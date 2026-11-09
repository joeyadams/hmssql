# hmssql developer documentation

For people working on hmssql itself. The [guide](../guide/README.md) is for
people using it; the Haddock of the `Hmssql` module is the reference. The
documents here record what hmssql does and why, what the server was seen
to do, what remains to be done, and how it was built. The root
`CLAUDE.md` says which sections to read before changing an area.

## By area

| Document | Read it for |
|---|---|
| [design.md](design.md) | The behaviour contract and the reasons for it, with the alternatives each decision rejected: the architecture and the transports, who owns a packet's bytes, connection ownership and MARS, interruption and cancellation, the connection's lifecycle, session setup and `reset`, transactions, queries, parameters and encoding, date and time, decoding and streaming values, what the wire layer checks, TLS, exceptions, memory and performance (with the RTS options that matter), and the platform workarounds. |
| [protocol-notes.md](protocol-notes.md) | What TDS, SQL Server, Azure, the `tls` package and the platform were seen to do, as measured, with the conditions: framing, negotiation, TLS in both modes, LOGIN7, tokens and ENVCHANGE, transactions, session reset, MARS and SMP, the server under load, RPC, and data types. |
| [limitations.md](limitations.md) | What hmssql doesn't do, the gaps with their workarounds, behaviours worth knowing about, what MARS doesn't do, and open questions. |
| [backlog.md](backlog.md) | What is still to be done: before the release (the API review's open items, Windows, the dependency bounds) and after it, the upstream reports to file, and the checks to revisit. |
| [bugs-found.md](bugs-found.md) | Every bug found and fixed before the first release, by area, with cause and fix, and the test suite's own. |
| [testing.md](testing.md) | Running the suite (environment, configurations, platforms and SQL Server versions, the test matrix, GHC master on Windows), writing tests, the benchmarks and how to compare two builds, the suite map, and the methods used. |
| [review-checklist.md](review-checklist.md) | How to review a change: which documents to read first, the question each kind of change raises, the questions to ask of each change, and how to settle a doubt against the server. |
| [features.md](features.md) | What hmssql does differently from other SQL Server clients, and why. |
| [azure-sql.md](azure-sql.md) | What Azure SQL Database does differently, which tests skip or adapt there and why, how to run the suite there, and what each run established. |

## Research records

Each records the questions an area was measured for before or while it was
built, how each was measured, the answers with their numbers and
conditions, what the implementation then did, and what stays unverified.
The contract is in design.md; these are the evidence.

| Document | Read it for |
|---|---|
| [mars-research.md](mars-research.md) | MARS (2026-09-29 and 30): the two spikes and seven probes, the numbered server assumptions the `Mars` and `MarsTx` tests cite, and where the implementation departed from the research. |
| [windows-research.md](windows-research.md) | The Windows work (2026-10-03 to 11-07): the pipes behind Shared Memory and Named Pipes and how the server wants writes split, the pipe client's impersonation level, the server's pipe listeners, a pending operation that dies with its thread, handle counts, what the backend costs, the suite over the pipes and over TCP, the non-threaded runtime, GHC's native I/O manager (the path built and removed, network's TCP path, the manager's fixes on a GHC branch, the pipes through the manager), and what stays unverified. |
| [value-streaming-research.md](value-streaming-research.md) | The rewrite of the decoder and encoder pipeline so that a single value can stream (2026-10-31 to 11-03): why the row walk went, the rejected attempts, the reader recipes, the server's behaviour with streamed values, and what the rewrite cost against the row walk. |
| [performance-research.md](performance-research.md) | Code size and speed: the measurements of the row-walk implementation, and the optimization runs of 2026-11-03 and 04, with where an application's object code came from, the traps GHC set, and what each idea kept or rejected, with its numbers. |
| [linear-types.md](linear-types.md) | A write-up for the Haskell community of what linear types did for hmssql (the ownership of packet buffers), how they compare with Rust's borrow checking, and why hmssql removed them. |

## History

| Document | Read it for |
|---|---|
| [development.md](development.md) | How hmssql was built with AI agents: the sessions and models, the orchestration, the reviews and their outcomes, incidents and lessons. |
| [history.md](history.md) | The lineage from ms-tds and mssql-simple through mssql to hmssql: contributors, upstream releases, and the timeline. |
| [mssql-comparison.md](mssql-comparison.md) | For anyone porting code from the unreleased `mssql` package: what hmssql dropped, covers and still lacks, and the behaviour changes. |

## Upstream reports

Bugs found in other projects, each with a repro that needs no hmssql.

| Report | What it is |
|---|---|
| [ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md) | GHC's kqueue and epoll I/O managers keeping a stale registration for a closed descriptor, with repros and a draft issue. |
| [ghc-threadlabel-null](upstream/ghc-threadlabel-null/README.md) | `threadLabel` on an unlabelled thread crashing the garbage collector (GHC #27618, fixed after 9.14.1), with the tests' workaround. |
| [ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md) | GHC's default I/O manager on Windows firing no timer for seconds once tens of thousands of pending delays expire, which abandoned `timeout`s are (not reported yet). |
| [ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md) | A crash in GHC's native I/O manager on Windows with a few dozen busy sockets, reproduced with network alone (not reported yet; a fix is on a GHC branch). |
| [ghc-winio-file-read](upstream/ghc-winio-file-read/README.md) | Under GHC's native I/O manager, a thread killed during a file read may never end (not reported yet; a likely fix is on the same branch). |
| [azure-sql-early-attention](upstream/azure-sql-early-attention/README.md) | Azure SQL Database ending a MARS connection when it reads a request and its Attention together, with a trace (not reported yet). |
| [tls-session-code-size.md](upstream/tls-session-code-size.md) | A proposal to the `tls` package: its session serialisation pulls about 5.5 MB of dependencies into a client linked without split sections (drafted, not submitted). |

The protocol specification is
[\[MS-TDS\]: Tabular Data Stream Protocol](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/b46a581a-39de-4745-b076-ec4dbb7d13ec);
source comments cite it by section number.
