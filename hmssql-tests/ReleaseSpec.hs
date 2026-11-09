{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}

-- | 'release', against its haddock and connection-release-renew.md:
--
-- * on a connection that is fine it returns 'True', and the handle it was
--   given is released ('ConnectionReleased' from then on, streams
--   included); the next borrower's 'renew'ed handle works;
-- * a statement still running (a stream not read to its end) is cancelled,
--   so it is gone from the server when 'release' returns;
-- * with no transaction open the reset stays lazy: nothing is sent, and the
--   next request after 'renew' carries the RESETCONNECTION bit (or the
--   session setup batch before it does);
-- * with a transaction open the reset is carried out at once, by one
--   request carrying the bit (a @SELECT 1@ batch, or the session setup
--   batch), so the transaction's locks are released before the connection
--   idles, and the next request carries no bit;
-- * a connection that is closed, killed, or fails on the way gives
--   'False', and 'False' always leaves it broken or closed;
-- * it waits behind another thread's request or 'withTransaction'; inside
--   'withTransaction' (unsupported) it gives the documented outcome.
--
-- The live tests run with whatever session setup @HMSSQL_TEST_SESSION_SETUP@
-- gives the test connections, and pass with both; the mock tests try both
-- kinds of setup explicitly, and show exactly what is sent.
module ReleaseSpec (spec) where

import UnusableCause (reasonCause, brokenCause)
import Control.Concurrent (forkIO, isEmptyMVar, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception
import Control.Monad (forM_, void)
import Data.Binary.Put (Put)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import Streaming (Of (..), Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (elapsed, expectUsable, isTimeout, within)
import Concurrency.Mock
import Hmssql
-- 'renewLease' gives a handle to a connection 'renew' would refuse, for the
-- tests of what requests through it throw.
import Hmssql.Connection.Internal (Connection (..), renewLease)
import Hmssql.Errors
import Hmssql.Tds.Packet
import Hmssql.Transaction
import Hmssql.Types (ServerMessage (..))
import MockServer
import OpenResponses (responsePending)
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

-- | A request that is waiting for the client, or working.
activeStatus :: [Text] -> Bool
activeStatus = \case
  [st] -> st `elem` ["suspended", "running", "runnable"]
  _ -> False

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

-- | Wait (up to 10 s) until the client has seen the server close the
-- connection ('connEnded'): only then does 'release' know without asking.
awaitEnded :: Connection -> IO ()
awaitEnded conn = do
  ended <- pollFor 10 id (isJust <$> readTVarIO (connEnded conn))
  ended `shouldBe` True

-- | Kill the connection's session from another connection.
killFrom :: Connection -> IO ()
killFrom victim = sessionIdentity victim >>= killSession

-- | A real table (so its contents and locks outlive a reset) with a unique
-- name, dropped afterwards.
withTable :: (Text -> IO a) -> IO a
withTable act = do
  name <- ("dbo." <>) <$> uniqueName "release"
  withTestDb $ \c -> void $ execute c (rawSql ("CREATE TABLE " <> name <> " (id int PRIMARY KEY, v int)"))
  act name `finally` withTestDb (\c -> void $ execute c (rawSql ("DROP TABLE IF EXISTS " <> name)))

insert :: Connection -> Text -> Int -> IO ()
insert conn t i = void $ execute conn (rawSql ("INSERT INTO " <> t <> " VALUES (" <> T.pack (show i) <> ", 1)"))

count :: Connection -> Text -> IO Int
count conn table = fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table))

-- | Whether the @#hmssql_release@ temp table exists.
tempTableExists :: Connection -> IO Bool
tempTableExists conn = do
  Only oid <- query1 conn "SELECT OBJECT_ID('tempdb..#hmssql_release')"
  pure (isJust (oid :: Maybe Int))

-- | Whether ARITHABORT is on.  It is off after login, and the session
-- setup of @HMSSQL_TEST_SESSION_SETUP=arithabort@ turns it on, so after a
-- reset it tells whether the setup ran again.
arithAbort :: Connection -> IO Bool
arithAbort conn = do
  Only opts <- query1 conn "SELECT CAST(@@OPTIONS AS int)"
  pure ((opts :: Int) .&. 64 /= 0)

-- | Reading the stream on throws 'ConnectionReleased'.
expectReleased :: Stream (Of a) IO () -> IO ()
expectReleased s = within 10 (try (S.length_ s)) >>= \case
  Left ConnectionReleased -> pure ()
  Right n -> expectationFailure ("the stream went on for " ++ show n ++ " rows")

------------------------------------------------------------------------------
-- Mock helpers

-- | What the client sent: a SQL batch's text and whether it carried the
-- RESETCONNECTION bit, or an Attention.
data Seen = Batch Text Bool | Attention
  deriving stock (Eq, Show)

-- | The next message, with its type, whether its first packet carries the
-- RESETCONNECTION bit, and the whole body; Nothing once the client closed
-- the connection.
recvWithReset :: MockConn -> IO (Maybe (PacketType, Bool, B.ByteString))
recvWithReset mc = recvPacket mc >>= \case
  Nothing -> pure Nothing
  Just (hdr, body) -> do
    let resetBit = headerStatus hdr .&. statusResetConnection /= PacketStatus 0
        go acc h
          | headerStatus h .&. statusEndOfMessage /= PacketStatus 0 = pure (B.concat (reverse acc))
          | otherwise = recvPacket mc >>= \case
              Nothing -> throwIO (MockUnexpected "client closed mid-message")
              Just (h', b) -> go (b : acc) h'
    whole <- go [body] hdr
    pure (Just (headerType hdr, resetBit, whole))

-- | Log in, then answer every SQL batch with the tokens @answer@ gives for
-- its text and RESETCONNECTION bit, and acknowledge Attentions, until the
-- client closes the connection; returns every message.
recordingServer :: (Text -> Bool -> [Put]) -> MockConn -> IO [Seen]
recordingServer answer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let loop acc = recvWithReset mc >>= \case
        Nothing -> pure (reverse acc)
        Just (PTSqlBatch, resetBit, body) -> do
          let sql = batchText body
          sendTokens mc (answer sql resetBit)
          loop (Batch sql resetBit : acc)
        Just (PTAttention, _, _) -> sendTokens mc [doneAttn] >> loop (Attention : acc)
        Just (ptype, _, _) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))
  loop []

-- | As SQL Server answers: a request carrying the RESETCONNECTION bit gets
-- the reset acknowledgement (which ends any transaction), @BEGIN TRAN@ the
-- begin-transaction ENVCHANGE, and every batch a final DONE.
serverAnswer :: Text -> Bool -> [Put]
serverAnswer sql resetBit =
  [resetConnectionEnvChange | resetBit]
    ++ [beginTransactionEnvChange 1 | "BEGIN TRAN" `T.isPrefixOf` sql]
    ++ [doneToken 0 0]

-- | 'serverAnswer', except that a request carrying the RESETCONNECTION bit
-- fails with an ERROR token.
failingReset :: Text -> Bool -> [Put]
failingReset sql resetBit
  | resetBit = [errorToken resetError, doneToken 0x0002 0]
  | otherwise = serverAnswer sql resetBit

resetError :: ServerMessage
resetError = ServerMessage
  { msgNumber = 50000, msgState = 1, msgClass = 16, msgText = "the reset failed"
  , msgServer = "mock", msgProcedure = "", msgLine = 1 }

-- | The two kinds of session setup whose resets differ on the wire: one
-- setup batch that carries the bit before the next request, or none (the
-- request carries it).
mockSetups :: [(String, [Text])]
mockSetups = [("with a session setup", ["SET ARITHABORT ON"]), ("without a session setup", [])]

-- | The setup batch 'connect' sends, if any.
connectBatches :: [Text] -> [Seen]
connectBatches setup = [Batch (T.intercalate "\n" setup) False | not (null setup)]

-- | A request made with a reset pending: the setup batch carries the bit,
-- or the request itself does.
resetThen :: [Text] -> Text -> [Seen]
resetThen setup sql
  | null setup = [Batch sql True]
  | otherwise = [Batch (T.intercalate "\n" setup) True, Batch sql False]

-- | The request 'release' makes to reset a connection with a transaction
-- open: the setup batch, or @SELECT 1@.
eagerReset :: [Text] -> Seen
eagerReset setup
  | null setup = Batch "SELECT 1" True
  | otherwise = Batch (T.intercalate "\n" setup) True

mockOutcome :: Either SomeException r -> IO r
mockOutcome = either (\e -> throwIO (userError ("mock: " ++ show e))) pure

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "live server" $ do
    it "after close gives False without throwing" $ within 30 $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      close conn
      release conn `shouldReturn` False
      -- The next borrower gets no handle.
      renew conn `shouldThrow` \case
        ConnectionClosedBy ClosedByClient -> True
        _ -> False

    around withTestDb liveTests

  describe "mock server" mockTests

liveTests :: SpecWith Connection
liveTests = do
    it "on an idle connection gives True, leaves the reset pending, and the renewed handle's session is reset (temp table gone, session setup re-run)" $ \conn -> within 30 $ do
      setupOn <- testSessionSetupArithabort
      _ <- execute conn (rawSql ("CREATE TABLE #hmssql_release (i int); SET ARITHABORT " <> (if setupOn then "OFF" else "ON")))
      arithAbort conn `shouldReturn` not setupOn
      release conn `shouldReturn` True
      readIORef (connResetPending conn) `shouldReturn` True
      try (query1 conn "SELECT 1") >>= \case
        Left ConnectionReleased -> pure ()
        Right (Only (n :: Int)) -> expectationFailure ("the released handle answered " ++ show n)
      conn' <- renew conn
      tempTableExists conn' `shouldReturn` False
      readIORef (connResetPending conn') `shouldReturn` False
      arithAbort conn' `shouldReturn` setupOn
      expectUsable conn'

    it "cancels a partly read stream: True, the statement is gone from the server, and the old stream throws ConnectionReleased" $ \conn ->
      withObserver $ \obs -> within 60 $ do
        spid <- spidOf conn
        rest <- partlyRead conn
        -- Abandoned but not cancelled: the statement waits for the client.
        before <- pollFor 10 activeStatus (requestStatus obs spid)
        before `shouldSatisfy` activeStatus
        release conn `shouldReturn` True
        -- Cancelled: no request left for the session.
        after <- pollFor 10 null (requestStatus obs spid)
        after `shouldBe` []
        responsePending conn `shouldReturn` False
        expectReleased rest
        conn' <- renew conn
        query1 conn' "SELECT 40 + 2" `shouldReturn` Only (42 :: Int)
        expectUsable conn'

    it "with a transaction open on a real table, gives True and ends the transaction at once: its locks are released before any further request, and the renewed handle's session is reset" $ \conn -> withTable $ \t -> within 60 $ do
      resource <- uniqueName "release_lock"
      insert conn t 1
      _ <- execute conn "CREATE TABLE #hmssql_release (i int)"
      Only (r :: Int) <- query1 conn $ mkQuery
        "DECLARE @r int; EXEC @r = sp_getapplock @Resource = @p1, @LockMode = 'Exclusive', \
        \@LockOwner = 'Session', @LockTimeout = 0; SELECT @r" (Only resource)
      r `shouldSatisfy` (>= 0)
      begin conn
      _ <- execute conn (rawSql ("UPDATE " <> t <> " SET v = 2 WHERE id = 1"))
      inTransaction conn `shouldReturn` True
      -- The session applock (released by the reset only) and the row lock
      -- (released by the rollback), and the row's committed value.
      let tryLocks other = do
            Only (applock :: Int) <- query1 other $ mkQuery
              "DECLARE @r int; EXEC @r = sp_getapplock @Resource = @p1, @LockMode = 'Exclusive', \
              \@LockOwner = 'Session', @LockTimeout = 0; \
              \IF @r >= 0 EXEC sp_releaseapplock @Resource = @p1, @LockOwner = 'Session'; SELECT @r"
              (Only resource)
            row <- try (query1 other (rawSql ("SET LOCK_TIMEOUT 0; SELECT v FROM " <> t <> " WITH (READCOMMITTEDLOCK) WHERE id = 1")))
            pure (applock >= 0, either (\(_ :: SqlServerError) -> Nothing) (\(Only v) -> Just (v :: Int)) row)
      withTestDb $ \other -> do
        tryLocks other `shouldReturn` (False, Nothing)
        release conn `shouldReturn` True
        inTransaction conn `shouldReturn` False
        -- Carried out, not left for the next request.
        readIORef (connResetPending conn) `shouldReturn` False
        -- Nothing more on conn: the release alone let go of the locks.
        tryLocks other `shouldReturn` (True, Just 1)
      conn' <- renew conn
      -- The renewed handle's first request finds the session reset.
      (,) <$> tempTableExists conn' <*> (fromOnly <$> query1 conn' "SELECT @@TRANCOUNT")
        `shouldReturn` (False, 0 :: Int)
      withTestDb $ \other -> query other (rawSql ("SELECT v FROM " <> t)) `shouldReturn` [Only (1 :: Int)]
      expectUsable conn'

    it "after the session was KILLed from another session gives False" $ \conn -> within 30 $ do
      killFrom conn
      awaitEnded conn
      release conn `shouldReturn` False

    skipOnAzure "RAISERROR ... WITH LOG needs sysadmin (error 2778)" $
      it "after a severity-20 error (the server closes the connection) gives False" $ \conn -> within 30 $ do
        r <- try (execute conn "RAISERROR('hmssql release', 20, 1) WITH LOG")
        case r of
          Left (_ :: SomeException) -> pure ()
          Right n -> expectationFailure ("RAISERROR severity 20 succeeded, rows=" ++ show n)
        -- The server closes the connection after the error; the client
        -- sees it shortly after.
        awaitEnded conn
        release conn `shouldReturn` False

    describe "from another thread" $ do
      it "waits for a withTransaction to end, which commits, then gives True" $ \conn -> withTable $ \t -> within 60 $ do
        inBody <- newEmptyMVar
        released <- newEmptyMVar
        withTransaction conn $ do
          insert conn t 1
          _ <- forkIO $ putMVar inBody () >> try @SomeException (release conn) >>= putMVar released
          takeMVar inBody
          threadDelay 100_000
          -- The other thread is still waiting for the connection.
          isEmptyMVar released `shouldReturn` True
          insert conn t 2
        within 10 (takeMVar released) >>= \case
          Right ok -> ok `shouldBe` True
          Left e -> expectationFailure ("release failed: " ++ show e)
        withTestDb $ \other -> count other t `shouldReturn` 2
        renew conn >>= expectUsable

      it "waits for an execute to finish instead of cancelling it, then gives True" $ \conn -> within 60 $ do
        t0 <- getMonotonicTime
        done <- newEmptyMVar
        _ <- forkIO $ do
          r <- try @SomeException (execute conn "WAITFOR DELAY '00:00:01'")
          t <- getMonotonicTime
          putMVar done (r, t)
        -- The request is registered: the other thread holds the connection.
        pollFor 10 id (responsePending conn) `shouldReturn` True
        ok <- release conn
        t1 <- getMonotonicTime
        (r, tr) <- within 10 (takeMVar done)
        either (\e -> expectationFailure ("execute failed: " ++ show e)) (const (pure ())) r
        ok `shouldBe` True
        -- The WAITFOR ran its full second (an Attention would have ended
        -- it early), and the release returned only after it.
        (tr - t0) `shouldSatisfy` (>= 0.9)
        (t1 - t0) `shouldSatisfy` (>= 0.9)
        renew conn >>= expectUsable

    it "inside withTransaction (unsupported) rolls the transaction back, and withTransaction throws ConnectionReleased, leaving the connection broken by RollbackFailed" $ \conn -> withTable $ \t -> within 60 $ do
      inside <- newIORef Nothing
      r <- try $ withTransaction conn $ do
        insert conn t 1
        release conn >>= writeIORef inside . Just
      case r of
        Left ConnectionReleased -> pure ()
        Right () -> expectationFailure "withTransaction returned"
      readIORef inside `shouldReturn` Just True
      -- The reset request ended the transaction; the cleanup sent nothing.
      inTransaction conn `shouldReturn` False
      withTestDb $ \other -> count other t `shouldReturn` 0
      readIORef (connBroken conn) >>= \case
        Just (RollbackFailed inner) | Just ConnectionReleased <- fromException inner -> pure ()
        other -> expectationFailure ("expected broken by RollbackFailed ConnectionReleased, got " ++ show other)
      -- The pool's own check-in, on the next handle, says to close it.
      conn' <- renewLease conn
      release conn' `shouldReturn` False

mockTests :: Spec
mockTests = do
    forM_ mockSetups $ \(label, setup) -> describe label $ do
      it "on an idle connection sends nothing, and the next request after renew carries the reset" $
        withMockServer (recordingServer serverAnswer) $ \srv -> do
          results <- within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = setup } $ \conn -> do
            _ <- execute conn "SELECT 1"
            ok <- release conn
            pending <- readIORef (connResetPending conn)
            conn' <- renew conn
            _ <- execute conn' "SELECT 2"
            _ <- execute conn' "SELECT 3"
            pure (ok, pending)
          results `shouldBe` (True, True)
          nextResult srv >>= mockOutcome >>= (`shouldBe`
            connectBatches setup ++ [Batch "SELECT 1" False] ++ resetThen setup "SELECT 2" ++ [Batch "SELECT 3" False])

      it "with a transaction open sends one request carrying the reset, and the next request after renew carries none" $
        withMockServer (recordingServer serverAnswer) $ \srv -> do
          results <- within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = setup } $ \conn -> do
            _ <- execute conn "BEGIN TRAN"
            open <- inTransaction conn
            ok <- release conn
            after <- (,) <$> inTransaction conn <*> readIORef (connResetPending conn)
            conn' <- renew conn
            _ <- execute conn' "SELECT 2"
            pure (open, ok, after)
          results `shouldBe` (True, True, (False, False))
          nextResult srv >>= mockOutcome >>= (`shouldBe`
            connectBatches setup ++ [Batch "BEGIN TRAN" False, eagerReset setup, Batch "SELECT 2" False])

      it "when the reset request fails with an ERROR token gives False, and the connection is broken" $
        withMockServer (recordingServer failingReset) $ \srv -> do
          results <- within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = setup } $ \conn -> do
            _ <- execute conn "BEGIN TRAN"
            ok <- release conn
            broken <- brokenCause conn
            conn' <- renewLease conn
            later <- try (execute conn' "SELECT 2")
            pure (ok, broken, later)
          case results of
            (ok, broken, later) -> do
              ok `shouldBe` False
              case broken of
                Just e | Just (se :: SqlServerError) <- fromException e -> sqlErrorNumber se `shouldBe` 50000
                other -> expectationFailure ("expected broken by the SqlServerError, got " ++ show other)
              case later of
                Left (ConnectionBroken _) -> pure ()
                Right n -> expectationFailure ("the broken connection answered " ++ show n)
          -- Nothing after the failed reset.
          nextResult srv >>= mockOutcome >>= (`shouldBe`
            connectBatches setup ++ [Batch "BEGIN TRAN" False, eagerReset setup])

    it "finds a transaction begun by a response it discards: cancels it, then resets at once" $ do
      let answer sql resetBit
            | "BEGIN TRAN" `T.isPrefixOf` sql =
                [beginTransactionEnvChange 1, doneMore 0, colMetaBigint "n", rowBigint 1, rowBigint 2, doneFinal 2]
            | otherwise = serverAnswer sql resetBit
      withMockServer (recordingServer answer) $ \srv -> do
        results <- within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
          s <- queryS conn "BEGIN TRAN; SELECT n FROM many" :: IO (Stream (Of (Only Int64)) IO ())
          -- Unread: the client doesn't know yet that the transaction began.
          before <- inTransaction conn
          ok <- release conn
          after <- inTransaction conn
          stale <- try (S.toList_ s)
          pure (before, ok, after, either (\ConnectionReleased -> Nothing) Just stale)
        results `shouldBe` (False, True, False, Nothing)
        nextResult srv >>= mockOutcome >>= (`shouldBe`
          [Batch "BEGIN TRAN; SELECT n FROM many" False, Attention, Batch "SELECT 1" True])

    it "after the server closed the connection while idle gives False, and sends nothing" $ do
      let script io = do
            _ <- expectBatch io
            mSendMessage io (answerSelect 1)
            -- Returning closes the connection.
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        a <- query1 conn "SELECT 1"
        awaitEnded conn
        ok <- release conn
        pure (a, ok)
      results `shouldBe` (Only (1 :: Int64), False)
      either (\e -> expectationFailure ("mock: " ++ show e)) pure outcome

    it "gives False when the server closes the connection during the drain, and the connection is broken" $ do
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3])
            expectAttention io
            -- Returning closes the connection, mid-drain.
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> _ <- S.toList (S.splitAt 1 s)
        ok <- release conn
        broken <- isJust <$> readIORef (connBroken conn)
        conn' <- renewLease conn
        later <- try (query1 conn' "SELECT 2" :: IO (Only Int64))
        pure (first, ok, broken, later)
      case results of
        (first, ok, broken, later) -> do
          first `shouldBe` [Only (1 :: Int64)]
          (ok, broken) `shouldBe` (False, True)
          case later of
            Left (ConnectionBroken _) -> pure ()
            Right v -> expectationFailure ("the broken connection answered " ++ show v)
      either (\e -> expectationFailure ("mock: " ++ show e)) pure outcome

    it "interrupted while waiting for the Attention's acknowledgement (timeout) gives Nothing, and later requests on the renewed handle throw ConnectionBroken" $ do
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
            rest <- serveSelects io
            pure (map fst extra, rest)
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> _ <- S.toList (S.splitAt 1 s)
        (released, t) <- elapsed (timeout 200_000 (release conn))
        conn' <- renewLease conn
        later <- try (query1 conn' "SELECT 2" :: IO (Only Int64))
        again <- release conn'
        putMVar laterDone ()
        -- Stay connected until the mock has stopped collecting and sent the
        -- acknowledgement.
        within 10 (takeMVar ackSent)
        pure (first, released, t, later, again)
      case results of
        (first, released, t, later, again) -> do
          first `shouldBe` [Only (1 :: Int64)]
          released `shouldBe` Nothing
          t `shouldSatisfy` (< 5)
          case later of
            Left (ConnectionBroken (reasonCause -> cause)) | isTimeout cause -> pure ()
            other -> expectationFailure ("expected ConnectionBroken carrying the timeout, got " ++ show other)
          again `shouldBe` False
      case outcome of
        Left e -> expectationFailure ("mock: " ++ show e)
        Right (extra, rest) -> do
          -- No second Attention, and nothing on the broken connection.
          extra `shouldBe` []
          rest `shouldBe` []

    it "interrupted while waiting for the reset request's response (timeout) gives Nothing, and later requests on the renewed handle throw ConnectionBroken" $ do
      -- The two sides take turns through these rather than by sleeping, so
      -- that under load the client does not close the connection before the
      -- mock has finished with it.
      laterDone <- newEmptyMVar
      collected <- newEmptyMVar
      let script io = do
            _ <- expectBatch io
            mSendMessage io [beginTransactionEnvChange 1, doneFinal 0]
            -- The reset request, never answered.
            resetSql <- expectBatch io
            -- Wait until the client has timed out and made its later request.
            within 10 (takeMVar laterDone)
            -- Anything the client sent (the Attention, and anything it should
            -- not have sent) has been written to the socket by now; a second
            -- lets the reader pick it up.
            extra <- collectFor io 1_000_000
            putMVar collected ()
            rest <- serveSelects io
            pure (resetSql, map fst extra, rest)
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        _ <- execute conn "BEGIN TRAN"
        released <- timeout 200_000 (release conn)
        conn' <- renewLease conn
        later <- try (query1 conn' "SELECT 2" :: IO (Only Int64))
        putMVar laterDone ()
        -- Stay connected until the mock has stopped collecting.
        within 10 (takeMVar collected)
        pure (released, later)
      case results of
        (released, later) -> do
          released `shouldBe` Nothing
          case later of
            Left (ConnectionBroken (reasonCause -> cause)) | isTimeout cause -> pure ()
            other -> expectationFailure ("expected ConnectionBroken carrying the timeout, got " ++ show other)
      case outcome of
        Left e -> expectationFailure ("mock: " ++ show e)
        Right (resetSql, extra, rest) -> do
          resetSql `shouldBe` "SELECT 1"
          -- Only the Attention the interrupted read sends.
          extra `shouldBe` [PTAttention]
          rest `shouldBe` []
