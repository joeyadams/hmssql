# Azure SQL Database ends a MARS connection at an early Attention

Found while running the hmssql test suite against Azure SQL Database
(October 2026). Not reported yet; this is the evidence a report would need.

When Azure SQL Database, under load, reads a request on an SMP session
together with the Attention that cancels it (the Attention sent tens of
milliseconds behind the request, before the server had taken the request
in), it ends the whole MARS connection: it answers the session with a DONE
flagged DONE_ERROR and DONE_SRVERROR and no ERROR token (the answer a
killed session's request gets), sends a FIN for the session, and closes the
TCP connection. Every other request of the connection is lost with it; the
server shows them as `KILLED/ROLLBACK`. MS-TDS lets an Attention follow its
request at any time, and SQL Server 2025 never did this: it acknowledges
such an Attention, or runs the statement to its end first, in thousands of
tries locally and in 1,800 immediate cancels on an idle Azure database.

## Environment

| | |
|---|---|
| Server | Azure SQL Database, Standard S3, East US, connection policy Default (logins redirected to the node) |
| Client | hmssql 0.1.0 (GHC 9.12.4), TDS 8.0 (strict TLS), MARS, from an 8-vCPU Azure Container Instances container in the same region |
| Load | the whole hmssql test suite running beside the case: the database at 94 to 100% of its DTU and log rate, the server's requests in `SOS_SCHEDULER_YIELD` |
| Date | 2026-10-01 |

## What happens

The case is the test `Mars.Random` seed 2 at its step 310, which is the
same sequence every time:

1. SMP session 1 has just become idle (its previous response has arrived),
   and sessions 2 and 3 hold 200,000-row result sets, parked at the
   client's receive window.
2. Step 304 sends `SELECT TOP 5 ...` on session 1 (one DATA packet).
3. Steps 306 to 309 run requests on session 4, which the server answers at
   once.
4. Step 310 cancels the `TOP 5` response: an Attention on session 1, a
   DATA packet inside the server's window.

Normally the server answers the request with a response whose SMP WNDW is
the request's sequence number + 4, and acknowledges the Attention in a
message of its own. In the failing runs no packet came on session 1 between
the request and the Attention, 37 ms in one run and 107 ms in the other,
and the server's first packet after the Attention was an ACK whose WNDW
took in both packets at once. Then came the DONE and the FIN, and the
connection closed.

A trace from the client (seconds since the process started; `out` is sent,
`in` received; SMP flags 8 DATA, 2 ACK, 4 FIN; TDS type 1 SQL batch, 6
Attention, 4 tabular result):

```
102.370917 out sid 1 flags 8 seq 45 wndw 1201 tds type 1 status 1 len 276    -- the SELECT TOP 5
    ...       requests and their responses on session 4
102.407578 out sid 1 flags 8 seq 46 wndw 1201 tds type 6 status 1 len 8      -- the Attention, 37 ms later
102.409396 in  sid 1 flags 2 seq 1137 wndw 50                                 -- ACK: both packets taken in
102.423281 in  sid 1 flags 8 seq 1138 wndw 50 tds type 4 status 1 len 21     -- DONE, status 0x0102
           tail 04 01 0015 0057 01 00 | fd 0201 fd00 00000000 00000000
102.423308 in  sid 1 flags 4 seq 1138 wndw 50                                 -- FIN
102.423315 the TCP connection closed (EOF)
```

The DONE's status 0x0102 is DONE_ERROR (0x2) and DONE_SRVERROR (0x100),
with no ERROR token before it. The second traced run is the same with 107
ms between the request (seq 46) and the Attention (seq 47).

Observed from another connection sampling `sys.dm_exec_requests` every
250 ms, the `TOP 5` never appeared as a request, so the server never
started it. After the close, the parked result sets' requests showed as
`KILLED/ROLLBACK` in `ASYNC_NETWORK_IO`, and session 1's row was gone from
`sys.dm_exec_connections`. The server's own reason could not be read: an
`error_reported` Extended Events session on the database timed out when
read under the load.

## How often

5 of about 140 runs of the seed-2 sequence under whole-suite load (3 Azure
runs, `Mars.Random` seed 2 repeated by 2 to 4 workers beside the suite),
and once `MarsTx.Hygiene`'s rollback with busy sessions, which sends
Attentions on two freshly sent requests beside a parked one. Never without
load. The cancelled reset-carrying requests of `MarsTx.Reset` show what may
be the other outcome of the same overtaking: on Azure 1 to 6 of 100 end
without the reset's acknowledgement, the request discarded rather than the
connection ended.

## Not verified

* Whether other open requests of the connection are needed for the kill
  (they were open every time it happened).
* The server's reason for the kill.
* Whether an Attention held until the server's WNDW shows the request
  taken in would avoid it. hmssql doesn't do that
  ([design.md](../../design.md#interruption-and-cancellation)).

## What hmssql does

Nothing special: the connection is broken cleanly, every stream and the
next request throw `ConnectionClosed`, and a pool replaces the connection
([limitations.md](../../limitations.md#mars)). The tests accept it on Azure
(`Mars.Harness.cancelling`).
