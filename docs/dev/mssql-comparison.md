# hmssql compared with mssql

hmssql replaced the unreleased `mssql` package, a merger of ms-tds and
mssql-simple (see [history.md](history.md)). This document is for anyone
porting code from mssql: what hmssql covers, what it drops on purpose, the
gaps that remain, and the behaviour changes to watch for. It began as the
audit done when mssql was deleted in September 2026, when two parallel
reviews, one of the wire layer and one of the client API, compared every
mssql module and its test suite with hmssql. The bugs that audit found, and
the many more found by the testing that followed, are in
[bugs-found.md](bugs-found.md); all are fixed.

**Verdict.** No key feature of mssql is missing from hmssql, apart from the
intentional drop of TDS versions before 7.4. The remaining gaps are
conveniences in the stored-procedure and parameter APIs.

## Intentionally dropped

| mssql feature | Why hmssql doesn't need it |
|---|---|
| Code paths for TDS 7.1–7.3: text-encoded date/time types, 16-bit UserType, 32-bit DONE row counts | hmssql speaks 7.4 and 8.0 only; `TdsContext.tdsVersion` still reaches every serializer |
| Legacy type codes 0x25, 0x27, 0x2D, 0x2F, 0x37, 0x3F | Servers speaking 7.2+ never send them, and they are not valid `sql_variant` base types |
| `Binary` instances; parsing of client messages (LOGIN7, SQLBatch, RPC) | hmssql is a client; every `get`/`put` takes a `TdsContext` instead (the test suite has a LOGIN7 parser for its mock server) |
| `Fixed0`…`Fixed38`, `Data (Fixed a)` | `Decimal` uses the column's scale; mssql's `Fixed` decoder ignored it |
| Template Haskell tuple instances up to arity 30 (rows) and 60 (RPC params) | Tuples up to 12 (decoders) and 10 (encoders), plus `Generic` records, `[SqlParam]`, `NamedParams` and `ResultSets` |
| Token-stream parser combinators (`TokenStreamParser`, `sqlWith`, `parseListOfRowsWith`, the `ResultSet` tuple class) | `responseS`, `RowDecoderMonadic`, `queryMulti` and the `ResultSets` monad; statements without result sets no longer need `()` placeholders |
| Raw LOGIN7 option flags, type flags, time zone and collation in `ConnectInfo` | Defaults are identical (`fSetLang`, `fDatabase`, `fUseDB`, `fODBC`, `fLanguage`); only `connectReadOnlyIntent` is exposed |
| Parsed COLINFO/TABNAME structures, text pointers and timestamps of `text`/`image` values | Browse-mode metadata; hmssql skips them |
| Bundled server certificate | `tlsCaCertificateFiles`, in-memory certificates, `tlsTrustServerCertificate` |
| The ten-statement session setup after login | LOGIN7's `fODBC` flag already sets the ANSI options and unlimited TEXTSIZE; `defaultSessionSetup` is empty, `["SET ARITHABORT ON"]` the opt-in |

## Covered

**Wire layer** (`Hmssql.Tds.*`, `Hmssql.Connection*`)

* **Types:** every fixed and nullable type; decimal/numeric; money and
  smallmoney (fixing mssql's sign bug in the low DWORD); datetime and
  smalldatetime; the binary encodings of date, time, datetime2 and
  datetimeoffset.
* **Strings and binary:** char, varchar, nchar, nvarchar, binary and
  varbinary, including `(max)` via PLP (unknown-length PLP too; sending in
  8000-byte chunks, only above the non-max limits); text, ntext and image;
  xml.
* **sql_variant:** every base type with its property bytes, and NULL. mssql
  handled only the fixed-length ones.
* **Collations**, including the UTF-8 flag; char/varchar/text are decoded by
  the collation's code page (single-byte code pages only).
* **Tokens:**
  * data: COLMETADATA (with multi-part table names, which mssql parsed
    wrongly), ROW, NBCROW;
  * completion and messages: DONE, DONEPROC, DONEINPROC, ERROR, INFO;
  * login: LOGINACK, FEATUREEXTACK;
  * procedures: RETURNVALUE, RETURNSTATUS;
  * other: ORDER, COLINFO, TABNAME, SESSIONSTATE, SSPI, FEDAUTHINFO;
  * CLR UDT column metadata (UDT_INFO), read past.
* **ENVCHANGE types 1–13 and 15–20.** Transaction descriptors are tracked
  and sent in ALL_HEADERS; packet-size changes are applied; a routing
  ENVCHANGE at login is followed (Azure SQL's Redirect policy). mssql
  ignored packet-size changes and misparsed routing.
* **PRELOGIN, all options.** Encryption negotiation follows the spec table.
  mssql only knew exact matches, and ENCRYPT_ON hit an incomplete pattern.
* **LOGIN7, all fields.** Includes password obfuscation, the UTF-8 feature
  extension, read-only intent, and the negotiated packet size (mssql never
  sent it).
* **SQLBatch and RPC** by name or ID, with output parameters and
  byRef/default status flags. Parameter lengths are UTF-16 byte lengths, so
  non-BMP text works.
* **Packet framing:** EOM tested as a bit, one `TLS.sendData` per packet,
  Attention, the RESETCONNECTION bit (`reset`).
* **TLS:** strict (ALPN `tds/8.0`, TLS 1.2/1.3), hosted in PRELOGIN, and
  login-only. SNI and hostname override; extra CA files and certificates;
  certificate validation on by default.

**Client API** (`Hmssql.Query`, `Hmssql.Decoding`, `Hmssql.Encoding`,
`Hmssql.Transaction`, `Hmssql.Errors`)

* **`ConnectInfo`:** host, port, user, password, database, server name (Azure
  error 40531), application name, language, packet size, encryption. New:
  TLS settings, read-only intent, a configurable session setup, an
  info-message callback, an access token, MARS (`connectMars`).
* **Queries:** a `Query` is SQL text with its parameters (`mkQuery`, `param`,
  `namedParam`, `<>`); one with no parameters runs as a plain batch, one
  with parameters via `sp_executesql`, with positional, named and
  heterogeneous parameters.
* **Results:** streaming (`queryS`, `withQueryS`); multiple result sets
  (`queryMulti`, `queryResultSets`). Neither library had MARS; hmssql has
  it as an option, several responses open on one connection.
* **Stored procedures:** `callProcedure` with output parameters and return
  status (`outParam`, `decodeReturnValue`).
* **Decoding:**
  * integers: `Int`, `Int8`–`Int64`, `Word8`, `Integer`;
  * other scalars: `Bool`, `Float`, `Double`, `Decimal`, `Money`;
  * text and binary: `Text` (strict and lazy), `String`, `ByteString` (strict
    and lazy), `UUID`;
  * dates and times: `Day`, `TimeOfDay`, `LocalTime`, `UTCTime`, `ZonedTime`,
    `DateTimeOffset`;
  * dynamic: `SqlValue`, `SqlRow`, `RawValue`, `Maybe`, `Only`.
* **Encoding:** all of the decoded types except `Fixed`, plus `SqlValue`
  (which mssql could not encode). `Maybe` becomes a typed NULL.
* **Dynamic rows** built at runtime: `RowDecoderMonadic`, `singleFieldM`,
  `remainingColumns`, `sqlRowDecoder`. This replaces mssql's `SqlRow` and
  runtime row parsers.
* **Transactions** with isolation levels, holding the connection, rolling
  back only if the transaction is still active, checking its identity.
* **Session reset** (`reset`), and returning a connection to a pool
  (`release`, `renew`), which neither library had.
* **Typed exceptions:** `LoginError`, `LoginRedirected`, `SqlServerError`
  (including the statement), `DecodeError` (raised eagerly with the column
  name), `EncodeError`, `ProtocolError`, `ConnectionClosed` with a
  `CloseReason`, `ConnectionBroken`, `TransactionError`, `ReentrantCallback`,
  `MarsNotSupported`.

The unmerged branches of the old repositories (`dev`, `devcustom`, `tds8` in
both ms-tds and mssql-simple) held nothing that hadn't reached mssql.

## Remaining gaps

None of these block ported code; each has a workaround, listed in
[limitations.md](limitations.md#gaps-with-workarounds).

1. **Typed stored-procedure results.** mssql's `rpc` decoded output parameters
   into a tuple and result sets into typed rows. `callProcedure` returns
   `[ResultSet SqlRow]` and raw `ReturnValue`s.
2. **Several RPCs in one request.** `putRpcRequest` takes a list, but
   `Hmssql.Query` always sends one.
3. **Calling procedures by well-known ID.** mssql had an enum from
   `sp_cursor` to `sp_unprepare`.
4. **Parameter wire types.** mssql had helpers for ANSI strings, `datetime`,
   `smallmoney`, decimals with explicit precision and scale, and fixed-length
   `char`/`binary`. hmssql picks one wire type per Haskell type; `RawParam`
   is the escape hatch.
5. **Decimal output parameters** are declared `decimal(38,10)`; mssql's
   `decimalRef` took precision and scale. Use `rawOutParam` with an
   explicit `TIDecimalN` and `procParamOutput = True` for other shapes.
6. **Looser decoding.** mssql decoded `Bool` from any integer column and
   `Bool`/integers directly from `sql_variant`; hmssql's `Bool` accepts only
   `bit`, and `sql_variant` decodes into `SqlValue`.
7. **Per-statement row counts.** `execute` returns the sum of every DONE
   count.
8. **RPC flags.** `ProcParam` can't set the DEFAULT parameter status flag,
   and `callProcedure` always sends option flags 0.
9. **Timeouts.** Neither library had them; hmssql's calls are all
   interruptible, so wrap them in `System.Timeout.timeout`.

## Behaviour changes when porting from mssql

* **Default encryption** is `EncryptOn` with certificate validation. mssql
  defaulted to login-only encryption. A server with an untrusted certificate
  now fails until `connectTls` is configured.
* **Other defaults:** host `localhost:1433`, application name `"hmssql"`,
  client PID and program version 0. The PRELOGIN instance name is empty.
* **No session setup after login.** mssql sent ten `SET` statements as one
  batch; hmssql sends none, since LOGIN7's `fODBC` flag provides the ANSI
  options and unlimited TEXTSIZE. `ARITHABORT` is off unless
  `connectSessionSetup = ["SET ARITHABORT ON"]`, which runs as one batch at
  connect and after each `reset`.
* **`SqlValue`** constructors are renamed (`SqlNullValue` → `SqlNull`, …).
  varchar values become `SqlText` (mssql gave bytes), tinyint becomes an
  unsigned `SqlWord8 Word8`, and datetime becomes `LocalTime` (mssql gave
  `UTCTime`).
* **Stricter decoding:** tinyint is decoded as unsigned (mssql read it as
  signed); `Float` rejects `float(53)` instead of losing precision; a column
  in a double-byte code page is a `DecodeError`; see also gap 6.
* **Errors are raised eagerly.** mssql errored lazily when a field was forced.
* **Info messages** go to `connectOnInfoMessage`; mssql dropped them.
* **`withTransactionLevel`** used to leave the isolation level set on the
  session after the transaction ended. It now sets READ COMMITTED back.
  `withTransaction` refuses to nest (`TransactionAlreadyActive`), holds the
  connection for the whole transaction, and throws `TransactionEndedEarly`
  if the transaction ended or was replaced before it could commit, and
  `TransactionStillOpen` if the body left a nested transaction open.
  Transactions begin with a Transaction Manager request, not a `BEGIN
  TRANSACTION` batch (the only begin SQL Server accepts on a MARS
  connection); commit and rollback are still T-SQL batches.
* **Connection failures** are `ConnectionClosed` with a `CloseReason`
  (`ClosedByServer`, `ClosedByClient` after `close`, `TransportFailed` with
  the underlying `IOException` or `TLSException`), never a raw transport
  exception; this includes `connect` failing to reach the server.
* **Interruptions.** An asynchronous exception while a request waits for or
  reads its response cancels the statement at once and leaves the
  connection usable; one that lands in a blocked send breaks the
  connection (`ConnectionBroken`). mssql had no defined behaviour.
* **Untyped NULL parameters** (`SqlNull`, `Nothing :: Maybe Text`) are
  declared `nvarchar(max)`, and `Nothing :: Maybe ByteString`
  `varbinary(max)`; the server won't convert either to `sql_variant` (error
  206), so a NULL for a `sql_variant` column or parameter must be typed
  (`Nothing :: Maybe Int32`, or `RawParam (TISqlVariant 8016, Nothing)`),
  and a NULL for a binary column must be `Nothing :: Maybe ByteString`.
* **`SqlXml` parameters** are sent as `xml`.
* **`Int8` parameters** are sent as `smallint` (mssql sent tinyint, so
  negative values arrived wrapped).
* **Date/time parameters** round like the server does (half up, carrying
  into the next day) and never past midnight; out-of-range values are an
  `EncodeError`.

## mssql tests worth porting

Behaviours mssql's test suite exercised, and whether hmssql-tests covers them
now:

* Session properties right after connect: `@@TEXTSIZE` and the `@@OPTIONS`
  bits. *Covered* (`ResetSpec`, `Session.SetOptions`).
* `sp_reset_connection`, then the same session-property checks, also inside an
  open `BEGIN TRAN`. *Covered* (`ResetSpec`, for `reset` too).
* A 134-million-character SQL batch, and the same string read back as
  `nvarchar(max)`. *Covered* (`LargeValueSpec`, slow).
* A million-character `nvarchar(max)` parameter, and a NULL `nvarchar(max)`
  parameter (a PLP NULL, so `DATALENGTH` is NULL). *Covered*
  (`LargeValueSpec`).
* `datetime` and `datetime2` decoded to `UTCTime`, including NULL and
  type-mismatch errors. *Covered* (`Types.DateTimeDecode`).
* Non-BMP string round trips through parameters. *Covered*
  (`Types.NVarChar`).
* Two RPCs in one request. *Not covered* (gap 2).
* mssql's `SqlQuery` helper, an Applicative pairing SQL text with its
  result parser so several queries run as one batch. *Covered* by
  `BatchQuery` (`Hmssql.BatchQuery`), one `sp_executesql` per statement in
  one message, each statement's results delimited by its DONEPROC.
