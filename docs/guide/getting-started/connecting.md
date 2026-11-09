# Connecting

Start with `defaultConnectInfo`. Its defaults are:

* `localhost` on port 1433
* Encryption enabled
* The server's certificate checked against the system's certificate store

For a local or on-premises SQL Server instance, set `connectUser` and
`connectPassword` to your SQL login credentials. Windows Integrated
Security is not supported.

Always set `connectDatabase` to the database you want to use. Leaving it
empty usually selects `master`, or fails if your account cannot access its
default database.

**Azure SQL Database** accepts an Entra access token as well as a SQL
login, including tokens obtained through a managed identity or through
client credentials.

* For token authentication, set `connectAccessToken = Just token` and
  leave `connectUser` and `connectPassword` empty.
* For password authentication, set `connectUser` and `connectPassword`
  to your SQL login credentials.

Password authentication works for application accounts as well as for the
server administrator.

Textual settings use `Text`, including `connectHost`, `connectPort` and
`connectInstance`. String literals work with `OverloadedStrings`, and
`String` values from `getEnv` are converted with `Data.Text.pack`. The
port may be a number such as `"1433"` or a service name.

## SQL Server on localhost

For development on localhost, use your SQL login credentials and skip
the certificate check. A local SQL Server generates a self-signed
certificate for itself, and the default check rejects it:

```haskell
local :: ConnectInfo
local = defaultConnectInfo
  { connectUser = "sa"
  , connectPassword = "..."
  , connectDatabase = "your_database"
  , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
  }
```

To validate the certificate instead, see
[Encryption and security](../errors-and-security/encryption.md).

## Azure SQL Database

Set `connectHost` to your server's full hostname, along with your SQL
login credentials and database name:

```haskell
azure :: ConnectInfo
azure = defaultConnectInfo
  { connectHost = "myserver.database.windows.net"
  , connectUser = "your_login"
  , connectPassword = "..."
  , connectDatabase = "your_database"
  }
```

Unlike a server on localhost, Azure SQL Database needs no TLS settings,
because its certificate passes the default check.

## Microsoft Entra ID

Obtain an Entra access token for `https://database.windows.net/` and set
`connectAccessToken = Just token`, leaving `connectUser` and
`connectPassword` empty.

For an application running in Azure, a managed identity provides the token
without a stored client secret. The
[managed identity example](../../../examples/managed-identity/README.md)
shows how to retrieve the token and connect.

## Session setup

`connectSessionSetup` is a list of statements that run after login, as one
batch, and run again after every reset.

The default is empty, because the login already sets the `SET` options
that Microsoft's drivers set. The one option it leaves off is
`ARITHABORT`, which SQL Server Management Studio turns on and which
affects plan caching. To share cached plans with SSMS, turn it on in the
session setup:

```haskell
defaultConnectInfo { connectSessionSetup = ["SET ARITHABORT ON"] }
```

## On Windows

SQL Server on Windows listens in three ways, over TCP, over Shared Memory
and over Named Pipes, and some editions install with TCP turned off. With
the default settings, `localhost` reaches the server whichever of them is
enabled.

The default protocol is `ProtocolAuto`. On Windows it tries, in order:

* Shared Memory, if the host is this machine
* TCP
* Named Pipes

It moves on to the next protocol only when the current one cannot be
opened; a refused login stops it. To choose a protocol yourself, set
`connectProtocol`:

```haskell
defaultConnectInfo { connectProtocol = ProtocolSharedMemory }
```

Three rules apply:

* **A port means TCP.** Any `connectPort` other than 1433 is tried over
  TCP only.
* **A named instance goes in `connectInstance`.** Shared Memory and Named
  Pipes find the instance by name. Over TCP, give its port instead.
* **The native I/O manager without `-threaded` needs network 3.3.** A
  program linked without `-threaded` and run with
  `+RTS --io-manager=native` needs hmssql built against network 3.3 and a
  GHC that network supports there. Otherwise `connect` fails and says so.

With `-threaded`, either I/O manager works for every protocol.

Under the native I/O manager, with network 3.3 and a GHC that network
supports there, TCP uses network's own calls, as it does on Linux, and the
pipes go through the manager. In that configuration a `timeout` cannot end
a blocked TCP connect or send. Without `-threaded`, such a call stops the
whole program until it returns, just as a name lookup does on Linux, and
so does opening a pipe on another machine. A send blocks only once the
server has stopped reading.

Everything else is the same on every protocol: encryption, logins, MARS
and cancellation.

On Linux and macOS, `ProtocolAuto` is TCP, because the other two protocols
do not exist there.

To see which transport a connection used, ask the server:

```sql
SELECT net_transport FROM sys.dm_exec_connections WHERE session_id = @@SPID
```

## Opening and closing a connection

`withConnection` keeps a connection open while an action runs and closes
it afterwards. To manage the lifetime yourself, use `connect` and `close`.

## Timeouts

There is no connect timeout. Wrap `connect` in `System.Timeout.timeout`
if the host might not answer.

A host with several addresses gets 4 seconds per address. If one address
is silent, the next is tried, and only the last waits as long as the
operating system does.

## How it works

A connection is one byte stream, a TCP socket or on Windows a pipe, and
hmssql implements the TDS protocol over it. Opening a connection takes
four steps:

1. PRELOGIN, in which the client and the server agree on encryption.
2. TLS. The handshake runs inside TDS packets under TDS 7.4, or on the raw
   socket under TDS 8.0.
3. LOGIN7, which carries the user, the password or token, the database
   and the options.
4. Your session setup, if there is one.
