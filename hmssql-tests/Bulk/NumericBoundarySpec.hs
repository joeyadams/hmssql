-- Binary floating sources must retain their own source type in the SQL
-- oracle. Adjacent bit patterns exercise truncation on either side of a
-- boundary; decimal text literals would test a different conversion.
module Bulk.NumericBoundarySpec (spec) where

import RecipeParameters
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int32, Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import GHC.Float (castDoubleToWord64, castFloatToWord32, castWord32ToFloat, castWord64ToDouble)
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding (FieldEncoder (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Types
import TestDb

spec :: Spec
spec = do
    describe "nonfinite bit conversion (pure)" $
        forM_ nonfinite $ \(label, value) ->
            it ("refuses " ++ label ++ " before converting to a bit") $ do
                encoded <- either expectationError pure (encodeFieldBytes fieldEncoder defaultTdsContext value)
                encodeBulkCellBytes defaultTdsContext (BulkColumn "v" TIBit True False) encoded `shouldSatisfy` isLeft
    describe "nonfinite Float widening (pure)" $
        forM_ (take 3 nonfinite) $ \(label, value) ->
            it ("does not manufacture a finite Double from " ++ label) $ do
                encoded <- either expectationError pure (encodeFieldBytes fieldEncoder defaultTdsContext value)
                encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TIFltN 8) True False) encoded `shouldSatisfy` isLeft
    describe "Double narrowing zero bits (pure)" $
        forM_ [("positive zero", 0, False), ("negative zero", 0x8000000000000000, True), ("positive tiny underflow", 1, False), ("negative tiny underflow", 0x8000000000000001, True)] $ \(label, bits, negative) ->
            it ("preserves IEEE zero sign for " ++ label) $ do
                encoded <- either expectationError pure (encodeFieldBytes fieldEncoder defaultTdsContext (castWord64ToDouble bits))
                encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TIFltN 4) True False) encoded `shouldBe` Right (Just (B.pack [0, 0, 0, if negative then 128 else 0]))
    around withTestDb $ do
        describe "nonfinite bulk numeric conversion" $
            forM_ nonfinite $ \(label, value) ->
                it ("rejects " ++ label ++ " for bit just as the ordinary parameter does") $ \conn -> do
                    (ordinary, ordinaryCount) <- probeBatch conn "bit" value
                    rejected ordinary `shouldBe` True
                    ordinaryCount `shouldBe` 0
                    expectRejected conn "bit" value
        describe "nonfinite passthrough and variant storage" $
            forM_ nonfinite $ \(label, value) ->
                forM_ ["real", "float", "sql_variant", "decimal(38,10)", "money", "smallmoney"] $ \target ->
                    it ("does not store " ++ label ++ " in " ++ T.unpack target) $ \conn ->
                        expectRejected conn target value
        describe "adjacent floating integer boundaries" $
            forM_ [("tinyint", 0, 255), ("smallint", -32768, 32767), ("int", -2147483648, 2147483647), ("bigint", -9223372036854775808, 9223372036854775807)] $ \(target, lo, hi) -> do
                forM_ (nub [fromInteger lo, fromInteger hi]) $ \boundary -> do
                    it (T.unpack target ++ " from Float neighbors of " ++ show (boundary :: Float)) $ \conn ->
                        forM_ [downF boundary, boundary, upF boundary] $ \value -> compareIntegral conn target lo hi (SqlParam value) (toRational value)
                forM_ (nub [fromInteger lo, fromInteger hi]) $ \boundary -> do
                    it (T.unpack target ++ " from Double neighbors of " ++ show (boundary :: Double)) $ \conn ->
                        forM_ [downD boundary, boundary, upD boundary] $ \value -> compareIntegral conn target lo hi (SqlParam value) (toRational value)
        describe "finite bit conversions next to zero" $
            forM_ [("Float", map (SqlParam . castWord32ToFloat) [0, 0x80000000, 1, 0x80000001]), ("Double", map (SqlParam . castWord64ToDouble) [0, 0x8000000000000000, 1, 0x8000000000000001])] $ \(label, values) ->
                it ("keeps signed zero and signed subnormals distinct as " ++ label ++ " bit sources") $ \conn -> do
                    (bulk, ordinary) <- createPair conn "bit"
                    let rows = [[SqlParam i, value] | (i, value) <- zip [1 .. 4 :: Int32] values]
                    loadBatch conn ordinary rows `shouldReturn` [1, 1, 1, 1]
                    loadBulk conn bulk rows `shouldReturn` 4
                    forM_ [bulk, ordinary] $ \table ->
                        query conn (rawSql ("SELECT CONVERT(int,v) FROM " <> table <> " ORDER BY k")) `shouldReturn` map Only [0, 0, 1, 1 :: Int32]
        describe "Double narrowing to real" $
            forM_ [0, 1, 2, 0x007fffff, 0x00800000, 0x3f7fffff, 0x3f800000, 0x7f7fffff :: Word32] $ \bits ->
                it ("agrees with server binary rounding around Float bits " ++ show bits) $ \conn -> do
                    let center = realToFrac (castWord32ToFloat bits) :: Double
                        next = realToFrac (castWord32ToFloat (bits + 1)) :: Double
                        midpoint = (center + next) / 2
                        values = nub ([downD center, center, upD center] ++ if isInfinite next then [] else [downD midpoint, midpoint, upD midpoint])
                    forM_ (values ++ map negate values) $ \value -> do
                        (bulk, ordinary) <- createPair conn "real"
                        (ordinaryResult, count) <- probeBatch conn "real" (SqlParam value)
                        if rejected ordinaryResult
                            then do
                                count `shouldBe` 0
                                expectRejected conn "real" (SqlParam value)
                            else do
                                loadBatch conn ordinary [[SqlParam (1 :: Int32), SqlParam value]] `shouldReturn` [1]
                                loadBulk conn bulk [[SqlParam (1 :: Int32), SqlParam value]] `shouldReturn` 1
                                Only serverValue <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Float)
                                Only bulkValue <- query1 conn (rawSql ("SELECT v FROM " <> bulk)) :: IO (Only Float)
                                castFloatToWord32 bulkValue `shouldBe` castFloatToWord32 serverValue
        describe "binary precision transitions" $ do
            forM_ [negate (2 ^ (24 :: Int)), 2 ^ (24 :: Int) :: Float] $ \boundary ->
                it ("stores Float neighbors of " ++ show boundary ++ " as exact bigint integers") $ \conn ->
                    forM_ [downF boundary, boundary, upF boundary] $ \value ->
                        compareIntegral conn "bigint" (toInteger (minBound :: Int64)) (toInteger (maxBound :: Int64)) (SqlParam value) (toRational value)
            forM_ [negate (2 ^ (53 :: Int)), 2 ^ (53 :: Int) :: Double] $ \boundary ->
                it ("stores Double neighbors of " ++ show boundary ++ " as exact bigint integers") $ \conn ->
                    forM_ [downD boundary, boundary, upD boundary] $ \value ->
                        compareIntegral conn "bigint" (toInteger (minBound :: Int64)) (toInteger (maxBound :: Int64)) (SqlParam value) (toRational value)

-- Each case has a fresh pair of tables. The expected integer is obtained
-- from the exact binary rational, independently of both driver paths.
compareIntegral :: Connection -> Text -> Integer -> Integer -> SqlParam -> Rational -> Expectation
compareIntegral conn target lo hi source exact = do
    let expected = truncate exact :: Integer
    if expected < lo || expected > hi
        then do
            (ordinary, count) <- probeBatch conn target source
            rejected ordinary `shouldBe` True
            count `shouldBe` 0
            expectRejected conn target source
        else do
            (bulk, ordinary) <- createPair conn target
            loadBatch conn ordinary [[SqlParam (1 :: Int32), source]] `shouldReturn` [1]
            loadBulk conn bulk [[SqlParam (1 :: Int32), source]] `shouldReturn` 1
            forM_ [ordinary, bulk] $ \table ->
                query1 conn (rawSql ("SELECT CONVERT(bigint,v) FROM " <> table)) `shouldReturn` Only (fromInteger expected :: Int64)

nonfinite :: [(String, SqlParam)]
nonfinite =
    [ ("Float NaN", SqlParam (0 / 0 :: Float))
    , ("Float +Infinity", SqlParam (1 / 0 :: Float))
    , ("Float -Infinity", SqlParam (-1 / 0 :: Float))
    , ("Double NaN", SqlParam (0 / 0 :: Double))
    , ("Double +Infinity", SqlParam (1 / 0 :: Double))
    , ("Double -Infinity", SqlParam (-1 / 0 :: Double))
    ]

upF :: Float -> Float
upF x
    | x == 0 = castWord32ToFloat 1
    | x > 0 = castWord32ToFloat (castFloatToWord32 x + 1)
    | otherwise = castWord32ToFloat (castFloatToWord32 x - 1)
downF :: Float -> Float
downF = negate . upF . negate
upD :: Double -> Double
upD x
    | x == 0 = castWord64ToDouble 1
    | x > 0 = castWord64ToDouble (castDoubleToWord64 x + 1)
    | otherwise = castWord64ToDouble (castDoubleToWord64 x - 1)
downD :: Double -> Double
downD = negate . upD . negate

expectationError :: String -> IO a
expectationError message = expectationFailure message >> fail message
