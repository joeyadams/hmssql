-- | Small helpers shared by the "Wire.*" pure protocol specs: round-trip
-- assertions and incremental ('Get.Decoder') feeding, to check that parsers
-- give the same answer regardless of how the bytes arrive in chunks.
module Wire.Util
  ( roundTrip
  , roundTripBytes
  , unsafeRight
  , runIncremental
  , byteByByte
  , genChunks
  , genPayload
  ) where

import Data.Bits (shiftL, shiftR, xor)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Word (Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

-- | Encode with @put@, decode with @get@, and check the result matches the
-- original value with nothing left over.
roundTrip :: (Eq a, Show a, MonadTest m) => (a -> Put.Put) -> Get.Get a -> a -> m ()
roundTrip put get a = do
  let bytes = Put.runPut (put a)
  case Get.runGetOrFail get bytes of
    Left (_, _, err) -> annotate err >> failure
    Right (rest, _, a') -> do
      LB.null rest === True
      a' === a

-- | Like 'roundTrip', but the encoder is a plain 'Put.Put' action (not a
-- function of the value): useful when the byte-level shape, not a decoded
-- Haskell value, is what's being checked.
roundTripBytes :: (Eq a, Show a, MonadTest m) => Put.Put -> Get.Get a -> a -> m ()
roundTripBytes body get a = do
  let bytes = Put.runPut body
  case Get.runGetOrFail get bytes of
    Left (_, _, err) -> annotate err >> failure
    Right (rest, _, a') -> do
      LB.null rest === True
      a' === a

unsafeRight :: Either String a -> a
unsafeRight = either error id

-- | Run a 'Get.Get' parser fed one chunk at a time, using binary's own
-- incremental interface. 'Left' is the parser's own failure message.
runIncremental :: Get.Get a -> [B.ByteString] -> Either String a
runIncremental get = go (Get.runGetIncremental get)
  where
    go (Get.Done _ _ a) _ = Right a
    go (Get.Fail _ _ err) _ = Left err
    go dec [] = case Get.pushEndOfInput dec of
      Get.Done _ _ a -> Right a
      Get.Fail _ _ err -> Left err
      Get.Partial _ -> Left "runIncremental: ran out of input"
    go dec (c : cs) = go (Get.pushChunk dec c) cs

-- | The whole strict 'B.ByteString' as single-byte chunks.
byteByByte :: B.ByteString -> [B.ByteString]
byteByByte = map B.singleton . B.unpack

-- | A random way to cut a 'B.ByteString' into consecutive pieces that
-- concatenate back to it (including the empty split list producing one chunk).
genChunks :: B.ByteString -> Gen [B.ByteString]
genChunks bs
  | B.null bs = pure [bs]
  | otherwise = do
      -- Cut points, as a sorted set of offsets in (0, length).
      let n = B.length bs
      cuts <- Gen.subsequence [1 .. n - 1]
      pure (splitAtAll cuts bs)
  where
    splitAtAll cuts s = go 0 cuts s
      where
        go _ [] rest = [rest]
        go pos (c : cs) rest =
          let (a, b) = B.splitAt (c - pos) rest
           in a : go c cs b

-- | Opaque bytes of up to @maxLen@ bytes, for code that never looks at
-- them (packet framing).  'Gen.bytes' builds, and keeps a shrink tree for,
-- a list of every byte (about 70 ms per 100 KB); this draws
-- a length and a seed and fills the bytes from an xorshift generator, so
-- that bytes moved, dropped or repeated still show.  It shrinks the length.
genPayload :: Int -> Gen B.ByteString
genPayload maxLen = do
  n <- Gen.int (Range.linear 0 maxLen)
  seed <- Gen.word32 (Range.linear 1 maxBound)
  pure (fst (B.unfoldrN n (\s -> let s' = xorshift s in Just (fromIntegral (s' `shiftR` 24), s')) seed))
  where
    xorshift :: Word32 -> Word32
    xorshift x0 =
      let x1 = x0 `xor` (x0 `shiftL` 13)
          x2 = x1 `xor` (x1 `shiftR` 17)
      in x2 `xor` (x2 `shiftL` 5)
