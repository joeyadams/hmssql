-- | The connection mutex ("Hmssql.Connection.Locking") and how the connection
-- behaves when its users are killed, block forever, re-enter it, or race.
-- Deadlocks are turned into failures with 'timeout'.
module LockingSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async (forConcurrently)
import Control.Exception
import Control.Monad (forM_, void, when)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (isJust)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Mem.Weak (deRefWeak)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Connection.Locking
import TestDb

-- | Fail instead of hanging.
within :: Int -> IO a -> IO a
within seconds act = timeout (seconds * 1_000_000) act >>= \case
  Just a -> pure a
  Nothing -> throwIO (userError ("timed out after " ++ show seconds ++ " s (deadlock?)"))

-- | Run GCs until the condition holds (or give up after a few seconds).
gcUntil :: IO Bool -> IO Bool
gcUntil cond = go (50 :: Int)
  where
    go 0 = cond
    go n = do
      performMajorGC
      ok <- cond
      if ok then pure True else threadDelay 100_000 >> go (n - 1)

-- | Wait until some other thread holds the connection.
waitForOwner :: Connection -> IO ()
waitForOwner conn = within 10 loop
  where
    loop = mutexOwner (connMutex conn) >>= \case
      Just _ -> pure ()
      Nothing -> threadDelay 1000 >> loop

-- | The number of rows makes it take a while to arrive in full.
bigQuery :: Query
bigQuery = "SELECT TOP 100000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

spec :: Spec
spec = do
  mars <- runIO testMars
  describe "Mutex" $ do
    it "is reentrant and released afterwards" $ do
      m <- newMutex
      me <- myThreadId
      owner <- withMutex m $ withMutex m $ mutexOwner m
      fmap show owner `shouldBe` Just (drop (length ("ThreadId " :: String)) (show me))
      mutexOwner m `shouldReturn` Nothing

    it "does not keep a finished owner's ThreadId alive" $ do
      m <- newMutex
      done <- newEmptyMVar
      w <- forkIO (withMutex m (pure ()) `finally` putMVar done ()) >>= mkWeakThreadId
      takeMVar done
      gcUntil (not . isJust <$> deRefWeak w) `shouldReturn` True
      mutexOwner m `shouldReturn` Nothing

    it "lets the GC collect an owner blocked forever, which then releases the mutex" $ do
      -- With a strong ThreadId in the mutex, the owner stays reachable
      -- through it, is never sent BlockedIndefinitelyOnMVar, and the mutex
      -- is held forever.
      m <- newMutex
      held <- newEmptyMVar
      outcome <- newEmptyMVar
      _ <- forkIO (do
        r <- try $ withMutex m $ do
          putMVar held ()
          newEmptyMVar >>= takeMVar :: IO ()
        putMVar outcome (either (Just . show @BlockedIndefinitelyOnMVar) (const Nothing) r))
      takeMVar held
      gcUntil (isJust <$> tryReadMVar outcome) `shouldReturn` True
      takeMVar outcome `shouldReturn` Just (show BlockedIndefinitelyOnMVar)
      within 5 (withMutex m (pure ()))

    it "is released when the owner is killed" $ do
      m <- newMutex
      held <- newEmptyMVar
      tid <- forkIO $ withMutex m $ putMVar held () >> threadDelay 60_000_000
      takeMVar held
      killThread tid
      within 5 (withMutex m (pure ()))
      mutexOwner m `shouldReturn` Nothing

    it "is unaffected by a waiter being killed" $ do
      m <- newMutex
      held <- newEmptyMVar
      release <- newEmptyMVar
      ownerDone <- newEmptyMVar
      _ <- forkIO $ withMutex m (putMVar held () >> takeMVar release) `finally` putMVar ownerDone ()
      takeMVar held
      waiterEntered <- newIORef False
      waiter <- forkIO $ withMutex m (writeIORef waiterEntered True)
      threadDelay 50_000
      killThread waiter
      readIORef waiterEntered `shouldReturn` False
      isJust <$> mutexOwner m `shouldReturn` True
      putMVar release ()
      takeMVar ownerDone
      mutexOwner m `shouldReturn` Nothing
      within 5 (withMutex m (pure ()))

  describe "connection" $ around withTestDb $ do
    it "is usable by others promptly after its owner is killed mid-query" $ \conn -> do
      owner <- forkIO $ void $ execute conn "WAITFOR DELAY '00:00:30'"
      waitForOwner conn
      other <- newEmptyMVar
      _ <- forkIO $ try (query1 conn "SELECT 42") >>= putMVar other
      threadDelay 100_000
      tryReadMVar other >>= \r -> when (isJust r) $ expectationFailure "did not wait for the owner"
      killThread owner
      r <- within 10 (takeMVar other)
      either (\e -> expectationFailure (show (e :: SomeException))) (`shouldBe` Only (42 :: Int)) r

    it "is unaffected by a waiting thread being killed" $ \conn -> do
      owner <- newEmptyMVar
      _ <- forkIO $ try (query1 conn "WAITFOR DELAY '00:00:01'; SELECT 1") >>= putMVar owner
      waitForOwner conn
      waiter <- forkIO $ void (query1 conn "SELECT 99" :: IO (Only Int))
      threadDelay 100_000
      killThread waiter
      within 10 (takeMVar owner) >>= either (\e -> expectationFailure (show (e :: SomeException))) (`shouldBe` Only (1 :: Int))
      mutexOwner (connMutex conn) `shouldReturn` Nothing
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)

    it "is unaffected by a thread waiting for a transaction being killed" $ \conn -> do
      _ <- execute conn "CREATE TABLE #waiter (i int)"
      inside <- newEmptyMVar
      gate <- newEmptyMVar
      result <- newEmptyMVar
      _ <- forkIO $ try (withTransaction conn $ do
        _ <- execute conn "INSERT INTO #waiter VALUES (1)"
        putMVar inside ()
        takeMVar gate
        execute conn "INSERT INTO #waiter VALUES (2)") >>= putMVar result
      takeMVar inside
      waiter <- forkIO $ void $ execute conn "INSERT INTO #waiter VALUES (99)"
      threadDelay 100_000
      killThread waiter
      putMVar gate ()
      within 10 (takeMVar result) >>= either (\e -> expectationFailure (show (e :: SomeException))) (`shouldBe` 1)
      query conn "SELECT i FROM #waiter ORDER BY i" `shouldReturn` [Only (1 :: Int), Only 2]
      mutexOwner (connMutex conn) `shouldReturn` Nothing

    it "rolls back and frees a transaction whose thread blocks forever" $ \conn -> do
      _ <- execute conn "CREATE TABLE #stuck (i int)"
      inside <- newEmptyMVar
      outcome <- newEmptyMVar
      _ <- forkIO $ do
        r <- try $ withTransaction conn $ do
          _ <- execute conn "INSERT INTO #stuck VALUES (1)"
          putMVar inside ()
          newEmptyMVar >>= takeMVar :: IO ()
        putMVar outcome (either (Just . show @BlockedIndefinitelyOnMVar) (const Nothing) r)
      takeMVar inside
      gcUntil (isJust <$> tryReadMVar outcome) `shouldReturn` True
      takeMVar outcome `shouldReturn` Just (show BlockedIndefinitelyOnMVar)
      within 10 (query1 conn "SELECT @@TRANCOUNT, (SELECT COUNT(*) FROM #stuck)")
        `shouldReturn` (0 :: Int, 0 :: Int)

    it "runs transactions from several threads one after another" $ \conn -> do
      _ <- execute conn "CREATE TABLE #serial (thread int, i int)"
      results <- within 60 $ forConcurrently [1 .. 8 :: Int] $ \t -> try $ withTransaction conn $ do
        forM_ [1 .. 3 :: Int] $ \i -> do
          _ <- execute conn (mkQuery "INSERT INTO #serial VALUES (@p1, @p2)" (t, i))
          threadDelay 2_000
        -- Only this transaction's rows are uncommitted, and it isn't nested.
        (level, mine, uncommittedOthers) <- query1 conn $ mkQuery
          "SELECT @@TRANCOUNT, (SELECT COUNT(*) FROM #serial WHERE thread = @p1), \
          \  (SELECT COUNT(*) FROM #serial WHERE thread <> @p1 AND thread % 2 = 1)" (Only t)
        when (odd t) $ throwIO (userError "odd threads roll back")
        pure (level :: Int, mine :: Int, uncommittedOthers :: Int)
      forM_ (zip [1 :: Int ..] results) $ \(t, r) -> case r of
        Left (e :: IOException) | odd t -> show e `shouldContain` "odd threads roll back"
        Right v | even t -> v `shouldBe` (1, 3, 0)
        other -> expectationFailure ("thread " ++ show t ++ ": " ++ show other)
      query conn "SELECT thread, COUNT(*) FROM #serial GROUP BY thread ORDER BY thread"
        `shouldReturn` [(t, 3 :: Int) | t <- [2, 4, 6, 8 :: Int]]
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)

    it "makes other threads wait for a transaction instead of joining it" $ \conn -> do
      _ <- execute conn "CREATE TABLE #join (i int)"
      inside <- newEmptyMVar
      gate <- newEmptyMVar
      txn <- newEmptyMVar
      _ <- forkIO $ try (withTransaction conn $ do
        _ <- execute conn "INSERT INTO #join VALUES (1)"
        putMVar inside ()
        takeMVar gate
        throwIO (userError "roll back")) >>= putMVar txn
      takeMVar inside
      other <- newEmptyMVar
      _ <- forkIO $ try (execute conn "INSERT INTO #join VALUES (2)") >>= putMVar other
      threadDelay 100_000
      tryReadMVar other >>= \r -> when (isJust r) $ expectationFailure "ran inside the other thread's transaction"
      putMVar gate ()
      within 10 (takeMVar txn) >>= \r -> either (\(_ :: IOException) -> pure ()) (\() -> expectationFailure "committed") r
      within 10 (takeMVar other) >>= either (\e -> expectationFailure (show (e :: SomeException))) (`shouldBe` 1)
      -- The rollback undid only the transaction's own row.
      query conn "SELECT i FROM #join" `shouldReturn` [Only (2 :: Int)]

  describe "re-entering the connection" $ do
    it "from an info-message callback throws ReentrantCallback instead of deadlocking" $ do
      connRef <- newIORef Nothing
      attempts <- newIORef ([] :: [String])
      ci <- defaultTestConnectInfo
      let onInfo _ = readIORef connRef >>= mapM_ (\c -> do
            r <- try (query1 c "SELECT 1" :: IO (Only Int))
            modifyIORef' attempts (either (\ReentrantCallback -> "refused") (const "ran") r :))
      withConnection ci { connectOnInfoMessage = onInfo } $ \conn -> do
        writeIORef connRef (Just conn)
        within 10 (query1 conn "PRINT 'hello'; SELECT 2") `shouldReturn` Only (2 :: Int)
        readIORef attempts `shouldReturn` ["refused"]
        writeIORef connRef Nothing
        query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int)

    it "an exception escaping the callback reaches the caller and leaves the connection usable" $ do
      connRef <- newIORef Nothing
      ci <- defaultTestConnectInfo
      let onInfo _ = readIORef connRef >>= mapM_ (\c -> void (execute c "SELECT 1"))
      withConnection ci { connectOnInfoMessage = onInfo } $ \conn -> do
        writeIORef connRef (Just conn)
        within 10 (try (execute conn "PRINT 'hello'; SELECT 2")) >>= \case
          Left ReentrantCallback -> pure ()
          Right n -> expectationFailure ("returned " ++ show n)
        writeIORef connRef Nothing
        query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int)

    -- Under MARS the consumer's request runs beside the stream (on a
    -- session of its own), which goes on to its end: every row reaches the
    -- consumer.  A request for every row would take 100,000 round trips, so
    -- there the consumer makes one for every 500th.
    it (if mars
          then "from a stream consumer runs beside the stream, which goes on, instead of deadlocking (MARS)"
          else "from a stream consumer supersedes the stream (ResultAbandoned) instead of deadlocking") $
      withTestDb $ \conn -> do
        seen <- newIORef (0 :: Int)
        r <- within 20 $ try $ do
          s <- queryS conn bigQuery
          S.mapM_ (\(Only (i :: Int64)) -> do
            modifyIORef' seen (+ 1)
            if mars
              then when (i `mod` 500 == 0) $ query1 conn ("SELECT " <> param i) `shouldReturn` Only i
              else void (query1 conn "SELECT 1" :: IO (Only Int))) s
        case r of
          Left ResultAbandoned | not mars -> pure ()
          Right () | mars -> readIORef seen `shouldReturn` 100_000
          Left ResultAbandoned -> expectationFailure "the stream was abandoned"
          Right () -> expectationFailure "the stream survived"
        query1 conn "SELECT 4" `shouldReturn` Only (4 :: Int)

    -- Under MARS the stream, read to its end, doesn't hold the commit up:
    -- the consumer's inserts are committed.
    it "from a stream consumer inside a transaction stays in the transaction" $
      withTestDb $ \conn -> do
        _ <- execute conn "CREATE TABLE #consumer (i int)"
        r <- within 20 $ try $ withTransaction conn $ do
          s <- queryS conn bigQuery
          S.mapM_ (\(Only (i :: Int64)) -> when (not mars || i `mod` 500 == 0) $
            void (execute conn ("INSERT INTO #consumer VALUES (" <> param i <> ")"))) s
        case r of
          Left ResultAbandoned | not mars -> pure ()
          Right () | mars -> pure ()
          Left ResultAbandoned -> expectationFailure "the stream was abandoned"
          Right () -> expectationFailure "the stream survived"
        query1 conn "SELECT @@TRANCOUNT, (SELECT COUNT(*) FROM #consumer)"
          `shouldReturn` (0 :: Int, if mars then 200 else 0 :: Int)
