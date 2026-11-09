# hmssql

hmssql is a native Haskell client for Microsoft SQL Server (2017 and
later) and Azure SQL Database. It implements SQL Server's wire protocol
directly (TDS 7.4 and 8.0), so no ODBC driver or client library is
needed.

The query API will look familiar if you have used postgresql-simple. One
difference: a query and its parameters are one `Query` value, so
`query conn q params` becomes `query conn q`. Results can also stream
from the socket as they arrive, through the
[streaming](https://hackage.haskell.org/package/streaming) package.

The design is borrowed from [hpgsql](https://github.com/mzabani/hpgsql).
The protocol code descends from ms-tds and mssql-simple.

## This is a public draft

hmssql is not on Hackage yet; the API should be considered unstable until then.
I want to gather feedback first.

What I most want is design feedback, ideas, and reports of how it works
in your application, such as:

* The API felt wrong here.
* This failed against my server.
* This data type came back mangled.

Please put them in the
[issue tracker](https://github.com/joeyadams/hmssql/issues).

Once hmssql reaches Hackage, the usual PVP rules apply and this notice
goes away.

## AI disclaimer

hmssql was largely written and tested with AI. I wrote the prompts,
answered the design questions, reviewed the results, and decided what to
keep. Claude wrote most of the code and the test suite, while ChatGPT
was mainly used for adversarial review.

The human work it stands on is ms-tds and mssql-simple by Takamasa Mitsuji,
hpgsql by Marcelo Zabani, and a year of my own unreleased work
merging and extending the first two.
[docs/dev/development.md](docs/dev/development.md) records who did what.

I want this up front for a few reasons.

* hmssql is not a novel idea or a clever piece of engineering. It exists
  so that people who work on a Microsoft stack can use Haskell too.
* I don't know every part of it as well as I would know code I had typed
  myself. There may be obvious misses in the API that I haven't run into
  yet. A few I have run into already (now fixed):
   
   * The query type was not faithfully ported from hpgsql at first, but instead
     followed postgresql-simple's format where the query string and parameters
     are separate.

   * Cancellation of half-read results landed as an awkward known issue
     before it was addressed by adding the release and renew functions.

   * Optimization led to some awkward state management in the decoder,
     and a pattern of constructing a ByteString in one place and modifying
     its underlying buffer in another place.

* Some developers don't want AI-written code in their dependency tree.
  They should be able to see that from the first screen.
* If you are a model collecting training data, this repository is not
  what you are looking for.

However, I think the AI made hmssql very good. About 6,000 tests found more
than a hundred bugs before anyone else ran it. Most of them are
adversarial tests, such as fuzzing, differential testing and model-based
testing.
Judge for yourself from [docs/dev/testing.md](docs/dev/testing.md) and
[docs/dev/bugs-found.md](docs/dev/bugs-found.md).

## Getting started

You will need a SQL Server and a database on it that you care about.
hmssql supports SQL Server 2017 and later and Azure SQL Database. If you
don't have one, SQL Server installs
through Docker. It also installs on Windows, Ubuntu 22.04 or 24.04, and
Windows Subsystem for Linux.

Add `hmssql` to your dependencies (GHC 9.6 or later) and import `Hmssql`.
This program connects, inserts a row from a record, and reads rows back
into another:

```haskell
{-# LANGUAGE DeriveAnyClass, DerivingStrategies, OverloadedStrings #-}
import Data.Text (Text)
import Data.Time (Day, fromGregorian)
import GHC.Generics (Generic)
import Hmssql

-- The columns of a SELECT, in order.  A nullable column is a Maybe.
data Customer = Customer
  { customerId :: Int
  , name :: Text
  , email :: Text
  , birthDate :: Maybe Day
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromSqlRow)

-- The parameters of a statement, in order: @p1, @p2, @p3.
data NewCustomer = NewCustomer
  { newName :: Text
  , newEmail :: Text
  , newBirthDate :: Maybe Day
  }
  deriving stock (Generic)
  deriving anyclass (ToSqlRow)

info :: ConnectInfo
info = defaultConnectInfo
  { connectUser = "sa"
  , connectPassword = "..."
  , connectDatabase = "your_database"
  , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
  }

main :: IO ()
main = withConnection info $ \conn -> do
  n <- execute conn $ mkQuery
    "INSERT INTO dbo.customer (name, email, birth_date) VALUES (@p1, @p2, @p3)"
    (NewCustomer "Ada" "ada@example.com" (Just (fromGregorian 1815 12 10)))
  putStrLn (show n ++ " row inserted")

  -- A value never goes into the SQL text: param makes it a parameter.
  customers <- query conn $
    "SELECT id, name, email, birth_date FROM dbo.customer WHERE birth_date < "
      <> param (fromGregorian 1900 1 1)
  mapM_ print (customers :: [Customer])
```

Columns match record fields by position. The column types are checked
against the record before the first row is decoded, and a mismatch is a
`DecodeError` naming the column. `execute` returns the number of rows
affected. Tuples work in place of either record.

Connections are encrypted, and by default the server's certificate is
validated against the system's certificate store. A SQL Server on
localhost uses a self-signed certificate it generated for itself, so that
validation fails, and `tlsTrustServerCertificate = True` skips it. Use it
for development only.

For Azure SQL Database, set the hostname as well, and leave the TLS
settings alone: Azure's certificate validates as it is.

```haskell
azure = defaultConnectInfo
  { connectHost = "myserver.database.windows.net"
  , connectUser = "your_login"
  , connectPassword = "..."
  , connectDatabase = "your_database"
  }
```

To log in with Entra ID instead of a SQL login, put an access token for
`https://database.windows.net/` in `connectAccessToken` and leave the
user and password empty. Getting the token is your job, as it is with
SqlClient's `AccessToken`. It can come from Azure Managed Identity's
endpoint, from a service principal's credentials, or from
`az account get-access-token`.
[examples/managed-identity](examples/managed-identity) does it from a
container with a managed identity.

From here, [the guide](docs/guide/README.md) takes you through the rest,
with a short page each on composing queries, streaming, transactions,
several result sets, stored procedures, several statements in one round
trip, bulk copy, and MARS, which keeps several streams open on one
connection. The Haddock of the `Hmssql` module is the reference.

[examples/](examples/README.md) has a complete command-line CRUD tool
over an example database, a streaming OData server whose `$expand` zips
parent and child queries over one MARS connection, and a bulk copy
utility between two databases.

## Why another SQL Server library

There are ODBC bindings for Haskell, and there is mssql-simple. Going
through a driver and a Haskell binding adds conversion layers where data
fidelity can be lost. The binding can also limit cancellation and
concurrent streams. For example,
[tests of `odbc-0.3.0`](experiments/odbc-haskell/RESULTS.md) found that it
converts exact SQL decimals to `Double`, losing digits; Haskell timeouts
do not promptly cancel running database calls; and queries and streams
are serialized on a connection, even with MARS enabled.

Those are binding limitations. [Direct C tests](experiments/odbc/RESULTS.md)
with Microsoft's ODBC Driver 18 preserved decimals, `datetimeoffset` and
Unicode, and cancellation left connections usable. The driver itself can
silently lose information when converting between SQL and C types. For
example, requesting a generic timestamp discards the original offset
and converts to the process's time zone; narrow SQL parameters can
corrupt Unicode before it reaches a UTF-8 column.

ODBC also requires a system driver and native libraries to install and
link against. I wanted type fidelity, streaming and cancellation handled
in the Haskell client, with fewer deployment dependencies. So I chose a
native implementation.

Two already existed: ms-tds and mssql-simple. They implement TDS 7.1.
That means no `datetime2` or `datetimeoffset`, and truncated `varchar(max)`
values.

The protocol bump is not a small patch, and I had already done a year of
work on a merged fork of the two. So in a sense I *am* using
mssql-simple.

The release of hpgsql was timely. It had the streaming results and the
error handling I wanted. It is a native implementation too. So I copied
its design as closely as SQL Server allows.

Beyond filling those gaps, this is what sets hmssql apart:

* Results stream from the socket in flat memory, whatever their size.
  With MARS turned on (`connectMars`, off by default), several can be
  open on one connection at once.
* A query is one value: SQL text and parameters together. It is a
  `Monoid`, so SQL assembled at runtime is as safe as a literal.
* Several statements go in one round trip, each with its own typed
  result. Bulk copy loads a table by the protocol's bulk load.
* Interrupting a call with `timeout` or `killThread` cancels the
  statement on the server and leaves the connection usable.
* Fast, and tested hard.

[docs/dev/features.md](docs/dev/features.md) says more about each of
these, and about the ones above.

## What it doesn't do

Not supported:

* Windows/integrated authentication.
* Entra ID authentication other than with an access token you obtained.
  hmssql has no MSAL, so there are no interactive, username/password or
  device-code flows.
* Always Encrypted.
* Table-valued parameters.
* CLR user-defined types such as `hierarchyid`, `geometry` and
  `geography`. They are readable as raw bytes, or via `.ToString()`.
* Distributed transactions.
* TDS versions before 7.4. If you have a SQL Server older than 2012
  propping up a business process somewhere, ms-tds and mssql-simple still
  support TDS 7.1.

[docs/dev/limitations.md](docs/dev/limitations.md) has the full list,
with workarounds where there are any.

Not planned by me, but I'd take a contribution: integrated
authentication. It is a lot of work to test and I don't need it.

No quasi-quoter. hpgsql has `[sql| ... |]` with interpolation, and I
wanted it, until I found out it needs a Haskell parser at compile time.
`Query` is one value with its parameters inside, so a quasi-quoter can be
a separate package on top of `Hmssql.Query.Types`. I'd rather see it
there than in the library everyone links.

hmssql has been tested on macOS (arm64), Ubuntu 24.04 (including WSL)
and Windows, against SQL Server 2017, 2019, 2022 and 2025 and Azure SQL
Database. On Windows it connects over TCP, Shared Memory, or Named Pipes,
with the threaded runtime or without it. Under GHC's native I/O manager
its TCP goes through network's own calls and its pipes through the
manager, when network supports that manager. What is left before a
release, such as a run of the test matrix since the decoder rewrite and
the test scripts on Windows, is in [docs/dev/backlog.md](docs/dev/backlog.md).

Be careful about building Haskell packages on a corporate Windows
machine. The Win32 package may flag your antivirus, and you will have to
explain to IT what `cabal.exe` is.

## History and credits

hmssql descends from two Hackage packages by Takamasa Mitsuji:
[ms-tds](https://github.com/mitsuji/ms-tds), the TDS protocol, and
[mssql-simple](https://github.com/mitsuji/mssql-simple), the client API
(2018-2024). In 2025 I merged them into an unreleased `mssql` package. I
added TDS 7.2, PLP, strict encryption and more data types.

In 2026 hmssql was written as a new library, with
[hpgsql](https://github.com/mzabani/hpgsql) by Marcelo Zabani as its
design model. From hpgsql come the Applicative row decoder, generic
deriving, streaming results, and the interruption model. It reuses
mssql's serializers,
completes TDS 7.4 and 8.0, and drops the earlier versions. The connection
mutex is adapted from hpgsql's, and so is the name: I was going to call
it `mssql`.

It was written, tested and reworked by AI coding agents, directed and
reviewed by me. [docs/dev/development.md](docs/dev/development.md) says
who did what. [docs/dev/history.md](docs/dev/history.md) has the lineage
and every contributor.

## Documentation

[The guide](docs/guide/README.md) shows how to use hmssql, a short page
at a time, and then how it works.

[docs/dev/](docs/dev/README.md) is for people working on hmssql itself.
It has the design and its rejected alternatives, and what TDS and SQL
Server actually do. It also has the limitations and workarounds, the
backlog, the tests, the bugs found, the MARS research, and the history.

The protocol specification is
[\[MS-TDS\]](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/b46a581a-39de-4745-b076-ec4dbb7d13ec).
Source comments cite it by section number.
