-- | Helpers for live tests against the shared test database: idempotent
-- fixtures, scratch schemas, scratch databases, unique names, slow tests,
-- tests that the server can't run, serial tests, the number of property
-- cases, and skipping the tests that need a server when there is none.
-- Re-exports "TestConfig", which has the companion database.
module TestDb
  ( module TestConfig
    -- * Fixtures
  , withFixture
  , applyFixture
  , fixturesTable
  , prepareTestDb
    -- * Scratch schemas
  , withScratchSchema
  , withSchema
  , dropSchema
    -- * Scratch databases
  , withScratchDatabase
  , dropDatabase
    -- * Unique names
  , uniqueName
    -- * Slow tests
  , slow
  , slowTestsEnabled
  , fastOrSlow
    -- * Tests the server can't run
  , skipWhen
  , skipOnAzure
  , skipBeforeSql2019
  , skipBeforeSql2022
  , skipBeforeSql2025
  , skipIfEncryptionRequired
  , skipUnlessLoopbackHost
    -- * Serial tests
  , serial
    -- * Property cases
  , withCases
  , withCasesSlow
  , scaledCases
  , propertyScale
  , scaleDefaultPropertyCases
    -- * No server
  , noServerHook
  ) where

import Control.Exception (finally, fromException, try)
import Control.Monad (forM_, unless, void, when)
import Data.Char (isAlphaNum, isAscii)
import Data.List (isInfixOf)
import Data.IORef
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Compat (randomBytes)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Text.Read (readMaybe)
import Test.Hspec.Core.Spec (FailureReason (..), Item (..), Result (..), ResultStatus (..), mapSpecItem_)

import Hmssql
import TestConfig

-- | Where applied fixtures are recorded, in the shared test database.
fixturesTable :: Text
fixturesTable = "dbo._hmssql_fixtures"

-- | Run the spec with fixture @name@ (a list of SQL batches) applied to the
-- shared test database:
--
-- > spec = withFixture "types_decimal" [...] $ around withTestDb $ ...
--
-- "SpecHook" applies every fixture declared this way before any test runs
-- ('prepareTestDb'), so the tests don't wait for it; the 'beforeAll_' this
-- adds then finds it done without asking the server.  (It applies the
-- fixture itself only if the hook didn't, e.g. because that failed.)
--
-- The batches run only when the fixture is missing or its text changed since
-- it was last applied; they then run again as they are, so write them to be
-- re-runnable (@DROP TABLE IF EXISTS@ before @CREATE@, or guarded creates).
-- Everything runs in one transaction under an exclusive applock, so
-- concurrent test runs apply each fixture once and never see it half-applied.
-- Statements that can't run in a transaction (ALTER DATABASE, ...) belong in
-- 'ensureCompanionDatabase' or a scratch database instead.  Two
-- declarations of the same name must have the same batches.
withFixture :: Text -> [Text] -> SpecWith a -> SpecWith a
withFixture name batches spec = do
  runIO (declareFixture name batches)
  beforeAll_ (seedFixture name batches) spec

-- | The fixtures declared with 'withFixture' (while the spec tree is built).
declared :: IORef [(Text, [Text])]
declared = unsafePerformIO (newIORef [])
{-# NOINLINE declared #-}

-- | The fixtures this process has applied or found up to date, with their
-- batches.
seeded :: IORef [(Text, [Text])]
seeded = unsafePerformIO (newIORef [])
{-# NOINLINE seeded #-}

declareFixture :: Text -> [Text] -> IO ()
declareFixture name batches = do
  clash <- atomicModifyIORef' declared $ \fs -> case lookup name fs of
    Nothing -> ((name, batches) : fs, False)
    Just bs -> (fs, bs /= batches)
  when clash $
    fail ("withFixture: fixture " ++ show name ++ " is declared twice, with different batches")

seedFixture :: Text -> [Text] -> IO ()
seedFixture name batches = do
  done <- (== Just batches) . lookup name <$> readIORef seeded
  unless done $ withTestDb $ \conn -> void (applyFixtureOn conn name batches)

-- | Create the shared test database and the companion database if they
-- are missing, and apply every fixture declared with 'withFixture'.
-- "SpecHook" runs it (with a server) after building the spec tree and
-- before running any test, so that no test waits for this setup, nor
-- competes with others to do it.
prepareTestDb :: IO ()
prepareTestDb = do
  ensureTestDatabase
  ensureCompanionDatabase
  fixtures <- reverse <$> readIORef declared
  unless (null fixtures) $ withTestDb $ \conn ->
    forM_ fixtures $ \(name, batches) -> applyFixtureOn conn name batches

-- | Apply fixture @name@ now if it is missing or changed (what 'withFixture'
-- does, but always asking the server), returning whether the batches ran.
applyFixture :: Text -> [Text] -> IO Bool
applyFixture name batches = withTestDb $ \conn -> applyFixtureOn conn name batches

applyFixtureOn :: Connection -> Text -> [Text] -> IO Bool
applyFixtureOn conn name batches = do
  stale <- withTransaction conn $ do
    let body = T.intercalate "\n-- hmssql fixture batch --\n" batches
    (newHash, oldHash) <- query1 conn $ mkQuery
      ( "DECLARE @r int; \
        \EXEC @r = sp_getapplock @Resource = N'hmssql_fixtures', @LockMode = 'Exclusive', \
        \  @LockOwner = 'Transaction', @LockTimeout = 300000; \
        \IF @r < 0 THROW 50000, N'hmssql tests: timed out waiting for the fixtures applock', 1; \
        \IF OBJECT_ID(N'" <> fixturesTable <> "', N'U') IS NULL \
        \  CREATE TABLE " <> fixturesTable <> " \
        \    ( name nvarchar(200) NOT NULL PRIMARY KEY \
        \    , hash varchar(64) NOT NULL \
        \    , applied_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME() ); \
        \SELECT CONVERT(varchar(64), HASHBYTES('SHA2_256', @p2), 2), \
        \  (SELECT hash FROM " <> fixturesTable <> " WHERE name = @p1)" )
      (name, body)
    let stale = oldHash /= Just (newHash :: Text)
    when stale $ do
      forM_ batches $ \b -> void (execute conn (rawSql b))
      void $ execute conn $ mkQuery
        ( "DELETE FROM " <> fixturesTable <> " WHERE name = @p1; \
          \INSERT INTO " <> fixturesTable <> " (name, hash) VALUES (@p1, @p2)" )
        (name, newHash)
    pure stale
  atomicModifyIORef' seeded (\fs -> ((name, batches) : filter ((/= name) . fst) fs, ()))
  pure stale

-- | Run the action with a schema of its own, named @<prefix>_<unique>@
-- ('uniqueName'), in the database the settings name (the shared test
-- database, 'defaultTestConnectInfo', or the companion,
-- 'companionConnectInfo'); then drop the schema with everything in it
-- ('dropSchema'), even on exceptions.  @prefix@ is letters, digits and
-- underscores, so the name needs no quoting.  For a test that wants its
-- objects apart (a temporal table, an XML schema collection, a catalog to
-- read), where a scratch database would only be tidier.
withScratchSchema :: ConnectInfo -> Text -> (Text -> IO a) -> IO a
withScratchSchema ci prefix act = do
  checkName "withScratchSchema" prefix
  name <- uniqueName prefix
  withSchema ci name (act name)

-- | 'withScratchSchema' with the name given, for a spec that names its
-- objects while the tree is built (@s <- runIO (uniqueName "txn")@) and
-- creates the schema in an 'aroundAll'.  The name must be unique across
-- concurrent runs, and need no quoting.
withSchema :: ConnectInfo -> Text -> IO a -> IO a
withSchema ci name act = do
  checkName "withSchema" name
  withConnection ci $ \conn -> retryDeadlock $ void $ execute conn (rawSql ("CREATE SCHEMA " <> name))
  act `finally` withConnection ci (\conn -> dropSchema conn name)

-- | Drop the schema with everything in it, if it exists: system versioning
-- is turned off, the foreign keys into or out of it are dropped, then its
-- views, procedures, synonyms, tables (with their triggers), functions,
-- sequences, rules and defaults, its types and XML schema collections, and
-- the schema itself.  Tried again if it loses a deadlock to other tests'
-- DDL ('retryDeadlock'): each try drops what is left.
dropSchema :: Connection -> Text -> IO ()
dropSchema conn name = retryDeadlock $ void $ execute conn $ mkQuery
  "DECLARE @id int = SCHEMA_ID(@p1); \
  \IF @id IS NULL RETURN; \
  \DECLARE @q nvarchar(max) = QUOTENAME(@p1) + N'.'; \
  \DECLARE @sql nvarchar(max) = CONCAT( \
  \  (SELECT STRING_AGG(CAST(N'ALTER TABLE ' + @q + QUOTENAME(name) + N' SET (SYSTEM_VERSIONING = OFF);' AS nvarchar(max)), N' ') \
  \     FROM sys.tables WHERE schema_id = @id AND temporal_type = 2), N' ', \
  \  (SELECT STRING_AGG(CAST(N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.' \
  \       + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' AS nvarchar(max)), N' ') \
  \     FROM sys.foreign_keys AS fk JOIN sys.objects AS r ON r.object_id = fk.referenced_object_id \
  \     WHERE fk.schema_id = @id OR r.schema_id = @id), N' ', \
  \  (SELECT STRING_AGG(CAST(N'DROP ' + CASE type WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' WHEN 'SN' THEN N'SYNONYM' \
  \       WHEN 'U' THEN N'TABLE' WHEN 'SO' THEN N'SEQUENCE' WHEN 'R' THEN N'RULE' WHEN 'D' THEN N'DEFAULT' ELSE N'FUNCTION' END \
  \       + N' ' + @q + QUOTENAME(name) + N';' AS nvarchar(max)), N' ') \
  \     WITHIN GROUP (ORDER BY CASE type WHEN 'V' THEN 0 WHEN 'P' THEN 1 WHEN 'SN' THEN 1 WHEN 'U' THEN 2 \
  \       WHEN 'FN' THEN 3 WHEN 'IF' THEN 3 WHEN 'TF' THEN 3 ELSE 4 END) \
  \     FROM sys.objects WHERE schema_id = @id AND parent_object_id = 0 \
  \       AND type IN ('V', 'P', 'SN', 'U', 'FN', 'IF', 'TF', 'SO', 'R', 'D')), N' ', \
  \  (SELECT STRING_AGG(CAST(N'DROP TYPE ' + @q + QUOTENAME(name) + N';' AS nvarchar(max)), N' ') \
  \     FROM sys.types WHERE schema_id = @id AND is_user_defined = 1), N' ', \
  \  (SELECT STRING_AGG(CAST(N'DROP XML SCHEMA COLLECTION ' + @q + QUOTENAME(name) + N';' AS nvarchar(max)), N' ') \
  \     FROM sys.xml_schema_collections WHERE schema_id = @id), N' ', \
  \  N'DROP SCHEMA ' + QUOTENAME(@p1) + N';'); \
  \EXEC sp_executesql @sql;"
  (Only name)

-- | Letters, digits and underscores, and not empty.
checkName :: String -> Text -> IO ()
checkName what name =
  unless (not (T.null name) && T.all (\c -> isAscii c && (isAlphaNum c || c == '_')) name) $
    fail (what ++ ": bad name " ++ show name)

-- | Create a fresh database named @hmssql_test_<suffix>_<unique>@, run the
-- action with settings for it (the configured encryption), then drop it
-- (even on exceptions; open connections to it are killed first).  @suffix@
-- is letters, digits and underscores, e.g. your test area.  Only for a
-- test of something that changes the database itself (its collation, say)
-- or of the harness: on Azure SQL Database a create takes 25-60 s,
-- serialised by the DDL lock.  Prefer a @#temp@ table, a 'uniqueName'
-- object or a 'withScratchSchema' in the shared database, or the companion
-- database ('companionConnectInfo') for a second database or for SNAPSHOT
-- isolation.
withScratchDatabase :: Text -> (ConnectInfo -> IO a) -> IO a
withScratchDatabase suffix act = do
  checkName "withScratchDatabase" suffix
  name <- uniqueName ("hmssql_test_" <> suffix)
  sql <- createDatabaseSql name
  withDdlLock $ \conn -> retryModelLock $ void $ execute conn (rawSql sql)
  ci <- masterConnectInfo
  act ci { connectDatabase = name } `finally` dropDatabase name

-- | Drop a database the suite created, if it still exists ('databaseExists':
-- not @DB_ID@, which is NULL for any other database in Azure's @master@),
-- under the DDL lock.  Connections into it are killed first (@SET
-- SINGLE_USER WITH ROLLBACK IMMEDIATE@).  Azure SQL Database refuses that
-- @ALTER DATABASE@ (error 1468) and wants @DROP DATABASE@ alone in its
-- batch; it drops a database with connections into it.
dropDatabase :: Text -> IO ()
dropDatabase name = do
  azure <- testServerIsAzure
  withDdlLock $ \conn -> do
    exists <- databaseExists conn name
    when exists $ do
      void $ execute conn $ rawSql $
        if azure
          then "DROP DATABASE " <> quoteName name
          else "ALTER DATABASE " <> quoteName name <> " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; \
               \DROP DATABASE " <> quoteName name
      -- A drop that returns without an error and without dropping would
      -- leave databases behind, billed by the hour.
      stillThere <- databaseExists conn name
      when stillThere $ fail $
        "dropDatabase: DROP DATABASE " ++ T.unpack (quoteName name) ++ " returned without error, but the database is still listed"

counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

-- | @prefix_<run>_<time>_<n>@: unique across concurrent test runs, for real
-- tables (or other objects) a test creates.  Letters, digits and underscores
-- only (if the prefix is), so it needs no quoting.  @<run>@ is random
-- ('runTag'), not the process id, which is 1 in every container of a
-- test-matrix run: two of them sharing a server once made the same login
-- name in the same millisecond with the same counter.
uniqueName :: Text -> IO Text
uniqueName prefix = do
  n <- atomicModifyIORef' counter (\i -> (i + 1, i))
  t <- getPOSIXTime
  let millis = floor (t * 1000) :: Integer
  pure $ T.intercalate "_" [prefix, runTag, base36 millis, T.pack (show n)]

-- | 32 random bits in base 36, chosen once per process.
runTag :: Text
runTag = unsafePerformIO $ do
  bytes <- randomBytes 4
  pure (base36 (B.foldl' (\acc w -> acc * 256 + fromIntegral w) 0 bytes))
{-# NOINLINE runTag #-}

base36 :: Integer -> Text
base36 0 = "0"
base36 x = T.pack (reverse (go x))
  where
    go 0 = []
    go k = let (q, r) = k `quotRem` 36 in ("0123456789abcdefghijklmnopqrstuvwxyz" !! fromInteger r) : go q

-- | @HMSSQL_TEST_SLOW=1@?
slowTestsEnabled :: IO Bool
slowTestsEnabled = (== Just "1") <$> lookupEnv "HMSSQL_TEST_SLOW"

-- | Mark tests taking more than ~20 s: unless @HMSSQL_TEST_SLOW=1@, they are
-- reported pending and not run (nor are their hooks).
slow :: SpecWith a -> SpecWith a
slow spec = do
  enabled <- runIO slowTestsEnabled
  if enabled then spec else mapSpecItem_ skip spec
  where
    skip item = item
      { itemExample = \_ _ _ -> pure (Result "" (Pending Nothing (Just "slow test; set HMSSQL_TEST_SLOW=1 to run")))
      }

-- | @fast@, or @slow@ with @HMSSQL_TEST_SLOW=1@: for a loop worth more
-- iterations than the fast suite can afford (as 'withCasesSlow' is for
-- properties), e.g. @n <- fastOrSlow 50 200@.
fastOrSlow :: a -> a -> IO a
fastOrSlow fast slowN = do
  enabled <- slowTestsEnabled
  pure (if enabled then slowN else fast)

-- | Report the items of the spec as pending, with the reason, when the
-- condition holds.  It is asked when each item would run (not while the
-- spec tree is built), so a condition that asks the server costs nothing
-- in a run without one; the hooks around a skipped item don't run either.
skipWhen :: IO Bool -> String -> SpecWith a -> SpecWith a
skipWhen cond reason = mapSpecItem_ $ \item -> item
  { itemExample = \params hook progress -> cond >>= \case
      True -> pure (Result "" (Pending Nothing (Just reason)))
      False -> itemExample item params hook progress
  }

-- | Pending on Azure SQL Database ('testServerIsAzure'), which lacks what
-- the tests need; say what.
skipOnAzure :: String -> SpecWith a -> SpecWith a
skipOnAzure what = skipWhen testServerIsAzure ("Azure SQL Database: " ++ what)

-- | Pending against SQL Server 2017 (@HMSSQL_TEST_SQL_VERSION=2017@,
-- 'testSqlVersion'): for the tests of what SQL Server 2019 added, such as
-- the UTF-8 collations; say what.
skipBeforeSql2019 :: String -> SpecWith a -> SpecWith a
skipBeforeSql2019 = skipBeforeSql 2019

-- | Pending against SQL Server 2019 and 2017 (@HMSSQL_TEST_SQL_VERSION@,
-- 'testSqlVersion'): for the tests of what SQL Server 2022 added; say what.
skipBeforeSql2022 :: String -> SpecWith a -> SpecWith a
skipBeforeSql2022 = skipBeforeSql 2022

-- | Pending against SQL Server 2022 and earlier (@HMSSQL_TEST_SQL_VERSION@):
-- for the tests of what SQL Server 2025 added; say what.
skipBeforeSql2025 :: String -> SpecWith a -> SpecWith a
skipBeforeSql2025 = skipBeforeSql 2025

-- | Pending when 'testSqlVersion' is before @needed@; the reason names both.
skipBeforeSql :: Int -> String -> SpecWith a -> SpecWith a
skipBeforeSql needed what = mapSpecItem_ $ \item -> item
  { itemExample = \params hook progress -> testSqlVersion >>= \case
      v | v < needed -> pure $ Result "" $ Pending Nothing $ Just $
            "needs SQL Server " ++ show needed ++ " (HMSSQL_TEST_SQL_VERSION=" ++ show v ++ "): " ++ what
      _ -> itemExample item params hook progress
  }

-- | Pending when the server refuses plaintext connections
-- ('testServerRequiresEncryption'): for the 'EncryptNotSup' variants.
skipIfEncryptionRequired :: SpecWith a -> SpecWith a
skipIfEncryptionRequired =
  skipWhen testServerRequiresEncryption "the server requires encryption: no plaintext connection"

-- | Pending unless the server is on this machine ('testHostIsLoopback'):
-- for tests that connect to a loopback address themselves.
skipUnlessLoopbackHost :: SpecWith a -> SpecWith a
skipUnlessLoopbackHost =
  skipWhen (not <$> testHostIsLoopback) "the test server is not on this machine (HMSSQL_TEST_HOST is not a loopback address)"

-- | Mark tests that must run alone: "SpecHook" runs every other item in
-- parallel with others, and these afterwards, one at a time.  Use it for a
-- test that measures time, allocation, residency, threads or descriptors,
-- or that otherwise can't share the process with other tests (see
-- 'SpecHook.serialModules' to mark a whole module).  It is hspec's
-- 'sequential'.
serial :: SpecWith a -> SpecWith a
serial = sequential

-- | @HMSSQL_TEST_PROPERTY_SCALE@ (default 1): a factor for the number of
-- cases every property runs, e.g. @0.2@ while iterating on something
-- unrelated, or @10@ for a soak run.  It scales the counts given to
-- 'withCases' and 'withCasesSlow', and hspec's default of 100 (see
-- "SpecHook"); a count set with a plain 'modifyMaxSuccess' is left alone.
propertyScale :: IO Double
propertyScale = lookupEnv "HMSSQL_TEST_PROPERTY_SCALE" >>= \case
  Nothing -> pure 1
  Just "" -> pure 1
  Just v -> case readMaybe v of
    Just x | x > 0 -> pure x
    _ -> fail ("HMSSQL_TEST_PROPERTY_SCALE: expected a positive number, not " ++ show v)

-- | @n@ scaled by 'propertyScale' (at least 1).
scaledCases :: Int -> IO Int
scaledCases n = do
  factor <- propertyScale
  pure (max 1 (round (fromIntegral n * factor)))

-- | Run each (hspec-hedgehog) property in the spec for @n@ cases, scaled
-- by 'propertyScale'.
withCases :: Int -> SpecWith a -> SpecWith a
withCases n spec = do
  k <- runIO (scaledCases n)
  modifyMaxSuccess (const k) spec

-- | 'withCases' @fast@, or @slow@ cases with @HMSSQL_TEST_SLOW=1@: for a
-- property worth more cases than the fast suite can afford.
withCasesSlow :: Int -> Int -> SpecWith a -> SpecWith a
withCasesSlow fast slowN spec = do
  enabled <- runIO slowTestsEnabled
  withCases (if enabled then slowN else fast) spec

-- | Scale hspec's default number of cases (for properties that don't set
-- one) by 'propertyScale'.  "SpecHook" applies it to the whole suite.
scaleDefaultPropertyCases :: SpecWith a -> SpecWith a
scaleDefaultPropertyCases spec = do
  factor <- runIO propertyScale
  if factor == 1
    then spec
    else modifyMaxSuccess (\n -> max 1 (round (fromIntegral n * factor))) spec

-- | Without a server (@HMSSQL_TEST_PASSWORD@ unset), report every item
-- that tries to reach it as pending instead of failed, so that the suite
-- passes where it can't run the live tests (e.g. a distribution's package
-- build); the pure and mock-server tests still run.  An item counts as
-- needing the server when it throws 'NoTestServer' (from its hooks too), or
-- fails with its message (a property reports the exception as a failure).
-- With @HMSSQL_TEST_REQUIRE_SERVER=1@, or with a server, this does nothing.
-- "SpecHook" applies it to the whole suite.
noServerHook :: SpecWith a -> SpecWith a
noServerHook spec = do
  configured <- runIO testServerConfigured
  required <- runIO testServerRequired
  if configured || required then spec else mapSpecItem_ skipIfNoServer spec
  where
    skipIfNoServer item = item
      { itemExample = \params hook progress ->
          try (itemExample item params hook progress) >>= \case
            Left NoTestServer -> pure skipped
            Right r | needsServer (resultStatus r) || afterSkippedHook (resultStatus r) -> pure skipped
            Right r -> pure r
      }
    skipped = Result "" (Pending Nothing (Just noTestServerMessage))
    needsServer = \case
      Failure _ reason -> case reason of
        NoReason -> False
        Reason m -> mentions m
        ColorizedReason m -> mentions m
        ExpectedButGot pre e a -> any mentions (maybe [] pure pre ++ [e, a])
        Error pre e -> any mentions (maybe [] pure pre) || isNoServer e
      Pending {} -> False
      Success -> False
    -- hspec's report for the items after the first of a 'beforeAll' (or
    -- 'aroundAll') whose hook failed; the first item's report shows why, so
    -- if that was a failure the run fails anyway.
    afterSkippedHook = \case
      Pending _ (Just m) -> "-hook (see previous failure)" `isInfixOf` m
      _ -> False
    mentions = (noTestServerMessage `isInfixOf`)
    isNoServer e = case fromException e of
      Just NoTestServer -> True
      Nothing -> mentions (show e)
