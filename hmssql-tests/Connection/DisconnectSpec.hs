{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}

-- | The connection going away under a request, for every encryption mode:
-- the server killing the session (idle, or with a response pending), and
-- 'close' from another thread.  Every failure must be one of hmssql's typed
-- exceptions ('ConnectionClosed', then 'ConnectionBroken'), never a raw
-- 'IOException' or 'TLS.TLSException', and nothing may hang.  The
-- 'EncryptNotSup' variants are pending on a server that requires
-- encryption.
module Connection.DisconnectSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar
import Control.Exception (Exception, IOException, SomeException, fromException, throwIO, try)
import qualified Data.ByteString as B
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import qualified Network.TLS as TLS
import qualified Streaming.Prelude as S
import System.IO.Error (ioeGetErrorString, isUserError)
import System.Mem.Weak (deRefWeak)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Connection.Internal (connReader)
import TestDb
import Mars.Harness (describeMars)
import OpenResponses (isMarsConnection)

modes :: [Encryption]
modes = [EncryptStrict, EncryptOn, EncryptOff, EncryptNotSup]

sessionId :: Connection -> IO SessionIdentity
sessionId = sessionIdentity

kill :: SessionIdentity -> IO ()
kill = killSession

within :: Int -> IO a -> IO a
within secs act = timeout (secs * 1_000_000) act >>= \case
  Nothing -> fail ("hung for " ++ show secs ++ " s")
  Just a -> pure a

-- | 'within' for a streaming test: a timeout says the step the test was at
-- and how many rows it had read, what the server shows for the session
-- ('describeSession'), and on a MARS connection the client's view of it
-- ('describeMars').
withinStreaming :: Int -> Connection -> SessionIdentity -> IORef String -> IORef Int -> IO a -> IO a
withinStreaming secs conn victim step count act = timeout (secs * 1_000_000) act >>= \case
  Just a -> pure a
  Nothing -> do
    at <- readIORef step
    n <- readIORef count
    server <- either (\e -> "not known: " ++ show (e :: SomeException)) id <$> try (describeSession victim)
    client <- if isMarsConnection conn then ("\n  client: " ++) <$> describeMars conn else pure ""
    fail ("hung for " ++ show secs ++ " s at " ++ at ++ ", after " ++ show n ++ " rows\n  server: " ++ server ++ client)

-- | 'withinStreaming' gave up: the connection went silent.
isHang :: SomeException -> Bool
isHang e = case fromException e of
  Just ioe -> isUserError ioe && "hung for " `isPrefixOf` ioeGetErrorString ioe
  Nothing -> False

-- | The rest of the stream's rows, counted into the reference.
countRows :: IORef Int -> S.Stream (S.Of a) IO () -> IO ()
countRows count = S.mapM_ (\_ -> atomicModifyIORef' count (\n -> (n + 1, ())))

describeResult :: Show a => Either SomeException a -> String
describeResult = either (\e -> "exception " ++ show e) (\a -> "success " ++ show a)

-- | The server closed the connection: EOF, or a reset / TLS failure whose
-- cause is the transport's own exception.
isServerClose :: SomeException -> Bool
isServerClose e = case fromException e of
  Just (ConnectionClosedBy ClosedByServer) -> True
  Just (ConnectionClosedBy (TransportFailed cause)) ->
    isJust (fromException cause :: Maybe IOException) || isJust (fromException cause :: Maybe TLS.TLSException)
  _ -> False

-- | A request on a connection the server has closed.  A kill during a
-- request may also be reported as a severe (severity 20+) server error, or
-- as a 'SevereError' (a DONE flagged as failed with no message: Azure SQL
-- Database answers a killed request that way, then resets the connection).
expectServerClose :: Show a => Bool -> Either SomeException a -> Expectation
expectServerClose allowSevere r = case r of
  Left e
    | isServerClose e -> pure ()
    | allowSevere, Just se <- fromException e, msgClass (sqlError se) >= 20 -> pure ()
    | allowSevere, Just SevereError{} <- fromException e -> pure ()
  _ -> expectationFailure ("expected ConnectionClosed, got " ++ describeResult r)

-- | For the idle case: the very next request is the one that notices.
expectBrokenNow :: Connection -> Expectation
expectBrokenNow conn = do
  r <- within 10 $ try (query1 conn "SELECT 1" :: IO (Only Int))
  case r of
    Left e | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, isServerClose cause -> pure ()
    _ -> expectationFailure ("expected ConnectionBroken (ConnectionClosed ...), got " ++ describeResult r)

-- | Later requests: the connection is broken by the earlier close.  If the
-- request that saw the kill got a complete response (a severe error), the
-- close is only noticed by the next request, which throws
-- 'ConnectionClosed' itself.
expectBrokenByClose :: Connection -> Expectation
expectBrokenByClose conn = go True
  where
    go firstTry = do
      r <- within 10 $ try (query1 conn "SELECT 1" :: IO (Only Int))
      case r of
        Left e
          | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, isServerClose cause || isSevere cause -> pure ()
          | firstTry, isServerClose e -> go False
        _ -> expectationFailure ("expected ConnectionBroken (ConnectionClosed ...), got " ++ describeResult r)
    isSevere cause = case fromException cause of
      Just se -> msgClass (sqlError se) >= 20
      Nothing -> False

-- | The request was interrupted by 'close' from another thread.
expectClosedByClient :: Show a => Either SomeException a -> Expectation
expectClosedByClient r = case r of
  Left e | Just (ConnectionClosedBy ClosedByClient) <- fromException e -> pure ()
  _ -> expectationFailure ("expected ConnectionClosedBy ClosedByClient, got " ++ describeResult r)

-- | After 'close': every use throws @ConnectionClosedBy ClosedByClient@, and
-- closing again is harmless.
expectClosed :: Connection -> Expectation
expectClosed conn = do
  within 10 (try (query1 conn "SELECT 1" :: IO (Only Int))) >>= expectClosedByClient
  within 10 (try (execute conn "SELECT 1")) >>= expectClosedByClient
  within 10 (close conn)

-- | Run @request@ on another thread; once @started@ says so, close the
-- connection from this one.  The request must fail with
-- @ConnectionClosedBy ClosedByClient@, and 'close' must return promptly.
closeDuring :: Show a => Connection -> (MVar () -> IO a) -> Expectation
closeDuring = closeDuringWith (within 10)

-- | 'closeDuring', with the wait for the request to start and the wait for
-- it to end given.
closeDuringWith :: Show a => (forall b. IO b -> IO b) -> Connection -> (MVar () -> IO a) -> Expectation
closeDuringWith waitLong conn request = do
  started <- newEmptyMVar
  result <- newEmptyMVar
  _ <- forkIO $ try (request started) >>= putMVar result
  waitLong $ takeMVar started
  within 5 $ close conn
  waitLong (takeMVar result) >>= expectClosedByClient
  expectClosed conn

data ReaderSabotage = ReaderSabotage
  deriving (Show)
instance Exception ReaderSabotage

spec :: Spec
spec = describe "disconnection" $ mapM_ forMode modes

-- | The plaintext variants are pending on a server that requires encryption.
plaintextIfAllowed :: Encryption -> Spec -> Spec
plaintextIfAllowed enc = if enc == EncryptNotSup then skipIfEncryptionRequired else id

forMode :: Encryption -> Spec
forMode enc = plaintextIfAllowed enc $ describe (show enc) $ do
  let withConn act = testConnectInfo enc >>= \ci -> withConnection ci act

  describe "server kills the session" $ do
    it "while idle: the next request throws ConnectionClosed, later ones ConnectionBroken" $ withConn $ \conn -> do
      sessionId conn >>= kill
      threadDelay 500_000
      r <- within 10 $ try (query1 conn "SELECT 1" :: IO (Only Int))
      expectServerClose False r
      expectBrokenNow conn

    it "while a request is waiting for its response" $ withConn $ \conn -> do
      victim <- sessionId conn
      -- The killer connects first, and kills once the server shows the
      -- request waiting: on a loaded server a connect can take longer than
      -- the WAITFOR (Azure SQL, 2026-10-01).  Its every exception comes
      -- back here; left to run on, it would print it, uncaught.
      ci <- defaultTestConnectInfo
      withConnection ci $ \killer -> do
        killed <- newEmptyMVar
        _ <- forkIO $ try @SomeException (awaitWaitfor killer victim >> killSessionFrom killer victim) >>= putMVar killed
        r <- within 20 $ try (query1 conn "WAITFOR DELAY '00:00:05'; SELECT 1" :: IO (Only Int))
        within 10 (takeMVar killed) >>= either throwIO pure
        expectServerClose True r
        expectBrokenByClose conn

    it "while rows are streaming" $ withConn $ \conn -> do
      spid <- sessionId conn
      step <- newIORef "queryS"
      count <- newIORef 0
      -- The 'try' is outside the timeout: inside, it would catch the
      -- timeout's own exception, and the failure would say only
      -- "<<timeout>>".
      --
      -- A streaming KILL left the connection silent on one Mac, including
      -- sqlcmd and a Linux container in Docker Desktop on that same host.
      -- Windows outside Azure and a container in Azure did not reproduce
      -- it. The cause is unknown and there is no public bug report
      -- (protocol-notes.md, "Azure SQL Database"; backlog.md, "Checks to
      -- revisit"). Preserve the 15 s Azure diagnostic bound and pending
      -- result when it expires; an arriving close is still checked.
      azure <- testServerIsAzure
      r <- try @SomeException $ withinStreaming (if azure then 15 else 30) conn spid step count $ do
        rows <- queryS conn
          "SELECT a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b"
        writeIORef step "the first row"
        S.next rows >>= \case
          Left () -> fail "no rows"
          Right (_ :: Only Int32, rest) -> do
            writeIORef step "the KILL"
            kill spid
            writeIORef step "the rows after the KILL"
            countRows count rest
      case r of
        Left e | azure, isHang e ->
          pendingWith "No connection end observed after KILL; previously seen only on one macOS system, cause unknown (no public bug report); see backlog.md, Checks to revisit"
        _ -> do
          expectServerClose True r
          expectBrokenByClose conn

  describe "close from another thread" $ do
    it "while a request is waiting for its response" $ withConn $ \conn ->
      closeDuring conn $ \started -> do
        _ <- forkIO $ threadDelay 300_000 >> putMVar started ()
        query1 conn "WAITFOR DELAY '00:00:05'; SELECT 1" :: IO (Only Int)

    it "while rows are streaming" $ withConn $ \conn -> do
      spid <- sessionId conn
      step <- newIORef "queryS"
      count <- newIORef 0
      closeDuringWith (withinStreaming 10 conn spid step count) conn $ \started -> do
        rows <- queryS conn
          "SELECT a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b"
        writeIORef step "the first row"
        S.next rows >>= \case
          Left () -> fail "no rows"
          Right (_ :: Only Int32, rest) -> do
            writeIORef step "the rows after the first (close follows)"
            putMVar started ()
            countRows count rest

    it "while a large parameter is being sent" $ withConn $ \conn ->
      -- 64 MB takes a quarter of a second or more to send on localhost, so
      -- the close lands in the middle of it; the send must stop at once.
      closeDuring conn $ \started -> do
        let big = B.replicate (64 * 1024 * 1024) 0x61
        _ <- forkIO $ threadDelay 50_000 >> putMVar started ()
        query1 conn ("SELECT DATALENGTH(" <> param big <> ")") :: IO (Only Int)

    it "while idle" $ withConn $ \conn -> do
      within 5 $ close conn
      expectClosed conn

  it "a reader thread that dies unexpectedly breaks the connection instead of hanging" $ withConn $ \conn -> do
    Just weakTid <- readIORef (connReader conn)
    Just tid <- deRefWeak weakTid
    throwTo tid ReaderSabotage
    r <- within 10 $ try (query1 conn "SELECT 1" :: IO (Only Int))
    case r of
      Left e | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, Just ReaderSabotage <- fromException cause -> pure ()
      _ -> expectationFailure ("expected ConnectionBroken ReaderSabotage, got " ++ describeResult r)
    r2 <- within 10 $ try (query1 conn "SELECT 1" :: IO (Only Int))
    case r2 of
      Left e | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, Just ReaderSabotage <- fromException cause -> pure ()
      _ -> expectationFailure ("expected ConnectionBroken ReaderSabotage again, got " ++ describeResult r2)
