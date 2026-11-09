-- The source SQL expression constructs the value independently at the same
-- precision as its public ToSqlField/RawParam representation. This separates
-- source quantization from a second server conversion to the destination.
module Bulk.TemporalBoundarySpec (spec) where

import Control.Monad (forM_)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.Errors (SqlServerError, sqlErrorNumber)
import Hmssql.SqlValue
import Hmssql.Tds.Primitives (putDateTime4, putDateTime8, runPutSized)
import Hmssql.Types
import TestDb

data Source = Source String SqlParam Text (Maybe Text)

spec :: Spec
spec = around withTestDb $ do
    describe "temporal source quantization and target conversion" $
        forM_ sources $ \(Source label source oracleSource legacyClamp) ->
            forM_ targets $ \target ->
                it (label ++ " into " ++ T.unpack target) $ \conn -> do
                    let nativeOracle = "SELECT TRY_CONVERT(" <> target <> "," <> oracleSource <> ")"
                        clampsLegacy = target == "datetime" && legacyClamp /= Nothing
                    Only expected <- query1 conn (rawSql (if clampsLegacy then "SELECT " <> maybe "NULL" id legacyClamp else nativeOracle)) :: IO (Only (Maybe SqlValue))
                    case expected of
                        Nothing -> do
                            (kind, count) <- probeBatch conn target source
                            rejected kind `shouldBe` True
                            count `shouldBe` 0
                            expectRejected conn target source
                        Just value -> do
                            (bulk, ordinary) <- createPair conn target
                            let rows = [[SqlParam (1 :: Int32), source]]
                            if clampsLegacy
                                then do
                                    -- The shared clock's upper clamp is intentional. SQL Server
                                    -- clamps datetime2 but rejects datetimeoffset at this boundary.
                                    query1 conn (rawSql nativeOracle) `shouldReturn` Only (Nothing :: Maybe SqlValue)
                                    loadBatch conn ordinary rows `shouldThrow` (\(e :: SqlServerError) -> sqlErrorNumber e == 242)
                                    readColumn conn "v" ordinary `shouldReturn` ([] :: [Maybe SqlValue])
                                else loadBatch conn ordinary rows `shouldReturn` [1]
                            loadBulk conn bulk rows `shouldReturn` 1
                            readColumn conn "v" bulk `shouldReturn` [Just value]
                            if clampsLegacy
                                then pure ()
                                else do
                                    readColumn conn "v" ordinary `shouldReturn` [Just value]
                                    lengths <- readDataLengths conn ordinary
                                    readDataLengths conn bulk `shouldReturn` lengths
    it "retains the documented smalldatetime upper clamp despite server INSERT overflow" $ \conn -> do
        let input = LocalTime (fromGregorian 2079 6 6) (TimeOfDay 23 59 29.99999995)
            sentinel = LocalTime (fromGregorian 2079 6 6) (TimeOfDay 23 58 0)
            clamped = LocalTime (fromGregorian 2079 6 6) (TimeOfDay 23 59 0)
        (bulk, ordinary) <- createPair conn "smalldatetime"
        forM_ [bulk, ordinary] $ \table ->
            loadBatch conn table [[SqlParam (0 :: Int32), SqlParam sentinel]] `shouldReturn` [1]
        let rows = [[SqlParam (1 :: Int32), SqlParam input]]
        loadBatch conn ordinary rows `shouldThrow` (\(e :: SqlServerError) -> sqlErrorNumber e == 242)
        loadBulk conn bulk rows `shouldReturn` 1
        query conn (rawSql ("SELECT k,v FROM " <> ordinary <> " ORDER BY k")) `shouldReturn` [(0 :: Int32, sentinel)]
        query conn (rawSql ("SELECT k,v FROM " <> bulk <> " ORDER BY k")) `shouldReturn` [(0 :: Int32, sentinel), (1, clamped)]

targets :: [Text]
targets = ["date", "datetime", "smalldatetime"] ++ [family <> "(" <> T.pack (show scale) <> ")" | family <- ["time", "datetime2", "datetimeoffset"], scale <- [0, 3, 7 :: Int]]

sources :: [Source]
sources =
    [ local "below source carry" (LocalTime (fromGregorian 2024 12 31) (TimeOfDay 23 59 59.99999994)) "2024-12-31T23:59:59.9999999"
    , local "at source carry" (LocalTime (fromGregorian 2024 12 31) (TimeOfDay 23 59 59.99999995)) "2025-01-01T00:00:00.0000000"
    , local "below second-rounding threshold" (LocalTime (fromGregorian 1999 12 31) (TimeOfDay 23 59 59.49999994)) "1999-12-31T23:59:59.4999999"
    , local "source rounds into second-rounding threshold" (LocalTime (fromGregorian 1999 12 31) (TimeOfDay 23 59 59.49999995)) "1999-12-31T23:59:59.5000000"
    , local "small date just below last-minute overflow" (LocalTime (fromGregorian 2079 6 6) (TimeOfDay 23 59 29.99999994)) "2079-06-06T23:59:29.9999999"
    , local "datetime lower bound rounds into range" (LocalTime (fromGregorian 1752 12 31) (TimeOfDay 23 59 59.9999)) "1752-12-31T23:59:59.9999000"
    , maxDto "local upper bound caps UTC rounding" (DateTimeOffset (UTCTime (fromGregorian 9999 12 31) (picosecondsToDiffTime (35999999999999950))) 840) "9999-12-31T23:59:59.9999999+14:00"
    , dto "UTC upper bound caps local rounding" (DateTimeOffset (UTCTime (fromGregorian 9999 12 31) (picosecondsToDiffTime (86399999999999950))) (-840)) "9999-12-31T09:59:59.9999999-14:00"
    , dto "local lower bound rounds into range" (DateTimeOffset (UTCTime (fromGregorian 1 1 1) (picosecondsToDiffTime 3599999999950000)) (-60)) "0001-01-01T00:00:00.0000000-01:00"
    , Source "legacy datetime fractional tick" (rawLegacy True (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 23 59 59.996666666667))) "CONVERT(datetime,'2024-02-29T23:59:59.997',126)" Nothing
    , Source "legacy datetime negative day fractional tick" (rawLegacy True (LocalTime (fromGregorian 1899 12 31) (TimeOfDay 23 59 59.003333333333))) "CONVERT(datetime,'1899-12-31T23:59:59.003',126)" Nothing
    , Source "legacy small datetime minute carry" (rawLegacy False (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 23 59 30))) "CONVERT(smalldatetime,'2024-03-01T00:00:00',126)" Nothing
    ]
  where
    local label value literal = Source label (SqlParam value) ("CONVERT(datetime2(7),'" <> literal <> "',126)") Nothing
    dto label value literal = Source label (SqlParam value) ("CONVERT(datetimeoffset(7),'" <> literal <> "')") Nothing
    maxDto label value literal = Source label (SqlParam value) ("CONVERT(datetimeoffset(7),'" <> literal <> "')") (Just "CONVERT(datetime,'9999-12-31T23:59:59.997',126)")

rawLegacy :: Bool -> LocalTime -> SqlParam
rawLegacy full input =
    let width = if full then 8 else 4
        encoded = if full then putDateTime8 input else putDateTime4 input
     in case encoded of
            Left message -> error message
            Right bytes -> SqlParam (RawParam (TIDateTimeN (fromIntegral width), Just (runPutSized width bytes)))
