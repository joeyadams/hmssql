{-# LANGUAGE DerivingStrategies #-}

module Bulk.AtomicityBoundarySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (sqlErrorNumber)
import Hmssql.Transaction
import TestDb

data FailureScope = Autocommit | EscapeWrapper | CatchInside deriving stock (Eq, Show)
type Row = (Int32, Int32, Text, B.ByteString)

spec :: Spec
spec = do
    describe "trigger RAISERROR across completed and failing batches" $
        forM_ [Autocommit, EscapeWrapper, CatchInside] $ \scope ->
            forM_ [1, 3, 5 :: Int32] $ \badRow ->
                it ("observes exact durable rows and audit effects, " ++ show scope ++ ", bad row=" ++ show badRow) $ fixture $ \ci conn table -> do
                    exec conn ("CREATE TRIGGER " <> table <> "_report ON " <> table <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; INSERT INTO " <> table <> "_audit SELECT id,v,label,bytes FROM inserted; IF EXISTS(SELECT 1 FROM inserted WHERE v<0) RAISERROR('batch value rejected by application',16,1); END")
                    write conn table baselineRow
                    exec conn "SET XACT_ABORT ON"
                    let rows = [(i, if i == badRow then -i else i * 11, "r" <> T.pack (show i) <> " tail  ", B.pack [fromIntegral i, 0, 255]) | i <- [1 .. 5]]
                        load = void $ bulkInsertWith (bulkCopy table){bulkBatchSize = Just 2, bulkFireTriggers = True} conn rows
                        reported e = sqlErrorNumber e == 50000
                    case scope of
                        Autocommit -> load `shouldThrow` reported
                        EscapeWrapper -> withTransaction conn load `shouldThrow` reported
                        CatchInside -> withTransaction conn $ do
                            load `shouldThrow` reported
                            query1 conn "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (1 :: Int32, 1 :: Int32)
                            write conn table caught
                    inTransaction conn `shouldReturn` False
                    let retained = if scope == EscapeWrapper then [] else take (fromIntegral (min 5 (((badRow + 1) `div` 2) * 2))) rows
                        expected = [baselineRow] ++ retained ++ [caught | scope == CatchInside]
                    finish ci conn table expected
    describe "bounded producer failures beside batch boundaries" $
        forM_ [False, True] $ \transactional ->
            forM_ [1, 2, 3 :: Int32] $ \prefix ->
                it ("retains only complete batches before producer failure, prefix=" ++ show prefix ++ ", wrapper=" ++ show transactional) $ fixture $ \ci conn table -> do
                    exec conn ("CREATE TRIGGER " <> table <> "_report ON " <> table <> " AFTER INSERT AS INSERT INTO " <> table <> "_audit SELECT id,v,label,bytes FROM inserted")
                    write conn table baselineRow
                    let values = [(i, i * 11, "r" <> T.pack (show i), B.pack [fromIntegral i, 0, 255]) | i <- [1 .. prefix]]
                        producer = S.each values >> liftIO (throwIO (userError "finite producer stopped"))
                        action = void $ bulkInsertSWith (bulkCopy table){bulkBatchSize = Just 2, bulkFireTriggers = True} conn producer
                    (if transactional then withTransaction conn action else action) `shouldThrow` anyIOException
                    let retained = if transactional then [] else take (fromIntegral ((prefix `div` 2) * 2)) values
                    finish ci conn table (baselineRow : retained)

baselineRow, caught, followingRow, rolledBack :: Row
baselineRow = (900, 900, "before  ", B.pack [0, 0])
caught = (800, 800, "caught  ", B.pack [0xCA, 0, 0])
followingRow = (902, 902, "after  ", B.pack [0xAF, 0, 0])
rolledBack = (903, 903, "rolled back", B.empty)

finish :: ConnectInfo -> Connection -> Text -> [Row] -> IO ()
finish ci conn table expected = do
    inTransaction conn `shouldReturn` False
    query1 conn "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
    write conn table followingRow
    (withTransaction conn $ write conn table rolledBack >> throwIO (userError "later rollback")) `shouldThrow` anyIOException
    query1 conn "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
    withConnection ci $ \observer -> forM_ [table, table <> "_audit"] $ \target ->
        query observer (rawSql ("SELECT id,v,label,bytes FROM " <> target <> " ORDER BY id")) `shouldReturn` sortOn (\(i, _, _, _) -> i) (followingRow : expected)

write :: Connection -> Text -> Row -> IO ()
write conn table row = void $ execute conn (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1,@p2,@p3,@p4)") row)
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "atomic_boundary" $ \schema -> withConnection ci $ \conn -> do
        let table = schema <> ".target"
        exec conn ("CREATE TABLE " <> table <> "(id int PRIMARY KEY,v int,label nvarchar(32),bytes varbinary(8)); CREATE TABLE " <> table <> "_audit(id int,v int,label nvarchar(32),bytes varbinary(8))")
        action ci conn table
