# Encoders

Two types turn Haskell values into parameters, both in `Hmssql.Encoding`:

* A `FieldEncoder a` turns an `a` into one parameter: its wire type and
  its bytes. The built-in types have one each, as their `fieldEncoder`.
* A `RowEncoder a` turns an `a` into a list of parameters, the `@p1`,
  `@p2` and so on of `mkQuery`, or one row of `executeMany` or
  `bulkInsert`.

[Parameters](../queries/parameters.md) covers the derived `ToSqlRow`
instances and the ways to pass parameters with a query. This page is
about how a value is declared to the server, and about the encoders you
write yourself.

## What each type is sent as

Each Haskell type is sent as one SQL type. `Int` is sent as `bigint`,
`Text` as `nvarchar` of any length, and `LocalTime` as `datetime2(7)`.
The full table is in the Haddock of `Hmssql.Types`.

The server converts where it can, but a mismatch can cost you an index:
comparing an `nvarchar` parameter against a `varchar` column can turn an
index seek into a scan. `RawParam` from `Hmssql.Types` sends a value
with a wire type of your choosing, and "An encoder from the wire type and
the bytes" below shows how to make that a type's own encoder.

## Long strings

A `Text` of up to 4000 UTF-16 code units is declared as `nvarchar(4000)`.
A longer one is declared as `nvarchar(max)`, and so is a NULL.
`ByteString` follows the same rule with `varbinary(8000)`.

Most queries never notice the difference. Three cases do:

* `@p1 + @p2` stops at 4000 characters, without an error. Write
  `CAST(@p1 AS nvarchar(max)) + @p2` if the result can grow past that.
* `sql_variant` refuses `(max)` types, with error 206.
* A statement can have two cached plans, one per declaration.

Lazy `ByteString` and lazy `Text` are declared by the same rule. A longer
value is forced as it is sent, and a shorter one is forced first and then
sent. To send a value without holding it in memory at all, use a streamed
parameter, which [Streaming values](streaming-values.md) describes.

## An encoder for your own type

Both `FieldEncoder` and `RowEncoder` are `Contravariant`, as in hpgsql.
Use `contramap` from `Data.Functor.Contravariant` to adapt an existing
encoder. A newtype takes the encoder of the type it wraps:

```haskell
import Data.Functor.Contravariant (contramap)
import Hmssql.Encoding (ToSqlField (..))

newtype CustomerId = CustomerId { unCustomerId :: Int }

instance ToSqlField CustomerId where
  fieldEncoder = contramap unCustomerId fieldEncoder
```

An enumeration is sent as the text the column stores, the mirror image of
the `Status` decoder in [Reading rows](../queries/reading-rows.md):

```haskell
instance ToSqlField Status where
  fieldEncoder = contramap statusText fieldEncoder
    where
      statusText :: Status -> Text
      statusText Active = "active"
      statusText Suspended = "suspended"
```

With both instances, `param (CustomerId 5)` and `param Active` work
wherever a parameter goes, and the two types can be fields of a derived
`ToSqlRow` record.

## A row encoder by hand

`singleParam` turns a `FieldEncoder` into a `RowEncoder` of one
positional parameter, and `divideRow` joins two row encoders over a
product: it takes a function that splits the value, and sends the first
part's parameters before the second's. Here the `Booking` of
[Decoders](decoders.md) is sent as three parameters, with the nested
`Period` accounting for two of them:

```haskell
import Hmssql.Encoding (RowEncoder, divideRow, fieldEncoder, singleParam)

bookingEncoder :: RowEncoder Booking
bookingEncoder = divideRow (\b -> (bookingRoom b, bookingPeriod b)) (singleParam fieldEncoder) periodEncoder
  where
    periodEncoder = divideRow (\p -> (periodStart p, periodEnd p)) (singleParam fieldEncoder) (singleParam fieldEncoder)

instance ToSqlRow Booking where
  rowEncoder = bookingEncoder

execute conn (mkQuery "INSERT INTO dbo.booking (room, start_date, end_date) VALUES (@p1, @p2, @p3)" booking)
```

`executeMany` and `bulkInsert` take a list of such values, one row each.
`contramap` works on a `RowEncoder` too, so a type that is a `Booking`
in disguise reuses `bookingEncoder` without a split.

## What a derived instance amounts to

`deriving anyclass (ToSqlRow)` gives `NewCustomer` from
[Parameters](../queries/parameters.md) the encoder a hand-written
`divideRow` chain would give it: one positional parameter per field, in
field order.

```haskell
instance ToSqlRow NewCustomer where
  rowEncoder = divideRow (\(NewCustomer a b c) -> (a, (b, c)))
    (singleParam fieldEncoder)
    (divideRow id (singleParam fieldEncoder) (singleParam fieldEncoder))
```

As with decoding, the instance comes from the type's `GHC.Generics`
representation:

* A product `f :*: g` becomes the parameters of `f` followed by those of
  `g`.
* A field `K1 a` becomes the `fieldEncoder` of the field's type, which is
  why every field needs a `ToSqlField` instance.
* The metadata wrappers `M1` contribute no parameters, and the field
  names are not used. A parameter that should go by name is a
  `NamedParams` value instead.

The walk only takes the record apart; the names, the closures and the
encoding itself are shared library code, so a derived record costs a few
words of code per field. A hand-written encoder is for a value that is not
a flat record, as `Booking` is not.

## An encoder from the wire type and the bytes

A `FieldEncoder` is a record of two functions, and can be written out
when no existing encoder fits. `encodeParam` receives the connection's
`TdsContext`, for an encoding that depends on the negotiated protocol, and
the value, and returns the `TypeInfo` to declare and the bytes to send, or
the reason the value cannot be sent, which the query functions throw as
`EncodeError` before anything goes to the server. `nullParamType` is the
type to declare for a NULL, which the `Maybe` instance uses for
`Nothing`. This encoder sends the `Rgb` of [Decoders](decoders.md) as an
`int`:

```haskell
import Data.Bits (shiftR)
import qualified Data.ByteString as B
import Hmssql.Encoding (FieldEncoder (..), ParamValue (..))
import Hmssql.Types (TypeInfo (..))

rgbEncoder :: FieldEncoder Rgb
rgbEncoder = FieldEncoder
  { encodeParam = \_ctx (Rgb w) ->
      Right (TIIntN 4, ParamBytes (Just (B.pack [fromIntegral (w `shiftR` s) | s <- [0, 8, 16, 24]])))
  , nullParamType = const (TIIntN 4)
  }

instance ToSqlField Rgb where
  fieldEncoder = rgbEncoder
```

`ParamBytes Nothing` is a NULL, `ParamLazy` sends a lazy `ByteString` as
it is forced, and `ParamStream` reads a `Source` as it is sent, which is
what `binaryStream` builds. For a one-off value, `RawParam` from
`Hmssql.Types` is this encoder with the type and the bytes supplied at
the call: `RawParam (TIIntN 4, Just bytes)`.

## Rows built at runtime

`SqlParam` wraps any `ToSqlField` value, so a list of `SqlParam` is a row
of mixed types that can be built at runtime, and `NamedParams` pairs each
with a name. `genericToSqlRow` is the encoder a derived `ToSqlRow`
instance uses, for an instance that wants the derived behavior under a
hand-written class declaration.

## How it works

A `RowEncoder` produces, for each parameter, its name (empty for a
positional one) and a function from the connection's context to the
encoded parameter. The names and the parameter count never depend on the
connection, so the SQL text is rendered and checked before anything is
encoded, and only the values' bytes wait for the context. A query with
parameters then goes to the server as a call to `sp_executesql`, with the
declared types in its parameter list and the bytes as typed values, never
as text.
