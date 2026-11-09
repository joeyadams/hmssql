-- | Connection lifecycle edge cases: closing, using a killed/broken
-- connection, host/port edge cases, TLS certificate validation, and opening
-- many connections without leaking server-side sessions.
module Connection.LifecycleSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (replicateConcurrently_)
import Control.Concurrent.MVar
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Control.Exception (SomeException, bracket_, fromException, throwIO, try)
import Control.Monad (forM_, replicateM_)
import Data.Int (Int64)
import qualified Network.TLS as TLS
import System.Timeout (timeout)
import Test.Hspec

import Compat (windowsNetworkTcp)
import Hmssql
import Hmssql.Errors
import TestDb

-- | Run @action@ on a second connection to kill @victim@'s session, given
-- @victim@'s own connection.
killFrom :: Connection -> IO ()
killFrom victim = sessionIdentity victim >>= killSession

spec :: Spec
spec = describe "connection lifecycle" $ do
  describe "default login server name" $
    forM_ [EncryptOn, EncryptStrict] $ \enc ->
      it ("connects to the requested database without a server-name override with " ++ show enc) $ do
        ci <- testConnectInfo enc
        withConnection ci { connectServerName = "" } $ \conn ->
          query1 conn "SELECT DB_NAME()" `shouldReturn` Only (connectDatabase ci)

  describe "close" $ do
    it "is a no-op the second time" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      close conn
      r <- try (close conn) :: IO (Either SomeException ())
      case r of
        Right () -> pure ()
        Left e -> expectationFailure ("closing twice threw: " ++ show e)

    it "using the connection after close throws synchronously (no hang)" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      close conn
      r <- timeout 5_000_000 (try (query1 conn "SELECT 1" :: IO (Only Int)) :: IO (Either SomeException (Only Int)))
      case r of
        Nothing -> expectationFailure "hung instead of throwing"
        Just (Right v) -> expectationFailure ("succeeded with " ++ show v)
        Just (Left _) -> pure () -- some exception; which one is incidental (see docs/dev/limitations.md)

    it "closing from another thread cancels a concurrent, in-flight query without hanging" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- try (query1 conn "WAITFOR DELAY '00:00:05'; SELECT 1" :: IO (Only Int))
        putMVar done (r :: Either SomeException (Only Int))
      threadDelay 300_000
      close conn
      r <- timeout 10_000_000 (takeMVar done)
      case r of
        Nothing -> expectationFailure "the in-flight query hung after close"
        Just (Right v) -> expectationFailure ("query succeeded after close, got " ++ show v)
        Just (Left e)
          | Just ConnectionClosed <- fromException e -> pure ()
          | Just (ConnectionBroken _) <- fromException e -> pure ()
          | otherwise -> expectationFailure ("unexpected exception: " ++ show e)

  describe "server-initiated disconnection" $ do
    it "KILLed while idle: the next request fails cleanly" $ do
      ci <- defaultTestConnectInfo
      r <- withConnection ci $ \victim -> do
        killFrom victim
        threadDelay 500_000
        try (query1 victim "SELECT 1" :: IO (Only Int))
      case r :: Either SomeException (Only Int) of
        Left e
          | Just ConnectionClosed <- fromException e -> pure ()
          | Just (ConnectionBroken _) <- fromException e -> pure ()
          | otherwise -> expectationFailure ("unexpected exception: " ++ show e)
        Right v -> expectationFailure ("succeeded with " ++ show v)

    it "KILLed mid-stream: the pending request fails cleanly" $ do
      ci <- defaultTestConnectInfo
      r <- withConnection ci $ \victim -> do
        killFrom victim
        try (query1 victim "WAITFOR DELAY '00:00:02'; SELECT 1" :: IO (Only Int))
      case r :: Either SomeException (Only Int) of
        Left e
          | Just ConnectionClosed <- fromException e -> pure ()
          | Just (ConnectionBroken _) <- fromException e -> pure ()
          | otherwise -> expectationFailure ("unexpected exception: " ++ show e)
        Right v -> expectationFailure ("succeeded with " ++ show v)

    skipOnAzure "RAISERROR ... WITH LOG needs sysadmin (error 2778)" $
      it "a severity-20+ error kills the connection cleanly (subsequent use throws ConnectionClosed)" $ do
      ci <- defaultTestConnectInfo
      withConnection ci $ \conn -> do
        r1 <- try (execute conn "RAISERROR('fatal', 20, 1) WITH LOG") :: IO (Either SomeException Int64)
        case r1 of
          Left e -> case fromException e :: Maybe SqlServerError of
            Just se -> sqlErrorNumber se `shouldBe` 50000
            Nothing -> case fromException e of
              Just ConnectionClosed -> pure () -- also acceptable: server may not flush the ERROR token first
              Nothing -> expectationFailure ("unexpected exception: " ++ show e)
          Right n -> expectationFailure ("RAISERROR severity 20 succeeded, rows=" ++ show n)
        r2 <- try (query1 conn "SELECT 1" :: IO (Only Int)) :: IO (Either SomeException (Only Int))
        case r2 of
          Left e | Just ConnectionClosed <- fromException e -> pure ()
                 | Just (ConnectionBroken _) <- fromException e -> pure ()
                 | otherwise -> expectationFailure ("unexpected exception: " ++ show e)
          Right v -> expectationFailure ("connection still usable, got " ++ show v)

  describe "host and port" $ do
    -- The three spellings of the loopback address resolve to the server on
    -- this machine.
    skipUnlessLoopbackHost $ mapM_
      (\host -> it ("connects to host " ++ show host) $ do
        ci <- defaultTestConnectInfo
        withConnection ci { connectHost = host } $ \conn -> query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int))
      ["localhost", "127.0.0.1", "::1"]

    it "a wrong port is refused promptly with a clean exception" $ do
      -- Over TCP whatever the suite's protocol is: a pipe has no port, so
      -- a run that forces Shared Memory or Named Pipes would connect.
      -- (Left to 'ProtocolAuto', a port other than the default means TCP
      -- as well, so that a wrong port can't reach the default instance
      -- over a pipe.)
      ci <- defaultTestConnectInfo
      r <- timeout 5_000_000 (try (withConnection ci { connectPort = "14330", connectProtocol = ProtocolTcp } (\_ -> pure ())) :: IO (Either SomeException ()))
      case r of
        Nothing -> expectationFailure "wrong-port connect did not fail within 5s"
        Just (Right ()) -> expectationFailure "connected on the wrong port"
        Just (Left _) -> pure ()

    it "an unroutable host has no built-in connect timeout, but an external `timeout` cancels it cleanly" $ do
     if windowsNetworkTcp
      then pendingWith "on Windows with TCP through network's calls a timeout can't end a connect (network's connect is a blocking call); Connection.ConnectFailure states the consequence"
      else do
      -- See docs/dev/limitations.md: hmssql has no connectTimeout option, so
      -- an unreachable/black-holed address blocks until the OS's own TCP
      -- connect timeout (which can be a minute or more). This only checks
      -- that wrapping the connect in System.Timeout.timeout works: the
      -- async exception interrupts cleanly and the partial socket is closed
      -- (connect's own `onException` handler), rather than hanging or
      -- leaking.
      -- Deliberately no 'try' around the connect: System.Timeout.timeout
      -- cancels by throwing its own exception into this action, and a
      -- broad 'try SomeException' in here would swallow that instead of
      -- letting 'timeout' observe it and return Nothing.
      -- Over TCP whatever the suite's protocol is: Shared Memory ignores
      -- the host, and would connect to the server on this machine.
      ci <- defaultTestConnectInfo
      r <- timeout 3_000_000 (withConnection ci { connectHost = "10.255.255.1", connectProtocol = ProtocolTcp } (\_ -> pure ()))
      case r of
        Nothing -> pure () -- the outer `timeout` fired first, as expected
        Just () -> expectationFailure "connected to an unroutable host within 3s"

  describe "TLS certificate validation" $
    it "rejects a certificate whose name doesn't match the configured hostname" $ do
      -- Under HMSSQL_TEST_ENCRYPTION=notsup there is no certificate to
      -- check, so it uses EncryptOn, which every server has.
      enc <- testEncryption
      ci <- testConnectInfo (if enc == EncryptNotSup then EncryptOn else enc)
      r <- try (withConnection ci { connectTls = (connectTls ci)
        { tlsTrustServerCertificate = False, tlsHostNameInCertificate = Just "not-the-right-host" } } (\_ -> pure ()))
      case r :: Either TLS.TLSException () of
        Left _ -> pure ()
        Right () -> expectationFailure "connected despite the hostname mismatch"

  describe "many connections" $
    it "opening and closing sequential and parallel connections leaves no sessions behind" $ do
      progName <- uniqueName "hmssql_test_lifecycle_many"
      ci <- defaultTestConnectInfo
      let ci' = ci { connectApplicationName = progName }
      sequential <- fastOrSlow 50 200
      -- The connections begun and not yet closed, for the message below.
      open <- newIORef (0 :: Int)
      let count d = atomicModifyIORef' open (\n -> (n + d, ()))
          once = bracket_ (count 1) (count (-1)) (withConnection ci' (\_ -> pure ()))
          -- sessions are torn down asynchronously server-side; poll briefly
          countSessions = withConnection ci $ \conn ->
            fromOnly <$> query1 conn ("SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = " <> param progName)
          waitForZero (n :: Int) = do
            c <- countSessions
            if c == (0 :: Int) then pure () else if n <= 0 then pure () else threadDelay 200_000 >> waitForZero (n - 1)
          body = do
            replicateM_ sequential once
            replicateConcurrently_ 50 once
            waitForZero (25 :: Int)
            countSessions `shouldReturn` 0
      -- The body runs in a thread of its own, waited for with a bound, and
      -- isn't waited for past it.  This test opens more sockets than any
      -- other, so it is the one most likely to be given a descriptor whose
      -- bucket in GHC's IO manager is wedged (before GHC 9.14, by a socket
      -- that some other code closed under a thread starting to wait on it;
      -- docs/dev/bugs-found.md, "In the test suite").  A wait on such a
      -- descriptor never returns, and neither does a 'timeout' that would
      -- wait for the cleanup, which closes the socket through the same
      -- bucket: the run hung for hours in the test matrix.
      result <- newEmptyMVar
      _ <- forkIO $ try body >>= putMVar result
      timeout manyConnectionsLimit (takeMVar result) >>= \case
        Just r -> either (\(e :: SomeException) -> throwIO e) pure r
        Nothing -> do
          stuck <- readIORef open
          expectationFailure $ "not done after " ++ show (manyConnectionsLimit `div` 1_000_000) ++ " s, with "
            ++ show stuck ++ " connections still opening or closing (a wedged bucket of GHC's IO manager, before 9.14, "
            ++ "looks like this: docs/dev/bugs-found.md, \"In the test suite\")"

-- | How long the many-connections test may take: under a second each for
-- its 50 (slow: 200) sequential connections, and all the rest at once.
manyConnectionsLimit :: Int
manyConnectionsLimit = 300_000_000
