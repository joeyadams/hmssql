-- | Memory after reading a large value with small packets.
--
-- Over TLS (TDS 8.0 or PRELOGIN-hosted), SQL Server sends each packet as a
-- TLS record of its own, and @TLS.recvData@ returns one record at a time.
-- With 512-byte packets each record's plaintext is a small pinned object,
-- allocated in the same blocks as the short-lived objects tls and crypton
-- allocate per record (about four of them with finalizers, @ScrubbedBytes@).
-- The packets of a token stay live until the whole token has been read, and
-- GHC frees a block of small pinned objects only once all of them are dead,
-- so the blocks, and the finalizable objects in them, were promoted and kept:
-- after a 32 MiB value, about 180 MiB was still live at the next major GC
-- (1024-byte packets: ~120 MiB, 2048: ~40 MiB, 4096 and over plaintext:
-- nothing), and only freed at the one after, once the finalizers had run.
-- The reader thread now copies small chunks into shared 32 KiB buffers
-- ('Hmssql.Connection.Internal.copyIntoArena').
--
-- Measured once the finalizers have run: a major GC, a pause for the
-- finalizer thread, another.  Measured at the first major GC after the
-- read, the figure depended on when the last collection during the read
-- had run: the tls objects allocated since then are all kept for their
-- finalizers at that GC, with the blocks they share, up to a nursery's
-- worth (-A64m, the test suite's).  A read that ended with a large
-- allocation (the joined value) happened to be collected just before its
-- end, and measured 1.0x; one that allocates its buffer early (the
-- resumable row reader, 1.0x at its peak) measured 1.1-2.05x for the same
-- memory, depending on the packet size.
--
-- The second group reads the same value as an output parameter
-- (RETURNVALUE), now read as a row's value is (in one copy, keeping no
-- packet), and keeps the 'ReturnValue' without decoding it.  The value was
-- a thunk over the packets until it was decoded: 1.14x at 512-byte packets
-- over TLS, 1.07x at 1024, 1.45x over plaintext (6.19x at 512 without the
-- arena, after any number of major GCs); now 1.001x in each case, against
-- a bound of 1.0625x.
--
-- Neither measurement sees the regression this module was written for,
-- which was a first-GC effect, nor can a first-GC measurement of a large
-- value, now that no token keeps its packets until it is complete: with
-- the chunks passed on uncopied, a 32 MiB row or output parameter measures
-- 1.04-1.41x at the first GC, no more than with them copied.  The third
-- group keeps the packets itself, as a token read by the incremental
-- parser does, or a caller holding slices of them: it reads a 32 MiB
-- response packet by packet ('readPacket') and holds every one.  Its bound
-- is one that finalizer timing can't reach: the packets plus one nursery
-- (@-A@), since only objects allocated since the last collection can be
-- pending finalization with the blocks they share.  Measured at -A64m:
-- 1.64x the packets at 512 bytes each, 1.57x at 1024 (ENCRYPT_ON 512:
-- 1.63x); with the chunks passed on uncopied, 6.14x and 4.05x (6.04x),
-- against the bound's 3x.  (At 2048-byte packets the regression measured
-- 1.33x, under the copied chunks' 1.66x, for a token keeping its packets
-- (5c8f6f7), so only the smaller sizes are checked.)
module Scale.TlsSmallPacketMemorySpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.IORef (writeIORef)
import qualified Data.Text as T
import Data.Word (Word32, Word64)
import GHC.RTS.Flags (GCFlags (..), getGCFlags)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import System.Mem (performMajorGC)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Connection.Internal (Connection (..), Session (..), readPacket, startRequest)
import Hmssql.Tds.Client (sqlBatchBody)
import Hmssql.Tds.Packet (Header (..), PacketStatus (..), PacketType (..), statusEndOfMessage)
import TestDb

valueBytes :: Int
valueBytes = 32 * 1024 * 1024

liveBytes :: IO Word64
liveBytes = do
  performMajorGC
  threadDelay 100000
  performMajorGC
  gcdetails_live_bytes . gc <$> getRTSStats

-- | Live bytes at the next major GC, with whatever it keeps for pending
-- finalizers.
liveBytesFirstGC :: IO Word64
liveBytesFirstGC = performMajorGC >> gcdetails_live_bytes . gc <$> getRTSStats

-- | One capability's nursery (@-A@; 4096-byte blocks).
nurseryBytes :: IO Int
nurseryBytes = (* 4096) . fromIntegral . minAllocAreaSize <$> getGCFlags

requireRtsStats :: IO ()
requireRtsStats = do
  enabled <- getRTSStatsEnabled
  if enabled then pure () else fail "RTS stats are off: link the test suite with -with-rtsopts=-T"

-- | Live bytes gained by reading one 'valueBytes' value (and keeping it) on
-- a fresh connection with the given packet size, once the garbage of the
-- read has been collected ('liveBytes').
liveAfterRead :: Encryption -> Word32 -> IO Int
liveAfterRead enc packetSize = do
  requireRtsStats
  ci <- testConnectInfo enc
  withConnection ci { connectPacketSize = packetSize } $ \conn -> do
    before <- liveBytes
    Only b <- query1 conn $ rawSql
      ("SELECT CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'A'), "
        <> T.pack (show valueBytes) <> "))")
    after <- liveBytes
    B.length b `shouldBe` valueBytes -- keeps b alive until after the measurement
    pure (fromIntegral after - fromIntegral before)

spec :: Spec
spec = do
  describe "reading a 32 MiB value leaves little more than the value live" $ do
    skipIfEncryptionRequired $ it "over a plaintext connection with 512-byte packets" $
      liveAfterRead EncryptNotSup 512 >>= (`shouldSatisfy` (< 5 * valueBytes `div` 4))
    it "over TLS (TDS 8.0) with 512-byte packets" $
      liveAfterRead EncryptStrict 512 >>= (`shouldSatisfy` (< 5 * valueBytes `div` 4))
    it "over TLS (TDS 8.0) with 2048-byte packets" $
      liveAfterRead EncryptStrict 2048 >>= (`shouldSatisfy` (< 5 * valueBytes `div` 4))
    it "over PRELOGIN-hosted TLS (ENCRYPT_ON) with 512-byte packets" $
      liveAfterRead EncryptOn 512 >>= (`shouldSatisfy` (< 5 * valueBytes `div` 4))

  describe "reading a 32 MiB output parameter leaves little more than the value live" $ do
    skipIfEncryptionRequired $ it "over a plaintext connection with 512-byte packets" $
      liveAfterOutput EncryptNotSup 512 >>= (`shouldSatisfy` (< 17 * valueBytes `div` 16))
    it "over TLS (TDS 8.0) with 512-byte packets" $
      liveAfterOutput EncryptStrict 512 >>= (`shouldSatisfy` (< 17 * valueBytes `div` 16))
    it "over TLS (TDS 8.0) with 1024-byte packets" $
      liveAfterOutput EncryptStrict 1024 >>= (`shouldSatisfy` (< 17 * valueBytes `div` 16))
    it "over PRELOGIN-hosted TLS (ENCRYPT_ON) with 512-byte packets" $
      liveAfterOutput EncryptOn 512 >>= (`shouldSatisfy` (< 17 * valueBytes `div` 16))

  describe "the packets of a 32 MiB response, kept, keep at most themselves and a nursery live at the next major GC" $ do
    it "over TLS (TDS 8.0) with 512-byte packets" $
      firstGCKeptPackets EncryptStrict 512
    it "over TLS (TDS 8.0) with 1024-byte packets" $
      firstGCKeptPackets EncryptStrict 1024
    it "over PRELOGIN-hosted TLS (ENCRYPT_ON) with 512-byte packets" $
      firstGCKeptPackets EncryptOn 512

-- | The statement that returns the 'valueBytes' value.
valueQuery :: T.Text
valueQuery = "SELECT CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'A'), " <> T.pack (show valueBytes) <> "))"

-- | Live bytes gained by reading one 'valueBytes' output parameter on a
-- fresh connection with the given packet size and keeping its
-- 'ReturnValue', undecoded, once the garbage of the read has been
-- collected ('liveBytes').
liveAfterOutput :: Encryption -> Word32 -> IO Int
liveAfterOutput enc packetSize = do
  requireRtsStats
  ci <- testConnectInfo enc
  withConnection ci { connectPacketSize = packetSize } $ \conn -> do
    let stmt = inParam ""
          ("SET @out = CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'A'), "
            <> T.pack (show valueBytes) <> "))")
    let decl = inParam "" ("@out varbinary(max) OUTPUT" :: T.Text)
    let out = outParam "@out" B.empty
    before <- liveBytes
    res <- callProcedure conn "sp_executesql" [stmt, decl, out]
    after <- liveBytes
    -- keeps the value alive until after the measurement
    map (fmap B.length . decodeReturnValue @B.ByteString) (procOutputValues res)
      `shouldBe` [Right valueBytes]
    pure (fromIntegral after - fromIntegral before)

-- | Read the response to 'valueQuery' packet by packet on a fresh
-- connection with the given packet size, keeping every packet, and check
-- the live bytes gained at the first major GC after the read
-- ('liveBytesFirstGC') against the packets plus one nursery.
firstGCKeptPackets :: Encryption -> Word32 -> IO ()
firstGCKeptPackets enc packetSize = do
  requireRtsStats
  nursery <- nurseryBytes
  ci <- testConnectInfo enc
  withConnection ci { connectPacketSize = packetSize } $ \conn -> do
    before <- liveBytes
    _ <- startRequest conn PTSqlBatch (\ctx -> sqlBatchBody ctx valueQuery)
    let readAll !n acc = do
          (hdr, body) <- readPacket conn
          let acc' = body : acc
              n' = n + B.length body
          if headerStatus hdr .&. statusEndOfMessage /= PacketStatus 0
            then pure (n', acc')
            else readAll n' acc'
    (kept, packets) <- readAll (0 :: Int) []
    -- The response was read to its end, around the token reader.
    writeIORef (sessResponse (connPrimary conn)) Nothing
    after <- liveBytesFirstGC
    -- keeps the packets alive until after the measurement
    length packets `shouldSatisfy` (>= valueBytes `div` fromIntegral packetSize)
    kept `shouldSatisfy` (>= valueBytes)
    (fromIntegral after - fromIntegral before :: Int) `shouldSatisfy` (< kept + nursery)
