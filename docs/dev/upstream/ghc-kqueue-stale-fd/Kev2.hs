{-# LANGUAGE ScopedTypeVariables #-}
-- 1. A thread that registers interest in an fd just after another thread
--    closed it leaves a stale registration; closing a socket that later gets
--    the same number fails with "kevent: does not exist".
-- 2. shutdown(SHUT_RDWR) wakes a thread blocked sending on a full socket.
import Control.Concurrent
import Control.Exception
import Control.Monad
import Foreign.C.Types
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as SB
import qualified Data.ByteString as B
import System.Posix.Types (Fd (..))
import System.Timeout
import Control.Concurrent (threadWaitWrite)

foreign import ccall unsafe "close" c_close :: CInt -> IO CInt
foreign import ccall unsafe "dup2" c_dup2 :: CInt -> CInt -> IO CInt

main :: IO ()
main = do
  (a, b) <- S.socketPair S.AF_UNIX S.Stream 0
  fdA <- S.unsafeFdSocket a
  S.close a
  r1 <- try (threadWaitWrite (Fd fdA))
  putStrLn ("threadWaitWrite on the closed fd: " ++ show (r1 :: Either IOException ()))
  (c, d) <- S.socketPair S.AF_UNIX S.Stream 0
  fdC <- S.unsafeFdSocket c
  _ <- c_dup2 fdC fdA
  s <- S.mkSocket fdA
  r2 <- try (S.close s)
  putStrLn ("Socket.close of the fd's next owner: " ++ show (r2 :: Either IOException ()))

  -- 2: shutdown wakes a blocked sender (fd 200+ to stay clear of the stripe above).
  (e, f) <- S.socketPair S.AF_UNIX S.Stream 0
  done <- newEmptyMVar
  _ <- forkIO $ do
    r <- try (forever (SB.sendAll e (B.replicate 65536 0)))
    putMVar done (r :: Either IOException ())
  threadDelay 300000
  S.shutdown e S.ShutdownBoth
  w <- timeout 2000000 (takeMVar done)
  putStrLn ("sender after shutdown: " ++ show w)
  S.close e
  mapM_ S.close [b, d, f]
  -- 3: the same over TCP.
  let hints = S.defaultHints { S.addrSocketType = S.Stream, S.addrFlags = [S.AI_NUMERICHOST] }
  addr : _ <- S.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  l <- S.openSocket addr
  S.bind l (S.addrAddress addr)
  S.listen l 4
  port <- S.socketPort l
  addr2 : _ <- S.getAddrInfo (Just hints) (Just "127.0.0.1") (Just (show port))
  t <- S.openSocket addr2
  S.connect t (S.addrAddress addr2)
  (srv, _) <- S.accept l
  done2 <- newEmptyMVar
  _ <- forkIO $ do
    r <- try (forever (SB.sendAll t (B.replicate 65536 0)))
    putMVar done2 (r :: Either IOException ())
  threadDelay 300000
  S.shutdown t S.ShutdownBoth
  w2 <- timeout 2000000 (takeMVar done2)
  putStrLn ("TCP sender after shutdown: " ++ show w2)
  mapM_ S.close [t, srv, l]
