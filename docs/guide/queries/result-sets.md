# Several result sets

A batch can contain several `SELECT` statements. `queryResultSets`
decodes one result set at a time, each into its own row type:

```haskell
(parents, children) <- queryResultSets ((,) <$> resultSet <*> resultSet) conn $ mkQuery
  "SELECT id, name FROM dbo.parent WHERE id = @id; \
  \SELECT id, parent_id, name FROM dbo.child WHERE parent_id = @id"
  (NamedParams [("id", SqlParam parentId)])
```

Statements that produce no rows are skipped: `DECLARE`, `SET` and
`UPDATE` do not count as result sets.

## The `ResultSets` monad

`ResultSets` is a `Monad`, so a later decoder can depend on earlier rows.

* `resultSet` decodes the next result set, as `query` would.
* `skipResultSet` skips one.
* `resultSetMWith` keeps the column metadata with the rows.

Asking for a result set that the response does not have throws
`UnexpectedResult`.

## A variable number of result sets

`queryMulti` reads every result set as `SqlRow`s. If every set has the
same known row shape, pass its decoder to `queryMultiWith`:

```haskell
sets <- queryMultiWith (rowDecoder :: RowDecoder (Only Int)) conn
          "SELECT 1; SELECT 2 WHERE 1 = 0"
```

Each set is checked once, even when it is empty. `queryMultiMWith` takes
a `RowDecoderMonadic` for shapes chosen at runtime, and its decoder runs
per row. The batch equivalents are `batchQueryMultiWith` and
`batchQueryMultiMWith`.

Each `ResultSet` carries `resultColumns`. `columnSqlType` from
`Hmssql.SqlType` reads the SQL type from that metadata, and recognizes
`rowversion` by its tag. Alias types are reported as their underlying
type.

## When to use it

Use one `Query` with several statements when they must share state: a
`#temp` table or a `SET` option created by one statement is seen by the
next. [Many statements in one round trip](../writing-data/batches.md)
describes the other arrangement, several statements each in a scope of
its own.
