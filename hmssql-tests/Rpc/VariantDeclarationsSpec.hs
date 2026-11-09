-- Each RPC in a batch owns its parameter declaration, even when NamedParams
-- reorder fields and native source types/lengths vary under the same SQL.
module Rpc.VariantDeclarationsSpec (spec) where

import Control.Monad (forM, forM_, void)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import Hmssql.BulkCopy (BulkColumn, bulkColumnType, bulkCopy, describeBulkColumns)
import Hmssql.SqlValue (SqlValue)
import Hmssql.Types
import TestDb

type Snapshot = (Int32, SqlValue, Maybe Text, Maybe Int32, Maybe Int32, Maybe Int32, Maybe RawValue)
spec :: Spec
spec = around withTestDb $ forM_ ["executeMany", "executeStatements", "BatchQuery"] $ \path ->
    it ("retains each reordered row's native declaration through " ++ path) $ \conn -> do
        void $ execute conn "CREATE TABLE #rpc_expected(id int,v sql_variant); CREATE TABLE #rpc_actual(id int,v sql_variant)"
        rows <- forM (zip [1 ..] sources) $ \(i, (decl, literal)) -> do
            void $ execute conn (rawSql ("CREATE TABLE #rpc_source(v " <> decl <> "); INSERT INTO #rpc_source VALUES(" <> literal <> ")"))
            void $ execute conn (mkQuery "INSERT #rpc_expected SELECT @p1,CONVERT(sql_variant,v) FROM #rpc_source" (Only (i :: Int32)))
            [column] <- sourceColumns conn
            Only (RawValue bytes) <- query1 conn "SELECT v FROM #rpc_source"
            void $ execute conn "DROP TABLE #rpc_source"
            pure $ named i (RawParam (bulkType column, Just bytes))
        let nil = fromIntegral (length rows) + 1 :: Int32
            allRows = rows ++ [named nil (RawParam (TISqlVariant 8016, Nothing))]
            sql = "INSERT #rpc_actual VALUES(@id,@value)"
            queries = map (mkQuery sql) allRows
        void $ execute conn (mkQuery "INSERT #rpc_expected VALUES(@p1,NULL)" (Only nil))
        counts <- case path of
            "executeMany" -> executeMany conn sql allRows
            "executeStatements" -> executeStatements conn queries
            _ -> runBatchQuery conn (traverse batchExecute queries)
        counts `shouldBe` replicate (length allRows) (1 :: Int64)
        expected <- query conn (snapshot "#rpc_expected") :: IO [Snapshot]
        actual <- query conn (snapshot "#rpc_actual")
        query1 conn "SELECT CONVERT(varbinary(max),0xDEADBEEF)" `shouldReturn` Only (RawValue "\xDE\xAD\xBE\xEF")
        actual `shouldBe` expected
  where
    named i value = NamedParams (if even i then reverse fields else fields)
      where
        fields = [("id", SqlParam i), ("value", SqlParam value)]

-- The existing bulk metadata reader also exposes the source's native TypeInfo.
-- Capture server bytes so no client encoder can cancel the batched writer's bug.
sourceColumns :: Connection -> IO [BulkColumn]
sourceColumns conn = describeBulkColumns conn (bulkCopy "#rpc_source")
bulkType :: BulkColumn -> TypeInfo
bulkType = bulkColumnType
snapshot :: Text -> Query
snapshot table = rawSql ("SELECT id,v,CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'BaseType')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Precision')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Scale')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'MaxLength')),v FROM " <> table <> " ORDER BY id")
sources :: [(Text, Text)]
sources =
    [ ("int", "16909060")
    , ("nvarchar(4000)", "REPLICATE(N'x',3994)+N'😀é  '")
    , ("decimal(38,2)", "1.25")
    , ("smallmoney", "-12.3456")
    , ("smalldatetime", "'2000-01-02T03:04:00'")
    , ("varbinary(8000)", "CONVERT(varbinary(8000),REPLICATE('X',7998))+0x0000")
    , ("datetime", "'2000-01-02T03:04:05.007'")
    , ("time(2)", "'03:04:05.12'")
    , ("nvarchar(12)", "N''")
    , ("uniqueidentifier", "'00112233-4455-6677-8899-aabbccddeeff'")
    , ("datetimeoffset(4)", "'2000-01-02T03:04:05.1234+05:45'")
    , ("bigint", "-9223372036854775808")
    , ("binary(12)", "0x0100FF00")
    , ("numeric(30,7)", "-12.3456789")
    , ("int", "-16909060")
    ]
