-- | @decimal@/@numeric@ column (result) decoding at every precision 1-38
-- (crossing the 5\/9\/13\/17-byte storage-length boundaries at precision
-- 9\/10, 19\/20 and 28\/29), scale 0, @p\/2@ and @p@, zero and negative
-- zero, and the decoding rules into 'Decimal', 'Integer', 'Double', 'Int'
-- and 'SqlValue'.
module Types.DecimalColumnSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Errors
import TestConfig

-- | An exact decimal literal of @precision@ digits at @scale@, all nines
-- (or all zero, when @allZero@), optionally negated.
digitsLiteral :: Int -> Int -> Bool -> Bool -> Text
digitsLiteral precision scale allZero neg =
  let digit = if allZero then '0' else '9'
      digits = replicate precision digit
      (intPart, fracPart) = splitAt (precision - scale) digits
      intPart' = if null intPart then "0" else intPart
      body = if scale == 0 then intPart' else intPart' ++ "." ++ fracPart
   in T.pack ((if neg && not allZero then "-" else "") ++ body)

expectedDecimal :: Int -> Int -> Bool -> Decimal
expectedDecimal precision scale neg = Decimal (fromIntegral scale) (if neg then negate mantissa else mantissa)
  where
    mantissa = (10 ^ precision) - 1

castLiteral :: Int -> Int -> Text -> Text
castLiteral precision scale lit =
  "CAST('" <> lit <> "' AS decimal(" <> T.pack (show precision) <> "," <> T.pack (show scale) <> "))"

-- Storage-length boundaries: precision 9/10, 19/20, 28/29, plus the extremes.
boundaryPrecisions :: [Int]
boundaryPrecisions = [1, 9, 10, 19, 20, 28, 29, 38]

spec :: Spec
spec = around withTestDb $ do
  describe "every precision 1..38 at scale 0" $
    it "round-trips the all-nines max and min" $ \conn ->
      forM_ [1 .. 38] $ \p -> do
        let q = "SELECT " <> castLiteral p 0 (digitsLiteral p 0 False False)
                <> ", " <> castLiteral p 0 (digitsLiteral p 0 False True)
        r <- query1 conn (rawSql q)
        r `shouldBe` (expectedDecimal p 0 False, expectedDecimal p 0 True)

  describe "boundary precisions at scale p/2 and scale p" $ do
    it "round-trips the all-nines max and min at scale p/2" $ \conn ->
      forM_ boundaryPrecisions $ \p -> do
        let s = p `div` 2
            q = "SELECT " <> castLiteral p s (digitsLiteral p s False False)
                <> ", " <> castLiteral p s (digitsLiteral p s False True)
        r <- query1 conn (rawSql q)
        r `shouldBe` (expectedDecimal p s False, expectedDecimal p s True)

    it "round-trips the all-nines max and min at scale p (fully fractional)" $ \conn ->
      forM_ boundaryPrecisions $ \p -> do
        let q = "SELECT " <> castLiteral p p (digitsLiteral p p False False)
                <> ", " <> castLiteral p p (digitsLiteral p p False True)
        r <- query1 conn (rawSql q)
        r `shouldBe` (expectedDecimal p p False, expectedDecimal p p True)

  describe "zero" $ do
    it "decodes zero at every boundary precision and a few scales" $ \conn ->
      forM_ boundaryPrecisions $ \p ->
        forM_ [0, p `div` 2, p] $ \s -> do
          r <- query1 conn (rawSql ("SELECT " <> castLiteral p s (digitsLiteral p s True False)))
          r `shouldBe` Only (Decimal (fromIntegral s) 0 :: Decimal)

    it "normalizes negative zero to positive zero, like the server's own literals" $ \conn -> do
      r <- query1 conn "SELECT CAST('-0.00' AS decimal(5,2)), CAST(-0.0 AS decimal(5,2))"
      r `shouldBe` (Decimal 2 0 :: Decimal, Decimal 2 0 :: Decimal)
      let d = Decimal 2 0 :: Decimal
      show d `shouldBe` "0.00" -- not "-0.00"

  describe "decoding rules" $ do
    it "decodes into Decimal regardless of scale (Decimal's Eq normalizes scale)" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.50 AS decimal(10,2))"
      r `shouldBe` Only (Decimal 1 15 :: Decimal) -- 1.5, different internal scale, still equal

    it "rejects a fractional decimal decoded as Int" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1.5 AS decimal(5,2))") :: IO (Either DecodeError (Only Int))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "decimal"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects an integral decimal decoded as Int or Int64 (fixed-size types stay decimal-free)" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(5 AS decimal(5,0))") :: IO (Either DecodeError (Only Int))
      case r of
        Left (DecodeError _ _) -> pure ()
        Right v -> expectationFailure ("decoded " ++ show v)
      r64 <- try (query1 conn "SELECT CAST(5 AS decimal(5,0))") :: IO (Either DecodeError (Only Int64))
      case r64 of
        Left (DecodeError _ _) -> pure ()
        Right v -> expectationFailure ("decoded " ++ show v)

    it "decodes a scale-0 decimal into Integer, including at the decimal(38,0) extremes" $ \conn -> do
      r <- query1 conn "SELECT CAST(5 AS decimal(5,0))"
      r `shouldBe` Only (5 :: Integer)
      let dec38 = 10 ^ (38 :: Int) - 1 :: Integer
      extremes <- query1 conn $ rawSql $
        "SELECT CAST('" <> T.pack (show dec38) <> "' AS decimal(38,0)), CAST('"
          <> T.pack (show (negate dec38)) <> "' AS decimal(38,0))"
      extremes `shouldBe` (dec38, negate dec38)

    it "rejects a nonzero-scale decimal decoded as Integer" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1.5 AS decimal(5,2))") :: IO (Either DecodeError (Only Integer))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "Integer"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a decimal decoded as Double" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1.5 AS decimal(5,2))") :: IO (Either DecodeError (Only Double))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "Double"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "decodes an int column into Decimal" $ \conn -> do
      r <- query1 conn "SELECT CAST(5 AS int)"
      r `shouldBe` Only (Decimal 0 5 :: Decimal)

    it "decodes as SqlDecimal via SqlValue" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.5 AS decimal(5,2)), CAST(NULL AS decimal(5,2))"
      r `shouldBe` (SqlDecimal 1.5, SqlNull)

  describe "a nullable decimal column" $ do
    it "round-trips a value and NULL" $ \conn -> do
      _ <- execute conn "CREATE TABLE #decn (v decimal(10,2) NULL)"
      _ <- execute conn "INSERT INTO #decn VALUES (NULL), (123.45)"
      rows <- query conn "SELECT v FROM #decn ORDER BY v"
      rows `shouldBe` [Only (Nothing :: Maybe Decimal), Only (Just 123.45)]
