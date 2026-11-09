{-# LANGUAGE BangPatterns #-}
module Main where
import qualified ProbeUtf16 as U
import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.Bits
import Data.Char (chr)
import Data.Word
import Data.IORef
import Control.Monad
import Data.Functor.Identity
import qualified Streaming.Prelude as S

main :: IO ()
main = do
  checks <- newIORef (0 :: Int)
  let check bytes = do
        unless (U.decodeUtf16LE bytes == reference bytes) $ fail ("UTF16 mismatch: " ++ show bytes)
        modifyIORef' checks (+1)
      checkChunks width bytes = do
        let actual = T.concat (runIdentity (S.toList_ (U.decodeUtf16Chunks (S.each (chunks width bytes)))))
        unless (actual == reference bytes) $ fail ("chunked UTF16 mismatch: " ++ show (width, bytes))
        modifyIORef' checks (+1)
  forM_ [0..65535 :: Int] $ \u -> do
    let bytes = units [fromIntegral u]
    forM_ [0,1,3,7] $ \off -> check (slice off bytes)
    check (bytes <> B.singleton 0x41)
  forM_ [0..8] $ \prefix -> forM_ [0..80] $ \n -> forM_ [0..3] $ \off ->
    forM_ [False,True] $ \oddByte -> do
      let bytes = units (replicate prefix 0x61 ++ take n (cycle [0x800,0x4E2D,0xD7FF,0xE000,0xFFFF,0xD800,0xDC00,0x7FF]))
                    <> if oddByte then B.singleton 0x41 else B.empty
      check (slice off bytes)
  forM_ [0,1,2,7,8,15,16,17,31,32,49,50,51,63,64,65,127,128,129,2047,2048,4095,4096,4097] $ \n -> do
    let bytes = units (0x61 : take n (cycle [0x4E2D,0xD800,0xDC00,0xDFFF,0x800,0xFFFF])) <> B.singleton 0x41
    forM_ [1,3,7] $ \off -> check (slice off bytes)
    forM_ [1,2,3,7,16,64,4096] $ \width -> checkChunks width bytes
  readIORef checks >>= print

slice :: Int -> B.ByteString -> B.ByteString
slice n bytes = B.take (B.length bytes) (B.drop n (B.replicate n 0xA5 <> bytes <> B.replicate 16 0x5A))
units :: [Word16] -> B.ByteString
units = B.pack . concatMap (\u -> [fromIntegral u, fromIntegral (u `shiftR` 8)])
chunks :: Int -> B.ByteString -> [B.ByteString]
chunks n bytes | B.null bytes = []
               | otherwise = let (a,b) = B.splitAt n bytes in a : chunks n b
reference :: B.ByteString -> T.Text
reference bytes = T.pack (go 0)
  where
    len = B.length bytes
    unit i = fromIntegral (B.index bytes i) .|. (fromIntegral (B.index bytes (i+1)) `shiftL` 8) :: Int
    go !i
      | i >= len = []
      | i+1 >= len = ['\xFFFD']
      | u >= 0xD800 && u <= 0xDBFF && i+3 < len && lo >= 0xDC00 && lo <= 0xDFFF =
          chr (0x10000 + ((u-0xD800) `shiftL` 10) + lo-0xDC00) : go (i+4)
      | u >= 0xD800 && u <= 0xDFFF = '\xFFFD' : go (i+2)
      | otherwise = chr u : go (i+2)
      where u = unit i; lo = unit (i+2)
