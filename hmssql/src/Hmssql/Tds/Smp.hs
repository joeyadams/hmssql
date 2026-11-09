{-# LANGUAGE MagicHash #-}
-- | The Session Multiplex Protocol's packet header: what carries the TDS
-- packets of several requests over one connection under MARS.
--
-- [MC-SMP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/mc-smp/04c8edde-371d-4af5-bb33-a39b3948f0af)
--
-- Every SMP packet starts with 16 bytes: the identifier 0x53, the flags
-- (exactly one of SYN, ACK, FIN and DATA), the session's identifier, the
-- packet's length (header included), a sequence number and a window, all
-- little-endian.  A DATA packet's payload is one TDS packet; the others
-- have none.
--
-- The sequence number of a DATA packet is one more than that of the
-- session's previous DATA packet from the same sender, the first being 1;
-- a SYN carries 0, and an ACK or FIN the sender's last DATA sequence
-- number.  The window is the highest sequence number the sender of the
-- packet will accept from its peer on this session: it only ever grows,
-- as the sender consumes what it received.
module Hmssql.Tds.Smp
  ( SmpHeader (..)
  , SmpFlag (..)
  , smpFlagWord
  , smpHeaderLength
  , smpIdentifier
  , readSmpHeader
  , pokeSmpHeader
  , smpControlPacket
  , smpDataPacket
  , smpInitialWindow
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Data.Word (Word16, Word32, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeByteOff)

import Hmssql.Internal.Derived
import Hmssql.Tds.Bytes (word16LeAt, word32LeAt, word8At)
import Hmssql.Tds.Bytes.Unsafe (pokeWord16LE, pokeWord32LE)

-- | What a packet is.
data SmpFlag
  = SmpSyn   -- ^ 0x01: opens a session.
  | SmpAck   -- ^ 0x02: carries a new window, nothing else.
  | SmpFin   -- ^ 0x04: closes a session.
  | SmpData  -- ^ 0x08: carries one TDS packet.
  deriving stock (Eq, Show)

smpFlagWord :: SmpFlag -> Word8
smpFlagWord = \case
  SmpSyn -> 0x01
  SmpAck -> 0x02
  SmpFin -> 0x04
  SmpData -> 0x08

data SmpHeader = SmpHeader
  { smpFlags :: !Word8
    -- ^ As sent: one of the 'SmpFlag' bits in a valid packet.
  , smpSession :: !Word16
  , smpLength :: !Word32
    -- ^ The whole packet's, this header included.
  , smpSeqNum :: !Word32
  , smpWindow :: !Word32
  }

instance Show SmpHeader where
  showsPrec p (SmpHeader a b c e f) = showRecord p "SmpHeader"#
    [ "smpFlags"# := a, "smpSession"# := b, "smpLength"# := c, "smpSeqNum"# := e
    , "smpWindow"# := f
    ]
  {-# OPAQUE showsPrec #-}

instance Eq SmpHeader where
  SmpHeader a b c e f == SmpHeader a' b' c' e' f' =
    a == a' && b == b' && c == c' && e == e' && f == f'
  {-# OPAQUE (==) #-}

smpHeaderLength :: Int
smpHeaderLength = 16

-- | The first byte of every SMP packet (SMID).
smpIdentifier :: Word8
smpIdentifier = 0x53

-- | The window a session has before its peer has said anything
-- (MC-SMP 3.1.3): how far a client may send after its SYN, which the
-- server doesn't answer.
smpInitialWindow :: Word32
smpInitialWindow = 4

-- | The header at the start of a buffer of at least 'smpHeaderLength'
-- bytes whose first byte is 'smpIdentifier' (the caller checks both).
readSmpHeader :: B.ByteString -> SmpHeader
readSmpHeader bs = SmpHeader
  { smpFlags = word8At bs 1
  , smpSession = word16LeAt bs 2
  , smpLength = word32LeAt bs 4
  , smpSeqNum = word32LeAt bs 8
  , smpWindow = word32LeAt bs 12
  }

-- | Write a header at the pointer.
pokeSmpHeader :: Ptr Word8 -> SmpFlag -> Word16 -> Int -> Word32 -> Word32 -> IO ()
pokeSmpHeader p flag sid len seqNum window = do
  pokeByteOff p 0 smpIdentifier
  pokeByteOff p 1 (smpFlagWord flag)
  pokeWord16LE p 2 sid
  pokeWord32LE p 4 (fromIntegral len)
  pokeWord32LE p 8 seqNum
  pokeWord32LE p 12 window

-- | A packet that is its header alone: a SYN, an ACK or a FIN.
smpControlPacket :: SmpFlag -> Word16 -> Word32 -> Word32 -> B.ByteString
smpControlPacket flag sid seqNum window =
  BI.unsafeCreate smpHeaderLength $ \p -> pokeSmpHeader p flag sid smpHeaderLength seqNum window

-- | A DATA packet around a complete TDS packet, as its pieces: the header,
-- then the packet.  The header is separate because its sequence number and
-- window are only known under the send lock, long after the packet is complete,
-- and a 'B.ByteString' must not be written to once it exists.
smpDataPacket :: Word16 -> Word32 -> Word32 -> B.ByteString -> [B.ByteString]
smpDataPacket sid window seqNum packet =
  [ BI.unsafeCreate smpHeaderLength $ \p ->
      pokeSmpHeader p SmpData sid (smpHeaderLength + B.length packet) seqNum window
  , packet
  ]
