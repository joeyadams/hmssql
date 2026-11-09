{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
-- | Overlapped I/O on a Windows handle: what a connection's bytes travel
-- on over Shared Memory and Named Pipes, and on Windows over TCP as well
-- (a socket is a handle that @ReadFile@ and @WriteFile@ accept).
-- "Hmssql.Connection.Backend" wraps it as a
-- 'Hmssql.Connection.Backend.Backend'; on other platforms this module is
-- empty.
--
-- GHC's own handle and socket I/O is not used.  With the threaded RTS and
-- the default I/O manager it blocks in a foreign call, which no
-- asynchronous exception can interrupt and no other thread can end.
-- Without @-threaded@ an exception interrupts a read, but the read itself
-- stays pending on a worker thread and takes the next bytes to arrive.  With
-- the native I/O manager (WinIO) it is interruptible, but that manager
-- crashed under a few dozen busy sockets and hung on an interrupted file
-- read (both upstream bugs, fixed on a GHC branch since), so nothing here
-- goes through it either: the same code runs under both managers, and
-- under the native one the low bit of each operation's event keeps its
-- completion off the manager's completion port.  Where the native manager
-- is used at all ('Hmssql.Connection.Backend.WinIO.nativeIO'), nothing
-- comes here (see the end of this header).
--
-- Here every operation is started overlapped, so it returns at once, and
-- a pending one is waited for on an 'MVar' that a helper thread fills
-- when the operation's event is signaled ('awaitEvent').  So:
--
-- * An asynchronous exception (a 'System.Timeout.timeout', a
--   'Control.Concurrent.killThread') interrupts a blocked operation.  The
--   operation is then canceled with @CancelIoEx@ and waited for, since
--   its buffer and its @OVERLAPPED@ must not be freed while the kernel
--   may still write to them.
--
-- * 'hioStopReceiving' and 'hioShutdown' are sticky.  Each sets a flag
--   and then cancels what is pending; an operation checks the flag before
--   it starts and again once it is pending, so a cancel that arrives
--   between two operations is not lost.
--
-- * A read and a write can be pending at once (each has its own
--   @OVERLAPPED@ and event), which a handle opened without
--   @FILE_FLAG_OVERLAPPED@ doesn't allow: there the Attention would wait
--   behind the reader thread's read.
--
-- * Every operation is started on one bound thread that lives as long as
--   the process ('onIssuer'), because Windows cancels a pending operation
--   when the thread that started it exits, and the runtime's worker
--   threads come and go.
--
-- That is the threaded runtime.  Without @-threaded@ a safe foreign call
-- stops every Haskell thread, so the waits happen elsewhere: on a worker
-- thread of GHC's default I/O manager, through @asyncDoProc@, which runs a
-- C function there while the scheduler goes on (@cbits/windows.c@).  An
-- operation is started in place there, since every Haskell thread then
-- runs on the one operating-system thread that runs the scheduler.  The
-- foreign calls that block for long (a name lookup, a connect, the open
-- of a pipe) are run on a worker the same way ('onWorker').  The native
-- I/O manager of a released GHC has no such workers, so without
-- @-threaded@ this module needs the default one ('requireRuntime').
--
-- Under the native I/O manager, with a network and a GHC that support it
-- ('Hmssql.Connection.Backend.WinIO.nativeIO'), nothing comes here, with
-- or without @-threaded@: TCP goes through network's own calls, as on
-- Linux and macOS, and the pipes through the manager's completion port
-- ("Hmssql.Connection.Backend.WinIO"), which takes its foreign calls and
-- its errors from here.
module Hmssql.Connection.Backend.Windows
#if !defined(mingw32_HOST_OS)
  () where
#else
  ( HandleIO
  , hioHandle
  , newHandleIO
  , hioRecv
  , hioSend
  , hioSendMany
  , hioStopReceiving
  , hioShutdown
  , hioClose
  , backendHandleCount
  , countBackendHandle
  , openPipe
  , openPipeWith
  , createPipeClient
  , createPipeInstance
  , PipeListener
  , pipeListenerOpen
  , pipeListenerAccept
  , pipeListenerClose
  , pipeDisconnect
  , abandonable
  , lookupAddresses
  , connectOnWorker
  , requireRuntime
    -- * For "Hmssql.Connection.Backend.WinIO"
  , throwWindows
  , ioFailure
  , stoppedError
  , eRROR_HANDLE_EOF
  , eRROR_BROKEN_PIPE
  , eRROR_NO_DATA
  , eRROR_PIPE_CONNECTED
  , eRROR_OPERATION_ABORTED
  , eRROR_IO_PENDING
  , c_ReadFile
  , c_WriteFile
  , c_RtlNtStatusToDosError
  , c_CancelIoEx
  , c_ConnectNamedPipe
  , c_DisconnectNamedPipe
  , c_CloseHandle
  ) where

import Control.Concurrent (forkIO, forkOS, rtsSupportsBoundThreads, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forever, join, unless, void, when)
import Data.Bits ((.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Data.IORef
import Data.Word (Word32, Word8)
import Foreign.C.Error (Errno (..), eCONNABORTED, eCONNRESET, ePIPE)
import Foreign.C.String (CString, CWString, withCString, withCWString)
import Foreign.C.Types (CInt (..), CUIntPtr (..))
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Marshal.Alloc (alloca, allocaBytes, callocBytes, free)
import Foreign.Ptr (FunPtr, Ptr, castPtr, intPtrToPtr, nullPtr, plusPtr)
import Foreign.Storable (peek, peekByteOff, poke, pokeByteOff, sizeOf)
import GHC.Conc (labelThread)
import GHC.Conc.Windows (asyncDoProc)
import GHC.Exts (keepAlive#)
import GHC.IO (IO (..))
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import GHC.IO.SubSystem (isWindowsNativeIO)
import Network.Socket (Socket)
import qualified Network.Socket as Socket
import qualified Network.Socket.Address as Socket (SocketAddress (..))
import qualified Network.Socket.Internal as Socket (throwSocketErrorCode)
import System.IO.Unsafe (unsafePerformIO)
import GHC.Windows (DWORD, ErrCode, HANDLE, errCodeToIOError, getLastError, iNFINITE)

-- | A handle opened for overlapped I/O, with what its operations need.
data HandleIO = HandleIO
  { hioHandle :: !HANDLE
  , hioReadOv :: !(Ptr ())
    -- ^ The @OVERLAPPED@ of the read in progress; 'hioWriteOv' is the
    -- write's.  Each carries an event of its own, so the two can be
    -- pending together.
  , hioWriteOv :: !(Ptr ())
  , hioReadEvent :: !HANDLE
  , hioWriteEvent :: !HANDLE
  , hioReadWait :: !(Ptr Wait)
    -- ^ Without @-threaded@, what a worker waits for the read with
    -- ('awaitEvent'); 'hioWriteWait' is the write's.  Null in the threaded
    -- runtime.
  , hioWriteWait :: !(Ptr Wait)
  , hioReadLock :: !(MVar ())
    -- ^ Held for the whole of a read, its cancellation included, so one
    -- read is in progress at a time and 'hioClose' can wait for it.
  , hioWriteLock :: !(MVar ())
  , hioStopRecv :: !(IORef Bool)
    -- ^ Receives fail: 'hioStopReceiving' or 'hioShutdown' was called.
  , hioShut :: !(IORef Bool)
    -- ^ Sends fail as well: 'hioShutdown' was called.
  , hioDead :: !(IORef Bool)
    -- ^ The handle is closed.  Written with both locks held.
  , hioClosed :: !(MVar Bool)
    -- ^ As 'hioDead', for the threads that cancel from outside an
    -- operation: held while they use the handle, and while it is closed.
  , hioPipe :: !Bool
    -- ^ The handle is a pipe, not a socket.  Each write given to
    -- 'hioSendMany' is then made one write of its own, because the other
    -- end reads a write at a time, and 'hioShutdown' closes the handle,
    -- because a pipe has no other way to tell the other end.
  , hioOnShutdown :: !(IO ())
    -- ^ What 'hioShutdown' does besides: a socket's own shutdown.
  , hioCloseHandle :: !(IO ())
    -- ^ How the handle is closed.  It must not throw.
  }

-- | Wrap an open handle.  The flag says whether it is a pipe ('hioPipe').
-- The first action is what shuts a socket down, at 'hioShutdown' (a pipe
-- is closed then, and has none), and the second closes the handle and
-- must not throw.  If this fails, the handle is left as it was.
newHandleIO :: HANDLE -> Bool -> IO () -> IO () -> IO HandleIO
newHandleIO h isPipe onShutdown closeIt = mask_ $ do
  readEvent <- newEvent
  writeEvent <- newEvent `onException` c_CloseHandle readEvent
  readOv <- newOverlapped readEvent
  writeOv <- newOverlapped writeEvent
  let undo = do
        _ <- c_CloseHandle readEvent
        _ <- c_CloseHandle writeEvent
        free readOv
        free writeOv
  hioReadWait <- newWait readOv readEvent `onException` undo
  hioWriteWait <- newWait writeOv writeEvent `onException` (freeWait hioReadWait >> undo)
  hioReadLock <- newMVar ()
  hioWriteLock <- newMVar ()
  hioStopRecv <- newIORef False
  hioShut <- newIORef False
  hioDead <- newIORef False
  hioClosed <- newMVar False
  -- Nothing after this can fail, so each count is a handle to be closed.
  countBackendHandle 1
  pure HandleIO
    { hioHandle = h
    , hioReadOv = readOv
    , hioWriteOv = writeOv
    , hioReadEvent = readEvent
    , hioWriteEvent = writeEvent
    , hioPipe = isPipe
    , hioOnShutdown = onShutdown
    , hioCloseHandle = closeIt
    , ..
    }
  where
    -- Manual-reset, not signaled.  @ReadFile@ and @WriteFile@ reset it
    -- as they start.
    newEvent = do
      ev <- c_CreateEventW nullPtr 1 0 nullPtr
      when (ev == nullPtr) $ getLastError >>= throwWindows "CreateEvent"
      pure ev

    -- Zeroed, with the event.  The event's low bit is set, which keeps a
    -- completion from being queued to a completion port if the handle has
    -- one (another I/O manager's); the event is signaled all the same.
    newOverlapped ev = do
      ov <- callocBytes overlappedSize
      pokeByteOff ov overlappedEventOffset (ev `plusPtr` 1)
      pure ov

    newWait ov ev
      | rtsSupportsBoundThreads = pure nullPtr
      | otherwise = do
          w <- c_hmssql_wait_new h ov ev
          when (w == nullPtr) $ getLastError >>= throwWindows "CreateEvent"
          pure w

freeWait :: Ptr Wait -> IO ()
freeWait w = unless (w == nullPtr) (c_hmssql_wait_free w)

-- | @sizeof(OVERLAPPED)@: two pointer-sized words, a 64-bit offset and the
-- event handle.
overlappedSize, overlappedEventOffset :: Int
overlappedSize = overlappedEventOffset + sizeOf (nullPtr :: Ptr ())
overlappedEventOffset = 2 * sizeOf (nullPtr :: Ptr ()) + 8

-- | Receive up to that many bytes into the buffer: how many arrived, or 0
-- at the end of the stream.  Blocks until some do; an asynchronous
-- exception, 'hioStopReceiving' or 'hioShutdown' ends the wait.  The
-- buffer must stay valid until this returns or throws.
hioRecv :: HandleIO -> Ptr Word8 -> Int -> IO Int
hioRecv hio buf size = keepAlive hio $ withMVar (hioReadLock hio) $ \() -> do
  refuse hio (hioStopRecv hio) "receive"
  let ov = hioReadOv hio
  r <- overlapped hio ov (hioReadEvent hio) (hioReadWait hio) (hioStopRecv hio) $
    c_ReadFile (hioHandle hio) buf (fromIntegral size) nullPtr ov
  case r of
    Right n -> pure n
    Left err
      -- The other end closed its handle (a pipe), or the file ended.
      | err == eRROR_BROKEN_PIPE || err == eRROR_HANDLE_EOF -> pure 0
      | otherwise -> failed hio (hioStopRecv hio) "receive" err

-- | Send all of the bytes.  Blocks while the other end doesn't read; an
-- asynchronous exception or 'hioShutdown' ends the wait, with part of the
-- bytes possibly sent.
hioSend :: HandleIO -> B.ByteString -> IO ()
hioSend hio bs = hioSendMany hio [[bs]]

-- | Send all of the writes, in order, with no other send's bytes between
-- them.  Each write is given as its pieces.  A handle takes one buffer
-- per write.
--
-- On a pipe ('hioPipe') each write is one write of the handle, whatever
-- its length, with its pieces copied together (a write of one piece is
-- not copied), because the write boundaries reach the other end: SQL
-- Server reads a pipe a write at a time, and drops the connection when a
-- write doesn't hold whole TDS or SMP packets or, over TLS, exactly one
-- TLS record.  hmssql's writes are always that; an SMP packet in
-- plaintext comes as two pieces, its header and its TDS packet.
--
-- On a socket the boundaries mean nothing, so small pieces are copied
-- together into writes of up to 'maxWrite' bytes (each write is at
-- least a TCP segment of its own), and a longer piece is written in
-- parts.
hioSendMany :: HandleIO -> [[B.ByteString]] -> IO ()
hioSendMany hio writes0 = case shape writes0 of
  [] -> pure ()
  writes -> keepAlive hio $ withMVar (hioWriteLock hio) $ \() -> mapM_ sendOne writes
  where
    ov = hioWriteOv hio
    shape
      | hioPipe hio = filter (not . B.null) . map B.concat
      | otherwise = coalesce . filter (not . B.null) . concat
    limit = if hioPipe hio then maxBound else maxWrite
    sendOne (BI.BS fp len) = withForeignPtr fp $ \p -> go p len
    go :: Ptr Word8 -> Int -> IO ()
    go p remaining
      | remaining <= 0 = pure ()
      | otherwise = do
          refuse hio (hioShut hio) "send"
          r <- overlapped hio ov (hioWriteEvent hio) (hioWriteWait hio) (hioShut hio) $
            c_WriteFile (hioHandle hio) p (fromIntegral (min remaining limit)) nullPtr ov
          case r of
            Right n | n > 0 -> go (p `plusPtr` n) (remaining - n)
            Right _ -> throwIO (ioFailure ResourceVanished "send" "the handle accepted no bytes")
            Left err -> failed hio (hioShut hio) "send" err

-- | The most one write to a socket carries.  The connection's own writes
-- are at most this long, unless a single packet or TLS record is longer.
maxWrite :: Int
maxWrite = 65536

-- | Join neighboring pieces into writes of at most 'maxWrite' bytes; a
-- piece longer than that stays as it is ('hioSendMany' writes it in
-- parts, without a copy).
coalesce :: [B.ByteString] -> [B.ByteString]
coalesce = go [] 0
  where
    go acc _ [] = flush acc
    go acc size (c : cs)
      | size + B.length c > maxWrite = flush acc ++ go [c] (B.length c) cs
      | otherwise = go (c : acc) (size + B.length c) cs
    flush [] = []
    flush [c] = [c]
    flush acc = [B.concat (reverse acc)]

-- | Start an overlapped operation and wait for it: 'Right' the number of
-- bytes it moved, or 'Left' the error it failed with.  The wait is
-- interruptible; interrupted, the operation is canceled and has ended
-- before the exception goes on, so nothing refers to its buffer
-- afterwards.  If the flag is set by the time the operation is pending,
-- it is canceled too (see the module's header).
--
-- In the threaded runtime the operation is started on the issuer thread
-- ('onIssuer'), never on the caller's own.  The 'Wait' is the one of the
-- direction the @OVERLAPPED@ belongs to.
overlapped :: HandleIO -> Ptr () -> HANDLE -> Ptr Wait -> IORef Bool -> IO CInt -> IO (Either ErrCode Int)
overlapped hio ov event wait flag start = mask_ $ do
  started <- onIssuer $ do
    ok <- start
    if ok /= 0 then pure Nothing else Just <$> getLastError
  case started of
    -- It completed at once.
    Nothing -> finished
    Just err
      | err /= eRROR_IO_PENDING -> pure (Left err)
      | otherwise -> do
          stopped <- readIORef flag
          when stopped cancel
          awaitEvent wait event cancel
          finished
  where
    cancel = void (c_CancelIoEx (hioHandle hio) ov)
    -- The outcome as the kernel left it in the OVERLAPPED: the status in
    -- its first word and the count of bytes in its second.  Not
    -- @GetLastError@, which belongs to an OS thread, and this Haskell
    -- thread may be on another one by now.
    finished = do
      status <- peek (castPtr ov) :: IO CUIntPtr
      count <- peekByteOff ov (sizeOf (nullPtr :: Ptr ())) :: IO CUIntPtr
      let ntStatus = fromIntegral status :: Word32
      if ntStatus == 0
        then pure (Right (fromIntegral count))
        else Left <$> c_RtlNtStatusToDosError ntStatus

-- | Run a short action on the issuer thread and return its result.
--
-- Windows cancels a pending overlapped operation when the thread that
-- started it exits: a read started with @ReadFile@ from a thread that
-- then ended completed with @ERROR_OPERATION_ABORTED@, on a socket.  (A
-- completion port saves an operation from that only if its @OVERLAPPED@
-- carries no event, and these carry one.)  A
-- Haskell thread runs on whichever of the runtime's worker threads has
-- it at the moment, and the runtime ends workers it has no more use for,
-- so an operation started in place was canceled now and then with
-- nobody having asked: 5 receives among 294 handles in one run of a
-- group of the test suite (@docs/dev/windows-research.md@).  So every
-- operation is started here, on one bound thread that lives as long as
-- the process.
--
-- The starts are calls that return at once, so one thread serves every
-- connection.  The wait for its answer is not interruptible, and is
-- short: the caller must learn what was started, since a pending
-- operation refers to the caller's buffer.
--
-- Without @-threaded@ the action runs in place.  Every Haskell thread then
-- runs on the operating-system thread that runs the scheduler, which lives
-- as long as the runtime, and there is no bound thread to start one on.
-- (A program whose other operating-system threads call into Haskell would
-- break this, and hmssql doesn't support that without @-threaded@.)
onIssuer :: IO a -> IO a
onIssuer act
  | not rtsSupportsBoundThreads = act
  | otherwise = do
      reply <- newEmptyMVar
      writeChan issuerQueue (try act >>= putMVar reply)
      r <- uninterruptibleMask_ (takeMVar reply)
      either (throwIO :: SomeException -> IO a) pure r

-- | What the issuer thread is given to run.  The thread is started by the
-- first use, and nothing ever stops it or throws to it.
issuerQueue :: Chan (IO ())
issuerQueue = unsafePerformIO $ do
  queue <- newChan
  issuer <- forkOS (forever (join (readChan queue)))
  labelThread issuer "hmssql: I/O issuer"
  pure queue
{-# NOINLINE issuerQueue #-}

-- | Wait until the operation's event is signaled, where an asynchronous
-- exception can interrupt the wait.  Interrupted, it cancels the
-- operation and waits for it to end, uninterruptibly, before rethrowing.
-- Called masked.
--
-- In the threaded runtime the wait is on an 'MVar' that a helper thread
-- fills once its blocking wait on the event returns, and @cancel@ (which
-- must make the event be signaled soon) is how it cancels.  Without
-- @-threaded@ a worker waits instead, in @hmssql_wait_operation@, for the
-- event or for the 'Wait''s cancel event, and on the second cancels the
-- operation itself and waits for it.  Interrupted, this sets the cancel
-- event and waits for the worker's done event, so neither the worker nor
-- the kernel refers to the 'Wait' or the buffer afterwards, even when the
-- worker began its wait only after the interruption.
awaitEvent :: Ptr Wait -> HANDLE -> IO () -> IO ()
awaitEvent wait event cancel = do
  -- Often the operation has completed already: no helper then.
  now <- c_WaitForSingleObjectNow event 0
  unless (now == wAIT_OBJECT_0) $
    if rtsSupportsBoundThreads then onHelper else onWorkerThread
  where
    onHelper = do
      done <- newEmptyMVar
      helper <- forkIO (c_WaitForSingleObject event iNFINITE >>= putMVar done)
      labelThread helper "hmssql: I/O wait"
      r <- takeMVar done `catch` \(e :: SomeException) -> do
        cancel
        _ <- uninterruptibleMask_ (takeMVar done)
        throwIO e
      -- The event is the handle's own and outlives the operation, so the
      -- wait has nothing to fail on.
      unless (r == wAIT_OBJECT_0) $
        throwIO (ioFailure OtherError "wait" ("WaitForSingleObject returned " ++ show r))

    onWorkerThread = do
      c_hmssql_wait_reset wait
      r <- asyncDoProc p_hmssql_wait_operation wait `catch` \(e :: SomeException) -> do
        c_hmssql_wait_cancel wait
        _ <- uninterruptibleMask_ (asyncDoProc p_hmssql_await_done (castPtr wait))
        throwIO e
      unless (r == 0) $
        throwIO (ioFailure OtherError "wait" ("the wait for the operation returned " ++ show r))

-- | Throw if the flag is set or the handle is closed.  The caller holds
-- the operation's lock.
refuse :: HandleIO -> IORef Bool -> String -> IO ()
refuse hio flag what = do
  dead <- readIORef (hioDead hio)
  stopped <- readIORef flag
  when (dead || stopped) $ throwIO (stoppedError what)

-- | Throw the operation's failure: as 'stoppedError' if it was canceled
-- because of the flag.
failed :: HandleIO -> IORef Bool -> String -> ErrCode -> IO a
failed hio flag what err = do
  stopped <- readIORef flag
  if stopped && err == eRROR_OPERATION_ABORTED
    then throwIO (stoppedError what)
    else throwWindows what (if hioPipe hio then err else winsockCode err)

-- | A socket read or written as a handle reports a reset or an aborted
-- connection with the file system's codes, whose messages ("The specified
-- network name is no longer available") say nothing of a connection.
-- Winsock's codes for the same events have the messages a socket's user
-- expects ("An existing connection was forcibly closed by the remote
-- host").
winsockCode :: ErrCode -> ErrCode
winsockCode err
  | err == eRROR_NETNAME_DELETED = wSAECONNRESET
  | err == eRROR_CONNECTION_ABORTED = wSAECONNABORTED
  | otherwise = err

stoppedError :: String -> IOException
stoppedError what = ioFailure ResourceVanished what "the connection was shut down"

ioFailure :: IOErrorType -> String -> String -> IOException
ioFailure ty what why = IOError Nothing ty ("hmssql: " ++ what) why Nothing Nothing

-- | Throw a Windows error as an 'IOException'.  The errors that mean the
-- other end is gone are typed 'ResourceVanished' and given the errno a
-- socket on another platform reports for the same event, so that code
-- which inspects 'ioe_errno' (for @ECONNRESET@, say) needs no Windows
-- case.  base would type them by their own table, which knows none of
-- these but the broken pipe.  The rest are as base makes them.
throwWindows :: String -> ErrCode -> IO a
throwWindows what err = do
  e <- errCodeToIOError ("hmssql: " ++ what) err
  throwIO $ case lookup err peerGone of
    Just (Errno errno) -> e { ioe_type = ResourceVanished, ioe_errno = Just errno }
    Nothing -> e
  where
    peerGone =
      -- The other end reset the connection, or (a pipe) disconnected it.
      [ (eRROR_NETNAME_DELETED, eCONNRESET)
      , (wSAECONNRESET, eCONNRESET)
      , (eRROR_PIPE_NOT_CONNECTED, eCONNRESET)
      , (eRROR_CONNECTION_ABORTED, eCONNABORTED)
      , (wSAECONNABORTED, eCONNABORTED)
      -- A write to a stream whose other end has closed.
      , (eRROR_BROKEN_PIPE, ePIPE)
      , (eRROR_NO_DATA, ePIPE)
      , (wSAESHUTDOWN, ePIPE)
      ]

-- | Make every receive fail from now on, a blocked one included.  Sends
-- still work.  It doesn't wait for the receive to end, and may be called
-- from any thread, any number of times, and after 'hioClose'.
hioStopReceiving :: HandleIO -> IO ()
hioStopReceiving hio = mask_ $ do
  atomicWriteIORef (hioStopRecv hio) True
  withMVar (hioClosed hio) $ \closed ->
    unless closed $ void (c_CancelIoEx (hioHandle hio) (hioReadOv hio))

-- | Make every send and receive fail from now on, blocked ones included,
-- and let the other end know.  It may be called from any thread, any
-- number of times, and after 'hioClose'; not from inside an operation on
-- the same handle.
--
-- A socket is shut down, which the other end sees as the end of the
-- stream, and stays open until 'hioClose'.  A pipe has no shutdown: the
-- other end learns nothing until the handle is closed, and a server that
-- holds part of a message would wait for the rest.  So a pipe is closed
-- here, which waits for the operations just canceled to end and no
-- longer.  The 'hioClose' that follows finds nothing left to do.
hioShutdown :: HandleIO -> IO ()
hioShutdown hio
  | hioPipe hio = hioClose hio
  | otherwise = mask_ $ do
      atomicWriteIORef (hioStopRecv hio) True
      atomicWriteIORef (hioShut hio) True
      withMVar (hioClosed hio) $ \closed -> unless closed $ do
        hioOnShutdown hio `catch` \(_ :: IOException) -> pure ()
        void (c_CancelIoEx (hioHandle hio) nullPtr)

-- | Close the handle and free what the operations used.  Operations in
-- progress are canceled and waited for first, so the handle is never
-- closed under one; later ones fail.  Closing twice is harmless.
hioClose :: HandleIO -> IO ()
hioClose hio = mask_ $ modifyMVar_ (hioClosed hio) $ \closed -> do
  unless closed $ do
    atomicWriteIORef (hioStopRecv hio) True
    atomicWriteIORef (hioShut hio) True
    _ <- c_CancelIoEx (hioHandle hio) nullPtr
    -- An operation that holds a lock has seen the flags or been
    -- canceled, so it lets go soon.
    uninterruptibleMask_ $ takeMVar (hioReadLock hio) >> takeMVar (hioWriteLock hio)
    writeIORef (hioDead hio) True
    hioCloseHandle hio
    _ <- c_CloseHandle (hioReadEvent hio)
    _ <- c_CloseHandle (hioWriteEvent hio)
    free (hioReadOv hio)
    free (hioWriteOv hio)
    freeWait (hioReadWait hio)
    freeWait (hioWriteWait hio)
    countBackendHandle (-1)
    putMVar (hioReadLock hio) ()
    putMVar (hioWriteLock hio) ()
  pure True

-- | How many handles hmssql's Windows backends have open: every handle
-- wrapped here ('newHandleIO') or in "Hmssql.Connection.Backend.WinIO",
-- less every one closed.  For tests of leaks.  Windows has no list of a
-- process's open descriptors to count, and its count of all the process's
-- handles moves with the runtime's threads, by some tens over a few
-- thousand connections with nothing leaked.
backendHandleCount :: IO Int
backendHandleCount = readIORef openHandles

-- | Add to 'backendHandleCount': 1 for a handle wrapped, -1 for one closed.
countBackendHandle :: Int -> IO ()
countBackendHandle d = atomicModifyIORef' openHandles (\n -> (n + d, ()))

openHandles :: IORef Int
openHandles = unsafePerformIO (newIORef 0)
{-# NOINLINE openHandles #-}

------------------------------------------------------------------------------
-- Pipes

-- | Open the client end of a named pipe, such as
-- @\\\\.\\pipe\\SQLLocal\\MSSQLSERVER@.  While every instance of the pipe
-- is busy (@ERROR_PIPE_BUSY@), it tries again every 10 ms for up to
-- 'pipeBusyWait'.  Interruptible: an open that is still in progress when
-- the caller is interrupted closes its handle when it ends.  Call it
-- masked, and install the cleanup before unmasking.
--
-- The handle is opened with @SECURITY_IDENTIFICATION@: the pipe's server
-- can learn who the client is, but can't act as the client, whoever the
-- server turns out to be.  It is the most restrictive level SQL Server
-- was seen to accept: with @SECURITY_ANONYMOUS@ it refused every login
-- over the Named Pipes protocol (error 18456, state 10), and no
-- difference was measured between this level and the default,
-- @SECURITY_IMPERSONATION@ (@docs/dev/windows-research.md@).
openPipe :: FilePath -> IO HandleIO
openPipe path = do
  requireRuntime
  h <- openPipeWith path attempt
  newHandleIO h True (pure ()) (void (c_CloseHandle h)) `onException` c_CloseHandle h
  where
    -- Opening a pipe on another machine waits for the network, in a
    -- foreign call.
    attempt
      | rtsSupportsBoundThreads = abandonable (createPipeClient path) (either (\_ -> pure ()) (void . c_CloseHandle))
      | otherwise = mask_ $ do
          req <- withCWString path $ \p -> c_hmssql_open_new p pipeAccess pipeFlags
          when (req == nullPtr) $ throwIO (outOfMemory "open")
          _ <- onWorker p_hmssql_open_run req (c_hmssql_open_free req 0)
          h <- c_hmssql_open_result req
          err <- c_hmssql_open_error req
          -- The handle is the caller's now.
          c_hmssql_open_free req 1
          pure (if h == iNVALID_HANDLE_VALUE then Left err else Right h)

-- | Open the client end of a pipe with the attempt given, trying again
-- while every instance is busy, as 'openPipe' says: the handle, or the
-- failure thrown.  The wait between two attempts is interruptible.
openPipeWith :: FilePath -> IO (Either ErrCode HANDLE) -> IO HANDLE
openPipeWith path attempt = go (pipeBusyWait `div` 10_000)
  where
    go :: Int -> IO HANDLE
    go tries = attempt >>= \case
      Right h -> pure h
      Left err
        | err == eRROR_PIPE_BUSY && tries > 0 -> threadDelay 10_000 >> go (tries - 1)
        | otherwise -> throwWindows ("open " ++ path) err

-- | One attempt to open the client end of a pipe, with 'openPipe''s
-- access and flags, the handle opened for overlapped I/O: the handle, or
-- the error.  A safe foreign call, which waits as long as the open does.
createPipeClient :: FilePath -> IO (Either ErrCode HANDLE)
createPipeClient path = withCWString path $ \p -> do
  h <- c_CreateFileW p pipeAccess 0 nullPtr oPEN_EXISTING pipeFlags nullPtr
  if h == iNVALID_HANDLE_VALUE then Left <$> getLastError else pure (Right h)

pipeAccess, pipeFlags :: DWORD
pipeAccess = gENERIC_READ .|. gENERIC_WRITE
pipeFlags = fILE_FLAG_OVERLAPPED .|. sECURITY_SQOS_PRESENT .|. sECURITY_IDENTIFICATION

-- | How long 'openPipe' keeps trying a pipe whose instances are all busy,
-- in microseconds: 30 seconds.
--
-- A busy pipe is Windows saying "wait and try again", and how long to go
-- on is the client's choice.  This is of the order of a TCP connect's own
-- patience (about 21 s on Windows) and above the 15 s that Microsoft's
-- client allows a login by default.  A SQL Server whose pipe listener
-- has stopped presents exactly this, and was seen to stay that way for 8
-- to 57 seconds; with the 5 s this started as, the test suite's first
-- connections failed where a little patience would have connected.  A
-- caller who wants less wraps 'Hmssql.Connection.connect' in a timeout,
-- as for any other connect.
pipeBusyWait :: Int
pipeBusyWait = 30_000_000

-- | The server side of a named pipe: for a mock server in tests, or a
-- proxy.
data PipeListener = PipeListener
  { plPath :: !FilePath
  , plPending :: !(MVar (Maybe HandleIO))
    -- ^ The instance the next client connects to, until the listener is
    -- closed.  There is always one, so that the pipe exists and a client
    -- finds it busy rather than missing.
  }

-- | Create a named pipe (which must not exist yet) that clients on this
-- machine can connect to.  Creating a pipe needs no privilege.
pipeListenerOpen :: FilePath -> IO PipeListener
pipeListenerOpen path = do
  requireRuntime
  mask_ $ do
    first <- newInstance path True
    PipeListener path <$> newMVar (Just first)

-- | One more instance of the pipe, waiting for a client.
newInstance :: FilePath -> Bool -> IO HandleIO
newInstance path first = do
  h <- createPipeInstance path first
  newHandleIO h True (pure ()) (void (c_CloseHandle h)) `onException` c_CloseHandle h

-- | Create an instance of the pipe, for overlapped I/O, that only clients
-- on this machine can connect to.  The flag says it is the first, which
-- makes the creation fail if the pipe exists already.  Throws on failure.
createPipeInstance :: FilePath -> Bool -> IO HANDLE
createPipeInstance path first = do
  h <- withCWString path $ \p -> c_CreateNamedPipeW p
    (pIPE_ACCESS_DUPLEX .|. fILE_FLAG_OVERLAPPED .|. (if first then fILE_FLAG_FIRST_PIPE_INSTANCE else 0))
    pIPE_REJECT_REMOTE_CLIENTS pIPE_UNLIMITED_INSTANCES 65536 65536 0 nullPtr
  when (h == iNVALID_HANDLE_VALUE) $
    getLastError >>= throwWindows ("create " ++ path)
  pure h

-- | Wait for a client and return the connection to it.  Interruptible;
-- one thread accepts at a time.
--
-- An accept that is interrupted, or fails, leaves the listener as it was.
-- If the next instance of the pipe can't be created once a client has
-- connected, that client's connection is closed and the listener with
-- it, since without an instance the pipe would no longer exist.
pipeListenerAccept :: PipeListener -> IO HandleIO
pipeListenerAccept pl = mask_ $ takeMVar pending >>= \case
  Nothing -> do
    putMVar pending Nothing
    throwIO (ioFailure IllegalOperation "accept" "the pipe listener is closed")
  Just hio -> do
    never <- newIORef False
    let ov = hioReadOv hio
        -- The instance is still good, and still the one to connect to.
        asItWas = putMVar pending (Just hio)
    r <- overlapped hio ov (hioReadEvent hio) (hioReadWait hio) never (c_ConnectNamedPipe (hioHandle hio) ov)
      `onException` asItWas
    case r of
      Right _ -> pure ()
      Left err
        -- The client connected before this was called.
        | err == eRROR_PIPE_CONNECTED -> pure ()
        -- It connected and has closed its end already (a connect that
        -- was interrupted at once does that).  Still a connection, as a
        -- socket accepted after its client has gone is: whoever is
        -- handed it reads the end of the stream.
        | err == eRROR_NO_DATA -> pure ()
        | otherwise -> asItWas >> throwWindows "accept" err
    try (newInstance (plPath pl) False) >>= \case
      Right next -> hio <$ putMVar pending (Just next)
      Left (e :: SomeException) -> do
        hioClose hio
        putMVar pending Nothing
        throwIO e
  where
    pending = plPending pl

-- | Stop listening.  Connections already accepted are not affected.  It
-- waits for an accept in progress, so stop the accepting thread first.
pipeListenerClose :: PipeListener -> IO ()
pipeListenerClose pl = mask_ $ modifyMVar_ (plPending pl) $ \pending -> do
  mapM_ hioClose pending
  pure Nothing

-- | On the server side of a pipe: disconnect the client, discarding what
-- it has not read yet, so that its next read or write fails.  The nearest
-- a pipe has to a TCP reset.  The handle must still be closed.
pipeDisconnect :: HandleIO -> IO ()
pipeDisconnect hio = mask_ $ withMVar (hioClosed hio) $ \closed ->
  unless closed $ void (c_DisconnectNamedPipe (hioHandle hio))

------------------------------------------------------------------------------
-- Helpers

-- | Run a blocking action (a foreign call that nothing can interrupt) on a
-- thread of its own and wait for its result, where an asynchronous
-- exception can interrupt the wait.  Interrupted, the action is left to
-- finish, and what it returns is given to the cleanup, so a handle it
-- opened is not leaked.  Call it masked, so that the result can't be lost
-- between this and the caller's own cleanup.
abandonable :: IO a -> (a -> IO ()) -> IO a
abandonable act cleanup = mask_ $ do
  result <- newEmptyMVar
  -- Whether the caller has given up, decided once.
  abandoned <- newMVar False
  helper <- forkIO $ do
    r <- try act
    gone <- takeMVar abandoned
    case r of
      Right a | gone -> cleanup a `catch` \(_ :: SomeException) -> pure ()
      _ -> pure ()
    putMVar result r
    putMVar abandoned gone
  labelThread helper "hmssql: blocking call"
  r <- takeMVar result `catch` \(e :: SomeException) -> uninterruptibleMask_ $ do
    -- The helper holds 'abandoned' only between the action's end and its
    -- result, so this doesn't wait for the action.
    gone <- takeMVar abandoned
    done <- tryTakeMVar result
    putMVar abandoned True
    case done of
      -- The action had ended, and its result is the caller's to clean up.
      Just (Right a) | not gone -> cleanup a `catch` \(_ :: SomeException) -> pure ()
      _ -> pure ()
    throwIO e
  either (throwIO :: SomeException -> IO a) pure r

-- | Throw if the program can't run this module's I/O: one linked without
-- @-threaded@ and run with GHC's native I/O manager
-- (@+RTS --io-manager=native@), whose released versions have no workers
-- for 'onWorker' (@asyncDoProc@ crashes the program there).  Nothing
-- comes here in that configuration when hmssql was built to use the
-- manager ('Hmssql.Connection.Backend.WinIO.nativeIO'), so this refuses
-- only a build that can't.
requireRuntime :: IO ()
requireRuntime = when (not rtsSupportsBoundThreads && isWindowsNativeIO) $
  throwIO $ ioFailure UnsupportedOperation "connect"
    ("on Windows without -threaded, GHC's native I/O manager needs hmssql built against network 3.3 or later "
      ++ "with a GHC whose native manager network supports: link the program with -threaded, "
      ++ "or run it without --io-manager=native")

-- | Run a C function on a request, on a worker thread of the default I/O
-- manager (@asyncDoProc@), and return what it returns.  The other Haskell
-- threads run meanwhile, and an asynchronous exception interrupts the
-- wait.  Interrupted, the function runs on, and @abandoned@ runs on a
-- thread of its own once it has ended (once it signals the request's done
-- event), to free the request and whatever the call made.  Without
-- @-threaded@ only: in the threaded runtime @asyncDoProc@ ends the
-- program.  Call it masked.
onWorker :: FunPtr (Ptr r -> IO Int) -> Ptr r -> IO () -> IO Int
onWorker proc req abandoned = asyncDoProc proc req `catch` \(e :: SomeException) -> do
  helper <- forkIO $ uninterruptibleMask_ $ do
    _ <- asyncDoProc p_hmssql_await_done (castPtr req)
    abandoned
  labelThread helper "hmssql: abandoned call"
  throwIO e

-- | The host's addresses for the port, as network's @getAddrInfo@ gives
-- them for the hints.  Interruptible: in the threaded runtime the lookup
-- runs on a thread of its own ('abandonable'), and without @-threaded@ on a
-- worker ('onWorker'), where it is a call to @getaddrinfo@ read back with
-- network's own @Storable AddrInfo@.
lookupAddresses :: Socket.AddrInfo -> String -> String -> IO [Socket.AddrInfo]
lookupAddresses hints host port
  | rtsSupportsBoundThreads = abandonable (Socket.getAddrInfo (Just hints) (Just host) (Just port)) (\_ -> pure ())
  | otherwise = Socket.withSocketsDo $ mask_ $ do
      requireRuntime
      req <- withCString host $ \h -> withCString port $ \p -> alloca $ \hp -> do
        poke hp hints
        c_hmssql_lookup_new h p hp
      when (req == nullPtr) $ throwIO (outOfMemory "getAddrInfo")
      _ <- onWorker p_hmssql_lookup_run req (c_hmssql_lookup_free req)
      flip finally (c_hmssql_lookup_free req) $ do
        err <- c_hmssql_lookup_error req
        unless (err == 0) $ do
          e <- errCodeToIOError ("hmssql: getAddrInfo (host name " ++ show host ++ ", service name " ++ show port ++ ")")
            (fromIntegral err)
          throwIO e { ioe_type = NoSuchThing }
        c_hmssql_lookup_result req >>= follow
  where
    follow ai
      | ai == nullPtr = pure []
      | otherwise = (:) <$> peek ai <*> (c_hmssql_addrinfo_next ai >>= follow)

-- | Connect the socket to the address on a worker ('onWorker'), without
-- @-threaded@.  If the connect fails the socket is closed, with the closer
-- given, and network's exception for the failure is thrown; if the caller
-- is interrupted, the socket is closed once the connect ends.
connectOnWorker :: (Socket -> IO ()) -> Socket -> Socket.SockAddr -> IO ()
connectOnWorker closeIt sock addr = mask_ $ do
  requireRuntime `onException` closeIt sock
  fd <- Socket.unsafeFdSocket sock
  let size = Socket.sizeOfSocketAddress addr
  req <- allocaBytes size $ \p -> do
    Socket.pokeSocketAddress p addr
    c_hmssql_connect_new (fromIntegral fd) p (fromIntegral size)
  when (req == nullPtr) $ closeIt sock >> throwIO (outOfMemory "connect")
  _ <- onWorker p_hmssql_connect_run req (closeIt sock >> c_hmssql_connect_free req)
  err <- c_hmssql_connect_error req
  c_hmssql_connect_free req
  unless (err == 0) $ do
    closeIt sock
    -- Named as network names it, with the descriptor it had.
    Socket.throwSocketErrorCode ("Network.Socket.connect: <socket: " ++ show fd ++ ">") err

outOfMemory :: String -> IOException
outOfMemory what = ioFailure ResourceExhausted what "out of memory"

-- | Run the action with the value kept reachable until it is done.
keepAlive :: a -> IO b -> IO b
keepAlive x (IO act) = IO (\s -> keepAlive# x s act)

------------------------------------------------------------------------------
-- The Windows API

gENERIC_READ, gENERIC_WRITE, oPEN_EXISTING, fILE_FLAG_OVERLAPPED, fILE_FLAG_FIRST_PIPE_INSTANCE :: DWORD
gENERIC_READ = 0x80000000
gENERIC_WRITE = 0x40000000
oPEN_EXISTING = 3
fILE_FLAG_OVERLAPPED = 0x40000000
fILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000

sECURITY_SQOS_PRESENT, sECURITY_IDENTIFICATION :: DWORD
sECURITY_SQOS_PRESENT = 0x00100000
sECURITY_IDENTIFICATION = 0x00010000

pIPE_ACCESS_DUPLEX, pIPE_REJECT_REMOTE_CLIENTS, pIPE_UNLIMITED_INSTANCES :: DWORD
pIPE_ACCESS_DUPLEX = 3
pIPE_REJECT_REMOTE_CLIENTS = 8
pIPE_UNLIMITED_INSTANCES = 255

wAIT_OBJECT_0 :: DWORD
wAIT_OBJECT_0 = 0

eRROR_HANDLE_EOF, eRROR_NETNAME_DELETED, eRROR_BROKEN_PIPE, eRROR_PIPE_BUSY, eRROR_NO_DATA,
  eRROR_PIPE_NOT_CONNECTED, eRROR_PIPE_CONNECTED, eRROR_OPERATION_ABORTED, eRROR_IO_PENDING,
  eRROR_CONNECTION_ABORTED, wSAECONNABORTED, wSAECONNRESET, wSAESHUTDOWN :: ErrCode
eRROR_HANDLE_EOF = 38
eRROR_NETNAME_DELETED = 64
eRROR_BROKEN_PIPE = 109
eRROR_PIPE_BUSY = 231
eRROR_NO_DATA = 232
eRROR_PIPE_NOT_CONNECTED = 233
eRROR_PIPE_CONNECTED = 535
eRROR_OPERATION_ABORTED = 995
eRROR_IO_PENDING = 997
eRROR_CONNECTION_ABORTED = 1236
wSAECONNABORTED = 10053
wSAECONNRESET = 10054
wSAESHUTDOWN = 10058

iNVALID_HANDLE_VALUE :: HANDLE
iNVALID_HANDLE_VALUE = intPtrToPtr (-1)

-- The calls that start or cancel an operation return at once on a handle
-- opened for overlapped I/O, so they are unsafe calls; the ones that can
-- wait are safe.  BOOL is a C int.

foreign import ccall unsafe "windows.h ReadFile"
  c_ReadFile :: HANDLE -> Ptr Word8 -> DWORD -> Ptr DWORD -> Ptr () -> IO CInt

foreign import ccall unsafe "windows.h WriteFile"
  c_WriteFile :: HANDLE -> Ptr Word8 -> DWORD -> Ptr DWORD -> Ptr () -> IO CInt

-- NTSTATUS to a Win32 error code: a pure table lookup in ntdll.
foreign import ccall unsafe "RtlNtStatusToDosError"
  c_RtlNtStatusToDosError :: Word32 -> IO ErrCode

foreign import ccall unsafe "windows.h CancelIoEx"
  c_CancelIoEx :: HANDLE -> Ptr () -> IO CInt

foreign import ccall unsafe "windows.h CreateEventW"
  c_CreateEventW :: Ptr () -> CInt -> CInt -> CWString -> IO HANDLE

foreign import ccall unsafe "windows.h WaitForSingleObject"
  c_WaitForSingleObjectNow :: HANDLE -> DWORD -> IO DWORD

foreign import ccall safe "windows.h WaitForSingleObject"
  c_WaitForSingleObject :: HANDLE -> DWORD -> IO DWORD

foreign import ccall unsafe "windows.h ConnectNamedPipe"
  c_ConnectNamedPipe :: HANDLE -> Ptr () -> IO CInt

foreign import ccall safe "windows.h CloseHandle"
  c_CloseHandle :: HANDLE -> IO CInt

foreign import ccall safe "windows.h CreateFileW"
  c_CreateFileW :: CWString -> DWORD -> DWORD -> Ptr () -> DWORD -> DWORD -> HANDLE -> IO HANDLE

foreign import ccall safe "windows.h CreateNamedPipeW"
  c_CreateNamedPipeW :: CWString -> DWORD -> DWORD -> DWORD -> DWORD -> DWORD -> DWORD -> Ptr () -> IO HANDLE

foreign import ccall safe "windows.h DisconnectNamedPipe"
  c_DisconnectNamedPipe :: HANDLE -> IO CInt

------------------------------------------------------------------------------
-- cbits/windows.c, for the non-threaded runtime.  The functions given to
-- asyncDoProc take the request and run on a worker; the rest return at
-- once.

-- | @hmssql_wait@: what a worker waits for an operation of one direction of
-- a handle with ('awaitEvent').
data Wait

-- | @hmssql_lookup@, @hmssql_connect@ and @hmssql_open@: one call each.
data Lookup
data Connect
data Open

foreign import ccall unsafe "&hmssql_await_done"
  p_hmssql_await_done :: FunPtr (Ptr () -> IO Int)

foreign import ccall unsafe "hmssql_wait_new"
  c_hmssql_wait_new :: HANDLE -> Ptr () -> HANDLE -> IO (Ptr Wait)

foreign import ccall unsafe "hmssql_wait_free"
  c_hmssql_wait_free :: Ptr Wait -> IO ()

foreign import ccall unsafe "hmssql_wait_reset"
  c_hmssql_wait_reset :: Ptr Wait -> IO ()

foreign import ccall unsafe "hmssql_wait_cancel"
  c_hmssql_wait_cancel :: Ptr Wait -> IO ()

foreign import ccall unsafe "&hmssql_wait_operation"
  p_hmssql_wait_operation :: FunPtr (Ptr Wait -> IO Int)

foreign import ccall unsafe "hmssql_lookup_new"
  c_hmssql_lookup_new :: CString -> CString -> Ptr Socket.AddrInfo -> IO (Ptr Lookup)

foreign import ccall unsafe "&hmssql_lookup_run"
  p_hmssql_lookup_run :: FunPtr (Ptr Lookup -> IO Int)

foreign import ccall unsafe "hmssql_lookup_error"
  c_hmssql_lookup_error :: Ptr Lookup -> IO CInt

foreign import ccall unsafe "hmssql_lookup_result"
  c_hmssql_lookup_result :: Ptr Lookup -> IO (Ptr Socket.AddrInfo)

foreign import ccall unsafe "hmssql_addrinfo_next"
  c_hmssql_addrinfo_next :: Ptr Socket.AddrInfo -> IO (Ptr Socket.AddrInfo)

foreign import ccall unsafe "hmssql_lookup_free"
  c_hmssql_lookup_free :: Ptr Lookup -> IO ()

foreign import ccall unsafe "hmssql_connect_new"
  c_hmssql_connect_new :: CUIntPtr -> Ptr () -> CInt -> IO (Ptr Connect)

foreign import ccall unsafe "&hmssql_connect_run"
  p_hmssql_connect_run :: FunPtr (Ptr Connect -> IO Int)

foreign import ccall unsafe "hmssql_connect_error"
  c_hmssql_connect_error :: Ptr Connect -> IO CInt

foreign import ccall unsafe "hmssql_connect_free"
  c_hmssql_connect_free :: Ptr Connect -> IO ()

foreign import ccall unsafe "hmssql_open_new"
  c_hmssql_open_new :: CWString -> DWORD -> DWORD -> IO (Ptr Open)

foreign import ccall unsafe "&hmssql_open_run"
  p_hmssql_open_run :: FunPtr (Ptr Open -> IO Int)

foreign import ccall unsafe "hmssql_open_result"
  c_hmssql_open_result :: Ptr Open -> IO HANDLE

foreign import ccall unsafe "hmssql_open_error"
  c_hmssql_open_error :: Ptr Open -> IO ErrCode

foreign import ccall unsafe "hmssql_open_free"
  c_hmssql_open_free :: Ptr Open -> CInt -> IO ()
#endif
