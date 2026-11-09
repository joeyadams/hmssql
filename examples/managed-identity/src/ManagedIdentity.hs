-- | An access token from Azure Managed Identity, for the code running on an
-- Azure host that has one: a VM, a container instance, a container app, a
-- function app, a web app.  The host runs a token endpoint on a local
-- address; this asks it, with plain HTTP, for a token for a resource.
--
-- Two endpoints exist.  App Service, Functions and Container Apps set
-- @IDENTITY_ENDPOINT@ and @IDENTITY_HEADER@ in the environment; VMs, VM
-- scale sets and Container Instances have the Instance Metadata Service at
-- @169.254.169.254@.  Both answer JSON with @access_token@ and
-- @expires_on@.  See
-- <https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token>.
module ManagedIdentity
  ( AccessToken (..)
  , getAccessToken
  , databaseResource
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client
import Network.HTTP.Types (statusCode, statusMessage)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | The resource (audience) of a token for Azure SQL.
databaseResource :: Text
databaseResource = "https://database.windows.net/"

data AccessToken = AccessToken
  { accessToken :: !Text
  , tokenExpiresOn :: !UTCTime
  }

-- | A token for the resource, from whichever endpoint this host has.  The
-- client id selects one of several user-assigned identities; @Nothing@
-- takes the system-assigned identity, or the only user-assigned one.
--
-- Throws an 'IOError' when neither endpoint answers with a token.  A host
-- without a managed identity has no endpoint: the IMDS request then fails
-- with a timeout (the address is link-local and nothing routes it), which
-- takes a while.
getAccessToken :: Manager -> Text -> Maybe Text -> IO AccessToken
getAccessToken manager resource clientId = do
  endpoint <- lookupEnv "IDENTITY_ENDPOINT"
  header <- lookupEnv "IDENTITY_HEADER"
  let (url, apiVersion, headers) = case (endpoint, header) of
        (Just e, Just secret) -> (e, "2019-08-01", [("X-IDENTITY-HEADER", BC.pack secret)])
        _ -> ("http://169.254.169.254/metadata/identity/oauth2/token", "2018-02-01", [("Metadata", "true")])
  req0 <- parseRequest url
  let req = setQueryString
        ([("api-version", Just apiVersion), ("resource", Just (T.encodeUtf8 resource))]
          ++ [("client_id", Just (T.encodeUtf8 c)) | Just c <- [clientId]])
        req0 { requestHeaders = headers, responseTimeout = responseTimeoutMicro 10000000 }
  resp <- httpLbs req manager
  let status = responseStatus resp
  unless (statusCode status == 200) $
    throwIO $ userError $ "the managed identity endpoint answered " ++ show (statusCode status) ++ " "
      ++ BC.unpack (statusMessage status) ++ ": " ++ take 500 (show (responseBody resp))
  either (throwIO . userError . ("the managed identity endpoint's answer: " ++)) pure $
    Aeson.eitherDecode (responseBody resp) >>= Aeson.parseEither parseToken
  where
    parseToken :: Aeson.Value -> Aeson.Parser AccessToken
    parseToken = Aeson.withObject "token" $ \o -> do
      token <- o Aeson..: "access_token"
      -- expires_on is Unix time, as a string on both endpoints (and a number
      -- in some older API versions).
      expiresOn <- o Aeson..: "expires_on"
      seconds <- case expiresOn of
        Aeson.String str -> maybe (fail "expires_on is not a number") pure (readMaybe (T.unpack str))
        Aeson.Number n -> pure (realToFrac n :: Double)
        _ -> fail "expires_on is neither a string nor a number"
      pure AccessToken { accessToken = token, tokenExpiresOn = posixSecondsToUTCTime (realToFrac seconds) }
