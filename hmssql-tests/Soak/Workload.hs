{-# LANGUAGE DerivingStrategies #-}

-- | The mixed workload run by each soak-test worker ("Soak.RunSpec"): a
-- random pick among small queries, parameterized inserts/updates into the
-- worker's own table, transactions (commit, rollback, and one ended by a
-- server error), a partially-consumed stream, occasional large values,
-- info messages, errors of various severities (including a rare fatal one
-- that ends the session), and a client-side cancellation. Every operation
-- verifies its own result (most carry the sentinel value they expect back,
-- to catch a desynchronised connection), and only a connection failure
-- (killed session, a severity-20+ error, ...) is treated as expected rather
-- than a test failure -- the pool is what's supposed to notice and recover
-- from those (see "Soak.Pool").
module Soak.Workload
  ( OpKind (..)
  , allOpKinds
  , genOpKind
  , nextSentinel
  , newKnownIds
  , isConnFailure
  , runOp
  ) where

import Control.Exception
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32, Int64)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Hedgehog (Gen)
import qualified Streaming.Prelude as S
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Soak.Pool (PooledConn (..), clearInfoLog)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Throw with @msg@ (a plain 'IOException' via 'userError') unless the
-- condition holds. "Soak.RunSpec" catches these from each worker and
-- collects them as verification failures, so the run keeps going instead of
-- stopping at the first one.
verify :: Bool -> String -> IO ()
verify True _ = pure ()
verify False msg = throwIO (userError msg)

------------------------------------------------------------------------------
-- Sentinel ids

sentinelCounter :: IORef Int64
sentinelCounter = unsafePerformIO (newIORef 1)
{-# NOINLINE sentinelCounter #-}

-- | A fresh value, never returned by any other soak operation in this
-- process: embedded in queries so a wrong (or missing) result is caught as
-- a desync rather than silently accepted.
nextSentinel :: IO Int64
nextSentinel = atomicModifyIORef' sentinelCounter (\i -> (i + 1, i))

------------------------------------------------------------------------------
-- Operations

data OpKind
  = OpSmallQuery
  | OpParamInsert
  | OpParamUpdate
  | OpTxCommit
  | OpTxRollback
  | OpTxServerError
  | OpStreamPartial
  | OpLargeValue
  | OpInfoMessage
  | OpErrorSeverity
  | OpTimeoutCancel
  deriving stock (Eq, Show, Enum, Bounded)

allOpKinds :: [OpKind]
allOpKinds = [minBound .. maxBound]

-- | Weighted pick, biased towards cheap operations; large values and the
-- fatal-error path are rare on purpose (they are each expensive, or end a
-- connection).
genOpKind :: Gen OpKind
genOpKind = Gen.frequency
  [ (25, pure OpSmallQuery)
  , (15, pure OpParamInsert)
  , (12, pure OpParamUpdate)
  , (8, pure OpTxCommit)
  , (8, pure OpTxRollback)
  , (6, pure OpTxServerError)
  , (10, pure OpStreamPartial)
  , (3, pure OpLargeValue)
  , (7, pure OpInfoMessage)
  , (6, pure OpErrorSeverity)
  , (6, pure OpTimeoutCancel)
  ]

-- | The last few ids a worker inserted into its own table, so
-- 'OpParamUpdate' has something to update. Bounded, so it can't grow.
newKnownIds :: IO (IORef [Int64])
newKnownIds = newIORef []

pushKnown :: IORef [Int64] -> Int64 -> IO ()
pushKnown ref i = modifyIORef' ref (\xs -> i : take 49 xs)

-- | A connection failure: the server killed the session, a severity 20+
-- error ended it, or hmssql itself reports the connection broken. Expected
-- during a soak run (the pool is meant to detect and replace it -- see
-- 'Soak.Pool.checkin'), so it is not a verification failure.
isConnFailure :: SomeException -> Bool
isConnFailure e =
  isJust (fromException e :: Maybe ConnectionClosed)
    || isJust (fromException e :: Maybe ConnectionBroken)
    || case fromException e of
         Just se -> msgClass (sqlError se) >= 20
         Nothing -> False

-- | A private exception used only to force 'withTransaction' to roll back
-- (as opposed to a server error propagating up, which 'opTxServerError'
-- exercises separately).
data SoakRollback = SoakRollback
  deriving stock (Show)

instance Exception SoakRollback

opSmallQuery :: Connection -> Int64 -> IO ()
opSmallQuery conn sentinel = do
  (a, b) <- query1 conn (mkQuery "SELECT @p1, @p2" (sentinel, sentinel * 2)) :: IO (Int64, Int64)
  verify (a == sentinel && b == sentinel * 2)
    ("small query desync: expected (" ++ show sentinel ++ "," ++ show (sentinel * 2) ++ "), got " ++ show (a, b))

opParamInsert :: Connection -> Text -> Int -> Int64 -> IORef [Int64] -> IO ()
opParamInsert conn tbl workerIdx sentinel knownIds = do
  let val = "v" <> tshow sentinel
  n <- execute conn $ mkQuery
    ("INSERT INTO " <> tbl <> " (id, worker, val) VALUES (@p1, @p2, @p3)")
    (sentinel, fromIntegral workerIdx :: Int32, val)
  verify (n == 1) ("insert affected " ++ show n ++ " row(s), expected 1")
  Only readBack <- query1 conn (mkQuery ("SELECT val FROM " <> tbl <> " WHERE id = @p1") (Only sentinel))
  verify (readBack == val) ("insert readback mismatch: expected " ++ show val ++ ", got " ++ show readBack)
  pushKnown knownIds sentinel

opParamUpdate :: Connection -> Text -> Int64 -> IORef [Int64] -> IO ()
opParamUpdate conn tbl sentinel knownIds = do
  ids <- readIORef knownIds
  case ids of
    [] -> pure () -- nothing inserted yet (only possible early in the run)
    _ -> do
      pick <- Gen.sample (Gen.element ids)
      let val = "u" <> tshow sentinel
      n <- execute conn (mkQuery ("UPDATE " <> tbl <> " SET val = @p1 WHERE id = @p2") (val, pick))
      verify (n == 1) ("update of id " ++ show pick ++ " affected " ++ show n ++ " row(s), expected 1")
      Only readBack <- query1 conn (mkQuery ("SELECT val FROM " <> tbl <> " WHERE id = @p1") (Only pick))
      verify (readBack == val) ("update readback mismatch: expected " ++ show val ++ ", got " ++ show readBack)

rowExists :: Connection -> Text -> Int64 -> IO Bool
rowExists conn tbl sentinel = do
  Only cnt <- query1 conn (mkQuery ("SELECT COUNT(*) FROM " <> tbl <> " WHERE id = @p1") (Only sentinel)) :: IO (Only Int)
  pure (cnt > 0)

opTxCommit :: Connection -> Text -> Int64 -> IO ()
opTxCommit conn tbl sentinel = do
  withTransaction conn $ do
    _ <- execute conn (mkQuery ("INSERT INTO " <> tbl <> " (id, worker, val) VALUES (@p1, 0, 'commit')") (Only sentinel))
    pure ()
  ok <- rowExists conn tbl sentinel
  verify ok ("commit: row " ++ show sentinel ++ " should exist afterward")

opTxRollback :: Connection -> Text -> Int64 -> IO ()
opTxRollback conn tbl sentinel = do
  r <- try
    ( withTransaction conn $ do
        _ <- execute conn (mkQuery ("INSERT INTO " <> tbl <> " (id, worker, val) VALUES (@p1, 0, 'rollback')") (Only sentinel))
        throwIO SoakRollback
    ) :: IO (Either SoakRollback ())
  case r of
    Left SoakRollback -> pure ()
    Right () -> throwIO (userError "opTxRollback: the body did not throw, so nothing was rolled back")
  ok <- rowExists conn tbl sentinel
  verify (not ok) ("rollback: row " ++ show sentinel ++ " should not exist afterward")

-- | A server-side error inside the transaction body (as opposed to
-- 'opTxRollback''s client-thrown exception): 'withTransaction' rolls back
-- because the body threw, just via a different route.
--
-- This op catches 'SqlServerError' itself (to verify it's the RAISERROR it
-- just sent), which means it must also allow for a connection failure
-- racing with that RAISERROR: the background killer (or the rare fatal
-- severity-20 path in 'opErrorSeverity') can end this exact session between
-- the insert and the RAISERROR, in which case the server reports something
-- else entirely (e.g. "the session is in the kill state", severity 21) --
-- rethrown rather than treated as a verification failure, exactly like
-- 'isConnFailure' would classify it at the top level.
opTxServerError :: Connection -> Text -> Int64 -> IO ()
opTxServerError conn tbl sentinel = do
  let msg = "soak txn err " <> tshow sentinel
  r <- try
    ( withTransaction conn $ do
        _ <- execute conn (mkQuery ("INSERT INTO " <> tbl <> " (id, worker, val) VALUES (@p1, 0, 'txerr')") (Only sentinel))
        _ <- execute conn ("RAISERROR(" <> param msg <> ", 16, 1)")
        pure ()
    ) :: IO (Either SqlServerError ())
  case r of
    Left se
      | sqlErrorMessage se == msg -> pure ()
      | msgClass (sqlError se) >= 20 -> throwIO se
      | otherwise -> throwIO (userError
          ("txn server error message mismatch: expected " ++ show msg ++ ", got " ++ show (sqlErrorMessage se)))
    Right () -> throwIO (userError "opTxServerError: RAISERROR did not throw inside the transaction")
  ok <- rowExists conn tbl sentinel
  verify (not ok) ("txn server error: row " ++ show sentinel ++ " should have been rolled back")

opStreamPartial :: Connection -> Int64 -> IO ()
opStreamPartial conn sentinel = do
  rows <- queryS conn
    ("SELECT " <> param sentinel <> ", a.object_id FROM sys.all_columns a CROSS JOIN sys.all_columns b")
  firstFew <- S.toList_ (S.take 5 rows) :: IO [(Int64, Int32)]
  verify (not (null firstFew)) "stream: got no rows at all"
  verify (all ((== sentinel) . fst) firstFew)
    ("stream desync: expected every row's first column to be " ++ show sentinel ++ ", got " ++ show (map fst firstFew))

mkLargeValue :: Int64 -> Int -> B.ByteString
mkLargeValue sentinel len =
  let header = LB.toStrict (Put.runPut (Put.putInt64le sentinel))
      fillByte = fromIntegral (sentinel `mod` 251)
      fill = B.replicate (max 0 (len - B.length header)) fillByte
   in B.take len (header <> fill)

opLargeValue :: Connection -> Int64 -> IO ()
opLargeValue conn sentinel = do
  mib <- Gen.sample (Gen.int (Range.linear 1 8))
  let body = mkLargeValue sentinel (mib * 1024 * 1024)
  Only echoed <- query1 conn ("SELECT " <> param body) :: IO (Only B.ByteString)
  verify (echoed == body)
    ("large value round trip: sent " ++ show (B.length body) ++ " bytes, got back " ++ show (B.length echoed))

opInfoMessage :: PooledConn -> Int64 -> IO ()
opInfoMessage pc sentinel = do
  let conn = pcConn pc
      msg = "soak info " <> tshow sentinel
  clearInfoLog pc
  n <- execute conn ("RAISERROR(" <> param msg <> ", 10, 1)")
  verify (n == 0) ("severity-10 RAISERROR reported " ++ show n ++ " row(s) affected, expected 0")
  logged <- readIORef (pcInfoLog pc)
  verify (take 1 logged == [msg])
    ("info message not delivered as expected: wanted [" ++ show msg ++ "], got " ++ show (take 3 logged))

-- | Severities 11-18 (still usable afterward), and rarely a fatal
-- severity-20 one (@WITH LOG@, ending the session): that exception is left
-- to propagate, so the top-level dispatcher's 'isConnFailure' check
-- classifies it -- exactly like an external KILL -- as the pool's job to
-- notice and recover from, not a verification failure.
opErrorSeverity :: Connection -> Int64 -> IO ()
opErrorSeverity conn sentinel = do
  fatal <- Gen.sample (Gen.frequency [(400, pure False), (1, pure True)])
  if fatal
    then do
      let msg = "soak fatal " <> tshow sentinel
      _ <- execute conn ("RAISERROR(" <> param msg <> ", 20, 1) WITH LOG")
      throwIO (userError "opErrorSeverity: a severity-20 RAISERROR did not end the connection")
    else do
      sev <- Gen.sample (Gen.element [11, 14, 16, 18 :: Int32])
      let msg = "soak err " <> tshow sev <> " " <> tshow sentinel
      r <- try (execute conn (mkQuery "RAISERROR(@p1, @p2, 1)" (msg, sev))) :: IO (Either SqlServerError Int64)
      case r of
        Left se
          | sqlErrorMessage se == msg && fromIntegral (msgClass (sqlError se)) == sev -> pure ()
          -- Raced with an external KILL (or the fatal branch above, on
          -- another worker's connection) between sending the RAISERROR and
          -- getting its response: not the error we asked for, but a
          -- connection failure, not a verification failure.
          | msgClass (sqlError se) >= 20 -> throwIO se
          | otherwise -> throwIO (userError
              ("severity error mismatch: expected severity " ++ show sev ++ " message " ++ show msg
                ++ ", got severity " ++ show (msgClass (sqlError se)) ++ " message " ++ show (sqlErrorMessage se)))
        Right n -> throwIO (userError ("RAISERROR severity " ++ show sev ++ " did not throw (returned " ++ show n ++ ")"))

opTimeoutCancel :: Connection -> Int64 -> IO ()
opTimeoutCancel conn sentinel = do
  r <- timeout 50_000 (query1 conn ("WAITFOR DELAY '00:00:01'; SELECT " <> param sentinel) :: IO (Only Int64))
  case r of
    Just (Only v) -> verify (v == sentinel) ("timeout op: unexpected value " ++ show v ++ " for sentinel " ++ show sentinel)
    Nothing -> pure () -- the common case: cancelled well before the WAITFOR would finish
  let sentinel2 = sentinel + 1
  Only v2 <- query1 conn ("SELECT " <> param sentinel2) :: IO (Only Int64)
  verify (v2 == sentinel2) ("post-cancellation desync: expected " ++ show sentinel2 ++ ", got " ++ show v2)

-- | Run one operation on the given pooled connection.
runOp :: OpKind -> PooledConn -> Text -> Int -> Int64 -> IORef [Int64] -> IO ()
runOp kind pc tbl workerIdx sentinel knownIds = case kind of
  OpSmallQuery -> opSmallQuery conn sentinel
  OpParamInsert -> opParamInsert conn tbl workerIdx sentinel knownIds
  OpParamUpdate -> opParamUpdate conn tbl sentinel knownIds
  OpTxCommit -> opTxCommit conn tbl sentinel
  OpTxRollback -> opTxRollback conn tbl sentinel
  OpTxServerError -> opTxServerError conn tbl sentinel
  OpStreamPartial -> opStreamPartial conn sentinel
  OpLargeValue -> opLargeValue conn sentinel
  OpInfoMessage -> opInfoMessage pc sentinel
  OpErrorSeverity -> opErrorSeverity conn sentinel
  OpTimeoutCancel -> opTimeoutCancel conn sentinel
  where
    conn = pcConn pc
