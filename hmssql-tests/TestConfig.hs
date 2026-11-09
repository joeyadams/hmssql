-- | Connection settings for the DB-backed tests, configured via environment.
-- @HMSSQL_TEST_PASSWORD@ has no default: without it, anything that would
-- connect to the server throws 'NoTestServer', and "SpecHook" reports such
-- tests as pending (unless @HMSSQL_TEST_REQUIRE_SERVER=1@), so the suite
-- passes without a server.  Everything else has a default.
--
-- Three variables adapt the suite to a server that is not the local Docker
-- one: @HMSSQL_TEST_TLS_HOSTNAME@ ('testTlsHostName'), the name the server
-- certificate is validated against, @HMSSQL_TEST_SERVER_NAME@
-- ('testServerName'), the server name Azure SQL needs in LOGIN7, and
-- @HMSSQL_TEST_CREATE_DATABASE_OPTIONS@ ('createDatabaseSql'), options for
-- every database the suite creates.
--
-- Six variables change the connection most tests use, to run the suite
-- over other code paths:
--
-- * @HMSSQL_TEST_PROTOCOL@ (@auto@, the default, @tcp@, @lpc@ or @np@):
--   what every test connection to the server travels on ('testProtocol'):
--   'ProtocolAuto', TCP, Shared Memory or Named Pipes.  The last two exist
--   on Windows only.  A run names the one it covered, since @auto@ picks
--   by what the server has enabled.  Connections to "MockServer" are not
--   affected.
-- * @HMSSQL_TEST_ENCRYPTION@ (@strict@, @on@, @req@, @off@ or @notsup@):
--   the encryption of 'withTestDb', 'defaultTestConnectInfo',
--   'companionConnectInfo' and 'masterConnectInfo' (so also
--   'withScratchDatabase').  The default is @strict@, or @on@ against a
--   SQL Server before 2025 ('defaultTestEncryption').  Tests that pass an
--   'Encryption' explicitly keep it.
-- * @HMSSQL_TEST_PACKET_SIZE@: the packet size to ask for (default 8000,
--   'defaultConnectInfo''s),
--   for every test connection.  Tests that set 'connectPacketSize' keep it.
-- * @HMSSQL_TEST_SESSION_SETUP@ (@default@ or @arithabort@): the session
--   setup of every test connection, unless the test sets it:
--   'testSessionSetup', @[]@ ('defaultSessionSetup', what applications get)
--   by default, where a reset rides on the next request; @arithabort@ gives
--   @[\"SET ARITHABORT ON\"]@ (the opt-in 'defaultSessionSetup' documents),
--   so that the suite runs the setup batch at connect and after each reset.
-- * @HMSSQL_TEST_MARS@ (@1@): every test connection has 'connectMars' set,
--   unless the test sets it, so that the suite runs over SMP sessions
--   ('testMars').  A test of what a request does to an open response
--   without MARS asks for a connection without it.
-- * @HMSSQL_TEST_MARS_WINDOW@: the 'connectMarsWindow' of every test
--   connection (default 64, 'defaultConnectInfo''s), unless the test sets
--   it ('testMarsWindow'): with @HMSSQL_TEST_MARS=1@ and a small window,
--   a response is held back at a few packets, and with small packets at a
--   few rows.
--
-- "SpecHook" creates the shared test database ('testDatabaseName', default
-- @hmssql_test@) and the companion database ('testCompanionDatabaseName',
-- default @hmssql_test_companion@) before any test runs, if they don't
-- exist yet; otherwise the first call to 'testConnectInfo' or
-- 'companionConnectInfo' (or anything built on them) does.  Both are kept.
-- Tests that never connect (e.g. @--match Wire@, or those against
-- "MockServer") need no server.
--
-- @HMSSQL_TEST_ACCESS_TOKEN@ (and @HMSSQL_TEST_ACCESS_TOKEN_USER@) serve
-- "Connection.AccessTokenSpec" alone: an Entra ID token for the server, and
-- the login it must show.
--
-- @HMSSQL_TEST_SQL_VERSION@ (@2025@, the default, @2022@, @2019@ or @2017@)
-- says which SQL Server the suite runs against ('testSqlVersion').  With
-- @2022@ or earlier, the tests of what SQL Server 2025 added (the @json@ and
-- @vector@ types, 'skipBeforeSql2025') are pending, and so is every test
-- connection with 'EncryptStrict' ('baseConnectInfo'): the Linux build of
-- SQL Server 2022 has no strict encryption (error 17821), and SQL Server
-- 2019 and 2017 have no TDS 8.0 at all.  The default test connection then
-- uses 'EncryptOn'.  With @2019@ or @2017@, the tests of what SQL Server
-- 2022 added ('skipBeforeSql2022') are pending as well.
--
-- Two facts about the server, asked once per process, let tests adapt to
-- one that is not SQL Server on this machine: 'testServerIsAzure' (Azure
-- SQL Database: no @USE@, no cross-database references, no @sysadmin@, a
-- reset puts the isolation level back, ...) and
-- 'testServerRequiresEncryption' (no plaintext connections; Azure, or any
-- SQL Server with Force Encryption).  'testHostIsLoopback' says whether the
-- server is on this machine.
module TestConfig
  ( testConnectInfo
  , defaultTestConnectInfo
  , withTestConnection
  , withTestDb
  , withTestDbWith
    -- * The configured defaults
  , testEncryption
  , defaultTestEncryption
  , testProtocol
  , testProtocolName
  , testPacketSize
  , testSessionSetup
  , testMars
  , testMarsWindow
  , testSessionSetupArithabort
  , testConfigIsDefault
  , testCertFile
  , testTlsHostName
  , testTrustServerCertificate
  , testServerName
  , testDatabaseName
  , testCompanionDatabaseName
  , testHost
  , testHostIsLoopback
  , testSqlVersion
  , strictEncryptionPending
  , masterConnectInfo
  , companionConnectInfo
  , withDdlLock
  , ensureTestDatabase
  , ensureCompanionDatabase
  , createDatabaseSql
  , createDatabaseOptions
  , databaseExists
  , retryModelLock
  , retryDeadlock
  , quoteName
    -- * Killing a session
  , SessionIdentity (..)
  , sessionIdentity
  , killSession
  , killSessionFrom
  , awaitWaitfor
  , describeSession
  , describeServer
    -- * Facts about the server
  , testNetTransport
  , testServerIsAzure
  , testServerOnWindows
  , testServerRequiresEncryption
    -- * No server
  , NoTestServer (..)
  , noTestServerMessage
  , testServerConfigured
  , testServerRequired
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (Exception (..), SomeException, bracket, throwIO, try)
import Control.Monad (unless, void, when)
import Data.List (intercalate, isInfixOf)
import Data.Maybe (fromMaybe, isJust, maybeToList)
import Data.Char (toLower)
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Int (Int32)
import Data.Word (Word32)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.Timeout (timeout)
import System.IO.Unsafe (unsafePerformIO)

import Test.Hspec (pendingWith)

import Hmssql

import Hmssql.Errors
-- | A PEM file to trust in addition to the system store, e.g. a local
-- server's self-signed certificate.
testCertFile :: IO (Maybe FilePath)
testCertFile = lookupEnv "HMSSQL_TEST_CERT"

-- | Opt in to trusting the live test server's certificate, e.g. SQL
-- Server's generated certificate on a local development instance. This
-- affects only the live test settings, not the library or mock servers.
testTrustServerCertificate :: IO Bool
testTrustServerCertificate = lookupEnv "HMSSQL_TEST_TRUST_SERVER_CERTIFICATE" >>= \case
  Nothing -> pure False
  Just "0" -> pure False
  Just "1" -> pure True
  Just v -> fail ("HMSSQL_TEST_TRUST_SERVER_CERTIFICATE: expected 0 or 1, not " ++ show v)

-- | The name to validate the server certificate against
-- (@HMSSQL_TEST_TLS_HOSTNAME@): @localhost@ by default, which the local test
-- server's certificate is issued for.  Set it to the name in the server's
-- certificate (for Azure SQL, the server's fully qualified domain name), or
-- to the empty string to validate against @HMSSQL_TEST_HOST@ itself.
testTlsHostName :: IO (Maybe Text)
testTlsHostName = lookupEnv "HMSSQL_TEST_TLS_HOSTNAME" <&> \case
  Nothing -> Just "localhost"
  Just "" -> Nothing
  Just h -> Just (T.pack h)

-- | What to send as the server name in LOGIN7 (@HMSSQL_TEST_SERVER_NAME@,
-- 'connectServerName'): empty by default; Azure SQL requires the first DNS
-- label of the server's name, or the login fails with error 40531.
testServerName :: IO Text
testServerName = maybe "" T.pack <$> lookupEnv "HMSSQL_TEST_SERVER_NAME"

-- | The shared test database (@HMSSQL_TEST_DATABASE@, default @hmssql_test@).
testDatabaseName :: IO Text
testDatabaseName = maybe "hmssql_test" T.pack <$> lookupEnv "HMSSQL_TEST_DATABASE"

-- | The companion database (@HMSSQL_TEST_COMPANION_DATABASE@, default the
-- shared test database's name followed by @_companion@): a second database,
-- kept like the shared one, for tests that need a database besides the
-- current one (@USE@, three-part names) or one that allows SNAPSHOT
-- isolation ('companionConnectInfo').
testCompanionDatabaseName :: IO Text
testCompanionDatabaseName = lookupEnv "HMSSQL_TEST_COMPANION_DATABASE" >>= \case
  Just n | not (null n) -> pure (T.pack n)
  _ -> (<> "_companion") <$> testDatabaseName

-- | The server's host (@HMSSQL_TEST_HOST@, default @::1@).
testHost :: IO Text
testHost = maybe "::1" T.pack <$> lookupEnv "HMSSQL_TEST_HOST"

-- | Whether the server is on this machine: 'testHost' is a loopback address.
testHostIsLoopback :: IO Bool
testHostIsLoopback = (`elem` ["localhost", "127.0.0.1", "::1", "ip6-localhost"]) <$> testHost

-- | The SQL Server version the suite runs against (@HMSSQL_TEST_SQL_VERSION@,
-- @2017@, @2019@, @2022@ or @2025@, default 2025).
testSqlVersion :: IO Int
testSqlVersion = lookupEnv "HMSSQL_TEST_SQL_VERSION" >>= \case
  Nothing -> pure 2025
  Just "" -> pure 2025
  Just "2017" -> pure 2017
  Just "2019" -> pure 2019
  Just "2022" -> pure 2022
  Just "2025" -> pure 2025
  Just v -> fail ("HMSSQL_TEST_SQL_VERSION: expected 2017, 2019, 2022 or 2025, not " ++ show v)

-- | Why a test that connects with 'EncryptStrict' can't run here, if it
-- can't.  SQL Server 2019 and 2017 have no TDS 8.0: 2019 closes the
-- connection at the TLS ClientHello (error 17832 in its log).  The Linux build of SQL Server
-- 2022 refuses strict encryption (error 17821), and
-- @HMSSQL_TEST_SQL_VERSION=2022@ assumes that build.
strictEncryptionPending :: IO (Maybe String)
strictEncryptionPending = lookupEnv "HMSSQL_TEST_STRICT_ENCRYPTION" >>= \case
  Just "0" -> pure (Just "live server has no strict encryption (HMSSQL_TEST_STRICT_ENCRYPTION=0)")
  Just "1" -> pure Nothing
  Nothing -> testSqlVersion <&> \case
    v | v < 2022 -> Just ("SQL Server " ++ show v ++ " has no strict encryption (HMSSQL_TEST_SQL_VERSION=" ++ show v ++ ")")
    v | v < 2025 -> Just "SQL Server 2022 on Linux has no strict encryption (HMSSQL_TEST_SQL_VERSION=2022)"
    _ -> Nothing
  Just v -> fail ("HMSSQL_TEST_STRICT_ENCRYPTION: expected 0 or 1, not " ++ show v)

-- | The encryption of the default test connection when
-- @HMSSQL_TEST_ENCRYPTION@ doesn't say: 'EncryptStrict', or 'EncryptOn'
-- against a server that has no strict encryption
-- ('strictEncryptionPending'), so that @HMSSQL_TEST_SQL_VERSION@ alone is
-- enough to run the suite against it.
defaultTestEncryption :: IO Encryption
defaultTestEncryption = strictEncryptionPending <&> maybe EncryptStrict (const EncryptOn)

-- | The encryption of the default test connection (@HMSSQL_TEST_ENCRYPTION@,
-- default 'defaultTestEncryption').
testEncryption :: IO Encryption
testEncryption = lookupEnv "HMSSQL_TEST_ENCRYPTION" >>= \case
  Nothing -> defaultTestEncryption
  Just v -> case map toLower v of
    "" -> defaultTestEncryption
    "strict" -> pure EncryptStrict
    "on" -> pure EncryptOn
    "req" -> pure EncryptReq
    "off" -> pure EncryptOff
    "notsup" -> pure EncryptNotSup
    _ -> fail ("HMSSQL_TEST_ENCRYPTION: expected strict, on, req, off or notsup, not " ++ show v)

-- | What test connections travel on (@HMSSQL_TEST_PROTOCOL@), by its short
-- name: @auto@ (the default), @tcp@, @lpc@ (Shared Memory) or @np@ (Named
-- Pipes).
testProtocolName :: IO String
testProtocolName = lookupEnv "HMSSQL_TEST_PROTOCOL" >>= \case
  Nothing -> pure "auto"
  Just v -> case map toLower v of
    "" -> pure "auto"
    name | name `elem` ["auto", "tcp", "lpc", "np"] -> pure name
    _ -> fail ("HMSSQL_TEST_PROTOCOL: expected auto, tcp, lpc or np, not " ++ show v)

-- | 'testProtocolName' as a 'Protocol'.
testProtocol :: IO Protocol
testProtocol = testProtocolName <&> \case
  "tcp" -> ProtocolTcp
  "lpc" -> ProtocolSharedMemory
  "np" -> ProtocolNamedPipes
  _ -> ProtocolAuto

-- | The packet size test connections ask for (@HMSSQL_TEST_PACKET_SIZE@,
-- default 8000, as 'defaultConnectInfo').
testPacketSize :: IO Word32
testPacketSize = lookupEnv "HMSSQL_TEST_PACKET_SIZE" >>= \case
  Nothing -> pure (connectPacketSize defaultConnectInfo)
  Just "" -> pure (connectPacketSize defaultConnectInfo)
  Just v -> maybe (fail ("HMSSQL_TEST_PACKET_SIZE: not a number: " ++ show v)) pure (readMaybe v)

-- | The session setup of test connections: @[]@ ('defaultSessionSetup'), or
-- @[\"SET ARITHABORT ON\"]@ with @HMSSQL_TEST_SESSION_SETUP=arithabort@.
testSessionSetup :: IO [Text]
testSessionSetup = testSessionSetupArithabort <&> \case
  True -> ["SET ARITHABORT ON"]
  False -> []

-- | @HMSSQL_TEST_SESSION_SETUP=arithabort@: test connections have a
-- one-statement session setup, so the setup batch runs at connect and
-- after each reset.
testSessionSetupArithabort :: IO Bool
testSessionSetupArithabort = lookupEnv "HMSSQL_TEST_SESSION_SETUP" >>= \case
  Nothing -> pure False
  Just v -> case map toLower v of
    "" -> pure False
    "default" -> pure False
    "arithabort" -> pure True
    _ -> fail ("HMSSQL_TEST_SESSION_SETUP: expected default or arithabort, not " ++ show v)

-- | @HMSSQL_TEST_MARS=1@: test connections are MARS connections.
testMars :: IO Bool
testMars = lookupEnv "HMSSQL_TEST_MARS" >>= \case
  Nothing -> pure False
  Just "" -> pure False
  Just "0" -> pure False
  Just "1" -> pure True
  Just v -> fail ("HMSSQL_TEST_MARS: expected 0 or 1, not " ++ show v)

-- | @HMSSQL_TEST_MARS_WINDOW@: the window of a test connection's SMP
-- sessions, 1 to 2^31 (default 64).
testMarsWindow :: IO Int
testMarsWindow = lookupEnv "HMSSQL_TEST_MARS_WINDOW" >>= \case
  Nothing -> pure (connectMarsWindow defaultConnectInfo)
  Just "" -> pure (connectMarsWindow defaultConnectInfo)
  Just v -> case readMaybe v of
    Just n | n >= 1 -> pure n
    _ -> fail ("HMSSQL_TEST_MARS_WINDOW: expected a positive number, not " ++ show v)

-- | Whether none of the six variables above changes anything.
testConfigIsDefault :: IO Bool
testConfigIsDefault = do
  enc <- testEncryption
  defaultEnc <- defaultTestEncryption
  protocol <- testProtocolName
  size <- testPacketSize
  optIn <- testSessionSetupArithabort
  mars <- testMars
  window <- testMarsWindow
  pure (enc == defaultEnc && protocol == "auto" && size == connectPacketSize defaultConnectInfo && not optIn && not mars
          && window == connectMarsWindow defaultConnectInfo)

-- | Thrown instead of connecting when @HMSSQL_TEST_PASSWORD@ is not set.
data NoTestServer = NoTestServer

instance Show NoTestServer where
  show NoTestServer = noTestServerMessage

instance Exception NoTestServer

-- | What 'NoTestServer' says (and how "SpecHook" recognizes it in a
-- failure report, e.g. a property's).
noTestServerMessage :: String
noTestServerMessage = "needs a SQL Server: HMSSQL_TEST_PASSWORD is not set (see README.md, \"Tests\")"

-- | Whether @HMSSQL_TEST_PASSWORD@ is set.
testServerConfigured :: IO Bool
testServerConfigured = isJust <$> lookupEnv "HMSSQL_TEST_PASSWORD"

-- | @HMSSQL_TEST_REQUIRE_SERVER=1@: a test that needs the server fails,
-- instead of being skipped, when there is none.
testServerRequired :: IO Bool
testServerRequired = (== Just "1") <$> lookupEnv "HMSSQL_TEST_REQUIRE_SERVER"

-- | Connection settings for the given database, without creating anything.
-- With 'EncryptStrict' against a SQL Server before 2025 ('testSqlVersion'),
-- the test is pending instead ('strictEncryptionPending').
baseConnectInfo :: Text -> Encryption -> IO ConnectInfo
baseConnectInfo database enc = do
  when (enc == EncryptStrict) $
    strictEncryptionPending >>= mapM_ pendingWith
  host <- testHost
  port <- maybe "1433" T.pack <$> lookupEnv "HMSSQL_TEST_PORT"
  user <- fromMaybe "sa" <$> lookupEnv "HMSSQL_TEST_USER"
  password <- lookupEnv "HMSSQL_TEST_PASSWORD" >>= maybe (throwIO NoTestServer) pure
  cert <- testCertFile
  trustCert <- testTrustServerCertificate
  tlsHost <- testTlsHostName
  serverName <- testServerName
  size <- testPacketSize
  setup <- testSessionSetup
  mars <- testMars
  window <- testMarsWindow
  protocol <- testProtocol
  pure defaultConnectInfo
    { connectHost = host
    , connectPort = port
    , connectProtocol = protocol
    , connectUser = T.pack user
    , connectPassword = T.pack password
    , connectDatabase = database
    , connectEncryption = enc
    , connectTls = defaultTlsSettings
        { tlsTrustServerCertificate = trustCert
        , tlsCaCertificateFiles = maybeToList cert
        , tlsHostNameInCertificate = tlsHost
        }
    , connectServerName = serverName
    , connectPacketSize = size
    , connectSessionSetup = setup
    , connectMars = mars
    , connectMarsWindow = window
    }

-- | Settings for @master@, for server-level DDL such as CREATE DATABASE.
-- Never create objects in @master@.
masterConnectInfo :: IO ConnectInfo
masterConnectInfo = testEncryption >>= baseConnectInfo "master"

-- | Settings for the shared test database with the configured encryption,
-- creating the database first if needed.
defaultTestConnectInfo :: IO ConnectInfo
defaultTestConnectInfo = testEncryption >>= testConnectInfo

-- | Settings for the shared test database with the given encryption (the
-- configured packet size and session setup), creating it first if needed.
testConnectInfo :: Encryption -> IO ConnectInfo
testConnectInfo enc = do
  ensureTestDatabase
  db <- testDatabaseName
  baseConnectInfo db enc

-- | Settings for the companion database ('testCompanionDatabaseName') with
-- the configured encryption, creating it first if needed
-- ('ensureCompanionDatabase').  Concurrent test runs share it, as they
-- share the test database: objects a test creates there need unique names.
companionConnectInfo :: IO ConnectInfo
companionConnectInfo = do
  ensureCompanionDatabase
  db <- testCompanionDatabaseName
  testEncryption >>= baseConnectInfo db

withTestConnection :: Encryption -> (Connection -> IO a) -> IO a
withTestConnection enc act = do
  ci <- testConnectInfo enc
  bracket (connect ci) close act

-- | A connection to the shared test database, with the configured encryption
-- ('defaultTestEncryption' unless @HMSSQL_TEST_ENCRYPTION@ says).
withTestDb :: (Connection -> IO a) -> IO a
withTestDb act = testEncryption >>= \enc -> withTestConnection enc act

-- | 'withTestDb' with some settings changed, for tests that depend on them
-- (e.g. @\\ci -> ci { connectSessionSetup = [] }@).
withTestDbWith :: (ConnectInfo -> ConnectInfo) -> (Connection -> IO a) -> IO a
withTestDbWith f act = do
  ci <- defaultTestConnectInfo
  bracket (connect (f ci)) close act

-- | Run with a @master@ connection holding a server-wide session applock, so
-- CREATE/DROP DATABASE from concurrent test runs don't race each other (or
-- fail with 1807, "could not obtain exclusive lock on database 'model'").
-- The wait is 2 minutes, or 15 on Azure SQL Database, where a CREATE
-- DATABASE takes 25-60 s and the run's scratch databases queue up here.
withDdlLock :: (Connection -> IO a) -> IO a
withDdlLock act = do
  azure <- testServerIsAzure
  let timeoutMs = if azure then 900_000 else 120_000 :: Int
  ci <- masterConnectInfo
  withConnection ci $ \conn -> do
    void $ execute conn $ mkQuery
      "DECLARE @r int; \
      \EXEC @r = sp_getapplock @Resource = N'hmssql_test_ddl', @LockMode = 'Exclusive', \
      \  @LockOwner = 'Session', @LockTimeout = @p1; \
      \IF @r < 0 THROW 50000, N'hmssql tests: timed out waiting for the DDL applock', 1;"
      (Only timeoutMs)
    -- The lock is released when the connection closes.
    act conn

ensureVar :: MVar Bool
ensureVar = unsafePerformIO (newMVar False)
{-# NOINLINE ensureVar #-}

-- | Create the shared test database if it is missing.  Runs at most once per
-- process (retried if it failed), and tolerates concurrent test runs.
ensureTestDatabase :: IO ()
ensureTestDatabase = modifyMVar_ ensureVar $ \done -> do
  unless done $ do
    db <- testDatabaseName
    withDdlLock $ \conn -> createDatabaseIfMissing conn db
  pure True

companionVar :: MVar Bool
companionVar = unsafePerformIO (newMVar False)
{-# NOINLINE companionVar #-}

-- | Create the companion database ('testCompanionDatabaseName') if it is
-- missing, and allow SNAPSHOT isolation in it if it doesn't yet.  Runs at
-- most once per process (retried if it failed), and tolerates concurrent
-- test runs.  The setting is checked here, under the DDL lock, rather than
-- in a 'TestDb.withFixture': @ALTER DATABASE@ can't run in a transaction.
-- On Azure SQL Database @ALLOW_SNAPSHOT_ISOLATION@ is always on, so the
-- @ALTER@ is never issued there.
ensureCompanionDatabase :: IO ()
ensureCompanionDatabase = modifyMVar_ companionVar $ \done -> do
  unless done $ do
    db <- testCompanionDatabaseName
    withDdlLock $ \conn -> do
      createDatabaseIfMissing conn db
      -- 0 is OFF, 1 ON, 2 on its way off, 3 on its way on.
      Only (state :: Int) <- query1 conn
        ("SELECT CAST(snapshot_isolation_state AS int) FROM sys.databases WHERE name = " <> param db)
      when (state == 0 || state == 2) $
        void $ execute conn (rawSql ("ALTER DATABASE " <> quoteName db <> " SET ALLOW_SNAPSHOT_ISOLATION ON"))
  pure True

-- | @CREATE DATABASE@ ('createDatabaseSql') unless it exists, on a @master@
-- connection holding the DDL lock.
createDatabaseIfMissing :: Connection -> Text -> IO ()
createDatabaseIfMissing conn db = do
  exists <- databaseExists conn db
  unless exists $ do
    sql <- createDatabaseSql db
    retryModelLock $ do
      r <- try $ execute conn (rawSql sql)
      case r of
        Right _ -> pure ()
        Left e | sqlErrorNumber e == 1801 -> pure () -- already exists
               | otherwise -> throwIO e

-- | Whether the database exists, asked in @master@ through @sys.databases@:
-- on Azure SQL Database, @DB_ID@ of another database is NULL even there
-- (the guard @IF DB_ID(...) IS NOT NULL@ once left every scratch database
-- of a run behind).
databaseExists :: Connection -> Text -> IO Bool
databaseExists conn name =
  fromOnly <$> query1 conn ("SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = " <> param name <> ") THEN 1 ELSE 0 END AS bit)")

-- | @CREATE DATABASE [name]@, followed by 'createDatabaseOptions'.
createDatabaseSql :: Text -> IO Text
createDatabaseSql name = do
  opts <- createDatabaseOptions
  pure ("CREATE DATABASE " <> quoteName name <> opts)

-- | @HMSSQL_TEST_CREATE_DATABASE_OPTIONS@ with a leading space, or empty:
-- the options every database the suite creates (the shared one, scratch
-- databases) is created with, at the end of its @CREATE DATABASE@.  On
-- Azure SQL, where a database created without options is General Purpose
-- with 2 vCores, set it to something like @(EDITION = 'Basic', MAXSIZE =
-- 100 MB)@.
createDatabaseOptions :: IO Text
createDatabaseOptions = do
  opts <- maybe "" (T.strip . T.pack) <$> lookupEnv "HMSSQL_TEST_CREATE_DATABASE_OPTIONS"
  pure (if T.null opts then "" else " " <> opts)

-- | Retry on error 1807 (another session, perhaps outside the tests, is using
-- @model@).
retryModelLock :: IO a -> IO a
retryModelLock = go (10 :: Int)
  where
    go n act = do
      r <- try act
      case r of
        Right a -> pure a
        Left e | sqlErrorNumber e == 1807, n > 0 -> threadDelay 500_000 >> go (n - 1) act
               | otherwise -> throwIO e

-- | Retry an action the server picks as a deadlock victim (1205), up to
-- five tries in all; the error stands after that.  For what the tests do
-- in a database other tests change at the same time (DDL in the shared
-- database, and reads of its catalog), which on Azure SQL Database under
-- the whole suite lost such deadlocks.  The action must be safe to run
-- again: the victim's statement is rolled back, but earlier statements of
-- its batch stay done.
retryDeadlock :: IO a -> IO a
retryDeadlock = go (5 :: Int)
  where
    go n act = do
      r <- try act
      case r of
        Right a -> pure a
        Left e | sqlErrorNumber e == 1205, n > 1 -> threadDelay 100_000 >> go (n - 1) act
               | otherwise -> throwIO e

-- | @[name]@, for identifiers from the environment.
quoteName :: Text -> Text
quoteName n = "[" <> T.replace "]" "]]" n <> "]"

------------------------------------------------------------------------------
-- Facts about the server

azureVar, encryptionRequiredVar, onWindowsVar :: MVar (Maybe Bool)
azureVar = unsafePerformIO (newMVar Nothing)
{-# NOINLINE azureVar #-}
onWindowsVar = unsafePerformIO (newMVar Nothing)
{-# NOINLINE onWindowsVar #-}
encryptionRequiredVar = unsafePerformIO (newMVar Nothing)
{-# NOINLINE encryptionRequiredVar #-}

-- | Ask the server once per process.  Without a server (no
-- @HMSSQL_TEST_PASSWORD@) the answer is 'False': the tests that would
-- act on it are pending anyway.
serverFact :: MVar (Maybe Bool) -> IO Bool -> IO Bool
serverFact var ask = modifyMVar var $ \case
  Just known -> pure (Just known, known)
  Nothing -> try ask >>= \case
    Left NoTestServer -> pure (Just False, False)
    Right known -> pure (Just known, known)

-- | Whether the test server is Azure SQL Database
-- (@SERVERPROPERTY('EngineEdition')@ is 5).  It has no @USE@ (error 40508)
-- and no three-part names into another database (40515); its server admin
-- is not @sysadmin@ (no @RAISERROR ... WITH LOG@, 2778); @CREATE LOGIN@
-- takes no @CHECK_POLICY@ (40517) and @ALTER LOGIN@ no @DEFAULT_DATABASE@;
-- @ALTER DATABASE ... SET OFFLINE@ or @SINGLE_USER@ is refused (1468), and a
-- database is dropped with @DROP DATABASE@ alone; no extended procedures;
-- @ALLOW_SNAPSHOT_ISOLATION@ is always on; a RESETCONNECTION puts the
-- isolation level back to READ COMMITTED (SQL Server keeps it); its
-- gateway sets CONTEXT_INFO to a tracing GUID at login, caps packets at
-- 16192 bytes, and resets the connection of a killed session; and a
-- @CREATE DATABASE@ takes 25-60 s.  See docs/dev/azure-sql.md.
testServerIsAzure :: IO Bool
testServerIsAzure = serverFact azureVar $ do
  ci <- masterConnectInfo
  withConnection ci $ \conn ->
    (== (5 :: Int)) . fromOnly <$> query1 conn "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int)"

-- | Whether the test server is SQL Server running on Windows (by its
-- @\@\@VERSION@; not Azure SQL Database).  It ends a killed session's
-- connection with a reset, or over a pipe a disconnect, where SQL Server
-- on Linux closes it in an orderly way.
testServerOnWindows :: IO Bool
testServerOnWindows = serverFact onWindowsVar $ do
  ci <- masterConnectInfo
  withConnection ci $ \conn ->
    (== (1 :: Int)) . fromOnly <$> query1 conn
      "SELECT CAST(CASE WHEN @@VERSION LIKE N'% on Windows %' THEN 1 ELSE 0 END AS int)"

netTransportVar :: MVar (Maybe Text)
netTransportVar = unsafePerformIO (newMVar Nothing)
{-# NOINLINE netTransportVar #-}

-- | What the server calls the transport the suite's connections arrive
-- on, @net_transport@ in @sys.dm_exec_connections@: @TCP@, or on Windows
-- @Shared memory@ or @Named pipe@.  Asked once per process.  For a test
-- of what that view shows, which must not assume TCP, and for the run's
-- first line, since with @HMSSQL_TEST_PROTOCOL=auto@ the transport
-- depends on what the server has enabled.
testNetTransport :: IO Text
testNetTransport = modifyMVar netTransportVar $ \case
  Just known -> pure (Just known, known)
  Nothing -> do
    ci <- masterConnectInfo
    known <- withConnection ci $ \conn -> fromOnly <$> query1 conn
      "SELECT net_transport FROM sys.dm_exec_connections WHERE session_id = @@SPID AND parent_connection_id IS NULL"
    pure (Just known, known)

-- | Whether the server requires encryption, so that a plaintext connection
-- ('EncryptNotSup') is refused before the login: Azure SQL, or any SQL
-- Server with Force Encryption.  Asked by offering 'EncryptNotSup' once.
testServerRequiresEncryption :: IO Bool
testServerRequiresEncryption = serverFact encryptionRequiredVar $ do
  ci <- baseConnectInfo "master" EncryptNotSup
  try (withConnection ci (\_ -> pure ())) >>= \case
    Right () -> pure False
    Left (ProtocolError why)
      | "requires encryption" `isInfixOf` why -> pure True
      | otherwise -> throwIO (ProtocolError why)

------------------------------------------------------------------------------
-- Killing a session

-- | A session as a @KILL@ must name it: its id, and its physical
-- connection's identifier.  The server gives an ended session's id to the next
-- session, so an id alone can name another test's session by the time a
-- @KILL@ runs, or the killer's own (error 6104).  On Azure SQL Database a
-- killer that connected late under load did both: one test's @KILL@ was
-- refused as the killer's own, and two other tests' connections were
-- closed by the server.
data SessionIdentity = SessionIdentity
  { sessionSpid :: Int32
  , sessionConnectionId :: Text
    -- ^ @sys.dm_exec_connections.connection_id@ of the physical
    -- connection, unique to it.  (Its @connect_time@ is not: a session
    -- id given to a new connection within the same 3 ms tick matched a
    -- guard on it, and the wrong session died.)
  }
  deriving (Eq, Show)

-- | The identity of the connection's session (one request on it).
sessionIdentity :: Connection -> IO SessionIdentity
sessionIdentity conn = do
  (spid, cid) <- query1 conn
    "SELECT CAST(@@SPID AS int), CONVERT(nvarchar(36), connection_id) FROM sys.dm_exec_connections \
    \WHERE session_id = @@SPID AND parent_connection_id IS NULL"
  pure (SessionIdentity spid cid)

-- | @KILL@ the session from @killer@, if it is still the one named;
-- otherwise fail (a 'SqlServerError' 50001) and kill nothing.
killSessionFrom :: Connection -> SessionIdentity -> IO ()
killSessionFrom killer victim = void $ execute killer $ mkQuery
  "DECLARE @kill nvarchar(40) = N'KILL ' + CAST(@p1 AS nvarchar(10)); \
  \IF EXISTS (SELECT 1 FROM sys.dm_exec_connections WHERE session_id = @p1 AND parent_connection_id IS NULL \
  \  AND CONVERT(nvarchar(36), connection_id) = @p2) \
  \  EXEC (@kill) \
  \ELSE THROW 50001, N'hmssql tests: the session to KILL has ended (its id may be another session''s now)', 1"
  (sessionSpid victim, sessionConnectionId victim)

-- | Wait (up to 10 s) until the server shows the session waiting in a
-- WAITFOR, asking on @observer@.
awaitWaitfor :: Connection -> SessionIdentity -> IO ()
awaitWaitfor observer victim = go (500 :: Int)
  where
    go n = do
      Only waiting <- query1 observer $ mkQuery
        "SELECT CAST(COUNT(*) AS int) FROM sys.dm_exec_requests WHERE session_id = @p1 AND wait_type = N'WAITFOR'"
        (Only (sessionSpid victim))
      if (waiting :: Int32) > 0
        then pure ()
        else if n <= 0
          then fail "the request never showed as waiting in its WAITFOR"
          else threadDelay 20_000 >> go (n - 1)

-- | 'killSessionFrom' a new connection to the test database.
killSession :: SessionIdentity -> IO ()
killSession victim = withTestDb (`killSessionFrom` victim)

-- | What the server shows for the session, from a new connection, for a
-- test's failure message: whether it still exists, with its open
-- transactions; each of its requests with its wait and what blocks it (the
-- blocker's most recent statements and open transactions); and the locks
-- the session holds or waits for, counted by kind.  A MARS connection's
-- requests share its session id, and each of its logical connections has a
-- most recent statement of its own.
--
-- The queries wait at most a second for a lock (a name lookup waits on a
-- schema lock the session may hold: a temporary table it dropped in its
-- transaction kept one such lookup waiting, and with it the test that
-- would have committed), name no object in tempdb, and the whole look
-- gives up after 10 s.
describeSession :: SessionIdentity -> IO String
describeSession victim = fmap (fromMaybe "not known: the look took over 10 s") $ timeout 10_000_000 $ withTestDb $ \observer -> do
  let p = (sessionSpid victim, sessionConnectionId victim)
  void $ execute observer "SET LOCK_TIMEOUT 1000"
  sessions <- query observer $ mkQuery
    "SELECT CONCAT(N'session ', s.session_id, N' ', s.status, N', open transactions ', s.open_transaction_count, \
    \  N'; its last request started ', CONVERT(nvarchar(30), s.last_request_start_time, 121), \
    \  N', now ', CONVERT(nvarchar(30), SYSDATETIME(), 121), N' (', CONVERT(nvarchar(30), SYSUTCDATETIME(), 121), N' UTC)') \
    \FROM sys.dm_exec_sessions AS s \
    \JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id AND c.parent_connection_id IS NULL \
    \  AND CONVERT(nvarchar(36), c.connection_id) = @p2 \
    \WHERE s.session_id = @p1" p
  case map fromOnly sessions of
    [] -> pure "the session is gone"
    header -> do
      -- Each part on its own: one that waits too long for a lock says so.
      let part :: forall r. IO [r] -> IO (Either String [r])
          part q = try q <&> either (\e -> Left ("not known: " ++ show (e :: SomeException))) Right
      requests <- part $ query observer $ mkQuery
        "SELECT CONCAT(N'request ', r.request_id, N' ', r.command, N' ', r.status, N', wait ', COALESCE(r.wait_type, N'none'), \
        \  N' for ', r.wait_time, N' ms (since ', CONVERT(nvarchar(30), DATEADD(ms, -r.wait_time, SYSUTCDATETIME()), 121), \
        \  N' UTC) on ', COALESCE(r.wait_resource, N''), \
        \  CASE WHEN r.blocking_session_id <> 0 THEN CONCAT(N', blocked by ', r.blocking_session_id, \
        \    N' (open transactions ', bs.open_transaction_count, N', status ', bs.status, N'; statements: ', b.texts, N')') ELSE N'' END) \
        \FROM sys.dm_exec_requests AS r \
        \LEFT JOIN sys.dm_exec_sessions AS bs ON bs.session_id = r.blocking_session_id \
        \OUTER APPLY (SELECT STRING_AGG(LEFT(t.text, 200), N' || ') AS texts FROM sys.dm_exec_connections AS bc \
        \  CROSS APPLY sys.dm_exec_sql_text(bc.most_recent_sql_handle) AS t \
        \  WHERE bc.session_id = r.blocking_session_id) AS b \
        \WHERE r.session_id = @p1" (Only (sessionSpid victim))
      own <- part $ query observer $ mkQuery
        "SELECT STRING_AGG(LEFT(t.text, 200), N' || ') FROM sys.dm_exec_connections AS c \
        \CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t WHERE c.session_id = @p1" (Only (sessionSpid victim))
      -- The physical connection's counters, and each SMP session's on a
      -- MARS connection: SQL Server counts a MARS connection's reads and
      -- writes on its logical connections (net_transport Session), and the
      -- physical one's stop at the login.
      conns <- part $ query observer $ mkQuery
        "SELECT CONCAT(N'connection ', c.net_transport, N': ', c.num_reads, N' reads (last ', \
        \  CONVERT(nvarchar(30), c.last_read, 121), N'), ', c.num_writes, N' writes (last ', \
        \  CONVERT(nvarchar(30), c.last_write, 121), N')') \
        \FROM sys.dm_exec_connections AS c \
        \WHERE c.session_id = @p1 AND (CONVERT(nvarchar(36), c.connection_id) = @p2 \
        \  OR CONVERT(nvarchar(36), c.parent_connection_id) = @p2) \
        \ORDER BY CASE WHEN c.parent_connection_id IS NULL THEN 0 ELSE 1 END, c.connect_time" p
      server <- part $ query observer serverQuery
      locks <- part $ query observer $ mkQuery
        "SELECT CONCAT(COUNT(*), N' ', l.request_status, N' ', l.request_mode, N' ', l.resource_type, \
        \  CASE WHEN l.obj IS NOT NULL AND l.db = 2 THEN CONCAT(N' tempdb object ', l.obj) \
        \    WHEN l.obj IS NOT NULL THEN CONCAT(N' ', DB_NAME(l.db), N'.', OBJECT_SCHEMA_NAME(l.obj, l.db), N'.', OBJECT_NAME(l.obj, l.db)) \
        \  ELSE CONCAT(N' in ', DB_NAME(l.db)) END, N' (', l.request_owner_type, N')') \
        \FROM (SELECT request_status, request_mode, resource_type, request_owner_type, resource_database_id AS db, \
        \  CASE WHEN resource_type = N'OBJECT' THEN resource_associated_entity_id END AS obj \
        \  FROM sys.dm_tran_locks WHERE request_session_id = @p1) AS l \
        \GROUP BY l.request_status, l.request_mode, l.resource_type, l.db, l.obj, l.request_owner_type" (Only (sessionSpid victim))
      let line label xs = if null xs then [] else [label ++ T.unpack (T.intercalate "; " xs)]
      let partLines f = either (\why -> [why]) f
      pure $ intercalate "\n    " $
        map T.unpack header
          ++ partLines (\rs -> if null rs then ["no request"] else map (T.unpack . fromOnly) rs) requests
          ++ partLines (\os -> line "its statements: " [t | Only (Just t) <- os]) own
          ++ partLines (\ls -> line "locks: " (take 20 (map fromOnly ls))) locks
          ++ partLines (map (T.unpack . fromOnly)) conns
          ++ partLines (map (T.unpack . fromOnly)) server

-- | The whole server, for a failure message, from a new connection (giving
-- up after 10 s): is it stopped, or busy, or is it one session alone?
-- Every user request by its wait, and the schedulers' queues.
describeServer :: IO String
describeServer = fmap (fromMaybe "not known: the look took over 10 s") $ timeout 10_000_000 $ withTestDb $ \observer ->
  intercalate "\n    " . map (T.unpack . fromOnly) <$> query observer serverQuery

serverQuery :: Query
serverQuery =
  "SELECT CONCAT(N'the whole server: ', (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id > 50 AND session_id <> @@SPID), \
  \  N' user requests (', COALESCE((SELECT STRING_AGG(CONCAT(w.n, N' ', w.wait), N', ') FROM \
  \    (SELECT COALESCE(wait_type, status) AS wait, COUNT(*) AS n FROM sys.dm_exec_requests \
  \     WHERE session_id > 50 AND session_id <> @@SPID GROUP BY COALESCE(wait_type, status)) AS w), N'none'), \
  \  N'); schedulers: ', SUM(s.runnable_tasks_count), N' runnable, ', SUM(s.work_queue_count), N' queued, ', \
  \  SUM(s.pending_disk_io_count), N' pending I/O, ', SUM(s.active_workers_count), N' active workers') \
  \FROM sys.dm_os_schedulers AS s WHERE s.status = N'VISIBLE ONLINE'"
