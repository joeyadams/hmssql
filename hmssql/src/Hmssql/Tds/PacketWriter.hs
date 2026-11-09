-- | Writing a message straight into packet buffers, a packet at a time.  This
-- module alone owns a packet's storage and its framing.  A producer writes
-- ordinary 'BB.Builder's, except the bulk row writer and the scalar parameter
-- path, which poke a value held in memory ('unsafeWriteSized').
--
-- A packet's storage stays private until its last write.  The writer then lets
-- go of it, and only then is it the 'B.ByteString' a sink receives, so no
-- 'B.ByteString' ever refers to memory that is still being written.  What
-- belongs in front of a packet, such as an SMP header, is the sink's to send
-- beside it.
module Hmssql.Tds.PacketWriter
  ( PacketSink
  , inSource, withSourceScope, PacketWriter, runPacketWriter, runPacketWriterWith, writeBytes, writeBuilder
  , unsafeWriteSized
  ) where

import Control.Exception (onException)
import Data.Bits ((.&.), (.|.), complement)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Extra as BB
import qualified Data.ByteString.Internal as BI
import Data.IORef
import Data.Word (Word8)
import Foreign.ForeignPtr (ForeignPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet

-- | Where a message's complete TDS packets go, in order.  Each is immutable
-- and belongs to the sink: the writer keeps no reference to it.
type PacketSink = B.ByteString -> IO ()

payloadOffset :: Int
payloadOffset = headerLength

newStorage :: Int -> IO (ForeignPtr Word8)
newStorage n = BI.mallocByteString (payloadOffset + n)

-- Open holds storage, bytes used, packet serial and allocated capacity.
-- Only the first packet can have storage smaller than the negotiated payload.
-- The state is an IORef because producers write over many calls with their own
-- code in between, such as a parameter's source, so no one callback spans a
-- packet's life.  That mutability stays behind 'writeBytes' and 'writeBuilder'.
data PacketState = Open !(ForeignPtr Word8) !Int !Int !Int | Closed

-- | The writer of one message: the packet being filled, and where the complete
-- packets go.
data PacketWriter = PacketWriter
  { payloadSize :: !Int
  , emitPacket :: PacketState -> Bool -> IO ()
  , inSource :: forall a. IO a -> IO a
    -- ^ The scope a parameter's source runs in ('withSourceScope').
  , packetState :: !(IORef PacketState)
  }

-- | Run a producer with a writer for a message of this packet type.  Each
-- packet goes to the sink as it fills, and the last when the producer returns.
runPacketWriter :: TdsContext -> PacketType -> PacketSink -> (PacketWriter -> IO a) -> IO a
runPacketWriter ctx ptype = runPacketWriterWith ctx ptype (PacketStatus 0)

-- | 'runPacketWriter' with extra status bits, which go on every packet, except
-- that RESETCONNECTION goes on the first alone.  Every packet but the last is
-- full.
runPacketWriterWith :: TdsContext -> PacketType -> PacketStatus -> PacketSink -> (PacketWriter -> IO a) -> IO a
runPacketWriterWith ctx ptype extra sink produce = do
  let capacity = packetPayloadSize ctx
      -- Most requests are far smaller than a packet.  Starting small saves a
      -- 4 KiB or 8 KiB allocation per request, and costs one copy when a
      -- message outgrows it ('makeRoom').
      initial = min 256 capacity
      emit Closed _ = writerEnded
      emit (Open fp used serial _) final = do
        let status = (if final then statusEndOfMessage else PacketStatus 0) .|.
              (if serial == 1 then extra else extra .&. complement statusResetConnection)
        -- The last write to this storage: the caller has already replaced or
        -- closed the writer's state, so nothing can reach it after the freeze.
        BI.unsafeWithForeignPtr fp $ \p ->
          pokePacketHeader p ptype status (headerLength + used) (fromIntegral serial)
        sink (BI.BS fp (headerLength + used))
  state <- newStorage initial >>= \fp -> newIORef (Open fp 0 1 initial)
  let writer = PacketWriter capacity emit id state
      finish = do
        final <- readOpen writer
        writeIORef state Closed
        emit final True
  (do result <- produce writer
      finish
      pure result) `onException` writeIORef state Closed

readOpen :: PacketWriter -> IO PacketState
readOpen writer = readIORef (packetState writer) >>= \case
  Closed -> writerEnded
  state -> pure state

writerEnded :: IO a
writerEnded = errorWithoutStackTrace "Hmssql.Tds.PacketWriter: a writer used after its message ended"

-- Grow the initial buffer or emit a full packet and start its successor.
makeRoom :: PacketWriter -> PacketState -> IO ()
makeRoom _ Closed = writerEnded
makeRoom writer old@(Open previous used serial capacity) = do
  let full = payloadSize writer
  fp <- newStorage full
  if capacity < full then do
    -- Small requests never need a full packet allocation. Growing before
    -- emission still makes every non-final packet exactly the negotiated size.
    BI.unsafeWithForeignPtr previous $ \src -> BI.unsafeWithForeignPtr fp $ \dst ->
      copyBytes (dst `plusPtr` payloadOffset) (src `plusPtr` payloadOffset) used
    writeIORef (packetState writer) (Open fp used serial full)
  else do
    writeIORef (packetState writer) (Open fp 0 (serial + 1) full)
    emitPacket writer old False

-- | Copy bytes into the message, across packets as needed.  Nothing of the
-- source is kept once it has been copied, and a full packet goes to the sink
-- when the next byte arrives.
writeBytes :: PacketWriter -> B.ByteString -> IO ()
writeBytes writer = go
  where
    go bytes | B.null bytes = pure ()
    go bytes = readOpen writer >>= \case
      Closed -> writerEnded
      state@(Open fp used serial capacity)
        | used == capacity -> makeRoom writer state >> go bytes
        | otherwise -> do
            let n = min (capacity - used) (B.length bytes)
            BI.unsafeWithForeignPtr fp $ \dst -> case bytes of
              BI.BS src _ -> BI.unsafeWithForeignPtr src $ \p ->
                copyBytes (dst `plusPtr` (payloadOffset + used)) p n
            writeIORef (packetState writer) (Open fp (used + n) serial capacity)
            go (B.drop n bytes)

-- | Write exactly @n@ bytes by poking them: straight into the current packet when they
-- fit, and otherwise staged in a buffer of their own and copied as 'writeBytes' copies.
-- The action must write all @n@ bytes from the pointer it is given, read nothing there,
-- and keep no reference to it.  This is for the two producers that compute a
-- write's size and its pokes from one description of a value: the bulk row
-- writer, and the scalar parameter path in "Hmssql.Tds.Parameter".
unsafeWriteSized :: PacketWriter -> Int -> (Ptr Word8 -> IO ()) -> IO ()
unsafeWriteSized writer n poke = readOpen writer >>= \case
  Open fp used serial capacity | n <= capacity - used -> do
    BI.unsafeWithForeignPtr fp $ \p -> poke (p `plusPtr` (payloadOffset + used))
    writeIORef (packetState writer) (Open fp (used + n) serial capacity)
  state -> writeSizedSlow writer state n poke
{-# INLINE unsafeWriteSized #-}

-- The small first buffer grows before anything else, as in 'writeBuilder', so that a
-- row splits across packets only where the message really exceeds a packet.
writeSizedSlow :: PacketWriter -> PacketState -> Int -> (Ptr Word8 -> IO ()) -> IO ()
writeSizedSlow writer state n poke = case state of
  Closed -> writerEnded
  Open _ _ _ capacity
    | capacity < payloadSize writer -> makeRoom writer state >> unsafeWriteSized writer n poke
    | otherwise -> BI.create n poke >>= writeBytes writer
{-# NOINLINE writeSizedSlow #-}

-- | Run a 'BB.Builder' into the packets.  A primitive that needs more
-- contiguous room than the packet has left is written to a small buffer of
-- its own, whose bytes fill the current packet and continue in the next, and
-- a chunk the builder inserts goes through 'writeBytes'.
writeBuilder :: PacketWriter -> BB.Builder -> IO ()
writeBuilder writer = go . BB.runBuilder
  where
    go build = readOpen writer >>= \case
      Closed -> writerEnded
      Open fp used serial capacity -> do
            let room = capacity - used
            (written, next) <- BI.unsafeWithForeignPtr fp $ \p -> build (p `plusPtr` (payloadOffset + used)) room
            writeIORef (packetState writer) (Open fp (used + written) serial capacity)
            continue capacity (room - written) next
    continue _ _ BB.Done = pure ()
    continue _ _ (BB.Chunk bytes next) = writeBytes writer bytes >> go next
    -- A Builder primitive asks for contiguous room.  The small first buffer
    -- grows before anything else happens, so that a request's fields split
    -- across packets only where the message really exceeds a packet.
    continue capacity room (BB.More needed next)
      | room >= needed = go next
      | needed <= payloadSize writer && (room == 0 || capacity < payloadSize writer) =
          readOpen writer >>= makeRoom writer >> go next
      | otherwise = do
          let size = max 64 needed
          fp <- BI.mallocByteString size
          (written, after) <- BI.unsafeWithForeignPtr fp $ \p -> next p size
          writeBytes writer (BI.BS fp written)
          case after of
            BB.Done -> pure ()
            BB.Chunk bytes k -> writeBytes writer bytes >> go k
            BB.More count k -> go (checked count k)
    -- The continuation of a staged primitive may ask for more room than the
    -- packet has.  Rather than run it short, hand its request back to the
    -- @More@ case above, which stages it in turn.
    checked needed next p room
      | room >= needed = next p room
      | otherwise = pure (0, BB.More needed next)

-- | Run the writer's sources in this scope, which is how the connection refuses
-- a request made from inside a parameter's source.
withSourceScope :: (forall a. IO a -> IO a) -> PacketWriter -> PacketWriter
withSourceScope scope writer = writer { inSource = scope }
