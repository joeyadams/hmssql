-- | The Haskell types that stand for SQL Server's, and which SQL types each
-- decodes from and is sent as.  The value types of hmssql's own
-- ('Money', 'DateTimeOffset', 'RawValue', 'RawParam'; "Hmssql.SqlValue" for a
-- value of any type) are
-- defined or re-exported here; the rest are the usual @base@, @text@,
-- @bytestring@, @time@, @Decimal@ and @uuid-types@ types.
--
-- = Decoding: 'Hmssql.Decoding.FromSqlField'
--
-- A column's SQL type is checked against the Haskell type when the result
-- set's columns arrive, before any row is decoded.  @Maybe a@ decodes
-- NULL as 'Nothing' for any @a@ below; a NULL in a column decoded as a
-- bare type is a 'Hmssql.Errors.DecodeError'.
--
-- +------------------------------------+------------------------------------------------------------------------+
-- | Haskell type                       | SQL types accepted                                                     |
-- +====================================+========================================================================+
-- | 'Bool'                             | @bit@                                                                  |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Int', 'Int8', 'Int16', 'Int32',   | @tinyint@, @smallint@, @int@, @bigint@, @bit@; a value outside the     |
-- | 'Int64', 'Word8'                   | Haskell type's range is an error                                       |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Integer'                          | the integer types, and @decimal@ or @numeric@ with scale 0             |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Double'                           | @float@, @real@                                                        |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Float'                            | @real@ (@float(24)@); @float(53)@ is refused rather than rounded       |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Decimal'                          | @decimal@, @numeric@, @money@, @smallmoney@, the integer types         |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Money'                            | @money@, @smallmoney@                                                  |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'UUID'                             | @uniqueidentifier@                                                     |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Text', 'String', lazy             | @nchar@, @nvarchar@, @ntext@, @xml@, and @char@, @varchar@, @text@     |
-- | 'Data.Text.Lazy.Text'              | in UTF-8 or a supported single-byte code page                          |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'ByteString', lazy                 | @binary@, @varbinary@, @image@, and the undecoded bytes of @char@,     |
-- | 'Data.ByteString.Lazy.ByteString'  | @varchar@, @text@                                                      |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'LocalTime'                        | @datetime@, @smalldatetime@, @datetime2@, @date@ (at midnight)         |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'UTCTime'                          | the same, taken to be UTC, and @datetimeoffset@, converted to UTC      |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'DateTimeOffset', 'ZonedTime'      | @datetimeoffset@                                                       |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Day'                              | @date@                                                                 |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'TimeOfDay'                        | @time@                                                                 |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Hmssql.SqlValue.SqlValue'         | any type but a CLR user-defined type; a @sql_variant@ as its base      |
-- |                                    | type                                                                   |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'RawValue'                         | any type, as the bytes on the wire                                     |
-- +------------------------------------+------------------------------------------------------------------------+
--
-- @rowversion@ is @binary(8)@ on the wire, @json@ is @nvarchar(max)@ and
-- @vector@ is @varchar@: each decodes as what it is sent as.  A CLR
-- user-defined type (@hierarchyid@, @geometry@, @geography@) decodes only
-- as 'RawValue'; @CAST@ it or call @.ToString()@ in the query instead.
--
-- = Encoding: 'Hmssql.Encoding.ToSqlField'
--
-- A parameter's wire type is fixed by its Haskell type.  The server
-- converts it to the column's type where it can, but sending @nvarchar@
-- against a @varchar@ index, or @datetime2@ against a @datetime@ column,
-- can turn a seek into a scan; 'RawParam' chooses the wire type yourself.
-- @Nothing@ is a NULL of the type the bare type would be sent as.
--
-- +------------------------------------+------------------------------------------------------------------------+
-- | Haskell type                       | Sent as                                                                |
-- +====================================+========================================================================+
-- | 'Bool'                             | @bit@                                                                  |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Word8'                            | @tinyint@                                                              |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Int8', 'Int16'                    | @smallint@                                                             |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Int32'                            | @int@                                                                  |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Int', 'Int64'                     | @bigint@                                                               |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Integer'                          | @bigint@, or @decimal(38,0)@ beyond its range; 39 digits or more is    |
-- |                                    | an 'Hmssql.Errors.EncodeError'                                         |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Double'                           | @float@                                                                |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Float'                            | @real@                                                                 |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Decimal'                          | @decimal(p,s)@ with the value's own scale and just enough precision    |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Money'                            | @money@                                                                |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'UUID'                             | @uniqueidentifier@                                                     |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Text', 'String', lazy             | @nvarchar(4000)@, or @nvarchar(max)@ beyond 4000 UTF-16 code units     |
-- | 'Data.Text.Lazy.Text'              |                                                                        |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'ByteString', lazy                 | @varbinary(8000)@, or @varbinary(max)@ beyond 8000 bytes               |
-- | 'Data.ByteString.Lazy.ByteString'  |                                                                        |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'LocalTime'                        | @datetime2(7)@                                                         |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'UTCTime'                          | @datetime2(7)@ holding the UTC clock time                              |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'DateTimeOffset', 'ZonedTime'      | @datetimeoffset(7)@; the offset must be within ±14:00                  |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Day'                              | @date@                                                                 |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'TimeOfDay'                        | @time(7)@                                                              |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'Hmssql.SqlValue.SqlValue'         | the type its constructor names; 'Hmssql.SqlValue.SqlNull' as an        |
-- |                                    | @nvarchar(max)@ NULL                                                   |
-- +------------------------------------+------------------------------------------------------------------------+
-- | 'RawParam'                         | the 'TypeInfo' given, with the bytes given                             |
-- +------------------------------------+------------------------------------------------------------------------+
--
-- Date and time values are rounded to 100 ns as the server rounds them;
-- a value the server would reject (a year outside 1 through 9999, an
-- offset beyond ±14:00) is an 'Hmssql.Errors.EncodeError' before anything
-- is sent.  A NULL of 'Text', 'Hmssql.Encoding.SqlParam' or 'RawParam' is @nvarchar(max)@,
-- which the server converts to most types but not to @binary@ or
-- @sql_variant@: send a typed NULL (@Nothing :: Maybe Int32@) there.
--
-- == When a string's declared type matters
--
-- A string or binary parameter's declared type depends on the value's length,
-- as the table shows, and on whether it is NULL.  The declared type doesn't limit
-- what can be sent, and it doesn't change the result of storing the value in a
-- column or comparing it with one.  It does matter in three cases:
--
-- * __An expression typed by the parameter.__  @SELECT \@p1@ returns the declared
--   type, and concatenating bounded types stops at their limit without an error.
--   With two values of 3000 characters, @\@p1 + \@p2@ returns 4000 characters and
--   @CAST(\@p1 AS nvarchar(max)) + \@p2@ returns 6000.  Binary values stop at 8000
--   bytes in the same way.  Cast a parameter whose result can outgrow the limit.
-- * __A @sql_variant@ target.__  The server won't convert a @(max)@ type to
--   @sql_variant@, so a longer value or an untyped NULL fails with error 206.
-- * __Plan caching.__  The server caches a plan per declaration, so one statement
--   can have one plan for short values and another for long values and NULLs.
--   Values within one declaration share a plan whatever their lengths.
module Hmssql.Types
  ( -- * hmssql's own value types
    Money (..)
  , DateTimeOffset (..)
  , dateTimeOffsetToZonedTime
  , zonedTimeToDateTimeOffset

    -- * The bytes as they are
  , RawValue (..)
  , RawParam (..)

    -- * The wire's view of a type
  , TypeInfo (..)
  , Collation (..)
  , ColumnInfo (..)
  , columnIsNullable
  , columnIsLong
  , ServerMessage (..)
  ) where

import Hmssql.Decoding (RawValue (..))
import Hmssql.Encoding (RawParam (..))
import Hmssql.Tds.Primitives (Collation (..), DateTimeOffset (..), Money (..), dateTimeOffsetToZonedTime, zonedTimeToDateTimeOffset)
import Hmssql.Tds.Token (ColumnInfo (..), ServerMessage (..), columnIsLong, columnIsNullable)
import Hmssql.Tds.TypeInfo (TypeInfo (..))
