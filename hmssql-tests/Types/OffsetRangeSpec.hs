-- | A @datetimeoffset@ offset must be within ±14:00 (±840 minutes).  The
-- check must see the caller's offset, not the offset narrowed to the
-- wire's 16-bit minute count: a 'ZonedTime' 65,596 minutes ahead of UTC
-- wrapped to +01:00 and was sent, and a 'DateTimeOffset' offset of -32768
-- minutes passed the check because @abs minBound@ is negative.
module Types.OffsetRangeSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.Either (isLeft, isRight)
import Data.Int (Int16)
import Data.Maybe (isJust)
import Data.Time
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Encoding (encodeParam)
import Hmssql.Tds.Context
import TestDb

zonedAt :: Int -> ZonedTime
zonedAt mins = ZonedTime (LocalTime (fromGregorian 2020 6 15) (TimeOfDay 12 0 0)) (minutesToTimeZone mins)

dtoAt :: Int16 -> DateTimeOffset
dtoAt = DateTimeOffset (UTCTime (fromGregorian 2020 6 15) 43200)

encoded :: ToSqlField a => a -> Either String ()
encoded a = () <$ encodeParam fieldEncoder defaultTdsContext a

isEncodeError :: Either SomeException a -> Bool
isEncodeError = \case
  Left e -> isJust (fromException e :: Maybe EncodeError)
  Right _ -> False

-- | Offsets (in minutes) beyond ±14:00, including ones that wrap into range
-- as an Int16 (65536 + 60 is +01:00 modulo 2^16) or wrap to minBound.
badZoneOffsets :: [Int]
badZoneOffsets = [841, -841, 32767, 32768, -32768, -32769, 65536, 65536 + 60, -65536 - 60, 65536 * 7 - 840, maxBound, minBound]

spec :: Spec
spec = do
  describe "ZonedTime parameters" $ do
    it "refuse offsets beyond ±14:00, even ones that wrap into range as an Int16" $
      mapM_ (\m -> (m, encoded (zonedAt m)) `shouldSatisfy` (isLeft . snd)) badZoneOffsets
    it "accept offsets within ±14:00" $
      mapM_ (\m -> (m, encoded (zonedAt m)) `shouldSatisfy` (isRight . snd)) [-840, -1, 0, 60, 840]
    it "zonedTimeToDateTimeOffset keeps an out-of-range offset out of range" $
      mapM_ (\m -> (m, abs (toInteger (dtoOffsetMinutes (zonedTimeToDateTimeOffset (zonedAt m)))))
                     `shouldSatisfy` ((> 840) . snd)) badZoneOffsets

  describe "DateTimeOffset parameters" $ do
    it "refuse every Int16 offset beyond ±14:00, including minBound" $
      mapM_ (\m -> (m, encoded (dtoAt m)) `shouldSatisfy` (isLeft . snd)) [minBound, minBound + 1, -841, 841, maxBound]
    it "accept offsets within ±14:00" $
      mapM_ (\m -> (m, encoded (dtoAt m)) `shouldSatisfy` (isRight . snd)) [-840, 0, 840]

  describe "against the server" $ around withTestDb $ do
    it "an offset that wraps to +01:00 is an EncodeError, not sent as +01:00" $ \conn -> do
      r <- try (query conn ("SELECT " <> param (zonedAt (65536 + 60))) :: IO [Only DateTimeOffset])
      r `shouldSatisfy` isEncodeError
    it "a DateTimeOffset offset of minBound is an EncodeError" $ \conn -> do
      r <- try (query conn ("SELECT " <> param (dtoAt minBound)) :: IO [Only DateTimeOffset])
      r `shouldSatisfy` isEncodeError
    it "the extreme valid offsets round-trip" $ \conn -> do
      query conn (mkQuery "SELECT @p1, @p2" (dtoAt 840, dtoAt (-840))) `shouldReturn` [(dtoAt 840, dtoAt (-840))]
