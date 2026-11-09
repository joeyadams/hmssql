-- | 'bulkInsert' and friends: rows loaded by the TDS bulk load, the column
-- discovery, the type conversions to each column, streaming and batching,
-- errors and cancellation.
module Bulk.CopySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (finally, throwIO, try, ErrorCall (..), SomeException)
import Control.Monad (void, when)
import qualified Data.ByteString as B
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Errors
import Hmssql.BulkCopy
import Hmssql.Tds.Primitives (Collation (..))
import Hmssql.Tds.TypeInfo (TypeInfo (..), maxLength)
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "inserting rows" $ do
    it "loads rows and returns the count" $ \conn -> do
      makeItem conn
      n <- bulkInsert conn "#item" [(1 :: Int32, "one" :: Text, 9.99 :: Double), (2, "two", 0.5)]
      n `shouldBe` 2
      query conn "SELECT id, name, CAST(price AS varchar(20)) FROM #item ORDER BY id"
        `shouldReturn` [(1 :: Int32, "one" :: Text, "9.99" :: Text), (2, "two", "0.50")]

    it "returns 0 and inserts nothing for no rows" $ \conn -> do
      makeItem conn
      bulkInsert conn "#item" ([] :: [(Int32, Text, Double)]) `shouldReturn` 0
      query1 conn "SELECT COUNT(*) FROM #item" `shouldReturn` Only (0 :: Int32)

    it "sends NULL for a Nothing in a nullable column" $ \conn -> do
      void $ execute conn "CREATE TABLE #n (id int NOT NULL, note nvarchar(50) NULL)"
      void $ bulkInsert conn "#n" [(1 :: Int32, Just ("hi" :: Text)), (2, Nothing)]
      query conn "SELECT id, note FROM #n ORDER BY id"
        `shouldReturn` [(1 :: Int32, Just ("hi" :: Text)), (2, Nothing)]

    it "loads a large stream that spans many packets" $ \conn -> do
      void $ execute conn "CREATE TABLE #s (i int NOT NULL, s nvarchar(30) NOT NULL)"
      n <- bulkInsertS conn "#s" (S.each [(i, T.pack (show i)) | i <- [1 .. 20000 :: Int32]])
      n `shouldBe` 20000
      query1 conn "SELECT COUNT(*), SUM(CAST(i AS bigint)) FROM #s" `shouldReturn` (20000 :: Int32, 200010000 :: Int64)

    it "loads named parameters into named columns" $ \conn -> do
      void $ execute conn "CREATE TABLE #nm (id int NOT NULL, name nvarchar(50) NOT NULL, note nvarchar(50) NULL)"
      n <- bulkInsertWith (bulkCopy "#nm") { bulkColumns = NamedColumns ["name", "id"] } conn
        [NamedParams [("id", SqlParam (7 :: Int32)), ("name", SqlParam ("seven" :: Text))]]
      n `shouldBe` 1
      query conn "SELECT id, name, note FROM #nm" `shouldReturn` [(7 :: Int32, "seven" :: Text, Nothing :: Maybe Text)]

  describe "column discovery" $ do
    it "skips identity, computed and rowversion columns by default" $ \conn -> do
      void $ execute conn "CREATE TABLE #d (id int IDENTITY(1,1) NOT NULL, v int NOT NULL, doubled AS v * 2, rv rowversion)"
      map bulkColumnName <$> describeBulkColumns conn (bulkCopy "#d") `shouldReturn` ["v"]
      n <- bulkInsert conn "#d" [Only (10 :: Int32), Only 20]
      n `shouldBe` 2
      query conn "SELECT v, doubled FROM #d ORDER BY v" `shouldReturn` [(10 :: Int32, 20 :: Int32), (20, 40)]

    it "keeps the identity column with bulkKeepIdentity" $ \conn -> do
      void $ execute conn "CREATE TABLE #ki (id int IDENTITY(1,1) NOT NULL, v int NOT NULL)"
      n <- bulkInsertWith (bulkCopy "#ki") { bulkKeepIdentity = True } conn [(100 :: Int32, 1 :: Int32), (200, 2)]
      n `shouldBe` 2
      query conn "SELECT id, v FROM #ki ORDER BY id" `shouldReturn` [(100 :: Int32, 1 :: Int32), (200, 2)]

    it "throws for a table that does not exist" $ \conn ->
      bulkInsert conn "#nope" [Only (1 :: Int32)] `shouldThrow` \e -> sqlErrorNumber e == 208

    it "does not query the server for DescribedColumns" $ \conn -> do
      void $ execute conn "CREATE TABLE #dc (a int NOT NULL, b nvarchar(20) NULL)"
      let cols = [BulkColumn "a" (TIIntN 4) False False, BulkColumn "b" (TINVarChar maxLength (Collation 0 0)) True False]
      n <- bulkInsertWith (bulkCopy "#dc") { bulkColumns = DescribedColumns cols } conn [(5 :: Int32, Just ("x" :: Text))]
      n `shouldBe` 1
      query conn "SELECT a, b FROM #dc" `shouldReturn` [(5 :: Int32, Just ("x" :: Text))]

  describe "conversions to the column type" $ do
    skipBeforeSql2019 "UTF-8 collations" $ it "loads char and varchar in a UTF-8 and a legacy collation, and pads char" $ \conn -> do
      void $ execute conn "CREATE TABLE #c (u varchar(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8 NULL,\
        \ a varchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL, c char(6) COLLATE SQL_Latin1_General_CP1_CI_AS NULL)"
      void $ bulkInsert conn "#c" [("Straße € 日本" :: Text, "Café crème" :: Text, "ab" :: Text)]
      query conn "SELECT u, a, c FROM #c"
        `shouldReturn` [("Straße € 日本" :: Text, "Café crème" :: Text, "ab    " :: Text)]

    it "roundtrips every max and large-object type" $ \conn -> do
      void $ execute conn "CREATE TABLE #m (nm nvarchar(max) NULL, vm varchar(max) NULL, bm varbinary(max) NULL,\
        \ x xml NULL, t text NULL, nt ntext NULL, im image NULL)"
      let big = T.replicate 50000 "y"
      n <- bulkInsert conn "#m" [(big, "v" :: Text, B.replicate 100000 0xAB, SqlXml "<a>1</a>", "t" :: Text, "n" :: Text, B.pack [1,2,3,4])]
      n `shouldBe` 1
      query1 conn "SELECT LEN(nm), CAST(vm AS varchar(5)), DATALENGTH(bm), CAST(x AS nvarchar(20)),\
        \ CAST(t AS varchar(5)), CAST(nt AS nvarchar(5)), DATALENGTH(im) FROM #m"
        `shouldReturn` (50000 :: Int32, "v" :: Text, 100000 :: Int32, "<a>1</a>" :: Text, "t" :: Text, "n" :: Text, 4 :: Int32)

    it "converts an integer to each numeric column type" $ \conn -> do
      void $ execute conn "CREATE TABLE #num (b bigint NULL, sm smallint NULL, ti tinyint NULL, de decimal(10,2) NULL,\
        \ mo money NULL, fl float NULL, rl real NULL, bt bit NULL)"
      void $ bulkInsert conn "#num" [(1 :: Int32, 2 :: Int32, 3 :: Int32, 4 :: Int32, 5 :: Int32, 6 :: Int32, 7 :: Int32, 1 :: Int32)]
      query conn "SELECT b, CAST(sm AS int), CAST(ti AS int), CAST(de AS varchar(10)), CAST(mo AS varchar(10)),\
        \ fl, rl, CAST(bt AS int) FROM #num"
        `shouldReturn` [(1 :: Int64, 2 :: Int32, 3 :: Int32, "4.00" :: Text, "5.00" :: Text, 6 :: Double, 7 :: Float, 1 :: Int32)]

    it "rounds a decimal to the column's scale, half away from zero" $ \conn -> do
      void $ execute conn "CREATE TABLE #r (d decimal(8,2) NULL)"
      void $ bulkInsert conn "#r" [Only (2.345 :: Double), Only 2.354, Only (-2.345)]
      query conn "SELECT CAST(d AS varchar(10)) FROM #r ORDER BY d"
        `shouldReturn` map Only ["-2.35" :: Text, "2.35", "2.35"]

    it "refuses a value out of the column's range" $ \conn -> do
      void $ execute conn "CREATE TABLE #ovf (t tinyint NOT NULL)"
      bulkInsert conn "#ovf" [Only (300 :: Int32)] `shouldThrow` \(EncodeError m) -> "range" `isInfixOfC` m

    it "refuses a string longer than the column" $ \conn -> do
      void $ execute conn "CREATE TABLE #len (s nvarchar(5) NOT NULL)"
      bulkInsert conn "#len" [Only ("toolong" :: Text)] `shouldThrow` \(EncodeError m) -> "long" `isInfixOfC` m

    it "refuses NULL for a NOT NULL column, naming the row and column" $ \conn -> do
      void $ execute conn "CREATE TABLE #nn (a int NOT NULL)"
      bulkInsert conn "#nn" [Only (Nothing :: Maybe Int32)]
        `shouldThrow` \(EncodeError m) -> "row 0" `isInfixOfC` m && "NOT NULL" `isInfixOfC` m

  describe "options" $ do
    it "sends the rows in batches of bulkBatchSize" $ \conn -> do
      void $ execute conn "CREATE TABLE #b (a int NOT NULL)"
      n <- bulkInsertWith (bulkCopy "#b") { bulkBatchSize = Just 7 } conn (map Only [1 .. 20 :: Int32])
      n `shouldBe` 20
      query1 conn "SELECT COUNT(*), SUM(a) FROM #b" `shouldReturn` (20 :: Int32, 210 :: Int32)

    it "fires triggers only when asked" $ \conn -> do
      tbl <- uniqueName "bulk_trig"
      let q = "dbo." <> tbl
      void $ execute conn (rawSql ("CREATE TABLE " <> q <> " (a int NOT NULL); CREATE TABLE " <> q <> "_log (a int NOT NULL)"))
      flip finally (void (execute conn (rawSql ("DROP TABLE " <> q <> "; DROP TABLE " <> q <> "_log")))) $ do
        void $ execute conn (rawSql ("CREATE TRIGGER " <> q <> "_t ON " <> q <> " AFTER INSERT AS INSERT INTO " <> q <> "_log SELECT a FROM inserted"))
        void $ bulkInsert conn q [Only (1 :: Int32)]
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> "_log")) `shouldReturn` Only (0 :: Int32)
        void $ bulkInsertWith (bulkCopy q) { bulkFireTriggers = True } conn [Only (2 :: Int32)]
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> q <> "_log")) `shouldReturn` Only (1 :: Int32)

  describe "errors and cancellation" $ do
    it "throws the server's error, leaving the connection usable" $ \conn -> do
      void $ execute conn "CREATE TABLE #pk (a int NOT NULL PRIMARY KEY)"
      r <- try (bulkInsert conn "#pk" (map Only [1, 2, 2, 3 :: Int32]))
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int32)

    it "is rolled back inside a transaction" $ \conn -> do
      void $ execute conn "CREATE TABLE #tx (a int NOT NULL PRIMARY KEY)"
      r <- try $ withTransaction conn $ bulkInsert conn "#tx" (map Only [1, 2, 2 :: Int32])
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      query1 conn "SELECT COUNT(*) FROM #tx" `shouldReturn` Only (0 :: Int32)

    it "propagates an exception from a stream cut short, leaving the connection usable" $ \conn -> do
      void $ execute conn "CREATE TABLE #se (a int NOT NULL)"
      let rows = S.mapM (\i -> if i == 3 then throwIO (ErrorCall "boom") else pure (Only i)) (S.each [1 .. 6 :: Int32])
      bulkInsertSWith (bulkCopy "#se") conn rows `shouldThrow` \(ErrorCall m) -> m == "boom"
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int32)
      query1 conn "SELECT COUNT(*) FROM #se" `shouldReturn` Only (0 :: Int32)

    -- Unlike a stream that throws: the interruption lands in the producer
    -- (here in its own wait for rows), while the message is going out.
    it "breaks the connection when interrupted while the rows are being sent (a timeout), as any interrupted send does" $ \conn -> do
      void $ execute conn "CREATE TABLE #it (a int NOT NULL)"
      -- Interrupted 100 ms after the load took its second row.  The first
      -- row is taken before the INSERT BULK statement, because it decides
      -- the wire layout, so a timeout counted from it, or from the start,
      -- fired in a busy run while the load still waited for the answer to
      -- its INSERT BULK: a read, which an interruption cancels and leaves
      -- the connection usable.  The second row is taken inside the send.
      started <- newEmptyMVar
      let slow = S.mapM (\i -> when (i == 2) (void (tryPutMVar started ())) >> threadDelay 1_000 >> pure (Only i)) (S.each [1 .. 100_000 :: Int32])
      race (takeMVar started >> threadDelay 100_000) (bulkInsertSWith (bulkCopy "#it") conn slow) `shouldReturn` Left ()
      (query1 conn "SELECT 1" :: IO (Only Int32)) `shouldThrow` \(ConnectionBroken _) -> True
      release conn `shouldReturn` False
  where
    makeItem conn = void $ execute conn "CREATE TABLE #item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
    isInfixOfC needle hay = needle `T.isInfixOf` T.pack hay
