-- | Statement/function mismatches: 'execute'\/'execute' pointed at a
-- statement that actually returns rows (a bare @SELECT@), and
-- 'query'\/'query'\/'queryS' pointed at a statement that produces no result
-- set at all (@DECLARE@, @SET NOCOUNT ON@, an @UPDATE@ with no @OUTPUT@).
-- Confirms the exact, current behaviour in each case -- 'execute' only ever
-- sums 'DONE' row counts, so a row-returning statement's rows are simply
-- discarded, never surfaced; 'query'\/'queryS' read the response looking for
-- the first 'Hmssql.Tds.Token.TColMetaData', so a response that never sends
-- one is read to exhaustion and yields @[]@, not an error -- and contrasts
-- that with 'queryMulti', which can tell "no result set" and "one empty
-- result set" apart while 'query' cannot (both report @[]@).
module Api.StatementShapeMisuseSpec (spec) where

import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "execute/execute on a statement that returns rows" $ do
    it "runs successfully and simply discards the rows, reporting the SELECT's own DONE row count" $ \conn -> do
      _ <- execute conn "CREATE TABLE #se (i int)"
      _ <- execute conn "INSERT INTO #se VALUES (1), (2), (3)"
      n <- execute conn "SELECT * FROM #se"
      n `shouldBe` 3
      -- the connection is unaffected: the result set was drained along with
      -- everything else in the response
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "a bare literal SELECT (no FROM) also just reports its own row count" $ \conn -> do
      n <- execute conn "SELECT 1 AS x"
      n `shouldBe` 1
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "execute (with parameters) on a row-returning statement also discards the rows" $ \conn -> do
      n <- execute conn ("SELECT " <> param (42 :: Int))
      n `shouldBe` 1
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "sums the DONE row counts of a rowless statement and a row-returning statement in the same batch" $ \conn -> do
      n <- execute conn "DECLARE @x int = 1; SELECT 1 AS a, 2 AS b"
      -- Somewhat surprisingly, "DECLARE @x int = 1" contributes 1 to the
      -- total (SQL Server reports the inline assignment itself as a
      -- "1 row affected"), and the SELECT contributes its own row count (1):
      -- 1 + 1 = 2. Confirmed empirically against SQL Server 2025.
      n `shouldBe` 2
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "query/query/queryS on a statement that produces no result set at all" $ do
    it "query on a batch containing only a DECLARE returns [] rather than erroring" $ \conn ->
      (query conn "DECLARE @x int = 1" :: IO [Only Int]) `shouldReturn` []

    it "query on SET NOCOUNT ON alone returns []" $ \conn ->
      (query conn "SET NOCOUNT ON" :: IO [Only Int]) `shouldReturn` []

    it "query on an UPDATE with no OUTPUT clause returns []" $ \conn -> do
      _ <- execute conn "CREATE TABLE #upd (i int)"
      _ <- execute conn "INSERT INTO #upd VALUES (1)"
      (query conn "UPDATE #upd SET i = i + 1" :: IO [Only Int]) `shouldReturn` []

    it "queryS yields an empty stream, not an error, and drains cleanly" $ \conn -> do
      s <- queryS conn "DECLARE @x int = 1"
      rows <- S.toList_ s :: IO [Only Int]
      rows `shouldBe` []
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "query's [] is ambiguous between 'no result set' and 'one empty result set'" $
    it "queryMulti tells them apart; query cannot" $ \conn -> do
      noSets <- queryMulti conn "DECLARE @x int = 1"
      noSets `shouldBe` []
      _ <- execute conn "CREATE TABLE #empty2 (i int)"
      [ResultSet _ emptyRows] <- queryMulti conn "SELECT i FROM #empty2"
      emptyRows `shouldBe` ([] :: [SqlRow])
      -- from query's point of view both situations look identical: []
      (query conn "DECLARE @y int = 1" :: IO [Only Int]) `shouldReturn` []
      (query conn "SELECT i FROM #empty2" :: IO [Only Int]) `shouldReturn` []
