{-# LANGUAGE BangPatterns #-}
-- | Reading result sets without a server: the synthetic responses of
-- "Bench.Tokens", split into 4096-byte packets' payloads, parsed into
-- tokens the way the connection parses them, and decoded.  No network, no
-- threads, no locks: what is left is the token parser and the row
-- decoders.
--
-- Each dataset has four benchmarks:
--
-- * @tokens@ and @rows@: materialized raw values through the same recipe.
--   Both historical case names remain for comparison; there is one parser.
-- * @typed@: direct reading and decoding with the dataset's RowDecoder.
-- * @SqlRow@: direct reading and conversion through sqlRowDecoderFor.
--
-- The @text@ group decodes single strings, as a column value's bytes:
-- UTF-16LE ('decodeUtf16LE') of 50 and 4000 characters of ASCII, Latin
-- text with accents, CJK, emoji (surrogate pairs) and ill-formed UTF-16
-- (lone surrogates), and single-byte code page text (@varchar@ in code
-- page 1252).
module Bench.Decode (benchmarks) where

import Control.DeepSeq (NFData (..), rwhnf)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word16, Word8)
import Test.Tasty.Bench

import Hmssql.Decoding (compileRowDecoder)
import Hmssql.Tds.CodePage (collationTextDecoder)
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Collation (..), decodeUtf16LE)
import Hmssql.Tds.Value (rowCellLength, rowColumnCount)
import Hmssql.Tds.Token (Token (..))

import Bench.Tokens

-- | A response's packet payloads, built by 'env' (so building them isn't
-- measured).
newtype Payloads = Payloads [B.ByteString]

instance NFData Payloads where
  rnf (Payloads ps) = foldr (\p r -> rwhnf p `seq` r) () ps

benchmarks :: Benchmark
benchmarks = bgroup "Decode" $
  [ env (pure (Payloads (packetPayloads (responseBody ds)))) $ \ ~(Payloads ps) -> bgroup (dsName ds)
      [ bench "tokens" $ whnfIO (valueBytes <$> tokens ctx ps)
      , bench "rows" $ whnfIO (valueBytes <$> walked ctx ps)
      , case dsTyped ds of
          Typed _ dec -> bench "typed" $ nfIO (decodeRows (compileRowDecoder dec) ctx ps)
      , bench "SqlRow" $ nfIO (decodeRows sqlRowCompiler ctx ps)
      ]
  | ds <- datasets
  ] ++ [textBenchmarks]
  where
    ctx = defaultTdsContext

textBenchmarks :: Benchmark
textBenchmarks = bgroup "text" $
  [ bench ("utf16 " ++ name ++ " " ++ show n) $ whnf decodeUtf16LE (utf16Of n t)
  | (name, t) <- [("ASCII", "name-12345 "), ("Latin", "Caf\233 cr\232me br\251l\233e n\186 1 "), ("CJK", "\26085\26412\35486\12398\12486\12461\12473\12488")]
  , n <- [50, 4000]
  ] ++
  [ bench "utf16 emoji 4000" $ whnf decodeUtf16LE (utf16Of 4000 "\128512a")
  , bench "utf16 ill-formed 4000" $ whnf decodeUtf16LE illFormed
  ] ++
  [ bench ("cp1252 " ++ name ++ " " ++ show n) $ whnf cp1252 (latin1Of n t)
  | (name, t) <- [("ASCII", "name-12345 "), ("Latin", "Caf\233 cr\232me br\251l\233e n\186 1 ")]
  , n <- [100, 4000]
  ]
  where
    -- @n@ UTF-16 code units of the text repeated.
    utf16Of n t = B.take (2 * n) (T.encodeUtf16LE (T.replicate (n `div` T.length t + 1) t))
    latin1Of :: Int -> Text -> B.ByteString
    latin1Of n t = B.pack (take n (cycle (map (fromIntegral . fromEnum) (T.unpack t))))
    -- 4000 units, a lone surrogate (high or low) every tenth.
    illFormed = B.pack $ concatMap le16
      [if i `mod` 10 == 9 then (if even (i `div` 10) then 0xD800 else 0xDC00) else 0x61 + fromIntegral (i `mod` 26) | i <- [0 .. 3999 :: Int]]
    le16 :: Word16 -> [Word8]
    le16 u = [fromIntegral u, fromIntegral (u `div` 256)]
    -- SQL_Latin1_General_CP1_CI_AS
    cp1252 = case collationTextDecoder (Collation 0x00D00409 0x34) of
      Right d -> either error id . d
      Left e -> error e

-- | The total length of materialized ROW values. Reading the lengths also
-- forces any deferred ownership copies.
valueBytes :: [Token] -> Int
valueBytes = foldl' step 0
  where
    step !acc = \case
      TRow row -> foldl' (\a i -> a + max 0 (rowCellLength row i)) acc [0 .. rowColumnCount row - 1]
      _ -> acc
