# hmssql-example-bulk-copy

Copies a table from one database to another with the TDS bulk load
(`Hmssql.BulkCopy`), after checking in both databases' catalogs that the
target table takes the source table's rows. The databases may be on
different servers: an on-premises SQL Server and Azure SQL Database, say.

```sh
hmssql-example-bulk-copy check copydemo.event copydemo.event_copy
hmssql-example-bulk-copy copy copydemo.event copydemo.event_copy --batch-size 10000 --transaction
```

| Module | What's in it |
|---|---|
| [`src/Copy/Check.hs`](src/Copy/Check.hs) | The catalog check: both tables read with `Hmssql.Catalog.readTable`, the columns paired by name, a verdict per pair |
| [`src/Copy/Run.hs`](src/Copy/Run.hs) | The copy: a `querySWith` stream on the source connection into `bulkInsertSWith` on the target, with the transaction and batch options |
| [`app/Main.hs`](app/Main.hs) | The command line, the `setup-demo` command, and the report of what a failed copy left behind |
| [`sql/`](sql) | The tables `setup-demo` creates: [`demo-source.sql`](sql/demo-source.sql), [`demo-target.sql`](sql/demo-target.sql) |
| [`scenarios.sh`](scenarios.sh) | Every copy scenario run and checked: 34 expected outcomes |

## How it works

**Two connections, one stream.** The source rows are read by `querySWith`
on one connection and pulled, as `bulkInsertSWith` sends them, into a bulk load
on the other: a table of any size is copied a packet at a time. It must be
two connections even for two tables in one database, since the load holds
the target connection while it pulls from the stream.

**Rows passed through undecoded.** Each cell is read as its bytes and the
source column's wire type (a `FieldDecoder RawParam` built from
`Maybe RawValue`), not decoded to a Haskell value. The bulk load sends the
bytes as they are where the target column stores the same thing, and
converts them otherwise, checking each value against the target column.

**A catalog check before any row.** `check` (and `copy`, before it
starts) reads both tables' columns, types, nullability, identity,
computed columns and defaults from the catalogs, and gives each source
column a verdict against the target column of the same name:

| Verdict | Meaning | Examples |
|---|---|---|
| same type | the values go as they are | `int` → `int` |
| fits | a different type that holds every source value | `varchar(20)` → `nvarchar(40)`, `smallint` → `int`, `datetime` → `datetime2(3)`, `decimal(12,2)` → `decimal(18,4)`, `rowversion` → `binary(8)` |
| per row | converted row by row, and a value may be refused or changed, as listed | `nvarchar(100)` → `varchar(40)` (too long, or a character the code page lacks), `datetime2(7)` → `datetime` (before 1753 refused; rounded to 1/300 s), `float` → `int` (out of range refused; fraction truncated), `datetimeoffset` → `datetime2` (offset dropped), `varchar` → `xml` (must be well-formed) |
| refused | no value converts, or none would fit | `varchar` → `int`, `int` → `varchar`, `uniqueidentifier` → `nchar(36)`, `time` → `datetime`, `char(20)` → `varchar(10)` (every value is padded to 20) |

The kinds that convert among themselves are numbers, strings (including
`json`, and `xml` either way), binary, and the date and time types
(`time` only from a time or a date-time); anything but `xml` goes into a
`sql_variant`. The rules are those of `Hmssql.BulkCopy.encodeBulkCell`, the
conversion the load applies to each value, so the check refuses up front
what would fail on the first row, and names what later rows are checked for.

The check also refuses a source column the target lacks (`--skip` it, or
choose columns with `--only`), a target column that is NOT NULL with no
default and no source column, an identity target column (unless
`--keep-identity`), and a computed or `rowversion` target column. It lists
the target columns the copy leaves to their default, identity or NULL.

**Batches and transactions.** What a failure leaves in the target
depends on how the load is split and on the transaction around it. The
scenarios measure it with 50,000 rows, batches of 10,000, and three kinds
of failure: a duplicate key at row 40,000 (the server refuses it), a title
too long for its column at row 40,000 (refused on the client, before the
row is sent), and the source stream failing after 25,000 rows:

| | Duplicate key | Value refused on the client | Source fails |
|---|---|---|---|
| one load, no transaction | none of its rows | none | none |
| `--batch-size 10000` | the 30,000 rows of the batches before | 30,000 | 20,000 |
| `--batch-size 10000 --transaction` | none | none | none |

One bulk load is atomic by itself: a failure anywhere leaves none of its
rows, transaction or not. With `--batch-size` each batch is a bulk load of
its own, committed when it ends, so the batches before a failure stay;
in a transaction (`--transaction`) they are rolled back with the rest.
`--replace` deletes the target's rows first, in the same transaction
(always: a delete that committed without the load would empty the table),
so a failing replace leaves the old rows in place. After every failure the
target connection is still usable; the tool counts the rows left on it.

A duplicate key surfaces only when the batch holding it has been sent:
the server answers a bulk load once, at its end. A value refused on the
client stops the load at that row; the rows of the batch already sent
are discarded with it (the load is cancelled with an Attention).

## Running it

The two connections are configured as the other examples' one is (see
[`examples/README.md`](../README.md)), each `MSSQL_*` variable looked up
with a prefix first: `SOURCE_MSSQL_HOST`, then `MSSQL_HOST`;
`TARGET_MSSQL_DATABASE`, then `MSSQL_DATABASE`. Two databases on one
server differ only in their database:

```sh
export MSSQL_PASSWORD=... MSSQL_TRUST_SERVER_CERT=1
export SOURCE_MSSQL_DATABASE=hmssql_example_copy_a TARGET_MSSQL_DATABASE=hmssql_example_copy_b
stack build
stack exec hmssql-example-bulk-copy -- setup-demo    # creates the databases if needed, and schema copydemo in each
stack exec hmssql-example-bulk-copy -- check copydemo.event copydemo.event_bad
stack exec hmssql-example-bulk-copy -- copy copydemo.event copydemo.event_copy --replace
stack exec hmssql-example-bulk-copy -- sql target "SELECT COUNT(*) FROM copydemo.event_copy"
```

`check` exits with status 2 if it refuses the copy; `copy` does too, before
reading a row, and exits with status 1 if the copy fails. The demo tables:

| Table | Database | |
|---|---|---|
| `copydemo.event` | source | 13 columns of assorted types, `--rows` rows (50,000); one title, at `--long-title-at`, too long for `event_narrow` |
| `copydemo.event_copy` | target | accepted: every column converts, `copied_at` gets its default |
| `copydemo.event_narrow` | target | accepted with `--only id,code,title`, but its `title` is `varchar(40)`: the long title is refused when the load reaches it |
| `copydemo.event_bad` | target | refused: `varchar` → `int`, `smallint` → `varchar`, `uniqueidentifier` → `nchar`, an identity column, a NOT NULL column the source lacks |

[`scenarios.sh`](scenarios.sh) runs all of it and checks each outcome
(`ROWS=1000000` scales it up); with nothing but `MSSQL_*` set it uses
`hmssql_example_copy_a` and `_b` on the one server.

### Between on-premises SQL Server and Azure SQL Database

[`scripts/azure-bulk-copy.sh`](../../scripts/azure-bulk-copy.sh) runs the
scenarios with the source on one server and the target on the other, from
this machine. It uses the Azure SQL database that
[`scripts/azure-sql-test.sh`](../../scripts/azure-sql-test.sh) `setup`
creates for the test suite (the demo's tables go in its schema `copydemo`;
`clean` drops them), and takes the on-premises server from `MSSQL_*`:

```sh
export MSSQL_PASSWORD=... MSSQL_CA_CERT=...          # the on-premises server
scripts/azure-bulk-copy.sh run                       # to-azure, then from-azure
scripts/azure-bulk-copy.sh run within-azure          # both tables in Azure, the rows through this machine
eval "$(scripts/azure-bulk-copy.sh env to-azure)"    # to run hmssql-example-bulk-copy by hand
```

Measured on 2026-09-29 (20,000 rows, a home connection to East US, the
database on the Basic tier): reading from Azure into the local server ran
at about 20,000 rows/s; loading into Azure at 350 to 900 rows/s, the Basic
tier's log rate (`azure-sql-test.sh scale S3` before a run for more). The
outcomes were the same in every direction.
