# Performance research record

This is the record of what hmssql's code size and speed were measured to be,
and of the optimization work those measurements drove: the round on the row
walk in September and October 2026, and the two runs on the reader recipes on
2026-11-04. It gives the questions, how each was measured, the answers with
their numbers and conditions, what was kept and what was refused, and what
stays unverified. The rules that came out of it are in [design.md](design.md),
"Memory and performance" (above all "How an optimization is kept local"); the
facts about GHC and its libraries are in
[protocol-notes.md](protocol-notes.md#ghc-and-its-libraries), "Platform and
tooling"; and how to run the tools is in [testing.md](testing.md#benchmarks),
"Benchmarks", above all "Measuring a change", "Comparing two commits" and
"Code size". The rewrite between the row walk and the recipes, with its own
measurements against the row walk, is in
[value-streaming-research.md](value-streaming-research.md).

## How performance is measured

Unless a section says otherwise, the measurements of November 2026 ran on one
32-core Linux workstation (an AMD Ryzen 9 9950X) with GHC 9.12.4 at `-O1`. The
row-walk round used the same kind of machine, and its TLS figures were taken on
macOS as well. Each kind of measurement answers a different question, and the
runs found how far each can be trusted.

* **Object code.** `scripts/code-size.sh` generates a program of 50 records of
  1,187 fields of ten types, with derived `FromSqlRow` and `ToSqlRow`, compiles
  it against the working tree's hmssql, and prints the `.text` of the decoders
  (`FromRows`), the encoders (`ToRows`) and the records; `--quick` has 393
  fields, and `--check` fails above 100 bytes per field. The library's own
  `.text` is summed over its objects. Two ways of summing it gave different
  totals for the same commit (2,548,813 and 2,675,828 bytes, the second
  counting objects left from earlier builds), so only differences within one
  count are compared. `scripts/api-code-size.sh` compiles forty call sites of
  one API function per module and takes the bytes per call against an empty
  module. `scripts/link-size.sh` and `link-map-size.py` measure a linked
  program and attribute its code to packages. `code-owners.py` and
  `code-inner.py` attribute each local closure to the binding whose STG
  defines it (`-ddump-stg-final` with uniques and `-fexpose-internal-symbols`).
  Attributing a closure to the next top-level symbol instead misattributed
  code: with GHC's default symbols only about 15% of the code has a symbol of
  its own.
* **Allocation from the benchmarks.** The benchmark's `--csv` at `--stdev 3` is
  exact to a few bytes per iteration and unaffected by other builds.
  `--stdev Infinity` runs one iteration and builds the dataset within it, which
  hid changes of 30 to 80 bytes per row: the typed `int bigint` Mock query read
  2.86 MB there against 3.66 MB at `--stdev 3` for the same binary. Allocation
  of a tiny case is still noisy: two builds of identical source gave the
  plain-text lexer an allocation ratio of 1.114.
* **Fixed-work probes.** `scripts/resource-probe.sh`,
  `encoding-resource-probe.hs`, `live-bulk-resources.hs`, the drivers under
  `scripts/optimization-decoding/` and `scripts/optimization-query/run.sh` run a
  fixed number of operations with no clock, after a warm-up and a major
  collection, and read `GHC.Stats`. They separate bytes allocated, the live heap
  after a collection, the maximum live heap, RTS memory and process RSS, which
  are different quantities. RSS includes demand-paged code and allocator pages
  and varies between launches; the maximum live heap of a probe includes its
  input fixture.
* **Time.** Only with nothing else building or measuring, as alternating pairs
  of saved binaries pinned to one CPU with `+RTS -N1`, by
  `scripts/bench-compare.py` (or `scripts/perf-compare.sh BASE-COMMIT`, which
  also measures the code size). A ratio is the geometric mean of each case's
  median new/old ratio. Five pairs of two identical builds gave Decode 1.000,
  Encode 0.997, Mock 1.004 and Sql 1.004; in one pair of the older harness, a
  binary against itself moved cases by 0.96 to 1.06, with one outlier at 1.52.
  The 4 MB cases are bimodal: they came out at 1.2 to 1.45 over two pairs twice,
  and at 0.93 to 1.03 over five, so they need five pairs or more.
* **Instruction counts.** `perf` isn't permitted on the machine
  (`perf_event_paranoid` is 4). Valgrind 3.22.0 was installed during the second
  run, and Callgrind counts a whole fixed-work probe, setup and warm-up
  included, so a count is a comparison of two runs and not a cost per row.

## The row-walk round, September and October 2026

These are the measurements of the row-walk implementation, from the round of
optimization that began on 2026-09-27 and the work that followed it. "Before"
is the library as it was when the round began, with 4096-byte packets; the
numbers are client CPU with `+RTS -N1`, from the benchmark suite against SQL
Server 2025 in Docker on the same machine over strict TLS, or against the
in-process mock server. The row walk and its parsers were replaced on
2026-11-01, so the decoding figures describe that code; they are the baseline
"original" that the value-streaming record compares against. The transport,
TLS and connecting figures describe code that is still in place.

### Decoding

Parsing and decoding 10,000 rows with the packets already in memory
(`Bench.Decode`):

| Dataset, 10,000 rows unless stated | Time before / after | Allocation before / after |
|---|---:|---:|
| `(int, bigint)` into `(Int32, Int64)` | 5.3 / 0.95 ms | 48 / 5 MB |
| `(datetime2, datetimeoffset)` into `(LocalTime, DateTimeOffset)` | 34.5 / 1.3 ms | 106 / 7 MB |
| `decimal(18,4)` | 7.4 / 0.9 ms | |
| Five nullable columns into `Maybe` fields | 26 / 1.7 ms | 97 / 8 MB |
| 1,000 rows of 50 columns | 17.6 / 2.8 ms | 86 / 11 MB |
| `varchar(100)` in code page 1252 | 10.1 / 1.3 ms | 70 / 6 MB |
| One `nvarchar(max)` of 2M characters | 10.4 / 0.9 ms | |

* The old date and time decoders went through `Integer` and `Rational` and
  left thunks.
* Text from the server: 4,000 ASCII characters of UTF-16 in 1.4 µs instead of
  17, 4,000 CJK characters in 7 µs instead of 21, text with lone surrogates 30
  times faster, and 100 bytes of accented Latin text in 0.13 µs instead of 2.6.
* From a local server (`Bench.Live`, the socket and TLS included): 10,000
  `(int, bigint)` rows by `query` 11 to 1.3 ms; `(Int32, Text)` 11.7 to 1.9 ms
  and 41 to 8 MB; five nullable columns to 3.45 ms; 1,000 rows of 50 columns to
  5 ms typed and 4.4 ms as `SqlRow`. Every 10,000-row dataset read in a fifth to
  a tenth of its earlier time. The 4 MB single-value datasets didn't change,
  because the network and TLS dominate them.
* The row walk alone measured 5 to 6 times the incremental parser's speed per
  row on narrow rows, and 4.4 times on 50 columns; the gate for keeping a
  second parser was 2 times. A row cut by a packet boundary, walked from a copy
  instead of parsed, took 1,000 rows of 50 columns from 0.78 to 0.42 ms parsing
  and from 8.7 to 7.0 ms end to end.
* A million rows of `(int, nvarchar(50), decimal(18,2))` from the mock server
  decoded in well under a second, against about 1.05 s before the round. Two
  regressions the fixes introduced, decimal powers computed per value and
  values copied twice, were undone ([bugs-found.md](bugs-found.md), "Memory
  and performance").
* Where the typed decoders' speed came from: three inlining rules, each of
  which cost 16 to 32 bytes and a few percent per cell when broken and showed
  only in the allocation column, and `-O2` on `Hmssql.Decoding`,
  `Hmssql.Tds.Token`, `Hmssql.Tds.CodePage`, `Hmssql.Tds.Utf16`,
  `Hmssql.Tds.Packet` and `Hmssql.Tds.PacketWriter`. The walk's loop kept its
  column index unboxed only with SpecConstr (8 to 25% faster), while the
  incremental parser in the same module was up to 10% slower for it; the loops
  over every byte sent, in `Packet`, were 15 to 20% faster. Library-wide `-O2`
  made the token parser 12 to 20% slower, and `-O2` on
  `Connection.Internal`, `Query` (streams 5 to 15% slower) or `Tds.Primitives`
  changed nothing or lost. The rewrite removed the rules and the `-O2` on
  `Decoding`, `Token` and `PacketWriter`; `Packet`, `Utf16` and `CodePage`
  keep it.
* GHC 9.12 compiled the walk's loop into a second, boxed copy when an NBCROW
  NULL was tested by a guard. Testing the bitmap to pick the column's kind
  instead, so both cases reached the loop through one call site, took 10,000
  NBCROW rows of five nullable columns from 0.89 to 0.70 ms.

### Reading rows a packet at a time

Reading rows a packet at a time rather than a token at a time took 10,000
`(int, bigint)` rows through the mock server from 4.8 to 1.45 ms and 17.9 to
5.8 MB, and from a local server from 5.9 to 2.6 ms by `query`. The connection
lock, the generation check, the masked commit and the exception frames are paid
once per packet. The thread holding the lock re-enters it without STM, about
270 bytes less per row read under `query`. The row walk read DONE, DONEPROC,
DONEINPROC and RETURNSTATUS in place, about 1 KB less per request and 5 KB per
`executeStatements` statement, and took the run of them that ends a statement
as one step: 1,000 rows through `executeMany` 4.5 to 3.8 ms.

### Large values

A large value is read in one copy: the reader copies it out of each packet as
it arrives instead of keeping the packets until the row is complete and
joining them. Peak live heap above the connection's own, with a major
collection forced at the peak:

| Value | Before | After |
|---|---:|---:|
| 4 MB `varbinary(max)` or `nvarchar(max)` | 8.5 MB (2.0 times the value) | 4.2 MB (1.0 times) |
| 64 MB value | 135 MB | 84 MB (1.25 times while its last quarter is copied, 1.0 at the end) |
| 4 MB output parameter (RETURNVALUE) | 8.6 MB | 4.3 MB |
| 32 MiB output parameter | 68 MB | 34 MB |
| 64 MiB output parameter | 136 MB | 67 MB |

A 32 MiB value read at 512- and 2048-byte packets leaves 1.00 times its size
live once the TLS layer's finalizers have run (`Scale.TlsSmallPacketMemory`).
`max_mem_in_use` at the default `-A` went from 121 to 65 MB for a 32 MiB output
parameter. CPU didn't change, but for 25 µs more parsing per 4 MB, a feed per
packet.

### Sending

* A request body was built in a buffer of its exact size and framed into
  packets as it was sent, each byte copied once. It had been copied four times
  (into the body's builder in 8000-byte PLP chunks, then per packet by
  `runPut`, `LB.toStrict` and TLS), about 12 bytes allocated per byte sent.
  Framing a 4 MB `varbinary(max)` parameter went from 2.25 ms and 44 MB to
  0.45 ms and 4.9 MB, and sending one to a local server from 27 to 11 ms with
  the slow TLS pair (6.7 ms with the fast one, below).
* Text is encoded to UTF-16 by a transcoder with an ASCII fast path: a
  1M-character parameter or batch takes 0.6 ms to build instead of 33, and
  allocates 4.6 MB instead of 211.
* A one-parameter `sp_executesql` request takes about 1 µs and 3 KB to build
  instead of 2.3 µs and 11 KB, and a 2,000-parameter one 1 ms and 1.7 MB
  instead of 5.8 ms and 28 MB. Against a local server, a one-parameter round
  trip took 33 µs instead of 44, and 100 rows through `executeMany` 0.53 ms
  instead of 0.71 (1,000 rows 4.6 ms instead of 5.9).
* `mkQuery` lexes in linear time (20,000 subtractions between two
  placeholders took 123 ms, and take under 1 ms), and a literal is lexed once
  per program run, because `mkQuery` is INLINE with the lexing outside the
  parameters' lambda: a 230-character lookup costs 1.05 µs from `Query` to
  packets instead of 1.97.
* Text and `ByteString` parameters are declared `nvarchar(4000)`,
  `varbinary(8000)` or `(max)` rather than by the value's length: a statement
  the server hadn't seen, run with strings of ten lengths, took 21.4 ms of wall
  time instead of 33.7.
* The default packet size of 8000 instead of 4096 takes about a quarter off
  reading or sending a 4 MB value over TLS (28.1 to 20.9 ms, and 22.9 to
  16.5 ms).
* Over TLS, a message's records are gathered into writes of up to 64 KiB, where
  a 4 MB parameter had been 525 `send`s of one 8 KB record: 12.1 to 11.1 ms.

### What the second review's safety changes cost

The second review of the row-walk code made every read bounds-checked and
sequenced in `IO`. Measured the same way:

* The checked reads cost nothing measurable once each read stopped boxing its
  result: the row walk and the typed and `SqlRow` decoders were at 0.90 to 1.05
  times, several faster because borrowed values were copied more cheaply. With
  `unsafeDupablePerformIO`'s `lazy` in the way they had been 1.05 to 1.35
  times, and code-page text 2.5 times.
* The incremental `Get` row parser, the fallback, was 1.2 to 1.9 times,
  because it copied every value.
* Rendering a 2,100-placeholder query and an RPC of 2,000 parameters were 1.45
  times (0.52 and 0.97 ms), the placeholder names being built with `show`.
* `withTransaction` around `SELECT 1` was 1.2 times, for the BEGIN's round trip.
* The `Mock` and `Live` groups were at 0.99 overall, and the byte-layer cleanup
  that followed (`sql_variant` in place, the packet header in place, buffers of
  exact size for the leftovers) at 0.97 to 1.00, with no case slower beyond
  the noise.

## The transport, TLS and the reader thread

These describe code that is still in place, measured when it was written.

**TLS records.** Over TLS, each TDS packet arrives as its own record, whose
plaintext is a small pinned object sharing blocks with tls's and crypton's
finalizable garbage. The reader thread copies chunks under 4096 bytes into
32 KiB arenas, so a 32 MiB read at 512-byte packets peaks at about 160 MiB
instead of 370 and is 10% faster; at 4096-byte packets nothing changes. The
backend's receive is buffered (`newBufferedRecv`): tls reads each record in two
calls, its 5-byte header and then its body, and `TLS.getBackend` made each a
system call. One receive into a 32 KiB buffer that the connection keeps usually
covers several records, copied out as tls asks for them, so a round trip takes
two `recvfrom` calls instead of three (one of them the EAGAIN before the wait).
Receiving into arenas and handing out slices, as the plain-socket path does,
allocated no less, since records split between receives had to be joined, and
kept a 128 KiB arena alive per idle connection.

**What a record costs is mostly the `tls` package's,** and depends on its
version. `tls` 2.4.7 or later over `crypton` 2.1 encrypts and decrypts AES-GCM
in one call with AES-NI; earlier `tls` goes through crypton's general AEAD
interface, which sets up the key per record, and `crypton` before 2.1 has no
accelerated GCM decryption (18.6 µs to decrypt 8000 bytes with 1.0.6, whose GCM
code 1.1.5 keeps, and 4.5 µs with 2.1.2). hmssql accepts either (`tls` 2.4.4 or
later). The Stackage snapshot `nightly-2026-11-03` has the slow pair, `tls`
2.4.6 over `crypton` 1.1.5, and no snapshot had the fast one by then.

| Client CPU, against a local server, GHC 9.12.4 | Slow pair | Fast pair |
|---|---:|---:|
| Per small record sent / received | 5.7 / 8.9 µs (`tls` 2.1.8) | 2.1 / 4.5 µs (`tls` 2.4.8) |
| A trivial round trip | 30 to 42 µs | 18 to 25 µs |
| Reading a 4 MB `varbinary(max)` | 15.1 ms | 7.1 ms |
| Sending one | 11.9 ms | 6.7 ms |
| 1,000 `nvarchar(1000)` rows | 7.9 ms | 3.9 ms |

With the fast pair, what is left is `tls`'s record layer (about 2 µs sent and 4
received, and 15 to 24 KB allocated per small record, for copies of the payload
and the header through cereal), not the cipher (0.1 to 0.3 µs). All of that is
with AES-NI. Where crypton has no accelerated AES, the cipher is most of the
client's CPU: on Apple silicon with `crypton` 1.1.5, a request loop under TLS
1.3 spent about 70% of its samples in `crypton_aes_generic_encrypt_block` and
`crypton_aes_generic_gf_mul`, and a request cost 20 to 70 µs of client CPU per
kilobyte sent where it cost under 1 in plaintext (a 32 KB batch 1,160 µs
against 25, and a 4 MB `varbinary(max)` parameter 48 ms; macOS, GHC 9.12.4,
SQL Server 2025 in Docker, 2026-10-04). SQL Server on Linux chooses AES-GCM
when the client offers it, whatever the client's order. Offered nothing but
ChaCha20-Poly1305 in a probe, it accepted, and the 32 KB batch took 335 µs of
client CPU and 0.9 ms by the clock instead of 2.9. hmssql offers `tls`'s
default suites and has no setting for them ([limitations.md](limitations.md)).

**On a plain socket** (no TLS after login), the reader thread receives straight
into the free end of its 32 KiB arena instead of calling `recv` with a fresh
32 KiB buffer each time (`network`'s `recv` allocates the whole size it asks for
on every call), and only a packet split between two receives is copied. A
one-token round trip against the in-process mock allocates 15 KB instead of 51.
The arena is renewed when less than 8 KiB of it remains. Ten thousand 32-byte
TLS reads from a synthetic backend allocated 2,559,840 bytes with 34,744 bytes
live (2026-11-04), so the TLS path shares its receive buffer too.

**The reader thread** is unbound by default (`forkIO`). With
`connectPinReader` it is forked on the capability of the thread that connects
(`forkOn`). When that is the thread that then waits for the responses, passing
it a chunk doesn't wake another capability, which with `+RTS -N` on 32 hardware
threads took 40 to 80 µs off a local round trip: a no-op batch took 77 µs of
wall time instead of 126, and 45 µs of CPU instead of 59. It is a setting and
not the default, because a pool's connections, opened by one thread, would
share one capability for their readers, which decrypt and copy what they
receive. Sixteen connections read in parallel by sixteen threads took the same
time either way; a sustained TLS workload wasn't measured.

**Connecting** with the system store trusted costs about 52 ms and 1.5 MB of
allocation against a local server, against 73 ms and 40 MB before the store was
cached. The files of `tlsCaCertificateFiles` are parsed on every connect, about
70 µs and 320 KB for a one-certificate PEM file. A cache by path and
modification time was tried and removed, since a file replaced with its
modification time preserved would have kept the old certificates in use.

**A request the server never answers costs nothing while it waits.** The waiting
thread blocks in STM on what the reader thread hands on (the connection's
`TMVar`, or under MARS its session's queue), and the reader thread blocks in its
receive; neither polls, and nothing is kept per unit of time. Measured for 15
minutes each against an in-process mock that stops answering (2026-10-15, GHC
9.12.4, the live heap read after a major collection every 30 s), on a plain
connection, under MARS and over strict TLS, with four ways of stopping:

* a request with no answer at all;
* rows in a packet without END_OF_MESSAGE;
* a packet whose header promises 4096 bytes, of which 108 arrive;
* a `varbinary(max)` value of unknown length cut after 1 MB (240 KB under
  MARS, within its window).

The live heap moved by at most 4 KB, in one step within the first four minutes,
and then not by a byte (0.27 MB with nothing received, 2.5 MB holding the cut
value, and 1 to 3.2 MB over TLS); the process allocated under 0.05 MB/s and used
no CPU. A loop of `timeout`s on such a connection goes as design.md,
"Interruption and cancellation", says: the first interruption sends the
Attention, the second interrupts the next request's drain and so breaks the
connection, and every later request throws `ConnectionBroken` at once. At
900,000 such requests a second (2.6 GB/s of allocation, all of it garbage) the
live heap stayed within 1 KB for 4 minutes on all three transports, and a loop
that opened a connection to such a server, gave its request 100 ms and closed it
held its live heap flat for 15 minutes (8,000 connections, 6,000 over TLS).
`Resources.StalledServer` keeps the shape of this in 2 s per case, a minute each
with the slow tests. A stalled server was therefore not what grew a test
process to 16 GB in the matrix run of 2026-10-05 ([bugs-found.md](bugs-found.md),
"In the test suite").

**The backend record costs nothing measurable off Windows.** The socket calls
went behind `Hmssql.Connection.Backend`, a record of functions, which adds an
indirect call to each send and receive. The benchmark before and after, on
macOS with GHC 9.12.4 against SQL Server 2025, `+RTS -N1`, the two executables
alternated for two rounds: the geometric mean was 1.004 by CPU time over the 94
cases of `Mock` and `Live`, and 1.000 by the clock over the 119 of `Mock`,
`Live` and `Mars`, where the same executable differed from itself by 0.9% and
0.4% between rounds. `Mock`'s bare round trip took 24.8 µs before and 24.7
after, and allocation was the same to the byte.

**What MARS cost a plain connection** is one more field hop per packet on the
plain read path (`connPrimary`) and a `keepAlive#`. The `Live` group at the MARS
change against the code before it, `+RTS -N1`, on 2026-09-30 with other test
suites loading the machine and the server, showed no case slower beyond the
noise: every case outside 10% in the first round measured 0.90 to 1.11 when
rerun alternately, and `withTransaction` around `SELECT 1`, now a TM begin, 0.96
to 0.98.

## The code-size run, 2026-11-04

**Question.** How much object code does hmssql add to an application with
many records, and what can be done about it without losing speed? The user
named 50 records of various sizes, a few over 50 fields and most at least 10,
which is what `scripts/code-size.sh` generates.

**How it was run.** Parallel experiments, each by an agent in its own git
worktree, in three rounds of four or five tracks. The coordinating session
merged the tracks that paid into `api-cleanup` and timed the merged branch
between rounds with nothing building, as alternating pairs on CPU 14.

### Where the code came from

**Decoders, 25 KB per field.** At the start the code-size program's decoders
were 29,939,740 bytes, 25,223 per field, and took 617 s to compile; its encoders
were 583,373 bytes, 491 per field. Every typed decoder was INLINE, from
`singleField` through `readCellRecipe`, `cellHead`, `convertBytes`, the
`Recipe` monad's binds and the `FromSqlField` instances to `genericFromSqlRow`,
so every field of every record got its own copy of the whole cell read: seven
delimiter shapes, each with its fast path, its slow primitive, `resume` and the
failure dispatch, the general path for NULL, PLP and values cut by a packet, the
streaming branch, and the type's conversion. Size was linear in fields, about
26 KB per `Int32` field from 5 fields to 160. Compile time was not: four times
the fields took 7.1 times as long, because each field's compile step sat inside
the previous one's `Right d ->` alternative of `RowDecoder`'s `liftA2`, so a
record was one function nested n deep. (A first `--quick` reading of 6,090,404
bytes, which suggested the cost per field grew with the program, was measured
against a library still built with a reverted experiment; the true figure,
9,941,572, is the same 25.3 KB per field.)

Taking the general cell path alone out of line gave 18.6 MB, and inlining only
the three common delimiters about 10 KB per field: the size was spread through
the inlined code, not in one part of it. Making `singleField` NOINLINE gave
2.55 MB and 35 s.

**What was left after that, 2,150 bytes per field,** was 75% the record's own
composition, inlined per record: a compile chain over `Either`, a prepare
closure per field, a recipe with a `$wresume` call and a suspension
continuation per field, and `to`'s `:*:` deconstruction. The rest was the field
decoders inlined into the module once per record and per type. GHC's CSE shared
identical decoder CAFs within one record's instance but not across records, so
`UTCTime`'s decoder, inlined down to the calendar arithmetic, was in the quick
module seven times.

**Encoders, 491 bytes per field.** `genericToSqlRow` was built from
`divideRow`, whose lazy `let (b, c) = split a` stopped case-of-case beyond the
smallest records. So each field got a selector thunk walking the generic tree
from its root (log₂ n cases), a closure with its type's encoding inlined, a list
cell and a tuple. Each selector also carried a coercion the size of the whole
representation type: an 8-field record had 3,892 types and 2,699 coercions in
Core, which made compile time quadratic in a record's fields.

**Call sites,** in modules of 40 uses each, after round 1:

| Use | Bytes per use |
|---|---:|
| Query's `<>` (inlined at every use) | about 550 |
| A query composed of four `param`s with literals, per function | 4,400 |
| An `Only` or tuple `FromSqlRow` instance (INLINE), per row type per module | 1,000 to 1,450 |
| `query` of a tuple type | 1,449 |
| `query1` | 657 |
| `queryResultSets` | 881 |
| `callProcedure` | 861 |
| `bulkInsert` | 593 |
| `queryWith ((,) <$> singleField fd <*> singleField fd)` | 1,563 |
| Three columns with `refineField` (INLINE, both branches copied, about 2.6 KB per use) | 8,550 |
| A `Text` literal in application code | about 248 |

The `Text` literal's cost is text's: its `$wunpackCStringAscii#` is reboxed in
each CAF.

**The library,** about 2.55 MB of `.text`. The largest sources were the tuple
instances (157 KB of Decoding's 325 KB, about 2.2 KB per field for 2- to
12-tuples), `writeTypeInfo` INLINE (25 KB, five copies), the `Recipe` binds
inlined into the readers that run once per token (83 KB of `Token.o` and 49 KB
of `TypeInfo.o`), `encodeUtf16LE` INLINE at 28 call sites (19 KB), `bVarChar`
and `usVarChar` INLINE (seven copies of the UTF-16 encoder in `writeTypeInfo`,
6.8 KB), derived `Show` (247 KB) and derived `Eq` (68 KB). A derived `Show`
constructor cost about 600 bytes: each field became two or three lazy `ShowS`
closures of 100 to 140 bytes, and GHC copied `showsPrec` into `show` and
`showList`.

**Linked programs.** After round 1, a minimal program (connect, one query into a
two-field record, close) linked 17,460,817 bytes of `.text`, the code-size
program 18,148,945, and `examples/crud` 22,974,033. The linker drops unused
sections, but stack's snapshot packages and hmssql weren't built with split
sections, so every module a program referenced was linked whole
([protocol-notes.md](protocol-notes.md#ghc-and-its-libraries), "GHC and its
libraries", has the toolchain's side of this). The chain `hmssql:Connection.Internal`,
`tls:Network.TLS.Core`, `tls:Session` and `serialise:Codec.Serialise.Class`
pulled in `vector`, `cborg`, `unordered-containers`, `serialise`,
`vector-stream`, `strict`, `hashable`, `primitive` and `these`, about 5.5 MB that
is never called.

| Linked `.text`, bytes | As built | hmssql split | Every package split |
|---|---:|---:|---:|
| Minimal program | 17,460,817 | 15,560,273 | 4,820,561 |
| Code-size program | 18,148,945 | 16,682,577 | 5,623,377 |
| `examples/crud` | 22,974,033 | 21,679,697 | 5,660,241 |

Split, only 0.88 MB of hmssql reached the minimal program, and `BulkCopy` and
`Catalog` weren't linked into either program even unsplit. `cabal check`
rejects `-split-sections` in a package's `ghc-options`, so splitting is the
application's build setting, as for any Haskell package. Making
TLS optional isn't worth it: even `EncryptOff` encrypts the login unless the
server answers NOT_SUP, Azure requires TLS, and split, the TLS stack is about
2.4 MB of the minimal program's 4.8 MB.

### Allocation: unknown calls and their arguments

**Why passing the input unboxed doubled allocation.** The earlier trial that gave
a recipe its input as the three unboxed fields of a `ByteString` (`Addr#`,
`ForeignPtrContents` and `Int#`) allocated 7.5 MB per typed query against 3.5 MB,
mostly in allocation ticky attributes to no closure
([value-streaming-research.md](value-streaming-research.md), "Optimization
candidates after the failure channel"). GHC's RTS has generic-apply entry
points only for all-pointer patterns and a lone `n`
([protocol-notes.md](protocol-notes.md#ghc-and-its-libraries), "GHC and its
libraries", lists them), so an unknown call with the pattern
`p n p n` compiles to `stg_ap_p_fast` with `stg_ap_n`, `stg_ap_p` and `stg_ap_n`
continuation frames, and each chunk applied to a function still wanting
arguments builds a PAP in the RTS (confirmed from the Cmm of a standalone
module). Any design that passes a position as an unboxed integer beside
pointers through an unknown call pays this, an index into a `ByteArray#`
included.

**What worked.** A recipe runs on the payload, shared by every call within it,
and a boxed position: an unknown call is one `stg_ap_ppp` with a 16-byte `I#`
where the `ByteString` was 32 bytes, and a known call takes the position unboxed
through the worker GHC makes. Then the boxes themselves: a table of 8,192 boxed
`Int`s, a CAF of about 170 KB built on first use, gives an unknown call its
position at the sites known to be unknown (`Parser.dynamic`), and the driver
keeps the payload and the position and builds a `ByteString` only when it
commits a batch or a suspension. A computed argument to an unknown call is a
lazy thunk unless it is forced: the first build of the table made every case
worse (24-byte thunks of the lookup where 16-byte boxes had been) until
`let !box = boxPosition pos`. Boxing everything through the table would be
wrong, because at a known call GHC can't see through `indexSmallArray#`, so an
inlined column would pay a lookup and lose its unboxed worker.

**The rest of what a row allocated.**

* A row's recipe left its failure in the channel, which removed a `Right` per
  row.
* The default `liftA2`, `<*>` after `fmap`, was a library function GHC didn't
  inline into a row type's module, so every column was an unknown call from it.
  Written out, the row calls its second column's worker directly.
* The tuples' balanced tree of pairs and triples, measured 10% faster before
  `Recipe`'s `liftA2` was written out, built a pair and a triple per five-column
  row, 56 bytes; a hand-written `(,,,,) <$> ...` had become cheaper.
* `sequenceA` over a list built a partial application of `(:)` per cell until
  `liftA2` was explicit.
* The raw-row loop behind `nextToken`, `queryCells` and raw rows had arity 2, so
  each cell built a thunk of its delimiter's recipe, two of the rest of the row
  and the bind's continuations before running them, about 390 bytes per
  two-column row. `GHC.Exts.oneShot` on the loop's arguments
  (`P.oneShotRecipe`) fixed it.
* Every row token allocated the closures of the other tokens' alternatives, 96
  bytes, until the rare tokens went to an out-of-line reader.

### Traps found in GHC's handling

* A NOINLINE function returning a record or a type with strict fields
  (`RowDecoder`, `FieldEncoder`, `Query`) gets a worker returning an unboxed
  tuple, and every caller rebuilds the box, 50 to 130 bytes per use; OPAQUE (GHC
  9.4 and later) stops it. OPAQUE isn't always better: on `productDecoder` its
  operands became lazy, a thunk each, and the quick program's decoders went from
  37,672 to 45,927 bytes.
* A pragma on a default class method copies a stable unfolding of the whole
  method into the instance, and GHC looks through a constructor application of
  any size wherever a field selects from it, so every use got the copy back.
  Default methods are always inlined into instances (`Unfolding: Core:
  Compulsory` on `$dm`).
* `RowDecoder a` can't be coerced across `M1` and `K1`: its result reaches
  `Stream Await IO (Outcome a)`, and `Stream f m r` applies `f` to a type
  containing `r`, so `r` is nominal. The generic decoder keeps a `Coercible`
  witness and applies the coercion to values. `coerce (:*:)` given to `liftA2`
  at each product was eta-expanded into a closure per product.
* An INLINE function defined as `f = \case` has no arguments on the left, so its
  pragma fires on any bare occurrence, `noinline f` included; to call the
  compiled copy, the argument has to be on the left. An INLINE call that isn't
  saturated silently doesn't inline. GHC eta-reduces an alias such as
  `doubleValue bs = readFloating bs` to the bare function, which then isn't
  inlined; a bang on the argument prevents it.
* GHC moved a per-column computation (`rowShape (columnType col)`) into each
  cell, building a `ConstantCell (Sized n)` per fixed-width cell, until it was
  evaluated once per column. A recipe returned from a NOINLINE function was
  eta-expanded to the cell's arguments until it was wrapped in `Prepared`.
* GHC doesn't return a sum type unboxed from an out-of-line function (there is
  no CPR for sums except on join points), so an out-of-line conversion's
  `Either` costs 16 bytes per cell more than an inlined one.
* After worker/wrapper, GHC's final float-out can make a guard that calls an
  out-of-line error a closed function of its own, which then takes its argument
  boxed: 16 bytes per `Int32` cell until the range check took an `Int64#`.
* RULES whose left-hand side is an OPAQUE function fire at `-O1`
  (`-ddump-rule-firings`), and not at `-O0` or on a let-bound partial chain.

### What was kept

| Track | Change | Effect |
|---|---|---|
| B | `singleField` out of line; the generic composition shared (`GDecoder`, `productDecoder` and `recordDecoder`); field instances not INLINE | Decoders 29.9 MB to 111 KB (94 bytes per field), compile 617 s to 1.6 s |
| C | Recipes on a payload and a boxed position | Typed allocation 22% to 28% lower; decoders 6.5% smaller |
| D | A derived record's fields as one list of `FieldParam` constructors; Query's `<>` out of line | Encoders 583 KB to 84 KB (71 bytes per field); a four-parameter composed query 4.4 KB to 0.6 KB of code per function |
| H | `Only` and tuple decoders compiled once, adapters out of line, and OPAQUE | A tuple `query` 1,449 to 193 bytes per use, `query1` 657 to 206, `callProcedure` 861 to 613 |
| I | Boxes from a table at unknown calls, the driver at a position, and no `Right` per row | Typed `int bigint` 3.66 to 2.84 MB per query, `SqlRow` 5.28 to 3.99 MB; library 35 KB larger |
| G | TYPE_INFO and token headers out of line (`Hmssql.Tds.Parser.OutOfLine`), and `encodeUtf16LE` called | Library 386 KB (15%) smaller |
| R3c | A hand-written decoder's composition out of line, with RULES to one call per arity | A two-column `queryWith` 1,563 to 283 bytes per use, three columns with `refineField` 8,550 to 677 |
| R3d | `Show` and `Eq` through out-of-line helpers (`Hmssql.Internal.Derived`) | Library 197 KB (8.6%) smaller |
| R3b | The row token's reader alone, the other tokens out of line, and a one-shot raw-row loop | Decode `.tokens` and `.rows` allocation 22% to 34% lower |
| A2, R3a | Built-in types' row decoders compiled once each in the library, the conversion inlined at one site | Decoders 111 KB to 79 KB (67 bytes per field); typed `int bigint` 2.84 to 1.89 MB per query; library 200 KB larger |

Some of the kept tracks cost a little, and the costs were accepted:

* **Track D's list of `FieldParam` constructors** made encoding 100,000 rows
  allocate 2.0% more for a five-field record and 1.3% more for a 3-tuple, about
  22 bytes per field; the `Encode` benchmarks use neither. The second run's
  numeric constructors (idea 3) took the five-numeric-field probe from 2,576 to
  2,296 bytes per row.
* **Track G** took `Tds/Token.o` from 248,030 to 164,918 bytes and
  `Tds/TypeInfo.o` from 176,254 to 127,158, and a COLMETADATA then allocated
  about 1.4 KB more per column: `Mock.query 50 columns x1000` 0.5% more and the
  output parameter case 1% more, while Decode's token benchmarks allocated 1% to
  1.5% less. It is paid once per result set.
* **Track R3c's rules** exist because, with `RowDecoder`'s `<*>` out of line
  through `apRowCalled` alone, each step of a chain held a partial application
  of the combining function per row: a hand-written five-column decoder
  allocated 176 bytes more per row. The `lift3RowCalled` .. `lift12RowCalled`
  rewrite brought the hand-written cases back to what they allocated inlined,
  and the five-tuple, built from those functions instead of a balanced tree of
  pairs and triples, went from 8,245,012 to 7,713,338 bytes per query. Making
  `nullableField`, `refineField` and `FieldDecoder`'s `fmap` OPAQUE turns the
  adapter's function into an unknown call per cell where it was known; no
  benchmark composes one, and the typed cases allocate as before.
* **Track R3d's `Eq` helpers** compare primitive fields inline: on `Token`'s
  types derived `Eq` was 14.0 KB, inline primitives with the rest through the
  out-of-line `eq` 8.1 KB, and every field through `eq` 10.5 KB, since each
  primitive field then had to be boxed.

**The per-type row decoders** (A2) were merged last, on the owner's decision of
size against speed. Each built-in type has one row decoder compiled in the
library, which inlines the type's conversion at a single site for a value lying
in the payload and sends every other cell through the type's out-of-line
`fieldDecoder`; `fieldRowDecoder` is exported. Against the code before them: the
code-size program's decoders 111,208 to 79,088 bytes (67 per field), typed
`int bigint` 2.84 to 1.89 MB per query, the nullable dataset 7.71 to 5.85 MB, a
derived record 3.10 to 2.14 MB, and over six pairs Decode 0.937 and Mock 0.907
in time; but `Decoding.o` grew from 332 KB to 533 KB. On the code-size program
that is 32 KB saved for 200 KB added, unsplit. Two pairs after the merge: Mock
0.924 in time and 0.917 in allocation, the typed and record cases 0.73 to 0.77,
Decode 0.989, and Encode and Sql within the noise.

### What was measured and not kept

* **Per-type row decoders with the whole cell read inlined** (track A): decoders
  111 KB to 79 KB and typed allocation 16% lower, but `Decoding.o` 0.36 MB to
  1.39 MB, which made a typical binary about 1 MB larger. A2's copies, a fifth of
  the size, replaced them.
* **A strict match of the generic product** in `ToSqlRow` (track E), 491 to 375
  bytes per field, superseded by track D.
* **`-split-sections` in hmssql's `ghc-options`:** 1.3 to 1.9 MB off an unsplit
  program, but rejected by `cabal check`.
* **`writeValue` out of line everywhere:** 38 KB less, but 32 bytes more per
  parameter (the second run found where they came from; idea 33 below).
* **`writeTypeInfo`'s layouts through NOINLINE helpers:** 14.6 KB to 7.7 KB, but
  16 to 64 bytes more per parameter.
* **A generic `Show` through DerivingVia:** larger when GHC specialised it, and
  only 6 KB smaller with NOINLINE methods once `from` and `to` were counted.
* **Track G's tuples** (wider tuples joining two narrower instances),
  superseded by track H's; they would have built two intermediate tuples per row
  of 7 to 12 fields.
* **`-fno-full-laziness` on `Token`:** 4 KB more, and the per-cell thunk stayed.
* **`encodeBulkCell`'s error messages out of line** (each a thunk chain of about
  270 bytes) made `BulkCopy.o` 2 KB larger, not smaller. What remains of
  `encodeBulkCell` is the conversion matrix, each part used once:
  `encodeValueAs` 26.9 KB, `sourceValue` 18.5, `variantFromSource` 10.3,
  `variantOf` 10.1 and `encodeBulkCell`'s own 18.1.
* **Sharing `otherCell` with `singleField`'s `cellPart`** saved 17 KB of
  `Decoding.o` but cost an unknown call per cell: a typed row of 50 `SqlValue`
  columns took 1.10 times as long in `Decode` and in `Mock.query`, so `cellPart`
  keeps its own read.

### Time

New against old, time and then allocation, CPU 14, `+RTS -N1`, no builds
running:

| Comparison | Pairs | Decode | Mock | Encode | Sql |
|---|---:|---|---|---|---|
| Round 1 | 2 | 0.979 / 0.954 | 0.996 / 0.942 | 1.004 / 1.000 | 0.986 / 1.005 |
| Round 2 | 2 | 0.991 / 0.970 | 0.955 / 0.885 | 0.996 / 1.000 | 1.016 / 0.987 |

A bisection over round 2's merges, four pairs each, found two regressions.

* **Track G's merge** made `nullable no NULL ROW` `.tokens` and `.rows` 1.08.
  The per-row STG was byte-identical before and after, so it was put down to
  code layout, and R3b's change, which removed real per-row work, took those
  cases to about 0.55.
* **Track I's merge** made `Decode.decimal(18,4) x10000.typed` 1.12 in time, the
  `datetime2 datetimeoffset` typed case 1.10 and its `SqlRow` 1.08, while
  allocating 4% to 9% less. Most of it was the benchmark: the Decode loop read
  rows through `rowRecipe`, which had become a closure of its own around the
  row's recipe, one more unknown call per row than the connection's driver makes
  (decimal typed was 1.14 against the code before the merge, and 1.03 with the
  loop in the driver's shape, which the benchmark now has). The rest is the
  table of boxed positions: with it disabled, every case was 1.00 to 1.02, and capturing the evaluated table
  outside the per-row closure changed nothing, so it is most likely the two
  dependent loads per lookup in a table of 98 to 192 KB, against a fresh box in
  L1. It was real and not the collector's timing: decimal typed was 1.26 at the
  default `-A64m` and 1.11 at `-A1g`. On the merged code, disabling the table
  made Decode 0.92 and Mock 1.03 in time, with 6% and 14% more allocation; the
  table stays, for Mock's sake, and its cost to Decode went on the ideas list
  (idea 27).

**At the end of the run**, against its start and against the original row walk:
one full pass of the 225 cases, with SQL Server 2025 in Docker for Live and
Mars, then two pairs of the groups without a server. The two-pair figures are
the ones to trust; the single pass gives Live and Mars and the comparison with
the original. Time and then allocation:

| Group | End/start, 1 pass | End/start, 2 pairs | End/original, 1 pass | Start/original, 1 pass |
|---|---|---|---|---|
| All | 0.893 / 0.878 | | 1.124 / 1.071 | 1.259 / 1.220 |
| Decode | 0.876 / 0.821 | 0.868 / 0.821 | 1.383 / 1.051 | 1.579 / 1.280 |
| Encode | 0.912 / 1.001 | 0.964 / 1.000 | 0.898 / 1.088 | 0.984 / 1.087 |
| Live | 0.915 / 0.900 | | 1.011 / 1.121 | 1.105 / 1.245 |
| Mars | 0.901 / 0.891 | | 1.025 / 1.036 | 1.137 / 1.163 |
| Mock | 0.802 / 0.845 | 0.838 / 0.844 | 1.105 / 1.075 | 1.378 / 1.273 |
| Sql | 1.084 / 0.989 | 1.040 / 1.011 | 1.013 / 0.992 | 0.934 / 1.004 |

The per-type decoders were merged after this pass. Against a real server, typed
`int bigint` queries were 0.94 of the original in time and 0.96 in allocation,
and `SqlRow` 1.00 and 1.01. Mock and Decode remained slower than the original
(1.105 and 1.383), where the Decode group's `.rows` and `.tokens` cases aren't
like for like. The Sql group lost: Query's `<>` out of line costs 3% to 7% per
piece in the composition benchmarks, and `mkQuery.lex 100 KB of plain text` was
1.18 in time and 1.13 in allocation. Both went on the ideas list (idea 29
below).

## The ideas run, 2026-11-04

**Question.** The code-size run ended with a list of 38 ideas for size, speed
and measurement. Which of them pay?

**How it was run.** From the end of the code-size run, with the per-type
decoders merged, each idea was tried as its own change and committed separately,
and a refused one was reverted before the next was measured. Agents worked by
area in parallel: decoding, encoding, queries and round trips, compilers and
platforms, and the library and link. While they built, they measured code,
allocation and memory only, with the fixed-work probes; the coordinator ran
the timing at the end with nothing else running, five alternating pairs on CPU
31. SQL Server suites ran one at a time, because parallel full suites saturated
the server's worker pool even with separate test databases. The rule the run
applied is design.md's: an optimization of more than about 20 lines moves a
common case by 10% in time or 20% in allocation. Idea 3 was kept below that bar,
on the owner's request for measured gains without significant regressions.

### At the start

| Compiled code | Bytes |
|---|---:|
| Library `.text` | 2,263,871 |
| 50-record decoders, 1,187 fields | 79,088 |
| 50-record encoders | 83,813 |
| Record definitions | 442,542 |

| Benchmark median | Time | Allocated bytes |
|---|---:|---:|
| Mock execute, one parameter | 7.870 µs | 18,461 |
| Mock typed `int bigint`, 10,000 rows | 522.175 µs | 1,886,868 |
| Decode decimal, 10,000 rows | 716.313 µs | 3,803,297 |
| Encode 2,000 integer parameters | 523.904 µs | 3,033,152 |
| Lex 100 KB of plain text | 38.441 µs | 224 |

The fixed-work decoder probe (100 operations in a fresh process, `+RTS -T -N1
-A4m`):

| Typed decode | Allocated per operation | Maximum live heap | RTS memory | Maximum RSS |
|---|---:|---:|---:|---:|
| `int bigint`, 10,000 rows | 3,666,351 | 1,147,136 | 9,437,184 | 19,824 KiB |
| `decimal`, 10,000 rows | 3,806,852 | 998,512 | 8,388,608 | 18,904 KiB |
| `nvarchar(max)`, 4 MB | 9,867,186 | 8,704,744 | 20,971,520 | 36,256 KiB |
| 50 columns, 1,000 rows | 11,445,288 | 4,614,624 | 13,631,488 | 20,408 KiB |

The payload of an 8000-byte packet is 7,992 bytes; the idea that the default
packet was 4096 bytes was stale, so the decoding probes ran both.

### The ideas and what became of them

| # | Idea | Outcome | Measurement |
|---:|---|---|---|
| 1 | Share the integer widths of the per-type decoders | Kept | Library 4,160 bytes smaller; row allocation identical |
| 2 | A derived record as static data (`lazy` on each product node) | Refused | Quick program's decoders 25,872 to 37,727 bytes (+46%) |
| 3 | An encoder constructor per numeric type | Kept, for strict numeric fields of records of several fields | Encoders 83,813 to 74,061 bytes (−11.6%); five numeric fields 2,576 to 2,296 bytes per row |
| 4 | Small encoders inlined per field | Checked, nothing to do | Five strict `Int32` fields 126 bytes per field (not the 606 seen after round 1), 60 with idea 3 |
| 5 | A derived record through the lift functions | Refused without a prototype | The whole gap to the 5-tuple is 12.25% of the record's allocation |
| 6 | `mkQuery` with `NamedParams` out of line | Refused | Caller 2,067 to 1,931 bytes, allocation 2.88 to 4.72 MB per 10,000 |
| 7 | `callProcedure` and the other call sites | Kept as they are | NOINLINE for OPAQUE on `inParam` grows the caller 1,042 to 1,298 bytes |
| 8 | A lexing entry point taking the literal's `Addr#` | Refused | No effect: text's literal rule fires first |
| 9 | `Text` literals in API calls | Refused | A `String` helper saves 336 bytes of code, adds 272 of data, and changes the API |
| 10 | Hand-written decoders at `-O0` | Measured, no change | 1.12 to 1.40 times the time and 1.24 to 1.27 the allocation of `-O1` |
| 11 | `-split-sections` in hmssql's modules | Tried, then removed on the owner's decision | 1,863,680 bytes off a linked program |
| 12 | tls's dependency on serialise | Upstream proposal drafted, no fork | 5,858,393 bytes attributed to the eight packages |
| 13 | `Addr#` literals in the `Show` helpers | Kept | `.data` 19,144 bytes smaller, `.text` 184 larger |
| 14 | Catalog and type tables as data | Arrays refused; a helper for the type-name literals kept | `SqlType` 4,568 bytes smaller, 104 more of data |
| 15 | A table for `encodeBulkCell`'s conversions | Refused | Outlining the classifiers saved 0.75% and cost 96 bytes per cell |
| 16 | The largest functions | One NOINLINE kept in bulk copy | 288 bytes and 24 bytes per successful row; the rest byte-identical |
| 17 | The wider tuples | Kept for 7 to 11 columns | Library 96,568 bytes smaller, 2.2% to 5.4% less allocation |
| 18 | Other compilers and platforms | Measured on GHC 9.6.6, 9.10.1 and 9.14.1 | All under 100 bytes per field; macOS and Windows not measured |
| 19 | The code size in CI | Kept | `code-size.sh --quick --check` in the test matrix |
| 20 | The attribution tools | Kept in `scripts/` | |
| 21 | No slice per cell for custom conversions | Refused | Offsets in `CellDecoder`'s interface break the buffer-ownership rule |
| 22 | Three list cells per row in `query` | Kept, as an internal reversed batch | 14.4% less allocation collecting 10,000 rows |
| 23 | The drain and skip paths | Kept, as a one-shot skip loop | 31.4% less allocation draining 10,000 rows |
| 24 | PLP values per type | Refused by projection | At most 1.78% of the short-text workload |
| 25 | The decimal and date and time conversions | `datetimeoffset` validation in `Int` kept | 16 bytes per value |
| 26 | UTF-16 decoding | Refused, and a layout effect found | text's decoder allocates 9 to 56 times as much |
| 27 | A smaller table of boxed positions | Refused | 98,304 bytes less live, 153 to 382 KB more allocation per workload |
| 28 | The NULL bitmap check | Kept, in `valueSpan` | Library 22,688 bytes smaller |
| 29 | Composing and lexing queries | Refused | Merging literals allocated 3.2 times as much |
| 30 | A round trip's allocation | `withConnectionLock` OPAQUE kept | 128 bytes per request |
| 31 | Receive buffers | Already in place | |
| 32 | RPC parameters poked | Kept for BYTE-length values | 100 scalar parameters 78,066 to 63,402 bytes per packet |
| 33 | `writeValue` out of line | Kept, as a shared Builder step | Library 19,752 bytes smaller, 32 bytes less per parameter |
| 34 | The encoders' unknown call per field | Done with idea 3 | 280 bytes per five-field row |
| 35 | MARS over TLS | Benchmarks added | Four `MarsTLS` cases |
| 36 | Live bulk loads | Profiled, no change | 0.28% less allocation, the same live heap |
| 37 | A load-independent clock | Valgrind installed; `perf` still blocked | |
| 38 | Benchmarks for the paths without one | Added | 110 cases |

The sections below give the numbers behind each, by area.

### Decoding

**1. Integer widths.** `integerAt` keeps its length and unsigned-byte checks
inline, and the three signed widths call `signedIntegerAt`, whose worker takes
the slice's fields and returns an unboxed integer. `Decoding` went from 532,655
to 528,647 bytes and `Scalar` from 72,527 to 72,375; all 19 typed Decode
fixtures allocated exactly the same.

**28. The NULL bitmap check.** `prefixedRowValue` takes the column index and the
bitmap environment, and `valueSpan` checks the bitmap before looking for a
delimiter: an NBCROW NULL consumes no bytes, while a prefix NULL consumes its
prefix. One copy of the bitmap branch went from every built-in decoder.
`Decoding` went from 528,647 to 504,983 bytes and `Parser` from 96,431 to 97,407,
22,688 bytes less in all, and 56 bytes less per compiled column; per-row
allocation was unchanged. The first version changed the exported
`prefixedValue`'s signature, which broke low-level callers; `prefixedValue` keeps
its signature and passes the caller's environment unchanged, an application's
`ByteString` environment is never read as a bitmap, and the bitmap-aware entry is
`prefixedRowValue` ([bugs-found.md](bugs-found.md)). The compatibility entry
costs 982 bytes of `Parser` and nothing in allocation.

**17. The wider tuples.** Attribution showed the `tuple7` to `tuple12` wrappers
at 152 bytes each, but the lift functions they share at 14,520 to 27,352 bytes
each. Seven columns are now two four-argument recipes, and eight to eleven a
first group of three to six and a six-argument recipe that applies the last
five fields; twelve keeps its own recipe. `Decoding` went from 504,983 to
408,415 bytes, and the quick program's decoders stayed at 25,872 bytes.

| Columns, 10,000 rows, allocated bytes | Before | Kept |
|---|---:|---:|
| 7 | 6,079,749 | 5,943,013 |
| 8 | 6,461,059 | 6,235,051 |
| 9 | 7,055,628 | 6,677,828 |
| 10 | 7,450,044 | 7,153,668 |
| 11 | 7,830,445 | 7,622,485 |
| 12 | 8,247,253 | 8,247,253 |

Splitting every width into three trailing fields saved 123,648 bytes of code
but added 459,040, 632,600 and 796,032 bytes of allocation at widths 10, 11 and
12. Twelve split as six and six allocated 9,153,597 bytes, and as seven and
five 8,836,845, so twelve stays one recipe. `Api.WideRowDecoderSpec` covers
every width from 7 to 12, ROW and NBCROW, whole and split payloads, bitmap
boundaries, column order, and a failed conversion followed by a good row.

**25. Dates and times.** `dateAt` has already restricted the UTC date to years 1
to 9999, and an offset of at most fourteen hours moves the day by at most one,
so the local day's bounds check fits in `Int`, even on a 32-bit target. That
saved 16 bytes per value: the `datetime2 datetimeoffset` fixture went from
6,637,110 to 6,477,110 bytes per 10,000 rows. The decimal reader already reads
64-bit magnitudes as `Word64`, and the local-time conversion already uses
`Int64` picoseconds and `MkFixed`. Callgrind over ten iterations of the whole
probe put `readDecimal` at 12,598,800 instructions and the `Integer` conversion
at 7,375,697, and the date and time profile at 123,167,634 in `evacuate1`,
60,293,477 in `Integer` multiplication and 28,182,370 in `Integer` quotient; the
fixture's encoding uses the same calendar arithmetic, so these aren't costs per
row, and no further rewrite was made on them.

| Whole fixed-work probe, Callgrind instructions | Before the run | After |
|---|---:|---:|
| `int bigint` | 194,258,769 | 194,004,982 |
| `decimal` | 193,020,909 | 191,751,581 |
| `datetime2 datetimeoffset` | 712,841,419 | 709,131,710 |

**2. Static product nodes.** `productDecoder a b = lazy (liftRow ... a b)`, with
`lazy` from `GHC.Exts`, grew the quick program's decoders from 25,872 to 37,727
bytes, and was refused on that alone.

**5. Records through the lift functions.** The integer pair as a derived record
allocated 3,920,278 bytes per response against 3,666,614 as a tuple, and the
five-field nullable record 7,845,986 against 6,884,831. Removing the whole of
the second difference would save 12.25% of the record's allocation, under the
20% that a new generic representation with its chunking and reconstruction
would need.

**10. Hand-written decoders at `-O0`.** With only the two modules defining the
decoders at `-O0` (the library, the parser and the driver at `-O1`), and both
decoders written with `singleField` and `<$>` and `<*>`:

| Decoder, 10,000 rows | Allocation `-O1` | Allocation `-O0` | Time `-O0`/`-O1` (five runs) |
|---|---:|---:|---:|
| Integer pair | 4,625,398 | 5,749,798 | 1.395 |
| Five nullable fields | 8,747,619 | 11,090,599 | 1.122 |

The definitions' code was 28,658 bytes at `-O0` against 11,750. Fusing an
arbitrary applicative chain without the rewrite rules would need another decoder
representation, so nothing changed; an application module that builds
hand-written decoder chains wants at least `-O1` when speed matters.

**21. The slice per cell.** A transparent `Int32` newtype through `refineField`
in an integer pair allocated 4,306,310 bytes per response against 3,666,614 for
the built-in pair, 639,696 bytes more per 10,000 rows, which includes the
adapter's path and isn't all the 32-byte slice. Taking the payload and an offset
in `CellDecoder` would put buffer and offset arguments in a value reader's
interface, which design.md rejects; the built-in types already avoid the slice
through a known conversion call.

**24. PLP values per type.** The short `nvarchar(max)` fixture allocated
8,984,212 bytes per 10,000 rows, so the projected 16 bytes per row would save at
most 1.78%, and a one-chunk path would have to repeat the checks of the total
length, the chunk boundaries and the terminator. Not built.

**27. The table of boxed positions.** A table of 4,096 entries instead of 8,192
left `Parser`'s code at 97,407 bytes and the live heap 98,304 bytes smaller. At
4096-byte payloads allocation didn't change, but at the default payload it rose:

| 7,992-byte payload, per response | 8,192 entries | 4,096 entries |
|---|---:|---:|
| Integer pair | 3,594,324 | 3,747,636 |
| Five nullable fields | 6,666,827 | 7,049,267 |
| Fifty fields | 10,539,513 | 10,912,569 |

A static table of `I#` closures through `addrToAny#` wasn't tried: it trades a
safe small array for assumptions about the closure layout of the target and the
runtime, and keeps the table's size.

**14. Catalog and type tables.** `Catalog`'s 67,494 bytes are mostly record
assembly, generic row conversion, ordering and `Show`, and column conversion
that depends on each row; `SqlType`'s 78,663 bytes hold a `dataTypeName` dispatch
of 673 bytes and a `dataTypeCategory` of 198, which an array wouldn't shrink, and
`toColumn` can't be a table because its lengths, precision, scale, user types,
XML schema and vector dimensions come from the row. What paid was the 35 type
names: each `Text` literal's CAF entry was 224 bytes, and a private OPAQUE
`Addr# -> Text` helper shares the `T.pack (unpackCString# addr)` conversion.
`SqlType` went to 74,095 bytes, with 104 bytes more of data, and a probe of
100,000 lookups allocated and retained exactly the same.

**16. The largest functions.** With each local closure attributed to its
binding:

| Binding, with its local closures | `.text` bytes | Largest parts |
|---|---:|---|
| `stepCoreWithOrder` | 36,664 | `resume` 14,224; `atBytes` 7,440 |
| `connect`'s body (`connect1` in STG) | 26,304 | `go` 7,336; `login` 5,800 |
| `putLogin7`'s worker | 12,288 | the body 6,240 |
| `bulkInsertSWith` | 21,720 | the entry 3,408; the row loop 2,184; send and clean-up 2,056; the batch loader 1,632 |
| `cellsOfResponse` | 20,336 | the row, cell and chunk continuations 1,968, 4,344 and 2,864 |

The source already shares the login function between its encryption branches,
`resume` between the suspension paths, and the two LOGIN7 offset writers.
NOINLINE on those four local helpers left the `.text` sections of `Client`,
`Connection` and `Connection.Internal` byte-identical, so it was reverted. In
`bulkInsertSWith`, `rowProblem` was shared in the source but inlined at three
sites, and two failure sites in the row loop shared a lazy `itos rowIndex []`
thunk built before the success and failure split, so every successful row paid
for an unevaluated row number. One NOINLINE on `rowProblem` keeps the formatting
inside the failure branches: `BulkCopy` 288 bytes smaller, and exactly 23,976
bytes less per successful load of 1,000 rows (24 for each row after the first)
and 12,016 per failed one, with the same live heap, error text and stored rows.
In `cellsOfResponse` the ownership `claim` helper is already one 400-byte entry
with three call sites, and the continuations hold distinct framing states, so
nothing was moved. The 10,000-row live bulk load allocates 0.28% less, most of
it the formatter.

**26. UTF-16 decoding.** A probe decoding 32 prebuilt strings of slightly varied
lengths, 10,000 times, allocated per decoded value:

| Input, nominal code units | hmssql's decoder | text's lenient UTF-16LE |
|---|---:|---:|
| ASCII 50 | 173 | 3,819 |
| ASCII 4000 | 4,123 | 228,969 |
| Latin 50 | 384 | 4,031 |
| Latin 4000 | 21,092 | 237,081 |
| CJK 50 | 305 | 4,379 |
| CJK 4000 | 12,155 | 253,229 |
| Emoji 4000, some pairs cut | 18,868 | 162,189 |

text's decoder also differs on a cut surrogate pair, where hmssql emits one
replacement per invalid unit. The existing decoder already loads eight ASCII
code units at a time inside its bounds-checked loop, and requiring aligned input
wouldn't cover arbitrary `ByteString` slices. The CJK timing that this idea led
to is under "Code layout and the short CJK case" below.

### Encoding

The encoding probe (`encoding-resource-probe.hs`, 10,000 iterations in a fresh
process, `+RTS -T -A4m`, checksums equal before and after):

| Measure | Before the run | With ideas 3, 32 and 33 |
|---|---:|---:|
| Library `.text` | 2,263,871 | 2,260,079 |
| 50-record `ToSqlRow` `.text` | 83,813 | 74,061 |
| Five `Int32` fields, encoder `.text` | 629 | 301 |
| Five numeric fields, allocation per row | 2,576 | 2,296 |
| Integer bulk conversion, per cell | 1,800 | 1,800 |
| Pure `writeValue`, per call | 4,992 | 5,032 |
| 100 scalar parameters, per packet | 78,066 | 63,402 |
| A query with 100 integer parameters | 309,468 | 294,988 |

The maximum live heap and RTS memory didn't change.

**3 and 34. Numeric constructors.** A hidden `ToSqlField` method builds an
unpacked constructor for a strict `Int32`, `Int64` or `Double` field of a
generic record of several fields, and the row walk out of line calls the
concrete encoder, so no numeric encoding is copied into the derived instance.
It saves 280 bytes per five-field row (10.9%) and 11.6% of the derived encoders,
for 13,728 more bytes of `Encoding`. A shared `numberParam` helper saved only 224
library bytes and gave back 160 bytes per row, and was refused. The first
version forced lazy numeric fields while building the parameter spine, so
`queryText`, `Show Query` and even `mkQuery` to WHNF threw for values that had
stayed unevaluated until encoding, tuples and `Only` included. The generic
selector instance now checks `selDecidedStrictness`, so only a strict or unpacked
selector takes the constructor, and a singleton constructor keeps the lazy path
([bugs-found.md](bugs-found.md); design.md, "Parameters and encoding"). The fix
left the code-size program and the five-field probe unchanged and made
`Encoding` 1,895 bytes smaller.

**33. The shared Builder step.** `writeValue` was INLINE with `noinline` at
chosen callers. A small INLINE wrapper now builds a Builder around an
out-of-line step that takes its continuation and buffer together, so no
intermediate Builder closure is returned. That alone took 19,752 bytes off the
library and 32 bytes off each scalar parameter in the packet probe; a pure
`writeValue` materialized alone allocates 40 bytes more per call (0.8%).

**32. Poked BYTE-length parameters.** A BYTE-length scalar writes its header
Builder and then a small write that takes the allocation size and the prefix
from the same payload length and copies the immutable payload; it is
`writeByteLengthValue` in `Hmssql.Tds.Parameter` (design.md, "Reading and writing
bytes: which layer"). Poking every non-PLP length kind allocated 68,226 bytes per
100-scalar packet against 63,402 for BYTE-length alone, so only BYTE-length is
poked. The property written for it, generated type and value pairs at generated
packet sizes compared with Builder framing, found two bugs in the writer: a
two-byte primitive resumed without room after a one-byte payload, and a staged
Builder could lose its next reservation ([bugs-found.md](bugs-found.md)).
Re-entering the local `continue` fixed the second at 24 bytes per parameter; a
capacity check around the rare staged continuation fixed it for nothing.

**4.** Five strict `Int32` fields were 629 bytes of encoder in a module of their
own, 126 per field, not the 606 per field seen after round 1 of the code-size
run, and 60 with idea 3.

**15. The bulk conversion matrix.** The conversions encode range checks, exact
rounding of floating point, character encoding, XML rules and the error message
of each type, which a table would still need. Outlining the twelve repeated type
classifiers took `BulkCopy` from 181,463 to 180,095 bytes and the integer
widening probe from 1,800 to 1,896 bytes per cell, and was reverted.

### Queries and round trips

`scripts/optimization-query/run.sh OUTPUT-DIRECTORY` builds the library and runs
these probes, including the refused shortcuts. Mock probes run 100 queries on
one connection over the first `Bench.Tokens` dataset, 10,000 `(Int32, Int64)`
rows; socket packet grouping varies their allocation a little. The final
comparison compiled the same runner against the code before and after:

| Workload | Allocated before | After | Maximum live before / after |
|---|---:|---:|---:|
| 100 bare executes | 1,212,296 | 1,213,896 | 160,520 / 160,544 |
| 100 one-parameter executes | 1,797,320 | 1,798,816 | 160,536 / 160,536 |
| 100 collections of 10,000 rows | 160,744,712 | 137,530,328 | 645,840 / 645,840 |
| 100 drains of 10,000 rows | 814,736,520 | 558,840,552 | 478,992 / 487,144 |
| 10,000 skips of 50 fixed-width cells | 28,318,888 | 32,478,888 | 6,584 / 5,384 |

**22. The reversed batch.** Only list collection takes the reversed path, its
accumulator wrapped in `ReversedBatch` and reversed once when the result is
assembled; `readStep`, streaming and folding keep the public order, which nine
mock tests check over normal, seven-byte and irregular packet boundaries. It
costs 1,184 bytes of `Connection.Internal`.

**23. The one-shot skip loop.** `skipCells` is a recursive one-shot loop, which
cuts a realistic drain's allocation by 31.4% and costs 1,288 bytes of `Value`.
A skip of 50 fixed-width cells, with nothing else in the row, allocates 14.7%
more; the tradeoff is noted beside the code. Wrapping the old `mapM_` whole in
`oneShotRecipe` allocated 95,998,888 bytes and was refused. Query's
`skipColumns` already delegates to `skipCells`.

**30. The lock boundary.** After idea 22, 100 bare executes allocated 1,226,696
bytes; OPAQUE on `withConnectionLock` lowered that to 1,213,896, 128 bytes per
request, and took 1,056 bytes off `Connection.Internal`. With idea 22, a request
without rows allocates about 16 bytes more than before the run.

**6. Named parameters.** The three-function `Calls` module was 2,067 bytes.
Moving the whole named mapping behind an opaque call took it to 1,931 bytes but
the 10,000-operation probe from 2,881,096 to 4,721,096 bytes; making only
`encodeNamed` opaque, 1,979 bytes and 3,681,096. Both rebuild existential
argument structure at run time to save little code.

**7. Procedure parameters.** NOINLINE instead of OPAQUE on `inParam` and
`outParam` grew `CallsProc` from 1,042 to 1,298 bytes, because the caller
rebuilds the worker's result. Standalone callers measured `executeMany` at 426
bytes, a tuple `bulkInsert` 530, and `queryS` with `S.length_` 733.

**8. The literal's lexing entry point.** An `Addr#` helper with a rule for
`lexPlaceholders (T.pack (unpackCString# addr))` left `Calls` at exactly 2,067
bytes: text's own literal rule fires before it can match, and the function that
unpacks directly is in text's hidden `Data.Text.Show`.

**9. `Text` literals.** Routing the procedure and name literals through an
opaque `String -> Text` helper took `CallsProc` from 1,042 to 706 bytes of code
but from 352 to 624 of data, and needs the callers or the public argument types
to change.

**29. Composing and lexing.** Merging adjacent literal pieces by appending their
text allocated 6,405,001,096 bytes against 2,011,521,096 for 10,000
constructions of about 1,000 pieces, because of the repeated copies. A first
`T.any (== '@')` scan saved 48 bytes per 100 KB query and adds a scan when there
are placeholders. The lexer's regression of the code-size run wasn't
reproduced: the code-size run changed only `Show` and `Eq` there, and two builds
of identical source already gave the lexer an allocation ratio of 1.114.

**31. Receive buffers** were already reused (above, "The transport, TLS and the
reader thread"). Reusing the storage under a returned `ByteString` would change
its ownership.

### The library and the link

**11. Split sections.** `{-# OPTIONS_GHC -split-sections #-}` on Linux in each
module (the `cabal check` rule doesn't see a pragma) took a small program from
17,227,345 to 15,363,665 bytes of `.text`, from 1,873,464 to 1,649,048 of `.data`
and from 29,505,696 to 26,296,392 bytes of file; hmssql's share of the link map
went from 1,943,112 to 715,153 bytes. `Catalog` and `Transaction` couldn't take
the CPP guard, because CPP changes their multiline string gaps. The owner then
chose to leave the setting to the application's build, so the pragmas were
removed; with them gone, the minimal application's `.text` is 0.45% below the
start of the run and its file 0.07%.

**12. tls and serialise.** The link map attributes 5,858,393 bytes of `.text` to
the eight packages named in the code-size run, though not all of it is
removable, since some have other dependents. A local fork of tls or a change to
its default instances would add maintenance without a measured gain at run
time; the reproduction and a proposal for tls are in
[upstream/tls-session-code-size.md](upstream/tls-session-code-size.md), not
submitted.

**13. Static `Show` names.** Constructor and field names are static `Addr#`
literals in `Hmssql.Internal.Derived`, which appends the literal directly to its
suffix. The library's `.data` went from 389,072 to 369,928 bytes, `.text` grew
by 184 bytes, and the output stayed identical (`InternalDerivedSpec`).

**19 and 20. Tools.** `scripts/code-size.sh --quick --check` holds both codecs
to 100 bytes per field and runs in the test matrix after each compiler's build;
a budget of one byte fails, as it should. The script works with Cabal's build
environment as well as Stack's, and counts split text sections rather than
reporting zero for them. The attribution and call-site tools joined `scripts/`
(`code-owners.py`, `code-inner.py`, `api-code-size.sh` and
`api-code-size-program.py`, `link-size.sh` and `link-map-size.py`); their first
readings were 88 bytes per literal `Query` and 762.6 per `mkQuery` with
`NamedParams`.

**35 and 38. Benchmarks.** The benchmark gained 7- to 12-tuples, a user
`refineField`, a real drain through `execute`, a callback per streamed row,
every `SqlValue` family of output parameter, and four cases that pin MARS over
TLS whatever the test environment says (`MarsTLS`). The wide tuples are wrapped
in newtypes, because this deepseq has tuple instances only up to nine. The
existing names were kept, so the 171 cases of the start stay comparable.

**36. Live bulk loads.** `scripts/live-bulk-resources.hs` loads 10,000 rows of
`(Int32, Text, Decimal)` over TLS ten times after a warm-up:

| Per 10,000-row load | Before the run | After |
|---|---:|---:|
| Allocated bytes | 85,651,131 | 85,410,612 |
| Live heap after a collection | 4,502,272 | 4,502,272 |
| Maximum live heap seen | 5,460,016 | 5,460,016 |
| Maximum RTS memory | 18,874,368 | 18,874,368 |

One early pair sampled a smaller peak on one side only; five more alternating
runs showed both binaries can sample either, so it wasn't a regression.
Callgrind counted 1,761,519,463 instructions before and 1,758,600,477 after for
the whole client process, setup and checks included. Of the second, 16.29% was
thunk-update frames, 10.94% one RTS application path, 6.32% evacuation, 4.63%
`lengthKind` and 3.13% `TypeInfo` equality: conversion, framing dispatch and
allocation remain substantial in the client, but the load's time is mostly the
server's.

### Compilers

**18.** GHC 9.6.6, 9.10.1 and 9.14.1 built the library with Cabal at `-O1`, with
dependency versions that differ between them (base 4.18 to 4.22, bytestring 0.11
to 0.12, text 2.1.1 to 2.1.4, and time 1.12 or 1.15), so these are complete
builds, not compiler effects in isolation:

| `.text` bytes | GHC 9.6.6 | GHC 9.10.1 | GHC 9.14.1 |
|---|---:|---:|---:|
| Library | 2,199,407 | 2,510,542 | 2,188,746 |
| Records and their `Generic` instances | 421,966 | 442,542 | 442,670 |
| Derived decoders | 98,920 | 79,088 | 79,088 |
| Derived encoders | 74,061 | 74,133 | 72,460 |
| Decoder bytes per field | 83.34 | 66.63 | 66.63 |
| Encoder bytes per field | 62.39 | 62.45 | 61.04 |
| A minimal linked Linux program | 2,179,157 | 1,040,469 | 990,747 |

All three are within the 100-byte budget. GHC 9.10.1's larger library is in a
few modules: `SqlType` 187,400 bytes against 79,945 on 9.14.1, and `BulkCopy`
232,449 against 177,357. Allocation per operation was within about 1.5% across the
compilers for encoding; for decoding, GHC 9.14.1 allocated least:

| Decoding, per dataset | GHC 9.6.6 | GHC 9.10.1 | GHC 9.14.1 |
|---|---:|---:|---:|
| `int bigint x10000` | 3,906,594 | 3,906,570 | 3,665,754 |
| `nullable half NULL NBCROW record x10000` | 10,646,676 | 8,084,668 | 7,630,884 |
| `50 columns x1000` | 11,470,908 | 11,470,884 | 11,443,604 |
| `tuple12 int x10000` | 9,004,488 | 9,004,464 | 7,893,664 |

The retained output stayed within 184 bytes across compilers. Two fixes to
`code-size.sh` came out of it: Cabal replaced the build plan with the default
compiler's unless `cabal exec` was also given `--with-compiler`, and exposing
dependencies by package name could pick another installed version (text 2.1.2
beside the selected 2.1.1 on 9.10.1), so the Cabal route uses its environment
and exposes only hmssql.

### Code layout and the short CJK case

The first timing checkpoint of the run found `Decode.text.utf16 CJK` 50 code
units 17% to 18% slower, with no change to the decoder. The object code of the
benchmark's driver (`Bench.Decode.o`) and of a standalone probe's `Main.o` were
byte-identical before and after, so the decoder's machine code hadn't changed;
`scripts/cjk-decode-probe.sh` builds that probe, over lengths 1 to 100 and
4,000, four CJK families with ASCII and Latin controls, and byte offsets 0 to 7,
with each timed action decoding 32 rotating buffers.

In the slow layout, the decoder's two hot six-byte conditional jumps were at
offsets 61 and 60 within a 64-byte block, so each straddled the boundary; in the
original binary neither did. An unrelated later change, the bulk error
formatter, moved them to offsets 29 and 28, and the short CJK ratio went from
1.169 to 0.998 without a change to the decoder. Controlled builds with
`-fproc-alignment=32` put the jumps at 13 and 12 in the formerly slow build and
45 and 44 in the fast one. Five alternating pairs, aligned over unaligned:

| Case | Formerly slow layout | Already fast layout |
|---|---:|---:|
| CJK, 50 code units | 0.803 | 1.005 |
| CJK, 4,000 code units | 0.839 | 1.004 |
| All 18 selected text and encoding cases | 0.975 | 1.012 |
| Allocation, every case | 1.000 | 1.000 |

So it was code placement, not the decoder. 64-byte alignment added more padding
and nothing for these jumps. The alignment was kept for a while on Linux x86-64
with GHC 9.12 and 9.14 only (GHC 9.14.1 emitted the same 2,639-byte decoder body
and was checked for layout, not timed; older compilers emit different loops),
and then removed on the owner's decision: a layout-dependent setting isn't worth
checking on every supported configuration, and the next layout may differ
anyway. Without it, the final run measured the two CJK cases at 0.980 and 0.975.

A rewrite of the store of a three-byte UTF-8 sequence, as disjoint 16-bit and
8-bit stores instead of one overlapping 4-byte store, looked 7% to 13% faster
on CJK until both variants were built aligned, when it was 3.9% to 6.2% slower;
it was refused. It and the decoder passed a reference corpus of 333,752 cases
(every BMP code unit, malformed and odd trailing input, shifted slices and chunk
cuts) at `-O0`, `-O1` and `-O2`, with its store helper INLINE and NOINLINE
(`scripts/optimization-decoding/utf16-modes.sh` and `Utf16Boundaries.hs`).

### The result

The final timing compared the end of the run with its start, five alternating
pairs on CPU 31, GHC 9.12.4, with the start's library built against the
expanded benchmark so that all 281 cases without a server compare; the 171
cases that existed at the start are also shown. This is the run as it stands,
with the split sections and the alignment removed:

| Workload | Cases | Time | Allocation |
|---|---:|---:|---:|
| The original cases | 171 | 0.999 | 0.990 |
| All cases without a server | 281 | 0.973 | 0.960 |
| Decode | 116 | 1.000 | 0.998 |
| Encode | 18 | 1.002 | 0.977 |
| Mock | 132 | 0.945 | 0.925 |
| Sql | 15 | 0.983 | 0.962 |
| Selected Live cases | 15 | 0.969 | 0.989 |
| MARS over TLS | 4 | 0.998 | 1.000 |

* The gains are the drains, where wide rows take about half the time:

  | Case | Time | Allocation |
  |---|---:|---:|
  | `Mock.query.50 columns x1000.drain` | 0.453 | 0.478 |
  | `Mock.query.tuple7 int x10000.drain` to `tuple12` | 0.46 to 0.55 | 0.43 to 0.49 |
  | `Mock.query.nullable half NULL NBCROW x10000.drain` | 0.600 | 0.650 |
  | `Mock.query.int bigint x10000.drain` | 0.675 | 0.696 |
  | `Sql.mkQuery.lex 20000 subtractions` | 0.825 | 0.600 |

* The largest regressions are within the noise of a 4 MB-scale or a small
  case: `Encode.large params.10 nvarchar(max) 100K chars` 1.230 and
  `nvarchar(max) 1M chars` 1.117, both with allocation 1.000, and
  `Mock.query.tuple7 int x10000.typed streamed` 1.106. No case allocates more
  than 1.005 times.
* Live, five pairs: the 10,000-row bulk load 0.952, 100 integer parameters
  0.936 in time and 0.962 in allocation, and the round trips 0.97 to 1.00.

| Compiled `.text` | Start | End |
|---|---:|---:|
| Library | 2,263,871 | 2,132,359 |
| Derived decoders | 79,088 | 79,088 |
| Derived encoders | 83,813 | 74,061 |
| Record definitions | 442,542 | 442,542 |

In the fixed-work decoder probe, allocation fell for the date and time dataset
(6,648,863 to 6,488,751 bytes) and held elsewhere, and the maximum live heap
stayed within 40 bytes of the start on every dataset. Process RSS moved by 0.96
to 1.03, so no saving in memory is claimed. The full suite passed at the end,
5,968 examples with none failing and 70 pending.

## Decoding interfaces

The first three were added on 2026-11-05 for programs that write values
straight out, each measured in `Bench.Decode` with GHC 9.12.4 before it was
kept; allocation is per 10,000 rows unless stated. The last is
older, measured before 2026-09-29.

* **A row known only at runtime.** A list's `traverse` with `RowDecoder`'s
  `Applicative` instance reaches the `cons` rule: ten `int` columns as
  `[Int32]` allocated 7.65 MB, and fifty `SqlValue`s 11.43 MB per 1,000 rows
  against `sqlRowDecoderFor`'s own loop's 11.50 MB. A `traverseRow` that
  compiled each element once and ran the recipes through the shape's own
  `traverse` allocated the same for a list (7.64 MB) and more for a
  `Data.Sequence` (9.1 MB against 7.6 MB), and was left out. `byColumn`, which
  chooses each column's decoder by its metadata, took fifty `SqlValue` columns
  from 11.43 to 7.99 MB per 1,000 rows.
* **An application's decoder on the built-in row path.** Two integers through
  `fieldDecoderFor` allocated 4.9 MB by `singleField`, 4.0 MB by `inlinedField`
  and 3.5 MB for the built-in `fieldRowDecoder`. Two nullable ones, half the
  rows NULL in one column or the other: 5.0 MB by `singleField . nullableField`,
  5.2 MB by `inlinedField . nullableField` (the OPAQUE `nullableField` makes the
  copy call the conversion unknown and box the `Just`), and 4.1 MB by
  `inlinedNullableField`. The cost is code: in a module of NOINLINE bindings,
  each distinct integer decoder was about 3,530 bytes of object code by
  `inlinedField`, 2,940 by `inlinedNullableField` and 650 by `singleField` of
  `nullableField`. Inlining doesn't pay for a large conversion: a `datetime2`
  and a `datetimeoffset` into a strict record of their parts allocated 5.1 MB by
  `singleField` and 5.6 MB by `inlinedField`, against 5.5 MB for the built-in
  `(LocalTime, DateTimeOffset)`.
* **A date or time from its parts.** `dayTimeFieldDecoder` and its siblings
  inline the reader, so the application's function inlines into it. With the
  readers out of line and given the function, the same record allocated 5.9 MB
  through `singleField` and 6.3 MB through `inlinedField`, against 5.1 and
  5.6 MB, because the function was then an unknown call with a boxed result.
* **Type checks over `SqlDataType`.** A micro-benchmark of the monadic row
  decoder, which recompiles every field on every row (five columns, two million
  rows, typed and `sqlRowDecoder`), showed allocation unchanged to the byte and
  time within a few per cent when the checks became predicates through
  `typeInfoDataType`, because GHC folds the two matches into one jump table
  over `TypeInfo`. Building a `SqlType` allocates, so decoders don't call
  `typeInfoSqlType`.

## The size breakdown, 2026-11-08

**Question.** A first program (connect with TLS, one `query` into
`[(Int, Text)]`, print) built with plain `ghc` was 35 MB, 23 MB stripped,
and hmssql's code was about 41% the size of the TLS stack's. How much of
hmssql is its feature set, its instances for built-in types, code compiled in
the library on applications' behalf, and inlining? Is there a cut with no
cost at run time?

**How it was measured.** GHC 9.12.4 and the stack snapshot of the time, on
Linux. The library was built with `-fexpose-internal-symbols -ddump-stg-final
-ddump-to-file`, and each symbol's bytes up to the next symbol were charged to
the top-level binding whose STG defines it; 97% of the 2,185,455 bytes of
`.text` found an owner. `scripts/code-owners.py` reported every symbol as
unowned here, because GHC 9.12's dump puts a binding's type and its
`[GblId]` on lines of their own. The program was linked against the
library with `-Wl,-Map` and attributed with `scripts/link-map-size.py`, as in
the code-size run.

**The program.** 17,124,945 bytes of `.text`, of which hmssql 1,891,496 (11%).
The TLS stack (tls, crypton and its C, random, crypton-x509 and its
validation, time-hourglass, asn1 and mlkem) is about 5 MB, and the eight
packages behind tls's `serialise` dependency are the largest share again
(vector alone 3.28 MB). A hello-world from the same compiler is 1.3 MB, 1.0 MB
stripped.

**The library by kind,** in bytes of `.text`; the kinds overlap where noted.

| Kind | Bytes | What |
|---|---:|---|
| Features linked only when used | 292,000 | `BulkCopy`, `Catalog`, `BatchQuery` and `Transaction`, none of which the program linked, even unsplit |
| `Hmssql.SqlType`, linked into every program | 74,095 | The decoders' type checks name `SqlDataType`'s constructors, so the whole module was linked |
| MARS | about 50,000 | `Tds.Smp` and the SMP parts of `Connection.Internal`; procedures, `sql_variant` and Entra ID tokens are a few KB each |
| The built-in types' field and row decoders | 224,344 | 23 row decoders of about 4.7 KB each and the out-of-line field decoders (track A2) |
| Encoders and `SqlValue` | about 45,000 | Of which the `ToSqlRow` tuples are about 10 KB; `tuple3` to `tuple12` on the decoding side are under 200 bytes each |
| `lift3RowCalled` to `lift12RowCalled` | 65,296 | `lift12RowCalled` alone 25,576 |
| Derived and hand-written `Show`, `Eq`, `Enum`, `Generic`, `Exception` and `Typeable` | 174,152 | `Eq` on the wire types is about 30 KB; kept, since applications may compare them |
| Record field selectors | 43,080 | 358 fields at about 120 bytes each |

**Inlining.** With every `INLINE` pragma removed, the library's `.text` went
from 2,195,125 to 1,740,265 bytes (−455 KB, 21%): `Decoding` 310 KB, which is the
bodies of the per-type decoders and the lift functions above, then `Scalar`
31 KB, `Value` 29 KB, `Token` 24 KB, and `Parser`, `Query` and `Primitives` about
10 KB each. Those pragmas are on the reader paths the earlier runs tuned, and
this build wasn't timed.

**The cut kept.** `SqlDataType` and `typeInfoDataType` moved to
`Hmssql.Internal.SqlDataType`, which `Hmssql.SqlType` re-exports; `Decoding` and
`Tds.Scalar` import the small module. `SqlType.o` went from 74,095 to 59,783 bytes
of `.text`, and the new module is 15,271. The program no longer links
`SqlType.o`: its `.text` went from 17,124,945 to 17,067,601 bytes (−57,344), its
three main sections from 19,536,319 to 19,465,503 (−70,816), and its file from
29,423,296 to 29,306,376 (−116,920). Nothing on the row path changed, since
`typeInfoDataType` stays INLINE.

**Not cut.** Every larger item above is a measured trade recorded earlier in
this document: A2's per-type decoders (200 KB for a third less allocation per
typed query), `lift12RowCalled` (split, it allocated more), and the INLINE
pragmas of the reader paths.

## Where things stand

Against the start of the code-size run:

| Measure | Start | Now |
|---|---:|---:|
| Decoders of the 50-record program | 29.9 MB, 617 s to compile | 79 KB, 1.2 s |
| Encoders of the same | 583 KB | 74 KB |
| The library's `.text` (from the code-size run's round 2) | 2.55 MB | 2.13 MB, with 200 KB of per-type decoders |
| A minimal program, linked, every package split | not measured | 4.8 MB |
| `Mock.query` typed `int bigint`, per query | 3.66 MB | 1.89 MB |

The last pass against the original row walk was at the end of the code-size
run, before the per-type decoders: 1.124 overall, Live 1.011, Mock 1.105 and
Decode 1.383.

Ideas on the list that weren't measured or remain open:

* **The table of boxed positions costs Decode time** (two dependent loads per
  lookup); a smaller table was refused (idea 27), and boxes only where a call is
  known to be cold weren't tried.
* **A cell's slice** for conversions other than the built-in types' (idea 21)
  stays, by design.
* **Track A2's per-type decoders under split sections,** where a program links
  only the types it uses.

## Not verified

* Timing on any compiler but GHC 9.12.4. The code size and allocation were
  measured on GHC 9.6.6, 9.10.1 and 9.14.1; GHC 9.8 wasn't measured, and the
  RULES of R3c and the strict bindings that guard against GHC 9.14.1's floating
  were checked for speed on 9.12.4 only.
* macOS and Windows for code size and linking (`ld64` with `-dead_strip`, and
  the Windows linker), where split sections differ.
* The speed of a hand-written decoder at `-O0` beyond the two decoders of idea 10.
* Live bulk loads and the other Live and Mars cases beyond the runs above.
