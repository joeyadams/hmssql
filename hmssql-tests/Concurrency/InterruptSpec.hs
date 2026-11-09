{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Fuzzing interruptions: every kind of request, interrupted at a random
-- moment by 'timeout', 'killThread' or 'throwTo'.  An interruption that
-- lands while the request waits for or reads its response leaves the
-- connection usable and in step: the next request gets its own results, not
-- the interrupted one's leftovers.  One that lands while a send blocks (a
-- large request, or the TLS session's write lock) breaks the connection
-- instead: every later request throws 'ConnectionBroken' carrying that
-- interruption.  So the outcome is always usable and in step, or broken by
-- the interruption; never out of step, never hung, never broken by anything
-- else.  Also many threads sharing a connection while being killed (where a
-- kill can also land in a request draining another's cancelled response,
-- which breaks the connection too), and 'race'.
module Concurrency.InterruptSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent
import Control.Concurrent.Async (AsyncCancelled (..), forConcurrently, race, withAsync)
import Control.Exception hiding (assert)
import Control.Monad (forM_, replicateM_, unless, void, when)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Streaming.Prelude as S
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Query
import Hmssql.Errors
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (Session (..), allSessions)
import OpenResponses (isMarsConnection)
import TestDb

-- | What the interrupted request does.
data Shape
  = Materialize !Int
    -- ^ 'query' of that many rows.
  | StreamPartial !Int !Int
    -- ^ 'queryS' of that many rows, of which only the first few are read.
  | Multi
    -- ^ 'queryMulti' with three result sets.
  | Execute !Int
    -- ^ 'execute' inserting that many rows into a temp table.
  | Proc
    -- ^ 'callProcedure' with an output parameter.
  | Lob !Int
    -- ^ One nvarchar(max) value of that many characters (spans packets).
  | BigParam !Int
    -- ^ An nvarchar parameter of that many characters (a multi-packet send).
  | Wait !Int
    -- ^ WAITFOR that many milliseconds, then a row.
  | Batch !Int
    -- ^ 'query' (a plain SQL batch) of that many rows.
  | Many !Int
    -- ^ 'executeStatements' of that many single-row inserts (several messages
    -- from about 5000).
  deriving stock (Eq, Show)

genShape :: Gen Shape
genShape = Gen.choice
  [ Materialize <$> Gen.int (Range.exponential 1 50_000)
  , do n <- Gen.int (Range.exponential 1 50_000); StreamPartial n <$> Gen.int (Range.linear 0 (min n 50))
  , pure Multi
  , Execute <$> Gen.int (Range.exponential 1 5_000)
  , pure Proc
  , Lob <$> Gen.int (Range.exponential 1 1_000_000)
  , BigParam <$> Gen.int (Range.exponential 1 400_000)
  , Wait <$> Gen.int (Range.linear 0 200)
  , Batch <$> Gen.int (Range.exponential 1 50_000)
  , Many <$> Gen.int (Range.exponential 1 20_000)
  ]

rowsSql :: Text
rowsSql = "SELECT TOP (@p2) @p1, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | Run the request and check its result (if it gets that far).
runShape :: Connection -> Int64 -> Shape -> IO (Either String ())
runShape conn v = \case
  Materialize n -> do
    rows <- query conn (mkQuery rowsSql (v, n))
    pure $ expect (rows == [(v, i) | i <- [1 .. fromIntegral n :: Int64]]) ("rows " ++ show (take 3 rows))
  StreamPartial n k -> do
    s <- queryS conn (mkQuery rowsSql (v, n))
    rows <- S.toList_ (S.take k s)
    pure $ expect (rows == [(v, i) | i <- [1 .. fromIntegral k :: Int64]]) ("rows " ++ show (take 3 rows))
  Multi -> do
    sets <- queryMulti conn
      (mkQuery "SELECT @p1 AS a; SELECT TOP 2000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns; SELECT @p1 + 1 AS b"
        (Only v))
    pure $ expect (map (length . resultRows) sets == [1, 2000, 1]) ("result sets " ++ show (map (length . resultRows) sets))
  Execute n -> do
    k <- execute conn (mkQuery "INSERT INTO #ck (v) SELECT TOP (@p2) @p1 FROM sys.all_columns" (v, n))
    pure $ expect (k == fromIntegral n) ("affected " ++ show k)
  Proc -> do
    let params =
          [ inParam "" ("SET @o = @i * 2; SELECT @i" :: Text)
          , inParam "" ("@i bigint, @o bigint OUTPUT" :: Text)
          , inParam "@i" v
          , outParam "@o" (0 :: Int64)
          ]
    r <- callProcedure conn "sp_executesql" params
    let outs = map decodeReturnValue (procOutputValues r) :: [Either DecodeError Int64]
    pure $ expect (outs == [Right (2 * v)] && map (length . resultRows) (procResultSets r) == [1])
      ("outputs " ++ show outs)
  Lob n -> do
    rows <- query conn (mkQuery "SELECT @p1, REPLICATE(CAST(N'x' AS nvarchar(max)), @p2)" (v, n))
    pure $ expect (map (fmap T.length) rows == [(v, n)]) ("lob of " ++ show (map (fmap T.length) rows))
  BigParam n -> do
    rows <- query conn (mkQuery "SELECT @p1, LEN(@p2)" (v, T.replicate n "y"))
    pure $ expect (rows == [(v, n)]) ("rows " ++ show rows)
  Wait ms -> do
    rows <- query conn (mkQuery ("WAITFOR DELAY '00:00:00." <> T.justifyRight 3 '0' (T.pack (show ms)) <> "'; SELECT @p1") (Only v))
    pure $ expect (rows == [Only v]) ("rows " ++ show rows)
  Batch n -> do
    rows <- query conn (rawSql ("SELECT TOP " <> tshow n <> " CAST(" <> tshow v <> " AS bigint), ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"))
    pure $ expect (rows == [(v, i) | i <- [1 .. fromIntegral n :: Int64]]) ("rows " ++ show (take 3 rows))
  Many n -> do
    counts <- executeMany conn "INSERT INTO #ck (v) VALUES (@p1)" (replicate n (Only v))
    pure $ expect (counts == replicate n 1) ("counts " ++ show (take 3 counts) ++ ", " ++ show (length counts))
  where
    expect ok msg = if ok then Right () else Left ("wrong result: " ++ msg)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | How iterations ended, for the summary line.
data Stats = Stats
  { completed :: !Int
  , interruptedUsable :: !Int
  , broken :: !Int
  }

setupConn :: Connection -> IO ()
setupConn conn = void $ execute conn "CREATE TABLE #ck (v bigint)"

-- | Under MARS a partly read stream ('StreamPartial') stays open after
-- the request, and is cancelled before the check.  Nothing else may be
-- left open: an interrupted non-streaming request's response is drained
-- by the check's first request, as without MARS.
interruptProperty :: ConnHolder -> IORef Stats -> PropertyT IO ()
interruptProperty holder stats = do
  shape <- forAll genShape
  method <- forAll genMethod
  delay <- forAll (genDelay 50_000)
  (outcome, health) <- evalIO $ withHeldConnection holder $ \conn -> do
    v <- nextId
    r <- interruptWith method delay (runShape conn v shape)
    case shape of
      StreamPartial _ _ -> settleInterruptedStream conn rowsSql
      _ -> pure ()
    -- Broken only by this interruption (landing in a blocked send).
    h <- expectUsableOrBrokenBy (interruptedBy method) conn
    case h of
      Broken _ -> closeHolder holder
      Usable -> pure ()
    pure (r, h)
  case outcome of
    Right (Left wrong) -> annotate wrong >> failure
    Right (Right ()) -> pure ()
    Left e -> do
      -- The request may only end with the interruption itself.
      annotateShow e
      assert (isAsync e || show e == show (userError "<<timeout>>"))
  case (health, outcome) of
    -- The interruption that broke the connection reached the request.
    (Broken cause, Right _) -> do
      annotate ("broken by " ++ show cause ++ ", but the request completed")
      failure
    (Broken cause, Left _) -> annotate ("broken by: " ++ show cause)
    (Usable, _) -> pure ()
  evalIO $ modifyIORef' stats $ \s -> case (outcome, health) of
    (_, Broken _) -> s { broken = broken s + 1 }
    (Right _, _) -> s { completed = completed s + 1 }
    (Left _, _) -> s { interruptedUsable = interruptedUsable s + 1 }

runInterruptProperty :: Int -> Spec
runInterruptProperty n =
  it ("leaves the connection usable and in step, or broken by the interruption (" ++ show n ++ " random interruptions)") $ do
    ci <- defaultTestConnectInfo
    holder <- newConnHolder ci setupConn
    stats <- newIORef (Stats 0 0 0)
    cases <- scaledCases n
    -- hedgehog's own runner prints the seed of a failing run.
    ok <- check (withTests (fromIntegral cases) (withShrinks 0 (property (interruptProperty holder stats))))
    closeHolder holder
    Stats{..} <- readIORef stats
    hPutStrLn stderr $ "    [interrupt fuzz] completed " ++ show completed ++ ", interrupted and usable "
      ++ show interruptedUsable ++ ", broken by the interruption " ++ show broken
    ok `shouldBe` True

-- | Many threads share a connection, some of their requests time out and a
-- killer interrupts random threads; every result must be the thread's own.
-- An interruption can land in a request that is draining another thread's
-- cancelled response (or in a blocked send), which breaks the connection:
-- then every thread's requests throw 'ConnectionBroken' carrying that
-- interruption (a timeout or 'Interrupt'), and the round ends.  Returns how
-- many rounds ended so.
sharedConnection :: Int -> Int -> IO Int
sharedConnection rounds iters = do
  ci <- defaultTestConnectInfo
  brokenRounds <- newIORef (0 :: Int)
  forM_ [1 .. rounds] $ \_ -> withConnection ci $ \conn -> do
    stop <- newIORef False
    -- The workers still running.  The killer picks and interrupts one while
    -- holding this, and a worker leaves it before it stops catching
    -- interruptions: a worker that finished and was interrupted anyway would
    -- end with the interruption instead of its errors.
    tids <- newMVar []
    let worker :: Int -> IO [String]
        worker w = mask $ \restore -> do
          me <- myThreadId
          modifyMVar_ tids (pure . (me :))
          -- Blocks while the killer holds the list (possibly interrupting
          -- this thread, and then again).
          let leave = modifyMVar_ tids (pure . filter (/= me)) `catch` \Interrupt -> leave
          let loop :: Int -> [String] -> IO [String]
              loop i errs
                | i >= iters = pure errs
                | otherwise = readIORef stop >>= \case
                    True -> pure errs
                    False -> do
                      v <- nextId
                      let len = fromIntegral ((v * 7919 + fromIntegral w * 104729) `mod` 12000) :: Int
                          viaStream = v `mod` 3 == 0
                          op = if viaStream
                            then queryS conn (mkQuery "SELECT @p1, @p2, REPLICATE(CAST('x' AS varchar(max)), @p2)" (v, len)) >>= S.toList_
                            else query conn (mkQuery "SELECT @p1, @p2, REPLICATE(CAST('x' AS varchar(max)), @p2)" (v, len))
                          timed = if v `mod` 5 == 0 then timeout (fromIntegral (v `mod` 3000)) op else Just <$> op
                      r <- try (restore timed)
                      case r of
                        Right Nothing -> loop (i + 1) errs
                        Right (Just rows)
                          | map (\(a, b, t) -> (a, b, T.length t)) rows == [(v, len, len)] -> loop (i + 1) errs
                          | otherwise -> loop (i + 1) (("DESYNC: thread " ++ show w ++ " asked for " ++ show (v, len)
                              ++ ", got " ++ show (map (\(a, b, t) -> (a :: Int64, b :: Int, T.length t)) rows)) : errs)
                        Left e
                          | isAsync e -> loop (i + 1) errs
                          | Just ResultAbandoned <- fromException e, viaStream -> loop (i + 1) errs
                          | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e -> do
                              writeIORef stop True
                              pure $ if isTimeout cause || isInterrupt cause
                                then errs
                                else ("broken by " ++ show cause) : errs
                          | otherwise -> pure (("thread " ++ show w ++ ": " ++ show e) : errs)
          errs <- loop 0 []
          leave
          pure errs
        killer = do
          threadDelay 2000
          let go (k :: Int) = do
                withMVar tids $ \ts -> unless (null ts) $ throwTo (ts !! (k `mod` length ts)) Interrupt
                threadDelay (200 + (k * 37) `mod` 1500)
                go (k + 1)
          go 0
    errs <- within 120 $ withAsync killer $ \_ -> concat <$> forConcurrently [1 .. 8] worker
    errs `shouldBe` []
    -- A worker sees only the interruption of an operation it was in, and
    -- the connection's break by it only in its next operation: a break in
    -- the last operations of all leaves 'stop' unset, so that is checked
    -- here as well.
    let byInterruption c = isTimeout c || isInterrupt c
    readIORef stop >>= \case
      True -> do
        _ <- expectBrokenBy byInterruption conn
        modifyIORef' brokenRounds (+ 1)
      False -> do
        -- Under MARS a worker's stream interrupted outside a read is still
        -- open: cancelled first, as an application would.
        when (isMarsConnection conn) $
          try (cancelActiveStatement conn) >>= \case
            Left (ConnectionBroken (reasonCause -> c)) | byInterruption c -> pure ()
            Left e -> throwIO e
            Right () -> pure ()
        expectUsableOrBrokenBy byInterruption conn >>= \case
          Usable -> pure ()
          Broken _ -> modifyIORef' brokenRounds (+ 1)
  readIORef brokenRounds

-- | 'sharedConnection', printing how many rounds broke the connection.
sharedRounds :: Int -> Int -> IO ()
sharedRounds rounds iters = do
  b <- sharedConnection rounds iters
  hPutStrLn stderr ("    [shared connection] broken by an interruption in " ++ show b ++ " of " ++ show rounds ++ " rounds")

spec :: Spec
spec = describe "interrupting requests" $ do
  runInterruptProperty 150
  slow $ runInterruptProperty 3000

  it "keeps a connection shared by killed threads in step, or breaks it (ConnectionBroken carrying an interruption)" $
    sharedRounds 3 60
  slow $ it "keeps a connection shared by killed threads in step, or breaks it (ConnectionBroken carrying an interruption) (long)" $
    sharedRounds 30 200

  describe "race" $ do
    -- The loser is cancelled wherever it is: waiting for the lock, sending
    -- (a one-packet request, which seldom blocks), or waiting for its
    -- response.  Only a cancellation that lands in a blocked send may break
    -- the connection (which is then replaced).
    it "cancels the losing query of two racing on one connection, leaving it in step, or broken by the cancellation" $ do
      ci <- defaultTestConnectInfo
      holder <- newConnHolder ci (\_ -> pure ())
      broken <- newIORef (0 :: Int)
      within 120 $ forM_ [1 .. 300 :: Int] $ \_ -> withHeldConnection holder $ \conn -> do
        a <- nextId
        b <- nextId
        r <- race (query1 conn ("SELECT " <> param a)) (query1 conn ("SELECT " <> param b))
        r `shouldSatisfy` either (== Only a) (== Only b)
        expectUsableOrBrokenBy (\c -> fromException c == Just AsyncCancelled) conn >>= \case
          Usable -> pure ()
          Broken _ -> modifyIORef' broken (+ 1) >> closeHolder holder
      closeHolder holder
      readIORef broken >>= \b -> hPutStrLn stderr ("    [race] broken by the cancellation " ++ show b ++ " of 300")

    -- Wall-clock bounds: alone (see TestDb.serial).
    serial $ it "cancels a long query that loses to a timer" $ withTestDb $ \conn -> do
      (r, t) <- elapsed $ race (query1 conn "WAITFOR DELAY '00:00:10'; SELECT 1" :: IO (Only Int)) (threadDelay 100_000)
      r `shouldBe` Right ()
      t `shouldSatisfy` (< 2)
      (_, t2) <- elapsed (within 10 (expectUsable conn))
      t2 `shouldSatisfy` (< 2)

  describe "the moment of sending" $ do
    -- The send runs masked, so an interruption lands in it only if it
    -- blocks: for a one-packet request, on the TLS session's write lock at
    -- most (a plain socket takes the packet at once).  Otherwise it is
    -- deferred until the send is over and lands in the wait for the
    -- response.  Which of the two happens is counted (and printed): how
    -- often an interruption at this moment costs the connection.
    it "an interruption while a one-packet request is being sent leaves the connection usable, or broken (ConnectionBroken carrying the interruption), never out of step" $ do
        ci <- defaultTestConnectInfo
        usable <- newIORef (0 :: Int)
        broken <- newIORef (0 :: Int)
        completed <- newIORef (0 :: Int)
        -- A connection each: 50 cover every number of yields six times.
        n <- fastOrSlow 50 200
        within 120 $ forM_ [1 .. n :: Int] $ \i -> withConnection ci $ \conn -> do
          -- A few yields: the request is still being encrypted and sent.
          r <- interruptWith ViaThrowTo (Yields (i `mod` 8)) (query1 conn "SELECT 1" :: IO (Only Int))
          case r of
            Right v -> v `shouldBe` Only 1
            Left e -> (show e, isInterrupt e) `shouldSatisfy` snd
          expectUsableOrBrokenBy isInterrupt conn >>= \case
            Usable -> modifyIORef' (either (const usable) (const completed) r) (+ 1)
            Broken _ -> do
              either (const (pure ())) (\_ -> expectationFailure "broken, but the request completed") r
              modifyIORef' broken (+ 1)
        u <- readIORef usable
        b <- readIORef broken
        c <- readIORef completed
        enc <- testEncryption
        hPutStrLn stderr ("    [moment of sending, " ++ show enc ++ "] of " ++ show n ++ ": interrupted and usable "
          ++ show u ++ ", interrupted and broken " ++ show b ++ ", completed first " ++ show c)

    it "an interruption just after a request was sent leaves the connection in step" $
      withTestDb $ \conn -> within 120 $ forM_ [1 .. 300 :: Int] $ \i -> do
        -- Summed over the sessions: under MARS the request may take any.
        let generation = allSessions conn >>= fmap sum . mapM (readIORef . sessGeneration)
        g0 <- generation
        v <- nextId
        result <- newEmptyMVar
        tid <- mask_ $ forkIOWithUnmask $ \unmask ->
          try (unmask (query conn (mkQuery "SELECT @p1" (Only v)))) >>= putMVar result
        -- The generation is bumped right after the request is on the wire,
        -- before the response is registered.
        let spin = generation >>= \g -> if g /= g0 then pure () else yield >> spin
        spin
        replicateM_ (i `mod` 4) yield
        throwTo tid Interrupt
        takeMVar result >>= \case
          Right rows -> rows `shouldBe` [Only v]
          Left e -> (show e, isAsync e) `shouldSatisfy` snd
        -- The send had completed, so nothing may be broken or out of step.
        checkHealth conn >>= \case
          Usable -> pure ()
          Broken cause -> throwIO (userError ("broken after the send completed: " ++ show cause))

  describe "back-to-back interruptions" $
    -- The first request is a large stream, abandoned; each following
    -- request is interrupted after a few hundred microseconds, i.e. usually
    -- while it is still cancelling and draining that stream (its Attention
    -- may already be sent).  An interruption mid-drain breaks the
    -- connection, carrying the timeout; one that lands before or after the
    -- drain leaves it usable.  Deterministic versions: Concurrency.Attention.
    -- Under MARS a request leaves the stream alone: there each request is
    -- preceded by 'cancelActiveStatement', which drains it (once).
    it "an interruption of the request draining an abandoned stream breaks the connection (ConnectionBroken carrying the timeout), or leaves it usable if it lands elsewhere; never out of step" $ do
      broken <- newIORef (0 :: Int)
      within 120 $ forM_ [1 .. 30 :: Int] $ \i -> withTestDb $ \conn -> do
        s <- queryS conn "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        _ <- S.toList_ (S.take 5 s) :: IO [Only Int64]
        let cancelling = if isMarsConnection conn then cancelActiveStatement conn else pure ()
        forM_ [1 .. 5 :: Int] $ \j -> do
          r <- try (timeout (100 * i + 37 * j) (cancelling >> query1 conn "SELECT 1" :: IO (Only Int)))
          case r of
            Right _ -> pure ()
            -- An earlier one broke the connection.
            Left (ConnectionBroken (reasonCause -> cause)) | isTimeout cause -> pure ()
            Left other -> expectationFailure ("request " ++ show j ++ " threw " ++ show other)
        expectUsableOrBrokenBy isTimeout conn >>= \case
          Usable -> pure ()
          Broken _ -> modifyIORef' broken (+ 1)
      readIORef broken >>= \b -> hPutStrLn stderr ("    [back-to-back] broken by a timeout mid-drain in " ++ show b ++ " of 30")
