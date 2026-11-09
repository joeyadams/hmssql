{-# LANGUAGE TypeApplications #-}
-- | The date\/time DECODING matrix: which of the six SQL date\/time column
-- families (date, time(s), datetime, smalldatetime, datetime2(s),
-- datetimeoffset(s)) each Haskell target ('Day', 'TimeOfDay', 'LocalTime',
-- 'UTCTime', 'ZonedTime', 'DateTimeOffset', 'SqlValue') accepts or rejects
-- (per the 'FromSqlField' instances in "Hmssql.Decoding"), plus value
-- correctness at scale/range boundaries and NULL\/type-mismatch errors for
-- the 'UTCTime' target specifically (the type mssql used to decode
-- @datetime@\/@datetime2@ into by default; see docs\/mssql-comparison.md,
-- "Behaviour changes when porting from mssql").
--
-- Encoding-side boundaries (rounding, clamping, range checks) are covered by
-- 'Types.TimeBoundarySpec'; this module only tests decoding.
module Types.DateTimeDecodeSpec (spec) where

import Control.Exception (try)
import Data.Time
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Decoding
import Hmssql.Tds.Context
import TestDb

------------------------------------------------------------------------------
-- Pure acceptance matrix

mkCol :: TypeInfo -> ColumnInfo
mkCol ti = ColumnInfo
  { columnName = "col"
  , columnType = ti
  , columnFlags = 0
  , columnUserType = 0
  , columnTableName = Nothing
  }

accepts :: FieldDecoder a -> TypeInfo -> Bool
accepts dec ti = either (const False) (const True) (compileField dec defaultTdsContext (mkCol ti))

-- | The six column families under test, each represented by one
-- representative 'TypeInfo' (scale doesn't affect acceptance).
sqlFamilies :: [(String, TypeInfo)]
sqlFamilies =
  [ ("date", TIDateN)
  , ("time(7)", TITimeN 7)
  , ("time(0)", TITimeN 0)
  , ("datetime (fixed, TIDateTime8)", TIDateTime8)
  , ("datetime (nullable, TIDateTimeN 8)", TIDateTimeN 8)
  , ("smalldatetime (fixed, TIDateTime4)", TIDateTime4)
  , ("smalldatetime (nullable, TIDateTimeN 4)", TIDateTimeN 4)
  , ("datetime2(7)", TIDateTime2N 7)
  , ("datetime2(0)", TIDateTime2N 0)
  , ("datetimeoffset(7)", TIDateTimeOffsetN 7)
  , ("datetimeoffset(0)", TIDateTimeOffsetN 0)
  ]

-- | Which families count as "date", "time", "datetime-like" (datetime,
-- smalldatetime, datetime2, date) and "datetimeoffset" for the expected
-- table below.
isDateFam, isTimeFam, isDatetimeLikeFam, isDtoFam :: String -> Bool
isDateFam n = n == "date"
isTimeFam n = take 4 n == "time"
isDatetimeLikeFam n = n `elem`
  [ "date", "datetime (fixed, TIDateTime8)", "datetime (nullable, TIDateTimeN 8)"
  , "smalldatetime (fixed, TIDateTime4)", "smalldatetime (nullable, TIDateTimeN 4)"
  , "datetime2(7)", "datetime2(0)" ]
isDtoFam n = take 14 n == "datetimeoffset"

data Target = Target String (TypeInfo -> Bool)

targets :: [Target]
targets =
  [ Target "Day" (accepts (fieldDecoder @Day))
  , Target "TimeOfDay" (accepts (fieldDecoder @TimeOfDay))
  , Target "LocalTime" (accepts (fieldDecoder @LocalTime))
  , Target "UTCTime" (accepts (fieldDecoder @UTCTime))
  , Target "ZonedTime" (accepts (fieldDecoder @ZonedTime))
  , Target "DateTimeOffset" (accepts (fieldDecoder @DateTimeOffset))
  , Target "SqlValue" (accepts (fieldDecoder @SqlValue))
  ]

-- | The documented rule for each target, derived from "Hmssql.Decoding":
--
-- * 'Day' only @date@.
-- * 'TimeOfDay' only @time@.
-- * 'LocalTime' @date@, @datetime@, @smalldatetime@, @datetime2@ (not @time@,
--   not @datetimeoffset@).
-- * 'UTCTime' everything except @time@ (zoneless types are taken as UTC;
--   @datetimeoffset@ is converted).
-- * 'ZonedTime' and 'DateTimeOffset' only @datetimeoffset@.
-- * 'SqlValue' everything (dynamic).
expected :: String -> String -> Bool
expected "Day" fam = isDateFam fam
expected "TimeOfDay" fam = isTimeFam fam
expected "LocalTime" fam = isDatetimeLikeFam fam
expected "UTCTime" fam = isDatetimeLikeFam fam || isDtoFam fam
expected "ZonedTime" fam = isDtoFam fam
expected "DateTimeOffset" fam = isDtoFam fam
expected "SqlValue" _ = True
expected t _ = error ("expected: unknown target " ++ t)

-- | 'Maybe' of a target accepts exactly what the target does (NULL is always
-- additionally accepted as 'Nothing', which this predicate doesn't need to
-- check since it only asks about compiling against a column type).
maybeAccepts :: Target -> TypeInfo -> Bool
maybeAccepts (Target "Day" _) = accepts (fieldDecoder @(Maybe Day))
maybeAccepts (Target "TimeOfDay" _) = accepts (fieldDecoder @(Maybe TimeOfDay))
maybeAccepts (Target "LocalTime" _) = accepts (fieldDecoder @(Maybe LocalTime))
maybeAccepts (Target "UTCTime" _) = accepts (fieldDecoder @(Maybe UTCTime))
maybeAccepts (Target "ZonedTime" _) = accepts (fieldDecoder @(Maybe ZonedTime))
maybeAccepts (Target "DateTimeOffset" _) = accepts (fieldDecoder @(Maybe DateTimeOffset))
maybeAccepts (Target "SqlValue" _) = accepts (fieldDecoder @(Maybe SqlValue))
maybeAccepts (Target t _) = error ("maybeAccepts: unknown target " ++ t)

matrixSpec :: Spec
matrixSpec = describe "acceptance matrix (compiled against a synthetic column, no server needed)" $
  sequence_
    [ it (target ++ " x " ++ fam) $ do
        got `shouldBe` expected target fam
        maybeGot `shouldBe` expected target fam
    | Target target predicate <- targets
    , (fam, ti) <- sqlFamilies
    , let got = predicate ti
    , let maybeGot = maybeAccepts (Target target predicate) ti
    ]

------------------------------------------------------------------------------
-- Live: value correctness and errors for UTCTime specifically

day' :: Integer -> Int -> Int -> Day
day' = fromGregorian

-- | @datetime@'s resolution is 1\/300s; the last representable tick of a day.
lastDateTimeTick :: DiffTime
lastDateTimeTick = picosecondsToDiffTime ((300 * 86400 - 1) * 1_000_000_000_000 `div` 300)

liveSpec :: SpecWith Connection
liveSpec = do
  describe "UTCTime decodes datetime and datetime2 (the mssql default target)" $ do
    it "decodes datetime at its extremes as UTCTime" $ \conn -> do
      r <- query1 conn
        "SELECT CAST('1753-01-01' AS datetime), CAST('9999-12-31 23:59:59.997' AS datetime)"
      r `shouldBe`
        ( UTCTime (day' 1753 1 1) 0
        , UTCTime (day' 9999 12 31) lastDateTimeTick :: UTCTime )

    it "decodes datetime2(7) at its extremes as UTCTime" $ \conn -> do
      r <- query1 conn
        "SELECT CAST('0001-01-01' AS datetime2(7)), CAST('9999-12-31 23:59:59.9999999' AS datetime2(7))"
      r `shouldBe`
        ( UTCTime (day' 1 1 1) 0
        , UTCTime (day' 9999 12 31) (86400 - 0.0000001) :: UTCTime )

    it "decodes date as UTCTime at midnight" $ \conn ->
      query1 conn "SELECT CAST('2020-06-15' AS date)"
        `shouldReturn` Only (UTCTime (day' 2020 6 15) 0)

    it "decodes smalldatetime as UTCTime" $ \conn ->
      query1 conn "SELECT CAST('2079-06-06 23:59' AS smalldatetime)"
        `shouldReturn` Only (UTCTime (day' 2079 6 6) (23 * 3600 + 59 * 60))

  describe "UTCTime decodes datetimeoffset, converting across day/year boundaries" $ do
    it "converts a positive-offset local time near midnight to the previous UTC day" $ \conn ->
      query1 conn "SELECT CAST('2020-01-01 00:30:00 +02:00' AS datetimeoffset(0))"
        `shouldReturn` Only (UTCTime (day' 2019 12 31) (22 * 3600 + 30 * 60))

    it "converts a negative-offset local time near midnight to the next UTC day" $ \conn ->
      query1 conn "SELECT CAST('2019-12-31 23:30:00 -02:00' AS datetimeoffset(0))"
        `shouldReturn` Only (UTCTime (day' 2020 1 1) (1 * 3600 + 30 * 60))

    it "converts the documented UTC extremes at +/-14:00" $ \conn ->
      query1 conn
        "SELECT CAST('0001-01-01 14:00:00 +14:00' AS datetimeoffset(7)), \
        \CAST('9999-12-31 09:59:59.9999999 -14:00' AS datetimeoffset(7))"
        `shouldReturn`
          ( UTCTime (day' 1 1 1) 0
          , UTCTime (day' 9999 12 31) (86400 - 0.0000001) :: UTCTime )

  describe "NULL" $ do
    it "decodes NULL datetime/datetime2/date/datetimeoffset as Nothing :: Maybe UTCTime" $ \conn -> do
      query1 conn "SELECT CAST(NULL AS datetime)" `shouldReturn` Only (Nothing :: Maybe UTCTime)
      query1 conn "SELECT CAST(NULL AS datetime2(7))" `shouldReturn` Only (Nothing :: Maybe UTCTime)
      query1 conn "SELECT CAST(NULL AS date)" `shouldReturn` Only (Nothing :: Maybe UTCTime)
      query1 conn "SELECT CAST(NULL AS datetimeoffset(7))" `shouldReturn` Only (Nothing :: Maybe UTCTime)

    it "rejects a NULL datetime into a non-Maybe UTCTime, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS datetime) AS d" :: IO (Only UTCTime))
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Just "d"
          msg `shouldContain` "NULL"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a NULL datetime2 into a non-Maybe UTCTime, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS datetime2(3)) AS d2" :: IO (Only UTCTime))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "d2"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a NULL datetimeoffset into a non-Maybe UTCTime, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS datetimeoffset(3)) AS dto" :: IO (Only UTCTime))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "dto"
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "type mismatches, naming the column" $ do
    it "rejects an int column as UTCTime" $ \conn -> do
      r <- try (query1 conn "SELECT 42 AS n" :: IO (Only UTCTime))
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Just "n"
          msg `shouldContain` "UTCTime"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a time column as UTCTime (there is no date to anchor it to)" $ \conn -> do
      r <- try (query1 conn "SELECT CAST('12:00:00' AS time) AS t" :: IO (Only UTCTime))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "t"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a datetimeoffset column as LocalTime (ambiguous without dropping the offset)" $ \conn -> do
      r <- try (query1 conn "SELECT CAST('2020-01-01 00:00:00 +02:00' AS datetimeoffset(0)) AS z" :: IO (Only LocalTime))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "z"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a datetime column as ZonedTime/DateTimeOffset" $ \conn -> do
      r1 <- try (query1 conn "SELECT CAST('2020-01-01' AS datetime) AS d" :: IO (Only ZonedTime))
      case r1 of
        Left (DecodeError col _) -> col `shouldBe` Just "d"
        Right (Only zt) -> expectationFailure ("decoded " ++ show zt)
      r2 <- try (query1 conn "SELECT CAST('2020-01-01' AS datetime) AS d" :: IO (Only DateTimeOffset))
      case r2 of
        Left (DecodeError col _) -> col `shouldBe` Just "d"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a datetime column as Day, and a date column as TimeOfDay" $ \conn -> do
      r1 <- try (query1 conn "SELECT CAST('2020-01-01' AS datetime) AS d" :: IO (Only Day))
      case r1 of
        Left (DecodeError col _) -> col `shouldBe` Just "d"
        Right v -> expectationFailure ("decoded " ++ show v)
      r2 <- try (query1 conn "SELECT CAST('2020-01-01' AS date) AS d2" :: IO (Only TimeOfDay))
      case r2 of
        Left (DecodeError col _) -> col `shouldBe` Just "d2"
        Right v -> expectationFailure ("decoded " ++ show v)

spec :: Spec
spec = do
  matrixSpec
  around withTestDb liveSpec
