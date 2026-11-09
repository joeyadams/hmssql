# Value streaming research record

Value streaming replaced the row walk with reader recipes, so that any column
of a result and any parameter of a request can stream, on one code path. This
is the record of that rewrite's evidence: why the row walk was replaced, what
the earlier attempts taught, what each optimization of the new code measured
when it was removed from a scratch build, what was rejected, and how far the
result is from the row walk's speed. The contract is in
[design.md](design.md), under "Reading and writing bytes: which layer",
"Decoding" and "Memory and performance"; the server facts measured for the
design are below and, by area, in [protocol-notes.md](protocol-notes.md); and
the work on code size and speed that followed, from 2026-11-04, is in
[performance-research.md](performance-research.md).

## How the work went

* **Two earlier attempts** in October 2026 built value streaming on the row
  walk's resumable reader. Their code is on the local branches
  `value-streaming-cursor-attempt` and `value-streaming-simple-reader`, which
  exist so tests and benchmarks can be salvaged from them. The owner rejected
  both for their shape: each grew the reader's eleven-field record, first into
  twelve mutable registers and then into a thirteen-field record.
* **The server probes** ran on 2026-10-31 against SQL Server 2025 RTM-CU10
  (17.0.5035) on Linux, locally ("The server probes", below).
* **The implementation** (Codex with parallel subagents, 2026-11-01) wrote
  the reader recipes, the value streams in both directions and Builder writing,
  from a plan that set the shape and the rules and measured nothing about the
  new code. Two reviews followed the same day, each implemented in full, and
  then the removal measurements and a bounded optimization round. The owner
  paused the work on 2026-11-01 with the original speed not reached.
* **The optimization candidates after the failure channel** (Claude Opus 5.5,
  2026-11-03 and 2026-11-04) took allocation profiles with ticky first and
  benchmarked once at the end.

All of it ran on one 32-core Linux workstation (an AMD Ryzen 9 9950X) with
GHC 9.12.4. Every comparison is between saved benchmark executables, run with
nothing building, pinned to one CPU, with `+RTS -N1`, and mostly `--stdev 15`
and `--timeout 20s`; a pair is one run of each executable, and two or more
pairs alternate them (ABAB). Ratios are geometric means of each case's
new/old ratio. The benchmark cases are the existing ones, and no case was
added for the work: 118 cases in `Decode`, `Encode` and `Mock.query`, or all
225 when the server groups ran too.

"The original" below is the row walk as it stood on 2026-10-31, before the
rewrite. The checkpoints of the rewrite are named for what they contained.

## Why the row walk was replaced

**Question.** Was the row walk, with its resumable reader beside it, the place
to build value streaming?

**Answer, from the plan and the attempts.** No. Measured on the row walk at the
start:

* The walk produced a view, an array of offsets and lengths per row, and the
  decoders then read the view, so each row was traversed twice. On 10,000
  `(int, bigint)` rows the walk alone took 3.5 MB of the typed decoder's 5.2 MB
  and 386 µs of its 695 µs (`Decode.int bigint x10000`, `rows` against
  `typed`).
* The attempts read each cell as it was found and, even with the machinery
  they carried, took typed decoding to 0.48 to 0.78 of the walk's time and
  0.31 to 0.55 of its allocation. Reading a cell where it is found was sound;
  the control block was what made it look expensive.
* The resumable reader (`RowReader`) inverted the control flow: fed a chunk, it
  had to return wherever the chunk ended, so its column, phase, bitmap and the
  carry of a delimiter cut by a chunk's end were stored by hand in an
  eleven-field record that mixed four lifetimes. Its linearity was a runtime
  check, a shared counter of feeds and an `ErrorCall`, where a continuation has
  no state to protect.
* `RowReader` always assembled a whole row, so a drain couldn't skip a value:
  draining a 16 MiB value allocated 44 MB through the mock server and 92 MB
  from the local server.
* There were three parsers of one wire format, `parseRowAt` walking rows inside
  a buffer, `RowReader` resuming across buffers and the `Get` parser
  `getToken`, held together by `Wire.TokensSpec`, and `joinRow`, the coalescing
  limit and the re-walk existed to choose between them.
* The speed rested on folklore: three inlining rules, each of which cost 16 to
  32 bytes per cell when broken and showed only in the allocation column; a
  loop that GHC 9.12 compiled into a second boxed copy when an NBCROW NULL was
  tested by a guard; and `-O2` on some modules only, because library-wide `-O2`
  made the token parser 12 to 20% slower.

**What the implementation did.** One parser module (`Hmssql.Tds.Parser`) owns
the buffer, tokens and values are recipes over it, a compiled row decoder reads
the recipes directly, and a drain skips values without assembling them. The
reasons a mutable control block costs more under GHC than it seems to are in
design.md, "No control blocks".

## The server probes

**Question.** What does the server accept and do when values stream, in either
direction? Measured on SQL Server 2025 RTM-CU10 (17.0.5035) on Linux, locally,
on 2026-10-31. SQL Server 2017 to 2022, Azure, Windows and a real network were
not measured.

| Question | Answer |
|---|---|
| A PLP parameter of unknown length in an RPC | Accepted in 288 of 288 RPCs: `varbinary(max)`, `nvarchar(max)` and `xml`, through `sp_executesql` and a procedure call, among small parameters, at packet sizes 512, 8000 and 16384 (negotiated to 16192), plaintext and strict, with and without MARS. A first packet ID of 1 is accepted. |
| A chunk boundary inside a code unit, sending | Harmless, because the server joins chunks first. An odd `nvarchar(max)` total gets error 8028, class 16, and the connection stays usable, so the client checks before the terminator. |
| A source failing part-way | The connection survives an Attention after a cut-off message, 2,400 of 2,400, RPC and batch, at 1 packet, 2 packets and 200 MB. The answer is a DONE with DONE_ERROR, then a separate DONE_ATTN message. RESETCONNECTION on such a message is carried out (40 of 40, without MARS), and a lone Attention was acknowledged 800 of 800, under 0.1 ms median. |
| A cut-off RPC in a transaction | It can roll back an open transaction with `XACT_ABORT` off, by error 4002 or 3980 and a rollback ENVCHANGE, depending on the cut position, with no rule a client can use; a batch never did in 200 positions. So a body that catches its source's exception either commits or gets `TransactionEndedEarly`, and the tests accept both. |
| An answer before the message ends | None: the server reads the whole message first (500 MB tried, with several kinds of error). No write deadlock is possible, and a slow source delays the earlier statements of its own message. |
| A stall | An unfinished message, and a row half read, both survive at least 15 minutes, plaintext and strict, with and without MARS. So the Haddock's warning is about the client's lock and transaction locks, not a server timeout. |
| Past 2^31-1 bytes | A parameter isn't limited: `DATALENGTH` returned 4294967297 for 4 GiB + 1, and `SELECT @a` returns it with a PLP total of 0x80000001, so a reader takes totals past 2^31-1. Storing it gets error 7119, class 16, and the connection survives. |
| A message ending inside a value | Never seen: 324 trials with 64 MiB values all ended at a token boundary, so it stays a `ProtocolError`. After an Attention the server finishes the whole row, later values included. |
| Wire shapes | `json` is `varchar(max)` under a UTF-8 collation with an unknown total, `xml` has an unknown total, and the other `(max)` types a known one. An empty value is a total or marker and a terminator with no chunk. PLP chunks end at packet ends, can be odd in `nvarchar(max)`, and can split a surrogate pair or a UTF-8 sequence, so the streaming text decoders hold bytes back. NBCROW appears on TDS 7.4 only, and NULLs appear in ROW too. |
| Bulk copy with streams | Several unknown-length values in a row work. An over-long value is refused by error 2628 with `ANSI_WARNINGS ON` and cut silently with it `OFF`, as a plain `INSERT` is; either way, trailing blanks and zeros past the width are dropped, and a character outside the code page becomes `?`. |

**What the implementation did.** Unknown-length PLP is how a stream is sent,
and the send path needs no reading while it writes. A streamed bulk cell isn't
checked by the client: it behaves as `INSERT` does under the session's
`ANSI_WARNINGS`, which is on by default on a new hmssql connection
(`SESSIONPROPERTY` read 1 on plain and MARS connections and after a reset).

In protocol-notes.md, by area: the whole message read before an answer, and
cut-off messages and the Attention after one, under
[Framing and packets](protocol-notes.md#framing-and-packets); a message never
ending inside a value under
[Tokens and ENVCHANGE](protocol-notes.md#tokens-and-envchange); a cut-off RPC
rolling back a transaction under
[ALL_HEADERS and transactions](protocol-notes.md#all_headers-and-transactions);
unknown-length PLP parameters, totals past 2^31-1 and the wire shapes under
[Data types, On the wire](protocol-notes.md#on-the-wire); and streamed bulk
values and `ANSI_WARNINGS` under [Bulk load](protocol-notes.md#bulk-load).

## What the earlier attempts taught

Traps that cost the attempts time, none of them visible in the source:

* **A lazy result in `IO` is a thunk per cell.** `pure (f x)` at the end of a
  per-cell reader allocated 260 to 400 bytes a cell, held the packet slice
  until forced, and made wide rows 3 to 6 times slower. The application
  module's Core looked clean, because the thunk was inside the library's
  worker. A reader returns `case` with `pure` in each branch, or binds `let !r`.
* **A held value is retention.** A last-value slot in a reader kept two rows'
  values alive, 271 MB against a 201 MB limit, seen only in `Scale.HugeBinary`,
  which runs with the slow tests.
* **A row can end exactly at a packet's end.** Asking for a byte before the
  delimiter needs it waits for a packet that may never come, or after an
  Attention turns into a `ProtocolError`. A recipe asks only for what the
  wire form requires.
* **An NBCROW bitmap can be cut by a packet boundary,** as can every
  delimiter, so the wire tests cut at every byte, at packet sizes 512 and 8000.
* **On MARS, a response that has fully arrived and is abandoned stays open on
  its session** unless something marks it for draining.
* **`executeMany` retained a lazy parameter** of 250 MB in a state thunk over
  the parameters.
* **A heap test proving non-retention has to keep the holder alive across the
  send.** Otherwise GHC's liveness analysis lets go, and the test passes with
  the reference still in the code. Heap tests are also `serial`, so other
  specs' readings don't overlap theirs.
* **`utf16Length` scanned a whole `Text` per batch,** which took a
  1M-character batch to 2.3 times the baseline. A batch's length limit is
  computed without walking it.
* **A `Request` holding a lazy or stream value can be sent once,** and a
  second send is an `EncodeError`, while a `Query` can be sent again.

**The generic cell interface.** In the attempts, nested streams with the lock
taken per pull (`queryCells`) took 2.7 times the time and 3.7 times the
allocation of typed reading on rows of small columns, were about even at 1 MiB
values, and were much better at 256 MiB: 272 ms with nothing live, against 500
ms and 269 MB. The owner had hoped the generic interface would suit generic
applications better, but a port of one path of the OData demo to it was 40
lines against 3, with no gain on small rows. It wasn't kept, and the recipe
design didn't optimize `queryCells` for small values.

## What the implementation found

* A stored phase and column position duplicated the parser's continuation and
  mixed result metadata, partly built values and the input position, which
  have different lifetimes. In a recipe they are separate: the metadata is
  captured when the row decoder is compiled, a partly built value is in the
  continuation, and the position is an argument. Assembling a whole value,
  streaming its slices and skipping it share one description of the value's
  envelope.
* An endless metadata list exposed quadratic work per suspension, because each
  item left a pending list constructor around the next read. Repeating the
  metadata read tail-recursively fixed it without a stored phase.
* Skipping rows and discarding a response are different: a procedure's output
  parameters must survive the first even when their values cross packets.
* A parity thunk and a lazy cache of statement shapes could each retain an
  entire earlier parameter (both are in [bugs-found.md](bugs-found.md),
  "Memory and performance"). Only names, types and continuation state already
  consumed belong in such caches.
* The tests of the deleted coalescing limit and of the fixed-token fast path
  described algorithms that no longer exist. Their wire claims are covered by
  generated expected tokens, input split and truncated at every byte, checked
  codecs, and connection-level tests of malformed input. A `Get` adapter in the
  test tree interprets recipes for the existing assertions; it is not an
  independent wire parser.

## The reviews

Two reviews read `hmssql/src/` on 2026-11-01, the first against the initial
implementation and the second against the code with the first review's fixes.
Their two defects (an interrupted consumer waited for the rest of its row, and
`cellDecoded` ignored the connection's context) are in
[bugs-found.md](bugs-found.md). Every finding was implemented, and the owner
ruled that a cleaner shape could cost speed; no finding was accepted or refused
on a benchmark. Three findings are relevant here.

* The first review's fixes and the first optimizations were committed
  together, so the effect of each optimization couldn't be attributed. The
  second review asked for each to be measured by removing it from the cleaned
  code, and removed if it added more than about 20 lines without moving a
  common-case benchmark by 10% in time or 20% in allocation (the rule now in
  design.md, "How an optimization is kept local").
* `withSqlValueReader` selected a `SqlValue` reader in continuation-passing
  style, with INLINE on it and on two callers, so all thirty branches were
  copied into each use. It became a data constructor, `SelectedReader`, with
  the pragmas removed.
* The private parameter queue (`consuming`, an `IORef` of the remaining
  parameters) gave no protection that `forM_` over the list doesn't; the
  guard that matters is the `Request`'s single take. The owner chose `forM_`.

| Comparison, 118 cases, one pair | Decode time | Allocation | Encode time | Allocation | Mock.query time | Allocation |
|---|---:|---:|---:|---:|---:|---:|
| After the first review against the first implementation | 0.944 | 0.914 | 1.126 | 0.979 | 0.929 | 0.837 |
| After the second review against before it | 1.052 | 1.040 | 0.985 | 1.002 | 1.097 | 1.132 |

`SelectedReader` alone, over the 22 `SqlRow` cases at `--stdev 10`: Decode
1.106 in time and 1.088 in allocation, Mock.query 1.132 and 1.106. A typed
`Mock.query.int bigint x10000.SqlRow` went from 1.244 to 1.610 ms and from
6.15 to 7.59 MB. The change was kept, and no pragma was restored.

The first-review binary was saved before its source was committed, so its
source was reconstructed later on a separate branch from the saved patch. A
fresh build of the reconstruction allocated within 0.02% of the saved binary
on all three groups, but it isn't claimed to be the exact build input, and its
timings, run on another day, aren't a comparison.

## The optimizations, measured by removal

**Method.** Each optimization that came in with the review fixes was removed
on its own from the cleaned code (after the second review's findings and the
owner's `forM_` decision), so that each variant differed from that baseline by
one feature, and its tests passed before timing. Two on/off pairs ran per
feature, on the cases each feature could affect:

| Scope | Benchmark filter |
|---|---|
| Reader representations and field compilation, 58 cases | `(/Decode/ \|\| /Mock.query/) && (/typed/ \|\| /SqlRow/)` |
| Scalar selection, 22 cases | `(/Decode/ \|\| /Mock.query/) && /SqlRow/` |
| First PLP fragment, 20 cases | `(/Decode/ \|\| /Mock.query/) && (/short x10000/ \|\| /4MB x1/)` |
| Writer allocation and prefix fusion, 21 cases | `/Encode/ \|\| /Mock.round trip/` |

A saving is `1 - on/off`, so a positive number means the optimization helps.

| Optimization | Cases | Time saved | Allocation saved | Decision |
|---|---:|---:|---:|---|
| The parser's immediate result as an unboxed sum | 58 | 6.48% | 13.80% | Kept |
| `Recipe env`, a read-only environment carrying the NBCROW bitmap | 58 | 5.90% | 6.98% | Kept |
| Separate borrowed and owned conversions in `CellDecoder` | 58 | 2.66% | 2.23% | Kept |
| A field decoder's metadata continuation | 58 | -1.41% | -0.05% | Removed |
| The first PLP fragment kept borrowed | 20 | 17.66% | 21.72% | Kept |
| A small first packet buffer | 21 | 1.81% | 9.66% | Kept |
| A parameter's prefix fused into its Builder | 21 | 4.81% | 4.44% | Kept |

The common case of each, on and off, as the geometric mean of two runs each
(time in µs, allocation in bytes per run):

| Optimization and case | Time on / off | Allocation on / off |
|---|---:|---:|
| Unboxed result: `Mock.query.int bigint x10000.SqlRow` | 1654.9 / 1894.7 | 7,592,713 / 11,032,246 |
| Environment: `Mock.query.nullable half NULL NBCROW x10000.SqlRow` | 3726.2 / 4642.5 | 14,788,486 / 19,640,477 |
| Two conversions: `Mock.query.int bigint x10000.typed` | 894.7 / 967.5 | 4,534,993 / 5,492,749 |
| Borrowed fragment: `Decode.nvarchar(max) short x10000.typed` | 1529.3 / 5363.0 | 9,761,250 / 42,561,002 |
| Small buffer: `Encode.SELECT 1 batch` | 0.184 / 0.213 | 1,326 / 5,135 |
| Prefix fusion: `Encode.100 int parameters` | 21.515 / 25.200 | 157,158 / 181,584 |

* **The unboxed result** saves the control constructor when a selected recipe
  can't inline, 31% of the allocation of a `SqlRow` of two integers.
* **The environment** saves rebuilding the row's field recipes for each
  bitmap, 25% of a nullable `SqlRow`'s allocation.
* **Two conversions** keep the ownership wrapper from escaping into scalar
  conversions: 17% less allocation for typed integer pairs, for nine more
  source lines than one conversion. Its time pair ranged from 2.5% to 12.3%,
  so no claim on time is made.
* **The borrowed first fragment** avoids building and copying an accumulator
  for a short `(max)` value, 77% of the typed case's allocation.
* **The small first buffer** (256 bytes, grown to the packet size when
  needed) saves 74% of `SELECT 1`'s allocation.
* **Prefix fusion** removes a writer entry per parameter, in fewer lines than
  separate writes, and saves 14.6% of the time and 13.5% of the allocation of
  100 parameters.
* **The metadata continuation**, a rank-2 layer through which a field decoder
  received its column's metadata, was removed. When it was added, before the
  second review, wide typed queries were 14.5% faster with it, at about 2 MB
  more of `Decoding`'s object code; after `SelectedReader` it saved nothing,
  and no case moved by 10% in time or 20% in allocation.

None of these is faster everywhere. On `Decode.nullable no NULL ROW
x10000.typed` the unboxed result took 12.8% more time and 3.9% more
allocation, and the environment took 8.1% more time and 7.1% more allocation
on short PLP typed decoding; the others have small regressions in some cases.

## The bounded optimization round

From the retained combination, three candidates and a pragma were built and
compared in two pairs each, on the 2026-11-01 code.

* **Checked `splitAt` in `bytesValue`,** in place of a `take` and a `drop`
  that each compared the boundary: kept. Allocation was unchanged, and time
  over 100 cases was 0.990 and 0.992, Mock.query 0.985 and 0.984. A small
  library cleanup, not a speedup.
* **Balanced tuple composition** for 3- to 12-tuples, with `liftA2` over
  smaller tuple decoders instead of function-valued intermediates: kept then.
  The nullable typed cases were 0.85 to 0.96 in time and about 0.98 in
  allocation, the folded nullable Mock case 1.004 in allocation, and the
  aggregate over the 58 reader cases 1.016 and 0.990; `Decoding`'s object was
  4.75% smaller. The code-size run of 2026-11-04 replaced it with the lift
  functions (performance-research.md, "Allocation: unknown calls and their
  arguments").
* **The request header fused into the first parameter,** first version:
  refused. Its helper passed a prefix argument to every later parameter, about
  80 bytes each, so 100 and 2,000 integer parameters allocated about 5% more and
  took 6 to 11% longer.
* **The same, corrected** (`rpcParamHeader` defines a parameter's header once
  for the pure body builder and the sender, only the first parameter takes the
  request header, and the rest go through `forM_`): kept. Allocation 0.965 for
  a one-integer request, 0.999 for 100 parameters, 1.000 for 2,000 and 0.988
  for statement batches, for one definition of the header. Time was
  inconclusive: the writer group was 1.128 and 0.993, with unchanged framing
  cases varying by several times between pairs.
* **INLINE on `sqlValueDecoder` alone:** refused. Over the 26 `SqlRow` and wide
  cases, time was 1.001 and 1.015 and allocation unchanged.

Three further directions were decided without a build:

* **A strict-only RPC sender** through `rpcRequestBuilder` would restore
  separate traversals for strict and streamed parameters, which the one-sender
  design rejects whatever it would save.
* **`keepBytes` in the raw-row getters,** with borrowed `ValueBytes` stored in
  each cell: refused by reading. A raw row's cell holds a lazy owned copy that
  `rowCellLength` or the first getter forces and later accesses reuse; storing
  borrowed bytes would make a fresh copy on every access and keep the packet
  alive after the values were forced. Caching lengths beside the owned thunks
  would add metadata per cell and wasn't evaluated. (The raw-row length
  benchmarks force these copies; their comment saying otherwise was corrected.)
* **`-O2` on `Hmssql.Decoding`** never produced an executable: the compiler
  passed an 8 GiB cap on its memory after 24 s (8,981,888 KiB) and was stopped.
  `-O2` on `Hmssql.Tds.Parser` and on `Hmssql.Tds.Value` was measured later
  (below).

The session's notes also list directions that were tried and didn't justify
themselves, with no numbers recorded: a runtime CPS parser, boxed and unboxed
offset cursors, extra writer wrappers, INLINE on `writeBuilder`,
`-fno-full-laziness`, conditional applicative helpers, changes to tail
bindings, and saturated combiners.

**What hpgsql's parser history measured.** The recipe design leaned on hpgsql.
Its `Hpgsql.SimpleParser`, 263 lines and a newtype over a function to a strict
result sum, began in continuation-passing style to beat attoparsec by 12 to 15%,
gained about 14.3% in time and 6% in allocation once `RowDecoder`'s `(<*>)` was
INLINE, and about 4.7% more when it left CPS, with fewer lines. Specialised row
decoders gained about 16% there, and one removal of a specialised decoder
accepted about 0.9% slower decoding for 77 fewer lines. hpgsql never parses a
partial message, because a PostgreSQL message carries its length, so its numbers
say nothing about the cost of suspension, which TDS requires: a row has no
length, and a value can be 2 GiB.

## Against the original, 2026-11-01

Two pairs of the 118 cases, the original against the retained combination
and then against the code with checked slicing and balanced tuples (new over
original):

| Group | Retained combination, time | With slicing and tuples, time | Allocation |
|---|---:|---:|---:|
| Decode | 1.624 / 1.619 | 1.593 / 1.630 | 1.337 |
| Encode | 1.267 / 1.177 | 1.184 / 1.093 | 1.265 |
| Mock.query | 1.623 / 1.538 | 1.570 / 1.509 | 1.442 |
| All 118 | 1.564 / 1.523 | 1.517 / 1.506 | 1.350 |

On the retained combination, a typed nullable Mock query was about 2.6 times
the original, the 50-column typed case 2.1 to 2.3 times, and the two 4 MB typed
cases 1.04 to 1.13.

### Full-suite comparison

The first pass of all 225 cases, at the corrected header fusion against the
original, one pair at `--timeout 30s`:

| Group | Cases | Time | Allocation |
|---|---:|---:|---:|
| All | 225 | 1.300 | 1.297 |
| Decode | 72 | 1.608 | 1.337 |
| Encode | 18 | 1.098 | 1.259 |
| Live | 62 | 1.098 | 1.331 |
| Mars | 24 | 1.107 | 1.220 |
| Mock | 34 | 1.533 | 1.387 |
| Sql | 15 | 1.025 | 0.987 |

* Against a real server the time gap was about 10%: `Live.decode 10000 rows`
  1.01 to 1.10, `Live.query.int bigint x10000.typed` 1.12, and its `SqlRow`
  1.73. The round trips were faster than the original's, which suggests drift
  between the two runs.
* `Decode.*.rows`, at 4 to 24 times the original, is not like for like: the
  original only found each cell, and the recipe reads the whole token.
* `Encode.bulk.bulk load 1000 rows framed` was a real regression, 66 to 232 µs
  and 179 to 1,460 bytes per row, from a Builder per row where the original
  poked. Poked rows came back with the candidates below.
* Comparing a binary with itself in this harness moved cases by 0.96 to 1.06,
  with one outlier at 1.52, so one pair says nothing inside that band.

Two changes then removed unsafe memory work, and both stay for that reason:

* **`PacketBuffer` went** (design.md, "Who owns a packet's bytes"). Its cost,
  one copy per packet on MARS over TLS, had no benchmark until the MARS-over-TLS
  cases of the second optimization run (performance-research.md).
* **`Hmssql.Tds.Bytes` stopped using `runRW#`,** which its own comment called
  `unsafeDupablePerformIO` without `lazy`, and assembles values after one
  bounds check. Two pairs against the binary before: Decode 1.027 in time and
  1.000 in allocation, typed Mock.query 1.040 and 1.000.

Two trials of a different representation were refused:

* **Staging `FieldDecoder` and `RowDecoder` as an existential selection and a
  read function,** so that a typed row inlines into one function. One pair:
  Decode 1.20 in time and 1.22 in allocation, Mock.query 1.19 and 1.28, typed
  `int bigint` 1.58 and 1.81. Once a row inlines, each bind's continuation is
  used in the completed branch and captured in the suspended one, so Core makes
  it a heap closure per bind, which costs more than a closure compiled per
  column.
* **Two readings of one recipe,** one giving up at the end of the buffer with
  nothing captured and one able to suspend, restarting a cut row from its
  bytes. On top of the staging, one pair: Decode typed 1.97 in time and 2.13 in
  allocation. A `Recipe` that is a record of two functions stopped GHC fusing
  it, and this wasn't investigated further.

Caching each bulk column's encoder per batch was refused too: allocation rose
3%, and time stayed within the noise. The same 225-case pass after these
changes (one pair, new over original): All 1.315 and 1.294, Decode 1.615 and
1.337, Encode 1.188 and 1.258, Live 1.149 and 1.328, Mars 1.128 and 1.228,
Mock 1.458 and 1.387, and Sql 0.983 and 0.955.

## Optimization candidates after the failure channel

On 2026-11-03 and 2026-11-04 a session worked through a card of eleven
candidates, starting from the failure channel (a failed row's result carried
in the parser's third branch rather than an `Either` per cell; design.md,
"Decoding"). It took ticky profiles of the target cases first
([testing.md](testing.md), "Where a benchmark allocates: ticky"), and checked
each change with ticky before committing it. Two findings changed the plan:

* GHC eta-expanded every row's preparation into a per-row function, which no
  candidate had named.
* A typed decoder's closures show under the module that names its row type
  (`Bench.Tokens`), so a profile of `Hmssql.Decoding` alone had suggested the
  typed path was already lean.

Allocation by ticky, per row or per query, before and after each change:

| Candidate | What was done | By ticky | Decision |
|---|---|---|---|
| 1. `SqlRow` as a loop | One recursive recipe over the columns' compiled recipes, built whole before the row's closure | With 3 and the `Prepared` row, a `SqlRow` cell went from 144 to 64 bytes | Kept |
| 3. Fewer wrappers per cell | `singleField`'s failure handler built once per column, and `Parser.convertBytes` giving a cell that lies in the buffer straight to its conversion | 144 to 96, then 96 to 64 bytes per `SqlRow` cell | Kept |
| Not on the card | A row's recipe prepared behind `Prepared`, which GHC can't eta-expand past | Typed `(Int32, Int64)` in `Mock.query` from about 450 to 305 bytes per row (4.9 to 3.5 MB per query) | Kept |
| 4. The delimiter chosen per column | The shape matched once per column | Nullable `Mock.query` 11.0 to 9.9 MB per query, fixed-width unchanged; `Bench/Tokens.o` 0.86 to 2.03 MB and the benchmark binary 36.6 to 46.3 MB | Reverted for the code size |
| 5. `Maybe` without two boxes | Not built | A `Right` and a `Just` per non-NULL value, about 40 of 1,100 bytes per nullable row; removing them changes the public `CellDecoder` | Dropped |
| 6. The batch loop | Not built | The driver allocates three list cells per row and nothing else, and the batch is a public list in order | Dropped |
| 7. Tokens that aren't rows | `runParser` first in `startToken` | 7,975 to 7,883 bytes per `execute`, time unchanged | Reverted |
| 8. A raw cursor | The input as the three unboxed fields of its `ByteString`, in `Result` and `Recipe` | Typed `Mock.query` 3.5 to 7.5 MB and 768 to 1,280 µs per query, mostly allocation ticky attributes to no closure | Refused |
| 9. `-O2` on one module | On `Parser`, then on `Value` | Within the noise (below) | Refused |
| 10. Bulk row framing | Strict primitive prefixes, then a row poked through `PacketWriter.unsafeWriteSized` | Prefixes 1,306 to 1,331 bytes per row; poked, 1,306 to 355, of which 56 the writer's | Poked rows kept |
| 11. `peekToken` | Inlined, with the wait out of line | Decode typed unchanged at 5.1 MB: the `Just` and the byte moved into the driver's bind | Reverted |

Candidate 8's doubled allocation was explained in the code-size run: the RTS's
generic apply splits an unknown call whose arguments mix pointers and unboxed
words (performance-research.md, "Allocation: unknown calls and their
arguments"). Candidate 10's poked rows are described in design.md, "Reading and
writing bytes: which layer".

**The comparison.** One full pass of the 225 cases, of the original, the start
(the failure channel) and the end, against SQL Server 2025 in Docker for Live
and Mars, at `--stdev 15`:

| Group | Cases | End/original time | Allocation | Start/original time | Allocation | End/start time | Allocation |
|---|---:|---:|---:|---:|---:|---:|---:|
| All | 225 | 1.226 | 1.217 | 1.366 | 1.369 | 0.898 | 0.889 |
| Decode | 72 | 1.574 | 1.280 | 1.734 | 1.374 | 0.908 | 0.932 |
| Encode | 18 | 0.996 | 1.087 | 1.179 | 1.258 | 0.844 | 0.864 |
| Live | 62 | 1.027 | 1.246 | 1.110 | 1.392 | 0.925 | 0.895 |
| Mars | 24 | 1.095 | 1.163 | 1.229 | 1.405 | 0.891 | 0.827 |
| Mock | 34 | 1.335 | 1.272 | 1.640 | 1.526 | 0.814 | 0.833 |
| Sql | 15 | 0.976 | 0.965 | 0.955 | 1.042 | 1.022 | 0.926 |

The card's target cases, from the same pass:

| Case | End/original time | Allocation | End/start time | Allocation |
|---|---:|---:|---:|---:|
| `Live.query.int bigint x10000.SqlRow` | 1.20 | 1.37 | 0.78 | 0.74 |
| `Live.query.int bigint x10000.typed` | 1.03 | 1.22 | 0.69 | 0.51 |
| `Mock.query.int bigint x10000.SqlRow` | 1.72 | 1.40 | 0.70 | 0.74 |
| `Mock.query.int bigint x10000.typed` | 1.48 | 1.26 | 0.58 | 0.50 |
| `Mock.query.nullable half NULL NBCROW x10000.typed` | 1.80 | 1.69 | 0.59 | 0.62 |
| `Decode.nullable no NULL ROW x10000.typed` | 2.45 | 1.60 | 0.70 | 0.64 |
| `Encode.bulk.bulk load 1000 rows framed` | 1.34 | 2.03 | 0.40 | 0.25 |
| `Live.insert.10000 rows, bulkInsert` | 0.91 | 1.00 | 0.87 | 0.89 |

Then the groups without a server, in two alternating pairs each:

| Comparison | Decode time | Allocation | Mock time | Allocation | Encode time | Allocation |
|---|---:|---:|---:|---:|---:|---:|
| End against start | 0.919 | 0.932 | 0.854 | 0.833 | 0.901 | 0.864 |
| End against the code before the failure channel | 0.948 | 0.958 | 0.962 | 0.918 | | |
| The failure channel alone | 1.046 | 1.028 | 1.071 | 1.101 | | |
| `-O2` on `Hmssql.Tds.Parser`, against the end | 1.012 | 0.997 | 0.985 | 0.999 | 0.981 | 1.000 |
| `-O2` on `Hmssql.Tds.Value`, against the end | 1.000 | 1.001 | 1.028 | 1.000 | 1.001 | 1.000 |

* The failure channel alone cost typed rows most:
  `Mock.query.int bigint x10000.typed` 1.46 in time and 1.65 in allocation, and
  the nullable typed cases about 1.2. Its handler per cell and the per-row
  preparation compounded, and which later change removed which part of the cost
  wasn't separated. Against the code before the channel, the end is faster in
  every target case, so the channel stays for its simpler readers (design.md,
  "Decoding").
* `-O2` stayed within the noise on both modules, so neither pays.
* In the two pairs of end against start, `Mock.query.nvarchar(max) 4MB
  x1.typed` was 1.38 in time and `Decode.text.utf16 CJK 4000` 1.29, with
  allocation 1.00. Four more pairs put the first at 0.96 to 1.00, and the UTF-16
  cases moved both ways, one from 1.29 to 1.06 and another from about 1.0 to
  1.34, on code this work didn't change. They are noise; the 4 MB cases need
  five pairs or more.

## Short streamed values, 2026-11-05

**Question.** What does a short `(max)` value cost when it is read through a
consumer or a fold rather than a `CellDecoder`, and how should a short value
reach them? Measured in `Bench.Decode` and `Mock.query` with GHC 9.12.4; the
benchmark cases are in [testing.md](testing.md#benchmarks).

**The cost of streaming a short value.** Before `streamWholeLimit`, 10,000 rows
of a short `nvarchar(max)` into `streamTextField`, keeping every chunk,
allocated 77.8 MB in `Bench.Decode` and 94.0 MB in `Mock.query`, against 9.0 MB
and 7.8 MB for `fieldDecoder @Text`. With a consumer that reads nothing it was
29 MB in `Bench.Decode`, so about 2 KB a value was the suspension of the row for
the consumer's `IO`, and the rest the consumer's own stream.

**What the implementation did.** A value of at most 64 KiB (`streamWholeLimit`)
is read as a `CellDecoder`'s is and reaches its consumer whole, as one chunk
through `consumeWhole`, with no reference to a suspended value, no masked pull
and no drain. A value whose total isn't sent (`xml`, `json`) is read a chunk at
a time until it ends within the limit or would pass it (`boundedValue`), so no
more than the limit is held. The same short `nvarchar(max)` case went to 47.8 MB
and 55.7 MB, and a 4 MB value through `streamField` allocated what it did. A pure
fold written as a `StreamingCell` suspends nothing: 10,000 short
`varbinary(max)` values cost 8.7 MB in `Mock.query` against 7.3 MB for
`fieldDecoder @ByteString`, and one 4 MB value 16.2 MB against 21.9 MB.

**Consumers among the rows.** The rule had been that a row with a consumer is
read alone, so that user code that blocks can't hold complete rows back. Ending
the batch before every consumer cost 1.1 to 1.7 KB more a row of a short
streamed value in `Mock.query` (48 and 55 MB per 10,000 rows, against 37 and
38 MB with a consumer that reads nothing). The owner reopened the rule: a
consumer that pulls from the response still starts its own batch, and one given
its value whole runs among the rows, holding back only the rows read ahead of
it in the same payloads. The per-result-set flag (`rowHasConsumers`) and the
flag in every `RowPart` went with it.

**`FoldingCell`.** A short value given to a `StreamingCell` pays for the call:
88 bytes a value for a pure fold (`varbinary(max) short folded`, 1.10 to 1.12 in
time) and 1.5% to 2.7% for a consumer, which pays for its `IO` anyway. A
`FoldingCell` is a `CellDecoder`'s three fields and a pure recipe over the
pieces of a value past the limit, so its short values take the `CellDecoder`'s
read. Refused for it:

* The fold as a `StreamingCell` given a short value as `StreamedWhole`: 2.0 MB
  more per 10,000 50-character `nvarchar(max)` values folded into text
  (15 MB against 13 MB for `fieldDecoder @Text`), for the value's
  result through the `StreamedValue`, the recipe's `Either` and
  `nullableField`'s `fmap`.
* A folding cell's short value read out of line too: 96 bytes a value more (9.97
  against 9.01 MB per 10,000 short `nvarchar(max)` into `Text`), for the call of
  seven arguments and a closure around its read.
* `cellRowDecoder` taking a folding cell's conversions through a `Maybe` of a
  pair, which changed nothing for a long column.

The streaming and folding reads are out of line once, rather than in each of
`readCellRecipe`'s three copies, with `boundedValue` and `nullsCell` NOINLINE.
Inlined, with every built-in type's row decoder holding `nullableCell`'s three
cases, they had made `Decoding.o` 62 KB larger and the library 3.7%; out of line,
`scripts/perf-compare.sh` against the code before them gave the library 0.975
of that size, with time 1.009 and allocation 1.002 over 385 cases.

**The built-in text decoders read a long value whole.** As `FoldingCell`s,
`Text` and lazy `Text` decoded a long value as it arrived (`decodeTextChunks`),
which gives the same text however the value is cut, ill-formed input included
(`Wire.StreamWhole` checks it). A 4 MB `nvarchar(max)` into `Text` then
allocated 0.874 as much in `Bench.Decode` but took 1.31 times as long there and
1.11 to 1.18 times on the mock connection (five pairs): a thousand chunks
decoded through a `Stream` and joined cost more than one decode of the assembled
bytes. Also refused: streaming every value, at the cost above; a limit the
application chooses, a few per cent for a choice every decoder would have to
make; and the pieces as the packets cut them for a value of unknown total,
which would start the consumer sooner but give a short `xml` value the streaming
cost.

## Where it stands

At the end of the candidates (2026-11-04), against the original row walk:
Live was 1.03 in time, Mock 1.34 and Decode 1.57, so the row walk's speed
without a socket was not reached. The code-size run that began the same day
took Mock to 1.105 and Decode to 1.383 of the original; after that pass its
per-type decoders measured Mock 0.924 and Decode 0.989 against the code before
them, and the second optimization run Mock 0.945 and Decode 1.000 against its
start (performance-research.md). No pass against the original has run since,
and the `Decode.*.rows` and `.tokens` cases still aren't like for like.

## Not verified

* GHC 9.14.1, on which the strict binding of a `SqlRow`'s column recipes
  matters ([protocol-notes.md](protocol-notes.md#ghc-and-its-libraries), "GHC
  and its libraries");
  `Resources.Complexity` and `Resources.ComplexityMock` passed with the slow
  tests on GHC 9.12.4 only.
* Live and Mars beyond one run each.
* Windows, macOS, a real network, and SQL Server 2017 to 2022 or Azure for the
  server probes.
* One `ConnectionClosed` in a full MARS run under other build and test load,
  while the randomized model test was opening its fresh connection, before its
  operations ran. The recorded seed passed alone, all 150 sequences, and a
  quiet full MARS run passed; the cause wasn't found.
