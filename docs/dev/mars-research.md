# MARS research record

MARS was researched before it was built, and this is the record: what was
asked, how it was measured, what was found, and where the implementation
then went its own way. The contract is in
[design.md](design.md#mars-several-responses-on-one-connection), the
server facts with their numbers are in
[protocol-notes.md](protocol-notes.md#mars-and-smp), the gaps are in
[limitations.md](limitations.md#mars), and the guide's
[MARS page](../guide/streaming/mars.md) shows the API in use. This document is
the evidence behind those, and the list of questions a port to another
server version should ask again.

## How MARS was researched

Two spikes, seven probes, a plan and a review, on 2026-09-29 and
2026-09-30, all against SQL Server 2025 (PRELOGIN version 17.0.4075) in
the `sqlserver2025` Docker container reached over `::1:1433` from an Apple
M4 Pro, except probe 6, which ran against an Azure SQL Database on the
Basic tier. The server behind Docker's port forwarding answers `SELECT 1`
in about 344 us, so the absolute latencies below are inflated against a
LAN server, and the ratios are what to read.

* **Spike 1** (2026-09-29, a Sonnet 5.5 subagent directed by Opus 5.5)
  built SMP session multiplexing as throwaway code on the local branch
  `mars-spike`, with a channel as a record copy of `Connection`, and
  measured it.
* **Spike 2** (the same day, a second Sonnet 5.5 subagent) probed
  transactions under MARS and a snapshot shared by several sessions, on
  the same branch.
* **Probes 1 to 7** (2026-09-29 and 2026-09-30, seven Sonnet 5.5
  subagents in parallel) each answered one remaining design question,
  with throwaway code on a branch of its own made from `mars-spike`
  (`mars-probe-1-lock-waits` to `mars-probe-7-bulk-copy`), six of them
  sharing the local server, so their timings are noisy and their counts
  are what to trust.
* **The plan** (2026-09-30, Fable 5.1) was written from the spikes and
  probes, corrected twelve of their statements, and listed the server
  assumptions below for the tests to pin.
* **The review** (2026-09-30) checked the finished code against a
  checklist of 111 items written before the code existed, by five
  subagents, one per area.

The throwaway code stayed on local branches, and the full write-ups,
about 6,900 lines, were consolidated into this page on 2026-09-30 and not
kept.

## The questions and the answers

Each spike and probe asked one question. The answer is given with its
numbers and the conditions they were measured under. Unless a section says otherwise, the
server is the local SQL Server 2025 over TDS 7.4 with `EncryptOn`, the
TDS packets are 8000 bytes, and the client runs with `-N1`.

### Spike 1: SMP session multiplexing

**Question.** Does MARS work against SQL Server 2025 when built inside
hmssql's connection design, what does it cost, and where does the design
have to bend?

**Method.** A channel as a record copy of `Connection`, an SMP mux and
demux, and a demo that read four tables of 200,000 rows as four streams,
round-robin by one thread (1, 100 or 1000 rows per turn) and by four
threads, every row verified. Window (4, 16, 64 and 1000), ACK cadence (1,
2 and 4), packet size (8000 and 4096) and the four encryption modes were
varied; timings are medians of three repetitions.

**Answer.**

* The protocol works: four interleaved streams on one connection with no
  row wrong in dozens of runs, and 3000 sessions on one connection work
  too (opened in 49 ms, one query each in 1.3 s).
* The server interleaves packet by packet: at 100 rows per turn, 8,400
  DATA packets arrived with 6,190 session switches. At the start of a
  query each session gets a burst up to its window, and then strictly one
  DATA packet per session per turn, in a fixed order that isn't the order
  the queries started in.
* SMP starts after the login. A SYN before LOGIN7 made the server close
  the connection without a reply; PRELOGIN, TLS, LOGIN7 and its response
  as plain TDS, then the SYN, worked in all four encryption modes. Under
  TDS 8.0 the MARS option needs a PRELOGIN inside the TLS session.
* The server's receive window stays 4 ahead of what it has consumed,
  whatever the client offers, and it ACKs every second packet (63 ACKs for
  a 126-packet request). The client's window is honoured far beyond
  MC-SMP's 4: with a window of 4, 16, 64 or 1000 the packets queued for an
  unread session were exactly that many (32,000 to 8,000,000 bytes).
* Violations (a SYN for a live SID, a shrinking WNDW, DATA beyond the
  window) close the TCP connection with no TLS alert. A `KILL` sends a FIN
  on every session and then closes.
* An Attention is an ordinary 24-byte DATA packet on its session;
  cancelling one stream with four packets in flight took 0.77 to 0.80 ms
  and the other three ran to their last row.
* Everything is one SQL session: one `@@SPID`, DATEFIRST, `#temp` tables
  and `USE` shared. (The probe's streams had ended on the server before
  it set anything. A setting changed while an older request is still
  running goes back when that request ends, which the test matrix found
  on 2026-10-05: [protocol-notes.md](protocol-notes.md#mars-and-smp).)
  A `BEGIN TRANSACTION` batch fails with 3997; a
  TM_BEGIN_XACT works and its ENVCHANGE arrives only on the sending
  session. A RESETCONNECTION with a stream open on another session fails
  with a bare error DONE, and so does every later request until the stream
  is cancelled.
* Throughput, with the spike's code (window 4, ACK every packet, 100 rows
  per turn): four MARS sessions read 800,000 rows in 0.682 s, four plain
  connections in 0.313 s, one plain connection reading the tables in turn
  in 0.578 s, and one MARS session in turn in 0.748 s. MARS cost 10 to 20%
  against a plain connection and bought no speed: the limit is one
  server-side connection, about 130 MB/s for this data. (The
  implementation's own figures, 1 to 2% per stream, are in
  [limitations.md](limitations.md#mars).)
* Window and cadence (one stream, plain 0.576 s): window 4 with an ACK
  every packet 0.750 s (stop-and-wait, four packets per 280 us round
  trip), window 4 with an ACK every 4 packets 1.084 s, window 16 with ACK
  every 2 0.631 s, window 64 with ACK every 4 0.614 s. 4096-byte packets
  were 30 to 60% slower in every configuration.
* Encryption (four MARS sessions against four plain connections):
  `EncryptOn` 0.684 s against 0.318 s, `EncryptStrict` 0.821 against
  0.314, `EncryptNotSup` and `EncryptOff` 0.44 against 0.205. Without TLS,
  four sessions are still half the speed of four connections.
* SMP adds 25 to 30 us to a `SELECT 1` round trip (344 us plain, 376 us on
  a MARS session). 12 to 18% of packet fetches waited 0.1 to 1 ms in every
  configuration, because the client is faster than the connection.
* Memory: 3.5 to 3.7 MiB live after a major GC and 32 MiB RSS for four
  200,000-row streams, the same as the plain baselines; at window 1000 the
  live heap reached 21.7 MiB.
* A session that read ten rows and slept held at most its window while
  the other three finished 200,000 rows each in 0.55 to 0.58 s. A
  1,000,000-byte parameter (126 packets) took 19 to 20 ms alone and 44 to
  59 ms beside two streams and another sender, with no deadlock, because
  the send lock was held for one packet only.

What the spike got wrong is in the departures below: a plain
session-setup batch before the SYN, FIN then SYN for one SID, the
defaults of 16 and 2, and the packet size over TLS.

### Spike 2: transactions and a shared snapshot

**Question.** Can the transaction layer move to Transaction Manager
requests on every connection, how do transactions behave across SMP
sessions, and can one snapshot transaction shared by several sessions
read a parent table and its child tables consistently while other
connections write?

**Method.** A raw request layer (a batch or a TM request with any
descriptor and any outstanding-request count), a script interpreter with
one script per case, statistics loops, and a snapshot demo. Round trips
are medians of five runs of 3000 pairs; a race between a request and
another session's commit ran 5,040 times; the zip ran 102 times beside
two writer connections, against controls of 10 to 30 runs each.

**Answer.**

* On a plain connection TM requests and the T-SQL statements are
  interchangeable on one transaction: begin, commit, rollback, savepoint,
  nesting, and every error that ends a transaction. TM_BEGIN and TM_COMMIT
  cost 422 to 448 us a pair against 481 to 529 us for the batches (less
  parsing, no round trip saved); a TM_COMMIT that begins the next
  transaction in the same request costs 219 to 225 us.
* The isolation byte maps 1 to 5 to READ UNCOMMITTED through SNAPSHOT, 0
  keeps the level, and 6 or 255 is error 3995. The level persists after
  the transaction, as with `SET`, and RESETCONNECTION keeps it on SQL
  Server. Traps: TM_SAVE_XACT with an empty name is 3977 and rolls back; a
  TM_COMMIT carrying an outstanding-request count above 1 is 3981 even on
  a plain connection; a wrong name on TM_COMMIT is ignored, and on
  TM_ROLLBACK inside a transaction is 6401 with the transaction kept.
* An Attention right behind a TM_BEGIN (2000 tries) left the transaction
  begun 1999 times, the ENVCHANGE in the drained response; a `BEGIN
  TRANSACTION` batch was no different.
* Under MARS the transaction is the SQL session's: any session can begin,
  save, commit or roll back, the ENVCHANGE arrives only on the sending
  session, and a second TM_BEGIN from another session silently nests. A
  `SET` batch waited 2.8 s behind a 3 s `WAITFOR` on another session, and a
  `SELECT` or a TM request 1.8 s behind a 2 s one.
* A commit with another session's stream half read gets 3981 and loses the
  transaction; the stream then delivers every row and ends with 3998. A
  small result completely sent earlier doesn't count, and a running
  `WAITFOR` makes the commit wait 2.7 s and then succeed. A rollback
  succeeds but the server keeps the transaction, doomed, until the stream
  ends.
* The race (a request carrying the descriptor the client still held, sent
  from 800 us before to 1600 us after another session's commit or
  rollback): 5,040 races and never an inconsistency. Of 1800 INSERTs
  against a commit, 1647 ran inside and 153 got 3971 having done nothing;
  of 720 streaming SELECTs against a commit, 300 ended in 3981 with the
  transaction lost and 61 got 3971.
* An outstanding-request count of 0 is error 4011; 1, 2, 3, 7, 99 and
  4294967295 are accepted for ordinary requests, and the true count changes
  nothing for a commit.
* One snapshot transaction on four sessions shows one
  `CURRENT_TRANSACTION_ID()` and one `transaction_sequence_num`. The
  snapshot is taken at the first read of a user table, not at the begin
  (a constant `SELECT` or `sys.objects` doesn't start it), and a session
  opened after outside commits joins it. Sessions see each other's
  uncommitted writes at once; an outside SNAPSHOT reader, or a READ
  COMMITTED reader in an RCSI database, reads the old version without
  blocking. An update conflict (3960) on one session dooms the transaction
  for all.
* The zip (a parent of 100,000 rows and three child tables of about
  250,000 rows, 850,004 rows per run, window 16 with ACK every 2, two
  writers committing about 260 times a second): 102 runs, 11,915 writer
  commits during the reads, no violation, no blocking, deadlock or
  timeout. The controls all had violations: no transaction in 10 of 30
  runs, a READ COMMITTED transaction in 10 of 10, an RCSI database with the
  queries together in 27 of 30, one connection reading in keyset chunks in
  10 of 10. It is the snapshot, not the transaction, that keeps the
  invariant.
* The zip took 0.387 to 0.445 s (1.9 to 2.2 million rows a second) with
  3.9 to 4.4 MiB of live heap; one connection buffering the parents took
  about the same time with 20 to 31 MiB; keyset chunks took 0.61 to
  0.76 s and one `UNION ALL` query 0.58 to 0.61 s. Reading one stream to
  its end first left the other three parked at their windows without harm.
* Within one transaction, a write on one session doesn't block another
  session's open scan of the same table, and the open scan doesn't see the
  write while a statement started afterwards does. Not explained.

### Probe 1: lock waits between sessions

**Question.** Does the server keep streaming session B while a statement
on session A of the same connection waits for a lock that B's open scan
holds, and would a pull lock per session beside the connection lock help?

**Method.** B is a clustered-index scan of 200,000 rows (25 rows a
packet) at window 16; A is a write on another session; a `SELECT 1`
bystander and a plain connection reading the DMVs watch. Varied: how B
was pulled (parked at 1,000 rows, fast, throttled or never), the key's
position against B's locked page, isolation and RCSI, lock hints,
statement types, windows 4, 16 and 64, and a single-thread "for each row,
write" loop; 5 to 8 repeats where it mattered.

**Answer.**

* No. While a request of the connection waits for a lock, the server
  runs none of its other requests: A waits in `LCK_M_IX`, and B waits in
  `TRANSACTION_MUTEX` whenever it wants to run. B delivers only what it
  had already produced, bounded by the window (104, 413 and 1,646 more
  rows at windows 4, 16 and 64), then nothing. A request yields the
  session's mutex only while a SELECT that has filled its window waits for
  the client; a lock wait doesn't yield, and neither does a DML statement.
* With B being read, the lock wait and the mutex wait form a cycle the
  deadlock monitor finds: A was the victim (1205, "generic waitable object
  resources") in 63 of 63 deadlocks, after 0.01 to 4.8 s (median about
  1 s), and B never got an error. With B parked and unread there is no
  cycle, and A waits until `LOCK_TIMEOUT` (1222) or a cancel. The
  single-thread loop never completed in 27 runs: 19 deadlocks and 8 hangs.
* Not blocked, A completing in 1 to 7 ms: inside an explicit transaction
  at any level, with RCSI (B holds only `Sch-S`), a write to another table
  or another page, any SELECT, or B with `ROWLOCK` or `NOLOCK`. Blocked
  (READ COMMITTED autocommit, no RCSI): a row on B's current page (a page
  S lock covers 24 rows), every row under `TABLOCK`, every row B has read
  under `HOLDLOCK`, and range UPDATEs.
* A small B finishes on the server without the client and then holds
  nothing: `TOP (1300)` parked at 1,000 rows was done; `TOP (1450)` was
  not. The margin is what the client read plus about the window.
* A lock held by a third connection stalls everything the same way: A
  waiting 4 s for another connection's row lock froze B and made the
  bystander's `SELECT 1` wait 3.0 s; RCSI didn't change it.
* B as a streaming `UPDATE ... OUTPUT` holds the session until it ends:
  every other request, even a SELECT of another table, waits in
  `TRANSACTION_MUTEX`, and with B never read fails with 3980 after 4.5 to
  10.6 s. This is the one case a pull lock per session would turn from a
  failure into "slow but completes"; it was not built.

### Probe 2: the reset gate

**Question.** After a request that carries RESETCONNECTION is sent, what
must requests on other sessions wait for, what else must be blocked, and
what does the gate cost?

**Method.** Session state (`DATEFIRST`, a `#temp` table and
`SESSION_CONTEXT`) made the order of execution observable. Varied: the
kind of request (batch, RPC or TM begin), the result size (one row or 260
packets), a transaction open or not, the delay between the sends (0 to
3200 us), multi-packet reset requests, the state of the other sessions,
and SYN, FIN and ACK during the reset; 300 trials per cell, 1000 resets
per gate rule under load with `-N4`.

**Answer.**

* Without a gate, a request sent on another session 15 to 190 us behind
  the reset-carrying one was refused with a bare error DONE in 77 to 100%
  of trials, the reset itself was refused (the other request ran first) in
  1 to 19%, and in up to 5% the other request ran to completion before the
  reset although the reset still applied: wire order is not execution
  order. Refusals stayed common up to about 400 us of delay and small but
  present at 1200 to 1600 us, so a time-based rule is unsafe.
* The reset is never lost: when the carrying request was refused, the next
  request on any session carried the acknowledgement (42 of 42).
* After the carrying request's first response packet has arrived and its
  ENVCHANGEs are applied, nothing was refused: 0 of about 4,600 requests
  and 1,000 resets under load, 0 of 1,958 sweep trials, including with a
  260-packet stream still running on the carrying session. A gate lifted
  when the reset request had merely been sent still saw 2,028 refusals of
  4,599. The gate cost 1.32 ms at the median (p90 1.58 ms) and adds about
  0.65 ms to the next request.
* The gate must open after the first packet's tokens are applied, not
  merely after it arrives: a request built before the acknowledgement was
  applied carried the old descriptor and got 3971 (200 of 200), or 3989
  after a TM begin, and a TM begin's new descriptor follows the
  acknowledgement.
* The acknowledgement is always the first token of the first packet of
  the response, after a rollback ENVCHANGE when a transaction was open
  (3,270 first packets peeked, syntax errors and PRINTs included). It
  travels with the first output, so after `WAITFOR DELAY 0.5` it arrived
  at 503 ms. The bit costs the request 0.5 to 0.7 ms to its first packet.
* The bit is honoured when the reset request's first packet arrives, so
  the gate must close before the first packet goes out. Another session
  busy (a stream with nothing read, or a running `WAITFOR`) refuses the
  reset; a fully arrived unread one-packet response doesn't. "Finished"
  on the server means at most window + 1 packets held back: at window 16
  a response of 17 packets lets the reset apply and 18 refuses it.
* An Attention with its acknowledgement read, then the reset: applied
  110 of 110. The reset sent right behind the Attention without waiting:
  refused 50 of 50. SYN, FIN and ACK are handled at the SMP layer
  regardless of the reset; a FIN on an idle session was answered in
  0.68 ms and never refused the reset.

### Probe 3: which pending responses make a commit fail

**Question.** For a commit sent on one session while another session's
request is in each of a list of states, does the commit get 3981, and
which client-side fact predicts it exactly?

**Method.** The spike's script interpreter with new demux counters, READ
COMMITTED transactions begun by TM_BEGIN_XACT, windows 4 and 16 (about
150 paired cases agreed), the boundary at windows 4 to 32, ACK cadences 1
to 8 and packet sizes 512 to 16384, states recorded 300 ms after the
request, and `sys.dm_exec_requests` from a plain connection for the
server's view; 407 cases.

**Answer.**

* What predicts the outcome is the receive side: no 3981 when every other
  session's response has had its last packet received, whatever the
  caller has read of it (92 commits, 10 begins and 52 rollbacks, none
  refused). The caller's position doesn't matter: stopped between two big
  result sets is 3981, stopped between small ones that all arrived is
  fine. RPC streams, several result sets, procedures with OUTPUT
  parameters and a 400 KB OUTPUT value all follow the rule.
* The rule is sufficient, not necessary: a response of exactly window + 1
  packets has no end on the client but is finished on the server, and
  the commit succeeds; window + 2 gets 3981. That held at every window,
  cadence and packet size tried. `sys.dm_exec_requests` predicted every
  case: no row, no 3981 (109 of 109); `ASYNC_NETWORK_IO`, 3981 (63 of 63).
* A request in a statement that doesn't yield makes the commit wait: a
  commit sent 600 ms into a 3 s `WAITFOR` waited 2.4 s and succeeded; a
  `WAITFOR` followed by a 200,000-row SELECT made it wait 1.5 s and then
  fail. A lock wait made it wait until the other session got 1222, then
  commit.
* What the client can't know: an error that already ended the transaction
  (245), unread in another session's response, makes the commit, the
  rollback and even `SELECT @@TRANCOUNT` fail with 3971 until it is read.
* A rollback is never refused; its ENVCHANGE arrives at once and the
  server keeps the transaction doomed until the other response ends with
  3998. A rollback to a savepoint behaves as a commit (3981, the whole
  transaction lost). With `@@TRANCOUNT` 2 the inner commit succeeds and
  only decrements. Outside a transaction, TM_BEGIN_XACT fails with 3988 in
  exactly the states where a commit gets 3981.
* A `COMMIT` or `ROLLBACK` sent as an `sp_executesql` RPC also reports
  error 266. An Attention for a stream parked at its window isn't
  processed until the client reads, so the commit behind it still gets
  3981 (10 of 10); an Attention on a `WAITFOR` ends it at once. A request
  only half sent is invisible to the server. A SYN with a window of 1, 2
  or 3 makes the server close the connection at the first request.

### Probe 4: cancelling a stream inside a transaction

**Question.** Should an abandoned stream inside a transaction be drained or
cancelled with an Attention, and does the answer depend on `XACT_ABORT`
and on how much is left?

**Method.** A table of 1,000,000 rows of about 104 bytes (104 MB on the
wire), window 16, every state once per combination of `XACT_ABORT`, a
bystander idle or streaming, and the cancel method; 20 to 30 runs per
timing point and 100 per Attention-delay point. The local round trip was
0.78 ms during the probe.

**Answer.**

* An Attention on a session whose statement is still executing, under
  `XACT_ABORT ON`, rolls back the whole connection's transaction; under
  `XACT_ABORT OFF` it never does, and a drain never did. After the server
  has finished the statement an Attention is harmless under either. The
  line is at window + 1 packets (at window 16, 1304 rows kept the
  transaction 30 of 30 and 1306 lost it 30 of 30), and the client sees both
  states alike.
* Against a short statement the doom window is the statement's own
  running time: with `SELECT TOP 300` under `XACT_ABORT ON`, the
  transaction survived an Attention 94 times of 100 at 0 us delay, 1 of
  100 at 200 us, and 100 of 100 from 750 us. `XACT_ABORT` is captured when
  the batch starts; setting it off on another session afterwards doesn't
  prevent the doom.
* Cost of cancelling a parked stream (medians of 20): an Attention 0.72 to
  0.97 ms whatever is left, flat from 10 KB to 100 MB; a drain 0.6 ms for
  one packet beyond the window, 1.6 ms for 100 KB, 10 ms for 1.16 MB,
  100 ms for 10.5 MB and 0.97 s for 104 MB, about 105 MB/s at window 16
  or 64 and 56 to 62 MB/s at window 4. Discarding packets without parsing
  was no faster: the wire is the limit. A `WAITFOR 8 s` drains in 7.7 s
  and cancels in about 1 ms.
* After an Attention the server sends one more full packet and then the
  DONE with the ATTN bit, so the Attention reads the whole window (32 KB,
  128 KB or 512 KB at windows 4, 16 and 64). A bystander read
  continuously gave the Attention a tail: median 1.7 to 3.0 ms, with 5 of
  30 runs above 100 ms, unexplained.
* On the server a parked stream is suspended in `ASYNC_NETWORK_IO` with no
  CPU and keeps its locks; a drained one runs and its CPU climbs; after an
  Attention the request is gone at once. A commit beside a parked stream
  gets 3981 under either setting, and the server keeps the locks until the
  stream ends.
* Cleanup with two parked streams: Attentions first and then a rollback is
  clean with `XACT_ABORT OFF`; under ON the first Attention dooms the
  transaction and the rollback gets 3903. Rollback first and then
  Attentions is clean under ON and gives 3998 under OFF. Every order left
  a usable connection with no locks.

### Probe 5: reusing, closing and counting sessions

**Question.** When is a session reusable, what does closing one cost and
require, what does the server do with SIDs, and what does a session cost?

**Method.** The spike's SMP layer with a chosen SID, an optional SYN and a
count of expected FINs; every cycle checked that `SELECT i` returned row
`i`. 35,800 Attention cycles, about 900 error cycles, twelve FIN states on
six fresh connections each, 40 tries per FIN-to-SYN gap, up to 10,000
sessions at once, and idle runs of 7 and 30 minutes.

**Answer.**

* Reuse after an Attention is immediate: 35,800 cycles at windows 4 and
  16, before any response, mid-stream, parked, fully arrived unread,
  alone and beside a stream, with no wrong answer and no stray packet.
  Cancel latency alone was 0.42 to 1.11 ms at the median, and the next
  request 0.4 to 0.8 ms, as after a normal response.
* An Attention is always acknowledged, even with nothing to cancel. One
  sent within about 75 to 300 us of its request isn't acted on until the
  request has finished (39 of 40 slow at 0 us, 0 of 40 at 150 us), on
  plain connections too.
* Reuse after an error-ended response is immediate (about 900 cycles over
  245, 8134, RAISERROR, THROW, severity 19, 1222 and 1205). Severity 19
  leaves the connection alive; severity 20 sends a FIN for the session and
  then closes the connection.
* A FIN for an idle session is answered in 309 to 390 us (3.4 to 3.8 ms
  beside three busy streams, which aren't disturbed). A session never
  used, read, fully arrived unread, cancelled and drained, or partly read
  with the rest queued survives a FIN (6 of 6 each); a FIN for a session
  with a request just sent, a running `WAITFOR`, a stream parked or
  flowing, or an Attention not yet acknowledged closes the whole connection
  5.6 to 7.0 ms later (6 of 6 each).
* A closed SID may be reopened only after the server's FIN has arrived:
  with a wait, 1000 cycles at 537 us each with no problem; without, dead
  at the second cycle, and the first spike's own case closed 7 of 7. Of
  about 800 reopenings after the server's FIN, none failed; of those
  before it, most failed at gaps under about 400 us. A SYN too early with
  the old response undrained let the old incarnation's DATA land on the
  new session.
* SID rules: the first must be 0 (a SYN for 1, 5, 1000, 32768 or 65535
  first closes the connection); a new SID may be at most one above the
  largest used so far, closed ones included; any lower SID may be
  reopened. SIDs walked to 65535 in 4.85 s. The server never closed an
  idle session in 7 or 30 minutes.
* A session costs the server about 35 KB once used (25 KB at the SYN,
  returned by the FIN) and the client 1.1 to 1.5 KB; 10,000 idle sessions
  didn't change another session's round trip. 10,000 sessions with a
  request each were all answered, with no rate limit, the server working
  through them at 0.12 to 0.19 ms each; about 10 requests in flight reach
  the full pipelined rate (339 us per request at 1 in flight, 140 at 10,
  114 to 121 at 100 or more). Closing many at once is superlinear: 3 ms
  for 100, 24 to 88 ms for 1000, 4.2 to 5.6 s for 10,000.

### Probe 6: Azure SQL Database

**Question.** Does the spike's MARS work against Azure SQL Database through
the gateway and after a redirect, with TM requests, with TDS 8.0 and with
an Entra access token, and what does Azure do differently?

**Method.** The spikes' demo and scripts against a Basic-tier database (5
DTUs, 30 workers) in `eastus`, about 45 ms from the client, with the
connection policy switched between Proxy, Redirect and Default; four
tables of 50,000 rows (517 packets, 4.13 MB per stream), the eleven
transaction scripts compared line by line with the local results, and the
snapshot zip at 10,000 parents; timings are medians of three.

**Answer.**

* MARS works in every combination: Proxy and Redirect, `EncryptOn` and
  `EncryptStrict` (the inner PRELOGIN carrying MARS = 1), SQL login and
  access token. On a redirect MARS is negotiated again on the node.
  `connect` took 250 to 335 ms through the gateway and 420 to 490 ms with
  a redirect.
* Azure grants packets of at most 16,192 bytes (16,384 and 32,767
  requested give 16,192), with and without MARS.
* Every local transaction finding recurred with the same error numbers
  and texts; the differences were RCSI effects and the reset's isolation
  level, which RESETCONNECTION sets back to READ COMMITTED on Azure, with
  MARS too.
* The snapshot zip: 100 runs (50 Proxy, 50 Redirect, 20 of them on a token
  login), 8.5 million rows checked, 1,429 writer commits during the reads,
  no violation; the controls had violations in 4 to 10 of every 10 runs.
  The writers committed 6 times a second whatever their number, the Basic
  tier's log rate.
* Over the WAN the window decides: four streams at window 4 took 6.2 s
  and one session reading the tables in turn 24 s, against 1.8 s for four
  plain connections and 1.7 to 2.2 s for one; at window 16, 2.3 s and
  6.3 to 6.6 s; at window 64, 1.9 to 2.0 s and 2.2 to 2.3 s, level with
  plain. A session reads at window x packet size per round trip (4 x
  8000 bytes / 45 ms is 0.71 MB/s), and 16,192-byte packets help in
  proportion. `EncryptStrict` timed the same as `EncryptOn`, and a
  `SELECT 1` was 44 to 46 ms plain and on MARS alike.
* Uploads: a 1,000,000-byte parameter took 1.6 to 2.5 s over MARS at every
  window against 0.24 to 0.25 s plain, because the server's own window
  stays 4 packets ahead (126 packets / 4 x 45 ms is 1.4 s); with
  16,192-byte packets 0.82 s against 0.24 s.
* An Attention beside three streams took 47 ms, one round trip. A stalled
  session held its window while the others finished.
* Each active request takes a worker: with k streams held open on one
  connection, 30 succeed and the rest fail with 10928 (class 20), only
  those requests failing, up to k = 200; at k = 300 the connection was
  closed. Bursts of one-shot requests: up to 280 at once all answered;
  290 and 300 vary from run to run, and from 400 most fail, with 3980 or a
  bare error DONE. Not the request limit and not a session limit (1000
  sessions could each run a query in turn); the cause is unknown.
* A `KILL` sends a FIN on every session, Proxy and Redirect alike. Protocol
  violations give a TCP reset through the gateway and an orderly close on
  the node.
* Idle MARS connections through the gateway survived gaps of up to 21
  minutes, died at 22 and 32 minutes, survived 28 and died at 35, all on
  one gateway address; on the node two 35-minute gaps survived. No clean
  threshold.

### Probe 7: bulk copy

**Question.** Does the bulk load's packet writer work on an SMP session,
and does a load on one session interleave with streams on others, block
them, or get blocked, in and out of a transaction, and when it fails or is
interrupted?

**Method.** Loads of 1,000,000 rows of about 85 bytes (10,611 packets)
into heaps and clustered tables, with and without `TABLOCK`, beside
200,000-row streams on other sessions, with `-N4`, window 16 and
`XACT_ABORT ON` throughout; SMP traces analysed per 250 ms; medians of two
to four rounds, and 48 loads for correctness. The server was shared with
other probes, which inflated a first series three to five times.

**Answer.**

* 48 of 48 loads (plain, SID 0 and SID 1; heap and clustered; with and
  without `TABLOCK`) inserted exactly 1,000,000 rows with the reference
  digest. Alone, SMP costs a load 13 to 19% (a heap 1.66 s against 1.47 s
  plain); the sender waited for the server's window 1 to 25% of the time.
* Beside two full-speed streams on the same connection a load is 5 to 8
  times slower (7.1 to 9.6 s against 1.4 to 1.7 s alone), waiting for the
  window 79 to 93% of the time, while the streams keep 80 to 100% of their
  rate. The same two streams on two other plain connections slowed the
  load by a factor of 2, which is shared server CPU and disk. Streams
  starting during a load cut its progress to about a sixth at once. A
  smaller window on the reader helps the load (5.2 s at window 4 against
  13.7 s at window 16 beside one stream).
* Small requests on another session during a load don't wait for it:
  `SELECT 1` 0.91 ms against 0.75 ms before.
* `XACT_ABORT` must be on when another session holds an open result set,
  even idle after ten rows: with it off the load fails with 595 after the
  whole message was sent. In a transaction, a load and any request on the
  same table conflict with 3970 after all 10,611 packets, and the
  transaction is lost; a stream already open delivers its rows, then 3998;
  a stream of another table is fine. Outside a transaction the same table
  deadlocks (1205, either side the victim, 3 of 3 each).
* A load waiting for a lock stops the whole connection: no packet in
  either direction on any session for the 3.5 s of the wait, although the
  server had 15 packets of credit on a streaming session; a `SELECT 1` on
  another session was answered after 3.95 s. A load waiting for the
  client's data does not do this.
* A failing load (2627 or 547 at row 500,000) is reported only after the
  whole message, is atomic, and doesn't affect the other sessions. An
  interrupted load: a FIN on its session closes the whole connection (3 of
  3); leaving the session alone hangs a later `COUNT(*)` of the table (2 of
  2); an Attention on the session recovers it in 58 to 65 ms with the
  table empty (2 of 2). hmssql breaks the connection instead
  ([design.md](design.md#mars-several-responses-on-one-connection)).

## The server assumptions MARS is built on

The implementation plan listed the server behaviours MARS depends on,
numbered A1 to A43, and the `Mars`, `MarsTx` and `Transaction` tests cite
them by number in their module headers and descriptions, so the numbers
are kept here unchanged. "Live" means pinned against SQL Server 2025;
"Mock" means pinned against the checking SMP mock server
(`hmssql-tests/Mars/MockSmp.hs`); "Azure" means seen by probe 6 with the spike's
request layer, and not by the library's own suite unless said. Where the
implementation found an assumption wrong, the corrected statement is
given, and the correction is noted.

**Negotiation** (`Mars.NegotiationSpec`)

* A1. PRELOGIN MARS = 1 is answered 1 by SQL Server 2025, the Azure
  gateway and the Azure node. Live.
* A2. Under TDS 8.0 the MARS option needs the PRELOGIN inside the TLS
  session. Live.
* A3. SMP starts after the login response. Corrected: the plan said a
  plain batch (the session setup) works between the login response and
  the SYN, as the first spike had recorded; the server closes the
  connection for it, so the setup runs as SMP DATA on session 0. Live, in
  all four encryption modes.
* A4. The server sends nothing in reply to a SYN. Live.
* A5. After a redirect, MARS is negotiated again on the node. Azure, and
  through the library: the MARS tests' connections are redirected (the
  Default policy, from inside Azure) and pass (2026-10-01).

**SMP framing and flow control** (`Mars.FlowControlSpec`,
`Mars.SmpFlowSpec`, `Mars.SmpViolationsSpec`)

* A6. Every DATA payload from the server is exactly one TDS packet; a
  violation is a `ProtocolError`. Live, and Mock for the violation.
* A7. One SMP packet per TLS record is accepted, multi-packet requests and
  strict mode included. Live.
* A8. The server honours an advertised window of 64 and never exceeds it.
  Live.
* A9. The server's own window stays 4 packets ahead of what it has
  consumed, it ACKs every second packet, and a request longer than the
  window completes. Live.
* A10. ACK and FIN carry the sender's current SEQNUM, and WNDW never
  decreases; a violation closes the connection. Mock and Live.
* A11. SEQNUM and WNDW wrap at 2^32. Mock.
* A12. A session nobody reads holds at most `window` packets on the client
  while the other sessions keep flowing. Live.

**Sessions** (`Mars.SessionsSpec`)

* A13. The first SID is 0; a new SID is at most the largest used plus 1,
  and any lower closed SID may be reopened. Live.
* A14. A session is reusable at once after its final DONE, after an
  error-ended response, and after an Attention's acknowledgement. Live,
  in loops.
* A15. An Attention is always acknowledged, in the response's own last
  message or in a message of its own. Live, at both timings.
* A16. A FIN for an idle, drained session is answered by a FIN, and the
  SID is reusable only after that; a FIN for a busy session kills the
  connection, so the library never sends one. Live for the first, Mock
  for the ordering.
* A17. The server never closes an idle session on its own; a server FIN
  that doesn't answer ours means the connection is ending (a `KILL`, or
  an error of severity 20 or more). Live.
* A18. All sessions are one SQL session: `@@SPID`, SET options, `#temp`
  tables, the database and the isolation level, as the requests that
  start afterwards see them. A request that ends writes back the SET
  options, the isolation level and the database it began with, so a
  change made while an older request is running lasts until that request
  ends. Live, both halves.

**Scheduling** (`Mars.SchedulingSpec`)

* A19. The server interleaves row-producing SELECTs across sessions packet
  by packet. Live, with four streams round-robin and every row checked.
* A20. A lock wait, a `WAITFOR` or any other statement that doesn't yield
  stalls every session of the connection. Live.
* A21. Outside a transaction (READ COMMITTED, no RCSI), a write to rows
  under an open scan's locks ends in 1205 or waits for `LOCK_TIMEOUT`;
  inside a transaction, under RCSI or snapshot, for other tables and for
  reads it does not. Live.

**Transactions** (`Transaction.TmBeginSpec`, `MarsTx.TransactionsSpec`,
`MarsTx.HygieneSpec`, `MarsTx.EndingSpec`, `MarsTx.SnapshotSpec`)

* A22. TM_BEGIN_XACT behaves as a `BEGIN TRANSACTION` batch on a plain
  connection: the ENVCHANGE, `@@TRANCOUNT`, the error classes, the doomed
  state, an Attention and a reset. Live, through the existing transaction
  and model tests.
* A23. The isolation-level byte maps 1 to 5 as MS-TDS says, the level
  persists after the transaction, and the commit batch's SET restores
  it. Live.
* A24. A `BEGIN TRANSACTION` batch under MARS fails with 3997. Live.
* A25. The transaction belongs to the connection: every session's request
  must carry the descriptor (0 gets 3989, a stale one gets 3971 with
  INFO 3926), and the ENVCHANGE arrives only on the requesting session.
  Live.
* A26. T-SQL `COMMIT` and `IF @@TRANCOUNT > 0 ROLLBACK` batches work on a
  TM-begun transaction from any session. Live.
* A27. With no session busy (every response read to its end, or cancelled
  and drained), a commit is never refused with 3981 and a TM begin never
  with 3988. Live. The server is more lenient, accepting both once the
  other responses have fully arrived; the library doesn't rely on that.
* A28. A commit with another request unfinished on the server gets 3981
  and loses the transaction, and a TM begin in that state gets 3988.
  Live, through the raw request layer, to pin what the check protects
  against.
* A29. Query hygiene is the caller's: a read started in a transaction and
  not read to its end or cancelled blocks the commit, whatever its size.
  Live: inside `withTransaction`, a `queryS` stream left unread gives
  `TransactionRequestsActive` and nothing is committed, for a one-row
  result that has fully arrived, for a large result parked at its window,
  and for a stream read up to but not past its last row; read to its end,
  cancelled with `cancelResponse`, or opened with `withQueryS`, the same
  body commits.
* A29b. A stream read to its last row but not to the end of its response
  is still busy, because the final DONE is unread. "Read to the end"
  means the stream returned.
* A30. After Attentions on every open response and their
  acknowledgements, the cleanup batch succeeds with `XACT_ABORT` off and
  on. Live.
* A31. An Attention on a still-executing statement under `XACT_ABORT ON`
  ends the connection's transaction; with it off, or once the server has
  finished the statement, it doesn't. Live.
* A32. An error that ends the transaction is reported on its own session;
  other open streams deliver their rows and end with 3998. Live.
* A33. One snapshot transaction is shared by all sessions and starts at
  the first user-table read. Live, as the parent-and-children zip through
  the public API.
* A34. An `OutstandingRequestCount` of 1 is accepted with several requests
  open. Live.

**Reset** (`MarsTx.ResetSpec`, `MarsTx.ResetGateSpec`)

* A35. RESETCONNECTION with every other session idle resets the whole SQL
  session, and the sessions stay open and usable. Live.
* A36. The reset acknowledgement is in the first packet of the carrying
  request's response, among its leading ENVCHANGEs (a rollback, the
  acknowledgement, and for a TM begin the new descriptor). Live.
* A37. No request started after those ENVCHANGEs are applied is refused.
  Live, in a loop over `release`, `renew`, a first request and a second
  request on another session.
* A38. A reset sent while another request is unfinished is refused with a
  bare error DONE; the library prevents it by settling first. Live for
  the prevention, Mock for the refusal.
* A39. SQL Server keeps the isolation level across the bit; Azure resets
  it to READ COMMITTED. Live and Azure.

**Azure** (seen by probe 6; A40 is not yet pinned through the library,
which is on the [backlog](backlog.md))

* A40. Each open response counts against the database's request limit;
  the refused request gets 10928 (class 20) and the connection stays
  usable. Azure.
* A41. Azure grants packets of at most 16192 bytes over TLS (a request of
  16384 or 32767 gets 16192), and window 64 reads at about a plain
  connection's rate over a 45 ms round trip where window 16 reads at a
  quarter of it. Azure. SQL Server 2025 grants 16384, and then closes a
  MARS connection at its first response because the packet and its SMP
  header don't fit one TLS record, so hmssql asks for at most 16368 on an
  encrypted MARS connection.

**Bulk copy** (`MarsTx.BulkCopySpec`, `Mars.SmpSessionsSpec`)

* A42. A bulk load over a session is exact, and a producer failure is
  recovered by an Attention on that session. Live.
* A42b. `INSERT BULK` and its BULK LOAD message must use the same SMP
  session. Assumed from the protocol and not probed: the probe's channel
  held one SID throughout. The library keeps them on one reserved session
  regardless (`Mars.SmpSessionsSpec`).
* A43. With another result set open, a load needs `XACT_ABORT ON` (595);
  in a transaction, a load and another request on the same table conflict
  (3970). Live, as documented behaviour, not prevented.

## Where the implementation departs from the research

The spikes and probes recommended some things the implementation did
differently, and recorded some observations it found wrong. The reasons
are in [design.md](design.md#mars-several-responses-on-one-connection).

* **No channels.** The first spike's design (a record copy of
  `Connection` per SMP session, opened with `openChannel` and
  `closeChannel`) was not built. Each request takes a session and gives
  it back, and the caller never sees one. "Broken" stays connection-wide,
  not per channel, and the weak-pointer reclaim of a dropped stream's
  session was dropped too, since `release` and `cancelActiveStatement`
  settle every session.
* **SMP starts after the login, and the session setup runs inside it.**
  The first spike had recorded a plain setup batch between the login
  response and the SYN as working; the server closes the connection for
  it. The setup runs as DATA on session 0.
* **Window 64 with an ACK every `window / 16` packets**, not the spike's
  16 and 2: over a 45 ms round trip, 16 read at a quarter of a plain
  connection's rate (probe 6).
* **Packets of at most 16368 bytes over TLS.** The spike ran at 8000 and
  never met the limit: at 16384 a packet and its SMP header don't fit one
  TLS record, and the server closes the connection.
* **The packets a window allows go out in one write**, each its own TLS
  record, rather than one send per packet.
* **Transactions.** No exclusive scope with a transaction handle, and no
  transaction-scoped channel opener (spike 2's sections 6.2 and 6.3):
  every request the body makes runs in the transaction. The commit check
  (`TransactionRequestsActive`) is on what the caller has read, not on
  "every other session's EOM received" (probe 3), so a small result that
  has fully arrived but is unread counts too; the begin makes the same
  check, so no old descriptor is kept and no gate orders requests around a
  commit. After a failure the cleanup cancels every open response first
  and then rolls back, not the other way round. There is no savepoint
  API.
* **Abandoned streams get an Attention, in and out of a transaction**,
  not a drain inside one (probe 4's recommendation). A response whose
  last packet has arrived is read to its end locally; otherwise the
  Attention goes out, and under `XACT_ABORT ON` that can end the
  transaction (`TransactionEndedEarly`), the contract a plain connection
  already had.
* **No per-session pull lock** (probe 1's open decision): one connection
  mutex, as before.
* **The reset gate is lazy.** A request that carries the reset first
  settles every other response, and the next request to start reads that
  response's leading ENVCHANGEs first (probe 2's gate, placed at the next
  request rather than at the reset, so nothing waits after a send and an
  interrupted wait is harmless). There is no gate with a session setup,
  whose batch is read in full. A cancelled reset request was found to be
  reset all the same, in 6,000 tries.
* **Idle sessions are capped at ten**, SqlClient's number; the probes
  found nothing that forces a cap.
* **A closed SID is reusable only after the server's FIN** (probe 5); the
  first spike's observation that FIN and SYN could be sent back to back
  was luck of timing.
* **Probe 3's count of "messages sent minus EOM packets received"** can't
  tell a response's end: an Attention's acknowledgement may arrive inside
  the response's own final message or in a message of its own. The
  library keeps two states per response instead, busy (what the caller
  did) and fully arrived (what the reader thread saw).
* **A refused MARS negotiation throws** (`MarsNotSupported`) where
  SqlClient silently falls back: a caller who asked for MARS would
  otherwise get `ResultAbandoned` semantics without knowing.
* **Errors mapped:** of the errors probe 5 and the plan listed, only a
  refused MARS negotiation got an exception of its own;
  `TransactionRequestsActive` prevents 3981 and 3988, and 1205, 3971,
  3989 and 10928 stay `SqlServerError`s.

## What the review found

The five reviews (the wire layer, cancellation, reset, transactions, and
the API with its defaults and documentation) went through the 111 items
of the checklist, each with a verdict and the test that pins it, and ran
the `Live` benchmarks of the MARS commit against its parent. Four items
were real defects, all fixed with regression tests, and one documented
claim was wrong; both are in
[bugs-found.md](bugs-found.md#mars).
The rest were correct as committed or not applicable to the final design.
Eight design questions the reviews raised, such as what names a
multi-statement message in `TransactionRequestsActive`, whether a refused
reset should break the connection, and whether a `Connection` should say
if MARS is on, were answered by the orchestrating session and are recorded
as decisions in [design.md](design.md), for the maintainer to confirm or
overturn. The benchmark showed no line slower beyond the noise once the
one-round outliers were rerun.

## Not verified

What no spike, probe or test has checked, with the backlog entries where
there are any:

* SQL Server 2017 and 2019 with the slow tests: the research was against
  SQL Server 2025, and the suite has since run over MARS on 2022 in the
  test matrix, and on 2017 and 2019 without the slow tests
  ([backlog.md](backlog.md)).
* The request limit (A40) through the library on Azure SQL Database.
  The whole suite over MARS connections (`HMSSQL_TEST_MARS=1`) has passed
  there on S3, without the slow tests
  ([azure-sql.md](azure-sql.md#s3-again-with-the-matrixs-fixes)).
* Whether the server requires a bulk load's data on the same session as
  its `INSERT BULK` (A42b); hmssql keeps them together regardless.
* Windows above 64 over a WAN, and the ACK cadence there
  ([backlog.md](backlog.md)).
* Heaps, joins, parallel plans, cursors and stored procedures as the
  lock-holding scan of probe 1; probe 1 used clustered-index scans.
* The cause of Azure's burst limit (about 300 requests at once refused or
  killing the connection) and of its idle-connection deaths.
