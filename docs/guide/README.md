# hmssql

hmssql is a native Haskell client for Microsoft SQL Server (2017 and later) and
Azure SQL Database.  It implements SQL Server's wire protocol directly (TDS 7.4 and 8.0),
so no ODBC driver or client library is needed.

## Contents

1. **Getting started**
   1. [A first program](getting-started/first-program.md) — Requirements, and a program that runs a query
   2. [Connecting](getting-started/connecting.md) — Local servers, Azure SQL Database and Microsoft Entra ID
   3. [Pools and threads](getting-started/pools-and-threads.md) — One thread per connection, and a pool recipe
2. **Queries**
   1. [Reading rows](queries/reading-rows.md) — Records, tuples and your own column types
   2. [Parameters](queries/parameters.md) — `param`, `mkQuery` and named parameters
   3. [Composing queries](queries/composing-queries.md) — Queries as values
   4. [Several result sets](queries/result-sets.md) — Reading the results of several `SELECT` statements in one batch
   5. [Stored procedures](queries/stored-procedures.md) — Output parameters and the return status
3. **Writing data**
   1. [Transactions](writing-data/transactions.md) — `withTransaction` and isolation levels
   2. [Many statements in one round trip](writing-data/batches.md) — `executeMany` and `BatchQuery`
   3. [Bulk copy](writing-data/bulk-copy.md) — Inserting many rows efficiently
4. **Streaming**
   1. [Streaming rows](streaming/streaming-rows.md) — Processing rows without collecting the whole result in memory
   2. [MARS](streaming/mars.md) — Several open streams on one connection
5. **Decoders and encoders**
   1. [Decoders](decoders-and-encoders/decoders.md) — Row decoders built by hand, and decoders chosen at runtime
   2. [Encoders](decoders-and-encoders/encoders.md) — How values are declared to the server, and encoders for your own types
   3. [Streaming values](decoders-and-encoders/streaming-values.md) — A single value too large for memory, in either direction
6. **Errors and security**
   1. [Errors and timeouts](errors-and-security/errors-and-timeouts.md) — Handling exceptions and setting timeouts
   2. [Encryption and security](errors-and-security/encryption.md) — Encryption modes, certificates and credentials
7. **Under the hood**
   1. [How it works](under-the-hood/how-it-works.md) — The protocol, in one page

## Where to go next

* [Examples](../../examples/README.md) — Complete programs over a sample database, among them a streaming OData server
* [Developer documentation](../dev/README.md) — Design decisions and implementation notes for contributors
