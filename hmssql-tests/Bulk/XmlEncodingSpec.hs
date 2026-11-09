module Bulk.XmlEncodingSpec (spec) where

import RecipeParameters
import Control.Exception (try)
import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric (showHex)

import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError, SqlServerError, sqlErrorNumber)
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Types
import TestDb

spec :: Spec
spec = pureSpec >> liveSpec

liveSpec :: Spec
liveSpec = around withTestDb $ do
    describe "SQL-accepted raw XML encodings" $
        forM_ encodings $ \(label, bytes) ->
            it (label ++ " agrees with ordinary XML parameters after storage") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (TIXml Nothing, Just bytes))]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                Only expected <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Text)
                loadBulk conn bulk rows `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected
    describe "XML byte encoding identification" $
        forM_ [("LE", TE.encodeUtf16LE, True), ("BE", TE.encodeUtf16BE, True), ("UTF32LE", (B.pack [0xFF, 0xFE, 0, 0] <>) . TE.encodeUtf32LE, False), ("UTF32BE", (B.pack [0, 0, 0xFE, 0xFF] <>) . TE.encodeUtf32BE, False)] $ \(label, encoder, clientSupported) ->
            forM_ ["xml", "nvarchar(max)"] $ \target ->
                it (label ++ " source follows server acceptance into " ++ T.unpack target) $ \conn -> do
                    (bulk, ordinary) <- createPair conn target
                    let bytes = encoder "<r>😀é</r>"
                        rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (TIXml Nothing, Just bytes))]]
                        statement = "INSERT INTO " <> ordinary <> "(k,v) VALUES(@p1," <> (if target == "xml" then "@p2" else "CONVERT(nvarchar(max),@p2)") <> ")"
                    native <- try (executeMany conn statement rows)
                    case native of
                        Left (e :: SqlServerError) ->
                            if target == "xml"
                                then loadBulk conn bulk rows `shouldThrow` (\(bulkError :: SqlServerError) -> sqlErrorNumber bulkError == sqlErrorNumber e)
                                else loadBulk conn bulk rows `shouldThrow` (\(_ :: EncodeError) -> True)
                        Right _ -> do
                            query1 conn (rawSql ("SELECT v FROM " <> ordinary)) `shouldReturn` Only ("<r>😀é</r>" :: Text)
                            if target == "nvarchar(max)" && not clientSupported
                                then loadBulk conn bulk rows `shouldThrow` (\(_ :: EncodeError) -> True)
                                else do
                                    loadBulk conn bulk rows `shouldReturn` 1
                                    query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only ("<r>😀é</r>" :: Text)
    describe "encoded XML source into character destinations" $
        forM_ [("UTF8 plain content", TE.encodeUtf8 "plain text", "plain text"), ("UTF8 document", TE.encodeUtf8 "<r>😀é</r>", "<r>😀é</r>"), ("UTF16LE document", B.pack [0xFF, 0xFE] <> TE.encodeUtf16LE "<r>😀é</r>", "<r>😀é</r>"), ("UTF16BE document", B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE "<r>😀é</r>", "<r>😀é</r>")] $ \(label, bytes, expected) ->
            it (label ++ " preserves text when the existing conversion needs no canonicalization") $ \conn -> do
                (bulk, ordinary) <- createPair conn "nvarchar(max)"
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (TIXml Nothing, Just bytes))]]
                executeMany conn ("INSERT INTO " <> ordinary <> "(k,v) VALUES(@p1,CONVERT(nvarchar(max),@p2))") rows `shouldReturn` [1]
                query1 conn (rawSql ("SELECT v FROM " <> ordinary)) `shouldReturn` Only (expected :: Text)
                loadBulk conn bulk rows `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected
    it "refuses unsupported declared XML-to-character transcoding rather than changing its meaning" $ \conn -> do
        (bulk, ordinary) <- createPair conn "nvarchar(max)"
        let bytes = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r>" <> B.pack [0xC3, 0xA9] <> "</r>"
            rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (TIXml Nothing, Just bytes))]]
        executeMany conn ("INSERT INTO " <> ordinary <> "(k,v) VALUES(@p1,CONVERT(nvarchar(max),@p2))") rows `shouldReturn` [1]
        query1 conn (rawSql ("SELECT v FROM " <> ordinary)) `shouldReturn` Only ("<r>Ã©</r>" :: Text)
        loadBulk conn bulk rows `shouldThrow` (\(_ :: EncodeError) -> True)
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> bulk)) `shouldReturn` Only (0 :: Int32)
    describe "Unicode text source XML conversion" $
        forM_ ["", "plain text", "😀é  ", "<r>😀&#x1D11E;&amp;</r>", "\xFEFF<r>😀</r>", "\xFEFF\xFEFF<r>😀</r>", "<?xml version=\"1.0\" encoding=\"UTF-16\"?><r>😀</r>"] $ \input ->
            it ("retains ordinary Unicode conversion for " ++ show input) $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                let rows = [[SqlParam (1 :: Int32), SqlParam (input :: Text)]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                Only expected <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Text)
                loadBulk conn bulk rows `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected
    describe "ANSI source XML encoding decisions" $
        forM_ ansiSources $ \(label, collation, bytes) ->
            it (label ++ " agrees with the same declared varchar source") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                void $ execute conn (rawSql ("CREATE TABLE #ansi_xml_source(v varchar(200) COLLATE " <> collation <> ")"))
                [source] <- describeBulkColumns conn (bulkCopy "#ansi_xml_source")
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType source, Just bytes))]]
                -- A varchar RPC formal uses the database's default collation.
                -- Construct the declared source collation explicitly on the server,
                -- rather than comparing a UTF8 bulk source with a CP1252 formal.
                let hex = T.concat [T.justifyRight 2 '0' (T.pack (showHex byte "")) | byte <- B.unpack bytes]
                    sourceExpression =
                        if collation == "Latin1_General_100_CI_AS_SC_UTF8"
                            then "CONVERT(varchar(200),N'" <> T.replace "'" "''" (TE.decodeUtf8 bytes) <> "' COLLATE " <> collation <> ")"
                            else "CONVERT(varchar(200),0x" <> hex <> ") COLLATE " <> collation
                query1 conn (rawSql ("SELECT CONVERT(varbinary(max)," <> sourceExpression <> ")")) `shouldReturn` Only bytes
                void $ execute conn (rawSql ("INSERT INTO " <> ordinary <> "(k,v) SELECT 1,CONVERT(xml," <> sourceExpression <> ")"))
                Only expected <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Text)
                loadBulk conn bulk rows `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected
    it "does not repair invalid UTF8 before XML validation" $ \conn -> do
        (bulk, ordinary) <- createPair conn "xml"
        void $ execute conn "CREATE TABLE #xml_utf8_source(v varchar(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8); INSERT INTO #xml_utf8_source VALUES(0x3C723EC33C2F723E)"
        let bytes = B.pack [0x3C, 0x72, 0x3E, 0xC3, 0x3C, 0x2F, 0x72, 0x3E]
        query1 conn "SELECT CONVERT(varbinary(max),v) FROM #xml_utf8_source" `shouldReturn` Only bytes
        [source] <- describeBulkColumns conn (bulkCopy "#xml_utf8_source")
        native <- try (execute conn (rawSql ("INSERT INTO " <> ordinary <> "(k,v) SELECT 1,v FROM #xml_utf8_source")))
        case native of
            Left (e :: SqlServerError) -> loadBulk conn bulk [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType source, Just bytes))]] `shouldThrow` (\(bulkError :: SqlServerError) -> sqlErrorNumber bulkError == sqlErrorNumber e)
            Right _ -> expectationFailure "ordinary XML conversion unexpectedly accepted the invalid UTF8"
        forM_ [bulk, ordinary] $ \table -> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table)) `shouldReturn` Only (0 :: Int32)
    it "keeps rejection of a UTF8 declaration in Unicode text" $ \conn -> do
        (bulk, ordinary) <- createPair conn "xml"
        let rows = [[SqlParam (1 :: Int32), SqlParam ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>é</r>" :: Text)]]
        native <- try (loadBatch conn ordinary rows)
        case native of
            Left (e :: SqlServerError) -> loadBulk conn bulk rows `shouldThrow` (\(bulkError :: SqlServerError) -> sqlErrorNumber bulkError == sqlErrorNumber e)
            Right _ -> expectationFailure "ordinary Unicode XML unexpectedly accepted the incompatible declaration"
    describe "Unicode source byte order marks" $
        forM_ [("UTF16BE", B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE "<r>😀é</r>"), ("UTF8", B.pack [0xEF, 0xBB, 0xBF] <> "A<r>x</r>")] $ \(label, bytes) ->
            it ("retains server sniffing of a " ++ label ++ " mark in Unicode source bytes") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                void $ execute conn "CREATE TABLE #unicode_xml_source(v nvarchar(100))"
                [source] <- describeBulkColumns conn (bulkCopy "#unicode_xml_source")
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType source, Just bytes))]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                Only expected <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Text)
                loadBulk conn bulk rows `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected
    describe "invalid Unicode XML code units" $
        forM_ [("high", 0xD8), ("low", 0xDC)] $ \(label, highByte) ->
            it ("does not replace a lone " ++ label ++ " surrogate with valid XML text") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                void $ execute conn "CREATE TABLE #invalid_xml_source(v nvarchar(100))"
                [source] <- describeBulkColumns conn (bulkCopy "#invalid_xml_source")
                let rows = [[SqlParam (1 :: Int32), SqlParam (RawParam (bulkColumnType source, Just (B.pack [0x78, 0, 0, highByte, 0x79, 0])))]]
                native <- try (loadBatch conn ordinary rows)
                case native of
                    Left (e :: SqlServerError) -> loadBulk conn bulk rows `shouldThrow` (\(bulkError :: SqlServerError) -> sqlErrorNumber bulkError == sqlErrorNumber e)
                    Right _ -> expectationFailure "ordinary XML conversion unexpectedly accepted the invalid surrogate"
                forM_ [bulk, ordinary] $ \table -> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table)) `shouldReturn` Only (0 :: Int32)
    describe "raw XML encodings across bulk value chunks" $
        forM_ ([("UTF8-" ++ show n, TE.encodeUtf8 ("<r>" <> T.replicate n "a" <> "😀</r>")) | n <- [7993, 7994, 7995]] ++ [("UTF16BE-" ++ show n, B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE ("<r>" <> T.replicate n "a" <> "😀</r>")) | n <- [3994, 3995, 3996]]) $ \(label, bytes) ->
            it (label ++ " retains complete content, NULL and empty values") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                let rows = [[SqlParam i, SqlParam (RawParam (TIXml Nothing, value))] | (i, value) <- [(1, Just bytes), (2, Nothing), (3, Just B.empty)] :: [(Int32, Maybe B.ByteString)]]
                loadBatch conn ordinary rows `shouldReturn` [1, 1, 1]
                expected <- query conn (rawSql ("SELECT k,v FROM " <> ordinary <> " ORDER BY k")) :: IO [(Int32, Maybe Text)]
                loadBulk conn bulk rows `shouldReturn` 3
                query conn (rawSql ("SELECT k,v FROM " <> bulk <> " ORDER BY k")) `shouldReturn` expected
    it "preserves raw encodings before typed XML schema validation" $ \conn -> do
        ci <- defaultTestConnectInfo
        withScratchSchema ci "xml_encoding" $ \schema -> do
            void $ execute conn $ rawSql $ "CREATE XML SCHEMA COLLECTION " <> schema <> ".Doc AS N'<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"><xs:element name=\"r\" type=\"xs:string\"/></xs:schema>'"
            let table = schema <> ".documents"
            void $ execute conn (rawSql ("CREATE TABLE " <> table <> "(id int,v xml(" <> schema <> ".Doc))"))
            let rows = [(1 :: Int32, RawParam (TIXml Nothing, Just (TE.encodeUtf8 "<r>😀é</r>"))), (2, RawParam (TIXml Nothing, Just (B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE "<r>😀é</r>")))]
            bulkInsert conn table rows `shouldReturn` 2
            query conn (rawSql ("SELECT id,v FROM " <> table <> " ORDER BY id")) `shouldReturn` [(1 :: Int32, "<r>😀é</r>" :: Text), (2, "<r>😀é</r>")]
    describe "explicit binary source declarations for XML destination" $
        forM_ encodings $ \(label, bytes) ->
            it (label ++ " is interpreted by the server from original bytes") $ \conn -> do
                (bulk, ordinary) <- createPair conn "xml"
                loadBatch conn ordinary [[SqlParam (1 :: Int32), SqlParam (RawParam (TIXml Nothing, Just bytes))]] `shouldReturn` [1]
                Only expected <- query1 conn (rawSql ("SELECT v FROM " <> ordinary)) :: IO (Only Text)
                columns <- describeBulkColumns conn (bulkCopy bulk)
                let sourceColumns = [if bulkColumnName c == "v" then c{bulkColumnType = TIBigVarBinary maxBound} else c | c <- columns]
                bulkInsertWith (bulkCopy bulk){bulkColumns = DescribedColumns sourceColumns} conn [[SqlParam (1 :: Int32), SqlParam (RawParam (TIBigVarBinary maxBound, Just bytes))]] `shouldReturn` 1
                query1 conn (rawSql ("SELECT v FROM " <> bulk)) `shouldReturn` Only expected

encodings :: [(String, B.ByteString)]
encodings =
    [ ("empty UTF8 content", B.empty)
    , ("ASCII UTF8 text content", "plain text")
    , ("supplementary UTF8 text content", TE.encodeUtf8 "😀é  ")
    , ("UTF8 document and character references", TE.encodeUtf8 "<r>😀&#x1D11E;&amp; é  </r>")
    , ("UTF8 declaration", TE.encodeUtf8 "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>😀é</r>")
    , ("UTF8 byte order mark", B.pack [0xEF, 0xBB, 0xBF] <> TE.encodeUtf8 "<r>😀é</r>")
    , ("UTF16LE byte order mark", B.pack [0xFF, 0xFE] <> TE.encodeUtf16LE "<r>😀é</r>")
    , ("UTF16BE byte order mark", B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE "<r>😀é</r>")
    , ("Latin1 declaration", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r>" <> B.singleton 0xE9 <> "</r>")
    ]

ansiSources :: [(String, Text, B.ByteString)]
ansiSources =
    [ ("CP1252 without declaration", cp1252, "<r>" <> B.singleton 0xE9 <> "</r>")
    , ("CP1252 ISO declaration", cp1252, "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r>" <> B.singleton 0xE9 <> "</r>")
    , ("CP1252 version-only declaration", cp1252, "<?xml version=\"1.0\"?><r>" <> B.singleton 0xE9 <> "</r>")
    , ("CP1252 stylesheet PI is not an encoding declaration", cp1252, "<?xml-stylesheet encoding=\"UTF-8\"?><r>" <> B.singleton 0xE9 <> "</r>")
    , ("CP1252 declaration whitespace and quotes", cp1252, "<?xml\tversion=\"1.0\"\r\nencoding = 'ISO-8859-1'?><r>" <> B.singleton 0xE9 <> "</r>")
    , ("CP1252 UTF8 declaration", cp1252, TE.encodeUtf8 "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>é</r>")
    , ("CP1252 UTF8 BOM", cp1252, B.pack [0xEF, 0xBB, 0xBF] <> TE.encodeUtf8 "<r>é</r>")
    , ("UTF8 without declaration", utf8, TE.encodeUtf8 "<r>😀é</r>")
    , ("UTF8 declaration", utf8, TE.encodeUtf8 "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>😀é</r>")
    ]
  where
    cp1252 = "Latin1_General_100_CI_AS"; utf8 = "Latin1_General_100_CI_AS_SC_UTF8"

pureSpec :: Spec
pureSpec = describe "XML byte conversion (pure)" $ do
    forM_ preserved $ \(label, source, target, input, expected) ->
        it label $
            encodeBulkCellBytes defaultTdsContext (BulkColumn "v" target True False) (source, Just input) `shouldBe` Right (Just expected)
    forM_ [("non-UTF8 declared bytes", latin), ("UTF32LE mark", B.pack [0xFF, 0xFE, 0, 0] <> TE.encodeUtf32LE "<r>x</r>"), ("incomplete UTF8", B.singleton 0xC3)] $ \(label, bytes) ->
        it ("refuses " ++ label ++ " as client-converted characters") $
            encodeBulkCellBytes defaultTdsContext (BulkColumn "v" unicode True False) (xml, Just bytes) `shouldSatisfy` isLeft
  where
    xml = TIXml Nothing
    coll = Collation 0x409 0
    unicode = TINVarChar maxBound coll
    text = "<r>😀é</r>"
    textLE = TE.encodeUtf16LE text
    textUTF8 = TE.encodeUtf8 text
    latin = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r>" <> B.pack [0xC3, 0xA9] <> "</r>"
    high = B.pack [0x78, 0, 0, 0xD8, 0x79, 0]
    preserved =
        [ ("raw UTF8 XML remains bytes", xml, xml, textUTF8, textUTF8)
        , ("declared Latin1 XML remains bytes", xml, xml, latin, latin)
        , ("ANSI declared encoding remains bytes", TIBigVarChar 200 coll, xml, latin, latin)
        , ("Unicode XML gets an encoding mark", unicode, xml, textLE, B.pack [0xFF, 0xFE] <> textLE)
        , ("Unicode mark is not doubled", unicode, xml, B.pack [0xFF, 0xFE] <> textLE, B.pack [0xFF, 0xFE] <> textLE)
        , ("invalid Unicode units reach server XML validation unchanged", unicode, xml, high, B.pack [0xFF, 0xFE] <> high)
        , ("UTF8 XML becomes character code units", xml, unicode, textUTF8, textLE)
        , ("UTF16BE XML becomes character code units", xml, unicode, B.pack [0xFE, 0xFF] <> TE.encodeUtf16BE text, textLE)
        ]
