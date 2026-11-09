{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}

-- | A reentrant mutex, so the thread that owns a connection's active response
-- can issue another request (which cancels the first) without deadlocking.
--
-- The owner is recorded by its thread /number/, not its 'ThreadId'.  Holding
-- a 'ThreadId' would keep the owner's thread object reachable from the
-- connection, so an owner that blocks forever (on an 'MVar' nobody else can
-- fill, say) could never be found unreachable by the garbage collector: it
-- would not receive 'Control.Exception.BlockedIndefinitelyOnMVar', never
-- release the mutex, and every other user of the connection would hang with
-- it.  hpgsql uses a weak 'ThreadId' for the same reason; a number also works
-- after the collector has declared the thread dead but resurrected it to run
-- its exception handlers, which may re-enter the mutex (a rollback, say).
--
-- Adapted from @Hpgsql.Locking@ in hpgsql
-- (<https://github.com/mzabani/hpgsql>), Copyright Marcelo Zabani (c) 2026,
-- BSD-3-Clause.
module Hmssql.Connection.Locking
  ( Mutex
  , newMutex
  , withMutex
  , mutexOwner
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
import Control.Exception (bracket_)
import Data.Functor ((<&>))
import Data.Word (Word64)

#if MIN_VERSION_base(4,19,0)
import GHC.Conc.Sync (fromThreadId)
#else
import Foreign.C.Types (CULLong (..))
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (ThreadId#)
#endif

newtype Mutex = Mutex (TVar Owner)

-- | Strict, so that no thunk referring to the owner's 'ThreadId' is stored.
data Owner
  = Unowned
  | Owner !Word64
    -- ^ The owner's thread number.  Nested entries don't count themselves:
    -- only the outermost one takes and releases the mutex.

newMutex :: IO Mutex
newMutex = Mutex <$> newTVarIO Unowned

-- | Run the action holding the mutex, waiting for any other owner to leave.
-- Waiting is interruptible; the mutex is released however the action ends.
--
-- Reentry takes a fast path: when this thread holds the mutex already, the
-- action just runs.  Nothing needs undoing afterwards, since the entry that
-- took the mutex releases it, and nothing can change the owner under us:
-- only the owner writes the variable while it is owned.  This saves two
-- STM transactions and an exception frame on every nested use (every token
-- read inside 'Hmssql.Query.query', say).
withMutex :: Mutex -> IO a -> IO a
withMutex (Mutex var) act = do
  !me <- threadNumber <$> myThreadId
  readTVarIO var >>= \case
    Owner owner | owner == me -> act
    _ -> bracket_ (acquire me) (release me) act
  where
    -- Another thread's (this one's, it was just seen not to be).
    acquire me = atomically $ readTVar var >>= \case
      Unowned -> writeTVar var (Owner me)
      Owner _ -> retry
    release me = atomically $ readTVar var >>= \case
      Owner owner | owner == me -> writeTVar var Unowned
      _ -> pure ()

-- | The number of the thread holding the mutex (as in 'show' of its
-- 'ThreadId').  For diagnostics and tests.
mutexOwner :: Mutex -> IO (Maybe Word64)
mutexOwner (Mutex var) = readTVarIO var <&> \case
  Unowned -> Nothing
  Owner owner -> Just owner

threadNumber :: ThreadId -> Word64
#if MIN_VERSION_base(4,19,0)
threadNumber = fromThreadId
#else
threadNumber (ThreadId t) = fromIntegral (rtsGetThreadId t)

foreign import ccall unsafe "rts_getThreadId"
  rtsGetThreadId :: ThreadId# -> CULLong
#endif
