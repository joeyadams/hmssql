-- | The pure conversions of SQL Server's scalar values, and the type checks
-- the field decoders make.
--
-- A reader is given exactly its value's bytes, whether they lay in one packet
-- or several, so it knows nothing about packets, and a wrong length is an
-- ordinary 'Left'.  Offsets into the bytes stay inside this module.
module Hmssql.Tds.Scalar
  ( -- * Scalar value readers
    integerValue, integerAt, bitValue, readFloating, float32Value
  , decimalValue, dayTimeValue, localTimeValue
  , SelectedReader (..), selectSqlValueReader, readSqlVariant
    -- * Character values
  , columnTextDecoder, decodeColumnText, textValue
  , TextEncoding (..), textEncodingOf, ansiCollation
    -- * Type selection and errors
  , hasDataType, rejectAs, unsupportedUdt
  , isIntegerType, unsignedByteType, isFloatType
  , isDecimalType, isMoneyType
  , isUnicodeType, isAnsiType, isBinaryType
  , isLocalTimeType, isDateTimeOffsetType
  ) where

import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import GHC.Float (castWord32ToFloat, castWord64ToDouble, float2Double)
import Hmssql.SqlValue
import Hmssql.Internal.SqlDataType (SqlDataType (..), typeInfoDataType)
import Hmssql.Tds.Bytes
import Hmssql.Tds.CodePage (TextCodec, collationCodec, collationTextDecoder, decodeCodec)
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

-- | The integer types and @bit@.
isIntegerType :: TypeInfo -> Bool
isIntegerType = hasDataType $ \case
  TyTinyInt -> True
  TySmallInt -> True
  TyInt -> True
  TyBigInt -> True
  TyBit -> True
  _ -> False

-- | The value of an integer-typed column ('isIntegerType').  Integers
-- arrive as 1, 2, 4 or 8 little-endian bytes; the value's own length is
-- authoritative.  A @tinyint@ is unsigned on the wire.
integerValue :: TypeInfo -> ValueReader Int64
integerValue ti = case ti of
  TIInt1 -> integerAt True
  TIIntN 1 -> integerAt True
  _ -> integerAt False
{-# INLINE integerValue #-}

-- | 'integerValue', given whether a one-byte value is unsigned.
integerAt :: Bool -> ValueReader Int64
integerAt unsignedByte bs = case B.length bs of
  1 | unsignedByte -> Right (fromIntegral (word8At bs 0))
    | otherwise -> Right (fromIntegral (int8At bs 0))
  n | unsignedByte -> Left (invalidLength "tinyint" n)
  n | n == 2 || n == 4 || n == 8 -> Right (signedIntegerAt bs)
  n -> Left (invalidLength "integer" n)
{-# INLINE integerAt #-}

-- The caller has checked the length.  The three signed widths are read out of
-- line, so that every built-in integer row decoder calls this one reader rather
-- than inlining a copy of the three: 4,160 bytes less of code, and the same
-- allocation in every typed decoding benchmark, because the worker takes the
-- slice's fields and returns the 'Int64' unboxed (GHC 9.12.4, 2026-11-04).
signedIntegerAt :: B.ByteString -> Int64
signedIntegerAt bs = case B.length bs of
  2 -> fromIntegral (int16LeAt bs 0)
  4 -> fromIntegral (int32LeAt bs 0)
  _ -> int64LeAt bs 0
{-# NOINLINE signedIntegerAt #-}

-- Out of line, so that a copy of 'integerAt' doesn't hold the message's 'show'.
invalidLength :: String -> Int -> String
invalidLength what n = "invalid " ++ what ++ " length " ++ show n
{-# NOINLINE invalidLength #-}

-- | Whether an integer type's one-byte values are unsigned (@tinyint@).
unsignedByteType :: TypeInfo -> Bool
unsignedByteType = \case
  TIInt1 -> True
  TIIntN 1 -> True
  _ -> False

-- | @bit@.
bitValue :: ValueReader Bool
bitValue bs
  | B.length bs == 1 = Right (word8At bs 0 /= 0)
  | otherwise = Left $ "invalid bit length " ++ show (B.length bs)

-- | @float@ and @real@.
isFloatType :: TypeInfo -> Bool
isFloatType = hasDataType $ \case
  TyFloat -> True
  TyReal -> True
  _ -> False

-- | @real@ or @float@, by the value's length.
readFloating :: ValueReader Double
readFloating bs = case B.length bs of
  4 -> Right (float2Double (float4At bs))
  8 -> Right (float8At bs)
  n -> Left $ "invalid float length " ++ show n

-- | @real@; a @float@ value is refused rather than narrowed.
float32Value :: ValueReader Float
float32Value bs
  | B.length bs == 4 = Right (float4At bs)
  | otherwise = Left "float(53) cannot be decoded as Float without losing precision; use Double"

float4At :: B.ByteString -> Float
float4At bs = castWord32ToFloat (word32LeAt bs 0)

float8At :: B.ByteString -> Double
float8At bs = castWord64ToDouble (word64LeAt bs 0)

-- | @decimal@ and @numeric@.
isDecimalType :: TypeInfo -> Bool
isDecimalType = hasDataType $ \case
  TyDecimal -> True
  TyNumeric -> True
  _ -> False

-- | @money@ and @smallmoney@.
isMoneyType :: TypeInfo -> Bool
isMoneyType = hasDataType $ \case
  TyMoney -> True
  TySmallMoney -> True
  _ -> False

-- | A @decimal@ or @numeric@ at the type's precision and scale, a @money@
-- type, or an integer type, as a 'Decimal'.
decimalValue :: TypeInfo -> ValueReader Decimal
decimalValue ti = case ti of
  TIDecimalN p s -> readDecimal p s
  TINumericN p s -> readDecimal p s
  _ | isMoneyType ti -> \bs -> moneyToDecimal <$> readMoney bs
  _ | isIntegerType ti -> \bs -> do
        i <- integerValue ti bs
        Right $! Decimal 0 (toInteger i)
  _ -> \_ -> Left "not a decimal type"
  where
    moneyToDecimal (Money (MkFixed i)) = Decimal 4 i
{-# INLINE decimalValue #-}

-- | The UTF-16 character types, @xml@ included; the single-byte character
-- types; and the binary types.
isUnicodeType, isAnsiType, isBinaryType :: TypeInfo -> Bool
isUnicodeType = hasDataType $ \case
  TyNChar -> True
  TyNVarChar -> True
  TyNText -> True
  TyXml -> True
  _ -> False
isAnsiType = hasDataType $ \case
  TyChar -> True
  TyVarChar -> True
  TyText -> True
  _ -> False
isBinaryType = hasDataType $ \case
  TyBinary -> True
  TyVarBinary -> True
  TyImage -> True
  _ -> False

-- | Compile a decoder for a character column.  Unicode types are UTF-16LE.
-- Single-byte types are decoded according to their collation's code page
-- (see "Hmssql.Tds.CodePage"); a collation whose code page hmssql can't
-- decode (a double-byte code page, or an unknown collation) is rejected.
columnTextDecoder :: TypeInfo -> Either String (ValueReader Text)
columnTextDecoder ti = case ti of
  TIBigChar _ c -> collationTextDecoder c
  TIBigVarChar _ c -> collationTextDecoder c
  TIText _ c -> collationTextDecoder c
  _ | isUnicodeType ti -> Right utf16
  _ -> Left "not a character type"
  where
    utf16 bs = Right (Utf16.decodeUtf16LE bs)

-- | The collation of a single-byte character type.
ansiCollation :: TypeInfo -> Maybe Collation
ansiCollation = \case
  TIBigChar _ c -> Just c
  TIBigVarChar _ c -> Just c
  TIText _ c -> Just c
  _ -> Nothing

-- | Decode a character value; see 'columnTextDecoder'.
decodeColumnText :: TypeInfo -> B.ByteString -> Either String Text
decodeColumnText ti bs = columnTextDecoder ti >>= \decode -> decode bs

isTextual :: TypeInfo -> Bool
isTextual ti = isUnicodeType ti || isAnsiType ti

-- | How a character column's values are encoded: UTF-16LE, or a
-- single-byte code page's codec, chosen by the collation once per column.
data TextEncoding = TextUtf16 | TextCodec !TextCodec
-- Two constructors, so that the 'Text' reader is a @case@ between two known
-- decoders.

-- | The 'TextEncoding' of a character column, or why it can't be decoded
-- as 'Text' (not a character type, or a collation whose code page hmssql
-- can't decode).
textEncodingOf :: TypeInfo -> Either String TextEncoding
textEncodingOf ti
  | isUnicodeType ti = Right TextUtf16
  | Just c <- ansiCollation ti = TextCodec <$> collationCodec c
  | otherwise = Left (rejectAs "Text" ti)

-- | A character value as 'Text', in the column's encoding.
textValue :: TextEncoding -> ValueReader Text
textValue TextUtf16 bs = Right $! Utf16.decodeUtf16LE bs
textValue (TextCodec codec) bs = Right $! decodeCodec codec bs

-- | A date-and-time type's value, given to the function as the day and the
-- picoseconds since midnight.
dayTimeValue :: (Day -> Int64 -> a) -> TypeInfo -> ValueReader a
dayTimeValue k ti = case ti of
  TIDateTime4 -> readDateTime4With k
  TIDateTime8 -> readDateTime8With k
  TIDateTimeN _ -> \bs -> case B.length bs of
    4 -> readDateTime4With k bs
    8 -> readDateTime8With k bs
    n -> Left $ "invalid datetime length " ++ show n
  TIDateTime2N s -> readDateTime2With k s
  TIDateN -> readDateWith (`k` 0)
  _ -> \_ -> Left "not a datetime type"
{-# INLINE dayTimeValue #-}

-- | 'dayTimeValue' as a 'LocalTime'.
localTimeValue :: TypeInfo -> ValueReader LocalTime
localTimeValue ti = dayTimeValue localTimeOf ti
{-# INLINE localTimeValue #-}

-- | The date and time types without an offset, @date@ included.
isLocalTimeType :: TypeInfo -> Bool
isLocalTimeType = hasDataType $ \case
  TyDateTime -> True
  TySmallDateTime -> True
  TyDateTime2 -> True
  TyDate -> True
  _ -> False

-- | @datetimeoffset@.
isDateTimeOffsetType :: TypeInfo -> Bool
isDateTimeOffsetType = hasDataType (== TyDateTimeOffset)

-- | The 'SqlValue' reader of a column's type, which 'selectSqlValueReader'
-- chooses once per column.
data SelectedReader = SelectedReader !(ValueReader SqlValue)
-- Data, not a function, on purpose.  A function that returns a function after
-- a @case@ can be eta-expanded by GHC, and the type switch with its guards
-- would then run for every cell.  Returning a constructor makes the selection
-- finish first, so it runs once per column.

-- | The reader of a column's values as 'SqlValue', by the column's type; for
-- a type it can't decode, a reader that fails on every value.
selectSqlValueReader :: TdsContext -> TypeInfo -> SelectedReader
selectSqlValueReader ctx ti = case ti of
  TINull -> SelectedReader (\_ -> Right SqlNull)
  TIBit -> SelectedReader bool
  TIBitN -> SelectedReader bool
  TIInt1 -> SelectedReader (fixed 1 "tinyint" (\bs -> SqlWord8 (word8At bs 0)))
  TIInt2 -> SelectedReader (fixed 2 "smallint" (\bs -> SqlInt16 (int16LeAt bs 0)))
  TIInt4 -> SelectedReader (fixed 4 "int" (\bs -> SqlInt32 (int32LeAt bs 0)))
  TIInt8 -> SelectedReader (fixed 8 "bigint" (\bs -> SqlInt64 (int64LeAt bs 0)))
  TIIntN _ -> SelectedReader $ \bs -> case B.length bs of
    1 -> Right (SqlWord8 (word8At bs 0))
    2 -> Right (SqlInt16 (int16LeAt bs 0))
    4 -> Right (SqlInt32 (int32LeAt bs 0))
    8 -> Right (SqlInt64 (int64LeAt bs 0))
    n -> Left $ "invalid integer length " ++ show n
  TIFlt4 -> SelectedReader (fixed 4 "real" (\bs -> SqlFloat (float4At bs)))
  TIFlt8 -> SelectedReader (fixed 8 "float" (\bs -> SqlDouble (float8At bs)))
  TIFltN _ -> SelectedReader $ \bs -> case B.length bs of
    4 -> Right (SqlFloat (float4At bs))
    8 -> Right (SqlDouble (float8At bs))
    n -> Left $ "invalid float length " ++ show n
  _ | isMoneyType ti -> SelectedReader (\bs -> SqlMoney <$> readMoney bs)
  _ | isDecimalType ti -> SelectedReader (\bs -> SqlDecimal <$> decimalValue ti bs)
  TIGuid -> SelectedReader (\bs -> SqlGuid <$> readGuid bs)
  TIDateN -> SelectedReader (\bs -> SqlDate <$> readDate bs)
  TITimeN s -> SelectedReader (\bs -> SqlTime <$> readTime s bs)
  TIDateTimeOffsetN s -> SelectedReader (\bs -> SqlDateTimeOffset <$> readDateTimeOffset s bs)
  _ | isLocalTimeType ti -> SelectedReader (\bs -> SqlDateTime <$> localTimeValue ti bs)
  TIXml _ -> text SqlXml
  _ | isUnicodeType ti -> SelectedReader (\bs -> Right (SqlText (Utf16.decodeUtf16LE bs)))
  _ | Just c <- ansiCollation ti -> case collationCodec c of
        Right codec -> SelectedReader (\bs -> Right (SqlText (decodeCodec codec bs)))
        Left e -> SelectedReader (\_ -> Left e)
  _ | isTextual ti -> text SqlText
  _ | isBinaryType ti -> SelectedReader (\bs -> Right (SqlBinary (B.copy bs)))
  TISqlVariant _ -> SelectedReader (readSqlVariant ctx)
  _ -> SelectedReader (\_ -> Left $ "unsupported type " ++ show ti)
  where
    bool bs = SqlBool <$> bitValue bs
    fixed :: Int -> String -> (B.ByteString -> SqlValue) -> ValueReader SqlValue
    fixed n name f bs
      | B.length bs == n = Right (f bs)
      | otherwise = Left $ "invalid " ++ name ++ " length " ++ show (B.length bs)
    text mk = case columnTextDecoder ti of
      Left e -> SelectedReader (\_ -> Left e)
      Right d -> SelectedReader (\bs -> mk <$> d bs)

-- | MS-TDS 2.2.5.5.4 sql_variant: base type, property bytes, then the
-- value using the rest of the buffer.  The number of property bytes is
-- fixed by the base type.
readSqlVariant :: TdsContext -> ValueReader SqlValue
readSqlVariant ctx bs
  | B.length bs < 2 = Left $ "sql_variant: " ++ show (B.length bs) ++ " bytes, no base type and property count"
  | otherwise = case baseType of
      0x24 -> fixed TIGuid
      0x32 -> fixed TIBit
      0x30 -> fixed TIInt1
      0x34 -> fixed TIInt2
      0x38 -> fixed TIInt4
      0x7F -> fixed TIInt8
      0x3D -> fixed TIDateTime8
      0x3A -> fixed TIDateTime4
      0x3B -> fixed TIFlt4
      0x3E -> fixed TIFlt8
      0x3C -> fixed TIMoney8
      0x7A -> fixed TIMoney4
      0x28 -> fixed TIDateN
      0x29 -> withProps 1 $ \props -> TITimeN (word8At props 0)
      0x2A -> withProps 1 $ \props -> TIDateTime2N (word8At props 0)
      0x2B -> withProps 1 $ \props -> TIDateTimeOffsetN (word8At props 0)
      0x6A -> withProps 2 $ \props -> TIDecimalN (word8At props 0) (word8At props 1)
      0x6C -> withProps 2 $ \props -> TINumericN (word8At props 0) (word8At props 1)
      0xAF -> withProps 7 $ \props -> TIBigChar (word16LeAt props 5) (collationAt props 0)
      0xA7 -> withProps 7 $ \props -> TIBigVarChar (word16LeAt props 5) (collationAt props 0)
      0xEF -> withProps 7 $ \props -> TINChar (word16LeAt props 5) (collationAt props 0)
      0xE7 -> withProps 7 $ \props -> TINVarChar (word16LeAt props 5) (collationAt props 0)
      0xAD -> withProps 2 $ \props -> TIBigBinary (word16LeAt props 0)
      0xA5 -> withProps 2 $ \props -> TIBigVarBinary (word16LeAt props 0)
      t -> Left $ "sql_variant: unsupported base type " ++ show t
  where
    baseType = word8At bs 0
    propBytes = fromIntegral (word8At bs 1) :: Int
    fixed = withProps 0 . const
    -- Parse the base type's properties from their own bounded value.
    withProps :: Int -> (B.ByteString -> TypeInfo) -> Either String SqlValue
    withProps n typeFrom
      | propBytes /= n = Left $ "sql_variant: " ++ show propBytes ++ " property bytes for base type "
          ++ show baseType ++ ", expected " ++ show n
      | B.length bs < 2 + n = Left $ "sql_variant: " ++ show (B.length bs) ++ " bytes, at least " ++ show (2 + n) ++ " expected"
      | Just e <- typeInfoProblem ti = Left ("sql_variant: " ++ e)
      -- Selected per value: each sql_variant value names its own type.
      | otherwise = case selectSqlValueReader ctx ti of
          SelectedReader reader -> reader (B.drop (2 + n) bs)
      where
        ti = typeFrom (B.take n (B.drop 2 bs))

-- | Whether a wire type's SQL data type satisfies the predicate.
hasDataType :: (SqlDataType -> Bool) -> TypeInfo -> Bool
hasDataType p = \ti -> maybe False p (typeInfoDataType ti)
{-# INLINE hasDataType #-}

-- | The message for a column of a type the decoder of this name doesn't accept.
rejectAs :: String -> TypeInfo -> String
rejectAs name ti = case ti of
  TIUdt _ -> unsupportedUdt ti ("as " ++ name)
  _ -> "SQL type " ++ T.unpack (typeInfoSqlName ti) ++ " cannot be decoded as " ++ name

-- | The message for a CLR user-defined type, which hmssql doesn't decode.
unsupportedUdt :: TypeInfo -> String -> String
unsupportedUdt ti how =
  "SQL type " ++ T.unpack (typeInfoSqlName ti) ++ " is a CLR user-defined type, which hmssql does not decode "
    ++ how ++ "; convert it in the query (e.g. CAST(col AS varbinary(max)) or col.ToString()),"
    ++ " or read its serialized bytes as RawValue"
