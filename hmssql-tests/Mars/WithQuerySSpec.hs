-- | 'withQueryS': the scope of a stream on a MARS connection, however it is
-- left (returning, an early exit, an exception, an asynchronous exception),
-- nested, and with the stream handed to another thread.  An ordinary exit
-- leaves nothing behind; an interruption cancels the statement at once
-- and leaves the drain to the next operation ('cancelActiveStatement'
-- here), and the leaked stream throws 'ResultAbandoned'.
module Mars.WithQuerySSpec (spec) where

import UnusableCause (brokenCause)
import qualified RecipeState
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_)
import Data.Int (Int64)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Data.IORef (newIORef, readIORef, writeIORef)

import Concurrency.Harness (Interrupt (..), elapsed, expectBrokenBy, expectUsable, isInterrupt, within)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (ActiveResponse (..), Session (..), allSessions)
import Hmssql.Errors
import Hmssql.Decoding (fieldDecoder, singleFieldM)
import Hmssql.Query (withQuerySMWith, withQuerySWith)
import Hmssql.Transaction (inTransaction)
import Mars.Harness
import TestDb (sessionIdentity, testServerIsAzure)
import OpenResponses (connectionBroken, openResponses)

-- | After an interruption of a scope: one response is left on the
-- connection, cancelled (its Attention sent) and abandoned, for the next
-- operation to drain.
leftCancelled :: Connection -> IO ()
leftCancelled conn = do
  length <$> busySids conn `shouldReturn` 1
  [ar] <- openResponses conn
  RecipeState.attentionSent ar `shouldReturn` True
  RecipeState.abandoned ar `shouldReturn` True

spec :: Spec
spec = around withMarsConn $ do
  describe "leaving the scope" $ do
    it "normally, after reading the stream to its end: returns the body's value, the session is free" $ \conn -> within 60 $ do
      r <- withNums conn 1000 $ \s -> do
        busySids conn `shouldReturn` [0]
        S.length_ s
      r `shouldBe` 1000
      expectClean conn

    it "without reading anything: the response is cancelled, the session is free" $ \conn -> within 60 $ do
      forM_ [1 .. 20 :: Int] $ \_ ->
        withNums conn 1_000_000 $ \_ -> busySids conn `shouldReturn` [0]
      expectClean conn
      openSids conn `shouldReturn` [0]

    it "early, with the stream unfinished: the rest is cancelled, and a later read of the leaked stream throws ResultAbandoned" $ \conn -> within 60 $ do
      (rows, leaked) <- withNums conn 1_000_000 $ \s -> do
        (rows, rest) <- takeRows 10 s
        pure (rows, rest)
      rows `shouldBe` [1 .. 10]
      busySids conn `shouldReturn` []
      expectAbandonedS leaked
      -- Again: still abandoned, not the rows.
      expectAbandonedS leaked
      expectClean conn

    it "early, with the stream read to the last row but not past it" $ \conn -> within 60 $ do
      leaked <- withNums conn 3 $ \s -> snd <$> takeRows 3 s
      busySids conn `shouldReturn` []
      -- Nothing is left to read: the stream ends, or is abandoned; never rows.
      r <- try (S.length_ leaked)
      case r of
        Right n -> n `shouldBe` 0
        Left ResultAbandoned -> pure ()
      expectClean conn

    it "with an error in the stream: the error reaches the body, the scope still ends cleanly" $ \conn -> within 60 $ do
      r <- try $ withQueryS conn "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 1 / 0" $ \s ->
        S.length_ (s :: Stream (Of (Only Int)) IO ())
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8134
        Right n -> expectationFailure ("no error after " ++ show n ++ " rows")
      expectClean conn

    it "with a query that can't be sent (an unbound placeholder): the error, and no session taken" $ \conn -> within 60 $ do
      r <- try $ withQueryS conn (mkQuery "SELECT @p1, @p2" (Only (1 :: Int))) $ \s -> S.length_ (s :: Stream (Of (Int, Int)) IO ())
      case r of
        Left (EncodeError _) -> pure ()
        Right n -> expectationFailure ("returned " ++ show n)
      busySids conn `shouldReturn` []
      openSids conn `shouldReturn` [0]

    it "with a decoding error in the body's stream: reported, the scope ends cleanly" $ \conn -> within 60 $ do
      r <- try $ withQueryS conn (rawSql "SELECT 'not a number' UNION ALL SELECT 'x'") $ \s ->
        S.length_ (s :: Stream (Of (Only Int)) IO ())
      case r of
        Left (_ :: SomeException) -> pure ()
        Right n -> expectationFailure ("decoded " ++ show n ++ " rows")
      expectClean conn

    it "withQuerySWith behaves alike (a decoder of its own)" $ \conn -> within 60 $ do
      (n, leaked) <- withQuerySWith (fromOnly <$> rowDecoder) conn (rawSql (numbers 1_000_000)) $ \s -> do
        (rows, rest) <- takeRows 5 (s :: Stream (Of Int64) IO ())
        rows `shouldBe` [1 .. 5]
        busySids conn `shouldReturn` [0]
        pure (length rows, rest)
      n `shouldBe` 5
      busySids conn `shouldReturn` []
      expectAbandonedS leaked

    it "withQuerySMWith behaves alike (a per-row decoder)" $ \conn -> within 60 $ do
      (n, leaked) <- withQuerySMWith (singleFieldM fieldDecoder) conn (rawSql (numbers 1_000_000)) $ \s -> do
        (rows, rest) <- takeRows 5 (s :: Stream (Of Int64) IO ())
        rows `shouldBe` [1 .. 5]
        busySids conn `shouldReturn` [0]
        pure (length rows, rest)
      n `shouldBe` 5
      busySids conn `shouldReturn` []
      expectAbandonedS leaked

  describe "exceptions in the body" $ do
    it "a synchronous exception is rethrown after the stream is cancelled" $ \conn -> within 60 $ do
      r <- try @ErrorCall $ withNums conn 1_000_000 $ \s -> do
        _ <- takeRows 3 s
        busySids conn `shouldReturn` [0]
        throwIO (ErrorCall "the body failed")
      r `shouldBe` (Left (ErrorCall "the body failed") :: Either ErrorCall ())
      expectClean conn

    it "a timeout while the body waits in a read: the statement is cancelled at once, the drain left to the next operation" $ \conn -> within 60 $ do
      (r, t) <- elapsed $ timeout 300_000 $
        withQueryS conn "WAITFOR DELAY '00:00:04'; SELECT CAST(1 AS bigint)" $ \s ->
          S.length_ (s :: Stream (Of (Only Int64)) IO ())
      r `shouldBe` Nothing
      -- The timeout didn't wait for the WAITFOR: nowhere near four seconds.
      t `shouldSatisfy` (< 3)
      leftCancelled conn
      cancelActiveStatement conn
      expectClean conn

    it "a timeout while the body computes between reads (no read in progress): cancelled at once, and the leaked stream throws ResultAbandoned" $ \conn -> within 60 $ do
      leaked <- newIORef Nothing
      r <- timeout 300_000 $ withNums conn 1_000_000 $ \s -> do
        (_, rest) <- takeRows 5 s
        writeIORef leaked (Just rest)
        threadDelay 5_000_000
      r `shouldBe` Nothing
      leftCancelled conn
      -- The body's handle is abandoned, not merely cancelled: read on, it
      -- throws rather than ending at the acknowledgement with rows missing.
      Just rest <- readIORef leaked
      expectAbandonedS rest
      cancelActiveStatement conn
      expectClean conn

    it "the body killed from another thread: the stream is cancelled at once" $ \conn -> within 60 $ do
      started <- newEmptyMVar
      done <- newEmptyMVar
      tid <- forkIO $ (try @SomeException $ withNums conn 1_000_000 $ \s -> do
        _ <- takeRows 5 s
        putMVar started ()
        threadDelay 10_000_000) >>= putMVar done
      takeMVar started
      killThread tid
      r <- takeMVar done
      either (\e -> fromException e `shouldBe` Just ThreadKilled) (\() -> expectationFailure "the body finished") r
      leftCancelled conn
      cancelActiveStatement conn
      expectClean conn

    -- G27 of the MARS review: an interruption right after the request is
    -- sent still cancels the response.  It is left busy, the Attention
    -- sent, for the next operation to drain; nothing is lost and the
    -- connection isn't broken.
    it "interrupted just after its request was sent: the response is cancelled, and the next operation settles it (100 times)" $ \conn -> do
     ident <- sessionIdentity conn
     step <- newSteps "start"
     -- Azure SQL Database acts on an Attention this early only once the
     -- statement has sent its million rows (protocol-notes.md, "Azure SQL
     -- Database"), which took up to 4.3 s a round on S3 under the whole
     -- suite, so 100 rounds take minutes there.
     azure <- testServerIsAzure
     withinTraced (if azure then 600 else 120) conn ident step $
      forM_ [1 .. 100 :: Int] $ \i -> do
        let at what = markStep step ("round " ++ show i ++ ", " ++ what)
        at "the request"
        -- The generation is bumped as the response is registered, right
        -- after the request is on the wire.
        let generation = allSessions conn >>= fmap sum . mapM (readIORef . sessGeneration)
        g0 <- generation
        result <- newEmptyMVar
        tid <- mask_ $ forkIOWithUnmask $ \unmask ->
          try @SomeException (unmask (withNums conn 1_000_000 S.length_)) >>= putMVar result
        let spin = generation >>= \g -> if g /= g0 then pure () else yield >> spin
        spin
        forM_ [1 .. i `mod` 4] $ \_ -> yield
        at "the interruption"
        throwTo tid Interrupt
        takeMVar result >>= \case
          Left e | isInterrupt e -> pure ()
          other -> expectationFailure ("expected the interruption, got " ++ show other)
        -- The request was on the wire before the interruption (the spin
        -- waited for its registration), so the send wasn't interrupted:
        -- the response is busy with its Attention sent.
        connectionBroken conn `shouldReturn` False
        leftCancelled conn
        at "cancelActiveStatement"
        cancelActiveStatement conn
        busySids conn `shouldReturn` []
        connectionBroken conn `shouldReturn` False

    -- R20 of the MARS review: the wait for the server at an ordinary exit
    -- (the body returns) is synchronous, and an interruption of it breaks
    -- the connection, as an interrupted drain does (never a resumed or
    -- second cancel).
    it "an interruption of the exit's wait for the Attention's acknowledgement breaks the connection (ConnectionBroken carrying it)" $ \conn -> within 120 $ do
      let sql = "WAITFOR DELAY '00:00:03'; SELECT CAST(1 AS bigint)"
          attempt n
            | n >= (50 :: Int) = expectationFailure "no interruption landed in the exit's wait in 50 tries"
            | otherwise = do
                inBody <- newEmptyMVar
                result <- newEmptyMVar
                tid <- forkIO $ (try @SomeException $ withQueryS conn sql $ \(_ :: Stream (Of (Only Int64)) IO ()) ->
                  putMVar inBody ()) >>= putMVar result
                takeMVar inBody
                -- Once the exit has sent the Attention, it waits for the
                -- acknowledgement (the WAITFOR is cut short, a round trip).
                -- Landed after the wait (the scope was over): the
                -- connection is clean; try again.
                let again = expectClean conn >> attempt (n + 1)
                -- Until the response is seen open, or the scope is over.
                let look = (,) <$> openResponses conn <*> (not <$> isEmptyMVar result)
                fmap fst (pollFor 10 (\(ars, over) -> not (null ars) || over) look) >>= \case
                  -- The exit's wait, a round trip, was over before this
                  -- thread looked (it can be descheduled that long under
                  -- load): the scope's result says how it ended.
                  [] -> takeMVar result >>= \case
                    Right () -> brokenCause conn >>= \case
                      Nothing -> again
                      Just cause -> expectationFailure ("broken by something else: " ++ show cause)
                    Left e -> expectationFailure ("the scope failed by itself: " ++ show e)
                  [ar] -> do
                    -- The look for the Attention spins.  A round trip to a
                    -- local server is over long before a 'threadDelay'
                    -- returns, which on Windows takes 16 ms at the least, so a
                    -- look that slept would find the wait already over.
                    let spin = RecipeState.attentionSent ar >>= \sent -> if sent then pure () else yield >> spin
                    timeout 10_000_000 spin `shouldReturn` Just ()
                    throwTo tid Interrupt
                    r <- takeMVar result
                    broken <- brokenCause conn
                    case (r, broken) of
                      (Left e, Just cause) | isInterrupt e, isInterrupt cause -> do
                        _ <- expectBrokenBy isInterrupt conn
                        pure ()
                      (_, Just cause) -> expectationFailure ("broken by something else: " ++ show cause)
                      (_, Nothing) -> again
                  ars -> fail ("expected the scope's response, found " ++ show (length ars))
      attempt 0

  describe "nesting" $ do
    it "three deep: each scope cancels its own stream, innermost first, the outer ones go on" $ \conn -> within 60 $ do
      withNums conn 100_000 $ \a -> do
        (ra, a') <- takeRows 3 a
        ra `shouldBe` [1, 2, 3]
        withNums conn 100_000 $ \b -> do
          (rb, b') <- takeRows 3 b
          rb `shouldBe` [1, 2, 3]
          withNums conn 100_000 $ \c -> do
            (rc, c') <- takeRows 3 c
            rc `shouldBe` [1, 2, 3]
            busySids conn `shouldReturn` [0, 1, 2]
            (S.length_ (S.take 50 c')) `shouldReturn` 50
          -- The innermost is gone; the others are open.
          busySids conn `shouldReturn` [0, 1]
          S.length_ (S.take 50 b') `shouldReturn` 50
        busySids conn `shouldReturn` [0]
        S.length_ (S.take 50 a') `shouldReturn` 50
      expectClean conn
      openSids conn `shouldReturn` [0, 1, 2]

    it "three deep, the innermost body throws: all three are cancelled on the way out" $ \conn -> within 60 $ do
      r <- try @ErrorCall $
        withNums conn 1_000_000 $ \a -> withNums conn 1_000_000 $ \b -> withNums conn 1_000_000 $ \c -> do
          mapM_ (\s -> takeRows 2 s) [a, b, c]
          busySids conn `shouldReturn` [0, 1, 2]
          throwIO (ErrorCall "deep")
      r `shouldBe` (Left (ErrorCall "deep") :: Either ErrorCall ())
      expectClean conn

    it "the outer scope's stream is read after the inner one has been left early" $ \conn -> within 60 $ do
      withNums conn 50_000 $ \outer -> do
        (first, rest) <- takeRows 10 outer
        first `shouldBe` [1 .. 10]
        _ <- withNums conn 50_000 $ \inner -> takeRows 10 inner
        busySids conn `shouldReturn` [0]
        S.length_ rest `shouldReturn` 49_990
      expectClean conn

  describe "handing the stream to another thread" $ do
    it "read to the end there, inside the scope" $ \conn -> within 60 $ do
      result <- newEmptyMVar
      withNums conn 100_000 $ \s -> do
        _ <- forkIO $ try @SomeException (S.length_ s) >>= putMVar result
        takeMVar result >>= either throwIO (`shouldBe` 100_000)
      expectClean conn

    it "read there while the scope's thread makes requests of its own" $ \conn -> within 60 $ do
      result <- newEmptyMVar
      withNums conn 100_000 $ \s -> do
        _ <- forkIO $ try @SomeException (S.length_ s) >>= putMVar result
        forM_ [1 .. 20 :: Int] $ \i ->
          query1 conn (mkQuery "SELECT @p1" (Only i)) `shouldReturn` Only i
        takeMVar result >>= either throwIO (`shouldBe` 100_000)
      expectClean conn

    it "read there after the scope has ended: ResultAbandoned" $ \conn -> within 60 $ do
      handOut <- newEmptyMVar
      result <- newEmptyMVar
      _ <- forkIO $ do
        s <- takeMVar handOut
        threadDelay 100_000
        try (S.length_ s) >>= putMVar result
      withNums conn 1_000_000 $ \s -> do
        _ <- takeRows 3 s
        putMVar handOut s
      takeMVar result >>= \case
        Left ResultAbandoned -> pure ()
        Right (n :: Int) -> expectationFailure ("the leaked stream gave " ++ show n ++ " rows")
      expectClean conn

    it "a stream read on another thread that is killed mid-read: the scope still ends cleanly" $ \conn -> within 60 $ do
      started <- newEmptyMVar
      finished <- newEmptyMVar
      withNums conn 5_000_000 $ \s -> do
        tid <- forkIO $ (try @SomeException $ S.mapM_ (\_ -> tryPutMVar started () >> pure ()) s) >>= putMVar finished
        takeMVar started
        killThread tid
        takeMVar finished >>= either (\e -> fromException e `shouldBe` Just ThreadKilled) pure
      expectClean conn

  describe "inside withTransaction" $
    it "a timeout caught in the body: the next request drains the abandoned response first, and the transaction commits" $ \conn -> within 60 $ do
      _ <- execute conn "CREATE TABLE #wq (i int NOT NULL)"
      withTransaction conn $ do
        _ <- execute conn "INSERT INTO #wq VALUES (1)"
        r <- timeout 300_000 $
          withQueryS conn "WAITFOR DELAY '00:00:04'; SELECT CAST(1 AS bigint)" $ \s ->
            S.length_ (s :: Stream (Of (Only Int64)) IO ())
        r `shouldBe` Nothing
        leftCancelled conn
        -- This request drains the cancelled WAITFOR's response before it
        -- is sent; the transaction survives (no XACT_ABORT).
        _ <- execute conn "INSERT INTO #wq VALUES (2)"
        inTransaction conn `shouldReturn` True
        busySids conn `shouldReturn` []
      query1 conn "SELECT COUNT(*) FROM #wq" `shouldReturn` Only (2 :: Int)
      expectClean conn

  describe "without MARS" $ do
    it "the scope cancels its stream, as on a MARS connection" $ \_ -> withPlainConn $ \conn -> within 60 $ do
      leaked <- withNums conn 1_000_000 $ \s -> snd <$> takeRows 3 s
      expectAbandonedS leaked
      expectUsable conn

    it "an interruption between reads cancels the statement at once, and the leaked stream throws ResultAbandoned" $ \_ -> withPlainConn $ \conn -> within 60 $ do
      leaked <- newIORef Nothing
      r <- timeout 300_000 $ withNums conn 1_000_000 $ \s -> do
        (_, rest) <- takeRows 5 s
        writeIORef leaked (Just rest)
        threadDelay 5_000_000
      r `shouldBe` Nothing
      -- The Attention went out from the handler, with no request to carry
      -- it; the response waits for the next operation to drain it.
      [ar] <- openResponses conn
      RecipeState.attentionSent ar `shouldReturn` True
      RecipeState.abandoned ar `shouldReturn` True
      Just rest <- readIORef leaked
      expectAbandonedS rest
      cancelActiveStatement conn
      length <$> openResponses conn `shouldReturn` 0
      expectUsable conn

    -- G25: the exit's cancelResponse finds the reader superseded, and does
    -- nothing to the response that superseded it.
    it "a request made in the body abandons the stream (queryS's rule), and the exit leaves that request's successor alone" $ \_ -> withPlainConn $ \conn -> within 60 $ do
      (leaked, next) <- withNums conn 1_000_000 $ \s -> do
        (_, rest) <- takeRows 3 s
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
        expectAbandonedS rest
        -- A stream started in the body, still open when the scope ends.
        next <- numStream conn 1000
        pure (rest, next)
      expectAbandonedS leaked
      S.length_ next `shouldReturn` 1000
      expectUsable conn

  describe "reading a leaked stream" $
    it "of an abandoned withQueryS never yields a row of a later stream on the same session" $ \conn -> within 60 $ do
      leaked <- withNums conn 1_000_000 $ \s -> snd <$> takeRows 5 s
      -- The session is reused at once, by a different stream.
      next <- numStream conn 1_000_000
      busySids conn `shouldReturn` [0]
      expectAbandonedS leaked
      (rows, _) <- takeRows 3 next
      rows `shouldBe` [1, 2, 3]
      cancelActiveStatement conn
      expectClean conn
