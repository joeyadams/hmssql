-- A source declares more than its decoded SqlValue family. Variant base
-- type, precision, scale, length and collation are observable stored data.
module Bulk.VariantSourceSpec (spec) where

import RecipeParameters
import Control.Monad (forM, forM_, void)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.SqlValue (SqlValue)
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.TypeInfo (maxLength)
import Hmssql.Types
import TestDb

type Snapshot = (Int32, SqlValue, Maybe Text, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Text, Maybe RawValue)

spec :: Spec
spec = do
    describe "native variant source headers (pure)" $
        forM_ pureCases $ \(label, source, input, expected) ->
            it label $ encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TISqlVariant 8016) True False) (source, Just input) `shouldBe` Right (Just expected)
    describe "native variant payload checks (pure)" $
        forM_ [("invalid decimal sign", TIDecimalN 38 2, B.pack [2, 125, 0, 0, 0]), ("decimal magnitude beyond source precision", TIDecimalN 1 0, B.pack [1, 10, 0, 0, 0]), ("datetime2 clock beyond a day", TIDateTime2N 3, B.pack [0, 0x5C, 0x26, 5, 0, 0, 0])] $ \(label, source, input) ->
            it ("retains the existing rejection for " ++ label) $
                encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TISqlVariant 8016) True False) (source, Just input) `shouldSatisfy` isLeft
    around withTestDb $ do
        forM_ sources $ \(decl, literal) ->
            gate decl $ it ("retains native variant source metadata for " ++ T.unpack decl ++ " from " ++ T.unpack literal) $ \conn -> do
                createTargets conn
                source <- capture conn 1 decl literal
                bulkInsert conn "#variant_actual" [(1 :: Int32, source)] `shouldReturn` 1
                compareTargets conn
        skipBeforeSql2019 "mixed UTF8 variant sources" $
            it "retains each row's raw declaration in one compiled column across batches" $ \conn -> do
                createTargets conn
                rows <- forM (zip [1 ..] sources) $ \(i, (decl, literal)) -> do
                    source <- capture conn i decl literal
                    pure (i, source)
                bulkInsertWith (bulkCopy "#variant_actual"){bulkBatchSize = Just 3} conn rows `shouldReturn` fromIntegral (length rows)
                compareTargets conn
        it "retains the fixed decimal precision of Integer parameters beyond bigint" $ \conn -> do
            createTargets conn
            let values = [10 ^ (20 :: Int) + 1, negate (10 ^ (30 :: Int) + 7)] :: [Integer]
            forM_ (zip [1 ..] values) $ \(i, value) -> void $ execute conn (mkQuery "INSERT INTO #variant_expected VALUES(@p1,@p2)" (i :: Int32, value))
            bulkInsert conn "#variant_actual" (zip [1 :: Int32 ..] values) `shouldReturn` 2
            compareTargets conn
        forM_ [("high", 0xD8, "NCHAR(0xD800)+N'x'"), ("low", 0xDC, "NCHAR(0xDC00)+N'x'")] $ \(label, unit, literal) ->
            it ("preserves accepted raw UTF-16 " ++ label ++ " surrogate payload separately from metadata") $ \conn -> do
                createTargets conn
                source <- capture conn 1 "nvarchar(12)" literal
                bulkInsert conn "#variant_actual" [(1 :: Int32, source)] `shouldReturn` 1
                forM_ ["#variant_expected", "#variant_actual"] $ \table ->
                    query1 conn (rawSql ("SELECT CONVERT(varbinary(max),CONVERT(nvarchar(max),v)) FROM " <> table)) `shouldReturn` Only (B.pack [0, unit, 0x78, 0])
        forM_ ["nvarchar(max)", "ntext"] $ \decl ->
            forM_ [("high", 0xD8, "NCHAR(0xD800)+N'x'"), ("low", 0xDC, "NCHAR(0xDC00)+N'x'")] $ \(label, unit, literal) ->
                it ("preserves raw LOB Unicode " ++ label ++ " surrogate through the existing bounded variant conversion, " ++ T.unpack decl) $ \conn -> do
                    createTargets conn
                    void $ execute conn (rawSql ("CREATE TABLE #variant_lob(v " <> decl <> "); INSERT INTO #variant_lob VALUES(" <> literal <> "); INSERT INTO #variant_expected SELECT 1,CONVERT(sql_variant,CONVERT(nvarchar(4000),v)) FROM #variant_lob"))
                    [column] <- describeBulkColumns conn (bulkCopy "#variant_lob")
                    Only (RawValue bytes) <- query1 conn "SELECT v FROM #variant_lob"
                    bulkInsert conn "#variant_actual" [(1 :: Int32, RawParam (bulkColumnType column, Just bytes))] `shouldReturn` 1
                    forM_ ["#variant_expected", "#variant_actual"] $ \table ->
                        query1 conn (rawSql ("SELECT CONVERT(varbinary(max),CONVERT(nvarchar(max),v)) FROM " <> table)) `shouldReturn` Only (B.pack [0, unit, 0x78, 0])
                    compareTargets conn
        forM_ ["nvarchar(max)", "ntext"] $ \decl ->
            it ("retains existing LOB Unicode conversion for pairs, empty, NUL and NULL, " ++ T.unpack decl) $ \conn -> do
                createTargets conn
                void $ execute conn (rawSql ("CREATE TABLE #variant_lob(id int,v " <> decl <> "); INSERT INTO #variant_lob VALUES(1,N'😀é  '),(2,N''),(3,NCHAR(0)+N'x'),(4,NULL); INSERT INTO #variant_expected SELECT id,CONVERT(sql_variant,CONVERT(nvarchar(4000),v)) FROM #variant_lob"))
                [column] <- describeBulkColumns conn (bulkCopy "#variant_lob"){bulkColumns = NamedColumns ["v"]}
                values <- query conn "SELECT id,v FROM #variant_lob ORDER BY id" :: IO [(Int32, Maybe RawValue)]
                let rows = [(i, RawParam (bulkColumnType column, fmap (\(RawValue b) -> b) value)) | (i, value) <- values]
                bulkInsert conn "#variant_actual" rows `shouldReturn` 4
                compareTargets conn
        it "keeps explicit NULL separate from zero, empty text and empty binary variants" $ \conn -> do
            createTargets conn
            let rows = [(1 :: Int32, RawParam (TIDecimalN 38 2, Nothing)), (2, RawParam (TIDecimalN 38 2, Just (B.pack [1, 0, 0, 0, 0]))), (3, RawParam (TINVarChar 24 (Collation 0 0), Just B.empty)), (4, RawParam (TIBigVarBinary 12, Just B.empty))]
            bulkInsert conn "#variant_actual" rows `shouldReturn` 4
            query conn "SELECT id,CONVERT(bit,CASE WHEN v IS NULL THEN 1 ELSE 0 END) FROM #variant_actual ORDER BY id" `shouldReturn` [(1 :: Int32, True), (2, False), (3, False), (4, False)]

createTargets :: Connection -> IO ()
createTargets conn = void $ execute conn "CREATE TABLE #variant_expected(id int,v sql_variant); CREATE TABLE #variant_actual(id int,v sql_variant)"
capture :: Connection -> Int32 -> Text -> Text -> IO RawParam
capture conn i decl literal = do
    void $ execute conn (rawSql ("CREATE TABLE #variant_source(v " <> decl <> "); INSERT INTO #variant_source VALUES(" <> literal <> ")"))
    void $ execute conn (mkQuery "INSERT INTO #variant_expected SELECT @p1,CONVERT(sql_variant,v) FROM #variant_source" (Only i))
    [column] <- describeBulkColumns conn (bulkCopy "#variant_source")
    Only (RawValue bytes) <- query1 conn "SELECT v FROM #variant_source"
    void $ execute conn "DROP TABLE #variant_source"
    pure (RawParam (bulkColumnType column, Just bytes))
compareTargets :: Connection -> IO ()
compareTargets conn = do
    expected <- query conn (snapshot "#variant_expected") :: IO [Snapshot]
    actual <- query conn (snapshot "#variant_actual")
    query1 conn "SELECT CONVERT(varbinary(max),0xDEADBEEF)" `shouldReturn` Only (B.pack [0xDE, 0xAD, 0xBE, 0xEF])
    actual `shouldBe` expected
snapshot :: Text -> Query
snapshot table = rawSql ("SELECT id,v,CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'BaseType')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Precision')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'Scale')),CONVERT(int,SQL_VARIANT_PROPERTY(v,'MaxLength')),CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'Collation')),v FROM " <> table <> " ORDER BY id")
gate :: Text -> SpecWith a -> SpecWith a
gate decl = if "_UTF8" `T.isInfixOf` decl then skipBeforeSql2019 "UTF8 variant source metadata" else id
sources :: [(Text, Text)]
sources =
    [ ("decimal(38,2)", "1.25")
    , ("numeric(30,7)", "-12.3456789")
    , ("smallmoney", "-12.3456")
    , ("datetime", "'2000-01-02T03:04:05.007'")
    , ("smalldatetime", "'2000-01-02T03:04:00'")
    , ("datetime2(3)", "'2000-01-02T03:04:05.123'")
    , ("time(2)", "'03:04:05.12'")
    , ("datetimeoffset(4)", "'2000-01-02T03:04:05.1234+05:45'")
    , ("char(12)", "'x  '")
    , ("varchar(12)", "'x  '")
    , ("nchar(12)", "N'😀é  '")
    , ("nvarchar(12)", "N'😀é  '")
    , ("binary(12)", "0x0100FF00")
    , ("varbinary(12)", "0x0100FF00")
    , ("nvarchar(12)", "NCHAR(0xD800)+N'x'")
    , ("nvarchar(12)", "NCHAR(0xDC00)+N'x'")
    , ("varchar(12) COLLATE Greek_CI_AS", "N'Ω  '")
    , ("nvarchar(12) COLLATE Greek_CI_AS", "N'😀é  '")
    , ("varchar(12) COLLATE Latin1_General_100_CI_AS_SC_UTF8", "N'😀é  '")
    , ("char(8000)", "REPLICATE('x',8000)")
    , ("nchar(4000)", "REPLICATE(N'😀',2000)")
    , ("varbinary(8000)", "CONVERT(varbinary(8000),REPLICATE('X',8000))")
    ]
pureCases :: [(String, TypeInfo, B.ByteString, B.ByteString)]
pureCases =
    [ ("decimal declaration precision", TIDecimalN 38 2, B.pack [1, 125, 0, 0, 0], B.pack [0x6A, 2, 38, 2, 1, 125, 0, 0, 0])
    , ("numeric base type", TINumericN 30 7, B.pack [1, 1, 0, 0, 0], B.pack [0x6C, 2, 30, 7, 1, 1, 0, 0, 0])
    , ("smallmoney base type", TIMoneyN 4, B.pack [0x10, 0x27, 0, 0], B.pack [0x7A, 0, 0x10, 0x27, 0, 0])
    , ("datetime2 scale", TIDateTime2N 3, B.replicate 7 0, B.pack [0x2A, 1, 3] <> B.replicate 7 0)
    , ("fixed binary padding", TIBigBinary 4, B.singleton 1, B.pack [0xAD, 2, 4, 0, 1, 0, 0, 0])
    , ("LOB binary retains its existing bounded conversion", TIBigVarBinary maxLength, B.pack [1, 0, 255], B.pack [0xA5, 2, 0x40, 0x1F, 1, 0, 255])
    , ("explicit Unicode collation and length", TINVarChar 4 (Collation 0x00000408 0), B.pack [0xA9, 3], B.pack [0xE7, 7, 8, 4, 0, 0, 0, 4, 0, 0xA9, 3])
    ]
