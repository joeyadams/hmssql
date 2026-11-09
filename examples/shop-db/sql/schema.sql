-- The example shop.  Re-runnable: everything is dropped and created again.
-- Batches are separated by GO lines (ShopDb.runSqlFile splits on them).

DROP PROCEDURE IF EXISTS dbo.place_order;
DROP TABLE IF EXISTS dbo.order_line;
DROP TABLE IF EXISTS dbo.sales_order;
DROP TABLE IF EXISTS dbo.product;
DROP TABLE IF EXISTS dbo.customer;
GO

CREATE TABLE dbo.customer (
  id         INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_customer PRIMARY KEY,
  public_id  UNIQUEIDENTIFIER  NOT NULL CONSTRAINT uq_customer_public_id UNIQUE,
  name       NVARCHAR(100)     NOT NULL,
  email      NVARCHAR(200)     NOT NULL CONSTRAINT uq_customer_email UNIQUE,
  birth_date DATE              NULL,
  created_at DATETIME2(3)      NOT NULL CONSTRAINT df_customer_created_at DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.product (
  id             INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_product PRIMARY KEY,
  sku            VARCHAR(20)       NOT NULL CONSTRAINT uq_product_sku UNIQUE,
  name           NVARCHAR(100)     NOT NULL,
  -- One Haskell value (a Price) stored as two columns.
  price_amount   DECIMAL(12,2)     NOT NULL,
  price_currency CHAR(3)           NOT NULL,
  stock          INT               NOT NULL CONSTRAINT ck_product_stock CHECK (stock >= 0),
  discontinued   BIT               NOT NULL CONSTRAINT df_product_discontinued DEFAULT 0,
  -- A JSON document, or NULL.
  attributes     NVARCHAR(MAX)     NULL CONSTRAINT ck_product_attributes CHECK (attributes IS NULL OR ISJSON(attributes) = 1)
);

CREATE TABLE dbo.sales_order (
  id          INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_sales_order PRIMARY KEY,
  customer_id INT               NOT NULL CONSTRAINT fk_sales_order_customer REFERENCES dbo.customer (id),
  placed_at   DATETIMEOFFSET(0) NOT NULL,
  status      VARCHAR(20)       NOT NULL CONSTRAINT ck_sales_order_status CHECK (status IN ('pending', 'shipped', 'cancelled')),
  note        NVARCHAR(400)     NULL
);

CREATE TABLE dbo.order_line (
  order_id            INT           NOT NULL CONSTRAINT fk_order_line_order REFERENCES dbo.sales_order (id),
  line_no             INT           NOT NULL,
  product_id          INT           NOT NULL CONSTRAINT fk_order_line_product REFERENCES dbo.product (id),
  quantity            INT           NOT NULL CONSTRAINT ck_order_line_quantity CHECK (quantity > 0),
  -- The price at the time of the order, again as two columns.
  unit_price_amount   DECIMAL(12,2) NOT NULL,
  unit_price_currency CHAR(3)       NOT NULL,
  CONSTRAINT pk_order_line PRIMARY KEY (order_id, line_no)
);

-- The foreign keys' indexes: a child table read in its parent's order (the
-- odata example's $expand, and crud's export) seeks by them.
CREATE INDEX ix_sales_order_customer ON dbo.sales_order (customer_id);
CREATE INDEX ix_order_line_product ON dbo.order_line (product_id);
GO

-- Places a one-line order for a product that is in stock.
--
-- Returns 0 and sets @order_id on success; returns 1 with @order_id NULL
-- when the product is unknown, discontinued, or short of stock.
CREATE PROCEDURE dbo.place_order
  @customer_id INT,
  @product_id  INT,
  @quantity    INT,
  @note        NVARCHAR(400) = NULL,
  @order_id    INT OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @amount DECIMAL(12,2), @currency CHAR(3);

  BEGIN TRANSACTION;

  UPDATE dbo.product
     SET stock = stock - @quantity,
         @amount = price_amount,
         @currency = price_currency
   WHERE id = @product_id AND stock >= @quantity AND discontinued = 0;

  IF @@ROWCOUNT = 0
  BEGIN
    ROLLBACK TRANSACTION;
    SET @order_id = NULL;
    RETURN 1;
  END

  INSERT dbo.sales_order (customer_id, placed_at, status, note)
  VALUES (@customer_id, SYSDATETIMEOFFSET(), 'pending', @note);

  SET @order_id = SCOPE_IDENTITY();

  INSERT dbo.order_line (order_id, line_no, product_id, quantity, unit_price_amount, unit_price_currency)
  VALUES (@order_id, 1, @product_id, @quantity, @amount, @currency);

  COMMIT TRANSACTION;
  RETURN 0;
END
GO
