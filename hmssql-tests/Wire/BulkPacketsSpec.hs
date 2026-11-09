-- | Bulk ROW/PLP serialization independently parsed from its packet payloads.
-- These checks need no server and include surrogate pairs split by chunks,
-- packet-id wraparound, NULL/empty values, and empty loads.
module Wire.BulkPacketsSpec (spec) where

import Wire.RecipeGet (getToken)
import Control.Monad (forM_, replicateM, unless)
import qualified Data.Binary.Get as Get
import Data.Bits (xor)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Hmssql.BulkCopy
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (Collation (..))
import Hmssql.Tds.Value (rowValues)
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo
import Wire.Util (runIncremental)

spec :: Spec
spec = do
  describe "bulk load packet serialization" $
    forM_ [512,513,1024,7999,8000,8192,32767 :: Int] $ \size -> do
      it ("encodes an empty load at packet size " ++ show size) $
        checkPackets size []
      forM_ [0,1,3999,4000,4001,7999,8000,8001,16000,131072 :: Int] $ \n ->
        it ("round trips PLP length " ++ show n ++ " with packet size " ++ show size) $ do
          let text = "x" <> T.replicate n "😀" <> "𝄞 tail"
              bytes = B.pack [fromIntegral ((i*97) `xor` (i `div` 251)) | i <- [0..n-1]]
              rows =
                [ [Just (B.pack [0,0,0,128]),Just (TE.encodeUtf16LE text),Just bytes]
                , [Nothing,Just B.empty,Nothing]
                , [Just (B.pack [255,255,255,127]),Nothing,Just B.empty]
                ]
          checkPackets size rows
  describe "a row poked into the packet" $
    forM_ [512, 4096 :: Int] $ \size ->
      it ("writes the bytes writeValue writes, at packet size " ++ show size) $ do
        let context = defaultTdsContext {tdsPacketSize = fromIntegral size}
            loaded rows = B.concat (map (B.drop headerLength) (bulkLoadPackets context "t" pokedColumns rows))
            withoutRows = loaded []
            (metadata, done) = B.splitAt (B.length withoutRows - 13) withoutRows
            row values = BB.word8 0xD1 <> mconcat (zipWith (writeValue . bulkWireType . bulkColumnType) pokedColumns values)
        loaded pokedRows `shouldBe` B.concat [metadata, LB.toStrict (BB.toLazyByteString (foldMap row pokedRows)), done]
  it "round trips supplementary characters in column metadata across packets" $ do
    let longColumns = zipWith (\column suffix -> column {bulkColumnName=T.replicate 63 "😀" <> suffix}) columns ["a","b","c"]
    checkPacketsWith longColumns 512 [[Nothing,Just (TE.encodeUtf16LE "😀"),Nothing]]

-- A column of each length kind a poked row writes, and rows with NULL, empty values
-- and one longer than a 512-byte packet.
pokedColumns :: [BulkColumn]
pokedColumns =
  [ BulkColumn "n" (TIIntN 4) True False
  , BulkColumn "f" TIInt4 False False
  , BulkColumn "s" (TINVarChar 200 (Collation 0 0)) True False
  , BulkColumn "b" (TIBigVarBinary 8000) True False
  , BulkColumn "v" (TISqlVariant 8016) True False ]

pokedRows :: [[RawBytes]]
pokedRows =
  [ [Just "\1\0\0\0", Just "\2\0\0\0", Just "a\0b\0", Just (B.replicate 3000 7), Just "\x38\0\4\0\0\0"]
  , [Nothing, Just "\3\0\0\0", Just B.empty, Nothing, Nothing]
  , [Just "\4\0\0\0", Just "\5\0\0\0", Nothing, Just B.empty, Just "\x38\0\6\0\0\0"] ]
  ++ [ [Just (B.pack [fromIntegral i, 0, 0, 0]), Just "\0\0\0\0", Just (B.replicate (2 * (i `mod` 100)) 0x41), Nothing, Nothing] | i <- [1 .. 200 :: Int] ]

columns :: [BulkColumn]
columns =
  [BulkColumn "id" (TIIntN 4) True False
  ,BulkColumn "value]😀" (TINVarChar maxLength (Collation 0 0)) True False
  ,BulkColumn "bytes" (TIBigVarBinary maxLength) True False]

checkPackets :: Int -> [[RawBytes]] -> Expectation
checkPackets = checkPacketsWith columns

checkPacketsWith :: [BulkColumn] -> Int -> [[RawBytes]] -> Expectation
checkPacketsWith cols size expected = do
  let context = defaultTdsContext {tdsPacketSize=fromIntegral size}
      packets = bulkLoadPackets context "[schema.with dot].[table]]😀]" cols expected
      headers = map (Get.runGet getHeader . LB.fromStrict) packets
      payloads = map (B.drop headerLength) packets
      parse = do
        TColMetaData metadata <- getToken context Nothing
        rows <- replicateM (length expected) $ do
          TRow row <- getToken context (Just metadata)
          pure (rowValues row)
        TDone done <- getToken context (Just metadata)
        unless (isFinalDone (TDone done)) (fail "bulk load did not end with final DONE")
        empty <- Get.isEmpty
        unless empty (fail "trailing bytes after bulk DONE")
        pure (map columnName metadata,rows)
      expectedResult = (map bulkColumnName cols,expected)
  packets `shouldSatisfy` (not . null)
  map headerType headers `shouldBe` replicate (length packets) PTBulkLoad
  map (fromIntegral . headerPacketLength) headers `shouldBe` map B.length packets
  map headerStatus headers `shouldBe` (replicate (length packets-1) (PacketStatus 0) ++ [statusEndOfMessage])
  map headerPacketId headers `shouldBe` take (length packets) (cycle ([1..255] ++ [0]))
  map B.length packets `shouldSatisfy` all (\n -> n>=headerLength && n<=size)
  Get.runGet parse (LB.fromChunks payloads) `shouldBe` expectedResult
  runIncremental parse payloads `shouldBe` Right expectedResult
