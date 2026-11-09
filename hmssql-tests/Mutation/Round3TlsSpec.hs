-- | Tests found by the third round of mutation testing of
-- "Hmssql.Connection.Tls": the system certificate store is loaded once and
-- the connection's own certificates are still added to it, and what strict
-- encryption reports for a server that doesn't answer in TLS.
module Mutation.Round3TlsSpec (spec) where

import Control.Exception (SomeException, evaluate, fromException)
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.List (isPrefixOf)
import Data.X509.CertificateStore (listCertificates)
import Data.X509.Memory (readSignedObjectFromMemory)
import Foreign.C.Error (Errno (..), eCONNRESET, eINVAL)
import Foreign.C.Types (CInt)
import GHC.IO.Exception (IOException (..))
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import System.Mem (getAllocationCounter)
import Test.Hspec

import Compat (windowsNetworkTcp)
import Hmssql
import Hmssql.Errors
import Hmssql.Connection.Tls (buildCertificateStore)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Security.TlsSpec (connectStrict, serverAuthCert, withRawServer)

-- | Bytes allocated by this thread while running the action.
allocatedBy :: IO a -> IO (Int, a)
allocatedBy act = do
  before <- getAllocationCounter
  a <- act
  after <- getAllocationCounter
  pure (fromIntegral (before - after), a)

-- | Connect with strict encryption to a raw server that answers the
-- ClientHello with the given bytes, and return the ProtocolError's message.
strictAnsweredWith :: B.ByteString -> IO String
strictAnsweredWith answer = do
  r <- withRawServer (\sock -> do
      _ <- SocketB.recv sock 4096
      SocketB.sendAll sock answer
      let drain = SocketB.recv sock 4096 >>= \bs -> unless (B.null bs) drain
      drain) $
    connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
  case r of
    Left e | Just (ProtocolError msg) <- fromException e -> pure msg
    _ -> expectationFailure ("expected a ProtocolError, got " ++ either (show :: SomeException -> String) show r) >> pure ""

-- | Close with a TCP reset.
abort :: Socket.Socket -> IO ()
abort sock = do
  Socket.setSockOpt sock Socket.Linger (Socket.StructLinger 1 0)
  Socket.close sock

-- | The errno of the IOException inside @ConnectionClosedBy (TransportFailed _)@.
transportErrno :: Either SomeException () -> Either String CInt
transportErrno = \case
  Left e
    | Just (ConnectionClosedBy (TransportFailed cause)) <- fromException e
    , Just (ioe :: IOException) <- fromException cause ->
        maybe (Left ("no errno: " ++ show ioe)) Right (ioe_errno ioe)
  other -> Left ("expected ConnectionClosedBy (TransportFailed IOException), got " ++ either show show other)

spec :: Spec
spec = do
  describe "the system certificate store" $ do
    it "is loaded once per process: later stores reuse it" $ do
      -- Loaded now if no test has yet (the first load allocates tens of MB).
      _ <- buildCertificateStore defaultTlsSettings >>= evaluate . length . listCertificates
      (bytes, n) <- allocatedBy (buildCertificateStore defaultTlsSettings >>= evaluate . length . listCertificates)
      n `shouldSatisfy` (> 0)
      bytes `shouldSatisfy` (< 4_000_000)

    it "still gets the connection's own certificates added to it" $ do
      let extra = readSignedObjectFromMemory serverAuthCert
      system <- listCertificates <$> buildCertificateStore defaultTlsSettings
      both <- listCertificates <$> buildCertificateStore defaultTlsSettings { tlsExtraCertificates = extra }
      length both `shouldBe` length system + 1
      all (`elem` both) extra `shouldBe` True

  describe "strict encryption, the server resetting the connection during the handshake" $ do
    -- The first failure of the transport is the one reported: the reset
    -- seen by the read, not the failure of the alert tls then tries to send.
    it "after the ClientHello: TransportFailed with the reset (ECONNRESET)" $ do
      r <- withRawServer (\sock -> SocketB.recv sock 4096 >> abort sock) $
        connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
      if windowsNetworkTcp
        -- network's receive there reports a reset that arrives while it
        -- is pending with EINVAL, the Windows code lost, and one that
        -- arrived before it began as the end of the stream (design.md,
        -- "Windows: GHC's native I/O manager").
        then case r of
          Left e | Just (ConnectionClosedBy ClosedByServer) <- fromException e -> pure ()
          _ -> transportErrno r `shouldBe` Right (let Errno c = eINVAL in c)
        else transportErrno r `shouldBe` Right (let Errno c = eCONNRESET in c)

    -- The ClientHello's send is the first to fail: it must be reported as
    -- the transport failure it is, not as a failure of TLS.
    -- (On a busy machine the reset can come before the socket's connect
    -- returns, which then fails too (or the setsockopt right after it,
    -- with EINVAL), before anything is sent: also a TransportFailed, but
    -- of opening the socket, not of the ClientHello's send.  That attempt
    -- is repeated.)
    it "before the ClientHello: TransportFailed" $ do
      let attempt :: Int -> IO (Either String ())
          attempt n = do
            r <- withRawServer abort $
              connectStrict "127.0.0.1" defaultTlsSettings { tlsTrustServerCertificate = True }
            case r of
              Left e
                | Just (ConnectionClosedBy (TransportFailed cause)) <- fromException e
                , Just (ioe :: IOException) <- fromException cause
                , any (`isPrefixOf` ioe_location ioe) ["Network.Socket.connect", "Network.Socket.setSockOpt"]
                , n > 1 -> attempt (n - 1)
              -- On Windows with TCP through network's calls the send can
              -- go into the socket's buffer although the connection was
              -- reset, and the read after it sees the reset as the end of
              -- the stream, as in the test above.
              Left e
                | windowsNetworkTcp
                , Just (ConnectionClosedBy ClosedByServer) <- fromException e -> pure (Right ())
              _ -> pure (fmap (const ()) (transportErrno r))
      attempt 10 `shouldReturn` Right ()

  describe "strict encryption against a server that doesn't answer in TLS" $ do
    it "says when the answer is a TDS packet, and suggests EncryptOn" $ do
      msg <- strictAnsweredWith (B.concat (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) "\xFF"))
      msg `shouldContain` "TDS packet"
      msg `shouldContain` "EncryptOn"

    it "gives the first byte of any other answer" $ do
      msg <- strictAnsweredWith "HTTP/1.1 400 Bad Request\r\n\r\n"
      msg `shouldContain` "not TLS"
      msg `shouldContain` "0x48"
