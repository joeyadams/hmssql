-- | Tests found by the third round of mutation testing of
-- "Hmssql.Connection" and "Hmssql.Connection.Internal": the PRELOGIN
-- response bound, what 'close' drops, that only SQL batches have a packet
-- limit, that received chunks copied into shared buffers arrive intact, and
-- parameter names the server accepts.
module Mutation.Round3ConnectionSpec (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (atomically, isEmptyTMVar)
import Control.Exception
import Control.Monad (forever, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import qualified Data.Text as T
import qualified Network.Socket as Socket
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Compat (connSocket)
import Hmssql.Connection.Backend (Backend (..))
import Hmssql.Connection.Internal (Connection (..), Session (..), Transport (..))
import Hmssql.Tds.Client (Prelogin (..), PreloginOption (..), encryptionWord, putPrelogin)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer
import Review.CumulativeSpec (untilSettled, withStalledTlsServer)
import Security.TlsSpec (serverAuthCert, trusting)
import TestDb

-- | The longest PRELOGIN response whose options are all reachable by the
-- 16-bit offsets and lengths: its last option starts at 65535 and is 65535
-- bytes long, so it ends at byte 131070.
longestPrelogin :: B.ByteString
longestPrelogin =
  let Prelogin opts = preloginReply (encryptionWord EncryptNotSup)
      layout a = Prelogin (opts ++ [PLUnknown 0x80 a, PLUnknown 0x81 (B.replicate 65535 0x42)])
      withoutPadding = fromIntegral (LB.length (Put.runPut (putPrelogin (layout B.empty)))) - 65535
   in LB.toStrict (Put.runPut (putPrelogin (layout (B.replicate (65535 - withoutPadding) 0x41))))

-- | A mock that answers PRELOGIN with the given body, then serves a login.
preloginServer :: B.ByteString -> MockConn -> IO ()
preloginServer body mc = do
  _ <- recvMessage mc
  mapM_ (sendRaw mc) (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) (LB.fromStrict body))
  _ <- expectLogin7 mc
  sendTokens mc defaultLoginResponse
  serveRequests (\_ _ -> pure [doneToken 0 0]) mc

isTransportSocket :: Transport -> Bool
isTransportSocket = \case
  TransportPlain _ -> True
  _ -> False

spec :: Spec
spec = do
  describe "a PRELOGIN response" $ do
    it "is accepted up to 131070 bytes (0xFFFF + 0xFFFF)" $ do
      B.length longestPrelogin `shouldBe` 131070
      withMockServer (preloginServer longestPrelogin) $ \srv ->
        withConnection (mockConnectInfo srv) $ \conn -> execute conn "SELECT 1" `shouldReturn` 0

    it "is refused with a ProtocolError at 131071 bytes" $
      withMockServer (preloginServer (longestPrelogin <> "\0")) $ \srv -> do
        r <- timeout 10_000_000 (try (withConnection (mockConnectInfo srv) (\_ -> pure ())))
        case r of
          Just (Left (ProtocolError msg)) -> msg `shouldContain` "131070"
          other -> expectationFailure ("expected a ProtocolError, got " ++ show other)

  describe "close" $ do
    it "drops unread received bytes: the partial packet and the chunk the reader was holding" $
      withMockServer (\mc -> do
          _ <- serveLogin defaultLoginResponse mc
          _ <- recvMessage mc
          -- The response, then the start of another packet in the same
          -- write; a moment later, a chunk that no one reads.
          sendRaw mc (B.concat (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) (Put.runPut (doneToken 0 0))) <> "\4\1\0")
          threadDelay 200_000
          sendRaw mc "\0\0\0\0\0"
          void (recvMessageMaybe mc)) $ \srv -> do
        conn <- connect (mockConnectInfo srv)
        void (execute conn "SELECT 1") `onException` close conn
        threadDelay 700_000
        before <- (,) <$> (sum . map B.length <$> readIORef (sessRecvBuffer (connPrimary conn))) <*> atomically (isEmptyTMVar (connIncoming conn))
        close conn
        after <- (,) <$> (sum . map B.length <$> readIORef (sessRecvBuffer (connPrimary conn))) <*> atomically (isEmptyTMVar (connIncoming conn))
        (before, after) `shouldBe` ((3, False), (0, True))

    it "closes the socket even when interrupted while saying goodbye, and can then be completed" $
      withStalledTlsServer $ \port -> do
        let ci = defaultConnectInfo
              { connectHost = "127.0.0.1", connectPort = port, connectUser = "u", connectPassword = "p"
              , connectEncryption = EncryptStrict, connectTls = trusting serverAuthCert, connectSessionSetup = [] }
        conn <- connect ci
        -- Fill the socket's send buffer, so that the close_notify blocks.
        let fillWith n = do
              count <- newIORef (0 :: Int)
              t <- forkIO $ handle (\(_ :: IOException) -> pure ()) $ forever $ do
                -- Through the connection's backend, which off Windows is this
                -- same send on the socket.  On Windows a thread inside
                -- network's own send can't be killed, as these are below.
                backendSend (connBackend conn) (B.replicate n 0)
                atomicModifyIORef' count (\c -> (c + 1, ()))
              untilSettled count
              pure t
        writers <- mapM fillWith [65536, 1]
        -- Stopped before the close: the buffer stays full.  Closing the
        -- socket under threads sending on it can leave a stale registration
        -- in GHC's IO manager, which breaks a later close of another socket
        -- (see Hmssql.Connection.Internal.closeSocket).
        mapM_ killThread writers
        closer <- forkIO (close conn)
        threadDelay 300_000
        killThread closer
        -- killThread returns once the exception is raised in the closer;
        -- give its handlers a moment to run.
        threadDelay 200_000
        fd <- Socket.withFdSocket (connSocket conn) pure
        again <- timeout 5_000_000 (try (close conn))
        Socket.close (connSocket conn)
        fd `shouldBe` (-1)
        fmap (either (\(e :: SomeException) -> Left (show e)) Right) again `shouldBe` Just (Right ())

    it "drops the TLS session" $ do
      ci <- testConnectInfo EncryptStrict
      conn <- connect ci
      tls <- not . isTransportSocket <$> readIORef (connTransport conn)
      close conn
      closed <- isTransportSocket <$> readIORef (connTransport conn)
      (tls, closed) `shouldBe` (True, True)

  describe "an RPC request over 65535 packets" $
    it "is sent: the 65535-packet limit is for SQL batches only" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectPacketSize = 512 } $ \conn -> do
        let n = 65536 * (512 - 8) + 1000
        query1 conn ("SELECT DATALENGTH(" <> param (B.replicate n 0x41) <> ")") `shouldReturn` Only (fromIntegral n :: Int64)

  describe "chunks received over TLS" $
    it "arrive intact with packets of 2049 to 4095 bytes, whatever the order of sizes" $ do
      ci <- testConnectInfo EncryptStrict
      let expected = B.concat (replicate 100000 "ab\1\2")
      mapM_ (\size -> withConnection ci { connectPacketSize = size } $ \conn -> do
          Only v <- query1 conn "SELECT CAST(REPLICATE(CAST(0x61620102 AS varbinary(max)), 100000) AS varbinary(max))"
          (size, B.length v, v == expected) `shouldBe` (size, B.length expected, True)
          rows <- query conn "SELECT TOP 3000 CAST(ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS int), REPLICATE(N'x', 50) FROM sys.all_columns"
          (size, rows) `shouldBe` (size, [(i, T.replicate 50 "x") | i <- [1 .. 3000 :: Int32]]))
        [3000, 4000, 2500]

  describe "parameter names" $
    it "the server accepts titlecase and modifier letters and spacing combining marks" $
      withTestDb $ \conn ->
        query conn (mkQuery "SELECT @x\x01C5 + @x\x02B0 + @\x0915\x093E"
          (NamedParams [("@x\x01C5", SqlParam (1 :: Int32)), ("@x\x02B0", SqlParam (2 :: Int32)), ("@\x0915\x093E", SqlParam (3 :: Int32))]))
          `shouldReturn` [Only (6 :: Int32)]
