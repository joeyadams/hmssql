-- Minimal repro, base only.  Build with -O0 -threaded -rtsopts, run with
-- +RTS -N.  (At -O0 the call goes to base's compiled threadLabel; at -O1
-- threadLabel is inlined here, and this program no longer crashes.)
--
-- threadLabel on threads that have no label, while another thread runs
-- major GCs.  The threadLabel# primop returns a null pointer as the label
-- of such a thread, and the code after it saves that pointer on the stack,
-- as a pointer, when its heap check fails; a GC request from another
-- capability makes the check fail.  The major GC then follows the null
-- pointer: the process dies of SIGSEGV in evacuate, usually within a
-- fraction of a second.
--
-- queryLabel is NOINLINE and its result forced, as in GHC's regression
-- test for the bug (T27618).
import Control.Concurrent
import Control.Monad
import GHC.Conc.Sync (threadLabel)
import System.Mem (performMajorGC)

queryLabel :: ThreadId -> IO (Maybe String)
queryLabel = threadLabel
{-# NOINLINE queryLabel #-}

main :: IO ()
main = do
  unlabelled <- replicateM 10 (forkIO (threadDelay 60000000))
  done <- newEmptyMVar
  _ <- forkIO $ let loop = performMajorGC >> tryReadMVar done >>= maybe loop pure in loop
  forM_ [1 :: Int .. 20000] $ \_ -> forM_ unlabelled $ \t -> do
    l <- queryLabel t
    l `seq` pure ()
  putMVar done ()
  putStrLn "20000 rounds of threadLabel on 10 unlabelled threads: no crash"
