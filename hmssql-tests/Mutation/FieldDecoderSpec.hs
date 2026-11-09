-- | Tests found by mutation testing of "Hmssql.Decoding": how field decoders
-- combine, that every combinator checks the column type up front, and
-- value rules the live tests don't reach (pure: no server needed).
module Mutation.FieldDecoderSpec (spec) where

import RecipeDecoding
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft)
import Data.Decimal (Decimal)
import Data.Int (Int32)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Decoding
import Hmssql.Tds.Context
import Hmssql.Tds.Value (rowFromValues)
import Hmssql.Tds.Token (compileResultSet)
import Hmssql.Tds.TypeInfo (RawBytes)

column :: TypeInfo -> ColumnInfo
column ti = ColumnInfo "c" ti 0x0001 0 Nothing

intCol, textCol, guidCol :: ColumnInfo
intCol = column (TIIntN 4)
textCol = column (TINVarChar 20 (Collation 0 0))
guidCol = column TIGuid

-- | Compile against the column and decode one value.
decodeWith :: FieldDecoder a -> ColumnInfo -> RawBytes -> Either String a
decodeWith dec col v = compileField dec defaultTdsContext col >>= \decode -> decodeCell decode v

compiles :: FieldDecoder a -> ColumnInfo -> Bool
compiles dec col = either (const False) (const True) (compileField dec defaultTdsContext col)

int4 :: Int32 -> RawBytes
int4 = Just . LB.toStrict . Put.runPut . Put.putInt32le

utf16 :: Text -> RawBytes
utf16 = Just . T.encodeUtf16LE

spec :: Spec
spec = do
  describe "FieldDecoder's Semigroup" $ do
    it "prefers the left decoder when both accept the column" $
      decodeWith (((1 :: Int) <$ fieldDecoder @Int32) <> (2 <$ fieldDecoder @Int32)) intCol (int4 5) `shouldBe` Right 1

    it "falls back to the right decoder" $ do
      let d = (T.pack . show <$> fieldDecoder @Int32) <> fieldDecoder @Text
      decodeWith d intCol (int4 5) `shouldBe` Right "5"
      decodeWith d textCol (utf16 "abc") `shouldBe` Right "abc"

    it "reports both reasons when neither accepts the column" $ do
      let d = (T.pack . show <$> fieldDecoder @Int32) <> fieldDecoder @Text
      case compileField d defaultTdsContext guidCol of
        Right _ -> expectationFailure "accepted a uniqueidentifier column"
        Left msg -> do
          msg `shouldSatisfy` ("as Int32" `isInfixOf`)
          msg `shouldSatisfy` ("as Text" `isInfixOf`)

  describe "values" $ do
    it "a fixed-length tinyint (INT1TYPE) is unsigned" $ do
      decodeWith (fieldDecoder @Int) (column TIInt1) (Just "\200") `shouldBe` Right 200
      decodeWith (fieldDecoder @Integer) (column TIInt1) (Just "\255") `shouldBe` Right 255

    it "money as Decimal keeps all four decimal places" $ do
      let money8 = Just (LB.toStrict (Put.runPut (Put.putWord32le 0 >> Put.putWord32le 12345)))
          money4 = Just (LB.toStrict (Put.runPut (Put.putInt32le (-12345))))
      decodeWith (fieldDecoder @Decimal) (column (TIMoneyN 8)) money8 `shouldBe` Right 1.2345
      decodeWith (fieldDecoder @Decimal) (column (TIMoneyN 4)) money4 `shouldBe` Right (-1.2345)

  describe "toMonadicRowDecoder" $
    it "leaves the columns and values after the ones it consumed to the next decoder" $ do
      let dec = (,) <$> toMonadicRowDecoder (rowDecoder @(Only Int32)) <*> singleFieldM (fieldDecoder @Int32)
          cols = [intCol, intCol { columnName = "d" }]
      decodeFixture cols (compileMonadicRowDecoder dec defaultTdsContext cols) [int4 1, int4 2]
        `shouldReturn` Right (Only 1, 2)

  describe "type checks happen when the column arrives, not per value" $ do
    it "refineField rejects a column its inner decoder rejects" $
      compiles (refineField Right (fieldDecoder @Int32)) textCol `shouldBe` False

    it "nullableField rejects a column its inner decoder rejects" $
      compiles (nullableField (fieldDecoder @Int32)) textCol `shouldBe` False

    it "Maybe rejects a column the inner type rejects, even for NULL values" $ do
      compiles (fieldDecoder @(Maybe Int32)) textCol `shouldBe` False
      isLeft (decodeWith (fieldDecoder @(Maybe Int32)) textCol Nothing) `shouldBe` True
