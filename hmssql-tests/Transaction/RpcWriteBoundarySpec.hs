{-# LANGUAGE DerivingStrategies #-}

module Transaction.RpcWriteBoundarySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text
import Test.Hspec

import Hmssql
import Hmssql.Errors (sqlErrorNumber)
import Hmssql.Query (callProcedure, outParam)
import Hmssql.Transaction (TransactionError (..), inTransaction)
import TestDb

data Scope = Auto | Escape | Caught deriving stock (Eq, Show)

spec :: Spec
spec = forM_ [False, True] $ \throws ->
    forM_ [Auto, Escape, Caught] $ \scope ->
        it ("separates RPC output/error completion from durable writes, THROW=" ++ show throws ++ ", scope=" ++ show scope) $ do
            ci <- defaultTestConnectInfo
            withScratchSchema ci "rpc_write_scope" $ \schema -> withConnection ci $ \writer -> do
                let table = schema <> ".target"
                    audit = schema <> ".audit"
                    proc = schema <> ".write_proc"
                    errorSql = if throws then "THROW 51000,'rpc write failure',1;" else "RAISERROR('rpc write failure',16,1);"
                    code = if throws then 51000 else 50000
                    failed e = sqlErrorNumber e == code
                    write n = void $ execute writer (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1,@p2)") (n :: Int32, "sentinel " <> fromStringInt n))
                exec writer ("CREATE TABLE " <> table <> "(id int PRIMARY KEY,label nvarchar(40)); CREATE TABLE " <> audit <> "(id int,label nvarchar(40)); INSERT INTO " <> table <> " VALUES(10,N'sentinel 10')")
                exec writer ("CREATE TRIGGER " <> schema <> ".audit_insert ON " <> table <> " AFTER INSERT AS INSERT INTO " <> audit <> " SELECT id,label FROM inserted")
                exec writer ("CREATE PROCEDURE " <> proc <> " @out nvarchar(max) OUTPUT AS BEGIN SET NOCOUNT ON; SET XACT_ABORT ON; INSERT INTO " <> table <> " VALUES(20,N'inside before'); SET @out=N'output before error'; SELECT id,label FROM " <> table <> " WHERE id=20; " <> errorSql <> " INSERT INTO " <> table <> " VALUES(21,N'inside after'); SET @out=N'output after error'; RETURN 7; END")
                let output = outParam "@out" ("initial" :: Text)
                let action = void $ callProcedure writer proc [output]
                    caught = withTransaction writer $ do
                        action `shouldThrow` failed
                        query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (if throws then (0 :: Int32, 0 :: Int32) else (1, 1))
                        write 22
                case scope of
                    Auto -> action `shouldThrow` failed
                    Escape -> withTransaction writer action `shouldThrow` failed
                    Caught -> if throws then caught `shouldThrow` endedEarly else caught
                inTransaction writer `shouldReturn` False
                query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
                write 30
                withTransaction writer (write 40 >> throwIO (userError "independent RPC rollback")) `shouldThrow` anyIOException
                let inside = case scope of
                        Auto -> if throws then [(20, "inside before")] else [(20, "inside before"), (21, "inside after")]
                        Escape -> []
                        Caught -> (if throws then [] else [(20, "inside before"), (21, "inside after")]) ++ [(22, "sentinel 22")]
                    following = inside ++ [(30, "sentinel 30")]
                withConnection ci $ \observer -> do
                    query observer (rawSql ("SELECT id,label FROM " <> table <> " ORDER BY id")) `shouldReturn` ((10 :: Int32, "sentinel 10" :: Text) : following)
                    query observer (rawSql ("SELECT id,label FROM " <> audit <> " ORDER BY id")) `shouldReturn` following

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
fromStringInt :: Int32 -> Text
fromStringInt = Data.Text.pack . show
endedEarly :: TransactionError -> Bool
endedEarly TransactionEndedEarly = True
endedEarly _ = False
