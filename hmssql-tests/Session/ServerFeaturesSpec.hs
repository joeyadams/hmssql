-- | Server-side features that change a response's shape or values, exercised
-- through the public query API: metadata introspection, temporal tables,
-- sparse columns and column sets, JSON/string functions, window functions and
-- paging clauses, CTE recursion limits, sequences, @SELECT INTO@, @MERGE@
-- @OUTPUT@, @OUTPUT INTO@ with triggers, table variables, user-defined
-- functions, nested dynamic SQL, @WITH RESULT SETS@, cross-database queries,
-- synonyms, and schema-bound views.
module Session.ServerFeaturesSpec (spec) where

import Control.Exception (finally, try)
import Control.Monad (void)
import qualified Data.List
import Data.Int (Int32, Int64)
import qualified Data.Text as T
import Data.Time (LocalTime)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

-- | The index of the column named @name@.
lookupIdx :: T.Text -> [ColumnInfo] -> Int
lookupIdx name cols = length (takeWhile ((/= name) . columnName) cols)

spec :: Spec
spec = around withTestDb $ do
  describe "sp_describe_first_result_set" $
    it "describes the columns of a query without running it" $ \conn -> do
      res <- callProcedure conn "sp_describe_first_result_set"
        [inParam "@tsql" ("SELECT 1 AS a, CAST('x' AS nvarchar(10)) AS b" :: T.Text)]
      case procResultSets res of
        [ResultSet cols rows] -> do
          let nameIdx = lookupIdx "name" cols
              typeIdx = lookupIdx "system_type_name" cols
          length rows `shouldBe` 2
          [sqlRowValues r !! nameIdx | r <- rows] `shouldBe` [SqlText "a", SqlText "b"]
          [sqlRowValues r !! typeIdx | r <- rows] `shouldBe` [SqlText "int", SqlText "nvarchar(10)"]
        other -> expectationFailure ("result sets: " ++ show other)

  describe "temporal tables" $
    it "FOR SYSTEM_TIME AS OF returns historical rows; SELECT * hides the period columns" $ \conn -> do
      -- In a schema of its own, dropped afterwards with the table, its
      -- history table and the versioning between them.
      ci <- defaultTestConnectInfo
      withScratchSchema ci "temporal" $ \s -> do
        let t = s <> ".t"
        _ <- execute conn $ rawSql $
          "CREATE TABLE " <> t <> " (\
          \  id int PRIMARY KEY, v int, \
          \  ValidFrom datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL, \
          \  ValidTo datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL, \
          \  PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)) \
          \WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = " <> t <> "_history))"
        -- A version's period runs from the begin time of the transaction
        -- that wrote it to that of the one that replaced it, and the
        -- server's clock for these is coarse (it ticks every 5 ms or so on
        -- the Linux server, and under load has been seen not to tick in
        -- 50 ms): an INSERT and the UPDATE after it can get the same time.
        -- The old version is then zero-length, and every FOR SYSTEM_TIME
        -- form (even ALL) leaves it out.  So the times are read back as the
        -- server recorded them, the AS OF queries use them, and a
        -- zero-length version (the server's doing, not something hmssql can
        -- get wrong) is retried on a new row, rather than hoping that a
        -- delay is long enough.
        let versions :: Int -> IO (Int, LocalTime, LocalTime)
            versions k = do
              _ <- execute conn (mkQuery ("INSERT INTO " <> t <> " (id, v) VALUES (@p1, 100)") (Only k))
              _ <- execute conn "WAITFOR DELAY '00:00:00.05'"
              _ <- execute conn (mkQuery ("UPDATE " <> t <> " SET v = 200 WHERE id = @p1") (Only k))
              -- The history table has the old version however short it was.
              [(old, from, to)] <- query conn (mkQuery ("SELECT v, ValidFrom, ValidTo FROM " <> t <> "_history WHERE id = @p1") (Only k))
              old `shouldBe` (100 :: Int)
              Only start <- query1 conn (mkQuery ("SELECT ValidFrom FROM " <> t <> " WHERE id = @p1") (Only k))
              start `shouldBe` to
              if to > from
                then pure (k, from, to)
                else if k < 10 then versions (k + 1) else fail "10 zero-length versions in a row"
        (k, from, to) <- versions 1
        [ResultSet cols rows] <- queryMulti conn (mkQuery ("SELECT * FROM " <> t <> " WHERE id = @p1") (Only k))
        map columnName cols `shouldBe` ["id", "v"]
        map sqlRowValues rows `shouldBe` [[SqlInt32 (fromIntegral k), SqlInt32 200]]
        query conn (rawSql ("SELECT v FROM " <> t <> " FOR SYSTEM_TIME AS OF ") <> param from <> " WHERE id = " <> param k) `shouldReturn` [Only (100 :: Int)]
        query conn (rawSql ("SELECT v FROM " <> t <> " FOR SYSTEM_TIME AS OF ") <> param to <> " WHERE id = " <> param k) `shouldReturn` [Only (200 :: Int)]
        query conn (mkQuery ("SELECT v FROM " <> t <> " FOR SYSTEM_TIME ALL WHERE id = @p1 ORDER BY v") (Only k)) `shouldReturn` [Only 100, Only (200 :: Int)]

  describe "sparse columns and a column set" $
    it "the column set is an xml document of the sparse columns actually set" $ \conn -> do
      _ <- execute conn
        "CREATE TABLE #sparse (id int PRIMARY KEY, a int SPARSE NULL, b nvarchar(50) SPARSE NULL, \
        \cs xml COLUMN_SET FOR ALL_SPARSE_COLUMNS)"
      _ <- execute conn "INSERT INTO #sparse (id, a, b) VALUES (1, 42, N'hi'), (2, NULL, NULL)"
      rows <- query conn "SELECT id, a, b, cs FROM #sparse ORDER BY id"
        :: IO [(Int, Maybe Int32, Maybe T.Text, Maybe T.Text)]
      rows `shouldBe`
        [ (1, Just 42, Just "hi", Just "<a>42</a><b>hi</b>")
        , (2, Nothing, Nothing, Nothing)
        ]

  describe "OPENJSON / JSON_VALUE" $ do
    it "OPENJSON WITH a schema decodes typed columns" $ \conn -> do
      row <- query1 conn
        "SELECT * FROM OPENJSON(N'{\"a\":1,\"b\":\"x\"}') WITH (a int, b nvarchar(10))"
        :: IO (Int32, T.Text)
      row `shouldBe` (1, "x")

    it "JSON_VALUE extracts a scalar from a JSON document" $ \conn ->
      query1 conn "SELECT JSON_VALUE(N'{\"a\":{\"b\":42}}', '$.a.b')" `shouldReturn` Only ("42" :: T.Text)

  -- SQL Server 2022 added both: STRING_SPLIT's third argument, and
  -- GENERATE_SERIES.  SQL Server 2019 answers with errors 8144 and 208.
  describe "STRING_SPLIT / GENERATE_SERIES" $ skipBeforeSql2022 "STRING_SPLIT's ordinal and GENERATE_SERIES" $ do
    it "STRING_SPLIT with the ordinal column preserves input order" $ \conn -> do
      rows <- query conn "SELECT value, ordinal FROM STRING_SPLIT('a,b,c', ',', 1) ORDER BY ordinal"
        :: IO [(T.Text, Int32)]
      rows `shouldBe` [("a", 1), ("b", 2), ("c", 3)]

    it "GENERATE_SERIES produces the inclusive range" $ \conn -> do
      rows <- query conn "SELECT value FROM GENERATE_SERIES(1, 5)" :: IO [Only Int32]
      rows `shouldBe` map Only [1 .. 5]

  describe "window functions returning a large result" $
    it "decodes 50000 rows of a windowed aggregate" $ \conn -> do
      _ <- execute conn "CREATE TABLE #win (grp int, v int)"
      _ <- execute conn
        "INSERT INTO #win SELECT n % 5, n FROM \
        \(SELECT TOP (50000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n \
        \ FROM sys.all_columns a CROSS JOIN sys.all_columns b) t"
      rows <- query conn
        "SELECT v, SUM(v) OVER (PARTITION BY grp) AS s FROM #win ORDER BY v"
        :: IO [(Int32, Int64)]
      length rows `shouldBe` 50000
      -- every row of group (v % 5) shares the same partition sum
      case [s | (v, s) <- rows, v `mod` 5 == 0] of
        [] -> expectationFailure "no rows in group 0"
        (s0 : rest) -> length (filter (/= s0) rest) `shouldBe` 0

  describe "OFFSET/FETCH and TOP WITH TIES" $ do
    it "OFFSET/FETCH pages a sorted result" $ \conn -> do
      _ <- execute conn "CREATE TABLE #page (v int)"
      _ <- execute conn "INSERT INTO #page SELECT v FROM (VALUES (1),(2),(3),(4),(5)) t(v)"
      rows <- query conn "SELECT v FROM #page ORDER BY v OFFSET 2 ROWS FETCH NEXT 2 ROWS ONLY" :: IO [Only Int]
      rows `shouldBe` [Only 3, Only 4]

    it "TOP WITH TIES includes every row tied with the last one" $ \conn -> do
      _ <- execute conn "CREATE TABLE #ties (v int)"
      _ <- execute conn "INSERT INTO #ties SELECT v FROM (VALUES (1),(2),(2),(3)) t(v)"
      rows <- query conn "SELECT TOP (2) WITH TIES v FROM #ties ORDER BY v" :: IO [Only Int]
      rows `shouldBe` [Only 1, Only 2, Only 2]

  describe "CTE recursion and MAXRECURSION" $
    it "reports error 530 when the recursion limit is exceeded" $ \conn -> do
      r <- try (query1 conn
        "WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 200) \
        \SELECT COUNT(*) FROM r OPTION (MAXRECURSION 10)") :: IO (Either SqlServerError (Only Int))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 530
        Right v -> expectationFailure ("succeeded: " ++ show v)

  describe "sequences" $
    it "NEXT VALUE FOR advances per call, and repeats within one row for the same statement" $ \conn -> do
      name <- uniqueName "hmssql_seq"
      let seqName = "dbo." <> name
      _ <- execute conn (rawSql ("CREATE SEQUENCE " <> seqName <> " AS int START WITH 1 INCREMENT BY 1"))
      flip finally (void (execute conn (rawSql ("DROP SEQUENCE " <> seqName)))) $ do
        -- two references to the same sequence in one SELECT share a value per row
        row1 <- query1 conn (rawSql ("SELECT NEXT VALUE FOR " <> seqName <> ", NEXT VALUE FOR " <> seqName)) :: IO (Int32, Int32)
        row1 `shouldBe` (1, 1)
        -- a later statement advances it
        row2 <- query1 conn (rawSql ("SELECT NEXT VALUE FOR " <> seqName)) :: IO (Only Int32)
        row2 `shouldBe` Only 2

  describe "SELECT ... INTO #t" $
    it "reports the number of rows copied" $ \conn -> do
      n <- execute conn "SELECT v INTO #sinto FROM (VALUES (1),(2),(3)) t(v)"
      n `shouldBe` 3
      query1 conn "SELECT COUNT(*) FROM #sinto" `shouldReturn` Only (3 :: Int)

  describe "MERGE with OUTPUT $action" $
    it "reports which branch fired for each row" $ \conn -> do
      _ <- execute conn "CREATE TABLE #trg (id int PRIMARY KEY, v int)"
      _ <- execute conn "CREATE TABLE #src (id int, v int)"
      _ <- execute conn "INSERT INTO #trg VALUES (1, 10), (2, 20)"
      _ <- execute conn "INSERT INTO #src VALUES (1, 11), (3, 30)"
      rows <- query conn
        "MERGE #trg t USING #src s ON t.id = s.id \
        \WHEN MATCHED THEN UPDATE SET v = s.v \
        \WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v) \
        \OUTPUT $action, s.id;"
        :: IO [(T.Text, Int32)]
      -- order isn't guaranteed by MERGE; compare as a sorted list
      Data.List.sort rows `shouldBe` [("INSERT", 3), ("UPDATE", 1)]

  describe "OUTPUT INTO with a trigger on the target" $ do
    it "OUTPUT without INTO is refused (error 334) when the target has a trigger" $ \conn -> do
      tbl <- uniqueName "hmssql_trg_tbl"
      trg <- uniqueName "hmssql_trg"
      let cleanup = void (execute conn (rawSql ("DROP TRIGGER IF EXISTS dbo." <> trg <> "; DROP TABLE IF EXISTS dbo." <> tbl)))
      flip finally cleanup $ do
        _ <- execute conn (rawSql ("CREATE TABLE dbo." <> tbl <> " (id int IDENTITY PRIMARY KEY, v int)"))
        _ <- execute conn (rawSql ("CREATE TRIGGER dbo." <> trg <> " ON dbo." <> tbl <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; END"))
        r <- try (execute conn (mkQuery ("INSERT INTO dbo." <> tbl <> " (v) OUTPUT inserted.id, inserted.v VALUES (@p1)") (Only (10 :: Int32))))
          :: IO (Either SqlServerError Int64)
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 334
          Right n -> expectationFailure ("succeeded: " ++ show n)

    it "OUTPUT INTO a table variable is allowed with a trigger present" $ \conn -> do
      tbl <- uniqueName "hmssql_trg_tbl2"
      trg <- uniqueName "hmssql_trg2"
      let cleanup = void (execute conn (rawSql ("DROP TRIGGER IF EXISTS dbo." <> trg <> "; DROP TABLE IF EXISTS dbo." <> tbl)))
      flip finally cleanup $ do
        _ <- execute conn (rawSql ("CREATE TABLE dbo." <> tbl <> " (id int IDENTITY PRIMARY KEY, v int)"))
        _ <- execute conn (rawSql ("CREATE TRIGGER dbo." <> trg <> " ON dbo." <> tbl <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; END"))
        row <- query conn
          ( mkQuery
              ( "DECLARE @t TABLE (id int, v int); \
                \INSERT INTO dbo." <> tbl <> " (v) OUTPUT inserted.id, inserted.v INTO @t VALUES (@p1); \
                \SELECT id, v FROM @t" )
              (Only (20 :: Int32)) )
          :: IO [(Int32, Int32)]
        row `shouldBe` [(1, 20)]

  describe "table variables" $
    it "hold rows across statements in a batch and support DML" $ \conn -> do
      rows <- query conn
        "DECLARE @t TABLE (i int PRIMARY KEY, v int); \
        \INSERT INTO @t VALUES (1, 10), (2, 20); \
        \UPDATE @t SET v = v + 1 WHERE i = 1; \
        \SELECT i, v FROM @t ORDER BY i"
        :: IO [(Int32, Int32)]
      rows `shouldBe` [(1, 11), (2, 20)]

  describe "user-defined functions" $ do
    it "a scalar UDF is callable in a SELECT" $ \conn -> do
      name <- uniqueName "hmssql_scalar_fn"
      _ <- execute conn (rawSql ("CREATE FUNCTION dbo." <> name <> " (@a int, @b int) RETURNS int AS BEGIN RETURN @a + @b END"))
      flip finally (void (execute conn (rawSql ("DROP FUNCTION dbo." <> name)))) $
        query1 conn (rawSql ("SELECT dbo." <> name <> "(2, 3)")) `shouldReturn` Only (5 :: Int32)

    it "an inline table-valued function returns rows" $ \conn -> do
      name <- uniqueName "hmssql_itvf"
      _ <- execute conn
        (rawSql ("CREATE FUNCTION dbo." <> name <> " (@n int) RETURNS TABLE AS RETURN (SELECT v FROM (VALUES (1),(2),(3)) t(v) WHERE v <= @n)"))
      flip finally (void (execute conn (rawSql ("DROP FUNCTION dbo." <> name)))) $ do
        rows <- query conn (rawSql ("SELECT v FROM dbo." <> name <> "(2)")) :: IO [Only Int32]
        rows `shouldBe` [Only 1, Only 2]

    it "a multi-statement table-valued function returns rows built up in its body" $ \conn -> do
      name <- uniqueName "hmssql_mstvf"
      _ <- execute conn
        (rawSql ("CREATE FUNCTION dbo." <> name <> " (@n int) RETURNS @r TABLE (v int) AS BEGIN \
         \INSERT INTO @r SELECT TOP (@n) v FROM (VALUES (1),(2),(3),(4)) t(v); RETURN END"))
      flip finally (void (execute conn (rawSql ("DROP FUNCTION dbo." <> name)))) $ do
        rows <- query conn (rawSql ("SELECT v FROM dbo." <> name <> "(2)")) :: IO [Only Int32]
        rows `shouldBe` [Only 1, Only 2]

  describe "EXEC('dynamic SQL') and nested sp_executesql" $ do
    it "EXEC of a dynamic string returns the statement's own result set" $ \conn -> do
      Only (v :: Int32) <- query1 conn "EXEC('SELECT 1 + 1 AS x')"
      v `shouldBe` 2

    it "sp_executesql nested inside sp_executesql produces both statements' results" $ \conn -> do
      sets <- queryMulti conn
        "EXEC sp_executesql N'EXEC sp_executesql N''SELECT 1 AS inner_x''; SELECT 2 AS outer_x'"
      map (map sqlRowValues . resultRows) sets `shouldBe` [[[SqlInt32 1]], [[SqlInt32 2]]]

  describe "EXEC ... WITH RESULT SETS" $
    it "renames and retypes the procedure's result columns" $ \conn -> do
      name <- uniqueName "hmssql_wrs"
      _ <- execute conn (rawSql ("CREATE PROCEDURE dbo." <> name <> " AS BEGIN SELECT 1 AS a, 'x' AS b END"))
      flip finally (void (execute conn (rawSql ("DROP PROCEDURE dbo." <> name)))) $ do
        [ResultSet cols rows] <- queryMulti conn
          (rawSql ("EXEC dbo." <> name <> " WITH RESULT SETS ((c1 bigint, c2 nvarchar(50)))"))
        map columnName cols `shouldBe` ["c1", "c2"]
        map sqlRowValues rows `shouldBe` [[SqlInt64 1, SqlText "x"]]

  describe "cross-database queries" $
    skipOnAzure "no three-part names into another database (error 40515)" $
    it "a three-part name reaches a table in a different database on the same connection" $ \conn -> do
      -- The companion database.
      ci <- companionConnectInfo
      xt <- uniqueName "hmssql_xdb"
      withConnection ci $ \other ->
        void $ execute other (rawSql ("CREATE TABLE dbo." <> xt <> " (v int); INSERT INTO dbo." <> xt <> " VALUES (1),(2)"))
      let db = connectDatabase ci
      flip finally (withConnection ci $ \other -> void $ execute other (rawSql ("DROP TABLE IF EXISTS dbo." <> xt))) $ do
        n <- fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> quoteName db <> ".dbo." <> xt)) :: IO Int
        n `shouldBe` 2

  describe "synonyms" $
    it "a synonym resolves to its target table" $ \conn -> do
      tbl <- uniqueName "hmssql_syn_tbl"
      syn <- uniqueName "hmssql_syn"
      _ <- execute conn (rawSql ("CREATE TABLE dbo." <> tbl <> " (v int); INSERT INTO dbo." <> tbl <> " VALUES (42)"))
      _ <- execute conn (rawSql ("CREATE SYNONYM dbo." <> syn <> " FOR dbo." <> tbl))
      flip finally
        (void (execute conn (rawSql ("DROP SYNONYM IF EXISTS dbo." <> syn <> "; DROP TABLE IF EXISTS dbo." <> tbl)))) $
        query1 conn (rawSql ("SELECT v FROM dbo." <> syn)) `shouldReturn` Only (42 :: Int32)

  describe "views with SCHEMABINDING" $
    it "a schema-bound view selects from its base table normally" $ \conn -> do
      tbl <- uniqueName "hmssql_sb_tbl"
      vw <- uniqueName "hmssql_sb_view"
      _ <- execute conn (rawSql ("CREATE TABLE dbo." <> tbl <> " (id int NOT NULL PRIMARY KEY, v int NOT NULL)"))
      _ <- execute conn (rawSql ("INSERT INTO dbo." <> tbl <> " VALUES (1, 100)"))
      _ <- execute conn
        ( rawSql
            ( "CREATE VIEW dbo." <> vw <> " WITH SCHEMABINDING AS \
              \SELECT id, v FROM dbo." <> tbl ) )
      flip finally
        (void (execute conn (rawSql ("DROP VIEW IF EXISTS dbo." <> vw <> "; DROP TABLE IF EXISTS dbo." <> tbl)))) $
        query1 conn (rawSql ("SELECT v FROM dbo." <> vw <> " WHERE id = 1")) `shouldReturn` Only (100 :: Int32)
