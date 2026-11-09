-- | @money@/@smallmoney@ result decoding: bounds, the historical sign bug in
-- the low DWORD of @money@'s two-DWORD wire encoding, 4-decimal precision,
-- rounding when a @Decimal@ parameter is cast to @money@, and decoding into
-- 'Money', 'Decimal' and 'Double'.
module Types.MoneySpec (spec) where

import Control.Exception (try)
import Data.Decimal (Decimal)
import Data.Fixed (Fixed (..))
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestConfig

-- | Render a money mantissa (1\/10000ths) as an exact decimal literal, e.g.
-- @-1@ (i.e. -0.0001) as @"-0.0001"@.
moneyLiteral :: Integer -> Text
moneyLiteral mantissa =
  let sign = if mantissa < 0 then "-" else ""
      mag = abs mantissa
      intPart = mag `div` 10000
      fracPart = mag `mod` 10000
   in sign <> T.pack (show intPart) <> "." <> T.pack (pad4 (show fracPart))
  where
    pad4 s = replicate (4 - length s) '0' ++ s

moneyOf :: Integer -> Money
moneyOf = Money . MkFixed

spec :: Spec
spec = around withTestDb $ do
  describe "money bounds" $ do
    it "decodes the documented min and max" $ \conn -> do
      r <- query1 conn "SELECT CAST(922337203685477.5807 AS money), CAST(-922337203685477.5808 AS money)"
      r `shouldBe` (moneyOf 9223372036854775807, moneyOf (-9223372036854775808))

    it "round-trips the min and max as parameters" $ \conn -> do
      let vMax = moneyOf 9223372036854775807
          vMin = moneyOf (-9223372036854775808)
      r <- query1 conn (mkQuery "SELECT @p1, @p2" (vMax, vMin))
      r `shouldBe` (vMax, vMin)

  describe "smallmoney bounds" $ do
    it "decodes the documented min and max" $ \conn -> do
      r <- query1 conn "SELECT CAST(214748.3647 AS smallmoney), CAST(-214748.3648 AS smallmoney)"
      r `shouldBe` (moneyOf 2147483647, moneyOf (-2147483648))

  describe "the historical low-DWORD sign bug" $ do
    -- money is two little-endian DWORDs, high half first (MS-TDS 2.2.5.5.1.7).
    -- A value whose low 32 bits of the 64-bit mantissa are nonzero, combined
    -- with a negative sign, is exactly what exposed mssql's bug.
    it "decodes negative values with a nonzero low DWORD" $ \conn -> do
      -- mantissa -1 = 0xFFFFFFFFFFFFFFFF: both DWORDs are 0xFFFFFFFF
      r1 <- query1 conn "SELECT CAST(-0.0001 AS money)"
      r1 `shouldBe` Only (moneyOf (-1))
      -- low DWORD 0x00000001, high DWORD 0xFFFFFFFF (mantissa just below -2^32)
      r2 <- query1 conn (rawSql ("SELECT CAST(" <> moneyLiteral (negate (4294967295)) <> " AS money)"))
      r2 `shouldBe` Only (moneyOf (-4294967295))

    it "round-trips arbitrary negative mantissas with a nonzero low DWORD" $ \conn -> liveHedgehog $ do
      m <- forAll $ Gen.integral (Range.linearFrom 0 (-9223372036854775808) (-1))
      Only r <- evalIO $ query1 conn (rawSql ("SELECT CAST(" <> moneyLiteral m <> " AS money)"))
      r === moneyOf m

  describe "4-decimal precision" $ do
    it "keeps exactly 4 decimal digits" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.2345 AS money)"
      r `shouldBe` Only (moneyOf 12345)

    it "rounds a decimal cast to money half away from zero beyond 4 places" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.00005 AS money), CAST(1.00004 AS money), CAST(-1.00005 AS money)"
      r `shouldBe` (moneyOf 10001, moneyOf 10000, moneyOf (-10001))

    it "rounds a Decimal parameter with more than 4 decimals when cast to money" $ \conn -> do
      r <- query1 conn ("SELECT CAST(" <> param (1.00005 :: Decimal) <> " AS money)")
      r `shouldBe` Only (moneyOf 10001)

  describe "decoding rules" $ do
    it "decodes money into Decimal" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.5 AS money)"
      r `shouldBe` Only (1.5 :: Decimal)

    it "decodes smallmoney into Decimal" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.5 AS smallmoney)"
      r `shouldBe` Only (1.5 :: Decimal)

    it "rejects money decoded as Double" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1.5 AS money)") :: IO (Either DecodeError (Only Double))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "Double"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "decodes a NULL nullable money column as Nothing" $ \conn -> do
      _ <- execute conn "CREATE TABLE #moneyn (v money NULL)"
      _ <- execute conn "INSERT INTO #moneyn VALUES (NULL), (1.5)"
      rows <- query conn "SELECT v FROM #moneyn ORDER BY v"
      rows `shouldBe` [Only (Nothing :: Maybe Money), Only (Just (moneyOf 15000))]
