{-# LANGUAGE DerivingStrategies #-}

-- | Cancelling long server-side work: a WAITFOR, a request blocked on a lock
-- held by another connection, a large result being streamed; nested
-- timeouts.  The interrupted request sends the Attention itself, so the
-- cancellation must return promptly, the work must stop on the server
-- promptly without the connection being used again, and the next request
-- must finish the cancellation (drain up to the acknowledgement) promptly
-- too.
module Concurrency.CancelSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (void, when)
import Data.Int (Int16, Int64)
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import TestDb

bigQuery :: Query
bigQuery = rawSql bigQueryText

bigQueryText :: Text
bigQueryText = "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), REPLICATE('x', 50) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | A hundred times 'bigQuery': over a minute of reading, for a test whose
-- request must still be reading when it is interrupted.
endlessQuery :: Query
endlessQuery = "SELECT TOP 100000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), REPLICATE('x', 50) FROM sys.all_columns a CROSS JOIN sys.all_columns b CROSS JOIN sys.all_columns c"

spid :: Connection -> IO Int16
spid conn = fromOnly <$> query1 conn "SELECT CAST(@@SPID AS smallint)"

-- | The session's current request, as another connection sees it:
-- (command, wait type).
currentRequest :: Connection -> Int16 -> IO (Maybe (Text, Maybe Text))
currentRequest observer sid =
  queryMay observer (mkQuery "SELECT command, wait_type FROM sys.dm_exec_requests WHERE session_id = @p1" (Only sid))

-- | Prompt: well under the 10 s the cancelled work would take.
prompt :: Double
prompt = 2

-- | Poll (for up to 'prompt' seconds) until the session has no current
-- request.  Whether it got there.
waitUntilIdle :: Connection -> Int16 -> IO Bool
waitUntilIdle observer sid = go (0 :: Int)
  where
    go n = currentRequest observer sid >>= \case
      Nothing -> pure True
      Just _
        | fromIntegral n * 0.02 >= prompt -> pure False
        | otherwise -> threadDelay 20_000 >> go (n + 1)

spec :: Spec
spec = around withTestDb $ do
  describe "WAITFOR" $ do
    it "is interrupted by a timeout promptly, and the next request finishes the cancellation promptly" $ \conn -> do
      (r, t) <- elapsed $ timeout 100_000 (execute conn "WAITFOR DELAY '00:00:10'")
      r `shouldBe` Nothing
      t `shouldSatisfy` (< 1)
      (_, t2) <- elapsed (within 10 (expectUsable conn))
      t2 `shouldSatisfy` (< prompt)

    -- An interruption never waits for the server, in a scope as in a
    -- plain call: the exit doesn't drain.
    it "a timeout around withQueryS over it returns promptly, and the next request finishes the cancellation promptly" $ \conn -> do
      (r, t) <- elapsed $ timeout 100_000 $
        withQueryS conn "WAITFOR DELAY '00:00:10'; SELECT CAST(1 AS bigint)" $ \s ->
          S.length_ (s :: Stream (Of (Only Int64)) IO ())
      r `shouldBe` Nothing
      t `shouldSatisfy` (< 1)
      (_, t2) <- elapsed (within 10 (expectUsable conn))
      t2 `shouldSatisfy` (< prompt)

    it "stops running on the server once the connection is used again" $ \conn -> withTestDb $ \observer -> do
      sid <- spid conn
      r <- timeout 100_000 (execute conn "WAITFOR DELAY '00:00:10'")
      r `shouldBe` Nothing
      -- The interrupted request sent the Attention; this one drains up to
      -- its acknowledgement.
      within 10 (expectUsable conn)
      currentRequest observer sid `shouldReturn` Nothing

    -- The Attention is sent by the interrupted request, not left for the
    -- next one: the WAITFOR stops at once although the connection is not
    -- touched again until it has.
    serial $ it "stops running on the server at once, before the connection is used again" $ \conn -> withTestDb $ \observer -> do
      sid <- spid conn
      done <- newEmptyMVar
      _ <- forkIO $ timeout 500_000 (execute conn "WAITFOR DELAY '00:00:10'") >>= putMVar done
      -- Running on the server (as the observer sees it) ...
      let waitRunning n = currentRequest observer sid >>= \case
            Just _ -> pure True
            Nothing | n >= (100 :: Int) -> pure False
                    | otherwise -> threadDelay 10_000 >> waitRunning (n + 1)
      waitRunning 0 `shouldReturn` True
      -- ... until the timeout fires.
      within 10 (takeMVar done) `shouldReturn` Nothing
      (idle, t) <- elapsed (waitUntilIdle observer sid)
      idle `shouldBe` True
      t `shouldSatisfy` (< prompt)
      within 10 (expectUsable conn)

    it "is interrupted by killThread from another thread" $ \conn -> do
      done <- newEmptyMVar
      tid <- forkIO $ try @SomeException (execute conn "WAITFOR DELAY '00:00:10'") >>= putMVar done
      threadDelay 100_000
      (_, t) <- elapsed (killThread tid >> within 5 (takeMVar done))
      t `shouldSatisfy` (< 1)
      (_, t2) <- elapsed (within 10 (expectUsable conn))
      t2 `shouldSatisfy` (< prompt)

  describe "a request blocked on another connection's lock" $
    it "is cancelled promptly, stops waiting on the lock at once (before the connection is used again), and has left nothing behind" $ \conn -> withTestDb $ \holder -> withTestDb $ \observer -> do
      table <- ("##" <>) <$> uniqueName "conc_lock"
      _ <- execute holder (rawSql ("CREATE TABLE " <> table <> " (id int PRIMARY KEY, v int); INSERT INTO " <> table <> " VALUES (1, 0)"))
      sid <- spid conn
      withTransaction holder $ do
        _ <- execute holder (rawSql ("UPDATE " <> table <> " SET v = 1 WHERE id = 1"))
        (r, t) <- elapsed $ timeout 300_000 (query conn (rawSql ("SELECT v FROM " <> table <> " WHERE id = 1")) :: IO [Only Int])
        r `shouldBe` Nothing
        t `shouldSatisfy` (< 1)
        -- No longer queued on the lock, although it is still held and the
        -- connection has not been used again: the interrupted request sent
        -- the Attention.
        waitUntilIdle observer sid `shouldReturn` True
        -- And the next request finishes the cancellation promptly.
        (_, t2) <- elapsed (within 10 (expectUsable conn))
        t2 `shouldSatisfy` (< prompt)
        currentRequest observer sid `shouldReturn` Nothing
      -- And the cancelled SELECT did not leave the reader holding anything.
      query1 conn (rawSql ("SET LOCK_TIMEOUT 2000; SELECT v FROM " <> table <> " WHERE id = 1")) `shouldReturn` Only (1 :: Int)

  describe "a large result" $ do
    it "materializing: a timeout returns promptly and the next request is prompt" $ \conn -> do
      -- Repeated: an interruption landing between consuming a token and
      -- recording its effects used to garble the next request's read.
      -- Under MARS the read also sends window updates (SMP ACKs), and a
      -- timeout that lands in one breaks the connection: a known bug.
      -- A result that can't all arrive within the timeout: the million
      -- rows of 'bigQuery' are read in 170 to 230 ms over a plaintext
      -- connection, which a timeout of 100 ms delivered late, on a busy
      -- machine, doesn't interrupt.
      let go i = when (i <= (30 :: Int)) $ do
            (r, t) <- elapsed $ timeout 100_000 (query conn endlessQuery :: IO [(Int64, Text)])
            fmap length r `shouldBe` Nothing
            t `shouldSatisfy` (< 1)
            (h, t2) <- elapsed (within 10 (checkHealth conn))
            case h of
              Usable -> (t2 `shouldSatisfy` (< prompt)) >> go (i + 1)
              Broken cause -> throwIO (userError ("connection broken: " ++ show cause))
      go 1

    -- Under MARS the next request leaves the stream open beside it, and is
    -- prompt; cancelling the stream is prompt too.
    it "streaming: abandoning the stream mid-way, the next request is prompt" $ \conn -> do
      s <- queryS conn bigQuery
      n <- S.length_ (S.take 1000 (s :: S.Stream (S.Of (Int64, Text)) IO ()))
      n `shouldBe` 1000
      mars <- testMars
      (_, t) <- elapsed (within 10 (expectUsableBeside [bigQueryText | mars] conn))
      t `shouldSatisfy` (< prompt)
      when mars $ do
        (_, t2) <- elapsed (within 10 (cancelActiveStatement conn))
        t2 `shouldSatisfy` (< prompt)
        expectUsable conn

    it "streaming: a consumer killed mid-way, the next request is prompt" $ \conn -> do
      started <- newEmptyMVar
      done <- newEmptyMVar
      tid <- forkIO $ do
        r <- try $ do
          s <- queryS conn bigQuery
          S.mapM_ (\(i :: Int64, _ :: Text) -> if i == 5000 then putMVar started () else pure ()) s
        putMVar done (r :: Either SomeException ())
      within 10 (takeMVar started)
      killThread tid
      within 10 (takeMVar done) >>= either (\e -> fromException e `shouldBe` Just ThreadKilled) (\() -> expectationFailure "finished")
      -- Under MARS the kill cancels the stream only if it lands in a read;
      -- landing between two rows it leaves the stream open, as abandoning
      -- it does, and the next request runs beside it.
      mars <- testMars
      (_, t) <- elapsed (within 10 (if mars then settleInterruptedStream conn bigQueryText >> expectUsable conn else expectUsable conn))
      t `shouldSatisfy` (< prompt)

  describe "nested timeouts" $ do
    it "the inner timeout firing leaves the outer one and the connection intact" $ \conn -> do
      r <- timeout 5_000_000 (timeout 100_000 (execute conn "WAITFOR DELAY '00:00:10'"))
      r `shouldBe` Just Nothing
      within 10 (expectUsable conn)

    it "the outer timeout firing inside the inner one" $ \conn -> do
      (r, t) <- elapsed $ timeout 100_000 (timeout 5_000_000 (execute conn "WAITFOR DELAY '00:00:10'"))
      r `shouldBe` Nothing
      t `shouldSatisfy` (< 1)
      within 10 (expectUsable conn)

    it "an inner timeout inside a transaction lets the transaction go on" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nt (i int)"
      withTransaction conn $ do
        _ <- execute conn "INSERT INTO #nt VALUES (1)"
        r <- timeout 100_000 (execute conn "WAITFOR DELAY '00:00:10'")
        r `shouldBe` Nothing
        void $ execute conn "INSERT INTO #nt VALUES (2)"
      query conn "SELECT i FROM #nt ORDER BY i" `shouldReturn` [Only (1 :: Int), Only 2]
      within 10 (expectUsable conn)

    it "a timeout around a whole transaction interrupting an inner timeout's query rolls back" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nt2 (i int)"
      r <- timeout 300_000 $ withTransaction conn $ do
        _ <- execute conn "INSERT INTO #nt2 VALUES (1)"
        timeout 5_000_000 (execute conn "WAITFOR DELAY '00:00:10'")
      r `shouldBe` Nothing
      query1 conn "SELECT COUNT(*) FROM #nt2" `shouldReturn` Only (0 :: Int)
      within 10 (expectUsable conn)
