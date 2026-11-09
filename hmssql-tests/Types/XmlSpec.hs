-- | The @xml@ type: NULL vs value, unicode content, large documents spanning
-- multiple packets/PLP chunks, typed xml (schema collection), and decoding
-- (both as plain 'Text' and as 'SqlValue').
module Types.XmlSpec (spec) where

import Control.Exception (try)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Errors (SqlServerError, sqlErrorNumber)
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "NULL vs value" $ do
    it "distinguishes NULL xml from an XML value" $ \conn -> do
      r <- query1 conn "SELECT CAST(NULL AS xml), CAST('<a/>' AS xml)"
      r `shouldBe` (Nothing :: Maybe Text, "<a/>" :: Text)

  describe "decoding" $ do
    it "decodes xml as Text" $ \conn -> do
      Only (t :: Text) <- query1 conn "SELECT CAST('<a><b>1</b></a>' AS xml)"
      t `shouldBe` "<a><b>1</b></a>"

    it "decodes xml as SqlXml via SqlValue" $ \conn -> do
      Only v <- query1 conn "SELECT CAST('<a><b>1</b></a>' AS xml)"
      v `shouldBe` SqlXml "<a><b>1</b></a>"

  describe "unicode content" $ do
    it "round trips accented and CJK characters" $ \conn -> do
      let t = "<a>h\233llo \20013\25991</a>" :: Text
      Only (t' :: Text) <- query1 conn ("SELECT CAST(" <> param t <> " AS xml)")
      t' `shouldBe` t

    it "round trips a non-BMP character" $ \conn -> do
      let t = "<a>\x1F600</a>" :: Text
      Only (t' :: Text) <- query1 conn ("SELECT CAST(" <> param t <> " AS xml)")
      t' `shouldBe` t

  describe "large documents" $ do
    it "round trips an xml document spanning multiple PLP chunks/packets" $ \conn -> do
      Only (t :: Text) <- query1 conn
        "SELECT CAST(N'<a>' + REPLICATE(CAST(N'x' AS nvarchar(max)), 20000) + N'</a>' AS xml)"
      T.length t `shouldBe` (20000 + 7)
      t `shouldBe` ("<a>" <> T.replicate 20000 "x" <> "</a>")

  describe "typed xml (schema collection)" $
    it "round trips a value validated against a schema collection" $ \conn -> do
      -- A #temp table can't use a collection outside tempdb, so both are in
      -- a schema of the test's own in the shared database, dropped
      -- afterwards.
      ci <- defaultTestConnectInfo
      withScratchSchema ci "types_xml" $ \s -> do
        _ <- execute conn $ rawSql $
          "CREATE XML SCHEMA COLLECTION " <> s <> ".PersonSchema AS \
          \N'<?xml version=\"1.0\"?>\
          \<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" elementFormDefault=\"qualified\">\
          \  <xs:element name=\"a\" type=\"xs:string\"/>\
          \</xs:schema>'"
        _ <- execute conn (rawSql ("CREATE TABLE " <> s <> ".typed_xml (v xml(" <> s <> ".PersonSchema))"))
        _ <- execute conn (rawSql ("INSERT INTO " <> s <> ".typed_xml (v) VALUES ('<a>hello</a>')"))
        Only (t :: Text) <- query1 conn (rawSql ("SELECT v FROM " <> s <> ".typed_xml"))
        t `shouldBe` "<a>hello</a>"
        -- Validated: an element the collection doesn't declare is refused.
        r <- try (execute conn (rawSql ("INSERT INTO " <> s <> ".typed_xml (v) VALUES ('<b>no</b>')")))
        either (\(e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 6913) (\_ -> expectationFailure "inserted") r
