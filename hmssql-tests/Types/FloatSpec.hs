-- | @float@/@real@ result decoding: exact bit patterns, extreme finite
-- values, subnormals, sign of zero, NaN\/Infinity as parameters, the
-- Float-vs-Double decoding rules, and nullable @FLTN@ columns.
module Types.FloatSpec (spec) where

import Control.Exception (try)
import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castFloatToWord32, castWord32ToFloat, castWord64ToDouble)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestConfig

spec :: Spec
spec = around withTestDb $ do
  describe "float(53)/double" $ do
    it "round-trips arbitrary finite bit patterns exactly" $ \conn -> liveHedgehog $ do
      w <- forAll $ Gen.filter (not . isNonFinite . castWord64ToDouble) (Gen.word64 Range.linearBounded)
      let d = castWord64ToDouble w
      Only d' <- evalIO $ query1 conn ("SELECT " <> param d)
      castDoubleToWord64 d' === w

    it "round-trips min and max finite values" $ \conn -> do
      let vMax = castWord64ToDouble 0x7FEFFFFFFFFFFFFF -- DBL_MAX
          vMin = castWord64ToDouble 0xFFEFFFFFFFFFFFFF -- most negative finite
      r <- query1 conn (mkQuery "SELECT @p1, @p2" (vMax, vMin))
      r `shouldBe` (vMax, vMin)

    it "round-trips the smallest normal and smallest subnormal" $ \conn -> do
      let normal = castWord64ToDouble 0x0010000000000000 -- DBL_MIN (smallest normal)
          subnormal = castWord64ToDouble 1 -- smallest positive subnormal
      r <- query1 conn (mkQuery "SELECT @p1, @p2" (normal, subnormal))
      r `shouldBe` (normal, subnormal)

    it "preserves the sign of zero" $ \conn -> do
      Only negZero <- query1 conn ("SELECT " <> param (-0.0 :: Double))
      castDoubleToWord64 negZero `shouldBe` castDoubleToWord64 (-0.0 :: Double)
      Only posZero <- query1 conn ("SELECT " <> param (0.0 :: Double))
      castDoubleToWord64 posZero `shouldBe` (0 :: Word64)

    it "rejects NaN as a parameter with a clean server error, not corruption" $ \conn -> do
      r <- try (query1 conn ("SELECT " <> param (0 / 0 :: Double))) :: IO (Either SqlServerError (Only Double))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8023
        Right v -> expectationFailure ("expected a clean server error, got " ++ show v)

    it "rejects +Infinity and -Infinity as parameters with a clean server error" $ \conn -> do
      rp <- try (query1 conn ("SELECT " <> param (1 / 0 :: Double))) :: IO (Either SqlServerError (Only Double))
      rn <- try (query1 conn ("SELECT " <> param (-1 / 0 :: Double))) :: IO (Either SqlServerError (Only Double))
      case (rp, rn) of
        (Left ep, Left en) -> do
          sqlErrorNumber ep `shouldBe` 8023
          sqlErrorNumber en `shouldBe` 8023
        other -> expectationFailure ("expected clean server errors, got " ++ show other)

    it "decodes float(25..53) columns, which are 8 bytes on the wire" $ \conn -> do
      -- 1.0e0 forces float division (full double precision); a plain "1.0/3"
      -- would divide as decimal first, rounding to 6 fractional digits.
      r <- query1 conn "SELECT CAST(1.0e0 / 3 AS float(53))"
      r `shouldBe` Only (1 / 3 :: Double)

    it "decodes a NULL FLTN(8) column as Nothing" $ \conn -> do
      _ <- execute conn "CREATE TABLE #fltn8 (v float NULL)"
      _ <- execute conn "INSERT INTO #fltn8 VALUES (NULL), (1.5)"
      rows <- query conn "SELECT v FROM #fltn8 ORDER BY v"
      rows `shouldBe` [Only (Nothing :: Maybe Double), Only (Just 1.5)]

  describe "float(1..24)/real" $ do
    it "round-trips arbitrary finite bit patterns exactly" $ \conn -> liveHedgehog $ do
      w <- forAll $ Gen.filter (not . isNonFinite . castWord32ToFloat) (Gen.word32 Range.linearBounded)
      let f = castWord32ToFloat w
      Only f' <- evalIO $ query1 conn ("SELECT " <> param f)
      castFloatToWord32 f' === w

    it "round-trips min and max finite values" $ \conn -> do
      let vMax = castWord32ToFloat 0x7F7FFFFF -- FLT_MAX
          vMin = castWord32ToFloat 0xFF7FFFFF -- most negative finite
      r <- query1 conn (mkQuery "SELECT @p1, @p2" (vMax, vMin))
      r `shouldBe` (vMax, vMin)

    it "round-trips the smallest normal and smallest subnormal" $ \conn -> do
      let normal = castWord32ToFloat 0x00800000 -- FLT_MIN (smallest normal)
          subnormal = castWord32ToFloat 1 -- smallest positive subnormal
      r <- query1 conn (mkQuery "SELECT @p1, @p2" (normal, subnormal))
      r `shouldBe` (normal, subnormal)

    it "preserves the sign of zero" $ \conn -> do
      Only negZero <- query1 conn ("SELECT " <> param (-0.0 :: Float))
      castFloatToWord32 negZero `shouldBe` castFloatToWord32 (-0.0 :: Float)

    it "rejects NaN as a parameter with a clean server error" $ \conn -> do
      r <- try (query1 conn ("SELECT " <> param (0 / 0 :: Float))) :: IO (Either SqlServerError (Only Float))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8023
        Right v -> expectationFailure ("expected a clean server error, got " ++ show v)

    it "decodes float(1..24)/real columns, which are 4 bytes on the wire" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.5 AS real), CAST(1.5 AS float(24)), CAST(1.5 AS float(1))"
      r `shouldBe` (1.5 :: Float, 1.5 :: Float, 1.5 :: Float)

    it "decodes a NULL real column as Nothing" $ \conn -> do
      _ <- execute conn "CREATE TABLE #real1 (v real NULL)"
      _ <- execute conn "INSERT INTO #real1 VALUES (NULL), (1.5)"
      rows <- query conn "SELECT v FROM #real1 ORDER BY v"
      rows `shouldBe` [Only (Nothing :: Maybe Float), Only (Just 1.5)]

  describe "Float vs Double decoding rules" $ do
    it "rejects float(25..53) columns for Float, since they are 8 bytes" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1.5 AS float(53))") :: IO (Either DecodeError (Only Float))
      case r of
        Left (DecodeError _ msg) -> unless ("Double" `isInfixOf` msg) $
          expectationFailure ("unexpected message: " ++ msg)
        Right v -> expectationFailure ("decoded " ++ show v)

    it "accepts float(1..24)/real columns for both Float and Double" $ \conn -> do
      rf <- query1 conn "SELECT CAST(1.5 AS real)"
      rf `shouldBe` Only (1.5 :: Float)
      rd <- query1 conn "SELECT CAST(1.5 AS real)"
      rd `shouldBe` Only (1.5 :: Double)

isNonFinite :: RealFloat a => a -> Bool
isNonFinite x = isNaN x || isInfinite x
