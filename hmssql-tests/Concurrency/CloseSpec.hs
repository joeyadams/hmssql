{-# LANGUAGE DerivingStrategies #-}

-- | Closing connections while they are in use, closing twice, interrupting
-- 'close' and 'connect', many connections at once, and connections dropped
-- without 'close': none may hang, throw a confusing error, or leave a
-- server session behind.
module Concurrency.CloseSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async (concurrently_, forConcurrently_, mapConcurrently_)
import Control.Exception
import Control.Monad (forM_, replicateM_, void, when)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Connection.Locking (mutexOwner)
import TestDb

-- | Test settings with a unique application name, to count sessions by.
appInfo :: Text -> IO (ConnectInfo, Text)
appInfo prefix = do
  app <- uniqueAppName prefix
  ci <- defaultTestConnectInfo
  pure (ci { connectApplicationName = app }, app)

waitForOwner :: Connection -> IO ()
waitForOwner conn = within 10 loop
  where
    loop = mutexOwner (connMutex conn) >>= \case
      Just _ -> pure ()
      Nothing -> threadDelay 1000 >> loop

-- | Some work of every kind, which may be interrupted anywhere.
mixedWork :: Int -> Connection -> IO ()
mixedWork i conn = do
  v <- nextId
  Only v' <- query1 conn ("SELECT " <> param v)
  when (v' /= v) $ throwIO (userError ("DESYNC: " ++ show (v, v')))
  _ <- execute conn "CREATE TABLE #w (i int)"
  withTransaction conn $ void $ execute conn ("INSERT INTO #w VALUES (" <> param i <> ")")
  s <- queryS conn "SELECT TOP 100000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
  _ <- S.length_ (S.take (i * 100) s :: S.Stream (S.Of (Only Int64)) IO ())
  _ <- execute conn "WAITFOR DELAY '00:00:00.020'"
  n <- query1 conn "SELECT COUNT(*) FROM #w"
  when (n /= Only (1 :: Int)) $ throwIO (userError ("wrong count " ++ show n))

-- | A connection opened and then dropped without being closed, once its
-- session (the only one with the given application name) has been seen.
-- Not inlined, so nothing in the caller keeps it alive.
openAndDrop :: ConnectInfo -> Text -> IO ()
openAndDrop ci app = do
  conn <- connect ci
  Only (1 :: Int) <- query1 conn "SELECT 1"
  sessionCount app `shouldReturn` 1
  -- Still in use here, so it can't have been collected before the count.
  Only (2 :: Int) <- query1 conn "SELECT 2"
  pure ()
{-# NOINLINE openAndDrop #-}

spec :: Spec
spec = do
  describe "close racing with use" $ do
    it "fails a query in flight on another thread promptly with a synchronous exception" $ do
      (ci, _) <- appInfo "conc_close_inflight"
      conn <- connect ci
      result <- newEmptyMVar
      _ <- forkIO $ try (execute conn "WAITFOR DELAY '00:00:10'") >>= putMVar result
      waitForOwner conn
      threadDelay 100_000
      within 5 (close conn)
      r <- within 5 (takeMVar result)
      case r of
        Right n -> expectationFailure ("the query finished: " ++ show n)
        -- An asynchronous exception type (e.g. ThreadKilled from the stopped
        -- reader thread) would look to the caller as if its own thread had
        -- been killed, and escape handlers for synchronous exceptions.
        Left e -> (show e, isAsync e) `shouldSatisfy` (not . snd)

    it "refuses requests after close promptly with a synchronous exception, every time" $ do
      (ci, _) <- appInfo "conc_close_after"
      conn <- connect ci
      close conn
      forM_ [1 .. 3 :: Int] $ \_ -> do
        r <- within 5 (try (query1 conn "SELECT 1" :: IO (Only Int)))
        case r of
          Right v -> expectationFailure ("answered after close: " ++ show v)
          Left e -> (show e, isAsync e) `shouldSatisfy` (not . snd)

    it "closing while a stream is being consumed on another thread ends the consumer promptly" $ do
      (ci, _) <- appInfo "conc_close_stream"
      conn <- connect ci
      started <- newEmptyMVar
      result <- newEmptyMVar
      _ <- forkIO $ do
        r <- try $ do
          s <- queryS conn "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
          S.mapM_ (\(Only (i :: Int64)) -> when (i == 1000) (putMVar started ()) >> when (i > 1000) yield) s
        putMVar result r
      within 10 (takeMVar started)
      within 5 (close conn)
      r <- within 5 (takeMVar result)
      case r of
        Right () -> pure ()  -- it may have raced to the end
        Left e -> (show e, isAsync e) `shouldSatisfy` (not . snd)

    it "closing twice, even from two threads at once, is harmless" $ do
      (ci, app) <- appInfo "conc_close_twice"
      replicateM_ 10 $ do
        conn <- connect ci
        within 10 (concurrently_ (close conn) (close conn))
        within 10 (close conn)
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

    it "a close interrupted at a random point can be completed by closing again" $ do
      (ci, app) <- appInfo "conc_close_killed"
      forM_ (concat (replicate 5 [Yields 0, Yields 5, Micros 50, Micros 300, Micros 2000])) $ \d -> do
        conn <- connect ci
        _ <- interruptWith ViaKillThread d (close conn)
        within 10 (close conn)
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

  describe "sessions" $ do
    it "50 connections with mixed work, some killed at random points, leave no sessions behind" $ do
      (ci, app) <- appInfo "conc_many"
      failures <- newMVar []
      within 120 $ forConcurrently_ [1 .. 50 :: Int] $ \i -> do
        let delay = [Micros 0, Micros 5_000, Micros 20_000, Micros 60_000, Micros 150_000] !! (i `mod` 5)
            work = withConnection ci (mixedWork i)
        r <- if i `mod` 3 == 0 then Right <$> work else interruptWith ViaKillThread delay work
        case r of
          Left e | not (isAsync e) -> modifyMVar_ failures (pure . ((i, show e) :))
          _ -> pure ()
      readMVar failures `shouldReturn` []
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

    it "connecting interrupted at random points leaves no sessions behind" $ do
      (ci, app) <- appInfo "conc_connect_killed"
      forM_ [0, 500 .. 30_000] $ \d ->
        void $ interruptWith ViaKillThread (Micros d) (withConnection ci (\_ -> pure ()))
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

    it "a connection dropped without close is closed once it is garbage" $ do
      (ci, app) <- appInfo "conc_dropped"
      openAndDrop ci app
      -- Its reader thread must not keep it reachable forever.
      waitForSessionCount 10 performMajorGC app 0 `shouldReturn` 0

    it "a connection dropped without close is closed once it is garbage (TLS negotiated via PRELOGIN)" $ do
      (ci, app) <- appInfo "conc_dropped_hosted"
      openAndDrop ci { connectEncryption = EncryptReq } app
      waitForSessionCount 10 performMajorGC app 0 `shouldReturn` 0

    it "closing explicitly ends the session" $ do
      -- The counterpart of the test above.
      (ci, app) <- appInfo "conc_closed"
      conn <- connect ci
      _ <- timeout 5_000_000 (query1 conn "SELECT 1" :: IO (Only Int))
      close conn
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

    it "many connections opened and closed concurrently by many threads" $ do
      (ci, app) <- appInfo "conc_churn"
      within 120 $ mapConcurrently_ (\i -> replicateM_ 5 (withConnection ci (mixedWork i))) [1 .. 12 :: Int]
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0
