-- | Closing a socket can fail: on macOS, GHC's @closeFdWith@ (which
-- network's 'Socket.close' uses) throws @kevent: does not exist@ when the
-- IO manager holds a stale registration for the descriptor's number, after
-- marking the socket closed and before closing the descriptor (see
-- 'closeSocket').  That can't be provoked here without breaking the IO
-- manager for the rest of the run, so these tests make closing fail the
-- same way through 'socketCloser': the cleanup that closes the socket must
-- neither replace the exception it is cleaning up after nor leave the
-- descriptor open.  Whether the descriptor was closed is seen from the
-- other end, which gets end of stream.
--
-- Serial (in "Resources."): 'socketCloser' is process-wide.  It fails only
-- for sockets connected to the test's own mock server anyway.
module Resources.CloseFailureSpec (spec) where

import Control.Exception
import Control.Monad (void)
import qualified Data.ByteString as B
import Data.IORef
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import System.IO (Handle, IOMode (ReadWriteMode), hIsClosed)
import System.IO.Error (doesNotExistErrorType, mkIOError)
import System.Mem (performMajorGC)
import Compat (detachDescriptor)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Connection.Internal (closeSocketWith, socketCloser)
import MockServer

-- | What 'Socket.close' does when @closeFdWith@ fails: the socket is marked
-- closed, its descriptor stays open, and an 'IOException' is thrown.
-- ('Socket.socketToHandle' marks the socket closed and hands the descriptor
-- to a handle; 'detachDescriptor' closes the handle but not the descriptor.)
brokenClose :: Socket.Socket -> IO ()
brokenClose = brokenCloseNoting (\_ -> pure ())

-- | 'brokenClose', giving the handle it makes on the way to the action.
--
-- The handle must not be left open.  Its finalizer would close the
-- descriptor's number a second time, at whatever collection finds the
-- handle, when the number may be another socket's: on Windows, where
-- 'detachDescriptor' once only threw, that closed the sockets of the
-- finalizer test below under it.
brokenCloseNoting :: (Handle -> IO ()) -> Socket.Socket -> IO ()
brokenCloseNoting note s = do
  h <- Socket.socketToHandle s ReadWriteMode
  note h
  detachDescriptor h
  throwIO (mkIOError doesNotExistErrorType "kevent" Nothing Nothing)

-- | Run the action with closing failing ('brokenClose') for hmssql's
-- sockets to the given port; returns how many closes failed.
withBrokenCloseTo :: String -> IO a -> IO (a, Int)
withBrokenCloseTo port act = do
  count <- newIORef (0 :: Int)
  let closer s = try @IOException (Socket.getPeerName s) >>= \case
        Right addr | peerPort addr == Just port -> do
          atomicModifyIORef' count (\n -> (n + 1, ()))
          brokenClose s
        _ -> Socket.close s
  r <- bracket (atomicModifyIORef' socketCloser (\old -> (closer, old))) (writeIORef socketCloser) (const act)
  (\n -> (r, n)) <$> readIORef count
  where
    peerPort = \case
      Socket.SockAddrInet p _ -> Just (show p)
      Socket.SockAddrInet6 p _ _ _ -> Just (show p)
      _ -> Nothing

-- | Whether the other end of a socket pair gets end of stream within 2 s.
seesEof :: Socket.Socket -> IO Bool
seesEof s = timeout 2_000_000 (SocketB.recv s 1) >>= \case
  Just bs -> pure (B.null bs)
  Nothing -> pure False

-- | A mock handler that answers nothing and returns when the client closes
-- the connection (with False if the client sent more than 64 KiB first,
-- which none of these clients do).
waitForClose :: MockConn -> IO Bool
waitForClose mc = (== Nothing) <$> recvBytes mc 65536

-- | The mock handler's outcome: 'nextResult' waits 10 s for it, so a
-- connection the client left open fails the test.
handlerResult :: MockServer r -> IO (Either String r)
handlerResult srv = either (Left . show) Right <$> nextResult srv

spec :: Spec
spec = describe "a socket close that fails" $ do
  describe "closeSocketWith" $ do
    it "closes the descriptor itself if the close failed after marking the socket closed" $
      bracket (Socket.socketPair Socket.AF_UNIX Socket.Stream 0) (\(a, b) -> Socket.close a >> Socket.close b) $ \(a, b) -> do
        closeSocketWith brokenClose a
        fd <- Socket.unsafeFdSocket a
        eof <- seesEof b
        (fd, eof) `shouldBe` (-1, True)

    it "leaves the socket as it is if the close failed before marking it closed" $
      bracket (Socket.socketPair Socket.AF_UNIX Socket.Stream 0) (\(a, b) -> Socket.close a >> Socket.close b) $ \(a, b) -> do
        closeSocketWith (\_ -> throwIO (userError "failed early")) a
        fd <- Socket.unsafeFdSocket a
        fd `shouldNotBe` (-1)
        Socket.close a
        seesEof b `shouldReturn` True

    it "rethrows an asynchronous exception, having closed the descriptor" $
      bracket (Socket.socketPair Socket.AF_UNIX Socket.Stream 0) (\(a, b) -> Socket.close a >> Socket.close b) $ \(a, b) -> do
        -- Whatever the broken close throws: under GHC's native I/O
        -- manager on Windows, with network before 3.3, 'socketToHandle'
        -- itself fails, with an 'ErrorCall', having marked the socket
        -- closed.
        r <- try (closeSocketWith (\s -> brokenClose s `catch` \(_ :: SomeException) -> throwIO ThreadKilled) a)
        eof <- seesEof b
        (r, eof) `shouldBe` (Left ThreadKilled, True)

  describe "the broken close of these tests" $
    it "leaves no open handle to close the descriptor's number again" $
      bracket (Socket.socketPair Socket.AF_UNIX Socket.Stream 0) (\(a, b) -> Socket.close a >> Socket.close b) $ \(a, _) -> do
        made <- newIORef Nothing
        closeSocketWith (brokenCloseNoting (writeIORef made . Just)) a
        -- No handle at all where 'socketToHandle' itself fails (see above).
        leftOpen <- readIORef made >>= maybe (pure False) (fmap not . hIsClosed)
        leftOpen `shouldBe` False

  describe "connect" $ do
    it "interrupted by a timeout: the timeout still wins and the socket is closed" $
      withTcpMockServer waitForClose $ \srv -> do
        (r, failures) <- withBrokenCloseTo (mockPort srv) $ do
          -- The mock never answers PRELOGIN, so this always times out.
          r <- timeout 300_000 (connect (mockConnectInfo srv))
          -- Nothing to close if it did connect, but don't leak it.
          maybe (pure ()) close r
          pure (void r)
        closed <- handlerResult srv
        (r, failures, closed) `shouldBe` (Nothing, 1, Right True)

    it "failing: its exception is thrown, not the close's, and the socket is closed" $ do
      let refusal = ServerMessage
            { msgNumber = 18456, msgState = 1, msgClass = 14, msgText = "Login failed for user 'mockuser'."
            , msgServer = "mock", msgProcedure = "", msgLine = 1 }
      withTcpMockServer (\mc -> serveLogin [errorToken refusal, doneToken 0x0002 0] mc >> waitForClose mc) $ \srv -> do
        (r, failures) <- withBrokenCloseTo (mockPort srv) $
          try (connect (mockConnectInfo srv) >>= close)
        closed <- handlerResult srv
        (either (\(LoginError m) -> Left (msgNumber m)) Right r, failures, closed)
          `shouldBe` (Left 18456, 1, Right True)

  describe "close" $ do
    it "returns normally, and the socket is closed" $
      withTcpMockServer (\mc -> cannedLoginServer defaultLoginResponse mc >> pure ()) $ \srv -> do
        ((), failures) <- withBrokenCloseTo (mockPort srv) $ do
          conn <- connect (mockConnectInfo srv)
          close conn
          -- Later use fails as after any close.
          try (execute conn "SELECT 1") >>= \case
            Left (ConnectionClosedBy ClosedByClient) -> pure ()
            other -> expectationFailure ("used after close: " ++ show other)
        closed <- handlerResult srv
        (failures, closed) `shouldBe` (1, Right ())

  describe "the finalizer of a connection dropped without close" $
    it "closes the socket" $
      withTcpMockServer (\mc -> cannedLoginServer defaultLoginResponse mc >> pure ()) $ \srv -> do
        ((), failures) <- withBrokenCloseTo (mockPort srv) $ do
          connectAndDrop (mockConnectInfo srv)
          performMajorGC
          performMajorGC
          -- The finalizer runs on a thread of its own; wait for the mock
          -- to see the close before putting 'socketCloser' back.
          closed <- handlerResult srv
          closed `shouldBe` Right ()
        failures `shouldBe` 1

-- | Connect and let go of the connection.  Not inlined, so that nothing
-- here keeps it.
connectAndDrop :: ConnectInfo -> IO ()
connectAndDrop ci = connect ci >>= evaluate >> pure ()
{-# NOINLINE connectAndDrop #-}
