# Decoders

Two types turn a result into Haskell values, both in `Hmssql.Decoding`:

* A `FieldDecoder a` reads one column into an `a`. The built-in types have
  one each, as their `fieldDecoder`.
* A `RowDecoder a` reads a fixed number of columns into an `a`. It is an
  `Applicative`, so decoders of single columns combine into a decoder of a
  row.

[Reading rows](../queries/reading-rows.md) covers the derived `FromSqlRow`
instances and `refineField`. This page shows how to build the same things
by hand, and what the derived instances amount to.

## A row decoder by hand

`singleField` turns a `FieldDecoder` into a `RowDecoder` of one column,
and `<$>` and `<*>` combine such decoders in column order. Here a booking
is read from three columns, two of which form a nested record:

```haskell
import Hmssql.Decoding (RowDecoder, fieldDecoder, singleField)
import Hmssql.Query (queryWith)

data Period = Period { periodStart :: Day, periodEnd :: Day }
data Booking = Booking { bookingRoom :: Int, bookingPeriod :: Period }

bookingDecoder :: RowDecoder Booking
bookingDecoder = Booking <$> singleField fieldDecoder <*> periodDecoder
  where
    periodDecoder = Period <$> singleField fieldDecoder <*> singleField fieldDecoder

bookings <- queryWith bookingDecoder conn "SELECT room, start_date, end_date FROM dbo.booking"
```

`queryWith` and `query1With` take the decoder in place of a `FromSqlRow`
instance, and `withQueryS` has a `withQuerySWith` for streaming. A decoder
of a type's own instance is `fieldRowDecoder`, which is
`singleField fieldDecoder` with the built-in types' fast path, so
`Booking <$> fieldRowDecoder <*> ...` reads the same.

A `RowDecoder` knows how many columns it reads, and the result set must
have exactly that many. The check runs when the column metadata arrives,
before the first row, together with each column's type check, so a wrong
`SELECT` list fails with a `DecodeError` even when the result is empty.

## What a derived instance amounts to

`deriving anyclass (FromSqlRow)` gives `Customer` from
[Reading rows](../queries/reading-rows.md) exactly this instance:

```haskell
instance FromSqlRow Customer where
  rowDecoder = Customer <$> fieldRowDecoder <*> fieldRowDecoder <*> fieldRowDecoder <*> fieldRowDecoder
```

It is built from the type's `GHC.Generics` representation, which for a
record is a product of its fields, each wrapped in metadata. The generic
decoder walks that representation:

* A product `f :*: g` becomes the decoder of `f` followed by the decoder
  of `g`, so the columns come in field order.
* A field `K1 a` becomes `fieldRowDecoder` of the field's type, which is
  why every field needs a `FromSqlField` instance.
* The metadata wrappers `M1` contribute nothing. The field names are not
  used, which is why columns match fields by position and not by name.
* At the end, `to` turns the representation back into a `Customer`.

The composition itself is compiled once in the library, so a derived
record holds a few words of code per field rather than a copy of the row's
reading. A hand-written decoder is the right choice when a field is more
than one column, as `Period` is above, or when it is not a record at all.

## A field decoder of your own

There are three ways to write a `FieldDecoder`, from the least work to
the most control.

**Refine an existing decoder.** `refineField` converts a decoded value
further, and a `Left` becomes a `DecodeError` naming the column. This is
how [Reading rows](../queries/reading-rows.md) decodes `Status` from an
`nvarchar` column.

**Accept NULL.** The `Maybe` instance wraps any field decoder with
`nullableField`, so `Maybe Status` works as soon as `Status` does. A
decoder used directly is wrapped the same way:

```haskell
import Hmssql.Decoding (nullableField)

statuses <- queryWith (singleField (nullableField fieldDecoder)) conn
              "SELECT status FROM dbo.customer" :: IO [Maybe Status]
```

**Decode the bytes yourself.** `fieldDecoderFor` builds a decoder from a
name for error messages, a predicate on the column's wire type, and a
conversion from the value's bytes. This one reads a color packed into an
`int` column:

```haskell
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as B
import Hmssql.Decoding (FieldDecoder, fieldDecoderFor)
import Hmssql.Types (TypeInfo (..))

newtype Rgb = Rgb Word32 deriving (Eq, Show)

rgbDecoder :: FieldDecoder Rgb
rgbDecoder = fieldDecoderFor "Rgb" isInt $ \_ctx _ti bytes ->
  if B.length bytes == 4
    then Right (Rgb (B.foldr (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 bytes))
    else Left ("expected 4 bytes, got " ++ show (B.length bytes))
  where
    isInt ti = ti == TIInt4 || ti == TIIntN 4

instance FromSqlField Rgb where
  fieldDecoder = rgbDecoder
```

The predicate runs once per result set, when the columns arrive, so a
`bigint` column is refused before any row is read, with a `DecodeError`
that names the column and both types. The conversion runs per value. Its
arguments are the connection's `TdsContext`, for a decoding that depends
on the negotiated protocol, the column's `TypeInfo`, and the value's bytes
with any length prefix already removed. The bytes may be a slice of the
receive buffer, so a conversion that keeps them must copy them, as the
Haddock of `CellDecoder` explains. A NULL is a `DecodeError` unless the
decoder is wrapped in `nullableField`.

The ready-made version of the last step is `RawValue` from `Hmssql.Types`,
which decodes any column as the bytes the server sent.

## Decoders chosen from the column metadata

A program that builds its queries at runtime may not know a column's type
until the result arrives. `byColumn` calls your function once, when the
columns arrive, with the column's `ColumnInfo`:

```haskell
import Hmssql.Decoding (byColumn, fieldRowDecoder, sqlValueDecoder)
import Hmssql.Types (ColumnInfo (..), TypeInfo (..))

asValue :: RowDecoder SqlValue
asValue = byColumn $ \col -> case columnType col of
  TIIntN 4 -> SqlInt32 <$> fieldRowDecoder
  _ -> singleField sqlValueDecoder
```

Each column then reads through the decoder chosen for it, which costs less
than `sqlValueDecoder` for every column. `columnIsLong` says whether a
column's values may be of any length, as those of a `max` type may.

When a later column depends on an earlier value, `RowDecoderMonadic` runs
per row instead: `singleFieldM` reads the next column, `remainingColumns`
lists the columns not yet read, and `queryMWith` runs the decoder. A
completed monadic decoder must have read every column. Because its checks
run per row, an empty result set is not checked at all.

## Values handed over in parts

Some programs write each value out as text or JSON, and for them the
`time` types are a detour. `dayTimeFieldDecoder`,
`dateTimeOffsetFieldDecoder` and `timeFieldDecoder` hand a date or time
value to your function as its parts: the day, the picoseconds since
midnight and the offset in minutes. They check a value as the built-in
decoders do. `decimalFieldDecoder` does the same for `decimal`, `money`
and the integer types, and your function receives the sign, the magnitude
as two 64-bit words and the scale.

`inlinedField` is `singleField` with the cell's read compiled around your
conversion. It pays off for a small conversion that many rows go through.
For a nullable column, use `inlinedNullableField`. Each use is a copy of
the cell's read, so bind it once at the top level, with a `NOINLINE`
pragma.

## How it works

Decoding runs in two stages. When a result set's column metadata arrives,
each `FieldDecoder` is given the connection's context and its column, and
returns either a `CellDecoder`, the function that will read that column's
values, or the reason it cannot. The `RowDecoder` checks the column count
at the same time. Then every row is read from the packet it arrived in
with those compiled cell decoders, and nothing is checked again.

A decoder can also consume a value in chunks, as they arrive.
[Streaming values](streaming-values.md) covers `streamField` and the
generic cell interface.
