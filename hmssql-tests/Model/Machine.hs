{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}

-- | A pure model of one 'Hmssql.Connection' and its server session, for the
-- state-machine tests in "Model.ConnectionSpec" and "Model.ParallelSpec".
--
-- The model predicts what the server's session looks like after each
-- operation (@\@\@TRANCOUNT@, SET options, the current database,
-- @SESSION_CONTEXT@, the contents of two @#temp@ tables and a real table),
-- what hmssql believes (whether a transaction is active, whether a reset is
-- pending), and what each operation returns or throws.
--
-- The SQL Server semantics were measured on SQL Server 2025 (17.0):
--
-- * Errors: RAISERROR only fails its statement, even under XACT_ABORT.
--   THROW and a missing object (208) abort the batch; under XACT_ABORT they
--   also roll the transaction back.  A duplicate key (2627), divide by zero
--   (8134), a savepoint that doesn't exist (6401) and COMMIT / ROLLBACK
--   without a transaction (3902 / 3903) only fail their statement, unless
--   XACT_ABORT is on, which aborts the batch and rolls back.  A conversion
--   error (245) aborts the batch and rolls back, XACT_ABORT or not.  An
--   error caught by TRY/CATCH under XACT_ABORT dooms the transaction: the
--   batch goes on, and at its end the server rolls back with error 3998.
-- * ROLLBACK TRAN savepoint rolls back to the newest savepoint of that
--   name, and forgets it and every newer one.
-- * Inside @sp_executesql@ (an RPC), SET options and the isolation level
--   revert when it returns, and a @#temp@ table created there is dropped;
--   transactions, savepoints, SESSION_CONTEXT, DROP TABLE of an outer
--   @#temp@ table and (unlike in @EXEC sp_executesql@ inside a batch) USE
--   persist.  If the transaction count changed, the server adds error 266
--   at the end.
-- * SET LANGUAGE also sets DATEFORMAT and DATEFIRST; SET TEXTSIZE 0 means 4096.
-- * The RESETCONNECTION bit leaves the isolation level as it is;
--   @sp_reset_connection@ sets READ COMMITTED.  But right after
--   @sp_reset_connection@, a request carrying the RESETCONNECTION bit
--   brings back the level from before it (see 'mSpResetLevel').  Azure SQL
--   Database ('cfgAzure') sets READ COMMITTED on either reset.
-- * An Attention that cancels a running statement rolls back the
--   transaction under XACT_ABORT, like any cancel.
--
-- What hmssql does is taken from its documentation: 'reset' applies to the
-- next request (with a session setup, one batch that re-runs it goes
-- first); 'begin' and 'withTransaction' begin with a Transaction
-- Manager request (TM_BEGIN_XACT, which carries a pending reset like any
-- request); 'withTransaction' refuses to start inside a transaction, sends
-- its begin as a request of its own before the body, before COMMIT checks
-- that its own transaction is still the open one and that no reset is
-- pending, and after it rolls everything back if a nested transaction is
-- still open ('TransactionStillOpen'); 'withTransactionLevel' sets the
-- level in the begin request, and READ COMMITTED on every exit; an
-- interrupted read sends the Attention at once and leaves the connection
-- usable; an interruption at an arbitrary point (see 'Cut') may also land
-- in a send, or in the drain of a cancelled response, and then breaks the
-- connection.  'release' finishes the response (cancelling a
-- statement still running), marks a reset pending, and carries it out at
-- once (one request) if a transaction is open, so the transaction is rolled
-- back then; it answers 'False' for a closed or broken connection, sending
-- nothing, and the handle it was given is stale afterwards, streams opened
-- through it included ('ConnectionReleased').
--
-- The model has a set of streams, each in a slot of its own ('mStreams').
-- Without MARS ('cfgMars') at most one is live: a request abandons it.  On
-- a MARS connection (docs/dev/design.md "MARS: several responses on one connection") several are, each on an SMP session of
-- its own, read, read to its end or cancelled ('cancelResponse')
-- independently, and a request leaves them open, except that:
--
-- * a request that carries a pending reset cancels every open stream
--   first, as do 'release', 'rollback' and the cleanup of a
--   'withTransaction' that fails (and without MARS the next request);
-- * a stream not read to its end (reading its last row is not enough) and
--   not cancelled is /busy/: 'begin', 'withTransaction' (at its
--   begin, and at its commit, which then rolls back) and
--   'commit' (which leaves the transaction open) throw
--   'TransactionRequestsActive', sending nothing;
-- * the server rolls back a transaction that a batch or an
--   @sp_executesql@ call began at @\@\@TRANCOUNT@ 0 and left open, with
--   error 3997 (after 266 for @sp_executesql@); inside a transaction begun
--   by a Transaction Manager request, @BEGIN TRANSACTION@ nests as without
--   MARS, and COMMIT, ROLLBACK and savepoints are as without MARS (SQL
--   Server 2025);
-- * a stream whose statement rolled the transaction back (an error under
--   XACT_ABORT) holds the rollback's ENVCHANGE until it is read: until
--   then hmssql sends the old transaction descriptor, and the server
--   refuses every request with error 3971 ('staleTx').
--
-- The rest (SET options, @#temp@ tables, the database, the isolation
-- level, resets) belongs to the one SQL session, as without MARS.  On a
-- MARS connection the runner waits, after opening a stream, until its
-- response has all arrived: the statement is over on the server then, so
-- what the next request finds on the server doesn't depend on timing, and
-- a cancelled stream is read to its end locally (no Attention, which
-- under XACT_ABORT would roll the transaction back if it reached the
-- server while the statement ran).
module Model.Machine
  ( -- * Operations
    Op (..)
  , Tbl (..)
  , Via (..)
  , Db (..)
  , Lang (..)
  , SetOpt (..)
  , TranOp (..)
  , ApiOp (..)
  , ErrKind (..)
  , InfoKind (..)
  , EndMode (..)
  , ManyStmt (..)
  , Row
    -- * Results
  , Outcome (..)
  , Failure (..)
  , Observed (..)
    -- * Model
  , Cfg (..)
  , Model (..)
  , Opts (..)
  , Tables (..)
  , Frame (..)
  , StreamSt (..)
  , Life (..)
  , usable
  , initialModel
  , Expect (..)
  , Accept (..)
  , step
  , brokenExpect
  , valid
  , clientInTransaction
  , genOp
  , OpWeights (..)
  , defaultWeights
  , parallelWeights
    -- * Session setup
  , nonEmptySetup
    -- * Rendering
  , renderRows
  , langName
  , isolationNumber
  , optionsMask
  ) where

import Control.Applicative ((<|>))
import Data.Int (Int32, Int64)
import Data.Kind (Type)
import Data.List (sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Hmssql (IsolationLevel (..))

------------------------------------------------------------------------------
-- Operations

-- | The two @#temp@ tables (@#hm1@, @#hm2@) and the real table.  All have
-- columns @(id int PRIMARY KEY, v int NOT NULL)@.
data Tbl = T1 | T2 | Real
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | How a statement is sent: as a plain SQL batch (a query with no
-- parameters, 'Hmssql.rawSql') or through @sp_executesql@ (the same text
-- with a parameter, 'Hmssql.mkQuery'; an otherwise parameterless statement
-- carries an unused one, since a query without parameters is a batch).
data Via = Batch | Rpc
  deriving stock (Eq, Show, Enum, Bounded)

-- | The login database (the shared test database) or another one (the
-- companion database, 'TestConfig.companionConnectInfo').
data Db = TestDb | ScratchDb
  deriving stock (Eq, Show, Enum, Bounded)

data Lang = UsEnglish | Deutsch | British
  deriving stock (Eq, Show, Enum, Bounded)

type Row = (Int32, Int32)

data SetOpt
  = SetNoCount Bool
  | SetXactAbort Bool
  | SetArithAbort Bool
  | SetAnsiNulls Bool
  | SetQuotedId Bool
  | SetTextSize Int32
  | SetLanguage Lang
  | SetDateFormat Text
  | SetDateFirst Int32
  | SetLockTimeout Int32
  | SetIsolation IsolationLevel
  deriving stock (Eq, Show)

-- | Transaction statements in SQL.
data TranOp = TBegin | TCommit | TRollback | TSave Text | TRollbackTo Text
  deriving stock (Eq, Show)

-- | 'begin', 'commit', 'rollback'.
data ApiOp = ApiBegin | ApiCommit | ApiRollback
  deriving stock (Eq, Show, Enum, Bounded)

-- | Failing statements, each followed in its batch by a statement that sets
-- SESSION_CONTEXT (so the model can tell whether the batch went on).
data ErrKind
  = ERaise16 -- ^ @RAISERROR(..., 16, 1)@
  | ERaise18 -- ^ @RAISERROR(..., 18, 1)@
  | EThrow -- ^ @THROW 50001, ...@
  | EConvert -- ^ @SELECT CAST('x' AS int)@ (245)
  | EDivZero -- ^ @SELECT 1/0@ (8134)
  | EMissing -- ^ @SELECT * FROM #hm_missing@ (208)
  | ETryCatch -- ^ @THROW@ caught by TRY/CATCH
  | ERollbackNoSp -- ^ @ROLLBACK TRAN hm_nosuch@ (6401, or 3903 without a transaction)
  deriving stock (Eq, Show, Enum, Bounded)

-- | Statements that send INFO messages.
data InfoKind = IPrint | IRaise10 | IRaise0 | IPrintTwice
  deriving stock (Eq, Show, Enum, Bounded)

-- | A statement of an 'ExecMany' (each is its own @sp_executesql@ call).
data ManyStmt
  = MInsert Tbl Int32 Int32
  | MUpdate Tbl Int32
  | MDelete Tbl Int32
  deriving stock (Eq, Show)

-- | How a 'withTransaction' body ends: by returning, or by throwing.
data EndMode = Commit | Throw
  deriving stock (Eq, Show, Enum, Bounded)

data Op
  = CreateTemp Via Tbl -- ^ @IF OBJECT_ID(...) IS NULL CREATE TABLE@
  | DropTemp Via Tbl -- ^ @DROP TABLE IF EXISTS@
  | Insert Via Tbl Int32 Int32 -- ^ 'execute'; returns the row count
  | UpdateRows Via Tbl Int32 -- ^ @UPDATE t SET v = v + d@
  | Delete Via Tbl Int32 -- ^ @DELETE t WHERE id = k@
  | ExecMany [ManyStmt] -- ^ 'executeStatements'; returns the row counts
  | Select Via Tbl -- ^ 'query'
  | Multi Via [Tbl] -- ^ 'queryMulti'
  | Results [Tbl] -- ^ 'queryResultSets'
  | StreamOpen Int Via Tbl
    -- ^ 'queryS' (as 'startResponse' and a stream over its reader), not
    -- consumed yet, kept in this slot (a new one: 'mNextSlot')
  | StreamPull Int Int -- ^ pull up to n rows from the stream in this slot
  | StreamDrain Int -- ^ consume the rest of it
  | StreamCancel Int -- ^ 'cancelResponse' on its reader
  | Set Via SetOpt
  | Use Via Db
  | SetCtx Via Int -- ^ @sp_set_session_context N'hm_k', N't<n>'@
  | Tran Via TranOp
  | Api ApiOp
  | TxBegin (Maybe IsolationLevel) -- ^ enter 'withTransaction' / 'withTransactionLevel'
  | TxEnd EndMode -- ^ leave the innermost one
  | Raise Via ErrKind Int
  | Info Via InfoKind
  | CallProc Int32 -- ^ 'callProcedure' with output parameters
  | Reset -- ^ 'reset'
  | SpReset -- ^ @callProcedure conn "sp_reset_connection" []@
  | Waitfor Via Int -- ^ @WAITFOR DELAY@ interrupted while the server waits
  | Cut Via Int Int
    -- ^ A read-only query (a @WAITFOR DELAY@ of this many milliseconds, then
    -- @SELECT \@\@TRANCOUNT, 0@) under 'System.Timeout.timeout' of this
    -- many microseconds: interrupted at an arbitrary point, or not at all.
  | Kill -- ^ @KILL@ the session from another connection
  | Fatal -- ^ @RAISERROR(..., 20, 1) WITH LOG@
  | Close -- ^ 'close'
  | Release -- ^ 'release', then 'renew' (the runner uses the new handle from then on)
  | Check -- ^ read the session's state from the server
  deriving stock (Eq, Show)

------------------------------------------------------------------------------
-- Results

data Failure
  = FSql Int32 -- ^ 'SqlServerError' with this number
  | FAbandoned -- ^ 'ResultAbandoned'
  | FClosedByClient -- ^ @'ConnectionClosedBy' 'ClosedByClient'@
  | FClosed -- ^ 'ConnectionClosedBy' another reason
  | FBroken -- ^ 'ConnectionBroken'
  | FTxActive -- ^ 'TransactionAlreadyActive'
  | FTxEndedEarly -- ^ 'TransactionEndedEarly'
  | FTxStillOpen -- ^ 'TransactionStillOpen'
  | FTxRequestsActive -- ^ 'TransactionRequestsActive'
  | FBodyAbort -- ^ the exception the body threw
  | FHang -- ^ no answer within a minute
  | FNoStream -- ^ the runner has no stream in the slot (its 'queryS' failed)
  | FReleased -- ^ 'ConnectionReleased'
  | FOther String -- ^ anything else
  deriving stock (Eq, Show)

-- | What the server says about the session (see "Model.Runner", @checkSql@).
data Observed = Observed
  { obTranCount :: Int32
  , obXactState :: Int32
  , obOptions :: Int32 -- ^ @\@\@OPTIONS@ masked by 'optionsMask'
  , obTextSize :: Int32
  , obLanguage :: Text
  , obDateFormat :: Text
  , obDateFirst :: Int32
  , obLockTimeout :: Int32
  , obIsolation :: Int32
  , obDb :: Text
  , obCtx :: Maybe Text
  , obT1 :: Maybe Text -- ^ 'renderRows', or Nothing if the table doesn't exist
  , obT2 :: Maybe Text
  , obReal :: Text
  }
  deriving stock (Eq, Show)

data Outcome
  = OUnit
  | OCount Int64
  | OCounts [Int64]
  | ORows [Row]
  | OSets [[Row]]
  | OPulled [Row] Bool -- ^ rows pulled, and whether the stream ended
  | OProc (Maybe Int32) (Maybe Int32) (Maybe Text) [[Int32]]
    -- ^ return status, the two output parameters, the result set's rows
  | OState Observed
  | OInterrupted
  | OBool Bool -- ^ what 'release' returned
  | OFail Failure
  deriving stock (Eq, Show)

------------------------------------------------------------------------------
-- Model

data Cfg = Cfg
  { cfgSetupEmpty :: Bool
    -- ^ @connectSessionSetup = []@; otherwise it is 'nonEmptySetup'
  , cfgTestDb :: Text
  , cfgScratchDb :: Text
  , cfgAzure :: Bool
    -- ^ Azure SQL Database: no 'Use' (no USE there) and no 'Fatal' (no
    -- @sysadmin@) are generated, and a reset puts the isolation level back
    -- to READ COMMITTED.
  , cfgMars :: Bool -- ^ 'connectMars'
  }
  deriving stock (Eq, Show)

data Opts = Opts
  { noCount :: Bool
  , xactAbort :: Bool
  , arithAbort :: Bool
  , ansiNulls :: Bool
  , quotedId :: Bool
  , textSize :: Int32
  , language :: Lang
  , dateFormat :: Text
  , dateFirst :: Int32
  , lockTimeout :: Int32
  , isolation :: IsolationLevel
  }
  deriving stock (Eq, Show)

-- | After LOGIN7 (hmssql sets fODBC, so the ANSI options are on).
loginOpts :: Opts
loginOpts = Opts
  { noCount = False, xactAbort = False, arithAbort = False, ansiNulls = True, quotedId = True
  , textSize = -1, language = UsEnglish, dateFormat = "mdy", dateFirst = 7, lockTimeout = -1
  , isolation = ReadCommitted
  }

-- | The session setup the model's connection uses with
-- @HMSSQL_TEST_SESSION_SETUP=arithabort@ (what 'TestConfig.testSessionSetup'
-- gives then), to cover the reset batch: the opt-in 'defaultSessionSetup'
-- documents.
nonEmptySetup :: [Text]
nonEmptySetup = ["SET ARITHABORT ON"]

-- | After 'nonEmptySetup'.
setupOpts :: Opts
setupOpts = loginOpts { arithAbort = True }

data Tables = Tables
  { tT1 :: Maybe [Row] -- ^ sorted by id; Nothing if it doesn't exist
  , tT2 :: Maybe [Row]
  , tReal :: [Row]
  }
  deriving stock (Eq, Show)

-- | A 'withTransaction' in progress.
data Frame = Frame
  { fLevel :: Maybe IsolationLevel
    -- ^ 'withTransactionLevel': its COMMIT or ROLLBACK batch sets READ
    -- COMMITTED
  , fTx :: Int
    -- ^ The transaction it began ('mTxSerial'), standing for the
    -- transaction descriptor hmssql compares before COMMIT.
  , fUnsure :: Bool
    -- ^ Entered while the connection may have been broken
    -- ('AliveOrBroken'): the runner may have no 'withTransaction' to end,
    -- even once the model has the session dead ('Fatal').
  }
  deriving stock (Eq, Show)

data StreamSt
  = Live [Row] (Maybe Int32)
    -- ^ Rows still to come; or the error it will throw.  Busy until it is
    -- read to its end, even with no rows left.
  | Gone
    -- ^ Read to its end, failed, abandoned or cancelled: pulling throws
    -- 'ResultAbandoned'.
  | Stale
    -- ^ Opened through a handle 'release' has released since: pulling
    -- throws 'ConnectionReleased', whatever became of the connection.
  deriving stock (Eq, Show)

data Life
  = Alive
  | AliveOrBroken
    -- ^ After a 'Cut': either usable and in step with the model, or broken
    -- (the interruption landed in a send, or in the drain of a cancelled
    -- response), so every request throws 'ConnectionBroken'.  Which one,
    -- the runner reports ("Model.Commands" checks the operation against the
    -- model, or against 'brokenExpect').
  | Closed -- ^ 'close' was called
  | Dead -- ^ the session was killed (and maybe closed afterwards)
  deriving stock (Eq, Show)

-- | Not closed or killed (though maybe broken, 'AliveOrBroken').
usable :: Model v -> Bool
usable m = mLife m == Alive || mLife m == AliveOrBroken

data Model (v :: Type -> Type) = Model
  { mCfg :: Cfg
  , mTables :: Tables
  , mTranCount :: Int
  , mTxStart :: Tables -- ^ the tables at the outermost BEGIN
  , mSavepoints :: [(Text, Tables)] -- ^ newest first
  , mOpts :: Opts
  , mDb :: Db
  , mCtx :: Maybe Text
  , mResetPending :: Bool
  , mSpResetLevel :: Maybe IsolationLevel
    -- ^ Right after @sp_reset_connection@: the isolation level before it.
    -- If the very next request carries the RESETCONNECTION bit (itself, or
    -- the session setup batch before it), the server brings that level
    -- back (SQL Server 2025, measured with an empty setup).
  , mTxSerial :: Int
    -- ^ Counts the transactions begun (at @\@\@TRANCOUNT@ 0): a new one
    -- has a new transaction descriptor.
  , mFrames :: [Frame] -- ^ innermost first
  , mStreams :: [(Int, StreamSt)] -- ^ by slot, oldest first
  , mNextSlot :: Int -- ^ the slot for the next 'StreamOpen'
  , mUnsure :: [Int]
    -- ^ Slots of streams opened while the connection may have been broken
    -- ('AliveOrBroken'): the runner may have none there ('FNoStream').
  , mRolledBackBy :: [Int]
    -- ^ Slots of streams whose statement rolled back the transaction (an
    -- error under XACT_ABORT): until such a stream is read to its end or
    -- cancelled, hmssql hasn't seen the rollback ('staleTx').
  , mSynced :: Bool
    -- ^ No response is left unread, so hmssql's view of the transaction
    -- (from ENVCHANGE tokens) is current.  On a MARS connection, set by a
    -- request (which first reads the leading ENVCHANGE tokens of a
    -- response that carried a reset, and drains a response cancelled by
    -- an interruption), and by settling every open response.
  , mDrainsNext :: Bool
    -- ^ A 'Cut' refused for a stale transaction descriptor ('staleStep')
    -- may have been interrupted after its request went out, leaving its
    -- response (error 3971 and INFO 3926) abandoned, or not.  The next
    -- operation that drains abandoned responses ('drainsAbandoned') runs
    -- the INFO callback for it, so that operation's INFO messages aren't
    -- predicted, and the flag is clear after it (not after a 'Cut', which
    -- may be interrupted before its drain).
  , mLife :: Life
  }
  deriving stock (Show)

initialModel :: Cfg -> Model v
initialModel cfg = Model
  { mCfg = cfg
  , mTables = emptyTables
  , mTranCount = 0
  , mTxStart = emptyTables
  , mSavepoints = []
  , mOpts = if cfgSetupEmpty cfg then loginOpts else setupOpts
  , mDb = TestDb
  , mCtx = Nothing
  , mResetPending = False
  , mSpResetLevel = Nothing
  , mTxSerial = 0
  , mFrames = []
  , mStreams = []
  , mNextSlot = 0
  , mUnsure = []
  , mRolledBackBy = []
  , mSynced = True
  , mDrainsNext = False
  , mLife = Alive
  }
  where
    emptyTables = Tables Nothing Nothing []

-- | What hmssql's 'inTransaction' should say (once synced).  While a reset
-- is pending, the transaction it will roll back still counts.
clientInTransaction :: Model v -> Bool
clientInTransaction m = mTranCount m > 0

------------------------------------------------------------------------------
-- Expectations

data Accept
  = OneOf [Outcome]
  | AnyOutcome -- ^ anything but a hang or an unexpected exception type
  deriving stock (Eq, Show)

data Expect = Expect
  { exOutcome :: Accept
  , exInfos :: Maybe [Int32] -- ^ INFO message numbers, if they are predictable
  }
  deriving stock (Eq, Show)

exactly :: Outcome -> [Int32] -> Expect
exactly o infos = Expect (OneOf [o]) (Just infos)

------------------------------------------------------------------------------
-- Transactions and tables

getT :: Tbl -> Tables -> Maybe [Row]
getT t ts = case t of
  T1 -> tT1 ts
  T2 -> tT2 ts
  Real -> Just (tReal ts)

putT :: Tbl -> Maybe [Row] -> Tables -> Tables
putT t rows ts = case t of
  T1 -> ts { tT1 = rows }
  T2 -> ts { tT2 = rows }
  Real -> ts { tReal = maybe [] id rows }

begin :: Model v -> Model v
begin m
  | mTranCount m == 0 =
      m { mTranCount = 1, mTxStart = mTables m, mSavepoints = [], mTxSerial = mTxSerial m + 1 }
  | otherwise = m { mTranCount = mTranCount m + 1 }

rollbackAll :: Model v -> Model v
rollbackAll m
  | mTranCount m > 0 = m { mTranCount = 0, mTables = mTxStart m, mSavepoints = [] }
  | otherwise = m

marsOn :: Model v -> Bool
marsOn = cfgMars . mCfg

-- | Some stream has not been read to its end or cancelled.
busy :: Model v -> Bool
busy = any (streaming . snd) . mStreams

streamAt :: Int -> Model v -> Maybe StreamSt
streamAt s = lookup s . mStreams

setStream :: Int -> StreamSt -> Model v -> Model v
setStream s st m = m { mStreams = [(k, if k == s then st else x) | (k, x) <- mStreams m] }

-- | On a MARS connection, a stream still unread holds the ENVCHANGE of a
-- rollback of the transaction hmssql believes open: a request carries
-- that transaction's descriptor, and the server refuses it with error
-- 3971 (and INFO 3926), having done nothing.  A pending reset settles the
-- stream before the request, which then carries the reset.
staleTx :: Model v -> Bool
staleTx m = marsOn m && not (mResetPending m)
  && any (\s -> maybe False streaming (streamAt s m)) (mRolledBackBy m)

-- | Finish every unread response (abandoning or cancelling the live
-- streams; the ones here have all arrived, so nothing is sent).
settleAll :: Model v -> Model v
settleAll m = m
  { mStreams = [(k, if streaming st then Gone else st) | (k, st) <- mStreams m]
  , mSynced = True
  }

-- | A request reaches the server: without MARS the previous response is
-- finished; with MARS the open ones stay open, unless a reset is pending;
-- a pending reset is carried out first (after every open response is
-- settled, which the server requires under MARS).
request :: Model v -> Model v
request m
  | marsOn m && not (mResetPending m) = m { mSynced = True, mSpResetLevel = Nothing }
  | otherwise = (applyReset (settleAll m)) { mSpResetLevel = Nothing }

-- | A pending reset goes out with the next request (or with the session
-- setup batch before it).
applyReset :: Model v -> Model v
applyReset m
  | mResetPending m = (sessionReset True m) { mResetPending = False }
  | otherwise = m

-- | The session after a reset: by the RESETCONNECTION bit (plus hmssql's
-- session setup, if any), or by @sp_reset_connection@.
sessionReset :: Bool -> Model v -> Model v
sessionReset bit m0 = m
  { mTables = (mTables m) { tT1 = Nothing, tT2 = Nothing }
  , mOpts = opts
  , mDb = TestDb
  , mCtx = Nothing
  }
  where
    m = rollbackAll m0
    opts
      -- sp_reset_connection sets READ COMMITTED, and doesn't run the setup.
      | not bit = loginOpts
      -- RESETCONNECTION keeps the isolation level (or brings back the one
      -- from before an sp_reset_connection just before); the setup doesn't
      -- set one.  Azure SQL Database sets READ COMMITTED.
      | otherwise =
          (if cfgSetupEmpty (mCfg m) then loginOpts else setupOpts)
            { isolation = if cfgAzure (mCfg m) then ReadCommitted else maybe (isolation (mOpts m)) id (mSpResetLevel m) }

------------------------------------------------------------------------------
-- Batches

-- | How an error affects the rest of the batch.
data ErrClass
  = Stmt -- ^ only the statement fails
  | XaStmt -- ^ only the statement, unless XACT_ABORT (then as 'Dooming')
  | BatchAbort -- ^ aborts the batch; under XACT_ABORT also rolls back
  | Dooming -- ^ aborts the batch and rolls back

data SR v
  = Ok Int64 (Model v) -- ^ with its row count (if not NOCOUNT)
  | Err Int32 ErrClass
  | Doom (Model v) -- ^ succeeded, but the transaction is now uncommittable

type Stmt v = Model v -> SR v

data BatchResult v = BatchResult
  { brModel :: Model v
  , brError :: Maybe Int32 -- ^ the first error
  , brCount :: Int64
  }

-- | Run the statements of one batch (or one @sp_executesql@ call).
runBatch :: Via -> Model v -> [Stmt v] -> BatchResult v
runBatch via m0 stmts = BatchResult m3 err3 count
  where
    (m1, err1, count, doomed) = go m0 Nothing 0 False stmts
    (m2, err2)
      | via == Rpc =
          ( m1 { mOpts = mOpts m0 }
          , err1 <|> (if mTranCount m1 /= mTranCount m0 then Just 266 else Nothing) )
      | otherwise = (m1, err1)
    (m3, err3)
      | doomed && mTranCount m2 > 0 = (rollbackAll m2, err2 <|> Just 3998)
      -- Under MARS a transaction must not outlive the batch that began
      -- it (a Transaction Manager request begins one that can).
      | marsOn m2 && mTranCount m0 == 0 && mTranCount m2 > 0 = (rollbackAll m2, err2 <|> Just 3997)
      | otherwise = (m2, err2)

    go m err n doomed = \case
      [] -> (m, err, n, doomed)
      s : ss -> case s m of
        Ok k m' -> go m' err (n + (if noCount (mOpts m) then 0 else k)) doomed ss
        Doom m' -> go m' err n True ss
        Err e cls ->
          let err' = err <|> Just e
              xa = xactAbort (mOpts m)
           in case cls of
                Stmt -> go m err' n doomed ss
                XaStmt | not xa -> go m err' n doomed ss
                BatchAbort | not xa -> (m, err', n, doomed)
                _ -> (rollbackAll m, err', n, False)

ok :: Model v -> SR v
ok = Ok 0

missing :: SR v
missing = Err 208 BatchAbort

withTable :: Tbl -> ([Row] -> Model v -> SR v) -> Stmt v
withTable t k m = maybe missing (\rows -> k rows m) (getT t (mTables m))

setRows :: Tbl -> [Row] -> Model v -> Model v
setRows t rows m = m { mTables = putT t (Just rows) (mTables m) }

stInsert :: Tbl -> Int32 -> Int32 -> Stmt v
stInsert t i v = withTable t $ \rows m ->
  if any ((== i) . fst) rows
    then Err 2627 XaStmt
    else Ok 1 (setRows t (sortOn fst ((i, v) : rows)) m)

stUpdate :: Tbl -> Int32 -> Stmt v
stUpdate t d = withTable t $ \rows m ->
  Ok (fromIntegral (length rows)) (setRows t [(i, v + d) | (i, v) <- rows] m)

stDelete :: Tbl -> Int32 -> Stmt v
stDelete t k = withTable t $ \rows m ->
  let rest = filter ((/= k) . fst) rows
   in Ok (fromIntegral (length rows - length rest)) (setRows t rest m)

manyStmt :: ManyStmt -> Stmt v
manyStmt = \case
  MInsert t i v -> stInsert t i v
  MUpdate t d -> stUpdate t d
  MDelete t k -> stDelete t k

stSelect :: Tbl -> Stmt v
stSelect t = withTable t (\_ m -> ok m)

stCreate :: Via -> Tbl -> Stmt v
stCreate via t m
  -- A #temp table created inside sp_executesql is dropped when it returns.
  | via == Rpc = ok m
  | isJust (getT t (mTables m)) = ok m
  | otherwise = ok (setRows t [] m)

stDrop :: Tbl -> Stmt v
stDrop t m = ok m { mTables = putT t Nothing (mTables m) }

stCtx :: Int -> Stmt v
stCtx tag m = ok m { mCtx = Just (ctxValue tag) }

ctxValue :: Int -> Text
ctxValue tag = "t" <> T.pack (show tag)

stSet :: SetOpt -> Stmt v
stSet opt m = ok m { mOpts = f (mOpts m) }
  where
    f o = case opt of
      SetNoCount b -> o { noCount = b }
      SetXactAbort b -> o { xactAbort = b }
      SetArithAbort b -> o { arithAbort = b }
      SetAnsiNulls b -> o { ansiNulls = b }
      SetQuotedId b -> o { quotedId = b }
      SetTextSize n -> o { textSize = if n == 0 then 4096 else n }
      SetLanguage l -> o { language = l, dateFormat = langDateFormat l, dateFirst = langDateFirst l }
      SetDateFormat df -> o { dateFormat = df }
      SetDateFirst n -> o { dateFirst = n }
      SetLockTimeout n -> o { lockTimeout = n }
      SetIsolation l -> o { isolation = l }

stTran :: TranOp -> Stmt v
stTran op m = case op of
  TBegin -> ok (begin m)
  TCommit
    | tc == 0 -> Err 3902 XaStmt
    | tc == 1 -> ok m { mTranCount = 0, mSavepoints = [] }
    | otherwise -> ok m { mTranCount = tc - 1 }
  TRollback
    | tc == 0 -> Err 3903 XaStmt
    | otherwise -> ok (rollbackAll m)
  TSave name
    | tc == 0 -> Err 628 XaStmt
    | otherwise -> ok m { mSavepoints = (name, mTables m) : mSavepoints m }
  TRollbackTo name
    | tc == 0 -> Err 3903 XaStmt
    | otherwise -> case break ((== name) . fst) (mSavepoints m) of
        (_, (_, snap) : older) -> ok m { mTables = snap, mSavepoints = older }
        _ -> Err 6401 XaStmt
  where
    tc = mTranCount m

stErr :: ErrKind -> Stmt v
stErr k m = case k of
  ERaise16 -> Err 50000 Stmt
  ERaise18 -> Err 50000 Stmt
  EThrow -> Err 50001 BatchAbort
  EConvert -> Err 245 Dooming
  EDivZero -> Err 8134 XaStmt
  EMissing -> Err 208 BatchAbort
  ETryCatch
    | xactAbort (mOpts m) && mTranCount m > 0 -> Doom m
    | otherwise -> ok m
  ERollbackNoSp
    | mTranCount m == 0 -> Err 3903 XaStmt
    | otherwise -> Err 6401 XaStmt

langDateFormat :: Lang -> Text
langDateFormat = \case
  UsEnglish -> "mdy"
  Deutsch -> "dmy"
  British -> "dmy"

langDateFirst :: Lang -> Int32
langDateFirst = \case
  UsEnglish -> 7
  Deutsch -> 1
  British -> 1

langName :: Lang -> Text
langName = \case
  UsEnglish -> "us_english"
  Deutsch -> "Deutsch"
  British -> "British"

isolationNumber :: IsolationLevel -> Int32
isolationNumber = \case
  ReadUncommitted -> 1
  ReadCommitted -> 2
  RepeatableRead -> 3
  Serializable -> 4
  Snapshot -> 5

-- | The @\@\@OPTIONS@ bits the model tracks: ANSI_NULLS 32, ARITHABORT 64,
-- QUOTED_IDENTIFIER 256, NOCOUNT 512, XACT_ABORT 16384.
optionsMask :: Int32
optionsMask = 32 + 64 + 256 + 512 + 16384

optionBits :: Opts -> Int32
optionBits o = sum
  [ bit | (True, bit) <-
      [ (ansiNulls o, 32), (arithAbort o, 64), (quotedId o, 256), (noCount o, 512), (xactAbort o, 16384) ] ]

renderRows :: [Row] -> Text
renderRows rows = T.intercalate "," [T.pack (show i) <> ":" <> T.pack (show v) | (i, v) <- rows]

observe :: Model v -> Observed
observe m = Observed
  { obTranCount = fromIntegral (mTranCount m)
  , obXactState = if mTranCount m > 0 then 1 else 0
  , obOptions = optionBits o
  , obTextSize = textSize o
  , obLanguage = langName (language o)
  , obDateFormat = dateFormat o
  , obDateFirst = dateFirst o
  , obLockTimeout = lockTimeout o
  , obIsolation = isolationNumber (isolation o)
  , obDb = case mDb m of
      TestDb -> cfgTestDb (mCfg m)
      ScratchDb -> cfgScratchDb (mCfg m)
  , obCtx = mCtx m
  , obT1 = renderRows <$> tT1 ts
  , obT2 = renderRows <$> tT2 ts
  , obReal = renderRows (tReal ts)
  }
  where
    o = mOpts m
    ts = mTables m

------------------------------------------------------------------------------
-- Transitions

-- | Whether the operation can run in this state (checked again while
-- shrinking, after earlier operations were dropped).
valid :: Model v -> Op -> Bool
valid m = \case
  -- The next request abandons the stream, cancelling its request with an
  -- Attention if the response hasn't been read to the end.  If that
  -- Attention reaches the server while it is still sending the result (in
  -- the first millisecond or so), the server treats it as a cancel, which
  -- under XACT_ABORT rolls back the transaction; later, it doesn't.  So
  -- whether the transaction survives depends on timing: leave that state
  -- out.  (See docs/dev/protocol-notes.md, "Session state and reset".)  So
  -- does 'cancelResponse'.  A stream whose own batch fails and rolls the
  -- transaction back is left out with it: the Attention can reach the
  -- server before the batch has run, and then nothing rolls back (nearly
  -- never on SQL Server 2025, nearly always on 2022).  On a MARS
  -- connection a stream has all arrived before the next operation, and is
  -- never cancelled by an Attention.
  op@(StreamOpen s _ _) ->
    let m' = fst (step m op)
        -- A stream still to be read, in a transaction it leaves open.
        cancelEndsIt = mTranCount m' > 0 && any (isLive . snd) (mStreams m')
        -- A stream whose own batch ends the transaction, if it runs.
        batchEndsIt = mTranCount m > 0 && mTranCount m' == 0
     in isNothing (streamAt s m)
          && (marsOn m || not (xactAbort (mOpts m') && (cancelEndsIt || batchEndsIt)))
  StreamPull s _ -> isJust (streamAt s m)
  StreamDrain s -> isJust (streamAt s m)
  StreamCancel s -> isJust (streamAt s m)
  TxEnd _ -> not (null (mFrames m))
  -- Unsupported inside withTransaction (which then throws
  -- 'ConnectionReleased' and breaks the connection); not modelled.
  Release -> null (mFrames m)
  -- Never KILL (or watch) a session id that may belong to someone else by
  -- now (after a 'Cut', the connection may be broken and the session gone).
  Kill -> mLife m == Alive
  Waitfor _ _ -> usable m
  Fatal -> usable m
  -- Only where the interruption can't change the session, whichever point
  -- it lands at: no pending reset (it would go out, or not), no
  -- sp_reset_connection just before (the next request may be this one, or
  -- not), no stream to abandon (it would be abandoned, or not; under MARS
  -- none is), and no XACT_ABORT transaction (the Attention, if it reaches
  -- the server while the statement runs, rolls it back).
  Cut _ _ _ ->
    usable m && not (mResetPending m) && isNothing (mSpResetLevel m)
      && (marsOn m || not (busy m)) && not (xactAbort (mOpts m) && mTranCount m > 0)
  _ -> True

isLive :: StreamSt -> Bool
isLive = \case
  Live _ Nothing -> True
  _ -> False

streaming :: StreamSt -> Bool
streaming = \case
  Live _ _ -> True
  _ -> False

-- | After 'release': every stream so far was opened through the released
-- handle.
staleStreams :: Model v -> Model v
staleStreams m = m { mStreams = [(k, Stale) | (k, _) <- mStreams m] }

-- | The slot an operation reads or cancels.
opSlot :: Op -> Maybe Int
opSlot = \case
  StreamPull s _ -> Just s
  StreamDrain s -> Just s
  StreamCancel s -> Just s
  _ -> Nothing

-- | The state after an operation, and what it should return.
step :: Model v -> Op -> (Model v, Expect)
step m0 op = (opened m', drainedInfos (unsure (settledInfos ex)))
  where
    -- An abandoned 'Cut' drained first ('mDrainsNext'): one INFO 3926
    -- more, or not.  A 'Cut' may be interrupted before it drains, so the
    -- flag stays set through it.
    drains = drainsAbandoned op && not (isCutOp op)
    m = if drains then m0 { mDrainsNext = False } else m0
    drainedInfos e
      | mDrainsNext m0 && drainsAbandoned op = e { exInfos = Nothing }
      | otherwise = e
    -- A refused stream ('staleStep') settled by the operation: its INFO
    -- 3926 comes as it is drained, first.  (Pulling it expects its own.)
    settledInfos e =
      let n = length
            [ () | (s, Live _ (Just 3971)) <- mStreams m, opSlot op /= Just s || isCancel
            , maybe False (not . streaming) (streamAt s m') ]
       in e { exInfos = (replicate n 3926 ++) <$> exInfos e }
    isCancel = case op of
      StreamCancel _ -> True
      _ -> False
    (m', ex) = case mLife m of
      Alive -> aliveStep m op
      -- The model follows the connection as if usable; 'brokenExpect' is
      -- the alternative.
      AliveOrBroken -> aliveStep m op
      Closed -> goneStep [FClosedByClient] m op
      Dead -> goneStep [FClosed, FBroken, FClosedByClient, FSql 596] m op
    opened r = case op of
      StreamOpen s _ _ -> r
        { mNextSlot = max (mNextSlot r) (s + 1)
        , mUnsure = [s | mLife m == AliveOrBroken] ++ mUnsure r
        }
      _ -> r
    unsure e = case (opSlot op, exOutcome e) of
      (Just s, OneOf os) | s `elem` mUnsure m -> e { exOutcome = OneOf (os ++ [OFail FNoStream]), exInfos = Nothing }
      _ -> e

-- | After a 'Cut' ('AliveOrBroken'): what the operation should do if the
-- connection is broken.  Every request throws 'ConnectionBroken'; 'close'
-- works; 'reset' only sets a flag; 'release' says 'False'; cancelling a
-- stream does nothing.  (A stream opened since then was never opened, so
-- the runner has none in its slot; an older one is abandoned, broken or
-- released.)
brokenExpect :: Model v -> Op -> Maybe Expect
brokenExpect m op
  | mLife m /= AliveOrBroken = Nothing
  | otherwise = Just $ case op of
      StreamPull _ _ -> Expect (OneOf (map OFail [FBroken, FAbandoned, FNoStream, FReleased])) Nothing
      StreamDrain _ -> Expect (OneOf (map OFail [FBroken, FAbandoned, FNoStream, FReleased])) Nothing
      StreamCancel _ -> Expect (OneOf [OUnit, OFail FNoStream, OFail FReleased]) Nothing
      Release -> Expect (OneOf [OBool False]) Nothing
      -- The interruption (if it came) is what the 'Cut' reports.
      Cut _ _ _ -> Expect (OneOf [OInterrupted, OFail FBroken]) Nothing
      Waitfor _ _ -> Expect (OneOf [OFail FBroken]) Nothing
      -- The 'TxBegin' may have failed, broken, and left the runner no
      -- 'withTransaction' to end.
      TxEnd _ -> case snd (goneStep [FBroken] m op) of
        Expect (OneOf os) infos -> Expect (OneOf (OFail (FOther "no withTransaction") : os)) infos
        e -> e
      _ -> snd (goneStep [FBroken] m op)

-- | After 'close' or a killed session: requests fail with @failures@.
goneStep :: [Failure] -> Model v -> Op -> (Model v, Expect)
goneStep failures m = \case
  Close -> (if mLife m == Alive then m { mLife = Closed } else m, loose [OUnit])
  -- Nothing is sent.  A session killed while idle may not have been
  -- noticed yet (the reader hasn't seen the end of the stream), and then
  -- 'release' can't tell it from a live one.
  Release ->
    ( staleStreams m
    , loose (OBool False : [OBool True | mLife m == Dead]) )
  Reset -> (m, loose (OUnit : fails))
  Api ApiRollback -> (m, loose (OUnit : fails))
  Api ApiBegin -> (m, loose (refused ++ fails))
  Api ApiCommit -> (m, loose (refused ++ fails))
  TxBegin _ -> (m, loose (OFail FTxActive : refused ++ fails))
  TxEnd mode ->
    ( m { mFrames = drop 1 (mFrames m) }
    , loose $ [OFail (FOther "no withTransaction") | f <- take 1 (mFrames m), fUnsure f] ++ case mode of
        Commit -> OFail FTxEndedEarly : refused ++ fails
        Throw -> [OFail FBodyAbort]
    )
  -- The handle is checked before anything else.
  StreamPull s _
    | streamAt s m == Just Stale -> (m, loose [OFail FReleased])
    | mLife m == Dead -> (m, Expect AnyOutcome Nothing)
  StreamDrain s
    | streamAt s m == Just Stale -> (m, loose [OFail FReleased])
    | mLife m == Dead -> (m, Expect AnyOutcome Nothing)
  -- Nothing to do once the connection is closed.  A killed session may
  -- not have been noticed yet: a response that has all arrived is read to
  -- its end then.
  StreamCancel s
    | streamAt s m == Just Stale -> (m, loose [OFail FReleased])
    | mLife m == Dead -> (m, Expect AnyOutcome Nothing)
    | otherwise -> (m, loose [OUnit])
  _ -> (m, loose fails)
  where
    fails = map OFail failures
    loose os = Expect (OneOf os) Nothing
    -- The check for busy responses comes before anything is sent: once
    -- the end of a killed session has been seen, the connection's error
    -- comes first ("Transaction.MarsEndedConnectionSpec"), but just after
    -- the KILL it may not have been, and a stream still unread is busy.
    refused = [OFail FTxRequestsActive | marsOn m, busy m, mLife m == Dead]

aliveStep :: Model v -> Op -> (Model v, Expect)
aliveStep m0 op | staleTx m0 && sendsRequest op = staleStep m0 op
aliveStep m0 op = case op of
  CreateTemp via t -> unitBatch via [stCreate via t] []
  DropTemp via t -> unitBatch via [stDrop t] []
  Insert via t i v -> countBatch via [stInsert t i v]
  UpdateRows via t d -> countBatch via [stUpdate t d]
  Delete via t k -> countBatch via [stDelete t k]
  -- Each statement is an RPC of one message.  An error that only ends its
  -- statement (a duplicate key), or its call (a missing table), lets the
  -- next run; under XACT_ABORT, any error rolls back and ends the message.
  -- (Measured: the rest of the message doesn't run then.)
  ExecMany stmts ->
    let go m counts err = \case
          [] -> (m, reverse counts, err)
          st : sts ->
            let br = runBatch Rpc m [manyStmt st]
                err' = err <|> brError br
             in if isJust (brError br) && xactAbort (mOpts m)
                  then (brModel br, reverse counts, err')
                  else go (brModel br) (brCount br : counts) err' sts
        (m', counts', err'') = go m1 [] Nothing stmts
     in (m', exactly (maybe (OCounts counts') (OFail . FSql) err'') [])
  Select via t ->
    let br = runBatch via m1 [stSelect t]
     in (brModel br, exactly (orFail br (ORows (rowsOf t))) [])
  Multi via ts -> sets via ts
  Results ts -> sets Batch ts
  -- Without MARS the request abandons the live stream, if any; with MARS
  -- it leaves the open ones open.
  StreamOpen s via t ->
    let br = runBatch via m1 [stSelect t]
        st = case brError br of
          Nothing -> Live (rowsOf t) Nothing
          Just e -> Live [] (Just e)
        r = brModel br
        rolledBack = [s | mTranCount m1 > 0, mTranCount r == 0]
     in r { mStreams = mStreams r ++ [(s, st)], mRolledBackBy = rolledBack ++ mRolledBackBy r, mSynced = False }
          `with` exactly OUnit []
  StreamPull s n -> pull s (Just n)
  StreamDrain s -> pull s Nothing
  -- A live stream is cancelled (its response, all arrived, is read to its
  -- end); anything else is left as it is, with nothing sent.  The handle
  -- is checked first.
  StreamCancel s -> case streamAt s m0 of
    Just Stale -> (m0, exactly (OFail FReleased) [])
    Just st | streaming st -> (ended s, exactly OUnit [])
    _ -> (m0, exactly OUnit [])
  -- Inside sp_executesql, SET LANGUAGE sends no INFO message (USE does).
  Set via opt -> unitBatch via [stSet opt] [5703 | SetLanguage _ <- [opt], via == Batch]
  Use via db -> unitBatch via [\m -> ok m { mDb = db }] [5701]
  SetCtx via tag -> unitBatch via [stCtx tag] []
  Tran via op -> unitBatch via [stTran op] []
  -- A Transaction Manager request (TM_BEGIN_XACT, keeping the session's
  -- level), which begins or nests a transaction as BEGIN TRANSACTION does.
  -- Under MARS both are refused, with nothing sent, while a stream is
  -- busy; the transaction stays open.
  Api ApiBegin
    | refused -> (m0, exactly (OFail FTxRequestsActive) [])
    | otherwise -> (begin m1, exactly OUnit [])
  Api ApiCommit
    | refused -> (m0, exactly (OFail FTxRequestsActive) [])
    | otherwise -> unitBatch Batch [stTran TCommit] []
  -- Every open response is settled first.
  Api ApiRollback ->
    let m' = settleAll m0
     in if clientInTransaction m'
          then (rollbackAll (request m'), exactly OUnit [])
          else (m', exactly OUnit [])
  -- Refused whenever hmssql believes a transaction is active, even one a
  -- pending reset is about to roll back.  The begin request (TM_BEGIN_XACT,
  -- with the level, if any; it carries a pending reset, or follows the
  -- session setup batch that does) begins the transaction numbered next.
  -- Under MARS, a busy stream is checked for first.
  TxBegin lvl
    | refused -> (m0, exactly (OFail FTxRequestsActive) [])
    | clientInTransaction (settleAll m0) -> (settleAll m0, exactly (OFail FTxActive) [])
    | otherwise ->
        let r = request (settleAll m0)
            r' = begin r { mOpts = (mOpts r) { isolation = maybe (isolation (mOpts r)) id lvl } }
            frame = Frame { fLevel = lvl, fTx = mTxSerial r', fUnsure = mLife m0 == AliveOrBroken }
         in (r' { mFrames = frame : mFrames r' }, exactly OUnit [])
  TxEnd mode -> case mFrames m0 of
    [] -> (m0, exactly (OFail (FOther "no withTransaction")) [])
    f : fs ->
      let m' = m0 { mFrames = fs }
          -- withTransactionLevel's COMMIT / ROLLBACK batch ends with SET
          -- TRANSACTION ISOLATION LEVEL READ COMMITTED.
          levelBack
            | isJust (fLevel f) = [stSet (SetIsolation ReadCommitted)]
            | otherwise = []
          -- Every open response is settled, then "IF @@TRANCOUNT > 0
          -- ROLLBACK TRANSACTION" (after a pending reset, which rolls back
          -- itself).
          cleanup r = brModel (runBatch Batch (request (settleAll r)) ((ok . rollbackAll) : levelBack))
       in case mode of
            Throw -> (cleanup m', exactly (OFail FBodyAbort) [])
            -- Under MARS, a busy stream is checked for first: the commit
            -- is refused, and everything rolled back.
            Commit | marsOn m' && busy m' -> (cleanup m', exactly (OFail FTxRequestsActive) [])
            Commit ->
              let r = settleAll m'
                  -- Its transaction is gone, another took its place, or a
                  -- pending reset would roll it back before the COMMIT.
                  ended = not (clientInTransaction r) || mTxSerial r /= fTx f || mResetPending r
                  br = runBatch Batch (request r) (stTran TCommit : levelBack)
               in if ended
                    then (cleanup r, exactly (OFail FTxEndedEarly) [])
                    else case brError br of
                      Just e -> (cleanup (brModel br), exactly (OFail (FSql e)) [])
                      Nothing
                        -- A nested BEGIN the body didn't end: the COMMIT
                        -- only lowered @@TRANCOUNT, and the cleanup rolls
                        -- everything back ('TransactionStillOpen').
                        | mTranCount (brModel br) > 0 -> (cleanup (brModel br), exactly (OFail FTxStillOpen) [])
                        | otherwise -> (brModel br, exactly OUnit [])
  Raise via k tag -> unitBatch via [stErr k, stCtx tag] []
  Info via k -> unitBatch via [ok] $ case k of
    IPrint -> [0]
    IRaise10 -> [50000]
    IRaise0 -> [50000]
    IPrintTwice -> [0, 50000]
  CallProc a ->
    ( m1
    , exactly (OProc (Just (a * 3)) (Just (a + 1)) (mCtx m1) [[fromIntegral (mTranCount m1)]]) []
    )
  Reset -> (m0 { mResetPending = True }, exactly OUnit [])
  SpReset -> ((sessionReset False m1) { mSpResetLevel = Just (isolation (mOpts m1)) }, exactly OUnit [])
  Waitfor _ _ ->
    -- Interrupted while waiting for the response: the interrupted thread
    -- sends the Attention at once, so the batch goes no further, and under
    -- XACT_ABORT the cancel rolls the transaction back.  The connection
    -- stays usable; the next request reads the acknowledgement (and the
    -- ENVCHANGE of that rollback).
    let r = if xactAbort (mOpts m1) then rollbackAll m1 else m1
     in (r { mSynced = False }, exactly OInterrupted [])
  -- The session doesn't change ('valid'), however far the query got; the
  -- connection may be broken ('brokenExpect').
  Cut _ _ _ ->
    ( m0 { mLife = AliveOrBroken, mSynced = False }
    , exactly' [OInterrupted, ORows [(fromIntegral (mTranCount m1), 0)]] [] )
  Kill -> (m0 { mLife = Dead }, exactly OUnit [])
  Fatal -> (m1 { mLife = Dead }, Expect (OneOf [OFail (FSql 50000)]) Nothing)
  Close -> (m0 { mLife = Closed }, exactly OUnit [])
  -- The response is finished (a statement still running is cancelled), and
  -- a reset marked pending.  With a transaction open (as hmssql sees it
  -- after that drain), one request (a SELECT 1, or the session setup
  -- batch) carries the reset out at once, so the transaction is rolled
  -- back, the #temp tables are dropped and nothing is left pending; else
  -- the reset waits for the next request, like 'reset'.  Every stream so
  -- far was opened through the released handle.
  Release ->
    let m' = (settleAll m0) { mResetPending = True }
        r = if clientInTransaction m' then request m' else m'
     in (staleStreams r, exactly (OBool True) [])
  Check -> (m1, exactly (OState (observe m1)) [])
  where
    m1 = request m0
    refused = marsOn m0 && busy m0
    with a b = (a, b)
    exactly' os infos = Expect (OneOf os) (Just infos)
    rowsOf t = maybe [] id (getT t (mTables m1))

    orFail br o = maybe o (OFail . FSql) (brError br)

    unitBatch via stmts infos =
      let br = runBatch via m1 stmts
       in (brModel br, exactly (orFail br OUnit) infos)

    countBatch via stmts =
      let br = runBatch via m1 stmts
       in (brModel br, exactly (orFail br (OCount (brCount br))) [])

    sets via ts =
      let br = runBatch via m1 (map stSelect ts)
       in (brModel br, exactly (orFail br (OSets (map rowsOf ts))) [])

    -- Read to its end (or cancelled).  Without MARS it was the only
    -- response unread; with MARS others may be.
    ended s = (setStream s Gone m0) { mSynced = mSynced m0 || not (marsOn m0) }

    -- Rows are yielded until n have been, so a stream read to its last row
    -- has not ended (and is busy) until it is pulled again.
    pull s limit = case streamAt s m0 of
      Nothing -> (m0, exactly (OFail FNoStream) [])
      Just Gone -> (m0, exactly (OFail FAbandoned) [])
      Just Stale -> (m0, exactly (OFail FReleased) [])
      -- Error 3971 comes with INFO 3926 ('staleStep').
      Just (Live _ (Just e)) -> (ended s, exactly (OFail (FSql e)) [3926 | e == 3971])
      Just (Live rows Nothing) -> case limit of
        Just n | length rows >= n ->
          let (got, rest) = splitAt n rows
           in (setStream s (Live rest Nothing) m0, exactly (OPulled got False) [])
        _ -> (ended s, exactly (OPulled rows True) [])

-- | Whether the operation sends a request without settling the open
-- responses first.
sendsRequest :: Op -> Bool
sendsRequest = \case
  Api _ -> False
  TxBegin _ -> False
  TxEnd _ -> False
  Reset -> False
  Kill -> False
  Close -> False
  Release -> False
  StreamPull _ _ -> False
  StreamDrain _ -> False
  StreamCancel _ -> False
  _ -> True

-- | Whether the operation first drains a response abandoned by an
-- interrupted read ('mDrainsNext'): every request does, and so do the
-- transaction functions (before they check for busy responses),
-- 'release' and 'rollback'.  Reading or cancelling a stream,
-- 'reset', 'close' and a KILL from the monitor connection don't.
drainsAbandoned :: Op -> Bool
drainsAbandoned op = sendsRequest op || case op of
  Api _ -> True
  TxBegin _ -> True
  TxEnd _ -> True
  Release -> True
  _ -> False

isCutOp :: Op -> Bool
isCutOp = \case
  Cut{} -> True
  _ -> False

-- | A request refused for its stale transaction descriptor ('staleTx'):
-- error 3971 with INFO 3926, nothing done.  (The transaction functions
-- are refused before that, since the stream is busy.)
staleStep :: Model v -> Op -> (Model v, Expect)
staleStep m0 = \case
  -- The error is the stream's, thrown once it is read to its end.
  StreamOpen s _ _ -> (m0 { mStreams = mStreams m0 ++ [(s, Live [] (Just 3971))] }, exactly OUnit [])
  -- A message of several calls: its INFO messages aren't predicted.
  ExecMany _ -> (m0, Expect (OneOf [refused]) Nothing)
  -- Interrupted after its request went out, its refused response is
  -- abandoned, and the next request drains it, INFO 3926 and all
  -- ('mDrainsNext').  Whether the interruption came before or after the
  -- send is a matter of scheduling.
  Cut _ _ _ -> (m0 { mLife = AliveOrBroken, mDrainsNext = True }, Expect (OneOf [OInterrupted, refused]) Nothing)
  _ -> (m0, exactly refused [3926])
  where
    refused = OFail (FSql 3971)

------------------------------------------------------------------------------
-- Generation

-- | How often each kind of operation is generated.
data OpWeights = OpWeights
  { wStreams :: Int
  , wTx :: Int -- ^ withTransaction
  , wTerminal :: Int -- ^ close, kill, severity 20
  , wWaitfor :: Int
  , wCut :: Int
  , wReset :: Int
  , wRelease :: Int -- ^ release (and renew)
  }

defaultWeights :: OpWeights
defaultWeights = OpWeights { wStreams = 3, wTx = 3, wTerminal = 1, wWaitfor = 2, wCut = 2, wReset = 3, wRelease = 2 }

-- | For operations run concurrently on one connection: nothing that spans
-- several operations (streams, withTransaction), nothing that ends the
-- connection or relies on timing, and no release (one thread's would make
-- the other's handle stale).
parallelWeights :: OpWeights
parallelWeights = OpWeights { wStreams = 0, wTx = 0, wTerminal = 0, wWaitfor = 0, wCut = 0, wReset = 3, wRelease = 0 }

genOp :: OpWeights -> Model v -> Gen Op
genOp w m = Gen.frequency $ filter ((> 0) . fst) $ if usable m then
    [ (60, pure Check)
    , (60, Insert <$> via <*> table <*> ident <*> value)
    , (24, UpdateRows <$> via <*> table <*> Gen.int32 (Range.linear (-10) 10))
    , (24, Delete <$> via <*> table <*> ident)
    , (16, ExecMany <$> Gen.list (Range.linear 1 4) manyStmtGen)
    , (24, Select <$> via <*> table)
    , (12, Multi <$> via <*> Gen.list (Range.linear 1 3) table)
    , (12, Results <$> Gen.list (Range.linear 1 3) table)
    , (if missingTemps then 30 else 6, CreateTemp <$> Gen.frequency [(6, pure Batch), (1, pure Rpc)] <*> Gen.element [T1, T2])
    , (8, DropTemp <$> via <*> Gen.element [T1, T2])
    , (openWeight, StreamOpen (mNextSlot m) <$> via <*> table)
    , (48, Set <$> Gen.frequency [(3, pure Batch), (1, pure Rpc)] <*> genSetOpt w)
    , (if cfgAzure (mCfg m) then 0 else 16, Use <$> via <*> Gen.enumBounded)
    , (16, SetCtx <$> via <*> tag)
    , (48, Tran <$> Gen.frequency [(4, pure Batch), (1, pure Rpc)] <*> tranOp)
    -- Under MARS a transaction only begins by a Transaction Manager request.
    , (if marsOn m then 24 else 16, Api <$> Gen.enumBounded)
    , ( (if null (mFrames m) then 8 else 2) * wTx w
      , TxBegin <$> Gen.maybe (Gen.element [ReadUncommitted, ReadCommitted, RepeatableRead, Serializable]) )
    , (30, Raise <$> via <*> Gen.enumBounded <*> tag)
    , (10, Info <$> via <*> Gen.enumBounded)
    , (12, CallProc <$> Gen.int32 (Range.linear (-50) 50))
    , (4 * wReset w, pure Reset)
    , (wReset w, pure SpReset)
    , (if null (mFrames m) then 4 * wRelease w else 0, pure Release)
    , (2 * wWaitfor w, Waitfor <$> via <*> tag)
    , (if cutOk then 2 * wCut w else 0, Cut <$> via <*> Gen.element [0, 1, 2, 5] <*> Gen.int (Range.linear 1 6000))
    , (if mLife m == Alive then wTerminal w else 0, pure Kill)
    , (if cfgAzure (mCfg m) then 0 else wTerminal w, pure Fatal)
    , (wTerminal w, pure Close)
    ] ++ streamOps ++ txEnd
  else
    [ (4, pure Check)
    , (2, Insert <$> via <*> table <*> ident <*> value)
    , (1, ExecMany <$> Gen.list (Range.linear 1 2) manyStmtGen)
    , (1, Set Batch <$> genSetOpt w)
    , (1, pure Reset)
    , (1, pure (Api ApiRollback))
    , (if null (mFrames m) then wRelease w else 0, pure Release)
    , (1 * wTx w, TxBegin <$> Gen.maybe (Gen.element [ReadCommitted, Serializable]))
    , (1, CallProc <$> Gen.int32 (Range.linear 0 5))
    , (1, pure Close)
    ] ++ streamOps ++ txEnd
  where
    via = Gen.enumBounded
    -- Mostly tables that exist (a missing one is an error, 208).
    table = Gen.frequency
      [ (if exists t then 8 else 1, pure t) | t <- [T1, T2, Real] ]
    exists t = isJust (getT t (mTables m))
    cutOk = valid m (Cut Batch 0 1)
    missingTemps = not (exists T1 && exists T2)
    ident = Gen.int32 (Range.linear 1 6)
    value = Gen.int32 (Range.linear (-100) 100)
    tag = Gen.int (Range.linear 0 99)
    manyStmtGen = Gen.frequency
      [ (4, MInsert <$> table <*> ident <*> value)
      , (1, MUpdate <$> table <*> Gen.int32 (Range.linear (-10) 10))
      , (1, MDelete <$> table <*> ident) ]
    tranOp = Gen.frequency
      [ (5, pure TBegin), (3, pure TCommit), (2, pure TRollback)
      , (2, TSave <$> savepoint), (2, TRollbackTo <$> savepoint) ]
    savepoint = Gen.element ["hm_a", "hm_b"]
    -- Without MARS a live stream is soon read (there is at most one);
    -- with MARS up to four are open at once, and each is read a little at
    -- a time between other operations.
    live = [s | (s, st) <- mStreams m, streaming st]
    done = [s | (s, st) <- mStreams m, not (streaming st)]
    openWeight
      | not (marsOn m) = 6 * wStreams w
      | length live < 4 = 14 * wStreams w
      | otherwise = 0
    pullN = Gen.int (Range.linear 1 3)
    streamOps = liveOps ++ doneOps
    liveOps
      | null live = []
      | marsOn m = let k = length live in
          [ (30 * k, StreamPull <$> Gen.element live <*> pullN)
          , (6 * k, StreamDrain <$> Gen.element live)
          , (6 * k, StreamCancel <$> Gen.element live) ]
      | otherwise =
          [ (300, StreamPull <$> Gen.element live <*> pullN)
          , (60, StreamDrain <$> Gen.element live)
          , (30, StreamCancel <$> Gen.element live) ]
    -- Read to the end, abandoned, cancelled, or stale.
    doneOps
      | null done = []
      | otherwise =
          [ (3, StreamPull <$> Gen.element done <*> pullN)
          , (1, StreamDrain <$> Gen.element done)
          , (1, StreamCancel <$> Gen.element done) ]
    txEnd
      | null (mFrames m) = []
      | otherwise = [(30, TxEnd <$> Gen.frequency [(3, pure Commit), (2, pure Throw)])]

genSetOpt :: OpWeights -> Gen SetOpt
genSetOpt _ = Gen.choice
  [ SetNoCount <$> Gen.bool
  , SetXactAbort <$> Gen.bool
  , SetXactAbort <$> Gen.bool
  , SetArithAbort <$> Gen.bool
  , SetAnsiNulls <$> Gen.bool
  , SetQuotedId <$> Gen.bool
  , SetTextSize <$> Gen.element [0, -1, 100, 65536, 2147483647]
  , SetLanguage <$> Gen.enumBounded
  , SetDateFormat <$> Gen.element ["mdy", "dmy", "ymd", "ydm", "myd", "dym"]
  , SetDateFirst <$> Gen.int32 (Range.linear 1 7)
  -- Not 0: the model has no locks, and with LOCK_TIMEOUT 0 any wait at
  -- all is error 1222.  A DELETE on the session's own #temp table met
  -- one once in a whole-suite run (docs/dev/protocol-notes.md).
  , SetLockTimeout <$> Gen.element [-1, 1000, 5000]
  , SetIsolation <$> Gen.element [ReadUncommitted, ReadCommitted, RepeatableRead, Serializable]
  ]
