# Streaming values

[Streaming rows](../streaming/streaming-rows.md) reads a result one row
at a time. This page is about a single value that is too large to hold in
memory: a column consumed in chunks as it arrives, a parameter read from
a source as it is sent, and the generic cell interface underneath.

## Streaming a column

`streamField` consumes a column as its chunks arrive. It works in any
column, including several large columns among small ones:

```haskell
import qualified Data.ByteString as B
import Hmssql.Decoding (singleField, streamField, valueChunks)
import Hmssql.Query (queryWith)

let byteCount = singleField (streamField (S.sum_ . S.map B.length . valueChunks))
sizes <- queryWith byteCount conn "SELECT payload FROM dbo.documents"
```

The consumer runs on your reading thread. Any bytes it leaves unread are
skipped. Its stream expires when it returns, and replaying a pull throws
`ResultAbandoned`.

A value of 64 KiB or less is read whole first and handed over as one
chunk, which costs about what `fieldDecoder` does. Only larger values
arrive in pieces, so `streamField` suits a column of mostly short values
too.

An exception from the consumer ends the query at once: the statement is
canceled, the exception reaches you as it was thrown, and the connection
stays usable. To report a bad value instead, return an `Either String`
and wrap the decoder in `refineField id`, which gives a `DecodeError`
naming the column.

Use `nullableField` for a nullable column and `streamTextField` for text;
text decoding handles characters split across packets. A consumer may use
other responses on a MARS connection, but it must not use its own plain
connection.

A slow consumer holds the connection lock, and may keep transaction locks.
Choose its work accordingly.

## Sending a large value

Use a source when a parameter should be read as it is sent:

```haskell
import Hmssql.Encoding (binaryStream, sourceOf)
import qualified Streaming.Prelude as S

let chunks = S.each ["first", "second"]
execute conn $ "INSERT INTO dbo.documents(payload) VALUES ("
  <> param (binaryStream (sourceOf chunks)) <> ")"
```

`textStream` takes `Text` chunks, and `streamAs` chooses a PLP wire type
for raw bytes. Several streamed parameters can appear among ordinary
parameters.

A `Source` can scope resources such as an open file around the whole
send. It runs masked. Starting a request on its own connection throws
`ReentrantSource`; on a MARS connection it may read an earlier response.

A `Query` can be sent again. An explicit `Request` containing a lazy value
or a source is single-use. Output parameters remain in memory and refuse
sources.

Bulk copy accepts streamed cells too, and
[Bulk copy](../writing-data/bulk-copy.md) has the rules.

## Generic cells

`queryCells` returns the column metadata and nested streams of rows,
cells and bytes. Finishing a value gives the next cells, and finishing a
row gives the next rows. `skipCell`, `cellText` and `cellDecoded` handle
the common cases, and `cellDecoded` uses the connection context and
allocation bound carried by the cell, including for custom decoders.

`withQueryCells` cancels and drains anything left at scope exit. Each pull
holds the lock only for that pull, so on a MARS connection other requests
can run between pulls. For a known row shape, the typed field interface
above is simpler.
