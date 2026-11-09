{-# LANGUAGE DeriveGeneric #-}
-- | Rendering SQL and inspecting parameter names must not run field encoders
-- or force values that their Haskell record constructors leave lazy.
module Api.FieldEncoderStrictnessSpec (spec) where

import Control.Exception (evaluate)
import qualified Data.ByteString as B
import Data.Int (Int32, Int64)
import Data.Text (Text)
import GHC.Generics (Generic)
import Test.Hspec

import Hmssql
import Hmssql.Encoding
import Hmssql.Tds.Context (defaultTdsContext)

data LazyNumeric = LazyNumeric Int32 Int64 Double deriving Generic
instance ToSqlRow LazyNumeric

data StrictOne = StrictOne !Int32 deriving Generic
instance ToSqlRow StrictOne

data StrictNumeric = StrictNumeric !Int32 !Int64 !Double deriving Generic
instance ToSqlRow StrictNumeric

data MixedNumeric = MixedNumeric !Int32 Int64 !Double deriving Generic
instance ToSqlRow MixedNumeric

-- A custom field's constructor is strict enough for the enclosing record,
-- while its contents and conversion can still remain unevaluated.
data Custom = Custom Int32
instance ToSqlField Custom where
  fieldEncoder = FieldEncoder
    (\ctx (Custom value) -> encodeParam (fieldEncoder @Int32) ctx (value + 1))
    (nullParamType (fieldEncoder @Int32))

data StrictCustom = StrictCustom !Custom !Int32 deriving Generic
instance ToSqlRow StrictCustom

sql :: Text
sql = "SELECT @p1, @p2, @p3"

spec :: Spec
spec = do
  it "renders a lazy numeric record without evaluating its fields" $ do
    let q = mkQuery sql (LazyNumeric undefined undefined undefined)
    (evaluate q >> pure ()) `shouldReturn` ()
    queryText q `shouldBe` sql
    show q `shouldBe` show sql

  it "renders a numeric tuple without evaluating its fields" $
    queryText (mkQuery sql (undefined :: Int32, undefined :: Int64, undefined :: Double)) `shouldBe` sql

  it "renders Only without evaluating its numeric field" $
    queryText (mkQuery "SELECT @p1" (Only (undefined :: Int32))) `shouldBe` "SELECT @p1"

  it "inspects the parameter spine without evaluating lazy fields" $
    evaluate (length (encodeParams rowEncoder (undefined :: Int32, undefined :: Int64, undefined :: Double))) `shouldReturn` 3

  it "does not force a singleton record just to render its parameter name" $
    queryText (mkQuery "SELECT @p1" (StrictOne undefined)) `shouldBe` "SELECT @p1"

  it "preserves the strict record constructor's evaluation" $
    evaluate (queryText (mkQuery sql (StrictNumeric undefined 2 3))) `shouldThrow` anyErrorCall

  it "uses each selector's strictness independently" $
    queryText (mkQuery sql (MixedNumeric 1 undefined 3)) `shouldBe` sql

  it "does not run a custom field conversion while rendering SQL" $
    queryText (mkQuery "SELECT @p1" (StrictCustom (Custom undefined) 0)) `shouldBe` "SELECT @p1"

  it "uses the custom encoder when a strict field is encoded" $
    case encodeParams rowEncoder (StrictCustom (Custom 41) 0) of
      [(name, encode), _] -> do
        name `shouldBe` ""
        case encode defaultTdsContext of
          Right (_, ParamBytes bytes) -> bytes `shouldBe` Just (B.pack [42, 0, 0, 0])
          _ -> expectationFailure "custom field did not produce bytes"
      _ -> expectationFailure "custom row did not produce two parameters"
