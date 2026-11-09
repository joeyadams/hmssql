{-# LANGUAGE ScopedTypeVariables, NumericUnderscores #-}
-- Under GHC's native I/O manager on Windows (WinIO), a thread that is
-- killed while it reads a file sometimes never ends.
--
-- Sixteen threads each read a small file with Data.ByteString.readFile,
-- over and over, each read on a thread of its own that is killed 0 to
-- 3000 us after it starts.  A watchdog reports a reader that has not ended
-- 10 s after it was killed, with its status.  base and bytestring only.
--
--   KilledRead <file> [threads rounds]   +RTS --io-manager=native -N
import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import Data.IORef
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (threadStatus)
import GHC.IO.SubSystem (conditional)
import System.Environment (getArgs)
import System.Timeout (timeout)
import Text.Printf

main :: IO ()
main = do
  args <- getArgs
  let (file, threads, rounds) = case args of
        [f, a, b] -> (f, read a, read b)
        [f] -> (f, 16, 2000)
        _ -> error "usage: KilledRead <file> [threads rounds]" :: (FilePath, Int, Int)
  putStrLn ("I/O manager: " ++ conditional "mio (default)" "winio (native)")
  size <- B.length <$> B.readFile file
  printf "reading a file of %d bytes\n" size
  stuck <- newIORef (0 :: Int)
  killed <- newIORef (0 :: Int)
  finished <- newIORef (0 :: Int)
  dones <- forM [1 .. threads] $ \t -> do
    done <- newEmptyMVar
    _ <- forkIO $ (`finally` putMVar done ()) $ forM_ [1 .. rounds] $ \i -> do
      back <- newEmptyMVar
      tid <- mask_ $ forkIOWithUnmask $ \unmask ->
        try (unmask (B.readFile file >>= evaluate . B.length)) >>= putMVar back
      -- Kill it after 0 to 3000 us, spinning, so that the kill lands at
      -- different points of the open, the read and the close.
      t0 <- getMonotonicTimeNSec
      let wait = fromIntegral ((i * 13 + t * 7) `mod` 3000) * 1000
          spin = getMonotonicTimeNSec >>= \now -> when (now - t0 < wait) (yield >> spin)
      spin
      killThread tid
      r <- timeout 10_000_000 (takeMVar back)
      case r of
        Nothing -> do
          st <- threadStatus tid
          atomicModifyIORef' stuck (\n -> (n + 1, ()))
          printf "thread %d, round %d: the killed reader has not ended after 10 s (%s)\n" t i (show st)
        Just (Left (_ :: SomeException)) -> atomicModifyIORef' killed (\n -> (n + 1, ()))
        Just (Right _) -> atomicModifyIORef' finished (\n -> (n + 1, ()))
    pure done
  mapM_ takeMVar dones
  a <- readIORef killed; b <- readIORef finished; c <- readIORef stuck
  printf "%d threads x %d rounds: %d readers were killed in time and ended, %d finished first, %d never ended\n"
    threads rounds a b c
