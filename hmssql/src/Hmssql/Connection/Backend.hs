{-# LANGUAGE CPP #-}
-- | What a connection's bytes travel on: a 'Backend' is a connected byte
-- stream, as a record of operations.  hmssql has three of its own (TCP,
-- and on Windows Shared Memory and Named Pipes), chosen by
-- 'Hmssql.Connection.connectProtocol'.  TLS, when the connection is
-- encrypted, runs on top of whichever it is.
--
-- On Linux and macOS TCP uses network's calls.  On Windows all three use
-- hmssql's own overlapped I/O, except under GHC's native I/O manager with
-- a network and a GHC that support it, where TCP uses network's calls and
-- the pipes the manager ('networkTcp').
--
-- The record is public so that a transport can be replaced or wrapped
-- without changing hmssql: 'Hmssql.Connection.ProtocolCustom' connects
-- over a 'Backend' the caller makes, which may be one of these with an
-- operation changed, a tunnel, or an in-memory stream for a test.
--
-- The pipe functions work on Windows only, since SQL Server listens on
-- pipes only there.  On other platforms they throw an 'IOException'
-- ('pipesSupported' says which it is).
module Hmssql.Connection.Backend
  ( -- * The record
    Backend (..)

    -- * TCP
  , tcpBackend
  , socketBackend

    -- * Shared Memory and Named Pipes
  , pipeBackend
  , pipesSupported
  , sharedMemoryPipe
  , namedPipe
  , isLocalHost
  , isDefaultInstance

    -- * Serving a pipe
  , PipeListener
  , pipeListen
  , pipeAccept
  , pipeListenerClose

    -- * Internal
  , networkTcp
  , tcpBackendWith
  , connectAddresses
  , addressConnectTimeout
  , pipeBackendMasked
  , closeSocket
  , closeSocketWith
  , socketCloser
  ) where

import Control.Exception
import Control.Monad (void, when)
import qualified Data.ByteString as B
import Data.Char (toLower)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Word (Word8)
#if defined(mingw32_HOST_OS)
import Foreign.C.Types (CInt (..), CUIntPtr (..))
#else
import Foreign.C.Types (CInt (..))
#endif
import Foreign.Ptr (Ptr)
import Network.HostName (getHostName)
import Network.Socket (Socket)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

#if defined(mingw32_HOST_OS)
import Control.Concurrent (rtsSupportsBoundThreads)
import Foreign.Ptr (intPtrToPtr)
import Hmssql.Connection.Backend.Windows hiding (PipeListener, openPipe, pipeDisconnect, pipeListenerAccept, pipeListenerClose, pipeListenerOpen)
import qualified Hmssql.Connection.Backend.Windows as Windows
import Hmssql.Connection.Backend.WinIO (PipeIO, nativeIO)
import qualified Hmssql.Connection.Backend.WinIO as WinIO
#else
import GHC.IO.Exception (IOErrorType (..), IOException (..))
#endif

-- | A connected byte stream.
--
-- One thread receives at a time and one sends at a time, but a receive
-- and a send may be in progress together, and 'backendStopReceiving',
-- 'backendShutdown' and 'backendClose' are called from other threads
-- while they are.
--
-- An asynchronous exception should end a blocked 'backendRecv',
-- 'backendSend' or 'backendSendMany' promptly.  hmssql doesn't use the
-- backend's stream afterwards: an interrupted send or receive ends the
-- connection.  (Canceling a query never interrupts one of these: the
-- thread that is canceled waits for the connection's reader thread, and
-- the Attention is an ordinary send.)  A backend that can't be
-- interrupted in some operation should say so; hmssql's own can be in
-- all of them, and network's except where 'socketBackend' says.
--
-- The operations report failure by throwing 'IOException'.  They must
-- not refer to the 'Hmssql.Connection.Connection' they serve, which
-- would keep a connection dropped without
-- 'Hmssql.Connection.close' from ever being collected.
data Backend = Backend
  { backendRecv :: !(Ptr Word8 -> Int -> IO Int)
    -- ^ Receive up to that many bytes into the buffer, waiting until at
    -- least one arrives: how many did, or 0 at the end of the stream.
  , backendSend :: !(B.ByteString -> IO ())
    -- ^ Send all of the bytes.  hmssql always passes whole units: one or
    -- more whole TDS packets, on a MARS connection whole SMP packets, or
    -- over TLS exactly one TLS record.  A transport that delivers writes
    -- one at a time must keep it one write: SQL Server reads a pipe a
    -- write at a time, and drops a connection whose write holds a part of
    -- a packet, or two TLS records.
  , backendSendMany :: !([[B.ByteString]] -> IO ())
    -- ^ Send all of the writes, in order, with no other send's bytes
    -- between them.  Each write is given as its pieces, and together the
    -- pieces of one write are a unit as for 'backendSend', which one
    -- piece alone need not be: a plaintext SMP packet comes as its
    -- header and its TDS packet.  Where the write boundaries don't
    -- matter (a socket) all of it can go in one system call; where they
    -- do (a pipe) each write must reach the other end as one.
  , backendStopReceiving :: !(IO ())
    -- ^ Wake a blocked receive, and make it and every later one fail.
    -- Sends still work.  It must not block, and is called from any
    -- thread, more than once, and after 'backendClose'.  A backend whose
    -- receive an asynchronous exception interrupts reliably may do
    -- nothing here, as the socket backend does with network's calls: hmssql
    -- kills its reader thread right after calling it.
  , backendShutdown :: !(IO ())
    -- ^ Make blocked and later sends and receives fail, and let the other
    -- end know, so that a server holding part of a message stops waiting
    -- for the rest.  Called from any thread, more than once, and after
    -- 'backendClose', but never from inside one of the backend's own
    -- operations.  It should return promptly.  A socket is shut down and
    -- stays open; a pipe, which has no shutdown, is closed here.
  , backendClose :: !(IO ())
    -- ^ Release the stream.  hmssql calls it once its reader thread has
    -- stopped and no send is in progress, and may call it again.  It
    -- should not throw: there is nothing a caller could do.
  , backendSocket :: !(Maybe Socket)
    -- ^ The socket underneath, if there is one: to set an option on it
    -- (keep-alive, a buffer size) or ask for the peer's address.
    -- Reading, writing or closing it is the backend's business.
  }

-- | Whether this platform has Shared Memory and Named Pipes: Windows only.
pipesSupported :: Bool
#if defined(mingw32_HOST_OS)
pipesSupported = True
#else
pipesSupported = False
#endif

------------------------------------------------------------------------------
-- TCP

-- | Whether TCP goes through network's own calls: on every platform but
-- Windows, and on Windows under GHC's native I/O manager, with or without
-- @-threaded@, when hmssql was built against network 3.3 or later with a
-- GHC whose native manager network supports.  The pipes then go through
-- that manager too.  Otherwise, on Windows, TCP and the pipes go through
-- hmssql's own overlapped I/O.
networkTcp :: Bool
#if defined(mingw32_HOST_OS)
networkTcp = nativeIO
#else
networkTcp = True
#endif

-- | Connect over TCP to the host and port (a number or a service name).
-- The host's addresses are tried in the resolver's order until one
-- accepts; if none does, the last failure is thrown, an 'IOException'.
-- An address that neither accepts nor refuses within
-- 'addressConnectTimeout' is given up and the next one tried; the last
-- address alone waits as long as the operating system does.  Nagle's
-- algorithm is turned off (@TCP_NODELAY@).
--
-- Interruptible.  An exception that arrives just as it returns can lose
-- the backend, so call it masked (@mask_@ will do: the waits inside are
-- interruptible) and install the cleanup before unmasking, as 'bracket'
-- does.
tcpBackend :: String -> String -> IO Backend
tcpBackend host port = mask $ \restore -> tcpBackendWith restore host port

-- | 'tcpBackend', called masked, with the caller's @restore@ for the parts
-- that wait: the lookup and each connect.  Returns still masked.
tcpBackendWith :: (forall a. IO a -> IO a) -> String -> String -> IO Backend
tcpBackendWith restore host port = do
  sock <- restore resolve >>= connectAddresses restore
  socketBackend sock `onException` closeSocket sock
  where
    resolve = do
      let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream }
      addrs <- lookupHost hints
      case addrs of
        addr : rest -> pure (addr :| rest)
        [] -> throwIO $ userError $ "cannot resolve " ++ host
    lookupHost hints
#if defined(mingw32_HOST_OS)
      -- On hmssql's own Windows path the lookup runs off the caller's
      -- thread, as the backend's other blocking calls do.
      | not networkTcp = lookupAddresses hints host port
#endif
      | otherwise = Socket.getAddrInfo (Just hints) (Just host) (Just port)

-- | How long an address that is not the host's last is given to accept
-- or refuse before the next address is tried: 4 seconds, in
-- microseconds.  An address that refuses fails at once; one that is
-- silent (a firewall that drops the SYN, a host that is down, a stale
-- DNS record) fails only when the operating system gives up, after
-- about two minutes on Linux and 21 seconds on Windows, so without this
-- a silent first address cost that whole wait.  Four seconds outlasts
-- one retransmission of the SYN on either platform, so a single lost
-- SYN doesn't skip a working address, and leaves a caller's 15-second
-- @timeout@ room for a third address behind two silent ones.
addressConnectTimeout :: Int
addressConnectTimeout = 4_000_000

-- | Connect to the first of the addresses that accepts, trying them in
-- the order given (the resolver's: a name such as @localhost@ often
-- resolves to @::1@ before @127.0.0.1@, and the server may listen on only
-- one of them).  Every address but the last is given
-- 'addressConnectTimeout'; when it refuses or the time runs out, the
-- next is tried.  The last address waits as long as the operating
-- system does, so a host with one address behaves as a plain connect,
-- and when it fails too, its failure is the one thrown.  Called masked,
-- with the caller's @restore@ for the wait of each connect; a caller's
-- @timeout@ around the whole still bounds it, since the limit here
-- catches only its own expiry.
connectAddresses :: (forall a. IO a -> IO a) -> NonEmpty Socket.AddrInfo -> IO Socket
connectAddresses restore = connectFirst
  where
    connectFirst :: NonEmpty Socket.AddrInfo -> IO Socket
    connectFirst (addr :| rest) = case rest of
      [] -> connectTo addr
      next : more -> try (timeout addressConnectTimeout (connectTo addr)) >>= \case
        Right (Just sock) -> pure sock
        Right Nothing -> connectFirst (next :| more)
        Left (_ :: IOException) -> connectFirst (next :| more)

    connectTo :: Socket.AddrInfo -> IO Socket
    connectTo addr
#if defined(mingw32_HOST_OS)
      -- On hmssql's own Windows path the connect, a foreign call that
      -- nothing interrupts, runs in the threaded runtime on a thread of its
      -- own, which closes the socket itself if the caller has gone by the
      -- time it ends.  Without -threaded it runs on a worker of the I/O
      -- manager, which does the same.
      | not networkTcp, rtsSupportsBoundThreads = abandonable (connectNow addr Socket.connect) closeSocket
      | not networkTcp = do
          sock <- newSocket addr
          connectOnWorker closeSocket sock (Socket.addrAddress addr)
          Socket.setSocketOption sock Socket.NoDelay 1 `onException` closeSocket sock
          pure sock
#endif
      -- network's connect.  On Windows under GHC's native I/O manager it
      -- is a blocking foreign call, which nothing interrupts before it
      -- returns: that is network's behaviour, and hmssql's there.
      | otherwise = connectNow addr (\sock to -> restore (Socket.connect sock to))

    connectNow :: Socket.AddrInfo -> (Socket -> Socket.SockAddr -> IO ()) -> IO Socket
    connectNow addr connectIt = do
      sock <- newSocket addr
      (do
          connectIt sock (Socket.addrAddress addr)
          -- Fails (EINVAL on macOS) if the server has already reset the
          -- connection; reported like a failed connect.
          Socket.setSocketOption sock Socket.NoDelay 1)
        `onException` closeSocket sock
      pure sock

    newSocket addr = Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)

-- | A backend over a connected socket, which it owns from then on:
-- 'backendClose' closes it.
--
-- It uses network's own calls on Linux and macOS, and on Windows under
-- GHC's native I/O manager when 'networkTcp' says network supports that
-- manager.  There a send of many pieces and a connect are blocking foreign
-- calls in network, which an asynchronous exception doesn't interrupt, and
-- which without @-threaded@ stop every Haskell thread while they block.
-- Otherwise, on Windows, the socket is read and written as a handle, with
-- hmssql's own overlapped I/O, because network's calls block in a foreign
-- call there, where nothing can interrupt them; a program linked without
-- @-threaded@ must then run with GHC's default I/O manager.
socketBackend :: Socket -> IO Backend
socketBackend sock
#if defined(mingw32_HOST_OS)
  | not networkTcp = do
      requireRuntime
      fd <- Socket.unsafeFdSocket sock
      hio <- newHandleIO (intPtrToPtr (fromIntegral fd)) False
        (Socket.shutdown sock Socket.ShutdownBoth)
        -- The handle is closed through the socket, which network marks
        -- closed, so its finalizer doesn't close the number again.
        (closeSocket sock)
      pure (handleBackend hio) { backendSocket = Just sock }
#endif
  | otherwise = pure (networkSocketBackend sock)

-- | The backend of network's own calls over a connected socket.
networkSocketBackend :: Socket -> Backend
networkSocketBackend sock = Backend
  { backendRecv = Socket.recvBuf sock
  , backendSend = Socket.sendAll sock
    -- Every piece of every write in one vectored send: a socket has no
    -- write boundaries to keep.
  , backendSendMany = Socket.sendMany sock . concat
    -- The reader thread waits in GHC's I/O manager, where the exception
    -- that follows this reaches it.
  , backendStopReceiving = pure ()
  , backendShutdown = Socket.shutdown sock Socket.ShutdownBoth `catch` \(_ :: IOException) -> pure ()
  , backendClose = closeSocket sock
  , backendSocket = Just sock
  }

-- | Close a socket, where a failure to close must not get in the way: in the
-- cleanup after a failed 'Hmssql.Connection.connect' (where it would
-- replace the exception that made it fail), in 'Hmssql.Connection.close',
-- and in the finalizer of a connection dropped without it.  It throws no
-- synchronous exception, and the descriptor is closed even when
-- 'Socket.close' fails, which it can:
--
-- 'Socket.close' marks the socket closed, then closes the descriptor with
-- GHC's @closeFdWith@, which first removes it from the IO manager.  With
-- kqueue (macOS, BSD), that throws @kevent: does not exist@ when the IO
-- manager's table has a registration for the descriptor number that the
-- kernel doesn't.  Before GHC 9.14, a thread that starts to wait on a
-- descriptor just after another thread closed it leaves one (checked on
-- 9.6 to 9.12), and the next socket to get the number then fails to close.
-- @closeFdWith@ gives up before closing the descriptor (in 9.14 too),
-- which would stay open (and the connection with it) for the life of the
-- process, since the socket is already marked closed.  So on failure the
-- descriptor is closed here directly: not through @closeFdWith@ again,
-- which would block for good (after that failure it leaves the IO
-- manager's lock for the descriptor taken, and anything waiting on a
-- descriptor under the same lock hangs; nothing here can undo that).
-- Both are bugs in GHC's kqueue IO manager.
--
-- Runs masked, so that an asynchronous exception can't come between
-- 'Socket.close' marking the socket closed and closing the descriptor.
closeSocket :: Socket -> IO ()
closeSocket sock = do
  closeIt <- readIORef socketCloser
  closeSocketWith closeIt sock

-- | 'closeSocket' with the given way to close the socket, standing in for
-- 'Socket.close'.  If it fails after marking the socket closed (as
-- 'Socket.close' does when @closeFdWith@ fails), the descriptor is closed
-- directly; if it fails before, the socket is left as it is (network's
-- finalizer closes it).  A synchronous exception is not rethrown.
closeSocketWith :: (Socket -> IO ()) -> Socket -> IO ()
closeSocketWith closeIt sock = mask_ $ do
  -- The descriptor only ever changes to network's mark of a closed
  -- socket, so if the close fails after the socket was marked closed,
  -- this is the descriptor it left open.
  fd <- Socket.unsafeFdSocket sock
  closeIt sock `catch` \(e :: SomeException) -> do
    now <- Socket.unsafeFdSocket sock
    when (fd /= closedMark && now == closedMark) $ void (closeDescriptor (fromIntegral fd))
    case fromException e of
      Just (_ :: SomeAsyncException) -> throwIO e
      Nothing -> pure ()
  where
    -- All bits set, in whatever type network gives a descriptor: -1 as a
    -- CInt, and on Windows from network 3.3 INVALID_SOCKET as a CULong.
    closedMark = fromIntegral (-1 :: Int)

-- | How 'closeSocket' closes a socket: 'Socket.close'.  Tests replace it to
-- make closing fail.
socketCloser :: IORef (Socket -> IO ())
socketCloser = unsafePerformIO (newIORef Socket.close)
{-# NOINLINE socketCloser #-}

#if defined(mingw32_HOST_OS)
-- A SOCKET is a UINT_PTR.
foreign import ccall unsafe "closesocket"
  closeDescriptor :: CUIntPtr -> IO CInt
#else
foreign import ccall unsafe "close"
  closeDescriptor :: CInt -> IO CInt
#endif

------------------------------------------------------------------------------
-- Pipes

-- | Connect to a named pipe by its path, such as
-- @\\\\.\\pipe\\SQLLocal\\MSSQLSERVER@ ('sharedMemoryPipe', 'namedPipe').
-- Throws an 'IOException' if the pipe can't be opened; on a platform
-- without pipes, always.
--
-- The pipe is opened so that its server can identify the client but not
-- act as the client (@SECURITY_IDENTIFICATION@), the most restrictive
-- level SQL Server was seen to accept.  A pipe on another machine is
-- reached over SMB, so Windows authenticates the user to that machine
-- first.  Interruptible, except that without @-threaded@ the open itself
-- stops the program while it waits; call it masked, as 'tcpBackend'.
--
-- The pipes go through GHC's native I/O manager exactly when TCP goes
-- through network's calls ('networkTcp'), with or without @-threaded@, and
-- through hmssql's own overlapped I/O otherwise, where a program linked
-- without @-threaded@ must run with GHC's default I/O manager.
pipeBackend :: FilePath -> IO Backend
pipeBackend path = mask_ (pipeBackendMasked path)

-- | 'pipeBackend', called masked.
pipeBackendMasked :: FilePath -> IO Backend
#if defined(mingw32_HOST_OS)
pipeBackendMasked path
  | nativeIO = pipeIOBackend <$> WinIO.openPipe path
  | otherwise = handleBackend <$> Windows.openPipe path
#else
pipeBackendMasked path = throwIO (noPipes ("open " ++ path))
#endif

-- | The pipe of the Shared Memory protocol for an instance on this
-- machine, by the instance's name: empty, or @MSSQLSERVER@, for the
-- default instance.  SQL Server's Shared Memory protocol is TDS over
-- this local pipe.
sharedMemoryPipe :: String -> FilePath
sharedMemoryPipe instanceName = "\\\\.\\pipe\\SQLLocal\\" ++ if defaultInstance instanceName then "MSSQLSERVER" else instanceName

-- | The pipe of the Named Pipes protocol for an instance on a host, at the
-- path SQL Server uses unless it was configured with another.  A host
-- that is this machine ('isLocalHost', or a loopback address) gives the
-- local form, @\\\\.\\pipe\\...@, which doesn't go through the network.
namedPipe :: Bool -> String -> String -> FilePath
namedPipe local host instanceName =
  "\\\\" ++ (if local then "." else host) ++ "\\pipe\\"
    ++ (if defaultInstance instanceName then "" else "MSSQL$" ++ instanceName ++ "\\")
    ++ "sql\\query"

defaultInstance :: String -> Bool
defaultInstance = isDefaultInstance

-- | Whether an instance name means the default instance: empty, or
-- @MSSQLSERVER@ in any case.
isDefaultInstance :: String -> Bool
isDefaultInstance name = null name || map toLower name == "mssqlserver"

-- | Whether a host name means this machine: @localhost@, @.@, @(local)@,
-- or the machine's own name, in any case.  An IP address is not, even a
-- loopback one: Microsoft's clients connect to those over TCP.
isLocalHost :: String -> IO Bool
isLocalHost host
  | name `elem` ["localhost", ".", "(local)"] = pure True
  | otherwise = do
      own <- map toLower <$> getHostName
      -- The machine's name may come with its domain.
      pure (not (null name) && (name == own || name == takeWhile (/= '.') own))
  where
    name = map toLower host

-- | The server side of a named pipe: for a mock server in tests, or a
-- proxy.
#if defined(mingw32_HOST_OS)
data PipeListener
  = HandleListener !Windows.PipeListener
    -- ^ On hmssql's own overlapped I/O.
  | ManagerListener !WinIO.PipeListener
    -- ^ Through GHC's native I/O manager ('networkTcp').
#else
-- There is none on this platform ('pipeListen' throws), so the type has
-- no values.
data PipeListener
#endif

-- | Create a named pipe that clients on this machine can connect to, such
-- as @\\\\.\\pipe\\my-test-pipe@.  No pipe of that name may exist yet.
-- Creating one needs no privilege.  Its connections go through the same
-- I/O as 'pipeBackend''s.
pipeListen :: FilePath -> IO PipeListener
#if defined(mingw32_HOST_OS)
pipeListen path
  | nativeIO = ManagerListener <$> WinIO.pipeListenerOpen path
  | otherwise = HandleListener <$> Windows.pipeListenerOpen path
#else
pipeListen path = throwIO (noPipes ("create " ++ path))
#endif

-- | Wait for a client: the connection to it, and an action that
-- disconnects the client abruptly, discarding what it hasn't read yet (so
-- that its next read or write fails, as after a TCP reset).  The backend
-- must still be closed.  Interruptible; one thread accepts at a time.
pipeAccept :: PipeListener -> IO (Backend, IO ())
#if defined(mingw32_HOST_OS)
pipeAccept listener = mask_ $ case listener of
  HandleListener l -> do
    hio <- Windows.pipeListenerAccept l
    pure (handleBackend hio, Windows.pipeDisconnect hio)
  ManagerListener l -> do
    pio <- WinIO.pipeListenerAccept l
    pure (pipeIOBackend pio, WinIO.pipeDisconnect pio)
#else
pipeAccept _ = throwIO (noPipes "accept")
#endif

-- | Stop listening.  Connections already accepted are not affected.  It
-- waits for an accept in progress, so stop the accepting thread first.
pipeListenerClose :: PipeListener -> IO ()
#if defined(mingw32_HOST_OS)
pipeListenerClose = \case
  HandleListener l -> Windows.pipeListenerClose l
  ManagerListener l -> WinIO.pipeListenerClose l
#else
pipeListenerClose _ = pure ()

noPipes :: String -> IOException
noPipes what = IOError Nothing UnsupportedOperation ("hmssql: " ++ what)
  "Shared Memory and Named Pipes are available on Windows only" Nothing Nothing
#endif

#if defined(mingw32_HOST_OS)
handleBackend :: HandleIO -> Backend
handleBackend hio = Backend
  { backendRecv = hioRecv hio
  , backendSend = hioSend hio
  , backendSendMany = hioSendMany hio
  , backendStopReceiving = hioStopReceiving hio
  , backendShutdown = hioShutdown hio
  , backendClose = hioClose hio
  , backendSocket = Nothing
  }

pipeIOBackend :: PipeIO -> Backend
pipeIOBackend pio = Backend
  { backendRecv = WinIO.pioRecv pio
  , backendSend = \bs -> WinIO.pioSendMany pio [[bs]]
  , backendSendMany = WinIO.pioSendMany pio
  , backendStopReceiving = WinIO.pioStopReceiving pio
    -- A pipe has no shutdown: closing it is how the other end learns.
  , backendShutdown = WinIO.pioClose pio
  , backendClose = WinIO.pioClose pio
  , backendSocket = Nothing
  }
#endif
