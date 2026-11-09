-- | Query hygiene on a MARS connection (docs/dev/mars-research.md A29, A29b): a
-- transaction can't begin or be committed while a response on the
-- connection has not been read to its end or cancelled.  'withTransaction'
-- then throws 'TransactionRequestsActive' naming the statement, commits
-- nothing and leaves no transaction open; the same body with the stream
-- finished commits.  The outcome depends only on what the caller read,
-- never on the result's size or on timing.  Before a begin nothing is
-- sent; 'commit' leaves the transaction open;
-- 'rollback' cancels the open responses and rolls back.
module MarsTx.HygieneSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (forM_, void)
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import Hmssql.Query
import Hmssql.Transaction
import Mars.Harness (cancelling, survivingEarlyAttentionKill)
import MarsTx.Harness
import TestDb

sizes :: [Int]
sizes = [1, 100, 100_000]

-- | How many times each case runs.
runs :: Int
runs = 50

-- | A way for the body to leave its stream unfinished, given the stream's
-- number of rows.
data Leave = Leave String (Int -> Stream (Of WideRow) IO () -> IO ())

unfinished :: [Leave]
unfinished =
  [ Leave "left unread" (\_ _ -> pure ())
  , Leave "read part-way" (\n s -> S.effects (S.take (n `div` 2) s))
  , Leave "A29b: read to its last row but not to its end (the final DONE unread)" $ \n s ->
      length <$> S.toList_ (S.take n s) `shouldReturn` n
  ]

-- | A way for the body to finish its stream, given its number of rows.
data Finish = Finish String (Connection -> Int -> IO ())

finishes :: [Finish]
finishes =
  [ Finish "read to its end (S.effects)" $ \conn n -> openWide conn n >>= S.effects . snd
  , Finish "read to its end (S.toList_)" $ \conn n -> do
      (_, s) <- openWide conn n
      length <$> S.toList_ s `shouldReturn` n
  , Finish "cancelled with cancelResponse after reading part of it" $ \conn n -> do
      (r, s) <- openWide conn n
      S.effects (S.take (n `div` 2) s)
      cancelResponse r
  , Finish "cancelled with cancelResponse unread" $ \conn n -> do
      (r, _) <- openWide conn n
      cancelResponse r
  , Finish "opened with withQueryS, read part-way" $ \conn n ->
      withQueryS conn (numbers n) (\(s :: Stream (Of WideRow) IO ()) -> S.effects (S.take (n `div` 2) s))
  , Finish "opened with withQueryS, read to its last row only" $ \conn n ->
      withQueryS conn (numbers n) (\(s :: Stream (Of WideRow) IO ()) -> S.effects (S.take n s))
  ]

-- | Timing, varied by run: nothing; a short pause; the response fully
-- arrived (a small one) or a longer pause (a large one, which never
-- arrives: it is parked at the window).
pause :: Connection -> Int -> Int -> IO ()
pause conn run size = case run `mod` 3 of
  0 -> pure ()
  1 -> threadDelay 2_000
  _ | size <= 100 -> awaitArrived conn
    | otherwise -> threadDelay 20_000

-- | A connection that takes and gives back a key, or says whether it is
-- committed, with a short @LOCK_TIMEOUT@: a lock left behind is held until
-- the connection closes, so 2 s tells it apart (0 met locks the server was
-- still releasing under the load of a whole suite run).
data Observer = Observer
  { takeKey :: Int -> IO ()
  , committed :: Int -> IO Bool
  }

withObserver :: Text -> (Observer -> IO a) -> IO a
withObserver t act = withTestDb $ \obs -> do
  _ <- execute obs "SET LOCK_TIMEOUT 2000"
  act Observer
    { takeKey = \k -> do
        insertKey obs t k
        void $ execute obs (mkQuery ("DELETE FROM " <> t <> " WHERE i = @p1") (Only k))
    , committed = \k -> (== (1 :: Int)) . fromOnly <$> query1 obs (mkQuery ("SELECT COUNT(*) FROM " <> t <> " WHERE i = @p1") (Only k))
    }

spec :: Spec
spec = do
  describe "A29: withTransaction whose body leaves a stream unfinished throws TransactionRequestsActive naming it; nothing is committed, and no transaction is left open" $ do
    it "a one-row result that has fully arrived, left unread (50 times)" $ withIntTable "marstx_a29a" $ \t -> withMarsConn $ \conn -> withObserver t $ \obs ->
      forM_ [1 .. runs] $ \i -> do
        stmts <- requestsActive $ withTransaction conn $ do
          insertKey conn t i
          _ <- openWide conn 1
          awaitArrived conn
          allArrived conn `shouldReturn` True
        stmts `shouldBe` [numbersSql 1]
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        takeKey obs i

    it "a large result parked at its window, one row read (50 times)" $ withIntTable "marstx_a29b" $ \t -> withMarsConn $ \conn -> withObserver t $ \obs ->
      forM_ [1 .. runs] $ \i -> do
        stmts <- requestsActive $ withTransaction conn $ do
          insertKey conn t i
          (_, s) <- openWide conn 100_000
          S.effects (S.take 1 s)
          threadDelay 10_000
          allArrived conn `shouldReturn` False
        stmts `shouldBe` [numbersSql 100_000]
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        takeKey obs i

    forM_ unfinished $ \(Leave label leave) ->
      it (label ++ ": the same for 1, 100 and 100,000 rows, 50 times each, at various timings") $ withIntTable "marstx_a29" $ \t -> withMarsConnArriving $ \conn -> withObserver t $ \obs ->
        forM_ (zip [0 ..] sizes) $ \(k, size) -> forM_ [1 .. runs] $ \i -> do
          let key = k * 1000 + i
          stmts <- requestsActive $ withTransaction conn $ do
            insertKey conn t key
            (_, s) <- openWide conn size
            leave size s
            pause conn i size
          stmts `shouldBe` [numbersSql size]
          inTransaction conn `shouldReturn` False
          noResponseOpen conn
          tranCount conn `shouldReturn` 0
          takeKey obs key

  describe "A29: the same body with the stream finished commits" $
    forM_ finishes $ \(Finish label finish) ->
      it (label ++ ": 1, 100 and 100,000 rows, 50 times each, at various timings") $ withIntTable "marstx_a29ok" $ \t -> withMarsConnArriving $ \conn -> withObserver t $ \obs ->
        forM_ (zip [0 ..] sizes) $ \(k, size) -> forM_ [1 .. runs] $ \i -> do
          let key = k * 1000 + i
          withTransaction conn $ do
            insertKey conn t key
            finish conn size
            noResponseOpen conn
            pause conn i size
          inTransaction conn `shouldReturn` False
          committed obs key `shouldReturn` True

  describe "TransactionRequestsActive before the begin" $ do
    let begins :: [(String, Connection -> IO () -> IO ())]
        begins =
          [ ("withTransaction", withTransaction)
          , ("withTransactionLevel Serializable", withTransactionLevel Serializable)
          , ("begin", \conn body -> begin conn >> body >> commit conn)
          ]
    forM_ begins $ \(label, run) ->
      it (label ++ " with streams open: refused naming both, nothing sent, the streams still readable and complete") $ withIntTable "marstx_before" $ \t -> withMarsConn $ \conn ->
        forM_ sizes $ \size -> do
          (_, s1) <- openWide conn size
          (_, s2) <- openS conn "SELECT 'second'"
          ran <- newIORef False
          stmts <- requestsActive $ run conn (writeIORef ran True >> insertKey conn t size)
          sort stmts `shouldBe` sort [numbersSql size, "SELECT 'second'"]
          readIORef ran `shouldReturn` False
          inTransaction conn `shouldReturn` False
          -- Nothing was sent: the begin at SERIALIZABLE would have set it.
          sessionLevel conn `shouldReturn` ReadCommitted
          tranCount conn `shouldReturn` 0
          map wideRow <$> S.toList_ s1 `shouldReturn` [1 .. size]
          S.toList_ s2 `shouldReturn` [Only ("second" :: Text)]
          noResponseOpen conn
          keysIn t `shouldReturn` []

  -- R27: a leaked stream must be findable from the exception, whichever
  -- function opened it.
  describe "TransactionRequestsActive names the leaked stream's statement" $ do
    it "a queryS stream with parameters: its text, as sent" $ withMarsConn $ \conn -> do
      s <- queryS conn ("SELECT n.i, n.pad FROM " <> rawSql (numbersTable 100) <> " WHERE n.i > " <> param (0 :: Int) <> " ORDER BY n.i")
      stmts <- requestsActive (withTransaction conn (pure ()))
      stmts `shouldBe` ["SELECT n.i, n.pad FROM " <> numbersTable 100 <> " WHERE n.i > @p1 ORDER BY n.i"]
      length <$> S.toList_ (s :: Stream (Of WideRow) IO ()) `shouldReturn` 100
      noResponseOpen conn

    it "a batchQueryS stream (the last statement of a runBatchQuery): its text, not an anonymous request" $ withIntTable "marstx_batchs" $ \t -> withMarsConn $ \conn -> do
      (n, s) <- runBatchQuery conn $ (,)
        <$> batchExecute (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only (1 :: Int)))
        <*> batchQueryS (numbers 100)
      n `shouldBe` 1
      stmts <- requestsActive (withTransaction conn (pure ()))
      stmts `shouldBe` [numbersSql 100]
      requestsActive (begin conn) `shouldReturn` [numbersSql 100]
      length <$> S.toList_ (s :: Stream (Of WideRow) IO ()) `shouldReturn` 100
      noResponseOpen conn
      withTransaction conn (pure ())

  describe "the manual functions" $ do
    it "commit with a busy session throws TransactionRequestsActive and leaves the transaction open; with the stream finished it commits" $ withIntTable "marstx_commit" $ \t -> withMarsConn $ \conn ->
      forM_ sizes $ \size -> do
        begin conn
        insertKey conn t size
        (_, s) <- openWide conn size
        requestsActive (commit conn) `shouldReturn` [numbersSql size]
        inTransaction conn `shouldReturn` True
        -- On another session, inside the transaction.
        tranCount conn `shouldReturn` 1
        length <$> S.toList_ s `shouldReturn` size
        commit conn
        inTransaction conn `shouldReturn` False
        tranCount conn `shouldReturn` 0
        (size `elem`) <$> keysIn t `shouldReturn` True

    it "rollback with busy sessions cancels them (ResultAbandoned) and rolls back" $ withIntTable "marstx_rollback" $ \t -> withMarsConn $ \conn ->
      survivingEarlyAttentionKill "rollback with busy sessions" conn $ forM_ [1 .. 20] $ \i -> do
        begin conn
        insertKey conn t i
        (_, big0) <- openWide conn 100_000
        Right (_, big) <- S.next big0
        (_, small) <- openWide conn 1
        (_, part0) <- openWide conn 100
        Right (_, part) <- S.next part0
        length <$> busySids conn `shouldReturn` 3
        cancelling (rollback conn)
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        tranCount conn `shouldReturn` 0
        shouldBeAbandoned (S.effects big)
        shouldBeAbandoned (S.effects small)
        shouldBeAbandoned (S.effects part)
        canTakeKeys t [i]

    it "rollback with an XACT_ABORT ON stream still executing: rolled back, no error surfaces" $ withIntTable "marstx_rollback_xa" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 20] $ \i -> do
        begin conn
        insertKey conn t i
        (_, big0) <- openWide conn 100_000
        Right (_, _) <- S.next big0
        r <- try (rollback conn)
        either (\(e :: SomeException) -> expectationFailure ("rollback threw " ++ show e)) pure r
        inTransaction conn `shouldReturn` False
        tranCount conn `shouldReturn` 0
        canTakeKeys t [i]
