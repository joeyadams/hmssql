-- | Shapes of plain-batch requests and responses: empty/trivial batches,
-- result-set shapes (widths, empty sets, rowless statements, column names),
-- row-count semantics, and unusual SQL text.
module Shapes.BatchesSpec (spec) where

import Control.Exception (finally, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "empty and trivial batches" $ do
    it "runs an empty batch" $ \conn ->
      execute conn "" `shouldReturn` 0

    it "runs a whitespace-only batch" $ \conn ->
      execute conn "   \n\t  " `shouldReturn` 0

    it "runs a comment-only batch (line comment)" $ \conn ->
      execute conn "-- just a comment" `shouldReturn` 0

    it "runs a comment-only batch (block comment)" $ \conn ->
      execute conn "/* just\na comment */" `shouldReturn` 0

    it "runs several statements with no GO separators" $ \conn -> do
      sets <- queryMulti conn "SELECT 1\nSELECT 2\nSELECT 3"
      map (map sqlRowValues . resultRows) sets `shouldBe` [[[SqlInt32 1]], [[SqlInt32 2]], [[SqlInt32 3]]]

  describe "result set shapes" $ do
    it "skips a rowless statement between two result sets" $ \conn -> do
      sets <- queryMulti conn "SELECT 1; DECLARE @x int = 1; SELECT 2"
      map (map sqlRowValues . resultRows) sets `shouldBe` [[[SqlInt32 1]], [[SqlInt32 2]]]

    it "returns an empty result set with its column metadata intact" $ \conn -> do
      _ <- execute conn "CREATE TABLE #empty (a int, b nvarchar(10))"
      [ResultSet cols rows] <- queryMulti conn "SELECT a, b FROM #empty"
      map columnName cols `shouldBe` ["a", "b"]
      rows `shouldBe` []

    it "decodes a single-column result set" $ \conn ->
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

    it "decodes a result set with 1024 columns" $ \conn -> do
      let n = 1024 :: Int
          sql = "SELECT " <> T.intercalate ", " ["CAST(" <> T.pack (show i) <> " AS int) AS c" <> T.pack (show i) | i <- [1 .. n]]
      [ResultSet cols [row]] <- queryMulti conn (rawSql sql)
      length cols `shouldBe` n
      length (sqlRowValues row) `shouldBe` n
      sqlRowValues row `shouldBe` [SqlInt32 (fromIntegral i) | i <- [1 .. n]]

    it "decodes a result set with the maximum of 4096 columns" $ \conn -> do
      let n = 4096 :: Int
          sql = "SELECT " <> T.intercalate ", " ["CAST(" <> T.pack (show i) <> " AS int) AS c" <> T.pack (show i) | i <- [1 .. n]]
      [ResultSet cols _] <- queryMulti conn (rawSql sql)
      length cols `shouldBe` n

    it "reports a clean server error for 4097 columns" $ \conn -> do
      let n = 4097 :: Int
          sql = "SELECT " <> T.intercalate ", " ["CAST(" <> T.pack (show i) <> " AS int) AS c" <> T.pack (show i) | i <- [1 .. n]]
      r <- try (execute conn (rawSql sql))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 1056
        Right n' -> expectationFailure ("succeeded with " ++ show n')

    it "allows duplicate column names" $ \conn -> do
      r <- query1 conn "SELECT 1 AS a, 2 AS a" :: IO (Int, Int)
      r `shouldBe` (1, 2)
      [ResultSet cols _] <- queryMulti conn "SELECT 1 AS a, 2 AS a"
      map columnName cols `shouldBe` ["a", "a"]

    it "allows an unaliased column, whose name is empty" $ \conn -> do
      [ResultSet cols _] <- queryMulti conn "SELECT 1 + 1"
      map columnName cols `shouldBe` [""]

    it "allows a unicode column name" $ \conn -> do
      [ResultSet cols _] <- queryMulti conn "SELECT 1 AS [héllo世界]"
      map columnName cols `shouldBe` ["héllo世界"]

    it "allows a column name at the 128-character identifier limit" $ \conn -> do
      let name = T.replicate 128 "x"
      [ResultSet cols _] <- queryMulti conn (rawSql ("SELECT 1 AS [" <> name <> "]"))
      map columnName cols `shouldBe` [name]

    it "reports a clean server error for an identifier over 128 characters" $ \conn -> do
      let name = T.replicate 129 "x"
      r <- try (execute conn (rawSql ("SELECT 1 AS [" <> name <> "]")))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 103
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "row counts" $ do
    it "SET NOCOUNT ON suppresses the row count" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nc (i int)"
      n <- execute conn "SET NOCOUNT ON; INSERT INTO #nc VALUES (1), (2), (3)"
      n `shouldBe` 0

    it "SET NOCOUNT OFF (the default) reports the row count" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nc2 (i int)"
      n <- execute conn "SET NOCOUNT OFF; INSERT INTO #nc2 VALUES (1), (2), (3)"
      n `shouldBe` 3

    it "counts INSERT/UPDATE/DELETE rows" $ \conn -> do
      _ <- execute conn "CREATE TABLE #dml (i int)"
      execute conn "INSERT INTO #dml VALUES (1), (2), (3)" `shouldReturn` 3
      execute conn "UPDATE #dml SET i = i + 1 WHERE i > 1" `shouldReturn` 2
      execute conn "DELETE FROM #dml WHERE i > 2" `shouldReturn` 2

    it "counts MERGE rows across matched and not-matched branches" $ \conn -> do
      _ <- execute conn "CREATE TABLE #trg (id int PRIMARY KEY, v int)"
      _ <- execute conn "CREATE TABLE #src (id int, v int)"
      _ <- execute conn "INSERT INTO #trg VALUES (1, 10), (2, 20)"
      _ <- execute conn "INSERT INTO #src VALUES (1, 11), (3, 30)"
      n <- execute conn
        "MERGE #trg t USING #src s ON t.id = s.id \
        \WHEN MATCHED THEN UPDATE SET v = s.v \
        \WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v);"
      -- 1 update + 1 insert
      n `shouldBe` 2

    it "counts rows via an OUTPUT clause once" $ \conn -> do
      _ <- execute conn "CREATE TABLE #out (id int)"
      n <- execute conn "INSERT INTO #out OUTPUT inserted.id VALUES (1), (2), (3)"
      -- the row count reflects the INSERT, not a doubling from the OUTPUT result set
      n `shouldBe` 3

    it "execute sums the row counts of every statement in the batch" $ \conn -> do
      _ <- execute conn "CREATE TABLE #multi (i int)"
      n <- execute conn "INSERT INTO #multi VALUES (1); INSERT INTO #multi VALUES (2), (3)"
      n `shouldBe` 3

    it "counts a trigger's nested DML as part of the statement's total" $ \conn -> do
      tbl <- uniqueName "hmssql_shapes_trg"
      logTbl <- uniqueName "hmssql_shapes_trg_log"
      trg <- uniqueName "hmssql_shapes_trg_trigger"
      let cleanup = void $ execute conn $ rawSql
            ( "DROP TRIGGER IF EXISTS dbo." <> trg <> "; \
              \DROP TABLE IF EXISTS dbo." <> tbl <> "; \
              \DROP TABLE IF EXISTS dbo." <> logTbl )
      flip finally cleanup $ do
        _ <- execute conn (rawSql ("CREATE TABLE dbo." <> tbl <> " (id int)"))
        _ <- execute conn (rawSql ("CREATE TABLE dbo." <> logTbl <> " (id int)"))
        _ <- execute conn $ rawSql
          ( "CREATE TRIGGER dbo." <> trg <> " ON dbo." <> tbl <> " AFTER INSERT AS BEGIN \
            \INSERT INTO dbo." <> logTbl <> " SELECT id FROM inserted; END" )
        -- 2 rows inserted directly, plus 2 rows inserted by the trigger
        n <- execute conn (rawSql ("INSERT INTO dbo." <> tbl <> " VALUES (1), (2)"))
        n `shouldBe` 4
        query1 conn (rawSql ("SELECT COUNT(*) FROM dbo." <> logTbl)) `shouldReturn` Only (2 :: Int)

  describe "unusual SQL text" $ do
    it "runs a very long batch of SQL text" $ \conn -> do
      -- a long comment, rather than a deeply-nested expression, so the
      -- server's own parser isn't the bottleneck being tested
      let padding = T.replicate 200000 "-"
          sql = "/* " <> padding <> " */\nSELECT 42"
      query1 conn (rawSql sql) `shouldReturn` Only (42 :: Int)

    it "round-trips a non-BMP character (surrogate pair) in an nvarchar literal" $ \conn -> do
      Only t <- query1 conn "SELECT N'a' + NCHAR(0xD83D) + NCHAR(0xDE00) + N'b'"
      t `shouldBe` ("a\128512b" :: Text) -- U+1F600 GRINNING FACE

    it "round-trips an embedded NUL character in an nvarchar literal" $ \conn -> do
      Only t <- query1 conn "SELECT N'a' + NCHAR(0) + N'b'"
      t `shouldBe` ("a\0b" :: Text)
