# How it works

This page is the short version. The long version is
[docs/dev/design.md](../../dev/design.md).

## The protocol

SQL Server's protocol is TDS, the Tabular Data Stream. hmssql implements
it over a socket, or on Windows over a pipe, with nothing in between.

Everything travels in packets of 8000 bytes by default. A request is one
message of packets, and the response is another. One request gets one
response, and the client sends nothing else until the response is done.
MARS lifts that rule by multiplexing sessions on one connection.

## Two kinds of request

A query with parameters is an RPC call to `sp_executesql`, and the
parameters travel as typed values, never as text. A query without
parameters is a SQL batch, and the text goes as it is.

Transactions begin with a Transaction Manager request. Commit and rollback
are SQL batches.

## The reader thread

Each connection has one reader thread. It receives bytes, decrypts them,
and hands over whole packets.

Your thread parses the packets, and rows are decoded as you pull them. A
`query` pulls them all, while a `queryS` stream pulls one packet's worth
at a time.

## Canceling

An Attention is a tiny message that means "stop". The server stops the
statement and acknowledges.

A `timeout` sends one, and so does the next request after a half-read
stream. hmssql reads the response up to the acknowledgment, and the
connection is clean again.

## Reset

A connection going back to a pool is marked for reset, and the next
request carries a flag that resets the session, with no extra round trip.
An open transaction is the exception: then `release` resets at once, so
that the locks are released.

## Encryption

TDS 7.4 negotiates TLS at the start, inside TDS packets. TDS 8.0 does the
TLS handshake first, on the raw socket, and then runs TDS inside it.
Azure SQL supports both modes.

## MARS

The Session Multiplex Protocol wraps each packet in a 16-byte header
naming its session. The reader thread sorts packets by session, and each
response reads its own queue. The server interleaves the sessions where a
statement sends rows.

## The wire modules

For code that works with the wire format directly, `Hmssql.Tds.Packet`
exposes `Header`. Its `headerPacketLength` is the whole packet's byte
count, including the payload, and `headerLength` is the fixed 8-byte
header size.

`Hmssql.Tds.Bytes` checks `ByteString` bounds before reading.
`Hmssql.Tds.Bytes.Unsafe` provides raw pointer reads and writes, and its
callers supply valid storage and keep it alive. Both support unaligned
wire offsets.

`encodeUtf16LE` and `utf16LEBuilder` provide storage for UTF-16 output.
`unsafeWriteUtf16LE` writes into a caller's buffer, whose capacity and
lifetime are the caller's responsibility.

Requests are Builder recipes. `Hmssql.Tds.PacketWriter` fills packet
buffers and releases each one before it is frozen and sent. SMP header
space stays inside that module, so producers receive no raw packet
pointer.

Reads are recipes too. A suspended recipe resumes with the next payload,
without joining packets or walking the row again, and the same value
envelope feeds whole-value conversion, streamed chunks and skips.

`Hmssql.Tds.TypeInfo.putValue` checks value framing, including lengths
that would turn a non-NULL payload into NULL. It does not validate every
semantic value; `putValueUnchecked` is for values already checked.

## Where to read more

* [docs/dev/design.md](../../dev/design.md): the behavior contract, with
  the alternatives that were rejected.
* [docs/dev/protocol-notes.md](../../dev/protocol-notes.md): what TDS and
  SQL Server actually do, as measured.
* [docs/dev/mars-research.md](../../dev/mars-research.md): how MARS was
  researched, with the numbers.
* [docs/dev/limitations.md](../../dev/limitations.md): what hmssql does
  not do, with workarounds.
