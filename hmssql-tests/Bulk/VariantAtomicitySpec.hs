-- Native variant metadata affects constraints and trigger-derived data too.
-- Retain the existing client payload checks before wrapping that metadata.
module Bulk.VariantAtomicitySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError, sqlErrorNumber)
import Hmssql.Transaction (inTransaction)
import Hmssql.Types
import TestDb

type Stored = (Int32, Text, Text, Int32, Int32)
spec :: Spec
spec = forM_ [False, True] $ \clientFailure ->
    forM_ [False, True] $ \wrapped ->
        it ("retains variant typing, payload validation and batch effects, client failure=" ++ show clientFailure ++ ", wrapper=" ++ show wrapped) $ fixture $ \ci conn target audit -> do
            let bad = if clientFailure then RawParam (TIDecimalN 38 2, Just (B.pack [2, 125, 0, 0, 0])) else RawParam (TIMoneyN 4, Just (B.pack [0x30, 0x75, 0, 0]))
                rows = [(1 :: Int32, decimal 125), (2, decimal 250), (3, bad), (4, decimal 400)]
                load = void $ bulkInsertWith (bulkCopy target){bulkBatchSize = Just 2, bulkCheckConstraints = True, bulkFireTriggers = True} conn rows
                action = if wrapped then withTransaction conn load else load
            if clientFailure then action `shouldThrow` (\(_ :: EncodeError) -> True) else action `shouldThrow` (\e -> sqlErrorNumber e == 547)
            inTransaction conn `shouldReturn` False
            query1 conn "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
            void $ execute conn (mkQuery ("INSERT INTO " <> target <> " VALUES(@p1,@p2)") (10 :: Int32, decimal 1000))
            withTransaction conn (void (execute conn (mkQuery ("INSERT INTO " <> target <> " VALUES(@p1,@p2)") (20 :: Int32, decimal 2000))) >> throwIO (userError "independent variant rollback")) `shouldThrow` anyIOException
            let earlier = if wrapped then [] else [stored 1 "1.25", stored 2 "2.50"]
            withConnection ci $ \observer -> do
                query observer (rawSql ("SELECT id,CONVERT(nvarchar(40),v),CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'BaseType')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Precision')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Scale')) FROM " <> target <> " ORDER BY id")) `shouldReturn` (stored 0 "0.50" : earlier ++ [stored 10 "10.00"])
                query observer (rawSql ("SELECT id,rendered,base,prec,scale FROM " <> audit <> " ORDER BY id")) `shouldReturn` (earlier ++ [stored 10 "10.00"])

stored :: Int32 -> Text -> Stored
stored i value = (i, value, "decimal", 38, 2)
decimal :: Int32 -> RawParam
decimal coefficient = RawParam (TIDecimalN 38 2, Just (B.pack [1, fromIntegral coefficient, fromIntegral (coefficient `div` 256), 0, 0]))
fixture :: (ConnectInfo -> Connection -> Text -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "variant_atomicity" $ \schema -> withConnection ci $ \conn -> do
        let target = schema <> ".target"
            audit = schema <> ".audit"
        exec conn ("CREATE TABLE " <> target <> "(id int PRIMARY KEY,v sql_variant NOT NULL CHECK(CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'BaseType'))=N'decimal' AND CONVERT(int,SQL_VARIANT_PROPERTY(v,'Precision'))=38 AND CONVERT(int,SQL_VARIANT_PROPERTY(v,'Scale'))=2)); CREATE TABLE " <> audit <> "(id int,rendered nvarchar(40),base nvarchar(128),prec int,scale int); INSERT INTO " <> target <> " VALUES(0,CONVERT(decimal(38,2),0.50))")
        exec conn ("CREATE TRIGGER " <> schema <> ".capture ON " <> target <> " AFTER INSERT AS INSERT INTO " <> audit <> " SELECT id,CONVERT(nvarchar(40),v),CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'BaseType')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Precision')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Scale')) FROM inserted")
        action ci conn target audit
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
