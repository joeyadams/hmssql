-- | A connect whose server stops sending at any byte of what it sends
-- before the login is done: the PRELOGIN response, each TLS handshake
-- flight and the login response, under 'EncryptOn' (TLS inside PRELOGIN
-- packets, then TDS inside TLS) and 'EncryptStrict' (TLS first).  A proxy
-- between the client and an in-process TLS server forwards the server's
-- first @n@ bytes and then closes the client's connection or resets it.
-- Every such connect fails promptly, with 'ConnectionClosed',
-- 'ProtocolError' or a 'TLS.TLSException', and leaves no descriptor open.
-- The fast suite cuts at every byte of the first and last 96 and at every
-- 17th between; with @HMSSQL_TEST_SLOW=1@, at every byte.  (Serial, as
-- every @Resources@ module is: it counts descriptors.)
module Resources.CutHandshakeSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM, unless, void, when)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.IORef
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import qualified Network.TLS as TLS
import Test.Hspec

import Compat (onWindows, timeoutInSlices)
import Hmssql
import Hmssql.Errors
import MockServer (defaultLoginResponse, mockConnectInfo, serveLoginTls, withTcpMockServer)
import Resources.Helpers (backendHandles, backendHandlesReturnTo, fdCount, fdSlack, settle)
import Security.TlsSpec (serverAuthCert, trusting, withStrictMock)
import TestDb (slowTestsEnabled)

-- | How the proxy ends the client's connection at the cut.
data Cut = Close | Reset
  deriving (Eq, Show)

-- | Accept one client on 127.0.0.1 and connect it to the upstream port:
-- what the client sends goes up as it is; of what comes down, the first
-- @limit@ bytes reach the client (all of them with 'Nothing'), and then
-- the client's connection is closed or reset and the upstream one closed.
-- The action gets the proxy's port, and how to read how many bytes have
-- come down to the client so far; the result is how many came down in
-- all.
withCuttingProxy :: String -> Maybe Int -> Cut -> (Text -> IO Int -> IO a) -> IO (a, Int)
withCuttingProxy upstream limit cut client = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  up : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just upstream)
  forwarded <- newIORef 0
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 1
    port <- Socket.socketPort lsock
    finished <- newEmptyMVar
    let serve = bracket (fst <$> Socket.accept lsock) Socket.close $ \down ->
          bracket (Socket.openSocket up) Socket.close $ \usock -> do
            Socket.connect usock (Socket.addrAddress up)
            Socket.setSocketOption down Socket.NoDelay 1
            Socket.setSocketOption usock Socket.NoDelay 1
            let upward = forever' $ SocketB.recv down 4096 >>= \bs ->
                  if B.null bs then Socket.shutdown usock Socket.ShutdownSend >> throwIO Done else SocketB.sendAll usock bs
                downward sent = do
                  bs <- SocketB.recv usock 4096
                  let room = maybe (B.length bs) (subtract sent) limit
                      now = B.take room bs
                  unless (B.null now) $ SocketB.sendAll down now
                  let sent' = sent + B.length now
                  writeIORef forwarded sent'
                  if B.null bs || maybe False (sent' >=) limit
                    then pure ()
                    else downward sent'
            t <- forkIO (void (try @SomeException upward))
            _ <- try @SomeException (downward 0)
            -- The cut.
            when (cut == Reset) $ Socket.setSockOpt down Socket.Linger (Socket.StructLinger 1 0)
            when (cut == Close) $ void (try @SomeException (Socket.shutdown down Socket.ShutdownBoth))
            -- Stock network's Windows recv is a blocking foreign call:
            -- killThread waits until it returns, and shutdown alone does
            -- not wake it. Close the sockets first, with the chosen linger
            -- setting, so either a receive or a send in upward can end.
            when onWindows $ Socket.close down >> Socket.close usock
            killThread t
    bracket (forkIO (try @SomeException serve >>= putMVar finished)) killThread $ \_ -> do
      a <- client (T.pack (show port)) (readIORef forwarded)
      _ <- timeoutInSlices 10_000_000 (takeMVar finished)
      (,) a <$> readIORef forwarded
  where
    forever' act = act >> forever' act

data Done = Done
  deriving (Show)

instance Exception Done

-- | A failed connect as the specification allows.
cleanFailure :: Either SomeException a -> Maybe String
cleanFailure = \case
  Right _ -> Just "connected"
  Left e
    | Just (_ :: ConnectionClosed) <- fromException e -> Nothing
    | Just (ProtocolError _) <- fromException e -> Nothing
    | Just (_ :: TLS.TLSException) <- fromException e -> Nothing
    | otherwise -> Just (show e)

-- | Connect through the proxy, cut after @limit@ bytes: the outcome, with
-- the bytes forwarded by the time the connect returned, and the bytes
-- forwarded in all.  (The server sends more after the login, such as its
-- TLS close_notify when the client closes, which the client doesn't wait
-- for.)
type Run = Maybe Int -> Cut -> IO (Either SomeException Int, Int)

-- | Connect with these settings, and return how many bytes the client had
-- been sent once connected.
connectThrough :: ConnectInfo -> IO Int -> IO (Either SomeException Int)
connectThrough ci forwarded =
  try (timeoutInSlices 20_000_000 (withConnection ci (\_ -> forwarded))) >>= \case
    Left e -> pure (Left e)
    Right Nothing -> throwIO (userError "connect hung")
    Right (Just n) -> pure (Right n)

encryptOn :: Run
-- The proxy reaches the mock by its port, so the mock keeps TCP whatever
-- HMSSQL_TEST_MOCK_TRANSPORT says.
encryptOn limit cut = withTcpMockServer server $ \srv -> do
  let ci = mockConnectInfo srv
  withCuttingProxy (T.unpack (connectPort ci)) limit cut $ \port ->
    connectThrough ci { connectPort = port, connectEncryption = EncryptOn
                      , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True } }
  where
    server mc = do
      (_, ctx) <- serveLoginTls defaultLoginResponse mc
      let drain = TLS.recvData ctx >>= \bs -> unless (B.null bs) drain
      drain `catch` \(_ :: SomeException) -> pure ()

strict :: Run
strict limit cut = fst <$> withStrictMock "127.0.0.1" serverAuthCert id
  (\upstream -> withCuttingProxy upstream limit cut $ \port -> connectThrough defaultConnectInfo
    { connectHost = "127.0.0.1", connectPort = port, connectUser = "u", connectPassword = "p"
    , connectEncryption = EncryptStrict, connectTls = trusting serverAuthCert, connectSessionSetup = [] })

-- | Every cut of the sweep: the failures.
sweep :: Run -> IO [String]
sweep run = do
  (whole, _) <- run Nothing Close
  total <- either (\e -> throwIO (userError ("the uncut connect failed: " ++ show e))) pure whole
  everyByte <- slowTestsEnabled
  let cuts = [n | n <- [0 .. total - 1], everyByte || n < 96 || n >= total - 96 || n `mod` 17 == 0]
  settle
  before <- fdCount
  beforeBackends <- backendHandles
  failures <- fmap concat $ forM cuts $ \n -> forM [Close, Reset] $ \cut -> do
    (r, sent) <- run (Just n) cut
    pure $ case cleanFailure r of
      -- The server's ECDSA signature is DER, 70 to 72 bytes long (shorter
      -- once in 256), so a run's bytes can be up to 3 fewer than the
      -- uncut run's: a cut that close to the end may have cut nothing.
      Just "connected" | n >= total - 3 -> []
      Nothing | sent == n -> []
      Nothing -> ["cut at " ++ show n ++ " (" ++ show cut ++ "): forwarded " ++ show sent]
      Just what -> ["cut at " ++ show n ++ " of " ++ show total ++ " (" ++ show cut ++ "): " ++ what]
  settle
  backendHandlesReturnTo beforeBackends
  after <- fdCount
  let leaked = case (before, after) of
        (Just f0, Just f1) | f1 > f0 + 2 + fdSlack -> [show (f1 - f0) ++ " descriptors/handles more after the sweep"]
        _ -> []
  pure (concat failures ++ leaked)

spec :: Spec
spec = describe "a connect whose server stops at any byte before the login is done" $ do
  it "EncryptOn (the PRELOGIN response, the TLS flights in PRELOGIN packets, the login response in TLS): fails cleanly, leaving no descriptor" $
    sweep encryptOn `shouldReturn` []
  it "EncryptStrict (the TLS flights, then the login response): fails cleanly, leaving no descriptor" $
    sweep strict `shouldReturn` []
