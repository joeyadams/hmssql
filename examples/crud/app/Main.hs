-- | @hmssql-example-crud@: a command-line CRUD application over the example
-- shop database.
--
-- This module is only the command line (optparse-applicative) and the
-- printing.  The row types and their instances are in "Shop.Types", the SQL
-- in "Shop.Queries", and the one-pass export of every customer with their
-- orders in "Shop.Export".  The connection settings come from the
-- environment (see "ShopDb" in the hmssql-example-shop-db package).
module Main (main) where

import Control.Exception (catch)
import Control.Monad (forM_, unless)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.Aeson.Encoding as E
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Decimal (Decimal, DecimalRaw (..), decimalPlaces, roundTo)
import Data.Foldable (for_)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Scientific (scientific)
import Data.Time (Day)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified Data.UUID.Types as UUID
import Options.Applicative
import System.Exit (die)

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import ShopDb (connectInfoFromEnv)
import Shop.Export
import Shop.Queries
import Shop.Types

data Command
  = Customers CustomerFilter
  | CustomerShow Int
  | CustomerAdd NewCustomer
  | CustomerUpdate Int CustomerChanges
  | CustomerDelete Int
  | Products ProductFilter
  | ProductAdd NewProduct
  | ProductUpdate Int ProductChanges
  | ProductDelete Int
  | OrderPlace Int Int Int (Maybe Text)
  | OrderCancel Int
  | Export

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper) (progDesc "CRUD over the hmssql example shop database"))
  info <- connectInfoFromEnv
  -- Only the export keeps several streams open at once, which takes a
  -- MARS connection; the other commands make one request at a time.
  let mars = case cmd of
        Export -> True
        _ -> False
  -- An error the server reports (a duplicate e-mail address, a customer id
  -- that doesn't exist in order-place, ...) arrives as a SqlServerError.
  withConnection info { connectMars = mars } (run cmd) `catch` \(e :: SqlServerError) ->
    die ("SQL Server error " ++ show (sqlErrorNumber e) ++ ": " ++ T.unpack (sqlErrorMessage e))

run :: Command -> Connection -> IO ()
run cmd conn = case cmd of
  Customers f -> listCustomers conn f >>= mapM_ (T.putStrLn . customerLine)
  CustomerShow cid -> customerReport conn cid >>= maybe (die "no such customer") printReport
  CustomerAdd new -> addCustomer conn new >>= \i -> putStrLn ("added customer " ++ show i)
  CustomerUpdate cid ch -> updateCustomer conn cid ch >>= orFail (\() -> putStrLn ("updated customer " ++ show cid))
  CustomerDelete cid -> deleteCustomer conn cid >>= orFail (\(orders, lines') ->
    putStrLn ("deleted customer " ++ show cid ++ ", " ++ show orders ++ " order(s), " ++ show lines' ++ " order line(s)"))
  Products f -> listProducts conn f >>= mapM_ (T.putStrLn . productLine)
  ProductAdd new -> addProduct conn new >>= \i -> putStrLn ("added product " ++ show i)
  ProductUpdate pid ch -> updateProduct conn pid ch >>= orFail (\() -> putStrLn ("updated product " ++ show pid))
  ProductDelete pid -> deleteProduct conn pid >>= orFail (\() -> putStrLn ("deleted product " ++ show pid))
  OrderPlace cid pid qty note -> placeOrder conn cid pid qty note >>= orFail (\oid -> putStrLn ("placed order " ++ show oid))
  OrderCancel oid -> cancelOrder conn oid >>= orFail (\restocked -> do
    putStrLn ("cancelled order " ++ show oid)
    forM_ restocked $ \(pid, qty) -> putStrLn ("  returned " ++ show qty ++ " of product " ++ show pid ++ " to stock"))
  Export -> exportCustomers conn (LB.putStrLn . E.encodingToLazyByteString . documentJson)

-- | Print a failure to stderr and exit with status 1, or carry on.
orFail :: (a -> IO ()) -> Either Text a -> IO ()
orFail = either (die . T.unpack)

------------------------------------------------------------------------------
-- Printing

customerLine :: Customer -> Text
customerLine c = T.stripEnd $ T.intercalate "  "
  [ padL 3 (tshow c.id), padR 18 c.name, padR 22 c.email
  , maybe "" (("born " <>) . tshow) c.birthDate ]

productLine :: Product -> Text
productLine p = T.intercalate "  " $
  [ padL 3 (tshow p.id), padR 7 p.sku, padR 20 p.name, padL 10 (priceText p.price)
  , "stock " <> padL 3 (tshow p.stock) ]
  ++ ["discontinued" | p.discontinued]
  ++ maybe [] (pure . jsonText) p.attributes

printReport :: CustomerReport -> IO ()
printReport r = do
  let c = r.customer
  T.putStrLn ("Customer " <> tshow c.id <> ": " <> c.name <> " <" <> c.email <> ">")
  T.putStrLn ("  public id  " <> UUID.toText c.publicId)
  T.putStrLn ("  born       " <> maybe "unknown" tshow c.birthDate)
  T.putStrLn ("  since      " <> tshow c.createdAt)
  T.putStrLn ("Orders: " <> tshow (length r.orders))
  forM_ r.orders $ \o -> do
    T.putStrLn ("  #" <> tshow o.id <> "  " <> tshow (dateTimeOffsetToZonedTime o.placedAt)
      <> "  " <> statusText o.status <> maybe "" (\n -> "  \"" <> n <> "\"") o.note)
    forM_ (filter (\l -> l.orderId == o.id) r.orderLines) $ \l ->
      T.putStrLn ("      " <> tshow l.quantity <> " x " <> padR 20 l.productName <> " at " <> padL 10 (priceText l.unitPrice)
        <> " = " <> padL 8 (tshow (lineTotal l)))
  unless (null r.totals) $ T.putStrLn "Total spent (orders not cancelled):"
  for_ r.totals $ \(cur, total :: Decimal) -> T.putStrLn ("  " <> padL 10 (tshow total) <> " " <> cur)

-- | Decimal's (*) drops trailing zeros (1 * 129.00 = 129), so round back to
-- the price's scale.
lineTotal :: OrderLine -> Decimal
lineTotal l = roundTo (decimalPlaces l.unitPrice.amount) (fromIntegral l.quantity * l.unitPrice.amount)

priceText :: Price -> Text
priceText p = tshow p.amount <> " " <> p.currency

-- | A customer's document as JSON: one object per customer, with the orders
-- nested in it and the lines nested in each order.
documentJson :: CustomerDocument -> E.Encoding
documentJson d = E.pairs $
  "id" .= d.customer.id
    <> "publicId" .= d.customer.publicId
    <> "name" .= d.customer.name
    <> "email" .= d.customer.email
    <> "birthDate" .= d.customer.birthDate
    <> "createdAt" .= d.customer.createdAt
    <> E.pair "orders" (E.list orderJson d.orders)
  where
    orderJson o = E.pairs $
      "id" .= o.order.id
        <> "placedAt" .= dateTimeOffsetToZonedTime o.order.placedAt
        <> "status" .= statusText o.order.status
        <> "note" .= o.order.note
        <> E.pair "lines" (E.list lineJson o.lines)
    lineJson l = E.pairs $
      "lineNo" .= l.lineNo
        <> "productId" .= l.productId
        <> "product" .= l.productName
        <> "quantity" .= l.quantity
        <> E.pair "unitPrice" (E.pairs ("amount" .= decimalJson l.unitPrice.amount <> "currency" .= l.unitPrice.currency))
    decimalJson (Decimal places mantissa) = scientific mantissa (negate (fromIntegral places))

tshow :: Show a => a -> Text
tshow = T.pack . show

padR, padL :: Int -> Text -> Text
padR n = T.justifyLeft n ' '
padL n = T.justifyRight n ' '

------------------------------------------------------------------------------
-- Command line

commandParser :: Parser Command
commandParser = hsubparser $ mconcat
  [ cmd "customers" "List customers, optionally filtered" $
      Customers <$> (CustomerFilter <$> optional nameLikeOpt <*> optional (option day (long "born-after" <> metavar "DATE")))
  , cmd "customer" "Show a customer with their orders (one batch, four result sets)" $
      CustomerShow <$> idArg "CUSTOMER"
  , cmd "customer-add" "Add a customer" $
      fmap CustomerAdd $ NewCustomer
        <$> strArgument (metavar "NAME")
        <*> strArgument (metavar "EMAIL")
        <*> optional (option day (long "birth-date" <> metavar "DATE"))
  , cmd "customer-update" "Change some of a customer's fields" $
      CustomerUpdate <$> idArg "CUSTOMER" <*> (CustomerChanges
        <$> optional (strOption (long "name" <> metavar "NAME"))
        <*> optional (strOption (long "email" <> metavar "EMAIL"))
        <*> optional (option dayOrNone (long "birth-date" <> metavar "DATE|none")))
  , cmd "customer-delete" "Delete a customer and their orders (one transaction)" $
      CustomerDelete <$> idArg "CUSTOMER"
  , cmd "products" "List products, optionally filtered" $
      fmap Products $ ProductFilter
        <$> optional (strOption (long "currency" <> metavar "CODE"))
        <*> switch (long "in-stock" <> help "Only products in stock and not discontinued")
        <*> optional nameLikeOpt
  , cmd "product-add" "Add a product" $
      fmap ProductAdd $ NewProduct
        <$> strArgument (metavar "SKU")
        <*> strArgument (metavar "NAME")
        <*> priceOpts
        <*> option auto (long "stock" <> metavar "N" <> value 0 <> showDefault)
        <*> optional (option json (long "attributes" <> metavar "JSON"))
  , cmd "product-update" "Change a product's price, stock, or mark it discontinued" $
      ProductUpdate <$> idArg "PRODUCT" <*> (ProductChanges
        <$> optional priceOpts
        <*> optional (option auto (long "stock" <> metavar "N"))
        <*> switch (long "discontinued"))
  , cmd "product-delete" "Delete a product that appears in no order" $
      ProductDelete <$> idArg "PRODUCT"
  , cmd "order-place" "Place a one-line order (calls dbo.place_order)" $
      OrderPlace <$> idArg "CUSTOMER" <*> idArg "PRODUCT" <*> argument auto (metavar "QUANTITY")
        <*> optional (strOption (long "note" <> metavar "TEXT"))
  , cmd "order-cancel" "Cancel a pending order and restock its lines (one transaction)" $
      OrderCancel <$> idArg "ORDER"
  , cmd "export" "Write every customer with their orders and lines as JSON, one customer per line (three streams zipped over MARS)" $
      pure Export
  ]
  where
    cmd name desc p = command name (info p (progDesc desc))
    idArg name = argument auto (metavar (name ++ "-ID"))
    nameLikeOpt = strOption (long "name-like" <> metavar "TEXT" <> help "Name contains TEXT (%, _ and [ match themselves)")
    -- Both options together, or neither: optparse-applicative reports a
    -- missing half.
    priceOpts = Price
      <$> option (auto @Decimal) (long "price" <> metavar "AMOUNT")
      <*> strOption (long "currency" <> metavar "CODE")
    day = maybeReader iso8601ParseM
    dayOrNone = maybeReader $ \s -> if s == "none" then Just Nothing else Just <$> (iso8601ParseM s :: Maybe Day)
    json = eitherReader (Aeson.eitherDecodeStrict . T.encodeUtf8 . T.pack)
