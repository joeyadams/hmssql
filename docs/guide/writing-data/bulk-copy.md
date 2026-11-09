# Bulk copy

`bulkInsert` from `Hmssql.BulkCopy` loads many rows into one table with
the TDS bulk load, which is what `bcp` and .NET's `SqlBulkCopy` use. The
rows travel as a stream of binary values, each in its column's own type,
with no statement to compile and no parameters to bind, and it is the
fastest way to fill a table:

```haskell
n <- bulkInsert conn "dbo.item" [(1 :: Int, "one" :: Text, 9.99 :: Double), (2, "two", 0.5)]
-- the number of rows the server inserted
```

## Rows

Any `ToSqlRow` value is a row: a tuple, a record with a derived instance,
an `Only`, a list of `SqlParam` or a `NamedParams`. The record that
`mkQuery` or `executeMany` takes loads unchanged:

```haskell
data NewItem = NewItem { itemId :: Int, itemName :: Text, itemPrice :: Decimal }
  deriving stock (Generic)
  deriving anyclass (ToSqlRow)

n <- bulkInsert conn "dbo.item" [NewItem 1 "one" 9.99, NewItem 2 "two" 0.5]
```

The difference from an `INSERT` is where the values go. An `INSERT` names
its columns, while a bulk load takes the table's insertable columns in
table order, and a positional row supplies one value for each of them. A
row with the wrong number of values is an `EncodeError` naming the row,
and a table with an extra column, or with its columns in another order,
is a mismatch the types may not catch. Two settings pin the columns down.
`NamedColumns` says which columns the rows hold and in what order, and
the columns it leaves out get their defaults:

```haskell
import Hmssql.BulkCopy

n <- bulkInsertWith (bulkCopy "dbo.item") { bulkColumns = NamedColumns ["id", "name", "price"] } conn items
```

A row of `NamedParams` names its own columns instead, and the names are
matched against the table, so the order no longer matters. Every selected
column still needs a value:

```haskell
n <- bulkInsert conn "dbo.item"
  [ NamedParams [("name", SqlParam ("one" :: Text)), ("price", SqlParam (9.99 :: Double)), ("id", SqlParam (1 :: Int))] ]
```

The identity column is left out of the insertable columns and the server
generates it, unless `bulkKeepIdentity` is set and the rows supply it.
Computed, `rowversion` and generated-always columns are never loaded.

## What the server skips

A bulk load skips the checks an `INSERT` makes, unless asked for them:

* Check constraints and foreign keys are not checked, and the load leaves
  them marked as not trusted, which keeps the query optimizer from relying
  on them afterwards. `bulkCheckConstraints` checks them and keeps the
  trust, and `ALTER TABLE ... WITH CHECK CHECK CONSTRAINT` restores it after
  a load that skipped them.
* Insert triggers do not fire, unless `bulkFireTriggers` is set.
* A NULL for a column with a default gets the default, unless
  `bulkKeepNulls` is set.

## Settings

`bulkInsertWith` takes a `BulkCopy`, which is `bulkCopy table` with some
of its fields changed. Besides the columns and the three options above,
`bulkTableLock` takes a table lock for the load, which allows minimal
logging and suits a large load into a table nobody else is using, and
`bulkOrder` tells the server that each batch is already sorted like the
clustered index. The rows are never sorted on the client, and a table with
a clustered index refuses a batch that is out of the declared order.

`bulkBatchSize` splits the rows into loads of that many, each committed on
its own outside a transaction, which bounds the server's memory and the
rows lost to a failure. "Batches and transactions" below has what each
arrangement leaves behind.

A table that is loaded many times needs its columns described only once.
`describeBulkColumns` asks the server, and `DescribedColumns` reuses the
answer, so each later load is one request:

```haskell
cols <- describeBulkColumns conn (bulkCopy "dbo.item")
let settings = (bulkCopy "dbo.item") { bulkColumns = DescribedColumns cols }
forM_ batches $ \rows -> bulkInsertWith settings conn rows
```

`DescribedColumns` also lets you declare the type the values are sent in,
leaving the conversion to the server, as an `INSERT` would convert
implicitly. "What the client refuses" below says when that matters.

## Streams: from a file, or from another connection

`bulkInsertS` takes a `Stream` from the streaming package instead of a
list, and `bulkInsertSWith` adds the settings. The rows are pulled as the
packets are filled, so a stream of any length needs one packet's worth of
memory. A file read line by line is one source. A query on another
connection is the other common one, and it copies a table of any size
without holding it:

```haskell
src <- queryS source "SELECT id, name, price FROM dbo.item WHERE price > 1"
n <- bulkInsertS target "dbo.expensive_item" (src :: Stream (Of (Int, Text, Decimal)) IO ())
```

The stream runs while the load holds the target connection, so it must
not use that connection, even for two tables in one database. On a MARS
connection it may read a stream opened before the load began, but not
start a request. If the stream throws, the load is canceled and the
exception reaches you.

The [bulk-copy example](../../../examples/bulk-copy/README.md) is this
shape at full size: it copies a table between two databases, passing each
value through as its wire bytes without decoding it, after checking both
tables' catalogs that every column converts.

## Batches and transactions

One load without `bulkBatchSize` is atomic by itself: a failure anywhere,
whether a value refused on the client, a duplicate key or the source
stream failing, leaves none of its rows, transaction or not. With
`bulkBatchSize`, each batch is a load of its own and commits when it ends,
so the batches before a failure stay. Inside `withTransaction`, every
batch commits with the transaction or not at all, and the target's locks
are held until the end:

| | One load | `bulkBatchSize` | `bulkBatchSize` inside `withTransaction` |
|---|---|---|---|
| A value refused on the client | no rows | the batches before | no rows |
| The server refuses a row | no rows | the batches before | no rows |
| The source stream throws | no rows | the batches before | no rows |

A client conversion failure throws `EncodeError`, naming the row and the
column, before the row is sent, and the rows of its batch that were
already sent are discarded with it. A server rejection throws
`SqlServerError` at the end of the batch, because the server answers a
bulk load once, when it has read all of it. The exception is a trigger's
`RAISERROR` without a rollback, which reports an error and keeps the
batch's rows.

## What the client refuses

Each value is converted to its column's type on the client, within a
family of types: numbers to any numeric column, rounded or truncated and
range-checked as the server converts them; strings to any character,
`xml` or `sql_variant` column; and date and time values among the date and
time types. A value outside its family, such as a `Text` for an `int`
column, is an `EncodeError` naming the row and the column. Convert it in
Haskell, or declare the column with `DescribedColumns` in the type the
value is sent as and let the server convert.

Bulk copy is stricter than an `INSERT` with characters. With
`ANSI_WARNINGS OFF`, an `INSERT` can truncate a long string silently, and a
character absent from a single-byte column's code page is stored as `?`.
Bulk copy refuses both on the client. A NULL for a NOT NULL column is
refused too, even one with a default, so leave the column out to get the
default.

Numbers are rounded as the server rounds them, so a `Double` loaded into
a `decimal` column stores the same digits by either path. The Haddock of
`encodeBulkCell` has the conversion rules.

For custom bulk writers, `encodeBulkCell` returns a `ParamValue` for
`bulkWireType (bulkColumnType column)`, which can differ from the target
column's storage type. For example, `varchar` values travel as UTF-16
`nvarchar(max)` and the server transcodes them. Use the wire type when
framing those bytes.

## Permissions

An `INSERT` needs INSERT permission on the table. A bulk load needs more,
which matters for an application login with a narrow grant:

* SELECT on the table, for the column discovery that `InsertableColumns`
  and `NamedColumns` do, or `DescribedColumns` in place of the discovery.
* ALTER TABLE, when the table has a check constraint or a trigger and
  either `bulkCheckConstraints` or `bulkFireTriggers` is left off. The
  server refuses the load with error 5304 otherwise. With both options
  set, INSERT is enough.
* ALTER TABLE for `bulkKeepIdentity`.

Measured on SQL Server 2025.

## Speed

Loading a three-column table on a local server:

| Rows | `execute`, one INSERT each | `executeMany` | `bulkInsert` |
|---|---|---|---|
| 100 | 4.4 ms | 0.49 ms | 0.40 ms |
| 1000 | 39 ms | 4.0 ms | 2.1 ms |
| 10000 | — | 41 ms | 18 ms |

## When an `INSERT` is the better tool

Bulk copy is for filling a table. For the ordinary inserts of an
application, `execute` or `executeMany` is usually the right choice, for
reasons that have nothing to do with speed:

* **The generated keys don't come back.** A bulk load has no `OUTPUT`
  clause, so the identity values and defaults the server generated have
  to be queried afterwards.
* **The server checks less.** Constraints are left unchecked and marked
  untrusted and triggers don't fire unless you ask. With both asked for,
  the load behaves as an `INSERT` does, but it needs the permissions above
  on a table that has them.
* **It is one table, whole rows.** There is no `INSERT ... SELECT`, no
  `MERGE`, no expression in a value and no `WHERE NOT EXISTS`.
* **Errors arrive late.** The server answers a bulk load once, at the end
  of a batch, so a duplicate key in the first row surfaces after the whole
  batch has been sent, and a load in several batches is not all or nothing
  without a transaction.
* **Conversions are narrower.** Only values within a type family convert,
  where an `INSERT` converts a string to a number or a number to a string.
* **It is a poor neighbor.** `bulkTableLock` locks the table against
  other writers for the load, a load inside a transaction holds its locks
  until the commit, and on a MARS connection a load beside open streams
  fails or crawls.

For a handful of rows, `executeMany` is nearly as fast and needs one
round trip, where a bulk load with column discovery needs two.

## On a MARS connection

A large load belongs on a connection of its own, because beside busy
streams it runs several times slower. [MARS](../streaming/mars.md) has
the rules.

## Streaming individual cells

Rows can contain `binaryStream` and `textStream` parameters, which
[Streaming values](../decoders-and-encoders/streaming-values.md)
introduces. The first row chooses each batch's wire types; if a later
stream needs a bounded column widened to `max`, the load throws
`EncodeError` naming its row and column.

Streamed cells use the server's `INSERT` conversion rules. Use
`ANSI_WARNINGS ON`, which is the default on a new hmssql connection, to
refuse most overlong values. No setting prevents discarded trailing blanks
or zeros, or `?` replacements during code-page conversion.

Character bulk columns travel as UTF-16, so use `textStream` for them; a
`varchar` byte stream is refused for those columns.
