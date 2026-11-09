-- | The finalizer of a connection dropped without 'close' must not close
-- the socket under a thread that is still sending on it, for the same
-- reason as 'close' (see "Resources.CloseDuringSendSpec"): the sender may
-- start to wait on the descriptor just after the close, which leaves a
-- stale registration in GHC's IO manager (before GHC 9.14; on macOS,
-- closing the number's next socket then fails), or use the number once it
-- belongs to another socket.
--
-- The finalizer closes the socket without waiting for senders, which is
-- safe because it can't run while one is sending: 'sendBytes' keeps the
-- whole connection reachable until it returns, and with it the receive
-- buffer the finalizer is attached to.  That matters for a thread that has
-- nothing left to do with the connection once the send is over, such as
-- one interrupted part-way through a request, which sends the packet that
-- tells the server to discard it and then only unwinds.  Here, a thread
-- sends through 'sendBytes' directly, and does nothing else, to a server
-- that doesn't read, so the send blocks while nothing else refers to the
-- connection.  The finalizer must close the socket only once the send has
-- ended (here, when the server goes away).
--
-- Serial (in "Resources."): it replaces the process-wide 'socketCloser'
-- and forces garbage collections.
module Resources.FinalizerDuringSendSpec (spec) where

import Control.Concurrent
import Control.Exception
import qualified Data.ByteString as B
import Data.IORef
import Data.Maybe (isJust)
import qualified Network.Socket as Socket
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Compat (connSocket)
import Hmssql.Connection.Internal (sendBytes, socketCloser)
import MockServer

spec :: Spec
spec = describe "the finalizer of a connection dropped while a thread is sending on it" $
  it "closes the socket only once the send has ended" $ do
    release <- newEmptyMVar
    -- Logs in, then reads nothing until the test is done.
    withTcpMockServer (\mc -> serveLogin defaultLoginResponse mc >> readMVar release) $ \srv -> do
      sent <- newEmptyMVar
      sock <- startSending (mockConnectInfo srv) sent
      threadDelay 300_000
      senderDone <- newIORef []
      closedVar <- newEmptyMVar
      let closer s
            | s == sock = do
                done <- timeout 2_000_000 (readMVar sent)
                atomicModifyIORef' senderDone (\ds -> (isJust done : ds, ()))
                Socket.close s `finally` putMVar closedVar ()
            | otherwise = Socket.close s
      (early, late) <- bracket (atomicModifyIORef' socketCloser (\old -> (closer, old))) (writeIORef socketCloser) $ \_ -> do
        performMajorGC
        performMajorGC
        -- The finalizer runs on a thread of its own.
        early <- timeout 1_000_000 (readMVar closedVar)
        -- The server goes away, which ends the send; the connection can
        -- then be finalized.
        putMVar release ()
        _ <- timeout 5_000_000 (readMVar sent)
        performMajorGC
        performMajorGC
        late <- timeout 10_000_000 (readMVar closedVar)
        pure (early, late)
      r <- tryReadMVar sent
      done <- readIORef senderDone
      (early, late, done, fmap (either (const "failed") (const ("sent" :: String))) r)
        `shouldBe` (Nothing, Just (), [True], Just "failed")

-- | Connect, and start a thread that sends far more than the socket
-- buffers hold on the connection, putting the outcome in the 'MVar'.
-- Returns the connection's socket only: nothing else refers to the
-- connection afterwards.  Not inlined, so that nothing here keeps it.
startSending :: ConnectInfo -> MVar (Either SomeException ()) -> IO Socket.Socket
startSending ci sent = do
  conn <- connect ci
  let packet = B.replicate 4096 0x20
  _ <- forkIO $ try (sendBytes conn (replicate 4096 packet)) >>= putMVar sent
  pure $! connSocket conn
{-# NOINLINE startSending #-}
