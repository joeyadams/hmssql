{-# LANGUAGE DerivingStrategies #-}

module Transaction.DataBoundarySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void, when)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import Hmssql.BulkCopy (bulkInsert)
import Hmssql.Connection (reset)
import Hmssql.Errors (UnexpectedResult (..), sqlErrorNumber)
import Hmssql.Transaction
import TestDb

data Scope = Auto | Escape | Caught deriving stock (Eq, Show)

spec :: Spec
spec = do
    describe "ordered batch error effects" $
        forM_ batches $ \(name, batch) ->
            forM_ [Auto, Escape, Caught] $ \scope ->
                it (name ++ " preserves server statement boundaries, scope=" ++ show scope) $ fixture $ \ci writer table -> do
                    exec writer "SET XACT_ABORT OFF"
                    let action = batch writer table
                        duplicate e = sqlErrorNumber e == 2627
                    case scope of
                        Auto -> action `shouldThrow` duplicate
                        Escape -> withTransaction writer action `shouldThrow` duplicate
                        Caught -> withTransaction writer $ do
                            action `shouldThrow` duplicate
                            write writer table 22
                    finish ci writer table (case scope of Escape -> []; Auto -> [20, 21]; Caught -> [20, 21, 22])
    describe "row cardinality failure after completed DML" $
        forM_ [Auto, Escape, Caught] $ \scope ->
            it ("separates an empty query1 result from write durability, scope=" ++ show scope) $ fixture $ \ci writer table -> do
                let statement = rawSql ("SET NOCOUNT ON; INSERT INTO " <> table <> " VALUES(20); SELECT v FROM " <> table <> " WHERE 1=0")
                    action = void (query1 writer statement :: IO (Only Int32))
                    noRows (UnexpectedResult message) = message == "expected exactly one row, got 0"
                case scope of
                    Auto -> action `shouldThrow` noRows
                    Escape -> withTransaction writer action `shouldThrow` noRows
                    Caught -> withTransaction writer $ do
                        action `shouldThrow` noRows
                        inTransaction writer `shouldReturn` True
                        query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (1 :: Int32, 1 :: Int32)
                        write writer table 21
                finish ci writer table (case scope of Auto -> [20]; Escape -> []; Caught -> [20, 21])
    describe "fully consumed final BatchQuery streams" $
        forM_ [False, True] $ \rollbackAtEnd ->
            it ("keeps streamed DML and a following bulk write in the wrapper, rollback=" ++ show rollbackAtEnd) $ fixture $ \ci writer table -> do
                let action = withTransaction writer $ do
                        (count, stream) <-
                            runBatchQuery writer $
                                (,)
                                    <$> batchExecute (rawSql ("INSERT INTO " <> table <> " VALUES(20)"))
                                    <*> batchQueryS (rawSql ("INSERT INTO " <> table <> " OUTPUT inserted.v VALUES(21)"))
                        count `shouldBe` 1
                        S.toList_ stream `shouldReturn` [Only (21 :: Int32)]
                        inTransaction writer `shouldReturn` True
                        query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (1 :: Int32, 1 :: Int32)
                        bulkInsert writer table [Only (22 :: Int32)] `shouldReturn` 1
                        when rollbackAtEnd (throwIO (userError "rollback after completed BatchQuery stream"))
                if rollbackAtEnd then action `shouldThrow` anyIOException else action
                finish ci writer table (if rollbackAtEnd then [] else [20, 21, 22])
    describe "pool lease reset and durable transaction scope" $
        forM_ [False, True] $ \openTransaction ->
            it ("renewed handle writes independently after release, transaction was open=" ++ show openTransaction) $ fixture $ \ci writer table -> do
                begin writer
                write writer table 20
                if openTransaction then pure () else rollback writer
                release writer `shouldReturn` True
                next <- renew writer
                finish ci next table []
    it "a write carrying lazy reset is outside the rolled-back transaction" $ fixture $ \ci writer table -> do
        ( withTransaction writer $ do
                write writer table 20
                reset writer
                write writer table 21
            )
            `shouldThrow` endedEarly
        finish ci writer table [21]
    it "replacing the transaction inside the body never commits the replacement" $ fixture $ \ci writer table -> do
        ( withTransaction writer $ do
                write writer table 20
                rollback writer
                begin writer
                write writer table 21
            )
            `shouldThrow` endedEarly
        finish ci writer table []

batches :: [(String, Connection -> Text -> IO ())]
batches =
    [ ("executeStatements", \conn table -> void $ executeStatements conn [mkQuery ("INSERT INTO " <> table <> " VALUES(@p1)") (Only n) | n <- [20, 10, 21 :: Int32]])
    , ("executeMany", \conn table -> void $ executeMany conn ("INSERT INTO " <> table <> " VALUES(@p1)") (map Only [20, 10, 21 :: Int32]))
    , ("BatchQuery", \conn table -> void $ runBatchQuery conn (traverse (\n -> batchExecute (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1)") (Only n))) [20, 10, 21 :: Int32]))
    ]

fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "transaction_data" $ \schema -> withConnection ci $ \writer -> do
        let table = schema <> ".target"
        exec writer ("CREATE TABLE " <> table <> "(v int PRIMARY KEY); INSERT INTO " <> table <> " VALUES(10)")
        action ci writer table
finish :: ConnectInfo -> Connection -> Text -> [Int32] -> IO ()
finish ci writer table inside = do
    inTransaction writer `shouldReturn` False
    query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
    write writer table 30
    (withTransaction writer $ write writer table 40 >> throwIO (userError "subsequent independent rollback")) `shouldThrow` anyIOException
    inTransaction writer `shouldReturn` False
    withConnection ci $ \observer -> query observer (rawSql ("SELECT v FROM " <> table <> " ORDER BY v")) `shouldReturn` map Only ([10] ++ inside ++ [30])
write :: Connection -> Text -> Int32 -> IO ()
write conn table value = void $ execute conn (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1)") (Only value))
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
endedEarly :: TransactionError -> Bool
endedEarly TransactionEndedEarly = True
endedEarly _ = False
