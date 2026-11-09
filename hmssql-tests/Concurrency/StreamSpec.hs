{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DerivingStrategies #-}

-- | 'queryS' streams across threads and under interruption: consumed on
-- another thread, abandoned and garbage-collected, failing consumers,
-- consumers killed at random points (only ever mid-receive), and read on
-- after interruptions.  An interruption that lands while the consumer waits
-- for or parses a row cancels the statement at once and abandons the
-- stream: reading on through it throws 'ResultAbandoned' (the cancelled
-- result would end early), and the connection stays usable.
module Concurrency.StreamSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, when)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Streaming (Of (..), Stream)
import System.IO (hPutStrLn, stderr)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Errors
import OpenResponses (openStatements)
import TestDb

numbers :: Int -> Text
numbers n = "SELECT TOP " <> tshow n <> " ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
  where tshow = T.pack . show

numberStream :: Connection -> Int -> IO (Stream (Of Int64) IO ())
numberStream conn n = S.map fromOnly <$> queryS conn (rawSql (numbers n))

-- | A stream started on this thread and consumed on another, which is killed
-- after the delay.  The request was sent before the consumer started, so the
-- kill always lands while receiving: the connection must stay usable.
killConsumer :: Connection -> Int -> Delay -> IO ()
killConsumer conn n delay = do
  s <- numberStream conn n
  _ <- interruptWith ViaKillThread delay (S.length_ s)
  settleInterruptedStream conn (numbers n)
  checkHealth conn >>= \case
    Usable -> pure ()
    Broken cause -> throwIO (userError ("a kill while receiving broke the connection: " ++ show cause))

-- | Read the stream to the end, catching 'Interrupt' and carrying on from
-- where it stopped, until it ends or throws 'ResultAbandoned'.  Returns the
-- values read, and whether it was abandoned.
-- Runs masked except inside @restore@.
resumeThroughInterrupts :: (forall a. IO a -> IO a) -> IORef Int -> Stream (Of Int64) IO () -> IO ([Int64], Bool)
resumeThroughInterrupts restore progress =
  let go acc s = do
        r <- try (try (restore (S.next s)))
        case r of
          Left Interrupt -> go acc s
          Right (Left ResultAbandoned) -> pure (reverse acc, True)
          Right (Right (Left ())) -> pure (reverse acc, False)
          Right (Right (Right (x, rest))) -> do
            modifyIORef' progress (+ 1)
            go (x : acc) rest
   in go []

spec :: Spec
spec = around withTestDb $ do
  mars <- runIO testMars
  it "can be consumed on a different thread than the one that started it" $ \conn -> do
    s <- numberStream conn 50_000
    result <- newEmptyMVar
    _ <- forkIO $ try (S.toList_ s) >>= putMVar result
    within 30 (takeMVar result) >>= \case
      Left (e :: SomeException) -> expectationFailure (show e)
      Right xs -> xs `shouldBe` [1 .. 50_000]
    expectUsable conn

  it "can be consumed a bit on each of several threads in turn" $ \conn -> do
    s0 <- numberStream conn 10_000
    ref <- newIORef s0
    got <- newIORef []
    forM_ [1 .. 10 :: Int] $ \_ -> do
      done <- newEmptyMVar
      _ <- forkIO $ do
        s <- readIORef ref
        xs :> rest <- S.toList (S.splitAt 1000 s)
        modifyIORef' got (++ xs)
        writeIORef ref rest
        putMVar done ()
      within 10 (takeMVar done)
    readIORef got `shouldReturn` [1 .. 10_000]
    -- Every row was read, but not the end of the response: under MARS the
    -- stream still holds its session until it is read to the end (without
    -- MARS the next request drains it).
    when mars $ do
      openStatements conn `shouldReturn` [numbers 10_000]
      readIORef ref >>= S.effects
    expectUsable conn

  -- Under MARS nothing cancels them: each stays open on a session of its
  -- own, and later requests are answered on others.
  it "abandoned, unconsumed streams that are garbage-collected don't disturb later requests" $ \conn -> do
    forM_ [1 .. 20 :: Int] $ \i -> do
      s <- numberStream conn 1_000_000
      _ <- S.length_ (S.take i s)
      performMajorGC
      expectUsableBeside (if mars then replicate i (numbers 1_000_000) else []) conn
    when mars $ do
      cancelActiveStatement conn
      expectUsable conn

  -- Under MARS the stream, not read on, stays open beside later requests
  -- until it is cancelled.
  it "an exception thrown by the consumer leaves the connection usable" $ \conn -> do
    forM_ [1, 10, 1000, 50_000] $ \k -> do
      s <- numberStream conn 1_000_000
      r <- try (S.mapM_ (\x -> when (x == k) (throwIO (userError "consumer failed"))) s)
      either (\(e :: IOException) -> show e `shouldContain` "consumer failed") (\() -> expectationFailure "no exception") r
      expectUsableBeside [numbers 1_000_000 | mars] conn
      when mars $ do
        cancelActiveStatement conn
        expectUsable conn

  it (if mars
        then "both of two streams open at once are complete, the older read on after the newer (MARS)"
        else "the older of two streams throws ResultAbandoned, the newer is complete") $ \conn -> do
    s1 <- numberStream conn 100_000
    xs :> rest1 <- S.toList (S.splitAt 3 s1)
    xs `shouldBe` [1, 2, 3]
    s2 <- numberStream conn 20_000
    S.toList_ s2 `shouldReturn` [1 .. 20_000]
    if mars
      then S.toList_ rest1 `shouldReturn` [4 .. 100_000]
      else do
        r <- try (S.length_ rest1)
        case r of
          Left ResultAbandoned -> pure ()
          Right n -> expectationFailure ("the older stream went on for " ++ show n ++ " rows")
    expectUsable conn

  it "a consumer killed at random points while receiving leaves the connection usable" $ \conn ->
    within 120 $ forM_ (concat (replicate 4 [Yields 0, Yields 3, Micros 10, Micros 100, Micros 300, Micros 1000, Micros 3000, Micros 10_000])) $
      killConsumer conn 200_000

  slow $ it "a consumer killed at random points while receiving leaves the connection usable (long)" $ \conn ->
    within 600 $ forM_ [0 .. 3000 :: Int] $ \i ->
      killConsumer conn 200_000 (if even i then Micros ((i * 7) `mod` 20_000) else Yields (i `mod` 50))

  -- WAITFOR first: the consumer waits for the first row, so the timeout
  -- surely lands in a read.
  serial $ it "an interrupted read abandons the stream: reading it again throws ResultAbandoned, and the connection stays usable" $ \conn -> do
    s <- queryS conn "WAITFOR DELAY '00:00:10'; SELECT CAST(1 AS bigint)"
    first <- timeout 200_000 (S.toList_ (s :: Stream (Of (Only Int64)) IO ()))
    first `shouldBe` Nothing
    again <- within 10 (try (S.toList_ s))
    case again of
      Left ResultAbandoned -> pure ()
      Right rows -> expectationFailure ("read on after the interruption: " ++ show rows)
    -- The statement was cancelled, not waited out.
    (_, t) <- elapsed (within 10 (expectUsable conn))
    t `shouldSatisfy` (< 2)

  it "read on after interruptions, yields the rows in order (losing at most a packet's rows per interruption) until one lands in a read, which abandons it (ResultAbandoned)" $ \_ -> do
    -- Small packets make the consumer wait for rows often; each
    -- interruption lands at a random point.  Rows are read a packet at a
    -- time (one batch per pull): one that lands between reads, while a
    -- batch is being returned, may lose that batch (the rows of one
    -- packet, plus a row cut by the packet boundary, which comes as a
    -- batch of its own), but never more, and the stream goes on; the
    -- first that lands in a read cancels the statement, and the stream
    -- then throws ResultAbandoned.
    ci <- defaultTestConnectInfo
    let packetSize = 512 :: Int
        -- A ROW token of one bigint is 9 bytes.
        maxLoss = (packetSize - 8) `div` 9 + 1
    withConnection ci { connectPacketSize = fromIntegral packetSize } $ \conn -> do
      progress <- newIORef 0
      s <- numberStream conn 300_000
      result <- newEmptyMVar
      consumer <- mask_ $ forkIOWithUnmask $ \unmask ->
        try (resumeThroughInterrupts unmask progress s) >>= putMVar result
      interrupts <- newIORef (0 :: Int)
      let interrupter lastSeen = tryReadMVar result >>= \case
            Just _ -> pure ()
            Nothing -> do
              p <- readIORef progress
              if p < lastSeen + 2
                then yield >> interrupter lastSeen
                else do
                  throwTo consumer Interrupt
                  modifyIORef' interrupts (+ 1)
                  -- Counted from when the interruption landed (the
                  -- consumer may have moved on while this thread was
                  -- descheduled), so that two interruptions are always
                  -- separated by a row read.
                  readIORef progress >>= interrupter
      interrupterDone <- newEmptyMVar
      _ <- forkIO (interrupter 0 `finally` putMVar interrupterDone ())
      r <- within 120 (readMVar result)
      -- The interrupter counts an interruption only after 'throwTo' has
      -- returned, and it may be descheduled in between while the consumer
      -- goes on to finish (an interruption that lands in a read ends it at
      -- once).  It stops once it sees the result, so once it has stopped,
      -- every interruption that landed has been counted.
      within 10 (takeMVar interrupterDone)
      n <- readIORef interrupts
      case r of
        Left (e :: SomeException) -> expectationFailure ("after " ++ show n ++ " interruptions: " ++ show e)
        Right (xs, abandoned) -> do
          let gaps = [(a, b) | (a, b) <- zip xs (drop 1 xs), b - a /= 1]
          -- Strictly increasing, and no gap larger than a packet's rows.
          filter (\(a, b) -> b <= a || b - a - 1 > fromIntegral maxLoss) gaps `shouldBe` []
          length gaps `shouldSatisfy` (<= n)
          when (null xs) $ expectationFailure "no rows"
          -- Only an interruption abandons it; a stream read to its end got
          -- every row but those lost.
          if abandoned
            then n `shouldSatisfy` (> 0)
            else (last xs, length xs + length gaps) `shouldBe` (300_000, 300_000)
          hPutStrLn stderr ("    [read on after interruptions] " ++ show n ++ " interruptions, "
            ++ show (length xs) ++ " rows, " ++ (if abandoned then "then ResultAbandoned" else "read to the end"))
      expectUsable conn
