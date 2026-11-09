-- | What the client keeps, and what it does, while a server says nothing:
-- a request the server never answers, or a response it stops sending
-- part-way, waited for on a plain connection, on a MARS connection and
-- over strict TLS.  The wait must hold the live heap where it was and
-- allocate nothing (a thread spinning on the socket or a buffer growing
-- with time would show in both), and when a 'timeout' interrupts the
-- request and the server never acknowledges the Attention, the
-- connection must break on the next request's interrupted drain and then
-- fail every request at once, still without growing.
--
-- The mock servers read everything the client sends until it closes, and
-- send nothing after the cut.  @HMSSQL_TEST_SLOW=1@ adds a minute-long
-- wait for each transport.  The measurements behind these bounds, over
-- 15 minutes, are in docs/dev/design.md ("Memory and performance").
module Resources.StalledServerSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, replicateM, replicateM_, unless, when)
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import GHC.Conc (ThreadStatus (..), threadStatus)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import qualified Network.TLS as TLS
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Mock (colMetaBigint, rowBigint)
import Hmssql
import Hmssql.Errors
import Hmssql.Query (queryMulti)
import Hmssql.Tds.Context (TdsVersion (..), defaultTdsContext)
import Hmssql.Tds.Packet
import Mars.MockSmp
import MockServer
import TestDb (slow)

-- | How the client reaches the mock.
data Transport = Plain | Mars | Strict
  deriving (Eq, Show)

-- | Where the server stops.
data Cut
  = NoAnswer
    -- ^ Not a byte of the response.
  | MidPacket
    -- ^ A column and some rows, in a packet whose header promises 4096
    -- bytes and of which 108 arrive.
  | MidValue
    -- ^ A @varbinary(max)@ value of unknown length, in whole packets, cut
    -- in a chunk after about 240 KB: a row longer than 64 KiB, which the
    -- row reader copies out of each packet as it arrives.
  deriving (Eq, Show)

-- | A server that has stopped answering.
data Stalled = Stalled
  { stConnectInfo :: ConnectInfo
  , stAwaitRequest :: IO ()
    -- ^ Wait until the client's first request has arrived and the part of
    -- the response the cut leaves has been sent.
  , stNextMessage :: IO PacketType
    -- ^ The type of the next message the client sends after it (waits up
    -- to 10 s).
  }

-- | The part of the response the cut leaves, as the packets to send.
cutPackets :: Cut -> [B.ByteString]
cutPackets = \case
  NoAnswer -> []
  MidPacket -> [B.take 108 (packet (4096 :: Int) (rows 500))]
  -- 60 packets: within the MARS window (64 by default).
  MidValue -> map (\body -> packet (headerLength + B.length body) body) (take 60 (chunksOf 4088 plp))
  where
    rows n = LB.toStrict (Put.runPut (colMetaBigint "" >> mapM_ (rowBigint . fromIntegral) [1 .. n :: Int]))
    packet len body = LB.toStrict $ Put.runPut $ do
      putHeader Header
        { headerType = PTTabularResult, headerStatus = PacketStatus 0, headerPacketLength = fromIntegral len
        , headerSpid = 0, headerPacketId = 1, headerWindow = 0 }
      Put.putByteString body
    -- COLMETADATA of one nullable varbinary(max) column, then its row: a
    -- PLP value of unknown length in chunks of 8000 bytes, never ended.
    plp = LB.toStrict $ Put.runPut $ do
      Put.putWord8 0x81 >> Put.putWord16le 1 >> Put.putWord32le 0 >> Put.putWord16le 0x0001
      Put.putWord8 0xA5 >> Put.putWord16le 0xFFFF >> Put.putWord8 0
      Put.putWord8 0xD1 >> Put.putWord64le 0xFFFFFFFFFFFFFFFE
      replicateM_ 40 (Put.putWord32le 8000 >> Put.putByteString (B.replicate 8000 0x5A))
    chunksOf n bs
      | B.length bs < n = []
      | otherwise = let (a, b) = B.splitAt n bs in a : chunksOf n b

withStalledServer :: Transport -> Cut -> (Stalled -> IO a) -> IO a
withStalledServer transport cut act = case transport of
  Mars -> withSmpServer defaultSmpConfig { cfgRespond = Nothing, cfgHoldLimit = 600 } $ \srv -> do
    mock <- newEmptyMVar
    let theMock = readMVar mock
    act Stalled
      { stConnectInfo = smpConnectInfo srv
      , stAwaitRequest = do
          m <- nextMock srv
          putMVar mock m
          msg <- expectMessage m
          case cut of
            -- SMP carries whole TDS packets: the SMP packet is cut instead.
            MidPacket -> stampData m (cmSid msg) (tdsPacket False (B.replicate 4088 0)) >>= sendSmpRaw m . B.take (16 + 108)
            _ -> unless (null (cutPackets cut)) $ respondPackets m (cmSid msg) (cutPackets cut)
      , stNextMessage = theMock >>= fmap cmType . expectMessage
      }
  _ -> do
    arrived <- newEmptyMVar
    seen <- newChan
    let handler mc = case transport of
          Strict -> strictLogin mc >>= \(recvMsg, send) -> stall recvMsg send
          _ -> do
            _ <- serveLogin defaultLoginResponse mc
            stall (fmap fst <$> recvMessageMaybe mc) (sendRaw mc)
        stall recvMsg send = do
          _ <- recvMsg >>= maybe (throwIO MockClientClosed) pure
          mapM_ send (cutPackets cut)
          putMVar arrived ()
          let loop = recvMsg >>= mapM_ (\t -> writeChan seen t >> loop)
          loop
    withMockServer handler $ \srv -> act Stalled
      { stConnectInfo = (mockConnectInfo srv)
          { connectEncryption = if transport == Strict then EncryptStrict else EncryptNotSup
          , connectTls = defaultTlsSettings { tlsTrustServerCertificate = True }
          }
      , stAwaitRequest = waitFor "the request" (takeMVar arrived)
      , stNextMessage = waitFor "a message" (readChan seen)
      }
  where
    waitFor what a = timeout 10_000_000 a >>= maybe (throwIO (MockUnexpected ("no " ++ what ++ " in 10 s"))) pure

-- | A strict-encryption login over the mock's connection: the TLS
-- handshake (selecting @tds/8.0@), LOGIN7 and its answer.  Returns how to
-- receive the type of each further message (Nothing once the client has
-- closed) and how to send bytes, in TLS records.
strictLogin :: MockConn -> IO (IO (Maybe PacketType), B.ByteString -> IO ())
strictLogin mc = do
  creds <- either (throwIO . MockUnexpected) pure (TLS.credentialLoadX509FromMemory mockTlsCert mockTlsKey)
  let backend = TLS.Backend
        { TLS.backendFlush = pure ()
        , TLS.backendClose = pure ()
        , TLS.backendSend = sendRaw mc
        , TLS.backendRecv = fmap (fromMaybe B.empty) . recvBytes mc
        }
      params = TLS.defaultParamsServer
        { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] }
        , TLS.serverHooks = TLS.defaultServerHooks { TLS.onALPNClientSuggest = Just (\_ -> pure "tds/8.0") }
        }
  ctx <- TLS.contextNew backend params
  TLS.handshake ctx
  buf <- newIORef B.empty
  let send = TLS.sendData ctx . LB.fromStrict
      -- At least n bytes in the buffer, or False at the end of the stream.
      need n = do
        b <- readIORef buf
        if B.length b >= n
          then pure True
          else try (TLS.recvData ctx) >>= \case
            Right more | not (B.null more) -> writeIORef buf (b <> more) >> need n
            Right _ -> pure False
            Left (_ :: SomeException) -> pure False
      -- The next whole message's type.
      recvMsg = need headerLength >>= \case
        False -> pure Nothing
        True -> do
          hdr <- readHeader <$> readIORef buf
          let len = fromIntegral (headerPacketLength hdr)
          need len >>= \case
            False -> pure Nothing
            True -> do
              modifyIORef' buf (B.drop len)
              if headerStatus hdr .&. statusEndOfMessage /= PacketStatus 0
                then pure (Just (headerType hdr))
                else recvMsg
  recvMsg >>= \case
    Just PTLogin7 -> pure ()
    other -> throwIO (MockUnexpected ("expected LOGIN7, got " ++ show other))
  mapM_ send (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0)
    (Put.runPut (loginAckToken Tds80 "mock" >> doneToken 0 0)))
  pure (recvMsg, send)

-- | The live heap after a major GC, and the bytes allocated so far.
-- Evaluated: a lazy field would keep the whole 'RTSStats' record alive,
-- about 1.2 KB a reading, which reads as growth.
reading :: IO (Word64, Word64)
reading = do
  performMajorGC
  s <- getRTSStats
  let !live = gcdetails_live_bytes (gc s)
      !allocated = allocated_bytes s
  pure (live, allocated)

-- | How much the live heap may grow while nothing happens: a few
-- objects, not a buffer per second.
liveBound :: Word64
liveBound = 64 * 1024

-- | How much the process may allocate in a wait of the given seconds
-- while nothing happens: about 100 KB goes to the five readings
-- themselves, and the runtime's own threads (the timer manager among
-- them) allocate about 40 KB a second however long the wait, which over
-- the slow test's 60 s is more than 2 MiB.  A thread polling the socket,
-- or reading on, would allocate megabytes a second.
allocBound :: Int -> Word64
allocBound seconds = 2 * 1024 * 1024 + 64 * 1024 * fromIntegral seconds

-- | Wait until the thread has been blocked at three looks 100 ms apart:
-- it has read what arrived and waits for more.
awaitBlocked :: ThreadId -> IO ()
awaitBlocked tid = go (0 :: Int) (0 :: Int)
  where
    go streak n
      | streak >= 3 = pure ()
      | n > 100 = expectationFailure "the waiting thread was never blocked: it is still running after 10 s"
      | otherwise = do
          threadDelay 100_000
          st <- threadStatus tid
          case st of
            ThreadBlocked _ -> go (streak + 1) (n + 1)
            ThreadRunning -> go 0 (n + 1)
            other -> expectationFailure ("the waiting thread is " ++ show other)

-- | A request waits for the cut response for the given seconds: the live
-- heap must stay where it was once the waiting thread had read what came
-- (four readings, spread over the wait), and the process must allocate
-- next to nothing.  Then 'close' ends the wait.
waitsFlat :: Transport -> Cut -> Int -> Expectation
waitsFlat transport cut seconds = do
  enabled <- getRTSStatsEnabled
  unless enabled $ pendingWith "run with +RTS -T"
  withStalledServer transport cut $ \st -> do
    conn <- connect (stConnectInfo st)
    result <- newEmptyMVar
    waiter <- forkIO $ try (queryMulti conn "SELECT 1") >>= putMVar result
    -- On every exit the connection is closed, which ends the request.
    (live0, lives, allocated) <- flip finally (close conn) $ do
      stAwaitRequest st
      awaitBlocked waiter
      (live0, alloc0) <- reading
      lives <- replicateM 4 (threadDelay (seconds * 250_000) >> fst <$> reading)
      (_, alloc1) <- reading
      pure (live0, lives, alloc1 - alloc0)
    r <- timeout 10_000_000 (takeMVar result)
    case r of
      Nothing -> expectationFailure "the waiting request didn't end when the connection was closed"
      Just (Right sets) -> expectationFailure ("the request returned " ++ show (length sets) ++ " result sets")
      Just (Left e) -> case fromException e of
        Just (ConnectionClosedBy ClosedByClient) -> pure ()
        _ -> expectationFailure ("the waiting request ended with " ++ show e)
    let grown = maximum lives - min live0 (maximum lives)
    when (grown > liveBound) $ expectationFailure $
      "the live heap grew by " ++ show grown ++ " bytes in " ++ show seconds ++ " s (from " ++ show live0
        ++ "; readings " ++ show lives ++ ")"
    when (allocated > allocBound seconds) $ expectationFailure $
      "the process allocated " ++ show allocated ++ " bytes in " ++ show seconds ++ " s of waiting"
        ++ " (the whole process: a thread an earlier test left polling counts too)"

-- | A 'timeout' interrupts the request: the Attention goes out, and the
-- server never acknowledges it.  The next request drains first, so it
-- waits too; a 'timeout' interrupts that drain, which breaks the
-- connection.  Every request after fails at once with 'ConnectionBroken',
-- sends nothing, and leaves nothing behind.
timeoutThenBroken :: Transport -> Expectation
timeoutThenBroken transport = withStalledServer transport NoAnswer $ \st -> do
  conn <- connect (stConnectInfo st)
  flip finally (close conn) $ do
    r1 <- timeout 500_000 (query conn "SELECT 1" :: IO [Only Int64])
    r1 `shouldBe` Nothing
    stAwaitRequest st
    stNextMessage st `shouldReturn` PTAttention
    r2 <- timeout 500_000 (query conn "SELECT 1" :: IO [Only Int64])
    r2 `shouldBe` Nothing
    let broken = try (query conn "SELECT 1" :: IO [Only Int64]) >>= \case
          Left (ConnectionBroken _) -> pure ()
          Right _ -> expectationFailure "a request on the stalled connection returned"
    broken
    (live0, _) <- reading
    replicateM_ 10_000 broken
    (live1, _) <- reading
    when (live1 > live0 + liveBound) $ expectationFailure $
      "the live heap grew by " ++ show (live1 - live0) ++ " bytes over 10,000 requests on the broken connection"
    -- Nothing more reached the server: no request, and no second Attention.
    extra <- timeout 300_000 (stNextMessage st)
    extra `shouldBe` Nothing

spec :: Spec
spec = describe "a server that stops answering" $
  forM_ [Plain, Mars, Strict] $ \transport -> describe (show transport) $ do
    forM_ [NoAnswer, MidPacket, MidValue] $ \cut ->
      it ("a request waiting at " ++ show cut ++ " keeps the heap flat and allocates nothing (2 s)") $
        waitsFlat transport cut 2
    slow $ it "a request waiting at NoAnswer keeps the heap flat and allocates nothing (60 s)" $
      waitsFlat transport NoAnswer 60
    it "a timeout, then an Attention never acknowledged: the next request's drain waits, a timeout breaks the connection, and 10,000 requests after fail at once without growing the heap" $
      timeoutThenBroken transport
