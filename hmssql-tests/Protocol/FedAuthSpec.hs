-- | Federated authentication with an access token ('connectAccessToken'):
-- what goes on the wire, checked against the mock server (TDS 7.4; the
-- strict-encryption path is covered live, "Connection.AccessTokenSpec").
module Protocol.FedAuthSpec (spec) where

import Control.Exception (throwIO, try)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client
import MockServer

token :: Text
token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.e30.signature"

-- | The expected FEDAUTH feature data: options, then the token with a
-- 32-bit byte length, then the nonce if any.
fedAuthData :: Bool -> Maybe B.ByteString -> B.ByteString
fedAuthData echo nonce = LB.toStrict $ Put.runPut $ do
  Put.putWord8 (if echo then 0x03 else 0x02)
  let bytes = T.encodeUtf16LE token
  Put.putWord32le (fromIntegral (B.length bytes))
  Put.putByteString bytes
  mapM_ Put.putByteString nonce

-- | Answer PRELOGIN with the given extra options, serve the login, and
-- report what the client sent in both.
serveWith :: [PreloginOption] -> MockConn -> IO (Prelogin, Login7)
serveWith extra mc = do
  let Prelogin base = preloginReply (encryptionWord EncryptNotSup)
  p <- respondPrelogin (Prelogin (base ++ extra)) mc
  l7 <- expectLogin7 mc
  sendTokens mc defaultLoginResponse
  serveRequests (\_ _ -> pure [doneToken 0 0]) mc
  pure (p, l7)

-- | What the handler saw, or its failure.
served :: MockServer r -> IO r
served srv = nextResult srv >>= either throwIO pure

tokenConnectInfo :: MockServer r -> ConnectInfo
tokenConnectInfo srv = (mockConnectInfo srv)
  { connectUser = "", connectPassword = "", connectAccessToken = Just token }

spec :: Spec
spec = describe "connectAccessToken" $ do
  it "sends FEDAUTHREQUIRED = 1 in PRELOGIN, and the token in a FEDAUTH feature echoing the server's 1" $
    withMockServer (serveWith [PLFedAuthRequired 1]) $ \srv -> do
      withConnection (tokenConnectInfo srv) $ \conn -> execute conn "SELECT 1" >> pure ()
      (Prelogin sent, l7) <- served srv
      sent `shouldContain` [PLFedAuthRequired 1]
      l7UserName l7 `shouldBe` ""
      l7Password l7 `shouldBe` ""
      [featureData f | f <- l7Features l7, featureId f == 0x02] `shouldBe` [fedAuthData True Nothing]
      l7Features l7 `shouldContain` [featureUtf8Support]

  it "echoes 0 when the server answers FEDAUTHREQUIRED = 0, or doesn't answer it" $ do
    let echoFor extra = withMockServer (serveWith extra) $ \srv -> do
          withConnection (tokenConnectInfo srv) $ \_ -> pure ()
          (_, l7) <- served srv
          pure [featureData f | f <- l7Features l7, featureId f == 0x02]
    echoFor [PLFedAuthRequired 0] `shouldReturn` [fedAuthData False Nothing]
    echoFor [] `shouldReturn` [fedAuthData False Nothing]

  it "echoes a nonce the server sends" $ do
    let nonce = B.pack [1 .. 32]
    withMockServer (serveWith [PLFedAuthRequired 1, PLNonce nonce]) $ \srv -> do
      withConnection (tokenConnectInfo srv) $ \_ -> pure ()
      (_, l7) <- served srv
      [featureData f | f <- l7Features l7, featureId f == 0x02] `shouldBe` [fedAuthData True (Just nonce)]

  it "sends no FEDAUTHREQUIRED and no FEDAUTH feature without a token" $
    withMockServer (serveWith [PLFedAuthRequired 1]) $ \srv -> do
      withConnection (mockConnectInfo srv) $ \_ -> pure ()
      (Prelogin sent, l7) <- served srv
      [f | PLFedAuthRequired f <- sent] `shouldBe` []
      [f | f <- l7Features l7, featureId f == 0x02] `shouldBe` []
      l7UserName l7 `shouldBe` "mockuser"

  describe "is refused before a socket is opened" $ do
    -- Port 1 has no listener; a connection attempt would fail differently.
    let unreachable = defaultConnectInfo { connectHost = "127.0.0.1", connectPort = "1" }
        refused ci = try (withConnection ci (\_ -> pure ())) >>= \case
          Left (EncodeError msg) -> pure msg
          Right () -> fail "connected"

    it "when a user or password is set as well" $ do
      msg <- refused unreachable { connectUser = "me", connectAccessToken = Just token }
      msg `shouldSatisfy` ("connectAccessToken" `isInfixOf`)
      msg' <- refused unreachable { connectPassword = "pw", connectAccessToken = Just token }
      msg' `shouldSatisfy` ("connectAccessToken" `isInfixOf`)

    it "when the token is empty" $ do
      msg <- refused unreachable { connectAccessToken = Just "" }
      msg `shouldSatisfy` ("empty" `isInfixOf`)

  it "is not in the Show of the feature or the LOGIN7" $ do
    let f = featureFedAuthToken True token Nothing
    show f `shouldNotContain` "eyJ0"
    show f `shouldContain` "<redacted>"
    show defaultLogin7 { l7Features = [f] } `shouldNotContain` "eyJ0"
    show (Feature 0x0A "\1") `shouldBe` "Feature {featureId = 10, featureData = \"\\SOH\"}"
