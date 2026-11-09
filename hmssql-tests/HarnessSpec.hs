-- | Smoke tests for the test harness itself ("TestDb"), and an example of
-- declaring a fixture next to the tests that use it.
module HarnessSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (LocalTime)
import Test.Hspec

import Hmssql
import Hmssql.Errors (sqlErrorNumber)
import TestDb

exampleFixture :: [Text]
exampleFixture =
  [ "DROP TABLE IF EXISTS dbo.harness_example"
  , "CREATE TABLE dbo.harness_example (id int NOT NULL PRIMARY KEY, label nvarchar(20) NOT NULL)"
  , "INSERT INTO dbo.harness_example VALUES (1, N'one'), (2, N'two')"
  ]

spec :: Spec
spec = withFixture "harness_example" exampleFixture $ do
  describe "killSession" $ do
    it "kills the session it names" $ do
      ci <- defaultTestConnectInfo
      withConnection ci $ \victim -> do
        sessionIdentity victim >>= killSession
        r <- try (query1 victim "SELECT 1" :: IO (Only Int))
        either (\(_ :: SomeException) -> pure ()) (\v -> expectationFailure ("the killed session answered " ++ show v)) r
    it "refuses a session that has ended, whose id may be another's now, and kills nothing" $ do
      ci <- defaultTestConnectInfo
      gone <- withConnection ci sessionIdentity
      withConnection ci $ \bystander -> do
        -- The bystander may well have the ended session's id.
        try (killSession gone) >>= \case
          Left e -> sqlErrorNumber e `shouldBe` 50001
          Right () -> expectationFailure "killed a session that had ended"
        query1 bystander "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "shared database" $ around withTestDb $ do
    it "connects to the shared test database" $ \conn -> do
      db <- testDatabaseName
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only db

    it "has the example fixture applied" $ \conn ->
      query conn "SELECT id, label FROM dbo.harness_example ORDER BY id"
        `shouldReturn` [(1 :: Int, "one" :: Text), (2, "two")]

    it "doesn't re-apply an unchanged fixture" $ \conn -> do
      let appliedAt :: IO (Only LocalTime)
          appliedAt = query1 conn (mkQuery ("SELECT applied_at FROM " <> fixturesTable <> " WHERE name = @p1") (Only ("harness_example" :: Text)))
      before <- appliedAt
      applyFixture "harness_example" exampleFixture `shouldReturn` False
      appliedAt `shouldReturn` before

    it "applies a new fixture once, and again when it changes" $ \conn -> do
      fixture <- uniqueName "harness_tmp"
      let v k = ["DROP TABLE IF EXISTS dbo." <> fixture, "SELECT " <> k <> " AS k INTO dbo." <> fixture]
          cleanup = void $ execute conn (mkQuery ("DROP TABLE IF EXISTS dbo." <> fixture <> "; DELETE FROM " <> fixturesTable <> " WHERE name = @p1") (Only fixture))
      applyFixture fixture (v "1") `shouldReturn` True
      applyFixture fixture (v "1") `shouldReturn` False
      applyFixture fixture (v "2") `shouldReturn` True
      query1 conn (rawSql ("SELECT k FROM dbo." <> fixture)) `shouldReturn` Only (2 :: Int)
      cleanup

  describe "the companion database" $
    it "is another database, kept, that allows SNAPSHOT isolation" $ do
      ci <- companionConnectInfo
      db <- testDatabaseName
      connectDatabase ci `shouldNotBe` db
      withConnection ci $ \conn -> do
        query1 conn "SELECT DB_NAME()" `shouldReturn` Only (connectDatabase ci)
        query1 conn "SELECT CAST(snapshot_isolation_state AS int) FROM sys.databases WHERE database_id = DB_ID()"
          `shouldReturn` Only (1 :: Int)

  describe "withScratchSchema" $
    it "creates a schema, and drops it with everything in it" $ do
      ci <- defaultTestConnectInfo
      name <- withScratchSchema ci "harness" $ \s -> withConnection ci $ \conn -> do
        -- Objects whose order of dropping matters: a schema-bound view on
        -- a table, a foreign key, a temporal table, an alias type and an
        -- XML schema collection a column uses, and a sequence a default
        -- uses.
        forM_
          [ "CREATE TYPE " <> s <> ".code FROM char(3) NOT NULL"
          , "CREATE XML SCHEMA COLLECTION " <> s <> ".doc AS N'<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"><xs:element name=\"a\"/></xs:schema>'"
          , "CREATE SEQUENCE " <> s <> ".seq"
          , "CREATE TABLE " <> s <> ".parent (id int PRIMARY KEY, c " <> s <> ".code, x xml(" <> s <> ".doc), n int DEFAULT NEXT VALUE FOR " <> s <> ".seq)"
          , "CREATE TABLE " <> s <> ".child (id int PRIMARY KEY, parent_id int REFERENCES " <> s <> ".parent (id))"
          , "CREATE VIEW " <> s <> ".v WITH SCHEMABINDING AS SELECT id FROM " <> s <> ".parent"
          , "CREATE TABLE " <> s <> ".versioned (id int PRIMARY KEY, \
            \vfrom datetime2 GENERATED ALWAYS AS ROW START NOT NULL, vto datetime2 GENERATED ALWAYS AS ROW END NOT NULL, \
            \PERIOD FOR SYSTEM_TIME (vfrom, vto)) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = " <> s <> ".versioned_history))"
          ] $ \sql -> void (execute conn (rawSql sql))
        pure s
      name `shouldSatisfy` T.isPrefixOf "harness_"
      withConnection ci $ \conn ->
        query1 conn (mkQuery "SELECT CAST(COUNT(*) AS int) FROM sys.schemas WHERE name = @p1" (Only name))
          `shouldReturn` Only (0 :: Int)

  -- The one scratch database it needs is the point of the test.
  describe "withScratchDatabase" $
    it "creates and drops a database" $ do
      name <- withScratchDatabase "harness" $ \ci -> withConnection ci $ \conn -> do
        Only name <- query1 conn "SELECT DB_NAME()"
        void $ execute conn "CREATE TABLE t (i int)"
        query1 conn "SELECT COUNT(*) FROM t" `shouldReturn` Only (0 :: Int)
        pure (name :: Text)
      name `shouldSatisfy` T.isPrefixOf "hmssql_test_harness_"
      -- Asked in master through sys.databases: on Azure SQL Database, DB_ID
      -- of any other database is NULL, even there.
      ci <- masterConnectInfo
      withConnection ci $ \conn -> databaseExists conn name `shouldReturn` False

  describe "uniqueName" $
    it "gives distinct names" $ do
      a <- uniqueName "t"
      b <- uniqueName "t"
      a `shouldNotBe` b

  describe "slow" $ slow $
    it "runs only with HMSSQL_TEST_SLOW=1" $
      slowTestsEnabled `shouldReturn` True
