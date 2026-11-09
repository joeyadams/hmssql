{-# LANGUAGE NoFieldSelectors #-}

-- | Every customer with their orders and each order's lines, read in one
-- pass: three streams open at once on one MARS connection, each sorted by
-- the path of keys from the customer down, and zipped on the client.  Each
-- table is read once, front to back, and only the current customer's rows
-- are held, however many customers there are.
--
-- The three statements start at different times and run as the documents
-- are written, so they run in one snapshot transaction, which makes them
-- read one state of the database whatever other connections commit
-- meanwhile.
module Shop.Export
  ( CustomerDocument (..)
  , OrderDocument (..)
  , exportCustomers
  ) where

import Control.Monad (forM)
import Data.IORef
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S

import Hmssql
import Hmssql.Query (withQuerySWith)
import Shop.Types

data CustomerDocument = CustomerDocument
  { customer :: Customer
  , orders :: [OrderDocument]
  }

data OrderDocument = OrderDocument
  { order :: Order
  , lines :: [OrderLine]
  }

-- | Give every customer's document to the action, in customer id order.
--
-- The transaction is begun first, and each stream is read to its end
-- inside it: SQL Server refuses to commit while a request of the
-- connection is still active.  'withQueryS' cancels a stream that was not
-- read to its end when its action leaves early, by return or by an
-- exception, so the transaction can still commit or roll back.
exportCustomers :: Connection -> (CustomerDocument -> IO ()) -> IO ()
exportCustomers conn emit =
  withTransactionLevel Snapshot conn $
  withQueryS conn "SELECT id, public_id, name, email, birth_date, created_at FROM dbo.customer ORDER BY id" $ \customers ->
  withQueryS conn "SELECT id, customer_id, placed_at, status, note FROM dbo.sales_order ORDER BY customer_id, id" $ \orders ->
  withQuerySWith orderLineDecoder conn
    "SELECT l.order_id, l.line_no, l.product_id, p.name, l.quantity, l.unit_price_amount, l.unit_price_currency \
    \FROM dbo.order_line l JOIN dbo.sales_order o ON o.id = l.order_id JOIN dbo.product p ON p.id = l.product_id \
    \ORDER BY o.customer_id, l.order_id, l.line_no" $ \lines -> do
    nextOrders <- newCursor orders
    nextLines <- newCursor lines
    flip S.mapM_ customers $ \(customer :: Customer) -> do
      os <- takeWhileC (\(o :: Order) -> o.customerId == customer.id) nextOrders
      docs <- forM os $ \order -> do
        ls <- takeWhileC (\l -> l.orderId == order.id) nextLines
        pure OrderDocument { order, lines = ls }
      emit CustomerDocument { customer, orders = docs }

-- | A stream and the row at its front: one row of lookahead, so that a row
-- can be looked at without being consumed until it is known which parent
-- it belongs to.
newtype Cursor a = Cursor (IORef (Either () (a, Stream (Of a) IO ())))

newCursor :: Stream (Of a) IO () -> IO (Cursor a)
newCursor s = Cursor <$> (S.next s >>= newIORef)

-- | The rows at the front of the stream that satisfy the predicate.  The
-- first row that doesn't stays in the cursor, for the next parent.
takeWhileC :: (a -> Bool) -> Cursor a -> IO [a]
takeWhileC p (Cursor ref) = go
  where
    go = readIORef ref >>= \case
      Right (x, rest) | p x -> do
        S.next rest >>= writeIORef ref
        (x :) <$> go
      _ -> pure []
