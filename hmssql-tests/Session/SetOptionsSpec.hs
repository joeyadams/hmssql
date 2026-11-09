-- | Session @SET@ options and how they change what the public API returns:
-- @TEXTSIZE@ truncation of LOB types, @ANSI_WARNINGS@\/@ARITHABORT@ silent
-- error handling, @CONCAT_NULL_YIELDS_NULL@, @ANSI_NULLS@,
-- @QUOTED_IDENTIFIER@, @DATEFIRST@\/@DATEFORMAT@\/@LANGUAGE@ (and that binary
-- date/time parameters are unaffected), @ROWCOUNT@, @LOCK_TIMEOUT@,
-- @DEADLOCK_PRIORITY@, @IMPLICIT_TRANSACTIONS@, and @XACT_ABORT@.
module Session.SetOptionsSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, try)
import Control.Monad (forM_, void, when)
import Data.Maybe (isJust)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Time (Day, fromGregorian)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Transaction
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Query (batchRequest, responseS)
import Hmssql.Tds.Token (Token (..))
import OpenResponses (isMarsConnection)
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "SET TEXTSIZE" $ do
    it "truncates nvarchar(max)/varbinary(max)/text/ntext/image to the byte count" $ \conn -> do
      _ <- execute conn "SET TEXTSIZE 10"
      (a :: T.Text) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 100)"
      (b :: B.ByteString) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(0x61 AS varbinary(max)), 100)"
      (c :: T.Text) <- fromOnly <$> query1 conn "SELECT CAST(REPLICATE('x', 100) AS text)"
      (d :: T.Text) <- fromOnly <$> query1 conn "SELECT CAST(REPLICATE(N'x', 100) AS ntext)"
      (e :: B.ByteString) <- fromOnly <$> query1 conn "SELECT CAST(REPLICATE(CAST(0x61 AS varbinary(max)), 100) AS image)"
      -- nvarchar/ntext are UCS-2: 10 bytes = 5 characters
      (T.length a, B.length b, T.length c, T.length d, B.length e) `shouldBe` (5, 10, 10, 5, 10)
      (T.all (== 'x') a, B.all (== 0x61) b, T.all (== 'x') c, T.all (== 'x') d, B.all (== 0x61) e)
        `shouldBe` (True, True, True, True, True)
      _ <- execute conn "SET TEXTSIZE -1" -- the login's (unlimited)
      pure ()

    it "does not truncate xml, which TEXTSIZE never applies to" $ \conn -> do
      _ <- execute conn "SET TEXTSIZE 10"
      (t :: T.Text) <- fromOnly <$> query1 conn "SELECT CAST('<a>' + REPLICATE('x', 100) + '</a>' AS xml)"
      T.length t `shouldBe` (100 + 7)
      _ <- execute conn "SET TEXTSIZE -1" -- the login's (unlimited)
      pure ()

    it "decodes a value truncated mid-PLP-chunk (chunks are 8000 bytes)" $ \conn -> do
      _ <- execute conn "SET TEXTSIZE 12345"
      (big :: T.Text) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(N'y' AS nvarchar(max)), 50000)"
      (bigbin :: B.ByteString) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(0x61 AS varbinary(max)), 50000)"
      (T.length big, T.all (== 'y') big) `shouldBe` (12345 `div` 2, True)
      (B.length bigbin, B.all (== 0x61) bigbin) `shouldBe` (12345, True)
      _ <- execute conn "SET TEXTSIZE -1" -- the login's (unlimited)
      pure ()

    it "SET TEXTSIZE 0 resets to the default (4096), not zero bytes" $ \conn -> do
      _ <- execute conn "SET TEXTSIZE 0"
      (a :: T.Text) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 100)"
      T.length a `shouldBe` 100
      _ <- execute conn "SET TEXTSIZE -1" -- the login's (unlimited)
      pure ()

    it "SET TEXTSIZE -1 means unlimited" $ \conn -> do
      _ <- execute conn "SET TEXTSIZE 10; SET TEXTSIZE -1" -- -1 is also the login's
      (a :: T.Text) <- fromOnly <$> query1 conn "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 1000000)"
      T.length a `shouldBe` 1000000

  describe "SET ANSI_WARNINGS / ARITHABORT" $ do
    it "OFF: divide by zero yields NULL with an info message instead of an error" $ \conn -> do
      _ <- execute conn "SET ANSI_WARNINGS OFF; SET ARITHABORT OFF"
      Only (x :: Maybe Int) <- query1 conn "SELECT 1/0 AS x"
      x `shouldBe` Nothing
      _ <- execute conn "SET ANSI_WARNINGS ON" -- the login's (ARITHABORT is left off)
      pure ()

    it "OFF: the info message text is 'Division by zero occurred.'" $ \conn -> do
      _ <- execute conn "SET ANSI_WARNINGS OFF; SET ARITHABORT OFF"
      msgs <- msgsOf conn "SELECT 1/0 AS x"
      msgs `shouldBe` ["Division by zero occurred."]
      _ <- execute conn "SET ANSI_WARNINGS ON" -- the login's (ARITHABORT is left off)
      pure ()

    it "ANSI_WARNINGS ON (the login's default): divide by zero is a hard error, whatever ARITHABORT" $ \conn ->
      -- ARITHABORT is off at login, on with the test suite's session setup.
      forM_ ["SET ARITHABORT OFF", "SET ARITHABORT ON"] $ \arithabort -> do
        _ <- execute conn arithabort
        r <- try (query1 conn "SELECT 1/0 AS x") :: IO (Either SqlServerError (Only Int))
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 8134
          Right v -> expectationFailure (T.unpack (queryText arithabort) ++ ": succeeded: " ++ show v)

    it "OFF: string truncation into a fixed-width column is silent" $ \conn -> do
      _ <- execute conn "SET ANSI_WARNINGS OFF"
      Only (t :: T.Text) <- query1 conn "DECLARE @s varchar(3) = 'abcdef'; SELECT @s"
      t `shouldBe` "abc"
      _ <- execute conn "SET ANSI_WARNINGS ON"
      pure ()

  describe "SET CONCAT_NULL_YIELDS_NULL" $ do
    it "OFF: concatenation with NULL yields the non-NULL operand" $ \conn -> do
      _ <- execute conn "SET CONCAT_NULL_YIELDS_NULL OFF"
      query1 conn "SELECT 'a' + NULL" `shouldReturn` Only ("a" :: T.Text)
      _ <- execute conn "SET CONCAT_NULL_YIELDS_NULL ON"
      pure ()

    it "ON (the default): concatenation with NULL yields NULL" $ \conn ->
      query1 conn "SELECT 'a' + NULL" `shouldReturn` Only (Nothing :: Maybe T.Text)

  describe "SET ANSI_NULLS" $ do
    it "OFF: x = NULL is true when x is NULL" $ \conn -> do
      _ <- execute conn "SET ANSI_NULLS OFF"
      query1 conn "SELECT CASE WHEN CAST(NULL AS int) = NULL THEN 1 ELSE 0 END" `shouldReturn` Only (1 :: Int)
      _ <- execute conn "SET ANSI_NULLS ON"
      pure ()

    it "ON (the default): x = NULL is never true (unknown), even when x is NULL" $ \conn ->
      query1 conn "SELECT CASE WHEN CAST(NULL AS int) = NULL THEN 1 ELSE 0 END" `shouldReturn` Only (0 :: Int)

  describe "SET QUOTED_IDENTIFIER" $ do
    it "OFF: double quotes delimit a string literal instead of an identifier" $ \conn -> do
      _ <- execute conn "SET QUOTED_IDENTIFIER OFF"
      query1 conn "SELECT \"hello\"" `shouldReturn` Only ("hello" :: T.Text)
      _ <- execute conn "SET QUOTED_IDENTIFIER ON"
      pure ()

    it "ON (the default): double quotes delimit an identifier, so a bare string errors" $ \conn -> do
      r <- try (query1 conn "SELECT \"hello\"") :: IO (Either SqlServerError (Only T.Text))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 207 -- invalid column name 'hello'
        Right v -> expectationFailure ("succeeded: " ++ show v)

  describe "SET DATEFIRST" $
    it "changes DATEPART(weekday, ...) but not a parameter's decoded value" $ \conn -> do
      let d = fromGregorian 2024 1 1 :: Day -- a Monday
      _ <- execute conn "SET DATEFIRST 1" -- Monday first
      w1 <- fromOnly <$> query1 conn (mkQuery "SELECT DATEPART(weekday, @p1)" (Only d)) :: IO Int
      _ <- execute conn "SET DATEFIRST 7" -- Sunday first (US default)
      w7 <- fromOnly <$> query1 conn (mkQuery "SELECT DATEPART(weekday, @p1)" (Only d)) :: IO Int
      (w1, w7) `shouldBe` (1, 2)
      -- the date value itself round-trips unaffected by DATEFIRST
      query1 conn ("SELECT " <> param d) `shouldReturn` Only d
      _ <- execute conn "SET DATEFIRST 7"
      pure ()

  describe "SET DATEFORMAT / SET LANGUAGE" $ do
    it "changes how a string literal converts to date, but not a binary date parameter" $ \conn -> do
      let d = fromGregorian 2024 3 4 :: Day
      _ <- execute conn "SET DATEFORMAT mdy"
      mdy <- fromOnly <$> query1 conn "SELECT CONVERT(date, '03/04/2024')" :: IO Day
      _ <- execute conn "SET DATEFORMAT dmy"
      dmy <- fromOnly <$> query1 conn "SELECT CONVERT(date, '03/04/2024')" :: IO Day
      _ <- execute conn "SET DATEFORMAT ydm"
      (mdy, dmy) `shouldBe` (fromGregorian 2024 3 4, fromGregorian 2024 4 3)
      -- the parameter's binary encoding is unaffected by DATEFORMAT
      query1 conn ("SELECT " <> param d) `shouldReturn` Only d
      _ <- execute conn "SET DATEFORMAT mdy"
      pure ()

    it "SET LANGUAGE Deutsch/British changes string parsing of month names, not binary parameters" $ \conn -> do
      let d = fromGregorian 2024 5 6 :: Day
      _ <- execute conn "SET LANGUAGE Deutsch"
      -- "Mai" (German for May) only parses under the German language setting
      de <- fromOnly <$> query1 conn "SELECT CONVERT(date, '6 Mai 2024', 104)" :: IO Day
      de `shouldBe` fromGregorian 2024 5 6
      _ <- execute conn "SET LANGUAGE British"
      r <- try (query1 conn "SELECT CONVERT(date, '6 Mai 2024', 104)") :: IO (Either SqlServerError (Only Day))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 241 -- conversion failed
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn ("SELECT " <> param d) `shouldReturn` Only d
      _ <- execute conn "SET LANGUAGE us_english"
      pure ()

  describe "SET ROWCOUNT" $ do
    it "truncates a SELECT's rows" $ \conn -> do
      _ <- execute conn "SET ROWCOUNT 2"
      rows <- query conn "SELECT v FROM (VALUES (1),(2),(3),(4)) t(v)" :: IO [Only Int]
      length rows `shouldBe` 2
      _ <- execute conn "SET ROWCOUNT 0"
      pure ()

    it "limits how many rows an INSERT affects, and the reported count reflects it" $ \conn -> do
      _ <- execute conn "SET ROWCOUNT 0"
      _ <- execute conn "CREATE TABLE #rc (i int)"
      n <- execute conn "SET ROWCOUNT 3; INSERT INTO #rc SELECT v FROM (VALUES (1),(2),(3),(4),(5)) t(v)"
      n `shouldBe` 3
      _ <- execute conn "SET ROWCOUNT 0"
      query1 conn "SELECT COUNT(*) FROM #rc" `shouldReturn` Only (3 :: Int)

    it "also limits how many rows an UPDATE affects" $ \conn -> do
      _ <- execute conn "SET ROWCOUNT 0"
      _ <- execute conn "CREATE TABLE #rcu (i int); INSERT INTO #rcu SELECT v FROM (VALUES (1),(2),(3),(4),(5)) t(v)"
      n <- execute conn "SET ROWCOUNT 2; UPDATE #rcu SET i = i + 100"
      n `shouldBe` 2
      _ <- execute conn "SET ROWCOUNT 0"
      query1 conn "SELECT COUNT(*) FROM #rcu WHERE i > 100" `shouldReturn` Only (2 :: Int)

    it "SET ROWCOUNT 0 (the default) removes the limit" $ \conn -> do
      _ <- execute conn "SET ROWCOUNT 5; SET ROWCOUNT 0"
      rows <- query conn "SELECT v FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) t(v)" :: IO [Only Int]
      length rows `shouldBe` 7

  describe "SET LOCK_TIMEOUT" $
    it "raises error 1222 cleanly, leaving the connection usable" $ \victim -> do
      name <- ("dbo." <>) <$> uniqueName "session_lock_timeout"
      _ <- execute victim (rawSql ("CREATE TABLE " <> name <> " (id int PRIMARY KEY, v int)"))
      _ <- execute victim (rawSql ("INSERT INTO " <> name <> " VALUES (1, 1)"))
      (do
        withTestDb $ \holder -> do
          ready <- newEmptyMVar
          release <- newEmptyMVar
          done <- newEmptyMVar
          _ <- forkIO $ flip finally (putMVar done ()) $ do
            begin holder
            _ <- execute holder (rawSql ("UPDATE " <> name <> " SET v = 2 WHERE id = 1"))
            putMVar ready ()
            takeMVar release
            _ <- execute holder "ROLLBACK"
            pure ()
          takeMVar ready
          threadDelay 100000
          _ <- execute victim "SET LOCK_TIMEOUT 200"
          r <- try (execute victim (rawSql ("UPDATE " <> name <> " SET v = 3 WHERE id = 1"))) :: IO (Either SqlServerError Int64)
          -- The holder's ROLLBACK must be over before withTestDb closes
          -- its connection, or it fails (on the holder's thread, which
          -- prints it).
          putMVar release ()
          takeMVar done
          case r of
            Left e -> sqlErrorNumber e `shouldBe` 1222
            Right n -> expectationFailure ("succeeded: " ++ show n)
          -- the connection is still usable
          query1 victim "SELECT 1" `shouldReturn` Only (1 :: Int)
          _ <- execute victim "SET LOCK_TIMEOUT -1"
          pure ())
        `finally` (void (execute victim (rawSql ("DROP TABLE IF EXISTS " <> name))))

  describe "SET DEADLOCK_PRIORITY" $
    it "is accepted for every documented value without error" $ \conn ->
      mapM_ (\p -> execute conn ("SET DEADLOCK_PRIORITY " <> p) `shouldReturn` 0)
        ["LOW", "NORMAL", "HIGH", "-10", "0", "10"]

  -- Under MARS a transaction a batch starts may not outlive the batch: the
  -- server rolls it back at the end of the batch, undoing the statement,
  -- with error 3997.  So there an implicit transaction is never open between
  -- requests; a batch that ends the one it started is fine.
  describe "SET IMPLICIT_TRANSACTIONS" $ do
    it "does not start a transaction for a SELECT, but does for DDL/DML" $ \conn -> do
      _ <- execute conn "SET IMPLICIT_TRANSACTIONS ON"
      inTransaction conn `shouldReturn` False
      _ <- execute conn "SELECT 1"
      inTransaction conn `shouldReturn` False
      if isMarsConnection conn
        then do
          implicitRolledBack conn "CREATE TABLE #impl (i int)"
          tempTable conn "#impl" `shouldReturn` (0, False)
          _ <- execute conn "CREATE TABLE #impl (i int); INSERT INTO #impl VALUES (1); COMMIT"
          inTransaction conn `shouldReturn` False
          tempTable conn "#impl" `shouldReturn` (0, True)
        else do
          _ <- execute conn "CREATE TABLE #impl (i int)"
          inTransaction conn `shouldReturn` True
          query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (1 :: Int)
          _ <- execute conn "INSERT INTO #impl VALUES (1)"
          inTransaction conn `shouldReturn` True
          _ <- execute conn "COMMIT"
          inTransaction conn `shouldReturn` False
      _ <- execute conn "SET IMPLICIT_TRANSACTIONS OFF"
      pure ()

    -- Under MARS no implicit transaction can be open when withTransaction
    -- starts; inside it, a statement starts none of its own, and the COMMIT
    -- commits the statement.
    it "withTransaction refuses to start while an implicit transaction is already open" $ \conn -> do
      _ <- execute conn "SET IMPLICIT_TRANSACTIONS ON"
      if isMarsConnection conn
        then do
          implicitRolledBack conn "CREATE TABLE #impl_wt (i int)"
          withTransaction conn (void (execute conn "CREATE TABLE #impl_wt (i int)"))
          inTransaction conn `shouldReturn` False
          tempTable conn "#impl_wt" `shouldReturn` (0, True)
        else do
          _ <- execute conn "CREATE TABLE #impl_wt (i int)"
          inTransaction conn `shouldReturn` True
          r <- try (withTransaction conn (execute conn "SELECT 1")) :: IO (Either TransactionError Int64)
          case r of
            Left TransactionAlreadyActive -> pure ()
            other -> expectationFailure ("expected TransactionAlreadyActive, got " ++ either show (const "success") other)
          void $ execute conn "COMMIT"
      _ <- execute conn "SET IMPLICIT_TRANSACTIONS OFF"
      pure ()

    -- Under MARS there is no implicit transaction open to roll back; the
    -- reset still clears the option.
    it "reset() rolls back an open implicit transaction and clears the option" $ \conn -> do
      _ <- execute conn "SET IMPLICIT_TRANSACTIONS ON"
      if isMarsConnection conn
        then implicitRolledBack conn "CREATE TABLE #impl_reset (i int)"
        else do
          _ <- execute conn "CREATE TABLE #impl_reset (i int)"
          _ <- execute conn "INSERT INTO #impl_reset VALUES (1)"
          inTransaction conn `shouldReturn` True
      reset conn
      -- inTransaction only reflects the reset once a request has carried it out
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
      inTransaction conn `shouldReturn` False
      -- IMPLICIT_TRANSACTIONS is back to the login's OFF: a
      -- plain SELECT no longer opens a transaction
      _ <- execute conn "SELECT 1"
      inTransaction conn `shouldReturn` False
      -- (nor does DDL, which under MARS would fail if it did)
      when (isMarsConnection conn) $ do
        _ <- execute conn "CREATE TABLE #impl_reset (i int)"
        tempTable conn "#impl_reset" `shouldReturn` (0, True)

  describe "SET XACT_ABORT" $ do
    it "ON: an uncaught error in the body propagates, and rolls back the whole transaction" $ \conn -> withTable conn $ \t -> do
      _ <- execute conn "SET XACT_ABORT ON"
      r <- try $ withTransaction conn $ do
        _ <- execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))
        execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int))) -- duplicate PK
      case (r :: Either SqlServerError Int64) of
        Left e -> sqlErrorNumber e `shouldBe` 2627
        Right n -> expectationFailure ("succeeded: " ++ show n)
      inTransaction conn `shouldReturn` False
      query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t)) `shouldReturn` Only (0 :: Int)
      _ <- execute conn "SET XACT_ABORT OFF"
      pure ()

    it "ON: an error under sp_executesql, caught by the body, still ends the transaction early" $ \conn -> withTable conn $ \t -> do
      _ <- execute conn "SET XACT_ABORT ON"
      r <- try $ withTransaction conn $ do
        _ <- execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))
        _ <- try (execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))) :: IO (Either SqlServerError Int64)
        -- the transaction is already gone even though the body caught the error
        inTransaction conn `shouldReturn` False
      case (r :: Either TransactionError ()) of
        Left TransactionEndedEarly -> pure ()
        other -> expectationFailure ("expected TransactionEndedEarly, got " ++ show other)
      inTransaction conn `shouldReturn` False
      query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t)) `shouldReturn` Only (0 :: Int)
      _ <- execute conn "SET XACT_ABORT OFF"
      pure ()

    it "OFF (the default): an error rolls back only the failed statement" $ \conn -> withTable conn $ \t -> do
      _ <- execute conn "SET XACT_ABORT OFF"
      withTransaction conn $ do
        _ <- execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))
        r <- try (execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))) :: IO (Either SqlServerError Int64)
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 2627
          Right n -> expectationFailure ("succeeded: " ++ show n)
        inTransaction conn `shouldReturn` True
      inTransaction conn `shouldReturn` False
      query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t)) `shouldReturn` Only (1 :: Int)

-- | INFO message texts from running one batch.
msgsOf :: Connection -> T.Text -> IO [T.Text]
msgsOf conn sql = do
  toks <- responseS conn (batchRequest sql) >>= S.toList_
  pure [msgText m | TInfo m <- toks]

-- | A real table (unique per test) with an @id@ primary key, dropped afterwards.
withTable :: Connection -> (T.Text -> IO a) -> IO a
withTable conn act = do
  name <- ("dbo." <>) <$> uniqueName "session_setopts"
  _ <- execute conn (rawSql ("CREATE TABLE " <> name <> " (id int PRIMARY KEY)"))
  act name `finally` void (execute conn (rawSql ("DROP TABLE IF EXISTS " <> name)))

-- | Under MARS with IMPLICIT_TRANSACTIONS on: the statement starts a
-- transaction, which the server rolls back at the end of the batch (error
-- 3997); nothing is left open.
implicitRolledBack :: Connection -> Query -> IO ()
implicitRolledBack conn sql = do
  r <- try (execute conn sql)
  either sqlErrorNumber (const 0) r `shouldBe` 3997
  inTransaction conn `shouldReturn` False

-- | @\@\@TRANCOUNT@, and whether the temp table exists (read without a
-- table, so that IMPLICIT_TRANSACTIONS starts no transaction).
tempTable :: Connection -> T.Text -> IO (Int, Bool)
tempTable conn name = do
  (n, oid) <- query1 conn (mkQuery "SELECT @@TRANCOUNT, OBJECT_ID(@p1)" (Only ("tempdb.." <> name)))
  pure (n, isJust (oid :: Maybe Int))
