-- ORDER applies to each INSERT BULK, not to the concatenation of batches.
-- Incorrect ordering is a server error, with the same batch atomicity rules.
module Bulk.OrderBoundarySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.List (sort)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (sqlErrorNumber)
import Hmssql.Transaction (inTransaction)
import TestDb

spec :: Spec
spec = do
    forM_ [False, True] $ \tablock ->
        forM_ [False, True] $ \wrapped ->
            forM_ [([2, 1, 3, 4], []), ([1, 2, 4, 3], [1, 2])] $ \(ids, earlier) ->
                it ("checks sortedness within a batch and its durable effects, rows=" ++ show ids ++ ", wrapper=" ++ show wrapped ++ ", TABLOCK=" ++ show tablock) $ fixture $ \ci conn target audit -> do
                    let action = bulkInsertWith (options target){bulkTableLock = tablock} conn (map row ids)
                    (if wrapped then withTransaction conn action else action) `shouldThrow` (\e -> sqlErrorNumber e == 4819)
                    finish ci conn target audit (if wrapped then [] else earlier)
    it "accepts global disorder when each separate batch is sorted" $ fixture $ \ci conn target audit -> do
        bulkInsertWith (options target) conn (map row [1, 3, 2, 4]) `shouldReturn` 4
        finish ci conn target audit [1, 2, 3, 4]
    -- The check is the clustered index's: a heap takes the rows in any
    -- order and the hint changes nothing.
    it "ignores the order on a heap" $ \_ -> do
        ci <- defaultTestConnectInfo
        withConnection ci $ \conn -> do
            exec conn "CREATE TABLE #order_heap(id int,label int)"
            bulkInsertWith (options "#order_heap") conn (map row [2, 1, 4, 3]) `shouldReturn` 4
            query conn "SELECT id FROM #order_heap ORDER BY id" `shouldReturn` map Only [1, 2, 3, 4 :: Int32]

options :: Text -> BulkCopy
options target = (bulkCopy target){bulkTableLock = True, bulkFireTriggers = True, bulkBatchSize = Just 2, bulkOrder = [Ascending "id"]}
row :: Int32 -> (Int32, Int32)
row i = (i, i * 101)
fixture :: (ConnectInfo -> Connection -> Text -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "order_boundary" $ \schema -> withConnection ci $ \conn -> do
        let target = schema <> ".target"
            audit = schema <> ".audit"
        exec conn ("CREATE TABLE " <> target <> "(id int PRIMARY KEY CLUSTERED,label int); CREATE TABLE " <> audit <> "(id int,label int); INSERT INTO " <> target <> " VALUES(0,0)")
        exec conn ("CREATE TRIGGER " <> schema <> ".capture ON " <> target <> " AFTER INSERT AS INSERT INTO " <> audit <> " SELECT id,label FROM inserted")
        action ci conn target audit
finish :: ConnectInfo -> Connection -> Text -> Text -> [Int32] -> IO ()
finish ci conn target audit survived = do
    inTransaction conn `shouldReturn` False
    query1 conn "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
    exec conn ("INSERT INTO " <> target <> " VALUES(10,1010)")
    withTransaction conn (exec conn ("INSERT INTO " <> target <> " VALUES(20,2020)") >> throwIO (userError "independent ORDER rollback")) `shouldThrow` anyIOException
    withConnection ci $ \observer -> do
        query observer (rawSql ("SELECT id,label FROM " <> target <> " ORDER BY id")) `shouldReturn` map row (sort (0 : 10 : survived))
        query observer (rawSql ("SELECT id,label FROM " <> audit <> " ORDER BY id")) `shouldReturn` map row (sort (10 : survived))
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
