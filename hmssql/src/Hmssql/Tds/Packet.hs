{-# LANGUAGE MagicHash #-}
{-# OPTIONS_GHC -O2 #-}
-- -O2: its loops over every byte sent run 15 to 20% faster than at -O1
-- (Bench.Encode "large params"); library-wide -O2 made row parsing slower.
-- | TDS packet framing.
--
-- [MS-TDS 2.2.3 Packets](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/f4f8a0d9-7c4a-4a36-a6f3-cd9f6f0d8a5b)
module Hmssql.Tds.Packet
  ( PacketType (..)
  , packetTypeWord
  , packetTypeFromWord
  , PacketStatus (..)
  , statusEndOfMessage
  , statusIgnore
  , statusResetConnection
  , Header (..)
  , headerLength
  , readHeader
  , getHeader
  , putHeader
  , pokePacketHeader
  , packetPayloadSize
  , splitIntoPackets
  , frameSegments
  , pokeFramedPacket
  , packetCount
  , maxSqlBatchPackets
  ) where

import Data.Binary.Get (Get)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (Bits, complement, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.Word (Word16, Word32, Word8)
import Foreign.ForeignPtr (plusForeignPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (pokeByteOff)

import Hmssql.Internal.Derived
import Hmssql.Tds.Bytes (word16BeAt, word8At)
import Hmssql.Tds.Context

-- | The type byte of a packet header.
data PacketType
  = PTSqlBatch          -- ^ 0x01
  | PTRpc               -- ^ 0x03
  | PTTabularResult     -- ^ 0x04
  | PTAttention         -- ^ 0x06
  | PTBulkLoad          -- ^ 0x07
  | PTTransactionManager -- ^ 0x0E
  | PTLogin7            -- ^ 0x10
  | PTSspi              -- ^ 0x11
  | PTPrelogin          -- ^ 0x12, also carries TLS handshake records for non-strict encryption
  | PTOther !Word8
  deriving stock (Eq)

instance Show PacketType where
  showsPrec p = \case
    PTSqlBatch -> showString "PTSqlBatch"
    PTRpc -> showString "PTRpc"
    PTTabularResult -> showString "PTTabularResult"
    PTAttention -> showString "PTAttention"
    PTBulkLoad -> showString "PTBulkLoad"
    PTTransactionManager -> showString "PTTransactionManager"
    PTLogin7 -> showString "PTLogin7"
    PTSspi -> showString "PTSspi"
    PTPrelogin -> showString "PTPrelogin"
    PTOther a -> showCon1 p "PTOther"# a
  {-# OPAQUE showsPrec #-}

packetTypeWord :: PacketType -> Word8
packetTypeWord = \case
  PTSqlBatch -> 0x01
  PTRpc -> 0x03
  PTTabularResult -> 0x04
  PTAttention -> 0x06
  PTBulkLoad -> 0x07
  PTTransactionManager -> 0x0E
  PTLogin7 -> 0x10
  PTSspi -> 0x11
  PTPrelogin -> 0x12
  PTOther w -> w

packetTypeFromWord :: Word8 -> PacketType
packetTypeFromWord = \case
  0x01 -> PTSqlBatch
  0x03 -> PTRpc
  0x04 -> PTTabularResult
  0x06 -> PTAttention
  0x07 -> PTBulkLoad
  0x0E -> PTTransactionManager
  0x10 -> PTLogin7
  0x11 -> PTSspi
  0x12 -> PTPrelogin
  w -> PTOther w

-- | The status byte of a packet header; 'statusEndOfMessage', 'statusIgnore'
-- and 'statusResetConnection' are its bits.
newtype PacketStatus = PacketStatus Word8
  deriving newtype (Eq, Bits)

instance Show PacketStatus where
  showsPrec p (PacketStatus a) = showCon1 p "PacketStatus"# a
  {-# OPAQUE showsPrec #-}

statusEndOfMessage, statusIgnore, statusResetConnection :: PacketStatus
statusEndOfMessage = PacketStatus 0x01
statusIgnore = PacketStatus 0x02
statusResetConnection = PacketStatus 0x08

-- | A packet header.
data Header = Header
  { headerType :: !PacketType
  , headerStatus :: !PacketStatus
  , headerPacketLength :: !Word16
    -- ^ Total packet length including the header and payload, in bytes.
  , headerSpid :: !Word16
  , headerPacketId :: !Word8
  , headerWindow :: !Word8
  }

instance Show Header where
  showsPrec p (Header a b c e f g) = showRecord p "Header"#
    [ "headerType"# := a, "headerStatus"# := b, "headerPacketLength"# := c, "headerSpid"# := e
    , "headerPacketId"# := f, "headerWindow"# := g
    ]
  {-# OPAQUE showsPrec #-}

instance Eq Header where
  Header a b c e f g == Header a' b' c' e' f' g' =
    eq a a' && eq b b' && c == c' && e == e' && f == f' && g == g'
  {-# OPAQUE (==) #-}

-- | The fixed size of a TDS packet header, in bytes. The total packet
-- length is the separate 'headerPacketLength' field.
headerLength :: Int
headerLength = 8

-- | The header at the start of a buffer of at least 'headerLength' bytes,
-- read in place: one per packet received ('error' on a shorter buffer).
readHeader :: B.ByteString -> Header
readHeader bs = Header
  { headerType = packetTypeFromWord (word8At bs 0)
  , headerStatus = PacketStatus (word8At bs 1)
  , headerPacketLength = word16BeAt bs 2
  , headerSpid = word16BeAt bs 4
  , headerPacketId = word8At bs 6
  , headerWindow = word8At bs 7
  }

-- | 'readHeader' as a 'Get' (the tests' mock server).
getHeader :: Get Header
getHeader = readHeader <$> Get.getByteString headerLength

putHeader :: Header -> Put
putHeader Header{..} = do
  Put.putWord8 $ packetTypeWord headerType
  let PacketStatus st = headerStatus
  Put.putWord8 st
  Put.putWord16be headerPacketLength
  Put.putWord16be headerSpid
  Put.putWord8 headerPacketId
  Put.putWord8 headerWindow

-- | The body bytes each packet of 'splitIntoPackets' carries: the
-- negotiated packet size less the header (clamped as 'frameSegments'
-- clamps it).
packetPayloadSize :: TdsContext -> Int
packetPayloadSize ctx = max 1 (fromIntegral (min maxPacketSize (tdsPacketSize ctx)) - headerLength)

-- | Write a packet header at the pointer: the type, the status (as given;
-- the caller sets 'statusEndOfMessage' on the last packet), the total
-- length (header included, at most 'maxPacketSize') and the packet ID.
-- For a message framed packet by packet as it is produced
-- ("Hmssql.Tds.PacketWriter"); 'frameSegments' frames a complete body.
pokePacketHeader :: Ptr Word8 -> PacketType -> PacketStatus -> Int -> Word8 -> IO ()
pokePacketHeader ptr ptype (PacketStatus st) len pid = do
  pokeByteOff ptr 0 (packetTypeWord ptype)
  pokeByteOff ptr 1 st
  pokeByteOff ptr 2 (fromIntegral (len `shiftR` 8) :: Word8)
  pokeByteOff ptr 3 (fromIntegral len :: Word8)
  pokeByteOff ptr 4 (0 :: Word32)  -- SPID (2 bytes), packet ID, window
  pokeByteOff ptr 6 pid

-- | How many packets 'splitIntoPackets' frames a message body into.
packetCount :: TdsContext -> LB.ByteString -> Int
packetCount ctx body = max 1 (fromIntegral ((LB.length body + n - 1) `div` n))
  where n = fromIntegral (packetPayloadSize ctx)

-- | The most packets SQL Server accepts in one SQLBatch message: it closes
-- the connection, without an error message, on a longer one.  (Hence the
-- documented batch size limit of "65,536 * network packet size"; SQL
-- Server 2025 accepts exactly 65535 full packets, at every packet size and
-- TDS version.  RPC messages have no such limit.)
maxSqlBatchPackets :: Int
maxSqlBatchPackets = 65535

-- | Frame a complete message body into packets of the negotiated size, one
-- strict chunk per packet.  ('frameSegments' with one packet per segment.)
--
-- The extra status bits go on every packet, except 'statusResetConnection',
-- which goes on the first packet only (MS-TDS 2.2.3.1.2), and EOM, which is
-- set on the last packet here.
--
-- Body lengths and the framed allocation sizes must fit in 'Int'.
-- A packet size outside what the header can describe is clamped: to at
-- least one byte of payload, so the split always makes progress, and to at
-- most 'maxPacketSize', so the 16-bit length field never truncates.  (The
-- connection never negotiates such a size; the clamp prevents a zero-size
-- split or a truncated packet header.)
splitIntoPackets :: TdsContext -> PacketType -> PacketStatus -> LB.ByteString -> [B.ByteString]
splitIntoPackets = frameSegments 0

-- | Frame a complete message body as 'splitIntoPackets' does, into strict
-- chunks of as many whole packets as fit in the given number of bytes (at
-- least one packet each). The message is the chunks concatenated. Body
-- lengths and framed allocation sizes must fit in 'Int'. No uninitialized
-- prefix is reserved by this entry point.
--
-- Each byte of the body is copied once, into a chunk of exactly its size;
-- the chunks are produced lazily, so a message sent as it is framed needs
-- the body and one chunk at a time.  The connection sends a chunk at a
-- time, sized to fill a TLS record, or a larger socket write.
frameSegments :: Int -> TdsContext -> PacketType -> PacketStatus -> LB.ByteString -> [B.ByteString]
frameSegments target ctx ptype extraStatus body0 = go True 0 total0 body0
  where
    total0 = LB.length body0
    payloadSize = packetPayloadSize ctx
    perSegment = max 1 (target `div` (payloadSize + headerLength))

    -- Requests are framed by "Hmssql.Tds.PacketWriter" instead, whose first
    -- packet ID is 1; SQL Server accepts either.  This remains for what is framed
    -- from memory, and as the tests' independent reference.
    go :: Bool -> Word8 -> Int64 -> LB.ByteString -> [B.ByteString]
    go isFirst !pid !remaining body =
      let full = fromIntegral (remaining `div` fromIntegral payloadSize)
          partial = if remaining `mod` fromIntegral payloadSize == 0 then 0 else 1
          -- An empty message is one packet with no payload.
          left = max 1 (full + partial) :: Int
          n = min perSegment left
          segPayload = min remaining (fromIntegral (n * payloadSize))
          (here, rest) = LB.splitAt segPayload body
          isLastSegment = n == left
          !seg = BI.unsafeCreate (fromIntegral segPayload + n * headerLength) $ \ptr ->
            fill ptr isFirst pid n isLastSegment (fromIntegral segPayload) (LB.toChunks here)
       in if isLastSegment then [seg] else seg : go False (pid + fromIntegral n) (remaining - segPayload) rest

    -- Write @n@ packets holding @len@ bytes of payload, taken from the chunks.
    fill :: Ptr Word8 -> Bool -> Word8 -> Int -> Bool -> Int -> [B.ByteString] -> IO ()
    fill ptr0 isFirst0 pid0 n isLastSegment len0 chunks0 = packets ptr0 isFirst0 pid0 0 len0 chunks0
      where
        packets !ptr !isFirst !pid !i !len chunks
          | i >= n = pure ()
          | otherwise = do
              let size = min payloadSize len
                  isLast = isLastSegment && i == n - 1
              chunks' <- pokeFramedPacket ptr ptype extraStatus isFirst pid isLast size chunks
              packets (ptr `plusPtr` (headerLength + size)) False (pid + 1) (i + 1) (len - size) chunks'

-- | Write a whole packet of a message body at the pointer: its header
-- (with EOM if it is the last, and the extra status bits as
-- 'splitIntoPackets' describes them) and @size@ bytes of payload from the
-- front of the chunks; the chunks left.
pokeFramedPacket :: Ptr Word8 -> PacketType -> PacketStatus -> Bool -> Word8 -> Bool -> Int -> [B.ByteString] -> IO [B.ByteString]
pokeFramedPacket ptr ptype extraStatus isFirst pid isLast size chunks = do
  let eom = if isLast then statusEndOfMessage else PacketStatus 0
      PacketStatus reset = statusResetConnection
      mask = if isFirst then 0xFE else 0xFE .&. complement reset
  pokePacketHeader ptr ptype (eom .|. (extraStatus .&. PacketStatus mask)) (size + headerLength) pid
  copyFrom (ptr `plusPtr` headerLength) size chunks
{-# INLINE pokeFramedPacket #-}

-- | Copy @k@ bytes from the front of the chunks; the chunks left.
copyFrom :: Ptr Word8 -> Int -> [B.ByteString] -> IO [B.ByteString]
copyFrom _ 0 chunks = pure chunks
copyFrom dst k (BI.BS fp clen : cs) = do
  let m = min k clen
  BI.unsafeWithForeignPtr fp $ \src -> copyBytes dst src m  -- a bounded memcpy
  if m == clen
    then copyFrom (dst `plusPtr` m) (k - m) cs
    else pure (BI.BS (fp `plusForeignPtr` m) (clen - m) : cs)
copyFrom _ _ [] = pure []  -- can't happen: the chunks hold the payload
