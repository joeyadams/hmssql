-- Seed data for the example shop.  Deterministic: ids and GUIDs are fixed,
-- so the examples and their documentation can refer to them.

SET IDENTITY_INSERT dbo.customer ON;
INSERT dbo.customer (id, public_id, name, email, birth_date, created_at) VALUES
  (1, '0f8fad5b-d9cb-469f-a165-70867728950e', N'Ada Lovelace',      N'ada@example.com',      '1985-12-10', '2026-01-05 09:15:00'),
  (2, '7c9e6679-7425-40de-944b-e07fc1f90ae7', N'Grace Hopper',      N'grace@example.com',    '1990-12-09', '2026-01-06 10:30:00'),
  (3, '16fd2706-8baf-433b-82eb-8c7fada847da', N'Linus Torvalds',    N'linus@example.com',    NULL,         '2026-01-20 14:00:00'),
  (4, '6ba7b810-9dad-11d1-80b4-00c04fd430c8', N'Barbara Liskov',    N'barbara@example.com',  '1979-11-07', '2026-02-02 08:45:00'),
  (5, '6ba7b811-9dad-11d1-80b4-00c04fd430c8', N'Edsger Dijkstra',   N'edsger@example.com',   '1982-05-11', '2026-02-14 16:20:00'),
  (6, '6ba7b812-9dad-11d1-80b4-00c04fd430c8', N'Margaret Hamilton', N'margaret@example.com', '1988-08-17', '2026-03-01 11:00:00'),
  (7, '6ba7b814-9dad-11d1-80b4-00c04fd430c8', N'Ken Thompson',      N'ken@example.com',      NULL,         '2026-03-15 13:10:00'),
  (8, '886313e1-3b8a-5372-9b90-0c9aee199e5d', N'Frances Allen',     N'fran@example.com',     '1993-08-04', '2026-04-01 09:00:00');
SET IDENTITY_INSERT dbo.customer OFF;

SET IDENTITY_INSERT dbo.product ON;
INSERT dbo.product (id, sku, name, price_amount, price_currency, stock, discontinued, attributes) VALUES
  (1,  'KB-0001', N'Mechanical keyboard',   129.00, 'USD', 25, 0, N'{"switches":"tactile","layout":"ANSI","backlight":true}'),
  (2,  'MS-0002', N'Trackball mouse',        79.50, 'USD', 40, 0, N'{"buttons":5,"wireless":true}'),
  (3,  'MN-0003', N'27" monitor',           349.99, 'USD',  8, 0, N'{"resolution":"2560x1440","refreshHz":144}'),
  (4,  'CB-0004', N'USB-C cable, 2 m',        9.99, 'USD', 200, 0, NULL),
  (5,  'HD-0005', N'Headphones',            199.00, 'EUR', 15, 0, N'{"wireless":true,"noiseCancelling":true}'),
  (6,  'DK-0006', N'Standing desk',         549.00, 'EUR',  3, 0, N'{"heightCm":{"min":65,"max":128}}'),
  (7,  'CH-0007', N'Office chair',          399.00, 'EUR',  5, 0, NULL),
  (8,  'LP-0008', N'Laptop stand',           45.00, 'GBP', 30, 0, N'{"material":"aluminium"}'),
  (9,  'WC-0009', N'Webcam',                 89.00, 'GBP',  0, 0, N'{"resolution":"1080p"}'),
  (10, 'FD-0010', N'Floppy disks (10)',      12.00, 'USD',  0, 1, N'{"capacityMB":1.44}'),
  (11, 'PN-0011', N'Notebook, dotted',        6.50, 'USD', 120, 0, NULL),
  (12, 'PW-0012', N'Power bank',             35.00, 'EUR', 50, 0, N'{"capacitymAh":20000,"ports":["USB-C","USB-A"]}');
SET IDENTITY_INSERT dbo.product OFF;

SET IDENTITY_INSERT dbo.sales_order ON;
INSERT dbo.sales_order (id, customer_id, placed_at, status, note) VALUES
  (1,  1, '2026-02-01 10:00:00 +00:00', 'shipped',   NULL),
  (2,  1, '2026-02-15 12:30:00 +00:00', 'shipped',   N'Gift wrap, please'),
  (3,  2, '2026-02-20 09:05:00 -05:00', 'shipped',   NULL),
  (4,  3, '2026-03-02 17:45:00 +01:00', 'cancelled', N'Ordered by mistake'),
  (5,  4, '2026-03-10 08:00:00 +00:00', 'shipped',   NULL),
  (6,  2, '2026-03-12 14:20:00 -05:00', 'pending',   NULL),
  (7,  5, '2026-03-18 11:11:00 +02:00', 'shipped',   NULL),
  (8,  6, '2026-04-01 16:00:00 +00:00', 'pending',   N'Leave at reception'),
  (9,  1, '2026-04-03 09:30:00 +00:00', 'pending',   NULL),
  (10, 7, '2026-04-05 13:00:00 -07:00', 'shipped',   NULL),
  (11, 8, '2026-04-06 10:10:00 +00:00', 'pending',   NULL),
  (12, 4, '2026-04-08 15:45:00 +00:00', 'cancelled', NULL);
SET IDENTITY_INSERT dbo.sales_order OFF;

INSERT dbo.order_line (order_id, line_no, product_id, quantity, unit_price_amount, unit_price_currency) VALUES
  (1,  1, 1,  1, 129.00, 'USD'),
  (1,  2, 4,  2,   9.99, 'USD'),
  (2,  1, 3,  1, 349.99, 'USD'),
  (2,  2, 2,  1,  79.50, 'USD'),
  (2,  3, 11, 3,   6.50, 'USD'),
  (3,  1, 5,  1, 199.00, 'EUR'),
  (4,  1, 6,  1, 549.00, 'EUR'),
  (5,  1, 8,  2,  45.00, 'GBP'),
  (5,  2, 9,  1,  89.00, 'GBP'),
  (6,  1, 12, 2,  35.00, 'EUR'),
  (6,  2, 7,  1, 399.00, 'EUR'),
  (7,  1, 5,  2, 199.00, 'EUR'),
  (8,  1, 1,  2, 129.00, 'USD'),
  (8,  2, 2,  2,  79.50, 'USD'),
  (8,  3, 4, 10,   9.99, 'USD'),
  (9,  1, 11, 5,   6.50, 'USD'),
  (10, 1, 8,  1,  45.00, 'GBP'),
  (11, 1, 12, 1,  35.00, 'EUR'),
  (11, 2, 5,  1, 199.00, 'EUR'),
  (12, 1, 3,  1, 349.99, 'USD');
