-- Zero payload length is SQL NULL for BYTE-length and variant fields.
-- A caller's non-NULL empty RawParam must not become NULL or a default.
module Bulk.EmptySourceSpec (spec) where

import RecipeParameters
import Control.Exception (try)
import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int32, Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError)
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Types
import TestDb

spec :: Spec
spec = pureSpec >> liveSpec

liveSpec :: Spec
liveSpec = around withTestDb $ do
    forM_ [False, True] $ \keepNulls ->
        forM_ invalidEmpty $ \(label, decl, defaultSql, valueSql, override) ->
            it ("refuses a non-NULL empty source instead of substituting data, " ++ label ++ ", KEEP_NULLS=" ++ show keepNulls) $ \conn -> do
                void $ execute conn (rawSql ("CREATE TABLE #empty_target(id int PRIMARY KEY,v " <> decl <> " NULL DEFAULT (" <> defaultSql <> ")); CREATE TABLE #empty_source(v " <> decl <> "); INSERT INTO #empty_source VALUES(" <> valueSql <> ")"))
                [column] <- describeBulkColumns conn (bulkCopy "#empty_source")
                let source = fromMaybe (bulkColumnType column) override
                    empty = RawParam (source, Just B.empty)
                    options = (bulkCopy "#empty_target"){bulkKeepNulls = keepNulls}
                execute conn (mkQuery "INSERT INTO #empty_target VALUES(@p1,@p2)" (1 :: Int32, empty)) `shouldThrow` (\(_ :: EncodeError) -> True)
                query1 conn "SELECT COUNT(*) FROM #empty_target" `shouldReturn` Only (0 :: Int32)
                result <- try (bulkInsertWith options conn [(1 :: Int32, empty)]) :: IO (Either EncodeError Int64)
                case result of
                    Left _ -> pure ()
                    Right _ -> do
                        stored <- query conn "SELECT id,CONVERT(nvarchar(80),v) FROM #empty_target" :: IO [(Int32, Maybe Text)]
                        expectationFailure ("non-NULL empty " ++ label ++ " stored as " ++ show stored)
                query1 conn "SELECT COUNT(*) FROM #empty_target" `shouldReturn` Only (0 :: Int32)
                Only (RawValue bytes) <- query1 conn "SELECT v FROM #empty_source"
                Only expected <- query1 conn "SELECT CONVERT(nvarchar(80),v) FROM #empty_source" :: IO (Only Text)
                Only defaultValue <- query1 conn (rawSql ("SELECT CONVERT(nvarchar(80),CONVERT(" <> decl <> "," <> defaultSql <> "))")) :: IO (Only Text)
                bulkInsertWith options conn [(2 :: Int32, RawParam (source, Just bytes)), (3, RawParam (source, Nothing))] `shouldReturn` 2
                query conn "SELECT id,CONVERT(nvarchar(80),v) FROM #empty_target ORDER BY id" `shouldReturn` [(2 :: Int32, Just expected), (3, if keepNulls then Nothing else Just defaultValue)]
    forM_ legalEmpty $ \(decl, defaultSql) ->
        it ("retains a valid non-NULL empty " ++ T.unpack decl ++ " payload") $ \conn -> do
            void $ execute conn (rawSql ("CREATE TABLE #legal_empty(v " <> decl <> " NULL DEFAULT (" <> defaultSql <> "))"))
            [column] <- describeBulkColumns conn (bulkCopy "#legal_empty")
            bulkInsert conn "#legal_empty" [Only (RawParam (bulkColumnType column, Just B.empty))] `shouldReturn` 1
            query1 conn "SELECT CONVERT(bit,CASE WHEN v IS NULL THEN 1 ELSE 0 END),CONVERT(int,DATALENGTH(CONVERT(nvarchar(max),v))) FROM #legal_empty" `shouldReturn` (False, 0 :: Int32)

pureSpec :: Spec
pureSpec = describe "empty source framing (pure)" $ do
    forM_ [("nullable int", TIIntN 4, TIIntN 4), ("fixed int", TIIntN 4, TIInt4), ("datetime2", TIDateTime2N 3, TIDateTime2N 3), ("variant", TISqlVariant 8016, TISqlVariant 8016)] $ \(label, target, source) ->
        it ("refuses a non-NULL empty " ++ label ++ " frame") $
            encodeBulkCellBytes defaultTdsContext (BulkColumn "v" target True False) (source, Just B.empty) `shouldSatisfy` isLeft
    it "retains logical NULL conversion from a fixed source to a nullable target" $
        encodeBulkCellBytes defaultTdsContext (BulkColumn "v" (TIIntN 4) True False) (TIInt4, Nothing) `shouldBe` Right Nothing

invalidEmpty :: [(String, Text, Text, Text, Maybe TypeInfo)]
invalidEmpty =
    [ ("nullable int", "int", "7", "13", Nothing)
    , ("fixed int", "int", "7", "13", Just TIInt4)
    , ("datetime2", "datetime2(3)", "'2000-01-01T00:00:00'", "'2001-02-03T04:05:06.007'", Nothing)
    , ("variant", "sql_variant", "CONVERT(sql_variant,7)", "CONVERT(sql_variant,CONVERT(smallint,13))", Nothing)
    ]
legalEmpty :: [(Text, Text)]
legalEmpty = [("nvarchar(12)", "N'default'"), ("varchar(12)", "'default'"), ("varbinary(12)", "0xAB"), ("xml", "CONVERT(xml,N'<default/>')"), ("ntext", "N'default'")]
