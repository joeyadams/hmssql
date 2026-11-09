{-# LANGUAGE MagicHash #-}
-- | Building queries, running them and reading their results.
--
-- Every function takes a 'Connection' and a 'Query': SQL text with its
-- parameters, built as described under "Hmssql.Query#g:building".  A query
-- with no parameters is sent as a plain SQL batch; one with parameters is
-- sent via @sp_executesql@, with the positional parameters as @\@p1@,
-- @\@p2@, ... and the named ones by name.
--
-- The functions differ in what they make of the response:
--
-- * 'execute': the number of rows affected; 'execute_' discards the count.
-- * 'query': the rows of the first result set, as a list; 'query1' and
--   'queryMay' for exactly one and at most one row.
-- * 'queryS': the rows of the first result set as a 'Stream', read from
--   the socket as they are consumed; 'queryFold' folds over them as they
--   arrive.
-- * 'queryCells': each row as a stream of cells, and each cell as a stream of
--   bytes, for a value too large to hold in memory.
-- * 'queryResultSets': several result sets, each into its own row type;
--   'queryMulti': every result set, as 'SqlRow's.
-- * 'callProcedure': a stored procedure by RPC, with its output parameters
--   and return status.
--
-- The plain functions decode with the row type's 'FromSqlRow' instance;
-- the @With@ variants take a 'RowDecoder', and the @MWith@ variants a
-- 'RowDecoderMonadic', which runs per row and can look at the columns.
-- Both forms must consume the whole row. Monadic decoders cannot check
-- an empty result set, since no decoder runs for it.
--
-- A 'queryS' stream must be consumed before another request is made on
-- the same connection; a newer request cancels the pending one, and the
-- old stream then throws 'ResultAbandoned' (see 'queryS').  On a MARS
-- connection ('Hmssql.Connection.connectMars') it needn't be: several
-- responses can be open at once, and 'withQueryS' gives a stream that is
-- canceled when its scope ends.
--
-- Several statements in one round trip, each with its own result, are
-- "Hmssql.BatchQuery"; many rows into one table, "Hmssql.BulkCopy".
module Hmssql.Query
  ( -- * Building queries #building#
    -- | The simplest query is a string literal (with @OverloadedStrings@),
    -- sent as a plain batch:
    --
    -- > execute conn "CREATE TABLE #t (i int)"
    --
    -- Parameters travel with the text, never inside it.  Either write the
    -- SQL in the @sp_executesql@ style, referring to the parameters of a
    -- 'ToSqlRow' value as @\@p1@, @\@p2@, ... (or by name, with
    -- 'NamedParams'):
    --
    -- > query conn (mkQuery "SELECT name FROM sys.tables WHERE schema_id = @p1" (Only (1 :: Int)))
    --
    -- or compose the query from pieces, each carrying its own parameters,
    -- with '<>':
    --
    -- > query conn ("SELECT name FROM sys.tables WHERE schema_id = " <> param (1 :: Int)
    -- >             <> " AND name LIKE " <> param ("t%" :: Text))
    --
    -- The two styles mix freely; placeholders are renumbered as queries
    -- are concatenated, so a query built from parts refers to its
    -- parameters correctly however it was assembled.  Identifiers that
    -- come from data go through 'escapeIdentifier'; 'rawSql' splices text
    -- as it is, for SQL assembled at runtime.
    --
    -- A query with no parameters is sent as a SQL batch (statements such
    -- as @CREATE PROCEDURE@ and @SET@ options that must outlive the
    -- request need that); a query with parameters is sent as an
    -- @sp_executesql@ call, whose body runs in its own scope.
    Query
  , mkQuery
  , rawSql
  , param
  , namedParam
  , escapeIdentifier
  , queryText

    -- * Statements
  , execute
  , execute_

    -- * Queries
  , query
  , query1
  , query1With
  , queryMay
  , queryMayWith
  , queryWith
  , queryMWith

    -- * Folding queries
  , queryFold
  , queryFoldWith

    -- * Streaming queries #streaming#
    -- | 'queryS' and 'withQueryS' give the rows as a 'Stream' from the @streaming@
    -- package.  Rows are read from the socket as you pull them, so memory doesn't grow
    -- with the result:
    --
    -- > import qualified Streaming.Prelude as S
    -- >
    -- > withQueryS conn "SELECT id, name FROM dbo.customer" $ \rows ->
    -- >   S.mapM_ (\(i :: Int64, name :: Text) -> T.putStrLn (T.pack (show i) <> " " <> name)) rows
    --
    -- Each row is still read whole.  To stream a large value within a row, see
    -- "Hmssql.Decoding#g:streaming".
  , queryS
  , querySWith
  , querySMWith
  , withQueryS
  , withQuerySWith
  , withQuerySMWith

    -- * Streaming cells #cells#
    -- | 'queryCells' and 'withQueryCells' give nested streams: rows of cells, and cells
    -- of bytes.  They let what you read in one column decide what to do with a later
    -- one.  Here, each row's first column names the file for its second, using @toFile@
    -- from "Hmssql.Decoding#g:streaming":
    --
    -- > import Streaming (inspect)
    -- >
    -- > withQueryCells conn "SELECT name, payload FROM dbo.documents" $ \_ rows ->
    -- >   let nextRow remaining = inspect remaining >>= \case
    -- >         Left () -> pure ()
    -- >         Right row -> do
    -- >           Right nameCell <- inspect row
    -- >           (Right name, afterName) <- cellDecoded (fieldDecoder @FilePath) nameCell
    -- >           Right payloadCell <- inspect afterName
    -- >           (Right (), afterPayload) <- cellDecoded (streamField (toFile name)) payloadCell
    -- >           Left more <- inspect afterPayload
    -- >           nextRow more
    -- >    in nextRow rows
    --
    -- When each column can be handled without the others, a field decoder is simpler
    -- and faster ("Hmssql.Decoding#g:streaming").
  , Cell (..), CellValue (..), RowCells, queryCells, withQueryCells
  , cellDecoded, cellText, skipCell

    -- * Several result sets
  , ResultSets
  , resultSet
  , resultSetWith
  , resultSetMWith
  , skipResultSet
  , queryResultSets
  , ResultSet (..)
  , queryMulti
  , queryMultiWith
  , queryMultiMWith

    -- * Stored procedures
  , callProcedure
  , ProcParam (..)
  , inParam
  , outParam
  , rawInParam
  , rawOutParam
  , ProcResult (..)
  , decodeReturnValue

    -- * Several statements in one request
  , executeMany
  , executeStatements
  , StatementOutcome (..)
  , executeManyOutcomes
  , executeStatementsOutcomes

    -- * Low level
    -- | Requests and responses as the query functions see them, for code
    -- that reads a response token by token.  Nothing here is needed to
    -- use the functions above.  The constructors of 'Request',
    -- 'ResponseStep' and 'RowBatch' are in "Hmssql.Query.Types".
  , Request, bytesBody
  , queryRequest
  , queryRequestFor
  , executeStatementsRequestsFor
  , batchRequest
  , executeSqlRequest
  , rpcRequest
  , paramNameProblem
  , responseS
  , ResponseReader
  , startResponse
  , cancelResponse
  , responseReader
  , affectedRows
  , readStep
  , drainResponse
  , RowBatch
  , ResponseStep
  ) where

import Control.Exception
import Control.Applicative ((<|>))
import Control.Monad (void, when)
import qualified Data.ByteString as B
import Data.Int (Int32, Int64)
import Data.Bits ((.&.))
import Data.IORef
import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of (..), Stream, effect)
import qualified Streaming as Streaming
import Hmssql.Internal.Derived
import qualified Hmssql.Tds.Parser as P
import qualified Hmssql.Tds.Value as V
import qualified Streaming.Prelude as S

import Hmssql.Connection.Internal
import Hmssql.Decoding
import Hmssql.Encoding
import Hmssql.Errors
import Hmssql.Query.Internal
import Hmssql.Query.Lexer (lexPlaceholders)
import Hmssql.Query.Types
import Hmssql.SqlValue
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.PacketWriter (writeBuilder)
import Hmssql.Tds.Primitives (putDecimal, readDecimal, runPutSized)
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo

------------------------------------------------------------------------------
-- Building queries

-- | SQL text with its parameters.  The parameters are those of the
-- 'ToSqlRow' value: a tuple, a record with a derived instance, an
-- 'Data.Tuple.Only.Only' for a single parameter, a list of 'SqlParam', or
-- 'NamedParams'.  In the text, @\@p1@, @\@p2@, ... refer to the positional
-- parameters and @\@name@ to the named ones.
--
-- > mkQuery "UPDATE dbo.customer SET email = @p1 WHERE id = @p2" (email, customerId)
--
-- @\@pN@, in either case, is a placeholder wherever it appears outside a
-- string literal, a quoted identifier or a comment, even where the SQL
-- means something else by it.  So a variable of that name, as in
-- @DECLARE \@p1 int@, can't be used in a 'mkQuery' text; use another name.
-- A placeholder that refers to no parameter makes sending the query throw
-- 'Hmssql.Errors.EncodeError'.
--
-- A string literal (@OverloadedStrings@) is the same as
-- @'mkQuery' text ()@ for text without placeholders.
--
-- The text is lexed once per application of 'mkQuery' to it, not once per
-- set of parameter values.  With a literal, the lexing floats out to the
-- top level when 'mkQuery' is inlined, so the text is lexed once per
-- program run however many times the query is built with new parameters.
mkQuery :: ToSqlRow p => Text -> p -> Query
mkQuery text = \params -> paramsQuery frags (encodeParams rowEncoder params)
  where
    frags = lexPlaceholders text
{-# INLINE mkQuery #-}

-- The query of 'mkQuery''s lexed text and parameters, out of line: inlined, each
-- application of 'mkQuery' had its own loop making the 'QueryParam's.  A function
-- applying 'mkQuery' to a literal and one to four parameters was 356 to 460 bytes of
-- object code, and is 288 to 414, of which about 260 are the literal and its lexing.
paramsQuery :: [Fragment] -> [(Text, TdsContext -> Either String EncodedParam)] -> Query
paramsQuery frags params = piece frags [QueryParam name enc | (name, enc) <- params]
{-# OPAQUE paramsQuery #-}

-- | Text spliced into the query as it is, with no parameters; a string
-- literal gives the same.  Nothing in it is parsed, so a @\@p1@ in it is
-- left to the server.  For text that comes from data, use 'param',
-- 'namedParam' or 'escapeIdentifier' instead.
rawSql :: Text -> Query
rawSql t = piece [Static t | not (T.null t)] []

-- | A positional parameter: a placeholder in the text, and the value sent
-- with the query.
--
-- > "WHERE id = " <> param (42 :: Int)
param :: ToSqlField a => a -> Query
param a = piece [Placeholder 1] [QueryParam "" (\ctx -> encodeParam fieldEncoder ctx a)]

-- | A named parameter: @\@name@ in the text, and the value sent with the
-- query.  The leading @\@@ is optional.  The name must be a T-SQL variable
-- name (see 'paramNameProblem'), and not of the form @\@pN@, which is
-- reserved for the positional parameters.  A query that uses one name for
-- two parameters can't be sent, and throws 'Hmssql.Errors.EncodeError'.
--
-- > "OFFSET " <> namedParam "skip" (100 :: Int) <> " ROWS"
namedParam :: ToSqlField a => Text -> a -> Query
namedParam name a = piece [Static name'] [QueryParam name' (\ctx -> encodeParam fieldEncoder ctx a)]
  where
    name' = if "@" `T.isPrefixOf` name then name else "@" <> name

-- | An identifier (a table or column name from data, say) quoted with
-- brackets: @[name]@, with @]@ doubled.
--
-- > "SELECT " <> escapeIdentifier col <> " FROM " <> escapeIdentifier table
escapeIdentifier :: Text -> Query
escapeIdentifier name = rawSql ("[" <> T.replace "]" "]]" name <> "]")

------------------------------------------------------------------------------
-- Requests

-- | A SQL batch: the text as it is, no parameters.
batchRequest :: Text -> Request
batchRequest sql = Request PTSqlBatch (\ctx writer -> do
  mapM_ (throwIO . EncodeError) (sqlBatchProblem ctx sql)
  writeBuilder writer (sqlBatchBuilder ctx sql)) (Just sql)

-- | @sp_executesql \@stmt, \@params, \@p1, \@p2, ...@
--
-- Parameters with an empty name are called @\@pN@ after their 1-based position
-- in the list.  The names are spliced into the @\@params@ declaration as
-- given, so check them with 'paramNameProblem' first (the query functions
-- do).  With no parameters, @\@params@ is left out.
executeSqlRequest :: Text -> [(Text, EncodedParam)] -> IO Request
executeSqlRequest sql params = checkedRpcRequest sql [executeSqlRpc sql (resolveParamNames params)]

executeSqlRequestWith :: Text -> [(Text, EncodedParam)] -> IO Request
executeSqlRequestWith sql named = do
  body <- newRpcWriter [executeSqlRpc sql named]
  pure (Request PTRpc body (Just sql))

resolveParamNames :: [(Text, EncodedParam)] -> [(Text, EncodedParam)]
resolveParamNames params =
  [ (if T.null name then placeholderText i else name, p)
  | (i, (name, p)) <- zip [1 :: Int ..] params
  ]

-- | An RPC call of the named procedure with these parameters, as
-- 'callProcedure' sends it. Invalid parameters throw EncodeError before
-- the request is constructed.
rpcRequest :: Text -> [RpcParam] -> IO Request
rpcRequest procName params = checkedRpcRequest procName [RpcRequest (RpcProcName procName) 0 params]

checkedRpcRequest :: Text -> [RpcRequest] -> IO Request
checkedRpcRequest label requests = do
  mapM_ (mapM_ (throwIO . EncodeError) . rpcRequestProblem) requests
  body <- newRpcWriter requests
  pure (Request PTRpc body (Just label))

-- | The request a query is sent as: a SQL batch when it has no parameters,
-- otherwise @sp_executesql@ with the parameters encoded for the connection.
-- Throws 'EncodeError' for a value that can't be encoded, a placeholder
-- with no parameter ('Hmssql.Query.Types.queryProblem'), a name that
-- isn't a T-SQL variable name ('paramNameProblem') or is of the reserved
-- form @\@pN@, or a name used twice (SQL Server identifiers are
-- case-insensitive, so @\@a@ and @\@A@ are one name).  Nothing is sent.
queryRequest :: Connection -> Query -> IO Request
queryRequest conn q = do
  ctx <- connectionContext conn
  queryRequestFor ctx q

-- | 'queryRequest' for a connection with this context, without the
-- connection.  It throws 'EncodeError' as 'queryRequest' does.  A request with
-- a lazy or streamed parameter can be sent only once.
queryRequestFor :: TdsContext -> Query -> IO Request
-- Each parameter is checked here, as it is encoded ('rpcParamProblem'), so
-- the request is written without checking again.  The positional names
-- (@\@p1@, @\@p2@, ...) need no name checks: they are valid, and distinct
-- from each other and from every name 'reservedNameProblem' lets through.
queryRequestFor ctx q = do
  (sql, named) <- either (throwIO . EncodeError) pure (encodeQuery ctx q)
  case named of
    [] -> pure (batchRequest sql)
    _ -> executeSqlRequestWith sql named

------------------------------------------------------------------------------
-- Responses

-- | Send a request and start reading its response.
startResponse :: Connection -> Request -> IO ResponseReader
startResponse conn Request{..} = do
  ar <- startRequestFor conn requestStatement requestPacketType requestBody
  responseReader conn ar requestStatement

-- | 'startResponse', for an action that reads the response to its end: if
-- it throws instead, the response is canceled ('readingToEnd') rather
-- than left open.
withResponse :: Connection -> Request -> (ResponseReader -> IO a) -> IO a
withResponse conn req act = mask $ \restore -> do
  -- Masked from the send to the handler's installation, so that an
  -- interruption can't come between them and leave the response open.
  resp <- startResponse conn req
  readingToEnd conn (respActive resp) (restore (act resp))

-- | Cancel one response: if it hasn't been read to its end, the
-- statement is canceled on the server and the rest of the response
-- discarded, as 'Hmssql.Connection.cancelActiveStatement' does for every
-- response of the connection.  It returns once the response is over on
-- the server, so the statement's locks are released by then (a round
-- trip, unless the response had fully arrived).  Nothing happens if the
-- response was already read to its end or canceled, or the connection is
-- closed or broken.  Reading on from the reader, or from a stream of it,
-- throws 'ResultAbandoned'.
cancelResponse :: ResponseReader -> IO ()
cancelResponse ResponseReader{..} = do
  cancelActiveResponse respConn respActive
  writeIORef respEnded True

-- | The cursor of a response started another way
-- ('Hmssql.Connection.Internal.startStreamingRequest'), with the
-- statement's text for its error messages.
responseReader :: Connection -> ActiveResponse -> Maybe Text -> IO ResponseReader
responseReader conn ar stmt =
  ResponseReader conn ar <$> newIORef Nothing <*> newIORef Nothing <*> newIORef Nothing <*> pure stmt <*> newIORef False <*> pure Nothing

-- | Send a request and stream the response tokens, a low-level view of a
-- response: every row as a 'TRow' (see "Hmssql.Tds.Value"), and the other
-- tokens, in order.  ERROR tokens are withheld and rethrown as
-- 'SqlServerError' once the response is complete, so the connection is
-- never left mid-message.  A DONE (DONE, DONEPROC or DONEINPROC) flagged
-- DONE_ERROR or DONE_SRVERROR in a response with no ERROR token is thrown
-- as 'SevereError' at the end, likewise: the server failed the request
-- without a message (as when the session was killed).
responseS :: Connection -> Request -> IO (Stream (Of Token) IO ())
responseS conn req = go <$> startResponse conn req
  where
    go resp = effect $ readStep resp wholeRows >>= \case
      StepEnd -> pure (pure ())
      StepToken tok -> pure (S.yield tok >> go resp)
      StepRows (RowBatch rows _) -> pure (yieldRows resp (map TRow rows) (go resp))

-- | 'streamFirstResultSet' of a request of its own.
firstResultSetS :: RowCompiler r -> Connection -> Request -> IO (Stream (Of r) IO ())
firstResultSetS compile conn req = do
  resp <- startResponse conn req
  pure (streamFirstResultSet compile resp (drainResponse resp))

-- | Sum of the row counts reported by DONE tokens, reading the response
-- to its end.
affectedRows :: ResponseReader -> IO Int64
affectedRows resp = go 0
  where
    go !acc = readStep resp ignoreRows >>= \case
      StepEnd -> pure acc
      StepToken tok -> go (acc + countOf tok)
      StepRows _ -> go acc
    countOf = \case
      TDone d -> fromDone d
      TDoneProc d -> fromDone d
      TDoneInProc d -> fromDone d
      _ -> 0
    fromDone d = if doneHasCount d then fromIntegral (doneRowCount d) else 0

------------------------------------------------------------------------------
-- Statements

-- | Run a statement, or a batch of them, and return the number of rows
-- affected, which is the sum of the counts the server reports.  Any
-- result sets are read and discarded.
execute :: Connection -> Query -> IO Int64
execute conn q = withConnectionLock conn $ queryRequest conn q >>= \req -> withResponse conn req affectedRows

-- | Run a statement as 'execute' does, and discard the row count.  The
-- whole response is still read, and a server error is still thrown.
execute_ :: Connection -> Query -> IO ()
execute_ conn q = void (execute conn q)
-- This and the other functions that only adapt another's result are out of line,
-- so that a use is a call rather than a call and its continuation (about 60 bytes
-- of object code each).
{-# NOINLINE execute_ #-}

------------------------------------------------------------------------------
-- Several statements in one request

-- | Run several statements in one request, which is one round trip, and
-- return the number of rows each affected, in order, as 'execute' would
-- return it.  Each statement is sent as its own @sp_executesql@ call, all
-- in one RPC message.  That includes a statement with no parameters, so a
-- @SET@ option it sets or a @#temp@ table it creates lasts only until it
-- returns; send such statements with 'execute'.  For many rows of one
-- statement, 'executeMany' is the same with the text read once.  To know
-- which statements failed, use 'executeStatementsOutcomes'.
--
-- The server runs the statements in order.  If some fail, the whole
-- response is still read, and then 'SqlServerError' is thrown for the
-- first that failed.  __Statements after a failed one may have run__: an
-- error that only ends its statement (a constraint violation, say) lets
-- the server go on; one that aborts the batch (@THROW@, a conversion
-- error, a deadlock, any error under @SET XACT_ABORT ON@) ends the
-- request there.  For all-or-nothing, run it inside
-- 'Hmssql.Transaction.withTransaction'.
--
-- A statement that can't be sent (see 'queryRequest') throws
-- 'EncodeError' naming its position, before its message is sent.  A long
-- list goes out in messages of about 1 MiB, each read before the next is
-- sent, so memory stays bounded; the split changes nothing else.
-- Interrupted, it cancels the running statement; the statements before
-- it have run.  An empty list returns @[]@ without a round trip.
executeStatements :: Connection -> [Query] -> IO [Int64]
executeStatements conn qs = runStatements queryStatement () conn qs >>= countsOf

-- | The counts, or the first failure thrown.
countsOf :: Statements -> IO [Int64]
countsOf (Statements outcomes failure) = case failure of
  Just (sql, err) -> throwIO (SqlServerError err (Just sql))
  Nothing -> traverse counted outcomes
  where
    counted = \case
      StatementDone n -> pure n
      -- Only after an error, or 'runStatements' throws.
      _ -> throwIO $ ProtocolError "executeStatements: a statement didn't run, but no error was reported"

-- | Run one statement text once for each row of parameters, all in one
-- request, and return the number of rows each affected, in order.  The
-- text refers to a row's parameters as a 'mkQuery' text does, with
-- @\@p1@, @\@p2@, ..., and a row is any 'ToSqlRow' value.
--
-- > executeMany conn "INSERT INTO item (id, name) VALUES (@p1, @p2)" [(1 :: Int, "one" :: Text), (2, "two")]
--
-- Each row is its own @sp_executesql@ call, with the text and the
-- parameter declaration shared (read and encoded once, not per row), so
-- the server compiles the statement once and reuses the plan.  It is
-- @'executeStatements' conn (map ('mkQuery' sql) rows)@ with that
-- sharing, and everything 'executeStatements' says about round trips,
-- errors, transactions and interruption applies: statements after a
-- failed row may have run, so use 'Hmssql.Transaction.withTransaction'
-- for all or nothing, or 'executeManyOutcomes' to see which rows failed.
-- For a large load into one table, 'Hmssql.BulkCopy.bulkInsert' is
-- faster.
executeMany :: ToSqlRow p => Connection -> Text -> [p] -> IO [Int64]
executeMany conn sql rows = runStatements (rowStatement frags text stmt) Nothing conn rows >>= countsOf
  where
    frags = lexPlaceholders sql
    text = renderFragments frags
    stmt = textParam text
-- Out of line, with 'executeManyOutcomes', so that a use is a call.  A row's
-- encoder is then an unknown call once per row, beside encoding the row's RPC.
{-# NOINLINE executeMany #-}

-- | 'executeStatements', returning what happened to each statement instead of
-- throwing the first failure: the statements' outcomes, one for each, in
-- order.  A failed statement's error is its 'StatementFailed'; the
-- statements after one that aborted the batch are 'StatementNotRun'.
-- Nothing else changes: an 'EncodeError', a 'SevereError', an
-- interruption and a connection that fails are thrown as by
-- 'executeStatements', and so is an error that closes the connection (severity
-- 20 or more), as 'SqlServerError'.
executeStatementsOutcomes :: Connection -> [Query] -> IO [StatementOutcome]
executeStatementsOutcomes conn qs = outcomesOf <$> runStatements queryStatement () conn qs

-- | 'executeMany' with each row's outcome, as 'executeStatementsOutcomes': the
-- way to tell which rows failed.
--
-- > outcomes <- executeManyOutcomes conn "INSERT INTO item (id, name) VALUES (@p1, @p2)" rows
-- > let failed = [(row, msgText err) | (row, StatementFailed err) <- zip rows outcomes]
executeManyOutcomes :: ToSqlRow p => Connection -> Text -> [p] -> IO [StatementOutcome]
executeManyOutcomes conn sql rows = outcomesOf <$> runStatements (rowStatement frags text stmt) Nothing conn rows
  where
    frags = lexPlaceholders sql
    text = renderFragments frags
    stmt = textParam text
{-# NOINLINE executeManyOutcomes #-}

outcomesOf :: Statements -> [StatementOutcome]
outcomesOf (Statements outcomes _) = outcomes

-- | What happened to one statement of 'executeStatementsOutcomes' or
-- 'executeManyOutcomes'.
data StatementOutcome
  = StatementDone !Int64
    -- ^ It ran, and affected this many rows (what 'execute' would return).
  | StatementFailed !ServerMessage
    -- ^ It failed with this error (the first, if it reported several).
  | StatementNotRun
    -- ^ The request ended before it ran: a statement before it aborted
    -- the batch (with @THROW@, a conversion error, a deadlock, or any
    -- error under @XACT_ABORT@).

instance Show StatementOutcome where
  showsPrec p = \case
    StatementDone a -> showCon1 p "StatementDone"# a
    StatementFailed a -> showCon1 p "StatementFailed"# a
    StatementNotRun -> showString "StatementNotRun"
  {-# OPAQUE showsPrec #-}

instance Eq StatementOutcome where
  x == y = case (x, y) of
    (StatementDone a, StatementDone a') -> a == a'
    (StatementFailed a, StatementFailed a') -> eq a a'
    (StatementNotRun, StatementNotRun) -> True
    _ -> False
  {-# OPAQUE (==) #-}

-- | The outcome of each statement, in order, and the first failure with
-- its statement's text.
data Statements = Statements [StatementOutcome] !(Maybe (Text, ServerMessage))

-- | A row of parameters for one statement text: the lexed text, rendered,
-- and its @\@stmt@ parameter are shared by every row, and the
-- @\@params@ declaration by a row whose parameters' names and types are
-- those of the row before (the state).
rowStatement :: ToSqlRow p => [Fragment] -> Text -> RpcParam -> StatementEncoder (Maybe ([(Text, TypeInfo)], RpcParam)) p
rowStatement frags sql stmt ctx prev row = do
  let params = [QueryParam name enc | (name, enc) <- encodeParams rowEncoder row]
  mapM_ Left (fragmentsProblem (length [() | QueryParam name _ <- params, T.null name]) frags)
  named <- encodeQueryParams ctx params
  case named of
    [] -> pure (sql, RpcRequest procSpExecuteSql 0 [stmt], prev)
    _ -> do
      let key = [(name, ti) | (name, (ti, _)) <- named]
          !decl = case prev of
            Just (key', d) | key' == key -> d
            _ -> declarationParam named
      -- Force only the reusable shape. A lazy projection of named would
      -- otherwise keep every value alive while the following request sends.
      let forceKey = foldr (\(name, ti) rest -> name `seq` ti `seq` rest) () key
      forceKey `seq` pure (sql, RpcRequest procSpExecuteSql 0 (stmt : decl : valueParams named), Just (key, decl))

-- | The statements, sent in messages of about 'statementMessageBytes'
-- each, one message's response read before the next is sent.  A message
-- whose response ended before all its statements ran is the last: the
-- rest haven't run.
runStatements :: StatementEncoder s a -> s -> Connection -> [a] -> IO Statements
runStatements encode s0 conn items0 = withConnectionLock conn $ go 0 s0 items0 [] Nothing
  where
    go !i s items acc failure = case items of
      [] -> pure (Statements (concat (reverse acc)) failure)
      _ -> do
        ctx <- connectionContext conn
        (stmts, n, rest, s') <- either (throwIO . EncodeError) pure (takeStatements encode ctx s i items)
        (outs, failure', complete) <- runMessage conn stmts n
        let failure'' = failure <|> failure'
        if complete
          then go (i + n) s' rest (outs : acc) failure''
          else pure (Statements (concat (reverse (map (const StatementNotRun) rest : outs : acc))) failure'')

-- | The messages 'executeStatements' sends for these statements, for a
-- connection with this context (as 'queryRequestFor' for one query): each
-- statement an @sp_executesql@ RPC, in messages of about 1 MiB; or why a
-- statement can't be sent.
executeStatementsRequestsFor :: TdsContext -> [Query] -> IO [Request]
executeStatementsRequestsFor ctx = go 0
  where
    go !i = \case
      [] -> pure []
      qs -> do
        (stmts, n, rest, ()) <- either (throwIO . EncodeError) pure (takeStatements queryStatement ctx () i qs)
        (:) <$> statementsRequest stmts <*> go (i + n) rest

-- | Send the statements (as many as the count) as one RPC message and read
-- the response: each statement's outcome, the first failure, and whether
-- every statement ran (the response didn't end early).
--
-- Each RPC's response ends with a DONEPROC (MS-TDS 2.2.4.3; a procedure a
-- statement calls reports DONEINPROC tokens, not a DONEPROC), so the
-- tokens up to the first DONEPROC are the first statement's, and so on;
-- a statement's count is the sum of the counts of its DONE tokens, as in
-- 'affectedRows'.  A response with fewer DONEPROCs than statements was
-- ended by an error that aborted the batch.  As in 'readStep', a DONE
-- flagged as failed in a response with no ERROR token is thrown as
-- 'SevereError', and a response cut off by the server closing the
-- connection after an error throws that error.
runMessage :: Connection -> [(Text, RpcRequest)] -> Int -> IO ([StatementOutcome], Maybe (Text, ServerMessage), Bool)
runMessage conn stmts n = do
  texts <- mapM (evaluate . fst) stmts
  Request{..} <- statementsRequest stmts
  mask $ \restore -> do
    ar <- startRequestFor conn requestStatement requestPacketType requestBody
    readingToEnd conn ar $ restore (runMessageResponse conn ar texts n)

-- | Read the response of a message of statements ('runMessage').
runMessageResponse :: Connection -> ActiveResponse -> [Text] -> Int -> IO ([StatementOutcome], Maybe (Text, ServerMessage), Bool)
runMessageResponse conn ar texts n = do
  let go st = do
        step <- nextStep conn ar ignoreRows `catch` \(e :: SomeException) -> case fromException e of
          Just (err :: SqlServerError) -> throwIO err { sqlErrorStatement = listToMaybe (runPending st) }
          Nothing -> case (fromException e, runFailure st <|> failedHere st) of
            (Just (ConnectionClosedBy reason), Just (sql, msg)) | not (byClient reason) -> throwIO (SqlServerError msg (Just sql))
            _ -> throwIO e
        case step of
          StepRows _ -> go st
          StepToken tok -> go (onToken st tok)
          StepEnd -> do
            let RunState{..} = st
            -- An error with no DONEPROC after it belongs to the statement
            -- that was running.
                (k', outs') = case runErr of
                  Just msg | runEnded < n -> (runEnded + 1, StatementFailed msg : runOuts)
                  _ -> (runEnded, runOuts)
                failure' = runFailure <|> failedHere st
            case (failure', runFailedDone) of
              (Nothing, Just (d, sql)) -> throwSevere conn d sql
              _ -> pure (reverse outs' ++ replicate (n - k') StatementNotRun, failure', runEnded >= n)
  go (RunState 0 0 Nothing Nothing Nothing [] texts)
  where
    byClient = \case
      ClosedByClient -> True
      _ -> False
    countOf d = if doneHasCount d then fromIntegral (doneRowCount d) else 0
    failedHere RunState{..} = (,) <$> listToMaybe runPending <*> runErr
    onToken st@RunState{..} = \case
      TError msg -> st { runErr = runErr <|> Just msg }
      TDoneProc d ->
        let !count' = runCount + countOf d
            out = maybe (StatementDone count') StatementFailed runErr
         in RunState
              { runEnded = runEnded + 1
              , runCount = 0
              , runErr = Nothing
              , runFailure = runFailure <|> failedHere st
              , runFailedDone = done d
              , runOuts = out : runOuts
              , runPending = drop 1 runPending
              }
      TDone d -> st { runCount = runCount + countOf d, runFailedDone = done d }
      TDoneInProc d -> st { runCount = runCount + countOf d, runFailedDone = done d }
      _ -> st
      where
        done d = runFailedDone <|> (if doneError d || doneServerError d then Just (d, listToMaybe runPending) else Nothing)

-- | Where 'runMessage' is in the response: how many statements have ended
-- (their DONEPROC has arrived), with these outcomes (newest first); the
-- texts of the rest, the running one first; the running one's count and
-- error so far; the first failure, and the first DONE flagged as failed.
data RunState = RunState
  { runEnded :: !Int
  , runCount :: !Int64
  , runErr :: !(Maybe ServerMessage)
  , runFailure :: !(Maybe (Text, ServerMessage))
  , runFailedDone :: !(Maybe (Done, Maybe Text))
  , runOuts :: [StatementOutcome]
  , runPending :: [Text]
  }

-- | 'queryS' with a 'RowDecoderMonadic' instead of a 'RowDecoder': the decoder
-- runs per row, so it can look at the columns ('remainingColumns') and
-- decode a shape only known at runtime.
querySMWith :: RowDecoderMonadic r -> Connection -> Query -> IO (Stream (Of r) IO ())
querySMWith dec conn q = queryRequest conn q >>= firstResultSetS (compilerForM dec) conn

-- | 'queryS' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance.
querySWith :: RowDecoder r -> Connection -> Query -> IO (Stream (Of r) IO ())
querySWith dec conn q = queryRequest conn q >>= firstResultSetS (compilerFor dec) conn

-- | The rows of the first result set as a 'Stream', read from the socket
-- as they are consumed, so memory doesn't grow with the result.
-- "Hmssql.Query#g:streaming" shows how to consume one.
--
-- Read the stream to its end before making another request on the
-- connection.  The next request cancels the statement and discards what
-- was left, and the old stream then throws 'ResultAbandoned'.  So does a
-- stream whose read was interrupted, by 'System.Timeout.timeout' say,
-- which cancels the statement at once, and a stream run a second time
-- after it was drained.
--
-- A stream not read to its end leaves its statement running on the
-- server, holding its locks, until the next request,
-- 'Hmssql.Connection.cancelActiveStatement' or
-- 'Hmssql.Connection.release' cancels it.  On a MARS connection
-- ('Hmssql.Connection.connectMars') other requests leave the stream open
-- instead, so it stays open until it is read to its end, canceled with
-- 'Hmssql.Connection.cancelActiveStatement', or the connection is
-- released.  'withQueryS' is the form that can't leak a stream.
--
-- Canceling a statement that is still running inside a transaction under
-- @SET XACT_ABORT ON@ rolls the transaction back
-- ('Hmssql.Transaction.TransactionEndedEarly').  Where the transaction
-- must survive, read the stream to its end.
queryS :: FromSqlRow r => Connection -> Query -> IO (Stream (Of r) IO ())
queryS = querySWith rowDecoder

-- | 'queryS' in a scope.  The action gets the stream, and when the action
-- ends, a stream not read to its end is canceled ('cancelResponse').
-- When the action returns, or throws an exception of its own,
-- 'withQueryS' returns once the statement is over on the server and its
-- locks are released.  On a MARS connection
-- ('Hmssql.Connection.connectMars') this is the way to read a stream
-- beside other requests.  Without MARS it works too, under the rule of
-- 'queryS': a request the action makes abandons the stream.
--
-- > withQueryS conn "SELECT id FROM dbo.parent" $ \parents ->
-- >   S.mapM_ (\(Only pid) -> query conn ("SELECT ... WHERE parent_id = " <> param (pid :: Int))) parents
--
-- An interruption ('System.Timeout.timeout', 'Control.Concurrent.killThread')
-- doesn't wait.  The statement is canceled at once, and the connection's
-- next request reads the rest of the response first; a transaction
-- function, 'Hmssql.Connection.release' and
-- 'Hmssql.Connection.cancelActiveStatement' do the same.  Until then the
-- statement's locks may still be held, and
-- 'Hmssql.Connection.cancelActiveStatement' waits for them to go.  The
-- stream must not be used after the action.
withQueryS :: FromSqlRow r => Connection -> Query -> (Stream (Of r) IO () -> IO a) -> IO a
withQueryS = withQuerySWith rowDecoder

-- | 'withQueryS' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance.
withQuerySWith :: RowDecoder r -> Connection -> Query -> (Stream (Of r) IO () -> IO a) -> IO a
withQuerySWith dec = withFirstResultSetS (compilerFor dec)

-- | 'withQueryS' with a 'RowDecoderMonadic' instead of a 'RowDecoder', as
-- 'querySMWith'.
withQuerySMWith :: RowDecoderMonadic r -> Connection -> Query -> (Stream (Of r) IO () -> IO a) -> IO a
withQuerySMWith dec = withFirstResultSetS (compilerForM dec)

-- | As 'withResponse': the body runs under 'readingToEnd', so an
-- asynchronous exception out of it cancels the statement at once and
-- leaves the drain to the next operation, and a synchronous one cancels
-- and drains before it propagates.  A body that returns cancels and
-- drains too ('cancelResponse'), under the mask like the release of 'bracket':
-- interruptible only in the drain's reads, which then break the
-- connection.
withFirstResultSetS :: RowCompiler r -> Connection -> Query -> (Stream (Of r) IO () -> IO a) -> IO a
withFirstResultSetS compile conn q act = do
  req <- queryRequest conn q
  mask $ \restore -> do
    resp <- startResponse conn req
    r <- readingToEnd conn (respActive resp) (restore (act (streamFirstResultSet compile resp (drainResponse resp))))
    cancelResponse resp
    pure r

-- | One column's value in a row being read, followed by @r@, the rest of the
-- row.  'skipCell', 'cellText' and 'cellDecoded' are the usual ways to read one.
data Cell r = Cell
  { cellColumn :: !ColumnInfo
  , cellContext :: !TdsContext
    -- ^ The connection's context, as a field decoder takes it.
  , cellAllocAhead :: !Int
    -- ^ The connection's 'Hmssql.Connection.connectValueAllocAhead'.
  , cellValue :: !(CellValue r)
  } deriving stock (Functor)

-- | A cell's value and what follows it.  A NULL gives the rest of the row at once.
-- A non-NULL value has its total length, if known, and its bytes, and gives the
-- rest of the row when they end, so a row's cells can only be read in order.
data CellValue r
  = CellNull r
  | CellBytes !(Maybe Int64) (Stream (Of B.ByteString) IO r)
  deriving stock (Functor)

-- | One row's cells, in column order.  Its result is the stream of the rows after it.
type RowCells = Stream Cell IO

-- | The columns of the first result set, and its rows as nested streams: rows of
-- cells, and cells of bytes.  A value is read as it arrives, so a large one
-- needn't be in memory.  For ordinary rows, 'queryS' is faster.
--
-- The rules of 'queryS' apply: a new request abandons the stream on a plain
-- connection, and on MARS it doesn't.  Reading any part of the stream a second
-- time, or using it after its scope ends, throws 'ResultAbandoned'.
queryCells :: Connection -> Query -> IO ([ColumnInfo], Stream RowCells IO ())
queryCells conn q = withConnectionLock conn $ do
  req <- queryRequest conn q
  resp <- startResponse conn req
  readingToEnd conn (respActive resp) (cellsOfResponse resp)

-- | 'queryCells' in a scope: when the action ends, a stream not read to its end is
-- canceled, with the same interruption rules as 'withQueryS'.
withQueryCells :: Connection -> Query -> ([ColumnInfo] -> Stream RowCells IO () -> IO a) -> IO a
withQueryCells conn q use = do
  req <- queryRequest conn q
  mask $ \restore -> do
    resp <- startResponse conn req
    r <- readingToEnd conn (respActive resp) $ restore $ do
      (cols, rows) <- cellsOfResponse resp
      use cols rows
    cancelResponse resp
    pure r

-- Build nested continuations over one response. The generation counter
-- rejects replayed pulls. Each pull's second argument describes how to drain
-- the remaining row if the caller abandons the continuation it receives.
--
-- Each pull takes the lock and catch frames, about 400 bytes, which is why this
-- costs several times a typed 'queryS' on small rows, and why it isn't the
-- interface for them.  It earns its place on large values, where a 256 MiB column
-- reads with nothing kept live.
cellsOfResponse :: ResponseReader -> IO ([ColumnInfo], Stream RowCells IO ())
cellsOfResponse resp = do
  let findColumns = readStep resp ignoreRows >>= \case
        StepToken (TColMetaData cols) -> pure (Just cols)
        StepEnd -> pure Nothing
        _ -> findColumns
  found <- findColumns
  case found of
    Nothing -> pure ([], pure ())
    Just cols -> do
      context <- connectionContext (respConn resp)
      generation <- newIORef (0 :: Int)
      let conn = respConn resp
          ar = respActive resp
          claim expected action = withConnectionLock conn $ mask $ \restore -> do
            checkCurrent conn ar
            current <- readIORef generation
            when (current /= expected) (throwIO ResultAbandoned)
            writeIORef generation (current + 1)
            readingToEnd conn ar (restore action)
          pull parser after = readPiece conn ar parser after
          info = compileResultSet cols
          skipColumns bitmap = V.skipCells bitmap . map snd
          columns = zip cols (rsCells info)
          remaining bitmap rest = if null rest then Nothing else Just (skipColumns bitmap rest)
          rowStart = do
            token <- P.peekToken
            case token of
              Just 0xD1 -> Just <$> V.rowBitmap (rsColumnCount info)
              Just 0xD2 -> Just <$> V.rowBitmap (rsColumnCount info)
              _ -> pure Nothing
          rows g = effect $ claim g $ do
            bitmap <- pull rowStart (\b -> b >>= \bits -> remaining bits columns)
            case bitmap of
              Just bits -> pure (Streaming.wrap (cells (g + 1) bits columns))
              Nothing -> readStep resp ignoreRows >>= \case
                StepEnd -> pure (pure ())
                StepToken tok | endsResultSet tok -> drainResponse resp >> pure (pure ())
                _ -> pure (rows (g + 1))
          cells g _ [] = pure (rows g)
          cells g bitmap ((col, (i, shape)) : later) = effect $ claim g $ do
            cell <- pull (V.cellAt bitmap i shape) $ \value -> case value of
              V.NullCell -> remaining bitmap later
              _ -> Just (V.skipValue value >> skipColumns bitmap later)
            let value = case cell of
                  V.NullCell -> CellNull (cells (g + 1) bitmap later)
                  _ -> CellBytes (V.cellLength cell) (chunks (g + 1) bitmap later (V.valueStream cell))
            pure (Streaming.wrap (Cell col context (connValueAllocAhead conn) value))
          chunks g bitmap later source = effect $ claim g $ do
            step <- pull (Streaming.inspect source) $ \case
              Left () -> remaining bitmap later
              Right (_ :> next) -> Just (S.effects next >> skipColumns bitmap later)
            pure $ case step of
              Left () -> pure (cells (g + 1) bitmap later)
              Right (bytes :> next) -> S.yield (B.copy bytes) >> chunks (g + 1) bitmap later next
      pure (cols, rows 0)

-- | Discard a cell's value and get the rest of the row.
skipCell :: Cell r -> IO r
skipCell Cell{cellValue} = case cellValue of
  CellNull rest -> pure rest
  CellBytes _ bytes -> S.effects bytes

-- | A character or XML cell's value as 'Text' chunks, read as it arrives, returning
-- the rest of the row.  A NULL gives no chunks.  A column whose encoding can't be
-- decoded throws 'DecodeError'.
cellText :: Cell r -> Stream (Of Text) IO r
cellText Cell{cellColumn = col, cellValue = value} = case value of
  CellNull rest -> pure rest
  CellBytes _ bytes -> case decodeColumnChunks (columnType col) of
    Left err -> effect (throwIO (DecodeError (Just (columnName col)) err))
    Right decode -> decode bytes

-- | Decode a cell with any field decoder, and get the rest of the row.  A failed
-- conversion is a 'Left' once the value has been read past, so the row can go on.
cellDecoded :: FieldDecoder a -> Cell r -> IO (Either DecodeError a, r)
cellDecoded decoder cell@Cell{cellColumn = col, cellContext, cellAllocAhead, cellValue = value} = case compileField decoder cellContext col of
  Left err -> (Left (DecodeError (Just (columnName col)) err),) <$> skipCell cell
  Right selected -> case selected of
    CellDecoder onNull _ owned -> whole onNull owned
    -- A value past the limit, or of a total not sent, goes to the fold.
    FoldingCell onNull _ owned fold -> case value of
      CellBytes total _ | maybe True (> fromIntegral streamWholeLimit) total -> streamed $ \case
        StreamedBytes _ chunks -> fold chunks
        StreamedWhole bytes -> pure (failed (owned (P.valueBytes bytes)))
        StreamedNull -> pure (failed onNull)
      _ -> whole onNull owned
    StreamingCell read -> streamed read
  where
    named = either (Left . DecodeError (Just (columnName col))) Right
    failed = either (Left . DecodeFailed . DecodeError (Just (columnName col))) Right
    whole onNull owned = case value of
      CellNull rest -> do
        let !result = named onNull
        pure (result, rest)
      CellBytes total source -> do
        -- The chunks are already free of PLP framing, so no parser is involved.
        bytes :> rest <- S.foldM (P.append cellAllocAhead)
          (pure (P.accumulator (fromIntegral <$> total))) P.finish source
        let !result = named (owned bytes)
        pure (result, rest)
    streamed read = case value of
      CellNull rest -> do
        (result, _) <- P.parseChunks (read StreamedNull) []
        (, rest) <$> conversion result
      CellBytes total source -> do
        -- A streaming decoder's stream returns (), so the rest of the row
        -- leaves through this reference.
        ending <- newIORef Nothing
        let chunks = Streaming.hoist P.effect source >>= \rest -> Streaming.effect $ do
              P.effect (writeIORef ending (Just rest))
              pure (pure ())
        (result, _) <- P.parseChunks (read (StreamedBytes total chunks)) []
        decoded <- conversion result
        readIORef ending >>= \case
          Just rest -> pure (decoded, rest)
          Nothing -> throwIO (ProtocolError "cell decoder did not finish its value")
    -- 'P.parseChunks' runs every consumer and discards nothing.
    conversion = \case
      Left (DecodeFailed err) -> pure (Left err)
      Left ReadDiscarded -> throwIO (ProtocolError "cell decoder discarded its value")
      Right a -> pure (Right a)

-- | 'query' with a 'RowDecoderMonadic' instead of a 'RowDecoder': the decoder
-- runs per row, so it can look at the columns ('remainingColumns') and
-- decode a shape only known at runtime.
queryMWith :: RowDecoderMonadic r -> Connection -> Query -> IO [r]
queryMWith dec conn q = collectFirstResultSet (compilerForM dec) conn q

-- | 'query' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance.
queryWith :: RowDecoder r -> Connection -> Query -> IO [r]
queryWith dec conn q = collectFirstResultSet (compilerFor dec) conn q

-- | The rows of the first result set, decoded into the row type by its
-- 'FromSqlRow' instance, with the column types checked before the first
-- row.  A query with no result set, such as an @UPDATE@, gives @[]@.  The
-- rest of the response is read to its end, so a later result set is
-- discarded, and an error from a later statement is still thrown.
query :: FromSqlRow r => Connection -> Query -> IO [r]
query = queryWith rowDecoder

collectFirstResultSet :: RowCompiler r -> Connection -> Query -> IO [r]
collectFirstResultSet compile conn q = withConnectionLock conn $
  queryRequest conn q >>= \req -> withResponse conn req (readFirstResultSet compile)

-- | Fold over the rows of the first result set as they arrive, without
-- building a list or a stream: the fastest way to count, sum or write
-- rows out.  The step runs with the connection lock held, in the middle
-- of reading the response, so it must not use the connection.  On a MARS
-- connection it may, because the request takes a session of its own.
-- An exception from the step cancels the response at once and
-- propagates.  If it is the step's own exception, the response is
-- drained before it propagates; if it is an interruption, the drain is
-- left to the next request.  After the fold, the rest of the response is
-- read to its end, as with 'query'.
queryFold :: FromSqlRow r => Connection -> Query -> a -> (a -> r -> IO a) -> IO a
queryFold = queryFoldWith rowDecoder

-- | 'queryFold' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance.
queryFoldWith :: RowDecoder r -> Connection -> Query -> a -> (a -> r -> IO a) -> IO a
queryFoldWith dec conn q z step = withConnectionLock conn $ do
  req <- queryRequest conn q
  withResponse conn req $ \resp -> foldFirstResultSet (compilerFor dec) resp z step

-- | 'query' for exactly one row.  It throws 'UnexpectedResult' if the
-- first result set has no rows or several.
query1 :: FromSqlRow r => Connection -> Query -> IO r
query1 = query1With rowDecoder

-- | 'query1' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance. Throws 'UnexpectedResult' unless the first
-- result set has exactly one row.
query1With :: RowDecoder r -> Connection -> Query -> IO r
query1With dec conn q = queryWith dec conn q >>= exactlyOne
{-# NOINLINE query1With #-}

-- | 'query' for at most one row.  It returns 'Nothing' if the first result
-- set has no rows, and throws 'UnexpectedResult' if it has several.
queryMay :: FromSqlRow r => Connection -> Query -> IO (Maybe r)
queryMay = queryMayWith rowDecoder

-- | 'queryMay' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance. Throws 'UnexpectedResult' if the first result
-- set has more than one row.
queryMayWith :: RowDecoder r -> Connection -> Query -> IO (Maybe r)
queryMayWith dec conn q = queryWith dec conn q >>= atMostOne
{-# NOINLINE queryMayWith #-}

------------------------------------------------------------------------------
-- Multiple result sets

-- | Every result set decoded with the given row decoder. Each set's
-- column count and types are checked before reading its rows, including
-- empty sets. Use 'queryResultSets' when the sets have different known shapes.
queryMultiWith :: RowDecoder r -> Connection -> Query -> IO [ResultSet r]
queryMultiWith dec conn q = withConnectionLock conn $ queryRequest conn q >>= collectResultSets (compilerFor dec) conn

-- | 'queryMulti' with a 'RowDecoderMonadic' instead of 'SqlRow': every result
-- set in the response, each decoded with the same decoder, which runs per
-- row and can look at the columns ('remainingColumns') to adapt to each
-- set.
queryMultiMWith :: RowDecoderMonadic r -> Connection -> Query -> IO [ResultSet r]
queryMultiMWith dec conn q = withConnectionLock conn $ queryRequest conn q >>= collectResultSets (compilerForM dec) conn

-- | Every result set in the response, in order, each row as a 'SqlRow'
-- ('sqlRowDecoderFor' the set's columns): for a batch or procedure whose
-- columns are only known at runtime.  For result sets of known types, use
-- 'queryResultSets'.
queryMulti :: Connection -> Query -> IO [ResultSet SqlRow]
queryMulti conn q = withConnectionLock conn $ queryRequest conn q >>= collectResultSets sqlRowCompiler conn

collectResultSets :: RowCompiler r -> Connection -> Request -> IO [ResultSet r]
collectResultSets compile conn req = withResponse conn req (readResultSets compile)

------------------------------------------------------------------------------
-- Typed multiple result sets

-- | 'resultSet' with the given row decoder instead of the row type's
-- 'FromSqlRow' instance.
resultSetWith :: RowDecoder r -> ResultSets [r]
resultSetWith dec = snd <$> nextResultSet (compilerFor dec)
{-# NOINLINE resultSetWith #-}

-- | The rows of the next result set, as 'query' would return them.  It
-- throws 'UnexpectedResult' if the response has no further result set.
resultSet :: FromSqlRow r => ResultSets [r]
resultSet = resultSetWith rowDecoder

-- | 'resultSet' with a 'RowDecoderMonadic', which runs per row and can look at
-- the columns ('remainingColumns'), and the result set's columns returned
-- with its rows.
resultSetMWith :: RowDecoderMonadic r -> ResultSets (ResultSet r)
resultSetMWith dec = uncurry ResultSet <$> nextResultSet (compilerForM dec)
{-# NOINLINE resultSetMWith #-}

-- | Read the next result set and discard its rows.  It throws
-- 'UnexpectedResult' if the response has no further result set.
skipResultSet :: ResultSets ()
skipResultSet = void (nextResultSet (\_ cols -> Right (skipRowDecoder cols)))

-- | Throws 'UnexpectedResult' if the response has no further result set.  On a
-- decode failure the rest of the response is drained before rethrowing.
nextResultSet :: RowCompiler r -> ResultSets ([ColumnInfo], [r])
nextResultSet compile = ResultSets $ \ctx resp -> do
  let skip = readStep resp ignoreRows >>= \case
        StepEnd -> throwIO $ UnexpectedResult "expected another result set"
        StepToken (TColMetaData cols) -> case compile ctx cols of
          Left err -> drainResponse resp >> throwIO err
          Right compiled -> newRowRead (connValueAllocAhead (respConn resp)) compiled >>= \decode -> collect cols decode []
        _ -> skip
      collect cols decode acc = readStep resp decode >>= \case
        StepEnd -> pure (cols, joinBatches acc)
        StepRows (RowBatch rows failed) -> case failed of
          Just err -> drainResponse resp >> throwIO err
          Nothing -> collect cols decode (rows : acc)
        -- A set followed directly by the next; leave its metadata for it.
        StepToken tok@(TColMetaData _) -> do
          writeIORef (respPushback resp) (Just tok)
          pure (cols, joinBatches acc)
        StepToken tok
          | endsResultSet tok -> pure (cols, joinBatches acc)
          | otherwise -> collect cols decode acc
  skip

-- | Run a batch that returns several result sets, and decode them one at
-- a time, each into its own row type.
--
-- > (parents, children) <- queryResultSets ((,) <$> resultSet <*> resultSet) conn
-- >   "SELECT id, name FROM dbo.parent; SELECT id, parent_id FROM dbo.child"
--
-- The whole response is read, so an error in a later statement still
-- throws 'SqlServerError', and result sets the 'ResultSets' didn't ask
-- for are discarded.
queryResultSets :: ResultSets a -> Connection -> Query -> IO a
queryResultSets sets conn q = withConnectionLock conn $ queryRequest conn q >>= runResultSetsOn sets conn

runResultSetsOn :: ResultSets a -> Connection -> Request -> IO a
runResultSetsOn sets conn req = withResponse conn req (readResultSetsWith sets)

------------------------------------------------------------------------------
-- Stored procedures

-- | A parameter of a 'callProcedure' call.  'inParam' and 'outParam' build
-- one from a 'ToSqlField' value; 'rawInParam' and 'rawOutParam' declare an
-- exact wire type. Encoding runs in 'callProcedure', with the connection's
-- context.
data ProcParam = ProcParam
  { procParamName :: !Text
    -- ^ With the leading @\@@, or empty for positional.  Sent as given (not
    -- spliced into SQL, and not checked by 'paramNameProblem'): the server
    -- matches it against the procedure's parameters, ignoring trailing
    -- spaces, and reports a name it can't match as a 'SqlServerError'.
  , procParamEncode :: TdsContext -> Either String EncodedParam
    -- ^ Encode with the connection's context: the declared wire type and
    -- value's bytes ('Nothing' for NULL), or why it cannot be encoded.
    -- 'callProcedure' throws 'EncodeError' before sending on a 'Left'.
  , procParamOutput :: !Bool
    -- ^ Whether the server returns the parameter's value after the call
    -- ('procOutputValues').
  }

-- | An input parameter, encoded with the connection's context when
-- 'callProcedure' runs. Encoding failures throw 'EncodeError' before
-- the procedure request is sent.
--
-- > inParam "@customer_id" (42 :: Int32)
inParam :: ToSqlField a => Text -> a -> ProcParam
inParam name a = ProcParam name (\ctx -> encodeParam fieldEncoder ctx a) False
-- 'inParam' and 'outParam' are OPAQUE: inlined, or split into a worker whose result
-- the caller boxed again, a call of 'callProcedure' with one of each was 861 bytes of
-- object code; called, with 'maybeEncoder' out of line too, it is 613.
{-# OPAQUE inParam #-}

-- | An input/output parameter; the value is its initial value (a NULL of
-- the right type, @Nothing :: Maybe Int32@, when it has none).  Its value
-- after the call is in 'procOutputValues', decoded with
-- 'decodeReturnValue'.
--
-- The server returns an output value converted to the type declared for the
-- parameter, which is derived from the initial value, so that type is widened
-- so the output isn't truncated:
--
-- * strings and binary (@char@, @varchar@, @nchar@, @nvarchar@, @binary@,
--   @varbinary@) are declared as @(max)@;
-- * @decimal@ and @numeric@ are declared with precision 38 and scale 10, or
--   the initial value's scale if that is larger (but less than 10 if the
--   initial value's integer digits need it).  So @0 :: Decimal@ and
--   @Nothing :: Maybe Decimal@ both declare @decimal(38,10)@; to get more
--   decimal places give the initial value a larger scale (e.g.
--   @'Data.Decimal.roundTo' 20 0@).
--
-- Other types are declared as their 'ToSqlField' instance sends them.  An
-- @xml@ output parameter needs an @xml@ initial value such as
-- @'SqlXml' \"\"@ (the server won't convert xml to the @nvarchar@ a 'Text'
-- initial value declares).  For full control of the declared type, use
-- 'rawOutParam', which widens nothing.
-- Encoding and widening run in 'callProcedure', with the connection's
-- context; failures throw 'EncodeError' before the procedure request is sent.
outParam :: ToSqlField a => Text -> a -> ProcParam
outParam name a = ProcParam name encode True
  where
    encode ctx = encodeParam fieldEncoder ctx a >>= widenOutputParam
{-# OPAQUE outParam #-}

-- | An input parameter with an exact wire type and encoded value, for a
-- type no 'ToSqlField' instance declares:
--
-- > rawInParam "@x" (TIDecimalN 20 4, decimalValue)
--
-- 'callProcedure' still validates the wire type and the value before
-- sending.
rawInParam :: Text -> (TypeInfo, RawBytes) -> ProcParam
rawInParam name (ti, value) = ProcParam name (const (Right (ti, ParamBytes value))) False

-- | 'rawInParam' as an input\/output parameter: the declared type is the
-- one given, with none of the widening of 'outParam', so the server converts
-- the output value to exactly it:
--
-- > rawOutParam "@x" (TIDecimalN 20 4, Nothing)   -- a NULL decimal(20,4)
rawOutParam :: Text -> (TypeInfo, RawBytes) -> ProcParam
rawOutParam name (ti, value) = ProcParam name (const (Right (ti, ParamBytes value))) True

-- | Checks the type first ('typeInfoProblem'), so that an invalid one (a
-- hand-built @decimal(40,0)@) is refused rather than widened into a valid
-- one.
widenOutputParam :: EncodedParam -> Either String EncodedParam
widenOutputParam (_, ParamLazy _) = Left "output parameters cannot stream"
widenOutputParam (_, ParamStream _) = Left "output parameters cannot stream"
widenOutputParam (ti, ParamBytes raw) = mapM_ Left (typeInfoProblem ti) >> case ti of
  TINVarChar _ c -> Right (TINVarChar maxLength c, v)
  TINChar _ c -> Right (TINVarChar maxLength c, v)
  TIBigVarChar _ c -> Right (TIBigVarChar maxLength c, v)
  TIBigChar _ c -> Right (TIBigVarChar maxLength c, v)
  TIBigVarBinary _ -> Right (TIBigVarBinary maxLength, v)
  TIBigBinary _ -> Right (TIBigVarBinary maxLength, v)
  TIDecimalN p s -> decimal TIDecimalN p s
  TINumericN p s -> decimal TINumericN p s
  _ -> Right (ti, v)
  where
    v = ParamBytes raw
    decimal mk p s = do
      let intDigits = fromIntegral p - fromIntegral s :: Int
          s' = max s (fromIntegral (max 0 (min 10 (38 - intDigits))))
      v' <- case raw of
        Nothing -> Right Nothing
        Just bs -> case readDecimal p s bs of
          Left err -> Left ("invalid decimal parameter value: " ++ err)
          Right d -> Right (Just (runPutSized 17 (putDecimal 38 s' d)))
      Right (mk 38 s', ParamBytes v')

-- | What 'callProcedure' returns: the return status, the output
-- parameters' values and the result sets.
data ProcResult = ProcResult
  { procReturnStatus :: !(Maybe Int32)
    -- ^ The procedure's @RETURN@ status, if the server sent one (it doesn't
    -- for a scalar function).
  , procOutputValues :: ![ReturnValue]
    -- ^ One value per output parameter ('outParam', or 'procParamOutput'
    -- set), in the order those parameters appear in the list passed to
    -- 'callProcedure' -- not the order the server sends them in, which
    -- differs (SQL Server sends @(max)@-typed values, which includes every
    -- string or binary 'outParam', after the others).  So
    -- @zip outputParams (procOutputValues res)@ pairs each parameter with
    -- its value, whether the parameters are passed by name or by position,
    -- interleaved with input parameters, or in a different order than the
    -- procedure declares them.
    --
    -- When the called object is a scalar user-defined function, its return
    -- value comes first ('rvStatus' has bit @0x02@ set); functions have no
    -- output parameters, so it is the only value.
  , procResultSets :: ![ResultSet SqlRow]
    -- ^ Every result set the procedure produced, as 'queryMulti' returns
    -- them.
  }

instance Show ProcResult where
  showsPrec p (ProcResult a b c) = showRecord p "ProcResult"#
    [ "procReturnStatus"# := a, "procOutputValues"# := b, "procResultSets"# := c ]
  {-# OPAQUE showsPrec #-}

-- | Call a stored procedure (or scalar function, or system procedure such as
-- @sp_executesql@) by RPC, with the parameters in the given order.  See
-- 'ProcResult' for how output values are ordered.  Like the other query
-- functions, it throws 'SqlServerError' if the server reports an error, even
-- one the procedure continues past; output values are then not available.
-- Parameters are encoded with the connection's context and validated
-- before sending; an encoding failure throws 'EncodeError'.
--
-- > res <- callProcedure conn "dbo.place_order"
-- >   [ inParam "@customer_id" (42 :: Int32)
-- >   , outParam "@order_id" (Nothing :: Maybe Int32)
-- >   ]
-- > let [orderId] = procOutputValues res
-- > print (decodeReturnValue orderId :: Either DecodeError (Maybe Int32), procReturnStatus res)
--
-- A procedure with typed result sets and no output parameters can also be
-- run as @EXEC dbo.report \@p1@ through 'queryResultSets'.
callProcedure :: Connection -> Text -> [ProcParam] -> IO ProcResult
callProcedure conn procName params = withConnectionLock conn $ do
  ctx <- connectionContext conn
  rpcParams <- either (throwIO . EncodeError) pure (traverse (toRpc ctx) params)
  rpcRequest procName rpcParams >>= \req -> withResponse conn req (readProcResult conn)
  where
    toRpc ctx ProcParam{..} = do
      (ti, v) <- procParamEncode ctx
      pure (RpcParam procParamName (if procParamOutput then paramByRef else 0) ti v)

-- | Read a procedure call's response to its end ('callProcedure').
readProcResult :: Connection -> ResponseReader -> IO ProcResult
readProcResult conn resp = do
  ctx <- connectionContext conn
  -- Return tokens belong to the whole response; columns, the decoder and
  -- row batches belong only to the set being read. Completed sets, row batches
  -- and output tokens accumulate newest first.
  let beforeFirst !returns = readStep resp ignoreRows >>= \case
        StepEnd -> finish returns []
        StepToken (TColMetaData cols) -> startSet returns [] cols
        StepToken tok -> beforeFirst (onToken returns tok)
        StepRows _ -> beforeFirst returns
      startSet returns sets cols = do
        decode <- either (\e -> drainResponse resp >> throwIO e)
          (newRowRead (connValueAllocAhead (respConn resp))) (sqlRowCompiler ctx cols)
        inSet returns sets cols decode []
      inSet !returns sets cols decode batches = readStep resp decode >>= \case
        StepEnd -> finish returns (flush sets cols batches)
        StepToken (TColMetaData next) -> startSet returns (flush sets cols batches) next
        StepToken tok -> inSet (onToken returns tok) sets cols decode batches
        StepRows (RowBatch rows failed) -> case failed of
          Just err -> drainResponse resp >> throwIO err
          Nothing -> inSet returns sets cols decode (rows : batches)
      onToken returns@(status, outputs) = \case
        TReturnStatus value -> (Just value, outputs)
        TReturnValue value -> (status, value : outputs)
        _ -> returns
      flush sets cols batches = ResultSet cols (joinBatches batches) : sets
      finish (status, outputs) sets = pure (ProcResult status (callerOrder outputs) (reverse sets))
  beforeFirst (Nothing, [])
  where
    -- RETURNVALUE tokens carry the parameter's 0-based position in the RPC
    -- parameter list (MS-TDS 2.2.7.18 ParamOrdinal), which is the position in
    -- @params@; a function's return value (status fUDF, 0x02) has ordinal 0
    -- as well, and goes first. The name isn't usable for matching: it is
    -- empty for positional parameters. sortOn is stable, so restore arrival
    -- order before sorting the accumulated outputs.
    callerOrder = sortOn (\rv -> (rvStatus rv .&. 0x02 == 0, rvOrdinal rv)) . reverse

-- | Decode an output parameter's value ('procOutputValues') as a column
-- of its declared type would be decoded.
decodeReturnValue :: FromSqlField a => ReturnValue -> Either DecodeError a
decodeReturnValue ReturnValue{..} = do
  let col = ColumnInfo rvName rvType rvFlags rvUserType Nothing
  decode <- either (Left . DecodeError (Just rvName)) Right (compileField fieldDecoder defaultTdsContext col)
  either (Left . DecodeError (Just rvName)) Right (decodeCell decode rvValue)
