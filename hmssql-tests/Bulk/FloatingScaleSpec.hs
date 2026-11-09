-- Multiplying in Float/Double before converting to Decimal loses low bits
-- even when the source value fits the declared exact destination completely.
module Bulk.FloatingScaleSpec (spec) where

import RecipeParameters
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import LiveProperty (liveHedgehog)
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding (FieldEncoder (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Types
import TestDb

spec :: Spec
spec = pureSpec >> liveSpec

pureSpec :: Spec
pureSpec = describe "floating scaling bytes (pure)" $ do
    forM_ [("Float integer", SqlParam (16777218 :: Float), 16777218 :: Rational), ("Double fraction", SqlParam (922337203685477.5 :: Double), 9223372036854775 / 10)] $ \(label, source, exact) ->
        forM_ [("money", TIMoneyN 8), ("decimal", TIDecimalN 20 4)] $ \(target, ti) ->
            it (label ++ " has exact " ++ target ++ " wire bytes") $ do
                let mantissa = round (exact * 10000) :: Integer
                    bytes = if target == "money" then little 4 (mantissa `div` 2 ^ (32 :: Int)) <> little 4 mantissa else B.singleton 1 <> little 12 mantissa
                    actual = encodeFieldBytes fieldEncoder defaultTdsContext source >>= encodeBulkCellBytes defaultTdsContext (BulkColumn "v" ti False False)
                actual `shouldBe` Right (Just bytes)
    it "rejects a negative Double that multiplication had rounded into money range" $ do
        let source = SqlParam (-922337203685477.625 :: Double)
            actual = encodeFieldBytes fieldEncoder defaultTdsContext source >>= encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TIMoneyN 8) False False)
        actual `shouldSatisfy` isLeft
  where
    little count n = B.pack [fromInteger ((n `div` 2 ^ (8 * i)) `mod` 256) | i <- [0 .. count - 1 :: Int]]

liveSpec :: Spec
liveSpec = around withTestDb $ do
    describe "exactly representable floating sources at four decimal places" $
        forM_ fourPlaceSources $ \(label, source, exact) ->
            forM_ ["money", "decimal(20,4)"] $ \target ->
                it (label ++ " remains exact in " ++ T.unpack target) $ \conn ->
                    checkExact conn target 4 source exact
    describe "large exact Double integers at fractional decimal scales" $
        forM_ [9007199254740994, 1e18, -1e18 :: Double] $ \value ->
            it (show value ++ " does not acquire a fractional tail") $ \conn ->
                checkExact conn "decimal(38,6)" 6 (SqlParam value) (toRational value)

    describe "range checks after exact floating scaling" $
        forM_ [("money", -922337203685477.625), ("money", 922337203685477.625), ("smallmoney", -214748.36485 :: Double)] $ \(target, value) ->
            it (T.unpack target ++ " rejects binary source " ++ show value ++ " outside its rounded range") $ \conn -> do
                (kind, count) <- probeBatch conn target (SqlParam value)
                rejected kind `shouldBe` True
                count `shouldBe` 0
                expectRejected conn target (SqlParam value)

    describe "high scale identity values" $
        forM_ highScaleSources $ \(label, scale, source, exact) ->
            it (label ++ " remains exact at scale " ++ show scale) $ \conn ->
                checkExact conn ("decimal(38," <> T.pack (show scale) <> ")") scale source exact

    describe "exact floating money properties" $ do
        withCases 200 $ it "preserves generated Float binary fractions that fit four places" $ \conn -> liveHedgehog $ do
            mantissa <- forAll $ Gen.integral (Range.constant (negate (2 ^ (24 :: Int) - 1)) (2 ^ (24 :: Int) - 1))
            exponent <- forAll $ Gen.int (Range.constant (-4) 20)
            let source = encodeFloat mantissa exponent :: Float
                exact = fromInteger mantissa * powerTwo exponent
            toRational source === exact
            evalIO $ checkExact conn "money" 4 (SqlParam source) exact
        withCases 200 $ it "preserves generated Double binary fractions that fit four places" $ \conn -> liveHedgehog $ do
            mantissa <- forAll $ Gen.integral (Range.constant (negate (2 ^ (49 :: Int) - 1)) (2 ^ (49 :: Int) - 1))
            exponent <- forAll $ Gen.int (Range.constant (-4) 0)
            let source = encodeFloat mantissa exponent :: Double
                exact = fromInteger mantissa * powerTwo exponent
            toRational source === exact
            evalIO $ checkExact conn "money" 4 (SqlParam source) exact

powerTwo :: Int -> Rational
powerTwo exponent
    | exponent < 0 = recip (fromInteger (2 ^ negate exponent))
    | otherwise = fromInteger (2 ^ exponent)

checkExact :: Connection -> Text -> Word8 -> SqlParam -> Rational -> Expectation
checkExact conn target scale source exact = do
    let scaled = exact * fromInteger (10 ^ scale)
        expected = Decimal scale (round scaled) :: Decimal
    -- These inputs have terminating binary fractions that fit the chosen
    -- decimal scale exactly; no rounding policy can justify changing them.
    toRational expected `shouldBe` exact
    (bulk, ordinary) <- createPair conn target
    loadBatch conn ordinary [[SqlParam (1 :: Int32), source]] `shouldReturn` [1]
    loadBulk conn bulk [[SqlParam (1 :: Int32), source]] `shouldReturn` 1
    forM_ [ordinary, bulk] $ \table -> do
        let expression = "CONVERT(decimal(38," <> T.pack (show scale) <> "),v)"
        query1 conn (rawSql ("SELECT " <> expression <> " FROM " <> table)) `shouldReturn` Only expected
        -- Compare against independently calculated decimal text on the server,
        -- so neither a dynamic decoder nor a matching encoder can hide loss.
        query1 conn (mkQuery ("SELECT CASE WHEN " <> expression <> "=CONVERT(decimal(38," <> T.pack (show scale) <> "),@p1) THEN 1 ELSE 0 END FROM " <> table) (Only (T.pack (show expected)))) `shouldReturn` Only (1 :: Int32)

fourPlaceSources :: [(String, SqlParam, Rational)]
fourPlaceSources =
    [floatSource value | value <- [16777215, 16777216, 16777218, -16777218, 123456.125, 1048576.25 :: Float]]
        ++ [doubleSource value | value <- [922337203685477.5, 922337203685477.375, -922337203685477.5, 900719925474099.125, -900719925474099.125 :: Double]]
  where
    floatSource value = ("Float " ++ show value, SqlParam value, toRational value)
    doubleSource value = ("Double " ++ show value, SqlParam value, toRational value)

highScaleSources :: [(String, Word8, SqlParam, Rational)]
highScaleSources =
    [ ("Float one", 37, SqlParam (1 :: Float), 1)
    , ("Float negative one", 37, SqlParam (-1 :: Float), -1)
    , ("Float half", 38, SqlParam (0.5 :: Float), 1 / 2)
    , ("Float negative half", 38, SqlParam (-0.5 :: Float), -1 / 2)
    , ("Float eighth", 38, SqlParam (0.125 :: Float), 1 / 8)
    , ("Float negative eighth", 38, SqlParam (-0.125 :: Float), -1 / 8)
    , ("Float five binary fractional bits", 12, SqlParam (0.03125 :: Float), 1 / 32)
    , ("Double one", 37, SqlParam (1 :: Double), 1)
    , ("Double negative one", 37, SqlParam (-1 :: Double), -1)
    , ("Double half", 38, SqlParam (0.5 :: Double), 1 / 2)
    , ("Double negative half", 38, SqlParam (-0.5 :: Double), -1 / 2)
    , ("Double eighth", 38, SqlParam (0.125 :: Double), 1 / 8)
    , ("Double negative eighth", 38, SqlParam (-0.125 :: Double), -1 / 8)
    , ("Double ten binary fractional bits", 38, SqlParam (0.0009765625 :: Double), 1 / 1024)
    ]
