{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# OPTIONS_HADDOCK not-home #-}

-- | Connection state, packet I/O, and the incremental token reader.
--
-- Everything here is protected by the connection's reentrant mutex.  A request
-- creates an 'ActiveResponse'; tokens are pulled from it one at a time, and
-- starting a new request first cancels and drains any unfinished response so
-- the connection can never be left mid-message.
--
-- A request and its response travel on a 'Session'.  A connection has one,
-- 'connPrimary', unless it negotiated MARS ('connMars'): then each request
-- takes an SMP session of its own ("Hmssql.Tds.Smp"), so several responses
-- can be open at once, and a new request leaves the others alone.  The
-- backend, the transport, the protocol state ('connContext', the transaction
-- descriptor included), the mutex and the broken flag stay the
-- connection's: the sessions are one SQL session on the server.
--
-- Interruptions (asynchronous exceptions) are handled by two rules:
--
-- * A send that doesn't complete breaks the connection ('sendBytes'): the
--   server may hold part of a message, and nothing here tries to recover
--   from that.
--
-- * A read that is interrupted leaves the connection usable ('nextToken'):
--   an Attention is sent at once, which cancels the statement, and the next
--   request drains the canceled response up to the server's
--   acknowledgement ('finishResponse').  If that drain is itself
--   interrupted, the connection is broken too.
--
-- A 'Connection' value is a handle, a lease on the connection: every field
-- but 'connLease' is shared or immutable, so a record copy is another handle
-- to the same connection.  'Hmssql.Connection.release' invalidates the
-- handle it was given ('invalidateLease') and 'renewLease' makes a new one;
-- everything that takes the lock, and every row a stream yields, checks the
-- handle first ('checkLease').
--
-- Applications use "Hmssql.Connection"; nothing here is stable.
module Hmssql.Connection.Internal
  ( Connection (..)
  , Transport (..)
  , Session (..)
  , SmpSession (..)
  , SmpLink (..)
  , Mars (..)
  , ActiveResponse (..), Cancellation (..)
  , ReadState (..), ReadPosition (..)
  , newConnection
  , startReader
  , enableMars
  , allSessions
  , closeConnection
  , releaseTransport
  , closeSocket
  , closeSocketWith
  , socketCloser
  , connectionContext
  , connectionMars
  , withConnectionLock
  , checkLease
  , invalidateLease
  , renewLease
  , renewUsable
  , checkNotBroken
  , refuseUnusable
  , currentUnusableReason
  , markBroken
  , reasonFor
  , resetFailure
  , throwSevere
  , transportError
  , recvSome
  , recvExactly
  , newBufferedRecv
  , SendGather (..)
  , Gathered (..)
  , gatheredSend
  , sendBytes
  , sendFramed
  , sendPackets
  , readPacket
  , sendMessage
  , runBody
  , startRequest
  , sourceAction
  , bytesBody
  , startRequestFor
  , startStreamingRequest
  , withReservedSession
  , requestReset
  , resetWithSessionSetup
  , RowRead (..), newRowRead, wholeRows, discardRows, drainingRows
  , nextStepReversed
  , RowBatch (..)
  , ResponseStep (..)
  , nextStep
  , readPiece
  , nextToken
  , checkCurrent
  , finishResponse
  , cancelActiveResponse
  , readingToEnd
  , abandonResponse
  , drainCancelled
  , busyStatements
  , drainActiveResponse
  , readWholeMessage
  , readWholeMessageUpTo
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOnWithUnmask, killThread, mkWeakThreadId, myThreadId, threadCapability)
import GHC.Conc (labelThread)
import GHC.Exts (keepAlive#)
import GHC.IO (IO (..))
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, unless, void, when)
import Streaming (Stream, inspect)
import qualified Streaming
import Hmssql.Internal.Derived
import Hmssql.Tds.Reader
import qualified Hmssql.Tds.Value as V
import qualified Hmssql.Tds.Parser as P
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import Data.Int (Int32)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Extra as BB
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Unsafe as BU
import Data.IORef
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word32, Word8)
import Foreign.ForeignPtr (ForeignPtr, plusForeignPtr, withForeignPtr)
import Foreign.Marshal.Utils (copyBytes, moveBytes)
import Foreign.Ptr (plusPtr)
import qualified Network.TLS as TLS
import System.Mem.Weak (Weak, deRefWeak)

import Hmssql.Connection.Backend
import Hmssql.Connection.Locking
import Hmssql.Errors
import Hmssql.Tds.Client (sqlBatchBuilder, sqlBatchProblem)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.PacketWriter
import Hmssql.Tds.Smp
import Hmssql.Tds.Token

-- | How the connection's bytes go to the backend: as they are, or through
-- a TLS session.
data Transport
  = TransportPlain !Backend
  | TransportTls !TLS.Context

-- | What one request at a time travels on: the connection itself, or under
-- MARS one of its SMP sessions.  A session is /busy/ while it has a current
-- response, that is, until the response's end has been read ('StepEnd'),
-- whether by its consumer or by a drain after it was canceled.
data Session = Session
  { sessResponse :: !(IORef (Maybe ActiveResponse))
    -- ^ The response being read on the session, if any.
  , sessGeneration :: !(IORef Int)
    -- ^ Counts the session's responses; one whose 'arGeneration' differs
    -- from its session's current response's was superseded or canceled.
  , sessRecvBuffer :: !(IORef [B.ByteString])
    -- ^ Without SMP: bytes read from the transport but not yet consumed
    -- as a whole packet: non-empty chunks, oldest first.  Kept as they
    -- arrived, so only a packet split between chunks is copied
    -- ('takeBytes').
  , sessSmp :: !(Maybe SmpSession)
    -- ^ The SMP session, on a MARS connection once SMP has started.
  }

-- | An SMP session's state on the side of the threads that use the
-- connection.
data SmpSession = SmpSession
  { smpSid :: !Word16
  , smpLink :: !SmpLink
  , smpSendSeq :: !(IORef Word32)
    -- ^ The sequence number of the last DATA packet sent (SeqNumForSend).
    -- Written under the send lock.
  , smpAdvertised :: !(IORef Word32)
    -- ^ The window last sent to the server.
  }

-- | An SMP session's state shared with the reader thread, which refers to
-- nothing else of the session (see 'startReader').
data SmpLink = SmpLink
  { linkIncoming :: !(TQueue B.ByteString)
    -- ^ The TDS packets received, whole, in order.  At most a window of
    -- them: the server sends no further than it was told.
  , linkSendHighWater :: !(TVar Word32)
    -- ^ The highest sequence number the server accepts (HighWaterForSend):
    -- the window of the last packet received on the session.
  , linkRecvSeq :: !(TVar Word32)
    -- ^ The sequence number of the last DATA packet received
    -- (SeqNumForRecv).
  , linkRecvHighWater :: !(TVar Word32)
    -- ^ The highest sequence number accepted from the server
    -- (HighWaterForRecv): the packets consumed plus the window.  Raised
    -- by the consumer before it tells the server.
  , linkEoms :: !(TVar Int)
    -- ^ How many packets marked end-of-message have been received.
  , linkClosing :: !(TVar Bool)
    -- ^ A FIN was sent; the server's FIN in reply frees the identifier.
  }

-- | What a MARS connection has beyond a plain one.
data Mars = Mars
  { marsRegistry :: !(TVar (IntMap.IntMap SmpLink))
    -- ^ The sessions the server knows, by identifier: open, or closing (a
    -- FIN sent and not yet answered).  Shared with the reader thread.
  , marsOpen :: !(IORef (IntMap.IntMap Session))
    -- ^ The open sessions.
  , marsReserved :: !(IORef (Maybe Session))
    -- ^ The session every request is sent on for now
    -- ('withReservedSession').
  , marsWindow :: !Word32
    -- ^ How many packets the server may send ahead of what was consumed,
    -- on each session.
  , marsResetInFlight :: !(IORef (Maybe ActiveResponse))
    -- ^ The response to a request that carried RESETCONNECTION, until its
    -- leading ENVCHANGEs have been read: no request starts before
    -- ('awaitReset').
  }

-- | The server's reply to one request.
data ActiveResponse = ActiveResponse
  { arGeneration :: !Int
  , arSession :: !Session
    -- ^ What the request was sent on.
  , arStatement :: !(Maybe Text)
    -- ^ The request's SQL text, when known: to name an unfinished response.
  , arEomBase :: !Int
    -- ^ The session's 'linkEoms' when the request was sent: the response
    -- has fully arrived once the count is past it.
  , arCarriedReset :: !Bool
    -- ^ The request carried RESETCONNECTION.
  , arSawResetAck :: !(IORef Bool)
    -- ^ The server's acknowledgement of a reset was read in this response.
  , arInConsumer :: !(IORef Bool)
    -- ^ Reading this response recursively from its value consumer is refused.
  , arCancellation :: !(IORef Cancellation)
    -- ^ Cancellation and abandonment have one progression, rather than
    -- independent flags admitting contradictory states.
  , arReplay :: !(IORef [Token])
    -- ^ Tokens read ahead of the consumer by 'awaitReset', in order, with
    -- their effects already applied: the consumer is given them first.
  , arState :: !(IORef ReadState)
    -- ^ What has been received but not yet returned.
  , arResultSet :: !(IORef (Maybe ResultSetInfo))
    -- ^ The columns of the most recent COLMETADATA, compiled for the row
    -- recipes and decoders.
  , arSawFinalDone :: !(IORef Bool)
  }

data Cancellation = Running | Abandoned | AttentionSent | AttentionAcknowledged
  deriving stock (Eq, Show)

attentionWasSent :: Cancellation -> Bool
attentionWasSent AttentionSent = True
attentionWasSent AttentionAcknowledged = True
attentionWasSent _ = False

markAbandoned :: ActiveResponse -> IO ()
markAbandoned ar = modifyIORef' (arCancellation ar) $ \case
  Running -> Abandoned
  state -> state

-- | What has been received but not yet returned: whether the message's last
-- packet has arrived, and where the parse has got to.
data ReadState = ReadState
  { readFinalPacket :: !Bool
  , readPosition :: !ReadPosition
  }

-- Where the response's parse has got to.  The rest of the parse is the state, so
-- an interrupted read, a later pull and a drain all go on from the same value,
-- and nothing has to be rewound or decoded twice; a column and a phase stored
-- here instead would need a parser of their own for the drain.
data ReadPosition
  = AtToken !B.ByteString
    -- ^ Between tokens, with the unconsumed payload.
  | Reading (Stream P.Await IO ReadEvent)
    -- ^ Normalized suspension, ready for a packet or a consumer outcome.
  | Parked !B.ByteString (P.Parser ())
    -- ^ A generic cell pull returned; the recipe drains its remaining row.

-- A completed suspended read either supplies a token, delivers to its typed
-- row recipient, or reports a skipped row. Every event includes unread bytes.
--
-- The response outlives any one decoder, and queryMulti changes decoder between
-- result sets, so a suspension stored here can't mention the row's type.  So a
-- suspended row ends in 'ReadRow', whose action puts the result in the slot of the
-- 'RowRead' that started it.  A row that completes without suspending never touches
-- the slot; it comes back from 'P.runParser' directly.
data ReadEvent
  = ReadToken !Token !B.ByteString
  | ReadRow (IO ()) !B.ByteString
  | SkippedRow !B.ByteString

-- | An open connection to a server.  It belongs to one thread at a time;
-- "Hmssql.Connection" has the rules.
data Connection = Connection
  { connBackend :: !Backend
    -- ^ The byte stream the connection runs on: a socket, or on Windows a
    -- pipe ("Hmssql.Connection.Backend").
  , connTransport :: !(IORef Transport)
  , connPrimary :: !Session
    -- ^ The session of a connection without MARS, and of any connection
    -- until it has logged in.  Under MARS, the SMP session 0.
  , connMars :: !(Maybe Mars)
    -- ^ Set once SMP has started ('enableMars').
  , connAlive :: !(IORef ())
    -- ^ What the finalizer that stops the reader thread and closes the
    -- backend is attached to ('startReader'): every handle reaches it, and
    -- the reader thread doesn't.
  , connIncoming :: !(TMVar B.ByteString)
    -- ^ Chunks from the reader thread, once it is running (without MARS;
    -- under MARS it puts packets in their sessions' 'linkIncoming').
  , connEnded :: !(TVar (Maybe SomeException))
    -- ^ Why the transport can no longer be used: set when the reader thread
    -- exits (to the 'ConnectionClosed' it saw, or 'ConnectionBroken' if it
    -- died of anything else), or by 'closeConnection'.  Reads see it once
    -- 'connIncoming' is drained, or at once after 'closeConnection'.
  , connSendLock :: !(MVar ())
    -- ^ Held while sending, so 'closeConnection' can tell whether it may say
    -- goodbye to the server.
  , connSendGather :: !SendGather
    -- ^ The TLS records of the message being sent, gathered into socket
    -- writes ('gatheredSend').
  , connReader :: !(IORef (Maybe (Weak ThreadId)))
    -- ^ The reader thread, once it is running ('startReader').  Weak: a
    -- 'ThreadId' keeps the thread's stack alive (32 KiB once it has grown)
    -- even after the thread has finished, which a closed connection that is
    -- still referenced shouldn't.  A running reader is reachable anyway
    -- (it is blocked on the socket or on 'connIncoming').
  , connContext :: !(IORef TdsContext)
  , connMutex :: !Mutex
  , connBroken :: !(IORef (Maybe UnusableReason))
  , connResetPending :: !(IORef Bool)
    -- ^ Set by 'requestReset'; consumed by the next SQLBatch or RPC.
  , connPinReader :: !Bool
    -- ^ Whether 'startReader' pins the reader thread to the capability
    -- of the thread that connects ('Hmssql.Connection.connectPinReader').
  , connSessionSetup :: ![Text]
    -- ^ Run after login (as one batch), and again after each reset.
  , connValueAllocAhead :: !Int
    -- ^ How far ahead of its bytes a large value's buffer is allocated
    -- ('Hmssql.Connection.connectValueAllocAhead').
  , connOnInfo :: !(ServerMessage -> IO ())
  , connOnEnvChange :: !(EnvChange -> IO ())
  , connInSource :: !(IORef Bool)
  , connInCallback :: !(IORef Bool)
    -- ^ A callback is running.  It runs with the lock held, in the middle of
    -- reading a response, so it must not use the connection.
  , connLease :: !Int
    -- ^ This handle's lease: the only field not shared between handles
    -- to the connection.
  , connCurrentLease :: !(IORef Int)
    -- ^ The connection's current lease.  A handle whose 'connLease'
    -- differs was released, or superseded by 'renewLease' ('checkLease').
  }

-- | A connection with no session setup; set 'connSessionSetup' afterwards.
newConnection :: Backend -> TdsContext -> (ServerMessage -> IO ()) -> IO Connection
newConnection backend ctx onInfo = do
  connTransport <- newIORef (TransportPlain backend)
  connPrimary <- newSession Nothing
  connAlive <- newIORef ()
  connIncoming <- newEmptyTMVarIO
  connEnded <- newTVarIO Nothing
  connSendLock <- newMVar ()
  connSendGather <- newSendGather
  connReader <- newIORef Nothing
  connContext <- newIORef ctx
  connMutex <- newMutex
  connBroken <- newIORef Nothing
  connInCallback <- newIORef False
  connInSource <- newIORef False
  connResetPending <- newIORef False
  connCurrentLease <- newIORef 0
  pure Connection
    { connBackend = backend
    , connSessionSetup = []
    , connPinReader = False
    , connValueAllocAhead = lobAllocAhead
    , connOnInfo = onInfo
    , connOnEnvChange = \_ -> pure ()
    , connLease = 0
    , connMars = Nothing
    , ..
    }

newSession :: Maybe SmpSession -> IO Session
newSession sessSmp = do
  sessResponse <- newIORef Nothing
  sessGeneration <- newIORef 0
  sessRecvBuffer <- newIORef []
  pure Session{..}

-- | The protocol state negotiated for the connection: the TDS version, the
-- packet size the server granted, whether a transaction is open, the
-- session's collation.
connectionContext :: Connection -> IO TdsContext
connectionContext = readIORef . connContext

-- | Whether the connection negotiated MARS ('Hmssql.Connection.connectMars'):
-- several responses can be open on it at once, and a new request leaves an
-- open stream alone.  For code that is handed a 'Connection' without the
-- 'Hmssql.Connection.ConnectInfo' it was opened with.
connectionMars :: Connection -> Bool
connectionMars = isJust . connMars

-- | Hold the connection's reentrant lock.  Refuses (with 'ReentrantCallback')
-- a callback's attempt to use the connection: the callback's thread already
-- holds the lock, so the attempt would otherwise interleave with the response
-- being read.  Refuses a released handle too ('checkLease'), once the lock
-- is held, so a handle released while this call waited for the lock is
-- refused.
withConnectionLock :: Connection -> IO a -> IO a
withConnectionLock conn act = withMutex (connMutex conn) $ do
  inCallback <- readIORef (connInCallback conn)
  when inCallback $ throwIO ReentrantCallback
  source <- readIORef (connInSource conn)
  when (source && isNothing (connMars conn)) (throwIO ReentrantSource)
  checkLease conn
  act
-- Opaque, so that GHC doesn't specialize the lock, the lease check and the
-- callback check into each caller's action: called, a request allocates 128
-- bytes less (100 executes against the mock server, 1,213,896 bytes in place
-- of 1,226,696, GHC 9.12.4, 2026-11-04).
{-# OPAQUE withConnectionLock #-}

-- | User code producing request data may not start a request on this connection.
sourceAction :: Connection -> IO a -> IO a
sourceAction conn action = mask_ $ bracket
  (atomicModifyIORef' (connInSource conn) (\old -> (True, old)))
  (writeIORef (connInSource conn)) (const action)

-- | Throw 'ConnectionReleased' if this handle is not the connection's
-- current one: it was released, or 'renewLease' made a newer one.
checkLease :: Connection -> IO ()
checkLease conn = do
  current <- readIORef (connCurrentLease conn)
  when (current /= connLease conn) $ throwIO ConnectionReleased

-- | Make every existing handle to the connection stale.  The caller holds
-- the lock.
invalidateLease :: Connection -> IO ()
invalidateLease conn = atomicModifyIORef' (connCurrentLease conn) (\l -> (l + 1, ()))

-- | A new handle to the connection, making every existing one stale.  Its
-- argument may be stale (that is what it is for), so it takes the mutex
-- directly, not 'withConnectionLock': it waits for a request in progress
-- on another handle rather than cutting in.
renewLease :: Connection -> IO Connection
renewLease conn = withMutex (connMutex conn) $ do
  lease <- atomicModifyIORef' (connCurrentLease conn) (\l -> (l + 1, l + 1))
  pure conn { connLease = lease }

-- | 'renewLease', after throwing what a request would throw if the connection
-- is unusable.  The check comes first, so a refusal leaves the lease alone.
renewUsable :: Connection -> IO Connection
renewUsable conn = withMutex (connMutex conn) $ refuseUnusable conn >> renewLease conn

-- | Throws 'ConnectionBroken' after a failure, or @'ConnectionClosedBy'
-- 'ClosedByClient'@ after 'closeConnection'.
checkNotBroken :: Connection -> IO ()
checkNotBroken conn = do
  readTVarIO (connEnded conn) >>= \case
    Just e | closedByClient e -> throwIO e
    _ -> pure ()
  readIORef (connBroken conn) >>= \case
    Nothing -> pure ()
    Just r -> throwIO (ConnectionBroken r)

closedByClient :: SomeException -> Bool
closedByClient e = case fromException e of
  Just (ConnectionClosedBy ClosedByClient) -> True
  _ -> False

-- | Throw the connection's reason if it is broken, closed by the client,
-- or ended by the server (which marks it broken too), as a request on it
-- would.  For the functions that would otherwise return normally with
-- nothing to do ('cancelActiveStatement', the transaction functions'
-- checks), so that a normal return says the connection is not known to
-- be unusable.
refuseUnusable :: Connection -> IO ()
refuseUnusable conn = do
  checkNotBroken conn
  readTVarIO (connEnded conn) >>= mapM_ (\e -> markBroken conn (reasonFor ReaderThreadDied e) >> throwIO e)

-- | Why the connection is known to be unusable, as 'refuseUnusable' would
-- throw it.  It reads what is recorded and leaves it as it is.
currentUnusableReason :: Connection -> IO (Maybe UnusableReason)
currentUnusableReason conn = withMutex (connMutex conn) $ do
  ended <- readTVarIO (connEnded conn)
  broken <- readIORef (connBroken conn)
  pure $ case ended of
    Just e | closedByClient e -> Just (Closed ClosedByClient)
    _ -> broken <|> (reasonFor ReaderThreadDied <$> ended)

-- | Record why the connection is unusable.  The first reason stays.
markBroken :: Connection -> UnusableReason -> IO ()
markBroken conn reason = modifyIORef' (connBroken conn) (maybe (Just reason) Just)

-- | The reason an exception gives by its own type, whatever was going on; the
-- function says what to call any other exception.
reasonFor :: (SomeException -> UnusableReason) -> SomeException -> UnusableReason
reasonFor other e
  -- Don't nest: a read that fails because the reader died already says so.
  | Just (ConnectionBroken r) <- fromException e = r
  | Just (ConnectionClosedBy r) <- fromException e = Closed r
  | Just (ProtocolError m) <- fromException e = ServerProtocolViolation m
  | otherwise = other e

-- | The reason for a failure of the request that carried a reset: the server's
-- refusal, or a request that could not be finished.
resetFailure :: SomeException -> UnusableReason
resetFailure e
  | Just err <- fromException e = ResetRefused (Just (sqlError err))
  | Just (SevereError{}) <- fromException e = ResetRefused Nothing
  | otherwise = reasonFor ResetFailed e

-- | Throw 'SevereError' for a failed DONE.  After DONE_SRVERROR the server
-- closes the connection, so it is broken from here on, as after a severity 20
-- error, without waiting for the reader thread to see the close.
throwSevere :: Connection -> Done -> Maybe Text -> IO a
throwSevere conn d stmt = do
  when (doneServerError d) $ markBroken conn (ServerFailedConnection d)
  throwIO (SevereError d stmt)

-- | Fail the connection if the action throws anything that leaves the
-- byte stream in an unknown position.  Async exceptions are the intended
-- interruption mechanism and leave the buffers consistent, so they don't.
breakOnFailure :: Connection -> IO a -> IO a
breakOnFailure conn act = act `catch` \e -> do
  unless (isBenign e) $ markBroken conn (reasonFor ReadFailed e)
  throwIO e
  where
    isBenign e =
      isA (Proxy @ResultAbandoned) e || isA (Proxy @SqlServerError) e
        || isA (Proxy @AsyncException) e || isA (Proxy @SomeAsyncException) e
    isA :: forall ex. Exception ex => Proxy ex -> SomeException -> Bool
    isA _ e = case fromException e :: Maybe ex of
      Just _ -> True
      Nothing -> False

------------------------------------------------------------------------------
-- Byte-level I/O

-- | The typed form of a synchronous exception from the transport: an
-- 'IOException' or 'TLS.TLSException' becomes 'ConnectionClosed'.  TLS
-- reports the end of the stream (after a TCP EOF without close_notify, as
-- when the server kills the session) as an error, but it is a close like any
-- other.  Anything else, async exceptions included, is returned unchanged.
transportError :: SomeException -> SomeException
transportError e
  | Just (_ :: SomeAsyncException) <- fromException e = e
  | Just (_ :: ConnectionClosed) <- fromException e = e
  | Just tls <- fromException e =
      toException $ ConnectionClosedBy $ if tlsEof tls then ClosedByServer else TransportFailed e
  | Just (_ :: IOException) <- fromException e = toException $ ConnectionClosedBy (TransportFailed e)
  | otherwise = e
  where
    tlsEof = \case
      TLS.PostHandshake TLS.Error_EOF -> True
      TLS.Terminated _ _ TLS.Error_EOF -> True
      TLS.Uncontextualized TLS.Error_EOF -> True
      _ -> False

-- | Read from the transport directly.  Only safe before 'startReader', since an
-- async exception inside @TLS.recvData@ corrupts the TLS session.  Throws
-- 'ConnectionClosed' on EOF or a transport failure.
recvDirect :: Connection -> IO B.ByteString
recvDirect conn = recvTransport (connTransport conn)

recvTransport :: IORef Transport -> IO B.ByteString
recvTransport transport = do
  bs <- recv `catch` (throwIO . transportError)
  when (B.null bs) $ throwIO ConnectionClosed
  pure bs
  where
    recv = readIORef transport >>= \case
      TransportPlain backend -> recvFresh backend
      TransportTls ctx -> TLS.recvData ctx

-- | Receive into a buffer of its own: for the few reads of a plaintext
-- handshake.  Empty at the end of the stream.
recvFresh :: Backend -> IO B.ByteString
recvFresh backend = do
  fp <- BI.mallocByteString recvBufferSize
  n <- withForeignPtr fp (\p -> backendRecv backend p recvBufferSize)
  pure (BI.BS fp (max 0 n))

-- | Move transport reads onto a dedicated thread.  Consumers then block on a
-- 'TMVar', which can be interrupted without losing bytes or TLS state.  Call
-- once the transport is final (after login).
--
-- When the reader stops, it records why in 'connEnded': the
-- 'ConnectionClosed' that 'recvDirect' threw, or 'ConnectionBroken' if it
-- died of anything else (it is never interrupted except by
-- 'closeConnection', which records its own reason first, or by the
-- finalizer below).  It never passes an exception on as data, so a reader
-- killed by 'closeConnection' doesn't look to the thread waiting for a
-- response as if that thread itself had been killed.
--
-- The thread refers to the transport, 'connIncoming' and 'connEnded' only,
-- never to the whole 'Connection': it is always reachable (blocked in a
-- read), so if it kept the connection reachable, a connection dropped
-- without 'close' would never be found garbage, and the finalizer below,
-- which stops the thread and closes the socket, would never run.
--
-- Small chunks are copied into shared buffers ('copyIntoArena') before
-- they are passed on.
--
-- On a MARS connection ('enableMars' came first) the thread cuts what it
-- receives into SMP packets instead and hands each session its TDS
-- packets ('demultiplex'); it then refers to the session registry, and
-- still not to the connection.
startReader :: Connection -> IO ()
startReader conn = do
  arena <- newIORef emptyArena
  let !transport = connTransport conn
      !incoming = connIncoming conn
      !endedVar = connEnded conn
      !backend = connBackend conn
      receive = readIORef transport >>= \case
        TransportPlain b -> recvIntoArena b arena
        TransportTls _ -> recvTransport transport >>= copyIntoArena arena
      plainLoop = do
        bs <- receive
        atomically $ putTMVar incoming bs
        plainLoop
      !loop = case connMars conn of
        Nothing -> plainLoop
        Just Mars{marsRegistry = !registry} -> demultiplex registry receive
      ended e = atomically $ do
        prev <- readTVar endedVar
        case prev of
          Just _ -> pure ()
          Nothing -> writeTVar endedVar $ Just $ if
            | Just (_ :: ConnectionClosed) <- fromException e -> e
            -- What 'demultiplex' found wrong with the server's packets.
            | Just (_ :: ProtocolError) <- fromException e -> e
            | otherwise -> toException (ConnectionBroken (ReaderThreadDied e))
  -- Unmasked whatever the caller's masking state ('connect' may run inside
  -- 'mask' or 'uninterruptibleMask'): the thread is stopped by 'killThread'
  -- ('stopReader'), which would otherwise wait for it (forever, if
  -- uninterruptibly masked).
  --
  -- Unbound by default: wherever the scheduler puts it, and free to move.
  -- With 'connPinReader', on the capability of the thread that connects:
  -- when that is the thread that then waits for the responses, a chunk
  -- the reader passes on wakes it without a message to another
  -- capability (with @+RTS -N@ on 32 hardware threads, a local round trip took 40
  -- to 80 us less, 'Bench.Live' "round trip"), but the readers of every
  -- connection opened by one thread (a pool's) then share that
  -- capability, and they decrypt and copy what they receive.
  let fork :: ((forall a. IO a -> IO a) -> IO ()) -> IO ThreadId
      fork act
        | connPinReader conn = do
            (cap, _) <- threadCapability =<< myThreadId
            forkOnWithUnmask cap act
        | otherwise = forkIOWithUnmask act
  tid <- mask_ $ fork $ \unmask ->
    try (unmask loop) >>= either ended (\() -> pure ())
  -- Named for 'GHC.Conc.listThreads' users and the eventlog.
  labelThread tid "hmssql: connection reader"
  weakTid <- mkWeakThreadId tid
  writeIORef (connReader conn) (Just weakTid)
  -- If the connection is dropped without 'close', don't leak the thread or
  -- the session.  (Closing a backend twice is harmless.)  As in
  -- 'closeConnection', the reader is stopped before the backend is closed.
  -- No thread is sending then: 'sendBytes' keeps the connection
  -- reachable until it is done, so the finalizer can't run before.
  -- The finalizer refers to the backend, never to the connection.
  _ <- mkWeakIORef (connAlive conn) (stopReader backend weakTid >> backendClose backend)
  pure ()

-- | The reader thread's loop on a MARS connection: cut the bytes received
-- into SMP packets (a header may straddle two chunks) and act on each.
-- Returns never; throws 'ConnectionClosed' when the server closes the
-- connection, or a session the client didn't close, and 'ProtocolError'
-- when a packet breaks the protocol.
--
-- A packet is handled in one STM transaction, which never blocks: the
-- server sends no further than the window it was given, so the queues
-- are bounded by it, and a packet beyond the window is an error.
demultiplex :: TVar (IntMap.IntMap SmpLink) -> IO B.ByteString -> IO a
demultiplex registry receive = go B.empty
  where
    go buf
      | B.length buf < smpHeaderLength = more buf
      | BU.unsafeHead buf /= smpIdentifier = violation "a packet that is not an SMP packet"
      | len < smpHeaderLength || len > smpHeaderLength + 65535 = violation "an SMP packet of an impossible length"
      | smpFlags hdr /= smpFlagWord SmpData && len /= smpHeaderLength = violation "a control packet with a payload"
      | B.length buf < len = more buf
      | otherwise = do
          atomically (packet hdr (BU.unsafeTake len buf)) >>= mapM_ throwIO
          go (BU.unsafeDrop len buf)
      where
        hdr = readSmpHeader buf
        len = fromIntegral (smpLength hdr) :: Int

    -- A packet split between chunks is copied (as 'takeBytes' does).
    more buf = do
      bs <- receive
      go (if B.null buf then bs else buf <> bs)

    violation :: String -> IO a
    violation what = throwIO $ ProtocolError $ "SMP: the server sent " ++ what

    wrong what = pure $ Just $ toException $ ProtocolError $ "SMP: the server sent " ++ what

    packet :: SmpHeader -> B.ByteString -> STM (Maybe SomeException)
    packet hdr bytes = do
      links <- readTVar registry
      case IntMap.lookup (fromIntegral (smpSession hdr)) links of
        Nothing -> wrong ("a packet for session " ++ show (smpSession hdr) ++ ", which is not open")
        Just link -> do
          -- The window only grows.
          highWater <- readTVar (linkSendHighWater link)
          let grown = fromIntegral (smpWindow hdr - highWater) :: Int32
          if grown < 0
            then wrong "a window smaller than its last"
            else do
              when (grown > 0) $ writeTVar (linkSendHighWater link) (smpWindow hdr)
              if
                | flags == smpFlagWord SmpData -> dataPacket link
                | flags == smpFlagWord SmpAck -> pure Nothing
                | flags == smpFlagWord SmpFin -> do
                    closing <- readTVar (linkClosing link)
                    if closing
                      then Nothing <$ writeTVar registry (IntMap.delete (fromIntegral (smpSession hdr)) links)
                      -- The server closes a session on its own only as it
                      -- closes the connection (a KILL, a severity 20 error).
                      else pure (Just (toException (ConnectionClosedBy ClosedByServer)))
                | otherwise -> wrong ("a packet with flags " ++ show flags)
      where
        flags = smpFlags hdr
        tds = BU.unsafeDrop smpHeaderLength bytes
        dataPacket link = do
          received <- readTVar (linkRecvSeq link)
          accepted <- readTVar (linkRecvHighWater link)
          if
            | smpSeqNum hdr /= received + 1 -> wrong "a DATA packet out of sequence"
            | (fromIntegral (accepted - smpSeqNum hdr) :: Int32) < 0 -> wrong "a DATA packet beyond the window"
            -- One TDS packet, whole, in each.
            | B.length tds < headerLength || fromIntegral (headerPacketLength (readHeader tds)) /= B.length tds ->
                wrong "a DATA packet that is not one TDS packet"
            | otherwise -> do
                writeTVar (linkRecvSeq link) (smpSeqNum hdr)
                when (headerStatus (readHeader tds) `hasStatus` statusEndOfMessage) $
                  modifyTVar' (linkEoms link) (+ 1)
                writeTQueue (linkIncoming link) tds
                pure Nothing

-- | Stop the reader thread, unless it has finished and been collected:
-- end its receive ('backendStopReceiving'), then kill it.  Where the
-- receive waits in GHC's I/O manager the first does nothing and the
-- exception ends the wait; where a receive can't be interrupted the first
-- ends it, and the exception finds the thread on its way out.
stopReader :: Backend -> Weak ThreadId -> IO ()
stopReader backend weakTid = do
  backendStopReceiving backend
  deRefWeak weakTid >>= mapM_ killThread

-- | A buffer that received chunks are copied into, and how much of it is
-- used.  Only the reader thread writes to it, and only past what it has
-- handed out, so the slices handed out never change.
data Arena = Arena !(ForeignPtr Word8) !Int

emptyArena :: Arena
emptyArena = Arena nullForeignPtr arenaSize
  where
    BI.BS nullForeignPtr _ = B.empty

-- | Big enough that GHC allocates it as a large object, in blocks of its own.
arenaSize :: Int
arenaSize = 32768

-- | A copy of a small chunk, in an arena shared with the chunks received
-- before and after it; a chunk of 4096 bytes or more is returned unchanged.
--
-- Over TLS, @TLS.recvData@ returns a record at a time, and SQL Server sends
-- each packet as a record of its own.  With small packets, the plaintext of
-- a record is a small pinned object, allocated in the same blocks as the
-- short-lived objects tls and crypton allocate per record, many of which
-- carry a finalizer (@ScrubbedBytes@).  GHC frees a block of small pinned
-- objects only once all of them are dead, and the chunks of a large token
-- stay live until the whole token has been read ('arState').  So the chunks
-- kept their blocks, and the finalizable objects in them (about four per
-- record), alive and promoted, and those could only be found dead by a
-- major GC, which keeps them for their finalizers: after reading a 32 MiB
-- value with 512-byte packets, about 180 MiB was still live at the first
-- major GC, and freed only at the second.  Copied into an arena, the chunks
-- keep nothing else alive.  (Copying each chunk on its own would put the
-- copy in the same blocks.)  The cost: a chunk still referred to (say, the
-- rest of the last packet read) keeps its whole arena alive.
copyIntoArena :: IORef Arena -> B.ByteString -> IO B.ByteString
copyIntoArena ref bs@(BI.BS src len)
  | len >= 4096 = pure bs
  | otherwise = do
      Arena fp0 used0 <- readIORef ref
      (fp, used) <-
        if used0 + len <= arenaSize
          then pure (fp0, used0)
          else (,0) <$> BI.mallocByteString arenaSize
      -- A bounded memcpy: within unsafeWithForeignPtr's contract.
      BI.unsafeWithForeignPtr fp $ \dst -> BI.unsafeWithForeignPtr src $ \s ->
        copyBytes (dst `plusPtr` used) s len
      writeIORef ref (Arena fp (used + len))
      pure (BI.BS (fp `plusForeignPtr` used) len)

-- | Receive from the backend straight into the free end of the arena
-- (a new one when less than 'minRecvSpace' is left): a slice of it,
-- neither allocated nor copied per call.  (@Socket.recv sock 32768@
-- allocated 32 KiB every time, and copied what arrived when it was less:
-- most of a small request's allocation.)  Throws like 'recvTransport'.
--
-- The buffer is kept alive over the receive with 'withForeignPtr'
-- (@keepAlive#@), never @unsafeWithForeignPtr@: a read blocks
-- for as long as the server takes, can fail, and is where the reader
-- thread is interrupted, none of which the latter's contract (a
-- continuation that can't diverge) allows.
recvIntoArena :: Backend -> IORef Arena -> IO B.ByteString
recvIntoArena backend ref = do
  Arena fp0 used0 <- readIORef ref
  (fp, used) <-
    if arenaSize - used0 >= minRecvSpace
      then pure (fp0, used0)
      else (,0) <$> BI.mallocByteString arenaSize
  n <- withForeignPtr fp (\p -> backendRecv backend (p `plusPtr` used) (arenaSize - used))
    `catch` (throwIO . transportError)
  when (n <= 0) $ throwIO ConnectionClosed
  writeIORef ref (Arena fp (used + n))
  pure (BI.BS (fp `plusForeignPtr` used) n)

-- | A receive function for a TLS backend: exactly the bytes asked for, or
-- fewer at the end of the stream (as @TLS.getBackend@'s), copied out of a
-- 32 KiB buffer that is filled by receiving as much as the backend has.
-- tls reads each record in two calls, its 5-byte header and then its body,
-- which @TLS.getBackend@ made two system calls; here one receive usually
-- covers several records.  Each call allocates what it returns, as
-- @TLS.getBackend@'s did; the buffer is the connection's for its life.
-- One thread reads at a time (the connecting thread during the handshake,
-- the reader thread after).  The buffer is kept alive over each receive
-- with 'withForeignPtr', as in 'recvIntoArena'.
newBufferedRecv :: Backend -> IO (Int -> IO B.ByteString)
newBufferedRecv backend = do
  buf <- BI.mallocByteString recvBufferSize
  -- The unread bytes are those from the first offset to the second.
  window <- newIORef (0 :: Int, 0 :: Int)
  let recvN n = do
        (start, end) <- readIORef window
        let have = end - start
        if
          | have >= n -> do
              writeIORef window (start + n, end)
              copyOut start n
          | n > recvBufferSize -> do
              -- More than the buffer holds (tls never asks for that): what
              -- it has, then straight from the backend.
              writeIORef window (0, 0)
              BI.createUptoN n $ \dst -> do
                withForeignPtr buf $ \src -> copyBytes dst (src `plusPtr` start) have
                let fill k
                      | k >= n = pure k
                      | otherwise = backendRecv backend (dst `plusPtr` k) (n - k) >>= \case
                          r | r <= 0 -> pure k
                            | otherwise -> fill (k + r)
                fill have
          | otherwise -> do
              -- Move the unread bytes to the front, and receive after them.
              when (start > 0 && have > 0) $ withForeignPtr buf $ \p ->
                moveBytes p (p `plusPtr` start) have
              writeIORef window (0, have)
              r <- withForeignPtr buf $ \p ->
                backendRecv backend (p `plusPtr` have) (recvBufferSize - have)
              if r <= 0
                then writeIORef window (0, 0) >> copyOut 0 have
                else writeIORef window (0, have + r) >> recvN n
      copyOut off len = BI.create len $ \dst ->
        withForeignPtr buf $ \src -> copyBytes dst (src `plusPtr` off) len
  pure recvN

-- | The size of the buffer of 'newBufferedRecv': more than a TLS record (at most
-- 16 KiB of plaintext and its overhead).
recvBufferSize :: Int
recvBufferSize = 32768

-- | The least free space 'recvIntoArena' reads into.
minRecvSpace :: Int
minRecvSpace = 8192

-- | Mark the connection closed by the client, stop the reader thread, run
-- @goodbye@ (a TLS close_notify) unless a send is in progress, and close the
-- socket.  A thread waiting for a response or sending, and every later use,
-- then fails with @'ConnectionClosedBy' 'ClosedByClient'@.
--
-- A send in progress (or a goodbye, from another 'closeConnection') may
-- wait for the server to read, which may be never, so it is not waited for
-- as it is: the backend is shut down, which makes the send fail at once, and
-- closed only once the send has given up the send lock.  Closing a socket
-- under a thread that is sending on it would be unsafe: that thread may
-- read the descriptor just before the close and use it just after, when
-- the number may already belong to another socket.  (Or start to wait on
-- it after the close: GHC's IO manager (before 9.14) then keeps a stale
-- registration for the number, which on macOS makes closing the number's
-- next socket fail; see 'closeSocket'.)  The wait for the send lock is
-- interruptible; the backend is then shut down but not closed, until the
-- next 'closeConnection' (or the finalizer).
--
-- The backend is closed only once the reader thread has stopped: if it were
-- still reading, it could go on to read from whatever socket the next
-- connection is given with the same descriptor.
--
-- The connection is kept reachable throughout ('keepAlive'), as a send
-- keeps it: past its first lines this refers only to the fields it uses,
-- so a connection whose last handle was the caller's could otherwise be
-- found garbage half-way, and the finalizer of 'startReader' would close the
-- backend under the goodbye.  The close_notify was then lost, its send
-- failing on the closed socket; a send that had read the descriptor just
-- before the close could have written it to whatever socket was given
-- the number next.
closeConnection :: Connection -> IO () -> IO ()
closeConnection conn goodbye = keepAlive (connAlive conn) $ do
  atomically $ writeTVar (connEnded conn) (Just (toException (ConnectionClosedBy ClosedByClient)))
  readIORef (connReader conn) >>= mapM_ (stopReader backend)
  mask $ \restore -> do
    free <- isJust <$> tryTakeMVar lock
    unless free $ do
      backendShutdown backend
      restore (takeMVar lock)
    -- A failure to say goodbye doesn't matter (the caller's @goodbye@
    -- catches it), but an asynchronous exception must reach the code that
    -- sent it; the backend is closed either way.
    ((when free (restore goodbye) `finally` backendClose backend) `finally` putMVar lock ())
  where
    lock = connSendLock conn
    backend = connBackend conn

-- | After 'closeConnection': drop what only a live
-- transport needs, so that a closed connection that is still referenced (by
-- a pool, a stream, a thread) keeps little alive.  A TLS context keeps its
-- record buffers and the parameters it was made with, the certificate store
-- among them: about 3 MB with the system store.  The transport becomes the
-- (closed) backend; nothing uses it any more, since the reader thread has
-- stopped and sends and reads check 'connEnded' first.  A thread that was
-- sending keeps the TLS context it had until its send fails.
--
-- The current response goes too: a response still arriving (a stream read
-- part-way) keeps the rest of the packet or chunk it stopped in, up to a
-- whole 32 KiB arena ('copyIntoArena').  Nothing reads it again, since
-- 'nextToken' and 'startRequest' check 'connEnded' first; a stream or
-- thread that still has the response keeps it as long as it does.
releaseTransport :: Connection -> IO ()
releaseTransport conn = do
  writeIORef (connTransport conn) (TransportPlain (connBackend conn))
  sessions <- allSessions conn
  forM_ sessions $ \sess -> do
    writeIORef (sessRecvBuffer sess) []
    writeIORef (sessResponse sess) Nothing
    forM_ (sessSmp sess) $ \smp -> atomically $ void $ flushTQueue (linkIncoming (smpLink smp))
  atomically $ void $ tryTakeTMVar (connIncoming conn)

-- | Read some bytes.  Throws 'ConnectionClosed' on EOF, and after
-- 'closeConnection'.
recvSome :: Connection -> IO B.ByteString
recvSome conn = readIORef (connReader conn) >>= \case
  Nothing -> recvDirect conn
  Just _ -> atomically $ do
    ended <- readTVar (connEnded conn)
    case ended of
      Just e | closedByClient e -> throwSTM e
      -- Bytes the reader received before it stopped come first.
      _ -> takeTMVar (connIncoming conn) `orElse` maybe retry throwSTM ended

-- | Receive more bytes into the primary session's 'sessRecvBuffer' (the
-- only one read this way: an SMP session gets whole packets).  Masked from
-- taking the bytes to storing them, so an async exception can't lose them
-- in between; the wait for them stays interruptible.
recvMore :: Connection -> IO ()
recvMore conn = mask_ $ do
  more <- recvSome conn
  modifyIORef' (primaryBuffer conn) (++ [more])

primaryBuffer :: Connection -> IORef [B.ByteString]
primaryBuffer = sessRecvBuffer . connPrimary

-- | Read exactly @n@ bytes.  Bytes stay in 'sessRecvBuffer' until all @n@ are
-- available, so an interrupted call loses nothing.
recvExactly :: Connection -> Int -> IO B.ByteString
recvExactly conn n = fillBuffer conn n >> takeBytes conn n

-- | Receive until 'sessRecvBuffer' holds at least @n@ bytes.
fillBuffer :: Connection -> Int -> IO ()
fillBuffer conn n = go
  where
    go = do
      chunks <- readIORef (primaryBuffer conn)
      unless (sum (map B.length chunks) >= n) $ recvMore conn >> go

-- | The first @n@ bytes of 'sessRecvBuffer', which holds at least that
-- many, without consuming them: a slice of the first chunk, or a copy of
-- the pieces of chunks they span.
peekBytes :: Connection -> Int -> IO B.ByteString
peekBytes conn n = fst . splitChunks n <$> readIORef (primaryBuffer conn)

-- | 'peekBytes', consuming them.
takeBytes :: Connection -> Int -> IO B.ByteString
takeBytes conn n = do
  (now, later) <- splitChunks n <$> readIORef (primaryBuffer conn)
  writeIORef (primaryBuffer conn) later
  pure now

-- | The first @n@ bytes of the chunks (joined only if they span chunks),
-- and the chunks after them.
splitChunks :: Int -> [B.ByteString] -> (B.ByteString, [B.ByteString])
splitChunks n = \case
  c : cs | B.length c >= n ->
    let (now, rest) = B.splitAt n c
     in (now, if B.null rest then cs else rest : cs)
  chunks -> go n [] chunks
  where
    go _ acc [] = (B.concat (reverse acc), [])
    go k acc (c : cs)
      | B.length c < k = go (k - B.length c) (c : acc) cs
      | otherwise =
          let (now, rest) = B.splitAt k c
           in (B.concat (reverse (now : acc)), if B.null rest then cs else rest : cs)

-- | Send a message, as chunks of whole packets ('splitIntoPackets',
-- 'frameSegments').  Returns normally if and only if the whole message was
-- sent; otherwise the connection is broken.
--
-- The chunks are produced as they are sent ('sendFramed' frames them
-- lazily), so the caller must have evaluated the message body in full
-- first: a lazy encoding failure (an 'error' inside a 'Put') must fail
-- before anything goes out, not cut a message short.  The send runs with asynchronous exceptions masked, so it can only be
-- interrupted while it actually blocks: waiting for the transport to take
-- the bytes (a peer that doesn't read), or for the TLS session's write
-- lock.  Any exception that escapes it, asynchronous or not, marks the
-- connection broken (the server may hold part of a message, and neither it
-- nor the TLS session can be told to forget it), shuts the socket down so
-- the reader thread ends and a later 'closeConnection' is clean, and is
-- rethrown: an interruption reaches the code that sent it, and the
-- connection then throws 'ConnectionBroken' wrapping it.
--
-- A transport failure is thrown as 'ConnectionClosed' (see
-- 'transportError'), and nothing is sent once the connection has ended: if
-- the reader thread has seen the server close the connection (as when the
-- session was killed while idle), or 'closeConnection' was called, that is
-- the reason given.
sendBytes :: Connection -> [B.ByteString] -> IO ()
sendBytes conn packets = sendWith conn (const packets)

-- | Frame a message body and send it ('sendBytes'), in chunks that suit the
-- transport: on a plain socket, up to 64 KiB of whole packets per write;
-- over TLS, one packet per chunk, since SQL Server (2025, strict
-- encryption) resets the connection when a TLS record holds more than one
-- TDS packet (the records are gathered into writes of up to 64 KiB
-- instead, 'SendGather').  The body must be evaluated in full already.
--
-- On an SMP session each packet goes out as an SMP DATA packet
-- ('sendSmpFrames'), and the send lock is held per write, not for the
-- message; the rest is the same: masked, and any exception out of it
-- breaks the connection.
sendFramed :: Connection -> Session -> TdsContext -> PacketType -> PacketStatus -> LB.ByteString -> IO ()
sendFramed conn sess ctx ptype status body =
  sendPacketsWith conn sess ctx ptype status (\writer -> writeBuilder writer (BB.lazyByteString body))
    >>= either (sendFailed conn) pure

-- | Run a send (masked); if it throws, shut the backend down and fail as
-- 'sendFailed' does.
breakingOnFailure :: Connection -> IO a -> IO a
breakingOnFailure conn act = act `catch` \e -> do
  -- Harmless if the backend is closed already ('closeConnection' shuts it
  -- down before waiting for this send to give up).
  backendShutdown (connBackend conn) `catch` \(_ :: IOException) -> pure ()
  sendFailed conn e

-- | Send one TDS packet as a DATA packet on an SMP session, as
-- 'sendSmpFrames' sends each.
sendSmpPacket :: Connection -> SmpSession -> PacketSink
sendSmpPacket conn smp packet = do
  _ <- awaitSmpWindow conn smp
  writeSmpData conn smp [packet]

-- | How many DATA packets the server's window has room for, at least one:
-- when it is used up, this waits (interruptibly, without the send lock) for
-- the server to raise it, which it does as it consumes the packets.
awaitSmpWindow :: Connection -> SmpSession -> IO Int
awaitSmpWindow conn smp = do
  sent <- readIORef (smpSendSeq smp)
  atomically $ do
    readTVar (connEnded conn) >>= mapM_ throwSTM
    highWater <- readTVar (linkSendHighWater (smpLink smp))
    let room = fromIntegral (highWater - sent) :: Int32
    when (room <= 0) retry
    pure (fromIntegral room)

-- | Write DATA packets in one write, which the caller knows the window has
-- room for.  The headers are made under the send lock ('writeSmp'), since
-- their sequence numbers and window must be in the order they are written.
writeSmpData :: Connection -> SmpSession -> [B.ByteString] -> IO ()
writeSmpData conn smp packets = writeSmp conn $ do
  sent <- readIORef (smpSendSeq smp)
  window <- readTVarIO (linkRecvHighWater (smpLink smp))
  -- (Not @[sent + 1 ..]@, which stops at the largest number: the sequence
  -- wraps.)
  writeIORef (smpSendSeq smp) (sent + fromIntegral (length packets))
  writeIORef (smpAdvertised smp) window
  pure (zipWith (smpDataPacket (smpSid smp) window) (iterate (+ 1) (sent + 1)) packets)

-- | Send a SYN, an ACK or a FIN on an SMP session.  It never waits for
-- the server's window, and leaves the DATA sequence number as it is: an
-- ACK must go out even when nothing more may be sent, or the two sides
-- could wait for each other.  Any exception out of it breaks the
-- connection, as for any send.
sendSmpControl :: Connection -> SmpSession -> SmpFlag -> IO ()
sendSmpControl conn smp flag = keepAlive conn $ mask_ $ breakingOnFailure conn $ writeSmp conn (controlPacket flag smp)

-- | A SYN, ACK or FIN for the session, made under the send lock
-- ('writeSmp'): SEQNUM 0 for a SYN, else the last DATA packet's, and the
-- window, which is recorded as advertised.
controlPacket :: SmpFlag -> SmpSession -> IO [[B.ByteString]]
controlPacket flag smp = do
  seqNum <- if flag == SmpSyn then pure 0 else readIORef (smpSendSeq smp)
  window <- readTVarIO (linkRecvHighWater (smpLink smp))
  writeIORef (smpAdvertised smp) window
  pure [[smpControlPacket flag (smpSid smp) seqNum window]]

-- | Write SMP packets, made once the send lock is held (so that their
-- sequence numbers and windows are in the order they are written).  Each is
-- given as its pieces: a header, and a TDS packet.  In plaintext each SMP
-- packet is one write of the backend ('backendSendMany'): a socket sends the
-- pieces as they are, and a pipe, whose server reads a write at a time,
-- joins them.  TLS joins them too, because a TLS record holds one SMP packet
-- and @sendData@ makes a record per chunk.
writeSmp :: Connection -> IO [[B.ByteString]] -> IO ()
writeSmp conn packets = withMVar (connSendLock conn) $ \() -> do
  readTVarIO (connEnded conn) >>= mapM_ throwIO
  smpPackets <- packets
  readIORef (connTransport conn) >>= \case
    TransportPlain backend -> backendSendMany backend smpPackets
    TransportTls ctx -> do
      let gather = connSendGather conn
          backend = connBackend conn
      startGathering gather
      (mapM_ (TLS.sendData ctx . LB.fromStrict . B.concat) smpPackets >> endGathering True gather backend)
        `onException` endGathering False gather backend

sendWith :: Connection -> (Transport -> [B.ByteString]) -> IO ()
sendWith conn chunksFor = keepAlive conn $ withMVar (connSendLock conn) $ \() -> mask_ $ do
  (readTVarIO (connEnded conn) >>= mapM_ throwIO) `catch` sendFailed conn
  transport <- readIORef (connTransport conn)
  let sendAll = case transport of
        TransportPlain backend -> mapM_ (backendSend backend) (chunksFor transport)
        TransportTls ctx -> do
          -- One record per chunk, gathered into backend writes, and the rest
          -- written at the end of the message.
          let gather = connSendGather conn
              backend = connBackend conn
          startGathering gather
          (mapM_ (TLS.sendData ctx . LB.fromStrict) (chunksFor transport) >> endGathering True gather backend)
            `onException` endGathering False gather backend
  breakingOnFailure conn sendAll

-- | A send failed with this exception: the connection is broken, and the
-- exception (a transport failure as 'ConnectionClosed', or the reason the
-- connection ended) rethrown.
sendFailed :: Connection -> SomeException -> IO a
sendFailed conn e = do
  e' <- case fromException (transportError e) of
    Just (closed :: ConnectionClosed) -> fromMaybe (toException closed) <$> readTVarIO (connEnded conn)
    Nothing -> pure e
  markBroken conn (reasonFor SendFailed e')
  throwIO e'

-- | Send a message whose packets are produced as they are sent: the
-- producer gets a 'PacketWriter' for a message of this packet type, and the
-- message is what it writes, ending when it returns.  For a message too long to build first (a bulk load), or one produced from an
-- effectful source.
--
-- Like 'sendBytes', it holds the send lock and runs masked, so the
-- producer is interrupted only where it blocks (a send that waits for
-- the transport, or its own source).  The packets go out as 'sendFramed'
-- sends them: up to 64 KiB of whole packets per socket write, or one
-- TLS record each, gathered.
--
-- Returns 'Right' the producer's result once every packet it sent has
-- been handed to the transport.  A synchronous exception from the
-- producer itself (not from a send) leaves the transport at a packet
-- boundary, with the message unfinished: it is returned as 'Left', and
-- the connection is not broken, for the caller to cancel the message
-- ('startStreamingRequest' does).  A failed send, or an asynchronous
-- exception (which may land inside a send), breaks the connection and is
-- rethrown, as for 'sendBytes'.
sendPackets :: forall a. Connection -> Session -> TdsContext -> PacketType -> (PacketWriter -> IO a) -> IO (Either SomeException a)
sendPackets conn sess tdsCtx ptype = sendPacketsWith conn sess tdsCtx ptype (PacketStatus 0)

sendPacketsWith :: forall a. Connection -> Session -> TdsContext -> PacketType -> PacketStatus -> (PacketWriter -> IO a) -> IO (Either SomeException a)
sendPacketsWith conn sess tdsCtx ptype status = sendPacketsTracked conn sess tdsCtx ptype status (pure ())

sendPacketsTracked :: forall a. Connection -> Session -> TdsContext -> PacketType -> PacketStatus -> IO () -> (PacketWriter -> IO a) -> IO (Either SomeException a)
sendPacketsTracked conn sess tdsCtx ptype status onPacket produce = case sessSmp sess of
  Nothing -> keepAlive conn $ withMVar (connSendLock conn) $ \() -> mask_ $ do
    (readTVarIO (connEnded conn) >>= mapM_ throwIO) `catch` sendFailed conn
    transport <- readIORef (connTransport conn)
    -- A failure inside a send is told from one in the producer by wrapping
    -- it; the producer's own synchronous exceptions are caught here.
    let run = case transport of
          TransportPlain backend -> do
            pending <- newIORef ([], 0 :: Int)
            let send p = do
                  (ps, n) <- readIORef pending
                  let n' = n + B.length p
                  if n' >= gatherLimit
                    then do
                      writeIORef pending ([], 0)
                      backendSendMany backend (reverse ([p] : ps)) `catch` sendFailure
                    else writeIORef pending ([p] : ps, n')
                flush = do
                  (ps, _) <- readIORef pending
                  writeIORef pending ([], 0)
                  unless (null ps) $ backendSendMany backend (reverse ps) `catch` sendFailure
            r <- writing send
            flush
            pure r
          TransportTls ctx -> do
            let gather = connSendGather conn
                backend = connBackend conn
            startGathering gather
            (do r <- writing (\p -> TLS.sendData ctx (LB.fromStrict p) `catch` sendFailure)
                endGathering True gather backend `catch` sendFailure
                pure r)
              `onException` endGathering False gather backend
    breakingOnFailure conn (run `catch` (throwIO . unwrap))
  -- Each packet is written as it is produced (the wait for the server's
  -- window comes between them), with the send lock held for the write only.
  Just smp -> keepAlive conn $ mask_ $ breakingOnFailure conn $
    writing (\p -> sendSmpPacket conn smp p `catch` sendFailure) `catch` (throwIO . unwrap)
  where
    writing :: PacketSink -> IO (Either SomeException a)
    writing sink = produced (runPacketWriterWith tdsCtx ptype status (\packet -> onPacket >> sink packet) (produce . withSourceScope sourceScope))
    sourceScope :: IO b -> IO b
    sourceScope = sourceAction conn
    -- The producer's own synchronous exceptions, as a value.
    produced act = try act >>= \case
      Right r -> pure (Right r)
      Left e
        | Just (PacketSendFailed inner) <- fromException e -> throwIO (PacketSendFailed inner)
        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        | otherwise -> pure (Left e)
    unwrap e = case fromException e of
      Just (PacketSendFailed inner) -> inner
      Nothing -> e
    sendFailure :: SomeException -> IO b
    sendFailure = throwIO . PacketSendFailed

-- | A transport send failed with this exception ('sendPackets').
newtype PacketSendFailed = PacketSendFailed SomeException

instance Show PacketSendFailed where
  showsPrec p (PacketSendFailed a) = showCon1 p "PacketSendFailed"# a
  {-# OPAQUE showsPrec #-}

instance Exception PacketSendFailed

-- | Where the TLS records of a message go: a TLS backend's send
-- ('gatheredSend') writes each record to the backend at once, unless
-- 'sendWith' is sending a message, when it gathers them into writes of up
-- to 'gatherLimit' bytes.  Records still hold one TDS packet each
-- ('sendFramed'); only the system calls change (a 4 MB parameter took 525
-- @send@s of one 8 KB record, which cost the client more CPU than tls's
-- encryption of it).  Every backend send goes through the MVar, so records
-- tls sends on its own while a message is being gathered (the reader
-- thread's answer to a KeyUpdate, an alert) are gathered too, in order.
newtype SendGather = SendGather (MVar Gathered)

data Gathered
  = NotGathering
  | Gathering ![[B.ByteString]] !Int
    -- ^ Records not yet written, newest first, each a write of one piece
    -- ('backendSendMany'), and their total length.

newSendGather :: IO SendGather
newSendGather = SendGather <$> newMVar NotGathering

-- | Backend writes of gathered records are at most this long, unless one
-- record is longer (as for plaintext messages, 'sendFramed').
gatherLimit :: Int
gatherLimit = 65536

-- | A TLS backend's send over the connection's backend: at once, or
-- gathered while 'sendWith' is sending a message.  It refers to the
-- backend and the gather only, never to the connection (see 'startReader').
gatheredSend :: SendGather -> Backend -> B.ByteString -> IO ()
gatheredSend (SendGather v) backend bs = modifyMVar_ v $ \case
  NotGathering -> NotGathering <$ backendSend backend bs
  Gathering pending size
    | size > 0 && size + len > gatherLimit -> do
        backendSendMany backend (reverse pending)
        pure $! Gathering [[bs]] len
    | otherwise -> pure $! Gathering ([bs] : pending) (size + len)
  where
    len = B.length bs

startGathering :: SendGather -> IO ()
startGathering (SendGather v) = modifyMVar_ v (\_ -> pure (Gathering [] 0))

-- | Stop gathering, and write what is gathered if asked to (at the end of
-- a message) or drop it (after a failed send: the connection is broken).
endGathering :: Bool -> SendGather -> Backend -> IO ()
endGathering write (SendGather v) backend = mask_ $ do
  gathered <- takeMVar v
  let pending = case gathered of
        Gathering p _ | write -> p
        _ -> []
  unless (null pending) (backendSendMany backend (reverse pending)) `finally` putMVar v NotGathering

-- | Run the action with the value kept reachable until it is done.
-- 'sendBytes' keeps its connection so, for the finalizer of 'startReader': a
-- thread that has nothing left to do with the connection once the send
-- is over keeps it reachable only through what 'sendBytes' itself refers
-- to, which is up to the optimizer; if it didn't, the finalizer could close
-- the backend under the send.
keepAlive :: a -> IO b -> IO b
keepAlive x (IO act) = IO (\s -> keepAlive# x s act)

-- | Read one packet.  Interrupted while waiting for it, it loses nothing;
-- the caller must run it masked if the packet must not be lost once read
-- (as 'nextToken' does).
--
-- This reads the primary session ('readSessionPacket'): the connection's
-- one, or SMP session 0.
readPacket :: Connection -> IO (Header, B.ByteString)
readPacket conn = readSessionPacket conn (connPrimary conn)

-- | 'readPacket' from a plain TDS stream: what a connection is before and
-- during its login, and what one without MARS stays.
readPlainPacket :: Connection -> IO (Header, B.ByteString)
readPlainPacket conn = do
  -- Peek at the header without consuming so a partial read can be retried.
  fillBuffer conn headerLength
  hdr <- readHeader <$> peekBytes conn headerLength
  let total = fromIntegral (headerPacketLength hdr)
  when (total < headerLength) $ throwIO $ ProtocolError "packet length smaller than header"
  fillBuffer conn total
  packet <- takeBytes conn total
  pure (hdr, B.drop headerLength packet)

-- | Read one packet of the session's: 'readPlainPacket', or on an SMP session
-- the next packet the reader thread queued for it.  The server is told
-- of the room that makes in the window (an ACK) once it has grown by
-- the cadence, @window / 16@ packets.  Interrupted while waiting for a
-- packet, it loses nothing; the ACK's send can't be interrupted, and its
-- failure breaks the connection, as for any send, unless the connection
-- has ended ('sendAck'): the packets queued before the end are read first.
--
-- The connection is kept reachable while it waits ('keepAlive'), as
-- 'sendBytes' keeps it: the wait itself refers only to what the reader
-- thread shares, and the finalizer of 'startReader' must not run under it.
readSessionPacket :: Connection -> Session -> IO (Header, B.ByteString)
readSessionPacket conn sess = keepAlive (connAlive conn) $ case sessSmp sess of
  Nothing -> readPlainPacket conn
  Just smp -> do
    let link = smpLink smp
    packet <- atomically $ do
      ended <- readTVar (connEnded conn)
      case ended of
        Just e | closedByClient e -> throwSTM e
        -- Packets the reader received before it stopped come first.
        _ -> readTQueue (linkIncoming link) `orElse` maybe retry throwSTM ended
    accepted <- atomically $ stateTVar (linkRecvHighWater link) (\w -> (w + 1, w + 1))
    advertised <- readIORef (smpAdvertised smp)
    let window = maybe 0 marsWindow (connMars conn)
    -- Uninterruptibly: this is a read, and an interruption of a read must
    -- leave the connection usable, which an interrupted send doesn't.  The
    -- ACK is 16 bytes and waits only briefly (for the TLS session's state,
    -- which the reader thread shares, or for room in the socket's buffer,
    -- which is full only while a request of this connection is still
    -- going out: a bulk load whose rows come from this stream);
    -- 'closeConnection' from another thread ends the wait.
    when (accepted - advertised >= max 1 (window `div` 16)) $
      uninterruptibleMask_ (sendAck conn smp)
    pure (readHeader packet, B.drop headerLength packet)

-- | Send an ACK ('sendSmpControl'), except on a connection that has ended
-- ('connEnded': the reader thread saw the server close it, or break the
-- protocol, or 'closeConnection' was called).  The packets the reader
-- queued before the end are still to be read, a severity-20 error among
-- them, and the server needs no more window: the ACK is skipped, and a
-- send that fails because the end came meanwhile is ignored, where
-- breaking the connection would make those packets unreadable and lose
-- the one being read.  Any other failure breaks the connection, as for
-- any send.
sendAck :: Connection -> SmpSession -> IO ()
sendAck conn smp = keepAlive conn $ mask_ $ do
  r <- try (writeSmp conn (controlPacket SmpAck smp))
  case r of
    Right () -> pure ()
    Left (e :: SomeException) -> do
      ended <- isJust <$> readTVarIO (connEnded conn)
      unless ended $ breakingOnFailure conn (throwIO e)

-- | A message body.  binary's 'Put.runPut' starts with a 4 KiB buffer,
-- which GHC allocates as a large object (taking the storage manager's
-- lock) for every request, though most bodies are a few dozen bytes; this
-- starts with 512 bytes and continues in 32 KiB chunks.  The chunks aren't
-- trimmed: the body is copied into packets anyway ('frameSegments').
runBody :: Put -> LB.ByteString
runBody = BB.toLazyByteStringWith (BB.untrimmedStrategy 512 32752) LB.empty . Put.execPut

-- | Frame and send a complete message.
sendMessage :: Connection -> PacketType -> Put -> IO ()
sendMessage conn ptype body = do
  ctx <- readIORef (connContext conn)
  let bytes = runBody body
  _ <- evaluate (LB.length bytes)
  sendFramed conn (connPrimary conn) ctx ptype (PacketStatus 0) bytes

-- | Read every packet of one message and return the concatenated body.
readWholeMessage :: Connection -> IO (PacketType, B.ByteString)
readWholeMessage conn = readWholeMessageUpTo conn maxBound

-- | 'readWholeMessage', failing with a 'ProtocolError' once the body is
-- longer than the given number of bytes, so a server can't make the client
-- buffer without bound.  Used for PRELOGIN, whose response is not a token
-- stream.
readWholeMessageUpTo :: Connection -> Int -> IO (PacketType, B.ByteString)
readWholeMessageUpTo conn limit = breakOnFailure conn $ go 0 []
  where
    go !size acc = do
      (hdr, body) <- readPacket conn
      let acc' = body : acc
          size' = size + B.length body
      when (size' > limit) $ throwIO $ ProtocolError $
        "the server's message is longer than " ++ show limit ++ " bytes, the most expected"
      if headerStatus hdr `hasStatus` statusEndOfMessage
        then pure (headerType hdr, B.concat (reverse acc'))
        else go size' acc'

hasStatus :: PacketStatus -> PacketStatus -> Bool
hasStatus a b = a .&. b /= PacketStatus 0

------------------------------------------------------------------------------
-- Requests and responses

-- | Send a request and start reading its response.  Any unfinished previous
-- response is canceled and drained first; on a MARS connection the
-- request takes a session of its own instead, and the other responses
-- stay open ('prepareForRequest').  A pending 'requestReset' is carried
-- out first (see there).
startRequest :: Connection -> PacketType -> (TdsContext -> LB.ByteString) -> IO ActiveResponse
startRequest conn ptype body = startRequestFor conn Nothing ptype (bytesBody body)

-- | A request body already in memory, as the request writer takes it.  The
-- body's length is forced before anything is written, so a lazy encoding
-- failure fails the request before any of it is sent.
bytesBody :: (TdsContext -> LB.ByteString) -> TdsContext -> PacketWriter -> IO ()
bytesBody body ctx writer = do
  let bytes = body ctx
  _ <- evaluate (LB.length bytes)
  writeBuilder writer (BB.lazyByteString bytes)

-- | 'startRequest', with the request's SQL text: what names the response
-- if it is found unfinished ('busyStatements').
startRequestFor :: Connection -> Maybe Text -> PacketType -> (TdsContext -> PacketWriter -> IO ()) -> IO ActiveResponse
startRequestFor conn stmt ptype mkBody = withConnectionLock conn $ do
  readIORef (connInSource conn) >>= \active -> when active (throwIO ReentrantSource)
  checkNotBroken conn
  prepareForRequest conn
  let resettable = ptype `elem` [PTSqlBatch, PTRpc, PTTransactionManager]
  pending <- readIORef (connResetPending conn)
  when (resettable && pending) $ do
    -- The server refuses a reset while another request is active on the
    -- connection (and then fails every request until that one is
    -- canceled), so every open response is settled first.
    forM_ (connMars conn) $ \_ -> finishResponse conn
    unless (null (connSessionSetup conn)) $ resetWithSessionSetup conn
  sendRequest conn stmt ptype resettable mkBody

-- | What precedes every request, with the lock held.
--
-- Without MARS: the unfinished response, if any, is canceled and drained
-- ('finishSession').
--
-- With MARS, other responses stay open, except that:
--
-- * a response canceled by an interrupted read (an Attention was sent,
--   its acknowledgement not yet read) is drained, as without MARS;
-- * inside 'withReservedSession', the reserved session's response is
--   finished, as without MARS;
-- * a request that carried RESETCONNECTION must have been answered
--   ('awaitReset');
-- * idle sessions beyond 'maxIdleSessions' are closed.
prepareForRequest :: Connection -> IO ()
prepareForRequest conn = case connMars conn of
  Nothing -> finishSession conn (connPrimary conn)
  Just mars -> do
    drainCancelled conn
    readIORef (marsReserved mars) >>= mapM_ (finishSession conn)
    awaitReset conn mars
    closeIdleSessions conn mars

-- | Drain every response that was canceled (an Attention sent, by an
-- interrupted read) and not yet read to the acknowledgement, or
-- abandoned by the function that was reading it ('readingToEnd').  The
-- caller holds the lock.
drainCancelled :: Connection -> IO ()
drainCancelled conn = do
  sessions <- allSessions conn
  forM_ sessions $ \sess -> readIORef (sessResponse sess) >>= mapM_ (\ar -> do
    canceled <- (/= Running) <$> readIORef (arCancellation ar)
    when canceled $ finishSession conn sess)

-- | Run an action that reads the response to its end, on a plain or a
-- MARS connection alike.  If it throws part-way, the response is not
-- left for the next request to find: a synchronous exception cancels and
-- drains it before it propagates ('cancelActiveResponse'); an
-- asynchronous one abandons it ('abandonResponse'), which cancels the
-- statement at once and leaves the drain to the next request (or
-- transaction function, 'release' or 'cancelActiveStatement'), so that an
-- interruption never waits for the server.  (An interruption needn't
-- land in a read: it can come just after the request was sent, or between
-- two reads.)
readingToEnd :: Connection -> ActiveResponse -> IO a -> IO a
readingToEnd conn ar act = act `catch` \(e :: SomeException) -> do
  case fromException e of
    Just (_ :: SomeAsyncException) -> abandonResponse conn ar
    -- A failure to cancel leaves the first exception to report (an
    -- interruption of the cancellation is reported instead).
    Nothing -> cancelActiveResponse conn ar `catch` \(c :: SomeException) -> case fromException c of
      Just (_ :: SomeAsyncException) -> throwIO c
      Nothing -> pure ()
  throwIO e

-- | After an asynchronous exception out of a function or scope that was
-- reading the response ('readingToEnd', 'withQueryS'): mark the response
-- abandoned, so that the next request (or transaction function, 'release'
-- or 'cancelActiveStatement') drains it; abandon the handle (a new
-- generation), so that a stream read on through it throws
-- 'ResultAbandoned' instead of ending at the acknowledgement, silently
-- missing rows; and cancel the statement at once ('cancelStatement').
-- Nothing if the response has ended or was superseded.
--
-- Runs masked (from a handler).  It never waits for the statement; it
-- may wait for the connection mutex (taken directly: the handle may be
-- stale, and the response is to be marked all the same) and, on a MARS
-- connection, for a slot in the server's window.  The abandoned flag is
-- written before the mutex is taken, so that a second interruption in
-- that wait still leaves the response for the next drain to find (on a
-- superseded response, which nothing consults, the flag is harmless); the
-- other state changes come before the send, since they can't fail.
abandonResponse :: Connection -> ActiveResponse -> IO ()
abandonResponse conn ar = do
  markAbandoned ar
  withMutex (connMutex conn) $ do
    current <- readIORef (sessResponse sess)
    case current of
      Just ar' | arState ar' == arState ar -> do
        abandonHandle ar
        broken <- isJust <$> readIORef (connBroken conn)
        unless broken $ void (cancelStatement conn ar)
      _ -> pure ()
  where
    sess = arSession ar

-- | Abandon the handle: the session's response gets a new generation, so
-- that reading on through the caller's record throws 'ResultAbandoned'
-- ('checkCurrent'), while the drain, which reads the session's current
-- record, goes on.  The caller holds the lock.
abandonHandle :: ActiveResponse -> IO ()
abandonHandle ar = do
  gen <- atomicModifyIORef' (sessGeneration sess) (\g -> (g + 1, g + 1))
  writeIORef (sessResponse sess) (Just ar { arGeneration = gen })
  where
    sess = arSession ar

-- | Send an Attention for the response, unless it has fully arrived (the
-- statement is over, and an Attention would get an acknowledgement of its
-- own) or one was sent already; whether one was sent now.  The caller
-- holds the lock and runs masked.  A failed send breaks the connection; a
-- second interruption, of the send, wins, as in 'bracket'.
cancelStatement :: Connection -> ActiveResponse -> IO Bool
cancelStatement conn ar = do
  arrived <- fullyArrived ar
  attn <- attentionWasSent <$> readIORef (arCancellation ar)
  if arrived || attn
    then pure False
    else do
      ctx <- readIORef (connContext conn)
      sendFramed conn (arSession ar) ctx PTAttention (PacketStatus 0) LB.empty
        `catch` \(c :: SomeException) -> case fromException c of
          Just (_ :: SomeAsyncException) -> throwIO c
          Nothing -> pure ()
      writeIORef (arCancellation ar) AttentionSent
      pure True

-- | Every session of the connection: the one, or under MARS the open
-- SMP sessions, in the order of their identifiers.
allSessions :: Connection -> IO [Session]
allSessions conn = case connMars conn of
  Nothing -> pure [connPrimary conn]
  Just mars -> IntMap.elems <$> readIORef (marsOpen mars)

-- | The session for the next request: the connection's one; under MARS
-- the reserved session ('withReservedSession'), else the idle session
-- with the lowest identifier, else a new one.  The caller holds the lock
-- and registers a response on it, or fails, without being interrupted.
takeSession :: Connection -> IO Session
takeSession conn = case connMars conn of
  Nothing -> pure (connPrimary conn)
  Just mars -> readIORef (marsReserved mars) >>= \case
    Just sess -> pure sess
    Nothing -> idleSessions conn mars >>= \case
      sess : _ -> pure sess
      [] -> openSession conn mars

-- | The open sessions with no response, lowest identifier first, but
-- for a reserved one.
idleSessions :: Connection -> Mars -> IO [Session]
idleSessions _ mars = do
  reserved <- fmap sessionId <$> readIORef (marsReserved mars)
  open <- IntMap.elems <$> readIORef (marsOpen mars)
  let idle sess
        | Just (sessionId sess) == reserved = pure False
        | otherwise = isNothing <$> readIORef (sessResponse sess)
  filterIO idle open
  where
    filterIO f = fmap concat . mapM (\x -> f x >>= \keep -> pure [x | keep])

-- | An SMP session's identifier (-1 for the session of a connection
-- without MARS).
sessionId :: Session -> Int
sessionId = maybe (-1) (fromIntegral . smpSid) . sessSmp

-- | Open an SMP session: the lowest identifier the server doesn't have
-- open (so at most one above the largest in use, which is all it accepts;
-- an identifier closed by a FIN is free again once the server's FIN has
-- arrived, which takes it out of the registry).  The session is
-- registered before its SYN is sent, so the client can't forget an
-- identifier the server has: a SYN that fails or is interrupted breaks
-- the connection, like any send.  The server doesn't answer a SYN.
openSession :: Connection -> Mars -> IO Session
openSession conn mars = mask_ $ do
  links <- readTVarIO (marsRegistry mars)
  let sid = until (\i -> not (IntMap.member i links)) (+ 1) 0
  when (sid > 0xFFFF) $ throwIO $ EncodeError
    "the connection has 65536 responses open, the most SMP has sessions for"
  link <- SmpLink <$> newTQueueIO <*> newTVarIO smpInitialWindow <*> newTVarIO 0
    <*> newTVarIO (marsWindow mars) <*> newTVarIO 0 <*> newTVarIO False
  smp <- SmpSession (fromIntegral sid) link <$> newIORef 0 <*> newIORef (marsWindow mars)
  sess <- newSession (Just smp)
  atomically $ modifyTVar' (marsRegistry mars) (IntMap.insert sid link)
  modifyIORef' (marsOpen mars) (IntMap.insert sid sess)
  sendSmpControl conn smp SmpSyn
  pure sess

-- | How many idle SMP sessions a connection keeps (SqlClient's number).
maxIdleSessions :: Int
maxIdleSessions = 10

-- | Close idle sessions beyond 'maxIdleSessions', highest identifier
-- first: a FIN, which the server answers with a FIN.  Until that arrives
-- the identifier stays in the registry, neither open nor free for a new
-- session (the server drops the connection on a SYN for it).  Only an
-- idle session is ever closed: a FIN for one whose request the server
-- hasn't finished drops the connection too.
closeIdleSessions :: Connection -> Mars -> IO ()
closeIdleSessions conn mars = do
  idle <- idleSessions conn mars
  forM_ (take (length idle - maxIdleSessions) (reverse idle)) $ \sess ->
    forM_ (sessSmp sess) $ \smp -> mask_ $ do
      atomically $ writeTVar (linkClosing (smpLink smp)) True
      modifyIORef' (marsOpen mars) (IntMap.delete (sessionId sess))
      sendSmpControl conn smp SmpFin

-- | Start SMP on a connection that negotiated MARS, once it has logged in
-- (and run its session setup) in plain TDS: open session 0, with the
-- given window (at least 4 packets).  Before 'startReader'.  The
-- connection returned is the one to use; the one given is no longer.
enableMars :: Connection -> Int -> IO Connection
enableMars conn window = do
  leftover <- readIORef (primaryBuffer conn)
  unless (null leftover) $ throwIO $ ProtocolError "unexpected data after the login response"
  marsRegistry <- newTVarIO IntMap.empty
  marsOpen <- newIORef IntMap.empty
  marsReserved <- newIORef Nothing
  marsResetInFlight <- newIORef Nothing
  let mars = Mars { marsWindow = fromIntegral (max 4 (min 0x7FFFFFFF window)), .. }
      conn' = conn { connMars = Just mars }
  primary <- openSession conn' mars
  pure conn' { connPrimary = primary }

-- | Run the action with every request it makes sent on one session, taken
-- for it; the lock is held throughout.  For an exchange that spans
-- several requests which the server ties to a session: a bulk load's
-- @INSERT BULK@, its BULK LOAD message, and the Attention that recovers a
-- failed load.  As without MARS, each request inside first finishes the
-- session's previous response.  Without MARS it is 'withConnectionLock'.
withReservedSession :: Connection -> IO a -> IO a
withReservedSession conn act = withConnectionLock conn $ case connMars conn of
  Nothing -> act
  Just mars -> readIORef (marsReserved mars) >>= \case
    Just _ -> act
    Nothing -> bracket_
      (checkNotBroken conn >> takeSession conn >>= writeIORef (marsReserved mars) . Just)
      (writeIORef (marsReserved mars) Nothing)
      act

-- | Send one message and make its response its session's current one.  If
-- @resettable@, a pending reset is consumed and the message carries the
-- RESETCONNECTION bit.
--
-- Returns normally if and only if the message was sent and its response
-- registered; if the send fails or is interrupted, the connection is broken
-- ('sendBytes').  A failure before anything is sent (an encoding error)
-- leaves the connection usable, and a pending reset pending.
sendRequest :: Connection -> Maybe Text -> PacketType -> Bool -> (TdsContext -> PacketWriter -> IO ()) -> IO ActiveResponse
sendRequest conn stmt ptype resettable writeBody = mask_ $ do
  ctx <- readIORef (connContext conn)
  sess <- takeSession conn
  resetting <- if resettable then atomicModifyIORef' (connResetPending conn) (False,) else pure False
  let status = if resetting then statusResetConnection else PacketStatus 0
  ar0 <- newResponse sess stmt resetting
  sent <- newIORef False
  result <- sendPacketsTracked conn sess ctx ptype status (writeIORef sent True) (writeBody ctx)
  case result of
    Right () -> registerResponse conn ar0
    Left err -> do
      anyPacket <- readIORef sent
      if not anyPacket && ptype /= PTBulkLoad then do
        when resetting (writeIORef (connResetPending conn) True)
        throwIO err
      else do
        ar <- registerResponse conn ar0
        sendFramed conn sess ctx PTAttention (PacketStatus 0) LB.empty
        writeIORef (arCancellation ar) AttentionSent
        finishSession conn sess
        throwIO err

-- | The response to a message about to be sent on the session, before its
-- generation: 'registerResponse' gives it that once the message is sent.
newResponse :: Session -> Maybe Text -> Bool -> IO ActiveResponse
newResponse sess stmt resetting = do
  arEomBase <- maybe (pure 0) (readTVarIO . linkEoms . smpLink) (sessSmp sess)
  arSawResetAck <- newIORef False
  arCancellation <- newIORef Running
  arInConsumer <- newIORef False
  arReplay <- newIORef []
  arState <- newIORef (ReadState False (AtToken B.empty))
  arResultSet <- newIORef Nothing
  arSawFinalDone <- newIORef False
  pure ActiveResponse
    { arGeneration = 0, arSession = sess, arStatement = stmt, arCarriedReset = resetting, .. }

-- | Make the response to the message just sent its session's current one,
-- as a new generation of the session.  Under MARS, one that carried a
-- reset holds back the requests after it ('awaitReset').
registerResponse :: Connection -> ActiveResponse -> IO ActiveResponse
registerResponse conn ar0 = do
  let sess = arSession ar0
  gen <- atomicModifyIORef' (sessGeneration sess) (\g -> (g + 1, g + 1))
  let ar = ar0 { arGeneration = gen }
  writeIORef (sessResponse sess) (Just ar)
  when (arCarriedReset ar) $ forM_ (connMars conn) $ \mars ->
    writeIORef (marsResetInFlight mars) (Just ar)
  pure ar

-- | Under MARS, a request sent on another session right behind one that
-- carries RESETCONNECTION races it: the server may run either first, and
-- refuses what it runs before the reset.  The reset's acknowledgement is
-- among the ENVCHANGE tokens that begin the carrying request's response,
-- and nothing sent once those have arrived is refused.  So before a
-- request starts, the response of a reset still in flight is read up to
-- its first token that is not an ENVCHANGE (or its end).
--
-- The tokens are read by the ordinary reader, which applies each once,
-- from wherever the response's consumer has got to, and kept for the
-- consumer, which is given them first ('arReplay').  The wait comes
-- before anything is sent, so an interruption is harmless: it doesn't
-- cancel the response, and the tokens read so far are kept.
awaitReset :: Connection -> Mars -> IO ()
awaitReset conn mars = readIORef (marsResetInFlight mars) >>= \case
  Nothing -> pure ()
  Just ar -> do
    current <- readIORef (sessResponse (arSession ar))
    case current of
      Just ar' | arGeneration ar' == arGeneration ar -> do
        -- Masked from consuming a token to keeping it; the wait for its
        -- packet stays interruptible.
        step <- mask_ $ do
          step <- stepCore conn ar False StopAtRow
          modifyIORef' (arReplay ar) (++ replayed step)
          settleReset conn ar step
          pure step
        runCallbacks conn step
        awaitReset conn mars
      -- Canceled, or drained: whoever did that has read it.
      _ -> writeIORef (marsResetInFlight mars) Nothing
  where
    replayed = \case
      StepToken tok -> [tok]
      StepRows _ -> []
      StepEnd -> []

-- | After a step of a response that carried a reset: once it is past its
-- leading ENVCHANGE tokens, requests may start again ('awaitReset').
settleReset :: Connection -> ActiveResponse -> ResponseStep r -> IO ()
settleReset conn ar step = when (arCarriedReset ar) $ case step of
  StepToken (TEnvChange _) -> pure ()
  _ -> forM_ (connMars conn) $ \mars -> readIORef (marsResetInFlight mars) >>= \case
    Just inFlight | arState inFlight == arState ar -> writeIORef (marsResetInFlight mars) Nothing
    _ -> pure ()

-- | 'startRequest' for a message produced packet by packet as it is sent
-- ('sendPackets'): the producer gets a 'PacketWriter', and the message ends
-- when it returns.  A pending 'requestReset' is
-- left pending (the message isn't a SQL batch or RPC).
--
-- If the producer fails (synchronously) with the message unfinished, the
-- request is canceled: an Attention is sent, and the server's
-- acknowledgement read (as after an interrupted read, 'nextToken'), so
-- the connection stays usable; the producer's exception is then
-- rethrown.  A failed or interrupted send breaks the connection, as any
-- send does.
startStreamingRequest :: Connection -> Maybe Text -> PacketType -> (PacketWriter -> IO ()) -> IO ActiveResponse
startStreamingRequest conn stmt ptype produce = startRequestFor conn stmt ptype (\_ -> produce)

-- | Reset the session and run the session setup again, in one SQLBatch that
-- carries the RESETCONNECTION bit, read to the end.  SET statements inside
-- an RPC (such as @sp_executesql@) revert when it returns, and prefixing
-- them to the caller's batch would break batches that must start with
-- CREATE PROCEDURE and the like, so this costs a round trip of its own.
--
-- If reading the response fails or is interrupted, it is unknown how much
-- of the setup ran, so the connection is marked broken; likewise if the
-- setup fails on the server (as in 'Hmssql.Connection.connect', a session
-- without its setup is not usable): with an ERROR token ('SqlServerError'),
-- or with a DONE flagged as failed and no ERROR token ('SevereError').
--
-- Unlike @sp_reset_connection@, RESETCONNECTION keeps the transaction
-- isolation level (SQL Server 2025; Azure SQL Database puts READ COMMITTED
-- back); nothing here restores it.
resetWithSessionSetup :: Connection -> IO ()
resetWithSessionSetup conn = mask $ \restore -> do
  let sql = T.intercalate "\n" (connSessionSetup conn)
  ar <- sendRequest conn (Just sql) PTSqlBatch True (\ctx writer -> do
    mapM_ (throwIO . EncodeError) (sqlBatchProblem ctx sql)
    writeBuilder writer (sqlBatchBuilder ctx sql))
  let go err done = nextToken conn ar >>= \case
        Nothing -> pure (err, done)
        Just (TError msg) -> go (err <|> Just msg) done
        Just tok -> go err (done <|> failedDoneOf tok)
  failed <- restore (go Nothing Nothing) `catch` \(e :: SomeException) -> do
    markBroken conn (reasonFor ResetFailed e)
    throwIO e
  -- A failed DONE with no ERROR token is a failure too: it is how the
  -- server refuses a reset (under MARS, with another request active).
  let failure = case failed of
        (Just msg, _) -> Just (toException (SqlServerError msg (Just sql)))
        (Nothing, Just d) -> Just (toException (SevereError d (Just sql)))
        (Nothing, Nothing) -> Nothing
  forM_ failure $ \e -> do
    markBroken conn (resetFailure e)
    throwIO e

-- | Reset the session before the next SQLBatch, RPC or transaction manager
-- request: the session returns to its state right after login (MS-TDS
-- 2.2.3.1.2, RESETCONNECTION), and the session setup runs again.  With no
-- session setup, the next request itself carries the RESETCONNECTION bit,
-- so the reset costs nothing extra; otherwise it is preceded by one batch
-- that carries the bit and the session setup.
--
-- Takes the connection lock, so a reset requested by another thread waits
-- for whatever holds the connection (a request being read, or a whole
-- 'Hmssql.Transaction.withTransaction') and applies to the request after it.
requestReset :: Connection -> IO ()
requestReset conn = withConnectionLock conn $
  atomicWriteIORef (connResetPending conn) True

-- | The rows at the head of the response, decoded: what one 'nextStep'
-- returns when it finds rows.
data RowBatch r = RowBatch
  { batchRows :: ![r]
    -- ^ In order.
  , batchFailed :: !(Maybe DecodeError)
    -- ^ The row after the last one didn't decode; it has been consumed,
    -- and the response goes on after it.
  }

-- | Where the reading of 'stepCore' stopped: at a step to return, or at a consumer to
-- run before reading on.  A consumer is user code, so the reading hands it out
-- rather than running it inside the handler that breaks the connection when the
-- bytes can't be read.  'StepConsumer' holds the consumer and the reading that
-- goes on with its result, as 'P.RunConsumer' does for a recipe.
data StepProgress r
  = StepReady (ResponseStep r)
  | forall x. StepConsumer (IO x) (x -> IO (StepProgress r))

-- | What 'nextStep' found next in the response.
data ResponseStep r
  = StepRows !(RowBatch r)
  | StepToken !Token
    -- ^ A token other than a row.
  | StepEnd
    -- ^ The response is complete.

-- | Read a batch of rows, a non-row token, or the end of the response.
-- Complete rows are returned before waiting for another packet. A partial
-- token remains as a continuation in the response, without re-reading bytes.
nextStep :: Connection -> ActiveResponse -> RowRead r -> IO (ResponseStep r)
nextStep conn ar decodeRow = stepResponse False conn ar False decodeRow

-- 'nextStep' with each batch's rows in reverse order, as they were accumulated,
-- for 'Hmssql.Query.Internal.readFirstResultSet', which collects every batch and
-- reverses once at the end.  No other caller may use it: a 'RowBatch' is in order
-- everywhere else.
nextStepReversed :: Connection -> ActiveResponse -> RowRead r -> IO (ResponseStep r)
nextStepReversed conn ar decodeRow = stepResponse True conn ar False decodeRow

-- | Read one raw token. An interrupted receive sends Attention eagerly
-- unless the response has already arrived, and its continuation is retained
-- for the drain. A malformed token breaks the connection.
nextToken :: Connection -> ActiveResponse -> IO (Maybe Token)
nextToken conn ar = stepResponse False conn ar True wholeRows >>= \case
  StepRows (RowBatch [row] _) -> pure (Just (TRow row))
  StepRows _ -> throwIO $ ProtocolError "nextToken: a batch of one row without the row"  -- can't happen: at most one row, decoded with Right
  StepToken tok -> pure (Just tok)
  StepEnd -> pure Nothing

-- | Throw 'ResultAbandoned' unless this response is still its session's
-- current one: not superseded by a later request (without MARS), canceled
-- by an interruption or by 'cancelActiveResponse', drained, or closed
-- with the connection (which throws its own reason);
-- 'ConnectionReleased' if the handle was released ('checkLease').  What 'nextStep' checks before reading; a
-- stream that holds rows of a batch checks it before yielding each, so
-- that a superseded stream throws at once, not after the rows it had.
checkCurrent :: Connection -> ActiveResponse -> IO ()
checkCurrent conn ar = do
  readIORef (arInConsumer ar) >>= \active -> when active (throwIO ReentrantCallback)
  checkLease conn
  checkNotBroken conn
  readIORef (sessResponse (arSession ar)) >>= \case
    Just ar' | arGeneration ar' == arGeneration ar -> pure ()
    _ -> abandoned conn

-- | Throw 'ResultAbandoned' for a response that is no longer the current
-- one, unless the connection was closed or broke meanwhile: 'close' from
-- another thread (which doesn't wait for the connection lock) may record
-- its reason and clear the response ('releaseTransport') just after the
-- caller's 'checkNotBroken'.  Every use after 'close' throws its reason.
abandoned :: Connection -> IO a
abandoned conn = checkNotBroken conn >> throwIO ResultAbandoned

-- | 'nextStep', optionally restricted to one row for 'nextToken'.
stepResponse :: Bool -> Connection -> ActiveResponse -> Bool -> RowRead r -> IO (ResponseStep r)
stepResponse reversed conn ar oneRow decodeRow = withConnectionLock conn $ do
  readIORef (arInConsumer ar) >>= \active -> when active (throwIO ReentrantCallback)
  checkNotBroken conn
  current <- readIORef (sessResponse sess)
  case current of
    Just ar' | arGeneration ar' == arGeneration ar ->
      -- Only a response that carried a reset has tokens read ahead
      -- ('awaitReset').
      if arCarriedReset ar then readIORef (arReplay ar) >>= replayOr else step
    _ -> abandoned conn
  where
    sess = arSession ar

    -- The token is fully consumed before the callbacks run, so a failing
    -- callback doesn't leave the byte stream in an unknown position; an
    -- interruption inside a callback still cancels the statement.
    step = (do
        r <- stepCoreWithOrder reversed conn ar oneRow decodeRow
        settleReset conn ar r
        runCallbacks conn r
        pure r)
      `catch` \(e :: SomeAsyncException) -> do
        cancelEagerly
        throwIO e

    -- A token 'awaitReset' read: its effects are applied and its
    -- callbacks have run.
    replayOr = \case
      [] -> step
      tok : rest -> writeIORef (arReplay ar) rest >> pure (StepToken tok)

    -- Runs masked (in a handler).  Once the statement is canceled, the
    -- handle is abandoned: read on through it, the response would end at
    -- the acknowledgement, silently missing the rest of the result.  A
    -- response that had fully arrived is left readable: nothing was sent,
    -- and reading on gives the rest of the result (a batch committed as
    -- consumed before the interruption landed is lost, as one interrupted
    -- on its way back to the caller is; design.md, "Interruption and
    -- cancellation").
    cancelEagerly = do
      sent <- cancelStatement conn ar
      when sent $ abandonHandle ar

-- | Whether the response's last packet has been received: read by its
-- consumer, or, on an SMP session, queued for it by the reader thread.
-- The statement is then over on the server, and the rest of the response
-- can be read without canceling anything.
fullyArrived :: ActiveResponse -> IO Bool
fullyArrived ar = do
  eom <- readFinalPacket <$> readIORef (arState ar)
  case sessSmp (arSession ar) of
    Just smp | not eom -> (> arEomBase ar) <$> readTVarIO (linkEoms (smpLink smp))
    _ -> pure eom

-- | Run the connection's callbacks for a step: with the lock held, and
-- the connection refusing to be used meanwhile.
runCallbacks :: Connection -> ResponseStep r -> IO ()
runCallbacks conn = \case
  StepToken (TEnvChange ec) -> inCallback (connOnEnvChange conn ec)
  StepToken (TInfo msg) -> inCallback (connOnInfo conn msg)
  _ -> pure ()
  where
    inCallback =
      bracket_ (writeIORef (connInCallback conn) True) (writeIORef (connInCallback conn) False)

-- | The reading of 'stepResponse': the next step of the response, from
-- the bytes pending or the session's next packets.  The caller holds the
-- lock and has checked that the response is its session's current one.
-- Completed rows are returned before a receive would block. State is committed
-- at the batch boundary or before a suspension, never for each completed row.
--
-- A batch is the rows that complete with the bytes in hand.  When a row runs out
-- of bytes with others already decoded, the batch ends and the suspended row is
-- kept, so complete rows never wait behind a slow server, and the next step goes
-- on with that row rather than reading it again.
--
-- The whole step runs masked, and only the wait for a packet is interruptible.  An
-- interruption there finds the suspension already committed, so nothing is lost.
-- A consumer is user code, so it alone runs in the caller's masking state.
stepCore :: Connection -> ActiveResponse -> Bool -> RowRead r -> IO (ResponseStep r)
stepCore = stepCoreWithOrder False

stepCoreWithOrder :: Bool -> Connection -> ActiveResponse -> Bool -> RowRead r -> IO (ResponseStep r)
stepCoreWithOrder reversed conn ar requestedOne reader = mask $ \restore -> do
  let sess = arSession ar
      ahead = connValueAllocAhead conn
      oneRow = requestedOne
      rows state acc failed = do
        writeIORef (arState ar) state
        pure (StepReady (StepRows (RowBatch (if reversed then acc else reverse acc) failed)))
      loop acc = readIORef (arState ar) >>= at acc
      at acc state = case readPosition state of
        AtToken bytes -> atBytes acc (readFinalPacket state) bytes 0
        Reading suspended -> resume acc state suspended
        Parked bytes remainder -> resume acc state $
          fmap (\(P.Got () rest) -> SkippedRow rest) (P.parse remainder bytes)
      -- Keep ordinary progress as arguments: the payload and a position in it,
      -- which a completed row returns ('P.runParserAt').  The unread bytes are
      -- built only when a batch or a suspended computation is committed to the
      -- response, or a token other than a row is read; built after every row,
      -- they were 32 bytes of a typed (Int32, Int64) row's 366.
      atBytes acc final payload !pos
        | oneRow && not (null acc) = rows state acc Nothing
        | isRowTokenAt payload pos = readRow acc final payload pos
        | not (null acc) = rows state acc Nothing
        | pos >= B.length payload = if final then messageEnd else do
            (body, end) <- readResponsePacket conn sess
            atBytes acc end body 0
        | otherwise = startToken acc state (B.drop pos payload)
        where state = ReadState final (AtToken (B.drop pos payload))
      changed = throwIO (ProtocolError "row decoder changed inside a row")
      -- The fast path is 'P.runParserAt', with no Stream constructor and no handler
      -- per row (the one handler is around the whole step, below).  This is
      -- selected once per step, not per row.
      readRow = case reader of
        ReadRows recipe inbox ->
          \acc final payload pos -> case P.runParserAt recipe payload pos of
            Right (P.At result end) -> atBytes (result : acc) final payload end
            Right (P.FailedAt failure end) -> failedRow acc final payload end failure
            Left suspended -> driveRow acc (ReadState final (AtToken (B.drop pos payload))) inbox suspended
        WholeRows _ -> withPosition startToken
        DiscardRows _ -> withPosition skipCurrent
        DrainRows _ -> withPosition skipCurrent
        -- 'awaitReset' stops here with nothing consumed.  Reading a row only to
        -- replay it meant writing it back to TDS and parsing it again.
        StopAtRow -> withPosition (\acc state _ -> rows state acc Nothing)
      withPosition next acc final payload pos =
        let bytes = B.drop pos payload in next acc (ReadState final (AtToken bytes)) bytes
      -- A row that didn't decode, read to its end.
      failedRow acc final payload end = \case
        DecodeFailed err -> rows (ReadState final (AtToken (B.drop end payload))) acc (Just err)
        -- Only a drain discards, and a drain doesn't look at rows.
        ReadDiscarded -> atBytes acc final payload end
      skipCurrent acc state bytes = do
        info <- readIORef (arResultSet ar) >>= maybe
          (throwIO (ProtocolError "ROW without COLMETADATA")) pure
        resume acc state $ fmap (\(P.Got () rest) -> SkippedRow rest) (P.parse (skipRow info) bytes)
      skipRow info = do
        bitmap <- V.rowBitmap (rsColumnCount info)
        V.skipCells bitmap (rsCells info)
      startToken acc state bytes = do
        cols <- readIORef (arResultSet ar)
        let token = case reader of DrainRows _ -> readTokenSkipping cols; _ -> readTokenWith ahead cols
            -- Rows and output parameters cost their values' size.  Every other
            -- token is metadata, whose lengths the bytes alone don't bound.
            recipe = if isRowToken bytes || isReturnValueToken bytes then token else P.limited tokenSizeLimit token
        resume acc state (fmap (\(P.Got tok rest) -> ReadToken tok rest) (P.parse recipe bytes))
      accept acc final rest = \case
        Left failure -> failedRow acc final rest 0 failure
        Right r -> atBytes (r : acc) final rest 0
      driveRow acc state inbox stream = inspect stream >>= \case
        Left (P.Got result rest) -> accept acc (readFinalPacket state) rest result
        Right await -> resume acc state $
          fmap (\(P.Got result rest) -> ReadRow (writeIORef inbox (Just result)) rest) (Streaming.wrap await)
      resume acc state suspended = inspect suspended >>= \case
        Left event -> case event of
          ReadToken tok rest -> do
            applyToken tok
            let after = state { readPosition = AtToken rest }
            case tok of
              TRow row -> case reader of
                WholeRows decode -> accept acc (readFinalPacket state) rest (Right (decode row))
                _ -> maybe changed (accept acc (readFinalPacket state) rest . Right) (skippedAs reader)
              _ -> writeIORef (arState ar) after >> pure (StepReady (StepToken tok))
          ReadRow deliver rest -> do
            case skippedAs reader of
              Just r -> accept acc (readFinalPacket state) rest (Right r)
              Nothing -> case reader of
                ReadRows _ inbox -> do
                  deliver
                  result <- readIORef inbox
                  writeIORef inbox Nothing
                  maybe changed (accept acc (readFinalPacket state) rest) result
                _ -> changed
          SkippedRow rest -> do
            let after = state { readPosition = AtToken rest }
            maybe (at acc after) (accept acc (readFinalPacket state) rest . Right) (skippedAs reader)
        Right await@(P.NeedMore k) -> do
          -- Committed before the receive, the only place this step can be
          -- interrupted.  A saved step is run once, which a value's accumulator
          -- relies on: it writes into a buffer the suspension holds.
          let pending = state { readPosition = Reading (Streaming.wrap await) }
          writeIORef (arState ar) pending
          if not (null acc) then rows pending acc Nothing else
            if readFinalPacket state then resume [] pending (k P.EndOfMessage) else do
              (body, final) <- readResponsePacket conn sess
              -- 'P.Discard' lets a value being assembled drop its buffer, since
              -- nothing will read it.
              resume [] pending { readFinalPacket = final } (k (case reader of DrainRows _ -> P.Discard body; _ -> P.More body))
        Right await@(P.RunConsumer live io k) -> do
          -- Committed before the consumer runs.  If it throws, a drain resumes
          -- here, and a drain gives 'Nothing', which reads past the rest of the
          -- value without running the consumer again.
          let pending = state { readPosition = Reading (Streaming.wrap await) }
          writeIORef (arState ar) pending
          -- A consumer that pulls its value from the response may wait for the
          -- server, so the complete rows go back first, as before a receive; the
          -- next step runs it.  One given its value whole runs here, among them.
          if live && not (null acc) then rows pending acc Nothing else case skippedAs reader of
            -- A drain must not run user code.
            Just _ -> resume acc state (k Nothing)
            Nothing -> pure $ StepConsumer (runConsumer io) $ \result -> do
              final <- readFinalPacket <$> readIORef (arState ar)
              resume acc state { readFinalPacket = final } (k (Just result))
      -- An exception from the consumer ends the query at once, as one from the
      -- caller's own code would, and leaves the rest of the value and row to the
      -- drain.  Reading them here would make a timeout in a consumer wait for the
      -- server, and hang if the server had stalled.  The statement is canceled
      -- and the handle abandoned, so that a stream of the response can't run the
      -- consumer again.
      runConsumer :: (P.Runner -> IO a) -> IO a
      runConsumer io = bracket_ enter leave $ do
        -- The consumer's pulls run back under the mask, one packet at a time.  A
        -- consumer could catch a failure of the byte stream and return, so each
        -- pull breaks the connection itself.
        let feed = do
              final <- readFinalPacket <$> readIORef (arState ar)
              if final then pure P.EndOfMessage else do
                (body, end) <- readResponsePacket conn sess
                modifyIORef' (arState ar) (\s -> s { readFinalPacket = end })
                pure (P.More body)
            pull = P.feedRunner feed
            runner = P.Runner $ \current -> mask_ $
              breakOnFailure conn (P.runAwait pull current)
        restore (io runner) `onException` abandonAtOnce conn ar
      enter = do
        writeIORef (arInConsumer ar) True
        when (isNothing (connMars conn)) (writeIORef (connInCallback conn) True)
      leave = do
        writeIORef (arInConsumer ar) False
        when (isNothing (connMars conn)) (writeIORef (connInCallback conn) False)
      messageEnd = do
        -- After an Attention the acknowledgement may come in a message of its
        -- own, so the end of this one doesn't end the response.
        cancellation <- readIORef (arCancellation ar)
        final <- readIORef (arSawFinalDone ar)
        if cancellation == AttentionSent
          then writeIORef (arState ar) (ReadState False (AtToken B.empty)) >> loop []
          else if not final && cancellation /= AttentionAcknowledged
            then throwIO (ProtocolError "response message ended without a final DONE token")
            else writeIORef (sessResponse sess) Nothing >> pure (StepReady StepEnd)
      applyToken tok = do
        when (isFinalDone tok) $ writeIORef (arSawFinalDone ar) True
        forM_ (doneOf tok) $ \d -> when (doneAttention d) $
          modifyIORef' (arCancellation ar) (\s -> if s == AttentionSent then AttentionAcknowledged else s)
        case tok of
          TError msg | msgClass msg >= 20 -> do
            let err = SqlServerError msg (arStatement ar)
            markBroken conn (FatalServerError msg)
            throwIO err
          TColMetaData cols -> writeIORef (arResultSet ar) (Just (compileResultSet cols))
          TEnvChange ec -> do
            modifyIORef' (connContext conn) (applyEnvChange ec)
            case ec of ECResetConnectionAck -> writeIORef (arSawResetAck ar) True; _ -> pure ()
          _ -> pure ()
  -- One handler for each stretch of reading, not one for each completed row.  It
  -- also preserves failures of custom pure conversions.
  let drive reading = breakOnFailure conn reading >>= \case
        StepReady step -> pure step
        StepConsumer consumer continue -> consumer >>= drive . continue
  drive (loop [])

-- | The next payload of this session's response, and whether it is the
-- message's last.  This hides the transport, TLS and SMP from the parser, and
-- checks the packet's type.
readResponsePacket :: Connection -> Session -> IO (B.ByteString, Bool)
readResponsePacket conn sess = breakOnFailure conn $ do
  (header, bytes) <- readSessionPacket conn sess
  unless (headerType header == PTTabularResult) $
    throwIO (ProtocolError ("unexpected packet type " ++ show (headerType header)))
  pure (bytes, headerStatus header `hasStatus` statusEndOfMessage)

-- | A consumer or cell pull cannot resume after an exception, unlike a plain
-- read after an interruption, so its handle is abandoned even if the response
-- has fully arrived. The caller holds the connection lock; the saved recipe
-- remains available to its drain.
abandonAtOnce :: Connection -> ActiveResponse -> IO ()
abandonAtOnce conn ar = do
  -- A consumer's pull that broke the connection fails through the consumer.
  broken <- isJust <$> readIORef (connBroken conn)
  unless broken $ void (cancelStatement conn ar)
  markAbandoned ar
  abandonHandle ar

-- | Pull a generic cell fragment, preserving a recipe for abandoning its row.
-- The function says, from what was read, how to skip the rest of the row, or
-- 'Nothing' when the pull ended at a token boundary.
readPiece :: Connection -> ActiveResponse -> P.Parser a -> (a -> Maybe (P.Parser ())) -> IO a
readPiece conn ar recipe remainder = withConnectionLock conn $ mask_ $ do
  checkCurrent conn ar
  state <- readIORef (arState ar)
  let start bytes = drive state (P.parse recipe bytes)
      drive current stream = breakOnFailure conn (inspect stream) >>= \case
        Left (P.Got a rest) -> do
          writeIORef (arState ar) current { readPosition = maybe (AtToken rest) (Parked rest) (remainder a) }
          pure a
        Right await@(P.NeedMore k) -> do
          -- If this wait is interrupted, no later pull will come for this piece,
          -- so what is saved is the piece followed by the skip of its row.
          let drain = Streaming.wrap await >>= \(P.Got a rest) -> case remainder a of
                Nothing -> pure (SkippedRow rest)
                Just skip -> fmap (\(P.Got () rest') -> SkippedRow rest') (P.parse skip rest)
              pending = current { readPosition = Reading drain }
          writeIORef (arState ar) pending
          if readFinalPacket current then drive pending (k P.EndOfMessage) else do
            (bytes, final) <- readResponsePacket conn (arSession ar)
            drive pending { readFinalPacket = final } (k (P.More bytes))
        Right P.RunConsumer{} -> throwIO (ProtocolError "a cell pull cannot invoke a field consumer")
      interrupted (err :: SomeAsyncException) = abandonAtOnce conn ar >> throwIO err
  (case readPosition state of
    AtToken bytes -> start bytes
    Parked bytes _ -> start bytes
    -- A pull that was interrupted left only the drain above.
    Reading _ -> throwIO ResultAbandoned) `catch` interrupted

-- | Whether the next token starts a row.
isRowToken :: B.ByteString -> Bool
isRowToken bs = isRowTokenAt bs 0

-- | Whether the token at this position of the payload starts a row.
isRowTokenAt :: B.ByteString -> Int -> Bool
isRowTokenAt payload pos = pos < B.length payload && (byte == 0xD1 || byte == 0xD2)
  where byte = B.index payload pos

isReturnValueToken :: B.ByteString -> Bool
isReturnValueToken bytes = not (B.null bytes) && B.head bytes == 0xAC

applyEnvChange :: EnvChange -> TdsContext -> TdsContext
applyEnvChange ec ctx = case ec of
  ECPacketSize{newSize} -> ctx { tdsPacketSize = newSize }
  ECBeginTransaction{transaction} -> ctx { tdsTransaction = Just transaction }
  ECCommitTransaction{} -> ctx { tdsTransaction = Nothing }
  ECRollbackTransaction{} -> ctx { tdsTransaction = Nothing }
  ECDefectTransaction{} -> ctx { tdsTransaction = Nothing }
  ECTransactionEnded{} -> ctx { tdsTransaction = Nothing }
  ECEnlistDtcTransaction{transaction} -> ctx { tdsTransaction = Just transaction }
  -- A reset rolls back any open transaction.
  ECResetConnectionAck -> ctx { tdsTransaction = Nothing }
  -- A copy: the bytes are a slice of whatever buffer the response was
  -- received into, and the context lives as long as the connection.  As
  -- a slice, the collation of a plaintext login kept the 32 KiB buffer of
  -- that login's read alive ('recvFresh').
  -- (Forced, or the copy would be a thunk that holds the slice.)
  ECSqlCollation{newBytes} -> ctx { tdsCollation = if B.null newBytes then Nothing else Just $! B.copy newBytes }
  _ -> ctx

-- | Read and discard the rest of the current response, a batch of rows
-- at a time (nothing is decoded).  The record given is the session's
-- current one (read from 'sessResponse', as 'finishSession' does), never
-- a caller's handle: a handle abandoned by an interruption has an older
-- generation, which 'stepResponse' would refuse.  ("Hmssql.BatchQuery"
-- drains with its reader's record on the synchronous path only, where no
-- generation has changed.)
drainActiveResponse :: Connection -> ActiveResponse -> IO ()
drainActiveResponse conn ar = do
  r <- nextStep conn ar drainingRows
  case r of
    StepEnd -> pure ()
    _ -> drainActiveResponse conn ar

-- | Make sure no response is pending on the connection: 'finishSession'
-- for its session, or under MARS for every session that has one.  Under
-- MARS the Attentions all go out first and the acknowledgements are read
-- after, so settling several running statements costs one round trip, not
-- one each.
finishResponse :: Connection -> IO ()
finishResponse conn = withConnectionLock conn $ do
  sessions <- allSessions conn
  when (isJust (connMars conn)) $
    forM_ sessions $ \sess -> readIORef (sessResponse sess) >>= mapM_ (cancelRunning conn)
  mapM_ (finishSession conn) sessions

-- | Make sure no response is pending on the session: send an Attention if
-- the server is still sending (unless one was sent already, by
-- 'nextToken'), then discard everything up to the end of the message (and,
-- after an Attention, up to its acknowledgement).  A response whose last
-- packet has arrived ('fullyArrived') is read to its end with nothing
-- sent.  Returns once the response is over on the server too.
--
-- If the drain fails or is interrupted, the connection is marked broken:
-- how much of the canceled response has been read is then unknown, and a
-- second Attention would get a second acknowledgement, which would be read
-- as the reply to the next request.
finishSession :: Connection -> Session -> IO ()
finishSession conn sess = withConnectionLock conn $
  readIORef (sessResponse sess) >>= \case
    Nothing -> pure ()
    Just ar -> do
      cancelRunning conn ar
      drainActiveResponse conn ar `catch` \(e :: SomeException) -> do
        markBroken conn (reasonFor DrainFailed e)
        throwIO e
      -- A canceled request that carried a reset: SQL Server applies the
      -- reset all the same, and acknowledges it in the canceled response
      -- (every time, in 6000 tries: batch, RPC and TM requests, the
      -- Attention sent 0 to 3 ms behind them, with and without MARS).  If
      -- a response ever ends without the acknowledgement, the reset is
      -- asked for again.
      when (arCarriedReset ar) $ do
        acked <- readIORef (arSawResetAck ar)
        unless acked $ atomicWriteIORef (connResetPending conn) True

-- | Send an Attention on the response's session, unless the response has
-- fully arrived ('fullyArrived': the statement is over, and an Attention
-- would get an acknowledgement of its own) or one was sent already.
-- Masked so the Attention is recorded once it was sent.  The caller
-- holds the lock and drains the response next ('finishSession').
cancelRunning :: Connection -> ActiveResponse -> IO ()
cancelRunning conn ar = do
  arrived <- fullyArrived ar
  attentionSent <- attentionWasSent <$> readIORef (arCancellation ar)
  unless (arrived || attentionSent) $ mask_ $ do
    ctx <- readIORef (connContext conn)
    sendFramed conn (arSession ar) ctx PTAttention (PacketStatus 0) LB.empty
    writeIORef (arCancellation ar) AttentionSent

-- | Cancel one response and leave the others alone: 'finishSession' for
-- its session, if the response is still that session's (read part-way, or
-- canceled by an interrupted read and not yet drained); nothing if it has
-- ended, was canceled and drained already, or the connection is closed or
-- broken.  A stream of the response throws 'ResultAbandoned' if read on.
cancelActiveResponse :: Connection -> ActiveResponse -> IO ()
cancelActiveResponse conn ar = withConnectionLock conn $ do
  ended <- isJust <$> readTVarIO (connEnded conn)
  broken <- isJust <$> readIORef (connBroken conn)
  current <- readIORef (sessResponse sess)
  case current of
    -- The same response, whatever its generation (an interrupted read
    -- gives it a new one).
    Just ar' | not (ended || broken), arState ar' == arState ar -> finishSession conn sess
    _ -> pure ()
  where
    sess = arSession ar

-- | The SQL text of each response on the connection that has not been
-- read to its end or canceled, where known.  The caller holds the lock.
busyStatements :: Connection -> IO [Text]
busyStatements conn = do
  sessions <- allSessions conn
  busy <- catMaybes <$> forM sessions (readIORef . sessResponse)
  pure [fromMaybe "(a request without SQL text)" (arStatement ar) | ar <- busy]
