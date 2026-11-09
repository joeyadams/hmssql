{-# LANGUAGE MagicHash #-}
-- | A value of any SQL Server type, for code that handles columns and
-- parameters whose types are only known at runtime: serving any table,
-- copying rows between tables, a REPL.
--
-- Decoding: 'SqlValue' is a 'Hmssql.Decoding.FromSqlField' that accepts
-- any column ('Hmssql.Decoding.sqlValueDecoder'), and 'SqlRow' a whole row
-- with its columns ('Hmssql.Decoding.sqlRowDecoder',
-- 'Hmssql.Decoding.sqlRowDecoderFor'); 'Hmssql.Query.queryMulti' and
-- 'Hmssql.Query.callProcedure' return every result set as 'SqlRow's.  A
-- @sql_variant@ decodes as its base type.
--
-- Encoding: 'SqlValue' is a 'Hmssql.Encoding.ToSqlField' sent as the type
-- its constructor names, so @SELECT \@p1@ gives the same value back;
-- 'SqlNull' is an @nvarchar(max)@ NULL, which the server converts to most
-- types but not to @binary@ or @sql_variant@.
module Hmssql.SqlValue
  ( SqlValue (..)
  , SqlRow (..)
  ) where

import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Int (Int16, Int32, Int64)
import Data.Text (Text)
import Data.Time (Day, LocalTime, TimeOfDay)
import Data.UUID.Types (UUID)
import Data.Word (Word8)

import Hmssql.Internal.Derived
import Hmssql.Tds.Primitives (DateTimeOffset, Money)
import Hmssql.Tds.Token (ColumnInfo)

-- | One constructor per family of SQL Server types.
data SqlValue
  = SqlNull
  | SqlBool !Bool
    -- ^ @bit@
  | SqlWord8 !Word8
    -- ^ @tinyint@: an unsigned value from 0 through 255
  | SqlInt16 !Int16
    -- ^ @smallint@
  | SqlInt32 !Int32
    -- ^ @int@
  | SqlInt64 !Int64
    -- ^ @bigint@
  | SqlFloat !Float
    -- ^ @real@
  | SqlDouble !Double
    -- ^ @float@
  | SqlDecimal !Decimal
    -- ^ @decimal@, @numeric@
  | SqlMoney !Money
    -- ^ @money@, @smallmoney@
  | SqlGuid !UUID
    -- ^ @uniqueidentifier@
  | SqlDateTime !LocalTime
    -- ^ @datetime@, @smalldatetime@, @datetime2@
  | SqlDate !Day
    -- ^ @date@
  | SqlTime !TimeOfDay
    -- ^ @time@
  | SqlDateTimeOffset !DateTimeOffset
    -- ^ @datetimeoffset@
  | SqlText !Text
    -- ^ The character types: @char@, @varchar@, @text@ (decoded by the
    -- collation's code page), @nchar@, @nvarchar@, @ntext@, and @json@ and
    -- @vector@, which arrive as character types
  | SqlBinary !B.ByteString
    -- ^ @binary@, @varbinary@, @image@, @rowversion@
  | SqlXml !Text
    -- ^ @xml@

instance Show SqlValue where
  showsPrec p = \case
    SqlNull -> showString "SqlNull"
    SqlBool a -> showCon1 p "SqlBool"# a
    SqlWord8 a -> showCon1 p "SqlWord8"# a
    SqlInt16 a -> showCon1 p "SqlInt16"# a
    SqlInt32 a -> showCon1 p "SqlInt32"# a
    SqlInt64 a -> showCon1 p "SqlInt64"# a
    SqlFloat a -> showCon1 p "SqlFloat"# a
    SqlDouble a -> showCon1 p "SqlDouble"# a
    SqlDecimal a -> showCon1 p "SqlDecimal"# a
    SqlMoney a -> showCon1 p "SqlMoney"# a
    SqlGuid a -> showCon1 p "SqlGuid"# a
    SqlDateTime a -> showCon1 p "SqlDateTime"# a
    SqlDate a -> showCon1 p "SqlDate"# a
    SqlTime a -> showCon1 p "SqlTime"# a
    SqlDateTimeOffset a -> showCon1 p "SqlDateTimeOffset"# a
    SqlText a -> showCon1 p "SqlText"# a
    SqlBinary a -> showCon1 p "SqlBinary"# a
    SqlXml a -> showCon1 p "SqlXml"# a
  {-# OPAQUE showsPrec #-}

instance Eq SqlValue where
  x == y = case (x, y) of
    (SqlNull, SqlNull) -> True
    (SqlBool a, SqlBool a') -> a == a'
    (SqlWord8 a, SqlWord8 a') -> a == a'
    (SqlInt16 a, SqlInt16 a') -> a == a'
    (SqlInt32 a, SqlInt32 a') -> a == a'
    (SqlInt64 a, SqlInt64 a') -> a == a'
    (SqlFloat a, SqlFloat a') -> a == a'
    (SqlDouble a, SqlDouble a') -> a == a'
    (SqlDecimal a, SqlDecimal a') -> eq a a'
    (SqlMoney a, SqlMoney a') -> eq a a'
    (SqlGuid a, SqlGuid a') -> eq a a'
    (SqlDateTime a, SqlDateTime a') -> eq a a'
    (SqlDate a, SqlDate a') -> eq a a'
    (SqlTime a, SqlTime a') -> eq a a'
    (SqlDateTimeOffset a, SqlDateTimeOffset a') -> eq a a'
    (SqlText a, SqlText a') -> eq a a'
    (SqlBinary a, SqlBinary a') -> eq a a'
    (SqlXml a, SqlXml a') -> eq a a'
    _ -> False
  {-# OPAQUE (==) #-}

-- | A row of 'SqlValue's with the columns they came from.
data SqlRow = SqlRow
  { sqlRowColumns :: ![ColumnInfo]
    -- ^ The result set's columns, one per value.
  , sqlRowValues :: ![SqlValue]
  }

instance Show SqlRow where
  showsPrec p (SqlRow a b) =
    showRecord p "SqlRow"# ["sqlRowColumns"# := a, "sqlRowValues"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq SqlRow where
  SqlRow a b == SqlRow a' b' = eq a a' && eq b b'
  {-# OPAQUE (==) #-}
