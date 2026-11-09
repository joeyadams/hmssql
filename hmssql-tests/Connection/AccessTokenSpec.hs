-- | Logging in with an Entra ID access token, against a server that
-- accepts them (Azure SQL Database).  Needs @HMSSQL_TEST_ACCESS_TOKEN@, a
-- token for the audience @https://database.windows.net/@ (from
-- @az account get-access-token --resource https://database.windows.net/@,
-- or a managed identity); pending without it.  With
-- @HMSSQL_TEST_ACCESS_TOKEN_USER@ set, the session's login name must be it.
module Connection.AccessTokenSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Types (ServerMessage (..))
import TestConfig

withToken :: (Text -> IO ()) -> IO ()
withToken act = lookupEnv "HMSSQL_TEST_ACCESS_TOKEN" >>= \case
  Nothing -> pendingWith "HMSSQL_TEST_ACCESS_TOKEN is not set"
  Just "" -> pendingWith "HMSSQL_TEST_ACCESS_TOKEN is empty"
  Just token -> act (T.pack token)

-- | The test connection settings with the token in place of the SQL login.
tokenConnectInfo :: Encryption -> Text -> IO ConnectInfo
tokenConnectInfo enc token = do
  ci <- testConnectInfo enc
  pure ci { connectUser = "", connectPassword = "", connectAccessToken = Just token }

spec :: Spec
spec = describe "connectAccessToken (live)" $ do
  -- Strict encryption sends the PRELOGIN inside TLS that the token needs;
  -- EncryptOn negotiates TLS through PRELOGIN, the TDS 7.4 way.
  forM_ [EncryptStrict, EncryptOn] $ \enc ->
    it ("logs in as the token's identity with " ++ show enc) $ withToken $ \token -> do
      ci <- tokenConnectInfo enc token
      expected <- lookupEnv "HMSSQL_TEST_ACCESS_TOKEN_USER"
      withConnection ci $ \conn -> do
        (login, db) <- query1 conn "SELECT SUSER_SNAME(), DB_NAME()" :: IO (Text, Text)
        login `shouldNotBe` ""
        sqlUser <- T.pack . maybe "sa" id <$> lookupEnv "HMSSQL_TEST_USER"
        login `shouldNotBe` sqlUser
        forM_ expected $ \u -> login `shouldBe` T.pack u
        db `shouldBe` connectDatabase ci

  it "is rejected with LoginError when the token is corrupted" $ withToken $ \token -> do
    -- Flip a character of the signature (the last segment), keeping the
    -- token well-formed.
    let corrupted = T.init token <> (if T.last token == 'A' then "B" else "A")
    ci <- tokenConnectInfo EncryptStrict corrupted
    r <- try (withConnection ci (\_ -> pure ()))
    case r of
      Left (LoginError msg) -> msgNumber msg `shouldSatisfy` (> 0)
      Right () -> expectationFailure "logged in with a corrupted token"
