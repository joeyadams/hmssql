-- | Bulk load interacts with SQL features as INSERT BULK, not ordinary
-- INSERT. Observe stored data and trigger effects, including failed batches.
module Bulk.FeaturesSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, void)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors
import TestDb

spec :: Spec
spec = describe "bulk copy with database features" $ do
  forM_ [False, True] $ \nocount ->
    it ("counts input rows when a trigger inserts more rows, NOCOUNT=" ++ show nocount) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int NOT NULL); CREATE TABLE " <> q <> "_audit (v int)")
      exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN SET NOCOUNT " <> (if nocount then "ON" else "OFF") <> "; INSERT INTO " <> q <> "_audit SELECT v FROM inserted UNION ALL SELECT -v FROM inserted; END")
      bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn (map Only [1,2,3 :: Int32]) `shouldReturn` 3
      query conn (rawSql ("SELECT v FROM " <> q <> "_audit ORDER BY v")) `shouldReturn` map Only [-3,-2,-1,1,2,3 :: Int32]
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int32)

  forM_ [Nothing, Just 1, Just 2, Just 3, Just 8] $ \batchSize ->
    it ("fires a set-based trigger once per batch, size=" ++ show batchSize) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int NOT NULL); CREATE TABLE " <> q <> "_audit (ordinal int IDENTITY, n int, total int)")
      exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS INSERT INTO " <> q <> "_audit(n,total) SELECT COUNT(*), SUM(v) FROM inserted")
      bulkInsertWith (bulkCopy q) {bulkFireTriggers = True, bulkBatchSize = batchSize} conn (map Only [1..7 :: Int32]) `shouldReturn` 7
      let groups = chunks (maybe 7 id batchSize) [1..7 :: Int32]
      query conn (rawSql ("SELECT n, total FROM " <> q <> "_audit ORDER BY ordinal")) `shouldReturn`
        [(fromIntegral (length xs) :: Int32, sum xs) | xs <- groups]

  it "rolls back the rejected trigger batch and keeps earlier committed batches" $ fixture $ \conn q -> do
    rejectingTrigger conn q
    result <- try $ bulkInsertWith (bulkCopy q) {bulkFireTriggers = True, bulkBatchSize = Just 2} conn (map Only [1,2,3,4 :: Int32])
    either sqlErrorNumber (const 0) result `shouldBe` 50011
    query conn (rawSql ("SELECT v FROM " <> q <> " ORDER BY v")) `shouldReturn` map Only [1,2 :: Int32]
    query conn (rawSql ("SELECT v FROM " <> q <> "_audit ORDER BY v")) `shouldReturn` map Only [1,2 :: Int32]
    bulkInsert conn q [Only (5 :: Int32)] `shouldReturn` 1

  it "rolls back all batches and trigger writes in an explicit transaction" $ fixture $ \conn q -> do
    rejectingTrigger conn q
    result <- try $ withTransaction conn $ bulkInsertWith (bulkCopy q) {bulkFireTriggers = True, bulkBatchSize = Just 2} conn (map Only [1,2,3,4 :: Int32])
    either sqlErrorNumber (const 0) result `shouldBe` 50011
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> "_audit")) `shouldReturn` Only (0 :: Int32)

  it "does not fire a disabled trigger even when requested" $ fixture $ \conn q -> do
    rejectingTrigger conn q
    exec conn ("DISABLE TRIGGER ALL ON " <> q)
    bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn [Only (3 :: Int32)] `shouldReturn` 1
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> "_audit")) `shouldReturn` Only (0 :: Int32)

  forM_ [False,True] $ \keepNulls ->
    it ("handles defaults, explicit NULL and empty values, KEEP_NULLS=" ++ show keepNulls) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (id int NOT NULL, v nvarchar(20) NULL DEFAULT N'default', omitted int NOT NULL DEFAULT 17)")
      let rows = [(1 :: Int32, Nothing :: Maybe Text), (2, Just ""), (3, Just "\x1f600")]
      bulkInsertWith (bulkCopy q) {bulkColumns = NamedColumns ["id","v"], bulkKeepNulls = keepNulls} conn rows `shouldReturn` 3
      query conn (rawSql ("SELECT id,v,omitted FROM " <> q <> " ORDER BY id")) `shouldReturn`
        [(1 :: Int32, if keepNulls then Nothing else Just ("default" :: Text), 17 :: Int32),(2,Just "",17),(3,Just "\x1f600",17)]

  forM_ [False,True] $ \check ->
    it ("enforces check constraints only when requested, CHECK_CONSTRAINTS=" ++ show check) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int NOT NULL CHECK (v > 0))")
      result <- try $ bulkInsertWith (bulkCopy q) {bulkCheckConstraints = check} conn [Only (-1 :: Int32)]
      if check then do
        either sqlErrorNumber (const 0) result `shouldBe` 547
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)
      else do
        either (expectationFailure . show) (`shouldBe` 1) result
        query1 conn (rawSql ("SELECT v FROM " <> q)) `shouldReturn` Only (-1 :: Int32)

  it "enforces foreign keys with CHECK_CONSTRAINTS and leaves the connection reusable" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> "_parent (id int PRIMARY KEY); CREATE TABLE " <> q <> " (id int REFERENCES " <> q <> "_parent(id))")
    result <- try $ bulkInsertWith (bulkCopy q) {bulkCheckConstraints = True} conn [Only (1 :: Int32)]
    either sqlErrorNumber (const 0) result `shouldBe` 547
    exec conn ("INSERT INTO " <> q <> "_parent VALUES (1)")
    bulkInsertWith (bulkCopy q) {bulkCheckConstraints = True} conn [Only (1 :: Int32)] `shouldReturn` 1

  it "loads reordered quoted columns beside computed, identity and rowversion columns" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int IDENTITY, [a]]b] nvarchar(20), [select] int NOT NULL, doubled AS [select]*2 PERSISTED, rv rowversion)")
    bulkInsertWith (bulkCopy q) {bulkColumns = NamedColumns ["select","a]b"]} conn [(9 :: Int32,"\x1f600" :: Text),(4,"")] `shouldReturn` 2
    query conn (rawSql ("SELECT id,[a]]b],[select],doubled,DATALENGTH(rv) FROM " <> q <> " ORDER BY id")) `shouldReturn`
      [(1 :: Int32,"\x1f600" :: Text,9 :: Int32,18 :: Int32,8 :: Int32),(2,"",4,8,8)]

  it "generates fresh rowversions and computed values when all columns are discovered" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id bigint IDENTITY(100,5), v int, square AS v*v, rv rowversion)")
    bulkInsert conn q (map Only [2,3 :: Int32]) `shouldReturn` 2
    query conn (rawSql ("SELECT id,v,square FROM " <> q <> " ORDER BY id")) `shouldReturn` [(100 :: Int64,2 :: Int32,4 :: Int32),(105,3,9)]
    query1 conn (rawSql ("SELECT COUNT(DISTINCT rv) FROM " <> q)) `shouldReturn` Only (2 :: Int32)

  it "drains a trigger's result set before returning the bulk count" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int)")
    exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; SELECT v,N'😀' AS note FROM inserted; END")
    bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn (map Only [1,2,3 :: Int32]) `shouldReturn` 3
    query conn (rawSql ("SELECT v FROM " <> q <> " ORDER BY v")) `shouldReturn` map Only [1,2,3 :: Int32]
    query1 conn "SELECT 17" `shouldReturn` Only (17 :: Int32)

  it "preserves changes an AFTER trigger makes to inserted rows" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int PRIMARY KEY,v int)")
    exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; UPDATE target SET v=target.v+10 FROM " <> q <> " AS target JOIN inserted AS i ON i.id=target.id; END")
    bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn [(1 :: Int32,2 :: Int32),(2,3)] `shouldReturn` 2
    query conn (rawSql ("SELECT id,v FROM " <> q <> " ORDER BY id")) `shouldReturn` [(1 :: Int32,12 :: Int32),(2,13)]

  it "does not invoke a trigger for an empty client stream" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int); CREATE TABLE " <> q <> "_audit(n int)")
    exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS INSERT INTO " <> q <> "_audit SELECT COUNT(*) FROM inserted")
    bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn ([] :: [Only Int32]) `shouldReturn` 0
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> "_audit")) `shouldReturn` Only (0 :: Int32)

  forM_ [False,True] $ \check ->
    it ("records constraint trust after bulk load, CHECK_CONSTRAINTS=" ++ show check) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int CHECK(v>0))")
      bulkInsertWith (bulkCopy q) {bulkCheckConstraints = check} conn [Only (1 :: Int32)] `shouldReturn` 1
      query1 conn (mkQuery "SELECT is_not_trusted FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(@p1)" (Only q))
        `shouldReturn` Only (not check)

  it "loads explicitly selected sparse columns beside a column set" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int, a int SPARSE NULL,b nvarchar(20) SPARSE NULL, all_sparse xml COLUMN_SET FOR ALL_SPARSE_COLUMNS)")
    bulkInsertWith (bulkCopy q) {bulkColumns = NamedColumns ["id","a","b"]} conn [(1 :: Int32,Just (7 :: Int32),Nothing :: Maybe Text),(2,Nothing,Just "😀")] `shouldReturn` 2
    query conn (rawSql ("SELECT id,a,b FROM " <> q <> " ORDER BY id")) `shouldReturn` [(1 :: Int32,Just (7 :: Int32),Nothing :: Maybe Text),(2,Nothing,Just "😀")]

  it "leaves temporal period columns for the server to generate" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int PRIMARY KEY,v nvarchar(20),valid_from datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,valid_to datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,PERIOD FOR SYSTEM_TIME(valid_from,valid_to)) WITH (SYSTEM_VERSIONING=ON)")
    map bulkColumnName <$> describeBulkColumns conn (bulkCopy q) `shouldReturn` ["id","v"]
    bulkInsert conn q [(1 :: Int32,"😀" :: Text),(2,"text")] `shouldReturn` 2
    query conn (rawSql ("SELECT id,v FROM " <> q <> " ORDER BY id")) `shouldReturn` [(1 :: Int32,"😀" :: Text),(2,"text")]
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> " WHERE valid_from<valid_to")) `shouldReturn` Only (2 :: Int32)

  forM_ [3,2000 :: Int32] $ \n ->
    it ("rolls back a single batch with a duplicate key after " ++ show n ++ " rows") $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int PRIMARY KEY)")
      result <- try $ bulkInsert conn q (map Only ([1..n] ++ [1]))
      either sqlErrorNumber (const 0) result `shouldBe` 2627
      query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)

  it "keeps earlier committed batches after a later duplicate-key failure" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int PRIMARY KEY)")
    result <- try $ bulkInsertWith (bulkCopy q) {bulkBatchSize = Just 2} conn (map Only [1,2,2,3 :: Int32])
    either sqlErrorNumber (const 0) result `shouldBe` 2627
    query conn (rawSql ("SELECT v FROM " <> q <> " ORDER BY v")) `shouldReturn` map Only [1,2 :: Int32]

  it "rolls back a checked batch when a later row violates a CHECK constraint" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int CHECK(v>0))")
    result <- try $ bulkInsertWith (bulkCopy q) {bulkCheckConstraints = True} conn (map Only [1,2,-1,3 :: Int32])
    either sqlErrorNumber (const 0) result `shouldBe` 547
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)

  it "rolls back a batch when a later XML value is invalid" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int,v xml)")
    result <- try $ bulkInsert conn q [(1 :: Int32,"<r/>" :: Text),(2,"<unclosed>")]
    either (\(_ :: SqlServerError) -> True) (const False) result `shouldBe` True
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)

  it "reports RAISERROR from a trigger even when the server commits the inserted rows" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int)")
    exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; RAISERROR('trigger reported error',16,1); END")
    result <- try $ bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn (map Only [1,2 :: Int32])
    either sqlErrorMessage (const "") result `shouldBe` "trigger reported error"
    query conn (rawSql ("SELECT v FROM " <> q <> " ORDER BY v")) `shouldReturn` map Only [1,2 :: Int32]

  it "rolls back trigger RAISERROR writes when the exception escapes withTransaction" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int)")
    exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; RAISERROR('trigger reported error',16,1); END")
    result <- try $ withTransaction conn $ bulkInsertWith (bulkCopy q) {bulkFireTriggers = True} conn (map Only [1,2 :: Int32])
    either sqlErrorMessage (const "") result `shouldBe` "trigger reported error"
    query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q)) `shouldReturn` Only (0 :: Int32)

  it "skips visible generated temporal period columns during discovery" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (id int PRIMARY KEY,v nvarchar(20),valid_from datetime2 GENERATED ALWAYS AS ROW START NOT NULL,valid_to datetime2 GENERATED ALWAYS AS ROW END NOT NULL,PERIOD FOR SYSTEM_TIME(valid_from,valid_to)) WITH (SYSTEM_VERSIONING=ON)")
    map bulkColumnName <$> describeBulkColumns conn (bulkCopy q) `shouldReturn` ["id","v"]
    bulkInsert conn q [(1 :: Int32,"😀" :: Text)] `shouldReturn` 1
    query1 conn (rawSql ("SELECT id,v FROM " <> q)) `shouldReturn` (1 :: Int32,"😀" :: Text)

  forM_ [False,True] $ \fire ->
    it ("handles a table with an INSTEAD OF trigger, FIRE_TRIGGERS=" ++ show fire) $ fixture $ \conn q -> do
      exec conn ("CREATE TABLE " <> q <> " (v int)")
      exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " INSTEAD OF INSERT AS BEGIN SET NOCOUNT ON; INSERT INTO " <> q <> " SELECT v+100 FROM inserted; END")
      exec conn ("INSERT INTO " <> q <> " VALUES(2)")
      bulkInsertWith (bulkCopy q) {bulkFireTriggers=fire} conn [Only (1 :: Int32)] `shouldReturn` 1
      query conn (rawSql ("SELECT v FROM " <> q <> " ORDER BY v")) `shouldReturn` map Only [if fire then 101 else 1,102 :: Int32]

  it "loads through an updatable view and leaves omitted columns to their defaults" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int,omitted int NOT NULL DEFAULT 17)")
    exec conn ("CREATE VIEW " <> q <> "_view AS SELECT v FROM " <> q)
    bulkInsert conn (q <> "_view") (map Only [1,2 :: Int32]) `shouldReturn` 2
    query conn (rawSql ("SELECT v,omitted FROM " <> q <> " ORDER BY v")) `shouldReturn` [(1 :: Int32,17 :: Int32),(2,17)]

  it "skips a view's computed projection during column discovery" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " (v int)")
    exec conn ("CREATE VIEW " <> q <> "_view AS SELECT v,v*2 AS doubled FROM " <> q)
    map bulkColumnName <$> describeBulkColumns conn (bulkCopy (q <> "_view")) `shouldReturn` ["v"]
    bulkInsert conn (q <> "_view") [Only (7 :: Int32)] `shouldReturn` 1
    query1 conn (rawSql ("SELECT v,doubled FROM " <> q <> "_view")) `shouldReturn` (7 :: Int32,14 :: Int32)

  it "maintains an indexed aggregate view while bulk loading its base table" $ fixture $ \conn q -> do
    exec conn "SET ARITHABORT ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET QUOTED_IDENTIFIER ON; SET NUMERIC_ROUNDABORT OFF"
    exec conn ("CREATE TABLE " <> q <> " (id int NOT NULL PRIMARY KEY,v int NOT NULL)")
    exec conn ("CREATE VIEW " <> q <> "_view WITH SCHEMABINDING AS SELECT v,COUNT_BIG(*) AS n FROM " <> q <> " GROUP BY v")
    exec conn ("CREATE UNIQUE CLUSTERED INDEX indexed_aggregate ON " <> q <> "_view(v)")
    bulkInsert conn q [(1 :: Int32,7 :: Int32),(2,7),(3,9)] `shouldReturn` 3
    query conn (rawSql ("SELECT v,n FROM " <> q <> "_view WITH (NOEXPAND) ORDER BY v")) `shouldReturn` [(7 :: Int32,2 :: Int64),(9,1)]

  it "accepts ordering and batch-size estimates without limiting the rows loaded" $ fixture $ \conn q -> do
    exec conn ("CREATE TABLE " <> q <> " ([a]]id] int NOT NULL,b int NOT NULL,PRIMARY KEY ([a]]id] ASC,b DESC))")
    let rows = [(1 :: Int32,3 :: Int32),(1,2),(1,1),(2,4)]
        options = (bulkCopy q) {bulkTableLock=True,bulkOrder=[Ascending "a]id",Descending "b"],bulkRowsPerBatch=Just 1,bulkKilobytesPerBatch=Just 1}
    bulkInsertWith options conn rows `shouldReturn` 4
    query conn (rawSql ("SELECT [a]]id],b FROM " <> q <> " ORDER BY [a]]id],b DESC")) `shouldReturn` rows

fixture :: (Connection -> Text -> IO a) -> IO a
fixture action = do
  ci <- defaultTestConnectInfo
  withScratchSchema ci "bulk_features" $ \schema -> withConnection ci $ \conn -> action conn (schema <> ".target")

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql

rejectingTrigger :: Connection -> Text -> IO ()
rejectingTrigger conn q = do
  exec conn ("CREATE TABLE " <> q <> " (v int NOT NULL); CREATE TABLE " <> q <> "_audit (v int)")
  exec conn ("CREATE TRIGGER " <> q <> "_tr ON " <> q <> " AFTER INSERT AS BEGIN INSERT INTO " <> q <> "_audit SELECT v FROM inserted; IF EXISTS (SELECT 1 FROM inserted WHERE v=3) THROW 50011, 'rejected by trigger', 1; END")

chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks n xs = let (a,b) = splitAt n xs in a : chunks n b
