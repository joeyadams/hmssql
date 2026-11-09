-- | SMP flow control, against the mock server ("Mars.MockSmp"), which
-- checks every packet the client sends: a request is held to the window
-- the server advertised (4 until it raises it); the client ACKs as it
-- consumes a response, every @max 1 (window / 16)@ packets, raising its
-- WNDW by as many; it ACKs even while its own DATA window is used up (or
-- the two sides would wait for each other); ACK, SYN and FIN leave the
-- next DATA SEQNUM as it was.  Sequence numbers and windows wrap at 2^32
-- (A11): a window the server raises past 2^32 is read as larger, and a
-- session whose SEQNUMs cross 2^32 (both sides' state shifted there)
-- carries responses, and should carry requests, as before.
module Mars.SmpFlowSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async, asyncThreadId, poll, wait, withAsync)
import Control.Exception
import Control.Monad (forM_, replicateM, void)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Text as T
import Data.Word (Word16, Word32)
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (elapsed, within)
import Concurrency.Mock (batchText, doneFinal, selectedNumber, tokenBytes)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Tds.Packet (PacketType (..))
import Mars.Harness (newSteps, pollFor, withinTraced)
import Mars.MockSmp
import TestConfig (SessionIdentity (..))

-- | Answer @SELECT 4@ with 'longRows' of 2000 rows in 128-byte packets
-- ('longPackets'), and everything else as 'answerRequests'.
longForFour :: SmpMock -> ClientMsg -> IO ()
longForFour m msg
  | cmType msg == PTSqlBatch, Just 4 <- selectedNumber (batchText (cmBody msg)) = respondPackets m (cmSid msg) longPackets
  | otherwise = answerRequests m msg

-- | 167 packets: more than the client's default window of 64.
longPackets :: [B.ByteString]
longPackets = tdsPackets 128 (longRows 2000)

dataOn :: Word16 -> [SmpIn] -> [SmpIn]
dataOn sid = filter (\p -> isData p && inSid p == sid)

-- | What each packet's SEQNUM must be, session by session: a DATA packet
-- one more than the session's last DATA packet, anything else the last
-- DATA packet's; a SYN (which opens the session again) 0.
expectedSeqs :: [SmpIn] -> [Word32]
expectedSeqs = go []
  where
    go _ [] = []
    go lasts (p : ps)
      | isSyn p = 0 : go ((inSid p, 0) : lasts) ps
      | isData p = let n = last' + 1 in n : go ((inSid p, n) : lasts) ps
      | otherwise = last' : go lasts ps
      where
        last' = fromMaybe 0 (lookup (inSid p) lasts)

-- | A batch of about 240 KB: 59 packets of 4096 bytes (the mock grants
-- no other packet size).
bigBatch :: Query
bigBatch = rawSql ("SELECT 1 -- " <> T.replicate 120_000 "x")

spec :: Spec
spec = describe "SMP flow control (mock server)" $ do
  it "a request and its response on session 0" $
    withSmpServer defaultSmpConfig $ \srv -> do
      within 30 $ withConnection (smpConnectInfo srv) $ \conn ->
        query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int64)
      out <- nextOutcome srv
      [(inFlags p, inSid p, inSeq p, inWindow p) | p <- outReceived out] `shouldBe` [(flagSyn, 0, 0, 64), (flagData, 0, 1, 64)]
      [(cmSid msg, cmType msg, batchText (cmBody msg)) | msg <- outMessages out] `shouldBe` [(0, PTSqlBatch, "SELECT 7")]
      outViolations out `shouldBe` []

  it "requests one after another all go on session 0, their SEQNUMs one apart" $
    withSmpServer defaultSmpConfig $ \srv -> do
      within 30 $ withConnection (smpConnectInfo srv) $ \conn ->
        forM_ [1 .. 5 :: Int64] $ \i -> query1 conn (rawSql ("SELECT " <> T.pack (show i))) `shouldReturn` Only i
      out <- nextOutcome srv
      [(inFlags p, inSid p, inSeq p) | p <- outReceived out]
        `shouldBe` (flagSyn, 0, 0) : [(flagData, 0, i) | i <- [1 .. 5]]
      outViolations out `shouldBe` []

  it "a request longer than the window: 4 DATA packets, then nothing until the server raises it" $
    withSmpServer defaultSmpConfig { cfgAutoAck = False } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        m <- nextMock srv
        let sent = length . dataOn 0
        req <- async (execute conn bigBatch)
        awaitReceived m 5_000_000 ((>= 4) . sent) `shouldReturn` True
        threadDelay 300_000
        sent <$> receivedSoFar m `shouldReturn` 4
        isNothing <$> poll req `shouldReturn` True
        raiseWindow m 0 8
        awaitReceived m 5_000_000 ((>= 8) . sent) `shouldReturn` True
        threadDelay 200_000
        sent <$> receivedSoFar m `shouldReturn` 8
        raiseWindow m 0 1000
        wait req `shouldReturn` 0
        (> 8) . sent <$> receivedSoFar m `shouldReturn` True
      out <- nextOutcome srv
      outViolations out `shouldBe` []

  it "drains the Attention acknowledgement when the response finishes while cancellation waits for credit" $ do
    let -- Hold the fourth response after its first row, with no EOM.
        partial m msg
          | cmType msg == PTSqlBatch, Just 4 <- selectedNumber (batchText (cmBody msg)) =
              partialSelects m msg
          | otherwise = answerRequests m msg
    withSmpServer defaultSmpConfig { cfgAutoAck = False, cfgRespond = Just partial } $ \srv -> do
      within 30 $ withConnection (smpConnectInfo srv) $ \conn -> do
        m <- nextMock srv
        forM_ [1 .. 3 :: Int64] $ \i -> query1 conn (rawSql ("SELECT " <> T.pack (show i))) `shouldReturn` Only i
        stream <- queryS conn "SELECT 4"
        Right (Only (4 :: Int64), _) <- S.next stream
        withAsync (cancelActiveStatement conn) $ \cancelling -> do
          pollFor 5 (== ThreadBlocked BlockedOnSTM) (threadStatus (asyncThreadId cancelling))
            `shouldReturn` ThreadBlocked BlockedOnSTM
          -- These travel in order: the final response is queued before the
          -- credit wakes the blocked Attention send. Its acknowledgement
          -- is a separate message and must not become SELECT 99's result.
          sendTdsPacket m 0 (tdsPacket True (tokenBytes [doneFinal 1]))
          raiseWindow m 0 8
          wait cancelling
        query1 conn "SELECT 99" `shouldReturn` Only (99 :: Int64)
      out <- nextOutcome srv
      length [msg | msg <- outMessages out, cmType msg == PTAttention] `shouldBe` 1
      outViolations out `shouldBe` []
      outErrors out `shouldBe` []

  forM_ [4, 5, 16, 17, 33, 64, 100] $ \window ->
    it ("with connectMarsWindow " ++ show window ++ ", ACKs every max 1 (window / 16) packets consumed, the window growing by as many") $
      withSmpServer defaultSmpConfig { cfgRespond = Just longForFour } $ \srv -> do
        rows <- within 60 $ withConnection (smpConnectInfo srv) { connectMarsWindow = window } $ \conn ->
          query conn "SELECT 4"
        rows `shouldBe` map Only [1 .. 2000 :: Int64]
        out <- nextOutcome srv
        let cadence = max 1 (window `div` 16)
        [(inSid p, inSeq p, inWindow p) | p <- outReceived out, isAck p]
          `shouldBe` [(0, 1, fromIntegral (window + cadence * k)) | k <- [1 .. length longPackets `div` cadence]]
        outViolations out `shouldBe` []

  it "ACKs a long response while its own DATA window is used up, and sends no DATA until it is raised" $
    withSmpServer defaultSmpConfig { cfgAutoAck = False, cfgRespond = Just longForFour } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        m <- nextMock srv
        forM_ [1 .. 3 :: Int64] $ \i -> query1 conn (rawSql ("SELECT " <> T.pack (show i))) `shouldReturn` Only i
        -- The fourth request uses up the window of 4 the server never
        -- raises; its response is longer than the client's window of 64.
        query conn "SELECT 4" `shouldReturn` map Only [1 .. 2000 :: Int64]
        let ackCount = length longPackets `div` 4
        awaitReceived m 5_000_000 ((== ackCount) . length . filter isAck) `shouldReturn` True
        received <- receivedSoFar m
        -- The window grows from the one the request carried (64, and one
        -- per packet of the three responses before).
        let fourth = inWindow (dataOn 0 received !! 3)
        fourth `shouldBe` 67
        [(inSeq p, inWindow p) | p <- received, isAck p]
          `shouldBe` [(4, fourth + 4 * k) | k <- [1 .. fromIntegral ackCount]]
        req <- async (query1 conn "SELECT 5")
        threadDelay 300_000
        isNothing <$> poll req `shouldReturn` True
        length . dataOn 0 <$> receivedSoFar m `shouldReturn` 4
        raiseWindow m 0 5
        wait req `shouldReturn` Only (5 :: Int64)
      out <- nextOutcome srv
      outViolations out `shouldBe` []

  it "ACK, SYN and FIN leave the next DATA SEQNUM as it was" $
    withSmpServer defaultSmpConfig { cfgRespond = Just longForFour } $ \srv -> do
      within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
        -- ACKs on session 0, then DATA on it again.
        length <$> (query conn "SELECT 4" :: IO [Only Int64]) `shouldReturn` 2000
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int64)
        -- SYNs for sessions 1 to 11, then FINs for 11 and 10 (more than
        -- ten idle), then DATA on the rest.
        streams <- replicateM 12 (queryS conn "SELECT 2")
        mapM S.toList_ streams `shouldReturn` replicate 12 [Only (2 :: Int64)]
        query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int64)
        streams' <- replicateM 10 (queryS conn "SELECT 5")
        mapM S.toList_ streams' `shouldReturn` replicate 10 [Only (5 :: Int64)]
      out <- nextOutcome srv
      let received = outReceived out
      map inSeq received `shouldBe` expectedSeqs received
      [length (filter f received) > 0 | f <- [isAck, isSyn, isFin]] `shouldBe` [True, True, True]
      outViolations out `shouldBe` []

  describe "A11: modulo 2^32" $ do
    it "a window the server raises past 2^32 is larger, not smaller: the client sends up to it" $
      withSmpServer defaultSmpConfig { cfgAutoAck = False } $ \srv -> do
        within 60 $ withConnection (smpConnectInfo srv) $ \conn -> do
          m <- nextMock srv
          -- Each step is less than 2^31: 4, 2^31 + 3, 2^32 - 16, then 10
          -- past 2^32.
          mapM_ (raiseWindow m 0) [0x80000003, 0xFFFFFFF0, 10]
          forM_ [1 .. 10 :: Int64] $ \i -> query1 conn (rawSql ("SELECT " <> T.pack (show i))) `shouldReturn` Only i
          req <- async (query1 conn "SELECT 11")
          threadDelay 300_000
          isNothing <$> poll req `shouldReturn` True
          raiseWindow m 0 11
          wait req `shouldReturn` Only (11 :: Int64)
        out <- nextOutcome srv
        map inSeq (dataOn 0 (outReceived out)) `shouldBe` [1 .. 11]
        outViolations out `shouldBe` []

    -- The client can't send or receive 2^32 packets in a test, and no
    -- packet of the protocol sets a session's sequence numbers: they start
    -- at 0 on both sides.  So the state of session 0 is shifted, on the
    -- client and on the mock alike, to just short of 2^32, as if that many
    -- packets had gone each way ('shiftClientSession', 'shiftSession').
    it "a response whose SEQNUMs cross 2^32, and the client's windows crossing it as it ACKs" $
      withSmpServer defaultSmpConfig { cfgRespond = Just longForFour } $ \srv -> do
        -- The response's 167 packets cross 2^32 at the 101st; the
        -- client's window (the offset and 64) at its 9th ACK.
        let offset = 0 - 100
        out <- acrossTheWrap srv offset $ \m conn -> do
          query conn "SELECT 4" `shouldReturn` map Only [1 .. 2000 :: Int64]
          query1 conn "SELECT 9" `shouldReturn` Only (9 :: Int64)
          fmap msServerSeq <$> mockSession m 0 `shouldReturn` Just (offset + 168)
        map inSeq (dataOn 0 (outReceived out)) `shouldBe` [offset + 1, offset + 2]
        let acks = [inWindow p | p <- outReceived out, isAck p]
        acks `shouldBe` [offset + 64 + 4 * k | k <- [1 .. 41]]
        (any (> 0xFFFFFF00) acks, any (< 0x100) acks) `shouldBe` (True, True)

    it "a request whose SEQNUMs cross 2^32" $ do
      -- (A list enumerated from a Word32 stops at its largest number.)
      withSmpServer defaultSmpConfig { cfgRespond = Just longForFour } $ \srv -> do
        -- The request's 59 packets cross 2^32 at the 31st.
        let offset = 0 - 30
        out <- acrossTheWrap srv offset $ \_ conn -> do
          execute conn bigBatch `shouldReturn` 0
          query1 conn "SELECT 9" `shouldReturn` Only (9 :: Int64)
        let seqs = map inSeq (dataOn 0 (outReceived out))
        seqs `shouldBe` take (length seqs) (iterate (+ 1) (offset + 1))
        (length seqs > 31, 0 `elem` seqs) `shouldBe` (True, True)

  -- The suite's hang detector for MARS tests ('withinTraced'): its limit is
  -- on time without progress on the connection, not on the test's time,
  -- since a loaded server can serve a connection slowly for minutes
  -- (docs/dev/protocol-notes.md, "The server under load").
  describe "the hang detector of the MARS tests (withinTraced)" $ do
    let nobody = SessionIdentity 0 "none"
    it "fails a test whose connection stops moving, at its limit" $
      withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv -> within 60 $
        withConnection (smpConnectInfo srv) $ \conn -> do
          steps <- newSteps "the query"
          (r, t) <- elapsed $ try (withinTraced 2 conn nobody steps (query conn "SELECT 7" :: IO [Only Int64]))
          case r of
            Left (e :: IOException) -> show e `shouldContain` "no progress on the connection for"
            Right rows -> expectationFailure ("the query returned " ++ show rows)
          t `shouldSatisfy` (< 15)

    it "lets through a test whose connection moves slowly past the limit" $
      withSmpServer defaultSmpConfig { cfgRespond = Just slowForFour } $ \srv -> within 60 $
        withConnection (smpConnectInfo srv) $ \conn -> do
          steps <- newSteps "the query"
          (rows, t) <- elapsed $ withinTraced 2 conn nobody steps (query conn "SELECT 4" :: IO [Only Int64])
          rows `shouldBe` map Only [1 .. 80]
          t `shouldSatisfy` (> 2)
  where
    -- @SELECT 4@ answered with a packet every 0.4 s, eight in all.
    slowForFour m msg
      | cmType msg == PTSqlBatch, Just 4 <- selectedNumber (batchText (cmBody msg)) =
          void $ forkIO $ forM_ (tdsPackets 128 (longRows 80)) (\p -> threadDelay 400_000 >> respondPackets m (cmSid msg) [p])
            `catch` \(_ :: SomeException) -> pure ()
      | otherwise = answerRequests m msg

-- | Connect, shift session 0 on both sides by the offset, run the action
-- (for at most 20 s), and close; what the mock saw, which must be no
-- violation (checked before the action's failure is rethrown).
acrossTheWrap :: SmpServer -> Word32 -> (SmpMock -> Connection -> IO ()) -> IO SmpOutcome
acrossTheWrap srv offset act = do
  r <- try $ within 20 $ withConnection (smpConnectInfo srv) $ \conn -> do
    m <- nextMock srv
    shiftClientSession conn 0 offset
    shiftSession m 0 offset
    act m conn
  out <- nextOutcome srv
  outViolations out `shouldBe` []
  either (\(e :: SomeException) -> throwIO e) pure r
  pure out
