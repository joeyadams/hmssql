# Many statements in one round trip

`executeStatements` sends a list of statements in one request and returns
each one's row count. `executeMany` runs one statement for each row in a
list of parameter rows:

```haskell
counts <- executeMany conn "INSERT INTO dbo.item (id, name) VALUES (@p1, @p2)"
            [(1 :: Int, "one" :: Text), (2, "two"), (3, "three")]
```

## When a statement fails

The server runs the statements in order, and statements after a failed
one may still run. The first failure is thrown once the whole response has
been read. For all-or-nothing behavior, wrap the call in
`withTransaction`.

To see each statement's outcome instead of an exception, use
`executeStatementsOutcomes` or `executeManyOutcomes` from `Hmssql.Query`.

## Statements with results

A `BatchQuery` pairs each statement with what to do with its rows, and
`runBatchQuery` sends the statements together and reads the results in
order. Both are in `Hmssql.BatchQuery`:

```haskell
(updated, Only total, items) <- runBatchQuery conn $ (,,)
  <$> batchExecute ("UPDATE dbo.item SET price = price * 1.1 WHERE category = " <> param cat)
  <*> batchQuery1 ("SELECT SUM(price) FROM dbo.item WHERE category = " <> param cat)
  <*> batchQuery ("SELECT id, name FROM dbo.item WHERE category = " <> param cat)
-- updated :: Int64, total :: Double, items :: [(Int32, Text)]
```

The consumers mirror the query functions: `batchExecute`, `batchQuery`,
`batchQuery1`, `batchQueryMay`, `batchQueryFold`, `batchQueryMulti`,
`batchQueryResultSets` and `batchQueryS`. Each has a `With` variant that
takes a row decoder instead of using the row type's instance.

`batchQueryS` streams the last statement's rows after `runBatchQuery`
returns. Only the last statement can stream.

Errors behave as they do for `executeStatements`.

## Scope

Each statement is its own `sp_executesql` call, so a `SET` option or a
`#temp` table it creates lasts only until it returns. Statements that must
share such state go in one `Query` to `queryResultSets` instead, as
[Several result sets](../queries/result-sets.md) shows.

## How it works

All the statements travel in one message. The server answers each one
between markers of its own, so a consumer only ever sees its own rows.

A very long list goes out in messages of about 1 MiB each. The list is
consumed as it is sent, so memory stays bounded.
