-- | Login-time credential edge cases: wrong/empty/unicode passwords, disabled
-- accounts, missing database access, and password-expiration policies.
--
-- Each test creates its own server-level login named @hmssql_test_login_*@
-- (via 'uniqueName', so concurrent test runs never collide) and drops it
-- afterwards.  The passwords satisfy the password policy, which Azure SQL
-- Database enforces (its @CREATE LOGIN@ has no @CHECK_POLICY@, error 40517);
-- on SQL Server the logins are created with @CHECK_POLICY = OFF@ all the
-- same, so that a machine's policy can't fail them.
module Connection.CredentialsSpec (spec) where

import Control.Exception (SomeException, bracket, fromException, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import TestDb

-- | @N'...'@ with embedded quotes doubled.
sqlLit :: Text -> Text
sqlLit t = "N'" <> T.replace "'" "''" t <> "'"

defaultPassword :: Text
defaultPassword = "Aa1!Aa1!Aa1!"

-- | Create a uniquely-named login (password 'defaultPassword', policy
-- checking off unless @extraSetup@ turns it back on), run @extraSetup@ (a
-- single batch, given the login's name) right after, run the action with
-- that name, then drop the login (and any matching user in the shared test
-- database) even on failure.
withLogin :: (Text -> Text) -> (Text -> IO a) -> IO a
withLogin = withLoginPassword defaultPassword

-- | Like 'withLogin', but with an explicit password (embedded as a quoted
-- SQL literal via 'sqlLit', which is injection-safe: it only needs to escape
-- single quotes, and CREATE LOGIN's PASSWORD clause takes any nvarchar
-- expression).
withLoginPassword :: Text -> (Text -> Text) -> (Text -> IO a) -> IO a
withLoginPassword = withLoginNamed "hmssql_test_login"

-- | 'withLoginPassword', with a name that starts with the given prefix
-- (and ends with a 'uniqueName' suffix).
withLoginNamed :: Text -> Text -> (Text -> Text) -> (Text -> IO a) -> IO a
withLoginNamed prefix password extraSetup act = bracket acquire dropLogin act
  where
    acquire = do
      name <- uniqueName prefix
      azure <- testServerIsAzure
      ci <- masterConnectInfo
      withConnection ci $ \conn -> void $ execute conn $ rawSql
        ( "CREATE LOGIN " <> quoteName name <> " WITH PASSWORD = " <> sqlLit password
            <> (if azure then "" else ", CHECK_POLICY = OFF") <> ";\n"
            <> extraSetup name )
      pure name

    -- The user first, on a connection to the test database (no USE on
    -- Azure), then the login.
    dropLogin name = do
      withTestDb $ \conn -> void $ execute conn (rawSql ("DROP USER IF EXISTS " <> quoteName name))
      ci <- masterConnectInfo
      withConnection ci $ \conn -> void $ execute conn $ rawSql
        ( "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " <> sqlLit name <> ") DROP LOGIN " <> quoteName name <> ";" )

-- | 'withLoginPassword', with a user for the login in the shared test
-- database.
withLoginUser :: Text -> (Text -> IO a) -> IO a
withLoginUser = withLoginUserNamed "hmssql_test_login"

-- | 'withLoginUser', with a name that starts with the given prefix.
withLoginUserNamed :: Text -> Text -> (Text -> IO a) -> IO a
withLoginUserNamed prefix password act = withLoginNamed prefix password (const "") $ \name -> do
  withTestDb $ \conn -> void $ execute conn
    (rawSql ("CREATE USER " <> quoteName name <> " FOR LOGIN " <> quoteName name))
  act name

-- | Try to connect as the given login/password/database, returning the
-- 'LoginError' if login failed with one.
connectAs :: Text -> Text -> Text -> IO (Either SomeException (Only Text))
connectAs user password db = do
  ci <- masterConnectInfo
  try $ withConnection ci { connectUser = user, connectPassword = password, connectDatabase = db } $ \conn ->
    query1 conn "SELECT SUSER_SNAME()"

-- | The 'msgNumber' of a 'LoginError', or 'Nothing' if the result wasn't one.
refusalNumber :: Either SomeException a -> Maybe Int
refusalNumber (Left e) = fromIntegral . loginErrorNumber <$> fromException e
refusalNumber (Right _) = Nothing

spec :: Spec
spec = describe "login-time credential errors" $ do
  it "reports a wrong password as LoginError 18456" $
    withLogin (const "") $ \user -> do
      db <- testDatabaseName
      r <- connectAs user "wrong password" db
      refusalNumber r `shouldBe` Just 18456

  it "reports an unknown user as LoginError 18456 (same as a wrong password)" $ do
    name <- uniqueName "hmssql_test_login_nosuch"
    db <- testDatabaseName
    r <- connectAs name "whatever" db
    refusalNumber r `shouldBe` Just 18456

  it "reports an empty password as LoginError 18456" $
    withLogin (const "") $ \user -> do
      db <- testDatabaseName
      r <- connectAs user "" db
      refusalNumber r `shouldBe` Just 18456

  it "reports a disabled login as LoginError 18470" $
    withLogin (\name -> "ALTER LOGIN " <> quoteName name <> " DISABLE;") $ \user -> do
      db <- testDatabaseName
      r <- connectAs user defaultPassword db
      refusalNumber r `shouldBe` Just 18470

  it "reports a login without access to the requested database as LoginError 4064 (916 on Azure SQL Database)" $ do
    -- No CREATE USER in the test database, so the login has no database to
    -- use other than master (which every login can reach via the public
    -- role).  Requesting the test database as the login's default database
    -- fails the login outright (4064) rather than silently falling back.
    -- Azure SQL Database has no DEFAULT_DATABASE (every login lands in
    -- master), so there the database is requested by name, and the login
    -- fails with 916 ("not able to access the database under the current
    -- security context").
    azure <- testServerIsAzure
    db <- testDatabaseName
    let defaultDb name = if azure then "" else "ALTER LOGIN " <> quoteName name <> " WITH DEFAULT_DATABASE = " <> quoteName db <> ";"
    withLogin defaultDb $ \user -> do
      r <- connectAs user defaultPassword (if azure then db else "")
      refusalNumber r `shouldBe` Just (if azure then 916 else 4064)

  skipOnAzure "no CHECK_EXPIRATION or MUST_CHANGE" $
    it "reports a login requiring a password change as LoginError 18488 (MUST_CHANGE)" $
      withLogin (\name -> "ALTER LOGIN " <> quoteName name
                   <> " WITH CHECK_POLICY = ON, CHECK_EXPIRATION = ON; ALTER LOGIN " <> quoteName name <> " WITH PASSWORD = "
                   <> sqlLit defaultPassword <> " MUST_CHANGE;") $ \user -> do
        db <- testDatabaseName
        r <- connectAs user defaultPassword db
        refusalNumber r `shouldBe` Just 18488

  describe "passwords hmssql must send byte-for-byte" $
    -- LOGIN7 passwords are "obfuscated" ([MS-TDS] 2.2.6.4) rather than
    -- hashed, so any mis-encoding (wrong endianness, truncated UTF-16,
    -- mishandled high surrogate pairs) would show up as a login failure
    -- against a real server.
    mapM_
      (\(label, password) ->
        it ("logs in with a " ++ label ++ " password") $
          withLoginUser password $ \user -> do
            db <- testDatabaseName
            r <- connectAs user password db
            case r of
              Right (Only name) -> name `shouldBe` user
              Left e -> expectationFailure ("failed to log in: " ++ show e))
      [ ("password containing quotes", "pa'ss\"word''1Aa!")
      , ("password containing unicode", "pässwörd日本語Ω✓1Aa!")
      , ("128-character password", T.take 128 (T.replicate 20 "Ab3!xyzQ"))
      ]

  describe "login names hmssql must send byte-for-byte" $
    -- The user name travels in LOGIN7 as UTF-16 ([MS-TDS] 2.2.6.4), as
    -- the database name does ("Connection.Database" connects to databases
    -- named outside ASCII).
    mapM_
      (\(label, prefix) ->
        it ("logs in as a login whose name has " ++ label) $
          withLoginUserNamed prefix defaultPassword $ \user -> do
            db <- testDatabaseName
            r <- connectAs user defaultPassword db
            case r of
              Right (Only name) -> name `shouldBe` user
              Left e -> expectationFailure ("failed to log in: " ++ show e))
      [ ("letters outside ASCII", "hmssql_test_login_ünïcödé_日本語_Ωμέγα")
      , ("a character outside the BMP (a surrogate pair in UTF-16)", "hmssql_test_login_𝄞")
      ]
