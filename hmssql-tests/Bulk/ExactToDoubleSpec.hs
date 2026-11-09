module Bulk.ExactToDoubleSpec (spec) where

import Control.Monad (forM_)
import Data.Bits ((.|.))
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int32, Int64)
import Data.Ratio (denominator, numerator)
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Test.Hspec

import Bulk.Harness
import Hmssql
import Hmssql.Types (Money (..))
import TestDb

spec :: Spec
spec = around withTestDb $
    describe "exact source rounding to Double" $
        forM_ cases $ \(label, source, expected) ->
            it label $ \conn -> do
                (bulk, ordinary) <- createPair conn "float"
                let rows = [[SqlParam (1 :: Int32), source]]
                loadBatch conn ordinary rows `shouldReturn` [1]
                loadBulk conn bulk rows `shouldReturn` 1
                forM_ [("ordinary", ordinary), ("bulk", bulk)] $ \(path, table) -> do
                    Only value <- query1 conn (rawSql ("SELECT v FROM " <> table)) :: IO (Only Double)
                    (path, castDoubleToWord64 value) `shouldBe` (path, expected)

cases :: [(String, SqlParam, Word64)]
cases =
    concat
        [ concat [aroundMid "Int64" exponent 0 (SqlParam . (fromInteger :: Integer -> Int64)) | exponent <- [54, 62]]
        , concat [aroundMid "Integer decimal" exponent 0 (SqlParam :: Integer -> SqlParam) | exponent <- [80, 120]]
        , concat [aroundMid "Decimal" exponent scale (SqlParam . (Decimal (fromIntegral scale) :: Integer -> Decimal)) | (exponent, scale) <- [(0, 37), (50, 20), (100, 7)]]
        , aroundMid "Money" 49 4 (SqlParam . Money . MkFixed)
        ]

aroundMid :: String -> Int -> Int -> (Integer -> SqlParam) -> [(String, SqlParam, Word64)]
aroundMid label exponent scale wrap =
    [ ( label ++ " 2^" ++ show exponent ++ ", lower bits=" ++ show lower ++ ", sign=" ++ show sign ++ ", mantissa=" ++ show m
      , wrap (sign * m)
      , expectedBits lower sign (compare (fromInteger m / fromInteger factor) middle)
      )
    | parity <- [0, 1]
    , let lower = castDoubleToWord64 (encodeFloat 1 exponent :: Double) + parity
    , let middle = (toRational (castWord64ToDouble lower) + toRational (castWord64ToDouble (lower + 1))) / 2
    , let factor = 10 ^ scale
    , let scaled = middle * fromInteger factor
    , let floorMid = numerator scaled `div` denominator scaled
    , let offsets = if denominator scaled == 1 then [-1, 0, 1] else [0, 1]
    , sign <- [1, -1]
    , offset <- offsets
    , let m = floorMid + offset
    ]
expectedBits :: Word64 -> Integer -> Ordering -> Word64
expectedBits lower sign relation = magnitude .|. if sign < 0 then 0x8000000000000000 else 0
  where
    magnitude = if relation == LT || (relation == EQ && even lower) then lower else lower + 1
