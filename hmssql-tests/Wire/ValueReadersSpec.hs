{-# LANGUAGE TupleSections #-}
-- | The in-place value readers of "Hmssql.Tds.Primitives" ('readMoney',
-- 'readDate', 'readTime', 'readDateTime2', 'readDateTimeOffset',
-- 'readDateTime4With', 'readDateTime8With', 'readDecimal', 'readGuid') and
-- the field decoders built on them, against the 'Get'-based parsers they
-- replaced (with datetimeoffset's offset and local-date checks added): the same value
-- for every input, the same error for a value of the right length, and an
-- error for a value of any other length.  Each value is read at an offset
-- inside a larger buffer, so a reader that looks outside its value (or
-- ignores the offset) fails, and a read outside the value's buffer is an
-- exception (every read of "Hmssql.Tds.Bytes" is bounds-checked).
module Wire.ValueReadersSpec (spec) where

import Wire.PrimitiveGet (getMoney4, getMoney8, getDateTime4, getDateTime8, getDate, getTime, getDateTime2, getDateTimeOffset, getDecimal)
import Control.Monad (unless, when)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import Data.Bits (shiftL, shiftR, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int16, Int32, Int64, Int8)
import Data.List (isInfixOf)
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Data.Word (Word64, Word8)
import GHC.Float (float2Double)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql.Decoding (FieldDecoder, FromSqlField (..), compileField, decodeCell)
import Hmssql.SqlValue (SqlValue (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo (TypeInfo (..))

------------------------------------------------------------------------------
-- The reference: the Get parsers as they were before the readers

refGetMoney4 :: Get.Get Money
refGetMoney4 = Money . MkFixed . fromIntegral <$> Get.getInt32le

refGetMoney8 :: Get.Get Money
refGetMoney8 = do
  hi <- Get.getInt32le
  lo <- Get.getWord32le
  pure $ Money $ MkFixed $ (fromIntegral hi `shiftL` 32) .|. fromIntegral lo

refEpoch1900, refEpoch0001 :: Day
refEpoch1900 = fromGregorian 1900 1 1
refEpoch0001 = fromGregorian 1 1 1

refGetDateTime4 :: Get.Get LocalTime
refGetDateTime4 = do
  days <- Get.getWord16le
  mins <- Get.getWord16le
  when (mins >= 1440) $ fail $ "smalldatetime: invalid minute count " ++ show mins
  pure $ LocalTime (addDays (fromIntegral days) refEpoch1900) (timeToTimeOfDay $ fromIntegral mins * 60)

refGetDateTime8 :: Get.Get LocalTime
refGetDateTime8 = do
  days <- Get.getInt32le
  ticks <- Get.getWord32le
  when (ticks >= 300 * 86400) $ fail $ "datetime: invalid tick count " ++ show ticks
  let day = addDays (fromIntegral days) refEpoch1900
  when (day < fromGregorian 1753 1 1 || day > fromGregorian 9999 12 31) $
    fail $ "datetime: invalid day count " ++ show days
  let secs = picosecondsToDiffTime (fromIntegral ticks * 1_000_000_000_000 `div` 300)
  pure $ LocalTime day (timeToTimeOfDay secs)

refGetUIntLE :: Int -> Get.Get Word64
refGetUIntLE n = do
  bs <- Get.getByteString n
  pure $ B.foldr' (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 bs

refGetDate :: Get.Get Day
refGetDate = do
  d <- refGetUIntLE 3
  when (toInteger d > diffDays (fromGregorian 9999 12 31) refEpoch0001) $ fail $ "date: invalid day count " ++ show d
  pure $ addDays (fromIntegral d) refEpoch0001

refCheckScale :: String -> Scale -> Get.Get ()
refCheckScale name s = mapM_ fail (scaleProblem name s)

refGetTime :: Scale -> Get.Get TimeOfDay
refGetTime scale = refCheckScale "time" scale >> refGetTimeUnits scale

refGetTimeUnits :: Scale -> Get.Get TimeOfDay
refGetTimeUnits scale = do
  units <- refGetUIntLE (timeLength scale)
  when (toInteger units >= 86400 * 10 ^ scale) $
    fail $ "time: invalid unit count " ++ show units
  let ps = fromIntegral units * (10 ^ (12 - fromIntegral scale :: Int))
  pure $ timeToTimeOfDay $ picosecondsToDiffTime ps

refGetDateTime2 :: Scale -> Get.Get LocalTime
refGetDateTime2 scale = refCheckScale "datetime2" scale >> refGetLocalTime scale

refGetLocalTime :: Scale -> Get.Get LocalTime
refGetLocalTime scale = do
  tod <- refGetTimeUnits scale
  day <- refGetDate
  pure $ LocalTime day tod

refGetDateTimeOffset :: Scale -> Get.Get DateTimeOffset
refGetDateTimeOffset scale = do
  refCheckScale "datetimeoffset" scale
  LocalTime day tod <- refGetLocalTime scale
  mins <- Get.getInt16le
  when (mins < -840 || mins > 840) $
    fail $ "datetimeoffset: invalid offset minute count " ++ show mins
  let utc = UTCTime day (timeOfDayToTime tod)
      local = localDay (utcToLocalTime (minutesToTimeZone (fromIntegral mins)) utc)
  when (local < fromGregorian 1 1 1 || local > fromGregorian 9999 12 31) $
    fail "datetimeoffset: local date outside 0001-01-01 through 9999-12-31"
  pure $ DateTimeOffset utc mins

refGetDecimal :: Word8 -> Scale -> Int -> Get.Get Decimal
refGetDecimal precision scale len = do
  when (len `notElem` [5, 9, 13, 17]) $ fail $
    "decimal: invalid length " ++ show len ++ " (5, 9, 13 or 17 bytes)"
  sign <- Get.getWord8
  when (sign > 1) $ fail $ "decimal: invalid sign byte " ++ show sign
  bs <- Get.getByteString (len - 1)
  let mag = B.foldr' (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 bs :: Integer
  when (mag >= 10 ^ precision) $ fail $
    "decimal: magnitude " ++ show mag ++ " has more than " ++ show precision ++ " digits"
  pure $ Decimal scale (if sign == 0 then negate mag else mag)

refGetGuid :: Get.Get UUID
refGetGuid = do
  d1 <- Get.getWord32le
  d2 <- Get.getWord16le
  d3 <- Get.getWord16le
  rest <- Get.getWord64be
  let hi = (fromIntegral d1 `shiftL` 32) .|. (fromIntegral d2 `shiftL` 16) .|. fromIntegral d3 :: Word64
  pure $ UUID.fromWords64 hi rest

-- | Run a reference parser over all of the bytes, as the old decoders did.
refRun :: Get.Get a -> B.ByteString -> Either String a
refRun g bs = case Get.runGetOrFail g (LB.fromStrict bs) of
  Left (_, _, err) -> Left err
  Right (rest, _, a)
    | LB.null rest -> Right a
    | otherwise -> Left $ show (LB.length rest) ++ " unexpected trailing bytes"

-- | Whether a decoder failed because the value had the wrong length: the
-- reference and the readers may then fail differently (the reference
-- checked some fields before it ran out of bytes; the readers check the
-- length first and say so in their own words).
lengthFailure :: String -> Bool
lengthFailure e = any (`isInfixOf` e) ["not enough bytes", "unexpected trailing bytes", "length "]

------------------------------------------------------------------------------
-- Comparing

-- | The value inside a buffer, after a prefix and before a suffix of random
-- bytes: the reader's buffer, offset and length.
embedded :: B.ByteString -> Gen (B.ByteString, Int, Int)
embedded v = do
  pre <- Gen.bytes (Range.linear 0 9)
  post <- Gen.bytes (Range.linear 0 9)
  pure (pre <> v <> post, B.length pre, B.length v)

-- | The reader agrees with the reference on these bytes.
agrees :: (Eq a, Show a) => Get.Get a -> ValueReader a -> B.ByteString -> PropertyT IO ()
agrees ref new v = do
  (buf, off, len) <- forAll (embedded v)
  -- A copy of exactly the value too: a reader may not rely on bytes after it.
  let exact = B.copy v
  sameOutcome (refRun ref v) (new (B.take len (B.drop off buf)))
  sameOutcome (refRun ref v) (new exact)

sameOutcome :: (Eq a, Show a) => Either String a -> Either String a -> PropertyT IO ()
sameOutcome expected actual = case (expected, actual) of
  (Right a, Right b) -> do
    a === b
    -- Evaluated and equal all the way down, as 'show' sees it.
    show a === show b
  (Left e, Left e') -> unless (lengthFailure e || lengthFailure e') (e === e')
  _ -> do
    annotateShow expected
    annotateShow actual
    failure

-- | Little-endian bytes of @n@ bytes of an integer.
le :: Int -> Integer -> B.ByteString
le n x = B.pack [fromIntegral (x `shiftR` (8 * i)) | i <- [0 .. n - 1]]

-- | An integer near one of the boundaries, or anywhere in @[0, 2^(8n))@.
nearAny :: Int -> [Integer] -> Gen Integer
nearAny n bounds = Gen.frequency
  [ (3, do b <- Gen.element bounds; d <- Gen.integral (Range.linearFrom 0 (-3) 3); pure ((b + d) `mod` (2 ^ (8 * n))))
  , (2, Gen.integral (Range.constant 0 (2 ^ (8 * n) - 1)))
  ]

-- | A length: usually the given one, sometimes another (shorter or longer).
lengthNear :: Int -> Gen Int
lengthNear n = Gen.frequency [(8, pure n), (1, Gen.int (Range.constant 0 (n + 3)))]

-- | Bytes of the given length, from the value's bytes padded or cut.
resized :: Int -> B.ByteString -> Gen B.ByteString
resized n v
  | n <= B.length v = pure (B.take n v)
  | otherwise = (v <>) <$> Gen.bytes (Range.singleton (n - B.length v))

scales :: Gen Scale
scales = Gen.frequency [(10, Gen.word8 (Range.constant 0 7)), (1, Gen.element [8, 12, 13, 255])]

-- | Time units at a scale, near the boundaries.
timeBytes :: Scale -> Gen B.ByteString
timeBytes s = do
  let n = timeLength s
      perDay = 86400 * 10 ^ min 7 s
  u <- nearAny n [0, perDay - 1, perDay, perDay + 1, 2 ^ (8 * n) - 1]
  pure (le n u)

dateBytes :: Gen B.ByteString
dateBytes = le 3 <$> nearAny 3 [0, 3652058, 3652059, 2 ^ (24 :: Int) - 1, 738000]

------------------------------------------------------------------------------
-- Field decoders

col :: TypeInfo -> ColumnInfo
col ti = ColumnInfo "c" ti 0 0 Nothing

decodeAs :: FieldDecoder a -> TypeInfo -> B.ByteString -> Either String a
decodeAs fd ti bs = compileField fd defaultTdsContext (col ti) >>= \dec -> decodeCell dec (Just bs)

-- | The old integer decoding: tinyint unsigned, otherwise signed by length.
refInteger :: TypeInfo -> B.ByteString -> Either String Integer
refInteger ti bs = case ti of
  TIInt1 -> fromIntegral <$> refRun Get.getWord8 bs
  TIIntN 1 -> fromIntegral <$> refRun Get.getWord8 bs
  _ -> case B.length bs of
    1 -> fromIntegral <$> refRun Get.getInt8 bs
    2 -> fromIntegral <$> refRun Get.getInt16le bs
    4 -> fromIntegral <$> refRun Get.getInt32le bs
    8 -> fromIntegral <$> refRun Get.getInt64le bs
    n -> Left $ "invalid integer length " ++ show n

refBounded :: forall a. (Integral a, Bounded a) => String -> TypeInfo -> B.ByteString -> Either String a
refBounded name ti bs = do
  i <- refInteger ti bs
  if i < toInteger (minBound @a) || i > toInteger (maxBound @a)
    then Left $ "value " ++ show i ++ " is out of range for " ++ name
    else Right (fromInteger i)

refLocalTime :: TypeInfo -> B.ByteString -> Either String LocalTime
refLocalTime ti bs = case ti of
  TIDateTime4 -> refRun refGetDateTime4 bs
  TIDateTime8 -> refRun refGetDateTime8 bs
  TIDateTimeN _ -> case B.length bs of
    4 -> refRun refGetDateTime4 bs
    8 -> refRun refGetDateTime8 bs
    n -> Left $ "invalid datetime length " ++ show n
  TIDateTime2N s -> refRun (refGetDateTime2 s) bs
  TIDateN -> (`LocalTime` midnight) <$> refRun refGetDate bs
  _ -> Left "not a datetime type"

refDecimal :: TypeInfo -> B.ByteString -> Either String Decimal
refDecimal ti bs = case ti of
  TIDecimalN p s -> refRun (refGetDecimal p s (B.length bs)) bs
  TINumericN p s -> refRun (refGetDecimal p s (B.length bs)) bs
  TIMoney4 -> money
  TIMoney8 -> money
  TIMoneyN _ -> money
  _ -> Decimal 0 <$> refInteger ti bs
  where
    money = case B.length bs of
      4 -> (\(Money (MkFixed i)) -> Decimal 4 i) <$> refRun refGetMoney4 bs
      8 -> (\(Money (MkFixed i)) -> Decimal 4 i) <$> refRun refGetMoney8 bs
      n -> Left $ "invalid money length " ++ show n

-- | Integer types and a value of a random length (mostly the right one).
integerValue :: Gen (TypeInfo, B.ByteString)
integerValue = do
  (ti, n) <- Gen.element
    [ (TIInt1, 1), (TIInt2, 2), (TIInt4, 4), (TIInt8, 8), (TIBit, 1), (TIBitN, 1)
    , (TIIntN 1, 1), (TIIntN 2, 2), (TIIntN 4, 4), (TIIntN 8, 8) ]
  len <- lengthNear n
  let bounds = [0, 2 ^ (8 * len - 1), 2 ^ (8 * len - 1) - 1, 2 ^ (8 * len) - 1, 127, 128, 255, 256, 32767, 32768, 2147483647, 2147483648]
  v <- if len == 0 then pure 0 else nearAny len bounds
  pure (ti, le len v)

-- | A type from the date and time family and a value for it.
dayTimeValue :: Gen (TypeInfo, B.ByteString)
dayTimeValue = Gen.choice
  [ (TIDateTime4,) <$> dt4
  , (TIDateTime8,) <$> dt8
  , (TIDateTimeN 4,) <$> Gen.choice [dt4, dt8]
  , (TIDateTimeN 8,) <$> Gen.choice [dt4, dt8]
  , do s <- Gen.word8 (Range.constant 0 7)
       v <- (<>) <$> timeBytes s <*> dateBytes
       (TIDateTime2N s,) <$> (lengthNear (B.length v) >>= (`resized` v))
  , (TIDateN,) <$> (lengthNear 3 >>= \n -> dateBytes >>= resized n)
  ]
  where
    dt4 = do
      days <- nearAny 2 [0, 65535]
      mins <- nearAny 2 [0, 1439, 1440, 65535]
      pure (le 2 days <> le 2 mins)
    dt8 = do
      days <- nearAny 4 [0, 2 ^ (32 :: Int) - 53690, 2958463, 2 ^ (31 :: Int), 2 ^ (31 :: Int) - 1]
      ticks <- nearAny 4 [0, 25920000, 2 ^ (32 :: Int) - 1]
      pure (le 4 days <> le 4 ticks)

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "readers agree with the Get parsers they replaced" $ do
    it "readMoney (smallmoney and money, negative and extreme)" $ hedgehog $ do
      n <- forAll $ Gen.element [4, 8]
      v <- forAll $ le n <$> nearAny n [0, 2 ^ (8 * n - 1), 2 ^ (8 * n - 1) - 1, 2 ^ (8 * n) - 1, 2 ^ (32 :: Int), 2 ^ (32 :: Int) - 1]
      agrees (if n == 4 then refGetMoney4 else refGetMoney8) readMoney v
      -- Any other length is an error.
      bad <- forAll $ Gen.filter (`notElem` [4, 8]) (Gen.int (Range.constant 0 12))
      (buf, off, _) <- forAll (embedded (B.replicate bad 0))
      assert (either (const True) (const False) (readMoney (B.take bad (B.drop off buf))))

    it "readDateTime4With localTimeOf (smalldatetime)" $ hedgehog $ do
      v <- forAll $ snd <$> Gen.filter ((== TIDateTime4) . fst) dayTimeValue
      agrees refGetDateTime4 (readDateTime4With localTimeOf) v

    it "readDateTime8With localTimeOf (datetime, day and tick boundaries)" $ hedgehog $ do
      v <- forAll $ snd <$> Gen.filter ((== TIDateTime8) . fst) dayTimeValue
      agrees refGetDateTime8 (readDateTime8With localTimeOf) v

    it "readDate (day boundaries)" $ hedgehog $ do
      v <- forAll dateBytes
      agrees refGetDate readDate v

    it "readTime (every scale, unit boundaries)" $ hedgehog $ do
      s <- forAll scales
      v <- forAll (timeBytes s)
      agrees (refGetTime s) (readTime s) v

    it "readDateTime2 (every scale)" $ hedgehog $ do
      s <- forAll scales
      v <- forAll $ (<>) <$> timeBytes s <*> dateBytes
      agrees (refGetDateTime2 s) (readDateTime2 s) v

    it "readDateTimeOffset (every scale, any offset)" $ hedgehog $ do
      s <- forAll scales
      v <- forAll $ (\t d o -> t <> d <> o) <$> timeBytes s <*> dateBytes <*> Gen.bytes (Range.singleton 2)
      agrees (refGetDateTimeOffset s) (readDateTimeOffset s) v

    it "readDecimal (every length, sign byte, precision boundary)" $ hedgehog $ do
      p <- forAll $ Gen.frequency [(10, Gen.word8 (Range.constant 1 38)), (1, Gen.element [0, 39, 40, 255])]
      s <- forAll $ Gen.word8 (Range.constant 0 (min p 38))
      len <- forAll $ Gen.frequency [(10, Gen.element [5, 9, 13, 17]), (1, Gen.int (Range.constant 0 20))]
      sign <- forAll $ Gen.frequency [(5, Gen.element [0, 1]), (1, Gen.word8 Range.constantBounded)]
      let pow = 10 ^ min p 60 :: Integer
          magBytes = max 0 (len - 1)
      mag <- forAll $ if magBytes == 0 then pure 0 else
        nearAny magBytes [0, pow - 1, pow, pow + 1, 2 ^ (64 :: Int) - 1, 2 ^ (64 :: Int), 2 ^ (96 :: Int) - 1, 2 ^ (8 * magBytes) - 1]
      let v = B.take len (B.cons sign (le magBytes mag))
      agrees (refGetDecimal p s len) (readDecimal p s) v
      -- The Get parser that is left agrees too.
      sameOutcome (refRun (refGetDecimal p s len) v) (refRun (getDecimal p s len) v)

    it "readGuid" $ hedgehog $ do
      v <- forAll $ Gen.bytes (Range.singleton 16)
      agrees refGetGuid readGuid v
      bad <- forAll $ Gen.filter (/= 16) (Gen.int (Range.constant 0 20))
      assert (either (const True) (const False) (readGuid (B.replicate bad 0)))

    it "the Get parsers, now on the readers, agree too" $ hedgehog $ do
      s <- forAll $ Gen.word8 (Range.constant 0 7)
      t <- forAll (timeBytes s)
      d <- forAll dateBytes
      o <- forAll $ Gen.bytes (Range.singleton 2)
      sameOutcome (refRun (refGetTime s) t) (refRun (getTime s) t)
      sameOutcome (refRun (refGetDate) d) (refRun getDate d)
      sameOutcome (refRun (refGetDateTime2 s) (t <> d)) (refRun (getDateTime2 s) (t <> d))
      sameOutcome (refRun (refGetDateTimeOffset s) (t <> d <> o)) (refRun (getDateTimeOffset s) (t <> d <> o))
      m <- forAll $ Gen.bytes (Range.singleton 8)
      sameOutcome (refRun refGetMoney8 m) (refRun getMoney8 m)
      sameOutcome (refRun refGetMoney4 (B.take 4 m)) (refRun getMoney4 (B.take 4 m))
      (_, v4) <- forAll $ Gen.filter ((== TIDateTime4) . fst) dayTimeValue
      sameOutcome (refRun refGetDateTime4 v4) (refRun getDateTime4 v4)
      (_, v8) <- forAll $ Gen.filter ((== TIDateTime8) . fst) dayTimeValue
      sameOutcome (refRun refGetDateTime8 v8) (refRun getDateTime8 v8)

    it "boundary values encoded by the put functions read back" $ do
      let days = [fromGregorian 1 1 1, fromGregorian 1753 1 1, fromGregorian 1900 1 1, fromGregorian 2079 6 6, fromGregorian 9999 12 31]
          tods = [midnight, TimeOfDay 23 59 59.9999999, TimeOfDay 12 34 56.1234567]
      mapM_ (\s -> mapM_ (\d -> mapM_ (\tod -> do
        let lt = LocalTime d tod
            -- Only the values the encoders accept.
            encoded r k = either (const (pure ())) (k . LB.toStrict . putBytes) r
        encoded (putDateTime2 s lt) $ \v2 ->
          refRun (refGetDateTime2 s) v2 `shouldBe` readDateTime2 s v2
        encoded (putTime s tod) $ \vt ->
          refRun (refGetTime s) vt `shouldBe` readTime s vt
        mapM_ (\mins -> encoded (putDateTimeOffset s (DateTimeOffset (UTCTime d (timeOfDayToTime tod)) mins)) $ \vo ->
          refRun (refGetDateTimeOffset s) vo `shouldBe` readDateTimeOffset s vo)
          ([-840, 0, 840] :: [Int16])) tods) days) [0 .. 7]

  describe "field decoders agree with the old decoding" $ do
    it "integers into every bounded integer type" $ hedgehog $ do
      (ti, v) <- forAll integerValue
      sameOutcome (refBounded @Int8 "Int8" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refBounded @Int16 "Int16" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refBounded @Int32 "Int32" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refBounded @Int64 "Int64" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refBounded @Int "Int" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refBounded @Word8 "Word8" ti v) (decodeAs fieldDecoder ti v)
      sameOutcome (refInteger ti v) (decodeAs (fieldDecoder @Integer) ti v)
      sameOutcome (refDecimal ti v) (decodeAs (fieldDecoder @Decimal) ti v)

    it "decimal, numeric and money into Decimal, Integer and Money" $ hedgehog $ do
      ti <- forAll $ Gen.choice
        [ TIDecimalN <$> Gen.word8 (Range.constant 1 38) <*> Gen.element [0, 2, 4]
        , TINumericN <$> Gen.word8 (Range.constant 1 38) <*> pure 0
        , Gen.element [TIMoney4, TIMoney8, TIMoneyN 4, TIMoneyN 8] ]
      let n = case ti of
            TIDecimalN p _ -> precisionToLength p + 1
            TINumericN p _ -> precisionToLength p + 1
            TIMoney4 -> 4
            TIMoneyN 4 -> 4
            _ -> 8
      len <- forAll (lengthNear n)
      v <- forAll $ Gen.bytes (Range.singleton len)
      sameOutcome (refDecimal ti v) (decodeAs (fieldDecoder @Decimal) ti v)
      case ti of
        TINumericN _ 0 -> sameOutcome (decimalMantissa <$> refDecimal ti v) (decodeAs (fieldDecoder @Integer) ti v)
        TIDecimalN _ _ -> pure ()
        TINumericN _ _ -> pure ()
        _ -> sameOutcome (fmap (\(Decimal _ i) -> Money (MkFixed i)) (refDecimal ti v)) (decodeAs (fieldDecoder @Money) ti v)

    it "the date and time types into LocalTime, UTCTime and SqlValue" $ hedgehog $ do
      (ti, v) <- forAll dayTimeValue
      sameOutcome (refLocalTime ti v) (decodeAs (fieldDecoder @LocalTime) ti v)
      sameOutcome (localTimeToUTC utc <$> refLocalTime ti v) (decodeAs (fieldDecoder @UTCTime) ti v)
      let sqlValue = case ti of
            TIDateN -> SqlDate . localDay <$> refLocalTime ti v
            _ -> SqlDateTime <$> refLocalTime ti v
      sameOutcome sqlValue (decodeAs (fieldDecoder @SqlValue) ti v)
      case ti of
        TIDateN -> sameOutcome (refRun refGetDate v) (decodeAs (fieldDecoder @Day) ti v)
        _ -> pure ()

    it "time and datetimeoffset into TimeOfDay, DateTimeOffset, UTCTime and SqlValue" $ hedgehog $ do
      s <- forAll $ Gen.word8 (Range.constant 0 7)
      t <- forAll (timeBytes s)
      sameOutcome (refRun (refGetTime s) t) (decodeAs (fieldDecoder @TimeOfDay) (TITimeN s) t)
      sameOutcome (SqlTime <$> refRun (refGetTime s) t) (decodeAs (fieldDecoder @SqlValue) (TITimeN s) t)
      v <- forAll $ (\d o -> t <> d <> o) <$> dateBytes <*> Gen.bytes (Range.singleton 2)
      let ti = TIDateTimeOffsetN s
          ref = refRun (refGetDateTimeOffset s) v
      sameOutcome ref (decodeAs (fieldDecoder @DateTimeOffset) ti v)
      sameOutcome (dtoUtcTime <$> ref) (decodeAs (fieldDecoder @UTCTime) ti v)
      sameOutcome (SqlDateTimeOffset <$> ref) (decodeAs (fieldDecoder @SqlValue) ti v)

    it "fixed-width types into SqlValue" $ hedgehog $ do
      (ti, v) <- forAll integerValue
      let ref = case ti of
            TIBit -> SqlBool . (/= 0) <$> refRun Get.getWord8 v
            TIBitN -> SqlBool . (/= 0) <$> refRun Get.getWord8 v
            TIInt1 -> SqlWord8 <$> refRun Get.getWord8 v
            TIInt2 -> SqlInt16 <$> refRun Get.getInt16le v
            TIInt4 -> SqlInt32 <$> refRun Get.getInt32le v
            TIInt8 -> SqlInt64 <$> refRun Get.getInt64le v
            _ -> case B.length v of
              1 -> SqlWord8 <$> refRun Get.getWord8 v
              2 -> SqlInt16 <$> refRun Get.getInt16le v
              4 -> SqlInt32 <$> refRun Get.getInt32le v
              8 -> SqlInt64 <$> refRun Get.getInt64le v
              n -> Left $ "invalid integer length " ++ show n
      sameOutcome ref (decodeAs (fieldDecoder @SqlValue) ti v)
      sameOutcome (either Left (\b -> Right (b /= (0 :: Word8))) (refRun Get.getWord8 v))
        (decodeAs (fieldDecoder @Bool) TIBitN v)
      g <- forAll $ Gen.bytes (Range.singleton 16)
      sameOutcome (SqlGuid <$> refRun refGetGuid g) (decodeAs (fieldDecoder @SqlValue) TIGuid g)
      sameOutcome (refRun refGetGuid g) (decodeAs (fieldDecoder @UUID) TIGuid g)
      f <- forAll $ Gen.bytes (Range.singleton 8)
      let sameFloat a b = show a === show b
      sameFloat (refRun Get.getDoublele f) (decodeAs (fieldDecoder @Double) TIFlt8 f)
      sameFloat (SqlDouble <$> refRun Get.getDoublele f) (decodeAs (fieldDecoder @SqlValue) (TIFltN 8) f)
      sameFloat (refRun Get.getFloatle (B.take 4 f)) (decodeAs (fieldDecoder @Float) TIFlt4 (B.take 4 f))
      sameFloat (float2Double <$> refRun Get.getFloatle (B.take 4 f))
        (decodeAs (fieldDecoder @Double) (TIFltN 4) (B.take 4 f))
      sameFloat (SqlFloat <$> refRun Get.getFloatle (B.take 4 f)) (decodeAs (fieldDecoder @SqlValue) TIFlt4 (B.take 4 f))
  where
    putBytes = Put.runPut
