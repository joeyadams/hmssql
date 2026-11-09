# Findings: Haskell `odbc-0.3.0`

Run date: 2026-10-29. This tests the unmodified FP Complete
[`odbc` release 0.3.0](https://hackage.haskell.org/package/odbc-0.3.0), through
`Database.ODBC.SQLServer`, on the same local SQL Server and Microsoft driver
as the [C experiments](../odbc/RESULTS.md).

**The Haskell middle-layer concern is confirmed in specific ways:** decimals
are converted to `Double`, ordinary Haskell cancellation does not promptly
cancel a running server query, and the API serializes same-connection
operations even with MARS enabled. The tested offset timestamps and Unicode
values retain their data.

The [full run](results/2026-10-29-full.log) has **124 assertions: 103 passed,
21 failed**. Those failures are the requirements under investigation, not
unexpected harness exceptions:

| Unmet requirement | Failures |
|---|---:|
| Exact rational representation of SQL decimals | 8 |
| Decimal read/write preserves the stored value at its original scale | 4 |
| Timeout/kill promptly completes and prevents later server writes, with MARS off/on | 8 |
| A second query can run while a MARS stream is open | 1 |

All 48 Haskell benchmark-validation assertions passed. The separate
[UTC type run](results/2026-10-29-types-utc.log) reproduces the same 12 decimal
failures, with date/time and Unicode checks passing. The contemporaneous
[C benchmark rerun](results/2026-10-29-c-baseline.log) passes 104 assertions.

## Environment and scope

Apple M4 Pro, macOS 15.6.1, GHC 9.10.3, `text-2.1.3`, `async-2.2.6`, `-O2`,
threaded runtime; Microsoft ODBC 18.7.1.1 and unixODBC 2.3.14. SQL Server
reports `17.0.4075.5`, and the database collation is
`SQL_Latin1_General_CP1_CI_AS`. The tests use TCP localhost, SQL authentication,
and strict encryption with the supplied certificate pinned. Dependencies are
frozen in [cabal.project.freeze](cabal.project.freeze).

No upstream source patches were needed. The Cabal project is isolated from
hmssql. This is not a test of other ODBC bindings, older releases, other
drivers, all supported SQL types, or Azure Managed Identity. The main
README's rationale has not been rewritten.

## Decimals: genuine data loss in the Haskell layer

The package requests SQL decimal/numeric results as `SQL_C_DOUBLE` and
constructs `DoubleValue`. It does this before applying the caller's
`FromValue` conversion. A custom Haskell decimal instance cannot recover
digits already lost there. The source locations are recorded in
[SOURCE-AUDIT.md](SOURCE-AUDIT.md).

The tests distinguish two questions:

1. Is the Haskell value exactly the SQL decimal? Eight of ten cases are not.
   Values such as `0.01` are approximations even if displayed as `1.0e-2`.
2. Does a read followed by `toSql` writeback change the value stored at the
   original SQL scale? Four cases demonstrably do:

| SQL type | Original decimal | After Haskell read/write |
|---|---|---|
| `decimal(18,4)` | `12345678901234.5678` | `12345678901234.5680` |
| `decimal(28,10)` | `987654321012345678.1234567890` | `987654321012345700.0000000000` |
| `decimal(38,18)` | `12345678901234567890.123456789012345678` | `12345678901234567000.000000000000000000` |
| `decimal(38,0)` | `12345678901234567890123456789012345678` | `12345678901234567525491324606797053952` |

Small currency examples `1234.56`, `-19.95`, and `0.01` round-trip to their
original SQL scale in this run despite their approximate Haskell
representation. `42.5000` has an exact binary numerical value; the original
scale is not carried by the `Double`, although the known destination column
restores it on writeback. It would be misleading to say every ordinary
currency amount changes merely by being read and written.

The C tests preserved all these decimals using native exact numeric structs.
This is therefore a demonstrated binding choice, not an inability of ODBC
or the Microsoft driver to handle fixed-precision decimals.

**Workaround tested:** select `CONVERT(nvarchar(100), decimal_column)` and
parse the resulting text into an exact decimal representation. All ten text
results preserve magnitude and scale. That changes the SQL/API contract;
ordinary decimal-column retrieval remains approximate. NULL is preserved.

## Datetimeoffset and Unicode: the main fears did not reproduce

All five offset-timestamp fixtures preserve local date/time fields, the
original offset, and seven fractional digits. The checks compare those fields
explicitly: the package's own `Datetimeoffset` equality compares UTC instants
and would not by itself detect loss of the original offset.

The fixtures include `+05:30`, `-03:30`, US offsets around a DST boundary, UTC,
and a 100ns fraction. A separate UTC-process run still preserves the original
fields. `datetime2(7)` precision and a NULL offset timestamp pass too. The
binding retrieves the SQL Server offset structure; it avoids the generic
timestamp conversion that silently changed values in the C experiment.

The multilingual input from C also survives through `toSql Text`, both
`nvarchar(max)` and UTF-8 `varchar(max)` storage, and output:

```text
Renée / Łódź / 東京 / مرحبا / 😀 / café
```

Emoji, combining accents, `O'Brien 😀`, empty text, NULL, and 4,096 repetitions
of the multilingual sample all pass exact comparison. The package uses a
Unicode SQL parameter for `Text`, avoiding the narrow-parameter corruption
seen in the C experiment.

There is an API distinction: `nvarchar` becomes `Text`, while `varchar`
becomes `ByteString`. The UTF-8 bytes are exact. Asking directly for a Haskell
`Text` from `varchar` throws `DataRetrievalError`; it does not decode or corrupt
it silently. Decode the bytes as UTF-8 when that is the known column encoding,
or explicitly cast the SQL column to `nvarchar`. The latter workaround passes.

## Cancellation: a timeout result is not prompt server cancellation

The decisive batch is:

```sql
WAITFOR DELAY '00:00:04';
INSERT INTO #late VALUES (1);
```

`System.Timeout.timeout 250000` surrounds its execution. With MARS both off
and on:

* At one second, a separate connection still sees the server's `WAITFOR`, and
  the caller has not returned.
* `timeout` finally returns `Nothing` after **4.00–4.01 seconds**.
* The insert after the wait **has executed**.

Thus the caller receives a timeout result after the work has effectively
finished. This is not a useful 250 ms query deadline, and it does not prevent
the later side effect.

The `killThread` experiment starts cancellation only after the observer sees
the server wait. The kill call itself returns in microseconds, but joining the
target worker takes **about four seconds**, and the post-wait insert still
executes. Measuring only how fast `killThread` returns would hide this issue.

Source inspection explains the behavior: the package runs operations with
`withAsyncBound`/`wait`, and its C layer has no `SQLCancel` or
`SQLCancelHandle` path. It also exposes no statement-level query-timeout
setter. These APIs worked in the direct C tests, so this is another limitation
of the binding's exposed behavior rather than of ODBC generally.

There are successful cleanup cases:

* After the delayed operation finishes, the connection is reusable and retains
  the same `@@SPID`.
* Returning `Stop` after ten rows of a roughly 100 MB result completes in
  **3.3–4.5 ms**, then reuse succeeds.
* A stream callback exception reaches the caller and leaves the connection
  usable.
* An explicit transaction remains open after timeout (`XACT_STATE() = 1`,
  `@@TRANCOUNT = 1`). Caller rollback undoes its insert and reuse succeeds.

Early stream termination works; prompt interruption of a blocked server call
does not. These are distinct behaviors. Broken networks/dead servers are not
tested.

## MARS: enabled in the driver, serialized by the binding

The connection string accepts `MARS_Connection=Yes`, but the API holds a
per-connection `MVar` throughout a query or streaming operation, including its
callback. A second query cannot acquire the connection while that stream is
open.

The test pauses the first stream in its callback, gives a second query 300 ms
to return, then releases the stream. The second query times out with MARS off
**and on**. After release, all 10,000 original rows are verified and another
query succeeds. The direct C tests interleaved two active result sets on the
same connection successfully.

This API therefore does not expose the overlapping-stream behavior MARS made
possible in C. Removing the lock or adding a statement-oriented API would be
a package change, not a connection-string fix.

## Connections and Managed Identity

The binding connects and queries with strict encryption through both:

* [Exact certificate pinning](results/2026-10-29-tls-pin.log).
* [Ordinary validation with `SSL_CERT_FILE`](results/2026-10-29-tls-ca-file.log).

[Default trust fails](results/2026-10-29-tls-default.log) on the same self-signed
certificate as the C experiment. No additional local connection obstacle was
observed in the Haskell layer. The runner supplies the same process-local
OpenSSL path as C; no system trust/link changes were made.

**Azure SQL Managed Identity remains untested.** The package passes a raw
connection string to the driver, so driver-managed authentication can be
requested there. Source inspection finds no public setter for the pre-connect
access-token attribute, which is a separate limitation if the application
already has a token. Neither observation proves whether a real Managed
Identity deployment connects successfully.

## Performance: measurable per-row cost, similar bulk transfers

Medians of five rounds on the same local server. The C path below uses bound
columns with a rowset of one and UTF-16 output. Both clients read and verify
the mixed-row fixture; Haskell's values are fully consumed before the timer
stops. All per-round results and min/max values are in the
[benchmark summary](results/2026-10-29-benchmark-summary.md).

| Operation | C, MARS off | Haskell, MARS off | C, MARS on | Haskell, MARS on |
|---|---:|---:|---:|---:|
| Mixed rows, streaming/folding | 1.40 M rows/s | 0.41 M rows/s | 0.61 M rows/s | 0.33 M rows/s |
| Mixed rows, Haskell list-returning `query` | — | 0.34 M rows/s | — | 0.29 M rows/s |
| `SELECT 1`, consume result | 314 µs | 417 µs | 332 µs | 340 µs |
| Connect + close | 73.4 ms | 71.1 ms | 73.4 ms | 71.6 ms |
| 4 MiB upload | 141 MiB/s | 146 MiB/s | 53 MiB/s | 56 MiB/s |
| 4 MiB download | 236 MiB/s | 225 MiB/s | 56 MiB/s | 58 MiB/s |

The Haskell stream is roughly 3.4 times slower than this C row-fetch path with
MARS off. That is a real measured difference for the tested API paths, but it
is not an isolated FFI tax: the binding makes different ODBC calls and
allocates/converts Haskell values. C reuses statement handles for the tiny
query test; the Haskell API creates new statements. Server/runtime variation
also affects these separate runs. Bulk-value throughput and connect time are
similar enough here that a blanket "the binding makes everything slow" claim
is not supported.

There is no hmssql comparison in this experiment. Performance claims about
the native library need a separate matched benchmark.

## What this establishes about the original fears

* **Confirmed:** decimal fidelity can be lost in this Haskell binding even
  though direct ODBC preserves it.
* **Confirmed:** the binding does not expose prompt server cancellation
  through ordinary Haskell `timeout`/`killThread`.
* **Confirmed:** enabling MARS does not provide concurrent active streams
  through this API.
* **Not reproduced for the tested cases:** loss of offset timestamp fields
  or Unicode data using the package's intended representations.
* **Measured, with limits:** a substantial mixed-row throughput cost; broadly
  similar large-value transfer performance.
* **Still open:** Azure Managed Identity and broader server compatibility.

These are specific reasons to prefer a different API or implementation for
some applications. They do not justify attributing the binding's limitations
to the ODBC protocol/driver itself.
