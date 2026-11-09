{-# LANGUAGE MagicHash #-}
-- | SQL Server's data types by name, as T-SQL and the catalog spell them:
-- @nvarchar(50)@, @decimal(10,2)@, @vector(3)@.  This is the vocabulary
-- for code that handles SQL generically, such as checking that a database
-- has the columns an application expects, generating record types from
-- tables, or serializing whatever a table holds; "Hmssql.Catalog" reads
-- these types from a database.
--
-- 'SqlDataType' is the closed list of the types a server ships with, so a
-- @case@ over it can be total, and a type this library doesn't know yet
-- makes a lookup return 'Nothing' rather than a catch-all constructor.
-- 'SqlType' adds a type's arguments: a length, a precision and scale, a
-- scale, a vector's dimensions or an @xml@ schema collection.
--
-- The wire has its own view of types, 'TypeInfo': the encodings values are
-- carried in, which name lengths in bytes and don't tell @json@ (sent as
-- @nvarchar(max)@), @vector@ (sent as @varchar@) or @rowversion@ (sent as
-- @binary(8)@) from what they are sent as.  'typeInfoSqlType' and
-- 'sqlTypeTypeInfo' go between the two views. 'columnSqlType' also uses
-- the column's user-type tag to recognize @rowversion@.
module Hmssql.SqlType
  ( -- * Data types
    SqlDataType (..)
  , dataTypeName
  , dataTypeFromName
  , TypeCategory (..)
  , dataTypeCategory

    -- * Types with their arguments
  , SqlType (..)
  , TypeArgs (..)
  , Length (..)
  , sqlTypeName
  , sqlTypeProblem

    -- * The wire's types
  , typeInfoDataType
  , typeInfoSqlType
  , sqlTypeTypeInfo
  , columnSqlType
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import GHC.Exts (Addr#, unpackCString#)

import Hmssql.Internal.Derived
import Hmssql.Internal.SqlDataType (SqlDataType (..), typeInfoDataType)
import Hmssql.Tds.Primitives (Collation (..), Precision, Scale)
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo

-- | The type's name in T-SQL and in @sys.types@, except that
-- 'TyRowVersion' is @rowversion@ (the catalog says @timestamp@, the older
-- name, which 'dataTypeFromName' accepts).
dataTypeName :: SqlDataType -> Text
dataTypeName = \case
  TyBit -> literalName "bit"#
  TyTinyInt -> literalName "tinyint"#
  TySmallInt -> literalName "smallint"#
  TyInt -> literalName "int"#
  TyBigInt -> literalName "bigint"#
  TyDecimal -> literalName "decimal"#
  TyNumeric -> literalName "numeric"#
  TyMoney -> literalName "money"#
  TySmallMoney -> literalName "smallmoney"#
  TyFloat -> literalName "float"#
  TyReal -> literalName "real"#
  TyDate -> literalName "date"#
  TyTime -> literalName "time"#
  TyDateTime -> literalName "datetime"#
  TySmallDateTime -> literalName "smalldatetime"#
  TyDateTime2 -> literalName "datetime2"#
  TyDateTimeOffset -> literalName "datetimeoffset"#
  TyChar -> literalName "char"#
  TyVarChar -> literalName "varchar"#
  TyText -> literalName "text"#
  TyNChar -> literalName "nchar"#
  TyNVarChar -> literalName "nvarchar"#
  TyNText -> literalName "ntext"#
  TyBinary -> literalName "binary"#
  TyVarBinary -> literalName "varbinary"#
  TyImage -> literalName "image"#
  TyUniqueIdentifier -> literalName "uniqueidentifier"#
  TyRowVersion -> literalName "rowversion"#
  TyXml -> literalName "xml"#
  TySqlVariant -> literalName "sql_variant"#
  TyJson -> literalName "json"#
  TyVector -> literalName "vector"#
  TyHierarchyId -> literalName "hierarchyid"#
  TyGeometry -> literalName "geometry"#
  TyGeography -> literalName "geography"#

-- The conversion of a name from its static bytes to 'Text' is compiled once here,
-- rather than inlined into each of the 35 alternatives as it was for 'Text'
-- literals: 4,568 bytes less of code (GHC 9.12.4, 2026-11-04).  Each alternative
-- is still a CAF, so a name is converted once and never allocated again.  The
-- names are ASCII, which is all 'unpackCString#' reads.
literalName :: Addr# -> Text
literalName addr = T.pack (unpackCString# addr)
{-# OPAQUE literalName #-}

-- | The type of a name as @sys.types@ or T-SQL spells it, ignoring case
-- and surrounding space: the inverse of 'dataTypeName', plus the aliases
-- @timestamp@ ('TyRowVersion') and @sysname@ ('TyNVarChar').  'Nothing'
-- for a user-defined type, and for a type newer than this library.
dataTypeFromName :: Text -> Maybe SqlDataType
dataTypeFromName name = Map.lookup (T.toLower (T.strip name)) namedTypes

namedTypes :: Map.Map Text SqlDataType
namedTypes = Map.fromList $
  ("timestamp", TyRowVersion) : ("sysname", TyNVarChar) :
  [(dataTypeName t, t) | t <- [minBound .. maxBound]]
{-# NOINLINE namedTypes #-}

-- | The groups of SQL Server's data type documentation.
data TypeCategory
  = ExactNumeric
  | ApproximateNumeric
  | DateAndTime
  | CharacterString          -- ^ single-byte: @char@, @varchar@, @text@
  | UnicodeCharacterString   -- ^ @nchar@, @nvarchar@, @ntext@
  | BinaryString             -- ^ @binary@, @varbinary@, @image@
  | OtherDataType            -- ^ @uniqueidentifier@, @rowversion@, @xml@, @sql_variant@, @json@, @vector@, the CLR types
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | The group of SQL Server's documentation the type is listed under.
dataTypeCategory :: SqlDataType -> TypeCategory
dataTypeCategory = \case
  TyBit -> ExactNumeric
  TyTinyInt -> ExactNumeric
  TySmallInt -> ExactNumeric
  TyInt -> ExactNumeric
  TyBigInt -> ExactNumeric
  TyDecimal -> ExactNumeric
  TyNumeric -> ExactNumeric
  TyMoney -> ExactNumeric
  TySmallMoney -> ExactNumeric
  TyFloat -> ApproximateNumeric
  TyReal -> ApproximateNumeric
  TyDate -> DateAndTime
  TyTime -> DateAndTime
  TyDateTime -> DateAndTime
  TySmallDateTime -> DateAndTime
  TyDateTime2 -> DateAndTime
  TyDateTimeOffset -> DateAndTime
  TyChar -> CharacterString
  TyVarChar -> CharacterString
  TyText -> CharacterString
  TyNChar -> UnicodeCharacterString
  TyNVarChar -> UnicodeCharacterString
  TyNText -> UnicodeCharacterString
  TyBinary -> BinaryString
  TyVarBinary -> BinaryString
  TyImage -> BinaryString
  TyUniqueIdentifier -> OtherDataType
  TyRowVersion -> OtherDataType
  TyXml -> OtherDataType
  TySqlVariant -> OtherDataType
  TyJson -> OtherDataType
  TyVector -> OtherDataType
  TyHierarchyId -> OtherDataType
  TyGeometry -> OtherDataType
  TyGeography -> OtherDataType

------------------------------------------------------------------------------
-- Types with their arguments

-- | The declared length of a character or binary type: in characters
-- (@nvarchar(50)@ is @Length 50@, whatever its storage takes), or in bytes
-- for the binary types.
data Length
  = Length !Int
  | Max       -- ^ @varchar(max)@, @nvarchar(max)@, @varbinary(max)@
  deriving stock (Ord)

instance Show Length where
  showsPrec p = \case
    Length a -> showCon1 p "Length"# a
    Max -> showString "Max"
  {-# OPAQUE showsPrec #-}

instance Eq Length where
  x == y = case (x, y) of
    (Length a, Length a') -> a == a'
    (Max, Max) -> True
    _ -> False
  {-# OPAQUE (==) #-}

-- | A type's arguments.  Which a type takes is fixed ('sqlTypeProblem'):
-- a length for the character and binary types, a precision and scale for
-- @decimal@ and @numeric@, a scale for @time@, @datetime2@ and
-- @datetimeoffset@, dimensions for @vector@, nothing or a schema
-- collection for @xml@, and nothing for the rest.
data TypeArgs
  = NoArgs
  | LengthArg !Length
  | PrecisionScaleArg !Precision !Scale
  | ScaleArg !Scale
  | DimensionsArg !Int
  | XmlSchemaArg !Text !Text
    -- ^ the schema and the name of the collection: @xml([dbo].[Person])@
  deriving stock (Ord)

instance Show TypeArgs where
  showsPrec p = \case
    NoArgs -> showString "NoArgs"
    LengthArg a -> showCon1 p "LengthArg"# a
    PrecisionScaleArg a b -> showCon p "PrecisionScaleArg"# [Arg a, Arg b]
    ScaleArg a -> showCon1 p "ScaleArg"# a
    DimensionsArg a -> showCon1 p "DimensionsArg"# a
    XmlSchemaArg a b -> showCon p "XmlSchemaArg"# [Arg a, Arg b]
  {-# OPAQUE showsPrec #-}

instance Eq TypeArgs where
  x == y = case (x, y) of
    (NoArgs, NoArgs) -> True
    (LengthArg a, LengthArg a') -> eq a a'
    (PrecisionScaleArg a b, PrecisionScaleArg a' b') -> a == a' && b == b'
    (ScaleArg a, ScaleArg a') -> a == a'
    (DimensionsArg a, DimensionsArg a') -> a == a'
    (XmlSchemaArg a b, XmlSchemaArg a' b') -> eq a a' && eq b b'
    _ -> False
  {-# OPAQUE (==) #-}

-- | A data type with its arguments: what a column is declared as.
data SqlType = SqlType
  { sqlDataType :: !SqlDataType
  , sqlTypeArgs :: !TypeArgs
  }
  deriving stock (Ord)

instance Show SqlType where
  showsPrec p (SqlType a b) =
    showRecord p "SqlType"# ["sqlDataType"# := a, "sqlTypeArgs"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq SqlType where
  SqlType a b == SqlType a' b' = eq a a' && eq b b'
  {-# OPAQUE (==) #-}

-- | The type as T-SQL declares it: @nvarchar(50)@, @varbinary(max)@,
-- @decimal(10,2)@, @time(4)@, @vector(3)@, @xml([dbo].[Person])@, @int@.
-- Rendered as it is; check 'sqlTypeProblem' first for a type built by
-- hand.
sqlTypeName :: SqlType -> Text
sqlTypeName (SqlType t args) = case args of
  NoArgs -> name
  LengthArg (Length n) -> name <> "(" <> tshow n <> ")"
  LengthArg Max -> name <> "(max)"
  PrecisionScaleArg p s -> name <> "(" <> tshow p <> "," <> tshow s <> ")"
  ScaleArg s -> name <> "(" <> tshow s <> ")"
  DimensionsArg n -> name <> "(" <> tshow n <> ")"
  XmlSchemaArg schema collection -> name <> "(" <> quote schema <> "." <> quote collection <> ")"
  where
    name = dataTypeName t
    quote n = "[" <> T.replace "]" "]]" n <> "]"

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Why this isn't a type SQL Server has, if it isn't: an argument the type
-- doesn't take, a missing one (the length of an @nvarchar@, the precision
-- and scale of a @decimal@, ...; nothing is defaulted), or one out of
-- range: a length outside 1 through 8000 (4000 for @nchar@ and
-- @nvarchar@), @max@ on a fixed-length type, a precision outside 1
-- through 38 or a scale above it, a scale above 7, dimensions below 1.
sqlTypeProblem :: SqlType -> Maybe String
sqlTypeProblem (SqlType t args) = case (t, args) of
  (TyChar, LengthArg len) -> fixedLength 8000 len
  (TyVarChar, LengthArg len) -> varLength 8000 len
  (TyNChar, LengthArg len) -> fixedLength 4000 len
  (TyNVarChar, LengthArg len) -> varLength 4000 len
  (TyBinary, LengthArg len) -> fixedLength 8000 len
  (TyVarBinary, LengthArg len) -> varLength 8000 len
  (TyDecimal, PrecisionScaleArg p s) -> decimal p s
  (TyNumeric, PrecisionScaleArg p s) -> decimal p s
  (TyTime, ScaleArg s) -> scale s
  (TyDateTime2, ScaleArg s) -> scale s
  (TyDateTimeOffset, ScaleArg s) -> scale s
  (TyVector, DimensionsArg n)
    | n < 1 -> Just (name ++ " needs at least one dimension")
    | otherwise -> Nothing
  (TyXml, NoArgs) -> Nothing
  (TyXml, XmlSchemaArg _ _) -> Nothing
  (_, NoArgs)
    | takesArgs t -> Just (name ++ " needs " ++ argsOf t)
    | otherwise -> Nothing
  _ -> Just (name ++ " takes " ++ (if takesArgs t then argsOf t else "no arguments"))
  where
    name = T.unpack (dataTypeName t)
    takesArgs = \case
      TyChar -> True
      TyVarChar -> True
      TyNChar -> True
      TyNVarChar -> True
      TyBinary -> True
      TyVarBinary -> True
      TyDecimal -> True
      TyNumeric -> True
      TyTime -> True
      TyDateTime2 -> True
      TyDateTimeOffset -> True
      TyVector -> True
      _ -> False
    argsOf = \case
      TyDecimal -> "a precision and scale"
      TyNumeric -> "a precision and scale"
      TyTime -> "a scale"
      TyDateTime2 -> "a scale"
      TyDateTimeOffset -> "a scale"
      TyVector -> "dimensions"
      _ -> "a length"
    fixedLength limit = \case
      Max -> Just (name ++ " has no (max) form")
      Length n -> inRange limit n
    varLength limit = \case
      Max -> Nothing
      Length n -> inRange limit n
    inRange limit n
      | n < 1 || n > limit = Just (name ++ " length " ++ show n ++ " is outside 1 through " ++ show limit)
      | otherwise = Nothing
    decimal p s
      | p < 1 || p > 38 = Just (name ++ " precision " ++ show p ++ " is outside 1 through 38")
      | s > p = Just (name ++ " scale " ++ show s ++ " is above its precision " ++ show p)
      | otherwise = Nothing
    scale s
      | s > 7 = Just (name ++ " scale " ++ show s ++ " is above 7")
      | otherwise = Nothing

------------------------------------------------------------------------------
-- The wire's types

-- | The type with its arguments: 'typeInfoDataType' plus the length,
-- precision and scale or schema collection the wire carries.  This
-- allocates the result, so prefer 'typeInfoDataType' where the arguments
-- don't matter.
typeInfoSqlType :: TypeInfo -> Maybe SqlType
typeInfoSqlType ti = SqlType <$> typeInfoDataType ti <*> pure args
  where
    args = case ti of
      TIDecimalN p s -> PrecisionScaleArg p s
      TINumericN p s -> PrecisionScaleArg p s
      TITimeN s -> ScaleArg s
      TIDateTime2N s -> ScaleArg s
      TIDateTimeOffsetN s -> ScaleArg s
      TIBigChar len _ -> LengthArg (Length (fromIntegral len))
      TIBigVarChar len _ -> LengthArg (bytes len)
      TINChar len _ -> LengthArg (Length (fromIntegral len `div` 2))
      TINVarChar len _ -> LengthArg (chars len)
      TIBigBinary len -> LengthArg (Length (fromIntegral len))
      TIBigVarBinary len -> LengthArg (bytes len)
      TIXml (Just XmlSchema{..}) -> XmlSchemaArg xmlOwningSchema xmlSchemaCollection
      _ -> NoArgs
    bytes len
      | len == maxLength = Max
      | otherwise = Length (fromIntegral len)
    chars len
      | len == maxLength = Max
      | otherwise = Length (fromIntegral len `div` 2)

-- | The wire type to declare a parameter of this type with, as
-- @RawParam@'s: the nullable encodings, the server's default collation
-- for character types, a schema collection in the current database.
-- 'Nothing' for a type with a 'sqlTypeProblem', and for @json@, @vector@
-- and the CLR types, which a TDS 7.4 or 8.0 client can't send as such
-- (send @json@ as @nvarchar(max)@, a @vector@ as its JSON array text).
sqlTypeTypeInfo :: SqlType -> Maybe TypeInfo
sqlTypeTypeInfo st@(SqlType t args) = case sqlTypeProblem st of
  Just _ -> Nothing
  Nothing -> case (t, args) of
    (TyBit, _) -> Just TIBitN
    (TyTinyInt, _) -> Just (TIIntN 1)
    (TySmallInt, _) -> Just (TIIntN 2)
    (TyInt, _) -> Just (TIIntN 4)
    (TyBigInt, _) -> Just (TIIntN 8)
    (TyDecimal, PrecisionScaleArg p s) -> Just (TIDecimalN p s)
    (TyNumeric, PrecisionScaleArg p s) -> Just (TINumericN p s)
    (TyMoney, _) -> Just (TIMoneyN 8)
    (TySmallMoney, _) -> Just (TIMoneyN 4)
    (TyFloat, _) -> Just (TIFltN 8)
    (TyReal, _) -> Just (TIFltN 4)
    (TyDate, _) -> Just TIDateN
    (TyTime, ScaleArg s) -> Just (TITimeN s)
    (TyDateTime, _) -> Just (TIDateTimeN 8)
    (TySmallDateTime, _) -> Just (TIDateTimeN 4)
    (TyDateTime2, ScaleArg s) -> Just (TIDateTime2N s)
    (TyDateTimeOffset, ScaleArg s) -> Just (TIDateTimeOffsetN s)
    (TyChar, LengthArg (Length n)) -> Just (TIBigChar (fromIntegral n) defaultCollation)
    (TyVarChar, LengthArg len) -> Just (TIBigVarChar (bytes len) defaultCollation)
    (TyText, _) -> Just (TIText longest defaultCollation)
    (TyNChar, LengthArg (Length n)) -> Just (TINChar (fromIntegral (2 * n)) defaultCollation)
    (TyNVarChar, LengthArg len) -> Just (TINVarChar (chars len) defaultCollation)
    (TyNText, _) -> Just (TINText longest defaultCollation)
    (TyBinary, LengthArg (Length n)) -> Just (TIBigBinary (fromIntegral n))
    (TyVarBinary, LengthArg len) -> Just (TIBigVarBinary (bytes len))
    (TyImage, _) -> Just (TIImage longest)
    (TyUniqueIdentifier, _) -> Just TIGuid
    (TyRowVersion, _) -> Just (TIBigBinary 8)
    (TyXml, XmlSchemaArg schema collection) -> Just (TIXml (Just (XmlSchema "" schema collection)))
    (TyXml, _) -> Just (TIXml Nothing)
    (TySqlVariant, _) -> Just (TISqlVariant 8016)
    _ -> Nothing
  where
    -- The server's default collation, as "Hmssql.Encoding" declares
    -- character parameters.
    defaultCollation = Collation 0 0
    -- The longest a text, ntext or image value can be.
    longest = 0x7FFFFFFF
    bytes :: Length -> Word16
    bytes = \case
      Max -> maxLength
      Length n -> fromIntegral n
    chars = \case
      Max -> maxLength
      Length n -> fromIntegral (2 * n)

-- | The declared type of a result set's column, as far as its metadata
-- says. The user-type tag identifies @rowversion@; otherwise this is
-- 'typeInfoSqlType' of the column's storage type. An alias type's user
-- ID does not carry its name, so its underlying type is returned.
columnSqlType :: ColumnInfo -> Maybe SqlType
columnSqlType col
  | columnUserType col == 0x50 = Just (SqlType TyRowVersion NoArgs)
  | otherwise = typeInfoSqlType (columnType col)
