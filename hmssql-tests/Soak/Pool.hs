-- | A small TVar-based connection pool, written for the soak test
-- ("Soak.RunSpec"): fixed size, blocking checkout that hands out a
-- 'renew'ed handle, and a checkin that 'release's the connection and, when
-- that says it was broken while checked out (the server killed its
-- session, a severe error closed it, ...), replaces it with a fresh one
-- instead of returning it to the pool. This is deliberately not
-- 'Hmssql', which has no pool of its own; it exists only to give the soak
-- test something realistic to hammer on.
module Soak.Pool
  ( PooledConn (..)
  , Pool
  , newPool
  , closePool
  , withPooledConn
  , replacementCount
  , clearInfoLog
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, try)
import Control.Monad (replicateM)
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import System.Timeout (timeout)

import Hmssql

import Hmssql.Types
-- | A pooled connection plus the INFO messages it has logged since the last
-- 'clearInfoLog'. Only ever touched by the worker that currently holds the
-- connection (the pool never hands the same entry to two threads at once),
-- so a plain 'IORef' is enough.
data PooledConn = PooledConn
  { pcConn :: !Connection
  , pcInfoLog :: !(IORef [Text])
  }

data Pool = Pool
  { poolConnectInfo :: !ConnectInfo
  , poolAvail :: !(TVar [PooledConn])
  , poolReplacements :: !(IORef Int)
  }

mkPooledConn :: ConnectInfo -> IO PooledConn
mkPooledConn ci = do
  logRef <- newIORef []
  conn <- connect ci { connectOnInfoMessage = \m -> modifyIORef' logRef (msgText m :) }
  pure (PooledConn conn logRef)

-- | Create a pool of @size@ connections, eagerly.
newPool :: Int -> ConnectInfo -> IO Pool
newPool size ci = do
  conns <- replicateM size (mkPooledConn ci)
  avail <- newTVarIO conns
  reps <- newIORef 0
  pure (Pool ci avail reps)

-- | Forget any INFO messages logged so far (call right before the statement
-- whose messages you want to inspect).
clearInfoLog :: PooledConn -> IO ()
clearInfoLog pc = writeIORef (pcInfoLog pc) []

-- | Take a connection, with a fresh handle ('renew'), so a handle kept by
-- the previous borrower can't reach it.
checkout :: Pool -> IO PooledConn
checkout p = do
  pc <- atomically $ do
    cs <- readTVar (poolAvail p)
    case cs of
      [] -> retry
      c : rest -> writeTVar (poolAvail p) rest >> pure c
  -- 'renew' refuses a connection the server ended while it sat in the pool.
  try (renew (pcConn pc)) >>= \case
    Right conn -> pure pc { pcConn = conn }
    Left (_ :: SomeException) -> do
      _ <- try (close (pcConn pc)) :: IO (Either SomeException ())
      atomicModifyIORef' (poolReplacements p) (\n -> (n + 1, ()))
      reconnect p (5 :: Int)

-- | Return a connection: 'release' it (as a real pool would before reuse:
-- a statement left running is cancelled, the session reset); if it says
-- 'False', or doesn't answer in time, the connection was broken while it
-- was out (killed server-side, say), so close it and connect a fresh
-- replacement instead of pooling a dead connection.
checkin :: Pool -> PooledConn -> IO ()
checkin p pc = do
  ok <- fromMaybe False <$> timeout 10_000_000 (release (pcConn pc))
  final <-
    if ok
      then pure pc
      else do
        _ <- try (close (pcConn pc)) :: IO (Either SomeException ())
        atomicModifyIORef' (poolReplacements p) (\n -> (n + 1, ()))
        reconnect p (5 :: Int)
  atomically $ modifyTVar' (poolAvail p) (final :)

reconnect :: Pool -> Int -> IO PooledConn
reconnect p 0 = mkPooledConn (poolConnectInfo p)
reconnect p n = try (mkPooledConn (poolConnectInfo p)) >>= \case
  Right pc' -> pure pc'
  Left (_ :: SomeException) -> threadDelay 200_000 >> reconnect p (n - 1)

-- | Check out a connection, run the action, and check it back in (replacing
-- it if it turned out to be broken), even if the action throws.
withPooledConn :: Pool -> (PooledConn -> IO a) -> IO a
withPooledConn p = bracket (checkout p) (checkin p)

-- | How many times a checkin has found a broken connection and replaced it.
replacementCount :: Pool -> IO Int
replacementCount p = readIORef (poolReplacements p)

-- | Close every pooled connection (only safe once nothing is checking
-- connections out any more).
closePool :: Pool -> IO ()
closePool p = do
  cs <- atomically (swapTVar (poolAvail p) [])
  mapM_ (\pc -> try (close (pcConn pc)) :: IO (Either SomeException ())) cs
