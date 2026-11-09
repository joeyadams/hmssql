{-# LANGUAGE BangPatterns, OverloadedStrings #-}
-- A standalone timing driver. Compile this identical source against both
-- libraries; the build script never runs it. Each measured batch decodes 32
-- inputs from a prepared ring of 31 buffers, rotating the starting input.
module Main (main) where

import Control.DeepSeq (NFData (..), force)
import Control.Exception (evaluate)
import Control.Monad (forM, forM_, unless)
import qualified Data.ByteString as B
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Internal as TextInternal
import System.Environment (getArgs)
import Test.Tasty.Bench

import qualified Hmssql.Tds.Utf16 as Utf16

data Inputs = Inputs !(IORef [B.ByteString]) !Int
instance NFData Inputs where
  rnf (Inputs cursor expected) = cursor `seq` expected `seq` ()

-- All seeds are BMP characters, so the requested length is also the number
-- of UTF-16 code units. The Japanese seed matches the existing Decode case.
families :: [(String, Text)]
families =
  [ ("CJK-japanese", "日本語のテキスト")
  , ("CJK-chinese", "中文測試漢字資料庫查詢")
  , ("CJK-hangul", "한국어문자열변환검사")
  , ("CJK-range", "一俿叿忿濿翿迿鿿")
  , ("ASCII", "name-12345 ")
  , ("Latin", "Café crème brûlée nº 1 ")
  ]

lengths :: [Int]
lengths = [1 .. 100] ++ [4000]

offsets :: [Int]
offsets = [0 .. 7]

prepare :: Text -> Int -> Int -> IO Inputs
prepare seed count = prepareCycle seed [count]

-- The mixed-length cases perturb output allocation sizes near the original
-- 50-character case while keeping their prepared input ring fixed.
prepareCycle :: Text -> [Int] -> Int -> IO Inputs
prepareCycle seed counts offset = do
  buffers <- forM [0 .. 30] $ \rotation -> do
    let count = counts !! (rotation `mod` length counts)
        start = rotation `mod` T.length seed
        rotated = T.drop start seed <> T.take start seed
        expected = T.take count (T.replicate (count `div` T.length seed + 1) rotated)
        payload = Text.encodeUtf16LE expected
        -- Every offset uses the same total backing-buffer size. Only the safe
        -- slice's starting byte changes, including odd-address variants.
        backing = B.concat [B.replicate offset 0xa5, payload, B.replicate (7 - offset) 0xa5]
        bytes = B.take (B.length payload) (B.drop offset backing)
    _ <- evaluate (force bytes)
    unless (Utf16.decodeUtf16LE bytes == expected) $
      fail "The prepared UTF-16 slice did not decode to its expected text."
    pure (bytes, B.length (Text.encodeUtf8 expected))
  let ring = cycle (map fst buffers)
      expectedBatch = sum (take 32 (cycle (map snd buffers)))
  -- Materialize the cyclic spine outside the measured action too.
  _ <- evaluate (force (take 62 ring))
  (\cursor -> Inputs cursor expectedBatch) <$> newIORef ring

-- Force each Text and inspect its stored UTF-8 byte length. Pattern matching
-- the descriptor adds no scan over the decoded UTF-8 characters.
-- The input cursor advances by 32 around a 31-buffer ring, amortizing cursor
-- overhead while changing each buffer's position between measured calls.
decodeBatch :: Inputs -> IO Int
decodeBatch (Inputs cursor _) = readIORef cursor >>= go 32 0
  where
    go 0 !checksum rest = writeIORef cursor rest >> pure checksum
    go !remaining !checksum (bytes : rest) = do
      decoded <- evaluate (Utf16.decodeUtf16LE bytes)
      let !next = case decoded of TextInternal.Text _ _ bytesWritten -> checksum + bytesWritten
      go (remaining - 1) next rest
    go _ _ [] = fail "The prepared input ring unexpectedly ended."
{-# NOINLINE decodeBatch #-}

benchmarks :: Benchmark
benchmarks = bgroup "isolated-utf16"
  [ bgroup name $
      [ bgroup ("len=" ++ show count)
          [ env (prepare seed count offset) $ \inputs ->
              bench ("offset=" ++ show offset) (whnfIO (decodeBatch inputs))
          | offset <- offsets
          ]
      | count <- lengths
      ] ++
      [ bgroup "mixed=47..53"
          [ env (prepareCycle seed [47 .. 53] offset) $ \inputs ->
              bench ("offset=" ++ show offset) (whnfIO (decodeBatch inputs))
          | offset <- offsets
          ]
      ]
  | (name, seed) <- families
  ]

main :: IO ()
main = getArgs >>= \args -> case args of
  ["--check"] -> do
    forM_ families $ \(_, seed) -> forM_ lengths $ \count -> forM_ offsets $ \offset -> do
      inputs <- prepare seed count offset
      result <- decodeBatch inputs
      let Inputs _ expected = inputs
      unless (result == expected) (fail "Unexpected decode checksum.")
    forM_ families $ \(_, seed) -> forM_ offsets $ \offset -> do
      inputs <- prepareCycle seed [47 .. 53] offset
      result <- decodeBatch inputs
      let Inputs _ expected = inputs
      unless (result == expected) (fail "Unexpected mixed-length decode checksum.")
    putStrLn "Checked 4,848 fixed-length and 48 mixed-length cases; 31 prepared buffers per case."
  _ -> defaultMain [benchmarks]
