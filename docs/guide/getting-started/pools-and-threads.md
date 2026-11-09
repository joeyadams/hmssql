# Pools and threads

A connection serves one thread at a time, and it has one request
outstanding at a time. MARS, which [its own page](../streaming/mars.md)
covers, relaxes the second rule but not the first.

Do not share one connection between threads. Give each thread its own
connection, taken from a pool. If two threads do use one connection,
nothing is corrupted, because their calls take turns, but that is not what
the library is designed for.

## A pool

[resource-pool](https://hackage.haskell.org/package/resource-pool) works
well. Take a connection out with `renew` and give it back with `release`,
whether your action returned or threw. A connection the server ended while
it sat in the pool is refused by `renew`, so the recipe destroys it and
takes the next one:

```haskell
import Control.Concurrent (forkIO)
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, onException, throwIO, try)
import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Data.Pool
import System.Timeout (timeout)

withPooled :: Pool Connection -> (Connection -> IO a) -> IO a
withPooled pool act = mask $ \restore -> do
  (conn, local) <- borrow
  restore (act conn) `finally` giveBack local conn
  where
    borrow = do
      (conn0, local) <- takeResource pool
      try (renew conn0) >>= \case
        Right conn -> pure (conn, local)
        Left (e :: SomeException)
          | Just (_ :: SomeAsyncException) <- fromException e -> putResource local conn0 >> throwIO e
          | otherwise -> close conn0 >> destroyResource pool local conn0 >> borrow
    giveBack local conn = void $ forkIO $ do
      let discard = close conn >> destroyResource pool local conn
      ok <- fromMaybe False <$> timeout 5000000 (release conn) `onException` discard
      if ok then putResource local conn else discard
```

The OData example's `withPooledConnection` in
[examples/odata/app/OData/Server.hs](../../../examples/odata/app/OData/Server.hs)
is this recipe.

## What `release` does

`release` leaves the connection clean for the next borrower:

* A stream that was not read to its end is canceled.
* The session is reset, which drops temp tables, `SET` options and any
  open transaction.
* It returns `False` for a connection that is broken or closed, so that
  the pool drops it.

It is cheap. On a clean connection it sends nothing, and the reset rides
on the next borrower's first request. An open transaction is the
exception: then the reset happens at once, so that the transaction's locks
are released.

An exception from your code usually leaves the connection in working
order, for example when a `timeout` fired or an HTTP client hung up, and
`release` keeps the connection. resource-pool's own `withResource` would
destroy it and pay for a new login.

## What `renew` does

`renew` gives each borrower its own handle to the connection. After
`release`, a request issued through the old handle throws
`ConnectionReleased`, and so does reading a stream that handle returned.
That protects the next borrower from stale requests.

Cached inspection (`connectionContext`, `connectionMars` and
`inTransaction`), `unusableReason`, `close` and `renew` still work on an
old handle. Inspection does not prove that a handle is current or that a
connection is usable.

`renew` refuses a connection it knows to be dead, and throws what a
request would have thrown. It sends nothing, so a borrow costs no round
trip.

## What a pool cannot know

`renew` knows only what hmssql has seen. Two cases get past it:

* A kill that lands after `renew` and before the first request.
* A session dropped without the socket closing.

The request then fails with `ConnectionClosed` or with error 596. Run it
again on another connection only if you know it was not sent, because
after the first byte the server may have run it.

## Why `release` runs on its own thread

Canceling a stream is a round trip, so `release` runs in `forkIO` and the
caller does not wait for it. `timeout` bounds it, and because a `release`
that times out leaves a broken connection, `Nothing` counts as `False`.
