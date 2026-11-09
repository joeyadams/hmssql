-- | Behaviour under async exceptions and concurrent callers.
module RobustnessSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async (forConcurrently, mapConcurrently_)
import Control.Exception
import Control.Monad (replicateM_)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import GHC.Stats (getRTSStats, getRTSStatsEnabled, max_live_bytes)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import TestDb

bigQuery :: Query
bigQuery = "SELECT TOP 300000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

spec :: Spec
spec = around withTestDb $ do
  mars <- runIO testMars
  describe "interruption" $ do
    it "recovers after a consumer thread is killed mid-stream" $ \conn -> do
      progress <- newIORef (0 :: Int)
      done <- newEmptyMVar
      tid <- forkIO $ do
        r <- try $ queryS conn bigQuery >>= S.mapM_ (\(Only (_ :: Int64)) -> modifyIORef' progress (+ 1))
        putMVar done (r :: Either SomeException ())
      -- Until the consumer has rows, or has ended (the query failed), for
      -- at most 60 s: a server that stopped answering would otherwise keep
      -- this polling for ever.
      let waitForRows k = do
            n <- readIORef progress
            ended <- isJust <$> tryReadMVar done
            if n > 100 || ended || k <= (0 :: Int) then pure () else threadDelay 1000 >> waitForRows (k - 1)
      waitForRows 60_000
      killThread tid
      r <- timeout 10_000_000 (takeMVar done) >>= maybe (fail "the consumer didn't end when killed") pure
      case r of
        Left e | Just ThreadKilled <- fromException e -> pure ()
        other -> expectationFailure ("consumer ended with " ++ show other)
      n <- readIORef progress
      -- Killed mid-stream, not before the rows came.
      n `shouldSatisfy` (\k -> k > 100 && k < 300000)
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

    it "recovers after a timeout during a materializing query" $ \conn -> do
      -- The WAITFOR keeps the response open behind the rows, so the query
      -- can't finish first.  Over Shared Memory in plaintext all 300,000
      -- rows arrived before the timeout fired, which on Windows is up to
      -- 16 ms later than asked.
      r <- timeout 20000 (query conn (bigQuery <> "; WAITFOR DELAY '00:00:10'") :: IO [Only Int64])
      case r of
        Nothing -> pure ()
        Just rows -> expectationFailure ("finished " ++ show (length rows) ++ " rows before the timeout")
      query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int)

    -- Under MARS another request doesn't supersede a stream: it runs beside
    -- it, and the stream reads on to its end.
    it (if mars
          then "a stream left unread while another request runs reads on to its end (MARS)"
          else "an abandoned stream throws ResultAbandoned once superseded") $ \conn -> do
      s <- queryS conn bigQuery
      first S.:> rest <- S.toList (S.splitAt 2 s)
      first `shouldBe` [Only 1, Only (2 :: Int64)]
      _ <- query1 conn "SELECT 1" :: IO (Only Int)
      if mars
        then S.toList_ rest `shouldReturn` map Only [3 .. 300_000]
        else do
          r <- try (S.toList_ s :: IO [Only Int64])
          case r of
            Left ResultAbandoned -> pure ()
            Right rows -> expectationFailure ("read " ++ show (length rows) ++ " rows")

    it "surfaces an error raised mid-result after yielding earlier rows" $ \conn -> do
      seen <- newIORef (0 :: Int)
      r <- try $ do
        s <- queryS conn "SELECT 1 UNION ALL SELECT 2; RAISERROR('late', 16, 1); SELECT 3"
        S.mapM_ (\(Only (_ :: Int)) -> modifyIORef' seen (+ 1)) s
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "late"
        Right () -> expectationFailure "no error"
      readIORef seen `shouldReturn` 2
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "concurrency" $ do
    it "serializes materializing queries from many threads" $ \conn -> do
      results <- forConcurrently [1 .. 40 :: Int] $ \i ->
        query1 conn ("SELECT " <> param i <> " * 2")
      results `shouldBe` [Only (i * 2) | i <- [1 .. 40 :: Int]]

    it "serializes writes inside transactions from many threads" $ \conn -> do
      _ <- execute conn "CREATE TABLE #conc (i int)"
      mapConcurrently_ (\i -> withTransaction conn $ replicateM_ 5 $ execute conn ("INSERT INTO #conc VALUES (" <> param i <> ")")) [1 .. 10 :: Int]
      query1 conn "SELECT COUNT(*), SUM(i) FROM #conc" `shouldReturn` (50 :: Int, 275 :: Int)

  -- Measures the heap high-water mark: alone (see TestDb.serial).
  serial $ describe "memory" $
    it "streams a large result set in bounded memory" $ \conn -> do
      -- The suite links with -with-rtsopts=-T (package.yaml), so stats are
      -- always on; fail rather than silently skip if that is ever lost.
      enabled <- getRTSStatsEnabled
      if not enabled then expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T" else do
        performMajorGC
        before <- max_live_bytes <$> getRTSStats
        -- ~200 bytes per row on the wire; materialized this would be well over 100 MB
        s <- queryS conn "SELECT TOP 400000 REPLICATE(N'x', 100) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        n <- S.length_ (S.map (\(Only (t :: Text)) -> t) s)
        n `shouldBe` 400000
        performMajorGC
        after <- max_live_bytes <$> getRTSStats
        fromIntegral (after - before) `shouldSatisfy` (< (32 * 1024 * 1024 :: Int))

  describe "info messages" $
    it "delivers PRINT output to the callback" $ \_ -> do
      msgs <- newIORef []
      ci <- defaultTestConnectInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' msgs (msgText m :) } $ \conn -> do
        _ <- execute conn "PRINT 'hello'; PRINT 'world'"
        pure ()
      -- login also produces INFO messages (database context, language)
      (take 2 <$> readIORef msgs) `shouldReturn` ["world", "hello"]
