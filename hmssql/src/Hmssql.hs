-- | hmssql is a native Haskell client for Microsoft SQL Server (2017 and later) and
-- Azure SQL Database.  It implements SQL Server's wire protocol directly (TDS 7.4 and 8.0),
-- so no ODBC driver or client library is needed.
--
-- The query API resembles postgresql-simple's, with one key difference: a
-- query and its parameters are one 'Query' value, so @query conn q params@
-- becomes @query conn q@.  Unlike <https://github.com/mzabani/hpgsql hpgsql>
-- (a newer PostgreSQL library that inspired this one), hmssql does not
-- include a quasiquoter.
--
-- This module exports what most programs need: connecting, building and
-- running queries, streaming, transactions, and the classes that turn rows
-- into your records and your values into parameters.  The rest of the
-- library is a module each, listed at the end of this page.
--
-- = Getting started
--
-- > {-# LANGUAGE DeriveAnyClass, DerivingStrategies, OverloadedStrings #-}
-- > import Data.Text (Text)
-- > import Data.Time (Day, fromGregorian)
-- > import GHC.Generics (Generic)
-- > import Hmssql
-- >
-- > -- The columns of a SELECT, in order.  A nullable column is a Maybe.
-- > data Customer = Customer
-- >   { customerId :: Int
-- >   , name :: Text
-- >   , birthDate :: Maybe Day
-- >   }
-- >   deriving stock (Show, Generic)
-- >   deriving anyclass (FromSqlRow)
-- >
-- > info :: ConnectInfo
-- > info = defaultConnectInfo
-- >   { connectUser = "sa"
-- >   , connectPassword = "..."
-- >   , connectDatabase = "your_database"
-- >   , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
-- >   }
-- >
-- > main :: IO ()
-- > main = withConnection info $ \conn -> do
-- >   -- A value never goes into the SQL text: param makes it a parameter.
-- >   customers <- query conn $
-- >     "SELECT id, name, birth_date FROM dbo.customer WHERE birth_date < "
-- >       <> param (fromGregorian 1900 1 1)
-- >   mapM_ print (customers :: [Customer])
-- >
-- >   -- Or write the SQL with @p1, @p2, ... and pass a tuple or a record.
-- >   n <- execute conn $ mkQuery
-- >     "INSERT INTO dbo.customer (name, birth_date) VALUES (@p1, @p2)"
-- >     ("Ada" :: Text, Just (fromGregorian 1815 12 10))
-- >   putStrLn (show n ++ " row inserted")
--
-- The columns of the @SELECT@ match the record's fields by position.
-- Before the first row is decoded, each column's type is checked against
-- its field, and a mismatch throws 'Hmssql.Errors.DecodeError' naming the
-- column.  A tuple works in place of a record, and 'Only' wraps a single
-- column.
--
-- Connections are encrypted, and by default the server's certificate is
-- validated against the system's certificate store.  A SQL Server on
-- localhost uses a self-signed certificate it generated for itself, so
-- that validation fails, and 'tlsTrustServerCertificate' skips it.  Use
-- it for development only.
--
-- = Connecting
--
-- Start from 'defaultConnectInfo', which connects to @localhost@ on port
-- 1433, encrypts the connection and validates the server's certificate
-- against the system store, and change the fields that differ.
-- 'withConnection' opens a connection, runs an action with it and closes
-- it afterward.  'connect' and 'close' are the two halves, for a
-- connection that outlives one action.
--
-- For Azure SQL Database, set the host name, the database and the
-- credentials, and leave the TLS settings alone: Azure's certificate
-- validates as it is.
--
-- > azure = defaultConnectInfo
-- >   { connectHost = "myserver.database.windows.net"
-- >   , connectUser = "your_login"
-- >   , connectPassword = "..."
-- >   , connectDatabase = "your_database"
-- >   }
--
-- A 'Connection' belongs to one thread at a time, and it runs one request
-- at a time unless it was opened with 'connectMars'.  Give each thread
-- its own connection, from a pool.  'release' cleans a connection up as
-- it goes back to the pool, and 'renew' gives the next borrower a fresh
-- handle to it.  "Hmssql.Connection#g:pools" has a recipe for the
-- resource-pool package.
--
-- = Building queries
--
-- A 'Query' is SQL text together with its parameters.  With
-- @OverloadedStrings@, a string literal is a query with no parameters.  A
-- value never goes into the SQL text itself.  There are two ways to pass
-- it as a parameter, and they mix:
--
-- * 'param' turns a value into a parameter where it is written, and '<>'
--   joins queries:
--
--   > "SELECT id FROM dbo.customer WHERE name = " <> param name
--   >   <> " AND birth_date < " <> param cutoff
--
--   Joining renumbers the placeholders, so SQL assembled at runtime from
--   optional pieces always refers to the right parameters.  'namedParam'
--   gives a parameter a name, 'escapeIdentifier' quotes a table or column
--   name that comes from data, and 'rawSql' splices text in as it is.
--
-- * 'mkQuery' takes SQL text written with @\@p1@, @\@p2@, ... and one
--   'ToSqlRow' value holding the parameters: a tuple, a record with a
--   derived instance, an 'Only' for a single parameter, a list of
--   'SqlParam', or 'NamedParams' for text written with @\@name@
--   placeholders.
--
--   > mkQuery "UPDATE dbo.customer SET email = @p1 WHERE id = @p2" (email, customerId)
--
-- 'queryText' renders a query as it is sent, with @\@p1@ in place of each
-- value, for logging.
--
-- A query with no parameters is sent as a SQL batch.  A query with
-- parameters goes through @sp_executesql@, whose body runs in a scope of
-- its own, so a @SET@ option or a @#temp@ table it creates is gone when
-- it returns.
--
-- = Running queries
--
-- Every function here takes the connection and a 'Query'.  They differ in
-- what they make of the response:
--
-- * 'execute' runs a statement and returns the number of rows it
--   affected.  'execute_' discards the count.
-- * 'query' returns the rows of the first result set as a list.
-- * 'query1' returns exactly one row, and 'queryMay' zero or one.  Any
--   other number of rows throws 'Hmssql.Errors.UnexpectedResult'.
-- * 'queryS' returns the rows as a stream, read from the socket as they
--   are consumed, and 'withQueryS' gives the stream a scope.  The next
--   section explains.
-- * 'queryFold' folds over the rows as they arrive, with neither a list
--   nor a stream.
-- * 'queryResultSets' runs a batch that returns several result sets and
--   decodes each into its own row type.  Its 'ResultSets' argument is
--   built from 'resultSet' and 'skipResultSet'.
-- * 'executeMany' runs one statement text once for each row of
--   parameters, in one round trip.  'executeStatements' runs a list of
--   statements in one round trip.
--
-- "Hmssql.Query" has the rest: the @With@ variants, which take a decoder
-- of your own instead of the row type's instance;
-- 'Hmssql.Query.queryMulti', for result sets whose columns are known
-- only at runtime; 'Hmssql.Query.callProcedure', for stored procedures
-- with output parameters; and the forms of 'executeMany' that report
-- each statement's outcome instead of throwing the first failure.
-- "Hmssql.BatchQuery" pairs each of several statements with what to do
-- with its result and sends them all in one round trip.
-- "Hmssql.BulkCopy" loads many rows into one table by the protocol's
-- bulk load, which is the fastest way to fill a table.
--
-- = Streaming
--
-- 'queryS' returns the rows as a 'Streaming.Stream' from the @streaming@
-- package instead of as a list.  A row is read from the socket when you
-- pull it, so memory doesn't grow with the result.  Consume the stream
-- with the functions of "Streaming.Prelude", which has the functions a
-- list has, such as @S.mapM_@, @S.fold_@ and @S.take@:
--
-- > import qualified Streaming.Prelude as S
-- >
-- > withQueryS conn "SELECT id, name FROM dbo.customer" $ \rows ->
-- >   S.mapM_ (\(i :: Int, name :: Text) -> print (i, name)) rows
--
-- 'withQueryS' runs an action with the stream and cancels whatever the
-- action didn't read, so the stream never outlives its scope.  'queryS'
-- hands you the stream itself, with one rule: read it to its end before
-- the connection's next request.  That request cancels the statement, and
-- the old stream then throws 'Hmssql.Errors.ResultAbandoned'.  A
-- connection opened with 'connectMars' keeps several streams open at
-- once, and "Hmssql.Connection#mars" has the rules.
--
-- Each row is still read whole.  To stream one large value, such as a
-- @varbinary(max)@ column that holds a file, see
-- "Hmssql.Decoding#g:streaming".  "Hmssql.Encoding#g:streaming" sends a
-- large parameter the same way.
--
-- = Rows and parameters
--
-- 'FromSqlRow' turns a row into a value.  Derive it for a record whose
-- fields are 'FromSqlField' types, one field per column of the @SELECT@
-- in order, as @Customer@ above does.  Tuples and 'Only' have instances
-- already.  'FromSqlField' turns one column into a value, and the usual
-- Haskell types have instances: 'Int', 'Data.Text.Text', 'Double',
-- 'Data.Time.Day', 'Data.Time.LocalTime', 'Data.ByteString.ByteString'
-- and so on.  A nullable column is a 'Maybe'.
-- "Hmssql.Types" has the table of which SQL types each accepts.
--
-- 'ToSqlRow' and 'ToSqlField' are the other direction, for parameters.
-- Derive 'ToSqlRow' for a record to pass to 'mkQuery' or 'executeMany':
--
-- > data NewCustomer = NewCustomer { newName :: Text, newBirthDate :: Maybe Day }
-- >   deriving stock (Generic)
-- >   deriving anyclass (ToSqlRow)
--
-- 'SqlParam' wraps any parameter so that a list can mix types, and
-- 'NamedParams' pairs names with such parameters.
--
-- To decode a column into a type of your own, write a 'FromSqlField'
-- instance with the combinators of "Hmssql.Decoding", usually
-- 'Hmssql.Decoding.refineField' over an existing decoder, for an
-- enumeration stored as a @varchar@ or for a JSON column, say.
-- "Hmssql.Encoding" has the same for parameters.  "Hmssql.SqlValue" is a
-- value of any SQL type, for columns and parameters whose types are known
-- only at runtime.
--
-- = Transactions
--
-- 'withTransaction' runs an action in a transaction.  It commits if the
-- action returns and rolls back if it throws.  'withTransactionLevel'
-- does the same at a chosen 'IsolationLevel'.  A transaction can't be
-- begun inside another, and a transaction the server ended under the
-- action, after a deadlock or an error under @XACT_ABORT@, is reported as
-- an exception rather than committed.  "Hmssql.Transaction" has those
-- exceptions, and the manual 'Hmssql.Transaction.begin',
-- 'Hmssql.Transaction.commit' and 'Hmssql.Transaction.rollback'.
--
-- = Handling errors
--
-- Every exception hmssql throws is in "Hmssql.Errors".  After a
-- 'Hmssql.Errors.SqlServerError', which means the server reported an
-- error, or after a 'Hmssql.Errors.DecodeError',
-- 'Hmssql.Errors.EncodeError' or 'Hmssql.Errors.UnexpectedResult', the
-- connection is still usable.  After a 'Hmssql.Errors.ConnectionClosed',
-- 'Hmssql.Errors.ConnectionBroken' or 'Hmssql.Errors.ProtocolError' it is
-- not: close it and open another.
--
-- Nothing here takes a timeout argument.  Interrupt a call with an
-- asynchronous exception instead, from 'System.Timeout.timeout' or
-- 'Control.Concurrent.killThread'.  The statement is canceled on the
-- server, and the connection stays usable.
--
-- = The other modules
--
-- * "Hmssql.Connection": the connection options in full, the pool recipe,
--   the MARS rules, and the negotiated protocol state.
-- * "Hmssql.Query": building and running queries, in full, and the
--   low-level request and response API.
-- * "Hmssql.BatchQuery": several statements in one round trip, each with
--   its own result.
-- * "Hmssql.BulkCopy": loading many rows into one table.
-- * "Hmssql.Transaction": manual transactions, and the transaction
--   exceptions.
-- * "Hmssql.Decoding" and "Hmssql.Encoding": decoders and encoders of your
--   own, and streaming one large value.
-- * "Hmssql.SqlValue": a value of any SQL type.  "Hmssql.Types": hmssql's
--   own value types, and the tables of SQL and Haskell types.
-- * "Hmssql.Errors": every exception.
-- * "Hmssql.Catalog": a database's tables and views, with their columns,
--   keys and foreign keys, as data.  "Hmssql.SqlType": SQL Server's data
--   types by name.
-- * "Hmssql.Query.Types": the representations of the query types, for
--   libraries built on hmssql.  @Hmssql.Tds.*@: the wire protocol.
module Hmssql
  ( -- * Connections
    Connection
  , ConnectInfo (..)
  , defaultConnectInfo
  , Protocol (..)
  , withConnection
  , connect
  , close
  , release
  , renew
  , unusableReason
  , Encryption (..)
  , TlsSettings (..)
  , defaultTlsSettings

    -- * Building queries
  , Query
  , mkQuery
  , param
  , namedParam
  , escapeIdentifier
  , rawSql
  , queryText

    -- * Running queries
  , execute
  , execute_
  , query
  , query1
  , queryMay
  , queryS
  , withQueryS
  , queryFold
  , executeMany
  , executeStatements
    -- ** Several result sets
  , ResultSets
  , resultSet
  , skipResultSet
  , queryResultSets

    -- * Transactions
  , withTransaction
  , withTransactionLevel
  , IsolationLevel (..)

    -- * Rows and parameters
  , FromSqlRow (..)
  , FromSqlField (..)
  , ToSqlRow (..)
  , ToSqlField (..)
  , Only (..)
  , SqlParam (..)
  , NamedParams (..)
  ) where

import Data.Tuple.Only (Only (..))

import Hmssql.Connection
import Hmssql.Decoding (FromSqlField (..), FromSqlRow (..))
import Hmssql.Encoding (NamedParams (..), SqlParam (..), ToSqlField (..), ToSqlRow (..))
import Hmssql.Query
import Hmssql.Transaction
