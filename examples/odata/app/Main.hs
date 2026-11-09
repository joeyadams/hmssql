-- | @hmssql-example-odata@: a read-only OData service over the shop
-- database, streaming its results.
--
-- Connection settings come from the @MSSQL_*@ variables (see "ShopDb"),
-- plus:
--
-- > ODATA_PORT     the port to listen on (default 8080)
-- > ODATA_LOG_SQL  1 logs each statement's SQL text to stderr
module Main (main) where

import Control.Exception
import Data.Pool (defaultPoolConfig, newPool, setNumStripes, withResource)
import qualified Data.Text as T
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setBeforeMainLoop, setOnException, setPort)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

import Hmssql
import OData.Model
import OData.Server
import ShopDb (connectInfoFromEnv)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  info <- connectInfoFromEnv `catch` \(e :: IOException) ->
    die ("configuration: " ++ displayException e ++ "\nSet MSSQL_PASSWORD and the other MSSQL_* variables (see ShopDb).")
  -- Four MARS connections, opened on demand and closed after 60 idle
  -- seconds, in one stripe so that every capability shares them.  A
  -- request with $expand keeps a stream open per level on the one
  -- connection it borrowed, which only a MARS connection allows.
  let mars = info { connectMars = True, connectApplicationName = "hmssql-example-odata" }
  pool <- newPool (setNumStripes (Just 1) (defaultPoolConfig (connect mars) close 60 4))

  -- The first checkout opens the first connection, so a server that can't
  -- be reached, or a login that fails, shows up here.
  model <- withResource pool loadModel `catch` \(e :: SomeException) ->
    die ("could not read the schema from SQL Server: " ++ displayException e)
  if null model
    then die "no tables to serve (is the database set up? run hmssql-example-setup)"
    else mapM_ describe model

  -- A snapshot transaction fails on a database without
  -- ALLOW_SNAPSHOT_ISOLATION, so check once rather than per request.
  snapshot <- withResource pool $ \conn -> do
    Only state <- query1 conn "SELECT CAST(snapshot_isolation_state AS int) FROM sys.databases WHERE database_id = DB_ID()"
    pure (state == (1 :: Int))
  if snapshot
    then putStrLn "$expand requests run in snapshot transactions"
    else putStrLn "warning: ALLOW_SNAPSHOT_ISOLATION is off for the database (hmssql-example-setup turns it on), \
                  \so the statements of an $expand request may read different states of the database"

  port <- lookupEnv "ODATA_PORT" >>= \case
    Nothing -> pure 8080
    Just s -> maybe (die ("ODATA_PORT is not a port number: " ++ s)) pure (readMaybe s)
  logSql <- (== Just "1") <$> lookupEnv "ODATA_LOG_SQL"
  let settings = setPort port
        $ setOnException onWarpException
        $ setBeforeMainLoop (putStrLn ("listening on http://localhost:" ++ show port ++ "/")) defaultSettings
  runSettings settings (app Env { pool, model, snapshot, logSql })
  where
    describe :: EntitySet -> IO ()
    describe set = putStrLn $ T.unpack $
      set.setName <> " (" <> T.pack (show (length set.columns)) <> " properties"
        <> (if null set.keyColumns then "" else ", key " <> T.intercalate ", " set.keyColumns)
        <> (if null set.navigations then "" else ", expands " <> T.intercalate ", " (map (.navName) set.navigations))
        <> ")"
