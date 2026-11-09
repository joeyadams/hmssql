-- | A @decimal@/@numeric@ value from the server ([MS-TDS] 2.2.5.5.1.3) is a
-- sign byte (0 negative, 1 positive) and a little-endian magnitude of 4, 8,
-- 12 or 16 bytes, below 10^precision.  The length is usually what the
-- precision needs (1-9, 10-19, 20-28, 29-38 digits), but SQL Server sends
-- 4 bytes for a @decimal(10,0)@ 0 from a table and 16 for a @decimal(1,0)@
-- in a @sql_variant@, so any of the four is valid.  Anything else is
-- malformed and must be a 'DecodeError', not a value (a sign byte of 2 read
-- as positive, a magnitude of 10^38 in a @decimal(5,2)@ column), in
-- columns, @sql_variant@ values and output parameters alike.
module Wire.DecimalValueSpec (spec) where

import qualified Data.ByteString as B
import Data.Bits (shiftR)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Either (isLeft)
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Decoding
import Hmssql.Tds.Context
import Hmssql.Tds.Token (ReturnValue (..))

col :: TypeInfo -> ColumnInfo
col ti = ColumnInfo "c" ti 0 0 Nothing

-- | Decode one non-NULL value of the given column type.
decodeAs :: FieldDecoder a -> TypeInfo -> B.ByteString -> Either String a
decodeAs fd ti bs = compileField fd defaultTdsContext (col ti) >>= \dec -> decodeCell dec (Just bs)

-- | Sign byte and an @n@-byte little-endian magnitude.
decimalBytes :: Word8 -> Int -> Integer -> B.ByteString
decimalBytes sign n mag = B.pack (sign : [fromIntegral (mag `shiftR` (8 * i)) | i <- [0 .. n - 1]])

-- | A @sql_variant@ holding a @decimal(p,s)@ value.
variantDecimal :: Word8 -> Word8 -> B.ByteString -> B.ByteString
variantDecimal p s v = B.pack [0x6A, 2, p, s] <> v

returnValue :: TypeInfo -> B.ByteString -> ReturnValue
returnValue ti bs = ReturnValue 1 "@x" 1 0 0 ti (Just bs)

-- | (precision, scale, value bytes) that are malformed.
malformed :: [(String, Word8, Word8, B.ByteString)]
malformed =
  [ ("sign byte 2", 5, 2, decimalBytes 2 4 1)
  , ("sign byte 0xFF", 38, 0, decimalBytes 0xFF 16 1)
  , ("3-byte magnitude", 5, 0, decimalBytes 1 3 1)
  , ("5-byte magnitude", 10, 0, decimalBytes 1 5 1)
  , ("13-byte magnitude", 38, 0, decimalBytes 1 13 1)
  , ("20-byte magnitude", 38, 0, decimalBytes 1 20 1)
  , ("no magnitude", 5, 0, B.pack [1])
  , ("empty", 5, 0, B.empty)
  , ("10^5 in decimal(5,2)", 5, 2, decimalBytes 1 4 (10 ^ (5 :: Int)))
  , ("-10^5 in decimal(5,0)", 5, 0, decimalBytes 0 4 (10 ^ (5 :: Int)))
  , ("10^9 in decimal(9,0)", 9, 0, decimalBytes 1 4 (10 ^ (9 :: Int)))
  , ("10^38 in decimal(38,0)", 38, 0, decimalBytes 1 16 (10 ^ (38 :: Int)))
  , ("2^128-1 in decimal(38,10)", 38, 10, decimalBytes 1 16 (2 ^ (128 :: Int) - 1))
  , ("2^32-1 in decimal(1,0)", 1, 0, decimalBytes 1 4 (2 ^ (32 :: Int) - 1))
  ]

spec :: Spec
spec = do
  describe "malformed decimal values are a DecodeError" $
    mapM_
      (\(label, p, s, bs) -> describe label $ do
        it "as Decimal (decimal and numeric)" $ do
          decodeAs (fieldDecoder @Decimal) (TIDecimalN p s) bs `shouldSatisfy` isLeft
          decodeAs (fieldDecoder @Decimal) (TINumericN p s) bs `shouldSatisfy` isLeft
        it "as SqlValue" $
          decodeAs (fieldDecoder @SqlValue) (TIDecimalN p s) bs `shouldSatisfy` isLeft
        it "as RawValue is unaffected (the bytes are passed through)" $
          decodeAs (fieldDecoder @RawValue) (TIDecimalN p s) bs `shouldSatisfy` either (const False) (const True)
        it "in a sql_variant" $
          decodeAs (fieldDecoder @SqlValue) (TISqlVariant 8016) (variantDecimal p s bs) `shouldSatisfy` isLeft
        it "as an output parameter (RETURNVALUE)" $ do
          (decodeReturnValue (returnValue (TIDecimalN p s) bs) :: Either DecodeError Decimal) `shouldSatisfy` isLeft
          (decodeReturnValue (returnValue (TISqlVariant 8016) (variantDecimal p s bs)) :: Either DecodeError SqlValue)
            `shouldSatisfy` isLeft)
      malformed
      >> it "as Integer (scale 0)" (do
        decodeAs (fieldDecoder @Integer) (TIDecimalN 5 0) (decimalBytes 2 4 1) `shouldSatisfy` isLeft
        decodeAs (fieldDecoder @Integer) (TIDecimalN 5 0) (decimalBytes 1 4 (10 ^ (5 :: Int))) `shouldSatisfy` isLeft
        decodeAs (fieldDecoder @Integer) (TIDecimalN 38 0) (decimalBytes 1 6 1) `shouldSatisfy` isLeft)

  describe "well-formed decimal values" $ do
    it "decode at the extremes of each length" $
      mapM_
        (\p -> do
          let n = if p <= 9 then 4 else if p <= 19 then 8 else if p <= 28 then 12 else 16
              top = 10 ^ (fromIntegral p :: Int) - 1
          decodeAs (fieldDecoder @Decimal) (TIDecimalN p 0) (decimalBytes 1 n top) `shouldBe` Right (Decimal 0 top)
          decodeAs (fieldDecoder @Decimal) (TIDecimalN p 0) (decimalBytes 0 n top) `shouldBe` Right (Decimal 0 (negate top))
          decodeAs (fieldDecoder @SqlValue) (TISqlVariant 8016) (variantDecimal p 0 (decimalBytes 1 n top))
            `shouldBe` Right (SqlDecimal (Decimal 0 top)))
        [1, 9, 10, 19, 20, 28, 29, 38]
    it "a magnitude of another length than the precision needs (as SQL Server sends)" $ do
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 1 0) (decimalBytes 1 16 0) `shouldBe` Right 0
      decodeAs (fieldDecoder @SqlValue) (TISqlVariant 8016) (variantDecimal 1 0 (decimalBytes 0 16 9)) `shouldBe` Right (SqlDecimal (-9))
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 5 2) (decimalBytes 1 8 99999) `shouldBe` Right (Decimal 2 99999)
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 10 0) (decimalBytes 1 4 0) `shouldBe` Right 0
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 38 2) (decimalBytes 0 8 12345) `shouldBe` Right (Decimal 2 (-12345))
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 38 0) (decimalBytes 1 12 (10 ^ (28 :: Int))) `shouldBe` Right (Decimal 0 (10 ^ (28 :: Int)))
    it "negative zero is zero" $
      decodeAs (fieldDecoder @Decimal) (TIDecimalN 5 2) (decimalBytes 0 4 0) `shouldBe` Right 0
    it "an output parameter decodes" $
      (decodeReturnValue (returnValue (TIDecimalN 5 2) (decimalBytes 0 4 12345)) :: Either DecodeError Decimal)
        `shouldBe` Right (Decimal 2 (-12345))

  it "arbitrary bytes decode to a value within the column's precision, or fail" $ hedgehog $ do
    p <- forAll $ Gen.word8 (Range.linear 1 38)
    s <- forAll $ Gen.word8 (Range.linear 0 p)
    bs <- forAll $ Gen.choice
      [ Gen.bytes (Range.linear 0 20)
      , (\sign mag -> decimalBytes sign (if p <= 9 then 4 else if p <= 19 then 8 else if p <= 28 then 12 else 16) mag)
          <$> Gen.element [0, 1, 2] <*> Gen.integral (Range.exponential 0 (10 ^ (fromIntegral p :: Int) + 5))
      ]
    case decodeAs (fieldDecoder @Decimal) (TIDecimalN p s) bs of
      Left _ -> success
      Right (Decimal s' m) -> do
        s' === s
        assert (abs m < 10 ^ (fromIntegral p :: Int))
        assert (B.length bs `elem` [5, 9, 13, 17])
        assert (B.head bs <= 1)
