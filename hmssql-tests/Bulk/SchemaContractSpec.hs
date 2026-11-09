-- Supplied descriptions declare source conversion types. They are not a
-- schema version token; callers choose when to discover destination metadata.
module Bulk.SchemaContractSpec (spec) where

import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError)
import Hmssql.Types (TypeInfo (..))
import TestDb

spec :: Spec
spec = around withTestDb $ do
    it "treats a supplied old decimal scale as an explicit source type after destination widening" $ \conn -> do
        exec conn "CREATE TABLE #scale_contract(id int,v decimal(5,2))"
        old <- describeBulkColumns conn (bulkCopy "#scale_contract")
        exec conn "ALTER TABLE #scale_contract ALTER COLUMN v decimal(8,4)"
        fresh <- describeBulkColumns conn (bulkCopy "#scale_contract")
        map bulkColumnType old `shouldBe` [TIIntN 4, TIDecimalN 5 2]
        map bulkColumnType fresh `shouldBe` [TIIntN 4, TIDecimalN 8 4]
        bulkInsertWith (bulkCopy "#scale_contract"){bulkColumns = DescribedColumns old} conn [(1 :: Int32, 1.2345 :: Decimal)] `shouldReturn` 1
        bulkInsertWith (bulkCopy "#scale_contract"){bulkColumns = DescribedColumns fresh} conn [(2 :: Int32, 1.2345 :: Decimal)] `shouldReturn` 1
        query conn "SELECT id,CONVERT(varchar(20),v) FROM #scale_contract ORDER BY id" `shouldReturn` [(1 :: Int32, "1.2300" :: Text), (2, "1.2345")]
    it "uses the caller's supplied length until fresh discovery is requested" $ \conn -> do
        exec conn "CREATE TABLE #length_contract(id int,v nvarchar(2))"
        old <- describeBulkColumns conn (bulkCopy "#length_contract")
        exec conn "ALTER TABLE #length_contract ALTER COLUMN v nvarchar(6)"
        bulkInsertWith (bulkCopy "#length_contract"){bulkColumns = DescribedColumns old} conn [(1 :: Int32, "😀x" :: Text)] `shouldThrow` (\(_ :: EncodeError) -> True)
        query conn "SELECT id,v FROM #length_contract" `shouldReturn` ([] :: [(Int32, Text)])
        bulkInsert conn "#length_contract" [(2 :: Int32, "😀x  " :: Text)] `shouldReturn` 1
        query1 conn "SELECT id,v,DATALENGTH(v) FROM #length_contract" `shouldReturn` (2 :: Int32, "😀x  " :: Text, 10 :: Int32)
    skipBeforeSql2019 "UTF8 schema changes" $
        it "keeps supplied code-page validation separate from fresh destination discovery" $ \conn -> do
            exec conn "CREATE TABLE #collation_contract(id int,v varchar(8) COLLATE Latin1_General_100_CI_AS)"
            old <- describeBulkColumns conn (bulkCopy "#collation_contract")
            exec conn "ALTER TABLE #collation_contract ALTER COLUMN v varchar(8) COLLATE Latin1_General_100_CI_AS_SC_UTF8"
            bulkInsertWith (bulkCopy "#collation_contract"){bulkColumns = DescribedColumns old} conn [(1 :: Int32, "😀" :: Text)] `shouldThrow` (\(_ :: EncodeError) -> True)
            bulkInsert conn "#collation_contract" [(2 :: Int32, "😀  " :: Text)] `shouldReturn` 1
            query1 conn "SELECT id,CONVERT(varbinary(max),v),DATALENGTH(v) FROM #collation_contract" `shouldReturn` (2 :: Int32, B.pack [0xF0, 0x9F, 0x98, 0x80, 0x20, 0x20], 6 :: Int32)
    it "matches native view binding before and after explicit refresh following base-column recreation" $ \conn -> do
        ci <- defaultTestConnectInfo
        withScratchSchema ci "bulk_view_binding" $ \schema -> do
            let base = schema <> ".base"
                view = schema <> ".projection"
                load phase = do
                    let a = 1000 + phase :: Int32
                        b = 2000 + phase :: Int32
                        bulkId = phase * 10 + 1
                        nativeId = phase * 10 + 2
                        row = NamedParams [("b", SqlParam b), ("id", SqlParam bulkId), ("a", SqlParam a)]
                    bulkInsert conn view [row] `shouldReturn` 1
                    void $ execute conn (mkQuery ("INSERT INTO " <> view <> "(id,a,b) VALUES(@p1,@p2,@p3)") (nativeId, a, b))
                    query conn (mkQuery ("SELECT a,b FROM " <> base <> " WHERE id IN(@p1,@p2) ORDER BY id") (bulkId, nativeId))
                        `shouldReturn` replicate 2 (if phase == 1 then (b, a) else (a, b))
            exec conn ("CREATE TABLE " <> base <> "(id int,a int,b int)")
            exec conn ("CREATE VIEW " <> view <> " AS SELECT * FROM " <> base)
            load 0
            exec conn ("ALTER TABLE " <> base <> " DROP COLUMN a; ALTER TABLE " <> base <> " ADD a int")
            map bulkColumnName <$> describeBulkColumns conn (bulkCopy view) `shouldReturn` ["id", "a", "b"]
            load 1
            void $ execute conn (mkQuery "EXEC sp_refreshview @p1" (Only view))
            map bulkColumnName <$> describeBulkColumns conn (bulkCopy view) `shouldReturn` ["id", "b", "a"]
            load 2
    it "maps current names and ordinals around identity, defaults and recreated computed columns" $ \conn -> do
        ci <- defaultTestConnectInfo
        withScratchSchema ci "bulk_contract" $ \s -> do
            let t = s <> ".evolving"
                rows a b = [NamedParams [("right_value", SqlParam b), ("left_value", SqlParam a), ("bytes", SqlParam (B.pack [0, 255, 0]))]]
            exec conn ("CREATE TABLE " <> t <> "(id int IDENTITY(1,1),left_value int,right_value int,bytes varbinary(8),derived AS (left_value*1000+right_value))")
            bulkInsert conn t (rows (101 :: Int32) (202 :: Int32)) `shouldReturn` 1
            exec conn ("ALTER TABLE " <> t <> " DROP COLUMN derived; ALTER TABLE " <> t <> " DROP COLUMN left_value; ALTER TABLE " <> t <> " ADD left_value int DEFAULT 909; ALTER TABLE " <> t <> " ADD derived AS (left_value*1000+right_value)")
            cols <- describeBulkColumns conn (bulkCopy t)
            map bulkColumnName cols `shouldBe` ["right_value", "bytes", "left_value"]
            bulkInsert conn t (rows (303 :: Int32) (404 :: Int32)) `shouldReturn` 1
            bulkInsertWith (bulkCopy t){bulkColumns = NamedColumns ["right_value", "bytes"]} conn [(505 :: Int32, B.empty)] `shouldReturn` 1
            query conn (rawSql ("SELECT id,left_value,right_value,bytes,derived FROM " <> t <> " ORDER BY id"))
                `shouldReturn` [(1 :: Int32, Nothing, 202 :: Int32, B.pack [0, 255, 0] :: ByteString, Nothing), (2, Just (303 :: Int32), 404, B.pack [0, 255, 0], Just (303404 :: Int32)), (3, Just 909, 505, B.empty, Just 909505)]

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
