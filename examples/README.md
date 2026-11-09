# hmssql examples

Complete programs over one example database, a shop with customers,
products, orders and order lines. Each is a package of its own, built by
`stack build` (or `cabal build all`) from the repository root.

| Package | What's in it |
|---|---|
| [shop-db](shop-db) | The database the examples share: [schema.sql](shop-db/sql/schema.sql) (four tables and the `dbo.place_order` procedure), [seed.sql](shop-db/sql/seed.sql), and `ShopDb`, which reads the connection settings from `MSSQL_*` environment variables. `hmssql-example-setup` creates and seeds the database. |
| [crud](crud) | A command-line CRUD application: `FromSqlRow` and `ToSqlRow` instances derived generically and written by hand, parameterized queries composed at runtime, a stored procedure call with an output parameter, one batch decoded result set by result set, several statements in one round trip, transactions, and an `export` that reads three tables side by side on one MARS connection and zips them into one document per customer. |
| [odata](odata) | A streaming OData service: the tables' schema is read at startup, each request composes its SQL and its row decoder from that schema, and rows go from the socket to the HTTP response as JSON without ever being held as a list. `$expand` zips a parent query with a query per child collection over one MARS connection, in one snapshot transaction, so a parent with a million children costs no more memory than one with none. |
| [bulk-copy](bulk-copy) | A table copied between two databases (on one server, or on-premises and Azure SQL) with the TDS bulk load: a catalog check that the target accepts the source's rows, rows streamed undecoded from one connection into `bulkInsertSWith` on another, and what batches and transactions leave behind when a copy fails. |
| [managed-identity](managed-identity) | An Entra ID login to Azure SQL with no password: an access token from the managed identity endpoint of the Azure host the program runs on, passed as `connectAccessToken`. `scripts/azure-managed-identity.sh` builds and runs it in Azure Container Instances. |

## Running

The examples read these environment variables (documented in
[ShopDb.hs](shop-db/src/ShopDb.hs)):

| Variable | Default |
|---|---|
| `MSSQL_HOST` | `localhost` |
| `MSSQL_PORT` | `1433` |
| `MSSQL_USER` | `sa` |
| `MSSQL_PASSWORD` | none, required unless `MSSQL_ACCESS_TOKEN` is set |
| `MSSQL_ACCESS_TOKEN` | unset; an Entra ID access token in place of the user and password |
| `MSSQL_DATABASE` | `hmssql_example` |
| `MSSQL_ENCRYPT` | `on` (TDS 7.4); `off` for login-only encryption or `strict` for TDS 8.0 |
| `MSSQL_SERVER_NAME` | empty; optional override for the login server name, which otherwise uses `MSSQL_HOST` |
| `MSSQL_CA_CERT` | unset; a PEM file to trust in addition to the system store |
| `MSSQL_TRUST_SERVER_CERT` | unset; `1` skips certificate validation (development only) |

bulk-copy has two connections, and looks each variable up with the prefix
`SOURCE_` or `TARGET_` first (`TARGET_MSSQL_DATABASE`, then
`MSSQL_DATABASE`); see [its README](bulk-copy/README.md).

```sh
export MSSQL_PASSWORD=... MSSQL_TRUST_SERVER_CERT=1   # SQL Server on localhost
stack build
stack exec hmssql-example-setup                        # creates hmssql_example, runs schema.sql and seed.sql
stack exec hmssql-example-crud -- customers
```

These commands use TDS 7.4 and skip certificate validation for localhost;
you do not need to install a certificate. For Azure SQL, set `MSSQL_HOST`
to your server's full hostname and unset `MSSQL_TRUST_SERVER_CERT` to
validate its certificate. The default `MSSQL_ENCRYPT=on` works with Azure
SQL; set it to `strict` to use TDS 8.0.

`hmssql-example-setup` can be run again at any time: the schema script drops
and recreates every object, so it resets the data too. It takes no
arguments and refuses any, so name the executable when you use `stack run`
(`stack run hmssql-example-crud -- customers`): without a name, Stack runs
whichever executable sorts first.

Every example links with `-threaded`, and a program of your own should
too. On Windows hmssql needs the threaded runtime, and without it
`connect` fails with an error that says so.
