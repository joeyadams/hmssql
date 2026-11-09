# Windows research record

hmssql was made to work on Windows from 2026-10-03 onward, and most of
what it does there was measured before it was decided. This is the
record: the questions asked, how each was measured, the answers with their
numbers and conditions, where the implementation then went its own way,
and what stays unverified. The decisions are in
[design.md](design.md#platform-workarounds), under "Platform
workarounds", with the backend record under "The backend: what the bytes
travel on" and the choice of protocol under "Connection lifecycle". The
server and platform facts are repeated in
[protocol-notes.md](protocol-notes.md), under "Shared Memory and Named
Pipes" and "Platform and tooling". The gaps are in
[limitations.md](limitations.md), how to run the suite on Windows is in
[testing.md](testing.md#on-windows), and the faults found in GHC are
written up with their repros under [upstream/](upstream/).

## How Windows was researched

### Where it started

A smoke test on 2026-10-03, with GHCi 9.10.3 on Windows 10, found two
things. Against a local SQL Server over TCP with `EncryptStrict`, a query
worked and `close` then hung until Ctrl-C; a later query threw
`ConnectionClosedBy ClosedByClient`, and a second `close` hung again. And
against a SQL Server installed with TCP/IP disabled, as some editions are,
`connect` to `localhost` failed with `ConnectionClosedBy (TransportFailed
... WSAECONNREFUSED)`, while SSMS connected to the same name.

The supposition was that the released network package receives with a
blocking `recv` made as a safe foreign call on Windows, that no
asynchronous exception reaches a thread inside a foreign call, and that
`killThread` on the reader thread, which is how `close` stops it, waits
for that delivery for good. On Linux and macOS the reader waits in GHC's
I/O manager, where `killThread` works. A compiled probe later confirmed
it for `recv`, `sendAll` and `accept`
([design.md](design.md#platform-workarounds)). The same reasoning
predicted that cancelling a query would work, since the cancelled thread
waits in STM for the reader and the Attention is an ordinary short send,
and that a `timeout` around `connect` or around a send blocked on a full
buffer would not. The first held, and the probe had shown a blocked
`sendAll` out of reach; the backend replaced network's calls before a
`timeout` around `connect` was measured with them.

SSMS and LINQPad use SqlClient's native network layer (SNI), which, given
a server name without a protocol prefix, tries Shared Memory first when
the host is local, then TCP, and then Named Pipes; a prefix (`lpc:`,
`tcp:` or `np:`) forces one. That is where the default of
`ProtocolAuto` came from.

### The plan

A plan written on 2026-10-03, before any of the work, had four phases:
the backend record with Shared Memory and Named Pipes; TCP that can be
interrupted with the released network; a test of network's support for
GHC's native I/O manager; and a retest on Linux. Its goals were to
abstract the connection's byte stream even at some cost, to add the two
pipe transports, to make basic cancellation work for the many users whose
network can't interrupt its I/O on Windows, and to stress network's new
support for the native manager with the test suite and report what it
found upstream. The retest on Linux was the suite on macOS (2026-10-04)
and on Linux (2026-10-05), without a server and against SQL Server 2025
with and without MARS, and the benchmark before and after the record,
which found no cost in it
([design.md](design.md#memory-and-performance)).

Basic cancellation meant four things on every backend: a long-running
query can be cancelled and the connection used afterwards; the same on a
MARS connection; `release` and `reset` work and can be repeated; and
`close` returns. Timing edge cases, such as a cancel sent just after the
query or a `timeout` that expires mid-send or mid-handshake, were out of
scope at first. So were integrated authentication, LocalDB, SQL Browser
lookups, the dedicated administrator connection and timeouts as
`ConnectInfo` options, which are all still undone
([limitations.md](limitations.md)).

The audience on Windows was taken to be desktop applications, such as
migration utilities, whose most common problem is a query that has to be
cancelled, with an unattended Windows service collecting monitoring data
as the worst case, where a hung connection is very disruptive. The
requirement that followed was that a bug report can be fixed inside a
backend without changing `Connection`. On Linux hmssql serves APIs whose
clients cancel on a whim, and nothing in the plan was to weaken
cancellation there.

Each statement of the plan that came from memory or documentation was
marked unverified and became a probe. Two cards later did the same for the
native manager: one for TCP through network's own calls (2026-11-06) and
one for the pipes through the manager (2026-11-07). Their decisions are in
design.md, and what they got wrong is in
[the departures](#where-the-implementation-departs-from-the-research)
below.

### Machines, servers and builds

Two machines were used. The figures of a section are from the first
unless it says otherwise.

| When | Machine | SQL Server | What was measured |
|---|---|---|---|
| 2026-10-03 and 2026-10-04 | Windows 10 Pro build 19045 in a QEMU virtual machine with 16 logical processors | SQL Server 2025 RTM (17.0.1000.7, Enterprise Developer Edition), a default instance, with TCP/IP disabled until the evening of 2026-10-03 | The pipes, the backend, TCP, the pre-release GHC with network 3.3, and about twenty-five probes |
| 2026-10-16 | The same | The same, updated to build 17.0.1145.4 | A retest of the whole suite |
| 2026-10-08 and 2026-10-09 | A second machine, Windows 10 Pro build 19045 with 32 logical processors | SQL Server 2019 RTM (15.0.2000.5, Developer Edition), local | The first runs against SQL Server 2019, and the stall of the default manager's timers ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)) |
| 2026-11-06 and 2026-11-07 | The second machine | The same | The non-threaded runtime, MARS over a pipe without encryption, TCP through network's calls under the native manager, the GHC branch with the manager's fixes, and the pipes through the manager |

On the first machine the client was built with GHC 9.12.4, network
3.2.9.0 and tls 2.4.6, with the threaded runtime and the default I/O
manager, and ran as a local administrator's ordinary (filtered, medium
integrity) token. The probes of 2026-10-03 were compiled without
optimisation, against a library built with `stack build --fast`, except
where a section says otherwise; the standard build changed three results,
and each figure below says which build it is from. Once TCP/IP had been
enabled, TCP and the native manager were measured with standard builds,
and the native manager also with GHC 9.12.4.20260713 and network 3.3.0.0.

On the second machine the non-threaded probes used GHC 9.12.4 and network
3.2.9.0, under both managers. The work on network's TCP path and on the
pipes through the manager used GHC master
`20334e1d1f` (2026-11-06, version 10.1.20261106) and network master
`1f6aa85` (3.3.0.0, 2026-11-04), and from 2026-11-07 the GHC branch
`wip/winio-completion-packets` (`16069bfc8c`, that master with the
manager's fixes, below). Those builds used a cabal project outside the
repository, with the test suite compiled without optimisation; testing.md
has the procedure.

The throwaway probes are not in the tree. The sessions that did the work
are in [development.md](development.md).

## The questions and the answers

### The pipes and what they carry

**Which pipes exist.** Listing `\\.\pipe\` showed
`\\.\pipe\SQLLocal\MSSQLSERVER` and `\\.\pipe\sql\query`, and the server's
error log names both at startup: "Server local connection provider is
ready to accept connection on [ `\\.\pipe\SQLLocal\MSSQLSERVER` ]" and
"Server named pipe provider is ready to accept connection on
[ `\\.\pipe\sql\query` ]". So Shared Memory is a local named pipe, as the
plan supposed.

**What travels on them.** Plain TDS, the same bytes as over TCP. A
connection over each pipe ran PRELOGIN, the TLS handshake and LOGIN7
unchanged, and `sys.dm_exec_connections.net_transport` reported
`Shared memory` and `Named pipe`. SQL authentication works over both.

**Encryption.** All four modes work on both pipes, with and without MARS.
One run covered 24 configurations and all 24 passed: the protocol chosen
in three ways (`auto`, Shared Memory and Named Pipes), each with the four
encryption modes, plain and over MARS. `EncryptStrict` reported
`protocol_version` 0x08000000 and `encrypt_option` TRUE; `EncryptOn`
reported 0x74000004 and TRUE; `EncryptOff` and `EncryptNotSup` reported
FALSE.

**MARS.** Works over both pipes. Each configuration sent a 4 MB parameter,
read a 4 MB value, cancelled a `WAITFOR`, and ran `release` and `renew`.

### How the server wants writes split

This is the finding that changed the design. SQL Server reads a pipe one
client write at a time, and drops the connection when a write is not made
of whole units. The client then gets `ERROR_PIPE_NOT_CONNECTED` (233) on
its next read or write.

It was measured by sending a 1 MB parameter through a backend that
reshaped the writes, for each of the two pipes, three encryption modes,
four packet sizes (512, 4096, 8000 and 16000) and nine ways of cutting
(216 cases). The two pipes behaved identically.

* **Plaintext:** a write may hold any number of whole TDS packets. Writes
  of 64 KiB holding from 4 to 128 packets were accepted, and so were
  writes cut at 4096, 8192, 16384 or 32768 bytes when the packet size
  divided the cut. Every cut that split a packet was refused, which
  includes every cut at 1000 bytes. (The PRELOGIN and LOGIN7 packets, 47
  and 173 bytes here, are shorter than that, so it was the request's
  packets that were split.)
* **Over TLS:** a write must hold exactly one TLS record. One write per
  record was accepted at every packet size. Joining records into larger
  writes was refused at every size, and so was cutting a record. Under
  strict encryption a cut at 1000 bytes ended the connection at its
  third write, in the TLS handshake, so the rule holds from the first
  byte.
* **On a MARS connection in plaintext:** the unit is the SMP packet.
  This was found on 2026-11-06 against SQL Server 2019 on the second
  machine, not by these probes: a DATA packet written as its 16-byte
  header and then its TDS packet, in two writes, made the server drop
  the connection at the first request, under `EncryptOff` and
  `EncryptNotSup` over both pipes. One write per SMP packet works.

hmssql had been gathering TLS records into writes of up to 64 KiB, which
is right for a socket and is what failed here first: a 4 MB parameter
over TLS failed on both pipes, while the same parameter in plaintext
passed. The plan had expected to concatenate or to write in sequence,
and had not expected the server to care. The pipe backend now makes each
write it is given one `WriteFile`, and the connection only ever hands a
backend whole packets or one record. A write comes as a list of pieces,
which the pipe backend joins, because a plaintext SMP packet is made as
two ([bugs-found.md](bugs-found.md#platform)).

### Cancellation and close over a pipe

* A `timeout` of 300 ms around `WAITFOR DELAY '00:00:10'` returned in 0.31
  to 0.32 s in every configuration, and the next query on the connection
  succeeded. So a write (the Attention) goes out while the reader
  thread's read is pending on the same handle, which is what overlapped
  I/O was chosen for: a handle opened without `FILE_FLAG_OVERLAPPED`
  serialises its operations.
* `close` returned within the clock's resolution (about 16 ms) in every
  configuration. This is the case that hung over TCP with network's
  blocking `recv`.

### The impersonation level of the pipe client

`CreateFileW` takes a level that limits what the pipe's server may do
with the client's identity. Three were tried.

* **`SECURITY_ANONYMOUS`:** the Named Pipes logins seen were refused with
  error 18456, and the server logged state 10, "Password validation
  failed with an infrastructure error", for a client on a named pipe. Two
  refusals were observed directly.
* **`SECURITY_IDENTIFICATION`:** all 8 Named Pipes configurations and all
  8 Shared Memory configurations logged in.
* **`SECURITY_IMPERSONATION`** (the default when no level is given): the
  same.

hmssql uses `SECURITY_IDENTIFICATION`, the most restrictive level that
was seen to work. No difference was measured between it and
`SECURITY_IMPERSONATION`. The comparison that counts is one run with
nothing else connecting: 600 connections at impersonation level, 600
more, 150 at identification level, then 600 and 600 at impersonation
level again, with a minute between the phases. The first phase lost its
third and fourth connections to a busy pipe, left over from before the
run, and the other 2,548 connections succeeded, at both levels. The
server logged one listener stop, in the first minute, and nothing after
it. A sample of 150 can't exclude a small effect, but a level that
made the server's failures (next section) much more likely would have
shown.

### The server's pipe listeners

On the first machine the server sometimes refused a pipe login and
stopped listening on the pipe for a while, and it did so for Microsoft's
own client. This cost most of the probing time of 2026-10-03, because
each failure looked like the result of whatever had just been changed,
and two explanations were proposed and then ruled out by experiment.

What the client sees: a connection that is accepted and then dropped
during the login (`ERROR_PIPE_NOT_CONNECTED`), or `ERROR_PIPE_BUSY` on
every open for some seconds, or both. What the server logs, at the same
second: error 17827, "There was a failure while attempting to encrypt a
password. The connection has been closed", and error 26050 (26044 for
Named Pipes), "Server local connection provider has stopped listening on
[ ... ] due to a failure. Error: 0x542, state: 1. The server will
automatically attempt to re-establish listening". 0x542 is
`ERROR_BAD_IMPERSONATION_LEVEL`. The listener was re-established after
between 8 and 57 seconds. A stopped listener doesn't always turn clients
away: one loop went on connecting through an eight-second stop without
a failure, which at its average rate was some sixty connections.

**It happens to Microsoft's client.** With no hmssql connection for four
minutes before or during, .NET Framework's `System.Data.SqlClient` over
`lpc:localhost` (pooling off; a connect, `SELECT 1` and close, 20 ms
apart) had 9 failures in 600 connections. Three were dropped in the
login, each matching a 17827 in the server's log, and six could not
connect while the listener was down. The server logged its first 0x542
stop twelve seconds into the loop, with no refused login before it.

**It happens at the start of activity, not during it.** In the two
experiments described here, hmssql made 3,750 connections in 11 loops,
each loop starting after an idle spell of between 44 seconds and two
minutes. Five connections failed, every one among the first four of its
loop, in 3 of the 11 loops. No connection failed later in a loop. The
server's log has a listener stop or a refused login at the time of each.

**The impersonation level is not the cause.** 2,548 of 2,550 connections
succeeded across both levels, with one listener stop, at the start
([above](#the-impersonation-level-of-the-pipe-client)).

**Reading the error log is not the cause.** `xp_readerrorlog` was the
only way to see the server's side, and most of the day's probes ended
with a call to it, so it was suspected of disturbing the server. Six
loops of 200 connections were run 90 seconds apart, alternately with and
without a log read immediately before. One loop of the three in each
group had failures: two busy opens after a read, and one dropped login
with no read. A third suspicion, that the read's loopback connection
fails in SSPI, came from one coincidence (an "SSPI handshake failed"
entry at the second of a read) and did not recur: four later reads
logged none.

**The suite's concurrency makes it worse.** The suite as it normally
runs, sixteen tests at a time, was more than the listener could take,
with or without encryption.

* With strict encryption, two groups at a time, each sixteen tests at a
  time, the areas for cancellation, MARS, `release` and `reset` ran for
  4.3 minutes before the run was stopped. In that time the server's log
  has eight stops of the Shared Memory listener with 0x542, of 8 to 57
  seconds each and 210 seconds in all, several of them within half a
  second of the listener being re-established, and no refused login. Of
  27 groups that finished, 21 passed. The six that failed had 43 failing
  tests between them: 41 whose `connect` found the pipe busy for more
  than the 5 seconds hmssql then waited, and 2 that assumed TCP in what
  they expected of `sys.dm_exec_connections`. None was a failure of what
  the test was about.
* With no encryption, the same areas and the same concurrency: groups
  that had failed on the busy pipe passed in a second or two, and then
  three tests of `Concurrency.Close` that open many connections each lost
  one to a login the server dropped, and the next groups sat waiting for
  the pipe. So encryption is not what the stops depend on.

The connect loops above, one connection at a time, ran clean for
thousands of connections, and Microsoft's client in such a loop did not.
What the suite adds is many connections at once, some of them killed or
interrupted part-way through a login. Which of those the listener
objects to was not found.

**The cause is not known.** One hypothesis fits the error code: a
service account that lacks the right to impersonate gets only an
identification-level token from a pipe client, and anything it then does
under that token fails with 0x542. It was not checked, because it needs
administrator access to the machine, and it doesn't by itself explain
why only some first connections fail.

**Later builds of the server did not show it.** At 23:10 on 2026-10-03 an
update replaced the server with build 17.0.1135.8 (RTM-GDR, KB5122770)
and restarted it, in the middle of a run. In the 100 minutes of runs on
that build, which were the last runs of the whole suite over each pipe
and over TCP, the server's log has no stop of a pipe listener and no
refused login, where on the earlier build every whole run over a pipe had
met several. On 2026-10-16 the maintainer updated the server to build
17.0.1145.4 (RTM-GDR, KB5128492) and restarted the machine. One whole
run of the suite over each pipe, one test at a time with the standard
build, passed in about 15 minutes without a rerun, and the server's log
from the restart to the end of that day's runs (about three hours, all
the transports) has no error 26050, 26044 or 17827. Its other errors are
ones the tests provoke (fatal errors, `KILL`, refused logins and a
malformed login packet), apart from two Query Store errors, 12412, which
were not looked into. Whether the updates are why was not established.

What followed for the work:

* A failure at `connect` over a pipe on such a server is not evidence
  about hmssql until the server's log has been read for the same second.
* The test suite's first connection is the one most likely to be
  refused, and the suite used to end there. Its setup hook waits for the
  server, and prints each wait (`waitingForPipes` in `hmssql-tests/SpecHook.hs`).
* The suite was run over the pipes one test at a time (hspec's
  `--jobs 1`, one group at a time), and a group that failed was run
  again up to twice: a failure that went away was the server's.
* hmssql itself does not retry a refused login, as it doesn't over TCP.
  It retries a busy pipe for 30 seconds. That began as 5, which was
  shorter than most of these stops: the first live run of the suite lost
  three tests to a busy pipe at its start, none of them having connected
  ([design.md](design.md#connection-lifecycle)).

### A pending operation dies with the thread that started it

This was a bug in the first version of the Windows backend, found by the
mock-server tests and not by any probe.

The symptom: in the first run of the suite without a server, two test
groups (`Protocol.Malformed` and `Mars.SmpFlow`) each had one failure, a
connection that ended while both sides still wanted it. Run again,
`Protocol.Malformed` failed in 3 of 9 runs, on a different test each
time. One failure carried the cause in its message: the client's
receive had failed with `ERROR_OPERATION_ABORTED` (995), "The I/O
operation has been aborted because of either a thread exit or an
application request", on a connection that nothing had stopped.

The first version started each overlapped `ReadFile` and `WriteFile` on
the Haskell thread that asked for it, which is to say on whichever of the
runtime's worker threads was running that Haskell thread. The runtime
ends worker threads it has no more use for, and every blocking wait the
backend makes (a safe foreign call) hands the capability to another
worker, so workers come and go.

The probe: on a loopback socket, a read was started with `ReadFile` from
a bound thread (`forkOS`), which has an operating-system thread of its
own that exits when the Haskell thread returns.

| The thread that started the read | The handle | The read, before any data was sent |
|---|---|---|
| Stays alive | Plain | Still pending after 0.5 s; then received the 3 bytes sent |
| Exits | Plain | Completed with error 995 |
| Exits | Associated with an I/O completion port | Completed with error 995 |
| Stays alive | Associated with an I/O completion port | Still pending; then received the 3 bytes |

So Windows cancels a pending overlapped read when its thread exits. In
this probe a completion port did not prevent it, and a later probe found
what decides that: the event in the read's `OVERLAPPED`. On a socket
associated with a completion port of the probe's own, a read was started
from a bound thread that then ended, with each combination of call and
event, twice over with the same results:

| The call | `hEvent` | The read, after its thread had exited |
|---|---|---|
| `ReadFile` or `WSARecv` | None (null) | Still pending; then received the 3 bytes sent |
| `ReadFile` or `WSARecv` | An event | Completed with error 995 |
| `ReadFile` or `WSARecv` | An event with its low bit set | Completed with error 995 |

A read that reports its completion only to the port outlives its thread.
One that carries an event does not, whether or not a packet goes to the
port as well. hmssql's own operations carry an event, with the low bit
set so that another I/O manager's port is left alone, and so they need
the issuer. GHC's native I/O manager gives its operations no event,
which is why its operations need none
([below](#ghcs-native-io-manager-winio)).

The fix is the issuer: one bound thread, alive as long as the process,
on which every operation is started
([design.md](design.md#platform-workarounds)). Its effect was measured
with a temporary trace of every receive that ended without data, counting
the ones aborted on a handle that had not been stopped, shut down or
closed. `Protocol.Malformed` (147 examples, two handles for each
connection) was the group used.

| Code | Runs | Handles opened | Receives aborted with no stop | Runs with a failed test |
|---|---|---|---|---|
| Operations started in place | 1 | 294 | 5 | 1 |
| Operations started on the issuer | 20 | 5,880 | 0 | 0 |

Only one of the five aborted receives failed a test. The others fell
where nothing was waiting on the connection, so the rate of visible
failures understated the fault by a good deal.

The probes that passed before this was found, of the socket backend in 17
steps and of a receive pending across a send, were short programs with
one or two threads, in which no worker thread had reason to exit. They
showed that the operations work, and could not have shown this.

### What one end of a pipe sees when the other closes

Measured between the two ends of a pipe made with `pipeListen`, both
through hmssql's pipe backend, because the mock server's tests rely on
it and the first guess at it was only a guess.

| The server end | The client's receive | The client's send |
|---|---|---|
| Sends 3 bytes, then closes its handle | The 3 bytes, then the end of the stream | Fails: "The pipe is being closed" (232) |
| Closes its handle, having sent nothing | The end of the stream | Fails the same way; a receive after it still gives the end of the stream |
| Closes while the client's receive is pending | The end of the stream | |
| Sends 3 bytes and closes at once, the client's receive pending | The 3 bytes, then the end of the stream | |
| Sends 3 bytes, then disconnects and closes | Fails: "No process is on the other end of the pipe" (233); the 3 bytes are lost | Fails the same way |

The other direction is the same: when the client closes after sending,
the server receives what was sent and then the end of the stream.

Two things follow. A pipe has no half-close: an end that closes can no
longer be written to, where a socket shut down in one direction still
accepts the other's writes. And a disconnect is the pipe's reset. The
mock server maps its "end the sending side" to a close and its "reset"
to a disconnect.

### Whether handles leak

The leak tests count open descriptors before and after thousands of
connects, and Windows has no list of descriptors, only a count of all the
process's handles. That count was first tried in their place, and rose
across each sweep of 5,000 interrupted connects: by 62, 38 and 3 in the
three tests of `Resources.ConnectTimeout`, and by 37 in
`Resources.ConnectReader`. A handle leaked on an interrupted connect
would look like that, so it was measured before any tolerance was chosen.

The probe made batches of 1,000 connects through the socket backend on a
loopback socket, each with a timeout swept across the connect and every
other one with a blocked receive interrupted, and read the count after
each batch.

* Over 8 batches: 145 at the start, then 160, 160, 168, 170, 176, 178,
  178 and 178.
* Over 20 batches: 139 at the start, 174 after the fourth, 178 after
  the ninth, 178 after each of the next ten, and 184 after the last.

About ten connects in each batch were interrupted, in the batches where
the count rose and in those where it didn't. So the count does not follow
the connects or the interruptions. It moves in small steps and stops,
which is what the runtime's worker threads and whatever Winsock keeps for
each would do, and it held still across 10,000 connects in a row.

The count is therefore too coarse for these tests, which on other
platforms allow a difference of 2. The backend counts its own open
handles (`backendHandleCount`), every one wrapped less every one closed,
and the tests check on Windows that the count returns to where it
started. A control confirmed that the count rises by one for a backend
left open and returns when it is closed. With that check, the three
sweeps of `Resources.ConnectTimeout` and the sweep of
`Resources.ConnectReader` pass: no handle of hmssql's stayed open after
5,000 connects interrupted at every point, including through a login
redirected twice and a MARS connect. The process's count is still
compared, with an allowance of 250 (`windowsHandleSlack`), as a backstop
for a leak outside the backend. Without `-threaded` that allowance was
not always enough ([below](#the-non-threaded-runtime)).

### What the backend costs

A loopback echo server, written with network's own calls, sent back 100
bytes at a time. A client made 20,000 round trips through network's
`sendAll` and `recv`, then 20,000 through hmssql's socket backend, three
times over in alternation. The library and the probe were compiled with
optimisation, and the machine was otherwise idle. The figures are those
of two runs.

| Client | Per round trip |
|---|---|
| network's blocking calls | 25.6 to 26.3 µs |
| hmssql's socket backend | 61.5 to 62.9 µs |

The backend adds about 36 µs to a round trip: two hand-offs to the
issuer thread, for the send and for the receive, and a helper thread
with a blocking wait for the receive, which is pending each time. With
the library compiled without optimisation (`stack build --fast`), and
the live tests running beside it, the backend's round trip took 73 to
75 µs and network's the same 26. It was not measured against a SQL Server, where the
server's own time is added to both rows.

The same probe with GHC 9.12.4.20260713 and network 3.3.0.0, on the idle
machine, three rounds under the default I/O manager and six under the
native one:

| I/O manager | network's calls | hmssql's socket backend |
|---|---|---|
| default | 26.4 to 27.7 µs | 65.5 to 66.0 µs |
| native | 47.1 to 49.1 µs | 64.6 to 66.2 µs |

Under the native manager network's calls go through the manager and
cost nearly twice what its blocking calls cost under the default one.
hmssql's backend costs the same under both, since it uses neither.

On the second machine in November the backend measured 40 to 43 µs over
TCP and 42 to 46 µs over a pipe, threaded, with network's calls at 24 to
26 µs ([the non-threaded runtime](#the-non-threaded-runtime) and
[the pipes through the manager](#the-pipes-through-the-manager-2026-11-07)).
The machine and the library had both changed since 2026-10-03, and the
difference was not looked into.

### The live suite over the pipes

All of this is from the first machine, run one test at a time as
[above](#the-servers-pipe-listeners) explains.

#### The areas for cancellation, with an unoptimised build

The 36 groups for cancellation, MARS, `release` and `reset` hold 544
examples, 4 of them pending. They were run under five configurations,
with the library and the suite built by `stack build --fast`.

| Configuration | Groups that passed, reruns included | What did not pass |
|---|---|---|
| Shared Memory, no encryption | 35 of 36 | `Concurrency.Attention` |
| Shared Memory, strict | 34 of 36 | `Concurrency.Attention` and `Mars.WithQueryS` |
| Shared Memory, strict, MARS | 35 of 36 | `Mars.WithQueryS` |
| Named Pipes, strict | 35 of 36 | `Concurrency.Attention` |
| Named Pipes, no encryption | 35 of 36 | `Concurrency.Attention` |

One more group needed its reruns. `MarsTx.Hygiene` over Shared Memory
with strict encryption lost one test in its first run and five in its
second to a connection dropped during the login, and passed in its
third. The server's log has a refused login (error 17827) at the second
of each of the six.

Meanwhile the server's log for the 41 minutes of the three Shared Memory
configurations has 24 stops of the Shared Memory listener and those six
refused logins, all six under strict encryption. No test failed on a
stopped listener. The stops lasted from under a second to 37 seconds, a
stopped listener does not turn every client away, and hmssql waits 30
seconds for a busy pipe. For the 19 minutes of the two Named Pipes
configurations the log has no stop and no refused login, which the next
run showed to be luck. So running one test at a time does not keep a
listener up; it leaves the stops few enough to wait out.

#### A drain too short to interrupt

The tests that did not pass depend on timing, and on the build. Each
needs an interruption to land inside a short wait.

* Three live tests of `Concurrency.Attention` need to interrupt the
  drain of a cancelled stream. A watcher throws 0 to 200 µs after the
  connection has recorded the Attention as sent, up to a hundred times,
  and in a failing test all hundred landed after the drain was over.
  Between one and three of the three failed in each of the group's
  twelve runs without MARS, and its one run over MARS passed.
* One test of `Mars.WithQueryS` needs to interrupt `withQueryS`'s wait
  for the Attention's acknowledgement at its exit. Its watcher looked
  for the Attention every 20 ms, and `threadDelay` takes 16 ms at the
  least on Windows, so the round trip was over before it looked again.
  It ran out of its 50 tries in 10 of the group's 13 runs.

Both tests were changed. The watcher of `Mars.WithQueryS` spins until
the Attention is recorded. The three tests of `Concurrency.Attention`
are reported as pending over a pipe when no interruption lands, and fail
as before over TCP. What they guard, that an interrupted drain breaks the
connection, is tested as well against the mock server, which withholds
the acknowledgement so that the drain is sure to wait, and those tests
pass with the mock on a named pipe.

With those changes and the standard build (`stack build`, the library
optimised), both groups passed in 15 runs of 15, three under each of
the five configurations, and no test of `Concurrency.Attention` was
pending. So for `Concurrency.Attention` it was the build that made the
difference; for `Mars.WithQueryS` the build and the change were not
separated. Why an unoptimised library makes the drain uninterruptible
in practice was not measured. The drain runs unmasked, so an
interruption can only miss it if nothing is left to wait for. The
supposition is that the acknowledgement from a local server is already
received by the time the slower send of the Attention has returned
through the backend.

#### The whole suite, with the standard build

All 198 groups (3,373 examples, 55 of them pending as in any run without
the slow tests) were run with strict encryption and without MARS, over
each pipe.

| Run | Groups that passed at once | After the reruns | Listener stops in the server's log | Logins refused (17827) |
|---|---|---|---|---|
| Shared Memory, 23 minutes | 194 of 198 | 196 | 12 | 3 |
| Named Pipes, 25 minutes | 192 of 198 | 196 | 16 | 8 |

Every failure that a rerun cured was the server's. Over Shared Memory
two tests lost their connection to a refused login, and a third found
the pipe busy for longer than 30 seconds, during a stop that lasted 76.
Over Named Pipes five tests lost their connection to a refused login.
The other refused logins fell on the first connection of a group, which
the suite's setup waits out. The count of refused logins in the server's
log equals the count of connections the suite saw dropped, in both runs.

The two groups that no rerun cured failed alike over both pipes, and
both were tests that assumed TCP:

* `Protocol.Login` logs in through the internal API on a socket it
  opens itself, and the server has TCP/IP disabled. It now opens what
  the configured protocol opens, and so tests the raw login over a pipe.
* `Mutation.HostedTls` kills a session and expects the next request to
  report `ClosedByServer`, or behind Azure's gateway a reset. Over a
  pipe SQL Server disconnects the pipe, and the request reports a
  transport failure with error 233, which the test now accepts there.

With those two changed, both groups passed twice over each pipe, so
every group of the suite has passed over Shared Memory and over Named
Pipes on the standard build.

**A mock test that the faster build broke.** `Resources.ConnectReader`
sweeps an interruption across the end of `connect`, counted from a
signal the mock gives when it has sent the login response. It passed
with the unoptimised build and failed with the standard one, on both
mock transports: no attempt in 3,000 was interrupted. The mock's send
goes through hmssql's backend and returns some tens of microseconds
after the bytes have left, and the optimised client had finished
`connect` by then. The mock now signals just before it sends
(`serveLoginAfter`), and the test passed three times on each transport.
With that, the suite without a server passes on the standard build with
the mock on TCP and with it on a named pipe: 198 groups and 3,373
examples each, of which 2,302 are pending for want of a server.

#### Three more configurations, whole

After those changes the suite was run whole under three more
configurations, and every failure below was looked at.

| Run | Groups that passed at once | What did not |
|---|---|---|
| Shared Memory, strict, MARS | 198 of 198 | |
| Shared Memory, no encryption | 197 of 198 | one test of `Robustness` |
| Named Pipes, `EncryptOn` (TDS 7.4) | 198 of 198 | |

None of the three runs met a refused login or a busy pipe. The test of
`Robustness` wraps a materializing query of 300,000 rows in a `timeout`
of 20 ms and expects the timeout to win. In plaintext over Shared
Memory all the rows arrived first, three times in three: the timeout
fires up to 16 ms late on Windows, and nothing slows the rows. The
query now ends in a `WAITFOR`, so that it can't finish first, and the
group passed three times in plaintext and once each with strict
encryption and with MARS.

By 2026-10-04, tests in nine groups had been changed for Windows:
three that assumed TCP or a server on Linux, five whose timing or clock
Windows didn't offer, and one that depended on an exception's type.

**How the groups were counted.** The suite's 198 top-level groups were
each run as a process of their own. Ten of them are listed twice by the
test binary, having a serial and a parallel part, and the runner ran
those twice, so its own totals were higher (208 runs and 3,640
examples). The figures here count each group and each example once.

### TCP against the server

With TCP/IP enabled on the first machine's server, the stock
configuration (GHC 9.12.4, network 3.2.9.0, the default I/O manager, a
standard build) ran the whole live suite over TCP with strict encryption.

| Run | Groups that passed |
|---|---|
| One test at a time | 198 of 198; one mock test failed once and passed when run again |
| One test at a time, MARS | 198 of 198 at once |
| A process per group, sixteen tests at a time | 198 of 198 at once, twice, in under nine minutes each |
| The same, MARS | 198 of 198 at once |
| One process for the whole suite, as `stack test` runs it | 3,373 examples: two failures in each of three runs, from a leak (below); with it fixed, none in one run and one in the next, a connect that timed out |

**The server stands the suite's concurrency over TCP,** where over
either pipe its listeners stopped under the same load. In about a dozen
runs of the whole suite at sixteen tests at a time, no connect was
refused, and two timed out (`WSAETIMEDOUT`, after the 21 seconds Windows
gives a connect), each failing the one test it belonged to. The fault
recorded above belongs to the server's pipe listeners.

**SQL Server on Windows resets a killed session's connection.** The
first run found one test that expected otherwise: after `KILL`, the next
request on the killed connection failed with a reset where SQL Server on
Linux closes in an orderly way. `ReadFile` on the socket reported it as
`ERROR_NETNAME_DELETED` (64), "The specified network name is no longer
available". The backend reports Winsock's code for the same event,
`WSAECONNRESET`, and the test accepts a reset from a server on Windows.

**The mock test that failed once** is `Resources.CloseFailure`'s "the
finalizer of a connection dropped without close closes the socket". It
counts the closes that went through a close made to fail, and counted
none. It failed three times in about fifteen runs of its group, and
passed each time it was run again. The fault was the test module's own:
on Windows its way of making a close fail left a `Handle` open on the
socket's number, and that handle's finalizer closed the number again
once it belonged to this test's socket
([bugs-found.md](bugs-found.md#in-the-test-suite)). network's own
finalizer for the socket had no part in it. The connection's reader
thread refers to the socket, so the socket is not garbage before the
connection's finalizer has stopped that thread.

**The one-process run found a leak that is not Windows's.** Two tests
of what a closed connection keeps alive failed in it, for plaintext
connections only: about 34 KB for each closed connection still
referenced, against a bound of 16 KB. A probe put the whole of it on the
connection's context, which kept the session's collation as a 5-byte
slice of the buffer the login response was received into, and for a
plaintext login that buffer is 32 KiB. With the five bytes copied the
figure is 3.7 KB. The two tests passed when their groups were run alone,
with or without the fix, and failed without it once another of them had
run in the same process. It is the last test of a process to connect
that measured low, not the first, and the tests measure differently now
([bugs-found.md](bugs-found.md#in-the-test-suite)).

### The non-threaded runtime

On 2026-11-06 the owner asked whether a `timeout` could still cancel a
query on Windows without `-threaded`. This section is what was measured
to answer it, with GHC 9.12.4 and network 3.2.9.0, on the second
machine. The probe's peer was a separate, threaded process with three
loopback servers: an echo, one that sends one byte 3 s after accepting
and then says nothing, and one that never says anything. No SQL Server
was involved. The probe was compiled with `-O`, once with `-threaded` and
once without.

**What the non-threaded runtime has for blocking calls.** Read in the
9.12.4 sources and then confirmed by the runs below:

* A safe foreign call stops every Haskell thread, because there is one
  operating-system thread for Haskell code and nothing to hand the
  capability to.
* The legacy I/O manager (the default) has a pool of worker threads,
  in `rts/win32/MIOManager.c`, behind three primops: `asyncRead#`,
  `asyncWrite#` and `asyncDoProc#`. `asyncDoProc#` runs a C function of
  type `HsInt f(void *)` on a worker, and the calling Haskell thread
  waits in the scheduler, as `BlockedOnDoProc`, while the others run.
  `GHC.Conc.Windows` exports it as `asyncDoProc`.
* The pool gains a worker whenever fewer are idle than requests are
  queued, and a worker never exits before the runtime shuts down. So a
  C function that starts an overlapped operation and waits for it in the
  same call is never cancelled by its thread exiting
  ([above](#a-pending-operation-dies-with-the-thread-that-started-it)).
* An asynchronous exception reaches a thread blocked in any of the three,
  under `mask_` too, since the wait is interruptible. The thread is
  removed from the queue and its request is marked abandoned
  (`abandonWorkRequest`), and that is all: the worker's call runs on,
  and its result is dropped when it ends.
* `asyncDoProc#` under the threaded runtime is `barf("asyncDoProc# on
  threaded RTS")`, and was seen to be (exit 127).

**network's `recv` is interruptible there, and loses data.** On Windows
network 3.2.9.0 receives through `GHC.IO.FD.readRawBufferPtr` on the
socket's descriptor, which under the non-threaded runtime is
`asyncRead#`, a blocking `recv` on a worker. So the program keeps
running: a `timeout` of 300 ms around a `recv` from the server that
speaks after 3 s returned `Nothing` after 300.8 ms, and a thread waking
every 10 ms meanwhile never waited more than 11.1 ms. But the abandoned
`recv` stays in place on its worker. A second `recv` on the same socket,
with a timeout of 6 s, returned nothing: the byte the server sent at 3 s
had gone to the abandoned call and been dropped. For hmssql that means
a timed-out read would take the start of the server's answer to the
Attention and lose it, so a timeout around a read can't be made to work
with network's calls under this runtime. (200 rounds of a connection, a
`recv` timed out after 1 ms and a close left the process with one more
operating-system thread than it started with, so closing the socket
does end the abandoned call.)

**One C function per operation, through `asyncDoProc`, does work.** The
probe's C function took a request with the handle, the buffer, an event
for the operation and a cancel event, and:

1. returned at once with `ERROR_OPERATION_ABORTED` if the cancel event
   was already set;
2. started `ReadFile` or `WriteFile` with its own `OVERLAPPED`, whose
   event had the low bit set;
3. if the operation was pending, waited for either event, and on the
   cancel event called `CancelIoEx` on its own `OVERLAPPED` and waited
   for the operation's event;
4. read the outcome with `GetOverlappedResult`, set a done event and
   returned.

On an exception the Haskell side set the cancel event and then waited
for the done event with a second `asyncDoProc`, under
`uninterruptibleMask_`, before freeing the request and the buffer. The
results:

* A `timeout` of 300 ms around a read from the server that speaks after
  3 s returned `Nothing` after 300.9 ms, with the ticker's longest wait
  11.2 ms. The read had been pending, was cancelled, and ended with 995.
  The same under `mask_`: 300.7 ms. Under `uninterruptibleMask_` the
  timeout waited for the byte, as it should: 3004 ms.
* The socket survived the cancel: a second read on it returned the one
  byte when the server sent it, 2.65 s later.
* 3000 reads on the silent socket, each killed after a yield or a delay
  cycling through 0, 0, 20, 100, 500 and 2000 µs, ended 996 times at the
  check before `ReadFile` and 2004 times pending and cancelled with 995,
  and never otherwise. It took 1.4 ms a kill, nothing hung, and the
  process went from 6 operating-system threads to 8 and from 145 handles
  to 147, which is the pool growing by two.
* Every operation of the first two bullets ran on the same worker thread.

**What it costs.** 20,000 round trips of 100 bytes against the echo,
each variant in a process of its own, five rounds each, on the otherwise
idle machine:

| Runtime | Client | Per round trip |
|---|---|---|
| non-threaded | network's `sendAll` and `recv` | 32.4 to 35.7 µs |
| non-threaded | the C function through `asyncDoProc` | 44.6 to 50.7 µs |
| threaded | network's `sendAll` and `recv` | 23.7 to 26.1 µs |
| threaded | the C function as a safe call on a forked thread, waited for on an `MVar` | 50.4 to 67.2 µs |
| threaded | the C function as a safe call in place (no exception can reach it) | 28.6 to 31.8 µs |
| threaded | hmssql's socket backend, the issuer and a helper | 39.8 to 43.3 µs |

The probe's threaded variant forks a thread for every operation, the
send included, where hmssql's backend forks one only for an operation
that is pending, so that row overstates what a C path in the threaded
runtime would cost. Each operation of the C path also creates and
closes three events, which a real implementation keeps per connection.

**Not under the native manager of a released GHC.** With
`+RTS --io-manager=native` and the non-threaded runtime, a `threadDelay`
of 100 ms worked (114 ms), but both network's `recv` and the probe's
`asyncDoProc` crashed the process, with an access violation reading
`0x28` or with exit code 127 and no message. The stack of the access
violation in network's `recv` was in `AddIORequest`, called by
`addIORequest` from `stg_asyncReadzh`: the legacy manager's pool, which
the native manager never starts. The sources agree, since `syncIOCancel`
there handles only the legacy manager and `barf`s otherwise. The GHC
branch of 2026-11-07 starts that pool under the native manager
([below](#the-manager-fixed-on-a-ghc-branch)).

**Under the whole suite.** The test suite linked without `-threaded`
(`--flag hmssql:nonthreaded`), against the local SQL Server 2019, found
three things that the probe, with a handful of threads, could not:

* **A delay is a worker.** Under this runtime `threadDelay` is the
  `delay#` primop, which on Windows queues a request with the worker
  pool (`addDelayRequest`), and a worker serves it with `Sleep`. A
  `timeout` whose action returns kills its timer thread, which abandons
  the request, and the worker sleeps on until the limit. In a probe,
  200 `timeout`s of 10 s around a 1 ms `threadDelay` added 201 handles,
  one worker each, and the pool kept them once the limits had passed;
  200 more after that added none, since the idle workers took them. The
  threaded runtime stayed at 127 handles throughout. The suite wraps
  each property case and most live items in a watchdog of 10 to 120 s,
  and with those on `timeout` the process had 5,847 threads when the
  parallel items were done. With the shared watchdogs on the test
  suite's `timeoutInSlices`, whose timer sleeps 50 ms at a time, it had
  2,153.
* **Each worker takes handles of its own once.** Over the 5,000 connects
  of the first sweep of `Resources.ConnectTimeout`, with the thread count
  flat at 5,847, the process's handle count rose by 854, in steps that
  shrank: 140 over the first 500 connects, 14 over the last. Run alone,
  with 29 threads, it rose by 30 and then not at all, and the exact
  count of the backend's handles never moved. The likely reading, not
  verified, is that Winsock keeps state for each thread that calls it,
  and the lookups and connects reached worker after worker for the first
  time. With 2,153 threads the sweep moved the count by 22. Over the
  pipes on 2026-11-07 the same check still failed in 3 runs of 6, by 270
  to 360 handles, while the exact count passed.
* **A thread whose wait ends goes to the back of the run queue.** All
  Haskell threads share one capability, and a thread that a worker
  wakes waits behind every runnable thread, each taking a time slice of
  20 ms. With 16 items at once, the reads of 64 MB in `LargeValue`,
  which took 2.3 to 2.5 s alone (1.3 to 1.6 s threaded), took more than
  their 60 s, and `Mars.WithQueryS` found no interruption landing in the
  exit's wait in 50 tries. The suite took 458 s that way. With 4 items at
  once both passed, and the suite took 368 s.

The suite's first full run without `-threaded` hung for four hours in
`Resources.Helpers`, whose loop of collections allocated nothing and so
was never preempted on one capability; it yields now
([bugs-found.md](bugs-found.md#in-the-test-suite)). Against the local SQL
Server 2019 the built library then took about 136 µs a `SELECT 1` round
trip over TCP with encryption without `-threaded` and 151 µs with it, and
a `timeout` of 500 ms around a `WAITFOR` of 5 s returned at 500 ms over
each transport, with the other threads running throughout.

One case of one run failed in the mock server's own lookup: network's
`getAddrInfo` of `127.0.0.1` with `AI_NUMERICHOST` returned 11001
(`WSAHOST_NOT_FOUND`). Three runs of that module afterwards passed. It was
seen again on 2026-11-07, twice in `Resources.CutHandshake`'s proxy
without `-threaded` under the default manager, and once with GHC master,
and it was not explained.

### GHC's native I/O manager (WinIO)

Under `+RTS --io-manager=native`, when hmssql was built against network
3.3 or later with a GHC that defines `__IO_MANAGER_WINIO__` as 2 or more,
its TCP goes through network's own calls, as on Linux and macOS, and its
pipes through the manager's completion port, with or without `-threaded`.
Otherwise hmssql's TCP and pipes run the code they run under the default
manager, and nothing of it goes through that manager
([design.md](design.md#platform-workarounds)). This section is what was
measured on the way there, which took three tries: hmssql's own I/O
through the manager (2026-10-04, removed for a crash in the manager),
network's calls for TCP (2026-11-06), and the manager for the pipes once
it had been fixed (2026-11-07).

#### Which compiler, and what the build needed

network 3.3.0.0 compiles its code for the manager only when GHC defines
`__IO_MANAGER_WINIO__` as 2 or more. GHC 9.10.3 and 9.12.4 define 1
(checked), and network's pull request 628 says the change behind the 2
reached the 9.12 and 9.14 branches after 9.12.4 and 9.14.1 were released.
GHC 9.12.4.20260713, the third release candidate of 9.12.5, defines 2
(checked), and was installed with ghcup from its pre-release channel for
the runs of October. GHC master of 2026-11-06 defines 2 (checked). On
that date 9.12.5 was at its fourth release candidate and 9.14.2 at its
second, and network 3.3 was not on Hackage, whose newest release was
3.2.12.0. With an older GHC, network 3.3 under the native manager runs
the code it always ran.

* network's repository at `7868459` did not configure with that
  compiler: its `configure` writes a `test-suite` section into
  `network.buildinfo`, which Cabal 3.14.2 refuses. The change of its pull
  request 628, which was open, was applied to the checkout: the test
  option moves into `network.cabal`. Network master `1f6aa85` still
  needed it, with the Cabal of cabal-install 3.18.
* hmssql did not compile against network 3.3: a socket's descriptor is a
  `CULong` there, where it was a `CInt`, and a closed socket is marked
  `INVALID_SOCKET`, where it was -1.
* On GHC master four of hmssql's dependencies did not compile as
  released (hashable, strict, crypton and serialise), each for a change
  in GHC, and were patched. With nothing pinned, cabal chose tls 2.5.1,
  and hmssql does not compile against tls 2.5, which drops `HashSHA1`;
  the runs pinned the TLS packages to the versions of `stack.yaml`.

#### The suite under the pre-release, 2026-10-04

The two columns without a server are the mock on TCP and on a named
pipe; live runs are strict encryption, at sixteen tests at a time over
TCP and one test at a time over a pipe. hmssql's own backend served
every transport.

| GHC | network | I/O manager | Without a server | Live |
|---|---|---|---|---|
| 9.12.4 | 3.2.9.0 | native | 198 and 198 of 198 | TCP: 198 of 198 |
| 9.12.4.20260713 | 3.3.0.0 | default | 198 and 198 | TCP: 198 of 198 |
| 9.12.4.20260713 | 3.3.0.0 | native | 198 and 198 | TCP: 198 of 198, and 198 over MARS. Shared Memory: 198 of 198. Named Pipes: 198 of 198 |

Every group passed at its first run in each cell. The stock build
(the first row's, under the default manager) was run again at the end
as well: 198 of 198 without a server on each mock transport, over TCP,
over Shared Memory and over Named Pipes, with one group needing a second
run over TCP and over Shared Memory, for `Resources.CloseFailure`
([above](#tcp-against-the-server)).

**A socket that network has given to the manager can still be used
beside it.** Under the native manager network 3.3 associates each
socket with the manager's completion port as it makes it. hmssql's
operations on that socket carry an event with its low bit set, which
keeps their completions off the port, and the runs above are the
evidence that the two don't disturb each other.

**An operation through the manager outlives its thread.** A receive
started with the manager's `withOverlapped` from a bound thread that
then ended was still pending afterwards and completed with the 3 bytes
sent a second later, three times in three, with the thread confirmed
gone while the receive was pending. That is the completion port's doing
and the absence of an event
([above](#a-pending-operation-dies-with-the-thread-that-started-it)).

**The wall clock is coarse under the native manager.** `getCurrentTime`
around a connect to the mock gave 0 s twenty times in twenty there,
where under the default manager it gave usable figures. Two tests sized
their timeouts from it and so tested nothing, and said so. The tests
measure durations with the monotonic clock now.

**Turning a socket into a `Handle` fails there with the older network.**
With network 3.2.9.0 under the native manager, `socketToHandle` threw
`FD:newBuf not supported`, having already marked the socket closed. One
test uses it to make a close fail, and caught only an `IOException`.
hmssql itself never calls it.

#### A path through the manager, built and removed

With a compiler that defines the 2, each handle was associated with the
manager's port and each operation went through `withOverlapped`, with no
issuer and no helper thread. What it showed:

* It passed the suite without a server on both mock transports, and the
  live suite over TCP, 198 of 198 each.
* A round trip on a loopback echo cost about 50 µs through it, the same
  as network's own calls under that manager, measured with tests running
  beside it. hmssql's backend cost 65 µs under either manager
  ([above](#what-the-backend-costs)).
* The manager gives a completion callback the operation's status as the
  kernel left it. For a failure that is an NTSTATUS, where the start of
  an operation fails with a Win32 code: the other end of a pipe closing
  arrived as `0xC000014B` (`STATUS_PIPE_BROKEN`), which the path took
  for an unknown error until it converted such codes with
  `RtlNtStatusToDosError`. GHC master converts them itself since
  `5e8ae81beb` (2026-10-23).
* Over MARS, `Scale.TlsConcurrency` (64 connections, each sending and
  receiving 64 KiB) crashed the process in most runs, with an access
  violation in `GHC.Internal.Event.Windows.$wprocessCompletion`. Making
  the path's completion callback do nothing that could block changed
  nothing, and no operation's start had failed before any crash.
* The crash does not need hmssql. A program with network's own `recv`
  and `sendAll` and 32 connections, each with a thread receiving all
  the time and another sending, crashed in 5 runs of 5 under the native
  manager, in 4 of 5 with 24 connections, in none with 16, and never
  under the default manager
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)).

So the path went, and hmssql did its own I/O under both managers until
TCP moved to network's calls and the pipes to the manager in November.

**A thread killed during a file read may never end.** Before the crash,
two tests of `Concurrency.Close` hung on that path in every run of their
group, with strict encryption only. The thread that didn't end was
blocked in a foreign call, and the same was reproduced with nothing but
`Data.ByteString.readFile` and `killThread`: under the native manager
31 killed readers of about 3,200 never ended, with GHC 9.12.4 as with
the pre-release, and none of 21,000 under the default manager
([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
A TLS connect reads the CA certificate files, which is where the tests'
kills had landed. hmssql reads those files with interruptions held off
on Windows. Interrupting network's `recv` under the same manager, 4,800
times from 16 threads, never hung.

#### network's TCP path, 2026-11-06

With GHC master `20334e1d1f` and network master `1f6aa85`, TCP under the
native manager was moved to network's own calls
([design.md](design.md#platform-workarounds)), against the local SQL
Server 2019, with the test suite built without optimisation.

**The control: hmssql's backend on that build.** Before the change, with
every connection on hmssql's backend, the suite passed under both
managers. Without a server, under the native manager, threaded: 5,998
examples, zero failures and 4,422 pending, in 136 s. Live over TCP:

| Runtime | Manager | Result |
|---|---|---|
| threaded | native | 5,997 examples, 0 failures, 143 pending, 199 s |
| threaded | default | 5,997 examples, 0 failures, 143 pending, 192 s |
| not threaded | default | 5,997 examples, 0 failures, 144 pending, 375 s |
| not threaded | native | refused at the suite's setup, as the backend then did there |

**What network does there, as read.** In network master `recvBuf` and
`sendAll` go through the manager, and an asynchronous exception cancels
them, but `sendMany` and `connect` are safe foreign calls on a blocking
socket ([protocol-notes.md](protocol-notes.md#platform-and-tooling) has
the whole reading).

**What the suite found on that path, and the probes of network alone
that explained it:**

* At first the suite without a server had 14 failures, in four groups,
  each a consequence of network's calls there: a reset read two ways,
  the mock server's own receive failing on a reset, a send that nothing
  interrupts, and a connect that nothing interrupts. The tests now state
  the consequence on that path, and without a server the suite then had
  one failure in 5,999, a reset test fixed after the run.
* *Is a reset the end of the stream there, as network's source
  suggests?* Only when it arrived before the receive began. A reset
  during a pending `recvBuf` completes it with `ERROR_NETNAME_DELETED`,
  which network's completion callback doesn't map, and which surfaces as
  an `InvalidArgument` with errno `EINVAL`. The mock server saw it
  whenever the client closed with bytes of the mock's unread, in
  `Concurrency.Boundary` over SMP and `Transaction.TmBegin`, and now
  reads it as the client's close.
* *Why did an interrupted 16 MB batch hang a test?* Winsock took the
  first 64 KiB `sendMany` of the message whole, and the next blocked in
  network's foreign call, under `mask_`, so the `cancel` landed only
  once the mock had read all of it, in the wait for the response. A
  64 MB `sendAll` or `sendMany` to a peer that read nothing returned in
  22 ms, and the next 100 bytes blocked.
* *What does `close` do to a sender blocked there?* It waited for the
  sender until the mock server ended the connection, in most runs of
  `Resources.CloseDuringSend`, since a shutdown doesn't end the call; in
  two runs, over MARS and over Shared Memory, it returned at once.
* *What does a silent address cost?* A `connect` to 10.255.255.1 under a
  `timeout` of 4 s returned after 21.0 s, when Windows gave the address
  up, and through hmssql's `connect` under a `timeout` of 3 s it failed
  with `WSAETIMEDOUT` after that wait.
* *The live suite, threaded,* each run 5,999 examples: over TCP 1
  failure and 149 pending in 329 s, and on the rerun with the final
  tests 1 failure, `Differential.Decode` at the server's stack dump and
  error 3624, the server's bug described in
  [testing.md](testing.md#sql-server-2017-2019-2022-and-2025); over TCP with MARS 2 failures in
  316 s; over Shared Memory 3 in 332 s; over Named Pipes 1 in 342 s.
  Every failure but the server's was a test of an interruptible connect
  or send that now states the consequence, and one, `Mars.SmpSessions`'
  dropped connection, failed once and passed 120 times alone.
* *Does the native manager's crash under busy sockets reach hmssql now?*
  It does. Three runs over TCP with MARS of four ended after 31 to 50 s
  in an access violation reading `0xffffffffffffffff`, the signature of
  [upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md),
  whose repro on this master crashed in 5 runs of 5 with 32 connections,
  in none of 2 with 16, and never under the default manager.
* *And without `-threaded`?* The suite froze before its first test: one
  connection established, no session on the server, 0.14 s of CPU.
  hmssql's TLS connect worked alone in a probe, and the third of three
  froze. A probe of network alone froze the same way: a `recv` killed
  while pending, on a socket then closed, left the next socket's first
  operation pending for good, and the whole runtime with it, in 13 runs
  of 13, and not with the sockets left open. `accept` crashed that
  runtime as well. hmssql's `close` kills a pending receive, so on GHC
  master this configuration was refused, over TCP as over the pipes.
* *Under the default manager, unchanged?* With the same build, threaded,
  over TCP: 2 failures in 192 s, two connects that timed out
  (`WSAETIMEDOUT`) while the server wasn't taking connections; not
  threaded: zero failures in 359 s.

#### The manager fixed on a GHC branch

On 2026-11-06 and 2026-11-07 the faults behind the crash and the freeze
were found in GHC's source and fixed on a GHC branch,
`wip/winio-completion-packets` (`73e9beb738` and `16069bfc8c`, on master
`20334e1d1f`), not yet submitted upstream. What it fixes:

* **Completion packets that outlived their requests.** That was the
  crash under a few dozen busy sockets
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)).
* **A request completed inline while its packet was still coming.** A
  start callback that returns `CbNone`, as a `ReadFile` does, could be
  completed at once although a completion packet would follow.
* **A cancelled request waited for in a blocking `GetOverlappedResult`
  on its handle,** a safe foreign call. In the non-threaded runtime that
  stopped the scheduler, which was the freeze; it fits the supposed
  cause of the file read that never ends
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
  The branch cancels with `CancelIoEx` and waits uninterruptibly on the
  `MVar` the manager fills.
* **`asyncDoProc`'s workers were never started under the native
  manager,** so `accept` and `asyncDoProc` crashed the non-threaded
  runtime.
* **In the non-threaded runtime the scheduler spun when idle, and took a
  wait for I/O for a deadlock,** running a collection whenever every
  thread was blocked.
* **A batch of exactly 64 completions failed a bounds check.** That
  ended the Haskell thread that processes completions before it let the
  manager's C thread go on, and nothing completed again. It hung every
  run of the suite over MARS without `-threaded`, with 4 jobs.

network's branch `winio-recvmsg-more-data` has one fix too, for
`recvBufMsg`, which hmssql doesn't use.

With the branch, threaded, 21 runs of the suite had no crash or hang, 12
of them over MARS. Without `-threaded`, network's TCP path ran the suite
to its end when two groups were skipped, `Concurrency.Send` and
`Resources.CloseDuringSend`: 5,994 examples, two failures, the server's
stale plan and a reset read as the end of the stream. Those two groups
hung because their mock server, in the same process, must read for a
blocked `sendMany` to end (a stack dump showed the scheduler's thread in
`WS2_32`), and their tests are pending there now
(`Compat.blockingCallStopsProcess`). In those runs, with 4 jobs,
`Concurrency.CancelModel` over MARS failed in about two runs of three with a reset the mock server
never sent. It failed in 2 of 3 beside `Connection.ConnectFailure` and
in none of 13 alone or under CPU load: that group's connect to
`10.255.255.1` stops the whole process for 21 s, and the mock servers
beside it give up. That test is pending there too. hmssql's own backend
also passed there in six runs, once the branch started the workers of
`asyncDoProc`; the pipes ran on it, with the refusal removed in a scratch
copy, before they moved to the manager. On the strength of these runs
TCP took network's path without `-threaded` as well.

#### The pipes through the manager, 2026-11-07

The path removed in October was built again for the pipes alone, on the
GHC branch. A probe came first: a program with both ends of a named pipe
in one process, every operation through `withOverlapped` on a handle
associated with the manager's port, built with the branch and with plain
master `20334e1d1f`, threaded and not, compiled with `-O`, on the second
machine. What it asked:

* *Does an echo work, and what does it cost?* 100 bytes each way, 20,000
  round trips: on the branch 50 µs each threaded and 12.5 µs not
  threaded; on master 37 µs threaded and 656 µs not threaded, where
  master's scheduler polls. With `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS`
  set on both ends, so that a write that completes at once posts no
  packet: 34 and 8.7 µs on the branch, 31 and 652 on master.
* *Does the open of a local pipe ever wait?* No. 2,000 opens of a pipe
  with a `ConnectNamedPipe` pending took 17 µs each on average threaded
  and 5.6 µs not threaded, the most 93 µs. 2,000 opens of a busy pipe
  failed with `ERROR_PIPE_BUSY` in 4.7 to 4.9 µs, the most 0.5 ms, and
  2,000 of a missing one with `ERROR_FILE_NOT_FOUND` in 4.5 µs. That is
  the measurement behind the plain safe call without `-threaded`
  ([design.md](design.md#platform-workarounds)).
* *Does an interrupted read return, and does the next read get the next
  bytes?* A read of an empty pipe under a `timeout` of 200 µs was
  interrupted 1,000 times in 1,000 on the branch and 300 in 300 on
  master, in both runtimes, and every following read got the 8 bytes
  written after it. Each interruption took 15.7 ms, the manager's timer
  granularity.
* *What does a read pending when the other end closes complete with?*
  `ERROR_BROKEN_PIPE` (109), a Win32 code, on the branch and on master
  alike. A read started after the close fails with the same code. A
  write after the close fails with `ERROR_NO_DATA` (232). A read pending
  on the client when the server calls `DisconnectNamedPipe` completes
  with `ERROR_PIPE_NOT_CONNECTED` (233), and so does the client's next
  write.
* *Does the manager agree that `ConnectNamedPipe` after the client
  connected posts no packet?* Yes. The call returned 0 with
  `ERROR_PIPE_CONNECTED` (535), or `ERROR_NO_DATA` when the client had
  connected and closed, and the `OVERLAPPED`'s status word stayed
  `STATUS_PENDING`, which Windows writes when it completes a request.
  Returned as `CbDone`, the operation ended at once, and the instance then
  carried a write and a read. A `ConnectNamedPipe` interrupted while
  pending could be started again on the same instance, and a client then
  connected.
* *Do `CancelIoEx(h, NULL)` and `CloseHandle` end a pending read and a
  pending write?* `CancelIoEx` ended both with `ERROR_OPERATION_ABORTED`.
  `CloseHandle` ended the read with `ERROR_BROKEN_PIPE`, which a receive
  takes for the end of the stream, and the write with
  `ERROR_OPERATION_ABORTED`; so hmssql's close cancels before it closes,
  and checks its flag.
* *Under load?* 200 pairs, each echoing 2,000 round trips, a third of the
  clients killed and a third cancelled with `CancelIoEx` part-way. On the
  branch, 6 runs of 6 ended with nothing hung and every pair never
  interrupted finished. On master, threaded, 5 runs of 5 did the same,
  with no crash; not threaded, 5 runs of 5 froze.

The decisions the probe was to check held: the open needs no machinery,
and on master the pipes have the exposure network's path has, the
non-threaded freeze above all. The skip of the completion port saved
about a third of a bare echo's round trip, which the card had left to
the next measurement.

**What the pipes' path costs.** With the path built, a second program
echoed 100 bytes 20,000 times through hmssql's own functions, both ends
in one process, on the branch, with `-O`: through the manager
(`Hmssql.Connection.Backend.WinIO`) and through hmssql's backend
(`Hmssql.Connection.Backend.Windows`) on the same build and under the
same manager.

| Runtime | Manager, no skip | Manager, skip on success | hmssql's backend |
|---|---|---|---|
| threaded | 51.8 to 54.1 µs | 36.0 to 38.5 µs | 41.7 to 46.0 µs |
| not threaded | 11.8 to 12.7 µs | 8.7 to 9.8 µs | 8.8 to 10.5 µs (default manager) |

Without the skip the new path cost more than the one it replaced, so the
handles get `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS`
([design.md](design.md#platform-workarounds)).

**The suite on the path.** On the branch, under the native manager, 15
runs of 5,999 examples each passed with no failure, threaded and not,
over Shared Memory, Named Pipes, both with MARS, the mock on a pipe, TCP
and TCP with MARS, and without `-threaded` also `auto` with the host
`localhost`, which went over Shared Memory
([testing.md](testing.md#latest-results) lists the runs). The first mock run
over a pipe hung on a test that put a TCP proxy in front of a mock on a
pipe (`Resources.CutHandshake`), and `Concurrency.Send` chose its
expectation by the TCP path alone; both tests were fixed. Under the
Stack build with GHC 9.12.4 and network 3.2, where the path can't hold,
the pipes behaved as before.

**hmssql under warp on the same build.** hmssql was run under warp and
http2, streaming query results into HTTP responses from a pool of
connections, built with the branch and network master and threaded under
both managers on 2026-11-07, against the same SQL Server 2019; it was the
first run of hmssql on the native manager outside the test suite. warp's
stack was pinned to the Stackage snapshot, with `recv` and `http-semantics`
one version back since network master lacks the calls their newer versions
use. Under the native manager as under the default one, the responses
streamed over Shared Memory and over TCP to the database, and a client that
hung up mid-response, by a killed socket or as HTTP/1.0, was handled the
same way under both. A load of 48 clients making 40 requests each, a quarter
of them long responses the client abandoned part-way, completed 1,920
requests and 3.57 GB with no failure in 33.3 to 33.7 s, over Shared Memory
and over TCP to the database.

### Other measurements

* A TCP connect to `localhost` with TCP/IP disabled took about 4 s to
  fail with `WSAECONNREFUSED`: the name resolves to two addresses, and
  Windows retries a refused loopback connect for about 2 s each.
  `ProtocolAuto` tries Shared Memory first for a local host, so it does
  not pay this unless the pipe can't be opened.
* A short sleep or timeout lasts until the next tick of the system
  timer: `threadDelay` of 100 µs, 1 ms and 5 ms each took about 17.5 ms
  on average on a machine busy with the test suite, and 20 ms took about
  32 ms ([protocol-notes.md](protocol-notes.md#platform-and-tooling)).
* On the second machine, with the threaded runtime and the default
  manager, tens of thousands of pending delays stalled every timer for
  seconds once they began to expire, which failed a MARS test in 9
  whole-suite runs of 12 on 2026-10-08
  ([upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md)).
  The test suite's helpers use `timeoutInSlices` since.

## Where the implementation departs from the research

The plan of 2026-10-03, the probes and the two cards of November
recommended some things the implementation did differently. The reasons
are in [design.md](design.md#platform-workarounds).

* **hmssql's own overlapped I/O for TCP as well, from the start.** The
  plan's phase 2 had three candidates for a socket's "stop receiving",
  in order of preference: `CancelIoEx` on network's blocking `recv`,
  with a flag to make it sticky; the pipe backend's overlapped I/O on
  the socket, with network only resolving and connecting; and a
  `shutdown` of the receiving side. The second was taken at once,
  because the mock-server tests needed it, and the other two were never
  measured. Closing the socket under the reader was never a candidate,
  since its number can be reused before the reader notices.
* **An issuer thread.** The plan started each operation in place, and
  that was the bug of
  [a pending operation](#a-pending-operation-dies-with-the-thread-that-started-it).
* **One write per unit on a pipe.** The plan expected to concatenate a
  vectored send or write it in sequence, and didn't expect the server to
  care about the boundaries. A write is now one unit, and since the fix
  for MARS without encryption it arrives as a list of pieces that the
  pipe joins.
* **30 seconds for a busy pipe,** not the first 5, because of the
  server's listener stops.
* **`ProtocolAuto` takes a port other than 1433 to mean TCP only,** a
  rule the plan didn't have, so that a wrong port can't reach the
  machine's default instance over a pipe.
* **The process's handle count replaced by the backend's own count** in
  the leak tests on Windows.
* **The `-threaded` requirement, which the plan meant to document, was
  lifted** on 2026-11-06 for the default manager. hmssql's path for the
  non-threaded runtime keeps the probe's wait and its cancel event but
  not the rest of it:
  * The operation is started by the Haskell thread, in place, and only a
    pending one goes to a worker. Every operation of the probe went to
    one, a write that completes at once included.
  * The events of the wait are the handle's own, one set per direction,
    reset before each wait, where the probe made three for every
    operation.
  * A name lookup, a connect and the open of a pipe run on workers too,
    which the probe left unmeasured. An interrupted caller leaves at
    once, and a thread of its own frees the request once the call ends.
  * The check that refuses the configuration a build can't serve comes
    before the first lookup. A first version checked only once the
    socket was connected, and the lookup crashed the process under the
    native manager before the check was reached.
* **Under the native manager, phase 3's open question** was whether
  hmssql's mechanism works there or has to stand aside. On 2026-10-04 it
  worked and stayed, and the path through the manager was removed for
  the manager's crash. On 2026-11-06 TCP moved to network's calls
  anyway, on the owner's position that hmssql should be an ordinary user
  of network on the path where network supports the manager.
* **The first card's reading of network was wrong in two places.** It
  read network's `recvBuf` as mapping every reset to the end of the
  stream; a reset during a pending receive is an `InvalidArgument`
  instead. And its table had TCP take network's path without `-threaded`
  as well; on GHC master that froze the runtime, so the configuration
  was refused until the GHC branch showed it working the next day.
* **The second card left `FILE_SKIP_COMPLETION_PORT_ON_SUCCESS` off**
  unless the round trip showed a need, and the round trip showed one.
  It also had stop receiving cancel nothing, which the implementation
  kept, and close cancel the whole handle, to which the implementation
  added a check of the flag in each operation's start callback, so that
  a close between an operation's first check and its `ReadFile` is not
  lost.

## Not verified

* Whether the server's pipes are message-type or byte-type
  (`GetNamedPipeInfo`). The server's behaviour, reading a write at a
  time, is what the backend relies on.
* A named instance. The pipe names `\\.\pipe\SQLLocal\<instance>` and
  `\\<host>\pipe\MSSQL$<instance>\sql\query` come from documentation.
* A pipe on another machine, over SMB, and with it the open that stops
  every Haskell thread without `-threaded` while SMB answers.
* What opening the pipe returns when the server is stopped or the
  protocol is disabled.
* Why the server's pipe listeners stop and refuse logins, whether
  another installation does it, whether builds 17.0.1135.8 and
  17.0.1145.4 still do (a few whole runs on each met no stop), and
  whether the suite at its usual concurrency over a pipe still stops
  them there. How often Microsoft's client is refused on its first
  connection after an idle spell.
* TCP to a server on another machine, and a connect that an interrupted
  caller abandons there.
* The suite with the slow tests over the pipes and under MARS, and the
  matrix's packet sizes and session setup, on Windows. The slow tests
  have run over TCP ([backlog.md](backlog.md#checks-to-revisit)).
* Why an unoptimised library makes the drain of a cancelled stream over
  a pipe too short to interrupt.
* Whether Winsock's state for each thread that calls it is what raises
  the handle count under the non-threaded runtime, and the cost of the
  workers there with many connections at once.
* Why network's `getAddrInfo` of `127.0.0.1` sometimes fails with
  `WSAHOST_NOT_FOUND`.
* Whether network's `sendMany` blocking under `mask_` can hold a
  `timeout` past what the tests saw.
* The two upstream repros on the GHC branch: the suite stopped crashing
  and freezing there, but whether `ManyConnections.hs` and
  `KilledRead.hs` pass on it is not recorded.
* The native manager under a released GHC that defines the 2 (9.12.5 or
  9.14.2), none of which has the branch's fixes.
