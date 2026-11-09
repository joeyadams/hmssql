-- The source table, copydemo.event, with $(ROWS) rows.
-- Run by `hmssql-example-bulk-copy setup-demo`, which substitutes $(ROWS)
-- and $(LONG_TITLE_AT) as sqlcmd would.  Touches only its own table, so the
-- target tables (demo-target.sql) may live in the same database.

IF SCHEMA_ID('copydemo') IS NULL EXEC('CREATE SCHEMA copydemo');
GO

DROP TABLE IF EXISTS copydemo.event;
GO

CREATE TABLE copydemo.event (
    id        int IDENTITY(1, 1) NOT NULL CONSTRAINT event_pk PRIMARY KEY,
    code      varchar(20)      NOT NULL,
    title     nvarchar(100)    NOT NULL,
    note      varchar(max)     NULL,
    amount    decimal(12, 2)   NOT NULL,
    qty       smallint         NOT NULL,
    happened  datetime         NOT NULL,
    logged_at datetime2(7)     NOT NULL,
    flag      bit              NOT NULL,
    ref       uniqueidentifier NOT NULL,
    payload   varbinary(200)   NULL,
    doc       xml              NULL,
    version   rowversion
);
GO

-- Every title is short and has a non-ASCII character (é and an en dash,
-- both in code page 1252) except the one at id $(LONG_TITLE_AT), which is
-- longer than 40 characters and has a character no single-byte code page
-- has (U+2615, a hot beverage).
WITH n AS (
    SELECT TOP ($(ROWS)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT INTO copydemo.event (code, title, note, amount, qty, happened, logged_at, flag, ref, payload, doc)
SELECT
    CONCAT('EV-', FORMAT(i, '000000')),
    CASE WHEN i = $(LONG_TITLE_AT)
         THEN CONCAT(N'An unusually long title for event ', i, N' at the café ', NCHAR(0x2615))
         ELSE CONCAT(N'Event ', i, N' – café') END,
    CASE WHEN i % 7 = 0 THEN NULL ELSE REPLICATE(CAST('note ' AS varchar(max)), i % 50 + 1) END,
    CAST(i AS decimal(12, 2)) / 8,
    i % 30000,
    DATEADD(minute, i, CAST('2020-01-01T00:00:00' AS datetime)),
    DATEADD(nanosecond, (i % 10000) * 100, DATEADD(second, i, CAST('2024-01-01T00:00:00' AS datetime2(7)))),
    i % 2,
    NEWID(),
    CASE WHEN i % 5 = 0 THEN NULL ELSE CAST(HASHBYTES('SHA2_256', CONCAT('payload', i)) AS varbinary(200)) END,
    CASE WHEN i % 10 = 0 THEN CAST(CONCAT('<event id="', i, '"><tag>demo</tag></event>') AS xml) END
FROM n;
GO
