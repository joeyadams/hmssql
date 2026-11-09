-- | Tests found by mutation testing of "Hmssql.Tds.TypeInfo": the T-SQL
-- declarations of parameter types that only a 'RawParam' can send.
module Mutation.TypeInfoSpec (spec) where

import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Time
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Tds.Primitives (putDateTime4, putMoney4)
import Hmssql.Tds.TypeInfo (typeInfoSqlName)
import TestDb

coll :: Collation
coll = Collation 0 0

bytes :: Put.Put -> Maybe LB.ByteString
bytes = Just . Put.runPut

spec :: Spec
spec = do
  describe "typeInfoSqlName" $ do
    it "names every fixed-length and length-selected type as SQL Server declares it" $ do
      map typeInfoSqlName
        [ TIIntN 1, TIIntN 2, TIIntN 4, TIIntN 8, TIMoneyN 4, TIMoneyN 8
        , TIDateTimeN 4, TIDateTimeN 8, TIFltN 4, TIFltN 8 ]
        `shouldBe`
        [ "tinyint", "smallint", "int", "bigint", "smallmoney", "money"
        , "smalldatetime", "datetime", "real", "float" ]
    it "gives nchar and nvarchar lengths in characters, char and binary in bytes" $
      map typeInfoSqlName [TINChar 20 coll, TINVarChar 20 coll, TIBigChar 20 coll, TIBigBinary 20]
        `shouldBe` ["nchar(10)", "nvarchar(10)", "char(20)", "binary(20)"]

  around withTestDb $ describe "RawParam declarations reach the server" $ do
    let baseType :: ToSqlField a => Connection -> a -> IO Text
        baseType conn p =
          fromOnly <$> query1 conn ("SELECT CAST(SQL_VARIANT_PROPERTY(" <> param p <> ", 'BaseType') AS nvarchar(128))")
    it "an nchar RawParam is declared with its length in characters" $ \conn -> do
      let p = RawParam (TINChar 6 coll, Just (T.encodeUtf16LE "abc"))
      query1 conn (mkQuery "SELECT @p1, DATALENGTH(@p1)" (Only p)) `shouldReturn` ("abc" :: Text, 6 :: Int)
    it "a 4-byte datetime RawParam is a smalldatetime" $ \conn -> do
      let put = either error id (putDateTime4 (LocalTime (fromGregorian 2020 1 2) (TimeOfDay 3 4 0)))
      baseType conn (RawParam (TIDateTimeN 4, LB.toStrict <$> bytes put)) `shouldReturn` "smalldatetime"
    it "a 4-byte money RawParam is a smallmoney" $ \conn ->
      baseType conn (RawParam (TIMoneyN 4, LB.toStrict <$> bytes (putMoney4 1.5))) `shouldReturn` "smallmoney"
    it "a Word8 parameter is a tinyint" $ \conn ->
      baseType conn (7 :: Word8) `shouldReturn` "tinyint"
