-- | ENVCHANGE parsing against the byte layouts of [MS-TDS] 2.2.7.9, and
-- routing (type 20) end to end against the mock server.
module Protocol.EnvChangeSpec (spec) where

import Wire.RecipeGet (getToken)
import Control.Exception (displayException, throwIO, try)
import Control.Monad (forM_, replicateM_)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client (Login7 (..))
import Hmssql.Tds.Context
import Hmssql.Tds.Token
import MockServer

-- | Parse a whole byte string as tokens.
parseTokens :: [Word8] -> Either String [Token]
parseTokens = go . B.pack
  where
    go bs
      | B.null bs = Right []
      | otherwise = case Get.runGetOrFail (getToken defaultTdsContext Nothing) (LB.fromStrict bs) of
          Left (_, _, err) -> Left err
          Right (rest, _, tok) -> (tok :) <$> go (LB.toStrict rest)

-- | An ENVCHANGE token: 0xE3, USHORT length, type, then the value bytes.
envChange :: Word8 -> [Word8] -> [Word8]
envChange ty values = [0xE3, fromIntegral len, fromIntegral (len `div` 256), ty] ++ values
  where len = 1 + length values

-- | B_VARCHAR.
bvarchar :: Text -> [Word8]
bvarchar t = let bs = B.unpack (T.encodeUtf16LE t) in fromIntegral (length bs `div` 2) : bs

-- | A DONE token, to check the parser stops at the right place.
done :: [Word8]
done = [0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

doneTok :: Token
doneTok = TDone (Done 0 0 0)

-- | Parse an ENVCHANGE followed by DONE.
shouldParseAs :: [Word8] -> EnvChange -> Expectation
shouldParseAs bytes ec = parseTokens (bytes ++ done) `shouldBe` Right [TEnvChange ec, doneTok]

descriptor :: [Word8]
descriptor = [1, 2, 3, 4, 5, 6, 7, 8]

td :: TransactionDescriptor
td = TransactionDescriptor 0x0807060504030201

spec :: Spec
spec = do
  describe "ENVCHANGE parsing (MS-TDS 2.2.7.9)" $ do
    it "1: database (new, old B_VARCHAR)" $
      envChange 1 (bvarchar "db" ++ bvarchar "master") `shouldParseAs` ECDatabase "master" "db"
    it "2: language" $
      envChange 2 (bvarchar "us_english" ++ bvarchar "") `shouldParseAs` ECLanguage "" "us_english"
    it "3: character set" $
      envChange 3 (bvarchar "iso_1" ++ bvarchar "") `shouldParseAs` ECCharacterSet "" "iso_1"
    it "4: packet size (B_VARCHAR numbers)" $
      envChange 4 (bvarchar "8000" ++ bvarchar "4096") `shouldParseAs` ECPacketSize 4096 8000
    it "5: Unicode sorting locale (old %x00)" $
      envChange 5 (bvarchar "1033" ++ [0]) `shouldParseAs` ECUnicodeSortingLocale "1033"
    it "6: Unicode comparison flags (old %x00)" $
      envChange 6 (bvarchar "196609" ++ [0]) `shouldParseAs` ECUnicodeComparisonFlags "196609"
    it "7: SQL collation (new, old B_VARBYTE)" $
      envChange 7 ([5, 0x09, 0x04, 0xD0, 0x00, 0x34] ++ [0])
        `shouldParseAs` ECSqlCollation B.empty (B.pack [0x09, 0x04, 0xD0, 0x00, 0x34])
    it "8: begin transaction (new B_VARBYTE, old %x00)" $
      envChange 8 ([8] ++ descriptor ++ [0]) `shouldParseAs` ECBeginTransaction td
    it "9: commit transaction (new %x00, old B_VARBYTE)" $
      envChange 9 ([0, 8] ++ descriptor) `shouldParseAs` ECCommitTransaction td
    it "10: rollback transaction (new %x00, old B_VARBYTE)" $
      envChange 10 ([0, 8] ++ descriptor) `shouldParseAs` ECRollbackTransaction td
    it "11: enlist DTC transaction, descriptor on either side" $ do
      envChange 11 ([0, 8] ++ descriptor) `shouldParseAs` ECEnlistDtcTransaction td
      envChange 11 ([8] ++ descriptor ++ [0]) `shouldParseAs` ECEnlistDtcTransaction td
    it "12: defect transaction, descriptor on either side" $ do
      envChange 12 ([8] ++ descriptor ++ [0]) `shouldParseAs` ECDefectTransaction td
      envChange 12 ([0, 8] ++ descriptor) `shouldParseAs` ECDefectTransaction td
    it "13: mirroring partner (new B_VARCHAR, old %x00)" $
      envChange 13 (bvarchar "partner" ++ [0]) `shouldParseAs` ECMirroringPartner "partner"
    it "15: promote transaction (Length 1, L_VARBYTE outside it)" $
      ([0xE3, 1, 0, 15] ++ [3, 0, 0, 0, 0xAA, 0xBB, 0xCC] ++ [0])
        `shouldParseAs` ECPromoteTransaction (B.pack [0xAA, 0xBB, 0xCC])
    it "15: promote transaction (Length covering the value)" $
      envChange 15 ([3, 0, 0, 0, 0xAA, 0xBB, 0xCC] ++ [0])
        `shouldParseAs` ECPromoteTransaction (B.pack [0xAA, 0xBB, 0xCC])
    it "16: transaction manager address (new B_VARBYTE, old %x00)" $
      envChange 16 ([2, 0xDE, 0xAD] ++ [0]) `shouldParseAs` ECTransactionManagerAddress (B.pack [0xDE, 0xAD])
    it "17: transaction ended, descriptor on either side" $ do
      envChange 17 ([0, 8] ++ descriptor) `shouldParseAs` ECTransactionEnded td
      envChange 17 ([8] ++ descriptor ++ [0]) `shouldParseAs` ECTransactionEnded td
    it "18: reset connection ack (%x00 %x00)" $
      envChange 18 [0, 0] `shouldParseAs` ECResetConnectionAck
    it "19: user instance (new B_VARCHAR, old %x00)" $
      envChange 19 (bvarchar "pipe" ++ [0]) `shouldParseAs` ECUserInstance "pipe"
    it "20: routing (RoutingData, old %x00 %x00)" $
      -- server "db1", port 1433
      [ 0xE3, 0x10, 0x00, 0x14
      , 0x0B, 0x00                            -- RoutingDataValueLength = 11
      , 0x00                                  -- Protocol = TCP
      , 0x99, 0x05                            -- ProtocolProperty = 1433
      , 0x03, 0x00, 0x64, 0x00, 0x62, 0x00, 0x31, 0x00 -- AlternateServer = US_VARCHAR "db1"
      , 0x00, 0x00                            -- OldValue
      ] `shouldParseAs` ECRouting (RoutingInfo 0 1433 "db1")
    it "20: routing without routing data is rejected" $
      parseTokens (envChange 20 [0, 0, 0, 0]) `shouldSatisfy` isLeft
    it "20: routing with a one-byte old value is rejected" $
      parseTokens (envChange 20 ([0x0B, 0x00, 0x00, 0x99, 0x05, 0x03, 0x00, 0x64, 0x00, 0x62, 0x00, 0x31, 0x00] ++ [0]))
        `shouldSatisfy` isLeft
    it "unknown types (14, 21) are kept as raw bytes" $ do
      envChange 14 [1, 2, 3] `shouldParseAs` ECUnknown 14 (B.pack [1, 2, 3])
      envChange 21 [0, 0] `shouldParseAs` ECUnknown 21 (B.pack [0, 0])
    it "routing round-trips through the mock server's encoder" $ hedgehog $ do
      server <- forAll $ Gen.text (Range.linear 1 100) Gen.unicode
      port <- forAll $ Gen.word16 (Range.linear 1 maxBound)
      let bytes = B.unpack $ LB.toStrict $ Put.runPut (routingEnvChange server port)
      parseTokens bytes === Right [TEnvChange (ECRouting (RoutingInfo 0 port server))]

  describe "routing at login (mock server)" $ do
    it "the mock server accepts a plain login" $
      withMockServer (cannedLoginServer defaultLoginResponse) $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (mockConnectInfo srv) $ \conn ->
          execute conn "SELECT 1"
        r `shouldBe` Just 0
        Right l7 <- nextResult srv
        l7UserName l7 `shouldBe` "mockuser"
        l7Password l7 `shouldBe` "mockpassword"
        l7Database l7 `shouldBe` "mockdb"

    forM_ [("", "127.0.0.1"), ("mockserver", "mockserver")] $ \(serverName, expectedName) ->
      it ("follows a redirect with the login server-name override " ++ show serverName) $ do
        withTcpMockServer (cannedLoginServer defaultLoginResponse) $ \target -> do
          let response =
                [ loginAckToken Tds74 "Microsoft SQL Server"
                , routingEnvChange "127.0.0.1" (read (mockPort target))
                , doneToken 0 0
                ]
              ci srv = (mockConnectInfo srv) { connectServerName = serverName, connectApplicationName = "redirected" }
          withMockServer (cannedLoginServer response) $ \gateway -> do
            r <- timeout 10_000_000 $ withConnection (ci gateway) $ \conn -> execute conn "SELECT 1"
            r `shouldBe` Just 0
            -- The gateway's connection was closed after the login response,
            -- with nothing more sent to it.
            Right l7 <- nextResult gateway
            Right l7' <- nextResult target
            let fields l = (l7UserName l, l7Password l, l7Database l, l7AppName l)
            fields l7' `shouldBe` fields l7
            -- The server name becomes the target's, as Azure's node needs.
            l7ServerName l7 `shouldBe` expectedName
            l7ServerName l7' `shouldBe` T.pack ("127.0.0.1," ++ mockPort target)

    it "connects to the port named, ignoring an instance name" $
      withTcpMockServer (cannedLoginServer defaultLoginResponse) $ \target -> do
        let response =
              [ loginAckToken Tds74 "Microsoft SQL Server"
              , routingEnvChange "127.0.0.1\\SQLEXPRESS" (read (mockPort target))
              , doneToken 0 0
              ]
        withMockServer (cannedLoginServer response) $ \gateway -> do
          r <- timeout 10_000_000 $ withConnection (mockConnectInfo gateway) $ \conn -> execute conn "SELECT 1"
          r `shouldBe` Just 0
          nextResult target >>= either (expectationFailure . show) (\_ -> pure ())

    it "follows a chain of redirects, each login with the caller's settings but the server name" $
      withTcpMockServer (cannedLoginServer defaultLoginResponse) $ \target ->
        withTcpMockServer (cannedLoginServer (redirectTo "127.0.0.1" (mockPort target))) $ \middle ->
          withMockServer (cannedLoginServer (redirectTo "127.0.0.1" (mockPort middle))) $ \gateway -> do
            let ci = (mockConnectInfo gateway) { connectServerName = "mockserver" }
            r <- timeout 10_000_000 $ withConnection ci $ \conn -> execute conn "SELECT 1"
            r `shouldBe` Just 0
            Right l7 <- nextResult gateway
            Right l7' <- nextResult middle
            Right l7'' <- nextResult target
            let fields l = (l7UserName l, l7Password l, l7Database l, l7AppName l)
            map fields [l7', l7''] `shouldBe` [fields l7, fields l7]
            map l7ServerName [l7, l7', l7'']
              `shouldBe` ["mockserver", T.pack ("127.0.0.1," ++ mockPort middle), T.pack ("127.0.0.1," ++ mockPort target)]

    it "follows ten redirects in a row" $ do
      -- A server that redirects the first ten logins to itself, then
      -- accepts one.
      logins <- newIORef (0 :: Int)
      let handler port mc = do
            n <- atomicModifyIORef' logins (\n -> (n + 1, n))
            cannedLoginServer (if n < 10 then redirectTo "127.0.0.1" port else defaultLoginResponse) mc
      withMockServerAt handler $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (mockConnectInfo srv) $ \conn -> execute conn "SELECT 1"
        r `shouldBe` Just 0
        readIORef logins `shouldReturn` 11

    it "throws LoginRedirected at the eleventh, naming its target, with every connection closed" $ do
      logins <- newIORef (0 :: Int)
      let handler port mc = do
            atomicModifyIORef' logins (\n -> (n + 1, ()))
            cannedLoginServer (redirectTo "127.0.0.1" port) mc
      withMockServerAt handler $ \srv -> do
        r <- timeout 10_000_000 $ try $ withConnection (mockConnectInfo srv) (\_ -> pure ())
        r `shouldBe` Just (Left (LoginRedirected "127.0.0.1" (read (mockPort srv))))
        -- Eleven logins, each closed without anything more sent.
        replicateM_ 11 $ nextResult srv >>= either (expectationFailure . show) (\_ -> pure ())
        readIORef logins `shouldReturn` 11

    describe "a redirect that can't be followed is a ProtocolError" $ do
      let refused server port = withMockServer (cannedLoginServer (redirectTo server port)) $ \gateway -> do
            r <- timeout 10_000_000 $ try $ withConnection (mockConnectInfo gateway) (\_ -> pure ())
            case r of
              Just (Left (ProtocolError _)) -> pure ()
              other -> expectationFailure ("expected a ProtocolError, got " ++ show (fmap (either (Left . show) (Right . const ())) other))
            -- The gateway's connection was closed.
            nextResult gateway >>= either (expectationFailure . show) (\_ -> pure ())
      it "no host" $ refused "" "11000"
      it "only an instance name" $ refused "\\SQLEXPRESS" "11000"
      it "port 0" $ refused "127.0.0.1" "0"

    it "a redirect to a server that can't be reached fails as a transport failure" $ withRefusingPort $ \port -> do
      let response =
            [ loginAckToken Tds74 "Microsoft SQL Server"
            , routingEnvChange "127.0.0.1" (read (T.unpack port))
            , doneToken 0 0
            ]
      withMockServer (cannedLoginServer response) $ \gateway -> do
        r <- timeout 10_000_000 $ try $ withConnection (mockConnectInfo gateway) (\_ -> pure ())
        case r of
          Just (Left (ConnectionClosedBy (TransportFailed _))) -> pure ()
          other -> expectationFailure ("expected a transport failure, got " ++ show (fmap (either (Left . show) (Right . const ())) other))

    it "does not follow a redirect in the plaintext response to a login-only encrypted login" $ do
      -- EncryptOff against a server with encryption off: LOGIN7 goes over
      -- TLS, and the response carrying the redirect comes back in
      -- plaintext, where anyone on the path could have written it.  The
      -- redirect names a server that would accept the login, and counts
      -- its connections: following the redirect would send it the login.
      connections <- newIORef (0 :: Int)
      let counting mc = do
            atomicModifyIORef' connections (\n -> (n + 1, ()))
            cannedLoginServer defaultLoginResponse mc
      withTcpMockServer counting $ \target -> do
        let port = read (mockPort target)
            response =
              [ loginAckToken Tds74 "Microsoft SQL Server"
              , routingEnvChange "127.0.0.1" port
              , doneToken 0 0
              ]
            -- The client closes the connection after the response, with
            -- nothing more sent.
            gateway mc = do
              l7 <- serveLoginOnlyTls response mc
              recvBytes mc 1 >>= \case
                Nothing -> pure l7
                Just _ -> throwIO (MockUnexpected "the client sent more after the login response")
        withMockServer gateway $ \srv -> do
          r <- timeout 10_000_000 $ try $ withConnection (loginOnly srv) (\_ -> pure ())
          r `shouldBe` Just (Left (LoginRedirected "127.0.0.1" port))
          Right l7 <- nextResult srv
          l7Password l7 `shouldBe` "mockpassword"
          readIORef connections `shouldReturn` 0

    it "a login-only encrypted login goes on in plaintext (the mock above, without a redirect)" $
      withMockServer (\mc -> serveLoginOnlyTls defaultLoginResponse mc <* serveRequests (\_ _ -> pure [doneToken 0 0]) mc) $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (loginOnly srv) $ \conn -> execute conn "SELECT 1"
        r `shouldBe` Just 0
        Right l7 <- nextResult srv
        l7UserName l7 `shouldBe` "mockuser"

    it "describes an unfollowed redirect in displayException" $
      displayException (LoginRedirected "other.example" 11000)
        `shouldBe` "the login was redirected to other.example, port 11000, and not followed: one redirect too many (hmssql follows ten), or one in plaintext after an encrypted login"

    it "a login error takes precedence over routing" $ do
      let err = ServerMessage 18456 1 14 "Login failed for user 'mockuser'." "mock" "" 1
          response = [errorToken err, routingEnvChange "other.example" 11000, doneToken 0x0002 0]
      withMockServer (cannedLoginServer response) $ \srv -> do
        r <- timeout 10_000_000 $ try $ withConnection (mockConnectInfo srv) (\_ -> pure ())
        case r of
          Just (Left (LoginError msg)) -> msgNumber msg `shouldBe` 18456
          other -> expectationFailure ("expected LoginError, got " ++ show (fmap (either (Left . show) (Right . const ())) other))
  where
    isLeft = either (const True) (const False)
    -- EncryptOff, to a mock with encryption off: LOGIN7 alone is encrypted,
    -- and the mock's certificate is self-signed.
    loginOnly srv = (mockConnectInfo srv)
      { connectEncryption = EncryptOff
      , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
      }

-- | A login response that redirects to the server and port given.
redirectTo :: Text -> String -> [Put.Put]
redirectTo server port =
  [loginAckToken Tds74 "Microsoft SQL Server", routingEnvChange server (read port), doneToken 0 0]
