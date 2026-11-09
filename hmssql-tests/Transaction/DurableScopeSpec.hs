-- Durable effects of a transaction's body, read by an independent observer
-- after commit, rollback, a caught server error, a decode failure, a reset
-- and every three-step sequence of commit, exception and conversion error;
-- a status assertion alone can't show whether work leaked.
module Transaction.DurableScopeSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Text (Text)
import Data.Time (Day)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import Hmssql.BulkCopy
import Hmssql.Connection (reset)
import Hmssql.Errors (DecodeError, SqlServerError)
import Hmssql.Transaction
import TestDb

spec :: Spec
spec = do
    describe "durable transaction scope" $
        forM_ scenarios $ \(label, inside, action) ->
            it label $ fixture $ \ci conn table -> do
                exec conn ("CREATE TABLE " <> table <> " (v int PRIMARY KEY)")
                write conn table 10
                action conn table
                inTransaction conn `shouldReturn` False
                query1 conn "SELECT @@TRANCOUNT, XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
                write conn table 30
                (withTransaction conn $ write conn table 40 >> boom) `shouldThrow` anyIOException
                inTransaction conn `shouldReturn` False
                withConnection ci $ \observer ->
                    query observer (rawSql ("SELECT v FROM " <> table <> " ORDER BY v")) `shouldReturn` map Only ([10] ++ inside ++ [30] :: [Int32])
    describe "short transaction models" $
        forM_ (sequence (replicate 3 [0, 1, 2 :: Int])) $ \steps ->
            it ("matches committed values after " ++ show steps) $ fixture $ \ci conn table -> do
                exec conn ("CREATE TABLE " <> table <> " (v int)")
                forM_ (zip [1 ..] steps) $ \(i, kind) -> do
                    let inside = i * 10 :: Int32
                        load = if even i then void (bulkInsert conn table [Only inside]) else write conn table inside
                        action = withTransaction conn $ do
                            load
                            case kind of
                                0 -> pure ()
                                1 -> boom
                                _ -> badConversion conn
                    case kind of
                        0 -> action
                        1 -> action `shouldThrow` anyIOException
                        _ -> action `shouldThrow` sqlError
                    write conn table (inside + 1)
                let expected = concat [[i * 10 | kind == 0] ++ [i * 10 + 1] | (i, kind) <- zip [1 ..] steps]
                withConnection ci $ \observer -> query observer (rawSql ("SELECT v FROM " <> table <> " ORDER BY v")) `shouldReturn` map Only (expected :: [Int32])
scenarios :: [(String, [Int32], Connection -> Text -> IO ())]
scenarios =
    [ ("normal commit", [20], \c t -> withTransaction c (write c t 20))
    , ("application exception", [], \c t -> (withTransaction c $ write c t 20 >> boom) `shouldThrow` anyIOException)
    , ("explicit rollback inside wrapper", [], \c t -> (withTransaction c $ write c t 20 >> rollback c) `shouldThrow` endedEarly)
    , ("server conversion error", [], \c t -> (withTransaction c $ write c t 20 >> badConversion c) `shouldThrow` sqlError)
    ,
        ( "caught conversion rollback makes the following write autocommit"
        , [21]
        , \c t ->
            ( withTransaction c $ do
                exec c "SET XACT_ABORT OFF"
                write c t 20
                badConversion c `shouldThrow` sqlError
                inTransaction c `shouldReturn` False
                write c t 21
            )
                `shouldThrow` endedEarly
        )
    ,
        ( "caught constraint error with XACT_ABORT OFF"
        , [20, 21]
        , \c t ->
            withTransaction c $ do
                exec c "SET XACT_ABORT OFF"
                write c t 20
                write c t 20 `shouldThrow` sqlError
                inTransaction c `shouldReturn` True
                write c t 21
        )
    ,
        ( "bulk then ordinary writes"
        , [20, 21]
        , \c t -> withTransaction c $ do
            bulkInsert c t [Only (20 :: Int32)] `shouldReturn` 1
            write c t 21
        )
    ,
        ( "ordinary then bulk writes"
        , [20, 21]
        , \c t -> withTransaction c $ do
            write c t 20
            bulkInsert c t [Only (21 :: Int32)] `shouldReturn` 1
        )
    ,
        ( "bulk failure rolls back earlier ordinary write"
        , []
        , \c t ->
            ( withTransaction c $ do
                write c t 20
                void $ bulkInsert c t [Only (20 :: Int32)]
            )
                `shouldThrow` sqlError
        )
    ,
        ( "BatchQuery writes inside transaction"
        , [20, 21]
        , \c t -> withTransaction c $ do
            runBatchQuery c (traverse (\n -> batchExecute (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only n))) [20, 21 :: Int32]) `shouldReturn` [1, 1]
        )
    ,
        ( "finite stream inside transaction"
        , [20]
        , \c t -> withTransaction c $ do
            write c t 20
            stream <- queryS c (rawSql ("SELECT v FROM " <> t <> " ORDER BY v"))
            S.toList_ stream `shouldReturn` map Only [10, 20 :: Int32]
        )
    ,
        ( "decode failure inside transaction"
        , []
        , \c t ->
            ( withTransaction c $ do
                void (query c (rawSql ("INSERT INTO " <> t <> " OUTPUT inserted.v VALUES (20)")) :: IO [Only Day])
            )
                `shouldThrow` decodeError
        )
    ,
        ( "autocommit DML survives client decode failure"
        , [20]
        , \c t ->
            void (query c (rawSql ("INSERT INTO " <> t <> " OUTPUT inserted.v VALUES (20)")) :: IO [Only Day]) `shouldThrow` decodeError
        )
    ,
        ( "savepoint rollback"
        , [20, 22]
        , \c t -> withTransaction c $ do
            write c t 20
            exec c "SAVE TRANSACTION hardening_save"
            write c t 21
            exec c "ROLLBACK TRANSACTION hardening_save"
            write c t 22
        )
    ,
        ( "nested wrapper refusal preserves outer writes"
        , [20, 21]
        , \c t -> withTransaction c $ do
            write c t 20
            withTransaction c (write c t 99) `shouldThrow` alreadyActive
            write c t 21
        )
    ,
        ( "lazy reset rolls back before next request"
        , []
        , \c t -> do
            begin c
            write c t 20
            reset c
            query1 c "SELECT 1" `shouldReturn` Only (1 :: Int32)
        )
    , ("manual commit after TM begin", [20], \c t -> begin c >> write c t 20 >> exec c "COMMIT TRANSACTION")
    ]

fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "hardening" $ \schema -> withConnection ci $ \conn -> action ci conn (schema <> ".target")

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql

write :: Connection -> Text -> Int32 -> IO ()
write conn table value = void $ execute conn (mkQuery ("INSERT INTO " <> table <> " VALUES (@p1)") (Only value))

boom :: IO ()
boom = throwIO (userError "hardening rollback")

badConversion :: Connection -> IO ()
badConversion conn = void (query1 conn (mkQuery "SELECT CONVERT(int,@p1)" (Only ("not-an-integer" :: Text))) :: IO (Only Int32))

sqlError :: SqlServerError -> Bool
sqlError _ = True

decodeError :: DecodeError -> Bool
decodeError _ = True

endedEarly :: TransactionError -> Bool
endedEarly TransactionEndedEarly = True
endedEarly _ = False

alreadyActive :: TransactionError -> Bool
alreadyActive TransactionAlreadyActive = True
alreadyActive _ = False
