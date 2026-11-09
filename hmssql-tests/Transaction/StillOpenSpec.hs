-- | 'TransactionStillOpen': a 'withTransaction' body that begins a nested
-- transaction ('begin', or a @BEGIN TRANSACTION@ batch) and
-- doesn't end it leaves the connection in a transaction after the COMMIT,
-- which only lowered @\@\@TRANCOUNT@.  'withTransaction' then rolls
-- everything back and throws: nothing is committed, nothing stays locked,
-- the connection is out of the transaction (and at READ COMMITTED after
-- 'withTransactionLevel').  A nested begin the body ends still commits.
module Transaction.StillOpenSpec (spec) where

import Control.Exception
import Control.Monad (forM_, void)
import Data.Int (Int16)
import Data.List (sort)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Transaction
import TestDb

-- | A table of its own in the test database, @(i int PRIMARY KEY)@.
withTable :: (Text -> IO a) -> IO a
withTable act = do
  t <- ("dbo." <>) <$> uniqueName "still_open"
  withTestDb $ \conn -> void $ execute conn (rawSql ("CREATE TABLE " <> t <> " (i int PRIMARY KEY)"))
  act t `finally` withTestDb (\conn -> void $ execute conn (rawSql ("DROP TABLE IF EXISTS " <> t)))

insert :: Connection -> Text -> Int -> IO ()
insert conn t i = void $ execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only i))

tranCount :: Connection -> IO Int
tranCount conn = fromOnly <$> query1 conn "SELECT @@TRANCOUNT"

-- | 2 is READ COMMITTED.
sessionLevel :: Connection -> IO Int16
sessionLevel conn = fromOnly <$> query1 conn
  "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID"

stillOpen :: IO a -> IO ()
stillOpen act = try act >>= \case
  Left TransactionStillOpen -> pure ()
  Left e -> expectationFailure ("threw " ++ show e)
  Right _ -> expectationFailure "no TransactionStillOpen"

-- | After 'TransactionStillOpen': the connection is out of the
-- transaction, and another connection can write the body's rows at once
-- (a lock left would fail with error 1222, a committed row with 2627);
-- the table then holds those and the others given.
checkRolledBack :: Connection -> Text -> [Int] -> [Int] -> IO ()
checkRolledBack conn t keys others = do
  inTransaction conn `shouldReturn` False
  tranCount conn `shouldReturn` 0
  withTestDb $ \other -> do
    _ <- execute other "SET LOCK_TIMEOUT 0"
    forM_ keys (insert other t)
    map fromOnly <$> query other (rawSql ("SELECT i FROM " <> t <> " ORDER BY i")) `shouldReturn` sort (keys ++ others)

-- | Bodies that insert key 1, and begin a nested transaction and leave it
-- open (@\@\@TRANCOUNT@ 2 when they return).
unended :: [(String, Text -> Connection -> IO ())]
unended =
  [ ("begin after its work", \t conn -> insert conn t 1 >> begin conn)
  , ("begin before its work", \t conn -> begin conn >> insert conn t 1)
  , ("a BEGIN TRANSACTION batch", \t conn -> insert conn t 1 >> void (execute conn "BEGIN TRANSACTION"))
  , ("two BEGIN TRANSACTION (@@TRANCOUNT 3), one COMMIT TRANSACTION", \t conn -> do
      _ <- execute conn "BEGIN TRANSACTION; BEGIN TRANSACTION"
      insert conn t 1
      void (execute conn "COMMIT TRANSACTION"))
  ]

spec :: Spec
spec = around withTestDb $ do
  describe "withTransaction, with a nested transaction the body began and didn't end" $
    forM_ unended $ \(label, body) ->
      it ("throws TransactionStillOpen after rolling everything back: " ++ label) $ \conn -> withTable $ \t -> do
        stillOpen $ withTransaction conn $ do
          body t conn
          tranCount conn `shouldReturn` 2
        checkRolledBack conn t [1] []
        -- Usable for the next transaction, which commits.
        withTransaction conn (insert conn t 2)
        inTransaction conn `shouldReturn` False
        map fromOnly <$> query conn (rawSql ("SELECT i FROM " <> t <> " ORDER BY i")) `shouldReturn` [1, 2 :: Int]

  describe "withTransaction, TransactionStillOpen" $ do
    it "rolls back the work of the whole batch that began the nested transaction" $ \conn -> withTable $ \t -> do
      stillOpen $ withTransaction conn $
        execute conn (rawSql ("INSERT INTO " <> t <> " VALUES (1); BEGIN TRANSACTION; INSERT INTO " <> t <> " VALUES (2)"))
      checkRolledBack conn t [1, 2] []

    it "leaves another connection's work alone" $ \conn -> withTable $ \t -> withTestDb $ \other -> do
      insert other t 5
      stillOpen $ withTransaction conn (insert conn t 1 >> begin conn)
      checkRolledBack conn t [1] [5]

  describe "withTransactionLevel, with a nested transaction the body began and didn't end" $
    forM_ [ReadUncommitted, RepeatableRead, Serializable] $ \l ->
      it ("throws TransactionStillOpen, and the level is READ COMMITTED afterwards: " ++ show l) $ \conn -> withTable $ \t -> do
        stillOpen $ withTransactionLevel l conn (insert conn t 1 >> begin conn)
        checkRolledBack conn t [1] []
        sessionLevel conn `shouldReturn` 2

  describe "withTransaction, with a nested transaction the body began and ended" $ do
    it "commits: begin and commit" $ \conn -> withTable $ \t -> do
      withTransaction conn $ do
        insert conn t 1
        begin conn
        insert conn t 2
        commit conn
        tranCount conn `shouldReturn` 1
      inTransaction conn `shouldReturn` False
      tranCount conn `shouldReturn` 0
      withTestDb $ \other ->
        map fromOnly <$> query other (rawSql ("SELECT i FROM " <> t <> " ORDER BY i")) `shouldReturn` [1, 2 :: Int]

    it "commits: BEGIN TRANSACTION and COMMIT TRANSACTION batches" $ \conn -> withTable $ \t -> do
      withTransaction conn $ do
        _ <- execute conn "BEGIN TRANSACTION"
        insert conn t 1
        _ <- execute conn "BEGIN TRANSACTION"
        insert conn t 2
        _ <- execute conn "COMMIT TRANSACTION; COMMIT TRANSACTION"
        tranCount conn `shouldReturn` 1
      tranCount conn `shouldReturn` 0
      withTestDb $ \other ->
        map fromOnly <$> query other (rawSql ("SELECT i FROM " <> t <> " ORDER BY i")) `shouldReturn` [1, 2 :: Int]

    it "commits: withTransactionLevel, and the level is READ COMMITTED afterwards" $ \conn -> withTable $ \t -> do
      withTransactionLevel Serializable conn $ do
        begin conn
        insert conn t 1
        commit conn
      tranCount conn `shouldReturn` 0
      sessionLevel conn `shouldReturn` 2
      withTestDb $ \other ->
        fromOnly <$> query1 other (rawSql ("SELECT COUNT(*) FROM " <> t)) `shouldReturn` (1 :: Int)
