{-# LANGUAGE CPP #-}
{-# LANGUAGE EmptyCase #-}
-- | Shared Memory and Named Pipes through GHC's native I/O manager (WinIO):
-- each operation on a pipe is an overlapped @ReadFile@, @WriteFile@ or
-- @ConnectNamedPipe@ made with @GHC.Event.Windows.withOverlapped@, on a
-- handle associated with the manager's completion port.  It is used when
-- 'nativeIO' holds, with or without @-threaded@, and then TCP goes through
-- network's own calls; otherwise the pipes go through
-- "Hmssql.Connection.Backend.Windows", whose foreign calls and errors this
-- module shares.  On other platforms this module is empty.
--
-- The manager does what that module does by hand.  An asynchronous
-- exception interrupts a pending operation, which the manager then cancels
-- with @CancelIoEx@ and waits for, uninterruptibly, so the buffer is never
-- freed while the kernel may still write to it.  A completion is processed
-- by the manager's thread, or without @-threaded@ by the scheduler, so no
-- operation needs an event, a helper thread or a worker of its own, and a
-- pipe opened without @-threaded@ needs no @asyncDoProc@.
--
-- Closing is as on the other path: a flag that later operations check,
-- then @CancelIoEx@ on the whole handle, then a wait for the operations in
-- progress.  An operation that becomes pending checks the flag once more,
-- in its start callback, and cancels itself if the flag is set by then, so
-- a close that comes between an operation's first check and its start is
-- not lost.  'pioStopReceiving' only sets the flag: the manager allocates
-- each operation's @OVERLAPPED@, so there is no address to cancel the
-- receive alone by, and hmssql kills the reader thread right after it,
-- which cancels the receive inside the manager.
module Hmssql.Connection.Backend.WinIO
#if !defined(mingw32_HOST_OS)
  () where
#else
  ( nativeIO
  , PipeIO
  , openPipe
  , pioRecv
  , pioSendMany
  , pioStopReceiving
  , pioClose
  , PipeListener
  , pipeListenerOpen
  , pipeListenerAccept
  , pipeListenerClose
  , pipeDisconnect
  ) where

#if MIN_VERSION_network(3,3,0) && __IO_MANAGER_WINIO__ >= 2
import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless, void, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Data.IORef
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import GHC.Event.Windows (CbResult (..), IOResult (..), LPOVERLAPPED, associateHandle', withOverlapped)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.SubSystem (isWindowsNativeIO)
import GHC.Windows (DWORD, ErrCode, HANDLE, getLastError)

import Hmssql.Connection.Backend.Windows
  ( abandonable
  , c_CancelIoEx
  , c_CloseHandle
  , c_ConnectNamedPipe
  , c_DisconnectNamedPipe
  , c_ReadFile
  , c_RtlNtStatusToDosError
  , c_WriteFile
  , countBackendHandle
  , createPipeClient
  , createPipeInstance
  , eRROR_BROKEN_PIPE
  , eRROR_HANDLE_EOF
  , eRROR_IO_PENDING
  , eRROR_NO_DATA
  , eRROR_OPERATION_ABORTED
  , eRROR_PIPE_CONNECTED
  , ioFailure
  , openPipeWith
  , stoppedError
  , throwWindows
  )
#else
import Control.Exception (throwIO)
import GHC.IO.Exception (IOErrorType (..))
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import qualified Data.ByteString as B
import Hmssql.Connection.Backend.Windows (ioFailure)
#endif

-- | Whether hmssql's Windows I/O goes through GHC's native I/O manager:
-- TCP through network's own calls, as on Linux and macOS, and the pipes
-- through this module.  True only when hmssql was built against network
-- 3.3 or later, with a compiler that defines @__IO_MANAGER_WINIO__@ as 2
-- or more (the only case in which network compiles its code for the
-- native manager), and the program runs under that manager
-- (@+RTS --io-manager=native@, fixed when the runtime starts), with or
-- without @-threaded@.  Otherwise both go through
-- "Hmssql.Connection.Backend.Windows".
--
-- Without @-threaded@, network's blocking calls (@sendMany@ once the
-- server stops reading, @connect@, @getAddrInfo@) and the open of a pipe
-- stop every Haskell thread while they block, as @getAddrInfo@ does on
-- Linux and macOS.  A GHC without the fix of its manager's completions
-- (on the branch @wip/winio-completion-packets@, 2026-11-07) crashes under
-- load and, without @-threaded@, freezes.
nativeIO :: Bool

#if MIN_VERSION_network(3,3,0) && __IO_MANAGER_WINIO__ >= 2
nativeIO = isWindowsNativeIO

-- | A pipe handle associated with the manager's completion port.  From
-- then on it must not reach "Hmssql.Connection.Backend.Windows"'s
-- operations, whose events keep their completions off the port.
data PipeIO = PipeIO
  { pioHandle :: !HANDLE
  , pioReadLock :: !(MVar ())
    -- ^ Held for the whole of a receive, so one is in progress at a time
    -- and 'pioClose' can wait for it; 'pioWriteLock' is the sends'.
  , pioWriteLock :: !(MVar ())
  , pioStopRecv :: !(IORef Bool)
    -- ^ Receives fail: 'pioStopReceiving' or 'pioClose' was called.
  , pioShut :: !(IORef Bool)
    -- ^ Sends fail as well: 'pioClose' was called.
  , pioClosed :: !(MVar Bool)
    -- ^ The handle is closed.  Held while 'pipeDisconnect' uses it.
  }

-- | Associate an open pipe handle with the manager and wrap it.  If this
-- fails, the handle is left open, for the caller to close.
--
-- An operation that completes at once then posts no completion packet
-- (@FILE_SKIP_COMPLETION_PORT_ON_SUCCESS@), so a write that the pipe
-- takes at once, which is most of them, is finished on the caller's
-- thread instead of after a switch to the manager's.  The manager asks the
-- handle for this mode when an operation completes at once.  It took a
-- round trip of 100 bytes over a pipe from 52 µs to 36 to 39 threaded, and
-- from 12 to 9 not threaded.  If Windows refuses the mode, the handle
-- works without it.
newPipeIO :: HANDLE -> IO PipeIO
newPipeIO h = mask_ $ do
  associateHandle' h
  _ <- c_SetFileCompletionNotificationModes h fILE_SKIP_COMPLETION_PORT_ON_SUCCESS
  pio <- PipeIO h <$> newMVar () <*> newMVar () <*> newIORef False <*> newIORef False <*> newMVar False
  countBackendHandle 1
  pure pio

-- | Open the client end of a named pipe, as
-- 'Hmssql.Connection.Backend.Windows.openPipe' does: the same flags, and
-- the same retries while every instance is busy.  Windows has no
-- asynchronous open, so in the threaded runtime the open runs on a thread
-- of its own ('abandonable') and is interruptible.  Without @-threaded@ it
-- is a safe foreign call, which stops every Haskell thread while it
-- blocks: a local pipe opens or fails at once, and a pipe on another
-- machine waits for the network.  Call it masked.
openPipe :: FilePath -> IO PipeIO
openPipe path = do
  h <- openPipeWith path attempt
  newPipeIO h `onException` c_CloseHandle h
  where
    attempt
      | rtsSupportsBoundThreads = abandonable (createPipeClient path) (either (\_ -> pure ()) (void . c_CloseHandle))
      | otherwise = createPipeClient path

-- | Start an operation through the manager and wait for it: 'Right' the
-- number of bytes it moved, or 'Left' the Win32 error it ended with.
-- Interruptible; interrupted, the manager cancels the operation and waits
-- for it before the exception goes on.
overlapped :: String -> HANDLE -> (LPOVERLAPPED -> IO (CbResult Int)) -> IO (Either ErrCode Int)
overlapped what h start = do
  r <- withOverlapped ("hmssql: " ++ what) h 0 start (\err n -> IOSuccess <$> outcome err n)
  pure $ case r of
    IOSuccess v -> v
    -- Not reached: the completion never fails.
    IOFailed e -> Left (maybe 0 fromIntegral e)

-- | The start of a @ReadFile@ or a @WriteFile@, given as the call.  The
-- manager works out from the call's result and last error whether a
-- completion packet is coming.  A call that becomes pending after the flag
-- was set cancels itself.
startCall :: HANDLE -> IORef Bool -> (Ptr () -> IO CInt) -> LPOVERLAPPED -> IO (CbResult Int)
startCall h flag call ov = do
  ok <- call (castPtr ov)
  if ok /= 0 then pure (CbNone True) else do
    err <- getLastError
    if err /= eRROR_IO_PENDING then pure (CbNone False) else do
      stopped <- readIORef flag
      when stopped $ void (c_CancelIoEx h (castPtr ov))
      pure CbPending

-- | What a completion means.  @ERROR_MORE_DATA@ is a success: the buffer
-- is full.  A code with an NTSTATUS's severity bits is converted first:
-- the GHC master of October 2026 passed the status itself
-- (@0xC000014B@ for a broken pipe), and a release may still.
outcome :: ErrCode -> DWORD -> IO (Either ErrCode Int)
outcome err n
  | err .&. 0xC0000000 /= 0 = c_RtlNtStatusToDosError err >>= \e -> outcome e n
  | err == 0 || err == eRROR_MORE_DATA = pure (Right (fromIntegral n))
  | otherwise = pure (Left err)

-- | Receive up to that many bytes into the buffer: how many arrived, or 0
-- at the end of the stream.  Blocks until some do; an asynchronous
-- exception or 'pioClose' ends the wait.  The buffer must stay valid until
-- this returns or throws.
pioRecv :: PipeIO -> Ptr Word8 -> Int -> IO Int
pioRecv pio buf size = withMVar (pioReadLock pio) $ \() -> do
  refuse (pioStopRecv pio) "receive"
  r <- overlapped "receive" h $ startCall h (pioStopRecv pio) $ \ov ->
    c_ReadFile h buf (fromIntegral size) nullPtr ov
  case r of
    Right n -> pure n
    Left err
      -- The other end closed its handle.
      | err == eRROR_BROKEN_PIPE || err == eRROR_HANDLE_EOF -> pure 0
      | otherwise -> failed (pioStopRecv pio) "receive" err
  where
    h = pioHandle pio

-- | Send all of the writes, in order, with no other send's bytes between
-- them.  Each write is its pieces copied together (a write of one piece
-- is not copied) and is one @WriteFile@, because SQL Server reads a pipe a
-- write at a time ('Hmssql.Connection.Backend.Windows.hioSendMany').
-- Blocks while the other end doesn't read; an asynchronous exception or
-- 'pioClose' ends the wait, with part of the bytes possibly sent.
pioSendMany :: PipeIO -> [[B.ByteString]] -> IO ()
pioSendMany pio writes0 = case filter (not . B.null) (map B.concat writes0) of
  [] -> pure ()
  writes -> withMVar (pioWriteLock pio) $ \() -> mapM_ sendOne writes
  where
    h = pioHandle pio
    sendOne (BI.BS fp len) = withForeignPtr fp $ \p -> go p len
    go :: Ptr Word8 -> Int -> IO ()
    go p remaining
      | remaining <= 0 = pure ()
      | otherwise = do
          refuse (pioShut pio) "send"
          r <- overlapped "send" h $ startCall h (pioShut pio) $ \ov ->
            c_WriteFile h p (fromIntegral remaining) nullPtr ov
          case r of
            -- A write to a pipe completes whole or fails, so this loops
            -- only if Windows ever says otherwise.
            Right n | n > 0 -> go (p `plusPtr` n) (remaining - n)
            Right _ -> throwIO (ioFailure ResourceVanished "send" "the handle accepted no bytes")
            Left err -> failed (pioShut pio) "send" err

-- | Throw if the flag is set.  The caller holds the operation's lock.
refuse :: IORef Bool -> String -> IO ()
refuse flag what = do
  stopped <- readIORef flag
  when stopped $ throwIO (stoppedError what)

-- | Throw the operation's failure: as 'stoppedError' if it was canceled
-- because of the flag, and otherwise as on the other path, so that the
-- errors that mean the other end is gone are typed alike.
failed :: IORef Bool -> String -> ErrCode -> IO a
failed flag what err = do
  stopped <- readIORef flag
  if stopped && err == eRROR_OPERATION_ABORTED
    then throwIO (stoppedError what)
    else throwWindows what err

-- | Make every later receive fail.  A receive already pending goes on:
-- hmssql kills the reader thread right after this, which cancels it.  It
-- doesn't block, and may be called from any thread, any number of times,
-- and after 'pioClose'.
pioStopReceiving :: PipeIO -> IO ()
pioStopReceiving pio = atomicWriteIORef (pioStopRecv pio) True

-- | Close the handle.  Operations in progress are canceled and waited for
-- first, so the handle is never closed under one; later ones fail.  A pipe
-- has no shutdown, so this is also the backend's shutdown, which tells the
-- other end.  Closing twice is harmless.
pioClose :: PipeIO -> IO ()
pioClose pio = mask_ $ modifyMVar_ (pioClosed pio) $ \closed -> do
  unless closed $ do
    atomicWriteIORef (pioStopRecv pio) True
    atomicWriteIORef (pioShut pio) True
    _ <- c_CancelIoEx (pioHandle pio) nullPtr
    -- An operation that holds a lock has seen the flags or been canceled,
    -- so it lets go once the manager has its cancellation.
    uninterruptibleMask_ $ takeMVar (pioReadLock pio) >> takeMVar (pioWriteLock pio)
    _ <- c_CloseHandle (pioHandle pio)
    countBackendHandle (-1)
    putMVar (pioReadLock pio) ()
    putMVar (pioWriteLock pio) ()
  pure True

-- | The server side of a named pipe, as
-- 'Hmssql.Connection.Backend.Windows.PipeListener'.
data PipeListener = PipeListener
  { plPath :: !FilePath
  , plPending :: !(MVar (Maybe PipeIO))
    -- ^ The instance the next client connects to, until the listener is
    -- closed.  There is always one, so that the pipe exists and a client
    -- finds it busy rather than missing.
  }

-- | Create a named pipe (which must not exist yet) that clients on this
-- machine can connect to.
pipeListenerOpen :: FilePath -> IO PipeListener
pipeListenerOpen path = mask_ $ do
  first <- newInstance path True
  PipeListener path <$> newMVar (Just first)

newInstance :: FilePath -> Bool -> IO PipeIO
newInstance path first = do
  h <- createPipeInstance path first
  newPipeIO h `onException` c_CloseHandle h

-- | Wait for a client and return the connection to it, as
-- 'Hmssql.Connection.Backend.Windows.pipeListenerAccept' does.
-- Interruptible; one thread accepts at a time.  An accept that is
-- interrupted, or fails, leaves the listener as it was.
pipeListenerAccept :: PipeListener -> IO PipeIO
pipeListenerAccept pl = mask_ $ takeMVar pending >>= \case
  Nothing -> do
    putMVar pending Nothing
    throwIO (ioFailure IllegalOperation "accept" "the pipe listener is closed")
  Just pio -> do
    -- The instance is still good, and still the one to connect to.
    let asItWas = putMVar pending (Just pio)
    r <- overlapped "accept" (pioHandle pio) (startConnect (pioHandle pio)) `onException` asItWas
    case r of
      Right _ -> pure ()
      Left err -> asItWas >> throwWindows "accept" err
    try (newInstance (plPath pl) False) >>= \case
      Right next -> pio <$ putMVar pending (Just next)
      Left (e :: SomeException) -> do
        pioClose pio
        putMVar pending Nothing
        throwIO e
  where
    pending = plPending pl

-- | The start of a @ConnectNamedPipe@, classified here, since the
-- manager's own classification is for calls that read or write.  A client
-- that connected before the call (@ERROR_PIPE_CONNECTED@), or connected and
-- closed its end already (@ERROR_NO_DATA@), is a connection, and the call
-- fails at once with no completion packet; whoever is handed the second
-- reads the end of the stream.
startConnect :: HANDLE -> LPOVERLAPPED -> IO (CbResult Int)
startConnect h ov = do
  ok <- c_ConnectNamedPipe h (castPtr ov)
  if ok /= 0 then pure (CbNone True) else do
    err <- getLastError
    pure $ if
      | err == eRROR_IO_PENDING -> CbPending
      | err == eRROR_PIPE_CONNECTED || err == eRROR_NO_DATA -> CbDone (Just 0)
      | otherwise -> CbError (fromIntegral err)

-- | Stop listening.  Connections already accepted are not affected.  It
-- waits for an accept in progress, so stop the accepting thread first.
pipeListenerClose :: PipeListener -> IO ()
pipeListenerClose pl = mask_ $ modifyMVar_ (plPending pl) $ \pending -> do
  mapM_ pioClose pending
  pure Nothing

-- | On the server side of a pipe: disconnect the client, discarding what
-- it has not read yet, so that its next read or write fails.  The handle
-- must still be closed.
pipeDisconnect :: PipeIO -> IO ()
pipeDisconnect pio = mask_ $ withMVar (pioClosed pio) $ \closed ->
  unless closed $ void (c_DisconnectNamedPipe (pioHandle pio))

eRROR_MORE_DATA :: ErrCode
eRROR_MORE_DATA = 234

fILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: Word8
fILE_SKIP_COMPLETION_PORT_ON_SUCCESS = 1

-- Returns at once.  The flags are a UCHAR.
foreign import ccall unsafe "windows.h SetFileCompletionNotificationModes"
  c_SetFileCompletionNotificationModes :: HANDLE -> Word8 -> IO CInt

#else
-- This build can't use the native manager: nothing here is reached.
nativeIO = False

data PipeIO
data PipeListener

openPipe :: FilePath -> IO PipeIO
openPipe _ = throwIO (ioFailure UnsupportedOperation "open" "this build of hmssql doesn't use GHC's native I/O manager")

pioRecv :: PipeIO -> Ptr Word8 -> Int -> IO Int
pioRecv pio = case pio of {}

pioSendMany :: PipeIO -> [[B.ByteString]] -> IO ()
pioSendMany pio = case pio of {}

pioStopReceiving, pioClose, pipeDisconnect :: PipeIO -> IO ()
pioStopReceiving pio = case pio of {}
pioClose pio = case pio of {}
pipeDisconnect pio = case pio of {}

pipeListenerOpen :: FilePath -> IO PipeListener
pipeListenerOpen _ = throwIO (ioFailure UnsupportedOperation "create" "this build of hmssql doesn't use GHC's native I/O manager")

pipeListenerAccept :: PipeListener -> IO PipeIO
pipeListenerAccept pl = case pl of {}

pipeListenerClose :: PipeListener -> IO ()
pipeListenerClose pl = case pl of {}
#endif
#endif
