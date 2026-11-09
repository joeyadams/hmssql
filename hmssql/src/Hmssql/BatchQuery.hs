-- | Several statements in one round trip, each with its own result.
--
-- A 'BatchQuery' pairs each statement with what to do with its results,
-- and 'runBatchQuery' sends them all in one request and reads the
-- results in order:
--
-- > (updated, Only total, items) <- runBatchQuery conn $ (,,)
-- >   <$> batchExecute ("UPDATE item SET price = price * 1.1 WHERE category = " <> param cat)
-- >   <*> batchQuery1 ("SELECT SUM(price) FROM item WHERE category = " <> param cat)
-- >   <*> batchQuery ("SELECT id, name FROM item WHERE category = " <> param cat)
-- > -- updated :: Int64, total :: Double, items :: [(Int32, Text)]
--
-- Each statement is its own @sp_executesql@ call, all of them in one RPC
-- message (as 'executeStatements' sends them): the server compiles and runs
-- them in order, and the response carries each one's results between its
-- own DONEPROC markers, so a statement's consumer sees exactly its own
-- result sets and counts, whatever the statements before it returned.  A
-- statement with no parameters is an @sp_executesql@ call too, not a SQL
-- batch, so a @SET@ option it sets or a @#temp@ table it creates lasts
-- only until it returns; statements that must share such state go in one
-- 'Query' (its text joined, as 'Query' is a 'Monoid') to
-- 'queryResultSets' instead.  @'executeStatements' conn qs@ is
-- @'runBatchQuery' conn ('traverse' 'batchExecute' qs)@ with the
-- counting done in bulk, and 'executeStatementsOutcomes' the way to see which
-- statements failed rather than the first that did.
--
-- The consumers mirror "Hmssql.Query": 'batchExecute' for 'execute',
-- 'batchQuery' for 'query' (with 'batchQuery1', 'batchQueryMay',
-- 'batchQueryFold', 'batchQueryS' and the @With@ variants),
-- 'batchQueryMulti' for 'queryMulti', 'batchQueryResultSets' for
-- 'queryResultSets'.  A statement's results are read as its consumer asks
-- for them, and what it leaves unread is skipped before the next
-- statement's, so a 'BatchQuery' holds no more memory than its results;
-- 'batchQueryS' streams the last statement's rows after 'runBatchQuery'
-- returns, as 'queryS' does.
--
-- = Errors
--
-- The server runs the statements in order, and __statements after a
-- failed one may have run__: an error that only ends its statement (a
-- constraint violation, say) lets the server go on to the next; an error
-- that aborts the batch (@THROW@, a conversion error, a deadlock, any
-- error under @SET XACT_ABORT ON@) ends the request there.  Outside a
-- transaction each statement is committed as it completes.  The first
-- error is thrown as 'SqlServerError' with its statement's text, once the
-- whole response (and the messages after it, for a batch over about 1
-- MiB, as 'executeStatements' explains) has been read, so the connection stays
-- usable.  For all-or-nothing, run the batch inside
-- 'Hmssql.Transaction.withTransaction' and let the exception roll it
-- back.
--
-- A statement that can't be sent (a value that can't be encoded, a
-- placeholder with no parameter) throws 'EncodeError', naming its
-- position, before its message is sent; so does a 'batchQueryS' that
-- isn't the last statement.
--
-- The shape is hpgsql's @Hpgsql.Pipeline@.  It is called a batch because
-- that is what TDS has: several statements in one request, run in order,
-- each committed on its own, later ones running after an earlier one's
-- error.
--
-- Only the last statement may stream.  'batchQueryS' gives a stream to read after
-- 'runBatchQuery' returns, so a stream in the middle would leave the statements
-- after it as actions you would have to run later, in order, on one thread.  With
-- only the last one streaming, there is no such order to get wrong.
module Hmssql.BatchQuery
  ( BatchQuery
  , runBatchQuery

    -- * Statements
  , batchExecute
  , batchExecute_

    -- * Queries
  , batchQuery
  , batchQueryWith
  , batchQueryMWith
  , batchQuery1
  , batchQuery1With
  , batchQueryMay
  , batchQueryMayWith

    -- * Folding queries
  , batchQueryFold
  , batchQueryFoldWith

    -- * Streaming queries
  , batchQueryS
  , batchQuerySWith
  , batchQuerySMWith

    -- * Multiple result sets
  , batchQueryMulti
  , batchQueryMultiWith
  , batchQueryMultiMWith
  , batchQueryResultSets
  ) where

import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.Int (Int64)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Streaming (Of, Stream)

import Hmssql.Connection.Internal (Connection, arResultSet, abandonResponse, connectionContext, drainActiveResponse, readingToEnd, startRequestFor, withConnectionLock)
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Query.Internal
import Hmssql.Query.Types
import Hmssql.SqlValue (SqlRow)
import Hmssql.Tds.Context (TdsContext)
import Hmssql.Tds.Token (ServerMessage)

-- | Several statements sent in one request, each paired with what to do
-- with its results: see "Hmssql.BatchQuery".
--
-- An 'Applicative', not a 'Monad': every statement is known before the
-- batch is sent, so a later statement can't depend on an earlier one's
-- rows (the 'ResultSets' monad of one statement can, within it).
data BatchQuery a = BatchQuery
  ([BatchItem] -> [BatchItem])
    -- ^ The statements, in order (a difference list).
  (BatchRun -> IO a)
    -- ^ Read each statement's results in turn ('nextStatement').

instance Functor BatchQuery where
  fmap f (BatchQuery items run) = BatchQuery items (fmap f . run)

instance Applicative BatchQuery where
  pure a = BatchQuery id (\_ -> pure a)
  BatchQuery items f <*> BatchQuery items' x = BatchQuery (items . items') $ \br -> do
    g <- f br
    g <$> x br

-- | One statement of a batch.
data BatchItem = BatchItem
  { itemQuery :: !Query
  , itemStreams :: !Bool
    -- ^ Its rows are read after 'runBatchQuery' returns (a
    -- 'batchQueryS' stream), so it must be the last.
  }

-- | A batch being run: the connection, its state, and the scope the
-- statement being read is bounded by.
data BatchRun = BatchRun
  { brConn :: !Connection
  , brState :: !(IORef BatchState)
  , brScope :: !BatchScope
  }

-- | Where a batch is: the reader of the message being read, if one has
-- been sent; how many statements have been opened (the position of the
-- next, from 0); the texts of the message's statements not opened yet;
-- the queries after the message; and whether a statement is open (was
-- given to its consumer, and hasn't been skipped to its end).
data BatchState = BatchState
  { bsReader :: !(Maybe ResponseReader)
  , bsIndex :: !Int
  , bsInMessage :: [Text]
  , bsRest :: [Query]
  , bsOpen :: !Bool
  }

-- | Run the batch: send the statements, read each one's results as its
-- consumer asks, and read the response to its end.  Nothing is sent for
-- a batch of no statements.  Statements that don't fit one message go
-- in the next, sent once the previous response has been read; a
-- statement's consumer runs when its results are reached.
runBatchQuery :: Connection -> BatchQuery a -> IO a
runBatchQuery conn (BatchQuery mkItems run) = case mkItems [] of
  [] -> do
    br <- newRun []
    run br
  items -> withConnectionLock conn $ do
    forM_ (zip [0 :: Int ..] (init items)) $ \(i, item) -> when (itemStreams item) $ throwIO $ EncodeError $
      "statement " ++ show i ++ " (from 0) streams its rows (batchQueryS), so it must be the last of the batch"
    br <- newRun (map itemQuery items)
    let body = do
          a <- run br
          unless (itemStreams (last items)) $ finishBatch br
          pure a
    body `catch` \(e :: SomeException) -> do
      case fromException e of
        -- Interrupted: the message's response is marked abandoned and its
        -- statement canceled at once, and the next request drains it, as
        -- for 'query' ('Hmssql.Connection.Internal.readingToEnd').
        Just (_ :: SomeAsyncException) -> abandonCurrent br
        Nothing -> abandonBatch br
      throwIO e
  where
    newRun qs = do
      st <- newIORef (BatchState Nothing 0 [] qs False)
      ended <- newIORef False
      stmt <- newIORef T.empty
      let br = BatchRun conn st (BatchScope ended stmt (failBatch br))
      pure br

-- | After an interruption: the response of the message being read, if it
-- hasn't ended, is canceled at once and left to the next request to
-- drain ('abandonResponse').
abandonCurrent :: BatchRun -> IO ()
abandonCurrent BatchRun{..} = do
  st <- readIORef brState
  forM_ (bsReader st) $ \rr -> abandonResponse brConn (respActive rr)

-- | Run the action; a synchronous exception runs the handler (an
-- asynchronous one is rethrown as it is, after the Attention 'nextStep'
-- has sent).
catchSyncException :: IO a -> (SomeException -> IO a) -> IO a
catchSyncException act handler = act `catch` \e -> case fromException e of
  Just (_ :: SomeAsyncException) -> throwIO e
  Nothing -> handler e

-- | The reader of the next statement's results, bounded to them: the
-- statement before it is read to its end first, and the next message
-- sent when the current one's statements are all read.
nextStatement :: BatchRun -> IO ResponseReader
nextStatement br@BatchRun{..} = do
  st <- readIORef brState
  when (bsOpen st) $ closeStatement br st
  case (bsReader st, bsInMessage st) of
    (Just rr, stmt : more) -> do
      writeIORef (scopeEnded brScope) False
      writeIORef (scopeStatement brScope) stmt
      writeIORef brState st { bsInMessage = more, bsIndex = bsIndex st + 1, bsOpen = True }
      pure rr
    (_, _ : _) -> throwIO $ ProtocolError "batch: statements to read, but no response"
    (mrr, []) -> do
      forM_ mrr (finishMessage br)
      case bsRest st of
        [] -> throwIO $ ProtocolError "batch: more statements read than were sent"
        qs -> do
          ctx <- connectionContext brConn
          (stmts, _, rest, ()) <- either (throwIO . EncodeError) pure (takeStatements queryStatement ctx () (bsIndex st) qs)
          texts <- mapM (evaluate . fst) stmts
          Request{..} <- statementsRequest stmts
          -- Masked from the send to recording the reader, so that an
          -- interruption finds the response ('abandonCurrent').
          mask_ $ do
            ar <- startRequestFor brConn requestStatement requestPacketType requestBody
            rr <- (\r -> r { respBatch = Just brScope }) <$> responseReader brConn ar Nothing
            writeIORef brState st { bsReader = Just rr, bsInMessage = texts, bsRest = rest, bsOpen = False }
          nextStatement br

-- | Read the open statement to its end (its consumer may have stopped
-- before it), and check it ended: a response that ended before its
-- DONEPROC without an error is a protocol error.
closeStatement :: BatchRun -> BatchState -> IO ()
closeStatement BatchRun{..} st = forM_ (bsReader st) $ \rr -> do
  let skip = readStep rr ignoreRows >>= \case
        StepEnd -> pure ()
        _ -> skip
  skip
  ended <- readIORef (scopeEnded brScope)
  unless ended $ throwIO $ ProtocolError $
    "batch: the response ended before statement " ++ show (bsIndex st - 1) ++ " (from 0) completed, and no error was reported"
  -- Each statement supplies its own metadata. Clear at DONEPROC, not when
  -- opening a statement: reset replay can already hold its first COLMETADATA.
  writeIORef (arResultSet (respActive rr)) Nothing
  writeIORef brState st { bsOpen = False }

-- | Read the message's response to its end, past the last statement's
-- DONEPROC: a failed DONE is thrown here.
finishMessage :: BatchRun -> ResponseReader -> IO ()
finishMessage BatchRun{..} rr = do
  stmt <- readIORef (scopeStatement brScope)
  drainResponse rr { respBatch = Nothing, respStatement = Just stmt }

-- | After the last consumer: read the open statement to its end and the
-- response after it.  Every statement must have been read.
finishBatch :: BatchRun -> IO ()
finishBatch br@BatchRun{..} = do
  st <- readIORef brState
  when (bsOpen st) $ closeStatement br st
  unless (null (bsInMessage st) && null (bsRest st)) $
    throwIO $ ProtocolError "batch: statements were sent but their results not read"
  forM_ (bsReader st) (finishMessage br)

-- | An ERROR token arrived while a statement was being read: the rest of
-- the response is read, the messages after it are sent and read (their
-- statements run, as they would have in one message), and the error is
-- thrown for its statement.  A later message that can't be encoded isn't
-- sent, nor those after it; a connection the server closes after the
-- error (severity 20 and up) throws the error too.
failBatch :: BatchRun -> ServerMessage -> IO Void
failBatch BatchRun{..} msg = do
  stmt <- readIORef (scopeStatement brScope)
  st <- readIORef brState
  let failure = SqlServerError msg (Just stmt)
      drain ar = drainActiveResponse brConn ar `catch` \e -> case e of
        ConnectionClosedBy reason | not (byClient reason) -> throwIO failure
        _ -> throwIO e
  forM_ (bsReader st) $ \rr -> do
    drain (respActive rr)
    writeIORef (respEnded rr) True
  ctx <- connectionContext brConn
  let go !i qs = case qs of
        [] -> pure ()
        _ -> case takeStatements queryStatement ctx () i qs of
          Left _ -> pure ()
          Right (stmts, n, rest, ()) -> do
            Request{..} <- statementsRequest stmts
            mask $ \restore -> do
              ar <- startRequestFor brConn requestStatement requestPacketType requestBody
              readingToEnd brConn ar (restore (drain ar))
            go (i + n) rest
  go (bsIndex st + length (bsInMessage st)) (bsRest st)
  throwIO failure
  where
    byClient = \case
      ClosedByClient -> True
      _ -> False

-- | A consumer threw (a row that doesn't decode, a shape the item didn't
-- expect, a fold's step): read the rest of the response so the
-- connection isn't left mid-message (as 'query' does before throwing a
-- 'DecodeError'), quietly.  The messages after it aren't sent.
abandonBatch :: BatchRun -> IO ()
abandonBatch BatchRun{..} = do
  st <- readIORef brState
  forM_ (bsReader st) $ \rr -> readIORef (respEnded rr) >>= \case
    True -> pure ()
    False -> do
      drainActiveResponse brConn (respActive rr) `catchSyncException` \_ -> pure ()
      writeIORef (respEnded rr) True

-- | A statement of a batch and its consumer, run over the reader bounded
-- to the statement's results.
batchItem :: Query -> (TdsContext -> ResponseReader -> IO a) -> BatchQuery a
batchItem q consume = BatchQuery (BatchItem q False :) $ \br -> do
  rr <- nextStatement br
  ctx <- connectionContext (brConn br)
  consume ctx rr

-- | The statement's rows affected: what 'execute' returns for it.
batchExecute :: Query -> BatchQuery Int64
batchExecute q = batchItem q (\_ rr -> affectedRows rr)

-- | 'batchExecute' without the count.
batchExecute_ :: Query -> BatchQuery ()
batchExecute_ = void . batchExecute

-- | The rows of the statement's first result set: what 'query' returns
-- for it (@[]@ for a statement with no result set).
batchQuery :: FromSqlRow r => Query -> BatchQuery [r]
batchQuery = batchQueryWith rowDecoder

-- | 'batchQuery' with the given row decoder, as 'queryWith'.
batchQueryWith :: RowDecoder r -> Query -> BatchQuery [r]
batchQueryWith dec q = batchItem q (\_ rr -> readFirstResultSet (compilerFor dec) rr)

-- | 'batchQuery' with a 'RowDecoderMonadic', as 'queryMWith'.
batchQueryMWith :: RowDecoderMonadic r -> Query -> BatchQuery [r]
batchQueryMWith dec q = batchItem q (\_ rr -> readFirstResultSet (compilerForM dec) rr)

-- | Exactly one row, as 'query1'.
batchQuery1 :: FromSqlRow r => Query -> BatchQuery r
batchQuery1 = batchQuery1With rowDecoder

-- | 'batchQuery1' with the given row decoder, as 'query1With'.
batchQuery1With :: RowDecoder r -> Query -> BatchQuery r
batchQuery1With dec q = batchItem q (\_ rr -> readFirstResultSet (compilerFor dec) rr >>= exactlyOne)

-- | Zero or one row, as 'queryMay'.
batchQueryMay :: FromSqlRow r => Query -> BatchQuery (Maybe r)
batchQueryMay = batchQueryMayWith rowDecoder

-- | 'batchQueryMay' with the given row decoder, as 'queryMayWith'.
batchQueryMayWith :: RowDecoder r -> Query -> BatchQuery (Maybe r)
batchQueryMayWith dec q = batchItem q (\_ rr -> readFirstResultSet (compilerFor dec) rr >>= atMostOne)

-- | Fold over the rows of the statement's first result set as they
-- arrive, as 'queryFold': the step runs with the connection lock held,
-- while the batch is being read, so it can't use the connection.
batchQueryFold :: FromSqlRow r => Query -> a -> (a -> r -> IO a) -> BatchQuery a
batchQueryFold = batchQueryFoldWith rowDecoder

-- | 'batchQueryFold' with the given row decoder, as 'queryFoldWith'.
batchQueryFoldWith :: RowDecoder r -> Query -> a -> (a -> r -> IO a) -> BatchQuery a
batchQueryFoldWith dec q z step = batchItem q (\_ rr -> foldFirstResultSet (compilerFor dec) rr z step)

-- | Stream the rows of the statement's first result set, as 'queryS':
-- they are read from the socket as the stream is consumed, after
-- 'runBatchQuery' has returned.  So the statement must be the last of
-- its batch ('runBatchQuery' throws 'EncodeError' otherwise, before
-- sending anything), and its stream must be consumed before the next
-- request on the connection, as any 'queryS' stream must (on a MARS
-- connection it stays open beside later requests instead, as a 'queryS'
-- stream does).  An error the statement reports is thrown by the stream;
-- one an earlier statement reports, by 'runBatchQuery'.
batchQueryS :: FromSqlRow r => Query -> BatchQuery (Stream (Of r) IO ())
batchQueryS = batchQuerySWith rowDecoder

-- | 'batchQueryS' with the given row decoder, as 'querySWith'.
batchQuerySWith :: RowDecoder r -> Query -> BatchQuery (Stream (Of r) IO ())
batchQuerySWith dec = batchStream (compilerFor dec)

-- | 'batchQueryS' with a 'RowDecoderMonadic', as 'querySMWith'.
batchQuerySMWith :: RowDecoderMonadic r -> Query -> BatchQuery (Stream (Of r) IO ())
batchQuerySMWith dec = batchStream (compilerForM dec)

batchStream :: RowCompiler r -> Query -> BatchQuery (Stream (Of r) IO ())
batchStream compile q = BatchQuery (BatchItem q True :) $ \br -> do
  rr <- nextStatement br
  pure (streamFirstResultSet compile rr (finishBatch br))

-- | Every result set of the statement, as 'queryMulti'.
batchQueryMulti :: Query -> BatchQuery [ResultSet SqlRow]
batchQueryMulti q = batchItem q (\_ rr -> readResultSets sqlRowCompiler rr)

-- | 'batchQueryMulti' with the given row decoder, as 'queryMultiWith'.
batchQueryMultiWith :: RowDecoder r -> Query -> BatchQuery [ResultSet r]
batchQueryMultiWith dec q = batchItem q (\_ rr -> readResultSets (compilerFor dec) rr)

-- | 'batchQueryMulti' with a 'RowDecoderMonadic', as 'queryMultiMWith'.
batchQueryMultiMWith :: RowDecoderMonadic r -> Query -> BatchQuery [ResultSet r]
batchQueryMultiMWith dec q = batchItem q (\_ rr -> readResultSets (compilerForM dec) rr)

-- | The statement's result sets decoded one at a time by a 'ResultSets'
-- action, as 'queryResultSets': the result sets are the statement's own,
-- and asking for one past its last throws 'UnexpectedResult'.
batchQueryResultSets :: ResultSets a -> Query -> BatchQuery a
batchQueryResultSets sets q = batchItem q (\_ rr -> readResultSetsWith sets rr)

