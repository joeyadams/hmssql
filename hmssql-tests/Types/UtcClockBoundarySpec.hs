-- utcToLocalTime used an Int hour during negative day-clock conversion.
-- A whole Int modulus of hours must not disappear before SQL range checks.
module Types.UtcClockBoundarySpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_, void)
import Data.Either (isLeft, isRight)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Time
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding (encodeParam)
import Hmssql.Errors (EncodeError)
import Hmssql.Tds.Context (defaultTdsContext)
import TestDb

spec :: Spec
spec = do
    describe "UTC negative day clocks (pure)" $ do
        forM_ [-1, 0, 1] $ \neighbor ->
            it ("refuses an Int hour modulus with neighboring second " ++ show neighbor) $
                encodeParam fieldEncoder defaultTdsContext (badClock neighbor) `shouldSatisfy` isLeft
        it "retains correct negative clocks, leap seconds and existing positive-clock validation" $ do
            forM_ neighbors $ \(_, value, _) -> encodeParam fieldEncoder defaultTdsContext value `shouldSatisfy` isRight
            forM_ [86401, 90000] $ \seconds -> encodeParam fieldEncoder defaultTdsContext (UTCTime epoch (secondsToDiffTime seconds)) `shouldSatisfy` isLeft
    around withTestDb $ do
        forM_ [-1, 0, 1] $ \neighbor ->
            it ("does not store a wrapped UTC clock as an unrelated finite datetime2, neighbor=" ++ show neighbor) $ \conn -> do
                void $ execute conn "CREATE TABLE #utc_bad(v datetime2(7))"
                result <- try (execute conn (mkQuery "INSERT INTO #utc_bad VALUES(@p1)" (Only (badClock neighbor))))
                case result of
                    Left (_ :: EncodeError) -> query1 conn "SELECT COUNT(*) FROM #utc_bad" `shouldReturn` Only (0 :: Int32)
                    Right _ -> do
                        Only actual <- query1 conn "SELECT v FROM #utc_bad" :: IO (Only LocalTime)
                        expectationFailure ("out-of-range UTC clock was stored as " ++ show actual)
        forM_ neighbors $ \(label, value, literal) ->
            it ("preserves the independent server instant for " ++ label) $ \conn -> do
                query1 conn (mkQuery "SELECT CONVERT(bit,CASE WHEN @p1=CONVERT(datetime2(7),@p2,126) THEN 1 ELSE 0 END)" (value, literal)) `shouldReturn` Only True
                void $ execute conn "CREATE TABLE #utc_neighbor(id int,v datetime2(7))"
                bulkInsert conn "#utc_neighbor" [(1 :: Int32, value)] `shouldReturn` 1
                query1 conn (mkQuery "SELECT CONVERT(bit,CASE WHEN v=CONVERT(datetime2(7),@p1,126) THEN 1 ELSE 0 END) FROM #utc_neighbor" (Only literal)) `shouldReturn` Only True
        forM_ [False, True] $ \wrapped ->
            it ("retains only intended batches after a bad UTC encoder, wrapper=" ++ show wrapped) $ \conn -> do
                void $ execute conn "CREATE TABLE #utc_batches(id int,v datetime2(7))"
                let action = void $ bulkInsertWith (bulkCopy "#utc_batches"){bulkBatchSize = Just 1} conn [(1 :: Int32, UTCTime epoch 0), (2, badClock 0), (3, UTCTime epoch 1)]
                (if wrapped then withTransaction conn action else action) `shouldThrow` (\(_ :: EncodeError) -> True)
                query conn "SELECT id FROM #utc_batches ORDER BY id" `shouldReturn` [Only (1 :: Int32) | not wrapped]
                void $ execute conn "INSERT INTO #utc_batches VALUES(10,'2000-01-02')"
                withTransaction conn (execute conn "INSERT INTO #utc_batches VALUES(20,'2000-01-03')" >> throwIO (userError "independent UTC rollback")) `shouldThrow` anyIOException
                query conn "SELECT id FROM #utc_batches ORDER BY id" `shouldReturn` map Only (if wrapped then [10] else [1, 10 :: Int32])

epoch :: Day
epoch = fromGregorian 2000 1 1
badClock :: Integer -> UTCTime
badClock neighbor = UTCTime epoch (secondsToDiffTime (negate (3600 * 2 * (toInteger (maxBound :: Int) + 1)) + neighbor))
neighbors :: [(String, UTCTime, Text)]
neighbors =
    compensated
        ++ [ ("negative second", UTCTime epoch (secondsToDiffTime (-1)), "1999-12-31T23:59:59")
           , ("negative day", UTCTime epoch (secondsToDiffTime (-86400)), "1999-12-31T00:00:00")
           , ("negative day and second", UTCTime epoch (secondsToDiffTime (-86401)), "1999-12-30T23:59:59")
           , ("negative picosecond", UTCTime epoch (picosecondsToDiffTime (-1)), "2000-01-01T00:00:00")
           , ("negative half tick", UTCTime epoch (picosecondsToDiffTime (-50000)), "2000-01-01T00:00:00")
           , ("below negative half tick", UTCTime epoch (picosecondsToDiffTime (-50001)), "1999-12-31T23:59:59.9999999")
           , ("exact negative tick", UTCTime epoch (picosecondsToDiffTime (-100000)), "1999-12-31T23:59:59.9999999")
           , ("ordinary epoch", UTCTime epoch 0, "2000-01-01T00:00:00")
           , ("leap second carry", UTCTime epoch 86400, "2000-01-02T00:00:00")
           , ("upper leap-second clamp", UTCTime (fromGregorian 9999 12 31) 86400, "9999-12-31T23:59:59.9999999")
           , ("negative clock brings date into range", UTCTime (fromGregorian 10000 1 1) (secondsToDiffTime (-1)), "9999-12-31T23:59:59")
           ]

-- The day and clock are both unbounded; only their resulting SQL date matters.
compensated :: [(String, UTCTime, Text)]
compensated =
    [ ("compensated huge clock " ++ show neighbor, UTCTime (addDays carry epoch) (secondsToDiffTime (negate seconds + neighbor)), literal)
    | (neighbor, literal) <- [(-1, "1999-12-31T23:59:59"), (0, "2000-01-01T00:00:00"), (1, "2000-01-01T00:00:01")]
    ]
  where
    seconds = 86400 * 3600 * 2 * (toInteger (maxBound :: Int) + 1)
    carry = seconds `div` 86400
