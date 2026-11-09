-- | A TLS handshake that fails because of the connection (the server closes
-- or resets it, or sends something that isn't TDS) is reported like any
-- other failure of the connection: 'ConnectionClosed' with its
-- 'CloseReason', or the 'ProtocolError'.  tls itself reports all of these as
-- 'TLS.HandshakeFailed', the end of the stream as @Error_EOF@ and anything
-- else only by its text.  A failure of TLS proper (an alert from the server)
-- is still a 'TLS.TLSException'.
module Connection.HandshakeFailureSpec (spec) where

import Control.Exception
import Control.Monad (void)
import qualified Data.ByteString as B
import qualified Network.TLS as TLS
import System.Timeout (timeout)
import Test.Hspec

import Compat (windowsNetworkTcp)
import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client (encryptionWord)
import MockServer

-- | How a failed connect ended, for comparison.
data Outcome
  = Connected
  | ClosedByTheServer
  | TransportFailedIO
  | Protocol
  | Tls
  deriving (Eq, Show)

classify :: Either SomeException () -> Either String Outcome
classify = \case
  Right () -> Right Connected
  Left e
    | Just (ConnectionClosedBy ClosedByServer) <- fromException e -> Right ClosedByTheServer
    | Just (ConnectionClosedBy (TransportFailed cause)) <- fromException e
    , Just (_ :: IOException) <- fromException cause -> Right TransportFailedIO
    | Just (ProtocolError _) <- fromException e -> Right Protocol
    | Just (_ :: TLS.TLSException) <- fromException e -> Right Tls
    | otherwise -> Left (show e)

-- | Connect to a mock running the handler, expecting the given outcome; the
-- exception itself is shown if it is something else.
expectConnect :: Encryption -> (MockConn -> IO ()) -> Outcome -> Expectation
expectConnect enc handler expected = expectConnectOneOf enc handler [expected]

-- | 'expectConnect', with any of the outcomes.
expectConnectOneOf :: Encryption -> (MockConn -> IO ()) -> [Outcome] -> Expectation
expectConnectOneOf enc handler expected = withMockServer handler $ \srv -> do
  let ci = (mockConnectInfo srv)
        { connectEncryption = enc
        , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
        }
  r <- timeout 20_000_000 (try (withConnection ci (\_ -> pure ())))
  case r of
    Nothing -> expectationFailure "connect hung"
    Just o -> case classify o of
      Right outcome | outcome `elem` expected -> pure ()
      other -> expectationFailure ("expected one of " ++ show expected ++ ", got " ++ either id show other)
  void (nextResult srv)

-- | What a reset by the server gives: a transport failure.  On Windows with
-- TCP through network's calls, network's receive reads a reset that
-- arrived before it began as the end of the stream, so the connection may
-- end as closed by the server instead (design.md, "Windows: GHC's native
-- I/O manager").
resetOutcomes :: [Outcome]
resetOutcomes = TransportFailedIO : [ClosedByTheServer | windowsNetworkTcp]

-- | Read one TLS record (the client's ClientHello) off the raw stream.
recvTlsRecord :: MockConn -> IO ()
recvTlsRecord mc = recvBytes mc 5 >>= \case
  Just hdr | B.index hdr 0 == 0x16 -> do
    let len = fromIntegral (B.index hdr 3) * 256 + fromIntegral (B.index hdr 4)
    recvBytes mc len >>= maybe (throwIO (MockUnexpected "client closed mid-record")) (const (pure ()))
  other -> throwIO (MockUnexpected ("expected a TLS handshake record, got " ++ show other))

-- | PRELOGIN answered with ENCRYPT_ON, then the client's first handshake
-- flight (wrapped in PRELOGIN).
hostedClientHello :: MockConn -> IO ()
hostedClientHello mc = do
  _ <- respondPrelogin (preloginReply (encryptionWord EncryptOn)) mc
  awaitLogin7 mc >>= \case
    ClientStartedTls -> pure ()
    other -> throwIO (MockUnexpected ("expected a TLS handshake, client did " ++ show other))

-- | End the stream (the client sees EOF), then wait for the client to close.
closeAfter :: MockConn -> IO ()
closeAfter mc = shutdownSend mc >> void (recvBytes mc 1)

spec :: Spec
spec = describe "a TLS handshake failing because of the connection" $ do
  describe "strict encryption (TLS on the socket)" $ do
    it "the server closing the connection: ConnectionClosedBy ClosedByServer" $
      expectConnect EncryptStrict (\mc -> recvTlsRecord mc >> closeAfter mc) ClosedByTheServer

    it "the server resetting the connection: ConnectionClosedBy (TransportFailed IOException)" $
      expectConnectOneOf EncryptStrict (\mc -> recvTlsRecord mc >> resetConnection mc) resetOutcomes

    it "a TLS alert from the server: still a TLSException" $
      -- A fatal handshake_failure alert.
      expectConnect EncryptStrict (\mc -> recvTlsRecord mc >> sendRaw mc "\x15\x03\x03\x00\x02\x02\x28" >> closeAfter mc) Tls

  describe "TDS-hosted TLS (ENCRYPT_ON)" $ do
    it "the server closing the connection: ConnectionClosedBy ClosedByServer" $
      expectConnect EncryptOn (\mc -> hostedClientHello mc >> closeAfter mc) ClosedByTheServer

    it "the server resetting the connection: ConnectionClosedBy (TransportFailed IOException)" $
      expectConnectOneOf EncryptOn (\mc -> hostedClientHello mc >> resetConnection mc) resetOutcomes

    it "a malformed TDS packet instead of the handshake reply: ProtocolError" $
      -- A packet header whose length (4) is shorter than the header.
      expectConnect EncryptOn (\mc -> hostedClientHello mc >> sendRaw mc "\x12\x01\x00\x04\x00\x00\x00\x00" >> closeAfter mc) Protocol
