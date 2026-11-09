{-# LANGUAGE ScopedTypeVariables #-}
-- Minimal repro, boot packages only (base, unix).  Build with -threaded.
--
-- 1. A threadWaitWrite on an fd that was just closed (with closeFdWith, the
--    race-safe way) fails with EBADF, but the IO manager keeps the failed
--    registration in its callback table.
-- 2. When the kernel later gives that fd number to a new file, closeFdWith on
--    it throws "kevent: does not exist" (ENOENT, from deleting the stale
--    filter), and does not close the fd.
-- 3. closeFdWith also leaves the callback-table lock for (fd mod 32) taken, so
--    any later wait on an fd in that bucket blocks forever.
import Control.Concurrent
import Control.Exception
import GHC.Conc (closeFdWith)
import System.IO.Error (tryIOError)
import System.Posix.IO
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

main :: IO ()
main = do
  (_r1, w1) <- createPipe
  (_r2, w2) <- createPipe  -- opened now so that it does not get w1's number
  -- 1.
  closeFdWith closeFd w1
  r <- tryIOError (threadWaitWrite w1)
  putStrLn ("1. threadWaitWrite on the closed fd " ++ show w1 ++ ": " ++ show r)
  -- 2. Fd number w1 now names the second pipe (dup2); close it properly.
  _ <- dupTo w2 w1
  closeFd w2
  c <- tryIOError (closeFdWith closeFd w1)
  putStrLn ("2. closeFdWith on the fd's next owner: " ++ show c)
  open <- tryIOError (queryFdOption w1 CloseOnExec)
  putStrLn ("   fd " ++ show w1 ++ " still open afterwards: " ++ show (either (const False) (const True) open))
  -- 3. Wait on a readable fd in the same bucket (fd + 32).
  (r3, w3) <- createPipe
  let fd = w1 + 32
  _ <- dupTo r3 fd
  _ <- fdWrite w3 "x"
  t <- timeout 2000000 (threadWaitRead fd)
  putStrLn ("3. threadWaitRead on readable fd " ++ show fd ++ " (same bucket): "
            ++ maybe "timed out after 2 s (blocked on the bucket lock)" (const "returned") t)
