# Bugs found during development

Every bug found in hmssql before its first release, with its cause and its
fix, by area. None shipped in a release. They were found between
September and November 2026: first by the audit that compared hmssql with
the old mssql package, then by a test suite that grew from 89 examples to
about 6,000 ([testing.md](testing.md)), by adversarial reviews, by the
runs against Azure SQL Database and the test matrix, by the tests written
for MARS and for the Windows transports, by readings of the connection
code and a review of the wire layer, and by the reviews and optimization runs of
the value-streaming rewrite.
An entry says where it came from when that matters. They are listed so
that the behaviour they led to (in [design.md](design.md)) can be traced
to a cause, and so that a similar bug is recognised sooner.

Three rounds of mutation testing (139, 148 and 113 mutants) found no bug
in the library, only behaviour the suite didn't pin down, and the tests
were added. The audit of compiler warnings and partial functions found
nothing reachable. The bugs of the test suite itself are in the last
section, by kind.

## Wire format

* **Reading a large value after an interrupted read took quadratic
  time.** The reader appended each packet to the pending token's buffer
  lazily. An uninterrupted read never forced the chain, but a retried one
  copied N²/packet-size bytes: a 64 MB retry took 25 s instead of 1 s. A
  token's bytes became a list of chunks. Found by the audit, which had
  reported every large read as quadratic; only retries were.
* **A response message ending without a final DONE was accepted as
  complete**: an early END_OF_MESSAGE, a last DONE with DONE_MORE, or an
  empty message. The next request then returned the rest of the previous
  response. It is a `ProtocolError` now.
* **A row before its metadata didn't break the connection** once token
  reads moved to reader recipes: the metadata lookup threw outside the
  handler for protocol failures. The lookup uses that handler now, as the
  parser does.
* **A batch's row skipper could use an earlier statement's metadata.**
  Several RPCs batched in one request share an `ActiveResponse`, and its
  column metadata survived each statement's DONEPROC. Closing a statement
  clears it now. It isn't cleared when the first statement opens, because
  the reset gate may already have applied that statement's COLMETADATA and
  queued it for replay. Found by the implementer while assessing the
  second review of the parser rework (2026-11-01).
* **A token whose length the bytes don't bound was held without bound.**
  The incremental parser keeps a token's packets until the token ends, so
  a FEATUREEXTACK whose list never reached its 0xFF, a SESSIONSTATE,
  FEDAUTHINFO or Promote Transaction ENVCHANGE with a DWORD length, or a
  COLMETADATA of text columns with 255-part table names grew the client
  for as long as the server sent, in the login response as anywhere else.
  A token other than a row or a RETURNVALUE is refused with
  `ProtocolError` past 16 MiB (`tokenSizeLimit`,
  [design.md](design.md#what-the-wire-layer-checks)). Found by reading,
  prompted by the question of whether the login response is bounded
  (2026-10-25).
* **The Azure routing ENVCHANGE failed to parse.** Type 20 has a two-byte
  old value and the parser read one, so the login threw `ProtocolError`
  whenever Azure SQL Database used its Redirect policy. It throws
  `LoginRedirected` now, which the connect follows. The same pass fixed
  the Promote Transaction ENVCHANGE and accepts the transaction descriptor
  on either side. Found by the audit.
* **CLR UDT columns broke the connection**: their UDT_INFO was taken for a
  malformed token stream, so `SELECT *` from a table with a `geography`
  column killed the connection. UDT_INFO is parsed and read past now.
* **Smaller parsing errors**: an odd-length ORDER token misparsed the next
  token; a PRELOGIN option whose offset pointed inside the option table
  was read from there; LOGINACK's ProgName kept four trailing NULs (found
  by the audit); and an unsupported TDS version was printed in decimal
  after "0x".
* **A packet size of 8 or less**, from `connectPacketSize` or an
  ENVCHANGE, made the next request send empty packets forever, and one
  above 65535 truncated every packet's 16-bit length. Sizes are validated
  and clamped to 512 through 32767.
* **A SQL batch over 65535 packets** (64 MB at packet size 512) made the
  server close the connection without an error. It is refused before
  sending now. Found by running the suite at packet size 512.
* **The packet writer resumed a Builder primitive without the room it had
  reserved, twice.** With a packet payload of one byte, a two-byte
  primitive that followed a full packet was resumed in a fresh packet too
  small for it; the writer now makes room only for a primitive that fits a
  packet's payload, and stages a wider one. And when a staging buffer
  filled, the reservation its continuation asked for was dropped; it is
  kept now, with the check on the rare staged path alone so that the
  common path costs nothing more. Both need a payload smaller than a
  Builder primitive, which a connection's packet sizes (512 and up) never
  give, so only the wire layer used directly could reach them. Found on
  2026-11-04 by the generated property written for the poked BYTE-length
  parameters of the second optimization run, which compares the writer's
  packets with the Builder's framing; its regression test sends separate
  primitive Builders that aren't inlined, so that fusion can't hide the
  second reservation.
* **The unchecked surface was public, and the row reader could be fed
  again.** The row type of the row walk exposed its offsets, lengths and
  arrays, and the offset-based readers and text decoders trusted their
  arguments, so a caller could build a malformed row and make an ordinary
  field decoder read outside its buffer; and feeding the reader that had
  produced a row again wrote into that row. The reader was made single-use
  and the unchecked byte primitives moved to `Hmssql.Tds.Bytes.Unsafe`,
  and the reader recipes later took the row type and the offset forms
  away. Found by the second adversarial review, which also found two
  portability defects: on a 32-bit target a wire length of 2^31 or more
  became a negative `Int`, which an addition-based bounds check accepted,
  and multi-byte values were peeked and poked at unaligned wire offsets.
  `Hmssql.Tds.Bytes` refuses to build where `Int` is narrower than 64
  bits now, and `Hmssql.Tds.Bytes.Unsafe` reads a word in one access only
  on targets known to allow unaligned access, and byte by byte elsewhere.
* **Socket reads ran under `unsafeWithForeignPtr`**, whose contract a read
  that can block or be interrupted doesn't meet, and the byte readers and
  text decoders used `accursedUnutterablePerformIO`. The reads hold their
  buffer with `withForeignPtr` now. The byte readers were first moved
  under `runRW#` with `touch#`, and the value-streaming rewrite took them
  off `runRW#` altogether: they assemble values from bytes after one
  bounds check. Found by the second adversarial review.

## Connection lifecycle and transport

This section covers connecting (the transport, PRELOGIN, TLS, the login
and Azure) and a connection's life after it.

* **`connect` used only the first resolved address**, so `localhost`, with
  `::1` first, couldn't reach a server listening on IPv4 alone.
* **A silent first address cost the operating system's whole connect
  timeout** before the second was tried. The next address was tried only
  when a connect threw, which an address that refuses does at once and an
  address that drops the SYN does only when the system gives up (133 s
  measured on Linux, 21 s on Windows), so a `timeout` around `connect`, the
  documented remedy, never reached a working second address. Every address
  but the last gets 4 seconds now (`addressConnectTimeout`), and the next
  is tried when they expire. Found by reading (2026-10-13).
* **`connect` could leak its socket** if a `timeout` landed between the TCP
  connect and the installation of its cleanup, a window a few instructions
  wide, found by sweeping a timeout's delay across 5000 connects.
* **Strict encryption hung** when the server, or a wrong port, answered
  the TLS handshake with plain TDS.
* **Sending a TLS record holding several TDS packets** made SQL Server
  2025 reset a strict-encryption connection. The framing keeps one packet
  per record and gathers the records into one `send` instead.
* **LOGIN7 was framed at the requested packet size.** hmssql framed
  PRELOGIN and LOGIN7 at the packet size the caller asked for, 8000 by
  default, where 4096 applies until the server grants a size in the login
  response. A password login never reached 4096 bytes, so nothing
  noticed; a login carrying a 2.3 KB access token (4.6 KB as UTF-16) did,
  and Azure SQL Database's gateway reset the connection under both kinds
  of encryption, where SQL Server 2025 had accepted the oversized packets.
  PRELOGIN and LOGIN7 are framed at 4096 now. Found by the first
  managed-identity login on Azure SQL Database (2026-09-29).
* **A strict access-token login sent no PRELOGIN.** Under `EncryptStrict`
  hmssql sent LOGIN7 right after the TLS handshake, but the FEDAUTH feature
  extension must echo the server's FEDAUTHREQUIRED answer from PRELOGIN.
  One is sent inside the TLS session now when a token is used, and for
  MARS; Azure answers FEDAUTHREQUIRED = 1 there and ignores the encryption
  value, as MS-TDS says. Found by the same login.
* **LOGIN7 offsets wrapped** for `ConnectInfo` strings totalling more than
  about 64 KiB, so the server read fields from the wrong places.
* **Azure SQL Database needed a redundant login server name from
  callers.** `defaultConnectInfo` left `connectServerName` empty and the
  library sent it empty in LOGIN7, which Azure's gateway refused with
  error 40531. An empty override now sends `connectHost` unchanged, and an
  explicit override and the name a redirect gives are kept.
* **The system certificate store was loaded again for every
  connection**: 16 ms and 38 MB of allocation each on macOS. It is read
  once per process now.
* **`close` from another thread delivered `ThreadKilled`** to a thread
  waiting for a response, which looked as if that thread had been
  cancelled, and using a closed connection threw `ThreadKilled` or a raw
  socket error. Both are `ConnectionClosedBy ClosedByClient` now.
* **`close` hung** on a connection opened under `uninterruptibleMask`,
  because the reader thread inherited the mask.
* **A connection dropped without `close` was never collected.** The reader
  thread and the hosted TLS backend's closures kept it reachable, so its
  session stayed open until the process exited.
* **`close` could run the connection's finalizer under itself.** Once
  `close` had read the fields it uses, nothing kept the connection
  reachable when the caller's handle was the last, as in
  `withConnection`. A garbage collection during the close found it
  garbage and ran the finalizer meant for a connection dropped without
  `close`, which stopped the reader and closed the socket before the TLS
  close_notify went out. That send failed on the closed socket and was
  ignored, as a failed goodbye is, and a send that had read the descriptor
  just before could have written the alert into whatever socket got the
  number next. Seen once in the overnight test matrix (GHC 9.6.6, 16 test
  jobs beside the matrix's other suites on 32 hardware threads), as
  `Mutation.StrictTls` finding no close_notify. 300 runs of that test
  alone passed; with a scratch `performMajorGC` before the goodbye, 20 of
  20 failed, and none of 20 with the fix. `closeConnection` keeps
  `connAlive` reachable throughout now (`keepAlive#`), as the sends and the
  blocking reads already did, and a test that runs a major collection as
  `close` stops the reader failed 5 runs of 5 without the fix.
* **A stream closed under it threw `ResultAbandoned`**, not
  `ConnectionClosedBy ClosedByClient`. The lock-free check before each
  row read the closed flag and then the response, and `close` could clear
  the response between the two. Both places check the connection again
  now before reporting a response abandoned. Reproduced 2 times in 500
  runs with every CPU busy.
* **A stream run again after its statement had failed and the connection
  had been closed** threw the old `SqlServerError` instead of
  `ClosedByClient`, because the withheld error had moved into the
  response reader's state. Found by the model tests (open a stream on a
  missing table, pull, close, pull).
* **The connection mutex held a strong `ThreadId`**, so a thread blocked
  forever while holding a connection was never told it was blocked, and
  never released it. Found by the audit.

## Interruption and cancellation

* **Request and response fell out of step on an interrupt.** The request
  was sent and its response registered without masking, and a `timeout`
  between the two made the next request read the interrupted one's reply.
  Reproduced within a few hundred iterations.
* **An interrupted read lost a token's effects** (column metadata, the
  final DONE, the acknowledgement or an ENVCHANGE) or a received chunk,
  which broke the connection with "ROW before COLMETADATA" and the like;
  with many threads under `killThread` it happened within a few thousand
  requests.
* **A second Attention**, sent after an interrupted wait for the first's
  acknowledgement, left every later request one response behind.
* **A cancelled stream could end early without an error**, missing rows,
  when the request draining it was interrupted.
* **An interrupted send broke the connection** even for a one-packet
  request, because the send blocked interruptibly on locks the TLS session
  shares with the reader thread. The first fix, uninterruptible sends per
  packet and an IGNORE packet, could defeat cancellation indefinitely,
  which the first adversarial review found, and was replaced by plain
  masking ([design.md](design.md#interruption-and-cancellation)). While
  the IGNORE packets existed, a failed one replaced the interrupting
  exception with `ConnectionClosed`, so a killed thread went on with a
  synchronous exception and a `timeout` didn't return `Nothing`; the same
  rule now holds for any interrupted send.
* **`close` swallowed an asynchronous exception** raised while it sent the
  TLS close_notify, which blocks if the server doesn't read, so a killed
  or timed-out thread carried on as if the close had succeeded.
* **A `timeout` during a failed login was swallowed** into `LoginError`.
* **Re-entry from the info-message callback** silently cancelled the
  response being read, and an exception from the callback marked the
  connection broken. **An interruption inside the callback** didn't send
  the eager Attention; found by the rewrite of the interruption tests after
  the first adversarial review.
* **An interrupted field consumer waited for the rest of its value.** The
  driver caught the interruption and drained the row before rethrowing,
  so a stalled server kept a `timeout` from returning. The driver saves
  the continuation and rethrows at once now, and the consumer's scope
  closes its value stream on exit; the next request drains the rest. A
  synchronous exception from a streaming consumer was likewise caught,
  carried in the row's result and rethrown after a drain, and now ends
  the query at once. The first was a defect of the first review of the
  parser rework (2026-11-01), and a mock withholds the rest of the value
  until the caller has returned.
* **A response abandoned outside a read kept its handle readable.**
  `abandonResponse` (an asynchronous exception between two reads, in a
  fold's step, or just after the send) marked the response abandoned and
  sent the Attention but didn't give the session's response a new
  generation, as an interrupted read does, so a stream read on through its
  handle would have ended at the acknowledgement, silently missing rows,
  instead of throwing `ResultAbandoned`. It was unreachable while
  `withQueryS` drained on every exit, and became reachable when an
  interrupted scope began leaving its response to the next operation
  (2026-10-02). The handle is abandoned before the send now.
* **`queryFold` ran its step for the rest of a batch** after a step had
  made another request on the connection, or closed it, because only the
  next read noticed. The response is checked before each step now. Found
  by the second adversarial review.

## Session setup and reset

* **The session setup ran differently at connect and after a reset**: one
  batch per statement, then one joined batch. A setup that relied on batch
  boundaries worked at connect and broke the connection after a reset. It
  is one batch in both places now. Found by the first adversarial review.
* **`rollback` after `reset`** failed with error 3903, since the reset had
  already rolled the transaction back.
* **A failed DONE without an ERROR token counted as success** in the
  session-setup batch and in `release`'s `SELECT 1`, although a query
  already treated it as `SevereError`. It is how the server refuses a
  reset under MARS. It is `SevereError` there too now: no connection at
  connect, a broken connection after a reset, and `False` from `release`.
  It held on plain connections too; found by the review of the MARS plan.

## Transactions

* **Other threads' requests ran inside a `withTransaction`**, and their
  own transactions nested into it, so one thread's rollback undid
  another's work. **A nested `withTransaction`'s inner rollback** silently
  ended the outer transaction, after which the outer body ran on in
  autocommit. **An asynchronous exception during BEGIN or COMMIT** could
  leave a transaction open.
* **`withTransactionLevel` leaked its isolation level** into the session.
* **The transaction guard checked existence, not identity**, so a body
  running `ROLLBACK; BEGIN TRANSACTION` had the wrapper commit the new
  transaction. The commit checks the descriptor's identity now. Found by
  the first adversarial review.
* **`withTransaction`'s interrupted rollback** discarded the interrupting
  exception in favour of the one that had caused the rollback, so a
  `killThread` or an outer `timeout` never reached its sender.
* **`withTransaction` returned normally with the work uncommitted** when
  the body began a nested transaction (`begin`, or a `BEGIN TRANSACTION`
  batch) and didn't end it: the COMMIT only lowered `@@TRANCOUNT` from 2
  to 1, and the locks stayed held. It rolls everything back and throws
  `TransactionStillOpen` now. Found by the review of the MARS plan; plain
  connections had it too.
* **The lazy BEGIN**, sent with the body's first request and tried during
  the first optimization round (September 2026), had four bugs. It was
  cancelled along with a first stream abandoned at once, 2 to 12 times in
  2000, and had to be armed again (found by the model tests). An inner
  `withTransaction` started after the outer transaction had ended could
  hand the outer the body's own BEGIN (the 5000-sequence model). An
  asynchronous exception between the end of a response and the settling
  of the BEGIN left it sent for good (found by reading). And a BEGIN armed
  again could skip the isolation level's cleanup (the second adversarial
  review). It was undone: the begin is a request of its own, a Transaction
  Manager request since MARS ([design.md](design.md#transactions)).

## MARS

The tests written for MARS (a mock SMP server, live tests of sessions,
flow control, cancellation and transactions, the model extended to
several open responses, and the whole suite over MARS connections) found
the first five below before the code was committed on 2026-09-30. The
review of that commit, five reviews by area against a checklist written
before the code ([mars-research.md](mars-research.md)), found the four
after them. Two older bugs the plan's review found are under
[Session setup and reset](#session-setup-and-reset) and
[Transactions](#transactions).

* **SMP DATA sequence numbers didn't wrap at 2^32.** The packets of a
  message were numbered by zipping them with `[sent + 1 ..]`, an
  enumeration of `Word32` that stops at the largest value, so a message
  that crossed it would have lost its remaining packets. They are counted
  modulo 2^32 now. Found by the mock server's test across the wrap.
* **An interrupted `query`, `execute` or other call that reads its whole
  response could leave the response open for good**: when the
  interruption landed outside a read, just after the send, or after the
  response had fully arrived, no Attention was sent, and the next request
  drained only responses that had one. The session stayed busy, and the
  next `withTransaction` threw `TransactionRequestsActive` naming a
  statement the caller had no handle to. These functions cancel their own
  response when they throw part-way now (`readingToEnd`).
* **`release` inside `withTransaction` threw `TransactionEndedEarly`**
  instead of `ConnectionReleased`, because the check before the commit
  found the transaction gone before it looked at the handle.
* **A `timeout` during a large read could break a MARS connection.** A
  read on an SMP session sends the ACK that reopens the window, and an
  asynchronous exception that landed in that send (it waits a moment for
  the TLS session's state, which the reader thread shares) broke the
  connection as any interrupted send does, where an interrupted read must
  leave it usable. Seen only under load, about one run in ten of the
  1,000,000-row timeout test with six test processes at once. The ACK is
  sent under `uninterruptibleMask_` now, the one exception to plain
  masking in sends, and 48 of 48 stressed runs passed.
* **On a MARS connection the server had closed, `withTransaction`,
  `begin` and `commit` threw `TransactionRequestsActive`** naming the
  responses the connection died with, again and again, instead of the
  connection's error, because the check for unfinished responses came
  before any look at the connection. It reports a broken or ended
  connection first now. Found by the model (`Kill`, then `TxBegin`).
* **A MARS reader lost the server's last words when an ACK came due after
  the connection had ended.** Once the reader thread had taken the
  server's FINs (after a severity-20 error or a `KILL`) or found a
  violation, a reader taking a queued packet whose ACK was due failed in
  the ACK's send, which broke the connection and dropped the packet. The
  stream threw `ConnectionClosed` instead of the severity-20 error it was
  about to read, and nothing queued behind it could be read. With a window
  of 4 every packet's read sends an ACK, and every fourth at the default
  of 64. No ACK is sent on an ended connection now, and one whose send
  fails because the end came meanwhile doesn't break it. Found by the
  review of the MARS commit's wire layer.
* **Settling every response cost a round trip per running statement.**
  `cancelActiveStatement`, `release`, a reset under MARS and a
  transaction's cleanup cancelled one session and read it to its
  acknowledgement before sending the next Attention. The Attentions all go
  out first now. Found by the same review.
* **An interrupted `runBatchQuery` could leave its response open for good**,
  the bug `readingToEnd` had fixed for `query`: `runBatchQuery` sends its
  messages itself and caught only synchronous exceptions. A `timeout` that
  landed in a `batchQueryFold` step, or anywhere outside a read, left the
  message's response busy with nobody to read it, its statement running
  and its locks held, and every later `withTransaction` refused with
  `TransactionRequestsActive` naming "(a request without SQL text)" until
  `release`. An interruption now marks the response abandoned and cancels
  the statement, as `readingToEnd` does. Found by the review of
  cancellation.
* **A leaked `batchQueryS` stream was nameless in
  `TransactionRequestsActive`** ("(a request without SQL text)"), since
  the request of several statements carried no text. It carries the last
  statement's now, the one a `batchQueryS` stream reads. Found by the
  review of transactions, which also found `withQuerySMWith` missing: the
  one member of the `queryS` family without a scoped form. `Hmssql.Query`
  exports it now.
* **SMP ACK and FIN packets accepted payload bytes.** The demultiplexer
  checked only the overall length range, then applied the window and FIN
  effects. It requires exactly 16 bytes for a control packet now, before
  either effect. Found in the review of 2026-10-23.
* **A MARS send wrote into a `ByteString` it was handed.** `sendPackets`
  poked the 16-byte SMP header at the front of each `ByteString` a
  producer gave it, trusting the producer to have left the room and to
  hold the only reference. A shorter packet was written out of bounds, and
  a shared one changed under its other holders. Bulk copy, the only
  producer, kept the contract, so nothing went wrong on the wire. A
  packet's storage is private to `Hmssql.Tds.PacketWriter` now, which
  makes the `ByteString` only after the packet's last write, and the SMP
  header travels beside the packet as a piece of its own
  ([design.md](design.md#who-owns-a-packets-bytes)). Found during the API
  cleanup (2026-10-30).

## Queries and parameters

* **Composing a `Query` from *n* pieces was quadratic** with the flat
  representation: 2100 pieces took half a second by `foldr`, and 10000
  twelve seconds. A tree with cached counts made it linear.
* **`mkQuery`'s lexer was quadratic** in the operators, doubled quotes or
  comment characters between two placeholders (20000 subtractions took
  123 ms, a string of 20000 doubled quotes 395 ms), which is a vector for
  CPU exhaustion through SQL text from outside the program. The scanner
  keeps offsets and slices the input now.
* **The hand-written placeholder renderer didn't terminate** on
  `Placeholder minBound`, since `negate minBound` is `minBound`, including
  through `Show`. Found by the second adversarial review, and gone with
  the renderer.
* **Parameter names were spliced unchecked** into the `sp_executesql`
  declaration, so `"x int, @y"` changed what was declared. Names are
  validated now.
* **`Text` and `ByteString` parameters were declared with the value's own
  length** (`nvarchar(1)` for `"x"`, `nvarchar(2)` for `"xy"`), so a
  statement run with values of different lengths compiled again for each
  length and filled the plan cache with copies, ADO.NET's `AddWithValue`
  problem. They are `nvarchar(4000)` and `varbinary(8000)`, or `(max)`,
  now, as SqlClient declares them.
* **Untyped NULL parameters couldn't reach `sql_variant`** (error 206).
  The fix, `nvarchar(4000)` and `varbinary(8000)`, silently truncated
  `ISNULL` and was reverted, so a NULL bound to `sql_variant` must be
  typed. Found by the first adversarial review.
* **`SqlXml` parameters were sent as `nvarchar`**: they read back as text,
  the xml methods were unavailable, and an xml output parameter couldn't
  be initialized (error 257).
* **RPC lengths wrapped.** A parameter name of 256 or more UTF-16 units
  went out short, with the rest read as the parameter's type (error 8009).
  A procedure name of 65535 or more units, a 65535-byte value with a
  USHORT length (its length became the NULL marker) and an empty
  BYTE-length `RawParam` (read as NULL) went out garbled. Each is an
  `EncodeError` before sending now.
* **Hand-built parameter types** with an invalid precision or scale were
  widened by `outParam` into valid ones, which hid the mistake, or sent
  for the server to refuse (error 8017). The time-family primitives
  accepted scales above 7, encoding wrong values from 8 and throwing from
  13.
* **Numeric parameter encoders forced lazy fields.** The first version of
  the unpacked numeric constructors of the second optimization run
  (2026-11-04) forced a lazy `Int32`, `Int64` or `Double` field while
  building the parameter spine, so `queryText`, `Show Query` and `mkQuery`
  to WHNF threw for values that had stayed unevaluated until encoding,
  tuples and `Only` included. The generic selector instance checks
  `selDecidedStrictness` now, so only a strict or unpacked field takes the
  constructor, and a singleton constructor keeps the lazy path
  (`Api.FieldEncoderStrictnessSpec`).
* **Procedure parameters used the default context.** `inParam` and
  `outParam` encoded eagerly with `defaultTdsContext`, so a custom encoder
  that needed the negotiated collation failed where an ordinary query
  parameter worked. Procedure parameters carry an encoder now, and
  `callProcedure` supplies the connection's context and checks every
  parameter before sending.
* **`Decimal` output parameters** were declared with the initial value's
  precision and scale (`0` became `decimal(1,0)`), so results overflowed
  or lost their fractions. Fixed-length `char`, `nchar` and `binary`
  output parameters truncated the result, and an input `Decimal`'s
  precision check refused values of scale 38.
* **`procOutputValues` came in wire order**, and the server sends
  `(max)`-typed values last, so pairing values with parameters gave wrong
  values.
* **Large output parameters became empty while rows were ignored**, since
  the feed that discards rows was chosen by the row decoder alone and
  discarded the RETURNVALUE's bytes too. `DiscardRows` keeps the tokens
  now and `DrainRows` skips their payloads.

## Types, decoding and encoding

* **NULL `sql_variant` failed to decode**, and a NULL `sql_variant`
  parameter was refused by the server (error 4002): its length on the wire
  is 0, not 0xFFFFFFFF. Non-NULL `sql_variant` output parameters failed as
  a result. Found by the audit.
* **Negative `Int8` parameters were corrupted**, sent as `tinyint`, so −1
  arrived as 255; they are `smallint` now. The same audit found `Integer`
  values beyond `decimal(38,0)` wrapped to their low 128 bits, `Decimal`
  decoding `tinyint` as signed, and `Integer` unable to read back its own
  large values.
* **Time values rounded past midnight** to 24:00:00, which the server
  rejects, and `datetime2` and `datetimeoffset` shared the bug through
  `putTime`. The fix rewrote every date and time encoder to the server's
  own rounding ([design.md](design.md#date-and-time)) and added range
  checks: days out of range had been sent as wrapped garbage, `datetime`
  rounded 23:59:59.999 to a whole day of ticks, `smalldatetime` truncated
  and wrapped, offsets were unchecked, and invalid `TimeOfDay` fields went
  out as they were. Found by the audit.
* **Non-UTF-8 `varchar` was decoded as Latin-1**, which is wrong for bytes
  0x80 to 0x9F under CP1252 and garbage for every other code page. It is
  decoded by the collation's code page now. Found by the audit.
* **`Money` out of range wrapped** modulo 2^64. **`datetimeoffset`
  offsets** were narrowed to `Int16` before the ±14:00 check, so 65,596
  minutes became +01:00, and −32768 passed the check, since
  `abs minBound` is negative.
* **A `UTCTime` with a huge negative day time wrapped into a valid
  date**, through the `Int` in `utcToLocalTime`: a clock of -3600 * 2^64
  seconds was stored as the epoch instead of refused. Such a `UTCTime` is
  outside `time`'s contract, but the encoder splits off the days with
  `Integer` arithmetic now and checks the date after. Found by the data
  hardening round (2026-10-28).
* **A non-NULL empty value could go out as NULL.** A zero length is the
  wire's NULL for a BYTE-length type and for `sql_variant`, so
  `Just mempty` there means NULL to the server. The public `putValue`
  checked only length ranges, and bulk copy's fast path for a value of the
  column's own type skipped the framing check RPC parameters get, so the
  server stored NULL, or the column's default without `KEEP_NULLS`, and
  reported success. Both run `valueProblem` now; the explicit unchecked
  writers keep their fast path.
* **Lone UTF-16 surrogates crashed decoding.** The strict decoder for
  column names, messages and ENVCHANGE strings threw from pure code
  (`THROW 50000, N'x' + NCHAR(0xD800), 1` crashed the query), and in a
  value one surrogate became two U+FFFD and garbled the text after it.
* **Ill-formed UTF-8 in a `_UTF8` column** failed the whole result.
* **`datetime` outside 1753 through 9999** decoded to a date millions of
  years away, and **malformed decimals** (a sign byte of 2, or a magnitude
  beyond the precision) decoded to a number.
* **A `sql_variant` time scale of 13 or more** threw `ErrorCall`
  ("Negative exponent"), and 8 to 12 decoded garbage. Decimal precisions
  and the variant's count of property bytes were taken on trust too.
* **Invalid `datetimeoffset` offsets and local dates decoded.** The
  decoder checked the UTC time and date but not the encoder's ±840
  minutes or the local date's range. Both apply when decoding now. A
  malformed value stays a `DecodeError`, so its raw bytes and the rows
  after it can still be read and the connection reused. Found in the review of
  2026-10-23.
* **Generic cells decoded with the default connection settings.**
  `cellDecoded` built its decoder with `defaultTdsContext` and the default
  allocation bound, where a decoder built with `fieldDecoderFor` is
  promised the connection's context and `connectValueAllocAhead` is
  promised to bound a value's buffer. Each `Cell` carries its response's
  context and bound now. Found by the first review of the parser rework
  (2026-11-01).
* **An optimization changed `prefixedValue`'s signature.** Moving the
  NBCROW check into `valueSpan` gave the exported `prefixedValue` a column
  argument and a `ByteString` environment, which broke low-level callers
  and would have read an application's environment as a bitmap.
  `prefixedValue` keeps its signature and passes the environment through
  now, and the bitmap-aware entry is `prefixedRowValue`
  (`Wire.PrefixedValueSpec`). Found during the second optimization run.
* **`columnSqlType` reported `rowversion` as `binary(8)`**, since it read
  `columnType` alone. It honours the user type 0x50 now; `typeInfoSqlType`
  still reports storage types, and no alias name is guessed from a numeric
  user type.

## Bulk copy

The data hardening round of 2026-10-27 and 2026-10-28, whose tests
compare bulk copy with the server's own conversion of the same parameter
([testing.md](testing.md)), found most of these, and the review of that
round found the rounding and the `@` rule.

* **Bulk copy silently stored `?`** for a character outside a discovered
  `varchar` column's code page: the column was remapped to
  `nvarchar(max)` for the load before the client's code-page check could
  see its collation, and the server substituted. Its length check depended
  on the session's `ANSI_WARNINGS`, and an out-of-range `Float` went to
  the server as infinity (error 7339). The column's real type is kept and
  checked on the client now. Found by a harness that loads every type by
  `bulkInsert` and by `executeMany` and compares the tables.
* **Named bulk rows aliased distinct columns after case folding**: in a
  case-sensitive catalog `a` and `A`, or `ß` and `ss`, both took the first
  value supplied. The lookup is exact first, and case-insensitive only
  when that matches one column and one value.
* **Named bulk rows dropped every leading `@`**, so `@a` and `a` were the
  same name, and a column called `@a` couldn't be addressed. The one `@`
  that `NamedParams` adds is removed now, and no more. An intermediate fix
  removed one prefix or all of them depending on the other columns' names.
* **Bulk copy read an `xml` value's bytes as UTF-16.** A raw UTF-8
  `RawParam` holding `plain text` was stored as unrelated non-ASCII text,
  and markup and declarations could vanish the same way. An `xml` column
  is sent as `varbinary(max)` now, so the server's parser reads the
  encoding. The one conversion on the client, an `xml` source into a
  character column, decoded unmarked UTF-8 and UTF-16BE as UTF-16LE; it
  takes UTF-8 and identifiable UTF-16 now, and refuses another declared
  encoding rather than guess.
* **Bulk conversion dropped a fixed source's padding.** A `RawParam`
  declared `char(n)`, `nchar(n)` or `binary(n)` was converted from its
  bytes alone, where the server pads such an RPC parameter first, so the
  two paths stored different values. Padding comes first now, before the
  fast path for the column's own type as well.
* **The remap of Unicode to `ntext` replaced lone surrogates**, decoding
  to `Text` and encoding again though both sides are UTF-16. The bytes
  pass through now.
* **Bulk conversion into `sql_variant` lost the source's declaration.**
  Decoding into `SqlValue` first turned `smallmoney` into `money`,
  `numeric` into `decimal`, `decimal(38,2)` into a smaller precision, a
  `datetime` fraction (5.006666666666) into `datetime2(7)`'s 5.0066667 and
  a fixed `char` into a variable one, and replaced lone surrogates. The
  variant carries the declared base type, precision, scale, length,
  collation and bytes now (`variantFromSource`).
* **Exact sources rounded twice on the way to `real`.** A `bigint`,
  `Decimal` or `Money` was rounded to `Double` and then to `Float`, so a
  value just beside a `Float` midpoint took the wrong neighbour: for the
  `bigint` 4611686293305294849 the server stores the bits `5E800001`, and
  the old path gave `5E800000`. Exact sources round once, straight to 24
  bits, now.
* **Floating sources lost digits while being scaled to a decimal, and
  rounded ties the other way from the server.** The scaling multiplied in
  the floating type, so `922337203685477.5 :: Double` became
  `922337203685477.4784` as `money`, `1e18` got a fractional tail at scale
  6, and `-922337203685477.625` was multiplied into money's range; the
  exact rational is scaled now. It then rounded half to even, where the
  server rounds the exact binary value half away from zero (0.125 into
  `decimal(8,2)` is 0.13 there and was 0.12 here), and bulk copy rounds as
  the server does now. The second half was found by the review of the
  round.
* **A NaN or an infinity became bit 1**, since the conversion tested only
  for nonzero, where the server refuses the same parameter (8023).
  Finiteness is checked first now.
* **`Money` into an integer type truncated** where the server rounds half
  away from zero, and **a floating `-2^63` was refused for `bigint`** by a
  symmetric check of the absolute value. It rounds now, and the lower
  bound is inclusive.
* **A `Double` negative zero into `real` lost its sign in a build without
  optimization**, and a `Float` NaN widened to a finite `Double`:
  `realToFrac` is exact only through its rewrite rules. No configuration
  builds the library at `-O0`, so this is hardening; the conversions use
  `double2Float` and `float2Double` now.

## Errors

* **A killed session on Azure SQL Database came back as a successful,
  empty result.** Azure's gateway answers the running request with one
  DONE flagged DONE_ERROR and DONE_SRVERROR and no ERROR token, and hmssql
  was lenient about those bits without a message, so an `execute` of a
  killed `UPDATE` reported success with no rows. It is `SevereError` now.
  Found by the first run against Azure (2026-09-25).
* **A DONE_SRVERROR didn't mark the connection broken.** The query threw
  `SevereError`, and the connection counted as usable until the reader
  thread saw the server close it, where an error of severity 20 is marked
  at once. `throwSevere` marks it now (`ServerFailedConnection`). Found by
  listing every way a connection becomes unusable, for `UnusableReason`.
* **A fatal ERROR could reach a pool before the server closed the
  socket.** Token processing ignored severity, the drain after a cancel
  discarded ERRORs, and the query readers kept only the first error even
  when a fatal one followed it. The shared token reader marks the
  connection broken and throws an error of severity 20 or more as soon as
  it is parsed now, a fatal error takes precedence over an earlier one,
  and both batch readers keep the current statement's text when it does.
  On MARS, packets the reader queued before the server's FIN can still be
  read, so the caller gets the fatal message. Found in the review of
  2026-10-23.
* **A login refused at severity 20 or more was a `SqlServerError`**, not
  the `LoginError` design.md promises, because the token reader throws a
  fatal ERROR as it is parsed, before the login's own reader sees the
  token. The login turns it into `LoginError` now. It came with the change
  above, and was found by reading while writing the tests of refused logins
  (2026-10-25).
* **Raw transport exceptions escaped.** With strict encryption a request
  after the server had ended the session threw `TLSException`
  (`PostHandshake Error_EOF`), resets and broken pipes threw `IOException`
  in every mode, a TLS handshake that the server ended threw
  `HandshakeFailed`, and a `connect` that couldn't reach the server threw
  a bare `IOException`. All are `ConnectionClosed` with a `CloseReason`
  now.
* **A TLS handshake that the server ended was reported as a failed
  send.** The handshake wrapper rethrew the first exception its backend
  had recorded, whenever there was one. When the server closes during the
  handshake, tls sees the end of the stream and then tries to send an
  alert, and on a stream closed whole that send fails and was the
  exception recorded. A pipe is always closed whole, so over Shared Memory
  a server that ended the handshake gave `TransportFailed` ("The pipe is
  being closed") for `ClosedByServer`, and a server's TLS alert gave it
  for the `TLSException`. The wrapper takes the kind of failure from what
  tls reports now, and uses the record only when tls says the backend
  failed.

## Memory and performance

* **Decoded values kept packets alive.** Binary values were slices of
  their packet, so a 1-byte value held 4 KiB, and `Text` and `Decimal`
  values were thunks over one. Values are copied and forced now. Copying
  large values that were already in a buffer of their own then doubled a
  256 MiB read's peak heap, and an ownership check undid that copy.
* **Over TLS with small packets, a large read left several times its
  size live** until two major collections later (a 32 MiB value at
  512-byte packets: 180 MiB), because the plaintexts of TLS records shared
  pinned blocks with crypton's finalizable objects. Small chunks are
  copied into arenas now.
* **A large output parameter was held twice.** The incremental parser
  returned the joined value as a thunk over the token's packets, so
  `callProcedure`'s result kept every packet until the value was decoded
  (1.14 to 1.45 times the value live, 6 times when the TLS layer's small
  records weren't copied), and decoding it took twice the value. The value
  is copied out of each packet as it arrives now, as a long row's are.
* **A declared value allocated 16 MiB ahead of its bytes**, the row
  reader's allocation ahead, per connection. The second adversarial review
  asked for a policy, and `connectValueAllocAhead` bounds it, 1 MiB by
  default.
* **A closed but referenced connection kept about 3.3 MB** (the TLS
  context, its buffers and the certificate store) and, after that fix,
  the unread rest of a half-read response, up to 34 KB over TLS with
  512-byte packets.
* **A plaintext connection kept 32 KiB for as long as it was
  referenced,** closed or not. The connection's context held the session's
  collation as the five bytes of the ENVCHANGE that named it, a slice of
  the buffer the login response was received into, and a plaintext login
  is read into a 32 KiB buffer of its own. The five bytes are copied now,
  and the copy forced, since a first fix left it a thunk that held the
  slice; a closed connection that is still referenced keeps 3.7 KB where
  it kept 34 KB. Found on Windows by the first run of the whole suite in
  one process, though it is not Windows's: the two tests of what a closed
  connection keeps passed alone, with the leak, because of how they
  measured ([In the test suite](#measurements-of-memory-and-allocation)).
* **A row cut across packets was walked again from its start at each
  packet.** The row walk of the time read a cut row again from a copy of
  what had arrived, up to 64 KiB, so a peer sending one byte per packet
  made a 16 KB row take 5.1 s of CPU (2 ms at 504-byte payloads, 0.5 s
  at 4; measured 2026-10-03 against the mock server). SQL Server never
  sends a short packet that isn't the last of its message, but a broken or
  hostile peer could. The reader recipes that replaced the row walk on
  2026-11-01 resume a parse where it stopped.
* **A repeated metadata list accumulated suspension work.** A recursive
  list constructor wrapped every new suspension in all the constructors
  before it, quadratic in the list's length. The repetition is tail
  recursive now, and the depth of a suspension doesn't grow with the
  list. Found while writing the reader recipes.
* **A streamed parameter's parity thunk kept the previous chunk.** The
  next pull ran before the parity of the previous chunk was evaluated, so
  that chunk stayed reachable through the thunk: a 32 MiB head was kept
  before the fix. The accumulator is strict now. **Statement metadata
  could keep parameter values**: a lazy projection of names and types,
  and a response handler that held whole `RpcRequest`s, kept values needed
  only for sending. Shape caches and response labels are evaluated apart
  from the parameter queues before a send. The heap tests of both keep
  their `Request` alive across the send, since dead frames of the caller
  can otherwise hide a kept head.
* **Decimal decoding slowed 35%** when a fix computed `10 ^ precision` for
  every value. The powers come from a table.
* **A request's body started in `binary`'s 4 KiB buffer**, a large object
  under the storage manager's lock, for bodies of a few dozen bytes;
  `network`'s `recv` allocated 32 KiB per call; and every fixed-width
  parameter ran a `runPut` of its own. Found by the first optimization
  round (September 2026), whose totals are in
  [performance-research.md](performance-research.md).
* **With GHC 9.14.1, a row decoded as `SqlRow` allocated 8n² bytes for
  its n columns.** `sqlRowDecoderFor` built its array of cell decoders as
  `smallArrayFromListN n <$> mapM ...`, which leaves the array a thunk
  beside the closure that decodes a row, and GHC 9.14.1 moved the building
  of it into that closure's loop: an array of n cells for every cell
  decoded. A row of 1024 columns cost 8.5 MB to decode and one of 4096
  columns 134.7 MB, where GHC 9.12.4 took 0.1 and 0.5 MB, and a row of 10
  columns paid 800 bytes more. The array is bound strictly now, before the
  closure, and both compilers take 0.1 and 0.4 MB. Found by the test
  matrix's first slow run on GHC 9.14.1 (`Resources.Complexity` and
  `Resources.ComplexityMock`, at 13.9 and 7.2 times the allocation for 4
  times the columns).
* **Every typed row prepared its decoder again.** `CompiledRow`'s recipe
  was a field `Int -> Parser`, prepared from the allocation bound once per
  result set. A recipe is a function, so GHC eta-expanded the preparation
  into a function of the row's input too, and each row ran it again,
  rebuilding each column's recipe after the first: 144 of about 450 bytes
  per typed `(Int32, Int64)` row in `Mock.query`, and 48 bytes per cell of
  a `SqlRow`, for a failure handler that captured the row's bitmap.
  Nothing in the source showed it; ticky over many iterations of the
  benchmark did. A preparation returns a `Prepared` now, which GHC can't
  eta-expand past, and the handler asks for the bitmap itself. Found by
  the optimization pass of 2026-11-03.
* **A typed decoder was 25 KB of an application's code per field.** Every
  part of the cell read was INLINE, so each field of each record got its
  own copy of all seven delimiter shapes, both value paths and the
  conversion: an application of 50 records (1,187 fields) got 29.9 MB of
  decoders, which took 617 s to compile, and composing a query with `<>`
  or reading a tuple type added 0.5 to 1.5 KB per use. `singleField` and
  the generic composition are out of line now, the field instances are
  not INLINE, and the API's row types and adapters are compiled once in
  the library: 111 KB and 1.6 s. Found by `scripts/code-size.sh` on
  2026-11-04 ([performance-research.md](performance-research.md), "The
  code-size run, 2026-11-04").
* **A derived record's encoder had a quadratic number of types.**
  `divideRow`'s lazy split made each field a selector walking the generic
  tree from its root, with a coercion the size of the whole representation
  type: 3,892 types for 8 fields, and compile time quadratic in a record's
  fields. A record's fields are one list of `FieldParam` constructors now.
  Found by the same run.
* **Moving pieces out of line brought back two boxes per cell.** With the
  out-of-range error out of line, GHC's last float-out made a bounded
  integer's range check a closed function of its own, which after
  worker/wrapper took the `Int64` boxed: 16 bytes per `Int32` cell. The
  check (`inBounds`) takes an `Int64#` now. And the decimal reader took
  the column's `TypeInfo`, whose precision and scale are unpacked, and
  boxed both for `readDecimal` on every value, 32 bytes; the column holds
  them boxed, built once, now. Per query in `Mock.query`, the applicative
  `(Int32, Int64)` decoder went from 3,004,528 to 2,844,673 bytes, the
  typed row from 2,046,738 to 1,886,902, and `decimal(18,4)` typed in
  `Decode` from 4,122,911 to 3,803,366. Found on 2026-11-04 by a
  hand-written applicative decoder, which allocated more than before the
  per-type decoders were merged.
* **The raw-row reader built a recipe for each cell before running it.**
  The loop behind `nextToken`, `queryCells` and raw rows had arity 2, so
  each cell allocated a thunk of its delimiter's recipe, two of the rest
  of the row and the bind's continuations, about 390 bytes per two-column
  row, and every row token allocated the closures of the other tokens'
  alternatives, 96 bytes. The loop is one-shot (`P.oneShotRecipe`) and the
  rare tokens are read out of line now. Found while looking for a
  regression on 2026-11-04.

## Security

* **Encryption negotiation** started TLS in cases MS-TDS says to refuse,
  and accepted ENCRYPT_STRICT as a PRELOGIN answer. Found by the audit.
* **The strict handshake never checked which protocol the server
  selected.** hmssql offered `tds/8.0` through ALPN, and tls refuses a
  server that selects something else but accepts one that answers with no
  ALPN extension at all. So a peer that completed a TLS handshake without
  agreeing to TDS 8.0 (an HTTPS listener or a TLS proxy on the port, with
  a certificate for the host) was taken for a SQL Server and sent the
  LOGIN7, password included, after which `connect` hung waiting for a TDS
  reply. `strictTlsHandshake` reads `getNegotiatedProtocol` after the
  handshake now and throws `ProtocolError` unless it is `tds/8.0`, before
  anything is sent inside the session. Found by reading (2026-10-13). SQL Server 2025 always
  selects the protocol, so only a mock shows it.
* **An IP address was sent as the TLS SNI**, which RFC 6066 disallows.
* **A certificate whose extended key usage excludes server
  authentication** was accepted.
* **SHA-1 signature schemes** were offered in the TLS handshake.
* **The cache of `tlsCaCertificateFiles`, by path and modification time,**
  would have kept the old certificates in use after a file was replaced
  with its modification time preserved, or the same relative path used
  from another working directory. Found by the second adversarial review;
  the cache was removed, so the files are read by every `connect`.
* **The PRELOGIN response was buffered without bound**, before any TLS or
  login.
* **`Login7`'s derived `Show` printed the password**, and the
  `EncodeError` for oversized LOGIN7 fields gave its length.

## Platform

### GHC, the runtime and the libraries

* On macOS, **a failed socket close replaced `connect`'s exception and
  leaked the descriptor.** network's `close` marks the socket closed, and
  then GHC's `closeFdWith` throws `kevent: does not exist` when the I/O
  manager holds a stale registration for the descriptor's number, giving
  up before closing it. Seen once in a full-suite run and traced to two
  GHC defects
  ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)),
  which the epoll backend on Linux has as well.
* **`close` closed the socket under a thread sending on it**, and
  **`connect` closed its socket under the reader thread it had started**,
  both of which are how the stale registration arises: 11 to 14
  violations per 3000 stress attempts before the fix, and none after.
* **GHC's `threadLabel` on an unlabelled thread** returns a null pointer
  that a major collection then follows. The full suite died of SIGSEGV in
  `evacuate` in a test that reads every thread's label before each of 3000
  connects, in nearly every run with `+RTS -A64k`. It is GHC #27618,
  fixed after 9.14.1, and the tests read labels through a wrapper of the
  primop
  ([upstream/ghc-threadlabel-null](upstream/ghc-threadlabel-null/README.md)).
* **GHC 9.12's SpecConstr compiled the row walk's loop twice**, the copy
  reached after a NULL cell taking its arguments boxed, which made NBCROW
  rows 10% slower than on 9.10. The bitmap test picked the column's kind
  instead, so that both paths reached the loop through one call site. The
  reader recipes replaced the row walk on 2026-11-01.
* **The text-array writers required `text` 2.1**, where `MArray` is an
  alias of `MutableByteArray`, and the package's bound allowed 2.0. Found
  by the second adversarial review.

### Windows

* **`close` hung, and no `timeout` could end a blocked send or
  receive.** With the threaded runtime and the default I/O manager,
  network's `recv`, `sendAll` and `accept` block in a foreign call that no
  asynchronous exception reaches, and `close` kills the reader thread,
  which is in `recv`. hmssql does its own overlapped I/O on Windows now,
  on sockets as on pipes, except under GHC's native I/O manager with a
  network that supports it
  ([design.md](design.md#platform-workarounds)).
* **A connection failed by itself now and then with "The I/O operation
  has been aborted"** (`ERROR_OPERATION_ABORTED`). The overlapped
  backend's first version started each operation on the calling Haskell
  thread, so on whichever worker thread of the runtime was running it, and
  Windows cancels a pending operation when the thread that started it
  exits. It was 5 receives in 294 handles in one run of a test group, of
  which one failed a test. In the threaded runtime operations are started
  on one long-lived bound thread now, and without `-threaded` on the
  thread that runs the scheduler, which lives as long as the runtime; the
  same measure gave none in 5,880
  ([windows-research.md](windows-research.md#a-pending-operation-dies-with-the-thread-that-started-it)).
  That version was never committed. It is recorded because whatever
  starts the operations must keep the property: the thread that starts an
  operation outlives it.
* **A reset connection was reported with errno 22.** base maps the
  Windows errors for a reset or a disconnected pipe to "invalid argument".
  The backend gives them the type and the errno that a socket on another
  platform reports (`ECONNRESET`, `ECONNABORTED` or `EPIPE`), so code that
  inspects `ioe_errno` needs no Windows case.
* **A TCP reset read "The specified network name is no longer
  available".** A socket read as a handle reports a reset with the file
  system's code (`ERROR_NETNAME_DELETED`), whose message says nothing of a
  connection. The backend reports Winsock's code for the same event, so
  the message is "An existing connection was forcibly closed by the
  remote host". Seen once TCP was enabled on the Windows test server,
  which resets a killed session's connection.
* **hmssql did not compile against network 3.3.** There a socket's
  descriptor is a `CULong`, not a `CInt`, and a closed socket is marked
  `INVALID_SOCKET`, not -1. `closeSocketWith` compared with -1 and passed
  the descriptor to `closesocket` as a `CInt`. It compares with all bits
  set in whichever type network has now, and passes a `UINT_PTR`.
* **A `timeout` around `connect` could hang for good under GHC's native
  I/O manager.** With TLS, `connect` reads the CA certificate files, and
  under that manager a thread interrupted during a file read sometimes
  never comes back, which is GHC's fault
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
  Two tests that kill connects at random points hung in every run of
  their group. The files are read under `uninterruptibleMask_` now.
* **hmssql's own operations through the native manager crashed the
  process.** A first path for that manager (2026-10-03) sent hmssql's
  socket operations through the manager's `withOverlapped`. It passed the
  suite without a server, and then `Scale.TlsConcurrency` over MARS, 64
  connections each moving 64 KiB both ways, died with an access violation
  inside the manager in most runs. network's own calls crashed the same
  way with no hmssql at all, so it is the manager's
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md));
  that path was removed and never committed. TCP under the native manager
  now goes through network's calls and shares the exposure, as every user
  of network does, and so do the pipes on a GHC without the manager's fix
  ([design.md](design.md#platform-workarounds)).
* **Four of the examples failed to connect out of the box.**
  `hmssql-example-setup`, `hmssql-example-crud`, `hmssql-example-bulk-copy`
  and `hmssql-example-managed-identity` were linked without `-threaded`,
  which hmssql then required on Windows, so `connect` refused with the
  error that says so. Every executable links `-threaded` now. The setup
  also ignored its arguments, so `stack run export` in a project with the
  shop-db package ran the setup instead, and with the threaded runtime it
  would have reset the example tables. It refuses arguments now.
* **Every MARS connection over a pipe without encryption was dropped at
  its first request.** Under `EncryptOff` and `EncryptNotSup`, over Shared
  Memory and Named Pipes, the first request after the SYN failed with
  `ConnectionClosedBy (TransportFailed ...)`, "No process is on the other
  end of the pipe": 23 tests over each pipe, mostly `Mars.Negotiation`
  and `Mars.FlowControl`. On 2026-11-01 the SMP header had become a
  `ByteString` of its own beside the TDS packet, passed to
  `backendSendMany` as a second chunk. The pipe backend writes each chunk
  as one write, since SQL Server reads a pipe a write at a time, so the
  server got a 16-byte write that was part of an SMP packet and dropped
  the connection
  ([protocol-notes.md](protocol-notes.md#shared-memory-and-named-pipes)).
  Over TLS the two were joined into one record, and a socket doesn't care
  about write boundaries, which is why `EncryptOn` and TCP passed; the
  pipe measurements of 2026-10-03, which found all four modes working
  with MARS, came before the change. `backendSendMany` takes each write as
  a list of its pieces now: the pipe backend joins a write's pieces into
  one write, and the socket backend still sends them all in one vectored
  send ([design.md](design.md#the-backend-what-the-bytes-travel-on)).
  `Mars.SmpWire` checks that each write the connection hands its backend
  is whole packets, with all of their pieces.

## Documentation

* **limitations.md said an interrupted bulk load is cancelled with an
  Attention**, where the code breaks the connection. That held for a row
  stream that throws, not for an asynchronous exception: the producer runs
  inside the send, which rethrows an asynchronous exception and marks the
  connection broken, wherever the interruption lands (a write, a wait for
  the MARS window, or the row stream's own wait for a row). Breaking is the
  decided design, so limitations.md, design.md and the `bulkInsertSWith`
  Haddock were corrected, not the code. Under MARS an interrupted load
  takes every open stream with it. Found by the review of the MARS commit,
  which also found two Haddocks wrong under MARS: `queryFold`'s said a
  request made in the step abandons the response, where on a MARS
  connection it takes a session of its own and the fold goes on, and
  `batchQueryS`'s said its stream must be read before the next request.
* **The public documents said Azure SQL Database requires TDS 8.0**, and
  the examples defaulted `MSSQL_ENCRYPT` to `strict` even in their
  localhost recipes, which `MSSQL_TRUST_SERVER_CERT=1` didn't help against
  a server without TDS 8.0. The README, the connection Haddock and the
  guide contradicted the TDS 7.4 access-token tests and the Proxy and
  Redirect benchmarks in [azure-sql.md](azure-sql.md). They distinguish
  the TDS 8.0 configurations from the default TDS 7.4 connection now, which
  works on Azure too, and the examples default to `on`.
* **The Haddock review of 2026-11-04 found four defects.** `readDecimal`'s
  Haddock, the paragraph on the decimal wire layout, sat above the private
  `decimalLengthError`, so Haddock showed it nowhere. `readTime` and
  `readDateTimeOffset` carried two summaries each, one left from a
  rewrite, and `readGuid`'s and `readMoney`'s led with the wire detail
  instead of the type. `connectAccessToken`'s repeated a paragraph.
  `Hmssql.Tds.Utf16.decodeUtf16LE` linked `Hmssql.Tds.Primitives` as a
  module followed by an identifier, which Haddock renders as text. Each
  was fixed, and the root module's "speaks the protocol" became
  "implements".
* **Haddock links of the form `'name''s` didn't link.** Fourteen links
  written as an identifier followed by a possessive rendered as text,
  since Haddock needs the identifier quoted on its own. The possessives
  were rephrased. Found on 2026-11-04, in the same review.
* **A doubled backslash in a bird-track code block rendered doubled.** The
  examples of `withQueryS` and of the MARS section of `Hmssql.Connection`
  wrote their lambdas as `\\parents`, as a `@...@` span would need, but
  Haddock interprets nothing inside a `>` block, so the page showed two
  backslashes. A bird-track block takes the code as it is. Found by the
  rewrite of the `Hmssql` page on 2026-11-05.
* **The package's ChangeLog linked documents it doesn't ship.** Its
  links were relative to the repository root (`docs/guide/...`,
  `docs/dev/...`), which broke them on GitHub once the ChangeLog moved to
  `hmssql/`, and on Hackage, where no document under `docs/` is shipped.
  They link the guide site and GitHub now. In the same pass before release,
  the package's description pointed at a README the package doesn't
  carry, its copyright field still named Takamasa Mitsuji after LICENSE
  had dropped the name, its dependencies had no upper bounds, and the `dev`
  flag put `-j` in the published `.cabal` file. Found by a release check on
  2026-11-09.

## In the test suite

Bugs of the tests themselves that hid or invented library behaviour,
kept so that their shapes are recognised again. [testing.md](testing.md)
has the rules they led to.

### Timing assumptions

A test that sleeps for a fixed time, or gives an operation a fixed time to
reach a point, breaks under load. Each of these now waits for the event
it needs, usually for the server to show it in a DMV.

* **Mock tests took turns by sleeping**: an acknowledgement withheld for
  "a second" of receive steps while the client slept 1.2 s. Under load
  they ran past each other; they signal through `MVar`s now. Closing right
  after the acknowledgement then showed that the mock's reader died
  silently on a TCP reset, so its script waited 30 s; a reset is a close
  to the mock now.
* **A coverage assertion waited by spinning** (`Mars.SmpSessions`, "a SYN
  whose send fails"). The mock drops the connection as the first request
  arrives, and the test spun 10 µs longer on each of 100 tries before
  sending the second, expecting some SYN's send to fail. A write after the
  peer's shutdown succeeds, so the send fails only once the client's
  reader has seen the end (`connEnded`), and under `+RTS -A64k` that took
  longer than the 990 µs the spin reached: one run in five failed on
  2026-09-30. Each try waits until the reader has seen the end now.
* **`Concurrency.Boundary` waited 10 ms for the reader to take the
  packets** before interrupting it, and at the last boundary expected all
  but two of the rows read. Under load it had read 18 of 28 (4 over SMP).
  It waits until the reader has recorded every row the packets complete.
* **`Mars.AttentionWindow` waited 200 ms for its scan to reach a lock**,
  which a loaded server overran in four rounds of nine. It waits for the
  server to show the scan waiting.
* **`Shapes.BatchQuery` and `Shapes.ExecuteMany` interrupted three
  statements after 300 ms** and expected the first to have run and the
  second, a `WAITFOR`, to be cancelled. In a matrix run the first had not
  run yet, and on Azure's Basic tier the batch had ended. They interrupt
  once the server shows the `WAITFOR` (`awaitWaitfor`).
* **`Shapes.Errors` made a deadlock by waiting a second** between each
  connection's two updates. In a matrix run one side had done all of it
  before the other connected. Each side tells the other when it holds its
  row now.
* **`Mars.Cancel` sent its Attention on a timer, and SQL Server 2025
  ignores an Attention that comes before the statement is under way.** "A
  timeout around withQueryS over a statement the server can't stop soon"
  interrupted a lock-waiting `SELECT` after 300 ms, and three runs on SQL
  Server 2025 in the matrix of 2026-10-15 hung for their whole 120 s in
  `cancelActiveStatement`, until the test's own lock holder was released.
  It was taken for the server not reading the Attention under load, then
  for the `arithabort` session setup, then for hmssql's SMP send window.
  The client's trace showed the Attention sent within the window and
  taken in, captures put it 7 to 44 ms before the lock wait began on a
  server that took 300 ms to start the statement, and a probe found SQL
  Server 2025 alone of the four versions ignoring an Attention sent right
  behind its request, 105 times in 120
  ([protocol-notes.md](protocol-notes.md#mars-and-smp)). The test
  interrupts once the server shows the lock wait, which the probe never
  saw ignored (0 of 240), and states the consequence of an ignored one
  rather than hang: if the cancel hasn't returned in 10 s, the holder
  rolls back, and the cancel must then return with the statement over.
* **Interrupted bulk loads were interrupted while the load still read.**
  `Bulk.Copy` and `MarsTx.BulkCopy` give a load of slow rows a `timeout`
  and expect the connection broken, as an interrupted send leaves it. A
  timeout counted from the start (300 ms) expired, in a busy matrix run
  and on Azure's Basic tier, while the load still waited for the answer
  to its `INSERT BULK`, a read, which an interruption cancels without
  breaking anything. Counted from the load's first row (100 ms) it still
  failed in two of about eight full live runs on 2026-11-04, because
  `bulkInsertSWith` takes the first row before the `INSERT BULK`
  statement, to decide the wire layout. The timeout counts from the second
  row now, which is taken inside the send. The cause of the second was
  read from the code and from a row counter in one instrumented failure;
  it didn't reproduce alone or under `yes` at twice the core count.
* **A 200 ms `timeout` had to land during a transaction's read of
  2,000,000 rows**, which took 1.1 s before rows were read a packet at a
  time and 0.19 s after, so the timeout could land on the COMMIT. It reads
  100,000,000 rows now.
* **`Concurrency.Cancel` expected a 100 ms `timeout` to interrupt the read
  of a million rows**, which takes 170 to 230 ms over a plaintext
  connection (260 to 310 ms under strict encryption; local SQL Server
  2025, GHC 9.12.4). A timeout delivered 100 ms late in a matrix run found
  the whole result read. `Scale.TlsKillMidResult` assumed the same of a
  `KILL` and 300,000 rows of 200 characters. Both read a hundred million
  rows now, which can't arrive first.
* **`MarsTx.Snapshot` required two writers to commit faster than its
  reader read.** It counted the commits made while 30 snapshot
  transactions ran and wanted more than 30. A commit waits for a log
  flush, which took 5 ms on the Linux machine
  ([protocol-notes.md](protocol-notes.md#platform-and-tooling)), so the
  writers made 14 to 16 commits and the test failed every time there.
  Each read now waits, with its parent rows in hand and its child streams
  not yet open, for a change made and committed entirely within the wait.
* **A heavy test timed out beside a stray process** (`Mars.Negotiation`,
  "packet size 512 asked for"). It sent a 1 MB parameter twice at 512-byte
  packets, about 2,100 SMP packets and 525 waits for the server's window
  of 4 each time, and hit its 60 s limit in a whole-suite run in which a
  test process left over in an agent's worktree had been looping commits
  against the server for hours. No wait in the SMP paths could last
  forever, and 200 runs of it, eight at a time beside a whole-suite run,
  took at most 6 s. The parameter is 200,000 bytes below 4096-byte packets
  now.
* **The MARS tests' 60 s bound was on speed, not on hangs.** Several
  `Mars.FlowControl` tests, with `Mars.Negotiation` at 512-byte packets and
  plain tests such as `LargeValue` and `Model.Connection`, timed out
  together in about 5 of 312 matrix runs, all at 512-byte packets, on all
  four servers. Traced, every stuck test was moving slowly while the server
  crawled: a new connection's `SELECT 1` took up to 90 s
  ([protocol-notes.md](protocol-notes.md#the-server-under-load)). The MARS
  tests' bound (`withinTraced`, `withinMoving`) is on time without progress
  on the connection now, with ten times the limit as a backstop, and a
  test that rides out a slow server says so on stderr.
* **Two tests timed a connect with the wall clock,** which on Windows
  advances in ticks of up to 16 ms. Under GHC's native I/O manager a
  connect to the mock measured 0 s every time, so `Resources.ConnectTimeout`
  sized its sweep from that, every timeout fired before any connect could
  finish, and the test covered nothing. Durations come from the monotonic
  clock now.
* **A test looked for a scope's response after the scope had ended.**
  `Mars.WithQueryS` "an interruption of the exit's wait for the
  Attention's acknowledgement" waits for the scope's response and then
  interrupts the wait, which is one round trip. A test thread descheduled
  that long found no response open (3 runs of 312 in the matrix of
  2026-10-15). It retries there, as it already did for an interruption
  landing after the wait.
* **A count of reader threads taken just after a failed `connect`**
  (`Mars.SmpNegotiation`) saw a stopped reader still alive, once in the
  overnight matrix. `killThread` returns once the exception is raised, and
  the thread ends only when it next runs, and the library promises the
  first, not the second
  ([design.md](design.md#connection-lifecycle)). The test waits up to 10
  s for its readers to end.

### What the server does: versions, Azure and settings

* **Thirty-two tests assumed SQL Server 2019, and two assumed 2022.**
  Against SQL Server 2017 in the matrix every test of a UTF-8 collation
  failed with error 448, and so did the two differential properties, whose
  random tables can draw one, and the negotiation test expected the UTF-8
  feature extension acknowledged. Against 2019, `Session.ServerFeatures`
  used `STRING_SPLIT`'s ordinal argument and `GENERATE_SERIES` (errors 8144
  and 208). With `HMSSQL_TEST_SQL_VERSION` those tests are pending
  (`skipBeforeSql2019`, `skipBeforeSql2022`), the generators take their
  collations from `collationsFor`, and the negotiation test expects
  `tdsUtf8Support` to be `False` on 2017.
* **The model had a failed stream's rollback happen whether or not its
  batch ran.** In a `SET XACT_ABORT ON` transaction, a stream opened on a
  table that doesn't exist rolls the transaction back (208). The next
  request abandons the stream with an Attention, which can reach the
  server before the batch has run, and then the transaction stays open.
  SQL Server 2025 nearly always runs the batch first and SQL Server 2022
  nearly never does
  ([protocol-notes.md](protocol-notes.md#all_headers-and-transactions)),
  so `Model.Connection` failed on 2022 in four of the first sixteen matrix
  runs. The model leaves that state out now, as it already did for a
  stream left open by the Attention's timing.
* **`Mars.Sessions` set the isolation level beside a stream whose request
  could end at any moment.** A request that ends puts back the settings it
  began with ([protocol-notes.md](protocol-notes.md#mars-and-smp)), and
  with 32767-byte packets the 100,000-row stream fit in the window, so its
  request ended on the server once between the `SET` and the check. The
  streams are too long for the window now. Two other `Mars.Sessions` tests
  had relied on a 1000-row stream always having ended before their `SET`
  or `USE` (next section).
* **Ten MARS tests assumed that a READ COMMITTED reader takes locks**
  (`Mars.Scheduling` A20 and A21, two in `Mars.Cancel` and five in
  `Mars.AttentionWindow`). Azure SQL Database has `READ_COMMITTED_SNAPSHOT`
  on, where a scan neither waits behind a writer nor holds a shared lock
  while parked; a local database with RCSI fails the same ten. Two of them
  made the first Azure run since MARS (2026-10-01) look crashed: threads
  they had forked raised an uncaught `ConnectionClosed` after the test had
  failed and closed its connection, and the report stood still. The scans
  read `WITH (READCOMMITTEDLOCK)` now, the A20 holder is released and
  waited for however the test ends, and both threads catch everything.
* **Five tests assumed what Azure SQL Database doesn't do** (2026-10-01).
  `MarsTx.Reset` required the acknowledgement of a reset whose request was
  cancelled at once, which Azure left out once in 100; hmssql asks for the
  reset again then, by design, and the test accepts either.
  `Protocol.Login`'s raw login didn't follow the gateway's redirect; it
  does now. `Transaction.TmBegin`'s READ COMMITTED test expected a lock
  wait where the companion database has RCSI; it reads the setting.
  `Mars.Scheduling`'s in-transaction write had a 1.9 s bound that only
  measured the disk (5 s on S3, 22 s beside a whole-suite run); its success
  is the evidence, since a blocked write ends in 1222.
* **Two `Mars.Cancel` tests timed out on Azure SQL Database, which looked
  like a hang in cancelling a response right behind its request.** Each
  cancels a scan five times and checks after each cancel that a writer on
  another connection gets through at `LOCK_TIMEOUT 0`. Nothing hung: the
  time went to the writer, which updated all 30,000 rows of the table,
  under the whole suite with the database at 100% of its log rate, where
  such a write waited in `LOG_RATE_GOVERNOR` for 1.6 to 42 s. The tests
  whose scan holds a shared lock on the table write one row now, whose IX
  lock is refused the same way. In one of those runs `MarsTx.Reset` A38
  failed with 1222 on a read of `sys.all_columns` under the `LOCK_TIMEOUT
  1234` it sets as state for the reset to clear, since other tests' DDL
  held the catalog's metadata locks longer; it sets two minutes now.
* **Two MARS tests took Azure's kill of an early Attention for a
  failure** (`Mars.Random` seed 2, and `MarsTx.Hygiene`'s rollback with
  busy sessions). Loaded, Azure SQL Database sometimes ends a MARS
  connection when it reads a request together with its Attention
  ([upstream/azure-sql-early-attention](upstream/azure-sql-early-attention/README.md)),
  and it took a packet trace of both sides to tell that from a protocol
  violation by the client. On Azure the tests' cancels go through
  `Mars.Harness.cancelling`, which ends the test with a note once the
  connection is shown to be broken.
* **A MARS test's bound assumed SQL Server's prompt Attention.**
  `Mars.WithQueryS` "interrupted just after its request was sent" cancels
  a 1,000,000-row `SELECT` right behind its request 100 times within
  120 s. Azure SQL Database acts on such an Attention only once the
  statement has sent its result, up to 4.3 s a round on S3 under the whole
  suite. The test allows 600 s on Azure
  ([azure-sql.md](azure-sql.md#s3-again-with-the-matrixs-fixes)).
* **A database-name test assumed Azure accepts a supplementary
  character.** SQL Server 2025 round-trips a name with U+1D11E; Azure SQL
  Database refuses the `CREATE DATABASE` with error 1055. The test expects
  the refusal on Azure.
* **Scratch databases were never dropped on Azure SQL Database.** The drop
  was guarded by `IF DB_ID(@p1) IS NOT NULL`, and `DB_ID` of another
  database is NULL in Azure's logical `master`, so the batch did nothing
  and no test failed. Existence is asked of `sys.databases` now, and
  `dropDatabase` fails if a drop doesn't drop.
* **A test assumed a 40 MB send blocks** (`Resources.CloseDuringSend`),
  and the container host's loopback buffers took the whole batch. The
  test clamps the socket buffers to 64 KB and waits until the sender holds
  the send lock and is blocked.

### Configuration assumptions

* **Sixteen places in the MARS tests assumed the default window of 64
  packets**, which `HMSSQL_TEST_MARS_WINDOW=4` with 512-byte packets
  showed: waits for a session to hold 64 (or 60) packets, waits for a
  response of 100 wide rows to arrive whole, and two `Mars.Sessions` tests
  whose 1000-row stream had always ended on the server before their `SET`
  or `USE`. They ask the connection for its window now (`connWindow`),
  take a window that fits (`withMarsConnArriving`), or use streams of one
  packet.
* **Two MARS tests assumed TCP.** They compared the rows of
  `sys.dm_exec_connections` with a list that named the physical
  connection's transport `TCP`, and ordered the rows by that name. Over
  Shared Memory the server reports `Shared memory`, and `Named pipe` would
  have sorted before the `Session` rows. They expect the run's transport
  (`testNetTransport`), with the physical connection's row last.
* **`Resources.CutHandshake` hung with the mock on a pipe.** Its
  `EncryptOn` cases started the mock with `withMockServer`, which follows
  `HMSSQL_TEST_MOCK_TRANSPORT`, and put a TCP proxy in front of the mock's
  `connectPort`, which for a mock on a pipe is the default 1433. The proxy
  went to the local SQL Server, and on Windows a proxy thread stayed in
  one of network's blocking calls, where `killThread` waits. They start
  the mock with `withTcpMockServer` now, as a test that needs a port must.
  Found on 2026-11-07, at the first run of the mock suite over a pipe
  under GHC's native I/O manager.
* **The TLS hostname leak test inherited plaintext mode.**
  `Resources.Leaks` used the default connection even under
  `HMSSQL_TEST_ENCRYPTION=notsup`, so it could connect without checking
  any certificate. It asks for `EncryptOn` and validation explicitly now.

### Interference between tests and between runs

* **A `KILL` named a session by its id alone.** The model's `KILL` killed
  whoever had the session id it had recorded, once its own connection had
  been replaced, and another test's session died. `Connection.Disconnect`
  killed from a forked thread 300 ms into a 5 s `WAITFOR` on a new
  connection; on a saturated Azure S3 database that connection took
  longer than the `WAITFOR`, the victim closed, and its id went to the
  killer's own session (error 6104, uncaught in the forked thread). Every
  test kills through `killSession` now, which checks
  `sys.dm_exec_connections.connection_id`, unique to the physical
  connection; a first guard on `connect_time` failed within its 3 ms tick
  (2026-10-02). The killer connects before the request now, and kills once
  the server shows the request in its `WAITFOR`, and the forked killer
  hands its result back to the test.
* **The `Catalog` tests lost deadlocks to other tests' DDL** once they
  moved from scratch databases to scratch schemas in the shared database:
  on Azure SQL Database under the whole suite, `readTable`'s read of the
  catalog views was chosen as a deadlock victim (1205), and in the next run
  the drop of a scratch schema lost one too. `retryDeadlock` retries such
  an action up to five times, and the library leaves retrying to the
  caller.
* **Two tests deadlocked through the client**: a `CREATE TRIGGER` inside a
  transaction on a table another test held an uncommitted insert on,
  whose observer queued behind the trigger. Each has a table of its own.
* **A test's unreachable port was another test's server.**
  `Protocol.EnvChange` redirected a login to a port that had been
  listening and no longer was, and `Connection.ConnectFailure` connected
  to a port it had bound and closed. A closed port is free, and a mock
  server started beside it was given it, so the client that was to be
  refused logged in there. The port is bound, without listening, for as
  long as the test runs now (`withRefusingPort`), which refuses a connect
  on Linux. On macOS such a socket drops the SYN instead (ETIMEDOUT after
  about 8 s, 2026-10-25), so there it returns a port bound and closed,
  which macOS refuses at once and, handing out ephemeral ports at random,
  is unlikely to give to a mock beside it.
* **`uniqueName` was unique per process id, and every matrix container's
  test process is pid 1.** Two runs against one server made the same
  login name in the same millisecond, and one failed with error 15025.
  The name carries 32 random bits per process now.

### Races inside a test

* **An interruption count was read before the interrupter had counted**,
  since it counts after `throwTo` returns and may be descheduled in
  between.
* **The shared-connection interruption test missed a break in the last
  operations.** In `Concurrency.Interrupt`, a break of the connection by
  an interruption reaches the next operation, which sets the test's
  `stop`. When the break came in every worker's last operations, no next
  operation came, and the round's final check threw the `ConnectionBroken`
  uncaught (8 runs of 312 in the matrix of 2026-10-15). The final check
  accepts a break by an interruption whether or not a worker saw it.
* **A hook counted a finalizer's socket close** as a violation of "no
  reader alive at close": the finalizer of an earlier attempt's connection
  closes its socket again, on its own thread. Only closes on the
  connecting thread count.

### Leaks and process-wide state

A test that leaves a thread, a timer or a socket behind can fail a later
test that measures the whole process.

* **`Concurrency.CancelModel`'s window poller swallowed the `killThread`
  meant to stop it, and polled for the rest of the process.** Its raise of
  a session's window was wrapped in `try @SomeException`, so a kill that
  landed there was caught, and the poller went on polling the dead mock,
  about 3 MB of allocation a second each. `Resources.StalledServer`, which
  measures the whole process's allocation over 2 s, failed all nine tests
  in most runs of the matrix of 2026-10-25, with 6.3 MB in 2 s when one
  poller had leaked and 14.9 MB when three had. The poller rethrows
  `SomeAsyncException` now, and the case fails if it is still running
  10 s after the kill. An earlier change had put the failures down to the
  finalizers of earlier tests' sockets and added a wait, which wasn't the
  cause and is gone.
* **`Concurrency.CancelModel` closed a socket under its own reader, and
  hung later connections in the process.** Its plain model server hung up
  with `resetConnection` from a worker thread while the handler's thread
  was reading the same socket. Before GHC 9.14 a wait that starts on a
  just-closed descriptor leaves a stale registration in the I/O manager,
  and closing the number's next owner then fails with `epollControl: does
  not exist` and leaves a bucket's lock taken, so every later wait on a
  descriptor with the same number mod 32 blocks forever
  ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)).
  Under load it showed as hangs in unrelated cases, and in four runs of the
  matrix of 2026-10-25 (GHC 9.6.6) as the live suite hanging for hours at
  `Connection.Lifecycle` "many connections", the test that opens the most
  sockets. Reproduced on Linux against a SQL Server 2019 container, three
  suites at once beside `yes`, with the stuck descriptors in no epoll set
  and sharing their number mod 32. The worker sets SO_LINGER 0 and shuts
  the receiving side down now, which ends the handler's read, and the
  handler's own close sends the reset; `CancelModel` at 20 times its cases
  then hung none of 6 runs, against 5 of 9 before. The many-connections
  test runs its body under a bound of 300 s and fails with what is still
  open, rather than wait for a cleanup through the same bucket.
* **Two tests could not end once a request failed or went unanswered**,
  found by reading the suite for what a server that stops answering would
  do to it (2026-10-15). `RobustnessSpec`'s consumer had its `queryS`
  outside its `try`, and the test polled for its rows with no limit; the
  consumer catches everything now, and the wait ends after 60 s.
  `Concurrency.Attention` stopped its spinning watcher only after a `try`
  that caught the test's own interruption, so any other exception left it
  spinning on a core; it is stopped on every exit now.
* **The soak test's apparent thread leak** (1.7 threads per pool
  replacement, with no plateau) was the test's own lazy
  `length <$> listThreads` thunk keeping every sampled `ThreadId` alive.
  It was pended as a library bug for a while.
* **The helpers' timeouts stalled every timer on Windows.** On Windows,
  with the default I/O manager, a `timeout` whose action returns leaves
  its delay with GHC's timer thread until the limit passes, and when
  thousands of them expire that thread fires nothing for a second or more
  ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)).
  The model's runner waited for each operation under a 15 s `timeout`,
  about 9,700 times a run, and the mock SMP server sent each packet under
  one of 20 s. `MarsTx.ResetGate`'s 200 ms `timeout`, which must fire
  while the server waits a second, then failed in 9 whole-suite runs of
  12 against SQL Server 2019, and looked like a gate that didn't hold.
  Separately, the sweeps of `Resources.CutHandshake` left thousands of 10
  and 20 s guards pending, whose expiry `Resources.StalledServer` measured
  as 3 to 30 MB allocated in its idle window when it ran next. The
  helpers, the watchdogs and the guards use `timeoutInSlices` now, and the
  runs pass.
* **Without `-threaded`, `Resources.ConnectTimeout` counted 514 and then
  854 handles too many after its sweep**, with every handle of the backend
  closed. There each pending delay is a worker thread of the I/O manager,
  and the suite's watchdogs had left 5,847 of them; the handle count rose
  as the sweep's lookups and connects reached workers for the first time.
  The shared watchdogs (`Concurrency.Harness.within`,
  `Protocol.MockTokens.within` and those of the `Mutation` modules) use
  `timeoutInSlices` now, the pool stays near 2,150 workers, and the sweep
  moved the count by 22
  ([windows-research.md](windows-research.md#the-non-threaded-runtime)).
  Counting the process's threads off the handle count was tried first and
  changed nothing, since the pool did not grow during the sweep.
* **On Windows, a test's broken close closed the next test's socket
  too.** `Resources.CloseFailure` makes a close fail the way `closeFdWith`
  fails under kqueue, by turning the socket into a `Handle` with
  `socketToHandle` and then letting go of the handle without closing the
  descriptor (`detachDescriptor`). On Windows `detachDescriptor` only
  threw, and the tests took that for the failure they wanted, so the
  handle stayed open; `closeSocketWith` closed the descriptor, as it
  should, and the handle's finalizer closed the same number again at the
  next major collection. Windows soon gives a closed handle's number to
  another, often a socket of the next test, and the module's last test,
  which collects garbage, failed in whichever way that socket's owner did:
  56 runs of 200 alone, and 7 of about 37 whole suites (GHC 9.12.4,
  network 3.2.9.0, Windows 10, the default I/O manager). In a build that
  logged the numbers, each failure whose log could be read had a socket on
  a number a broken close had used, and no passing run did. It had been
  put down, without a reproduction, to network's own finalizer running
  first. `detachDescriptor` marks both sides of the handle closed on
  Windows now and leaves the device alone, as `handleToFd` does, and the
  module passed 800 runs of 800, 300 of 300 beside 64 busy processes, and
  200 of 200 under the native I/O manager. A test checks that the broken
  close leaves no open handle.
* **The first run without `-threaded` hung for four hours, on 2026-11-06,
  in `Resources.Helpers` "threadLabelOf".** The test's collector thread
  looped on `performMajorGC` and `tryReadMVar`, which allocate nothing, so
  on the single capability of the non-threaded runtime nothing ever
  preempted it. The loop yields now. A loop that shares the capability
  must allocate or yield.

### Measurements of memory and allocation

* **The last test of a process to connect measured that a closed
  connection keeps nothing,** with a leak of 34 KB a connection or
  without. `Resources.ClosedConnection` and `Resources.ClosedMidResponse`
  compared the live heap before 50 connections with the live heap after.
  hmssql caches the system certificate store in a CAF, and the collector
  frees a CAF once no code still to run refers to it, so in the last test
  to connect the store (2.6 MB) was alive at the first reading and dead
  at the second, which took 50 KB off each connection. Each group alone
  passed with the leak, and in a run of both the first group's failed.
  The tests read the heap with the connections referenced and again with
  them dropped (`keptAliveByEach`), then connect once more, so that the
  cache is referred to at both readings. With the leak put back each
  group fails at 34.0 KB; without it a closed connection keeps 5.4 to 5.7
  KB with TLS and 2.5 to 3.3 KB without (GHC 9.12.4 on Linux; over MARS 8
  to 10 KB and 3.5 to 4.2 KB).
* **`LargeValue` held the allocation for 4 times the bytes under 6 times
  the allocation**, and what a reader allocates per byte depends on how the
  packets fall across the chunks received: 2.35 bytes for most reads over
  a plaintext connection with 32767-byte packets, as little as 1.5 for
  some, and 1.4 with TLS. A lucky read of 16 MiB beside an ordinary one of
  64 MiB showed 6.1 times in the matrix. The bound is 8 times now, and a
  quadratic buffer shows 16.
* **`SqlRow` benchmarks counted rows without forcing them**, so work left
  in a lazy row didn't show. They use `nfIO` now, as the typed ones do.

### The model and the properties

* **The model's runner caught its own timeout.** `Concurrency.CancelModel`'s
  `guarded` ran `timeout 10_000_000 (try act)`, so the timeout's exception
  was caught by the `try` and rethrown outside, and a step that hung for
  10 s failed as an uncaught `<<timeout>>` with no case printed. The `try`
  is outside the `timeout` now, and a hung case says which of its recorded
  phases it was in.
* **`Concurrency.CancelModel` expected an interrupted read that left its
  response readable to have lost nothing.** Under load a read under
  `timeout` had its batch, and the timeout fired as `readStep` returned it,
  so the batch was committed as consumed and lost, which is the contract
  design.md states for a batch on its way to a `queryS` consumer. The
  model assumed a read that can't be interrupted after it returns, and
  allowed no gap. It allows each such read
  to skip one batch now, and design.md names `readStep` and `timeout`
  beside `queryS`.
* **The model drew `SET LOCK_TIMEOUT 0` and knows no locks.** In a
  whole-suite run over MARS, a `DELETE` from the session's own empty
  `#temp` table inside a transaction got error 1222 where the model
  expected a count of 0. At 0 any lock wait at all is 1222
  ([protocol-notes.md](protocol-notes.md#session-state-and-reset)). The
  generator draws -1, 1000 and 5000 now.
* **The model predicted the INFO messages of the operation after an
  interrupted, refused request.** Beside a MARS stream whose statement
  rolled the transaction back under `XACT_ABORT`, every request is refused
  with error 3971 and INFO 3926. A `Cut` whose `timeout` fired after its
  request went out left that response for the next request to drain, which
  ran the INFO callback a second time. A probe of 200 such cuts left one
  for the next request 17 times. The model leaves the INFO messages of the
  next draining operation unpredicted now (`mDrainsNext`).
* **The model forgot that a `withTransaction` might never have begun once
  the session was dead.** A `Cut` landed in the drain of an interrupted
  `WAITFOR` and broke the connection, so the next `TxBegin` threw
  `ConnectionBroken` and the runner had no `withTransaction`, while the
  model pushed a frame. One sequence in 5,000. A frame records now that it
  was entered while the connection may have been broken (`fUnsure`).
* **A property's coverage labels drew too rarely** (the `smalldatetime`
  and `datetimeoffset` ranges) on one seed in a few hundred. The
  generators draw the in-range case more often.
* **A variant output test claimed to cover every byte value**, but
  `COLLATE` after a cast from binary to `varchar` changed some of the 256
  bytes. The sources are assigned as binary literals to a column of the
  intended collation now, and the bytes are checked before the conversion
  is.
* **A mock test of a bulk load's session couldn't tell the reservation
  from the choice of the lowest idle session**: session 0 stayed busy
  throughout, so a mutant without `withReservedSession` passed it. A load
  during which a lower session is freed pins it now (`Mars.SmpSessions`).
  `withQueryS` on a connection without MARS had no test either, and has
  two now. Both found by the review of the MARS commit.

### The harness, its reports and the scripts

* **A property that failed once, for a reason outside its case, shrank
  for hours and grew without bound.** Hedgehog's shrink limit counts the
  shrinks it accepts, not the smaller cases it tries. A case that failed
  because the server refused a request while out of memory, or because
  another test killed the session, has smaller cases that all pass, and
  hedgehog tries every one before it reports, keeping each in the
  generator's tree. A probe without a server, failing a random table of
  `Differential.Schema` once (GHC 9.12.4), tried 46,000 smaller cases and
  peaked at 1.5 GB, and in two other runs passed 3 GB after 21,000 and
  11 GB after 142,000, still going. Against the server each case is a
  table created and filled. Every property that talks to the server runs
  through `LiveProperty.liveHedgehog` now, which stops shrinking once 1000
  smaller cases in a row have passed and fails with a note; the same
  probes then ended within 1050 cases at 11 to 23 MB. That this is what
  grew a matrix process to 16 GB on 2026-10-05 is likely, not shown
  ([backlog.md](backlog.md)).
* **A matrix run hung for eight hours at full CPU in `Protocol.Fuzz`.** A
  case of 16 KB in packets of one byte took over 5 s under load, because
  of the row walk's quadratic re-walk (under
  [Memory and performance](#memory-and-performance)), its 5 s timeout
  counted it as hung, and hedgehog shrank it, up to a thousand times, each
  smaller case as slow; a limit of 50 shrinks didn't help, for the reason
  above. The fuzz prints a hung case's packets at once now and runs
  nothing more for that property. Stacks sampled with gdb (2026-10-05)
  found the quadratic walk at work, not a loop.
* **The first full test matrix (2026-10-02) ran 433 of the suite's
  examples.** Every run stopped at the first hedgehog property to print a
  coverage table, whose bars (U+2588) can't be written to stdout in a
  container with no locale, and hspec printed its summary of what had
  run, so nothing looked short. Sixteen of the 168 runs printed no summary,
  since a `Model` property's failure report (U+250F) ended the process,
  losing the failure too. The spec hook sets stdout and stderr to UTF-8
  now.
* **A failing property's report was lost where there is no locale.**
  Hedgehog reads the property's source file in the locale's encoding to
  draw its report, and for a module with a character beyond ASCII the
  report was an `IOException` from `hGetContents`. It hid two failures of
  `Protocol.Fuzz`. The suite sets the default encoding to UTF-8 at its
  start now.
* **A diagnostic hung the run it diagnosed.** `describeSession` looked up
  the names of the objects a session held locks on, one of them a
  temporary table a `Model` session had dropped in its transaction, whose
  schema-modification lock held the lookup, and the transaction was the
  test's, waiting for the diagnostic. It waits a second for a lock now,
  names no tempdb object, and gives up after 10 s.
* **The setup's failure against a server without strict encryption said
  nothing of the cause.** The suite's first connection is strict, and SQL
  Server 2019 closes such a connection at the TLS ClientHello, so a run
  stopped with "the server closed the connection". The hook adds that the
  test connection is strict and names `HMSSQL_TEST_SQL_VERSION`.
* **`scripts/azure-sql-test.sh env` left localhost's TLS settings in
  place** when sourced after the local configuration: plaintext,
  certificate trust and the strict-TLS tests off. It sets TCP, strict
  encryption and certificate validation explicitly now, unsets the local
  CA file, quotes every value, and names the Azure host as the TLS
  hostname, since GHC on Windows reads an empty variable as unset.
* **`scripts/azure-sql-test.sh prune` missed four of the databases a run
  can leave behind**, since `Connection.Database`'s odd names didn't match
  its pattern. Every database the suite creates now starts with
  `hmssql_test` and ends with the `uniqueName` suffix, and prune takes
  names by that suffix, which covers the old shapes too.

### On Windows

* **The suite did not build or run on Windows.** It depended on the
  `unix` package, and it read the run's tag for unique names from
  `/dev/urandom`, which a native Windows program can't open. `hmssql-tests/Compat.hs`
  has the platform's equivalents now.
* **A mock-server test hung, and so did a test that filled a socket's
  buffer.** The mock stopped its accept loop with `killThread`, and two
  tests stopped threads inside network's `sendAll` the same way, which on
  Windows never returns. The mock closes its listener first there and does
  its I/O through hmssql's socket backend, and the tests fill the buffer
  through the connection's backend.
* **The `Mock` benchmarks hung at the end of their first group**, for the
  same reason: `Bench.Mock`'s cleanup killed the mock's acceptor thread
  inside network's `accept` before closing the listener. The benchmark's
  mock closes the listener first now, as the suite's does. Found on
  2026-11-06, at the first run of `scripts/perf-compare.sh` on Windows.
* **Two mock-server shutdown paths stalled on stock Windows GHC.**
  `Concurrency.CancelModel` used `shutdown(SD_RECEIVE)` to make its
  handler close a socket with `SO_LINGER=0`, which didn't cancel the
  backend's pending overlapped read, so a request superseding a large row
  waited for a reset that never came; on Windows it uses the backend's
  close, which cancels and waits for pending I/O. `Resources.CutHandshake`
  killed its proxy's thread inside network's blocking `recv`; it closes
  the sockets first now, and its leak check counts the backend's handles
  exactly.
* **A test's broken close depended on the I/O manager.**
  `Resources.CloseFailure` breaks a close through `socketToHandle`, which
  with network before 3.3 under the native I/O manager fails with an
  `ErrorCall`, where the test caught only `IOException`. It catches
  whatever the broken close throws.
* **From Git Bash, `--match "/Wire/"` ran nothing and passed.** The shell
  rewrites an argument that starts with a slash into a Windows path, the
  pattern matched no example, and hspec reported `0 examples, 0 failures`
  with exit code 0 ([testing.md](testing.md#building-and-running)).
