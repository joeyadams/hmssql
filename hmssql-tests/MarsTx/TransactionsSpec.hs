-- | Transactions on a MARS connection (docs/dev/mars-research.md, "Transactions",
-- A24-A28): a @BEGIN TRANSACTION@ batch is refused (3997) and the library
-- begins with a Transaction Manager request instead; the transaction is
-- the connection's, seen by every session, and committed or rolled back
-- from any; with no session busy a commit or a begin is never refused;
-- what the server does when one is (3981, 3988), which the library's
-- check prevents; 'TransactionStillOpen'; the isolation level of
-- 'withTransactionLevel' on every session; and failures inside the body
-- that leave no response open.
module MarsTx.TransactionsSpec (spec) where

import Hmssql.Query (bytesBody)
import Control.Exception
import Control.Monad (forM_, when)
import Data.Int (Int16)
import Data.IORef
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Query.Types (Request (..))
import Hmssql.Tds.Client (tmBeginTransactionBody)
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (ServerMessage (..))
import Hmssql.Transaction
import MarsTx.Harness
import TestDb

-- | The isolation level and @\@\@TRANCOUNT@ as one request sees them.
levelAndCountSql :: Text
levelAndCountSql =
  "SELECT s.transaction_isolation_level, @@TRANCOUNT FROM sys.dm_exec_sessions s WHERE s.session_id = @@SPID"

levelByte :: IsolationLevel -> Int16
levelByte = \case
  ReadUncommitted -> 1
  ReadCommitted -> 2
  RepeatableRead -> 3
  Serializable -> 4
  Snapshot -> 5

-- | Three requests open at once, each on its own session, each reading
-- the isolation level and @\@\@TRANCOUNT@: what every session sees.
seenBySessions :: Connection -> IO [(Int16, Int)]
seenBySessions conn =
  withQueryS conn (rawSql levelAndCountSql) $ \s0 ->
    withQueryS conn (rawSql levelAndCountSql) $ \s1 ->
      withQueryS conn (rawSql levelAndCountSql) $ \s2 -> do
        length <$> busySids conn `shouldReturn` 3
        concat <$> mapM S.toList_ [s0, s1, s2 :: Stream (Of (Int16, Int)) IO ()]

-- | A TM_BEGIN_XACT request, as 'begin' sends it, for the raw
-- request layer (no check of the other sessions).
rawTmBegin :: Request
rawTmBegin = Request PTTransactionManager (bytesBody (\ctx -> tmBeginTransactionBody ctx 0)) (Just "TM_BEGIN_XACT")

spec :: Spec
spec = do
  describe "A24: a BEGIN TRANSACTION batch under MARS" $ do
    it "fails with error 3997, and leaves no transaction open" $ withMarsConn $ \conn -> do
      execute conn "BEGIN TRANSACTION" `failsWithSql` 3997
      inTransaction conn `shouldReturn` False
      tranCount conn `shouldReturn` 0

    -- Inside a transaction begun by a TM request it is a nested begin
    -- (@@TRANCOUNT 2), not refused; the body then leaves a transaction
    -- open.
    it "inside withTransaction is a nested begin, not refused: TransactionStillOpen, everything rolled back" $ withIntTable "marstx_a24" $ \t -> withMarsConn $ \conn -> do
      r <- try $ withTransaction conn $ do
        insertKey conn t 1
        _ <- execute conn "BEGIN TRANSACTION"
        tranCount conn `shouldReturn` 2
      case r of
        Left TransactionStillOpen -> pure ()
        other -> expectationFailure ("expected TransactionStillOpen, got " ++ show other)
      inTransaction conn `shouldReturn` False
      tranCount conn `shouldReturn` 0
      canTakeKeys t [1]

    it "works when the batch also ends the transaction it began" $ withIntTable "marstx_a24b" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn (rawSql ("BEGIN TRANSACTION; INSERT INTO " <> t <> " VALUES (1); COMMIT TRANSACTION"))
      inTransaction conn `shouldReturn` False
      keysIn t `shouldReturn` [1]

    it "is not needed: begin (a Transaction Manager request) begins one" $ withMarsConn $ \conn -> do
      begin conn
      inTransaction conn `shouldReturn` True
      tranCount conn `shouldReturn` 1
      rollback conn
      inTransaction conn `shouldReturn` False

  describe "A25: the transaction is the connection's" $ do
    it "a stream opened on another session inside withTransaction sees the uncommitted rows and @@TRANCOUNT 1" $ withIntTable "marstx_a25" $ \t -> withMarsConn $ \conn -> withTestDb $ \other -> do
      withTransaction conn $ do
        insertKey conn t 1
        insertKey conn t 2
        withQueryS conn (numbers 100_000) $ \(_ :: Stream (Of WideRow) IO ()) ->
          withQueryS conn (rawSql ("SELECT i, @@TRANCOUNT FROM " <> t <> " ORDER BY i")) $ \s -> do
            busySids conn `shouldReturn` [0, 1]
            S.toList_ s `shouldReturn` [(1 :: Int, 1 :: Int), (2, 1)]
        -- Not yet for another connection.
        fromOnly <$> query1 other (rawSql ("SELECT COUNT(*) FROM " <> t <> " WITH (READPAST)")) `shouldReturn` (0 :: Int)
      keysIn t `shouldReturn` [1, 2]

    it "every session's request carries the descriptor: inside the transaction each of three open requests sees @@TRANCOUNT 1" $ withMarsConn $ \conn -> do
      begin conn
      map snd <$> seenBySessions conn `shouldReturn` [1, 1, 1]
      commit conn
      map snd <$> seenBySessions conn `shouldReturn` [0, 0, 0]

  describe "A26: T-SQL COMMIT and ROLLBACK batches work from any session" $ do
    -- The begin goes on session 0 (the lowest idle one); a response kept
    -- open there (fully arrived, which the server doesn't count) puts the
    -- COMMIT on session 1.
    it "COMMIT TRANSACTION on another session than the begin's commits" $ withIntTable "marstx_a26c" $ \t -> withMarsConn $ \conn -> do
      begin conn
      insertKey conn t 1
      (_, s) <- openWide conn 3
      awaitArrived conn
      busySids conn `shouldReturn` [0]
      _ <- execute conn "COMMIT TRANSACTION"
      inTransaction conn `shouldReturn` False
      map wideRow <$> S.toList_ s `shouldReturn` [1, 2, 3]
      tranCount conn `shouldReturn` 0
      keysIn t `shouldReturn` [1]

    it "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION on another session than the begin's rolls back" $ withIntTable "marstx_a26r" $ \t -> withMarsConn $ \conn -> do
      begin conn
      insertKey conn t 1
      (_, s) <- openWide conn 3
      awaitArrived conn
      busySids conn `shouldReturn` [0]
      _ <- execute conn "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"
      inTransaction conn `shouldReturn` False
      map wideRow <$> S.toList_ s `shouldReturn` [1, 2, 3]
      tranCount conn `shouldReturn` 0
      canTakeKeys t [1]

  describe "A27: with no session busy, a commit or a begin is never refused" $
    it "200 transactions, each begun and committed right after streams of 1 to 3,000 rows were read to their end, cancelled, or closed by withQueryS" $ withIntTable "marstx_a27" $ \t -> withMarsConn $ \conn -> do
      let n = 200
      forM_ [1 .. n] $ \i -> do
        let size = [1, 100, 3000] !! (i `mod` 3)
        -- Before the begin: one stream read to its end, one cancelled
        -- part-way, one left by withQueryS.
        (_, s1) <- openWide conn size
        S.effects s1
        (r2, s2) <- openWide conn size
        S.effects (S.take (size `div` 2) s2)
        cancelResponse r2
        withQueryS conn (numbers size) $ \(s3 :: Stream (Of WideRow) IO ()) -> S.effects (S.take 1 s3)
        -- Alternately withTransaction and the manual functions.
        if even i
          then withTransaction conn $ do
            withQueryS conn (numbers size) $ \(s4 :: Stream (Of WideRow) IO ()) -> S.effects (S.take 1 s4)
            insertKey conn t i
            (_, s5) <- openWide conn size
            S.effects s5
          else do
            begin conn
            (r6, s6) <- openWide conn size
            S.effects (S.take 1 s6)
            cancelResponse r6
            insertKey conn t i
            commit conn
        inTransaction conn `shouldReturn` False
      keysIn t `shouldReturn` [1 .. n]

  -- The stream's first row is read before, so that its statement is
  -- running on the server, parked at the window (sent right behind its
  -- request, the other request may run first).
  describe "A28: what the check protects against, through the raw request layer" $ do
    it "a COMMIT batch with another request unfinished gets 3981 and loses the transaction; the other stream delivers its rows, then 3998" $ withIntTable "marstx_a28c" $ \t -> withMarsConn $ \conn -> do
      begin conn
      insertKey conn t 1
      (_, s0) <- openWide conn 100_000
      Right (_, s) <- S.next s0
      -- The library refuses first, and the transaction stays open.
      requestsActive (commit conn) `shouldReturn` [numbersSql 100_000]
      inTransaction conn `shouldReturn` True
      -- The server, asked without the check:
      resp <- startResponse conn (batchRequest "COMMIT TRANSACTION")
      drainResponse resp `failsWithSql` 3981
      inTransaction conn `shouldReturn` False
      seen <- newIORef (1 :: Int)
      sqlErrorOf (S.mapM_ (\_ -> modifyIORef' seen (+ 1)) s) `shouldReturn` 3998
      readIORef seen `shouldReturn` 100_000
      noResponseOpen conn
      tranCount conn `shouldReturn` 0
      canTakeKeys t [1]

    it "a TM begin with another request unfinished gets 3988, and the stream is unaffected" $ withMarsConn $ \conn -> do
      (_, s0) <- openWide conn 100_000
      Right (_, s) <- S.next s0
      requestsActive (begin conn) `shouldReturn` [numbersSql 100_000]
      resp <- startResponse conn rawTmBegin
      drainResponse resp `failsWithSql` 3988
      inTransaction conn `shouldReturn` False
      length <$> S.toList_ s `shouldReturn` 99_999
      begin conn
      inTransaction conn `shouldReturn` True
      rollback conn

  describe "TransactionStillOpen on a MARS connection" $ do
    it "a body that calls begin and doesn't end it: everything rolled back, then TransactionStillOpen" $ withIntTable "marstx_still" $ \t -> withMarsConn $ \conn -> do
      r <- try $ withTransaction conn $ do
        insertKey conn t 1
        withQueryS conn (numbers 100) $ \(s :: Stream (Of WideRow) IO ()) -> S.effects s
        begin conn
        insertKey conn t 2
        tranCount conn `shouldReturn` 2
      case r of
        Left TransactionStillOpen -> pure ()
        other -> expectationFailure ("expected TransactionStillOpen, got " ++ show other)
      inTransaction conn `shouldReturn` False
      tranCount conn `shouldReturn` 0
      noResponseOpen conn
      canTakeKeys t [1, 2]
      withTransaction conn (insertKey conn t 3)
      keysIn t `shouldReturn` [3]

    it "a nested begin with a stream open is refused (TransactionRequestsActive), and withTransaction rolls back" $ withIntTable "marstx_still2" $ \t -> withMarsConn $ \conn -> do
      stmts <- requestsActive $ withTransaction conn $ do
        insertKey conn t 1
        withQueryS conn (numbers 100) $ \(_ :: Stream (Of WideRow) IO ()) -> begin conn
      stmts `shouldBe` [numbersSql 100]
      inTransaction conn `shouldReturn` False
      noResponseOpen conn
      canTakeKeys t [1]

  describe "withTransactionLevel on a MARS connection" $
    it "sets the level every session sees, in the transaction, and READ COMMITTED on every session after it" $ withMarsConn $ \conn ->
      forM_ [ReadUncommitted, RepeatableRead, Serializable, ReadCommitted] $ \l -> do
        _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
        withTransactionLevel l conn $
          seenBySessions conn `shouldReturn` replicate 3 (levelByte l, 1)
        seenBySessions conn `shouldReturn` replicate 3 (levelByte ReadCommitted, 0)

  describe "a failure inside a transaction leaves no response open, and the commit goes through" $ do
    it "a decode error (query, and a stream)" $ withIntTable "marstx_decode" $ \t -> withMarsConn $ \conn -> do
      withTransaction conn $ do
        insertKey conn t 1
        r1 <- try (query conn "SELECT 'x' UNION ALL SELECT 'y'" :: IO [Only Int])
        either (\(_ :: DecodeError) -> pure ()) (\_ -> expectationFailure "decoded") r1
        noResponseOpen conn
        -- Row 50,000 has a NULL, with half the result still to come.
        (_, s) <- openS conn ("SELECT CASE WHEN n.i = 50000 THEN NULL ELSE n.i END, n.pad FROM " <> numbersTable 100_000 <> " ORDER BY n.i")
        r2 <- try (S.effects (s :: Stream (Of WideRow) IO ()))
        either (\(_ :: DecodeError) -> pure ()) (\_ -> expectationFailure "decoded") r2
        noResponseOpen conn
        insertKey conn t 2
      keysIn t `shouldReturn` [1, 2]

    it "an exception from the info message callback, with the rest of the response still to come" $ withIntTable "marstx_info" $ \t -> do
      let boom m = when (msgText m == "boom") $ throwIO (userError "callback")
      withMarsConnWith (\ci -> ci { connectOnInfoMessage = boom }) $ \conn -> do
        withTransaction conn $ do
          insertKey conn t 1
          r <- try (execute conn (rawSql ("PRINT 'boom'; " <> numbersSql 100_000)))
          either (\(e :: IOException) -> show e `shouldContain` "callback") (\_ -> expectationFailure "no exception") r
          noResponseOpen conn
          insertKey conn t 2
        keysIn t `shouldReturn` [1, 2]

    it "an exception from a queryFold step part-way through a large result" $ withIntTable "marstx_fold" $ \t -> withMarsConn $ \conn -> do
      withTransaction conn $ do
        insertKey conn t 1
        seen <- newIORef (0 :: Int)
        r <- try $ queryFold conn (numbers 100_000) () $ \() (row :: WideRow) -> do
          modifyIORef' seen (+ 1)
          when (wideRow row == 10) $ throwIO (userError "fold")
        either (\(e :: IOException) -> show e `shouldContain` "fold") (\_ -> expectationFailure "no exception") r
        readIORef seen `shouldReturn` 10
        noResponseOpen conn
        insertKey conn t 2
      keysIn t `shouldReturn` [1, 2]

    it "a stream's consumer that throws, inside withQueryS" $ withIntTable "marstx_consumer" $ \t -> withMarsConn $ \conn -> do
      withTransaction conn $ do
        insertKey conn t 1
        r <- try $ withQueryS conn (numbers 100_000) $ \(s :: Stream (Of WideRow) IO ()) ->
          S.mapM_ (\row -> when (wideRow row == 500) $ throwIO (userError "consumer")) s
        either (\(e :: IOException) -> show e `shouldContain` "consumer") (\_ -> expectationFailure "no exception") r
        noResponseOpen conn
        insertKey conn t 2
      keysIn t `shouldReturn` [1, 2]
