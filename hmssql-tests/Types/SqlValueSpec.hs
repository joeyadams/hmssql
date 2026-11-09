{-# LANGUAGE DeriveGeneric #-}
-- | Dynamic decoding ('SqlValue'\/'SqlRow'\/'RawValue'), the fixed decoders
-- for 'Maybe', 'Only', tuples and 'Generic' records, the monadic decoders
-- ('singleFieldM'\/'remainingColumns'), row/column-count mismatches, computed
-- expressions whose type the server infers, and hedgehog properties that
-- treat the server's own text rendering as ground truth.
module Types.SqlValueSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import GHC.Generics (Generic)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestConfig

tshow :: Show a => a -> Text
tshow = T.pack . show

spec :: Spec
spec = around withTestDb $ do
  describe "a wide result set with every type" $ do
    let wideCols =
          [ "CAST(1 AS bit)"
          , "CAST(5 AS tinyint)"
          , "CAST(-5 AS smallint)"
          , "CAST(7 AS int)"
          , "CAST(9000000000 AS bigint)"
          , "CAST(1.5 AS real)"
          , "CAST(2.5 AS float)"
          , "CAST(3.25 AS decimal(10,2))"
          , "CAST(4.5 AS money)"
          , "CAST('01020304-0506-0708-090a-0b0c0d0e0f10' AS uniqueidentifier)"
          , "CAST('2020-05-06 10:20:30' AS datetime)"
          , "CAST('2020-05-06' AS date)"
          , "CAST('10:20:30' AS time)"
          , "CAST('2020-05-06 10:20:30 +02:00' AS datetimeoffset(0))"
          , "N'hello'"
          , "CAST(0xDEADBEEF AS varbinary(8))"
          , "CAST('<a/>' AS xml)"
          ]
        colNames =
          [ "bit", "tinyint", "smallint", "int", "bigint", "real", "float", "decimal", "money"
          , "guid", "datetime", "date", "time", "dto", "text", "binary", "xml"
          ]
        expected =
          [ SqlBool True
          , SqlWord8 5
          , SqlInt16 (-5)
          , SqlInt32 7
          , SqlInt64 9000000000
          , SqlFloat 1.5
          , SqlDouble 2.5
          , SqlDecimal 3.25
          , SqlMoney 4.5
          , SqlGuid (UUID.fromWords 0x01020304 0x05060708 0x090a0b0c 0x0d0e0f10)
          , SqlDateTime (LocalTime (fromGregorian 2020 5 6) (TimeOfDay 10 20 30))
          , SqlDate (fromGregorian 2020 5 6)
          , SqlTime (TimeOfDay 10 20 30)
          , SqlDateTimeOffset (DateTimeOffset (UTCTime (fromGregorian 2020 5 6) (8 * 3600 + 20 * 60 + 30)) 120)
          , SqlText "hello"
          , SqlBinary (B.pack [0xDE, 0xAD, 0xBE, 0xEF])
          , SqlXml "<a/>"
          ]
        selectList as = T.intercalate ", " [c <> " AS " <> n | (c, n) <- zip as colNames]
        sql = rawSql $ "SELECT " <> selectList wideCols
                <> " UNION ALL SELECT " <> selectList (map (const "NULL") wideCols)

    it "decodes every non-NULL value to the right SqlValue constructor" $ \conn -> do
      [ResultSet cols rows] <- queryMulti conn sql
      map columnName cols `shouldBe` colNames
      case rows of
        (SqlRow _ vals : _) -> vals `shouldBe` expected
        [] -> expectationFailure "no rows"

    it "decodes NULL of every type as SqlNull" $ \conn -> do
      [ResultSet _ rows] <- queryMulti conn sql
      case rows of
        [_, SqlRow _ vals] -> vals `shouldBe` replicate (length expected) SqlNull
        _ -> expectationFailure ("expected 2 rows, got " ++ show (length rows))

  describe "Maybe and Only" $ do
    it "decodes a single nullable column with Only and Maybe" $ \conn -> do
      r <- query conn "SELECT v FROM (VALUES (CAST(1 AS int)), (CAST(NULL AS int))) t(v) ORDER BY v"
      r `shouldBe` [Only Nothing, Only (Just (1 :: Int))]

  describe "tuples up to arity 12" $
    it "decodes a 12-column row" $ \conn -> do
      r <- query1 conn "SELECT 1,2,3,4,5,6,7,8,9,10,11,12"
      r `shouldBe` ((1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) :: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int))

  describe "Generic records" $ do
    it "binds fields by position, not by column name" $ \conn -> do
      -- The record's field names ("wa"/"wb") match neither column alias
      -- below; Generic decoding is purely positional.
      r <- query1 conn "SELECT N'Alice' AS unrelated1, 30 AS unrelated2"
      r `shouldBe` Widget { wa = "Alice", wb = 30 }

  describe "monadic decoders: singleFieldM and remainingColumns" $ do
    it "decodes a typed prefix then the rest dynamically" $ \conn -> do
      let decoder = do
            a <- singleFieldM (fieldDecoder :: FieldDecoder Int)
            rest <- sqlRowDecoder
            pure (a, rest)
      [(a, SqlRow cols vals)] <- queryMWith decoder conn "SELECT 1 AS n, N'x' AS s, CAST(2.5 AS float) AS f"
      a `shouldBe` (1 :: Int)
      map columnName cols `shouldBe` ["s", "f"]
      vals `shouldBe` [SqlText "x", SqlDouble 2.5]

  describe "row/column-count mismatches" $ do
    it "reports a clear error when the row has more columns than the target" $ \conn -> do
      r <- try (query1 conn "SELECT 1, 2, 3") :: IO (Either DecodeError (Int, Int))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "3 column"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "reports a clear error when the row has fewer columns than the target" $ \conn -> do
      r <- try (query1 conn "SELECT 1, 2") :: IO (Either DecodeError (Int, Int, Int))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "2 column"
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "computed expressions whose type the server infers" $ do
    it "decodes decimal division (1.0/3), scale limited by the server's rules" $ \conn -> do
      r <- query1 conn "SELECT 1.0/3"
      r `shouldBe` Only (Decimal 6 333333 :: Decimal)

    it "decodes float division at full double precision" $ \conn -> do
      r <- query1 conn "SELECT 1.0e0/3"
      r `shouldBe` Only (1 / 3 :: Double)

    it "decodes SUM of decimal columns, keeping scale" $ \conn -> do
      r <- query1 conn
        "SELECT SUM(x) FROM (VALUES (CAST(1.11 AS decimal(5,2))), (CAST(2.22 AS decimal(5,2)))) t(x)"
      r `shouldBe` Only (3.33 :: Decimal)

    it "decodes AVG of an int column, which stays int (integer division)" $ \conn -> do
      r <- query1 conn "SELECT AVG(x) FROM (VALUES (1), (2)) t(x)"
      r `shouldBe` Only (1 :: Int)

    it "decodes CAST(... AS float(24)) at real precision" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.0e0/3 AS float(24))"
      r `shouldBe` Only (1 / 3 :: Float)

    it "COALESCE promotes to the higher-precedence decimal type" $ \conn -> do
      r <- query1 conn "SELECT COALESCE(CAST(NULL AS int), CAST(1.5 AS decimal(5,2)))"
      r `shouldBe` Only (1.5 :: Decimal)

    it "ISNULL keeps the first argument's type, truncating the replacement (a T-SQL quirk, not an hmssql bug)" $ \conn -> do
      r <- query1 conn "SELECT ISNULL(CAST(NULL AS int), CAST(1.5 AS decimal(5,2)))"
      r `shouldBe` Only (1 :: Int)

  describe "hedgehog: the server's own rendering as ground truth" $ do
    it "decimal: matches CONVERT(varchar, ...) for random precision/scale/digits" $ \conn -> liveHedgehog $ do
      (p, s, lit, expectedVal) <- forAll genDecimalCase
      let q = rawSql $ "SELECT CAST('" <> lit <> "' AS decimal(" <> tshow p <> "," <> tshow s <> ")), "
                <> "CONVERT(varchar(60), CAST('" <> lit <> "' AS decimal(" <> tshow p <> "," <> tshow s <> ")))"
      (d, txt) <- evalIO (query1 conn q :: IO (Decimal, Text))
      d === expectedVal
      tshow d === txt

    it "money: our decode agrees with the server's own CONVERT(..., 2) text" $ \conn -> liveHedgehog $ do
      m <- forAll $ Gen.integral (Range.linearFrom 0 (-9223372036854775808) 9223372036854775807)
      let lit = moneyLiteral m
          q = rawSql $ "SELECT CAST(" <> lit <> " AS money), CONVERT(varchar(40), CAST(" <> lit <> " AS money), 2)"
      (decoded, txt) <- evalIO (query1 conn q :: IO (Money, Text))
      let fromServerText = parseMoneyText txt
      decoded === Money (MkFixed fromServerText)
      fromServerText === m

    it "float: text literals round-trip exact bit patterns for normal (non-subnormal) doubles" $ \conn -> liveHedgehog $ do
      -- SQL Server's float *literal* parser flushes subnormals to zero
      -- (unlike the binary parameter path, see Types.FloatSpec), so this
      -- generator is restricted to the normal range.
      w <- forAll $ Gen.filter isNormalDouble (Gen.word64 Range.linearBounded)
      let d = castWord64ToDouble w
          lit = tshow d
      Only d' <- evalIO (query1 conn (rawSql ("SELECT CAST(" <> lit <> " AS float)")) :: IO (Only Double))
      castDoubleToWord64 d' === w

data Widget = Widget { wa :: !Text, wb :: !Int }
  deriving (Eq, Show, Generic)

instance FromSqlRow Widget

isNormalDouble :: Word64 -> Bool
isNormalDouble w =
  let d = castWord64ToDouble w
   in not (isNaN d) && not (isInfinite d) && not (isDenormalized d)

-- | @precision, scale, exact decimal literal text, expected value@.
genDecimalCase :: Gen (Int, Int, Text, Decimal)
genDecimalCase = do
  p <- Gen.int (Range.linear 1 38)
  s <- Gen.int (Range.linear 0 p)
  neg <- Gen.bool
  digits <- Gen.string (Range.singleton p) Gen.digit
  let magnitude = read digits :: Integer
      isZero = magnitude == 0
      mantissa = if neg && not isZero then negate magnitude else magnitude
      (intPart, fracPart) = splitAt (p - s) digits
      intPart' = if null intPart then "0" else intPart
      body = if s == 0 then intPart' else intPart' ++ "." ++ fracPart
      lit = T.pack ((if neg && not isZero then "-" else "") ++ body)
  pure (p, s, lit, Decimal (fromIntegral s) mantissa)

-- | Render a money mantissa (1\/10000ths) as an exact decimal literal.
moneyLiteral :: Integer -> Text
moneyLiteral mantissa =
  let sign = if mantissa < 0 then "-" else ""
      mag = abs mantissa
      intPart = mag `div` 10000
      fracPart = mag `mod` 10000
      pad4 str = replicate (4 - length str) '0' ++ str
   in sign <> tshow intPart <> "." <> T.pack (pad4 (show fracPart))

-- | Parse @CONVERT(varchar(40), m, 2)@'s always-4-decimal output back into a
-- mantissa (1\/10000ths), independently of how we generated the literal.
parseMoneyText :: Text -> Integer
parseMoneyText t =
  let (neg, rest) = case T.stripPrefix "-" t of
        Just r -> (True, r)
        Nothing -> (False, t)
      (intPart, dotFrac) = T.breakOn "." rest
      fracPart = T.take 4 (T.drop 1 dotFrac)
      mantissa = read (T.unpack intPart) * 10000 + read (T.unpack fracPart)
   in if neg then negate mantissa else mantissa
