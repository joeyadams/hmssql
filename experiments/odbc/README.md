# Direct ODBC experiments

This is a C program that tests the ODBC concerns in the main README, before
involving a Haskell binding. It uses unixODBC and Microsoft's ODBC Driver 18.
It does not invoke or replace `sqlcmd`.

The [results and interpretation](RESULTS.md) distinguish things measured here
from things that still need testing. The [raw logs](results/) preserve the
diagnostics and individual benchmark rounds. Nothing here establishes the
fidelity of a Haskell binding, or Azure SQL Managed Identity support.

## Run

On the Mac used for these experiments, `msodbcsql18` and its `unixodbc`
dependency were already installed through Homebrew. No ODBC command-line tools
are required. Build requirements are a C11 compiler, the driver and unixODBC
headers, and pthreads. Python 3 is only used to summarize results.

```sh
bash experiments/odbc/run.sh                  # correctness and benchmarks
bash experiments/odbc/run.sh --types-only    # date/time, decimal, Unicode
bash experiments/odbc/run.sh --tests-only    # types, cancellation, MARS
bash experiments/odbc/run.sh --bench-only
bash experiments/odbc/run.sh --connect-only
```

The runner sources `~/.hmssql-test-env` (override with `HMSSQL_ENV_FILE`) and
exports its variables to the C process. Do not enable shell tracing when
loading credentials. Passwords and completed connection strings are never
printed by the program or put in its command-line arguments.

| Variable | Default / purpose |
|---|---|
| `HMSSQL_TEST_PASSWORD` | Required, from the environment file |
| `HMSSQL_TEST_USER` | `sa` |
| `HMSSQL_TEST_DATABASE` | `master`; all tables are session-local `#temp` tables |
| `HMSSQL_TEST_PORT` | `1433` |
| `ODBC_TEST_HOST` | `localhost`; deliberately does not inherit a potentially remote `HMSSQL_TEST_HOST` |
| `HMSSQL_TEST_CERT` | Certificate file for strict-mode pinning |
| `ODBC_TEST_ENCRYPT` | `strict` |
| `ODBC_TEST_PIN_CERT` | `1`; adds `ServerCertificate` using the supplied certificate file |
| `ODBC_TEST_OPENSSL_AUTO` | `1`; on Homebrew, adds `openssl@3/lib` to this process's `DYLD_LIBRARY_PATH` |
| `CC` | `cc` |

The supplied login was `sa`. The cancellation test's observer connection reads
another session's `sys.dm_exec_requests`, which needs the appropriate server
performance-state permission for a less privileged login. The benchmark uses
catalog cross joins to generate data; the tested server has enough catalog
rows for the asserted counts.

The runner handles Homebrew paths on macOS and the conventional Microsoft
Driver 18 header path on Linux. Only the recorded macOS configuration has been
run. It compiles with `-O2 -Wall -Wextra -Werror`. Exit codes are 0 for success,
1 for a failed assertion, and 2 for a setup/unexpected ODBC failure. An
unexpected ODBC error stops the process; expected errors are inspected and
then followed by reuse tests. Disconnection removes all temporary tables.

## Connection experiments

Run each in a new process so OpenSSL configuration is loaded afresh:

```sh
# Normal certificate validation through the driver's default trust source.
ODBC_TEST_PIN_CERT=0 ODBC_TEST_ENCRYPT=mandatory \
  bash experiments/odbc/run.sh --connect-only
ODBC_TEST_PIN_CERT=0 ODBC_TEST_ENCRYPT=strict \
  bash experiments/odbc/run.sh --connect-only

# Normal validation with an explicit trusted certificate file.
SSL_CERT_FILE=~/sqlserver.crt ODBC_TEST_PIN_CERT=0 \
  bash experiments/odbc/run.sh --connect-only

# Strict encryption with exact certificate matching (the runner's default).
bash experiments/odbc/run.sh --connect-only
```

`ServerCertificate` is an exact-match pin, not ordinary chain/hostname/expiry
validation. The default full run uses this pin. The `SSL_CERT_FILE` experiment
separately tests ordinary validation. None of the runs use
`TrustServerCertificate=Yes`, alter the system trust store, or relink Homebrew
libraries. To reproduce the original OpenSSL-loading failure on this machine,
unset any inherited `DYLD_LIBRARY_PATH` and set `ODBC_TEST_OPENSSL_AUTO=0`.

## What the code checks

* `datetimeoffset(7)`: native struct parameters, native struct results, metadata,
  and independently matching text results. Cases include US offsets, `+05:30`,
  `-03:30`, a time just before a daylight-saving transition, UTC, NULL, and
  100ns fractional precision. Generic timestamp retrieval is recorded as a
  deliberately lossy alternative. `datetime2(7)` has a native struct round trip.
* `decimal(p,s)`: exact base-256 integer magnitudes in `SQL_NUMERIC_STRUCT`,
  with explicit input/output descriptors. Currency, negatives, zero, trailing
  zeros, six fractional digits, precision 28 and 38, and NULL are covered.
  Both `SQLGetData` and `SQLBindCol` are tested. Text results independently
  check the stored value and scale. No decimal test passes through floating
  point. A separate test records the warning from omitting output scale.
* Unicode: UTF-8 and UTF-16 inputs declared as `SQL_WVARCHAR`, stored in both
  `nvarchar` and UTF-8-collated `varchar`, then retrieved in both encodings.
  Names, Arabic, Japanese, an emoji, and a combining accent are compared
  exactly, without relying on collation equality. Long Unicode parameters
  and chunked retrieval test both `max` column types in both encodings.
  NULL and empty strings are distinct. The narrow `SQL_VARCHAR` parameter
  experiment records whether the database's default collation loses input.
* MARS: two 10,000-row results are interleaved and verified on one connection.
  The same attempt without MARS must fail. A separate test times out a second
  statement and then verifies the first result's remaining rows.
* Cancellation, with MARS off and on: a one-second query timeout interrupts a
  ten-second `WAITFOR`; another thread cancels an independently observed
  running request three times; timeout is also tested in `SQLMoreResults`.
  The latter query flushes the first result with `RAISERROR ... WITH NOWAIT`
  so the delay occurs after that result is available. A partly read large
  result is abandoned with `SQLFreeStmt(SQL_CLOSE)`. Every case checks reuse
  of the statement and the original server session. Explicit transactions
  are tested through timeout and caller rollback.

The cancellation tests use a responsive server and connection. They do not
test a broken network, dead server, automatic retries, or async Haskell
exceptions. A successful cancel call alone is not counted as cancellation:
the query must return `HY008`, and the observer must no longer see its wait.

## Performance methodology

The timer is `CLOCK_MONOTONIC`. All reported numbers include the driver,
network, and server; they do not isolate ODBC overhead. Connection pooling is
explicitly disabled. Both MARS settings use the same queries and encryption.

* Fetch 100,000 rows with a bigint, multilingual text, and `datetimeoffset`.
  Compare `SQLBindCol` with rowsets of 1 and 256 and UTF-8/UTF-16 output.
  Check every text value and key date/time fields, count rows, and sum IDs.
  There is one warmup for each configuration, then five measured rounds,
  reversing configuration order on alternate rounds. Temporary-table setup
  and buffer allocation are outside the timer; value verification is inside.
* Each of five rounds runs 200 `SELECT 1` queries and 200 prepared parameter
  queries. Both retrieve and check results. Preparation and a prepared-query
  warmup are outside the timer. Each round also times 10 connect/close cycles.
* Upload and download a 4 MiB binary value, with one warmup and five rounds.
  Downloads copy 64 KiB chunks into a buffer; byte comparison is outside the
  timed transfer. Upload preparation and buffer initialization are excluded.
* Insert 1,000 integers with one prepared execution per row versus a parameter
  array. Both use one explicit transaction and include commit time. There is
  one warmup and five rounds; row counts, sums, and array status are checked.
  This is a parameter-array test, not a bulk-copy API benchmark.

The process peak RSS is reported once. That number includes driver loading,
allocated buffers, and all earlier tests; it is not a memory-scaling result.
No Haskell or alternative client is benchmarked, so these results cannot rank
ODBC against hmssql. The results are a local baseline for a later matched test.

```sh
bash experiments/odbc/run.sh > experiments/odbc/results/local-run.log 2>&1
python3 experiments/odbc/summarize.py experiments/odbc/results/local-run.log
```

New `local-*.log` files and the executable are ignored. The dated evidence logs
are intentionally kept in Git. To check the process-time-zone effect on the
generic timestamp conversion, run `TZ=UTC bash experiments/odbc/run.sh
--types-only` and compare the `OBS datetimeoffset` lines.

## API references

* [Microsoft programming guidelines](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/programming-guidelines):
  `SQLWCHAR` is UTF-16, and narrow parameter conversion depends on collation.
* [Connection attributes](https://learn.microsoft.com/en-us/sql/connect/odbc/dsn-connection-string-attribute):
  MARS and strict-mode certificate pinning.
* [SQLGetData](https://learn.microsoft.com/en-us/sql/odbc/reference/syntax/sqlgetdata-function):
  numeric scale defaults, descriptors, and chunked retrieval.
* [SQLCancel](https://learn.microsoft.com/en-us/sql/odbc/reference/syntax/sqlcancel-function):
  cross-thread cancellation and the distinction between accepting a cancel
  request and actually interrupting execution.
