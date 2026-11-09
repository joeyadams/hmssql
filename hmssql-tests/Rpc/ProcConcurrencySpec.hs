-- | Calling procedures repeatedly and concurrently on one connection: many
-- calls in sequence, many threads sharing a connection (calls are
-- serialized, and each thread gets its own result), a call after a failed
-- one, and calls inside a transaction and after a reset.
module Rpc.ProcConcurrencySpec (spec) where

import Control.Concurrent.Async (forConcurrently_)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.Int (Int32)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Errors
import Rpc.Common
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "sequential calls" $
    it "calls many different procedures one after another on one connection" $ \conn -> do
      name <- uniqueName "hmssql_rpcconc_seq"
      withProc conn name "@x int OUTPUT AS SET @x = @x + 1" $
        forM_ [1 .. 100 :: Int32] $ \k -> do
          res <- callProcedure conn ("dbo." <> name) [out "@x" k]
          outValues res `shouldBe` [Right (SqlInt32 (k + 1))]

  describe "many threads sharing one connection" $
    it "serializes calls so each thread gets only its own result" $ \conn -> do
      name <- uniqueName "hmssql_rpcconc_threads"
      withProc conn name "@x int OUTPUT AS SET @x = @x * 2" $
        forConcurrently_ [1 .. 50 :: Int32] $ \k -> do
          res <- callProcedure conn ("dbo." <> name) [out "@x" k]
          outValues res `shouldBe` [Right (SqlInt32 (k * 2))]

  describe "recovery after a failed call" $ do
    it "a call after a failed one succeeds normally" $ \conn -> do
      name <- uniqueName "hmssql_rpcconc_after_fail"
      withProc conn name "AS SELECT 1 AS a" $ do
        r <- try (callProcedure conn "dbo.hmssql_rpcconc_no_such_proc" [])
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 2812
          Right res -> expectationFailure ("succeeded: " ++ show res)
        res <- callProcedure conn ("dbo." <> name) []
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]

    it "a call after one that raised a server error (16) succeeds normally" $ \conn -> do
      name <- uniqueName "hmssql_rpcconc_after_err"
      okName <- uniqueName "hmssql_rpcconc_after_err_ok"
      withProc conn name "AS RAISERROR('boom', 16, 1)" $
        withProc conn okName "AS SELECT 2 AS a" $ do
          r <- try (callProcedure conn ("dbo." <> name) [])
          case r of
            Left (e :: SqlServerError) -> sqlErrorMessage e `shouldBe` "boom"
            Right res -> expectationFailure ("succeeded: " ++ show res)
          res <- callProcedure conn ("dbo." <> okName) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 2]]]

  describe "inside a transaction, and after a reset" $ do
    it "calls a procedure inside withTransaction, committing its effects" $ \conn -> do
      tblName <- uniqueName "hmssql_rpcconc_tx_tbl"
      name <- uniqueName "hmssql_rpcconc_tx_proc"
      execute conn (rawSql ("CREATE TABLE #" <> tblName <> " (v int)")) `shouldReturn` 0
      withProc conn name ("AS INSERT INTO #" <> tblName <> " VALUES (1)") $ do
        withTransaction conn $ do
          res <- callProcedure conn ("dbo." <> name) []
          procResultSets res `shouldBe` []
        query conn (rawSql ("SELECT v FROM #" <> tblName)) `shouldReturn` [Only (1 :: Int32)]

    it "calls a procedure normally after reset" $ \conn -> do
      name <- uniqueName "hmssql_rpcconc_reset_proc"
      withProc conn name "AS SELECT 9 AS a" $ do
        reset conn
        res <- callProcedure conn ("dbo." <> name) []
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 9]]]
