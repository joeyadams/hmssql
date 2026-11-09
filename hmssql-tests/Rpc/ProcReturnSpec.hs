-- | RETURN status in depth: negative and large values, an absent RETURN,
-- RETURN after a caught error, and RETURN through nested calls.
module Rpc.ProcReturnSpec (spec) where

import Control.Exception (finally, try)
import Data.Int (Int32)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Errors
import Rpc.Common
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "RETURN values" $ do
    it "reports a negative RETURN status" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_neg"
      withProc conn name "AS RETURN -7" $ do
        res <- callProcedure conn ("dbo." <> name) []
        procReturnStatus res `shouldBe` Just (-7)

    it "reports the minimum and maximum int32 RETURN status" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_extreme"
      withProc conn name "@big bit AS IF @big = 1 RETURN 2147483647 ELSE RETURN -2147483648" $ do
        let pBig = inParam "@big" True
        let pSmall = inParam "@big" False
        resBig <- callProcedure conn ("dbo." <> name) [pBig]
        resSmall <- callProcedure conn ("dbo." <> name) [pSmall]
        procReturnStatus resBig `shouldBe` Just (maxBound :: Int32)
        procReturnStatus resSmall `shouldBe` Just (minBound :: Int32)

    it "reports 0 for a procedure with no explicit RETURN" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_none"
      withProc conn name "AS BEGIN SELECT 1 AS a END" $ do
        res <- callProcedure conn ("dbo." <> name) []
        procReturnStatus res `shouldBe` Just 0

    it "reports a RETURN issued from inside a caught error's CATCH block" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_caught"
      withProc conn name
        "AS BEGIN TRY; SELECT 1/0; END TRY \
        \BEGIN CATCH RETURN ERROR_NUMBER(); END CATCH" $ do
        res <- callProcedure conn ("dbo." <> name) []
        procReturnStatus res `shouldBe` Just 8134  -- divide by zero

  describe "RETURN through nested calls" $ do
    it "an inner procedure's RETURN does not automatically become the outer's" $ \conn -> do
      inner <- uniqueName "hmssql_rpcret_inner"
      outer <- uniqueName "hmssql_rpcret_outer"
      mkProc conn inner "AS RETURN 42"
      let cleanup = dropProc conn outer >> dropProc conn inner
      flip finally cleanup $ do
        -- The outer procedure calls the inner one but never captures its
        -- RETURN value, so the outer's own (implicit 0) status is reported.
        mkProc conn outer ("AS BEGIN EXEC dbo." <> inner <> "; END")
        res <- callProcedure conn ("dbo." <> outer) []
        procReturnStatus res `shouldBe` Just 0

    it "an outer procedure can propagate an inner RETURN explicitly" $ \conn -> do
      inner <- uniqueName "hmssql_rpcret_inner2"
      outer <- uniqueName "hmssql_rpcret_outer2"
      mkProc conn inner "AS RETURN 55"
      let cleanup = dropProc conn outer >> dropProc conn inner
      flip finally cleanup $ do
        mkProc conn outer ("AS BEGIN DECLARE @r int; EXEC @r = dbo." <> inner <> "; RETURN @r END")
        res <- callProcedure conn ("dbo." <> outer) []
        procReturnStatus res `shouldBe` Just 55

    it "an outer procedure's own RETURN wins when it doesn't propagate the inner one" $ \conn -> do
      inner <- uniqueName "hmssql_rpcret_inner3"
      outer <- uniqueName "hmssql_rpcret_outer3"
      mkProc conn inner "AS RETURN 1"
      let cleanup = dropProc conn outer >> dropProc conn inner
      flip finally cleanup $ do
        mkProc conn outer ("AS BEGIN EXEC dbo." <> inner <> "; RETURN 99 END")
        res <- callProcedure conn ("dbo." <> outer) []
        procReturnStatus res `shouldBe` Just 99

  describe "RAISERROR severity 10 (informational)" $
    it "doesn't throw, and doesn't interfere with output parameters or RETURN" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_info"
      withProc conn name
        "@x int OUTPUT AS BEGIN RAISERROR('just fyi', 10, 1); SET @x = 5; RETURN 3 END" $ do
        res <- callProcedure conn ("dbo." <> name) [out "@x" (0 :: Int32)]
        procReturnStatus res `shouldBe` Just 3
        outValues res `shouldBe` [Right (SqlInt32 5)]

  describe "RAISERROR severity 16 after partial output" $
    it "throws, and no RETURN status or output values are available" $ \conn -> do
      name <- uniqueName "hmssql_rpcret_sev16"
      withProc conn name
        "@x int OUTPUT AS BEGIN SET @x = 1; RAISERROR('boom', 16, 1); SET @x = 2; RETURN 7 END" $ do
        r <- try (callProcedure conn ("dbo." <> name) [out "@x" (0 :: Int32)])
        case r of
          Left (e :: SqlServerError) -> sqlErrorMessage e `shouldBe` "boom"
          Right res -> expectationFailure ("succeeded: " ++ show res)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
