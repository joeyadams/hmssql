# ODBC findings: local SQL Server, direct C

Run date: 2026-10-29. The [full run](results/2026-10-29-full.log) completed
**244 assertions with zero failures**: 140 correctness assertions and 104
benchmark-validation assertions, including repetitions. A separate
[UTC type run](results/2026-10-29-types-utc.log) passed 75 assertions.

The broad fear that ODBC cannot faithfully represent these SQL Server types
was not borne out. The narrower fear that a conversion layer can quietly lose
information was borne out: the C type, SQL parameter type, and descriptor
settings matter. This is evidence about Microsoft's driver through unixODBC;
it says nothing yet about which choices a particular Haskell binding makes.

## Environment

* Apple M4 Pro, 48 GiB RAM, macOS 15.6.1, arm64.
* Apple Clang 17.0.0, C11, `-O2`; unixODBC Homebrew package 2.3.14.
* Microsoft ODBC package 18.7.1.1; driver reports `18.07.0001`.
* SQL Server 2025, build `17.00.4075`, Enterprise Developer Edition, TCP on
  localhost. Database: `master`, collation `SQL_Latin1_General_CP1_CI_AS`.
* Strict encryption with the supplied certificate pinned. The connection
  reports encryption enabled. Connection pooling is explicitly disabled.
* Process locale `C`, which this driver treats as UTF-8 for narrow characters;
  `SQLWCHAR` is two bytes. Default process time zone is Eastern; UTC is tested
  separately.

These results apply to this configuration. There is no cross-version,
cross-platform, remote-network, or Haskell comparison in this experiment.

## Type fidelity

| Concern | Measured result | What a binding must get right |
|---|---|---|
| `datetimeoffset(7)` | Exact native-struct parameter/result round trips, including the original offset and 100ns precision; matching text results | Support `SQL_SS_TIMESTAMPOFFSET` / `SQL_C_SS_TIMESTAMPOFFSET`, or an exact textual representation |
| `datetime2(7)` | Exact native timestamp-struct round trip | Preserve the fractional field's precision |
| `decimal(p,s)` | Exact signed integer magnitudes and scales for tested precisions 9, 18, 19, 28, and 38 | Use exact numerics and configure precision/scale descriptors, or parse exact text |
| Unicode in `nvarchar` | Exact UTF-8 and UTF-16 inputs and outputs | Declare Unicode SQL parameters and use the intended C encoding |
| Unicode in UTF-8 `varchar` | Exact with Unicode SQL parameters; corrupted with a narrow SQL parameter on this database | Do not infer the parameter's encoding from the destination column alone |
| Large Unicode values | Exact chunked reads from both `nvarchar(max)` and UTF-8 `varchar(max)` | Handle lengths and truncation warnings correctly across chunks |
| NULL | Preserved for offset timestamps, decimals, and both text types | Inspect the length/NULL indicator; distinguish empty text |

### Offset timestamps: an actual silent conversion

Native `SQL_SS_TIMESTAMPOFFSET_STRUCT` results preserve the fields, and text
results independently confirm the values stored by native-struct parameters.
For example:

```text
2026-07-01 09:12:33.7654321 +05:30
```

Requesting the same value as `SQL_C_TYPE_TIMESTAMP` instead returns
`SQL_SUCCESS`, with no warning, and:

```text
Eastern process: 2026-06-30 23:42:33.765432100
UTC process:     2026-07-01 03:42:33.765432100
```

The generic C timestamp has no offset field. This conversion both drops the
original offset and expresses the instant in the process's local time zone.
The two saved runs demonstrate the time-zone dependency directly. A binding
that maps `datetimeoffset` to a generic timestamp would therefore be a real
fidelity problem; the driver also supplies a faithful representation.

### Decimals: exact support, but scale is not automatic

The native tests use `SQL_NUMERIC_STRUCT`: a sign, precision, scale, and a
16-byte integer magnitude. The harness constructs and compares magnitudes
with integer arithmetic only. It sets input and output descriptor precision
and scale explicitly, and checks both `SQLGetData` and `SQLBindCol`.

Examples that survived exactly include `-19.95`, `0.01`, `42.5000`,
`12345678901234.5678`, `987654321012345678.1234567890`,
`12345678901234567890.123456789012345678` as `decimal(38,18)`, and a
38-digit integer as `decimal(38,0)`. Stored text also preserves trailing
fractional zeros. These are fixed-precision/fixed-scale decimal tests, not
floating-point approximations.

The deliberately unconfigured `SQL_C_NUMERIC` retrieval of
`decimal(9,2) 1234.56` returns magnitude **1234, scale 0**, with
`SQL_SUCCESS_WITH_INFO` and **`01S07` (Fractional truncation)**. Unlike the
timestamp conversion, this supplies a warning. A binding that treats all
successful return codes alike and discards diagnostics could hide the loss.

### Unicode: the parameter's SQL type matters

The shared input is:

```text
Renée / Łódź / 東京 / مرحبا / 😀 / café
```

It survives every combination of UTF-8/UTF-16 input, `nvarchar`/UTF-8
`varchar` storage, and UTF-8/UTF-16 output when bound as `SQL_WVARCHAR`.
Exact byte/code-unit comparison preserves even the decomposed accent.
Repeating this string 4,096 times also survives both `max` types and chunked
reads: 221,184 UTF-8 bytes or 311,296 UTF-16 bytes.

Binding the UTF-8 input as `SQL_C_CHAR` **and `SQL_VARCHAR`** instead produces:

```text
Renée / Lód´z / ?? / ????? / ?? / cafe?
```

The destination column still has a UTF-8 collation. The parameter has already
lost information on the way there, under this database's CP1252 default
collation. In the recorded run, the insert and retrieval return success with
no conversion warning. Declaring the parameter `SQL_WVARCHAR` fixes the same
test without changing the column. Reading a correctly stored UTF-8 column
does not show corruption here.

## Connections and encryption

| Test | Result | Evidence |
|---|---|---|
| Driver with unmodified library search path | OpenSSL could not be loaded | [Log](results/2026-10-29-openssl-default.log) |
| Mandatory encryption, default trust | Rejected self-signed certificate | [Log](results/2026-10-29-tls-mandatory-default.log) |
| Strict encryption, default trust | Rejected self-signed certificate | [Log](results/2026-10-29-tls-strict-default.log) |
| Strict encryption, `SSL_CERT_FILE` naming supplied certificate | Connected and queried | [Log](results/2026-10-29-tls-strict-ca-file.log) |
| Strict encryption, `ServerCertificate` pin | Connected and queried | [Log](results/2026-10-29-tls-strict-pin.log) |

OpenSSL 3.5.9 was already installed. Adding its library directory to the
test process's `DYLD_LIBRARY_PATH` resolved the loading failure. No package
installation, system symlink change, or trust-store change was made.

The tests establish the driver's behavior, not whether the certificate is
present in the macOS Keychain. Whatever the Keychain's state, the driver's
default validation did not accept this certificate. Supplying the trusted
certificate file enabled normal validation; pinning provided a separate
working strict-mode path. Pinning is exact certificate matching and replaces
normal chain, hostname, and expiry validation; see the
[documented `ServerCertificate` semantics](https://learn.microsoft.com/en-us/sql/connect/odbc/dsn-connection-string-attribute#servercertificate).

**Azure SQL and Managed Identity were not tested.** They require a separate
Azure run, including an identity-bearing execution environment for credential
acquisition. A local SQL login cannot settle that concern. Build and packaging
compatibility were not evaluated beyond the setup needed to run these tests.

## MARS and interruptibility

MARS successfully interleaves two 10,000-row result sets on one connection,
with every value verified. Without MARS, the second active query is rejected
with `HY000`, "Connection is busy with results for another command". Timing
out a second MARS statement leaves the first result readable and correct.

With MARS both off and on:

* A one-second `SQL_ATTR_QUERY_TIMEOUT` interrupts a ten-second `WAITFOR`
  after about **1.005 seconds**, with `HYT00`.
* `SQLCancelHandle` from another pthread interrupts an independently observed
  running query, with `HY008`. Across six trials, query completion takes
  **0.46–0.65 ms after the cancel call starts**. The observer confirms the
  waiting request is gone afterward.
* Timeout also interrupts `SQLMoreResults` after the first result is consumed.
  The measured interval is about **2.01 seconds**, despite a one-second
  setting. Treat this as a working timeout, not proof of an exact one-second
  end-to-end deadline.
* Closing a cursor after reading ten rows of a roughly 100 MB result takes
  **1.4–1.7 ms**, and the connection remains usable.
* The same statement then executes `SELECT 42`, and a fresh statement confirms
  the original `@@SPID`. Reuse is not concealed reconnection.

A timed-out explicit transaction remains open and committable:
`XACT_STATE() = 1`, `@@TRANCOUNT = 1`. Explicit `SQLEndTran(..., SQL_ROLLBACK)`
undoes the preceding insert, after which reuse succeeds. Applications still
need transaction cleanup on interruption.

These tests support ODBC cancellation and connection reuse on a responsive
local server. They do not establish whether a Haskell binding exposes
cancellation, whether its FFI calls are interruptible, or whether its cleanup
handles async exceptions correctly. Nor do they test network failure.

## Performance baseline

Medians of five measured rounds; setup/warmup details are in the
[methodology](README.md#performance-methodology). The
[full summary](results/2026-10-29-benchmark-summary.md) includes min/max values.

| Operation | MARS off | MARS on |
|---|---:|---:|
| `SELECT 1`, retrieve result | 288 µs/query | 271 µs/query |
| Prepared one-parameter SELECT | 198 µs/query | 199 µs/query |
| Connect + close, pooling disabled | 70.4 ms | 70.6 ms |
| Fetch bigint + Unicode + offset timestamp, UTF-8, rowset 1 | 1.50 M rows/s | 0.62 M rows/s |
| Same, rowset 256 | 0.33 M rows/s | 0.31 M rows/s |
| 4 MiB binary upload | 140 MiB/s | 59 MiB/s |
| 4 MiB binary download | 231 MiB/s | 62 MiB/s |
| Insert 1,000 rows, separate prepared executions, one transaction | 233 ms | 225 ms |
| Insert 1,000 rows, parameter array, one transaction | 8.18 ms | 9.25 ms |

UTF-16 retrieval is close to UTF-8 here. Rowsets of 256 are surprisingly
slower than fetching one row per call; the cause has not been isolated, so
these results do not justify a general claim that rowset batching is slower.
Parameter arrays substantially improve this insert workload. MARS noticeably
reduces streaming/large-value throughput in this configuration even when only
one statement is active.

The full process peaks at about **42.8 MiB RSS**. This is not a scaling test.
All timings include the local server and transport and come from a shared
development machine. They establish a reproducible ODBC baseline, **not that
ODBC is faster or slower than hmssql**. A fair comparison must match queries,
types, encryption, MARS, batching, result consumption, and transaction scope.

## Consequence for the README's rationale

The evidence supports "ODBC bindings need careful conversion and cancellation
handling". It does not support "Microsoft ODBC cannot preserve
`datetimeoffset`, decimals, or Unicode", or "ODBC cannot cancel and reuse a
connection". The native-library build/deployment motivation remains separate
and was not evaluated here.

The next binding audit can use these same fixtures to ask whether it preserves
the offset type, decimal precision/scale, Unicode parameter declarations,
diagnostics, and cancellation/rollback semantics. Managed Identity remains
an independent, untested concern.
