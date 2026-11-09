# How hmssql was developed

hmssql was written with AI coding agents, directed and reviewed by Joey
Adams, from September to November 2026. This document records who did
what, how the work was organized, what the reviews changed, and what went
wrong along the way. The Git commit history during initial development
was consolidated into [design.md](design.md), [bugs-found.md](bugs-found.md),
[protocol-notes.md](protocol-notes.md), [testing.md](testing.md) and the
research records. The lineage before hmssql is in [history.md](history.md).

The maintainer wrote the prompts, answered the design questions, reviewed
the results and decided what to keep. A "card" below is a plan or a
proposal kept at the repository's root while a session works from it (the
root `CLAUDE.md`, "Cards at the repo root"); its decisions went into the
documents when the work was done.

## Sessions

Each row says who did what and where the findings went. The findings
themselves are in the documents the row links to.

### September 2026: the first version and MARS

| # | Date | Model | What it did |
|---|---|---|---|
| 1 | 2026-09-06 | Claude Fable 5.1, in GitHub Copilot in VS Code | Compared hpgsql's design with the mssql package's problems, planned hmssql in seven phases and implemented it: the wire layer with `TdsContext` everywhere, both TLS modes, the reader thread, `FieldDecoder` and `RowDecoder`, `SqlValue`, `sp_executesql` parameters, `queryS`, transactions, typed exceptions, and 73 tests (hedgehog round trips and live tests). |
| 2 | 2026-09-06 | Claude Fable 5.1, Copilot | A second pass over the API: `SqlParam` (heterogeneous parameter lists), `NamedParams`, the `ResultSets` monad and `queryResultSets`, and `refineField`. 89 tests. |
| (lift) | 2026-09-23 | Claude Opus 5.5 | Made hmssql the only package in the repository, deleted mssql, redacted the session logs, and wrote the history and the comparison audit of hmssql against mssql, which listed seven bugs. |
| 3 | 2026-09-24 and 25 | Claude Opus 5.5 orchestrating Opus 5.5 and Sonnet 5 subagents (Claude Code) | Fixed the audit's bugs, added `reset`, and ran an open-ended test-and-fix loop for a day: the test suite grew from 89 to 2435 examples, in 160 commits, 79 of them touching the library ([below](#how-the-testing-session-worked)). |
| 4 | 2026-09-25 | GPT 6 Astra, Copilot | An adversarial review of that day's library changes, presented as an untested pull request, with the tests, docs and git history hidden from it ([below](#the-adversarial-review)). |
| 5 | 2026-09-25 | Claude Fable 5.1 orchestrating Fable 5.1 and Opus 5.5 subagents (Claude Code) | Evaluated the review, put the design questions to the maintainer, simplified the connection core accordingly, and reworked the tests to state the new contract. 33 commits. |
| 6 | 2026-09-25 | Claude Fable 5.1 | Consolidated the session records, commit messages and open questions into this documentation. |
| 7 | 2026-09-25 and 26 | Claude Fable 5.1 orchestrating Fable 5.1 and Opus 5.5 subagents | The suite run against Azure SQL Database from a container in the same region, its 75 failures triaged and fixed ([azure-sql.md](azure-sql.md); one was a bug, `SevereError`); `cancelActiveStatement`; the example applications and their database; `Hmssql.SqlType` and `Hmssql.Catalog`; the `Query` type (hpgsql's design, left out of the first version); and the benchmark suite. |
| 8 | 2026-09-27 | Claude Opus 5.5 (Claude Code), with Fable 5.1 for the row view and the packet-at-a-time reader | An optimisation round with no single use case in mind: request encoding and framing, the TLS and plain-socket receive paths, the row walk and the in-place value decoders, rows read a packet at a time, `executeMany` and `executeStatements`, and large values read in one copy. About 60 commits, each with its before-and-after measurement ([performance-research.md](performance-research.md)). Also tried and measured `tls` 2.4.8 over `crypton` 2.1.2, and moved to Stackage `nightly-2026-09-27`. |
| 9 | 2026-09-27 | GPT 6 Astra, Copilot | A second adversarial review, of the optimisation round's source alone (tests, benchmarks and history hidden): 18 findings ([below](#the-second-adversarial-review)). |
| 10 | 2026-09-28 | Claude Fable 5.1 | Resolved the review (memory safety, the eager BEGIN back, one description of each wire layout), wrote the byte-layer convention, bulk copy with its equivalence and fuzz tests, batch queries, the documented front door (`Hmssql` exports by name), and the split of the README into the guide, the features and the security documents. |
| 11 | 2026-09-29 | Claude Opus 5.5 | `release` and `renew`; the bulk-copy example; `Hmssql.Query`'s module layout; four flakes under load fixed at their causes; the `threadLabel` crash traced to GHC #27618. |
| 12 | 2026-09-29 | Claude Fable 5.1 | Entra ID login with an access token the caller obtains (`connectAccessToken`), sent in LOGIN7's FEDAUTH feature with no HTTP or JWT dependency. The token exposed two bugs, both fixed: packets are 4096 bytes until the server grants the requested size, and strict encryption needs the inner PRELOGIN for the FEDAUTHREQUIRED answer. Also `examples/managed-identity` and the script that runs it in a container with a user-assigned identity ([azure-sql.md](azure-sql.md)). |
| 13 | 2026-09-29 | Claude Opus 5.5 | Followed Azure SQL Database's login redirects, up to ten in a row as SqlClient does, with the LOGIN7 server name set to the target's `host,port`, since the node refuses the gateway's name with error 40613 ([design.md](design.md#connection-lifecycle)). `bench/azure` compared the Proxy and Default connection policies from a container in the region: redirected connections connected and answered faster, so the test scripts stopped forcing Proxy. |
| 14 | 2026-09-29 | Claude Fable 5.1 | Consolidated the commit history since session 6 into this documentation again, and wrote [backlog.md](backlog.md). |
| 15 | 2026-09-29 | Claude Opus 5.5 orchestrating Sonnet 5.5 subagents (Claude Code) | A MARS research spike: read MS-TDS and MC-SMP, planned a channel as a record copy of `Connection`, and had a subagent build it as throwaway code and measure it against SQL Server 2025; then a second subagent probed transactions under MARS and snapshot isolation shared across sessions, and seven more probed the remaining design questions in parallel, one of them against Azure SQL Database ([mars-research.md](mars-research.md)). |
| 16 | 2026-09-30 | Claude Fable 5.1 orchestrating Opus 5.5 and Sonnet 5.5 subagents (Claude Code) | Implemented MARS from a plan written from the spikes and probes, which corrected them in twelve places: the connection split into sessions, SMP framing and flow control, the reset gate, transactions begun by a Transaction Manager request on every connection, `withQueryS` and `cancelResponse` ([design.md](design.md#mars-several-responses-on-one-connection)). The subagents adapted the suite to run over MARS and wrote the mock SMP server, the live MARS tests, the model's extension to several open responses, the snapshot example and the benchmarks. Their tests found seven bugs, five in the new code and two older ones ([bugs-found.md](bugs-found.md)); where the implementation found the plan wrong in turn, [mars-research.md](mars-research.md#where-the-implementation-departs-from-the-research) says so. |
| 17 | 2026-09-30 | Claude Fable 5.1 orchestrating five subagents (Claude Code) | Reviewed the MARS commit against a checklist of 111 items written before the code existed, one subagent per area: the wire layer, cancellation, reset, transactions, and the API with its defaults and documentation. Four defects, all fixed with regression tests, and one wrong documented claim ([bugs-found.md](bugs-found.md)). The orchestrating session answered the eight design questions the reviews raised, for the maintainer to confirm or overturn ([design.md](design.md#mars-several-responses-on-one-connection)). |
| 18 | 2026-09-30 | Claude Fable 5.1 | Moved the OData example to `demos/odata`, since a demo shows what hmssql can do and an example teaches the API, and added `$expand` over MARS: each expanded collection is a statement open beside the root's, sorted by a row number and zipped on the client with one row of lookahead, inside a snapshot transaction. A parent with a million children took the same memory as one with none, about 2 MB of peak live heap for a 50 MB response. |
| 19 | 2026-09-30 | Claude Fable 5.1 | Split the documentation into the user book (`docs/book/`, since renamed the guide) and the developer documents (`docs/dev/`), made the root `CLAUDE.md` the index of where each area is documented, and consolidated the MARS research (two spikes, seven probes, the plan and five review reports, about 6,900 lines) into [mars-research.md](mars-research.md). |

### October 2026: hardening, the test matrix, and Windows

| # | Date | Model | What it did |
|---|---|---|---|
| 20 | 2026-10-01 and 02 | Claude Opus 5.5 (Claude Code), with two Opus 5.5 subagents | Reproduced and fixed the four MARS flakes the backlog listed, and a fifth that the slow model run found. None was a library bug: two were gaps in the model, one a test that waited by spinning, and one a heavy test timed out beside a stray process. Then three runs against Azure SQL Database, whose failures were all the tests': lock tests that assumed lock-based READ COMMITTED where Azure has RCSI, five tests of server behaviour Azure lacks, two `Mars.Cancel` timeouts that were the tests' own writes held by the log-rate governor, a `KILL` of the wrong session and a catalog read lost to a deadlock. Packet traces showed Azure ending a MARS connection that sends a request and its Attention together, which the maintainer chose to document ([upstream/azure-sql-early-attention](upstream/azure-sql-early-attention/README.md)). A subagent cut the scratch databases of a run from 28 to 8 ([azure-sql.md](azure-sql.md)). With the maintainer, the session settled one cancellation rule: an interruption never waits, and an ordinary exit leaves nothing behind ([design.md](design.md#interruption-and-cancellation)). |
| 21 | 2026-10-02 | Claude Fable 5.1 (Claude Code) | Reworked `scripts/test-matrix.sh` to run the GHC matrix with nothing but Docker: a container per SQL Server with a generated certificate, so that strict encryption validates, an image and a cache volume per GHC version, and three runs at a time. It found that SQL Server 2022 on Linux has no strict encryption, so the 2022 column runs over TDS 7.4 ([protocol-notes.md](protocol-notes.md#strict-encryption-tds-80), [testing.md](testing.md)). |
| 22 | 2026-10-02 and 03 | Claude Opus 5.5 (Claude Code) | Triaged the first full matrix run, which had tested 433 of 3372 examples because every run stopped at the first hedgehog coverage table on an ASCII stdout. Added `HMSSQL_TEST_SQL_VERSION`, and chased the matrix's hangs with reports of both sides of each timeout: every one was the server under load, and the eight-hour fuzz hang was hedgehog shrinking a case slowed by quadratic re-walks of tiny packets. |
| 23 | 2026-10-03 | Claude Opus 5.5 (Claude Code) | The Windows transports, on Windows 10 against a local SQL Server 2025, working unattended from a plan card: the backend record, Shared Memory and Named Pipes on overlapped I/O, `connectProtocol`, the mock server on a pipe, and the suite building and passing on Windows. Then the suite over TCP, and under GHC's native I/O manager with network 3.3, where a path through the manager was built and removed, two bugs in the manager were reduced to repros without hmssql, and a leak of 32 KiB per plaintext connection was found and fixed. Twenty-five probes ([windows-research.md](windows-research.md)). |
| 24 | 2026-10-04 | Claude Fable 5.1 (Claude Code) | Merged the Windows work and reviewed everything since the test matrix: the uninterruptible read of a certificate file, a workaround for GHC's native I/O manager, became Windows-only ([design.md](design.md#platform-workarounds)). Built and tested on macOS, and benchmarked the backend record, which cost nothing measurable; the benchmark's own pitfalls are in [testing.md](testing.md#benchmarks). |
| 25 | 2026-10-05 and 06 | Claude Opus 5.5 (Claude Code) | Fixed `MarsTx.Snapshot`, which assumed two writers could out-commit a reader on a disk where a commit waits 5 ms; found that the 2.5 MB a process's last connection seemed to keep was the system certificate store's cache; ran two suites against Azure SQL Database on the Basic tier ([azure-sql.md](azure-sql.md)); and ran the whole test matrix for the first time since the optimisation round. Of its 180 runs, 49 failed at first and 43 of those passed after the fixes. They found one library defect (an `SqlRow` cost 8n² bytes on GHC 9.14.1), one server fact the documents had wrong (on a MARS connection a `SET` beside a running stream is undone when the stream ends), and ten tests that assumed how long something takes ([bugs-found.md](bugs-found.md), [testing.md](testing.md)). |
| 26 | 2026-10-08 | Claude Opus 5.5 (Claude Code) | The first run against SQL Server 2019, on Windows 10. Strict encryption, the suite's default, failed there with error 17832, so `HMSSQL_TEST_SQL_VERSION=2019` makes `on` the default. Two failures were not hmssql's: a MARS test's `timeout` that GHC's timer on Windows fired a second late behind thousands of abandoned `timeout`s ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)), and a stale cached plan that SQL Server 2019 RTM ran against a re-created `#temp` table ([protocol-notes.md](protocol-notes.md)). |
| 27 | 2026-10-13 | Claude Fable 5.1 (Claude Code) | Two bugs and three suspected ones, reported from a reading of the connection code. The bugs: a silent first address cost the operating system's whole connect timeout before the next was tried, and the strict handshake never checked that the server selected `tds/8.0` ([bugs-found.md](bugs-found.md)). The three suspicions were measured and found not to be bugs, and the measurements went into [protocol-notes.md](protocol-notes.md) and [design.md](design.md#what-the-wire-layer-checks). |
| 28 | 2026-10-14 | Claude Opus 5.5 (Claude Code) | Added SQL Server 2017 and 2019 to the test matrix from their newest Linux images. 2017 failed 32 tests in each configuration, all about the UTF-8 collations and the UTF-8 feature extension that SQL Server 2019 added; they are pending on 2017 now ([testing.md](testing.md), [protocol-notes.md](protocol-notes.md#login7-and-login)). |
| 29 | 2026-10-15 | Claude Opus 5.5 (Claude Code), as a subagent, with an Opus 5.5 subagent of its own | Asked whether a request the server never answers lets hmssql or the suite grow, after a test process was killed at 16 GB. Mocks that stop answering held the live heap flat for 4 to 15 minutes each, which `Resources.StalledServer` keeps. What grew was hedgehog shrinking a failed live property, up to 11 GB, so every live property now stops after 1000 passing smaller cases in a row ([bugs-found.md](bugs-found.md)). |
| 30 | 2026-10-15 | Claude Opus 5.5 (Claude Code), a subagent | Asked whether two kinds of MARS hang in the test matrix were hmssql's or the server's. Both were the server's: SQL Server 2025 ignores an Attention that arrives before its statement is under way, and SQL Server 2022 crawled for minutes beside runs at 512-byte packets. The MARS tests now bound time without progress rather than time ([protocol-notes.md](protocol-notes.md#mars-and-smp), [bugs-found.md](bugs-found.md)). |
| 31 | 2026-10-16 | Claude Opus 5.5 and Claude Sonnet 5.5 (Claude Code) | Retested Windows 10 against SQL Server 2025 build 17.0.1145.4 after the 23 commits since the Windows merge. The suite passed without a server and over TCP, Shared Memory and Named Pipes; two whole runs with the slow tests failed three tests that each passed alone, now in the backlog's checks to revisit. |
| 32 | 2026-10-23 | Codex | Triaged nine suspected defects of the wire layer against hmssql. Three were real and were fixed: a fatal ERROR was admitted before the end of its response, SMP control packets accepted payloads, and `datetimeoffset` decoding accepted an offset or a local date out of range. The other six were deliberate differences of policy ([bugs-found.md](bugs-found.md), [design.md](design.md)). |
| 33 | 2026-10-25 | Claude Opus 5.5 (Claude Code), as a subagent | A round of connection and interruption testing, with the tests it added and the fixes it led to. Two bugs: a token other than a row was held without a bound (now refused past 16 MiB), and a login refused at severity 20 or more was a `SqlServerError` (now a `LoginError`, with `loginErrorNumber` and `isTransientLoginError`). New tests of interruption at every packet boundary, a cancellation model, a cut handshake and non-ASCII logins found nothing more, and `HMSSQL_TEST_MARS_WINDOW` found sixteen places in the MARS tests that assumed a window of 64. |
| 34 | 2026-10-25 | Claude Opus 5.5 (Claude Code), as a subagent | Diagnosed the matrix's hang at `Connection.Lifecycle` "many connections" on GHC 9.6.6: GHC's epoll I/O manager has the stale-registration defects of the kqueue one ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)). No library defect; the test now fails with a bound instead of hanging. |
| 35 | 2026-10-25 | Claude Sonnet 5.5 (Claude Code) | Ran the suite on macOS, locally and against Azure SQL Database. Two failures were the tests' and are fixed (a refusing port that times out on macOS, and a database name outside the BMP that Azure refuses). A hang of a streaming `KILL` was seen on one macOS system only and is documented as such ([testing.md](testing.md)). |
| 36 | 2026-10-25 | Not recorded | Ran the whole suite on Windows with the stock GHC 9.12.4 from MSYS2 over Shared Memory (3,585 examples, no failures, 113 pending) and fixed what stalled there: a mock's shutdown that `shutdown(SD_RECEIVE)` couldn't wake, a proxy thread blocked in network's uninterruptible Windows `recv`, and timeout guards whose pending delays polluted `Resources.StalledServer`'s allocation window ([bugs-found.md](bugs-found.md), [testing.md](testing.md)). Also let the live tests trust a generated certificate and turn strict encryption off where the server lacks it. |
| 37 | 2026-10-27 | Codex | Added 1,242 examples of data and features: every decimal precision and scale, Unicode boundaries, XML and JSON, catalog names, collations and permissions, bulk copy with triggers, views and constraints, and the laws of `BatchQuery`. Server-oracle tests found three bulk copy bugs, fixed: money rounded into an integer, the minimum `bigint` refused as a floating-point value, and named rows aliasing case-folded column names. |
| 38 | 2026-10-27 | Codex | A data-integrity hardening pass: 118 examples of narrowing and rounding boundaries, RETURNVALUE agreement, changed bulk metadata, and transactions checked by an observer connection, including all 27 three-step transaction sequences. |
| 39 | 2026-10-28 | Codex | Extended the paired campaign with independent native values, raw bytes and type metadata, valid neighbours and durable observer rows. The hmssql fixes covered exact floating conversions and signed zero, source padding, raw Unicode and XML in bulk copy, native `sql_variant` declarations, empty sources, literal leading `@` in column names, and huge negative UTC clocks ([bugs-found.md](bugs-found.md)). |
| 40 | 2026-10-28 | Claude Fable 5.1 (Claude Code) | Reviewed the hardening round against the documents as they were before it, with a checklist written first ([review-checklist.md](review-checklist.md)) and every doubt measured on the local server. Two library findings, both fixed: bulk copy rounded a floating value into a decimal half to even where the server rounds the exact binary value half away from zero, and the named-row `@` rule depended on the other columns' names. A counter-review of this review then found two claims it had left standing in the guide's bulk copy chapter, both measured wrong on the server: a plain `INSERT` truncates a long string silently only under `ANSI_WARNINGS OFF`, and a failed bulk batch keeps its rows when a trigger's `RAISERROR` reported the error. The campaign's plan, which held credentials, was removed, the test module was split by area, and the documents were trimmed of the round's run log. |
| 41 | 2026-10-29 | Codex | Revised the guide's opening with the maintainer, corrected the claim that Azure SQL Database requires TDS 8.0, made the examples default to TDS 7.4, and made an empty `connectServerName` take `connectHost` in LOGIN7 ([azure-sql.md](azure-sql.md)). |
| 42 | 2026-10-29 | Codex | Added the opt-in `Connection.AzureServerName` tests of the LOGIN7 server name against Azure SQL Database, under TDS 7.4 and 8.0 ([azure-sql.md](azure-sql.md)). |
| 43 | 2026-10-29 | Codex | Measured the ODBC route, which the first session had rejected unmeasured: Microsoft's ODBC Driver 18 from C, and the Haskell binding `odbc-0.3.0`, for type fidelity, cancellation and speed (`experiments/odbc` and `experiments/odbc-haskell`). The README's section on ODBC was rewritten from the results ([below](#why-hmssql-was-written-instead-of-fixing-mssql-simple-and-ms-tds)). |

### Late October and November 2026: the API cleanup, value streaming, optimization, and WinIO

| # | Date | Model | What it did |
|---|---|---|---|
| 44 | 2026-10-29 to 31 | Not recorded (the commits carry no attribution), then Claude Opus 5 (Claude Code) | The API cleanup before the first release, with the tests, benchmarks and examples set aside while the interface changed: names aligned with hpgsql's (`RowDecoderMonadic`, `singleField`, `genericFromSqlRow` and `genericToSqlRow`, `begin`, `commit` and `rollback`, `SqlWord8`, and others), the conveniences `execute_`, `query1With` and `queryMayWith`, applicative and monadic multi-result decoders split (`queryMultiWith` and `queryMultiMWith`), procedure parameters encoded with the connection's context, `Text` throughout `ConnectInfo`, monadic row decoders that must consume every column, `rowversion` kept in column metadata, and the unsafe byte primitives moved to `Hmssql.Tds.Bytes.Unsafe` under `unsafe` names. Then Claude brought the tests, benchmarks, examples and demos to the new API, which exposed two gaps (`rawInParam` and `rawOutParam`, and `batchQuery1With` and `batchQueryMayWith`); the whole suite passed. `exposed-modules` came out of `package.yaml`, since hpack exposes every module anyway. |
| 45 | 2026-10-30 | Claude Opus 5.5 (Claude Code), then Codex | The cleanup found a MARS send writing into a `ByteString` it was handed. Made the ownership of packet buffers linear with no copy added, tested the one `unsafeCoerce` against 19 mutants, and won back the 7 to 11% it first cost in bulk framing by reading the STG. Codex merged it into the cleanup branch. |
| 46 | 2026-10-30 | Claude Opus 5.5 (Claude Code) | Wrote [linear-types.md](linear-types.md), the assessment of what linear types did for hmssql, and revised it against a second draft the maintainer had ChatGPT write independently ([below](#incidents-and-lessons)). Then removed the linear types at the maintainer's direction, after asking what the early `ByteString` was for: nothing read it, so the defect was the early wrap, not the lack of a compile-time owner ([design.md](design.md#who-owns-a-packets-bytes), [linear-types.md](linear-types.md)). |
| 47 | 2026-10-31 | Claude Opus 5.5 and Codex, with the maintainer | Wrote the public API review card (Claude Opus 5.5) and planned the value-streaming rewrite from its D2 ("a large parameter can't stream"). The first plan built streaming on a mutable row cursor; two attempts at it grew a control block, twelve mutable registers and then a thirteen-field record, and the maintainer rejected both. A second card replaced that design with parser recipes over the `streaming` package's `Stream`, one code path for any column, and a revision took it off continuation-passing style. A spike of the reader recipes was kept as a reference ([value-streaming-research.md](value-streaming-research.md)). |
| 48 | 2026-11-01 | Codex | Implemented the rewrite: parser continuations in place of the row walk and its resumable control blocks, direct field decoding, value streams in both directions, and Builder writing, with the wire fixtures moved to the one recipe path. The first spike had left out the library change asked for, so the maintainer required the complete implementation before any performance work. |
| 49 | 2026-11-01 | Codex with parallel subagents | Implemented two reviews of the rewrite, each assessed finding by finding first ([below](#the-reviews-of-the-value-streaming-rewrite)), and reduced the recipes' allocation with controlled ablations. The rewrite ended slower than the row walk it replaced, and the work was paused there ([value-streaming-research.md](value-streaming-research.md)). |
| 50 | 2026-11-01 | Claude Opus 5.5 (Claude Code), with agents in worktrees | After the rewrite: gave packets to the sink only once complete, with the SMP header beside them; removed `runRW#` from `Hmssql.Tds.Bytes` (3 to 4% in time); commented the decoders, the writer, the response driver and bulk copy in parallel agents; made the public Haddock general; and moved what the Haddock had taken from the guide into the modules, so that a Hackage reader needs no path under `docs/`. Writing the tests of the returned-failure rule found one that was undocumented: a `StreamingCell` must read its value to the end even when it returns a `Left`. |
| 51 | 2026-11-02 | Claude Opus 5.5 (Claude Code) | `unusableReason`, with the `UnusableReason` sum type that `ConnectionBroken` now carries; `renew` refuses an unusable connection, and the pool recipe destroys it and takes the next; a DONE_SRVERROR breaks the connection at once; `TransactionCleanupFailed` removed. |
| 52 | 2026-11-03 | Claude Opus 5.5 (Claude Code) | Brought the README and the guide up to date: the platform section still said Windows was unverified and no SQL Server before 2025 tested. Every `ConnectInfo` example became one field per line, `DocExamplesSpec` began running the README's and the `Hmssql` module's getting-started programs, and a claim that `cancelResponse` cancels a `queryS` stream, which has no `ResponseReader` to pass it, was corrected. |
| 53 | 2026-11-03 | Claude Opus 5.5 (Claude Code) | No result type of a recipe, row or cell holds a `SomeException` any more: failures are `ReadFailure`, and a streaming consumer's exception ends the query at once instead of being carried in the row's result and rethrown after a drain. |
| 54 | 2026-11-03 | Claude Opus 5.5 (Claude Code) | Worked through an optimization card, profiling with ticky first and benchmarking once at the end. The largest saving was on no list: GHC had eta-expanded a row's preparation into every row ([performance-research.md](performance-research.md)). |
| 55 | 2026-11-04 | Claude Opus 5.5 (Claude Code), with Opus and Fable agents in worktrees | An optimization run whose first metric was the object code hmssql adds to an application, measured with the new `scripts/code-size.sh` (50 records, 1,187 fields). Three rounds of four or five parallel experiments, each an agent in its own worktree, merged and timed by the coordinator. The decoders of the 50 records went from 29.9 MB and 617 s of compile time to 79 KB and 1.2 s ([performance-research.md](performance-research.md)). |
| 56 | 2026-11-04 | Claude Fable 5.1 (Claude Code) | Reviewed the library's interface and the Haddock of every module after the run, with American spellings throughout. Found four documentation defects and one interface wart, a hidden class method that Haddock would have shown in the minimal complete definition. |
| 57 | 2026-11-04 | Not recorded (the commits carry no attribution), with parallel agents by area | A second optimization run, through the 38 ideas the code-size run left, each its own commit and a refused one reverted before the next; the agents measured code, allocation and memory with fixed-work probes while they built, and the coordinator timed the end with nothing running. The changes of thirteen ideas and the tools and benchmarks of four more were kept: the benchmark suite, expanded to 281 cases, went to 0.973 in time and 0.960 in allocation, the drains to about half, and the library and the derived encoders 6% and 12% smaller. Split sections in every module and a 32-byte procedure alignment on `Tds.Utf16` were added and later removed on the maintainer's decision ([performance-research.md](performance-research.md)). |
| 58 | 2026-11-04 | Claude Fable 5.1 (Claude Code) | Reviewed the second run for unsafe code, benchmark-only wins, interface cost, placement and comment wording. The unsafe additions are contained. At the maintainer's request, the per-module split sections and the procedure alignment for UTF-16 decoding were then taken out: the first is the application's build setting, and the second's benefit depended on code layout. |
| 59 | 2026-11-05 | Claude Opus 5.5 (Claude Code) | Exported the compiled row path and added decoders of a date or time value from its parts, for a consumer that writes every cell straight to JSON with no allocation per cell; measured each choice before documenting it. |
| 60 | 2026-11-05 | Claude Fable 5.1 (Claude Code) | Reviewed session 59's commit. The code and the test stood; the documents had one false claim about which path a NULL takes, and a `design.md` bullet that told history instead of the contract. |
| 61 | 2026-11-05 | Claude Opus 5.5 (Claude Code) | On the maintainer's three requests, for programs that write values out as they read them: a streamed value read whole up to 64 KiB (`streamWholeLimit`), a fold over a short value at a `CellDecoder`'s cost (`FoldingCell`), and a decimal from its parts (`decimalFieldDecoder`). A `traverseRow` was measured and left out. |
| 62 | 2026-11-05 | Claude Opus 5.5 (Claude Code) | Took back session 61's library growth with `scripts/perf-compare.sh`, and added `byColumn` and `columnIsLong` for programs that build their queries at runtime ([performance-research.md](performance-research.md)). Verified the move to Stackage `nightly-2026-11-03`: the suite passed and the benchmarks were the same within their noise. |
| 63 | 2026-11-05 | Claude Fable 5.1 (Claude Code) | Rewrote the English of the `Hmssql` module's Haddock page for a first-time reader, with a Streaming section and an example of each way of passing a parameter. |
| 64 | 2026-11-06 | Claude Opus 5.5 (Claude Code) | Asked whether a `timeout` could still cancel a query on Windows without `-threaded`, probed GHC's non-threaded runtime, then made hmssql work there under the default I/O manager, with the blocking calls in `cbits/windows.c` run on the manager's workers ([windows-research.md](windows-research.md), [design.md](design.md#platform-workarounds)). The first full run without `-threaded` found three time limits too tight for one capability and a handle count raised by the suite's sleeping watchdogs. |
| 65 | 2026-11-06 | Claude Opus 5.5 (Claude Code) | Started by session 64 to find why MARS over a pipe without encryption failed. A change of 2026-11-01 had sent the SMP header beside its packet as a chunk of its own, and the pipe backend makes each chunk a write, which the server can't take apart; the pipe now joins them ([bugs-found.md](bugs-found.md)). Then ran `scripts/perf-compare.sh` on Windows for the first time, which needed `awk` in place of `bc` and a benchmark mock that doesn't kill a thread inside `accept`. |
| 66 | 2026-11-06 | Claude Opus 5.5 (Claude Code) | Implemented the maintainer's card for TCP through network's own calls under GHC's native I/O manager, built with GHC master and network master. The suite failed in four groups, and probes of network's calls alone found what the card's reading of network's source had missed ([below](#incidents-and-lessons)). The non-threaded runtime froze on that path and stayed refused for the day. |
| 67 | 2026-11-07 | Claude Opus 5.5 (Claude Code) | Fixed GHC's native I/O manager on a GHC branch (completion packets that outlived their requests, a cancelled read waited for on its file handle, and the non-threaded runtime's idle spin), then ran the suite with that GHC: no crash or hang in 21 threaded runs. On the maintainer's decision TCP takes network's path without `-threaded` as well ([windows-research.md](windows-research.md)). |
| 68 | 2026-11-07 | Claude Opus 5.5 (Claude Code) | Implemented the maintainer's card for Shared Memory and Named Pipes through GHC's native I/O manager, with and without `-threaded`, after probes on the fixed GHC branch and on plain master. 15 runs under the native manager and 7 under the default one passed ([windows-research.md](windows-research.md)). |
| 69 | 2026-11-08 | Claude Opus 5.5 (Claude Code) orchestrating Opus 5.5 subagents | Before the merge into `main`: renamed the book to the guide, folded the cards at the repository's root and the commit messages since 2026-09-29 into the documents, and reorganized the documents the work since then had cluttered. |
| 70 | 2026-11-08 | Claude Opus 5.5 (Claude Code) | Ported to tls 2.5, keeping 2.4: the SHA-1 signature schemes are filtered under CPP, since 2.5 renamed them but still offers them. Found that 2.5 refuses a server's RSA key shorter than 2048 bits even with `tlsTrustServerCertificate`, kept that, and documented it for older SQL Servers. The suite passed against SQL Server 2025 on tls 2.5.1 (6000 examples) and the TLS tests on 2.4.6. |
| 71 | 2026-11-08 | Claude Fable 5.1 (Claude Code) | Reworded the whole guide into plain documentation English, replacing the clipped voice that had made it hard to read, and reorganized its sixteen numbered chapters into nineteen topic-named pages under seven section folders, with the contents page as the tree and the Previous/Next footers still running through the pages in order. Reading rows, Parameters and Streaming each gave up their advanced half to a new Decoders and encoders section. After the site generator landed, gave that section worked examples with tests in `DocExamplesSpec`: a row decoder and encoder built by hand, a field decoder and encoder from the wire bytes, and the hand-written form of a derived instance beside the `GHC.Generics` walk that produces it. Then reworked the Bulk copy page and the `Hmssql.BulkCopy` header around three questions: which rows a load takes (any `ToSqlRow`, positionally in table order, or by name), what a failure leaves behind per batching and transaction, and when an `INSERT` is the better tool. A probe with a login granted INSERT alone measured the permissions a load needs and that a load without `CHECK_CONSTRAINTS` leaves the constraint untrusted, now in `protocol-notes.md`. |
| 72 | 2026-11-08 | Claude Opus 5.5 (Claude Code) | Wrote the HTML site for the guide and the Haddock (`site/`): a generator in Haskell over cmark-gfm with its own highlighting, names in the guide linked to the Haddock, a search as you type with no server, and light and dark colors that follow the reader, in a Haddock theme as well. The guide's Previous/Next footers went, since the site draws them from the contents. Publishing is a force-push to `gh-pages`. |
| 73 | 2026-11-08 | Claude Fable 5.1 (Claude Code) | Made the examples a single folder of programs written for people to read. The OData server moved from `demos/odata` to `examples/odata` and shrank from about 1,900 lines to about 900: `$select`, `$orderby`, `$top`, `$skip` and `$expand` nested to any depth, with `$filter`, `$count`, entities by key, many-to-one properties and per-parent paging gone, so that the model from the catalog, the statement per level, the decoder per statement, the zip and the snapshot transaction are what the reader meets. The `mars-zip` example went, since its verifier was a test of the library rather than a lesson, and `crud` gained `export`, three `withQueryS` streams on one MARS connection zipped into a document per customer. The `DEMONSTRATES (n)` markers left the comments, and every example has a hand-written `.cabal` file in place of `package.yaml`. Measured with `+RTS -s`: about 6 MB of maximum residency for a 54 MB `$expand` response, the same as for a plain stream. |
| 74 | 2026-11-08 | Claude Opus 5.5 (Claude Code) | Broke a first program's 23 MB and hmssql's 2.2 MB of code down by package and by kind: features, built-in instances, code compiled on applications' behalf, and inlining. Moved `SqlDataType` and `typeInfoDataType` into `Hmssql.Internal.SqlDataType`, so that a program that doesn't use `Hmssql.SqlType` no longer links it: 117 KB off the program's file ([performance-research.md](performance-research.md#the-size-breakdown-2026-11-08)). |
| 75 | 2026-11-09 | Claude Opus 5.5 (Claude Code) | Split the repository into packages of their own, as hpgsql's is: the library in `hmssql/` (with `ChangeLog.md` and its own `LICENSE`), the test suite in `hmssql-tests/`, the benchmarks in `hmssql-bench/` and the Azure benchmark in `hmssql-bench-azure/`. The library's package no longer ships `docs/`, `README.md`, the scripts or the `Dockerfile`, and building it builds nothing else. The `nonthreaded` flag moved to `hmssql-tests`, and the scripts, the `Dockerfile`, `site/build.sh` and the documents follow the new paths; `scripts/perf-compare.sh` still builds a commit from before the split. |
| 76 | 2026-11-09 | Claude Opus 5.5 (Claude Code) | Release check of the library's package. The `dev` flags left `hmssql`, `hmssql-tests` and `hmssql-bench`, and their `-j` and the test suite's `-O0` moved to `stack.yaml`'s `ghc-options`. The library's dependencies got bounds (the oldest tested versions, and PVP upper bounds above the newest), which cabal resolves on GHC 9.6.6 and 9.14.1; the ChangeLog's links became absolute, and the copyright field and the description's README reference were corrected. `cabal check` is clean. |

## Why hmssql was written instead of fixing mssql-simple and ms-tds

From the first session's prompt: mssql-simple's `Row` class was not
composable, so it could not be derived generically; every type needed
separate `T` and `Maybe T` instances; decoders called `error`; results were
built in memory, with lazy parsing leaving thunks behind; and ms-tds's
serialization didn't know the protocol version, although TDS encodings
depend on it. hpgsql had solved four of the five for PostgreSQL, and its
encoding context was the pattern for the fifth. The point of a native
client rather than ODBC was deployability and predictable types, not speed.
An ODBC driver is a system package to install and version, and the
maintainer was concerned about how one would handle types such as
`datetimeoffset`. The ODBC route was not tried then.

It was measured on 2026-10-29, against a local SQL Server 2025 on macOS
(arm64) under strict encryption (`experiments/odbc` and
`experiments/odbc-haskell`). Microsoft's ODBC Driver 18, called from C,
kept `datetimeoffset(7)`, `datetime2(7)`, `decimal` up to 38 digits and
Unicode exactly when the binding chose the right C and SQL types (244
assertions, none failed), and its cancellation (`SQLCancelHandle`, about
0.5 ms; a query timeout, about 1 s) left the connection usable. The driver
also loses information silently when the binding chooses badly: a
`datetimeoffset` read as a generic timestamp drops its offset and comes
back in the process's time zone, an unconfigured `SQL_C_NUMERIC` drops the
scale with only a 01S07 warning, and a UTF-8 parameter bound as
`SQL_VARCHAR` is mangled through the database's code page before it
reaches a UTF-8 column. The Haskell binding `odbc-0.3.0` made the bad
choices: it reads every decimal as a `Double` before the caller's
conversion (8 of 10 values inexact), a Haskell `timeout` or `killThread`
did not promptly cancel a running query, and it runs a connection's
statements one at a time even with MARS on (21 of 124 assertions failed).
So the concern was right about the binding and wrong about the driver. The
README's section on ODBC states the result.

The prompt's point of comparison was mssql, the maintainer's unreleased
2025 merge of ms-tds and mssql-simple into one package
([history.md](history.md)), made so that the protocol layer and the client
API could be developed and tested together. hmssql keeps that shape, one
package for both, for the same reason; the problems above were the two
upstream packages', which the merge carried.

## How the testing session worked

The maintainer asked for the audit's bugs fixed with tests, and then: "write
tests (and if found, fix bugs) for hmssql and run them, endlessly, or until
every single edge case of every single data type, request query shape, and
concurrency fuzzing you can think of is tested, or until I tell you to
stop." Ground rules: subagents for all code changes, to keep the root
session's context small (tests by Sonnet 5, or Opus 5.5 when complex; fixes
by Opus 5.5); bugs only, no missing features; a shared test database, no
data in `master`; log unclear points in a running questions document instead
of stopping; ask questions up front, then run without interruption.

**Orchestration.** The root session never edited code. It wrote a brief for
subagents (server details, build and test commands, conventions, scope, how
to report), spawned three to nine agents at a time in isolated git
worktrees, merged their work by cherry-picking, and kept a ledger. Rules
added to the brief as problems appeared: put tests in new modules of your
own (hspec-discover picks them up, and it avoids conflicts); mark a test
that exposes a bug `pendingWith "BUG: ..."`, never weaken it; reset your
worktree to the main branch before starting; stop your background processes
before reporting; never kill processes by broad patterns; cap test heaps
with `+RTS -M` and run at most two test binaries at once.

**Rounds.** Round 1 fixed the audit's bugs and built the harness. Rounds 2
to 5 fuzzed the protocol against a mock server, fuzzed concurrency and
cancellation, ran type matrices and random-schema differential tests against
the server, and covered sessions, procedures, scale and API misuse. Round 6
reviewed the wire layer against MS-TDS and the client layer, and ran the
first mutation-testing round. Round 7 ran the suite under other connection
configurations. Rounds 8 to 11 chased memory retention, flakes under load, a
security review, model-based state-machine tests, a soak test, two reviews
of how the fixes combine, a warnings audit, and a GHC bug. After every few
rounds a docs-only agent updated the changelog, the comparison and the
questions file. The methods are described in [testing.md](testing.md).

**Cost.** The fast suite went from 7 s (89 examples) to about 65 s (2435
examples, parallel); the library diff was 16 files, +3028 −425; the test
diff 170 files, +27540.

## The adversarial review

The maintainer's concern, after the testing day, was that the library had
been made robust by accretion: error handling for errors that will hardly
come up, and fixes wedged in without extending the architecture. The review
was asked to find bad code, to list architectural changes that would make
the quirks fall into place, and to remove anything that added only clutter.
It could not see the tests, the documentation or the history.

Its findings, and what came of them:

| Finding | Outcome |
|---|---|
| **High.** Uninterruptible per-packet sends can defeat cancellation indefinitely once a peer stops reading. | Agreed. Sends run under plain `mask_`; any exception out of a send breaks the connection; the IGNORE packet is gone. The measured cost is zero spurious breaks (design.md). |
| **High.** Declaring untyped NULLs as `nvarchar(4000)` permits silent truncation of `ISNULL(@p, col)`. | Agreed. Reverted to `(max)`; `sql_variant` NULLs must be typed. |
| **Medium.** `reset` replays the session setup as one batch where `connect` ran one batch per statement. | Agreed. Both run one batch. |
| **Medium.** The transaction guard checks that a transaction exists, not that it is the same one. | Agreed. The descriptor is compared. |
| Simplify by making connections single-owner and discarding them after interrupted I/O. | Adopted for sends. Reads keep Attention recovery, since abandoned streams need the same cancel-and-drain path anyway; the resumable-drain machinery went. |
| Narrow the transaction contract; drop the isolation-level restoration. | Adopted: READ COMMITTED is set back; manual transaction control and `reset` in the body are unsupported and still detected. |
| Make `reset` an explicit pool-boundary operation. | Rejected by the maintainer: the lazy flag saves a round trip, which matters against Azure SQL from outside Azure; `sp_reset_connection` as an RPC covers the eager case. |
| Offer explicit SQL parameter types. | Deferred; `RawParam` covers the need. |
| Validate once before touching the connection. | Only the cheap part: the request body is forced before the first packet. |
| Contain implementation-specific machinery (GHC buffer internals in `Decoding`, a LOGIN7 parser with no client-side caller, an exact reproduction of the server's UTF-8 replacement). | The buffer check stays (fifteen contained lines that halve large reads' memory); the LOGIN7 parser moved to the tests; the UTF-8 decoder became text's. |
| The `callProcedure` parameter-name check duplicates the server's. | Removed (the review removed it itself). |

Kept against the review's direction: the reentrant mutex, the
close-during-send handshake (it guards the GHC IO-manager bug) and the arena
copying of small TLS records. The review's overall assessment was
"worthwhile hardening, but not rock-solid": the codec and framing fixes had
clear value, and the maintenance burden came from behavioural promises
(surviving interruptions, transparent deferred reset, inferred types,
level restoration) that the abstractions didn't comfortably express. The
simplification removed 520 lines from the library and added 292, most of
them module headers and haddocks stating the contract.

**The maintainer's answers** to the design questions the review raised are
the contract in design.md: one owner at a time; send the Attention at once
and drain later; keep the lazy `reset`; set READ COMMITTED back; an empty
default session setup (after confirming that LOGIN7's `fODBC` already sets
the ANSI options and that `ARITHABORT` matters only as a plan-cache key);
serialize concurrent use on the lock and document it as unsupported. The
maintainer also asked that the tests keep every scenario, including
now-invalid usage, and state what happens.

## The second adversarial review

After the optimisation round, the same reviewer was given the source of
the round's changes, again without the tests, the benchmarks or the
history, and asked for the same kind of review. Its framing: "source
comments quoting benchmark results are not independent evidence that an
optimization pays for its maintenance cost", and API compatibility no
reason to keep a problem. Its findings, and what came of each:

| Finding | Outcome |
|---|---|
| **P1.** `accursedUnutterablePerformIO` in the byte reads and both text decoders. | Gone. The byte readers run one load under `runRW#` with `touch#` (`unsafeDupablePerformIO` minus the `lazy` that boxed every result); the decoders read in `IO` with the buffer held by `withForeignPtr` for the whole decode. |
| **P1.** An unchecked public surface: `Row(..)`, `ResultSetInfo(..)`, the offset-based readers and decoders trusted their inputs; a misnamed `putCheckedValue`. | Every read of `Hmssql.Tds.Bytes` is bounds-checked (`error` outside the buffer, as `B.index`); `Row` and `ResultSetInfo` are abstract; `withCell`, `slice` and the text decoders check their spans; the unchecked writers are named so. |
| **P1.** Blocking socket reads under `unsafeWithForeignPtr`, whose contract a read that can block or be interrupted doesn't meet. | `withForeignPtr` for the socket reads; bounded `memcpy`s keep the cheap form. |
| **P1.** `feedRow` could write into a `Row` an earlier reader had returned. | Readers of one row share a feed count; `feedRow` refuses any reader but the one it last returned. |
| **P1.** The CA-file cache keyed by path and modification time could keep trusting removed certificates. | Removed; each connection reads its files. |
| **P1.** The lazy BEGIN, re-armed after an Attention, could skip the isolation level's cleanup. | Made moot by the eager BEGIN (below). |
| **P2.** `queryFold` ran its step for the rest of a batch after a step abandoned the response. | The response is checked before each step. |
| **P2.** The text-array writers needed `text` 2.1, and the bound said 2.0. | `text >= 2.1`. |
| **P2.** A declared 16 MiB value allocated 16 MiB as its first bytes arrived. | `connectValueAllocAhead`, 1 MiB by default. |
| **P1 on 32-bit.** Wire lengths converted to `Int` could go negative. | A 64-bit `Int` is required at build time; span checks written without overflow. |
| **P2 on alignment-sensitive targets.** Unaligned multi-byte loads at wire offsets. | Unaligned only on x86, x86-64, AArch64 and POWER LE; byte-wise elsewhere. |
| Undo the implicit BEGIN folding; make transaction batching explicit. | Undone: the BEGIN is a batch of its own before the body again. An explicit transactional-batch API is on the [backlog](backlog.md). |
| Remove the unconditional reader affinity. | Unbound by default; `connectPinReader` opts in. |
| Simplify the hand-written placeholder renderer (which didn't terminate on `minBound`). | `T.concat` and `show`; the array writer, digit writer and placeholder table are gone. |
| The metadata lookup tables optimise a once-per-column step. | The compact lists are back. |
| Parallel interpreters of the wire layout (sizing, writing, three row readers). | One layout description (`WireSink`) for `Put`, sizing and poking; one delimiter reader (`cellDelimiter`) for the walk, the row reader and the `Get` parser. |
| Ownership reconstructed from GHC allocation details (`ownBytes`). | Explicit in the row (`rowCellIsBorrowed`, `rowCellOwned`); `ownBytes` is gone. |
| Compiler-specific specialisation tricks and `rightAs = unsafeCoerce`. | `rightAs` is gone; the tuple instances and the three inlining rules stay, documented in one place. |

What it would keep: the linear lexer and query tree, the compiled
per-column decoders, row batches, the row view behind a safe boundary,
stable parameter declarations, bounded transport buffering, one copy of a
large value, the reentrant mutex's fast path, TLS key logging off, and
the send path's masking and breaking. What the resolution cost, measured
with the benchmark suite, is under
[design.md](design.md#memory-and-performance): the checked reads nothing
measurable, the eager BEGIN a round trip.

## The reviews of the value-streaming rewrite

The rewrite of sessions 47 to 49 had two reviews on 2026-11-01, each of the
library's source alone, with nothing compiled or run, and each written as a
card for the implementer. The maintainer's terms were that the findings be
implemented in order, the defects first; that a change costing performance
for a cleaner shape is acceptable, with no mechanism added to win the cost
back; and that a test stating a behaviour a finding would change stops the
work for a decision. The implementer assessed every finding in writing
before changing any code.

The first review had seventeen findings. Two were defects: a consumer
interrupted by an asynchronous exception read the rest of its row before
the exception reached the caller, so a `timeout` around a consumer waited
on a stalled server; and `cellDecoded` decoded with the default context and
allocation bound instead of the connection's
([bugs-found.md](bugs-found.md)). The rest were dead code left from the row
walk, structure (stop writing wire bytes in order to parse them again, read
a scalar from a whole value, one way to read and to skip a cell, validate a
parameter once), obvious performance mistakes (a lazy `Text` parameter
walked as a `String`, a skipped cell allocating a stream, and work repeated
per row that belongs once per result set), and comments lost in the port.
All were accepted, two with a refined remedy. A partial leading token held
after an interrupted reset wait can meet the new stop-at-row mode, so that
mode must resume metadata, where the review had said it couldn't; the
second review agreed with the implementer. And a user's pure conversion can
throw, so the driver keeps one failure handler per batch rather than none.

The second review confirmed the first's findings in the code, answered the
maintainer's questions, and had fourteen more. One of the first review's
own suggestions, a `RefuseRows` state, was clutter: it stated what an
existing check already enforced, and went. Rows before the first
COLMETADATA needed no state of their own, a failed row carries the position
where it stopped instead of a parallel skip recipe, the character modules
lost their offset forms, and a continuation that had come back
(`withSqlValueReader`) became a value. That last change cost 11% in time
and 9% in allocation on `SqlRow` decoding and was kept. The review also
asked that the optimizations which had come in with the fixes be redone as
a reproducible record, which became the controlled ablations of
[value-streaming-research.md](value-streaming-research.md). Its last
finding was the maintainer's to decide: a private `IORef` queue of
parameters protected nothing that `forM_` over the list doesn't, since the
guard that matters is the `Request`'s single take. The maintainer chose
`forM_`, and `Scale.ParameterResidency` confirms that the parameters aren't
retained.

## Incidents and lessons

* **A memory blow-up.** A model-based test agent ran its tests under five
  configurations at once at 5000 sequences each; each process grew to
  22–25 GB (115 GB on a 48 GB machine), swap reached 45 GB and free disk
  fell to 18 GB before the maintainer noticed. The test's executor thread
  swallowed `killThread`, leaking one thread and a closed TLS connection
  per sequence. Rules added: always cap heaps with `+RTS -M`, at most two
  test binaries at once, and treat a multi-GB test process as a finding.
  The chase also found that a closed TLS connection retained 3.3 MB, which
  was a real library problem.
* **The server under memory pressure.** The container (7.65 GiB) returned
  error 701 during heavy parallel runs.
* **Stale tests from parallel work.** Agents based on older commits wrote
  tests asserting behaviour another agent had just changed intentionally.
  Merges ran the combined suite to catch them, and the brief required
  resetting to the main branch first.
* **Agents misreporting their branch or commit.** The orchestrator located
  every commit by SHA before picking it. SHAs changed on cherry-pick, so
  pending notes that cited worktree SHAs had to be corrected.
* **Flakes under load were test problems**, fixed at the cause rather than
  by retrying: timing assumptions, Docker's accept queue overflowing at 64
  simultaneous TLS connects (which also exposed a real bug in handshake
  error typing), same-tick temporal-table timestamps, ephemeral-port
  exhaustion from the mock server's TIME_WAIT sockets, a watcher on the
  wrong capability, a lazy measurement.
* **A broad `pkill`** in one agent could have killed other agents' builds;
  banned.
* **About forty worktrees** accumulated before the maintainer asked for a
  cleanup; every branch was checked by patch-id and subject against the
  main branch before deletion, and thereafter each worktree was removed as
  soon as its work was merged.
* **Credentials.** The test password was never to pass through an agent's
  context. In session 5 an attempt to read it from the container was
  stopped by a safety classifier; the maintainer wrote an environment file
  for the agent to `source` instead. Session logs were redacted before
  being committed, and the agent brief, which held the password, was kept
  out of the repository.
* **The specification.** Agents could not read a PDF the maintainer had
  attached from a protected folder and used the MS-TDS pages on
  learn.microsoft.com instead.
* **Hackage** returned 503 from its main address during the GHC-version
  matrix run; the archives were fetched from its alternate address, checked
  against the index hashes.
* **The lazy BEGIN.** Sending `BEGIN TRANSACTION` with the body's first
  request saved a round trip per transaction, and the model tests found
  the first bug at once (an abandoned first stream's Attention cancelled
  the BEGIN, 2 to 12 times in 2000), then a nested-transaction identity
  case; a race in settling it was found by reading; the review found a
  cleanup it could skip. It was undone. The state machine had spread over
  request encoding, token application, response completion, reset and
  cleanup, with a keyword blacklist deciding which batches could carry the
  prefix.
* **Flakes under load**, found by running the suite beside 28 busy
  processes, were test problems again: mock tests that took turns by
  sleeping (and a `collectFor` that counted receive steps, not time); a
  test that assumed a 40 MB send blocks, which the container host's
  loopback buffers absorbed; a finalizer's socket close counted as a
  violation; an interruption count read before the interrupter had
  counted; a timing test whose premise (a read slower than its 200 ms
  timeout) the optimisation round invalidated; a `KILL` of a session id
  another test had inherited; a deadlock through the client between two
  tests sharing a table. Each was fixed at its cause
  ([testing.md](testing.md#writing-tests) has the rules that came of it).
* **A crash in the garbage collector.** The full suite died of SIGSEGV in
  `evacuate` during a test that reads every thread's label. Traced to
  GHC's `threadLabel` returning a null pointer for an unlabelled thread
  (GHC #27618, fixed after 9.14.1); the tests read labels through a
  wrapper of the primop. Two earlier crash reports turned out to be
  mutation-testing mutants, not this.
* **Scratch databases were never dropped on Azure**: the drop was guarded
  by `IF DB_ID(...) IS NOT NULL`, and `DB_ID` of another database is NULL
  in Azure's `master`. No test failed, since the guard made the batch a
  no-op. `dropDatabase` now fails if a drop doesn't drop.
* **A hang that was a slow write.** Two `Mars.Cancel` tests timed out on
  Azure in every whole-suite run, never alone, and looked like a lost
  Attention acknowledgement or a stalled SMP window. A dump of both sides
  at the timeout (the client's sessions and a ring of the SMP packets in
  and out; the server's `sys.dm_exec_requests` and `sys.dm_tran_locks`
  for the session) showed neither: the cancel had returned, and the test
  was waiting on its own writer, an `UPDATE` of 30,000 rows held up to
  42 s by the log-rate governor of a database at 100% of its log rate.
  Dump both sides before theorising about the protocol. The diagnostic
  code hung one run itself: its sampler thread caught `SomeException`
  around each query, so the `killThread` meant to stop it was swallowed
  whenever it landed in a query.
* **A bulk copy equivalence harness** (each column type loaded by
  `bulkInsert` and by `executeMany`, the two tables compared byte for
  byte) found the one silent data-loss path in the new code: a character
  outside a discovered `varchar` column's code page stored as `?`.
* **Measuring on a shared 16-core machine with 32 hardware threads.** `Mock` and `Live` results
  varied up to twice between runs at `-N32` (parallel collections over
  every capability); the rule became `+RTS -N1`, the two executables
  alternated, two rounds or more, with 10% inside the noise. Numbers from
  before a benchmark changed what it forces aren't comparable with later
  ones.
* **What the maintainer asked about.** What "benchmarks" meant in a review
  (decoding a million rows, streaming 256 MiB, against the pre-testing
  build, reporting any regression over 20%); whether a slow `stack test`
  would get the package rejected upstream (Hackage doesn't run tests;
  Stackage and distribution builds do, without a SQL Server, hence the
  no-server mode); whether the test suite's `["SET ARITHABORT ON"]` default
  was a crutch (it was coverage of the reset-with-setup path; the default
  run now uses what applications get, and the matrix covers the rest).
* **A fault blamed on three things before it was measured.** While the
  pipe backend was probed on Windows, the local SQL Server kept refusing a
  first connection and then stopped listening for up to a minute. It was
  put down to the pipe's impersonation level; then declared not to be
  hmssql's doing, after a control with Microsoft's client that the
  session's own probe had contaminated; then put down to the reads of the
  server's error log that ended each probe. Each was an inference from
  runs that overlapped, and each was reported to the maintainer as a
  finding before it was one. An A-B-A run on the level and an alternating
  run on the log reads, each with nothing else connecting, showed that
  neither mattered, and that the failures come with the first connections
  after an idle spell. The cause is still unknown. The lesson is the
  order: isolate first, and count before explaining.
* **Two results that tested nothing.** A run of `--match "/Wire/"` from
  Git Bash reported no failures because it ran no examples, the shell
  having rewritten the pattern into a path. And a group that passed was
  taken as evidence about the mock server, which it never used. Both were
  caught by checking what had run. How many examples ran and what they
  exercise are part of a result.
* **A bug that no probe could show.** The overlapped backend passed every
  probe and then lost about one receive in sixty under the test suite.
  Windows cancels a pending operation when the thread that started it
  exits, and the short probes had no thread that exited. The mock-server
  tests found it, and a count of the receives aborted on a handle nobody
  had stopped measured it before and after the fix: 5 in 294 handles,
  then none in 5,880.
* **A cause recorded without a reproduction.** On Windows
  `Resources.CloseFailure`'s finalizer test failed three times in about
  fifteen runs of its group. The record said that network's finalizer
  for the socket and the connection's run in no fixed order, and the
  test was left as it was. The test had not been looped. When it failed
  again, in other ways, in the runs against SQL Server 2019, a loop of
  the module alone failed in 56 runs of 200, and a build that logged
  the socket numbers showed the module closing its own sockets: its
  broken close left a `Handle` open on Windows, and the handle's
  finalizer closed the number a second time
  ([bugs-found.md](bugs-found.md#in-the-test-suite)). An explanation
  that fits one symptom is a guess until the failure has been made to
  happen with the evidence in view.
* **A check that selected the wrong branch.** To type-check the socket
  backend's non-Windows code on Windows, the preprocessor was told to
  undefine the platform's macro, and the module compiled without a
  warning. It was the Windows branch again: GHC defines the macro after
  the command line is read. The preprocessed output showed it, and a
  copy with the condition renamed gave the real check.
* **A day of results from the wrong build.** Every build of session 23
  was `stack build --fast`, for speed, and every result up to its last
  hours was therefore of a library without optimisation, which is not
  what `stack test` builds. The standard build changed three results.
  Two groups of timing-dependent live tests that failed over a pipe
  passed, 15 runs of 15. One mock test that had passed failed, because a
  faster client finished `connect` before the mock's signal. And the
  backend's cost per round trip came out at 36 µs, not 48. A result is
  reported for the build the user gets; a faster build is for finding
  out whether the code compiles.
* **Three faults that looked like hmssql's and were not, and one that
  looked like a flake and was.** Under GHC's native I/O manager a group
  hung, then a group crashed. Each time the thing just built (a path
  through the manager) was the suspect, and each time the fault was
  first narrowed to that path and then, by taking hmssql out of the
  probe, shown to be the manager's: a killed file read that never ends,
  and a crash with a few dozen busy sockets. What settled it was a
  status from the stuck thread (blocked in a foreign call), a symbol for
  the crash address, and a probe with network's own calls. Two wrong
  causes were tried on the way, and one of them was written into a
  comment as fact before the experiment that refuted it. The other way
  round, two memory tests that failed only in a run of the whole suite
  looked like noise from that run, and were a leak on every platform,
  which the same tests pass over when run alone.
* **A runner that hung more often than the tests.** The Git Bash runner
  failed to fork every few hundred groups once several runs went at
  once, and stalled three chains before it was replaced by a Python
  script that starts the test binary directly. A chain was also twice
  left using a binary that a rebuild then could not replace. And the
  server was updated and restarted by the machine in the middle of a
  run, which looked for a minute like the pipes failing again.
* **A total that counted ten groups twice.** The runner that gave each
  top-level group a process of its own took the groups from a dry run's
  listing, where a spec with a serial and a parallel part appears twice.
  It ran those ten twice and reported 208 groups and 3,640 examples for
  a suite of 198 and 3,373, and one commit message carries the larger
  figures. The dry run's own summary line had the right total all along.
* **A fix checked on the wrong server.** The test matrix's first failure
  was the model's, on SQL Server 2022: a failing stream abandoned before
  its batch ran. The session changed the model's rule, ran the model
  tests against SQL Server 2025, where the state hardly ever arises,
  saw them pass, wrote the fix into the documents and committed it. The
  rule tested whether a stream was "live", which the model says only of
  a stream with no error pending, so it left out nothing new, and the
  rerun failed on it again six hours later. Run against SQL Server 2022
  itself, the old rule failed three times in three and the corrected
  one passed five in five, which took four minutes.
* **Three matrix runs shrinking for hours, and a session that ended.**
  The slow fuzz had been given a limit of 50 shrinks after the
  eight-hour run of 2026-10-02; the limit counts steps, not cases, and
  three slots spun for one to two hours before stack samples (gdb, with
  the container's executable for symbols) showed `joinRow` under them.
  Later the rerun of the failed runs died with the Claude Code session
  at 31 of 49, since it had been started as the session's background
  task; the script now takes `--rerun` more than once, and the rest ran
  detached (`setsid nohup`).
* **A run that did not try what it was named for, and a log read too
  soon.** On 2026-10-16 the run with `HMSSQL_TEST_HOST=localhost` and the
  default `auto` was meant to try both addresses of `localhost`. The
  setup hook's line said the server reported Shared Memory, which `auto`
  prefers when it is enabled, so the run passed without the
  several-address connect; it ran in the rerun with
  `HMSSQL_TEST_PROTOCOL=tcp`, and testing.md says so now. The server's
  log had been read before any run and showed nothing, which says
  nothing of the runs; read afterwards it held 37 errors 17191 and two
  errors 12412, the first about terminated sessions (most likely the
  tests' own `KILL`s, not checked) and the second Query Store errors,
  not looked into. Read the
  setup hook's line in the first minute of a run and the log after the
  last.
* **Two rejected attempts nobody looked at until they were built.** The
  first plan for value streaming was implemented twice on side branches,
  and each time the maintainer rejected the result, a control block of
  mutable registers that the plan had not asked for. The plan's core (the
  `Parser` module and the row recipe) could have been shown before the
  port. One attempt also widened a plan decision to keep a golden test's
  row unchanged, where the decision outranked a table captured before it;
  a test that blocks a decision is a question for the maintainer.
* **A second draft by another model.** The maintainer had ChatGPT write
  the linear-types assessment independently. It corrected two claims of
  the first draft: an exception that abandons a writer is harmless for the
  memory only, since a message cut short still needs the Attention or the
  broken connection, and the coercion rests on two assumptions rather than
  one, since each wrapped function must also run its linear argument at
  most once. Its own document had no measurements and no verdict, so the
  version kept is the first draft with the corrections. An independent
  draft is a good review of the claims; the version kept is the one with
  evidence behind it.
* **Measurements that couldn't be attributed.** In the value-streaming
  rewrite the first review's fixes and the first optimizations went into
  one commit, measured with one saved binary that matched no commit, so
  what each optimization did couldn't be told; the second review had them
  removed one at a time from the cleaned code and measured again. Commit
  each optimization alone, keep the binary it was measured with, and time
  only with nothing else building. In the ideas run, parallel full suites
  saturated SQL Server's worker pool even with separate test databases, so
  suites against the server run one at a time, while builds and
  fixed-work probes can run beside them.
* **A card's reading of a library is not a measurement.** The card of
  session 66 read network's source for what its calls do under GHC's
  native manager, and three of its claims were wrong in practice: a
  reset was said to read as the end of the stream, which it does only
  when it arrived before the receive; the non-threaded runtime was said
  to work on network's path, where it froze; and a blocked send was the
  one thing it expected to wait, where `close` could wait too. Each was
  found by a probe of network's calls alone, a few dozen lines built
  against the same checkout, in minutes, after the suite had failed. A
  probe of the calls a design rests on, before the design, is cheaper.
  The non-threaded freeze was also first taken for a slow run: a run
  with no output and no CPU for ten minutes is hung, and is to be looked
  at then.

## Lessons for the next round

* Fix flakes at their cause. Every flake in this project was a real
  assumption, in the test or in the library.
* Reviews of the fixes as a whole found regressions that no single test
  round did (two performance regressions, two swallowed exceptions). Do
  them.
* Mutation testing found no bugs but made the suite pin down what it had
  only been exercising; the kill rate is the more honest coverage number.
* A test of now-invalid usage should say what happens, not be deleted.
* Machinery to survive rare interruptions costs more than a broken
  connection does. Prefer a clear outcome and a documented constraint.
* Measure before keeping a defensive change: the uninterruptible send was
  introduced on a misdiagnosis and measured out afterwards.
* A round trip saved by machinery spread across layers (the lazy BEGIN)
  costs more than the round trip. Offer the saving explicitly or not at
  all.
* Optimise in place only where the frequency is known when the code is
  written (per row, per cell, per byte sent), and keep one description of
  each wire layout; the second review's findings were where that line had
  been crossed.
* Profile before choosing among planned optimizations, over enough iterations that
  the case outweighs its setup, and read each closure beside the STG of its module.
  The largest cost of the 2026-11-03 pass, a row's preparation that GHC
  eta-expanded into every row, was on no list, and a typed decoder's closures sit
  in the module that names its row type, so a profile of `Hmssql.Decoding` alone
  had made the typed path look lean.
* A reader inlined into several places multiplies every branch it gains,
  and the branch a rare value takes costs every copy its code; but taking
  a branch out of line moves its per-cell work behind a call that may
  build closures for each value. Session 62 found both in one change: the
  long-value branches belonged out of line and the common read inside,
  and only a benchmark of the common shape (a row through `singleField`)
  showed the second.
* Check object size beside allocation. Choosing a cell's delimiter once per
  column saved 10% of one dataset's allocation and doubled the code of every
  module of row types.
* Measure what an application pays, not only what a benchmark runs. The
  benchmark binary's few row types hid that every typed decoder was 25 KB per
  field; a generated program of the users' shape found it in one compile.
* Parallel experiments in worktrees work when each has one idea, a shared brief
  with the metrics and their pitfalls, and a report format; the coordinator then
  merges, and only it times, with nothing building. Tell running agents when the
  base moves, or their numbers compare against the wrong thing.
* Measure allocation exactly and time rarely. `--csv` at `--stdev 3` gives bytes
  per iteration that other builds don't disturb; time needs an idle machine and
  five pairs or more, and a bisect over saved binaries of each merge finds a
  regression faster than reading the diffs.
* Re-measure a base before comparing against it. A stale library made one figure
  wrong by a third, and three agents found it; a benchmark loop that made an extra
  call per row was most of an apparent regression.
* A safety review of optimised code pays: the reads it made checked and
  sequenced cost nothing measurable, once each read stopped boxing its
  result.
* Check a fix where the failure was seen: the same server version, the
  same configuration, and a run of the old code beside it that fails.
  A pass somewhere the failure never showed says nothing.
* A test that waits a fixed time for something to happen, or expects a
  result to take longer to read than something else takes, fails on a
  faster client or a busier server. The matrix found ten; each was fixed
  by waiting for the event, or by a result that can't arrive first.
* A feature's research piles up beside the documents: MARS left nine
  write-ups, a plan and five review reports, half of all the documentation,
  with their conclusions already copied into the documents by area and
  their corrections scattered. Consolidate when the feature lands, into
  one research record per topic, and put the decisions in `design.md` and
  the facts in `protocol-notes.md` as they are made; the index in the root
  `CLAUDE.md` says where each area's facts go.
* A review's own suggestion can be clutter: the first review of the
  value-streaming rewrite added a state that the second one removed. A
  later review checks the earlier one's changes as it checks the
  implementer's.
