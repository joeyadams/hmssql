{-# LANGUAGE ScopedTypeVariables #-}
-- closeFdWith is not exception-safe: when the backend's kevent(EV_DELETE)
-- fails (here ENOENT, because the kernel no longer has the filter), it throws
-- without closing the fd and without putting back the callback-table lock for
-- (fd mod 32), so every later wait on an fd in that bucket blocks forever.
--
-- To get a registration the kernel no longer has without the registerFd_ bug
-- (fixed in 9.14), this closes the fd with close(2) behind the IO manager's
-- back while a thread waits on it.  Boot packages only; build with -threaded.
import Control.Concurrent
import Control.Exception
import Foreign.C.Types (CInt (..))
import GHC.Conc (closeFdWith)
import System.IO.Error (tryIOError)
import System.Posix.IO
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

foreign import ccall unsafe "close" c_close :: CInt -> IO CInt

main :: IO ()
main = do
  (r1, _w1) <- createPipe
  (r2, _w2) <- createPipe  -- opened now so that it does not get r1's number
  -- A thread waits to read r1: the IO manager registers it with the kernel.
  _ <- forkIO $ do
    x <- try (threadWaitRead r1)
    putStrLn ("   waiter: " ++ show (x :: Either SomeException ()))
  threadDelay 100000
  -- close(2) behind the manager's back: the kernel drops the filter, the
  -- manager's table keeps the registration.  (Misuse, but it stands in for
  -- any way the two can disagree.)
  let Fd n = r1
  _ <- c_close n
  -- Fd number r1 now names the second pipe (dup2); close it properly.
  _ <- dupTo r2 r1
  closeFd r2
  c <- tryIOError (closeFdWith closeFd r1)
  putStrLn ("1. closeFdWith: " ++ show c)
  open <- tryIOError (queryFdOption r1 CloseOnExec)
  putStrLn ("   fd " ++ show r1 ++ " still open afterwards: " ++ show (either (const False) (const True) open))
  -- Wait on a readable fd in the same bucket (fd + 32).
  (r3, w3) <- createPipe
  let fd = r1 + 32
  _ <- dupTo r3 fd
  _ <- fdWrite w3 "x"
  t <- timeout 2000000 (threadWaitRead fd)
  putStrLn ("2. threadWaitRead on readable fd " ++ show fd ++ " (same bucket): "
            ++ maybe "timed out after 2 s (blocked on the bucket lock)" (const "returned") t)
