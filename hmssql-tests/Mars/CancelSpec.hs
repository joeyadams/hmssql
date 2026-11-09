-- | 'cancelResponse' in every state a response can be in, and the rule that
-- settling is synchronous: when 'cancelResponse', 'cancelActiveStatement'
-- or an ordinary exit of 'withQueryS' returns, the statement is over on the
-- server and its locks are free; an interruption of 'withQueryS' doesn't
-- wait, and 'cancelActiveStatement' settles what it left
-- (docs/dev/design.md "MARS: several responses on one connection").
module Mars.CancelSpec (spec) where

import qualified RecipeState
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, wait, waitCatch, withAsync)
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.IORef (readIORef)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (elapsed, within)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (ActiveResponse (..))
import Hmssql.Errors
import Hmssql.Query (ResponseReader, cancelResponse)
import Hmssql.Transaction (begin, inTransaction, rollback)
import Mars.Harness
import OpenResponses (openResponses)
import TestDb

spec :: Spec
spec = do
  describe "cancelResponse" $ around withMarsConn $ do
    it "on a response read to its end does nothing: no Attention, the session stays free" $ \conn -> within 60 $ do
      (resp, s) <- startNumbers conn 5
      S.length_ s `shouldReturn` 5
      cancelResponse resp
      attentionSent resp `shouldReturn` False
      expectClean conn
      openSids conn `shouldReturn` [0]

    it "on a response that has all arrived but is unread sends no Attention, and the stream is abandoned" $ \conn -> within 60 $ do
      (resp, s) <- startNumbers conn 3
      waitFullyArrived resp
      busySids conn `shouldReturn` [0]
      cancelResponse resp
      attentionSent resp `shouldReturn` False
      busySids conn `shouldReturn` []
      expectAbandonedS s
      expectClean conn

    it "on a response that has all arrived and is half read sends no Attention" $ \conn -> within 60 $ do
      (resp, s) <- startNumbers conn 3
      waitFullyArrived resp
      (rows, rest) <- takeRows 1 s
      rows `shouldBe` [1]
      cancelResponse resp
      attentionSent resp `shouldReturn` False
      expectAbandonedS rest
      expectClean conn

    it "mid-stream sends an Attention, returns with the session free, and abandons the stream" $ \conn -> within 60 $ do
      (resp, s) <- startNumbers conn 1_000_000
      (rows, rest) <- takeRows 3 s
      rows `shouldBe` [1, 2, 3]
      busySids conn `shouldReturn` [0]
      cancelResponse resp
      attentionSent resp `shouldReturn` True
      busySids conn `shouldReturn` []
      expectAbandonedS rest
      expectClean conn
      -- The session is the same one again.
      openSids conn `shouldReturn` [0]

    it "parked at the window (nothing read) sends an Attention and returns promptly, with the session free" $ \conn -> within 60 $ do
      (resp, s) <- startRowReader conn (rawSql (wideRows 200_000)) :: IO (ResponseReader, Stream (Of (Int64, Text)) IO ())
      held <- waitHeldFull conn 0 (connWindow conn)
      held `shouldBe` connWindow conn
      (_, t) <- elapsed (cancelResponse resp)
      t `shouldSatisfy` (< 10)
      attentionSent resp `shouldReturn` True
      busySids conn `shouldReturn` []
      expectAbandonedS s
      expectClean conn

    it "twice: the second call does nothing" $ \conn -> within 60 $ do
      (resp, s) <- startNumbers conn 1_000_000
      _ <- takeRows 3 s
      cancelResponse resp
      cancelResponse resp
      attentionSent resp `shouldReturn` True
      busySids conn `shouldReturn` []
      -- A new response on the session is not cancelled by the old handle.
      (resp2, s2) <- startNumbers conn 1000
      busySids conn `shouldReturn` [0]
      cancelResponse resp
      busySids conn `shouldReturn` [0]
      S.length_ s2 `shouldReturn` 1000
      cancelResponse resp2
      expectAbandonedS s
      expectClean conn

    it "discards an error the response had withheld: no exception, session free" $ \conn -> within 60 $ do
      (resp, s) <- startRowReader conn "SELECT 1 UNION ALL SELECT 1 / 0" :: IO (ResponseReader, Stream (Of (Only Int)) IO ())
      waitFullyArrived resp
      cancelResponse resp
      busySids conn `shouldReturn` []
      expectAbandonedS s
      expectClean conn

    -- G24 of the MARS review: the drain skips nothing but the rows.
    it "applies the ENVCHANGEs of what it discards: a ROLLBACK in the unread part ends the transaction on the client too" $ \conn -> within 60 $ do
      begin conn
      inTransaction conn `shouldReturn` True
      (resp, s) <- startRowReader conn "SELECT 1 UNION ALL SELECT 2; IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; SELECT 3" :: IO (ResponseReader, Stream (Of (Only Int)) IO ())
      waitFullyArrived resp
      (rows, _) <- takeRows 1 s
      rows `shouldBe` [Only 1]
      cancelResponse resp
      attentionSent resp `shouldReturn` False
      -- The descriptor the unread rollback cleared is gone: the next request
      -- runs outside a transaction, and a new one can begin.
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT CAST(@@TRANCOUNT AS int)" `shouldReturn` Only (0 :: Int)
      withTransaction conn (query1 conn "SELECT 4") `shouldReturn` Only (4 :: Int)
      expectClean conn

    -- G22: the end-of-message count is per response, whether the
    -- acknowledgement of an Attention came in the cancelled response's last
    -- message or in one of its own.
    it "tells arrived from still arriving on a session reused after cancels (100 rounds)" $ \conn -> within 180 $ do
      forM_ [1 .. 100 :: Int] $ \_ -> do
        (big, sb) <- startNumbers conn 1_000_000
        _ <- takeRows 3 sb
        cancelResponse big
        attentionSent big `shouldReturn` True
        (small, _) <- startNumbers conn 3
        waitFullyArrived small
        cancelResponse small
        attentionSent small `shouldReturn` False
        openSids conn `shouldReturn` [0]
      expectClean conn

    it "right behind the request, before anything is read, returns with the session free" $ \conn -> within 60 $ do
      forM_ [1 .. 20 :: Int] $ \_ -> do
        (resp, s) <- startNumbers conn 1_000_000
        cancelResponse resp
        busySids conn `shouldReturn` []
        expectAbandonedS s
      expectClean conn
      openSids conn `shouldReturn` [0]

    it "while other responses are open: they continue and deliver every row, and the freed session is taken next" $ \conn -> within 120 $ do
      (a, sa) <- startNumbers conn 300_000
      (b, sb) <- startNumbers conn 300_000
      (c, sc) <- startNumbers conn 300_000
      busySids conn `shouldReturn` [0, 1, 2]
      -- Some rows of each, interleaved.
      (ra, sa') <- takeRows 1000 sa
      (rb, sb') <- takeRows 1000 sb
      (rc, sc') <- takeRows 1000 sc
      forM_ [ra, rb, rc] $ \rows -> rows `shouldBe` [1 .. 1000]
      cancelResponse b
      attentionSent b `shouldReturn` True
      attentionSent a `shouldReturn` False
      attentionSent c `shouldReturn` False
      busySids conn `shouldReturn` [0, 2]
      expectAbandonedS sb'
      -- The others carry on, from where they were.
      rows <- roundRobin [sa', sc'] $ \i n v ->
        when (v /= fromIntegral n + 1001) $ expectationFailure ("stream " ++ show i ++ " row " ++ show n ++ " is " ++ show v)
      rows `shouldBe` [299_000, 299_000]
      busySids conn `shouldReturn` []
      cancelResponse a
      cancelResponse c
      -- Session 1 was free: the next request took it.
      (_, s1) <- startNumbers conn 10
      (_, s2) <- startNumbers conn 10
      busySids conn `shouldReturn` [0, 1]
      _ <- S.length_ s1
      _ <- S.length_ s2
      expectClean conn

  describe "settling is synchronous: the statement's locks are free when the cancel returns" $ do
    let rows = 30_000 :: Int
        -- The rows are locked (a shared lock on the table under HOLDLOCK) while
        -- the statement runs.
        scan table = rawSql ("SELECT id, pad FROM " <> table <> " AS t WITH (TABLOCK, HOLDLOCK)")
        -- At lock-based READ COMMITTED whatever the database's
        -- READ_COMMITTED_SNAPSHOT (on in Azure SQL Database): under RCSI a
        -- scan reads row versions and holds no shared lock to free.
        plainScan table = rawSql ("SELECT id, pad FROM " <> table <> " WITH (READCOMMITTEDLOCK)")
        -- What the writer writes, and how many rows that is.  Every row,
        -- for a scan with READCOMMITTEDLOCK, whose shared lock is wherever it
        -- is parked.  One row, for a scan holding a shared lock on the table
        -- (TABLOCK, HOLDLOCK), which refuses the write's IX lock on the table
        -- whatever the row.  One row costs one row's log, not 30,000 rows':
        -- on Azure SQL Database (S3, at 100% of its log rate under the whole
        -- suite) a write of every row took 37 s, and the tests that cancel
        -- five times overran their 60 s.
        everyRow = ("", rows)
        oneRow = (" WHERE id = 1", 1 :: Int)
        write (cond, _) other table = try @SqlServerError $
          execute other (rawSql ("SET LOCK_TIMEOUT 0; UPDATE " <> table <> " SET pad = 'w'" <> cond <> "; SET LOCK_TIMEOUT -1"))
        -- A writer on another connection that must not wait: it is refused
        -- while the statement runs, and succeeds at the first try once it is
        -- over.
        blockedWhileOpen w other table = write w other table >>= \case
          Left e -> sqlErrorNumber e `shouldBe` 1222
          Right n -> expectationFailure ("the write got through while the statement ran: " ++ show n)
        freeAtOnce w other table = write w other table >>= \case
          Right n -> n `shouldBe` fromIntegral (snd w)
          Left e -> expectationFailure ("still blocked when the scope returned: " ++ show e)
        setup act = withScanTable rows $ \table -> withMarsConn $ \conn -> withTestDb $ \other -> within 60 $
          act table conn other `finally` void (try @SomeException (execute other "SET LOCK_TIMEOUT -1"))

    it "withQueryS over a scan that holds a table lock: free when the scope ends" $ setup $ \table conn other -> do
      withQueryS conn (scan table) $ \s -> do
        (r, _) <- takeRows 3 (s :: Stream (Of (Int32, Text)) IO ())
        map fst r `shouldBe` [1, 2, 3]
        blockedWhileOpen oneRow other table
      freeAtOnce oneRow other table
      expectClean conn

    it "withQueryS over a plain READ COMMITTED scan: free when the scope ends" $ setup $ \table conn other -> do
      withQueryS conn (plainScan table) $ \s -> do
        _ <- takeRows 3 (s :: Stream (Of (Int32, Text)) IO ())
        -- All but a few of the window: the rows taken freed some.
        _ <- waitHeldFull conn 0 (max 1 (connWindow conn - 4))
        blockedWhileOpen everyRow other table
      freeAtOnce everyRow other table
      expectClean conn

    it "withQueryS under REPEATABLE READ: free when the scope ends" $ setup $ \table conn other -> do
      _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
      withQueryS conn (plainScan table) $ \s -> do
        _ <- takeRows 3 (s :: Stream (Of (Int32, Text)) IO ())
        -- All but a few of the window: the rows taken freed some.
        _ <- waitHeldFull conn 0 (max 1 (connWindow conn - 4))
        blockedWhileOpen everyRow other table
      freeAtOnce everyRow other table
      _ <- execute conn "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
      expectClean conn

    it "withQueryS left by an exception: free by the time it propagates" $ setup $ \table conn other -> do
      r <- try @ErrorCall $ withQueryS conn (scan table) $ \s -> do
        _ <- takeRows 3 (s :: Stream (Of (Int32, Text)) IO ())
        blockedWhileOpen oneRow other table
        throwIO (ErrorCall "leaving")
      r `shouldBe` (Left (ErrorCall "leaving") :: Either ErrorCall ())
      freeAtOnce oneRow other table
      expectClean conn

    it "cancelResponse: free when it returns" $ setup $ \table conn other -> do
      (resp, s) <- startRowReader conn (scan table) :: IO (ResponseReader, Stream (Of (Int32, Text)) IO ())
      _ <- takeRows 3 s
      blockedWhileOpen oneRow other table
      cancelResponse resp
      freeAtOnce oneRow other table
      expectClean conn

    it "cancelResponse right behind the request, nothing read: free when it returns" $ setup $ \table conn other -> do
      forM_ [1 .. 5 :: Int] $ \_ -> do
        (resp, _) <- startRowReader conn (scan table) :: IO (ResponseReader, Stream (Of (Int32, Text)) IO ())
        cancelResponse resp
        freeAtOnce oneRow other table
      expectClean conn

    it "withQueryS whose body reads nothing: free when the scope ends" $ setup $ \table conn other -> do
      forM_ [1 .. 5 :: Int] $ \_ -> do
        withQueryS conn (scan table) $ \s -> void (pure (s :: Stream (Of (Int32, Text)) IO ()))
        freeAtOnce oneRow other table
      expectClean conn

    -- An interruption doesn't wait for the server (docs/dev/design.md
    -- "Interruption and cancellation"): the timeout returns with the
    -- Attention sent and the response still busy, left for the next
    -- operation to drain; 'cancelActiveStatement' is that operation here,
    -- and only once it returns is the statement gone from the server.
    it "a timeout around withQueryS whose body waits on a WAITFOR returns before the statement has ended; cancelActiveStatement settles it" $ \_ ->
      withObserver $ \obs -> withMarsConn $ \conn -> within 60 $ do
        spid <- spidOf conn
        -- The body waits for the first row, behind the WAITFOR.
        (r, t) <- elapsed $ timeout 300_000 $
          withQueryS conn "WAITFOR DELAY '00:00:04'; SELECT CAST(1 AS bigint)" $ \s ->
            S.length_ (s :: Stream (Of (Only Int64)) IO ())
        r `shouldBe` Nothing
        -- Cancelled at once, drained by nobody yet.
        [sid] <- busySids conn
        [ar] <- openResponses conn
        RecipeState.attentionSent ar `shouldReturn` True
        (_, t2) <- elapsed (cancelActiveStatement conn)
        -- Over on the server by the time the cancel returned.
        observerSees obs spid `shouldReturn` []
        busySids conn `shouldReturn` []
        expectClean conn
        putStrLn ("    [timeout around withQueryS over WAITFOR 4 s: returned after " ++ seconds t
          ++ ", session " ++ show sid ++ " settled by cancelActiveStatement in " ++ seconds t2 ++ "]")

    -- The same over a lock wait, with the interruption sent once the server
    -- shows the statement waiting for the lock, not after a fixed time: SQL
    -- Server 2025 ignores an Attention that arrives before the statement is
    -- under way, and acknowledges it only when the statement ends, here
    -- when the holder's lock goes (docs/dev/protocol-notes.md, "MARS and
    -- SMP"); a loaded server took 300 ms to get there, and the test hung
    -- for its whole bound ("The server under load").  Sent during the lock
    -- wait, an Attention was never seen ignored (0 in 120).
    --
    -- Should one be ignored all the same, 'cancelActiveStatement' waits as
    -- long, which is its contract (it returns once the statement is over;
    -- docs/dev/limitations.md, "Behaviours to know about"), and the test
    -- states that consequence rather than hanging: if the cancel hasn't
    -- returned after 10 s (0.3 s is usual), the Attention must have been
    -- sent and taken in by the server (its SMP window past it); if the
    -- statement is still waiting for the lock, the holder rolls back; and
    -- the cancel must then return with the statement over.
    it "an interruption of withQueryS over a statement waiting for a lock returns before it has ended; cancelActiveStatement waits for it" $ \_ ->
      withObserver $ \obs -> withMarsConn $ \conn -> do
       ident <- sessionIdentity conn
       step <- newSteps "start"
       let at = markStep step
       withinTraced 120 conn ident step $ do
        spid <- spidOf conn
        -- The read is lock-based, or under RCSI it wouldn't wait.
        at "creating the table"
        withScanTable 100 $ \table -> withTestDb $ \holder -> do
          at "the holder's UPDATE"
          bracket_ (begin holder) (inTransaction holder >>= \open -> when open (rollback holder)) $ do
            _ <- execute holder (rawSql ("UPDATE " <> table <> " SET pad = 'held'"))
            at "withQueryS, until the statement waits for the lock"
            reader <- async $ withQueryS conn (rawSql ("SELECT id FROM " <> table <> " WITH (READCOMMITTEDLOCK)")) $ \s ->
              S.length_ (s :: Stream (Of (Only Int32)) IO ())
            awaitLockWait obs spid
            at "the interruption"
            (_, t) <- elapsed (cancel reader)
            waitCatch reader >>= \case
              Left e | Just AsyncCancelled <- fromException e -> pure ()
              other -> expectationFailure ("expected the interruption, got " ++ show (() <$ other))
            [sid] <- busySids conn
            [ar] <- openResponses conn
            RecipeState.attentionSent ar `shouldReturn` True
            at "cancelActiveStatement"
            withAsync (elapsed (cancelActiveStatement conn)) $ \canceller -> do
              settled <- timeout 10_000_000 (waitCatch canceller)
              t2 <- case settled of
                Just r -> either throwIO (pure . snd) r
                Nothing -> do
                  at "the server ignoring the Attention"
                  takenIn <- waitUntil 10 (attentionTakenIn conn sid)
                  unless takenIn $ expectationFailure
                    "the server's window never moved past the Attention: it wasn't sent, or the server didn't read it"
                  waiting <- waitingForLock obs spid
                  when waiting $ do
                    at "the holder's rollback"
                    rollback holder
                    hPutStrLn stderr ("    [the server took the Attention in and didn't act on it for 10 s, "
                      ++ "until the lock was released; cancelActiveStatement then returned]")
                  at "cancelActiveStatement, after the look"
                  snd <$> wait canceller
              at "the observer's look"
              observerSees obs spid `shouldReturn` []
              busySids conn `shouldReturn` []
              putStrLn ("    [interruption of withQueryS over a lock wait: returned after " ++ seconds t
                ++ ", settled by cancelActiveStatement in " ++ seconds t2 ++ "]")
          at "the end"
          expectClean conn

