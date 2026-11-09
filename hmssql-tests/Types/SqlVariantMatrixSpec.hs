-- | @sql_variant@ across every base type it can carry: columns, parameters,
-- and 'SQL_VARIANT_PROPERTY' (BaseType\/Precision\/Scale\/MaxLength) checked
-- server-side against what hmssql decoded. NULL handling and character/binary
-- payloads are already covered by 'Types.SqlVariantNullSpec' and
-- 'Types.LegacyLobSpec'; this module is the base-type matrix.
module Types.SqlVariantMatrixSpec (spec) where

import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Fixed (Fixed (..))
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Test.Hspec

import Hmssql
import Hmssql.Encoding (RawParam (..))
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import TestDb

------------------------------------------------------------------------------
-- Fixed (non-scaled) base types: columns

data VCase = VCase
  { vLabel :: String
  , vExpr :: Text            -- ^ SQL expression, already cast to its base type
  , vExpected :: SqlValue
  , vBaseType :: Text
  , vPrecision :: Maybe Int
  , vScale :: Maybe Int
  , vMaxLength :: Maybe Int
  }

vcases :: [VCase]
vcases =
  [ VCase "minimum bigint" "CAST(-9223372036854775808 AS bigint)" (SqlInt64 (-9223372036854775808)) "bigint" Nothing Nothing Nothing
  , VCase "negative widest decimal" ("CAST(-" <> T.replicate 38 "9" <> " AS decimal(38,0))")
      (SqlDecimal (negate (read (T.unpack (T.replicate 38 "9"))))) "decimal" (Just 38) (Just 0) Nothing
  , VCase "tinyint" "CAST(255 AS tinyint)" (SqlWord8 255) "tinyint" Nothing Nothing Nothing
  , VCase "smallint" "CAST(-32768 AS smallint)" (SqlInt16 (-32768)) "smallint" Nothing Nothing Nothing
  , VCase "int" "CAST(-2147483648 AS int)" (SqlInt32 (-2147483648)) "int" Nothing Nothing Nothing
  , VCase "bigint" "CAST(9223372036854775807 AS bigint)" (SqlInt64 9223372036854775807) "bigint" Nothing Nothing Nothing
  , VCase "bit" "CAST(1 AS bit)" (SqlBool True) "bit" Nothing Nothing Nothing
  , VCase "real" "CAST(1.5 AS real)" (SqlFloat 1.5) "real" Nothing Nothing Nothing
  , VCase "float" "CAST(1.5e10 AS float)" (SqlDouble 1.5e10) "float" Nothing Nothing Nothing
  , VCase "decimal(5,2)" "CAST(123.45 AS decimal(5,2))" (SqlDecimal 123.45) "decimal" (Just 5) (Just 2) Nothing
  , VCase "decimal(38,0), the widest precision" ("CAST(" <> T.replicate 38 "9" <> " AS decimal(38,0))")
      (SqlDecimal (read (T.unpack (T.replicate 38 "9")))) "decimal" (Just 38) (Just 0) Nothing
  , VCase "numeric(10,2) (a distinct server base type, decoded the same as decimal)"
      "CAST(12345.67 AS numeric(10,2))" (SqlDecimal 12345.67) "numeric" (Just 10) (Just 2) Nothing
  , VCase "money" "CAST(922337203685477.5807 AS money)" (SqlMoney (Money (MkFixed 9223372036854775807))) "money" Nothing Nothing Nothing
  , VCase "smallmoney" "CAST(-214748.3648 AS smallmoney)" (SqlMoney (Money (MkFixed (-2147483648)))) "smallmoney" Nothing Nothing Nothing
  , VCase "uniqueidentifier" "CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier)"
      (SqlGuid (UUID.fromWords 0x6F9619FF 0x8B86D011 0xB42D00C0 0x4FC964FF)) "uniqueidentifier" Nothing Nothing Nothing
  , VCase "date" "CAST('2020-05-06' AS date)" (SqlDate (fromGregorian 2020 5 6)) "date" Nothing Nothing Nothing
  , VCase "datetime" "CAST('2020-05-06T01:02:03.12' AS datetime)" -- 0.12s = 36 ticks of 1/300s, exact
      (SqlDateTime (LocalTime (fromGregorian 2020 5 6) (TimeOfDay 1 2 3.12))) "datetime" Nothing Nothing Nothing
  , VCase "smalldatetime" "CAST('2020-05-06T01:02:00' AS smalldatetime)"
      (SqlDateTime (LocalTime (fromGregorian 2020 5 6) (TimeOfDay 1 2 0))) "smalldatetime" Nothing Nothing Nothing
  , VCase "char(5), space-padded" "CAST('ab' AS char(5))" (SqlText "ab   ") "char" Nothing Nothing (Just 5)
  , VCase "varchar(10)" "CAST('ab' AS varchar(10))" (SqlText "ab") "varchar" Nothing Nothing (Just 10)
  , VCase "nchar(5), space-padded" "CAST(N'ab' AS nchar(5))" (SqlText "ab   ") "nchar" Nothing Nothing (Just 10)
  , VCase "nvarchar(10)" "CAST(N'ab' AS nvarchar(10))" (SqlText "ab") "nvarchar" Nothing Nothing (Just 20)
  , VCase "binary(10), zero-padded" "CAST(0x0102 AS binary(10))" (SqlBinary (B.pack ([1, 2] ++ replicate 8 0))) "binary" Nothing Nothing (Just 10)
  , VCase "varbinary(10)" "CAST(0x0102 AS varbinary(10))" (SqlBinary (B.pack [1, 2])) "varbinary" Nothing Nothing (Just 10)
  ]

spec :: Spec
spec = around withTestDb $ do
  describe "fixed base types (column, one CAST per case)" $
    mapM_ (\c -> it (vLabel c) (\conn -> checkCase conn c)) vcases

  describe "date/time family at every scale 0-7 (time, datetime2, datetimeoffset)" $ scaleSpec

  describe "RETURNVALUE and row payload agreement" $
    mapM_ (\c -> it (vLabel c) (\conn -> checkOutput conn c)) vcases

  describe "as parameters, exact round trip" $ paramSpec

checkCase :: Connection -> VCase -> IO ()
checkCase conn VCase{..} = do
  let variant = "CAST(" <> vExpr <> " AS sql_variant)"
  (decoded :: SqlValue, baseType :: Text) <- query1 conn $ rawSql
    ("SELECT " <> variant <> ", CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'BaseType') AS nvarchar(128))")
  decoded `shouldBe` vExpected
  baseType `shouldBe` vBaseType
  case vPrecision of
    Nothing -> pure ()
    Just p -> do
      Only (got :: Int) <- query1 conn $ rawSql ("SELECT CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'Precision') AS int)")
      got `shouldBe` p
  case vScale of
    Nothing -> pure ()
    Just s -> do
      Only (got :: Int) <- query1 conn $ rawSql ("SELECT CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'Scale') AS int)")
      got `shouldBe` s
  case vMaxLength of
    Nothing -> pure ()
    Just m -> do
      Only (got :: Int) <- query1 conn $ rawSql ("SELECT CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'MaxLength') AS int)")
      got `shouldBe` m

------------------------------------------------------------------------------
-- Scale sweep: compare the variant-decoded value against the non-variant
-- decode of the same cast, and check BaseType/Scale server-side.

scaleSpec :: SpecWith Connection
scaleSpec = sequence_
  [ it (fam ++ "(" ++ show s ++ ")") $ \conn -> checkScale conn fam s
  | fam <- ["time", "datetime2", "datetimeoffset"]
  , s <- [0 .. 7 :: Int]
  ]

checkScale :: Connection -> String -> Int -> IO ()
checkScale conn fam s = do
  let ty = T.pack fam <> "(" <> T.pack (show s) <> ")"
      lit = literalFor fam
      cast = "CAST('" <> lit <> "' AS " <> ty <> ")"
      variant = "CAST(" <> cast <> " AS sql_variant)"
  case fam of
    "time" -> do
      (direct :: TimeOfDay, viaVariant :: SqlValue) <- query1 conn $ rawSql ("SELECT " <> cast <> ", " <> variant)
      viaVariant `shouldBe` SqlTime direct
    "datetime2" -> do
      (direct :: LocalTime, viaVariant :: SqlValue) <- query1 conn $ rawSql ("SELECT " <> cast <> ", " <> variant)
      viaVariant `shouldBe` SqlDateTime direct
    "datetimeoffset" -> do
      (direct :: DateTimeOffset, viaVariant :: SqlValue) <- query1 conn $ rawSql ("SELECT " <> cast <> ", " <> variant)
      viaVariant `shouldBe` SqlDateTimeOffset direct
    _ -> expectationFailure ("unknown family " ++ fam)
  (baseType :: Text, scale :: Int) <- query1 conn $ rawSql
    ("SELECT CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'BaseType') AS nvarchar(128)), \
     \CAST(SQL_VARIANT_PROPERTY(" <> variant <> ", 'Scale') AS int)")
  baseType `shouldBe` T.pack fam
  scale `shouldBe` s
  where
    literalFor "time" = "01:02:03.1234567"
    literalFor "datetime2" = "2020-05-06 01:02:03.1234567"
    literalFor "datetimeoffset" = "2020-05-06 01:02:03.1234567 +05:30"
    literalFor f = error ("literalFor: " ++ f)

------------------------------------------------------------------------------
-- Parameters: SqlValue and native types sent as parameters, round-tripped
-- through sql_variant (via an implicit conversion on the server side, since
-- ToSqlField SqlValue/native types declare their own native wire type).

paramSpec :: SpecWith Connection
paramSpec = do
  it "CAST(@p1 AS sql_variant) round-trips native-typed parameters exactly" $ \conn -> do
    roundTripsAsVariant conn (32 :: Int32) (SqlInt32 32)
    roundTripsAsVariant conn ("hello" :: Text) (SqlText "hello")
    roundTripsAsVariant conn (1.25 :: Decimal) (SqlDecimal 1.25)
    roundTripsAsVariant conn (LocalTime (fromGregorian 2020 1 2) (TimeOfDay 3 4 5)) (SqlDateTime (LocalTime (fromGregorian 2020 1 2) (TimeOfDay 3 4 5)))
    roundTripsAsVariant conn (B.pack [1, 2, 3]) (SqlBinary (B.pack [1, 2, 3]))
    roundTripsAsVariant conn True (SqlBool True)
    roundTripsAsVariant conn (UUID.fromWords 1 2 3 4) (SqlGuid (UUID.fromWords 1 2 3 4))

  it "inserts a SqlValue parameter into a sql_variant column and reads it back" $ \conn -> do
    _ <- execute conn "CREATE TABLE #svp (id int IDENTITY, v sql_variant NULL)"
    _ <- execute conn ("INSERT INTO #svp (v) VALUES (" <> param (SqlInt64 123456789012 :: SqlValue) <> ")")
    _ <- execute conn ("INSERT INTO #svp (v) VALUES (" <> param (SqlText "abcdef" :: SqlValue) <> ")")
    _ <- execute conn ("INSERT INTO #svp (v) VALUES (" <> param (SqlDecimal 42.5 :: SqlValue) <> ")")
    rows <- query conn "SELECT v FROM #svp ORDER BY id"
    rows `shouldBe` [Only (SqlInt64 123456789012), Only (SqlText "abcdef"), Only (SqlDecimal 42.5)]

roundTripsAsVariant :: (ToSqlField a, Show a) => Connection -> a -> SqlValue -> IO ()
roundTripsAsVariant conn val expected = do
  Only (decoded :: SqlValue) <- query1 conn (mkQuery "SELECT CAST(@p1 AS sql_variant)" (Only val))
  decoded `shouldBe` expected

-- The server constructs each value independently. The same expression goes
-- through RETURNVALUE as through a row, retaining the dynamic base type.
checkOutput :: Connection -> VCase -> IO ()
checkOutput conn VCase{..} = do
  let stmt = inParam "" ("SET @out = CAST(" <> vExpr <> " AS sql_variant)" :: Text)
  let declaration = inParam "" ("@out sql_variant OUTPUT" :: Text)
  let output = outParam "@out" (RawParam (TISqlVariant 8016, Nothing))
  result <- callProcedure conn "sp_executesql" [stmt,declaration,output]
  map (decodeReturnValue @SqlValue) (procOutputValues result) `shouldBe` [Right vExpected]
