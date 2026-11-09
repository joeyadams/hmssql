# Errors and timeouts

Everything hmssql throws is defined in `Hmssql.Errors`.

## Exceptions that leave the connection usable

* `SqlServerError` below severity 20: the server reported an error.
  `sqlErrorNumber` has the number, such as 2627 for a duplicate key or
  1205 for a deadlock victim.
* `DecodeError`: a row did not fit the Haskell type.
* `EncodeError`: a parameter could not be sent, and nothing was sent.
* `UnexpectedResult`: `query1` got no row, or several.
* `ResultAbandoned`: a stream was read after it was canceled.
* `TransactionError`: see [Transactions](../writing-data/transactions.md).

A usable connection can still need its transaction rolled back.

## Exceptions that mean the connection is gone

* `SqlServerError` of severity 20 or more. The fatal error breaks the
  connection immediately, even before the server closes it.
* `ConnectionClosed`: the server closed the connection, `close` was
  called, or the network failed. `connect` throws it too, when the server
  cannot be reached.
* `ConnectionBroken`: an earlier failure left the connection in an
  unknown state, and the cause is carried inside.
* `ProtocolError`: the bytes from the server made no sense.

`ConnectionBroken` reports a failure the connection has already recorded.
The operation that failed first reports its own exception, such as a
fatal `SqlServerError` or a `ProtocolError`, so catching
`ConnectionBroken` alone does not catch that first failure. After
`close`, later requests report `ConnectionClosed` instead.

`SevereError` can be either kind. The server flagged a request as failed
without a message; a killed session does that.

## Is the connection still usable?

Ask `unusableReason`, which sends nothing:

```haskell
unusableReason conn >>= \case
  Nothing -> pure ()
  Just reason -> logWarn (show reason) >> close conn
```

`UnusableReason` lists every way a connection stops being usable, such as
`Closed`, `FatalServerError` and `DrainFailed`, and `ConnectionBroken`
carries the same reason. `Nothing` means that no failure has been seen;
it is not a probe.

## Errors worth trying again

Some server errors may pass on another connection, or a moment later:

* 1205, a deadlock victim.
* 596, a session that is being killed.
* 921 and 922, a database in recovery.

These stay `SqlServerError`, and hmssql does not retry them.

## A refused login

`connect` throws `LoginError` when the server refuses the login, and
`loginErrorNumber` says why: 18456 for a wrong password, or 4060 for a
database that cannot be opened.

Some refusals only mean "not now", and `isTransientLoginError` is `True`
for those: a server shutting down (6005), or an Azure SQL database that
is failing over or busy (40613, 40501, and 49918 to 49920).

hmssql never retries a login. Wait and try again yourself:

```haskell
connectRetrying :: ConnectInfo -> IO Connection
connectRetrying ci = go (5 :: Int)
  where
    go n = try (connect ci) >>= \case
      Left e | n > 1, isTransientLoginError e -> threadDelay 2000000 >> go (n - 1)
      Left e -> throwIO e
      Right conn -> pure conn
```

## Timeouts

Nothing in hmssql takes a timeout argument. Use `System.Timeout.timeout`:

```haskell
r <- timeout 5000000 (query conn "SELECT ...")
```

Interrupting a call sends the server an Attention at once, and the server
cancels the statement, so a timed-out `UPDATE` does not go on to commit.
The connection is ready for the next request, which reads the rest of the
canceled response first.

Until then the statement may still hold its locks. To wait for them to
go, call `cancelActiveStatement conn`, and do so before holding a
connection idle after a timeout.

`killThread` and `async`'s `cancel` work the same way.

## The two cases that break the connection

An interruption that lands while a request is being *sent* breaks the
connection, because the server may hold part of a message. Later requests
throw `ConnectionBroken`. A send is short, so this happens mainly with a
large parameter or a bulk load.

Interrupting the drain of a canceled response breaks the connection too.
The drain runs in the next request, or in `cancelActiveStatement`.

## Info messages

`PRINT` output and low-severity messages go to `connectOnInfoMessage`.
The callback runs while the response is being read, and it must not use
the connection.
