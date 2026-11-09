# Transactions

`withTransaction` runs your action in a transaction:

```haskell
withTransaction conn $ do
  execute_ conn (mkQuery "UPDATE dbo.account SET balance = balance - @p1 WHERE id = @p2" (amount, from))
  execute_ conn (mkQuery "UPDATE dbo.account SET balance = balance + @p1 WHERE id = @p2" (amount, to))
```

The transaction commits when the body returns, and rolls back if the body
throws.

## Isolation levels

`withTransactionLevel` chooses the isolation level:

```haskell
withTransactionLevel Snapshot conn $ do ...
```

Afterwards the level is set back to READ COMMITTED, which is the level at
login. `Snapshot` needs `ALLOW_SNAPSHOT_ISOLATION` enabled on the
database.

## Exceptions

* A nested `withTransaction` throws `TransactionAlreadyActive`. SQL
  Server's nested transactions do not really nest, so hmssql refuses them.
* If the server rolled the transaction back underneath you, the body's
  return throws `TransactionEndedEarly`. A deadlock does that, and so does
  an error under `XACT_ABORT ON`. Nothing is committed by mistake.
* A body that begins a nested transaction and never ends it throws
  `TransactionStillOpen`, and everything is rolled back.

## Manual control

`begin`, `commit` and `rollback` are in `Hmssql.Transaction`, and
`inTransaction` says whether a transaction is open.

## Canceled streams under `XACT_ABORT ON`

Under `SET XACT_ABORT ON`, canceling a stream can roll the transaction
back. Leaving a `queryS` stream half-read does that when the next request
cancels it, and so does a `timeout`. `withTransaction` then throws
`TransactionEndedEarly`. Where the transaction must survive, read the
stream to its end.

## How it works

The begin is a request of its own: hmssql sends it and reads the reply
before your body runs, which is one round trip, and the commit is
another.

The begin is a Transaction Manager request rather than a
`BEGIN TRANSACTION` batch, because of MARS. On a MARS connection SQL
Server refuses the batch form, with error 3997. The Transaction Manager
request works on every connection, and on a plain one it behaves exactly
as the batch does, so hmssql uses it everywhere and has one code path.

Commit and rollback are plain T-SQL batches. The isolation level is set
back in the same batch, so it costs no extra round trip.

hmssql tracks the transaction from what the server reports, so
`inTransaction` is the server's view, and a transaction the server has
already ended is never rolled back twice.
