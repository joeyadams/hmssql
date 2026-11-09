-- | The SMP wire format: "Hmssql.Tds.Smp"'s header against an independent
-- encoding (the mock's) and the control packets; then the client's parsing of SMP packets that arrive split across TCP chunks
-- anywhere, against the mock server ("Mars.MockSmp"); then the writes the
-- client hands its backend, each of which must be whole SMP packets.
module Mars.SmpWireSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Monad (forM, forM_)
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import qualified Data.Text as T
import Data.Word (Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import Streaming (Of, Stream)
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Concurrency.Harness (within)
import Concurrency.Mock (colMetaBigint, doneFinal, rowBigint)
import Hmssql
import Hmssql.Connection.Backend (Backend (..), tcpBackend)
import Hmssql.Tds.Smp
import Mars.MockSmp

-- | Sequence numbers and windows, near 0 and 2^32 as often as anywhere.
genWord32 :: Gen Word32
genWord32 = Gen.choice
  [ Gen.word32 Range.linearBounded
  , Gen.word32 (Range.linear 0 100)
  , (maxBound -) <$> Gen.word32 (Range.linear 0 100)
  , (0x80000000 +) . subtract 50 <$> Gen.word32 (Range.linear 0 100)
  ]

genFlag :: Gen SmpFlag
genFlag = Gen.element [SmpSyn, SmpAck, SmpFin, SmpData]

spec :: Spec
spec = do
  describe "the SMP header (Hmssql.Tds.Smp)" $ do
    it "has MC-SMP's identifier, flags, length and initial window" $ do
      smpIdentifier `shouldBe` 0x53
      smpHeaderLength `shouldBe` 16
      map smpFlagWord [SmpSyn, SmpAck, SmpFin, SmpData] `shouldBe` [0x01, 0x02, 0x04, 0x08]
      smpInitialWindow `shouldBe` 4

    it "is written as the mock encodes it, little-endian, and parses back" $ hedgehog $ do
      flag <- forAll genFlag
      sid <- forAll $ Gen.word16 Range.linearBounded
      len <- forAll $ Gen.int (Range.linear 16 (16 + 65535))
      sq <- forAll genWord32
      w <- forAll genWord32
      let bytes = BI.unsafeCreate smpHeaderLength $ \p -> pokeSmpHeader p flag sid len sq w
      bytes === smpPacketWithLength (smpFlagWord flag) sid (fromIntegral len) sq w B.empty
      readSmpHeader bytes === SmpHeader (smpFlagWord flag) sid (fromIntegral len) sq w

    it "parses what the mock encodes, whatever the flags" $ hedgehog $ do
      flags <- forAll $ Gen.word8 Range.linearBounded
      sid <- forAll $ Gen.word16 Range.linearBounded
      len <- forAll genWord32
      sq <- forAll genWord32
      w <- forAll genWord32
      tailBytes <- forAll $ Gen.bytes (Range.linear 0 20)
      readSmpHeader (smpPacketWithLength flags sid len sq w tailBytes) === SmpHeader flags sid len sq w

  describe "smpControlPacket" $
    it "is the header alone, of length 16, with the SEQNUM and WNDW given" $ hedgehog $ do
      flag <- forAll genFlag
      sid <- forAll $ Gen.word16 Range.linearBounded
      sq <- forAll genWord32
      w <- forAll genWord32
      smpControlPacket flag sid sq w === smpPacket (smpFlagWord flag) sid sq w B.empty

  describe "SMP packets split across TCP chunks (mock server)" $ do
    -- About 30 DATA packets, with ACKs between them, sent a byte at a
    -- time with a pause after each, so the client's reader receives them
    -- in pieces cut at every offset of a header and of a packet.
    it "a byte at a time: parsed as unsplit" $
      splitResponse 40 60 (\bytes -> map B.singleton (B.unpack bytes)) 300 >>= (`shouldBe` [1 .. 40])

    it "in random chunks: parsed as unsplit" $ hedgehog $ do
      rows <- forAll $ Gen.int (Range.linear 0 50)
      packetSize <- forAll $ Gen.int (Range.linear 20 200)
      sizes <- forAll $ Gen.list (Range.linear 1 400) (Gen.int (Range.linear 1 40))
      got <- evalIO $ splitResponse rows packetSize (chunksOfSizes sizes) 100
      got === [1 .. fromIntegral rows]

  -- SQL Server reads a pipe a write at a time and drops a connection
  -- whose write holds part of a packet (protocol-notes.md, "Shared Memory
  -- and Named Pipes").  A plaintext SMP packet is made as two pieces, its
  -- header and its TDS packet, and the pipe backend once wrote each piece
  -- as a write of its own: every MARS connection over a pipe without
  -- encryption was dropped at its first request (bugs-found.md).  The
  -- pipe backend makes each write 'backendSendMany' is given one write,
  -- so each must be whole packets, whatever pieces it comes in.  This
  -- checks what the connection gives the backend; that the pipe backend
  -- keeps each write one is checked against the server, by the MARS tests
  -- under EncryptOff and EncryptNotSup with HMSSQL_TEST_PROTOCOL=np or lpc.
  describe "the writes a MARS connection hands its backend (mock server)" $
    it "are whole TDS packets before SMP starts and whole SMP packets after, each write with all its pieces" $ within 60 $ do
      -- Each write as its pieces, in order.
      writes <- newIORef []
      withSmpServer defaultSmpConfig $ \srv -> do
        let record w = atomicModifyIORef' writes (\ws -> (w : ws, ()))
            recording b = b
              { backendSend = \bs -> record [bs] >> backendSend b bs
              , backendSendMany = \ws -> mapM_ record ws >> backendSendMany b ws
              }
            ci = smpConnectInfo srv
            open = case connectProtocol ci of
              ProtocolCustom o -> o
              _ -> tcpBackend (T.unpack (connectHost ci)) (T.unpack (connectPort ci))
        withConnection ci { connectProtocol = ProtocolCustom (recording <$> open) } $ \conn -> do
          query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int64)
          -- A parameter and a batch of several packets each.
          execute_ conn (mkQuery "SELECT @p1" (Only (T.replicate 10_000 "x")))
          execute_ conn (rawSql ("SELECT 1 -- " <> T.replicate 10_000 "y"))
          -- A second session, opened beside a stream on the first.
          withQueryS conn "SELECT 2" $ \(_ :: Stream (Of (Only Int64)) IO ()) ->
            query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int64)
        out <- nextOutcome srv
        outViolations out `shouldBe` []
      ws <- map B.concat . reverse <$> readIORef writes
      pieces <- map length <$> readIORef writes
      let (beforeSmp, fromSmp) = break isSmp ws
      -- PRELOGIN and LOGIN7 in plain TDS; then a SYN and DATA packets.
      length beforeSmp `shouldBe` 2
      length fromSmp `shouldSatisfy` (> 10)
      -- The DATA packets come as a header and a TDS packet, the shape a
      -- pipe once wrote as two writes.
      length (filter (== 2) pieces) `shouldSatisfy` (> 10)
      [w | w <- beforeSmp, not (wholeUnits tdsLength w)] `shouldBe` []
      [w | w <- fromSmp, not (wholeUnits smpPacketLength w)] `shouldBe` []
  where
    isSmp w = B.take 1 w == B.singleton smpIdentifier

-- | Whether the bytes are a sequence of whole packets, by the given
-- reading of a packet's length from its start (Nothing: too short to say).
wholeUnits :: (B.ByteString -> Maybe Int) -> B.ByteString -> Bool
wholeUnits lengthOf bs
  | B.null bs = True
  | otherwise = case lengthOf bs of
      Just n | n > 0 && n <= B.length bs -> wholeUnits lengthOf (B.drop n bs)
      _ -> False

-- | A TDS packet's length: bytes 2 and 3 of its header, big-endian.
tdsLength :: B.ByteString -> Maybe Int
tdsLength bs
  | B.length bs < 8 = Nothing
  | otherwise = Just (fromIntegral (B.index bs 2) `shiftL` 8 .|. fromIntegral (B.index bs 3))

-- | An SMP packet's length, from its header (at least the header's 16
-- bytes).
smpPacketLength :: B.ByteString -> Maybe Int
smpPacketLength bs
  | B.length bs < smpHeaderLength || B.index bs 0 /= smpIdentifier = Nothing
  | n < smpHeaderLength = Nothing
  | otherwise = Just n
  where
    n = fromIntegral (smpLength (readSmpHeader bs))

-- | Cut the bytes into chunks of the sizes, repeated as needed.
chunksOfSizes :: [Int] -> B.ByteString -> [B.ByteString]
chunksOfSizes sizes = go (cycle sizes)
  where
    go (n : ns) bs
      | B.null bs = []
      | otherwise = let (now, later) = B.splitAt n bs in now : go ns later
    go [] bs = [bs]

-- | The rows the client reads from a response of @SELECT@ with the given
-- number of rows, in TDS packets of the given size, each DATA packet
-- followed by an ACK (with the mock's window as it is), all cut into
-- chunks sent with a pause of that many microseconds after each.
splitResponse :: Int -> Int -> (B.ByteString -> [B.ByteString]) -> Int -> IO [Int64]
splitResponse rows packetSize cut pause =
  withSmpServer defaultSmpConfig { cfgRespond = Nothing } $ \srv -> within 60 $
    withConnection (smpConnectInfo srv) $ \conn -> do
      m <- nextMock srv
      result <- async (query conn "SELECT 1")
      _ <- expectMessage m
      let packets = tdsPackets packetSize (colMetaBigint "" : map (rowBigint . fromIntegral) [1 .. rows] ++ [doneFinal rows])
      bytes <- fmap B.concat $ forM packets $ \p -> do
        dataBytes <- stampData m 0 p
        Just s <- mockSession m 0
        pure (dataBytes <> smpPacket flagAck 0 (msServerSeq s) (msServerWindow s) B.empty)
      forM_ (cut bytes) $ \chunk -> sendSmpRaw m chunk >> threadDelay pause
      got <- map (\(Only n) -> n) <$> wait result
      violationsSoFar m >>= (`shouldBe` [])
      pure got
