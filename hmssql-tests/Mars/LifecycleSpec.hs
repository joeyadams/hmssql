{-# LANGUAGE ViewPatterns #-}
-- | Interruption and the connection's lifecycle with several responses open
-- (docs/dev/design.md "MARS: several responses on one connection"): an
-- interrupted pull, 'cancelActiveStatement',
-- 'release' and 'renew', 'close', a server-side @KILL@, info-message
-- callbacks on any session, batch queries beside a stream, and a dropped
-- connection being collected.
module Mars.LifecycleSpec (spec) where

import UnusableCause (reasonCause, brokenCause)
import Control.Concurrent
import Control.Exception
import Control.Monad (forM, forM_, void, when)
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (elapsed, sessionCount, uniqueAppName, waitForSessionCount, within)
import Hmssql
import Hmssql.BatchQuery
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors
import Hmssql.Transaction (TransactionError (..))
import Hmssql.Types (ServerMessage (..))
import Mars.Harness
import TestDb

-- | The server closed the connection: EOF, a reset, or a severe error.
isServerClose :: SomeException -> Bool
isServerClose e = case fromException e of
  Just ConnectionClosed -> True
  Nothing -> case fromException e of
    Just se -> msgClass (sqlError se) >= 20
    Nothing -> case fromException e of
      Just SevereError{} -> True
      Nothing -> False

-- | A reader that came after the one that saw the close: the connection is
-- broken, by the server's close.
isBrokenByServerClose :: SomeException -> Bool
isBrokenByServerClose e = case fromException e of
  Just (ConnectionBroken (reasonCause -> cause)) -> isServerClose cause
  Nothing -> False

numsOf :: Connection -> Int -> IO (Stream (Of Int64) IO ())
numsOf = numStream

spec :: Spec
spec = do
  describe "an interrupted pull" $ do
    it "on one stream leaves the others readable; the interrupted one is abandoned, and the next request drains it" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        b <- numsOf conn 300_000
        (rb, b') <- takeRows 1000 b
        rb `shouldBe` [1 .. 1000]
        -- A stream that has nothing to read for a while: the WAITFOR is on the server.
        a <- queryS conn "WAITFOR DELAY '00:00:03'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
        busySids conn `shouldReturn` [0, 1]
        r <- timeout 300_000 (S.length_ a)
        r `shouldBe` Nothing
        -- The interrupted read sent the Attention; the response is still the
        -- session's until the next request drains it.
        busySids conn `shouldReturn` [0, 1]
        query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)
        -- Drained: session 1 is free (and was used again); stream b is unharmed.
        busySids conn `shouldReturn` [0]
        expectAbandonedS a
        rows <- roundRobin [b'] $ \_ n v ->
          when (v /= fromIntegral n + 1001) $ expectationFailure ("row " ++ show n ++ " is " ++ show v)
        rows `shouldBe` [299_000]
        expectClean conn

    it "on the first stream leaves a later one readable" $ withMarsConn $ \conn -> withinMoving 60 conn $ do
      a <- queryS conn "WAITFOR DELAY '00:00:03'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
      b <- numsOf conn 100_000
      r <- timeout 300_000 (S.length_ a)
      r `shouldBe` Nothing
      -- b's rows had been sent before the WAITFOR? Not necessarily: it is
      -- readable once the Attention has ended the WAITFOR.
      S.length_ b `shouldReturn` 100_000
      expectAbandonedS a
      -- Cancelled but not drained: session 0 is busy until the next request.
      busySids conn `shouldReturn` [0]
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      expectClean conn

    -- G23 of the MARS review: the drain doesn't depend on which session
    -- the next request takes.
    it "is drained by the next request when that request takes another session" $ withMarsConn $ \conn -> withinMoving 60 conn $ do
      first <- numsOf conn 10
      a <- queryS conn "WAITFOR DELAY '00:00:03'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
      busySids conn `shouldReturn` [0, 1]
      timeout 300_000 (S.length_ a) >>= (`shouldBe` Nothing)
      -- Session 0 is freed; session 1 is cancelled and undrained.
      S.length_ first `shouldReturn` 10
      busySids conn `shouldReturn` [1]
      -- The next request takes session 0, the lowest idle one, and drains
      -- session 1 first.
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0, 1]
      expectAbandonedS a
      expectClean conn

    it "leaves the connection usable and the statement cancelled on the server, 20 times over" $
      withMarsConn $ \conn -> withinMoving 120 conn $ do
        keep <- numsOf conn 1_000_000
        _ <- takeRows 3 keep
        forM_ [1 .. 20 :: Int] $ \_ -> do
          a <- queryS conn "WAITFOR DELAY '00:00:03'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
          timeout 50_000 (S.length_ a) >>= (`shouldBe` Nothing)
          query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
          expectAbandonedS a
        busySids conn `shouldReturn` [0]
        openSids conn `shouldReturn` [0, 1]

  -- G29 of the MARS review: broken is the connection's, not a session's.
  describe "an interrupted send" $
    it "breaks the whole connection: a stream open on another session throws ConnectionBroken, as does every later request" $
      withMarsConn $ \conn -> withinMoving 120 conn $ do
        keep <- numsOf conn 1_000_000
        (rows, keep') <- takeRows 3 keep
        rows `shouldBe` [1, 2, 3]
        let payload = B.replicate 8_000_000 0x61
            interruptSend n
              | n >= (20 :: Int) = expectationFailure "no timeout landed in the send in 20 tries"
              | otherwise = do
                  r <- try @SomeException $ timeout 5_000 $
                    query1 conn (mkQuery "SELECT DATALENGTH(@p1)" (Only payload)) :: IO (Either SomeException (Maybe (Only Int)))
                  broken <- brokenCause conn
                  case broken of
                    Just _ -> pure ()
                    Nothing -> do
                      -- The send finished and the read was interrupted:
                      -- usable; try again.
                      r `shouldSatisfy` either (const False) (const True)
                      interruptSend (n + 1)
        interruptSend 0
        try (S.length_ keep') >>= \case
          Left (ConnectionBroken _) -> pure ()
          Right n -> expectationFailure ("the other session's stream read on: " ++ show n ++ " rows")
        try (query1 conn "SELECT 1" :: IO (Only Int)) >>= \case
          Left (ConnectionBroken _) -> pure ()
          Right v -> expectationFailure ("a request after the broken send ran: " ++ show v)

  describe "cancelActiveStatement" $ do
    it "cancels every open stream: each is abandoned, no session is busy, the connection works" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        streams <- mapM (const (numsOf conn 1_000_000)) [1 .. 4 :: Int]
        forM_ streams $ \s -> takeRows 3 s
        busySids conn `shouldReturn` [0, 1, 2, 3]
        cancelActiveStatement conn
        busySids conn `shouldReturn` []
        forM_ streams expectAbandonedS
        expectClean conn

    it "cancels streams parked at their window, and streams that have all arrived" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        parked <- queryS conn (rawSql (wideRows 100_000)) :: IO (Stream (Of (Int64, Text)) IO ())
        small <- numsOf conn 5
        _ <- waitHeldFull conn 0 (connWindow conn)
        cancelActiveStatement conn
        busySids conn `shouldReturn` []
        expectAbandonedS parked
        expectAbandonedS small
        expectClean conn

    it "is a no-op with every stream read to its end" $ withMarsConn $ \conn -> withinMoving 60 conn $ do
      numsOf conn 100 >>= S.length_ >>= (`shouldBe` 100)
      cancelActiveStatement conn
      busySids conn `shouldReturn` []
      expectClean conn

  describe "release and renew with streams open" $ do
    it "release returns True, settles every response, the old handle's readers throw ConnectionReleased, the renewed handle works" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        streams <- mapM (const (numsOf conn 1_000_000)) [1 .. 3 :: Int]
        forM_ streams $ \s -> takeRows 3 s
        busySids conn `shouldReturn` [0, 1, 2]
        release conn `shouldReturn` True
        -- Settled: nothing busy, whatever the handle.
        busySids conn `shouldReturn` []
        forM_ streams $ \s -> within 10 (try (S.length_ s)) >>= \case
          Left ConnectionReleased -> pure ()
          Right n -> expectationFailure ("a stale stream gave " ++ show n ++ " rows")
        within 10 (try (query1 conn "SELECT 1" :: IO (Only Int))) >>= \case
          Left ConnectionReleased -> pure ()
          Right r -> expectationFailure ("the released handle answered: " ++ show r)
        conn' <- renew conn
        query1 conn' "SELECT 2" `shouldReturn` Only (2 :: Int)
        -- The old streams still refuse, and the new handle streams on.
        forM_ streams $ \s -> within 10 (try (S.length_ s)) >>= \case
          Left ConnectionReleased -> pure ()
          Right n -> expectationFailure ("a stale stream gave " ++ show n ++ " rows")
        numsOf conn' 1000 >>= S.length_ >>= (`shouldBe` 1000)
        expectClean conn'

    it "release with a stream parked at its window and another that has all arrived" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        _ <- queryS conn (rawSql (wideRows 100_000)) :: IO (Stream (Of (Int64, Text)) IO ())
        _ <- numsOf conn 5
        _ <- waitHeldFull conn 0 (connWindow conn)
        release conn `shouldReturn` True
        conn' <- renew conn
        busySids conn' `shouldReturn` []
        expectClean conn'

    it "a released connection's statements are over on the server: another connection can take their locks at once" $
      withScanTable 30_000 $ \table -> withMarsConn $ \conn -> withTestDb $ \other -> withinMoving 60 conn $ do
        s <- queryS conn (rawSql ("SELECT id, pad FROM " <> table <> " AS t WITH (TABLOCK, HOLDLOCK)")) :: IO (Stream (Of (Int, Text)) IO ())
        _ <- takeRows 3 s
        release conn `shouldReturn` True
        n <- execute other (rawSql ("SET LOCK_TIMEOUT 0; UPDATE " <> table <> " SET pad = 'w'; SET LOCK_TIMEOUT -1"))
        n `shouldBe` 30_000
        conn' <- renew conn
        expectClean conn'

  describe "close" $ do
    it "with readers blocked on several sessions in other threads: each gets ConnectionClosed" $ do
      ci <- marsInfo
      conn <- connect ci
      streams <- forM [1 .. 3 :: Int] $ \_ ->
        queryS conn "WAITFOR DELAY '00:00:10'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
      busySids conn `shouldReturn` [0, 1, 2]
      results <- forM streams $ \s -> do
        r <- newEmptyMVar
        _ <- forkIO $ try @SomeException (S.length_ s) >>= putMVar r
        pure r
      threadDelay 300_000
      (_, t) <- elapsed (close conn)
      t `shouldSatisfy` (< 5)
      forM_ results $ \r -> within 10 (takeMVar r) >>= \case
        Left e | Just ConnectionClosed <- fromException e -> pure ()
        other -> expectationFailure ("expected ConnectionClosed, got " ++ show other)
      -- Closed for good, for any use.
      within 10 (try (query1 conn "SELECT 1" :: IO (Only Int))) >>= \case
        Left ConnectionClosed -> pure ()
        Right r -> expectationFailure ("a closed connection answered " ++ show r)

    it "with streams open and nobody reading, and again afterwards: harmless, and the server session ends" $ do
      app <- uniqueAppName "mars_close_open"
      ci <- marsInfo
      conn <- connect ci { connectApplicationName = app }
      forM_ [1 .. 4 :: Int] $ \_ -> numsOf conn 1_000_000
      sessionCount app `shouldReturn` 1
      close conn
      close conn
      waitForSessionCount 10 (pure ()) app 0 `shouldReturn` 0

  describe "a server-side KILL" $ do
    it "with streams open: every reader gets ConnectionClosed (or the severe error), later requests ConnectionBroken" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        spid <- sessionIdentity conn
        streams <- mapM (const (queryS conn (rawSql (wideRows 100_000)) :: IO (Stream (Of (Int64, Text)) IO ()))) [1 .. 3 :: Int]
        _ <- waitHeldFull conn 0 (connWindow conn)
        kill spid
        threadDelay 500_000
        forM_ streams $ \s -> within 30 (try @SomeException (S.length_ s)) >>= \case
          Left e | isServerClose e || isBrokenByServerClose e -> pure ()
          other -> expectationFailure ("expected the server's close, got " ++ either show (const "rows") other)
        within 10 (try (query1 conn "SELECT 1" :: IO (Only Int))) >>= \case
          Left (ConnectionBroken (reasonCause -> cause)) | isServerClose cause -> pure ()
          Left e -> expectationFailure ("expected ConnectionBroken, got " ++ show e)
          Right r -> expectationFailure ("a killed connection answered " ++ show r)

    it "with readers blocked on several sessions in other threads: each gets the server's close" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        spid <- sessionIdentity conn
        streams <- forM [1 .. 3 :: Int] $ \_ ->
          queryS conn "WAITFOR DELAY '00:00:10'; SELECT CAST(1 AS bigint)" :: IO (Stream (Of (Only Int64)) IO ())
        results <- forM streams $ \s -> do
          r <- newEmptyMVar
          _ <- forkIO $ try @SomeException (S.length_ s) >>= putMVar r
          pure r
        threadDelay 300_000
        kill spid
        -- The requests queued behind the killed WAITFOR on the server may also
        -- fail with 3980 (the batch is aborted), before the close arrives.
        let queuedBehind e = maybe False ((== 3980) . msgNumber . sqlError) (fromException e)
        forM_ results $ \r -> within 30 (takeMVar r) >>= \case
          Left e | isServerClose e || isBrokenByServerClose e || queuedBehind e -> pure ()
          other -> expectationFailure ("expected the server's close, got " ++ show other)

    it "while idle sessions are open: the next request notices" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        spid <- sessionIdentity conn
        streams <- mapM (const (numsOf conn 100)) [1 .. 3 :: Int]
        forM_ streams $ \s -> void (S.length_ s)
        kill spid
        threadDelay 500_000
        within 10 (try (query1 conn "SELECT 1" :: IO (Only Int))) >>= \case
          Left e | isServerClose e || isBrokenByServerClose e -> pure ()
          other -> expectationFailure ("expected the server's close, got " ++ show other)

  describe "info-message callbacks" $ do
    it "PRINTs arriving on any session reach the callback once, when that session's response is read" $ do
      seen <- newIORef ([] :: [Text])
      ci <- marsInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' seen (msgText m :) } $ \conn -> withinMoving 60 conn $ do
        -- What the login said (the language and database context) is not ours.
        writeIORef seen []
        let tagged tag = "PRINT '" <> tag <> "'; SELECT TOP 20000 CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        s0 <- queryS conn (tagged "zero") :: IO (Stream (Of (Only Int64)) IO ())
        s1 <- queryS conn (tagged "one") :: IO (Stream (Of (Only Int64)) IO ())
        s2 <- queryS conn (tagged "two") :: IO (Stream (Of (Only Int64)) IO ())
        busySids conn `shouldReturn` [0, 1, 2]
        -- Nothing is read yet: the messages have arrived but are not delivered.
        threadDelay 300_000
        readIORef seen `shouldReturn` []
        -- Reading the middle one delivers its message and no other.
        (_, s1') <- takeRows 1 s1
        readIORef seen `shouldReturn` ["one"]
        (_, s2') <- takeRows 1 s2
        (_, s0') <- takeRows 1 s0
        readIORef seen >>= (`shouldBe` ["zero", "two", "one"])
        rows <- roundRobin [s0', s1', s2'] (\_ _ _ -> pure ())
        rows `shouldBe` [19_999, 19_999, 19_999]
        readIORef seen >>= (`shouldBe` ["zero", "two", "one"])
        -- A request on yet another session: its own PRINT, once.
        query1 conn "PRINT 'three'; SELECT 3" `shouldReturn` Only (3 :: Int)
        readIORef seen >>= (`shouldBe` ["three", "zero", "two", "one"])
        expectClean conn

    it "a PRINT on a second session while a stream on the first is open" $ do
      seen <- newIORef ([] :: [Text])
      ci <- marsInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' seen (msgText m :) } $ \conn -> withinMoving 60 conn $ do
        writeIORef seen []
        s <- numsOf conn 100_000
        _ <- takeRows 5 s
        forM_ [1 .. 5 :: Int] $ \i -> do
          _ <- execute conn (rawSql ("PRINT 'n" <> T.pack (show i) <> "'"))
          pure ()
        openSids conn `shouldReturn` [0, 1]
        reverse <$> readIORef seen `shouldReturn` ["n1", "n2", "n3", "n4", "n5"]
        cancelActiveStatement conn

    it "a callback that uses the connection gets ReentrantCallback, on any session, and the response is unharmed" $ do
      refused <- newIORef (0 :: Int)
      connRef <- newIORef Nothing
      ci <- marsInfo
      let onInfo _ = readIORef connRef >>= mapM_ (\c -> do
            r <- try (query1 c "SELECT 1" :: IO (Only Int))
            case r of
              Left ReentrantCallback -> modifyIORef' refused (+ 1)
              Right _ -> pure ()
            r2 <- try (S.length_ =<< numStream c 10)
            case r2 of
              Left ReentrantCallback -> modifyIORef' refused (+ 1)
              Right _ -> pure ())
      withConnection ci { connectOnInfoMessage = onInfo } $ \conn -> withinMoving 60 conn $ do
        writeIORef connRef (Just conn)
        -- On session 0 with a stream open on it? The PRINT arrives on session 1.
        s <- numsOf conn 100_000
        (_, rest) <- takeRows 5 s
        query1 conn "PRINT 'x'; SELECT 2" `shouldReturn` Only (2 :: Int)
        readIORef refused `shouldReturn` 2
        openSids conn `shouldReturn` [0, 1]
        -- And the stream is intact.
        writeIORef connRef Nothing
        S.length_ (S.take 10 rest) `shouldReturn` 10
        cancelActiveStatement conn
        expectClean conn

  describe "batch queries beside an open stream" $ do
    it "runBatchQuery and executeStatements run while a stream is open, and the stream reads on" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        withNums conn 100_000 $ \s -> do
          (first, rest) <- takeRows 10 s
          first `shouldBe` [1 .. 10]
          (_, Only total, rows) <- runBatchQuery conn $ (,,)
            <$> batchExecute "DECLARE @x int = 1"
            <*> batchQuery1 "SELECT CAST(42 AS int)"
            <*> batchQuery "SELECT 1 UNION ALL SELECT 2"
          total `shouldBe` (42 :: Int)
          rows `shouldBe` [Only (1 :: Int), Only 2]
          counts <- executeStatements conn ["DECLARE @y int = 2", "DECLARE @z int = 3"]
          length counts `shouldBe` 2
          openSids conn >>= (`shouldSatisfy` (\sids -> 0 `elem` sids && length sids >= 2))
          busySids conn `shouldReturn` [0]
          S.length_ rest `shouldReturn` 99_990
        expectClean conn

    it "a batchQueryS stream beside another stream: both deliver every row" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        withNums conn 50_000 $ \a -> do
          (_, a') <- takeRows 3 a
          b <- runBatchQuery conn $ batchQueryS (rawSql (numbers 50_000))
          rows <- roundRobin [a', S.map fromOnly b] $ \_ _ _ -> pure ()
          rows `shouldBe` [49_997, 50_000]
        busySids conn `shouldReturn` []

    -- R22 of the MARS review: a batch's statement readers never reach the
    -- caller, so its stream is cancelled with the connection's others.
    it "a batchQueryS stream left open is named by its last statement, and cancelActiveStatement ends it" $
      withMarsConn $ \conn -> withinMoving 60 conn $ do
        let sql = numbers 1_000_000
        s <- runBatchQuery conn $ batchExecute "DECLARE @x int = 1" *> batchQueryS (rawSql sql)
        (rows, rest) <- takeRows 3 (S.map fromOnly s :: Stream (Of Int64) IO ())
        rows `shouldBe` [1, 2, 3]
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
        busySids conn `shouldReturn` [0]
        try (withTransaction conn (pure ())) >>= \case
          -- The last statement's text: the one the stream reads.
          Left (TransactionRequestsActive stmts) -> stmts `shouldBe` [sql]
          other -> expectationFailure ("expected TransactionRequestsActive, got " ++ show other)
        cancelActiveStatement conn
        busySids conn `shouldReturn` []
        expectAbandonedS rest
        expectClean conn

  describe "a dropped connection" $
    it "with open sessions is garbage collected, and its socket closed (the server's session ends)" $ do
      app <- uniqueAppName "mars_gc"
      ci <- marsInfo
      openStreamsAndDrop ci { connectApplicationName = app } app
      waitForSessionCount 20 performMajorGC app 0 `shouldReturn` 0
  where
    kill = killSession

-- | Open a MARS connection, leave several streams open on it, and let it go
-- once the server shows its session.  Not inlined, so nothing in the caller
-- keeps it alive.
openStreamsAndDrop :: ConnectInfo -> Text -> IO ()
openStreamsAndDrop ci app = do
  conn <- connect ci
  streams <- mapM (const (numStream conn 1_000_000)) [1 .. 4 :: Int]
  forM_ streams $ \s -> takeRows 3 s
  sessionCount app `shouldReturn` 1
  busySids conn `shouldReturn` [0, 1, 2, 3]
  pure ()
{-# NOINLINE openStreamsAndDrop #-}
