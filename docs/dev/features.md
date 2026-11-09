# What hmssql does differently

The README lists hmssql's distinguishing features in a line each.  This
document says what each one means in practice and why it is there.  The
full behaviour contract is in [design.md](design.md).

## Native

hmssql implements the TDS protocol itself, in Haskell, over a socket.
There is no ODBC driver manager, no Microsoft driver package and no foreign
library: `cabal build` produces an executable that talks to SQL Server, and
the same executable behaves the same on every machine.  With ODBC, whether
`datetimeoffset` arrives as a date, a time and an offset, or a UTF-8
`varchar` column survives, depends on which driver is installed where the
program runs.  Here the whole path from the wire to your record is in this
package.

On Windows the same goes for the local transports.  `connectProtocol`
reaches a server over TCP, Shared Memory or Named Pipes, which is how a
local SQL Server with TCP/IP disabled is reached, and hmssql implements
the pipes itself on Win32 overlapped I/O.  It runs with or without
`-threaded`, and under GHC's native I/O manager when network 3.3 or later
is built with it ([windows-research.md](windows-research.md)).

## Azure SQL Database

Azure SQL supports TDS 8.0, "strict" encryption: a TLS handshake on the raw
socket, with ALPN `tds/8.0`, before a single TDS byte. hmssql implements that
(`EncryptStrict`) alongside TDS 7.4, which also works with Azure SQL. Its TLS
handshake is wrapped in TDS packets (`EncryptOn`, `EncryptOff`,
`EncryptNotSup`).  Certificates are validated against the system store by
default; `TlsSettings` adds CA files or in-memory certificates, overrides
the host name to validate against, or trusts the server certificate
outright, and unlike most drivers hmssql allows that last option with
strict encryption too, for a test server with a self-signed certificate.
[the guide's page on encryption and security](../guide/errors-and-security/encryption.md) has the modes, the validation rules and what an
attacker can do in each.

Azure routes logins using the server name in LOGIN7. hmssql fills it from
`connectHost`; `connectServerName` is an override for tunnels or aliases.
From inside Azure through its public endpoint, the default connection
policy redirects the login to the node hosting the database, and `connect`
follows the redirect (up to ten in a row, as SqlClient does).
The test suite has run against Azure SQL Database from a container in the
same region; [azure-sql.md](azure-sql.md) records what Azure does
differently.

Entra ID logins take an access token (`connectAccessToken`) in place of the
user and password: TDS federated authentication with the token in the login
packet, which is what SqlClient's `AccessToken`, JDBC's `accessToken` and
ODBC's `SQL_COPT_SS_ACCESS_TOKEN` do.  The token comes from wherever the
application runs: Azure Managed Identity's local endpoint (one HTTP
request; [examples/managed-identity](../../examples/managed-identity) makes
it), a service principal's credentials, `az account get-access-token`.
hmssql adds no HTTP client or OAuth library for it, and the token is never
parsed, shown or kept: `Login7`'s `Show` redacts it as it does the
password.

## SQL Server's types, faithfully

TDS 7.3 and later send `date`, `time`, `datetime2` and `datetimeoffset` in
binary; TDS 7.1 clients get them as strings, or not at all.  hmssql decodes
them from the binary encodings, and `datetimeoffset` becomes a
`DateTimeOffset` that keeps both the instant and the UTC offset it was
recorded with, convertible to and from `ZonedTime`.  `decimal` and
`numeric` decode to `Decimal` with the column's scale; `money` keeps its
four decimal places; `varchar`, `char` and `text` are decoded by the
collation's code page, including the UTF-8 collations SQL Server 2019
introduced; `varchar(max)`, `nvarchar(max)` and `varbinary(max)` values
of any size arrive whole, or as a stream (below); `sql_variant` decodes into `SqlValue` with its
base type.  Date and time parameters round the way the server rounds, and
a value the server would reject is an `EncodeError` before anything is
sent.  The Haddock of `Hmssql.Types` has the table: which SQL types each
Haskell type decodes from, and what each is sent as.

## Streaming results and values

`queryS` returns a `Stream (Of row) IO ()` from the
[streaming](https://hackage.haskell.org/package/streaming) package.  Rows
are decoded from packets as the consumer pulls them, so a result of ten
million rows runs in memory that does not grow with the result.

A single value can stream too, in both directions.  `streamField` and
`streamTextField` give a column's value to the application's function as
its packets arrive, so a gigabyte `varbinary(max)` can go to a file
without being held, and they compose with the other columns' decoders.
`binaryStream` and `textStream` send a parameter from a `Source` as the
request is written, and a lazy `ByteString` or `Text` parameter is read
as it is sent.  The Haddock of `Hmssql.Decoding` and `Hmssql.Encoding`
has the rules; [value-streaming-research.md](value-streaming-research.md)
how the decoder and encoder pipeline was rebuilt for it.  `query` is `queryS` collected into a list,
and `queryFold` folds without building one.  The rule that comes with
streaming: consume the stream before the connection's next request.  If you
don't, the next request cancels the statement with an Attention and drains
what was left, and the abandoned stream throws `ResultAbandoned`.  A
connection going back to a pool gets the same from `release`, so the
statement doesn't sit on the server with its locks while the connection
idles.  A MARS connection, below, lifts the rule.

## Several open results on one connection (MARS)

With `connectMars = True` a connection can have several responses open at
once, what SqlClient calls `MultipleActiveResultSets`: a request made while
a stream is being read leaves the stream open, so one query's rows can
drive a query per row without being held in memory first.  hmssql
negotiates MARS at login and carries each request on a session of the
Session Multiplex Protocol, but the API has no session or channel type:
each request takes a session and gives it back when its response has
been read, and the caller sees only that requests stop abandoning
streams.  `withQueryS` scopes a stream: when its action ends the stream
is cancelled, and an ordinary exit returns once the statement is over on
the server and its locks are released (an interruption returns at once,
and the next request finishes the cancel); `cancelResponse` cancels one
response and `cancelActiveStatement` all of them.  A connection that doesn't ask for
MARS uses plain TDS, with no SMP framing; a transaction begins with a
Transaction Manager request on every connection, the only begin SQL
Server accepts under MARS, which behaves the same on a plain connection.

The transaction, like every `SET` option and `#temp` table, belongs to
the connection, so the streams opened inside `withTransaction` share it
(and, at `Snapshot` isolation, one snapshot).  SQL Server refuses to begin
or commit a transaction while another request is unfinished, and loses
the transaction when it refuses a commit; hmssql checks what the caller
has read before either and throws `TransactionRequestsActive`, naming the
unfinished statements.  It never cancels a stream to make a commit go
through, and after a failure it cancels every open response before the
rollback.

MARS buys interleaving, not speed.  The server runs one request of the
connection at a time and switches where a statement sends rows, so a lock
wait or a `WAITFOR` on one session stops them all.  Against a local
server (the `Mars` benchmark group, [testing.md](testing.md#benchmarks)),
a round trip and a stream cost 1 to 2% more than on a plain connection,
a 4 MB parameter about 20% more (the server takes four packets at a
time), and four 50,000-row streams read in turn took as long as the four
read one after another.  Four plain connections read by four threads are
about twice as fast as four streams on one MARS connection
([mars-research.md](mars-research.md#spike-1-smp-session-multiplexing)).  The behaviour contract is in
[design.md](design.md#mars-several-responses-on-one-connection), the
rules for using it in the [guide](../guide/streaming/mars.md).

## A query is one value

`Query` is SQL text together with the parameters it refers to, and a
`Monoid`.  `"WHERE id = " <> param x` is a query; `mconcat` over a list of
optional conditions is a query; the placeholders are renumbered as pieces
are joined, so SQL assembled at runtime is as safe as a literal.  The
`sp_executesql` style is there too: `mkQuery` takes text with `@p1`, `@p2`,
... or `@name`, and a tuple, a record with a derived `ToSqlRow`, a list of
`SqlParam`, or `NamedParams`.  A string literal is a query with no
parameters, sent as a plain batch.

The alternative, a template plus a separate tuple, splits one idea into
two values that have to travel together, and makes composing a query from
parts awkward.  Keeping the two in one value also leaves room for a
quasi-quoter as a separate package: hpgsql's `[sql| ... |]` needs a Haskell
parser at compile time, which is more than a protocol library should carry.

## Rows decode into your types

`FromSqlRow` derives generically for a record, and tuples up to twelve
columns have instances.  `Maybe a` is a single instance that makes any
field nullable.  A `RowDecoder` is an `Applicative` of `FieldDecoder`s, and
it is compiled against the result set's column metadata once, before the
first row: a column count or type that doesn't match is a `DecodeError`
naming the column and both types, and no decoder ever calls `error`.
`refineField` layers a fallible conversion over an existing decoder, for an
enum or a JSON column; `RowDecoderMonadic` decodes shapes only known at runtime;
`SqlRow` and `SqlValue` decode any result set at all, for code that handles
tables generically.  This design is hpgsql's.

## Several statements in one round trip

TDS sends one request at a time and answers it with one response (MARS
keeps several responses open, but the server still runs one request of
the connection at a time), so there is no pipelining in the libpq sense,
but a request may carry several statements.  `executeStatements` sends a
list of statements and returns each one's row count; `executeMany` sends
one statement text for a list of
parameter rows, compiled once by the server.  A `BatchQuery` pairs each
statement with what to do with its results, in an `Applicative`:

```haskell
(updated, Only total, items) <- runBatchQuery conn $ (,,)
  <$> batchExecute ("UPDATE dbo.item SET price = price * 1.1 WHERE category = " <> param cat)
  <*> batchQuery1 ("SELECT SUM(price) FROM dbo.item WHERE category = " <> param cat)
  <*> batchQuery ("SELECT id, name FROM dbo.item WHERE category = " <> param cat)
```

Each statement is its own `sp_executesql` call in one RPC message, so its
results are delimited from its neighbours' however many result sets each
has, and a consumer never sees another statement's rows.  It is the
counterpart of hpgsql's `Hpgsql.Pipeline`, named for what TDS has and does:
a batch, not a pipeline.  SQL Server runs the statements in order and
commits each as it completes, and statements after a failed one may still
run, so the batch goes inside `withTransaction` when it must be all or
nothing.  The `Hmssql.BatchQuery` documentation compares the two designs.

## Bulk copy

`bulkInsert` loads many rows into a table with the protocol's bulk load,
what `bcp` and .NET's `SqlBulkCopy` use: the rows go as a stream of binary
values in each column's own wire type, with no statement to compile and no
parameters to bind.  The columns are discovered from the table, each value
is converted to its column's type on the client, and the rows are produced
and sent a packet at a time, so `bulkInsertS` over a `Stream` needs only a
packet's memory whatever the source.  `bulkInsertWith` takes the settings:
which columns, keep the identity value, `TABLOCK`, fire triggers, check
constraints, a batch size.  A value the column can't take is refused on
the client, where a plain `INSERT` would silently truncate or transcode it.

On a local server, loading a three-column table (`+RTS -N1`):

| Rows | `execute` one INSERT each | `executeMany` | `bulkInsert` |
|---|---|---|---|
| 100 | 4.4 ms | 0.49 ms | 0.40 ms |
| 1000 | 39 ms | 4.0 ms | 2.1 ms |
| 10000 | — | 41 ms | 18 ms |

So bulk copy is about twice as fast as `executeMany` (itself far faster
than a statement per row) and copies a fraction of the bytes: a 1000-row
load moved 3.5 KB between buffers against `executeMany`'s 55 KB.
[limitations.md](limitations.md) lists what it converts and the cases it
leaves to a plain `INSERT`.

## Interruption is cancellation

Nothing in hmssql takes a timeout argument, because it doesn't need one.
Interrupting a call with an asynchronous exception, from
`System.Timeout.timeout`, `killThread` or `async`'s `cancel`, sends an
Attention to the server at once.  SQL Server cancels the statement (a
timed-out `UPDATE` doesn't go on to commit) and acknowledges, and the
connection's next request reads that acknowledgement before it is sent;
`cancelActiveStatement` reads it now, for a caller that needs the
statement's locks gone before the next request.  That is how Haskell does
timeouts, and it is idiomatic here rather than a gap.
On a MARS connection the Attention goes to the interrupted response
alone, and the other open streams read on.  The exact rules, including
the one case where an interruption breaks the connection instead, are in
[design.md](design.md#interruption-and-cancellation).

## The schema, as data

`Hmssql.Catalog` reads a database's user tables and views with their
columns, declared types, primary keys, unique constraints and foreign keys,
in one request against the catalog views.  `Hmssql.SqlType` names every
SQL Server data type as T-SQL spells it, with its arguments
(`nvarchar(50)`, `decimal(10,2)`), as a closed type a `case` can be total
over, and converts between that view and the wire's `TypeInfo`.  Together
they are the vocabulary for code that handles SQL generically: checking
that a database has the columns an application expects, generating record
types from tables, or serving any table over HTTP, which is what the OData
example does.  Neither is re-exported from `Hmssql`.

## Fast, small, and tested hard

Rows are decoded from the packet buffer by a decoder compiled once per
result set, a large value is copied once or streamed, and requests are
written straight into packets.  hmssql also watches what it costs an
application in object code: a derived record's decoder is about a hundred
bytes per field, compiled once in the library rather than inlined at each
use.  The benchmark suite is under `hmssql-bench/`;
[design.md](design.md#memory-and-performance) has the rules an
optimization follows and the RTS options that matter for a database
client, and [performance-research.md](performance-research.md) the
measurements.  Comparisons with SQL Server clients in other languages are
on the [backlog](backlog.md).

The test suite is about 6000 examples: round-trip properties for every
serializer, fuzzing against a mock server, random-schema differential
tests against a live server, concurrency and cancellation fuzzing,
model-based state-machine tests, mutation testing, and soak tests.  It
runs on Linux, macOS and Windows, against SQL Server 2017 to 2025 and
Azure SQL Database, across GHC 9.6 to 9.14 and several connection
configurations.  [testing.md](testing.md) describes the methods and
[bugs-found.md](bugs-found.md) what they found.
