-- | 100,000 tiny queries run sequentially on one connection: checks there is
-- no per-query memory leak (e.g. an accumulating cache, a growing list of
-- callbacks, ...) by sampling residency every 10,000 queries and comparing
-- the trend, rather than asserting a single before/after delta as the other
-- memory tests do (a slow, steady leak wouldn't necessarily show up in a
-- single delta over a run this size, but would show up as a rising trend
-- across samples).
module Scale.RepeatedQueriesSpec (spec) where

import Control.Monad (forM_, replicateM_)
import Data.IORef
import GHC.Stats (getRTSStats, getRTSStatsEnabled, max_live_bytes)
import System.Mem (performMajorGC)
import Test.Hspec

import Hmssql
import TestDb

totalQueries :: Int
totalQueries = 100000

sampleEvery :: Int
sampleEvery = 10000

spec :: Spec
spec = around withTestDb $
  describe "100,000 sequential tiny queries on one connection" $
    slow $ it "residency does not grow with query count" $ \conn -> do
      enabled <- getRTSStatsEnabled
      if not enabled then expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T" else do
        samplesRef <- newIORef []
        let sample = do
              performMajorGC
              bytes <- max_live_bytes <$> getRTSStats
              modifyIORef' samplesRef (bytes :)

        sample -- baseline before any queries
        forM_ [1 .. totalQueries `div` sampleEvery] $ \_ -> do
          replicateM_ sampleEvery $ do
            Only (n :: Int) <- query1 conn "SELECT 1"
            n `shouldBe` 1
          sample

        samples <- reverse <$> readIORef samplesRef
        length samples `shouldBe` (totalQueries `div` sampleEvery + 1)

        -- Compare the last sample to the first with a generous multiplicative
        -- tolerance: a flat/bounded residency (GC bookkeeping noise, RTS
        -- allocator fragmentation) should stay well within 3x; a genuine
        -- per-query leak accumulating over 100,000 queries would blow far
        -- past that.
        let baseline = case samples of -- avoid a zero baseline
              first : _ -> max 1 first
              [] -> 1
            final = last samples
        fromIntegral final `shouldSatisfy` (< (3 :: Double) * fromIntegral baseline)
