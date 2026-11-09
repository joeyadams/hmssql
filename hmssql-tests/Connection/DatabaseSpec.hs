-- | Login-time database-selection edge cases: unusual names, unavailable
-- databases, and the empty-database-means-login-default case.
module Connection.DatabaseSpec (spec) where

import Control.Exception (SomeException, bracket, fromException, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import TestDb

-- | Create a database with an arbitrary (not identifier-restricted) name,
-- with the given clause between the name and the configured options, run
-- the action with a connection to it, then drop it. Unlike
-- 'withScratchDatabase', @name@ is used as given (not combined with a unique
-- suffix), so callers that need uniqueness across concurrent runs must
-- include it themselves.  Every name here starts with @hmssql_test@ and ends
-- with a 'uniqueName' suffix, which is how @scripts/azure-sql-test.sh prune@
-- tells a database a run left behind (and never the shared database or the
-- companion).
withNamedDatabase :: Text -> Text -> (ConnectInfo -> IO a) -> IO a
withNamedDatabase name clause act = bracket create (const (dropDatabase name)) (const (act =<< ci))
  where
    ci = do
      base <- masterConnectInfo
      pure base { connectDatabase = name }
    create = withDdlLock $ \conn -> do
      opts <- createDatabaseOptions
      void $ execute conn (rawSql ("CREATE DATABASE " <> quoteName name <> clause <> opts))

refusalNumber :: Either SomeException a -> Maybe Int
refusalNumber (Left e) = fromIntegral . loginErrorNumber <$> fromException e
refusalNumber (Right _) = Nothing

spec :: Spec
spec = describe "database selection" $ do
  it "reports a nonexistent database as LoginError 4060" $ do
    name <- uniqueName "hmssql_test_nonexistent"
    ci <- masterConnectInfo
    r <- try $ withConnection ci { connectDatabase = name } (\_ -> pure ()) :: IO (Either SomeException ())
    refusalNumber r `shouldBe` Just 4060

  it "an empty database means the login's own default database" $ do
    ci <- masterConnectInfo -- sa's default database is master
    withConnection ci { connectDatabase = "" } $ \conn ->
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only ("master" :: Text)

  describe "unusual (but valid) database names" $ do
    let connectsTo label mkName =
          it ("connects to a database with " ++ label ++ " in its name") $ do
            suffix <- uniqueName ""
            let name = mkName suffix
            withNamedDatabase name "" $ \ci -> withConnection ci $ \conn ->
              query1 conn "SELECT DB_NAME()" `shouldReturn` Only name
    connectsTo "spaces" (\s -> "hmssql_test db " <> s)
    connectsTo "closing brackets" (\s -> "hmssql_test]db]" <> s)
    connectsTo "unicode" (\s -> "hmssql_test_únïcödé_日本語_" <> s)

  it "a non-BMP database name is refused by Azure (1055), but round-trips on SQL Server" $ do
    suffix <- uniqueName ""
    let name = "hmssql_test_𝄞_" <> suffix
        roundTrip = withNamedDatabase name "" $ \ci -> withConnection ci $ \conn ->
          query1 conn "SELECT DB_NAME()" `shouldReturn` Only name
    azure <- testServerIsAzure
    if azure
      then try @SqlServerError roundTrip >>= \case
        Left e -> sqlErrorNumber e `shouldBe` 1055
        Right () -> expectationFailure "Azure accepted a database name containing a supplementary character"
      else roundTrip

  it "accepts a 128-character database name (the identifier limit)" $ do
    -- 128 characters exactly.  On SQL Server, short explicit file names
    -- avoid hitting the filesystem's own path-length limit, which is
    -- unrelated to the identifier-length limit this test targets; Azure SQL
    -- Database has no file paths (InstanceDefaultDataPath is NULL).
    suffix <- uniqueName ""
    let prefix = "hmssql_test_maxlen"
        name = prefix <> T.replicate (128 - T.length prefix - T.length suffix) "y" <> suffix
    T.length name `shouldBe` 128
    azure <- testServerIsAzure
    files <- if azure then pure "" else do
      ci <- masterConnectInfo
      dataPath <- withConnection ci $ \conn ->
        fromOnly <$> query1 conn "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000))"
      let fileBase = (dataPath :: Text) <> "hmssql_test_maxlen_" <> suffix
      pure $ " ON PRIMARY (NAME = N'hmssql_test_maxlen_" <> suffix <> "', FILENAME = N'" <> fileBase <> ".mdf')"
        <> " LOG ON (NAME = N'hmssql_test_maxlen_" <> suffix <> "_log', FILENAME = N'" <> fileBase <> "_log.ldf')"
    withNamedDatabase name files $ \ci -> withConnection ci $ \conn ->
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only name

  skipOnAzure "ALTER DATABASE ... SET OFFLINE is refused (error 1468)" $
    it "a database taken offline is reported as LoginError 4060" $ do
    suffix <- uniqueName ""
    let name = "hmssql_test_offline_" <> suffix
    withNamedDatabase name "" $ \ci -> do
      withConnection ci { connectDatabase = "master" } $ \conn ->
        void $ execute conn (rawSql ("ALTER DATABASE " <> quoteName name <> " SET OFFLINE WITH ROLLBACK IMMEDIATE"))
      r <- try (withConnection ci (\_ -> pure ())) :: IO (Either SomeException ())
      refusalNumber r `shouldBe` Just 4060
      -- bring it back online so withNamedDatabase's teardown can drop it
      withConnection ci { connectDatabase = "master" } $ \conn ->
        void $ execute conn (rawSql ("ALTER DATABASE " <> quoteName name <> " SET ONLINE"))

  skipOnAzure "ALTER DATABASE ... SET SINGLE_USER is refused (error 1468)" $
    it "a single-user database already in use is reported as LoginError 4060" $ do
    suffix <- uniqueName ""
    let name = "hmssql_test_singleuser_" <> suffix
    withNamedDatabase name "" $ \ci -> do
      withConnection ci { connectDatabase = "master" } $ \conn ->
        void $ execute conn (rawSql ("ALTER DATABASE " <> quoteName name <> " SET SINGLE_USER"))
      withConnection ci $ \_holder -> do
        r <- try (withConnection ci (\_ -> pure ())) :: IO (Either SomeException ())
        refusalNumber r `shouldBe` Just 4060
      withConnection ci { connectDatabase = "master" } $ \conn ->
        void $ execute conn (rawSql ("ALTER DATABASE " <> quoteName name <> " SET MULTI_USER"))
