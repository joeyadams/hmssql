-- Alternate payload types in one stored column so metadata cannot be inferred
-- from the first row. XML comparisons use the server's canonicalization.
module Types.StructuredAdversarialSpec (spec) where

import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Fixed (Fixed (..))
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import TestDb

spec :: Spec
spec = around withTestDb $ do
    describe "heterogeneous variants through one compiled bulk column" $
        forM_ [Nothing, Just 3] $ \batchSize ->
            it ("retains each row's payload and metadata, batch size=" ++ show batchSize) $ \conn -> do
                void $ execute conn "CREATE TABLE #variant_bulk(id int,v sql_variant); CREATE TABLE #variant_rpc(id int,v sql_variant)"
                forM_ (zip [1 ..] values) $ \(i, value) ->
                    void $ execute conn (if value == SqlNull then mkQuery "INSERT INTO #variant_rpc VALUES (@p1,NULL)" (Only (i :: Int32)) else mkQuery "INSERT INTO #variant_rpc VALUES (@p1,@p2)" (i :: Int32, value))
                bulkInsertWith (bulkCopy "#variant_bulk"){bulkBatchSize = batchSize} conn (zip [1 ..] values :: [(Int32, SqlValue)]) `shouldReturn` fromIntegral (length values)
                let selection table = rawSql ("SELECT id,v,CAST(SQL_VARIANT_PROPERTY(v,'BaseType') AS nvarchar(128)),CAST(SQL_VARIANT_PROPERTY(v,'Precision') AS int),CAST(SQL_VARIANT_PROPERTY(v,'Scale') AS int),CAST(SQL_VARIANT_PROPERTY(v,'MaxLength') AS int),DATALENGTH(v) FROM " <> table <> " ORDER BY id")
                ordinary <- query conn (selection "#variant_rpc") :: IO [(Int32, SqlValue, Maybe Text, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32)]
                bulk <- query conn (selection "#variant_bulk")
                bulk `shouldBe` ordinary
                map (\(_, v, _, _, _, _, _) -> v) ordinary `shouldBe` values
                streamed <- withQueryS conn "SELECT id,v FROM #variant_bulk ORDER BY id" S.toList_
                streamed `shouldBe` zip [1 :: Int32 ..] values
                -- Later values must not overwrite retained heterogeneous payloads.
                query1 conn "SELECT CAST(N'next' AS sql_variant)" `shouldReturn` Only (SqlText "next")
                map (\(_, v, _, _, _, _, _) -> v) bulk `shouldBe` values
    describe "typed XML through remapped bulk and output values" $
        forM_ xmlInputs $ \input ->
            it ("preserves server XML meaning for " ++ T.unpack input) $ \conn -> do
                ci <- defaultTestConnectInfo
                withScratchSchema ci "structured_xml" $ \schema -> do
                    void $ execute conn $ rawSql $ "CREATE XML SCHEMA COLLECTION " <> schema <> ".Doc AS N'<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"><xs:element name=\"r\" type=\"xs:string\"/></xs:schema>'"
                    let target = schema <> ".Documents"
                    void $ execute conn (rawSql ("CREATE TABLE " <> target <> "(id int,v xml(" <> schema <> ".Doc))"))
                    void $ execute conn (mkQuery ("INSERT INTO " <> target <> " VALUES (0,@p1)") (Only (SqlXml input)))
                    Only canonical <- query1 conn (rawSql ("SELECT v FROM " <> target <> " WHERE id=0")) :: IO (Only Text)
                    cols <- describeBulkColumns conn (bulkCopy target)
                    bulkInsertWith (bulkCopy target){bulkColumns = DescribedColumns cols} conn [(1 :: Int32, Just (SqlXml input)), (2, Nothing)] `shouldReturn` 2
                    query conn (rawSql ("SELECT id,v FROM " <> target <> " ORDER BY id")) `shouldReturn` [(0 :: Int32, Just canonical), (1, Just canonical), (2, Nothing)]
                    let stmt = inParam "" ("SELECT @out=v FROM " <> target <> " WHERE id=1" :: Text)
                    let declaration = inParam "" ("@out xml OUTPUT" :: Text)
                    let output = outParam "@out" (RawParam (TIXml Nothing, Nothing))
                    result <- callProcedure conn "sp_executesql" [stmt, declaration, output]
                    map (decodeReturnValue @Text) (procOutputValues result) `shouldBe` [Right canonical]
                    map (decodeReturnValue @SqlValue) (procOutputValues result) `shouldBe` [Right (SqlXml canonical)]

values :: [SqlValue]
values =
    [ SqlInt64 minBound
    , SqlText "😀é  "
    , SqlNull
    , SqlBinary (B.pack [0 .. 255] <> B.pack [0, 0])
    , SqlDecimal (read "-123456789012345678901234567890.12345678" :: Decimal)
    , SqlMoney (Money (MkFixed (-9223372036854775808)))
    , SqlText ""
    , SqlBinary B.empty
    , SqlDateTimeOffset (DateTimeOffset (UTCTime (fromGregorian 2000 1 1) 50400.0000001) (-840))
    , SqlNull
    , SqlDouble (-1.23456789e100)
    , SqlInt32 16909060
    , SqlText "last  "
    ]

xmlInputs :: [Text]
xmlInputs = ["<r>  😀é&#x20; </r>", "<r>&#128512;&amp;&#x1D11E;</r>", "<r/>"]
