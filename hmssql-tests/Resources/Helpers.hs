{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
-- | Shared helpers for the resource-leak and algorithmic-complexity tests
-- (@hmssql-tests/Resources/*Spec.hs@): counting live threads, open file descriptors
-- and the heap's high-water mark, reading a thread's label, and comparing
-- allocation between two run sizes.  For allocation itself, see
-- "Protocol.MockTokens" (@allocatedDuring@), which these tests reuse.
module Resources.Helpers
  ( -- * Snapshot counts
    threadCount
  , fdCount
  , fdSlack
  , backendHandles
  , backendHandlesReturnTo
  , heapLiveBytes
  , keptAliveByEach
  , settle

    -- * Threads
  , threadLabelOf

    -- * Comparing two run sizes
  , subQuadratic
  , subQuadraticAlloc
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, evaluate, try)
import Data.Array.Byte (ByteArray (..))
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Conc (listThreads)
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (ByteArray#, RealWorld, State#, threadLabel#, toList)
import GHC.IO (IO (..))
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import System.Directory (listDirectory)
import System.Mem (performMajorGC)
import Data.Word (Word64)
import Test.Hspec (Expectation, expectationFailure, pendingWith)

import Compat (onWindows, openBackendHandles, processHandleCount)

-- | Live (not yet garbage collected) Haskell threads, including this one and
-- every other test's leftover threads: only meaningful as a delta around a
-- narrow window.
--
-- The count is evaluated before it is returned. A lazy @length <$>
-- listThreads@ returns a thunk holding the whole @[ThreadId]@ list, and a
-- 'ThreadId' keeps its thread (even a finished one) from being collected:
-- a caller that stores the count unevaluated (the soak test kept one per
-- sample in an 'IORef' until the end of the run) then keeps every thread
-- that was alive at that moment in 'listThreads' forever after, which
-- looks exactly like a thread leak in whatever is being measured.
threadCount :: IO Int
threadCount = listThreads >>= evaluate . length

-- | Open file descriptors, counted the lsof-free way: on macOS, \/dev\/fd has
-- one entry per open descriptor (including the one opened to list it).
-- 'Nothing' if \/dev\/fd isn't listable (not macOS, or sandboxed): callers
-- should then skip the assertion.
--
-- On Windows, which has no such directory, it is the process's count of
-- kernel handles ('processHandleCount'): sockets and pipes, and every
-- event and thread as well, so it moves a little with nothing leaked
-- ('fdSlack').
fdCount :: IO (Maybe Int)
fdCount = processHandleCount >>= \case
  Just n -> pure (Just n)
  Nothing -> do
    r <- try (listDirectory "/dev/fd") :: IO (Either SomeException [FilePath])
    -- Evaluated, so a stored count doesn't keep the directory listing alive.
    evaluate $ either (const Nothing) (\xs -> Just $! length xs) r

-- | How far 'fdCount' may move with nothing leaked, beyond what a test
-- allows for descriptors: to be added to the test's own tolerance.
-- Nothing off Windows.
fdSlack :: Int
fdSlack = if onWindows then windowsHandleSlack else 0

-- | On Windows the count of a process's handles is a coarse measure.  With
-- nothing leaked it rose by 3 to 62 across a sweep of 5,000 connects in
-- these tests, and by 45 over 20,000 connects in a probe, in steps that
-- followed neither the connects nor the interruptions and then stopped:
-- the runtime's worker threads and what Winsock keeps for each.  So it
-- can only show a gross leak, some hundreds of handles, and the exact
-- check there is 'backendHandlesReturnTo'.
windowsHandleSlack :: Int
windowsHandleSlack = 250

-- | On Windows, check that hmssql's backends have no more handles open
-- than the count given, taken earlier with 'backendHandles': every socket
-- and pipe opened since has been closed.  It waits up to 2 s for closes
-- still on their way (a mock connection is closed just after its handler
-- returns).  Fewer is not a failure: a connection left by an earlier test
-- may have been collected meanwhile.  Elsewhere it checks nothing; the
-- descriptor count ('fdCount') is exact there.
backendHandlesReturnTo :: Maybe Int -> Expectation
backendHandlesReturnTo Nothing = pure ()
backendHandlesReturnTo (Just before) = go (200 :: Int)
  where
    go n = openBackendHandles >>= \case
      Just now
        | now <= before -> pure ()
        | n > 0 -> threadDelay 10_000 >> go (n - 1)
        | otherwise -> expectationFailure $
            show (now - before) ++ " of hmssql's handles opened during the test are still open ("
              ++ show before ++ " before, " ++ show now ++ " after)"
      Nothing -> pure ()

-- | The count for 'backendHandlesReturnTo'; 'Nothing' off Windows.
backendHandles :: IO (Maybe Int)
backendHandles = openBackendHandles

-- | Live bytes as of the most recent major GC, forced right before reading:
-- the *current* retained heap, not a running maximum.  ('GHC.Stats.max_live_bytes',
-- which RobustnessSpec's memory test uses, is instead an all-time high-water
-- mark over the whole process; comparing it before/after a scenario that
-- itself transiently holds a lot of memory -- e.g. a big result set that's
-- cancelled partway through -- would record that transient peak as
-- "growth" even though nothing was actually leaked. @gcdetails_live_bytes@
-- avoids that: comparing it before and after N repetitions, both taken
-- right after a major GC, approximates the extra memory N iterations left
-- permanently retained.) The suite links with @-with-rtsopts=-T@
-- (package.yaml), so stats should always be enabled; this reports that
-- explicitly rather than silently reading zeroes if it's ever lost.
--
-- A difference of two readings counts whatever died between them as
-- well, and that includes what the process loaded once.  A CAF lives only
-- as long as code that is still to run refers to it, and the system
-- certificate store that hmssql loads once and caches in one is 2.6 MB
-- (123 certificates, on Ubuntu 24.04): it is alive at a reading taken
-- before the last connect of a process and dead at one taken after.  So a
-- test that compares readings either keeps the code path in use after its
-- last reading (one more connection will do) or allows for it.
heapLiveBytes :: IO (Maybe Word64)
heapLiveBytes = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then pure Nothing
    else do
      performMajorGC
      stats <- getRTSStats
      pure $! Just $! gcdetails_live_bytes (gc stats)

-- | The bytes that each of the values made by an action keeps alive: the
-- live heap with them referenced, less the live heap once they are dropped.
-- The values are given to @use@ between the two readings, which is what
-- keeps them referenced during the first; it must not be what frees their
-- memory.
--
-- Nothing is read before the values are made.  What is alive then and dead
-- once they are made would be taken off what they keep: these tests once
-- compared with such a baseline, and the last of them to run in a process
-- measured nothing at all, with a leak of 34 KB a connection or without
-- ('heapLiveBytes' says what died).  Here whatever dies between the two
-- readings is added to what they keep, so nothing can hide a leak; what
-- could add to it is the same cache, so the caller makes one more
-- connection after this returns.
keptAliveByEach :: (a -> IO ()) -> IO [a] -> IO Word64
keptAliveByEach use make = do
  xs <- make
  -- Counted now: counting them after the last reading would keep them
  -- referenced during it.
  n <- evaluate (length xs)
  held <- reading
  mapM_ use xs
  dropped <- reading
  pure ((max held dropped - dropped) `div` fromIntegral (max 1 n))
  where
    reading = settle >> heapLiveBytes >>= maybe (fail "RTS stats are off: link the test suite with -with-rtsopts=-T") pure

-- | Let short-lived threads/sockets from whatever ran just before finish
-- unwinding, and force a GC, before taking a baseline or a final snapshot.
settle :: IO ()
settle = threadDelay 200_000 >> performMajorGC >> threadDelay 50_000

-- | A thread's label ('GHC.Conc.Sync.labelThread'), as
-- 'GHC.Conc.Sync.threadLabel' returns it, but without its crash.
--
-- For a thread without a label, the @threadLabel#@ primop returns a null
-- pointer as the label, and @threadLabel@ (GHC 9.12.4 and 9.14.1, at
-- least) checks the heap for the 'Just' it may build before it looks at
-- whether there is a label.  If that check fails (the nursery block is
-- full, or the scheduler wants the capability), the thread saves the null
-- pointer on its stack as a pointer, and a major GC that runs before the
-- thread goes on follows it: a segfault in @evacuate@.  The full suite
-- crashed so, now and then, in "Resources.ConnectReader", which reads the
-- label of every thread in the process before each of its 3000 connects;
-- with @+RTS -A64k@, nearly every run of it did.
--
-- Here the continuation of the primop allocates nothing, so it has no
-- heap check: it returns 'Nothing' or passes a label that exists to
-- 'labelled', which is NOINLINE so that its allocation stays out of it.
--
-- GHC #27618, fixed on master and for 9.14.2 (not 9.12); see
-- @docs/dev/upstream/ghc-threadlabel-null@, whose @Minimal.hs@ reproduces it.
threadLabelOf :: ThreadId -> IO (Maybe String)
threadLabelOf (ThreadId t) = IO $ \s -> case threadLabel# t s of
  (# s', 0#, _ #) -> (# s', Nothing #)
  (# s', _, label #) -> labelled label s'

-- | A label from @threadLabel#@, in UTF-8.
labelled :: ByteArray# -> State# RealWorld -> (# State# RealWorld, Maybe String #)
labelled label s = (# s, Just (T.unpack (TE.decodeUtf8Lenient (B.pack (toList (ByteArray label))))) #)
{-# NOINLINE labelled #-}

-- | Assert that going from size @n@ to size @factor * n@ multiplied a cost
-- (allocation, time, ...) by well under @factor^2@ (quadratic).  Linear
-- predicts @factor@; this allows 1.5x that, matching the brief's own example
-- (ratio < 6 for a 4x size increase).  @small@ must be positive.
subQuadratic :: String -> Double -> Word64 -> Word64 -> Expectation
subQuadratic label factor small large
  | small == 0 = expectationFailure (label ++ ": the small run allocated/took nothing to compare against")
  | ratio < bound = pure ()
  | otherwise = expectationFailure $
      label ++ ": ratio " ++ show ratio ++ " for a " ++ show factor ++ "x size increase"
        ++ " (small=" ++ show small ++ ", large=" ++ show large ++ "), expected < " ++ show bound
        ++ " -- looks quadratic (or worse), not linear"
  where
    ratio = fromIntegral large / fromIntegral small :: Double
    bound = factor * 1.5

-- | 'subQuadratic' over two 'Protocol.MockTokens.allocatedDuring' results:
-- pending (not failing) if RTS stats are off, matching the existing
-- convention (MalformedSpec's @memory@ tests).
subQuadraticAlloc :: String -> Double -> Maybe Word64 -> Maybe Word64 -> Expectation
subQuadraticAlloc label factor small large = case (small, large) of
  (Just s, Just l) -> subQuadratic label factor s l
  _ -> pendingWith "run with +RTS -T"
