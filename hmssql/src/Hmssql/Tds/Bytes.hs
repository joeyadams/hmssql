{-# LANGUAGE CPP #-}
-- | Bounds-checked little-endian (and two big-endian) reads from a
-- 'B.ByteString' at an offset: what the value decoders use once a value's
-- length has been checked against its type.
--
-- No 'Data.Binary.Get', no intermediate 'B.ByteString', and no pointers here:
-- each reader checks that the @n@ bytes at @off@ lie within the buffer (calling
-- 'error' if they don't, as 'B.index' does: a read can never touch memory
-- outside the buffer, whatever the caller got wrong), then assembles the value
-- from its bytes.  Raw pointer operations, for the character codecs, are in
-- "Hmssql.Tds.Bytes.Unsafe".
--
-- The parser and the scalar codecs read with these.  A field conversion
-- receives a whole value, so it never needs an offset into a packet.
module Hmssql.Tds.Bytes
  ( -- * Checked reads from a buffer
    word8At
  , word16LeAt
  , word32LeAt
  , word64LeAt
  , word16BeAt
  , word64BeAt
  , wordLeAt
  , int8At
  , int16LeAt
  , int32LeAt
  , int64LeAt
    -- * Spans
  , spanWithin
  , checkSpan
  ) where

#include "MachDeps.h"

#if WORD_SIZE_IN_BITS < 64
#error "hmssql needs a 64-bit Int: its wire lengths (up to 2^32 - 1, and PLP totals up to 2^64 - 2) are converted to Int"
#endif

import Data.Bits (Bits, shiftL, unsafeShiftL, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Word (Word16, Word32, Word64, Word8, byteSwap16, byteSwap64)

-- | Whether @len@ bytes at @off@ lie within a buffer of @size@ bytes:
-- @0 <= off@, @0 <= len@ and @off + len <= size@, checked without
-- overflowing.
spanWithin :: Int -> Int -> Int -> Bool
spanWithin size off len = off >= 0 && len >= 0 && len <= size - off
{-# INLINE spanWithin #-}

-- | 'error' unless the span lies within the buffer ('spanWithin').
checkSpan :: String -> B.ByteString -> Int -> Int -> ()
checkSpan who bs off len
  | spanWithin (B.length bs) off len = ()
  | otherwise = outOfBounds who len off (B.length bs)
{-# INLINE checkSpan #-}

outOfBounds :: String -> Int -> Int -> Int -> a
outOfBounds who n off size = error $
  who ++ ": " ++ show n ++ " bytes at offset " ++ show off ++ " of a " ++ show size ++ "-byte buffer"
{-# NOINLINE outOfBounds #-}

-- | A read of @n@ bytes at the offset, checked against the buffer.
checked :: Int -> B.ByteString -> Int -> a -> a
checked n bs off read
  | spanWithin (B.length bs) off n = read
  | otherwise = outOfBounds "Hmssql.Tds.Bytes" n off (B.length bs)
{-# INLINE checked #-}

-- GHC doesn't merge these into one load, so a word is several. Measured against
-- a single load through runRW#, which had to sidestep unsafeDupablePerformIO's lazy
-- to stay unboxed: Decode 1.03 in time and 1.00 in allocation, Mock.query typed 1.04.
-- That was accepted to keep this code free of pointers and of that trick.

-- | The byte at a position already checked, widened and shifted into place.
byteAt :: (Bits w, Num w) => B.ByteString -> Int -> Int -> w
byteAt bs off i = fromIntegral (BU.unsafeIndex bs (off + i)) `unsafeShiftL` (8 * i)
{-# INLINE byteAt #-}

word8At :: B.ByteString -> Int -> Word8
word8At bs off = checked 1 bs off (BU.unsafeIndex bs off)
{-# INLINE word8At #-}

word16LeAt :: B.ByteString -> Int -> Word16
word16LeAt bs off = checked 2 bs off (byteAt bs off 0 .|. byteAt bs off 1)
{-# INLINE word16LeAt #-}

word32LeAt :: B.ByteString -> Int -> Word32
word32LeAt bs off = checked 4 bs off
  (byteAt bs off 0 .|. byteAt bs off 1 .|. byteAt bs off 2 .|. byteAt bs off 3)
{-# INLINE word32LeAt #-}

word64LeAt :: B.ByteString -> Int -> Word64
word64LeAt bs off = checked 8 bs off
  ( byteAt bs off 0 .|. byteAt bs off 1 .|. byteAt bs off 2 .|. byteAt bs off 3
    .|. byteAt bs off 4 .|. byteAt bs off 5 .|. byteAt bs off 6 .|. byteAt bs off 7 )
{-# INLINE word64LeAt #-}

-- | Big-endian: a packet header's fields, and a GUID's last eight bytes.
word16BeAt :: B.ByteString -> Int -> Word16
word16BeAt bs off = byteSwap16 (word16LeAt bs off)
{-# INLINE word16BeAt #-}

word64BeAt :: B.ByteString -> Int -> Word64
word64BeAt bs off = byteSwap64 (word64LeAt bs off)
{-# INLINE word64BeAt #-}

-- | An unsigned little-endian integer of @n@ bytes (0 through 8).
wordLeAt :: Int -> B.ByteString -> Int -> Word64
wordLeAt n bs off = case n of
  3 -> fromIntegral (word16LeAt bs off) .|. (fromIntegral (word8At bs (off + 2)) `shiftL` 16)
  4 -> fromIntegral (word32LeAt bs off)
  5 -> fromIntegral (word32LeAt bs off) .|. (fromIntegral (word8At bs (off + 4)) `shiftL` 32)
  _ -> go (n - 1) 0
  where
    go i !acc
      | i < 0 = acc
      | otherwise = go (i - 1) ((acc `shiftL` 8) .|. fromIntegral (word8At bs (off + i)))
{-# INLINE wordLeAt #-}

int8At :: B.ByteString -> Int -> Int8
int8At bs off = fromIntegral (word8At bs off)
{-# INLINE int8At #-}

int16LeAt :: B.ByteString -> Int -> Int16
int16LeAt bs off = fromIntegral (word16LeAt bs off)
{-# INLINE int16LeAt #-}

int32LeAt :: B.ByteString -> Int -> Int32
int32LeAt bs off = fromIntegral (word32LeAt bs off)
{-# INLINE int32LeAt #-}

int64LeAt :: B.ByteString -> Int -> Int64
int64LeAt bs off = fromIntegral (word64LeAt bs off)
{-# INLINE int64LeAt #-}
