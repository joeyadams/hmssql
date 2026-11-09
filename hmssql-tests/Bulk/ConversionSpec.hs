-- | Cross-type conversions, rather than only loading a value into its own
-- SQL type. Ordinary parameterized INSERT is the server-side oracle.
module Bulk.ConversionSpec (spec) where

import Control.Monad (forM_)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int16, Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.Types (Money (..), DateTimeOffset (..))
import Hmssql.SqlValue
import TestDb
import Bulk.Harness

spec :: Spec
spec = around withTestDb $ describe "bulk cross-type conversions" $ do
  forM_ numericSources $ \(source,values) ->
    forM_ ["bit","tinyint","smallint","int","bigint","decimal(10,2)","numeric(12,4)","money","smallmoney","real","float"] $ \target ->
      it (source ++ " into " ++ T.unpack target ++ " agrees with INSERT") $ \conn ->
        compareInsert conn target values
  forM_ ["smallint","int","bigint"] $ \target ->
    it ("rounds negative Money into " ++ T.unpack target ++ " as INSERT does") $ \conn ->
      compareInsert conn target (map (SqlParam . Money) [-2.5001,-2.5,-2.4999,-1.5,-1.0001,-0.5,-0.4999,0])
  it "accepts the exactly representable minimum bigint as Double" $ \conn ->
    compareInsert conn "bigint" [SqlParam (fromIntegral (minBound :: Int64) :: Double)]
  it "accepts the exactly representable minimum bigint as Float" $ \conn ->
    compareInsert conn "bigint" [SqlParam (fromIntegral (minBound :: Int64) :: Float)]
  it "converts the largest Double below bigint overflow without loss" $ \conn ->
    compareInsert conn "bigint" [SqlParam (9223372036854774784 :: Double)]

  it "keeps Money values that round to the minimum int in range" $ \conn ->
    compareInsert conn "int" [SqlParam (Money (-2147483648.4999)),SqlParam (Money (-2147483648)),SqlParam (Money 2147483647.4999)]
  it "accepts negative Money that rounds to zero in tinyint" $ \conn ->
    compareInsert conn "tinyint" [SqlParam (Money (-0.4999))]
  forM_ [("tinyint",Money 255.5),("tinyint",Money (-0.5)),("smallint",Money 32767.5),("int",Money 2147483647.5),("int",Money (-2147483648.5))] $ \(target,value) ->
    it ("rejects Money " ++ show value ++ " that rounds outside " ++ T.unpack target) $ \conn ->
      expectRejected conn target (SqlParam value)
  forM_ [9223372036854775808,-9223372036854777856 :: Double] $ \value ->
    it ("still rejects out-of-range Double " ++ show value ++ " for bigint") $ \conn ->
      expectRejected conn "bigint" (SqlParam value)

  -- At a target's integer boundary, decimal and binary floating values
  -- truncate, while money rounds. Check the stored server value as well
  -- as agreement between the two write paths.
  forM_ [("tinyint",0,255),("smallint",-32768,32767),("int",-2147483648,2147483647),("bigint",-9223372036854775808,9223372036854775807)] $ \(target,lo,hi) -> do
    it ("preserves integral neighbors of both " ++ T.unpack target ++ " boundaries") $ \conn ->
      compareInsert conn target (map (SqlParam . (fromInteger :: Integer -> Int64)) [lo,lo+1,hi-1,hi])
    it ("truncates decimal fractions at " ++ T.unpack target ++ " boundaries") $ \conn ->
      compareInsert conn target (map (SqlParam . (Decimal 4 :: Integer -> Decimal)) [lo*10000-9999,lo*10000,lo*10000+1,hi*10000-1,hi*10000+9999])
    forM_ [lo-1,hi+1] $ \value ->
      it ("rejects decimal " ++ show value ++ " outside " ++ T.unpack target) $ \conn -> do
        expectRejected conn target (SqlParam (Decimal 0 value :: Decimal))
        (kind,count) <- probeBatch conn target (SqlParam (Decimal 0 value :: Decimal))
        rejected kind `shouldBe` True
        count `shouldBe` 0
  forM_ [16777215,16777216,16777217,9007199254740991,9007199254740992,9007199254740993 :: Int64] $ \value ->
    it ("retains integer precision around binary float transitions: " ++ show value) $ \conn -> do
      compareInsert conn "bigint" [SqlParam value]
      compareInsert conn "decimal(20,0)" [SqlParam value]
      let floating = fromIntegral value :: Double
      compareInsert conn "bigint" [SqlParam floating]
      query1 conn (mkQuery "SELECT CONVERT(bigint,@p1)" (Only floating)) `shouldReturn` Only (truncate floating :: Int64)
  forM_ ["money","smallmoney"] $ \target ->
    it ("preserves exact fixed-point extrema of " ++ T.unpack target) $ \conn ->
      compareInsert conn target (map (SqlParam . (Decimal 4 :: Integer -> Decimal)) (if target == "money" then [-9223372036854775808,-9223372036854775807,9223372036854775806,9223372036854775807] else [-2147483648,-2147483647,2147483646,2147483647]))
  forM_ ["decimal(3,0)","decimal(5,2)"] $ \target -> do
    it ("rounds decimal ties with both signs and a carry in " ++ T.unpack target) $ \conn ->
      compareInsert conn target (map (SqlParam . (Decimal 3 :: Integer -> Decimal)) [-998499,-995500,-995499,-500,0,500,995499,995500,998499])
    it ("rejects decimal rounding that carries outside " ++ T.unpack target) $ \conn ->
      expectRejected conn target (SqlParam (Decimal 3 999999 :: Decimal))

  forM_ ["date","datetime","smalldatetime"] $ \target -> do
    it ("LocalTime into " ++ T.unpack target ++ " agrees with INSERT") $ \conn -> compareInsert conn target localValues
    it ("datetimeoffset local date/time into " ++ T.unpack target ++ " agrees with INSERT") $ \conn -> compareInsert conn target offsetValues
  forM_ [0..7 :: Int] $ \scale ->
    forM_ ["time","datetime2","datetimeoffset"] $ \family -> do
      let target = family <> "(" <> T.pack (show scale) <> ")"
      it ("LocalTime into " ++ T.unpack target ++ " agrees with INSERT") $ \conn -> compareInsert conn target localValues
      it ("datetimeoffset into " ++ T.unpack target ++ " agrees with INSERT") $ \conn -> compareInsert conn target offsetValues
  forM_ ["date","datetime","smalldatetime","datetime2(0)","datetime2(7)","datetimeoffset(0)","datetimeoffset(7)"] $ \target ->
    it ("Day at midnight into " ++ T.unpack target ++ " agrees with INSERT") $ \conn ->
      compareInsert conn target (map SqlParam [fromGregorian 1900 1 1,fromGregorian 2000 2 29,fromGregorian 2024 12 31])
  forM_ [0..7 :: Int] $ \scale ->
    it ("TimeOfDay into time(" ++ show scale ++ ") agrees with INSERT") $ \conn ->
      compareInsert conn ("time(" <> T.pack (show scale) <> ")") (map SqlParam [midnight,TimeOfDay 12 34 56.1234567,TimeOfDay 23 59 59.9999999])

numericSources :: [(String,[SqlParam])]
numericSources =
  [("Bool",map SqlParam [False,True])
  ,("Word8",map SqlParam ([0,1,254] :: [Word8]))
  ,("Int16",map SqlParam ([0,1,254] :: [Int16]))
  ,("Int32",map SqlParam ([0,1,254] :: [Int32]))
  ,("Int64",map SqlParam ([0,1,254] :: [Int64]))
  ,("Decimal",map SqlParam ([Decimal 2 0,Decimal 2 125,Decimal 2 150,Decimal 2 250,Decimal 2 25449] :: [Decimal]))
  ,("Money",map (SqlParam . Money) [0,1.25,1.5,2.5,254.49])
  ,("Float",map SqlParam ([0,1.25,1.5,2.5,254] :: [Float]))
  ,("Double",map SqlParam ([0,1.25,1.5,2.5,254] :: [Double]))]

localValues :: [SqlParam]
localValues = map SqlParam
  [LocalTime (fromGregorian 2000 2 29) midnight
  ,LocalTime (fromGregorian 2024 12 31) (TimeOfDay 23 59 59.9999999)
  ,LocalTime (fromGregorian 1900 1 1) (TimeOfDay 12 34 56.1234567)]

offsetValues :: [SqlParam]
offsetValues = [SqlParam (DateTimeOffset (UTCTime (fromGregorian 2024 2 29) (picosecondsToDiffTime 1800123456700000)) offset) | offset <- [-840,-60,0,60,840]]

compareInsert :: Connection -> Text -> [SqlParam] -> Expectation
compareInsert conn target values = do
  (bulk,ordinary) <- createPair conn target
  let rows = [[SqlParam i,value] | (i,value) <- zip [1..] values :: [(Int32,SqlParam)]]
  loadBatch conn ordinary rows `shouldReturn` replicate (length values) 1
  expected <- readColumn conn "v" ordinary :: IO [Maybe SqlValue]
  loadBulk conn bulk rows `shouldReturn` fromIntegral (length values)
  readColumn conn "v" bulk `shouldReturn` expected
  expectedLengths <- readDataLengths conn ordinary
  readDataLengths conn bulk `shouldReturn` expectedLengths
