{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
-- Minimal.hs with threadLabel replaced by a wrapper that tests the tag
-- before anything can check the heap: it returns Nothing at once, or passes
-- a label that exists to a NOINLINE function, which does the allocation.
-- (hmssql's tests use the same wrapper: threadLabelOf in
-- hmssql-tests/Resources/Helpers.hs.)  Build and run as Minimal.hs.
import Control.Concurrent
import Control.Monad
import Data.Char (chr)
import GHC.Conc (labelThread)
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (ByteArray#, Int (..), RealWorld, State#, indexWord8Array#, sizeofByteArray#, threadLabel#)
import GHC.IO (IO (..))
import GHC.Word (Word8 (..))
import System.Mem (performMajorGC)

threadLabelOf :: ThreadId -> IO (Maybe String)
threadLabelOf (ThreadId t) = IO $ \s -> case threadLabel# t s of
  (# s', 0#, _ #) -> (# s', Nothing #)
  (# s', _, label #) -> labelled label s'

-- The label's bytes as characters (enough for ASCII labels).
labelled :: ByteArray# -> State# RealWorld -> (# State# RealWorld, Maybe String #)
labelled label s =
  let byte (I# i) = chr (fromIntegral (W8# (indexWord8Array# label i)))
   in (# s, Just (map byte [0 .. I# (sizeofByteArray# label) - 1]) #)
{-# NOINLINE labelled #-}

main :: IO ()
main = do
  unlabelled <- replicateM 10 (forkIO (threadDelay 60000000))
  named <- forkIO (threadDelay 60000000)
  labelThread named "named"
  done <- newEmptyMVar
  _ <- forkIO $ let loop = performMajorGC >> tryReadMVar done >>= maybe loop pure in loop
  forM_ [1 :: Int .. 20000] $ \_ -> mapM_ threadLabelOf unlabelled
  putMVar done ()
  labels <- mapM threadLabelOf (named : take 1 unlabelled)
  putStrLn ("20000 rounds of threadLabelOf on 10 unlabelled threads: no crash; labels " ++ show labels)
