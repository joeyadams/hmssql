{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
-- Under GHC's native I/O manager on Windows (WinIO), a program with 32
-- busy sockets crashes inside the manager.
--
-- A loopback echo server and N clients, all in this process, with
-- network's own recv and sendAll.  On each client connection one thread
-- receives all the time and another sends all the time, so that every
-- socket has a read and a write in progress.  network only (3.3.0.0 or
-- later, with a GHC that defines __IO_MANAGER_WINIO__ >= 2, so that its
-- calls go through the manager).
--
--   ManyConnections [connections rounds bytes]   +RTS --io-manager=native -N
import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import Data.IORef
import GHC.IO.SubSystem (conditional)
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as SB
import System.Environment (getArgs)
import Text.Printf

main :: IO ()
main = do
  args <- getArgs
  let (conns, rounds, bytes) = case map read args of
        [a, b, c] -> (a, b, c)
        _ -> (32, 100, 65537) :: (Int, Int, Int)
  putStrLn ("I/O manager: " ++ conditional "mio (default)" "winio (native)")
  let hints = S.defaultHints { S.addrSocketType = S.Stream, S.addrFlags = [S.AI_NUMERICHOST] }
  addr : _ <- S.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  l <- S.openSocket addr
  S.bind l (S.addrAddress addr)
  S.listen l 256
  port <- S.socketPort l
  -- The echo server: a thread per connection.
  _ <- forkIO $ forever $ do
    (s, _) <- S.accept l
    void $ forkIO $ void $ try @SomeException $ forever $ do
      bs <- SB.recv s 65536
      when (B.null bs) (throwIO (userError "closed"))
      SB.sendAll s bs
  failures <- newIORef (0 :: Int)
  let total = rounds * bytes
  dones <- forM [1 .. conns] $ \i -> do
    done <- newEmptyMVar
    _ <- forkIO $ (`finally` putMVar done ()) $ do
      r <- try @SomeException $ do
        c <- S.socket S.AF_INET S.Stream S.defaultProtocol
        S.connect c (S.SockAddrInet port (S.tupleToHostAddress (127, 0, 0, 1)))
        -- The receiver: until everything sent has come back.
        got <- newEmptyMVar
        _ <- forkIO $ (try @SomeException $ do
          let go n | n >= total = pure n
                   | otherwise = SB.recv c 32768 >>= \bs ->
                       if B.null bs then pure n else go (n + B.length bs)
          go 0) >>= putMVar got
        -- The sender, meanwhile.
        let msg = B.replicate bytes (fromIntegral i)
        replicateM_ rounds (SB.sendAll c msg)
        n <- takeMVar got
        S.close c
        case n of
          Right k | k == total -> pure ()
          other -> throwIO (userError ("received " ++ show other ++ " of " ++ show total))
      case r of
        Left e -> atomicModifyIORef' failures (\n -> (n + 1, ())) >> printf "connection %d: %s\n" i (show e)
        Right () -> pure ()
    pure done
  mapM_ takeMVar dones
  f <- readIORef failures
  printf "%d connections, %d messages of %d bytes each, all echoed: %d connections failed\n" conns rounds bytes f
