-- | Soak testing: a realistic mixed workload run through a small connection
-- pool ("Soak.Pool") by many worker threads for a configurable number of
-- minutes, with periodic sampling of process-wide resources and server
-- sessions. Gated behind @HMSSQL_TEST_SOAK=<minutes>@: skipped (pending)
-- otherwise, so it never runs as part of the fast or even the
-- @HMSSQL_TEST_SLOW=1@ suite. 'serial': it measures threads, fds and heap,
-- which other tests running at the same time would disturb.
--
-- The workload itself (what each worker does, and what it verifies) is in
-- "Soak.Workload". This module wires it together: the pool, the worker
-- tables, a background thread that occasionally @KILL@s one of the pool's
-- own sessions (the pool must notice and replace it), periodic sampling,
-- and the end-of-run assertions (no growth trend, zero verification
-- failures) plus a compact summary table.
module Soak.RunSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently_, withAsync)
import Control.Exception
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef
import Data.Int (Int32)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Environment (lookupEnv)
import Test.Hspec
import Text.Printf (printf)
import Text.Read (readMaybe)

import Hmssql
import Resources.Helpers (fdCount, heapLiveBytes, threadCount)
import Soak.Histogram
import Soak.Pool
import Soak.Workload
import TestDb

tshow :: Show a => a -> Text
tshow = T.pack . show

------------------------------------------------------------------------------
-- Configuration

-- | Pooled connections, shared by all 'workerCount' workers.
poolSize :: Int
poolSize = 8

-- | Worker threads hammering the pool.
workerCount :: Int
workerCount = 32

-- | How often resources and sessions are sampled, in seconds.
sampleIntervalS :: Int
sampleIntervalS = 10

-- | @HMSSQL_TEST_SOAK@: the number of minutes to run for. 'Nothing' if unset
-- (or empty), in which case the whole test is skipped.
soakMinutes :: IO (Maybe Int)
soakMinutes = lookupEnv "HMSSQL_TEST_SOAK" >>= \case
  Nothing -> pure Nothing
  Just "" -> pure Nothing
  Just v -> case readMaybe v of
    Just n | n > 0 -> pure (Just n)
    _ -> fail ("HMSSQL_TEST_SOAK: expected a positive number of minutes, not " ++ show v)

spec :: Spec
spec = serial $ describe "soak" $
  it "runs a long mixed workload through a small pool without growth or verification failures" $
    soakMinutes >>= \case
      Nothing -> pendingWith
        "set HMSSQL_TEST_SOAK=<minutes> to run (e.g. HMSSQL_TEST_SOAK=30); skipped by default"
      Just minutes -> runSoak minutes

------------------------------------------------------------------------------
-- Periodic snapshot

data Tick = Tick
  { tickElapsedS :: !Double
  , tickHeap :: !(Maybe Word64)
  , tickThreads :: !Int
  , tickFds :: !(Maybe Int)
  , tickSessions :: !Int
  , tickOps :: !Int
  , tickFailures :: !Int
  , tickReplacements :: !Int
  , tickKills :: !Int
  }

takeTick :: UTCTime -> Text -> Pool -> IORef Int -> IORef [String] -> IORef Int -> IO Tick
takeTick start appName pool opsCounter failuresRef killsRef = do
  heap <- heapLiveBytes
  thr <- threadCount
  fds <- fdCount
  sess <- sessionCountFor appName
  ops <- readIORef opsCounter
  fails <- length <$> readIORef failuresRef
  reps <- replacementCount pool
  kills <- readIORef killsRef
  now <- getCurrentTime
  -- Forced (all its fields are strict), so the ticks kept in 'ticksRef' for
  -- the whole run hold numbers, not thunks that could keep what they were
  -- computed from alive.
  pure $! Tick (realToFrac (diffUTCTime now start)) heap thr fds sess ops fails reps kills

sessionCountFor :: Text -> IO Int
sessionCountFor appName = withTestDb $ \c ->
  fromOnly <$> query1 c ("SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = " <> param appName)

------------------------------------------------------------------------------
-- Running it

-- | The shared test database's DDL applock (see "TestConfig"'s
-- @ensureTestDatabase@) is process-wide and taken once, the first time
-- anything connects; under heavy contention from other concurrent test runs
-- on the same server it can occasionally time out (120 s). Retry that once
-- here, before starting the clock on the run itself, rather than losing an
-- entire 10- or 30-minute soak run to a slow start that has nothing to do
-- with the workload being tested.
warmUpTestDb :: IO ()
warmUpTestDb = go (5 :: Int)
  where
    go n
      | n <= 1 = withTestDb (\_ -> pure ())
      | otherwise = try (withTestDb (\_ -> pure ())) >>= \case
          Right () -> pure ()
          Left (_ :: SomeException) -> threadDelay 2_000_000 >> go (n - 1)

runSoak :: Int -> IO ()
runSoak minutes = do
  warmUpTestDb
  appName <- uniqueName "soak"
  baseCi <- defaultTestConnectInfo
  let ci = baseCi { connectApplicationName = appName }
  pool <- newPool poolSize ci

  tables <- forM [0 .. workerCount - 1] $ \i -> do
    tbl <- uniqueName ("dbo.soak_w" <> tshow i)
    withTestDb $ \c -> void $ execute c $ rawSql
      ( "CREATE TABLE " <> tbl
          <> " (id bigint NOT NULL PRIMARY KEY, worker int NOT NULL, val nvarchar(200) NOT NULL, \
             \ts datetime2 NOT NULL DEFAULT SYSUTCDATETIME())" )
    pure tbl

  hists <- mapM (const newHistogram) allOpKinds
  let histFor k = hists !! fromEnum k

  failuresRef <- newIORef ([] :: [String])
  opsCounter <- newIORef (0 :: Int)
  killsRef <- newIORef (0 :: Int)
  ticksRef <- newIORef ([] :: [Tick])

  start <- getCurrentTime
  let deadline = addUTCTime (fromIntegral (minutes * 60) :: NominalDiffTime) start
      notDone = (< deadline) <$> getCurrentTime

  let recordFailure msg = atomicModifyIORef' failuresRef $ \xs ->
        (if length xs < 50 then msg : xs else xs, ())

  let runWorker :: Int -> IO ()
      runWorker workerIdx = do
        knownIds <- newKnownIds
        let tbl = tables !! workerIdx
            go = notDone >>= \more -> when more $ do
              kind <- Gen.sample genOpKind
              sentinel <- nextSentinel
              t0 <- getMonotonicTime
              outcome <- try (withPooledConn pool (\pc -> runOp kind pc tbl workerIdx sentinel knownIds))
                :: IO (Either SomeException ())
              t1 <- getMonotonicTime
              recordUs (histFor kind) (max 0 (round ((t1 - t0) * 1_000_000)))
              atomicModifyIORef' opsCounter (\c -> (c + 1, ()))
              case outcome of
                Right () -> pure ()
                Left e
                  | isConnFailure e -> pure ()
                  | otherwise -> recordFailure
                      ("worker " ++ show workerIdx ++ " " ++ show kind ++ ": " ++ displayException e)
              thinkMs <- Gen.sample (Gen.int (Range.linear 20 150))
              threadDelay (thinkMs * 1000)
              go
        go

  let killerLoop = notDone >>= \more -> when more $ do
        delaySec <- Gen.sample (Gen.int (Range.linear 10 25))
        threadDelay (delaySec * 1_000_000)
        stillGoing <- notDone
        when stillGoing $ do
          sids <- withTestDb $ \c ->
            (map fromOnly <$> query c
              ("SELECT session_id FROM sys.dm_exec_sessions WHERE program_name = " <> param appName))
              :: IO [Int32]
          case sids of
            [] -> pure ()
            _ -> do
              sid <- Gen.sample (Gen.element sids)
              r <- try (withTestDb (\c -> void (execute c (rawSql ("KILL " <> tshow sid))))) :: IO (Either SomeException ())
              case r of
                Right () -> atomicModifyIORef' killsRef (\c -> (c + 1, ()))
                Left (_ :: SomeException) -> pure () -- lost the race (session already gone/replaced)
        killerLoop

  let sampler = notDone >>= \more -> when more $ do
        threadDelay (sampleIntervalS * 1_000_000)
        stillGoing <- notDone
        when stillGoing $ do
          tick <- takeTick start appName pool opsCounter failuresRef killsRef
          atomicModifyIORef' ticksRef (\xs -> (tick : xs, ()))
        sampler

  withAsync killerLoop $ \_ ->
    withAsync sampler $ \_ ->
      mapConcurrently_ runWorker [0 .. workerCount - 1]

  finalTick <- takeTick start appName pool opsCounter failuresRef killsRef
  ticks <- reverse . (finalTick :) <$> readIORef ticksRef
  replacements <- replacementCount pool
  kills <- readIORef killsRef
  failures <- reverse <$> readIORef failuresRef
  totalOps <- readIORef opsCounter

  closePool pool
  withTestDb $ \c -> forM_ tables $ \t -> void (execute c (rawSql ("DROP TABLE IF EXISTS " <> t)))

  summary <- renderSummary minutes appName ticks totalOps replacements kills hists
  putStrLn summary

  unless (null failures) $ expectationFailure $
    show (length failures) ++ " verification failure(s) (showing up to 10):\n"
      ++ intercalate "\n" (take 10 failures)

  checkNoGrowth "live heap bytes" (24 * 1024 * 1024) (fmap fromIntegral . tickHeap) ticks
  checkNoGrowth "open fd count" 20 (fmap fromIntegral . tickFds) ticks

  checkNoGrowth "thread count" 15 (Just . fromIntegral . tickThreads) ticks

------------------------------------------------------------------------------
-- No-growth check

-- | The last quarter's mean must not exceed 1.2x the first quarter's mean,
-- plus a fixed slack (so a small, noisy baseline doesn't fail on nothing).
-- Skipped (not a failure) if there aren't enough samples, or the metric was
-- unavailable throughout (e.g. \/dev\/fd not listable).
checkNoGrowth :: String -> Double -> (Tick -> Maybe Double) -> [Tick] -> Expectation
checkNoGrowth label slack f ticks
  | n < 8 = pure ()
  | otherwise =
      when (m1 > limit) $ expectationFailure $
        label ++ ": grew from " ++ showRounded m0 ++ " (first-quarter mean) to " ++ showRounded m1
          ++ " (last-quarter mean) over the run, exceeding " ++ showRounded limit
          ++ " (1.2x + slack of " ++ show slack ++ ")"
  where
    vals = [v | Just v <- map f ticks]
    n = length vals
    q = max 1 (n `div` 4)
    meanOf xs = sum xs / fromIntegral (length xs)
    m0 = meanOf (take q vals)
    m1 = meanOf (drop (n - q) vals)
    limit = m0 * 1.2 + slack
    showRounded :: Double -> String
    showRounded x = show (round x :: Integer)

------------------------------------------------------------------------------
-- Summary

opLabel :: OpKind -> String
opLabel = \case
  OpSmallQuery -> "smallQuery"
  OpParamInsert -> "paramInsert"
  OpParamUpdate -> "paramUpdate"
  OpTxCommit -> "txCommit"
  OpTxRollback -> "txRollback"
  OpTxServerError -> "txServerError"
  OpStreamPartial -> "streamPartial"
  OpLargeValue -> "largeValue"
  OpInfoMessage -> "infoMessage"
  OpErrorSeverity -> "errorSeverity"
  OpTimeoutCancel -> "timeoutCancel"

renderSummary :: Int -> Text -> [Tick] -> Int -> Int -> Int -> [Histogram] -> IO String
renderSummary minutes appName ticks totalOps replacements kills hists = do
  opRows <- forM (zip allOpKinds hists) $ \(kind, h) -> do
    cnt <- histCount h
    p50 <- percentileMs h 0.50
    p95 <- percentileMs h 0.95
    p99 <- percentileMs h 0.99
    pure (printf "  %-14s %8d  p50=%8.2fms  p95=%8.2fms  p99=%8.2fms" (opLabel kind) cnt p50 p95 p99 :: String)

  let showMb :: Word64 -> String
      showMb b = printf "%.1fMB" (fromIntegral b / (1024 * 1024) :: Double)

      renderTick :: Tick -> String
      renderTick t = printf
        "  %7.0fs  heap=%-8s threads=%-4d fds=%-6s sessions=%-3d ops=%-8d failures=%d  replaced=%-3d kills=%d"
        (tickElapsedS t) (maybe "?" showMb (tickHeap t)) (tickThreads t)
        (maybe "?" show (tickFds t)) (tickSessions t) (tickOps t) (tickFailures t)
        (tickReplacements t) (tickKills t)

      sampleTicks = subsample 12 ticks
      tickRows = map renderTick sampleTicks

  pure $ unlines $
    [ "=== soak summary (" ++ show minutes ++ " min, app " ++ T.unpack appName ++ ") ==="
    , "total ops: " ++ show totalOps
    , "pool connection replacements: " ++ show replacements
    , "successful KILLs issued: " ++ show kills
    , "--- per-operation latency (count, p50/p95/p99) ---"
    ] ++ opRows ++
    [ "--- resource samples over time ---" ] ++ tickRows

-- | Up to @n@ evenly-spaced elements, always including the first and last.
subsample :: Int -> [a] -> [a]
subsample n xs
  | len <= n = xs
  | otherwise = [xs !! i | i <- idxs]
  where
    len = length xs
    step = fromIntegral (len - 1) / fromIntegral (max 1 (n - 1)) :: Double
    idxs = [round (fromIntegral k * step) | k <- [0 .. n - 1]]
