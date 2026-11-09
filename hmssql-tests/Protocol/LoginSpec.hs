-- | LOGIN7 and LOGINACK strings: no stray NULs in either direction.
module Protocol.LoginSpec (spec) where

import Wire.RecipeGet (getToken)
import Control.Exception (SomeException, bracket, bracketOnError, fromException, try)
import Control.Monad (forM_)
import Data.Int (Int32)
import Data.Word (Word8)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Network.HostName (getHostName)
import qualified Network.Socket as Socket
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql
import Hmssql.Connection.Backend (Backend (..), isLocalHost, namedPipe, pipeBackend, sharedMemoryPipe, socketBackend, tcpBackend)
import Hmssql.Connection.Internal (newConnection, nextToken, runBody, startRequest)
import Hmssql.Connection.Tls (strictTlsHandshake)
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token
import Hmssql.Errors
import MockServer (cannedLoginServer, defaultLoginResponse, doneToken, errorToken, loginAckToken, mockConnectInfo, mockPort, nextResult, withMockServer, withTcpMockServer)
import Protocol.MockTokens (withinSecs)
import TestConfig
import Wire.Login7Parser (getLogin7)

parseToken :: LB.ByteString -> Either String Token
parseToken bytes = case Get.runGetOrFail (getToken defaultTdsContext Nothing) bytes of
  Left (_, _, err) -> Left err
  Right (rest, _, tok)
    | LB.null rest -> Right tok
    | otherwise -> Left "trailing bytes"

genName :: Gen Text
genName = Gen.text (Range.linear 0 60) Gen.unicode

genLogin7 :: Gen Login7
genLogin7 = do
  l7Version <- Gen.element [Tds74, Tds80]
  l7PacketSize <- Gen.word32 (Range.linear 512 32767)
  l7ClientProgVer <- Gen.word32 Range.linearBounded
  l7ClientPid <- Gen.word32 Range.linearBounded
  l7ConnectionId <- Gen.word32 Range.linearBounded
  l7OptionFlags1 <- Gen.word8 Range.linearBounded
  l7OptionFlags2 <- Gen.word8 Range.linearBounded
  l7TypeFlags <- Gen.word8 Range.linearBounded
  -- 0x10 (fExtension) is derived from l7Features.
  l7OptionFlags3 <- Gen.element [0, 0x01, 0x02, 0x04, 0x08]
  l7TimeZone <- Gen.int32 Range.linearBounded
  l7Collation <- Gen.word32 Range.linearBounded
  l7HostName <- genName
  l7UserName <- genName
  l7Password <- genName
  l7AppName <- genName
  l7ServerName <- genName
  l7LibraryName <- genName
  l7Language <- genName
  l7Database <- genName
  l7ClientId <- Gen.bytes (Range.singleton 6)
  l7Features <- Gen.list (Range.linear 0 3) $
    Feature <$> Gen.word8 (Range.linear 0 0xFE) <*> Gen.bytes (Range.linear 0 20)
  pure Login7{..}

-- | Log in to the live server with the internal API and return every token
-- of the login response.
rawLoginResponse :: IO [Token]
rawLoginResponse = do
  -- The handshake below is strict TLS whatever the configured encryption.
  strictEncryptionPending >>= mapM_ pendingWith
  ci <- defaultTestConnectInfo
  let serverName = if T.null (connectServerName ci) then connectHost ci else connectServerName ci
  loginAt (3 :: Int) True (T.unpack (connectHost ci)) (T.unpack (connectPort ci)) serverName ci
  where
    -- Azure's gateway redirects a login from inside Azure to the
    -- database's node (a LOGINACK, a routing ENVCHANGE and nothing else):
    -- follow it, as 'connect' does, and return the node's response.
    loginAt hops first host port serverName ci = do
      toks <- loginOnce first host port serverName ci
      case [r | TEnvChange (ECRouting r) <- toks] of
        RoutingInfo{..} : _ | hops > 0 ->
          let host' = T.unpack (T.takeWhile (/= '\\') routingServer)
              port' = show routingPort
           in loginAt (hops - 1) False host' port' (routingServer <> "," <> T.pack port') ci
        _ -> pure toks
    -- What 'connect' opens when the suite is run over a pipe
    -- (HMSSQL_TEST_PROTOCOL): the server may have TCP/IP disabled.  A
    -- redirect leads to a TCP endpoint, as it does for 'connect'.
    openRaw first host port ci = case connectProtocol ci of
      ProtocolSharedMemory | first -> pipeBackend (sharedMemoryPipe (T.unpack (connectInstance ci)))
      ProtocolNamedPipes | first -> do
        local <- (|| host `elem` ["127.0.0.1", "::1"]) <$> isLocalHost host
        pipeBackend (namedPipe local host (T.unpack (connectInstance ci)))
      _ -> do
        let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream }
        addr : _ <- Socket.getAddrInfo (Just hints) (Just host) (Just port)
        bracketOnError (Socket.openSocket addr) Socket.close $ \sock -> do
          Socket.connect sock (Socket.addrAddress addr)
          socketBackend sock
    loginOnce first host port serverName ci =
      bracket (openRaw first host port ci) backendClose $ \backend -> do
        conn <- newConnection backend defaultTdsContext (\_ -> pure ())
        strictTlsHandshake conn (connectTls ci) host
        let l7 = defaultLogin7
              { l7Version = Tds80
              , l7UserName = connectUser ci
              , l7Password = connectPassword ci
              , l7Database = connectDatabase ci
              , l7ServerName = serverName -- Azure's gateway routes the login by it
              , l7AppName = "hmssql-tests"
              }
        ar <- startRequest conn PTLogin7 (\_ -> runBody (putLogin7 l7))
        let go = nextToken conn ar >>= maybe (pure []) (\t -> (t :) <$> go)
        go

hasNul :: Text -> Bool
hasNul = T.any (== '\0')

-- | Connect to a mock that refuses the login with this error.
refusedWith :: Int32 -> Word8 -> IO (Either SomeException ())
refusedWith number severity = do
  let msg = ServerMessage number 1 severity "Login refused by the mock." "mock" "" 1
  withMockServer (cannedLoginServer [errorToken msg, doneToken 0x0002 0]) $ \srv ->
    withinSecs 10 $ try $ withConnection (mockConnectInfo srv) (\_ -> pure ())

-- | The 'LoginError' of a failed connect, or a failure naming what it got.
expectLoginError :: Either SomeException () -> IO LoginError
expectLoginError = \case
  Left e | Just le <- fromException e -> pure le
  Left e -> fail ("expected LoginError, got " ++ show e)
  Right () -> fail "expected LoginError, connected"

spec :: Spec
spec = do
  describe "LOGIN7 server name" $ do
    -- The custom transport reaches the mock independently of connectHost,
    -- as a tunnel would. Check the actual LOGIN7 without resolving test names.
    let sentName host override =
          withTcpMockServer (cannedLoginServer defaultLoginResponse) $ \srv -> do
            let ci = (mockConnectInfo srv)
                  { connectHost = host
                  , connectServerName = override
                  , connectProtocol = ProtocolCustom (tcpBackend "127.0.0.1" (mockPort srv))
                  }
            withConnection ci $ \_ -> pure ()
            Right l7 <- nextResult srv
            pure (l7ServerName l7)
    forM_ ["myserver.database.windows.net", "db.alias.example", "127.0.0.1", "::1", "[::1]"] $ \host ->
      it ("uses the configured host unchanged when no override is set: " ++ T.unpack host) $
        sentName host "" `shouldReturn` host
    it "preserves an explicit logical server name when the transport uses a tunnel" $
      sentName "localhost" "myserver.database.windows.net" `shouldReturn` "myserver.database.windows.net"

  describe "a login refused by the server" $ do
    it "is a LoginError carrying the server's number" $ do
      e <- refusedWith 18456 14 >>= expectLoginError
      loginErrorNumber e `shouldBe` 18456
      isTransientLoginError e `shouldBe` False

    it "is a LoginError at severity 20 or more too, not a SqlServerError" $
      forM_ [20, 21, 25] $ \severity -> do
        r <- refusedWith 18456 severity
        case r of
          Left e | Just (SqlServerError m _) <- fromException e ->
            expectationFailure ("a SqlServerError at severity " ++ show (msgClass m))
          _ -> pure ()
        e <- expectLoginError r
        loginErrorNumber e `shouldBe` 18456

    it "is transient for 6005 (shutdown in progress) and Azure's 40613, 40501 and 49918 to 49920" $
      forM_ [6005, 40613, 40501, 49918, 49919, 49920] $ \number -> do
        e <- refusedWith number 14 >>= expectLoginError
        (loginErrorNumber e, isTransientLoginError e) `shouldBe` (number, True)

    it "is not transient for a database that can't be opened (4060), a disabled login (18470) or a missing permission (916)" $
      forM_ [4060, 18470, 916] $ \number -> do
        e <- refusedWith number 11 >>= expectLoginError
        (loginErrorNumber e, isTransientLoginError e) `shouldBe` (number, False)

  describe "LOGINACK" $ do
    it "drops the NUL padding from ProgName" $ do
      let bytes = Put.runPut (loginAckToken Tds74 "Microsoft SQL Server\0\0\0\0")
      fmap (\case TLoginAck la -> Just (laProgName la); _ -> Nothing) (parseToken bytes)
        `shouldBe` Right (Just "Microsoft SQL Server")

    it "parses the spec's byte layout" $ do
      -- Interface 1, TDS 7.4, ProgName "SQL\0" (4 chars), version 17.0.3.232
      let bytes = LB.pack $
            [0xAD, 0x12, 0x00, 0x01, 0x74, 0x00, 0x00, 0x04, 0x04]
              ++ concatMap (\c -> [fromIntegral (fromEnum c), 0]) ("SQL\0" :: String)
              ++ [17, 0, 3, 232]
      parseToken bytes `shouldBe` Right (TLoginAck (LoginAck 1 0x74000004 "SQL" (17, 0, 3, 232)))

    it "from the live server has no NULs in ProgName or other strings" $ do
      toks <- rawLoginResponse
      [laProgName la | TLoginAck la <- toks] `shouldBe` ["Microsoft SQL Server"]
      let strings = concat
            [ case t of
                TEnvChange ec -> case ec of
                  ECDatabase o n -> [o, n]
                  ECLanguage o n -> [o, n]
                  ECCharacterSet o n -> [o, n]
                  _ -> []
                TInfo m -> [msgText m, msgServer m, msgProcedure m]
                _ -> []
            | t <- toks
            ]
      strings `shouldNotSatisfy` null
      filter hasNul strings `shouldBe` []

  describe "LOGIN7" $ do
    it "round-trips through putLogin7 and getLogin7" $ hedgehog $ do
      l7 <- forAll genLogin7
      let bytes = Put.runPut (putLogin7 l7)
      case Get.runGetOrFail getLogin7 bytes of
        Left (_, _, err) -> annotate err >> failure
        Right (rest, _, l7') -> do
          LB.null rest === True
          l7' === l7

    it "sends strings without terminators" $ do
      let l7 = defaultLogin7 { l7HostName = "host", l7AppName = "app" }
          bytes = LB.toStrict (Put.runPut (putLogin7 l7))
          slot n = Get.runGet ((,) <$> Get.getWord16le <*> Get.getWord16le)
            (LB.fromStrict (B.drop (36 + 4 * n) bytes))
      snd (slot 0) `shouldBe` 4   -- HostName, in characters
      snd (slot 3) `shouldBe` 3   -- AppName

    it "reaches the live server exactly as configured" $ do
      ci0 <- defaultTestConnectInfo
      let app = "hmssql-tests app ☃ é"
          ci = ci0 { connectApplicationName = app, connectLanguage = "British" }
      host <- T.pack <$> getHostName
      withConnection ci $ \conn -> do
        row <- query1 conn
          "SELECT APP_NAME(), HOST_NAME(), SUSER_SNAME(), DB_NAME(), @@LANGUAGE, \
          \  s.program_name, s.host_name, s.login_name, s.client_interface_name, \
          \  LEN(s.program_name), DATALENGTH(s.program_name), DATALENGTH(s.host_name) \
          \FROM sys.dm_exec_sessions s WHERE s.session_id = @@SPID"
        let (appName, hostName, login, db, lang, prog, sHost, sLogin, iface, progLen, progBytes, hostBytes) = row
        (appName :: Text) `shouldBe` app
        (hostName :: Text) `shouldBe` host
        (login :: Text) `shouldBe` connectUser ci
        (db :: Text) `shouldBe` connectDatabase ci
        (lang :: Text) `shouldBe` "British"
        (prog :: Text) `shouldBe` app
        (sHost :: Text) `shouldBe` host
        (sLogin :: Text) `shouldBe` connectUser ci
        (iface :: Text) `shouldBe` "hmssql"
        (progLen :: Int) `shouldBe` T.length app
        (progBytes :: Int) `shouldBe` 2 * T.length app
        (hostBytes :: Int) `shouldBe` 2 * T.length host
