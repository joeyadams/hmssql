{-# LANGUAGE NoFieldSelectors #-}

-- | The database operations behind each subcommand.
--
-- User input only ever reaches the server as parameters.  The SQL is
-- assembled at runtime in two places (the WHERE clauses of the searches and
-- the SET lists of the updates), but only from fixed fragments written
-- here; each fragment is a 'Query' that carries the parameters it refers
-- to, so the values travel with the text without ever being part of it.
--
-- Operations that can fail for a reason the user should hear about return
-- @Either Text@; errors the server reports (a duplicate e-mail address, say)
-- are left to propagate as 'SqlServerError' and are reported by "Main".
module Shop.Queries
  ( -- * Customers
    CustomerFilter (..)
  , listCustomers
  , addCustomer
  , CustomerChanges (..)
  , updateCustomer
  , deleteCustomer
  , CustomerReport (..)
  , customerReport

    -- * Products
  , ProductFilter (..)
  , listProducts
  , addProduct
  , ProductChanges (..)
  , updateProduct
  , deleteProduct

    -- * Orders
  , placeOrder
  , cancelOrder
  ) where

import Control.Exception (Exception, throwIO, try)
import Control.Monad (unless)
import Data.Decimal (Decimal)
import Data.Functor ((<&>))
import Data.Int (Int32, Int64)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)

import Hmssql
import Hmssql.Query
import Hmssql.Errors
import Shop.Types

------------------------------------------------------------------------------
-- Composing SQL from optional pieces
--
-- The query is built at runtime.  A 'Query' is SQL text
-- with its parameters; '<>' joins queries, renumbering their positional
-- parameters, and 'param' and 'namedParam' make a parameter from a value of
-- any 'ToSqlField' type.  'SqlParam' wraps such a value so a list can hold
-- values of different types.

-- | @WHERE c1 AND c2 ...@, or nothing.  Each condition carries its own
-- parameters.
whereClause :: [Query] -> Query
whereClause [] = mempty
whereClause conds = " WHERE " <> joinWith " AND " conds

joinWith :: Query -> [Query] -> Query
joinWith _ [] = mempty
joinWith sep (q : qs) = q <> foldMap (sep <>) qs

-- | A column to set, and its new value.  The parameter is named after the
-- column.
type Assignment = (Text, SqlParam)

-- | @UPDATE table SET a = \@a, b = \@b WHERE id = \@id@: the affected row
-- count, or an error if there is nothing to set.  The column names are
-- fixed strings written in this module, never user input.
updateById :: Connection -> Query -> Int -> [Assignment] -> IO (Either Text Int64)
updateById _ _ _ [] = pure (Left "nothing to update")
updateById conn table rowId assignments =
  Right <$> execute conn
    ("UPDATE " <> table <> " SET " <> joinWith ", " [rawSql col <> " = " <> namedParam col v | (col, v) <- assignments]
      <> " WHERE id = " <> namedParam "id" rowId)

-- | A LIKE pattern matching the text anywhere, with the pattern characters
-- in the text escaped (for @ESCAPE '\\'@), so that a search for @50%@ or
-- @a_b@ finds exactly that.
containsPattern :: Text -> Text
containsPattern t = "%" <> T.concatMap escape t <> "%"
  where
    escape c
      | c `elem` ['\\', '%', '_', '['] = T.pack ['\\', c]
      | otherwise = T.singleton c

-- | 'Right' if exactly one row was affected, else the message.
oneRow :: Text -> Int64 -> Either Text ()
oneRow notFound n = if n == 1 then Right () else Left notFound

------------------------------------------------------------------------------
-- Customers

-- | The columns of 'Customer', in field order (its instance is positional).
customerColumns :: Query
customerColumns = "id, public_id, name, email, birth_date, created_at"

data CustomerFilter = CustomerFilter
  { nameLike :: Maybe Text
  , bornAfter :: Maybe Day
  }

listCustomers :: Connection -> CustomerFilter -> IO [Customer]
listCustomers conn f = query conn ("SELECT " <> customerColumns <> " FROM dbo.customer" <> cond <> " ORDER BY id")
  where
    cond = whereClause $ catMaybes
      [ f.nameLike <&> \t -> "name LIKE " <> param (containsPattern t) <> " ESCAPE '\\'"
      , f.bornAfter <&> \d -> "birth_date > " <> param d
      ]

-- | The generically encoded 'NewCustomer' supplies
-- @\@p1@, @\@p2@ and @\@p3@, in field order, to a query written with
-- 'mkQuery'.  @OUTPUT INSERTED.id@ returns the new identity as a one-row
-- result, read with 'query1'.
addCustomer :: Connection -> NewCustomer -> IO Int
addCustomer conn new = do
  Only newId <- query1 conn $ mkQuery
    "INSERT dbo.customer (public_id, name, email, birth_date) \
    \OUTPUT INSERTED.id \
    \VALUES (NEWID(), @p1, @p2, @p3)"
    new
  pure newId

-- | 'Nothing' leaves a column alone.  @birthDate = Just Nothing@ clears it.
data CustomerChanges = CustomerChanges
  { name :: Maybe Text
  , email :: Maybe Text
  , birthDate :: Maybe (Maybe Day)
  }

-- | Only the given columns are set.  The @Maybe Day@ of a cleared birth date
-- is sent as a @date@ NULL.
updateCustomer :: Connection -> Int -> CustomerChanges -> IO (Either Text ())
updateCustomer conn customerId ch =
  (>>= oneRow "no such customer") <$> updateById conn "dbo.customer" customerId (catMaybes
    [ ch.name <&> \v -> ("name", SqlParam v)
    , ch.email <&> \v -> ("email", SqlParam v)
    , ch.birthDate <&> \v -> ("birth_date", SqlParam v)
    ])

-- | Three DELETEs in one transaction.  If any of them
-- fails, or the customer turns out not to exist, nothing is deleted.
-- Returns the number of orders and order lines deleted.
--
-- The three go to the server in one request
-- ('executeStatements'), which returns each one's row count.  A failure of one
-- is thrown once all have been read (the others may have run), and
-- throwing rolls the transaction back.
deleteCustomer :: Connection -> Int -> IO (Either Text (Int64, Int64))
deleteCustomer conn customerId = catchNotFound . withTransaction conn $ do
  let p = param customerId
  counts <- executeStatements conn
    [ "DELETE l FROM dbo.order_line l JOIN dbo.sales_order o ON o.id = l.order_id WHERE o.customer_id = " <> p
    , "DELETE dbo.sales_order WHERE customer_id = " <> p
    , "DELETE dbo.customer WHERE id = " <> p
    ]
  case counts of
    [nLines, nOrders, nCustomers] -> do
      -- Throwing rolls the transaction back; catchNotFound makes it the Left.
      unless (nCustomers == 1) $ throwIO (NotFound "no such customer")
      pure (nOrders, nLines)
    _ -> throwIO (UnexpectedResult ("expected three row counts, got " ++ show counts))

-- | What 'deleteCustomer' throws to abandon its transaction.
newtype NotFound = NotFound Text
  deriving stock (Show)
  deriving anyclass (Exception)

catchNotFound :: IO a -> IO (Either Text a)
catchNotFound act = either (\(NotFound msg) -> Left msg) Right <$> try act

data CustomerReport = CustomerReport
  { customer :: Customer
  , orders :: [Order]
  , orderLines :: [OrderLine]
  , totals :: [(Text, Decimal)]  -- currency, total of the orders not cancelled
  }

-- | One batch, several result sets, each with its own type.
--
-- The whole batch below is sent to the server once, as a single
-- @sp_executesql@ call with the one parameter @\@id@ ('namedParam' once,
-- then referred to by name).  The response carries
-- its result sets one after another, and the 'ResultSets' decoder reads
-- them left to right: a 'Customer' set, an 'Order' set, an 'OrderLine' set
-- and a @(Text, Decimal)@ set, each type-checked against its own columns.
--
-- The first statement (@SELECT ... INTO #orders@) fills a temporary table
-- and returns no result set, only a row count; 'ResultSets' passes over it
-- without being told.  ('skipResultSet' is for the other case: a statement
-- that does return a result set, perhaps empty, which you don't want.)
--
-- 'ResultSets' is a 'Monad', so the decoder can stop after the first set when
-- there is no such customer; 'queryResultSets' then reads and discards the
-- rest of the response.
customerReport :: Connection -> Int -> IO (Maybe CustomerReport)
customerReport conn customerId =
  queryResultSets decoder conn batch
  where
    batch = joinWith "\n"
      [ "SELECT id INTO #orders FROM dbo.sales_order WHERE customer_id = " <> namedParam "id" customerId <> ";"
      , "SELECT " <> customerColumns <> " FROM dbo.customer WHERE id = @id;"
      , "SELECT id, customer_id, placed_at, status, note FROM dbo.sales_order"
      , "  WHERE id IN (SELECT id FROM #orders) ORDER BY placed_at;"
      , "SELECT l.order_id, l.line_no, l.product_id, p.name, l.quantity, l.unit_price_amount, l.unit_price_currency"
      , "  FROM dbo.order_line l JOIN dbo.product p ON p.id = l.product_id"
      , "  WHERE l.order_id IN (SELECT id FROM #orders) ORDER BY l.order_id, l.line_no;"
      , "SELECT l.unit_price_currency, SUM(l.quantity * l.unit_price_amount)"
      , "  FROM dbo.order_line l JOIN dbo.sales_order o ON o.id = l.order_id"
      , "  WHERE o.id IN (SELECT id FROM #orders) AND o.status <> 'cancelled'"
      , "  GROUP BY l.unit_price_currency ORDER BY l.unit_price_currency;"
      ]
    decoder :: ResultSets (Maybe CustomerReport)
    decoder = resultSet >>= \case
      [customer] -> do
        orders <- resultSet                     -- via Order's generic instance
        orderLines <- resultSetWith orderLineDecoder -- via an explicit RowDecoder
        totals <- resultSet                     -- via the tuple instance
        pure (Just CustomerReport {..})
      _ -> pure Nothing

------------------------------------------------------------------------------
-- Products

-- | The columns of 'Product', in the order its handwritten instance reads.
productColumns :: Query
productColumns = "id, sku, name, price_amount, price_currency, stock, discontinued, attributes"

data ProductFilter = ProductFilter
  { currency :: Maybe Text
  , inStock :: Bool
  , nameLike :: Maybe Text
  }

-- | Optional filters combined at runtime.  @--in-stock@
-- adds a condition without a parameter.
listProducts :: Connection -> ProductFilter -> IO [Product]
listProducts conn f = query conn ("SELECT " <> productColumns <> " FROM dbo.product" <> cond <> " ORDER BY id")
  where
    cond = whereClause $ catMaybes
      [ f.currency <&> \c -> "price_currency = " <> param c
      , if f.inStock then Just "stock > 0 AND discontinued = 0" else Nothing
      , f.nameLike <&> \t -> "name LIKE " <> param (containsPattern t) <> " ESCAPE '\\'"
      ]

-- | The handwritten 'ToSqlRow' 'NewProduct' supplies the
-- named parameters used here.
addProduct :: Connection -> NewProduct -> IO Int
addProduct conn new = do
  Only newId <- query1 conn $ mkQuery
    "INSERT dbo.product (sku, name, price_amount, price_currency, stock, attributes) \
    \OUTPUT INSERTED.id \
    \VALUES (@sku, @name, @priceAmount, @priceCurrency, @stock, @attributes)"
    new
  pure newId

data ProductChanges = ProductChanges
  { price :: Maybe Price
  , stock :: Maybe Int
  , discontinued :: Bool
  }

updateProduct :: Connection -> Int -> ProductChanges -> IO (Either Text ())
updateProduct conn productId ch =
  (>>= oneRow "no such product") <$> updateById conn "dbo.product" productId (concat
    [ maybe [] (\p -> [("price_amount", SqlParam p.amount), ("price_currency", SqlParam p.currency)]) ch.price
    , maybe [] (\n -> [("stock", SqlParam n)]) ch.stock
    , [("discontinued", SqlParam True) | ch.discontinued]
    ])

-- | A product that appears in an order can't be deleted (the foreign key
-- refuses it, error 547); that is turned into advice.
deleteProduct :: Connection -> Int -> IO (Either Text ())
deleteProduct conn productId =
  try (execute conn ("DELETE dbo.product WHERE id = " <> param productId)) >>= \case
    Right n -> pure (oneRow "no such product" n)
    Left e
      | sqlErrorNumber e == 547 ->
          pure (Left ("product " <> T.pack (show productId) <> " appears in orders; mark it discontinued instead"))
      | otherwise -> throwIO e

------------------------------------------------------------------------------
-- Orders

-- | Calling @dbo.place_order@ by RPC.
--
-- Inputs are 'inParam's, including @\@note@ as a @Maybe Text@ (a NULL when
-- absent); @\@order_id@ is an 'outParam' whose initial value, a NULL @int@,
-- fixes its declared type.  The procedure's RETURN status says whether it
-- worked (0) or found the product unknown, discontinued or short of stock
-- (1); the output value is then decoded with 'decodeReturnValue'.
placeOrder :: Connection -> Int -> Int -> Int -> Maybe Text -> IO (Either Text Int)
placeOrder conn customerId productId quantity note = do
  -- callProcedure encodes each parameter with the connection's context, and
  -- throws EncodeError if a value can't be encoded (these values always can).
  let params =
        [ inParam "@customer_id" customerId
        , inParam "@product_id" productId
        , inParam "@quantity" quantity
        , inParam "@note" note
        , outParam "@order_id" (Nothing :: Maybe Int32)
        ]
  -- The procedure doesn't check the customer; the foreign key does.
  try (callProcedure conn "dbo.place_order" params) >>= \case
    Left e
      | sqlErrorNumber e == 547 -> pure (Left "no such customer")
      | otherwise -> throwIO e
    Right res -> checkResult res
  where
    checkResult :: ProcResult -> IO (Either Text Int)
    checkResult res = case (res.procReturnStatus, res.procOutputValues) of
        (Just 0, [orderIdValue]) -> case decodeReturnValue orderIdValue of
          Right (Just orderId) -> pure (Right orderId)
          Right Nothing -> throwIO (UnexpectedResult "place_order succeeded but returned no order id")
          Left err -> throwIO err
        (Just 1, _) -> pure (Left "product is unknown, discontinued, or short of stock")
        (status, _) -> throwIO (UnexpectedResult ("place_order returned " ++ show status))

-- | A transaction.  The status change and the stock
-- restored for each line commit together, or not at all.
--
-- The UPDATE only matches a pending order, so its row count tells whether
-- the order could be cancelled; it can't be a shipped or cancelled order
-- even if another session changes it between our statements.  Returns the
-- (product id, quantity) put back in stock.
--
-- The stock of every line is restored by one
-- 'executeMany': one UPDATE text, a parameter row per line, one round
-- trip for all of them.
cancelOrder :: Connection -> Int -> IO (Either Text [(Int, Int)])
cancelOrder conn orderId = withTransaction conn $ do
  n <- execute conn $ mkQuery "UPDATE dbo.sales_order SET status = @p1 WHERE id = @p2 AND status = @p3"
    (Cancelled, orderId, Pending)
  if n == 0
    then do
      status <- queryMay conn ("SELECT status FROM dbo.sales_order WHERE id = " <> param orderId)
      pure $ Left $ case status of
        Nothing -> "no such order"
        Just (Only s) -> "order " <> T.pack (show orderId) <> " is " <> statusText s <> ", not pending"
    else do
      lines' <- query conn ("SELECT product_id, quantity FROM dbo.order_line WHERE order_id = " <> param orderId)
      _ <- executeMany conn "UPDATE dbo.product SET stock = stock + @p1 WHERE id = @p2"
        [(quantity, productId) | (productId, quantity) <- lines']
      pure (Right lines')
