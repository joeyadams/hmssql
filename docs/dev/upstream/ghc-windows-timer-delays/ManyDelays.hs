-- How late is a 200 ms 'threadDelay' while other threads wait in long ones?
--
--   many-delays RATE SECONDS RUN
--
-- forks RATE threads a second, each of which sleeps SECONDS in one
-- 'threadDelay', for RUN seconds, and meanwhile times a 200 ms
-- 'threadDelay' again and again.  The forking is paced by the clock, not
-- by a timer.
import Control.Concurrent
import Control.Monad
import Data.IORef
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)
import System.IO
import Text.Printf (printf)

main :: IO ()
main = do
  [rateArg, secondsArg, runArg] <- getArgs
  let rate = read rateArg :: Int
      micros = round ((read secondsArg :: Double) * 1e6) :: Int
      run = read runArg :: Double
  hSetBuffering stdout LineBuffering
  started <- newIORef (0 :: Int)
  t0 <- getMonotonicTime
  _ <- forkIO $ forever $ do
    now <- getMonotonicTime
    done <- readIORef started
    let due = floor ((now - t0) * fromIntegral rate) - done :: Int
        batch = min 200 due
    if batch > 0 && now - t0 < run
      then replicateM_ batch (forkIO (threadDelay micros)) >> modifyIORef' started (+ batch)
      else yield
  let loop = do
        a <- getMonotonicTime
        threadDelay 200000
        b <- getMonotonicTime
        n <- readIORef started
        printf "at %5.1f s, %7d delays started: a 200 ms delay took %6.0f ms\n" (b - t0) n ((b - a) * 1000)
        when (b - t0 < run) loop
  loop
