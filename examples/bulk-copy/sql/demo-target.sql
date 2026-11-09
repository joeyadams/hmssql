-- The target tables, empty, in schema copydemo.  Run by
-- `hmssql-example-bulk-copy setup-demo`.  Each takes copydemo.event's rows
-- differently:
--
--   event_copy    accepted: every column converts (varchar -> nvarchar,
--                 smallint -> int, datetime -> datetime2(3), datetime2(7) ->
--                 datetime, xml -> nvarchar(max), rowversion -> binary(8)),
--                 and copied_at, which the source lacks, gets its default.
--   event_narrow  accepted for --only id,code,title, but its title is
--                 varchar(40) in a code page 1252 collation: the one long
--                 title is refused, per row, when the load reaches it.
--   event_bad     refused by the catalog check before a row is read.

IF SCHEMA_ID('copydemo') IS NULL EXEC('CREATE SCHEMA copydemo');
GO

DROP TABLE IF EXISTS copydemo.event_copy;
DROP TABLE IF EXISTS copydemo.event_narrow;
DROP TABLE IF EXISTS copydemo.event_bad;
GO

CREATE TABLE copydemo.event_copy (
    id        int              NOT NULL CONSTRAINT event_copy_pk PRIMARY KEY,
    code      nvarchar(40)     NOT NULL,
    title     nvarchar(200)    NOT NULL,
    note      nvarchar(max)    NULL,
    amount    decimal(18, 4)   NOT NULL,
    qty       int              NOT NULL,
    happened  datetime2(3)     NOT NULL,
    logged_at datetime         NOT NULL,
    flag      bit              NOT NULL,
    ref       uniqueidentifier NOT NULL,
    payload   varbinary(max)   NULL,
    doc       nvarchar(max)    NULL,
    version   binary(8)        NULL,
    copied_at datetime2(3)     NOT NULL CONSTRAINT event_copy_copied_at DEFAULT SYSUTCDATETIME()
);

CREATE TABLE copydemo.event_narrow (
    id    int         NOT NULL CONSTRAINT event_narrow_pk PRIMARY KEY,
    code  varchar(20) NOT NULL,
    title varchar(40) COLLATE Latin1_General_CI_AS NOT NULL
);

CREATE TABLE copydemo.event_bad (
    id       int IDENTITY(1, 1) NOT NULL CONSTRAINT event_bad_pk PRIMARY KEY,
    code     int          NOT NULL,  -- varchar(20) -> int: refused
    title    char(100)    NOT NULL,  -- nvarchar(100) -> char(100): per row
    qty      varchar(10)  NOT NULL,  -- smallint -> varchar: refused
    ref      nchar(36)    NOT NULL,  -- uniqueidentifier -> nchar: refused
    happened time(0)      NOT NULL,  -- datetime -> time: per row, the date dropped
    logged_at date        NOT NULL,  -- datetime2 -> date: per row, the time dropped
    region   char(2)      NOT NULL   -- not in the source, NOT NULL, no default
);
GO
