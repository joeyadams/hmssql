# Parameters

A value never goes into the SQL text. There are two ways to send one, and
they can be mixed.

## `param`

`param` splices a value in as a parameter, at the place where it is
written:

```haskell
older <- query conn ("SELECT id, name FROM dbo.customer WHERE birth_date < " <> param cutoff)
```

## `mkQuery`

`mkQuery` takes SQL text with `@p1`, `@p2` and so on, and a `ToSqlRow`
value that supplies them. The value can be:

* a tuple,
* a record with a derived `ToSqlRow` instance,
* an `Only`, for one parameter, or
* a list of `SqlParam`. `SqlParam` wraps any parameter type, so the list
  can be mixed and built at runtime.

```haskell
data NewCustomer = NewCustomer { newName :: Text, newEmail :: Text, newBirthDate :: Maybe Day }
  deriving stock (Generic)
  deriving anyclass (ToSqlRow)

n <- execute conn (mkQuery "INSERT INTO dbo.customer (name, email, birth_date) VALUES (@p1, @p2, @p3)" newCustomer)

n <- execute conn (mkQuery "UPDATE dbo.customer SET email = @p1 WHERE id = @p2" (newEmail, customerId))
```

## Named parameters

Names read better in a long `INSERT`. Use `NamedParams`, or `namedParam`
with `<>`:

```haskell
execute conn (mkQuery "UPDATE dbo.customer SET email = @email WHERE id = @id"
  (NamedParams [("email", SqlParam newEmail), ("id", SqlParam customerId)]))
```

The names `@p1`, `@p2` and so on are reserved in `mkQuery` text, so a
variable of that name needs another name.

## What each type is sent as

Each Haskell type is sent as one SQL type. `Int` is sent as `bigint`,
`Text` as `nvarchar` of any length, and `LocalTime` as `datetime2(7)`.
The full table is in the Haddock of `Hmssql.Types`.

The server converts where it can, but a mismatch can cost you an index:
comparing an `nvarchar` parameter against a `varchar` column can turn an
index seek into a scan. [Encoders](../decoders-and-encoders/encoders.md)
explains how the declared type is chosen, how to choose it yourself, and
what changes when a string is longer than 4000 characters.

## How it works

A query with parameters is sent as a call to `sp_executesql`, and its body
runs in a scope of its own: a `SET` option or a `#temp` table it creates
lasts only until the call returns.

A query without parameters is sent as a plain batch, with the text as it
is. That is what `CREATE PROCEDURE` and session-level `SET` options need.
