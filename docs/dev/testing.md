# Testing hmssql

How to run the test suite, and what each platform and server needs; the
test matrix; the latest results, with what the runs established; how to
write a test; how to measure a change with the benchmarks; and the
methods that produced the suite. The bugs it found are in
[bugs-found.md](bugs-found.md).

## Running the tests

The `hmssql-tests` suite (in `hmssql-tests/`) has pure round-trip properties for
every serializer, tests against an in-process mock TDS server and an
in-process TLS server, and tests against a live SQL Server. hspec-discover
finds the modules: any `hmssql-tests/**/*Spec.hs` exporting `spec` is run, under
its module name (`Wire`, `Query`, `Types.Decimal`, and so on). The suite
is about 6,000 examples (5,999 on 2026-11-07). A run against a local
server takes three to six minutes, and with the slow tests half an hour to
an hour, most of it the 5,000 sequences of each of `Model.Connection`'s
two machines.

```sh
stack test
stack test --test-arguments '--match Wire.Primitives'  # no server needed
HMSSQL_TEST_SLOW=1 stack test                           # also the slow tests
HMSSQL_TEST_SOAK=30 stack test --test-arguments '--match Soak'  # 30-minute pool soak test
```

### The environment

The live tests are configured through environment variables. The
developer's are in `~/.hmssql-test-env`, a file of `export` lines to
`source` before a run (the root `CLAUDE.md`, "Credentials and servers").

| Variable | Default | What it sets |
|---|---|---|
| `HMSSQL_TEST_HOST` | `::1` | The server's host |
| `HMSSQL_TEST_PORT` | `1433` | The server's port |
| `HMSSQL_TEST_USER` | `sa` | The SQL login |
| `HMSSQL_TEST_PASSWORD` | none | Its password. Without it the tests that need a server are skipped ([Without a server](#without-a-server)) |
| `HMSSQL_TEST_REQUIRE_SERVER` | unset | `1` makes the tests that need a server fail, instead of being skipped, when the password is unset |
| `HMSSQL_TEST_DATABASE` | `hmssql_test` | The shared database |
| `HMSSQL_TEST_COMPANION_DATABASE` | the shared database's name with `_companion` after it | A second database, which allows SNAPSHOT isolation ([Writing tests](#writing-tests)) |
| `HMSSQL_TEST_CREATE_DATABASE_OPTIONS` | unset | Text appended to every `CREATE DATABASE` the suite issues. On Azure SQL, `(EDITION = 'Basic', MAXSIZE = 100 MB)`, since a database created without options is General Purpose with 2 vCores |
| `HMSSQL_TEST_CERT` | none | A PEM file to trust in addition to the system store |
| `HMSSQL_TEST_TRUST_SERVER_CERTIFICATE` | `0` | `1` skips certificate validation for the live test connections, strict encryption included, for a development server with an untrusted certificate. The mock TLS tests keep their own settings, and the tests of certificate rejection enable validation regardless |
| `HMSSQL_TEST_TLS_HOSTNAME` | `localhost` | The name the server certificate is validated against (for Azure SQL, the server's fully qualified domain name). The empty string validates against `HMSSQL_TEST_HOST` itself |
| `HMSSQL_TEST_SERVER_NAME` | empty | An override of the LOGIN7 server name, which otherwise is `HMSSQL_TEST_HOST` |
| `HMSSQL_TEST_ENCRYPTION` | `strict`, or `on` for SQL Server 2017 to 2022 | The encryption of the default test connection ([Configurations](#configurations)) |
| `HMSSQL_TEST_STRICT_ENCRYPTION` | inferred from `HMSSQL_TEST_SQL_VERSION` | `0` marks the live strict-encryption tests pending, for an instance without TDS 8.0 configured, even SQL Server 2025; `1` enables them. The mock strict-TLS tests still run |
| `HMSSQL_TEST_PACKET_SIZE` | `8000` | The packet size every test connection asks for |
| `HMSSQL_TEST_SESSION_SETUP` | `default` | `default` (no session setup) or `arithabort` |
| `HMSSQL_TEST_MARS` | unset | `1` makes every test connection a MARS connection |
| `HMSSQL_TEST_MARS_WINDOW` | `64` | The `connectMarsWindow` of every test connection that doesn't set its own |
| `HMSSQL_TEST_PROTOCOL` | `auto` | What the test connections travel on: `auto`, `tcp`, or on Windows `lpc` (Shared Memory) or `np` (Named Pipes) |
| `HMSSQL_TEST_MOCK_TRANSPORT` | `tcp` | What the mock server listens on: `tcp`, or on Windows `pipe` |
| `HMSSQL_TEST_SQL_VERSION` | `2025` | The SQL Server the suite runs against: `2017`, `2019`, `2022` or `2025` ([SQL Server 2017 to 2025](#sql-server-2017-2019-2022-and-2025)) |
| `HMSSQL_TEST_SLOW` | unset | `1` also runs the slow tests |
| `HMSSQL_TEST_SOAK` | unset | A number of minutes runs `hmssql-tests/Soak/RunSpec.hs`'s pool soak test, pending otherwise |
| `HMSSQL_TEST_KNOWN_BUGS` | unset | `1` runs the tests pending on a known bug (`knownBug`) |
| `HMSSQL_TEST_PROPERTY_SCALE` | `1` | A factor for the number of cases every property runs ([Property cases](#property-cases)) |
| `HMSSQL_TEST_ACCESS_TOKEN` | unset | An Entra ID access token for `Connection.AccessToken` ([Azure SQL](#azure-sql)), with `HMSSQL_TEST_ACCESS_TOKEN_USER` the login the session must show |
| `HMSSQL_TEST_AZURE_SERVER_NAME` | unset | `1` enables `Connection.AzureServerName`, an Azure-only matrix of LOGIN7 server names ([Azure SQL](#azure-sql)) |
| `HMSSQL_MODEL_TRACE` | unset | `1` makes the `Model` runner log every operation and its outcome to stderr |

Before the first live test, the suite creates the shared and the
companion database if they are missing (connecting to `master`), and
leaves them in place. Concurrent runs, from several worktrees for
example, are safe, but whole suites run at once against one server
saturate its worker pool, even with separate test databases
(2026-11-04), so run whole suites against one server one at a time. The tests that need `sysadmin` (a `RAISERROR ... WITH
LOG` at severity 20 in the soak test) assume the `sa` login.

The tests expect the server certificate to be issued for `localhost` (or
`HMSSQL_TEST_TLS_HOSTNAME`), with `HMSSQL_TEST_CERT` naming its PEM file
when it is self-signed. [The test server's
certificate](#the-test-servers-certificate) has the steps that give a
server such a certificate, and `HMSSQL_TEST_TRUST_SERVER_CERTIFICATE=1`
runs the live TLS tests against a server without one.

Every run prints one line first, saying what it tests against: the server
and its databases, the protocol and the transport the server reports,
MARS and its window, the encryption, the packet size, whether the server
certificate is trusted, the session setup, on Windows which I/O path the
run covers, and whether the slow tests run.

### Without a server

Without `HMSSQL_TEST_PASSWORD`, anything that would connect to the test
server throws `NoTestServer` instead, and the hook reports such tests as
pending ("needs a SQL Server"), while the pure tests and the tests against
the mock and the in-process TLS servers still run. So `stack test` passes
in a package build without a SQL Server, as Stackage, Nix and Debian
builds run test suites. Set `HMSSQL_TEST_REQUIRE_SERVER=1` in CI to make a
missing password fail the run instead.

### Configurations

The default test connection is what an application gets from
`defaultConnectInfo`: strict encryption, 8000-byte packets, no session
setup and no MARS. Five variables move every test connection off it, to
exercise the code paths it misses: SQL Server sends NBCROW rows only over
TDS 7.4, small packets split values and tokens across many packets, and
MARS sends every request on an SMP session. They change the connection of
`withTestDb`, `defaultTestConnectInfo`, `companionConnectInfo` and
`masterConnectInfo`, and so `withScratchDatabase`. A test that asks for a
particular encryption, packet size, session setup or MARS setting keeps
it.

* **Encryption** (`HMSSQL_TEST_ENCRYPTION`): `strict` (TDS 8.0), `on` or
  `req` (TDS 7.4, with TLS hosted in PRELOGIN), `off` (TLS for the login
  only) or `notsup` (plaintext, if the server allows it).
* **Packet size** (`HMSSQL_TEST_PACKET_SIZE`): 512, the smallest, splits
  values and tokens across many packets, and 32767 is the largest.
* **Session setup** (`HMSSQL_TEST_SESSION_SETUP`): `default` gives
  `connectSessionSetup = []`, what applications get, so a `reset` rides
  on the next request. `arithabort` gives `["SET ARITHABORT ON"]`, the
  documented opt-in, so the setup batch runs at connect and after each
  `reset`.
* **MARS** (`HMSSQL_TEST_MARS=1`): every test connection has `connectMars
  = True`. A request then no longer abandons an open stream, and a batch
  can't leave a transaction it began open (error 3997). The tests whose
  expectation differs say what holds under MARS (`testMars`), and a test
  of something MARS doesn't have asks for a connection without it.
* **The MARS window** (`HMSSQL_TEST_MARS_WINDOW`): with MARS, a small
  window holds a response back at a few packets, and with 512-byte
  packets at a few rows, so that every read of a stream waits on the
  window and its ACKs (`mars+w4+p512` in the matrix's notation).
* **The protocol** (`HMSSQL_TEST_PROTOCOL`): `auto` is `ProtocolAuto`,
  which picks by what the server has enabled, so the run's first line
  names the transport the server reports. Connections to the mock server
  are not affected. `HMSSQL_TEST_MOCK_TRANSPORT=pipe` makes the mock
  serve a named pipe of its own, so that the mock tests run the client's
  pipe backend; a test of something only TCP has (a port, a half-close or
  a socket option) keeps TCP (`withTcpMockServer`). Both are for
  [Windows](#on-windows).
* **The server version** (`HMSSQL_TEST_SQL_VERSION`), for a server that
  lacks what the suite uses by default ([SQL Server 2017 to
  2025](#sql-server-2017-2019-2022-and-2025)).

### Building

The library, the test suite and the benchmarks are three packages, in
`hmssql/`, `hmssql-tests/` and `hmssql-bench/`, so that building the library
alone builds nothing else. `stack.yaml`'s `ghc-options` has GHC compile
every local package's modules in parallel (`-j`, with a 128 MB allocation
area for GHC itself) and the test suite without optimisation (`-O0`), which
makes a full rebuild of the suite about 6x faster, since the tests spend
their time in the library, which stays optimised. The options are in
`stack.yaml` rather than behind a flag in the `package.yaml` files, so that
the published package carries none of them; a cabal build gets them with
`--ghc-options=-j` or a `package` stanza in a `cabal.project.local`. The
test executable runs with `-N -A64m`: a 64 MB allocation area per
capability makes the allocation-heavy properties 2 to 3x faster. The
`nonthreaded` flag links it without `-threaded`, with `-A64m` alone
([On Windows](#on-windows)).

The value decoders' byte reads (`Hmssql.Tds.Bytes`) are always
bounds-checked (a read outside the buffer calls `error`), so a decoder that
trusts a wrong length fails a test (`Wire.ValueReaders`, `Types` or
`Differential.Decode`) instead of reading past a value. There is no
unchecked build.

Every token and value is read by the reader recipes
(`Hmssql.Tds.Parser`). There is no other parser and no build flag that
selects one. The wire tests compare generated tokens with parsed values,
and feed truncated input, input a byte at a time and arbitrary packet
cuts. `Wire.RecipeGet`, a test-only adapter, runs the older `Get`-based
assertions on the same recipes, zero-length values included.

### GHC versions

`stack.yaml` uses `nightly-2026-11-03` (GHC 9.12.4, `tls` 2.4.6, `crypton`
1.1.5 and `network` 3.2.11.0, with no `extra-deps`). With it the library,
the examples and the benchmarks build without warnings on Linux (x86-64),
and the test suite with about forty, nearly all redundant imports
(2026-11-05). The last macOS build was on the previous snapshot,
`nightly-2026-09-27`. [The test matrix](#the-test-matrix) builds the suite
with cabal on every version in `tested-with`, 9.6.6 to 9.14.1. GHC 9.4 is
refused by the solver (`base >= 4.18`). With GHC 9.14, `cabal.project`
relaxes the bounds of `serialise` and `cborg`, which tls needs.

## Platforms and servers

### Linux

Linux is the reference platform. The developer's server is SQL Server
2025 in the Docker container `sqlserver2025` on localhost:1433, with a
certificate made as [The test server's
certificate](#the-test-servers-certificate) shows, and [the test
matrix](#the-test-matrix) runs every supported GHC against SQL Server 2017
to 2025 there, in Docker. The executables that run in Azure are built for
Linux ([Linux builds in Docker](#linux-builds-in-docker)).

### macOS

The suite runs on macOS as on Linux, against a server in Docker. Two
things differ:

* A bound socket that doesn't listen drops a SYN, where Linux refuses
  it, so a connect to the mock's refusing port (`withRefusingPort`)
  times out with `ETIMEDOUT`; the tests accept either.
* GHC's kqueue I/O manager, before 9.14, keeps a failed registration of a
  descriptor that was closed under a waiting thread, and a later close
  of the same number can wedge a bucket of the manager
  ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)).
  A test that closes a socket under its own reader can meet that on
  either platform; see [What the runs
  established](#what-the-runs-established).

The benchmark's mock closes its connections with a reset, because macOS
has 16,384 ephemeral ports ([Benchmarks](#benchmarks)).

### On Windows

The suite builds and runs on Windows, over TCP, Shared Memory and Named
Pipes, with the threaded runtime and without it, and under both of GHC's
I/O managers. The development machine is Windows 10 with a local SQL
Server 2019 RTM (15.0.2000.5, Developer Edition); earlier runs were
against SQL Server 2025, on Windows as well.

#### Building and running

With Stack, the non-threaded runtime is the `nonthreaded` flag, built in a
work directory of its own so that the two builds don't replace each
other:

```sh
stack --work-dir .stack-work/nonthreaded build --test --no-run-tests --flag hmssql-tests:nonthreaded
source ~/.hmssql-test-env
hmssql-tests/.stack-work/nonthreaded/dist/*/build/hmssql-tests/hmssql-tests.exe --no-unicode
```

Run the binary itself rather than `stack test` when its output goes to a
file: stack relays the test output in the console's code page and stops
at hspec's first check mark (`commitAndReleaseBuffer: invalid argument`),
and `--no-unicode` keeps the report plain. Without `-threaded` the suite
runs 4 items at once rather than 16 (`SpecHook.defaultJobs`), and one item
that needs a second capability stays pending.

`stack build` can fail on `examples/managed-identity` with "permission
denied" renaming `cabal_macros.h` in its `autogen` directory, after the
library and `hmssql-tests.exe` have linked (twice on 2026-10-16).
`stack build hmssql --test --no-run-tests` builds the library and the
suite alone.

With cabal and a stock GHC run from MSYS2's CLANG64 shell:

```sh
source ~/.hmssql-test-env
cabal test hmssql-tests --enable-tests --with-compiler=ghc-9.12.4 \
  --builddir=dist-newstyle/stock --constraint='network < 3.3' \
  --test-show-details=direct
```

Use the `CABAL_DIR` the GHCup installer sets (`C:\cabal` by default). If
building `hsc2hs` fails with an undefined `__local_stdio_printf_options`,
check the global Cabal configuration: an `extra-include-dirs` or
`extra-lib-dirs` entry for MSYS2's `clang64` directories mixes newer CRT
headers with GHC's bundled runtime libraries. Remove those, keep the
`extra-prog-path` entries, and let each package find its C libraries.

From Git Bash:

* **Turn path conversion off.** Git Bash rewrites an argument that starts
  with `/` into a Windows path before a native program sees it, so
  `--match "/Wire/"` reaches the test binary as a path under Git's
  directory and matches nothing. The run then reports `0 examples, 0
  failures` and exits 0, which looks like a pass. Set
  `MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL='*'`, or leave the leading
  slash off the pattern.
* **`~/.hmssql-test-env` is a shell script.** `source` it from Git Bash,
  and start a native program from that shell if it needs the variables.
* **Don't drive many runs from a Git Bash script.** A runner that started
  each top-level group as a process of its own, with a time limit, hung
  itself every few hundred groups, the shell failing to fork, with several
  runs going at once. One written in Python, which starts the test binary
  directly, did not, and needs no path-conversion variables. A runner of
  that kind is how to find which group hung, since hspec prints results
  in the order of the tree while it runs sixteen items at once, and a
  hung item hides the rest of the run.

#### Transports and I/O managers

* **TCP** runs as it does anywhere, at sixteen tests at a time.
* **A SQL Server with TCP/IP disabled** is reached with
  `HMSSQL_TEST_PROTOCOL=lpc` or `np`, or with `HMSSQL_TEST_HOST=localhost`
  and the default `auto`. The default host, `::1`, is an address, which
  `ProtocolAuto` doesn't take for this machine. With Shared Memory
  enabled, `localhost` with `auto` connects over Shared Memory and not
  over TCP. To try TCP to a name that resolves to both `::1` and
  `127.0.0.1`, and so the several-address connect of `connectAddresses`,
  set `HMSSQL_TEST_PROTOCOL=tcp` as well.
* **The mock server** goes through hmssql's own socket backend on
  Windows, because a thread inside one of network's calls can't be
  stopped there; it closes its listener to end its accept loop. With
  `HMSSQL_TEST_MOCK_TRANSPORT=pipe` it serves a named pipe instead, which
  needs no privilege.
* **GHC's native I/O manager** is chosen when the test binary starts:
  `stack test --test-arguments "+RTS --io-manager=native -RTS"`, or the
  same option on the binary's command line (it is linked with
  `-rtsopts`). `GHCRTS=--io-manager=native` works too, but every other
  Haskell tool on the `PATH` reads it as well.

Which code a run covers depends on the build
([design.md](design.md#platform-workarounds)). With network 3.3 and a GHC
that defines `__IO_MANAGER_WINIO__` as 2, under the native manager, TCP
goes through network's own calls and the pipes through the manager's
completion port, with or without `-threaded`. Otherwise hmssql runs its
own overlapped I/O under either manager, and what a run under the native
manager adds is the manager's effect on everything around that code: the
timers, the clock, the mock's listener, and with network 3.3 the sockets'
association with the manager's port. The run's first line says which path
it covers ("TCP through network's calls and the pipes through GHC's
native I/O manager", or "TCP and the pipes through hmssql's overlapped
I/O"). The tests that behave differently on network's TCP path check
`Compat.windowsNetworkTcp`, and a test of a send that nothing interrupts
there asks for the mock on TCP as well, since a pipe's send is
interruptible on both paths. Without `-threaded` on network's path, three
tests are pending (`Compat.blockingCallStopsProcess`): two need the mock
server, in the same process, to read a blocked send, and one connects to
an address that doesn't answer, which stops the whole process for 21 s
and fails the tests running beside it.

On 2026-11-06 no released GHC defined the 2 and network 3.3 was not
released, so that path was tested with GHC and network built from master
([below](#testing-with-ghc-master-and-the-native-io-manager)). A release
candidate that defines it, GHC 9.12.4.20260713, was tested earlier with a
second `stack.yaml` beside the project's, naming the compiler
(`compiler: ghc-9.12.4.20260713`, with `system-ghc: true` and ghcup's copy
first on the `PATH`) and the network checkout as an `extra-deps` path, in
a work directory of its own (`--work-dir`)
([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).

#### The server's listeners

* **The first connection may be refused.** The server on the development
  machine refused some first pipe connections after an idle spell, and
  then stopped listening for up to a minute
  ([windows-research.md](windows-research.md#the-servers-pipe-listeners)).
  The suite's first connection is its setup hook's, which therefore
  waits, for up to two minutes, and prints each wait with the failure
  (`waitingForPipes` in `hmssql-tests/SpecHook.hs`). A test that fails at
  `connect` with "No process is on the other end of the pipe" or "All
  pipe instances are busy" is checked against the server's log before it
  is taken for a failure of hmssql.
* **SQL Server 2025 before build 17.0.1135.8 stopped listening under the
  suite's concurrency.** With sixteen tests at a time its Shared Memory
  and Named Pipes listeners stopped again and again, for 8 to 57 seconds
  each time, and tests failed at `connect` on a busy pipe or a dropped
  login. One test at a time (`--jobs 1`, in one process) left the stops
  few enough for hmssql's 30-second wait on a busy pipe to cover nearly
  all of them. A login the server refused (error 17827 in its log) still
  failed a test now and then, so a group that failed was run again
  before its failure was believed, and the server's log (`EXEC
  xp_readerrorlog 0, 1`, errors 26050, 26044 and 17827) said whether the
  server was the one that failed: 2 and 4 of the 198 groups needed a
  rerun in a whole run over each pipe. From build 17.0.1135.8 on, no run
  over the pipes met either fault, and the 2026-10-16 server log had none
  of those errors
  ([windows-research.md](windows-research.md#the-servers-pipe-listeners)).
* **Over TCP a connect timed out under load** now and then (twice in
  about a dozen runs at sixteen tests at a time), failing the test it
  belonged to. Four whole runs over TCP and one over Shared Memory at that
  concurrency on 2026-10-16, on build 17.0.1145.4, met none.

#### How the tests are written for Windows

Each rule came from a test that failed on Windows for a reason that was
the test's, not hmssql's.

* **A helper's timeout must not leave a long delay behind.** Under the
  default I/O manager, a `timeout` whose action returns leaves its delay
  with GHC's timer thread until the limit passes, and when thousands of
  those expire, no timer in the process fires for a second or more
  ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)).
  The model's wait for each operation, 15 s around each of about 9,700,
  did that to the rest of the run: `MarsTx.ResetGate`'s own 200 ms
  `timeout` didn't fire within the second it had, in 9 whole-suite runs
  of 12 with `HMSSQL_TEST_ENCRYPTION=notsup`, the configuration whose
  timing put the two together. A helper that waits for each operation,
  message or packet uses `timeoutInSlices` (`hmssql-tests/Compat.hs`), which
  leaves at most 50 ms behind. A test's own `timeout` around a call to
  hmssql stays `timeout`. The default manager's pool of workers also
  grows with those `timeout`s and never shrinks
  ([limitations.md](limitations.md#behaviours-to-know-about)).
* **A test that must act within a round trip spins, and doesn't sleep.**
  `threadDelay` and `timeout` take 16 ms at the least on Windows, and a
  round trip to a local server is far shorter. A watcher that looked for
  a state every 20 ms (`Mars.WithQueryS`, the interruption of the exit's
  wait for the Attention's acknowledgement) found the wait over on every
  one of 50 tries, in most runs of an unoptimised build. It now spins
  with `yield` until the Attention is recorded, as the watcher of
  `Concurrency.Attention` does.
* **Durations are measured with the monotonic clock.** The wall clock
  (`getCurrentTime`) advances in ticks of up to 16 ms on Windows, and
  under the native I/O manager a connect to the mock measured 0 s twenty
  times in twenty. `Resources.ConnectTimeout` sized its sweep of timeouts
  from that measurement, so every timeout was too short to let a connect
  finish, and the test failed its own coverage check. `elapsed` in
  `Concurrency.Harness` and the sweep use `getMonotonicTime`.
* **A thread that doesn't end after being interrupted says what it is
  blocked on.** `interruptWith` reports the thread's `threadStatus` when
  it gives up after 60 s. That is how a hang under the native I/O manager
  was traced to GHC and not to hmssql: the status was
  `BlockedOnForeignCall`, and the same was then reproduced with a file
  read and nothing else
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
* **A mock that signals "sent" signals before it sends.** The mock's send
  goes through hmssql's backend on Windows and returns some tens of
  microseconds after the bytes have left, by which time an optimised
  client may have acted on them. `Resources.ConnectReader` sweeps an
  interruption across the end of `connect`, counted from the login
  response; with the signal after the send, no attempt in 3,000 was
  interrupted. `serveLoginAfter` gives it just before the send.
* **A test that must stop a thread that is sending or receiving** does
  the I/O through a `Backend` (`socketBackend`, or the connection's own),
  never through network's calls directly. `killThread` and `timeout`
  don't return while their target is inside one of those.
* **A `Handle` a test makes from a socket must end up closed.** An open
  handle that becomes garbage is closed by its finalizer, at whatever
  collection finds it, and that closes the socket's number. Windows soon
  gives a closed handle's number to another, so if the socket was closed
  some other way in the meantime, the finalizer may close a socket of a
  later test. `Resources.CloseFailure` breaks a close by turning the
  socket into a handle and letting go of the handle without closing the
  descriptor (`detachDescriptor` in `hmssql-tests/Compat.hs`). On Windows that
  once left the handle open, and the module's finalizer test, which
  collects garbage, lost its own sockets in 56 runs of 200
  ([bugs-found.md](bugs-found.md#in-the-test-suite)). `detachDescriptor`
  marks the handle closed there, as `handleToFd` does elsewhere.
* **Leaked handles are counted two ways.** The tests that count open
  descriptors on other platforms count the process's kernel handles on
  Windows (`fdCount` in `hmssql-tests/Resources/Helpers.hs`). That count includes
  every event and thread, and it moved by 3 to 62 across 5,000 connects
  with nothing leaked, so it is allowed a slack of 250 and shows only a
  gross leak. The exact check is `backendHandlesReturnTo`, which reads
  hmssql's own count of the sockets and pipes it has open.
* **No test assumes TCP or a server on Linux.** `Protocol.Login` opens
  what `HMSSQL_TEST_PROTOCOL` names, where it opened a socket of its own.
  `Mars.Negotiation` asks the server which transport the suite is on
  (`testNetTransport`), where it expected `TCP` in
  `sys.dm_exec_connections`. `Mutation.HostedTls` expected a killed
  session to end in an orderly close; SQL Server on Windows resets the
  connection, or disconnects the pipe, and the test accepts that when the
  server says it runs on Windows (`testServerOnWindows`).
* **Three tests of `Concurrency.Attention` need to interrupt a
  cancel-drain, which a pipe may not allow.** Over a pipe to a local
  server, one test at a time, with a library built without optimisation
  (`--fast`), the drain was mostly over before any of a hundred
  interruptions could land; with the standard build they passed every
  time. Over a pipe such a test is reported as pending, with its
  attempts, when no interruption lands, because it has no state to check
  (`fromInterruptedDrain`); over TCP it fails as before. The same spec
  tests the same guarantees against the mock server, which withholds the
  acknowledgement so that the drain is sure to wait, and those pass with
  the mock on a named pipe.
* The `unix` package doesn't exist there. `hmssql-tests/Compat.hs` has what the
  suite took from it (`exitImmediately`, and random bytes for the run's
  tag).

#### Testing with GHC master and the native I/O manager

network's TCP path and the pipes through the manager need a GHC that
defines `__IO_MANAGER_WINIO__` as 2 and network 3.3. On 2026-11-06 neither
was released, so they were tested with GHC master and network master,
built as follows, and the native manager's fixes were tested on a GHC
branch. Budget about an hour, most of it unattended: the GHC build took 20
minutes on 2026-11-06, and hmssql's dependencies are about sixty packages
that cabal builds with the new compiler the first time.

**The shell.** Every command runs in MSYS2's bash as CLANG64, with a
`PATH` that puts the boot compiler (GHC 9.12.4), alex, happy and cabal on
it and leaves `/clang64/bin` off, so that no other compiler shadows the
one GHC downloads into its tree. Not Git Bash, and not the CLANG64 shell
with its default `PATH`. `~` in that shell is MSYS2's home, not the
Windows user's, so the test settings are sourced by their full path. To
run a command in that shell from another, `MSYSTEM=CLANG64
<msys64>/usr/bin/bash.exe -lc '...'`.

**GHC master.** In the GHC checkout:

```sh
git pull
git submodule update --init --recursive
./boot
./configure --enable-tarballs-autodownload
cabal update
hadrian/build --flavour=default+no_profiled_libs+debug_info --docs=none -j
```

* `cabal update` comes before the build because hadrian builds itself
  with cabal: without a recent package index it stops at once with
  "Please run 'cabal update' first", as it did on 2026-11-06.
* `./boot` and `./configure` are needed whenever `configure.ac` or `m4/`
  may have changed, and running them again is harmless. Read the summary
  `configure` prints: it names the boot compiler, alex, happy and the C
  toolchain it found. On 2026-11-06 master wanted a boot GHC of 9.10 or
  later, alex 3.2.6 or later and happy below 2.3, which 9.12.4, alex
  3.5.4.2 and happy 2.2 satisfied.
* A new master is not built with `--freeze1`: the compiler itself
  changed, so everything is rebuilt. Freezing stage 1 is for after an
  edit of `ghc-internal` or the RTS alone. If the build fails in a way
  that looks like stale output rather than a real error, run
  `hadrian/build clean` and build again.

`_build/stage1/bin/ghc.exe --version` gives `10.1.<date of the commit>`,
and `--info | grep "Project Git commit id"` the checkout's commit. network
compiles its code for the native manager only when the compiler defines
`__IO_MANAGER_WINIO__` as 2 or more, which master does. To see it, with
`$HC` the new compiler:

```sh
printf '{-# LANGUAGE CPP #-}\nmain :: IO ()\nmain = print (__IO_MANAGER_WINIO__ :: Int)\n' > winio.hs
$HC -outputdir winio winio.hs -o winio.exe && ./winio.exe    # prints 2
```

**network master.** The network checkout needs the change of network's
pull request 628, applied by hand to `configure.ac` and `network.cabal`:
without it network's `configure` writes a `test-suite` section into
`network.buildinfo`, which the Cabal of cabal-install 3.18 refuses.
`configure.ac` is then newer than the `configure` generated from it, so
run `autoreconf -i`. To update network later, keep the edits across the
pull (`git stash`, `git pull`, `git stash pop`, `autoreconf -i`); once
that pull request is merged, `git checkout configure.ac network.cabal`
takes the place of `git stash pop`, and `autoreconf -i` is still needed.

**The repros, optional.** GHC's two native-manager repros, built with the
new compiler against that network, are the quickest check that the two
work together before hmssql's larger build. Their READMEs say how to build
and run them, and what a fixed manager makes them show:
[upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)
and [upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md).
Without `+RTS --io-manager=native` both run clean, which is the control.

**hmssql.** `stack.yaml` pins GHC through a Stackage snapshot, and Stack
has no good way to use a compiler that isn't installed, so the build uses
cabal, with a project of its own in a directory outside the repository.
It names hmssql and the network checkout as local packages, so that cabal
builds network from source instead of taking 3.3.0.0 from Hackage, and
keeps everything it builds out of hmssql's tree:

```
packages: <the hmssql checkout>
          <the network checkout>
          -- Patched copies of packages that don't build on GHC master.
          <patched>/hashable-1.5.1.0
          <patched>/strict-0.5.1
          <patched>/crypton-1.1.5
          <patched>/serialise-0.2.6.1

with-compiler: <the GHC checkout>/_build/stage1/bin/ghc.exe

-- The boot libraries of an unreleased compiler carry versions that no
-- package on Hackage allows yet.
allow-newer: all

-- The TLS stack of stack.yaml's snapshot (nightly-2026-11-03).
constraints: tls ==2.4.6, crypton ==1.1.5,
             crypton-x509 ==1.9.1, crypton-x509-store ==1.9.0,
             crypton-x509-system ==1.9.0, crypton-x509-validation ==1.9.1

tests: True

package hmssql
  ghc-options: -j
```

The TLS stack is pinned because with nothing pinned cabal took tls 2.5.1
and crypton 2.2.6, and hmssql doesn't compile against tls 2.5, which drops
`HashSHA1`; the same versions also keep the runs comparable with GHC
9.12.4. `allow-newer` lifts version bounds only, and on 2026-11-06 four
packages didn't compile on master. Each was fetched with `cabal get` into
a directory of patched copies and changed as little as builds, with a
comment saying the change is for GHC master:

| Package | Error on master | Change |
|---|---|---|
| hashable-1.5.1.0 | `GHC.Num.BigNat`, `GHC.Num.Integer` and `GHC.Num.Natural` are in the hidden package `ghc-bignum`, since base no longer re-exports them | In `hashable.cabal`, `if impl(ghc >=10.1)` adds `build-depends: ghc-bignum` |
| strict-0.5.1 | A non-canonical `mappend` in `Monoid (Pair a b)` is an error (GHC-50928), with no `-W` flag to relax it | The `mappend` line of that instance removed from `src/Data/Strict/Tuple.hs`, so that it defaults to `(<>)` |
| crypton-1.1.5 | GHC's `Stg.h` requires C11, and crypton compiles its C with `-std=gnu99` | `-std=gnu11` in `crypton.cabal` |
| serialise-0.2.6.1 | `KindRepTYPE` is gone: `KindRep` has `KindRepType` and `KindRepConstraint`, without fields | In `instance Serialise KindRep` (`src/Codec/Serialise/Class.hs`), the two new constructors as tags 4 and 6, with no field |

tls needs serialise. A later master may break other packages the same
way: fetch the version the plan picked, patch it, and add it to
`packages:`. Then, in the project's directory, `cabal update` and `cabal
build hmssql-tests:test:hmssql-tests`. Once the patches were in, the build took
a little over a minute on 2026-11-06, since cabal had kept what the
failed attempts had built. When master moves again, rebuild GHC, update
network as above, and build hmssql again: a new GHC commit has a new
version number, so cabal builds the dependencies again into a store of
their own.

**Running the suite.** First the tests that need no server, as a check
that the build runs, and then the whole suite, with the variables of
[The environment](#the-environment) set in the shell
(`HMSSQL_TEST_SQL_VERSION=2019` for SQL Server 2019):

```sh
cabal test hmssql-tests:test:hmssql-tests --test-show-details=direct \
  --test-options='--match Wire.Primitives'
cabal test hmssql-tests:test:hmssql-tests --test-show-details=direct \
  --test-options='+RTS --io-manager=native -RTS'
HMSSQL_TEST_PROTOCOL=np HMSSQL_TEST_MARS=1 cabal test hmssql-tests:test:hmssql-tests \
  --test-show-details=direct --test-options='+RTS --io-manager=native -RTS'
```

Pass the RTS option on the command line rather than in `GHCRTS`, which
cabal and the other tools would read too. The non-threaded runtime is the
`nonthreaded` flag, with a build directory of its own so that it doesn't
replace the threaded build: `-f nonthreaded
--builddir=dist-nonthreaded` on each command. To run the test binary
itself, in a loop or with its output in a file, take its path from `cabal
list-bin hmssql-tests:test:hmssql-tests` and pass `--no-unicode`.

**The manager's fixes.** On master the native manager crashed under busy
sockets (three runs over MARS in four) and froze the non-threaded
runtime. Both are fixed on the GHC branch `wip/winio-completion-packets`
(`16069bfc8c`, master `20334e1d1f` with the fixes, 2026-11-07, not yet
upstream), which the runs of the pipes through the manager need:
completion packets that outlived their requests, a cancelled read waited
for on its file handle, a batch of exactly 64 completions that failed a
bounds check, and in the non-threaded runtime `asyncDoProc`, an idle
spin, and a garbage collection whenever every thread blocked
([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).
network's branch `winio-recvmsg-more-data` has one fix too, for
`recvBufMsg`, which hmssql doesn't use. A failure that appears only with
the native manager, or a crash in `processCompletion`, is the kind of
thing these builds exist to find; [upstream/](upstream/) has what is
known. The results are in [Latest results](#latest-results).

hmssql also ran under warp on both managers with this build, threaded, on
2026-11-07, streaming query results into HTTP responses under load
([windows-research.md](windows-research.md#the-pipes-through-the-manager-2026-11-07)).

### SQL Server 2017, 2019, 2022 and 2025

The suite is developed against SQL Server 2025, and
`HMSSQL_TEST_SQL_VERSION` runs it against an older server; the variable
alone is enough, because it moves the default test connection to `on`.
Without it, against a server without strict encryption, the setup fails
at its first connection with "the server closed the connection", and the
hook's message then names the variable.

| Version | What it lacks | What the variable marks pending |
|---|---|---|
| `2022` | Strict encryption, on Linux: the server closes the connection with error 17821 ([protocol-notes.md](protocol-notes.md#strict-encryption-tds-80)). The `json` and `vector` types | Every test connection with strict encryption (`baseConnectInfo`), and the tests of what SQL Server 2025 added (`skipBeforeSql2025`) |
| `2019` | TDS 8.0 (error 17832 at the ClientHello). `STRING_SPLIT`'s ordinal argument and `GENERATE_SERIES` (errors 8144 and 208) | What `2022` marks, and the tests of what SQL Server 2022 added (`skipBeforeSql2022`) |
| `2017` | The UTF-8 collations (error 448), and it doesn't acknowledge the UTF-8 feature extension ([protocol-notes.md](protocol-notes.md#login7-and-login)) | What `2019` marks, and the tests of the UTF-8 collations (`skipBeforeSql2019`). The differential tests' random tables have no UTF-8 columns (`collationsFor`), and the test of the negotiation expects no UTF-8 support |

SQL Server 2019 RTM sometimes runs a stale cached plan against a
re-created `#temp` table
([protocol-notes.md](protocol-notes.md#session-state-and-reset)). That
fails `Differential.Decode` in about one whole-suite run in four in
plaintext, with a server error, a closed connection or a `ProtocolError`,
and the server's log then has error 682, 3624 or 17310. Whether CU32 still
does it is a [check to revisit](#checks-to-revisit). On a server under
load, a timeout is the server's rather than a hang of the client, and the
matrix spreads its runs over the servers for that reason ([The test
matrix](#the-test-matrix), and
[protocol-notes.md](protocol-notes.md#the-server-under-load)).

### The test server's certificate

The default test connection uses strict encryption and validates the
server's certificate against `localhost`. With no certificate configured,
SQL Server generates one for itself at every start, which no client can
validate, so the test server needs a certificate that stays: one issued
for `localhost`, with its PEM file named by `HMSSQL_TEST_CERT`. An
application rarely needs this, because most connect over TDS 7.4 with
`tlsTrustServerCertificate` or to a server whose certificate a certificate
authority issued, which is why the steps are here and not in the guide.

**In a Linux container**, the certificate and `mssql.conf` go into the data
volume before the server's first start, written by the server's own image,
which has `openssl`. These are the steps `scripts/test-matrix.sh` runs
(`start_sql`); user 10001 is `mssql` in the image:

```sh
docker volume create mssql-data
docker run --rm --user root --entrypoint bash \
  -v mssql-data:/var/opt/mssql \
  mcr.microsoft.com/mssql/server:2025-latest -c '
    set -e
    mkdir -p /var/opt/mssql/certs
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
      -keyout /var/opt/mssql/certs/server.key \
      -out /var/opt/mssql/certs/server.crt 2>/dev/null
    cat >/var/opt/mssql/mssql.conf <<EOF
[network]
tlscert = /var/opt/mssql/certs/server.crt
tlskey = /var/opt/mssql/certs/server.key
EOF
    chown -R 10001:10001 /var/opt/mssql
    chmod 600 /var/opt/mssql/certs/server.key
    cat /var/opt/mssql/certs/server.crt' >sqlserver.crt
docker run -d --name sqlserver -p 1433:1433 \
  -v mssql-data:/var/opt/mssql \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='...' \
  mcr.microsoft.com/mssql/server:2025-latest
```

`sqlserver.crt` is the file for `HMSSQL_TEST_CERT`. SQL Server 2022 on
Linux refuses strict encryption whatever the certificate, so against it
the certificate serves `HMSSQL_TEST_ENCRYPTION=on`.

**On Linux from the package**, the same certificate is created on the host
and named with `mssql-conf`. These steps follow Microsoft's [Encrypt
connections to SQL Server on
Linux](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-encrypted-connections)
and have not been run for hmssql:

```sh
sudo mkdir -p /var/opt/mssql/certs
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
  -keyout /var/opt/mssql/certs/server.key \
  -out /var/opt/mssql/certs/server.crt
sudo chown -R mssql:mssql /var/opt/mssql/certs
sudo chmod 700 /var/opt/mssql/certs
sudo chmod 600 /var/opt/mssql/certs/server.key
sudo /opt/mssql/bin/mssql-conf set network.tlscert /var/opt/mssql/certs/server.crt
sudo /opt/mssql/bin/mssql-conf set network.tlskey /var/opt/mssql/certs/server.key
sudo systemctl restart mssql-server
```

**On Windows**, the certificate is created in the computer's certificate
store, from PowerShell run as an administrator. These steps follow
Microsoft's [Encrypt connections by importing a
certificate](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-sql-server-encryption)
and [Certificate requirements for SQL
Server](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements),
and have not been run for hmssql either:

```powershell
$params = @{
    Type = "SSLServerAuthentication"
    Subject = "CN=$env:COMPUTERNAME"
    DnsName = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostEntry('').HostName, 'localhost')
    KeyAlgorithm = "RSA"
    KeyLength = 2048
    HashAlgorithm = "SHA256"
    TextExtension = "2.5.29.37={text}1.3.6.1.5.5.7.3.1"
    NotAfter = (Get-Date).AddMonths(36)
    KeySpec = "KeyExchange"
    Provider = "Microsoft RSA SChannel Cryptographic Provider"
    CertStoreLocation = "cert:\LocalMachine\My"
}
$cert = New-SelfSignedCertificate @params
```

`KeySpec` and `Provider` matter: SQL Server refuses to start with a
configured certificate whose key is not `AT_KEYEXCHANGE` in a legacy
cryptographic service provider. The server then has to be told to use the
certificate:

1. Give the service account Read on the private key: in `certlm.msc`, on
   the certificate under Personal, All Tasks and then Manage Private Keys.
   The account is `NT Service\MSSQLSERVER` for a default instance.
2. In SQL Server Configuration Manager, under SQL Server Network
   Configuration, open the properties of "Protocols for" the instance and
   select the certificate on the Certificate tab.
3. Restart the SQL Server service.

`HMSSQL_TEST_CERT` needs PEM, which `certutil -encode` writes:

```powershell
Export-Certificate -Cert $cert -FilePath sqlserver.cer
certutil -encode sqlserver.cer sqlserver.crt
```

### Azure SQL

The suite tells Azure SQL Database apart by
`SERVERPROPERTY('EngineEdition')` (`testServerIsAzure`): the tests of what
it lacks are pending there, and the tests of what it does differently
expect that ([Writing tests](#writing-tests), and
[azure-sql.md](azure-sql.md) for what differs). Two scripts run it there,
from the developer's machine or from Azure Container Instances.

#### Native runs, including Windows without Docker

An existing, seeded Azure test database can be tested directly from the
developer's machine, without Docker or ACI. Keep `AZ_PREFIX` and
`AZ_SUBSCRIPTION` in `~/.hmssql-test-env`, sign in to the Azure CLI, and
put the SQL password in
`~/.config/hmssql-azure/<prefix>-hmssql-test.password` (or set
`HMSSQL_AZURE_STATE_DIR` or `AZ_SQL_PASSWORD`). The server's firewall must
allow the machine's public address; `allow-my-ip` adds a rule. Don't run
`setup` or `seed` again for a database another host prepared.

```sh
source ~/.hmssql-test-env
scripts/azure-sql-test.sh run-local --jobs 4
```

The LOGIN7 server-name matrix is opt-in, because it also needs native
IPv4 and IPv6 addresses for the Azure hostname. It checks omitted, short,
full and bogus names under both encryption modes, and reports a missing
address family as a failure of its own, not as coverage:

```sh
HMSSQL_TEST_AZURE_SERVER_NAME=1 scripts/azure-sql-test.sh run-local \
  --match Connection.AzureServerName --jobs 1
```

`run-local` builds a native executable with Stack unless `HMSSQL_TEST_EXE`
names one. For the cabal build on Windows ([On Windows](#on-windows)),
build it with `cabal build hmssql-tests --enable-tests` and the same
compiler, build directory and network constraint, and select it, rebuilding
after each edit of the Haskell sources:

```sh
export HMSSQL_TEST_EXE="$(cabal list-bin hmssql-tests --enable-tests \
  --with-compiler=ghc-9.12.4 --builddir=dist-newstyle/stock \
  --constraint='network < 3.3')"
scripts/azure-sql-test.sh run-local --jobs 4
```

On MSYS2's CLANG64 shell, put the Azure CLI's `wbin` directory on the
`PATH`, for the MSI installation:

```sh
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
```

The runner takes its connection settings from `scripts/azure-sql-test.sh
env`: TCP, strict encryption, the certificate validated against the
server's hostname and the system store, and the Azure database names and
scratch-database options. It clears a local PEM file, and overrides a
local plaintext, certificate-trust or strict-encryption setting. It sets
the TLS hostname to the Azure name explicitly, since GHC on Windows reads
an empty environment variable as unset, which would select the harness's
default, `localhost`. Other options, such as MARS and the slow tests,
remain configurable, and hspec arguments pass through unchanged,
leading-slash patterns included on MSYS2. The logs go in
`~/.config/hmssql-azure/logs/local-*.log`, and the command returns the
test's exit status. `env` prints shell-quoted exports that contain the
password: capture them with `eval "$(scripts/azure-sql-test.sh env)"`
rather than display them.

`run-local` uploads nothing, starts no container, changes no tier, and
doesn't run `seed`; the test executable's startup hook still checks the
fixtures and creates what is missing. Wait for any other run that must
finish first.

#### Runs in Azure Container Instances

`scripts/azure-sql-test.sh` runs the suite against an Azure SQL Database
from a container in Azure Container Instances in the same region, since
the round trip from a developer's machine is 10 to 50x longer, and an
application would run there anyway. It compiles the suite locally, on
Ubuntu 24.04 or a derivative so that the executable's glibc matches the
container's, and uploads it to an Azure Files share that a stock Ubuntu
24.04 container mounts; no Docker image is built. The script's header
lists its commands and its configuration (subscription, name prefix,
location and SKUs), which environment variables override:

```sh
scripts/azure-sql-test.sh setup        # resource group, SQL server, database, storage, share
scripts/azure-sql-test.sh check-local  # the built suite in the same image, with Docker
scripts/azure-sql-test.sh upload       # build and upload the suite
scripts/azure-sql-test.sh seed         # create the fixtures and the companion database before any real run
scripts/azure-sql-test.sh run          # the suite; hspec arguments and HMSSQL_TEST_* pass through
scripts/azure-sql-test.sh run --match Types
mapfile -t args < <(scripts/rerun-args.py ~/.config/hmssql-azure/logs/RUN.log)
scripts/azure-sql-test.sh run "${args[@]}"   # only what failed in RUN
scripts/azure-sql-test.sh teardown     # delete everything
```

The server's connection policy is Azure's default
(`AZ_SQL_CONNECTION_POLICY` changes it), which from inside Azure redirects
every login to the node hosting the database, so every connection of the
suite follows a redirect. The connections are what an application with
default TLS settings makes: strict encryption, and the certificate
validated against the host name and the system store only
(`HMSSQL_TEST_TLS_HOSTNAME` empty and no `HMSSQL_TEST_CERT`; the uploaded
CA bundle is the container's system store). The container gets
`HMSSQL_TEST_SERVER_NAME`, `HMSSQL_TEST_COMPANION_DATABASE`
(`AZ_SQL_COMPANION_DATABASE`, by default the test database's name with
`_companion` after it) and `HMSSQL_TEST_CREATE_DATABASE_OPTIONS` (Basic
edition for the databases the suite creates).

The suite creates the companion on its first run (`seed`) and keeps it,
at Basic's few dollars a month; `setup` leaves it to the suite, `status`
marks it, and `teardown` deletes it with everything else. `prune` drops
the scratch databases a failed run left behind: the names that start with
`hmssql` and end with `uniqueName`'s `_<run>_<time>_<n>`, never the test
database or the companion. `scale Basic` keeps the test database for a few
dollars a month between sessions; the suite runs against Basic with
`--jobs 4`, in over an hour ([azure-sql.md](azure-sql.md#the-basic-tier)).
A database is billed as long as it exists, and the container only while it
runs.

Much of a run's time is `CREATE DATABASE`, of which a run makes six
([azure-sql.md](azure-sql.md#scratch-databases)); the times and sizes by
tier are in [azure-sql.md](azure-sql.md#running-there). Since hspec reports items in the order of the tree, the log can
stand still for minutes behind an item waiting for its scratch database.
An "Uncaught exception" line comes from a thread a test forked and doesn't
end the run; the run is over when the log ends with `hmssql tests: exit
status N`. To try a test locally the way Azure reads, point
`HMSSQL_TEST_DATABASE` at a database with `READ_COMMITTED_SNAPSHOT` on.

The container defaults to 1 vCPU and 2 GB (`AZ_CONTAINER_CPU`,
`AZ_CONTAINER_MEMORY`). The runner gives the RTS one capability per CPU of
the container's quota, since `-N` alone counts the CPUs it sees (32
capabilities with `-A64m` is 2 GB of nursery). On 1 vCPU with the default
16 jobs, mock-server timing tests (`Concurrency.Attention` and
`Resources.CloseDuringSend`) sometimes fail; `--jobs 4` passes, as does a
bigger container (`AZ_CONTAINER_CPU=8 AZ_CONTAINER_MEMORY=16`).

`Connection.AccessToken` logs in with an Entra ID access token instead of
the SQL login, when `HMSSQL_TEST_ACCESS_TOKEN` holds one for the audience
`https://database.windows.net/` (from `az account get-access-token
--resource https://database.windows.net/`, as the server's Entra admin or
a user of the test database), and is pending without it. The
managed-identity path, where the token comes from the Azure host's
identity endpoint, is `scripts/azure-managed-identity.sh`: it builds
`examples/managed-identity` for Linux in ACI, creates a user-assigned
identity and its database user, and runs the example in a container that
has the identity ([azure-sql.md](azure-sql.md#entra-id-and-managed-identity)).

### Linux builds in Docker

The `Dockerfile` at the repository root builds one executable for Linux
and puts it in a stock Ubuntu image: a toolchain stage installs GHC and
cabal with ghcup (`scripts/linux-toolchain.sh`, `GHC_VERSION` selectable),
a build stage copies the working tree in (`.dockerignore` leaves the build
directories out) and runs `cabal build`, and the final stage has only the
executable, its shared libraries and a certificate store. `EXE` picks the
executable, `examples/managed-identity` by default:

```sh
docker build -t hmssql-example .
docker build --build-arg EXE=hmssql-example-crud -t hmssql-example-crud .
docker build --platform linux/amd64 ...    # on an Apple Silicon Mac, for Azure
```

`scripts/azure-managed-identity.sh build` runs the same toolchain script
and build in Azure Container Instances, which can't build images, so the
executable that runs there is built the same way whether or not Docker is
at hand.

## The test matrix

`scripts/test-matrix.sh` runs the suite under several configurations, on
every GHC version in `tested-with` and against SQL Server 2017, 2019, 2022
and 2025, with nothing but Docker. It creates a bridge network and a
container per SQL Server, whose certificate the server's own image
generates (for `localhost`, so that strict encryption validates as it does
locally, and for the container's name). It builds an image per GHC version
(Ubuntu 24.04 with ghcup, `scripts/linux-toolchain.sh`), keeps each
version's cabal store and build in a volume, seeds each server's databases
and fixtures with the GHC 9.10.3 build, and then runs the suite once per
GHC version, server and configuration, three at a time (`-j`) with 8 CPUs
and 16 GB each, the working tree mounted read-only. After each build it
checks the code size (`scripts/code-size.sh --quick --check`, [Code
size](#code-size)). Each step is skipped when its result exists, so a
later invocation goes straight to the runs and a code change rebuilds only
hmssql. The SA password, the certificates and the logs are under
`~/.config/hmssql-matrix`.

```sh
scripts/test-matrix.sh --prepare                   # servers, builds and seed, but no runs
scripts/test-matrix.sh                             # the default matrix on every GHC and server
scripts/test-matrix.sh --ghc 9.12.4 --sql 2025 on+p512 arithabort
scripts/test-matrix.sh --sql 2022 mars+slow        # the whole suite over MARS, on 2022
scripts/test-matrix.sh -j 2 --cpus 12 off -- --match Types
scripts/test-matrix.sh --rerun ~/.config/hmssql-matrix/logs/20261005-111153
```

A configuration is a `+`-separated list of an encryption, `p<N>` (packet
size), `arithabort`, `mars`, `w<N>` (MARS window) and `slow`, or
`default`. The default matrix is the fifteen configurations `-h` lists:
the default connection and MARS with the slow tests (`default+slow` and
`mars+slow`), and the other encryption modes, packet sizes and session
setups, alone and combined, without them. A slow run takes about half an
hour and the others a few minutes each, so the default matrix on six GHC
versions and four servers is an overnight run.

SQL Server 2017 and 2019 have no TDS 8.0, and SQL Server 2022 on Linux has
no strict encryption, so the script runs those three with `on` where a
configuration names no encryption, and skips the configurations that ask
for `strict`. On them `default` is `on`, so `on+p512` and `on+arithabort`
are `p512` and `arithabort`, and `mars+on` is `mars`: eleven distinct
configurations. The script sets `HMSSQL_TEST_SQL_VERSION` for every run.
The servers are the newest Linux images of each version: 2017 CU31 on
Ubuntu 18.04, 2019 CU32 on Ubuntu 20.04, 2022 CU27 on Ubuntu 22.04 and
2025 CU9 on Ubuntu 24.04. The 2017 image has `sqlcmd` in
`/opt/mssql-tools`, the others in `/opt/mssql-tools18`, and the script uses
whichever is there.

Six tests are pending in the matrix that `stack test` on the host runs:
the three that connect to a loopback address themselves, because the
server is on the Docker network, and the three `Security.Tls` tests that
connect to the certificate's name, `localhost`, with no
`tlsHostNameInCertificate`.

The runs of a GHC version alternate between the servers, which spreads
those going at once over them. Three runs at once on one server are more
than it serves without stalls: on SQL Server 2025 they brought 15 timeouts
of 30 to 180 s in four rounds, and on 2022 up to 27 in a round, where two
runs on 2025 brought one
([protocol-notes.md](protocol-notes.md#the-server-under-load)). In each
such timeout the test's report showed the client waiting for the server
and the server holding the request. A server that has served runs for a
day is best restarted (`--down`, then a new invocation): SQL Server 2022
failed requests with error 701 after about 20 hours of them, and SQL
Server 2025 twice in seven hours with three runs on it, two minutes into a
run with the slow tests each time.

The summary at the end lists every run's result with its failures. `--rerun
DIR` runs only the runs that did not pass in `DIR`, the log directory of
an earlier invocation, and `scripts/rerun-args.py` turns one run's log
into the `--match` arguments that rerun what failed in it. A run that ends
without a summary is listed with the test process's exit status: 137 is a
kill, by Docker when the container passed its memory limit (`docker events
--filter event=oom` shows it) or by hand. `--prepare` stops after the
builds and the seed, and `--status`, `--down` and `--purge` show and
remove what the script made.

Three things the script works around, which a maintainer of it should
know. `cabal update` run inside the read-only source mount tries to write
`dist-newstyle` there, so the script runs it from the cache directory.
cabal reorders separate `--ghc-options` arguments, so `+RTS -A64m -RTS`
must be one argument, together with `-j4`. And hpack writes `tested-with`
on the line after the field's name, which a script reading the field
must expect.

## Latest results

The newest run of each platform and server. "Pending" counts the tests a
configuration can't run there: the slow tests, the tests of a later
server's features, and those that need a certificate, a PEM file or an
access token the run didn't have.

| Platform and server | Date | Build | What ran | Result |
|---|---|---|---|---|
| Linux (x86-64), SQL Server 2025 in Docker | 2026-11-05 | GHC 9.12.4, `nightly-2026-11-03` | The default configuration | 5,991 examples, 0 failures, 70 pending |
| Linux, the matrix: SQL Server 2017 CU31, 2019 CU32, 2022 CU27 and 2025 CU9 | 2026-10-25 | GHC 9.6.6, 9.8.4, 9.10.3, 9.12.2, 9.12.4 and 9.14.1, cabal | The default matrix, 360 runs, four at a time | 326 passed. 33 failed only on timing under load, and one on a check to revisit |
| macOS, a local server | 2026-10-25 | GHC 9.12.4, `nightly-2026-09-27` | The default configuration | 3,584 examples, after one test fix (`withRefusingPort`) |
| Windows 10, SQL Server 2019 RTM | 2026-11-07 | GHC branch `wip/winio-completion-packets`, network master | The native manager: threaded with the mock on a pipe, over Shared Memory, Named Pipes, both with MARS, TCP, and TCP with MARS; not threaded the same, and `auto` with `localhost` | 15 runs of 5,999 examples, no failure, 300 to 375 s each |
| The same | 2026-11-07 | The same build, the default manager | Threaded over TCP, Shared Memory and Named Pipes; not threaded over TCP and the pipes | Passed threaded over all three (about 195 s each), and not threaded over TCP. Not threaded over the pipes, `Resources.ConnectTimeout`'s whole-process handle count failed in 3 runs of 6 |
| The same | 2026-11-06 | GHC 9.12.4, Stack | The default manager: threaded and not threaded over TCP; threaded over Named Pipes, Shared Memory, and TCP with MARS | 5,997 to 5,998 examples, 0 failures and 143 pending in each threaded run (189 s over TCP); not threaded, 144 pending in 336 s |
| The same | 2026-10-09 | GHC 9.12.4, Stack | `on`, `off`, `notsup`, `p512`, `p32767`, `arithabort`, `off+p512`, MARS, MARS with `off+p512`, MARS with `arithabort`, Shared Memory, Named Pipes, and Shared Memory with MARS; the slow tests once, over MARS | Passed. The slow run failed three tests: the server's stale plan, and `Model.Connection` twice |
| Windows, SQL Server 2025 (17.0.1145.4) | 2026-10-25 | Stock GHC 9.12.4 with cabal, network 3.2.9.0, tls 2.4.13 | `auto` (Shared Memory), `np` and `tcp`, each with `notsup`, a trusted certificate and the live strict tests off | 3,585 examples, 0 failures and 113 pending each, in about 175 s |
| The same | 2026-10-16 | GHC 9.12.4, Stack | Over TCP: strict, MARS, `notsup`, and `tcp` with `localhost`; `auto` with `localhost`; each pipe one test at a time; the slow tests twice over TCP | Passed (3,401 examples). The slow runs failed 3 and 2 tests, different ones, each passing alone |
| Azure SQL Database, S3 | 2026-10-26 | A native Windows client, stock GHC 9.12.4 | `run-local --jobs 4`, strict over TCP | 3,585 examples and one failure, a test since corrected ([azure-sql.md](azure-sql.md#native-windows-client-outside-azure)) |

The other Azure runs, by tier, policy and client, are in
[azure-sql.md](azure-sql.md).

With GHC 9.12.4 and network 3.2 on Windows, where network's path can't
hold, the pipes behaved as before on 2026-11-07: threaded under the
native manager the mock on a pipe passed and Shared Memory failed only the
server's stale plan; without `-threaded` under the native manager the
setup's first connect was refused, with a message saying what is needed;
and without `-threaded` under the default manager the same handle count
failed once, in the redirect sweep, and `Resources.CutHandshake`'s proxy
failed twice in network's `getAddrInfo` of `127.0.0.1` with
`WSAHOST_NOT_FOUND` (11001), as it did once with GHC master. Both are
checks to revisit.

### What the runs established

What the runs found that wasn't a defect of the library, and what
explains how a test is written or why a configuration needs a setting.

**The server.**

* SQL Server 2017 has no UTF-8 collations and doesn't acknowledge the
  UTF-8 feature extension: on 2026-10-14 it failed the same 32 tests in
  each of the eleven configurations, every one about UTF-8, which is why
  `HMSSQL_TEST_SQL_VERSION=2017` marks them pending. With that, the
  eleven passed: 3,380 examples, 150 pending. In `notsup+p32767` one more
  was pending, `LargeValueSpec`'s interruption late in a large value,
  which could not land its interruption before the value had arrived.
* SQL Server 2019 RTM's stale plan over `#temp` tables fails
  `Differential.Decode` in about one plaintext run in four, and with
  3,000 tables in the slow tests almost surely.
* Several runs on one server at once make it stall: the timeouts of the
  matrix were the server's, and the matrix alternates servers and wants
  them restarted after a day ([The test matrix](#the-test-matrix)).
* On a MARS connection, a `SET` beside a running stream is undone when the
  stream ends, which the documents had wrong until the matrix of
  2026-10-05 ([protocol-notes.md](protocol-notes.md#mars-and-smp)).

**Tests that assumed a timing.** The rule that came of them is that two
parties signal each other through `MVar`s and never by sleeping ([Writing
tests](#writing-tests)).

* The matrix of 2026-10-05 found ten such tests and one defect of the
  library, on GHC 9.14.1 only: a row decoded as `SqlRow` cost 8 n² bytes
  ([bugs-found.md](bugs-found.md#in-the-test-suite)). `MarsTx.Snapshot`
  wanted two writers to out-commit its reader, and on that machine a
  commit waits 5 ms for the disk, so the reader was through its 30 runs in
  the time of 14 commits; the test waits for a committed change inside
  each read.
* The matrix of 2026-10-25, after the round of connection and
  interruption tests, found four defects of the new tests and none of the
  library ([bugs-found.md](bugs-found.md#in-the-test-suite)).
  `Concurrency.CancelModel` closed a socket under its own reader, which
  wedged a bucket of GHC's I/O manager and hung `Connection.Lifecycle`'s
  "many connections" for hours on 2017, 2019 and 2022. Its window poller
  outlived its case and made `Resources.StalledServer` see megabytes
  allocated. `Concurrency.Boundary` and the model's lost batch assumed a
  timing.
* The 33 runs of 2026-10-25 that failed only on timing under load were
  `Protocol.Fuzz` with its responses in one-byte packets (most of them,
  as on 2026-10-05, when it took over 5 s under load), `Model.Connection`'s
  `FHang` at 512-byte packets (seven), a cancel right behind its request
  on SQL Server 2025
  ([protocol-notes.md](protocol-notes.md#the-server-under-load), two),
  and one each of `Security.Dos`, `Mars.AttentionWindow`, `LargeValue`,
  `Concurrency.Cancel` and `Review.Cumulative2`'s interrupted send. Those
  runs were before the reader recipes replaced the row walk, so whether
  `Protocol.Fuzz` is still slow in one-byte packets is for the next
  matrix to say.
* In the matrix of 2026-10-05, one run with the slow tests had a request
  unanswered for 15 s while SQL Server reported its I/O completion
  listener as not yielding
  ([protocol-notes.md](protocol-notes.md#the-server-under-load)), and one
  test process was killed at 16 GB
  ([backlog.md](backlog.md#before-the-release)).

**Windows.**

* The 23 failures over Named Pipes on 2026-11-06, each a MARS connection
  over a pipe without encryption, were hmssql's: the SMP header went to
  the pipe as a write of its own, and the server, which reads a pipe a
  write at a time, dropped a MARS connection whose SMP packet came in two
  writes. A plaintext SMP packet is one write on a pipe now
  ([bugs-found.md](bugs-found.md#platform), and
  [windows-research.md](windows-research.md#how-the-server-wants-writes-split)). The rules of [How the tests
  are written for Windows](#how-the-tests-are-written-for-windows) came
  from the rest.
* The slow tests over TCP on 2026-10-16 failed 3 and 2 examples in two
  runs of 35 and 53 minutes, each passing alone with its seed:
  `Robustness`' killed consumer in both, `Protocol.Fuzz`'s 5 s hang
  watchdog twice in the first, and `Model.Connection` at 5,000 sequences
  once in the second. A failure of these on Windows is rerun alone before
  it is believed, as a group over a pipe is.
* On SQL Server 2019 RTM over MARS with the slow tests (52 minutes), the
  two `Model.Connection` properties at 5,000 sequences failed after 1,196
  and 998 of them, each at a `Waitfor` that ran its ten seconds where the
  model has it interrupted once the server shows it waiting. The
  interrupter polls with `threadDelay`, so a stall of the process's timers
  would do that; that is a supposition, not a measurement.
* Before the manager's fixes, three runs over MARS of four under the
  native manager ended in the manager's known crash within a minute, and
  the non-threaded runtime froze before its first test. With the GHC
  branch, 21 threaded runs, 12 of them over MARS, had no crash or hang.

## Checks to revisit

The unexplained failures, each with what was seen and what would settle
it, are in [backlog.md](backlog.md#checks-to-revisit). What follows is
what hasn't been run since a change that could matter, or never:

* **Linux and macOS since 2026-11-05.** The Windows work of 2026-11-06 and
  07 changed `backendSendMany` on every platform, and the suite has not
  run on Linux or macOS since. macOS last ran on 2026-10-25, on the
  previous Stack snapshot.
* **The test matrix since 2026-10-25.** The value-streaming rewrite and
  the two optimization runs came after it, and the rewrite replaced the
  code the matrix's timing failures went through.
* **SQL Server 2019 CU32 in plaintext**, more runs, to see whether RTM's
  stale plans are gone ([backlog.md](backlog.md#before-the-release)).
* **Windows:** the slow tests over the pipes and over MARS; the matrix's
  packet sizes and `arithabort` against SQL Server 2025; the scripts
  (`test-matrix.sh` and the Azure ones), which have not run there; and a
  named instance, a pipe on another machine, and TCP to a server on
  another machine.
* **The native I/O manager with a released GHC.** The runs used GHC
  master with the manager's fixes on a branch; the minimum GHC to name is
  the first release that has them
  ([backlog.md](backlog.md#before-the-release)).
* **Azure SQL Database** since 2026-10-26, and the six-database run there
  untimed.

## Writing tests

`hmssql-tests/TestDb.hs` has the helpers for live tests, and re-exports
`hmssql-tests/TestConfig.hs`, which has the connection settings:

* `withTestDb :: (Connection -> IO a) -> IO a` connects to the shared
  database with the configured defaults (`defaultTestConnectInfo` has its
  settings; `withTestConnection` and `testConnectInfo` take an explicit
  `Encryption`). `withTestDbWith f` changes settings a test depends on
  (for example `\ci -> ci { connectSessionSetup = [] }`), and
  `testEncryption`, `testPacketSize`, `testSessionSetup` and
  `testSessionSetupArithabort` return the configuration.
* `withFixture :: Text -> [Text] -> SpecWith a -> SpecWith a` declares a
  named fixture (a list of SQL batches) that the spec needs. Before any
  test runs, `hmssql-tests/SpecHook.hs` creates the shared database if it is
  missing and applies every declared fixture that is missing or whose text
  changed, each in one transaction (applied fixtures are recorded in
  `dbo._hmssql_fixtures`), so no test waits for that setup. Write the
  batches to be re-runnable (`DROP TABLE IF EXISTS` first).
* `companionConnectInfo :: IO ConnectInfo` connects to the companion
  database, for a test that needs a second database (`USE`, three-part
  names) or one that allows SNAPSHOT isolation, which the shared database
  doesn't. Like the shared database, the hook creates it if it is missing
  (`ensureCompanionDatabase`, which also turns `ALLOW_SNAPSHOT_ISOLATION`
  on if it is off), and it is kept. Concurrent runs share it, so what a
  test creates there has a unique name.
* `withScratchSchema :: ConnectInfo -> Text -> (Text -> IO a) -> IO a`
  creates a schema `<prefix>_<unique>` in the database the settings name
  (the shared one or the companion) and drops it afterwards with
  everything in it (`dropSchema`: system versioning off, then foreign
  keys, views, procedures, tables, functions, types and XML schema
  collections). It is for a test that wants its objects apart: a temporal
  table, a typed XML column, or a catalog to read. `withSchema ci name`
  does the same for a name the spec chose while its tree was built
  (`runIO (uniqueName "txn")`), so that an `aroundAll` can create it and
  the tests name its objects.
* `retryDeadlock :: IO a -> IO a` runs an action again (up to five tries)
  when the server picks it as a deadlock victim (1205): DDL in the shared
  database, or a read of its catalog, beside other tests' DDL. The action
  must be safe to repeat.
* `sessionIdentity :: Connection -> IO SessionIdentity` records a
  session's id and its physical connection's `connection_id`, and
  `killSession` (or `killSessionFrom killer`) `KILL`s it only while both
  still match, failing with error 50001 and killing nothing otherwise.
  Every test that kills a session goes through it: an ended session's id
  goes to the next session, which may be another test's or the killer's
  own.
* `withScratchDatabase :: Text -> (ConnectInfo -> IO a) -> IO a` creates a
  database `hmssql_test_<suffix>_<unique>` and drops it afterwards. It is
  only for a test that changes the database itself (its collation, say) or
  tests the harness: on Azure SQL a create takes 25 to 60 s.
* `uniqueName :: Text -> IO Text` makes names for real tables that don't
  collide with concurrent runs (prefer `#temp` tables where possible).
* `slow :: SpecWith a -> SpecWith a` marks tests pending unless
  `HMSSQL_TEST_SLOW=1`.
* `skipOnAzure what`, `skipIfEncryptionRequired` and
  `skipUnlessLoopbackHost` mark tests pending on a server that can't run
  them (Azure SQL Database, one that refuses plaintext connections, or one
  that isn't on this machine), from `testServerIsAzure`,
  `testServerRequiresEncryption` and `testHostIsLoopback`, which ask the
  server once per process; `skipWhen cond reason` is the general form. A
  test whose expectation differs on Azure asks `testServerIsAzure` itself
  (see [azure-sql.md](azure-sql.md) for what differs).
* `serial :: SpecWith a -> SpecWith a` marks tests that must run alone
  ([Parallel and serial tests](#parallel-and-serial-tests)).
* `withCases n` and `withCasesSlow fast slow` set the number of cases of
  the hedgehog properties in a spec ([Property cases](#property-cases));
  `fastOrSlow fast slow` returns `slow` with `HMSSQL_TEST_SLOW=1`, and
  `fast` otherwise, for the length of a loop.

```haskell
spec :: Spec
spec = withFixture "decimal_values" fixture $ around withTestDb $ do
  it "reads the fixture" $ \conn ->
    query conn "SELECT v FROM dbo.decimal_values" `shouldReturn` [Only (1.5 :: Decimal)]
  slow $ it "takes a while" $ \conn -> ...
  where
    fixture =
      [ "DROP TABLE IF EXISTS dbo.decimal_values"
      , "CREATE TABLE dbo.decimal_values (v decimal(10, 2))"
      , "INSERT INTO dbo.decimal_values VALUES (1.5)"
      ]
```

`hmssql-tests/MockServer.hs` is a scriptable TDS server for injecting arbitrary
responses (with TCP_NODELAY, half-close, abortive reset and an in-process
TLS server with a throwaway key), and `hmssql-tests/Concurrency/Harness.hs` has
the interruption helpers and `knownBug`. The strict-TLS mock in
`Security.Tls` sets TCP_NODELAY too: without it, Nagle's algorithm held
back the later records of the mock's TLS 1.3 flight until the client's
ACK, and `Resources.CutHandshake`'s sweep took four times as long. A mock
that writes a handshake flight as several records needs the option for
the same reason. Live tests share the database
`hmssql_test`: fixtures are declared with `withFixture` and seeded before
the tests run, and writes go to `#temp` tables, `uniqueName` tables or a
`withScratchSchema`. A test that needs a second database, or SNAPSHOT
isolation, uses the companion database, and only a test that changes the
database itself uses `withScratchDatabase`. A whole run creates 8
databases locally (`Connection.Database`'s six odd names, `Harness` and
`Types.CodePage`), and 5 on Azure SQL, where the offline and single-user
tests are pending and Azure refuses the name with a character outside the
BMP (error 1055); see
[azure-sql.md](azure-sql.md#scratch-databases).

Conventions from the development rounds, worth keeping:

* A test that exposes a bug is marked `pendingWith "BUG: ..."` (or wrapped
  in `knownBug`), never weakened; a conditional pending for behaviour that
  works is turned into a hard assertion.
* A scenario that becomes unsupported keeps its test, which then states
  the consequence (for example, that the connection is broken with
  `ConnectionBroken` carrying the interruption).
* A flake is fixed at its cause, in the test or the library, not by
  retrying.
* Tests that count outcomes of a nondeterministic scenario (interruptions
  that may or may not land in a blocked send) print the counts, so a
  change in the cost of a rule shows up in the output.
* Two parties that must take turns (a client and the mock server, a
  consumer and an interrupter) signal each other through `MVar`s, never by
  sleeping: under load a sleep of any length runs past the other side.
  The mock server's `collectFor` counts receive steps, not wall time.
* A test that needs a send to block clamps the socket buffers; a test
  that needs a read to outlast a timeout reads enough rows to outlast it
  on any machine (an optimisation can invalidate a timing premise).
* Before a run of the whole suite counts as passing, run it beside a load
  (the flakes of 2026-09-29 appeared only beside 28 busy processes) and
  with `+RTS -A64k` or `-A1m`, which brings GC-timing bugs forward.
* A test of reading cuts every delimiter, the NBCROW bitmap included, at
  every byte, at packet sizes 512 and 8000, and tests each read
  function. A row can end exactly at a packet's end, and a reader that
  asks for a byte before it knows a delimiter needs one waits for a packet
  that may never come, or after an Attention turns that into a
  `ProtocolError`. That, and the next rule, are lessons of the two
  attempts at value streaming rejected before the reader recipes
  ([value-streaming-research.md](value-streaming-research.md#what-the-earlier-attempts-taught)).
* A test that interrupts a streaming consumer sends a value longer than
  `streamWholeLimit`. A value of at most 64 KiB is read whole before its
  consumer runs, so an interruption meant to land in the consumer's pulls
  needs a longer one (`Concurrency.ValueConsumer`).
* A retention bug may show only in a slow test: a last-value slot in a
  reader kept two rows' values alive, 271 MB against
  `Scale.HugeBinary`'s 201 MB limit, in a test that only
  `HMSSQL_TEST_SLOW=1` runs. A change to how values are held is run with
  the slow tests.
* A test that can hang says where when it times out. `withinTraced`
  (`Mars.Harness`, `withinTracedOn` for a test of one connection) bounds
  a MARS test by its time without progress on the connection (no DATA
  packet sent or received and no window raised), with ten times that as
  a backstop: a loaded server can serve a connection slowly for minutes,
  and a test of what MARS does, not of how fast, rides that out and says
  so on stderr. It reports the step it was at and for how long
  (`markStep`, with the step's start by the wall clock), a look taken 2 s
  before the limit, and one after. A look has the thread's status, the
  client's view of a MARS connection (`describeMars`: the mutex owner,
  the send lock, gathered TLS records, the socket's kernel queues, the
  reader thread, and each session's response and SMP counters), the
  server's view of the session (`describeSession`: its waits and since
  when, blockers, locks, each SMP session's reads and writes, and the
  whole server's requests by wait and its schedulers' queues), and how
  long the look took to connect and answer. The `Model` runner prints
  the same for an operation with no answer in 15 s, and a
  `Protocol.Fuzz` case that outlives its timeout prints its packets and
  ends the process. `describeSession` waits at most a second for a lock
  and names no tempdb object: a name lookup waiting on a lock the session
  held kept the test that would have released it waiting.

Test modules build as Haskell2010 with the suite's `default-extensions`
(`hmssql-tests/package.yaml`), without `DerivingStrategies`, `RankNTypes` or
`ExistentialQuantification`, so a test that uses one has a pragma of its
own. An `hpack` on the `PATH` older than the one that generated a
package's `.cabal` file makes `stack build` regenerate the file. The rules for
working in `hmssql-tests/`, such as how to reproduce load and how to triage a
hang, are in `hmssql-tests/CLAUDE.md`.

### Parallel and serial tests

`hmssql-tests/SpecHook.hs` (applied to the whole suite by hspec-discover) runs
every spec item in parallel with others, up to `--jobs` at a time
(`defaultJobs`: 16, or 4 without `-threaded`; live tests mostly wait for
the server, so more than the number of cores pays off). Items marked
serial run afterwards, one at a time, with nothing else running: hspec
starts a non-parallel item only when its report reaches it, so the hook
moves the serial items after all the parallel ones. The report therefore
lists the parallel items first and the serial ones at the end (a module
with both appears twice); `--match` paths don't change. `-j1` runs
everything one item at a time.

Parallel is the default, so a new module needs nothing as long as its
tests keep to themselves, as they must anyway for concurrent runs from
other worktrees: `#temp` tables, `uniqueName` objects, scratch schemas and
databases, their own connections, and sessions found by a unique
application name. Mark tests serial when they measure something other
tests running at the same time would disturb:

* wall-clock bounds or timing ratios ("returns within 1 s", "4x the bytes
  takes well under 16x the time");
* allocation, residency or the live heap (the RTS counters, such as
  `allocated_bytes` and `max_live_bytes`, are process-wide), and thread or
  file-descriptor counts.

A whole module goes in `serialModules` in `hmssql-tests/SpecHook.hs`, by its
hspec-discover name (`"Scale.HugeBinary"`, or `"Resources."` for
everything under `hmssql-tests/Resources/`); a name that matches no module is an
error. A few items of an otherwise parallel module get `serial` (hspec's
`sequential`) from `TestDb`:

```haskell
serial $ it "reading 4x the bytes takes well under 16x the time" $ \conn -> ...
```

A group with an `aroundAll` or `afterAll` hook runs as a whole: if any
item in it is serial, all of it is. Its items still run in parallel with
each other, so whatever a `beforeAll` or `aroundAll` hook hands them (a
connection, or a table the test assumes it owns) is used by several at
once; use `around` to give each item its own. `startFirst` in
`hmssql-tests/SpecHook.hs` lists modules with long items (the `Model` tests),
which start before the other parallel items so that they don't finish
last.

Making the suite parallel took the fast suite from 350 s to 65 s, a test
rebuild from 73 s to 12 s (the test suite at `-O0`), and a no-server run from 1483
failures in 77 s to 0 failures in 5 s, at about 2,900 examples.

### Property cases

Properties use hspec-hedgehog, which takes the number of cases from hspec
(hedgehog's own `withTests` is ignored there). `withCases n` sets it for
the properties in a spec; `withCasesSlow fast slow` runs `fast` cases in
the fast suite and `slow` with `HMSSQL_TEST_SLOW=1`, for properties worth
more cases than the fast suite can afford. `HMSSQL_TEST_PROPERTY_SCALE`
multiplies both, and hspec's default of 100 for properties that set
nothing: `0.2` for a quick run while working on something else, and `10`
for a soak run.

```sh
HMSSQL_TEST_PROPERTY_SCALE=10 stack test --test-arguments '--match Wire'
```

A property that talks to the server runs through `liveHedgehog`
(`hmssql-tests/LiveProperty.hs`) in place of hspec-hedgehog's `hedgehog`: the same
runner, which also stops shrinking once 1000 smaller cases in a row have
passed. Hedgehog's shrink limit counts accepted shrinks only, so a case
that failed for a reason outside it (the server refusing a request for a
while) had it try every smaller case, keeping each in memory: for a random
table, tens of thousands of round trips and gigabytes
([bugs-found.md](bugs-found.md#in-the-test-suite)).

A test of shrinking needs a property with one minimal failing case.
`LivePropertySpec`'s "shrinks a failure the case causes" first asked for
a list summing to 500 or more to shrink to `[500]`, and failed with the
seed that shrank it to `[286, 214]`: dropping either element passes, and
so does making either one smaller, so hedgehog stops at that local
minimum. Its property is a single number, whose smallest failing value
(500) hedgehog reaches exactly, and the test reads the value from the last
case to fail rather than from the report, which quotes the source lines
around the failure.

## Benchmarks

`hmssql-bench/` is a [tasty-bench](https://hackage.haskell.org/package/tasty-bench)
suite, one module per area under `hmssql-bench/Bench/`, each exporting a
`Benchmark` (or `IO [Benchmark]` when it needs a resource) that
`hmssql-bench/Main.hs` lists. The top-level groups:

| Group (`$2`) | Module | Needs | What it measures |
|---|---|---|---|
| `Sql` | `Bench.Sql` | nothing | Composing a `Query` with `<>` in every association, `mkQuery` lexing, and rendering |
| `Decode` | `Bench.Decode` | nothing | The reader recipes and row decoders on synthetic responses (`Bench.Tokens`), split into 4096-byte packets' payloads and parsed as the connection parses them. Per dataset: `tokens` and `rows`, the raw values through the same recipe (two names kept so that results compare with older runs), `typed` (the dataset's `RowDecoder`), and `SqlRow`. `Decode.text` decodes single strings from UTF-16 (ASCII, Latin, CJK, emoji and ill-formed) and code page 1252 |
| `Encode` | `Bench.Encode` | nothing | A `Query` to the packets sent (`queryRequestFor`, the RPC body and the framing): 1, 100 and 2000 parameters, mixed types, a composed 300-parameter `INSERT`, 100 and 1000 one-row `INSERT`s as `executeStatements` messages, 100- and 1000-row bulk-load messages framed, 4 MB and 1M-character parameters, a 1M-character batch, and framing 4 MB at two packet sizes |
| `Mock` | `Bench.Mock` | nothing | The whole client against an in-process mock server on 127.0.0.1 (plaintext) that answers every request with the same canned response: round trips, connect and close, the `Decode` datasets through `query`, `queryS`, `queryFold` and `queryMulti`, and an output parameter (`int`, and 4 MB `varbinary(max)` and `nvarchar(max)`) through `callProcedure` |
| `Live` | `Bench.Live` | a server | Round trips, the `Decode` datasets read from `#temp` tables, 1, 100 and 2000 parameters, 4 MB parameters and output parameters, inserts of 100, 1000 and 10000 rows (one statement; one per row, alone or in a transaction; `executeStatements`, `executeMany` and `bulkInsert`), cancelling a stream, `withTransaction`, `reset`, `release` (idle, and with a transaction open, which it resets at once), and connect and close (TLS login) |
| `Mars` | `Bench.Mars` | a server | A MARS connection beside a plain one on the same work, with tasty-bench's ratio to the plain one on each MARS line: a `SELECT 1` round trip, one stream of 10,000 and of 200,000 `(Int32, Text)` rows, four streams of 50,000 rows (round-robin on MARS, one after another on both), a 1 MB and a 4 MB `varbinary(max)` parameter, nested N+1 (a 1,000-row stream with a `query1` per row, against the list read first), and `connectMarsWindow` 4, 16, 64 and 256 for the one-stream case |

The datasets (`Bench.Tokens.datasets`) have the same names in `Decode`,
`Mock` and `Live`'s `query` group, so one result set can be followed from
the parser to the socket to the server: `int bigint x10000`,
`nvarchar(50) x10000`, `nvarchar(50) CJK x10000`, `nvarchar(1000) x1000`,
`varchar(100) cp1252 x10000`, `varchar(100) utf8 x10000`, `decimal(18,4)
x10000`, `datetime2 datetimeoffset x10000`, `uniqueidentifier x10000`,
`nvarchar(max) short x10000`, `varbinary(max) 4MB x1`, `nvarchar(max) 4MB
x1`, `nullable half NULL NBCROW x10000` (and `nullable no NULL ROW
x10000`; in `Live`, `nullable half NULL x10000`, where the server picks the
token), and `50 columns x1000`. `Decode` and `Mock` also read the `max`
columns through a consumer (`nvarchar(max) short streamed x10000`,
`varbinary(max) short streamed x10000` and the `4MB streamed x1` pair,
each keeping every chunk, beside `varbinary(max) short x10000`) and
through a pure fold written as a `StreamingCell` (`varbinary(max) short
folded x10000` and `4MB folded x1`), which are the measurements behind
`streamWholeLimit` in [design.md](design.md#decoding). `50 columns
byColumn x1000` reads `50 columns x1000`'s row with each column's decoder
chosen by its type.

`Live` and `Mars` connect with the same `HMSSQL_TEST_*` variables as the
tests and are skipped with a note when `HMSSQL_TEST_PASSWORD` is unset.
Each of their groups has its own connections, which create the `#temp`
tables they read, so nothing is left on the server. A full run takes
about a minute and a half for `Live` and about two minutes for `Mars`.

`Live` and `Mars` are measured by the clock, whatever `--time-mode` says
(`hmssql-bench/Main.hs` sets it for the two groups). Their requests mostly wait
for the server, and what a MARS connection changes (an SMP header on
every packet, and acknowledgements the server waits for) shows up as
waiting as much as computing. CPU time also breaks tasty-bench's timeout
there: it plans its iterations within the timeout by the time it
measures, the client's CPU time was about a third of what a run took, and
`Live`'s `100 int params` was killed as a `TIMEOUT` in 3 runs of 4
(2026-10-04, on both sides of a comparison). `Mars`'s module header has
the numbers from the machine it was written on, with their spread; `-p
Mars` reproduces them.

```sh
stack bench                                             # everything
stack bench --benchmark-arguments '-p "$2 == \"Decode\""'      # one group
stack bench --benchmark-arguments '-p "/nvarchar(50) x10000/"'  # one dataset, every group
stack bench --benchmark-arguments '-p /Encode.request/'         # a subgroup
stack bench --benchmark-arguments '-l'                  # list the names
stack bench --benchmark-arguments '--csv before.csv'    # record a baseline
stack bench --benchmark-arguments '--baseline before.csv --fail-if-slower 10'
```

Stack hands the arguments to Cabal, which splits them at spaces outside
double quotes, hence the quoting. After a `stack build --bench
--no-run-benchmarks`, the executable can also be run directly, with
ordinary shell quoting and without Stack's checks:
`hmssql-bench/$(stack path --dist-dir)/build/hmssql-bench/hmssql-bench -p '$2 == "Mock"'`.
Don't pipe `stack bench` through `head`, because SIGPIPE kills the run.

A pattern like `-p Sql` (or `-p /Sql/`) is a substring match on the whole
dotted name, not a regular expression (`All.Live.decode 10000
rows.SqlRow with queryMulti` matches too), so select a group by its
field: the fields of `All.Decode.int bigint x10000.typed` are `$1` to
`$4`, and in `Mock` and `Live` the dataset is `$4`, under `query`. The
`--baseline` form compares against the recorded run (only the benchmarks
the pattern selects) and fails on a regression of more than 10%; `--stdev
2` asks for tighter measurements when a result looks noisy. The benchmark
executable runs with `+RTS -T`, so each result also reports the bytes
allocated and copied, and the CSV records them. Each benchmark stops
refining after 30 seconds (`--timeout` replaces that; a benchmark that
can't stop in time is reported as `TIMEOUT`, a failure).

tasty-bench measures CPU time by default, which for `Mock` is the whole
process's: the reader threads and the mock server's threads. Add
`--time-mode wall` to measure latency instead. `Mock`'s `connect+close
plaintext` closes its connections with a reset (a linger time of zero, set
through `ProtocolCustom`): closed in the ordinary way, each socket kept
its port in TIME_WAIT, and in the wall-clock mode the benchmark used up
macOS's 16,384 ephemeral ports in about a second, after which every
connect of the group failed with "Can't assign requested address".

To add a benchmark: `bench "name" (nf f x)` for a pure function whose
result is fully evaluated, `whnf` where forcing the result's spine is the
point, and `nfIO` or `whnfIO` for actions. Prepare inputs with `env`, so
that building them isn't measured (a resource without an `NFData`
instance gets a newtype whose `rnf` forces what matters, as
`Bench.Sql.Pieces` and `Bench.Live.Conn` do). A benchmark that guards
against a regression already fixed says so in its module comment, with
the numbers it replaced. Keep the cases and datasets stable when changing
their runner, so that the results stay comparable.

### Measuring a change

Timings on a development machine are shared, so compare runs, not
absolute numbers, and decide on the comparison of two saved binaries:

* **Keep builds and the test suite out of timing runs.** Build both
  binaries first, copy them aside, and time with nothing else running.
  Builds and fixed-work probes can run beside each other, but not beside
  a timing.
* **Run them in ABAB order**, the baseline and the candidate alternating,
  two rounds or more, with the same RTS options: `+RTS -N1`, since the
  executable's default `-N -A64m` makes the `Mock` and `Live` results
  vary up to twice between runs on a many-core machine (parallel
  collections over every capability). 10% is within the noise of a
  single pair. `scripts/bench-compare.py` does this.
* **Read time beside allocation and code size.** A case can move by 10%
  to 25% in time with its code and allocation unchanged, and a change that
  inlines more can multiply the code of every module that names a row
  type ([Code size](#code-size)).
* **Changes that help separately may interact when combined**, so measure
  the combination before keeping it.

[design.md](design.md#rts-options) has the suite's numbers under several
RTS settings, and [performance-research.md](performance-research.md) the
optimization runs measured this way.

### Comparing two commits

`scripts/perf-compare.sh BASE-COMMIT` compares the working tree with an
earlier commit, the code size first and then the speed. It builds the
earlier commit in a temporary worktree under the user's cache directory
(`$XDG_CACHE_HOME/hmssql/perf-compare`, by default under `~/.cache`),
where its benchmark binary and its sizes stay by commit, so that a second
comparison against it builds only the working tree. Then, with nothing
building, it measures:

* the code size of both, with `scripts/code-size.sh --repo`, and the
  `.text` of the library's objects compiled from `hmssql/src/`;
* the time and allocation of the groups that need no server (`Decode`,
  `Mock`, `Encode` and `Sql`), with `scripts/bench-compare.py`, which runs
  the two binaries alternately, pinned to one CPU, and takes each case's
  median ratio over the pairs.

It prints a summary, ratios below 1 being better, and keeps the CSVs in a
directory under the cache. It runs five pairs by default, because the 4 MB
cases are bimodal, and took 5 minutes on 2026-11-04 with both builds;
`--quick` measures 12 records and times one pair. The timing is only
meaningful on an idle machine, and even then a case can move by 10% to 25%
with its code and allocation unchanged, so read the groups, and a case
only beside its allocation. `Decode.int bigint x10000.typed` was bimodal
in one binary, at about 500 and 800 µs on 2026-11-04, and a run of it
alone can land on either.

When new benchmark cases are added, `--baseline-bench BINARY` supplies the
baseline library built with the same expanded harness. It changes only
the timing executable: the code size still comes from the base commit,
and the supplied binary is copied into the result directory. Record how
that binary was built, and check that its library sources are the base
commit's. `bench-compare.py --live` keeps the server's password in the
environment for live comparisons; by default it drops it, so that only
the groups needing no server run.

On Windows the script runs from Git Bash, with the tools it needs from an
MSYS2 installation on the `PATH`: `python3` and `size` from its
`clang64/bin`, before Git's own directories (Git for Windows has
neither), and `taskset` from its `usr/bin`, after them, so that none of
Git's tools is shadowed. MSYS2's `taskset` does pin the native benchmark
process. The script copes with the rest: `cp` adds the `.exe` to the
binaries it copies, and the backslashes of `stack path --dist-dir` are
turned into slashes. On 2026-11-06 one run of a benchmark binary took
about 7.5 minutes there, so five pairs take more than an hour.

### Code size

`scripts/code-size.sh` measures what hmssql adds to an application with
many records. It generates 50 records (three of 60 to 80 fields and the
rest 10 to 30, 1,187 fields of ten types, a third of them `Maybe`) with
derived `FromSqlRow` and `ToSqlRow`, compiles them at `-O1` against the
hmssql built in the working tree, and prints the `.text` size of each
module, the bytes per field and the compile time. `--quick` compiles 12
of the records (393 fields) for iterating. Typed decoders are inlined into
the module that names their row type, so this is where a change to the
decoders shows its cost in code; the benchmark binary shows it only for
the few row types in `Bench.Tokens`.

`--check` enforces a budget of 100 bytes per field on both generated
codec modules, which [the test matrix](#the-test-matrix) runs after each
build; `HMSSQL_CODE_SIZE_FIELD_LIMIT` changes the budget, and a run with
it at 1 shows that exceeding it fails. For a cabal build, `--cabal-builddir
DIRECTORY --compiler PATH` uses that compiler's exact package environment
rather than whichever installed version of a dependency the name selects.
All text sections are counted, split sections included.

On 2026-11-04, GHC 9.12.4, before and after the optimization run of that
day ([performance-research.md](performance-research.md)):

| Program | `FromRows` | Per field | Compile | `ToRows` | Per field | Compile |
|---|---:|---:|---:|---:|---:|---:|
| Before, full (1,187 fields) | 29,939,740 bytes | 25,223 | 617 s | 583,373 bytes | 491 | 4.3 s |
| Before, `--quick` (393 fields) | 9,941,572 bytes | 25,297 | 215 s | 203,861 bytes | 519 | 1.8 s |
| After, full | 79,088 bytes | 67 | 1.2 s | 83,813 bytes | 71 | 0.9 s |
| After, `--quick` | 25,872 bytes | 66 | 0.6 s | 28,965 bytes | 74 | 0.5 s |

After the run the library's own `.text` was 2,264,119 bytes, and the
records' own code (`Records.o`, their `Generic` instances included)
442,542 bytes for the full program, 373 per field, more than the decoders
and encoders together.

Other scripts attribute code and memory more finely:

* `scripts/api-code-size.sh DIRECTORY` measures forty distinct call sites
  of each API.
* `scripts/link-size.sh DIRECTORY` links a small consumer and keeps its
  GNU link map, and `link-map-size.py` attributes it by package.
* `code-owners.py` and `code-inner.py` attribute local closures from final
  STG dumps and objects built with `-fexpose-internal-symbols`; their
  headers describe the dump layout they need, and local symbols they
  can't find are reported as unowned bytes.
* `scripts/resource-probe.sh DIRECTORY` builds a fixed-work probe of the
  decoders' allocation and residency, apart from adaptive timing. Its
  executable takes a dataset name and an iteration count, and runs with
  `+RTS -T -N1 -A4m`. Use the same benchmark fixture sources on both sides
  (`--bench-dir DIRECTORY`) when the benchmark list changed. The encoding,
  query and live bulk probes under `scripts/` work the same way. Their
  results tell allocated bytes, the live heap, the RTS's memory and the
  process's RSS apart, which are different quantities and not to be
  substituted for one another. Where `perf` isn't permitted
  (`perf_event_paranoid` 4), Callgrind (Valgrind 3.22.0) runs the probes;
  its counts cover the whole process, setup and warm-up included, so
  compare two runs rather than reading a cost per row.

### Where a benchmark allocates: ticky

A ticky build counts, for every closure, how often it was entered and how
much it allocated. Build it in a work directory of its own, so that the
ordinary build is untouched:

```sh
stack build --work-dir .stack-work-ticky --bench --no-run-benchmarks \
  --ghc-options='-ticky -ticky-allocd' hmssql-bench:bench:hmssql-bench
```

Then run one case with enough iterations that its own allocation
outweighs building its dataset, and divide by the iterations (the entries
of a closure that runs once per row give them):

```sh
hmssql-bench/.stack-work-ticky/dist/x86_64-linux/ghc-9.12.4/build/hmssql-bench/hmssql-bench \
  -p '$0 == "All.Mock.query.int bigint x10000.typed"' --stdev 5 \
  +RTS -N1 -rticky.out -RTS
```

With `--stdev Infinity` the case runs once, and the dataset is most of
what the profile shows. Over many iterations, ticky's total matched the
benchmark's own allocation figure to within 10% on 2026-11-03.

A closure's name means something only beside the STG of its module. GHC
doesn't recompile a module for a new `-ddump` flag, so add `{-#
OPTIONS_GHC -ddump-stg-final -ddump-to-file #-}` to the modules wanted for
the build, and take it out after; the dumps land beside the objects. A
typed decoder is inlined where its row type is named, so its closures
appear under that module (`Bench.Tokens` for the `Decode` and `Mock`
typed cases), not under `Hmssql.Decoding`. Look for `let` bindings and
constructors (`Just!`, `BS!`) on the path that runs per row, and for a
closure whose arity takes in the row's input when it should have been
built once. Check the size of the objects beside the allocation: choosing
a cell's delimiter once per column doubled `Bench/Tokens.o`.

### The decoders' Core at a user's call site

A typed row decoder selects its field conversions from the metadata and
prepares its read and skip recipes once per result set. `Recipe` carries
the row's null bitmap beside its input, so a new bitmap doesn't rebuild
the parser. The primitive reads and the applicative composition can then
fuse, while the field conversions chosen at run time stay ordinary calls.

When an allocation is in question, read the final optimised Core at a
user's call site. An interface's stable unfolding says what can inline,
but it is not the final program: a `let` or a partial application visible
there may go away after specialisation. Build the library, then compile a
module like this one against it:

```haskell
{-# LANGUAGE DeriveAnyClass, DeriveGeneric, DerivingStrategies #-}
module U (dec2, dec5, decGen) where

import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (LocalTime)
import GHC.Generics (Generic)
import Hmssql.Decoding

dec2 :: RowDecoder (Int32, Int64)
dec2 = rowDecoder

dec5 :: RowDecoder (Maybe Int32, Maybe Text, Maybe Int64, LocalTime, Text)
dec5 = rowDecoder

data Rec = Rec { a :: Int32, b :: Text, c :: Maybe Int64 }
  deriving stock (Generic)
  deriving anyclass (FromSqlRow)

decGen :: RowDecoder Rec
decGen = rowDecoder
```

```sh
stack build
stack exec -- ghc -O1 -fforce-recomp -c -package hmssql \
  -ddump-simpl -ddump-to-file -dsuppress-all -dsuppress-uniques \
  -dumpdir core -outputdir core U.hs
```

In `core/U.dump-simpl`, tell the compilation at metadata time apart from
the functions that run for each row. The prepared parser returns an
unboxed result on its ordinary path; `Stream` continuations belong to
suspension. Look for parser-valued closures built inside the row loop,
boxed control values passed to unknown callbacks, and partial
applications in the applicative composition. A raw row array on the
typed path would be a regression: an ordinary typed query decodes its
values directly. The `Decode` fixture prepares each `rowRecipe` when the
metadata arrives, as the connection does, and must not rebuild one for
every row.

### Azure SQL connection policies

`hmssql-bench-azure/` (a package of its own) is not a
tasty-bench suite: it times connects, round trips, downloads and uploads
against the server the `HMSSQL_TEST_*` variables name, after timing the
cold first connect and first queries separately and a warm-up, and prints
the endpoint every connection reached, so that a run shows whether it
went through Azure's gateway (Proxy) or was redirected to the database's
node. `scripts/azure-bench.sh` builds it for linux/amd64 with Docker (the
Dockerfile's build stage), puts it on the share of `azure-sql-test.sh` and
runs it in ACI, a new 1-vCPU container per run:

```sh
scripts/azure-bench.sh build && scripts/azure-bench.sh upload
scripts/azure-bench.sh compare 3        # Proxy, Default, Proxy, ...; the policy put back after
scripts/azure-bench.sh table ~/.config/hmssql-azure/logs/bench-*.log
```

The results are in [azure-sql.md](azure-sql.md#proxy-and-redirect).

## Test suite map

| Area (`--match`) | What it covers |
|---|---|
| `Wire` | Pure properties for every serializer and parser pair, and a few live checks of wire length and range limits. The reader recipes consume each envelope once at any packet cut (`Wire.Recipes`). Bulk COLMETADATA, ROW, PLP and DONE serialization across packet sizes, empty values and packet-id wraparound (`Wire.BulkPackets`). The ownership of packet buffers at the level of the bytes (`Wire.PacketWriter`). A streamed value of at most `streamWholeLimit` given whole and a larger one in pieces, for each delimiter, a known and an unknown total and text, at every cut; a `FoldingCell`'s two ways of reading; and the text decoders' long values against the whole values' decoders, ill-formed UTF-16 and UTF-8 included (`Wire.StreamWhole`). `byColumn`'s choice per column and its refusals, and `columnIsLong` (`Wire.ByColumn`). `inlinedField` and `inlinedNullableField` against `singleField` at every cut, and the decoders from a date or time value's parts (`Wire.InlinedField`) |
| `Sql` | `Query`'s algebra: placeholders renumbered by `<>`, named parameters, rendering, and a placeholder with no parameter reported (`Sql.Query`), and `mkQuery`'s lexical rules (`Sql.Lexer`); no server |
| `Types` | Each SQL type family: round trips, boundaries, code pages, UTF-16, `sql_variant` row and RETURNVALUE agreement, and parameter and date and time matrices. Every legal decimal precision and scale compared across RPC, bulk copy and the server's text conversion (`Types.DecimalMatrix`); supplementary characters at short-value, PLP and packet boundaries (`Types.UnicodeBoundary`); XML serialization and JSON text and native storage (`Types.StructuredData`); `decimalFieldDecoder` against `Decimal` at every magnitude length, for `money` and the integer types, with its refusals (`Types.DecimalParts`); and lazy text's bounded probe for a large parameter (`Types.LazyParameter`) |
| `Shapes` | Batches, streaming, messages, errors, ENVCHANGEs, procedures and `executeStatements`. `BatchQuery`'s Functor and Applicative laws, comparing returned values and the order and multiplicity of SQL effects (`Shapes.BatchLaws`). Streamed fields on the ordinary query and row-decoder path (`Shapes.ValueStreaming`, `Shapes.Cells`), and lazy and effectful parameter values through the same writer as strict ones (`Shapes.StreamParameters`) |
| `Bulk` | `Hmssql.BulkCopy`: rows loaded by the bulk load, column discovery, the type conversions to each column, streaming, batching, options, errors and a cancelled stream (`Bulk.Copy`); every column type loaded by `bulkInsert` and by `executeMany`, and the two compared (`Bulk.Types`); the policy that a value the column can't take fails on the client rather than being truncated or transcoded (`Bulk.Policy`); hedgehog properties over the PLP chunk, packet and length boundaries (`Bulk.Fuzz`); triggers, batched failures, rollback, defaults, constraint trust, sparse columns, temporal periods and updatable or indexed views (`Bulk.Features`); cross-type numeric and date and time conversions compared with INSERT (`Bulk.Conversion`); named-column mapping in a case-sensitive catalog (`Bulk.NamedColumns`); a load failing on either side of a batch boundary (`Bulk.FailureBoundary`); column discovery after the table changed (`Bulk.Rediscovery`); and large streams among small values (`Bulk.StreamCells`). The data-integrity modules are under [Methods](#methods) |
| `Rpc` | Stored procedures in depth: names, parameters, return status, results and concurrency |
| `Session` | SET options, diagnostics (STATISTICS and SHOWPLAN), server features and cursors |
| `Connection` | Login, credentials, database selection, options, disconnects, TLS hostname checks, connect-phase failures, Entra ID tokens, and Azure's LOGIN7 server names |
| `Protocol` | Encryption negotiation, login, ENVCHANGE, malformed responses and fuzzing (mock server), Attention, UDTs, fatal errors before EOF, and datetimeoffset decoding bounds |
| `Concurrency` | Interruptions, cancellation, many threads, `close` races, streams across threads, sends, callbacks, and transactions under `KILL`. An interruption at every packet boundary of cut rows, of a row longer than 64 KiB, of PLP chunks and of a RETURNVALUE, plain and over the mock SMP server (`Concurrency.Boundary`). A hedgehog property of statements opened, read part-way, cancelled, interrupted and abandoned against a model server that cuts its packets anywhere, may run a cancelled statement whole, acknowledges in the last DONE or in a message of its own, raises its SMP windows late, and may hang up, plain and over SMP (`Concurrency.CancelModel`, 500 cases each in about 2 s). Interrupting a value's consumer doesn't wait for the unread value (`Concurrency.ValueConsumer`) |
| `Differential` | Random schemas filled by literals and by parameters, compared with the server's own rendering |
| `Resources` | Thread, descriptor, heap and session leaks; allocation growth; what closed connections retain; connect under `timeout`. A request left waiting by a mock server that stopped answering, before or part-way through its response, plain, over MARS and over strict TLS (`Resources.StalledServer`). A connect whose server stops, closing or resetting, at any byte of the PRELOGIN response, the TLS flights and the login response, under `EncryptOn` and `EncryptStrict`, fails cleanly and leaves no descriptor (`Resources.CutHandshake`: every 17th byte and the first and last 96, every byte with `HMSSQL_TEST_SLOW=1`) |
| `Scale` | Millions of rows, thousands of columns and result sets, 1 GiB values and many parameters; TLS at packet boundaries and under load |
| `Soak` | A realistic mixed workload run through a small connection pool for `HMSSQL_TEST_SOAK` minutes, with sessions `KILL`ed now and then; checks for growth in heap, descriptors, threads and server sessions |
| `Catalog` | `Hmssql.SqlType` (names, arguments, rendering and the wire's types; pure) and `Hmssql.Catalog` against two scratch schemas in the shared database, with a column of every type, an alias type, typed xml, CLR types, `json` and `vector`, computed and generated columns, keys, foreign keys and a view. Quoted names, schema evolution, cross-schema and self-referencing foreign keys, alias types, sparse columns, quoted XML schema collections and a case-sensitive database (`Catalog.Unusual`) |
| `Api` | API misuse: decoder arity, `RowDecoderMonadic` edges, `ResultSets` misuse, wrong statement shapes, the `queryS` lifecycle, and strictness of field decoders and encoders. `Api.UseAfterRelease` (mock): every request through a released handle, its streams included, throws `ConnectionReleased` and sends nothing, while `close`, `renew` and the read-only inspection still answer, and `renew` makes older handles stale |
| `Review` | Regressions from the client-layer review and from the reviews of how the fixes combine (hot-path costs, exceptions that must propagate, parameter names, and LOGIN7 lengths) |
| `Mutation` | Behaviour that mutation testing of `hmssql/src/` found unpinned |
| `Security` | Secrets in `Show` and exceptions, certificate and TLS parameter checks (in-process TLS server), downgrades, and what a malicious server can make the client buffer |
| `Model` | State-machine tests: random sequences of queries, streams, transactions, errors, SET and USE, resets, releases, interruptions and closes on one connection (and from two threads at once), checked against a model of the session. Each machine runs on a connection without MARS and on a MARS connection, where up to four streams are open at once |
| `Mars` | MARS connections. Live: negotiation, flow control and the window's memory bound, sessions and their reuse, how the server schedules sessions, cancellation and the Attention's slot in the server's window, interruption and the connection's lifecycle, `withQueryS`, and random interleavings of streams (`Mars.Random`). Against the checking mock SMP server in `hmssql-tests/Mars/MockSmp.hs`, which records every breach of SMP by the client (a SYN, a sequence number or a window out of place, or a DATA payload that isn't one TDS packet): negotiation, flow control and sequence wraparound, sessions and FINs, the server's violations, and the reset cases the real server can't be made to produce (the six `Mars.Smp*` modules, among them `Mars.SmpWire`, with pure properties of the SMP header and a check of every write the connection hands its backend) |
| `Transaction` | The durable effects of a transaction body as an independent observer reads them: after commit, rollback, a caught server error, a decode failure, a reset, and every three-step sequence of commit, exception and conversion error (`Transaction.DurableScope`); and the scope of writes made in fully consumed callbacks, fold steps and batch streams (the other `Transaction.*` modules) |
| `MarsTx` | Transactions on a MARS connection: the TM begin and the transaction as the connection's, hygiene (`TransactionRequestsActive` for a stream left unfinished), how a transaction ends with streams open, one SNAPSHOT transaction shared by every session, `reset` and `release` with streams open, the reset gate and its replay, the order in which ENVCHANGEs are applied, and bulk copy beside open streams |
| `Query` | `Query.MarsInterruptedRead`: a non-streaming query on a MARS connection interrupted after its response had all arrived is drained by the next request |
| `Release` | `ReleaseSpec`, live and against the mock server: `release` of an idle connection, a partly read stream, an open transaction (its locks go before the next request), a closed, killed or severely failed connection, waiting behind other threads, and inside `withTransaction`. The mock checks which request carries the RESETCONNECTION bit, with and without a session setup, and the failure paths (an error from the reset request, a withheld acknowledgement under `timeout`, and the server closing mid-drain) |
| `QuerySpec`, `TransactionSpec`, `ResetSpec`, `LockingSpec`, `LargeValueSpec`, `RequestInterruptSpec`, `RobustnessSpec`, `ConnectivitySpec` and `DocExamplesSpec` | The API itself, transactions, `reset`, locking, huge values, interrupted requests, recovery from asynchronous exceptions and concurrent callers, the encryption modes' basic connects, and every README and Haddock example |
| `Harness`, `LiveProperty` and `InternalDerived` | The test harness itself (`TestDb` and its fixtures), the runner of live properties, and the helpers of `Hmssql.Internal.Derived`, whose `Show` and `Eq` must match derived ones character for character |

## Methods

What each kind of test does, and what it found. Most of the library's
behaviour contract ([design.md](design.md)) was pinned down by these.

**Data integrity against the server's own values** (the `Bulk.*Boundary`,
`Bulk.*Source`, `Transaction.*Scope` and `Types.*Boundary` modules, from
the hardening round of 2026-10-27 and 2026-10-28). Each check writes the
same value by bulk copy and by a parameterized `INSERT`, or reads the
value the server constructs from a literal, and compares complete stored
rows, `DATALENGTH`s, raw bytes and `SQL_VARIANT_PROPERTY` metadata rather
than decoded values alone, so that a matching encoder and decoder can't
hide a loss. Where a conversion is expected to differ from the server's
(the clamps at the top of a date-time's range, and bulk copy's stricter
length checks) the test says so and checks the server's refusal beside
the client's result. The transaction checks read the table from a second
connection after the body ends, then run an independent rollback, so that
a status assertion can't conceal leaked work; `Transaction.DurableScope`
runs every three-step sequence of commit, exception and conversion error,
alternating ordinary and bulk writes. `Bulk.FailureBoundary` and
`Bulk.AtomicityBoundary` fail a load on the client or the server on each
side of a batch boundary and check which rows and trigger writes remain.
The numeric checks straddle each binary boundary with the adjacent
representable `Float` and `Double` values and compare the stored bits
(`Bulk.NumericBoundary`, `Bulk.ExactToReal` and `Bulk.ExactToDouble`),
and `Bulk.FloatingScale` generates representable binary fractions whose
exact rational the destination scale can hold. `Bulk.XmlEncoding` sends
raw XML in nine encodings; `Bulk.VariantSource` captures typed source
bytes from a server column and compares the variant with
`CONVERT(sql_variant, v)`; and `Bulk.TextBinaryBoundary` compares fixed
and variable sources below, at and above each length limit.
`Bulk.SchemaContract` and `Bulk.Rediscovery` alter the table between
loads, and `Bulk.NamedColumns` and `Bulk.AtNameEvolution` map named rows
in a case-sensitive catalog and through renames to names starting with
`@`. Run these groups plain and with `HMSSQL_TEST_MARS=1
HMSSQL_TEST_PACKET_SIZE=512 HMSSQL_TEST_MARS_WINDOW=4`, where the rows
cross packet boundaries. What the round found is in
[bugs-found.md](bugs-found.md#bulk-copy).

**Pure round trips (`Wire`).** Hedgehog properties for every serializer
and parser pair, under both protocol versions: every `TypeInfo`
constructor and value encoding including every NULL form and PLP
chunking, every token, SQLBatch and RPC requests, LOGIN7, PRELOGIN,
packet framing over the whole 512..32767 range, and a mixed token stream
parsed incrementally at random chunk boundaries. About 93 properties.

**The mock server (`Protocol`, and elsewhere).** A scriptable in-process
TDS server injects arbitrary or malformed responses: bad packet lengths
and types, one-byte sends, an early END_OF_MESSAGE, the server closing at
every stage, malformed tokens and values, absurd length prefixes
(allocation measured), and Attention timing (a pause mid-token, and
withheld acknowledgements). Fuzz properties mutate token streams, packet
streams and login responses at random and truncate responses at every
byte offset; 400,000 iterations passed after the fixes, and every
exception must be one of hmssql's own. Found eight bugs.

**Live matrices (`Types`).** Every integer type over its full range;
every decimal precision and scale; every single-byte collation for all
256 byte values; every date and time type against the server's
`TRY_CONVERT` of the same value as a literal, biased toward midnight,
rounding ties and range edges; every `sql_variant` base type against
`SQL_VARIANT_PROPERTY`; every `ToSqlField` wire type cast into every
compatible column type; and string and binary types at the PLP and
packet-size boundaries and with non-BMP text and lone surrogates.

**Differential fuzzing (`Differential`).** Random tables (1 to 40 columns
of every supported type, random collations and NULL rates, and 0 to 200
rows biased to boundaries) are filled with T-SQL literals and read back
as `SqlRow`, each cell compared with the server's own canonical
rendering; filled again through hmssql parameters and compared with both;
and read as ROW and NBCROW at packet sizes 512, 4096 and 32767 over TDS
8.0 and 7.4. About 6000 tables showed no mismatches; two targeted bugs
turned up (ill-formed UTF-8, and NULLs into `sql_variant`).

**Concurrency and cancellation fuzzing (`Concurrency`,
`RequestInterruptSpec`).** Interruptions (`timeout`, `killThread` and
`throwTo`) at random points of every kind of request, checked with
sentinel queries that detect a desynchronised connection; many threads
sharing a connection while being killed; `race`; cancelling `WAITFOR`,
lock waits and large results; nested timeouts; `close` racing with use;
streams across threads; `withTransaction` interrupted anywhere; and slow,
throwing and self-killing callbacks. Found five bugs, and later measured
the cost of interruptible sends (0 spurious breaks in several thousand
interruptions).

**Scale and resources (`Scale`, `Resources`, `LargeValueSpec`).** 10
million rows streamed in bounded memory; a 1 GiB `varbinary(max)` round
trip; 4096 columns; 10,000 result sets; 100,000 sequential queries; 1000
large parameters; and a 134-million-character batch read back as a 268 MB
value. Leak tests run 200 iterations of connect and close, failed
connects, abandoned connections, interrupted queries, abandoned streams
and failed transactions, and require thread, descriptor, heap and
server-session counts to return to baseline. Complexity tests measure
allocation at 4x to 10x scale on every axis and require it well under
quadratic. Memory tests inspect the heap with `ghc-heap` to check that
decoded values don't retain packets, and measure what closed connections
retain: the live heap with 50 of them referenced, less the live heap once
they are dropped (`keptAliveByEach`). A reading from before they were made
is not used, because what is alive then and dead afterwards would be taken
off the result, and the system certificate store's cache is exactly that
in the last test of a process to connect
([protocol-notes.md](protocol-notes.md#platform-and-tooling)).
`Resources.StalledServer` leaves a request waiting on a mock that has
stopped answering, and requires the live heap to stay where it was and
the process to allocate next to nothing while the request waits. The
allocation is the whole process's, so a thread any earlier test left
running shows there: a window poller of `Concurrency.CancelModel` that
had swallowed its `killThread` was found that way
([bugs-found.md](bugs-found.md#in-the-test-suite)).

**Reviews as tests (`Review`, `Security`).** A review of the wire layer
against MS-TDS, a review of the client layer, an audit of every narrowing
conversion of caller-supplied values, a security review (certificate
validation in every TLS mode, SNI, signature schemes and cipher suites
seen by an in-process TLS server, downgrade answers, error floods, and
secrets in `Show` and exceptions), and two reviews of how the fixes
combine (with benchmarks of the hot paths against the build before the
testing) each produced tests for what they found.

**Mutation testing (`Mutation`).** Three rounds applied hand-written
mutants to scratch copies of `hmssql/src/` (flipped comparisons, off-by-one
lengths, swapped byte order, dropped validation, removed masking and
cleanup steps, and changed defaults) and ran the suite against each:

| Round | Mutants | Killed by the existing suite | Killed after adding tests |
|---|---|---|---|
| 1 | 139 (138 valid) | 79% | 97% (97.8% of non-equivalent) |
| 2 | 148 | 71% | 95% (98% of non-equivalent) |
| 3 | 113 (code changed since round 1) | 69% | 96.5% (99.1% of non-equivalent) |

The survivors are equivalent mutants or untestable from outside (for
example, the finalizer not killing the reader thread, since closing the
socket ends it anyway). No library bug was found; the rounds pinned down
behaviour the suite had only been exercising.

**Memory safety of the packet buffers (`Wire.PacketWriter`).** These
tests exist to detect corrupted memory. `Wire.PacketWriter` keeps every
packet and compares it at the end with a copy made when it was handed
over, with an allocation of a marked pattern between the buffers; a crash
there is the test failing, and the suite's exit status shows it. Mutants
of the writer as it was before Builder writing replaced it, each run
against the module's 11 examples, showed that they catch it:

| Mutant | Examples failing, of 11 |
|---|---|
| A later packet reuses the buffer | 5 |
| The SMP header goes inside the packet | 5 |
| The plain bytes start at the wrong offset | 6 |
| Buffers are allocated with no room | 5 |
| `unsafeWriteSized` doesn't check the room | 3 |
| A writer stays usable after its message ended | 2 |

The Builder writer keeps the ownership checks, and adds cases at the
primitives' boundaries and for an exactly full packet.

**Model-based tests (`Model`).** Hedgehog's state-machine testing runs
random sequences of 20 to 80 operations on one connection (queries;
streams consumed fully, partially or abandoned; procedures with outputs;
transactions in SQL and through the API; errors of every class; SET
options; `USE`; SESSION_CONTEXT; info messages; `reset`;
`sp_reset_connection`; `release` followed by `renew`, after which an open
stream goes stale; an interrupted `WAITFOR`; a read-only query under a
random `timeout`; `KILL`; severity 20; and `close`). It compares every
result, the messages, `inTransaction`, the pending reset and the server's
own view of the session with a pure model (`hmssql-tests/Model/Machine.hs`).
`Model.Parallel` runs the single-request operations from two threads (not
`release`, which would make the other thread's handle stale). 150 and 100
sequences in the fast suite, 5000 and 3000 in the slow one. No hmssql
bugs were found by the plain machine; the model learned several server
facts ([protocol-notes.md](protocol-notes.md)).

Both machines run twice, whatever `HMSSQL_TEST_MARS` says: on a
connection without MARS and on a `connectMars` connection. The model
keeps its streams in slots: an operation opens one (`startResponse` and a
stream over its reader), reads some rows of a chosen one, reads one to
its end, or cancels one (`cancelResponse`). Without MARS a request
abandons the stream left open. With MARS up to four are open at once
between the other operations, and the model states
[design.md](design.md#mars-several-responses-on-one-connection)'s
contract:

* A request leaves them open, unless it carries a pending reset: then
  every open stream is cancelled first, as by `release`, `rollback` and a
  failed `withTransaction`'s cleanup.
* A stream not read to its end (its last row is not enough) or cancelled
  makes `begin`, `withTransaction` (at its begin, and at its commit, which
  then rolls back) and `commit` (which leaves the transaction open) throw
  `TransactionRequestsActive`.
* A batch or `sp_executesql` call that begins a transaction at
  `@@TRANCOUNT` 0 and leaves it open is rolled back by the server with
  error 3997, while a `BEGIN TRANSACTION` inside a transaction begun by
  `begin` nests, and COMMIT, ROLLBACK and savepoints behave as without
  MARS.
* A stream whose statement rolled back the transaction (an error under
  `XACT_ABORT`) and hasn't been read leaves hmssql with the old
  descriptor, so every request fails with 3971 (INFO 3926), having done
  nothing, until the stream is read or cancelled. A `Cut` refused that way
  may have been interrupted after its request went out, and then the next
  operation that drains abandoned responses reports its INFO 3926 too, so
  that operation's INFO messages are not predicted.

The generator never sets `LOCK_TIMEOUT 0`: the model has no locks, and at
0 any lock wait at all is error 1222. On a MARS connection the runner
waits for each new stream's response to arrive in full before going on,
so that the statement is over on the server and a cancelled stream needs
no Attention, and what the server does then doesn't depend on timing.
`Model.Parallel` has no streams; on a MARS connection its two threads'
requests take turns on the SMP sessions. The MARS machine found two bugs,
both fixed, each pinned by a regression test. A request whose read failed
because the server ended the connection stayed busy, so the transaction
functions threw `TransactionRequestsActive` instead of the connection's
error; now the connection's error comes first
(`Transaction.MarsEndedConnection`). And a non-streaming query interrupted
after its response had all arrived stayed busy too, with nothing draining
it; now the next request, or a transaction function's check, drains it
(`Query.MarsInterruptedRead`).

**Soak testing (`Soak`).** An 8-connection pool shared by 32 workers runs
a mixed workload (small queries, parameterized DML into per-worker
tables, transactions that commit, roll back and are ended by server
errors, partially consumed streams, 1 to 8 MB values, info messages,
errors of severities 11 to 20, and 50 ms timeouts racing a `WAITFOR`)
while a background thread `KILL`s one of the pool's sessions now and then;
every operation verifies its result through a sentinel. A 30-minute run at
the default configuration and 10-minute runs over TDS 7.4 and with
512-byte packets totalled about 1.5 million operations with no
verification failure and no growth trend in the live heap, descriptors,
threads or server sessions. Those runs were made with a pool that reset
its connections and ran `SELECT 1`; the pool (`hmssql-tests/Soak/Pool.hs`) now
hands out `renew`ed handles and checks connections in with `release`,
replacing those it says are gone.

**Equivalence tests for bulk copy (`Bulk`).** For each column type,
`hmssql-tests/Bulk/Harness.hs` creates two identical `#temp` tables, loads one with
`bulkInsert` and the other with `executeMany` of the equivalent
parameterized `INSERT`, and asserts that the bulk-loaded table reads back
what was put in (allowing the documented lossless transforms: `char`
padding, `binary` zero padding, `decimal` scale rounding and `json`
whitespace) and that the two tables hold the same data, value for value
and by `DATALENGTH`. A data-loss probe classifies a rejection as a client
`EncodeError`, a server error, a silent store, or something else. It found
the one silent data-loss path (a character outside a discovered `varchar`
column's code page stored as `?`, by `executeMany` too) and the
`Double`-to-`decimal` rounding divergence between the two paths, now
documented; the fuzz properties over the wire-format boundaries found
nothing.

**Documentation examples (`DocExamplesSpec`).** Every Haskell code example
in the README, the guide and the Haddock is run live, adapted to `#temp`
tables.

**Configuration matrix (`scripts/test-matrix.sh`).** The whole suite under
other encryption modes, packet sizes and session setups, and with MARS
(`mars`, alone and combined with the others), on every GHC version in
`tested-with` and against SQL Server 2017, 2019, 2022 and 2025, in Docker.
The 512-byte configuration found the 65535-packet limit of a batch and the
TLS layer's retention of memory at small packets; `on` is the only way
NBCROW decoding is exercised end to end; and the `mars` configurations run
every test over SMP sessions.

**Reviews without tests.** Builds with extra warnings and a grep of every
partial function found nothing reachable. The adversarial review
([development.md](development.md)) read only the library diff.
