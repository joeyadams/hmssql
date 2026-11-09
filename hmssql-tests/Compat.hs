{-# LANGUAGE CPP #-}
-- | What the test suite needs to know about the versions of the libraries
-- it was built with, and about the platform.  (Here rather than in the
-- spec modules, where CPP would get in the way of Haskell's multi-line
-- string gaps.)
module Compat
  ( tlsChecksServerAuthPurpose
  , tlsRefusesShortRsaKeys
  , SignatureScheme
  , ecdsaSha256
  , ecdsaSha1
    -- * The platform
  , onWindows
  , windowsNetworkTcp
  , blockingCallStopsProcess
  , onMacOS
  , exitImmediately
  , detachDescriptor
  , randomBytes
  , processHandleCount
  , openBackendHandles
  , timeoutInSlices
    -- * A connection's socket
  , connSocket
  , connSocketMaybe
  ) where

import qualified Data.ByteString as B
import qualified Network.Socket as Socket
import qualified Network.TLS as TLS
import System.Exit (ExitCode (..))
import System.IO (Handle)

import Hmssql.Connection.Backend (Backend (..), networkTcp)
import Hmssql.Connection.Internal (Connection (..))
import Control.Concurrent (rtsSupportsBoundThreads)

#if defined(mingw32_HOST_OS)
import Control.Concurrent (forkIOWithUnmask, killThread, myThreadId, threadDelay, throwTo)
import Control.Exception
  (Exception (..), asyncExceptionFromException, asyncExceptionToException, bracket, handleJust, uninterruptibleMask_)
import Data.Unique (Unique, newUnique)
import Control.Monad (when)
import qualified Data.ByteString.Internal as BI
import Data.Word (Word32, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import GHC.IO.Handle.Internals (flushWriteBuffer, withHandle')
import GHC.IO.Handle.Types (Handle (..), Handle__ (..), HandleType (ClosedHandle))
import Hmssql.Connection.Backend.Windows (backendHandleCount)
#else
import System.Timeout (timeout)
import Control.Monad (void)
import System.IO (IOMode (..), withBinaryFile)
import System.Posix.IO (handleToFd)
import qualified System.Posix.Process as Posix
#endif

-- | Whether @tls@ refuses a server certificate whose extended key usage
-- extension doesn't include server authentication even when the
-- @onServerCertificate@ hook accepts it (tls 2.4.4, "Enforce server
-- certificate purpose").
tlsChecksServerAuthPurpose :: Bool
#if MIN_VERSION_tls(2,4,4)
tlsChecksServerAuthPurpose = True
#else
tlsChecksServerAuthPurpose = False
#endif

-- | Whether @tls@ refuses a server certificate with an RSA key shorter than
-- 2048 bits, even when the @onServerCertificate@ hook accepts it (tls 2.5,
-- @supportedMinRSAKeySize@).
tlsRefusesShortRsaKeys :: Bool
#if MIN_VERSION_tls(2,5,0)
tlsRefusesShortRsaKeys = True
#else
tlsRefusesShortRsaKeys = False
#endif

-- | A signature scheme as @supportedHashSignatures@ takes it: one IANA
-- number since tls 2.5, a (hash, signature) pair before.
#if MIN_VERSION_tls(2,5,0)
type SignatureScheme = TLS.SignatureScheme
#else
type SignatureScheme = TLS.HashAndSignatureAlgorithm
#endif

-- | @ecdsa_secp256r1_sha256@ and @ecdsa_sha1@.
ecdsaSha256, ecdsaSha1 :: SignatureScheme
#if MIN_VERSION_tls(2,5,0)
ecdsaSha256 = TLS.ECDSA_SECP256R1_SHA256
ecdsaSha1 = TLS.ECDSA_SHA1
#else
ecdsaSha256 = (TLS.HashSHA256, TLS.SignatureECDSA)
ecdsaSha1 = (TLS.HashSHA1, TLS.SignatureECDSA)
#endif

-- | Whether the suite was built for Windows.
onWindows :: Bool
#if defined(mingw32_HOST_OS)
onWindows = True
#else
onWindows = False
#endif

-- | Whether this is Windows with TCP through network's own calls: under
-- GHC's native I/O manager, with a network and a GHC that support it
-- ('Hmssql.Connection.Backend.networkTcp').  There a connect and a send
-- of many pieces block in network's foreign calls, and a reset reads as
-- the end of the stream.
windowsNetworkTcp :: Bool
windowsNetworkTcp = onWindows && networkTcp

-- | Whether a network call that blocks stops every Haskell thread of the
-- process: on Windows with TCP through network's calls in a program linked
-- without @-threaded@, where network's send of many pieces, its connect and
-- its lookup are blocking foreign calls.  Two kinds of test can't run there.
-- One whose mock server, in this process, has to read for a blocked send to
-- end: the process would wait for itself (a real server is another process,
-- and the send ends when it reads).  And one that connects to an address
-- that doesn't answer: the process stops until Windows gives up, 21 s, and
-- every test running beside it misses its deadlines and fails.
blockingCallStopsProcess :: Bool
blockingCallStopsProcess = windowsNetworkTcp && not rtsSupportsBoundThreads

-- | Whether the suite was built for macOS.
onMacOS :: Bool
#if defined(darwin_HOST_OS)
onMacOS = True
#else
onMacOS = False
#endif

-- | 'System.Timeout.timeout', for a helper that is called thousands of
-- times with a long limit it seldom reaches (the model's wait for each
-- operation, the mock's wait for each packet).
--
-- On Windows, with GHC's default I/O manager, 'timeout' forks a thread
-- that sleeps in one 'threadDelay', and the delay stays with the
-- manager's timer thread until its time comes, though the call returned
-- long before.  That thread keeps the pending delays in a lazily sorted
-- list, and pays for the ones left behind when they expire: with about
-- 13,000 of them it fired no timer for a second, and a test whose own
-- 200 ms 'timeout' had to fire within that second failed
-- (@docs/dev/upstream/ghc-windows-timer-delays@).  Without @-threaded@
-- each pending delay is instead a worker thread of the manager, asleep,
-- and the pool of workers grows to the most requests ever pending at once
-- and never shrinks: with the watchdogs of the shared helpers on
-- 'timeout', the suite had 5,847 threads when its parallel items were
-- done, and 2,153 with them here.  Here the forked thread sleeps 50 ms at
-- a time, so a call that returns leaves a delay of at most that behind.
-- Elsewhere 'timeout' registers with the event manager and unregisters, and
-- this is 'timeout'.
--
-- A test's own timeout around a call to hmssql stays 'timeout': there are
-- few of those, and they are what the tests of interruption are about.
timeoutInSlices :: Int -> IO a -> IO (Maybe a)
#if defined(mingw32_HOST_OS)
timeoutInSlices n act
  | n < 0 = Just <$> act
  | n == 0 = pure Nothing
  | otherwise = do
      me <- myThreadId
      ex <- SliceTimeout <$> newUnique
      handleJust (\e -> if e == ex then Just () else Nothing) (\_ -> pure Nothing) $
        bracket (forkIOWithUnmask $ \unmask -> unmask $ sleep n >> throwTo me ex)
                (uninterruptibleMask_ . killThread)
                (\_ -> Just <$> act)
  where
    sleep left
      | left <= 0 = pure ()
      | otherwise = threadDelay (min slice left) >> sleep (left - slice)
    slice = 50000

-- | What 'timeoutInSlices' throws to its caller: asynchronous, as
-- 'System.Timeout.Timeout' is.
newtype SliceTimeout = SliceTimeout Unique
  deriving (Eq)

instance Show SliceTimeout where
  show _ = "<<timeout>>"

instance Exception SliceTimeout where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException
#else
timeoutInSlices = timeout
#endif

-- | End the process at once with the given status, without running exit
-- handlers or unwinding any thread: for a watchdog that has found the
-- process hung where no exception can reach.
exitImmediately :: ExitCode -> IO a
#if defined(mingw32_HOST_OS)
exitImmediately code = do
  c_exit (case code of ExitSuccess -> 0; ExitFailure n -> fromIntegral n)
  -- Not reached.
  ioError (userError "_exit returned")

foreign import ccall unsafe "_exit"
  c_exit :: CInt -> IO ()
#else
exitImmediately code = do
  -- Its result is @()@ in older versions of unix and anything in newer.
  void (Posix.exitImmediately code)
  ioError (userError "exitImmediately returned")
#endif

-- | Close a handle made from a socket without closing the socket's
-- descriptor.  With 'Socket.socketToHandle' before it, this leaves a
-- socket that network has marked closed while its descriptor is still
-- open, which is the state 'Socket.close' leaves when GHC's @closeFdWith@
-- fails under kqueue (see 'Hmssql.Connection.Backend.closeSocket').
--
-- The handle must end up closed, not merely unused: an open handle that
-- becomes garbage is closed by its finalizer, which closes the
-- descriptor's number at some later collection, when the number may be
-- another socket's.  On Windows, which has no @handleToFd@, this does what
-- that does: both sides of the handle are marked closed, and the device is
-- left alone.
detachDescriptor :: Handle -> IO ()
#if defined(mingw32_HOST_OS)
detachDescriptor h = case h of
  FileHandle _ m -> detach m
  -- The finalizer is the write side's, and it closes the device unless
  -- that side is closed.
  DuplexHandle _ r w -> detach r >> detach w
  where
    detach m = withHandle' "detachDescriptor" h m $ \h_ -> do
      flushWriteBuffer h_
      pure (h_ { haType = ClosedHandle }, ())
#else
detachDescriptor = void . handleToFd
#endif

-- | That many random bytes from the operating system: @\/dev\/urandom@, or
-- on Windows, where a native program has no such file, @RtlGenRandom@.
randomBytes :: Int -> IO B.ByteString
#if defined(mingw32_HOST_OS)
randomBytes n = BI.create n $ \p -> do
  ok <- c_RtlGenRandom p (fromIntegral n)
  when (ok == 0) $ ioError (userError "RtlGenRandom failed")

-- RtlGenRandom, by the name advapi32 exports it under.  It returns a
-- BOOLEAN, which is one byte.
foreign import ccall unsafe "SystemFunction036"
  c_RtlGenRandom :: Ptr Word8 -> Word32 -> IO Word8
#else
randomBytes n = withBinaryFile "/dev/urandom" ReadMode (`B.hGet` n)
#endif

-- | On Windows, how many kernel handles the process has open
-- (@GetProcessHandleCount@): sockets and pipes, and also every event,
-- thread and file, the runtime's own included.  'Nothing' elsewhere, where
-- the tests count descriptors instead.
processHandleCount :: IO (Maybe Int)
#if defined(mingw32_HOST_OS)
processHandleCount = alloca $ \p -> do
  process <- c_GetCurrentProcess
  ok <- c_GetProcessHandleCount process p
  if ok == 0 then pure Nothing else Just . fromIntegral <$> (peek p :: IO Word32)

foreign import ccall unsafe "windows.h GetCurrentProcess"
  c_GetCurrentProcess :: IO (Ptr ())

foreign import ccall unsafe "windows.h GetProcessHandleCount"
  c_GetProcessHandleCount :: Ptr () -> Ptr Word32 -> IO CInt
#else
processHandleCount = pure Nothing
#endif

-- | On Windows, how many handles hmssql's backends have open: each socket
-- or pipe it wrapped and has not closed, the mock server's among them.
-- An exact count, where 'processHandleCount' moves with the runtime's
-- threads.  'Nothing' elsewhere.  Where 'windowsNetworkTcp' holds, a TCP
-- connection goes through network's calls and is not counted: only the
-- pipes are, and the tests of TCP have only the coarse process count
-- ('Resources.Helpers.windowsHandleSlack'), which shows only a gross
-- leak.
openBackendHandles :: IO (Maybe Int)
#if defined(mingw32_HOST_OS)
openBackendHandles = Just <$> backendHandleCount
#else
openBackendHandles = pure Nothing
#endif

-- | The socket a connection runs on.  For tests of what is specific to
-- TCP (a socket option, a reset, the descriptor): it fails for a
-- connection over a pipe.
connSocket :: Connection -> Socket.Socket
connSocket conn = case connSocketMaybe conn of
  Just sock -> sock
  Nothing -> error "connSocket: this connection doesn't run on a socket"

-- | The socket a connection runs on, if it runs on one.
connSocketMaybe :: Connection -> Maybe Socket.Socket
connSocketMaybe = backendSocket . connBackend
