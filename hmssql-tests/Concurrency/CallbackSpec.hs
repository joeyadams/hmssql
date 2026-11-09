{-# LANGUAGE DerivingStrategies #-}

-- | Info-message callbacks ('connectOnInfoMessage') that are slow, throw,
-- kill their own thread, are interrupted from outside, or hand work to
-- another thread.  (Re-entering the connection from a callback is covered by
-- LockingSpec.)
module Concurrency.CallbackSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (void, when)
import Data.IORef
import Data.Int (Int64)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Types
import TestDb

-- | A connection whose info messages go to the given callback, which can be
-- changed while it is open.
withCallbackConnection :: (IORef (ServerMessage -> IO ()) -> Connection -> IO a) -> IO a
withCallbackConnection act = do
  ref <- newIORef (\_ -> pure ())
  ci <- defaultTestConnectInfo
  withConnection ci { connectOnInfoMessage = \m -> readIORef ref >>= ($ m) } (act ref)

spec :: Spec
spec = do
  -- A wall-clock bound: alone (see TestDb.serial).
  serial $ it "a slow callback can be interrupted by a timeout, leaving the connection usable" $
    withCallbackConnection $ \cb conn -> do
      seen <- newIORef []
      writeIORef cb $ \m -> modifyIORef' seen (msgText m :) >> threadDelay 300_000
      (r, t) <- elapsed $ timeout 100_000 (execute conn "PRINT 'a'; PRINT 'b'; SELECT 1")
      r `shouldBe` Nothing
      t `shouldSatisfy` (< 1)
      -- The next request drains the rest (running the callback for 'b').
      within 10 (expectUsable conn)
      reverse <$> readIORef seen `shouldReturn` ["a", "b"]

  it "an exception from the callback reaches the caller, and the rest of the response is still drained" $
    withCallbackConnection $ \cb conn -> do
      seen <- newIORef []
      writeIORef cb $ \m -> do
        modifyIORef' seen (msgText m :)
        when (msgText m == "boom") $ throwIO (userError "callback failed")
      r <- try (within 10 (query conn "PRINT 'a'; PRINT 'boom'; SELECT 1; PRINT 'c'; SELECT 2" :: IO [Only Int]))
      either (\(e :: IOException) -> show e `shouldContain` "callback failed") (\rows -> expectationFailure ("returned " ++ show rows)) r
      within 10 (expectUsable conn)
      reverse <$> readIORef seen `shouldReturn` ["a", "boom", "c"]

  it "a callback that kills its own thread leaves the connection usable by others" $
    withCallbackConnection $ \cb conn -> do
      writeIORef cb $ \m -> when (msgText m == "die") $ myThreadId >>= killThread
      done <- newEmptyMVar
      _ <- forkIO $ try (execute conn "PRINT 'die'; SELECT 1; PRINT 'after'") >>= putMVar done
      within 10 (takeMVar done) >>= \case
        Left ThreadKilled -> pure ()
        other -> expectationFailure ("ended with " ++ show other)
      writeIORef cb (\_ -> pure ())
      within 10 (expectUsable conn)

  it "a callback blocked forever can be killed from outside" $
    withCallbackConnection $ \cb conn -> do
      entered <- newEmptyMVar
      forever <- newEmptyMVar :: IO (MVar ())
      writeIORef cb $ \_ -> putMVar entered () >> takeMVar forever
      done <- newEmptyMVar
      tid <- forkIO $ try (execute conn "PRINT 'wait'; SELECT 1") >>= putMVar done
      within 10 (takeMVar entered)
      killThread tid
      within 10 (takeMVar done) >>= \case
        Left ThreadKilled -> pure ()
        other -> expectationFailure ("ended with " ++ show other)
      writeIORef cb (\_ -> pure ())
      within 10 (expectUsable conn)
      -- Not stuck "in a callback": ordinary use is not refused.
      query1 conn "PRINT 'x'; SELECT 5" `shouldReturn` Only (5 :: Int)

  it "a callback may hand work to another thread that uses the connection afterwards" $
    withCallbackConnection $ \cb conn -> do
      results <- newIORef []
      finished <- newEmptyMVar
      writeIORef cb $ \m -> when (msgText m == "spawn") $ void $ forkIO $ do
        r <- try (within 20 (query conn ("SELECT " <> param (42 :: Int64))))
        modifyIORef' results (r :)
        putMVar finished ()
      rows <- within 10 (query conn "PRINT 'spawn'; SELECT 1")
      rows `shouldBe` [Only (1 :: Int)]
      within 20 (takeMVar finished)
      readIORef results >>= \case
        [Right [Only 42]] -> pure ()
        other -> expectationFailure (show (other :: [Either SomeException [Only Int64]]))
      within 10 (expectUsable conn)

  it "callbacks from many PRINTs interleaved with rows, under random interruptions" $
    withCallbackConnection $ \cb conn -> do
      count <- newIORef (0 :: Int)
      writeIORef cb $ \_ -> modifyIORef' count (+ 1)
      let batchText = "DECLARE @i int = 0; WHILE @i < 200 BEGIN PRINT 'row'; SELECT @i; SET @i += 1; END"
          batch = rawSql batchText
      within 120 $ mapM_ (\d -> do
        -- Sent here, consumed (and killed) on another thread: the kill
        -- always lands while receiving.
        s <- queryS conn batch
        _ <- interruptWith ViaKillThread (Micros d) (S.length_ (s :: S.Stream (S.Of (Only Int)) IO ()))
        -- Under MARS the stream may still be open: cancelled here.
        settleInterruptedStream conn batchText
        checkHealth conn >>= \case
          Usable -> pure ()
          Broken cause -> throwIO (userError ("a kill while receiving broke the connection: " ++ show cause)))
        [0, 100, 300, 1000, 3000, 10_000, 30_000]
      readIORef count >>= (`shouldSatisfy` (> 0))
