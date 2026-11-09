# History of hmssql

hmssql was written in 2026. Its protocol code, and much of what is known about
the protocol's quirks, comes from two earlier Haskell libraries and a year of
unreleased work that merged and extended them. The git history of that work is
not carried forward into this repository, so this document records who did what
and when. What was learned about the protocol is in
[protocol-notes.md](protocol-notes.md); how hmssql itself was developed is in
[development.md](development.md).

```
ms-tds        (Takamasa Mitsuji, 2018–2024) ──┐
                                              ├─> mssql (Joey Adams, 2025, unreleased) ──┐
mssql-simple  (Takamasa Mitsuji, 2018–2024) ──┘                                          ├─> hmssql (2026)
                                              hpgsql (Marcelo Zabani, 2026: design) ─────┘
```

* **[ms-tds](https://github.com/mitsuji/ms-tds)**
  ([Hackage](https://hackage.haskell.org/package/ms-tds)): the TDS protocol,
  i.e. data types, PRELOGIN/LOGIN7, the token stream, and TLS inside TDS
  packets. Protocol types were `Binary` instances.
* **[mssql-simple](https://github.com/mitsuji/mssql-simple)**
  ([Hackage](https://hackage.haskell.org/package/mssql-simple)): a client API
  on top of ms-tds, with `sql` and `rpc` queries, `Row` and `ResultSet`
  classes with Template Haskell tuple instances up to arity 30, stored
  procedure calls with output parameters, and `withTransaction`. Usage
  examples live in
  [mssql-simple-example](https://github.com/mitsuji/mssql-simple-example).
* **mssql** (never released): ms-tds and mssql-simple merged into one package
  (version 0.5.0), so that the protocol layer and the client API could be
  developed and tested together, plus TDS 7.2, PLP, strict encryption,
  ENVCHANGE and transaction tracking, `sql_variant`, and `SqlValue`/`SqlRow`
  dynamic rows.
* **hmssql**: a new library, written by Claude (Fable 5.1) and then tested
  and reworked by further AI sessions. Its design is modeled on
  [hpgsql](https://github.com/mzabani/hpgsql) and its serialization logic
  comes from mssql. It targets TDS 7.4 and 8.0 only.

## Contributors

### Takamasa Mitsuji

Author of ms-tds and mssql-simple, 2018-08-31 to 2024-05-19 (about 56 commits
to ms-tds and 66 to mssql-simple). He wrote the whole TDS layer, the whole
client API, and their Haddock documentation, and maintained both through GHC
and template-haskell upgrades. BSD-3-Clause,
"Copyright Takamasa Mitsuji (c) 2019".

### Joey Adams

* Upstream: updated both packages to Stackage lts-22.22 and the crypton
  packages in May 2024 ([ms-tds 01092c0](https://github.com/mitsuji/ms-tds/commit/01092c0),
  [mssql-simple 756d7e0](https://github.com/mitsuji/mssql-simple/commit/756d7e0)),
  released as ms-tds 0.4.0.3 and mssql-simple 0.6.0.5.
* 2025: forks of both packages, then the mssql merge and everything in it
  (see the [timeline](#timeline)).
* 2026: directed the creation, testing, review and release of hmssql.

### Other upstream contributors (mssql-simple)

* **German Zhyvotnikov**: "Fix for the problem with improper null passing to
  stored procedures" (2021-06-06, PR #4,
  [5c7d1fc](https://github.com/mitsuji/mssql-simple/commit/5c7d1fc)). NULL
  string/binary parameters had declared a max length of 0xFFFF, which TDS 7.1
  rejects. Released in mssql-simple 0.6.0.2, together with Mitsuji's follow-up
  that made every NULL length 0.
* **Joranvar**: "Add empty `[Type]` list to `ConP` constructor" (2023-03-30,
  PR #6, [607ac0d](https://github.com/mitsuji/mssql-simple/commit/607ac0d)),
  for template-haskell 2.18 and later. Released in mssql-simple 0.6.0.4.

No outside pull requests appear in the ms-tds history.

### hpgsql (Marcelo Zabani)

hmssql borrows hpgsql's architecture:

* an Applicative `RowDecoder` over `Either`-returning `FieldDecoder`s, which
  checks column count and types before the first row;
* a single generic `Maybe` instance and `Generic` row deriving;
* a monadic row decoder for shapes known only at runtime;
* STM connection state and `streaming` results;
* the interruption-safety model (hpgsql's `INTERRUPTION-SAFETY.md`);
* an encoding context passed to every serializer, which became `TdsContext`.

The reentrant mutex in `Hmssql.Connection.Locking` is adapted from
`Hpgsql.Locking` (BSD-3-Clause, Copyright Marcelo Zabani (c) 2026).

### AI assistance

* **December 2025, in mssql.** Claude-assisted commits, each marked with a
  `claude:` prefix and curated by hand: closing the connection instead of
  looping forever on EOF; ALL_HEADERS on SQLBatch and RPC; reading PLP;
  setting TEXTSIZE and other session options after login; PLP encoding of
  large parameters, used only when needed. Two attempts were reverted (see
  the experiments in [protocol-notes.md](protocol-notes.md)).
* **September 2026, hmssql.** Claude Fable 5.1 wrote hmssql and its first
  tests in two sessions; Claude Opus 5.5 lifted it to the repository root
  and audited it against mssql; Claude Opus 5.5 and Sonnet 5, orchestrated
  by Opus 5.5, fixed the audit's bugs and tested it exhaustively; GPT 6
  Astra reviewed the result adversarially; Claude Fable 5.1 and Opus 5.5
  simplified it after the review; Fable 5.1 and Opus 5.5 then added the
  query type, the examples, bulk copy and batch queries and optimised the
  library, GPT 6 Astra reviewed that too, and Claude Fable 5.1
  consolidated the documentation. At the end of the month Claude Opus 5.5
  and Fable 5.1 researched and implemented MARS.
* **October and November 2026, hmssql.** Claude Opus 5.5, Fable 5.1 and
  Sonnet 5.5, in Claude Code, hardened MARS, built the test matrix across
  GHC versions and SQL Server 2017 to 2025, wrote the Windows transports,
  and added a round of connection and interruption tests. OpenAI's Codex
  ran a data-integrity hardening round, wrote the first version of the
  value-streaming rewrite and implemented the reviews of it. Claude then
  cleaned up the API, optimised the rewrite for code size and speed, and
  prepared hmssql for GHC's native I/O manager on Windows, including fixes
  to that manager on a GHC branch. Details in
  [development.md](development.md).

## Upstream releases

ms-tds on Hackage:

| Version | Date | Highlights |
|---|---|---|
| 0.1.0.0 | 2019-05-19 | First release |
| 0.1.0.1 | 2019-05-25 | SQL Server 2014, TABNAME, type validation, default collation |
| 0.1.0.2 | 2019-06-09 | Lazy `RawBytes`, error handling, documentation |
| 0.1.0.3 | 2019-06-22 | GHC 7.x support, Template Haskell for `Fixed`/`Decimal` |
| 0.1.0.4 | 2019-06-30 | `putMessage` improvements |
| 0.2.0.0 | 2019-07-07 | LOGIN7 visibility |
| 0.3.0.0 | 2019-07-15 | Packet size, PRELOGIN/LOGIN7 defaults, `Data String` |
| 0.3.0.1 | 2019-08-25 | Fixes for putting decimal/numeric and `UTCTime` |
| 0.4.0.0 | 2019-08-25 | `Decimal` replaced by `Fixed{n}` |
| 0.4.0.1 | 2019-12-20 | UUID byte-order fix |
| 0.4.0.2 | 2022-01-13 | template-haskell 2.17, newer GHCs |
| 0.4.0.3 | 2024-05-19 | lts-22.22 and crypton (Joey Adams) |

mssql-simple on Hackage:

| Version | Date | Highlights |
|---|---|---|
| 0.1.0.x | 2019-05/06 | First releases; SQL Server 2014; GHC 7.x |
| 0.2.0.0 | 2019-07-07 | `defaultConnectInfo`, encryption mode, `RpcParam` helpers |
| 0.3.0.0 | 2019-07-15 | `withTransaction`, packet size, row counts |
| 0.4.0.0 | 2019-08-06 | Applicative/MonadPlus parser, `ResultSet`/`RpcResultSet` |
| 0.4.0.2 | 2019-08-11 | Template Haskell tuple instances |
| 0.5.0.0 | 2019-08-25 | Connection and token-stream parser rework, parameter helpers |
| 0.5.0.1 | 2019-08-31 | Haddock usage documentation |
| 0.6.0.0 | 2019-09-16 | Improved token-stream parsing and documentation |
| 0.6.0.1 | 2020-06-21 | template-haskell 2.16 |
| 0.6.0.2 | 2021-07-31 | NULL parameter fix (German Zhyvotnikov), TYPE_INFO data length fix |
| 0.6.0.3 | 2022-01-13 | template-haskell 2.17 |
| 0.6.0.4 | 2023-04-02 | template-haskell 2.19 (Joranvar), GHC 9.2/9.4 |
| 0.6.0.5 | 2024-05-19 | lts-22.22 (Joey Adams) |

Never released: ms-tds 0.4.1 and mssql 0.5.0 (both 2025). hmssql 0.1.0 is
the first release of this line since then.

Mitsuji's projects supported TDS 7.1 Revision 1 (SQL Server 2000 SP1 and later)
and were tested against SQL Server 2008 R2 and 2014. The 2025 work was tested
against Azure SQL and SQL Server 2025 for Linux. hmssql's live tests run
against SQL Server 2017, 2019, 2022 and 2025 on Linux, SQL Server 2019 and
2025 on Windows, and Azure SQL Database ([testing.md](testing.md)).

## Timeline

### 2018–2019: original development

Mitsuji released the first versions of ms-tds and mssql-simple in May 2019 and
had most of their features in place by September 2019: packet size support,
transactions, row counts, the Applicative/MonadPlus token parser, Template
Haskell tuple instances, RPC parameter helpers, and documentation.

### 2020–2024: maintenance

Compatibility updates for newer GHC and template-haskell versions, the two
community pull requests above, and Joey Adams's crypton/lts-22.22 update. Both
packages had their last upstream release on 2024-05-19.

### March–November 2025: Joey Adams's forks

* Decoding `datetime2` sent as text into `UTCTime`. Below TDS 7.3 the server
  sends `date`/`time`/`datetime2`/`datetimeoffset` as nvarchar strings.
* `Data` instances for `Day`, `TimeOfDay`, `ZonedTime`, `Decimal`, `Int64`,
  `Word8`, and `Maybe` variants.
* `SqlValue`, a sum type of every SQL Server value, so an application can
  decode arbitrary results without knowing the column types at compile time.
* In mssql-simple: building a row parser at runtime (`sqlWith`,
  `parseListOfRowsWith`), `SqlRow`, and exporting `mcdTypeInfo`.
* A first TDS 8.0 prototype (May 2025) that runs TLS directly on the socket.
  It worked against Azure SQL.

### December 2025: the mssql merge

On 2025-12-05 mssql-simple's sources were copied into ms-tds, forming the
`mssql` package (version 0.5.0). This was a file copy, not a git merge, so
mssql-simple's history was never part of that repository. Over the next two
weeks:

* TDS 7.2: the new field widths, version `0x72090002`, and the RPC batch
  separator.
* ALL_HEADERS on SQLBatch and RPC requests.
* Reading PLP (`varchar(max)`, `nvarchar(max)`, `varbinary(max)`), then PLP
  encoding for large parameters.
* Standard session options sent as one batch after login, plus the LOGIN7
  `fODBC` flag.
* Strict encryption (TLS from byte zero), selectable alongside the classic
  PRELOGIN mode. Also TLS 1.3, and certificate validation turned on.
* ENVCHANGE parsing and transaction descriptor tracking, so explicit
  transactions work.
* Sending each TDS packet to TLS separately, which fixed large messages over
  TLS.
* Newtypes for LOGIN7/RPC option flags, `sql_variant`, and a first
  `TdsContext`.
* Bundling the local server's certificate, because the macOS system store
  did not seem to pick it up.

Tests from this period sent a 134-million-character SQL batch, read the same
string back as an `nvarchar(max)` (268 MB of UTF-16), and sent
million-character RPC parameters, two RPCs in one message, and non-BMP text.

### September 2026: hmssql 0.1.0 and MARS

* 2026-09-05: hpgsql added as a git submodule for reference (removed the next
  day), and the MS-TDS PDF added for the AI to consult (since removed; see
  the [online spec](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/b46a581a-39de-4745-b076-ec4dbb7d13ec)).
* 2026-09-06: first session. Claude Fable 5.1 created `hmssql` and
  `hmssql-tests` (73 tests).
* 2026-09-06: second session. It added `SqlParam`, `NamedParams`, the
  `ResultSets` monad, and `refineField` (89 tests).
* 2026-09-23: the mssql package was removed and hmssql became the only package
  in the repository; the comparison audit listed seven bugs.
* 2026-09-24/25: the audit's bugs fixed, `reset` added, and a day of
  AI-driven testing that grew the suite to 2435 examples and found some
  eighty more bugs ([bugs-found.md](bugs-found.md)).
* 2026-09-25: an adversarial review of the day's library changes, and the
  simplification that followed it ([design.md](design.md)).
* 2026-09-25 to 09-29: the suite run against Azure SQL Database, the
  `Query` type, the examples, a round of optimisation with a second
  adversarial review, bulk copy, batch queries and connection pooling
  support; the documentation consolidated, and the history squashed into
  one commit, as hmssql 0.1.0 (unreleased).
* 2026-09-29 and 09-30: MARS, researched with two spikes and seven
  probes, implemented and reviewed
  ([mars-research.md](mars-research.md)). The documentation split into
  the user guide and the developer documents.

### October and November 2026: hardening, Windows, and the rewrite

The sessions are in [development.md](development.md); in outline:

* 2026-10-01 to 10-16: the MARS flakes, Azure SQL Database again, the test
  matrix (GHC 9.6 to 9.14 against SQL Server 2017, 2019, 2022 and 2025,
  with nothing but Docker), the Windows transports (Shared Memory, Named
  Pipes, and TCP), and the first runs on macOS and against SQL Server 2019
  on Windows.
* 2026-10-13 to 10-25: the findings reported against hmssql's connection
  and interruption handling, triaged, with tests added for each.
* 2026-10-27 and 10-28: a data-integrity hardening round, and its review.
* 2026-10-29 to 11-05: the API cleanup before the first release, the
  value-streaming rewrite of the decoder and encoder pipeline, and two
  optimization runs for code size and speed.
* 2026-11-06 and 11-07: Windows without `-threaded`, and the transports
  through GHC's native I/O manager.

## The original READMEs

Both projects had English and Japanese READMEs with the same content. They
advertised no ODBC dependency; pure Haskell with no libraries from other
languages or environments; encryption during login; protocol types
implemented with the `binary` package; a design meant for both client and
server implementations; multiple result sets, stored procedures via RPC, and
transactions (mssql-simple); TDS 7.1 Revision 1.

Their TODO lists, and where hmssql stands on each:

| TODO | hmssql |
|---|---|
| Tests, including legacy data types | Round-trip properties and live tests, including `text`/`ntext`/`image` |
| Encrypt the entire connection | Done: `EncryptOn`, `EncryptStrict` |
| TDS versions other than 7.1 | Done: 7.4 and 8.0 |
| Attention | Done: used for cancellation and interruption |
| Detailed types for collation, GUID, flags, LOGIN7 fields | Mostly done |
| AltMetaData/AltRow (`COMPUTE BY`) | Not supported; `COMPUTE BY` was removed from SQL Server 2012 |
| `Binary` put/get for server-side messages | Out of scope; hmssql is a client and has no `Binary` instances |
| MARS, SSPI, FedAuth, Bulk Load, distributed transactions | MARS: done, opt-in (`connectMars`). FedAuth: access tokens only. Bulk Load: done. SSPI and distributed transactions: not supported |

## Sources

This document was compiled from the git history of
[mitsuji/ms-tds](https://github.com/mitsuji/ms-tds),
[mitsuji/mssql-simple](https://github.com/mitsuji/mssql-simple), their forks,
the unreleased mssql repository (all branches), both projects' READMEs
(English and Japanese), code comments in the deleted mssql sources, and the
records of the AI sessions that produced hmssql.
