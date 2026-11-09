# Reading rows

Define a record for the columns you select, derive `FromSqlRow`, and ask
for a list:

```haskell
data Customer = Customer
  { customerId :: Int
  , name :: Text
  , email :: Text
  , birthDate :: Maybe Day
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromSqlRow)

customers <- query conn "SELECT id, name, email, birth_date FROM dbo.customer"
mapM_ print (customers :: [Customer])
```

Columns match fields by position, so the `SELECT` list and the record
must line up. A nullable column is a `Maybe`, and any field type can be
wrapped in `Maybe`.

## Type checking

The column types are checked against the record before the first row is
decoded. A mismatch throws `DecodeError`, which names the column and both
types. A bad value in a row throws `DecodeError` too; nothing in the
decoder calls `error`.

The Haddock of `Hmssql.Types` has the table of which SQL types each
Haskell type accepts.

## Other shapes

* Tuples work up to twelve columns.
* `Only` is for one column.
* `query1` fetches exactly one row, and throws `UnexpectedResult`
  otherwise.
* `queryMay` fetches at most one row.
* `queryFold` folds over the rows without building a list.

`query1With` and `queryMayWith` in `Hmssql.Query` take an explicit
`RowDecoder` and keep the same row-count checks. For example, a single
column can be read directly, without an `Only` wrapper:

```haskell
name <- queryMayWith (singleField fieldDecoder) conn
          ("SELECT name FROM dbo.customer WHERE id = " <> param customerId)
          :: IO (Maybe Text)
```

`singleField` turns a `FieldDecoder` into a `RowDecoder` of one column.
[Decoders](../decoders-and-encoders/decoders.md) covers it and the rest of
`Hmssql.Decoding`.

## Columns you only know at runtime

`SqlRow` decodes any result set. It holds the row's columns and a list of
`SqlValue`, with one constructor per SQL Server type, and it lives in
`Hmssql.SqlValue`. SQL Server's `tinyint` is unsigned, so its constructor
is `SqlWord8 Word8`, with values from 0 through 255.

`queryMulti` from `Hmssql.Query` reads every result set of a batch that
way, with its column metadata.

## A column of your own type

A `FromSqlField` instance makes a type of your own usable as a field.
Usually it is `refineField` from `Hmssql.Decoding` applied to an existing
decoder:

```haskell
data Status = Active | Suspended

instance FromSqlField Status where
  fieldDecoder = refineField parse fieldDecoder
    where
      parse :: Text -> Either String Status
      parse "active" = Right Active
      parse "suspended" = Right Suspended
      parse other = Left ("unknown status " ++ show other)
```

A `Left` becomes a `DecodeError` for that row.
[Decoders](../decoders-and-encoders/decoders.md) goes further: row
decoders built by hand, decoders that hand a value to your code in parts,
and decoders chosen from the column metadata.

## How it works

The server sends the column metadata first, and hmssql compiles the row
decoder against it once. Every row is then decoded straight out of the
packet it arrived in.
