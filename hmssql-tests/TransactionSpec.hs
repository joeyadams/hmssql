{-# LANGUAGE ViewPatterns #-}
-- | 'withTransaction' and 'withTransactionLevel': commit and rollback, the
-- isolation level inside the transaction and READ COMMITTED after it on every
-- exit path (a level set by hand before is not preserved), the transaction's
-- identity, nesting, and interruption.
module TransactionSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, void, when)
import Data.IORef
import Data.Int (Int16)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import System.Timeout (Timeout, timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.SqlValue
import Hmssql.Errors
import OpenResponses (isMarsConnection)
import TestDb

levels :: [IsolationLevel]
levels = [ReadUncommitted, ReadCommitted, RepeatableRead, Serializable, Snapshot]

-- | A level different from the given one, used as the session's level before
-- the transaction.  Every level (the default READ COMMITTED included) occurs.
previousFor :: IsolationLevel -> IsolationLevel
previousFor l = case dropWhile (/= l) (cycle levels) of
  _ : next : _ -> next
  _ -> ReadCommitted

levelSql :: IsolationLevel -> Text
levelSql = \case
  ReadUncommitted -> "READ UNCOMMITTED"
  ReadCommitted -> "READ COMMITTED"
  RepeatableRead -> "REPEATABLE READ"
  Snapshot -> "SNAPSHOT"
  Serializable -> "SERIALIZABLE"

setLevel :: Connection -> IsolationLevel -> IO ()
setLevel conn l = void $ execute conn (rawSql ("SET TRANSACTION ISOLATION LEVEL " <> levelSql l))

-- | The session's isolation level, as the server reports it.
sessionLevel :: Connection -> IO IsolationLevel
sessionLevel conn = do
  Only (n :: Int16) <- query1 conn "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID"
  case n of
    1 -> pure ReadUncommitted
    2 -> pure ReadCommitted
    3 -> pure RepeatableRead
    4 -> pure Serializable
    5 -> pure Snapshot
    _ -> fail ("unexpected transaction_isolation_level " ++ show n)

tranCount :: Connection -> IO Int
tranCount conn = fromOnly <$> query1 conn "SELECT @@TRANCOUNT"

rows :: Connection -> IO [Int]
rows conn = map fromOnly <$> query conn "SELECT i FROM #t ORDER BY i"

insert :: Connection -> Int -> IO ()
insert conn i = void $ execute conn ("INSERT INTO #t VALUES (" <> param i <> ")")

-- | Inside the transaction: the level asked for, and not nested.
checkInside :: Connection -> IsolationLevel -> IO ()
checkInside conn l = do
  sessionLevel conn `shouldReturn` l
  tranCount conn `shouldReturn` 1

-- | A way for 'withTransactionLevel' to end.  The action runs it on a
-- connection whose table @#t (i int PRIMARY KEY)@ is empty and checks how it
-- ended; it returns the rows #t should then have.
data ExitPath = ExitPath String (IsolationLevel -> Connection -> IO [Int])

shouldThrowSql :: Either SqlServerError a -> Int -> IO ()
shouldThrowSql r n = case r of
  Left e -> fromIntegral (sqlErrorNumber e) `shouldBe` n
  Right _ -> expectationFailure ("expected SQL error " ++ show n)

shouldEndEarly :: Either TransactionError a -> IO ()
shouldEndEarly = \case
  Left TransactionEndedEarly -> pure ()
  Left e -> expectationFailure ("expected TransactionEndedEarly, got " ++ show e)
  Right _ -> expectationFailure "expected TransactionEndedEarly"

-- | How a body that replaces the transaction in one batch (@ROLLBACK
-- TRANSACTION; BEGIN TRANSACTION@) ends: 'TransactionEndedEarly'.  Under
-- MARS a batch can't leave a transaction it began open: the server rolls
-- the new one back at the end of the batch (error 3997), and that error,
-- thrown by the body's request, is what the caller gets.
shouldEndReplaced :: Connection -> Either SomeException a -> IO ()
shouldEndReplaced conn = \case
  Left e
    | isMarsConnection conn, Just s <- fromException e -> sqlErrorNumber s `shouldBe` 3997
    | not (isMarsConnection conn), Just TransactionEndedEarly <- fromException e -> pure ()
    | otherwise -> expectationFailure ("threw " ++ show e)
  Right _ -> expectationFailure "the body's transaction was committed"

exitPaths :: [ExitPath]
exitPaths =
  [ ExitPath "commit" $ \l conn -> do
      withTransactionLevel l conn (checkInside conn l >> insert conn 1) `shouldReturn` ()
      pure [1]
  , ExitPath "an exception in the body" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        throwIO (userError "boom")
      either (\(e :: IOException) -> show e `shouldContain` "boom") (\() -> expectationFailure "no exception") r
      pure []
  , ExitPath "a server error in the body (statement-level, transaction left open)" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        execute conn "RAISERROR('boom', 16, 1)"
      r `shouldThrowSql` 50000
      pure []
  , ExitPath "killThread in the body" $ \l conn -> do
      inside <- newEmptyMVar
      outcome <- newEmptyMVar
      tid <- forkIO $ try (withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        putMVar inside ()
        threadDelay 60_000_000) >>= putMVar outcome
      takeMVar inside
      killThread tid
      takeMVar outcome >>= \case
        Left ThreadKilled -> pure ()
        other -> expectationFailure ("ended with " ++ show other)
      pure []
  , ExitPath "a timeout during a query in the body" $ \l conn -> do
      r <- timeout 500_000 $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        void $ execute conn "WAITFOR DELAY '00:00:20'"
      isJust r `shouldBe` False
      pure []
  , ExitPath "a server error under XACT_ABORT, rethrown" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        _ <- execute conn "SET XACT_ABORT ON"
        insert conn 1
        insert conn 1
      _ <- execute conn "SET XACT_ABORT OFF"
      r `shouldThrowSql` 2627
      pure []
  , ExitPath "a server error under XACT_ABORT, caught by the body" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        _ <- execute conn "SET XACT_ABORT ON"
        insert conn 1
        _ <- try @SqlServerError (insert conn 1)
        inTransaction conn `shouldReturn` False
      _ <- execute conn "SET XACT_ABORT OFF"
      shouldEndEarly r
      pure []
  , ExitPath "a doomed transaction, rolled back by the server at the end of the batch" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        -- XACT_STATE() is -1: uncommittable.  The server rolls it back when
        -- the batch ends (error 3998).
        r <- try $ query conn
          "SET XACT_ABORT ON; \
          \BEGIN TRY INSERT INTO #t VALUES (1) END TRY BEGIN CATCH SELECT XACT_STATE() END CATCH; \
          \SET XACT_ABORT OFF"
        (r :: Either SqlServerError [Only Int]) `shouldThrowSql` 3998
      shouldEndEarly r
      pure []
  , ExitPath "the body rolls back itself" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        void $ execute conn "ROLLBACK TRANSACTION"
      shouldEndEarly r
      pure []
  , ExitPath "the body commits itself" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        void $ execute conn "COMMIT TRANSACTION"
      shouldEndEarly r
      pure [1]
  , ExitPath "the body replaces the transaction (ROLLBACK; BEGIN TRANSACTION), which is rolled back too" $ \l conn -> do
      r <- try $ withTransactionLevel l conn $ do
        checkInside conn l
        insert conn 1
        _ <- execute conn "ROLLBACK TRANSACTION; BEGIN TRANSACTION"
        insert conn 2
      shouldEndReplaced conn r
      pure []
  ]

-- | Schema @s@ of the run's own in the companion database, which allows
-- SNAPSHOT isolation, with the tables the tests share.  Concurrent runs
-- share the database, so the objects of this one are in its schema.
withSnapshotSchema :: Text -> (ConnectInfo -> IO ()) -> IO ()
withSnapshotSchema s act = do
  ci <- companionConnectInfo
  withSchema ci s $ do
    withConnection ci $ \conn ->
      -- Each table belongs to one test: the tests share the schema and run
      -- at the same time.  (A CREATE TRIGGER on the visible table waited
      -- for a schema lock behind the uncommitted insert of the test that
      -- owns it, and that test's observer queued behind the CREATE
      -- TRIGGER, while the test waited for the observer before committing:
      -- a deadlock through the client, which the server can't see, so the
      -- run hung.)
      void $ execute conn $ rawSql $
        "CREATE TABLE " <> s <> ".visible (i int PRIMARY KEY); \
        \CREATE TABLE " <> s <> ".deadlock (id int PRIMARY KEY, v int); \
        \INSERT INTO " <> s <> ".deadlock VALUES (1, 0), (2, 0); \
        \CREATE TABLE " <> s <> ".lazy_trigger_target (i int)"
    act ci

-- | A connection to the companion database, with an empty @#t@.
withConn :: ConnectInfo -> (Connection -> IO a) -> IO a
withConn ci act = withConnection ci $ \conn -> do
  _ <- execute conn "CREATE TABLE #t (i int PRIMARY KEY)"
  act conn

-- | Afterwards: no transaction, the given level, and a usable connection.
checkAfter :: Connection -> IsolationLevel -> IO ()
checkAfter conn level = do
  tranCount conn `shouldReturn` 0
  inTransaction conn `shouldReturn` False
  sessionLevel conn `shouldReturn` level

-- | The exception is 'ConnectionBroken' whose cause is a 'Timeout'.
isBrokenByTimeout :: SomeException -> Bool
isBrokenByTimeout e = case fromException e of
  Just (ConnectionBroken (reasonCause -> cause)) -> isJust (fromException cause :: Maybe Timeout)
  Nothing -> False

-- | The run's schema in the companion database is named while the tree is
-- built, so that the tests can name its objects.
spec :: Spec
spec = runIO (uniqueName "txn") >>= \s -> aroundAll (withSnapshotSchema s) $ do
  let obj name = s <> "." <> name
  -- Some statements differ under MARS (@HMSSQL_TEST_MARS=1@).
  mars <- runIO testMars
  -- withTransactionLevel doesn't query the previous level: the COMMIT or
  -- cleanup ROLLBACK batch sets READ COMMITTED, the level at login.  Each
  -- test starts from another level set by hand (READ COMMITTED included),
  -- which is not preserved.
  describe "withTransactionLevel sets READ COMMITTED back" $
    forM_ levels $ \l -> describe (show l ++ ", from " ++ show (previousFor l) ++ " set by hand (not preserved)") $ forM_ exitPaths $ \(ExitPath name run) ->
      it ("after " ++ name) $ \ci -> withConn ci $ \conn -> do
        setLevel conn (previousFor l)
        expected <- run l conn
        checkAfter conn ReadCommitted
        rows conn `shouldReturn` expected

  describe "withTransactionLevel" $ do
    it "leaves a fresh connection at READ COMMITTED" $ \ci ->
      forM_ levels $ \l -> withConn ci $ \conn -> do
        withTransactionLevel l conn (checkInside conn l)
        checkAfter conn ReadCommitted

    it "does not preserve a level set by hand: READ COMMITTED afterwards, not the level set before" $ \ci ->
      forM_ levels $ \prev -> withConn ci $ \conn -> do
        setLevel conn prev
        withTransactionLevel Serializable conn (checkInside conn Serializable >> insert conn 1)
        checkAfter conn ReadCommitted
        rows conn `shouldReturn` [1]

    it "sets READ COMMITTED back after losing a deadlock" $ \ci -> withConn ci $ \victim -> withConn ci $ \other -> do
      _ <- execute victim "SET DEADLOCK_PRIORITY LOW"
      setLevel victim Snapshot
      step1 <- newEmptyMVar
      step2 <- newEmptyMVar
      victimOutcome <- newEmptyMVar
      _ <- forkIO $ try (withTransactionLevel Serializable victim $ do
        _ <- execute victim (rawSql ("UPDATE " <> obj "deadlock" <> " SET v = v + 1 WHERE id = 1"))
        putMVar step1 ()
        takeMVar step2
        void $ execute victim (rawSql ("UPDATE " <> obj "deadlock" <> " SET v = v + 1 WHERE id = 2"))) >>= putMVar victimOutcome
      withTransaction other $ do
        _ <- execute other (rawSql ("UPDATE " <> obj "deadlock" <> " SET v = v + 1 WHERE id = 2"))
        takeMVar step1
        putMVar step2 ()
        -- Blocks on the victim's lock until the deadlock monitor (every ~5 s)
        -- picks the victim.
        void $ execute other (rawSql ("UPDATE " <> obj "deadlock" <> " SET v = v + 1 WHERE id = 1"))
      r <- timeout 30_000_000 (takeMVar victimOutcome)
      case r of
        Just res -> res `shouldThrowSql` 1205
        Nothing -> expectationFailure "no deadlock victim"
      -- Not Snapshot, the level set by hand before: READ COMMITTED.
      checkAfter victim ReadCommitted
      query victim (rawSql ("SELECT v FROM " <> obj "deadlock" <> " ORDER BY id")) `shouldReturn` [Only (1 :: Int), Only 1]

    skipOnAzure "ALLOW_SNAPSHOT_ISOLATION is always on" $
      it "sets READ COMMITTED back when SNAPSHOT isn't allowed and the first read fails" $ \_ -> withTestDb $ \conn -> do
      r <- try $ withTransactionLevel Snapshot conn $ do
        sessionLevel conn `shouldReturn` Snapshot
        -- Any user table in a database without ALLOW_SNAPSHOT_ISOLATION.
        query conn (rawSql ("SELECT COUNT(*) FROM " <> fixturesTable)) :: IO [Only Int]
      r `shouldThrowSql` 3952
      checkAfter conn ReadCommitted

    -- An interrupted read cancels the statement and keeps the connection;
    -- the cleanup then rolls back and sets READ COMMITTED.  An interrupted
    -- send breaks the connection (the server rolls back when it is
    -- closed).  So after an interruption at any point, the connection is
    -- either usable, at READ COMMITTED and not in a transaction, or broken
    -- with the interruption as the cause; and a fresh connection finds no
    -- transaction or lock left behind.
    it "after an interruption at any point, is usable and not in a transaction, or broken (ConnectionBroken wrapping the interruption)" $ \ci -> do
      let table = obj "interrupt"
      withConnection ci $ \c -> void $ execute c (rawSql ("CREATE TABLE " <> table <> " (i int PRIMARY KEY)"))
      let ins conn i = void $ execute conn (mkQuery ("INSERT INTO " <> table <> " VALUES (@p1)") (Only i))
      connRef <- newIORef =<< connect ci
      let attempt :: (Connection -> IO () -> IO ()) -> Int -> Int -> IO ()
          attempt txn key delay = do
            conn <- readIORef connRef
            _ <- timeout delay $ txn conn (ins conn key)
            try (tranCount conn) >>= \case
              Right n -> do
                n `shouldBe` 0
                inTransaction conn `shouldReturn` False
                sessionLevel conn `shouldReturn` ReadCommitted
              Left e
                | isBrokenByTimeout e -> do
                    close conn
                    connect ci >>= writeIORef connRef
                | otherwise -> expectationFailure ("after the interruption: " ++ show e)
      flip finally (readIORef connRef >>= close) $ do
        forM_ [0, 150 .. 9000] $ \delay -> attempt (withTransactionLevel Serializable) delay delay
        forM_ [0, 150 .. 6000] $ \delay -> attempt withTransaction (100000 + delay) delay
      withConnection ci $ \fresh -> do
        tranCount fresh `shouldReturn` 0
        -- Blocks (and fails after the lock timeout) if a row lock of an
        -- uncommitted insert is left behind.
        _ <- execute fresh "SET LOCK_TIMEOUT 10000"
        _ <- execute fresh (rawSql ("DELETE FROM " <> table))
        void $ execute fresh (rawSql ("DROP TABLE " <> table))

  describe "withTransaction" $ do
    it "does not change the isolation level" $ \ci -> withConn ci $ \conn -> do
      setLevel conn Serializable
      withTransaction conn (checkInside conn Serializable)
      checkAfter conn Serializable

    it "makes committed rows visible to other connections, and rolled-back rows not" $ \ci ->
      withConn ci $ \conn -> withConn ci $ \observer -> do
        let count sql = fromOnly <$> query1 observer sql :: IO Int
        _ <- execute conn (rawSql ("DELETE FROM " <> obj "visible"))
        withTransaction conn $ do
          _ <- execute conn (rawSql ("INSERT INTO " <> obj "visible" <> " VALUES (1)"))
          count (rawSql ("SELECT COUNT(*) FROM " <> obj "visible" <> " WITH (READPAST)")) `shouldReturn` 0
          count (rawSql ("SELECT COUNT(*) FROM " <> obj "visible" <> " WITH (NOLOCK)")) `shouldReturn` 1
        count (rawSql ("SELECT COUNT(*) FROM " <> obj "visible")) `shouldReturn` 1
        r <- try $ withTransaction conn $ do
          _ <- execute conn (rawSql ("INSERT INTO " <> obj "visible" <> " VALUES (2)"))
          count (rawSql ("SELECT COUNT(*) FROM " <> obj "visible" <> " WITH (NOLOCK)")) `shouldReturn` 2
          throwIO (userError "roll back")
        either (\(_ :: IOException) -> pure ()) (\() -> expectationFailure "committed") r
        count (rawSql ("SELECT COUNT(*) FROM " <> obj "visible")) `shouldReturn` 1

    -- The transaction's identity is checked before COMMIT: another one in
    -- its place is not committed.
    it (if mars
          then "throws the batch's error 3997 when the body replaces the transaction (ROLLBACK TRANSACTION; BEGIN TRANSACTION): under MARS the server rolls the new one back; nothing is committed"
          else "throws TransactionEndedEarly when the body replaces the transaction (ROLLBACK TRANSACTION; BEGIN TRANSACTION), committing nothing") $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ do
        insert conn 1
        _ <- execute conn "ROLLBACK TRANSACTION; BEGIN TRANSACTION"
        insert conn 2
        tranCount conn `shouldReturn` 1
      shouldEndReplaced conn r
      tranCount conn `shouldReturn` 0
      inTransaction conn `shouldReturn` False
      rows conn `shouldReturn` []
      -- The connection is fine for the next transaction.
      withTransaction conn (insert conn 3)
      rows conn `shouldReturn` [3]

    it "throws TransactionEndedEarly when the body replaces the transaction in two requests, committing nothing" $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ do
        insert conn 1
        rollback conn
        begin conn
        insert conn 2
      shouldEndEarly r
      tranCount conn `shouldReturn` 0
      inTransaction conn `shouldReturn` False
      rows conn `shouldReturn` []

    -- The timeout must land while the rows stream in, so the result must
    -- take far longer than 200 ms to read.  2,000,000 rows took 1.1 s
    -- before ff2a674 (rows a packet at a time), then 0.19 s: the timeout
    -- could land on the COMMIT (which may then commit) or after the end.
    -- 100,000,000 rows take about 10 s.
    it "leaves the connection usable after an async exception during a stream" $ \ci -> withConn ci $ \conn -> do
      r <- timeout 200_000 $ withTransaction conn $ do
        insert conn 1
        void (query conn "SELECT TOP 100000000 1 FROM sys.all_columns a CROSS JOIN sys.all_columns b" :: IO [Only Int])
      isJust r `shouldBe` False
      tranCount conn `shouldReturn` 0
      rows conn `shouldReturn` []

  describe "nesting" $ do
    it "refuses a nested withTransaction, leaving the outer transaction intact" $ \ci -> withConn ci $ \conn -> do
      withTransaction conn $ do
        insert conn 1
        r <- try (withTransaction conn (insert conn 2))
        case r of
          Left TransactionAlreadyActive -> pure ()
          other -> expectationFailure ("inner: " ++ show other)
        tranCount conn `shouldReturn` 1
        insert conn 3
      rows conn `shouldReturn` [1, 3]
      tranCount conn `shouldReturn` 0

    it "refuses a nested withTransactionLevel, leaving the outer level intact (READ COMMITTED afterwards)" $ \ci -> withConn ci $ \conn -> do
      setLevel conn RepeatableRead
      withTransactionLevel Serializable conn $ do
        r <- try (withTransactionLevel ReadUncommitted conn (insert conn 2))
        case r of
          Left TransactionAlreadyActive -> pure ()
          other -> expectationFailure ("inner: " ++ show other)
        checkInside conn Serializable
      -- Not REPEATABLE READ, the level set by hand before.
      checkAfter conn ReadCommitted
      rows conn `shouldReturn` []

    it "rolls back the outer transaction when the refusal propagates" $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ do
        insert conn 1
        withTransaction conn (insert conn 2)
      case r of
        Left TransactionAlreadyActive -> pure ()
        other -> expectationFailure (show other)
      checkAfter conn ReadCommitted
      rows conn `shouldReturn` []

    it "refuses to start inside a transaction begun by hand, and leaves it alone" $ \ci -> withConn ci $ \conn -> do
      begin conn
      insert conn 1
      r <- try (withTransactionLevel Serializable conn (insert conn 2))
      case r of
        Left TransactionAlreadyActive -> pure ()
        other -> expectationFailure (show other)
      tranCount conn `shouldReturn` 1
      sessionLevel conn `shouldReturn` ReadCommitted
      commit conn
      rows conn `shouldReturn` [1]

    -- Model.Connection found it: the inner one's BEGIN bookkeeping
    -- replaced the outer one's, which then committed the transaction the
    -- body began by hand.
    it "keeps an outer transaction's identity across an inner withTransaction started after it ended" $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ do
        insert conn 1
        commit conn
        withTransaction conn (pure ())
        withTransaction conn (insert conn 2)
        begin conn
        insert conn 3
      shouldEndEarly r
      checkAfter conn ReadCommitted
      rows conn `shouldReturn` [1, 2]

    it "allows sequential transactions" $ \ci -> withConn ci $ \conn -> do
      forM_ [1 .. 3] $ \i -> withTransactionLevel Serializable conn (insert conn i)
      forM_ [4 .. 6] $ \i -> withTransaction conn (insert conn i)
      rows conn `shouldReturn` [1 .. 6]
      checkAfter conn ReadCommitted

  -- The begin is a Transaction Manager request of its own, sent and read
  -- before the body runs (Mutation.Transaction shows the messages).
  describe "the begin sent before the body" $ do
    it "has begun the transaction before the body's first request, and commits it when the body makes none" $ \ci -> withConn ci $ \conn -> do
      withTransaction conn (inTransaction conn `shouldReturn` True)
      withTransactionLevel Serializable conn $ do
        inTransaction conn `shouldReturn` True
        tranCount conn `shouldReturn` 1
        sessionLevel conn `shouldReturn` Serializable
      checkAfter conn ReadCommitted

    it "rolls back when the body's first batch doesn't compile" $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ execute conn "INSERT INTO #t VALUES (1); SELEC 1"
      either sqlErrorNumber (const 0) r `shouldBe` 102
      rows conn `shouldReturn` []
      checkAfter conn ReadCommitted

    it "keeps the transaction when the body catches a batch that doesn't compile" $ \ci -> withConn ci $ \conn -> do
      withTransaction conn $ do
        r <- try (execute conn "INSERT INTO #t VALUES (2); SELEC 1")
        either sqlErrorNumber (const 0) r `shouldBe` 102
        insert conn 1
        tranCount conn `shouldReturn` 1
      rows conn `shouldReturn` [1]
      checkAfter conn ReadCommitted

    -- The next request's Attention can cancel the abandoned stream's batch
    -- before it runs (a few times in a thousand, locally); the begin went
    -- before it, in a request of its own read to its end.
    -- Under MARS the next request leaves the stream alone, and a stream
    -- left unread blocks the commit: withTransaction throws
    -- TransactionRequestsActive naming it, and rolls back.
    it "has begun the transaction whatever becomes of a first stream abandoned at once (300 times)" $ \ci -> withConn ci $ \conn ->
      forM_ [1 .. 300 :: Int] $ \i -> do
        r <- try $ withTransaction conn $ do
          _ <- queryS conn "SELECT 1" :: IO (Stream (Of (Only Int)) IO ())
          insert conn i
          tranCount conn `shouldReturn` 1
        case r of
          Right () | not mars -> pure ()
          Left (TransactionRequestsActive ["SELECT 1"]) | mars -> pure ()
          other -> expectationFailure ("withTransaction: " ++ show other)
        tranCount conn `shouldReturn` 0
        when mars $ rows conn `shouldReturn` []

    it "sets the isolation level back after a first stream abandoned at once, however the body ends (300 times)" $ \ci -> withConn ci $ \conn ->
      forM_ [1 .. 300 :: Int] $ \i -> do
        r <- try $ withTransactionLevel Serializable conn $ do
          _ <- queryS conn "SELECT 1" :: IO (Stream (Of (Only Int)) IO ())
          when (odd i) $ throwIO (userError "body failed")
        case r of
          Left (e :: SomeException) | odd i -> show e `shouldContain` "body failed"
          Left e | mars, Just (TransactionRequestsActive ["SELECT 1"]) <- fromException e -> pure ()
          Left e -> expectationFailure ("threw " ++ show e)
          Right () | odd i -> expectationFailure "the body's exception was lost"
          Right () | mars -> expectationFailure "committed beside the unread stream"
          Right () -> pure ()
        checkAfter conn ReadCommitted

    it "leaves the transaction open after a runtime error in the first batch" $ \ci -> withConn ci $ \conn -> do
      withTransaction conn $ do
        r <- try (execute conn "INSERT INTO #t VALUES (1); SELECT 1/0")
        either sqlErrorNumber (const 0) r `shouldBe` 8134
        tranCount conn `shouldReturn` 1
      rows conn `shouldReturn` [1]

    it "sets the isolation level in the begin request, and back at the end" $ \ci -> withConn ci $ \conn -> do
      withTransactionLevel Serializable conn $ do
        sessionLevel conn `shouldReturn` Serializable
        tranCount conn `shouldReturn` 1
      checkAfter conn ReadCommitted

    it "is in place before a first RPC" $ \ci -> withConn ci $ \conn -> do
      withTransactionLevel RepeatableRead conn $ do
        n <- query1 conn ("SELECT @@TRANCOUNT + " <> param (0 :: Int))
        n `shouldBe` Only (1 :: Int)
        sessionLevel conn `shouldReturn` RepeatableRead
      checkAfter conn ReadCommitted

    it "is rolled back by a reset before the body's first request (TransactionEndedEarly)" $ \ci -> withConn ci $ \conn -> do
      r <- try $ withTransaction conn $ do
        reset conn
        -- Pending: nothing has been sent yet.
        inTransaction conn `shouldReturn` True
        -- The request carries the reset, which rolls the transaction back.
        tranCount conn `shouldReturn` 0
        inTransaction conn `shouldReturn` False
      shouldEndEarly r
      checkAfter conn ReadCommitted

    -- Each must be the first statement of its batch (error 111), which
    -- it is, the begin being a request of its own.  The body throws, so
    -- what it made is rolled back.
    forM_
      [ ("CREATE PROCEDURE", "CREATE PROCEDURE " <> obj "lazy_p" <> " AS SELECT 1", obj "lazy_p")
      , ("CREATE OR ALTER PROCEDURE", "CREATE OR ALTER PROC " <> obj "lazy_p2" <> " AS SELECT 1", obj "lazy_p2")
      , ("CREATE VIEW", "/* a view */ CREATE VIEW " <> obj "lazy_v" <> " AS SELECT 1 AS x", obj "lazy_v")
      , ("CREATE FUNCTION", "CREATE FUNCTION " <> obj "lazy_f" <> "() RETURNS int AS BEGIN RETURN 1 END", obj "lazy_f")
      , ("CREATE TRIGGER", "CREATE TRIGGER " <> obj "lazy_t" <> " ON " <> obj "lazy_trigger_target" <> " AFTER INSERT AS SELECT 1", obj "lazy_t")
      , ("CREATE SCHEMA", "CREATE SCHEMA " <> s <> "_lazy", "")
      , ("CREATE DEFAULT", "CREATE DEFAULT " <> obj "lazy_d" <> " AS 1", obj "lazy_d")
      , ("CREATE RULE", "CREATE RULE " <> obj "lazy_r" <> " AS @x > 0", obj "lazy_r")
      ] $ \(label, sql, object) ->
      it ("lets the body start with " ++ label) $ \ci -> withConn ci $ \conn -> do
        r <- try $ withTransaction conn $ do
          _ <- execute conn (rawSql sql)
          tranCount conn `shouldReturn` 1
          throwIO (userError "roll back")
        either (\(e :: IOException) -> show e `shouldContain` "roll back") (\() -> expectationFailure "committed") r
        checkAfter conn ReadCommitted
        let exists = if T.null object
              then "SELECT CAST(COUNT(*) AS int) FROM sys.schemas WHERE name = " <> param (s <> "_lazy")
              else "SELECT CAST(CASE WHEN OBJECT_ID(" <> param object <> ") IS NULL THEN 0 ELSE 1 END AS int)"
        query1 conn exists `shouldReturn` Only (0 :: Int)

    it "lets the body start with ALTER PROCEDURE" $ \ci -> withConn ci $ \conn -> do
      _ <- execute conn (rawSql ("CREATE OR ALTER PROCEDURE " <> obj "lazy_alter" <> " AS SELECT 1 AS x"))
      withTransaction conn $ void (execute conn (rawSql ("ALTER PROCEDURE " <> obj "lazy_alter" <> " AS SELECT 2 AS x")))
      queryMulti conn (rawSql ("EXEC " <> obj "lazy_alter")) >>= \sets ->
        map (map sqlRowValues . resultRows) sets `shouldBe` [[[SqlInt32 2]]]
      void $ execute conn (rawSql ("DROP PROCEDURE " <> obj "lazy_alter"))
