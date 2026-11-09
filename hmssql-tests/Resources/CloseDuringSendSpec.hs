-- | 'close' while another thread is sending on the connection (blocked,
-- because the server doesn't read) must not close the socket under that
-- thread: it may read the descriptor just before the close and use it just
-- after, when the number may belong to another socket already, or start to
-- wait on it just after the close, which leaves a stale registration in
-- GHC's IO manager (on macOS, closing the number's next socket then fails:
-- see 'Hmssql.Connection.Internal.closeSocket').  'close' shuts the socket
-- down instead, which ends the send, and closes it once the sender has
-- given up.
--
-- Serial (in "Resources."): it replaces the process-wide 'socketCloser'
-- (for its own connection's socket only) to see what the sender is doing
-- when the socket is closed.
module Resources.CloseDuringSendSpec (spec) where

import Control.Concurrent
import Control.Exception
import Data.IORef
import Data.Maybe (isJust)
import qualified Data.Text as T
import GHC.Conc (ThreadStatus (..), threadStatus)
import qualified Network.Socket as Socket
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Compat (connSocket, blockingCallStopsProcess, windowsNetworkTcp)
import Hmssql.Connection.Internal (connSendLock, socketCloser)
import MockServer

spec :: Spec
spec = describe "close while another thread is sending" $
  it "ends the send, and closes the socket only once the sender has given up" $ do
   if blockingCallStopsProcess
    then pendingWith "without -threaded the blocked send stops every thread, the mock server's and the closer's too (Compat.blockingCallStopsProcess)"
    else do
    release <- newEmptyMVar
    -- Logs in, then reads nothing until the test is done.  Its receive
    -- buffer is kept small, like the client's send buffer below, so that
    -- the batch can't be absorbed by the socket buffers of a generously
    -- tuned host (it was, on Azure Container Instances) and the send does
    -- block.
    let server mc = do
          Socket.setSocketOption (mcSocket mc) Socket.RecvBuffer 65536
          serveLogin defaultLoginResponse mc >> readMVar release
    withTcpMockServer server $ \srv -> do
      conn <- connect (mockConnectInfo srv)
      Socket.setSocketOption (connSocket conn) Socket.SendBuffer 65536
      sent <- newEmptyMVar
      -- Far more than the socket buffers hold, so the send blocks.
      let batch = "SELECT 1" <> T.replicate 2_000_000 "\n--xxxxxxx"
      sender <- forkIO $ try @SomeException (execute conn (rawSql batch)) >>= putMVar sent
      -- Close only once the sender is blocked in the send, holding the
      -- send lock.  A fixed delay isn't enough: the batch is encoded before
      -- the lock is taken, which under load (the whole suite) can take
      -- longer.  Closed before that, the close finds the lock free and
      -- closes the socket before the send starts, so there is no send for
      -- it to end, and the sender waits for the lock the close holds.
      let waitBlocked = do
            locked <- isEmptyMVar (connSendLock conn)
            status <- threadStatus sender
            case status of
              ThreadBlocked _ | locked -> pure ()
              _ -> threadDelay 1000 >> waitBlocked
      blocked <- timeout 10_000_000 waitBlocked
      -- When the socket is closed, has the sender given up?  (Before the
      -- fix, the sender was still blocked then, and the close was what
      -- ended it.)
      senderDone <- newIORef []
      let closer s
            | s == connSocket conn = do
                done <- timeout 2_000_000 (readMVar sent)
                atomicModifyIORef' senderDone (\ds -> (isJust done : ds, ()))
                Socket.close s
            | otherwise = Socket.close s
      let outcome = \case
            Left e | Just (ConnectionClosedBy ClosedByClient) <- fromException e -> "closed by client"
            other -> show other
      bracket (atomicModifyIORef' socketCloser (\old -> (closer, old))) (writeIORef socketCloser) $ \_ ->
        if not windowsNetworkTcp
          then do
            closed <- timeout 5_000_000 (close conn)
            putMVar release ()
            r <- timeout 5_000_000 (readMVar sent)
            done <- readIORef senderDone
            (blocked, closed, done, fmap outcome r) `shouldBe` (Just (), Just (), [True], Just "closed by client")
          else do
            -- On Windows with TCP through network's calls the send may be
            -- a blocking WSASend in a foreign call (network's sendMany),
            -- which the shutdown doesn't end.  So the consequence: close
            -- may wait for the sender until the server ends the
            -- connection (it did in most runs, and returned at once in
            -- one over MARS), and it still closes the socket only once the
            -- sender has given up.
            closing <- newEmptyMVar
            _ <- forkIO $ try @SomeException (close conn) >>= putMVar closing
            _ <- timeout 1_000_000 (readMVar closing)
            putMVar release ()
            closed <- timeout 10_000_000 (readMVar closing)
            r <- timeout 5_000_000 (readMVar sent)
            done <- readIORef senderDone
            (blocked, fmap (either (const False) (const True)) closed, done, fmap outcome r)
              `shouldBe` (Just (), Just True, [True], Just "closed by client")
