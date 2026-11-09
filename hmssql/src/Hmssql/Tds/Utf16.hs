{-# OPTIONS_GHC -O2 #-}
-- -O2: its loops over every byte sent run 15 to 20% faster than at -O1
-- (Bench.Encode "large params"); library-wide -O2 made row parsing slower.
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
-- | Encoding 'Text' as UTF-16LE, as every string the client sends is: the
-- SQL text of a batch or @sp_executesql@, @nvarchar@ parameters, parameter
-- names, LOGIN7's strings; and decoding UTF-16LE into 'Text', as every
-- string the server sends is.
--
-- The encoder is a transcoder straight from the UTF-8 array of a 'Text'.
-- @text@'s own 'Data.Text.Encoding.encodeUtf16LE' (text 2.1) goes through
-- stream fusion into a buffer that doubles as it grows: about 14 ns and
-- 100 bytes of allocation per character.  Here ASCII runs take eight bytes
-- per step, and the output is written once into a buffer of its exact
-- size.  The decoder likewise writes UTF-8 straight into a 'Text' array.
module Hmssql.Tds.Utf16
  ( encodeUtf16LE
  , utf16Length
  , unsafeWriteUtf16LE
  , utf16LEBuilder
  , decodeUtf16LE
  , decodeUtf16Chunks
  ) where

import Streaming (Stream, Of)
import qualified Streaming as S
import qualified Streaming.Prelude as S
import Control.Monad.ST (RealWorld, stToIO)
import Data.Array.Byte (MutableByteArray (..))
import Data.Bits (shiftL, shiftR, unsafeShiftL, unsafeShiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Internal as BBI
import qualified Data.ByteString.Internal as BI
import qualified Data.Text as T
import Data.Text.Internal (Text (..))
import qualified Data.Text.Array as A
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import GHC.ByteOrder (ByteOrder (..), targetByteOrder)
import GHC.Exts (Int (..), indexWord8ArrayAsWord64#, writeWord8ArrayAsWord32#, writeWord8ArrayAsWord64#)
import GHC.IO (IO (..))
import GHC.Word (Word32 (..), Word64 (..))
import System.IO.Unsafe (unsafeDupablePerformIO)

import Hmssql.Tds.Bytes.Unsafe (peekWord16LE, peekWord64LE, pokeWord64LE)

-- | The text in UTF-16LE, without a byte order mark.  The same bytes as
-- 'Data.Text.Encoding.encodeUtf16LE'.
encodeUtf16LE :: Text -> B.ByteString
encodeUtf16LE t@(Text _ _ len)
  | len == 0 = B.empty
  | otherwise = unsafeDupablePerformIO $ do
      -- Each UTF-8 byte makes at most one UTF-16 code unit (a four-byte
      -- sequence makes two), so 2 * len bytes always suffice, and are
      -- exact for ASCII.
      fp <- BI.mallocByteString (2 * len)
      n <- withForeignPtr fp (unsafeWriteUtf16LE t)
      pure $! if n == 2 * len then BI.BS fp n else B.copy (BI.BS fp n)
{-# NOINLINE encodeUtf16LE #-}
-- Out of line: its 28 call sites each had a copy of the allocation and the size
-- check, 19 KB of the library's object code; the encoding benchmarks allocate the
-- same, and the call is small beside the conversion.

-- | 'encodeUtf16LE' as a 'BB.Builder', written straight into the builder's
-- buffer, a piece at a time for text too long for one of 32 KiB.
utf16LEBuilder :: Text -> BB.Builder
utf16LEBuilder t@(Text _ _ len)
  | len == 0 = mempty
  | len > 16376 = let (here, rest) = T.splitAt 2048 t in utf16LEBuilder here <> utf16LEBuilder rest
  | otherwise = BBI.builder step
  where
    step :: BBI.BuildStep r -> BBI.BuildStep r
    step k (BBI.BufferRange op ope)
      | ope `minusPtr` op >= 2 * len = do
          n <- unsafeWriteUtf16LE t op
          k (BBI.BufferRange (op `plusPtr` n) ope)
      | otherwise = pure (BBI.bufferFull (2 * len) op (step k))

-- | The length of the text in UTF-16 code units: its characters, plus one
-- for each outside the Basic Multilingual Plane.  (Every UTF-8 byte that
-- isn't a continuation byte starts a character, and a four-byte sequence
-- is a surrogate pair.)
utf16Length :: Text -> Int
utf16Length (Text arr off len) = go off 0
  where
    end = off + len
    go !i !n
      | i >= end = n
      | otherwise =
          let b = A.unsafeIndex arr i
           in go (i + 1) (n + (if b .&. 0xC0 /= 0x80 then 1 else 0) + (if b >= 0xF0 then 1 else 0))

-- | Write UTF-16LE into caller-owned memory without checking capacity.
-- Returns the byte count written: @2 * utf16Length text@, with no byte
-- order mark or terminator.
--
-- The pointer must remain valid and writable for at least that many bytes
-- throughout the call. Twice the text's UTF-8 byte length is a sufficient
-- upper bound when avoiding a length scan. Size and offset arithmetic must
-- fit in 'Int'; source and destination must not overlap, and the caller
-- must respect the lifetime and immutability of any aliases to the buffer.
-- Use 'encodeUtf16LE' or 'utf16LEBuilder' to let the library provide storage.
unsafeWriteUtf16LE :: Text -> Ptr Word8 -> IO Int
unsafeWriteUtf16LE (Text arr off len) p = go off 0
  where
    end = off + len
    go !i !o
      | targetByteOrder == LittleEndian, i + 8 <= end, ascii8 w = do
          -- Eight ASCII bytes: spread each to 16 bits.
          pokeWord64LE p o (spread w)
          pokeWord64LE p (o + 8) (spread (w `unsafeShiftR` 32))
          go (i + 8) (o + 16)
      | i >= end = pure o
      | b < 0x80 = unit o (fromIntegral b) >> go (i + 1) (o + 2)
      | b < 0xE0 = do
          unit o ((fromIntegral (b .&. 0x1F) `shiftL` 6) .|. cont 1)
          go (i + 2) (o + 2)
      | b < 0xF0 = do
          unit o ((fromIntegral (b .&. 0x0F) `shiftL` 12) .|. (cont 1 `shiftL` 6) .|. cont 2)
          go (i + 3) (o + 2)
      | otherwise = do
          let c = ((fromIntegral (b .&. 0x07) :: Int) `shiftL` 18)
                .|. (fromIntegral (cont 1) `shiftL` 12) .|. (fromIntegral (cont 2) `shiftL` 6)
                .|. fromIntegral (cont 3)
              c' = c - 0x10000
          unit o (fromIntegral (0xD800 + (c' `shiftR` 10)))
          unit (o + 2) (fromIntegral (0xDC00 + (c' .&. 0x3FF)))
          go (i + 4) (o + 4)
      where
        b = A.unsafeIndex arr i
        w = word64At (i :: Int)
        cont :: Int -> Word16
        cont k = fromIntegral (A.unsafeIndex arr (i + k) .&. 0x3F)
    unit :: Int -> Word16 -> IO ()
    unit o u = do
      pokeByteOff p o (fromIntegral u :: Word8)
      pokeByteOff p (o + 1) (fromIntegral (u `unsafeShiftR` 8) :: Word8)
    ascii8 x = x .&. 0x8080808080808080 == 0
    -- The low four bytes of @x@, each widened to 16 bits (little-endian).
    spread :: Word64 -> Word64
    spread x0 =
      let x1 = x0 .&. 0xFFFFFFFF
          x2 = (x1 .|. (x1 `unsafeShiftL` 16)) .&. 0x0000FFFF0000FFFF
       in (x2 .|. (x2 `unsafeShiftL` 8)) .&. 0x00FF00FF00FF00FF
    word64At (I# i) = case arr of
      A.ByteArray ba -> W64# (indexWord8ArrayAsWord64# ba i)

------------------------------------------------------------------------------
-- Decoding

-- One pass, writing UTF-8 into a 'Text' array.  While the text is ASCII it
-- goes into an array of one byte per code unit, eight units per step; at
-- the first unit that isn't ASCII, the array grows to room for three bytes
-- per remaining unit (the most any unit takes: a surrogate pair is four
-- bytes for two units, U+FFFD three for one), and the rest is decoded unit
-- by unit, back to eight at a time after each ASCII unit.  The array is
-- then cut to its length (copied, if it is large and a good part of it is
-- unused, so that a kept value doesn't keep the slack).
--
-- The buffer's bytes are read in 'IO', with the buffer kept alive for the
-- whole decode ('withForeignPtr'); the decode is pure from outside
-- ('unsafeDupablePerformIO'). The private loop checks each read against the
-- value's length.

-- | Decode UTF-16LE text from the server, never failing: each ill-formed
-- code unit (an unpaired surrogate) becomes one U+FFFD, and so does a
-- trailing odd byte.  'Hmssql.Tds.Primitives.decodeUtf16LE' says why.
decodeUtf16LE :: B.ByteString -> Text
decodeUtf16LE (BI.BS fp len)
  | len <= 0 = T.empty
  | otherwise = unsafeDupablePerformIO $ withForeignPtr fp $ \p -> do
      let units = len `unsafeShiftR` 1
      -- One byte per unit if the text starts with ASCII (it may all
      -- be), else the most it can take.
      startsAscii <-
        if len >= 2
          then (\b1 b0 -> b1 == (0 :: Word8) && b0 < (0x80 :: Word8)) <$> peekByteOff p 1 <*> peekByteOff p 0
          else pure False
      let cap0 = if startsAscii then units else maxLength 0 len
      marr0 <- stToIO (A.new cap0)
      (marr, cap, n) <- decodeInto p len marr0 cap0
      arr <- stToIO $ if
        | n == cap -> A.unsafeFreeze marr
        | cap > 4096 && cap - n > cap `unsafeShiftR` 3 -> do
            exact <- A.new n
            A.copyM exact 0 marr 0 n
            A.unsafeFreeze exact
        | otherwise -> A.shrinkM marr n >> A.unsafeFreeze marr
      pure (Text arr 0 n)

-- | 'decodeUtf16LE' for a value that arrives in chunks: the result is the same
-- however the value is cut.  SQL Server ends PLP chunks at packet ends, which
-- can fall inside a code unit or a surrogate pair.  Only the pending character,
-- at most three bytes, is copied between chunks.
decodeUtf16Chunks :: Monad m => Stream (Of B.ByteString) m r -> Stream (Of T.Text) m r
decodeUtf16Chunks = go B.empty
  where
    go carry source = S.effect $ S.next source >>= \case
      Left r -> pure (emit (decodeUtf16LE carry) >> pure r)
      Right (bs, next) ->
        let (texts, tailBytes) = push carry bs
         in pure (mapM_ emit texts >> go tailBytes next)
    emit t = if T.null t then pure () else S.yield t
    -- Complete the carried character from the new chunk, then decode the rest of
    -- the chunk in place.  An unpaired surrogate decodes to U+FFFD as it would in
    -- a whole value, so it isn't held back once the next unit shows it is unpaired.
    push carry bs
      | B.null carry = block bs
      | B.null bs = ([], carry)
      | B.length prefix < 2 || (high first && B.length prefix < 4) = ([], B.copy prefix)
      | otherwise =
          let n = if high first && low (unit prefix 2) then 4 else 2
              text = decodeUtf16LE (B.take n prefix)
              (later, pending) = if n >= B.length carry
                then block (B.drop (n - B.length carry) bs)
                else push (B.drop n carry) bs
           in (text : later, pending)
      where
        prefix = carry <> B.take (4 - B.length carry) bs
        first = unit prefix 0
    -- All but a trailing odd byte or a high surrogate, which wait for their rest.
    block bs =
      let evenLength = B.length bs - B.length bs `mod` 2
          n = if evenLength >= 2 && high (unit bs (evenLength - 2)) then evenLength - 2 else evenLength
       in ([decodeUtf16LE (B.take n bs)], B.copy (B.drop n bs))
    unit bs i = fromIntegral (B.index bs i) + 256 * fromIntegral (B.index bs (i + 1)) :: Int
    high n = n >= 0xD800 && n <= 0xDBFF
    low n = n >= 0xDC00 && n <= 0xDFFF

-- | Decode the @len@ bytes at the pointer into the array (of capacity
-- @cap0@, the number of whole code units), growing it once if the text
-- isn't all ASCII.  Returns the array, its capacity and the number of
-- bytes written.
decodeInto :: Ptr Word8 -> Int -> A.MArray RealWorld -> Int -> IO (A.MArray RealWorld, Int, Int)
decodeInto p len marr0 cap0 = ascii 0 0
  where
    -- The ASCII prefix, into the array of one byte per unit: eight units
    -- at a time while they last, then one.
    ascii !i !o
      | targetByteOrder == LittleEndian, i + 16 <= len = do
          w0 <- word64At i
          w1 <- word64At (i + 8)
          if asciiUnits (w0 .|. w1)
            then writeW64 marr0 o (narrow w0 .|. (narrow w1 `unsafeShiftL` 32)) >> ascii (i + 16) (o + 8)
            else asciiUnit i o
      | i + 2 <= len = asciiUnit i o
      | i >= len = pure (marr0, cap0, o)
      | otherwise = grow i o  -- an odd trailing byte
    asciiUnit !i !o = do
      u <- unitAt i
      if u < 0x80
        then writeW8 marr0 o (fromIntegral u) >> ascii (i + 2) (o + 1)
        else grow i o
    -- Not ASCII (or an odd trailing byte): room for the most the rest can
    -- take, and the general loop.
    grow !i !o = do
      let cap = maxLength o (len - i)
      marr <- if cap <= cap0 then pure marr0 else stToIO (A.resizeM marr0 cap)
      o' <- general marr i o
      pure (marr, max cap cap0, o')

    general :: A.MArray RealWorld -> Int -> Int -> IO Int
    general marr = go
      where
        go !i !o
          | i + 2 > len =
              if i < len then replacement o >> pure (o + 3) else pure o
          | otherwise = do
              u <- unitAt i
              if
                | u < 0x80 -> writeW8 marr o (fromIntegral u) >> run (i + 2) (o + 1)
                | u < 0x800 -> do
                    writeW8 marr o (fromIntegral (0xC0 .|. (u `unsafeShiftR` 6)))
                    writeW8 marr (o + 1) (fromIntegral (0x80 .|. (u .&. 0x3F)))
                    go (i + 2) (o + 2)
                | u < 0xD800 || u > 0xDFFF -> three u o >> go (i + 2) (o + 3)
                | u <= 0xDBFF, i + 4 <= len -> do
                    lo <- unitAt (i + 2)
                    if lo >= 0xDC00 && lo <= 0xDFFF
                      then do
                        let c = 0x10000 + ((u - 0xD800) `unsafeShiftL` 10) + (lo - 0xDC00)
                        writeW8 marr o (fromIntegral (0xF0 .|. (c `unsafeShiftR` 18)))
                        writeW8 marr (o + 1) (fromIntegral (0x80 .|. ((c `unsafeShiftR` 12) .&. 0x3F)))
                        writeW8 marr (o + 2) (fromIntegral (0x80 .|. ((c `unsafeShiftR` 6) .&. 0x3F)))
                        writeW8 marr (o + 3) (fromIntegral (0x80 .|. (c .&. 0x3F)))
                        go (i + 4) (o + 4)
                      else replacement o >> go (i + 2) (o + 3)
                | otherwise -> replacement o >> go (i + 2) (o + 3)
        -- After an ASCII unit: eight at a time while they last.
        run !i !o
          | targetByteOrder == LittleEndian, i + 16 <= len = do
              w0 <- word64At i
              w1 <- word64At (i + 8)
              if asciiUnits (w0 .|. w1)
                then writeW64 marr o (narrow w0 .|. (narrow w1 `unsafeShiftL` 32)) >> run (i + 16) (o + 8)
                else go i o
          | otherwise = go i o
        -- One four-byte store (the array has a byte of slack for it).
        three :: Int -> Int -> IO ()
        three c o
          | targetByteOrder == LittleEndian =
              writeW32 marr o $ fromIntegral $
                (0xE0 .|. (c `unsafeShiftR` 12))
                  .|. ((0x80 .|. ((c `unsafeShiftR` 6) .&. 0x3F)) `unsafeShiftL` 8)
                  .|. ((0x80 .|. (c .&. 0x3F)) `unsafeShiftL` 16)
          | otherwise = do
              writeW8 marr o (fromIntegral (0xE0 .|. (c `unsafeShiftR` 12)))
              writeW8 marr (o + 1) (fromIntegral (0x80 .|. ((c `unsafeShiftR` 6) .&. 0x3F)))
              writeW8 marr (o + 2) (fromIntegral (0x80 .|. (c .&. 0x3F)))
        replacement = three 0xFFFD

    -- The code unit at a byte offset (the caller has checked that it is
    -- within the span).
    unitAt :: Int -> IO Int
    unitAt i = fromIntegral <$> peekWord16LE p i
    {-# INLINE unitAt #-}
    -- Four code units, little-endian, in one word.
    word64At :: Int -> IO Word64
    word64At i = peekWord64LE p i
    {-# INLINE word64At #-}
    -- Four little-endian code units, all below 0x80.
    asciiUnits w = w .&. 0xFF80FF80FF80FF80 == 0
    -- The low bytes of four little-endian 16-bit units, as four bytes.
    narrow :: Word64 -> Word64
    narrow x0 =
      let x1 = (x0 .|. (x0 `unsafeShiftR` 8)) .&. 0x0000FFFF0000FFFF
       in (x1 .|. (x1 `unsafeShiftR` 16)) .&. 0xFFFFFFFF

-- | The most UTF-8 that @n@ bytes of UTF-16 can decode to, after @o@
-- bytes: three per code unit, and three for a trailing byte; plus one
-- byte of slack, for a three-byte sequence written as four.
maxLength :: Int -> Int -> Int
maxLength o n = o + 3 * (n `unsafeShiftR` 1) + (if odd n then 3 else 0) + 1
{-# INLINE maxLength #-}

writeW8 :: A.MArray RealWorld -> Int -> Word8 -> IO ()
writeW8 marr o w = stToIO (A.unsafeWrite marr o w)
{-# INLINE writeW8 #-}

-- | Four bytes at a byte offset (unaligned), in the machine's order.
writeW32 :: A.MArray RealWorld -> Int -> Word32 -> IO ()
writeW32 (MutableByteArray mba) (I# o) (W32# w) = IO $ \s -> (# writeWord8ArrayAsWord32# mba o w s, () #)
{-# INLINE writeW32 #-}

-- | Eight bytes at a byte offset (unaligned), in the machine's order.
writeW64 :: A.MArray RealWorld -> Int -> Word64 -> IO ()
writeW64 (MutableByteArray mba) (I# o) (W64# w) = IO $ \s -> (# writeWord8ArrayAsWord64# mba o w s, () #)
{-# INLINE writeW64 #-}
