{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TupleSections #-}
-- | Random schemas and data for the differential tests ("Differential.*"),
-- with the server as ground truth.
--
-- A 'Table' is a list of columns of random SQL types (every type hmssql
-- supports, with random lengths, precisions, scales and collations) and rows
-- of random values, biased towards boundaries.  Each value carries
--
-- * a T-SQL literal, so a table can be filled without hmssql's parameter
--   encoding ('setupTable'), and
-- * the 'SqlValue' to send as a parameter for it ('rowParams').
--
-- Every column also has a /canonical rendering/: 'serverCanon' is a T-SQL
-- expression that renders a cell as exact text (digits, or hex of the bytes
-- the server holds, or of the server's own conversion of a string to UTF-16),
-- and 'canonHs' renders a decoded 'SqlValue' into the same form.  Comparing
-- the two checks decoding against the server without trusting hmssql's
-- decoders for anything but short ASCII strings.
module Differential.Schema
  ( -- * Schemas
    ColType (..)
  , StrKind (..)
  , Len (..)
  , Coll (..)
  , Column (..)
  , Cell (..)
  , Table (..)
  , collations
  , collationsFor
  , genTable
  , genVal
    -- * SQL
  , colTypeSql
  , typeName
  , createSql
  , literalInsertSql
  , setupTable
  , createTable
  , paramInsertSql
  , rowParams
  , selectSql
  , paddedSelectSql
  , canonSelectSql
  , scriptFor
  , readCanon
    -- * Canonical forms
  , serverCanon
  , canonHs
  , renderScaled
  , hexText
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (DecimalRaw (..))
import Data.Fixed (E12, Fixed (..))
import Data.Int (Int16, Int32, Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Data.Word (Word16, Word32, Word8)
import GHC.Float (castDoubleToWord64, castFloatToWord32, castWord32ToFloat, castWord64ToDouble)
import Hedgehog (Gen, Size (..))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Numeric (showEFloat, showHex)
import Text.Printf (printf)

import Hmssql
import Hmssql.Query hiding (Cell)
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Tds.CodePage (singleByteDecoder)

------------------------------------------------------------------------------
-- Schemas

-- | A collation and its code page.
data Coll = Coll
  { collName :: !Text
  , collCodePage :: !Int
  }
  deriving stock (Eq, Show)

-- | Curated collations: the test database's default, other Windows and SQL
-- collations over every single-byte code page family, binary collations and
-- UTF-8.  (Double-byte code pages are rejected by hmssql's decoders by
-- design, so they are not generated.)
collations :: [Coll]
collations =
  [ Coll "SQL_Latin1_General_CP1_CI_AS" 1252 -- the test database's default
  , Coll "Latin1_General_100_CI_AS" 1252
  , Coll "Latin1_General_BIN2" 1252
  , Coll "Latin1_General_100_CI_AS_SC_UTF8" 65001
  , Coll "Latin1_General_100_BIN2_UTF8" 65001
  , Coll "Greek_CI_AS" 1253
  , Coll "SQL_Latin1_General_CP1253_CI_AS" 1253
  , Coll "Cyrillic_General_CI_AS" 1251
  , Coll "Hebrew_CI_AS" 1255
  , Coll "Arabic_CI_AS" 1256
  , Coll "Thai_CI_AS" 874
  , Coll "Turkish_CI_AS" 1254
  , Coll "Estonian_CI_AS" 1257
  , Coll "Vietnamese_CI_AS" 1258
  , Coll "Czech_CI_AS" 1250
  , Coll "SQL_Latin1_General_CP437_BIN" 437
  , Coll "SQL_Latin1_General_CP850_CI_AS" 850
  ]

-- | The 'collations' a SQL Server version has: before 2019, which added
-- them, none of the UTF-8 ones.
collationsFor :: Int -> [Coll]
collationsFor v
  | v < 2019 = filter ((/= 65001) . collCodePage) collations
  | otherwise = collations

-- | The legacy @text@ type rejects UTF-8 and supplementary-character (_SC)
-- collations.
textCollations :: [Coll] -> [Coll]
textCollations =
  filter (\c -> collCodePage c /= 65001 && not ("_SC" `T.isInfixOf` collName c))

data Len = LenN !Int | LenMax
  deriving stock (Eq, Show)

data StrKind = KChar | KVarChar | KNChar | KNVarChar
  deriving stock (Eq, Show)

isNKind :: StrKind -> Bool
isNKind k = k == KNChar || k == KNVarChar

data ColType
  = TTinyInt
  | TSmallInt
  | TInt
  | TBigInt
  | TBit
  | TDecimal !Bool !Int !Int -- ^ numeric?, precision, scale
  | TMoney
  | TSmallMoney
  | TFloat !Int -- ^ float(n); n <= 24 is real
  | TReal
  | TDate
  | TTime !Int
  | TDateTime
  | TSmallDateTime
  | TDateTime2 !Int
  | TDateTimeOffset !Int
  | TStr !StrKind !Len !Coll
  | TBinary !Int
  | TVarBinary !Len
  | TGuid
  | TXml
  | TVariant
  | TText !Coll
  | TNText
  | TImage
  | TRowVersion
  deriving stock (Eq, Show)

isRealType :: ColType -> Bool
isRealType = \case
  TFloat n -> n <= 24
  TReal -> True
  _ -> False

isDoubleType :: ColType -> Bool
isDoubleType = \case
  TFloat n -> n > 24
  _ -> False

data Column = Column
  { colName :: !Text
  , colType :: !ColType
  , colNullable :: !Bool
  }
  deriving stock (Eq, Show)

data Cell
  = CNull
  | CAuto -- ^ rowversion: generated by the server
  | CVal
      { cellLit :: !Text -- ^ T-SQL expression for the value
      , cellSend :: !SqlValue -- ^ the same value as a parameter
      , cellExactLit :: !Bool
        -- ^ whether the literal is exactly the parameter's value (false for
        -- float literals, which the server's parser may round differently)
      }
  deriving stock (Show)

data Table = Table
  { tableColumns :: ![Column]
  , tableRows :: ![[Cell]]
  }
  deriving stock (Show)

------------------------------------------------------------------------------
-- Generators

-- | A random table: 1-40 columns, 0-200 rows (fewer when the columns are
-- wide), and a per-table NULL rate so some tables are mostly NULL.
--
-- Hedgehog grows 'Size' by one per test, so a short run would only ever see
-- tiny tables; the size is drawn at random instead (and shrinks to 0).  The
-- string types take their collations from @cs@ ('collationsFor').
genTable :: [Coll] -> Gen Table
genTable cs = do
  sz <- Gen.int (Range.constant 0 99)
  Gen.resize (Size sz) $ do
    cols <- fixColumns <$> Gen.list (Range.linear 1 40) (genColumn cs)
    nullPct <- Gen.element [0, 5, 20, 50, 90, 100]
    let maxRows = max 1 (min 200 (600_000 `div` sum (map (costOf . colType) cols)))
    rows <- Gen.list (Range.linear 0 maxRows) (traverse (genCell cs nullPct) cols)
    pure (Table cols rows)

genColumn :: [Coll] -> Gen Column
genColumn cs = Column "" <$> genColType cs <*> Gen.bool

-- | Name the columns, keep at most one rowversion (NOT NULL), and keep the
-- fixed-length part of a row well under the 8060-byte row limit.
fixColumns :: [Column] -> [Column]
fixColumns cols0 = capWidths (zipWith name [1 :: Int ..] (oneRowversion False cols0))
  where
    name i c = c { colName = "c" <> tshow i }
    oneRowversion _ [] = []
    oneRowversion seen (c : cs)
      | colType c == TRowVersion =
          if seen
            then c { colType = TBinary 8 } : oneRowversion seen cs
            else c { colNullable = False } : oneRowversion True cs
      | otherwise = c : oneRowversion seen cs
    capWidths cs
      | sum (map (fixedWidth . colType) cs) <= 6000 = cs
      | otherwise = map cap cs
    cap c = c
      { colType = case colType c of
          TStr KChar (LenN n) co -> TStr KChar (LenN (min n 20)) co
          TStr KNChar (LenN n) co -> TStr KNChar (LenN (min n 10)) co
          TBinary n -> TBinary (min n 20)
          t -> t
      }
    fixedWidth = \case
      TStr KChar (LenN n) _ -> n
      TStr KNChar (LenN n) _ -> 2 * n
      TBinary n -> n
      _ -> 17

-- | Rough worst-case bytes per row, to bound the size of a table.
costOf :: ColType -> Int
costOf = \case
  TStr k (LenN n) _ -> if isNKind k then 2 * n else n
  TStr _ LenMax _ -> 10_000
  TVarBinary (LenN n) -> n
  TVarBinary LenMax -> 10_000
  TBinary n -> n
  TText _ -> 10_000
  TNText -> 10_000
  TImage -> 10_000
  TXml -> 2_000
  TVariant -> 100
  _ -> 10

genColType :: [Coll] -> Gen ColType
genColType cs = Gen.choice
  [ pure TTinyInt, pure TSmallInt, pure TInt, pure TBigInt, pure TBit
  , genDecimalType
  , pure TMoney, pure TSmallMoney
  , TFloat <$> Gen.int (Range.constant 1 53), pure TReal
  , pure TDate, TTime <$> genScale, pure TDateTime, pure TSmallDateTime
  , TDateTime2 <$> genScale, TDateTimeOffset <$> genScale
  , genStrType cs, genStrType cs, genStrType cs, genStrType cs
  , TBinary <$> genN 8000, TVarBinary <$> genLen 8000
  , pure TGuid, pure TXml, pure TVariant, pure TVariant
  , TText <$> Gen.element (textCollations cs), pure TNText, pure TImage
  , pure TRowVersion
  ]

genScale :: Gen Int
genScale = Gen.int (Range.constant 0 7)

genDecimalType :: Gen ColType
genDecimalType = do
  num <- Gen.bool
  p <- Gen.frequency [(1, Gen.element [1, 38]), (3, Gen.int (Range.constant 1 38))]
  s <- Gen.frequency [(1, Gen.element [0, p]), (2, Gen.int (Range.constant 0 p))]
  pure (TDecimal num p s)

-- | A declared length: mostly short, sometimes the type's maximum.
genN :: Int -> Gen Int
genN cap = Gen.frequency
  [ (6, Gen.int (Range.linear 1 30))
  , (2, Gen.int (Range.linear 1 500))
  , (1, Gen.element [cap, cap - 1])
  , (1, Gen.int (Range.linear 1 cap))
  ]

genLen :: Int -> Gen Len
genLen cap = Gen.frequency [(3, LenN <$> genN cap), (1, pure LenMax)]

genStrType :: [Coll] -> Gen ColType
genStrType cs = do
  k <- Gen.element [KChar, KVarChar, KNChar, KNVarChar]
  let cap = if isNKind k then 4000 else 8000
  l <- if k == KChar || k == KNChar then LenN <$> genN cap else genLen cap
  TStr k l <$> Gen.element cs

genCell :: [Coll] -> Int -> Column -> Gen Cell
genCell cs nullPct col
  | colType col == TRowVersion = pure CAuto
  | colNullable col && nullPct >= 100 = pure CNull
  | colNullable col && nullPct > 0 =
      Gen.frequency [(nullPct, pure CNull), (100 - nullPct, genVal cs (colType col))]
  | otherwise = genVal cs (colType col)

val :: Text -> SqlValue -> Cell
val l v = CVal l v True

-- | A random non-NULL value of a column type; a @sql_variant@ of a string
-- type takes its collation from @cs@.
genVal :: [Coll] -> ColType -> Gen Cell
genVal cs ty = case ty of
  TTinyInt -> (\w -> val (tshow w) (SqlWord8 w)) <$> genBounded @Word8
  TSmallInt -> (\i -> val (tshow i) (SqlInt16 i)) <$> genBounded @Int16
  TInt -> (\i -> val (tshow i) (SqlInt32 i)) <$> genBounded @Int32
  TBigInt -> (\i -> val (tshow i) (SqlInt64 i)) <$> genBounded @Int64
  TBit -> (\b -> val (if b then "1" else "0") (SqlBool b)) <$> Gen.bool
  TDecimal _ p s -> do
    m <- genMantissa p
    pure (val (renderScaled m s) (SqlDecimal (Decimal (fromIntegral s) m)))
  TMoney -> money . toInteger <$> genBounded @Int64
  TSmallMoney -> money . toInteger <$> genBounded @Int32
  _ | isRealType ty -> do
        f <- genFloat
        pure (CVal ("CAST(" <> floatLit (realToFrac f) <> " AS real)") (SqlFloat f) False)
    | isDoubleType ty -> (\d -> CVal (floatLit d) (SqlDouble d) False) <$> genDouble
  TDate -> (\d -> val ("CAST('" <> renderDay d <> "' AS date)") (SqlDate d)) <$> genDay
  TTime s -> do
    tod <- unitsToTod s <$> genUnits s
    pure (val ("CAST('" <> renderTod s tod <> "' AS " <> typeName ty <> ")") (SqlTime tod))
  TDateTime2 s -> do
    lt <- LocalTime <$> genDay <*> (unitsToTod s <$> genUnits s)
    pure (val ("CAST('" <> renderLocal 'T' s lt <> "' AS " <> typeName ty <> ")") (SqlDateTime lt))
  TDateTimeOffset s -> do
    d <- genDay
    u <- genUnits s
    off0 <- Gen.frequency [(1, Gen.element [0, 840, -840]), (3, Gen.int16 (Range.constant (-840) 840))]
    let utc = UTCTime d (picosecondsToDiffTime (u * 10 ^ (12 - s)))
        localAt o = utcToLocalTime (minutesToTimeZone (fromIntegral o)) utc
        off = if inDateRange (localDay (localAt off0)) then off0 else 0
    pure $ val
      ("CAST('" <> renderLocal 'T' s (localAt off) <> renderOffset off <> "' AS " <> typeName ty <> ")")
      (SqlDateTimeOffset (DateTimeOffset utc off))
  TDateTime -> do
    days <- Gen.frequency [(1, Gen.element [-53690, 2958463, 0, -1]), (4, Gen.int32 (Range.constant (-53690) 2958463))]
    ticks <- Gen.frequency [(1, Gen.element [0, 1, 25919999]), (4, Gen.word32 (Range.constant 0 25919999))]
    pure $ val
      ("CAST(0x" <> hex32 (fromIntegral days) <> hex32 ticks <> " AS datetime)")
      (SqlDateTime (LocalTime (addDays (toInteger days) epoch1900)
                     (timeToTimeOfDay (picosecondsToDiffTime (toInteger ticks * 1_000_000_000_000 `div` 300)))))
  TSmallDateTime -> do
    days <- Gen.frequency [(1, Gen.element [0, 65535]), (4, Gen.word16 Range.constantBounded)]
    mins <- Gen.frequency [(1, Gen.element [0, 1439]), (4, Gen.word16 (Range.constant 0 1439))]
    pure $ val
      ("CAST(0x" <> hex16 days <> hex16 mins <> " AS smalldatetime)")
      (SqlDateTime (LocalTime (addDays (toInteger days) epoch1900)
                     (timeToTimeOfDay (fromIntegral (toInteger mins * 60)))))
  TGuid -> do
    u <- Gen.frequency
      [ (1, Gen.element [UUID.nil, UUID.fromWords maxBound maxBound maxBound maxBound])
      , (4, UUID.fromWords <$> w32 <*> w32 <*> w32 <*> w32)
      ]
    pure (val ("CAST('" <> UUID.toText u <> "' AS uniqueidentifier)") (SqlGuid u))
  TStr k l c -> genStrCell k (strCap k l) c
  TBinary n -> binCell <$> genBytes n
  TVarBinary l -> binCell <$> genBytes (case l of LenN n -> n; LenMax -> 10_000)
  TImage -> binCell <$> genBytes 10_000
  TXml -> (\t -> val (nLit t) (SqlXml t)) <$> genXml
  TNText -> (\t -> val (nLit t) (SqlText t)) <$> genUnitsText 5_000
  TText c -> do
    bs <- genBytes 10_000
    let t = decodeCp (collCodePage c) bs
        -- A varchar expression has the database's collation (code page 1252);
        -- converting it to another code page would change the bytes.
        lit
          | collCodePage c == 1252 = "CAST(" <> hexLit bs <> " AS varchar(max))"
          | otherwise = nLit t
    pure (val lit (SqlText t))
  TVariant -> genVariantCell cs
  TRowVersion -> pure CAuto
  _ -> error ("genVal: " ++ show ty)
  where
    money m = val (renderScaled m 4) (SqlMoney (Money (MkFixed m)))
    w32 = Gen.word32 Range.constantBounded
    binCell bs = val (hexLit bs) (SqlBinary bs)

strCap :: StrKind -> Len -> Int
strCap k = \case
  LenN n -> n
  LenMax -> if isNKind k then 5_000 else 10_000

-- | Character data.  Single-byte code pages get random bytes (all values),
-- inserted raw; the parameter is their decoding.  UTF-8 and n-types get
-- random text, including non-BMP characters.
genStrCell :: StrKind -> Int -> Coll -> Gen Cell
genStrCell k m c
  | isNKind k = (\t -> val (nLit t) (SqlText t)) <$> genUnitsText m
  | collCodePage c == 65001 = (\t -> val (hexLit (T.encodeUtf8 t)) (SqlText t)) <$> genUtf8Text m
  | otherwise = (\bs -> val (hexLit bs) (SqlText (decodeCp (collCodePage c) bs))) <$> genBytes m

decodeCp :: Int -> B.ByteString -> Text
decodeCp cp = maybe (error ("no decoder for code page " ++ show cp)) id (singleByteDecoder (fromIntegral cp))

genBounded :: forall a. (Integral a, Bounded a) => Gen a
genBounded = Gen.frequency
  [ (1, Gen.element (nub [minBound, maxBound, 0, 1, fromInteger (max (toInteger (minBound @a)) (-1))]))
  , (3, Gen.integral Range.constantBounded)
  , (1, Gen.integral (Range.linear 0 100))
  ]

genMantissa :: Int -> Gen Integer
genMantissa p = do
  let maxM = 10 ^ p - 1
  Gen.frequency
    [ (1, Gen.element [0, 1, -1, maxM, negate maxM])
    , (4, do
          d <- Gen.int (Range.constant 1 p)
          m <- Gen.integral (Range.constant 0 (10 ^ d - 1))
          neg <- Gen.bool
          pure (if neg then negate m else m))
    ]

genDouble :: Gen Double
genDouble = Gen.frequency
  [ (2, Gen.element
          [ 0, -0.0, 1, -1, 0.1, 0.5, 1e15, 2 ^ (53 :: Int), pi
          , castWord64ToDouble 0x7FEFFFFFFFFFFFFF, castWord64ToDouble 0xFFEFFFFFFFFFFFFF
          , castWord64ToDouble 0x0010000000000000, castWord64ToDouble 0x8010000000000000
          , castWord64ToDouble 1 ])
  , (2, fromIntegral <$> Gen.int (Range.linearFrom 0 (-1000) 1000))
  , (3, finite . castWord64ToDouble <$> Gen.word64 Range.constantBounded)
  , (1, Gen.double (Range.linearFracFrom 0 (-1e6) 1e6))
  ]
  where
    finite d = if isNaN d || isInfinite d then 1.5 else d

genFloat :: Gen Float
genFloat = Gen.frequency
  [ (2, Gen.element
          [ 0, -0.0, 1, -1, 0.1, 0.5, 16777216, castWord32ToFloat 0x7F7FFFFF, castWord32ToFloat 0xFF7FFFFF
          , castWord32ToFloat 0x00800000, castWord32ToFloat 1 ])
  , (2, fromIntegral <$> Gen.int (Range.linearFrom 0 (-1000) 1000))
  , (3, finite . castWord32ToFloat <$> Gen.word32 Range.constantBounded)
  ]
  where
    finite f = if isNaN f || isInfinite f then 1.5 else f

floatLit :: Double -> Text
floatLit d = T.pack (showEFloat Nothing d "")

epoch1900 :: Day
epoch1900 = fromGregorian 1900 1 1

minDay, maxDay :: Day
minDay = fromGregorian 1 1 1
maxDay = fromGregorian 9999 12 31

inDateRange :: Day -> Bool
inDateRange d = d >= minDay && d <= maxDay

genDay :: Gen Day
genDay = Gen.frequency
  [ (1, Gen.element
          [ minDay, maxDay, epoch1900, fromGregorian 2000 2 29, fromGregorian 1582 10 4
          , fromGregorian 1582 10 15, fromGregorian 1753 1 1, fromGregorian 1970 1 1 ])
  , (4, ModifiedJulianDay <$> Gen.integral (Range.constant (toModifiedJulianDay minDay) (toModifiedJulianDay maxDay)))
  ]

-- | Clock units at a scale (10^-s seconds) since midnight.
genUnits :: Int -> Gen Integer
genUnits s = do
  let maxU = 86400 * 10 ^ s - 1
  Gen.frequency [(1, Gen.element [0, 1, maxU]), (4, Gen.integral (Range.constant 0 maxU))]

unitsToTod :: Int -> Integer -> TimeOfDay
unitsToTod s u = timeToTimeOfDay (picosecondsToDiffTime (u * 10 ^ (12 - s)))

-- | A length up to @m@, biased to short, empty and exactly @m@.
genLenUpTo :: Int -> Gen Int
genLenUpTo m = Gen.frequency
  [ (4, Gen.int (Range.linear 0 (min m 16)))
  , (1, Gen.element (nub [0, min m 1, m, max 0 (m - 1)]))
  , (1, Gen.int (Range.linear 0 m))
  ]

genBytes :: Int -> Gen B.ByteString
genBytes m = do
  len <- genLenUpTo m
  Gen.frequency
    [ (4, Gen.bytes (Range.singleton len))
    , (1, pure (B.pack (take len (cycle [0 .. 255]))))
    , (1, B.replicate len <$> Gen.element [0, 0x20, 0x7F, 0x80, 0xFF])
    ]

genChar :: Gen Char
genChar = Gen.frequency
  [ (6, Gen.enum 'a' 'z')
  , (2, Gen.enum ' ' '~')
  , (1, Gen.enum '\x00' '\x1F')
  , (2, Gen.enum '\x80' '\xFF')
  , (2, Gen.enum '\x100' '\xD7FF')
  , (1, Gen.enum '\xE000' '\xFFFF')
  , (2, Gen.enum '\x10000' '\x10FFFF')
  , (1, Gen.element ['\x0', '\'', '\xFFFD', '\xFEFF', '\xFFFE', '\xFFFF', '\x10FFFF', '\x1F600', '\x10000'])
  ]

-- | Text of at most @m@ UTF-16 code units; exactly the chosen length (padded
-- with @x@ when a surrogate pair didn't fit).
genUnitsText :: Int -> Gen Text
genUnitsText m = fitted units m genChar

genUtf8Text :: Int -> Gen Text
genUtf8Text m = fitted (B.length . T.encodeUtf8 . T.singleton) m genChar

fitted :: (Char -> Int) -> Int -> Gen Char -> Gen Text
fitted size m gc = do
  len <- genLenUpTo m
  cs <- Gen.list (Range.singleton len) gc
  let go n (c : rest) | n + size c <= len = c : go (n + size c) rest
      go n _ = replicate (len - n) 'x'
  pure (T.pack (go 0 cs))

units :: Char -> Int
units c = if c >= '\x10000' then 2 else 1

-- | A small XML document or fragment.
genXml :: Gen Text
genXml = Gen.frequency
  [ (1, pure "")
    -- Converting a literal to xml drops a leading U+FEFF (as a byte order
    -- mark), so the literal table would differ from the parameter table.
  , (1, Gen.filter (not . T.isPrefixOf "\xFEFF") (escText <$> genXmlText 20))
  , (6, genElem (3 :: Int))
  ]
  where
    genElem depth = do
      name <- Gen.element ["a", "b", "row", "x1", "\xE9l\xE9ment", "\x4E2D"]
      attrs <- Gen.subsequence ["k", "v", "id"] >>= traverse (\k -> (k,) <$> genXmlText 10)
      kids <- if depth <= 0 then pure [] else
        Gen.list (Range.linear 0 3) (Gen.choice [escText <$> genXmlText 20, genElem (depth - 1)])
      pure $ "<" <> name <> foldMap (\(k, v) -> " " <> k <> "=\"" <> escAttr v <> "\"") attrs
        <> (if null kids then "/>" else ">" <> mconcat kids <> "</" <> name <> ">")
    genXmlText n = T.pack <$> Gen.list (Range.linear 0 n) (Gen.filter xmlOk genChar)
    xmlOk c = c == '\t' || c == '\n' || c == '\r' || (c >= ' ' && c /= '\xFFFE' && c /= '\xFFFF')
    escText = T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"
    escAttr = T.replace "\"" "&quot;" . T.replace "\t" "&#9;" . T.replace "\n" "&#10;"
      . T.replace "\r" "&#13;" . escText

-- | sql_variant: a random base type (no max, LOB, xml or variant types) and
-- a value of it.
genVariantCell :: [Coll] -> Gen Cell
genVariantCell cs = do
  base <- Gen.choice
    [ pure TTinyInt, pure TSmallInt, pure TInt, pure TBigInt, pure TBit, genDecimalType
    , pure TMoney, pure TSmallMoney, pure (TFloat 53), pure TReal
    , pure TDate, TTime <$> genScale, pure TDateTime, pure TSmallDateTime
    , TDateTime2 <$> genScale, TDateTimeOffset <$> genScale, pure TGuid
    , do
        k <- Gen.element [KChar, KVarChar, KNChar, KNVarChar]
        n <- Gen.int (Range.linear 1 50)
        TStr k (LenN n) <$> Gen.element cs
    , TBinary <$> Gen.int (Range.linear 1 50)
    , TVarBinary . LenN <$> Gen.int (Range.linear 1 50)
    ]
  genVal cs base >>= \case
    CVal lit v exact -> do
      let lit' = case (base, v) of
            -- nvarchar with the collation, converted with its code page
            (TStr _ _ c, SqlText t) -> "CAST(" <> nLit t <> " COLLATE " <> collName c <> " AS " <> typeName base <> ")"
            _ -> "CAST(" <> lit <> " AS " <> typeName base <> ")"
      pure (CVal lit' (padStored base v) exact)
    other -> pure other

-- | What a fixed-length column stores for a shorter value.
padStored :: ColType -> SqlValue -> SqlValue
padStored ty v = case (ty, v) of
  (TStr KChar (LenN n) c, SqlText t) -> SqlText (t <> T.replicate (n - byteLen c t) " ")
  (TStr KNChar (LenN n) _, SqlText t) -> SqlText (t <> T.replicate (n - sum (map units (T.unpack t))) " ")
  (TBinary n, SqlBinary b) -> SqlBinary (b <> B.replicate (n - B.length b) 0)
  _ -> v
  where
    byteLen c t = if collCodePage c == 65001 then B.length (T.encodeUtf8 t) else T.length t

------------------------------------------------------------------------------
-- SQL

tshow :: Show a => a -> Text
tshow = T.pack . show

typeName :: ColType -> Text
typeName = \case
  TTinyInt -> "tinyint"
  TSmallInt -> "smallint"
  TInt -> "int"
  TBigInt -> "bigint"
  TBit -> "bit"
  TDecimal num p s -> (if num then "numeric(" else "decimal(") <> tshow p <> "," <> tshow s <> ")"
  TMoney -> "money"
  TSmallMoney -> "smallmoney"
  TFloat n -> "float(" <> tshow n <> ")"
  TReal -> "real"
  TDate -> "date"
  TTime s -> "time(" <> tshow s <> ")"
  TDateTime -> "datetime"
  TSmallDateTime -> "smalldatetime"
  TDateTime2 s -> "datetime2(" <> tshow s <> ")"
  TDateTimeOffset s -> "datetimeoffset(" <> tshow s <> ")"
  TStr k l _ -> kindName k <> lenSql l
  TBinary n -> "binary(" <> tshow n <> ")"
  TVarBinary l -> "varbinary" <> lenSql l
  TGuid -> "uniqueidentifier"
  TXml -> "xml"
  TVariant -> "sql_variant"
  TText _ -> "text"
  TNText -> "ntext"
  TImage -> "image"
  TRowVersion -> "rowversion"
  where
    kindName = \case
      KChar -> "char"
      KVarChar -> "varchar"
      KNChar -> "nchar"
      KNVarChar -> "nvarchar"
    lenSql = \case
      LenN n -> "(" <> tshow n <> ")"
      LenMax -> "(max)"

colTypeSql :: ColType -> Text
colTypeSql ty = typeName ty <> case ty of
  TStr _ _ c -> " COLLATE " <> collName c
  TText c -> " COLLATE " <> collName c
  _ -> ""

quoteCol :: Column -> Text
quoteCol c = "[" <> colName c <> "]"

-- | The columns an INSERT names (not the rowversion).
insertedColumns :: Table -> [(Int, Column)]
insertedColumns t = filter ((/= TRowVersion) . colType . snd) (zip [0 ..] (tableColumns t))

createSql :: Text -> Table -> Text
createSql tbl t =
  "CREATE TABLE " <> tbl <> " (_rid int NOT NULL PRIMARY KEY"
    <> foldMap (\c -> ", " <> quoteCol c <> " " <> colTypeSql (colType c) <> (if colNullable c then " NULL" else " NOT NULL")) (tableColumns t)
    <> ");"

literalInsertSql :: Text -> Table -> Text
literalInsertSql tbl t = T.unlines
  [ "INSERT INTO " <> tbl <> " (" <> T.intercalate ", " ("_rid" : map (quoteCol . snd) ins) <> ") VALUES ("
      <> T.intercalate ", " (tshow i : [lit (row !! j) | (j, _) <- ins]) <> ");"
  | (i, row) <- zip [1 :: Int ..] (tableRows t)
  ]
  where
    ins = insertedColumns t
    lit = \case
      CNull -> "NULL"
      CAuto -> "DEFAULT"
      CVal l _ _ -> l

-- | Drop, create and fill the table with literals.  The DROP is a batch of
-- its own: a batch is compiled against the temporary tables that exist when
-- it starts, so an INSERT in the same batch would see the old table.
setupTable :: Connection -> Text -> Table -> IO ()
setupTable conn tbl t = do
  _ <- execute conn (rawSql ("DROP TABLE IF EXISTS " <> tbl))
  _ <- execute conn (rawSql (createSql tbl t <> "\n" <> literalInsertSql tbl t))
  pure ()

-- | Drop and create the (empty) table.
createTable :: Connection -> Text -> Table -> IO ()
createTable conn tbl t = do
  _ <- execute conn (rawSql ("DROP TABLE IF EXISTS " <> tbl))
  _ <- execute conn (rawSql (createSql tbl t))
  pure ()

-- | The script that reproduces a table, for counterexamples.
scriptFor :: Text -> Table -> String
scriptFor tbl t = T.unpack (createSql tbl t <> "\n" <> literalInsertSql tbl t)

paramInsertSql :: Text -> Table -> Text
paramInsertSql tbl t =
  "INSERT INTO " <> tbl <> " (" <> T.intercalate ", " ("_rid" : map (quoteCol . snd) ins) <> ") VALUES ("
    <> T.intercalate ", " ["@p" <> tshow i | i <- [1 .. length ins + 1]] <> ")"
  where
    ins = insertedColumns t

-- | Parameters for 'paramInsertSql'.  NULLs are sent as 'SqlNull' (an
-- untyped nvarchar NULL) where the server converts that implicitly, and as a
-- typed NULL for binary types (nvarchar never converts to binary implicitly)
-- and sql_variant (see "Differential.EncodeSpec").
rowParams :: Table -> Int -> [Cell] -> [SqlParam]
rowParams t i row = SqlParam (fromIntegral i :: Int32) : [param (colType col) (row !! j) | (j, col) <- insertedColumns t]
  where
    param ty = \case
      CVal _ v _ -> SqlParam v
      _ -> case ty of
        TBinary _ -> SqlParam (Nothing :: Maybe B.ByteString)
        TVarBinary _ -> SqlParam (Nothing :: Maybe B.ByteString)
        TImage -> SqlParam (Nothing :: Maybe B.ByteString)
        TVariant -> SqlParam (Nothing :: Maybe Int32)
        _ -> SqlParam SqlNull

selectSql :: Text -> Table -> Text
selectSql tbl t =
  "SELECT " <> T.intercalate ", " (map quoteCol (tableColumns t)) <> " FROM " <> tbl <> " ORDER BY _rid"

-- | 'selectSql' followed by @n@ NULL columns, so that every row is mostly
-- NULL and the server sends NBCROW tokens.
paddedSelectSql :: Int -> Text -> Table -> Text
paddedSelectSql n tbl t =
  "SELECT " <> T.intercalate ", " (map quoteCol (tableColumns t) ++ ["CAST(NULL AS int) AS [n" <> tshow i <> "]" | i <- [1 .. n]])
    <> " FROM " <> tbl <> " ORDER BY _rid"

canonSelectSql :: Text -> Table -> Text
canonSelectSql tbl t =
  "SELECT " <> T.intercalate ", " [canonCol c | c <- tableColumns t] <> " FROM " <> tbl <> " ORDER BY _rid"
  where
    canonCol c = "CASE WHEN " <> quoteCol c <> " IS NULL THEN NULL ELSE " <> serverCanon (colType c) (quoteCol c) <> " END"

-- | The server's canonical rendering of every cell ('Nothing' for NULL).
readCanon :: Connection -> Text -> Table -> IO [[Maybe Text]]
readCanon conn tbl t = map (map toM . sqlRowValues) <$> queryMWith sqlRowDecoder conn (rawSql (canonSelectSql tbl t))
  where
    toM = \case
      SqlNull -> Nothing
      SqlText x -> Just x
      v -> error ("canonical column decoded as " ++ show v)

------------------------------------------------------------------------------
-- Canonical forms

-- | A T-SQL expression rendering a (non-NULL) cell of the given type as
-- @nvarchar(max)@.
serverCanon :: ColType -> Text -> Text
serverCanon ty c = case ty of
  TTinyInt -> str
  TSmallInt -> str
  TInt -> str
  TBigInt -> str
  TBit -> str
  TDecimal{} -> str
  TMoney -> styled 2
  TSmallMoney -> styled 2
  TFloat _ -> hexOf ("CAST(" <> c <> " AS varbinary(8))")
  TReal -> hexOf ("CAST(" <> c <> " AS varbinary(8))")
  TDate -> styled 23
  TTime _ -> styled 121
  TDateTime2 _ -> styled 121
  TDateTimeOffset _ -> styled 121
  TDateTime -> hexOf ("CAST(" <> c <> " AS varbinary(8))")
  TSmallDateTime -> hexOf ("CAST(" <> c <> " AS varbinary(4))")
  TGuid -> str
  TStr{} -> utf16
  TText _ -> utf16
  TNText -> utf16
  TXml -> utf16
  TBinary _ -> bin
  TVarBinary _ -> bin
  TImage -> bin
  TRowVersion -> bin
  TVariant -> variantCanon c
  where
    str = "CONVERT(nvarchar(max), " <> c <> ")"
    styled (n :: Int) = "CONVERT(nvarchar(max), " <> c <> ", " <> tshow n <> ")"
    utf16 = hexOf ("CAST(CAST(" <> c <> " AS nvarchar(max)) AS varbinary(max))")
    bin = hexOf ("CAST(" <> c <> " AS varbinary(max))")

hexOf :: Text -> Text
hexOf e = "CONVERT(nvarchar(max), " <> e <> ", 2)"

-- | A sql_variant as @family:value@: the family groups base types whose
-- values hmssql decodes to the same 'SqlValue' constructor.
variantCanon :: Text -> Text
variantCanon c =
  "CASE CONVERT(sysname, SQL_VARIANT_PROPERTY(" <> c <> ", 'BaseType'))"
    <> foldMap branch families
    <> " ELSE N'?:' + CONVERT(nvarchar(max), SQL_VARIANT_PROPERTY(" <> c <> ", 'BaseType')) END"
  where
    branch (names, tag, expr) = foldMap (\n -> " WHEN '" <> n <> "' THEN N'" <> tag <> ":' + " <> expr) names
    families :: [([Text], Text, Text)]
    families =
      [ (["tinyint", "smallint", "int", "bigint"], "i", "CONVERT(nvarchar(max), CAST(" <> c <> " AS bigint))")
      , (["bit"], "b", "CONVERT(nvarchar(max), CAST(" <> c <> " AS bit))")
      , (["real"], "r", hexOf ("CAST(CAST(" <> c <> " AS real) AS varbinary(4))"))
      , (["float"], "f", hexOf ("CAST(CAST(" <> c <> " AS float) AS varbinary(8))"))
      , (["money", "smallmoney"], "m", "CONVERT(nvarchar(max), CAST(" <> c <> " AS money), 2)")
      , (["decimal", "numeric"], "d", "CONVERT(nvarchar(max), " <> c <> ")")
      , (["uniqueidentifier"], "g", "CONVERT(nvarchar(max), CAST(" <> c <> " AS uniqueidentifier))")
      , (["date"], "D", "CONVERT(nvarchar(max), CAST(" <> c <> " AS date), 23)")
      , (["time"], "t", "CONVERT(nvarchar(max), CAST(" <> c <> " AS time(7)), 121)")
      , (["datetime", "smalldatetime", "datetime2"], "T", "CONVERT(nvarchar(max), CAST(" <> c <> " AS datetime2(7)), 121)")
      , (["datetimeoffset"], "O", "CONVERT(nvarchar(max), CAST(" <> c <> " AS datetimeoffset(7)), 121)")
      , (["char", "varchar", "nchar", "nvarchar"], "s", hexOf ("CAST(CAST(" <> c <> " AS nvarchar(4000)) AS varbinary(max))"))
      , (["binary", "varbinary"], "x", hexOf ("CAST(" <> c <> " AS varbinary(8000))"))
      ]

-- | 'serverCanon' computed from a value hmssql decoded (or will send), or
-- why the value can't belong to the column type.
canonHs :: ColType -> SqlValue -> Either String (Maybe Text)
canonHs _ SqlNull = Right Nothing
canonHs ty v0 = Just <$> case (ty, padStored ty v0) of
  (TTinyInt, SqlWord8 w) -> Right (tshow w)
  (TSmallInt, SqlInt16 i) -> Right (tshow i)
  (TInt, SqlInt32 i) -> Right (tshow i)
  (TBigInt, SqlInt64 i) -> Right (tshow i)
  (TBit, SqlBool b) -> Right (if b then "1" else "0")
  (TDecimal{}, SqlDecimal d) -> Right (renderScaled (decimalMantissa d) (fromIntegral (decimalPlaces d)))
  (TMoney, SqlMoney m) -> Right (renderMoney m)
  (TSmallMoney, SqlMoney m) -> Right (renderMoney m)
  (_, SqlDouble d) | isDoubleType ty -> Right (hex64 (castDoubleToWord64 d))
  (_, SqlFloat f) | isRealType ty -> Right (hex32 (castFloatToWord32 f))
  (TDate, SqlDate d) -> Right (renderDay d)
  (TTime s, SqlTime tod) -> Right (renderTod s tod)
  (TDateTime2 s, SqlDateTime lt) -> Right (renderLocal ' ' s lt)
  (TDateTimeOffset s, SqlDateTimeOffset dto) -> Right (renderDto s dto)
  (TDateTime, SqlDateTime lt) -> Right (datetimeHex lt)
  (TSmallDateTime, SqlDateTime lt) -> Right (smallDatetimeHex lt)
  (TGuid, SqlGuid u) -> Right (T.toUpper (UUID.toText u))
  (TStr{}, SqlText t) -> Right (utf16Hex t)
  (TText _, SqlText t) -> Right (utf16Hex t)
  (TNText, SqlText t) -> Right (utf16Hex t)
  (TXml, SqlXml t) -> Right (utf16Hex t)
  (TBinary _, SqlBinary b) -> Right (hexText b)
  (TVarBinary _, SqlBinary b) -> Right (hexText b)
  (TImage, SqlBinary b) -> Right (hexText b)
  (TRowVersion, SqlBinary b) -> Right (hexText b)
  (TVariant, v) -> variantHs v
  (_, v) -> Left ("a " ++ T.unpack (typeName ty) ++ " column decoded as " ++ show v)

variantHs :: SqlValue -> Either String Text
variantHs = \case
  SqlWord8 i -> Right ("i:" <> tshow i)
  SqlInt16 i -> Right ("i:" <> tshow i)
  SqlInt32 i -> Right ("i:" <> tshow i)
  SqlInt64 i -> Right ("i:" <> tshow i)
  SqlBool b -> Right (if b then "b:1" else "b:0")
  SqlFloat f -> Right ("r:" <> hex32 (castFloatToWord32 f))
  SqlDouble d -> Right ("f:" <> hex64 (castDoubleToWord64 d))
  SqlMoney m -> Right ("m:" <> renderMoney m)
  SqlDecimal d -> Right ("d:" <> renderScaled (decimalMantissa d) (fromIntegral (decimalPlaces d)))
  SqlGuid u -> Right ("g:" <> T.toUpper (UUID.toText u))
  SqlDate d -> Right ("D:" <> renderDay d)
  SqlTime tod -> Right ("t:" <> renderTod 7 (localTimeOfDay (roundTo100ns (LocalTime epoch1900 tod))))
  SqlDateTime lt -> Right ("T:" <> renderLocal ' ' 7 (roundTo100ns lt))
  SqlDateTimeOffset dto -> Right ("O:" <> renderDto 7 dto)
  SqlText t -> Right ("s:" <> utf16Hex t)
  SqlBinary b -> Right ("x:" <> hexText b)
  v -> Left ("a sql_variant decoded as " ++ show v)

-- | @mantissa / 10^scale@ as SQL Server prints a decimal: an optional minus,
-- at least one integer digit, and exactly @scale@ fraction digits.
renderScaled :: Integer -> Int -> Text
renderScaled m s =
  let (i, f) = abs m `quotRem` (10 ^ s)
   in (if m < 0 then "-" else "") <> tshow i <> (if s > 0 then "." <> T.justifyRight s '0' (tshow f) else "")

renderMoney :: Money -> Text
renderMoney (Money (MkFixed m)) = renderScaled m 4

renderDay :: Day -> Text
renderDay d = let (y, m, dd) = toGregorian d in T.pack (printf "%04d-%02d-%02d" y m dd)

-- | @hh:mm:ss@ and exactly @s@ fraction digits; a value with more precision
-- than the scale gets all 12 picosecond digits and a @!@, so it never
-- matches the server's rendering.
renderTod :: Int -> TimeOfDay -> Text
renderTod s (TimeOfDay h m (MkFixed ps)) =
  let (whole, frac) = ps `divMod` (10 ^ (12 :: Int))
      unit = 10 ^ (12 - s)
      fracTxt
        | frac `mod` unit /= 0 = "." <> T.justifyRight 12 '0' (tshow frac) <> "!"
        | s == 0 = ""
        | otherwise = "." <> T.justifyRight s '0' (tshow (frac `div` unit))
   in T.pack (printf "%02d:%02d:%02d" h m whole) <> fracTxt

renderLocal :: Char -> Int -> LocalTime -> Text
renderLocal sep s (LocalTime d tod) = renderDay d <> T.singleton sep <> renderTod s tod

renderOffset :: Int16 -> Text
renderOffset off =
  T.pack (printf "%c%02d:%02d" (if off < 0 then '-' else '+') (abs off `div` 60) (abs off `mod` 60))

renderDto :: Int -> DateTimeOffset -> Text
renderDto s (DateTimeOffset u off) =
  renderLocal ' ' s (utcToLocalTime (minutesToTimeZone (fromIntegral off)) u) <> " " <> renderOffset off

roundTo100ns :: LocalTime -> LocalTime
roundTo100ns (LocalTime d tod) =
  let MkFixed ps = realToFrac (timeOfDayToTime tod) :: Fixed E12
      r = (ps + 50_000) `div` 100_000 * 100_000
      day = 86400 * 10 ^ (12 :: Int)
   in if r >= day
        then LocalTime (addDays 1 d) (timeToTimeOfDay (picosecondsToDiffTime (r - day)))
        else LocalTime d (timeToTimeOfDay (picosecondsToDiffTime r))

-- | datetime's storage: days since 1900 and 1/300 s ticks, big-endian.
datetimeHex :: LocalTime -> Text
datetimeHex (LocalTime d tod) =
  let ticks = round (toRational (timeOfDayToTime tod) * 300) :: Integer
   in hex32 (fromIntegral (diffDays d epoch1900)) <> hex32 (fromIntegral ticks)

-- | smalldatetime's storage: days since 1900 and minutes.
smallDatetimeHex :: LocalTime -> Text
smallDatetimeHex (LocalTime d tod) =
  let secs = toRational (timeOfDayToTime tod)
      mins = floor (secs / 60) :: Integer
   in hex16 (fromIntegral (diffDays d epoch1900)) <> hex16 (fromIntegral mins)
        <> (if secs == fromIntegral (mins * 60) then "" else "!")

utf16Hex :: Text -> Text
utf16Hex = hexText . T.encodeUtf16LE

hexText :: B.ByteString -> Text
hexText = T.toUpper . T.decodeLatin1 . LB.toStrict . BB.toLazyByteString . BB.byteStringHex

hexLit :: B.ByteString -> Text
hexLit bs = "0x" <> hexText bs

hex16 :: Word16 -> Text
hex16 w = T.toUpper (T.justifyRight 4 '0' (T.pack (showHex w "")))

hex32 :: Word32 -> Text
hex32 w = T.toUpper (T.justifyRight 8 '0' (T.pack (showHex w "")))

hex64 :: (Integral a, Show a) => a -> Text
hex64 w = T.toUpper (T.justifyRight 16 '0' (T.pack (showHex (fromIntegral w :: Integer) "")))

-- | An @nvarchar@ literal: @N'...'@ when every character is safe to embed in
-- a batch, else the UTF-16 bytes cast to @nvarchar(max)@.
nLit :: Text -> Text
nLit t
  | T.all safe t = "N'" <> T.replace "'" "''" t <> "'"
  | otherwise = "CAST(" <> hexLit (T.encodeUtf16LE t) <> " AS nvarchar(max))"
  where
    safe c =
      (c >= ' ' && c < '\x7F')
        || (c >= '\xA0' && c < '\xD800')
        || (c >= '\xE000' && c < '\xFFFE' && c /= '\xFEFF')
        || c >= '\x10000'
