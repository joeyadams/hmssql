-- | Which SMP session each request takes and when it is free again
-- (docs/dev/mars-research.md, A13, A14, A16-A18, "Session reuse"): sequential requests
-- stay on session 0; requests made while streams are open take 1, 2, ...;
-- a freed session is the lowest one taken next and is reusable at once after
-- the final DONE, an error and a cancel; the sessions are one SQL session;
-- and at most 10 idle sessions are kept, the rest closed with FIN.
module Mars.SessionsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (forM, forM_, void)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (expectUsable)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Errors
import Hmssql.Query (callProcedure, inParam)
import Mars.Harness
import TestDb

spec :: Spec
spec = around withMarsConn $ do
  describe "which session a request takes" $ do
    it "sequential requests of every kind use only session 0" $ \conn -> withinMoving 60 conn $ do
      forM_ [1 .. 20 :: Int] $ \i -> do
        query1 conn (mkQuery "SELECT @p1" (Only i)) `shouldReturn` Only i
        _ <- execute conn "DECLARE @x int = 1"
        _ <- query conn (rawSql (numbers 100)) :: IO [Only Int64]
        numStream conn 5000 >>= S.length_ >>= (`shouldBe` 5000)
        _ <- callProcedure conn "sp_executesql" [inParam "" ("SELECT 1" :: Text)]
        try @SqlServerError (query conn "SELECT 1/0" :: IO [Only Int]) >>= either (const (pure ())) (const (expectationFailure "no error"))
      openSids conn `shouldReturn` [0]
      registrySids conn `shouldReturn` [0]

    it "A13: the first session is 0, and streams open at once take 1, 2, ... in turn" $ \conn -> withinMoving 60 conn $ do
      openSids conn `shouldReturn` [0]
      streams <- forM [0 .. 5 :: Int] $ \k -> do
        s <- numStream conn 1000
        busySids conn `shouldReturn` [0 .. k]
        openSids conn `shouldReturn` [0 .. k]
        registrySids conn `shouldReturn` [0 .. k]
        pure s
      -- Every one holds its rows.
      forM_ streams $ \s -> S.length_ s `shouldReturn` 1000
      busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0 .. 5]

    it "requests made beside an open stream take the next session, and leave the stream's open" $ \conn -> withinMoving 60 conn $ do
      s <- numStream conn 1000
      busySids conn `shouldReturn` [0]
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      openSids conn `shouldReturn` [0, 1]
      busySids conn `shouldReturn` [0]
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
      -- Session 1 again: it was idle again.
      openSids conn `shouldReturn` [0, 1]
      S.length_ s `shouldReturn` 1000
      busySids conn `shouldReturn` []

    it "requests made in a queryFold step take the next session, and the fold goes on" $ \conn -> withinMoving 60 conn $ do
      total <- queryFold conn (rawSql (numbers 5000)) (0 :: Int64) $ \acc (Only (n :: Int64)) -> do
        busySids conn `shouldReturn` [0]
        Only m <- query1 conn (mkQuery "SELECT CAST(@p1 AS bigint)" (Only n))
        pure (acc + m)
      total `shouldBe` sum [1 .. 5000]
      openSids conn `shouldReturn` [0, 1]
      busySids conn `shouldReturn` []

    it "freed sessions are taken lowest first" $ \conn -> withinMoving 60 conn $ do
      [s0, s1, s2, s3] <- mapM (const (numStream conn 1000)) [1 .. 4 :: Int]
      busySids conn `shouldReturn` [0, 1, 2, 3]
      -- End the streams on sessions 2 and 0, in that order.
      S.length_ s2 `shouldReturn` 1000
      busySids conn `shouldReturn` [0, 1, 3]
      S.length_ s0 `shouldReturn` 1000
      busySids conn `shouldReturn` [1, 3]
      idleSids conn `shouldReturn` [0, 2]
      x <- numStream conn 1000
      busySids conn `shouldReturn` [0, 1, 3]
      y <- numStream conn 1000
      busySids conn `shouldReturn` [0, 1, 2, 3]
      z <- numStream conn 1000
      busySids conn `shouldReturn` [0, 1, 2, 3, 4]
      forM_ [s1, s3, x, y, z] $ \s -> S.length_ s `shouldReturn` 1000
      busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0 .. 4]

    it "a stream read up to its last row but not past it still holds its session (the final DONE is unread)" $ \conn -> withinMoving 60 conn $ do
      s <- numStream conn 3
      (rows, rest) <- takeRows 3 s
      rows `shouldBe` [1, 2, 3]
      busySids conn `shouldReturn` [0]
      S.length_ rest `shouldReturn` 0
      busySids conn `shouldReturn` []

  describe "A14: a session is reusable at once" $ do
    it "after its final DONE (500 streams read to the end, one after the other)" $ \conn -> withinMoving 120 conn $ do
      forM_ [1 .. 500 :: Int] $ \_ -> do
        numStream conn 50 >>= S.length_ >>= (`shouldBe` 50)
        busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0]

    it "after an error-ended response (500 failing requests)" $ \conn -> withinMoving 120 conn $ do
      forM_ [1 .. 500 :: Int] $ \i -> do
        r <- try (query conn (mkQuery "SELECT 1 / (@p1 - @p1)" (Only i)) :: IO [Only Int])
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 8134
          Right rows -> expectationFailure ("no error: " ++ show rows)
        busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0]
      query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)

    it "after an error in the middle of a stream (500 streams that fail after some rows)" $ \conn -> withinMoving 120 conn $ do
      forM_ [1 .. 500 :: Int] $ \_ -> do
        s <- queryS conn "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 1 / 0" :: IO (S.Stream (S.Of (Only Int)) IO ())
        r <- try (S.length_ s)
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 8134
          Right n -> expectationFailure ("no error after " ++ show n ++ " rows")
        busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0]

    it "after a cancel (500 streams cancelled after three rows)" $ \conn -> withinMoving 180 conn $ do
      forM_ [1 .. 500 :: Int] $ \_ -> do
        withNums conn 1_000_000 $ \s -> do
          (rows, _) <- takeRows 3 s
          rows `shouldBe` [1, 2, 3]
        busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0]
      expectUsable conn

    it "beside an open stream: 500 errors and cancels use session 1 only" $ \conn -> withinMoving 180 conn $ do
      parked <- numStream conn 1_000_000
      forM_ [1 .. 250 :: Int] $ \_ -> do
        void (try @SqlServerError (query conn "SELECT 1/0" :: IO [Only Int]))
        withNums conn 1_000_000 $ \s -> void (takeRows 2 s)
        busySids conn `shouldReturn` [0]
      openSids conn `shouldReturn` [0, 1]
      -- The stream that was open all along is intact.
      (rows, rest) <- takeRows 3 parked
      rows `shouldBe` [1, 2, 3]
      S.length_ (S.take 100 rest) `shouldReturn` 100

  describe "A18: every session is one SQL session" $ do
    it "a SET option set on one session holds on another" $ \conn -> withinMoving 60 conn $ do
      -- A stream that fits in one packet, so that its request has ended on
      -- the server: a SET beside a running request is undone when the
      -- request ends (a test below), which with a window of 4 packets of
      -- 512 bytes a stream of 1000 rows still was.
      s <- numStream conn 20
      -- The batch goes on session 1, the next request on 0 once s has ended.
      _ <- execute conn "SET DATEFIRST 3"
      busySids conn `shouldReturn` [0]
      S.length_ s `shouldReturn` 20
      query1 conn "SELECT CAST(@@DATEFIRST AS int)" `shouldReturn` Only (3 :: Int)
      openSids conn `shouldReturn` [0, 1]
      -- And the other way round: set on session 0, seen from 1.
      _ <- execute conn "SET DATEFIRST 5"
      s2 <- numStream conn 1000
      query1 conn "SELECT CAST(@@DATEFIRST AS int)" `shouldReturn` Only (5 :: Int)
      void (S.length_ s2)

    it "a #temp table created on one session is visible on another, and dropped with the connection's session" $ \conn -> withinMoving 60 conn $ do
      s <- numStream conn 1000
      _ <- execute conn "CREATE TABLE #shared (i int); INSERT INTO #shared VALUES (1), (2)"
      S.length_ s `shouldReturn` 1000
      query conn "SELECT i FROM #shared ORDER BY i" `shouldReturn` [Only (1 :: Int), Only 2]
      s2 <- numStream conn 1000
      _ <- execute conn "INSERT INTO #shared VALUES (3)"
      S.length_ s2 `shouldReturn` 1000
      query conn "SELECT COUNT(*) FROM #shared" `shouldReturn` [Only (3 :: Int)]

    skipOnAzure "no USE" $ it "USE on one session changes the database of every session" $ \conn -> withinMoving 60 conn $ do
      db <- fromOnly <$> query1 conn "SELECT DB_NAME()" :: IO Text
      -- Streams that fit in one packet, so that their requests have ended
      -- on the server: a USE beside a running request is undone when the
      -- request ends (a test below), which with a window of 4
      -- packets of 512 bytes a stream of 1000 rows still was.
      s <- numStream conn 20
      _ <- execute conn "USE tempdb"
      S.length_ s `shouldReturn` 20
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only ("tempdb" :: Text)
      s2 <- numStream conn 20
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only ("tempdb" :: Text)
      _ <- execute conn (rawSql ("USE " <> quoteName db))
      S.length_ s2 `shouldReturn` 20
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only db

    it "the isolation level set on one session is seen from a second while a stream is open on the first" $ \conn -> withinMoving 60 conn $ do
      let level = fromOnly <$> query1 conn
            "SELECT CAST(transaction_isolation_level AS int) FROM sys.dm_exec_sessions WHERE session_id = @@SPID" :: IO Int
      level `shouldReturn` 2
      -- Streams too long for the window, so that their requests are still
      -- running: one that ended here would bring back the level it began
      -- with (the next test).  With 100,000 rows, which fit in the window
      -- of packets of 32767 bytes, the first stream's request now and then
      -- ended between the SET and the check after it.
      s <- numStream conn 2_000_000
      _ <- firstRow s
      _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
      level `shouldReturn` 3
      -- Another session, with two streams open.
      s2 <- numStream conn 2_000_000
      level `shouldReturn` 3
      openSids conn `shouldReturn` [0, 1, 2]
      _ <- execute conn "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
      level `shouldReturn` 2
      cancelActiveStatement conn
      expectAbandonedS s
      expectAbandonedS s2

    -- One SQL session, but not one set of settings: the server gives each
    -- request a copy of the session's settings when it starts and writes
    -- the copy back when it ends, so the last request to end decides them
    -- (docs/dev/protocol-notes.md, "MARS and SMP").
    it "a SET made while an older request is running is undone when that request ends; SESSION_CONTEXT and a #temp table stay" $ \conn -> withinMoving 60 conn $ do
      let settings = query1 conn
            "SELECT CAST(s.transaction_isolation_level AS int), CAST(@@OPTIONS & 16384 AS int), CAST(@@DATEFIRST AS int), \
            \CAST(SESSION_CONTEXT(N'hmssql_k') AS nvarchar(10)), CAST(OBJECT_ID('tempdb..#kept') AS int) \
            \FROM sys.dm_exec_sessions s WHERE s.session_id = @@SPID" :: IO (Int, Int, Int, Maybe Text, Maybe Int)
          stripped (level, xactAbort, dateFirst, ctx, temp) = (level, xactAbort, dateFirst, ctx, fmap (const ()) temp)
      (stripped <$> settings) `shouldReturn` (2, 0, 7, Nothing, Nothing)
      -- Too long for the window: its request is still running.
      older <- numStream conn 2_000_000
      (_, rest) <- firstRow older
      _ <- execute conn
        "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET XACT_ABORT ON; SET DATEFIRST 3; \
        \EXEC sp_set_session_context N'hmssql_k', N'v'; CREATE TABLE #kept (i int)"
      -- Later requests see it all.
      (stripped <$> settings) `shouldReturn` (3, 16384, 3, Just "v", Just ())
      -- The older request ends, with the settings it began with.
      S.effects rest
      (stripped <$> settings) `shouldReturn` (2, 0, 7, Just "v", Just ())

  describe "the idle cap" $ do
    it "A16: with 30 streams opened and ended, a request closes all but 10 idle sessions with FIN, the server answers, and the SIDs are reusable" $ \conn -> withinMoving 120 conn $ do
      streams <- mapM (const (numStream conn 100)) [1 .. 30 :: Int]
      busySids conn `shouldReturn` [0 .. 29]
      forM_ streams $ \s -> S.length_ s `shouldReturn` 100
      busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0 .. 29]
      -- The next request closes the idle sessions beyond ten, highest first.
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      openSids conn `shouldReturn` [0 .. 9]
      -- The server's FINs arrive and free the identifiers.
      gone <- waitUntil 10 ((== [0 .. 9]) <$> registrySids conn)
      gone `shouldBe` True
      closingSids conn `shouldReturn` []
      -- The server has the ten sessions and the connection only.
      rows <- query conn
        "SELECT net_transport FROM sys.dm_exec_connections WHERE session_id = @@SPID" :: IO [Only Text]
      length [() | Only "Session" <- rows] `shouldBe` 10
      -- New sessions reuse the closed low identifiers: 10, 11, ..., not 30.
      more <- mapM (const (numStream conn 100)) [1 .. 15 :: Int]
      busySids conn `shouldReturn` [0 .. 14]
      registrySids conn `shouldReturn` [0 .. 14]
      forM_ more $ \s -> S.length_ s `shouldReturn` 100

    it "the cap does not close a busy session: 30 streams, ten of them ended, keep the twenty open" $ \conn -> withinMoving 120 conn $ do
      streams <- mapM (const (numStream conn 100)) [1 .. 30 :: Int]
      -- End the first ten.
      forM_ (take 10 streams) $ \s -> S.length_ s `shouldReturn` 100
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      -- Ten idle (0-9), twenty busy: nothing beyond the cap of idle ones to close.
      busySids conn `shouldReturn` [10 .. 29]
      idle <- idleSids conn
      idle `shouldBe` [0 .. 9]
      openSids conn `shouldReturn` [0 .. 29]
      forM_ (drop 10 streams) $ \s -> S.length_ s `shouldReturn` 100

    it "with more than ten idle, the highest closes first: the request runs on the lowest idle session" $ \conn -> withinMoving 120 conn $ do
      streams <- mapM (const (numStream conn 100)) [1 .. 14 :: Int]
      forM_ streams $ \s -> S.length_ s `shouldReturn` 100
      -- A stream now takes session 0, so the busy one is the lowest.
      s <- numStream conn 100
      busySids conn `shouldReturn` [0]
      openSids conn `shouldReturn` [0 .. 9]
      void (S.length_ s)

    it "A17: idle sessions stay open: the server closes none of them by itself" $ \conn -> withinMoving 120 conn $ do
      streams <- mapM (const (numStream conn 100)) [1 .. 6 :: Int]
      forM_ streams $ \s -> S.length_ s `shouldReturn` 100
      openSids conn `shouldReturn` [0 .. 5]
      threadDelay 4_000_000
      registrySids conn `shouldReturn` [0 .. 5]
      -- All six are usable still: six streams at once take all of them.
      again <- mapM (const (numStream conn 100)) [1 .. 6 :: Int]
      busySids conn `shouldReturn` [0 .. 5]
      openSids conn `shouldReturn` [0 .. 5]
      forM_ again $ \s -> S.length_ s `shouldReturn` 100
      expectUsable conn
