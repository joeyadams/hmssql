# Streaming rows

`queryS` returns a `Stream` from the
[streaming](https://hackage.haskell.org/package/streaming) package instead
of a list. Rows are read from the socket as you pull them, so memory does
not grow with the size of the result:

```haskell
import qualified Streaming.Prelude as S

s <- queryS conn "SELECT id, payload FROM dbo.big_table"
S.mapM_ (\(i :: Int64, p :: ByteString) -> process i p) s
```

## The one rule

Finish the stream before you make another request on the connection.

If you stop early and move on, the next request cancels the statement on
the server, and what was left is discarded. The old stream throws
`ResultAbandoned` if anything touches it again.

A connection going back to a pool gets the same treatment from `release`,
so the statement does not keep its locks while the connection waits in
the pool. A web server whose client hangs up mid-response is the usual
case.

On a MARS connection the rule is different: the next request leaves the
stream open. [MARS](mars.md) explains.

## `withQueryS`

`withQueryS` is `queryS` within a scope:

```haskell
withQueryS conn "SELECT id, payload FROM dbo.big_table" $ \s ->
  S.mapM_ (\(i :: Int64, p :: ByteString) -> process i p) s
```

When the action ends, a stream that was not read to its end is canceled.
Whether the action returned or threw, the statement is over on the server
by the time `withQueryS` returns, and its locks are released.

On a MARS connection, prefer `withQueryS`. On a plain connection it works
too, under the rule above.

## Interruptions

A `timeout` around a stream read cancels the statement at once. The
stream throws `ResultAbandoned` afterwards, and the connection stays
usable.

The timeout returns at once, and the next request on the connection
finishes the cancel first. Until then the statement may still hold its
locks. To wait for them to go, call `cancelActiveStatement conn`.

Under `SET XACT_ABORT ON`, a canceled stream inside a transaction can
roll the transaction back.
[Transactions](../writing-data/transactions.md) has the details.

## Streaming within a value

A single large value can be streamed too, as chunks of one column, with
`streamField`.
[Streaming values](../decoders-and-encoders/streaming-values.md) covers
it, together with streamed parameters and the generic cell interface.

## How it works

The server sends rows in packets, and hmssql decodes a packet's rows when
you pull them. The rest waits in the socket, so memory stays flat.

Canceling sends the server an Attention. The server stops the statement
and acknowledges. An ordinary exit from `withQueryS` waits for that
acknowledgment, while an interruption leaves it to the next request.
