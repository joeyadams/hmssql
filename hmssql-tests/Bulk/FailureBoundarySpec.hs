-- A load that fails on either side of a batch boundary, on the client (a
-- value the column can't take) or on the server (a CHECK constraint), with
-- and without a transaction: which rows and trigger writes remain.
module Bulk.FailureBoundarySpec (spec) where

import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError, SqlServerError)
import Hmssql.Transaction
import TestDb

spec :: Spec
spec = do
    describe "bulk failure batch boundaries" $
        forM_ [False, True] $ \transactional ->
            forM_ [1, 2, 3, 5 :: Int32] $ \badRow ->
                forM_ [False, True] $ \clientFailure ->
                    it ("retains exact rows: transaction=" ++ show transactional ++ ", bad row=" ++ show badRow ++ ", client failure=" ++ show clientFailure) $ fixture $ \ci conn table -> do
                        exec conn ("CREATE TABLE " <> table <> " (id int PRIMARY KEY,v smallint CHECK(v>0)); CREATE TABLE " <> table <> "_audit (id int,v smallint)")
                        exec conn ("CREATE TRIGGER " <> table <> "_tr ON " <> table <> " AFTER INSERT AS INSERT INTO " <> table <> "_audit SELECT id,v FROM inserted")
                        let rows = [(i, if i == badRow then (if clientFailure then 32768 else -1) else i * 11) | i <- [1 .. 5 :: Int32]]
                            load = void $ bulkInsertWith (bulkCopy table){bulkBatchSize = Just 2, bulkFireTriggers = True, bulkCheckConstraints = True} conn rows
                            action = if transactional then withTransaction conn load else load
                        if clientFailure
                            then action `shouldThrow` (\(_ :: EncodeError) -> True)
                            else action `shouldThrow` (\(_ :: SqlServerError) -> True)
                        inTransaction conn `shouldReturn` False
                        let retained = if transactional then [] else [(i, i * 11) | i <- [1 .. ((badRow - 1) `div` 2) * 2]]
                        withConnection ci $ \observer -> do
                            query observer (rawSql ("SELECT id,v FROM " <> table <> " ORDER BY id")) `shouldReturn` (retained :: [(Int32, Int32)])
                            query observer (rawSql ("SELECT id,v FROM " <> table <> "_audit ORDER BY id")) `shouldReturn` retained
                        bulkInsert conn table [(99 :: Int32, 99 :: Int32)] `shouldReturn` 1
                        query1 conn "SELECT @@TRANCOUNT, XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)

fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "bulk_failure" $ \schema -> withConnection ci $ \conn -> action ci conn (schema <> ".target")

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
