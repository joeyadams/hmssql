-- | The time-family encoders and decoders ('putTime', 'putDateTime2',
-- 'putDateTimeOffset', 'getTime', 'getDateTime2', 'getDateTimeOffset') take
-- a scale, which [MS-TDS] 2.2.5.4.2 allows from 0 through 7.  Hmssql's own
-- callers pass 7 or a scale read (and checked) from the wire, but the
-- functions are exported, so they must be total: any other scale is a
-- 'Left' (encoders) or a failed 'Get' (decoders), never an exception
-- (@10 ^ negative@ for a scale above 12) or a value in some other unit.
module Wire.TimeScaleSpec (spec) where

import Wire.PrimitiveGet (getTime, getDateTime2, getDateTimeOffset)
import Control.Exception (SomeException, evaluate, try)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Either (isRight)
import Data.Int (Int64)
import Data.List (isInfixOf)
import Data.Time
import Test.Hspec

import Hmssql.Tds.Primitives

-- | The encoder's result, forced: 'Left' for an error, the length for a
-- value, or an exception if evaluating either throws.
forced :: Either String Put.Put -> IO (Either SomeException (Either String Int64))
forced r = try $ case r of
  Left e -> Left <$> evaluate (length e `seq` e)
  Right p -> Right <$> evaluate (LB.length (Put.runPut p))

-- | The decoder's outcome on the given bytes, forced.
decoded :: Show a => Get.Get a -> LB.ByteString -> IO (Either SomeException (Either String String))
decoded g bs = try $ evaluate $ case Get.runGetOrFail g bs of
  Left (_, _, e) -> length e `seq` Left e
  Right (_, _, a) -> let s = show a in length s `seq` Right s

isScaleError :: Either SomeException (Either String a) -> Bool
isScaleError = \case
  Right (Left e) -> "scale" `isInfixOf` e
  _ -> False

errorMentions :: String -> Either SomeException (Either String a) -> Bool
errorMentions what = \case
  Right (Left e) -> what `isInfixOf` e
  _ -> False

tod :: TimeOfDay
tod = TimeOfDay 12 34 56.789

lt :: LocalTime
lt = LocalTime (fromGregorian 2024 2 29) tod

dto :: DateTimeOffset
dto = DateTimeOffset (UTCTime (fromGregorian 2024 2 29) 45296.789) 60

-- | Enough bytes for any scale's encoding.
bytes :: LB.ByteString
bytes = LB.replicate 16 0

badScales :: [Scale]
badScales = [8, 9, 12, 13, 20, 255]

spec :: Spec
spec = do
  describe "encoders" $ do
    it "accept every scale from 0 through 7" $
      mapM_ (\s -> do
        r <- mapM forced [putTime s tod, putDateTime2 s lt, putDateTimeOffset s dto]
        r `shouldSatisfy` all (either (const False) isRight)) [0 .. 7]
    it "refuse a scale above 7 with a Left (putTime)" $
      mapM_ (\s -> forced (putTime s tod) >>= (`shouldSatisfy` isScaleError)) badScales
    it "refuse a scale above 7 with a Left (putDateTime2)" $
      mapM_ (\s -> forced (putDateTime2 s lt) >>= (`shouldSatisfy` isScaleError)) badScales
    it "refuse a scale above 7 with a Left (putDateTimeOffset)" $
      mapM_ (\s -> forced (putDateTimeOffset s dto) >>= (`shouldSatisfy` isScaleError)) badScales
    it "check the scale before the value" $ do
      forced (putTime 13 (TimeOfDay 25 0 0)) >>= (`shouldSatisfy` isScaleError)
      forced (putDateTime2 13 (LocalTime (fromGregorian 10000 1 1) tod)) >>= (`shouldSatisfy` isScaleError)
      forced (putDateTimeOffset 13 dto { dtoOffsetMinutes = 900 }) >>= (`shouldSatisfy` isScaleError)
    it "name the type in the error" $ do
      forced (putTime 8 tod) >>= (`shouldSatisfy` errorMentions "time")
      forced (putDateTime2 8 lt) >>= (`shouldSatisfy` errorMentions "datetime2")
      forced (putDateTimeOffset 8 dto) >>= (`shouldSatisfy` errorMentions "datetimeoffset")

  describe "decoders" $ do
    it "accept every scale from 0 through 7" $
      mapM_ (\s -> do
        a <- decoded (getTime s) bytes
        b <- decoded (getDateTime2 s) bytes
        c <- decoded (getDateTimeOffset s) bytes
        [a, b, c] `shouldSatisfy` all (either (const False) isRight)) [0 .. 7]
    it "fail on a scale above 7" $
      mapM_ (\s -> do
        a <- decoded (getTime s) bytes
        b <- decoded (getDateTime2 s) bytes
        c <- decoded (getDateTimeOffset s) bytes
        [a, b, c] `shouldSatisfy` all isScaleError) badScales
    it "name the type in the error" $ do
      decoded (getTime 8) bytes >>= (`shouldSatisfy` errorMentions "time")
      decoded (getDateTime2 8) bytes >>= (`shouldSatisfy` errorMentions "datetime2")
      decoded (getDateTimeOffset 8) bytes >>= (`shouldSatisfy` errorMentions "datetimeoffset")

  it "timeLength is total" $
    mapM_ (\s -> evaluate (timeLength s) >>= (`shouldSatisfy` (`elem` [3, 4, 5]))) [minBound .. maxBound]
