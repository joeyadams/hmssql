# Stored procedures

`callProcedure` from `Hmssql.Query` runs a procedure by name. It takes
`inParam` and `outParam` parameters, and returns the result sets, the
output values and the return status:

```haskell
res <- callProcedure conn "dbo.place_order"
  [ inParam "@customer_id" customerId
  , outParam "@order_id" (Nothing :: Maybe Int32)
  ]
case (procReturnStatus res, procOutputValues res) of
  (Just 0, [orderIdValue]) -> either throwIO pure (decodeReturnValue orderIdValue :: Either DecodeError (Maybe Int32))
  (status, _) -> throwIO (userError ("place_order returned " ++ show status))
```

## The pieces

* `inParam` and `outParam` build parameters. `callProcedure` encodes them
  with the connection's context, and throws `EncodeError` before sending
  if a value cannot be encoded.
* `procOutputValues` are in the order in which you passed the output
  parameters.
* `decodeReturnValue` decodes one output value as it would a column.
* The result sets come back as `SqlRow`s.

## Output parameter types

An output parameter is declared from its initial value, and the type is
widened so that the output is not cut short: strings become `(max)`, and
decimals become `decimal(38,10)`. The Haddock of `outParam` has the
rules, and says how to declare a type yourself.

For an exact wire type, use `rawInParam` or `rawOutParam`, neither of
which widens the type:

```haskell
rawOutParam "@amount" (TIDecimalN 20 4, Nothing)
```

This declares a NULL input/output parameter of type `decimal(20,4)`.
`TIDecimalN` comes from `Hmssql.Types`.

## The other way

A procedure with typed result sets and no output parameters can run as
`EXEC dbo.report @p1` through `queryResultSets`.
