-- | A non-streaming query interrupted part-way on a MARS connection, found
-- by the model tests ("Model.ConnectionSpec", a 'System.Timeout.timeout'
-- around 'query').  The response is the caller's to read no more: as
-- after an interrupted read of a stream, the next request drains it, and
-- so do the transaction functions' checks, so it doesn't stay unfinished
-- and a transaction can begin ('TransactionRequestsActive' otherwise).
-- Here the interruption lands in a 'queryFold' step, after the whole
-- (one-packet) response has arrived, so no Attention is needed to end it.
-- ("Concurrency.InterruptedRequestSpec" covers the same ground on the
-- test configuration's connection, a MARS one with @HMSSQL_TEST_MARS=1@;
-- this one is always MARS.)
--
-- The same for 'runBatchQuery', whose consumers read the response as
-- 'query' does but which sends its messages itself (found in the MARS
-- review: an interruption in a 'batchQueryFold' step left the message's
-- response open, holding its session, and every later transaction
-- refused with 'TransactionRequestsActive' until 'release').
module Query.MarsInterruptedReadSpec (spec) where

import qualified RecipeState
import Control.Concurrent (threadDelay)
import Data.Int (Int32, Int64)
import Data.IORef (readIORef)
import Data.Text (Text)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import Hmssql.Connection.Internal (ActiveResponse (..))
import Hmssql.Transaction
import OpenResponses (openResponses, openStatements)
import TestDb

-- | A MARS connection whose last query was interrupted in a fold step.
withInterrupted :: (Connection -> IO a) -> IO a
withInterrupted act = do
  ci <- defaultTestConnectInfo
  withConnection ci { connectMars = True } $ \conn -> do
    r <- timeout 200_000 $ queryFold conn "SELECT 1 UNION ALL SELECT 2" (0 :: Int32) $ \acc (Only x) ->
      (acc + x) <$ threadDelay 2_000_000
    r `shouldBe` Nothing
    act conn

-- | A MARS connection whose last 'runBatchQuery' was interrupted in a
-- 'batchQueryFold' step: of a response that had fully arrived (two rows),
-- or, with @big@, of one still arriving.
withInterruptedBatch :: Bool -> (Connection -> IO a) -> IO a
withInterruptedBatch big act = do
  ci <- defaultTestConnectInfo
  withConnection ci { connectMars = True } $ \conn -> do
    let sql = if big then bigSql else "SELECT CAST(1 AS bigint) UNION ALL SELECT 2"
    r <- timeout 200_000 $ runBatchQuery conn $ (,)
      <$> batchExecute "SELECT 1"
      <*> batchQueryFold (rawSql sql) (0 :: Int64) (\acc (Only x) -> (acc + x) <$ threadDelay 2_000_000)
    r `shouldBe` Nothing
    act conn

-- | A million rows: far more than the window, so the response is still
-- arriving when the fold's step is interrupted.
bigSql :: Text
bigSql = "SELECT TOP 1000000 CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | A transaction begins, and rolls back.
transactionWorks :: Connection -> IO ()
transactionWorks conn = do
  begin conn
  inTransaction conn `shouldReturn` True
  rollback conn
  inTransaction conn `shouldReturn` False

spec :: Spec
spec = do
  describe "a query interrupted part-way on a MARS connection" $ do
    it "is drained by the next request: a transaction can begin afterwards" $
      withInterrupted $ \conn -> do
        query1 conn "SELECT CAST(7 AS int)" `shouldReturn` Only (7 :: Int32)
        transactionWorks conn
    it "is drained by the begin's check, with no request in between" $
      withInterrupted transactionWorks
    it "is drained by withTransaction's check, with no request in between" $
      withInterrupted $ \conn ->
        withTransaction conn (query1 conn "SELECT CAST(3 AS int)") `shouldReturn` Only (3 :: Int32)

  describe "a batch query interrupted in a consumer's step on a MARS connection" $ do
    it "is drained by the next request: nothing is left open, and a transaction can begin afterwards" $
      withInterruptedBatch False $ \conn -> do
        query1 conn "SELECT CAST(7 AS int)" `shouldReturn` Only (7 :: Int32)
        openStatements conn `shouldReturn` []
        transactionWorks conn
    it "is drained by withTransaction's check, with no request in between" $
      withInterruptedBatch False $ \conn ->
        withTransaction conn (query1 conn "SELECT CAST(3 AS int)") `shouldReturn` Only (3 :: Int32)
    it "while its response still arrives: the statement is cancelled at once (an Attention), and the next request drains it" $
      withInterruptedBatch True $ \conn -> do
        [ar] <- openResponses conn
        RecipeState.attentionSent ar `shouldReturn` True
        -- Named by its last statement, as TransactionRequestsActive would.
        arStatement ar `shouldBe` Just bigSql
        query1 conn "SELECT CAST(7 AS int)" `shouldReturn` Only (7 :: Int32)
        openStatements conn `shouldReturn` []
        transactionWorks conn
