{-# LANGUAGE NoFieldSelectors #-}

-- | The shop's row types, and how each one is read from and written to SQL.
--
-- The instances are of two kinds:
--
-- * __Generic__ ('Customer', 'NewCustomer', 'Order'): every record field is
--   exactly one column (or one parameter), in declaration order, and has a
--   'FromSqlField' (or 'ToSqlField') instance.  @deriving anyclass@ is then
--   all it takes.
--
-- * __Handwritten__ ('Product', 'NewProduct', 'OrderLine'): a 'Price' is one
--   Haskell value stored as two columns, and a product's @attributes@ column
--   holds JSON.  Neither fits the generic scheme; see the comments below.
--
-- The records use 'NoFieldSelectors' so that fields can be called @id@ and
-- @name@ without clashing with the Prelude or with each other; they are read
-- with record dot syntax (@customer.name@).
module Shop.Types
  ( -- * Customers (generic instances)
    Customer (..)
  , NewCustomer (..)

    -- * Prices and products (handwritten instances)
  , Price (..)
  , priceDecoder
  , Product (..)
  , NewProduct (..)
  , jsonText

    -- * Orders
  , OrderStatus (..)
  , statusText
  , Order (..)
  , OrderLine (..)
  , orderLineDecoder
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal)
import Data.Functor.Contravariant (contramap)
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Time (Day, LocalTime)
import Data.UUID.Types (UUID)
import GHC.Generics (Generic)

import Hmssql

import Hmssql.Decoding
import Hmssql.Types
------------------------------------------------------------------------------
-- Customers: generic instances

-- | A row of @dbo.customer@.
--
-- a generically derived 'FromSqlRow'.  The derived decoder
-- is positional: it reads one column per field, left to right, so a query
-- must select @id, public_id, name, email, birth_date, created_at@ in this
-- order (see 'Shop.Queries.customerColumns').  Each column's SQL type is
-- checked against the field's type once, when the result set's metadata
-- arrives, before any row is decoded; @birth_date@ is nullable, so its field
-- is a 'Maybe'.
data Customer = Customer
  { id :: Int
  , publicId :: UUID
  , name :: Text
  , email :: Text
  , birthDate :: Maybe Day
  , createdAt :: LocalTime  -- datetime2(3), a zoneless timestamp (UTC by convention)
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromSqlRow)

-- | The fields a user supplies for a new customer.
--
-- a generically derived 'ToSqlRow'.  The fields become the
-- positional parameters @\@p1@ (name), @\@p2@ (email) and @\@p3@ (birth
-- date, a typed @date@ NULL when 'Nothing'); see 'Shop.Queries.addCustomer'.
data NewCustomer = NewCustomer
  { name :: Text
  , email :: Text
  , birthDate :: Maybe Day
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToSqlRow)

------------------------------------------------------------------------------
-- Prices and products: handwritten instances

-- | An amount of money in a currency, stored as two columns (@price_amount@
-- and @price_currency@ in @dbo.product@, @unit_price_amount@ and
-- @unit_price_currency@ in @dbo.order_line@).
data Price = Price
  { amount :: Decimal
  , currency :: Text
  }
  deriving stock (Show, Eq)

-- | Two columns, amount then currency, as one 'Price'.
--
-- 'RowDecoder' is an 'Applicative', so a decoder for
-- several columns is built from single-column 'field's and then reused as a
-- building block of bigger row decoders ('Product' and 'OrderLine' below).
-- A 'FromSqlField' instance could not do this: a field decoder sees exactly
-- one column.
priceDecoder :: RowDecoder Price
priceDecoder = Price <$> singleField fieldDecoder <*> singleField fieldDecoder

-- | A row of @dbo.product@.
data Product = Product
  { id :: Int
  , sku :: Text
  , name :: Text
  , price :: Price                   -- two columns
  , stock :: Int
  , discontinued :: Bool
  , attributes :: Maybe Aeson.Value  -- nvarchar(max) holding JSON, or NULL
  }
  deriving stock (Show)

-- | A handwritten 'FromSqlRow'.
--
-- The generic default can't be used, for two reasons:
--
-- * It is positional and takes one column per record field, through that
--   field type's 'FromSqlField' instance.  The 'price' field spans two
--   columns, which no 'FromSqlField' instance can read.
-- * @attributes@ is text in the database but a JSON 'Aeson.Value' here.  A
--   @FromSqlField Aeson.Value@ instance would be an orphan, and would claim
--   every text column for JSON; a decoder local to this row is better.
--
-- So the instance lists the columns with the applicative 'RowDecoder':
-- @id, sku, name, price_amount, price_currency, stock, discontinued,
-- attributes@ (eight columns; the decoder checks the count).
instance FromSqlRow Product where
  rowDecoder =
    Product
      <$> singleField fieldDecoder
      <*> singleField fieldDecoder
      <*> singleField fieldDecoder
      <*> priceDecoder
      <*> singleField fieldDecoder
      <*> singleField fieldDecoder
      <*> singleField jsonDecoder

-- | A nullable text column parsed as JSON.  'refineField' layers a fallible
-- conversion over the existing @Maybe Text@ decoder, keeping its SQL type
-- check and NULL handling; a parse failure becomes a 'DecodeError' that
-- names the column.
jsonDecoder :: FieldDecoder (Maybe Aeson.Value)
jsonDecoder = refineField (traverse parseJson) fieldDecoder
  where
    parseJson = Aeson.eitherDecodeStrict . T.encodeUtf8

-- | JSON as text, for a parameter or for display.
jsonText :: Aeson.Value -> Text
jsonText = T.decodeUtf8 . LB.toStrict . Aeson.encode

-- | The fields a user supplies for a new product.
data NewProduct = NewProduct
  { sku :: Text
  , name :: Text
  , price :: Price
  , stock :: Int
  , attributes :: Maybe Aeson.Value
  }
  deriving stock (Show)

-- | A handwritten 'ToSqlRow'.
--
-- The generic encoder would send one positional parameter per field, which
-- fails the same way as decoding: 'price' has to become two parameters, and
-- there is no 'ToSqlField' for a JSON value.
--
-- Instead the record is mapped onto 'NamedParams' with 'contramap', which
-- reuses 'NamedParams'' own encoder.  The parameters are then referenced by
-- name in the SQL, @\@sku@, @\@name@, @\@priceAmount@, @\@priceCurrency@,
-- @\@stock@ and @\@attributes@ (see 'Shop.Queries.addProduct'), which also
-- makes a long INSERT easier to read than @\@p1@ .. @\@p6@.  (For
-- positional parameters, @divideRow@ and @singleParam@ compose a
-- 'RowEncoder' the same way 'singleField' composes a 'RowDecoder'.)
instance ToSqlRow NewProduct where
  rowEncoder = contramap toNamed rowEncoder
    where
      toNamed :: NewProduct -> NamedParams
      toNamed p =
        NamedParams
          [ ("sku", SqlParam p.sku)
          , ("name", SqlParam p.name)
          , ("priceAmount", SqlParam p.price.amount)
          , ("priceCurrency", SqlParam p.price.currency)
          , ("stock", SqlParam p.stock)
          , ("attributes", SqlParam (jsonText <$> p.attributes))
          ]

------------------------------------------------------------------------------
-- Orders

-- | @dbo.sales_order.status@, a @varchar@ restricted by a CHECK constraint.
data OrderStatus = Pending | Shipped | Cancelled
  deriving stock (Show, Eq, Enum, Bounded)

statusText :: OrderStatus -> Text
statusText = \case
  Pending -> "pending"
  Shipped -> "shipped"
  Cancelled -> "cancelled"

-- | An enum decoded with 'refineField' over the 'Text'
-- decoder.  An unexpected value is a 'DecodeError', not a crash.
instance FromSqlField OrderStatus where
  fieldDecoder = refineField parse fieldDecoder
    where
      parse t = maybe (Left ("unknown order status " ++ show t)) Right $
        lookup t [(statusText s, s) | s <- [minBound .. maxBound]]

-- | And encoded as its text, so a status can be a query parameter.
instance ToSqlField OrderStatus where
  fieldEncoder = contramap statusText fieldEncoder

-- | A row of @dbo.sales_order@.  With field instances for 'OrderStatus' and
-- 'DateTimeOffset' (@datetimeoffset@ keeps the offset the order was placed
-- with), every field is one column again, so the instance is generic.
data Order = Order
  { id :: Int
  , customerId :: Int
  , placedAt :: DateTimeOffset
  , status :: OrderStatus
  , note :: Maybe Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromSqlRow)

-- | A row of @dbo.order_line@ joined with the product's name.
data OrderLine = OrderLine
  { orderId :: Int
  , lineNo :: Int
  , productId :: Int
  , productName :: Text
  , quantity :: Int
  , unitPrice :: Price  -- two columns again
  }
  deriving stock (Show)

-- | @order_id, line_no, product_id, product name, quantity,
-- unit_price_amount, unit_price_currency@, reusing 'priceDecoder'.  A plain
-- 'RowDecoder' rather than an instance; 'Shop.Queries.customerReport' reads
-- its result set with 'resultSetWith'.
orderLineDecoder :: RowDecoder OrderLine
orderLineDecoder =
  OrderLine
    <$> singleField fieldDecoder
    <*> singleField fieldDecoder
    <*> singleField fieldDecoder
    <*> singleField fieldDecoder
    <*> singleField fieldDecoder
    <*> priceDecoder
