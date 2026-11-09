-- | Date/time encoders and decoders at their boundaries: rounding past
-- midnight, leap seconds, the first and last representable days, and
-- datetimeoffset UTC/local range crossings.
--
-- The live properties use the server's own conversion of a string literal
-- (@TRY_CONVERT(type(s), '...')@) as the ground truth: the client must round,
-- carry and clamp exactly as the server does when it converts a more precise
-- value to the parameter's type, and must reject exactly the values the server
-- finds out of range.
module Types.TimeBoundarySpec (spec) where

import Wire.PrimitiveGet (getDateTime4, getDateTime8, getDate, getTime, getDateTime2, getDateTimeOffset)
import Control.Exception (try)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int16)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Text.Printf (printf)

import Hmssql
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Primitives
import LiveProperty (liveHedgehog)
import TestDb

------------------------------------------------------------------------------
-- Pure helpers

runEnc :: Either String Put.Put -> Either String B.ByteString
runEnc = fmap (LB.toStrict . Put.runPut)

decodeWith :: Get.Get a -> B.ByteString -> a
decodeWith g = Get.runGet g . LB.fromStrict

-- | Encode then decode.
viaWire :: (a -> Either String Put.Put) -> Get.Get b -> a -> Either String b
viaWire put get a = decodeWith get <$> runEnc (put a)

-- | The error message of a 'Left' (or "" for a 'Right', failing the test's
-- message check).
leftMsg :: Either String a -> String
leftMsg = either id (const "")

-- | @n@ little-endian bytes.
le :: Int -> Integer -> [Word8]
le n v = [ fromIntegral (v `div` (256 ^ i) `mod` 256) | i <- [0 .. n - 1] ]

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

ps :: Integer -> DiffTime
ps = picosecondsToDiffTime

-- | 23:59:59 followed by @s@ nines.
lastTimeAt :: Scale -> TimeOfDay
lastTimeAt s = timeToTimeOfDay (86400 - ps (10 ^ (12 - fromIntegral s :: Int)))

-- | Just before midnight, below every scale's resolution.
almostMidnight :: TimeOfDay
almostMidnight = timeToTimeOfDay (86400 - ps 1)

day :: Integer -> Int -> Int -> Day
day = fromGregorian

at :: Day -> TimeOfDay -> LocalTime
at = LocalTime

scales :: [Scale]
scales = [0 .. 7]

------------------------------------------------------------------------------
-- String literals for the server's ground truth

-- | @yyyy-mm-dd hh:mm:ss.fff...@ with @digits@ fractional digits (truncating).
fmtLocal :: Int -> LocalTime -> Text
fmtLocal digits (LocalTime d tod) =
  let (y, m, dd) = toGregorian d
      TimeOfDay h mi s = tod
      totalPs = diffTimeToPicoseconds (realToFrac s)
      whole = totalPs `div` 1_000_000_000_000
      frac = (totalPs `mod` 1_000_000_000_000) `div` (10 ^ (12 - digits))
   in T.pack $ printf "%04d-%02d-%02d %02d:%02d:%02d.%0*d" y m dd h mi whole digits frac

fmtTime :: Int -> TimeOfDay -> Text
fmtTime digits tod = T.drop 11 (fmtLocal digits (LocalTime (day 2000 1 1) tod))

fmtOffset :: Int16 -> Text
fmtOffset mins =
  let (h, m) = abs mins `divMod` 60
   in T.pack $ printf "%c%02d:%02d" (if mins < 0 then '-' else '+') h m

------------------------------------------------------------------------------
-- Generators

-- | A count of @10^-digits@ second units within a day, biased toward midnight
-- and toward rounding ties at every scale.
genUnits :: Int -> Gen Integer
genUnits digits = do
  let perSec = 10 ^ digits
      perDay = 86400 * perSec
  Gen.frequency
    [ (3, Gen.integral (Range.constant 0 (perDay - 1)))
    , (2, (perDay -) <$> Gen.integral (Range.exponential 1 (2 * perSec)))
    , (1, Gen.integral (Range.exponential 0 (2 * perSec)))
    , (2, do
        sec <- Gen.integral (Range.constant 0 86399)
        s <- Gen.int (Range.constant 0 (digits - 1))
        delta <- Gen.integral (Range.constant (-1) 1)
        let v = sec * perSec + 5 * 10 ^ (digits - 1 - s) + delta
        pure (max 0 (min (perDay - 1) v)))
    ]

genTime :: Int -> Gen TimeOfDay
genTime digits = do
  u <- genUnits digits
  pure $ timeToTimeOfDay (ps (u * 10 ^ (12 - digits)))

edgeDays :: [Day]
edgeDays =
  [ day 1 1 1, day 1 1 2, day 9999 12 30, day 9999 12 31, day 1999 12 31, day 2000 2 28
  , day 2000 2 29, day 1753 1 1, day 1752 12 31, day 1900 1 1, day 1899 12 31
  , day 2079 6 6, day 2079 6 7, day 1970 1 1, day 1969 12 31 ]

genDay :: Gen Day
genDay = Gen.frequency
  [ (3, ModifiedJulianDay <$> Gen.integral (Range.constant (toModifiedJulianDay (day 1 1 1)) (toModifiedJulianDay (day 9999 12 31))))
  , (2, Gen.element edgeDays)
  ]

genLocal :: Int -> Gen LocalTime
genLocal digits = LocalTime <$> genDay <*> genTime digits

-- | A local time for a @smalldatetime@, half the time on a day within its
-- range (1900-01-01 through 2079-06-06).  'genLocal' alone lands there under
-- a fifth of the time, too rarely for the in-range coverage to be reliable.
genSmallLocal :: Int -> Gen LocalTime
genSmallLocal digits = Gen.frequency
  [ (1, genLocal digits)
  , (1, LocalTime <$> inRange <*> genTime digits)
  ]
  where
    inRange = ModifiedJulianDay <$> Gen.integral
      (Range.constant (toModifiedJulianDay (day 1900 1 1)) (toModifiedJulianDay (day 2079 6 6)))

-- | A local time and offset for a @datetimeoffset@, half the time within a
-- few seconds of where the UTC time leaves the range (0001-01-01 local with
-- a positive offset, 9999-12-31 local with a negative one).  Those draws are
-- nearly all of the out-of-range cases, so they need the weight.
genDtoLocal :: Int -> Gen (LocalTime, Int16)
genDtoLocal digits = do
  off <- genOffset
  Gen.frequency
    [ (1, (\l -> (l, off)) <$> genLocal digits)
    , (1, do
        let perSec = 10 ^ digits
        delta <- Gen.integral (Range.constant (-2 * perSec) (2 * perSec))
        let (d, edgeUnits)
              | off >= 0 = (day 1 1 1, toInteger off * 60 * perSec)
              | otherwise = (day 9999 12 31, (86400 + toInteger off * 60) * perSec)
            u = max 0 (min (86400 * perSec - 1) (edgeUnits + delta))
        pure (LocalTime d (timeToTimeOfDay (ps (u * 10 ^ (12 - digits)))), off))
    ]

genOffset :: Gen Int16
genOffset = Gen.frequency
  [ (1, Gen.element [-840, 840, 0, -1, 1, 330, -570])
  , (2, Gen.integral (Range.constant (-840) 840))
  ]

genScaleG :: Gen Scale
genScaleG = Gen.word8 (Range.constant 0 7)

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "encoders (pure)" pureSpec
  describe "decoders (pure)" decoderSpec
  around withTestDb $ do
    describe "server round trips at the boundaries" liveEdgeSpec
    describe "properties against the server's CONVERT" livePropertySpec

pureSpec :: Spec
pureSpec = do
  describe "time" $ do
    it "clamps a value that rounds to midnight to the last unit of the day, at every scale" $
      [ viaWire (putTime s) (getTime s) almostMidnight | s <- scales ]
        `shouldBe` [ Right (lastTimeAt s) | s <- scales ]
    it "clamps leap seconds to the last unit of the day" $ do
      [ viaWire (putTime s) (getTime s) (TimeOfDay 23 59 60) | s <- scales ]
        `shouldBe` [ Right (lastTimeAt s) | s <- scales ]
      viaWire (putTime 7) (getTime 7) (TimeOfDay 23 59 60.9999999999)
        `shouldBe` Right (lastTimeAt 7)
    it "rounds half up elsewhere" $ do
      viaWire (putTime 0) (getTime 0) (TimeOfDay 12 0 0.5) `shouldBe` Right (TimeOfDay 12 0 1)
      viaWire (putTime 0) (getTime 0) (TimeOfDay 12 0 0.4999999999) `shouldBe` Right (TimeOfDay 12 0 0)
      viaWire (putTime 0) (getTime 0) (TimeOfDay 23 59 59.4) `shouldBe` Right (TimeOfDay 23 59 59)
      viaWire (putTime 3) (getTime 3) (TimeOfDay 23 59 59.9985) `shouldBe` Right (TimeOfDay 23 59 59.999)
      viaWire (putTime 7) (getTime 7) (TimeOfDay 0 0 0.00000005) `shouldBe` Right (TimeOfDay 0 0 0.0000001)
    it "treats second 60 of another minute as the next minute" $
      viaWire (putTime 1) (getTime 1) (TimeOfDay 12 30 60.5) `shouldBe` Right (TimeOfDay 12 31 0.5)
    it "rejects invalid times of day" $
      map (isLeft . putTime 7) [TimeOfDay 24 0 0, TimeOfDay 0 60 0, TimeOfDay 0 0 61, TimeOfDay (-1) 0 0, TimeOfDay 0 0 (-1)]
        `shouldBe` replicate 5 True
    it "is within half a unit of the input, or clamped" $ hedgehog $ do
      s <- forAll genScaleG
      u <- forAll $ Gen.integral (Range.constant 0 (86401 * 10 ^ (12 :: Int) - 1))
      let tod = timeToTimeOfDay (ps u)
          half = 10 ^ (12 - fromIntegral s :: Int) `div` 2
      Right tod' <- pure $ viaWire (putTime s) (getTime s) tod
      let u' = diffTimeToPicoseconds (timeOfDayToTime tod')
      if u' == diffTimeToPicoseconds (timeOfDayToTime (lastTimeAt s))
        then assert (u >= u' - half)
        else assert (abs (u' - u) <= half)

  describe "datetime2" $ do
    it "carries a value that rounds to midnight into the next day, at every scale" $
      [ viaWire (putDateTime2 s) (getDateTime2 s) (at (day 1999 12 31) almostMidnight) | s <- scales ]
        `shouldBe` replicate 8 (Right (at (day 2000 1 1) midnight))
    it "carries leap seconds into the next day" $ do
      viaWire (putDateTime2 7) (getDateTime2 7) (at (day 2016 12 31) (TimeOfDay 23 59 60.5))
        `shouldBe` Right (at (day 2017 1 1) (TimeOfDay 0 0 0.5))
      viaWire (putDateTime2 0) (getDateTime2 0) (at (day 2016 12 31) (TimeOfDay 23 59 60))
        `shouldBe` Right (at (day 2017 1 1) midnight)
    it "clamps a value that rounds past 9999-12-31 to the maximum, at every scale" $ do
      [ viaWire (putDateTime2 s) (getDateTime2 s) (at (day 9999 12 31) almostMidnight) | s <- scales ]
        `shouldBe` [ Right (at (day 9999 12 31) (lastTimeAt s)) | s <- scales ]
      viaWire (putDateTime2 7) (getDateTime2 7) (at (day 9999 12 31) (TimeOfDay 23 59 60.5))
        `shouldBe` Right (at (day 9999 12 31) (lastTimeAt 7))
    it "accepts the first and last days" $ do
      viaWire (putDateTime2 7) (getDateTime2 7) (at (day 1 1 1) midnight) `shouldBe` Right (at (day 1 1 1) midnight)
      viaWire (putDateTime2 7) (getDateTime2 7) (at (day 9999 12 31) (lastTimeAt 7)) `shouldBe` Right (at (day 9999 12 31) (lastTimeAt 7))
    it "rejects days outside 0001-01-01 through 9999-12-31 with a clear message" $ do
      let msg = leftMsg $ putDateTime2 7 (at (day 10000 1 1) midnight)
      msg `shouldSatisfy` ("out of range" `isInfixOf`)
      msg `shouldSatisfy` ("datetime2" `isInfixOf`)
      isLeft (putDateTime2 7 (at (day 0 12 31) (TimeOfDay 23 59 59))) `shouldBe` True
      isLeft (putDateTime2 0 (at (day (-5) 1 1) midnight)) `shouldBe` True
    it "carries a pre-0001 leap second into 0001-01-01" $
      viaWire (putDateTime2 7) (getDateTime2 7) (at (day 0 12 31) (TimeOfDay 23 59 60.5))
        `shouldBe` Right (at (day 1 1 1) (TimeOfDay 0 0 0.5))

  describe "date" $ do
    it "accepts the first and last days" $ do
      viaWire putDate getDate (day 1 1 1) `shouldBe` Right (day 1 1 1)
      viaWire putDate getDate (day 9999 12 31) `shouldBe` Right (day 9999 12 31)
    it "rejects days out of range" $ do
      isLeft (putDate (day 10000 1 1)) `shouldBe` True
      isLeft (putDate (day 0 12 31)) `shouldBe` True
      isLeft (putDate (day (-44) 3 15)) `shouldBe` True

  describe "datetimeoffset" $ do
    let dto d t off = DateTimeOffset (UTCTime d (timeOfDayToTime t)) off
        rt s = viaWire (putDateTimeOffset s) (getDateTimeOffset s)
    it "accepts offsets of exactly ±14:00 and rejects larger ones" $ do
      rt 7 (dto (day 2000 1 1) midnight 840) `shouldBe` Right (dto (day 2000 1 1) midnight 840)
      rt 7 (dto (day 2000 1 1) midnight (-840)) `shouldBe` Right (dto (day 2000 1 1) midnight (-840))
      let msg = leftMsg $ putDateTimeOffset 7 (dto (day 2000 1 1) midnight 841)
      msg `shouldSatisfy` ("14:00" `isInfixOf`)
      isLeft (putDateTimeOffset 7 (dto (day 2000 1 1) midnight (-841))) `shouldBe` True
    it "carries the UTC time across a year boundary" $
      [ rt s (dto (day 1999 12 31) almostMidnight 60) | s <- scales ]
        `shouldBe` replicate 8 (Right (dto (day 2000 1 1) midnight 60))
    it "accepts UTC 0001-01-01 00:00 with a positive offset and UTC 9999-12-31 with a negative one" $ do
      rt 7 (dto (day 1 1 1) midnight 840) `shouldBe` Right (dto (day 1 1 1) midnight 840)
      rt 7 (dto (day 9999 12 31) (lastTimeAt 7) (-840)) `shouldBe` Right (dto (day 9999 12 31) (lastTimeAt 7) (-840))
    it "rejects a local time before 0001-01-01 or after 9999-12-31" $ do
      let msg = leftMsg $ putDateTimeOffset 7 (dto (day 1 1 1) (TimeOfDay 13 59 0) (-840))
      msg `shouldSatisfy` ("out of range" `isInfixOf`)
      isLeft (putDateTimeOffset 7 (dto (day 1 1 1) midnight (-1))) `shouldBe` True
      isLeft (putDateTimeOffset 7 (dto (day 9999 12 31) (TimeOfDay 10 0 0) 840)) `shouldBe` True
      isLeft (putDateTimeOffset 7 (dto (day 9999 12 31) (TimeOfDay 23 59 0) 1)) `shouldBe` True
    it "rejects a UTC time out of range" $ do
      isLeft (putDateTimeOffset 7 (dto (day 0 12 31) (TimeOfDay 23 0 0) 840)) `shouldBe` True
      isLeft (putDateTimeOffset 7 (dto (day 10000 1 1) (TimeOfDay 1 0 0) (-840))) `shouldBe` True
    it "clamps when the local time rounds past 9999-12-31" $
      [ rt s (dto (day 9999 12 31) (timeToTimeOfDay (36000 - ps 1)) 840) | s <- scales ]
        `shouldBe` [ Right (dto (day 9999 12 31) (timeToTimeOfDay (36000 - ps (10 ^ (12 - fromIntegral s :: Int)))) 840) | s <- scales ]
    it "clamps when the UTC time rounds past 9999-12-31" $
      rt 0 (dto (day 9999 12 31) almostMidnight (-60)) `shouldBe` Right (dto (day 9999 12 31) (lastTimeAt 0) (-60))
    it "carries a UTC leap second into the next day" $
      viaWire (putDateTimeOffset 7) (getDateTimeOffset 7) (DateTimeOffset (UTCTime (day 2016 12 31) 86400.25) 0)
        `shouldBe` Right (dto (day 2017 1 1) (TimeOfDay 0 0 0.25) 0)
    it "rejects an invalid UTC day time" $ do
      isLeft (putDateTimeOffset 7 (DateTimeOffset (UTCTime (day 2000 1 1) 86401) 0)) `shouldBe` True
      isLeft (putDateTimeOffset 7 (DateTimeOffset (UTCTime (day 2000 1 1) (-1)) 0)) `shouldBe` True

  describe "datetime" $ do
    let rt = viaWire putDateTime8 getDateTime8
        tick n = timeToTimeOfDay (ps (n * 1_000_000_000_000 `div` 300))
    it "carries a value that rounds to midnight into the next day" $
      rt (at (day 2000 1 1) (TimeOfDay 23 59 59.999)) `shouldBe` Right (at (day 2000 1 2) midnight)
    it "rounds to the nearest 1/300 s" $ do
      rt (at (day 2000 1 1) (TimeOfDay 12 0 0.0016666)) `shouldBe` Right (at (day 2000 1 1) (TimeOfDay 12 0 0))
      rt (at (day 2000 1 1) (TimeOfDay 12 0 0.0016667)) `shouldBe` Right (at (day 2000 1 1) (TimeOfDay 12 0 0 `addTicks` 1))
    it "clamps a value that rounds past 9999-12-31 23:59:59.997" $ do
      rt (at (day 9999 12 31) (TimeOfDay 23 59 59.999)) `shouldBe` Right (at (day 9999 12 31) (tick (300 * 86400 - 1)))
      rt (at (day 9999 12 31) (TimeOfDay 23 59 60)) `shouldBe` Right (at (day 9999 12 31) (tick (300 * 86400 - 1)))
    it "accepts 1753-01-01, including values that round up to it" $ do
      rt (at (day 1753 1 1) midnight) `shouldBe` Right (at (day 1753 1 1) midnight)
      rt (at (day 1752 12 31) (TimeOfDay 23 59 59.999)) `shouldBe` Right (at (day 1753 1 1) midnight)
    it "accepts days before 1900 (negative day counts)" $
      rt (at (day 1800 7 4) (TimeOfDay 12 34 56)) `shouldBe` Right (at (day 1800 7 4) (TimeOfDay 12 34 56))
    it "rejects values out of range" $ do
      isLeft (putDateTime8 (at (day 1752 12 31) (TimeOfDay 12 0 0))) `shouldBe` True
      isLeft (putDateTime8 (at (day 10000 1 1) midnight)) `shouldBe` True
      isLeft (putDateTime8 (at (day 1 1 1) midnight)) `shouldBe` True

  describe "smalldatetime" $ do
    let rt = viaWire putDateTime4 getDateTime4
    it "rounds to the nearest minute, half up, carrying into the next day" $ do
      rt (at (day 2000 1 1) (TimeOfDay 23 59 30)) `shouldBe` Right (at (day 2000 1 2) midnight)
      rt (at (day 2000 1 1) (TimeOfDay 23 59 29.9999999)) `shouldBe` Right (at (day 2000 1 1) (TimeOfDay 23 59 0))
      rt (at (day 2000 1 1) (TimeOfDay 12 0 45)) `shouldBe` Right (at (day 2000 1 1) (TimeOfDay 12 1 0))
    it "clamps a value that rounds past 2079-06-06 23:59" $
      rt (at (day 2079 6 6) (TimeOfDay 23 59 45)) `shouldBe` Right (at (day 2079 6 6) (TimeOfDay 23 59 0))
    it "accepts 1900-01-01, including values that round up to it" $ do
      rt (at (day 1900 1 1) midnight) `shouldBe` Right (at (day 1900 1 1) midnight)
      rt (at (day 1899 12 31) (TimeOfDay 23 59 45)) `shouldBe` Right (at (day 1900 1 1) midnight)
    it "rejects values out of range" $ do
      isLeft (putDateTime4 (at (day 1899 12 31) (TimeOfDay 23 59 0))) `shouldBe` True
      isLeft (putDateTime4 (at (day 2079 6 7) midnight)) `shouldBe` True
      isLeft (putDateTime4 (at (day 2100 1 1) midnight)) `shouldBe` True
  where
    addTicks tod n = timeToTimeOfDay (timeOfDayToTime tod + ps (n * 1_000_000_000_000 `div` 300))

decoderSpec :: Spec
decoderSpec = do
  let parse g bytes = either (\(_, _, e) -> Left e) (\(_, _, a) -> Right a) (Get.runGetOrFail g (LB.pack bytes))
  it "rejects a time of 24:00:00 or more at every scale" $
    [ isLeft (parse (getTime s) (le (timeLength s) (86400 * 10 ^ s))) | s <- scales ]
      `shouldBe` replicate 8 True
  it "decodes the last unit of the day at every scale" $
    [ parse (getTime s) (le (timeLength s) (86400 * 10 ^ s - 1)) | s <- scales ]
      `shouldBe` [ Right (lastTimeAt s) | s <- scales ]
  it "rejects a date past 9999-12-31" $ do
    parse getDate (le 3 (3652058)) `shouldBe` Right (day 9999 12 31)
    isLeft (parse getDate (le 3 (3652059))) `shouldBe` True
  it "rejects a datetime tick count of a whole day" $ do
    isLeft (parse getDateTime8 (le 4 (0) ++ le 4 (25920000))) `shouldBe` True
    parse getDateTime8 (le 4 (0) ++ le 4 (25919999)) `shouldSatisfy` (not . isLeft)
  it "rejects a smalldatetime minute count of a whole day" $
    isLeft (parse getDateTime4 (le 2 (0) ++ le 2 (1440))) `shouldBe` True

------------------------------------------------------------------------------
-- Live

rawParam :: TypeInfo -> Either String Put.Put -> Either String RawParam
rawParam ti enc = (\bs -> RawParam (ti, Just bs)) <$> runEnc enc

sqlScale :: Scale -> Text
sqlScale = T.pack . show

encodeFails :: IO a -> IO String
encodeFails act = try act >>= \case
  Left (EncodeError msg) -> pure msg
  Right _ -> expectationFailure "expected an EncodeError" >> pure ""

liveEdgeSpec :: SpecWith Connection
liveEdgeSpec = do
  it "the server rejects a wire time of 24:00:00 (why the encoder clamps)" $ \conn -> do
    let bytes = B.pack (le 5 864_000_000_000)  -- 24:00:00 at scale 7
    r <- try (query1 conn (mkQuery "SELECT @p1" (Only (RawParam (TITimeN 7, Just bytes)))) :: IO (Only TimeOfDay))
    either (\(_ :: SqlServerError) -> pure ()) (\v -> expectationFailure ("accepted: " ++ show v)) r

  it "sends TimeOfDay values that round to midnight" $ \conn -> do
    query1 conn ("SELECT " <> param almostMidnight) `shouldReturn` Only (lastTimeAt 7)
    query1 conn ("SELECT " <> param (TimeOfDay 23 59 59.99999999)) `shouldReturn` Only (lastTimeAt 7)
    query1 conn ("SELECT " <> param (TimeOfDay 23 59 60)) `shouldReturn` Only (lastTimeAt 7)
    query1 conn ("SELECT " <> param (TimeOfDay 23 59 60.5)) `shouldReturn` Only (lastTimeAt 7)

  it "sends LocalTime and UTCTime values that round to midnight into the next day" $ \conn -> do
    query1 conn (mkQuery "SELECT @p1" (Only (at (day 2000 1 1) (TimeOfDay 23 59 59.99999999))))
      `shouldReturn` Only (at (day 2000 1 2) midnight)
    query1 conn (mkQuery "SELECT @p1" (Only (UTCTime (day 1999 12 31) (86400 - ps 1))))
      `shouldReturn` Only (UTCTime (day 2000 1 1) 0)
    query1 conn (mkQuery "SELECT @p1" (Only (UTCTime (day 2016 12 31) 86400.5)))
      `shouldReturn` Only (at (day 2017 1 1) (TimeOfDay 0 0 0.5))
    query1 conn (mkQuery "SELECT @p1" (Only (at (day 2016 12 31) (TimeOfDay 23 59 60))))
      `shouldReturn` Only (at (day 2017 1 1) midnight)

  it "sends and decodes the extremes of datetime2" $ \conn -> do
    let lo = at (day 1 1 1) midnight
        hi = at (day 9999 12 31) (lastTimeAt 7)
    query1 conn (mkQuery "SELECT @p1, @p2, CAST('0001-01-01' AS datetime2), CAST('9999-12-31 23:59:59.9999999' AS datetime2)" (lo, hi))
      `shouldReturn` (lo, hi, lo, hi)
    query1 conn ("SELECT " <> param (at (day 9999 12 31) almostMidnight)) `shouldReturn` Only hi
    query1 conn (mkQuery "SELECT @p1" (Only (UTCTime (day 9999 12 31) 86400.5))) `shouldReturn` Only hi

  it "rejects datetime2, date and datetimeoffset values out of range with an EncodeError" $ \conn -> do
    m1 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only (at (day 10000 1 1) midnight))) :: IO (Only LocalTime))
    m1 `shouldSatisfy` ("out of range" `isInfixOf`)
    m2 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only (day 0 12 31))) :: IO (Only Day))
    m2 `shouldSatisfy` ("out of range" `isInfixOf`)
    m3 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only (UTCTime (day (-100) 1 1) 0))) :: IO (Only UTCTime))
    m3 `shouldSatisfy` ("out of range" `isInfixOf`)
    let zt = ZonedTime (at (day 1 1 1) (TimeOfDay 1 0 0)) (minutesToTimeZone 120)
    m4 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only zt)) :: IO (Only DateTimeOffset))
    m4 `shouldSatisfy` ("out of range" `isInfixOf`)
    let zt2 = ZonedTime (at (day 2000 1 1) midnight) (minutesToTimeZone 900)
    m5 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only zt2)) :: IO (Only DateTimeOffset))
    m5 `shouldSatisfy` ("14:00" `isInfixOf`)
    m6 <- encodeFails (query1 conn (mkQuery "SELECT @p1" (Only (TimeOfDay 24 0 0))) :: IO (Only TimeOfDay))
    m6 `shouldSatisfy` ("invalid time of day" `isInfixOf`)

  it "sends and decodes the extremes of date" $ \conn ->
    query1 conn (mkQuery "SELECT @p1, @p2, CAST('0001-01-01' AS date), CAST('9999-12-31' AS date)" (day 1 1 1, day 9999 12 31))
      `shouldReturn` (day 1 1 1, day 9999 12 31, day 1 1 1, day 9999 12 31)

  it "sends and decodes datetimeoffset at ±14:00 and at the UTC extremes" $ \conn -> do
    let lo = ZonedTime (at (day 1 1 1) (TimeOfDay 14 0 0)) (minutesToTimeZone 840)
        hi = ZonedTime (at (day 9999 12 31) (timeToTimeOfDay (36000 - ps 100_000))) (minutesToTimeZone (-840))
    (a, b, c, d) <- query1 conn $ mkQuery
      "SELECT @p1, @p2, CAST('0001-01-01 14:00:00 +14:00' AS datetimeoffset), CAST('9999-12-31 09:59:59.9999999 -14:00' AS datetimeoffset)"
      (lo, hi)
    map zonedTimeToDateTimeOffset [a, b, c, d]
      `shouldBe` map zonedTimeToDateTimeOffset [lo, hi, lo, hi]
    map zonedTimeToLocalTime [a, b] `shouldBe` map zonedTimeToLocalTime [lo, hi]
    (u1, u2) <- query1 conn (mkQuery "SELECT @p1, @p2" (lo, hi))
    (u1, u2) `shouldBe` (UTCTime (day 1 1 1) 0, UTCTime (day 9999 12 31) (86400 - ps 100_000))
    -- the local time rounds past 9999-12-31: clamped, like the server's CONVERT
    let near = ZonedTime (at (day 9999 12 31) almostMidnight) (minutesToTimeZone 840)
    Only r <- query1 conn ("SELECT " <> param near)
    zonedTimeToLocalTime r `shouldBe` at (day 9999 12 31) (lastTimeAt 7)

  it "decodes time at every scale up to the last unit of the day" $ \conn -> do
    rs <- mapM (\s -> query1 conn (rawSql ("SELECT CAST('23:59:59.9999999' AS time(" <> sqlScale s <> "))"))) scales
    rs `shouldBe` [ Only (lastTimeAt s) | s <- scales ]

  it "decodes datetime and smalldatetime at their extremes" $ \conn -> do
    r <- query1 conn
      "SELECT CAST('1753-01-01' AS datetime), CAST('9999-12-31 23:59:59.997' AS datetime), \
      \CAST('1900-01-01' AS smalldatetime), CAST('2079-06-06 23:59' AS smalldatetime)"
    r `shouldBe`
      ( at (day 1753 1 1) midnight
      , at (day 9999 12 31) (timeToTimeOfDay (ps ((300 * 86400 - 1) * 1_000_000_000_000 `div` 300)))
      , at (day 1900 1 1) midnight
      , at (day 2079 6 6) (TimeOfDay 23 59 0) )

livePropertySpec :: SpecWith Connection
livePropertySpec = do
  -- 400 cases, so the carry (about 5% of them) reliably reaches its 3%.
  withCases 400 $
   it "datetime2(s) parameters match CONVERT(datetime2(s), literal)" $ \conn -> liveHedgehog $ do
    s <- forAll genScaleG
    lt <- forAll (genLocal 8)
    Right p <- pure $ rawParam (TIDateTime2N s) (putDateTime2 s lt)
    (echo :: LocalTime, truth, echo7 :: LocalTime, truth7) <- evalIO $ query1 conn $ mkQuery
      ("SELECT @p1, TRY_CONVERT(datetime2(" <> sqlScale s <> "), @p2), @p3, TRY_CONVERT(datetime2(7), @p2)")
      (p, fmtLocal 8 lt, lt)
    cover 3 "carried into the next day" (localDay echo > localDay lt)
    classify "clamped at the maximum" (echo < lt)
    Just echo === truth
    Just echo7 === truth7

  it "time(s) parameters match CONVERT(time(s), literal)" $ \conn -> liveHedgehog $ do
    s <- forAll genScaleG
    tod <- forAll (genTime 8)
    Right p <- pure $ rawParam (TITimeN s) (putTime s tod)
    (echo :: TimeOfDay, truth, echo7 :: TimeOfDay, truth7) <- evalIO $ query1 conn $ mkQuery
      ("SELECT @p1, TRY_CONVERT(time(" <> sqlScale s <> "), @p2), @p3, TRY_CONVERT(time(7), @p2)")
      (p, fmtTime 8 tod, tod)
    cover 2 "clamped to the end of the day" (echo < tod)
    Just echo === truth
    Just echo7 === truth7

  it "datetimeoffset(s) parameters match CONVERT(datetimeoffset(s), literal), including range errors" $ \conn -> liveHedgehog $ do
    s <- forAll genScaleG
    (local, off) <- forAll (genDtoLocal 8)
    let dto = DateTimeOffset (localTimeToUTC (minutesToTimeZone (fromIntegral off)) local) off
        lit = fmtLocal 8 local <> " " <> fmtOffset off
        ty = "datetimeoffset(" <> sqlScale s <> ")"
    annotate (T.unpack lit)
    let enc = rawParam (TIDateTimeOffsetN s) (putDateTimeOffset s dto)
    cover 5 "out of range" (isLeft enc)
    cover 50 "in range" (not (isLeft enc))
    case enc of
      Left err -> do
        annotate err
        Only truth <- evalIO $ query1 conn (mkQuery ("SELECT TRY_CONVERT(" <> ty <> ", @p1)") (Only lit))
        truth === (Nothing :: Maybe DateTimeOffset)
      Right p -> do
        (echo :: DateTimeOffset, truth) <- evalIO $ query1 conn $ mkQuery
          ("SELECT @p1, TRY_CONVERT(" <> ty <> ", @p2)") (p, lit)
        Just echo === truth
    -- The ToSqlField instance (scale 7).  It can reject a value that a lower
    -- scale accepts: the range is checked after rounding, as the server does
    -- ('0001-01-01 00:00:59.5 +00:01' is valid at scale 0 only).
    r7 <- evalIO $ try $ query1 conn (mkQuery "SELECT @p1, TRY_CONVERT(datetimeoffset(7), @p2)" (dto, lit))
    case r7 of
      Left (EncodeError err) -> do
        annotate err
        Only truth7 <- evalIO $ query1 conn (mkQuery "SELECT TRY_CONVERT(datetimeoffset(7), @p1)" (Only lit))
        truth7 === (Nothing :: Maybe DateTimeOffset)
      Right (echo7 :: DateTimeOffset, truth7) -> Just echo7 === truth7

  it "datetime parameters match CONVERT(datetime, datetime2 literal), including range errors" $ \conn -> liveHedgehog $ do
    lt <- forAll (genLocal 7)
    Only truth <- evalIO $ query1 conn (mkQuery "SELECT TRY_CONVERT(datetime, TRY_CONVERT(datetime2(7), @p1))" (Only (fmtLocal 7 lt)))
    let enc = rawParam (TIDateTimeN 8) (putDateTime8 lt)
    cover 5 "out of range" (isLeft enc)
    case enc of
      Left err -> annotate err >> truth === (Nothing :: Maybe LocalTime)
      Right p -> do
        Only (echo :: LocalTime) <- evalIO $ query1 conn ("SELECT " <> param p)
        Just echo === truth

  it "smalldatetime parameters match CONVERT(smalldatetime, datetime2 literal), including range errors" $ \conn -> liveHedgehog $ do
    lt <- forAll (genSmallLocal 7)
    Only truth <- evalIO $ query1 conn (mkQuery "SELECT TRY_CONVERT(smalldatetime, TRY_CONVERT(datetime2(7), @p1))" (Only (fmtLocal 7 lt)))
    let lastMinute = at (day 2079 6 6) (TimeOfDay 23 59 0)
    let enc = rawParam (TIDateTimeN 4) (putDateTime4 lt)
    cover 20 "out of range" (isLeft enc)
    cover 20 "in range" (not (isLeft enc))
    case enc of
      Left err -> annotate err >> truth === (Nothing :: Maybe LocalTime)
      Right p -> do
        Only (echo :: LocalTime) <- evalIO $ query1 conn ("SELECT " <> param p)
        if lt >= at (day 2079 6 6) (TimeOfDay 23 59 30) && localDay lt == day 2079 6 6
          -- the server's CONVERT fails here; the encoder clamps (see docs/dev/design.md, "Date and time")
          then (echo, truth) === (lastMinute, Nothing)
          else Just echo === truth
