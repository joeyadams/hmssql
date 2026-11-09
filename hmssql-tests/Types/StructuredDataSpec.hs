module Types.StructuredDataSpec (spec) where

import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Errors (sqlErrorNumber)
import Hmssql.BulkCopy
import Hmssql.Query (queryMWith)
import Hmssql.Decoding (sqlRowDecoder)
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "XML serialization" $ do
    forM_ xmlCases $ \(label,input) -> do
      it (label ++ " as an XML parameter") $ \conn -> do
        -- SQL Server canonicalizes XML (entities, empty elements, and
        -- whitespace). Compare the two independently encoded inputs after
        -- the server's conversion, not to an invented canonical spelling.
        Only canonical <- query1 conn (mkQuery "SELECT CONVERT(xml,@p1)" (Only input)) :: IO (Only Text)
        query1 conn (mkQuery "SELECT @p1" (Only (SqlXml input))) `shouldReturn` Only canonical
        query1 conn (mkQuery "SELECT @p1" (Only (SqlXml input))) `shouldReturn` Only (SqlXml canonical)
        rows <- queryMWith sqlRowDecoder conn (mkQuery "SELECT @p1, CAST(NULL AS xml)" (Only (SqlXml input)))
        map sqlRowValues rows `shouldBe` [[SqlXml canonical,SqlNull]]
      it (label ++ " through bulk copy") $ \conn -> do
        void $ execute conn "CREATE TABLE #xml_data (id int, v xml)"
        Only canonical <- query1 conn (mkQuery "SELECT CONVERT(xml,@p1)" (Only input)) :: IO (Only Text)
        bulkInsert conn "#xml_data" [(1 :: Int32,Just (SqlXml input)),(2,Nothing :: Maybe SqlValue)] `shouldReturn` 2
        query conn "SELECT id,v FROM #xml_data ORDER BY id" `shouldReturn` [(1 :: Int32,Just canonical),(2,Nothing)]
    it "extracts supplementary characters without reinterpreting entities" $ \conn -> do
      query1 conn (mkQuery "DECLARE @x xml=@p1; SELECT @x.value('(/r/text())[1]', 'nvarchar(30)')" (Only (SqlXml "<r>😀&#x1D11E;&amp;</r>")))
        `shouldReturn` Only ("😀𝄞&" :: Text)
    it "distinguishes empty XML, SQL NULL, and whitespace preserved with style 1" $ \conn -> do
      query1 conn "DECLARE @x xml=CONVERT(xml,N'<r>  </r>',1); SELECT CAST(N'' AS xml), CAST(NULL AS xml), @x.value('(/r/text())[1]', 'nvarchar(10)')"
        `shouldReturn` ("" :: Text,Nothing :: Maybe Text,"  " :: Text)

  describe "JSON text and SQL functions" $ do
    forM_ jsonCases $ \(label,input) -> do
      it (label ++ " is stored as text without client normalization") $ \conn -> do
        void $ execute conn "CREATE TABLE #json_text (v nvarchar(max) CHECK (ISJSON(v)=1))"
        void $ execute conn $ mkQuery "INSERT INTO #json_text VALUES (@p1)" (Only input)
        query1 conn "SELECT v FROM #json_text" `shouldReturn` Only input
        query1 conn "SELECT v FROM #json_text" `shouldReturn` Only (SqlText input)
      skipBeforeSql2025 "native json type" $
        it (label ++ " in a native json column agrees with the server's text representation") $ \conn -> do
          void $ execute conn "CREATE TABLE #json_native (v json)"
          let nativeInput = T.replace "1e40" "1e3" input
          void $ execute conn $ mkQuery "INSERT INTO #json_native VALUES (CAST(@p1 AS json))" (Only nativeInput)
          Only expected <- query1 conn "SELECT CAST(v AS nvarchar(max)) FROM #json_native" :: IO (Only Text)
          query1 conn "SELECT v FROM #json_native" `shouldReturn` Only expected
          query1 conn "SELECT v FROM #json_native" `shouldReturn` Only (SqlText expected)
    it "OPENJSON preserves supplementary characters from escaped surrogate pairs" $ \conn -> do
      let input = "{\"s\":\"\\ud83d\\ude00\\ud834\\udd1e\",\"n\":null,\"empty\":\"\"}" :: Text
      query1 conn (mkQuery "SELECT s,n,empty FROM OPENJSON(@p1) WITH (s nvarchar(max),n nvarchar(max),empty nvarchar(max))" (Only input))
        `shouldReturn` ("😀𝄞" :: Text,Nothing :: Maybe Text,"" :: Text)
    it "OPENJSON returns a long supplementary string beyond JSON_VALUE's scalar limit" $ \conn -> do
      let value = T.replicate 5000 "😀"
          input = "{\"s\":\"" <> value <> "\"}"
      query1 conn (mkQuery "SELECT s,JSON_VALUE(@p1,'$.s') FROM OPENJSON(@p1) WITH (s nvarchar(max))" (Only input))
        `shouldReturn` (value,Nothing :: Maybe Text)
    it "FOR JSON output escapes controls while preserving the original value on parse" $ \conn -> do
      let value = "😀\0\t\r\n\"\\ é" :: Text
      Only json <- query1 conn (mkQuery "SELECT @p1 AS s FOR JSON PATH, WITHOUT_ARRAY_WRAPPER" (Only value)) :: IO (Only Text)
      query1 conn (mkQuery "SELECT s FROM OPENJSON(@p1) WITH (s nvarchar(max))" (Only json)) `shouldReturn` Only value
    skipBeforeSql2025 "native json type" $ it "reports native JSON numeric overflow without altering the input" $ \conn -> do
      let input = "[1e40]" :: Text
      (query1 conn (mkQuery "SELECT CAST(@p1 AS json)" (Only input)) :: IO (Only Text))
        `shouldThrow` (\e -> sqlErrorNumber e == 1007)
      query1 conn (mkQuery "SELECT @p1" (Only input)) `shouldReturn` Only input
    it "JSON null and missing properties remain distinct from the literal string null" $ \conn ->
      query1 conn "SELECT JSON_VALUE(N'{\"s\":\"null\",\"n\":null}','$.s'), JSON_VALUE(N'{\"n\":null}','$.n'), JSON_VALUE(N'{}','$.missing')"
        `shouldReturn` ("null" :: Text,Nothing :: Maybe Text,Nothing :: Maybe Text)

xmlCases :: [(String,Text)]
xmlCases =
  [ ("empty content", ""), ("text-only content", "😀 text")
  , ("multiple roots", "<a/><b/>")
  , ("entities", "<a>&lt;&gt;&amp;&quot;&apos;</a>")
  , ("numeric character references", "<a>&#128512;&#x1D11E;</a>")
  , ("CDATA", "<a><![CDATA[<😀>&]]></a>")
  , ("namespaces", "<r xmlns=\"urn:😀\" xmlns:x=\"urn:x\"><x:v>𝄞</x:v></r>")
  , ("comments and processing instructions", "<?test value?><r><!--😀--><v/></r>")
  , ("attribute whitespace", "<r a=\"x&#x9;y&#xA;z\">  value  </r>")
  , ("large supplementary text", "<r>" <> T.replicate 9000 "😀𝄞" <> "</r>")
  , ("XML declaration", "<?xml version=\"1.0\"?><r>😀</r>")
  , ("Unicode element names", "<日本語 属性=\"é\">𝄞</日本語>")
  ]

jsonCases :: [(String,Text)]
jsonCases =
  [ ("empty object","{}"), ("empty array","[]")
  , ("whitespace and duplicate keys"," { \"x\" : 1, \"x\" : 2 } \n")
  , ("surrogate escape pair","{\"s\":\"\\ud83d\\ude00\\ud834\\udd1e\"}")
  , ("literal supplementary characters","{\"😀\":\"𝄞𐀀\"}")
  , ("escaped controls","[\"\\u0000\\b\\f\\n\\r\\t\\u0001\"]")
  , ("large and precise numbers","[123456789012345678901234567890,0.000000000000000000000001,-0,1e40]")
  , ("nested structures","{\"a\":[null,true,false,{},[],{\"b\":[1,2,3]}]}")
  , ("large string","{\"s\":\"" <> T.replicate 9000 "😀abc" <> "\"}")
  , ("large array","[" <> T.intercalate "," (replicate 5000 "{\"😀\":123}") <> "]")
  ]
