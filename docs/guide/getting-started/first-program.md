# A first program

## Requirements

* SQL Server 2017 or later, or Azure SQL Database
* GHC 9.6 or later
* `hmssql` in your package's dependencies

## Connect to your database

Start with `defaultConnectInfo` and set your username, password and
database name. The following program connects to SQL Server on localhost
and runs a small query (`SELECT 1`) to test that the connection works:

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Hmssql

info :: ConnectInfo
info = defaultConnectInfo
  { connectUser = "sa"
  , connectPassword = "..."
  , connectDatabase = "your_database"
  , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
  }

main :: IO ()
main = withConnection info $ \conn -> do
  Only n <- query1 conn "SELECT 1" :: IO (Only Int)
  print n
```

If your program prints `1`, you have run your first query.

Here is what the code does:

* `withConnection` is a [bracket](https://wiki.haskell.org/Bracket_pattern)
  that opens the connection and makes sure it is closed when the code
  inside finishes, whether that code returns or throws an exception.
* `query1` runs a query that returns exactly one row. Use `query` for a
  query that returns any number of rows.
* `Only` is a one-element tuple, used for a row with a single column. The
  pattern `Only n` extracts that column's value into `n`.

`execute` runs a statement and returns the number of rows it affected,
and `execute_` runs one when you do not need that count. Both report
server errors as exceptions.

Connections are encrypted, and the server's certificate is checked by
default. A SQL Server on localhost generates a self-signed certificate for
itself, which fails that check, and `tlsTrustServerCertificate = True`
skips the check. Use that setting for development only;
[Encryption and security](../errors-and-security/encryption.md) shows how
to validate a self-signed certificate instead.

## Where to go next

The [CRUD example](../../../examples/crud/README.md) reads and updates
customers in a sample database. To run it, clone the repository with
`git clone https://github.com/joeyadams/hmssql` and follow the
[setup instructions](../../../examples/README.md#running).

The next page, [Connecting](connecting.md), covers Azure SQL Database,
Microsoft Entra ID and the rest of the connection settings.
