{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Shared helpers for the concurrency and cancellation tests
-- (@hmssql-tests/Concurrency/*Spec.hs@): deadlock guards, interrupting an action at a
-- chosen moment, and a sentinel query that detects a desynchronised
-- connection (a request reading an earlier request's leftover response).
module Concurrency.Harness
  ( -- * Guards
    within
  , elapsed
    -- * Interrupting
  , Interrupt (..)
  , Method (..)
  , Delay (..)
  , genMethod
  , genDelay
  , waitDelay
  , interruptWith
  , isAsync
  , isTimeout
  , isInterrupt
  , interruptedBy
    -- * Known bugs
  , knownBug
    -- * Checking a connection afterwards
  , Health (..)
  , nextId
  , checkHealth
  , checkHealthBeside
  , settleInterruptedStream
  , expectUsable
  , expectUsableBeside
  , expectUsableOrBrokenBy
  , expectBrokenBy
  , ConnHolder
  , newConnHolder
  , withHeldConnection
  , holderReconnects
  , closeHolder
    -- * Sessions
  , uniqueAppName
  , sessionCount
  , waitForSessionCount
  ) where

import UnusableCause (reasonCause)
import Control.Concurrent
import Control.Exception
import Control.Monad (replicateM_, unless, when)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import GHC.Conc (threadStatus)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Hedgehog (Gen)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (Timeout, timeout)
import Compat (timeoutInSlices)
import Test.Hspec (pendingWith)

import Hmssql
import Hmssql.Transaction
import Hmssql.Errors
import Hmssql.Connection (cancelActiveStatement)
import OpenResponses (connectionBroken, isMarsConnection, openStatements)
import TestDb

------------------------------------------------------------------------------
-- Guards

-- | Fail instead of hanging.
within :: Int -> IO a -> IO a
within seconds act = timeoutInSlices (seconds * 1_000_000) act >>= \case
  Just a -> pure a
  Nothing -> throwIO (userError ("timed out after " ++ show seconds ++ " s (deadlock or hang?)"))

-- | Seconds the action took, by the monotonic clock (the wall clock
-- advances in ticks of up to 16 ms on Windows).
elapsed :: IO a -> IO (a, Double)
elapsed act = do
  t0 <- getMonotonicTime
  a <- act
  t1 <- getMonotonicTime
  pure (a, t1 - t0)

------------------------------------------------------------------------------
-- Interrupting

-- | An asynchronous exception of our own, for 'throwTo'.
data Interrupt = Interrupt
  deriving stock (Show)

instance Exception Interrupt where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | How the action is interrupted.
data Method
  = ViaTimeout
    -- ^ 'System.Timeout.timeout' in the thread running the action.
  | ViaKillThread
    -- ^ The action runs in its own thread, which is killed.
  | ViaThrowTo
    -- ^ The action runs in its own thread, which is sent 'Interrupt'.
  deriving stock (Eq, Show, Enum, Bounded)

-- | When the action is interrupted.
data Delay
  = Yields !Int
    -- ^ After this many 'yield's: almost immediately, e.g. mid-send.
  | Micros !Int
  deriving stock (Eq, Show)

genMethod :: Gen Method
genMethod = Gen.enumBounded

-- | Biased towards small delays, where the interesting states are (sending,
-- the first packets of the response), up to @maxMicros@.
genDelay :: Int -> Gen Delay
genDelay maxMicros = Gen.frequency
  [ (2, Yields <$> Gen.int (Range.linear 0 40))
  , (5, Micros <$> Gen.int (Range.exponential 1 3000))
  , (2, Micros <$> Gen.int (Range.exponential 3000 (max 3000 maxMicros)))
  ]

waitDelay :: Delay -> IO ()
waitDelay = \case
  Yields n -> replicateM_ n yield
  Micros n -> threadDelay n

-- | Run the action and interrupt it after the delay.  'Right' if it finished
-- first, else the exception it ended with.  Always waits for the action to
-- end (within 60 s).
interruptWith :: Method -> Delay -> IO a -> IO (Either SomeException a)
interruptWith method delay act = case method of
  ViaTimeout -> do
    let micros = case delay of
          Micros n -> max 1 n
          Yields n -> 1 + n
    r <- within 60 (try (timeout micros act))
    pure $ case r of
      Left e -> Left e
      Right Nothing -> Left (toException (userError "<<timeout>>"))
      Right (Just a) -> Right a
  ViaKillThread -> forked killThread
  ViaThrowTo -> forked (`throwTo` Interrupt)
  where
    forked stop = do
      result <- newEmptyMVar
      tid <- mask_ $ forkIOWithUnmask $ \unmask -> try (unmask act) >>= putMVar result
      waitDelay delay
      _ <- stop tid
      -- A thread that doesn't end says what it is blocked on.
      timeout 60_000_000 (takeMVar result) >>= \case
        Just r -> pure r
        Nothing -> do
          status <- threadStatus tid
          throwIO (userError ("timed out after 60 s: the interrupted thread has not ended (" ++ show status ++ ")"))

-- | An asynchronous exception ('ThreadKilled', 'System.Timeout.Timeout',
-- 'Interrupt', ...).
isAsync :: SomeException -> Bool
isAsync e = isJust (fromException @SomeAsyncException e)

-- | 'System.Timeout.timeout''s exception (shown as @<<timeout>>@).
isTimeout :: SomeException -> Bool
isTimeout e = isJust (fromException @Timeout e)

-- | 'Interrupt'.
isInterrupt :: SomeException -> Bool
isInterrupt e = case fromException e of
  Just Interrupt -> True
  Nothing -> False

-- | The exception the method interrupts with: the cause that a connection
-- broken by it must carry ('ConnectionBroken').
interruptedBy :: Method -> SomeException -> Bool
interruptedBy method e = case method of
  ViaTimeout -> isTimeout e
  ViaKillThread -> fromException e == Just ThreadKilled
  ViaThrowTo -> isInterrupt e

------------------------------------------------------------------------------
-- Known bugs

-- | A test that fails because of a known hmssql bug: reported pending with
-- @BUG: <reason>@, unless @HMSSQL_TEST_KNOWN_BUGS=1@, which runs it (to check
-- a fix).  Remove the wrapper once the bug is fixed.
knownBug :: String -> IO () -> IO ()
knownBug reason act = lookupEnv "HMSSQL_TEST_KNOWN_BUGS" >>= \case
  Just "1" -> act
  _ -> pendingWith ("BUG: " ++ reason ++ " (HMSSQL_TEST_KNOWN_BUGS=1 runs it)")

------------------------------------------------------------------------------
-- Health checks

-- | What a connection is like after an interruption.
data Health
  = Usable
  | Broken SomeException
    -- ^ Refuses requests with 'ConnectionBroken' (the cause is inside).
  deriving stock (Show)

counter :: IORef Int64
counter = unsafePerformIO (newIORef 1_000_000)
{-# NOINLINE counter #-}

-- | A fresh value, never returned by any other query of this process.
nextId :: IO Int64
nextId = atomicModifyIORef' counter (\i -> (i + 1, i))

-- | Check the connection answers requests with their own results.  Runs two
-- sentinel queries (an RPC and a plain batch) that return unique values;
-- getting anything else means the connection is desynchronised.  Also checks
-- no response is left pending and no transaction is open.  Pending means on
-- any session: under MARS a response left open beside the sentinels still
-- holds its session (and its statement's locks), so a test that leaves a
-- stream open on purpose says so ('checkHealthBeside') or reads or cancels
-- it first.
--
-- Throws (failing the test) on a desync, a hang, a transaction left open, or
-- any exception other than 'ConnectionBroken'.  A broken connection must stay
-- broken: a second request must be refused too.
checkHealth :: Connection -> IO Health
checkHealth = checkHealthBeside []

-- | 'checkHealth' on a MARS connection with streams the test left open on
-- purpose: after the sentinels, exactly these statements are still open
-- (the SQL text of each, in the order of their sessions).
checkHealthBeside :: [Text] -> Connection -> IO Health
checkHealthBeside besides conn = do
  a <- nextId
  r <- try (within 30 (query conn ("SELECT " <> param a <> ", @@TRANCOUNT")))
  case r of
    Left e
      | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e -> do
          r2 <- try (within 30 (query1 conn "SELECT 1" :: IO (Only Int)))
          case r2 of
            Left (ConnectionBroken _) -> pure (Broken cause)
            Right v -> throwIO (userError ("a broken connection answered a later request: " ++ show v))
      | otherwise -> throwIO (userError ("sentinel query threw " ++ displayException e ++ " (" ++ show e ++ ")"))
    Right rows -> do
      unless (rows == [(a, 0 :: Int)]) $
        throwIO (userError ("DESYNC or open transaction: sentinel SELECT " ++ show a
          ++ ", @@TRANCOUNT returned " ++ show rows))
      b <- nextId
      rows2 <- within 30 (query conn (rawSql ("SELECT CAST(" <> tshow b <> " AS bigint)")))
      unless (rows2 == [Only b]) $
        throwIO (userError ("DESYNC: sentinel batch SELECT " ++ show b ++ " returned " ++ show rows2))
      open <- openStatements conn
      unless (open == besides) $
        throwIO (userError ("a response is still pending after a completed query: " ++ show open
          ++ (if null besides then "" else " (expected " ++ show besides ++ ")")))
      inTransaction conn >>= \t -> when t $ throwIO (userError "the connection thinks a transaction is open")
      pure Usable
  where
    tshow = T.pack . show

-- | After the consumer of a stream (whose statement is given) was
-- interrupted, on a MARS connection: the next request would leave the
-- stream alone.  It may be cancelled (the interruption landed in a read
-- and sent the Attention), read to its end, or still open (the
-- interruption landed outside a read, or in one of a response that had
-- fully arrived: nothing was cancelled, and it could be read on); nothing
-- else may be open.  It is settled with 'cancelActiveStatement', as an
-- application would.  Without MARS, or on a broken connection, nothing is
-- done.
settleInterruptedStream :: Connection -> Text -> IO ()
settleInterruptedStream conn stmt = do
  broken <- connectionBroken conn
  when (isMarsConnection conn && not broken) $ do
    open <- openStatements conn
    unless (open `elem` [[], [stmt]]) $
      throwIO (userError ("open after the stream's consumer was interrupted: " ++ show open))
    cancelActiveStatement conn

-- | 'checkHealth', requiring 'Usable'.
expectUsable :: Connection -> IO ()
expectUsable = expectUsableBeside []

-- | 'checkHealthBeside', requiring 'Usable'.
expectUsableBeside :: [Text] -> Connection -> IO ()
expectUsableBeside besides conn = checkHealthBeside besides conn >>= \case
  Usable -> pure ()
  Broken cause -> throwIO (userError ("connection broken: " ++ show cause))

-- | 'checkHealth', allowing a broken connection only if the cause inside
-- 'ConnectionBroken' satisfies the predicate (e.g. is the exception that
-- interrupted a send): usable and in step, or broken by that; never out of
-- step, hung, or broken by anything else.
expectUsableOrBrokenBy :: (SomeException -> Bool) -> Connection -> IO Health
expectUsableOrBrokenBy ok conn = checkHealth conn >>= \case
  Usable -> pure Usable
  Broken cause
    | ok cause -> pure (Broken cause)
    | otherwise -> throwIO (userError ("connection broken by something else: " ++ show cause))

-- | 'checkHealth', requiring 'Broken' with a cause that satisfies the
-- predicate.  Returns the cause.
expectBrokenBy :: (SomeException -> Bool) -> Connection -> IO SomeException
expectBrokenBy ok conn = checkHealth conn >>= \case
  Usable -> throwIO (userError "the connection is still usable (expected ConnectionBroken)")
  Broken cause
    | ok cause -> pure cause
    | otherwise -> throwIO (userError ("connection broken by something else: " ++ show cause))

------------------------------------------------------------------------------
-- A connection reused across property iterations, replaced when broken.

data ConnHolder = ConnHolder
  { chInfo :: !ConnectInfo
  , chSetup :: !(Connection -> IO ())
  , chConn :: !(IORef (Maybe Connection))
  , chReconnects :: !(IORef Int)
  }

newConnHolder :: ConnectInfo -> (Connection -> IO ()) -> IO ConnHolder
newConnHolder ci setup = ConnHolder ci setup <$> newIORef Nothing <*> newIORef 0

withHeldConnection :: ConnHolder -> (Connection -> IO a) -> IO a
withHeldConnection h act = do
  conn <- readIORef (chConn h) >>= \case
    Just c -> pure c
    Nothing -> do
      c <- connect (chInfo h)
      chSetup h c
      writeIORef (chConn h) (Just c)
      pure c
  act conn

-- | Close and forget the current connection (e.g. because it broke).
closeHolder :: ConnHolder -> IO ()
closeHolder h = readIORef (chConn h) >>= \case
  Nothing -> pure ()
  Just c -> do
    writeIORef (chConn h) Nothing
    modifyIORef' (chReconnects h) (+ 1)
    within 30 (close c)

holderReconnects :: ConnHolder -> IO Int
holderReconnects = readIORef . chReconnects

------------------------------------------------------------------------------
-- Server sessions

-- | An application name unique to this test, to find its sessions by.
uniqueAppName :: Text -> IO Text
uniqueAppName = uniqueName

-- | Sessions whose program_name is the given application name.
sessionCount :: Text -> IO Int
sessionCount app = withTestDb $ \c ->
  fromOnly <$> query1 c ("SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = " <> param app)

-- | Poll (for up to @seconds@) until the count is as expected, running the
-- given action (e.g. a GC) between polls.  Returns the last count seen.
waitForSessionCount :: Int -> IO () -> Text -> Int -> IO Int
waitForSessionCount seconds between app expected = go (seconds * 10)
  where
    go n = do
      c <- sessionCount app
      if c == expected || n <= 0
        then pure c
        else between >> threadDelay 100_000 >> go (n - 1 :: Int)
