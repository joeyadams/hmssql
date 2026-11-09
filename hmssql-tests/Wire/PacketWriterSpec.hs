-- | The ownership of packet buffers ("Hmssql.Tds.PacketWriter"), at the level
-- of the bytes: a buffer written after it was given away, a header written
-- outside its room, or a packet that shares memory with another shows here as
-- bytes that changed.  Every packet is kept and compared at the end with a
-- copy made when it was handed over, with marked allocations between the
-- packets and collections on the way.  @docs/dev/testing.md@ lists the
-- mutants these were checked against.  A buffer is frozen only when it is
-- handed over, and these are the tests of what comes out.
module Wire.PacketWriterSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Control.Monad (forM_, replicateM, unless, when)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.List (isInfixOf)
import Data.Word (Word16, Word32, Word8)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Mem (performGC, performMinorGC)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.PacketWriter
import Hmssql.Tds.TypeInfo (writeValue)
import Hmssql.Tds.Parameter (ParamValue (..), writeParamValueWith)
import Wire.TypeInfoSpec (genTypeInfo, genValueFor)
import Hmssql.Tds.Smp

-- | An allocation of the size of a packet, filled with a mark.  One is made
-- after each packet is handed over and before the next buffer is allocated,
-- so that the buffers have them for neighbours in the pinned heap: a write
-- past the end of a buffer, or before the start of the next, lands in one.
newCanary :: Int -> IO B.ByteString
newCanary n = BI.create n $ \p -> fillBytes p canaryMark n

canaryMark :: Word8
canaryMark = 0xA5

canaryIntact :: B.ByteString -> Bool
canaryIntact = B.all (== canaryMark)

-- | What came out: each packet as it is now, a copy made when it was handed
-- over, and the marked allocations.
data Kept = Kept !(IORef [(B.ByteString, B.ByteString)]) !(IORef [B.ByteString]) !Int

newKept :: Int -> IO Kept
newKept size = do
  first <- newCanary size
  Kept <$> newIORef [] <*> newIORef [first] <*> pure size

-- | Keep a frozen packet, and get ready for the next buffer.
keep :: Kept -> B.ByteString -> IO ()
keep (Kept packets canaries size) bs = do
  snapshot <- pure $! B.copy bs
  modifyIORef' packets ((bs, snapshot) :)
  count <- length <$> readIORef packets
  when (count `mod` 32 == 0) performMinorGC
  canary <- newCanary size
  modifyIORef' canaries (canary :)

-- | The packets, in order, after checking that none changed since it was
-- handed over and that nothing was written to a neighbour.  A collection comes
-- first, and more allocation, so that memory that was freed while still in
-- use is reused and shows.
keptPackets :: Kept -> IO [B.ByteString]
keptPackets (Kept packets canaries size) = do
  performGC
  _ <- replicateM 8 (newCanary size)
  performGC
  kept <- reverse <$> readIORef packets
  forM_ kept $ \(now, snapshot) ->
    unless (now == snapshot) $ throwIO $ ErrorCall "a packet changed after it was handed over"
  marks <- readIORef canaries
  unless (all canaryIntact marks) $ throwIO $ ErrorCall "a write landed outside its buffer"
  pure (map fst kept)

-- | One step of a generated message.
data Write
  = WriteBytes !B.ByteString
  | WriteBuilder !B.ByteString
  deriving (Show)

genWrites :: Gen [Write]
genWrites = Gen.list (Range.linear 0 40) $ do
  bs <- Gen.bytes (Range.linear 0 700)
  Gen.element [WriteBytes bs, WriteBuilder bs]

applyWrite :: PacketWriter -> Write -> IO ()
applyWrite w (WriteBytes bs) = writeBytes w bs
applyWrite w (WriteBuilder bs) = writeBuilder w (BB.byteString bs)

pokeAll :: B.ByteString -> Ptr Word8 -> IO ()
pokeAll (BI.BS fp n) p = BI.unsafeWithForeignPtr fp $ \s -> copyBytes p s n

writeBody :: [Write] -> B.ByteString
writeBody = B.concat . map (\case WriteBytes b -> b; WriteBuilder b -> b)

-- | The SMP DATA packet, encoded apart from the library's own.
smpPacket :: Word8 -> Word16 -> Word32 -> Word32 -> B.ByteString -> B.ByteString
smpPacket flags sid sq window payload = LB.toStrict $ Put.runPut $ do
  Put.putWord8 0x53
  Put.putWord8 flags
  Put.putWord16le sid
  Put.putWord32le (fromIntegral (16 + B.length payload))
  Put.putWord32le sq
  Put.putWord32le window
  Put.putByteString payload

-- | Run a writer into a sink of frozen packets.
writeMessage :: TdsContext -> PacketSink -> [Write] -> IO ()
writeMessage ctx sink writes =
  runPacketWriter ctx PTBulkLoad sink $ \w -> mapM_ (applyWrite w) writes

-- | The packets a message must become: each full but the last, the last
-- marked, with IDs from 1, as the bulk load path numbers them.
expectedPackets :: TdsContext -> B.ByteString -> [B.ByteString]
expectedPackets ctx body = go (1 :: Word8) body
  where
    size = packetPayloadSize ctx
    go pid rest
      | B.length rest <= size = [packet pid statusEndOfMessage rest]
      | otherwise = packet pid (PacketStatus 0) (B.take size rest) : go (pid + 1) (B.drop size rest)
    packet pid status payload =
      BI.unsafeCreate (headerLength + B.length payload) $ \p -> do
        pokePacketHeader p PTBulkLoad status (headerLength + B.length payload) pid
        pokeAll payload (p `plusPtr` headerLength)

genSize :: Gen Word32
genSize = Gen.word32 (Range.linear 9 600)

genSeq :: Gen Word32
genSeq = Gen.choice [Gen.word32 (Range.linear 0 100), (maxBound -) <$> Gen.word32 (Range.linear 0 40)]

-- | A sink that keeps each packet as SMP DATA, with a sequence number
-- counted here.
smpSink :: Kept -> IORef Word32 -> Word16 -> Word32 -> PacketSink
smpSink kept seqRef sid window packet = do
  sq <- readIORef seqRef
  keep kept (B.concat (smpDataPacket sid window sq packet))
  writeIORef seqRef (sq + 1)

-- The unified writer numbers its first packet 1; the old pure framing
-- helper starts at 0. All other packet bytes must still agree.
numberFromOne :: [B.ByteString] -> [B.ByteString]
numberFromOne = zipWith (\i p -> B.take 6 p <> B.singleton i <> B.drop 7 p) (iterate (+ 1) 1)

spec :: Spec
spec = describe "PacketWriter" $ do
  describe "writing a message" $ do
    it "writes checked cells with the Builder framing and preserves frozen packets" $ hedgehog $ do
      size <- forAll genSize
      cells <- forAll $ Gen.list (Range.linear 0 40) $ do
        ti <- genTypeInfo
        value <- genValueFor ti
        pure (ti, value)
      let ctx = defaultTdsContext { tdsPacketSize = size }
          body = LB.toStrict $ BB.toLazyByteString $ foldMap (uncurry writeValue) cells
      packets <- evalIO $ do
        kept <- newKept (fromIntegral size)
        runPacketWriter ctx PTBulkLoad (keep kept) $ \writer ->
          mapM_ (\(ti, value) -> writeParamValueWith writer mempty ti (ParamBytes value)) cells
        keptPackets kept
      packets === expectedPackets ctx body

    it "makes full packets and a marked last one, none changed after it was handed over" $ hedgehog $ do
      size <- forAll genSize
      writes <- forAll genWrites
      let ctx = defaultTdsContext { tdsPacketSize = size }
      got <- evalIO $ do
        kept <- newKept (fromIntegral size)
        writeMessage ctx (keep kept) writes
        keptPackets kept
      got === expectedPackets ctx (writeBody writes)

    it "puts each SMP header in the packet's own room, under the sender's sequence numbers" $ hedgehog $ do
      size <- forAll genSize
      writes <- forAll genWrites
      sid <- forAll $ Gen.word16 Range.linearBounded
      window <- forAll genSeq
      first <- forAll genSeq
      let ctx = defaultTdsContext { tdsPacketSize = size }
      got <- evalIO $ do
        kept <- newKept (fromIntegral size + smpHeaderLength)
        seqRef <- newIORef first
        writeMessage ctx (smpSink kept seqRef sid window) writes
        keptPackets kept
      got === zipWith (\sq tds -> smpPacket 0x08 sid sq window tds)
        (iterate (+ 1) first) (expectedPackets ctx (writeBody writes))

    it "survives many messages at the buffers' real sizes, with allocations in between" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 4096 }
          body = B.pack (take 100_000 (cycle [0 .. 250]))
          writes = [WriteBytes (B.take 3000 body), WriteBuilder (B.take 5000 (B.drop 3000 body)), WriteBytes (B.drop 8000 body)]
      forM_ [1 .. 200 :: Int] $ \i -> do
        kept <- newKept 4096
        if even i
          then writeMessage ctx (keep kept) writes
          else do
            seqRef <- newIORef 1
            writeMessage ctx (smpSink kept seqRef 7 64) writes
        got <- keptPackets kept
        got `shouldBe`
          if even i
            then expectedPackets ctx body
            else zipWith (\sq tds -> smpPacket 0x08 7 sq 64 tds) (iterate (+ 1) 1) (expectedPackets ctx body)

    it "drops the packet in progress when the producer throws, and leaves the sent ones alone" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 512 }
          chunk = B.replicate 2000 0x42
      kept <- newKept 512
      r <- try $ runPacketWriter ctx PTBulkLoad (keep kept) $ \w -> do
        writeBytes w chunk
        throwIO (ErrorCall "the source failed") :: IO ()
      r `shouldBe` Left (ErrorCall "the source failed")
      got <- keptPackets kept
      map (`B.index` 1) got `shouldSatisfy` all (== 0)
      B.concat (map (B.drop headerLength) got) `shouldBe` B.take (length got * packetPayloadSize ctx) chunk

    it "makes the bytes of a row that doesn't fit first, and splits them" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 100 }
          body = B.pack (take 1000 (cycle [1 .. 200]))
      kept <- newKept 100
      writeMessage ctx (keep kept) [WriteBuilder body]
      keptPackets kept `shouldReturn` expectedPackets ctx body

    it "ends the message when the producer returns, with one empty packet if it wrote nothing" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 512 }
      kept <- newKept 512
      writeMessage ctx (keep kept) []
      keptPackets kept `shouldReturn` expectedPackets ctx B.empty

    it "refuses a writer used after its message ended, and leaves the sent packets alone" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 64 }
          body = B.replicate 20 0x33
          misused = \case
            ErrorCall msg -> "used after its message ended" `isInfixOf` msg
      kept <- newKept 64
      seqRef <- newIORef 1
      stale <- runPacketWriter ctx PTBulkLoad (smpSink kept seqRef 7 64) $ \w -> w <$ writeBytes w body
      writeBytes stale (B.replicate 200 0xEE) `shouldThrow` misused
      writeBuilder stale (BB.word32LE 0xEEEEEEEE) `shouldThrow` misused
      got <- keptPackets kept
      got `shouldBe` zipWith (\sq tds -> smpPacket 0x08 7 sq 64 tds) (iterate (+ 1) 1) (expectedPackets ctx body)

    it "refuses a writer kept from a producer that threw" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 64 }
      kept <- newKept 64
      ref <- newIORef Nothing
      _ <- try @ErrorCall $ runPacketWriter ctx PTBulkLoad (keep kept) $ \w -> do
        writeIORef ref (Just w)
        throwIO (ErrorCall "the source failed")
      Just stale <- readIORef ref
      writeBytes stale (B.replicate 200 0xEE) `shouldThrow` anyErrorCall
      keptPackets kept `shouldReturn` []

  describe "builder packet boundaries" $ do
    it "splits multi-byte builder primitives without emitting short intermediate packets" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 29 }
      forM_ [0 .. 21] $ \n -> do
        let builder = BB.byteString (B.replicate n 0x42) <> BB.word64LE 0x0102030405060708 <> BB.word32LE 1234
            body = LB.toStrict (BB.toLazyByteString builder)
        kept <- newKept 29
        runPacketWriter ctx PTBulkLoad (keep kept) (\writer -> writeBuilder writer builder)
        keptPackets kept `shouldReturn` expectedPackets ctx body

    it "stages repeated primitives that are wider than a fresh packet" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 9 }
          builders = [BB.word8 97, smallPrimitive <> repeatedPrimitives]
          body = LB.toStrict (BB.toLazyByteString (mconcat builders))
      kept <- newKept 9
      runPacketWriter ctx PTBulkLoad (keep kept) $ \writer -> mapM_ (writeBuilder writer) builders
      keptPackets kept `shouldReturn` expectedPackets ctx body

    it "does not add an empty final packet after an exactly full builder" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 512 }
          body = B.replicate 504 0x42
      kept <- newKept 512
      runPacketWriter ctx PTBulkLoad (keep kept) (\writer -> writeBuilder writer (BB.byteString body))
      keptPackets kept `shouldReturn` expectedPackets ctx body

  describe "framing a complete message" $ do
    it "makes the framing helper's packets from arbitrary input chunks" $ hedgehog $ do
      size <- forAll genSize
      body <- forAll $ Gen.bytes (Range.linear 0 5000)
      batch <- forAll $ Gen.int (Range.linear 1 9)
      reset <- forAll Gen.bool
      let ctx = defaultTdsContext { tdsPacketSize = size }
          status = if reset then statusResetConnection else PacketStatus 0
          lazyBody = LB.fromChunks (chunksOf 97 body)
      got <- evalIO $ do
        kept <- newKept (fromIntegral size)
        runPacketWriterWith ctx PTRpc status (keep kept) $ \writer ->
          mapM_ (writeBuilder writer . BB.byteString) (chunksOf batch body)
        keptPackets kept
      got === numberFromOne (splitIntoPackets ctx PTRpc status lazyBody)

    it "puts SMP headers in front of them, the sequence wrapping" $ hedgehog $ do
      size <- forAll genSize
      body <- forAll $ Gen.bytes (Range.linear 0 5000)
      batch <- forAll $ Gen.int (Range.linear 1 9)
      sid <- forAll $ Gen.word16 Range.linearBounded
      window <- forAll genSeq
      first <- forAll genSeq
      let ctx = defaultTdsContext { tdsPacketSize = size }
          lazyBody = LB.fromStrict body
      got <- evalIO $ do
        kept <- newKept (fromIntegral size + smpHeaderLength)
        sequenceRef <- newIORef first
        runPacketWriter ctx PTRpc (smpSink kept sequenceRef sid window) $ \writer ->
          mapM_ (writeBuilder writer . BB.byteString) (chunksOf batch body)
        keptPackets kept
      got === zipWith (\sq tds -> smpPacket 0x08 sid sq window tds)
        (iterate (+ 1) first) (numberFromOne (splitIntoPackets ctx PTRpc (PacketStatus 0) lazyBody))

    it "makes new buffers for each execution of the same builder" $ do
      let ctx = defaultTdsContext { tdsPacketSize = 64 }
          body = BB.byteString (B.replicate 40 0x11)
          freezeWith :: Word32 -> IO [B.ByteString]
          freezeWith sq = do
            kept <- newKept 64
            sequenceRef <- newIORef sq
            runPacketWriter ctx PTRpc (smpSink kept sequenceRef 3 9) (\writer -> writeBuilder writer body)
            keptPackets kept
      first <- freezeWith 1
      snapshot <- pure $! map B.copy first
      second <- freezeWith 1000
      first `shouldBe` snapshot
      map (B.take 12) second `shouldNotBe` map (B.take 12) first
      map (B.drop smpHeaderLength) second `shouldBe` map (B.drop smpHeaderLength) first

-- | Chunks of at most the given size.
chunksOf :: Int -> B.ByteString -> [B.ByteString]
chunksOf n bs
  | B.null bs = []
  | otherwise = let (a, b) = B.splitAt n bs in a : chunksOf n b

-- Separate Builders prevent primitive fusion from turning the test into one
-- reservation. The second reservation happens after a staging buffer fills.
smallPrimitive :: BB.Builder
smallPrimitive = BB.word16LE 65535
{-# NOINLINE smallPrimitive #-}

repeatedPrimitives :: BB.Builder
repeatedPrimitives = mconcat (replicate 20 (BB.word64LE 1234))
{-# NOINLINE repeatedPrimitives #-}
