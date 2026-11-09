-- | SMP sessions on a MARS connection, against the mock server
-- ("Mars.MockSmp"), which checks every SYN (for a closed identifier, at
-- most one above the largest in use) and every sequence number: each open
-- response has a session of its own, taken lowest identifier first and
-- opened with a SYN before its request; idle sessions beyond 10 are
-- closed with a FIN, highest first, and an identifier is reused only once
-- the server's FIN has answered; an Attention goes on the session of the
-- response it cancels; a bulk load keeps to one session.  A session is
-- registered before its SYN leaves, so whatever interrupts a request, the
-- connection is either broken or knows every session the server has.  A
-- MARS connection dropped without 'close' is collected and its socket
-- closed.
module Mars.SmpSessionsSpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM (atomically, check, readTVar, readTVarIO)
import Control.Exception
import Control.Monad (forM_, replicateM, unless, when)
import Data.Int (Int32, Int64)
import Data.IORef
import Data.Maybe (isJust)
import Data.Word (Word16, Word8)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (batchText, doneAttn, doneFinal, selectedNumber)
import qualified Data.Text as T
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Errors (ResultAbandoned (..))
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Types (TypeInfo (..))
import Mars.MockSmp

data Snipe = Snipe
  deriving (Show)

instance Exception Snipe

-- | Flags and SID of each packet but the ACKs.
opens :: [SmpIn] -> [(Word8, Word16)]
opens ps = [(inFlags p, inSid p) | p <- ps, not (isAck p)]

-- | Wait (up to 5 s) until the action's result satisfies the predicate.
waitUntil :: IO a -> (a -> Bool) -> IO ()
waitUntil act p = do
  ok <- timeout 5_000_000 $ let loop = act >>= \a -> unless (p a) (threadDelay 5_000 >> loop) in loop
  unless (isJust ok) $ expectationFailure "timed out waiting for the client"

-- | The connection is broken or closed.
isBroken :: Connection -> IO Bool
isBroken conn = do
  broken <- isJust <$> readIORef (connBroken conn)
  ended <- isJust <$> readTVarIO (connEnded conn)
  pure (broken || ended)

-- | After whatever interrupted a request: the connection is broken, or
-- it knows (has registered) exactly the sessions the server has, and
-- goes on opening new ones without a SYN for one of them (which the mock
-- would record as a violation).  For 'partialSelects', which answers the
-- UPDATEs in full.
consistent :: SmpMock -> Connection -> IO ()
consistent m conn = do
  broken <- isBroken conn
  unless broken $ do
    -- Once its answer is read, the mock has taken everything sent before.
    execute conn "UPDATE t SET a = 3" `shouldReturn` 0
    ids <- mockSessionIds m
    openSessionIds conn `shouldReturn` ids
    mapM (registered conn) ids `shouldReturn` map (const True) ids
    registrySize conn `shouldReturn` length ids
    _ <- queryS conn "SELECT 4" :: IO (S.Stream (S.Of (Only Int64)) IO ())
    execute conn "UPDATE t SET a = 5" `shouldReturn` 0
  violationsSoFar m `shouldReturn` []

showText :: Show a => a -> T.Text
showText = T.pack . show

spec :: Spec
spec = describe "SMP sessions (mock server)" $ do
  it "a second open response takes session 1, a third session 2, each SYN first; freed sessions are reused lowest first" $
    withSmpServer defaultSmpConfig $ \srv -> do
      within 30 $ withConnection (smpConnectInfo srv) $ \conn -> do
        s0 <- queryS conn "SELECT 10"
        s1 <- queryS conn "SELECT 11"
        s2 <- queryS conn "SELECT 12"
        openSessionIds conn `shouldReturn` [0, 1, 2]
        S.toList_ s1 `shouldReturn` [Only (11 :: Int64)]
        s3 <- queryS conn "SELECT 13"
        S.toList_ s0 `shouldReturn` [Only (10 :: Int64)]
        s4 <- queryS conn "SELECT 14"
        mapM S.toList_ [s2, s3, s4] `shouldReturn` map (\i -> [Only i]) [12, 13, 14 :: Int64]
        openSessionIds conn `shouldReturn` [0, 1, 2]
      out <- nextOutcome srv
      opens (outReceived out) `shouldBe`
        [(flagSyn, 0), (flagData, 0), (flagSyn, 1), (flagData, 1), (flagSyn, 2), (flagData, 2), (flagData, 1), (flagData, 0)]
      [(cmSid msg, batchText (cmBody msg)) | msg <- outMessages out]
        `shouldBe` [(0, "SELECT 10"), (1, "SELECT 11"), (2, "SELECT 12"), (1, "SELECT 13"), (0, "SELECT 14")]
      outViolations out `shouldBe` []

  it "keeps 10 idle sessions: FINs the rest, highest first, at the next request, and reuses one only after the server's FIN" $
    withSmpServer defaultSmpConfig { cfgAutoFin = False } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        m <- nextMock srv
        streams <- replicateM 12 (queryS conn "SELECT 1")
        mapM S.toList_ streams `shouldReturn` replicate 12 [Only (1 :: Int64)]
        openSessionIds conn `shouldReturn` [0 .. 11]
        query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int64)
        -- Closing: out of the open sessions, still in the registry.
        openSessionIds conn `shouldReturn` [0 .. 9]
        registrySize conn `shouldReturn` 12
        more <- replicateM 11 (queryS conn "SELECT 3")
        openSessionIds conn `shouldReturn` [0 .. 9] ++ [12]
        -- The mock answers the FINs once it has the SYN for 12, while 10
        -- and 11 are still closing on its side too.
        awaitReceived m 5_000_000 (any (\p -> isSyn p && inSid p == 12)) `shouldReturn` True
        sendFin m 11
        sendFin m 10
        waitUntil (registrySize conn) (== 11)
        lastOne <- queryS conn "SELECT 4"
        openSessionIds conn `shouldReturn` [0 .. 10] ++ [12]
        mapM S.toList_ more `shouldReturn` replicate 11 [Only (3 :: Int64)]
        S.toList_ lastOne `shouldReturn` [Only (4 :: Int64)]
      out <- nextOutcome srv
      let packets = opens (outReceived out)
      [p | p@(f, _) <- packets, f `elem` [flagSyn, flagFin]]
        `shouldBe` [(flagSyn, i) | i <- [0 .. 11]] ++ [(flagFin, 11), (flagFin, 10), (flagSyn, 12), (flagSyn, 10)]
      -- The FINs go before the request that closes them.
      take 3 (drop 24 packets) `shouldBe` [(flagFin, 11), (flagFin, 10), (flagData, 0)]
      outViolations out `shouldBe` []

  it "never FINs a busy session: with the highest sessions busy, the highest idle one is closed" $
    withSmpServer defaultSmpConfig $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        streams <- replicateM 13 (queryS conn "SELECT 1")
        -- 0 to 10 idle, 11 and 12 busy (their responses unread).
        mapM S.toList_ (take 11 streams) `shouldReturn` replicate 11 [Only (1 :: Int64)]
        query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int64)
        openSessionIds conn `shouldReturn` [0 .. 9] ++ [11, 12]
        mapM S.toList_ (drop 11 streams) `shouldReturn` replicate 2 [Only (1 :: Int64)]
      out <- nextOutcome srv
      [inSid p | p <- outReceived out, isFin p] `shouldBe` [10]
      outViolations out `shouldBe` []

  describe "a stream left on a session that the trim closes, whose identifier is then reused" $
    forM_ [(777, "still running (an Attention cancels it)"), (778, "arrived whole (drained with nothing sent)")] $ \(n, how) ->
      it ("throws ResultAbandoned, and the new stream on the identifier gets only its own rows: a response " ++ how) $ do
        -- SELECT 777 is answered with its first packet only.
        let answer m msg
              | cmType msg == PTSqlBatch, selectedNumber (batchText (cmBody msg)) == Just 777 = partialSelects m msg
              | otherwise = answerRequests m msg
            stale str = try @ResultAbandoned (S.toList_ str :: IO [Only Int64])
        withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv -> do
          within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
            busy <- replicateM 11 (queryS conn "SELECT 1")
            -- On session 11: one row read, then left by its scope.
            old <- withQueryS conn (rawSql ("SELECT " <> showText n)) $ \s -> S.next s >>= \case
              Right (Only r, rest) -> (r `shouldBe` (n :: Int64)) >> pure rest
              Left () -> expectationFailure "no row" >> pure (pure ())
            openSessionIds conn `shouldReturn` [0 .. 11]
            mapM S.toList_ busy `shouldReturn` replicate 11 [Only (1 :: Int64)]
            -- The trim closes 11 and 10, and the mock answers the FINs.
            query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int64)
            waitUntil (registrySize conn) (== 10)
            either (const True) (const False) <$> stale old `shouldReturn` True
            -- Eleven busy streams take 0 to 10 again, and the next one 11.
            busy' <- replicateM 11 (queryS conn "SELECT 3")
            fresh <- queryS conn "SELECT 888"
            openSessionIds conn `shouldReturn` [0 .. 11]
            either (const True) (const False) <$> stale old `shouldReturn` True
            S.toList_ fresh `shouldReturn` [Only (888 :: Int64)]
            mapM S.toList_ busy' `shouldReturn` replicate 11 [Only (3 :: Int64)]
            either (const True) (const False) <$> stale old `shouldReturn` True
            query1 conn "SELECT 4" `shouldReturn` Only (4 :: Int64)
          out <- nextOutcome srv
          [(flags, sid) | (flags, sid) <- opens (outReceived out), flags `elem` [flagSyn, flagFin], sid >= 10]
            -- The last request trims them again.
            `shouldBe` [(flagSyn, 10), (flagSyn, 11), (flagFin, 11), (flagFin, 10), (flagSyn, 10), (flagSyn, 11), (flagFin, 11), (flagFin, 10)]
          [sid | msg <- outMessages out, cmType msg == PTAttention, let sid = cmSid msg]
            `shouldBe` [11 | n == 777]
          outViolations out `shouldBe` []

  it "an Attention goes out as DATA on the session of the response it cancels" $
    withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv -> do
      within 30 $ withConnection (smpConnectInfo srv) $ \conn -> do
        withQueryS conn "SELECT 1" $ \s0 -> do
          Right (Only (1 :: Int64), _) <- S.next s0
          -- Cancelled when the scope ends.
          withQueryS conn "SELECT 2" $ \s1 -> do
            Right (Only (2 :: Int64), _) <- S.next s1
            pure ()
          -- Cancelled by an interrupted read, on session 1 again.
          s2 <- queryS conn "SELECT 3"
          timeout 200_000 (S.toList_ s2 :: IO [Only Int64]) `shouldReturn` Nothing
        -- Session 1's cancelled response is drained first.
        execute conn "UPDATE t SET a = 1" `shouldReturn` 0
      out <- nextOutcome srv
      [(cmSid msg, cmType msg, batchText (cmBody msg)) | msg <- outMessages out]
        `shouldBe` [ (0, PTSqlBatch, "SELECT 1"), (1, PTSqlBatch, "SELECT 2"), (1, PTAttention, "")
                   , (1, PTSqlBatch, "SELECT 3"), (1, PTAttention, ""), (0, PTAttention, "")
                   , (0, PTSqlBatch, "UPDATE t SET a = 1") ]
      outViolations out `shouldBe` []

  it "a bulk load's INSERT BULK and every packet of its load go on one session, batch after batch" $ do
    let answer m msg = case cmType msg of
          PTBulkLoad -> respondOn m (cmSid msg) [doneFinal 5000]
          _ -> answerRequests m msg
        cols = [BulkColumn "a" (TIIntN 4) False False]
    withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        -- Session 0 stays busy: the load takes session 1.
        s0 <- queryS conn "SELECT 10"
        n <- bulkInsertWith (bulkCopy "t") { bulkColumns = DescribedColumns cols, bulkBatchSize = Just 5000 } conn
          (map Only [1 .. 20000 :: Int32])
        n `shouldBe` 20000
        S.toList_ s0 `shouldReturn` [Only (10 :: Int64)]
      out <- nextOutcome srv
      [(cmSid msg, cmType msg) | msg <- outMessages out]
        `shouldBe` (0, PTSqlBatch) : concat (replicate 4 [(1, PTSqlBatch), (1, PTBulkLoad)])
      -- More packets than the window of 4 per load: each waited for the
      -- mock's ACKs.
      length [p | p <- outReceived out, isData p, inSid p == 1] `shouldSatisfy` (> 4 * 8)
      outViolations out `shouldBe` []

  -- Without the reservation, the INSERT BULK of the third batch would take
  -- session 0 (the lowest idle one), freed during the second batch.
  it "a bulk load stays on its session when a lower one is freed during the load (its rows come from a stream on session 0)" $ do
    let answer m msg = case cmType msg of
          PTBulkLoad -> respondOn m (cmSid msg) [doneFinal 1000]
          PTSqlBatch | batchText (cmBody msg) == "SELECT rows" -> respondOn m (cmSid msg) (longRows 1500)
          _ -> answerRequests m msg
        cols = [BulkColumn "a" (TIIntN 4) False False]
    withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        s0 <- queryS conn "SELECT rows"
        let rows = S.map (\(Only i) -> Only (fromIntegral (i :: Int64) :: Int32)) s0 >> S.each (map Only [1501 .. 3000])
        n <- bulkInsertSWith (bulkCopy "t") { bulkColumns = DescribedColumns cols, bulkBatchSize = Just 1000 } conn rows
        n `shouldBe` 3000
        openSessionIds conn `shouldReturn` [0, 1]
        -- Session 0 is idle again, and taken first.
        execute conn "UPDATE t SET a = 1" `shouldReturn` 0
      out <- nextOutcome srv
      [(cmSid msg, cmType msg) | msg <- outMessages out]
        `shouldBe` (0, PTSqlBatch) : concat (replicate 3 [(1, PTSqlBatch), (1, PTBulkLoad)]) ++ [(0, PTSqlBatch)]
      outViolations out `shouldBe` []

  describe "a new session is known to the client before its SYN leaves" $ do
    -- The server shuts the connection down as the first request arrives,
    -- and the second request goes out once the client's reader has seen
    -- the end.  A write after the peer's shutdown would succeed; what
    -- fails is the SYN's send, which checks that the connection hasn't
    -- ended.  The session was registered first, and the failed send
    -- breaks the connection.
    it "a SYN whose send fails: the session is registered, and the connection broken" $ do
      let answer m msg = when (batchText (cmBody msg) == "SELECT 1") $ dropConnection m
      withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv ->
        forM_ [1 .. 10 :: Int] $ \_ -> within 30 $ do
          conn <- connect (smpConnectInfo srv)
          flip finally (close conn) $ do
            _ <- queryS conn "SELECT 1" :: IO (S.Stream (S.Of (Only Int64)) IO ())
            atomically $ readTVar (connEnded conn) >>= check . isJust
            r <- try (queryS conn "SELECT 2" :: IO (S.Stream (S.Of (Only Int64)) IO ()))
            registered conn 1 `shouldReturn` True
            case r of
              Left (_ :: SomeException) -> pure ()
              Right _ -> expectationFailure "the SYN's send succeeded after the connection ended"
            (isJust <$> readIORef (connBroken conn)) `shouldReturn` True
            try (query1 conn "SELECT 3" :: IO (Only Int64)) >>= \case
              Left (_ :: SomeException) -> pure ()
              Right _ -> expectationFailure "the connection is usable after a failed send"

    it "a request interrupted by a timeout: broken, or the client knows every session the server has" $
      withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv ->
        forM_ ([0 .. 50] ++ [60, 80 .. 1000]) $ \micros -> within 30 $
          withConnection (smpConnectInfo srv) $ \conn -> do
            m <- nextMock srv
            _ <- queryS conn "SELECT 1" :: IO (S.Stream (S.Of (Only Int64)) IO ())
            _ <- timeout micros (queryS conn "SELECT 2" >>= evaluate :: IO (S.Stream (S.Of (Only Int64)) IO ()))
            consistent m conn

    it "a request interrupted as its SYN reaches the server: broken, or the client knows every session the server has" $
      withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv ->
        forM_ [1 .. 30 :: Int] $ \_ -> within 30 $
          withConnection (smpConnectInfo srv) $ \conn -> do
            m <- nextMock srv
            _ <- queryS conn "SELECT 1" :: IO (S.Stream (S.Of (Only Int64)) IO ())
            me <- myThreadId
            sniper <- forkIO $ do
              seen <- awaitReceived m 5_000_000 (any (\p -> isSyn p && inSid p == 1))
              when seen $ throwTo me Snipe
            _ <- try @Snipe $ do
              _ <- queryS conn "SELECT 2" :: IO (S.Stream (S.Of (Only Int64)) IO ())
              threadDelay 2_000_000
            killThread sniper
            consistent m conn

  -- R19: settling every response (cancelActiveStatement, release, a
  -- pending reset, a transaction's cleanup) sends all the Attentions
  -- before it reads any acknowledgement.  The mock acknowledges only once
  -- both have come, so a client that drains one session before it cancels
  -- the next never gets an answer.
  it "settling several running responses sends every Attention before it waits for an acknowledgement" $ do
    attentions <- newIORef []
    let answer m msg = case cmType msg of
          PTAttention -> do
            sids <- atomicModifyIORef' attentions (\s -> (cmSid msg : s, cmSid msg : s))
            when (length sids == 2) $ forM_ (reverse sids) $ \sid -> respondOn m sid [doneAttn]
          _ -> partialSelects m msg
    withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv -> do
      within 10 $ withConnection (smpConnectInfo srv) $ \conn -> do
        s0 <- queryS conn "SELECT 1"
        s1 <- queryS conn "SELECT 2"
        Right (Only (1 :: Int64), rest0) <- S.next s0
        Right (Only (2 :: Int64), rest1) <- S.next s1
        cancelActiveStatement conn
        forM_ [rest0, rest1] $ \rest -> try (S.toList_ rest) >>= \case
          Left ResultAbandoned -> pure ()
          Right _ -> expectationFailure "a cancelled stream read on"
        execute conn "UPDATE t SET a = 1" `shouldReturn` 0
      out <- nextOutcome srv
      [(cmSid msg, cmType msg) | msg <- outMessages out]
        `shouldBe` [(0, PTSqlBatch), (1, PTSqlBatch), (0, PTAttention), (1, PTAttention), (0, PTSqlBatch)]
      outViolations out `shouldBe` []

  -- G12: the finalizer that closes a dropped connection's socket is keyed
  -- on what every stream keeps (through its handle), so streams outliving
  -- the handle they came from read on, however often the collector runs.
  it "streams kept after their connection's handle is dropped read to their end across major GCs" $
    withSmpServer defaultSmpConfig { cfgRespond = Just longSelects } $ \srv -> do
      (a, b) <- streamsOnly (smpConnectInfo srv)
      m <- nextMock srv
      forM_ [1 .. 5 :: Int] $ \_ -> performMajorGC >> threadDelay 20_000
      awaitClientClose m 100_000 `shouldReturn` False
      within 30 $ do
        S.length_ a `shouldReturn` 2000
        S.length_ b `shouldReturn` 2000
      -- Once the streams are gone too, the connection is collected.
      let collect :: Int -> IO Bool
          collect n = do
            performMajorGC
            closed <- awaitClientClose m 100_000
            if closed || n == 0 then pure closed else collect (n - 1)
      collect 100 `shouldReturn` True
      out <- nextOutcome srv
      [inSid p | p <- outReceived out, isSyn p] `shouldBe` [0, 1]
      -- Both responses outran the window: the client ACKed as it read.
      length [p | p <- outReceived out, isAck p] `shouldSatisfy` (> 2 * 20)
      outViolations out `shouldBe` []

  it "a MARS connection dropped with open sessions, without close, is collected and its socket closed" $
    withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv -> do
      connectAndDrop (smpConnectInfo srv)
      m <- nextMock srv
      let collect :: Int -> IO Bool
          collect n = do
            performMajorGC
            closed <- awaitClientClose m 100_000
            if closed || n == 0 then pure closed else collect (n - 1)
      collect 100 `shouldReturn` True
      out <- nextOutcome srv
      [(inFlags p, inSid p) | p <- outReceived out, isSyn p] `shouldBe` [(flagSyn, 0), (flagSyn, 1)]
      outViolations out `shouldBe` []

-- | Connect, open two responses (sessions 0 and 1) and let go of
-- everything.  Not inlined, so that nothing here keeps the connection.
connectAndDrop :: ConnectInfo -> IO ()
connectAndDrop ci = do
  conn <- connect ci
  _ <- queryS conn "SELECT 1" :: IO (S.Stream (S.Of (Only Int64)) IO ())
  _ <- queryS conn "SELECT 2" :: IO (S.Stream (S.Of (Only Int64)) IO ())
  pure ()
{-# NOINLINE connectAndDrop #-}

-- | Connect, open two long responses (sessions 0 and 1), read a row of
-- each, and return the streams only.  Not inlined, so that nothing here
-- keeps the connection's handle.
streamsOnly :: ConnectInfo -> IO (S.Stream (S.Of (Only Int64)) IO (), S.Stream (S.Of (Only Int64)) IO ())
streamsOnly ci = do
  conn <- connect ci
  a <- queryS conn "SELECT 2000"
  b <- queryS conn "SELECT 2000"
  Right (Only 1, a') <- S.next a
  Right (Only 1, b') <- S.next b
  pure (S.cons (Only 1) a', S.cons (Only 1) b')
{-# NOINLINE streamsOnly #-}

-- | @SELECT 2000@ answered with 2000 rows in 128-byte packets (167
-- packets, more than the client's window of 64), anything else as
-- 'answerRequests'.
longSelects :: SmpMock -> ClientMsg -> IO ()
longSelects m msg
  | cmType msg == PTSqlBatch, Just 2000 <- selectedNumber (batchText (cmBody msg)) =
      respondPackets m (cmSid msg) (tdsPackets 128 (longRows 2000))
  | otherwise = answerRequests m msg
