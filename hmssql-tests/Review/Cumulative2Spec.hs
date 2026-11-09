{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE MultiWayIf #-}

-- | Regression tests from a second review of how the fixes combine (those
-- since 80eaab1: close dropping the transport, the weak reader 'ThreadId',
-- the process-wide certificate store, typed connect and handshake
-- failures).
module Review.Cumulative2Spec (spec) where

import UnusableCause (brokenCause)
import Control.Concurrent
import Control.Exception
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Maybe (isJust)
import GHC.Conc (ThreadStatus (..), BlockReason (..), threadStatus)
import qualified Network.Socket as Socket
import qualified Network.TLS as TLS
import Test.Hspec

import Concurrency.Harness (within)
import Hmssql
import Hmssql.Connection.Backend (socketBackend)
import Hmssql.Connection.Internal (Connection (..), Transport (..), newConnection, sendBytes)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Security.TlsSpec (mockKey, serverAuthCert)

-- | Thrown to a sending thread, as 'killThread' or a timeout would.
data Stop = Stop
  deriving stock (Show)

instance Exception Stop where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | What the test lets a send do, by how many bytes had gone out before it.
data Gate = Gate
  { gateBlockAt :: !Int
    -- ^ The first send starting at or after this many bytes waits for
    -- 'gateRelease' (as a send to a peer that doesn't read would).
  , gateFailAt :: !Int
    -- ^ Sends starting at or after this many bytes fail (as a send to a
    -- peer that has reset the connection would).
  , gateBlocked :: !(MVar ())
  , gateRelease :: !(MVar ())
  }

-- | A 'Connection' whose transport is a TLS session (with an in-process
-- server, over a socket pair) whose sends after the handshake go through
-- the gate instead of the socket.
withGatedTlsConnection :: Gate -> (Connection -> IO a) -> IO a
withGatedTlsConnection gate act =
  bracket (Socket.socketPair Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) closeBoth $ \(a, b) -> do
    creds <- either (throwIO . userError) pure (TLS.credentialLoadX509FromMemory serverAuthCert mockKey)
    serverCtx <- TLS.contextNew b TLS.defaultParamsServer
      { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] } }
    serverDone <- newEmptyMVar
    _ <- forkIO $ (TLS.handshake serverCtx >> putMVar serverDone ()) `catch` \(_ :: SomeException) -> pure ()
    gated <- newIORef False
    sent <- newIORef 0
    blockedOnce <- newIORef False
    let real = TLS.getBackend a
        send bs = readIORef gated >>= \case
          False -> TLS.backendSend real bs
          True -> do
            before <- readIORef sent
            modifyIORef' sent (+ B.length bs)
            if
              | before >= gateFailAt gate -> throwIO (userError "send: connection reset by peer")
              | before >= gateBlockAt gate -> do
                  already <- readIORef blockedOnce
                  unless already $ do
                    writeIORef blockedOnce True
                    putMVar (gateBlocked gate) ()
                    takeMVar (gateRelease gate)
              | otherwise -> pure ()
        backend = real { TLS.backendSend = send }
    clientCtx <- TLS.contextNew backend (TLS.defaultParamsClient "hmssql-mock" B.empty)
      { TLS.clientHooks = TLS.defaultClientHooks { TLS.onServerCertificate = \_ _ _ _ -> pure [] } }
    TLS.handshake clientCtx
    takeMVar serverDone
    writeIORef gated True
    backend <- socketBackend a
    conn <- newConnection backend defaultTdsContext (\_ -> pure ())
    writeIORef (connTransport conn) (TransportTls clientCtx)
    act conn
  where
    closeBoth (a, b) = Socket.close a >> Socket.close b

spec :: Spec
spec = describe "Review 2" $ do
  describe "a send interrupted while it blocks" $
    it "rethrows the interrupting exception, and breaks the connection with it as the cause" $ do
      gate <- Gate 4096 8192 <$> newEmptyMVar <*> newEmptyMVar
      r <- within 30 $ withGatedTlsConnection gate $ \conn -> do
        -- Three 4096-byte packets: the first goes out, the second waits,
        -- and everything after it fails.
        let packets = splitIntoPackets defaultTdsContext PTSqlBatch (PacketStatus 0) (LB.replicate 12000 0x41)
        result <- newEmptyMVar
        sender <- forkIO $ try (sendBytes conn packets) >>= putMVar result
        takeMVar (gateBlocked gate)
        -- Interrupt the sender while its second packet is going out (the
        -- send blocks, so it can be interrupted although it runs masked).
        thrower <- forkIO $ throwTo sender Stop
        let waitPending = threadStatus thrower >>= \case
              ThreadBlocked BlockedOnException -> pure ()
              ThreadFinished -> pure ()
              _ -> yield >> threadDelay 1000 >> waitPending
        waitPending
        putMVar (gateRelease gate) ()
        (,) <$> takeMVar result <*> brokenCause conn
      -- The server holds part of a message: the connection can't be used,
      -- and says why.
      snd r `shouldSatisfy` isJust
      (snd r >>= fmap (show @Stop) . fromException) `shouldBe` Just "Stop"
      case fst r of
        Left e -> case fromException e of
          Just Stop -> pure ()
          Nothing -> expectationFailure ("the sender got " ++ show e ++ ", not the exception thrown to it")
        Right () -> expectationFailure "the send wasn't interrupted"
