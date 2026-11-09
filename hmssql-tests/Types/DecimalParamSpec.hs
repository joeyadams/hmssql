{-# LANGUAGE ExistentialQuantification #-}
-- | Decimal parameters: the type declared for input values, round trips at
-- every precision and scale, rounding, and output parameters of every type
-- returning values larger or more precise than their initial value.
module Types.DecimalParamSpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..), roundTo)
import Data.Int (Int16)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Encoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Token (ReturnValue (..))
import LiveProperty (liveHedgehog)
import TestDb

------------------------------------------------------------------------------
-- Output parameter cases

procPrefix :: Text
procPrefix = "dbo.hmssql_decparam_"

-- | A procedure @procPrefix <> name@ with one OUTPUT parameter @\@x@ of the
-- given type, which it sets to the expression.
data Proc = Proc
  { procName :: Text
  , procType :: Text
  , procExpr :: Text
  }

procs :: [Proc]
procs =
  [ Proc "dec20_4" "decimal(20,4)" "1234567890123456.7891"
  , Proc "dec38_10" "decimal(38,10)" "-9999999999999999999999999999.9999999999"
  , Proc "num10_2" "numeric(10,2)" "12345678.91"
  , Proc "dec38_20" "decimal(38,20)" "123.45678901234567890123"
  , Proc "dec38_20_half" "decimal(38,20)" "0.12345678905"
  , Proc "dec38_20_neghalf" "decimal(38,20)" "-0.12345678905"
  , Proc "dec38_0" "decimal(38,0)" "99999999999999999999999999999999999999"
  , Proc "varchar" "varchar(max)" "REPLICATE(CAST('x' AS varchar(max)), 10000)"
  , Proc "nvarchar" "nvarchar(4000)" "REPLICATE(N'\233', 4000)"
  , Proc "varbinary" "varbinary(8000)" "CAST(REPLICATE(CAST('ab' AS varchar(max)), 4000) AS varbinary(8000))"
  , Proc "char" "char(10)" "'abcdefghij'"
  , Proc "nchar" "nchar(10)" "N'abcdefghi\233'"
  , Proc "binary" "binary(10)" "0x00010203040506070809"
  , Proc "datetime2" "datetime2(7)" "'2020-01-02T03:04:05.1234567'"
  , Proc "time" "time(7)" "'23:59:59.9999999'"
  , Proc "dto" "datetimeoffset(7)" "'2020-01-02T03:04:05.1234567+05:30'"
  , Proc "datetime" "datetime" "'2020-01-02T03:04:05.990'"
  , Proc "date" "date" "'9999-12-31'"
  , Proc "money" "money" "922337203685477.5807"
  , Proc "smallmoney" "smallmoney" "214748.3647"
  , Proc "float" "float" "1e308"
  , Proc "real" "real" "CAST(3.4e38 AS real)"
  , Proc "guid" "uniqueidentifier" "'6F9619FF-8B86-D011-B42D-00C04FC964FF'"
  , Proc "variant" "sql_variant" "CAST(42 AS int)"
  , Proc "xml" "xml" "N'<a>b\233</a>'"
  , Proc "bigint" "bigint" "9223372036854775807"
  , Proc "smallint" "smallint" "-32768"
  , Proc "tinyint" "tinyint" "255"
  , Proc "bit" "bit" "1"
  ]

fixture :: [Text]
fixture = concat
  [ [ "DROP PROCEDURE IF EXISTS " <> procPrefix <> procName
    , "CREATE PROCEDURE " <> procPrefix <> procName <> " @x " <> procType
        <> " OUTPUT AS SET @x = " <> procExpr
    ]
  | Proc{..} <- procs
  ]

-- | Call the procedure with the one parameter and return its output value.
callOut :: Connection -> Text -> ProcParam -> IO ReturnValue
callOut conn name p = do
  res <- callProcedure conn (procPrefix <> name) [p]
  case procOutputValues res of
    [rv] -> pure rv
    rvs -> fail ("expected one output value, got " ++ show rvs)

-- | The output value of the procedure, decoded.
outValue :: FromSqlField b => Connection -> Text -> ProcParam -> IO b
outValue conn name p = callOut conn name p >>= either throwIO pure . decodeReturnValue

data OutCase = forall a b. (ToSqlField a, FromSqlField b, Eq b, Show b) =>
  OutCase String Text a b

coll0 :: Collation
coll0 = Collation 0 0

outCases :: [OutCase]
outCases =
  [ OutCase "decimal(20,4) from 0" "dec20_4" (0 :: Decimal) (read "1234567890123456.7891" :: Decimal)
  , OutCase "decimal(20,4) from NULL" "dec20_4" (Nothing :: Maybe Decimal) (Just (read "1234567890123456.7891" :: Decimal))
  , OutCase "decimal(38,10) from 0" "dec38_10" (0 :: Decimal) (read "-9999999999999999999999999999.9999999999" :: Decimal)
  , OutCase "numeric(10,2) from 0" "num10_2" (0 :: Decimal) (read "12345678.91" :: Decimal)
  , OutCase "decimal(38,20) from a scale-20 value" "dec38_20" (roundTo 20 0 :: Decimal) (read "123.45678901234567890123" :: Decimal)
  , OutCase "decimal(38,0) from a 38-digit value" "dec38_0" (Decimal 0 (10 ^ (37 :: Int)) :: Decimal) (Decimal 0 (10 ^ (38 :: Int) - 1) :: Decimal)
  , OutCase "varchar(max) from \"\"" "varchar" ("" :: Text) (T.replicate 10000 "x")
  , OutCase "nvarchar(4000) from \"\"" "nvarchar" ("" :: Text) (T.replicate 4000 "\233")
  , OutCase "varbinary(8000) from empty" "varbinary" B.empty (B.concat (replicate 4000 "ab"))
  , OutCase "char(10) from char(1)" "char" (RawParam (TIBigChar 1 coll0, Just "a")) ("abcdefghij" :: Text)
  , OutCase "char(10) from \"\"" "char" ("" :: Text) ("abcdefghij" :: Text)
  , OutCase "nchar(10) from nchar(1)" "nchar" (RawParam (TINChar 2 coll0, Just "a\0")) ("abcdefghi\233" :: Text)
  , OutCase "binary(10) from binary(1)" "binary" (RawParam (TIBigBinary 1, Just "\0")) (B.pack [0 .. 9])
  , OutCase "datetime2(7) from midnight" "datetime2" (LocalTime (fromGregorian 2000 1 1) midnight)
      (LocalTime (fromGregorian 2020 1 2) (TimeOfDay 3 4 5.1234567))
  , OutCase "time(7) from midnight" "time" midnight (TimeOfDay 23 59 59.9999999)
  , OutCase "datetimeoffset(7) from a whole second" "dto" (DateTimeOffset (UTCTime (fromGregorian 2000 1 1) 0) 0)
      (DateTimeOffset (UTCTime (fromGregorian 2020 1 1) (21 * 3600 + 34 * 60 + 5.1234567)) 330)
  , OutCase "datetime from a LocalTime" "datetime" (LocalTime (fromGregorian 2000 1 1) midnight)
      (LocalTime (fromGregorian 2020 1 2) (TimeOfDay 3 4 5.99))
  , OutCase "date from a Day" "date" (fromGregorian 2000 1 1) (fromGregorian 9999 12 31)
  , OutCase "money from 0" "money" (0 :: Money) (922337203685477.5807 :: Money)
  , OutCase "smallmoney from 0" "smallmoney" (0 :: Money) (214748.3647 :: Money)
  , OutCase "float from 0" "float" (0 :: Double) (1e308 :: Double)
  , OutCase "real from 0" "real" (0 :: Float) (3.4e38 :: Float)
  , OutCase "uniqueidentifier from nil" "guid" UUID.nil
      (UUID.fromWords 0x6F9619FF 0x8B86D011 0xB42D00C0 0x4FC964FF :: UUID)
  , OutCase "xml from xml NULL" "xml" (RawParam (TIXml Nothing, Nothing)) ("<a>b\233</a>" :: Text)
  , OutCase "xml from SqlXml \"\"" "xml" (SqlXml "") ("<a>b\233</a>" :: Text)
  , OutCase "xml from a SqlXml document, decoded as SqlXml" "xml" (SqlXml "<old/>") (SqlXml "<a>b\233</a>")
  , OutCase "bigint from Integer 0" "bigint" (0 :: Integer) (toInteger (maxBound :: Int))
  , OutCase "smallint from Int16 0" "smallint" (0 :: Int16) (-32768 :: Int16)
  , OutCase "tinyint from Word8 0" "tinyint" (0 :: Word8) (255 :: Word8)
  , OutCase "bit from False" "bit" False True
  ]

------------------------------------------------------------------------------
-- Input decimals

-- | The @decimal(p,s)@ a value is sent as: its own scale, and just enough
-- precision for its digits.
expectedType :: Decimal -> (Int, Int)
expectedType (Decimal s m) = (max (length (show (abs m))) (fromIntegral s), fromIntegral s)

-- | Precision and scale of @\@p1@ as the server sees it.
paramType :: Connection -> Decimal -> IO (Int, Int)
paramType conn d = query1 conn $ mkQuery
  "SELECT CAST(SQL_VARIANT_PROPERTY(@p1, 'Precision') AS int), CAST(SQL_VARIANT_PROPERTY(@p1, 'Scale') AS int)"
  (Only d)

decType :: Int -> Int -> Text
decType p s = "decimal(" <> T.pack (show p) <> "," <> T.pack (show s) <> ")"

expectEncodeError :: Connection -> Decimal -> String -> Expectation
expectEncodeError conn d needle = do
  r <- try (query1 conn ("SELECT " <> param d))
  case r of
    Left (EncodeError msg) -> msg `shouldContain` needle
    Right (Only (x :: Decimal)) -> expectationFailure ("sent " ++ show d ++ ", got " ++ show x)

spec :: Spec
spec = withFixture "types_decimal_param" fixture $ around withTestDb $ do
  describe "input decimals" $ do
    it "round-trip at every precision 1-38 and scale 0-p, at the extremes" $ \conn ->
      forM_ [1 .. 38] $ \p -> forM_ [0 .. p] $ \s -> do
        let top = 10 ^ p - 1
            vals = [Decimal (fromIntegral s) top, Decimal (fromIntegral s) (negate top), Decimal (fromIntegral s) 1, Decimal (fromIntegral s) 0]
            t = decType p s
        r <- query1 conn $ mkQuery ("SELECT CAST(@p1 AS " <> t <> "), CAST(@p2 AS " <> t <> "), CAST(@p3 AS " <> t <> "), CAST(@p4 AS " <> t <> "), @p1, @p2, @p3, @p4") vals
        let (a, b, c, d, e, f, g, h) = r :: (Decimal, Decimal, Decimal, Decimal, Decimal, Decimal, Decimal, Decimal)
        ([a, b, c, d], [e, f, g, h]) `shouldBe` (vals, vals)

    it "round-trip at random precision, scale and value" $ \conn -> liveHedgehog $ do
      p <- forAll $ Gen.int (Range.linear 1 38)
      s <- forAll $ Gen.int (Range.linear 0 p)
      m <- forAll $ Gen.integral (Range.linearFrom 0 (1 - 10 ^ p) (10 ^ p - 1))
      let d = Decimal (fromIntegral s) m
      Only r <- evalIO $ query1 conn (mkQuery ("SELECT CAST(@p1 AS " <> decType p s <> ")") (Only d))
      r === d
      Only r' <- evalIO $ query1 conn ("SELECT " <> param d)
      r' === d
      -- the server keeps the scale, not just the value
      decimalPlaces r' === fromIntegral s
      t <- evalIO $ paramType conn d
      t === expectedType d

    it "are declared with the value's precision and scale" $ \conn -> do
      paramType conn 0.001 `shouldReturn` (3, 3)
      paramType conn 1000000 `shouldReturn` (7, 0)
      paramType conn 0 `shouldReturn` (1, 0)
      paramType conn 0.5 `shouldReturn` (1, 1)
      paramType conn (Decimal 2 100) `shouldReturn` (3, 2)
      paramType conn (-12.345) `shouldReturn` (5, 3)

    it "accept a scale of 38 (regression: precision was scale + 1)" $ \conn -> do
      let tiny = Decimal 38 1 :: Decimal
          nines = Decimal 38 (10 ^ (38 :: Int) - 1) :: Decimal
      query1 conn (mkQuery "SELECT @p1, @p2" (tiny, negate nines)) `shouldReturn` (tiny, negate nines)
      paramType conn tiny `shouldReturn` (38, 38)

    it "accept ±(10^38-1)" $ \conn -> do
      let big = Decimal 0 (10 ^ (38 :: Int) - 1) :: Decimal
      query1 conn (mkQuery "SELECT @p1, @p2, CAST(@p1 AS decimal(38,0))" (big, negate big))
        `shouldReturn` (big, negate big, big)

    it "reject values of more than 38 digits" $ \conn -> do
      expectEncodeError conn (Decimal 0 (10 ^ (38 :: Int))) "38"
      expectEncodeError conn (Decimal 0 (negate (10 ^ (38 :: Int)))) "38"
      expectEncodeError conn (Decimal 5 (10 ^ (40 :: Int))) "digits"
      expectEncodeError conn (Decimal 39 1) "decimal places"
      expectEncodeError conn (Decimal 255 1) "decimal places"

    it "are sent exactly; the server rounds half away from zero" $ \conn -> do
      query1 conn ("SELECT " <> param (1.005 :: Decimal)) `shouldReturn` Only (1.005 :: Decimal)
      let casts = "SELECT CAST(@p1 AS decimal(10,2)), CAST(@p2 AS decimal(10,2)), CAST(@p3 AS decimal(10,2)), CAST(@p4 AS decimal(10,2))"
      query1 conn (mkQuery casts (1.005 :: Decimal, -1.005 :: Decimal, 1.015 :: Decimal, 1.025 :: Decimal))
        `shouldReturn` (1.01 :: Decimal, -1.01 :: Decimal, 1.02 :: Decimal, 1.03 :: Decimal)
      _ <- execute conn "CREATE TABLE #decparam_round (v decimal(10,2))"
      _ <- execute conn (mkQuery "INSERT INTO #decparam_round VALUES (@p1), (@p2)" (1.235 :: Decimal, -2.345 :: Decimal))
      query conn "SELECT v FROM #decparam_round ORDER BY v"
        `shouldReturn` [Only (-2.35 :: Decimal), Only 1.24]

    it "are rejected by a narrower column rather than truncated" $ \conn -> do
      r <- try (query1 conn ("SELECT CAST(" <> param (12345.6 :: Decimal) <> " AS decimal(5,2))"))
      case r of
        Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 8115  -- arithmetic overflow
        Right (Only (x :: Decimal)) -> expectationFailure ("got " ++ show x)

  describe "output parameters" $ do
    forM_ outCases $ \(OutCase label name initial expected) ->
      it (label ++ " returns the whole value") $ \conn ->
        outValue conn name (outParam "@x" initial) `shouldReturn` expected

    it "declares a Decimal as decimal(38,10) by default" $ \conn -> do
      rv <- callOut conn "dec20_4" (outParam "@x" (0 :: Decimal))
      rvType rv `shouldBe` TIDecimalN 38 10
      rv' <- callOut conn "dec20_4" (outParam "@x" (Nothing :: Maybe Decimal))
      rvType rv' `shouldBe` TIDecimalN 38 10

    it "keeps room for an initial Decimal of more than 28 integer digits" $ \_ -> do
      let declared d = fst <$> procParamEncode (outParam "@x" (d :: Decimal)) defaultTdsContext
      declared (Decimal 0 (10 ^ (33 :: Int))) `shouldBe` Right (TIDecimalN 38 4)
      declared (Decimal 2 (10 ^ (37 :: Int))) `shouldBe` Right (TIDecimalN 38 2)
      declared (Decimal 12 5) `shouldBe` Right (TIDecimalN 38 12)
      declared (Decimal 38 5) `shouldBe` Right (TIDecimalN 38 38)

    it "passes the initial Decimal value in exactly" $ \conn -> do
      _ <- execute conn "CREATE PROCEDURE #decparam_echo @x decimal(38,20) OUTPUT AS SET @x = @x * 2"
      let p = outParam "@x" (read "-12345.6789" :: Decimal)
      res <- callProcedure conn "#decparam_echo" [p]
      map decodeReturnValue (procOutputValues res) `shouldBe` [Right (read "-24691.3578" :: Decimal)]

    it "rounds a Decimal to 10 places (half away from zero) unless told otherwise" $ \conn -> do
      outValue conn "dec38_20" (outParam "@x" (0 :: Decimal)) `shouldReturn` (read "123.4567890123" :: Decimal)
      outValue conn "dec38_20_half" (outParam "@x" (0 :: Decimal)) `shouldReturn` (read "0.1234567891" :: Decimal)
      outValue conn "dec38_20_neghalf" (outParam "@x" (0 :: Decimal)) `shouldReturn` (read "-0.1234567891" :: Decimal)
      outValue conn "dec38_20_half" (outParam "@x" (roundTo 11 0 :: Decimal)) `shouldReturn` (read "0.12345678905" :: Decimal)

    it "fails loudly for a Decimal of more than 28 integer digits from 0" $ \conn -> do
      r <- try (callOut conn "dec38_0" (outParam "@x" (0 :: Decimal)))
      case r of
        Left (e :: SqlServerError) -> sqlErrorNumber e `shouldSatisfy` (`elem` [8114, 8115])
        Right rv -> expectationFailure ("got " ++ show (decodeReturnValue rv :: Either DecodeError Decimal))

    it "takes an explicit decimal(p,s) via rawOutParam" $ \conn -> do
      rv <- callOut conn "dec38_0" (rawOutParam "@x" (TIDecimalN 38 0, Nothing))
      rvType rv `shouldBe` TIDecimalN 38 0
      decodeReturnValue rv `shouldBe` Right (Decimal 0 (10 ^ (38 :: Int) - 1) :: Decimal)
      rv' <- callOut conn "dec38_20" (rawOutParam "@x" (TIDecimalN 38 20, Nothing))
      decodeReturnValue rv' `shouldBe` Right (read "123.45678901234567890123" :: Decimal)

    it "returns a sql_variant from a NULL sql_variant" $ \conn -> do
      outValue conn "variant" (rawOutParam "@x" (TISqlVariant 8016, Nothing))
        `shouldReturn` SqlInt32 42

    it "needs an xml-typed parameter for xml (the server won't convert xml to nvarchar)" $ \conn -> do
      r <- try (callOut conn "xml" (outParam "@x" ("" :: Text)))
      case r of
        Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 257
        Right rv -> expectationFailure ("got " ++ show (decodeReturnValue rv :: Either DecodeError Text))

    it "widens string and binary types to (max)" $ \conn -> do
      let typeOf name a = rvType <$> callOut conn name (outParam "@x" a)
      typeOf "char" (RawParam (TIBigChar 1 coll0, Just "a")) >>= \case
        TIBigVarChar 0xFFFF _ -> pure ()
        t -> expectationFailure (show t)
      typeOf "nchar" (RawParam (TINChar 2 coll0, Just "a\0")) >>= \case
        TINVarChar 0xFFFF _ -> pure ()
        t -> expectationFailure (show t)
      typeOf "nvarchar" ("" :: Text) >>= \case
        TINVarChar 0xFFFF _ -> pure ()
        t -> expectationFailure (show t)
      typeOf "binary" (RawParam (TIBigBinary 1, Just "\0")) `shouldReturn` TIBigVarBinary 0xFFFF
