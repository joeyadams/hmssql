# hmssql: notes for Claude

hmssql is a native Haskell client for Microsoft SQL Server and Azure SQL
Database, implementing TDS 7.4 and 8.0 over a socket. It is pre-release at
version 0.1.0 on the orphan branch `main`, and the API stays unstable until
it reaches Hackage. The owner is Joey Adams; the code was largely written
by AI agents under his direction, and the README says so up front.

This file is the index. Before changing an area, read the documents the
index names for it, so the decisions already made and the server facts
already measured are known before the work starts. After changing an
area, update the same documents: they are the project's memory, and
commit messages are not. "Cleaning up after a change" below is the
checklist.

## Layout

The repository is a project of several packages, as hpgsql's is, and each
package has a folder of its own. Only `hmssql/` is published, so someone
building the library compiles none of the tests, benchmarks or examples, and
its package ships none of the documents under `docs/`.

* `hmssql/` is the library package: `package.yaml`, `hmssql.cabal`,
  `ChangeLog.md`, `src/` and `cbits/`. In `hmssql/src/Hmssql/`, `Hmssql`
  re-exports the common API, `Hmssql.Tds.*` is the wire protocol, and
  `Hmssql.Connection.Internal` holds the connection, its sessions and the
  reader thread.
* `hmssql-tests/` is the package of the hspec suite `hmssql-tests` (about
  6,000 examples): pure properties, mock-server tests and live tests.
  `hmssql-tests/CLAUDE.md` has the rules for working there.
* `hmssql-bench/` is the package of the tasty-bench suite. `Bench.Sql` needs
  no server, and `Bench.Live` and `Bench.Mars` need one.
  `hmssql-bench-azure/` is a program that runs in Azure.
* `examples/` are complete programs written for people to read: `shop-db`,
  `crud`, `odata` (the streaming OData server), `bulk-copy` and
  `managed-identity`. They read `MSSQL_*` environment variables, and each
  has a hand-written `.cabal` file, with no `package.yaml`. Their comments
  are for the human reader of the example, and never the checklist of
  what an example covers.
* `docs/guide/` is the user guide, nineteen short pages in seven
  sections, and `docs/dev/` is for people working on hmssql.
  `docs/CLAUDE.md` says where things go.
* `site/` builds the guide and the Haddock into a static HTML site for
  GitHub Pages (`site/build.sh`); `docs/CLAUDE.md` says how.
* `scripts/` holds the test matrix and the Azure scripts.

## Where to look before changing an area

The developer documents are by area, and each answers one kind of
question:

* `docs/dev/design.md` is the behaviour contract, with the alternative
  each decision rejected. Read its section before touching the area, and
  don't reopen a decision without saying so.
* `docs/dev/protocol-notes.md` is what TDS, SQL Server, Azure and the
  platform were seen to do, as measured.
* `docs/dev/limitations.md` is what hmssql doesn't do and why, and
  `docs/dev/backlog.md` is what is planned.
* `docs/dev/bugs-found.md` is what went wrong before, by area, with cause
  and fix. A change in an area should not reintroduce one.
* `docs/dev/testing.md` is how to run and write tests, with the suite map.
* `docs/dev/development.md` is how the AI sessions went, and the lessons.
* `docs/dev/README.md` lists the rest: the research records
  (`mars-research.md`, `windows-research.md`,
  `value-streaming-research.md` and `performance-research.md`),
  `features.md`, `azure-sql.md`, `review-checklist.md`, `history.md`,
  `mssql-comparison.md`, `linear-types.md` and `upstream/`.

The Haddock is the reference and the guide shows the API in use; both
follow `design.md`. By area, with the section names to search for:

| Area | Code (`Hmssql.`) | `design.md` | `protocol-notes.md` | Tests (`--match`) | Guide (page) |
|---|---|---|---|---|---|
| Wire format: packets, tokens, type info, values, the reader recipes | `Tds.Packet`, `Tds.PacketWriter`, `Tds.Token`, `Tds.TypeInfo`, `Tds.Parser`, `Tds.Value`, `Tds.Scalar`, `Tds.Bytes`, `Tds.Primitives` | What the wire layer checks; Who owns a packet's bytes | Framing and packets; Tokens and ENVCHANGE | `Wire`, `Protocol` | `how-it-works` |
| Connecting: the transport (TCP, and on Windows Shared Memory and Named Pipes), PRELOGIN, TLS, login, Entra ID, Azure, redirects | `Connection`, `Connection.Backend`, `Connection.Backend.Windows`, `Connection.Backend.WinIO`, `Connection.Tls`, `Connection.Internal` | Connection lifecycle; Encryption and TLS; Platform workarounds | PRELOGIN to LOGIN7 (seven sections, among them The tls package); Azure SQL Database | `Connection`, `Protocol`, `Security` | `connecting`, `encryption` |
| The connection: sessions, the reader thread, the mutex, ownership | `Connection.Internal`, `Connection.Locking` | Architecture; Connection ownership and concurrency | | `Concurrency`, `Resources`, `Model` | `pools-and-threads` |
| Interruption and cancellation: Attention, `timeout`, abandoned streams | `Connection.Internal` | Interruption and cancellation | | `Concurrency`, `RequestInterruptSpec` | `errors-and-timeouts`, `streaming-rows` |
| Session setup, `reset`, `release`, pools | `Connection.Internal` | Session setup and reset | Session state and reset | `Release`, `ResetSpec`, `Session` | `connecting`, `pools-and-threads` |
| Transactions | `Transaction` | Transactions | ALL_HEADERS and transactions | `Transaction`, `TransactionSpec`, `LockingSpec` | `transactions` |
| MARS | `Tds.Smp`, `Connection.Internal` | MARS: several responses on one connection | MARS and SMP | `Mars`, `MarsTx`, `Model` | `mars` |
| Queries, parameters, batches, procedures | `Query`, `Query.Internal`, `Query.Lexer`, `BatchQuery` | Queries; Parameters and encoding | RPC and stored procedures | `Query`, `Shapes`, `Rpc`, `Api` | `parameters`, `composing-queries`, `result-sets`, `stored-procedures`, `batches` |
| Streaming rows and values | `Query` (`queryS`, `withQueryS`), `Decoding` (`streamField`), `Encoding` (`binaryStream`), `Tds.Parser` | Queries; Decoding; Parameters and encoding; Memory and performance | | `Shapes`, `Scale`, `Wire.StreamWhole`, `Concurrency.ValueConsumer` | `streaming-rows`, `streaming-values` |
| Types, decoding, encoding | `Types`, `Decoding`, `Encoding`, `SqlValue`, `Tds.Parameter`, `Tds.CodePage`, `Tds.Utf16` | Decoding; Date and time; Parameters and encoding | Data types | `Types`, `Differential` | `reading-rows`, `decoders`, `encoders` |
| Bulk copy | `BulkCopy`, `Tds.PacketWriter` | Parameters and encoding ("Bulk copy"); Architecture ("Reading and writing bytes", "Who owns a packet's bytes") | Bulk load | `Bulk` | `bulk-copy` |
| Catalog and SQL type names | `Catalog`, `SqlType` | Architecture (the module table) | | `Catalog` | |
| Errors | `Errors` | Exceptions | | `Api`, `Review` | `errors-and-timeouts` |
| Performance, memory and code size | | Memory and performance; RTS options | Platform and tooling | `Scale`, `Resources`, `hmssql-bench/`, `scripts/code-size.sh` and `scripts/perf-compare.sh` | |
| Platform | | Platform workarounds | Platform and tooling | | |

Six areas have a document of their own as well:

* Azure has `docs/dev/azure-sql.md`: what Azure SQL Database does
  differently, and the suite's runs there.
* MARS has `docs/dev/mars-research.md`: the questions the spikes and
  probes asked, the answers with their numbers, and the numbered server
  assumptions the `Mars` and `MarsTx` tests cite.
* Windows has `docs/dev/windows-research.md`: what the probes measured
  about pipes, overlapped I/O, the non-threaded runtime and GHC's native
  I/O manager, and what was built and removed.
* Streaming values has `docs/dev/value-streaming-research.md`: how the
  decoder and encoder pipeline was rebuilt so that a single value can
  stream, the reader recipes, and what the rewrite cost against the row
  walk it replaced.
* Performance and code size have `docs/dev/performance-research.md`: the
  optimization runs, where an application's object code came from, the
  traps GHC set, and what each experiment kept and rejected, with its
  numbers.
* The platform bugs have `docs/dev/upstream/`, a folder per report with
  its repro.

`limitations.md`, `backlog.md` and `bugs-found.md` have a section or an
entry per area; search them for the area's name.

## Cleaning up after a change

A change is done when the code, the tests and the documents agree. Before
reporting it finished:

* A behaviour decision goes in `docs/dev/design.md`, in the section of
  its area, with the alternative it rejected. When a decision changes,
  rewrite the paragraph; don't append a correction under it.
* A server or protocol fact goes in `docs/dev/protocol-notes.md`, with
  the conditions it was measured under.
* A gap, a workaround or a behaviour worth knowing goes in
  `docs/dev/limitations.md`. Work now done comes out of
  `docs/dev/backlog.md`, and new planned work goes in.
* A bug found and fixed goes in `docs/dev/bugs-found.md`, by area, with
  cause and fix.
* A public API change goes into the Haddock and the guide page of its
  area, and into `hmssql-tests/DocExamplesSpec.hs` when an example changes.
* A new document gets a row in `docs/dev/README.md`. Documents aren't
  shipped with the package, so none goes in `hmssql/package.yaml`. A new
  module under `hmssql/src/` needs no change there either, because
  `hmssql/package.yaml` names no `exposed-modules` and hpack exposes every
  module it finds.
* A session worth recording gets one row in `docs/dev/development.md`,
  and an incident or a lesson gets a paragraph there.
* `hmssql/ChangeLog.md` stays one entry.

What not to do, because it is how the documentation came apart before:

* No new document or folder per feature. A feature adds to the sections
  of its area in the existing documents. The research record (next
  section) is the one document per topic.
* No "since implemented", "update" or "previously" banners. A document
  describes the current state; its history is in `development.md` and in
  git.
* No plans, review reports, checklists or question lists in the tree,
  apart from the cards at the repo root (below). A plan's decisions go into
  `design.md` once they are taken, a review's defects go into
  `bugs-found.md` and its narrative into `development.md`, and the documents
  themselves stay in the session.
* No working-notes files.

## Cards at the repo root

The repo root can serve as a Kanban board. A card is one document for work
in progress, such as `PLAN-value-streaming.md`, that a session can run from.
It may be committed on a local working branch, on these conditions:

* A card doesn't stay there forever. Implementing it includes folding its
  decisions into `docs/dev/`, as the list above says, and deleting it.
* A card that remains a proposal moves off the board. Its planned work goes
  into `docs/dev/backlog.md`, and the card itself leaves the repository.
* A card is never pushed upstream. It is gone from a branch before that
  branch is pushed or merged into `main`, and a card's deletion alone doesn't
  do that for a branch whose history is pushed, so check the history too.

A card is the only exception. It isn't the place for a project fact that
should outlive it, and it doesn't excuse a new document under `docs/`.

## Research spikes and probes

When an area has to be measured before it can be designed (MARS was built
from two spikes and seven probes), the throwaway code stays on a local
branch, and the findings go in one document, `docs/dev/<topic>-research.md`:
the questions asked, how each was measured, the answers with their
numbers and conditions, what the implementation then did differently, and
what stays unverified. The server facts go into `protocol-notes.md` as
well, because that is where the next reader looks. The probes' own
write-ups are not committed. `docs/dev/mars-research.md` is the model.

## Building and testing

* `stack build` builds the library and the examples. hpack generates
  each package's `.cabal` file from its `package.yaml` (`hmssql`,
  `hmssql-tests`, `hmssql-bench` and `hmssql-bench-azure`): edit the
  `package.yaml`, then run `hpack` in that folder, and commit both. The
  examples' `.cabal` files are written by hand. The development build
  options (`-j`, and `-O0` for the test suite) are in `stack.yaml`, not in
  any `package.yaml`, so that the published package builds serially at
  cabal's default optimisation, as any other does.
* `stack test` without a server runs the pure and mock tests, which is
  cheap. With `HMSSQL_TEST_PASSWORD` set, the live tests run too, against
  the SQL Server 2025 in the `sqlserver2025` Docker container on
  localhost:1433 (`HMSSQL_TEST_HOST` defaults to `::1`).
* `scripts/test-matrix.sh` runs the suite under several connection
  configurations (encryption modes, packet sizes, a session setup, `mars`
  and `slow`), on every GHC version in `tested-with` and against SQL
  Server 2017, 2019, 2022 and 2025, with nothing but Docker; `--prepare`
  builds and seeds without running, and the whole default matrix is an
  overnight run.
  For `stack test`, `HMSSQL_TEST_MARS=1` runs the whole suite over MARS
  connections, and `HMSSQL_TEST_SLOW=1` includes the slow tests. Stack runs
  the suite in `hmssql-tests/`, so a path given to it is relative to that
  folder.
* Benchmarks: `source ~/.hmssql-test-env && stack bench
  --benchmark-arguments '-p Sql'`; `--csv before.csv`, then `--baseline
  before.csv --fail-if-slower 10` compares two runs. Don't pipe `stack
  bench` through `head`, because SIGPIPE kills the run.
  `scripts/perf-compare.sh BASE-COMMIT` compares the working tree with a
  commit in code size and in time, with nothing else building.
* `site/build.sh` builds the documentation site into `_site/`, and fails
  on a broken link in the guide. Run it after changing the guide or the
  Haddock's links; `site/build.sh --publish REMOTE` publishes it, only when
  asked.
* Keep build verification minimal: `stack build`, and the no-server suite
  when the change warrants it. macOS has no `timeout` command.
* To run the examples against the local server: `source
  ~/.hmssql-test-env`, then `export MSSQL_PASSWORD="$HMSSQL_TEST_PASSWORD"
  MSSQL_HOST=localhost MSSQL_CA_CERT="$HMSSQL_TEST_CERT"`.

## Credentials and servers

**The local SQL Server.** The developer's credentials are in
`~/.hmssql-test-env`, a file to `source` before `stack test`, `stack bench`
or the examples:

```sh
export HMSSQL_TEST_PASSWORD=******
export HMSSQL_TEST_CERT=$HOME/sqlserver.crt      # the server's self-signed PEM certificate
```

That file existing is permission to use the local server: the developer
set it up for that. Never extract the password from the Docker container,
from a config file or from anywhere else, and never print the file. If it
is missing, ask.

**Azure SQL.** The Azure scripts (`scripts/azure-sql-test.sh`,
`azure-bench.sh`, `azure-bulk-copy.sh` and `azure-managed-identity.sh`)
keep their state in `~/.config/hmssql-azure`: the generated SQL admin
password as `<server>.password`, the staged upload, and the logs. They
take the developer's resource-name prefix and subscription from
`AZ_PREFIX` and `AZ_SUBSCRIPTION`, which `~/.hmssql-test-env` also exports
(for example `export AZ_PREFIX=alice`). `scripts/azure-sql-test.sh env`
prints `HMSSQL_TEST_*` exports for a local run against Azure.

Never access Azure SQL, and never run an `azure-*.sh` command that touches
Azure, unless the user explicitly asks for it or has given permission in
this session. Azure costs money, and the database there is shared state.
Never scale the Azure database without asking. Don't hard-code the
developer's prefix, subscription or server name in the repository; they
may appear only as examples.

## Design decisions not to reopen

The full contract, with each rejected alternative, is
`docs/dev/design.md`. The short list:

* A `Connection` has one owner at a time. The reentrant mutex stays, so
  other threads serialize and a newer request abandons an older stream
  with `ResultAbandoned`; sharing is documented as unsupported.
* Sends run under plain `mask_`, and any exception out of a send breaks
  the connection. There is no `uninterruptibleMask_` and no IGNORE packet,
  with one exception: the MARS flow-control ACK. Reads keep the eager
  Attention: an asynchronous exception mid-read cancels the statement at
  once, the next request drains, and an interrupted drain breaks the
  connection.
* `reset` is a lazy flag carried by the next request. An immediate reset
  is `callProcedure conn "sp_reset_connection" []`. `defaultSessionSetup`
  is empty, and the setup runs as one batch at connect and after a reset.
* Every transaction begins with a Transaction Manager request
  (TM_BEGIN_XACT) on every connection, and commit and rollback are T-SQL
  batches. `withTransactionLevel` sets READ COMMITTED back, and the commit
  checks the transaction descriptor's identity.
* MARS is transparent: no channel type, one mutex, each request takes an
  SMP session. `withQueryS` scopes a stream, and `TransactionRequestsActive`
  checks what the caller has read, not what has arrived. The library never
  cancels a stream to make a commit succeed.
* `Query` is a composable value built with plain functions (`mkQuery`,
  `param`, `namedParam`, `rawSql`, `escapeIdentifier` and `<>`). There is
  no quasiquoter, no Template Haskell, and no dependency on `ghc` or
  `ghc-lib-parser`; the `Request` layer stays public so low-level access
  stays natural.
* Entra ID login takes an access token the caller obtained. hmssql has no
  JWT, MSAL or HTTP dependency.
* Untyped NULL parameters are `nvarchar(max)`; a `sql_variant` NULL needs a
  typed NULL.
* Prefer a documented constraint on the application developer over
  defensive machinery, and keep the test suite comprehensive: a test of
  usage that became invalid states the consequence instead.
* What hmssql won't do is in `docs/dev/limitations.md`; what is planned is
  in `docs/dev/backlog.md`.

## English voice

Two registers, by audience:

| Where | Register |
|---|---|
| `README.md`, `docs/guide/`, Haddock under `hmssql/src/`, the READMEs of `examples/`, `hmssql/ChangeLog.md` | The user voice |
| `docs/dev/`, code comments, test descriptions, commit messages | The developer voice |

### Everywhere

* Keep conjunctions and connectives. Clipped pairs are ambiguous, and
  they are the tell of machine-written prose. Not "One thread, one lock"
  but "One thread with one lock". Not "No shoes, no shirt, no service" but
  "Shoes and a shirt are required".
* A colon is not a connective. It may introduce exactly what the
  sentence just promised ("two packages: ms-tds and mssql-simple"), but
  not a set of examples or a loose series. Examples get "such as" or
  "for example", in prose or before a bulleted list ("such as:").
* A list of three or more things gets an "and" or an "or" before the last
  item, in prose and in bullet items alike. Pick the one that is meant:
  examples and alternatives, where any one would do, take "or".
* Don't put a list inside a list. A sentence that is already a list can't
  also carry a parenthetical list in one of its items, and a bullet item
  shouldn't hold a comma-separated list of five things. Rearrange: split
  the sentence, or promote the inner list to its own bullets. This is hard
  to read:

  > SQL Server refuses the batch on a MARS connection (error 3997), the TM
  > request behaves identically on a plain one (the ENVCHANGE,
  > `@@TRANCOUNT`, nesting, the doomed state, a reset riding on it), and
  > one code path is better than two.

  This says the same thing:

  > SQL Server refuses the batch form on a MARS connection, with error
  > 3997. The Transaction Manager request works on both kinds of
  > connection, and on a plain one it behaves exactly as the batch does:
  > the same ENVCHANGE, the same `@@TRANCOUNT` and nesting, the same
  > doomed state, and a reset can ride on it the same way. One code path
  > is better than two.

* Keep the key jargon and the precise words: MARS, Attention, snapshot,
  deadlock, `sp_executesql`. They anchor the reader. Don't trade them for
  baby words, and that includes verbs: a library implements a protocol,
  it doesn't "speak" it.
* The first person in the README is Joey's. Don't write Haskell
  evangelism.

### The user voice (README, the guide, Haddock, example READMEs)

Regular technical documentation English.

* Plain and direct, with the same jargon kept. Sentences can run longer,
  and a paragraph holds one idea in three or four sentences.
* Haddock stays short. Say what the function does, what it returns, what
  it throws, and the one or two rules that come with it. Rationale and
  measurements go to `docs/dev/design.md`, and longer explanations go to
  the guide.
* Haddock stands on its own for someone reading Hackage. A topic that needs
  an explanation or an example gets one in a module, usually as a section's
  prose, and a pointer goes to that module and section
  (`"Hmssql.Decoding#g:streaming"`), not to a path under `docs/` or to GitHub.
* The guide's pages are short and start with what the reader needs.
  They were once written in a clipped "book voice", and were reworded
  into the user voice on 2026-11-08; new text keeps that register.
* Landing pages (the README and the `Hmssql` module header) leave out
  advanced topics: concurrency beyond "one thread per connection, use a
  pool", cancellation internals, data-type edge cases, and
  `Hmssql.Catalog`.

### The developer voice (`docs/dev/`, comments, commits)

Dense and complete is fine: full sentences, measurements with their
conditions, and the rejected alternative beside the decision. The
"everywhere" rules still apply.

## Working with subagents

* Model split: Fable only for substantial architecture rework of the
  library; Opus for well-specified library changes and complex test fixes;
  Sonnet for grunt work such as updating many tests alike.
* Give a subagent the index entries for its area (the `design.md` and
  `protocol-notes.md` sections, the test area) in its prompt, and ask it
  to report what it learned that the documents don't say, so the
  orchestrating session can fold it in.
* Subagents in worktrees can't see uncommitted work in this tree. When
  several agents edit test modules in the shared tree, none of them may run
  `stack build` or `stack test`: a failed test-suite build unregisters the
  library and breaks everyone's checks. Give them a type-check command
  instead (`stack exec -- ghc -fno-code -ihmssql-tests <default-extensions>
  File.hs`), and kill any stale `ghc -fno-code` afterwards.
* Never `pkill` by name while subagents run test binaries.

## Git

* Commit or push only when asked. Never delete branches. `main` is an
  orphan branch; the development history lives on local branches only.
* Commit messages carry the attribution lines the session asks for.
