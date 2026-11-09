-- Source declaration semantics, raw Unicode preservation, and complete byte
-- values matter as well as SQL equality, which can hide trailing-space loss.
module Bulk.TextBinaryBoundarySpec (spec) where

import RecipeParameters
import Control.Exception (finally)
import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding (RawParam (..))
import Hmssql.Errors (EncodeError, SqlServerError)
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Types (Collation (..), TypeInfo (..))
import TestDb

spec :: Spec
spec = pureSpec >> liveSpec

pureSpec :: Spec
pureSpec = describe "source padding and raw Unicode (pure)" $
    forM_ pureCases $ \(label, source, target, input, expected) ->
        it label $
            encodeBulkCellBytes defaultTdsContext (BulkColumn "v" target True False) (source, input) `shouldBe` Right expected

liveSpec :: Spec
liveSpec = around withTestDb $ do
    describe "fixed and variable source declarations" $
        forM_ declarationCases $ \(label, sourceDecl, target, payloads, expected) ->
            it (label ++ " retains source padding, empty and NULL distinctions") $ \conn -> do
                void $ execute conn (rawSql ("CREATE TABLE #source_decl(v " <> sourceDecl <> ")"))
                [sourceColumn] <- describeBulkColumns conn ((bulkCopy "#source_decl"){bulkColumns = NamedColumns ["v"]})
                (bulk, ordinary) <- createPair conn target
                described <- createTable conn target
                columns <- describeBulkColumns conn (bulkCopy described)
                let rows = [[SqlParam i, SqlParam (RawParam (bulkColumnType sourceColumn, value))] | (i, value) <- zip [1 ..] payloads :: [(Int32, Maybe B.ByteString)]]
                    expectedRows = [(i, value, fmap (fromIntegral . B.length) value) | (i, value) <- zip [1 ..] expected] :: [(Int32, Maybe B.ByteString, Maybe Int32)]
                loadBatch conn ordinary rows `shouldReturn` replicate (length rows) 1
                loadBulk conn bulk rows `shouldReturn` fromIntegral (length rows)
                bulkInsertWith (bulkCopy described){bulkColumns = DescribedColumns columns} conn rows `shouldReturn` fromIntegral (length rows)
                describedRows <- query conn (rawSql ("SELECT k,CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> described <> " ORDER BY k"))
                ordinaryRows <- query conn (rawSql ("SELECT k,CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> ordinary <> " ORDER BY k"))
                bulkRows <- query conn (rawSql ("SELECT k,CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> bulk <> " ORDER BY k"))
                -- Retain both decoded results over a subsequent read to detect a
                -- decoder whose small byte values still alias a reusable buffer.
                query1 conn "SELECT CONVERT(varbinary(max),0xDEADBEEF)" `shouldReturn` Only (B.pack [0xDE, 0xAD, 0xBE, 0xEF])
                ordinaryRows `shouldBe` expectedRows
                bulkRows `shouldBe` expectedRows
                describedRows `shouldBe` expectedRows
    describe "declared length units across metadata and session paths" $
        forM_ lengthCases $ \(label, family, collation, value, bytes, limit, unicode, fixed) ->
            (if "_UTF8" `T.isInfixOf` collation then skipBeforeSql2019 "UTF-8 collations" else id) $
                forM_ [limit - 1, limit, limit + 1] $ \width ->
                    forM_ [False, True] $ \described ->
                        forM_ [False, True] $ \warnings ->
                            it (label ++ ", width=" ++ show width ++ ", described=" ++ show described ++ ", ANSI_WARNINGS=" ++ show warnings) $ \conn -> withWarnings conn warnings $ do
                                let target = family <> "(" <> T.pack (show width) <> ")" <> collation
                                    fits = width >= limit
                                    capacityBytes = width * if unicode then 2 else 1
                                    nativeBytes = if width < limit then B.take capacityBytes bytes else if fixed then padTarget capacityBytes unicode bytes else bytes
                                (bulk, ordinary) <- createPair conn target
                                let rows = [[SqlParam (1 :: Int32), SqlParam value]]
                                options <-
                                    if described
                                        then do cols <- describeBulkColumns conn (bulkCopy bulk); pure (bulkCopy bulk){bulkColumns = DescribedColumns cols}
                                        else pure (bulkCopy bulk)
                                if not fits && warnings
                                    then
                                        loadBatch conn ordinary rows `shouldThrow` (\(_ :: SqlServerError) -> True)
                                    else do
                                        loadBatch conn ordinary rows `shouldReturn` [1]
                                        query1 conn (rawSql ("SELECT CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> ordinary)) `shouldReturn` (nativeBytes, fromIntegral (B.length nativeBytes) :: Int32)
                                if not fits
                                    then do
                                        bulkInsertWith options conn rows `shouldThrow` (\(_ :: EncodeError) -> True)
                                        query conn (rawSql ("SELECT k,CONVERT(varbinary(max),v) FROM " <> bulk)) `shouldReturn` ([] :: [(Int32, B.ByteString)])
                                    else do
                                        bulkInsertWith options conn rows `shouldReturn` 1
                                        query1 conn (rawSql ("SELECT CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> bulk)) `shouldReturn` (nativeBytes, fromIntegral (B.length nativeBytes) :: Int32)
    it "uses each row's fixed or variable source declaration independently" $ \conn -> do
        let rows =
                [ [SqlParam i, SqlParam (RawParam (ti, value))]
                | (i, ti, value) <-
                    [(1, TIBigBinary 4, Just (B.singleton 1)), (2, TIBigBinary 6, Just (B.singleton 1)), (3, TIBigVarBinary 6, Just (B.singleton 1)), (4, TIBigBinary 4, Nothing), (5, TIBigBinary 4, Just B.empty), (6, TIBigVarBinary 4, Just B.empty)] :: [(Int32, TypeInfo, Maybe B.ByteString)]
                ]
            expected = [(1 :: Int32, Just (B.pack [1, 0, 0, 0])), (2, Just (B.pack [1, 0, 0, 0, 0, 0])), (3, Just (B.singleton 1)), (4, Nothing), (5, Just (B.replicate 4 0)), (6, Just B.empty)]
        (bulk, ordinary) <- createPair conn "varbinary(20)"
        loadBatch conn ordinary rows `shouldReturn` replicate 6 1
        loadBulk conn bulk rows `shouldReturn` 6
        forM_ [bulk, ordinary] $ \table -> query conn (rawSql ("SELECT k,v FROM " <> table <> " ORDER BY k")) `shouldReturn` expected
    describe "maximum fixed source padding across value chunks"
        $ forM_
            [ ("binary(8000)", "varbinary(max)", B.pack [1, 0, 255], B.pack [1, 0, 255] <> B.replicate 7997 0)
            , ("char(8000)", "varchar(max)", B.singleton 0x78, B.singleton 0x78 <> B.replicate 7999 0x20)
            , ("nchar(4000)", "ntext", B.pack [0x78, 0, 0, 0xD8, 0x79, 0], B.pack [0x78, 0, 0, 0xD8, 0x79, 0] <> B.concat (replicate 3997 (B.pack [0x20, 0])))
            ]
        $ \(sourceDecl, target, payload, expected) ->
            it (T.unpack sourceDecl ++ " preserves complete padding and raw code units") $ \conn -> do
                void $ execute conn (rawSql ("CREATE TABLE #maximum_source(v " <> sourceDecl <> ")"))
                [column] <- describeBulkColumns conn (bulkCopy "#maximum_source")
                (bulk, ordinary) <- createPair conn target
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType column, Just payload))]]
                    expression = if target == "ntext" then "CONVERT(varbinary(max),CONVERT(nvarchar(max),v))" else "CONVERT(varbinary(max),v)"
                loadBatch conn ordinary rows `shouldReturn` [1]
                loadBulk conn bulk rows `shouldReturn` 1
                forM_ [bulk, ordinary] $ \table -> query1 conn (rawSql ("SELECT " <> expression <> ",DATALENGTH(v) FROM " <> table)) `shouldReturn` (expected, 8000 :: Int32)
    describe "raw UTF-16 values into ntext" $
        forM_ rawUnicode $ \(label, bytes) ->
            it ("preserves " ++ label ++ " through the Unicode bulk remap") $ \conn -> do
                void $ execute conn "CREATE TABLE #raw_source(v nvarchar(10))"
                [sourceColumn] <- describeBulkColumns conn ((bulkCopy "#raw_source"){bulkColumns = NamedColumns ["v"]})
                (bulk, ordinary) <- createPair conn "ntext"
                described <- createTable conn "ntext"
                columns <- describeBulkColumns conn (bulkCopy described)
                let value = RawParam (bulkColumnType sourceColumn, Just bytes)
                    rows = [[SqlParam (1 :: Int32), SqlParam value]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                loadBulk conn bulk rows `shouldReturn` 1
                bulkInsertWith (bulkCopy described){bulkColumns = DescribedColumns columns} conn rows `shouldReturn` 1
                forM_ [ordinary, bulk, described] $ \table -> do
                    query1 conn (rawSql ("SELECT CONVERT(varbinary(max),CONVERT(nvarchar(max),v)),DATALENGTH(v) FROM " <> table)) `shouldReturn` (bytes, fromIntegral (B.length bytes) :: Int32)
    skipBeforeSql2019 "UTF-8 collations"
        $ describe "raw UTF-16 conversion to a UTF-8 varchar"
        $ forM_
            [ ("lone high surrogate", B.pack [0x78, 0, 0, 0xD8, 0x79, 0], B.pack [0x78, 0xEF, 0xBF, 0xBD, 0x79])
            , ("lone low surrogate", B.pack [0x78, 0, 0, 0xDC, 0x79, 0], B.pack [0x78, 0xEF, 0xBF, 0xBD, 0x79])
            , ("valid supplementary pair", B.pack [0x78, 0, 0x3D, 0xD8, 0, 0xDE, 0x79, 0], B.pack [0x78, 0xF0, 0x9F, 0x98, 0x80, 0x79])
            ]
        $ \(label, bytes, expected) ->
            it ("matches the server's character conversion for " ++ label) $ \conn -> do
                void $ execute conn "CREATE TABLE #utf8_raw_source(v nvarchar(10))"
                [source] <- describeBulkColumns conn (bulkCopy "#utf8_raw_source")
                (bulk, ordinary) <- createPair conn "varchar(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8"
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType source, Just bytes))]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                loadBulk conn bulk rows `shouldReturn` 1
                -- SQL Server replaces unpaired units during this character
                -- conversion. UTF-16 storage itself retains the raw units.
                forM_ [ordinary, bulk] $ \table ->
                    query1 conn (rawSql ("SELECT CONVERT(varbinary(max),v),DATALENGTH(v) FROM " <> table)) `shouldReturn` (expected, fromIntegral (B.length expected) :: Int32)

declarationCases :: [(String, Text, Text, [Maybe B.ByteString], [Maybe B.ByteString])]
declarationCases =
    [ ("char(4) to varchar", "char(4)", "varchar(20)", ansi, map (fmap (padBytes 4 0x20)) ansi)
    , ("varchar(4) to varchar", "varchar(4)", "varchar(20)", ansi, ansi)
    , ("nchar(4) to nvarchar", "nchar(4)", "nvarchar(20)", unicode, map (fmap padUnicode) unicode)
    , ("nvarchar(4) to nvarchar", "nvarchar(4)", "nvarchar(20)", unicode, unicode)
    , ("binary(4) to varbinary", "binary(4)", "varbinary(20)", binary, map (fmap (padBytes 4 0)) binary)
    , ("varbinary(4) to varbinary", "varbinary(4)", "varbinary(20)", binary, binary)
    ]
  where
    ansi = [Just "x", Just B.empty, Just (B.pack [0x78, 0]), Nothing]
    unicode = [Just (B.pack [0x78, 0]), Just B.empty, Just (B.pack [0x3D, 0xD8, 0, 0xDE]), Nothing]
    binary = [Just (B.singleton 1), Just B.empty, Just (B.pack [1, 0, 0]), Nothing]
    padUnicode bytes = bytes <> B.concat (replicate ((8 - B.length bytes) `div` 2) (B.pack [0x20, 0]))
    padBytes width byte bytes = bytes <> B.replicate (width - B.length bytes) byte

rawUnicode :: [(String, B.ByteString)]
rawUnicode =
    [ ("lone high surrogate beside distinct sentinels", B.pack [0x78, 0, 0, 0xD8, 0x79, 0])
    , ("lone low surrogate beside distinct sentinels", B.pack [0x78, 0, 0, 0xDC, 0x79, 0])
    , ("valid supplementary pair", B.pack [0x78, 0, 0x3D, 0xD8, 0, 0xDE, 0x79, 0])
    , ("embedded zero and trailing space", B.pack [0x78, 0, 0, 0, 0x20, 0])
    , ("empty non-NULL Unicode", B.empty)
    , ("semantic leading U+FEFF character", B.pack [0xFF, 0xFE, 0x78, 0])
    ]

lengthCases :: [(String, Text, Text, Text, B.ByteString, Int, Bool, Bool)]
lengthCases =
    [ ("UTF8 varchar", "varchar", utf8, wide, TE.encodeUtf8 wide, 8, False, False)
    , ("UTF8 char", "char", utf8, wide, TE.encodeUtf8 wide, 8, False, True)
    , ("Unicode nvarchar", "nvarchar", "", wide, TE.encodeUtf16LE wide, 5, True, False)
    , ("Unicode nchar", "nchar", "", wide, TE.encodeUtf16LE wide, 5, True, True)
    , ("cp1252 varchar", "varchar", ansi, "éxy", B.pack [0xE9, 0x78, 0x79], 3, False, False)
    , ("cp1252 char", "char", ansi, "éxy", B.pack [0xE9, 0x78, 0x79], 3, False, True)
    ]
  where
    wide = "😀éz"
    utf8 = " COLLATE Latin1_General_100_CI_AS_SC_UTF8"
    ansi = " COLLATE Latin1_General_100_CI_AS"

padTarget :: Int -> Bool -> B.ByteString -> B.ByteString
padTarget width unicode bytes
    | unicode = bytes <> B.concat (replicate ((width - B.length bytes) `div` 2) (B.pack [0x20, 0]))
    | otherwise = bytes <> B.replicate (width - B.length bytes) 0x20

withWarnings :: Connection -> Bool -> IO a -> IO a
withWarnings conn enabled action = do
    Only old <- query1 conn "SELECT CONVERT(int,SESSIONPROPERTY('ANSI_WARNINGS'))" :: IO (Only Int32)
    void $ execute conn (rawSql ("SET ANSI_WARNINGS " <> if enabled then "ON" else "OFF"))
    action `finally` (void $ execute conn (rawSql ("SET ANSI_WARNINGS " <> if old == 0 then "OFF" else "ON")))

pureCases :: [(String, TypeInfo, TypeInfo, Maybe B.ByteString, Maybe B.ByteString)]
pureCases =
    [ ("fixed ANSI pads before Unicode conversion", TIBigChar 4 coll, TINVarChar 40 coll, Just "x", Just (B.pack [0x78, 0, 0x20, 0, 0x20, 0, 0x20, 0]))
    , ("fixed Unicode pads before variable conversion", TINChar 8 coll, TINVarChar 40 coll, Just (B.pack [0x78, 0]), Just (B.pack [0x78, 0, 0x20, 0, 0x20, 0, 0x20, 0]))
    , ("fixed binary empty pads before variable conversion", TIBigBinary 4, TIBigVarBinary 20, Just B.empty, Just (B.replicate 4 0))
    , ("fixed binary NULL remains NULL", TIBigBinary 4, TIBigVarBinary 20, Nothing, Nothing)
    , ("raw high surrogate needs no ntext transcoding", TINVarChar 20 coll, TINText 0 coll, Just high, Just high)
    , ("fixed Unicode padding precedes raw ntext remap", TINChar 8 coll, TINText 0 coll, Just high, Just (high <> B.pack [0x20, 0]))
    ]
  where
    coll = Collation 0x409 0
    high = B.pack [0x78, 0, 0, 0xD8, 0x79, 0]
