{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}

-- | 'cancelActiveStatement', against its haddock:
--
-- * with no response pending (no request yet, a completed query, a stream
--   read to its end) it sends and reads nothing;
-- * a response that has all arrived but is unread is discarded without
--   sending anything;
-- * otherwise it sends one Attention (none if an interrupted read already
--   sent it) and reads up to the acknowledgement, so the statement is gone
--   from the server, with its locks, when it returns;
-- * a stream of the cancelled response throws 'ResultAbandoned';
-- * a transaction survives without @XACT_ABORT@; under @XACT_ABORT ON@ it
--   may be rolled back (timing-dependent, see docs/dev/design.md), and hmssql
--   reports which;
-- * it waits for another thread's request instead of interrupting it;
-- * a drain that fails or is interrupted breaks the connection.
--
-- The live tests watch the server through @sys.dm_exec_requests@ from a
-- second connection (VIEW SERVER STATE); the mock server shows exactly what
-- the client sends.
module Api.CancelActiveStatementSpec (spec) where

import UnusableCause (reasonCause)
import qualified RecipeState
import Control.Concurrent
import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Exception
import Control.Monad (forM, forM_, void, when)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import Streaming (Of (..), Stream)
import qualified Streaming.Prelude as S
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Concurrency.Mock
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Errors
import Hmssql.Connection.Internal (ActiveResponse (..), Connection (..), ReadState (..))
import Hmssql.Tds.Packet (PacketType (..))
import MockServer (MockError (..))
import OpenResponses (responsePending, theOpenResponse)
import TestDb

------------------------------------------------------------------------------
-- Live helpers

numbers :: Int -> Text
numbers n = "SELECT TOP " <> T.pack (show n) <> " ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | A stream of a million numbers with the first three read: its statement
-- is still running on the server, which waits for the client to read on.
partlyRead :: Connection -> IO (Stream (Of Int64) IO ())
partlyRead conn = do
  s <- S.map fromOnly <$> queryS conn (rawSql (numbers 1_000_000))
  xs :> rest <- S.toList (S.splitAt 3 s)
  xs `shouldBe` [1, 2, 3]
  pure rest

-- | Reading the stream on throws 'ResultAbandoned'.
expectAbandoned :: Stream (Of a) IO () -> IO ()
expectAbandoned s = within 10 (try (S.length_ s)) >>= \case
  Left ResultAbandoned -> pure ()
  Right n -> expectationFailure ("the stream went on for " ++ show n ++ " rows")

-- | No response pending on any session of the connection.
noResponsePending :: Connection -> IO ()
noResponsePending conn = do
  r <- responsePending conn
  when r $ expectationFailure "a response is still pending"

spidOf :: Connection -> IO Int
spidOf conn = fromOnly <$> query1 conn "SELECT CAST(@@SPID AS int)"

-- | A second connection that can see other sessions' requests; pending
-- without VIEW SERVER STATE.
withObserver :: (Connection -> IO ()) -> IO ()
withObserver act = withTestDb $ \obs -> do
  Only perm <- query1 obs "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"
  if perm == Just (1 :: Int)
    then act obs
    else pendingWith "needs VIEW SERVER STATE to see another session's requests"

-- | The status of each request the session has on the server.
requestStatus :: Connection -> Int -> IO [Text]
requestStatus obs spid =
  map fromOnly <$> query obs (mkQuery "SELECT status FROM sys.dm_exec_requests WHERE session_id = @p1" (Only spid))

-- | Run the action every 50 ms until its result satisfies the predicate or
-- the deadline (in seconds) passes; returns the last result.
pollFor :: Double -> (a -> Bool) -> IO a -> IO a
pollFor seconds ok act = do
  t0 <- getMonotonicTime
  let go = do
        a <- act
        now <- getMonotonicTime
        if ok a || now - t0 > seconds then pure a else threadDelay 50_000 >> go
  go

-- | A request that is waiting for the client, or working.
activeStatus :: [Text] -> Bool
activeStatus = \case
  [st] -> st `elem` ["suspended", "running", "runnable"]
  _ -> False


------------------------------------------------------------------------------
-- Mock helpers

-- | What the client sent after the scripted part.
data Seen = Batch Text | Attention
  deriving stock (Eq, Show)

-- | Answer @SELECT n@ batches with @n@ and acknowledge Attentions, recording
-- every message, until the client closes the connection.
serveRecording :: MockIO -> IO [Seen]
serveRecording io = go []
  where
    go acc = try (mRecv io 30_000_000) >>= \case
      Left MockClientClosed -> pure (reverse acc)
      Left e -> throwIO e
      Right Nothing -> throwIO (MockUnexpected "client idle for 30 s")
      Right (Just (PTAttention, _)) -> mSendMessage io [doneAttn] >> go (Attention : acc)
      Right (Just (PTSqlBatch, body)) -> do
        let sql = batchText body
        mSendMessage io (maybe [doneFinal 0] answerSelect (selectedNumber sql))
        go (Batch sql : acc)
      Right (Just (ptype, _)) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))

mockOutcome :: Either SomeException r -> IO r
mockOutcome = either (\e -> throwIO (userError ("mock: " ++ show e))) pure

abandonedOr :: Either ResultAbandoned a -> Maybe a
abandonedOr = either (\ResultAbandoned -> Nothing) Just

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "live server" $ around withTestDb $ do
    describe "with no response pending" $ do
      it "returns before any request, and the connection works" $ \conn -> within 30 $ do
        cancelActiveStatement conn
        noResponsePending conn
        expectUsable conn

      it "returns after a query or execute that completed, and the connection works" $ \conn -> within 30 $ do
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
        cancelActiveStatement conn
        noResponsePending conn
        _ <- execute conn "DECLARE @x int = 1"
        cancelActiveStatement conn
        noResponsePending conn
        expectUsable conn

      it "is a no-op for a stream read to its end, and the connection works" $ \conn -> within 30 $ do
        s <- queryS conn (rawSql (numbers 10_000))
        S.toList_ (S.map fromOnly s) `shouldReturn` [1 .. 10_000 :: Int64]
        noResponsePending conn
        cancelActiveStatement conn
        noResponsePending conn
        expectUsable conn

    -- A normal return says the connection is not known to be unusable:
    -- it refuses a connection the server has closed (marking it broken,
    -- as a request would) and a broken one, rather than returning with
    -- nothing to do.
    it "on a connection the server has closed throws the close, then ConnectionBroken, as a request would" $ \conn -> within 30 $ do
      victim <- sessionIdentity conn
      killSession victim
      atomically $ readTVar (connEnded conn) >>= check . isJust
      try (cancelActiveStatement conn) >>= \case
        Left (ConnectionClosedBy ClosedByClient) -> expectationFailure "closed by the client?"
        Left (ConnectionClosedBy _) -> pure ()
        Right () -> expectationFailure "returned with nothing to do on a closed connection"
      try (cancelActiveStatement conn) >>= \case
        Left (ConnectionBroken _) -> pure ()
        Right () -> expectationFailure "returned on a broken connection"
      try (query1 conn "SELECT 1" :: IO (Only Int)) >>= \case
        Left (ConnectionBroken _) -> pure ()
        Right v -> expectationFailure ("a broken connection answered " ++ show v)

    it "cancels a partly read stream: the stream is abandoned, the connection works, and the statement is gone from the server" $ \conn ->
      withObserver $ \obs -> within 60 $ do
        spid <- spidOf conn
        requestStatus obs spid `shouldReturn` []
        rest <- partlyRead conn
        -- Abandoned but not cancelled: the statement lingers on the server,
        -- waiting for the client to read on.
        before <- pollFor 10 activeStatus (requestStatus obs spid)
        before `shouldSatisfy` activeStatus
        threadDelay 300_000
        requestStatus obs spid >>= (`shouldSatisfy` activeStatus)
        cancelActiveStatement conn
        noResponsePending conn
        -- Cancelled: no request left for the session.
        after <- pollFor 10 null (requestStatus obs spid)
        after `shouldBe` []
        expectAbandoned rest
        query1 conn "SELECT 40 + 2" `shouldReturn` Only (42 :: Int)
        expectUsable conn

    it "releases the locks of a partly read stream's statement: a writer it blocks gets through after the cancel" $ \other -> within 60 $ do
      name <- uniqueName "hmssql_cancel_locks"
      let table = "dbo." <> name
          insert = try @SqlServerError $ execute other (rawSql ("SET LOCK_TIMEOUT 0; INSERT INTO " <> table <> " VALUES (2)"))
      _ <- execute other (rawSql ("CREATE TABLE " <> table <> " (x int); INSERT INTO " <> table <> " VALUES (1)"))
      flip finally (execute other (rawSql ("SET LOCK_TIMEOUT -1; DROP TABLE IF EXISTS " <> table))) $ withTestDb $ \conn -> do
        -- HOLDLOCK: the shared table lock is held until the statement ends.
        s <- queryS conn (rawSql ("SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM " <> table
          <> " t WITH (TABLOCK, HOLDLOCK) CROSS JOIN sys.all_columns a CROSS JOIN sys.all_columns b"))
        S.toList_ (S.take 3 (S.map fromOnly s)) `shouldReturn` [1, 2, 3 :: Int64]
        -- The abandoned statement still holds its lock.
        insert >>= \case
          Left e -> sqlErrorNumber e `shouldBe` 1222
          Right _ -> expectationFailure "the insert got through while the stream's statement held its lock"
        cancelActiveStatement conn
        r <- pollFor 10 (either (const False) (const True)) insert
        either (\e -> expectationFailure ("still blocked after the cancel: " ++ show e)) (`shouldBe` 1) r
        expectAbandoned s
        expectUsable conn

    it "is idempotent: calling it twice in a row cancels once, and the connection works" $ \conn -> within 60 $ do
      rest <- partlyRead conn
      cancelActiveStatement conn
      noResponsePending conn
      cancelActiveStatement conn
      noResponsePending conn
      expectAbandoned rest
      expectUsable conn

    it "after a consumer was killed while waiting for rows (which sent the Attention), only drains, and the connection works" $ \conn -> within 60 $ do
      -- WAITFOR first: the consumer waits for the first row, so the kill
      -- lands in a read.
      s <- queryS conn "WAITFOR DELAY '00:00:20'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
      started <- newEmptyMVar
      result <- newEmptyMVar
      tid <- forkIO $ do
        putMVar started ()
        try (S.toList_ s) >>= putMVar result
      takeMVar started
      threadDelay 200_000
      killThread tid
      within 10 (takeMVar result) >>= \case
        Left ThreadKilled -> pure ()
        other -> expectationFailure ("the consumer ended with " ++ show other)
      -- The interrupted read sent the Attention already.
      ar <- theOpenResponse conn
      RecipeState.attentionSent ar `shouldReturn` True
      -- Waiting out the WAITFOR would take 20 s.
      (_, t) <- elapsed (within 30 (cancelActiveStatement conn))
      t `shouldSatisfy` (< 5)
      noResponsePending conn
      expectAbandoned s
      expectUsable conn

    it "discards a small response that has all arrived without sending an Attention, and the connection works" $ \conn -> within 30 $ do
      s <- queryS conn "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3"
      xs :> rest <- S.toList (S.splitAt 1 s)
      xs `shouldBe` [Only (1 :: Int)]
      ar <- theOpenResponse conn
      -- The last packet is in hand.
      (RecipeState.ended <$> readIORef (arState ar)) `shouldReturn` True
      cancelActiveStatement conn
      RecipeState.attentionSent ar `shouldReturn` False
      noResponsePending conn
      expectAbandoned rest
      expectUsable conn

    describe "inside withTransaction" $ do
      it "without XACT_ABORT, the transaction survives the cancel and commits" $ \conn -> within 60 $ do
        _ <- execute conn "CREATE TABLE #t (x int)"
        withTransaction conn $ do
          _ <- execute conn "INSERT INTO #t VALUES (1)"
          rest <- partlyRead conn
          cancelActiveStatement conn
          inTransaction conn `shouldReturn` True
          expectAbandoned rest
          _ <- execute conn "INSERT INTO #t VALUES (2)"
          query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (1 :: Int)
        inTransaction conn `shouldReturn` False
        query conn "SELECT x FROM #t ORDER BY x" `shouldReturn` [Only (1 :: Int), Only 2]
        expectUsable conn

      -- docs/dev/design.md, "Abandoning a stream can roll back a transaction":
      -- whether the Attention rolls the transaction back depends on timing.
      -- Either way, hmssql's report (inTransaction, TransactionEndedEarly)
      -- must match what the server did.
      it "under XACT_ABORT ON, the transaction is either rolled back (TransactionEndedEarly) or survives, as reported, and the connection works" $ \conn -> within 120 $ do
        _ <- execute conn "SET XACT_ABORT ON; CREATE TABLE #t (x int)"
        outcomes <- forM [1 .. 5 :: Int] $ \i -> do
          inside <- newIORef Nothing
          r <- try @TransactionError $ withTransaction conn $ do
            _ <- execute conn (mkQuery "INSERT INTO #t VALUES (@p1)" (Only i))
            rest <- partlyRead conn
            cancelActiveStatement conn
            inTransaction conn >>= writeIORef inside . Just
            expectAbandoned rest
          stillIn <- readIORef inside
          inTransaction conn `shouldReturn` False
          committed <- (== [Only i]) <$> query conn (mkQuery "SELECT x FROM #t WHERE x = @p1" (Only i))
          case (r, stillIn) of
            (Right (), Just True) -> ("survived" <$ (committed `shouldBe` True))
            (Left TransactionEndedEarly, Just False) -> ("rolled back" <$ (committed `shouldBe` False))
            other -> ("?" <$ expectationFailure ("inconsistent outcome: " ++ show other))
        let count o = length (filter (== o) outcomes)
        hPutStrLn stderr ("    [XACT_ABORT cancel] " ++ show (count ("rolled back" :: String)) ++ " rolled back, "
          ++ show (count "survived") ++ " survived, of " ++ show (length outcomes))
        expectUsable conn

    describe "while another thread's request is in progress" $
      forM_ [ ("execute", \c -> void (execute c "WAITFOR DELAY '00:00:01'"))
            , ("callProcedure", \c -> void (callProcedure c "sp_executesql" [inParam "" ("WAITFOR DELAY '00:00:01'" :: Text)]))
            ] $ \(what, request) ->
        it ("waits for " ++ what ++ " to finish instead of interrupting it") $ \conn -> within 60 $ do
          t0 <- getMonotonicTime
          done <- newEmptyMVar
          _ <- forkIO $ do
            r <- try @SomeException (request conn)
            t <- getMonotonicTime
            putMVar done (r, t)
          -- The request is registered: the other thread holds the connection.
          pollFor 10 id (responsePending conn) `shouldReturn` True
          cancelActiveStatement conn
          t1 <- getMonotonicTime
          (r, tr) <- within 10 (takeMVar done)
          either (\e -> expectationFailure (what ++ " failed: " ++ show e)) pure r
          -- The WAITFOR ran its full second (an Attention would have ended
          -- it early), and the cancel returned only after it.
          (tr - t0) `shouldSatisfy` (>= 0.9)
          (t1 - t0) `shouldSatisfy` (>= 0.9)
          noResponsePending conn
          expectUsable conn

  describe "mock server" $ do
    it "sends nothing with no response pending: before any request, after a query, after a stream read to its end, twice in a row" $ do
      (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $ withConnection ci $ \conn -> do
        cancelActiveStatement conn
        a <- query1 conn "SELECT 1"
        cancelActiveStatement conn
        s <- queryS conn "SELECT 2"
        b <- S.toList_ s
        cancelActiveStatement conn
        cancelActiveStatement conn
        c <- query1 conn "SELECT 3"
        pure (a, b, c)
      results `shouldBe` (Only (1 :: Int64), [Only (2 :: Int64)], Only (3 :: Int64))
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 1", Batch "SELECT 2", Batch "SELECT 3"])

    it "sends nothing for a response that has fully arrived but is unread, and discards it" $ do
      let script io = do
            _ <- expectBatch io
            mSendMessage io [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3, doneFinal 3]
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        cancelActiveStatement conn
        pending <- responsePending conn
        again <- try (S.toList_ rest)
        final <- query1 conn "SELECT 4"
        pure (first, pending, abandonedOr again, final)
      results `shouldBe` ([Only (1 :: Int64)], False, Nothing, Only (4 :: Int64))
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 4"])

    it "sends an Attention for a response that arrived before its stream was read at all: what has arrived is only known once read" $ do
      let script io = do
            _ <- expectBatch io
            mSendMessage io [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3, doneFinal 3]
            expectAttention io
            mSendMessage io [doneAttn]
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many" :: IO (Stream (Of (Only Int64)) IO ())
        -- Let the whole response arrive; the client hasn't read any of it,
        -- so it can't know that, and cancels as if the server were still
        -- sending.  The server acknowledges the Attention as usual.
        threadDelay 200_000
        cancelActiveStatement conn
        again <- try (S.toList_ s)
        final <- query1 conn "SELECT 4"
        pure (abandonedOr again, final)
      results `shouldBe` (Nothing, Only (4 :: Int64))
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 4"])

    it "sends one Attention for a response still arriving, returns only once the acknowledgement is read, and the next request goes out normally" $ do
      ackSent <- newIORef False
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3])
            expectAttention io
            -- The cancelled result ends its message; the acknowledgement
            -- follows later, in a message of its own.
            mSendPacket io True (tokenBytes [rowBigint 4, doneFinal 4])
            threadDelay 200_000
            writeIORef ackSent True
            mSendMessage io [doneAttn]
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        cancelActiveStatement conn
        acked <- readIORef ackSent
        pending <- responsePending conn
        cancelActiveStatement conn
        again <- try (S.toList_ rest)
        final <- query1 conn "SELECT 5"
        pure (first, acked, pending, abandonedOr again, final)
      results `shouldBe` ([Only (1 :: Int64)], True, False, Nothing, Only (5 :: Int64))
      -- The Attention the script expected, and no other.
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 5"])

    it "after an interrupted read (which sent the Attention), sends no second Attention and reads up to the acknowledgement" $ do
      ackSent <- newIORef False
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1])
            -- Sent by the interrupted read.
            expectAttention io
            threadDelay 200_000
            writeIORef ackSent True
            mSendPacket io True (tokenBytes [rowBigint 2, doneAttn])
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> more <- S.toList (S.splitAt 1 s)
        waited <- timeout 100_000 (S.toList_ more)
        cancelActiveStatement conn
        acked <- readIORef ackSent
        pending <- responsePending conn
        again <- try (S.toList_ more)
        final <- query1 conn "SELECT 3"
        pure (first, waited, acked, pending, abandonedOr again, final)
      results `shouldBe` ([Only (1 :: Int64)], Nothing, True, False, Nothing, Only (3 :: Int64))
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 3"])

    it "a drain that fails (the server closes the connection) breaks the connection: the cancel rethrows, later requests and the stream throw ConnectionBroken" $ do
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3])
            expectAttention io
            -- Returning closes the connection, mid-drain.
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        cancelled <- try (cancelActiveStatement conn)
        later <- replicateTry 2 (query1 conn "SELECT 2" :: IO (Only Int64))
        again <- try (S.toList_ rest)
        pure (first, cancelled, later, again)
      case results of
        (first, cancelled, later, again) -> do
          first `shouldBe` [Only (1 :: Int64)]
          case cancelled of
            Left ConnectionClosed -> pure ()
            Right () -> expectationFailure "the cancel returned although the connection closed mid-drain"
          forM_ later $ \case
            Left (ConnectionBroken (reasonCause -> cause)) | Just ConnectionClosed <- fromException cause -> pure ()
            other -> expectationFailure ("expected ConnectionBroken carrying ConnectionClosed, got " ++ show other)
          case again of
            Left (ConnectionBroken _) -> pure ()
            Right rows -> expectationFailure ("the cancelled stream went on: " ++ show rows)
      either (\e -> expectationFailure ("mock: " ++ show e)) pure outcome

    it "a drain that is interrupted breaks the connection: later requests throw ConnectionBroken carrying the timeout, and nothing more is sent" $ do
      -- The two sides take turns through these rather than by sleeping, so
      -- that under load the client does not close the connection before the
      -- mock has finished with it.
      laterDone <- newEmptyMVar
      ackSent <- newEmptyMVar
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2])
            expectAttention io
            -- Hold the acknowledgement back until the client has timed out
            -- and made its later requests.
            within 10 (takeMVar laterDone)
            -- Anything those requests sent (a second Attention, say) has
            -- been written to the socket by now; a second lets the reader
            -- pick it up.
            extra <- collectFor io 1_000_000
            mSendPacket io True (tokenBytes [doneAttn])
            putMVar ackSent ()
            rest <- serveRecording io
            pure (map fst extra, rest)
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        cancelled <- timeout 200_000 (cancelActiveStatement conn)
        later <- replicateTry 2 (query1 conn "SELECT 2" :: IO (Only Int64))
        again <- try (S.toList_ rest)
        putMVar laterDone ()
        -- Stay connected until the mock has stopped collecting and sent the
        -- acknowledgement.
        within 10 (takeMVar ackSent)
        pure (first, cancelled, later, again)
      case results of
        (first, cancelled, later, again) -> do
          first `shouldBe` [Only (1 :: Int64)]
          cancelled `shouldBe` Nothing
          forM_ later $ \case
            Left (ConnectionBroken (reasonCause -> cause)) | isTimeout cause -> pure ()
            other -> expectationFailure ("expected ConnectionBroken carrying the timeout, got " ++ show other)
          case again of
            Left (ConnectionBroken (reasonCause -> cause)) | isTimeout cause -> pure ()
            Left other -> expectationFailure ("the stream failed with " ++ show other)
            Right rows -> expectationFailure ("the cancelled stream went on: " ++ show rows)
      case outcome of
        Left e -> expectationFailure ("mock: " ++ show e)
        Right (extra, rest) -> do
          -- No second Attention, and nothing on the broken connection.
          extra `shouldBe` []
          rest `shouldBe` []
  where
    replicateTry :: Int -> IO a -> IO [Either ConnectionBroken a]
    replicateTry n act = forM [1 .. n] (const (try act))
