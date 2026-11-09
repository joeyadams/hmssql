# Protocol and server behaviour notes

Facts about TDS, SQL Server, Azure SQL Database, the `tls` package and the
platform that hmssql's code and tests depend on, learned in ms-tds, mssql
and hmssql, each with the conditions it was measured under. Section
numbers refer to [\[MS-TDS\]](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/b46a581a-39de-4745-b076-ec4dbb7d13ec),
and [MC-SMP] is the Session Multiplex Protocol specification. Where an
observation looks like an hmssql bug, it is recorded here so the next
reader doesn't chase it. The decisions taken from these facts are in
[design.md](design.md).

Unless a fact says otherwise, it was measured on SQL Server 2025 on Linux,
in Docker, over TDS 7.4 and 8.0. The servers named below are these:

| Name used here | Build and image |
|---|---|
| SQL Server 2025 | On Linux: RTM (17.0.4075, September 2026), CU8, CU9 (`2025-CU9-ubuntu-24.04`) and CU10 (17.0.5035.5). On Windows 10: RTM (17.0.1000.7), then 17.0.1135.8 (RTM-GDR, KB5122770) and 17.0.1145.4 (RTM-GDR, KB5128492) |
| SQL Server 2022 | CU27 on Linux (`2022-CU27-ubuntu-22.04`) |
| SQL Server 2019 | RTM (15.0.2000.5) on Windows 10, and CU32 (15.0.4500.2) on Linux (`2019-CU32-GDR12-ubuntu-20.04`) |
| SQL Server 2017 | CU31 (14.0.3560.2) on Linux (`2017-CU31-GDR19-ubuntu-18.04`) |
| Azure SQL Database | East US, on the Basic, Standard S3 and General Purpose serverless (`GP_S_Gen5_1`) tiers |

## Framing and packets

* Increment the packet ID (modulo 256) for each packet of a message. The
  RESETCONNECTION status bit goes on the first packet of a message only, not
  again when the ID wraps. A first packet ID of 1 is accepted (SQL Server
  2025 CU10, 2026-10-31).
* Over TLS, each TDS packet must be its own TLS record. SQL Server 2025
  resets a connection whose TLS record holds more than one TDS packet
  (16 KiB records of four 4096-byte packets failed every multi-packet
  request), and handing `TLS.sendData` one large lazy ByteString made the
  server see a truncated packet and close the connection. SQL Server
  likewise sends each packet as its own record. TCP carries no record
  boundaries, so several records may go in one `send` system call; a pipe
  does carry them ([Shared Memory and Named Pipes](#shared-memory-and-named-pipes)).
* SQL Server supports packet sizes 512..32767 and bumps a smaller request to
  512. It may cap a request: 32767 became 16384 on SQL Server 2025, and
  16192 behind Azure SQL Database's gateway. It says so in an ENVCHANGE
  whose values are decimal strings such as `"4096"`. Over TLS a MARS
  connection needs less; see [MARS and SMP](#mars-and-smp).
* A SQLBatch message may have at most 65535 packets (the documented limit is
  "65,536 * network packet size"; exactly 65535 full packets at every packet
  size on SQL Server 2025). A longer one makes the server close the
  connection without an error message. RPC messages have no such limit.
* **The server reads the whole message before it answers.** No answer came
  before the END_OF_MESSAGE packet, for messages up to 500 MB and with
  several kinds of error in them, so a client that sends without reading
  can't deadlock, and a slow source of a parameter delays the earlier
  statements of its own message. An unfinished message, and a row of a
  response half read, both survived at least 15 minutes, plaintext and
  strict, with and without MARS (SQL Server 2025 CU10, 2026-10-31).
* **A message the client cuts short** (no END_OF_MESSAGE) is discarded by
  the server. What ends it:
  * An empty packet with the IGNORE and EOM bits (2.2.3.1.2) makes the
    server answer with a bare DONE (DONE_ERROR, no ERROR token), and it
    performs a RESETCONNECTION carried by the discarded message without
    acknowledging it. hmssql sends no IGNORE packet; an interrupted send
    breaks the connection
    ([design.md](design.md#interruption-and-cancellation)).
  * An Attention leaves the connection usable: 2,400 of 2,400 cut-off
    RPCs and batches, cut after 1 packet, 2 packets and 200 MB, were
    answered with a DONE with DONE_ERROR and then a separate DONE_ATTN
    message. A RESETCONNECTION on such a message was carried out and
    acknowledged (40 of 40, without MARS). A lone Attention was
    acknowledged 800 of 800, in under 0.1 ms at the median (SQL Server
    2025 CU10, 2026-10-31). What a cut-off RPC does to a transaction is
    under [ALL_HEADERS and transactions](#all_headers-and-transactions).
* A session killed while a request runs: SQL Server sends an ERROR of
  severity 20 or more and closes the socket, or just closes it. SQL Server
  on Windows resets the TCP connection or disconnects the pipe instead
  ([Shared Memory and Named Pipes](#shared-memory-and-named-pipes)), and
  Azure SQL Database answers with a DONE and no ERROR token, then a reset
  ([Azure SQL Database](#azure-sql-database)). A client has to tell
  "closed between messages" from "closed in the middle of a message".

## PRELOGIN and encryption negotiation

* The encryption negotiation table (2.2.6.5) has cases the client must
  terminate: an ENCRYPT_NOT_SUP client answered ENCRYPT_REQ or ENCRYPT_ON,
  and an ENCRYPT_ON client answered ENCRYPT_OFF. ENCRYPT_STRICT (0x04) is
  never a valid PRELOGIN answer. A server with encryption off answers
  NOT_SUP to a NOT_SUP client (the OFF answer isn't in the table).
* PRELOGIN option offsets count from the start of the message; an option
  pointing inside the option table is malformed. A response can't
  legitimately be longer than 131070 bytes (0xFFFF offset + 0xFFFF length).
* With ENCRYPT_OFF only the LOGIN7 packet is encrypted, and the login
  response is already plaintext. With ENCRYPT_NOT_SUP from the server,
  nothing is encrypted, password included (its obfuscation is a byte swap
  and XOR).
* **Packets are 4096 bytes until the server grants the requested size**
  (the packet-size ENVCHANGE in the login response), whatever the client
  asked for in LOGIN7. A password login fits in one packet at any size; a
  LOGIN7 carrying an access token is about 5 KB, and Azure SQL Database's
  gateway resets the connection, under either kind of encryption, when it
  arrives as one packet larger than 4096 bytes. SQL Server 2025 accepted
  it. hmssql frames PRELOGIN and LOGIN7 at 4096.

## Federated authentication (Entra ID)

* `connectAccessToken` uses the FEDAUTH feature extension (id 0x02) with
  the "Security Token" library: one options byte (the library, 0x01, in the
  upper seven bits, the server's FEDAUTHREQUIRED answer echoed in the
  lowest), then the token as UTF-16LE with a 32-bit byte length, then the
  server's nonce if it sent one (it only does when the client sent a
  NONCEOPT, which hmssql doesn't). The user name and password are empty;
  fIntSecurity is 0. This is SqlClient's `AccessToken` path; the MSAL
  library (0x02) and its FEDAUTHINFO round trip, where the server names
  the token issuer for the client to go and get one, aren't needed when
  the caller brings the token.
* The client sends FEDAUTHREQUIRED = 0x01 in PRELOGIN (the only value
  MS-TDS allows a client) and must echo the server's answer, so a strict
  connection needs the PRELOGIN inside the TLS session
  ([Strict encryption](#strict-encryption-tds-80)). Azure SQL Database
  answers FEDAUTHREQUIRED = 0x01 under both kinds of encryption.
* A token that Azure SQL Database accepts as a token, but whose identity
  has no user in the database (or isn't the server's Entra admin), fails
  with error 18456, "Login failed for user '<token-identified
  principal>'": the login was parsed and the token validated. A corrupted
  token fails the same way. Sessions logged in this way show
  `auth_scheme` = SQL in `sys.dm_exec_connections`, as SqlClient's do.
  `SUSER_SNAME()` of a managed identity is its client id at the tenant id,
  not its name; `sys.database_principals` has the name, with
  `authentication_type_desc` = EXTERNAL. What it took to set up is in
  [azure-sql.md](azure-sql.md#entra-id-and-managed-identity).

## TLS hosted in TDS (TDS 7.x)

* The client's handshake records are wrapped in TDS packets of type 0x12.
  Each handshake flight must be exactly one TDS message. The `tls` package
  flushes in the middle of a flight (after ChangeCipherSpec), so hmssql
  buffers records and flushes them only before a read. Mitsuji's ms-tds had
  found the same by trial ("wrapping each record separately doesn't work").
* SQL Server offers only TLS 1.2 in the hosted modes.

## Strict encryption (TDS 8.0)

* TLS 1.2 or 1.3 directly on the socket with ALPN `tds/8.0`, then ordinary
  TDS packets inside TLS. Packet framing does not go away. LOGIN7 carries
  version `0x08000000`, which the server acknowledges. (The 2025 mssql
  work had kept sending 7.2 inside strict TLS, and had dropped the
  framing and ALPN, after a first attempt got "PostHandshake Error_EOF";
  the cause was several packets in one TLS record.)
* MS-TDS describes a PRELOGIN inside the TLS session ("the encryption value
  sent by the client is ignored"), and SqlClient sends one. SQL Server 2025
  and Azure SQL Database accept LOGIN7 right after the handshake, without
  it. hmssql sends an inner PRELOGIN, with ENCRYPTION = ENCRYPT_ON, only
  when it needs the answer, for an access token or MARS.
* A server (or a wrong port) that answers the TLS ClientHello with a TDS
  packet makes tls read the packet header as a record header and wait for
  the rest forever. The first byte must be 0x16 (handshake) or 0x15 (alert).
* **ALPN.** SQL Server 2025 selects `tds/8.0` whenever it is offered,
  closes the connection without a ServerHello when only other protocols
  are offered (`h2` and `http/1.1`), and completes the handshake with no
  ALPN extension when the client offers none, so it does not require ALPN
  of the client. Measured on 2026-10-13 with `openssl s_client` against
  SQL Server 2025 CU9 with a self-signed certificate, TLS 1.3 in each
  handshake that completed. Azure SQL Database's gateway answered the same
  three ways the same day, from a workstation, TLS 1.3, with the gateway's
  certificate validated, and a strict hmssql login there succeeded with
  the selection checked. So did the strict logins of whole suites against
  SQL Server 2025 17.0.1145.4 on Windows over TCP on 2026-10-16. hmssql
  requires the selection ([design.md](design.md#encryption-and-tls)).
* **SQL Server 2022 on Linux has no strict encryption.** It answers a TLS
  ClientHello with ALPN `tds/8.0` by closing the socket, and its error log
  says "Error: 17821 ... A valid TLS certificate is not configured to
  accept strict (TDS 8.0 and above) connections", whatever the
  certificate. Measured on 2026-10-02 with SQL Server 2022 CU27 and five
  certificates: a self-signed one for `localhost` and the container's
  name, one carrying the server-authentication key usage, one issued by a
  CA installed in the container's trust store, one matching the
  container's host name, and one with
  `SQLSERVR_SSL_CERTIFICATE_DNS_OR_SUBJECT_NAME` set. TDS 7.4 with TLS
  from PRELOGIN works with each. Its `network.tlsprotocols` allows 1.0 to
  1.2 by default, and `1.3,1.2` makes every login time out instead. SQL
  Server 2025 CU9 accepts strict connections with the same self-signed
  certificate, allowing TLS 1.0 to 1.3 by default. The `mssql-docker`
  repository's issue 878 reports the same of 2022 since 2024, with no fix.
* **SQL Server 2019 and 2017 have no TDS 8.0.** They answer a TLS
  ClientHello by closing the socket, so the client sees only "the server
  closed the connection", and the error log says "Error: 17832, Severity:
  20, State: 2. The login packet used to open the connection is
  structurally invalid". Measured on 2026-10-08 over TCP with SQL Server
  2019 RTM on Windows 10, whose certificate TDS 7.4 with TLS from
  PRELOGIN (`EncryptOn`) validates, and on 2026-10-14 with SQL Server
  2017 CU31, where `EncryptOn` with the test matrix's self-signed
  certificate validates.

## The tls package

* An asynchronous exception inside `TLS.recvData` corrupts the TLS session
  ("bad record mac"). hmssql reads the socket on a dedicated thread.
* tls turns every backend exception during the handshake into
  `HandshakeFailed` with only the exception's text, and reports the end of
  the stream as `HandshakeFailed Error_EOF`. The server closes or resets
  connections during the handshake under load (a Docker accept-queue
  overflow, [Platform and tooling](#platform-and-tooling)), so the
  handshake's backend records the first real exception.
* tls 2.4.4 ("Enforce server certificate purpose") refuses a server
  certificate whose extended key usage excludes server authentication after
  the `onServerCertificate` hook, whatever the hook decided. hmssql needs
  tls 2.4.4 or later, so this always applies.
* tls 2.4 appends the TLS secrets to the file named by `SSLKEYLOGFILE` when
  that variable is set (`defaultKeyLogger`); hmssql sets `debugKeyLogger`
  to a no-op.
* tls before 2.4.7 (over crypton before 2.1, which has no AES-NI GCM
  decryption) makes a TLS record 2 to 3 times as expensive: 8.9 µs of
  client CPU to receive a small record with tls 2.1.8, and 4.5 µs with
  2.4.8. Stackage `nightly-2026-11-03`, which `stack.yaml` uses, has tls
  2.4.6 over crypton 1.1.5, the slow pair.
* tls 2.5 replaced the (hash, signature) pair of `supportedHashSignatures`
  with one IANA number, `SignatureScheme`, with a pattern synonym for each
  name. `HashSHA1`, `HashAlgorithm` and `SignatureAlgorithm` are gone, so
  hmssql filters the signature schemes under CPP. tls 2.5.1 still offers
  `rsa_pkcs1_sha1` and `ecdsa_sha1` by default, as 2.4 does, though RFC 9155
  forbids them. With the filter turned off, a handshake with the mock TLS
  server signed with `ecdsa_sha1` succeeded (2026-11-08).
* tls 2.5 refuses a server certificate whose RSA key is shorter than 2048
  bits or longer than 8192 (`supportedMinRSAKeySize` and
  `supportedMaxRSAKeySize`). As with the key usage check, this happens after
  the `onServerCertificate` hook, whatever the hook decided. On 2026-11-08,
  a mock with a self-signed 1024-bit RSA certificate was accepted with
  `tlsTrustServerCertificate` under tls 2.4.6 and refused under tls 2.5.1.
  The other 2.5 changes that could refuse a server don't apply to hmssql:
  the bounds on a Diffie-Hellman prime only matter for DHE suites, which
  `ciphersuite_default` doesn't offer, and hmssql uses no channel binding,
  PSK, early data or client certificate.
* tls has no client setting to refuse server-initiated renegotiation (SQL
  Server doesn't renegotiate).
* **Small records and pinned blocks.** Over TLS with small packets (512 to
  2048 bytes), each record's plaintext is a small pinned object allocated
  in the same pinned blocks as tls's and crypton's short-lived objects,
  about four of which per record carry a finalizer (memory's
  `ScrubbedBytes`). GHC frees such a block only once every object in it is
  dead, and a finalizable object is found dead only at a major GC, which
  keeps the block once more for the finalizer. Keeping the packets of a
  large value live therefore kept several times its size live until two
  major GCs later: a 32 MiB value at 512-byte packets kept about 180 MiB.
  hmssql copies small chunks into arenas of its own
  ([design.md](design.md#who-owns-a-packets-bytes)).

## Shared Memory and Named Pipes

Measured on SQL Server 2025 RTM on Windows 10, a default instance, on
2026-10-03, unless a bullet says otherwise; the probes, and what the
Windows side of each was seen to do, are in
[windows-research.md](windows-research.md). SQL Server on Linux listens on
TCP only.

* **Shared Memory is a local named pipe.** The server listens on
  `\\.\pipe\SQLLocal\MSSQLSERVER` for Shared Memory and on
  `\\.\pipe\sql\query` for Named Pipes, and its error log names both at
  startup. For a named instance the documented names are
  `\\.\pipe\SQLLocal\<instance>` and
  `\\<host>\pipe\MSSQL$<instance>\sql\query`; these were not measured.
  Because the name carries the instance, a named instance needs no SQL
  Server Browser lookup over a pipe.
* **The bytes are the same as over TCP:** PRELOGIN, the TLS handshake of
  either kind, and LOGIN7. `EncryptStrict`, `EncryptOn`, `EncryptOff` and
  `EncryptNotSup` all work, with and without MARS.
  `sys.dm_exec_connections.net_transport` reports `Shared memory` or
  `Named pipe`.
* **The server reads a pipe one write at a time.** In plaintext a write
  must hold whole TDS packets, any number of them. Over TLS a write must
  hold exactly one TLS record. A write that splits a packet or a record,
  or carries two records, makes the server drop the connection, and the
  client's next read or write fails with `ERROR_PIPE_NOT_CONNECTED`.
  This holds from the first byte: under strict encryption, a connection
  whose TLS handshake records were cut at 1000 bytes got no further than
  its third write.
* **On a MARS connection in plaintext the unit is the SMP packet.** A
  DATA packet written as two writes, its 16-byte SMP header and then its
  TDS packet, made the server drop the connection at the first request
  after the login, under `EncryptOff` (where only LOGIN7 is encrypted)
  and `EncryptNotSup` alike: the client's next receive failed with
  `ERROR_PIPE_NOT_CONNECTED`. A SYN, a 16-byte write that is a whole SMP
  packet, works, and so does each DATA packet as one write. Measured over
  both pipes against SQL Server 2019 RTM on Windows 10 on 2026-11-06.
  Over TLS the header and packet travel in one record, and over TCP the
  boundaries don't matter, so neither was affected.
* **The server needs to identify the pipe's client.** A handle opened
  with `SECURITY_ANONYMOUS` had its logins over Named Pipes refused with
  error 18456, state 10. `SECURITY_IDENTIFICATION` and the default,
  `SECURITY_IMPERSONATION`, both work.
* **A pipe is closed whole, or disconnected.** When one end closes its
  handle, the other end's receive gets what was sent and then the end of
  the stream (`ERROR_BROKEN_PIPE`, 109), whether it was pending or came
  later, and its send fails with `ERROR_NO_DATA` (232), "The pipe is
  being closed". There is no closing of one direction, as a socket has.
  When the server end disconnects (`DisconnectNamedPipe`), the client's
  receive and send both fail with `ERROR_PIPE_NOT_CONNECTED` (233), "No
  process is on the other end of the pipe", and what the client had not
  read is lost. hmssql reports the first as `ClosedByServer` and the
  second as a transport failure. Measured between two ends of a pipe of
  hmssql's own, under the default I/O manager and under GHC's native one.
* **SQL Server disconnects.** When it dropped a connection (for a write
  that split a packet, when it refused a login, and when another session
  killed this one with `KILL`), the client saw error 233, the
  disconnect. So a killed session's next request fails with
  `ConnectionClosedBy (TransportFailed ...)` over a pipe, where over TCP
  on Linux it fails with `ClosedByServer`. The `KILL` was measured over
  Shared Memory with `EncryptOn`.
* **SQL Server on Windows resets a killed session's TCP connection.**
  Over TCP to the same server, the request after a `KILL` failed with a
  reset where SQL Server on Linux closes in an orderly way: `ReadFile`
  on the socket gave `ERROR_NETNAME_DELETED` (64), which hmssql reports
  as Winsock's `WSAECONNRESET`, a `TransportFailed`. Measured with
  `EncryptOn`.
* **While every instance of a pipe is in use, opening it fails** with
  `ERROR_PIPE_BUSY` (231), at once.
* **The server refused some first connections after an idle spell** on
  the measured machine, and stopped listening on the pipe for up to a
  minute (errors 17827 and 26050 in its log), for Microsoft's client as
  well. The cause is unknown; builds 17.0.1135.8 and 17.0.1145.4 showed
  no stop in the runs made on them
  ([windows-research.md](windows-research.md#the-servers-pipe-listeners)).

## LOGIN7 and login

* String fields are located by 16-bit offsets and lengths; strings totalling
  over about 64 KiB wrap them. The server applies its own 128-character
  limits.
* The `fODBC` flag (with `fSetLang`, `fDatabase`, `fUseDB`, `fLanguage`)
  makes the login state ANSI_NULLS, QUOTED_IDENTIFIER, ANSI_PADDING,
  ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL and ANSI_NULL_DFLT_ON on;
  NUMERIC_ROUNDABORT, IMPLICIT_TRANSACTIONS and CURSOR_CLOSE_ON_COMMIT off;
  TEXTSIZE -1 (unlimited). ARITHABORT is off. Both kinds of reset turn
  those options back on, including one turned OFF during the session.
* LOGINACK's ProgName is "Microsoft SQL Server" followed by four NULs.
* "Cannot open user default database" (4064) and "Cannot open database
  requested by the login" (4060) are fatal login errors on SQL Server 2025,
  not the fallback-to-master with an INFO message older documentation
  describes. Azure SQL Database says 916 instead
  ([Azure SQL Database](#azure-sql-database)).
* The UTF-8 feature extension is acknowledged in FEATUREEXTACK by SQL
  Server 2019 and later. SQL Server 2017, which has no UTF-8 collations
  (`COLLATE Latin1_General_100_CI_AS_SC_UTF8` is error 448, "Invalid
  collation"), leaves it out of FEATUREEXTACK, so `tdsUtf8Support` is
  `False` there (SQL Server 2017 CU31, 2026-10-14).
* A session takes about 75 ms to log in over strict TLS and 48 ms in
  plaintext against SQL Server 2025 in Docker on a Mac, almost all of it
  server-side; a round trip afterwards is 0.35 ms.
* A failed login is written to the error log with the login's name, and
  when that name holds a character outside the BMP (`probe_𝄞`),
  `sp_readerrorlog` (and `xp_readerrorlog`) stops at that entry and returns
  nothing logged after it, until `sp_cycle_errorlog` starts a new log.
  Names with accented letters or CJK characters do not do it. Measured on
  2026-10-25 on SQL Server 2025 CU10, with sqlcmd's failed logins as
  `probe_ascii`, `probe_ünï`, `probe_日本` and `probe_𝄞`, each followed by
  a `RAISERROR ... WITH LOG` marker that only the last hid. A tool that
  counts failed logins in the error log reads 0 after it.

## Tokens and ENVCHANGE

* ENVCHANGE values come new first, then old. Transaction ENVCHANGEs carry
  B_VARBYTE values (a length prefix of 8, then a ULONGLONG); parsing them as
  UTF-16 text breaks every later query. The spec's table and notes disagree
  about which side carries the descriptor for types 11, 12 and 17;
  Microsoft's drivers accept it on either side, as does hmssql.
* Type 12 is Defect Transaction (new value), not a second Enlist. Type 15
  (Promote Transaction) is sent with Length 1, the type byte only, and its
  L_VARBYTE value follows outside the declared length. Type 20 (Routing) has
  a two-byte empty old value (`0x00 0x00`, 2.2.7.9), unlike the one-byte
  empty values of the other types.
* ENVCHANGE 18 (reset acknowledgement) and 10 (transaction ended) both end
  the tracked transaction; the server sends 10 before 18 when a reset rolls
  a transaction back.
* SQL Server always ends a response with a final DONE, DONEPROC or
  DONEINPROC without DONE_MORE. A DONE-family token with DONE_ATTN inside
  a cancelled response is the acknowledgement (SqlClient agrees).
* **An Attention cuts a result short between tokens, never inside one.**
  After an Attention, the acknowledging DONE with DONE_ATTN can arrive in
  a separate message after the END_OF_MESSAGE of the interrupted
  response, so the drain has to keep reading. In 807 cancellations of SQL
  Server 2025 CU9 (plaintext, 2026-10-13, every byte received copied) the
  cancelled message always ended at a token boundary with a DONE whose
  status was DONE_ERROR, every value whole, and the acknowledgement was
  always a message of its own, one packet holding only a DONE with
  DONE_ATTN. That held for rows of 300 to 1,100 bytes straddling packet
  boundaries at packet sizes 512 to 32767, for 2 MB and 3 MB values with
  the server blocked on back-pressure inside a value when the Attention
  arrived, for a `WAITFOR DELAY` after a result set, and for Attentions
  sent from an asynchronous interruption of the reader. In 324 more
  trials with 64 MiB values (CU10, 2026-10-31) the message always ended at
  a token boundary, and the server finished the whole row after the
  Attention, its later values included. So a cancelled message that ends
  inside a token is a framing error, and hmssql's `ProtocolError` on it
  is right. Not measured: MARS, Azure SQL Database and SQL Server 2022.
* NBCROW (0xD2) is sent only to a TDS 7.4 client, for rows with enough
  NULLs; SQL Server 2025 never sends it to a TDS 8.0 client. NULLs appear
  in ROW tokens too.
* An ORDER token holds one USHORT per column.
* RETURNVALUE tokens for `(max)`-typed output parameters are sent after all
  the others, whatever the RPC order; ParamOrdinal (0-based position in the
  RPC parameter list) is the only reliable pairing, since names are empty
  for positional parameters. A scalar function's return value (fUDF) comes
  first.
* `FOR BROWSE` (or `SET NO_BROWSETABLE ON`) appends the key and timestamp
  columns and marks them hidden only in COLINFO (status 0x10), not with
  COLMETADATA's fHidden bit.
* COLMETADATA table names can have several parts; ms-tds parsed them
  wrongly.

## ALL_HEADERS and transactions

* From TDS 7.2, SQLBatch and RPC requests start with ALL_HEADERS: 22 bytes
  holding a transaction descriptor header (type 2) with the 8-byte
  descriptor and an outstanding-request count of 1. It appears once at the
  start of an RPC request, not once per RPC in a multi-RPC message, and
  must carry the current descriptor or the server fails with "New request
  is not allowed to start because it should come with valid transaction
  descriptor".
* The separator between RPC requests in one message changed from 0x80 to
  0xFF in TDS 7.2, which also widened UserType to 32 bits, the DONE row
  count to 64 bits and the ERROR/INFO line number to 32 bits.
* **Transaction Manager requests** (packet type 0x0E) work on a plain
  connection as well, and are interchangeable with T-SQL on one
  transaction: TM_BEGIN_XACT, then a T-SQL `COMMIT`, `SAVE TRANSACTION` or
  `ROLLBACK TRANSACTION name`, and the other way round. The ENVCHANGEs, the
  errors that end a transaction (245 and 2714 roll back, 2627 and syntax
  errors don't, `XACT_ABORT`, the doomed state and 3998), Attention and
  RESETCONNECTION all behave as for a T-SQL-begun transaction. The
  ISOLATION_LEVEL byte of TM_BEGIN_XACT is 0 (no change), 1 to 4 (READ
  UNCOMMITTED to SERIALIZABLE), or 5 (SNAPSHOT); 6 or 255 is error 3995
  and nothing is begun. The level it sets outlives the transaction, after
  commit and rollback, as a `SET` does, and the RESETCONNECTION bit keeps
  it too. TM_SAVE_XACT with an empty name is 3977 and rolls the
  transaction back; a rollback to a savepoint with the chained-begin flag
  is 3978 and rolls it all back (MS-TDS says the flag is ignored). A
  wrong name on TM_COMMIT is ignored, and on TM_ROLLBACK inside a
  transaction it is 6401 with the transaction kept. Without a
  transaction: commit 3902, rollback 3903, save 628. A begin and commit
  pair costs 8 to 17% less time than the same pair as batches (422 to
  448 µs against 481 to 529 µs locally), the server's parse work, but no
  round trip ([mars-research.md](mars-research.md#spike-2-transactions-and-a-shared-snapshot)).
* `XACT_STATE()` is 1 inside a statement that reads `sys.dm_exec_sessions`
  even with no transaction open (the statement runs in its own autocommit
  transaction); read it into a variable first.
* `ROLLBACK TRAN savepoint` consumes the savepoint and every newer one;
  rolling back to it again is error 6401.
* A doomed transaction is rolled back by the server at the end of the
  body's batch, before any COMMIT, so a COMMIT that fails with the
  transaction still open couldn't be provoked live.
* Error classes (which errors abort the batch, which roll back, which only
  under XACT_ABORT) are tabulated in the header of `hmssql-tests/Model/Machine.hs`.
  A conversion error (245) rolls back even without XACT_ABORT.
* An Attention arriving within about a millisecond of a SELECT inside a
  `SET XACT_ABORT ON` transaction is treated as a cancel and rolls the
  transaction back; the next statement runs in autocommit.
* **A cut-off RPC can roll back a transaction.** With `XACT_ABORT` off, an
  RPC message cut short and then cancelled rolled back an open
  transaction at some cut positions, by error 4002 or 3980 with a
  rollback ENVCHANGE, with no rule a client can use; a batch never did in
  200 positions (SQL Server 2025 CU10, 2026-10-31). So a transaction body
  that catches its parameter source's exception either commits or gets
  `TransactionEndedEarly`, and the tests accept both.
* `BEGIN TRANSACTION` can't ride in an RPC: `sp_executesql N'BEGIN
  TRANSACTION'` fails with 266 and leaves the transaction open; a `COMMIT`
  or `ROLLBACK` sent as an `sp_executesql` RPC reports 266 as well. In
  front of a SQL batch it can (`BEGIN TRANSACTION; ...` on one line),
  except before a statement that must be first in its batch (error 111),
  where the whole batch fails to compile and nothing runs; any compile
  error likewise. Those statements are `CREATE` and `ALTER` of a
  `PROCEDURE`, `VIEW`, `FUNCTION` or `TRIGGER`, and `CREATE SCHEMA`,
  `DEFAULT` or `RULE`. A runtime error after the BEGIN leaves the
  transaction open, as after a separate BEGIN (245 rolls it back, as
  always). `SET TRANSACTION ISOLATION LEVEL` inside `sp_executesql`
  reverts when it returns, so the level too can only go in front of a
  batch.
* **An Attention that reaches the server before a batch starts cancels all
  of it.** With `BEGIN TRANSACTION; SELECT 1` sent and abandoned at once
  (a `queryS` stream dropped, the next request's Attention right behind
  it), the BEGIN didn't run in 2 to 12 of 2000 tries on SQL Server 2025.
  A batch cancelled later (mid-WAITFOR, mid-result) keeps the
  transaction. A batch that would have failed is cancelled the same way,
  with its consequences: in a `SET XACT_ABORT ON` transaction, a `SELECT`
  from a table that doesn't exist (208) rolls the transaction back when it
  runs, and abandoned at once it may not run. How often depends on the
  server's version far more than on its load (2026-10-05, plaintext,
  packet sizes 8000 and 32767 alike, the test matrix's containers beside
  three runs of the suite). SQL Server 2022 CU27 left the transaction
  open 299 times in 300, and 15,960 times in 16,000 with 8 connections at
  once: an Attention right behind a request nearly always stops it before
  it starts there. SQL Server 2025 CU9 never did in 16,300, and the one
  installed on the Linux development machine did once in 96,000 with 48
  connections at once and never in 6,000 idle. With the Attention 20 ms
  behind the request, the batch had run every time on both (300 each).
  This is one reason `withTransaction` sends its begin as a request of its
  own and reads the response before the body runs
  ([design.md](design.md#transactions)).
* **A commit waits for the log flush, and that costs what the disk
  costs.** With SQL Server 2025 on Linux (ext4 on a Samsung 990 PRO), an
  `INSERT` of one row that commits took 5.1 to 5.4 ms, measured inside one
  batch and from the client alike. The session's wait statistics put it on
  the flush that follows each log write: 5.1 ms a commit in
  `PREEMPTIVE_OS_FLUSHFILEBUFFERS`, and 0.1 ms in `WRITELOG`. A 4 KiB write
  with `O_DSYNC` on that filesystem took 5.0 ms. The same `INSERT` into a
  `#temp` table took 0.05 ms, and a `SELECT 1` round trip 0.06 ms. `COMMIT
  WITH (DELAYED_DURABILITY = ON)` changes nothing in a database whose
  `DELAYED_DURABILITY` is `DISABLED`, the default. So one connection
  commits about 190 times a second there, however fast the client is, and
  a test must not assume a rate of commits beside a rate of reads (October
  2026). What a commit costs in Docker on macOS was not measured.

## Session state and reset

* Both `sp_reset_connection` and the RESETCONNECTION bit return the session
  to its state right after LOGIN7: SET options, TEXTSIZE, language, date
  format, DATEFIRST, lock timeout, deadlock priority, the database after
  `USE`, CONTEXT_INFO, SESSION_CONTEXT, `#temp` tables, global cursors,
  locks and session-owned applocks, and an open transaction. They differ
  in one thing: `sp_reset_connection` resets the isolation level to READ
  COMMITTED, and the bit keeps it on SQL Server. Azure SQL Database resets
  it either way ([Azure SQL Database](#azure-sql-database)).
* `sp_reset_connection`'s reset of the level appears deferred to the next
  request: `SET ... READ UNCOMMITTED; sp_reset_connection; reset` then any
  request sees READ UNCOMMITTED again (20 of 20 runs), while any request in
  between sees READ COMMITTED.
* `EXEC sp_reset_connection` from T-SQL fails ("Invalid object name"); it
  exists only as an RPC.
* A reset-carrying request that is cancelled is reset all the same, with
  and without MARS ([MARS and SMP](#mars-and-smp) has the 6,000 tries).
* `USE [db]` inside an RPC (`sp_executesql`) changes the session's database
  for good (with INFO 5701), unlike `EXEC sp_executesql N'USE ...'` in a
  batch and unlike SET options, which revert when the RPC returns. `SET
  LANGUAGE` inside an RPC sends no 5703. A `#temp` table created inside an
  RPC is dropped when the RPC returns.
* `SET PARSEONLY` and `SET NOEXEC` take effect from the next batch, not
  later in the batch that sets them; constant folding still raises a
  divide-by-zero in that batch. Under `NOEXEC ON`, a SELECT from a
  nonexistent table is not an error (name resolution is deferred). `SET
  STATISTICS XML/PROFILE ON` appends a plan result set only when the
  statement touches a table.
* `OUTPUT` without `INTO` on a table with a trigger is refused up front
  (error 334).
* **SQL Server 2019 RTM runs a stale plan against a `#temp` table.** The
  plan of an ad hoc batch over a `#temp` table is cached under the
  session's id (`optional_spid` in `sys.dm_exec_plan_attributes`), so a
  later session that is given the same id and sends the same text finds
  it. When that session's table has the same name and other columns, the
  server sometimes does not recompile, and reads the new rows with the old
  plan. What follows is one of several things: error 682 at severity 22
  ("Buffer provided to read column value is too small"), an assertion with
  a stack dump (`_retypesbase.inl` line 380, on a `sql_variant`'s version
  byte, as error 3624), error 17310 or 7884 in the server's log, error
  8114 ("Error converting data type numeric to nvarchar") for a `tinyint`
  column, a connection the server closes, or a response whose rows don't
  fit their COLMETADATA, which hmssql reports as a `ProtocolError`.
  Measured on 2026-10-09 on Windows 10 with the suite's
  `Differential.Decode`, which fills a `#t` of random columns named `c1`,
  `c2` and so on fifty times and sends `SELECT [c1], ... FROM #t ORDER BY
  _rid` for each: it failed in 3 runs of 15 alone in plaintext, in about
  a quarter of the whole-suite runs in plaintext, and with one seed under
  TLS as well. One table of fifteen columns then failed on every replay
  through hmssql, with and without TLS, until the 14 cached plans of that
  one statement were removed (`DBCC FREEPROCCACHE` with each plan's
  handle), after which it passed. The same script passed through
  `sqlcmd`, whose SET options give it cache entries of its own, and with a
  permanent table in place of `#t`. On SQL Server 2019 CU32,
  `Differential.Decode` passed in each of the eleven matrix runs of
  2026-10-14, two of them in plaintext; at RTM's rate that is not enough
  to say the cumulative update fixed it. SQL Server 2022 and 2025 passed
  the same tests in the matrix.
* With `LOCK_TIMEOUT 0`, a `DELETE` (one `sp_executesql` call) from the
  session's own, empty `#temp` table, inside a transaction begun by a TM
  request, with no other request of the connection open and the monitor
  connection idle, failed once with 1222 in a whole-suite run over MARS
  on 2026-09-30. What it waited for is not known. It didn't recur in
  6,000 such deletes, plain and MARS, beside 16 connections creating,
  filling, deleting from and dropping `#temp` tables, with ghost records
  left in the deleting session's table (32-core Linux, 2026-10-01).

## MARS and SMP

hmssql implements MARS (`connectMars`; the design is in
[design.md](design.md#mars-several-responses-on-one-connection)). These
facts come from two spikes and seven probes on 2026-09-29 and 2026-09-30
([mars-research.md](mars-research.md) has their questions, their answers
and the conditions of each measurement), from the implementation's tests
and probes since, and from the test matrix, against SQL Server 2025 over
TDS 7.4 and 8.0 unless a bullet names another server. Azure SQL Database
behaves the same, with the same error numbers; what it adds is in
[Azure SQL Database](#azure-sql-database).

* MARS is asked for with the PRELOGIN option MARS (0x04) = 1, and the
  server answers 1. Under TDS 8.0 it needs the PRELOGIN inside the TLS
  session, which hmssql otherwise sends only for an access-token login.
* **SMP starts after the login**, not before: PRELOGIN, TLS, LOGIN7 and its
  response as plain TDS, and only then the client's SYN for the first
  session (SID 0), with every later request as SMP DATA. A SYN followed by
  LOGIN7 as SMP DATA makes the server close the connection without a
  reply. MS-TDS doesn't say where SMP starts. **After the login response
  the server accepts nothing but SMP**: a plain TDS batch (a session
  setup) sent before the SYN makes it close the connection, although the
  first spike had recorded that order as working. hmssql sends the SYN,
  starts its reader, and then runs the session setup as DATA on session 0.
  This order works in all four encryption modes; with ENCRYPT_OFF the SMP
  traffic after the login is plaintext. The server sends nothing in reply
  to a SYN.
* Each TDS packet travels as one SMP DATA payload; the 16-byte SMP header
  is outside the TDS header, and over TLS one record carries one SMP packet
  (the one-packet-per-record rule still holds). Over a pipe in plaintext
  each SMP packet must be one write
  ([Shared Memory and Named Pipes](#shared-memory-and-named-pipes)). An
  Attention is an ordinary DATA packet on the session of the request it
  cancels.
* **Packet size over TLS.** SQL Server grants TLS connections packets of
  at most 16384 bytes (a request of 16400 to 32767 gets 16384, one of
  16384 gets 16192), and then closes a MARS connection at its first
  response: a TDS packet of that size and its 16-byte SMP header don't fit
  one TLS record, in either direction. Sending the header in a record of
  its own didn't help. hmssql asks for at most 16368 on a MARS connection
  unless the encryption is `EncryptNotSup`; without TLS, 32767 works.
* **Flow control.** The server takes a receive window (WNDW) far above
  MC-SMP's 4 (tested up to 100,000) and runs that far ahead on the
  session: the window is the client's memory bound. Its own window stays
  4 packets ahead of what it has consumed, whatever the client
  advertises, and it ACKs every second packet it consumes. With several
  sessions busy it sends one DATA packet per session in turn. A SYN with
  a window of 1, 2 or 3 makes the server close the connection at the
  first request.
* **Violations close the TCP connection with no error:** a SYN for a live
  SID, a shrinking WNDW, DATA beyond the server's window, a SYN for a SID
  more than one above the largest used on the connection, a SYN for a
  closed SID sent before the server's FIN for it has arrived, and a FIN
  for a session whose request the server hasn't finished.
  * The first SID must be 0, and a lower SID may be reopened. "Used"
    includes sessions still closing: a SYN for SID 30 sent right behind
    FINs for 10 to 29, not yet answered, was accepted 200 times in 200.
  * A SYN for a closed SID sent before the server's FIN failed in most
    tries at gaps under about 0.4 ms; the SYN alone is enough.
  * The unfinished requests whose FIN closes the connection were a stream
    parked or flowing, a `WAITFOR`, an Attention not yet acknowledged and
    a half-sent bulk load.
* **Sessions.** A FIN for an idle session is answered with a FIN in about
  0.35 ms (3.5 ms beside busy streams), which frees the SID. A server-side
  `KILL`, or an error of severity 20 or more, sends a FIN on every session
  and then closes the connection (with several streams open, one of them
  may first get error 3980, a batch aborted because another request is
  running in the same session); the server never closed an idle session
  on its own (30 minutes). SIDs reached 65,535; 10,000 sessions at once
  answered, with no rate limit, at about 35 KB each on the server once
  used.
* A session is reusable at once after its response's final DONE, or after
  the DONE with the ATTN bit that acknowledges an Attention; an Attention
  sent when the response has finished still gets its own acknowledgement.
  An Attention does interrupt a `WAITFOR` and a lock wait: cancelling a
  response parked in either and reading to the acknowledgement
  (`cancelActiveStatement`) took about 0.3 s.
* **SQL Server 2025 ignores an Attention that arrives before the statement
  is under way**, plain connections too: the statement runs to its end,
  and the acknowledgement follows its whole result in a message of its
  own. Measured with a `SELECT` (`WITH (READCOMMITTEDLOCK)`, of a table
  made for each try, so compiled each time) that waits for a lock another
  connection holds, and the cancel's wait ended by that connection's
  rollback after 3 s (CU9, 2026-10-15): an Attention sent right behind the
  request was ignored 51 times in 60 over MARS and 54 in 60 plain, idle;
  5 ms behind, never; and sent once the server showed the lock wait,
  never in 240, idle or loaded. Beside two runs of the test suite it was
  ignored 56 and 58 times in 60 right behind, 2 and 13 in 60 at 5 ms, up
  to 5 in 30 at 20 ms, and 1 in 30 at 100 ms: a loaded server takes
  longer to get the statement under way. SQL Server 2019 and 2022, idle,
  acted on every one (0 of 360 each, the same three timings), and so did
  SQL Server 2017 (0 of 300, at 0, 1, 5, 20 and 100 ms). Over MARS the
  server takes such an Attention in all the same: its session reads it
  (`num_reads` of the session's row in `sys.dm_exec_connections` counts
  it) and its SMP window moves past it
  ([The server under load](#the-server-under-load) has the packet
  timings). The spike's probe 5 had seen the same on SQL Server 2025 RTM:
  one sent within about 75 to 300 µs of its request was not acted on
  until the request had finished.
* **Under MARS, the physical connection's row of `sys.dm_exec_connections`**
  (`net_transport` `TCP`) stops counting at the login: 4 reads and 4
  writes, its `last_read` and `last_write` from the login, whatever the
  sessions do. Each SMP session's row (`Session`) counts its own DATA,
  not its ACKs: `num_reads` 2 for two one-packet requests on a session
  that also sent 1,700 ACKs, and `num_writes` 1,710 for the 1,700 packets
  of its response. `sys.dm_exec_sessions.last_request_start_time` didn't
  move for a MARS session's later requests either (SQL Server 2019 and
  2025, 2026-10-15).
* **All sessions of a connection are one SQL session:** the same `@@SPID`;
  SET options (the isolation level, `XACT_ABORT`, `LOCK_TIMEOUT`,
  DATEFIRST), `#temp` tables and `USE` made on one are seen by the
  requests that start afterwards on the others, in and out of a
  transaction. `sys.dm_exec_connections` shows one row with
  `net_transport` = `Session` per SMP session and one `TCP` row
  (`parent_connection_id` NULL) for the physical connection, all with the
  same `session_id`.
* **Requests on different sessions are not run in the order they were
  sent.** In a transaction under `XACT_ABORT ON`, a `SELECT` from a table
  that doesn't exist was sent on one session and `SELECT @@TRANCOUNT` on
  another right behind it: the second ran first, and found the
  transaction open, 84 times in 2,000 on SQL Server 2022 and 241 on SQL
  Server 2025; sent 2 ms later, 3 and 20 times (the test matrix's
  containers beside three runs of the suite, 2026-10-05). Once the first
  response had been read to its end, the rollback was always done (3,000
  of 3,000 on each).
* **The settings belong to the request that ends last.** A request starts
  with a copy of the session's settings and writes its copy back when it
  ends, whatever happened meanwhile. With a stream too long for the
  window open on one session (its request still running), a batch on
  another session changed a setting, later requests saw the change, and
  when the stream was read to its end the setting was back to what it
  was when the stream began. Undone so: the isolation level,
  `XACT_ABORT`, `NOCOUNT`, `LANGUAGE`, `LOCK_TIMEOUT`, `TEXTSIZE`,
  `DATEFIRST`, `CONTEXT_INFO` and the database (`USE`). Not undone:
  `SESSION_CONTEXT` and a `#temp` table. Cancelling the older stream
  undoes them as reading it does. A request that has ended on the server
  undoes nothing later, read or not: a stream of 50 rows left unread
  changed nothing when it was read. The same on SQL Server 2025 CU9 and
  2022 CU27, 2026-10-05; Azure SQL Database was not tried. Whether the
  server tells the client that the database or the language went back
  (an ENVCHANGE) was not looked at.
* **A statement that doesn't yield stops every session.** A batch or TM
  request on one session waits while such a statement runs on another: a
  `SELECT` waited 1.8 s behind a `WAITFOR`, a `SET` batch 2.8 s.
  Row-producing SELECTs yield; MARS interleaves, it doesn't run statements
  side by side. A lock wait doesn't yield either: while a statement on one
  session waits for a lock (held by another connection, or by a scan open
  on another session of the same connection), every other session stops,
  including streams already running (they deliver only what the window
  lets them send ahead; their requests wait in `TRANSACTION_MUTEX`).
* **A write that meets the lock of a scan open on another session**,
  outside a transaction at READ COMMITTED without RCSI, never completes.
  The deadlock monitor kills the write (1205, 0 to 5 s) once the scan's
  session has window to send again (it then waits for the connection, a
  cycle the server can see), or the write waits for `LOCK_TIMEOUT` (1222)
  while the scan is parked at its window, where the server sees nothing
  wrong. With one thread and the scan parked, the implementation's test
  got 1222 after a `LOCK_TIMEOUT` of 2 s every time, never 1205: the only
  thread that could read the scan is the one waiting for the write.
  Inside one transaction (any level), with RCSI, for writes to other
  tables and for any SELECT, it doesn't happen. A streamed `UPDATE ...
  OUTPUT` holds the session until it ends; other requests fail with 3980
  after seconds unless it is read.
* **Transactions.** A `BEGIN TRANSACTION` batch fails under MARS with
  error 3997 ("A transaction that was started in a MARS batch is still
  active at the end of the batch") and is rolled back; a Transaction
  Manager request (TM_BEGIN_XACT) works. Its begin ENVCHANGE arrives only
  on the session that sent it, and a commit's only on the session that
  commits, but the transaction is the connection's.
  * Another session sending the descriptor sees `@@TRANCOUNT = 1` and the
    uncommitted rows; one sending 0 while it is open fails with 3989; and
    one sending a committed descriptor fails with 3971 (with INFO 3926),
    having done nothing.
  * Any session can save, roll back to a savepoint, commit or roll back,
    by TM request or by a T-SQL batch. A T-SQL `BEGIN TRANSACTION` inside
    an open transaction is a nested begin (`@@TRANCOUNT` 2), and a
    TM_BEGIN_XACT from a second session joins the open transaction
    silently the same way. So 3997 is for a batch that begins the
    outermost transaction.
  * Under `IMPLICIT_TRANSACTIONS ON`, DDL or DML in a batch fails with
    3997 the same way and is rolled back, unless the batch commits what
    it began.
  * The outstanding-request count in ALL_HEADERS can stay 1 with several
    requests outstanding. 0 is error 4011, and a TM commit carrying 2 or 3
    fails with 3981 even with nothing else active, so the true count buys
    nothing.
* **Commit with another session's request unfinished** fails with 3981
  ("pending requests working on this transaction") and an ENVCHANGE
  rollback: the transaction is lost. That holds for a T-SQL `COMMIT`
  batch too. The client can predict it exactly: no 3981 when every other
  session's response has had its last packet (EOM) received, whatever the
  caller has read of it (RPC streams, several result sets, output
  parameters and error responses alike). The converse is nearly exact: a
  response at most one packet longer than the window has finished on the
  server and doesn't count, and a statement that doesn't yield (a
  `WAITFOR`, a lock wait) makes the commit wait, then succeed. A rollback
  to a savepoint gets 3981 the same way and rolls back the whole
  transaction; a plain rollback is never refused. Outside a transaction,
  TM_BEGIN_XACT fails with 3988 in the same states, and leaves the stream
  intact. An error that ended the transaction, sitting unread in another
  session's response, makes every request fail with 3971 until it is read.
  The 3981 is deterministic once the stream's statement is running; a
  COMMIT sent right behind the stream's request, before its statement has
  started, can be run first and succeed. After a 3981 the stream still
  delivers every row and then ends with 3998. hmssql doesn't rely on the
  server's rule: it refuses a begin or commit while any response is
  unread, whatever has arrived
  ([design.md](design.md#mars-several-responses-on-one-connection)).
* **Rollback, or an error that ends the transaction** (245, `XACT_ABORT`,
  update conflict 3960), while other sessions stream: the rollback
  ENVCHANGE arrives at once, but the server keeps the transaction, doomed,
  until the other requests end. Their streams deliver every row and then
  end with error 3998 and a second ENVCHANGE rollback (a stream whose
  response had fully arrived before the error ends without one);
  meanwhile a request carrying the old descriptor is accepted (reads work,
  writes fail with 3930) and one carrying 0 fails with 3989. With
  `XACT_ABORT ON`, cancelling one session's stream (an Attention) rolls
  back the whole connection's transaction when the statement is still
  executing on the server; with it off, the transaction survives, and
  draining a stream never loses it. `XACT_ABORT` is captured when a batch
  starts: turning it off on another session afterwards doesn't prevent
  the doom. Draining runs at the connection's rate (about 105 MB/s
  locally) and keeps the statement executing; an Attention costs one
  round trip.
* Inside one transaction, a write on one session doesn't block another
  session's open stream over the same table, and that stream doesn't see
  the write (it did not in READ COMMITTED or SNAPSHOT); a statement
  started afterwards does. Without a transaction, the same UPDATE was
  blocked by the open scan's locks.
* **Snapshot isolation is shared by the sessions of one transaction.**
  With `TM_BEGIN_XACT` at level 5 (or `SET TRANSACTION ISOLATION LEVEL
  SNAPSHOT` and a begin at level 0), every session has the same
  `CURRENT_TRANSACTION_ID()` and reads the same snapshot, including a
  session opened, or a statement started, after an outside connection
  committed changes; each session sees the others' uncommitted writes at
  once, while an outside SNAPSHOT or RCSI reader sees the old version
  without blocking. The snapshot is taken at the transaction's first read
  of a user table, not at the begin (a change committed between the two
  is seen; a constant `SELECT` or `sys.objects` doesn't start it),
  inferred from behaviour, since `first_snapshot_sequence_num` stayed
  NULL. In 102 runs of a parent table and three child tables read on four
  sessions and zipped, while other connections committed about 11,900
  changes (about 260 commits a second), there was no inconsistency;
  without the snapshot (READ COMMITTED or RCSI, with no transaction or a
  READ COMMITTED one), between a third and all of each control's runs had
  some.
* **RESETCONNECTION** with no other request active resets the whole SQL
  session (every session sees it).
  * With another session's request still active (unfinished by the same
    measure as for a commit), the request carrying the bit fails with a
    bare DONE with the error bit and no ERROR token, and so does every
    later request on the other sessions, until the active request is
    cancelled; the reset is then applied, and its acknowledgement arrives
    on whichever response comes next.
  * A request sent on another session right behind the reset request
    races it: the server may run either first, whatever the order on the
    wire, and it takes the bit from the first packet of the request.
  * The reset acknowledgement (ENVCHANGE 18, after a rollback ENVCHANGE
    when a transaction was open) is always in the first packet of the
    reset request's response. Nothing sent on another session after that
    first packet's ENVCHANGEs were applied was ever refused (over 10,000
    requests); the bit costs the request about 0.5 to 0.7 ms.
  * **A reset-carrying request that is cancelled is reset all the same.**
    In 6,000 tries (batch, RPC and TM begin requests, the Attention sent
    0, 0.1, 0.3, 1 and 3 ms behind the request, with and without MARS)
    the reset acknowledgement was in the cancelled response every time,
    the session state was reset, and the next response carried no
    acknowledgement. A cancelled TM begin had usually begun its
    transaction as well (its begin ENVCHANGE was in the cancelled
    response).
  * FINs for idle sessions sent just before the reset-carrying request
    don't count as active requests: in 400 tries (200 without a session
    setup and 200 with one), a closing session, its FIN sent and the
    server's not yet read, never made the server refuse the reset. That
    is evidence, not proof.
* A bulk load over an SMP session is described under
  [Bulk load](#bulk-load).

## RPC and stored procedures

* Parameter names are B_VARCHAR (at most 255 UTF-16 code units on the
  wire); the server's own limit is 128 (error 8005). A procedure name is a
  USHORT-length string. A 65535-byte value of a USHORT-length type would
  carry the NULL marker as its length; an empty value of a BYTE-length type
  reads as NULL.
* The server matches RPC parameter names ignoring trailing spaces, NULs and
  format characters (`"@x "` matches `@x`); a name without `@` fails with
  error 201 ("expects parameter '@x'"). In an `sp_executesql` declaration
  it accepts BMP letters, marks, digits and letter numbers it knows (it
  rejects about 4200 newer ones), `@`, `#`, `$`, `_`, and also format
  characters, connector punctuation and a bare `@`; none of its whitespace
  characters. An injected statement in the declaration is refused with
  error 4124.
* Error 119 ("must pass parameter number N as '@name = value'") is an
  EXEC-statement parser rule, not enforced over RPC: a positional parameter
  after a named one binds to its ordinal among the unbound ones.
* An RPC caps at 2100 parameters (error 8003), independently of the
  procedure's arity (error 8144 for too many arguments), and the cap is
  per RPC, not per message. A parameterized query has at most 2098 (two
  are `sp_executesql`'s own).
* **Several RPCs in one message** (0xFF between them): each RPC's response
  ends with a DONEPROC, DONE_MORE and DONE_RPCINBATCH (0x80) set on all but
  the last; a procedure an `sp_executesql` body EXECs reports DONEINPROC
  tokens, not a DONEPROC of its own. An error that only ends its statement
  (2627, 8134, RAISERROR) or its call (208, deferred name resolution) lets
  the next RPC run; a runtime batch abort (THROW, 245) ends the message
  there (DONEPROC with DONE_ERROR and no DONE_MORE), and so does any error
  under `XACT_ABORT`, rolling back. `Shapes.ExecuteMany` pins the parts
  hmssql relies on.
* `RAISERROR` doesn't honour `XACT_ABORT`: a procedure can set its
  outputs, return rows, raise at severity 16 and go on writing, with the
  transaction still committable, where a `THROW` ends the procedure and
  rolls the explicit transaction back, leaving earlier autocommit
  statements stored (SQL Server 2025 CU8).
* Numbered procedures (`name;1`) can no longer be created on SQL Server
  2025. `USE` inside a procedure body is a compile error (154).
* `RAISERROR(..., 20, 1) WITH LOG` needs sysadmin; the server closes the
  session afterwards.
* **A table-valued parameter can be sent with the current exports**,
  without a change to the library. Measured on SQL Server 2025 with a
  `Request` of type `PTRpc` whose body writes `rpcRequestBuilder ctx
  [RpcRequest procSpExecuteSql 0 [stmt, decl]]`, with `decl` being `@p1
  dbo.T READONLY`, followed by the parameter written by hand:
  * its name, status 0 and the type byte 0xF3;
  * three B_VARCHARs, an empty database, the schema and the type name;
  * a column count of 1, and for each column a user type (4 bytes of 0),
    flags (2 bytes of 0), `writeTypeInfo` and an empty name;
  * a 0x00 ending the optional metadata;
  * each row as 0x01 and its `writeValue`s, and a final 0x00.

  `SELECT SUM(n), COUNT(*) FROM @p1` over the int rows 1, 2, 3 and 40
  returned 46 and 4.

## Data types

### On the wire

* The [COLMETADATA specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/58880b9f-381c-43b2-bf8b-0727a98c4f4c)
  assigns `UserType` 0x50 to `timestamp` (`rowversion`), values above 0xFF
  to alias types, and zero otherwise (a specification fact, not a server
  measurement). `columnSqlType` can therefore tell a tagged `rowversion`
  from its binary storage. An alias ID alone does not name the alias; a
  catalog lookup is needed for that.
* GUIDs store the first three groups little-endian (fixed in ms-tds
  0.4.0.1). An nvarchar parameter's declared length is its UTF-16 byte
  length, not `T.length * 2`; surrogate pairs break the naive version.
* NULL parameters: TDS 7.1 rejected a declared max length of 0xFFFF; from
  7.2 on, 0xFFFF means `(max)` and a PLP NULL is valid. A NULL
  `sql_variant` is sent and received with length 0 (2.2.5.5.4), not the
  0xFFFFFFFF of other LONGLEN types; 0xFFFFFFFF is accepted on read.
* **PLP.** A PLP value starts with an 8-byte total length
  (`0xFFFFFFFFFFFFFFFF` NULL, `0xFFFFFFFFFFFFFFFE` unknown), then
  length-prefixed chunks and a zero-length terminator; an empty value is
  the total and the terminator with no chunk. Client chunks are at most
  8000 bytes.
  * SQL Server 2025 sends the total for every value tried (columns,
    `REPLICATE`, `CAST`, `STRING_AGG`, `FOR JSON`), except `xml` (a `CAST`
    to it, `FOR XML ... TYPE`) and the native `json` type, which come with
    the unknown length.
  * The server's chunks end at packet ends: the first fills the rest of
    its packet (7966 bytes at 8000-byte packets, 2014 at 2048). In
    `nvarchar(max)` a chunk can be odd, and a chunk boundary can split a
    surrogate pair or a UTF-8 sequence, so a streaming text decoder holds
    bytes back.
  * The server takes an unknown-length PLP parameter in an RPC: 288 RPCs
    with no failure, of `varbinary(max)`, `nvarchar(max)` and `xml`,
    through `sp_executesql` and a procedure call, several among small
    parameters, at packet sizes 512, 8000 and 16384 (granted as 16192),
    plaintext and strict, with and without MARS. It joins a parameter's
    chunks before it reads them, so a client's chunk boundary inside a
    code unit is harmless; an odd `nvarchar(max)` total gets error 8028,
    class 16, and the connection stays usable.
  * A total is not limited to 2^31-1: a parameter of 4 GiB + 1 bytes had
    a `DATALENGTH` of 4294967297, and `SELECT @a` returned it with a PLP
    total of 0x80000001. Storing it is error 7119, class 16, and the
    connection survives.
  * The last three were measured on SQL Server 2025 CU10 on 2026-10-31;
    SQL Server 2017 to 2022, Azure, Windows and a real network were not
    measured.
* Use PLP only for values over the non-max limits (4000 characters, 8000
  bytes): declaring every parameter `(max)` makes it a LOB type, which
  affects plans and implicit conversions. The default TEXTSIZE of 4096
  truncates `(max)` values (irrelevant with `fODBC`, which makes it
  unlimited).
* `text`, `ntext` and `image` values carry a text pointer (length 0 for
  NULL), 8 bytes of timestamp, a 4-byte length and the value unchunked.
* CLR UDT values (`hierarchyid`, `geometry`, `geography`) are always sent
  as PLP, whatever UDT_INFO's MAX_BYTE_SIZE says, in columns and in a
  scalar function's RETURNVALUE.
* `decimal`/`numeric` values may be 5, 9, 13 or 17 bytes long whatever the
  precision: a 4-byte magnitude for a `decimal(10,0)` zero read from a
  table, a 16-byte one for a `decimal(1,0)` inside a `sql_variant`.
  SqlClient accepts any multiple of 4.
* money's sign lives in the high DWORD; ms-tds had it in the low one.
* Below TDS 7.3 the date/time types arrive as text; Azure SQL Database
  honours the negotiated version.
* `json` and `vector` (SQL Server 2025) come to a TDS 7.4 or 8.0 client
  as character types. Measured in September 2026, `json` came as
  `nvarchar(max)`; on 2026-10-31 (CU10) it came as `varchar(max)` under a
  UTF-8 collation, with an unknown total. Which builds or settings differ
  was not established.
* `SESSIONPROPERTY` returns `sql_variant`; an unsupported property returns
  NULL (which mssql failed to decode).

### Conversions on the server

* **Date and time** conversions round half up, exactly, and carry into
  the next day: `CAST(datetime2(7) '2000-01-01 23:59:59.9999999' AS
  datetime2(0))` is 2000-01-02. `time` clamps; rounding past 9999-12-31
  clamps to the maximum; `smalldatetime` fails from 2079-06-06 23:59:30
  on; `'23:59:60'` is rejected; datetimeoffset offsets beyond ±14:00 and
  values outside the range in UTC or local time are rejected. `1752-12-31
  23:59:59.999` is a valid `datetime` (it rounds to 1753-01-01). At the
  top of the range, `9999-12-31 23:59:59.9999999` converts from
  `datetime2(7)` to `datetime` by clamping to the last 1/300 s tick, and
  from `datetimeoffset(7)` with the same local time by overflowing (error
  242), at offset zero as well as at +14:00; `datetime2(7)` to
  `datetime2(0)` clamps to 23:59:59 (SQL Server 2025 CU8). `SqlValue` has
  no duration type because `time` can't exceed 24 hours.
* **Floating point.** NaN and either infinity are refused as an ordinary
  floating parameter (error 8023), with a `bit` destination too. Positive
  and negative zero convert to 0, and the smallest positive and negative
  subnormals of `real` and `float` convert to 1, through `INSERT` and bulk
  copy alike. A `Double` negative zero inserted into `real` keeps its sign
  bit (0x80000000 read back as bytes), though SQL equality can't tell it
  from positive zero (SQL Server 2025 CU8).
* Money converts to an integer type by rounding half away from zero
  (`1.5` to `2`, `-1.5` to `-2`); decimal and float fractions truncate
  toward zero. A float of exactly `-2^63` converts to `bigint`, and `2^63`
  is refused. Conversions to a narrower decimal round half away from zero
  on the server (`Data.Decimal.roundTo` is banker's).
* **`sql_variant`** keeps its source column's base type, precision,
  scale, declared length and collation: `smallmoney` stays `smallmoney`,
  `numeric` stays `numeric`, a `datetime` keeps its 1/300 s fraction, and
  a bounded `char`, `nchar` or `binary` keeps its fixed length and
  padding, as `SQL_VARIANT_PROPERTY` reports. A `sql_variant` `nvarchar`
  keeps the lone surrogates its source held. `ALTER DATABASE CURRENT
  COLLATE` changes the collation a later `nvarchar` parameter or bulk
  value takes as a `sql_variant`: a scratch database changed from
  Greek_CI_AS to SQL_Latin1_General_CP850_CI_AS, and the variants written
  after it carried the new collation, plain and over MARS, without a new
  connection (SQL Server 2025 CU8).
* **Collations and code pages.** A `varchar` formal of `sp_executesql`
  takes the database's default collation. Applying `COLLATE` after a cast
  from binary to `varchar` transcodes the bytes; assigning a binary
  literal to a `varchar` column of the intended collation keeps all 256
  byte values (Greek_CI_AS, Cyrillic_General_CI_AS and
  SQL_Latin1_General_CP850_CI_AS, SQL Server 2025 CU8). In single-byte
  code pages, undefined bytes convert to the C1 control of the same value,
  or to a private-use character in 874, 1253 and 1255. SQL collations map
  to a code page by sort ID, Windows collations by LCID.
* **Unicode validity.** `nchar`/`nvarchar` data is never validated: the
  server stores lone surrogates (`NCHAR(0xD800)`) and truncated pairs,
  and `nvarchar` and `ntext` storage keeps an unpaired unit. A `_UTF8`
  varchar column stores most ill-formed UTF-8 (from a varbinary
  conversion), and the server's own conversion to nvarchar makes U+FFFD
  by Unicode's maximal-subpart practice, except that a lead byte with an
  out-of-range continuation (`E0 80`, `ED A0`, `F0 8F`, `F4 90`) is one
  U+FFFD; a sequence truncated at the very end is trimmed on store. A
  varchar *parameter* with ill-formed UTF-8 is sanitized (`?`) or rejected
  (9833). An `nvarchar` parameter holding `x`, one unpaired surrogate and
  `y` converts into a `_UTF8` `varchar` as `78EFBFBD79`, the unpaired unit
  replaced by U+FFFD; a valid pair converts as itself (SQL Server 2025
  CU8).
* **Fixed-width parameters.** A short `char(n)`, `nchar(n)` or `binary(n)`
  RPC parameter is padded to its length before it is assigned to a
  variable-width column; an empty fixed parameter pads too, and an empty
  variable value stays empty (SQL Server 2025 CU8). To see `ntext` bytes,
  cast through `nvarchar(max)`: a direct cast to `varbinary` fails with
  error 529.
* **`xml`.** A parameter's encoding is sniffed from its bytes: a
  text-only document such as `a` in UTF-16 without a byte order mark is
  misread (error 9420). Converting a literal to xml drops a leading
  U+FEFF. The server canonicalizes a value: with whitespace preserved,
  `<r>  </r>` can come back as `<r> &#x20;</r>`, so compare the extracted
  text, or the server's own canonical form, not the input.
* The native `json` type refuses some numbers that JSON text accepts
  (`[1e40]`, error 1007 on the SQL Server 2025 build tested).
* **What a parameter's declaration changes**, measured with `Text` and
  `ByteString` parameters on SQL Server 2025 at the default session
  options. `LEN(@p1 + @p2)` with two values of 3000 characters is 4000,
  with no error or warning; 5000 and 3000 give 8000, and `CAST(@p1 AS
  nvarchar(max)) + @p2` with two of 3000 gives 6000. `DATALENGTH(@p1 +
  @p2)` of two 6000-byte values is 8000, or 12000 with the cast. Inserting
  into `sql_variant` takes the 3000-character value and refuses the
  5000-character one and the NULL with error 206. `SELECT COUNT(*) FROM #s
  WHERE k = @p1`, with `k` an `nvarchar(100)` primary key of 2000 rows,
  cached two plans for one statement, `nvarchar(4000)` and
  `nvarchar(max)`, and the NULL reused the `(max)` plan. Both plans used
  an index seek.
* **NULL conversion reach**, from probing NULLs of many declared types
  against every column type: `varchar` reaches the most (91 of 105
  cases), `nvarchar(4000)` 89, `nvarchar(max)` 86, and `sql_variant` 25.
  No string type converts to `binary`/`varbinary`. `varbinary(8000)`
  reaches everything `varbinary(max)` does, and `sql_variant` too. Both
  are refused by `text`, `ntext`, `float`, `datetime2`, `date`, `time`,
  `datetimeoffset`, `vector` and `json`.
* **Temporal tables:** a version's period runs between the begin times of
  the writing transactions, and the clock is coarse enough that an INSERT
  and UPDATE in quick succession usually produce a zero-length history
  row, which every `FOR SYSTEM_TIME` form, even ALL, leaves out. A visible
  generated temporal column is marked read-only in COLMETADATA, as the
  hidden period columns are.
* A `SELECT *` view that isn't schema-bound keeps its old column list
  after a base column is dropped and added back at the end, so an old
  name can address a different base column of the same width. `INSERT`
  and `INSERT BULK` agree on that stale binding, and `sp_refreshview`
  updates both the names `SELECT TOP 0` reports and the insert mapping
  (SQL Server 2025 CU8).

## Bulk load

Measured on SQL Server 2025 CU8 unless a bullet says otherwise.

* **A zero length is NULL** for a BYTE-length numeric cell and for a
  `sql_variant`: a load that sent an empty non-NULL payload into a
  nullable `int`, `datetime2` or `sql_variant` column stored the column's
  default without `KEEP_NULLS` and NULL with it. An empty character,
  binary, `xml` or legacy text value is stored as an empty value.
* `INSERT BULK` with a native `xml` column in its COLMETADATA fails with
  error 4816. Declared `varbinary(max)`, the bytes reach the XML parser
  with their byte order mark or encoding declaration (UTF-8, UTF-16LE,
  UTF-16BE and Latin-1 were tried, into a typed `xml` column too), where
  declared `nvarchar` the unmarked UTF-8 bytes were read as UTF-16 text,
  itself valid XML content.
* `INSERT BULK` refuses source metadata that is nullable for a NOT NULL
  column with error 4816, even when the column has a default.
* **`ORDER` is checked per batch.** `INSERT BULK ... ORDER(id ASC)` into a
  table with a clustered primary key refuses the rows [2,1] with error
  4819, with and without TABLOCK; into a heap the same load is accepted
  and the hint changes nothing. In batches of two, [1,2,4,3] keeps the
  first batch outside a transaction, and a wrapper rolling back loses the
  destination and trigger writes of both; the globally unsorted [1,3,2,4]
  succeeds because each batch is sorted. ORDER is not a request for the
  client to sort the input.
* **Permissions** (SQL Server 2025 CU10, 2026-11-08, a login with INSERT
  on the table and nothing else). `INSERT BULK` into a table with a check
  constraint and no trigger was refused with error 5304, "ALTER TABLE
  permission is required on the target table of a bulk copy operation if
  the table has triggers or check constraints, but 'FIRE_TRIGGERS' or
  'CHECK_CONSTRAINTS' bulk hints are not specified", with no hint, with
  `FIRE_TRIGGERS` alone, and with `CHECK_CONSTRAINTS` alone it succeeded;
  with both it succeeded, and with `TABLOCK` or `KEEP_NULLS` added too.
  Into a table with neither constraint nor trigger (an identity column
  only) the load succeeded with no hint and with `TABLOCK`, and
  `KEEP_IDENTITY` was refused with error 1088 ("does not exist or you do
  not have permissions"). Granting ALTER on the table made the hintless
  load into the constrained table succeed. hmssql's column discovery, a
  `SELECT TOP 0 ... FROM` the table, needs SELECT on it (error 229);
  `DescribedColumns` sends no such query.
* **A load without `CHECK_CONSTRAINTS` marks the table's check
  constraints not trusted** (`is_not_trusted` in `sys.check_constraints`
  went from 0 to 1 after a one-row load with no hints), `ALTER TABLE ...
  WITH CHECK CHECK CONSTRAINT` set it back to 0, and a load with
  `CHECK_CONSTRAINTS`, and a plain `INSERT`, left it at 0 (SQL Server 2025
  CU10, 2026-11-08).
* **Triggers.** A load with `FIRE_TRIGGERS` fires an insert trigger once
  per client batch, the short last batch included, and `INSTEAD OF
  INSERT` triggers too. A trigger that throws rolls back its batch and the
  trigger's own writes; the earlier batches stay committed outside an
  explicit transaction, and `withTransaction` rolls them all back. A
  trigger's `RAISERROR` without a rollback reports an error and leaves the
  batch's rows committed. A trigger's result set is sent back and doesn't
  count toward the load's DONE count. An empty load sends no `INSERT BULK`
  and fires nothing (SQL Server 2025).
* A load into a view uses the view's binding as it stands, stale or not
  ([Conversions on the server](#conversions-on-the-server)); bulk column
  discovery reads the view as it is and doesn't refresh it.
* **Streamed values.** Several unknown-length values in a row work.
  Over-long values depend on `ANSI_WARNINGS`: with `ON` the load is
  refused by error 2628, and with `OFF` the value is cut silently, as a
  plain `INSERT` is. In both settings, trailing blanks and zeros past the
  width are dropped, and a character outside the code page becomes `?`.
  `ANSI_WARNINGS` read 1 from `SESSIONPROPERTY` on a new hmssql
  connection, plain and MARS, and after a reset (SQL Server 2025 CU10,
  2026-10-31).
* **Over an SMP session** a load works (one TDS packet per SMP DATA
  packet), from the spikes on SQL Server 2025 RTM
  ([mars-research.md](mars-research.md#probe-7-bulk-copy)).
  * With a result set open on any other session it fails with 595 unless
    `XACT_ABORT` is ON (the stream then reads on to its end; with it ON
    the load is exact).
  * Inside a transaction, any other request on the target table fails it
    with 3970: the transaction is lost, and a stream open over the table
    delivers its rows, then 3998. Both errors come after the whole load
    has been sent.
  * Beside busy streams a load is starved (5 to 8 times slower; the
    streams keep their rate), and a load waiting for a lock stops every
    session.
  * The server accepts an Attention on the session of a load cut short
    (a FIN there closes the connection). hmssql doesn't use it, and an
    interrupted load breaks the connection (the recovery is on the
    [backlog](backlog.md#after-the-release)).

## Azure SQL Database

What hmssql's suite, the MARS spike's probe 6 and later probes found
against Azure SQL Database in East US, from 2026-09-25 to 2026-10-29.
[azure-sql.md](azure-sql.md) has the runs, what each tier and connection
policy was, and how the tests adapt. The MARS facts of probe 6 were
measured with the spike's own request layer, through the gateway and
after a redirect, over TDS 7.4 and 8.0, with SQL and Entra token logins.

### Login, routing and encryption

* **The gateway routes a login by the LOGIN7 server name**, and refuses
  one without it with error 40531 ("Server name cannot be determined").
  A bare name such as `myserver` and the full `myserver.database.windows.net`
  are both accepted; a wrong name, short or full, is refused with 40532.
  The network destination is a separate thing: with the gateway's IPv4
  address as `connectHost`, that address in LOGIN7 is refused with 40532,
  and an explicit valid name succeeds, the certificate validated against
  the Azure host name through `tlsHostNameInCertificate`, with no SNI.
  Measured on 2026-10-28 and 29 from macOS under `EncryptOn` and
  `EncryptStrict`, through the gateway and with the Redirect policy;
  `sys.dm_exec_connections` reported protocol versions `0x74000004` and
  `0x08000000` with encryption on. The server's name resolved to IPv4
  only: `AF_INET6` gave an IPv4-mapped address, and DNS had no AAAA
  record.
* **Redirects.** Under the Default connection policy, a login from inside
  Azure is redirected to the node hosting the database, and one from
  outside Azure is proxied; the Redirect policy redirects both. The
  gateway answers a LOGIN7 it redirects with a LOGINACK and a routing
  ENVCHANGE and nothing else: no database, language or collation
  ENVCHANGE and no INFO, which come from the node. The node refuses the
  gateway's server name: the redirected login must carry the node's own
  (`host,port`, as SqlClient sends it), or it fails with 40613,
  "Database '...' on server '' is not currently available"; an empty one
  fails with 40531, as at the gateway.
* **Encryption is required.** A PRELOGIN offering ENCRYPT_NOT_SUP is
  refused, and ENCRYPT_OFF gets everything encrypted, not just the login.
* **Packets are capped at 16192 bytes** (a request of 16384 or 32767 gets
  16192), with and without MARS. A LOGIN7 packet over 4096 bytes is reset
  ([PRELOGIN and encryption negotiation](#prelogin-and-encryption-negotiation)).
* Error 40613, "Database ... is not currently available. Please retry the
  connection later", is transient: a serverless database that was paused
  answered two logins with it while it resumed, and a Basic companion
  database answered one in a whole-suite run (2026-10-15).

### Session state

* **CONTEXT_INFO is set at login** to a tracing GUID (UTF-16, padded to
  128 bytes); a reset leaves it NULL.
* **RESETCONNECTION puts the isolation level back to READ COMMITTED**,
  where SQL Server keeps it, with MARS too.
* **`READ_COMMITTED_SNAPSHOT` is on by default** in a new database. A
  READ COMMITTED reader then reads row versions: it neither waits for a
  writer's locks nor holds a shared lock while it is parked at its
  window. A test of those lock effects reads `WITH (READCOMMITTEDLOCK)`,
  which behaves as READ COMMITTED does without RCSI.
  `ALLOW_SNAPSHOT_ISOLATION` is always on.

### What Azure SQL Database lacks

* No `USE` (40508) and no three-part names into another database (40515).
* No `ALTER LOGIN ... WITH DEFAULT_DATABASE`: every login lands in
  `master`, and a login without a user in the database it asks for gets
  916, not 4060.
* No `CREATE LOGIN ... CHECK_POLICY = OFF` (40517), no extended
  procedures, and no `RAISERROR ... WITH LOG` (2778: the server admin is
  not `sysadmin`).
* No `ALTER DATABASE ... SET OFFLINE` or `SINGLE_USER` (1468, the database
  is in an availability group).
* `SUSER_SNAME()` is refused inside `EXECUTE AS` (40529), and
  `SERVERPROPERTY('InstanceDefaultDataPath')` is NULL.
* `sys.dm_exec_connections` needs VIEW DATABASE STATE, which a
  `db_datareader` lacks (error 300).
* **Databases.** In the logical `master`, `DB_ID` of any other database is
  NULL; ask `sys.databases` instead. A plain `DROP DATABASE` drops a
  database with connections into it. A bare `CREATE DATABASE` makes a
  General Purpose 2-vCore database, billed by the hour, and takes 25 to
  60 s. `CREATE DATABASE` refuses a name with a character outside the BMP
  (`hmssql_test_𝄞_...`) with error 1055, "an invalid name because it
  contains a NULL character or an invalid unicode character"; names with
  accented letters, CJK characters, spaces and closing brackets are
  accepted, and SQL Server 2025 on Linux accepts that one too
  (`GP_S_Gen5_1`, from a workstation, 2026-10-25).
* `sp_getapplock` works in the logical `master`.

### Cancellation and killed sessions

* **A killed session's running request** is answered by the gateway with
  one DONE of status 0x102 (DONE_ERROR and DONE_SRVERROR), no ERROR token,
  and then a TCP reset. hmssql throws `SevereError` for the DONE and marks
  the connection broken. SqlClient reports the same as "a severe error
  occurred on the current command".
* **A session killed in the middle of a long result hung on one macOS
  system** connecting from outside Azure. The rows already on their way
  arrived (91,000 to 265,000 of 2,027,776), and then nothing, not a DONE,
  an ERROR, a FIN or a reset, for as long as the client waited (45 s; a
  `sqlcmd` was still blocked after 26 minutes). The session was gone from
  the server's view at once. In a hung run the client's socket is
  `ESTABLISHED` with an empty receive queue, and closing it leaves it in
  `FIN_WAIT_1` with its last 54 bytes unacknowledged. A request killed
  while it waits (a `WAITFOR`) ended the connection every time, from
  everywhere. Measured on 2026-10-25 and 26:

  | Client | Policy and tier | Result |
  |---|---|---|
  | macOS, about 45 ms away | Default (the gateway), S3 | 6 of 6 hung |
  | macOS | Redirect (the node), `GP_S_Gen5_1` | 5 of 6 hung |
  | macOS | Redirect, Basic | 4 of 6 hung |
  | Linux in Docker Desktop on the same Mac | Default, S3 | 6 of 6 hung |
  | Linux in Azure Container Instances, same region | Default, S3 | 4 of 4 ended with a reset within 0.09 s |
  | Native Windows, outside Azure | Default, S3 | 18 of 18 ended (3 in the full suite, 15 focused) |

  The runs on the Mac that ended did so with a reset after 0.5 s, once
  7.5 s. The hang has not been reproduced on any other system, and there
  is no public bug report. Its cause is unknown: the observations
  establish neither an Azure nor a macOS defect, and an environmental
  cause remains possible. What would settle it is on the
  [backlog](backlog.md#checks-to-revisit).
* **An Attention right behind its request is acted on late.** An
  Attention sent right behind a `SELECT` of 30,000 rows over MARS (S3,
  from a container in the same region, 2026-10-01) was usually not acted
  on until the statement had finished: in the one traced, the whole
  result arrived, 402 packets of 8000 bytes, and then the acknowledgement
  in a message of its own, as SQL Server 2025 does with an Attention that
  arrives before the statement is under way ([MARS and SMP](#mars-and-smp)).
  Of 210 such cancels beside the whole suite, drain included, 4 took
  about 2 ms, too short for that result to have arrived, which fits the
  Attention overtaking the request (the next bullet); the rest took 9 to
  610 ms (median 190 ms). None was left unacknowledged. On S3 under the
  whole suite, a 1,000,000-row `SELECT` cancelled so took up to 4.3 s
  (2026-10-15).
* **Under load, Azure SQL Database sometimes ends a MARS connection when
  it reads a request together with the Attention that cancels it** (sent
  37 to 107 ms behind): a DONE flagged DONE_ERROR and DONE_SRVERROR with
  no ERROR token on that session, a FIN, and the TCP close; the
  connection's other requests are killed. Seen 5 times in about 140 runs
  of one cancel sequence under whole-suite load, never in 1,800 immediate
  cancels without load; S3, Default policy, 2026-10-01. SQL Server 2025
  never does it. The evidence is in
  [upstream/azure-sql-early-attention](upstream/azure-sql-early-attention/README.md).
* **A cancelled reset-carrying request** (the Attention sent right behind
  it, over MARS) ended without the reset's acknowledgement in 1 of 100
  batches and 1 of 100 RPCs in a whole-suite run on S3 (2026-10-01), and
  in 1 to 3 of 100 in later runs; SQL Server 2025 acknowledges every one
  ([MARS and SMP](#mars-and-smp)). hmssql then asks for the reset again
  (`finishSession`).
* A `KILL` sends a FIN on every MARS session, through the gateway and on
  the node alike. SMP protocol violations get a TCP reset through the
  gateway and an orderly close on the node.

### Limits and load

* **Every active request counts against the database's request limit**,
  30 on Basic: the 31st fails with 10928 ("The request limit for the
  database is 30 and has been reached", class 20), and only that request.
  With k streams held open on one MARS connection, 30 succeeded and the
  rest failed so, up to k = 200; at k = 300 the connection was closed.
  Bursts of one-shot requests on one connection were all answered up to
  280 at once; 290 and 300 varied from run to run, and from 400 most
  failed, with 3980 or a bare error DONE. It is neither the request limit
  nor a session limit (1000 sessions could each run a query in turn), and
  the cause is unknown (probe 6, Basic). The test suite with its default
  16 parallel items passes the limit on Basic (2026-10-05).
* **Over a WAN a MARS session reads at window × packet size per round
  trip:** at a 45 ms round trip, window 64 matched a plain connection and
  window 16 read at a quarter of it (4 × 8000 bytes / 45 ms is
  0.71 MB/s). Uploads over MARS were several times slower than plain (a
  1,000,000-byte parameter took 1.6 to 2.5 s against 0.24 s), because the
  server's own window stays 4 packets ahead; 16,192-byte packets help in
  proportion. A `SELECT 1` was 44 to 46 ms, plain and on MARS alike, and
  `EncryptStrict` timed the same as `EncryptOn` (probe 6, Basic).
* Idle MARS connections through the gateway survived gaps of up to 21
  minutes, died at 22 and 32 minutes, survived 28 and died at 35, all on
  one gateway address; on the node two 35-minute gaps survived. There was
  no clean threshold (probe 6).
* **Log rate.** The test suite runs an S3 database at its limits: the
  per-minute maxima of DTU and log write reached 100% for most of each
  whole-suite run (2026-10-01), and log-heavy statements then wait in
  `LOG_RATE_GOVERNOR`. An `UPDATE` of every row of a 30,000-row table
  (104-byte rows) took 1.6 to 42 s (median 11 s, 53 tries), where an
  `UPDATE` of one row took at most 0.22 s and locally the whole table
  27 ms. On Basic, writers committed 6 times a second whatever their
  number, and the database's CPU sat at 100% of the tier's allowance for
  a whole run of the suite (2026-10-05).
* **Deadlocks on the catalog.** A read of the catalog views (`sys.objects`,
  `sys.columns`, the key and foreign-key views, joined, as
  `Hmssql.Catalog` reads them) was chosen as a deadlock victim (1205)
  beside other sessions creating and dropping objects in the same
  database, once in a whole-suite run on S3 (2026-10-01), and so was a
  batch dropping a schema's objects in the next run; it hasn't happened
  locally.

## The server under load

Seen in `scripts/test-matrix.sh` runs from 2026-10-03 to 2026-10-15: two
or three runs of the whole suite at once (16 items in parallel each, often
over MARS connections), against one SQL Server container of each version
(8 GB memory limit, 6 GB for SQL Server), on a 32-core Linux machine.

* **An Attention waited 117 s for a lock.** With three runs on SQL Server
  2025, an Attention for a MARS statement waiting for a lock was not acted
  on for 117 s, until the lock was released: seven times in the
  `mars+on` configuration (TLS from PRELOGIN) on 2026-10-03, once with two
  runs, and in three of the eighteen `on+arithabort` and `mars+arithabort`
  runs of 2026-10-15 (a test sending the Attention 300 ms after its
  request). The acknowledgement came right after the release. It is SQL
  Server 2025 ignoring an Attention that arrives before the statement is
  under way ([MARS and SMP](#mars-and-smp)), which a loaded server's late
  start stretches to 300 ms. Reproduced 3 times in 300 runs of the test
  beside two runs of the suite (2026-10-15) and captured: the request
  arrived, the Attention 300 ms later, the statement's lock wait began 7
  to 44 ms after the Attention had arrived, the server's session read the
  Attention 1 to 3 ms after that (its row's `last_read`) and ACKed it at
  the SMP level (its window moved past it) 17 to 49 ms after its arrival,
  and the statement then waited 116 to 117 s, until the lock was released
  and the result came with the acknowledgement behind it. The physical
  connection's `last_read`, from before the request, had made the
  Attention look unread; under MARS it stops at the login. A probe on
  2026-10-03 (1,440 Attentions sent 1 µs to 50 ms behind such a request,
  strict and `on`, plain and MARS, idle and beside two runs) saw every
  one acted on at once; what its statement was is not recorded, and the
  probe of 2026-10-15, with a new table for each try, found the opposite
  right behind the request. The session setup of those configurations is
  not needed: the probe found it without one.
* **SQL Server 2022 crawled for minutes** with two runs of the suite at
  512-byte packets on it (2026-10-15, CU27, a run on each of 2019 and
  2025 beside them): twice in five rounds, for about 2.5 and 1.5 minutes.
  A new connection's `SELECT 1` took 1 to 21 s, once 90 s, where it takes
  under 0.1 s; the server's container used 1 to 1.7 cores where it had
  used 4 to 16, and the two test processes under a tenth of one; the
  error log had nothing at all for the 2.5 minutes, no non-yielding
  report among it. Connections kept moving, slowly: a MARS upload at
  512-byte packets got its window raised about 30 times a second and a
  stream at window 4 got 10 packets a second, each session's row showing
  a read a few milliseconds old and its requests in `ASYNC_NETWORK_IO`,
  while the client had sent everything its window allowed and read and
  acknowledged everything it got. Tests that need thousands of round
  trips ran past their 60 s, MARS and plain alike, and the matrix's
  timeouts of whole groups of 512-byte tests (about 5 runs in 312, on
  all four versions) look the same. Both times the crawl began within
  seconds of both runs creating and dropping their scratch databases
  (about 25 database starts, with `SINGLE_USER` and `OFFLINE` switches,
  in 10 to 30 s); whether that is the cause was not established, and
  other rounds did the same without a crawl.
* **What the stalls are, on the server's side.** Three times in the
  reruns of 2026-10-05 and 06 (49 and 24 runs, alternating between the
  servers, so one or two on each) a request went unanswered for 15 s or
  more, and each time the server's log has the reason at that minute:
  "IO Completion Listener ... appears to be non-yielding on Node N", for
  15 to 25 s on SQL Server 2025 (twice, with 7 to 12 s of kernel time and
  as much user time in 15 s) and for 65 s on SQL Server 2022 (once, all
  of it user time), with a stack dump. Those are all the reports of it in
  the two containers' logs, over twelve hours. While that thread doesn't
  yield, nothing the node's connections send is read: the session of the
  unanswered request showed as sleeping, its connection's last read from
  before the request, and the client had nothing unsent (the MARS model's
  diagnostic). The seven tests of a MARS stream that failed in the same
  run had waited 60 s for packets. All three were in a run with `off`
  (TLS for the login only), 12 to 68 s after it began; six other `off`
  runs passed. Measured alone, a whole run of the suite pauses the server
  for 0.4 to 1.2 s at about 10, 30 and 58 s in (twelve connections asking
  `SELECT 1` every 50 ms; the longest waits were 0.4 s under `notsup`,
  0.7 s under strict and `on` and 0.9 to 1.2 s under `off`), with no
  report in the log. Which tests cause the pause was not looked for.
* **Waits that timed out.** SQL Server 2025 stopped for about 30 s once:
  no request answered, no login accepted, and nothing written to its error
  log, then everything went on, with no memory, CPU or I/O pressure in the
  container. With two runs on SQL Server 2025 there was one timeout of a
  test's wait in four rounds, and with three, fifteen. SQL Server 2022,
  with three runs, timed out as many as 27 waits of 30 to 180 s in a
  round; after about 20 hours of such runs it failed requests with error
  701 ("insufficient system memory in resource pool 'default'") and reset
  connections. Restarted, it held 5.6 GB (2026-10-03).
* **SQL Server 2025 ran out of memory for about a minute**, twice in seven
  hours of three runs at once (2026-10-05, CU9, the same limits), each
  time two minutes after a run with the slow tests had begun on it. The
  second time (22 errors 701) a login was closed by the server, and that
  was all. The first time its log shows eight errors 701 in that minute
  and a memory report with no available physical memory and a committed
  target of 1.64 GB, under a `max server memory` of 6 GB. What the clients
  saw:
  * requests and logins refused with 701 ("insufficient system memory in
    resource pool 'internal'");
  * a login refused with 4060 whose text was "The error is printed in
    terse mode because there was error during formatting";
  * connections reset by the peer, during a login or between requests
    (`ConnectionClosedBy (TransportFailed ...)`);
  * and, twice, a login response with neither a LOGINACK nor an error,
    which hmssql reports as `ProtocolError "login response did not
    include LOGINACK"` (what it did contain was not captured).

  It failed 12 tests of one run and one of another, and the server went
  on afterwards. A third run, of the whole suite over MARS with the slow
  tests (GHC 9.8.4), had begun two minutes before; its report stopped at
  the slow `Differential.Encode` property, and 46 minutes later Docker
  killed the test process for passing its 16 GB of memory. A server that
  stops answering would not explain that: against a mock server that
  stops answering, nothing in hmssql or in the suite grows
  ([design.md](design.md#memory-and-performance), 2026-10-15). The likely
  cause was the suite's, a property whose case failed once, as at the
  server's error 701, so that hedgehog tried every smaller case and kept
  each in memory ([bugs-found.md](bugs-found.md#in-the-test-suite)). A
  session killed in the middle of that property, locally, fails it in
  12 s at 0.7 GB.
* **A metadata-cache lock on a fresh server.** On a freshly created SQL
  Server 2025 CU9 container (3 GB memory limit, 2026-10-13), the first run
  of the whole suite failed the eight `Connection.Disconnect` tests that
  stream `sys.all_objects` cross-joined with itself, each hung at its
  first row for its whole 10 or 30 s limit while its session waited on
  `LCK_M_SCH_M` for `METADATA_CACHE`, blocked by the sibling test's
  session running the same statement; the sessions had no open
  transaction and the hmssql side had sent the request. Alone and on the
  second run of the suite, all 32 passed. A one-row metadata-cache lock
  held across a whole request looks like the server's first compilation
  of that plan, and it was not seen again.
* A `KILL` of a session in a `WAITFOR`, issued once the server showed the
  wait, let the request finish with its result (once).

## Platform and tooling

### GHC and its libraries

* **GHC's I/O manager, kqueue (macOS, BSD) and epoll (Linux) alike**, has
  two defects ([upstream/ghc-kqueue-stale-fd](upstream/ghc-kqueue-stale-fd/README.md)):
  a stale registration after a wait on a just-closed descriptor (GHC 9.6
  through 9.12; fixed in 9.14), and a `closeFdWith` that throws (`kevent:
  does not exist`; on Linux `epollControl: does not exist`), which leaks
  the descriptor and wedges its lock bucket (every version, master
  included). On Linux the README's `Minimal.hs` and `Minimal2.hs` give the
  macOS results on GHC 9.6.6, 9.8.4, 9.10.3, 9.12.4 and 9.14.1 (Ubuntu,
  kernel 6.8, 2026-10-25). A process with a wedged bucket shows it as
  threads `BlockedOnMVar` that never wake, all on descriptors with the
  same number mod 32 (the bucket), none of them in any of the I/O
  manager's epoll sets (`/proc/PID/fdinfo` of each
  `anon_inode:[eventpoll]` descriptor), and their sockets sitting in
  CLOSE-WAIT with bytes unread once the other end gives up. SQL Server
  2019 had closed two such connections, one of them stuck in `connect`,
  by the time they were looked at minutes later, each with 1 byte left
  unread (what the byte is was not looked at).
* `GHC.Conc.threadLabel` on a thread with no label can crash the process
  in the garbage collector (GHC #27618, in every release through 9.14.1):
  see [upstream/ghc-threadlabel-null](upstream/ghc-threadlabel-null/README.md).
  The test suite reads labels through a wrapper of the primop.
* `getaddrinfo` is a safe foreign call an asynchronous exception can't
  interrupt.
* GHC frees a CAF once no code that is still to run refers to it, so
  what a process loads once is not kept for its life. hmssql's cache of
  the system certificate store is a CAF (`systemCertificateStoreCache`),
  and the store is 2.6 MB of live heap on Ubuntu 24.04 (123 certificates,
  GHC 9.12.4): after the last `connect` a program can still reach, the
  next major collection frees it. A test that compares two readings of
  the live heap sees that as 2.6 MB freed by whatever ran between them.
* `-N` counts the CPUs the process sees, which a CPU quota (Docker's
  `--cpus`, cgroup `cpu.max`) doesn't reduce: on a host with 32 hardware
  threads in a 2 GB container, `-N -A64m` is 2 GB of nursery before the
  first test.
* **What the optimiser does.** These were found by the optimisation runs
  ([performance-research.md](performance-research.md) has the
  measurements around them):
  * GHC 9.12's SpecConstr can leave a second, unspecialised copy of a loop
    (its arguments boxed) when one branch reaches the loop through a guard
    and another through a call; routing both through one call site avoids
    it. A higher `-fspec-constr-count` didn't help.
  * GHC 9.14.1 can move the evaluation of a thunk into the loop of a
    closure built beside it. In `sqlRowDecoderFor` a `SmallArray` made by
    `smallArrayFromListN n <$> mapM ...` in `Either`, and indexed in the
    loop of the function returned, was built once for each iteration:
    8 n² bytes for n elements, on 9.14.1 only (9.6.6 to 9.12.4 built it
    once). A strict binding (`let !cells = ...`) before the closure ends
    it. Not reduced to a program that shows it outside hmssql.
  * GHC 9.12.4's threaded RTS has generic-apply entry points only for
    all-pointer argument patterns and a lone non-pointer word (`stg_ap_0`,
    `v`, `f`, `d`, `l`, `n`, `p`, `pv`, `pp`, `ppv`, `ppp`, `pppv`,
    `pppp`, `ppppp`, `pppppp`, `v16`, `v32` and `v64`, listed with `nm` on
    `libHSrts-1.0.3_thr.a`). An unknown call with any other pattern, such
    as `p n p n` for an environment, an `Addr#`, a `ForeignPtrContents`
    and an `Int#`, is split into chunks, and each chunk applied to a
    function still wanting arguments builds a PAP in the RTS, which ticky
    attributes to no closure. Seen in the Cmm of a standalone module on
    2026-11-04; it doubled a typed query's allocation in hmssql.
  * GHC 9.12.4 links with `--gc-sections` on Linux whatever the flags (in
    the `-v3` link line), and ghcup's boot libraries (`base`, `text`,
    `containers` and the rest) are built with split sections; Stack's
    snapshot packages are not (0 split sections in every snapshot `.a`,
    2026-11-04). So the code an unsplit build links is every module a
    program refers to, whole: a minimal hmssql program was 17.5 MB of
    `.text`, and 4.8 MB with every package split (Stack's `ghc-options:
    "$everything": -split-sections`, which rebuilt 59 snapshot packages in
    about 7 minutes). In cabal, a top-level `split-sections: True` in
    `cabal.project` applies to local packages only, and `package *` with
    it, or the global config, to every dependency. `cabal check` refuses
    `-split-sections` in a package's `ghc-options` as an error for
    Hackage, also under a flag or `if impl(ghc)`.
* `network`'s `recv` allocates the whole size it asks for on every call
  and copies what arrived; `recvBuf` into a buffer of one's own doesn't.
  `binary`'s `runPut` starts with a 4 KiB buffer, a large object under the
  storage manager's lock, however few bytes are written.
* `text` 2.1 made `Data.Text.Array.MArray` an alias of
  `MutableByteArray`; in 2.0 it is a distinct type, so code that writes a
  `Text` array directly needs `text >= 2.1`.
* `foldl'` is in the Prelude only from base 4.20 (GHC 9.10). With GHC
  9.14, `serialise` and `cborg` need `allow-newer` for `base`,
  `containers` and `time` (`cabal.project`).
* `getSystemCertificateStore` on macOS runs the `security` tool: about
  16 ms and 38 MB of allocation for 158 certificates.
* `hspec-hedgehog` takes a property's case count from hspec
  (`maxSuccess`), not from hedgehog's `withTests`. `length <$>
  listThreads` returns an unevaluated thunk holding every `ThreadId`,
  which keeps finished threads listed (this looked like a thread leak for
  a while).

### Build tools

* Adding `-threaded` to an executable's `ghc-options` does not relink it:
  GHC's recompilation check does not count the runtime among the link
  inputs, so `stack build` reinstalls the binary and it still reports
  `"RTS way", "rts_v"` under `+RTS --info`. It takes `stack build
  --force-dirty` or a change to a module. Measured with Stack and GHC
  9.12.4 on Windows on 2026-10-14.
* `stack run` with no target runs the project's executable whose name
  sorts first, from any package of the project, and passes it the
  arguments meant for another one. In this repository that is
  `hmssql-bench-azure`; in a project that lists the shop-db package
  beside its own, it is `hmssql-example-setup`, which resets the example
  tables (Stack, 2026-10-14).

### Networking

* **A connect to an address that never answers** fails with `ETIMEDOUT`
  after 133 s on Linux with the default `tcp_syn_retries` of 6 (the SYN is
  retransmitted after 1, 2, 4, 8, 16 and 32 s; measured on 2026-10-13
  against 10.255.255.1 on a wireless network with a default route), and
  with `WSAETIMEDOUT` after 21 s on Windows. An address with no route
  fails at once with `ENETUNREACH` instead. On Windows a `timeout` around
  the connect doesn't shorten it: with network's blocking connect under
  GHC's native I/O manager, a `timeout` of 4 s returned after 21.0 s, and
  through hmssql's `connect` under a `timeout` of 3 s the connect failed
  with `WSAETIMEDOUT` after that wait, the `timeout` giving that failure,
  not `Nothing`.
* On macOS a TCP connect to a port with a socket bound to it that doesn't
  listen gets no answer: the SYN is dropped, and the connect fails with
  `ETIMEDOUT` after about 8 s (7.78 s in one measurement). A port whose
  socket was closed answers with a reset, and the connect fails at once
  with `ECONNREFUSED`. Linux refuses both. Measured with Python's `socket`
  on 127.0.0.1 on macOS 15 (Darwin 24.6.0), 2026-10-25.
* On macOS a TCP connect started right after an interrupted one on the
  same descriptor number now and then returns connected while it isn't;
  the next send fails with ENOTCONN (once in about 400 runs of 5000
  attempts).
* Every client-closed connection leaves a socket in TIME_WAIT for 30 s;
  macOS has 16384 ephemeral ports, and tens of thousands of short
  connections exhaust them. A test server can skip TIME_WAIT by resetting
  with `SO_LINGER 0` once the client has closed.

### Docker

* A Docker port forward to the server overflows its accept queue when 64
  TLS connections open at once; the kernel retries most, but Docker
  sometimes gives up mid-PRELOGIN or mid-handshake. Opening 8 at a time
  avoids it.
* A client container removed with `docker rm -f` sends no FIN or reset:
  its sessions stay on the server, sleeping, for hours (20 h seen).
* Docker Desktop's networking re-originates a container's connections,
  so a packet capture inside the container shows its own proxy, not the
  connection to the server.

### Windows

What GHC, network and Windows were seen to do under hmssql's Windows
backends; the probes, their conditions and the rest of the numbers are in
[windows-research.md](windows-research.md), and the decisions taken from
them in [design.md](design.md#platform-workarounds). Measured on Windows
10 with GHC 9.12.4 and network 3.2.9.0 unless a bullet says otherwise.

* **Under the default I/O manager with `-threaded`, nothing interrupts
  network's calls.** No asynchronous exception reaches a thread inside
  network's `recv`, `sendAll` or `accept`: `killThread` on one had not
  returned after 3 s, and neither had a `timeout` of 300 ms around `recv`
  (a compiled program). A refused TCP connect to a loopback address takes
  about 2 s to fail, and its `IOException` has no errno; the description
  names the Winsock error (`WSAECONNREFUSED`).
* **A pending overlapped operation that carries an event is cancelled
  when the thread that started it exits** (`ERROR_OPERATION_ABORTED`,
  995), even on a handle associated with a completion port; one that
  reports only to the port outlives its thread. A Haskell thread's
  foreign calls are made on whichever worker thread of the runtime is
  running it, unless the thread is bound
  ([windows-research.md](windows-research.md#a-pending-operation-dies-with-the-thread-that-started-it)).
* **Without `-threaded`, under the default manager**, network's `recv` is
  a blocking `recv` on a worker of the runtime (`asyncRead#`): a
  `timeout` around it fires, but the abandoned call keeps running and the
  next bytes to arrive go to it and are lost. A C function run with
  `asyncDoProc`, which starts an overlapped operation, waits for it and
  cancels it on request, was interrupted in 300 ms with nothing lost, at
  about 45 to 51 µs a loopback round trip against 33 to 36 for network's
  calls. `threadDelay` is a request to the same worker pool, served with
  `Sleep`, and a `timeout` that returns leaves its worker asleep until
  the limit; the pool grows whenever fewer workers are idle than requests
  are queued, and its workers never exit: 200 `timeout`s of 10 s that
  returned at once added 201 handles for good, and the test suite's
  watchdogs grew the pool to 5,847 threads. Under `--io-manager=native`
  both `recv` and `asyncDoProc` crash this runtime, because the worker
  pool behind them is never started (2026-11-06,
  [windows-research.md](windows-research.md#the-non-threaded-runtime)).
* **network under GHC's native I/O manager.** network 3.3 compiles its
  code for that manager only when GHC defines `__IO_MANAGER_WINIO__` as 2
  or more: GHC master on 2026-11-06 and 9.12.4.20260713 did, and 9.10.3,
  9.12.4 and 9.14.1 define 1. What network master `1f6aa85` does there,
  read in its source on 2026-11-04:
  * `socket` makes a blocking socket and associates it with the
    manager's port;
  * `recvBuf`, `sendBuf` (so `sendAll`), `recvBufFrom` and `sendBufTo`
    are overlapped `WSARecv` and `WSASend` through the manager's
    `withOverlapped`, which an asynchronous exception cancels;
  * `sendMany` is a `WSASend` without an `OVERLAPPED`, a safe foreign
    call;
  * `connect` is a safe `connect` on the blocking socket, which never
    waits in the manager;
  * and `close` is a plain `closesocket`.

  Measured with that network and GHC master `20334e1d1f`, threaded, on
  loopback, in a probe of network's calls alone:
  * A reset that arrives while a `recvBuf` is pending fails it with an
    `IOException` of type `InvalidArgument`, errno `EINVAL` (22), "The
    specified network name is no longer available": the completion
    carries `ERROR_NETNAME_DELETED` (64), which network's completion
    callback doesn't map, and base's conversion loses it. A `recvBuf`
    started after the reset arrived returns 0, as does the one after the
    failure. A `sendAll` after a reset fails the same way, with "forcibly
    closed"; a `sendMany` with `WSAECONNRESET`, of type "failed".
  * The receiving side's pending `recvBuf` sees that failure too when the
    other end closes, even after a `shutdown`, with bytes unread. Killing
    a pending `recvBuf` doesn't reset the connection: a send afterwards
    arrived, and a later close read as the end of the stream.
  * A `sendAll` or a `sendMany` of 64 MB to a peer that read nothing
    returned in about 22 ms, under a `timeout` of 500 ms or not: Winsock
    took it whole. The next send of 100 bytes then blocked, in
    `sendMany`'s safe call, which nothing interrupts.
  * Without `-threaded`, a thread killed while its `recv` was pending,
    and that socket then closed, left the first `sendAll` or `recv` on
    the next socket pending for good, and every Haskell thread with it:
    a thread printing once a second never printed again. It happened by
    the second or third round of connect, round trip, kill and close in
    each of 13 runs, with or without file reads between the rounds, and
    not in 40 rounds that left the sockets open, nor under the default
    manager. `accept` crashed that runtime under that manager with an
    access violation reading `0x28`. With `-threaded` neither was seen.
    The cause was in GHC: the manager cancelled the killed receive and
    waited for it in a blocking `GetOverlappedResult`, a safe foreign
    call, which in the non-threaded runtime stops the scheduler, and
    `asyncDoProc`'s worker threads were never started under that
    manager. With a GHC fixed for both (the branch
    `wip/winio-completion-packets`, 2026-11-06) the probe ran 40 rounds in
    each of 4 runs, and `accept` worked. Then the only call that stopped
    the runtime was network's own blocking `sendMany`: in the suite,
    sending to a mock server in the same process that had stopped
    reading, the process waited for itself.

  What each did to the test suite is in
  [windows-research.md](windows-research.md#ghcs-native-io-manager-winio).
  Under that manager with many busy sockets, GHC's own completion
  handling crashed with an access violation, without hmssql
  ([upstream/ghc-winio-many-connections](upstream/ghc-winio-many-connections/README.md)),
  and a thread killed during a file read could hang for good
  ([upstream/ghc-winio-file-read](upstream/ghc-winio-file-read/README.md)).
* **A named pipe through the native manager** (2026-11-07, GHC master
  `20334e1d1f`, with and without the manager's fix, threaded and not): a
  completion callback gets a Win32 code (109, 232 and 233, as under
  [Shared Memory and Named Pipes](#shared-memory-and-named-pipes)), not an
  NTSTATUS, where GHC 9.12.4.20260713 gave `0xC000014B` for a broken
  pipe. `ConnectNamedPipe` on an overlapped instance whose client
  connected first returns 0 with `ERROR_PIPE_CONNECTED` (535), and with
  `ERROR_NO_DATA` (232) if the client has closed again; either way
  Windows completed nothing, and no packet comes. Both are connections,
  and a listener that took the second for a failure stopped accepting.
  `CancelIoEx(h, NULL)` ends a pending read and write with 995;
  `CloseHandle` ends the read with `ERROR_BROKEN_PIPE`, as the other
  end's close would, and the write with 995. Opening the client end of a
  local pipe never waited: 4.5 to 17 µs on average over 2,000 opens, the
  most 0.5 ms, whether the pipe was listening, busy or missing
  ([windows-research.md](windows-research.md#ghcs-native-io-manager-winio)).
* **A short sleep lasts until the next tick of the system timer.** On a
  machine busy with the test suite, `threadDelay` of 100 µs, 1 ms and
  5 ms each took about 17.5 ms on average, and 20 ms took about 32 ms;
  `timeout` of the same lengths took the same. So a `timeout` under 16 ms
  can't be relied on to be short, and a test that sweeps a timeout across
  an operation of a few hundred microseconds lands inside it by the
  chance of where the tick falls, in about one attempt in a hundred.
  Under the native manager, `getCurrentTime` around a connect to the
  mock server gave 0 s twenty times in twenty, where the default manager
  gave usable figures; the tests measure durations with the monotonic
  clock.
* **The default I/O manager fires no timer for seconds** once tens of
  thousands of pending delays expire, and a `timeout` whose action has
  returned still counts as one until its limit passes. With `-N` on 32
  processors and 10,000 threads a second that each sleep 3 s, a
  `threadDelay` of 200 ms took up to 6.8 s, and with 2,000 a second that
  each sleep 15 s up to 4.9 s; with 1,000 a second of either it stayed
  on time, and so it did under the native I/O manager at 10,000. The
  repro and the reading of the manager's source are in
  [upstream/ghc-windows-timer-delays](upstream/ghc-windows-timer-delays/README.md).
