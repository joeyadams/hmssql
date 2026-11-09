-- | Shapes of an RPC response in depth: many result sets alongside output
-- parameters (and the pairing between them), PRINT/info messages
-- interleaved, session state that is and isn't scoped to the call, nesting
-- limits, and cancellation.
module Rpc.ProcResultsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (finally, try)
import Control.Monad (forM_)
import Data.Int (Int32)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Test.Hspec

import Concurrency.Harness (elapsed, expectUsable, within)
import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import OpenResponses (isMarsConnection)
import Rpc.Common
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "many result sets alongside output parameters" $
    it "reports 0, 1 and 50 result sets, with output values always coming after all of them" $ \conn ->
      forM_ [0, 1, 50 :: Int] $ \n -> do
        name <- uniqueName "hmssql_rpcres_many"
        let selects = if n == 0 then "" else T.concat ["SELECT " <> tshow k <> " AS a; " | k <- [1 .. n]]
            body = "@x int OUTPUT AS BEGIN " <> selects <> "SET @x = " <> tshow n <> " END"
        withProc conn name body $ do
          res <- callProcedure conn ("dbo." <> name) [out "@x" (0 :: Int32)]
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 (fromIntegral k)]] | k <- [1 .. n]]
          outValues res `shouldBe` [Right (SqlInt32 (fromIntegral n))]

  describe "a large result set followed by output parameters" $
    it "pairs a big row count with the output values correctly" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_huge"
      withProc conn name
        "@n int, @count int OUTPUT AS BEGIN \
        \SELECT TOP (@n) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn \
        \  FROM sys.all_columns a CROSS JOIN sys.all_columns b; \
        \SET @count = @n; END" $ do
        let n = 50000 :: Int32
        res <- callProcedure conn ("dbo." <> name) [inp "@n" n, out "@count" (0 :: Int32)]
        case procResultSets res of
          [rs] -> length (resultRows rs) `shouldBe` fromIntegral n
          other -> expectationFailure ("result sets: " ++ show (map (length . resultRows) other))
        outValues res `shouldBe` [Right (SqlInt32 n)]

  describe "result sets of varying shape in a single call" $
    it "reports each result set's own column count" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_shapes"
      withProc conn name
        "AS BEGIN SELECT 1 AS a; SELECT 1 AS a, 2 AS b; SELECT 1 AS a, 2 AS b, 3 AS c; END" $ do
        res <- callProcedure conn ("dbo." <> name) []
        map (length . resultColumns) (procResultSets res) `shouldBe` [1, 2, 3]

  describe "PRINT between result sets" $
    it "doesn't disturb result-set pairing, and reaches the info-message callback" $ \_ -> do
      msgsRef <- newIORef []
      ci <- defaultTestConnectInfo
      withConnection ci { connectOnInfoMessage = \m -> atomicModifyIORef' msgsRef (\ms -> (msgText m : ms, ())) } $ \conn -> do
        -- Login's own session-setup batch (setting the database, language,
        -- ...) produces its own info messages; clear those before the part
        -- under test.
        writeIORef msgsRef []
        name <- uniqueName "hmssql_rpcres_print"
        withProc conn name
          "AS BEGIN PRINT 'first'; SELECT 1 AS a; PRINT 'second'; SELECT 2 AS b; PRINT 'third'; END" $ do
          res <- callProcedure conn ("dbo." <> name) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]], [[SqlInt32 2]]]
        msgs <- reverse <$> readIORef msgsRef
        msgs `shouldBe` ["first", "second", "third"]

  describe "a transaction left open by a procedure" $
    it "reports error 266, and hmssql's transaction tracking matches the server's" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_opentran"
      withProc conn name "AS BEGIN BEGIN TRANSACTION; SELECT 1 AS a; END" $ do
        r <- try (callProcedure conn ("dbo." <> name) [])
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 266
          Right res -> expectationFailure ("succeeded: " ++ show res)
        if isMarsConnection conn
          then do
            -- Under MARS a transaction a request starts may not outlive the
            -- request: the server rolls it back (error 3997, after the 266).
            inTransaction conn `shouldReturn` False
            query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
          else do
            inTransaction conn `shouldReturn` True
            query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (1 :: Int)
        rollback conn
        inTransaction conn `shouldReturn` False
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "session state scoped to the call" $
    it "SET options changed inside a procedure revert to the caller's when it returns" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_setoption"
      withProc conn name "AS SET DATEFORMAT dmy" $ do
        _ <- callProcedure conn ("dbo." <> name) []
        -- Default DATEFORMAT is mdy: '01/02/2020' is January 2nd, not the
        -- 1st of February that dmy (set only inside the procedure) would give.
        query1 conn "SELECT CAST('01/02/2020' AS date)" `shouldReturn` Only (fromGregorian 2020 1 2)

  describe "EXECUTE AS / REVERT" $
    it "runs under the impersonated context and reverts, without upsetting result-set decoding" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_execas"
      user <- uniqueName "hmssql_rpcres_execas_user"
      -- A user without a login, so the impersonated context differs from
      -- the caller's; USER_NAME() shows it (SUSER_SNAME() under
      -- impersonation is refused on Azure SQL Database, error 40529).
      Only me <- query1 conn "SELECT USER_NAME()"
      execute conn (rawSql ("CREATE USER " <> quoteName user <> " WITHOUT LOGIN")) `shouldReturn` 0
      flip finally (execute conn (rawSql ("DROP USER IF EXISTS " <> quoteName user))) $
        withProc conn name
          ("AS BEGIN EXECUTE AS USER = N'" <> user <> "'; SELECT USER_NAME() AS whoami; REVERT; SELECT USER_NAME() AS whoami2; END") $ do
          res <- callProcedure conn ("dbo." <> name) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlText user]], [[SqlText me]]]

  describe "WITH RECOMPILE" $
    it "calls normally" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_recompile"
      execute conn (rawSql ("CREATE OR ALTER PROCEDURE dbo." <> name <> " WITH RECOMPILE AS SELECT 1 AS a")) `shouldReturn` 0
      res <- callProcedure conn ("dbo." <> name) [] `finally` dropProc conn name
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]

  describe "NOCOUNT ON/OFF" $
    it "doesn't change which result sets callProcedure reports" $ \conn ->
      forM_ [False, True] $ \nc -> do
        name <- uniqueName "hmssql_rpcres_nocount"
        let body = "AS BEGIN " <> (if nc then "SET NOCOUNT ON; " else "SET NOCOUNT OFF; ")
              <> "CREATE TABLE #hmssql_rpcres_nc (v int); INSERT INTO #hmssql_rpcres_nc VALUES (1),(2),(3); \
                 \SELECT v FROM #hmssql_rpcres_nc ORDER BY v; END"
        withProc conn name body $ do
          res <- callProcedure conn ("dbo." <> name) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1], [SqlInt32 2], [SqlInt32 3]]]

  describe "recursion limit" $ do
    it "succeeds within the nesting limit" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_recurse_ok"
      withProc conn name
        ("@n int AS BEGIN DECLARE @m int = @n - 1; IF @n > 0 EXEC dbo." <> name <> " @n = @m; ELSE SELECT 1 AS a; END") $ do
        res <- callProcedure conn ("dbo." <> name) [inp "@n" (30 :: Int32)]
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]

    it "reports a clean error (217) past the maximum nesting level (32)" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_recurse_bad"
      withProc conn name
        ("@n int AS BEGIN DECLARE @m int = @n - 1; IF @n > 0 EXEC dbo." <> name <> " @n = @m; ELSE SELECT 1 AS a; END") $ do
        r <- try (callProcedure conn ("dbo." <> name) [inp "@n" (40 :: Int32)])
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 217
          Right res -> expectationFailure ("succeeded: " ++ show res)

  -- Wall-clock bounds: alone (see TestDb.serial).
  serial $ describe "cancellation" $
    it "cancels a long-running procedure call that loses a race, leaving the connection usable" $ \conn -> do
      name <- uniqueName "hmssql_rpcres_cancel"
      withProc conn name "AS BEGIN WAITFOR DELAY '00:00:10'; SELECT 1 AS a; END" $ do
        (r, t) <- elapsed $ race (() <$ callProcedure conn ("dbo." <> name) []) (threadDelay 100_000)
        r `shouldBe` Right ()
        t `shouldSatisfy` (< 2)
        (_, t2) <- elapsed (within 10 (expectUsable conn))
        t2 `shouldSatisfy` (< 2)
