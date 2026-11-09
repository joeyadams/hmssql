-- | The row decoder of a statement, built from the model.
--
-- Which columns a statement returns is only known when the request
-- arrives, but each column's type is known from the model.  So the
-- decoder is assembled per request: a typed 'FieldDecoder' per column
-- (@Int64@, @Decimal@, @Text@, ...), each mapped to the JSON of its value,
-- combined with the 'RowDecoder' 'Applicative' into the row's JSON
-- members.  A value goes from the TDS packet to a Haskell value to JSON
-- bytes, and no row is ever a list of dynamic values.
--
-- hmssql checks a 'RowDecoder' against the result set's metadata once,
-- when the metadata arrives and before any row is decoded.  A table that
-- changed since the model was read is a 'DecodeError' naming the column,
-- before any of the response has been sent.
module OData.Decode
  ( Row (..)
  , levelRow
  ) where

import qualified Data.Aeson as Aeson
import Data.Aeson.Encoding (Encoding)
import qualified Data.Aeson.Encoding as E
import Data.ByteString.Builder (Builder, char7)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (scientific)
import Data.Text (Text)
import Data.Time (Day, LocalTime, TimeOfDay)
import Data.UUID.Types (UUID)

import Hmssql
import Hmssql.Decoding (FieldDecoder, RowDecoder, nullableField, singleField)
import Hmssql.Types (DateTimeOffset, dateTimeOffsetToZonedTime)
import OData.Model
import OData.Query (Level (..))

-- | A row of one level's statement.
data Row = Row
  { parentRn :: !Int64
    -- ^ The number of the parent row this row belongs to; 0 at the root.
  , members :: Builder
    -- ^ The selected columns as JSON members: @"id":1,"name":"Ada"@.
  , rn :: !Int64
    -- ^ This row's number, which its children carry as 'parentRn'.
  }

-- | The decoder for a level's statement, in the column order
-- 'OData.Query.compile' produces.
levelRow :: Level -> RowDecoder Row
levelRow level = Row <$> parentRn <*> members <*> singleField fieldDecoder
  where
    parentRn = if level.isRoot then pure 0 else singleField fieldDecoder
    members = commaSep <$> traverse member level.selected
    member col = (\v -> E.fromEncoding (E.text col.colName) <> char7 ':' <> E.fromEncoding v) <$> singleField (columnValue col)

-- | One column's value as JSON.  NULL is accepted only where the model
-- says the column is nullable.
columnValue :: Column -> FieldDecoder Encoding
columnValue col
  | col.colNullable = fromMaybe E.null_ <$> nullableField (typedValue col.colType)
  | otherwise = typedValue col.colType

typedValue :: ColumnType -> FieldDecoder Encoding
typedValue = \case
  TInt -> E.int64 <$> fieldDecoder @Int64
  TDecimal -> decimal <$> fieldDecoder @Decimal
  TDouble -> E.double <$> fieldDecoder @Double
  TBool -> E.bool <$> fieldDecoder @Bool
  TString -> E.text <$> fieldDecoder @Text
  TDate -> E.day <$> fieldDecoder @Day
  TDateTime -> E.localTime <$> fieldDecoder @LocalTime
  -- The offset is kept: 2026-02-20T09:05:00-05:00, not converted to UTC.
  TDateTimeOffset -> E.zonedTime . dateTimeOffsetToZonedTime <$> fieldDecoder @DateTimeOffset
  TTime -> E.timeOfDay <$> fieldDecoder @TimeOfDay
  TGuid -> Aeson.toEncoding <$> fieldDecoder @UUID
  where
    decimal (Decimal places mantissa) = E.scientific (scientific mantissa (negate (fromIntegral places)))

commaSep :: [Builder] -> Builder
commaSep [] = mempty
commaSep (b : bs) = b <> foldMap (char7 ',' <>) bs
