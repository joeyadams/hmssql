{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-type bulk-copy tests: for every SQL Server column type, load a
-- table with 'bulkInsert' and an identical one with 'executeMany', and
-- assert (a) the bulk load round-trips the values (allowing the documented
-- lossless transforms: @char@ padding, @decimal@ scale rounding, @vector@
-- and @json@ normalization) and (b) the two loads store byte-identical
-- data (value-for-value and by @DATALENGTH@).  See "Bulk.Harness".
--
-- Also: @rowversion@ is excluded from an insertable load and can't be sent;
-- CLR UDTs (@hierarchyid@/@geometry@/@geography@) are refused with an
-- 'EncodeError'.
module Bulk.TypesSpec (spec) where

import RecipeParameters
import Control.Monad (void)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int16, Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.BulkCopy
import TestDb

import Bulk.Harness

-- | A 'Decimal' with the given scale and mantissa (fixes the otherwise
-- ambiguous @DecimalRaw i@).
dec :: Word8 -> Integer -> Decimal
dec = Decimal

spec :: Spec
spec = around withTestDb $ do
  describe "exact numeric types" $ mapM_ typeCaseSpec exactNumericCases
  describe "approximate numeric types" $ mapM_ typeCaseSpec approxNumericCases
  describe "date and time types" $ mapM_ typeCaseSpec dateTimeCases
  describe "character types (single-byte)" $ mapM_ typeCaseSpec charCases
  describe "unicode character types" $ mapM_ typeCaseSpec ncharCases
  describe "binary types" $ mapM_ typeCaseSpec binaryCases
  describe "other types" $ mapM_ typeCaseSpec otherCases
  describe "SQL Server 2025 types" $ skipBeforeSql2025 "json and vector" $ mapM_ typeCaseSpec sql2025Cases
  describe "server-generated and unsupported columns" $ do
    it "excludes rowversion from an insertable load" $ \conn -> do
      void $ execute conn "CREATE TABLE #rv (v int NOT NULL, rv rowversion)"
      map bulkColumnName <$> describeBulkColumns conn (bulkCopy "#rv") `shouldReturn` ["v"]

    it "cannot bulk-insert a rowversion column even by name" $ \conn -> do
      void $ execute conn "CREATE TABLE #rv2 (v int NOT NULL, rv rowversion)"
      -- The server generates rowversion; asking to load it fails.
      bulkInsertWith (bulkCopy "#rv2") { bulkColumns = NamedColumns ["rv"] } conn
        [Only (B.pack [0,0,0,0,0,0,0,1] :: B.ByteString)]
        `shouldThrow` (\(_ :: SqlServerError) -> True)

    it "refuses a CLR UDT (hierarchyid) with an EncodeError" $ \conn -> do
      void $ execute conn "CREATE TABLE #hid (h hierarchyid NULL)"
      -- hierarchyid is discovered as a CLR UDT; encodeBulkCellBytes has no path
      -- into it, so it is a client-side EncodeError (never silently wrong).
      bulkInsert conn "#hid" [Only (B.pack [0x58] :: B.ByteString)]
        `shouldThrow` (\(EncodeError _) -> True)

------------------------------------------------------------------------------
-- Exact numerics

exactNumericCases :: [TypeCase]
exactNumericCases =
  [ typeCase "bit" "bit"
      [ same True, same False
      , into (1 :: Int32) True, into (0 :: Int32) False
      , nullCell
      ]
  , typeCase "tinyint" "tinyint"
      [ same (0 :: Word8), same (255 :: Word8), same (1 :: Word8), nullCell ]
  , typeCase "smallint" "smallint"
      [ same (minBound :: Int16), same (maxBound :: Int16), same (0 :: Int16), same (-1 :: Int16), nullCell ]
  , typeCase "int" "int"
      [ same (minBound :: Int32), same (maxBound :: Int32), same (0 :: Int32), same (-1 :: Int32), nullCell ]
  , typeCase "bigint" "bigint"
      [ same (minBound :: Int64), same (maxBound :: Int64), same (0 :: Int64), nullCell ]
  , typeCase "decimal(10,2)" "decimal(10,2)"
      [ same (dec 2 0)
      , same (dec 2 1234567890)     -- 12345678.90 (10 digits)
      , same (dec 2 (-1234567890))
      , same (dec 2 1)              -- 0.01
      , nullCell
      ]
  , typeCase "numeric(10,4)" "numeric(10,4)"
      [ same (dec 4 123456)         -- 12.3456
      , same (dec 4 (-123456))
      , same (dec 4 0)
      , nullCell
      ]
  , typeCase "decimal(38,0)" "decimal(38,0)"
      [ same (dec 0 (10 ^ (37 :: Int)))
      , same (dec 0 (negate (10 ^ (37 :: Int))))
      , nullCell
      ]
  , typeCase "money" "money"
      [ same (Money 0), same (Money 1234.5678), same (Money (-99.99)), nullCell ]
  , typeCase "smallmoney" "smallmoney"
      [ same (Money 0), same (Money 214748.3647), same (Money (-214748.3647)), same (Money 12.34), nullCell ]
  ]

------------------------------------------------------------------------------
-- Approximate numerics

approxNumericCases :: [TypeCase]
approxNumericCases =
  [ typeCase "float" "float"
      [ same (0 :: Double), same (1.5 :: Double), same (-1.5 :: Double)
      , same (pi :: Double), same (1.0e308 :: Double), same (2.2250738585072014e-308 :: Double)
      , nullCell
      ]
  , typeCase "real" "real"
      [ same (0 :: Float), same (1.5 :: Float), same (-1.5 :: Float), same (3.4e38 :: Float), nullCell ]
  ]

------------------------------------------------------------------------------
-- Date and time

dateTimeCases :: [TypeCase]
dateTimeCases =
  [ typeCase "date" "date"
      [ same (fromGregorian 2021 6 15)
      , same (fromGregorian 1 1 1)
      , same (fromGregorian 9999 12 31)
      , nullCell
      ]
  , typeCase "time(7)" "time(7)"
      [ same (TimeOfDay 13 45 30.1234567), same (TimeOfDay 0 0 0), same (TimeOfDay 23 59 59.9999999), nullCell ]
  , typeCase "time(0)" "time(0)"
      [ same (TimeOfDay 13 45 30), same (TimeOfDay 0 0 0), nullCell ]
  , typeCase "datetime" "datetime"
      [ same (LocalTime (fromGregorian 2021 6 15) (TimeOfDay 13 45 30))
      , same (LocalTime (fromGregorian 1753 1 1) (TimeOfDay 0 0 0))
      , nullCell
      ]
  , typeCase "smalldatetime" "smalldatetime"
      [ same (LocalTime (fromGregorian 2021 6 15) (TimeOfDay 13 45 0))
      , nullCell
      ]
  , typeCase "datetime2(7)" "datetime2(7)"
      [ same (LocalTime (fromGregorian 2021 6 15) (TimeOfDay 13 45 30.1234567))
      , same (LocalTime (fromGregorian 1 1 1) (TimeOfDay 0 0 0))
      , nullCell
      ]
  , typeCase "datetime2(3)" "datetime2(3)"
      [ same (LocalTime (fromGregorian 2021 6 15) (TimeOfDay 13 45 30.123))
      , nullCell
      ]
  , typeCase "datetimeoffset(7)" "datetimeoffset(7)"
      [ same (DateTimeOffset (UTCTime (fromGregorian 2021 6 15) (timeOfDayToTime (TimeOfDay 13 45 30.1234567))) 0)
      , same (DateTimeOffset (UTCTime (fromGregorian 2021 6 15) (timeOfDayToTime (TimeOfDay 8 15 30.1234567))) 330)
      , nullCell
      ]
  ]

------------------------------------------------------------------------------
-- Character (single-byte) types.  The default database collation is
-- SQL_Latin1_General_CP1_CI_AS (CP1252); accented Latin and the euro sign
-- are representable in it, CJK/emoji are not (see Bulk.PolicySpec).

charCases :: [TypeCase]
charCases =
  [ typeCase "char(6)" "char(6)"
      [ into ("abcdef" :: Text) ("abcdef" :: Text)
      , into ("ab" :: Text) ("ab    " :: Text)          -- right-padded with spaces
      , into ("" :: Text) ("      " :: Text)
      , into (" " :: Text) ("      " :: Text)
      , nullCell
      ]
  , typeCase "varchar(50)" "varchar(50)"
      [ same ("hello, world" :: Text)
      , same ("" :: Text)
      , same (" " :: Text)
      , same ("Caf\233 cr\232me" :: Text)               -- é, è in CP1252
      , same ("\8364 100" :: Text)                      -- euro sign in CP1252
      , nullCell
      ]
  , typeCase "varchar(50) UTF-8" "varchar(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8"
      [ same ("Stra\223e \8364 \26085\26412" :: Text)    -- ß € 日本
      , same ("\128512" :: Text)                          -- 😀 (non-BMP)
      , same ("" :: Text)
      , nullCell
      ]
  , typeCaseNoLen "varchar(max)" "varchar(max)"
      [ same (T.replicate 10000 "y")
      , same ("small" :: Text)
      , same ("" :: Text)
      , nullCell
      ]
  , typeCaseNoLen "text" "text"
      [ same ("a text value" :: Text)
      , same (T.replicate 9000 "t")
      , nullCell
      ]
  ]

------------------------------------------------------------------------------
-- Unicode character types

ncharCases :: [TypeCase]
ncharCases =
  [ typeCase "nchar(6)" "nchar(6)"
      [ into ("ab" :: Text) ("ab    " :: Text)
      , into ("abcd\233f" :: Text) ("abcd\233f" :: Text)  -- abcdéf, 6 chars, no pad
      , nullCell
      ]
  , typeCase "nvarchar(50)" "nvarchar(50)"
      [ same ("h\233llo w\246rld" :: Text)
      , same ("\128512 emoji \26085\26412" :: Text)
      , same ("" :: Text)
      , same (" " :: Text)
      , same ("a\0b" :: Text)                            -- embedded NUL
      , nullCell
      ]
  , typeCaseNoLen "nvarchar(max)" "nvarchar(max)"
      [ same (T.replicate 30000 "y" <> "\128512")
      , same ("" :: Text)
      , nullCell
      ]
  , typeCaseNoLen "ntext" "ntext"
      [ same ("an ntext value \26085\26412" :: Text)
      , same (T.replicate 9000 "n")
      , nullCell
      ]
  ]

------------------------------------------------------------------------------
-- Binary types

binaryCases :: [TypeCase]
binaryCases =
  [ typeCase "binary(4)" "binary(4)"
      [ same (B.pack [1,2,3,4])
      , into (B.pack [1,2]) (B.pack [1,2,0,0])           -- right-padded with zeros
      , into B.empty (B.pack [0,0,0,0])
      , nullBinary
      ]
  , typeCase "varbinary(10)" "varbinary(10)"
      [ same (B.pack [1,2,3])
      , same B.empty
      , same (B.pack [0..9])
      , nullBinary
      ]
  , typeCaseNoLen "varbinary(max)" "varbinary(max)"
      [ same (B.replicate 100000 0xAB)
      , same (B.pack [1,2,3])
      , same B.empty
      , nullBinary
      ]
  , typeCaseNoLen "image" "image"
      [ same (B.pack [1,2,3,4])
      , same (B.replicate 9000 0xCD)
      , nullBinary
      ]
  ]

------------------------------------------------------------------------------
-- Other types

otherCases :: [TypeCase]
otherCases =
  [ typeCase "uniqueidentifier" "uniqueidentifier"
      [ same (UUID.fromWords 0x12345678 0x9abcdef0 0x11223344 0x55667788)
      , same UUID.nil
      , nullCell
      ]
  , TypeCase "xml" "xml" "CAST(v AS nvarchar(max))" False
      [ into ("<a>1</a>" :: Text) ("<a>1</a>" :: Text)
      , into ("<root><child x=\"1\"/></root>" :: Text) ("<root><child x=\"1\"/></root>" :: Text)
      , nullCell
      ]
  , TypeCase "sql_variant" "sql_variant" "v" False
      [ into (5 :: Int32) (SqlInt32 5)
      , into ("hi" :: Text) (SqlText "hi")
      , into (3.5 :: Double) (SqlDouble 3.5)
      , nullVariant
      ]
  ]

------------------------------------------------------------------------------
-- SQL Server 2025 types.  Over TDS the server downgrades json to
-- nvarchar(max) and vector to varchar; a bulk load sends the text and the
-- server converts it back.

sql2025Cases :: [TypeCase]
sql2025Cases =
  [ TypeCase "json" "json" "CAST(v AS nvarchar(max))" False
      [ into ("{\"a\":1,\"b\":[1,2,3]}" :: Text) ("{\"a\":1,\"b\":[1,2,3]}" :: Text)
      , into ("{\"x\":true}" :: Text) ("{\"x\":true}" :: Text)
      , nullCell
      ]
  , typeCase "vector(3)" "vector(3)"
      [ into ("[1,2,3]" :: Text) ("[1.0000000e+000,2.0000000e+000,3.0000000e+000]" :: Text)
      , into ("[0.5,-1.25,3]" :: Text) ("[5.0000000e-001,-1.2500000e+000,3.0000000e+000]" :: Text)
      , nullCell
      ]
  ]
