-- Exact numeric sources need one rounding to real, not an intermediate
-- 53-bit Double rounding followed by a 24-bit Float rounding.
module Bulk.ExactToRealSpec (spec) where

import Control.Monad (forM_)
import Data.Bits ((.|.))
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int32, Int64)
import Data.Ratio (denominator, numerator)
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.Types (Money (..))
import TestDb

spec :: Spec
spec = around withTestDb $
    describe "exact source rounding to real" $
        forM_ cases $ \(label, source, expected) ->
            it label $ \conn -> do
                (bulk, ordinary) <- createPair conn "real"
                let rows = [[SqlParam (1 :: Int32), source]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                loadBulk conn bulk rows `shouldReturn` 1
                forM_ [ordinary, bulk] $ \table -> do
                    Only value <- query1 conn (rawSql ("SELECT v FROM " <> table)) :: IO (Only Float)
                    castFloatToWord32 value `shouldBe` expected

cases :: [(String, SqlParam, Word32)]
cases =
    concat
        [ integralCases "Int32 control" 30 (SqlParam . (fromInteger :: Integer -> Int32))
        , concat [integralCases "Int64" exponent (SqlParam . (fromInteger :: Integer -> Int64)) | exponent <- [54, 62]]
        , concat [integralCases "Integer decimal" exponent (SqlParam :: Integer -> SqlParam) | exponent <- [80, 120]]
        , fractionalCases "Decimal scale 37" 0 37 (SqlParam . (Decimal 37 :: Integer -> Decimal))
        , fractionalCases "Money" 42 4 (SqlParam . Money . MkFixed)
        ]

integralCases :: String -> Int -> (Integer -> SqlParam) -> [(String, SqlParam, Word32)]
integralCases label exponent wrap =
    [ (name label exponent lower sign delta, wrap (sign * (integerMid + delta)), nearestBits lower sign delta)
    | parity <- [0, 1]
    , let lower = castFloatToWord32 (encodeFloat 1 exponent :: Float) + parity
    , let integerMid = exactInteger (midpoint lower)
    , sign <- [1, -1]
    , delta <- [-1, 0, 1]
    ]

fractionalCases :: String -> Int -> Int -> (Integer -> SqlParam) -> [(String, SqlParam, Word32)]
fractionalCases label exponent scale wrap =
    [ (name label exponent lower sign delta, wrap (sign * (scaledMid + delta)), nearestBits lower sign delta)
    | parity <- [0, 1]
    , let lower = castFloatToWord32 (encodeFloat 1 exponent :: Float) + parity
    , let scaledMid = exactInteger (midpoint lower * fromInteger (10 ^ scale))
    , sign <- [1, -1]
    , delta <- [-1, 0, 1]
    ]

midpoint :: Word32 -> Rational
midpoint lower = (toRational (castWord32ToFloat lower) + toRational (castWord32ToFloat (lower + 1))) / 2
nearestBits :: Word32 -> Integer -> Integer -> Word32
nearestBits lower sign delta = magnitude .|. if sign < 0 then 0x80000000 else 0
  where
    magnitude = if delta < 0 || (delta == 0 && even lower) then lower else lower + 1
exactInteger :: Rational -> Integer
exactInteger value
    | denominator value == 1 = numerator value
    | otherwise = error "test midpoint is not integral at its chosen scale"
name :: String -> Int -> Word32 -> Integer -> Integer -> String
name label exponent lower sign delta = label ++ " 2^" ++ show exponent ++ ", lower bits=" ++ show lower ++ ", sign=" ++ show sign ++ ", midpoint delta=" ++ show delta
