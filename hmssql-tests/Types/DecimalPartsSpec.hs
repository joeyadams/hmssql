-- | 'decimalFieldDecoder' gives the parts of what the 'Decimal' decoder gives,
-- for every magnitude length, @money@, @smallmoney@ and the integer types, and
-- refuses what it refuses with the same message.
module Types.DecimalPartsSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Binary.Put as Put
import Data.Bits (shiftL, shiftR, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Word (Word64, Word8)
import Test.Hspec

import Hmssql.Decoding
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo (TypeInfo (..))

decode :: FieldDecoder a -> TypeInfo -> B.ByteString -> Either String a
decode d ti bytes = case compileField d defaultTdsContext (ColumnInfo "c" ti 1 0 Nothing) of
  Left e -> Left e
  Right c -> decodeCell c (Just bytes)

-- The 'Decimal' the parts make, under the built-in decoder's name.
fromParts :: FieldDecoder Decimal
fromParts = decimalFieldDecoder "Decimal" $ \negative hi lo scale ->
  let magnitude = (toInteger hi `shiftL` 64) .|. toInteger lo
   in Decimal scale (if negative then negate magnitude else magnitude)

parts :: FieldDecoder (Bool, Word64, Word64, Word8)
parts = decimalFieldDecoder "parts" (,,,)

-- A decimal's bytes: the sign byte, then the magnitude in this many bytes.
decimalBytes :: Int -> Integer -> B.ByteString
decimalBytes width m = B.pack $ (if m < 0 then 0 else 1)
  : [fromIntegral (abs m `shiftR` (8 * i)) | i <- [0 .. width - 1]]

bytesOf :: Put.Put -> B.ByteString
bytesOf = LB.toStrict . Put.runPut

agrees :: TypeInfo -> B.ByteString -> Expectation
-- Shown, so that the scale counts as well as the value.
agrees ti bytes = fmap show (decode fromParts ti bytes) `shouldBe` fmap show (decode (fieldDecoder @Decimal) ti bytes)

spec :: Spec
spec = do
  it "agrees with Decimal at every precision, scale and magnitude length" $
    forM_ [1, 5, 9, 10, 18, 19, 20, 28, 29, 38] $ \p -> forM_ [0, min p 4, p] $ \s -> do
      let ms = [0, 1, 7, 10 ^ (p - 1), 10 ^ p - 1] ++ [10 ^ (p `div` 2) + 3 | p > 2]
      forM_ (concatMap (\m -> [m, negate m]) ms) $ \m ->
        forM_ [4, 8, 12, 16] $ \width ->
          if abs m < 2 ^ (8 * width)
            then agrees (TIDecimalN (fromIntegral p) (fromIntegral s)) (decimalBytes width m)
            else pure ()

  it "gives a 64-bit magnitude in the low word and a larger one in both" $ do
    decode parts (TIDecimalN 38 2) (decimalBytes 16 (-12345)) `shouldBe` Right (True, 0, 12345, 2)
    decode parts (TINumericN 38 0) (decimalBytes 16 (2 ^ (64 :: Int) + 5)) `shouldBe` Right (False, 1, 5, 0)
    decode parts (TIDecimalN 9 3) (decimalBytes 4 4321) `shouldBe` Right (False, 0, 4321, 3)

  it "never gives a negative zero" $
    forM_ [4, 8, 12, 16] $ \width ->
      decode parts (TIDecimalN 38 2) (B.pack (0 : replicate width 0)) `shouldBe` Right (False, 0, 0, 2)

  it "refuses a bad length, a bad sign byte and too many digits with Decimal's message" $ do
    agrees (TIDecimalN 10 2) (B.pack [1, 0, 0, 0, 0, 0])
    agrees (TIDecimalN 10 2) (B.pack [2, 1, 0, 0, 0])
    agrees (TIDecimalN 5 0) (decimalBytes 4 100_000)
    agrees (TIDecimalN 25 0) (decimalBytes 12 (10 ^ (25 :: Int)))
    agrees (TIDecimalN 38 0) (decimalBytes 16 (2 ^ (127 :: Int)))
    decode fromParts (TIDecimalN 5 0) (decimalBytes 4 100_000) `shouldSatisfy` either (const True) (const False)

  it "gives money and smallmoney at scale 4, at their ends" $ do
    forM_ [minBound, -1, 0, 1, 123_456_789, maxBound :: Int64] $ \i -> do
      let bytes = bytesOf (putMoney8 (Money (MkFixed (toInteger i))))
      forM_ [TIMoney8, TIMoneyN 8] $ \ti -> agrees ti bytes
      decode parts TIMoney8 bytes `shouldBe` Right (i < 0, 0, fromInteger (abs (toInteger i)), 4)
    forM_ [minBound, -5, 0, maxBound :: Int32] $ \i -> do
      let bytes = bytesOf (putMoney4 (Money (MkFixed (toInteger i))))
      forM_ [TIMoney4, TIMoneyN 4] $ \ti -> agrees ti bytes
    agrees TIMoney8 (B.pack [1, 2, 3])

  it "gives the integer types at scale 0, at their ends" $ do
    forM_ [minBound, -1, 0, maxBound :: Int64] $ \i -> forM_ [TIInt8, TIIntN 8] $ \ti ->
      agrees ti (bytesOf (Put.putInt64le i))
    forM_ [minBound, maxBound :: Int32] $ \i -> agrees TIInt4 (bytesOf (Put.putInt32le i))
    forM_ [minBound, maxBound :: Int16] $ \i -> agrees TIInt2 (bytesOf (Put.putInt16le i))
    forM_ [0, 255 :: Word8] $ \i -> forM_ [TIInt1, TIIntN 1] $ \ti -> agrees ti (B.singleton i)
    forM_ [0, 1 :: Int8] $ \i -> agrees TIBit (B.singleton (fromIntegral i))
    decode parts TIInt8 (bytesOf (Put.putInt64le minBound)) `shouldBe` Right (True, 0, 2 ^ (63 :: Int), 0)
    agrees TIInt4 (B.pack [1, 2, 3])

  it "refuses a column Decimal refuses, with its message" $
    forM_ [TIFltN 8, TINVarChar 10 (Collation 0 0), TIDateN] $ \ti ->
      case (compileField fromParts defaultTdsContext (ColumnInfo "c" ti 1 0 Nothing), compileField (fieldDecoder @Decimal) defaultTdsContext (ColumnInfo "c" ti 1 0 Nothing)) of
        (Left a, Left b) -> a `shouldBe` b
        _ -> expectationFailure "accepted a column Decimal refuses"
