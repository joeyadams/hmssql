# The test suite against Azure SQL Database

How hmssql and its test suite meet Azure SQL Database: what Azure does
differently, which tests skip or adapt there and why, how to run there, and
a record of the runs from 2026-09-25 to 2026-10-29 with what each
established. The server facts, with their conditions, are in
[protocol-notes.md](protocol-notes.md#azure-sql-database); how to set up
and run the scripts is in [testing.md](testing.md#azure-sql); the bugs the
runs found are in [bugs-found.md](bugs-found.md).

Every run was in East US, against a database of the tier the record names
(Basic, Standard S3, or the General Purpose serverless `GP_S_Gen5_1`), with
a companion database at Basic. Clients ran in Azure Container Instances in
the same region unless the record says otherwise.

## What Azure does differently

Each line is a fact of [protocol-notes.md](protocol-notes.md#azure-sql-database),
with what it means for hmssql and its tests.

| Azure SQL Database | What follows |
|---|---|
| The gateway routes a login by the LOGIN7 server name (40531 without it) | `connect` copies `connectHost` into LOGIN7 when `connectServerName` is empty, and replaces it with the node's `host,port` after a redirect. An IP address as `connectHost` needs an explicit `connectServerName` |
| Under the Default policy, logins from inside Azure are redirected to the node; from outside they are proxied | Every connection of a run from a container follows a redirect |
| Encryption is required: a PRELOGIN offering ENCRYPT_NOT_SUP is refused, and ENCRYPT_OFF gets everything encrypted | The plaintext variants of tests skip |
| Packets are capped at 16192 bytes, and a LOGIN7 packet over 4096 bytes is reset | hmssql adopts the granted size, and frames PRELOGIN and LOGIN7 at 4096 |
| No `USE` and no three-part names into another database | Tests of either skip; the model's generator leaves `Use` out |
| The server admin is not `sysadmin`: no `RAISERROR ... WITH LOG`, no extended procedures, no `CREATE LOGIN ... CHECK_POLICY = OFF`, no `SUSER_SNAME()` under `EXECUTE AS` | Tests of severity 20 and `xp_msver` skip; the others adapt |
| No `ALTER DATABASE ... SET OFFLINE` or `SINGLE_USER`; a plain `DROP DATABASE` drops a database with connections | Those tests skip, and the harness drops with a plain `DROP DATABASE` |
| In the logical `master`, `DB_ID` of another database is NULL | The harness asks `sys.databases` |
| A bare `CREATE DATABASE` makes a General Purpose 2-vCore database and takes 25 to 60 s | The suite creates its databases at Basic, and few of them |
| `CREATE DATABASE` refuses a name with a character outside the BMP (1055) | The test of that name expects the refusal |
| CONTEXT_INFO holds a tracing GUID at login, and a reset leaves it NULL | The reset tests compare CONTEXT_INFO only as "not the value the test set" |
| RESETCONNECTION puts the isolation level back to READ COMMITTED | The tests expect the level reset; documented in [limitations.md](limitations.md#behaviours-to-know-about) |
| `READ_COMMITTED_SNAPSHOT` is on, and `ALLOW_SNAPSHOT_ISOLATION` always on | Lock tests read `WITH (READCOMMITTEDLOCK)`; the test of a refused SNAPSHOT skips |
| A killed session's request gets a DONE flagged DONE_ERROR and DONE_SRVERROR with no ERROR token, then a TCP reset | hmssql throws `SevereError`; the tests accept a reset as the end of a killed session |
| An Attention right behind its request is acted on only once the statement has sent its result | Cancellation tests that do it in a loop allow minutes there |
| Loaded, a request read together with its Attention can end the whole MARS connection | The two tests that meet it accept it; documented in [limitations.md](limitations.md#mars) |
| A cancelled reset-carrying request ends without the acknowledgement in 1 to 3 of 100 | hmssql asks for the reset again |
| Every open response counts against the request limit (30 on Basic) | The suite runs on Basic only with `--jobs 4` |
| The log-rate governor holds log-heavy statements for seconds on S3 under the suite | Tests write few rows where only the timing matters |
| Catalog reads lose deadlocks to concurrent DDL | The catalog tests and the scratch-schema helpers retry on 1205 |
| Error 40613 at login is transient | Neither hmssql nor the suite retries a refused login ([limitations.md](limitations.md)) |

## How the suite adapts

### Telling Azure apart

The suite tells Azure apart by `SERVERPROPERTY('EngineEdition') = 5`
(`testServerIsAzure` in `hmssql-tests/TestConfig.hs`, asked once per process), and
`skipOnAzure` in `hmssql-tests/TestDb.hs` marks a test pending there. A test whose
expectation differs on Azure asks `testServerIsAzure` itself. Two more
facts serve the tests that assume a local server rather than Azure as
such, and they hold for any server like it:

* `testServerRequiresEncryption` offers `EncryptNotSup` once and takes the
  refusal (`ProtocolError`, "the server requires encryption") as the
  answer, and `skipIfEncryptionRequired` marks the plaintext variants
  pending. A SQL Server with Force Encryption behaves the same.
* `testHostIsLoopback` and `skipUnlessLoopbackHost` keep the tests of the
  loopback spellings to a local server.

The model (`hmssql-tests/Model/Machine.hs`) carries `cfgAzure`, which takes `Use`
and `Fatal` out of its generator and makes a reset put the isolation
level back.

### Tests that skip there

About 28 more tests are pending on Azure than locally, each because what
it tests does not exist there:

| Tests | Why |
|---|---|
| The `EncryptNotSup` variants: `Connection.Disconnect` ×8, `Protocol.Encryption` "EncryptNotSup logs in without encryption", `Resources.ClosedConnection`, `Resources.ClosedMidResponse` and `Scale.TlsSmallPacketMemory` | The server requires encryption |
| `Shapes.EnvChange` "database (USE)" ×2, `Rpc.ProcNames` three-part name, `Session.ServerFeatures` cross-database query, and `Reset` "reverts the database after USE" ×2 | No `USE` and no three-part names |
| `Connection.Lifecycle` "connects to host" `localhost`, `127.0.0.1` and `::1` | They test the loopback spellings |
| `DocExamples` "README.md: Encryption (connectTls)" | It runs the README's literal example, which names `localhost` |
| `Connection.Lifecycle` "a severity-20+ error kills the connection", `Shapes.Errors` "severity 20+" | `RAISERROR ... WITH LOG` needs `sysadmin` (2778) |
| `Connection.Credentials`'s MUST_CHANGE test | It needs `CHECK_EXPIRATION` |
| `Connection.Database` "taken offline" and "single-user already in use" | Refused with 1468 |
| `Rpc.ProcNames` "calls an extended procedure (xp_msver)" | No extended procedures |
| `Transaction.withTransactionLevel` "when SNAPSHOT isn't allowed" | `ALLOW_SNAPSHOT_ISOLATION` is always on |
| `Connection.Disconnect` "server kills the session, while rows are streaming", when no reset arrives within 15 s | The hang seen from one macOS system ([backlog.md](backlog.md#checks-to-revisit)) |

### Tests that adapt there

| Tests | On Azure |
|---|---|
| `Reset`, the tests whose setup ends with `USE tempdb` | The setup leaves `USE` out; the options, transactions, temp tables, cursors and context they check matter there as anywhere |
| `Reset` (five), `Mutation.Transaction` ×2 and the model | `keptLevel` in `hmssql-tests/ResetSpec.hs` is the level a RESETCONNECTION leaves, kept on SQL Server and READ COMMITTED on Azure |
| `Reset` (eleven) | `getProps` reads CONTEXT_INFO as "the value a test set, or nothing" |
| `Protocol.Encryption` "EncryptOff encrypts only the login" | On a server that requires encryption, it expects `encrypt_option = TRUE` |
| `Connection.Lifecycle` "rejects a certificate whose name doesn't match", `Security.Tls` "checks the certificate against connectHost by default" ×3 | They connect to the name the certificate is for (`HMSSQL_TEST_TLS_HOSTNAME`, or the host itself), with a wrong `tlsHostNameInCertificate` where the test needs one |
| `Connection.Credentials` | Logins are created without `CHECK_POLICY = OFF`, with passwords that satisfy Azure's policy; the password-bytes tests (quotes, unicode, 128 characters) run against Azure's login path |
| `Connection.Credentials` "login without access to the requested database" | It requests the test database by name, and expects 916 as a `LoginError` |
| `Rpc.ProcResults` "EXECUTE AS / REVERT" | It impersonates a user without login that it creates, and checks `USER_NAME()` before and after `REVERT`, on both servers |
| `Connection.Database` "128-character database name" | It skips the file-path part, since `InstanceDefaultDataPath` is NULL |
| `Connection.Database` "a non-BMP database name" | It expects error 1055 on Azure and the round trip on SQL Server |
| `Differential.Shape` "the requested TDS versions and packet sizes" | It expects a size no larger than requested |
| `Mutation.HostedTls` "when the server kills the session" | It accepts a reset as well as an orderly close |
| `Connection.Disconnect` (the three killed-request tests) | A `SevereError` followed by the reset is the severe failure they expect |
| The MARS lock tests (`Mars.*`, `MarsTx.*`) | They read `WITH (READCOMMITTEDLOCK)`, which behaves as READ COMMITTED without RCSI |
| `Mars.Cancel`'s checks | They write one row, where a 30,000-row write waited up to 42 s in `LOG_RATE_GOVERNOR` |
| `Mars.Random` and `MarsTx.Hygiene` | `Mars.Harness.cancelling` accepts the end of the connection at an early Attention, prints a note and checks the connection is broken |
| `Mars.WithQueryS` "interrupted just after its request was sent ... (100 times)" | It allows 600 s there, against 120 |
| Every test `KILL` | It checks the session's physical connection first, so that it can't land on the killer's own session (6104) |
| `Catalog` and the scratch-schema helpers | They retry a read or a drop that loses a deadlock |
| The DDL lock (`withDdlLock`) | It waits 15 minutes, behind `CREATE DATABASE`s of 25 to 60 s |

`Protocol.Login` "LOGINACK from the live server", which builds its own
LOGIN7, takes the server name from the test configuration and follows the
gateway's redirect, as `connect` does.

### Scratch databases

A whole run creates 8 databases against a local server, and 5 on Azure,
at 25 to 60 s each behind the DDL lock; it was 28 and 18 before
2026-10-01. The rest use one of two things the suite keeps:

* **The companion database**, a second database that the pre-test hook
  creates if it is missing, under the DDL lock, and keeps like
  `hmssql_test` itself (`HMSSQL_TEST_COMPANION_DATABASE`, by default the
  test database's name with `_companion` after it). Concurrent runs share
  it, so what a test creates there has a unique name. It serves the tests
  that need a second database (`Shapes.EnvChange`, `Rpc.ProcNames`,
  `Session.ServerFeatures` and the model's `Use`), and those that need
  `ALLOW_SNAPSHOT_ISOLATION` (`Transaction`, `Transaction.TmBegin` and
  `MarsTx.Snapshot`), which the hook turns on when it finds it off, since
  an `ALTER DATABASE` can't run in a transaction. `Transaction` and
  `MarsTx.Snapshot` keep their tables in a schema of the run's own there.
  The shared test database keeps snapshot isolation off, which
  `Transaction` "when SNAPSHOT isn't allowed" needs. The suite creates the
  companion, rather than `azure-sql-test.sh setup`, so that local and
  Azure runs take one code path and it gets the same
  `HMSSQL_TEST_CREATE_DATABASE_OPTIONS` (Basic, 100 MB) as every other
  database the suite creates.
* **A scratch schema** in the shared database (`withScratchSchema`),
  dropped afterwards with everything in it, for the tests that only
  wanted their objects apart: `Catalog`, temporal tables and typed XML.
  `Catalog`'s "lists every schema" reads the shared database and checks
  the order of the test's two schemas within it, and that other schemas'
  tables are listed too.

What still creates a database: `Types.CodePage` "uses the database's
default collation", which alters the database's collation and needs the
database to itself (error 5030 otherwise); `Harness`, which tests
`withScratchDatabase`; and `Connection.Database`, whose odd names (spaces,
closing brackets, unicode and 128 characters) and states are what each
test is about. On Azure, the offline and single-user tests are pending
and the non-BMP name is refused.

Every database name the suite gives starts with `hmssql` and ends with
`uniqueName`'s `_<run>_<time>_<n>` suffix, which is how
`scripts/azure-sql-test.sh prune` recognizes what a failed run left
behind; it never drops the test database or the companion. The existence
check asks `sys.databases` (`databaseExists`), and `dropDatabase` fails
the test if a drop returns without dropping, since a drop guarded by
`DB_ID` once did nothing on Azure without an error
([bugs-found.md](bugs-found.md#in-the-test-suite)).

## Running there

The scripts, their commands and their configuration are in
[testing.md](testing.md#azure-sql) and in each script's header:
`scripts/azure-sql-test.sh` for the suite (in a container, or natively with
`run-local`), `scripts/azure-bench.sh` for `hmssql-bench-azure`,
`scripts/azure-managed-identity.sh` for the Entra ID example, and
`scripts/azure-bulk-copy.sh` for the bulk-copy example. What the runs
below taught about sizing:

* **S3 and 16 jobs.** A whole run takes 8 to 13 minutes on S3 from an
  8-vCPU, 16 GB container (`AZ_CONTAINER_CPU=8 AZ_CONTAINER_MEMORY=16`)
  with hspec's default of 16 items at once. On a 1-vCPU container the
  mock-server timing tests are sensitive to 16 jobs, and `--jobs 4`
  passes.
* **Basic needs `--jobs 4`.** With 16 jobs the suite passes Basic's
  request limit of 30 and fails with 10928; with 4 it takes over an hour,
  the database's CPU at the tier's limit throughout, and the MARS tests
  that cancel a request the moment it is sent can run out of their time.
* **Over MARS.** The script passes every `HMSSQL_TEST_*` variable set in
  its environment to the container, so after `upload` has put a suite
  built from the current tree on the share, the whole suite over MARS
  connections is:

  ```sh
  HMSSQL_TEST_MARS=1 AZ_CONTAINER_CPU=8 AZ_CONTAINER_MEMORY=16 scripts/azure-sql-test.sh run
  ```

* **From Windows.** `HMSSQL_TEST_TLS_HOSTNAME` has to be set to the
  server's host name explicitly: GHC on Windows reads an empty
  environment variable as unset, and the harness's default of
  `localhost` then rejects Azure's certificate. `azure-sql-test.sh env`
  sets it.
* A transient DNS failure resolving the redirected node's name in the
  container failed one test in each of two runs (2026-10-01 and
  2026-10-05).

## Entra ID and managed identity

On 2026-09-29, once `connectAccessToken` existed, a container in ACI with a
user-assigned managed identity logged in to the test database with a token
from its identity endpoint, with no password anywhere
(`scripts/azure-managed-identity.sh`, the program
`examples/managed-identity`). What it took, in order:

1. **An Entra admin on the server**, set with `az sql server ad-admin
   create`. Only an Entra identity can create users `FROM EXTERNAL
   PROVIDER`; the SQL admin can't. The admin is matched by object id: the
   first attempt registered the object id that `az ad signed-in-user show`
   reported, a guest object in the tenant, while `az account
   get-access-token` issues tokens for the tenant's own user with another
   object id, and every login failed with 18456, "Login failed for user
   '<token-identified principal>'". That message means the token was
   parsed and validated and its identity has no login there.
2. **The identity's user in the database**, created as the admin over
   hmssql with a CLI token (`create-user` runs the example's `exec`):
   `CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER` worked at once,
   with no Directory Readers role for the server and no `WITH OBJECT_ID`,
   the admin being a user rather than a service principal. Then `ALTER
   ROLE db_datareader ADD MEMBER`.
3. **The container**, ACI with `--assign-identity` and the same share as
   the suite's. The identity endpoint there is the Instance Metadata
   Service, `api-version=2018-02-01`, with `client_id` naming the
   user-assigned identity; it answered in well under a second with a
   token good for 24 hours. The login went through strict encryption and
   the inner PRELOGIN the token needs.

The session showed the login as `<client-id>@<tenant-id>` and the user as
the identity's name with authentication EXTERNAL; protocol-notes.md has
what each catalog view shows. The token found two bugs in hmssql, both
fixed: LOGIN7 was framed at the requested packet size, which Azure's
gateway resets once a token makes it longer than 4096 bytes, and strict
encryption sent no PRELOGIN, which the FEDAUTH feature needs to echo
FEDAUTHREQUIRED from. `Connection.AccessToken` then passed with a CLI
token under both `EncryptStrict` and `EncryptOn`, and saw a corrupted
token refused with 18456.

Building the example for the container is
[testing.md](testing.md#linux-builds-in-docker)'s story: Docker Hub refused
ACI the `haskell` image and Docker Desktop on the Mac hung pulling from it,
so both the Dockerfile and the ACI build install GHC with ghcup on
Microsoft's mirror of Ubuntu 24.04. The Docker build of the example took
about four minutes on an Apple Silicon Mac under x86-64 emulation once the
toolchain layer existed; the ACI build on 2 cores, with nothing cached,
about 20.

## Proxy and Redirect

`scripts/azure-bench.sh compare 3` measured the two connection policies on
2026-09-29: `hmssql-bench-azure` in a fresh 1-vCPU ACI container per run,
against the test database on the **Basic** tier, three runs under Proxy
and three under Default, alternating, a minute after each policy change.
Each run timed the cold first connect and queries, then a warm-up of five,
then 30 connects and, on one connection, 500 `SELECT 1` round trips and 20
each of the transfers, for `EncryptStrict` and `EncryptOn`.

Under Default every connection (all 60 of each run) was redirected: its
socket ended at the database's node, on a port in the 11000 range, whose
certificate validates against the node's name with no settings. Under
Proxy they went to either of the two gateway addresses the server's name
resolves to, on port 1433. `@@SERVERNAME` is the logical server either
way, and `CONNECTIONPROPERTY('local_net_address')` is NULL.

Medians, `EncryptStrict`, one value per run (ms):

| | Proxy | Default (redirected) |
|---|---|---|
| connect | 52.5, 57.6, 56.7 | 33.0, 31.0, 47.1 |
| connect + first `SELECT 1` | 55.2, 62.2, 59.6 | 34.6, 32.7, 49.4 |
| `SELECT 1` round trip | 2.50, 2.30, 2.58 | 1.36, 1.55, 2.52 |
| 10,000 short rows | 32.6, 31.6, 34.1 | 31.8, 36.5, 32.1 |
| 2000 rows of 1000 characters (4 MB) | 78.2, 78.8, 81.7 | 70.9, 62.8, 65.8 |
| a 1 MB parameter | 95.2, 93.6, 95.8 | 95.5, 97.3, 94.5 |

`EncryptOn` (TDS 7.4) came out the same way: connects 46 to 60 ms against
33 to 48, round trips 2.5 to 2.9 against 1.45 to 2.54, the 1 MB parameter
100 to 109 against 94 to 96.

* **Connecting is faster redirected**, although it is two logins: a third
  to two fifths less. Presumably the gateway answers a login it redirects
  without logging in to the node itself, which it has to do for a login it
  proxies, whose every packet then crosses it too; this wasn't measured.
* **Round trips are about 40% shorter** redirected (1.4 to 1.6 ms against
  2.3 to 2.6), in two runs of three; in the third, both connects and
  round trips were as slow as Proxy's. Every run is a new container,
  placed anew, so the distance to the node varies between runs; the Proxy
  runs, which all cross the gateway, varied less.
* **Transfers** gain less: 4 MB of rows 10 to 20% faster, and 10,000 short
  rows and a 1 MB upload the same. At these sizes the Basic tier and the
  client's one vCPU set the pace, not the hop.
* **Cold starts**: the first connect of a container took 105 to 210 ms
  under either policy (the lookup, the first TLS handshake and the
  certificate bundle), and the first queries cost little more than warm
  ones; the warm-up absorbed it.
* One of the 30 `EncryptStrict` connects of the first Default run took
  5.0 s (the rest of that run's, under 70 ms). It was not seen again in
  the 150 other redirected connects, and was not investigated.

From outside Azure (a Mac about 45 ms from East US) the Redirect policy
costs instead: a connect took about 380 ms against 250 under Proxy, the
second login's round trips added to the first's, and queries were the
same, the round trip to Azure dwarfing the gateway's hop. The Default
policy proxies connections from outside Azure anyway.

## MARS

MARS on Azure SQL Database was probed before the library had it, by the
spike's probe 6 ([mars-research.md](mars-research.md#probe-6-azure-sql-database))
with the spike's own request layer: through the gateway and after a
redirect, over TDS 7.4 and 8.0, with SQL and access-token logins, it
behaved as on SQL Server 2025, with the same error numbers. What Azure
adds (the request limit, the burst limit, the read rate over a long round
trip, which is why `connectMarsWindow` defaults to 64, and the end of a
connection at an early Attention) is in
[protocol-notes.md](protocol-notes.md#azure-sql-database).

Through the library, the MARS tests (`Mars.*`, `MarsTx.*`) have passed on
Azure on MARS connections of their own since 2026-10-01, and the whole
suite over MARS connections since the same evening; every connection was
redirected to the node. What the runs taught the tests is in the tables
above. What the suite doesn't reach, the request limit and a longer round
trip, is on the [backlog](backlog.md).

## The server name in LOGIN7

On 2026-10-28 a native macOS client built with GHC 9.12.4 connected to the
`GP_S_Gen5_1` test database with `connectServerName` empty, so the library
copied the full `connectHost` host name into LOGIN7. The probe used SQL
login credentials and the system certificate store, and only read
`sys.dm_exec_connections` and `DB_NAME()`.

| Connection policy | Encryption | Server-reported protocol | Encrypted | Peer port |
|---|---|---|---|---|
| Default, from outside Azure | `EncryptOn` | `0x74000004` | TRUE | 1433 |
| Default, from outside Azure | `EncryptStrict` | `0x08000000` | TRUE | 1433 |
| Redirect | `EncryptOn` | `0x74000004` | TRUE | the node's |
| Redirect | `EncryptStrict` | `0x08000000` | TRUE | the node's |

All four reached the requested database. The database started paused,
and two transient 40613 login errors were retried while it resumed. The
policy was changed from Default to Redirect for the probe and put back
afterwards. So the full host name works at the gateway, and the redirect
path supplies the node's name. The `Connection.Lifecycle` tests of it then
passed against Azure under both encryption modes.

On 2026-10-29 `Connection.AzureServerName` (opt-in, with
`HMSSQL_TEST_AZURE_SERVER_NAME=1`) ran from the same client against the
same database, through its public host name under the Default policy,
under `EncryptOn` and `EncryptStrict` separately, with the same results
for both. `myserver` stands for the logical server's name.

| `connectHost` | `connectServerName` | Result |
|---|---|---|
| `myserver.database.windows.net` | empty | Connected |
| `myserver.database.windows.net` | `myserver` | Connected |
| `myserver.database.windows.net` | `myserver.database.windows.net` | Connected |
| `myserver.database.windows.net` | `myserver2` | `LoginError` 40532 |
| `myserver.database.windows.net` | `myserver2.database.windows.net` | `LoginError` 40532 |
| The resolved IPv4 address | empty | `LoginError` 40532, naming the IP address as the requested server |
| The resolved IPv4 address | `myserver` | Connected |
| The resolved IPv4 address | `myserver.database.windows.net` | Connected |

Every connection that succeeded reported the expected database, encryption
on, and protocol version `0x74000004` or `0x08000000`. The IP cases kept
`tlsHostNameInCertificate` set to the Azure host name and validated
against the system certificate store, and the gateway accepted the valid
LOGIN7 name with no host name in the TLS SNI. The test of IPv6 failed
before connecting: `AF_INET6` returned only an IPv4-mapped address, and
DNS had no AAAA record, so there is no native IPv6 coverage. The run had
12 examples, 11 passing and the IPv6 one failing. Only read-only queries
were issued. So copying `connectHost` is a default for the usual host
name, not a rule that any network address is a valid LOGIN7 name.

## The runs

| Date | Database | Client | Connections | Result | What it established |
|---|---|---|---|---|---|
| 2026-09-25 | S3, Proxy | ACI, 1 vCPU, 2 GB | Strict, plain | 2476 examples, 75 failures, 54 pending, 747 s | Everything the suite needs works there; the failures sorted into the differences above, and one bug (below) |
| 2026-09-26 | S3, Proxy | ACI, 8 vCPU, 16 GB | Strict, plain | 2478 examples, 2 failures, 82 pending, 449 s | The adaptations work; two more test fixes |
| 2026-09-29 | Basic | ACI, 1 vCPU | Token login | Passed | [Entra ID and managed identity](#entra-id-and-managed-identity) |
| 2026-09-29 | Basic, Proxy and Default | ACI, 1 vCPU | Strict and On | Benchmark | [Proxy and Redirect](#proxy-and-redirect) |
| 2026-10-01 | S3, Default | ACI, 8 vCPU, 16 GB | Strict, plain; the MARS tests on MARS | 3366 examples, 0 failures, 103 pending, 447 s, after runs that found five test faults | The MARS tests on Azure; RCSI, the log-rate governor and the early Attention |
| 2026-10-01 | S3, Default | ACI, 8 vCPU, 16 GB | Strict, all over MARS | 3368 examples, 0 failures, 103 pending, at the third run | The whole suite over MARS |
| 2026-10-05 | Basic, Default | ACI, 4 vCPU and 1 vCPU | Strict, plain | 60 and 7 failures, over an hour each | [The Basic tier](#the-basic-tier) |
| 2026-10-15 | S3, Default | ACI, 8 vCPU, 16 GB | Strict, plain and MARS | 3380 examples, 2 and 0 failures, 539 and 478 s | [S3 again, with the matrix's fixes](#s3-again-with-the-matrixs-fixes) |
| 2026-10-25 and 26 | S3, `GP_S_Gen5_1` and Basic | macOS, Docker Desktop, ACI | Strict, On and Off | Focused runs | The killed-session hang from one macOS system ([protocol-notes.md](protocol-notes.md#cancellation-and-killed-sessions)) |
| 2026-10-26 | S3, Default | Native Windows, outside Azure | Strict, plain | 3,585 examples, 1 failure, 106 pending, 2,286 s | [Native Windows client outside Azure](#native-windows-client-outside-azure) |
| 2026-10-28 and 29 | `GP_S_Gen5_1`, Default and Redirect | Native macOS | Strict and On | 4 probes; 12 examples, 11 passing | [The server name in LOGIN7](#the-server-name-in-login7) |

### The first two runs

The first run took 12.5 minutes against about 2 locally, almost all of
the difference `CREATE DATABASE`: 25 to 60 s each, serialised by the
suite's DDL lock, for 14 scratch databases and the odd-name databases of
`Connection.Database`. The database's load peaked at 44% of S3's DTUs, 58
concurrent workers and 66 sessions. Everything the suite needs from a
server it got: strict encryption with the publicly trusted certificate and
no TLS configuration, the fixtures under the `sp_getapplock` in `master`,
scratch databases, `KILL` from another session, temporal tables, XML
schema collections, and the 1 GiB values of the `Scale` tests.

Of its 75 failures, all but two were an Azure difference or a test that
assumed a local server, and became the skips and adaptations above. One
was a test that assumed a 40 MB send blocks, which the container host's
loopback buffers took whole (`Resources.CloseDuringSend`). The other was
hmssql's: a killed session came back as a successful, empty result,
because hmssql was lenient about a DONE flagged as failed without an
ERROR token; it now throws `SevereError`
([bugs-found.md](bugs-found.md)). The scratch databases were also never
dropped, since the drop was guarded by `DB_ID`, and the second run left
its own behind the same way; the third left none.

The second run's two failures were the 916 for a login without a user in
the requested database and `Resources.CloseDuringSend` again; both tests
were fixed, and a targeted rerun passed. It was three minutes shorter than
the first, since the model created no scratch database and four of the
tests that did were pending.

### The runs since MARS

The first run of 2026-10-01 was stopped before its end: ten MARS tests
assumed that a READ COMMITTED reader takes locks, which it doesn't under
Azure's RCSI, and two of them printed an uncaught `ConnectionClosed` from
a thread they had forked; a local database with RCSI on reproduced both.
The runs after it found the rest, all in the tests: two `Mars.Cancel`
checks held up to 42 s by the log-rate governor, `MarsTx.Reset` meeting
the missing reset acknowledgement and a catalog lock held longer than its
1.2 s `LOCK_TIMEOUT`, a test `KILL` that landed on the killer's own
session, catalog reads and a scratch-schema drop lost to deadlocks, and
two MARS tests that met the end of the connection at an early Attention
([bugs-found.md](bugs-found.md#in-the-test-suite)). The run at 18:51 UTC
passed. Over MARS connections, the first run lost a scratch-schema drop to
a deadlock and the second met a DNS failure and a `KILL` that came after
its victim's `WAITFOR` had ended; the third (21:21 UTC) passed.

### The Basic tier

Two runs on 2026-10-05 with the test database at Basic (5 DTU) instead of
S3, strict encryption, plain test connections, and without the slow tests:

| | Run 1 | Run 2 |
|---|---|---|
| Container | 4 vCPU, 8 GB | 1 vCPU, 2 GB |
| Jobs | 16, the default | `--jobs 4` |
| Result | 3374 examples, 60 failures, 103 pending | 3374 examples, 7 failures, 104 pending |
| Time | 3815 s | 4018 s |
| Error 10928 | in 14 failures | none |

The database's CPU was at 100% of what the tier allows from the second
minute to the end of run 1 (`cpu_percent`, in 5-minute averages), so the
server set the pace and the client's size didn't. Log writes reached 100%
at times in the first 25 minutes and were under 5% afterwards. Sessions
never passed 22% of the tier's 300.

* **With 16 jobs the suite passes the request limit.** `workers_percent`
  reached 100% in bursts and averaged 40 to 65%. Fourteen tests failed
  with 10928 itself, thrown as a `SqlServerError`: eight of
  `Concurrency.Interrupt`, `Concurrency.InterruptedRequest` and
  `Concurrency.Attention`, five of `Concurrency.Close`, and
  `Model.Parallel`. With 4 jobs there was none.
* **The rest of run 1 is time.** Thirty-seven tests ran into a bound of
  their own, of 10 to 180 s: 26 MARS tests that do something 500 times,
  read a window's worth of packets, or cancel a request as it is sent;
  both `Model.Connection` properties, whose watchdog found a statement
  unanswered after 15 s; five of `Connection.Disconnect`; two of
  `Concurrency.Stream`; and two reads of a 64 MB value that took over
  60 s. In nine more an interruption did not land where the test expects
  it, because the statement had ended or had not begun. None of the 60
  was looked at beyond what it reported.
* **The seven of run 2.** Four MARS cancellation tests reached their
  bounds of 60 and 120 s, since an Attention right behind its request is
  what Azure is slowest to act on, and on Basic the statement it has to
  wait out is slow as well; one `cancelActiveStatement` took 11 s. One
  more interruption test (`Mars.WithQueryS` "without MARS, an
  interruption between reads") found its interruption too early or too
  late, `MarsTx.Snapshot`'s control met a DNS failure, and
  `Resources.ConnectCost` measured 14.3 MB of allocation for an
  `EncryptOn` connection against a bound of 8 MB. Neither of the last two
  unexplained ones came back on S3.

No scratch database was left behind by either run.

### S3 again, with the matrix's fixes

Two whole-suite runs on 2026-10-15 with the test database back at S3,
strict encryption, without the slow tests, from an 8-vCPU, 16 GB container
with the default 16 jobs, the suite as of the test matrix's fixes: 3380
examples each, with 2 failures and 103 pending in 539 s on plain
connections, and none in 478 s over MARS connections, the first run of the
whole suite that way to pass at its first attempt. Both failures of the
plain run passed when run again alone:

* The harness's test of the companion database could not log in to it:
  error 40613, which Azure documents as transient.
* `Mars.WithQueryS` "interrupted just after its request was sent ...
  (100 times)" ran out of its 120 s in round 97, with no round stuck: the
  slowest took 4.3 s. Each round cancels a 1,000,000-row `SELECT` right
  behind its request, and Azure acts on such an Attention only once the
  statement has sent its result. Alone, the 100 rounds took 16 s. The
  test allows 600 s on Azure now.

### Native Windows client outside Azure

On 2026-10-26 `scripts/azure-sql-test.sh run-local --jobs 4` ran the suite
natively on Windows, with GHC 9.12.4, network 3.2.9.0 and tls 2.4.13 under
the default I/O manager, over TCP with strict TLS validated, MARS off for
the default test connection and the slow tests off. The database was S3
under the Default policy, so the connections went through the gateway on
port 1433. The run took 2,286 s: 3,585 examples, one failure and 106
pending. The failure was `Connection.Database`'s name with a character
outside the BMP, which Azure refused with error 1055; the test now expects
the refusal on Azure and passed against Azure and SQL Server 2025, and the
whole suite was not run again after that test-only change.

`Connection.Disconnect`'s `KILL` while rows are streaming passed under
`EncryptStrict`, `EncryptOn` and `EncryptOff`, in the full run and in
five more focused runs of the three (15 checks, each three-case run
taking 2.12 to 2.66 s), so this client did not reproduce the hang of the
macOS system, under the full suite's load either. That alone doesn't
establish why the other client hangs or whether the cause is the
platform's.
