# Changelog for hmssql

## 0.1.0 (unreleased)

First release. hmssql is a native Microsoft SQL Server client for Haskell,
for SQL Server 2017 and later and Azure SQL, implementing TDS 7.4 and 8.0
directly over a socket, with streaming results, composable type-checked
row decoders, queries as values, several statements per round trip, bulk
copy, strict (TDS 8.0) encryption, Azure SQL's login redirects followed,
Entra ID logins with an access token (`connectAccessToken`; Azure Managed
Identity and the like), and MARS.

A single large value streams too, in either direction. `streamField` and
`streamTextField` give a column's value to your function as it arrives,
and `binaryStream`, `textStream` and lazy `ByteString` and `Text`
parameters are read as the request is sent, so a value of any size never
has to be held in memory. Dates, times and decimals can be decoded from
their parts (`dayTimeFieldDecoder`, `decimalFieldDecoder` and the like),
and `byColumn` chooses a column's decoder by its metadata, for programs
that write values out as they read them.

MARS keeps several responses open on one connection. It is opt-in with
`connectMars`, and [the guide](https://joeyadams.github.io/hmssql/streaming/mars.html) explains it.

On Windows a connection can travel over Shared Memory or Named Pipes as
well as TCP. The default, `connectProtocol = ProtocolAuto`, tries them
in the order Microsoft's clients do, so `localhost` reaches a SQL Server
that has TCP/IP turned off. hmssql does its own I/O on Windows, so that
`timeout` and `killThread` interrupt a call there as they do elsewhere.
It works there with the threaded runtime under either of GHC's I/O
managers, without `-threaded` under the default one, and with network
3.3. Under the native manager, with network 3.3 and a GHC that network
supports there, TCP goes through network's own calls instead, as on
Linux and macOS, and the pipes through the manager, with or without
`-threaded`.
[The guide](https://joeyadams.github.io/hmssql/getting-started/connecting.html) has the rules.

It replaces the unreleased `mssql` package, which merged
[ms-tds](https://hackage.haskell.org/package/ms-tds) and
[mssql-simple](https://hackage.haskell.org/package/mssql-simple) by Takamasa
Mitsuji. hmssql is a rewrite modeled on
[hpgsql](https://github.com/mzabani/hpgsql), reusing mssql's serialization
logic. See [history.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/history.md) for the lineage,
[mssql-comparison.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/mssql-comparison.md) for what changed for
users of mssql, [design.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/design.md) for the behaviour contract,
[limitations.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/limitations.md) for what is not supported, and
[backlog.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/backlog.md) for what is planned.

Before release, the library went through an audit against mssql, AI-driven
testing that grew the test suite from 89 to about 6000 examples, two
adversarial reviews and several more, a simplification pass, a rewrite of
the decoder and encoder pipeline for streaming values, and rounds of
optimisation for speed and code size;
the bugs found along the way are catalogued in
[bugs-found.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/bugs-found.md) and the methods in
[testing.md](https://github.com/joeyadams/hmssql/blob/main/docs/dev/testing.md). The test suite runs against a live SQL
Server when `HMSSQL_TEST_PASSWORD` is set and passes without one.

Versions follow the PVP.
