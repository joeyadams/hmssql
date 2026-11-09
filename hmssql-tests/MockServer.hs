-- | A tiny in-process TDS server for tests that need responses a real SQL
-- Server won't produce on demand (routing, odd encryption answers, malformed
-- tokens, ...).
--
-- It speaks plaintext TDS: PRELOGIN, then LOGIN7, then whatever the handler
-- does.  The one exception is 'serveLoginOnlyTls', a server with encryption
-- off, to which a client with encryption off sends LOGIN7 over TLS and
-- nothing else.  Otherwise it cannot do TLS, but it recognises a client's
-- TLS handshake ('ClientStartedTls') so tests can check that one was
-- attempted.
--
-- > it "..." $ withMockServer (cannedLoginServer [loginAckToken Tds74 "mock", doneToken 0 0]) $ \srv -> do
-- >   withConnection (mockConnectInfo srv) $ \conn -> ...
-- >   r <- nextResult srv       -- what the handler saw / returned
--
-- A handler is an ordinary function of the 'MockConn', so it can script any
-- exchange: 'recvMessage' / 'sendMessage' / 'sendTokens' / 'sendRaw' are the
-- building blocks, and 'serveLogin' / 'serveRequests' cover the usual parts.
module MockServer
  ( -- * Running a server
    MockServer
  , withMockServer
  , withTcpMockServer
  , withMockServerAt
  , withRefusingPort
  , MockTransport (..)
  , mockTransport
  , mockPort
  , nextResult
  , mockConnectInfo
  , MockError (..)

    -- * Talking to the client
  , MockConn
  , mcSocket
  , mcSocketMaybe
  , recvBytes
  , recvPacket
  , recvMessage
  , recvMessageMaybe
  , recvMessageWithReset
  , sendMessage
  , sendTokens
  , sendRaw
  , shutdownSend
  , resetConnection

    -- * Handshake
  , respondPrelogin
  , preloginReply
  , ClientStep (..)
  , awaitLogin7
  , expectLogin7
  , serveLogin
  , serveLoginAfter
  , serveLoginOnlyTls
  , serveLoginTls
  , serveRequests
  , cannedLoginServer
  , mockTlsKey
  , mockTlsCert

    -- * Token builders
  , defaultLoginResponse
  , loginAckToken
  , doneToken
  , envChangeToken
  , routingEnvChange
  , databaseEnvChange
  , beginTransactionEnvChange
  , rollbackTransactionEnvChange
  , resetConnectionEnvChange
  , messageToken
  , errorToken
  , infoToken
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.Chan
import Control.Exception
import Control.Monad (forever, unless, void)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Char (toLower)
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word64, Word8)
import Foreign.ForeignPtr (withForeignPtr)
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import qualified Network.TLS as TLS
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Compat (onMacOS, onWindows, randomBytes, timeoutInSlices, windowsNetworkTcp)
import Hmssql
import Hmssql.Connection.Backend
import Hmssql.Types
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (putBVarChar, putUsVarChar)
import Wire.Login7Parser (getLogin7)

------------------------------------------------------------------------------
-- Running

data MockServer r = MockServer
  { msEndpoint :: !MockEndpoint
  , msResults :: !(Chan (Either SomeException r))
  }

-- | Where a mock server listens.
data MockEndpoint
  = MockTcpPort !String
    -- ^ A TCP port on 127.0.0.1.
  | MockPipePath !FilePath
    -- ^ A named pipe on this machine (Windows).

-- | What a mock server listens on.
data MockTransport
  = MockTcp
  | MockPipe
    -- ^ A named pipe, so that the client under test runs its pipe backend
    -- against the mock.  Windows only.
  deriving (Eq, Show)

-- | The transport 'withMockServer' uses (@HMSSQL_TEST_MOCK_TRANSPORT@):
-- @tcp@, the default, or @pipe@.
mockTransport :: IO MockTransport
mockTransport = lookupEnv "HMSSQL_TEST_MOCK_TRANSPORT" >>= \case
  Nothing -> pure MockTcp
  Just v -> case map toLower v of
    "" -> pure MockTcp
    "tcp" -> pure MockTcp
    "pipe"
      | pipesSupported -> pure MockPipe
      | otherwise -> fail "HMSSQL_TEST_MOCK_TRANSPORT=pipe: named pipes exist on Windows only"
    _ -> fail ("HMSSQL_TEST_MOCK_TRANSPORT: expected tcp or pipe, not " ++ show v)

-- | The TCP port the server listens on (on 127.0.0.1).  For a test that
-- needs a port (a login redirect names one, say), which therefore runs its
-- server with 'withTcpMockServer': a server on a pipe has none.
mockPort :: MockServer r -> String
mockPort srv = case msEndpoint srv of
  MockTcpPort port -> port
  MockPipePath path -> error $
    "mockPort: this mock server listens on the pipe " ++ path ++ "; a test that needs a port uses withTcpMockServer"

-- | Failures of the mock itself (as opposed to the client under test).
data MockError
  = MockClientClosed
    -- ^ The client closed the connection where the handler expected a message.
  | MockUnexpected String
  deriving (Eq, Show)

instance Exception MockError

-- | Listen on an ephemeral local port and run the handler for every accepted
-- connection, each in its own thread.  The handler's outcome (its result or
-- exception) is queued for 'nextResult'.  The socket to the client is closed
-- when the handler returns.
--
-- If the client closed the connection first (the handler read its end of
-- stream), the mock's close resets the connection instead of answering with
-- a FIN, so the client's socket skips TIME_WAIT: otherwise every such
-- connection would hold a client port for 30 s, and a test run opening
-- thousands of connections (several runs at once, especially) would run out
-- of ephemeral ports ("Can't assign requested address").  The client has
-- finished with the connection by then, so it cannot tell the difference.
--
-- The server listens on the configured transport ('mockTransport'): TCP on
-- 127.0.0.1, or with @HMSSQL_TEST_MOCK_TRANSPORT=pipe@ a named pipe, where
-- the reset is a disconnect of the pipe.  A test of something only TCP has
-- asks for it with 'withTcpMockServer'.
withMockServer :: (MockConn -> IO r) -> (MockServer r -> IO a) -> IO a
withMockServer handler act = do
  transport <- mockTransport
  case transport of
    MockTcp -> withTcpMockServerAt (const handler) act
    MockPipe -> withPipeMockServer handler act

-- | 'withMockServer' over TCP whatever is configured: for a test that needs
-- the server's port ('mockPort'), its socket ('mcSocket'), or a behaviour
-- that only TCP has.
withTcpMockServer :: (MockConn -> IO r) -> (MockServer r -> IO a) -> IO a
withTcpMockServer = withTcpMockServerAt . const

-- | 'withTcpMockServer' with a handler that is told the server's own port
-- (to redirect a login to itself, say).  Always TCP: a redirect names a
-- port.
withMockServerAt :: (String -> MockConn -> IO r) -> (MockServer r -> IO a) -> IO a
withMockServerAt = withTcpMockServerAt

-- | A port on 127.0.0.1 that refuses connections for as long as the action
-- runs: a socket is bound to it and doesn't listen.  A port taken from a
-- listener that was then closed is free again, and a mock server started
-- by a test running beside this one was given it: the client meant to be
-- refused logged in there, and both tests failed.
--
-- macOS drops the SYN that reaches a socket that is bound and not listening,
-- so the connect times out (ETIMEDOUT after about 8 s) instead of being
-- refused.  There the port is a closed one, taken from a socket that was
-- bound and closed: macOS hands out ephemeral ports at random, so a mock
-- server started beside this test is unlikely to be given the same one.
withRefusingPort :: (Text -> IO a) -> IO a
withRefusingPort act = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  -- Without SO_REUSEADDR, which the mock servers set: with it on both
  -- sockets, Linux lets a second one bind a port that nobody listens on.
  if onMacOS
    then do
      port <- bracket (Socket.openSocket addr) Socket.close $ \sock -> do
        Socket.bind sock (Socket.addrAddress addr)
        Socket.socketPort sock
      act (T.pack (show port))
    else bracket (Socket.openSocket addr) Socket.close $ \sock -> do
      Socket.bind sock (Socket.addrAddress addr)
      Socket.socketPort sock >>= act . T.pack . show

withTcpMockServerAt :: (String -> MockConn -> IO r) -> (MockServer r -> IO a) -> IO a
withTcpMockServerAt handler act = do
  results <- newChan
  stopping <- newIORef False
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.setSocketOption lsock Socket.ReuseAddr 1
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 16
    port <- Socket.socketPort lsock
    let acceptLoop = forever $ do
          (sock, _) <- Socket.accept lsock
          -- Send each 'sendRaw' as its own segment, so tests can split the
          -- stream at chosen offsets without Nagle delays.
          Socket.setSocketOption sock Socket.NoDelay 1
          void $ forkIO $ do
            conn <- tcpMockConn sock
            r <- try (handler (show port) conn) `finally` closeMock conn
            writeChan results r
        -- On Windows no exception reaches a thread inside network's
        -- accept (killThread on one never returned), so the listener is
        -- closed first: the accept then fails, and the loop ends on that.
        windowsLoop = acceptLoop `catch` \(e :: IOException) -> do
          stopped <- readIORef stopping
          unless stopped (throwIO e)
        stop tid
          | onWindows = writeIORef stopping True >> Socket.close lsock >> killThread tid
          | otherwise = killThread tid
    bracket (forkIO (if onWindows then windowsLoop else acceptLoop)) stop $ \_ ->
      act MockServer { msEndpoint = MockTcpPort (show port), msResults = results }

-- | A mock server on a named pipe of its own (Windows).
withPipeMockServer :: (MockConn -> IO r) -> (MockServer r -> IO a) -> IO a
withPipeMockServer handler act = do
  results <- newChan
  path <- newPipePath
  bracket (pipeListen path) pipeListenerClose $ \listener -> do
    let acceptLoop = forever $ do
          (backend, disconnect) <- pipeAccept listener
          void $ forkIO $ do
            conn <- pipeMockConn backend disconnect
            r <- try (handler conn) `finally` closeMock conn
            writeChan results r
    -- The accept waits where an exception reaches it.
    bracket (forkIO acceptLoop) killThread $ \_ ->
      act MockServer { msEndpoint = MockPipePath path, msResults = results }

-- | A pipe name no other mock server has: random per process, then counted.
newPipePath :: IO FilePath
newPipePath = do
  n <- atomicModifyIORef' pipeCounter (\i -> (i + 1, i))
  pure ("\\\\.\\pipe\\hmssql-mock-" ++ pipeTag ++ "-" ++ show n)

pipeCounter :: IORef Int
pipeCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE pipeCounter #-}

pipeTag :: String
pipeTag = unsafePerformIO (concatMap show . B.unpack <$> randomBytes 4)
{-# NOINLINE pipeTag #-}

-- | Wait (up to 10 s) for the next connection handler to finish.
nextResult :: MockServer r -> IO (Either SomeException r)
nextResult srv =
  timeoutInSlices 10_000_000 (readChan (msResults srv))
    >>= maybe (throwIO (MockUnexpected "timed out waiting for the mock handler")) pure

-- | Settings that reach the mock: plaintext ('EncryptNotSup') and no session
-- setup batches.  Override fields as needed.
--
-- The protocol is named, never left to 'ProtocolAuto': on Windows that
-- would answer a refused TCP connect by trying the Named Pipes protocol,
-- which for 127.0.0.1 is the real SQL Server on this machine.
mockConnectInfo :: MockServer r -> ConnectInfo
mockConnectInfo srv = defaultConnectInfo
  { connectHost = "127.0.0.1"
  , connectPort = case msEndpoint srv of
      MockTcpPort port -> T.pack port
      MockPipePath _ -> connectPort defaultConnectInfo
  , connectProtocol = case msEndpoint srv of
      MockTcpPort _ -> ProtocolTcp
      MockPipePath path -> ProtocolCustom (pipeBackend path)
  , connectUser = "mockuser"
  , connectPassword = "mockpassword"
  , connectDatabase = "mockdb"
  , connectEncryption = EncryptNotSup
  , connectSessionSetup = []
  }

------------------------------------------------------------------------------
-- Packet I/O

-- | The server's end of one connection.  The transport is behind five
-- operations, so a handler is the same over TCP and over a pipe.
data MockConn = MockConn
  { mcRecv :: !(IO B.ByteString)
    -- ^ Some bytes; empty at the end of the stream.
  , mcSend :: !(B.ByteString -> IO ())
  , mcClose :: !(IO ())
    -- ^ An orderly close.  Harmless when repeated, as the two below are.
  , mcReset :: !(IO ())
    -- ^ An abortive close: the client's next read or write fails.
  , mcHalfClose :: !(IO ())
    -- ^ End the sending side: the client sees the end of the stream.
  , mcSocketMaybe :: !(Maybe Socket.Socket)
    -- ^ The socket, over TCP.
  , mcBuffer :: !(IORef B.ByteString)
  , mcPeerClosed :: !(IORef Bool)
    -- ^ A receive returned end of stream: the client closed its side.
  }

-- | The connection's socket, for a test of something only TCP has (run
-- with 'withTcpMockServer').
mcSocket :: MockConn -> Socket.Socket
mcSocket mc = fromMaybe (error "mcSocket: this mock connection is on a pipe; the test needs withTcpMockServer") (mcSocketMaybe mc)

-- | The server's end of a TCP connection.
--
-- Off Windows it is network's own calls, as it always was.  On Windows
-- those block in a foreign call that no exception reaches under GHC's
-- default I/O manager (a handler waiting in a receive could never be
-- stopped), so the socket goes through hmssql's socket backend, which can
-- be interrupted, and which is network's own calls again where
-- 'windowsNetworkTcp' holds.
--
-- There network's receive reports a reset that arrives while it is
-- pending as an 'IOException' of type @InvalidArgument@ (the code
-- @ERROR_NETNAME_DELETED@ is lost on the way), and one that arrived before
-- it began as the end of the stream.  The mock takes the first as the
-- second: the client closing with bytes of the mock's unread is the
-- client closing, and which form it takes is timing.
tcpMockConn :: Socket.Socket -> IO MockConn
tcpMockConn sock
  | onWindows = do
      backend <- socketBackend sock
      let resetAsEnd
            | windowsNetworkTcp = handleJust
                (\e -> if ioe_type e == InvalidArgument then Just () else Nothing)
                (\() -> pure B.empty)
            | otherwise = id
      mc <- conn backend
        (backendClose backend)
        (lingerZero >> backendClose backend)
      pure mc { mcRecv = resetAsEnd (mcRecv mc) }
  | otherwise = do
      buffer <- newIORef B.empty
      peerClosed <- newIORef False
      pure MockConn
        { mcRecv = SocketB.recv sock 65536
        , mcSend = SocketB.sendAll sock
        , mcClose = Socket.close sock
        , mcReset = lingerZero >> Socket.close sock
        , mcHalfClose = Socket.shutdown sock Socket.ShutdownSend
        , mcSocketMaybe = Just sock
        , mcBuffer = buffer
        , mcPeerClosed = peerClosed
        }
  where
    -- SO_LINGER 0, so that the close sends a reset.
    lingerZero = Socket.setSockOpt sock Socket.Linger (Socket.StructLinger 1 0)
      `catch` \(_ :: IOException) -> pure ()
    conn backend close reset = do
      buffer <- newIORef B.empty
      peerClosed <- newIORef False
      pure MockConn
        { mcRecv = backendRecvSome backend
        , mcSend = backendSend backend
        , mcClose = close
        , mcReset = reset
        , mcHalfClose = Socket.shutdown sock Socket.ShutdownSend
        , mcSocketMaybe = Just sock
        , mcBuffer = buffer
        , mcPeerClosed = peerClosed
        }

-- | The server's end of a pipe connection, with the action that
-- disconnects its client ('pipeAccept').
--
-- A pipe has no half-close.  Ending the sending side closes the handle,
-- which is what a client of a real server sees when the server ends the
-- stream: it reads what was sent and then the end.  The handler's later
-- receives report the end of the stream too, as they would once the
-- client had closed in answer.
pipeMockConn :: Backend -> IO () -> IO MockConn
pipeMockConn backend disconnect = do
  buffer <- newIORef B.empty
  peerClosed <- newIORef False
  closed <- newIORef False
  let close = writeIORef closed True >> backendClose backend
  pure MockConn
    { mcRecv = readIORef closed >>= \case
        True -> pure B.empty
        False -> backendRecvSome backend
    , mcSend = backendSend backend
    , mcClose = close
    , mcReset = disconnect >> close
    , mcHalfClose = close
    , mcSocketMaybe = Nothing
    , mcBuffer = buffer
    , mcPeerClosed = peerClosed
    }

-- | Receive up to 64 KiB from a backend: empty at the end of the stream.
backendRecvSome :: Backend -> IO B.ByteString
backendRecvSome backend = do
  fp <- BI.mallocByteString 65536
  n <- withForeignPtr fp (\p -> backendRecv backend p 65536)
  pure (BI.BS fp (max 0 n))

-- | Close the connection when the handler is done: see 'withMockServer'.
closeMock :: MockConn -> IO ()
closeMock mc = do
  peerClosed <- readIORef (mcPeerClosed mc)
  if peerClosed then mcReset mc else mcClose mc

-- | Fill the buffer to at least @n@ bytes; False on EOF first.
fill :: MockConn -> Int -> IO Bool
fill mc n = do
  buf <- readIORef (mcBuffer mc)
  if B.length buf >= n
    then pure True
    else do
      more <- mcRecv mc
      if B.null more
        then writeIORef (mcPeerClosed mc) True >> pure False
        else writeIORef (mcBuffer mc) (buf <> more) >> fill mc n

-- | Exactly @n@ bytes, whatever they are (e.g. a TLS record), or Nothing if
-- the client closed the connection first.
recvBytes :: MockConn -> Int -> IO (Maybe B.ByteString)
recvBytes mc n = fill mc n >>= \case
  False -> pure Nothing
  True -> do
    (now, later) <- B.splitAt n <$> readIORef (mcBuffer mc)
    writeIORef (mcBuffer mc) later
    pure (Just now)

-- | The next packet, or Nothing if the client closed the connection between
-- packets.
recvPacket :: MockConn -> IO (Maybe (Header, B.ByteString))
recvPacket mc = do
  ok <- fill mc 1
  if not ok
    then pure Nothing
    else do
      full <- fill mc headerLength
      unless full $ throwIO $ MockUnexpected "client closed mid-header"
      buf <- readIORef (mcBuffer mc)
      let hdr = Get.runGet getHeader (LB.fromStrict buf)
          total = fromIntegral (headerPacketLength hdr)
      unless (total >= headerLength) $ throwIO $ MockUnexpected ("bad packet header " ++ show hdr)
      full' <- fill mc total
      unless full' $ throwIO $ MockUnexpected "client closed mid-packet"
      buf' <- readIORef (mcBuffer mc)
      let (pkt, rest) = B.splitAt total buf'
      writeIORef (mcBuffer mc) rest
      pure $ Just (hdr, B.drop headerLength pkt)

-- | The next whole message (packets up to END_OF_MESSAGE), or Nothing if the
-- client closed the connection first.
recvMessageMaybe :: MockConn -> IO (Maybe (PacketType, B.ByteString))
recvMessageMaybe mc = fmap (\(ptype, _, body) -> (ptype, body)) <$> recvMessageWithReset mc

-- | 'recvMessageMaybe', also telling whether the message's first packet
-- carries the RESETCONNECTION bit.
recvMessageWithReset :: MockConn -> IO (Maybe (PacketType, Bool, B.ByteString))
recvMessageWithReset mc = go Nothing []
  where
    go first acc = recvPacket mc >>= \case
      Nothing
        | null acc -> pure Nothing
        | otherwise -> throwIO $ MockUnexpected "client closed mid-message"
      Just (hdr, body) ->
        let PacketStatus st = headerStatus hdr
            resetting = fromMaybe (headerStatus hdr .&. statusResetConnection /= PacketStatus 0) first
            acc' = body : acc
         in if st .&. 0x01 /= 0
              then pure $ Just (headerType hdr, resetting, B.concat (reverse acc'))
              else go (Just resetting) acc'

-- | Like 'recvMessageMaybe', but throws 'MockClientClosed' on EOF.
recvMessage :: MockConn -> IO (PacketType, B.ByteString)
recvMessage mc = recvMessageMaybe mc >>= maybe (throwIO MockClientClosed) pure

-- | Send one message, split into 4096-byte packets.
sendMessage :: MockConn -> PacketType -> LB.ByteString -> IO ()
sendMessage mc ptype body =
  mapM_ (mcSend mc) (splitIntoPackets defaultTdsContext ptype (PacketStatus 0) body)

-- | Send a tabular-result message made of the given tokens.
sendTokens :: MockConn -> [Put] -> IO ()
sendTokens mc toks = sendMessage mc PTTabularResult (Put.runPut (sequence_ toks))

-- | Send arbitrary bytes (e.g. hand-made or malformed packets).
sendRaw :: MockConn -> B.ByteString -> IO ()
sendRaw = mcSend

-- | Close the sending side only (the client sees EOF), and keep receiving.
-- On a pipe, which can't be closed one way, the handle is closed, and the
-- handler's later receives report the end of the stream ('pipeMockConn').
shutdownSend :: MockConn -> IO ()
shutdownSend = mcHalfClose

-- | Close the connection abortively, so the client sees a failure instead
-- of an orderly end of stream: a TCP reset (SO_LINGER 0), or on a pipe a
-- disconnect.
resetConnection :: MockConn -> IO ()
resetConnection = mcReset

------------------------------------------------------------------------------
-- Handshake

-- | A PRELOGIN response with the given ENCRYPTION byte.
preloginReply :: Word8 -> Prelogin
preloginReply enc = Prelogin
  [ PLVersion 17 0 1000 0
  , PLEncryption enc
  , PLInstance ""
  , PLThreadId Nothing
  , PLMars 0
  ]

-- | Receive the client's PRELOGIN and answer with the given one (see
-- 'preloginReply').  Returns what the client sent.
respondPrelogin :: Prelogin -> MockConn -> IO Prelogin
respondPrelogin reply mc = do
  (ptype, body) <- recvMessage mc
  unless (ptype == PTPrelogin) $ throwIO $ MockUnexpected ("expected PRELOGIN, got " ++ show ptype)
  p <- case Get.runGetOrFail getPrelogin (LB.fromStrict body) of
    Right (_, _, p) -> pure p
    Left (_, _, err) -> throwIO $ MockUnexpected ("bad PRELOGIN: " ++ err)
  sendMessage mc PTTabularResult (Put.runPut (putPrelogin reply))
  pure p

-- | What the client did after PRELOGIN.
data ClientStep
  = ClientSentLogin7 Login7
  | ClientStartedTls
    -- ^ A PRELOGIN packet carrying a TLS handshake record.
  | ClientClosed
    -- ^ The client closed the connection without sending anything.
  deriving (Eq, Show)

-- | Wait for the client's next move after PRELOGIN.
awaitLogin7 :: MockConn -> IO ClientStep
awaitLogin7 mc = recvMessageMaybe mc >>= \case
  Nothing -> pure ClientClosed
  Just (PTLogin7, body) -> ClientSentLogin7 <$> parseLogin7 body
  Just (PTPrelogin, body) | B.take 1 body == "\x16" -> pure ClientStartedTls
  Just (ptype, _) -> throwIO $ MockUnexpected ("expected LOGIN7, got " ++ show ptype)

parseLogin7 :: B.ByteString -> IO Login7
parseLogin7 body = case Get.runGetOrFail getLogin7 (LB.fromStrict body) of
  Right (_, _, l7) -> pure l7
  Left (_, _, err) -> throwIO $ MockUnexpected ("bad LOGIN7: " ++ err)

-- | 'awaitLogin7', throwing unless the client sent LOGIN7.
expectLogin7 :: MockConn -> IO Login7
expectLogin7 mc = awaitLogin7 mc >>= \case
  ClientSentLogin7 l7 -> pure l7
  other -> throwIO $ MockUnexpected ("expected LOGIN7, client did " ++ show other)

-- | PRELOGIN (answering ENCRYPT_NOT_SUP), then LOGIN7, answered with the given
-- tokens.  Returns the client's LOGIN7.
serveLogin :: [Put] -> MockConn -> IO Login7
serveLogin = serveLoginAfter (pure ())

-- | 'serveLogin', running the action once LOGIN7 has arrived, just before
-- the response is sent: for a test that times something from the login
-- response.  A signal given after the send would be late on Windows,
-- where the mock's send returns through hmssql's backend some tens of
-- microseconds after the bytes have left, and the client may have
-- finished its 'connect' by then.
serveLoginAfter :: IO () -> [Put] -> MockConn -> IO Login7
serveLoginAfter beforeResponse loginResponse mc = do
  _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
  l7 <- expectLogin7 mc
  beforeResponse
  sendTokens mc loginResponse
  pure l7

-- | PRELOGIN answering ENCRYPT_OFF, then LOGIN7 over TLS, answered with the
-- given tokens in plaintext: what a server with encryption off does for a
-- client with encryption off, which encrypts the login packet only (MS-TDS
-- 2.2.6.5).  Returns the client's LOGIN7.
--
-- The TLS handshake records travel inside PRELOGIN packets, both ways;
-- after the handshake, TLS records go directly on the socket, carrying TDS
-- packets.  Once LOGIN7 has arrived the TLS session is abandoned, as the
-- client abandons it: neither side sends a close_notify, and everything
-- after it (on the same 'MockConn') is plaintext.  The server's certificate
-- is 'mockTlsCert', so the client must be told to trust any certificate.
serveLoginOnlyTls :: [Put] -> MockConn -> IO Login7
serveLoginOnlyTls loginResponse mc = fst <$> tlsLogin False loginResponse mc

-- | PRELOGIN answering ENCRYPT_ON, then the TLS handshake as for
-- 'serveLoginOnlyTls', then LOGIN7 answered with the given tokens inside
-- TLS: a client with 'EncryptOn', whose whole session is encrypted.
-- Returns the client's LOGIN7 and the TLS session, which carries the rest.
serveLoginTls :: [Put] -> MockConn -> IO (Login7, TLS.Context)
serveLoginTls = tlsLogin True

-- | 'serveLoginOnlyTls', or with @whole@ 'serveLoginTls'.
tlsLogin :: Bool -> [Put] -> MockConn -> IO (Login7, TLS.Context)
tlsLogin whole loginResponse mc = do
  _ <- respondPrelogin (preloginReply (encryptionWord (if whole then EncryptOn else EncryptOff))) mc
  hosted <- newIORef True
  unwrapped <- newIORef B.empty
  let -- Each send is a message of its own: the client takes the records
      -- out of the packets as they come, whatever message they are in.
      send bs = readIORef hosted >>= \case
        True -> sendMessage mc PTPrelogin (LB.fromStrict bs)
        False -> sendRaw mc bs
      -- tls wants exactly n bytes, and takes fewer for the end of the
      -- stream.
      recv n = readIORef hosted >>= \case
        True -> recvUnwrapped n
        False -> fromMaybe B.empty <$> recvBytes mc n
      recvUnwrapped n = do
        buf <- readIORef unwrapped
        if B.length buf >= n
          then do
            let (now, later) = B.splitAt n buf
            writeIORef unwrapped later
            pure now
          else recvPacket mc >>= \case
            Nothing -> pure B.empty
            Just (hdr, body) -> do
              unless (headerType hdr == PTPrelogin) $ throwIO $ MockUnexpected $
                "expected a PRELOGIN packet carrying TLS, got " ++ show (headerType hdr)
              writeIORef unwrapped (buf <> body)
              recvUnwrapped n
      backend = TLS.Backend
        { TLS.backendFlush = pure ()
        , TLS.backendClose = pure ()
        , TLS.backendSend = send
        , TLS.backendRecv = recv
        }
  creds <- either (throwIO . MockUnexpected) pure (TLS.credentialLoadX509FromMemory mockTlsCert mockTlsKey)
  ctx <- TLS.contextNew backend TLS.defaultParamsServer
    { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] } }
  -- The client offers TLS 1.2 only, whose handshake the server finishes by
  -- sending its Finished: the client has nothing more to send until LOGIN7.
  TLS.handshake ctx
  leftover <- readIORef unwrapped
  unless (B.null leftover) $ throwIO $ MockUnexpected "TLS data after the handshake in a PRELOGIN packet"
  writeIORef hosted False
  (ptype, body) <- recvTlsMessage ctx
  unless (ptype == PTLogin7) $ throwIO $ MockUnexpected ("expected LOGIN7 over TLS, got " ++ show ptype)
  l7 <- parseLogin7 body
  if whole
    then mapM_ (TLS.sendData ctx . LB.fromStrict)
      (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) (Put.runPut (sequence_ loginResponse)))
    else sendTokens mc loginResponse
  pure (l7, ctx)

-- | The next whole message from a TLS session carrying TDS packets, which
-- must end with it.
recvTlsMessage :: TLS.Context -> IO (PacketType, B.ByteString)
recvTlsMessage ctx = go B.empty []
  where
    need buf n
      | B.length buf >= n = pure buf
      | otherwise = TLS.recvData ctx >>= \more ->
          if B.null more then throwIO MockClientClosed else need (buf <> more) n
    go buf acc = do
      buf' <- need buf headerLength
      let hdr = Get.runGet getHeader (LB.fromStrict buf')
          total = fromIntegral (headerPacketLength hdr)
      unless (total >= headerLength) $ throwIO $ MockUnexpected ("bad packet header " ++ show hdr)
      (pkt, rest) <- B.splitAt total <$> need buf' total
      let acc' = B.drop headerLength pkt : acc
          PacketStatus st = headerStatus hdr
      if st .&. 0x01 == 0
        then go rest acc'
        else do
          unless (B.null rest) $ throwIO $ MockUnexpected "data after the message over TLS"
          pure (headerType hdr, B.concat (reverse acc'))

-- | A throwaway self-signed P-256 key and certificate for mock TLS servers
-- (CN hmssql-mock); clients are told to trust any server certificate.
mockTlsKey, mockTlsCert :: B.ByteString
mockTlsKey =
  "-----BEGIN PRIVATE KEY-----\n\
  \MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgMH0iSpK6vMjuMgea\n\
  \3qOoD1xp2KE63d5W+4jRSV/F4C2hRANCAATaXA0DGo2YwTEHbnZBl1QWUdBt/CeI\n\
  \/cFuw3pddtZE/a3pmvitNK+vkmbd6KSvA5d3WxTtlxfbxyqgL7mOTc+C\n\
  \-----END PRIVATE KEY-----\n"
mockTlsCert =
  "-----BEGIN CERTIFICATE-----\n\
  \MIIBgjCCASmgAwIBAgIUGKiira19LrbBtUSxJmAxhiAMcZswCgYIKoZIzj0EAwIw\n\
  \FjEUMBIGA1UEAwwLaG1zc3FsLW1vY2swIBcNMjYwOTI0MTM1MjE2WhgPMjEyNjA4\n\
  \MzExMzUyMTZaMBYxFDASBgNVBAMMC2htc3NxbC1tb2NrMFkwEwYHKoZIzj0CAQYI\n\
  \KoZIzj0DAQcDQgAE2lwNAxqNmMExB252QZdUFlHQbfwniP3BbsN6XXbWRP2t6Zr4\n\
  \rTSvr5Jm3eikrwOXd1sU7ZcX28cqoC+5jk3PgqNTMFEwHQYDVR0OBBYEFAAy0ZQF\n\
  \E4izXlsM09utjmV8pEtZMB8GA1UdIwQYMBaAFAAy0ZQFE4izXlsM09utjmV8pEtZ\n\
  \MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgJ4gfM95HlIlsn8RL\n\
  \Rq+Uvqmr5I+vwuYZbfQE+3O1BYACICMjNVLIapv+fHQpkybEncr/C4XyGU8T/jLq\n\
  \z/FKlYPF\n\
  \-----END CERTIFICATE-----\n"

-- | Answer each further request with the tokens the function returns, until
-- the client closes the connection.  Attention requests are acknowledged
-- with a DONE carrying the ATTN bit.
serveRequests :: (PacketType -> B.ByteString -> IO [Put]) -> MockConn -> IO ()
serveRequests respond mc = recvMessageMaybe mc >>= \case
  Nothing -> pure ()
  Just (PTAttention, _) -> sendTokens mc [doneToken 0x0020 0] >> serveRequests respond mc
  Just (ptype, body) -> respond ptype body >>= sendTokens mc >> serveRequests respond mc

-- | 'serveLogin' with the given login response, then answer every request
-- with a bare DONE.
cannedLoginServer :: [Put] -> MockConn -> IO Login7
cannedLoginServer loginResponse mc = do
  l7 <- serveLogin loginResponse mc
  serveRequests (\_ _ -> pure [doneToken 0 0]) mc
  pure l7

------------------------------------------------------------------------------
-- Tokens

-- | LOGINACK and a final DONE: the least a server must send for a login to
-- succeed.
defaultLoginResponse :: [Put]
defaultLoginResponse = [loginAckToken Tds74 "Microsoft SQL Server", doneToken 0 0]

-- | LOGINACK (0xAD) for the given TDS version, with ProgName as given (append
-- NULs to imitate SQL Server's padding).
loginAckToken :: TdsVersion -> Text -> Put
loginAckToken v progName = lengthPrefixed 0xAD $ do
  Put.putWord8 1
  Put.putWord32be (tdsVersionWord v)
  putBVarChar progName
  mapM_ Put.putWord8 [17, 0, 3, 232]

-- | DONE (0xFD) with the given status and row count.
doneToken :: Word16 -> Word64 -> Put
doneToken status rows = do
  Put.putWord8 0xFD
  Put.putWord16le status
  Put.putWord16le 0
  Put.putWord64le rows

-- | ENVCHANGE (0xE3) of the given type; the bytes are NewValue and OldValue
-- as they appear on the wire.
envChangeToken :: Word8 -> B.ByteString -> Put
envChangeToken ty values = lengthPrefixed 0xE3 $ Put.putWord8 ty >> Put.putByteString values

-- | Routing ENVCHANGE (type 20) to the given server and port.
routingEnvChange :: Text -> Word16 -> Put
routingEnvChange server port = envChangeToken 20 $ LB.toStrict $ Put.runPut $ do
  let routingData = Put.runPut $ Put.putWord8 0 >> Put.putWord16le port >> putUsVarChar server
  Put.putWord16le (fromIntegral (LB.length routingData))
  Put.putLazyByteString routingData
  Put.putWord16le 0

-- | Database ENVCHANGE (type 1).
databaseEnvChange :: Text -> Text -> Put
databaseEnvChange old new = envChangeToken 1 $ LB.toStrict $ Put.runPut $ putBVarChar new >> putBVarChar old

-- | Begin Transaction ENVCHANGE (type 8), with the new transaction's
-- descriptor: the client is in a transaction ('Hmssql.Tds.Context.tdsTransaction').
beginTransactionEnvChange :: Word64 -> Put
beginTransactionEnvChange d = envChangeToken 8 $ LB.toStrict $ Put.runPut $
  Put.putWord8 8 >> Put.putWord64le d >> Put.putWord8 0

-- | Rollback Transaction ENVCHANGE (type 10) of the transaction with this
-- descriptor: the descriptor is the old value, the new one is empty.
rollbackTransactionEnvChange :: Word64 -> Put
rollbackTransactionEnvChange d = envChangeToken 10 $ LB.toStrict $ Put.runPut $
  Put.putWord8 0 >> Put.putWord8 8 >> Put.putWord64le d

-- | Reset Completion Acknowledgement ENVCHANGE (type 18), SQL Server's
-- answer to a request carrying the RESETCONNECTION bit; it ends any open
-- transaction too.
resetConnectionEnvChange :: Put
resetConnectionEnvChange = envChangeToken 18 (B.pack [0, 0])

-- | ERROR (0xAA) or INFO (0xAB) token.
messageToken :: Word8 -> ServerMessage -> Put
messageToken tokenType ServerMessage{..} = lengthPrefixed tokenType $ do
  Put.putInt32le msgNumber
  Put.putWord8 msgState
  Put.putWord8 msgClass
  putUsVarChar msgText
  putBVarChar msgServer
  putBVarChar msgProcedure
  Put.putInt32le msgLine

errorToken, infoToken :: ServerMessage -> Put
errorToken = messageToken 0xAA
infoToken = messageToken 0xAB

-- | Token type byte, USHORT length, body.
lengthPrefixed :: Word8 -> Put -> Put
lengthPrefixed tokenType body = do
  let bytes = Put.runPut body
  Put.putWord8 tokenType
  Put.putWord16le (fromIntegral (LB.length bytes))
  Put.putLazyByteString bytes
