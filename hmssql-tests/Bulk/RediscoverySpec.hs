-- Column discovery after the table changed: ordinals, names, lengths,
-- scales and code pages come from the table as it is at the load.
module Bulk.RediscoverySpec (spec) where

import Control.Monad (void)
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError)
import TestDb

spec :: Spec
spec = do
    describe "rediscovered bulk metadata" $ do
        it "uses new ordinals after dropping and re-adding a column beside generated columns" $ fixture $ \_ conn table -> do
            exec conn ("CREATE TABLE " <> table <> " (id int IDENTITY,a int,b int,c int,derived AS a+c,omitted int NOT NULL DEFAULT 701)")
            let row i = NamedParams [("c", SqlParam (i + 2)), ("b", SqlParam (i + 1)), ("a", SqlParam i)]
            bulkInsertWith (bulkCopy table){bulkColumns = NamedColumns ["a", "b", "c"]} conn [row (101 :: Int32)] `shouldReturn` 1
            exec conn ("ALTER TABLE " <> table <> " DROP COLUMN b; ALTER TABLE " <> table <> " ADD b int")
            bulkInsertWith (bulkCopy table){bulkColumns = NamedColumns ["c", "b", "a"]} conn [row (201 :: Int32)] `shouldReturn` 1
            query conn (rawSql ("SELECT a,b,c,derived,omitted FROM " <> table <> " ORDER BY id"))
                `shouldReturn` [(101 :: Int32, Nothing :: Maybe Int32, 103 :: Int32, 204 :: Int32, 701 :: Int32), (201, Just 202, 203, 404, 701)]
        it "uses a renamed column's current name in reordered named rows" $ fixture $ \_ conn table -> do
            exec conn ("CREATE TABLE " <> table <> " (a int,b int)")
            bulkInsert conn table [NamedParams [("b", SqlParam (102 :: Int32)), ("a", SqlParam (101 :: Int32))]] `shouldReturn` 1
            void $ execute conn (mkQuery "EXEC sp_rename @p1,@p2,N'COLUMN'" (table <> ".a", "renamed" :: Text))
            bulkInsert conn table [NamedParams [("b", SqlParam (202 :: Int32)), ("renamed", SqlParam (201 :: Int32))]] `shouldReturn` 1
            query conn (rawSql ("SELECT renamed,b FROM " <> table <> " ORDER BY renamed")) `shouldReturn` [(101 :: Int32, 102 :: Int32), (201, 202)]
        skipBeforeSql2019 "UTF-8 collations" $
            it "rediscovers byte lengths and code pages after varchar collation changes" $
                fixture $ \_ conn table -> do
                    exec conn ("CREATE TABLE " <> table <> " (id int,v varchar(4) COLLATE Latin1_General_100_CI_AS)")
                    bulkInsert conn table [(1 :: Int32, "é  " :: Text)] `shouldReturn` 1
                    exec conn ("ALTER TABLE " <> table <> " ALTER COLUMN v varchar(4) COLLATE Latin1_General_100_CI_AS_SC_UTF8")
                    bulkInsert conn table [(2 :: Int32, "😀" :: Text)] `shouldReturn` 1
                    bulkInsert conn table [(3 :: Int32, "😀x" :: Text)] `shouldThrow` (\(_ :: EncodeError) -> True)
                    query conn (rawSql ("SELECT id,v,DATALENGTH(v) FROM " <> table <> " ORDER BY id")) `shouldReturn` [(1 :: Int32, "é  " :: Text, 4 :: Int32), (2, "😀", 4)]
                    exec conn ("TRUNCATE TABLE " <> table <> "; ALTER TABLE " <> table <> " ALTER COLUMN v varchar(4) COLLATE Latin1_General_100_CI_AS")
                    bulkInsert conn table [(4 :: Int32, "😀" :: Text)] `shouldThrow` (\(_ :: EncodeError) -> True)
                    query conn (rawSql ("SELECT id,v FROM " <> table)) `shouldReturn` ([] :: [(Int32, Text)])
        it "refreshes length, scale and collation validation after ALTER COLUMN" $ fixture $ \_ conn table -> do
            exec conn ("CREATE TABLE " <> table <> " (id int,v nvarchar(2),n decimal(5,2))")
            bulkInsert conn table [(1 :: Int32, "😀" :: Text, 1.25 :: Double)] `shouldReturn` 1
            exec conn ("ALTER TABLE " <> table <> " ALTER COLUMN v nvarchar(6) COLLATE Latin1_General_100_BIN2; ALTER TABLE " <> table <> " ALTER COLUMN n decimal(8,4)")
            bulkInsert conn table [(2 :: Int32, "😀x  " :: Text, 1.125 :: Double)] `shouldReturn` 1
            query conn (rawSql ("SELECT id,v,DATALENGTH(v),CONVERT(varchar(20),n) FROM " <> table <> " ORDER BY id"))
                `shouldReturn` [(1 :: Int32, "😀" :: Text, 4 :: Int32, "1.2500" :: Text), (2, "😀x  ", 10, "1.1250")]

fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "bulk_rediscovery" $ \schema -> withConnection ci $ \conn -> action ci conn (schema <> ".target")

exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
