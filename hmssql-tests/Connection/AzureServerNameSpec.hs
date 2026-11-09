-- | Opt-in Azure routing checks. Each address-family test resolves and uses
-- that family's native addresses; IPv4-mapped IPv6 is not IPv6 coverage.
-- Set HMSSQL_TEST_AZURE_SERVER_NAME=1 with the usual Azure test settings.
module Connection.AzureServerNameSpec (spec) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (forM_, unless)
import Data.Int (Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Network.Socket as Socket
import System.Environment (lookupEnv)
import Test.Hspec

import Compat (timeoutInSlices)
import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Context (TdsVersion (..), tdsVersionWord)
import TestConfig
import TestDb (serial)

requireProbe :: IO ()
requireProbe = do
  enabled <- lookupEnv "HMSSQL_TEST_AZURE_SERVER_NAME"
  unless (enabled == Just "1") $
    pendingWith "set HMSSQL_TEST_AZURE_SERVER_NAME=1 to run the Azure hostname and native IPv4/IPv6 routing matrix"
  azure <- testServerIsAzure
  unless azure $ pendingWith "requires Azure SQL Database"

settings :: Encryption -> IO ConnectInfo
settings enc = do
  ci <- testConnectInfo enc
  -- Keep certificate validation independent of LOGIN7 routing. For IP
  -- connections the certificate still identifies the configured DNS name.
  pure ci
    { connectProtocol = ProtocolTcp
    , connectMars = False
    , connectServerName = ""
    , connectTls = defaultTlsSettings
        { tlsHostNameInCertificate = Just (connectHost ci) }
    }

names :: ConnectInfo -> [(String, Text)]
names ci = [("omitted", ""), ("short name", short), ("full hostname", host)]
  where
    host = connectHost ci
    short = T.takeWhile (/= '.') host

observe :: ConnectInfo -> IO (Int64, Text, Text)
observe ci = do
  result <- timeoutInSlices 30_000_000 $ withConnection ci $ \conn ->
    query1 conn
      "SELECT CAST(protocol_version AS bigint), CAST(encrypt_option AS nvarchar(10)), DB_NAME() \
      \FROM sys.dm_exec_connections WHERE session_id = @@SPID AND parent_connection_id IS NULL"
  maybe (fail "Azure connection/query timed out after 30 seconds") pure result

succeeds :: ConnectInfo -> Expectation
succeeds ci = do
  (version, encrypted, database) <- observe ci
  let expected = if connectEncryption ci == EncryptStrict then Tds80 else Tds74
  version `shouldBe` fromIntegral (tdsVersionWord expected)
  encrypted `shouldBe` "TRUE"
  database `shouldBe` connectDatabase ci
  putStrLn "    connected; expected protocol, encryption and database confirmed"

refused :: ConnectInfo -> Expectation
refused ci = do
  result <- try (observe ci)
  case result of
    Left (e :: LoginError) -> do
      putStrLn ("    Azure rejected the login with " ++ show (loginErrorNumber e))
      loginErrorNumber e `shouldBe` 40532
    Right _ -> expectationFailure "Azure accepted a login with the wrong logical server name"

nativeAddresses :: Socket.Family -> Text -> IO [Text]
nativeAddresses family host = do
  result <- try $ do
    let hints = Socket.defaultHints
          { Socket.addrFamily = family, Socket.addrSocketType = Socket.Stream
          , Socket.addrFlags = [] }
    resolved <- Socket.getAddrInfo (Just hints) (Just (T.unpack host)) (Just "1433")
    traverse (\info -> do
      (numeric, _) <- Socket.getNameInfo [Socket.NI_NUMERICHOST] True False (Socket.addrAddress info)
      maybe (fail "resolver returned no numeric address") (pure . T.pack) numeric) resolved
  case result of
    Left (e :: IOException) -> fail (show family ++ " resolution unavailable: " ++ displayException e)
    Right addresses -> do
      let native = nub $ filter (\address -> family /= Socket.AF_INET6 ||
            (T.any (== ':') address && not ("::ffff:" `T.isPrefixOf` T.toLower address))) addresses
      unless (not (null native)) $ fail
        (show family ++ " has no native address for the Azure hostname; resolver returned " ++ show addresses ++
          ". IPv4-mapped addresses do not test IPv6 connectivity.")
      pure native

spec :: Spec
spec = serial $ before_ requireProbe $ describe "Azure LOGIN7 server-name routing" $ do
  forM_ [EncryptOn, EncryptStrict] $ \enc -> describe (show enc) $ do
    forM_ [0, 1, 2] $ \index ->
      it (["accepts an omitted name", "accepts the short name", "accepts the full hostname"] !! index) $ do
        ci <- settings enc
        let (_, name) = names ci !! index
        succeeds ci { connectServerName = name }
    forM_ [False, True] $ \qualified ->
      it ("rejects a bogus " ++ if qualified then "full hostname" else "short name") $ do
        ci <- settings enc
        let host = connectHost ci
            (short, suffix) = T.breakOn "." host
            bogus = short <> "2" <> if qualified then suffix else ""
        refused ci { connectServerName = bogus }

  forM_ [("IPv4", Socket.AF_INET), ("IPv6", Socket.AF_INET6)] $ \(label, family) ->
    it (label ++ ": resolves native addresses and checks omitted, short and full login names") $ do
      base <- settings EncryptOn
      addresses <- nativeAddresses family (connectHost base)
      forM_ addresses $ \address -> forM_ [EncryptOn, EncryptStrict] $ \enc -> do
        ci <- settings enc
        forM_ (names ci) $ \(label, name) -> do
          putStrLn ("    " ++ T.unpack address ++ " / " ++ show enc ++ " / " ++ label)
          let byAddress = ci { connectHost = address, connectServerName = name }
          if T.null name then refused byAddress else succeeds byAddress
