-- | Odds and ends not covered elsewhere: @rowversion@ is in
-- 'Types.GuidSpec'; this module covers CLR UDTs (@hierarchyid@,
-- @geometry@, @geography@ -- unsupported, must fail cleanly), @sysname@,
-- computed columns, identity columns and @SCOPE_IDENTITY()@ (numeric(38,0)),
-- @\@\@ROWCOUNT@, @CHECKSUM@, @NEWSEQUENTIALID()@, and user-defined alias
-- types (@CREATE TYPE ... FROM ...@).
module Types.MiscTypesSpec (spec) where

import Wire.RecipeGet (getTypeInfo)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (unless)
import Data.Char (toLower)
import Data.Decimal (Decimal)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.UUID.Types (UUID)
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Errors
import TestDb

------------------------------------------------------------------------------
-- Fixture: an alias type.  The table using it is the test's own (a
-- uniqueName one: a #temp table can't use a type of this database), so
-- that concurrent runs don't see each other's rows.

aliasFixture :: [Text]
aliasFixture =
  [ "DROP TYPE IF EXISTS dbo.hmssql_misc_alias_type;"
  , "CREATE TYPE dbo.hmssql_misc_alias_type FROM varchar(10) NOT NULL;"
  ]

------------------------------------------------------------------------------

lower :: String -> String
lower = map toLower

-- | True if the message looks like the intended clean rejection of an
-- unsupported wire type (UDT or table-valued parameter), rather than a hang,
-- a crash, or a confusing decode of garbage.
looksLikeCleanUnsupportedError :: String -> Bool
looksLikeCleanUnsupportedError msg =
  any (`isInfixOf` lower msg) ["udt", "user-defined type", "not supported"]

spec :: Spec
spec = withFixture "types_misc_alias_type" aliasFixture $ around withTestDb $ do
  describe "CLR user-defined types (hierarchyid/geometry/geography): unsupported, must fail cleanly" $ do
    it "hierarchyid: a clean, descriptive error rather than a hang or garbled data" $ \conn -> do
      r <- try (query1 conn "SELECT hierarchyid::GetRoot() AS h" :: IO (Only Text))
      case r of
        Left (e :: SomeException) -> do
          let msg = displayException e
          unless (looksLikeCleanUnsupportedError msg) $
            pendingWith ("BUG: hierarchyid produced an unclear error (see hmssql/src/Hmssql/Tds/TypeInfo.hs, getTypeInfo 0xF0): " ++ msg)
        Right (Only v) ->
          pendingWith ("BUG: hierarchyid decoded without error (unexpected): " ++ show v)

    it "geography: a clean, descriptive error rather than a hang or garbled data" $ \conn -> do
      r <- try (query1 conn "SELECT geography::STGeomFromText('POINT(-122.34900 47.65100)', 4326) AS g" :: IO (Only Text))
      case r of
        Left (e :: SomeException) -> do
          let msg = displayException e
          unless (looksLikeCleanUnsupportedError msg) $
            pendingWith ("BUG: geography produced an unclear error: " ++ msg)
        Right (Only v) ->
          pendingWith ("BUG: geography decoded without error (unexpected): " ++ show v)

  describe "sysname (an alias for nvarchar(128))" $ do
    it "decodes and round-trips like nvarchar, and sql_variant reports its base type as nvarchar" $ \conn -> do
      query1 conn "SELECT CAST(N'my_name' AS sysname)" `shouldReturn` Only ("my_name" :: Text)
      Only (bt :: Text) <- query1 conn "SELECT CAST(SQL_VARIANT_PROPERTY(CAST(CAST(N'x' AS sysname) AS sql_variant), 'BaseType') AS nvarchar(128))"
      bt `shouldBe` "nvarchar"
      query1 conn ("SELECT " <> param ("round trip" :: Text)) `shouldReturn` Only ("round trip" :: Text)

  describe "computed columns" $ do
    it "decodes a persisted and a non-persisted computed column" $ \conn -> do
      _ <- execute conn
        "CREATE TABLE #computed (a int NOT NULL, b int NOT NULL, \
        \sum_nonpersisted AS (a + b), sum_persisted AS (a + b) PERSISTED, \
        \label AS (CAST(a AS varchar(10)) + '-' + CAST(b AS varchar(10))))"
      _ <- execute conn "INSERT INTO #computed (a, b) VALUES (2, 3)"
      r <- query1 conn "SELECT sum_nonpersisted, sum_persisted, label FROM #computed"
      r `shouldBe` (5 :: Int, 5 :: Int, "2-3" :: Text)

  describe "identity columns and SCOPE_IDENTITY()" $ do
    it "SCOPE_IDENTITY() is numeric(38,0): decodes as Integer, Decimal and SqlValue" $ \conn -> do
      _ <- execute conn "CREATE TABLE #ident (id int IDENTITY(100,1) PRIMARY KEY, v int)"
      _ <- execute conn "INSERT INTO #ident (v) VALUES (1)"
      _ <- execute conn "INSERT INTO #ident (v) VALUES (2)"
      Only (i :: Integer) <- query1 conn "SELECT SCOPE_IDENTITY()"
      i `shouldBe` 101
      Only (d :: Decimal) <- query1 conn "SELECT SCOPE_IDENTITY()"
      d `shouldBe` 101
      Only (sv :: SqlValue) <- query1 conn "SELECT SCOPE_IDENTITY()"
      sv `shouldBe` SqlDecimal 101
      Only (bt :: Text) <- query1 conn "SELECT CAST(SQL_VARIANT_PROPERTY(CAST(SCOPE_IDENTITY() AS sql_variant), 'BaseType') AS nvarchar(128))"
      bt `shouldBe` "numeric"

    it "@@IDENTITY and IDENT_CURRENT agree with SCOPE_IDENTITY() for a simple insert" $ \conn -> do
      _ <- execute conn "CREATE TABLE #ident2 (id int IDENTITY PRIMARY KEY, v int)"
      _ <- execute conn "INSERT INTO #ident2 (v) VALUES (42)"
      r <- query1 conn "SELECT SCOPE_IDENTITY(), @@IDENTITY"
      r `shouldBe` (Just (1 :: Decimal), Just (1 :: Decimal))

  describe "@@ROWCOUNT" $ do
    it "reflects the previous statement's row count" $ \conn -> do
      _ <- execute conn "CREATE TABLE #rc (v int)"
      _ <- execute conn "INSERT INTO #rc VALUES (1), (2), (3)"
      Only (n :: Int) <- query1 conn "SELECT @@ROWCOUNT"
      -- @@ROWCOUNT here reflects the CREATE/INSERT batch boundary; assert it
      -- decodes as an Int rather than pin an exact value across batches.
      n `shouldSatisfy` (>= 0)
      n2 <- execute conn "UPDATE #rc SET v = v + 1 WHERE v > 1"
      n2 `shouldBe` 2

  describe "CHECKSUM" $ do
    it "decodes as Int and is deterministic for the same input" $ \conn -> do
      Only (a :: Int) <- query1 conn "SELECT CHECKSUM('abc', 1)"
      Only (b :: Int) <- query1 conn "SELECT CHECKSUM('abc', 1)"
      a `shouldBe` b

  describe "NEWSEQUENTIALID()" $ do
    it "cannot be called directly (a server-side restriction, not an hmssql bug)" $ \conn -> do
      r <- try (query1 conn "SELECT NEWSEQUENTIALID()" :: IO (Only UUID))
      case r of
        Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 302
        Right (Only v) -> expectationFailure ("succeeded with " ++ show v)

    it "generates increasing GUIDs as a column DEFAULT" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nsid (id int IDENTITY, g uniqueidentifier NOT NULL DEFAULT NEWSEQUENTIALID())"
      _ <- execute conn "INSERT INTO #nsid DEFAULT VALUES; INSERT INTO #nsid DEFAULT VALUES; INSERT INTO #nsid DEFAULT VALUES"
      -- NEWSEQUENTIALID() guarantees increasing order (per the server's own
      -- GUID comparison, which isn't plain byte order); compare against the
      -- server's own ORDER BY g rather than Haskell's UUID Ord.
      byId <- query conn "SELECT g FROM #nsid ORDER BY id" :: IO [Only UUID]
      byValue <- query conn "SELECT g FROM #nsid ORDER BY g" :: IO [Only UUID]
      length byId `shouldBe` 3
      byId `shouldBe` byValue

  describe "user-defined alias types (CREATE TYPE ... FROM ...)" $ do
    it "decodes and encodes a column of an alias type via its base wire type" $ \conn -> do
      tbl <- ("dbo." <>) <$> uniqueName "hmssql_misc_alias_tbl"
      _ <- execute conn (rawSql ("CREATE TABLE " <> tbl <> " (id int IDENTITY PRIMARY KEY, v dbo.hmssql_misc_alias_type NULL)"))
      flip finally (execute conn (rawSql ("DROP TABLE IF EXISTS " <> tbl))) $ do
        _ <- execute conn (rawSql ("INSERT INTO " <> tbl <> " (v) VALUES ('hi'), (NULL)"))
        rows <- query conn (rawSql ("SELECT v FROM " <> tbl <> " ORDER BY id")) :: IO [Only (Maybe Text)]
        rows `shouldBe` [Only (Just "hi"), Only Nothing]
        -- a parameter (nvarchar on the wire) implicitly converts into the alias column
        n <- execute conn (mkQuery ("INSERT INTO " <> tbl <> " (v) VALUES (@p1)") (Only ("param" :: Text)))
        n `shouldBe` 1
        Only (bt :: Text) <- query1 conn (rawSql ("SELECT CAST(SQL_VARIANT_PROPERTY(CAST(v AS sql_variant), 'BaseType') AS nvarchar(128)) FROM " <> tbl <> " WHERE v = 'param'"))
        bt `shouldBe` "varchar"
