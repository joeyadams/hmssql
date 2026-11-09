-- | A tiny fixed-bucket latency histogram, used to report approximate
-- percentiles for the soak test (@Soak.RunSpec@) without keeping every raw
-- sample: a 30-minute run at even a modest rate would otherwise pile up
-- millions of 'Double's, which would itself look like (or cause) a leak.
module Soak.Histogram
  ( Histogram
  , newHistogram
  , recordUs
  , percentileMs
  , histCount
  ) where

import Control.Monad (replicateM)
import Data.IORef

-- | Bucket upper bounds, in microseconds: sub-millisecond up to 100 seconds.
-- A sample larger than the last bound falls in the final (overflow) bucket.
boundariesUs :: [Int]
boundariesUs =
  [ 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000
  , 100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000
  , 10_000_000, 20_000_000, 50_000_000, 100_000_000
  ]

-- | One counter per bucket (including the overflow bucket at the end), each
-- updated with 'atomicModifyIORef'', so it's safe to share across worker
-- threads.
newtype Histogram = Histogram [IORef Int]

newHistogram :: IO Histogram
newHistogram = Histogram <$> replicateM (length boundariesUs + 1) (newIORef 0)

bucketIndex :: Int -> Int
bucketIndex us = length (takeWhile (< us) boundariesUs)

-- | Record one sample, in microseconds.
recordUs :: Histogram -> Int -> IO ()
recordUs (Histogram refs) us = atomicModifyIORef' (refs !! bucketIndex us) (\c -> (c + 1, ()))

-- | Total samples recorded so far.
histCount :: Histogram -> IO Int
histCount (Histogram refs) = sum <$> mapM readIORef refs

-- | The upper bound (in milliseconds) of the bucket containing the @p@-th
-- percentile (@p@ in @[0,1]@), e.g. @percentileMs h 0.95@. An approximation
-- (bucket resolution only), which is all a soak summary needs. 0 if nothing
-- was recorded yet.
percentileMs :: Histogram -> Double -> IO Double
percentileMs (Histogram refs) p = do
  counts <- mapM readIORef refs
  let total = sum counts
  if total <= 0
    then pure 0
    else do
      let target = max 1 (ceiling (p * fromIntegral total) :: Int)
          bounds = boundariesUs ++ [last boundariesUs * 2] -- overflow bucket's reported bound
          pick = go 0 (zip counts bounds)
          go _ [] = last bounds
          go acc ((c, b) : rest) =
            let acc' = acc + c
             in if acc' >= target then b else go acc' rest
      pure (fromIntegral (pick :: Int) / 1000)
