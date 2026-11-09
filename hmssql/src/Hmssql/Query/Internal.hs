{-# OPTIONS_HADDOCK not-home #-}

-- | What "Hmssql.Query" and "Hmssql.BatchQuery" share beyond the types of
-- "Hmssql.Query.Types": encoding a query into its @sp_executesql@ call,
-- reading a response step by step, decoding result sets from a reader, and
-- packing statements into messages.  Applications use "Hmssql.Query",
-- which re-exports 'readStep', 'drainResponse' and 'paramNameProblem';
-- nothing here is stable.
module Hmssql.Query.Internal where

import Control.Exception
import Control.Applicative ((<|>))
import Control.Monad (foldM)
import qualified Data.ByteString as B
import Data.IORef
import qualified Data.List as List
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (absurd)
import Streaming (Of (..), Stream, effect)
import qualified Streaming.Internal as SI

import Hmssql.Connection.Internal
import Hmssql.Decoding
import Hmssql.Encoding
import Hmssql.Errors
import Hmssql.Query.Lexer (isVariableChar)
import Hmssql.Query.Types
import Hmssql.SqlValue
import Hmssql.Tds.Parameter (paramValueProblem)
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (Collation (..))
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

------------------------------------------------------------------------------
-- Encoding queries

-- | The @sp_executesql@ call of a statement with its parameters named.
executeSqlRpc :: Text -> [(Text, EncodedParam)] -> RpcRequest
executeSqlRpc sql named = RpcRequest procSpExecuteSql 0 $ case named of
  [] -> [textParam sql]
  _ -> textParam sql : declarationParam named : valueParams named

-- | An @nvarchar(max)@ parameter of @sp_executesql@'s own: the statement,
-- or the declaration.
textParam :: Text -> RpcParam
textParam t = RpcParam "" 0 (TINVarChar maxLength (Collation 0 0)) (ParamBytes (Just (Utf16.encodeUtf16LE t)))

-- | @\@params@: the parameters' names and types, @\@p1 int,\@p2
-- nvarchar(4000)@, written as UTF-16LE straight into one buffer.
declarationParam :: [(Text, EncodedParam)] -> RpcParam
declarationParam named = textParam (T.intercalate "," [name <> " " <> typeInfoSqlName ti | (name, (ti, _)) <- named])

valueParams :: [(Text, EncodedParam)] -> [RpcParam]
valueParams named = [RpcParam name 0 ti v | (name, (ti, v)) <- named]

-- | A query's text and its parameters, encoded, checked and named, or why
-- it can't be sent.
encodeQuery :: TdsContext -> Query -> Either String (Text, [(Text, EncodedParam)])
encodeQuery ctx q = do
  mapM_ Left (fragmentsProblem (queryPositional q) frags)
  named <- encodeQueryParams ctx (queryParams q)
  pure (sql, named)
  where
    -- Flattened once, for the check and the text.
    frags = queryFragments q
    sql = renderFragments frags

-- | Parameters encoded, checked and named: the positional ones @pN by
-- their position among the positional ones.
encodeQueryParams :: TdsContext -> [QueryParam] -> Either String [(Text, EncodedParam)]
encodeQueryParams ctx = \case
  [] -> pure []
  params -> do
    named <- encodeAll 1 params
    checkDuplicates [name | (QueryParam given _, (name, _)) <- zip params named, not (T.null given)]
    pure named
  where
    encodeAll :: Int -> [QueryParam] -> Either String [(Text, EncodedParam)]
    encodeAll _ [] = pure []
    encodeAll !i (QueryParam given enc : ps)
      | T.null given = do
          (ti, v) <- enc ctx
          let name = positionalName i
          mapM_ Left (valueProblems name ti v)
          ((name, (ti, v)) :) <$> encodeAll (i + 1) ps
      | otherwise = do
          (ti, v) <- enc ctx
          mapM_ Left (reservedNameProblem given <|> paramNameProblem given <|> rpcParamProblem (RpcParam given 0 ti v))
          ((given, (ti, v)) :) <$> encodeAll i ps
    -- 'rpcParamProblem' without the name's length check, which a
    -- positional name passes.
    valueProblems name ti v = (("parameter " ++ T.unpack name ++ ": ") ++) <$>
      (typeInfoProblem ti <|> paramValueProblem ti v)
    checkDuplicates = go Set.empty
    go _ [] = pure ()
    go seen (n : ns)
      | Set.member key seen = Left $ "duplicate parameter name " ++ T.unpack n
      | otherwise = go (Set.insert key seen) ns
      where key = T.toCaseFold n

-- | @\@p@ and the number.
positionalName :: Int -> Text
positionalName = placeholderText

-- | A named parameter can't be called @\@pN@: that is how the positional
-- parameters are named.
reservedNameProblem :: Text -> Maybe String
reservedNameProblem name = case T.uncons name of
  Just ('@', rest)
    | Just (p, digits) <- T.uncons rest, p == 'p' || p == 'P'
    , not (T.null digits), T.all (\c -> c >= '0' && c <= '9') digits ->
        Just $ "parameter name " ++ show name ++ " is reserved for the positional parameters (@p1, @p2, ...)"
  _ -> Nothing

-- | Why a parameter name can't be used, if it can't: it must be a T-SQL
-- variable name, @\@@ followed by one or more letters, combining marks,
-- decimal digits, @\@@, @#@, @$@ or @_@ (Unicode ones included, but only
-- from the Basic Multilingual Plane: SQL Server rejects surrogates in
-- identifiers).  The query functions' parameter names are spliced into the
-- @sp_executesql@ declaration, where anything else (a space, a comma, a
-- parenthesis, a comment) would change what is declared.  'callProcedure'
-- doesn't use this check: its parameter names are sent as data, and the
-- server reports the ones it can't match.  SQL Server itself accepts a few
-- more names (a bare @\@@, and ignores format characters such as U+200D
-- and trailing spaces in RPC parameter names), and rejects some letters
-- added in recent Unicode versions; it enforces its 128-character limit
-- itself.
paramNameProblem :: Text -> Maybe String
paramNameProblem name = case T.uncons name of
  Just ('@', rest) | not (T.null rest), T.all variableChar rest -> Nothing
  _ -> Just $
    "parameter name " ++ show name ++ " is not a T-SQL variable name"
      ++ " (@ followed by letters, digits, @, #, $ or _)"
  where
    variableChar = isVariableChar

------------------------------------------------------------------------------
-- Reading responses

-- | The next thing in the response ('nextStep'), with the rows decoded
-- by the given function: a batch of rows, a token other than a row or
-- a nonfatal ERROR (withheld), or 'StepEnd', which throws the withheld error (or
-- 'SevereError') instead if there was one.  A response that ends with
-- the connection closed after an error (by the server, as after a
-- severity 20 error, or by a failed transport) throws that error; after
-- 'Hmssql.Connection.close', the 'ConnectionClosed' that every use of the
-- connection gets.  (The withheld error is the reader's, not a stream's:
-- a stream run again from a step before the error would otherwise report
-- an error it hadn't seen.)
--
-- A fatal ERROR is thrown by the common token reader immediately and
-- leaves the connection broken.
--
-- Reading one statement of a batch query ('respBatch'): the statement's
-- DONEPROC is returned and then 'StepEnd', for as long as the statement
-- stays the current one; an ERROR token isn't withheld but ends the batch
-- ('scopeFail'), and the response's end throws 'SevereError' for a
-- failed DONE but never a withheld error, which there is none of.
readStep :: ResponseReader -> RowRead r -> IO (ResponseStep r)
readStep = readStepUsing False

-- 'readStep' with each batch's rows in reverse order.  Only 'readFirstResultSet'
-- uses it, and wraps each batch as a 'ReversedBatch' at once, so that no
-- streaming or token-level caller sees a 'RowBatch' out of order.
readStepReversed :: ResponseReader -> RowRead r -> IO (ResponseStep r)
readStepReversed = readStepUsing True

readStepUsing :: Bool -> ResponseReader -> RowRead r -> IO (ResponseStep r)
readStepUsing reversed rr@ResponseReader{..} decodeRow = withStatement $ case respBatch of
  Nothing -> readIORef respPushback >>= \case
    Just tok -> writeIORef respPushback Nothing >> pure (StepToken tok)
    Nothing -> do
      r <- try ((if reversed then nextStepReversed else nextStep) respConn respActive decodeRow)
      case r of
        Left e
          | closedByServer e -> readIORef respFirstError >>= \case
              Just err -> throwIO (SqlServerError err respStatement)
              Nothing -> throwIO e
          | otherwise -> throwIO e
        Right StepEnd -> do
          writeIORef respEnded True
          firstErr <- readIORef respFirstError
          failedDone <- readIORef respFailedDone
          case (firstErr, failedDone) of
            (Just err, _) -> throwIO (SqlServerError err respStatement)
            (Nothing, Just d) -> throwSevere respConn d respStatement
            (Nothing, Nothing) -> pure StepEnd
        Right (StepToken (TError msg)) -> do
          modifyIORef' respFirstError (<|> Just msg)
          readStepUsing reversed rr decodeRow
        Right step@(StepToken tok) -> do
          noteFailedDone tok
          pure step
        Right step -> pure step
  Just scope -> do
    ended <- (||) <$> readIORef (scopeEnded scope) <*> readIORef respEnded
    if ended
      then pure StepEnd
      else readIORef respPushback >>= \case
        Just tok -> writeIORef respPushback Nothing >> statementToken scope tok
        Nothing -> (if reversed then nextStepReversed else nextStep) respConn respActive decodeRow >>= \case
          StepEnd -> do
            writeIORef respEnded True
            readIORef respFailedDone >>= \case
              Just d -> do
                stmt <- readIORef (scopeStatement scope)
                throwSevere respConn d (Just stmt)
              Nothing -> pure StepEnd
          StepToken (TError msg) -> do
            modifyIORef' respFirstError (<|> Just msg)
            scopeFail scope msg >>= absurd
          StepToken tok -> statementToken scope tok
          step -> pure step
  where
    -- Fatal ERRORs throw in the common token reader, before they reach
    -- scopeFail. The request names the batch's last statement, but this
    -- reader knows which statement is being consumed.
    withStatement act = act `catch` \(err :: SqlServerError) -> do
      stmt <- maybe (pure respStatement) (fmap Just . readIORef . scopeStatement) respBatch
      throwIO err { sqlErrorStatement = stmt }
    closedByServer e = case fromException e of
      Just (ConnectionClosedBy reason) -> not (byClient reason)
      _ -> False
    byClient = \case
      ClosedByClient -> True
      _ -> False
    statementToken scope tok = do
      noteFailedDone tok
      case tok of
        TDoneProc _ -> writeIORef (scopeEnded scope) True
        _ -> pure ()
      pure (StepToken tok)
    noteFailedDone tok = mapM_ (\d -> modifyIORef' respFailedDone (<|> Just d)) (flagged tok)
    -- A DONE flagged as failed.
    flagged = \case
      TDone d | failed d -> Just d
      TDoneProc d | failed d -> Just d
      TDoneInProc d | failed d -> Just d
      _ -> Nothing
    failed d = doneError d || doneServerError d

-- | Skip the rows without decoding them.  A row before the first COLMETADATA
-- is a 'ProtocolError', since there are no columns to skip it by, so the
-- result-set loops need no state for that case.
ignoreRows :: RowRead ()
ignoreRows = discardRows

-- | Read the rest of the response and discard it.  The withheld error,
-- if any, is thrown at the end.  Nothing to do once the end has been
-- read.
drainResponse :: ResponseReader -> IO ()
drainResponse resp = readIORef (respEnded resp) >>= \case
  True -> pure ()
  False -> readStep resp drainingRows >>= \case
    StepEnd -> pure ()
    _ -> drainResponse resp

-- | Yield the rows of a batch, then continue.  Before each row, the
-- response must still be the current one ('checkCurrent'): the rows of
-- a batch are read from the connection together, but a stream whose
-- response was superseded by a later request (or canceled, or drained)
-- throws 'ResultAbandoned' at the next row it is asked for, not after
-- the rows it already had.
yieldRows :: ResponseReader -> [r] -> Stream (Of r) IO () -> Stream (Of r) IO ()
yieldRows resp = go
  where
    -- Built from the constructors: 'S.yield' and '>>' cost a bind and
    -- its closures per row on top of the step.
    go [] rest = rest
    go (r : rs) rest = SI.Effect $ do
      checkCurrent (respConn resp) (respActive resp)
      let !next = go rs rest
      pure (SI.Step (r :> next))

------------------------------------------------------------------------------
-- The first result set

-- | How to turn a result set's columns into a per-row decoding function.
type RowCompiler r = TdsContext -> [ColumnInfo] -> Either DecodeError (CompiledRow r)

compilerFor :: RowDecoder r -> RowCompiler r
compilerFor = compileRowDecoder

-- | A 'RowDecoderMonadic' runs per row (later fields may depend on earlier
-- values). The completed decoder must consume every column; prefixes may
-- be composed inside it. An empty result set cannot be checked this way.
compilerForM :: RowDecoderMonadic r -> RowCompiler r
compilerForM dec ctx cols = Right (compileMonadicRowDecoder dec ctx cols)

-- | How 'queryMulti' and 'callProcedure' decode: every column as a
-- 'SqlValue', with the decoders compiled once per result set.
sqlRowCompiler :: RowCompiler SqlRow
sqlRowCompiler ctx cols = compileRowDecoder (sqlRowDecoderFor cols) ctx cols

-- | Skip to the first result set: its decoder, compiled, or 'Nothing' if
-- the response has none.  On a compile failure the rest of the response
-- is drained before the error is thrown.
firstResultSet :: RowCompiler r -> ResponseReader -> IO (Maybe (RowRead r))
firstResultSet compile resp = do
  ctx <- connectionContext (respConn resp)
  let go = readStep resp ignoreRows >>= \case
        StepEnd -> pure Nothing
        StepToken (TColMetaData cols) -> case compile ctx cols of
          Left err -> drainResponse resp >> throwIO err
          Right decode -> Just <$> newRowRead (connValueAllocAhead (respConn resp)) decode
        _ -> go
  go

-- | Whether a token ends the result set whose rows are being read.
endsResultSet :: Token -> Bool
endsResultSet = \case
  TColMetaData _ -> True
  TDone _ -> True
  TDoneProc _ -> True
  TDoneInProc _ -> True
  _ -> False

-- | Fold over the rows of the first result set, a batch at a time, then
-- drain the rest of the response.  A row that doesn't decode drains the
-- rest of the response before its 'DecodeError' is thrown.  Before each
-- call of the step, the response must still be the current one
-- ('checkCurrent', as a 'queryS' stream checks before each row): a step
-- that abandons it (by making another request on the connection, or
-- closing it) is the last to run, and the fold throws 'ResultAbandoned'
-- rather than run the steps for the rest of the batch it had.
foldFirstResultSet :: RowCompiler r -> ResponseReader -> a -> (a -> r -> IO a) -> IO a
foldFirstResultSet compile resp z step = foldBatches compile resp z $
  foldM $ \acc r -> do
    checkCurrent (respConn resp) (respActive resp)
    step acc r

-- | 'foldFirstResultSet' a batch (the rows of one packet) at a time.
foldBatches :: RowCompiler r -> ResponseReader -> a -> (a -> [r] -> IO a) -> IO a
foldBatches = foldBatchesUsing readStep

foldBatchesUsing :: (ResponseReader -> RowRead r -> IO (ResponseStep r)) -> RowCompiler r -> ResponseReader -> a -> (a -> [r] -> IO a) -> IO a
foldBatchesUsing readBatch compile resp z step =
  firstResultSet compile resp >>= \case
    Nothing -> pure z
    Just decode -> do
      let go !acc = readBatch resp decode >>= \case
            StepRows (RowBatch rows failed) -> do
              acc' <- step acc rows
              case failed of
                Nothing -> go acc'
                Just err -> drainResponse resp >> throwIO err
            StepToken tok
              | endsResultSet tok -> drainResponse resp >> pure acc
              | otherwise -> go acc
            StepEnd -> pure acc
      go z

-- | The rows of the first result set, decoded, and the rest of the
-- response drained.
readFirstResultSet :: RowCompiler r -> ResponseReader -> IO [r]
readFirstResultSet compile resp = joinReversedBatches <$>
  foldBatchesUsing readStepReversed compile resp [] (\acc rows -> pure (ReversedBatch rows : acc))

-- The rows of one packet, last first.  A collected result is then reversed once,
-- where it was reversed per packet and copied again as the packets were joined:
-- one cons cell per row less, 23 MB (14.3%) over 100 queries of 10,000 @int@
-- and @bigint@ rows, for the same maximum residency (GHC 9.12.4, 2026-11-04).
newtype ReversedBatch r = ReversedBatch [r]

joinReversedBatches :: [ReversedBatch r] -> [r]
joinReversedBatches = List.foldl' (\acc (ReversedBatch rows) -> List.foldl' (flip (:)) acc rows) []

-- | Rows of the first result set, decoded, a batch (the rows of one
-- packet) per effect; then the given action, which reads the rest of the
-- response ('drainResponse' for a query of its own).
streamFirstResultSet :: RowCompiler r -> ResponseReader -> IO () -> Stream (Of r) IO ()
streamFirstResultSet compile resp finish = effect $ firstResultSet compile resp >>= \case
  Nothing -> finish >> pure (pure ())
  Just decode -> pure (rows decode)
  where
    rows decode = effect $ readStep resp decode >>= \case
      StepRows (RowBatch batch failed) -> pure $ yieldRows resp batch $ case failed of
        Nothing -> rows decode
        Just err -> effect (drainResponse resp >> throwIO err)
      StepToken tok
        | endsResultSet tok -> pure (effect (finish >> pure (pure ())))
        | otherwise -> pure (rows decode)
      StepEnd -> pure (effect (finish >> pure (pure ())))

------------------------------------------------------------------------------
-- Several statements in one request

-- | How to encode each item of a list as a statement: its text and its
-- RPC, or why it can't be sent.  The state is what one item passes on to
-- the next.
type StatementEncoder s a = TdsContext -> s -> a -> Either String (Text, RpcRequest, s)

-- | A 'Query' as its @sp_executesql@ call.
queryStatement :: StatementEncoder () Query
queryStatement ctx () q = do
  (sql, named) <- encodeQuery ctx q
  let !rpc = executeSqlRpc sql named
  pure (sql, rpc, ())

-- | One message of statements.  It is named by its last statement's text
-- ('busyStatements'): the statement a 'Hmssql.BatchQuery.batchQueryS'
-- stream reads, which is what a message left unfinished is.
statementsRequest :: [(Text, RpcRequest)] -> IO Request
statementsRequest stmts = (\body -> Request PTRpc body lastText) <$> newRpcWriter (map snd stmts)
  where
    lastText = case stmts of
      [] -> Nothing
      _ -> Just $! fst (List.last stmts)

-- | About how many bytes of statements 'runStatements' sends per message.
statementMessageBytes :: Int
statementMessageBytes = 1048576

-- | The statements of the next message, encoded (with the text of each),
-- how many there are, the items after them and the encoder's state; or
-- why one can't be sent.  @i@ is the position of the first in the
-- caller's list.
takeStatements :: StatementEncoder s a -> TdsContext -> s -> Int -> [a] -> Either String ([(Text, RpcRequest)], Int, [a], s)
takeStatements encode ctx s0 i0 = go i0 0 s0 []
  where
    go !i !size s acc = \case
      a : as | size < statementMessageBytes -> do
        (sql, rpc, s') <- either (\e -> Left ("statement " ++ show i ++ " (from 0): " ++ e)) Right (encode ctx s a)
        go (i + 1) (size + rpcSize rpc) s' ((sql, rpc) : acc) as
      as -> Right (reverse acc, i - i0, as, s)
    -- About the size of the RPC as written.
    rpcSize (RpcRequest _ _ params) = 8 + sum [paramSize p | p <- params]
    paramSize (RpcParam name _ _ v) = 16 + 2 * T.length name + case v of ParamBytes b -> maybe 0 B.length b; _ -> statementMessageBytes

------------------------------------------------------------------------------
-- Rows and result sets

-- | The batches, newest first, as one list in order: one list cell per
-- row, and none for the last batch, which is the list's tail as it is.
joinBatches :: [[r]] -> [r]
joinBatches = \case
  [] -> []
  newest : older -> go newest older
  where
    go acc = \case
      [] -> acc
      b : bs -> go (prependTo b acc) bs
    prependTo b acc = case b of
      [] -> acc
      x : xs -> let !rest = prependTo xs acc in x : rest

exactlyOne :: [r] -> IO r
exactlyOne = \case
  [r] -> pure r
  rs -> throwIO $ UnexpectedResult $ "expected exactly one row, got " ++ show (length rs)

atMostOne :: [r] -> IO (Maybe r)
atMostOne = \case
  [] -> pure Nothing
  [r] -> pure (Just r)
  rs -> throwIO $ UnexpectedResult $ "expected at most one row, got " ++ show (length rs)

-- | Every result set the reader has left, each decoded by the compiler.
readResultSets :: RowCompiler r -> ResponseReader -> IO [ResultSet r]
readResultSets compile resp = do
  ctx <- connectionContext (respConn resp)
  -- The common skipper rejects rows before metadata. Within a set, its
  -- decoder travels with its columns. Completed sets and row batches
  -- accumulate newest first, and are joined only when a set ends.
  let beforeFirst = readStep resp ignoreRows >>= \case
        StepEnd -> pure []
        StepToken (TColMetaData cols) -> startSet [] cols
        _ -> beforeFirst
      startSet sets cols = case compile ctx cols of
        Left err -> drainResponse resp >> throwIO err
        Right compiled -> do
          decode <- newRowRead (connValueAllocAhead (respConn resp)) compiled
          inSet sets cols decode []
      inSet sets cols decode batches = readStep resp decode >>= \case
        StepEnd -> pure (reverse (flush sets cols batches))
        StepToken (TColMetaData next) -> startSet (flush sets cols batches) next
        StepToken _ -> inSet sets cols decode batches
        StepRows (RowBatch rows failed) -> case failed of
          Just err -> drainResponse resp >> throwIO err
          Nothing -> inSet sets cols decode (rows : batches)
      flush sets cols batches = ResultSet cols (joinBatches batches) : sets
  beforeFirst

-- | Run the decoder over what the reader has left, then drain the rest.
readResultSetsWith :: ResultSets a -> ResponseReader -> IO a
readResultSetsWith sets resp = do
  ctx <- connectionContext (respConn resp)
  a <- runResultSets sets ctx resp
  drainResponse resp
  pure a
