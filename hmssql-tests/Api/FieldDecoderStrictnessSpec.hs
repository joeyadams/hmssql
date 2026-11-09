-- | A NULL conversion is evaluated for a NULL value, not for its metadata.
module Api.FieldDecoderStrictnessSpec (spec) where

import Control.Exception (evaluate)
import Data.Int (Int32)
import Test.Hspec
import Hmssql.Query (queryWith)
import Hmssql.Decoding
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo (TypeInfo (..))
import TestDb (withTestDb)

onlyPresent :: FieldDecoder Int32
onlyPresent = refineField (\case
  Nothing -> error "NULL conversion ran"
  Just value -> Right value) (fieldDecoder @(Maybe Int32))

spec :: Spec
spec = do
  it "keeps the NULL conversion lazy while compiling and reading a present value" $ do
    let col = ColumnInfo "n" (TIIntN 4) 1 0 Nothing
    case compileField onlyPresent defaultTdsContext col of
      Left err -> expectationFailure err
      Right decoder -> do
        decodeCell decoder (Just "\42\0\0\0") `shouldBe` Right 42
        evaluate (decodeCell decoder Nothing) `shouldThrow` anyErrorCall

  around withTestDb $
    it "does not run a NULL conversion for empty or non-NULL result sets" $ \conn -> do
      let decoder = singleField onlyPresent
      queryWith decoder conn "SELECT CAST(NULL AS int) WHERE 1 = 0" `shouldReturn` []
      queryWith decoder conn "SELECT CAST(42 AS int)" `shouldReturn` [42]
