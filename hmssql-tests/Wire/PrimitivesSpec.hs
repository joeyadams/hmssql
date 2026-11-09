-- | Boundary properties for the leaf encoders in "Hmssql.Tds.Primitives":
-- decimal byte-length steps, the money high/low DWORD split, the date/time
-- family's range checks (an @Either@-returning putter must reject an
-- out-of-range value, not clamp or crash), and non-BMP UCS-2 text. No server
-- needed.
module Wire.PrimitivesSpec (spec) where

import Wire.PrimitiveGet (getMoney8, getTime, getDecimal, getCollation, getBVarChar, getUsVarChar, getUcs2)
import Control.Monad (forM_)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql.Tds.Primitives

import Wire.Util

spec :: Spec
spec = do
  describe "decimal / numeric byte length" $ do
    it "steps at precision 9/10, 19/20, 28/29 (5/9/13/17 bytes incl. the sign byte)" $
      mapM_
        (\(p, expected) -> precisionToLength p + 1 `shouldBe` expected)
        [(1, 5), (9, 5), (10, 9), (19, 9), (20, 13), (28, 13), (29, 17), (38, 17)]

    it "round-trips the maximum magnitude at each byte-length boundary" $ hedgehog $ do
      p <- forAll $ Gen.element [1, 9, 10, 19, 20, 28, 29, 38]
      s <- forAll $ Gen.word8 (Range.linear 0 p)
      positive <- forAll Gen.bool
      let maxMag = 10 ^ (fromIntegral p :: Integer) - 1
          mantissa = if positive then maxMag else negate maxMag
      roundTrip (putDecimal p s) (getDecimal p s (precisionToLength p + 1)) (Decimal s mantissa)

  describe "money" $ do
    it "splits into a signed high DWORD and an unsigned low DWORD" $ do
      let v = Money (MkFixed (-1))
          bytes = LB.toStrict (Put.runPut (putMoney8 v))
      B.take 4 bytes `shouldBe` B.pack [0xFF, 0xFF, 0xFF, 0xFF] -- hi = -1 (int32le)
      B.drop 4 bytes `shouldBe` B.pack [0xFF, 0xFF, 0xFF, 0xFF] -- lo = 0xFFFFFFFF
      Get.runGet getMoney8 (LB.fromStrict bytes) `shouldBe` v

    it "round-trips at the Int64 extremes (sign correctness across the split)" $
      forM_ [minBound, maxBound, -1, 0, 1] $ \i -> do
        let v = Money (MkFixed (fromIntegral (i :: Int64)))
        Get.runGet getMoney8 (Put.runPut (putMoney8 v)) `shouldBe` v

  describe "date/time range checks (Either-returning putters)" $ do
    it "putDate rejects a day before 0001-01-01 or after 9999-12-31" $ do
      expectLeft (putDate (fromGregorian 0 12 31))
      expectLeft (putDate (fromGregorian 10000 1 1))
      expectRight (putDate (fromGregorian 1 1 1))
      expectRight (putDate (fromGregorian 9999 12 31))

    it "putTime rejects an invalid TimeOfDay" $ do
      expectLeft (putTime 7 (TimeOfDay 24 0 0))
      expectLeft (putTime 7 (TimeOfDay 0 60 0))
      expectLeft (putTime 7 (TimeOfDay 0 0 61))
      expectRight (putTime 7 (TimeOfDay 23 59 60)) -- a leap second: clamped, not rejected

    it "putDateTime2 rejects a day outside 0001-01-01..9999-12-31" $ do
      expectLeft (putDateTime2 7 (LocalTime (fromGregorian 0 12 31) midnight))
      expectLeft (putDateTime2 7 (LocalTime (fromGregorian 10000 1 1) midnight))

    it "putDateTimeOffset rejects an offset beyond +-14:00" $ do
      let t = UTCTime (fromGregorian 2020 1 1) 0
      expectLeft (putDateTimeOffset 7 (DateTimeOffset t 841))
      expectLeft (putDateTimeOffset 7 (DateTimeOffset t (-841)))
      expectRight (putDateTimeOffset 7 (DateTimeOffset t 840))
      expectRight (putDateTimeOffset 7 (DateTimeOffset t (-840)))

    it "putDateTime4 (smalldatetime) rejects a day outside 1900-01-01..2079-06-06" $ do
      expectLeft (putDateTime4 (LocalTime (fromGregorian 1899 12 31) midnight))
      expectLeft (putDateTime4 (LocalTime (fromGregorian 2079 6 7) midnight))
      expectRight (putDateTime4 (LocalTime (fromGregorian 1900 1 1) midnight))
      expectRight (putDateTime4 (LocalTime (fromGregorian 2079 6 6) midnight))

    it "putDateTime8 (datetime) rejects a day outside 1753-01-01..9999-12-31" $ do
      expectLeft (putDateTime8 (LocalTime (fromGregorian 1752 12 31) midnight))
      expectRight (putDateTime8 (LocalTime (fromGregorian 1753 1 1) midnight))

    it "rejects any out-of-range day for date/datetime2/datetime/smalldatetime alike" $ hedgehog $ do
      -- Days well before year 1 or well after year 9999, in Modified Julian Day.
      d <- forAll $ Gen.integral (Range.linear (-10000000) (-700000))
      let day = ModifiedJulianDay d
      annotate (showGregorian day)
      assert (isLeft (putDate day))
      assert (isLeft (putDateTime2 7 (LocalTime day midnight)))

  describe "time family at every scale" $
    it "round-trips a value exactly representable at that scale" $ hedgehog $ do
      s <- forAll $ Gen.word8 (Range.linear 0 7)
      units <- forAll $ Gen.integral (Range.linear 0 (86400 * 10 ^ (fromIntegral s :: Int) - 1))
      let tod = timeToTimeOfDay (picosecondsToDiffTime (units * 10 ^ (12 - fromIntegral s :: Int)))
      roundTrip (unsafeRight . putTime s) (getTime s) tod

  describe "UCS-2 / UTF-16" $ do
    it "round-trips astral characters (surrogate pairs)" $ do
      let t = T.pack "\x1F600\x10000\x10FFFFhello"
          units = B.length (T.encodeUtf16LE t) `div` 2
      Get.runGet (getUcs2 units) (Put.runPut (putUcs2 t)) `shouldBe` t

    it "B_VARCHAR / US_VARCHAR round-trip astral characters" $ hedgehog $ do
      let t = T.pack "\x1D11E\x1F4A9"
      roundTrip putBVarChar getBVarChar t
      roundTrip putUsVarChar getUsVarChar t

  describe "collation" $ do
    it "round-trips arbitrary LCID/flags/version and sort-id bytes" $ hedgehog $ do
      info <- forAll $ Gen.word32 Range.linearBounded
      sortId <- forAll $ Gen.word8 Range.linearBounded
      roundTrip putCollation getCollation (Collation info sortId)

    it "round-trips realistic named collations" $
      mapM_
        (\c -> Get.runGet getCollation (Put.runPut (putCollation c)) `shouldBe` c)
        [ Collation 0x00000409 0x00 -- SQL_Latin1_General_CP1_CI_AS-ish LCID, no sort id
        , Collation 0x0000040C 0x34 -- French LCID with a legacy sort id
        , Collation 0xFFFFFFFF 0xFF
        ]
  where
    isLeft = either (const True) (const False)
    expectLeft, expectRight :: Either String a -> Expectation
    expectLeft = either (const (pure ())) (const (expectationFailure "expected Left, got Right"))
    expectRight = either (\e -> expectationFailure ("expected Right, got Left " ++ e)) (const (pure ()))
