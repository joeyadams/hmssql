-- | Security review: what the client accepts from a TLS server.  An
-- in-process strict-encryption (TDS 8.0) TLS server shows what the client
-- sends (SNI) and which certificates, signatures and cipher suites it
-- accepts; the live server checks certificate validation in the TDS 7.x
-- modes, whose TLS parameters are the same apart from the versions.
module Security.TlsSpec
  ( spec, mockKey, serverAuthCert, trusting, recvTdsMessage
  , withStrictMock, connectStrict, shouldConnect, shouldRefuseTls, withRawServer
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forM_, unless)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import Data.Bits (testBit)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509.Memory (readSignedObjectFromMemory)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import System.Timeout (timeout)
import Test.Hspec

import Compat (SignatureScheme, ecdsaSha1, ecdsaSha256, tlsChecksServerAuthPurpose, tlsRefusesShortRsaKeys)
import Data.Maybe (fromMaybe)
import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer (doneToken, loginAckToken)
import TestConfig
import TestDb (skipWhen)

-- | A throwaway P-256 key, and two self-signed certificates for it, both
-- for the name @hmssql-mock@ (subject CN and DNS SAN): one whose extended
-- key usage is server authentication, one whose is client authentication
-- only.
mockKey, serverAuthCert, clientAuthCert :: B.ByteString
mockKey =
  "-----BEGIN PRIVATE KEY-----\n\
  \MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgPdpcgB0xENuixtFS\n\
  \ociSrMY7lwMzJz0jWjFSzMPGm96hRANCAATgDNZLIwoLDlfzYYCdYB4bnHzGQNLP\n\
  \0bW/mk5QNTv4PZL1PjagyJGvgbPWVAOu2gxJO4GCQkbZPCe7Gei6drFl\n\
  \-----END PRIVATE KEY-----\n"
serverAuthCert =
  "-----BEGIN CERTIFICATE-----\n\
  \MIIBsTCCAVegAwIBAgIULEAHGx4BkNQmp8d32KSqY9ibrgYwCgYIKoZIzj0EAwIw\n\
  \FjEUMBIGA1UEAwwLaG1zc3FsLW1vY2swIBcNMjYwOTI0MTgwNDE1WhgPMjEyNjA4\n\
  \MzExODA0MTVaMBYxFDASBgNVBAMMC2htc3NxbC1tb2NrMFkwEwYHKoZIzj0CAQYI\n\
  \KoZIzj0DAQcDQgAE4AzWSyMKCw5X82GAnWAeG5x8xkDSz9G1v5pOUDU7+D2S9T42\n\
  \oMiRr4Gz1lQDrtoMSTuBgkJG2TwnuxnounaxZaOBgDB+MB0GA1UdDgQWBBQKLdbm\n\
  \tD/wukovOfjgqa4MGiw7XDAfBgNVHSMEGDAWgBQKLdbmtD/wukovOfjgqa4MGiw7\n\
  \XDAWBgNVHREEDzANggtobXNzcWwtbW9jazATBgNVHSUEDDAKBggrBgEFBQcDATAP\n\
  \BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDqJFvmxQ8tSShpsXEh\n\
  \QMI76izAZOHFbK15WmohIFbYswIgFBbVHU7gyKxX6WbjK0qtHJDkCYLTsIozAHYF\n\
  \3DqGaA8=\n\
  \-----END CERTIFICATE-----\n"
clientAuthCert =
  "-----BEGIN CERTIFICATE-----\n\
  \MIIBsDCCAVegAwIBAgIUR6meor6juAE1cHWMBRHQ6euZnfYwCgYIKoZIzj0EAwIw\n\
  \FjEUMBIGA1UEAwwLaG1zc3FsLW1vY2swIBcNMjYwOTI0MTgwNDE1WhgPMjEyNjA4\n\
  \MzExODA0MTVaMBYxFDASBgNVBAMMC2htc3NxbC1tb2NrMFkwEwYHKoZIzj0CAQYI\n\
  \KoZIzj0DAQcDQgAE4AzWSyMKCw5X82GAnWAeG5x8xkDSz9G1v5pOUDU7+D2S9T42\n\
  \oMiRr4Gz1lQDrtoMSTuBgkJG2TwnuxnounaxZaOBgDB+MB0GA1UdDgQWBBQKLdbm\n\
  \tD/wukovOfjgqa4MGiw7XDAfBgNVHSMEGDAWgBQKLdbmtD/wukovOfjgqa4MGiw7\n\
  \XDAWBgNVHREEDzANggtobXNzcWwtbW9jazATBgNVHSUEDDAKBggrBgEFBQcDAjAP\n\
  \BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIF3zwq8aKHoqPZCBCNTF\n\
  \jsOa6v/NQZV1j81/XgDJYzOTAiBkIWB3vdLcVcs5H/TNLxoiJ4xqrOW2VSRBinP0\n\
  \GFaRqQ==\n\
  \-----END CERTIFICATE-----\n"

-- | A self-signed certificate for @hmssql-mock@ with a 1024-bit RSA key and
-- server authentication, and its key: what an older SQL Server presents
-- when it generates its own certificate.
rsa1024Key, rsa1024Cert :: B.ByteString
rsa1024Key =
  "-----BEGIN PRIVATE KEY-----\n\
  \MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAMDDSlGKo1a4vY/F\n\
  \O3KQQldVQqIvsROl6VEhXS4eXQoi4cPzY4I5QTIuxJwHdPbw0Q7gGwLPHDEOP5Gq\n\
  \UgmP7jb6X44gewwJSckTcHgNpQI4uXwrYMTyxyfe6XYsgsSTKB3caCWsgiau/siO\n\
  \Mm4cRPUnB8U39jFjQqj68yq190ptAgMBAAECgYBP/zwShxSuYtDYn6PCMbg2gj27\n\
  \DUvRuaMQdmYzQ4qdMEi9h36ehqBV8S7LChUyflJkeAD9s3IhsaYUD7koGsFi+lka\n\
  \kwN03zlS0jhyuTqnbom+mOp5rA4FJPjwJ4iA+RLgHtLH7BmWbX5nV9CKLrppxHZE\n\
  \ckrf3pUW4LJOGBV2iQJBAPTGKcEgZr1PiUfIZc3znTcV/Q93vADSet1bK+GUX9u5\n\
  \Z/WMY+OE22+HO0cF4Cf+VVoyIP6hwOQ3wiimETuYl5sCQQDJmnmpj8VK8Lku0HEc\n\
  \TtcEhtDD6ZzsPGMvKvWYUHKYLz2TZitnRh9gLUea3ubaMqCjlr0pZDtlc1QaJQ0u\n\
  \gnqXAkEAxWh4TliKY42c4va9HE+ocL/cGzhuuJ8IFjQsfL7EXJn4PPHfsaP5scX3\n\
  \ybz0Xmzhe1/IenQL9EL/5PaiGVVklwJANULMVZGYC95g7g8/cr0ZbSa4zKlRPdAO\n\
  \XA27aIwIWlBQsjpRySzraRtNSYsN7iNl8RIH04GZd4nqdCXJv7nU7QJALn1vGH+H\n\
  \p/+8iAvzIQR2YWUjBB+EbBJ3ll4GcR9nH4Hm28GnXVFidaBuOP4GJ7aVJqpc3oR3\n\
  \o3m3V74N28/vJQ==\n\
  \-----END PRIVATE KEY-----\n"
rsa1024Cert =
  "-----BEGIN CERTIFICATE-----\n\
  \MIICODCCAaGgAwIBAgIUNIHf/HyWjlfbsge1l7C1V2qzmwkwDQYJKoZIhvcNAQEL\n\
  \BQAwFjEUMBIGA1UEAwwLaG1zc3FsLW1vY2swIBcNMjYxMTA4MTMyMTUwWhgPMjEy\n\
  \NjEwMTUxMzIxNTBaMBYxFDASBgNVBAMMC2htc3NxbC1tb2NrMIGfMA0GCSqGSIb3\n\
  \DQEBAQUAA4GNADCBiQKBgQDAw0pRiqNWuL2PxTtykEJXVUKiL7ETpelRIV0uHl0K\n\
  \IuHD82OCOUEyLsScB3T28NEO4BsCzxwxDj+RqlIJj+42+l+OIHsMCUnJE3B4DaUC\n\
  \OLl8K2DE8scn3ul2LILEkygd3GglrIImrv7IjjJuHET1JwfFN/YxY0Ko+vMqtfdK\n\
  \bQIDAQABo4GAMH4wHQYDVR0OBBYEFL+x5rTLTdcWT7dHoOO5TEal2VseMB8GA1Ud\n\
  \IwQYMBaAFL+x5rTLTdcWT7dHoOO5TEal2VseMBYGA1UdEQQPMA2CC2htc3NxbC1t\n\
  \b2NrMBMGA1UdJQQMMAoGCCsGAQUFBwMBMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI\n\
  \hvcNAQELBQADgYEAvqpVDO3eodSLkQa4bYGQUyX/RqIRKrIpra1LvGUzQUBuxqX1\n\
  \QH9bntmjEm+v0OtHuwJY7slU84aETB/Ijw/qEzfPU6xAN/ajCqki/+KYKJAeBfDo\n\
  \5lZkOK9zn707wYyAPyZN4Yz+JQm7YkpEarXejwp1v0o8fWFa5qPLehYG0rE=\n\
  \-----END CERTIFICATE-----\n"

-- | Trust the given certificate only, and check it against @hmssql-mock@.
trusting :: B.ByteString -> TlsSettings
trusting pem = defaultTlsSettings
  { tlsUseSystemCertificateStore = False
  , tlsExtraCertificates = readSignedObjectFromMemory pem
  , tlsHostNameInCertificate = Just "hmssql-mock"
  }

-- | What the mock saw.
data Seen = Seen
  { seenSni :: Maybe (Maybe TLS.HostName)
    -- ^ The server name the client asked for, once the handshake got to it.
  }

-- | Read one TDS message (packets up to END_OF_MESSAGE) from the TLS stream.
recvTdsMessage :: TLS.Context -> IORef B.ByteString -> IO ()
recvTdsMessage ctx buf = packet
  where
    need n = do
      b <- readIORef buf
      if B.length b >= n
        then pure b
        else do
          more <- TLS.recvData ctx
          if B.null more then throwIO (userError "client closed mid-message") else writeIORef buf (b <> more) >> need n
    packet = do
      hdr <- need 8
      let len = fromIntegral (Get.runGet Get.getWord16be (LB.fromStrict (B.take 2 (B.drop 2 hdr))))
      b <- need len
      writeIORef buf (B.drop len b)
      unless (testBit (B.index hdr 1) 0) packet

-- | Run a strict-encryption server for one client on the given (numeric)
-- address, with the given certificate (for 'mockKey') and changes to the
-- server parameters: TLS handshake, then LOGIN7 answered with a LOGINACK,
-- then wait for the client to close.  The action gets the port.
withStrictMock
  :: String -> B.ByteString -> (TLS.ServerParams -> TLS.ServerParams) -> (String -> IO a) -> IO (a, Seen)
withStrictMock bindHost = withStrictMockKey bindHost mockKey

-- | 'withStrictMock' with the given private key.
withStrictMockKey
  :: String -> B.ByteString -> B.ByteString -> (TLS.ServerParams -> TLS.ServerParams) -> (String -> IO a) -> IO (a, Seen)
withStrictMockKey bindHost keyPem certPem tweak client = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just bindHost) (Just "0")
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.setSocketOption lsock Socket.ReuseAddr 1
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 4
    port <- Socket.socketPort lsock
    sniRef <- newIORef Nothing
    done <- newEmptyMVar :: IO (MVar (Either SomeException ()))
    let serve = do
          (sock, _) <- Socket.accept lsock
          -- Each record as it is written: Nagle's algorithm held the
          -- TLS 1.3 flight's later records for the client's ACK.
          Socket.setSocketOption sock Socket.NoDelay 1
          flip finally (Socket.close sock) $ do
            creds <- either (throwIO . userError) pure (TLS.credentialLoadX509FromMemory certPem keyPem)
            let base = TLS.defaultParamsServer
                  { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] }
                  , TLS.serverHooks = TLS.defaultServerHooks
                      { TLS.onServerNameIndication = \sni -> writeIORef sniRef (Just sni) >> pure mempty
                      , TLS.onALPNClientSuggest = Just $ \protos -> pure (if "tds/8.0" `elem` protos then "tds/8.0" else B.concat (take 1 protos))
                      }
                  }
            ctx <- TLS.contextNew sock (tweak base)
            TLS.handshake ctx
            buf <- newIORef B.empty
            recvTdsMessage ctx buf  -- LOGIN7
            let response = Put.runPut (loginAckToken Tds80 "mock" >> doneToken 0 0)
            mapM_ (TLS.sendData ctx . LB.fromStrict) (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) response)
            let drain = SocketB.recv sock 4096 >>= \bs -> unless (B.null bs) drain
            drain
    bracket (forkIO (try serve >>= putMVar done)) killThread $ \_ -> do
      a <- client (show port)
      -- The mock's own outcome doesn't matter: it fails whenever the
      -- client refuses the handshake.
      _ <- timeout 10_000_000 (takeMVar done) >>= maybe (throwIO (userError "mock timed out")) pure
      sni <- readIORef sniRef
      pure (a, Seen sni)

-- | Connect with strict encryption to the given host and port, log in, and
-- close.
connectStrict :: Text -> TlsSettings -> String -> IO (Either SomeException ())
connectStrict host tls port = do
  let ci = defaultConnectInfo
        { connectHost = host
        , connectPort = T.pack port
        , connectUser = "u"
        , connectPassword = "p"
        , connectEncryption = EncryptStrict
        , connectTls = tls
        , connectSessionSetup = []
        }
  timeout 20_000_000 (try (withConnection ci (\_ -> pure ()))) >>= \case
    Nothing -> throwIO (userError "client timed out")
    Just r -> pure r

-- | The client connected (and the mock logged it in).
shouldConnect :: Either SomeException () -> Expectation
shouldConnect = either (\e -> expectationFailure ("connect failed: " ++ show e)) pure

-- | The client refused the server with a 'TLS.TLSException'.
shouldRefuseTls :: Either SomeException () -> Expectation
shouldRefuseTls = \case
  Right () -> expectationFailure "connected"
  Left e -> case fromException e of
    Just (_ :: TLS.TLSException) -> pure ()
    Nothing -> expectationFailure ("expected a TLSException, got " ++ show e)

-- | Server parameters restricted to TLS 1.2 and the given signature
-- schemes and cipher suites.
tls12With :: [SignatureScheme] -> [TLS.Cipher] -> TLS.ServerParams -> TLS.ServerParams
tls12With sigs ciphers p = p
  { TLS.serverSupported = (TLS.serverSupported p)
      { TLS.supportedVersions = [TLS.TLS12]
      , TLS.supportedHashSignatures = sigs
      , TLS.supportedCiphers = ciphers
      }
  }

spec :: Spec
spec = do
  describe "server name indication (mock TLS server)" $ do
    it "sends the host name as SNI" $ do
      (r, seen) <- withStrictMock "127.0.0.1" serverAuthCert id (connectStrict "localhost" (trusting serverAuthCert))
      shouldConnect r
      seenSni seen `shouldBe` Just (Just "localhost")

    -- RFC 6066, section 3: "Literal IPv4 and IPv6 addresses are not
    -- permitted in HostName."
    it "sends no SNI when the host is an IPv4 address" $ do
      (r, seen) <- withStrictMock "127.0.0.1" serverAuthCert id (connectStrict "127.0.0.1" (trusting serverAuthCert))
      shouldConnect r
      seenSni seen `shouldBe` Just Nothing

    it "sends no SNI when the host is an IPv6 address" $ do
      (r, seen) <- withStrictMock "::1" serverAuthCert id (connectStrict "::1" (trusting serverAuthCert))
      shouldConnect r
      seenSni seen `shouldBe` Just Nothing

  describe "certificate validation (mock TLS server)" $ do
    it "is on by default: a self-signed certificate is refused" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert id (connectStrict "127.0.0.1" defaultTlsSettings)
      shouldRefuseTls r

    it "accepts a trusted certificate for tlsHostNameInCertificate" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert id (connectStrict "127.0.0.1" (trusting serverAuthCert))
      shouldConnect r

    it "checks the certificate against connectHost when tlsHostNameInCertificate is unset" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert id $
        connectStrict "127.0.0.1" (trusting serverAuthCert) { tlsHostNameInCertificate = Nothing }
      shouldRefuseTls r

    it "refuses a trusted certificate for another name" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert id $
        connectStrict "127.0.0.1" (trusting serverAuthCert) { tlsHostNameInCertificate = Just "other-host" }
      shouldRefuseTls r

    it "refuses a certificate whose extended key usage excludes server authentication" $ do
      (r, _) <- withStrictMock "127.0.0.1" clientAuthCert id (connectStrict "127.0.0.1" (trusting clientAuthCert))
      shouldRefuseTls r

    it "tlsTrustServerCertificate accepts an untrusted certificate for another name" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert id $
        connectStrict "127.0.0.1" defaultTlsSettings
          { tlsTrustServerCertificate = True, tlsUseSystemCertificateStore = False }
      shouldConnect r

    -- tls 2.4.4 checks the leaf certificate's extended key usage itself,
    -- after (and whatever) the validation hook decides; see the
    -- documentation of 'tlsTrustServerCertificate'.
    if tlsChecksServerAuthPurpose
      then it "tlsTrustServerCertificate still refuses a certificate whose extended key usage excludes server authentication (tls >= 2.4.4)" $ do
        (r, _) <- withStrictMock "127.0.0.1" clientAuthCert id $
          connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
        shouldRefuseTls r
      else it "tlsTrustServerCertificate accepts a certificate whose extended key usage excludes server authentication (tls < 2.4.4)" $ do
        (r, _) <- withStrictMock "127.0.0.1" clientAuthCert id $
          connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
        shouldConnect r

    -- tls 2.5 checks the size of the leaf certificate's RSA key itself,
    -- after (and whatever) the validation hook decides, as it does the
    -- extended key usage.
    if tlsRefusesShortRsaKeys
      then it "tlsTrustServerCertificate still refuses a certificate with a 1024-bit RSA key (tls >= 2.5)" $ do
        (r, _) <- withStrictMockKey "127.0.0.1" rsa1024Key rsa1024Cert id $
          connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
        shouldRefuseTls r
      else it "tlsTrustServerCertificate accepts a certificate with a 1024-bit RSA key (tls < 2.5)" $ do
        (r, _) <- withStrictMockKey "127.0.0.1" rsa1024Key rsa1024Cert id $
          connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
        shouldConnect r

  describe "TLS parameters (mock TLS server)" $ do
    it "accepts TLS 1.2 with a SHA-256 signature and AES-GCM" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert
        (tls12With [ecdsaSha256] [TLS.cipher_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256])
        (connectStrict "127.0.0.1" (trusting serverAuthCert))
      shouldConnect r

    -- RFC 9155: TLS 1.2 clients MUST NOT offer SHA-1 signature schemes.
    it "refuses a TLS 1.2 server that signs its key exchange with SHA-1" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert
        (tls12With [ecdsaSha1] [TLS.cipher_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256])
        (connectStrict "127.0.0.1" (trusting serverAuthCert))
      shouldRefuseTls r

    it "refuses a server that offers only a cipher suite with 64-bit tags (AES-CCM-8)" $ do
      (r, _) <- withStrictMock "127.0.0.1" serverAuthCert
        (tls12With [ecdsaSha256] [TLS.cipher_ECDHE_ECDSA_WITH_AES_128_CCM_8])
        (connectStrict "127.0.0.1" (trusting serverAuthCert))
      shouldRefuseTls r

  describe "strict encryption against a server that doesn't speak TLS" $ do
    it "fails promptly with a ProtocolError when the server answers in plain TDS" $ do
      r <- withRawServer (\sock -> do
          _ <- SocketB.recv sock 4096
          -- What a TDS 7.x server sends: a (PRELOGIN response) packet.
          SocketB.sendAll sock $ B.concat $ splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) "\xFF"
          let drain = SocketB.recv sock 4096 >>= \bs -> unless (B.null bs) drain
          drain) $
        connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
      case r of
        Left e | Just (ProtocolError msg) <- fromException e -> msg `shouldContain` "strict encryption"
        _ -> expectationFailure ("expected a ProtocolError, got " ++ show r)

    it "fails promptly when the server closes the connection" $ do
      r <- withRawServer (\sock -> () <$ SocketB.recv sock 4096) $
        connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
      case r of
        Right () -> expectationFailure "connected"
        Left e
          | Just (_ :: TLS.TLSException) <- fromException e -> pure ()
          | Just (_ :: ConnectionClosed) <- fromException e -> pure ()
          | otherwise -> expectationFailure ("expected a TLSException or ConnectionClosed, got " ++ show e)

  describe "certificate validation in every TLS mode (live server)" $
    forM_ [EncryptStrict, EncryptOn, EncryptOff] $ \enc -> describe (show enc) $ do
      it "refuses an untrusted certificate with a TLSException" $ do
        ci <- testConnectInfo enc
        r <- try (withConnection ci { connectTls = defaultTlsSettings { tlsUseSystemCertificateStore = False } } (\_ -> pure ()))
        shouldRefuseTls r

      it "refuses a certificate for another name with a TLSException" $ do
        ci <- testConnectInfo enc
        r <- try (withConnection ci { connectTls = (connectTls ci)
          { tlsTrustServerCertificate = False, tlsHostNameInCertificate = Just "other-host" } } (\_ -> pure ()))
        shouldRefuseTls r

      skipWhen localhostNotTheServer "the certificate is for localhost, and the test server is not on this machine" $
        skipWhen testTrustServerCertificate "requires a trusted server certificate (HMSSQL_TEST_TRUST_SERVER_CERTIFICATE=1)" $
        it "checks the certificate against connectHost by default" $ do
          ci <- testConnectInfo enc
          -- Connecting to the name the certificate is for (localhost for the
          -- local server; the host itself where HMSSQL_TEST_TLS_HOSTNAME is
          -- empty, as for Azure SQL), with no tlsHostNameInCertificate.
          host <- fromMaybe (connectHost ci) <$> testTlsHostName
          withConnection ci { connectHost = host, connectTls = (connectTls ci)
            { tlsTrustServerCertificate = False, tlsHostNameInCertificate = Nothing } } $ \conn ->
            query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

-- | Whether the certificate's name ('testTlsHostName') is a name for this
-- machine while the server is elsewhere (on a Docker network, as in
-- scripts/test-matrix.sh), so that connecting to that name reaches no server.
localhostNotTheServer :: IO Bool
localhostNotTheServer = do
  tlsHost <- testTlsHostName
  loopback <- testHostIsLoopback
  pure (tlsHost == Just "localhost" && not loopback)

-- | Accept one connection on 127.0.0.1 and run the handler on it, while the
-- action runs with the port.
withRawServer :: (Socket.Socket -> IO ()) -> (String -> IO a) -> IO a
withRawServer handler client = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 1
    port <- Socket.socketPort lsock
    let serve = do
          (sock, _) <- Socket.accept lsock
          handler sock `finally` Socket.close sock
    bracket (forkIO (serve `catch` \(_ :: SomeException) -> pure ())) killThread $ \_ -> client (show port)
