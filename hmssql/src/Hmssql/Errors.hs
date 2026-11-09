{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Every exception hmssql throws.
--
-- After a nonfatal 'SqlServerError', 'DecodeError', 'EncodeError', 'UnexpectedResult',
-- 'Hmssql.Transaction.TransactionError' and 'ResultAbandoned' the
-- connection is usable: the
-- response was read to its end (or the request never sent).  After
-- 'ConnectionClosed', 'ConnectionBroken' and 'ProtocolError' it is not.
-- A 'SqlServerError' of severity 20 or more also breaks the connection.
-- 'SevereError' is either, as its documentation says.  'LoginError' and
-- 'LoginRedirected' (and 'MarsNotSupported') come from 'Hmssql.Connection.connect', which then has
-- no connection to return.  'ReentrantCallback' and 'ConnectionReleased' are
-- thrown before anything is sent: after 'ReentrantCallback' the connection
-- is as it was; after 'ConnectionReleased' the connection is too, but the
-- handle that was used is not ('Hmssql.Connection.release').
module Hmssql.Errors
  ( SqlServerError (..)
  , sqlErrorNumber
  , sqlErrorMessage
  , LoginError (..)
  , loginErrorNumber
  , isTransientLoginError
  , LoginRedirected (..)
  , MarsNotSupported (..)
  , ProtocolError (..)
  , ConnectionClosed (ConnectionClosedBy, ConnectionClosed)
  , CloseReason (..)
  , connectionClosedReason
  , ConnectionBroken (..)
  , UnusableReason (..)
  , ResultAbandoned (..)
  , ReentrantCallback (..)
  , ReentrantSource (..)
  , ConnectionReleased (..)
  , SevereError (..)
  , severeErrorServerError
  , DecodeError (..)
  , EncodeError (..)
  , UnexpectedResult (..)
  ) where

import Control.Exception (Exception (..), SomeException)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Numeric (showHex)

import Hmssql.Internal.Derived
import Hmssql.Tds.Parser (DecodeError (..), ProtocolError (..), ResultAbandoned (..))
import Hmssql.Tds.Token (Done (..), ServerMessage (..), doneServerError)

-- | SQL Server reported an error (an ERROR token with severity above 10).
--
-- Severity 20 or more breaks the connection immediately, even before the
-- server closes it. Lower severities leave the connection usable.
data SqlServerError = SqlServerError
  { sqlError :: !ServerMessage
    -- ^ The error as the server sent it: number, severity, state, text,
    -- procedure and line.
  , sqlErrorStatement :: !(Maybe Text)
    -- ^ The SQL text that was executing, when known.
  }

instance Show SqlServerError where
  showsPrec p (SqlServerError a b) =
    showRecord p "SqlServerError"# ["sqlError"# := a, "sqlErrorStatement"# := b]
  {-# OPAQUE showsPrec #-}

instance Exception SqlServerError

-- | The server's error number ('msgNumber'): 2627 for a duplicate key,
-- 1205 for a deadlock victim, and so on. Login failures use
-- 'loginErrorNumber' instead.
sqlErrorNumber :: SqlServerError -> Int32
sqlErrorNumber = msgNumber . sqlError

-- | The server's message text ('msgText').
sqlErrorMessage :: SqlServerError -> Text
sqlErrorMessage = msgText . sqlError

-- | The server rejected the login.  'loginErrorNumber' says why: 18456
-- for a wrong password or an unknown login, 4060 for a database that can't
-- be opened, and so on.  'isTransientLoginError' picks out the refusals
-- that mean the server may accept the same login shortly.  hmssql never
-- retries a login itself, so wait and try again if that suits you:
--
-- > connectRetrying :: ConnectInfo -> IO Connection
-- > connectRetrying ci = go (5 :: Int)
-- >   where
-- >     go n = try (connect ci) >>= \case
-- >       Left e | n > 1, isTransientLoginError e -> threadDelay 2000000 >> go (n - 1)
-- >       Left e -> throwIO e
-- >       Right conn -> pure conn
newtype LoginError = LoginError ServerMessage

instance Show LoginError where
  showsPrec p (LoginError a) = showCon1 p "LoginError"# a
  {-# OPAQUE showsPrec #-}

instance Exception LoginError

-- | The server's error number of a refused login ('msgNumber').
loginErrorNumber :: LoginError -> Int32
loginErrorNumber (LoginError msg) = msgNumber msg

-- | Whether the login was refused for the moment rather than for good:
-- the server is shutting down (6005), or an Azure SQL database is not
-- available yet, as during a failover or a scaling operation (40613), is
-- busy (40501), or can't take the request for now (49918, 49919 and
-- 49920).  Trying the same login again after a pause may succeed.  Every
-- other refusal is 'False', including 4060, which a database that doesn't
-- exist gets too.
isTransientLoginError :: LoginError -> Bool
isTransientLoginError e = loginErrorNumber e `elem` [6005, 40613, 40501, 49918, 49919, 49920]

-- | A login redirect that was not followed.  A server may accept a login
-- but tell the client to log in to another server instead (a routing
-- ENVCHANGE, MS-TDS 2.2.7.9): Azure SQL does this under its default
-- connection policy from inside Azure, and availability group listeners do
-- it for read-only routing.  'Hmssql.Connection.connect' follows up to ten
-- redirects in a row, as SqlClient does; this is thrown for the eleventh,
-- naming where to, and for a redirect that came in plaintext after an
-- encrypted login ('Hmssql.Connection.EncryptOff', where anyone on the
-- path could have written it).  The connections are closed.
data LoginRedirected = LoginRedirected
  { redirectServer :: !Text
    -- ^ The server to connect to, as sent by the server (a host name,
    -- possibly followed by @\\instance@).
  , redirectPort :: !Word16
    -- ^ Its TCP port.
  }

instance Show LoginRedirected where
  showsPrec p (LoginRedirected a b) =
    showRecord p "LoginRedirected"# ["redirectServer"# := a, "redirectPort"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq LoginRedirected where
  LoginRedirected a b == LoginRedirected a' b' = eq a a' && b == b'
  {-# OPAQUE (==) #-}

instance Exception LoginRedirected where
  displayException LoginRedirected{..} =
    "the login was redirected to " ++ T.unpack redirectServer ++ ", port " ++ show redirectPort
      ++ ", and not followed: one redirect too many (hmssql follows ten), or one in plaintext after an encrypted login"

-- | 'Hmssql.Connection.connectMars' was set, and the server answered that
-- it doesn't do MARS.  Thrown by 'Hmssql.Connection.connect' (the
-- connection is closed) rather than connecting without it: code written
-- for several open responses would otherwise find each request
-- abandoning the last ('ResultAbandoned').
data MarsNotSupported = MarsNotSupported
  deriving stock (Eq, Show)

instance Exception MarsNotSupported where
  displayException MarsNotSupported =
    "connectMars is set, but the server does not support MARS (multiple active result sets)"

-- | The connection is gone, for the given reason.  Whatever the reason, the
-- connection cannot be used again: later requests throw 'ConnectionBroken'
-- wrapping this exception (or, after 'Hmssql.Connection.close', this
-- exception again).  'Hmssql.Connection.connect' throws it too, when the
-- server can't be reached or the connection fails during the handshake.
--
-- The pattern 'ConnectionClosed' matches any reason, so
-- @\\ConnectionClosed -> ...@ catches them all.
newtype ConnectionClosed = ConnectionClosedBy CloseReason

instance Show ConnectionClosed where
  showsPrec p (ConnectionClosedBy a) = showCon1 p "ConnectionClosedBy"# a
  {-# OPAQUE showsPrec #-}

-- | Why a connection closed.
data CloseReason
  = ClosedByServer
    -- ^ The server closed the connection (TCP EOF, or a TLS close_notify or
    -- end of stream), as it does when the session is killed or after an
    -- error of severity 20 or more.  (A killed session ends in
    -- 'TransportFailed' instead when the server is SQL Server on Windows,
    -- which resets the connection or disconnects the pipe, and behind
    -- Azure's gateway.)
  | ClosedByClient
    -- ^ 'Hmssql.Connection.close' was called, possibly from another thread
    -- while a request was in progress.
  | TransportFailed SomeException
    -- ^ Connecting, sending or receiving failed: the host name did not
    -- resolve, the TCP connect was refused, the connection was reset, a
    -- send hit a broken pipe, a TLS alert or TLS error ended the session,
    -- and so on.  Carries the underlying 'Control.Exception.IOException' or
    -- 'Network.TLS.TLSException'.

instance Show CloseReason where
  showsPrec p = \case
    ClosedByServer -> showString "ClosedByServer"
    ClosedByClient -> showString "ClosedByClient"
    TransportFailed a -> showCon1 p "TransportFailed"# a
  {-# OPAQUE showsPrec #-}

-- | Matches a 'ConnectionClosed' with any 'CloseReason'.  As an expression,
-- it is @'ConnectionClosedBy' 'ClosedByServer'@.
pattern ConnectionClosed :: ConnectionClosed
pattern ConnectionClosed <- ConnectionClosedBy _
  where
    ConnectionClosed = ConnectionClosedBy ClosedByServer

{-# COMPLETE ConnectionClosed #-}

-- | Why the connection closed.
connectionClosedReason :: ConnectionClosed -> CloseReason
connectionClosedReason (ConnectionClosedBy r) = r

instance Exception ConnectionClosed where
  displayException (ConnectionClosedBy r) = case r of
    ClosedByServer -> "the server closed the connection"
    ClosedByClient -> "the connection was closed by close"
    TransportFailed e -> "the connection failed: " ++ displayException e

-- | An earlier failure left the connection in an unknown state, so it refuses
-- further requests. The cause is inside. The original failing operation
-- reports its own exception (for example a fatal 'SqlServerError' or a
-- 'ProtocolError'); catching 'ConnectionBroken' alone does not catch it.
-- 'Hmssql.Connection.unusableReason' gives the same reason without a request.
-- After an explicit 'Hmssql.Connection.close', later requests instead
-- throw @'ConnectionClosedBy' 'ClosedByClient'@.
--
-- Interrupting a request with an asynchronous exception
-- ('Control.Concurrent.killThread', 'System.Timeout.timeout', @async@'s
-- @cancel@) while it waits for or reads its response is not a failure:
-- the statement is canceled and the connection stays usable.  One that
-- lands while the request is being sent, or while the next request
-- drains a canceled response, breaks the connection, and is the cause
-- here.  An exception of a synchronous type thrown to a thread with
-- 'Control.Concurrent.throwTo' can't be told from a failure inside
-- hmssql, and breaks the connection too.
newtype ConnectionBroken = ConnectionBroken UnusableReason

instance Show ConnectionBroken where
  showsPrec p (ConnectionBroken a) = showCon1 p "ConnectionBroken"# a
  {-# OPAQUE showsPrec #-}

instance Exception ConnectionBroken

-- | Why a connection can't be used, as far as hmssql has seen.  New
-- constructors may be added.  The first reason recorded stays, except that
-- 'Hmssql.Connection.close' is always reported.
data UnusableReason
  = Closed CloseReason
    -- ^ 'Hmssql.Connection.close' was called, the server closed the
    -- connection, or the transport failed.
  | ServerProtocolViolation String
    -- ^ The server sent TDS or SMP bytes that hmssql refuses ('ProtocolError').
  | FatalServerError ServerMessage
    -- ^ An ERROR token of severity 20 or more.
  | ServerFailedConnection Done
    -- ^ A DONE flagged DONE_SRVERROR with no ERROR token ('SevereError').  The
    -- server closes the connection after it.
  | SendFailed SomeException
    -- ^ An exception left a send part-way, such as an asynchronous one or one
    -- from a parameter's source.
  | ReadFailed SomeException
    -- ^ A read failed, so the position in the byte stream is unknown.
  | DrainFailed SomeException
    -- ^ A canceled response could not be read to its end: the drain failed
    -- or was interrupted.
  | ResetRefused (Maybe ServerMessage)
    -- ^ The server refused the request that carried a reset.  'Nothing' means
    -- a failed DONE with no message.
  | ResetFailed SomeException
    -- ^ The request that carried a reset could not be finished.
  | RollbackFailed SomeException
    -- ^ Rolling back after a failure failed or was interrupted, so the session
    -- may still hold a transaction.
  | ReaderThreadDied SomeException
    -- ^ The thread that reads from the server died.  This is a bug in hmssql.

instance Show UnusableReason where
  showsPrec p = \case
    Closed a -> showCon1 p "Closed"# a
    ServerProtocolViolation a -> showCon1 p "ServerProtocolViolation"# a
    FatalServerError a -> showCon1 p "FatalServerError"# a
    ServerFailedConnection a -> showCon1 p "ServerFailedConnection"# a
    SendFailed a -> showCon1 p "SendFailed"# a
    ReadFailed a -> showCon1 p "ReadFailed"# a
    DrainFailed a -> showCon1 p "DrainFailed"# a
    ResetRefused a -> showCon1 p "ResetRefused"# a
    ResetFailed a -> showCon1 p "ResetFailed"# a
    RollbackFailed a -> showCon1 p "RollbackFailed"# a
    ReaderThreadDied a -> showCon1 p "ReaderThreadDied"# a
  {-# OPAQUE showsPrec #-}

-- | The connection was used from inside its own info-message callback
-- ('Hmssql.Connection.connectOnInfoMessage').  The callback runs while a
-- response is being read, so it cannot start another request or read a
-- stream; collect the messages and act on them afterwards instead.
data ReentrantCallback = ReentrantCallback
  deriving stock (Show)

instance Exception ReentrantCallback

-- | A parameter or bulk source attempted a request on its own connection.
-- The source runs while that connection's message is being sent, so a request
-- from it could never be answered.  On a MARS connection it may still read a
-- stream that was opened earlier.
data ReentrantSource = ReentrantSource deriving stock (Show)
instance Exception ReentrantSource

-- | The 'Hmssql.Connection.Connection' handle was used after
-- 'Hmssql.Connection.release' (or after 'Hmssql.Connection.renew' made a
-- newer handle to the same connection): it went back to a pool, and
-- another borrower may be using the connection. Requests and reads from
-- streams it produced throw this before sending anything. Read-only
-- inspection ('Hmssql.Connection.connectionContext',
-- 'Hmssql.Connection.connectionMars' and 'Hmssql.Transaction.inTransaction'),
-- 'Hmssql.Connection.close' and 'Hmssql.Connection.renew' remain available.
-- The inspection reads cached state; it does not establish that the
-- handle is current or that the connection is usable.
data ConnectionReleased = ConnectionReleased
  deriving stock (Show)

instance Exception ConnectionReleased

-- | The server flagged the request as failed without saying why: a DONE
-- token (DONE, DONEPROC or DONEINPROC) with DONE_ERROR or DONE_SRVERROR
-- set, in a response that carried no ERROR token (an ERROR token is thrown
-- as 'SqlServerError' instead).  SQL Server answers this way when the
-- session is killed while the request runs: on Azure SQL Database in
-- particular, a killed request gets one such DONE (both flags), and the
-- gateway then resets the connection.  Microsoft's clients report it as \"a
-- severe error occurred on the current command\".
--
-- After a DONE_SRVERROR ('severeErrorServerError') the server closes the
-- connection, so the connection is broken at once ('ServerFailedConnection');
-- after a DONE_ERROR alone it may still be usable.
data SevereError = SevereError
  { severeErrorDone :: !Done
    -- ^ The DONE token that carried the flag.
  , severeErrorStatement :: !(Maybe Text)
    -- ^ The SQL text that was executing, when known.
  }

instance Show SevereError where
  showsPrec p (SevereError a b) =
    showRecord p "SevereError"# ["severeErrorDone"# := a, "severeErrorStatement"# := b]
  {-# OPAQUE showsPrec #-}

instance Exception SevereError where
  displayException e =
    "the server reported a failure without an error message (DONE status 0x"
      ++ showHex (doneStatus (severeErrorDone e)) ""
      ++ (if severeErrorServerError e then ", a server error: the connection is closed" else "")
      ++ ")"

-- | Whether the DONE carried DONE_SRVERROR, after which the server closes
-- the connection.
severeErrorServerError :: SevereError -> Bool
severeErrorServerError = doneServerError . severeErrorDone

-- | A parameter value could not be represented as a SQL Server value (or a
-- request, such as a login with very long names, could not be encoded).
newtype EncodeError = EncodeError String
  deriving stock (Eq)

instance Show EncodeError where
  showsPrec p (EncodeError a) = showCon1 p "EncodeError"# a
  {-# OPAQUE showsPrec #-}

instance Exception EncodeError

-- | The result shape didn't match the query function used, e.g. 'Hmssql.Query.query1'
-- returned no rows.
newtype UnexpectedResult = UnexpectedResult String

instance Show UnexpectedResult where
  showsPrec p (UnexpectedResult a) = showCon1 p "UnexpectedResult"# a
  {-# OPAQUE showsPrec #-}

instance Exception UnexpectedResult
