-- | The example shop database: where it is, and how to (re)create it.
--
-- Connection settings come from the environment, so the same binary runs
-- against a local SQL Server in Docker or Azure SQL Database:
--
-- > MSSQL_HOST               localhost
-- > MSSQL_PORT               1433
-- > MSSQL_USER               sa
-- > MSSQL_PASSWORD           (required, unless MSSQL_ACCESS_TOKEN is set)
-- > MSSQL_ACCESS_TOKEN       an Entra ID access token, in place of the user and password
-- > MSSQL_DATABASE           hmssql_example
-- > MSSQL_ENCRYPT            on | off | strict        (default on, TDS 7.4)
-- > MSSQL_SERVER_NAME        optional login server-name override (defaults to MSSQL_HOST)
-- > MSSQL_CA_CERT            a PEM file to trust in addition to the system store
-- > MSSQL_TRUST_SERVER_CERT  1 skips certificate validation (development only)
--
-- 'connectInfoFromEnvPrefixed' reads the same variables under a prefix
-- first (@SOURCE_MSSQL_HOST@, then @MSSQL_HOST@), for a program with two
-- connections.
module ShopDb
  ( connectInfoFromEnv
  , connectInfoFromEnvPrefixed
  , databaseName
  , withShopConnection
  , setupDatabase
  , runSqlFile
  , sqlBatches
  ) where

import Control.Monad (forM_, mfilter, unless)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text (Text)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

import Hmssql
import Paths_hmssql_example_shop_db (getDataFileName)

-- | The database the examples use (@MSSQL_DATABASE@).
databaseName :: IO Text
databaseName = maybe "hmssql_example" T.pack <$> lookupEnv "MSSQL_DATABASE"

-- | The connection settings from the environment; see "ShopDb".
connectInfoFromEnv :: IO ConnectInfo
connectInfoFromEnv = connectInfoFromEnvPrefixed ""

-- | 'connectInfoFromEnv', each variable looked up with the prefix first
-- and then without it: with the prefix @TARGET_@, @TARGET_MSSQL_HOST@ if it is
-- set, else @MSSQL_HOST@.
connectInfoFromEnvPrefixed :: String -> IO ConnectInfo
connectInfoFromEnvPrefixed prefix = do
  host <- fromEnvT "MSSQL_HOST" "localhost"
  port <- fromEnvT "MSSQL_PORT" "1433"
  token <- mfilter (not . null) <$> lookupEnv' "MSSQL_ACCESS_TOKEN"
  -- With a token, the user and password stay empty (hmssql refuses both).
  user <- maybe (fromEnvT "MSSQL_USER" "sa") (const (pure "")) token
  password <- case token of
    Just _ -> pure ""
    Nothing -> lookupEnv' "MSSQL_PASSWORD" >>= maybe (fail (orPrefixed "MSSQL_PASSWORD" ++ " (or MSSQL_ACCESS_TOKEN) is not set")) pure
  database <- fromEnvT "MSSQL_DATABASE" "hmssql_example"
  encrypt <- fromEnv "MSSQL_ENCRYPT" "on" >>= \case
    "strict" -> pure EncryptStrict
    "on" -> pure EncryptOn
    "off" -> pure EncryptOff
    other -> fail (orPrefixed "MSSQL_ENCRYPT" ++ " must be strict, on or off, not " ++ show other)
  serverName <- fromEnvT "MSSQL_SERVER_NAME" ""
  caCert <- mfilter (not . null) <$> lookupEnv' "MSSQL_CA_CERT"
  trust <- (`elem` [Just "1", Just "true", Just "yes"]) <$> lookupEnv' "MSSQL_TRUST_SERVER_CERT"
  pure defaultConnectInfo
    { connectHost = host
    , connectPort = port
    , connectUser = user
    , connectPassword = T.pack password
    , connectAccessToken = T.pack <$> token
    , connectDatabase = database
    , connectEncryption = encrypt
    , connectServerName = serverName
    , connectApplicationName = "hmssql-example"
    , connectTls = defaultTlsSettings
        { tlsCaCertificateFiles = maybe [] pure caCert
        , tlsTrustServerCertificate = trust
        }
    }
  where
    fromEnv name def = maybe def id <$> lookupEnv' name
    fromEnvT name def = maybe def T.pack <$> lookupEnv' name
    lookupEnv' name
      | null prefix = lookupEnv name
      | otherwise = lookupEnv (prefix ++ name) >>= maybe (lookupEnv name) (pure . Just)
    orPrefixed name
      | null prefix = name
      | otherwise = prefix ++ name ++ " (or " ++ name ++ ")"

-- | Run an action with a connection to the shop database.
withShopConnection :: (Connection -> IO a) -> IO a
withShopConnection body = connectInfoFromEnv >>= \info -> withConnection info body

-- | Create the database if it doesn't exist, turn on
-- @ALLOW_SNAPSHOT_ISOLATION@ (the odata example and crud's export read in
-- snapshot transactions), then run @schema.sql@ (which drops
-- and recreates every object) and @seed.sql@.
setupDatabase :: IO ()
setupDatabase = do
  info <- connectInfoFromEnv
  db <- databaseName
  withConnection info { connectDatabase = "master" } $ \conn -> do
    existing <- query conn ("SELECT COUNT(*) FROM sys.databases WHERE name = " <> param db)
    unless (existing == [Only (1 :: Int)]) $ do
      hPutStrLn stderr ("creating database " ++ T.unpack db)
      -- A database name can't be a parameter; this one comes from the
      -- environment, not from a user, and is quoted as an identifier.
      _ <- execute conn ("CREATE DATABASE " <> escapeIdentifier db)
      pure ()
    Only state <- query1 conn ("SELECT CAST(snapshot_isolation_state AS int) FROM sys.databases WHERE name = " <> param db)
    unless (state == (1 :: Int)) $ do
      hPutStrLn stderr "turning on ALLOW_SNAPSHOT_ISOLATION"
      _ <- execute conn ("ALTER DATABASE " <> escapeIdentifier db <> " SET ALLOW_SNAPSHOT_ISOLATION ON")
      pure ()
  withConnection info $ \conn -> do
    forM_ ["sql/schema.sql", "sql/seed.sql"] $ \name -> do
      path <- getDataFileName name
      hPutStrLn stderr ("running " ++ name)
      runSqlFile conn path
  hPutStrLn stderr "done"

-- | Run every batch of a script, in order.
runSqlFile :: Connection -> FilePath -> IO ()
runSqlFile conn path = do
  script <- T.readFile path
  forM_ (sqlBatches script) $ \batch -> execute conn (rawSql batch)

-- | Split a script on @GO@ lines, as sqlcmd does, dropping empty batches.
sqlBatches :: Text -> [Text]
sqlBatches = filter (not . T.null . T.strip) . map T.unlines . splitOnGo . T.lines
  where
    splitOnGo ls = case break isGo ls of
      (batch, []) -> [batch]
      (batch, _ : rest) -> batch : splitOnGo rest
    isGo l = T.toUpper (T.strip l) == "GO"
