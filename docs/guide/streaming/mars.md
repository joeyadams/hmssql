# MARS: several open streams on one connection

MARS stands for Multiple Active Result Sets. It is a SQL Server feature
that lets one connection have several responses open at once.

Without MARS, a connection has one response open at a time, and a new
request cancels the stream you were reading. With MARS, the stream stays
open, so you can read one result and make other requests as you go.

## What it is for

The usual reason is the N+1 read, where one query's rows drive a query
per row. The first result is never held in memory:

```haskell
withQueryS conn "SELECT id, name FROM dbo.customer ORDER BY id" $ \customers ->
  flip S.mapM_ customers $ \(cid :: Int, name :: Text) -> do
    orders <- query conn ("SELECT id, placed_at FROM dbo.orders WHERE customer_id = " <> param cid)
    report name (orders :: [(Int, LocalTime)])
```

The other reason is reading several tables side by side. A parent table
and its child tables can be read as one stream each, in key order, and
zipped together. The `export` command of
[examples/crud](../../../examples/crud/app/Shop/Export.hs) does that with
three tables, and the `$expand` of
[examples/odata](../../../examples/odata) does it for a query whose shape
is only known at runtime.

## What it is not for

MARS is not for speed. The server runs one request of the connection at a
time, and switches between them only where a statement sends rows, so a
lock wait or a `WAITFOR` stops every stream on the connection. Four
streams on one MARS connection took twice as long as four connections
read by four threads.

MARS is not for threads either. A MARS connection still serves one thread
at a time.

## Turning it on

Set `connectMars` on your `ConnectInfo`, here the `local` from
[Connecting](../getting-started/connecting.md#sql-server-on-localhost):

```haskell
localMars :: ConnectInfo
localMars = local { connectMars = True }
```

It is off by default. `connect` throws `MarsNotSupported` if the server
refuses it, and `connectionMars` from `Hmssql.Connection` says whether a
connection has it. Nothing else in the API changes.

## The lifecycle of a stream

Each request quietly takes a *session* of the connection, and gives it
back when its response has been read to the end or canceled.

An open stream holds its session, and it holds its statement's locks on
the server, so every stream needs an end.

**Use `withQueryS`.** When its action ends, the stream is canceled if it
was not read to the end. When the action returns, the statement is over
on the server by the time `withQueryS` returns. A `timeout` around it
returns at once, and the next request finishes the cancel.

A plain `queryS` stream stays open until one of three things happens:

* It is read to its end.
* `cancelActiveStatement` from `Hmssql.Connection` cancels every open
  response.
* `release` returns the connection to a pool.

A canceled stream throws `ResultAbandoned` if it is touched again.

## Transactions

The transaction belongs to the connection, and so do the isolation level,
every `SET` option and every `#temp` table. Every stream opened inside
`withTransaction` runs in the transaction.

SQL Server refuses to begin or commit a transaction while another request
of the connection is unfinished, and a refused commit loses the
transaction. hmssql checks first, and throws `TransactionRequestsActive`,
which names each unfinished statement.

So the order is:

1. Begin the transaction first.
2. Open the streams inside it, with `withQueryS`.
3. Finish or cancel every stream before the body returns.

"Finished" means that the stream returned; seeing the last row is not
enough. A stream taken with `S.take` up to its last row still has the end
of its response unread.

```haskell
withTransaction conn $
  withQueryS conn "SELECT id, price FROM dbo.product WHERE category = 'tea'" $ \products ->
    flip S.mapM_ products $ \(pid :: Int, price :: Decimal) ->
      execute conn (mkQuery "UPDATE dbo.product SET price = @p1 WHERE id = @p2" (price * 1.1, pid))
```

## Writing under an open stream

The transaction above is what makes that write safe.

Writing to a table while a stream over it is open needs a transaction, or
a database with `READ_COMMITTED_SNAPSHOT`. Otherwise the write waits for
the locks the open scan holds, and nothing releases them while your
thread waits for the write. The wait ends as a deadlock victim (error
1205), at `LOCK_TIMEOUT` (error 1222), or never.

Set a lock timeout in the session setup, so that the mistake is an error
rather than a hang:

```haskell
localMars = local
  { connectMars = True
  , connectSessionSetup = ["SET LOCK_TIMEOUT 30000"]
  }
```

Reads beside an open stream need nothing, and neither do writes to other
tables.

## Snapshot transactions

A transaction at `Snapshot` isolation gives every stream in it the same
snapshot, taken at the transaction's first read of a table. That is what
keeps the parent-and-children zip consistent while other connections
write. `withTransactionLevel Snapshot` needs `ALLOW_SNAPSHOT_ISOLATION`
enabled on the database.

## Canceling under `XACT_ABORT ON`

Under `SET XACT_ABORT ON`, canceling a stream inside a transaction can
roll the transaction back. Leaving `withQueryS` early does that if the
statement is still running, and `withTransaction` then throws
`TransactionEndedEarly`. Where the transaction must survive, read the
stream to its end.

## Settings under an open stream

Do not `SET` an option or `USE` a database while a stream is open. SQL
Server undoes the change when the older stream ends: the isolation level,
`XACT_ABORT`, the language and the lock timeout all go back to what they
were when that stream began.

Change settings with no stream open, or put them in
`connectSessionSetup`. `withTransactionLevel` is safe, and so are `#temp`
tables and `SESSION_CONTEXT`.

## The rules, in one place

1. Turn MARS on only where you need several responses open at once.
2. Use `withQueryS` for streams.
3. Begin the transaction first, stream inside it, and end every stream
   before the body returns.
4. Write to a table under an open stream only inside a transaction, or
   with `READ_COMMITTED_SNAPSHOT`, and set a lock timeout.
5. Read a stream to its end where the transaction must survive under
   `XACT_ABORT ON`.
6. Give large parameters and bulk loads a connection of their own.
7. On Azure SQL Database, count open streams as requests. The Basic tier
   allows 30 at once.
8. On Azure SQL Database, expect a cancel sent right behind its request
   to end the connection now and then under load. A pool replaces it.
9. Change session settings with no stream open.

## Memory and the window

A stream nobody is reading keeps at most `connectMarsWindow` packets in
memory, 64 by default, and the server waits with the rest.

Over a long round trip, the window is also the speed limit of a single
stream. The default kept up with a plain connection 45 ms from the
server.

## How it works

On the wire, MARS is the Session Multiplex Protocol. After the login,
every packet carries a 16-byte header naming its session, and the server
tags each packet it sends the same way.

One reader thread sorts the packets by session, and each stream reads
from its own queue. Sending waits for the server's window, four packets
at a time.

[docs/dev/design.md](../../dev/design.md#mars-several-responses-on-one-connection)
has the full contract, and
[docs/dev/protocol-notes.md](../../dev/protocol-notes.md#mars-and-smp)
has what the server does that shapes the rules.
