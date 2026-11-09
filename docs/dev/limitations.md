# Limitations, gaps and open questions

What hmssql doesn't do, what it does awkwardly, and what remains undecided.
The rules it does follow are in [design.md](design.md). What is planned,
before the release and after it on request, is in [backlog.md](backlog.md);
this document lists what is true today, gives each gap its workaround, and
says where a gap is planned to close.

## Not supported

Not planned, unless someone brings a use case and a good argument:

* integrated (Windows) authentication through SSPI;
* Always Encrypted;
* CLR UDTs: their columns are readable only as `RawValue` bytes, and a
  parameter of one is an `EncodeError`;
* `COMPUTE BY`, which SQL Server 2012 removed;
* distributed transactions;
* servers older than SQL Server 2017 (below this list), and TDS versions
  before 7.4, which servers before SQL Server 2012 implement;
* double-byte code pages (gap 11);
* `Word16`, `Word32`, `Word64` and `Natural` parameters and columns, since
  SQL Server has no unsigned type wider than `tinyint`, which `Word8` maps
  to;
* a `sql` quasiquoter (gap 14);
* LocalDB and the dedicated administrator connection.

SQL Server 2012 to 2016 implement TDS 7.4, and hmssql doesn't refuse
them, but it supports SQL Server 2017 and later only. 2017 is the oldest
server the test matrix runs against, and the older servers aren't tested.
They are also the likely ones to present a certificate they generated for
themselves with an RSA key shorter than 2048 bits, which `tls` 2.5 refuses
([below](#connections-tls-and-the-wire)). Supporting them is not
planned.

Entra ID authentication is by access token only (`connectAccessToken`):
hmssql sends a token the caller obtained and never obtains one itself.
That covers Azure Managed Identity, service principals, workload identity
and `az account get-access-token`, whose tokens the caller can fetch with
a plain HTTP request. The interactive, device-code and username and
password flows, which need an OAuth client library (MSAL), are not
planned.

Not supported yet, and planned ([backlog.md](backlog.md)):

* **Table-valued parameters.** `RawParam` and `TypeInfo` have no encoding
  for one, so a caller has to write the whole RPC through `Request`, as
  [protocol-notes.md](protocol-notes.md#rpc-and-stored-procedures) shows.
  A procedure called without its TVP parameter gets the server's empty
  table.
* **Enhanced routing**, the redirect that also names a database (Azure SQL
  Hyperscale's reader endpoints). hmssql doesn't request it, and follows
  only the ordinary redirect.

MARS is supported and opt-in (`connectMars`); what it doesn't do is under
[MARS](#mars) below.

## Gaps with workarounds

The numbers are stable, because other documents cite them.

1. **No built-in timeouts, and no TCP keepalive.** `ConnectInfo` has no
   connect or command timeout, and hmssql never gives up waiting for the
   server to acknowledge an Attention. Bound calls yourself with
   `System.Timeout.timeout`, `killThread` or `async`'s `cancel`:
   interrupting a query sends the Attention at once, which cancels the
   statement on the server. Without such a wrapper the last address of an
   unreachable host blocks `connect` until the operating system gives up
   (every address before it gets 4 seconds), a server that never answers
   keeps the caller waiting, and a runaway query runs until it finishes.
   No keepalive is set on the socket either, so a peer that vanished is
   noticed only when the kernel gives up retransmitting. The wait itself
   costs nothing: memory and CPU stay flat however long a server leaves a
   request unanswered ([design.md](design.md#memory-and-performance)). A
   `timeout` around `connect` that expires during the host name lookup
   takes effect only when the lookup returns, and on Windows under GHC's
   native I/O manager a connect can't be shortened at all (under
   [Windows](#windows)). Timeout settings are on the backlog.
2. **Parameter wire types are fixed per Haskell type.** `Int` is `bigint`,
   `Text` is `nvarchar`, and `LocalTime` is `datetime2(7)`. Sending
   `nvarchar` against a `varchar` index, or `datetime2` against a
   `datetime` column, forces implicit conversions: index seeks become
   scans, and an exact comparison with a `datetime`, whose precision is
   1/300 s, can miss rows. `RawParam` is the escape hatch:
   `sqlTypeTypeInfo` (`Hmssql.SqlType`) gives it the wire type of a
   declared type such as `varchar(20)`, but the value's bytes are the
   caller's to encode. An explicit parameter-type API is on the backlog.
3. **Typed stored-procedure results.** `callProcedure` returns
   `[ResultSet SqlRow]` and raw `ReturnValue`s, each decoded with
   `decodeReturnValue`. Running `EXEC` through `queryResultSets` gives
   typed rows but loses the output parameters. A form that decodes the
   result sets into row types is on the backlog.
4. **Decimal output parameters** are declared `decimal(38,10)`, or with
   the initial value's scale if that is larger. For another precision or
   scale, use `rawOutParam "@x" (TIDecimalN 38 0, Nothing)`.
5. **RPC flags.** `ProcParam` can't set the DEFAULT parameter status flag,
   though the wire layer supports it; omit the parameter and pass the
   others by name instead. `callProcedure` always sends RPC option flags 0,
   so there is no `WITH RECOMPILE`.
6. **Several RPCs in one request.** `putRpcRequest` takes a list, and
   `Hmssql.Query` sends one per statement. `executeStatements` and
   `runBatchQuery` send several `sp_executesql` calls in one message,
   which covers several parameterized statements.
7. **Calling procedures by well-known ID.** `RpcProcId` exists on the
   wire, but everything except `sp_executesql` is called by name, which
   works.
8. **Per-statement row counts.** `execute` returns the sum of every DONE
   count of its batch. `executeStatements` and `executeManyOutcomes` count
   per statement, one `sp_executesql` call each.
9. **Stricter decoding.** `Bool` accepts only `bit`, though `Int` accepts
   `bit` too, and `sql_variant` decodes only into `SqlValue`. `refineField`
   over `SqlValue` works around both.
10. **`sql_variant` NULLs need a typed NULL.** Untyped NULLs are
    `nvarchar(max)`, which the server won't convert to `sql_variant`
    (error 206). Use `Nothing :: Maybe Int32`, say, or
    `RawParam (TISqlVariant 8016, Nothing)`. An `xml` output parameter
    needs `outParam "@x" (SqlXml "")` or `RawParam (TIXml Nothing,
    Nothing)`, since a `Text` initial value fails with error 257.
11. **Double-byte code pages** (932, 936, 949 and 950) are not decoded.
    Such a column is a `DecodeError` when its metadata arrives, even if it
    holds only NULLs. Read it as `ByteString`, or cast it to `nvarchar` in
    the query. Bulk copy leaves the representability and length of a value
    for such a column to the server.
12. **`FOR BROWSE` hidden columns** are returned as ordinary columns, since
    COLINFO is skipped, so a one-field row type fails on a one-column
    `FOR BROWSE` query.
13. **Typed streaming of several result sets.** `queryMulti*` and
    `queryResultSets` materialize each set's rows, though a large value in
    any of them can stream through its decoder. `queryS` streams only the
    first set, and `batchQueryS` only the last statement's first. A
    `BatchQuery` statement that streams from the middle of a batch is on
    the backlog.
14. **No `sql` quasiquoter** with `#{expr}` interpolation, as hpgsql has.
    This is by design: it needs a Haskell parser at compile time and is
    more magic than a TDS library should carry. `Query` is a `Monoid` with
    `param`, `namedParam`, `rawSql` and `escapeIdentifier`, which covers
    SQL built at runtime, and a quasiquoter can be built on
    `Hmssql.Query.Types` as a package of its own. Related: `@p<digits>` is
    always a placeholder in `mkQuery` text, so a variable of that name
    needs another name.
15. **Nothing probes the server.** `unusableReason`, `renew` and `release`
    report what hmssql has recorded, so a session dropped without the
    socket being closed (a half-open connection, which TCP keepalive would
    find in minutes) is found by the next request, and so is a kill that
    lands between a `renew` and the first request. A pool that must know
    before lending a connection out can run `SELECT 1` on the `renew`ed
    handle. An exception's type doesn't say whether the connection
    survived, since an asynchronous exception during a send breaks it while
    the caller sees only that exception, so ask `unusableReason`. A request
    that fails with `ConnectionClosed` or error 596 is safe to run again on
    another connection only if it wasn't sent, and nothing says whether it
    was: an application infers that from its own bookkeeping, though
    hmssql knows whether the first packet was written.
16. **`withTransaction` costs a round trip for its begin**, a Transaction
    Manager request of its own before the body, and one for the `COMMIT`.
    There is no way to send the begin with the body's first batch. An
    explicit transactional-batch API is on the backlog.
17. **On Windows without `-threaded`, some calls stop the whole program,
    and some builds can't use GHC's native I/O manager.** With network 3.3
    or later and a GHC whose native manager network supports, every
    protocol works under `+RTS --io-manager=native` without `-threaded`:
    TCP goes through network's own calls and the pipes through the manager
    ([design.md](design.md#platform-workarounds)). network's `getAddrInfo`
    and `connect`, a send once the server has stopped reading, and the
    open of a pipe then stop every Haskell thread until they return,
    timers and `timeout` included, as `getAddrInfo` does on Linux and
    macOS. A local pipe opens or fails in microseconds, and a pipe on
    another machine waits for SMB. A GHC without the manager's fix (on the
    branch `wip/winio-completion-packets` as of 2026-11-07, not yet
    upstream, so every release so far) freezes this runtime under load:
    the probe of the pipes froze in 5 runs of 5, and network's TCP path
    after the first `close`
    ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
    In any other build hmssql's own backend runs its waits, lookups and
    connects on the default manager's worker threads through
    `asyncDoProc`, which the native manager of a released GHC doesn't
    have, so under that manager `connect` throws
    `ConnectionClosedBy (TransportFailed e)` saying what is needed. With
    `-threaded`, both managers work for every protocol in every build. A
    non-threaded program whose other operating-system threads call into
    Haskell is not supported on hmssql's backend, because it starts its
    operations on whichever thread runs the scheduler. Making the first
    GHC release with the manager's fix the minimum for that manager is on
    the backlog.
18. **A named instance is reached over TCP by its port.** hmssql doesn't
    ask the SQL Server Browser which port a named instance listens on.
    Give the port in `connectPort`, or on Windows give the instance's name
    in `connectInstance`, which Shared Memory and Named Pipes use.
19. **Output parameter values are read whole.** Input parameters and
    result columns can stream, but a RETURNVALUE is assembled in memory,
    whatever its size. Return a large value as a column of a result set
    instead. Streaming output parameters needs a `ProcResult` of another
    shape, and is on the backlog.

## Behaviours to know about

### Connections, TLS and the wire

* **TLS is slow where crypton has no accelerated AES**, which includes
  Apple silicon with `crypton` 1.1.5. SQL Server picks AES-GCM, and the
  client then encrypts at some tens of megabytes a second: a 4 MB
  parameter takes 48 ms of client CPU, and a 32 KB batch takes 2.9 ms
  where it takes 0.4 ms in plaintext
  ([design.md](design.md#memory-and-performance)). Small requests are
  hardly affected. What a TLS record costs also depends on the versions in
  the build: `tls` 2.4.7 or later over `crypton` 2.1 is about twice as
  fast per record as the pair in Stackage `nightly-2026-11-03` (`tls`
  2.4.6 over `crypton` 1.1.5). hmssql has no setting for the cipher
  suites; one that offers ChaCha20-Poly1305 alone, which SQL Server 2025
  on Linux accepted in a probe, is on the backlog.
* **With `tls` 2.5 or later, a server certificate with an RSA key shorter
  than 2048 bits is refused**, even with `tlsTrustServerCertificate`. Every
  connection fails its login handshake, `EncryptOff` included
  ([design.md](design.md#encryption-and-tls)). The likely case is an
  older SQL Server without a configured certificate, which presents the one
  it generated for itself. Clients built on OpenSSL 3 are widely reported to
  fail against those servers with "ee key too small". The suite has not
  measured that certificate's key size, because the test matrix starts at
  SQL Server 2017 and has no Windows server older than 2019. The workaround
  is to install a 2048-bit certificate on the server.
* **The system certificate store is read once per process**, and the
  files in `tlsCaCertificateFiles` are read by every `connect`.
* **Azure SQL Database's gateway caps the packet size at 16192 bytes**
  (SQL Server 2025 caps a request for 32767 at 16384), sets CONTEXT_INFO
  to a tracing GUID at login, and routes the login by the LOGIN7 server
  name, which is `connectHost` unless `connectServerName` overrides it.
  [azure-sql.md](azure-sql.md) has what the test suite found there.
* **The responses to the connection's own requests are read whatever
  their size.** hmssql sends some requests itself: the Transaction
  Manager's begin, the commit and rollback batches, and the session setup
  batch, which carries a reset when one is pending. It reads their
  responses to the end with no bound of their own, so a broken or hostile
  server that answers with an endless value grows the process for as long
  as it sends ([design.md](design.md#what-the-wire-layer-checks)). SQL
  Server answers each with a few small tokens. A `timeout` around the call
  ends it and breaks the connection. No response has a bound on its size,
  by design, and these get no exception, because hmssql has no budget
  per request.
* **SQL Server 2025 never sends NBCROW rows over TDS 8.0**, so only the
  other encryption modes exercise NBCROW decoding against it; the test
  suite does that through `HMSSQL_TEST_ENCRYPTION=on`.
* **`connectReadOnlyIntent` affects only routing on an Availability Group
  listener.** No DMV on a standalone instance reflects it, so the tests
  can only check that it doesn't break an ordinary login.
* **A killed session.** The request running at the time fails with a
  `SqlServerError` of severity 20 or more, with `ConnectionClosed`, or on
  Azure SQL Database with `SevereError` (a DONE flagged as failed with no
  message), and the connection is gone. SQL Server on Linux closes it
  (`ClosedByServer`), and Azure's gateway resets it (`TransportFailed`
  with "connection reset by peer"). SQL Server on Windows ends it
  abruptly too: over TCP it resets the connection, and over Shared Memory
  or Named Pipes it disconnects the pipe ("No process is on the other end
  of the pipe"), both a `TransportFailed`. With several streams open on a
  MARS connection, one may first fail with `SqlServerError` 3980, its
  batch aborted because another request is running in the session.

### Errors

* **A `SqlServerError` of severity 20 or more breaks the connection** as
  soon as its ERROR token is parsed, before the server closes the
  transport. Lower severities leave it usable.
* **A `SqlServerError` holds one message.** When a statement reports
  several errors, as `BACKUP` and `RESTORE` can, only the first is kept.
* **A shape error on the client says nothing about the server's work.** A
  `query1` over a batch that writes and then selects nothing reads the
  response to its end and throws `UnexpectedResult`, and the write is
  committed in autocommit mode, or stays in the transaction if the error
  is caught inside `withTransaction`. Let it escape to roll back.

### Interruption and cancellation

* **An interruption of a send, or of the drain of a cancelled response,
  breaks the connection.** A pool must replace it; `release` returns
  `False` for it, while `reset` alone does no I/O and can't tell.
  Cancellation needs no second core: on one capability the interrupted
  thread sends the Attention as soon as it runs. But a `timeout` shorter
  than the time the process can stall (a saturated single capability, or
  a long garbage collection) can expire before the request it wraps has
  sent anything, or while that request drains a result the previous call
  abandoned, and then it breaks the connection instead of cancelling a
  statement.
* **An interruption can lose one batch of a stream's rows.** One that
  lands while a batch of rows is being handed to a `queryS` consumer,
  after the batch was committed as consumed, loses that batch, the rows
  of one packet. One that lands while waiting for or parsing rows loses
  nothing.
* **Nothing bounds the wait for an Attention's acknowledgement.**
  `cancelActiveStatement`, `release` and the drain of an abandoned stream
  wait for it as long as it takes. SQL Server 2025 ignores an Attention
  that reaches it before the statement is under way, on plain and MARS
  connections alike, and acknowledges it only once the statement has
  ended ([protocol-notes.md](protocol-notes.md#mars-and-smp)). Idle, that
  is an Attention sent within a few milliseconds of its request; on a
  loaded server it was 300 ms. A `timeout` that interrupts a request that
  early returns at once as usual, but the statement runs on, holding its
  locks, and the next operation's drain waits for its end, which for a
  lock wait is until the lock is released: 117 s in the test matrix,
  where the holder was the test itself
  ([protocol-notes.md](protocol-notes.md#the-server-under-load)). hmssql
  can't tell such an Attention from one the server is about to act on,
  and doesn't send a second, which would be acknowledged twice. An
  unattended service wraps these calls in `timeout`, as `release`'s
  documentation shows; the interrupted wait breaks the connection.
* **An info-message callback that throws leaves the rest of its response
  pending.** The next request drains it and runs the callback on the
  remaining INFO tokens, so a callback that throws again fails that
  request too.
* **A cancelled stream can roll back an `XACT_ABORT` transaction.** A
  `queryS` stream abandoned under `SET XACT_ABORT ON` inside a transaction
  can roll the transaction back, depending on timing, because the
  cancelling Attention is a cancel to the server. Read or drain such
  streams explicitly inside such transactions. On a MARS connection the
  same goes for a stream cancelled by `withQueryS`'s exit or
  `cancelResponse` while its statement is still running.

### Transactions and session state

* **`withTransactionLevel` sets READ COMMITTED back when it ends**, not
  the level in effect before, so a level set by hand on the session is
  lost.
* **A `reset` keeps the session's isolation level on SQL Server 2025 and
  puts READ COMMITTED back on Azure SQL Database.** `sp_reset_connection`
  puts it back on both, and a session setup that sets the level behaves
  the same everywhere.
* **`sp_reset_connection` exists only as an RPC.** `EXEC
  sp_reset_connection` fails. `reset` and `callProcedure conn
  "sp_reset_connection" []` differ, as
  [design.md](design.md#session-setup-and-reset) says.

### Queries and parameters

* **A query runs as a batch or through `sp_executesql` depending on
  whether it has parameters.** Adding the first `param` moves it into
  `sp_executesql`, where a `SET` option or a `#temp` table it creates
  ends with the call. `executeStatements`, `executeMany` and
  `runBatchQuery` send every statement through `sp_executesql`, even one
  without parameters.
* **`executeStatements`, `executeMany` and `runBatchQuery` are not all or
  nothing.** Statements after a failed one may have run, unless the error
  aborted the batch. Use them inside `withTransaction` when that matters.
* **`Text` parameters are declared `nvarchar(4000)`** (up to 4000 UTF-16
  code units) or `nvarchar(max)`, and `ByteString` ones `varbinary(8000)`
  or `varbinary(max)`, not by the value's own length, so a statement
  compiles once for values of every length; `SELECT @p1` for a short
  string has the type `nvarchar(4000)`. Concatenating two short parameters
  therefore stops at 4000 characters or 8000 bytes without an error,
  unless one is cast to `(max)` in the SQL. A value over the limit fails
  against `sql_variant`, and a statement can have a cached plan for each
  of the two declarations.
* **A `Decimal` parameter is declared by its value**, as `decimal(p,s)`
  with the value's own scale and just the precision its digits need, so
  `1.5` and `1.50` are different declarations and a statement run with
  both is compiled for each. An `Integer` is `bigint`, or `decimal(38,0)`
  beyond `bigint`'s range, by value too. Give such a parameter a fixed
  declaration with `RawParam` where the plan cache matters.
* **`Text` into a `varchar` column becomes `?` for a character outside its
  code page**, which the server substitutes when it converts the
  `nvarchar` parameter. Bulk copy
  refuses the same value on the client instead (under
  [Bulk copy](#bulk-copy)).

### Types and conversions

* **`UTCTime` reads the zoneless types as UTC.** A `datetime`,
  `smalldatetime`, `datetime2` or `date` column decodes into `UTCTime` as
  if its clock time were UTC, so a column filled by `GETDATE()` on a
  server outside UTC decodes to the wrong instant; a `datetimeoffset` is
  converted to UTC properly. Store `SYSUTCDATETIME()`, or decode into
  `LocalTime` and convert with the right zone. A `UTCTime` parameter is
  sent as its UTC clock time in a zoneless `datetime2(7)`, the wire type
  of `LocalTime`. The decisions on these conversions are on the backlog.
* **A `date` column decodes into `LocalTime` or `UTCTime` at midnight**,
  while `Day` refuses a `datetime` column, so the two directions differ.
* **`TimeOfDay` clamps at 23:59:59.9999999** when it rounds to 100 ns, and
  a leap second becomes that value, while a `LocalTime` carries into the
  next day and counts a leap second as the following second
  ([Open questions](#open-questions)).
* **`SqlValue` doesn't keep the SQL type.** `datetime`, `smalldatetime` and
  `datetime2` are one constructor, as are all the character types and
  both money types, and `SqlDateTime` goes back as `datetime2(7)`, so a
  value read into `SqlValue` and sent back may not have its column's type.
* **`DateTimeOffset`'s `Eq` and `Ord` count the offset**: the same instant
  recorded with two offsets is two different values, where SQL Server
  compares `datetimeoffset` values by their instant. Compare `dtoUtcTime`
  for SQL's equality.
* **Hand-written decoders compiled at `-O0` are slower.** The rewrite
  rules that turn an applicative chain into one call of a lift function
  fire only under optimization, so at `-O0` each step is a partial
  application: an integer pair took 1.40 times as long and allocated 1.24
  times as much as at `-O1`, and five nullable fields 1.12 and 1.27 times
  (GHC 9.12.4, 2026-11-04). Derived decoders aren't affected. Compile the
  modules that build such decoders at `-O1` or more. Not planned.
* **A very wide applicative decoder does more work when a row is cut into
  tiny packets.** A decoder suspended at a packet boundary traverses its
  pending binds when it resumes, a cost proportional to its depth for each
  suspension; a long value loops inside a primitive instead. SQL Server's
  smallest packets carry 504 bytes, so it matters only for a peer that
  sends short packets that aren't the last of their message, which hmssql
  accepts. Measuring it is on the backlog.

### Bulk copy

* **Bulk copy skips the checks a plain `INSERT` makes.** A bulk load
  doesn't fire triggers or check constraints and foreign keys unless asked
  (`bulkFireTriggers`, `bulkCheckConstraints`), and leaves the constraints
  marked untrusted; a NULL for a column with a default gets the default
  unless `bulkKeepNulls` is set.
* **Bulk copy needs more permissions than an `INSERT`.** Column discovery
  (`InsertableColumns` and `NamedColumns`) is a `SELECT TOP 0` that needs
  SELECT on the table, where `DescribedColumns` needs none; the load
  itself needs ALTER TABLE on a table with a check constraint or a
  trigger unless both `bulkCheckConstraints` and `bulkFireTriggers` are
  set (error 5304), and ALTER TABLE for `bulkKeepIdentity`. A login
  granted INSERT alone can load a table without constraints or triggers,
  or one with them when both options are set and the columns are
  described ([protocol-notes.md](protocol-notes.md#bulk-load)).
* **A bulk load is not all or nothing.** A batch that fails (on a
  constraint, invalid XML, or a trigger that throws) is rolled back and the
  batches before it stay inserted, and a trigger's `RAISERROR` without a
  rollback reports an error and leaves the batch's rows in. Run the load
  inside `withTransaction` and let the exception escape to roll back the
  whole of it.
* **An interrupted load breaks the connection.** A load whose row stream
  throws is cancelled with an Attention; a small partial load leaves the
  connection usable, but the server may reset the connection for a larger
  one. A load interrupted by an asynchronous exception (a `timeout` or a
  `killThread`) while its rows are being sent breaks the connection, as
  any interrupted send does, whether the interruption lands in a send or
  in the row stream's own wait for its next row. Rows committed by an
  earlier `bulkBatchSize` batch outside a transaction remain.
* **Bulk copy converts on the client, within a family of types.** Each
  value is converted to its column's type as its `ToSqlField` instance
  encodes it (`encodeBulkCell`): numbers to any numeric column, rounded or
  truncated and range-checked as SQL Server converts them; strings to any
  character, `xml` or `sql_variant` column; and date and time values
  between the date and time types. It does not convert across those
  families as a plain `INSERT` would, so a number for a character column,
  or a string for an `int` column, is an `EncodeError`. Convert it in
  Haskell, or declare the columns (`DescribedColumns`) with the type the
  value is sent as and let the server convert.
* **Bulk copy is stricter than a plain `INSERT` with characters.**
  Character columns are sent as `nvarchar` and converted by the server to
  the column's collation, but a character absent from a single-byte
  column's code page, or a value longer than the column, is refused on the
  client with an `EncodeError` rather than stored as `?` or truncated, as
  a plain `INSERT` would do silently (for length, under `SET ANSI_WARNINGS
  OFF`). A double-byte collation (Shift-JIS, GBK, Big5 or EUC-KR), which
  hmssql can't encode, is the exception: its representability and length
  are left to the server. A UTF-16 value with an unpaired surrogate stores
  U+FFFD in its place in a `_UTF8` column, as the server converts it,
  while `nvarchar` and `ntext` keep the unit.
* **A `Double` or `Float` into a `decimal`, `numeric`, `money` or
  `smallmoney` column is rounded on the client** from its exact binary
  value, half away from zero, which is how the server rounds the same
  parameter, so bulk copy and `executeMany` store the same digits.
* **Bulk copy clamps a date and time at the top of its column's range**
  where the encoders do, and the server refuses two of those conversions:
  a `smalldatetime` from 2079-06-06 23:59:30 on, and a `datetimeoffset` at
  the last fractional tick of `datetime` (the server clamps a `datetime2`
  there too).
* **A non-NULL `RawParam` with no bytes is refused** for a BYTE-length
  numeric type and for `sql_variant`, in bulk copy as in a query, since a
  zero length is the wire's NULL and the server would store NULL or the
  column's default. An empty string, binary or `xml` value is a value.
* **An `xml` column takes its value's bytes as they are**, so the server
  reads their byte order mark or encoding declaration. An `xml` value
  going into a character column is decoded on the client, which takes
  UTF-8 and a UTF-16 it can identify and refuses any other declared
  encoding; give it `Text`, or `CONVERT` on the server.
* **A `sql_variant` column takes a `RawParam` as declared**, with the base
  type, precision, scale, length and collation the parameter declares. A
  `Text`, `Double` or other Haskell value goes in as its `ToSqlField`
  type, and an `nvarchar(max)` or `ntext` source as `nvarchar(4000)`.
* **A named bulk row addresses a column called `@a` as `@@a`**, since the
  one `@` that `NamedParams` puts before a name is removed, and no more. A
  name matches its column exactly, or case-insensitively when that
  matches one column and one value; two matches are an `EncodeError`.
* **Column discovery reads a view as the server defines it.** A `SELECT *`
  view that isn't schema-bound keeps its old column list after a base
  column is dropped and added back, for `INSERT` too; `sp_refreshview` is
  the application's to run.

### Windows

* **`ProtocolAuto` chooses by what the server has enabled**, so the same
  `ConnectInfo` can travel on Shared Memory on one machine and on TCP on
  another. A host that is this machine is tried over Shared Memory first,
  and a `connectPort` other than 1433 means TCP only
  ([design.md](design.md#connection-lifecycle)). Name the protocol to make
  it fixed. `sys.dm_exec_connections.net_transport` says which one a
  connection used.
* **`ProtocolAuto` ends with Named Pipes, which for another host is
  opened over SMB**, and Windows then authenticates the user running the
  program to that host. It gets that far only when the host refused TCP
  on port 1433. `ProtocolTcp` never does it.
* **A busy pipe is retried for 30 seconds**, and `connect` then fails with
  an `IOException` ("All pipe instances are busy"), so a `connect` over a
  pipe can take that long to fail, as one over TCP to a host that doesn't
  answer can; wrap it in a `timeout` for less. A SQL Server whose pipe
  listener has stopped presents a busy pipe. On the one Windows machine
  measured, the server's pipe listeners stopped for up to 76 seconds at a
  time, after some first connections following an idle spell and while
  the test suite ran, and the server refused some logins outright, for
  Microsoft's client as well
  ([windows-research.md](windows-research.md)). hmssql doesn't retry a
  refused login, over a pipe or over TCP; a pool or a service that must
  ride this out retries the `connect`.
* **Under GHC's native I/O manager, TCP is network's, with its gaps.**
  With network 3.3 and a GHC whose manager network uses (after 9.12.4 or
  9.14.1), hmssql's TCP connections go through network's own calls, as on
  Linux and macOS, and share network's behaviour there
  ([design.md](design.md#platform-workarounds)). Closing these gaps is
  network's and GHC's, and reporting them is on the backlog:
  * A few dozen sockets busy at once through network's `recv` and `send`
    crashed the process
    ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)),
    and hmssql's connections are among them: the test suite over MARS
    crashed that way in three runs of four with GHC master of 2026-11-06,
    and over plain TCP in none of three.
  * A send to a server that has stopped reading blocks in a foreign call.
    A `timeout` or a `cancel` around the request lands only once the
    server has read the whole message, and then cancels the statement
    with an Attention. `close` can wait for that sender until the server
    reads or ends the connection.
  * `connect` to a silent address blocks for Windows's 21 s, which no
    `timeout` shortens, and a host whose first address is silent costs
    that before its next address is tried. A `timeout` around `connect` to
    a host with one silent address then ends with the connect's own
    failure, `TransportFailed` with `WSAETIMEDOUT`, not with `Nothing`.
  * A reset by the server ends the connection with `TransportFailed` when
    it arrives during a receive, with an `IOException` of type
    `InvalidArgument` (errno `EINVAL`), and with `ClosedByServer`, like an
    orderly close, when it arrived before one.

  The pipes go through the manager on the same builds. On a GHC without
  the manager's fix they share the first point, though the probe of 200
  busy pipes didn't crash threaded on plain master, and none of the
  others: a pipe's send is an overlapped operation that a `timeout`
  interrupts, its open is local or over SMB, and a disconnect reads as
  `ResourceVanished`, as on hmssql's backend.
* **Under GHC's native I/O manager, a thread interrupted while it reads a
  file may never come back**, in GHC 9.12.4 and the pre-release
  9.12.4.20260713
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
  hmssql reads its certificate files with interruptions held off, so
  `connect` is not exposed, but an application's own file reads inside a
  `timeout` are.
* **A `timeout` shorter than about 16 ms is not that short.** A wait ends
  at the next tick of the system timer, so a `timeout` of 1 ms took about
  17 ms to fire where it was measured
  ([protocol-notes.md](protocol-notes.md#platform-and-tooling)). This is
  GHC's timer on Windows, and a timeout of a second is as exact there as
  anywhere.
* **With the default I/O manager, a program that calls `timeout` very
  often with a long limit can stall its own timers.** A `timeout` whose
  action returns leaves its delay pending until the limit passes, and once
  tens of thousands of pending delays expire, no timer in the process
  fires for seconds: 2,000 a second with a limit of 15 seconds was enough
  in a program of nothing else
  ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)).
  hmssql starts no timer for a request, so this concerns an application
  that wraps each query in a `timeout`, as gap 1 recommends. Below that
  rate it is harmless, and the native manager is not affected.
* **Without `-threaded`, each pending delay is an operating-system
  thread.** There `threadDelay` runs on a worker of GHC's I/O manager, and
  a `timeout` whose action returns leaves its worker asleep until the
  limit. The pool of workers grows to the most delays ever pending at
  once and never shrinks, so a program that wraps every call in a
  `timeout` of a minute holds about as many threads as it made calls in
  the last minute; the test suite had 5,847 that way
  ([windows-research.md](windows-research.md#the-non-threaded-runtime)).
  hmssql's own pending waits take a worker each too, and its connect sets
  a limit of 4 s on each address but a host's last. The threaded runtime
  has no such pool.
* **Without `-threaded`, a read competes with computation.** A thread
  whose read was waiting is woken at the back of the run queue, behind
  every runnable thread, and each of those takes a time slice of 20 ms. So
  a large result arrives slowly under load: a read of 64 MB that took 2.5 s
  alone took more than 60 s beside fifteen other tests. A program that
  computes while it reads should link with `-threaded`.

## MARS

What a MARS connection (`connectMars`) doesn't do, or does in a way worth
knowing. The rules it follows are in
[design.md](design.md#mars-several-responses-on-one-connection), and how
to use it is in the [guide](../guide/streaming/mars.md).

* **Tested against SQL Server 2017 to 2025 and Azure SQL Database.** The
  MARS tests, and the whole suite over MARS connections
  (`HMSSQL_TEST_MARS=1`), have run against SQL Server 2022 and 2025 and
  Azure SQL Database, and 2022 over TDS 7.4 in the test matrix. Against
  SQL Server 2017 and 2019 the whole suite has passed over MARS without
  the slow tests, in the matrix over TDS 7.4, and on 2019 RTM on Windows
  over TCP and Shared Memory ([testing.md](testing.md#latest-results)).
  hmssql treats a DATA payload that isn't exactly one TDS packet as a
  `ProtocolError`, a rule checked against those servers only: a server
  that split packets, or packed two SMP packets into one TLS record
  (another version, Managed Instance, or a proxy between), would fail
  every MARS connection to it. Azure SQL Database keeps to it
  ([azure-sql.md](azure-sql.md#mars)), apart from ending a connection at
  an early Attention (below).
* **Still one thread at a time.** One lock covers the connection, with no
  lock per stream. Two threads reading two streams of one connection take
  turns, and a thread whose request waits for the locks of a stream open
  on the same connection keeps every other thread from reading that
  stream.
* **A `SET` or a `USE` beside a running stream is undone when the stream
  ends.** Each request starts with a copy of the session's settings and
  writes it back when it ends, so the last request to end decides them:
  the isolation level, `XACT_ABORT`, `NOCOUNT`, `LANGUAGE`,
  `LOCK_TIMEOUT`, `TEXTSIZE`, `DATEFIRST`, `CONTEXT_INFO` and the database
  ([protocol-notes.md](protocol-notes.md#mars-and-smp)). `SESSION_CONTEXT`
  and `#temp` tables are not affected. Change settings with no stream
  open, or in `connectSessionSetup`. hmssql's own transactions and resets
  are not exposed to it
  ([design.md](design.md#mars-several-responses-on-one-connection)).
* **Interleaving, not parallelism.** The server runs one request of the
  connection at a time, so a lock wait, a `WAITFOR` or a statement that
  produces no rows for a while stops every stream. A stream reads 1 to 2%
  slower than on a plain connection, a large parameter is sent about 20%
  slower, and four streams on one connection take about twice as long as
  on four connections read by four threads.
* **Large requests go out four packets per round trip.** The server's own
  receive window stays four packets ahead of what it has consumed,
  whatever the client's, so a large parameter or a bulk load on a MARS
  connection costs a round trip per four packets: about 20% more than a
  plain connection for a 4 MB parameter with 8000-byte packets locally,
  and far more with small packets or over a long round trip (`Bench.Mars`;
  probe 6 measured uploads several times slower than a plain
  connection's at a 45 ms round trip). The cost is the server's window,
  not hmssql's: Microsoft's ODBC Driver 18 pays it too. Measured on
  2026-10-29 from C on macOS (arm64) against a local SQL Server 2025 under
  strict encryption, medians of five rounds, it downloaded a blob at 231
  MiB/s without MARS and 62 MiB/s with it, uploaded at 140 and 59 MiB/s,
  and fetched 1.53 million single rows a second without MARS and 0.62
  million with it. The wait for the window is part of the send, so a
  `timeout` that lands in it breaks the connection, and so ends every
  stream open on it, even when no packet of the request has gone out yet.
  Ending such a message with an Attention instead is on the backlog.
* **Packets of at most 16368 bytes** on an encrypted MARS connection
  (every mode but `EncryptNotSup`); a larger `connectPacketSize` is
  lowered. SQL Server 2025 grants up to 16384 over TLS, and then closes a
  MARS connection at its first response, because a packet and its 16-byte
  SMP header no longer fit one TLS record. Without TLS, 32767 works.
* **A write beside an open scan of the same table**, outside a
  transaction and without `READ_COMMITTED_SNAPSHOT` or snapshot isolation,
  waits for the scan's locks. It ends as a deadlock victim (1205), at
  `LOCK_TIMEOUT` (1222), or, with no lock timeout set, when it is
  cancelled. hmssql doesn't prevent it; a `SET LOCK_TIMEOUT` in
  `connectSessionSetup` makes it error 1222 rather than a hang.
* **Errors 3971 and 3989 are plain `SqlServerError`s.** When an error ends
  the transaction while other streams are open, the server keeps the
  transaction, doomed, until they end, and a request made before they have
  been read or cancelled fails with 3989 (or 3971, with INFO 3926). The
  begin and commit checks keep `withTransaction` clear of them; the body's
  own requests are not. A typed exception is on the backlog.
* **No savepoint API.** `SAVE TRANSACTION` and `ROLLBACK TRANSACTION name`
  batches work, but a rollback to a savepoint while another request is
  unfinished fails with 3981 and loses the whole transaction, and hmssql
  checks for that only before a commit.
* **A transaction can't begin beside an unfinished response**
  (`TransactionRequestsActive`), even when a pending `reset` would have
  cancelled it.
* **Bulk copy beside busy streams** runs five to eight times slower. With
  a result set open on the connection a load fails with 595 unless
  `XACT_ABORT` is on, and inside a transaction a load and a stream over the
  same table fail with 3970 and lose the transaction. Large loads belong
  on a connection of their own.
* **An interruption leaves the drain to the next operation.**
  `cancelResponse`, `cancelActiveStatement` and an ordinary exit of
  `withQueryS` return once the statement is over on the server. An
  interruption (`timeout`, `killThread`) sends the Attention and returns at
  once, and the connection's next request, transaction function,
  `release` or `cancelActiveStatement` reads the rest of the response
  first. Until then the cancelled statement's locks may be held, and its
  INFO messages reach the callback during that next operation. Call
  `cancelActiveStatement` before holding a connection idle after an
  interruption, or when another connection waits on those locks. An
  interruption that lands in a drain breaks the connection. On SQL Server
  2025 an interruption that comes before the statement is under way
  doesn't stop it, and the drain then waits for its end
  ([Interruption and cancellation](#interruption-and-cancellation)).
* **On Azure SQL Database a cancel right behind its request can end the
  connection.** Loaded, the server sometimes reads the request and its
  Attention together and then closes the whole MARS connection, every open
  stream with it ([protocol-notes.md](protocol-notes.md#azure-sql-database)).
  The connection is broken cleanly: the streams and the next request throw
  `ConnectionClosed`, and a pool replaces it; for an interrupted
  `withQueryS` the close surfaces at that next operation. Not planned:
  holding the Attention back would slow every early cancel
  ([design.md](design.md#interruption-and-cancellation)).
* **On Azure SQL Database every open response counts against the
  database's limit of concurrent requests** (30 on Basic, after which the
  next request fails with 10928), and over a long round trip a stream reads
  at most `connectMarsWindow` packets per round trip.

## Open questions

Decisions that were made but could reasonably go the other way. None is
blocking.

**Encryption and connecting**

* Should `EncryptOff` refuse a server that answers ENCRYPT_NOT_SUP, since
  the login, password included and merely obfuscated, then goes in clear,
  and an active attacker can force that answer? It is kept as MS-TDS
  specifies, and documented, because refusing would break servers with
  encryption disabled.
* Should hmssql always send a PRELOGIN inside the strict TLS session, as
  SqlClient does and MS-TDS describes? It sends one only when it needs the
  answer (an access-token login, or MARS), and SQL Server 2025 and Azure
  SQL Database both accept the login without one.
* Should `tlsHostNameInCertificate` be sent as the SNI when `connectHost`
  is an IP address, to help proxies that route by SNI? No SNI is sent for
  an IP address now.
* Should a refused encryption negotiation be an exception of its own
  rather than `ProtocolError`, whose Haddock says the stream "could not be
  interpreted"?
* Is there a way on the server to verify LOGIN7's read-only-intent bit
  outside an Availability Group, through extended events, say?
* Should `connectPinReader`, which puts the reader thread on the
  connecting thread's capability and takes 30 to 40% off a local round
  trip with `+RTS -N` on many cores, be the default? It is off, because a
  pool's connections, opened by one thread, would put every reader on one
  capability.

**Queries and streams**

* Should hmssql parse COLINFO and drop `FOR BROWSE` hidden columns?
* Should `executeStatements` and `runBatchQuery` refuse statements without
  parameters, which they send through `sp_executesql`, where a `SET` or a
  `#temp` table ends with the call, rather than send them? They send them
  now.
* Should a SQL batch over 65535 packets have an exception of its own
  instead of `EncodeError`?
* Running a partly read `queryS` stream value again, instead of the
  continuation `S.splitAt` returns, doesn't start the result again: it
  skips the rest of the result set and yields the rows of the next one,
  or nothing. Should it throw `ResultAbandoned`, as a stream run again
  after its end does?

**Transactions and cancellation**

* Should a `withTransaction` body's own `ROLLBACK` be an accepted way to
  abort without an exception? It ends in `TransactionEndedEarly` now.
* Should an unacknowledged Attention time out and break the connection, as
  Microsoft's drivers do after a few seconds?

**Types**

* Should leap seconds clamp to 23:59:59.9999999, keeping the order of
  timestamps, rather than carry into the next second, keeping elapsed
  time? `TimeOfDay` clamps and `LocalTime` carries now.
