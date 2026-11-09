{-# LANGUAGE CPP #-}
-- | TLS for both flavors of SQL Server encryption:
--
-- * __Strict__ (TDS 8.0): TLS on the raw byte stream from byte zero, with ALPN
--   @tds/8.0@.  The TDS packet stream runs inside the TLS session.
--
-- * __Hosted__ (TDS 7.x @ENCRYPT_ON@ / @ENCRYPT_OFF@): the TLS handshake records
--   are carried inside TDS PRELOGIN packets; once the handshake completes, TLS
--   records go directly on the byte stream and TDS packets go inside them.
module Hmssql.Connection.Tls
  ( TlsSettings (..)
  , defaultTlsSettings
  , buildCertificateStore
  , strictTlsHandshake
  , hostedTlsHandshake
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
#if defined(mingw32_HOST_OS)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO, uninterruptibleMask_)
#else
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
#endif
import Control.Monad (unless, when)
import Data.Char (isDigit)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509 (ExtKeyUsagePurpose (KeyUsagePurpose_ServerAuth), HashALG (HashSHA256), SignedCertificate)
import Data.X509.CertificateStore (CertificateStore, makeCertificateStore)
import Data.X509.File (readSignedObject)
import Data.X509.Validation
  (ValidationChecks (..), defaultChecks, defaultHooks, validate)
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)
import System.IO.Unsafe (unsafePerformIO)
import System.X509 (getSystemCertificateStore)
import Text.Printf (printf)

import Hmssql.Connection.Internal
import Hmssql.Errors
import Hmssql.Tds.Packet

-- | How the server's certificate is validated, in every mode that uses TLS.
-- 'defaultTlsSettings' validates against the system store; the fields add
-- trust, override the name checked, or turn validation off.
data TlsSettings = TlsSettings
  { tlsTrustServerCertificate :: !Bool
    -- ^ Skip certificate validation entirely.  Encryption still applies, but
    -- the server's identity is not verified.
    --
    -- A certificate whose extended key usage extension doesn't include
    -- server authentication is refused even so:
    -- @tls@ checks that itself, whatever the validation decided.  (SQL
    -- Server doesn't use such a certificate anyway: it requires a
    -- certificate for server authentication.)  With @tls@ 2.5 or later, so
    -- is a certificate whose RSA key is shorter than 2048 bits.
  , tlsUseSystemCertificateStore :: !Bool
    -- ^ Trust the system's certificate store.  It is loaded once per
    -- process, by the first connection that uses it (loading it takes
    -- about 20 ms and 38 MB of allocation on macOS, where it runs the
    -- @security@ tool), so certificates added to the system store later
    -- are seen only by a new process.
  , tlsCaCertificateFiles :: ![FilePath]
    -- ^ PEM files whose certificates are trusted in addition to the system
    -- store.  A self-signed server certificate can be listed here directly.
    -- Each is read and parsed by every connection that uses it (about
    -- 70 us for a one-certificate file), so a replaced file takes effect
    -- with the next connection; an application that connects often and
    -- wants to parse a file once can read it itself
    -- ('Data.X509.File.readSignedObject') and pass the certificates as
    -- 'tlsExtraCertificates'.
  , tlsExtraCertificates :: ![SignedCertificate]
    -- ^ Trusted certificates supplied in memory.
  , tlsHostNameInCertificate :: !(Maybe Text)
    -- ^ Validate the certificate against this name instead of the host that
    -- was connected to.  The server name sent in the TLS handshake (SNI) is
    -- still 'Hmssql.Connection.connectHost', or none if that is an IP
    -- address.
  }

-- | Validate the server's certificate against the system store, for the
-- host that was connected to, with no extra certificates trusted.
defaultTlsSettings :: TlsSettings
defaultTlsSettings = TlsSettings
  { tlsTrustServerCertificate = False
  , tlsUseSystemCertificateStore = True
  , tlsCaCertificateFiles = []
  , tlsExtraCertificates = []
  , tlsHostNameInCertificate = Nothing
  }

-- | The certificates to validate a server against: the system store (if
-- 'tlsUseSystemCertificateStore'), the files (read now: nothing is cached
-- by path, so a replaced file, even one with the modification time it
-- had, is what the next connection trusts) and the in-memory certificates.
buildCertificateStore :: TlsSettings -> IO CertificateStore
buildCertificateStore TlsSettings{..} = do
  sys <- if tlsUseSystemCertificateStore then systemCertificateStore else pure mempty
  fromFiles <- concat <$> mapM readCertificateFile tlsCaCertificateFiles
  pure $ sys <> makeCertificateStore (fromFiles ++ tlsExtraCertificates)

-- | Read the certificates of a PEM file.
--
-- On Windows, not interruptible: under GHC's native I/O manager a thread
-- interrupted in the middle of a file read may never come back (a GHC bug,
-- seen in GHC 9.12.4),
-- and a 'System.Timeout.timeout' around 'Hmssql.Connection.connect' that fired here hung for good.  On
-- other platforms the read is as interruptible as the file is: the
-- workaround is not shared, since it would make a path that blocks (a
-- FIFO, say) hang a 'System.Timeout.timeout' it has no reason to.
readCertificateFile :: FilePath -> IO [SignedCertificate]
#if defined(mingw32_HOST_OS)
readCertificateFile = uninterruptibleMask_ . readSignedObject
#else
readCertificateFile = readSignedObject
#endif

-- | The system store, loaded by the first call and shared by every
-- connection after it.  Concurrent first calls wait for one load; a load
-- that fails (or is interrupted) is not cached, so the next call tries
-- again.
systemCertificateStore :: IO CertificateStore
systemCertificateStore = modifyMVar systemCertificateStoreCache $ \case
  Just store -> pure (Just store, store)
  Nothing -> do
    store <- getSystemCertificateStore
    pure (Just store, store)

systemCertificateStoreCache :: MVar (Maybe CertificateStore)
systemCertificateStoreCache = unsafePerformIO (newMVar Nothing)
{-# NOINLINE systemCertificateStoreCache #-}

clientParams :: TlsSettings -> String -> [TLS.Version] -> Maybe [B.ByteString] -> IO TLS.ClientParams
clientParams settings host versions alpn = do
  store <- buildCertificateStore settings
  let validateName = maybe host T.unpack (tlsHostNameInCertificate settings)
      onServerCertificate
        | tlsTrustServerCertificate settings = \_ _ _ _ -> pure []
        | otherwise = \s cache (_, sni) chain -> validate HashSHA256 defaultHooks checks s cache (validateName, sni) chain
      -- The defaults, and a certificate whose extended key usage extension
      -- doesn't include server authentication (one meant for signing
      -- code, say) is refused, as other TLS clients do.  One without the
      -- extension is accepted.
      checks = defaultChecks { checkLeafKeyPurpose = [KeyUsagePurpose_ServerAuth] }
  pure (TLS.defaultParamsClient host B.empty)
    { TLS.clientSupported = TLS.defaultSupported
        { TLS.supportedVersions = versions
        , TLS.supportedCiphers = ciphersuite_default
          -- RFC 9155: no SHA-1 signatures in the TLS 1.2 handshake.
        , TLS.supportedHashSignatures =
            filter (not . isSha1) (TLS.supportedHashSignatures TLS.defaultSupported)
        }
    , TLS.clientShared = TLS.defaultShared { TLS.sharedCAStore = store }
    , TLS.clientHooks = TLS.defaultClientHooks
        { TLS.onServerCertificate = onServerCertificate
        , TLS.onSuggestALPN = pure alpn
        }
      -- RFC 6066 (3) doesn't allow an IP address as the server name.
    , TLS.clientUseServerNameIndication = not (isIpAddressLiteral host)
      -- tls 2.4 appends the session keys to the file named by
      -- SSLKEYLOGFILE when that variable is set; a stray variable in a
      -- production environment must not do that to a database session.
    , TLS.clientDebug = TLS.defaultDebugParams { TLS.debugKeyLogger = \_ -> pure () }
    }

-- | Whether a signature scheme signs a SHA-1 hash.  tls 2.5 replaced the
-- (hash, signature) pair with one IANA number and still offers
-- @rsa_pkcs1_sha1@ and @ecdsa_sha1@ by default.
#if MIN_VERSION_tls(2,5,0)
isSha1 :: TLS.SignatureScheme -> Bool
isSha1 s = s `elem` [TLS.RSA_PKCS1_SHA1, TLS.ECDSA_SHA1, TLS.DSA_SHA1]
#else
isSha1 :: TLS.HashAndSignatureAlgorithm -> Bool
isSha1 (h, _) = h == TLS.HashSHA1
#endif

-- | A backend that records the first synchronous exception its sends and
-- receives throw (typed by 'transportError') before passing it on, for
-- 'handshake'.  It refers to the IORef only, never to the connection (see
-- 'startReader').
recordingFailures :: IORef (Maybe SomeException) -> TLS.Backend -> TLS.Backend
recordingFailures failure backend = backend
  { TLS.backendSend = recording . TLS.backendSend backend
  , TLS.backendRecv = recording . TLS.backendRecv backend
  }
  where
    recording act = act `catch` \e -> do
      case fromException e of
        Just (_ :: SomeAsyncException) -> pure ()
        Nothing -> atomicModifyIORef' failure (\old -> (old <|> Just (transportError e), ()))
      throwIO e

-- | 'TLS.handshake' over a backend made by 'recordingFailures'.  tls turns
-- an exception from the backend into @HandshakeFailed (Error_Misc text)@,
-- keeping only its text, and reports the end of the stream as
-- @HandshakeFailed Error_EOF@.  Those are failures of the connection, not
-- of TLS, so they are thrown as for the rest of the connection: the
-- recorded exception (a 'ConnectionClosed' for an I/O error, or e.g. a
-- 'ProtocolError'), or @'ConnectionClosedBy' 'ClosedByServer'@ for the end
-- of the stream.  A failure of TLS itself (a certificate the client
-- rejects, an alert from the server) is still thrown as the
-- 'TLS.TLSException'.
--
-- Which of the three it was is taken from what tls reports, and the
-- record is consulted only for a failure tls says came from the backend.
-- A recorded exception is not always the cause: once tls has decided a
-- handshake has failed it tries to send an alert, and on a stream whose
-- other end has closed (a pipe always; a socket unless only one direction
-- was closed) that send fails and is recorded, after the end of the
-- stream or the server's alert that was the real reason.
handshake :: IORef (Maybe SomeException) -> TLS.Context -> IO ()
handshake failure ctx = TLS.handshake ctx `catch` \(e :: TLS.TLSException) -> case e of
  TLS.HandshakeFailed TLS.Error_EOF -> throwIO (ConnectionClosedBy ClosedByServer)
  TLS.HandshakeFailed (TLS.Error_Misc _) -> readIORef failure >>= maybe (throwIO e) throwIO
  _ -> throwIO e

-- | Whether a host is written as an IP address rather than a DNS name: IPv6
-- addresses contain colons, which a DNS name can't, and no DNS name
-- consists of digits and dots only, since top-level domains aren't
-- numeric.  (Also true of IPv4 shorthand such as @127.1@, which the
-- resolver accepts.)
isIpAddressLiteral :: String -> Bool
isIpAddressLiteral host = ':' `elem` host || (not (null host) && all (\c -> isDigit c || c == '.') host)

-- | The application protocol of TDS 8.0, offered and required through ALPN.
alpnTds80 :: B.ByteString
alpnTds80 = "tds/8.0"

-- | TDS 8.0: negotiate TLS directly on the socket and switch the connection's
-- transport to it.  Throws 'ProtocolError' if the server's first byte is
-- not TLS, or if the handshake ends without the server selecting
-- @tds/8.0@; nothing is sent inside the session before that check.
strictTlsHandshake :: Connection -> TlsSettings -> String -> IO ()
strictTlsHandshake conn settings host = do
  params <- clientParams settings host [TLS.TLS13, TLS.TLS12] (Just [alpnTds80])
  failure <- newIORef Nothing
  checkFirst <- newIORef True
  -- Like the connection's own reader thread, the TLS backend refers to
  -- the connection's backend only (see 'startReader').
  bufferedRecv <- newBufferedRecv (connBackend conn)
  let !backend = connBackend conn
      !gather = connSendGather conn
      -- tls never closes it: the connection closes its own backend.
      socketBackend = TLS.Backend
        { TLS.backendFlush = pure ()
        , TLS.backendClose = pure ()
        , TLS.backendRecv = bufferedRecv
        , TLS.backendSend = gatheredSend gather backend
        }
      -- A server that doesn't do strict encryption may answer the
      -- ClientHello with a TDS packet, whose header tls would take for a
      -- record header, then wait for more of the record, forever.  The
      -- ProtocolError is recorded by 'recordingFailures', so 'handshake'
      -- throws it.
      checked = socketBackend
        { TLS.backendRecv = \n -> do
            bs <- TLS.backendRecv socketBackend n
            first <- readIORef checkFirst
            when first $ do
              writeIORef checkFirst False
              case B.uncons bs of
                Just (b, _) | b /= 0x15 && b /= 0x16 -> throwIO $ ProtocolError (notTls b)
                _ -> pure ()
            pure bs
        }
      notTls b
        | b == packetTypeWord PTTabularResult =
            "the server answered the TLS handshake of strict encryption (TDS 8.0) with a TDS packet;"
              ++ " it may not support strict encryption (try EncryptOn)"
        | otherwise =
            "the server's answer to the TLS handshake of strict encryption (TDS 8.0) is not TLS"
              ++ " (its first byte is 0x" ++ printf "%02x" b ++ ")"
  ctx <- TLS.contextNew (recordingFailures failure checked) params
  handshake failure ctx
  -- The server must select the protocol offered.  tls refuses a server
  -- that selects a protocol the client didn't offer, but accepts one
  -- that answers with no ALPN extension at all (RFC 7301 allows it of a
  -- server without ALPN), and such a peer is not a TDS 8.0 endpoint:
  -- it may be an HTTPS listener or a TLS proxy on the port, holding a
  -- certificate for the host.  Nothing is sent inside the session, so
  -- the login and its password don't reach it.
  negotiated <- TLS.getNegotiatedProtocol ctx
  unless (negotiated == Just alpnTds80) $ throwIO $ ProtocolError $
    "the server completed the TLS handshake of strict encryption (TDS 8.0) without selecting"
      ++ " the protocol " ++ show alpnTds80 ++ "; it may not be a SQL Server, or it may not"
      ++ " support strict encryption (try EncryptOn)"
  writeIORef (connTransport conn) (TransportTls ctx)

-- | TDS 7.x: negotiate TLS with the handshake records wrapped in PRELOGIN
-- packets, then switch the connection's transport to the TLS session.
hostedTlsHandshake :: Connection -> TlsSettings -> String -> IO ()
hostedTlsHandshake conn settings host = do
  wrapped <- newIORef True
  sendBuf <- newIORef []
  recvBuf <- newIORef B.empty
  wrappedRecv <- newIORef Nothing
  bufferedRecv <- newBufferedRecv (connBackend conn)
  -- Bound strictly, so the closures below capture the connection's
  -- backend, not the connection (see the TLS backend).
  let !connBackend' = connBackend conn
      !gather = connSendGather conn

      flush = do
        pending <- atomicModifyIORef' sendBuf (\p -> ([], p))
        unless (null pending) $ do
          tdsCtx <- connectionContext conn
          sendBytes conn $ splitIntoPackets tdsCtx PTPrelogin (PacketStatus 0) $
            LB.fromChunks (reverse pending)

      -- Unwrap TDS packets until we have n bytes of TLS data.
      recvWrapped n = do
        flush
        let go = do
              buf <- readIORef recvBuf
              if B.length buf >= n
                then do
                  let (now, later) = B.splitAt n buf
                  writeIORef recvBuf later
                  pure now
                else do
                  (_, body) <- readPacket conn
                  writeIORef recvBuf (buf <> body)
                  go
        go

      recvRaw n = do
        bs <- bufferedRecv n
        when (B.length bs < n) $ throwIO ConnectionClosed
        pure bs

      -- The server needs each handshake flight in a single TDS message, and
      -- tls flushes mid-flight (after ChangeCipherSpec), so records are only
      -- flushed when we're about to wait for the server.
      -- The TLS context lives as long as the connection and is reachable
      -- from its reader thread, so after the handshake the backend must not
      -- refer to the connection (as 'recvWrapped' does): see 'startReader'.
      backend = TLS.Backend
        { TLS.backendFlush = pure ()
        , TLS.backendClose = pure ()
        , TLS.backendSend = \bs -> readIORef wrapped >>= \case
            True -> modifyIORef' sendBuf (bs :)
            False -> gatheredSend gather connBackend' bs
        , TLS.backendRecv = \n -> readIORef wrappedRecv >>= \case
            Just recv -> recv n
            Nothing -> recvRaw n
        }

  writeIORef wrappedRecv (Just recvWrapped)
  params <- clientParams settings host [TLS.TLS12] Nothing
  failure <- newIORef Nothing
  ctx <- TLS.contextNew (recordingFailures failure backend) params
  handshake failure ctx
  flush
  leftoverTls <- readIORef recvBuf
  leftoverTds <- readIORef (sessRecvBuffer (connPrimary conn))
  unless (B.null leftoverTls && null leftoverTds) $
    throwIO $ ProtocolError "unexpected data after TLS handshake"
  writeIORef wrapped False
  writeIORef wrappedRecv Nothing
  writeIORef (connTransport conn) (TransportTls ctx)
