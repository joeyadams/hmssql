-- | 'byColumn' compiles the decoder its function chooses for each column, and
-- 'columnIsLong' says which columns' values may be of any length.
module Wire.ByColumnSpec (spec) where

import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Hmssql.Decoding
import Hmssql.Errors (DecodeError (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Collation (..))
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Token (ColumnInfo (..), columnIsLong)
import Hmssql.Tds.TypeInfo (TypeInfo (..))

latin1 :: Collation
latin1 = Collation 0x00D00409 0x34

column :: TypeInfo -> ColumnInfo
column ti = ColumnInfo "c" ti 1 0 Nothing

-- An int, an nvarchar(max) and another int, as one ROW, then a sentinel byte.
rowBytes :: B.ByteString
rowBytes = LB.toStrict $ Put.runPut $ do
  Put.putWord8 0xD1
  Put.putWord8 4 >> Put.putInt32le 7
  let t = TE.encodeUtf16LE "long"
  Put.putWord64le (fromIntegral (B.length t)) >> Put.putWord32le (fromIntegral (B.length t)) >> Put.putByteString t >> Put.putWord32le 0
  Put.putWord8 4 >> Put.putInt32le 9
  Put.putWord8 0xFE

columns :: [ColumnInfo]
columns = [column (TIIntN 4), column (TINVarChar 0xFFFF latin1), column (TIIntN 4)]

-- A long column as text and any other as an int.
chosen :: ColumnInfo -> RowDecoder (Either Text Int32)
chosen col
  | columnIsLong col = Left <$> fieldRowDecoder
  | otherwise = Right <$> fieldRowDecoder

decoded :: Eq a => RowDecoder a -> IO (Either String a)
decoded d = case compileRowDecoder d defaultTdsContext columns of
  Left err -> pure (Left (show err))
  Right compiled -> mapM (\cut -> do
      ((result, marker), _) <- P.parseChunks ((,) <$> rowRecipe compiled 8 <*> P.word8) [B.take cut rowBytes, B.drop cut rowBytes]
      marker `shouldBe` 0xFE
      pure (either (const (Left "failed")) Right result))
    [0 .. B.length rowBytes] >>= \case
      results@(first : _) | all (== first) results -> pure first
      _ -> pure (Left "the cuts disagree")

spec :: Spec
spec = do
  it "compiles the decoder chosen for each column, in its place in the row" $
    decoded (traverse (const (byColumn chosen)) [(), (), ()]) `shouldReturn` Right [Right 7, Left "long", Right 9]

  it "refuses a chosen decoder that doesn't read one column, naming the column" $
    case compileRowDecoder (byColumn (const ((,) <$> fieldRowDecoder @Int32 <*> fieldRowDecoder @Int32)) *> pure ()) defaultTdsContext (take 1 columns) of
      Left (DecodeError col msg) -> (col, msg) `shouldBe` (Just "c", "byColumn chose a decoder of 2 columns, not 1")
      Right _ -> expectationFailure "accepted a decoder of two columns"

  it "refuses a column the chosen decoder refuses, as the decoder would" $
    case compileRowDecoder (byColumn (const (fieldRowDecoder @Int32))) defaultTdsContext [column (TINVarChar 0xFFFF latin1)] of
      Left (DecodeError col _) -> col `shouldBe` Just "c"
      Right _ -> expectationFailure "accepted text as an int"

  it "columnIsLong: the max types, xml and the legacy LOBs, and nothing of a bounded length" $ do
    map (columnIsLong . column)
      [TINVarChar 0xFFFF latin1, TIBigVarBinary 0xFFFF, TIBigVarChar 0xFFFF latin1, TIXml Nothing, TINText 0x7FFFFFFF latin1, TIImage 0x7FFFFFFF]
      `shouldBe` replicate 6 True
    map (columnIsLong . column)
      [TINVarChar 100 latin1, TIBigVarBinary 8000, TIIntN 4, TIDecimalN 18 4, TIGuid, TIDateTime2N 7]
      `shouldBe` replicate 6 False
