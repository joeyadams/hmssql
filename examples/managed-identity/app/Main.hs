-- | @hmssql-example-managed-identity@: log in to Azure SQL Database with an
-- Entra ID access token instead of a SQL login.
--
-- The token comes from @MSSQL_ACCESS_TOKEN@ if it is set (for instance
-- from @az account get-access-token --resource https://database.windows.net/@
-- on a developer machine), and otherwise from the managed identity endpoint
-- of the Azure host this runs on ("ManagedIdentity").  The rest of the
-- connection settings are the examples' usual @MSSQL_*@ variables
-- ("ShopDb"), with no @MSSQL_USER@ or @MSSQL_PASSWORD@.
--
-- > hmssql-example-managed-identity            # whoami: the login the server sees
-- > hmssql-example-managed-identity whoami
-- > hmssql-example-managed-identity query SQL  # run a query, print its result sets
-- > hmssql-example-managed-identity exec SQL   # run a statement, print the rows affected
--
-- @AZURE_CLIENT_ID@ selects a user-assigned identity, when the host has
-- several.
module Main (main) where

import Control.Exception (SomeException, displayException, fromException, handle, throwIO)
import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time (defaultTimeLocale, formatTime)
import Network.HTTP.Client (newManager, defaultManagerSettings)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Exit (ExitCode, exitFailure)
import System.IO (hPutStrLn, stderr)

import Hmssql
import Hmssql.Query (ResultSet (..), queryMulti)
import Hmssql.SqlValue (SqlRow (..), SqlValue (..))
import Hmssql.Types (ColumnInfo (..))
import ManagedIdentity
import ShopDb (connectInfoFromEnv)

main :: IO ()
main = handle failing $ do
  args <- getArgs
  command <- case args of
    [] -> pure whoami
    ["whoami"] -> pure whoami
    ["query", sql] -> pure (runQuery (T.pack sql))
    ["exec", sql] -> pure (runExec (T.pack sql))
    _ -> do
      hPutStrLn stderr "usage: hmssql-example-managed-identity [whoami | query SQL | exec SQL]"
      exitFailure
  ensureToken
  ci <- connectInfoFromEnv
  withConnection ci command
  where
    -- Report any failure on one line; an exit (the usage message's) passes.
    failing :: SomeException -> IO ()
    failing e = case fromException e of
      Just (code :: ExitCode) -> throwIO code
      Nothing -> hPutStrLn stderr ("hmssql-example-managed-identity: " ++ displayException e) >> exitFailure

-- | Put a token in @MSSQL_ACCESS_TOKEN@ for 'connectInfoFromEnv' if there
-- is none: from the managed identity endpoint of this host.
ensureToken :: IO ()
ensureToken = lookupEnv "MSSQL_ACCESS_TOKEN" >>= \case
  Just t | not (null t) -> hPutStrLn stderr "token: from MSSQL_ACCESS_TOKEN"
  _ -> do
    clientId <- fmap T.pack <$> lookupEnv "AZURE_CLIENT_ID"
    manager <- newManager defaultManagerSettings
    AccessToken{..} <- getAccessToken manager databaseResource clientId
    hPutStrLn stderr $ "token: from the managed identity endpoint"
      ++ maybe "" (\c -> " (client id " ++ T.unpack c ++ ")") clientId
      ++ ", expires " ++ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" tokenExpiresOn
    setEnv "MSSQL_ACCESS_TOKEN" (T.unpack accessToken)

whoami :: Connection -> IO ()
whoami conn = do
  -- (sys.dm_exec_connections would name the scheme, but reading it takes
  -- VIEW DATABASE STATE on Azure, which a db_datareader lacks.)
  (login, user, authType, db, server, edition) <- query1 conn
    "SELECT SUSER_SNAME(), USER_NAME(), \
    \(SELECT authentication_type_desc FROM sys.database_principals WHERE name = USER_NAME()), \
    \DB_NAME(), @@SERVERNAME, CAST(SERVERPROPERTY('Edition') AS nvarchar(100))"
    :: IO (Text, Text, Text, Text, Text, Text)
  T.putStrLn $ "login " <> login
  T.putStrLn $ "user " <> user <> " (authentication " <> authType <> ") in database " <> db
  T.putStrLn $ "server " <> server <> ", " <> edition

runQuery :: Text -> Connection -> IO ()
runQuery sql conn = do
  sets <- queryMulti conn (rawSql sql)
  forM_ sets $ \ResultSet{..} -> do
    T.putStrLn $ T.intercalate "\t" [if T.null columnName then "?" else columnName | ColumnInfo{..} <- resultColumns]
    forM_ resultRows $ \SqlRow{..} -> T.putStrLn $ T.intercalate "\t" (map render sqlRowValues)
    unless (null resultRows) $ putStrLn ("(" ++ show (length resultRows) ++ " rows)")
  where
    render = \case
      SqlNull -> "NULL"
      SqlText t -> t
      SqlBool b -> if b then "1" else "0"
      v -> T.pack (fromMaybe (show v) (stripConstructor (show v)))
    -- "SqlInt32 5" -> "5"
    stripConstructor s = case break (== ' ') s of
      ('S' : 'q' : 'l' : _, ' ' : rest) -> Just rest
      _ -> Nothing

runExec :: Text -> Connection -> IO ()
runExec sql conn = do
  n <- execute conn (rawSql sql)
  putStrLn ("(" ++ show n ++ " rows affected)")
