# hmssql-example-crud

A command-line CRUD application over the example shop database
([`examples/shop-db`](../shop-db): customers, products, orders and order
lines, and the stored procedure `dbo.place_order`), one database operation
per function.

| Module | What's in it |
|---|---|
| [`app/Shop/Types.hs`](app/Shop/Types.hs) | The row types and their `FromSqlRow`, `ToSqlRow` and field instances |
| [`app/Shop/Queries.hs`](app/Shop/Queries.hs) | One function per database operation |
| [`app/Shop/Export.hs`](app/Shop/Export.hs) | Every customer with their orders and lines in one pass: three streams on one MARS connection, zipped |
| [`app/Main.hs`](app/Main.hs) | The command line (optparse-applicative) and the printing |

## Where to look

| Feature | Where |
|---|---|
| **Generic instances.** `Customer` derives `FromSqlRow` and `NewCustomer` derives `ToSqlRow` with `deriving anyclass`; the new customer's fields become `@p1`, `@p2`, `@p3` of an `INSERT ... OUTPUT INSERTED.id`, read back with `query1`. `Order` is generic too, once its `status` and `placed_at` fields have field instances. | `Shop.Types`: `Customer`, `NewCustomer`, `Order`; `Shop.Queries.addCustomer` |
| **Handwritten instances.** A `Price` is one Haskell value stored as two columns, which a generic instance (one column per field) can't express. `priceDecoder :: RowDecoder Price` is built from two `singleField`s and reused in the `Product` and `OrderLine` decoders. `Product`'s `attributes` column holds JSON and is decoded as `Maybe Aeson.Value` with `refineField` over the `Text` decoder. `NewProduct`'s `ToSqlRow` maps the record onto `NamedParams` with `contramap`, giving `@sku`, `@name`, `@priceAmount` and so on. | `Shop.Types`: `priceDecoder`, `instance FromSqlRow Product`, `jsonDecoder`, `instance ToSqlRow NewProduct`, `orderLineDecoder`; `Shop.Queries.addProduct` |
| **Parameterized queries built at runtime.** Optional filters become WHERE conditions, each a `Query` carrying the parameters it refers to (`param`), joined with `<>`; updates compose their SET list from `namedParam`s, and `SqlParam` lets values of different types share one list. LIKE patterns escape `%`, `_`, `[` and `\` in the user's text and use `ESCAPE '\'`. User text is never spliced into SQL. | `Shop.Queries`: `whereClause`, `containsPattern`, `listCustomers`, `listProducts`, `updateById`, `updateCustomer`, `updateProduct` |
| **A stored procedure call.** `dbo.place_order` via `callProcedure`, with `inParam`s (the optional `@note` as `Maybe Text`) and `outParam "@order_id"`; `procReturnStatus` says whether it worked, and `decodeReturnValue` reads the new order id. | `Shop.Queries.placeOrder` |
| **One batch, several typed result sets.** `customer ID` sends one batch (one `queryResultSets` call, one `@id` parameter) whose first statement, a `SELECT ... INTO #orders`, returns no result set and is passed over; then come a `Customer` set, an `Order` set (`status` decoded into the enum `OrderStatus` with `refineField`, `placed_at` as `DateTimeOffset`), an `OrderLine` set (joined with product names, via `resultSetWith` and `priceDecoder`) and a `(Text, Decimal)` totals set. The `ResultSets` decoder is monadic: with no customer it stops after the first set. | `Shop.Queries.customerReport`; `Shop.Types`: `OrderStatus`, `Order`, `orderLineDecoder` |
| **Transactions.** `order-cancel` sets the status (a parameterized UPDATE that only matches a pending order, so its row count says whether it could) and restores the stock of each line in one `withTransaction`. `customer-delete` deletes the lines, orders and customer in one transaction, rolled back by throwing if there is no such customer. | `Shop.Queries`: `cancelOrder`, `deleteCustomer` |
| **Several statements in one round trip.** `customer-delete` sends its three DELETEs in one request with `executeStatements`, which returns the three row counts; `order-cancel` restores the stock of all the order's lines with one `executeMany` (one UPDATE text, a parameter row per line). | `Shop.Queries`: `deleteCustomer`, `cancelOrder` |
| **Streams zipped over MARS.** `export` reads the customers, the orders and the order lines as three `withQueryS` streams open at once on one `connectMars` connection, each sorted by the path of keys from the customer down, and walks them together: a customer's orders are the next rows of the order stream with that customer's id, and an order's lines the next rows of the line stream with that order's id. Each table is read once, front to back, and only the current customer is held. The three statements run in one `withTransactionLevel Snapshot` transaction, so they read one state of the database. | `Shop.Export`; `Main`: the connection is MARS only for this command |

Errors the server reports (a duplicate e-mail address) reach `Main` as
`SqlServerError`; two foreign key violations (error 547) are turned into
friendlier messages where they're expected (`deleteProduct`, `placeOrder`).

## Running it

The connection settings come from `MSSQL_*` environment variables, documented
in [`examples/shop-db/src/ShopDb.hs`](../shop-db/src/ShopDb.hs):
`MSSQL_PASSWORD` is required, and `MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_USER`,
`MSSQL_DATABASE`, `MSSQL_ENCRYPT`, `MSSQL_SERVER_NAME`, `MSSQL_CA_CERT` and
`MSSQL_TRUST_SERVER_CERT` have defaults. For SQL Server on localhost:

```sh
export MSSQL_HOST=localhost MSSQL_PASSWORD='...' MSSQL_TRUST_SERVER_CERT=1
export MSSQL_DATABASE=hmssql_example_crud   # optional; default hmssql_example

stack build hmssql-example-crud
stack exec hmssql-example-setup              # create and seed the database (re-run to reset it)
stack exec -- hmssql-example-crud --help
```

```
Usage: hmssql-example-crud COMMAND

  CRUD over the hmssql example shop database

Available options:
  -h,--help                Show this help text

Available commands:
  customers                List customers, optionally filtered
  customer                 Show a customer with their orders (one batch, four
                           result sets)
  customer-add             Add a customer
  customer-update          Change some of a customer's fields
  customer-delete          Delete a customer and their orders (one transaction)
  products                 List products, optionally filtered
  product-add              Add a product
  product-update           Change a product's price, stock, or mark it
                           discontinued
  product-delete           Delete a product that appears in no order
  order-place              Place a one-line order (calls dbo.place_order)
  order-cancel             Cancel a pending order and restock its lines (one
                           transaction)
  export                   Write every customer with their orders and lines as
                           JSON, one customer per line (three streams zipped
                           over MARS)
```

Each command has its own `--help`. The commands:

```
customers [--name-like TEXT] [--born-after DATE]
customer CUSTOMER-ID
customer-add NAME EMAIL [--birth-date DATE]
customer-update CUSTOMER-ID [--name NAME] [--email EMAIL] [--birth-date DATE|none]
customer-delete CUSTOMER-ID
products [--currency CODE] [--in-stock] [--name-like TEXT]
product-add SKU NAME --price AMOUNT --currency CODE [--stock N] [--attributes JSON]
product-update PRODUCT-ID [--price AMOUNT --currency CODE] [--stock N] [--discontinued]
product-delete PRODUCT-ID
order-place CUSTOMER-ID PRODUCT-ID QUANTITY [--note TEXT]
order-cancel ORDER-ID
export
```

A failure prints a message to stderr and exits with status 1.

## Transcript

Run in this order against a freshly seeded database (`stack exec
hmssql-example-setup`); `hmssql-example-crud` stands for `stack exec --
hmssql-example-crud`. Failures are marked with their exit status.

### Customers

```
$ hmssql-example-crud customers
  1  Ada Lovelace        ada@example.com         born 1985-12-10
  2  Grace Hopper        grace@example.com       born 1990-12-09
  3  Linus Torvalds      linus@example.com
  4  Barbara Liskov      barbara@example.com     born 1979-11-07
  5  Edsger Dijkstra     edsger@example.com      born 1982-05-11
  6  Margaret Hamilton   margaret@example.com    born 1988-08-17
  7  Ken Thompson        ken@example.com
  8  Frances Allen       fran@example.com        born 1993-08-04

$ hmssql-example-crud customers --name-like an
  8  Frances Allen       fran@example.com        born 1993-08-04
```

`_` is escaped, so it matches only an underscore (unescaped, it would match
every name):

```
$ hmssql-example-crud customers --name-like _

$ hmssql-example-crud customers --born-after 1985-01-01 --name-like ar
  6  Margaret Hamilton   margaret@example.com    born 1988-08-17
```

The one-batch report:

```
$ hmssql-example-crud customer 1
Customer 1: Ada Lovelace <ada@example.com>
  public id  0f8fad5b-d9cb-469f-a165-70867728950e
  born       1985-12-10
  since      2026-01-05 09:15:00
Orders: 3
  #1  2026-02-01 10:00:00 +0000  shipped
      1 x Mechanical keyboard  at 129.00 USD =   129.00
      2 x USB-C cable, 2 m     at   9.99 USD =    19.98
  #2  2026-02-15 12:30:00 +0000  shipped  "Gift wrap, please"
      1 x 27" monitor          at 349.99 USD =   349.99
      1 x Trackball mouse      at  79.50 USD =    79.50
      3 x Notebook, dotted     at   6.50 USD =    19.50
  #9  2026-04-03 09:30:00 +0000  pending
      5 x Notebook, dotted     at   6.50 USD =    32.50
Total spent (orders not cancelled):
      630.47 USD

$ hmssql-example-crud customer 99
no such customer
# exit status 1
```

Adding and updating (only the given fields are set; `--birth-date none`
sets NULL):

```
$ hmssql-example-crud customer-add 'Alan Turing' alan@example.com --birth-date 1912-06-23
added customer 9

$ hmssql-example-crud customer-add 'Alan T' alan@example.com
SQL Server error 2627: Violation of UNIQUE KEY constraint 'uq_customer_email'. Cannot insert duplicate key in object 'dbo.customer'. The duplicate key value is (alan@example.com).
# exit status 1

$ hmssql-example-crud customer-update 9 --name 'Alan M. Turing' --birth-date none
updated customer 9

$ hmssql-example-crud customer-update 9
nothing to update
# exit status 1

$ hmssql-example-crud customer-update 99 --email x@example.com
no such customer
# exit status 1

$ hmssql-example-crud customers --name-like Alan
  9  Alan M. Turing      alan@example.com
```

### Products

```
$ hmssql-example-crud products
  1  KB-0001  Mechanical keyboard   129.00 USD  stock  25  {"backlight":true,"layout":"ANSI","switches":"tactile"}
  2  MS-0002  Trackball mouse        79.50 USD  stock  40  {"buttons":5,"wireless":true}
  3  MN-0003  27" monitor           349.99 USD  stock   8  {"refreshHz":144,"resolution":"2560x1440"}
  4  CB-0004  USB-C cable, 2 m        9.99 USD  stock 200
  5  HD-0005  Headphones            199.00 EUR  stock  15  {"noiseCancelling":true,"wireless":true}
  6  DK-0006  Standing desk         549.00 EUR  stock   3  {"heightCm":{"max":128,"min":65}}
  7  CH-0007  Office chair          399.00 EUR  stock   5
  8  LP-0008  Laptop stand           45.00 GBP  stock  30  {"material":"aluminium"}
  9  WC-0009  Webcam                 89.00 GBP  stock   0  {"resolution":"1080p"}
 10  FD-0010  Floppy disks (10)      12.00 USD  stock   0  discontinued  {"capacityMB":1.44}
 11  PN-0011  Notebook, dotted        6.50 USD  stock 120
 12  PW-0012  Power bank             35.00 EUR  stock  50  {"capacitymAh":20000,"ports":["USB-C","USB-A"]}

$ hmssql-example-crud products --currency EUR --in-stock
  5  HD-0005  Headphones            199.00 EUR  stock  15  {"noiseCancelling":true,"wireless":true}
  6  DK-0006  Standing desk         549.00 EUR  stock   3  {"heightCm":{"max":128,"min":65}}
  7  CH-0007  Office chair          399.00 EUR  stock   5
 12  PW-0012  Power bank             35.00 EUR  stock  50  {"capacitymAh":20000,"ports":["USB-C","USB-A"]}

$ hmssql-example-crud product-add TP-0013 'Trackpad, 100% glass' --price 119.00 --currency USD --stock 12 --attributes '{"multitouch":true}'
added product 13
```

A search for `%` finds only the name with a literal percent sign:

```
$ hmssql-example-crud products --name-like %
 13  TP-0013  Trackpad, 100% glass  119.00 USD  stock  12  {"multitouch":true}

$ hmssql-example-crud product-add TP-0014 Bad --price 1
Missing: --currency CODE

Usage: hmssql-example-crud product-add 
         SKU NAME --price AMOUNT --currency CODE [--stock N] [--attributes JSON]

  Add a product
# exit status 1

$ hmssql-example-crud product-update 13 --price 109.50 --currency EUR --stock 20
updated product 13

$ hmssql-example-crud product-update 13 --discontinued
updated product 13

$ hmssql-example-crud product-update 99 --stock 1
no such product
# exit status 1

$ hmssql-example-crud products --currency EUR
  5  HD-0005  Headphones            199.00 EUR  stock  15  {"noiseCancelling":true,"wireless":true}
  6  DK-0006  Standing desk         549.00 EUR  stock   3  {"heightCm":{"max":128,"min":65}}
  7  CH-0007  Office chair          399.00 EUR  stock   5
 12  PW-0012  Power bank             35.00 EUR  stock  50  {"capacitymAh":20000,"ports":["USB-C","USB-A"]}
 13  TP-0013  Trackpad, 100% glass  109.50 EUR  stock  20  discontinued  {"multitouch":true}

$ hmssql-example-crud product-delete 13
deleted product 13

$ hmssql-example-crud product-delete 1
product 1 appears in orders; mark it discontinued instead
# exit status 1
```

### Orders

`dbo.place_order` returns 1 for a product that is out of stock (9, the
webcam) or discontinued (10); an unknown customer fails its foreign key.

```
$ hmssql-example-crud order-place 8 3 2 --note 'Deliver after 5pm'
placed order 13

$ hmssql-example-crud order-place 8 9 1
product is unknown, discontinued, or short of stock
# exit status 1

$ hmssql-example-crud order-place 8 10 1
product is unknown, discontinued, or short of stock
# exit status 1

$ hmssql-example-crud order-place 99 3 1
no such customer
# exit status 1

$ hmssql-example-crud customer 8
Customer 8: Frances Allen <fran@example.com>
  public id  886313e1-3b8a-5372-9b90-0c9aee199e5d
  born       1993-08-04
  since      2026-04-01 09:00:00
Orders: 2
  #11  2026-04-06 10:10:00 +0000  pending
      1 x Power bank           at  35.00 EUR =    35.00
      1 x Headphones           at 199.00 EUR =   199.00
  #13  2026-09-26 00:54:35 +0000  pending  "Deliver after 5pm"
      2 x 27" monitor          at 349.99 USD =   699.98
Total spent (orders not cancelled):
      234.00 EUR
      699.98 USD
```

Cancelling restores the stock (the monitor's is back to 8) in the same
transaction; a shipped or already cancelled order is refused:

```
$ hmssql-example-crud order-cancel 13
cancelled order 13
  returned 2 of product 3 to stock

$ hmssql-example-crud order-cancel 13
order 13 is cancelled, not pending
# exit status 1

$ hmssql-example-crud order-cancel 1
order 1 is shipped, not pending
# exit status 1

$ hmssql-example-crud order-cancel 99
no such order
# exit status 1

$ hmssql-example-crud products --name-like monitor
  3  MN-0003  27" monitor           349.99 USD  stock   8  {"refreshHz":144,"resolution":"2560x1440"}
```

### Deleting a customer

```
$ hmssql-example-crud customer-delete 8
deleted customer 8, 2 order(s), 3 order line(s)

$ hmssql-example-crud customer 8
no such customer
# exit status 1

$ hmssql-example-crud customer-delete 99
no such customer
# exit status 1
```

### Export

One JSON document per customer, with the orders nested in it and the
lines nested in each order, written as each customer's rows have been
read from the three streams:

```
$ hmssql-example-crud export | head -3
{"id":1,"publicId":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Ada Lovelace","email":"ada@example.com","birthDate":"1985-12-10","createdAt":"2026-01-05T09:15:00","orders":[{"id":1,"placedAt":"2026-02-01T10:00:00Z","status":"shipped","note":null,"lines":[{"lineNo":1,"productId":1,"product":"Mechanical keyboard","quantity":1,"unitPrice":{"amount":129.0,"currency":"USD"}},{"lineNo":2,"productId":4,"product":"USB-C cable, 2 m","quantity":2,"unitPrice":{"amount":9.99,"currency":"USD"}}]},{"id":2,"placedAt":"2026-02-15T12:30:00Z","status":"shipped","note":"Gift wrap, please","lines":[{"lineNo":1,"productId":3,"product":"27\" monitor","quantity":1,"unitPrice":{"amount":349.99,"currency":"USD"}},{"lineNo":2,"productId":2,"product":"Trackball mouse","quantity":1,"unitPrice":{"amount":79.5,"currency":"USD"}},{"lineNo":3,"productId":11,"product":"Notebook, dotted","quantity":3,"unitPrice":{"amount":6.5,"currency":"USD"}}]},{"id":9,"placedAt":"2026-04-03T09:30:00Z","status":"pending","note":null,"lines":[{"lineNo":1,"productId":11,"product":"Notebook, dotted","quantity":5,"unitPrice":{"amount":6.5,"currency":"USD"}}]}]}
{"id":2,"publicId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","name":"Grace Hopper","email":"grace@example.com","birthDate":"1990-12-09","createdAt":"2026-01-06T10:30:00","orders":[{"id":3,"placedAt":"2026-02-20T09:05:00-05:00","status":"shipped","note":null,"lines":[{"lineNo":1,"productId":5,"product":"Headphones","quantity":1,"unitPrice":{"amount":199.0,"currency":"EUR"}}]},{"id":6,"placedAt":"2026-03-12T14:20:00-05:00","status":"pending","note":null,"lines":[{"lineNo":1,"productId":12,"product":"Power bank","quantity":2,"unitPrice":{"amount":35.0,"currency":"EUR"}},{"lineNo":2,"productId":7,"product":"Office chair","quantity":1,"unitPrice":{"amount":399.0,"currency":"EUR"}}]}]}
{"id":3,"publicId":"16fd2706-8baf-433b-82eb-8c7fada847da","name":"Linus Torvalds","email":"linus@example.com","birthDate":null,"createdAt":"2026-01-20T14:00:00","orders":[{"id":4,"placedAt":"2026-03-02T17:45:00+01:00","status":"cancelled","note":"Ordered by mistake","lines":[{"lineNo":1,"productId":6,"product":"Standing desk","quantity":1,"unitPrice":{"amount":549.0,"currency":"EUR"}}]}]}
```
