-- | Pure round-trip properties for every 'TypeInfo' constructor and the
-- value encodings ('putValue'\/'getValue') that go with each one, including
-- every NULL representation the wire format has. No server needed.
module Wire.TypeInfoSpec
  ( spec
    -- * Generators reused by other Wire specs
  , genTypeInfo
  , genValueFor
  , genScale
  , genCollation
  , genText
  , genPrecisionScale
  ) where

import Wire.RecipeGet (getTypeInfo, getValue)
import Control.Monad (forM_)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import Data.Word (Word16, Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog
import TestDb (withCases, withCasesSlow)

import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.TypeInfo

import Wire.Util

------------------------------------------------------------------------------
-- Generators

genCollation :: Gen Collation
genCollation = Collation <$> Gen.word32 Range.linearBounded <*> Gen.word8 Range.linearBounded

genText :: Gen T.Text
genText = Gen.text (Range.linear 0 40) Gen.unicode

genScale :: Gen Scale
genScale = Gen.word8 (Range.linear 0 7)

-- | 1 <= precision <= 38, scale <= precision.
genPrecisionScale :: Gen (Precision, Scale)
genPrecisionScale = do
  p <- Gen.word8 (Range.linear 1 38)
  s <- Gen.word8 (Range.linear 0 p)
  pure (p, s)

-- | A char/binary length: 0 (an empty fixed-length value, legal on the wire
-- even though the server never declares it), a small length, and 8000 (the
-- boundary where the server would have to switch to @(max)@).
genFixedLen :: Gen Word16
genFixedLen = Gen.choice [pure 0, Gen.word16 (Range.linear 1 7999), pure 8000]

-- | Like 'genFixedLen', plus 'maxLength' (@0xFFFF@, the @(max)@ sentinel).
genVarLen :: Gen Word16
genVarLen = Gen.choice [genFixedLen, pure maxLength]

genLongLen :: Gen Word32
genLongLen = Gen.word32 Range.linearBounded

-- | Every 'TypeInfo' constructor, with a variety of lengths/precisions/scales.
genTypeInfo :: Gen TypeInfo
genTypeInfo = Gen.choice
  [ Gen.element
      [ TINull, TIBit, TIInt1, TIInt2, TIInt4, TIInt8
      , TIMoney4, TIMoney8, TIDateTime4, TIDateTime8, TIFlt4, TIFlt8
      ]
  , pure TIBitN
  , TIIntN <$> Gen.element [1, 2, 4, 8]
  , TIMoneyN <$> Gen.element [4, 8]
  , TIDateTimeN <$> Gen.element [4, 8]
  , TIFltN <$> Gen.element [4, 8]
  , pure TIGuid
  , uncurry TIDecimalN <$> genPrecisionScale
  , uncurry TINumericN <$> genPrecisionScale
  , pure TIDateN
  , TITimeN <$> genScale
  , TIDateTime2N <$> genScale
  , TIDateTimeOffsetN <$> genScale
  , TIBigChar <$> genFixedLen <*> genCollation
  , TIBigVarChar <$> genVarLen <*> genCollation
  , TIText <$> genLongLen <*> genCollation
  , TINChar <$> genFixedLen <*> genCollation
  , TINVarChar <$> genVarLen <*> genCollation
  , TINText <$> genLongLen <*> genCollation
  , TIBigBinary <$> genFixedLen
  , TIBigVarBinary <$> genVarLen
  , TIImage <$> genLongLen
  , pure (TIXml Nothing)
  , TIXml . Just <$> (XmlSchema <$> genText <*> genText <*> genText)
  , TISqlVariant <$> genLongLen
  ]

-- | A raw value shaped correctly for the given type (the exact bytes are
-- opaque to the framing logic under test).
genValueFor :: TypeInfo -> Gen RawBytes
genValueFor ti = case ti of
  TINull -> pure Nothing
  TIBit -> fixed 1
  TIInt1 -> fixed 1
  TIInt2 -> fixed 2
  TIInt4 -> fixed 4
  TIInt8 -> fixed 8
  TIMoney4 -> fixed 4
  TIMoney8 -> fixed 8
  TIDateTime4 -> fixed 4
  TIDateTime8 -> fixed 8
  TIFlt4 -> fixed 4
  TIFlt8 -> fixed 8

  TIBitN -> nOrNull 1
  TIIntN n -> nOrNull (fromIntegral n)
  TIMoneyN n -> nOrNull (fromIntegral n)
  TIDateTimeN n -> nOrNull (fromIntegral n)
  TIFltN n -> nOrNull (fromIntegral n)
  TIGuid -> nOrNull 16
  TIDecimalN p _ -> nOrNull (precisionToLength p + 1)
  TINumericN p _ -> nOrNull (precisionToLength p + 1)
  TIDateN -> nOrNull 3
  TITimeN s -> nOrNull (timeLength s)
  TIDateTime2N s -> nOrNull (timeLength s + 3)
  TIDateTimeOffsetN s -> nOrNull (timeLength s + 5)

  TIBigChar len _ -> shortOrNull (fromIntegral len)
  TIBigVarChar len _ | len == maxLength -> plp
                      | otherwise -> shortOrNull (fromIntegral len)
  TIText _ _ -> longOrNull
  TINChar len _ -> shortOrNull (fromIntegral len)
  TINVarChar len _ | len == maxLength -> plp
                    | otherwise -> shortOrNull (fromIntegral len)
  TINText _ _ -> longOrNull

  TIBigBinary len -> shortOrNull (fromIntegral len)
  TIBigVarBinary len | len == maxLength -> plp
                      | otherwise -> shortOrNull (fromIntegral len)
  TIImage _ -> longOrNull

  TIXml _ -> plp
  -- A non-NULL sql_variant always carries at least its base type and
  -- property-length bytes ([MS-TDS] 2.2.5.5.4).
  TISqlVariant _ -> Gen.choice [pure Nothing, Just <$> Gen.bytes (Range.linear 2 60)]
  TIUdt _ -> plp
  where
    fixed n = Just <$> Gen.bytes (Range.singleton n)
    nOrNull n = Gen.frequency [(1, pure Nothing), (4, Just <$> Gen.bytes (Range.singleton n))]
    shortOrNull n = Gen.frequency [(1, pure Nothing), (4, Just <$> Gen.bytes (Range.singleton n))]
    longOrNull = Gen.frequency [(1, pure Nothing), (4, Just <$> Gen.bytes (Range.linear 0 40))]
    plp = Gen.frequency [(1, pure Nothing), (4, Just <$> Gen.bytes (Range.linear 0 20000))]

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "TYPE_INFO" $ do
    withCases 2000 $
      it "round-trips every constructor" $ hedgehog $ do
        ti <- forAll genTypeInfo
        roundTrip (putTypeInfo defaultTdsContext) (getTypeInfo defaultTdsContext) ti

    withCasesSlow 500 2000 $
      it "round-trips a value shaped for its type, including NULLs" $ hedgehog $ do
        ti <- forAll genTypeInfo
        v <- forAll (genValueFor ti)
        roundTrip (putValue defaultTdsContext ti) (getValue defaultTdsContext ti) v

  describe "NULL encodings, by wire shape" $ do
    it "N-type (ByteLen): length byte 0 is NULL" $ do
      let bytes = Put.runPut (Put.putWord8 0)
      Get.runGet (getValue defaultTdsContext (TIIntN 4)) bytes `shouldBe` Nothing

    it "UShortCharBin: 0xFFFF is NULL" $ do
      let bytes = Put.runPut (Put.putWord16le 0xFFFF)
      Get.runGet (getValue defaultTdsContext (TIBigVarChar 100 (Collation 0 0))) bytes `shouldBe` Nothing

    it "UShortCharBin: length 0 is an empty value, not NULL" $ do
      let bytes = Put.runPut (Put.putWord16le 0)
      Get.runGet (getValue defaultTdsContext (TIBigVarChar 100 (Collation 0 0))) bytes `shouldBe` Just B.empty

    it "LongLen: 0xFFFFFFFF is NULL" $ do
      let bytes = Put.runPut (Put.putWord32le 0xFFFFFFFF)
      Get.runGet (getValue defaultTdsContext (TIText 1000 (Collation 0 0))) bytes `shouldBe` Nothing

    it "VariantLen: 0 is NULL" $ do
      let bytes = Put.runPut (Put.putWord32le 0)
      Get.runGet (getValue defaultTdsContext (TISqlVariant 8016)) bytes `shouldBe` Nothing

    it "VariantLen: 0xFFFFFFFF also decodes as NULL" $ do
      -- putValue never emits this sentinel for sql_variant, but getValue
      -- accepts it (defensive parsing of a value hmssql never produces).
      let bytes = Put.runPut (Put.putWord32le 0xFFFFFFFF)
      Get.runGet (getValue defaultTdsContext (TISqlVariant 8016)) bytes `shouldBe` Nothing

    it "PLP: 0xFFFFFFFFFFFFFFFF is NULL" $ do
      let bytes = Put.runPut (Put.putWord64le 0xFFFFFFFFFFFFFFFF)
      Get.runGet (getValue defaultTdsContext (TIXml Nothing)) bytes `shouldBe` Nothing

    it "PLP: a known total length of 0 is an empty value" $ do
      let bytes = Put.runPut (Put.putWord64le 0 >> Put.putWord32le 0)
      Get.runGet (getValue defaultTdsContext (TIXml Nothing)) bytes `shouldBe` Just B.empty

  describe "PLP chunking" $ do
    it "sends a large value as one chunk" $ do
      let ti = TIBigVarBinary maxLength
          v = Just (B.replicate 20000 0xAB)
          bytes = Put.runPut (putValue defaultTdsContext ti v)
      -- 8-byte total length, one 4-byte chunk length, the data itself, and
      -- a 4-byte zero terminator.
      LB.length bytes `shouldBe` 8 + 4 + 20000 + 4
      Get.runGet (getValue defaultTdsContext ti) bytes `shouldBe` v

    it "round-trips around 8000 bytes (the chunk size it used to have)" $ do
      let ti = TIBigVarBinary maxLength
      forM_ [7999, 8000, 8001, 16000, 16001] $ \n -> do
        let v = Just (B.replicate n 0x5A)
            bytes = Put.runPut (putValue defaultTdsContext ti v)
        Get.runGet (getValue defaultTdsContext ti) bytes `shouldBe` v

    it "reads unknown-length PLP terminated by a zero-length chunk" $ hedgehog $ do
      chunks <- forAll $ Gen.list (Range.linear 0 6) (Gen.bytes (Range.linear 1 20))
      let bytes = Put.runPut $ do
            Put.putWord64le 0xFFFFFFFFFFFFFFFE
            mapM_ (\c -> Put.putWord32le (fromIntegral (B.length c)) >> Put.putByteString c) chunks
            Put.putWord32le 0
      Get.runGet (getValue defaultTdsContext (TINVarChar maxLength (Collation 0 0))) bytes
        === Just (B.concat chunks)

    it "an unknown-length PLP with only the terminator is an empty value" $ do
      let bytes = Put.runPut (Put.putWord64le 0xFFFFFFFFFFFFFFFE >> Put.putWord32le 0)
      Get.runGet (getValue defaultTdsContext (TINVarChar maxLength (Collation 0 0))) bytes `shouldBe` Just B.empty

  describe "invalid TYPE_INFO" $ do
    it "rejects an IntN length outside {1,2,4,8}" $ hedgehog $ do
      n <- forAll $ Gen.filter (`notElem` [1, 2, 4, 8]) (Gen.word8 Range.linearBounded)
      let bytes = Put.runPut (Put.putWord8 0x26 >> Put.putWord8 n)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> annotate ("accepted: " ++ show ti) >> failure

    it "rejects decimal precision 0" $ do
      let bytes = Put.runPut (Put.putWord8 0x6A >> Put.putWord8 5 >> Put.putWord8 0 >> Put.putWord8 0)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    it "rejects decimal precision > 38" $ do
      let bytes = Put.runPut (Put.putWord8 0x6A >> Put.putWord8 17 >> Put.putWord8 39 >> Put.putWord8 0)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    it "rejects decimal scale > precision" $ do
      let bytes = Put.runPut (Put.putWord8 0x6A >> Put.putWord8 5 >> Put.putWord8 4 >> Put.putWord8 5)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    it "rejects a time-family scale > 7" $ do
      let bytes = Put.runPut (Put.putWord8 0x29 >> Put.putWord8 8)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    it "rejects an unknown type code" $ do
      let bytes = Put.runPut (Put.putWord8 0x99)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left (_, _, err) -> err `shouldContain` "unknown data type"
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    -- A complete UDT_INFO is read ("Wire.UdtSpec"), so values of CLR
    -- user-defined types can be stepped over; only a truncated one fails.
    it "rejects a CLR UDT (0xF0) without its UDT_INFO, not a crash" $ do
      let bytes = Put.runPut (Put.putWord8 0xF0)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left _ -> pure ()
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)

    it "reports TVP (0xF3) as unsupported, not a crash" $ do
      let bytes = Put.runPut (Put.putWord8 0xF3)
      case Get.runGetOrFail (getTypeInfo defaultTdsContext) bytes of
        Left (_, _, err) -> err `shouldContain` "table-valued"
        Right (_, _, ti) -> expectationFailure ("accepted: " ++ show ti)
