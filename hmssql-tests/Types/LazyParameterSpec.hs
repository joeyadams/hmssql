module Types.LazyParameterSpec (spec) where
import Control.Exception (evaluate)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Test.Hspec
import Hmssql.Encoding
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

spec :: Spec
spec = describe "lazy text's bounded UTF-16 probe" $ do
  let isLarge text = case encodeParam fieldEncoder defaultTdsContext text of
        Right (TINVarChar 0xFFFF _, ParamLazy _) -> True
        _ -> False
  it "does not force a later chunk after ASCII already exceeds the bound" $
    evaluate (isLarge (LT.fromChunks [T.replicate 4001 "a", error "tail forced"])) `shouldReturn` True
  it "counts astral characters as two units without forcing a later chunk" $
    evaluate (isLarge (LT.fromChunks [T.replicate 2001 "😀", error "tail forced"])) `shouldReturn` True
  it "widens when an astral character cannot fit in the final unit" $
    evaluate (isLarge (LT.fromChunks [T.replicate 3999 "a", "😀", error "tail forced"])) `shouldReturn` True
  it "checks the tail at exactly 4000 units" $
    evaluate (isLarge (LT.fromChunks [T.replicate 2000 "😀", error "tail forced"])) `shouldThrow` anyErrorCall
  it "keeps a short multi-chunk value bounded without changing its bytes" $ do
    let chunks = [T.replicate 1000 "a", T.replicate 1000 "😀", T.replicate 999 "b"]
    case encodeParam fieldEncoder defaultTdsContext (LT.fromChunks chunks) of
      Right (TINVarChar 8000 _, ParamBytes (Just bytes)) -> bytes `shouldBe` Utf16.encodeUtf16LE (T.concat chunks)
      other -> expectationFailure (show other)
