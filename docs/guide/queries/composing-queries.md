# Composing queries

`Query` is a `Monoid`, and each piece carries its own parameters. When
pieces are joined, their placeholders are renumbered, so a query built
from optional parts refers to the right values however it was assembled:

```haskell
let conds = catMaybes
      [ (\d -> "birth_date < " <> param d) <$> maybeCutoff
      , (\t -> "name LIKE " <> param t) <$> maybePattern
      ]
    whereClause | null conds = mempty
                | otherwise  = " WHERE " <> mconcat (intersperse " AND " conds)
rows <- query conn ("SELECT id, name, email, birth_date FROM dbo.customer" <> whereClause
                     <> " ORDER BY " <> escapeIdentifier sortColumn)
```

## Names from data

A column or table name that comes from data goes through
`escapeIdentifier`, which bracket-quotes it as `[name]`.

## Text as it is

`rawSql` splices text in as it is. Use it for SQL that is genuinely text
rather than a value. A string literal is the same thing: a query with no
parameters.

## Logging

`queryText` renders a query as it will be sent, with the values replaced
by `@p1`, `@p2` and so on. `show` does the same, and never includes a
value.

## How it works

A `Query` is a tree of pieces, and each piece numbers its own
placeholders. The absolute numbers are computed once, when the query is
sent, so joining pieces is cheap however many there are.
