-- | Tests found by mutation testing of "Hmssql.Connection.Tls" and
-- 'Hmssql.Connection.close': what a TDS 8.0 (strict encryption) client
-- sends on the TLS layer, observed by an in-process TLS server.  SQL Server
-- itself accepts a client that omits these, so only a mock can tell.
--
-- Also what the client requires of the server's ALPN answer.  SQL Server
-- always selects @tds/8.0@ when it is offered, so the peer that completes
-- the handshake without selecting it (an HTTPS listener or a TLS proxy on
-- the port, with a certificate for the host) can only be a mock.
--
-- And that 'Hmssql.Connection.close' keeps the connection reachable until
-- it is done, so that a garbage collection during it doesn't run the
-- connection's finalizer under the close_notify.
module Mutation.StrictTlsSpec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (join)
import qualified Data.Binary.Get as Get
import Data.Bits (testBit)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import qualified Data.Text as T
import Data.Maybe (isJust)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import qualified Network.TLS as TLS
import System.Mem (performMajorGC)
import System.Mem.Weak (deRefWeak)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection.Backend (Backend (..), tcpBackend)
import Hmssql.Connection.Internal (connAlive)
import Hmssql.Errors
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer (doneToken, loginAckToken, mockTlsCert, mockTlsKey)

-- | What the mock saw: the client's ALPN protocols, how many bytes of
-- application data it sent inside the session, and whether it sent
-- anything (a close_notify alert) after the login before closing the TCP
-- connection.
data Seen = Seen
  { seenAlpn :: Maybe [B.ByteString]
  , seenAppBytes :: Int
  , seenBytesAtClose :: Int
  }
  deriving (Eq, Show)

-- | What the mock does with the client's ALPN offer.
data Alpn
  = SelectTds80
    -- ^ Select @tds/8.0@ when offered, as SQL Server does, and log the
    -- client in.
  | IgnoreAlpn
    -- ^ Answer without the ALPN extension, as a server without ALPN
    -- does (RFC 7301 allows it), then read whatever the client sends
    -- until it closes.

-- | Read one TDS message (packets up to END_OF_MESSAGE) from the TLS
-- stream, returning its length in bytes.
recvTdsMessage :: TLS.Context -> IORef B.ByteString -> IO Int
recvTdsMessage ctx buf = do
  let need n = do
        b <- readIORef buf
        if B.length b >= n
          then pure b
          else do
            more <- TLS.recvData ctx
            if B.null more then throwIO (userError "client closed mid-message") else writeIORef buf (b <> more) >> need n
      packet n = do
        hdr <- need 8
        let len = fromIntegral (Get.runGet Get.getWord16be (LB.fromStrict (B.take 2 (B.drop 2 hdr))))
        b <- need len
        writeIORef buf (B.drop len b)
        if testBit (B.index hdr 1) 0 then pure (n + len) else packet (n + len)
  packet 0

-- | Accept one strict-encryption client, answer its ALPN offer as told,
-- log it in if the offer was accepted, and wait for it to close.
strictMock :: Alpn -> Socket.Socket -> MVar (Either SomeException Seen) -> IO ()
strictMock mode lsock result = do
  (sock, _) <- Socket.accept lsock
  r <- try $ flip finally (Socket.close sock) $ do
    alpn <- newIORef Nothing
    creds <- either (throwIO . userError) pure (TLS.credentialLoadX509FromMemory mockTlsCert mockTlsKey)
    let params = TLS.defaultParamsServer
          { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] }
          , TLS.serverHooks = TLS.defaultServerHooks
              { TLS.onALPNClientSuggest = case mode of
                  SelectTds80 -> Just $ \protos -> do
                    writeIORef alpn (Just protos)
                    pure (if "tds/8.0" `elem` protos then "tds/8.0" else B.concat (take 1 protos))
                  IgnoreAlpn -> Nothing
              }
          }
    ctx <- TLS.contextNew sock params
    TLS.handshake ctx
    appBytes <- case mode of
      SelectTds80 -> do
        buf <- newIORef B.empty
        n <- recvTdsMessage ctx buf  -- LOGIN7
        let response = Put.runPut (loginAckToken Tds80 "mock" >> doneToken 0 0)
        mapM_ (TLS.sendData ctx . LB.fromStrict) (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) response)
        pure n
      IgnoreAlpn -> do
        -- Whatever the client sends inside the session until it closes
        -- (a close_notify, an end of stream or a reset all end this);
        -- a client that checks the selection sends nothing.
        let readAll n = try (TLS.recvData ctx) >>= \case
              Right bs | not (B.null bs) -> readAll (n + B.length bs)
              Right _ -> pure n
              Left (_ :: SomeException) -> pure n
        readAll 0
    -- Now read the raw socket: the client sends nothing more until it
    -- closes, and on close it should send a (TLS 1.3: encrypted) alert.
    let drain n = SocketB.recv sock 4096 >>= \bs -> if B.null bs then pure n else drain (n + B.length bs)
    n <- drain 0 `catch` \(_ :: IOException) -> pure 0
    Seen <$> readIORef alpn <*> pure appBytes <*> pure n
  putMVar result r

-- | Connect with strict encryption to a mock that selects @tds/8.0@, then
-- close.
runStrict :: IO Seen
runStrict = runStrictWith SelectTds80 >>= \(r, seen) -> either throwIO (const (pure seen)) r

-- | Connect with strict encryption to the mock, then close: what the
-- client got, and what the mock saw.
runStrictWith :: Alpn -> IO (Either SomeException (), Seen)
runStrictWith mode = runStrictOn mode id (\_ -> pure ())

-- | 'runStrictWith', with the 'ConnectInfo' changed as given, and the
-- action run on the connection before it is closed.
runStrictOn :: Alpn -> (ConnectInfo -> ConnectInfo) -> (Connection -> IO ()) -> IO (Either SomeException (), Seen)
runStrictOn mode adjust body = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 1
    port <- Socket.socketPort lsock
    result <- newEmptyMVar
    bracket (forkIO (strictMock mode lsock result)) killThread $ \_ -> do
      let ci = defaultConnectInfo
            { connectHost = "127.0.0.1"
            , connectPort = T.pack (show port)
            , connectUser = "u"
            , connectPassword = "p"
            , connectEncryption = EncryptStrict
            , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
            , connectSessionSetup = []
            }
      r <- timeout 20_000_000 (try (withConnection (adjust ci) body))
      client <- case r of
        Nothing -> throwIO (userError "client timed out")
        Just o -> pure o
      seen <- timeout 10_000_000 (takeMVar result) >>= maybe (throwIO (userError "mock timed out")) (either throwIO pure)
      pure (client, seen)

spec :: Spec
spec = describe "strict encryption, seen by a TLS mock server" $ do
  it "offers the ALPN protocol tds/8.0, as TDS 8.0 requires, and logs in once it is selected" $ do
    seen <- runStrict
    seenAlpn seen `shouldBe` Just ["tds/8.0"]
    seenAppBytes seen `shouldSatisfy` (> 0)

  it "sends a close_notify alert when closed" $ do
    seen <- runStrict
    seenBytesAtClose seen `shouldSatisfy` (> 0)

  -- 'close' given the last handle: once it had read the fields it needed,
  -- nothing kept the connection reachable, and a garbage collection
  -- during the close ran the finalizer of a connection dropped without
  -- 'close', which closed the socket under the goodbye.  The full suite
  -- failed the test above so once, under load.  Here the collection runs
  -- as 'close' stops the reader (the backend's 'backendStopReceiving'),
  -- and a weak pointer to what the finalizer is keyed on says whether
  -- the connection was found unreachable.
  it "sends the close_notify when a garbage collection runs during close, and stays reachable through it" $ do
    hook <- newIORef (pure ())
    reachable <- newEmptyMVar
    let hooked backend = backend
          { backendStopReceiving = do
              join (atomicModifyIORef' hook (\act -> (pure (), act)))
              backendStopReceiving backend
          }
        adjust ci = ci { connectProtocol = ProtocolCustom (hooked <$> tcpBackend (T.unpack (connectHost ci)) (T.unpack (connectPort ci))) }
    (client, seen) <- runStrictOn SelectTds80 adjust $ \conn -> do
      alive <- mkWeakIORef (connAlive conn) (pure ())
      writeIORef hook $ do
        performMajorGC
        deRefWeak alive >>= putMVar reachable . isJust
    either throwIO pure client
    tryTakeMVar reachable `shouldReturn` Just True
    seenBytesAtClose seen `shouldSatisfy` (> 0)

  it "a server that completes the handshake without selecting tds/8.0: ProtocolError, and no login is sent" $ do
    (client, seen) <- runStrictWith IgnoreAlpn
    case client of
      Left e | Just (ProtocolError msg) <- fromException e -> msg `shouldContain` "tds/8.0"
      other -> expectationFailure ("expected ProtocolError, got " ++ either show show other)
    -- Nothing inside the session: the LOGIN7, and the password in it,
    -- never reached a peer that didn't agree to TDS.
    seenAppBytes seen `shouldBe` 0
