{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TupleSections #-}
-- | Integer parameters and columns: every Haskell integer type round-tripped
-- through the server over its full range, the wire type each is sent as, and
-- decoding from every SQL integer type (in range and out of range).
module Types.IntegerSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int16, Int32, Int64, Int8)
import Data.List (nub, sort)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestDb

-- | Largest magnitude of @decimal(38,0)@.
dec38 :: Integer
dec38 = 10 ^ (38 :: Int) - 1

-- | A Haskell type under test, with its range (Nothing = unbounded).
data HType = forall a. (ToSqlField a, FromSqlField a, Integral a, Show a) =>
  HType String (Maybe (Integer, Integer)) (Proxy a)

bounded :: forall a. (ToSqlField a, FromSqlField a, Integral a, Bounded a, Show a) => String -> Proxy a -> HType
bounded name p = HType name (Just (toInteger (minBound @a), toInteger (maxBound @a))) p

hTypes :: [HType]
hTypes =
  [ bounded "Int8" (Proxy @Int8)
  , bounded "Int16" (Proxy @Int16)
  , bounded "Int32" (Proxy @Int32)
  , bounded "Int64" (Proxy @Int64)
  , bounded "Int" (Proxy @Int)
  , bounded "Word8" (Proxy @Word8)
  , HType "Integer" Nothing (Proxy @Integer)
  ]

-- | A SQL column type, its range, and whether it is an integer type (as
-- opposed to an exact numeric with scale 0).
data SqlType = SqlType
  { sqlName :: Text
  , sqlRange :: (Integer, Integer)
  , sqlIsInteger :: Bool
  }

sqlTypes :: [SqlType]
sqlTypes =
  [ SqlType "tinyint" (0, 255) True
  , SqlType "smallint" (-32768, 32767) True
  , SqlType "int" (-2147483648, 2147483647) True
  , SqlType "bigint" (toInteger (minBound @Int64), toInteger (maxBound @Int64)) True
  , SqlType "bit" (0, 1) True
  , SqlType "decimal(38,0)" (negate dec38, dec38) False
  , SqlType "numeric(10,0)" (-9999999999, 9999999999) False
  ]

inRange :: (Integer, Integer) -> Integer -> Bool
inRange (lo, hi) v = lo <= v && v <= hi

-- | Interesting values of a SQL type: its bounds, small values, and every
-- Haskell type's bounds and their neighbours, as far as the SQL type holds them.
probeValues :: SqlType -> [Integer]
probeValues st = sort $ nub $ filter (inRange (sqlRange st)) $
  [lo, lo + 1, hi - 1, hi, -1, 0, 1, 2]
    ++ concat [ [b - 1, b, b + 1] | HType _ (Just (l, h)) _ <- hTypes, b <- [l, h] ]
  where
    (lo, hi) = sqlRange st

-- | Decode @SELECT CAST(v AS t)@ as the Haskell type, widened to 'Integer'.
decodeAs :: forall a. (FromSqlField a, Integral a) => Proxy a -> Connection -> Text -> Integer -> IO (Either DecodeError Integer)
decodeAs _ conn t v =
  try $ (\(Only (x :: a)) -> toInteger x) <$> query1 conn (rawSql ("SELECT CAST(" <> T.pack (show v) <> " AS " <> t <> ")"))

-- | The SQL Server base type a parameter arrives as.
baseTypeOf :: ToSqlField a => Connection -> a -> IO Text
baseTypeOf conn a = fromOnly <$> query1 conn (mkQuery "SELECT CAST(SQL_VARIANT_PROPERTY(@p1, 'BaseType') AS nvarchar(128))" (Only a))

roundTrip :: forall a. (ToSqlField a, FromSqlField a, Eq a, Show a) => Connection -> a -> PropertyT IO ()
roundTrip conn v = do
  Only r <- evalIO (query1 conn ("SELECT " <> param v))
  r === v

boundedGen :: forall a. (Integral a, Bounded a) => Gen a
boundedGen = Gen.integral (Range.linearFrom 0 minBound maxBound)

spec :: Spec
spec = around withTestDb $ do
  describe "parameters" $ do
    describe "round trip over the full range" $ do
      it "Int8" $ \conn -> liveHedgehog $ forAll (boundedGen @Int8) >>= roundTrip conn
      it "Int16" $ \conn -> liveHedgehog $ forAll (boundedGen @Int16) >>= roundTrip conn
      it "Int32" $ \conn -> liveHedgehog $ forAll (boundedGen @Int32) >>= roundTrip conn
      it "Int64" $ \conn -> liveHedgehog $ forAll (boundedGen @Int64) >>= roundTrip conn
      it "Int" $ \conn -> liveHedgehog $ forAll (boundedGen @Int) >>= roundTrip conn
      it "Word8" $ \conn -> liveHedgehog $ forAll (boundedGen @Word8) >>= roundTrip conn
      it "Integer (bigint and decimal(38,0) range)" $ \conn -> liveHedgehog $ do
        v <- forAll $ Gen.choice
          [ Gen.integral (Range.linearFrom 0 (negate dec38) dec38)
          , toInteger <$> boundedGen @Int64
          ]
        roundTrip conn v
      it "Bool" $ \conn -> liveHedgehog $ forAll Gen.bool >>= roundTrip conn

    describe "boundaries" $ do
      let checkAll :: forall a. (ToSqlField a, FromSqlField a, Eq a, Show a) => Connection -> [a] -> IO ()
          checkAll conn vs = forM_ vs $ \v -> query1 conn ("SELECT " <> param v) `shouldReturn` Only v
          bnds :: forall a. (Bounded a, Num a) => [a]
          bnds = [minBound, minBound + 1, -1, 0, 1, maxBound - 1, maxBound]
      it "Int8" $ \conn -> checkAll conn (bnds @Int8)
      it "Int16" $ \conn -> checkAll conn (bnds @Int16)
      it "Int32" $ \conn -> checkAll conn (bnds @Int32)
      it "Int64" $ \conn -> checkAll conn (bnds @Int64)
      it "Int" $ \conn -> checkAll conn (bnds @Int)
      it "Word8" $ \conn -> checkAll conn (bnds @Word8)
      it "Integer" $ \conn -> checkAll conn
        [ negate dec38, negate dec38 + 1
        , toInteger (minBound @Int64) - 1, toInteger (minBound @Int64)
        , -1, 0, 1
        , toInteger (maxBound @Int64), toInteger (maxBound @Int64) + 1
        , dec38 - 1, dec38 ]
      it "Bool" $ \conn -> checkAll conn [False, True]

    describe "wire types" $ do
      it "sends Int8 as smallint (tinyint is unsigned)" $ \conn ->
        baseTypeOf conn (-1 :: Int8) `shouldReturn` "smallint"
      it "sends Word8 as tinyint" $ \conn -> baseTypeOf conn (255 :: Word8) `shouldReturn` "tinyint"
      it "sends Int16 as smallint" $ \conn -> baseTypeOf conn (1 :: Int16) `shouldReturn` "smallint"
      it "sends Int32 as int" $ \conn -> baseTypeOf conn (1 :: Int32) `shouldReturn` "int"
      it "sends Int64 and Int as bigint" $ \conn -> do
        baseTypeOf conn (1 :: Int64) `shouldReturn` "bigint"
        baseTypeOf conn (1 :: Int) `shouldReturn` "bigint"
      it "sends Integer as bigint, or decimal(38,0) beyond it" $ \conn -> do
        baseTypeOf conn (toInteger (maxBound @Int64)) `shouldReturn` "bigint"
        baseTypeOf conn (toInteger (minBound @Int64)) `shouldReturn` "bigint"
        baseTypeOf conn (toInteger (maxBound @Int64) + 1) `shouldReturn` "decimal"
        baseTypeOf conn (toInteger (minBound @Int64) - 1) `shouldReturn` "decimal"
      it "sends Bool as bit" $ \conn -> baseTypeOf conn True `shouldReturn` "bit"

    describe "negative Int8 (regression)" $ do
      it "compares as a negative number" $ \conn ->
        query1 conn (mkQuery "SELECT CASE WHEN @p1 = -1 THEN 1 ELSE 0 END" (Only (-1 :: Int8)))
          `shouldReturn` Only (1 :: Int)
      it "decodes as Int16" $ \conn ->
        query1 conn ("SELECT " <> param (-128 :: Int8)) `shouldReturn` Only (-128 :: Int16)
      it "is rejected by a tinyint column rather than stored as 255" $ \conn -> do
        _ <- execute conn "CREATE TABLE #int8_tiny (v tinyint)"
        r <- try (execute conn ("INSERT INTO #int8_tiny VALUES (" <> param (-1 :: Int8) <> ")"))
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 220  -- arithmetic overflow
          Right n -> do
            rows <- query conn "SELECT v FROM #int8_tiny"
            expectationFailure ("inserted " ++ show n ++ " row(s): " ++ show (rows :: [Only Word8]))

    describe "values that don't fit" $ do
      let rejects :: Integer -> Expectation
          rejects v = withTestDb $ \conn -> do
            r <- try (query1 conn ("SELECT " <> param v))
            case r of
              Left (EncodeError msg) -> msg `shouldContain` "decimal(38,0)"
              Right (Only (x :: Integer)) -> expectationFailure ("sent " ++ show v ++ ", got " ++ show x)
      it "rejects Integer beyond decimal(38,0)" $ \_ -> do
        rejects (dec38 + 1)
        rejects (negate dec38 - 1)
        rejects (2 ^ (128 :: Int))
        rejects (2 ^ (128 :: Int) + 5)
        rejects (negate (10 ^ (100 :: Int)))
      it "rejects them in a Maybe too" $ \conn -> do
        r <- try (query1 conn (mkQuery "SELECT @p1" (Only (Just (dec38 + 1)))))
        case r of
          Left (EncodeError _) -> pure ()
          Right (Only (x :: Maybe Integer)) -> expectationFailure ("got " ++ show x)
      it "types a NULL Integer as bigint" $ \conn -> do
        query1 conn ("SELECT " <> param (Nothing :: Maybe Integer)) `shouldReturn` Only (Nothing :: Maybe Integer)
        query1 conn (mkQuery "SELECT CAST(SQL_VARIANT_PROPERTY(ISNULL(@p1, 0), 'BaseType') AS nvarchar(128))"
          (Only (Nothing :: Maybe Integer))) `shouldReturn` Only ("bigint" :: Text)

  describe "decoding" $ do
    forM_ sqlTypes $ \st -> describe (T.unpack (sqlName st)) $ do
      forM_ hTypes $ \(HType hname hrange proxy) -> do
        let accepts = sqlIsInteger st || hname == "Integer"
        it ("into " ++ hname ++ (if accepts then "" else " (rejected)")) $ \conn -> do
          results <- mapM (\v -> (v,) <$> decodeAs proxy conn (sqlName st) v) (probeValues st)
          let wrong =
                [ (v, r)
                | (v, r) <- results
                , let ok = accepts && maybe True (`inRange` v) hrange
                , case r of
                    Right x -> not ok || x /= v
                    Left _ -> ok
                ]
          wrong `shouldBe` []
      it "into Decimal" $ \conn -> forM_ (probeValues st) $ \v ->
        query1 conn (rawSql ("SELECT CAST(" <> T.pack (show v) <> " AS " <> sqlName st <> ")"))
          `shouldReturn` Only (Decimal 0 v :: Decimal)

    it "decodes tinyint 255 as Decimal 255, not -1 (regression)" $ \conn ->
      query1 conn "SELECT CAST(255 AS tinyint)" `shouldReturn` Only (255 :: Decimal)
    it "rejects decimal with a nonzero scale as Integer" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1 AS decimal(10,2))")
      case r of
        Left (DecodeError _ _) -> pure ()
        Right (Only (x :: Integer)) -> expectationFailure ("decoded " ++ show x)
    it "reports out-of-range values with the column name" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(300 AS smallint) AS big")
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Just "big"
          msg `shouldContain` "out of range"
        Right (Only (x :: Word8)) -> expectationFailure ("decoded " ++ show x)
    it "decodes bit as Bool, and nothing else" $ \conn -> do
      query1 conn "SELECT CAST(1 AS bit), CAST(0 AS bit)" `shouldReturn` (True, False)
      r <- try (query1 conn "SELECT CAST(1 AS int)")
      case r of
        Left (DecodeError _ _) -> pure ()
        Right (Only b) -> expectationFailure ("decoded " ++ show (b :: Bool))
