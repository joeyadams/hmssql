-- | A server that breaks SMP (A6, A10, the mock-server cases of
-- docs/dev/mars-research.md), against the mock server ("Mars.MockSmp"): whatever it
-- sends, the connection ends with the documented error, 'ProtocolError'
-- for a violation, @'ConnectionClosedBy' 'ClosedByServer'@ for a FIN on a
-- session the client didn't close or the end of the stream.  Every
-- response being read then fails with it (or with 'ConnectionBroken'
-- wrapping it), so does the next request, and 'close' still works.
module Mars.SmpViolationsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, readTVar, readTVarIO, retry)
import Control.Exception
import Control.Monad (forM_, replicateM, replicateM_, when)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Word (Word16, Word32, Word8)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (doneFinal, tokenBytes)
import Hmssql
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors
import Hmssql.Types (ServerMessage (..))
import Mars.MockSmp
import MockServer (errorToken, shutdownSend)

isProtocolError :: SomeException -> Bool
isProtocolError e = isJust (fromException e :: Maybe ProtocolError)

isClosedByServer :: SomeException -> Bool
isClosedByServer e = case fromException e of
  Just (ConnectionClosedBy ClosedByServer) -> True
  _ -> False

-- | 'close' returns normally.
closes :: Connection -> IO ()
closes conn = try @SomeException (close conn) >>= either (expectationFailure . ("close threw " ++) . show) pure

-- | The session's next SEQNUM and its window, as the mock has them.
nextOn :: SmpMock -> Word16 -> IO (Word32, Word32)
nextOn m sid = mockSession m sid >>= \case
  Just s -> pure (msServerSeq s + 1, msServerWindow s)
  Nothing -> throwIO (userError ("session " ++ show sid ++ " is not open on the mock"))

-- | An empty TDS packet, not the last of its message.
emptyPacket :: B.ByteString
emptyPacket = tdsPacket False B.empty

-- | The TDS packet with its length field changed by the amount.
withLengthOff :: Int -> B.ByteString -> B.ByteString
withLengthOff d p =
  let n = B.length p + d
   in B.take 2 p <> B.pack [fromIntegral (n `div` 256), fromIntegral n] <> B.drop 4 p

-- | Send a DATA packet on the session, with its next SEQNUM and the
-- window, carrying the payload, whatever the client's window.
dataWith :: SmpMock -> Word16 -> B.ByteString -> IO ()
dataWith m sid payload = stampData m sid payload >>= sendSmpRaw m

-- | A packet with the flags on session 0, its SEQNUM and window as a
-- control packet's would be.
flagged :: SmpMock -> Word8 -> IO ()
flagged m flags = do
  (n, w) <- nextOn m 0
  sendSmpRaw m (smpPacket flags 0 (n - 1) w B.empty)

-- | Two responses open, on sessions 0 and 1, each read up to its first row
-- and waiting for the rest ('partialSelects'), with a window of 4 (so the
-- client has ACKed each packet, and the mock knows its window); then the
-- server does what the case says.  Each reader, then the next request,
-- fails with the expected exception; 'close' returns normally.
violation :: String -> (SmpMock -> IO ()) -> (SomeException -> Bool) -> Spec
violation label act expected = it label $
  withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv -> within 30 $ do
    conn <- connect (smpConnectInfo srv) { connectMarsWindow = 4 }
    m <- nextMock srv
    s0 <- queryS conn "SELECT 1"
    s1 <- queryS conn "SELECT 2"
    Right (Only (1 :: Int64), rest0) <- S.next s0
    Right (Only (2 :: Int64), rest1) <- S.next s1
    awaitReceived m 5_000_000 ((== 2) . length . filter isAck) `shouldReturn` True
    act m
    r0 <- try (S.toList_ rest0)
    r1 <- try (S.toList_ rest1)
    r2 <- try (query1 conn "SELECT 3" :: IO (Only Int64))
    forM_ [("the reader on session 0", fmap (const ()) r0), ("the reader on session 1", fmap (const ()) r1), ("the next request", fmap (const ()) r2)] $
      \(who, r) -> case r of
        Left e | endedBy expected e -> pure ()
        Left e -> expectationFailure (who ++ " failed with " ++ show e)
        Right () -> expectationFailure (who ++ " succeeded")
    release conn `shouldReturn` False
    closes conn
    out <- nextOutcome srv
    outViolations out `shouldBe` []

spec :: Spec
spec = describe "a server that breaks SMP (mock server)" $ do
  describe "framing" $ do
    violation "a packet whose first byte is not 0x53 (a plain TDS packet): ProtocolError"
      (\m -> sendSmpRaw m (tdsPacket True (tokenBytes [doneFinal 0]))) isProtocolError
    forM_ [0, 1, 15] $ \len -> violation ("an SMP packet of length " ++ show len ++ ": ProtocolError")
      (\m -> sendSmpRaw m (smpPacketWithLength flagAck 0 len 1 5 B.empty)) isProtocolError

    forM_ [(flagAck, "ACK"), (flagFin, "FIN")] $ \(flag, name) ->
      forM_ [1, 4, 64] $ \n ->
        violation (name ++ " with " ++ show n ++ " payload bytes: ProtocolError")
          (\m -> nextOn m 0 >>= \(seqNum, window) ->
            sendSmpRaw m (smpPacket flag 0 (seqNum - 1) window (B.replicate n 0x63))) isProtocolError

    forM_ [1, 4, 64] $ \n -> it ("a FIN with " ++ show n ++ " payload bytes cannot free a locally closing session") $
      withSmpServer defaultSmpConfig { cfgAutoFin = False } $ \srv -> within 30 $ do
        withConnection (smpConnectInfo srv) $ \conn -> do
          m <- nextMock srv
          streams <- replicateM 11 (queryS conn "SELECT 1")
          mapM S.toList_ streams `shouldReturn` replicate 11 [Only (1 :: Int64)]
          query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int64)
          awaitReceived m 5_000_000 (any (\p -> isFin p && inSid p == 10)) `shouldReturn` True
          (seqNum, window) <- nextOn m 10
          sendSmpRaw m (smpPacket flagFin 10 (seqNum - 1) window (B.replicate n 0x63))
          e <- atomically $ readTVar (connEnded conn) >>= maybe retry pure
          isProtocolError e `shouldBe` True
          registrySize conn `shouldReturn` 11
          try (execute conn "SELECT 3") >>= \case
            Left err -> endedBy isProtocolError err `shouldBe` True
            Right _ -> expectationFailure "accepted work after malformed FIN"
          release conn `shouldReturn` False
        out <- nextOutcome srv
        outViolations out `shouldBe` []

  describe "sessions" $ do
    violation "an ACK for a session that is not open: ProtocolError"
      (\m -> sendSmpRaw m (smpPacket flagAck 7 0 4 B.empty)) isProtocolError
    violation "a DATA packet for a session that is not open: ProtocolError"
      (\m -> sendSmpRaw m (smpPacket flagData 2 1 4 emptyPacket)) isProtocolError
    violation "a FIN for a session open mid-response: ConnectionClosed ClosedByServer"
      (\m -> sendFin m 0) isClosedByServer
    violation "a FIN for the other open session: ConnectionClosed ClosedByServer"
      (\m -> sendFin m 1) isClosedByServer

    it "a FIN for an idle session: ConnectionClosed ClosedByServer at the next request" $
      withSmpServer defaultSmpConfig $ \srv -> within 30 $ do
        conn <- connect (smpConnectInfo srv)
        m <- nextMock srv
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int64)
        sendFin m 0
        -- Once the reader has taken the FIN (a request sent before would
        -- cross it, and fail as it reads).
        let ended = timeout 5_000_000 $ let loop = readTVarIO (connEnded conn) >>= maybe (threadDelay 5_000 >> loop) pure in loop
        ended >>= \case
          Just e -> isClosedByServer e `shouldBe` True
          Nothing -> expectationFailure "the FIN didn't end the connection"
        replicateM_ 2 $ try (query1 conn "SELECT 2" :: IO (Only Int64)) >>= \case
          Left e | endedBy isClosedByServer e -> pure ()
          other -> expectationFailure ("expected ConnectionClosed ClosedByServer, got " ++ show other)
        closes conn
        out <- nextOutcome srv
        outViolations out `shouldBe` []

    -- R14: a severity-20 error ends with a FIN on every session.  What
    -- the reader thread queued before the FINs is read before the end of
    -- the connection, whichever session it is on.
    -- With a window of 4 the client ACKs every packet it takes, the one
    -- with the error too, after the connection has ended.
    forM_ [False, True] $ \fins -> forM_ [4, 64] $ \window -> it ("a severity-20 error on one session preserves the error and ends both readers (FINs " ++ show fins ++ ", window " ++ show window ++ ")") $
      withSmpServer defaultSmpConfig { cfgRespond = Just partialSelects } $ \srv -> within 30 $ do
        conn <- connect (smpConnectInfo srv) { connectMarsWindow = window }
        m <- nextMock srv
        s0 <- queryS conn "SELECT 1"
        s1 <- queryS conn "SELECT 2"
        Right (Only (1 :: Int64), rest0) <- S.next s0
        Right (Only (2 :: Int64), rest1) <- S.next s1
        -- The mock has taken the ACKs for those rows (with a window of 4,
        -- one per packet) before it closes the sessions.
        awaitReceived m 5_000_000 ((== (if window == 4 then 2 else 0)) . length . filter isAck) `shouldReturn` True
        let fatal = ServerMessage 50000 1 20 "fatal" "mock" "" 1
        dataWith m 1 (tdsPacket True (tokenBytes [errorToken fatal, doneFinal 0]))
        when fins $ sendFin m 0 >> sendFin m 1
        -- The reader thread has taken both FINs (the connection has ended)
        -- before anything is read.
        when fins $ do
          let ended = timeout 5_000_000 $ let loop = readTVarIO (connEnded conn) >>= maybe (threadDelay 5_000 >> loop) pure in loop
          ended >>= \case
            Just e -> isClosedByServer e `shouldBe` True
            Nothing -> expectationFailure "the FINs didn't end the connection"
        try (S.toList_ rest1) >>= \case
          Left e | Just se <- fromException e -> msgClass (sqlError se) `shouldBe` 20
          Left e -> expectationFailure ("session 1's reader got " ++ show e ++ ", not the error")
          Right _ -> expectationFailure "the stream ended without its error"
        try (S.toList_ rest0) >>= \case
          Left e | endedBy (\x -> isClosedByServer x || isJust (fromException x :: Maybe SqlServerError)) e -> pure ()
          other -> expectationFailure ("session 0's reader: " ++ show (fmap length other))
        release conn `shouldReturn` False
        closes conn
        out <- nextOutcome srv
        outViolations out `shouldBe` []

  describe "sequence numbers" $ do
    violation "a DATA packet one SEQNUM ahead: ProtocolError"
      (\m -> nextOn m 0 >>= \(n, w) -> sendSmpRaw m (smpPacket flagData 0 (n + 1) w emptyPacket)) isProtocolError
    violation "a DATA packet repeating the last SEQNUM: ProtocolError"
      (\m -> nextOn m 0 >>= \(n, w) -> sendSmpRaw m (smpPacket flagData 0 (n - 1) w emptyPacket)) isProtocolError
    violation "a DATA packet with SEQNUM 0: ProtocolError"
      (\m -> nextOn m 1 >>= \(_, w) -> sendSmpRaw m (smpPacket flagData 1 0 w emptyPacket)) isProtocolError
    -- The client's window on session 1 is 5 (4, and the packet it read);
    -- packets 2 to 5 fill it, unread.
    violation "a DATA packet beyond the client's window: ProtocolError"
      (\m -> do
          Just s <- mockSession m 1
          msClientWindow s `shouldBe` 5
          replicateM_ 4 (dataWith m 1 emptyPacket)
          dataWith m 1 emptyPacket)
      isProtocolError

  describe "windows" $ do
    violation "an ACK with a window smaller than the last: ProtocolError"
      (\m -> raiseWindow m 0 10 >> nextOn m 0 >>= \(n, _) -> sendSmpRaw m (smpPacket flagAck 0 (n - 1) 9 B.empty)) isProtocolError
    violation "an ACK with a window below the initial 4: ProtocolError"
      (\m -> nextOn m 1 >>= \(n, _) -> sendSmpRaw m (smpPacket flagAck 1 (n - 1) 3 B.empty)) isProtocolError
    violation "a DATA packet with a window smaller than the last: ProtocolError"
      (\m -> raiseWindow m 0 10 >> nextOn m 0 >>= \(n, _) -> sendSmpRaw m (smpPacket flagData 0 n 9 emptyPacket)) isProtocolError
    -- Modulo 2^32, a window 2^31 or more ahead is behind.
    violation "an ACK with a window 2^31 ahead: ProtocolError"
      (\m -> nextOn m 0 >>= \(n, w) -> sendSmpRaw m (smpPacket flagAck 0 (n - 1) (w + 0x80000000) B.empty)) isProtocolError
    violation "a window that shrinks across 2^32 (from 10 past it to 8 short of it): ProtocolError"
      (\m -> do
          mapM_ (raiseWindow m 0) [0x80000003, 0xFFFFFFF0, 10]
          nextOn m 0 >>= \(n, _) -> sendSmpRaw m (smpPacket flagAck 0 (n - 1) 0xFFFFFFF8 B.empty))
      isProtocolError

  describe "DATA payloads (A6: one whole TDS packet each)" $ do
    violation "a TDS packet whose length field is one more than the payload: ProtocolError"
      (\m -> dataWith m 0 (withLengthOff 1 (tdsPacket False "abc"))) isProtocolError
    violation "a TDS packet whose length field is one less than the payload: ProtocolError"
      (\m -> dataWith m 0 (withLengthOff (-1) (tdsPacket False "abc"))) isProtocolError
    violation "two TDS packets in one payload: ProtocolError"
      (\m -> dataWith m 0 (emptyPacket <> emptyPacket)) isProtocolError
    violation "a truncated TDS packet (5 bytes): ProtocolError"
      (\m -> dataWith m 0 (B.take 5 emptyPacket)) isProtocolError
    violation "an empty payload: ProtocolError"
      (\m -> dataWith m 0 B.empty) isProtocolError

  describe "flags" $
    forM_ [(0x00, "no flag"), (0x10, "an unknown flag"), (0x80, "an unknown flag"), (0x03, "SYN and ACK"), (0x0C, "FIN and DATA"), (0x01, "SYN")] $
      \(flags, what) -> violation ("flags " ++ show flags ++ " (" ++ what ++ "): ProtocolError") (`flagged` flags) isProtocolError

  describe "the end of the stream" $ do
    violation "between packets: ConnectionClosed ClosedByServer"
      (\m -> shutdownSend (mockConn m)) isClosedByServer
    violation "in the middle of an SMP header: ConnectionClosed ClosedByServer"
      (\m -> sendSmpRaw m (B.take 7 (smpPacket flagAck 0 1 5 B.empty)) >> shutdownSend (mockConn m)) isClosedByServer
    violation "in the middle of a DATA packet: ConnectionClosed ClosedByServer"
      (\m -> do
          (n, w) <- nextOn m 0
          sendSmpRaw m (B.take 30 (smpPacket flagData 0 n w (tdsPacket False (B.replicate 50 0))))
          shutdownSend (mockConn m))
      isClosedByServer
