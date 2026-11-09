# Backlog

Work that is intended and not yet done. Nothing else belongs here: what is
done is removed, and what hmssql won't do (integrated authentication or
`Word32` columns, for example) is in [limitations.md](limitations.md),
which also says, for each gap, whether it is on this list.

The sections are by when: what the first release needs, what can come
after it, the reports to file with other projects, and the checks that
came out of test runs and have no deadline.

## Before the release

The first release needs the README's claims to hold, and the public API
settled, since a change to it after the release breaks its callers.

### The public API

A review of the public API against hpgsql listed on 2026-10-31 what would be
expensive to change after the release. The main path is not in question:
`query`, `query1`, `queryMay`, `queryS`, `execute`, `execute_` and their
`With` and `MWith` variants match hpgsql's names and signatures. The
value-streaming rewrite then closed three of the review's items: a large
parameter streams (`ParamValue`'s `ParamLazy` and `ParamStream`, and
`binaryStream`, `textStream` and `streamAs`), a large column value streams
(`streamField`, `queryCells` and the value streams of `Hmssql.Decoding`),
and a lazy parameter is no longer forced whole before it is sent. What is
left is below. An item that asks "whether" is a decision for the owner; the
rest is work.

#### Naming and types

* **`Encryption`'s constructors are named after wire values.**
  `EncryptOff` still encrypts the login, `EncryptNotSup` is the real
  "off", and `EncryptReq` behaves as `EncryptOn` does
  (`Hmssql.Tds.Client`). Names that say what the client does, in the
  style of `Optional`, `Mandatory` and `Strict`, would read better, and
  the wire values can stay in the wire layer.
* **`executeMany` takes `Text`** and returns `[Int64]`, one count per row,
  while the root module's Haddock says every function takes a `Query`,
  and postgresql-simple's `executeMany` returns a total. Decide what it
  takes and returns, and `executeManyOutcomes` with it.
* **`resultSet` and `resultSetMWith` have different shapes.** The first
  gives `ResultSets [r]` and the second `ResultSets (ResultSet r)`.
* **`queryMulti` and `queryResultSets` are hard to tell apart by name.**
  The first gives every result set as `SqlRow`s, the second the typed
  result sets of a `ResultSets`.
* **`Protocol`, the transport,** sits beside the unrelated
  `ProtocolError`, which reads as one of its constructors. `Transport`
  would be clearer (the internal `Transport` of
  `Hmssql.Connection.Internal` would then need another name).
* **`SqlValue`'s constructors follow three naming schemes**: Haskell's
  (`SqlInt32`, `SqlWord8`), .NET's (`SqlGuid`) and SQL's (`SqlDateTime`).
* **Whether the login should be a sum type.** `connectUser`,
  `connectPassword` and `connectAccessToken` allow combinations that fail
  only in `connect`, with an `EncodeError`. A sum type would rule them
  out, and could hold an action that fetches a fresh token for each
  `connect`.
* **Numeric settings in three types**: `connectPort :: Text` (hpgsql's
  port is a `Word16`), `connectPacketSize :: Word32` and
  `connectMarsWindow :: Int`.
* **`bulkTable :: Text` is spliced into SQL unquoted**, into `INSERT BULK`
  and the column query, though `Hmssql.Catalog.ObjectName` exists. See
  also the quoting item under usability.
* **Overlapping names.** `SqlType`, `SqlDataType` and `TypeInfo` describe a
  type three ways, and `Column` (`Hmssql.Catalog`), `ColumnInfo`
  (`Hmssql.Tds.Token`) and `BulkColumn` describe a column three ways. The
  rewrite added `Hmssql.Query`'s `Cell` beside the `Cell` of
  `Hmssql.Tds.Value`. And `connect`, `close` and `release` are generic
  names to import unqualified. Decide which to rename, or say in the
  Haddock which is for what.

#### Consistency with hpgsql

* **`withTransactionLevel level conn` takes the connection second**, where
  hpgsql's `withTransactionMode conn il rw` takes it first. This one is
  worth fixing.
* **A manual `begin` can't set an isolation level** (hpgsql's
  `beginMode`). `beginAtLevel` in `Hmssql.Transaction` does it and is not
  exported.
* **Whether `inTransaction :: Connection -> IO Bool` should be a status.**
  A `Bool` can't say that a transaction is doomed; hpgsql has
  `transactionStatus`.
* **The root module exports no exception**, though its Haddock discusses
  errors, so catching a `SqlServerError` needs a second import. hpgsql's
  root exports `PostgresError`.
* **No row composition** (hpgsql's `(:.)`), so no `Customer :. Order`.
* **No multi-row builder** (hpgsql's `vALUES`). One would have to respect
  SQL Server's limits of 2,100 parameters per request and 1,000 rows per
  table value constructor.
* **No enumeration codecs** (hpgsql's `LowerCasedPgEnum` and its generic
  ones). An enumeration is written by hand with `refineField`.
* **Whether aeson instances belong in hmssql.** hpgsql has `Aeson` and an
  instance for `Aeson.Value`; hmssql has no aeson dependency, and an
  add-on package would keep it so.
* **The tuple instances stop at different sizes**: `ToSqlRow` at 10 fields
  and `FromSqlRow` at 12, where hpgsql's `ToPgRow` stops at 11 and
  `FromPgRow` at 13.
* **No prepared statements** (hpgsql's `preparedStatement` and
  `sqlPrep`). `sp_executesql` caches a plan for each text and declaration,
  so preparing buys little, but neither design.md nor limitations.md says
  so. Record the decision either way.
* **`BatchQuery` returns values** where hpgsql's `Pipeline` returns `IO`
  actions; see `BatchQuery`'s shape under breaking changes.

#### Missing functions

* **A connection string parser and renderer**, for the ADO.NET form
  `Server=...;Database=...` (hpgsql has `parseLibpqConnectionString`).
  It is how most SQL Server deployments carry their configuration.
* **Error predicates** for a deadlock (1205), a unique key (2627 and 2601),
  a foreign key (547) and a lock timeout (1222).
* **`isTransientError` for a `SqlServerError`.** `isTransientLoginError`
  covers only `LoginError`, though the same numbers can come after the
  login. The predicate for a dead connection exists: `unusableReason`.
* **The session ID and the server's version.** Nothing gives `@@SPID`,
  and `TdsContext` keeps the TDS version of LOGINACK but not the server's
  program version, so a `SELECT` is the workaround.
* **`withSavepoint`.** There is no savepoint API, and a nested transaction
  is refused, so nothing composes ([limitations.md](limitations.md#mars)
  has what a savepoint does on a MARS connection).
* **An `IN` list helper**, a list turned into comma-separated `param`s,
  which matters more than for PostgreSQL because SQL Server has no arrays.
* **`resultSet1` and `resultSetMay`**, for the common shape of a count and
  then the rows.
* **Column metadata beside a typed decoder.** A `ResultSet`'s columns come
  through `queryMulti` and `ResultSets`, and a `queryCells` `Cell` carries
  its column, but a `RowDecoder` sees none. Decoding by column name is the
  same question: `RowDecoder` is positional, as hpgsql's is, and whether
  it stays so is to decide.
* **Output parameter helpers.** `outParam` needs a value to declare its
  type, and `procOutputValues` is a list the caller searches by name.
* **Whether to have a query logging or tracing hook.** Only
  `connectOnInfoMessage` exists.
* **Whether named instances over TCP belong in the release.** Reaching
  `host\instance` through the SQL Server Browser is common in enterprise
  installations, and is gap 18 in [limitations.md](limitations.md) with
  LocalDB and the dedicated administrator connection.
* **Table-valued parameters** are planned after the release
  ([below](#table-valued-parameters)), but their place in the API is
  decided now: see the last item of the next list.

#### Breaking changes to decide

* **Explicit parameter types** (gap 2). A Haskell type fixes the wire
  type: `Text` is `nvarchar` and `LocalTime` `datetime2(7)`, so on a
  legacy schema of `varchar` and `datetime` a parameter turns index seeks
  into scans, and an exact comparison with a `datetime` can miss rows. No
  Haskell type sends `smallmoney`, `varchar`, `datetime` or
  `smalldatetime`. `RawParam` needs bytes encoded by hand, and `streamAs`
  declares a type only for a streamed value. `sqlTypeTypeInfo` gives the
  wire type of a declared type such as `varchar(20)`; what is missing is
  the encoding of a value in that type (length, precision, scale, ANSI
  strings, `datetime` and `smallmoney`). Wrappers could come later without
  breaking anything, but how the library fares on such schemas depends on
  them, so they belong before the release. A declared `varchar` type
  would also let the client refuse a character outside the column's code
  page, as bulk copy does, where the server now stores `?`.
* **`BatchQuery`'s shape.** A statement that streams rows from the middle
  of a batch (gap 13) turns the statements after it into `IO` actions,
  which is hpgsql's shape for its pipelines and not today's. Choose that
  shape now, or commit to a second API for it; the feature itself can
  come after the release ([below](#after-the-release)). A large value
  already streams in the middle of a batch through a stream field; a
  stream of rows is what is missing.
* **`SqlServerError` holds one message**, the first ERROR token of the
  response ([design.md](design.md#exceptions)). Decide whether it keeps
  all of them, and check `BACKUP` and `RESTORE`, whose first message may
  not be the useful one.
* **Whether the choice between a batch and an RPC should be explicit.**
  A query without parameters goes as a SQL batch and one with parameters
  through `sp_executesql`, so adding the first `param` changes the scope of
  a `SET` and of a `#temp` table.
* **The open questions in limitations.md that are behaviour contracts.**
  A re-run of a partly consumed `queryS` stream yields nothing; a
  `withTransaction` body's own `ROLLBACK` throws `TransactionEndedEarly`;
  an unacknowledged Attention is waited for forever; `EncryptOff` accepts
  a plaintext downgrade; and a leap second carries into the next second.
  Changing one after the release is a silent break, so settle each, and
  check that the value and cell streams the rewrite added follow the rule
  chosen for `queryS`.
* **No stability boundary.** Every module is exposed, including
  `Hmssql.Connection.Internal` and `Hmssql.Tds.Bytes.Unsafe`, and
  `FieldDecoder (..)` exposes its reader. That fits the owner's preference
  for exposing things, but the documents should say which modules carry
  no stability promise. The rewrite widened that surface with
  `Hmssql.Tds.Parser`'s recipes, the value streams, `Cell`, `Source` and
  `StreamParam`.
* **The layout of the exceptions.** `Hmssql.Errors` says it has every
  exception, but `TransactionError` is in `Hmssql.Transaction`. There is
  no common parent type, and `ProtocolError`, `EncodeError` and
  `UnexpectedResult` carry a `String`. Decide it together with their
  display, under usability.
* **Table-valued parameters and lists.** The planned `ToSqlField` for a
  list of rows would sit beside the `OVERLAPPING` instance for `String`,
  which hpgsql avoids with its `PGArray` newtype; the
  [proposal](#table-valued-parameters) uses a `TableParam` type instead. A
  new `TypeInfo` constructor breaks exhaustive matches, so if `TITable`
  is the way, it should be added before the release.

#### Defaults

* **A `Decimal` parameter declares `decimal(p,s)` from its value**, so
  `1.5` and `1.50` are different declarations with a cached plan each,
  against the reasoning that declares every `Text` as `nvarchar(4000)` or
  `nvarchar(max)` so that a statement compiles once. Measure how much the
  plan cache churns, and decide on a fixed declaration.
* **`Integer` changes its declared type by value too**: `bigint` while
  the value fits, and `decimal(38,0)` beyond.
* **No TCP keepalive.** A dead peer is noticed only when the kernel gives
  up retransmitting, and an idle connection never notices. Setting a
  keepalive is cheap. hpgsql requires a connect timeout; timeouts as
  `ConnectInfo` options are planned after the release
  ([below](#features-on-request)), and adding a field later is additive
  for callers that start from `defaultConnectInfo`.

#### Conversions

These are decisions about conversions that lose or invent information.
What a user should know of them today is in
[limitations.md](limitations.md).

* **`UTCTime` from a column without a zone.** `datetime`, `smalldatetime`,
  `datetime2` and `date` decode into `UTCTime` taken to be UTC, so a
  column filled by `GETDATE()`, which is local time, is silently wrong.
  hpgsql's `Unbounded UTCTime` decoder accepts only `timestamptz`. Taking
  the value as UTC is pragmatic, since `SYSUTCDATETIME()` in a `datetime2`
  is common, but it is the main decision of this list. The other
  direction matches it: a `UTCTime` parameter is sent as a bare
  `datetime2(7)` clock time, the wire type of `LocalTime`.
* **`date` widened to midnight.** `LocalTime` and `UTCTime` accept a
  `date` column, at midnight, while `Day` refuses a `datetime`, so the two
  directions differ.
* **`Bool` accepts only `bit`, while `Int` accepts `bit` too** (gap 9).
* **`SqlValue` doesn't keep a value's type through a round trip.**
  `datetime`, `smalldatetime` and `datetime2` become `SqlDateTime`, every
  character type `SqlText` and both money types `SqlMoney`, and a
  `SqlDateTime` goes back as `datetime2(7)`.
* **`DateTimeOffset`'s `Eq` and `Ord` count the offset**, so one instant
  at two offsets is not equal, unlike SQL Server's comparison of
  `datetimeoffset`.
* **`UUID`'s `Ord` is not SQL Server's.** SQL Server sorts
  `uniqueidentifier` in a byte order of its own, so a list sorted in
  Haskell and one sorted by `ORDER BY` differ. Check the order on a
  server and document it.
* **A `Decimal` output parameter** is declared `decimal(38,10)` (gap 4).
  Check whether a value with more decimal places is silently rounded.

#### Type mappings

* **`Char`** to and from `char(1)` and `nchar(1)`; hpgsql has it.
* **`Fixed E_n`** to and from `decimal`, though `Money` wraps `Fixed E4`.
* **`Scientific` and `Rational`**; hpgsql has both.
* **`CI Text`**, from the case-insensitive package. hpgsql has it, and a
  case-insensitive collation is SQL Server's usual default.
* **`rowversion`** decodes as a `ByteString`; a `RowVersion` newtype or a
  `Word64` would be clearer.
* **`sql_variant`** decodes only as `SqlValue` (gap 9).
* **`json` and `vector`** (SQL Server 2025) arrive as `nvarchar(max)` and
  `varchar` ([protocol-notes.md](protocol-notes.md#data-types)). Check how
  they behave as parameters, and whether to plan their native types on
  the wire.

#### Usability

* **Displaying an exception.** `displayException` falls back to the
  derived `Show` for most of hmssql's exceptions, so a refused login
  prints as `LoginError (ServerMessage {msgNumber = 4060, ...})`. Only
  `LoginRedirected`, `MarsNotSupported`, `ConnectionClosed`, `SevereError`
  and `TransactionError` define it; `SqlServerError`, `LoginError`,
  `ProtocolError`, `ConnectionBroken`, `ResultAbandoned`,
  `ReentrantCallback`, `ReentrantSource`, `ConnectionReleased`,
  `DecodeError`, `EncodeError` and `UnexpectedResult` don't. Decide all of
  them together, and add a `loginErrorMessage` beside `sqlErrorMessage`
  so that printing a refusal's text needs no unwrapping.
* **Quoting one identifier as `Text`.** `escapeIdentifier :: Text -> Query`
  is public, so `"CREATE DATABASE " <> escapeIdentifier name` works, but a
  setting that takes `Text`, such as `bulkTable` or `connectSessionSetup`,
  can't use a `Query`, and `objectNameSql` quotes only a schema and a
  name. The same bracket quoting is written three times, as `Catalog`'s
  private `quote`, `BulkCopy`'s `quoteName` and `escapeIdentifier`. Export
  one `quoteIdentifier :: Text -> Text`, have the three use it, and point
  to it from `Hmssql.Catalog`'s Haddock.
* **Building a `SqlType`.** `SqlType TyNVarChar (LengthArg (Length 36))` is
  long for code that declares a whole schema. Builders such as
  `nvarchar 36`, `nvarcharMax`, `varbinary`, `decimal 10 2` and
  `datetime2 7` are additive. Names like `decimal` and `time` collide on
  import, so decide between a module meant to be imported qualified and
  prefixed names. An argument out of range stays `sqlTypeProblem`'s to
  report, as for a type built by hand.

#### The API the rewrite added

`ParamValue`, `Source`, `StreamParam`, the value streams of
`Hmssql.Decoding`, `Cell` with `CellValue` and `RowCells`, `queryCells`,
`streamField`, `ReentrantSource` and the exports of `Hmssql.Tds.Parser`
came after the review, and have not had one of their own.

### Windows

hmssql builds on Windows and connects over Shared Memory and Named Pipes
as well as TCP, with the threaded runtime and without it, under GHC's
default I/O manager and its native one. The whole suite has passed there
over all three ([testing.md](testing.md#latest-results)). What is left:

* **The scripts.** `scripts/test-matrix.sh` and the Azure scripts have not
  been tried on Windows; `scripts/perf-compare.sh` runs there.
* **The suite where it hasn't run on Windows**: with the slow tests over
  the pipes and over MARS, and the matrix's packet sizes and session setup
  against SQL Server 2025 (under [Checks to revisit](#checks-to-revisit)),
  and at its usual concurrency over a pipe. Over the pipes it runs one
  test at a time, because the server's pipe listeners stopped under it on
  build 17.0.1000.7; a few whole runs on the later builds met no stop
  ([windows-research.md](windows-research.md), "The server's pipe
  listeners").
* **What no Windows run has covered**: a named instance, a pipe on
  another machine over SMB, and TCP to a server on another machine
  ([windows-research.md](windows-research.md#not-verified)).
* **The minimum GHC for the native manager.** Under the native manager,
  with network 3.3 or later, TCP goes through network's calls and the
  pipes through the manager. Every GHC so far crashes there under a few
  dozen busy sockets and freezes the non-threaded runtime; the GHC branch
  `wip/winio-completion-packets` fixes both, and is to be submitted
  ([below](#upstream-reports)). Once a release has the fixes, name it as
  the minimum for the native manager in [limitations.md](limitations.md)
  (gap 17) and in `Protocol`'s Haddock, and check that the two upstream
  repros pass on it.

### The test matrix and the other platforms

* **The test matrix since the rewrite.** The whole default matrix last ran
  on 2026-10-25, on every GHC in `tested-with` against SQL Server 2017 to
  2025 ([testing.md](testing.md)), before the value-streaming rewrite,
  the two optimization runs and the Windows work. Run it again. On GHC
  9.14.1 the strict binding of a `SqlRow`'s column recipes guards against
  its floating, and only code size was measured there after the rewrite
  ([value-streaming-research.md](value-streaming-research.md#not-verified)).
  The run also answers whether `Protocol.Fuzz`, with its responses in
  one-byte packets, is still slow under load with the reader recipes.
* **Linux and macOS since the Windows work.** The changes of 2026-11-06
  and 07 touched `backendSendMany` on every platform. The suite last ran
  on Linux on 2026-11-05 (5,991 examples, 70 pending) and on macOS on
  2026-10-25.
* **macOS on the current snapshot.** The last macOS build was on Stackage
  `nightly-2026-09-27`; `nightly-2026-11-03` has been built on Linux and
  Windows only. The run above can be on it.

## After the release

### The documentation site

* **Take the Haddock off the site.** The copy under `api/` on GitHub Pages
  is for reviewing hmssql before it is on Hackage. Once Hackage has it,
  remove `api/` from `site/build.sh` and point the guide's links at
  Hackage's latest version (`https://hackage.haskell.org/package/hmssql/docs/...`),
  so that search engines find one copy of the reference.

### Performance and code size

**The rest of the gap against the original row walk.** The last pass
against the implementation before the value-streaming rewrite, on
2026-11-04 after the code-size run, measured Live at 1.01 in time, Mars
1.03, Mock 1.11 and Decode 1.38 (the `Decode.*.rows` and `.tokens` cases
aren't like for like). The per-type decoders and the second optimization
run have improved Mock and Decode since, but no pass against the original
has run since them
([value-streaming-research.md](value-streaming-research.md#where-it-stands)).
Run one. If a gap remains without a socket, two ideas are not yet tried,
within safe and idiomatic Haskell:

* **The table of boxed positions** saves unknown calls their allocation,
  but costs Decode two dependent loads per lookup in a table of 98 to
  192 KB: without it, Decode was 0.92 in time and Mock 1.03, with 6% and
  14% more allocation. A static table of `I#` closures addressed by
  arithmetic (it needs `addrToAny#` and 64 to 128 KB of `.data`), or boxes
  only where a call is known to be cold, may keep the allocation without
  the loads. A table half the size was measured and rejected.
* **An index into a `ByteArray#`** for the parser's input. The input as
  its three unboxed `ByteString` fields was measured and rejected.

`peekToken` inlined, with its wait out of line, was tried on 2026-11-04
and gave nothing. The directions measured and rejected, not to be
repeated without a new reason, are in
[value-streaming-research.md](value-streaming-research.md) and
[performance-research.md](performance-research.md).

The rest of the performance and size work:

* **Code size on macOS and Windows.** `scripts/code-size.sh` and the
  linked-program measurements ran on Linux only; `ld64` with
  `-dead_strip` on macOS and the linker on Windows, where split sections
  behave differently, were not measured
  ([performance-research.md](performance-research.md#not-verified)).
* **One description of a value held in memory.** The poked bulk row
  describes a non-PLP cell with `cellFrame`, beside `writeValue`, and
  `Wire.BulkPacketsSpec` pins the two together
  ([design.md](design.md#reading-and-writing-bytes-which-layer)). Derive
  `writeValue`'s in-memory cases from `cellFrame`, and measure `Encode`
  before and after, because RPC parameters share `writeValue`.
* **Very wide suspended decoders.** A wide applicative decoder that
  suspends at the end of a packet traverses its pending binds. Measure
  that traversal at small packet sizes before adding any specialization
  for it ([limitations.md](limitations.md#behaviours-to-know-about)).
* **The issuer's cost on Windows.** On hmssql's own backend every
  operation is handed to one bound thread, which costs about 36 µs a round
  trip. If that matters, a C function or a completion port of hmssql's
  own are the alternatives
  ([design.md](design.md#platform-workarounds)), and the native manager is
  the way out for a program that can opt in.
* **A setting for the TLS cipher suites**, so that a client on a
  processor crypton has no accelerated AES for (Apple silicon with
  `crypton` 1.1.5) can offer ChaCha20-Poly1305 alone and have the server
  take it ([limitations.md](limitations.md)). To measure first: whether a
  later `crypton` accelerates AES on ARM, what SQL Server on Windows and
  Azure SQL Database accept, and what a Linux client on x86 gains or loses
  by it.

### Features on request

On request, as the need arises; contributions welcome.

* **Streaming output parameters.** A RETURNVALUE is read with the common
  value recipe but held in memory; streaming it needs a continuation-based
  `ProcResult`.
* **Comparisons with SQL Server clients in other languages** (SqlClient,
  JDBC, pyodbc and tiberius): the benchmark suite's `Live` group against
  the same server, for the README's claim of speed.
* **Typed stored-procedure calls**: a `callProcedureWith :: ResultSets a ->
  ...` that decodes the result sets into row types and still returns the
  output parameters ([limitations.md](limitations.md), gap 3).
* **Timeouts as `ConnectInfo` options**: a connect timeout, a command
  timeout, and a bound on the wait for an Attention's acknowledgement
  (gap 1). All are `timeout` around the existing calls; the option would
  spare each caller the wrapper. Beside them, an opt-in for connecting to
  a host's addresses in parallel and keeping the first that accepts, as
  SqlClient's `MultiSubnetFailover` does for an availability group
  listener; today the addresses are tried one after another, each but the
  last for 4 seconds ([design.md](design.md#connection-lifecycle)).
* **A `BatchQuery` statement that streams from the middle of a batch**
  (gap 13): the statements after it become `IO` actions to be run in
  order on one thread, hpgsql's rule for its pipelines. A scoped
  `batchQueryS`, which cancels a stream left open on a MARS connection,
  can come with it ([design.md](design.md#queries)). The shape is to be
  chosen before the release ([above](#breaking-changes-to-decide)).
* **An explicit transactional-batch API**: the `BEGIN TRANSACTION` sent
  with the body's first batch, saving a round trip per transaction (gap
  16). The implicit form was tried and undone
  ([design.md](design.md#transactions)); the second review asked for an
  explicit one, where the caller says the first batch may carry it.
* **Table-valued parameters**, [below](#table-valued-parameters).
* **Enhanced routing** (MS-TDS ENVCHANGE type 21, feature extension
  ENHANCEDROUTINGSUPPORT, 0x0F): a redirect that also names the database
  to open, overriding `connectDatabase`. Azure SQL Hyperscale's reader
  endpoints use it to spread read-only logins over named replicas whose
  databases have names of their own
  ([dotnet/SqlClient#3641](https://github.com/dotnet/SqlClient/issues/3641);
  SqlClient 7.0 requests it on every login). The work: request 0x0F in
  LOGIN7, record the server's FEATUREEXTACK (as for UTF-8 support, 0x0A),
  parse type 21 (the field list, with AlternateDatabase, not the grammar
  line, which leaves it out), and have the redirect loop set the database
  from it only when the server acknowledged the feature. Only a Hyperscale
  database with named replicas can test it for real. Until then a reader
  endpoint's behaviour with a client that doesn't request it is unknown.

### MARS

* **MARS at Azure SQL Database's request limit, and over its round
  trip.** The whole suite passes there over MARS connections
  ([azure-sql.md](azure-sql.md#mars)), but nothing in it reaches the
  database's limit of concurrent requests: through hmssql, a request
  refused with 10928 (class 20) must leave the connection usable, which
  only the spike's probe has shown. Nor has the default window been
  measured over a round trip longer than the region's.
* **MARS windows above 64 over a WAN**, and the ACK cadence at 64 there.
  Window 64 was measured locally and at a 45 ms round trip (where 16 read
  at a quarter of a plain connection's rate); nothing larger was tried
  over a long round trip, where it might pay for itself.
* **Typed exceptions for errors 3971 and 3989** on a MARS connection: a
  request made after an error ended the transaction while other streams
  were still open ([limitations.md](limitations.md#mars)). They surface as
  `SqlServerError` today.
* **Descriptor-aware clearing of the transaction descriptor**, as
  hardening: a commit or rollback ENVCHANGE would clear the tracked
  descriptor only if it names the current one. Which descriptor each
  carries (the second rollback after 3998, the one in an Attention's
  acknowledgement, the one before a reset acknowledgement) was never
  recorded; the begin and commit checks keep the order right without it
  ([design.md](design.md#transactions)).
* **Recovering an interrupted multi-packet request on a MARS connection.**
  A request longer than the server's window (4 packets) waits for the
  window every four packets, so a `timeout` around a large `execute` or a
  bulk load is likely to land in such a wait, where nothing is half
  written on the wire; today it breaks the connection all the same, every
  open stream with it (the rule "any exception out of a send breaks the
  connection", [design.md](design.md#interruption-and-cancellation)). The
  server accepts an Attention on the session of a message cut short (the
  bulk-copy probe), so the message could be ended with one at a packet
  boundary and the connection kept, at the cost of a new state (a session
  whose request is half sent) and its tests. Over a WAN, where the wait
  is most of a large request's time, it would matter most.
Server behaviour on a MARS connection that has not been probed:

* The doom of a transaction by a cancelled stream under `XACT_ABORT ON`
  when the stream is an RPC (`sp_executesql`) rather than a batch. The
  probes and the library's tests of it used batches.
* A statement other than a `SELECT` as the open response, such as a
  stored procedure, `UPDATE ... OUTPUT` or a cursor, for the commit check
  and the lock behaviour.
* That a BULK LOAD message sent on another session than its `INSERT BULK`
  is refused, and what the server then does with the first. hmssql keeps
  a load on one session.
* Whether anything but a nested begin leaves `@@TRANCOUNT` above 1
  without a descriptor change the client sees, which
  `TransactionStillOpen`'s wording assumes.
* An Attention's wait for a slot in the server's window over a long round
  trip (Azure, or a WAN), where it should take at most one round trip, or
  beside anything but a lock wait that might stop the server taking a
  session's request in, such as a memory grant or log growth.

### Table-valued parameters

A proposal written before the value-streaming rewrite and brought up to
date with the current encoding types. It asks
hmssql to send a table-valued parameter (TVP): an RPC parameter whose value
is a set of typed rows, declared in `sp_executesql`'s `@params` as a
user-defined table type (`@p1 dbo.KeyList READONLY`) and read by the
statement as a table. Output TVPs don't exist in the protocol. Today hmssql
has no type for one, and a caller can send one only by writing the whole
RPC through `Request`, which was measured to work on SQL Server 2025
([protocol-notes.md](protocol-notes.md#rpc-and-stored-procedures)).
`readTypeInfo` refuses the type 0xF3, and that refusal stays, because the
server never sends a TVP in COLMETADATA or RETURNVALUE (MS-TDS 2.2.5.5.5).

#### Why

The case is a statement given about 1,000 rows of (ordinal, key), which
it joins to a table by the key and orders by the ordinal. Without a TVP
the rows go as an `nvarchar(max)` JSON parameter, read with `OPENJSON(@p)
WITH (ord int '$[0]', id uniqueidentifier '$[1]')`, and SQL Server plans
the statement on `OPENJSON`'s fixed estimate of 50 rows. Two workarounds
were measured, a temporary table filled per batch and a table variable:
both cost an extra round trip, an extra `INSERT` and a recompile per
execution, and read 4 to 11% more pages. A TVP is the one candidate not
yet measured. That plan's cost was dominated by other operators, so what
to expect is the JSON overhead gone and a correct estimate, both to be
measured. An (int, uniqueidentifier) row is about 45 characters of
JSON, 90 bytes in UTF-16 that the client escapes and the server parses; as
a TVP_ROW it is 23 bytes, already binary (the token, an IntN of 1+4 bytes
and a GUID of 1+16, by arithmetic).

The other ways to pass a set of values hit limits:

* Scalar parameters stop at 2,100 per request, so 1,000 pairs take 2,000,
  and the `@params` declaration, part of the plan cache's key, changes
  with the list's length, so each length compiles its own plan unless the
  lists are padded.
* A literal `IN` list is compiled afresh for every length, and slowly at
  thousands of values.
* A table value constructor (`INSERT ... VALUES`) takes at most 1,000 rows.
* XML through `nodes()` costs a heavier parse than JSON, and its row count
  is the optimizer's guess too.
* `STRING_SPLIT` gives one string column per list, so a pair needs two
  lists or an encoding inside each value; its ordinal argument came in SQL
  Server 2022; values are typed only by a `CAST`; and its row count is a
  guess.
* A temporary table filled by bulk copy gets real statistics, but takes
  several requests (create, load, statement and drop) instead of one RPC,
  and on a MARS connection a load beside an open result set fails with
  error 595 unless `XACT_ABORT` is on.

SQL Server's documentation of TVPs lists fewer round trips, strong typing,
no locks for the initial population from the client, and plan caching
like a temporary table's since SQL Server 2012, and recommends them over
bulk copy for fewer than about 1,000 rows. It also says that SQL Server
keeps no statistics on a TVP's columns, which bounds what the optimizer
can know.

#### The API

The parameter API stays as it is, so a TVP goes through `param`,
`mkQuery`, `NamedParams`, `executeStatements` and
`inParam`/`callProcedure` unchanged. A parameter is an `EncodedParam`,
which is `(TypeInfo, ParamValue)`. The wire layer (`Hmssql.Tds.TypeInfo`)
gains the type and its columns:

```haskell
data TvpColumn = TvpColumn
  { tvpColumnType :: !TypeInfo        -- an N type or a big type (below)
  , tvpColumnNullable :: !Bool        -- fNullable
  , tvpColumnServerDefault :: !Bool } -- fDefault: no data sent for it
data TvpInfo = TvpInfo                -- DbName is always empty
  { tvpSchema :: !Text, tvpTypeName :: !Text, tvpColumns :: ![TvpColumn] }
data TypeInfo = ... | TITable !TvpInfo  -- 0xF3, parameters only
```

`writeTypeInfo (TITable t)` writes the type byte, TVP_TYPENAME,
TVP_COLMETADATA and the TVP_END_TOKEN that ends the optional metadata.
`typeInfoSqlName` gives `[schema].[name] READONLY` for the declaration,
quoted as `escapeIdentifier` quotes, and `outParam` refuses a TVP.

The rows are a new `ParamValue` constructor, whose case in
`writeParamValueWith` writes `*TVP_ROW TVP_END_TOKEN` to the
`PacketWriter`. Since `writeRpcRequests` already writes an RPC packet by
packet for a streamed parameter, the rows can come from a list or from a
`Source` of rows at no extra cost, and a streamed TVP follows the rules of
any `Source`: it must not make a request on its own connection
(`ReentrantSource`), and a source that throws abandons the request and
leaves the connection usable. The alternative is the rows encoded into
`ParamBytes` behind a new `LengthKind` that writes them verbatim. It is a
smaller change, but it holds the rows in memory (100,000 rows of
`dbo.KeyList` are about 2.3 MB) and makes `ParamBytes` mean more than one
value; with `ParamValue` a sum type since the rewrite, the constructor is
the likelier choice.

The user layer is a new module, `Hmssql.TableParam`, re-exported by
`Hmssql`:

```haskell
data TableType = TableType
  { tableTypeSchema :: !Text, tableTypeName :: !Text, tableTypeColumns :: ![TvpColumn] }
-- | A table type's columns from sys.table_types and sys.columns, in one
-- query whose result is kept, as describeBulkColumns does for a table.
describeTableType :: Connection -> Text -> IO TableType
data TableParam
tableParam :: ToSqlRow r => TableType -> [r] -> TableParam
tableParamSource :: ToSqlRow r => TableType -> Source r -> TableParam
instance ToSqlField TableParam
```

Each row is encoded by its `ToSqlRow` instance, and each cell converted to
its column's type by the rules `encodeBulkCell` applies to bulk copy, so
an `Int` (alone a `bigint`) fills an `int` column. `encodeBulkCell` takes a
`BulkColumn`, which has the name, type and nullability a TVP column needs,
but no fDefault; it would take a type and a nullability instead, or a TVP
column would be a `BulkColumn` with the flag beside it. A value the column
can't take is an `EncodeError` naming the row and the column, before
anything is sent for a list, and at that row for a source. `Nothing ::
Maybe TableParam` is an `EncodeError`, since a TVP is never NULL, unless
the second open question below makes it the default TVP. For `CREATE TYPE
dbo.KeyList AS TABLE (ord int NOT NULL, id uniqueidentifier NOT NULL)`:

```haskell
keyList <- describeTableType conn "dbo.KeyList"
-- or, with no round trip:
-- keyList = TableType "dbo" "KeyList" [TvpColumn (TIIntN 4) False False, TvpColumn TIGuid False False]
let keys = zip [1 :: Int32 ..] ids :: [(Int32, UUID)]
rows <- query conn $ "SELECT i.name FROM " <> param (tableParam keyList keys)
                       <> " AS k JOIN dbo.item AS i ON i.id = k.id ORDER BY k.ord"
-- sp_executesql N'SELECT ... FROM @p1 AS k ...', N'@p1 [dbo].[KeyList] READONLY', <TVP>
```

#### The wire format

The specification is MS-TDS 2.2.5.5.5, "Table Valued Parameter (TVP)
Values", with 2.2.5.5.5.1 "Metadata", 2.2.5.5.5.2 "Optional Metadata
Tokens" and 2.2.5.5.5.3 "TDS Type Restrictions"; 2.2.6.6, "RPC Request";
2.2.7.24, "TVP_ROW"; and the example 4.14, "TVP Insert Statement". From
2.2.5.5.5.1 and 2.2.5.5.5.2:

```
TVP_TYPE_INFO   = %xF3 TVP_TYPENAME TVP_COLMETADATA [TVP_ORDER_UNIQUE] [TVP_COLUMN_ORDERING]
                  TVP_END_TOKEN *TVP_ROW TVP_END_TOKEN            ; TVP_END_TOKEN = %x00
TVP_TYPENAME    = DbName OwningSchema TypeName                    ; B_VARCHARs
TVP_COLMETADATA = TVP_NULL_TOKEN (%xFFFF) / (Count <Count> TvpColumnMetaData)
TvpColumnMetaData = UserType (ULONG) Flags (USHORT) TYPE_INFO ColName (B_VARCHAR)
TVP_ROW         = %x01 *TvpColumnData      ; a TYPE_VARBYTE per non-default column
```

2.2.6.6 puts `(TYPE_INFO / TVP_TYPE_INFO)` in ParamMetaData and requires
fByRefValue and fDefaultValue to be zero for a TVP. ParamLenData is empty:
in example 4.14 the parameter ends with the second 0x00.

* **TVP_TYPENAME.** DbName must be empty, so the type is in the current
  database. OwningSchema and TypeName are at most 128 characters each,
  which `typeInfoProblem` checks before sending, as it checks an XML
  schema's names.
* **TVP_COLMETADATA** has COLMETADATA's column layout (2.2.7.4) with
  fDefault (0x0200) added, and ColName must be empty. Bulk copy's
  `colMetaData` writes UserType, Flags, the TYPE_INFO and the name; the
  TVP's is the same loop with an empty name and the flags fNullable
  (0x0001) and fDefault (fCaseSen, usUpdateable and fFixedLenCLRType are
  ignored on input). Count is 1 to 1024.
* **TVP_ROW** is bulk copy's ROW with the token 0x01 in place of 0xD1, so
  bulk copy's `writeRow` serves with the token as an argument: a row of
  cells in memory and none PLP is poked through `cellFrame` and
  `unsafeWriteSized`, and any other goes through a Builder of `bulkValue`.
  The counted size and the poked bytes then can't disagree.
* **The column types allowed** (2.2.5.5.5.3). The legacy fixed types are
  refused in favour of their N forms: Bit by BitN, Int1 to Int8 by IntN,
  Float4 and Float8 by FloatN, Money and Money4 by MoneyN, and DateTime and
  DateTime4 by DatetimeN. The null type 0x1F and a TVP inside a TVP are
  refused too. hmssql's encoders already produce N types (`TIIntN 4` for
  `Int32`), so a `tvpColumnProblem` refuses `TIBit`, `TIInt1` to `TIInt8`,
  `TIFlt4`, `TIFlt8`, `TIMoney4`, `TIMoney8`, `TIDateTime4`, `TIDateTime8`,
  `TINull`, `TITable` and `TIUdt`. `TIText`, `TINText` and `TIImage` are
  not on the specification's list, but hmssql should send the `(max)`
  types instead and refuse them.
* **NULLs** are the column type's own NULL, as `writeValue` writes it for
  each length kind, allowed only under fNullable and refused on the client
  otherwise.
* **Default columns.** A column with fDefault has no TvpColumnData in any
  row, and the server fills it. That is how an identity, computed or
  `DEFAULT` column of the type is left to the server. TVP_ORDER_UNIQUE
  (0x10) may not name such a column. TVP_COLUMN_ORDERING (0x11) reorders
  the columns within a row, for example to send a `(max)` column last.
  Neither optional token is needed in a first version.
* **PLP for the `(max)` types.** The bulk row parser refuses the
  known-length PLP total and wants the unknown-length form in chunks of
  at most 8000 bytes (`bulkPlp`), and an RPC parameter takes the
  unknown-length form as well
  ([value-streaming-research.md](value-streaming-research.md)), so
  writing a TVP's PLP cells as `bulkPlp` does is the likely choice.
  Whether the TVP row parser also takes the known-length form is the
  fourth open question.
* **Collation.** A character column's TYPE_INFO carries a collation.
  hmssql's parameters send `Collation 0 0`, harmless for `nvarchar`, whose
  bytes are UTF-16. A `varchar` column is either sent as `nvarchar` for the
  server to convert, as `bulkWireType` does for bulk copy, or with the
  column's collation from `sys.columns` (the third open question).
* **The TDS version.** A TVP needs TDS 7.3 or later, and a server must
  refuse one from an older client. hmssql negotiates only 7.4 and 8.0
  (`TdsVersion` in `Hmssql.Tds.Context`), so no gate is needed.
* **A type the server doesn't have.** For an ad hoc statement without
  enough type information, the RPC fails before it runs (2.2.5.5.5.1).
  Through `sp_executesql` the declaration names the type, so the expected
  result is an ordinary `SqlServerError` on the declaration, likely error
  2715 ("Cannot find data type"), with the connection still usable. That
  number, and the error for a type the login lacks EXECUTE or REFERENCES
  on, are for the tests to pin and protocol-notes.md to record.
* **Checks before sending**, as design.md's "What the wire can't carry is
  refused before anything is sent" requires: a column count of 0 or over
  1024, a name over 128 characters, a type not allowed, a row of the wrong
  width, and a cell that can't be converted are each an `EncodeError`.

#### Tests to write

* The bytes of MS-TDS example 4.14 as a golden test, and a poked row's
  counted size against its bytes, as for the bulk rows.
* A round trip of every type `ToSqlField` sends, in a one-column table
  type, nullable and not, with a NULL in each nullable one, against SQL
  Server 2017 to 2025. The differential suite's random tables can generate
  table types the same way.
* An empty TVP, the columns with no rows: `SELECT COUNT(*) FROM @p1` is 0.
* `(max)` columns: `nvarchar(max)` and `varbinary(max)` values of 0, 8000,
  8001 bytes and several MB, in both PLP forms, recording which the server
  accepts.
* A large TVP, 100,000 rows of `dbo.KeyList` from a list and from a
  source, with the client's residency checked as the `Scale` tests check
  bulk copy's.
* A TVP joined inside `sp_executesql`, and the showplan's estimated rows
  for its scan at 1,000 rows, against `OPENJSON`'s for the same rows.
* A table variable filled from one (`DECLARE @t dbo.KeyList; INSERT @t
  SELECT * FROM @p1`), and a procedure called with one through
  `callProcedure`.
* A type with an identity column and a `DEFAULT` column, sent with
  fDefault.
* The errors: an unknown type, a type without permission, a column count
  or type that doesn't match, and the client's `EncodeError`s, each
  followed by a query on the same connection, and the same on a MARS
  connection and in `executeStatements`.

#### Open questions

1. **An untyped TVP through `sp_executesql`.** 2.2.5.5.5.1 allows all
   three TVP_TYPENAME strings to be empty when the server knows the
   parameter's type (a procedure's or a function's parameter), and
   requires enough type information for an ad hoc statement. Whether the
   server resolves an empty name from `@params` is not stated and was not
   tested. Until a probe says otherwise, hmssql always sends the schema
   and the name.
2. **`TVP_NULL_TOKEN`** (0xFFFF in place of the column count) has no prose
   in the specification. Is it the default, empty TVP that a procedure
   called without its TVP parameter gets today, and does `sp_executesql`
   accept it?
3. **Metadata that differs from the type.** Does the server convert a
   column sent as `nvarchar` into the type's `varchar` column, or a
   `bigint` into an `int`, or refuse it? The answer decides whether
   `describeTableType` is needed for correctness or only for convenience,
   and how `varchar` columns and their collations are sent.
4. **The PLP form** the TVP row parser accepts: the unknown length in
   chunks of at most 8000 bytes, as bulk copy needs, the known-length form
   of an RPC parameter, or both.
5. **TVP_ORDER_UNIQUE.** Does the server verify the declared order and
   uniqueness, and does the optimizer use them? If so, an option on
   `TableType` may follow.
6. **The error numbers** for an unknown type, a missing permission and a
   row that doesn't match the metadata, and whether any of them is a
   protocol error that ends the request differently from an ordinary
   error.
7. **The estimate.** The row count at compile time, a cached plan reused
   for TVPs of other sizes, and the missing column statistics should be
   measured against the `OPENJSON` form before anyone claims a gain.
8. **The representation**: a `ParamValue` constructor for the rows, or the
   rows in `ParamBytes` behind a new `LengthKind` (see the API above).

## Upstream reports

Bugs and gaps found in other projects, each with what a report needs.
None is filed yet, unless it says so.

* **GHC's native I/O manager on Windows.** A few dozen busy sockets crash
  it ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)),
  and a thread killed during a file read may never end
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
  Without `-threaded`, an interrupted `recv` on a socket then closed froze
  the runtime at the next socket's first operation, and `accept` crashed
  it, because `asyncDoProc`'s workers were never started under that
  manager ([protocol-notes.md](protocol-notes.md#platform-and-tooling)).
  The GHC branch `wip/winio-completion-packets` (2026-11-06 and 07) fixes
  the crash and both faults of the non-threaded runtime, with three more
  of the manager's ([windows-research.md](windows-research.md), "The
  manager fixed on a GHC branch"), and is to be submitted with the
  reports. Since 2026-11-06 hmssql's TCP under that manager is network's
  own calls, which gives the reports a real use case. Before submitting,
  run both repros (`ManyConnections.hs` and `KilledRead.hs`) on the
  branch: the suite stopped crashing and freezing there, but the repros'
  own results on it were not recorded, and for the file read the branch's
  change only fits the supposed cause.
* **GHC's default I/O manager on Windows**: tens of thousands of pending
  delays stall every timer in the process for seconds
  ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)).
* **GHC's kqueue I/O manager on macOS**: a failed `closeFdWith` leaves the
  descriptor open and the manager's bucket locked
  ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)).
  Before filing, search the tracker, and check GHC #21969 and whether the
  fix of the stale registration was backported to 9.10 and 9.12.
* **network on Windows under the native manager.** Three gaps, measured
  with network master `1f6aa85` ([design.md](design.md#platform-workarounds)):
  `sendMany` is a `WSASend` without an `OVERLAPPED`, which nothing
  interrupts; `connect` is a blocking call, where a `ConnectEx` through the
  manager would be interruptible; and `recvBuf`'s completion callback
  doesn't map `ERROR_NETNAME_DELETED`, so a reset during a receive is an
  `InvalidArgument` with errno `EINVAL`, while a `WSAECONNRESET` reads as
  the end of the stream. Beside them, network's open pull request 628
  is still needed: without it, network's `configure` writes a
  `test-suite` section into `network.buildinfo`, which the Cabal of
  cabal-install 3.18 refuses, so network's repository doesn't build with a
  compiler that turns its native-manager code on. And a fix of
  `recvBufMsg`, which hmssql doesn't use, is on a local network branch,
  `winio-recvmsg-more-data`, to be submitted.
* **Azure SQL Database** ends a whole MARS connection when it reads a
  request and the Attention that cancels it together, under load
  ([upstream/azure-sql-early-attention](upstream/azure-sql-early-attention/README.md)).
* **tls's dependency on serialise**, about 5.5 MB of an unsplit link that
  a client never calls. A proposal and its reproduction are drafted
  ([upstream/tls-session-code-size.md](upstream/tls-session-code-size.md)).

## Checks to revisit

Low-priority checks that came out of a run and have no deadline. None of
them is known to be a defect of the library. Each says what was seen, and
what would settle it.

* **A test process killed at 16 GB, once.** In the matrix run of
  2026-10-05 one test process (GHC 9.8.4, SQL Server 2025, `mars+slow`)
  was killed by Docker for its memory, 46 minutes after its report stopped
  at the slow `Differential.Encode` property and two minutes after the
  server had run out of memory
  ([protocol-notes.md](protocol-notes.md#the-server-under-load)). A server
  that stops answering is ruled out: a request waiting on one keeps the
  client's memory and CPU flat on every transport, before the response or
  part-way through it, and so does a `timeout` loop on the stalled
  connection ([design.md](design.md#memory-and-performance)). The likely
  cause was in the suite and is fixed: a property whose case failed once,
  as one would when the server refused a request with error 701, made
  hedgehog try every smaller case of it, keeping each in memory, which for
  a random table is tens of thousands of cases and gigabytes
  ([bugs-found.md](bugs-found.md#in-the-test-suite)). The run's log was
  lost, so that is not confirmed; the matrix of 2026-10-25 ran `mars+slow`
  on GHC 9.8.4 against all four servers without a recurrence. What would
  tell next time: have `scripts/test-matrix.sh` keep each run's `+RTS -s`
  summary and a heap profile by type (`-hT`, which needs no profiling
  build).
* **`Resources.ConnectTimeout`'s process handle count, without
  `-threaded` under the default manager over a pipe.** In the whole suite
  against SQL Server 2019 over Shared Memory or Named Pipes, the first
  test's whole-process count grew by 270 to 360 handles across its sweep,
  in 3 runs of 6 with GHC master's branch of 2026-11-07, and in 2 of 2
  before the pipes moved to the native manager, so not by that change.
  Its exact count of hmssql's own handles passed every time, and the group
  alone passed 4 times in 4. The suspect is the default manager's worker
  pool, which grows with pending `timeout`s and never shrinks
  ([testing.md](testing.md#on-windows)). Counting the process's threads
  beside its handles would settle it, and the bound could then allow for
  the pool on that runtime. With GHC 9.12.4 the redirect sweep of the same
  group failed the same count once, over a mock on a pipe.
* **`Resources.CutHandshake`'s proxy, without `-threaded` under the
  default manager.** Its `EncryptOn` case failed with "gai_strerror not
  supported: 11001", network's `getAddrInfo` of the numeric `127.0.0.1`
  failing with `WSAHOST_NOT_FOUND`, in 3 whole-suite runs of about 10 on
  2026-11-07, with GHC 9.12.4 and with GHC master. The failure is in the
  test's own proxy, not in hmssql. Whether network's non-threaded lookup
  is what fails would settle it.
* **`Connection.Disconnect` "server kills the session, while rows are
  streaming" hung on one macOS system connecting to Azure.** After the
  `KILL` the client reads the rows already on their way (91,000 to 265,000
  of the 2,027,776 the statement sends), then nothing arrives and the
  connection stays open and silent for the test's 30 s. `sqlcmd` on the
  same Mac hung too, blocked for over 26 minutes, as did a Linux container
  in Docker Desktop on that Mac. These are observations from one host, not
  independent reproductions on macOS and Linux. The hang has not been
  reproduced elsewhere, and there is no public bug report. An
  environmental cause is suspected but undiagnosed; neither a general
  macOS defect nor an Azure defect has been established. The measurements
  of 2026-10-25 and 26 (which clients and tiers hung, and the socket's
  state in a hung run) are in
  [protocol-notes.md](protocol-notes.md#cancellation-and-killed-sessions).
  A packet capture of a hung run and a comparison from another host or
  network would help isolate the cause. A capture needs root on a machine
  that connects directly (Docker Desktop's networking re-originates the
  connection, so a capture inside the container would show its own
  proxy). A caller that needs a bound on waiting can use its own
  `timeout`, since hmssql sets no TCP keepalive, and a dead peer is
  otherwise noticed only when the kernel gives up retransmitting. On Azure
  the test waits 15 s for the reset and is pending without it, so it is
  still a check wherever the reset arrives (including the Windows client
  outside Azure and the container in the region).
* **`Robustness` "recovers after a consumer thread is killed
  mid-stream" races the stream it kills.** The test polls with
  `threadDelay 1000` until its consumer has 100 rows, which takes at least
  16 ms a tick on Windows, and then kills it. In both whole runs with the
  slow tests on 2026-10-16 (SQL Server 2025 build 17.0.1145.4, over TCP,
  at the suite's usual concurrency) the consumer had read all 300,000 rows
  by then and ended with `Right ()`; alone it passed 11 times in 11, the
  whole test taking 0.07 s. The cause is read from the test and not
  traced. The fix is to make the stream be mid-read for certain: the
  consumer waits on an `MVar` in its callback after the hundredth row, and
  the test kills it there. That also follows the rule in
  [testing.md](testing.md#how-the-tests-are-written-for-windows) that a test which must act within a
  round trip doesn't sleep.
* **A hang of `Protocol.Fuzz`, not explained.** In the first of those
  runs both properties of the hedgehog fuzz (the tokens of a response, and
  its packets with the server closing after them) failed on the harness's
  own watchdog, "the first request hung for 5 s", twice, 3,684 and 12,095
  cases in. The mock serves them, so the server is not involved, and a
  failure after the first hang shrinks to a trivial case and says nothing
  about the cause. The second run did not hang, and the module alone with
  the slow tests and the same seed passed all 13 examples. What would
  settle it: the module run beside a loaded machine (another suite going),
  and the two packet dumps the run printed (one-byte packets, the first
  not final), replayed against the mock to see whether hmssql waits for a
  packet the case never sends or the machine stalled for five seconds.
* **`Model.Connection` at 5,000 sequences, once.** In the second of those
  runs the property failed after 652 cases with `OInterrupted` where the
  model expected `OUnit`; the report stops before the operation that
  failed, so it is not known which one it was. The shrunk sequence holds a
  `Waitfor` and no `Cut`. Alone, with the same seed, it passed in 389 s.
  The one other failure of these properties on record, on SQL Server 2019
  RTM on Windows, was a `Waitfor` that ran its ten seconds
  ([testing.md](testing.md#what-the-runs-established)), and both are consistent
  with the polling of `interruptWhenWaiting` being starved, which is a
  supposition and not a measurement. What would settle it: have the
  property print the failing operation, and run the slow suite with a
  trace of the interrupter's polls.
* **`Model.Connection` over MARS found a row in the shared table that the
  model had not inserted, once.** In the matrix of 2026-10-25 (GHC 9.8.4,
  SQL Server 2022 CU27, `mars+slow`, 5,000 sequences) the property failed
  after 4,301 cases: a `Check` with the model's table empty saw `3:30` in
  it. `newEnv` releases the previous sequence's connection and then
  empties the table with `DELETE`, and a statement the old connection had
  already sent can still commit on a loaded server after that `DELETE`;
  that is the likeliest source, and a supposition. It did not recur in the
  other 359 runs. What would settle it: have `newEnv` wait until the old
  session is gone from `sys.dm_exec_sessions` before the `DELETE`, or give
  each sequence a table of its own.
* **The slow tests over the pipes and over MARS on Windows.** They have
  run only over TCP without MARS, twice. Over a pipe the suite goes one
  test at a time, so the run is several hours.
* **The matrix's other configurations against SQL Server 2025 on
  Windows**: packet sizes of 512 and 32767 and a session setup
  (`arithabort`). They passed against SQL Server 2019 RTM there.
* **The build of `examples/managed-identity` on Windows.** `stack build`
  failed twice on 2026-10-16 with "permission denied" renaming
  `cabal_macros.h` in that example's `autogen` directory, with no stale
  process holding the file and Windows Defender's real-time protection
  on. The library and the test suite are not affected. Whether an
  exclusion for the project directory ends it has not been tried.
* **`Mars.SmpSessions` "a MARS connection dropped with open sessions",
  once on network's path.** In the live run over Shared Memory of
  2026-11-06 (GHC master, native manager, threaded, so the mock's TCP on
  network's calls), the mock received the client's SYN for session 0 but
  not for session 1 before the connection ended. It passed in 120 runs
  alone on that path and in 40 on hmssql's own backend. A reset makes
  Windows discard what the receiver hasn't read, and the dropped
  connection's close resets it while the mock has sent more than the
  client read, so a slow mock reader would lose the SYN; that is a
  supposition. If it comes back, have the mock wait for both SYNs before
  it answers.
