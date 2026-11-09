{-# LANGUAGE DerivingStrategies #-}

-- Mix the changed converters in reordered named rows. Expectations come from
-- exact source rationals, declared padding and server-side text/byte views.
module Bulk.MixedPreservationSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import LiveProperty (liveHedgehog)
import Test.Hspec

import Bulk.Harness (createPair)
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Types (Collation (..), RawParam (..), TypeInfo (..))
import TestDb

data Number = F Float | D Double | I Int64 | N Decimal deriving stock (Eq, Show)
data Input = Input (Maybe Number) Integer (Maybe [Word16]) Int Bool (Maybe [Word16]) Int Bool deriving stock (Eq, Show)

spec :: Spec
spec = around withTestDb $
    withCases 100 $
        it "preserves mixed numeric sources and fixed/variable raw values across named-row order" $ \conn -> liveHedgehog $ do
            inputs <- forAll $ Gen.list (Range.linear 1 7) inputGen
            described <- forAll Gen.bool
            evalIO $ do
                (bulk, ordinary) <- createPair conn "decimal(28,4)"
                -- The harness tables have only k/v; give each the same extra columns.
                forM_ [bulk, ordinary] $ \table -> do
                    _ <- execute conn (rawSql ("ALTER TABLE " <> table <> " ADD r decimal(28,4),bytes varbinary(max),text_value ntext"))
                    pure ()
                let indexed = zip [1 ..] inputs :: [(Int32, Input)]
                    positional = [cells i value | (i, value) <- indexed]
                    names = ["k", "v", "r", "bytes", "text_value"]
                    named = [NamedParams (rotate (fromIntegral i `mod` 5) (zip names row)) | ((i, _), row) <- zip indexed positional]
                    expected = [expectation i value | (i, value) <- indexed]
                    view table = rawSql ("SELECT k,CONVERT(varchar(50),v),CONVERT(varchar(50),r),bytes,CONVERT(varbinary(max),CONVERT(nvarchar(max),text_value)) FROM " <> table <> " ORDER BY k")
                executeMany conn ("INSERT INTO " <> ordinary <> " (k,v,r,bytes,text_value) VALUES(@p1,@p2,@p3,@p4,@p5)") positional `shouldReturn` replicate (length inputs) 1
                columns <- if described then DescribedColumns <$> describeBulkColumns conn (bulkCopy bulk) else pure InsertableColumns
                bulkInsertWith (bulkCopy bulk){bulkColumns = columns, bulkBatchSize = Just 3} conn named `shouldReturn` fromIntegral (length inputs)
                query conn (view ordinary) `shouldReturn` expected
                query conn (view bulk) `shouldReturn` expected

inputGen :: Gen Input
inputGen = do
    base <- (+) <$> Gen.element [-(2 ^ (53 :: Int)) - 3, -(2 ^ (24 :: Int)) - 3, -1, 0, 1, 2 ^ (24 :: Int) + 3, 2 ^ (53 :: Int) + 3 :: Integer] <*> Gen.integral (Range.constant (-2) 2)
    fraction <- Gen.integral (Range.constant (-15) 15)
    number <- Gen.maybe $ Gen.element [F (fromRational (fromInteger base + fromInteger fraction / 16)), D (fromRational (fromInteger base + fromInteger fraction / 16)), I (fromInteger base), N (Decimal 4 (base * 10000 + fraction * 625))]
    binary <- Gen.maybe $ Gen.list (Range.linear 0 8) (Gen.element [0, 1, 127, 128, 255])
    binPad <- Gen.int (Range.constant 0 5)
    binFixed <- Gen.bool
    unicode <- Gen.maybe $ Gen.list (Range.linear 0 8) (Gen.element [0, 0x20, 0x78, 0x79, 0xD800, 0xDC00, 0xFEFF])
    textPad <- Gen.int (Range.constant 0 3)
    textFixed <- Gen.bool
    pure (Input number (base * 10000 - fraction * 625 - 100000) binary binPad binFixed unicode textPad textFixed)

cells :: Int32 -> Input -> [SqlParam]
cells ident (Input number right bin binPad fixedBin text textPad fixedText) =
    [SqlParam ident, maybe (SqlParam (Nothing :: Maybe Decimal)) numberParam number, SqlParam (Decimal 4 right :: Decimal), SqlParam (RawParam (if fixedBin then TIBigBinary (fromIntegral binWidth) else TIBigVarBinary (fromIntegral binWidth), B.pack . map fromIntegral <$> bin)), SqlParam (RawParam (if fixedText then TINChar (fromIntegral textWidth) coll else TINVarChar (fromIntegral textWidth) coll, utf16 <$> text))]
  where
    binWidth = max 1 (maybe 0 length bin + binPad)
    textWidth = 2 * max 1 (maybe 0 length text + textPad)
    coll = Collation 0x409 0

expectation :: Int32 -> Input -> (Int32, Maybe Text, Text, Maybe B.ByteString, Maybe B.ByteString)
expectation ident (Input number right bin binPad fixedBin text textPad fixedText) =
    (ident, format4 . round . (* 10000) . exact <$> number, format4 right, paddedBinary <$> bin, paddedText <$> text)
  where
    paddedBinary xs = B.pack (map fromIntegral xs ++ replicate (if fixedBin then max 1 (length xs + binPad) - length xs else 0) 0)
    paddedText xs = utf16 (xs ++ replicate (if fixedText then max 1 (length xs + textPad) - length xs else 0) 0x20)

numberParam :: Number -> SqlParam
numberParam = \case F x -> SqlParam x; D x -> SqlParam x; I x -> SqlParam x; N x -> SqlParam x
exact :: Number -> Rational
exact = \case F x -> toRational x; D x -> toRational x; I x -> fromIntegral x; N x -> toRational x
utf16 :: [Word16] -> B.ByteString
utf16 = B.pack . concatMap (\n -> [fromIntegral n, fromIntegral (n `div` 256)])
format4 :: Integer -> Text
format4 n = (if n < 0 then "-" else "") <> T.pack (show (abs n `div` 10000)) <> "." <> T.justifyRight 4 '0' (T.pack (show (abs n `mod` 10000)))
rotate :: Int -> [a] -> [a]
rotate n xs = drop n xs ++ take n xs
