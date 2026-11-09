# Testing FP Complete's Haskell `odbc` package

This repeats the [direct C ODBC experiments](../odbc/README.md) through the
unmodified Hackage release **`odbc-0.3.0`**, using
`Database.ODBC.SQLServer`. It tests the extra Haskell layer's fidelity and
behavior, not a patched version of the package.

Read [RESULTS.md](RESULTS.md) for the findings. Dated [logs](results/) contain
the evidence, including deliberately unmet fidelity/interruptibility
requirements. A `FAIL` means that requirement was not satisfied; it is not
silently converted into a passing test because we now expect the limitation.

## Reproduce

Use the same SQL Server, Microsoft Driver 18, unixODBC, and environment file as
the C experiments. The runner uses `~/.hmssql-test-env` (override with
`HMSSQL_ENV_FILE`), and the same connection variables as the C runner:
`HMSSQL_TEST_PASSWORD`, `_USER`, `_DATABASE`, `_PORT`, `_CERT`,
`ODBC_TEST_HOST` (default `localhost`), `ODBC_TEST_ENCRYPT` (default `strict`),
and `ODBC_TEST_PIN_CERT` (default `1`). It never prints the connection string.
Only session-local temporary tables are created. The observer in the
cancellation tests needs permission to inspect the other session's requests;
the recorded runs use the supplied `sa` login.

```sh
bash experiments/odbc-haskell/run.sh                 # all tests and benchmarks
bash experiments/odbc-haskell/run.sh --types-only
bash experiments/odbc-haskell/run.sh --tests-only
bash experiments/odbc-haskell/run.sh --bench-only
bash experiments/odbc-haskell/run.sh --connect-only
```

The isolated Cabal project pins GHC 9.10.3, `odbc-0.3.0`, a Hackage index state,
and dependency versions in `cabal.project.freeze`. The executable is built
with `-O2 -threaded`. The repository's main Stack/Cabal projects are unchanged.
On macOS the runner generates an ignored `cabal.project.local` with Homebrew
unixODBC include/library paths for the dependency, and supplies the same
process-local OpenSSL 3 library path as the C runner. No ODBC version of
`sqlcmd` is used or installed. Other platforms have not been run.

The full recorded run exits **1** because it detects real shortcomings.
Individual exceptions are logged and counted, then other sections continue.
Unexpected connection/setup failures terminate the process. Delayed SQL
batches finish in two or four seconds even when Haskell cancellation fails.

```sh
# Repeat the time-zone check independently.
TZ=UTC bash experiments/odbc-haskell/run.sh --types-only

# Strict encryption with ordinary validation through an explicit CA file.
SSL_CERT_FILE=~/sqlserver.crt ODBC_TEST_PIN_CERT=0 \
  bash experiments/odbc-haskell/run.sh --connect-only

# Inspect exactly the source archive Cabal built (download is hash-checked).
bash experiments/odbc-haskell/fetch-upstream.sh
```

Build products, the downloaded upstream source, generated local configuration,
and `results/local-*.log` scratch logs are ignored. Dated result logs, the
freeze file, and source identities are retained.

## Test design

* Date/time fixtures match the C experiment. `Datetimeoffset` input uses
  `toSql`; output uses `ZonedTime`. Comparisons check local date/time fields
  **and offset minutes**, not the package's `Datetimeoffset` equality, which
  only compares UTC instants. Seven fractional digits, half-hour offsets,
  UTC, NULL, and `datetime2` are covered.
* Decimal fixtures also match C. A decimal string is parsed into an exact
  `Integer` numerator and power-of-ten denominator. We separately test exact
  Haskell representation, and whether reading then writing through `toSql`
  changes the value stored at the original SQL precision/scale. Small decimal
  values can fail the first check and pass the second; the report distinguishes
  those outcomes. An explicit SQL cast to `nvarchar` is tested as an exact
  workaround. All expected decimal values use integer arithmetic.
* Unicode goes through the package's `Text` parameters into `nvarchar(max)`
  and UTF-8 `varchar(max)`. The latter comes back as `ByteString`, which is
  checked against the expected UTF-8 bytes. Names, Arabic, Japanese, emoji,
  combining accents, an apostrophe, empty strings, NULL, and a 4,096-times
  repeated string are covered. A requested `Text` result from `varchar` is
  recorded separately as an API mismatch, not treated as byte corruption.
* A 250 ms `System.Timeout.timeout` surrounds a four-second server wait
  followed by a temporary-table insert. An independent connection checks at
  one second whether the server is still waiting. Elapsed time, the timeout
  result, and the presence of the later write distinguish cancellation from
  merely discarding an eventual result. A separate `killThread` test waits
  until the observer sees the server wait, measures both the kill call and
  worker completion, and checks the later write. Both run with MARS off/on.
* Early `stream` `Stop`, a callback exception, subsequent query reuse with
  unchanged `@@SPID`, and caller rollback after a timeout are tested too.
* For MARS, a streaming callback signals that its result is open and waits
  on a gate. A second query has 300 ms to return. Then the gate is released
  and the original stream is fully verified. This distinguishes overlapping
  work from serialized work on one connection without leaving a deadlock.

## Performance comparisons

Five measured rounds follow a warmup, for both MARS settings. The row fixture
matches C: 100,000 rows of bigint, multilingual `nvarchar`, and
`datetimeoffset(7)`. Haskell `query` materializes the list; `stream` folds it.
Both verify the row count, ID sum, text and timestamp values. Five rounds also
measure 200 `SELECT 1` calls, 10 connect/close cycles, and exact 4 MiB binary
uploads/downloads. Connection settings and the local server match the C run.

These are end-to-end **API-path comparisons**, not a controlled estimate of
FFI overhead alone. C uses bound columns and reusable statement handles;
Haskell allocates/converts values and its public API creates statements per
operation. C and Haskell do not perform identical verification instructions.
There is no `hmssql` benchmark, rowset/parameter-array extension to the Haskell
package, prepared numeric-parameter benchmark, or memory-scaling benchmark.
The package renders numeric/date inputs as literals and only binds text and
binary inputs; treating its numeric `toSql` as prepared parameter execution
would be misleading.

The saved C and Haskell benchmarks run separately on the same server, without
running them concurrently. To summarize:

```sh
python3 experiments/odbc-haskell/summarize.py \
  experiments/odbc-haskell/results/2026-10-29-full.log \
  experiments/odbc-haskell/results/2026-10-29-c-baseline.log
```

## Source provenance

The inspected source is the same tarball hash Cabal records in its plan:

```text
odbc-0.3.0.tar.gz SHA256
d2653e222e9485e1a72862146347aeca6276308c31d2b5d771013e7670f6f54e
```

It is available from [Hackage](https://hackage.haskell.org/package/odbc-0.3.0)
and the project is [fpco/odbc](https://github.com/fpco/odbc). The source fetch
script is for inspection; the harness builds the normal Hackage dependency,
not that downloaded working copy. No changes to upstream source were needed.
