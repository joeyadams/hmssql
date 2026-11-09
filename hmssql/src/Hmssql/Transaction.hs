{-# LANGUAGE MagicHash #-}
-- | Transactions.  'withTransaction' runs an action in one, committing if
-- it returns and rolling back if it throws; the @begin@, @commit@ and
-- @rollback@ functions are the pieces, for manual control.
--
-- A transaction begins with a Transaction Manager request (TM_BEGIN_XACT,
-- what @BEGIN TRANSACTION@ does, and the only begin SQL Server accepts on a
-- MARS connection); it is committed and rolled back by T-SQL batches.
-- The connection tracks the server's transaction descriptor from ENVCHANGE
-- tokens, so 'inTransaction' is what the server says, and a transaction
-- the server has already rolled back (after a deadlock, or an error under
-- @XACT_ABORT ON@) is not rolled back twice, and not committed by mistake.
module Hmssql.Transaction
  ( IsolationLevel (..)
  , withTransaction
  , withTransactionLevel
  , TransactionError (..)
  , begin
  , commit
  , rollback
  , inTransaction
  ) where

import Control.Exception
import Control.Monad (void, when)
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)

import Hmssql.Connection.Internal
import Hmssql.Errors (UnusableReason (..))
import Hmssql.Internal.Derived
import Hmssql.Query
import Hmssql.Query.Types (Request (..), ResponseReader (..))
import Hmssql.Tds.Client (tmBeginTransactionBuilder)
import Hmssql.Tds.PacketWriter (writeBuilder)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet (PacketType (..))

-- | SQL Server's transaction isolation levels, for 'withTransactionLevel'.
-- 'ReadCommitted' is the session's level at login.  'Snapshot' needs
-- @ALLOW_SNAPSHOT_ISOLATION@ turned on for the database, or the
-- transaction fails.
data IsolationLevel
  = ReadUncommitted
  | ReadCommitted
  | RepeatableRead
  | Snapshot
  | Serializable
  deriving stock (Eq, Show, Enum, Bounded)

-- | The isolation-level byte of a TM_BEGIN_XACT request.
isolationByte :: IsolationLevel -> Word8
isolationByte = \case
  ReadUncommitted -> 1
  ReadCommitted -> 2
  RepeatableRead -> 3
  Serializable -> 4
  Snapshot -> 5

-- | Misuse of 'withTransaction' or 'withTransactionLevel'.
data TransactionError
  = TransactionAlreadyActive
    -- ^ A transaction was already active on the connection.  SQL Server's
    -- nested transactions don't nest (an inner @ROLLBACK@ ends the outer
    -- transaction too), so they are refused rather than emulated.
  | TransactionEndedEarly
    -- ^ The transaction ended before the body returned, so nothing was
    -- committed: the server rolled it back after an error the body caught
    -- (under @XACT_ABORT ON@, or as a deadlock victim) or after the
    -- Attention that canceled a stream under @XACT_ABORT ON@ (see
    -- 'Hmssql.Query.queryS'); or the body committed or rolled it back
    -- itself, or called 'Hmssql.Connection.reset'.  (A body that calls
    -- 'Hmssql.Connection.release' gets 'Hmssql.Errors.ConnectionReleased'
    -- instead.)
  | TransactionRequestsActive [Text]
    -- ^ On a MARS connection ('Hmssql.Connection.connectMars'): another
    -- response on the connection had not been read to its end or
    -- canceled when a transaction was to begin or to be committed.  The
    -- server refuses both while another request is active (errors 3988
    -- and 3981, the second of which loses the transaction), so hmssql
    -- checks first, by what has been read.  Before a begin, nothing was
    -- sent; before the commit of 'withTransaction', the responses were
    -- canceled and the transaction rolled back; before
    -- 'commit', the transaction is still open.  Carries the
    -- SQL text of each unfinished response, so that a stream left open
    -- can be found.  Read every stream to its end (not only to its last
    -- row), cancel it, or open it with 'Hmssql.Query.withQueryS'.
  | TransactionStillOpen
    -- ^ The connection was still in a transaction after the @COMMIT@: the
    -- body began a nested one (@BEGIN TRANSACTION@, 'begin')
    -- and didn't end it, so the @COMMIT@ only lowered @\@\@TRANCOUNT@ and
    -- committed nothing.  Everything was then rolled back.

instance Show TransactionError where
  showsPrec p = \case
    TransactionAlreadyActive -> showString "TransactionAlreadyActive"
    TransactionEndedEarly -> showString "TransactionEndedEarly"
    TransactionRequestsActive a -> showCon1 p "TransactionRequestsActive"# a
    TransactionStillOpen -> showString "TransactionStillOpen"
  {-# OPAQUE showsPrec #-}

instance Exception TransactionError where
  displayException = \case
    TransactionAlreadyActive ->
      "hmssql: withTransaction: a transaction is already active on this connection \
      \(nested transactions are not supported)"
    TransactionEndedEarly ->
      "hmssql: withTransaction: the transaction ended before the body returned \
      \(rolled back by the server, or ended by the body); nothing was committed"
    TransactionRequestsActive stmts ->
      "hmssql: a transaction can't begin or be committed while other responses on the \
      \connection are unfinished (read them to the end or cancel them first): "
        ++ T.unpack (T.intercalate "; " stmts)
    TransactionStillOpen ->
      "hmssql: withTransaction: the connection was still in a transaction after the COMMIT \
      \(the body began a nested transaction and did not end it); everything was rolled back"

-- | Whether a transaction is active on the connection: the server said
-- one began (a begin-transaction ENVCHANGE), and hasn't said it ended.
inTransaction :: Connection -> IO Bool
inTransaction conn = isJust . tdsTransaction <$> connectionContext conn

-- | Begin a transaction (as @BEGIN TRANSACTION@ does, by a Transaction
-- Manager request), for manual control.  Unlike 'withTransaction' it
-- doesn't refuse a nested transaction, hold the connection for the
-- transaction's duration, or roll back on an exception.  On a MARS
-- connection it throws 'TransactionRequestsActive' if another response is
-- unfinished.
begin :: Connection -> IO ()
begin conn = withConnectionLock conn $ do
  refuseActiveRequests conn
  beginAtLevel conn Nothing

-- | On a MARS connection, throw 'TransactionRequestsActive' if any
-- response has not been read to its end or canceled.  (Without MARS the
-- next request abandons the one response there can be.)  A released
-- handle is refused first, as by any use of the connection.
refuseActiveRequests :: Connection -> IO ()
refuseActiveRequests conn = when (isJust (connMars conn)) $ withConnectionLock conn $ do
  -- A connection that is broken or has ended says so, as a request on it
  -- would, rather than naming the responses it died with.
  refuseUnusable conn
  -- A response canceled by an interrupted read is over but for its
  -- acknowledgement.
  drainCancelled conn
  busy <- busyStatements conn
  when (not (null busy)) $ throwIO (TransactionRequestsActive busy)

-- | TM_BEGIN_XACT at the level (or the session's), read to its end.
beginAtLevel :: Connection -> Maybe IsolationLevel -> IO ()
beginAtLevel conn mlevel = mask $ \restore -> do
  resp <- startResponse conn req
  readingToEnd conn (respActive resp) (restore (drainResponse resp))
  where
    req = Request PTTransactionManager
      (\ctx writer -> writeBuilder writer (tmBeginTransactionBuilder ctx (maybe 0 isolationByte mlevel)))
      (Just "BEGIN TRANSACTION")

-- | @COMMIT TRANSACTION@.  Throws 'Hmssql.Errors.SqlServerError' if no transaction is
-- active (the server's error 3902).  On a MARS connection it throws
-- 'TransactionRequestsActive' if another response is unfinished; nothing
-- is sent then, and the transaction stays open.
commit :: Connection -> IO ()
commit conn = withConnectionLock conn $ do
  refuseActiveRequests conn
  void $ execute conn "COMMIT TRANSACTION"

-- | @ROLLBACK TRANSACTION@, if a transaction is active; nothing if the
-- server has already ended it.  Responses still open on the connection
-- are canceled first (on a MARS connection, all of them: the server
-- keeps a rolled-back transaction, doomed, until they have ended).
rollback :: Connection -> IO ()
rollback conn = withConnectionLock conn $ do
  -- An unread response may still hold the ENVCHANGE that ended it.
  finishResponse conn
  active <- inTransaction conn
  -- Conditional: a pending 'Hmssql.Connection.reset' goes out first and
  -- rolls the transaction back itself.
  when active $ void $ execute conn "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"

-- | Run the action in a transaction.  It commits if the action returns,
-- and rolls back if the action throws, an asynchronous exception from
-- 'Control.Concurrent.killThread' or 'System.Timeout.timeout' included.
-- Beginning the transaction is a round trip of its own before the action
-- runs, and the @COMMIT@ is another.
--
-- The connection is held for the whole transaction, so requests from
-- other threads wait until it ends instead of running inside it.  The
-- action must not wait for another thread that uses the connection.
--
-- On a MARS connection ('Hmssql.Connection.connectMars') every request
-- the body makes, and every stream it opens, runs in the transaction.  No
-- response may be unfinished when it begins or when the body returns
-- ('TransactionRequestsActive'): begin first, open the streams inside
-- with 'Hmssql.Query.withQueryS', and let them end before the body
-- returns.  If the body throws, the responses it left open are canceled
-- before the rollback.
--
-- Throws 'TransactionAlreadyActive' if a transaction is already active;
-- 'TransactionEndedEarly' (after cleaning up) if the body returns but the
-- transaction it started is gone; and 'TransactionStillOpen' (after
-- rolling everything back) if the body began a nested transaction and
-- didn't end it.  If the rollback after a failure itself fails, the
-- connection is marked broken ('Hmssql.Errors.RollbackFailed') rather than
-- left in an unknown state, and the exception that caused the rollback
-- propagates, unless an asynchronous exception interrupted the rollback.
withTransaction :: Connection -> IO a -> IO a
withTransaction conn = runTransaction conn Nothing

-- | 'withTransaction' at the given isolation level.  The begin request
-- sets the level, and the @COMMIT@ or @ROLLBACK@ batch sets it back to
-- READ COMMITTED, the session's level at login, however the transaction
-- ends, so no round trips are added.  The session is assumed to be at
-- READ COMMITTED outside 'withTransactionLevel', and a level the
-- application set by hand is not preserved.
withTransactionLevel :: IsolationLevel -> Connection -> IO a -> IO a
withTransactionLevel level conn = runTransaction conn (Just level)

runTransaction :: Connection -> Maybe IsolationLevel -> IO a -> IO a
runTransaction conn mlevel act = mask $ \restore -> withConnectionLock conn $ do
  -- Read any unfinished response first, so the transaction state is
  -- current.  On a MARS connection the responses are the caller's to
  -- finish: with none unfinished, every ENVCHANGE of an earlier
  -- transaction has been applied, and none can arrive later and end this
  -- one in the connection's eyes.
  if isJust (connMars conn) then refuseActiveRequests conn else finishResponse conn
  active <- inTransaction conn
  when active $ throwIO TransactionAlreadyActive
  let restoreSql = case mlevel of
        Just _ -> "; SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
        Nothing -> ""
      -- Works whatever state the transaction is in: never started, still
      -- active (even if doomed), or already rolled back by the server.
      -- On a MARS connection the open responses are canceled first
      -- (Attention, acknowledgement read): a rollback beside a request
      -- still active leaves the transaction doomed on the server until
      -- that request ends.
      cleanup = do
        finishResponse conn
        void $ execute conn ("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION" <> restoreSql)
      cleanupOrBreak = cleanup `catch` \e -> do
        markBroken conn (RollbackFailed e)
        -- An asynchronous exception that interrupted the rollback (a second
        -- 'Control.Concurrent.killThread', an outer 'System.Timeout.timeout') must still reach
        -- whoever sent it, so it replaces the exception being handled, as
        -- in 'bracket'.  A failure of the rollback itself is only recorded.
        case fromException e of
          Just (_ :: SomeAsyncException) -> throwIO e
          Nothing -> pure ()

  -- The begin, read to its end: interrupted or failed part-way, the level
  -- may have been set, so the cleanup sets it back.
  beginAtLevel conn mlevel `onException` cleanupOrBreak
  -- The transaction's identity: the descriptor the server assigned it.
  started <- tdsTransaction <$> connectionContext conn

  r <- restore act `onException` cleanupOrBreak

  flip onException cleanupOrBreak $ do
    -- A commit beside an unfinished request would be refused, and lose
    -- the transaction (error 3981).
    if isJust (connMars conn) then refuseActiveRequests conn else finishResponse conn
    now <- tdsTransaction <$> connectionContext conn
    -- A pending reset would roll the COMMIT's transaction back first.
    resetPending <- readIORef (connResetPending conn)
    when (isNothing now || now /= started || resetPending) $ throwIO TransactionEndedEarly
    void $ execute conn ("COMMIT TRANSACTION" <> restoreSql)
    -- A nested begin the body didn't end: the COMMIT only lowered
    -- @@TRANCOUNT, and the work is uncommitted, its locks held.
    stillOpen <- inTransaction conn
    when stillOpen $ throwIO TransactionStillOpen
  pure r
