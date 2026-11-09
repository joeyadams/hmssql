# Source audit supporting the runtime findings

All references below are to the unmodified **odbc-0.3.0 Hackage source
archive**, whose SHA256 is recorded in [README.md](README.md#source-provenance).
Run `bash experiments/odbc-haskell/fetch-upstream.sh` to unpack the exact
source under the ignored `upstream/odbc-0.3.0/` directory. The archive hash
matches Cabal's build plan; the dependency is not built from a modified fork.

The paths and one-based line numbers below refer to that archive, not the
moving GitHub default branch. [The Hackage release](https://hackage.haskell.org/package/odbc-0.3.0)
and [upstream repository](https://github.com/fpco/odbc) provide package context.

| Finding | Source location | Mechanism |
|---|---|---|
| Decimal values become approximate | `src/Database/ODBC/Internal.hs:697` | Both SQL numeric and decimal types are retrieved with `sql_c_double` into eight bytes, then returned as `DoubleValue`. This happens before any user `FromValue` instance runs. |
| The high-level value model lacks an exact decimal constructor | `src/Database/ODBC/Internal.hs:115` | `Value` has `DoubleValue`, `FloatValue`, integer, text, date/time and other cases, but no scaled-integer/decimal case. |
| Offset timestamps avoid generic timestamp conversion | `src/Database/ODBC/Internal.hs:787` | Reads the driver's 20-byte offset-timestamp structure via `SQL_C_BINARY`; reconstructs local fields, fractional seconds and signed offset minutes. |
| Text inputs use Unicode parameters | `src/Database/ODBC/Internal.hs:459` | Binds UTF-16 as `SQL_C_WCHAR` / `SQL_WLONGVARCHAR`. |
| UTF-8 varchar output is bytes | `src/Database/ODBC/Internal.hs:641` and `:892` | Narrow SQL character types use `getBytesData`, retrieving binary bytes rather than guessing an encoding. |
| Varchar does not automatically decode to `Text` | `src/Database/ODBC/Conversion.hs:39` | `FromValue Text` accepts `TextValue`, not `ByteStringValue`; this produces the observed conversion exception rather than silent corruption. |
| One connection serializes whole operations | `src/Database/ODBC/Internal.hs:385` | `withHDBC` holds the connection's `MVar` while the complete query or stream runs. Streaming invokes its callback inside this scope (`streamWithParams`, line 368). A callback cannot issue another same-connection operation until the outer operation releases the lock. |
| Async exceptions do not implement server cancellation | `src/Database/ODBC/Internal.hs:430`, `:1168`; `cbits/odbc.c:205` | Operations run through `withAsyncBound` and `wait`; C execution calls `SQLExecDirectW`. The package has no `SQLCancel`/`SQLCancelHandle` call or exported statement-cancellation API. Its ordinary safe foreign call is not an interruptible foreign call. Runtime evidence shows cancellation waits for the server call to finish. |
| Native query timeout configuration is not exposed | Module exports in `src/Database/ODBC/Internal.hs:25` and `src/Database/ODBC/SQLServer.hs:14`, plus the FFI declarations | There is no exported statement handle or API for `SQL_ATTR_QUERY_TIMEOUT`; the high-level tests therefore use ordinary Haskell `timeout` and `killThread`. This limitation is in the package API, not the Microsoft driver. |
| Only text and binary inputs become bound parameters | `src/Database/ODBC/SQLServer.hs:515` | `valueToParam` recognizes nonempty text and binary values. Numeric and date/time values are rendered into the SQL text. `toSql` is not evidence that every input uses a prepared parameter. |
| Warning diagnostics are not generally exposed | `src/Database/ODBC/Internal.hs:1025`; `cbits/odbc.c:231` | Success-with-information is accepted. The C wrapper collects error diagnostics on `SQL_ERROR`; there is no general public warning result. This is a source observation, separate from the measured decimal loss, which follows its explicit Double mapping. |
| Connection string authentication can reach the driver | `src/Database/ODBC/Internal.hs:231`; `cbits/odbc.c:129` | `connect` sends the provided connection string to `SQLDriverConnect`. Driver-managed authentication can be requested in that string. No pre-connect access-token attribute setter is exposed. This does not establish that Managed Identity works in a particular Azure environment. |

These observations explain the measured behavior. They are not a full security,
memory-safety, compatibility, or correctness audit of the package.
