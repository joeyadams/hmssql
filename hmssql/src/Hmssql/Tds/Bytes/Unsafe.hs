{-# LANGUAGE CPP #-}
-- | Unchecked little-endian loads and stores through raw pointers.
-- Use "Hmssql.Tds.Bytes" for bounds-checked reads from a 'Data.ByteString.ByteString'.
--
-- Every operation needs a valid span of 2, 4 or 8 bytes at the given byte
-- offset.  A read needs memory that is initialized and readable, and a write
-- needs memory that is writable and that nothing else expects to stay as it
-- was.  The caller keeps the allocation alive for the whole call and makes
-- sure the offset arithmetic doesn't overflow.  Nothing here checks a
-- capacity, an initialization, an ownership or a lifetime.
--
-- Alignment is handled here: on targets known to load and store words at any
-- address an operation is one word access, and elsewhere it goes byte by
-- byte.  The functions are public for codecs and transports written outside
-- hmssql.
module Hmssql.Tds.Bytes.Unsafe
  ( -- * Unchecked pointer reads
    peekWord16LE
  , peekWord32LE
  , peekWord64LE
    -- * Unchecked pointer writes
  , pokeWord16LE
  , pokeWord32LE
  , pokeWord64LE
  ) where

#include "MachDeps.h"

-- Whether the target loads and stores words at any byte address.  Where
-- it doesn't (or it isn't known to), multi-byte values are assembled from
-- byte loads, which never need alignment.
#if defined(x86_64_HOST_ARCH) || defined(i386_HOST_ARCH) || defined(aarch64_HOST_ARCH) || defined(powerpc64le_HOST_ARCH)
#define HMSSQL_UNALIGNED_ACCESS 1
#endif

import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff, pokeByteOff)
#ifdef HMSSQL_UNALIGNED_ACCESS
import Data.Word (byteSwap16, byteSwap32, byteSwap64)
import GHC.ByteOrder (ByteOrder (..), targetByteOrder)
#else
import Data.Bits (unsafeShiftL, unsafeShiftR, (.|.))
#endif

------------------------------------------------------------------------------
-- Unaligned loads and stores
--
-- 'Foreign.Storable' promises nothing for a word at an address that isn't
-- a multiple of its size, and a wire offset is any byte; on the
-- architectures listed above, an unaligned load is one instruction, and
-- that is what is done.  Elsewhere, the bytes are loaded one at a time.

-- | A little-endian 16-bit word at a byte offset from the pointer.
peekWord16LE :: Ptr Word8 -> Int -> IO Word16
#ifdef HMSSQL_UNALIGNED_ACCESS
peekWord16LE p o = fromLE16 <$> peekByteOff p o
#else
peekWord16LE p o = do
  b0 <- byte p o
  b1 <- byte p (o + 1)
  pure (fromIntegral b0 .|. (fromIntegral b1 `unsafeShiftL` 8))
#endif
{-# INLINE peekWord16LE #-}

-- | A little-endian 32-bit word at a byte offset from the pointer.
peekWord32LE :: Ptr Word8 -> Int -> IO Word32
#ifdef HMSSQL_UNALIGNED_ACCESS
peekWord32LE p o = fromLE32 <$> peekByteOff p o
#else
peekWord32LE p o = do
  lo <- peekWord16LE p o
  hi <- peekWord16LE p (o + 2)
  pure (fromIntegral lo .|. (fromIntegral hi `unsafeShiftL` 16))
#endif
{-# INLINE peekWord32LE #-}

-- | A little-endian 64-bit word at a byte offset from the pointer.
peekWord64LE :: Ptr Word8 -> Int -> IO Word64
#ifdef HMSSQL_UNALIGNED_ACCESS
peekWord64LE p o = fromLE64 <$> peekByteOff p o
#else
peekWord64LE p o = do
  lo <- peekWord32LE p o
  hi <- peekWord32LE p (o + 4)
  pure (fromIntegral lo .|. (fromIntegral hi `unsafeShiftL` 32))
#endif
{-# INLINE peekWord64LE #-}

-- | Store a 16-bit word little-endian at a byte offset from the pointer.
pokeWord16LE :: Ptr Word8 -> Int -> Word16 -> IO ()
#ifdef HMSSQL_UNALIGNED_ACCESS
pokeWord16LE p o w = pokeByteOff p o (fromLE16 w)
#else
pokeWord16LE p o w = do
  pokeByteOff p o (fromIntegral w :: Word8)
  pokeByteOff p (o + 1) (fromIntegral (w `unsafeShiftR` 8) :: Word8)
#endif
{-# INLINE pokeWord16LE #-}

-- | Store a 32-bit word little-endian at a byte offset from the pointer.
pokeWord32LE :: Ptr Word8 -> Int -> Word32 -> IO ()
#ifdef HMSSQL_UNALIGNED_ACCESS
pokeWord32LE p o w = pokeByteOff p o (fromLE32 w)
#else
pokeWord32LE p o w = do
  pokeWord16LE p o (fromIntegral w)
  pokeWord16LE p (o + 2) (fromIntegral (w `unsafeShiftR` 16))
#endif
{-# INLINE pokeWord32LE #-}

-- | Store a 64-bit word little-endian at a byte offset from the pointer.
pokeWord64LE :: Ptr Word8 -> Int -> Word64 -> IO ()
#ifdef HMSSQL_UNALIGNED_ACCESS
pokeWord64LE p o w = pokeByteOff p o (fromLE64 w)
#else
pokeWord64LE p o w = do
  pokeWord32LE p o (fromIntegral w)
  pokeWord32LE p (o + 4) (fromIntegral (w `unsafeShiftR` 32))
#endif
{-# INLINE pokeWord64LE #-}

#ifdef HMSSQL_UNALIGNED_ACCESS
-- The word as loaded from (or to be stored as) little-endian bytes.
fromLE16 :: Word16 -> Word16
fromLE16 w = case targetByteOrder of
  LittleEndian -> w
  BigEndian -> byteSwap16 w
{-# INLINE fromLE16 #-}

fromLE32 :: Word32 -> Word32
fromLE32 w = case targetByteOrder of
  LittleEndian -> w
  BigEndian -> byteSwap32 w
{-# INLINE fromLE32 #-}

fromLE64 :: Word64 -> Word64
fromLE64 w = case targetByteOrder of
  LittleEndian -> w
  BigEndian -> byteSwap64 w
{-# INLINE fromLE64 #-}
#else
byte :: Ptr Word8 -> Int -> IO Word8
byte = peekByteOff
{-# INLINE byte #-}
#endif
