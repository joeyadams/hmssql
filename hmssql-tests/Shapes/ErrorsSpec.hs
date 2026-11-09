-- | Shapes of server-reported errors: severities, THROW, TRY/CATCH, ordering
-- when several errors occur, error metadata, transaction state, and how the
-- connection behaves when the server aborts or kills the session.
module Shapes.ErrorsSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, try)
import Control.Monad (void)
import Data.IORef
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "severities" $ do
    it "delivers severity <=10 as an INFO message, not an exception" $ \_ -> do
      msgs <- newIORef []
      ci <- defaultTestConnectInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' msgs (msgText m :) } $ \conn -> do
        execute conn "RAISERROR('info msg', 10, 1)" `shouldReturn` 0
      -- login itself produces a couple of INFO messages (database, language);
      -- ours is the most recent one prepended
      (take 1 <$> readIORef msgs) `shouldReturn` ["info msg"]

    it "throws for severity 11-16" $ \conn -> do
      r <- try (execute conn "RAISERROR('sev11', 11, 1)")
      case r of
        Left e -> msgClass (sqlError e) `shouldBe` 11
        Right n -> expectationFailure ("succeeded with " ++ show n)

    it "throws for severity 17-18 without WITH LOG" $ \conn -> do
      r <- try (execute conn "RAISERROR('sev18', 18, 1)")
      case r of
        Left e -> msgClass (sqlError e) `shouldBe` 18
        Right n -> expectationFailure ("succeeded with " ++ show n)

    it "rejects severity >18 without WITH LOG, with a clean server error" $ \conn -> do
      r <- try (execute conn "RAISERROR('sev19', 19, 1)")
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 2754
        Right n -> expectationFailure ("succeeded with " ++ show n)

    it "substitutes RAISERROR format arguments" $ \conn -> do
      r <- try (execute conn "RAISERROR('value: %s and %d', 16, 1, 'foo', 42)")
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "value: foo and 42"
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "THROW" $
    it "reports the custom error number, message and state" $ \conn -> do
      r <- try (execute conn "THROW 51000, 'custom throw', 1")
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 51000
          sqlErrorMessage e `shouldBe` "custom throw"
          msgState (sqlError e) `shouldBe` 1
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "TRY/CATCH" $
    it "does not surface an error handled by CATCH" $ \conn -> do
      -- the TRY block's own SELECT still produces an (empty) result set for
      -- the statement that failed; the CATCH block's SELECT follows it
      sets <- queryMulti conn "BEGIN TRY SELECT 1 / 0 END TRY BEGIN CATCH SELECT 'caught' END CATCH"
      map (map sqlRowValues . resultRows) sets `shouldBe` [[], [[SqlText "caught"]]]

  describe "multiple errors" $ do
    it "reports the first error when several occur in one batch" $ \conn -> do
      r <- try (execute conn "RAISERROR('first', 16, 1); RAISERROR('second', 16, 1)")
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "first"
        Right n -> expectationFailure ("succeeded with " ++ show n)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "still runs (and discards) later statements after a statement-terminating error" $ \conn -> do
      _ <- execute conn "CREATE TABLE #me (i int)"
      -- both divide-by-zero errors are statement-terminating, not batch-aborting;
      -- the INSERT after them still runs
      r <- try (execute conn "SELECT 1/0; SELECT 2/0; INSERT INTO #me VALUES (1)")
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "Divide by zero error encountered."
        Right n -> expectationFailure ("succeeded with " ++ show n)
      query1 conn "SELECT COUNT(*) FROM #me" `shouldReturn` Only (1 :: Int)

  describe "errors in the middle of rows" $ do
    it "yields rows produced before a mid-result error, while streaming" $ \conn -> do
      seen <- newIORef (0 :: Int)
      r <- try $ do
        s <- queryS conn "SELECT 1 / CASE WHEN v = 3 THEN 0 ELSE 1 END FROM (VALUES (1), (2), (3), (4)) AS t(v)"
        S.mapM_ (\(Only (_ :: Int)) -> modifyIORef' seen (+ 1)) s
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "Divide by zero error encountered."
        Right () -> expectationFailure "no error"
      readIORef seen `shouldReturn` 2
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "reports arithmetic overflow" $ \conn -> do
      r <- try (execute conn "SELECT CAST(2000000000 AS int) + CAST(2000000000 AS int)")
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8115
        Right n -> expectationFailure ("succeeded with " ++ show n)

    it "reports a conversion error" $ \conn -> do
      r <- try (execute conn "SELECT CAST('abc' AS int)")
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 245
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "error metadata" $ do
    it "includes unicode and reasonably long text" $ \conn -> do
      let msg = "héllo 世界 " <> T.replicate 100 "abcdefghij"
      r <- try (execute conn (rawSql ("RAISERROR('" <> msg <> "', 16, 1)")))
      case r of
        Left e -> sqlErrorMessage e `shouldBe` msg
        Right n -> expectationFailure ("succeeded with " ++ show n)

    it "reports the line number and procedure name for an error raised inside a procedure" $ \conn -> do
      name <- uniqueName "hmssql_shapes_err_proc"
      _ <- execute conn $ rawSql
        ( "CREATE OR ALTER PROCEDURE dbo." <> name <> " AS BEGIN\n\
          \  SELECT 1;\n\
          \  RAISERROR('boom in proc', 16, 1);\n\
          \END" )
      r <- try (execute conn (rawSql ("EXEC dbo." <> name)))
      _ <- execute conn (rawSql ("DROP PROCEDURE dbo." <> name))
      case r of
        Left e -> do
          sqlErrorMessage e `shouldBe` "boom in proc"
          msgLine (sqlError e) `shouldBe` 3
          msgProcedure (sqlError e) `shouldSatisfy` T.isSuffixOf name
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "XACT_ABORT and transaction state" $ do
    it "leaves a transaction open (but usable) after a plain error, without XACT_ABORT" $ \conn -> do
      begin conn
      r <- try (execute conn "SELECT 1/0")
      case r of
        Left (_ :: SqlServerError) -> pure ()
        Right n -> expectationFailure ("succeeded with " ++ show n)
      inTransaction conn `shouldReturn` True
      query1 conn "SELECT @@TRANCOUNT, XACT_STATE()" `shouldReturn` (1 :: Int, 1 :: Int)
      rollback conn

    it "aborts the batch and rolls back the transaction with XACT_ABORT ON" $ \conn -> do
      begin conn
      inTransaction conn `shouldReturn` True
      r <- try (execute conn "SET XACT_ABORT ON; SELECT 1/0")
      case r of
        Left (_ :: SqlServerError) -> pure ()
        Right n -> expectationFailure ("succeeded with " ++ show n)
      -- the server sent a rollback ENVCHANGE along with the error
      inTransaction conn `shouldReturn` False

  describe "concurrent connections" $ do
    it "reports a deadlock (1205) to exactly one of two competing connections" $ \_ -> do
      name <- withTestDb $ \conn -> do
        n <- uniqueName "hmssql_shapes_deadlock"
        _ <- execute conn (rawSql ("CREATE TABLE dbo." <> n <> " (id int PRIMARY KEY, v int)"))
        _ <- execute conn (rawSql ("INSERT INTO dbo." <> n <> " VALUES (1, 0), (2, 0)"))
        pure n
      -- Each side asks for its second row once the other holds its first:
      -- a handoff, not a wait of a second, which one side of a busy run
      -- outlasted before the other had connected, and nothing deadlocked.
      aHolds <- newEmptyMVar
      bHolds <- newEmptyMVar
      let update conn k = void $ execute conn (mkQuery ("UPDATE dbo." <> name <> " SET v = v + 1 WHERE id = @p1") (Only (k :: Int)))
          runSide mine theirs firstId secondId = withTestDb $ \conn -> do
            -- Told to the other side whether or not it worked, so that it
            -- doesn't wait for good.
            first <- try (begin conn >> update conn firstId) `finally` putMVar mine ()
            case first of
              Left e -> pure (Left e)
              Right () -> do
                () <- takeMVar theirs
                try (update conn secondId >> commit conn)
      (ra, rb) <- concurrently (runSide aHolds bHolds 1 2) (runSide bHolds aHolds 2 1)
      let outcomes = [ra, rb] :: [Either SqlServerError ()]
          victims = [e | Left e <- outcomes]
      length victims `shouldBe` 1
      case victims of
        [e] -> sqlErrorNumber e `shouldBe` 1205
        _ -> expectationFailure ("unexpected outcomes: " ++ show outcomes)
      withTestDb $ \conn -> execute conn (rawSql ("DROP TABLE dbo." <> name)) `shouldReturn` 0

    it "surfaces a clean error (not a hang) when another connection KILLs the session" $ \conn -> do
      victimId <- sessionIdentity conn
      killer <- withTestDb $ \killerConn -> do
        r <- timeout 10000000 (try (killSessionFrom killerConn victimId) :: IO (Either SomeException ()))
        pure r
      case killer of
        Just _ -> pure ()
        Nothing -> expectationFailure "KILL timed out"
      victim <- timeout 10000000 (try (execute conn "WAITFOR DELAY '00:00:05'") :: IO (Either SomeException Int64))
      case victim of
        Nothing -> expectationFailure "victim connection hung instead of erroring"
        Just (Right n) -> expectationFailure ("victim query succeeded with " ++ show n)
        Just (Left _) -> pure ()
      -- the connection is unusable afterwards, but that must be a clean error, not a hang
      after <- timeout 10000000 (try (execute conn "SELECT 1") :: IO (Either SomeException Int64))
      case after of
        Nothing -> expectationFailure "connection hung on reuse after being killed"
        Just (Right n) -> expectationFailure ("succeeded with " ++ show n)
        Just (Left _) -> pure ()

  describe "severity 20+ (server closes the connection)" $
    skipOnAzure "RAISERROR ... WITH LOG needs sysadmin (error 2778)" $
    it "reports a clean error and the connection is unusable afterwards" $ \conn -> do
      r <- timeout 10000000 (try (execute conn "RAISERROR('sev20', 20, 1) WITH LOG") :: IO (Either SomeException Int64))
      case r of
        Nothing -> expectationFailure "hung instead of erroring"
        Just (Right n) -> expectationFailure ("succeeded with " ++ show n)
        Just (Left _) -> pure ()
      after <- timeout 10000000 (try (execute conn "SELECT 1") :: IO (Either SomeException Int64))
      case after of
        Nothing -> expectationFailure "hung on reuse after a severity-20 error"
        Just (Right n) -> expectationFailure ("succeeded with " ++ show n)
        Just (Left _) -> pure ()
