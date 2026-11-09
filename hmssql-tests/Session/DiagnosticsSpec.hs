-- | Diagnostic\/compile-only @SET@ options and how they change a response's
-- shape: @STATISTICS IO\/TIME@ (interleaved INFO messages), @STATISTICS
-- XML\/PROFILE@ (an extra result set per statement), @SHOWPLAN_XML\/TEXT\/ALL@
-- (the statement is not executed; a plan is returned instead, including for a
-- parameterized query), @FMTONLY@ (metadata only, no rows), @PARSEONLY@ and
-- @NOEXEC@ (nothing executes, no result sets).
module Session.DiagnosticsSpec (spec) where

import Control.Exception (try)
import Data.Int (Int32, Int64)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Tds.Value (rowValues)
import Hmssql.Tds.Token (Token (..))
import TestDb

-- | Every token of one plain-batch request.
tokensOf :: Connection -> T.Text -> IO [Token]
tokensOf conn sql = responseS conn (batchRequest sql) >>= S.toList_

spec :: Spec
spec = around withTestDb $ do
  describe "SET STATISTICS IO / TIME" $
    it "interleaves INFO messages with the query's own result, without disturbing it" $ \conn -> do
      toks <- tokensOf conn "SET STATISTICS IO ON; SET STATISTICS TIME ON; \
                            \SELECT 1 AS x; SET STATISTICS IO OFF; SET STATISTICS TIME OFF"
      let rows = [rowValues row | TRow row <- toks]
          infos = [msgText m | TInfo m <- toks]
      rows `shouldBe` [[Just "\SOH\NUL\NUL\NUL"]]
      -- "SQL Server Execution Times" appears (at least) for the SELECT and
      -- for the whole batch; hmssql must decode the query's row despite the
      -- INFO tokens interleaved around it.
      length (filter ("Execution Times" `T.isInfixOf`) infos) `shouldSatisfy` (>= 1)
      query1 conn "SELECT 1 AS x" `shouldReturn` Only (1 :: Int32)

  describe "SET STATISTICS XML" $ do
    it "adds no extra result set for a query with nothing to execute" $ \conn -> do
      sets <- queryMulti conn "SET STATISTICS XML ON; SELECT 1 AS x; SET STATISTICS XML OFF"
      map (map columnName . resultColumns) sets `shouldBe` [["x"]]

    it "adds a showplan-XML result set after a query against a real table" $ \conn -> do
      _ <- execute conn "CREATE TABLE #statxml (i int); INSERT INTO #statxml VALUES (1),(2),(3)"
      sets <- queryMulti conn "SET STATISTICS XML ON; SELECT * FROM #statxml; SET STATISTICS XML OFF"
      case sets of
        [dataSet, planSet] -> do
          map columnName (resultColumns dataSet) `shouldBe` ["i"]
          length (resultRows dataSet) `shouldBe` 3
          case resultRows planSet of
            [row] -> case sqlRowValues row of
              [SqlText t] -> T.isInfixOf "ShowPlanXML" t `shouldBe` True
              other -> expectationFailure ("plan row: " ++ show other)
            other -> expectationFailure ("plan rows: " ++ show other)
        other -> expectationFailure ("result sets: " ++ show (length other))

  describe "SET STATISTICS PROFILE" $
    it "adds a tabular (non-XML) plan result set with the classic profile columns" $ \conn -> do
      _ <- execute conn "CREATE TABLE #statprof (i int); INSERT INTO #statprof VALUES (1),(2)"
      sets <- queryMulti conn "SET STATISTICS PROFILE ON; SELECT * FROM #statprof; SET STATISTICS PROFILE OFF"
      case sets of
        [dataSet, planSet] -> do
          length (resultRows dataSet) `shouldBe` 2
          ("StmtText" `elem` map columnName (resultColumns planSet)) `shouldBe` True
        other -> expectationFailure ("result sets: " ++ show (length other))

  describe "SET SHOWPLAN_XML / SHOWPLAN_TEXT / SHOWPLAN_ALL" $ do
    it "SHOWPLAN_XML: the statement is not executed; one XML plan result set comes back instead" $ \conn -> do
      _ <- execute conn "SET SHOWPLAN_XML ON"
      sets <- queryMulti conn "SELECT 1 AS x"
      case sets of
        [ResultSet cols [row]] -> do
          map columnName cols `shouldBe` ["Microsoft SQL Server 2005 XML Showplan"]
          case sqlRowValues row of
            [SqlText t] -> T.isInfixOf "ShowPlanXML" t `shouldBe` True
            other -> expectationFailure ("plan row: " ++ show other)
        other -> expectationFailure ("result sets: " ++ show other)
      _ <- execute conn "SET SHOWPLAN_XML OFF"
      -- statements after turning it off execute normally again
      query1 conn "SELECT 1 AS x" `shouldReturn` Only (1 :: Int32)

    it "SHOWPLAN_TEXT / SHOWPLAN_ALL: likewise return a plan instead of executing" $ \conn -> do
      _ <- execute conn "SET SHOWPLAN_TEXT ON"
      textSets <- queryMulti conn "SELECT 1 AS x"
      map (map columnName . resultColumns) textSets `shouldBe` [["StmtText"]]
      _ <- execute conn "SET SHOWPLAN_TEXT OFF"
      _ <- execute conn "SET SHOWPLAN_ALL ON"
      allSets <- queryMulti conn "SELECT 1 AS x"
      case allSets of
        [ResultSet cols _] -> ("StmtText" `elem` map columnName cols) `shouldBe` True
        other -> expectationFailure ("result sets: " ++ show other)
      _ <- execute conn "SET SHOWPLAN_ALL OFF"
      query1 conn "SELECT 1 AS x" `shouldReturn` Only (1 :: Int32)

    it "a parameterized query (sp_executesql) under SHOWPLAN_XML returns a plan, not the computed value" $ \conn -> do
      _ <- execute conn "SET SHOWPLAN_XML ON"
      let p1 = inParam "@p1" (41 :: Int32)
      let stmt = inParam "" ("SELECT @p1 + 1 AS x" :: T.Text)
      let decl = inParam "" ("@p1 int" :: T.Text)
      res <- callProcedure conn "sp_executesql" [stmt, decl, p1]
      -- no output/return value: the statement never actually ran
      procOutputValues res `shouldBe` []
      procReturnStatus res `shouldBe` Nothing
      _ <- execute conn "SET SHOWPLAN_XML OFF"
      query1 conn ("SELECT " <> param (41 :: Int32) <> " + 1 AS x") `shouldReturn` Only (42 :: Int32)

  describe "SET FMTONLY" $
    it "returns column metadata with zero rows, even over data that exists" $ \conn -> do
      _ <- execute conn "CREATE TABLE #fmt (a int, b nvarchar(10)); INSERT INTO #fmt VALUES (1, N'x')"
      toks <- tokensOf conn "SET FMTONLY ON; SELECT a, b FROM #fmt; SET FMTONLY OFF"
      let cols = [cs | TColMetaData cs <- toks]
          rows = [rowValues row | TRow row <- toks]
      map (map columnName) cols `shouldBe` [["a", "b"]]
      rows `shouldBe` []
      -- queryMulti likewise reports the shape with no rows
      sets <- queryMulti conn "SET FMTONLY ON; SELECT a, b FROM #fmt; SET FMTONLY OFF"
      map (\s -> (map columnName (resultColumns s), resultRows s)) sets `shouldBe` [(["a", "b"], [])]
      query1 conn "SELECT COUNT(*) FROM #fmt" `shouldReturn` Only (1 :: Int)

  describe "SET PARSEONLY" $ do
    it "takes effect starting with the next batch: nothing executes, no result set, no error" $ \conn -> do
      _ <- execute conn "CREATE TABLE #po (i int)"
      _ <- execute conn "SET PARSEONLY ON"
      toks <- tokensOf conn "INSERT INTO #po VALUES (1/0)" -- would divide by zero if it ran
      [rowValues row | TRow row <- toks] `shouldBe` []
      _ <- execute conn "SET PARSEONLY OFF"
      query1 conn "SELECT COUNT(*) FROM #po" `shouldReturn` Only (0 :: Int)

    it "a later SELECT in the same connection executes normally once turned off" $ \conn -> do
      _ <- execute conn "SET PARSEONLY ON"
      _ <- execute conn "SET PARSEONLY OFF"
      query1 conn "SELECT 1 AS x" `shouldReturn` Only (1 :: Int32)

  describe "SET NOEXEC" $ do
    it "compiles but does not execute; no rows, no error, on a later batch" $ \conn -> do
      _ <- execute conn "CREATE TABLE #ne (i int)"
      _ <- execute conn "SET NOEXEC ON"
      toks <- tokensOf conn "INSERT INTO #ne VALUES (1/0)"
      [rowValues row | TRow row <- toks] `shouldBe` []
      _ <- execute conn "SET NOEXEC OFF"
      query1 conn "SELECT COUNT(*) FROM #ne" `shouldReturn` Only (0 :: Int)

    it "a reference to a nonexistent object under NOEXEC is not even an error \
       \(deferred name resolution is never reached without execution)" $ \conn -> do
      _ <- execute conn "SET NOEXEC ON"
      toks <- tokensOf conn "SELECT * FROM dbo.hmssql_diagnostics_no_such_table_xyz"
      [rowValues row | TRow row <- toks] `shouldBe` []
      [e | TError e <- toks] `shouldBe` []
      _ <- execute conn "SET NOEXEC OFF"
      -- once truly off, the same reference does fail
      r <- try (execute conn "SELECT * FROM dbo.hmssql_diagnostics_no_such_table_xyz") :: IO (Either SqlServerError Int64)
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 208
        Right n -> expectationFailure ("succeeded: " ++ show n)
