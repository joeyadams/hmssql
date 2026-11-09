-- Defaults distinguish omitted columns, SQL NULL, empty payloads and fixed
-- source padding. Observe the values after defaults and trigger execution.
module Bulk.DefaultValueBoundarySpec (spec) where

import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError, SqlServerError, sqlErrorNumber)
import Hmssql.SqlValue (SqlValue (..))
import Hmssql.Types
import TestDb

type Stored = (Int32, Maybe Int32, Maybe Text, Maybe B.ByteString, Maybe Text, Int32)

spec :: Spec
spec = do
    forM_ [False, True] $ \keepNulls -> do
        it ("retains default/NULL/empty/padded distinctions in destination and trigger rows, KEEP_NULLS=" ++ show keepNulls) $ fixture $ \conn table -> do
            let rows =
                    [ named 1 (SqlParam (Nothing :: Maybe Int32)) (SqlParam (Nothing :: Maybe Text)) (SqlParam (Nothing :: Maybe B.ByteString)) (SqlParam (Nothing :: Maybe SqlValue))
                    , named 2 (SqlParam (0 :: Int32)) (SqlParam ("" :: Text)) (SqlParam B.empty) (SqlParam (SqlXml ""))
                    , named 3 (SqlParam (3 :: Int32)) (SqlParam ("sentinel  " :: Text)) (SqlParam (B.pack [0, 0])) (SqlParam (SqlXml "<r>é😀</r>"))
                    , named 4 (SqlParam (4 :: Int32)) (SqlParam (RawParam (TINChar 8 (Collation 0x409 0), Just B.empty))) (SqlParam (RawParam (TIBigBinary 4, Just B.empty))) (SqlParam (RawParam (TIXml Nothing, Just B.empty)))
                    ]
                options = (bulkCopy table){bulkColumns = NamedColumns ["id", "n", "s", "b", "x"], bulkBatchSize = Just 2, bulkKeepNulls = keepNulls, bulkFireTriggers = True}
                first = if keepNulls then (1, Nothing, Nothing, Nothing, Nothing, 99) else defaults 1
                expected = [first, (2, Just 0, Just "", Just B.empty, Just "", 99), (3, Just 3, Just "sentinel  ", Just (B.pack [0, 0]), Just "<r>é😀</r>", 99), (4, Just 4, Just "    ", Just (B.replicate 4 0), Just "", 99)] :: [Stored]
            bulkInsertWith options conn rows `shouldReturn` 4
            assertStored conn table expected
        it ("rejects inconsistent nullability while omitted NOT NULL defaults work, KEEP_NULLS=" ++ show keepNulls) $ fixture $ \conn table -> do
            let options = (bulkCopy table){bulkColumns = NamedColumns ["id", "required_value"], bulkKeepNulls = keepNulls, bulkFireTriggers = True}
                row = [(1 :: Int32, Nothing :: Maybe Int32)]
            bulkInsertWith options conn row `shouldThrow` (\(_ :: EncodeError) -> True)
            query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table)) `shouldReturn` Only (0 :: Int32)
            columns <- describeBulkColumns conn options
            let source = [if bulkColumnName c == "required_value" then c{bulkColumnNullable = True} else c | c <- columns]
                supplied = options{bulkColumns = DescribedColumns source}
            -- Nullability is target metadata rather than a convertible source
            -- type. The server rejects the inconsistent declaration before rows.
            bulkInsertWith supplied conn row `shouldThrow` (\(e :: SqlServerError) -> sqlErrorNumber e == 4816)
            bulkInsertWith (bulkCopy table){bulkColumns = NamedColumns ["id"], bulkKeepNulls = keepNulls, bulkFireTriggers = True} conn [Only (2 :: Int32)] `shouldReturn` 1
            assertStored conn table [defaults 2]

named :: Int32 -> SqlParam -> SqlParam -> SqlParam -> SqlParam -> NamedParams
named ident n s b x = NamedParams [("x", x), ("b", b), ("id", SqlParam ident), ("s", s), ("n", n)]
defaults :: Int32 -> Stored
defaults ident = (ident, Just 17, Just "default  ", Just (B.pack [0xAA, 0]), Just "<r>default</r>", 99)
assertStored :: Connection -> Text -> [Stored] -> IO ()
assertStored conn table expected = do
    destination <- query conn (rawSql ("SELECT id,n,s,b,CONVERT(nvarchar(max),x),required_value FROM " <> table <> " ORDER BY id"))
    audit <- query conn (rawSql ("SELECT id,n,s,b,x,required_value FROM " <> table <> "_audit ORDER BY id"))
    destination `shouldBe` expected
    audit `shouldBe` expected
fixture :: (Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "default_boundary" $ \schema -> withConnection ci $ \conn -> do
        let table = schema <> ".target"
        exec conn ("CREATE TABLE " <> table <> "(id int PRIMARY KEY,n int NULL DEFAULT 17,s nvarchar(16) NULL DEFAULT N'default  ',b varbinary(8) NULL DEFAULT 0xAA00,x xml NULL DEFAULT N'<r>default</r>',required_value int NOT NULL DEFAULT 99); CREATE TABLE " <> table <> "_audit(id int,n int,s nvarchar(16),b varbinary(8),x nvarchar(max),required_value int)")
        exec conn ("CREATE TRIGGER " <> table <> "_tr ON " <> table <> " AFTER INSERT AS BEGIN SET NOCOUNT ON; INSERT INTO " <> table <> "_audit SELECT id,n,s,b,CONVERT(nvarchar(max),x),required_value FROM inserted; END")
        action conn table
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
