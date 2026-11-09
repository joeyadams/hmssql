-- | PRELOGIN encryption negotiation ([MS-TDS] 2.2.6.5): every client setting
-- against every server answer (mock server), and the combinations a real
-- server offers (live).
module Protocol.EncryptionSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Word (Word8)
import System.Timeout (timeout)
import Test.Hspec
import Text.Printf (printf)

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client (Prelogin (..), PreloginOption (..), encryptionWord)
import MockServer
import TestDb

-- | What happened after the server's PRELOGIN answer.
data Outcome
  = Plain    -- ^ the client logged in without TLS
  | Tls      -- ^ the client started a TLS handshake
  | Refused  -- ^ the client gave up with a ProtocolError, sending nothing more
  deriving (Eq, Show)

-- | Rows: client setting.  Columns: the server's answer (ENCRYPT_OFF, _ON,
-- _NOT_SUP, _REQ).  The client-side table of 2.2.6.5, completed with the
-- server-side table's \"connection terminated\" cells.
expected :: [(Encryption, [(Word8, Outcome)])]
expected =
  [ (EncryptOff,    [(0, Tls),     (1, Tls),     (2, Plain),   (3, Tls)])
  , (EncryptOn,     [(0, Refused), (1, Tls),     (2, Refused), (3, Tls)])
  , (EncryptNotSup, [(0, Plain),   (1, Refused), (2, Plain),   (3, Refused)])
  , (EncryptReq,    [(0, Refused), (1, Tls),     (2, Refused), (3, Tls)])
  ]

-- | Answers that are never valid: ENCRYPT_STRICT (TDS 8.0 does not negotiate
-- in PRELOGIN), ENCRYPT_CLIENT_CERT variants (we never ask for client
-- certificates), the reserved ENCRYPT_EXT bit, and unknown values.
invalidAnswers :: [Word8]
invalidAnswers = [0x04, 0x05, 0x20, 0x21, 0x80, 0x81, 0x83, 0xFF]

-- | The client's PRELOGIN ENCRYPTION byte, and what it did next.
negotiationHandler :: Word8 -> MockConn -> IO (Maybe Word8, ClientStep)
negotiationHandler answer mc = do
  Prelogin opts <- respondPrelogin (preloginReply answer) mc
  step <- awaitLogin7 mc
  case step of
    ClientSentLogin7 _ -> do
      sendTokens mc defaultLoginResponse
      serveRequests (\_ _ -> pure [doneToken 0 0]) mc
    _ -> pure ()
  pure (case [e | PLEncryption e <- opts] of { e : _ -> Just e; [] -> Nothing }, step)

runNegotiation :: Encryption -> Word8 -> IO (Maybe Word8, Outcome)
runNegotiation client answer =
  withMockServer (negotiationHandler answer) $ \srv -> do
    let ci = (mockConnectInfo srv) { connectEncryption = client }
    r <- timeout 10_000_000 (try (withConnection ci (\_ -> pure ())))
    server <- nextResult srv
    case (r, server) of
      (Nothing, _) -> fail "client timed out"
      (_, Left e) -> fail ("mock server failed: " ++ show e)
      (Just clientResult, Right (sent, step)) -> do
        outcome <- case (clientResult, step) of
          (Right (), ClientSentLogin7 _) -> pure Plain
          (Left _, ClientStartedTls) -> pure Tls
          (Left e, ClientClosed) | isProtocolError e -> pure Refused
          other -> fail ("inconsistent result " ++ show other)
        pure (sent, outcome)
  where
    isProtocolError (e :: SomeException) = case fromException e of
      Just (ProtocolError _) -> True
      Nothing -> False

-- | The encryption of the physical connection.  A MARS connection has a
-- row of its own for each SMP session besides it, all with the same
-- @session_id@; the physical connection's is the one without a parent.
encryptOption :: Connection -> IO Text
encryptOption conn = do
  Only v <- query1 conn "SELECT CAST(encrypt_option AS nvarchar(10)) FROM sys.dm_exec_connections \
                        \WHERE session_id = @@SPID AND parent_connection_id IS NULL"
  pure v

spec :: Spec
spec = do
  describe "PRELOGIN encryption negotiation (mock server)" $ do
    forM_ expected $ \(client, row) ->
      forM_ row $ \(answer, outcome) ->
        it (printf "%s, server answers 0x%02x: %s" (show client) answer (show outcome)) $ do
          (sent, got) <- runNegotiation client answer
          sent `shouldBe` Just (encryptionWord client)
          got `shouldBe` outcome

    forM_ [EncryptOff, EncryptOn, EncryptNotSup, EncryptReq] $ \client ->
      it (show client ++ " refuses invalid answers") $
        forM_ invalidAnswers $ \answer -> do
          (_, got) <- runNegotiation client answer
          (answer, got) `shouldBe` (answer, Refused)

  describe "PRELOGIN encryption negotiation (live server)" $ do
    it "EncryptOff encrypts only the login (everything, if the server requires encryption)" $ withTestConnection EncryptOff $ \conn -> do
      required <- testServerRequiresEncryption
      encryptOption conn `shouldReturn` (if required then "TRUE" else "FALSE")
    it "EncryptOn encrypts the session" $ withTestConnection EncryptOn $ \conn ->
      encryptOption conn `shouldReturn` "TRUE"
    it "EncryptReq encrypts the session" $ withTestConnection EncryptReq $ \conn ->
      encryptOption conn `shouldReturn` "TRUE"
    skipIfEncryptionRequired $ it "EncryptNotSup logs in without encryption" $ withTestConnection EncryptNotSup $ \conn ->
      encryptOption conn `shouldReturn` "FALSE"
    it "EncryptStrict encrypts the session" $ withTestConnection EncryptStrict $ \conn ->
      encryptOption conn `shouldReturn` "TRUE"
