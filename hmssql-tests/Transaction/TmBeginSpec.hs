-- | The begin of a transaction is a Transaction Manager request
-- (TM_BEGIN_XACT), not a @BEGIN TRANSACTION@ batch: 'begin',
-- 'withTransaction' and 'withTransactionLevel' send one message of type
-- 0x0E with ALL_HEADERS, request type 5, the isolation level's byte and an
-- empty name (mock server), which carries a pending reset like any
-- request; and on a real server it does what @BEGIN TRANSACTION@ (and
-- @SET TRANSACTION ISOLATION LEVEL@) did: a transaction is open, at the
-- level asked for, which is in force, and READ COMMITTED after it however
-- it ends.
module Transaction.TmBeginSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
import Control.Monad (forM_, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int16)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word64, Word8)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (batchText, tmBeginLevel)
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Errors
import Hmssql.Query (batchRequest, callProcedure, startResponse)
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (ServerMessage (..))
import Hmssql.Transaction
import MockServer
import TestDb

------------------------------------------------------------------------------
-- Mock server

-- | A message the client sent: its type, whether it carried the
-- RESETCONNECTION bit, and its body.
type Sent = (PacketType, Bool, B.ByteString)

-- | Log in, then answer as SQL Server does, as far as these tests go: a
-- request carrying the RESETCONNECTION bit gets the reset acknowledgement
-- (which ends any transaction); TM_BEGIN_XACT begins a transaction with
-- the next descriptor (1, 2, ...), or nests the open one (no ENVCHANGE); a
-- COMMIT ends the outermost one, the conditional ROLLBACK any; and every
-- request gets a final DONE.  Returns every message, until the client
-- closes the connection.
tmServer :: MockConn -> IO [Sent]
tmServer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let ended ty d = envChangeToken ty (LB.toStrict (Put.runPut (Put.putWord8 0 >> Put.putWord8 8 >> Put.putWord64le d)))
      -- The open transaction (its descriptor and nesting), the next free
      -- descriptor, and the messages so far.
      loop :: Maybe (Word64, Int) -> Word64 -> [Sent] -> IO [Sent]
      loop open0 next sent = recvMessageWithReset mc >>= \case
        Nothing -> pure (reverse sent)
        Just m@(ptype, resetting, body) -> do
          let open = if resetting then Nothing else open0
              acked = [resetConnectionEnvChange | resetting]
              answer toks open' next' = do
                sendTokens mc (acked ++ toks ++ [doneToken 0 0])
                loop open' next' (m : sent)
          case ptype of
            PTTransactionManager | Just _ <- tmBeginLevel body -> case open of
              Nothing -> answer [beginTransactionEnvChange next] (Just (next, 1)) (next + 1)
              Just (d, n) -> answer [] (Just (d, n + 1)) next
            PTSqlBatch -> case (batchText body, open) of
              (sql, Just (d, n)) | "COMMIT TRANSACTION" `T.isPrefixOf` sql ->
                if n > 1 then answer [] (Just (d, n - 1)) next else answer [ended 9 d] Nothing next
              (sql, Just (d, _)) | "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION" `T.isPrefixOf` sql ->
                answer [ended 10 d] Nothing next
              _ -> answer [] open next
            -- The response it cancels has been sent in full: only the
            -- acknowledgement.
            PTAttention -> do
              sendTokens mc [doneToken 0x0020 0]
              loop open next (m : sent)
            _ -> throwIO (MockUnexpected ("unexpected " ++ show ptype))
  loop Nothing 1 []

-- | Log in, then fail every TM_BEGIN_XACT with an ERROR token (3995, as
-- SQL Server answers an isolation-level byte it doesn't know) and answer
-- anything else with a final DONE.
failingBegin :: MockConn -> IO ()
failingBegin mc = do
  _ <- serveLogin defaultLoginResponse mc
  serveRequests answer mc
  where
    answer PTTransactionManager _ = pure [errorToken beginError, doneToken 0x0002 0]
    answer _ _ = pure [doneToken 0 0]
    beginError = ServerMessage
      { msgNumber = 3995, msgState = 1, msgClass = 16
      , msgText = "Unknown isolation level 0x0 requested for begin transaction."
      , msgServer = "mock", msgProcedure = "", msgLine = 1 }

-- | The messages the client sends for the action, on a connection with
-- the given session setup (after the setup batch 'connect' sends, if any).
sentBy :: [Text] -> (Connection -> IO ()) -> IO [Sent]
sentBy setup act = withMockServer tmServer $ \srv -> do
  within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = setup } act
  nextResult srv >>= either (\e -> throwIO (userError ("mock: " ++ show e))) (pure . drop (if null setup then 0 else 1))

-- | ALL_HEADERS as MS-TDS 2.2.5.3 has it: total length 22, and one
-- transaction descriptor header of 18 bytes (type 2) with the descriptor
-- (0 outside a transaction) and an outstanding request count of 1.
allHeaders :: Word64 -> Put.Put
allHeaders descriptor = do
  Put.putWord32le 22
  Put.putWord32le 18
  Put.putWord16le 2
  Put.putWord64le descriptor
  Put.putWord32le 1

-- | A TM_BEGIN_XACT body (MS-TDS 2.2.6.9): ALL_HEADERS, the request type
-- (5, a USHORT), the isolation level (a BYTE) and the transaction name (a
-- B_VARCHAR, empty).
tmBeginBody :: Word64 -> Word8 -> B.ByteString
tmBeginBody descriptor lvl = LB.toStrict $ Put.runPut $ do
  allHeaders descriptor
  Put.putWord16le 5
  Put.putWord8 lvl
  Put.putWord8 0

-- | A SQL batch body: ALL_HEADERS, then the text in UTF-16LE.
sqlBody :: Word64 -> Text -> B.ByteString
sqlBody descriptor sql = LB.toStrict (Put.runPut (allHeaders descriptor)) <> T.encodeUtf16LE sql

-- | The isolation-level byte of each level (MS-TDS 2.2.6.9).
levelBytes :: [(IsolationLevel, Word8)]
levelBytes = [(ReadUncommitted, 1), (ReadCommitted, 2), (RepeatableRead, 3), (Serializable, 4), (Snapshot, 5)]

-- | Every way to begin a transaction, with the level byte it sends.
begins :: [(String, Connection -> IO (), Word8)]
begins =
  [ ("begin", begin, 0)
  , ("withTransaction", \conn -> withTransaction conn (pure ()), 0) ]
  ++ [ ("withTransactionLevel " ++ show l, \conn -> withTransactionLevel l conn (pure ()), b) | (l, b) <- levelBytes ]

typeAndReset :: Sent -> (PacketType, Bool)
typeAndReset (ptype, resetting, _) = (ptype, resetting)

------------------------------------------------------------------------------
-- Live server

tranCount :: Connection -> IO Int
tranCount conn = fromOnly <$> query1 conn "SELECT @@TRANCOUNT"

-- | The session's isolation level, as the server reports it.
sessionLevel :: Connection -> IO IsolationLevel
sessionLevel conn = do
  Only (n :: Int16) <- query1 conn "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID"
  maybe (fail ("unexpected transaction_isolation_level " ++ show n)) pure (lookup (fromIntegral n) [(b, l) | (l, b) <- levelBytes])

levelSql :: IsolationLevel -> Text
levelSql = \case
  ReadUncommitted -> "READ UNCOMMITTED"
  ReadCommitted -> "READ COMMITTED"
  RepeatableRead -> "REPEATABLE READ"
  Snapshot -> "SNAPSHOT"
  Serializable -> "SERIALIZABLE"

-- | The companion database, which allows SNAPSHOT isolation.  The tables
-- the tests create there have unique names ('withTable').
withSnapshotDatabase :: (ConnectInfo -> IO ()) -> IO ()
withSnapshotDatabase act = companionConnectInfo >>= act

-- | A connection to the database, with an empty @#t (i int PRIMARY KEY)@.
withConn :: ConnectInfo -> (Connection -> IO a) -> IO a
withConn ci act = withConnection ci $ \conn -> do
  _ <- execute conn "CREATE TABLE #t (i int PRIMARY KEY)"
  act conn

-- | A table of its own in the database, @(i int PRIMARY KEY)@, for what
-- another connection sees.
withTable :: ConnectInfo -> (Text -> IO a) -> IO a
withTable ci act = do
  t <- ("dbo." <>) <$> uniqueName "tm_begin"
  withConnection ci $ \conn -> void $ execute conn (rawSql ("CREATE TABLE " <> t <> " (i int PRIMARY KEY)"))
  act t `finally` withConnection ci (\conn -> void $ execute conn (rawSql ("DROP TABLE IF EXISTS " <> t)))

rows :: Connection -> IO [Int]
rows conn = map fromOnly <$> query conn "SELECT i FROM #t ORDER BY i"

insert :: Connection -> Int -> IO ()
insert conn i = void $ execute conn ("INSERT INTO #t VALUES (" <> param i <> ")")

insertInto :: Connection -> Text -> Int -> IO ()
insertInto conn t i = void $ execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only i))

countOf :: Connection -> Text -> IO Int
countOf conn t = fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t))

-- | Inside a transaction begun by the request: open, not nested, at the level.
checkInside :: Connection -> IsolationLevel -> IO ()
checkInside conn l = do
  inTransaction conn `shouldReturn` True
  tranCount conn `shouldReturn` 1
  sessionLevel conn `shouldReturn` l

checkAfter :: Connection -> IsolationLevel -> IO ()
checkAfter conn l = do
  inTransaction conn `shouldReturn` False
  tranCount conn `shouldReturn` 0
  sessionLevel conn `shouldReturn` l

-- | The request fails with this SQL Server error.
failsWith :: IO a -> Int -> IO ()
failsWith act n = try act >>= \case
  Left (e :: SqlServerError) -> fromIntegral (sqlErrorNumber e) `shouldBe` n
  Right _ -> expectationFailure ("expected SQL error " ++ show n)

------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "the begin request (mock server)" $ do
    forM_ begins $ \(label, act, lvl) ->
      it (label ++ " sends one Transaction Manager message: ALL_HEADERS, TM_BEGIN_XACT, level byte " ++ show lvl ++ ", an empty name") $
        sentBy [] act >>= \case
          (PTTransactionManager, False, body) : _ -> body `shouldBe` tmBeginBody 0 lvl
          other -> expectationFailure ("sent " ++ show (map typeAndReset (take 1 other)))

    it "inside a transaction carries its descriptor in ALL_HEADERS, as any request does (begin twice)" $
      sentBy [] (\conn -> begin conn >> begin conn >> (inTransaction conn `shouldReturn` True)) >>= \case
        [(PTTransactionManager, _, first), (PTTransactionManager, _, second)] -> do
          first `shouldBe` tmBeginBody 0 0
          second `shouldBe` tmBeginBody 1 0
        other -> expectationFailure ("sent " ++ show (map typeAndReset other))

    it "goes before the body's first request, which carries the transaction it began, as the COMMIT does" $
      sentBy [] (\conn -> withTransactionLevel Serializable conn (void (execute conn "SELECT 1")))
        >>= (`shouldBe` [ (PTTransactionManager, False, tmBeginBody 0 4)
                        , (PTSqlBatch, False, sqlBody 1 "SELECT 1")
                        , (PTSqlBatch, False, sqlBody 1 "COMMIT TRANSACTION; SET TRANSACTION ISOLATION LEVEL READ COMMITTED") ])

    -- The reset rides on the begin request itself, or on the session setup
    -- batch before it; either way the transaction begins after the reset.
    forM_ [("begin", begin), ("withTransaction", \conn -> withTransaction conn (pure ()))] $ \(label, act) -> do
      it (label ++ " after reset, without a session setup: the begin request carries the RESETCONNECTION bit") $
        sentBy [] (\conn -> reset conn >> act conn)
          >>= (`shouldSatisfy` \case
                (PTTransactionManager, True, body) : _ -> body == tmBeginBody 0 0
                _ -> False)
      it (label ++ " after reset, with a session setup: the setup batch carries the bit, the begin request doesn't") $
        map typeAndReset . take 2 <$> sentBy ["SET ARITHABORT ON"] (\conn -> reset conn >> act conn)
          `shouldReturn` [(PTSqlBatch, True), (PTTransactionManager, False)]

    -- G46: the descriptor a request carries is read with the lock held,
    -- after what precedes the request (here, the drain of the response it
    -- abandons, whose ENVCHANGE ends the transaction); one read earlier
    -- would be stale, and the server fails a request carrying a
    -- descriptor that has ended (3971).
    it "carries the descriptor as it is after the drain of an unread response that ended the transaction" $
      sentBy [] (\conn -> do
        begin conn
        _ <- startResponse conn (batchRequest "COMMIT TRANSACTION")
        inTransaction conn `shouldReturn` True
        _ <- execute conn "SELECT 1"
        inTransaction conn `shouldReturn` False)
        >>= \case
          [(PTTransactionManager, _, _), (PTSqlBatch, _, commit), (PTAttention, _, _), (PTSqlBatch, _, select)] -> do
            commit `shouldBe` sqlBody 1 "COMMIT TRANSACTION"
            select `shouldBe` sqlBody 0 "SELECT 1"
          other -> expectationFailure ("sent " ++ show (map typeAndReset other))

    -- R31: the begin is a TM request, which has no SQL text of its own; a
    -- failed one names the statement it stands for.
    forM_ [("begin", begin), ("withTransactionLevel Serializable", \conn -> withTransactionLevel Serializable conn (pure ()))] $ \(label, act) ->
      it (label ++ ": a begin the server fails throws SqlServerError naming BEGIN TRANSACTION, and no transaction is open") $
        withMockServer failingBegin $ \srv -> within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = [] } $ \conn -> do
          try (act conn) >>= \case
            Left (e :: SqlServerError) -> do
              sqlErrorNumber e `shouldBe` 3995
              sqlErrorStatement e `shouldBe` Just "BEGIN TRANSACTION"
            Right () -> expectationFailure "the begin succeeded"
          inTransaction conn `shouldReturn` False

    it "after reset inside a transaction begun by hand (begin): the second begin request carries the bit" $
      sentBy [] (\conn -> do
        begin conn
        reset conn
        begin conn
        inTransaction conn `shouldReturn` True)
        >>= \case
          [(PTTransactionManager, False, first), (PTTransactionManager, True, second)] -> do
            tmBeginLevel first `shouldBe` Just 0
            tmBeginLevel second `shouldBe` Just 0
          other -> expectationFailure ("sent " ++ show (map typeAndReset other))

  aroundAll withSnapshotDatabase $ describe "the begin request (live server)" $ do
    it "begin begins a transaction as BEGIN TRANSACTION does, and rollback rolls it back" $ \ci -> withConn ci $ \conn -> do
      begin conn
      checkInside conn ReadCommitted
      Only (1 :: Int) <- query1 conn "SELECT XACT_STATE()"
      insert conn 1
      rollback conn
      checkAfter conn ReadCommitted
      rows conn `shouldReturn` []

    it "begin then commit commits, for another connection to see" $ \ci -> withTable ci $ \t ->
      withConnection ci $ \conn -> withConnection ci $ \other -> do
        begin conn
        insertInto conn t 1
        countOf other ("(SELECT * FROM " <> t <> " WITH (READPAST)) AS x") `shouldReturn` 0
        commit conn
        checkAfter conn ReadCommitted
        countOf other t `shouldReturn` 1

    it "begin inside a transaction nests it, as BEGIN TRANSACTION does (@@TRANCOUNT 2)" $ \ci -> withConn ci $ \conn -> do
      begin conn
      insert conn 1
      begin conn
      tranCount conn `shouldReturn` 2
      insert conn 2
      commit conn
      tranCount conn `shouldReturn` 1
      inTransaction conn `shouldReturn` True
      commit conn
      checkAfter conn ReadCommitted
      rows conn `shouldReturn` [1, 2]

    it "begin keeps the session's isolation level (level byte 0)" $ \ci -> withConn ci $ \conn ->
      forM_ (map fst levelBytes) $ \l -> do
        _ <- execute conn (rawSql ("SET TRANSACTION ISOLATION LEVEL " <> levelSql l))
        begin conn
        checkInside conn l
        commit conn
        checkAfter conn l

    it "a pending reset rides on the begin request (or the setup batch before it): the session is reset, then the transaction begins" $ \ci -> withConn ci $ \conn -> do
      _ <- execute conn "SET LOCK_TIMEOUT 1234"
      reset conn
      begin conn
      tranCount conn `shouldReturn` 1
      inTransaction conn `shouldReturn` True
      -- Reset: #t is gone, LOCK_TIMEOUT is back to its default.
      query1 conn "SELECT CASE WHEN OBJECT_ID(N'tempdb..#t') IS NULL THEN 1 ELSE 0 END, @@LOCK_TIMEOUT"
        `shouldReturn` (1 :: Int, -1 :: Int)
      rollback conn
      checkAfter conn ReadCommitted

    it "a pending reset inside a transaction begun by hand rides on the next begin request: that transaction is rolled back, and a new one begins" $ \ci -> withTable ci $ \t ->
      withConnection ci $ \conn -> withConnection ci $ \other -> do
        begin conn
        insertInto conn t 1
        reset conn
        begin conn
        checkInside conn ReadCommitted
        insertInto conn t 2
        commit conn
        checkAfter conn ReadCommitted
        map fromOnly <$> query other (rawSql ("SELECT i FROM " <> t)) `shouldReturn` [2 :: Int]

    -- Right after sp_reset_connection (which sets READ COMMITTED), a
    -- request carrying the RESETCONNECTION bit brings back the level from
    -- before it (SQL Server 2025; Model.Machine's mSpResetLevel).  The
    -- begin request carrying the bit does as a batch carrying it does.
    it "a pending reset right after sp_reset_connection leaves the level as a batch carrying it would" $ \ci -> do
      let levelAfterReset first = withConnection ci $ \conn -> do
            _ <- execute conn "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
            _ <- callProcedure conn "sp_reset_connection" []
            reset conn
            first conn
            l <- sessionLevel conn
            rollback conn
            pure l
      viaBatch <- levelAfterReset (\conn -> void (execute conn "SELECT 1"))
      viaBegin <- levelAfterReset begin
      viaBegin `shouldBe` viaBatch

    forM_ levelBytes $ \(l, _) -> describe ("withTransactionLevel " ++ show l) $ do
      it "is at that level inside, in a transaction, and at READ COMMITTED after the COMMIT" $ \ci -> withConn ci $ \conn -> do
        withTransactionLevel l conn (checkInside conn l >> insert conn 1)
        checkAfter conn ReadCommitted
        rows conn `shouldReturn` [1]
      it "is at READ COMMITTED after the rollback" $ \ci -> withConn ci $ \conn -> do
        r <- try $ withTransactionLevel l conn (checkInside conn l >> insert conn 1 >> throwIO (userError "roll back"))
        either (\(e :: IOException) -> show e `shouldContain` "roll back") (\() -> expectationFailure "committed") r
        checkAfter conn ReadCommitted
        rows conn `shouldReturn` []

    -- The level the begin request sets is the one the transaction runs at,
    -- not only the one the session reports.
    describe "the level set by the begin request is in force" $ do
      it "SNAPSHOT: the transaction reads the table as of its first read, not another connection's later commit" $ \ci -> withTable ci $ \t ->
        withConnection ci $ \conn -> withConnection ci $ \other -> do
          insertInto other t 1
          withTransactionLevel Snapshot conn $ do
            countOf conn t `shouldReturn` 1
            insertInto other t 2
            countOf conn t `shouldReturn` 1
          countOf conn t `shouldReturn` 2

      it "READ UNCOMMITTED: the transaction reads another connection's uncommitted row" $ \ci -> withTable ci $ \t ->
        withConnection ci $ \conn -> withConnection ci $ \other -> do
          begin other
          insertInto other t 1
          withTransactionLevel ReadUncommitted conn $ countOf conn t `shouldReturn` 1
          rollback other
          countOf conn t `shouldReturn` 0

      it "REPEATABLE READ: a row the transaction read can't be updated by another connection until it ends" $ \ci -> withTable ci $ \t ->
        withConnection ci $ \conn -> withConnection ci $ \other -> do
          insertInto other t 1
          _ <- execute other "SET LOCK_TIMEOUT 0"
          withTransactionLevel RepeatableRead conn $ do
            countOf conn t `shouldReturn` 1
            execute other (rawSql ("UPDATE " <> t <> " SET i = 2")) `failsWith` 1222
          execute other (rawSql ("UPDATE " <> t <> " SET i = 2")) `shouldReturn` 1

      it "SERIALIZABLE: another connection can't insert into a range the transaction read until it ends" $ \ci -> withTable ci $ \t ->
        withConnection ci $ \conn -> withConnection ci $ \other -> do
          _ <- execute other "SET LOCK_TIMEOUT 0"
          withTransactionLevel Serializable conn $ do
            countOf conn t `shouldReturn` 0
            insertInto other t 1 `failsWith` 1222
          insertInto other t 1
          countOf conn t `shouldReturn` 1

      it "READ COMMITTED: the transaction doesn't read another connection's uncommitted row (it waits for it, or under RCSI reads the committed version)" $ \ci -> withTable ci $ \t ->
        withConnection ci $ \conn -> withConnection ci $ \other -> do
          -- From READ UNCOMMITTED set by hand, which would read the row.
          _ <- execute conn "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"
          -- READ_COMMITTED_SNAPSHOT is on in an Azure SQL database.
          Only rcsi <- query1 conn "SELECT CAST(is_read_committed_snapshot_on AS bit) FROM sys.databases WHERE name = DB_NAME()"
          begin other
          insertInto other t 1
          _ <- execute conn "SET LOCK_TIMEOUT 0"
          withTransactionLevel ReadCommitted conn $
            if rcsi
              then countOf conn t `shouldReturn` 0
              else countOf conn t `failsWith` 1222
          rollback other
          countOf conn t `shouldReturn` 0

    it "a transaction begun by withTransactionLevel blocks another connection's writes until it commits" $ \ci -> withTable ci $ \t ->
      withConnection ci $ \conn -> withConnection ci $ \other -> do
        inside <- newEmptyMVar
        release' <- newEmptyMVar
        done <- newEmptyMVar
        _ <- forkIO $ try (withTransactionLevel Serializable conn $ do
          insertInto conn t 1
          putMVar inside ()
          takeMVar release') >>= putMVar done
        within 30 (takeMVar inside)
        _ <- execute other "SET LOCK_TIMEOUT 0"
        insertInto other t 1 `failsWith` 1222
        putMVar release' ()
        within 30 (takeMVar done) >>= \case
          Right () -> pure ()
          Left (e :: SomeException) -> expectationFailure ("withTransactionLevel: " ++ show e)
        -- Committed: the key is taken.
        insertInto other t 1 `failsWith` 2627
