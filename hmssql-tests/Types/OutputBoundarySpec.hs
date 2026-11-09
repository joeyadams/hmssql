module Types.OutputBoundarySpec (spec) where

import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric (showHex)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Tds.Token (ReturnValue (..))
import Hmssql.Types
import TestDb

spec :: Spec
spec = around withTestDb $ do
    skipBeforeSql2019 "UTF8 variant outputs" $
        forM_ [0, 1, 7, 7988, 7989, 7990, 7991] $ \prefix ->
            it ("retains UTF8 variant collation and payload near its 8000-byte bound, prefix=" ++ show prefix) $ \conn -> do
                let expected = T.replicate prefix "a" <> "😀é  "
                    expression = "CAST((REPLICATE(CAST(N'a' AS nvarchar(max))," <> T.pack (show prefix) <> ")+N'😀é  ') COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(8000))"
                query1 conn (rawSql ("SELECT CAST(" <> expression <> " AS sql_variant),DATALENGTH(" <> expression <> ")")) `shouldReturn` (SqlText expected, fromIntegral (B.length (TE.encodeUtf8 expected)) :: Int32)
                query1 conn (rawSql ("SELECT CAST(SQL_VARIANT_PROPERTY(CAST(" <> expression <> " AS sql_variant),'BaseType') AS nvarchar(128)),CAST(SQL_VARIANT_PROPERTY(CAST(" <> expression <> " AS sql_variant),'MaxLength') AS int)")) `shouldReturn` ("varchar" :: Text, 8000 :: Int32)
                result <- variantOutput conn expression
                readLaterResponse conn
                map (decodeReturnValue @SqlValue) (procOutputValues result) `shouldBe` [Right (SqlText expected)]
    forM_ ["Greek_CI_AS", "Cyrillic_General_CI_AS", "SQL_Latin1_General_CP850_CI_AS"] $ \collation ->
        it ("decodes all byte values in a variant output using its own collation, " ++ T.unpack collation) $ \conn -> do
            let bytes = B.pack [0 .. 255]
            -- Applying COLLATE after a binary-to-varchar cast can transcode
            -- the bytes. Assign binary directly to the declared source column
            -- and establish the exact source before using its Unicode oracle.
            void $ execute conn (rawSql ("CREATE TABLE #variant_codepage_source(v varchar(256) COLLATE " <> collation <> "); INSERT #variant_codepage_source VALUES(0x" <> byteHex <> ")"))
            query1 conn "SELECT CONVERT(varbinary(max),v),DATALENGTH(v) FROM #variant_codepage_source" `shouldReturn` (bytes, 256 :: Int32)
            query1 conn "SELECT CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(CONVERT(sql_variant,v),'Collation')),CONVERT(int,SQL_VARIANT_PROPERTY(CONVERT(sql_variant,v),'MaxLength')) FROM #variant_codepage_source" `shouldReturn` (collation, 256 :: Int32)
            Only expected <- query1 conn "SELECT CONVERT(nvarchar(max),v) FROM #variant_codepage_source" :: IO (Only Text)
            Only (RawValue variantBytes) <- query1 conn "SELECT CONVERT(sql_variant,v) FROM #variant_codepage_source"
            B.take 2 variantBytes `shouldBe` B.pack [0xA7, 7]
            B.drop 9 variantBytes `shouldBe` bytes
            result <- variantOutput conn "(SELECT v FROM #variant_codepage_source)"
            readLaterResponse conn
            map rvValue (procOutputValues result) `shouldBe` [Just variantBytes]
            map (decodeReturnValue @SqlValue) (procOutputValues result) `shouldBe` [Right (SqlText expected)]
    forM_ [3998, 3999, 4000, 4001] $ \prefix ->
        it ("retains reordered long Unicode/binary outputs and explicit NULL, prefix=" ++ show prefix) $ \conn -> do
            let binarySize = prefix * 2 + 3
                expectedText = T.replicate prefix "x" <> "😀𝄞é tail  "
                expectedBinary = B.pack (take binarySize (cycle [0 .. 255])) <> B.pack [0, 0]
                statement = "SET @u=REPLICATE(CAST(N'x' AS nvarchar(max))," <> T.pack (show prefix) <> ")+N'😀𝄞é tail  '; SET @b=CONVERT(varbinary(max),REPLICATE(CAST('" <> byteHex <> "' AS varchar(max))," <> T.pack (show (binarySize `div` 256)) <> ")+LEFT('" <> byteHex <> "'," <> T.pack (show (2 * (binarySize `mod` 256))) <> "),2)+0x0000; SET @nil=NULL; SELECT @u,@b,@nil"
            let stmt = inParam "" statement
            let declaration = inParam "" ("@u nvarchar(max) OUTPUT,@b varbinary(max) OUTPUT,@nil varbinary(max) OUTPUT" :: Text)
            let unicodeOut = outParam "@u" ("initial" :: Text)
            let binaryOut = outParam "@b" (B.singleton 1)
            let nullOut = outParam "@nil" (B.pack [2, 0])
            result <- callProcedure conn "sp_executesql" [stmt, declaration, nullOut, binaryOut, unicodeOut]
            map rvName (procOutputValues result) `shouldBe` ["@nil", "@b", "@u"]
            map (map sqlRowValues . resultRows) (procResultSets result) `shouldBe` [[[SqlText expectedText, SqlBinary expectedBinary, SqlNull]]]
            readLaterResponse conn
            map (decodeReturnValue @SqlValue) (procOutputValues result) `shouldBe` [Right SqlNull, Right (SqlBinary expectedBinary), Right (SqlText expectedText)]

variantOutput :: Connection -> Text -> IO ProcResult
variantOutput conn expression = do
    let stmt = inParam "" ("SET @out=CAST(" <> expression <> " AS sql_variant)" :: Text)
    let declaration = inParam "" ("@out sql_variant OUTPUT" :: Text)
    let output = outParam "@out" (RawParam (TISqlVariant 8016, Nothing))
    callProcedure conn "sp_executesql" [stmt, declaration, output]

-- A short reply might never overwrite the part of a reused buffer holding
-- an earlier output. Consume a distinct response larger than the maximum
-- negotiated TDS packet before inspecting the retained raw values.
readLaterResponse :: Connection -> Expectation
readLaterResponse conn =
    query1 conn "SELECT CONVERT(varbinary(max),REPLICATE(CAST('A5' AS varchar(max)),40000),2)" `shouldReturn` Only (B.replicate 40000 0xA5)

byteHex :: Text
byteHex = T.concat [T.justifyRight 2 '0' (T.pack (showHex n "")) | n <- [0 .. 255 :: Int]]
