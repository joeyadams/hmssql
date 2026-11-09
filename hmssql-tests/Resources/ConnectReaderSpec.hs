-- | 'connect' interrupted just after it started the connection's reader
-- thread must not close the socket under that thread.  The reader may be
-- between a receive that found nothing to read and the start of its wait
-- for more: a wait that starts on a descriptor just after another thread
-- closed it leaves a stale registration in GHC's IO manager (before GHC
-- 9.14), and on macOS, closing the next socket that gets the number then
-- fails (see 'Hmssql.Connection.Internal.closeSocket').  Before the fix,
-- the reader was started inside the part of 'connect' whose failure
-- cleanup closes the socket, and that cleanup didn't stop it.
--
-- The gap was a few instructions wide.  To land in it, the mock server
-- signals as it sends the login response, and a thread on another
-- capability waits a delay swept across the client's handling of that
-- response, then throws to the connecting thread.  A hook on the socket
-- close records whether a reader thread started by this attempt is still
-- alive when 'connect' closes the socket.
--
-- Serial (in "Resources."): it replaces the process-wide 'socketCloser',
-- lists the process's threads, and counts file descriptors.  It reads
-- their labels with 'threadLabelOf', not 'GHC.Conc.Sync.threadLabel',
-- which can crash the process on a thread without a label.
module Resources.ConnectReaderSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (filterM, forM_, replicateM, unless, when)
import Data.IORef
import Data.List (sort)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (ThreadStatus (..), listThreads, numCapabilities, threadStatus)
import qualified Network.Socket as Socket
import Test.Hspec

import Hmssql
import Hmssql.Connection.Internal (socketCloser)
import MockServer
import Resources.Helpers (backendHandles, backendHandlesReturnTo, fdCount, fdSlack, settle, threadLabelOf)

data Snipe = Snipe
  deriving (Show)

instance Exception Snipe

-- | Attempts to run.
attempts :: Int
attempts = 3000

readerLabel :: String
readerLabel = "hmssql: connection reader"

-- | The live threads labelled as a connection's reader.
liveReaders :: IO [ThreadId]
liveReaders = do
  ts <- listThreads
  flip filterM ts $ \t -> do
    label <- threadLabelOf t
    status <- threadStatus t
    pure (label == Just readerLabel && status `notElem` [ThreadFinished, ThreadDied])

spec :: Spec
spec = describe "connect interrupted just after starting its reader" $
  it "never closes the socket while the reader it started is running" $ do
    if numCapabilities < 2
      then pendingWith "needs -N2 or more, to interrupt connect from another capability"
      else run

run :: IO ()
run = do
  signal <- newIORef Nothing
  let handler mc = do
        -- The signal goes just before the response, not after it: on
        -- Windows the mock's send returns after the client has the bytes,
        -- and a fast client had finished connecting before any delay
        -- counted from there, so that no attempt was interrupted.
        _ <- serveLoginAfter (readIORef signal >>= mapM_ (`tryPutMVar` ())) defaultLoginResponse mc
        serveRequests (\_ _ -> pure [doneToken 0 0]) mc
  withMockServer handler $ \srv -> do
    let ci = mockConnectInfo srv
    me <- myThreadId
    -- Set while 'connect' runs: the readers alive before it started.
    inConnect <- newIORef Nothing
    violations <- newIORef (0 :: Int)
    -- Only a close on this thread is 'connect' closing its socket.  The
    -- finalizer of a connection from an earlier attempt runs on a thread
    -- of its own, whenever a garbage collection finds the connection
    -- unreachable, and closes that connection's socket again (it was
    -- already closed by 'close').  When that happens during a later
    -- 'connect' that has started its reader, the reader is rightly
    -- running, and the close is not that 'connect' closing its socket.
    let closer s = do
          onThisThread <- (== me) <$> myThreadId
          when onThisThread $ readIORef inConnect >>= mapM_ (\before -> do
            now <- liveReaders
            unless (null (filter (`notElem` before) now)) $
              atomicModifyIORef' violations (\n -> (n + 1, ())))
          Socket.close s
        -- One connect, interrupted the given number of nanoseconds after
        -- the mock began sending the login response (if given).  Returns whether
        -- connect was interrupted, and how long after the response it
        -- returned.
        attempt :: Maybe Word64 -> IO (Bool, Word64)
        attempt delayNs = mask $ \restore -> do
          sent <- newEmptyMVar
          writeIORef signal (Just sent)
          fired <- newEmptyMVar
          sentAt <- newIORef 0
          sniper <- forkIO $ do
            takeMVar sent
            t0 <- getMonotonicTimeNSec
            writeIORef sentAt t0
            forM_ delayNs $ \d -> do
              let spin = getMonotonicTimeNSec >>= \t -> unless (t - t0 >= d) spin
              spin
              throwTo me Snipe
            putMVar fired ()
          liveReaders >>= writeIORef inConnect . Just
          r <- try (restore (connect ci))
          writeIORef inConnect Nothing
          t1 <- getMonotonicTimeNSec
          -- Let the sniper finish; its exception may arrive here instead.
          _ <- try @Snipe (restore (takeMVar fired))
          killThread sniper
          t0 <- readIORef sentAt
          case r of
            Right conn -> close conn >> pure (False, t1 - t0)
            Left Snipe -> pure (True, t1 - t0)
    bracket (atomicModifyIORef' socketCloser (\old -> (closer, old))) (writeIORef socketCloser) $ \_ -> do
      -- How long connect goes on after the login response, to sweep the
      -- delay across it.
      spans <- replicateM 20 (snd <$> attempt Nothing)
      let span_ = max 20_000 (sort spans !! 10 * 3 `div` 2)
      settle
      fds0 <- fdCount
      handles0 <- backendHandles
      interrupted <- newIORef (0 :: Int)
      forM_ [0 .. attempts - 1] $ \i -> do
        let delay = (fromIntegral i * 7919) `mod` span_
        (hit, _) <- attempt (Just delay)
        when hit $ modifyIORef' interrupted (+ 1)
      settle
      fds1 <- fdCount
      n <- readIORef interrupted
      v <- readIORef violations
      -- The sweep did cover the end of connect: some attempts finished,
      -- some didn't.
      (v, n > 0 && n < attempts) `shouldBe` (0, True)
      -- On Windows, exactly: every handle a connect opened was closed.
      backendHandlesReturnTo handles0
      case (fds0, fds1) of
        (Just f0, Just f1) -> (f1 - f0) `shouldSatisfy` (<= 2 + fdSlack)
        _ -> pure ()
