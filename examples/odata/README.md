# hmssql-example-odata

A read-only OData service over the example shop database
([`examples/shop-db`](../shop-db)) that streams every response, `$expand`
included. It builds each request's query and row decoder at runtime from
the database's schema, streams the rows from SQL Server into the HTTP
response, and answers `$expand` by reading a parent table and its child
tables as one stream each on one MARS connection, zipped into one nested
document.

| Module | What's in it |
|---|---|
| [`app/OData/Model.hs`](app/OData/Model.hs) | The entity sets, read from the catalog with `Hmssql.Catalog`: tables, columns with a type the service serves, and a collection property per foreign key |
| [`app/OData/Query.hs`](app/OData/Query.hs) | The query options, and the statement per level of the `$expand` tree, composed as a `Query` |
| [`app/OData/Decode.hs`](app/OData/Decode.hs) | The row decoder per statement, built from the model's column types, straight to JSON |
| [`app/OData/Expand.hs`](app/OData/Expand.hs) | The streams of a request zipped together, and the nested JSON written as they are read |
| [`app/OData/Server.hs`](app/OData/Server.hs) | Routes, errors, the connection pool, and the streaming response |
| [`app/Main.hs`](app/Main.hs) | The pool of MARS connections, the model, and warp |

## Running it

A SQL Server with the shop database, created and seeded by
`hmssql-example-setup`. The connection settings are the other examples'
(see [`examples/README.md`](../README.md)).

```sh
export MSSQL_PASSWORD=... MSSQL_TRUST_SERVER_CERT=1
stack build
stack exec hmssql-example-setup
stack exec hmssql-example-odata
```

```
customer (6 properties, key id, expands sales_order)
order_line (6 properties, key order_id, line_no)
product (8 properties, key id, expands order_line)
sales_order (5 properties, key id, expands order_line)
$expand requests run in snapshot transactions
listening on http://localhost:8080/
```

`ODATA_PORT` sets the port (8080 by default), and `ODATA_LOG_SQL=1` logs
each statement's SQL to stderr, which is the quickest way to see what a
request compiles to.

## Routes

| Route | |
|---|---|
| `GET /` | the service document: the name and URL of every entity set |
| `GET /<set>` | the rows of a table or view, as `{"@odata.context":"$metadata#<set>","value":[...]}` |

An entity set is a table or view of `dbo`, under its own name, and a
property is a column, under its own name. The server lists the sets it
serves at startup. An unknown set is a 404, a request with a mistake in
it is a 400 with a message, and a method other than GET is a 405; errors
are `{"error":{"code":"...","message":"..."}}`.

## Query options

A `GET /<set>` request takes these options, in any combination.

**`$select`** names the properties to return, separated by commas. They
come back in the table's column order whatever order they are named in.
Without `$select`, every property is returned.

```
$select=id,name
```

**`$orderby`** sorts by one or more properties, each `asc` (the default) or
`desc`. The set's key columns are added as the last sort keys, so the
order is total and paging with `$skip` neither repeats nor loses a row.

```
$orderby=name
$orderby=price_amount desc,id
```

**`$top`** returns at most that many rows, and **`$skip`** passes over that
many first; together they page through the set. `$top` takes an integer
of 1 or more, and `$skip` one of 0 or more.

```
$top=3
$skip=6&$top=3
```

**`$expand`** nests, in each row, the rows of another set that reference
it. A set has one such *collection property* per foreign key that
references its primary key, named after the referencing table:
`customer` has `sales_order`, and `sales_order` and `product` have
`order_line`. The other direction, from a `sales_order` to its one
`customer`, is not a collection property and cannot be expanded. Several
properties are separated by commas.

```
$expand=sales_order
$expand=sales_order,other_property
```

A collection property can take options of its own in parentheses,
separated by semicolons: `$select`, `$orderby` and a further `$expand`,
to any depth, but not `$top` or `$skip`. The nested rows come in their
own `$orderby` order, or in key order.

```
$expand=sales_order($select=id,status)
$expand=sales_order($select=id,status;$orderby=placed_at desc)
$expand=sales_order($expand=order_line($select=line_no,quantity))
```

Values are JSON numbers for the integer, decimal and floating-point
types, `true` or `false` for `bit`, strings for the character types and
`uniqueidentifier`, and strings in ISO 8601 form for dates and times:
`"2026-01-05"` for a `date`, `"2026-01-05T09:15:00"` for a `datetime2`,
`"2026-02-20T09:05:00-05:00"` for a `datetimeoffset`, with its offset
kept, and `"10:30:00"` for a `time`. A NULL is `null`.

## Examples

```
$ curl -s 'http://localhost:8080/customer?$select=id,name&$expand=sales_order($select=id,status)&$top=2'
{"@odata.context":"$metadata#customer","value":[{"id":1,"name":"Ada Lovelace","sales_order":[{"id":1,"status":"shipped"},{"id":2,"status":"shipped"},{"id":9,"status":"pending"}]},{"id":2,"name":"Grace Hopper","sales_order":[{"id":3,"status":"shipped"},{"id":6,"status":"pending"}]}]}

$ curl -s 'http://localhost:8080/customer?$select=id,name&$expand=sales_order($select=id,status;$orderby=placed_at%20desc;$expand=order_line($select=line_no,quantity))&$top=1&$skip=1'
{"@odata.context":"$metadata#customer","value":[{"id":2,"name":"Grace Hopper","sales_order":[{"id":6,"status":"pending","order_line":[{"line_no":1,"quantity":2},{"line_no":2,"quantity":1}]},{"id":3,"status":"shipped","order_line":[{"line_no":1,"quantity":1}]}]}]}

$ curl -s 'http://localhost:8080/product?$select=id,name&$orderby=price_amount%20desc&$top=3'
{"@odata.context":"$metadata#product","value":[{"id":6,"name":"Standing desk"},{"id":7,"name":"Office chair"},{"id":3,"name":"27\" monitor"}]}

$ curl -s 'http://localhost:8080/sales_order?$expand=customer'
{"error":{"code":"BadRequest","message":"customer is not a collection property of sales_order"}}
```

With `ODATA_LOG_SQL=1`, the first request above is these two statements:

```
SELECT t.[id], t.[name], ROW_NUMBER() OVER (ORDER BY t.[id] ASC) AS [__rn]
FROM [customer] AS t
ORDER BY t.[id] ASC OFFSET @skip ROWS FETCH NEXT @top ROWS ONLY

SELECT p.[__rn], t.[id], t.[status], ROW_NUMBER() OVER (ORDER BY p.[__rn], t.[id] ASC) AS [__rn]
FROM (SELECT t.[id] AS [__k1], ROW_NUMBER() OVER (ORDER BY t.[id] ASC) AS [__rn]
      FROM [customer] AS t
      ORDER BY t.[id] ASC OFFSET @skip ROWS FETCH NEXT @top ROWS ONLY) AS p
JOIN [sales_order] AS t ON t.[customer_id] = p.[__k1]
ORDER BY p.[__rn], t.[id] ASC
```

## How a request runs

**The model.** At startup, `Model.hs` reads every table and view in `dbo`
through `Hmssql.Catalog`, keeps the columns whose SQL type it can serve,
and turns each foreign key into a collection property of the referenced
table. Nothing about the shop is hard-coded; point it at another database
and it serves that.

**The statements.** A request is a tree: the requested set at the root,
and a level under it for each collection property that `$expand` names.
`Query.hs` compiles each level to one statement. The root numbers its rows
with `ROW_NUMBER()` in the order it returns them. A child level's
statement joins the child table to the parent's *key relation*, the
parent's statement reduced to its key columns and row numbers, so every
child row carries its parent's number and comes sorted by it. The SQL is
a `Query` composed with `<>` from pieces that carry their parameters:
names from the request are matched against the model and emitted as the
model's names with `escapeIdentifier`, and `$top` and `$skip` are
`namedParam`s.

**The decoder.** The columns a statement returns are only known when the
request arrives, so `Decode.hs` builds the `RowDecoder` per statement: a
typed `FieldDecoder` per column, chosen from the model's column type and
mapped to its JSON, combined with the `RowDecoder` applicative. A value
goes from the TDS packet to a Haskell value to JSON bytes, and no row is
ever a list of dynamic values. hmssql checks the decoder against the
result set's metadata before the first row, so a table that no longer
matches the model fails the request before anything is sent.

**The streams.** `Server.hs` borrows a MARS connection from the pool,
begins a snapshot transaction, and opens the root's stream with
`querySWith`. It reads the first row before the headers go out, which is
when a refused statement or a rejected decoder would surface, and then
opens a stream per child level on the same connection. A plain
connection has one response open at a time, and the second statement
would have abandoned the first; a MARS connection keeps them all open.

**The zip.** `Expand.hs` walks the streams together. Each child stream is
held at one row of lookahead. For each parent row, the rows at the front
of the child stream whose parent number is the parent's are that parent's
collection, and they are written as they are read, with their own
children nested the same way. A parent's children are never collected in
a list, so a parent with a million children costs the same memory as one
with none. The body is one builder over a stream of builders, and warp
writes it a buffer at a time.

**The snapshot.** The statements of one request start at different times
and run while the response is written. In a snapshot transaction they
all read the database as it was at the first statement, however much
other connections commit meanwhile. The transaction commits after the
body, by which time every stream has been read to its end. This needs
`ALLOW_SNAPSHOT_ISOLATION` on the database; `hmssql-example-setup` turns
it on, and the server says at startup whether it has it.

**A client that hangs up.** warp's write throws, the rest of every stream
is abandoned, and `withTransactionLevel` cancels the open statements and
rolls back. The connection then goes back to the pool through `release`,
which keeps a connection that is still usable, instead of resource-pool's
`withResource`, which would destroy it and pay for a new login. The
response is cut off without its final chunk, so the client sees an
incomplete body rather than a complete one with wrong data.

Measured on 2026-11-08 against SQL Server 2025 in Docker, with `+RTS -s`:
a parent with 1,000,000 children (a 29 MB response), 200,000 parents with
1,600,000 children (54 MB), and a plain stream of 1,600,000 rows (67 MB)
each ran in about 5 to 6 MB of maximum residency.
