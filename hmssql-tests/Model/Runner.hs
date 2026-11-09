{-# LANGUAGE DerivingStrategies #-}

-- | Runs "Model.Machine" operations against a real connection.
--
-- Every operation runs on one executor thread, so that a 'withTransaction'
-- body can span several operations: 'TxBegin' enters 'withTransaction' on
-- the executor thread, whose body serves the following operations until
-- 'TxEnd' makes it return or throw.  (The body must run on the thread
-- that holds the connection lock, so nested ones nest on the same thread.)
--
-- 'Release' releases the current handle and renews it, as a pool would
-- between two borrowers; every operation after it uses the new handle,
-- and a stream keeps the one it was opened through.
--
-- Streams are kept by slot, each with its response's reader, so that one
-- can be cancelled ('cancelResponse').  On a MARS connection, opening one
-- waits until its response has all arrived (see "Model.Machine").
module Model.Runner
  ( Shared (..)
  , withModelFixture
  , withShared
  , Env (..)
  , newEnv
  , releaseEnv
  , Result (..)
  , runOp
  , cfgFor
  ) where

import Control.Concurrent
import GHC.Conc (threadStatus)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.IORef
import Data.Int (Int32)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import Compat (timeoutInSlices)
import Test.Hspec (SpecWith)

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Connection.Internal (ActiveResponse (..), Connection (..), Session (..), SmpLink (..), SmpSession (..), renewLease)
import Hmssql.Query.Internal (compilerFor, streamFirstResultSet)
import Hmssql.Query.Types (ResponseReader (..))
import Hmssql.Tds.Token (ReturnValue)
import Mars.Harness (describeMars)
import Model.Machine
import TestDb

-- | Set up once per spec item: the monitor connection, the real table, and
-- the name of the other database 'Use' switches to.
data Shared = Shared
  { shConnectInfo :: ConnectInfo
    -- ^ For the connection under test: the test configuration, with no
    -- session setup by default ('defaultSessionSetup'), or 'nonEmptySetup'
    -- with @HMSSQL_TEST_SESSION_SETUP=arithabort@ (which covers the reset
    -- batch).
  , shMonitor :: Connection -- ^ watches and kills the session under test
  , shTestDb :: Text
  , shScratchDb :: Text
    -- ^ The companion database; empty on Azure, where 'Use' is never
    -- generated.
  , shAzure :: Bool
  , shReal :: Text -- ^ the real table, fully qualified
  , shProc :: Text -- ^ the procedure, fully qualified
  , shSetupEmpty :: Bool
  , shMars :: Bool -- ^ 'connectMars' for the connection under test
  , shCurrent :: IORef (Maybe Env) -- ^ released before the next one starts
  }

cfgFor :: Shared -> Cfg
cfgFor sh = Cfg
  { cfgSetupEmpty = shSetupEmpty sh
  , cfgTestDb = shTestDb sh
  , cfgScratchDb = shScratchDb sh
  , cfgAzure = shAzure sh
  , cfgMars = shMars sh
  }

-- | The procedure 'CallProc' calls, as a fixture: for the specs using
-- 'withShared'.
withModelFixture :: SpecWith a -> SpecWith a
withModelFixture = withFixture "model_connection_proc" procFixture

-- | The procedure 'CallProc' calls; its SETs revert when it returns.
procFixture :: [Text]
procFixture =
  [ "DROP PROCEDURE IF EXISTS dbo.hmssql_model_proc"
  , "CREATE PROCEDURE dbo.hmssql_model_proc @a int, @b int OUTPUT, @ctx nvarchar(100) OUTPUT AS \
    \BEGIN \
    \  SET NOCOUNT ON; SET XACT_ABORT ON; SET TEXTSIZE 10; \
    \  SET @b = @a + 1; \
    \  SET @ctx = CAST(SESSION_CONTEXT(N'hm_k') AS nvarchar(100)); \
    \  SELECT CAST(@@TRANCOUNT AS int) AS tc; \
    \  RETURN @a * 3; \
    \END"
  ]

-- | The 'Shared' setup for one spec item, for a connection under test
-- with MARS or without (whatever @HMSSQL_TEST_MARS@ says); the spec must
-- be wrapped in 'withModelFixture'.
withShared :: Bool -> (Shared -> IO a) -> IO a
withShared mars act = do
  azure <- testServerIsAzure
  -- The other database is only for 'Use', which Azure SQL Database (no
  -- USE) never generates.  The model creates nothing there.
  scratchDb <- if azure then pure "" else connectDatabase <$> companionConnectInfo
  ci <- defaultTestConnectInfo
  testDb <- testDatabaseName
  empty <- null <$> testSessionSetup
  name <- uniqueName "hmssql_model"
  let real = quoteName testDb <> ".dbo." <> quoteName name
  withTestDb $ \mon -> do
    void $ execute mon (rawSql ("CREATE TABLE " <> real <> " (id int NOT NULL PRIMARY KEY, v int NOT NULL)"))
    cur <- newIORef Nothing
    let sh = Shared
          { shConnectInfo = ci { connectSessionSetup = if empty then [] else nonEmptySetup, connectMars = mars }
          , shMonitor = mon
          , shTestDb = testDb
          , shScratchDb = scratchDb
          , shAzure = azure
          , shReal = real
          , shProc = quoteName testDb <> ".dbo.hmssql_model_proc"
          , shSetupEmpty = empty
          , shMars = mars
          , shCurrent = cur
          }
    act sh `finally` do
      readIORef cur >>= mapM_ releaseEnv
      void $ execute mon (rawSql ("DROP TABLE IF EXISTS " <> real))

------------------------------------------------------------------------------
-- The executor

data Job
  = Run (IO ())
  | Begin (Maybe IsolationLevel) (MVar (Maybe SomeException)) (MVar (Either SomeException ()))
    -- ^ reports on the first MVar once the body runs (or why it didn't),
    -- and the result of the whole 'withTransaction' on the second
  | End EndMode

-- | What a 'TxEnd Throw' body throws.
data BodyAbort = BodyAbort
  deriving stock (Show)

instance Exception BodyAbort

-- | 'StreamPull', 'StreamDrain' or 'StreamCancel' with no stream in the
-- slot (its 'queryS' failed).
data NoStreamOpened = NoStreamOpened
  deriving stock (Show)

instance Exception NoStreamOpened

-- | Our interruption of a WAITFOR.  An asynchronous exception, like
-- 'System.Timeout.timeout's: hmssql tells interruptions from failures by
-- type, and marks the connection broken after a synchronous-typed exception
-- thrown into a read.  (An asynchronous one landing in a send, or in the
-- drain of a cancelled response, breaks it too; 'Waitfor' interrupts only
-- once the request is sent and the server is waiting.)
newtype Interrupted = Interrupted Int
  deriving stock (Eq, Show)

instance Exception Interrupted where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

data Env = Env
  { eShared :: Shared
  , eConn :: IORef Connection
    -- ^ The current handle: 'Release' replaces it with a renewed one.
  , eSpid :: Int32
  , eConnectionId :: Text
    -- ^ Its physical connection's @connection_id@ (a reset keeps it):
    -- with the session id, which the server hands to another session
    -- once this one is gone, it names this session.  (Not its
    -- @connect_time@, whose 3 ms tick a recycled id can land in.)
  , eInfos :: IORef [(ThreadId, ServerMessage)] -- ^ newest first, by reading thread
  , eStreams :: IORef [(Int, (Stream (Of Row) IO (), ResponseReader))]
    -- ^ By slot: what is left of the stream, and its response's reader.
  , eJobs :: MVar Job
  , eFinals :: IORef [MVar (Either SomeException ())]
  , eExecutor :: ThreadId
  , ePoisoned :: IORef Bool -- ^ an operation hung; don't wait for more
  , eDirect :: Bool
    -- ^ Run operations on the calling thread instead of the executor (for
    -- concurrent use; no withTransaction then).
  }

-- | A fresh connection (releasing the previous one).  @direct@: see 'eDirect'.
newEnv :: Bool -> Shared -> IO Env
newEnv direct sh = do
  readIORef (shCurrent sh) >>= mapM_ releaseEnv
  writeIORef (shCurrent sh) Nothing
  infos <- newIORef []
  let onInfo m = myThreadId >>= \t -> atomicModifyIORef' infos (\ms -> ((t, m) : ms, ()))
  conn <- connect (shConnectInfo sh) { connectOnInfoMessage = onInfo }
  flip onException (close conn) $ do
    (spid, connectTime) <- query1 conn
      "SELECT CAST(@@SPID AS int), CONVERT(nvarchar(36), connection_id) FROM sys.dm_exec_connections WHERE session_id = @@SPID AND parent_connection_id IS NULL"
    void $ execute conn (rawSql ("DELETE FROM " <> shReal sh))
    writeIORef infos []
    jobs <- newEmptyMVar
    -- A stray 'End' outside any withTransaction returns or throws; keep
    -- serving.  'releaseEnv' (ThreadKilled), or nobody left to send jobs
    -- (BlockedIndefinitelyOnMVar), ends the thread: it holds the connection.
    connRef <- newIORef conn
    let executor = try (serve connRef jobs) >>= \case
          Left e
            | Just (_ :: SomeAsyncException) <- fromException e -> pure ()
            | Just BlockedIndefinitelyOnMVar <- fromException e -> pure ()
          _ -> executor
    tid <- forkIO executor
    env <- Env sh connRef spid connectTime infos
      <$> newIORef []
      <*> pure jobs
      <*> newIORef []
      <*> pure tid
      <*> newIORef False
      <*> pure direct
    writeIORef (shCurrent sh) (Just env)
    pure env

-- | The executor loop, which is also the body of each 'withTransaction'.
-- Returns when told to commit; throws 'BodyAbort' when told to throw.
-- ('Release' never runs inside a body, so a body's handle stays current.)
serve :: IORef Connection -> MVar Job -> IO ()
serve connRef jobs = takeMVar jobs >>= \case
  Run io -> io >> serve connRef jobs
  Begin lvl started final -> do
    conn <- readIORef connRef
    let txFn = maybe withTransaction withTransactionLevel lvl conn
    ran <- newIORef False
    r <- try $ txFn $ writeIORef ran True >> putMVar started Nothing >> serve connRef jobs
    trace ("  withTransaction returned " ++ either (\e -> show (e :: SomeException)) (const "()") r)
    -- 'releaseEnv' killed us inside the body: stop.
    case r of
      Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      _ -> pure ()
    readIORef ran >>= \case
      True -> putMVar final r
      False -> putMVar started $ Just $ case r of
        Left e -> e
        Right () -> toException (userError "withTransaction returned without running its body")
    serve connRef jobs
  End Commit -> trace "  body returns" >> pure ()
  End Throw -> trace "  body throws" >> throwIO BodyAbort

releaseEnv :: Env -> IO ()
releaseEnv env = do
  trace "release"
  (readIORef (eConn env) >>= close) `catch` \(_ :: SomeException) -> pure ()
  killThread (eExecutor env)

------------------------------------------------------------------------------
-- Running operations

data Result = Result
  { rOutcome :: Outcome
  , rInfos :: [Int32] -- ^ INFO numbers, except 3621 ("The statement has been terminated.")
  , rInTransaction :: Bool
  , rResetPending :: Bool
  , rClientChecked :: Bool
    -- ^ Whether 'rInTransaction' and 'rResetPending' belong to this
    -- operation (not when other threads use the connection too).
  , rBrokenBefore :: Bool -- ^ the connection was marked broken before the operation
  , rBroken :: Bool -- ^ and after it
  }
  deriving stock (Show)

hangLimit :: Int
hangLimit = 15_000_000

-- | Run an operation (on the executor thread) and report what happened.
runOp :: Env -> Op -> IO Result
runOp env op = do
  trace ("> " ++ show op)
  me <- myThreadId
  -- Forget earlier messages of this thread (the executor's, if not direct).
  let mine t = if eDirect env then t == me else True
  atomicModifyIORef' (eInfos env) (\ms -> (filter (not . mine . fst) ms, ()))
  poisoned <- readIORef (ePoisoned env)
  brokenBefore <- isBroken
  out <- if poisoned then pure (OFail FHang) else case op of
    _ | eDirect env -> try (perform env op) >>= either failed pure
    TxBegin lvl -> do
      started <- newEmptyMVar
      final <- newEmptyMVar
      putMVar (eJobs env) (Begin lvl started final)
      waitFor (takeMVar started) >>= \case
        Nothing -> pure (OFail FHang)
        Just Nothing -> OUnit <$ modifyIORef' (eFinals env) (final :)
        Just (Just e) -> failed e
    TxEnd mode -> readIORef (eFinals env) >>= \case
      [] -> pure (OFail (FOther "no withTransaction"))
      final : rest -> do
        writeIORef (eFinals env) rest
        putMVar (eJobs env) (End mode)
        waitFor (takeMVar final) >>= \case
          Nothing -> pure (OFail FHang)
          Just (Right ()) -> pure OUnit
          Just (Left e) -> failed e
    _ -> do
      reply <- newEmptyMVar
      putMVar (eJobs env) (Run (try (perform env op) >>= putMVar reply))
      waitFor (takeMVar reply) >>= \case
        Nothing -> pure (OFail FHang)
        Just (Right o) -> pure o
        Just (Left e) -> failed e
  infos <- atomicModifyIORef' (eInfos env) $ \ms ->
    (filter (not . mine . fst) ms, reverse [m | (t, m) <- ms, mine t])
  conn <- readIORef (eConn env)
  inTx <- inTransaction conn
  pending <- readIORef (connResetPending conn)
  broken <- isBroken
  trace ("< " ++ show out ++ (if broken && not brokenBefore then " (now broken)" else ""))
  pure Result
    { rOutcome = out
    , rInfos = filter (/= 3621) (map msgNumber infos)
    , rInTransaction = inTx
    , rResetPending = pending
    , rClientChecked = not (eDirect env)
    , rBrokenBefore = brokenBefore
    , rBroken = broken
    }
  where
    isBroken = readIORef (eConn env) >>= \conn -> isJust <$> readIORef (connBroken conn)
    waitFor act = do
      r <- timeoutInSlices hangLimit act
      when (null r) $ do
        writeIORef (ePoisoned env) True
        -- What the session is doing, on both sides: printed whether or not
        -- the run traces, since a hang is rare and the failure report only
        -- names the operation.
        let ident = SessionIdentity (eSpid env) (eConnectionId env)
        server <- either (\e -> "not known: " ++ show (e :: SomeException)) id <$> try (describeSession ident)
        conn <- readIORef (eConn env)
        client <- if isJust (connMars conn) then ("\n  client: " ++) <$> describeMars conn else pure ""
        executor <- threadStatus (eExecutor env)
        withMVar traceLock $ \_ -> hPutStrLn stderr $
          "Model: " ++ show op ++ " had no answer in " ++ show (hangLimit `div` 1_000_000) ++ " s; the executor, "
            ++ show (eExecutor env) ++ ", is " ++ show executor ++ "\n  server: " ++ server ++ client
      pure r
    failed e = OFail <$> classifyTraced e

-- | Log an exception (with @HMSSQL_MODEL_TRACE=1@) and classify it.
classifyTraced :: SomeException -> IO Failure
classifyTraced e = classify e <$ trace ("! " ++ show e)

classify :: SomeException -> Failure
classify e
  | Just (err :: SqlServerError) <- fromException e = FSql (sqlErrorNumber err)
  | Just ResultAbandoned <- fromException e = FAbandoned
  | Just (ConnectionClosedBy ClosedByClient) <- fromException e = FClosedByClient
  | Just (ConnectionClosedBy _) <- fromException e = FClosed
  | Just (ConnectionBroken _) <- fromException e = FBroken
  | Just TransactionAlreadyActive <- fromException e = FTxActive
  | Just TransactionEndedEarly <- fromException e = FTxEndedEarly
  | Just TransactionStillOpen <- fromException e = FTxStillOpen
  | Just (TransactionRequestsActive _) <- fromException e = FTxRequestsActive
  | Just BodyAbort <- fromException e = FBodyAbort
  | Just NoStreamOpened <- fromException e = FNoStream
  | Just ConnectionReleased <- fromException e = FReleased
  | otherwise = FOther (show e)

tableSql :: Env -> Tbl -> Text
tableSql env = \case
  T1 -> "#hm1"
  T2 -> "#hm2"
  Real -> shReal (eShared env)

-- | The parameter of an 'Rpc' statement that has none of its own: a query
-- without parameters is sent as a batch, so this one (declared, unused)
-- is what sends it through @sp_executesql@.
dummy :: Only Int32
dummy = Only 0

-- | Runs on the executor thread, through the current handle.
perform :: Env -> Op -> IO Outcome
perform env op = readIORef (eConn env) >>= \conn -> performOn env conn op

performOn :: Env -> Connection -> Op -> IO Outcome
performOn env conn = \case
  CreateTemp via t ->
    let n = tableSql env t
     in unit $ run via $
          "IF OBJECT_ID(N'tempdb.." <> n <> "') IS NULL CREATE TABLE " <> n
            <> " (id int NOT NULL PRIMARY KEY, v int NOT NULL)"
  DropTemp via t -> unit $ run via ("DROP TABLE IF EXISTS " <> tableSql env t)
  Insert via t i v -> OCount <$> case via of
    Batch -> execute conn (rawSql ("INSERT INTO " <> tableSql env t <> " (id, v) VALUES (" <> lit i <> ", " <> lit v <> ")"))
    Rpc -> execute conn (mkQuery ("INSERT INTO " <> tableSql env t <> " (id, v) VALUES (@p1, @p2)") (i, v))
  UpdateRows via t d -> OCount <$> case via of
    Batch -> execute conn (rawSql ("UPDATE " <> tableSql env t <> " SET v = v + " <> lit d))
    Rpc -> execute conn (mkQuery ("UPDATE " <> tableSql env t <> " SET v = v + @p1") (Only d))
  Delete via t k -> OCount <$> case via of
    Batch -> execute conn (rawSql ("DELETE FROM " <> tableSql env t <> " WHERE id = " <> lit k))
    Rpc -> execute conn (mkQuery ("DELETE FROM " <> tableSql env t <> " WHERE id = @p1") (Only k))
  ExecMany stmts -> OCounts <$> executeStatements conn (map manySql stmts)
  Select via t -> ORows <$> case via of
    Batch -> query conn (rawSql (selectSql t))
    Rpc -> query conn (mkQuery (selectSql t) dummy)
  Multi via ts -> do
    let sql = T.intercalate "; " (map selectSql ts)
    sets <- case via of
      Batch -> queryMulti conn (rawSql sql)
      Rpc -> queryMulti conn (mkQuery sql dummy)
    OSets <$> mapM (mapM pair . resultRows) sets
  Results ts ->
    OSets <$> queryResultSets (traverse (const resultSet) ts) conn (rawSql (T.intercalate "; " (map selectSql ts)))
  -- 'queryS', with the reader kept.
  StreamOpen slot via t -> do
    req <- queryRequest conn $ case via of
      Batch -> rawSql (selectSql t)
      Rpc -> mkQuery (selectSql t) dummy
    resp <- startResponse conn req
    when (shMars (eShared env)) $ awaitArrival resp
    let s = streamFirstResultSet (compilerFor rowDecoder) resp (drainResponse resp)
    OUnit <$ modifyIORef' (eStreams env) ((slot, (s, resp)) :)
  StreamPull slot n -> pull slot (Just n)
  StreamDrain slot -> pull slot Nothing
  StreamCancel slot -> lookup slot <$> readIORef (eStreams env) >>= \case
    Nothing -> throwIO NoStreamOpened
    Just (_, resp) -> OUnit <$ cancelResponse resp
  Set via opt -> unit $ run via (setSql opt)
  Use via db -> unit $ run via ("USE " <> quoteName (dbName db))
  SetCtx via tag -> unit $ case via of
    Batch -> execute conn (rawSql ("EXEC sp_set_session_context N'hm_k', N't" <> T.pack (show tag) <> "'"))
    Rpc -> execute conn (mkQuery "EXEC sp_set_session_context N'hm_k', @p1" (Only ("t" <> T.pack (show tag))))
  Tran via op -> unit $ run via (tranSql op)
  Api ApiBegin -> OUnit <$ begin conn
  Api ApiCommit -> OUnit <$ commit conn
  Api ApiRollback -> OUnit <$ rollback conn
  Raise via k tag -> unit $ run via (errSql k <> "; " <> ctxSql tag)
  Info via k -> unit $ run via $ case k of
    IPrint -> "PRINT N'hm print'"
    IRaise10 -> "RAISERROR(N'hm info', 10, 1)"
    IRaise0 -> "RAISERROR(N'hm info', 0, 1)"
    IPrintTwice -> "PRINT N'hm print'; RAISERROR(N'hm info', 10, 1)"
  CallProc a -> do
    let ps = [inParam "@a" a, outParam "@b" (0 :: Int32), outParam "@ctx" (Nothing :: Maybe Text)]
    ProcResult{..} <- callProcedure conn (shProc (eShared env)) ps
    (b, c) <- case procOutputValues of
      [rb, rc] -> (,) <$> decodeOrThrow rb <*> decodeOrThrow rc
      vs -> throwIO (userError ("expected two output values, got " ++ show (length vs)))
    rows <- mapM (mapM ints . resultRows) procResultSets
    pure (OProc procReturnStatus b c (concat rows))
  Reset -> OUnit <$ reset conn
  SpReset -> OUnit <$ callProcedure conn "sp_reset_connection" []
  Waitfor via tag ->
    fmap (maybe OInterrupted (const OUnit)) $
      interruptWhenWaiting env $ \marker ->
        run via ("/* " <> marker <> " */ WAITFOR DELAY '00:00:10'; " <> ctxSql tag)
  Cut via delayMs micros ->
    let sql = (if delayMs > 0 then "WAITFOR DELAY '00:00:00.00" <> T.pack (show delayMs) <> "'; " else "")
          <> "SELECT CAST(@@TRANCOUNT AS int), CAST(0 AS int)"
     in fmap (maybe OInterrupted ORows) $ timeout micros $ case via of
          Batch -> query conn (rawSql sql)
          Rpc -> query conn (mkQuery sql dummy)
  -- Only this session: a KILL of its id after the session had gone (the
  -- model wrongly taking it for alive) would end whichever session has
  -- the id now, perhaps another test run's.  Fails the sequence instead.
  Kill -> OUnit <$ execute (shMonitor (eShared env)) (mkQuery
    "DECLARE @kill nvarchar(40) = N'KILL ' + CAST(@p1 AS nvarchar(10)); \
    \IF EXISTS (SELECT 1 FROM sys.dm_exec_connections WHERE session_id = @p1 AND parent_connection_id IS NULL AND CONVERT(nvarchar(36), connection_id) = @p2) \
    \  EXEC (@kill) \
    \ELSE THROW 50001, N'model: the session to KILL is gone (its id may be another session''s now)', 1"
    (eSpid env, eConnectionId env))
  Fatal -> unit $ execute conn "RAISERROR(N'hm fatal', 20, 1) WITH LOG"
  Close -> OUnit <$ close conn
  -- Renewed however 'release' ends, even when 'renew' would refuse the
  -- connection, so that the model goes on to check what its requests throw.
  -- The stream in 'eStream' keeps the released handle.
  Release -> (OBool <$> release conn) `finally` (renewLease conn >>= writeIORef (eConn env))
  Check -> queryWith observedDecoder conn (rawSql (checkSql env)) >>= \case
    [o] -> pure (OState o)
    os -> throwIO (userError ("check: expected one row, got " ++ show (length os)))
  op -> throwIO (userError ("not an executor operation: " ++ show op))
  where
    unit act = OUnit <$ act
    run Batch sql = execute conn (rawSql sql)
    run Rpc sql = execute conn (mkQuery sql dummy)
    lit :: Int32 -> Text
    lit n = if n < 0 then "(" <> T.pack (show n) <> ")" else T.pack (show n)
    manySql = \case
      MInsert t i v -> mkQuery ("INSERT INTO " <> tableSql env t <> " (id, v) VALUES (@p1, @p2)") (i, v)
      MUpdate t d -> mkQuery ("UPDATE " <> tableSql env t <> " SET v = v + @p1") (Only d)
      MDelete t k -> mkQuery ("DELETE FROM " <> tableSql env t <> " WHERE id = @p1") (Only k)
    selectSql t = "SELECT id, v FROM " <> tableSql env t <> " ORDER BY id"
    ctxSql tag = "EXEC sp_set_session_context N'hm_k', N't" <> T.pack (show tag) <> "'"
    dbName = \case
      TestDb -> shTestDb (eShared env)
      ScratchDb -> shScratchDb (eShared env)
    pull :: Int -> Maybe Int -> IO Outcome
    pull slot limit = lookup slot <$> readIORef (eStreams env) >>= \case
      Nothing -> throwIO NoStreamOpened
      Just (s0, resp) -> do
        let keep s = modifyIORef' (eStreams env) (\ss -> (slot, (s, resp)) : filter ((/= slot) . fst) ss)
            go s acc k
              | Just 0 <- k = (reverse acc, False) <$ keep s
              | otherwise = S.next s >>= \case
                  -- Keep the finished stream: pulling it again must throw.
                  Left () -> (reverse acc, True) <$ keep s
                  Right (r, rest) -> go rest (r : acc) (subtract 1 <$> k)
        uncurry OPulled <$> go s0 [] limit
    pair row = case sqlRowValues row of
      [SqlInt32 a, SqlInt32 b] -> pure (a, b)
      vs -> throwIO (userError ("expected two int columns, got " ++ show vs))
    ints row = mapM (\case SqlInt32 x -> pure x; v -> throwIO (userError ("expected int, got " ++ show v))) (sqlRowValues row)
    decodeOrThrow :: FromSqlField a => ReturnValue -> IO a
    decodeOrThrow = either throwIO pure . decodeReturnValue

-- | Wait (up to 10 s) until the last packet of a response on an SMP
-- session has been received (queued for it by the reader thread), so that
-- its statement is over on the server.
awaitArrival :: ResponseReader -> IO ()
awaitArrival resp = forM_ (sessSmp (arSession ar)) $ \smp ->
  let go k = do
        arrived <- (> arEomBase ar) <$> readTVarIO (linkEoms (smpLink smp))
        unless (arrived || k <= 0) $ threadDelay 200 >> go (k - 1)
   in go (50_000 :: Int)
  where
    ar = respActive resp

------------------------------------------------------------------------------
-- SQL

setSql :: SetOpt -> Text
setSql = \case
  SetNoCount b -> "SET NOCOUNT " <> onOff b
  SetXactAbort b -> "SET XACT_ABORT " <> onOff b
  SetArithAbort b -> "SET ARITHABORT " <> onOff b
  SetAnsiNulls b -> "SET ANSI_NULLS " <> onOff b
  SetQuotedId b -> "SET QUOTED_IDENTIFIER " <> onOff b
  SetTextSize n -> "SET TEXTSIZE " <> T.pack (show n)
  SetLanguage l -> "SET LANGUAGE " <> langName l
  SetDateFormat f -> "SET DATEFORMAT " <> f
  SetDateFirst n -> "SET DATEFIRST " <> T.pack (show n)
  SetLockTimeout n -> "SET LOCK_TIMEOUT " <> T.pack (show n)
  SetIsolation l -> "SET TRANSACTION ISOLATION LEVEL " <> case l of
    ReadUncommitted -> "READ UNCOMMITTED"
    ReadCommitted -> "READ COMMITTED"
    RepeatableRead -> "REPEATABLE READ"
    Serializable -> "SERIALIZABLE"
    Snapshot -> "SNAPSHOT"
  where
    onOff b = if b then "ON" else "OFF"

tranSql :: TranOp -> Text
tranSql = \case
  TBegin -> "BEGIN TRANSACTION"
  TCommit -> "COMMIT TRANSACTION"
  TRollback -> "ROLLBACK TRANSACTION"
  TSave n -> "SAVE TRANSACTION " <> n
  TRollbackTo n -> "ROLLBACK TRANSACTION " <> n

errSql :: ErrKind -> Text
errSql = \case
  ERaise16 -> "RAISERROR(N'hm error', 16, 1)"
  ERaise18 -> "RAISERROR(N'hm error', 18, 1)"
  EThrow -> "THROW 50001, N'hm throw', 1"
  EConvert -> "SELECT CAST('x' AS int)"
  EDivZero -> "SELECT 1/0"
  EMissing -> "SELECT * FROM #hm_missing"
  ETryCatch -> "BEGIN TRY THROW 50001, N'hm caught', 1 END TRY BEGIN CATCH END CATCH"
  ERollbackNoSp -> "ROLLBACK TRANSACTION hm_nosuch"

-- | One row describing the session (see 'Observed').
checkSql :: Env -> Text
checkSql env =
  "DECLARE @xs int = XACT_STATE(), @t1 nvarchar(max), @t2 nvarchar(max), @r nvarchar(max); \
  \IF OBJECT_ID(N'tempdb..#hm1') IS NOT NULL SELECT @t1 = " <> agg <> " FROM #hm1; \
  \IF OBJECT_ID(N'tempdb..#hm2') IS NOT NULL SELECT @t2 = " <> agg <> " FROM #hm2; \
  \SELECT @r = " <> agg <> " FROM " <> shReal (eShared env) <> "; \
  \SELECT CAST(@@TRANCOUNT AS int), @xs, CAST(@@OPTIONS & " <> T.pack (show optionsMask) <> " AS int), \
  \  CAST(@@TEXTSIZE AS int), CAST(@@LANGUAGE AS nvarchar(128)), CAST(s.date_format AS nvarchar(10)), \
  \  CAST(s.date_first AS int), CAST(@@LOCK_TIMEOUT AS int), CAST(s.transaction_isolation_level AS int), \
  \  CAST(DB_NAME() AS nvarchar(128)), CAST(SESSION_CONTEXT(N'hm_k') AS nvarchar(100)), @t1, @t2, @r \
  \FROM sys.dm_exec_sessions AS s WHERE s.session_id = @@SPID"
  where
    agg = "ISNULL(STRING_AGG(CONCAT(id, N':', v), N',') WITHIN GROUP (ORDER BY id), N'')"

observedDecoder :: RowDecoder Observed
observedDecoder = Observed
  <$> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f <*> f
  where
    f :: FromSqlField a => RowDecoder a
    f = singleField fieldDecoder

------------------------------------------------------------------------------
-- Interrupting a WAITFOR

-- | Run the action, interrupting it (as 'System.Timeout.timeout' would) once
-- the server shows the session waiting in a WAITFOR of a batch containing
-- the marker passed to the action, so the interruption always lands after
-- that request was sent, while its response is awaited: a read
-- interruption, which must leave the connection usable.  (Matching the
-- text matters: an earlier WAITFOR, cancelled when it was interrupted, can
-- still show for a moment, while this request's session setup batch runs
-- after a reset.)  Gives up waiting after 10 s.
interruptWhenWaiting :: Env -> (Text -> IO a) -> IO (Maybe a)
interruptWhenWaiting env act = do
  me <- myThreadId
  n <- atomicModifyIORef' interruptCounter (\i -> (i + 1, i))
  let ex = Interrupted n
      marker = "hm-wait-" <> T.pack (show n)
      watcher = poll (5000 :: Int) `catch` \(e :: SomeException) -> case fromException e of
        Just (_ :: AsyncException) -> pure ()
        Nothing -> throwTo me ex
      poll k = do
        Only waiting <- query1 (shMonitor (eShared env)) $ mkQuery
          "SELECT CAST(COUNT(*) AS int) FROM sys.dm_exec_requests AS r \
          \CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t \
          \WHERE r.session_id = @p1 AND r.wait_type = N'WAITFOR' AND t.text LIKE N'%' + @p2 + N' %'"
          (eSpid env, marker)
        if (waiting :: Int32) > 0 || k <= 0
          then throwTo me ex
          else threadDelay 2000 >> poll (k - 1)
  handleJust (\e -> if e == ex then Just () else Nothing) (\_ -> pure Nothing) $
    bracket (forkIOWithUnmask (\unmask -> unmask watcher)) (uninterruptibleMask_ . killThread) (\_ -> Just <$> act marker)

-- | With @HMSSQL_MODEL_TRACE=1@, log each operation and its outcome to stderr.
trace :: String -> IO ()
trace msg = when tracing $ withMVar traceLock $ \_ -> hPutStrLn stderr msg

traceLock :: MVar ()
traceLock = unsafePerformIO (newMVar ())
{-# NOINLINE traceLock #-}

tracing :: Bool
tracing = unsafePerformIO (maybe False (== "1") <$> lookupEnv "HMSSQL_MODEL_TRACE")
{-# NOINLINE tracing #-}

interruptCounter :: IORef Int
interruptCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE interruptCounter #-}
