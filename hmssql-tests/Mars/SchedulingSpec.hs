-- | How the server schedules the sessions of one connection (docs/dev/mars-research.md,
-- A19-A21): row-producing SELECTs interleave packet by packet; a statement
-- that does not yield (WAITFOR, a lock wait) stalls every session; and a
-- write to the table an open scan reads, outside a transaction, ends in a
-- lock timeout, where inside one transaction, or to another table, it
-- succeeds.  The scans read at lock-based READ COMMITTED whatever the
-- database's READ_COMMITTED_SNAPSHOT (on in Azure SQL Database), since
-- these are lock effects.
module Mars.SchedulingSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM, forM_, void, when)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (elapsed)
import Hmssql
import Hmssql.Errors
import Mars.Harness
import TestDb

-- | The numbers 1 .. n, plus an offset that names the stream.
numbersFrom :: Int64 -> Int -> Text
numbersFrom offset n = "SELECT TOP " <> T.pack (show n)
  <> " CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) + " <> T.pack (show offset)
  <> " FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | A scan at lock-based READ COMMITTED (READCOMMITTEDLOCK): under RCSI a
-- plain scan reads row versions, so it neither waits for a writer's lock
-- nor holds a shared one while it is parked at its window.
scanQuery :: Text -> Query
scanQuery table = rawSql ("SELECT id, pad FROM " <> table <> " WITH (READCOMMITTEDLOCK)")

scanStream :: Connection -> Text -> IO (Stream (Of (Int32, Text)) IO ())
scanStream conn table = queryS conn (scanQuery table)

spec :: Spec
spec = do
  describe "A19: row-producing SELECTs interleave" $
    it "four streams read round-robin, 200,000 rows each, through withQueryS: every row is its stream's next number" $
      withMarsConn $ \conn -> withinMoving 300 conn $ do
        let stream k = withQueryS conn (rawSql (numbersFrom (k * 10_000_000) 200_000))
        stream 0 $ \a -> stream 1 $ \b -> stream 2 $ \c -> stream 3 $ \d -> do
          busySids conn `shouldReturn` [0, 1, 2, 3]
          rows <- roundRobin (map (S.map fromOnly) [a, b, c, d]) $ \i n (v :: Int64) ->
            when (v /= fromIntegral i * 10_000_000 + fromIntegral n + 1) $
              expectationFailure ("stream " ++ show i ++ " row " ++ show n ++ " is " ++ show v)
          rows `shouldBe` replicate 4 200_000
        busySids conn `shouldReturn` []

  describe "A19: the server serves every open stream, not one at a time" $
    it "four unread streams each have their window of packets before any is read" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        streams <- forM [1 .. 4 :: Int] $ \_ -> queryS conn (rawSql (wideRows 30_000)) :: IO (Stream (Of (Int64, Text)) IO ())
        forM_ [0 .. 3] $ \sid -> waitHeldFull conn sid (connWindow conn) `shouldReturn` connWindow conn
        -- Reading one does not need the others to have finished.
        rows <- roundRobin streams (\_ _ _ -> pure ())
        rows `shouldBe` replicate 4 30_000

  describe "A20: a statement that does not yield stalls every session" $ do
    serial $ it "a WAITFOR on one session delays a request on another by its whole length" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        s <- queryS conn "WAITFOR DELAY '00:00:02'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
        -- Let the server start the WAITFOR: a request sent right behind it
        -- may be dispatched first.
        threadDelay 300_000
        (r, t) <- elapsed (query1 conn "SELECT 2")
        r `shouldBe` Only (2 :: Int)
        -- The request waited for the rest of the WAITFOR on the server.
        t `shouldSatisfy` (>= 1.0)
        readAll s `shouldReturn` [1]

    serial $ it "without MARS, on another connection, the same request is not delayed" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        s <- queryS conn "WAITFOR DELAY '00:00:02'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
        threadDelay 300_000
        (r, t) <- withPlainConn $ \other -> elapsed (query1 other "SELECT 2")
        r `shouldBe` Only (2 :: Int)
        t `shouldSatisfy` (< 0.6)
        readAll s `shouldReturn` [1]

    it "a lock wait on one session stalls a request on another until the lock is released" $
      withScanTable 10 $ \table -> withMarsConn $ \conn -> withTestDb $ \holder -> withinMoving 60 conn $ do
        locked <- newEmptyMVar
        release <- newEmptyMVar
        done <- newEmptyMVar
        -- The holder's thread reports how its transaction ended, and is
        -- released and waited for however the test ends: left blocked, it
        -- would commit on a connection already closed, and throw where
        -- nothing catches it.
        _ <- forkIO $ try @SomeException (withTransaction holder $ do
          _ <- execute holder (rawSql ("UPDATE " <> table <> " SET pad = 'held'"))
          putMVar locked ()
          takeMVar release) >>= putMVar done
        flip finally (tryPutMVar release () >> takeMVar done) $ do
          takeMVar locked
          -- The scan waits for the lock; the request on the other session waits too.
          s <- queryS conn (scanQuery table) :: IO (Stream (Of (Int32, Text)) IO ())
          _ <- forkIO (threadDelay 2_000_000 >> void (tryPutMVar release ()))
          threadDelay 300_000
          (r, t) <- elapsed (query1 conn "SELECT 3")
          r `shouldBe` Only (3 :: Int)
          t `shouldSatisfy` (>= 1.0)
          readMVar done >>= either throwIO pure
          -- Once it is free, the scan delivers the committed rows.
          rows <- S.toList_ s
          map fst rows `shouldBe` [1 .. 10]
          map snd rows `shouldBe` replicate 10 (T.pack ("held" ++ replicate 96 ' '))

  describe "A21: a write beside an open scan of the same table" $ do
    it "outside a transaction ends in a lock timeout (1222), not a deadlock, and the scan delivers every row" $
      withScanTable 30_000 $ \table -> withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- execute conn "SET LOCK_TIMEOUT 2000"
        scan <- scanStream conn table
        (rows, rest) <- takeRows 3 scan
        map fst rows `shouldBe` [1, 2, 3]
        -- The server is parked mid-scan with the rows' lock.
        _ <- waitHeldFull conn 0 (max 1 (connWindow conn - 4))
        (r, t) <- elapsed (try (execute conn (rawSql ("UPDATE " <> table <> " SET pad = 'y'"))))
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 1222
          Right n -> expectationFailure ("the write went through: " ++ show n ++ " rows")
        t `shouldSatisfy` (>= 1.5)
        t `shouldSatisfy` (< 30)
        -- The stream is intact and the write did nothing.
        S.length_ rest `shouldReturn` 29_997
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table <> " WHERE pad = 'y'")) `shouldReturn` Only (0 :: Int)
        expectClean conn

    it "another thread cannot read the scan while the write waits (one connection lock): the write times out, then the read goes on" $
      withScanTable 30_000 $ \table -> withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- execute conn "SET LOCK_TIMEOUT 2000"
        scan <- scanStream conn table
        (_, rest) <- takeRows 3 scan
        _ <- waitHeldFull conn 0 (max 1 (connWindow conn - 4))
        writing <- newEmptyMVar
        written <- newEmptyMVar
        -- Every exception is caught: if the test fails first, the
        -- connection is closed under the write, which then throws.
        _ <- forkIO $ do
          putMVar writing ()
          try @SomeException (execute conn (rawSql ("UPDATE " <> table <> " SET pad = 'z'"))) >>= putMVar written
        takeMVar writing
        threadDelay 200_000
        -- The read waits for the connection: the write holds it.
        (n, t) <- elapsed (S.length_ rest)
        n `shouldBe` 29_997
        t `shouldSatisfy` (>= 1.0)
        takeMVar written >>= \case
          Left e | Just err <- fromException e -> sqlErrorNumber err `shouldBe` 1222
          Left e -> throwIO e
          Right c -> expectationFailure ("the write went through: " ++ show c ++ " rows")
        expectClean conn

    it "inside one transaction it succeeds, and the scan reads on" $
      withScanTable 30_000 $ \table -> withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- execute conn "SET LOCK_TIMEOUT 2000"
        withTransaction conn $
          withQueryS conn (scanQuery table) $ \scan -> do
            (rows, rest) <- takeRows 3 (scan :: Stream (Of (Int32, Text)) IO ())
            map fst rows `shouldBe` [1, 2, 3]
            -- That it succeeds is the point: blocked by the scan, the write
            -- would wait for good and end in 1222 after LOCK_TIMEOUT.  (No
            -- time bound: the 30,000-row update itself took 5 s on Azure
            -- SQL S3, 22 s beside a whole-suite run.)
            r <- try @SqlServerError (execute conn (rawSql ("UPDATE " <> table <> " SET pad = 'y'")))
            either throwIO (`shouldBe` 30_000) r
            S.length_ rest `shouldReturn` 29_997
        query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table <> " WHERE pad = 'y'")) `shouldReturn` Only (30_000 :: Int)
        expectClean conn

    it "a write to another table succeeds beside the open scan" $
      withScanTable 30_000 $ \table -> withScanTable 100 $ \other -> withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- execute conn "SET LOCK_TIMEOUT 2000"
        scan <- scanStream conn table
        (_, rest) <- takeRows 3 scan
        (r, t) <- elapsed (try @SqlServerError (execute conn (rawSql ("UPDATE " <> other <> " SET pad = 'y'"))))
        either throwIO (`shouldBe` 100) r
        t `shouldSatisfy` (< 1.9)
        S.length_ rest `shouldReturn` 29_997
        expectClean conn

    it "a read of the same table succeeds beside the open scan: the N+1 pattern, one query per row" $
      withScanTable 30_000 $ \table -> withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- execute conn "SET LOCK_TIMEOUT 2000"
        withQueryS conn (scanQuery table) $ \scan -> do
          counted <- S.length_ $ S.mapM (\(i, _) -> do
            Only (c :: Int) <- query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table <> " WHERE id = " <> T.pack (show (i :: Int32))))
            when (c /= 1) $ expectationFailure ("no row " ++ show i)
            pure c) (S.take 300 (scan :: Stream (Of (Int32, Text)) IO ()))
          counted `shouldBe` 300
        expectClean conn
