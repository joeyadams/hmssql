-- | Encoding text as UTF-16LE ("Hmssql.Tds.Utf16"), as the SQL text,
-- @nvarchar@ parameters, names and LOGIN7 strings are sent: the same bytes
-- as @text@'s own encoder, for every mix of ASCII runs (which take a fast
-- path eight bytes at a time), two-, three- and four-byte characters, and
-- slices that start and end anywhere in the text's array.
module Types.Utf16EncodeSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql.Tds.Utf16

spec :: Spec
spec = describe "encodeUtf16LE" $ do
  it "agrees with text's encodeUtf16LE" $ hedgehog $ do
    t <- forAll genText
    encodeUtf16LE t === T.encodeUtf16LE t

  it "agrees on slices of a longer text" $ hedgehog $ do
    t <- forAll genText
    i <- forAll $ Gen.int (Range.linear 0 (T.length t))
    j <- forAll $ Gen.int (Range.linear 0 (T.length t - i))
    let s = T.take j (T.drop i t)
    encodeUtf16LE s === T.encodeUtf16LE s

  it "utf16Length counts code units" $ hedgehog $ do
    t <- forAll genText
    utf16Length t === B.length (T.encodeUtf16LE t) `div` 2

  it "handles the edges of each UTF-8 length" $ do
    let t = T.pack "\0\x7F\x80\x7FF\x800\xFFFF\x10000\x10FFFF\xD7FF\xE000"
    encodeUtf16LE t `shouldBe` T.encodeUtf16LE t
    encodeUtf16LE "" `shouldBe` B.empty
    utf16Length t `shouldBe` 12

-- | Runs of ASCII of varied length (so the eight-byte steps start and stop
-- anywhere) between non-ASCII characters of every UTF-8 length.
genText :: Gen T.Text
genText = T.concat <$> Gen.list (Range.linear 0 20) piece
  where
    piece = Gen.choice
      [ Gen.text (Range.linear 0 40) Gen.ascii
      , Gen.text (Range.linear 0 5) Gen.unicode
      , Gen.text (Range.linear 0 5) (Gen.element ['\x80', '\x7FF', '\x800', '\xFFFD', '\x10000', '\x1F600', '\x10FFFF'])
      ]
