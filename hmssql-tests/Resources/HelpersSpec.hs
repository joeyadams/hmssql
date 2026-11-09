-- | The measuring helpers of "Resources.Helpers" must not change what they
-- measure, nor crash. Serial (the "Resources." prefix is in
-- 'SpecHook.serialModules'): it relies on a finished thread being collected
-- by a major GC, and runs major GCs back to back for a second.
module Resources.HelpersSpec (spec) where

import Control.Concurrent (forkIO, killThread, mkWeakThreadId, threadDelay, yield)
import Control.Concurrent.MVar
import Control.Exception (finally)
import Control.Monad (replicateM, unless)
import Data.Maybe (isJust)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (labelThread)
import System.Mem (performMajorGC)
import System.Mem.Weak (deRefWeak)
import Test.Hspec

import Resources.Helpers (threadCount, threadLabelOf)

spec :: Spec
spec = do
  describe "threadCount" $
    -- The soak test's thread count grew by about one thread per pool
    -- replacement, with no plateau: the thread counts it kept for its summary
    -- were each an unevaluated @length@ of a whole 'GHC.Conc.listThreads'
    -- result, so every thread alive at any sample (each connection's reader
    -- thread among them) stayed listed, finished, for the rest of the run.
    it "does not keep the threads it counted from being collected" $ do
      gate <- newEmptyMVar
      done <- newEmptyMVar
      tid <- forkIO (takeMVar gate >> putMVar done ())
      weak <- mkWeakThreadId tid
      counted <- threadCount -- counted while the thread is alive
      putMVar gate ()
      takeMVar done
      threadDelay 10_000 -- let it finish after its putMVar
      performMajorGC
      collected <- not . isJust <$> deRefWeak weak
      collected `shouldBe` True
      -- Still in use after the GC, so it was live during it.
      counted `shouldSatisfy` (> 0)

  describe "threadLabelOf" $
    -- 'GHC.Conc.Sync.threadLabel' in its place crashes the process here
    -- (segfault in the GC) within a fraction of a second: another thread's
    -- major GC makes the reading thread's heap check fail, with the null
    -- label of a thread without one saved on its stack.
    it "reads threads without a label while major GCs run" $ do
      unlabelled <- replicateM 10 (forkIO (threadDelay 60_000_000))
      labelled <- forkIO (threadDelay 60_000_000)
      labelThread labelled "labelled"
      stop <- newEmptyMVar
      -- The loop allocates nothing, so without -threaded nothing would
      -- preempt it, and the reading thread would never run: it yields.
      collector <- forkIO $
        let loop = performMajorGC >> yield >> tryReadMVar stop >>= maybe loop pure in loop
      labels <- flip finally (putMVar stop () >> mapM_ killThread (collector : labelled : unlabelled)) $ do
        t0 <- getMonotonicTime
        let loop = do
              mapM_ threadLabelOf unlabelled
              t <- getMonotonicTime
              unless (t - t0 >= 1) loop
        loop
        mapM threadLabelOf (labelled : unlabelled)
      labels `shouldBe` Just "labelled" : replicate 10 Nothing
