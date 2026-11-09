-- | Tests found by mutation testing of "Hmssql.Connection" (connect, the
-- PRELOGIN exchange, the login response, and the defaults).
module Mutation.ConnectSpec (spec) where

import Control.Exception
import Control.Monad (forM_)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Word (Word8)
import Compat (timeoutInSlices)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Connection
import Hmssql.Tds.Client (Login7 (..), Prelogin (..), PreloginOption (..), encryptionWord, putPrelogin)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer
import TestDb

within :: IO a -> IO a
within act = timeoutInSlices 20_000_000 act >>= maybe (throwIO (userError "timed out")) pure

-- | Connect to a mock server running the handler and run one request; the
-- outcome of the client side, and of the handler.
connectTo :: (MockConn -> IO r) -> (ConnectInfo -> ConnectInfo) -> IO (Either SomeException (), Either SomeException r)
connectTo handler adjust = withMockServer handler $ \srv -> do
  r <- within (try (withConnection (adjust (mockConnectInfo srv)) (\conn -> () <$ execute conn "SELECT 1")))
  h <- nextResult srv
  pure (r, h)

expectProtocolError :: Either SomeException a -> Expectation
expectProtocolError = \case
  Left e | Just (ProtocolError _) <- fromException e -> pure ()
  Left e -> expectationFailure ("expected ProtocolError, got " ++ show e)
  Right _ -> expectationFailure "expected ProtocolError, but the connection succeeded"

-- | Answer PRELOGIN with the given message, sent as packets of the given
-- type, then (if the client goes on) log it in and serve requests.
preloginThen :: PacketType -> Prelogin -> MockConn -> IO ()
preloginThen ptype reply mc = do
  _ <- recvMessage mc
  mapM_ (sendRaw mc) (splitIntoPackets defaultTdsContext ptype (PacketStatus 0) (Put.runPut (putPrelogin reply)))
  awaitLogin7 mc >>= \case
    ClientSentLogin7 _ -> do
      sendTokens mc defaultLoginResponse
      serveRequests (\_ _ -> pure [doneToken 0 0]) mc
    _ -> pure ()

notSup :: Word8
notSup = encryptionWord EncryptNotSup

-- | FEATUREEXTACK (0xAE) with the given features.
featureExtAck :: [(Word8, B.ByteString)] -> Put
featureExtAck feats = do
  Put.putWord8 0xAE
  forM_ feats $ \(fid, dat) -> do
    Put.putWord8 fid
    Put.putWord32le (fromIntegral (B.length dat))
    Put.putByteString dat
  Put.putWord8 0xFF

-- | The UTF-8 support flag after a login answered with the given FEATUREEXTACK.
utf8SupportAfter :: [(Word8, B.ByteString)] -> IO Bool
utf8SupportAfter feats = do
  let handler mc = do
        _ <- serveLogin [loginAckToken Tds74 "x", featureExtAck feats, doneToken 0 0] mc
        serveRequests (\_ _ -> pure [doneToken 0 0]) mc
  withMockServer handler $ \srv ->
    within $ withConnection (mockConnectInfo srv) $ \conn ->
      tdsUtf8Support <$> connectionContext conn

-- | The LOGIN7 the client sends with these settings.
login7With :: (ConnectInfo -> ConnectInfo) -> IO Login7
login7With adjust = do
  (r, h) <- connectTo (cannedLoginServer defaultLoginResponse) adjust
  either throwIO pure r
  either throwIO pure h

spec :: Spec
spec = do
  describe "PRELOGIN response checks (mock server)" $ do
    it "refuses a server that requires MARS" $ do
      let reply = Prelogin [PLVersion 17 0 0 0, PLEncryption notSup, PLInstance "", PLThreadId Nothing, PLMars 1]
      (r, _) <- connectTo (preloginThen PTTabularResult reply) id
      expectProtocolError r

    it "refuses a PRELOGIN response of another packet type" $ do
      (r, _) <- connectTo (preloginThen PTPrelogin (preloginReply notSup)) id
      expectProtocolError r

    it "refuses a PRELOGIN response without the ENCRYPTION option" $ do
      let reply = Prelogin [PLVersion 17 0 0 0, PLInstance "", PLThreadId Nothing, PLMars 0]
      (r, _) <- connectTo (preloginThen PTTabularResult reply) id
      expectProtocolError r

  describe "the login response's FEATUREEXTACK (mock server)" $ do
    it "UTF8_SUPPORT (0x0A) with value 1 turns UTF-8 support on" $
      utf8SupportAfter [(0x0A, "\1")] `shouldReturn` True
    it "UTF8_SUPPORT with value 0 leaves it off" $
      utf8SupportAfter [(0x0A, "\0")] `shouldReturn` False
    it "another feature doesn't turn it on" $
      utf8SupportAfter [(0x0B, "\1")] `shouldReturn` False
    it "no FEATUREEXTACK leaves it off" $
      utf8SupportAfter [] `shouldReturn` False

  describe "LOGIN7 (mock server)" $ do
    it "sets the read-only intent bit (TypeFlags 0x20) only when asked to" $ do
      ro <- login7With (\ci -> ci { connectReadOnlyIntent = True })
      rw <- login7With id
      (l7TypeFlags ro .&. 0x20, l7TypeFlags rw .&. 0x20) `shouldBe` (0x20, 0)

    it "sends the application and server names in their own fields" $ do
      l7 <- login7With (\ci -> ci { connectApplicationName = "app", connectServerName = "srv" })
      (l7AppName l7, l7ServerName l7) `shouldBe` ("app", "srv")

    it "sends the language and database in their own fields" $ do
      l7 <- login7With (\ci -> ci { connectLanguage = "lang", connectDatabase = "db" })
      (l7Language l7, l7Database l7) `shouldBe` ("lang", "db")

  describe "defaultConnectInfo" $ do
    it "asks for 8000-byte packets" $
      connectPacketSize defaultConnectInfo `shouldBe` 8000
    it "calls the application hmssql" $
      connectApplicationName defaultConnectInfo `shouldBe` "hmssql"
    it "asks for encryption (ENCRYPT_ON)" $
      (encryptionWord (connectEncryption defaultConnectInfo)) `shouldBe` encryptionWord EncryptOn
    it "doesn't declare read-only intent" $
      connectReadOnlyIntent defaultConnectInfo `shouldBe` False
    it "runs defaultSessionSetup" $
      connectSessionSetup defaultConnectInfo `shouldBe` defaultSessionSetup
    it "validates the server certificate against the system store" $ do
      let t = connectTls defaultConnectInfo
      (tlsTrustServerCertificate t, tlsUseSystemCertificateStore t, tlsCaCertificateFiles t, length (tlsExtraCertificates t), tlsHostNameInCertificate t)
        `shouldBe` (False, True, [], 0, Nothing)

  describe "session setup (live server)" $ around withTestDb $ do
    it "runs the statements in order, each in the session" $ \_ -> do
      ci <- testConnectInfo EncryptStrict
      let setup = ["CREATE TABLE #mutation_setup_order (i int)", "INSERT INTO #mutation_setup_order VALUES (7)"]
      withConnection ci { connectSessionSetup = setup } $ \conn ->
        query conn "SELECT i FROM #mutation_setup_order" `shouldReturn` [Only (7 :: Int32)]

    it "the login's options, plus a SET ARITHABORT ON setup, are all in effect" $ \_ -> withTestDbWith (\ci -> ci { connectSessionSetup = ["SET ARITHABORT ON"] }) $ \conn -> do
      -- @@OPTIONS bits: 8 ANSI_WARNINGS, 16 ANSI_PADDING, 32 ANSI_NULLS,
      -- 64 ARITHABORT, 256 QUOTED_IDENTIFIER, 4096 CONCAT_NULL_YIELDS_NULL,
      -- 8192 NUMERIC_ROUNDABORT (off), 2 IMPLICIT_TRANSACTIONS (off),
      -- 4 CURSOR_CLOSE_ON_COMMIT (off).
      Only (opts :: Int32) <- query1 conn "SELECT CAST(@@OPTIONS AS int)"
      [(name, opts .&. bit /= 0) | (name, bit) <- optionBits]
        `shouldBe` [(name, on) | (name, _, on) <- expectedOptions]
      -- The login's TEXTSIZE: -1, unlimited.
      Only (textSize :: Int32) <- query1 conn "SELECT @@TEXTSIZE"
      textSize `shouldBe` (-1)

    -- SQL Server 2017 has no UTF-8 collations, and its FEATUREEXTACK has no
    -- UTF8_SUPPORT.
    it "reports UTF-8 support negotiated with the server (none before SQL Server 2019)" $ \conn -> do
      v <- testSqlVersion
      (tdsUtf8Support <$> connectionContext conn) `shouldReturn` (v >= 2019)
  where
    expectedOptions :: [(String, Int32, Bool)]
    expectedOptions =
      [ ("IMPLICIT_TRANSACTIONS", 2, False)
      , ("CURSOR_CLOSE_ON_COMMIT", 4, False)
      , ("ANSI_WARNINGS", 8, True)
      , ("ANSI_PADDING", 16, True)
      , ("ANSI_NULLS", 32, True)
      , ("ARITHABORT", 64, True)
      , ("QUOTED_IDENTIFIER", 256, True)
      , ("CONCAT_NULL_YIELDS_NULL", 4096, True)
      , ("NUMERIC_ROUNDABORT", 8192, False)
      ]
    optionBits = [(name, bit) | (name, bit, _) <- expectedOptions]
