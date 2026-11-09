# Design and behaviour contract

This document states the rules hmssql follows and why. Most of them were
settled in September 2026, during two days of exhaustive testing and the
adversarial review that followed, and the rest as MARS, the Windows
transports, value streaming and the optimization runs were built (see
[development.md](development.md)). Where a rule was chosen over an
alternative, the alternative is named, so a future change can be weighed
against the reasons. The test suite states the consequence of each rule,
including what happens when the rules are broken.

Companion documents: [limitations.md](limitations.md) lists what hmssql
doesn't do; [protocol-notes.md](protocol-notes.md) records what SQL Server
and TDS actually do; [bugs-found.md](bugs-found.md) lists the bugs these
rules replaced. The measurements behind the larger decisions are in the
research records: [mars-research.md](mars-research.md),
[windows-research.md](windows-research.md),
[value-streaming-research.md](value-streaming-research.md) and
[performance-research.md](performance-research.md).

## Architecture

hmssql is modeled on [hpgsql](https://github.com/mzabani/hpgsql), a native
PostgreSQL client. From it come the Applicative `RowDecoder` over
`FieldDecoder`s (column count and types checked once, before the first
row), the single generic `Maybe` instance, `Generic` row deriving, the
monadic `RowDecoderMonadic` for shapes known only at runtime, `streaming`
results, the interruption-safety model and the reentrant connection mutex.
The protocol code descends from ms-tds and mssql (see
[history.md](history.md)).

| Layer | Modules | Role |
|---|---|---|
| Wire | `Hmssql.Tds.Context`, `.Packet`, `.PacketWriter`, `.Smp`, `.Parser`, `.Parser.OutOfLine`, `.Token`, `.TypeInfo`, `.Value`, `.Reader`, `.Scalar`, `.Primitives`, `.Parameter`, `.Client`, `.Bytes`, `.Bytes.Unsafe`, `.Utf16`, `.CodePage` | TDS 7.4 and 8.0: reader recipes for tokens and values, `Builder` writers for requests, packet framing, the SMP header, and the scalar and character conversions. There are no `Binary` instances; what depends on the protocol state takes a `TdsContext` (protocol version, packet size, transaction descriptor). |
| Backend | `Hmssql.Connection.Backend`, `.Connection.Backend.Windows`, `.Connection.Backend.WinIO` | The connected byte stream under a connection, as a record of operations: TCP everywhere, and on Windows Shared Memory and Named Pipes. |
| Connection | `Hmssql.Connection`, `.Connection.Internal`, `.Connection.Tls`, `.Connection.Locking` | The TLS transport over a backend, PRELOGIN and LOGIN7, the reader thread, sessions, the incremental token stream, Attention, reset, `release` and `renew`, and close. |
| Codecs | `Hmssql.Decoding`, `Hmssql.Encoding`, `Hmssql.Types`, `Hmssql.SqlValue` | `FieldDecoder` and `RowDecoder` with `FromSqlField` and `FromSqlRow`; `FieldEncoder` and `RowEncoder` with `ToSqlField` and `ToSqlRow`, `NamedParams` and `RawParam`; the Haskell types of SQL values. |
| Queries | `Hmssql.Query.Types`, `.Query.Lexer`, `.Query.Internal` | The representations, constructors included: `Query` (SQL text with its parameters), `Request`, `ResponseReader` and `ResultSets`; the `@pN` scanner; and what `Hmssql.Query` and `Hmssql.BatchQuery` share (reading a response, decoding result sets from it, packing statements into messages). |
| API | `Hmssql.Query`, `Hmssql.BatchQuery`, `Hmssql.BulkCopy`, `Hmssql.Transaction`, `Hmssql.Errors`, `Hmssql` | Building a `Query` (`mkQuery`, `param`, `namedParam`, `rawSql` and `escapeIdentifier`) and running it (`query`, `execute`, `queryS`, `queryMulti`, `queryResultSets` and `callProcedure`), batch queries, bulk copy, transactions, and typed exceptions. |
| Metadata | `Hmssql.SqlType`, `Hmssql.Internal.SqlDataType`, `Hmssql.Catalog` | SQL Server's data types by name (`SqlDataType`, a closed list) with their arguments and T-SQL spelling, converted to and from the wire's `TypeInfo`; a database's tables, views, columns, keys and foreign keys read from its catalog views. None of them is re-exported from `Hmssql`. `SqlDataType` and `typeInfoDataType` live in the internal module, which `Hmssql.SqlType` re-exports, because the decoders' type checks refer to the constructors: in `Hmssql.SqlType` they linked that whole module into every program unless the application builds with split sections. |

`Hmssql.SqlType.typeInfoSqlType` describes a column's storage type. Its
counterpart `columnSqlType` also reads COLMETADATA's user-type tag 0x50 to
report `rowversion`, rather than only its binary storage. Alias type IDs
above 0xFF don't carry the alias's name, so both return the underlying
type for those; resolving names belongs to `Hmssql.Catalog`. The 35 type
names are built by one private OPAQUE helper from `Addr#` literals, 4,568
bytes less code than a literal per name; the dispatch on a name stays a
`case`, since an array would add initialization and data to save under
1 KB.

Principles that hold throughout:

* **Decoders never call `error`.** A failure is a `DecodeError` naming the
  column, raised when the row is decoded, not when a field is forced.
* **Rows are decoded as packets arrive.** `queryS` streams, and `query` is
  `queryS` materialized. Memory stays flat for any result size.
* **The socket is read by one thread per connection.** Consumers wait on an
  `MVar`, so an asynchronous exception never lands inside `TLS.recvData`,
  which would corrupt the TLS session.
* **Constraints on the caller are preferred over defensive machinery.** Where
  a usage is unsupported, hmssql says so, detects it where that is cheap,
  and the tests show what happens.
* **Every module under `hmssql/src/` is exposed.** `hmssql/package.yaml` names no
  `exposed-modules`, so hpack exposes each module it finds, and a caller
  extending hmssql can reach the layer it needs. The module names carry the
  warning instead. `Hmssql.Query.Internal` and `Hmssql.Connection.Internal`
  hold the representations and the connection state, and nothing in them
  is stable; `Hmssql.Tds.Bytes.Unsafe` is unchecked, and its Haddock states
  the preconditions the caller has to meet. What `Hmssql` re-exports is the
  supported API, and that is the surface the guide and the Haddock
  describe.
  * *Alternative rejected:* hiding the internals, by listing them as
    `other-modules` or by collecting them behind one `Hmssql.Internal`
    boundary. This is a low-level client, the wire and connection layers
    are useful on their own to a custom codec or transport, and a caller
    who has to fork the package to reach a parser is worse off than one who
    imports it.
* **The Haddock sends a reader to where a name is documented.** A module
  that holds a name the public API re-exports carries `{-# OPTIONS_HADDOCK
  not-home #-}`, so that `Connection` is documented in `Hmssql.Connection`
  and not in `Hmssql.Connection.Internal`. `Hmssql.Tds.Bytes.Unsafe` doesn't
  carry it, because its own functions are documented there.

### The backend: what the bytes travel on

A connection does not hold a socket. It holds a `Backend`
(`Hmssql.Connection.Backend`), a record of six operations on a connected
byte stream: receive into a buffer, send one chunk, send several, stop
receiving, shut down, and close. Connecting is not in the record; it is a
function that returns one, and each backend's connect cleans up after its
own interruption. TLS, when the connection is encrypted, runs above the
record, on a `TLS.Backend` built from it.

hmssql has three backends. TCP is the socket code. Shared Memory and Named
Pipes exist on Windows only, where they are one implementation, since SQL
Server's Shared Memory protocol is TDS over a local named pipe and the two
differ only in the pipe's path
([protocol-notes.md](protocol-notes.md#shared-memory-and-named-pipes)).
`connectProtocol` chooses ([Connection lifecycle](#connection-lifecycle)),
and `ProtocolCustom` takes a backend of the caller's making, so that a
transport can be wrapped or replaced without changing hmssql, such as a
tunnel, a proxy, or a stream that reshapes writes for a test. On Windows
each operation is implemented one of two ways, by hmssql's own overlapped
I/O or through GHC's native I/O manager
([Platform workarounds](#platform-workarounds)).

The record exists so that the platforms can differ below `Connection` and
nowhere else. On Linux, where hmssql serves APIs whose clients cancel at
any moment, reliable cancellation is paramount, and the record may not
weaken it. On Windows the audience is desktop applications such as
migration utilities, whose common problem is a query that has to be
cancelled, and at worst an unattended Windows service, where a connection
that hangs is very disruptive; there the requirement is that a bug report
can be fixed inside a backend without changing `Connection`. The abstraction was taken
even at a cost, and off Windows it costs nothing measurable: the indirect
call per send and receive moved the geometric mean of the `Mock` and
`Live` benchmarks by 1.004 in CPU time and 1.000 by the clock, within the
0.9% the same executable differed from itself (macOS, GHC 9.12.4, SQL
Server 2025, 2026-10-04).

* *Alternative rejected:* `TLS.Backend` as the bottom layer. Its receive
  returns exactly `n` bytes in a fresh `ByteString`, where the reader
  thread wants "up to `n` bytes into this buffer". It has no vectored
  send and no way to end a blocked operation, and it begins after the
  connection exists.

Six rules make up the record's contract.

* **Interruption is the backend's business.** An asynchronous exception
  should end a blocked receive or send promptly, and the stream need not
  be usable afterwards. `Connection` has no second code path for a
  backend that can't be interrupted, and needs none, because an
  interrupted raw send or receive already ends the connection: a failed
  send breaks it, the reader thread is only stopped at `close` and by the
  finalizer, and an interrupted `connect` closes what it opened.
  Cancelling a query never interrupts one of these. The thread that is
  cancelled waits in STM for the reader, and the Attention is an ordinary
  send.
* **"Stop receiving" and "shut down" are sticky, and separate.** Each
  makes later operations fail as well as the blocked one, so that a stop
  that arrives while the reader is between two receives is not lost.
  They are two operations because `close` sends a TLS close_notify after
  the reader has stopped, which a single abort that also failed sends
  would lose. `stopReader` calls "stop receiving" and then `killThread`.
  On a POSIX socket the first does nothing and the second ends the wait
  in GHC's I/O manager. On Windows, on hmssql's own backend, the first
  ends the receive.
* **"Shut down" tells the other end.** After a send that failed part-way
  the connection shuts its backend down, so that a server holding part
  of a message stops waiting for the rest. A socket's shutdown does that
  and leaves the socket open until `close`. A pipe has no shutdown, and
  its other end learns nothing until the handle is closed, so the pipe
  backend closes the handle at "shut down". That waits for the
  operations it has just cancelled to end, and the `close` that follows
  finds nothing left to do. A backend must therefore not be shut down
  from inside one of its own operations, and the connection never does.
* **A write is a unit, whatever pieces it comes in.** Every write the
  connection hands to a send is one or more whole TDS packets, on a MARS
  connection in plaintext whole SMP packets, or over TLS exactly one TLS
  record. `backendSendMany` takes each write as a list of pieces, because
  a plaintext SMP packet is two: its header, made under the send lock,
  and its TDS packet ([Who owns a packet's bytes](#who-owns-a-packets-bytes)).
  A backend whose other end sees write boundaries must make each write
  one write, joining its pieces. SQL Server reads a pipe one write at a
  time and drops the connection otherwise, so the pipe backend joins
  them, at a copy of each SMP packet in plaintext; the socket backend
  sends every piece in one vectored send.
  * *Alternative rejected:* a flat list of chunks, each a unit. The SMP
    header and its packet were then two chunks, the pipe backend wrote
    them as two writes, and SQL Server dropped every MARS connection over
    a pipe without encryption at its first request
    ([bugs-found.md](bugs-found.md#platform)). Joining the pieces in the
    connection would cost the copy on a socket too, and a backend can't
    tell where the units of a flat list end.
* **A handle is closed last.** `backendClose` is called once the reader
  has stopped and no send is in progress, because a descriptor or handle
  number can be given to the next socket opened, which a late operation
  would then reach. It may be called more than once, and waits for an
  operation in progress where the platform needs that: on Windows a
  handle must not be closed, nor its `OVERLAPPED` freed, under an
  operation the kernel has not finished, and `stopReader` returns once
  the exception has been raised in the reader, which may still be
  unwinding.
  * *Alternative rejected:* closing the socket under a blocked reader to
    wake it, which is the hazard of a reused number.
* **A backend refers to its handle only,** never to the `Connection`. The
  reader thread and the TLS session hold the backend, and both are always
  reachable; if the backend reached the connection, a connection dropped
  without `close` would never be collected.

The record also carries the socket, when there is one, so that a caller
can set an option on it.

### Reading and writing bytes: which layer

**Reading is described by recipes.** Transport and session code supply
immutable TDS payloads. `Hmssql.Tds.Parser` owns the current payload and
asks for another when a read can't finish; `Hmssql.Tds.Token` and
`Hmssql.Tds.Value` describe token and value envelopes, with no packet
offsets. A row decoder compiled for a result set consumes those recipes
directly, so an ordinary query doesn't materialize a raw row first. A
recipe that needs more input suspends (`NeedMore`), and the connection
resumes it with the next payload; one that has to run the caller's code
says so (`RunConsumer`), so that the connection runs it in the caller's
masking state. `Recipe env` carries immutable context beside the input,
and `Parser` is `Recipe ()`; a compiled row takes its NBCROW bitmap from
the environment, so each row supplies a new bitmap without rebuilding its
field recipes.

* *Alternatives rejected:* a row walk over offsets beside a resumable
  reader, and a hand-written record of phases. Both duplicated the wire
  logic, needed concatenation or replay where a row was cut by a packet,
  and hid the continuations and the ownership of bytes in large records.
  The walk traversed each row twice, once to slice it into an array of
  offsets and once to decode it: on 10,000 `int, bigint` rows the walk
  alone took 3.5 MB of a typed decode's 5.2 MB and 386 of its 695 us
  (2026-10-31, GHC 9.12.4). Its resumable reader always assembled a row and
  copied each value into a buffer of its own, so nothing could ask for
  less (draining a 16 MiB value allocated 44 MB through the mock server),
  its linearity was a runtime check, and it was one of three parsers of
  one wire format. The walk was the implementation until 2026-11-01;
  [value-streaming-research.md](value-streaming-research.md) records the
  rewrite and what it cost.

**How a recipe runs.** A recipe runs on the payload, shared by every call
within it, and a position in it, boxed as an `Int`, and returns the
position unboxed. So an unknown call, such as to a column's recipe, passes
only pointers and is one `stg_ap_ppp`, and a known call goes to a worker
that takes the position unboxed. At the sites known to be unknown calls,
`dynamic` takes the box from a table of 8,192 boxed `Int`s (about 170 KB,
built on first use) instead of allocating one, and the driver keeps the
payload and position apart through `runParserAt`, building a `ByteString`
only when it commits a batch or a suspension. A suspension resumes at
position 0 of the next payload. A recipe's immediate result is a private
unboxed sum of three, `Parsed value position`, a suspension (a `Stream
Await IO` continuation) or `Failed failure position`, so that a recipe
chosen at runtime returns without allocating a constructor even when GHC
can't inline it. A suspended computation ends in a private `Outcome`, a
value or a failure, which `parse` and `runParser` turn into the public
`Got` for drivers.

* *Alternatives rejected:* the input as a lifted `ByteString`, which boxed
  32 bytes per unknown call; the input as its three unboxed fields, and any
  position passed unboxed beside pointers through an unknown call, which
  the RTS's generic apply splits into partial applications
  ([protocol-notes.md](protocol-notes.md#platform-and-tooling)), doubling a
  typed query's allocation; boxing every position through the table, which
  a known call can't see through; and a recipe in continuation-passing
  style, and a recipe of two readings, each measured
  ([performance-research.md](performance-research.md)).
* *The table of boxed positions keeps 8,192 entries.* It costs Decode some
  time, two dependent loads per lookup (without it Decode was 0.92 in time
  and Mock 1.03, with 6% and 14% more allocation), and it stays for the
  allocation. *Alternatives rejected:* 4,096 entries, which saved 98 KB of
  live heap but allocated 4% to 6% more per response at the default
  payload of 7,992 bytes; and a static table through `addrToAny#`, which
  would depend on the target's closure layout.

**What `Hmssql.Tds.Parser` exports.** Recipes built from the reads, the
`Monad` instance and `fail`, the failure channel (`failValue`, `recover`
and `attempt`), and the drivers are public: `parse`, `runParser`,
`runParserAt` with its `At`, `parseChunks`, `runFrom`, `feedRunner`, and
the `Await` and `Feed` a driver matches on. So are `dynamic` and
`oneShotRecipe`, which change how GHC compiles a recipe and nothing about
what it reads, and `Hmssql.Tds.Parser.OutOfLine`, the binds and reads out
of line, for `QualifiedDo` in readers that run once per token or per
column, where the inlined binds were most of Token's and TypeInfo's code.
`runFrom` is public because a driver written by hand has to follow the
run-once rule that `Accumulator` depends on, and nothing tests a
violation; a caller with its own source of payloads should not have to.
`Recipe`'s constructor, `Result` and what is built on them (`run`,
`parser`, `await`, `resume`, `stream` and `primitive`) stay private, for
three reasons:

* They add no reach. `chunk` and `>>=` can express any format, and each
  has a public form: `runParser` is a boxed `run`, `parse` is `stream`
  after `run`, and `boundedBytes` is `primitive` without its inlining.
* A hand-built recipe could break what the module relies on. `limited`
  counts bytes by comparing the input with the unread part, so the unread
  part must be a suffix of the input, and `Parsed` is what forces results.
* The representation is what performance work keeps changing, as the
  comment at the top of the module records, so exporting it would make
  that work a breaking change.

* *Alternative rejected:* exporting the internals for extensions such as
  table-valued parameters. A TVP is sent, so it never touches this module;
  it is reachable through `Request` as it stands
  ([protocol-notes.md](protocol-notes.md#rpc-and-stored-procedures)).

**Offsets stop at the parser.** The scalar codecs in `Hmssql.Tds.Scalar`,
`Hmssql.Tds.Primitives`, `Hmssql.Tds.Utf16` and `Hmssql.Tds.CodePage` take
a whole value: a `ValueReader a` is `ByteString -> Either String a`, given
exactly its value's bytes whether they lay in one packet or several, so a
wrong length is an ordinary `Left`. Only these leaf codecs and the parser
use byte positions, and a codec reads at constant positions within a value
whose length it has checked. A caller that holds a larger buffer takes a
slice, which `B.take` and `B.drop` make in constant time without a copy.

* *Alternative rejected:* an offset and a length beside the buffer, as the
  `*Span` readers and `decodeUtf16LEAt` took. No caller passed an offset
  other than 0, and a bad span raised `error` through the bounds check, so
  offset arithmetic from wire data surfaced as an `ErrorCall` rather than
  a `DecodeError`.
* *Alternative rejected:* the payload and an offset in a custom
  `CellDecoder`'s interface, to save the 32-byte slice per cell (a refined
  integer through `fieldDecoderFor` allocated 640 KB more per 10,000 rows
  than the built-in decoder). It would hand the buffer's bounds and
  lifetime to every decoder. The built-in types avoid the slice by
  inlining their conversion at one site, and `inlinedField` does the same
  for an application's ([Decoding](#decoding)).

**Value pulls use one shared feed runner** (`feedRunner`). A value's
recipe contains byte reads and internal effects, and only the top-level
driver runs consumers. A consumer nested in a value's pull is a
`ProtocolError`, and leaves a failing continuation in the value cursor, so
cleanup can't later run the rejected action. The connection supplies the
runner's read mask and failure handler, and consumer code keeps the
caller's masking state.

**Writing uses `ByteString.Builder`.** `writeTypeInfo`, `writeValue` and
the request builders describe bytes once. `Hmssql.Tds.PacketWriter`
interprets builders in packet storage, handles primitives cut by packet
boundaries, and lets go of each buffer before handing it to the transport
([Who owns a packet's bytes](#who-owns-a-packets-bytes)). The first buffer
starts at 256 payload bytes and grows to the negotiated capacity if
needed, so small requests don't allocate a full packet. Every packet but
the last is full, the SMP header's room stays private to the writer, and
the first packet ID is 1. `writeValue` is a small inline wrapper around
one out-of-line `BuildStep`, `writeValueStep`, which takes the Builder's
continuation and buffer together, so the sender, the in-memory serializer
and the bulk writer share one compiled copy of the framing without
allocating a Builder to apply it: 19,752 bytes less library code and 32
bytes less per scalar parameter than INLINE throughout, and a pure
`writeValue` materialized alone allocates 40 bytes more.

* *Alternative rejected:* counted `Size` and `Poke` writers. Every layout
  needed a second interpretation, and producers saw the contracts of
  writing through a pointer. Builder is the writing recipe bytestring
  already provides.
* *Alternative rejected:* `writeValue` wholly out of line, 38 KB less code
  but 32 bytes more per parameter.
* *Alternatives rejected:* strict prefixes in `writeValue` (each length as
  a `FixedPrim` on a computed value), which saved nothing (1,331 bytes per
  bulk row against 1,306), because the cost is the closures and not the
  prefixes; and a cheaper `writeBuilder`, which could save at most its own
  129 bytes per row.

**Two producers poke into the packet.** The general counted writer stays
rejected; these two are confined to their modules, and each pointer stays
inside one function.

* A bulk ROW whose cells are all in memory and none of them PLP is written
  by `PacketWriter.unsafeWriteSized`, which pokes a known number of bytes
  straight into the current packet when they fit, grows the small first
  buffer first as `writeBuilder` does, and stages a row that doesn't fit
  in a buffer of its own. The row's size and its pokes both come from
  `cellFrame` in `Hmssql.BulkCopy`, which gives a cell's length prefix and
  bytes, and `Wire.BulkPacketsSpec` checks the poked rows against
  `writeValue` for each length kind. A row with a stream or a PLP cell
  keeps the Builder. Through a Builder per row, a row of an `int`, an
  `nvarchar(50)` and a `decimal` cost about 1,460 bytes and 250 ns in the
  closures built for each cell; poked, it costs 56 bytes in the writer.
  `cellFrame` is a second description of a non-PLP value beside
  `writeValue`, which the [backlog](backlog.md) plans to remove by deriving
  `writeValue`'s in-memory cases from it.
* A scalar parameter of a BYTE-length type (the integers, the floats,
  `decimal`, `money`, the dates and `uniqueidentifier`) is poked after its
  header by `writeByteLengthValue` in `Hmssql.Tds.Parameter`, rather than
  composing the two in one Builder. The payload is an immutable
  `ByteString` the parameter layer has already checked, and the size and
  the length byte come from the same length. Poked, a scalar allocates 147
  bytes less per parameter; poking every non-PLP kind saved only 98 more
  and was more code. `Wire.PacketWriterSpec` checks the poked parameters
  against the Builder framing across packet sizes, and that no packet
  changes after it is handed over.

**A request is checked once, where it is built.** A query's parameters are
checked when they are encoded (`EncodeError`, before anything is sent);
`executeSqlRequest` and `rpcRequest`, the low-level constructors, check
their parameters for what the wire can't carry when they build the
`Request`, in `IO`; `batchRequest` checks its text as it starts to write.
The writers (`writeRpcRequests`, `writeValue`) then write without checking
again, which their Haddock states as a precondition, and `encodeBulkCell`
keeps its own checks for bulk cells.

* *Alternative rejected:* checking at each layer, in the encoder, the RPC
  writer and the value writer, which ran the same checks three times per
  parameter.

### Who owns a packet's bytes

**Rule.** A `ByteString` is never made from a buffer that still has a write
to come, because its type promises that the bytes won't change, and a
`ByteString` function run on it too early would give a value that depends
on when it was evaluated. A packet's storage stays private to
`Hmssql.Tds.PacketWriter`: the writer writes the TDS header last, lets go
of the storage, and only then makes the `ByteString` that a `PacketSink`
(`ByteString -> IO ()`) receives. Nothing outside that module can see a
packet while it is mutable. All request sends go through `PacketWriter`;
the pure `frameSegments` remains for in-memory framing and wire fixtures.

**A producer gets a `PacketWriter`**, which is one mutable value. It gives
a buffer to the sink as soon as the packet is complete, and lets go of it
first, so that no later write can reach it. `runPacketWriter` sends the
last packet, marked as the end of the message, when the producer returns,
and every packet but the last is full because one goes out only when the
next byte arrives. So the shape of a message isn't up to the producer. A
writer used after its message ended, which includes one kept from a
producer that threw, is an `error`, since it still refers to a buffer the
sender may hold.

**A buffer is a `ForeignPtr` and a length, not a `Ptr`.** A packet is
filled over many writes with the producer's own code between them, so no
callback encloses the buffer's life; the collector sees only the
`ForeignPtr`; and the frozen `ByteString` is itself a `ForeignPtr`, which a
plain socket's send path keeps in a list until it has enough to write.
Each write itself goes through a `Ptr`.

**An SMP header is not written into the packet's buffer.** Its sequence
number and window are known only under the send lock, because a window
must not go backwards on the wire, so `writeSmpData` makes the header
there as a `ByteString` of its own. A plain socket writes the two pieces
in one vectored send. A plain pipe joins them, since its server reads a
write at a time and the two must be one write, and TLS joins them too: one
copy per packet, since `TLS.sendData` makes one record per chunk and a TLS
record holds one SMP packet.

**Received bytes keep the same rule**, so a slice of a received packet can
never change. A plain socket reads into the free end of a 32 KiB arena
(`recvIntoArena`), past everything already handed out, and takes a new
arena when too little is left; only a packet split between two receives
is copied. The TLS backend's receive buffer (`newBufferedRecv`), which the
connection reuses, only ever gives out copies. So a decoder that keeps a
borrowed slice costs memory, the whole arena or TLS record, and can't get
wrong data; that is why `fieldDecoderFor`'s rule to copy is about
retention.

* *Alternative rejected:* network's `recv`, which allocates the whole size
  it asks for on every call: a one-token round trip against the mock
  server allocated 51 KB, and 15 KB through the arena.
* *Alternative rejected:* arenas for TLS, handing out slices as the plain
  socket does. They allocated no less, since records split between
  receives had to be joined, and kept a 128 KiB arena alive per idle
  connection.

Rejected for the packet's own buffer:

* A `ByteString` with a documented contract, which is what the original
  code had. `sendPackets` took a `ByteString -> IO ()`, and on a MARS
  connection it poked 16 bytes at the front of what it was given, so that
  one sink type served both kinds of connection. A producer that left too
  little room overwrote its own TDS header, one shorter than 16 bytes
  wrote out of bounds, and a literal or a shared `ByteString` was written
  in place.
* Linear types: `PacketWriter` and an `OwnedPacket` as linear values, with
  `QualifiedDo` over `IO` and one `unsafeCoerce` that changed a function's
  arrow. This was built and worked ([linear-types.md](linear-types.md) has
  the assessment). It made a second freeze a compile error, but the defect
  was the early wrap, and a type that isn't a `ByteString` removes that.
  What the linear version added was about 900 lines with its tests,
  hand-arranged unboxing with nothing to check it, and `%1` in the
  signature of the send path and of bulk copy. The raw sized writer was
  unsafe either way, since it handed out a pointer.
* A `PacketBuffer` that kept room for the SMP header and let the sender
  freeze the buffer. It saved the copy of a TLS or pipe write, but the
  rule against a second freeze was documented and not enforced, in code
  outside the module that owned the storage.
* A header in a `ByteString` of its own and no joining at all. On a socket
  `backendSendMany` could take the pairs, but `TLS.sendData` makes a record
  per chunk, so each SMP packet would be two records. Two records aren't
  known to work: at the oversized packet in
  [protocol-notes.md](protocol-notes.md#mars-and-smp) they didn't help,
  and no smaller size was tried.

**What it costs.** No copy is added or removed against the linear version
it replaced. The writer's `IORef`s allocate more: framing a bulk load of
1000 rows went from 160 to 175 KB, and took 199 to 298 us against 271 to
309 us, in three alternating runs of each. Against SQL Server 2025 over
strict TLS, a load of 10,000 rows, a 4 MB parameter and a small query
were within the noise of those runs, on a plain connection and on a MARS
one (GHC 9.12.4, Linux, 2026-10-30).

## Connection ownership and concurrency

**Rule.** A `Connection` is meant to be used by one thread at a time; give
each thread its own, from a pool. A connection has one outstanding request
at a time, unless it was opened with `connectMars`; see
[MARS](#mars-several-responses-on-one-connection) at the end of this section.

**What happens if several threads use one.** The library makes sharing safe,
not efficient: the materializing functions hold a reentrant lock for their
duration, so calls from different threads serialize. A `queryS` stream must
be consumed before any other thread uses the connection; if another request
starts first, the stream's remaining rows are discarded (an Attention cancels
the statement unless the whole response has arrived) and the stream throws
`ResultAbandoned`. `withTransaction` holds the lock for the whole
transaction, so other threads' requests wait instead of running inside it. A
body that waits for another thread using the same connection deadlocks.

**Callbacks.** An info-message callback runs while the connection is
mid-response with the lock held. Using the connection from it throws
`ReentrantCallback`. An exception thrown by the callback propagates to the
request and leaves the connection usable, since the token was fully
consumed.

* *Alternative rejected:* queuing callbacks to run after the response,
  which is machinery for a misuse.
* *Alternative rejected:* letting the inner request run, which silently
  cancelled the response being read.

**The mutex records its owner by thread number**, not by a weak `ThreadId`
as hpgsql does. A thread the garbage collector resurrects to deliver
`BlockedIndefinitelyOnMVar` already has a dead weak pointer, yet its
handlers (a transaction's rollback) re-enter the mutex and must be
recognised. A strong `ThreadId` was worse: it kept a thread that blocked
forever reachable, so it was never told it was blocked and never released
the connection.

**Why not forbid concurrency and drop the lock?** The lock is 91 tested lines that give a clean answer to "two
threads pull from one connection" (they serialize; the older stream throws
`ResultAbandoned`), and forbidding concurrency would not remove the need for
asynchronous-exception safety: a single caller can still time out. It stays,
documented as unsupported.

**`withConnectionLock` is OPAQUE**, so that its callers don't rebuild its
result: 128 bytes less per request and 1,056 bytes less code in
`Hmssql.Connection.Internal`.

**Returning a connection to a pool** is `release`, and borrowing one is
`renew`; hmssql has no pool of its own, and the Haddock of `release` and
[the guide's page on pools and threads](../guide/getting-started/pools-and-threads.md) show the resource-pool
recipe. `release` cancels a statement still running (a stream not read to
its end, as `cancelActiveStatement` does), flags the lazy reset, and says
whether the connection is worth keeping: `False` for one already broken or
closed (by `close`, or by the server while it sat idle), and for one that
fails along the way, which it marks broken, so `False` always means "close
it". It carries the reset out at once only when a transaction is open (see
[Session setup and reset](#session-setup-and-reset)). It takes the lock
like a request, so it waits behind a request or a `withTransaction` on
another thread, interruptibly. A pool bounds it with `timeout` and treats
`Nothing` as `False`: an interruption that lands in the drain or the reset
request breaks the connection, as any interrupted drain does, and one that
lands in the bookkeeping around them leaves a good connection that the pool
then closes, which is rare and safe. It sends nothing to probe the server,
so a session dropped without the socket being closed is found by the next
request.

**`renew` refuses an unusable connection**, with what a request would throw,
because a borrow is the one place every use of a pooled connection passes
through. A session killed while it idles in a pool is otherwise found by the
borrower's first request: four idle sessions killed cost four failed requests
(SQL Server 2025, 17.0, Developer edition on Linux). The check reads what the
reader thread recorded, so it adds no round trip. It comes before the lease
moves, so a refused `renew` leaves earlier handles as they were, and the
recipe closes and destroys the connection and takes the next, ending at a
connection the pool makes anew. An asynchronous exception goes the other way:
the recipe puts the connection back, because all it says is that the borrower
was interrupted. A probe on borrow (`SELECT 1`) was rejected for the reason
`release` rejects one: every request pays a round trip for a rare event, and
the kill can still land after the probe.

**`unusableReason`** asks the same question without giving up the handle, and
answers `Maybe UnusableReason`. `Maybe SomeException` was rejected: the caller
would recover the reason by testing exception types, and it can't always be
recovered, since a `ThreadKilled` during a send and one during a drain look the
same. So each reason is tagged where it is recorded, and `SomeException` stays
only as the payload of a reason whose cause can be arbitrary. There is no
`Usable` constructor, because `Nothing` means "no failure seen", and a half-open
socket gives `Nothing` too. A `connectionIsBroken :: Connection -> IO Bool` was
rejected: `isJust <$> unusableReason conn` is short, "broken" is narrower than
what the check covers, `False` would read as "healthy", and a `Bool` steers a
pool away from logging the reason. The check describes the connection and not
the handle, so like `renew` it skips the lease check and takes the mutex
directly: a released handle to a healthy connection gives `Nothing` while a
request through it throws `ConnectionReleased`. It takes the mutex so that the
answer can't race a request on another handle.

**A `Connection` value is a handle** to the connection, not the connection
itself. Every field of the record but `connLease` is a shared reference or
immutable configuration (the mutex, the transport, the pending response,
the broken flag, the session context), so a record copy with another
`connLease` is a second handle to the same connection. The connection's
current lease is a shared `IORef`; `release` bumps it (in a `finally`
inside the lock, so the caller's handle is invalid however `release` ends),
and `renew` bumps it and returns a copy carrying the new number, which
makes every earlier handle stale, including one a buggy pool handed out
twice. `checkLease` compares the two numbers and throws
`ConnectionReleased`. It runs in `withConnectionLock` once the lock is held
(so a handle released while its call waited for the lock is refused), and
first thing in `checkCurrent`, which a stream runs before each read and
before yielding each row of a batch it holds, without the lock. That covers
every request, every stream pull, `reset`, `cancelActiveStatement`,
`rollback`, `withTransaction`, bulk copy and `release` itself,
whatever state the connection is in. Not checked, by design: `close`,
which takes no lock and works through any handle; `renew`, whose argument
is stale by definition, and `unusableReason` (both take the mutex directly, so
they wait for a request still running on an old handle instead of cutting in);
and the read-only `connectionContext` and `inTransaction`. The garbage collector's
finalizer is keyed on `connAlive`, a shared `IORef` that exists for it (every
handle reaches it, the reader thread doesn't, and the blocking reads, the
sends and `close` keep it alive explicitly), so it runs once the last handle is gone. `connect` starts both numbers at 0, so
its handle works without `renew`.

* *Alternative rejected:* a separate session type for a borrowed
  connection, or a split of `Connection` into a core and a handle. The
  record copy gives the same guard with no change to any signature, for an
  `IORef` read per request and per row yielded.

### MARS: several responses on one connection

With `connectMars = True` (off by default) several responses can be open on
one `Connection` at once, as with SqlClient's `MultipleActiveResultSets`.
MARS is invisible in the API: no channel or session type, no `openChannel`.
Each request takes an SMP session for itself and gives it back when its
response ends; the caller sees only that a new request no longer abandons an
open stream. A connection without `connectMars` uses plain TDS, with no
SMP framing; transactions begin with a Transaction Manager request on
every connection (see [Transactions](#transactions)). The server facts
behind the design are in
[protocol-notes.md](protocol-notes.md#mars-and-smp), and the spikes and
probes that found them are summarised in
[mars-research.md](mars-research.md).

**Negotiation.** `connect` throws `MarsNotSupported` unless the server
answers the PRELOGIN option MARS with exactly 1 (an answer of 0 and a
missing option alike), before LOGIN7 and with the socket closed; a
connection without `connectMars` whose server turns MARS on unasked gets a
`ProtocolError`. `connectionMars :: Connection -> Bool` says whether a
connection has MARS, for code handed a `Connection` without its
`ConnectInfo` (a pool wrapper, or a helper choosing between `withQueryS`
and `query`).

* *Alternative rejected:* connecting without MARS when the server refuses
  it. Code written for several open responses would then find each request
  abandoning the last (`ResultAbandoned`).
* *Alternative rejected:* a `tdsMars` field in `TdsContext`, read with
  `connectionContext`, which would put a connection property into the
  protocol-state record the encoders take; or nothing at all, since the
  caller chose `connectMars`. `connectionMars` is one pure export and no
  new state: the property is fixed once `connect` returns.

**What is shared and what a response owns.** `Connection` keeps everything
physical and everything the server shares between sessions: the socket, the
transport, the send lock, the reader thread, `connEnded`, the protocol
context (`connContext`, which holds the transaction descriptor), the mutex,
the broken flag, the reset flag, the lease, the callbacks. A `Session` holds
what one request at a time needs: its current response, a generation
counter, and either a receive buffer (a plain connection's one session) or
an `SmpSession` (the SID, the send sequence number, and an `SmpLink` of
STM variables shared with the reader thread: the queue of received TDS
packets, both windows, the receive sequence number, a count of
end-of-message packets, and whether a FIN was sent). An `ActiveResponse`
points to its session, so every reader (`stepResponse`, `checkCurrent`, the
drain) finds the session from the response and the query modules kept their
shape. A plain connection has exactly one session, `connPrimary`, and runs
the same code.

**One mutex, one owner.** The reentrant connection mutex is unchanged and
covers everything; there is no lock per session. A MARS connection is still
for one thread at a time. SQL Server runs one request of a MARS connection
at a time and switches where a statement yields, so a second lock would buy
no parallelism. `withQueryS` and the rest of its scoped family
(`withQuerySWith` and `withQuerySMWith`) are `startResponse`, the body
under `readingToEnd`, then `cancelResponse`, and hold the lock only inside
those, not across the body, so a stream can be handed to another thread to
consume as long as nothing else uses the connection meanwhile.

* *Alternative rejected:* channels, the design of the first spike (a record
  copy of `Connection` per SMP session, opened with
  `openChannel`/`withChannel`). Every caller would have had to manage
  channels for what SqlClient does silently, `withTransaction` would have
  needed a way to hand channels to its body, and "broken" and the lease
  would have had per-channel and per-connection variants.
* *Alternative rejected:* a pull lock per session beside the connection
  lock. It would let a second thread read a stream while the first waits in
  a request blocked by that stream's locks, turning a wait for
  `LOCK_TIMEOUT` into a deadlock error (1205). Single-owner code gains
  nothing, and the documentation rule (write beside an open scan only
  inside a transaction) is needed either way.
* *Alternative rejected:* reclaiming the session of a stream that was
  dropped unread through a weak pointer. `release` and
  `cancelActiveStatement` settle every session, which is what SqlClient
  relies on too (it reclaims at pool return).

**Sessions.** A request takes the idle session with the lowest SID, else
opens a new one: the lowest SID the server doesn't have open or closing
(so at most one above the largest of those, which the server accepts: its
limit counts the largest SID ever used on the connection, closing ones
included, and a SYN for SID 30 right behind unanswered FINs for 10 to 29
was accepted 200 times in 200). The session is
registered before its SYN is sent, so the client can never forget a SID the
server has; a SYN that fails or is interrupted breaks the connection, like
any send. A session is busy while it has a current response, that is, until
the response's end has been read (`StepEnd`), by its consumer or by a drain.
Sequential requests therefore all use SID 0. At each request start, idle
sessions beyond ten (SqlClient's number) are closed with a FIN, highest SID
first; the SID stays in the registry, neither open nor free, until the
server's FIN arrives, since a SYN for it before then makes the server drop
the connection. A busy session is never closed (the server drops the
connection for that too). Sessions survive `release` and `reset`, so a
pooled MARS connection keeps its sessions across borrowers, as SqlClient's
does: `release` settles every response and sends no FIN, and FINs come
only from closing idle sessions beyond ten. A bulk copy (`bulkInsertS`)
runs whole inside `withReservedSession`: its column query, every batch's
`INSERT BULK` and load, and the load's Attention recovery all go on one
session, whether or not the server requires a load on the session of its
`INSERT BULK` (unprobed; see the [backlog](backlog.md#after-the-release)).

**A response belongs to its session object, not to the SID.** A reused SID
gets a new session object, so a stream left part-way on a session the
trim closed stays abandoned after the server has answered the FIN and a
new request has opened the same SID again: the old handle throws
`ResultAbandoned` before and after the reuse, and the new stream gets
exactly its own rows (`Mars.SmpSessions`).

* *Alternative rejected:* sessions indexed by SID. The old handle would
  then have read the new statement's rows in the same sequence, because
  the reused SID is the same.

**The reader thread** is chosen at `startReader`. A plain connection's
reads the TDS stream; on a MARS connection it cuts what it receives into SMP packets
and, in one STM transaction per packet that never blocks, raises the send
window from the packet's WNDW, checks a DATA packet's sequence number and
that it lies within the window the client gave, checks that its payload is
exactly one TDS packet, counts it if it ends a message, and queues it for
its session. A control packet must be exactly 16 bytes; its declared length
is checked before changing a window or removing a session. A FIN for a
session the client closed frees the SID; any other FIN means the server
is closing the connection (`ClosedByServer`); anything malformed is a
`ProtocolError`. Either ends the connection for every reader and sender,
through `connEnded`. The thread refers to the session registry only, never
to the `Connection`.

**Flow control.** A reader takes whole TDS packets from its session's
queue (interruptibly, losing nothing) and sends an ACK once the window has
room for `window / 16` more packets than the server was last told. ACKs
follow consumption, not arrival, which is what makes a stream nobody reads
stop at `connectMarsWindow` packets while the other sessions keep flowing.
The cadence is internal rather than a `ConnectInfo` option.

* **The window** (`connectMarsWindow`, default 64 packets, raised to at
  least 4 and capped at 2^31-1, which the modular sequence comparisons
  need) is the memory bound of a response nobody is reading. Over a 45 ms
  round trip a session reads at window x packet size per round trip, and
  16 gave a quarter of a plain connection's rate there.
  * *Alternative rejected:* the first spike's window of 16, with an ACK
    every 2 packets.
* **The ACK is the one send made uninterruptibly.** It happens inside a
  read, and a `timeout` that landed in it (under load it did, in the
  moment the send waits for the TLS session's state) broke the connection,
  where an interrupted read must leave it usable. It is 16 bytes, and
  `close` from another thread ends the wait if the socket is stuck. Once
  the connection has ended (the server's FINs, a protocol violation) no
  ACK goes out, and one whose send fails because the end came meanwhile
  doesn't break the connection: the packets queued before the end, a
  severity-20 error among them, are still read, then the end.
* **A DATA packet waits for the server's window**, in STM and without the
  send lock, until it has room (the server keeps it 4 ahead of what it has
  consumed). Then the packets the window has room for go out in one write,
  each its own TLS record, with the send lock held for that write only.
  SYN, ACK and FIN never wait for the window and leave the sequence number
  alone. An Attention is DATA and takes a slot like any packet, so a
  cancel can wait for one in an exception handler; the server takes a
  session's request in (and ACKs it) even while the connection's running
  statement, on another session, waits for a lock, so the slot comes
  within a round trip (`Mars.AttentionWindow`: a timeout on a request of 1
  to 8 packets beside a lock wait returns on time, its Attention sent).
* **An interrupted send breaks the whole connection**, a wait for the
  window included, whichever session it was on, with every stream open on
  it. That is so even for a wait before the request's first packet, where
  the wire is clean: a trade-off made on purpose. The first packets of a
  request go out at once, since the server's window is open when a
  request starts, so a timeout only rarely lands before the first packet;
  the waits it does land in are mid-message, which only the Attention
  recovery on the [backlog](backlog.md#after-the-release) would save.
  * *Alternatives not taken:* telling the clean waits apart, and ending a
    cut-short message with an Attention on its session, which a probe
    found the server accepts ([mars-research.md](mars-research.md)).

**Busy and fully arrived** are two states, kept apart. *Busy* is what the
caller did: a response not read to its end and not cancelled-and-drained.
The transaction checks use it, so they don't depend on a result's size or
on timing. *Fully arrived* is what the reader thread saw: the response's
last packet is in the queue. It decides only how to cancel a response: one
that has fully arrived is read to its end locally; otherwise an Attention
goes out on its session and the response is drained to the acknowledgement.
An Attention after the server has finished gets an acknowledgement of its
own, so none is sent when completion is already known. If completion
arrives while the Attention waits for SMP credit, the send still records
it (`arCancellation` becomes `AttentionSent`), and the drain reads both the completed response and the
separate acknowledgement before allowing another request, rather than
leave that acknowledgement for the next response.

**Cancelling.** Two kinds of exit, with one rule each. An *ordinary* exit
leaves nothing behind: `cancelResponse`, `cancelActiveStatement`,
`release`, a pending `reset`, a transaction's cleanup, and a `withQueryS`
whose body returns or throws an exception of its own settle the response
(or every busy session) and return only when it is over on the server,
acknowledgement read, so the statement's locks are free by then. Every
Attention goes out before any acknowledgement is read (one round trip for
them all, not one per session). A statement that would have finished on
its own during an earlier drain is cancelled too, which inside a
transaction under `XACT_ABORT ON` dooms the transaction; the caller asked
for everything to be cancelled. An *interruption* never waits for the
server: an asynchronous exception out of any call (`query`, `execute`, a
fold, the body of `withQueryS`) sends the Attention at once, from the
handler, and returns, leaving the response abandoned: busy on the client,
its handle refusing further reads (`ResultAbandoned`), for the
connection's next operation to drain before it does anything else (a
request, a transaction function, `release`, `cancelActiveStatement`).
Until then the statement's locks may be held, since the server releases
them only once its response is drained; a caller that will hold the
connection idle, or whose other connections wait on those locks, calls
`cancelActiveStatement`. Plain and MARS connections follow the same rule
(`readingToEnd` and `abandonResponse` are one code path for both). The
functions that read their response to the end themselves (`query`,
`execute`, `queryFold`, `callProcedure`, `runBatchQuery`, ...) cancel it
if they throw part-way, so that no response is left holding its session
and the statement's locks with nobody to read it.

* *Alternative rejected:* draining on every exit of `withQueryS`, the
  first design: the statement's locks were free when the scope returned,
  at the cost of a `timeout` around it returning only once the server had
  stopped the statement (about 0.3 s over a `WAITFOR`, up to 40 s on a
  loaded Azure SQL database) and of a second place where a kill lands in
  a drain and breaks the connection.
* *Alternative rejected:* draining an abandoned response from a
  background thread when no request follows soon. It would race the
  application's next request for the connection lock, and it would have
  no owner to report its failure to.
* *Alternative rejected:* draining an abandoned stream instead of
  cancelling it inside a transaction (an Attention on a still-executing
  statement ends the transaction under `XACT_ABORT ON`). The client can't
  tell "still executing" reliably, a drain can take arbitrarily long, and
  the contract was already "abandoning a stream under `XACT_ABORT ON` can
  end the transaction, and `withTransaction` says so".
* *Alternative rejected:* settling one session at a time, or sending every
  Attention first only when more than one response is still arriving.
  Settle-all runs only where the caller asked for everything to be
  cancelled (`cancelActiveStatement`, `release`, a reset, and the cleanup
  of a transaction being rolled back anyway); one round trip for all of
  them is the point, and a statement that might have finished in time is
  not a behaviour anyone can rely on.

**What the sessions share on the server** is everything: one `@@SPID`, the
SET options, `#temp` tables, the database, the isolation level, the
transaction. So the unit a pool lends is still the connection, and `reset`
and `release` act on all of it.

**A setting changed under a running request doesn't last.** The server
gives each request a copy of the session's SET options, isolation level
and database when it starts, and writes the copy back when it ends
([protocol-notes.md](protocol-notes.md#mars-and-smp)), so a `SET` or a
`USE` sent while an older stream is still running is undone when that
stream ends or is cancelled. hmssql leaves that to the application, as a
documented rule: change settings with no stream open, or in
`connectSessionSetup`. Its own changes are not exposed to it. The session
setup runs at connect and with a reset, when every other session is
idle. A transaction can't begin or be committed while another response
is unfinished (`TransactionRequestsActive`), so no older request ends
inside one that `withTransactionLevel` began, and on an exception the
body's streams are cancelled before the rollback batch sets READ
COMMITTED back (measured: the level was READ COMMITTED after the exit
and stayed so).

* *Alternative rejected:* tracking the settings each open request began
  with and refusing a `SET` beside one. hmssql doesn't parse the
  application's SQL, and a stored procedure can change a setting as well.

## Interruption and cancellation

The guarantee holds for **asynchronous exceptions**: `killThread`,
`System.Timeout.timeout`, `async`'s `cancel`, or a `throwTo` of any exception
of an asynchronous type (one caught as `SomeAsyncException`). A `throwTo` of
a synchronous exception type (`throwTo t (userError "stop")`) can't be told
from a failure inside hmssql; landing while the thread waits for a response,
it breaks the connection.

**Reads.** An interruption that lands while a request waits for or reads
its response leaves the connection usable. The interrupted thread sends an
Attention at once, from its exception handler, so the statement is
cancelled on the server right away: a timed-out `UPDATE` doesn't go on to
commit. The same holds for an interruption that lands outside a read,
between two rows, in a fold's step or in the body of `withQueryS`:
`abandonResponse` sends the Attention from the handler. The stream whose
read was interrupted is abandoned (further reads throw `ResultAbandoned`),
because reading on would end at the acknowledgement without an error,
silently missing rows.

**The next operation drains.** The server releases the statement's locks
only once the client has read the cancelled response to its
acknowledgement, which the connection's next operation does first (a
request, a transaction function, `release`, `cancelActiveStatement`). The
drain calls `connectOnInfoMessage` for the INFO tokens it passes, so a
message of the interrupted request can reach the callback during the next
one, and applies the ENVCHANGE tokens, so `inTransaction` can be stale
until then (the transaction functions drain before they look). An
interruption that lands during that drain breaks the connection: there is
no resumable drain and never a second Attention. Cancellation is one
progression (`Running`, `Abandoned`, `AttentionSent`,
`AttentionAcknowledged`), and the message-end handler waits for an
acknowledgement that arrives in a message of its own.

**A drain resumes where the read stopped.** The recipe's continuation is
saved, normalized, before each interruptible receive, and a drain resumes
it without replaying consumed bytes or completed effects. An interrupted
receive keeps a fully arrived response readable; a value consumer that is
interrupted or throws is abandoned, because its consumer can't continue.

**An interruption between packets can lose one batch.** Rows are read a
packet at a time ([Decoding](#decoding)), so an interruption that lands
after a step's batch was committed as consumed but before the caller has
it loses that batch: the rows of one packet, plus a row cut by the packet
boundary. That is an interruption landing while a batch is being handed to
a `queryS` consumer, or one landing just as `readStep` returns, in its
last instructions or in the code of a `timeout` around it (which then
returns `Nothing` for a read that was done); a step that returns a token
other than a row loses that token the same way. The response then stays
readable, since nothing can tell that the batch never reached the caller,
and reading on goes on with the rows after it. `Concurrency.Stream`
("read on after interruptions") bounds the loss by the packet size, and
`Concurrency.CancelModel` allows each interrupted read that leaves its
response readable one batch.

* *Alternative rejected:* reading a token at a time, so that the loss is
  one row. The connection lock, the generation check, the masked commit
  and the exception frames then cost once per row instead of once per
  packet: 10,000 `(int, bigint)` rows through the mock server took 4.8 ms
  and 17.9 MB that way, and 1.45 ms and 5.8 MB a packet at a time
  (2026-09-27).

**Abandoned streams.** A `queryS` stream whose consumer stops early is
not interrupted: nothing sends an Attention until the connection's next
request, which cancels and drains the response before it is sent. (On a
MARS connection the next request leaves it open; `withQueryS`,
`cancelResponse`, `cancelActiveStatement` and `release` end it; see
[MARS](#mars-several-responses-on-one-connection).) A
connection going back to a pool gets the same cancel-and-drain from
`release`, its first step (`cancelActiveStatement` in `Hmssql.Connection`
does it alone), with no I/O when the response has been read to the end.
The case is common in web servers (a client that hangs up mid-response);
the example OData server leaves it to the `release` that returns the
connection to its pool.

* *Alternative rejected:* lazy cancellation, where the next request sends
  the Attention. It was the original behaviour; a timed-out statement kept
  running, and kept its locks, until the connection was next used.
* *Alternative rejected:* resuming an interrupted drain, with at most one
  Attention and a resumed wait. An interrupted drain is rare, and a broken
  connection is a clear outcome.
* *Alternative rejected:* on a MARS connection, holding an Attention back
  until the server's window shows it has taken the request in. Azure SQL
  Database, under load, ends the whole connection when it reads a request
  and its Attention together
  ([protocol-notes.md](protocol-notes.md#azure-sql-database)), and holding
  the Attention back would narrow that. But a request into a statement
  that sends nothing (a `WAITFOR`, a lock wait) gives no such signal, so
  the cancel would wait for the statement unless capped, a cap only
  narrows the window, and every early cancel would pay for it. The
  owner chose the documented limitation (2026-10-01,
  [limitations.md](limitations.md#mars)): the connection breaks cleanly
  and a pool replaces it.

**Sends.** A request is sent with asynchronous exceptions masked (`mask_`),
so an interruption can only land while the send actually blocks: on the
network, on the TLS session's write lock, or, on a MARS connection, on the
server's window, which a large request waits for every few packets (see
[MARS](#mars-several-responses-on-one-connection)). A bulk load's producer,
or a streamed parameter's `Source`, runs inside the send, so an
interruption of its own wait counts as one too. Any exception escaping a
send, asynchronous or not, marks the connection broken (the server may
hold part of a message), shuts the backend down and is rethrown; later
requests throw `ConnectionBroken` wrapping it.

* **A failure before the first packet leaves the connection usable.** The
  request is written by a `PacketWriter` as it is sent
  ([Reading and writing bytes](#reading-and-writing-bytes-which-layer)),
  and a value held in memory is encoded and checked before any of it goes
  out, so an encoding failure fails the request cleanly and leaves a
  pending reset pending. A body given as bytes has its length forced
  before anything is written, for the same reason.
* **A producer's own failure after the first packet cancels the
  message.** A synchronous exception from a streamed parameter's source or
  a bulk load's producer, once packets have gone out, ends the message with
  an Attention at a packet boundary and drains its acknowledgement, so the
  connection stays usable; a failed recovery breaks it. With no packet
  sent there is nothing to cancel, except a bulk load, whose `INSERT BULK`
  already made the server wait for the load.
* **Over TLS, one TDS packet per record.** SQL Server 2025 resets a
  strict-encryption connection whose TLS record holds more than one TDS
  packet (four 4096-byte packets per 16 KiB record failed every
  multi-packet request). The records of one message are gathered by the
  TLS backend's send (`SendGather`) and written with `sendMany` up to 64
  KiB at a time, the rest at the end of the message: TCP carries no record
  boundaries, so only the system calls change (a 4 MB parameter was 525
  `send`s of one 8 KB record, and 12.1 ms became 11.1). Every backend
  send goes through the gather's lock, so a record tls sends on its own
  while a message is being gathered (a KeyUpdate answer from the reader
  thread, an alert) is gathered with it, in order; a failed send drops
  what was gathered, since the connection is broken anyway. On a plain
  socket the packets are gathered the same way into writes of up to 64
  KiB.

* *Alternative rejected:* each packet sent under `uninterruptibleMask_`,
  with a message cut short ended by an IGNORE packet so that the
  connection could be reused. Once a peer stopped reading and the socket
  buffer filled, neither `timeout` nor `killThread` could end the wait. It
  had been introduced on a misdiagnosis: `timeout` and `race` broke TLS
  connections "often" because interruptible sends cut TLS records short,
  not because interruptions landed in a blocked write. Plain `mask_`
  removes the spurious breaks without the indefinite wait, and hmssql's
  answer to an interrupted send stays a broken connection.
* *Measured cost* (SQL Server 2025 in Docker on localhost, strict TLS unless
  said): 0 broken connections in 1800 timeouts at random points around a
  one-row query, 200 interruptions timed at a one-packet send (50 more in
  plaintext), 150 during multi-packet sends, 3000 random interruptions of
  mixed requests and 300 `race`s between two queries on one connection.
  Interruptions aimed at the drain of a cancelled response break the
  connection 15 to 23 times in 30, as designed.

**Elsewhere.** An interruption inside an info-message callback also cancels
the statement. An interruption of `withTransaction`'s cleanup rollback
propagates in place of the exception that caused the rollback, as `bracket`
does (losing the original is better than losing a `killThread` or an outer
`timeout`); the connection is marked broken. An interruption of `close`
while it sends the TLS close_notify propagates too, after the socket is
closed; an interrupted close can be completed by calling it again. An
interruption of `connect` closes the socket opened so far, except that a
`timeout` expiring during the host name lookup takes effect only when the
lookup returns (`getaddrinfo` can't be interrupted).

**Cancellation is synchronous.** Unlike PostgreSQL, which cancels out of
band over a second connection (so the cancel races the statement), a TDS
Attention travels on the connection itself and is always acknowledged:
hmssql reads up to the acknowledgement and then knows the statement is
over. Whether the server had finished sending is only known from what has
been read, so a response complete in the socket but never pulled is
cancelled like one still arriving; the server acknowledges either way.

**No Attention timeout.** If the server never acknowledges an Attention, the
next request waits forever, interruptibly. SQL Server 2025 acknowledges
one that arrived before the statement was under way only once the
statement has ended, so the wait can be as long as the statement
([limitations.md](limitations.md#behaviours-to-know-about)). Microsoft's drivers give up after
a few seconds and break the connection; hmssql has no read timeouts at all
(see [limitations.md](limitations.md)).

**Abandoning a stream can roll back a transaction.** Under `SET XACT_ABORT
ON` inside a transaction, the Attention that cancels an unconsumed `queryS`
stream is treated by the server like a timeout: if it arrives while the
statement is still sending its result, the transaction is rolled back and
the next statement runs in autocommit mode. hmssql reports it
(`inTransaction` becomes `False`; `withTransaction` throws
`TransactionEndedEarly`), but the outcome is timing-dependent (measured: 9 to
25 of 40 runs when the next request followed at once, 0 of 40 after a 1 ms
pause).

* *Alternative not taken:* draining a nearly complete response instead of
  cancelling it. The client can't tell "nearly complete" reliably
  ([MARS](#mars-several-responses-on-one-connection) has the same
  decision).

## Connection lifecycle

**`ConnectInfo`'s text settings are `Text`**, including `connectHost`,
`connectPort`, `connectInstance` and `tlsHostNameInCertificate`, as the
login fields are. Conversion to `String` happens at the backend and TLS
APIs that require it, and file paths stay `FilePath`. The port stays
textual so that service names keep working.

* *Alternative rejected:* a mix of `String` and `Text`, which made callers
  convert some fields and not others.

**The LOGIN7 server name** defaults to `connectHost` when
`connectServerName` is empty. The host is copied unchanged, without DNS
resolution, suffix stripping or host and port parsing; `ConnectInfo`
already keeps the host, port and instance apart. An explicit override is
sent unchanged, for tunnels or aliases, and a redirect replaces it with
the server's destination (below). The network destination and the login
server name stay distinct: an Azure gateway reached by IP address rejects
that address as its LOGIN7 name, so the caller overrides the logical
server name. `connectServerName` doesn't change certificate validation;
an IP destination can set `tlsHostNameInCertificate` to the expected DNS
name separately. SqlClient, Tiberius and go-mssqldb fill this field from
the configured server address, fully qualified names included.

* *Alternatives rejected:* requiring a second name for Azure SQL, and
  detecting Azure domains to extract the first label.

**`connect` tries every address in turn.** It resolves the host and tries
every address in resolver order, sequentially, rethrowing the last failure
(so `localhost`, which resolves to `::1` first, reaches an IPv4-only
server). Every address but the last is given 4 seconds
(`addressConnectTimeout`) to accept or refuse, and then the next is tried;
the last address waits as long as the operating system does, so a host
with one address behaves as a plain connect, and the whole `connect` has
no timeout of its own. A caller wraps `connect` in `timeout`; it is
cancelled cleanly, and the per-address limit doesn't catch its expiry
(`System.Timeout.timeout` throws a value unique to each call). When the
last address fails, its failure is the one reported and the earlier ones
are lost.

The limit exists because an address that is silent (a firewall that drops
the SYN, a host that is down, a stale DNS record) fails only when the
operating system gives up: after 133 s on Linux (`tcp_syn_retries` 6) and
21 s on Windows. A `timeout` of the 15 seconds Microsoft's client allows a
login then never reached a working second address: the documented remedy
made a slow connect a failed one. Four seconds outlasts one retransmission
of the SYN on either platform (1 s on Linux; Windows's 21 s fits 3 s
doubled twice, inferred from the total rather than measured), so a single
lost SYN to a working address doesn't skip it, and leaves a 15-second
caller room to reach a third address behind two silent ones. On Windows,
on hmssql's own backend, an expired limit abandons the connect's helper
thread as a caller's `timeout` does, and that thread closes the socket
when the system gives up; the cost is bounded by the number of addresses.

* *Alternative rejected:* RFC 8305's staggered parallel attempts ("Happy
  Eyeballs"). They never give up on a slow but working address, but open
  several sockets per `connect`, each a half-open connection the losing
  server sees, and need a race whose losers are closed under every
  interruption. SqlClient makes it an opt-in, `MultiSubnetFailover`, which
  is on the [backlog](backlog.md) as a `ConnectInfo` option.
* *Alternative rejected:* a share of the caller's timeout per address, as
  SqlClient's `TransparentNetworkIPResolution` is described. hmssql has no
  login timeout to divide and doesn't know the caller's.
* *Alternative rejected:* 2.5 s, which is under Windows's first
  retransmission.
* *Alternative rejected:* leaving it documented, since the documented
  remedy was the problem.

**A failure to reach the server is one exception.** A failure before there
is a connection (a name that doesn't resolve, a TCP connect refused or
reset, a failed `TCP_NODELAY` setsockopt) is `ConnectionClosedBy
(TransportFailed e)` with the original `IOException`, the same as every
later transport failure, so one handler covers "can't reach the server".
Only `IOException` is caught; an asynchronous exception passes through.

**The socket and the reader thread are set up so that nothing leaks.** The
socket is set up masked, so a `timeout` landing just after the TCP connect
can't leak it, and the reader thread is started after that cleanup's
scope, so it is never left running on a socket the cleanup closes. The
reader is labelled `hmssql: connection reader` (`GHC.Conc.labelThread`)
and always runs unmasked, whatever the caller's masking state: a reader
that inherited `uninterruptibleMask` could never be stopped, so `close`
hung.

**The protocol.** `connectProtocol` says what the connection travels on:
TCP, Shared Memory, Named Pipes, a backend of the caller's making, or
`ProtocolAuto`, the default. An explicit protocol is the only one tried.
On every platform but Windows, `ProtocolAuto` is TCP, and asking for a
pipe protocol fails at `connect` with an `IOException` that says so. On
Windows it does what Microsoft's clients do: Shared Memory if the host is
this machine, then TCP, and then Named Pipes. `localhost` therefore
reaches a SQL Server installed with TCP/IP disabled, which some editions
are, and which is where every other client connects.

* *Alternative rejected:* TCP as the default everywhere, with the pipes on
  request. It keeps a connection's transport independent of where the
  program runs, but `localhost` then fails against a default installation
  on Windows.

The rules of `ProtocolAuto` on Windows:

* **Which hosts are this machine.** `localhost`, `.`, `(local)` and the
  machine's own name, in any case. A loopback address is not: it is
  reached over TCP first, as Microsoft's clients reach it. (For the Named
  Pipes path, a loopback address does count as local, so that the pipe is
  opened directly and not through the network redirector.)
* **A port other than 1433 means TCP only.** The port names one server,
  and a pipe may lead to another. Without this rule a program configured
  for `localhost` and port 14330, a second instance or a forwarded
  container port, would be tried over Shared Memory first and would
  connect, without complaint, to the machine's default instance. hmssql
  can't tell a port that was chosen from the default, so the test is
  whether it differs from 1433. A program that wants TCP on port 1433 of
  a machine that also has a local instance says `ProtocolTcp`.
* **A named instance with the default port means the pipes only.** The
  pipes find an instance by its name (`connectInstance`). TCP would need
  the instance's port, which hmssql doesn't ask the SQL Server Browser
  for, and port 1433 belongs to the default instance.
* **Only a failure to open moves on to the next protocol.** A TLS failure
  or a refused login comes from a server that was reached, and trying
  another protocol would hide it.
* **When none opens, the failure names each.** It is one `IOException`,
  thrown as `ConnectionClosedBy (TransportFailed e)` like any connect
  failure, whose description gives each protocol's own failure and whose
  type is the TCP attempt's.

A login redirect always continues over TCP, whatever the first hop was,
since a redirect names a host and a port.

**A busy pipe is waited for, for 30 seconds.** Opening a pipe whose
instances are all in use fails with `ERROR_PIPE_BUSY`, which is Windows
saying "wait and try again", and how long to go on is the client's
choice. hmssql tries every 10 ms for 30 seconds. That is of the order of
a TCP connect's own patience (about 21 seconds on Windows) and above the
15 seconds Microsoft's client allows a login by default. A SQL Server
whose pipe listener has stopped presents exactly this, for 8 to 57
seconds on the machine measured. A caller who wants less wraps `connect`
in a `timeout`, as for a TCP connect that doesn't answer.

* *Alternative rejected:* 5 seconds. It made hmssql the least patient
  client on the platform, and the test suite's first connections failed
  where a few seconds more would have connected.
* *Alternative rejected:* waiting without limit. `connect` has no
  timeout of its own over TCP either, but there the operating system
  gives up; over a pipe nothing would.

Named Pipes to another machine is opened over SMB, so Windows
authenticates the user running the program to that machine before any
TDS is exchanged. `ProtocolAuto` does this as its last resort for a host
that refused TCP on port 1433, as Microsoft's clients do.

**`connect` failures** during PRELOGIN, the TLS handshake or LOGIN7 are typed
the same way: `ConnectionClosedBy ClosedByServer` for an end of stream,
`TransportFailed` otherwise. A rejected certificate or a TLS alert is
still a `TLSException`. A login refused by the server is `LoginError`,
whatever the error's severity: the token reader throws an ERROR of
severity 20 or more as `SqlServerError` as soon as it is parsed, breaking
the connection at once ([Exceptions](#exceptions)), and the login turns
that into `LoginError` too, since `connect` has no connection to return
either way.

**A handshake failure reports its cause.** tls turns a backend exception
during the handshake into `HandshakeFailed (Error_Misc text)`, keeping
only the text, so the handshake's backend records the first exception its
sends and receives throw, and a handshake that tls says failed that way
rethrows the recorded one. An end of stream is `HandshakeFailed
Error_EOF`, thrown as `ClosedByServer`. Which of these it was is taken from
what tls reports, and the record is consulted only for `Error_Misc`,
because a recorded exception is not always the cause. Once tls has
decided that a handshake failed, it tries to send an alert, and on a
stream whose other end has closed that send fails and is recorded after
the fact. Over TCP the mock closes one direction only and the alert goes
out. On a pipe, which can only be closed whole, the failed send was
reported in place of the end of stream, and in place of the server's own
alert.

* *Alternative rejected:* the recorded exception whenever there is one.
  It reports a consequence as the cause on any stream that is closed
  whole.

**`isTransientLoginError`** says which refusals mean the server may take
the same login shortly: 6005 (shutdown in progress), and Azure SQL's
40613, 40501 and 49918 to 49920. 4060 is not in the list, though
SqlClient's configurable retry logic counts it as transient: it is also
what a database that doesn't exist gets.

* *Alternative rejected:* retrying the transient refusals inside
  `connect`, as SqlClient can be configured to. How long to wait and how
  often to try are the application's to decide, a retry hides a wait from
  a caller who may hold a `timeout` around `connect`, and a pool that
  retries on its own can lock an account out.

**Login redirects.** A routing ENVCHANGE (type 20) in the login response
(Azure SQL's Redirect policy, read-only routing) is followed: the socket is
closed without a goodbye (the reader was never started) and the caller's
`ConnectInfo` connects to the host and port named, an instance name after
a backslash dropped. Every hop starts from the caller's settings (MS-TDS
3.2.5.10: nothing from the redirected login applies to the next). Up to
ten redirects in a row are followed, the limit SqlClient sets (its check,
counting from zero, lets 11 through); no known server chains them, and the
limit stops a loop. A redirect naming no host (or only `\instance`), port
0 or a protocol other than TCP is a `ProtocolError`, as SqlClient rejects
them. The LOGIN7 server name becomes the target's,
`host,port` as SqlClient sends it: Azure's node derives the logical server
from it, and answers the gateway's `connectServerName` (a bare `myserver`)
with error 40613, "Database 'mydb' on server '' is not currently
available", and an empty one with 40531. Everything else is kept: the TLS
settings (so the certificate is validated against the new host, which
Azure's node certificates cover) and an access token. An eleventh redirect,
and a redirect in the plaintext response of an `EncryptOff` login (checked
at every hop), are `LoginRedirected`. All the logins run under one `mask`,
whose `restore` covers each lookup, TCP connect and login, so a `timeout`
anywhere closes whichever socket is open, and the connection returned is
returned masked (`Resources.ConnectTimeout` sweeps a timeout across a login
redirected twice). Enhanced routing (ENVCHANGE type 21, which also names a
database, for Azure SQL Hyperscale's reader endpoints) is not requested, so
a server should not send it; one that did would be ignored as an unknown
ENVCHANGE, as SqlClient ignores one it didn't negotiate
([backlog.md](backlog.md)).

**`close`** from another thread fails a request in flight (waiting for its
response, streaming rows or sending), and every later use, with
`ConnectionClosedBy ClosedByClient`. It records the reason first, then shuts
the backend down (which ends a blocked send at once), sends the TLS
close_notify if no send is in progress, stops the reader thread, and closes
the socket once the sender has released the send lock. Once the reader has
stopped it drops the TLS session, its buffers and parameters, the receive
buffer and the response being read, so a closed connection that is still
referenced (a pool entry, a stream) keeps under 1 KB rather than the 3.3
MB of a TLS session. The reader's `ThreadId` is held weakly. The reader is
stopped but not waited for: `close`, and a `connect` that fails after
starting it, returns once the exception has been raised in the reader
thread, which reads nothing more but may not have run its exit yet, so a
count of live threads taken at once can still include it. `close` never
throws a synchronous exception for a failed socket close (see the GHC bug
under [Platform](#platform-workarounds)); the connection is closed either
way.

**A connection dropped without `close`** is closed, socket included, once it
is garbage. The reader thread refers only to the transport and the two
variables it fills, never to the `Connection`, so it doesn't keep it
reachable. The finalizer doesn't wait for senders; a thread sending keeps
the connection reachable explicitly (`keepAlive#`) rather than relying on
the optimiser, and so does `close` until it has closed the socket. Without
that, `close` given the last handle (as `withConnection`'s is) refers only
to the fields it has read, a collection during it finds the connection
garbage, and the finalizer closes the socket under the TLS close_notify
([bugs-found.md](bugs-found.md#connection-lifecycle-and-transport)).

**A broken connection** throws `ConnectionBroken`, carrying the first
cause's `UnusableReason` ([Exceptions](#exceptions)), from every later
request until `close`. The causes: an exception escaping a send, an
interrupted cancel-drain, a failed or interrupted setup batch after a
reset, a failed or interrupted `release`, a failed transaction cleanup, a
`ProtocolError`, a reader thread that died of anything other than a close,
a DONE_SRVERROR with no ERROR token, and a `SqlServerError` of severity 20
or more.

**A fatal ERROR breaks the connection as soon as it is parsed**, and
throws that server message, including during a cancellation drain. It
takes precedence over an earlier nonfatal ERROR. This is shared token
processing, so raw readers, queries, both batch APIs and discarded
responses follow the same rule, and `release` returns `False` for such a
connection before the server's DONE, end of stream or SMP FIN arrives.
The MARS reader still lets the packets queued before a server's FIN be
parsed, so that a fatal message received just before the close reaches
the caller instead of being lost to a failed flow-control ACK; once the
fatal token is parsed, every other session refuses further work.

* *Alternative rejected:* waiting for the final DONE, the end of stream
  or the SMP FIN. The transport's closure can arrive later, leaving a
  window in which `release` would admit the connection to a pool.

**Released handles.** After `release`, the handle it was given throws
`ConnectionReleased` from every operation, streams it produced included,
before anything is sent; only `close`, `connectionContext`,
`inTransaction` and `renew` still work through it. The connection is not
affected, and a stale handle to a broken connection throws
`ConnectionReleased`, not `ConnectionBroken`. A stream of a released handle
throws `ConnectionReleased` rather than `ResultAbandoned`, so that one
rule covers everything: a released handle can't reach the connection. A
second `release` of the same handle throws too, so a connection checked in
twice is found out in the thread that checks it in (the recipe then closes
it and gives up its slot).

`release` inside `withTransaction` is unsupported, like `reset`, and ends
loudly. It runs reentrantly (the body's thread holds the lock), its reset
request rolls the transaction back, and the lease moves on. After the body,
the drain of any pending response that comes before the `COMMIT` throws
`ConnectionReleased`; the cleanup rollback throws it again, so the
connection is marked broken (`RollbackFailed`), and
`withTransaction` throws `ConnectionReleased`. Nothing hangs and the cleanup
sends nothing. The pool's own `release` at check-in then throws
`ConnectionReleased` as well.

## Session setup and reset

**`defaultSessionSetup` is empty.** Logging in with the LOGIN7 `fODBC` flag
already gives the session what Microsoft's drivers set: ANSI_NULLS,
QUOTED_IDENTIFIER, ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL and
ANSI_NULL_DFLT_ON on; NUMERIC_ROUNDABORT, IMPLICIT_TRANSACTIONS and
CURSOR_CLOSE_ON_COMMIT off; TEXTSIZE unlimited (-1). The only setting of the
old ten-statement setup the login didn't provide was `ARITHABORT ON`, which
with ANSI_WARNINGS on has no functional effect and matters only as a
plan-cache key (SSMS sets it on, most drivers off). `["SET ARITHABORT ON"]`
is the documented opt-in for plan-cache parity with SSMS.

* *Alternative rejected:* a default setup of the ten SET statements
  Microsoft's drivers imply, which cost ten round trips at connect for
  settings the login already gives.

**The setup runs as one batch**, statements joined with newlines, at connect
and after a reset, so the two can't differ: as separate batches, a setup
that declared the same variable twice worked at connect and failed after a
reset. A setup batch that fails, or whose response can't be read, breaks
the connection: how much of it ran is unknown, and a connection whose
options are unknown is worse than none.

**`reset`** sets a one-shot flag: the next SQLBatch or RPC carries the
RESETCONNECTION status bit on its first packet, which returns the session to
its state after login (SET options, TEXTSIZE, language, date format,
DATEFIRST, lock timeout, deadlock priority, the database after `USE`,
CONTEXT_INFO, SESSION_CONTEXT, `#temp` tables, global cursors, locks and
applocks, an open transaction). With an empty setup the bit rides on the
request itself: no extra round trip, which matters when calling Azure SQL
from outside Azure. With a non-empty setup, one batch that re-runs it
precedes the request, carrying the bit (SET statements can't ride along in
an RPC, where they revert when it returns, and can't be prefixed to the
caller's batch, which may have to start with `CREATE PROCEDURE`).
RESETCONNECTION keeps the isolation level on SQL Server (2025; Azure SQL
Database puts READ COMMITTED back), and hmssql does not add a `SET
TRANSACTION ISOLATION LEVEL` to the setup batch; a session setup can include
one. To reset right now, call `callProcedure conn "sp_reset_connection" []`:
a round trip, the isolation level is reset, the session setup is not re-run.

* *Alternative rejected:* an eager `reset` function, or making reset an
  explicit pool-boundary operation. The lazy flag is the cheap one, and the
  RPC covers the eager case. `release`, the pool-boundary operation, keeps the reset lazy on a clean connection (no I/O at
  check-in) and carries it out at once only when a transaction is open,
  checked after the pending response is drained, since that response may
  begin or end one. Then one request bears the bit: a `SELECT 1` batch with
  an empty setup, the setup batch otherwise. The server rolls the
  transaction back and releases its locks before the connection idles in
  the pool, and the round trip doubles as a liveness check. The reset's
  ENVCHANGEs end the tracked transaction and the flag is consumed, so the
  next borrower's first request doesn't carry the bit again.
* *Not a liveness check:* `reset` does no I/O, so `try (reset conn)` never
  fails on a dead connection. `release` is the check a pool wants: `False`
  for a connection known to be broken or closed, or that fails its drain or
  reset request. It doesn't probe either, so a session dropped without the
  socket being closed is still found only by the next request.
* **A failed DONE without an ERROR token** in the setup batch's response,
  or in `release`'s `SELECT 1`, is a failure (`SevereError`), as it is for
  a query: at connect no connection is returned, after a reset the
  connection is broken, and `release` returns `False`. It is how the server
  refuses a reset. Without a session setup a refused reset doesn't break
  the connection: the request that carried the bit throws `SevereError`,
  `release` can still return `True`, and the server applies the reset once
  the request that blocked it ends. The library sends the bit only after
  settling every other response, so its own sequencing can't be refused
  (`Mars.SmpReset` pins both cases).
  * *Alternatives not taken:* breaking the connection on a reset-carrying
    response that ends in a failed DONE without the acknowledgement, which
    would hang the decision on a server detail no live run has shown; and
    re-arming the reset, which would only repeat the refusal.
* `reset` inside `withTransaction` is unsupported: the transaction ends with
  `TransactionEndedEarly`, and the request after the reset is out of the
  transaction but still at the transaction's isolation level. A `reset`
  (or a `release`) from another thread waits for the transaction to end.

**On a MARS connection** the server refuses a reset while another request
is active (a bare failed DONE, and every later request fails the same way
until that one is cancelled). So a request that is to carry the bit first
settles every open response, as `cancelActiveStatement` does, and their
streams throw `ResultAbandoned`.

**The reset gate.** A request sent on another session right behind the one
carrying the bit races it, and is refused if the server runs it first. The
reset's acknowledgement is among the ENVCHANGE tokens that begin the
carrying request's response, and nothing sent after those had arrived was
ever refused. So before any request starts, the response of a reset still
in flight is read up to its first token that is not an ENVCHANGE
(`awaitReset`). The tokens are read by the ordinary reader, which applies
each once, and kept in the response's replay queue (`arReplay`) for its
consumer, which gets them first; the callbacks run once, when they are
read. The gate stops before a row (`StopAtRow`), consuming nothing of it,
so the queue holds only tokens; it may still have to resume a leading
ENVCHANGE or a first COLMETADATA cut by a packet, after an interrupted
wait. The wait comes before anything is sent, so an interruption of it is
harmless and cancels nothing.

* **A cancelled request that carried the reset has been reset all the
  same.** SQL Server applied the reset and acknowledged it in the
  cancelled response in every one of 6,000 tries (batch, RPC and TM
  requests, the Attention 0 to 3 ms behind them, with and without MARS);
  if a drained response ever lacks the acknowledgement, the reset flag is
  set again.
* **What the gate costs.** The first request after a `release` or `reset`
  holds every other request of the connection back until it has produced
  its first packet, so one that is slow to (a `WAITFOR`, a long sort, a
  lock wait) delays them by that much. The server would have held most of
  them back anyway (a statement that doesn't yield stops every session),
  and an interleavable stream produces its first packet at once. With a
  session setup there is no gate, since the setup batch that carries the
  bit is read in full.
* *Alternative rejected:* the gate at the reset itself, as a probe first
  had it ([mars-research.md](mars-research.md)). At the next request, the
  carrying request returns as soon as its response is registered.
* *Alternative rejected:* reading the leading tokens and any rows into the
  replay queue, then writing a row back to TDS bytes to replay it through
  the parser. It was a second copy of the row's entry and exit, and the
  gate needs nothing past the ENVCHANGE tokens.

## Transactions

**Manual transaction control uses `begin`, `commit` and `rollback`**, as in
hpgsql and postgresql-simple. SQL Server's nesting and MARS rules still
apply; the names don't imply PostgreSQL's transaction behaviour. `begin`
doesn't refuse a nested transaction, hold the connection for the
transaction's duration, or roll back on an exception; those are
`withTransaction`'s.

**`withTransaction` and `withTransactionLevel`** hold the connection lock for
the whole body. Nesting, or starting inside a transaction begun by hand or by
`IMPLICIT_TRANSACTIONS`, throws `TransactionAlreadyActive` without touching
the outer transaction.

* *Alternative rejected:* letting the inner `BEGIN` nest. An inner failure
  then rolled back the outer transaction while the outer body kept running
  in autocommit.
* *Alternative rejected:* emulating nesting with savepoints.

**The begin is a request of its own, before the body**, and a Transaction
Manager request (TM_BEGIN_XACT), not a `BEGIN TRANSACTION` batch, on every
connection. SQL Server refuses the batch form on a MARS connection, with
error 3997. The Transaction Manager request works on both kinds of
connection, and on a plain one it behaves exactly as the batch does: the
same ENVCHANGE, the same `@@TRANCOUNT` and nesting, the same doomed state,
and a reset can ride on it the same way. One code path is better than two.
Its isolation-level byte carries a
`withTransactionLevel` level (the session keeps that level afterwards, as
after a `SET`). `withTransaction` reads its response to the end before the
body runs, so the transaction is begun, and its descriptor known, before
the body's first request: a round trip per transaction. If the request
fails or is interrupted part-way, the cleanup batch runs, so the session's
level is set back whatever happened. Commit and rollback stay T-SQL
batches, which work on a TM-begun transaction and carry the level restore
in the same round trip. A failed begin throws a `SqlServerError` whose
`sqlErrorStatement` is `BEGIN TRANSACTION`, under `withTransactionLevel`
too: no SQL is sent, and the name says what failed.

* *Alternative rejected:* TM commit and rollback requests. They would need
  a second request for the level restore.
* *Alternative rejected:* naming a failed begin under
  `withTransactionLevel` by a `SET TRANSACTION ISOLATION LEVEL ...; BEGIN
  TRANSACTION` text, which isn't sent.
* *Alternative rejected:* sending the BEGIN with the body's first
  request, in front of a SQL batch's text or as a batch just before an RPC,
  saving the round trip. It spread a transaction state machine (armed,
  sent, settled, voided) over request encoding, token application, response
  completion, reset and cleanup; a keyword blacklist decided whether a
  batch could take the prefix (statements that must start their batch);
  a BEGIN cancelled by an Attention before it ran had to be re-armed, and
  the re-armed state could skip the level's cleanup. An explicit
  transactional-batch API is the way to save the round trip, and it is on
  the [backlog](backlog.md).
* *Alternative rejected:* folding into RPCs by prefixing `@stmt` (the
  scoping of `sp_executesql` makes the BEGIN a nested transaction count of
  the call, error 266) or by sending a SQL batch and the RPC in one message
  (TDS has one request per message).

**A request carries the transaction descriptor as it stands after the
drain.** The descriptor a request carries in ALL_HEADERS is read with the
mutex held, after everything that precedes the request, including the
drain of a response the request abandons. That drain can read an
ENVCHANGE that ends the transaction, such as an unread `COMMIT
TRANSACTION` in the abandoned response, and the server fails a request
carrying a descriptor that has ended with error 3971, having done
nothing. `Transaction.TmBegin` pins the order against a mutant that reads
the descriptor before the drain.

**An asynchronous exception during the COMMIT** may arrive after the
server committed: the transaction then stays committed, and the exception
is rethrown all the same (the body's effects are durable; the caller's
`timeout` says only that it didn't wait for the answer).

**Before COMMIT, the transaction's identity is checked.** The transaction
descriptor the connection tracks from ENVCHANGE tokens is compared with the
one the begin's response reported. If the transaction is gone (the server rolled it
back after an error the body caught: XACT_ABORT, a deadlock, a doomed
transaction; or the body ran COMMIT or ROLLBACK itself), was replaced
(`ROLLBACK; BEGIN TRANSACTION` in the body) or a reset is pending, the
wrapper rolls back whatever is open and throws `TransactionEndedEarly`
instead of the server's error 3902 or committing the wrong transaction.

* *Alternative rejected:* checking only that a transaction is active,
  which commits a replacement transaction begun in the body.

**After the COMMIT, no transaction may be open.** A body that begins a
nested transaction (`begin`, or a `BEGIN TRANSACTION` batch) and
doesn't end it leaves `@@TRANCOUNT` at 2, and the COMMIT only lowers it,
leaving the work uncommitted and its locks held. So if the connection is
still in a transaction after the COMMIT's response, the cleanup batch rolls
everything back and `TransactionStillOpen` is thrown. A balanced nested
begin and commit still commits.

**On a MARS connection the transaction is the connection's**, and the
caller keeps its reads in order: no response may be busy when a
transaction begins or is committed. The server refuses a begin beside an
active request (3988) and a commit beside one (3981, and the transaction is
lost); hmssql checks first and throws `TransactionRequestsActive`, naming
the statements, so a stream left open can be found. A message of several
statements (from `runBatchQuery`, `executeStatements` or `executeMany`)
is named by its last statement, the one a `batchQueryS` stream reads and
so the one left open. The check is on what
the caller has read, not on what has arrived: the server would accept a
commit once the other responses have fully arrived, but a rule that lets
the same code commit with a small result and fail with a large one is no
rule. "Read" means the stream returned, not that its last row was seen
(the final DONE is still unread then). The library never cancels a stream
to make a commit succeed; on the way out after a failure it does: the
cleanup first settles every open response (Attention, acknowledgement
read) and then rolls back, an order that never meets the state where the
server keeps a rolled-back transaction, doomed, until the other requests
end (errors 3989 and 3998). `commit` makes the same check and
leaves the transaction open; `rollback` settles and rolls back;
`begin` checks like `withTransaction`.

* *Alternative rejected:* naming a message of several statements by every
  statement joined (up to 1 MB for `executeMany`), or by its first
  statement and a count.
* *Alternative rejected:* an exclusive transaction scope with a
  transaction handle, or a transaction-scoped opener of sessions, as the
  second MARS spike proposed ([mars-research.md](mars-research.md)); every
  request the body makes runs in the transaction. Keeping the old descriptor, with a gate that orders
  requests around a commit, isn't needed either, since the begin makes the
  same check as the commit.

The check also keeps the transaction state right. ENVCHANGE tokens are
applied to the shared context by whichever consumer reads them, in the
order of reading, not the server's. Since a transaction begins only when
no session is busy, every ENVCHANGE of an earlier transaction has been
read by then, and none can arrive later and clear the new descriptor;
while one transaction is open, every commit or rollback ENVCHANGE any
session delivers is that transaction's; and a request carrying a reset is
sent only with every other session settled.

* *Alternative not taken:* clearing the descriptor only when the ENVCHANGE
  names the current one. Which descriptor each rollback ENVCHANGE carries
  (the second one after 3998, the one in an Attention's acknowledgement)
  isn't established, and a mismatch would leave a stale descriptor.
* *Not added:* typed exceptions for 3971 and 3989 (a request that lost to
  the end of its transaction); they surface as `SqlServerError`.

**Cleanup** after a failure is `IF @@TRANCOUNT > 0 ROLLBACK`, run after
draining any pending response, so an asynchronous exception during the begin or
COMMIT can't leave a transaction open. If the cleanup itself fails, the
connection is marked broken with `RollbackFailed` rather than left
in an unknown state. `rollback` is conditional on `@@TRANCOUNT`
too (after a `reset`, the reset has already rolled the transaction back, and
an unconditional ROLLBACK failed with error 3903).

**`release` ends a transaction as a reset does.** A transaction left open
on a connection going back to a pool (begun in SQL, or by
`IMPLICIT_TRANSACTIONS`) is rolled back by the reset, which `release`
carries out at once in that case, so its locks go with it. A
`withTransaction` running on another thread is not ended from outside:
`release` waits for its lock. A `release` inside the body is under
[Connection lifecycle](#connection-lifecycle).

**`withTransactionLevel` sets READ COMMITTED back** in the COMMIT and cleanup
ROLLBACK batches, however the transaction ends. The session is assumed to be
READ COMMITTED (the level at login) outside `withTransactionLevel`; a level
the application set by hand is not preserved. `withTransaction` (no level)
doesn't touch the level, so a level the body sets stays set.

* *Alternative rejected:* reading the session's level from
  `sys.dm_exec_sessions` in the BEGIN batch and restoring it afterwards, at
  no extra round trip, through a resumable BEGIN batch. The machinery, a
  second implementation of response handling inside `Hmssql.Transaction`,
  was too much for the promise; removing it took the module from 248 to
  164 lines.
* *Alternative rejected:* leaving the level set, the original behaviour,
  which leaked it into every later statement on the session.

## Queries

**A `Query` is SQL text with its parameters.** It holds fragments (static
text and placeholders for positional parameters) and parameters, each a
name (empty for a positional one) and an encoder to run against the
connection's `TdsContext`. The query functions take a `Query` and nothing
else, so text and values never travel apart. This is hpgsql's design.

* *Alternative rejected:* functions taking `Text` plus a `ToSqlRow` value,
  as the first version of hmssql did. SQL built at runtime then had to
  carry its parameters by hand, and the OData example grew its own fragment
  monoid to do it.

**The query functions mirror hpgsql's** in name and shape: `query`,
`query1`, `queryMay`, `queryS`, `execute` and `execute_`, with `With`
variants that take an explicit applicative `RowDecoder` and `MWith`
variants that take a `RowDecoderMonadic`. `execute_` discards `execute`'s
count, and `query1With` and `queryMayWith` combine an explicit decoder with
the cardinality checks, so a caller needs no `FromSqlRow` instance just to
read a single row with a custom decoder. They reuse the ordinary query
paths, so draining and error handling are the same. `Hmssql.BatchQuery`
mirrors `Hmssql.Query` consumer for consumer (`batchQuery1With`,
`batchQueryMayWith` and the rest). `queryMultiWith` and
`batchQueryMultiWith` take an applicative `RowDecoder` and compile it once
per result set, checking empty sets too; their `MWith` counterparts take a
`RowDecoderMonadic`. A known shape then doesn't have to be lifted to a
monadic decoder, which repeats the column checks for every row, merely to
read a variable number of result sets.

**A response's result sets are read in two phases**, before the first
COLMETADATA and with a compiled decoder for the current set, written as
two functions, so that the state is where the code is. Columns and row
batches travel as arguments within a set, and a procedure's status and
output values fold over the whole response, as arguments too. A row
before the first COLMETADATA is refused by the reader itself, with a
`ProtocolError` that breaks the connection. A batch statement drops its
result-set metadata only when its DONEPROC has been consumed and the
statement closed; the next statement must supply its own. Clearing it
when a statement opens would lose metadata the reset gate had already
applied and queued for replay
([Session setup and reset](#session-setup-and-reset)).

* *Alternative rejected:* one loop holding a `Maybe` current result set,
  `Nothing` only before the first COLMETADATA, with a `ProtocolError` and a
  `RowRead` that refuses rows (`RefuseRows`) for a case the reader already
  refuses, and a procedure's results in four `IORef`s.

**Sent as a batch, or as `sp_executesql`.** A query with no parameters goes
out as a SQLBatch; one with parameters as an `sp_executesql` RPC, the
positional parameters declared as `@p1`, `@p2`, ... in the order they appear
in the parameter list and the named ones under their names. The rule is
derived from the query rather than chosen by the caller, because the two
can't be confused: a batch can't carry parameters, and a parameterless
`sp_executesql` differs from a batch only in scoping (a `SET` option or a
`#temp` table created inside it doesn't outlive the call), which is what
the batch form is for. A parameterless RPC remains reachable as
`callProcedure conn "sp_executesql" [...]`, and `queryRequest`,
`batchRequest` and `executeSqlRequest` are public for anyone who wants the
`Request` itself.

**Concatenation renumbers, in constant time.** `<>` appends the text and
the parameters, shifting the right operand's placeholders past the left
operand's positional parameters; named parameters keep their names (the
same name in both operands is a duplicate, refused at send). `mempty` is
the empty query. So `param x` is "the next parameter, whatever number it
gets", and a query assembled from optional pieces in any order comes out
right. A `Query` is a tree of pieces, each piece numbering its placeholders
among its own positional parameters and each node caching its positional
count; `<>` is one node, and the absolute numbering is computed in one pass
when the query is rendered. Building a query from *n* pieces is O(n)
whichever way the `<>`s associate (`hmssql-bench/Bench/Sql.hs` measures it: 10000
pieces in a few milliseconds by `foldr`, `foldl` or `mconcat`).

* *Alternative rejected:* flat lists, with `<>` copying the
  left fragments and shifting the right ones. A right-associated chain,
  which is what `a <> b <> c` and `foldMap` produce, re-shifted the whole
  suffix at every step: 2100 pieces (the most a request can carry) took
  half a second, and 10000 twelve seconds.

**`mkQuery` lexes `@pN`; nothing else parses anything.** `mkQuery text row`
keeps the `sp_executesql` writing style (positional `@pN`, or names with
`NamedParams`), and for the placeholders to renumber under `<>` the text has
to be scanned for them. The scanner (`Hmssql.Query.Lexer`) recognises `@p`
followed by ASCII digits, either case, standing alone as a name (not after
`@` or an identifier character, not followed by one), outside string
literals (`'...'`, `N'...'`, with `''`), quoted identifiers (`"..."`,
`[...]` with `]]`) and comments (`--`, nested `/* */`); anything
unterminated runs to the end of the text, and the scanner never fails. The
consequence is that `@p<digits>` is reserved for the positional parameters:
a `DECLARE @p1` in `mkQuery` text is a placeholder with no parameter (an
`EncodeError` at send), and a `NamedParams` name of that shape is refused.
String literals (`IsString`) and `rawSql` are verbatim: `"SELECT @p1"` sent
as a batch is the server's "must declare the scalar variable".

**Rendering keeps a placeholder apart from adjacent name characters.**
`"x = " <> param 1 <> "1"` is sent as `x = @p1 1`, not `x = @p11` (another
parameter, silently, once there are that many), and `"N" <> param s` as
`N @p1`, not the identifier `N@p1`. The property test that found this
concatenates random pieces and checks that the rendered text refers to
exactly the parameters the query has.

**Errors are found before anything is sent**, as `EncodeError`: a
placeholder outside the positional range, a reserved or invalid name, a
duplicate name (case-insensitively, as SQL Server compares them), a value
the encoder refuses. `Show` renders the text with `@pN` and never a
value; `sqlErrorStatement` carries the same text.

**`query` collects a batch's rows in reverse** inside the library
(`ReversedBatch`) and reverses them once when the result is assembled, a
list cell per row less: 14.4% less allocation collecting 10,000 rows.
`readStep`, streaming and folding keep the public order, and `RowBatch`
stays in order.

* *Alternative rejected:* a public reversed batch, a contract change for 24
  bytes a row.

**`execute`'s count is the sum of every DONE count in the response**,
including the rows a trigger writes and every statement of a batch, as
SqlClient's `ExecuteNonQuery` counts them. An `OUTPUT` clause's result set
is not counted again, and a `MERGE` counts its updates and inserts
together. `Shapes.Batches` pins these, and `Shapes.ExecuteMany` checks
that `executeMany` counts each statement as `execute` would. Under `SET
NOCOUNT ON` no DONE carries a count, so the count is 0.

* *Alternative rejected:* counting only the top-level statement's DONE,
  without the trigger's rows, or only the last statement's. Either differs
  from SqlClient, and a caller who wants a count per statement has
  `executeStatements` and `executeManyOutcomes`.

**`executeStatements`: several statements, one RPC message.** Each statement is
an `sp_executesql` RPC and they travel together, 0xFF-separated under one
ALL_HEADERS, so a list of single-row writes costs one round trip instead of
one each. The response is read with `nextStep` directly (not the cursor
that withholds ERROR tokens), because an error must be attributed to its
statement: each RPC's tokens end with a DONEPROC (a procedure its body
EXECs reports DONEINPROC, not DONEPROC), so the tokens up to the first
DONEPROC are the first statement's, and a statement's count is the sum of
its DONE counts, what `execute` sums. The server goes on to the next RPC
after an error that ends only its statement or its call, and ends the
message at a batch abort; hmssql reads the whole response either way and
then throws the first failure with its statement's text. A response with
fewer DONEPROCs than statements means the rest didn't run.

The statements go out in messages of about 1 MiB (the size estimated from
the encoded values), each read to its end before the next is sent, and the
list is consumed as it goes, so memory is bounded by a message, not the
list. The split is invisible: a message whose statements all ran (with
errors or not) is followed by the next, as one RPC follows another in a
single message, and a message that ended early is the last. What the split
does change: an `EncodeError` in a later message comes after the earlier
ones ran (within a message, nothing is sent), and each message is a
request of its own (a pending reset rides on the first; the transaction
descriptor is re-read for each, which is if anything more exact).

`executeStatementsOutcomes` and `executeManyOutcomes` return the same reading
of the response as a list of `StatementOutcome`s (a count, the first error,
or not run) and throw only what isn't a statement's error. The throwing
form can only name the failing statement's text, which for `executeMany`
is every row's; the outcomes say which row.

* *Alternative rejected:* one message however long the list, leaving the
  caller to split. The whole message would be built in memory before the
  first byte is sent: about 150 MB for 10^6 rows.
* **A statement without parameters is sent through `sp_executesql` too**,
  where a `SET` or `#temp` table it makes ends with the call. That is what
  `executeStatements conn ["DELETE FROM a", "DELETE FROM b"]` expects, and
  the Haddock says where the scoping differs.
  * *Alternative not taken:* refusing such a statement with an
    `EncodeError`.
* *Alternative rejected:* joining the statements into one SQL batch. A batch
  can't carry parameters, and the count and error per statement would be
  lost.

**`RowEncoder` produces per-parameter encoders**
(`a -> [(Text, TdsContext -> Either String EncodedParam)]`), where it used
to take the context first and produce the encoded list. A query's parameter
count and names are then known without a connection, which `<>` needs;
no encoder's count ever depended on the context.

* *Alternative rejected:* a `[sql|...|]` quasiquoter with `#{expr}`
  interpolation, as hpgsql has. It needs a Haskell expression parser at
  compile time (hpgsql depends on ghc-lib-parser; the compiler's own `ghc`
  package would do the same at no build cost), it is more magic than a TDS
  library should carry, and it would set a style for a package whose job is
  low-level access. `Query` is the piece a quasiquoter needs; one can be
  built on top of `Hmssql.Query.Types`.
* *Alternative rejected:* an explicit request mode on the query (batch or
  RPC). With parameters the choice is forced; without, the batch is the
  form that has a use.
* *Alternative rejected:* keeping the parameterless functions (`query_`)
  beside the `Query`-taking ones. With `IsString` they would be synonyms;
  one function per shape. (`execute_` is not one of them: it is `execute`
  with the count discarded, below.)
* *Alternative rejected:* not lexing `mkQuery` text and letting `@pN` refer
  to the row by absolute number. Then `param y <> mkQuery "... @p1" (Only x)`
  would send `@p1` for both, silently binding `y` where `x` was meant.

**Batch queries: one RPC per statement, read through a bounded reader.**
`BatchQuery` (`Hmssql.BatchQuery`) is an `Applicative` pairing each
statement with a consumer; `runBatchQuery` sends the statements as
`executeStatements` does (one `sp_executesql` per statement, in messages of
about 1 MiB) and drives the consumers in order, each over the connection's
`ResponseReader` bounded to its statement (`respBatch`): the reader
returns the statement's DONEPROC and then `StepEnd`, so the consumers are
the plain query functions' readers (`readFirstResultSet`,
`affectedRows`, the `ResultSets` monad) unchanged, and what a consumer
leaves unread is skipped before the next statement's. In the bounded
mode an ERROR token isn't withheld: the rest of the response and the
messages after it are read (their statements run, as they would in one
message), then the error is thrown for its statement, so a consumer's
own shape error (`query1` on the empty set a failed `SELECT` left) can't
preempt the server's. A consumer that throws (a `DecodeError`, a fold's
step) has the current response drained before the exception propagates,
as `query` does; the messages after it aren't sent. A fatal ERROR instead
ends reading immediately and breaks the connection; no later message is
sent. Both batch readers attach the statement being consumed to that
error, rather than the last statement used to name the request.

* *Streaming only the last statement.* `batchQueryS` hands out a stream
  read after `runBatchQuery` returns, as `queryS` does; a stream in the
  middle would make the statements after it `IO` actions to be run in
  order on one thread, hpgsql's rule for its pipelines, and its footgun.
  Refused before anything is sent (`EncodeError`). There is no scoped
  `batchQueryS`: on a MARS connection a stream left open holds its session
  and makes a commit throw `TransactionRequestsActive`, so batch the
  statements that don't stream and use `withQueryS` for the one that
  does, with `cancelActiveStatement` as the escape hatch.
* *Alternative rejected:* a `withBatchQueryS`, or the statement's reader
  returned with the stream for `cancelResponse`. The combination is rare,
  the workaround costs one round trip, and a scoped form would add a
  second shape to `BatchQuery`'s API; it can come with a statement that
  streams from the middle of a batch
  ([backlog](backlog.md#after-the-release)), which reshapes `BatchQuery`
  anyway.
* *Alternative rejected:* joining the statements into one request (a SQL
  batch, or one `sp_executesql`), which shares `#temp` tables and `SET`
  options across them. A statement's results then have no reliable
  delimiter: DONE tokens come per statement, per trigger, per statement
  of a called procedure, and `DONEINPROC`s from a nested procedure look
  like the caller's. That form stays available as `queryResultSets` over
  a joined `Query`.
* *Why not "pipeline":* a libpq pipeline is the client sending requests
  without waiting, run in one implicit transaction and skipped after an
  error; TDS has one request per message and commits each statement on
  its own, and later statements run after an earlier one's error. The
  server's word for that is a batch, and the name says which behaviour
  to expect. The shape is still hpgsql's `Hpgsql.Pipeline`: an
  `Applicative` whose combinators take a query and name what to do with
  its rows. Two consequences of the difference for the API: hpgsql's
  `runPipeline` returns `IO` actions to be run later, in order, on the
  same thread, because any of its statements may stream, where here every
  consumer but the last runs inside `runBatchQuery` and only the last
  statement may stream, so there is no ordering rule to get wrong; and a
  PostgreSQL statement's result is one thing while a SQL Server
  statement's is a run of tokens (any number of result sets and DONE
  counts, from a procedure it calls or a trigger it fires), so the batch
  is one RPC per statement, delimited by its DONEPROC, and
  `batchQueryMulti` and `batchQueryResultSets` read all of a statement's
  result sets where hpgsql has one row type per statement.

## Parameters and encoding

**`FieldEncoder` and `RowEncoder` are `Contravariant`**, from `base`, as in
hpgsql. Adapting a field encoder keeps its NULL type, and adapting a row
encoder keeps parameter order and names, so no bespoke contramap functions
are needed and generic contravariant code works with either. `divideRow`
stays a standalone combinator rather than bringing in a dependency for
`Divisible`.

**`RowEncoder` produces per-parameter encoders**
(`a -> [(Text, TdsContext -> Either String EncodedParam)]`): the value
first, the connection's context last. A query's parameter count and names
are then known without a connection, which `<>` needs
([Queries](#queries)); no encoder's count ever depended on the context.

* *Alternative rejected:* the context first, producing the encoded list.

**A derived record's encoder is one list of constructors.**
`genericToSqlRow` takes the record apart in one `case` and builds a
`FieldParam` per field, the field's encoder and its value, which one
out-of-line function in the library turns into the parameters. The tuples
and `Only` go through it too, and the `Maybe` field encoder is shared.
Strict numeric fields of a record of several fields use constructors with
the value unpacked and no encoder pointer, chosen at compile time from the
selector's metadata; lazy fields, tuples, `Only` and records of one field
keep the general constructor, so inspecting parameter names or rendering
the SQL doesn't force their values. A derived encoder is then about 62
bytes of the application's code per field, and a record of five strict
numeric fields allocates 2,296 bytes per row rather than 2,576. Query's
`<>` is out of line, so a query composed of `param`s and literals is a
chain of calls, 0.6 KB of code per function where it was 4.4 KB.

* *Alternatives rejected:* `divideRow`'s lazy split, which made each field
  a selector thunk walking the generic tree from its root, 491 bytes per
  field and a number of types quadratic in a record's fields; a strict
  match of the product, 375 bytes per field; outlining the named
  parameters of `NamedParams`, which saved 136 bytes of code per call and
  allocated 64% more; and a flattened generic representation of its own,
  which could have saved at most 12% of a nullable record's allocation
  for another layer of reconstruction
  ([performance-research.md](performance-research.md), "The code-size run,
  2026-11-04" and "The ideas run, 2026-11-04").

**Parameter values are explicit.** `EncodedParam` pairs a `TypeInfo` with a
`ParamValue`: `ParamBytes`, held in memory; `ParamLazy`, a lazy
`ByteString` forced as it is sent; or `ParamStream`, a `Source` read as it
is sent. The constructors are public, so that table-valued parameters and
other libraries can reach them. `RawParam`, `rawInParam` and `rawOutParam`
keep their `(TypeInfo, RawBytes)` interface, and `StreamParam`,
`binaryStream`, `textStream`, `streamAs` and `lazyAs` are the entry for a
stream or a lazy value, as PLP. Output parameters refuse lazy or effectful
values.

* *Alternative rejected:* `EncodedParam` as a tuple with strict bytes,
  which kept every parameter in memory.
* *Alternative rejected:* an abstract `ParamValue`, or one shaped as a
  single continuation, which `widenOutputParam` and bulk copy's converters
  couldn't inspect.
* *Alternative rejected:* `RawParam` and its kin taking a `ParamValue`,
  which changed about 128 call sites and gained nothing.

**A lazy value is inspected no further than its declaration needs.** A
lazy binary value is inspected for no more than 8000 bytes, and a lazy
`Text` for no more than 4000 UTF-16 units, before choosing a bounded or a
`(max)` declaration; at exactly that boundary the next chunk must be
inspected. A larger value stays lazy until it is sent. The lazy `Text`
check walks the chunks, measuring at most one unit more of each than is
left, so it forces exactly the chunks the declaration depends on. Lazy and
effectful values use PLP of unknown length, cut into chunks of at most
8000 bytes whatever the input's chunks are, and an empty input chunk is
dropped, because an empty PLP chunk is the terminator. A UTF-16 byte stream
must end on an even byte count. Strict values keep known-length framing.

* *Alternative rejected:* `toStrict`, which held the whole value.
* *Alternative rejected:* always declaring `(max)` for a lazy value, which
  changes the declared type of small values and so their cached plans.
* *Alternative rejected:* walking a lazy `Text` as a `String`, a
  `T.uncons` per character packed back into a `Text`.

**A `Source` scopes its resources around the whole send.** A `Source` is
`forall r. (Stream (Of a) IO () -> IO r) -> IO r`, so a `withBinaryFile`
lasts exactly as long as the send. Sources run masked, and an asynchronous
failure of the send breaks the connection. A synchronous failure of the
producer cancels an unfinished message and drains its acknowledgement
([Interruption and cancellation](#interruption-and-cancellation),
"Sends").

* *Alternatives rejected:* `IO (Stream ...)`, which can't scope a
  resource; and a bare `Stream`, which a second send would run from
  wherever the first left it.

**A source that makes a request on its own connection throws
`ReentrantSource`.** On a plain connection such a request would wait for
the send lock, which the source's own thread holds, and hang rather than
fail. On a MARS connection, reading a stream opened earlier stays allowed.

* *Alternative rejected:* a documented rule alone, since the misuse hangs.

**A request holding a lazy or effectful value can be sent once.** Request
creation that installs streamed parameters is in `IO`, and the request's
writer takes the pending requests out of a shared reference, atomically,
as it starts to write, so keeping that `Request` alive doesn't retain the
values it has sent, and a value is read once however many threads try. A
`Query` creates a fresh `Request` each time; a `Request` holding only
strict values stays reusable. The writer then traverses the requests and
their parameters as plain lists (`forM_`), with one separator written
between requests: once the requests have been taken, nothing refers to a
parameter after its turn. Retained statement metadata holds names and
types, not values, and a caller's own reference to a lazy head stays the
caller's responsibility. `Scale.ParameterResidency` checks what a request
retains.

* *Alternatives rejected:* pure construction, with `unsafePerformIO` for
  the identity of the reference; materializing a lazy value before the
  send; separate senders for streamed and strict parameters, which would
  traverse the parameters twice; and a private `IORef` per list that the
  writer popped parameters from, which protected nothing more than the
  list does, since the call holds only the rest of the list in either
  case.

**One wire type per Haskell type.** `Int` is `bigint`, `Text` `nvarchar`,
`LocalTime` and `UTCTime` `datetime2(7)`, `Int8` `smallint` (tinyint is
unsigned), `Word8` `tinyint`, `Integer` `bigint` or `decimal(38,0)` beyond
it (more than 38 digits is an `EncodeError`), `Decimal` `decimal(p,s)` with
`p = max digits s` (so scale-38 values such as 1e-38 are accepted, and more
than 38 digits is an `EncodeError`; hmssql never rounds an input), `Money`
`money` (out of range is an `EncodeError`, not a wrap modulo 2^64), and
`SqlXml` `xml`, with a UTF-16 byte order mark, which the server needs to
recognise a text-only document. `RawParam` is the escape hatch for any
other wire type. A typed parameter API (length, precision, scale) is on
the [backlog](backlog.md); see [limitations.md](limitations.md).

**Declarations don't depend on the value's length.** A `Text` is declared
`nvarchar(4000)` up to 4000 UTF-16 code units and `nvarchar(max)` beyond,
and a `ByteString` `varbinary(8000)` or `varbinary(max)`, as SqlClient
declares them. The `sp_executesql` declaration is part of what the server
caches a plan by, so declaring each value's own length (`nvarchar(1)` for
`"x"`, `nvarchar(2)` for `"xy"`) compiled a statement again for every new
length and filled the plan cache with copies: a statement the server
hadn't seen, run with strings of ten lengths, took 33.7 ms of wall time
that way and takes 21.4. The wider declaration truncates less, too:
`ISNULL(@p, col)` is typed by `@p`. A caller can see the declaration in
three places, which the `Hmssql.Types` Haddock and the guide's
[Encoders](../guide/decoders-and-encoders/encoders.md) page describe: the type of an expression such as `SELECT @p1` and its
truncation under `+`, a `sql_variant` target refusing the `(max)` form,
and one statement having two cached plans. The Haddock of an instance
states the rule and what the caller must know; the rationale and the
measurements stay here. `Decimal` keeps its value's own precision and
scale: `decimal(38,s)` would change the result type of arithmetic on the
parameter, since precision 38 triggers the scale reduction of `*` and `/`.

**Untyped NULLs are `nvarchar(max)`**, and `Nothing :: Maybe ByteString` is
`varbinary(max)`. The server won't convert either to `sql_variant` (error
206), so a NULL bound to a `sql_variant` column or parameter must be typed
(`Nothing :: Maybe Int32`, or `RawParam (TISqlVariant 8016, Nothing)`).

* *Alternative rejected:* `nvarchar(4000)` and `varbinary(8000)`, chosen by
  probing NULLs of twelve declared types against 35 column types; they
  reach everything the `(max)` types do, plus `sql_variant`. But an
  expression typed by the parameter, `ISNULL(@p, col)` with a longer
  `nvarchar(max)` column, was silently truncated to 4000 characters, and
  silent truncation is worse than an error.

**Procedure parameters encode at the call.** `inParam` and `outParam`
build a `ProcParam` whose `procParamEncode` takes the connection's
`TdsContext`. `callProcedure` runs all encoders under its lock, then
validates the RPC before sending it, and failures throw `EncodeError`, as
for query parameters. `rawInParam` and `rawOutParam` keep exact wire types
and values available without output widening, and pair with `inParam` and
`outParam` rather than taking a record update to say which direction a raw
parameter goes in.

* *Alternative rejected:* eager encoding with `defaultTdsContext`. Custom
  encoders need the negotiated context, and callers should not need a
  separate `sequence` or `either` step.

**Output parameters** (`outParam`) are declared in their widest form, since
the server converts the output to the declared type: `Decimal` as
`decimal(38,10)`, or the initial value's scale if larger; variable-length
and fixed-length string and binary types as `(max)`. `Float` stays `real`
(a `Float` decoder would reject `float(53)`), and `Integer` `bigint`. For
exact control use `rawOutParam "@x" (TIDecimalN 38 0, Nothing)`. A
hand-built type with a decimal precision outside 1..38, a scale above the
precision, or a time scale above 7 is refused with `EncodeError` by
`callProcedure` instead of being widened into a valid one or sent for the
server to reject. `procOutputValues` is in the caller's parameter order:
the server sends `(max)`-typed values last, so pairing by arrival order
gave wrong values.

* *Alternative rejected:* declaring a `Decimal` output by the initial
  value's own precision, which made `0` a `decimal(1,0)` that most results
  overflowed.

**`NamedParams` and `namedParam` names** must be `@` followed by one or
more BMP letters, combining marks, decimal digits, letter numbers, `@`,
`#`, `$` or `_`, and not `@p` followed by digits (reserved for the
positional parameters, see [Queries](#queries)); anything else is an
`EncodeError` before sending. The names are spliced into the
`sp_executesql` declaration, so an unchecked name such as `"x int, @y"`
changed what was declared (SQL Server 2025 itself refused an injected
statement, with error 4124, so the practical effect was confusing
errors). The rule was found by probing every BMP character; it refuses 45
characters the server accepts (format characters, connector punctuation,
a bare `@`). Duplicate names are refused case-insensitively by the query
functions. The low-level `executeSqlRequest` splices names unchecked, and
`paramNameProblem` is exported for its callers.

* *Alternative rejected:* the same rule for `callProcedure`'s names, which
  are sent as RPC data, not spliced, and are left to the server.

**What the wire can't carry is refused before anything is sent**, as an
`EncodeError`: a parameter name of 256 or more UTF-16 code units, a
procedure name of 65535 or more, a 65535-byte value of a USHORT-length type
(whose length is the NULL marker), an empty `RawParam` value of a
BYTE-length type (read as NULL), `ConnectInfo` strings totalling more than
about 64 KiB (LOGIN7's 16-bit offsets), and a SQL batch of more than 65535
packets (SQL Server closes the connection without a message; RPC messages
have no such limit). Names of 129 to 255 code units still go out, and the
server reports its own 128-character limit (error 8005). The low-level
`put` functions fail with `error` on the same inputs rather than wrapping;
the checks are duplicated there deliberately, since they are cheap and
guard direct users of `Hmssql.Tds.*`.

* *Alternative not taken:* a dedicated `RequestTooLarge` exception.

**`connectPacketSize` is clamped to 512..32767** before LOGIN7, as the
server itself raises smaller requests to 512. So 0 means 512, not "the
server's default", and a size of 8 or less can't make a request send
empty packets forever. The server may cap the request lower (32767 became
16384 on the test server), and hmssql adopts the ENVCHANGE value. The
default is 8000, as SqlClient's: each packet is a TLS record, a system call
and a hand-off from the reader thread, and SQL Server sends one packet per
record, so larger packets cost less per byte. Above 8060 bytes SQL Server
allocates packets from a different memory pool, so the default stays below
it. A MARS connection over TLS asks for at most 16368: SQL Server grants
up to 16384 there and then closes a MARS connection at its first
response, a packet and its 16-byte SMP header being too long for one TLS
record ([protocol-notes.md](protocol-notes.md#mars-and-smp)).

* *Alternative rejected:* 4096. Against a local server a 4 MB
  `varbinary(max)` read took 28.1 ms at 4096 and 20.9 at 8000, and sending
  one 22.9 and 16.5 ms.

### Bulk copy

**A bulk load is one message per batch.** It is a COLMETADATA written by
the client, then a ROW per row, then a DONE, sent after an `INSERT BULK`
statement; the server reads it and answers with a DONE that carries the
count. The metadata is written once per message. A row held in memory is
poked into the packet, and one with a stream or a PLP cell goes through
Builders interpreted by `PacketWriter`
([Reading and writing bytes](#reading-and-writing-bytes-which-layer)). A
bulk PLP cell uses an unknown total and chunks of at most 8000 bytes.

**The entry points match.** `bulkInsert` and `bulkInsertS` take a
connection and a table with default settings, and `bulkInsertWith` and
`bulkInsertSWith` take an explicit `BulkCopy` first, so switching to a
stream doesn't also mean switching the settings API. The name is
`bulkInsert`, not hpgsql's `copyFrom`, because a TDS bulk load is not a
`COPY` statement: it takes a table, not a query.

**`encodeBulkCell` says what it sends.** The low-level `encodeBulkCell`
validates against the destination column but returns bytes for
`bulkWireType (bulkColumnType column)`. Both the encoder and the type
mapping are public, so a custom writer can describe the bytes correctly
without a type and value pair allocated per cell.

* *Alternative rejected:* describing it as a generic conversion to the
  column's type, which hid the remapping of character columns to Unicode
  and of `xml` columns to binary.

**Character and `xml` columns are sent in a form the server converts.**
Character columns (`char`, `varchar`, `text`) and `ntext` are declared and
sent as `nvarchar(max)` (UTF-16) and converted by the server to the
column's own collation, since the load reads a single-byte value in its
statement's default collation, not the column's. An `xml` column is
declared and sent as `varbinary(max)`, so that the server's XML parser
reads the value's own byte order mark or encoding declaration, as it does
for an `xml` RPC parameter: a `Text` or `SqlXml` source gets a UTF-16 byte
order mark unless it carries one, a UTF-8 `varchar` source or one with a
mark or a declaration goes as it is, and any other single-byte source is
converted to UTF-16 first. SQL Server 2025 refuses a native `xml` column in
a load's COLMETADATA (error 4816), and through `nvarchar` the unmarked
UTF-8 bytes of a `RawParam` were read as UTF-16 and stored as unrelated
text.

* *Alternative rejected:* decoding the bytes on the client and sending
  characters. The client would have to guess the encoding, and a lone
  surrogate or an ill-formed sequence would be repaired before the
  server's XML validation saw it. The one conversion the client does make,
  an `xml` source into a character column, takes UTF-8 and a UTF-16 it can
  identify, and refuses any other declared encoding.

**The converter keeps what a source declares.** A `RawParam` of a fixed
type (`char(n)`, `nchar(n)`, `binary(n)`) is padded to its length before
conversion, as the server pads such an RPC parameter, so the same value
stores the same bytes on both paths. A UTF-16 source remapped to `ntext`
keeps its code units rather than being decoded and re-encoded, which would
replace the lone surrogates the server accepts. A source converted to
`sql_variant` keeps its declared base type, precision, scale, length and
collation (`variantFromSource`): `smallmoney` stays `smallmoney`,
`decimal(38,2)` stays `decimal(38,2)`, and a `datetime` keeps its 1/300 s
fraction. A source declared in the session's collation (`Collation 0 0`)
takes the collation of the session (`tdsCollation`), and an
`nvarchar(max)` or `ntext` source goes into a variant as a bounded
`nvarchar`, with its code units kept. A non-NULL source whose bytes are
empty fails the check an RPC parameter fails (`valueProblem`): for a
BYTE-length type or `sql_variant` a zero length is the wire's NULL, and the
server stored NULL, or the column's default without `KEEP_NULLS`, for a
value the caller gave. An empty character, binary or `xml` value is a
value, and goes.

* *Alternative rejected:* converting a variant's source through
  `SqlValue`, which widened each to its constructor's canonical type.

**A row of `NamedParams` goes to the columns of its names**, with the one
leading `@` that `NamedParams` adds removed, so `a` and `@a` name the
column `a` and `@@a` a column called `@a`. The lookup is exact first, then
case-insensitive when that matches one column and one value, so a
case-sensitive catalog's `a` and `A`, or `ß` and `ss`, each get their own
value; a name that matches two columns or two values is an `EncodeError`.

* *Alternative rejected:* folding every name before the lookup, which gave
  one value to both `a` and `A`.
* *Alternative rejected:* removing every leading `@`, which made `@a` and
  `a` the same name and left a column called `@a` unreachable; and a rule
  that removed one `@` only when some selected column started with `@`,
  which made a name's meaning depend on the other columns.

**A number converts as the server converts a parameter of its type.** A
`Float` or `Double` into `decimal`, `numeric`, `money` or `smallmoney` is
scaled as an exact rational and rounded half away from zero, which is what
the server does with the exact binary value (0.125 is 0.13, and 2.355,
whose nearest `Double` lies just below it, is 2.35 on both paths). An exact
source (`bigint`, `Decimal`, `Money`) into `real` is rounded once, straight
to 24 bits. `Money` into an integer type rounds half away from zero, as the
server does, where `decimal` and the floating types truncate. A NaN or an
infinity into `bit` is refused, as the server refuses the RPC parameter
(error 8023). Widening and narrowing between `Float` and `Double` use
`float2Double` and `double2Float`, which keep NaN, infinity and the sign of
zero in every build; `realToFrac` does so only through its rewrite rules,
that is, under optimisation.

* *Alternatives rejected:* multiplying in the floating type first, which
  lost low bits (922337203685477.5 became 922337203685477.4784 as `money`)
  or moved an out-of-range value into range; rounding the exact value half
  to even, which differed from the server at every representable tie; a
  `Double` in between for an exact source into `real`, which picked the
  wrong neighbour beside a `Float` midpoint; and "nonzero is 1" for a NaN
  into `bit`, which stored true.

**Streamed cells follow the server's `INSERT` conversions.** A bulk
stream's values are converted and truncated as an `INSERT` would under
the session's settings. The first row chooses whether a bounded character
or binary column is widened to `(max)` for that batch, and a later stream
that needs a widening is an `EncodeError` naming the row and column.
Character columns take UTF-16, so a `varchar(max)` byte stream is refused
there. `ANSI_WARNINGS ON` is recommended, and is on by default on a new
hmssql connection; no setting prevents discarded trailing blanks or zeros,
or replacement with `?` during code-page conversion. Strict in-memory
cells keep their client-side checks.

**A row's error text is built only on failure.** `rowProblem` is
NOINLINE, because inlined it left a lazy row-number string built before the
split between success and failure, 24 bytes per successful row.

**`ORDER` says each batch is sorted.** The client sends the rows as given
and never sorts them; a table with a clustered index refuses an
out-of-order batch (error 4819), with the usual rules for the batches
before it, and a heap ignores the hint.

**The message is produced and framed as it is sent**, a packet at a time
(`startStreamingRequest` in `Hmssql.Connection.Internal`), so a stream of
any length needs only a packet's memory. A producer that throws cancels
the load with an Attention: the connection stays usable for a small
partial load, but the server may reset it for a larger one, as any
interrupted send may leave the connection broken. A bulk copy on a MARS
connection runs on one session throughout
([MARS](#mars-several-responses-on-one-connection)).

## Date and time

The encoders (`putDate`, `putTime`, `putDateTime2`, `putDateTimeOffset`,
`putDateTime8`, `putDateTime4` and the `ToSqlField` instances on them)
mirror the server's own conversions, as probed on SQL Server 2025:

* **Round** to the nearest unit of the type, half up, exactly (no double
  rounding: `12:00:00.49999999` is 12:00:00 at scale 0).
* **Carry into the next day** for types with a date part
  (`23:59:59.9999999` at scale 0 is the next day's midnight, as the server
  converts it); **clamp** `time` to `23:59:59.(9...)` at its scale.
* **Clamp at the type's maximum** when rounding would go past it
  (`9999-12-31 23:59:59.9999999` to `datetime2(0)` is `9999-12-31
  23:59:59`), as the server does. A clear error was considered; the value
  itself is in range, and the server accepts and clamps the equivalent
  literal. Values whose day is out of range are an `EncodeError` naming the
  type and its range; the lower bound is checked after rounding
  (`1752-12-31 23:59:59.999` is a valid `datetime`: it rounds to 1753-01-01).
* **Leap seconds** (a `TimeOfDay` second of 60, a `UTCTime` day time of
  86400 s or more) count as the following second and carry, as PostgreSQL
  does (the server rejects `'23:59:60'`, so there is nothing to mirror).
  Clamping would keep the order of timestamps; carrying keeps elapsed time.
* **smalldatetime and datetime deviate at the top**: the server fails on
  2079-06-06 23:59:30 or later for `smalldatetime`, where the encoder
  clamps to 23:59 for consistency, and it refuses a `datetimeoffset`
  source at the last fractional tick of `datetime` (error 242, at offset
  zero too) where it clamps a `datetime2` source; bulk copy's shared
  clock clamps both. `smalldatetime` rounds to the nearest minute, as the
  server does. Only `RawParam` users reach
  `putDateTime4` and `putDateTime8`.
* **A `UTCTime` with a negative day time**, which `time` itself never
  produces, is split into whole days and a time of day with `Integer`
  arithmetic before the date check, so that a huge negative clock can't
  wrap through the `Int` in `utcToLocalTime` into a date in range. A
  positive clock past the day carries, as a leap second does, and one
  past that is refused as an invalid time of day.
* **datetimeoffset** rejects offsets beyond ±14:00 (checked before the
  offset is narrowed to `Int16`, so that a `ZonedTime` 65,596 minutes ahead
  of UTC can't be sent as +01:00) and values whose UTC or local time is outside
  0001-01-01 through 9999-12-31. `zonedTimeToDateTimeOffset` clamps an
  offset to the `Int16` range instead of wrapping, so an out-of-range offset
  stays out of range.
* Invalid `TimeOfDay` fields (hour 24, second 61, negatives) are rejected.
  Scales above 7 are a `Left` from the primitives. The decoders reject a
  time of 24:00:00 or more, a date past 9999-12-31, a `datetime` outside
  1753..9999 and a whole-day time part: the server never sends these, so
  they indicate a corrupt stream. The datetimeoffset decoder also checks
  the offset against ±840 minutes and the resulting local date against
  0001-01-01 through 9999-12-31. These are value errors (`DecodeError`),
  not framing errors: raw values remain accessible, following rows can be
  read, and a correctly framed response leaves the connection usable.

The `Types.TimeBoundary` tests compare every generated value with the
server's own `TRY_CONVERT` of the same value as a string literal.

## Decoding

### The decoder API

**The names follow hpgsql's.** The field-to-row combinator is
`singleField`, and its monadic variant `singleFieldM`. Generic derivation
uses `genericFromSqlRow` and `genericToSqlRow`, matching hpgsql's
`genericFromPgRow` and `genericToPgRow` while keeping hmssql's `Sql` class
names. The monadic decoder is `RowDecoderMonadic`, with
`toMonadicRowDecoder` lifting an applicative decoder. The same concepts
are then recognizable across the two libraries.

**Errors are eager and name the column.** A result set's decoder is
compiled against its column metadata once, so a type mismatch fails before
the first row. `Generic` records decode positionally, in declaration
order, ignoring column names, as tuples do.

**A monadic row decoder must consume exactly the result set's columns**, as
the applicative one must, and as in hpgsql. Prefix composition through
`toMonadicRowDecoder` stays valid inside a larger decoder. The check runs
per row, so a monadic decoder still can't check an empty result set; the
usual draining and `DecodeError` handling apply.

* *Alternative rejected:* silently discarding the leftover columns.
  Switching decoder styles should not hide an unexpected result shape.

**Strict types.** `Bool` accepts only `bit`; `Float` rejects `float(53)`
rather than lose precision; tinyint is unsigned (`Word8`, `SqlWord8
Word8`); `Integer` accepts `decimal` and `numeric` with scale 0, so that
its own large values read back, and the bounded integer types don't.
`refineField` layers a fallible conversion over an existing decoder,
reusing its type check and NULL handling.

**Type checks name SQL types, not wire encodings.** Each built-in decoder's
type check is a predicate over `SqlDataType`, applied through
`typeInfoDataType` (`Hmssql.SqlType`, defined in
`Hmssql.Internal.SqlDataType`), and `fieldDecoderForTypes` offers
the same to custom decoders. A `RowDecoderMonadic` recompiles every field
on every row, so the check is on the row path there: `typeInfoDataType`
and the predicate wrapper are inlined, and GHC folds the two matches into
one jump table over `TypeInfo`, with allocation unchanged to the byte
against predicates over `TypeInfo`. Building a `SqlType`, with its
arguments, does allocate, so decoders stay away from `typeInfoSqlType`.

### Compiling a row

**Rows are compiled before their first value.** Field types are selected
and column counts checked against COLMETADATA, and applicative composition
keeps the column order. A field compiler returns its selected conversion
directly, and each compiled part has a read recipe prepared with the
allocation bound once per result set. A caller with a materialized value
can use the same conversion through `compileField` and `decodeCell`.
Monadic row decoders keep their shape decided at runtime.

**A row's recipe is prepared once per result set, behind a constructor.**
`CompiledRow` holds `rowPrepare`, which gives the row's recipe for an
allocation bound inside a `Prepared`, and `rowRecipe` takes it out.
`RowPart`, a decoder's compiled part, returns a `Prepared` too, for parts
that aren't inlined into their row. A recipe is a function, so GHC
eta-expanded a preparation that returned one into a function of the row's
input as well, and the preparation ran again for every row, rebuilding
each column's recipe: 144 of about 450 bytes per row of a typed `(Int32,
Int64)` row in `Mock.query`, by ticky. A constructor can't be eta-expanded
past.

* *Alternative rejected:* `rowRecipe` as a field of type `Int -> Parser`,
  which is what let the preparation run per row.
  `-fno-do-lambda-eta-expansion` on the module would also stop it, for
  every function in the module.

**A failed cell reads past the rest of its row**, from the compiled column
shapes it captured, before it fails (`recover` in `singleField`).
Composition then stops, so no later consumer runs, and the row compiler
only converts the failure. A failed applicative part inside a monadic
decoder reports the whole row as read, and the monadic decoder checks the
count it consumed on success.

* *Alternative rejected:* carrying the next column in the failure, for the
  row compiler to skip from, which would put a column number in the
  parser's failure type.
* *Alternative rejected:* a second recipe tree per decoder, built only so
  that `liftA2` could skip the later columns after a failure.

**A failed value goes through the parser's failure channel, and an
unreadable response is thrown.** A cell that can't be decoded fails its
recipe with `failValue`, a `ReadFailure`, once its bytes have been read.
Binds and `<*>` pass the failure on without running their continuations,
so a recipe that succeeds builds no `Either` per cell, and `liftA2` over
row parts is the `Recipe`'s own. The row compiler catches it with
`attempt`, so a row recipe's result is `Either ReadFailure`, one `Right`
per row.

* `DecodeFailed` holds a `DecodeError`: this row failed and its bytes are
  accounted for. `RowBatch` carries the `DecodeError`, the response is
  drained and the error is thrown with the connection usable.
* `ReadDiscarded` is a value or row read by a drain, which nothing looks
  at.
* A throw ends the recipe, and `Parser` has no way to catch one and keep
  reading, so it means the position in the bytes is lost and the
  connection is broken. A failure must come after its value has been read
  to the end, or the next read starts inside it and fails with an unknown
  token. A failure that reaches a driver uncaught is a bug in the recipe,
  and a `ProtocolError`.
* `ValueReader`'s `String` is pure conversion only, and `readCellRecipe`
  makes it a `DecodeError` naming the column. `StreamingCell` still returns
  an `Either ReadFailure`, which `readCellRecipe` turns into the channel,
  so a hand-written one needs no part of it.
* No result type of a recipe, a row or a cell holds a `SomeException`: a
  returned error says why the value didn't decode, and an exception that
  could be anything ends the query instead ("Consumers are explicit
  effects", below). A conversion written by the application can still
  throw from pure code, so the driver keeps one failure handler per batch
  of rows, not one per row.

* *Alternative rejected:* an `Either` per cell, which `singleField` built,
  wrapped again with the next column, and each `liftA2` level matched and
  rebuilt. The channel costs a third branch in every bind's `case`, taken
  only on failure. Measured alone, it was a loss (Decode 1.046 in time and
  Mock 1.071), and with the changes that followed it the code is faster
  than before it (Decode 0.948 and Mock 0.962), so the channel stays for
  its simpler readers ([value-streaming-research.md](value-streaming-research.md)).
* *Alternative rejected:* a `Left` of `SomeException`, so that a consumer's
  exception could ride in the row's result to be rethrown after the drain.
  A caller handling a decode failure had to cast it, and the `try` that
  caught it sat beside the parse.

**Dynamic values select a reader once.** `SqlValue` keeps its scalar
conversion in a `SelectedReader` when the metadata is compiled
(`selectSqlValueReader`). A data constructor separates that selection
from the per-value calls.

* *Alternative rejected:* a continuation (`withSqlValueReader`) that took
  the reader as an argument to keep one type switch, with `INLINE` on it
  and on its callers, which copied all thirty branches into each use. The
  constructor cost the `SqlRow` benchmarks about 1.1 in time and
  allocation, and the cleaner shape was kept.

**A `SqlRow` is one loop over its columns.** `sqlRowDecoderFor` compiles
each column with `singleField` once, builds the columns' recipes whole
before the row's closure (the GHC 9.14.1 regression in
[bugs-found.md](bugs-found.md) is why), and reads a row with a recursive
recipe over them that builds the list, each step a `liftA2 (:)` of the
cell, through `P.dynamic`, and the rest of the loop.

* *Alternatives rejected:* `traverse` over `RowDecoder`'s applicative,
  which built a partial application of `(:)` and a level of recipe per
  cell; and a bind per cell, whose continuation, shared by the completed
  and suspended branches, was a 16-byte closure per cell.

**`traverse` is the combinator for a row known only at runtime.** A list's
`traverse` with `RowDecoder`'s `Applicative` instance reaches the `cons`
rule, so fifty `SqlValue`s allocated what `sqlRowDecoderFor`'s own loop
does (11.43 MB per 1,000 rows against 11.50 in `Bench.Decode`, 2026-11-05,
GHC 9.12.4); a vector's `traverse` goes through a list.

* *Alternative rejected:* a `traverseRow` that compiles each element once
  and runs the elements' recipes through the shape's own `traverse`. It
  allocated the same for a list and more for a `Data.Sequence` (9.1 MB
  against 7.6), whose `traverse` then ran once per row.

**A column's decoder can be chosen by the column.** `byColumn` calls its
function with the `ColumnInfo` when the result set's columns arrive and
compiles the one-column decoder it returns, so a program that builds its
queries at runtime reads each column through its type's own
`fieldRowDecoder`, or a long column through a fold (`columnIsLong`), at no
cost per row: fifty columns of five types as `SqlValue`s, each through the
decoder of its type, allocated 7.99 MB per 1,000 rows against 11.43 MB
through `sqlValueDecoder` (2026-11-05, GHC 9.12.4). It is OPAQUE, as
`singleField` is.

* *Alternative rejected:* `RowDecoderMonadic`, which makes the choice for
  every row and reads every column through `singleField`.

### What a decoder costs an application

The rules for code that reaches an application are under
[Memory and performance](#memory-and-performance); these are how the
decoders follow them.

**Decoders are compiled once, not into each use.** An application's
decoders are paid for at every field of every record, every row type in a
module and every call site. So `singleField` is out of line (OPAQUE), the
`FromSqlField` instances are not INLINE, the generic decoder is a chain of
calls to `singleField`, `productDecoder` and `recordDecoder`, the `Only` and
tuple instances call decoders compiled in the library, and the API's small
adapters (`query1With`, `execute_`, `executeMany`, `bulkInsert` and the
like) are out of line. A derived record's decoder is about 94 bytes of the
application's code per field, where the inlined design was 25 KB, and a
`query` of a tuple type 193 bytes per use.

* The generic decoder keeps a `Coercible` witness (`GDecoder`) and coerces
  values, because a `RowDecoder` can't be coerced across `M1` and `K1`: its
  result type is nominal through `Stream`.
* `RowDecoder`'s own `fmap`, `liftA2` and `<*>` call out-of-line functions,
  and rewrite rules turn a chain `f <$> a <*> b <*> ...` into one call of
  `lift3RowCalled` .. `lift12RowCalled`, each the chain inlined once in the
  library with a lambda of known arity, so a row calls `f` once with all
  its values; the tuples are those functions applied to their constructor.
  The rules don't fire without optimisation, where a chain takes a partial
  application per step. From seven to eleven columns a lift function is
  two smaller recipes, 96 KB less library code and 2.2% to 5.4% less
  allocation per row; twelve stays one recipe, because split it allocated
  more.
* OPAQUE rather than NOINLINE on functions returning a `RowDecoder` or a
  `FieldEncoder`, so that GHC doesn't make a worker returning an unboxed
  tuple whose every caller boxes it again.

* *Alternatives rejected:* the inlined design, which took 617 s to compile
  30 MB of decoders for 50 records; and a hand-written composition inlined
  at its use, 1.5 to 8.5 KB per call site, most of it from `refineField`
  and `nullableField`, which are OPAQUE now too.

**A built-in type's row decoder is one small copy in the library.** Through
the shared `singleField`, a cell's conversion is an unknown call, which
costs a boxed slice and a `Right` per cell. So each built-in `FromSqlField`
type has one row decoder compiled in `Hmssql.Decoding`, `rowDecoderWith`,
NOINLINE per instance and shared by the plain and the `Maybe` column
through a `Nulls` witness. It inlines the type's conversion at a single
site, for a value lying in the payload behind a fixed width or a one- or
two-byte length (`Parser.prefixedRowValue`), and sends every other cell
(cut by a packet, PLP, NULL or failed) through the type's out-of-line
`fieldDecoder`; the large conversions (the dates, `Decimal`, `Money`) stay
calls, taking the slice unboxed. The class exports `fieldRowDecoder`, a
constructor around a call, so that a field refers to it directly. Each
built-in type's decoder is a top-level INLINE definition (`int32Decoder`
and the others): the instance's `fieldDecoder` is that definition,
compiled once as the method, and its `rowDecoderWith` gives the same
definition to `cellRowDecoder`, where it inlines. The tuples, `Only` and
the generic leaf use `fieldRowDecoder`, and a user's type gets
`singleField fieldDecoder` by default. It costs the library about 200 KB,
3 to 5 KB per type, and saves about 27 bytes per field in an application
and a third of a typed row's allocation (typed `int bigint` 2.84 to 1.89
MB per query); the owner chose speed over that size.

* *Alternative rejected:* INLINE on `fieldDecoder` itself, which would copy
  a decoder into every hand-written `singleField fieldDecoder`.
* *Alternative rejected:* a hidden class method holding the INLINE
  decoder, with `fieldDecoder` defaulting to it, which put the hidden name
  in the class's minimal complete definition for Haddock to show.
* *Alternatives rejected:* a copy per type of the whole cell read, every
  delimiter and both paths, which cost 1 MB of library; and a pragma on
  the class's default methods, which GHC copies as a stable unfolding into
  every field that selects them.

**An application's own decoder can have the built-in row path.**
`inlinedField` and `inlinedNullableField` are `cellRowDecoder` given an
application's `FieldDecoder` as both the inlined and the shared decoder, so
that a conversion of the application's, such as one written with
`fieldDecoderFor`, is a known call on the value's place in the buffer
rather than an unknown call on a `ByteString` built for it: two integers
through `fieldDecoderFor` allocated 4.9 MB per 10,000 rows by
`singleField` and 4.0 MB by `inlinedField`, against 3.5 MB for the
built-in decoder (`Bench.Decode`, 2026-11-05, GHC 9.12.4). It loses no
check. The column's type is checked by the decoder's own compile function
once per result set, before any row, and the function runs a second time
for the shared path's copy, which is harmless because a `FieldDecoder`'s
compile function is pure. The fast path's NULL rule and lengths are
`cellHead`'s, as `Parser.valueSpan` applies them, and it sends a length
prefix past the payload, a fixed width that doesn't fit, PLP and a column
with no delimiter in the row to the shared path, so the conversion is
given the same slice either way and its own length checks still run.

* **Its cost is code**: about 3,530 bytes of object code per binding by
  `inlinedField`, 2,940 by `inlinedNullableField` and 650 by `singleField`
  of `nullableField` (GHC 9.12.4, `-O`). So the Haddock says to bind the
  result once at the top level with NOINLINE: the result is a constructor
  application, whose unfolding GHC looks through at any size, so a
  binding without the pragma can be copied into its uses, which is the
  blowup that `singleField`'s OPAQUE prevents.
* **Inlining doesn't pay for a large conversion.** A `datetime2` and a
  `datetimeoffset` into a strict record of their parts allocated 5.1 MB
  per 10,000 rows by `singleField` and 5.6 MB by `inlinedField`, so the
  Haddock says `inlinedField` is for small conversions, and the built-in
  date decoders keep their conversions out of line.
* *Alternative rejected:* `inlinedField . nullableField` as the nullable
  form, which gains nothing, because `nullableField` is OPAQUE and the
  copy then calls the conversion unknown and boxes the `Just`.
  `inlinedNullableField` passes the `Nulls` witness as the built-in types'
  `Maybe` row decoder does (two nullable integers, half the rows NULL:
  5.0 MB by `singleField . nullableField`, 5.2 MB by `inlinedField .
  nullableField` and 4.1 MB by `inlinedNullableField`).
* *Alternative rejected:* a nullable counterpart of `singleField`. Its
  conversion is a call either way, so `singleField . nullableField` is its
  nullable form.

**A cell of known length goes straight to its conversion.**
`Parser.convertBytes` gives a value lying in the buffer to the borrowed
conversion as a slice, without the intermediate `Maybe`, `ValueBytes` and
`WholeValue` constructors, which reached the conversion whenever its
continuation was shared with the suspended branch. NULL, PLP and values
cut by a packet keep the general path. A cell's failure handler, which
reads past the rest of the row, asks for the row's bitmap itself, so that
it is built once per column rather than as a closure and a thunk per cell.

* *Alternative rejected:* choosing a column's delimiter read once per
  column, when the row is compiled. It saved 10% of the nullable dataset's
  allocation, but gave each shape its own copy of the cell's read in every
  row type, and doubled the object code of a module of row types (0.86 to
  2.03 MB).

**A date, time or decimal value can be decoded from its parts.**
`dayTimeFieldDecoder`, `dateTimeOffsetFieldDecoder` and `timeFieldDecoder`
give an application's function the day, the picoseconds since midnight and
the offset in minutes that the readers' `…With` forms
(`readDateTime2With`, `readDateTimeOffsetWith`, `readTimeWith` and the
others) pass, with the built-in decoders' type checks and range checks.
They are for a consumer that writes values straight out, such as a JSON
encoder, for which the `time` package's types are an intermediate built
from `Integer`s. Each is `compiledFieldDecoder` with the built-in
decoder's accept predicate and the INLINE reader, so the conversion
inlines into the reader. `decimalFieldDecoder` is the same for the types
`Decimal` accepts: the sign, the magnitude's high and low 64 bits and the
scale, which `readDecimalWith` passes, with the same checks and messages,
`money` at scale 4 and an integer type at scale 0 (`Types.DecimalPartsSpec`
holds it to `Decimal` at every magnitude length). A zero is never
negative, though the wire can carry one.

* *Alternative rejected:* the readers out of line, NOINLINE and given the
  function. The function is then an unknown call whose result is boxed,
  and a `datetime2` and a `datetimeoffset` into a strict record of their
  parts allocated 5.9 MB per 10,000 rows rather than 5.1.
* *Alternative rejected:* exporting the readers alone from
  `Hmssql.Tds.Primitives`, which would leave each application to repeat
  the type check and the dispatch over the date types that `dayTimeValue`
  does.
* *Alternative rejected:* the decimal's magnitude as an `Integer`, which is
  what `Decimal` already holds; the two words keep a value below 2^64 out
  of `Integer` arithmetic altogether.

### Values and their bytes

**Values don't retain their input packet.** The parser tells borrowed
slices from owned, assembled values (`ValueBytes` is `Borrowed` or
`Owned`). `ByteString` and `RawValue` conversions copy a borrowed slice and
keep an owned value as it is; scalar and text results are evaluated before
they are returned; and streamed chunks are copies, so retaining one doesn't
retain a packet. A custom `fieldDecoderFor` must copy any bytes it keeps
([Who owns a packet's bytes](#who-owns-a-packets-bytes)). A compiled field
has a lazy NULL result and separate borrowed and owned conversions, so
ownership wrappers don't escape into every scalar callback. Compiling the
metadata doesn't evaluate a NULL conversion; it runs only for a NULL.

* *Alternative rejected:* a `Discarded` constructor in `ValueBytes`, for a
  value a drain read past, whose projections then returned an empty string
  and whose callers had to remember to check first. A discarded value is
  not a value: `wholeValueBytes` returns a `WholeValue` that is
  `NullValue`, `PresentValue` or `DiscardedValue`, and a decoder never sees
  the third.

**One recipe per wire envelope.** `cellHead` describes NULL, a sized value
or a PLP value, and the caller collects the bytes, streams the chunks or
skips. PLP traversal is shared, with one definition of a chunk's header,
and skipping a value folds over its lengths directly, without building a
stream. Materializing a PLP value keeps its first payload fragment
borrowed and allocates an accumulator only when a second fragment arrives;
returning bytes to the application still makes the owned copy it needs,
and scalar conversions read the borrowed fragment directly. NBCROW's bitmap
is a whole value passed to the column fold, including when the bitmap
itself crosses a packet boundary. Raw `TRow` values are arrays of raw
cells, built only for callers that ask for them.

* *Alternative rejected:* a per-type inline path for a PLP value in one
  chunk, which would have saved at most 16 bytes of the 900 per row of a
  short `nvarchar(max)` read, for more framing code.

**A drain skips cells with a one-shot loop.** `skipCells` is a recursive
loop whose arguments are `oneShot`, so a drain builds no recipe per cell:
31.4% less allocation draining 10,000 `(int, bigint)` rows, and about half
the time for wide rows. A row of 50 fixed-width cells and nothing else
allocates 14.7% more to skip.

* *Alternative rejected:* a `mapM_` over the cells wrapped whole in
  `oneShotRecipe`, three times the allocation.

**Skipping rows and draining are different operations.** A procedure
caller may ignore rows while still collecting output parameters, and only
an actual drain discards RETURNVALUE payloads. When a drain takes over a
suspended assembly, the next feed releases its partial buffer and skips
the remainder. Output parameters stay materialized; streaming them is
deferred.

### Long values and consumers

**Any value can stream, in either direction.** Any column of a row, and any
parameter of a request, can be read or sent as a stream, so several large
values can sit among small ones. A value not read when its turn ends is
skipped, with nothing kept.

* *Alternative rejected:* streaming the last column only, which no other
  client requires: SqlClient's `SequentialAccess` asks only that columns
  are read in order, and ODBC's `SQLGetData` asks for ascending column
  order unless the driver reports `SQL_GD_ANY_ORDER`.
* *Alternative rejected:* random access to a row's values. TDS is
  sequential, and it would mean buffering the row.

**A streaming field is a `FieldDecoder`.** `streamField` and
`streamTextField` are field decoders, so a stream works with `query`,
`queryS`, `queryFold`, `queryResultSets`, `BatchQuery` and derived records
with no new variants, the column types are still checked before the first
row, and `Maybe` still handles NULL.

* *Alternative rejected:* a query function per shape (a `queryFoldValue`
  and its kin).

**Three kinds of field decoder.** A `CellDecoder` reads a whole value and
converts it with pure functions. A `StreamingCell` gives the value to a
recipe as a `StreamedValue`, NULL or its bytes as a stream with the
declared total, and the recipe may run a consumer. A `FoldingCell` is a
`CellDecoder` with a pure fold for a value past `streamWholeLimit`
(below).

* *Alternative rejected:* `StreamingCell` alone, with `CellDecoder` as a
  function that builds one. A consumer needs what an ordinary value
  doesn't: two references, a step of `RunConsumer`, a `bracket_`, a handler
  that abandons the response and a masked pull per chunk, and it leaves
  `runParser`'s path with no `Stream`. The stream's chunks would have to be
  joined too, which loses the borrowed slice. 100,000 rows of five `int`
  columns, from the local SQL Server 2025 at `-O1`, took 24.7 ms and 911
  bytes per row with `fieldDecoder`, and 275.8 ms and 32,021 bytes per row
  with `streamField` over each column. A pure conversion also works
  without a connection (`decodeCell`).
* *Alternative rejected:* giving a streaming decoder the `Cell` to parse,
  which made the generic cells frame their chunks as PLP so that a parser
  could read them back.

**Consumers are explicit effects.** `streamField` accepts any non-NULL
column, and `nullableField` supplies NULL handling. `streamTextField`
checks the column's encoding before rows arrive; UTF-16 holds at most three
bytes across chunks, and UTF-8 uses the incremental text decoder. Consumers
run on the reading thread in the caller's masking state, and unread bytes
are skipped when the consumer returns. A stream used after its consumer,
or replayed from an old pull, throws `ResultAbandoned`. A consumer can't
use its plain connection or read its own response recursively; MARS
permits work on other responses.

**An exception from a consumer ends the query at once**, synchronous or
not, as an exception from the caller's own code between rows does. The
consumer's statement is cancelled and its handle abandoned
(`abandonAtOnce`), so a `queryS` stream read on throws `ResultAbandoned`
rather than running the consumer again, and the value stream it was given
is closed at once. `readingToEnd` or the next request drains the rest, and
the drain resumes the step saved before the consumer ran, which gives
`RunConsumer` `Nothing` and reads past the value. The connection stays
usable, because a consumer only pulls through the driver and can't move
the position in the bytes. `stepCore` doesn't run the consumer itself: its
reading returns `StepConsumer`, and the step's driver runs the consumer
outside `breakOnFailure`, so the consumer's exception neither breaks the
connection nor needs catching. A consumer that means to reject a value
returns a `Left` through `refineField`, which is a `DecodeError`.

* *Alternative rejected:* catching the exception, reading the rest of the
  row and the response, and rethrowing it from the query. It needed the
  exception in the row's result, it read a large response to its end for
  a query that had already failed, and an interrupted consumer waited for
  the rest of its row to arrive, which against a stalled server it never
  did.

**A value of at most 64 KiB reaches its consumer whole**
(`streamWholeLimit`). `readCellRecipe` reads such a value as a
`CellDecoder`'s is read and gives a `StreamingCell` `StreamedWhole`, its
bytes borrowed or owned; `streamField` gives the consumer a stream of that
one chunk through `consumeWhole`, which needs no reference to the
suspended value, no masked pull and no drain. A larger value is streamed. A
PLP value whose total isn't sent (`xml`, `json`) is read a chunk at a time
until it ends within the limit, and once a chunk would take it past, its
stream starts with the chunks already read (`Tds.Value.boundedValue`), so
no more than the limit is ever held. The limit is fixed rather than a
setting: a consumer gets a value of either size by the same function, and
only the cost differs. 10,000 rows of a short `nvarchar(max)` into
`streamTextField`, every chunk kept, allocated 94.0 MB in `Mock.query`
when each was streamed and 55.7 MB read whole, against 7.8 MB for
`fieldDecoder @Text` (2026-11-05, GHC 9.12.4); what remains is mostly the
suspension of the row for the consumer's `IO` and the consumer's own
stream.

* *Alternatives rejected:* streaming every value, at the cost above; a
  limit the application chooses, which buys a few per cent at the price of
  a choice every decoder would have to make; and a stream of the value's
  pieces as the packets cut them for a value whose total isn't sent, which
  would start its consumer sooner but give a short `xml` value the
  streaming cost.

**A `FoldingCell` converts a short value as a `CellDecoder` does and folds a
long one.** It is a `CellDecoder`'s three fields and a pure recipe over the
pieces of a value past `streamWholeLimit`, for a conversion that can work a
piece at a time, such as writing a long text or binary value out as JSON.
`readCellRecipe` reads a value that is NULL or of a known length within
the limit through the same join point as a `CellDecoder`'s, and gives any
other to `foldingCellRecipe`, out of line, where `boundedValue` reads it
whole or gives the fold its pieces. The streaming and folding reads are
out of line, once, rather than in each of `readCellRecipe`'s three copies,
with `boundedValue` and `nullsCell` (which runs once per result set)
NOINLINE: inlined, they made the library 3.7% larger.

* *Alternative rejected:* the same fold as a `StreamingCell`, given a short
  value as `StreamedWhole`, which cost 2.0 MB more per 10,000
  50-character `nvarchar(max)` values folded into text (15 MB against
  13 MB for `fieldDecoder @Text`), for the value's result through
  the `StreamedValue`, the recipe's `Either` and `nullableField`'s `fmap`.
* *Alternative rejected:* a folding cell's short value read out of line
  too, 96 bytes a value more.
* *Alternative rejected:* `cellRowDecoder` taking a folding cell's whole
  conversions through a `Maybe` of a pair, which changed nothing for a
  long column, whose values are never read inline.

**The built-in text decoders read a long value whole.**

* *Alternative rejected:* `Text` and lazy `Text` as `FoldingCell`s for a
  long column, decoding a value past `streamWholeLimit` with
  `decodeTextChunks` as it arrives, so that its UTF-16 is never held whole
  beside the text. The chunk decoders give the same text however a value
  is cut, ill-formed UTF-16 and UTF-8 included (`Wire.StreamWhole` holds
  them to the whole values' decoders at every cut), and a 4 MB
  `nvarchar(max)` into `Text` allocated 0.874 as much, but it took 1.31
  times as long in `Bench.Decode` and 1.11 to 1.18 times on the mock
  connection: a thousand chunks decoded through a `Stream` and joined cost
  more than one decode of the assembled bytes (2026-11-05).

**A consumer that pulls starts its own batch; one given its value whole
runs among the rows.** `RunConsumer` says whether its consumer pulls from
the response (`consume`) or has its value in hand (`consumeWhole`). Before
a consumer that pulls, the driver returns the complete rows it holds and
runs the consumer at the next step, as it does before a receive, so
complete rows never wait behind the server. A consumer of a value in hand
runs where it is, so a column of short streamed values is read in batches
like any other, and holds back only the rows read ahead of it in the same
payloads, for as long as its own code takes.

* *Alternative rejected:* ending the batch before every consumer, so that
  user code that blocks never holds complete rows back. It cost 1.1 to 1.7
  KB more a row of a short streamed value in `Mock.query` (2026-11-05).
* *Alternative rejected:* the rule decided once per result set, which
  needed a flag in every `RowPart`.

**Batches end at suspension.** Complete rows are returned before waiting
for another packet. The response saves the normalized continuation after
the effects already performed, so feeding it can't replay them. A typed
result slot is used only when a row crosses a batch boundary, and is
cleared on delivery. Ordinary row progress flows through arguments, and
the response's reference is committed at a batch or suspension boundary.

**Generic cells have nested continuations.** `queryCells` returns metadata
and rows whose cells contain their byte streams. Finishing or skipping a
cell reveals the next cells, and finishing a row reveals the next rows.
Each pull holds the lock only for that pull and records a recipe for
draining the rest of the row, and `withQueryCells` gives `queryS`-style
scoping. `cellDecoded`, `cellText` and `skipCell` use the same conversions
and recipes. Each cell carries the connection's negotiated context and
allocation bound, and conversions use those rather than the defaults.
Streaming conversions consume payload chunks directly, without
reconstructing a wire envelope: an ordinary decoder's chunks are gathered
and converted, and a streaming decoder is given them as a stream.

* *Alternative rejected:* a `ResponseStep` constructor per chunk, which
  breaks exhaustive matches and leaves the column order to the caller.
  With nested streams the order can't be got wrong.

### Data types

**Character data.** `char`, `varchar` and `text` are decoded by the
collation's code page (the UTF-8 flag, then the sort ID for SQL
collations, then the LCID), with tables for the single-byte code pages
437, 850, 874 and 1250 to 1258 generated from the server's own
conversions. A column in a double-byte (932, 936, 949, 950) or unknown code
page is a `DecodeError` when its metadata arrives, even if every value is
NULL or ASCII: failing up front is predictable, where failing per value
would pass in testing and fail on production data. Read such a column as
`ByteString` or cast it to `nvarchar`. A `sql_variant`'s collation is known
only per value, so it fails per value. Ill-formed UTF-16 (lone surrogates,
which the server stores without complaint) decodes to one U+FFFD per
ill-formed code unit, everywhere: values, column names, messages,
ENVCHANGE strings. Ill-formed UTF-8 in a `_UTF8` column decodes with
text's `decodeUtf8Lenient`, one U+FFFD per byte.

* *Alternative rejected:* a hand-written UTF-8 decoder that reproduced the
  server's exact replacement count, an unneeded requirement.
* *Alternative rejected:* text's own `decodeUtf16LE` in place of
  `Hmssql.Tds.Utf16`'s, which allocated 229 KB for 4,000 units of ASCII
  where hmssql's allocates 4 KB.

**Decimals from the server** are checked: a sign byte other than 0 or 1, a
magnitude of 10^precision or more, or a length other than 5, 9, 13 or 17
bytes is a `DecodeError`. The length is not required to match the
precision, because SQL Server sends both shorter and longer values than the
precision needs (a 4-byte magnitude for a `decimal(10,0)` zero, a 16-byte
one for a `decimal(1,0)` inside a `sql_variant`). The powers of ten come
from a table; computing them per value cost 35% on a million-row read.

**CLR UDT columns** (`hierarchyid`, `geometry`, `geography`) don't break the
connection: their UDT_INFO is parsed and the values (always PLP) read
past. Every decoder but `RawValue` rejects them up front with a
`DecodeError` suggesting `CAST(col AS varbinary(max))` or
`col.ToString()`, and `RawValue` gets the serialized bytes. `ByteString`
deliberately doesn't accept them, so reading UDTs stays opt-in. A UDT
parameter is an `EncodeError`.

**`FOR BROWSE` hidden columns are returned.** SQL Server marks the key and
timestamp columns hidden only in the COLINFO token, which hmssql skips, so
a one-column `FOR BROWSE` query has three columns, as ADO.NET's
`FieldCount` does.

**`query` returns `[]`** both for a batch with no result set and for one
empty result set; `queryMulti` tells them apart. Pulling from a fully
drained `queryS` stream again throws `ResultAbandoned`. Re-running a partly
consumed stream value (rather than the continuation from `S.splitAt`)
yields nothing; this is a misuse of `streaming` and is not detected.

## What the wire layer checks

**The library's own byte access is checked; the unchecked forms are
public in a module of their own.** `Hmssql.Tds.Bytes` exposes checked
`ByteString` reads and span operations, and `Hmssql.Tds.Bytes.Unsafe` the
raw pointer loads and stores, following the public unsafe-module boundary
of [bytestring](https://hackage-content.haskell.org/package/bytestring-0.12.2.0/docs/Data-ByteString-Unsafe.html).
The raw operations still handle alignment and endianness; the caller owns
the capacity, initialization, lifetime and aliasing. Checked reads use the
same primitives after verifying the span and keeping the buffer alive. No
raw capability is hidden from custom codecs.

**`unsafeWriteUtf16LE` writes UTF-16 into the caller's buffer.** It needs
valid, writable, non-overlapping storage for twice `utf16Length` bytes;
twice the input's UTF-8 byte count is a sufficient bound, not a required
minimum. The allocating `encodeUtf16LE` and `utf16LEBuilder` handle
storage for ordinary callers. This follows text's distinction for
[`unsafeCopyToPtr`](https://hackage-content.haskell.org/package/text-2.1/docs/Data-Text-Foreign.html#v:unsafeCopyToPtr).

**A producer of a message gets a `PacketWriter`.** `sendPackets` and
`startStreamingRequest` pass one to the producer, which supplies Builders;
the packet type it is given decides the headers the writer writes, and
the packet's storage and pointers stay private to the writer
([Who owns a packet's bytes](#who-owns-a-packets-bytes)). There is no
caller-supplied mutable `ByteString` and no framing function that reserves
a prefix.

**The public `putValue` checks the framing** (`valueProblem`): an invalid
length, and a non-NULL empty payload whose zero length means NULL, are
refused, so that `Nothing` and `Just bytes` stay distinct. It doesn't
validate type declarations or the values' meaning. `putValueUnchecked` and
`writeValue` stay unchecked, for callers that validated their values
already ([Reading and writing bytes](#reading-and-writing-bytes-which-layer)).

* *Alternative rejected:* checking only the prefix's numeric range, which
  let an empty value be read as NULL.

From the server, hmssql refuses with `ProtocolError` (and breaks the
connection): a response message that ends without a final DONE, DONEPROC or
DONEINPROC lacking DONE_MORE (after an Attention, the acknowledgement ends
the response instead; SQL Server always ends a response with a final DONE,
and hmssql doesn't do the SSPI or federated-auth exchanges whose messages
don't); a packet-size ENVCHANGE outside 512..32767; a decimal precision
outside 1..38 or a scale above it in COLMETADATA or RETURNVALUE; an ORDER
token of odd length; a PRELOGIN option whose offset points inside the option
table; a PRELOGIN response longer than 131070 bytes (the most its 16-bit
offsets and lengths can describe); a token other than a row or a
RETURNVALUE still unfinished after 16 MiB (below); an unsupported TDS
version in LOGINACK (printed in hex). Inside a `sql_variant`, a time scale above 7, a property
byte count that doesn't match the base type or an invalid decimal precision
is a `DecodeError` for the value.

It is lenient about: packets longer than the negotiated size; server packets
with the IGNORE bit; a spurious DONE_ATTN inside a cancelled response (taken
as the acknowledgement, as Microsoft's SqlClient does). A DONE (DONE,
DONEPROC or DONEINPROC) flagged DONE_ERROR or DONE_SRVERROR in a response
that carried no ERROR token fails the request with `SevereError`, once the
response has been read: the server failed the request without a message,
which is what a killed session gets (Azure SQL Database answers the running
request with one such DONE, then resets the connection), and not a
successful request with no rows. A DONE_SRVERROR also marks the
connection broken at once, since the server closes it afterwards
([Exceptions](#exceptions)); DONE_ERROR alone leaves the connection as it
was.

Length prefixes do not cause unbounded allocation ahead of received bytes.
A spanning value allocates at most `connectValueAllocAhead` (1 MiB by default)
before more data arrives, then grows by quarters of its declared length.
Known totals need at most 1.25 times the final value during the last growth;
unknown totals use bounded buffers and a final join. No packet list is retained.
A drain skips envelopes and payloads without assembling them.

Metadata tokens are limited to 16 MiB of received bytes, including during
login. This bounds an endless FEATUREEXTACK list and DWORD-sized SESSIONSTATE,
FEDAUTHINFO or Promote Transaction values. Metadata repetition is tail-recursive,
so each new packet does not revisit a growing chain of pending constructors.
Rows and RETURNVALUE values are exempt from the metadata limit. A message
ending inside either remains a ProtocolError, even after an Attention.

* *Alternative rejected:* a bound per token type, such as 64 KiB for
  FEATUREEXTACK. A table of bounds for tokens a connection meets once at
  login buys nothing that one bound above COLMETADATA's doesn't.
* *Alternative rejected:* a bound on the whole login response, such as
  1 MiB. A response of many small tokens grows
  nothing, because only the first error is kept, so bounding each token
  bounds the memory without a second rule for the login.

## Encryption and TLS

**The default is `EncryptOn`** (TDS 7.4), in the library and in the
examples' shared settings. The examples accept `MSSQL_ENCRYPT=strict` for
TDS 8.0, and their localhost recipes set `MSSQL_TRUST_SERVER_CERT=1`
explicitly; certificate validation stays on by default. Azure SQL supports
both modes (the access-token tests and the Proxy and Redirect benchmarks in
[azure-sql.md](azure-sql.md) succeeded with `EncryptOn` and
`EncryptStrict`), so TDS 8.0 is not required to connect to it.

* *Alternative rejected:* strict encryption as the examples' default,
  which stops the localhost recipes from working with servers that don't
  accept TDS 8.0.

| `connectEncryption` | Wire behaviour |
|---|---|
| `EncryptStrict` | TDS 8.0: TLS 1.2 or 1.3 on the raw socket with ALPN `tds/8.0`, then TDS inside TLS. LOGIN7 announces version `0x08000000`. No PRELOGIN is sent inside the TLS session unless its answer is needed, for an access token or MARS; SQL Server 2025 and Azure SQL Database accept LOGIN7 right after the handshake, and SqlClient always sends one ([protocol-notes.md](protocol-notes.md#strict-encryption-tds-80)). |
| `EncryptOn`, `EncryptReq` | PRELOGIN in clear, TLS 1.2 handshake records wrapped in TDS packets (each handshake flight must be exactly one TDS message), then TDS inside TLS. |
| `EncryptOff` | Only the LOGIN7 packet is encrypted; everything, if the server requires it; nothing, not even the password, if the server answers ENCRYPT_NOT_SUP. |
| `EncryptNotSup` | No encryption; refused if the server requires it. Against a server answering ENCRYPT_OFF, hmssql logs in unencrypted (not in the spec's table, but neither side wants encryption). |

**The negotiation follows the MS-TDS table.** The combinations it says to
terminate, and invalid answers, throw `ProtocolError` before anything else
is sent; a dedicated exception type was considered and not added. The
PRELOGIN exchange is unauthenticated, so in the TDS 7.x modes an active
attacker can rewrite the server's answer: `EncryptOn` and `EncryptReq` then
fail, but `EncryptOff` sends the login in clear. Whether `EncryptOff` should
refuse ENCRYPT_NOT_SUP is an open question (it would break servers with
encryption disabled), and it is documented instead.

**A strict connection checks that it reached a TDS 8.0 endpoint.** The first
byte from the server must begin a TLS handshake record or alert, or
`connect` throws `ProtocolError` suggesting `EncryptOn`, where a TDS reply
would make tls wait forever for the rest of a record. A strict handshake that
completes without the server selecting `tds/8.0` through ALPN throws
`ProtocolError` too, before anything is sent inside the session: tls
refuses a server that selects a protocol the client didn't offer, but
accepts one that answers with no ALPN extension at all, as RFC 7301 lets
a server without ALPN do, and such a peer is not a TDS 8.0 endpoint. With
certificate validation on it holds a certificate for the host, so it is
the right machine and the wrong service on the port, such as an HTTPS
listener or a TLS-terminating proxy; the login, password included, then
went to a service that never agreed to TDS, and an HTTP server waiting
for the end of a request header made `connect` hang. The check costs
nothing against SQL Server, which always selects the protocol
([protocol-notes.md](protocol-notes.md#strict-encryption-tds-80)).

* *Alternatives rejected:* accepting a missing selection, which leaves the
  wrong endpoint to a hang; falling back to TDS 7.4, a silent downgrade of
  what the caller asked for; and an option to turn the check off, which
  nothing is known to need (a TLS proxy that strips ALPN in front of SQL
  Server would be the reason to add one).

**Certificates** are validated by default in every mode that uses TLS,
against the system store plus `tlsCaCertificateFiles` and
`tlsExtraCertificates`; the name checked is `tlsHostNameInCertificate` or
else `connectHost` (an IP address must be among the certificate's IP
addresses). A leaf certificate whose extended key usage extension excludes
server authentication is refused (one without the extension is accepted; SQL
Server's own certificates include it). `tlsTrustServerCertificate` turns
validation off, name check included, except that tls (2.4.4 and later,
which hmssql requires) enforces the extended key usage check itself. The system store is loaded
once per process by the first connection that needs it, and shared;
certificates added later are seen only by a new process. On macOS loading
it runs the `security` tool, which cost 16 ms and 38 MB of allocation per
connection when it was loaded for each. The files of
`tlsCaCertificateFiles` are parsed on every connect (about 70 us and 320 KB
for a one-certificate PEM file).

* *Alternative rejected:* caching the parsed files by path and
  modification time. A file replaced with its modification time preserved
  would have kept the old certificates in use.
* *Alternative rejected:* searching for trusted certificates in
  `SSL_CERT_FILE`, `SSL_CERT_DIR` and Homebrew's paths with the validation
  cache disabled, and then a bundled certificate. The caller supplies CA
  settings instead (`tlsCaCertificateFiles`, `tlsExtraCertificates`), and
  the macOS system store accepted the test server's self-signed
  certificate after all.

**TLS parameters:** the tls package's strong cipher suites; no SHA-1
signature schemes (RFC 9155; tls offers them by default); the extended master
secret required with TLS 1.2; SNI carries `connectHost`, or nothing when it
is an IP address (RFC 6066; `tlsHostNameInCertificate` is a validation
setting, not sent as SNI, which an SNI-routing proxy might want); a TLS 1.2
server may renegotiate (secure renegotiation only; tls has no client setting
to refuse it, and SQL Server doesn't renegotiate).

With tls 2.5 or later, the RSA key in the server's certificate must have at
least 2048 bits. This is tls's default (`supportedMinRSAKeySize`), and hmssql
keeps it. tls checks the key after the `onServerCertificate` hook, so the
rule holds with `tlsTrustServerCertificate`. Every mode runs a handshake for
the login, `EncryptOff` included, so a server with a shorter key can't be
reached at all. OpenSSL 3 refuses the same keys at its default security
level, so an ODBC driver on a current Linux fails against the same servers.
hmssql builds against tls 2.4.4 and later, and before 2.5 tls has no such
check.
* *Alternative rejected:* lowering the minimum to 1024 bits, or adding a
  setting for it, so that an older SQL Server with the certificate it
  generates for itself can be reached. A 1024-bit RSA key is no longer
  considered secure. Installing a 2048-bit certificate on the server fixes
  it there, and no new setting is needed.

**Secrets.** `ConnectInfo` and `TlsSettings` have no `Show`, `Login7`'s
`Show` hides the password, and no exception includes it or its length. An
open connection doesn't keep the password reachable, but it isn't wiped
(GHC can't). `SqlServerError` carries the SQL text that failed, not
parameter values; `EncodeError` and `DecodeError` may quote the value at
fault.

## Exceptions

**Exception names describe hmssql's own recovery boundaries**, not a
one-to-one mapping to hpgsql's. Hpgsql's `IrrecoverableHpgsqlError` is a
broad client-failure category that includes decoding failures; hmssql
instead drains those responses and keeps the connection usable.
`ConnectionBroken` reports subsequent use after a recorded failure, not
an umbrella around every initial fatal error. The initial operation
reports its own exception; after explicit `close`, later requests report
`ConnectionClosedBy ClosedByClient`. It carries an `UnusableReason`, not a
`SomeException`, so that it and `unusableReason` have one vocabulary. The
initial exception has the statement, so a reason needs no SQL text.

**`UnusableReason` lists what hmssql records**, tagged where it records it. An
exception of a known type names its own reason whatever was going on
(`reasonFor`): `ConnectionClosed` is `Closed`, `ProtocolError` is
`ServerProtocolViolation`, and a `ConnectionBroken` isn't nested. The first
reason stays, except that `close` is always reported, as `checkNotBroken`
does.

| Reason | Recorded by | Trigger |
|---|---|---|
| `Closed` | `closeConnection`, the reader thread, `sendFailed` | `close`, an end of stream, or a transport failure |
| `ServerProtocolViolation` | The reader thread (`demultiplex`), `breakOnFailure` | Malformed SMP or TDS |
| `FatalServerError` | The token reader | An ERROR token of severity 20 or more |
| `ServerFailedConnection` | `throwSevere` | DONE_SRVERROR with no ERROR token |
| `SendFailed` | `sendFailed`, `breakingOnFailure` | Any other exception out of a send |
| `ReadFailed` | `breakOnFailure` | Any other exception out of a read |
| `DrainFailed` | `finishSession` | A drain that failed or was interrupted |
| `ResetRefused` | `resetWithSessionSetup`, `release` | An ERROR token or a failed DONE answering the request that carried a reset |
| `ResetFailed` | `resetWithSessionSetup`, `release` | Reading that response failed, or any other cleanup failure |
| `RollbackFailed` | `withTransaction`'s cleanup | The rollback failed or was interrupted |
| `ReaderThreadDied` | The reader thread | Anything else ended it, which is a bug |

* *Alternative rejected:* a `TransactionCleanupFailed` constructor of
  `TransactionError`, which was never thrown, only wrapped in
  `ConnectionBroken`. A failed cleanup is the reason `RollbackFailed`.
* *Alternative rejected:* `ConnectionBroken` carrying a `SomeException`,
  which gave it and `unusableReason` two vocabularies.

**A `SevereError` with DONE_SRVERROR marks the connection broken at once**,
as a severity 20 error does, because the server closes the connection
after it (Azure SQL Database, measured on a killed session). DONE_ERROR
alone leaves the connection as it was.

* *Alternative rejected:* waiting for the reader thread to see the close.
  It left a window in which `unusableReason` said `Nothing`, with no
  benefit.
* *Alternative rejected:* leaving the connection to DONE_SRVERROR's
  closure, on the ground that MS-TDS defines the flag as the failure of the
  statement's result set without requiring the connection to end. The
  window above is the cost.

[Npgsql's error documentation](https://www.npgsql.org/doc/diagnostics/exceptions_notices.html)
also distinguishes server-reported `PostgresException` from driver-level
`NpgsqlException`; these categories alone are not a universal recovery
policy. PostgreSQL's [extended-query protocol](https://www.postgresql.org/docs/18/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY)
uses Sync/ReadyForQuery for error resynchronization, but Sync does not
close an explicit transaction block. Protocol usability and transaction
recovery are separate concerns.

`SevereError` retains SQL Server client terminology without promising
that every such error is fatal. In [SqlClient's DONE handling at commit
b368afd983e0bddfd48761d6aeb9bae7c1395f6c](https://github.com/dotnet/SqlClient/blob/b368afd983e0bddfd48761d6aeb9bae7c1395f6c/src/Microsoft.Data.SqlClient/src/Microsoft/Data/SqlClient/Parser/TdsParser.cs#L3679-L3704),
the same severe-error message is used for DONE_ERROR without an error
token at `MIN_ERROR_CLASS` and for DONE_SRVERROR at `FATAL_ERROR_CLASS`.
Hmssql preserves the distinction through `severeErrorServerError`.

| Exception | When |
|---|---|
| `SqlServerError` | An ERROR token: number, state, severity, message, the statement. Severity 20 or more breaks the connection immediately, before transport closure; lower severities leave it usable. |
| `SevereError` | A DONE flagged DONE_ERROR or DONE_SRVERROR in a response with no ERROR token: the server failed the request without a message (a killed session). Carries the DONE and the statement; DONE_SRVERROR breaks the connection at once, since the server closes it. |
| `LoginError`, `LoginRedirected` | The login was refused (at any severity; `isTransientLoginError` for a refusal of the moment), or answered with a routing ENVCHANGE. |
| `MarsNotSupported` | `connectMars` was set and the server doesn't do MARS. `connect` closes the socket and throws it rather than connect without MARS. |
| `DecodeError` | A column type the decoder doesn't accept, a wrong column count, a malformed value, a UDT or double-byte column. Named column; the rest of the batch still runs (the response is drained, not cancelled). |
| `EncodeError` | A parameter, name, statement or `ConnectInfo` the wire can't carry, before anything is sent. |
| `ProtocolError` | A byte stream the client refuses (see above). Breaks the connection. |
| `ConnectionClosed` | The pattern matches any `CloseReason`; the expression is `ConnectionClosedBy ClosedByServer`. `ClosedByServer` for an end of stream (including TLS's), `ClosedByClient` after `close`, `TransportFailed e` for an `IOException` or `TLSException` from the transport, including `connect`'s socket failures. Never a raw transport exception. |
| `ConnectionBroken` | Every request after the connection broke; carries the `UnusableReason`. |
| `ResultAbandoned` | A `queryS` stream superseded by a newer request, interrupted, or drained already. On a MARS connection a newer request leaves the stream open, so only a cancel abandons it: `cancelResponse` or the end of `withQueryS`, `cancelActiveStatement`, a `reset`, the rollback of a transaction it was open in, or an interrupted read. |
| `TransactionError` | `TransactionAlreadyActive`, `TransactionEndedEarly`, `TransactionRequestsActive` (on a MARS connection: another response unfinished at a begin or commit, with each one's SQL text), and `TransactionStillOpen` (a nested transaction left open at the commit). |
| `ReentrantCallback` | The info-message callback used its own connection. |
| `ConnectionReleased` | A handle used after `release`, or after `renew` made a newer one; its streams too. Thrown before anything is sent; the connection is unaffected. |
| `UnexpectedResult` | `ResultSets` asked for a result set that isn't there; `queryMay` got two rows. |

## Memory and performance

The measurements behind these rules, and those of the row-walk
implementation the value-streaming rewrite replaced, are in
[performance-research.md](performance-research.md) and
[value-streaming-research.md](value-streaming-research.md).

**Memory is bounded by what is being read, not by the result.** A recipe
keeps only the current payload's bytes and the values a caller asks to
retain; streaming consumers and drains don't assemble values; and a value
of known length is assembled in at most 1.25 times its size
([What the wire layer checks](#what-the-wire-layer-checks)). `queryS`
reads 10 million rows, and a 1 GiB `varbinary(max)` streams, in bounded
memory, and every cost axis measured (columns, rows, result sets,
messages, parameters, SQL length, output parameters, NBCROW bitmaps and
PLP chunks) is linear.

**A request the server never answers costs nothing while it waits.** The
waiting thread blocks in STM on what the reader thread hands on (the
connection's `TMVar`, or under MARS its session's queue), and the reader
thread blocks in its receive; neither polls, and nothing is kept per unit
of time. Measured for 15 minutes each against an in-process mock that
stops answering (2026-10-15, GHC 9.12.4), on a plain connection, under MARS
and over strict TLS, with no answer at all, rows without END_OF_MESSAGE, a
packet cut short and a `varbinary(max)` value cut after 1 MB: the live
heap moved by at most 4 KB, within the first four minutes, and then not by
a byte, and the process used no CPU. A loop of `timeout`s on such a
connection goes as [Interruption and cancellation](#interruption-and-cancellation)
says ("No Attention timeout"): the first interruption sends the Attention,
the second interrupts the next request's drain and so breaks the
connection, and every request after it throws `ConnectionBroken` at once,
with the live heap flat. `Resources.StalledServer` keeps the shape of it
in 2 s per case, a minute each with the slow tests.

**The reader thread is unbound by default** (`forkIO`). With
`connectPinReader` it is forked on the capability of the thread that
connects (`forkOn`); when that is the thread that then waits for the
responses, handing it a chunk doesn't wake another capability, which with
`+RTS -N` on 32 hardware threads took a no-op batch's round trip from 126
to 77 us of wall time.

* *Alternative rejected:* pinning by default. A pool's connections, opened
  by one thread, would share that capability for their readers, which
  decrypt and copy what they receive, however many threads then use the
  connections. Sixteen connections read in parallel by sixteen threads
  took the same time either way, but a sustained TLS workload wasn't
  measured.

**What a TLS record costs is the `tls` package's.** `tls` 2.4.7 or later
over `crypton` 2.1 encrypts and decrypts AES-GCM in one call with AES-NI;
an earlier `tls` goes through crypton's general AEAD interface, which sets
up the key per record, and `crypton` before 2.1 has no accelerated GCM
decryption. hmssql accepts either (`tls` 2.4.4 or later), and
`stack.yaml`'s snapshot has the slow pair. Against a local server (GHC
9.12.4, the same build but for the two packages) a trivial round trip took
30 to 42 us of client CPU with the slow pair and 18 to 25 with the fast
one, and reading a 4 MB `varbinary(max)` 15.1 ms against 7.1. Where crypton
has no accelerated AES, the cipher is most of the client's CPU (on Apple
silicon with `crypton` 1.1.5, about 70% of a request loop's samples).
hmssql offers `tls`'s default suites and has no setting for them
([limitations.md](limitations.md)).

* *Alternative rejected:* pinning `tls` and `crypton` above the snapshot in
  `stack.yaml`, which would make every project built on the same snapshot
  pin them too.
* *Alternative rejected:* a fork of `tls` or a change of its instances to
  drop its dependency on `serialise` and the packages behind it (about 5.5
  MB of an unsplit program). That is a proposal for `tls`.

**The library leaves code-layout choices to the application's build.**

* *Split sections.* A Cabal consumer can ask for `split-sections: True` in
  a `package hmssql` stanza, or in `package *` for its other dependencies
  as well, as for any Haskell package; under it only the
  decoders of the types a program uses are linked. *Alternative
  rejected:* `{-# OPTIONS_GHC -split-sections #-}` in each module of the
  library (`cabal check` refuses the flag in `ghc-options`), which took
  1.3 to 1.9 MB off a program that doesn't split its dependencies, but was
  a platform-dependent setting in every module for something the
  application decides (the owner's decision of 2026-11-04).
* *Procedure alignment* is the compiler's default. *Alternative
  rejected:* `-fproc-alignment=32` on `Hmssql.Tds.Utf16`, which recovered
  a 17% loss on short CJK text caused by where the linker placed two
  jumps, not by the decoder. The next layout may differ, and a
  layout-dependent setting isn't worth checking on every supported
  configuration (the owner's decision of 2026-11-04;
  [performance-research.md](performance-research.md), "Code layout and the
  short CJK case").
* *`-O2` only where it was measured to pay*: `Hmssql.Tds.Packet`,
  `Hmssql.Tds.Utf16` and `Hmssql.Tds.CodePage`, the loops over every byte.
  *Alternatives rejected:* `-O2` library-wide, which made the token parser
  slower; on `Hmssql.Tds.Parser` and `Hmssql.Tds.Value`, which stayed
  within the noise (2026-11-04); and on `Hmssql.Decoding`, whose
  compilation passed 8 GiB of memory and was stopped. A module gets `-O2`
  only with a benchmark behind it.

### How an optimization is kept local

The library is a clean, functional interface that orchestrates the movement of
bytes, and the bytes underneath move without needless copies. Those are two
layers, and an optimization must not blur them. A parser or writer implementer
sees recipes and whole values, with no offsets, phases or buffer management in
view. Control flow is in the code: state travels through arguments, results and
continuations, choices are sum types, and values are immutable once they exist.
Underneath, a small module may use whatever moves the bytes fastest, provided
its unsafety ends at its own interface. Value streaming had to be scrapped and
redone partly because earlier optimization had spread into the shape of the
code: `Row`'s array of offsets, the `buffer offset length` signature of every
value reader, three inlining rules that every decoder had to follow, a loop
GHC compiled into a second, boxed copy when a NULL was tested by a guard
rather than by a kind, and a second row parser. So an optimization goes in
only on these terms:

* One module, or one function, knows the trick, behind that module's existing
  interface. Callers don't change, or change only by losing code, and removing
  the optimization is one small commit.
* Decoders and token recipes stay ordinary code. A new field type, token or fix
  is written as it would be with no optimization present, and may run slower
  than the rest, but can't break anything.
* Raw buffer access is allowed inside the module that owns the buffer, with its
  bounds and lifetime handled there and no pointer or offset in the interface
  (`unsafeWriteUtf16LE` is the model; `unsafeWriteSized` is the one exception,
  its callback confined to the bulk row writer). `accursedUnutterablePerformIO`,
  `runRW#` around a load, and any write to memory a `ByteString` refers to stay
  out.
* An optimization of more than about 20 lines moves a common-case benchmark by
  at least 10% in time or 20% in allocation, and its object code is checked
  too. A comment beside it gives the number and what was rejected. Timings
  compare saved binaries in alternating pairs, with nothing else building
  (`scripts/perf-compare.sh`).
* Code that is inlined into an application is paid for at every use: each field of
  each record, each row type in a module and each call site. An application of 50
  records has about 1,200 fields, so 1 KB per field is 1.2 MB, and the inlined
  decoders were once 25 KB per field and 30 MB in all. So library code that
  reaches an application through INLINE, a class method's default or a
  specialisation is kept to a call, or to what the hot path needs, and its cost is
  measured with `scripts/code-size.sh` and per call site. The test matrix runs
  `scripts/code-size.sh --check`, which fails when the decoders or encoders of its
  records pass 100 bytes per field, so that an INLINE added later shows at once.
  The library's own code is paid once per program, and only where a program links
  it unsplit, so code there can be traded for speed more freely.
* No control blocks, as below.

**Show and Eq through helpers.** The library's `Show` instances are written with
out-of-line helpers from `Hmssql.Internal.Derived`, generated mechanically from
`-ddump-deriv`, and its `Eq` instances compare small fields inline and the rest
through an out-of-line `eq`. The constructor and field names are `Addr#`
literals that the helpers append directly, 19 KB less `.data` than `String`
literals for 184 bytes of code. Primitive fields are compared inline because
sending them through `eq` boxes them: on `Token`'s types, derived `Eq` was 14.0 KB,
inline primitives 8.1 KB, and everything through `eq` 10.5 KB. A derived `Show` constructor was about 600 bytes, two or three
lazy `ShowS` closures per field with `showsPrec` copied into `show` and
`showList`, and derived `Show` and `Eq` were 315 KB of the library; through the
helpers they are 197 KB less, with the output byte-identical
(`InternalDerivedSpec` checks the helpers against derived twins). Enumerations
keep derived `Show`, and the types compared per cell or per packet (`Cell`,
`ColumnShape` and `PacketType`) keep derived `Eq`. A field added to a type has to
be added to its instances by hand, and a record written with `{..}` in its
instance (Login7's and Feature's `Show`) doesn't fail to compile when it isn't.

* *Alternative rejected:* a generic `Show` through `DerivingVia`, larger when GHC
  specialised it, and 6 KB smaller with NOINLINE methods once `from` and `to` were
  counted.

**No control blocks.** A control block is one object holding a set of mutable
variables that every step of a process reads and updates: a position, a phase,
the current column, a flag for what happened earlier. Each attempt here that
started from one was rejected: the old `RowReader` with eleven fields, a
`RowCursor` of twelve registers in a `MutablePrimArray` beside `IORef`s, and a
second `RowReader` of thirteen fields.

* GHC optimizes values it can see, and a mutable location is opaque to
  case-of-known-constructor, unboxing, SpecConstr and join points, so each step
  re-reads, re-dispatches and writes back. An `IORef Int` read chases two
  pointers, and a write allocates a box and runs the write barrier; a record
  update copies the record; past `-fmax-worker-args` a record is no longer
  unboxed into its worker; and a closure captures each field it uses, which cost
  448 bytes per cell in one stream's pull function.
* Sum types are cheap when GHC can see them: a constructor meeting a known `case`
  is never allocated, a recursive function taking a sum is specialised per
  constructor, and a local state machine of mutually recursive functions compiles
  to join points. A phase stored in a record is the worst use of one: it is
  allocated, stored, read back and dispatched on again.
* Code grows with a control block: every inlined function that touches the record
  carries its field loads, every update site its stores, and field selectors and
  their unfoldings grow quadratically with the record's size in Core.
* A control block's fields are shared by everything that touches it, so a new
  feature adds a field and a phase that every step must consider.

Instead, a phase or a column is the place in the code or an argument to a loop, a
position to resume from is a continuation, several flags are one sum type, a field
set up for a later step is a value computed once and captured, and a rewind is a
local variable, because the bytes are immutable. A record of more than two to four
fields, or of fields with different lifetimes, calls for another look. A buffer
being filled inside the module that owns it is not a control block, and neither is
a single reference holding one sum-typed state committed at clear points, such as
`arState`. `Connection` and `ActiveResponse` carry several `IORef`s, read per batch
rather than per cell; don't add to them.

### RTS options

How the runtime is set up matters more for a database client's CPU time
than most of the library's own costs. These are the guide's
recommendations, and the figures behind them are of the threaded runtime
(`-threaded`), which the test suite and the benchmarks are linked with;
each connection has a reader thread. On Windows hmssql runs without it as
well ([Platform workarounds](#platform-workarounds)). Measured with the
benchmark suite on a 16-core Linux machine with 32 hardware threads, client
CPU per call (the server's time not counted), GHC 9.12, September 2026, with
the row-walk implementation of the time:

| | `-N1 -A64m` | `-N1 -A4m` | `-N1 -A1m` | `-N4 -A64m` | `-N -A64m` (32) | `-N -A4m` (32) | `-N -qg -A64m` |
|---|---|---|---|---|---|---|---|
| mock server round trip | 10 us | 10 us | 10 us | 25 us | 40 us | 42 us | 30 us |
| local SQL Server `SELECT 1` (TLS) | 31 us | 30 us | 26 us | 50 us | 44 us | 48 us | 35 us |
| 10,000 rows of `(Int32, Text)`, `query` | 1.9 ms | 2.0 ms | 3.3 ms | 2.1 ms | 2.2 ms | 4.2 ms | 2.0 ms |
| the same, `queryFold` | 2.0 ms | 1.7 ms | 1.8 ms | 2.1 ms | 2.0 ms | 3.5 ms | 2.0 ms |
| 1000 rows of 50 columns, `query` (mock) | 3.1 ms | 5.6 ms | 8.5 ms | 3.0 ms | 3.4 ms | 13 ms | 3.1 ms |
| a 4 MB `varbinary(max)` value | 15 ms | 16 ms | 18 ms | 15 ms | 19 ms | 27 ms | 17 ms |

What that suggests:

* **Few capabilities.** Every capability takes part in each garbage
  collection, and idle ones are woken for it: with `-N` on 32 hardware threads a
  round trip costs four times the CPU it does with `-N1`, and a
  materialized result up to twice as much. Use as many capabilities as
  the program has work for (`-N4`, say, for a web server with a pool);
  with many, `-qn2` to `-qn4` (fewer threads in the parallel GC) or `-qg`
  (none) keeps the collections cheap. A connection's reader thread is
  unbound unless `connectPinReader` pins it
  ([Memory and performance](#memory-and-performance)).
* **A larger nursery for materialized results.** `query`, `queryMulti`
  and `execute` build their whole result before returning it, and each
  minor collection copies what has been built so far: with the default
  `-A4m`, 1000 rows of 50 columns cost 1.8 times what they do with
  `-A64m` (four times the bytes copied), and with `-A1m` 2.7 times. `-A16m`
  to `-A64m` suits a program that reads result sets of more than a few
  thousand rows. (The nursery is per capability: `-N32 -A64m` is 2 GB of
  it.)
* **Stream large results.** `queryFold`, `queryS` and `responseS` hand on
  each row as it arrives, so nothing is live for long and the nursery
  size hardly matters (a smaller one is even a little faster, being
  warmer in the cache); memory stays flat however many rows there are.
  A result of millions of rows should be folded or streamed, not
  materialized: a large `[r]` is live data that every major collection
  copies again.
* `-I0` (no idle GC) for a server that is idle between requests, if the
  idle collections show up.

## Platform workarounds

On Windows a connection's I/O takes one of two paths, chosen once for the
whole program: hmssql's own overlapped I/O, under GHC's default I/O
manager or with a network or GHC that can't use the native one; or, under
the native I/O manager with a network that supports it, network's own
calls for TCP and the manager's completion port for the pipes. The first
three subsections are the first path, the next two the second, and the
rest hold on either.

### Windows: hmssql's own I/O

**No I/O through GHC or network under the default manager.** With the
threaded RTS and the default I/O manager, network's `recv`, `sendAll` and
`accept` block in a foreign call that no asynchronous exception reaches.
Measured in a compiled program with network 3.2.9.0 and GHC 9.12.4:
`killThread` on a thread blocked in any of the three had not returned after
3 s, and neither had a `timeout` of 300 ms around `recv`. `close` kills the
reader thread, so it hung, which is how this was first noticed, and a
`timeout` around a handshake or a blocked send could not have worked
either. So hmssql does its own I/O there, on sockets as on pipes, in
`Hmssql.Connection.Backend.Windows`:

* Every operation is started overlapped (`ReadFile` and `WriteFile` on
  the handle, each with its own `OVERLAPPED` and event), so the call
  returns at once. A socket is a handle these accept. network is still
  used to resolve and to connect.
* Every operation is started on one bound thread, the issuer, which lives
  as long as the process. Windows cancels a pending overlapped operation
  when the thread that started it exits, and a Haskell thread runs on
  whichever of the runtime's worker threads has it at the moment, which
  the runtime ends when it has no more use for it. Started in place, a
  read was cancelled now and then with nobody having asked, and the
  connection failed with `ERROR_OPERATION_ABORTED`
  ([windows-research.md](windows-research.md#a-pending-operation-dies-with-the-thread-that-started-it)).
  The starts are calls that return at once, so one thread serves every
  connection.
* An operation's outcome is read from its `OVERLAPPED`, where the kernel
  leaves the status and the byte count, and not from `GetLastError`,
  which belongs to an operating-system thread.
* A pending operation is waited for on an `MVar`, which a helper thread
  fills when its blocking wait on the operation's event returns. The
  `MVar` wait is where an exception can land. The operation is then
  cancelled with `CancelIoEx` and waited for, uninterruptibly, because
  its buffer and its `OVERLAPPED` must not be freed while the kernel may
  still write to them.
* "Stop receiving" and "shut down" set a flag and then cancel. An
  operation checks the flag before it starts and again once it is
  pending, so a stop is not lost between two receives.
* A connect and a name lookup, which are foreign calls too, run on a
  thread of their own. A caller that is interrupted leaves at once, and
  the thread closes the socket it made when its call ends.
* The handle is opened with `FILE_FLAG_OVERLAPPED`. A handle opened
  without it serialises its operations, so the Attention's write would
  wait behind the reader's blocked read.

The cost is a hand-off to the issuer and back for every operation, and a
thread and a safe foreign call besides for each one that has to wait,
which is no more operating-system threads than network's blocking calls
used. Measured on a loopback echo of 100 bytes each way, a round trip
took about 62 µs where network's own calls took about 26
([windows-research.md](windows-research.md#what-the-backend-costs)). The
36 µs are accepted: on Windows a connection that never fails by itself,
and that a timeout can interrupt, matters more than a fast round trip
([The backend](#the-backend-what-the-bytes-travel-on) says who it is for).

* *Alternative rejected:* starting each operation on the calling thread,
  which is the bug described above.
* *Alternative rejected:* network's calls with `CancelIoEx` on the socket,
  to end a blocked `recv` from another thread. It could make `close` work,
  but nothing would make a `timeout` around a send or a handshake work,
  and Windows would have two I/O paths.
* *Alternatives not taken, and not measured:* a `shutdown` of the
  receiving side, which may not wake a `recv` already blocked on Windows;
  and closing the socket under the reader, which the reuse of handle
  numbers rules out ([The backend](#the-backend-what-the-bytes-travel-on)).
* *Alternative rejected:* GHC's `Handle` for the pipes. Its behaviour
  depends on the I/O manager, and this code has to work under both.
* *Alternative not taken:* a C function that starts an operation and
  waits for it in one foreign call, made from a helper thread. The thread
  that started the operation is then inside the call until it ends, so
  it can't exit first, and there is no hand-off and no single thread that
  every connection shares. But a probe of it that forked a thread for
  every operation took 50 to 67 µs a round trip where the issuer's path
  took 40 to 43 on the same day
  ([windows-research.md](windows-research.md#the-non-threaded-runtime)),
  and the threaded path is the one the suite has run on longest. It is
  the first thing to try if the issuer turns out to cost too much, with a
  helper only for an operation that is pending.
* *Alternative not taken:* a completion port of hmssql's own, with a
  thread that takes its completions. An operation whose `OVERLAPPED`
  carries no event, on a handle with a port, is not cancelled when its
  thread exits (measured; with an event it is, port or no port), so it
  could be started in place with no issuer. It is a second I/O manager in
  miniature, and the next thing to try after the C function.

### Windows: the non-threaded runtime

Without `-threaded` a safe foreign call stops every Haskell thread, timers
included, so neither the helper's wait nor network's connect or lookup can
be made from Haskell. GHC's default I/O manager has what is needed
instead: `asyncDoProc` runs a C function of one pointer on one of the
manager's worker threads while the scheduler goes on, and an asynchronous
exception reaches the Haskell thread that waits for it. The exception only
abandons the request, though, and the function runs on to its end. So the
C functions are in `hmssql/cbits/windows.c`, each request owns what its function
uses, and the function signals the request's own event as the last thing
it does with it:

* An operation is started in place, by the calling Haskell thread. Every
  Haskell thread then runs on the operating-system thread that runs the
  scheduler, which lives as long as the runtime, so nothing ends the
  thread under a pending operation and there is no issuer.
* A pending operation is waited for by a worker, in
  `hmssql_wait_operation`, which waits for the operation's event or for a
  cancel event of the handle's direction. Interrupted, the Haskell thread
  sets the cancel event and waits, uninterruptibly, for the worker's
  done event. On the cancel event the worker cancels the operation with
  `CancelIoEx` and waits for it to end. A worker that begins its wait
  only after the interruption, which happened in a third of the kills of
  a probe, finds the cancel event set and does the same, so neither it
  nor the kernel refers to the buffer once the Haskell thread goes on.
* A name lookup, a connect and the open of a pipe each run on a worker,
  with copies of their arguments. A caller that is interrupted leaves at
  once, and a thread of its own frees the request when the call ends,
  with what it made: the addresses, the socket or the handle.
* The native I/O manager of a released GHC has no such workers, and
  `asyncDoProc` crashes the process under it, so this backend refuses to
  run without `-threaded` under that manager (`requireRuntime`). Only a
  build that can't take the native manager's path (below) reaches that
  refusal ([limitations.md](limitations.md)).

The threaded runtime keeps the issuer and the helpers: the two paths
differ only in where an operation starts and where its wait happens, and
the rest of the backend is shared. Measured against the local SQL Server
2019, 1000 `SELECT 1` round trips over TCP with encryption took about
136 µs each without `-threaded` and 151 µs with it, and a `timeout` of
500 ms around a `WAITFOR` of 5 s returned at 500 ms over each transport,
with the other threads running throughout. What the runtime itself costs
a program there, a worker thread for every pending delay and a reader
woken at the back of the run queue, is in
[limitations.md](limitations.md#windows).

* *Alternative rejected:* network's own calls. Under the non-threaded
  runtime its `recv` is interruptible, since network receives through
  `asyncRead#`, but the abandoned `recv` stays pending on its worker and
  takes the next bytes to arrive, which for hmssql is the start of the
  server's answer to the Attention
  ([windows-research.md](windows-research.md#the-non-threaded-runtime)).
* *Alternative rejected:* a C function that starts the operation as well
  as waiting for it, on the worker. It would survive Haskell being
  entered from other operating-system threads, which this doesn't
  support, but every operation would pay for a worker, a write that
  completes at once included: 45 to 51 µs a loopback round trip in the
  probe, against 32 to 36 for network's calls.

### Windows: GHC's native I/O manager

**One switch decides every transport.** In a program run under `+RTS
--io-manager=native` (WinIO), with or without `-threaded`, TCP goes through
network's own calls, exactly as on Linux and macOS, and Shared Memory and
Named Pipes go through the manager's completion port, in
`Hmssql.Connection.Backend.WinIO` (the next subsection), when hmssql was
built against network 3.3 or later with a GHC that defines
`__IO_MANAGER_WINIO__` as 2 or more. Those are the only builds in which
network compiles its code for that manager. `nativeIO` in that module says
whether that holds, and `networkTcp` in `Hmssql.Connection.Backend` repeats
it; it is fixed when the runtime starts. In every other build or manager,
TCP and the pipes stay on hmssql's own I/O. A program is either all on the
native manager or all on hmssql's own I/O: network 3.3 has nothing to do
with the pipes, but whoever opts in to the native manager uses it, and the
test matrix stays at one row per runtime and manager.

* *Alternative rejected:* a switch of the pipes' own, on
  `__IO_MANAGER_WINIO__` alone. It would add rows to the matrix for no
  user (the owner's decision of 2026-11-07).

**On that path hmssql is an ordinary user of network.** The goal is to
meet GHC and network where they are, without awkward workarounds. hmssql's
own I/O is the workaround for network's calls under the default manager,
which nothing interrupts. Under the native manager, with a network that
supports it, network's receive and `sendAll` are overlapped operations of
the manager, which an asynchronous exception cancels: network's `recv` was
interrupted 4,800 times from 16 threads and never hung
([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).
So that reason is gone. Whoever opts in to the native manager also uses
network 3.3 or later, and what network still lacks there is shared with
every other user of it, as warp is one, and is reported and fixed in
network, not worked around here. Most Windows programs have an older
network and the default manager, and keep hmssql's own I/O. This was the
owner's decision of 2026-11-06. The calls are `getAddrInfo`, `connect`
under the caller's `restore`, `recvBuf`, `sendAll`, `sendMany` of every
piece of every write, a "stop receiving" that does nothing, `shutdown` and
`close`.

What the path inherits from network master `1f6aa85` under GHC master
`20334e1d1f`, measured on loopback
([protocol-notes.md](protocol-notes.md#platform-and-tooling)), each a gap
to close in network or in GHC's manager ([backlog.md](backlog.md)):

* **A send blocks where nothing reaches it.** network's `sendMany` on
  Windows is a `WSASend` without an `OVERLAPPED`, a safe foreign call.
  Winsock takes the whole of a send while its buffer has room (64 MB to a
  peer that read nothing returned in 22 ms), so a send blocks only once
  the server has stopped reading. Then a `timeout` or a `cancel` aimed at
  the sender lands only when the server has read the rest of the message,
  which goes out whole, and the exception falls in the wait for the
  response, which cancels the statement with an Attention. `close` can wait
  for the sender too, because a shutdown doesn't end the call, until the
  server reads or ends the connection.
* **So does `connect`.** network's `connect` there is a safe call on a
  blocking socket, which never waits in the manager. A silent first
  address costs Windows's 21 s before the next is tried, because
  `addressConnectTimeout`'s `timeout` lands only when the call returns,
  and a caller's `timeout` around `connect` can't end it sooner either:
  it ends with the connect's own failure, `WSAETIMEDOUT`, after the 21 s.
  The lookup is the safe call it is on every platform.
* **A reset reads two ways.** A reset that arrives while a receive is
  pending completes it with `ERROR_NETNAME_DELETED`, which network's
  completion callback doesn't map. It surfaces as an `IOException` of
  type `InvalidArgument` with errno `EINVAL`, the Windows code lost, and
  the connection ends with `TransportFailed`. A reset that arrived before
  the receive began reads as the end of the stream, and so does
  `WSAECONNRESET`, which the callback maps to 0 bytes, so the connection
  ends with `ClosedByServer`, as if the server had closed it in order.
  Which of the two a reset gives is timing.
* **The manager's crash under a few dozen busy sockets** is now hmssql's
  exposure, as it is every other user of network's
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)).

* *Alternative rejected:* hmssql's own I/O for TCP under the native
  manager as well, which was the design until 2026-11-06. Each
  operation's `OVERLAPPED` carries an event whose low bit is set, which
  keeps its completion off a completion port, so a socket that network
  3.3 has associated with the manager's port can be read and written
  beside it, and the suite passed that way with GHC 9.12.4 and network
  3.2.9.0, with the pre-release 9.12.4.20260713 and network 3.3.0.0, and
  with GHC master and network master over TCP, threaded. It avoids every
  gap above, but it is a workaround where network no longer needs one. It
  stays for every build and manager where network's path doesn't hold.
* *Alternative rejected:* one overlapped `sendAll` for each piece in place
  of `sendMany`. It would be interruptible, but it would chunk the writes
  differently from every other platform.
* *Alternative rejected:* the connect under `abandonable`, as hmssql's own
  I/O makes it in the threaded runtime. It would make the network path
  special, and the fix belongs in network (a `ConnectEx` through the
  manager).
* *Alternative rejected:* a receive of hmssql's own on that path, to see
  the error a reset gives. It is the workaround the path removes.

**Without `-threaded` the same path holds**, and so does what it inherits,
with one difference: network's blocking calls (`getAddrInfo`, `connect`,
and `sendMany` once the server has stopped reading) are safe foreign
calls, which in the non-threaded runtime stop every Haskell thread, timers
included, until they return. The open of a pipe is one too (below).
`getAddrInfo` does that on Linux and macOS too, and a send blocks only once
Winsock's buffers are full, so in use that is a server that has stopped
reading a large request. The owner's decision of 2026-11-07 was to accept
it, for network's path wherever network supports the manager. GHC master
of 2026-11-06 freezes this runtime as well: a thread killed while
network's `recv` was pending, on a socket then closed, leaves the next
socket's first operation pending for good, because the manager waits for
the cancelled receive in a blocking `GetOverlappedResult`. A GHC branch
with the manager's fix, not yet upstream
([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)),
ran the suite that way with no hang. Three tests are pending there
(`Compat.blockingCallStopsProcess`): in two, a mock server in the same
process has to read for a blocked send to end, and the third connects to
an address that doesn't answer, which stopped every test beside it for
21 s.

* *Alternative rejected:* hmssql's own I/O for TCP without `-threaded`
  under the native manager. It runs once GHC's manager hosts the workers of
  `asyncDoProc` (the same fix), and the suite passed that way in six runs,
  but it would keep the workaround on one path where network now serves,
  and no released GHC can run it.

### Windows: the pipes through the native manager

Where network's path holds, each operation on a pipe is an overlapped
`ReadFile`, `WriteFile` or `ConnectNamedPipe` made through
`GHC.Event.Windows.withOverlapped`, on a handle associated with the
manager's port (`associateHandle'`), with and without `-threaded`. Under
that manager hmssql's own I/O is a workaround for nothing: it keeps its
operations off the port with the low-bit event, it needs the issuer
because an operation with an event dies with its thread, and without
`-threaded` it needs `asyncDoProc`, which crashes under the native manager
of every released GHC. The manager does what the backend does by hand: an
interrupted operation is cancelled with `CancelIoEx` and waited for,
uninterruptibly, on the `MVar` the manager fills, so a buffer is never
freed under the kernel. The foreign calls, the error table
(`throwWindows`) and the open's retries are shared with
`Hmssql.Connection.Backend.Windows`. There is no addition to network and no
Win32 dependency: network is a sockets library and a pipe shares none of
its code, and Win32's build trips virus scanners. The owner took these
decisions on 2026-11-07:

* **The open.** Windows has no asynchronous open: `CreateFileW` always
  returns once the open has ended, with no completion packet. With
  `-threaded` the open runs under `abandonable`, as on hmssql's own I/O.
  Without it the open is a plain safe call, which stops every Haskell
  thread while it blocks. A local pipe opens or fails at once: in the
  probe 2,000 opens of a listening pipe took 5.6 µs each on average, and
  a busy one failed with `ERROR_PIPE_BUSY` in 4.9 µs, the most of either
  0.5 ms ([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).
  A pipe on another machine waits for SMB, and a program that can't
  afford that stop uses the threaded runtime.
  * *Alternative rejected:* the open on a worker (`asyncDoProc`), which
    works only on a GHC with the manager's fix and crashes on every
    released one.
  * *Alternative rejected:* the open on a thread of Windows's thread pool
    (`TrySubmitThreadpoolCallback`), waited for by polling its event
    between `threadDelay`s or through a private pipe of the manager's.
    Either is machinery for the remote open alone, which is rare without
    `-threaded`.
* **Stop receiving sets the flag and cancels nothing.** `withOverlapped`
  allocates the `OVERLAPPED` itself, so cancelling the receive alone
  would mean catching its address in the start callback, where a send
  could free and reuse it before the canceller used it. As on network's
  path, `stopReader` kills the reader right after, and the kill cancels
  the pending receive inside the manager. A receive that starts after
  the stop fails at its check of the flag.
  * *Alternative rejected:* catching the address under a lock that the
    receive holds until `withOverlapped` returns. It is more code for no
    behaviour the kill doesn't give.
* **Close cancels the whole handle.** It sets both flags, calls
  `CancelIoEx(h, NULL)`, takes both operations' locks uninterruptibly,
  and closes the handle. An operation that becomes pending checks its
  flag once more in its start callback and cancels itself if the flag is
  set by then, so a close between an operation's first check and its
  `ReadFile` is not lost. A pipe has no shutdown, so shutdown is this
  close, as on hmssql's own I/O.
* **The start callbacks.** `ReadFile` and `WriteFile` return `CbNone`,
  and the manager works out from the result and the last error whether a
  packet is coming, as base's own `hwndRead` does. `ConnectNamedPipe`'s
  start classifies itself: `CbPending` on `ERROR_IO_PENDING`, `CbDone` on
  `ERROR_PIPE_CONNECTED` and `ERROR_NO_DATA` (a client that connected, or
  connected and closed, before the call), and `CbError` otherwise. The
  probe found no completion written for the two synchronous cases. The
  completion callback never fails: a failure comes back as its Win32 code
  and is thrown with `throwWindows`, so that `ResourceVanished`,
  `ECONNRESET` and `EPIPE` come out as on hmssql's own I/O. A code with an
  NTSTATUS's severity bits is converted first, since GHC master passed
  `0xC000014B` for a broken pipe until 2026-10-23.
* **Completion modes.** Each handle gets
  `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS`, so an operation that completes
  at once, as most writes to a pipe do, posts no packet and is finished on
  the caller's thread instead of after a switch to the manager's. The
  fixed manager asks the handle for the mode when an operation completes
  at once, so it handles either. Through hmssql's own API, a round trip of
  100 bytes over a pipe cost 52 µs threaded without the mode, against 42
  to 46 on hmssql's own I/O on the same build, and 36 to 39 with it; not
  threaded, 12 µs without and 9 with
  ([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).
  On a GHC without the fix the mode helps as well: that manager completes
  a request inline when the status word says it succeeded, which is right
  only when no packet comes.
  * *Alternative rejected:* the mode off, as on network's sockets. A
    round trip then cost more than on the I/O this path replaces.
* **A GHC without the fix.** The switch holds on upstream master and on
  9.12.5 and 9.14.2 when they are released, none of which has the
  manager's fix (on the branch `wip/winio-completion-packets`,
  2026-11-07, not yet upstream). There the pipes inherit the manager's
  crash under load and, without `-threaded`, its freeze, as network's
  path does. This is accepted: the native manager is an opt-in, the fix
  goes upstream, and the first release with it is to be named as the
  minimum ([backlog.md](backlog.md)).
  * *Alternative rejected:* gating the pipes' path on the
    `__GLASGOW_HASKELL__` of the first release with the fix, unknown
    today, and refusing the pipes without `-threaded` until then.

* *Alternative rejected:* the pipes on hmssql's own I/O under the native
  manager, which was the design until 2026-11-07. Without `-threaded` it
  needs `asyncDoProc`, so it needs the fixed GHC as much as this path
  does. An earlier path through the manager was removed on 2026-11-05
  because MARS over TCP crashed the process in the manager's
  `processCompletion`, and network's own calls reproduced it with nothing
  of hmssql's
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)).
  That is the bug the branch fixes.

### Windows: the pipe client

**A pipe is opened with `SECURITY_IDENTIFICATION`**, so the pipe's server
can learn who the client is but can't act as the client. It is the most
restrictive level SQL Server was seen to accept: with `SECURITY_ANONYMOUS`
it refused logins over Named Pipes, and no difference was measured between
identification and the default, impersonation
([windows-research.md](windows-research.md#the-impersonation-level-of-the-pipe-client)).
What it guards against is a program that creates the pipe's name before
SQL Server does, or while it is stopped: with the default level that
program could act as the user who connects.

### Windows: a certificate file is read with interruptions held off

With TLS, `connect` reads the files named in `tlsCaCertificateFiles`.
Under the native I/O manager a thread interrupted during a file read
sometimes never comes back, in GHC 9.12.4 and in the pre-release alike
([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)),
and a `timeout` around `connect` that fired in the read hung for good.
`buildCertificateStore` reads each file under `uninterruptibleMask_`, on
Windows only. Elsewhere the read is left as interruptible as the file is:
a regular file's read can't be interrupted anyway, and a path that blocks,
such as a FIFO, should not hang a `timeout` because of a bug another
platform has.

* *Alternative rejected:* reading the files on a helper thread, so that
  the caller stays interruptible. It is more machinery for a read of a
  local file that takes well under a millisecond.

### GHC's I/O manager: a stale registration

GHC's I/O manager, kqueue on macOS and BSD and epoll on Linux alike, can be
left with a stale registration for a descriptor number (GHC 9.6 through
9.12; fixed in 9.14), after which closing the next socket to get that
number throws (`kevent: does not exist`, or `epollControl: does not exist`
on Linux), leaves the descriptor open for the life of the process and
wedges every later wait on descriptors in the same bucket (every GHC
version checked, including master). network's `close` then never closes
the descriptor, not even from the finalizer. hmssql avoids both:

* every cleanup-time close throws no synchronous exception and falls back
  to `close(2)`;
* `close` shuts a socket down rather than closing it under a thread
  sending on it;
* `connect` never closes its socket under the reader thread it started;
  and
* a send keeps its connection reachable explicitly.

What hmssql can't avoid is a stale registration made by other code in the
same process: a connection then given a descriptor in the wedged bucket
waits forever in `connect` or in its reader, whatever the server does, and
its `close` waits too. That is how the test suite hung in the test matrix
([bugs-found.md](bugs-found.md#in-the-test-suite)). Repros and a draft GHC
issue are in [upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md).
