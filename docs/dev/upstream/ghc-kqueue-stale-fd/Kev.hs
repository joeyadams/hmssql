-- Repro: GHC's closeFdWith on macOS (kqueue) throws "kevent: does not exist"
-- when the IO manager's table has a registration the kernel no longer has,
-- and then leaves the fd open and the callback-table stripe empty.
{-# LANGUAGE ScopedTypeVariables #-}
import Control.Concurrent
import Control.Exception
import Control.Monad
import Foreign.C.Types
import qualified Network.Socket as S
import System.Posix.Types (Fd (..))
import System.Timeout

import qualified Network.Socket.ByteString as SB
import qualified Data.ByteString.Char8 as BC

foreign import ccall unsafe "close" c_close :: CInt -> IO CInt
foreign import ccall unsafe "dup2" c_dup2 :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "fcntl" c_fcntl :: CInt -> CInt -> CInt -> IO CInt

main :: IO ()
main = do
  (a, b) <- S.socketPair S.AF_UNIX S.Stream 0
  fdA <- S.unsafeFdSocket a
  -- A thread waits to read fd A: the IO manager registers it (EV_ADD).
  _ <- forkIO $ (threadWaitRead (Fd fdA) >> putStrLn "waiter woke") `catch` \(e :: SomeException) -> putStrLn ("waiter: " ++ show e)
  threadDelay 100000
  -- Close fd A behind the IO manager's back: the kernel drops the knote,
  -- the manager's table keeps the registration.
  _ <- c_close fdA
  -- Another socket takes fd A's number.
  (c, d) <- S.socketPair S.AF_UNIX S.Stream 0
  fdC <- S.unsafeFdSocket c
  _ <- c_dup2 fdC fdA
  s <- S.mkSocket fdA
  r <- try (S.close s)
  putStrLn ("Socket.close: " ++ show (r :: Either IOException ()))
  open <- c_fcntl fdA 1 0  -- F_GETFD
  putStrLn ("fd " ++ show fdA ++ " still open after the failed close: " ++ show (open /= -1))
  -- Is the stripe (fd mod 32) poisoned?  Wait on another fd in it.
  (e, f) <- S.socketPair S.AF_UNIX S.Stream 0
  fdE <- S.unsafeFdSocket e
  let target = fdA + 32
  _ <- c_dup2 fdE target
  w <- timeout 2000000 $ do
    done <- newEmptyMVar
    _ <- forkIO $ (threadWaitRead (Fd target) >> putMVar done ()) `catch` \(x :: SomeException) -> putMVar done ()
    threadDelay 100000
    SB.sendAll f (BC.pack "x")
    takeMVar done
  putStrLn ("wait on fd " ++ show target ++ " (same stripe): " ++ maybe "HUNG (stripe poisoned)" (const "ok") w)
  mapM_ S.close [b, d, f]
