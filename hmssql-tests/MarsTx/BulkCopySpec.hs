-- | Bulk copy ("Hmssql.BulkCopy") on a MARS connection (docs/dev/mars-research.md
-- A42, A43): a load runs on one reserved session, across all its batches,
-- while other sessions are opened, freed and closed; it is exact; a
-- producer failure is recovered on that session.  What the server
-- requires of a load beside other open responses (@XACT_ABORT ON@, error
-- 595 otherwise; in a transaction, no other request on the table, 3970)
-- is documented, not prevented: the tests pin it.
module MarsTx.BulkCopySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception
import Control.Monad (forM_, replicateM, void)
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int32, Int64)
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (ConnectionBroken (..))
import Hmssql.Query
import Hmssql.Transaction
import MarsTx.Harness

type Item = (Int32, Text)

items :: Int32 -> Int32 -> Stream (Of Item) IO ()
items from to = S.each [(i, T.pack (show i)) | i <- [from .. to]]

-- | A table of 'Item's.
withItems :: Text -> (Text -> IO a) -> IO a
withItems prefix = withTable prefix "i int NOT NULL, s nvarchar(30) NOT NULL"

-- | @(COUNT(*), SUM(i), rows whose s isn't i)@ of an item table.
summary :: Connection -> Text -> IO (Int, Int64, Int)
summary conn t = query1 conn $ rawSql $
  "SELECT COUNT(*), ISNULL(SUM(CAST(i AS bigint)), 0), \
  \  ISNULL(SUM(CASE WHEN s = CAST(i AS nvarchar(30)) THEN 0 ELSE 1 END), 0) FROM " <> t

-- | The summary of items @1 .. n@.
exactly :: Int -> (Int, Int64, Int)
exactly n = (n, fromIntegral n * (fromIntegral n + 1) `div` 2, 0)

-- | Fail instead of hanging.
within :: Int -> IO a -> IO a
within seconds act = timeout (seconds * 1_000_000) act >>= \case
  Just a -> pure a
  Nothing -> throwIO (userError ("timed out after " ++ show seconds ++ " s"))

-- | The stream, recording the session the load's requests go on (the
-- reserved one) before each row is pulled.
recordingSession :: Connection -> IORef [Maybe Int] -> Stream (Of a) IO r -> Stream (Of a) IO r
recordingSession conn seen = S.mapM $ \a -> do
  sid <- reservedSid conn
  modifyIORef' seen (sid :)
  pure a

spec :: Spec
spec = do
  describe "A42: a load over a MARS connection" $ do
    it "is exact: 100,000 rows in one batch, and in several (bulkBatchSize 30,000)" $ withItems "marstx_bulk" $ \t -> withMarsConn $ \conn ->
      forM_ [Nothing, Just 30_000] $ \batch -> do
        _ <- execute conn (rawSql ("TRUNCATE TABLE " <> t))
        bulkInsertSWith (bulkCopy t) { bulkBatchSize = batch } conn (items 1 100_000) `shouldReturn` 100_000
        summary conn t `shouldReturn` exactly 100_000
        noResponseOpen conn
        reservedSid conn `shouldReturn` Nothing

    forM_ [(Nothing, 0), (Just 20_000, 40_000)] $ \(batch, kept) ->
      it ("recovers from a producer failure half-way (bulkBatchSize " ++ show batch ++ "): the exception propagates, the connection is usable, " ++ show kept ++ " rows loaded (the batches before), and its session is free again") $ withItems "marstx_bulk_fail" $ \t -> withMarsConn $ \conn -> do
        seen <- newIORef []
        let failing = recordingSession conn seen (items 1 50_000) >> liftIO (throwIO (userError "producer"))
        r <- try (bulkInsertSWith (bulkCopy t) { bulkBatchSize = batch } conn failing)
        either (\(e :: IOException) -> show e `shouldContain` "producer") (\n -> expectationFailure ("loaded " ++ show n)) r
        sids <- nub <$> readIORef seen
        length sids `shouldBe` 1
        reservedSid conn `shouldReturn` Nothing
        noResponseOpen conn
        -- The session it used is open and idle, and taken first.
        [Just sid] <- pure sids
        (sid `elem`) <$> openSids conn `shouldReturn` True
        fst3 <$> summary conn t `shouldReturn` kept
        -- The next load works.
        _ <- execute conn (rawSql ("TRUNCATE TABLE " <> t))
        bulkInsertSWith (bulkCopy t) conn (items 1 1000) `shouldReturn` 1000
        summary conn t `shouldReturn` exactly 1000

  describe "A43: a load beside another open response (documented, not prevented)" $ do
    it "with a stream open on another session and XACT_ABORT OFF fails with 595; the stream then reads on to its end; with XACT_ABORT ON the load is exact" $ withItems "marstx_bulk595" $ \t -> withMarsConn $ \conn -> do
      (_, s0) <- openWide conn 100_000
      Right (_, s) <- S.next s0
      bulkInsertSWith (bulkCopy t) conn (items 1 1000) `failsWithSql` 595
      fst3 <$> summary conn t `shouldReturn` 0
      length <$> S.toList_ s `shouldReturn` 99_999
      noResponseOpen conn
      _ <- execute conn "SET XACT_ABORT ON"
      (_, s0') <- openWide conn 100_000
      Right (_, s') <- S.next s0'
      bulkInsertSWith (bulkCopy t) conn (items 1 1000) `shouldReturn` 1000
      summary conn t `shouldReturn` exactly 1000
      length <$> S.toList_ s' `shouldReturn` 99_999

    forM_ [Nothing, Just 7_000] $ \batch ->
      it ("copies a table into another from a queryS stream on the same connection, opened before, under XACT_ABORT ON: exact (bulkBatchSize " ++ show batch ++ ")") $ withItems "marstx_bulk_src" $ \src -> withItems "marstx_bulk_dst" $ \dst -> withMarsConn $ \conn -> do
        bulkInsertSWith (bulkCopy src) conn (items 1 100_000) `shouldReturn` 100_000
        _ <- execute conn "SET XACT_ABORT ON"
        rows <- queryS conn (rawSql ("SELECT i, s FROM " <> src)) :: IO (Stream (Of Item) IO ())
        within 120 (bulkInsertSWith (bulkCopy dst) { bulkBatchSize = batch } conn rows) `shouldReturn` 100_000
        summary conn dst `shouldReturn` exactly 100_000
        fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM (SELECT i, s FROM " <> src <> " EXCEPT SELECT i, s FROM " <> dst <> ") AS d"))
          `shouldReturn` (0 :: Int)
        noResponseOpen conn

    it "inside a transaction, with nothing else open: the load commits and rolls back with it" $ withItems "marstx_bulk_tx" $ \t -> withMarsConn $ \conn -> do
      withTransaction conn $ void $ bulkInsertSWith (bulkCopy t) conn (items 1 1000)
      r <- try $ withTransaction conn $ do
        void $ bulkInsertSWith (bulkCopy t) conn (items 1001 2000)
        fst3 <$> summary conn t `shouldReturn` 2000
        throwIO (userError "roll back")
      either (\(_ :: IOException) -> pure ()) (\() -> expectationFailure "committed") r
      summary conn t `shouldReturn` exactly 1000

    -- The stream must still be executing when the load arrives: with the
    -- suite's largest packets its 100,000 rows would fit the window.
    it "inside a transaction, with a stream over the same table open, under XACT_ABORT ON: the load fails with 3970, the transaction is lost, and the stream ends with 3998" $ withItems "marstx_bulk3970" $ \t -> withMarsConnWith (\ci -> ci { connectPacketSize = min 8000 (connectPacketSize ci) }) $ \conn -> do
      bulkInsertSWith (bulkCopy t) conn (items 1 100_000) `shouldReturn` 100_000
      _ <- execute conn "SET XACT_ABORT ON"
      begin conn
      (_, s0) <- openS conn ("SELECT i, s FROM " <> t)
      Right (_ :: Item, s) <- S.next s0
      bulkInsertSWith (bulkCopy t) conn (items 100_001 101_000) `failsWithSql` 3970
      inTransaction conn `shouldReturn` False
      -- The stream delivers the rest of its rows, then ends with 3998.
      readCounting s `shouldReturn` (99_999, 3998)
      noResponseOpen conn
      tranCount conn `shouldReturn` 0
      summary conn t `shouldReturn` exactly 100_000

  -- docs/dev/design.md "Sends": an interrupted send breaks the whole MARS
  -- connection (a decided trade-off), whichever session it was on.
  describe "an interrupted load" $
    it "(a timeout while the rows are being sent) breaks the connection, and the stream open beside it" $ withItems "marstx_bulk_interrupt" $ \t -> withMarsConn $ \conn -> do
      (_, s0) <- openWide conn 100_000
      Right (_, s) <- S.next s0
      -- Interrupted 100 ms after the load took its first row, as in
      -- "Bulk.CopySpec": a timeout from the start can fire before the
      -- load has begun to send.
      started <- newEmptyMVar
      let slow = S.mapM (\i -> tryPutMVar started () >> threadDelay 1_000 >> pure i) (items 1 100_000)
      race (takeMVar started >> threadDelay 100_000) (bulkInsertSWith (bulkCopy t) conn slow) `shouldReturn` Left ()
      (query1 conn "SELECT 1" :: IO (Only Int)) `shouldThrow` \(ConnectionBroken _) -> True
      S.effects s `shouldThrow` \(ConnectionBroken _) -> True
      release conn `shouldReturn` False

  describe "the load's session" $ do
    it "stays the same across every batch of a load while the sessions of 15 streams it reads are freed and closed (FIN) meanwhile" $ withItems "marstx_bulk_sid" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      streams <- replicateM 15 (snd <$> openWide conn 1000)
      busySids conn `shouldReturn` [0 .. 14]
      seen <- newIORef []
      openCounts <- newIORef []
      let item i = (i, T.pack (show i))
          rows = S.for (S.each (zip [0 :: Int32 ..] streams)) $ \(k, st) ->
            S.map (\(i, _) -> item (k * 1000 + i)) st
          recorded = S.chain (\_ -> openSids conn >>= \sids -> modifyIORef' openCounts (length sids :)) (recordingSession conn seen rows)
      within 120 (bulkInsertSWith (bulkCopy t) { bulkBatchSize = Just 700 } conn recorded) `shouldReturn` 15_000
      summary conn t `shouldReturn` exactly 15_000
      sids <- nub <$> readIORef seen
      sids `shouldBe` [Just 15]
      counts <- readIORef openCounts
      -- Sessions were closed during the load.
      minimum counts `shouldSatisfy` (< 16)
      noResponseOpen conn
      _ <- query1 conn "SELECT 1" :: IO (Only Int)
      length <$> openSids conn `shouldReturn` 10

    it "loads beside 30 other streams opened and closed around each load: exact, and the idle sessions are closed down to 10 (5 rounds)" $ withItems "marstx_bulk_churn" $ \t -> withMarsConn $ \conn -> do
      forM_ [0 .. 4 :: Int32] $ \k -> do
        streams <- replicateM 30 (openWide conn 10)
        length <$> busySids conn `shouldReturn` 30
        forM_ (zip [0 :: Int ..] streams) $ \(j, (r, s)) ->
          if even j then S.effects s else cancelResponse r
        noResponseOpen conn
        bulkInsertSWith (bulkCopy t) conn (items (k * 1000 + 1) (k * 1000 + 1000)) `shouldReturn` 1000
        -- Ten idle, and the load's, reserved while the others were closed.
        length <$> openSids conn `shouldReturn` 11
        after <- replicateM 30 (openWide conn 10)
        mapM_ (S.effects . snd) after
        summary conn t `shouldReturn` exactly (fromIntegral (k + 1) * 1000)
      length <$> openSids conn `shouldReturn` 10
  where
    fst3 (a, _, _) = a
