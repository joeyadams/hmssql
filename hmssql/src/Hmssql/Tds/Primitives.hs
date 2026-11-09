{-# LANGUAGE MagicHash #-}
-- | Binary encodings of individual SQL Server scalar types.
--
-- These are the leaf encoders/decoders shared by "Hmssql.Tds.TypeInfo",
-- "Hmssql.Decoding" and "Hmssql.Encoding".
module Hmssql.Tds.Primitives
  ( -- * Reading values in place
    ValueReader

    -- * Writing a value
  , runPutSized

    -- * money / smallmoney
  , E4
  , Money (..)
  , putMoney4, putMoney8
  , readMoney, moneyUnits
  , money4Problem, money8Problem

    -- * datetime / smalldatetime (legacy)
  , putDateTime4, putDateTime8
  , readDateTime4With, readDateTime8With

    -- * date / time / datetime2 / datetimeoffset (TDS 7.3+)
  , Scale
  , DateTimeOffset (..)
  , dateTimeOffsetToZonedTime
  , zonedTimeToDateTimeOffset
  , scaleProblem
  , timeLength
  , putDate
  , putTime
  , putDateTime2
  , putDateTimeOffset
  , readDate, readTime, readDateTime2, readDateTimeOffset
  , readDateWith, readTimeWith, readDateTime2With, readDateTimeOffsetWith
  , localTimeOf, utcTimeOf, picosecondsToTimeOfDay

    -- * decimal / numeric
  , Precision
  , precisionToLength
  , putDecimal
  , readDecimal
  , readDecimalWith

    -- * uniqueidentifier
  , putGuid
  , readGuid

    -- * collation
  , Collation (..)
  , collationAt, putCollation

    -- * UCS-2 strings
  , decodeUtf16LE
  , putUcs2
  , putBVarChar
  , putUsVarChar
  , ucs2Length
  ) where

import Control.Monad (when)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder.Extra as BB
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..), roundTo)
import Data.Fixed (Fixed (..), HasResolution (..))
import Data.Int (Int16, Int32, Int64)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Data.Word (Word32, Word64, Word8)

import Hmssql.Internal.Derived
import Hmssql.Tds.Bytes
import qualified Hmssql.Tds.Utf16 as Utf16

------------------------------------------------------------------------------
-- Reading values in place

-- | A conversion of one whole value, given exactly its bytes; where they lay
-- in the packets is the parser's concern.  They may be a slice of a receive
-- buffer, so a reader must copy any it keeps.
type ValueReader a = B.ByteString -> Either String a


-- | Report the actual and expected lengths of a scalar value.
invalidLength :: String -> String -> Int -> Either String a
invalidLength name expected len = Left $ name ++ ": invalid length " ++ show len ++ " (" ++ expected ++ ")"
{-# NOINLINE invalidLength #-}

------------------------------------------------------------------------------
-- Writing a value

-- | The bytes of a short 'Put' of (at most, or it is slower) @n@ bytes, in
-- a buffer of that size: how a parameter's value is encoded by the @put*@
-- functions below.  binary's own 'Put.runPut' starts with a 4 KiB buffer,
-- a large object of its own, and 'LB.toStrict' then copies the few bytes
-- out of it: about 100 ns and 4 KiB per value.
runPutSized :: Int -> Put -> B.ByteString
runPutSized n = LB.toStrict . BB.toLazyByteStringWith (BB.untrimmedStrategy n n) LB.empty . Put.execPut

------------------------------------------------------------------------------
-- money

-- | Resolution of 1/10000, matching @money@ and @smallmoney@.
data E4

instance HasResolution E4 where
  resolution _ = 10000

-- | A @money@ or @smallmoney@ value: a fixed-point number with four
-- decimal places, exactly as the server stores it.
newtype Money = Money (Fixed E4)
  deriving newtype (Eq, Ord, Num, Fractional, Real, RealFrac)

instance Show Money where
  showsPrec p (Money a) = showCon1 p "Money"# a
  {-# OPAQUE showsPrec #-}

-- | @smallmoney@ (4 bytes) or @money@ (8 bytes), by the value's length.  A
-- @money@ value is two little-endian DWORDs, the high half first.
readMoney :: ValueReader Money
readMoney bs = case B.length bs of
  4 -> Right $! Money (MkFixed (toInteger (int32LeAt bs 0)))
  8 ->
    let hi = int32LeAt bs 0
        lo = word32LeAt bs 4
        i = (fromIntegral hi `shiftL` 32) .|. fromIntegral lo :: Int64
     in Right $! Money (MkFixed (toInteger i))
  _ -> Left $ "invalid money length " ++ show (B.length bs)

-- | A @money@ or @smallmoney@ value as its count of 1\/10000ths.
moneyUnits :: ValueReader Int64
moneyUnits bs = case B.length bs of
  4 -> Right $! fromIntegral (int32LeAt bs 0)
  8 -> Right $! (fromIntegral (int32LeAt bs 0) `shiftL` 32) .|. fromIntegral (word32LeAt bs 4)
  _ -> Left $ "invalid money length " ++ show (B.length bs)

-- | Why a 'Money' value doesn't fit in @money@ (a signed 64-bit count of
-- 1\/10000ths: -922,337,203,685,477.5808 through 922,337,203,685,477.5807),
-- if it doesn't.  'Money' itself is unbounded.
money8Problem :: Money -> Maybe String
money8Problem = moneyRangeProblem "money" (minBound :: Int64) maxBound

-- | Likewise for @smallmoney@ (-214,748.3648 through 214,748.3647).
money4Problem :: Money -> Maybe String
money4Problem = moneyRangeProblem "smallmoney" (minBound :: Int32) maxBound

moneyRangeProblem :: Integral n => String -> n -> n -> Money -> Maybe String
moneyRangeProblem name lo hi m@(Money (MkFixed i))
  | i < toInteger lo || i > toInteger hi = Just $
      "value " ++ show m ++ " is out of range for " ++ name ++ " ("
        ++ show (Money (MkFixed (toInteger lo))) ++ " through " ++ show (Money (MkFixed (toInteger hi))) ++ ")"
  | otherwise = Nothing

-- | Fails (with 'error') outside the @smallmoney@ range ('money4Problem').
putMoney4 :: Money -> Put
putMoney4 m@(Money (MkFixed i)) = case money4Problem m of
  Just p -> error ("putMoney4: " ++ p)
  Nothing -> Put.putInt32le (fromIntegral i)

-- | Fails (with 'error') outside the @money@ range ('money8Problem') rather
-- than sending the value modulo 2^64.
putMoney8 :: Money -> Put
putMoney8 m@(Money (MkFixed i)) = do
  mapM_ (\p -> error ("putMoney8: " ++ p)) (money8Problem m)
  let i64 = fromIntegral i :: Int64
  Put.putInt32le $ fromIntegral (i64 `shiftR` 32)
  Put.putWord32le $ fromIntegral (i64 .&. 0xFFFFFFFF)

------------------------------------------------------------------------------
-- Rounding and range checks shared by the date/time encoders
--
-- Every encoder rounds to the nearest unit of its type (half up), as SQL
-- Server does when converting to a lower precision, and checks the type's
-- range:
--
-- * Types with a date part carry into the next day (23:59:59.9999999 at
--   scale 0 is midnight of the next day).  A value on the type's last day
--   that rounds past its maximum is clamped to the maximum, as SQL Server
--   does when converting @datetime2(7)@ to @datetime2(0)@ or @datetime@.
--   Values outside the type's range are rejected with a 'Left'.
-- * @time@ has no next day, so a value that rounds to 24:00:00 is clamped to
--   the last unit of the day (23:59:59 at scale 0), again as the server does.
-- * A leap second (second 60 of 'TimeOfDay', or a 'UTCTime' day time of
--   86400 s or more) counts as the following second: it carries into the
--   next day, or clamps for @time@.

-- | A clock resolution and range: @clockUnits@ units per @clockPer@
-- picoseconds, counted from midnight of @clockEpoch@, valid from midnight of
-- @clockMinDay@ to the last unit of @clockMaxDay@.
data Clock = Clock
  { clockType :: String
  , clockUnits :: !Integer
  , clockPer :: !Integer
  , clockEpoch :: !Day
  , clockMinDay :: !Day
  , clockMaxDay :: !Day
  }

picosPerDay :: Integer
picosPerDay = 86400 * 1_000_000_000_000

clockUnitsPerDay :: Clock -> Integer
clockUnitsPerDay c = picosPerDay * clockUnits c `div` clockPer c

-- | Round picoseconds to the clock's units, half up.
clockRound :: Clock -> Integer -> Integer
clockRound c ps = (ps * clockUnits c + clockPer c `div` 2) `div` clockPer c

-- | For a scale from 0 through 7 ('scaleProblem'): @clockPer@ is
-- @10 ^ (12 - s)@, a unit finer than any SQL Server type for 8 through 12
-- and an exception (negative exponent) from 13 on.
scaleClock :: String -> Scale -> Clock
scaleClock name s = Clock name 1 (10 ^ (12 - fromIntegral s :: Int)) epoch0001 epoch0001 lastDay

dateTimeClock :: Clock
dateTimeClock = Clock "datetime" 300 1_000_000_000_000 epoch1900 (fromGregorian 1753 1 1) lastDay

smallDateTimeClock :: Clock
smallDateTimeClock = Clock "smalldatetime" 1 (60 * 1_000_000_000_000) epoch1900 epoch1900 (fromGregorian 2079 6 6)

lastDay :: Day
lastDay = fromGregorian 9999 12 31

-- | Picoseconds since midnight.  Rejects fields out of range; a leap second
-- (second 60) gives 86400 s or more.
timeOfDayPicoseconds :: TimeOfDay -> Either String Integer
timeOfDayPicoseconds tod@(TimeOfDay h m s)
  | h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s >= 61 = Left $ "invalid time of day " ++ show tod
  | otherwise = Right $ diffTimeToPicoseconds (timeOfDayToTime tod)

outOfRange :: Clock -> String -> Either String a
outOfRange c what = Left $
  clockType c ++ " value " ++ what ++ " is out of range (" ++ showGregorian (clockMinDay c)
    ++ " through " ++ showGregorian (clockMaxDay c) ++ ")"

-- | Units since the clock's epoch, rounded and range-checked.  @shift@ (in
-- units) is added to get a second value that must also be in range (the local
-- time of a @datetimeoffset@); @shiftDay@ is that value's unrounded day.
clockValue :: Clock -> Integer -> Day -> LocalTime -> Either String Integer
clockValue c shift shiftDay lt@(LocalTime day tod) = do
  ps <- timeOfDayPicoseconds tod
  let perDay = clockUnitsPerDay c
      lo = diffDays (clockMinDay c) (clockEpoch c) * perDay
      hi = (diffDays (clockMaxDay c) (clockEpoch c) + 1) * perDay - 1
      u = diffDays day (clockEpoch c) * perDay + clockRound c ps
  if | day > clockMaxDay c || shiftDay > clockMaxDay c -> outOfRange c (show lt)
     | u < lo || u + shift < lo -> outOfRange c (show lt)
     | otherwise -> Right $ minimum [u, hi, hi - shift]

------------------------------------------------------------------------------
-- datetime / smalldatetime

epoch1900 :: Day
epoch1900 = fromGregorian 1900 1 1

-- | The modified Julian day number of 1900-01-01.
mjd1900 :: Int
mjd1900 = 15020

-- | @smalldatetime@, passing the day and the picoseconds since midnight to
-- the function ('localTimeOf', 'utcTimeOf').
readDateTime4With :: (Day -> Int64 -> a) -> ValueReader a
readDateTime4With k bs
  | B.length bs /= 4 = invalidLength "smalldatetime" "4 bytes" (B.length bs)
  | mins >= 1440 = Left $ "smalldatetime: invalid minute count " ++ show mins
  | otherwise = Right $! k (dayOf (fromIntegral days + mjd1900)) (fromIntegral mins * 60_000_000_000_000)
  where
    days = word16LeAt bs 0
    mins = word16LeAt bs 2
{-# INLINE readDateTime4With #-}

-- | @datetime@, passing the day and the picoseconds since midnight (rounded
-- down) to the function.
readDateTime8With :: (Day -> Int64 -> a) -> ValueReader a
readDateTime8With k bs
  | B.length bs /= 8 = invalidLength "datetime" "8 bytes" (B.length bs)
  | ticks >= 300 * 86400 = Left $ "datetime: invalid tick count " ++ show ticks
  -- 1753-01-01 through 9999-12-31
  | days < -53690 || days > 2958463 = Left $ "datetime: invalid day count " ++ show days
  | otherwise = Right $! k (dayOf (fromIntegral days + mjd1900)) ps
  where
    days = int32LeAt bs 0
    ticks = word32LeAt bs 4
    -- ticks * 10^12 / 300 overflows 64 bits; the seconds and the rest don't.
    (secs, rest) = fromIntegral ticks `quotRem` 300 :: (Int64, Int64)
    ps = secs * 1_000_000_000_000 + rest * 1_000_000_000_000 `quot` 300
{-# INLINE readDateTime8With #-}

-- | Rounds to the nearest minute (1900-01-01 through 2079-06-06).
putDateTime4 :: LocalTime -> Either String Put
putDateTime4 lt = do
  u <- clockValue smallDateTimeClock 0 epoch1900 lt
  let (days, mins) = u `divMod` 1440
  pure $ Put.putWord16le (fromIntegral days) >> Put.putWord16le (fromIntegral mins)

-- | Rounds to the nearest 1/300 s (1753-01-01 through 9999-12-31).
putDateTime8 :: LocalTime -> Either String Put
putDateTime8 lt = do
  u <- clockValue dateTimeClock 0 epoch1900 lt
  let (days, ticks) = u `divMod` clockUnitsPerDay dateTimeClock
  pure $ Put.putInt32le (fromIntegral days) >> Put.putWord32le (fromIntegral ticks)

------------------------------------------------------------------------------
-- date / time / datetime2 / datetimeoffset

type Scale = Word8

-- | A @datetimeoffset@ value: an instant plus the UTC offset it was recorded with.
data DateTimeOffset = DateTimeOffset
  { dtoUtcTime :: !UTCTime
    -- ^ The instant.
  , dtoOffsetMinutes :: !Int16
    -- ^ The offset from UTC the value was recorded with, in minutes; the
    -- local clock time is the instant plus this.
  }
  deriving stock (Ord)

instance Show DateTimeOffset where
  showsPrec p (DateTimeOffset a b) =
    showRecord p "DateTimeOffset"# ["dtoUtcTime"# := a, "dtoOffsetMinutes"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq DateTimeOffset where
  DateTimeOffset a b == DateTimeOffset a' b' = eq a a' && b == b'
  {-# OPAQUE (==) #-}

-- | The same instant as a 'ZonedTime' in the value's offset.
dateTimeOffsetToZonedTime :: DateTimeOffset -> ZonedTime
dateTimeOffsetToZonedTime (DateTimeOffset utc mins) =
  utcToZonedTime (minutesToTimeZone (fromIntegral mins)) utc

-- | An offset beyond the range of 'Int16' is clamped to it rather than
-- wrapped (so it stays outside the ±14:00 a @datetimeoffset@ allows, and
-- 'putDateTimeOffset' rejects it).
zonedTimeToDateTimeOffset :: ZonedTime -> DateTimeOffset
zonedTimeToDateTimeOffset zt =
  DateTimeOffset (zonedTimeToUTC zt) (fromIntegral (max lo (min hi mins)))
  where
    mins = timeZoneMinutes (zonedTimeZone zt)
    lo = fromIntegral (minBound :: Int16)
    hi = fromIntegral (maxBound :: Int16)

epoch0001 :: Day
epoch0001 = fromGregorian 1 1 1

-- | Why a @time@, @datetime2@ or @datetimeoffset@ (named) can't have this
-- scale, if it can't: MS-TDS 2.2.5.4.2 allows 0 through 7.  Every
-- exported function here that takes a scale checks it with this.
scaleProblem :: String -> Scale -> Maybe String
scaleProblem name s
  | s > 7 = Just $ "invalid " ++ name ++ " scale " ++ show s ++ " (0 through 7)"
  | otherwise = Nothing

checkScale :: String -> Scale -> Either String ()
checkScale name s = maybe (Right ()) Left (scaleProblem name s)

-- | Number of bytes used for the time portion at a given scale (5 for any
-- scale above 4, including invalid ones: see 'scaleProblem').
timeLength :: Scale -> Int
timeLength s
  | s <= 2 = 3
  | s <= 4 = 4
  | otherwise = 5

putUIntLE :: Int -> Word64 -> Put
putUIntLE n v = mapM_ (\i -> Put.putWord8 $ fromIntegral $ v `shiftR` (8 * i)) [0 .. n - 1]

-- | @date@: 3-byte count of days since 0001-01-01.
readDate :: ValueReader Day
readDate = readDateWith id
{-# INLINE readDate #-}

-- | @date@, passing the day to the function.
readDateWith :: (Day -> a) -> ValueReader a
readDateWith k bs
  | B.length bs /= 3 = invalidLength "date" "3 bytes" (B.length bs)
  | otherwise = do
      !d <- dateAt bs 0
      Right $! k d
{-# INLINE readDateWith #-}

-- | The 3-byte day count at the offset.
dateAt :: B.ByteString -> Int -> Either String Day
dateAt bs off
  -- 9999-12-31
  | d > 3_652_058 = Left $ "date: invalid day count " ++ show d
  | otherwise = Right $! dayOf (fromIntegral d + mjd0001)
  where
    d = wordLeAt 3 bs off
{-# INLINE dateAt #-}

-- | The modified Julian day number of 0001-01-01.
mjd0001 :: Int
mjd0001 = -678575

-- | A day from its modified Julian day number.
dayOf :: Int -> Day
dayOf n = ModifiedJulianDay (toInteger n)
{-# INLINE dayOf #-}

-- | Picoseconds per unit at a scale from 0 through 7: @10 ^ (12 - s)@.
picosPerUnit :: Scale -> Int64
picosPerUnit = \case
  0 -> 1_000_000_000_000
  1 -> 100_000_000_000
  2 -> 10_000_000_000
  3 -> 1_000_000_000
  4 -> 100_000_000
  5 -> 10_000_000
  6 -> 1_000_000
  _ -> 100_000

-- | Units per day at a scale from 0 through 7: @86400 * 10 ^ s@.
unitsPerDay :: Scale -> Word64
unitsPerDay = \case
  0 -> 86_400
  1 -> 864_000
  2 -> 8_640_000
  3 -> 86_400_000
  4 -> 864_000_000
  5 -> 8_640_000_000
  6 -> 86_400_000_000
  _ -> 864_000_000_000

-- | The time units (of a scale already checked) at the offset, as
-- picoseconds since midnight.
timeAt :: Scale -> B.ByteString -> Int -> Either String Int64
timeAt scale bs off
  | units >= unitsPerDay scale = Left $ "time: invalid unit count " ++ show units
  | otherwise = Right $! fromIntegral units * picosPerUnit scale
  where
    units = wordLeAt (timeLength scale) bs off
{-# INLINE timeAt #-}

-- | A time of day from picoseconds since midnight (less than a day).
picosecondsToTimeOfDay :: Int64 -> TimeOfDay
picosecondsToTimeOfDay ps =
  let (h, r) = ps `quotRem` 3_600_000_000_000_000
      (m, s) = r `quotRem` 60_000_000_000_000
      !h' = fromIntegral h
      !m' = fromIntegral m
      !s' = MkFixed (toInteger s)
   in TimeOfDay h' m' s'
{-# INLINE picosecondsToTimeOfDay #-}

-- | A 'LocalTime', evaluated, from a day and picoseconds since midnight.
localTimeOf :: Day -> Int64 -> LocalTime
localTimeOf !day ps = let !tod = picosecondsToTimeOfDay ps in LocalTime day tod
{-# INLINE localTimeOf #-}

-- | A 'UTCTime', evaluated, from a day and picoseconds since midnight.
utcTimeOf :: Day -> Int64 -> UTCTime
utcTimeOf !day ps = let !dt = picosecondsToDiffTime (toInteger ps) in UTCTime day dt
{-# INLINE utcTimeOf #-}

scaledLength :: String -> Scale -> Int -> Int -> Either String a
scaledLength name scale expected = invalidLength name (show expected ++ " bytes at scale " ++ show scale)
{-# NOINLINE scaledLength #-}

-- | 0001-01-01 through 9999-12-31.
putDate :: Day -> Either String Put
putDate d
  | d < epoch0001 || d > lastDay = outOfRange (scaleClock "date" 0) (showGregorian d)
  | otherwise = Right $ putUIntLE 3 (fromIntegral $ diffDays d epoch0001)

-- | @time(scale)@: a count of units of 10^-scale seconds since midnight.
readTime :: Scale -> ValueReader TimeOfDay
-- Written with its arguments, so that the INLINE reader below inlines here, which
-- it doesn't into an unsaturated call; and with the bang, so that GHC doesn't
-- eta-reduce the definition back to that call.
readTime scale !bs = readTimeWith picosecondsToTimeOfDay scale bs

-- | @time(scale)@, passing the picoseconds since midnight to the function.
readTimeWith :: (Int64 -> a) -> Scale -> ValueReader a
readTimeWith k scale bs
  | Just p <- scaleProblem "time" scale = Left p
  | B.length bs /= n = scaledLength "time" scale n (B.length bs)
  | otherwise = do
      !ps <- timeAt scale bs 0
      Right $! k ps
  where
    n = timeLength scale
{-# INLINE readTimeWith #-}

-- | Rounds to the nearest unit, but never past 23:59:59.(9...) at the scale.
putTime :: Scale -> TimeOfDay -> Either String Put
putTime scale tod = do
  checkScale "time" scale
  ps <- timeOfDayPicoseconds tod
  let c = scaleClock "time" scale
      units = min (clockRound c ps) (clockUnitsPerDay c - 1)
  pure $ putUIntLE (timeLength scale) (fromIntegral units)

-- | @datetime2(scale)@: the time units, then the date.
readDateTime2 :: Scale -> ValueReader LocalTime
readDateTime2 = readDateTime2With localTimeOf
{-# INLINE readDateTime2 #-}

-- | @datetime2(scale)@, passing the day and the picoseconds since midnight
-- to the function.
readDateTime2With :: (Day -> Int64 -> a) -> Scale -> ValueReader a
readDateTime2With k scale bs
  | Just p <- scaleProblem "datetime2" scale = Left p
  | B.length bs /= n + 3 = scaledLength "datetime2" scale (n + 3) (B.length bs)
  | otherwise = do
      !ps <- timeAt scale bs 0
      !day <- dateAt bs (n)
      Right $! k day ps
  where
    n = timeLength scale
{-# INLINE readDateTime2With #-}

-- | Units since 0001-01-01 split into the time and date fields.
putScaledUnits :: Scale -> Integer -> Put
putScaledUnits scale u = do
  let (days, units) = u `divMod` clockUnitsPerDay (scaleClock "" scale)
  putUIntLE (timeLength scale) (fromIntegral units)
  putUIntLE 3 (fromIntegral days)

-- | Rounds to the nearest unit, carrying into the next day.
putDateTime2 :: Scale -> LocalTime -> Either String Put
putDateTime2 scale lt = checkScale "datetime2" scale >> putScaledUnits scale <$> clockValue (scaleClock "datetime2" scale) 0 epoch0001 lt

-- | @datetimeoffset(scale)@: the time units and the date, both in UTC, then
-- the offset as a signed count of minutes.
readDateTimeOffset :: Scale -> ValueReader DateTimeOffset
-- With its arguments and the bang, as 'readTime' has them.
readDateTimeOffset scale !bs = readDateTimeOffsetWith (\day ps mins -> DateTimeOffset (utcTimeOf day ps) mins) scale bs

-- | @datetimeoffset(scale)@, passing the UTC day, the picoseconds since UTC
-- midnight and the offset in minutes to the function.  The value is checked
-- as 'readDateTimeOffset' checks it: the offset within ±14:00, and the local
-- date within 0001-01-01 through 9999-12-31.
readDateTimeOffsetWith :: (Day -> Int64 -> Int16 -> a) -> Scale -> ValueReader a
readDateTimeOffsetWith k scale bs
  | Just p <- scaleProblem "datetimeoffset" scale = Left p
  | B.length bs /= n + 5 = scaledLength "datetimeoffset" scale (n + 5) (B.length bs)
  | otherwise = do
      !ps <- timeAt scale bs 0
      !day <- dateAt bs (n)
      let mins = int16LeAt bs (n + 3)
      when (mins < -840 || mins > 840) $
        Left $ "datetimeoffset: invalid offset minute count " ++ show mins
      let localPs = ps + fromIntegral mins * 60_000_000_000_000
          -- 'dateAt' has kept the day within SQL Server's range, and the offset
          -- moves it by at most one day, so the local day fits an 'Int' on a
          -- 32-bit target too.  In 'Integer' the same check allocated 16 bytes
          -- per value (GHC 9.12.4, 2026-11-04).
          localDay = fromInteger (toModifiedJulianDay day) + fromIntegral (localPs `div` 86_400_000_000_000_000) :: Int
      when (localDay < mjd0001 || localDay > mjd0001 + 3_652_058) $
        Left "datetimeoffset: local date outside 0001-01-01 through 9999-12-31"
      Right $! k day ps mins
  where
    n = timeLength scale
{-# INLINE readDateTimeOffsetWith #-}

-- | Rounds like 'putDateTime2'.  The offset must be within ±14:00, and both
-- the UTC and the local time must be in range.
putDateTimeOffset :: Scale -> DateTimeOffset -> Either String Put
putDateTimeOffset scale dto@(DateTimeOffset t@(UTCTime day dt) mins)
  | Just p <- scaleProblem "datetimeoffset" scale = Left p
  | mins < -840 || mins > 840 = Left $ "datetimeoffset value " ++ show dto ++ ": the UTC offset must be between -14:00 and +14:00"
  | dt < 0 || dt >= 86401 = Left $ "datetimeoffset value " ++ show dto ++ ": invalid time of day"
  | otherwise = do
      let c = scaleClock "datetimeoffset" scale
          shift = toInteger mins * 60 * clockUnitsPerDay c `div` 86400
          local = utcToLocalTime (minutesToTimeZone (fromIntegral mins)) t
      u <- either (const (Left rangeErr)) Right $
        clockValue c shift (localDay local) (LocalTime day (timeToTimeOfDay dt))
      pure $ putScaledUnits scale u >> Put.putInt16le mins
  where
    rangeErr =
      "datetimeoffset value " ++ show (dateTimeOffsetToZonedTime dto) ++ " (UTC " ++ show t
        ++ ") is out of range: the UTC and local times must be within 0001-01-01 through 9999-12-31"

------------------------------------------------------------------------------
-- decimal / numeric

type Precision = Word8

-- | Length of the magnitude (excluding the sign byte) for a given precision.
precisionToLength :: Precision -> Int
precisionToLength p
  | p <= 9 = 4
  | p <= 19 = 8
  | p <= 28 = 12
  | otherwise = 16

decimalLengthError :: Int -> String
decimalLengthError len = "decimal: invalid length " ++ show len ++ " (5, 9, 13 or 17 bytes)"

-- | @decimal@ and @numeric@: a sign byte (0 negative, 1 positive) followed by
-- a little-endian unsigned magnitude of 4, 8, 12 or 16 bytes (MS-TDS
-- 2.2.5.5.1.3).  The magnitude is usually 'precisionToLength' bytes, but SQL
-- Server doesn't always send that: a @decimal(10,0)@ zero read from a table
-- has 4, and a @decimal(1,0)@ in a @sql_variant@ has 16.  So any of the four
-- lengths is accepted, as SqlClient accepts them, and the value is checked
-- against the precision instead.  Another length, another sign byte, or a
-- magnitude with more digits than the precision allows is a 'Left'.
readDecimal :: Precision -> Scale -> ValueReader Decimal
-- A magnitude that fits in 64 bits is checked against the precision as a
-- 'Word64' and becomes an 'Integer' once.
readDecimal precision scale bs
  | B.length bs /= 5 && (B.length bs) /= 9 && (B.length bs) /= 13 && (B.length bs) /= 17 = Left (decimalLengthError (B.length bs))
  | sign > 1 = Left $ "decimal: invalid sign byte " ++ show sign
  | B.length bs == 5 = small (fromIntegral (word32LeAt bs 1))
  | B.length bs == 9 = small (word64LeAt bs 1)
  | hi == 0 = small lo
  | otherwise = big ((toInteger hi `shiftL` 64) .|. toInteger lo)
  where
    sign = word8At bs 0
    lo = word64LeAt bs 1
    hi | B.length bs == 13 = fromIntegral (word32LeAt bs 9)
       | otherwise = word64LeAt bs 9
    -- Below 2^64, so fewer than 20 digits: only a precision below 20 can
    -- be exceeded.
    small :: Word64 -> Either String Decimal
    small m
      | precision < 20 && m >= word64PowerOfTen precision = tooMany (toInteger m)
      | otherwise = value (toInteger m)
    big m
      | m >= powerOfTen precision = tooMany m
      | otherwise = value m
    value m = Right $! Decimal scale (if sign == 0 then negate m else m)
    tooMany m = Left $ "decimal: magnitude " ++ show m ++ " has more than " ++ show precision ++ " digits"

-- | @decimal@ and @numeric@, checked as 'readDecimal' checks them, passing the
-- value's parts to the function: whether it is negative, the high and low 64 bits
-- of its magnitude, and the scale.  A zero is never negative, though the wire can
-- carry one.
readDecimalWith :: (Bool -> Word64 -> Word64 -> Scale -> a) -> Precision -> Scale -> ValueReader a
readDecimalWith k precision scale bs
  | len /= 5 && len /= 9 && len /= 13 && len /= 17 = Left (decimalLengthError len)
  | sign > 1 = Left $ "decimal: invalid sign byte " ++ show sign
  | len == 5 = small (fromIntegral (word32LeAt bs 1))
  | len == 9 = small (word64LeAt bs 1)
  | hi == 0 = small lo
  | (toInteger hi `shiftL` 64) .|. toInteger lo >= powerOfTen precision =
      Left (decimalDigitsError precision ((toInteger hi `shiftL` 64) .|. toInteger lo))
  | otherwise = Right $! k (sign == 0) hi lo scale
  where
    len = B.length bs
    sign = word8At bs 0
    lo = word64LeAt bs 1
    hi | len == 13 = fromIntegral (word32LeAt bs 9)
       | otherwise = word64LeAt bs 9
    small m
      | precision < 20 && m >= word64PowerOfTen precision = Left (decimalDigitsError precision (toInteger m))
      | otherwise = Right $! k (sign == 0 && m /= 0) 0 m scale
{-# INLINE readDecimalWith #-}

-- Out of line, so that a copy of 'readDecimalWith' doesn't hold the message.
decimalDigitsError :: Precision -> Integer -> String
decimalDigitsError precision m = "decimal: magnitude " ++ show m ++ " has more than " ++ show precision ++ " digits"
{-# NOINLINE decimalDigitsError #-}

-- | @10 ^ p@ for @p@ from 0 through 19.
word64PowerOfTen :: Precision -> Word64
word64PowerOfTen = \case
  0 -> 1
  1 -> 10
  2 -> 100
  3 -> 1_000
  4 -> 10_000
  5 -> 100_000
  6 -> 1_000_000
  7 -> 10_000_000
  8 -> 100_000_000
  9 -> 1_000_000_000
  10 -> 10_000_000_000
  11 -> 100_000_000_000
  12 -> 1_000_000_000_000
  13 -> 10_000_000_000_000
  14 -> 100_000_000_000_000
  15 -> 1_000_000_000_000_000
  16 -> 10_000_000_000_000_000
  17 -> 100_000_000_000_000_000
  18 -> 1_000_000_000_000_000_000
  _ -> 10_000_000_000_000_000_000

-- | @10 ^ p@, from a table for the precisions SQL Server allows.
-- The decimal reader checks every value against it; computing it each time with
-- @(^)@ (about 1.5 KB of allocation for @10 ^ 38@) it made reading rows of
-- an @int@, an @nvarchar(50)@ and a @decimal@ a third slower.
powerOfTen :: Precision -> Integer
powerOfTen p
  | p <= 38 = Seq.index powersOfTen (fromIntegral p)
  | otherwise = 10 ^ p
{-# INLINE powerOfTen #-}

powersOfTen :: Seq.Seq Integer
powersOfTen = Seq.fromList (take 39 (iterate (* 10) 1))
{-# NOINLINE powersOfTen #-}

-- | A decimal at the precision and scale, rounded to the scale: the sign byte
-- and 'precisionToLength' bytes of magnitude.
putDecimal :: Precision -> Scale -> Decimal -> Put
putDecimal precision scale value = do
  let Decimal _ mantissa = roundTo scale value
  Put.putWord8 $ if mantissa < 0 then 0 else 1
  let n = precisionToLength precision
  mapM_ (\i -> Put.putWord8 $ fromIntegral $ (abs mantissa `shiftR` (8 * i)) .&. 0xFF) [0 .. n - 1]

------------------------------------------------------------------------------
-- uniqueidentifier

-- | @uniqueidentifier@.  The first three groups are little-endian on the
-- wire, unlike RFC 4122.
readGuid :: ValueReader UUID
readGuid bs
  | B.length bs /= 16 = invalidLength "uniqueidentifier" "16 bytes" (B.length bs)
  | otherwise = Right $! UUID.fromWords64 hi (word64BeAt bs 8)
  where
    hi = (fromIntegral (word32LeAt bs 0) `shiftL` 32) .|. (fromIntegral (word16LeAt bs 4) `shiftL` 16)
           .|. fromIntegral (word16LeAt bs 6) :: Word64

-- | The layout of 'readGuid', written.
putGuid :: UUID -> Put
putGuid u = do
  let (hi, lo) = UUID.toWords64 u
  Put.putWord32le $ fromIntegral (hi `shiftR` 32)
  Put.putWord16le $ fromIntegral (hi `shiftR` 16)
  Put.putWord16le $ fromIntegral hi
  Put.putWord64be lo

------------------------------------------------------------------------------
-- collation

-- | MS-TDS 2.2.5.1.2 Collation Rule Definition. Kept opaque: the LCID,
-- flags and version share a DWORD, followed by the sort ID byte.
data Collation = Collation
  { collationInfo :: !Word32
  , collationSortId :: !Word8
  }

instance Show Collation where
  showsPrec p (Collation a b) =
    showRecord p "Collation"# ["collationInfo"# := a, "collationSortId"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq Collation where
  Collation a b == Collation a' b' = a == a' && b == b'
  {-# OPAQUE (==) #-}

-- | The five bytes of a collation at an offset.
collationAt :: B.ByteString -> Int -> Collation
collationAt bs off = Collation (word32LeAt bs off) (word8At bs (off + 4))

-- | The five bytes of a collation.
putCollation :: Collation -> Put
putCollation (Collation info sortId) = Put.putWord32le info >> Put.putWord8 sortId

------------------------------------------------------------------------------
-- strings

-- | Decode UTF-16LE text from the server, never failing.
--
-- SQL Server stores and sends UCS-2 code units without validating them, so
-- a value can hold unpaired surrogates (@NCHAR(0xD800)@, a reversed pair, a
-- high surrogate cut off at the end of a string).  Following the Unicode
-- Standard's recommended practice (\"U+FFFD Substitution of Maximal
-- Subparts\", ch. 3), each ill-formed code unit becomes exactly one U+FFFD
-- and every well-formed scalar value decodes unchanged.  A trailing odd
-- byte (a truncated code unit) also becomes one U+FFFD.
--
-- @text@'s own 'T.decodeUtf16LE' throws on such input, and its
-- 'T.decodeUtf16LEWith' resynchronizes byte by byte, emitting one U+FFFD
-- per byte and then misreading the following units.
--
-- One pass writing UTF-8 into the 'Text' array, eight ASCII units at a
-- time ("Hmssql.Tds.Utf16").
decodeUtf16LE :: B.ByteString -> Text
decodeUtf16LE = Utf16.decodeUtf16LE
{-# INLINE decodeUtf16LE #-}

-- | Write text as UTF-16LE without a length prefix.
putUcs2 :: Text -> Put
putUcs2 = Put.putByteString . Utf16.encodeUtf16LE

-- | B_VARCHAR: one-byte character count followed by UCS-2 text.
-- Fails (with 'error') for text of more than 255 UTF-16 code units, which
-- the length byte can't count; check with 'ucs2Length' first.
putBVarChar :: Text -> Put
putBVarChar t = do
  let bs = Utf16.encodeUtf16LE t
      n = B.length bs `div` 2
  when (n > 0xFF) $
    error $ "putBVarChar: " ++ show n ++ " UTF-16 code units do not fit in a B_VARCHAR (at most 255)"
  Put.putWord8 $ fromIntegral n
  Put.putByteString bs

-- | US_VARCHAR: two-byte character count followed by UCS-2 text.
-- Fails (with 'error') for text of more than 65535 UTF-16 code units.
putUsVarChar :: Text -> Put
putUsVarChar t = do
  let bs = Utf16.encodeUtf16LE t
      n = B.length bs `div` 2
  when (n > 0xFFFF) $
    error $ "putUsVarChar: " ++ show n ++ " UTF-16 code units do not fit in a US_VARCHAR (at most 65535)"
  Put.putWord16le $ fromIntegral n
  Put.putByteString bs

-- | The length of text in UTF-16 code units, which is what B_VARCHAR and
-- US_VARCHAR count (a character outside the BMP is two).
ucs2Length :: Text -> Int
ucs2Length = Utf16.utf16Length
