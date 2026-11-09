-- | A streamed value of at most 'streamWholeLimit' bytes reaches its consumer
-- whole, as one chunk with its length, whatever its delimiter and wherever the
-- packets cut it; a larger one arrives in pieces that join up to it, an unknown
-- total's starting with the chunks read before it passed the limit.  A
-- 'FoldingCell' converts the first by its whole value's conversions and folds the
-- second, with 'nullableField' and 'refineField' over it.
module Wire.StreamWholeSpec (spec) where

import Control.Monad (forM_, when)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as LT
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql.Decoding
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Collation (..))
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.CodePage (collationCodec, decodeCodec)
import Hmssql.Tds.Token (ColumnInfo (..))
import qualified Hmssql.Tds.Utf16 as Utf16
import Hmssql.Tds.TypeInfo (TypeInfo (..))

-- How a value is delimited: PLP with its total or without, in chunks of at most
-- this many bytes, or behind a two-byte length.
data Delimiter = Plp Bool Int | Short
  deriving (Show)

-- A ROW of one value (NULL for 'Nothing'), then a sentinel byte.
rowBytes :: Delimiter -> Maybe B.ByteString -> B.ByteString
rowBytes delimiter value = LB.toStrict $ Put.runPut $ do
  Put.putWord8 0xD1
  case (delimiter, value) of
    (Short, Nothing) -> Put.putWord16le 0xFFFF
    (Short, Just v) -> Put.putWord16le (fromIntegral (B.length v)) >> Put.putByteString v
    (Plp _ _, Nothing) -> Put.putWord64le 0xFFFFFFFFFFFFFFFF
    (Plp known size, Just v) -> do
      Put.putWord64le (if known then fromIntegral (B.length v) else 0xFFFFFFFFFFFFFFFE)
      let chunks b
            | B.null b = pure ()
            | otherwise = do
                let (h, t) = B.splitAt size b
                Put.putWord32le (fromIntegral (B.length h)) >> Put.putByteString h >> chunks t
      chunks v
      Put.putWord32le 0
  Put.putWord8 0xFE

-- The row decoded with the cut at each of these places (every place when
-- 'Nothing'), and the sentinel after it.
decodedAt :: TypeInfo -> RowDecoder a -> Maybe [Int] -> B.ByteString -> IO [a]
decodedAt ti decoder cuts bytes = do
  compiled <- either (fail . show) pure (compileRowDecoder decoder defaultTdsContext [ColumnInfo "v" ti 1 0 Nothing])
  mapM (\cut -> do
    ((result, marker), rest) <- P.parseChunks ((,) <$> rowRecipe compiled 1_000_000 <*> P.word8)
      [B.take cut bytes, B.drop cut bytes]
    marker `shouldBe` 0xFE
    all B.null rest `shouldBe` True
    either (\_ -> fail "the row failed") pure result) (maybe [0 .. B.length bytes] (nub . filter (<= B.length bytes)) cuts)

-- What a consumer saw: the length it was told and the chunks.
seen :: RowDecoder (Maybe Int64, [B.ByteString])
seen = singleField (streamField (\v -> (,) (valueLength v) <$> S.toList_ (valueChunks v)))

-- A 'FoldingCell' that says which way it read a value: whole, or folded from
-- this many pieces.
folding :: FieldDecoder (Either B.ByteString (Int, B.ByteString))
folding = fieldDecoderCompiled $ \_ _ -> Right $ FoldingCell (Left "NULL")
  (\b -> Right (Left (B.copy b))) (\b -> Right (Left b))
  (\chunks -> do
    pieces <- S.toList_ chunks
    pure (Right (Right (length pieces, B.concat pieces))))

seenText :: RowDecoder [Text]
seenText = singleField (streamTextField (\_ chunks -> S.toList_ chunks))

-- A few cuts of a long row: in its header, in the first chunk, and near its end.
someCuts :: B.ByteString -> Maybe [Int]
someCuts bytes = let n = B.length bytes in Just [0, 1, 9, 13, 14, 5000, n `div` 2, n - 2, n - 1, n]

value :: Int -> B.ByteString
value n = B.pack (take n (cycle [0 .. 250]))

spec :: Spec
spec = do
  it "gives a value of at most the limit as one chunk, with its length" $ do
    let cases =
          [ (d, n) | d <- [Plp True 7, Plp False 7, Plp True 8000, Plp False 8000], n <- [1, 6, 7, 100] ]
          ++ [ (Short, n) | n <- [1, 100, 8000] ]
    forM_ cases $ \(d, n) -> do
      let ti = case d of Short -> TIBigVarBinary 8000; _ -> TIBigVarBinary 0xFFFF
          bytes = rowBytes d (Just (value n))
      results <- decodedAt ti seen (if n > 100 then someCuts bytes else Nothing) bytes
      results `shouldSatisfy` all (== (Just (fromIntegral n), [value n]))
    forM_ [Plp True 8000, Plp False 8000, Plp False 4096] $ \d -> do
      let bytes = rowBytes d (Just (value streamWholeLimit))
      decodedAt (TIBigVarBinary 0xFFFF) seen (someCuts bytes) bytes
        >>= (`shouldSatisfy` all (== (Just (fromIntegral streamWholeLimit), [value streamWholeLimit])))

  it "gives an empty value as no chunks" $
    forM_ [Plp True 7, Plp False 7, Short] $ \d -> do
      let ti = case d of Short -> TIBigVarBinary 8000; _ -> TIBigVarBinary 0xFFFF
      decodedAt ti seen Nothing (rowBytes d (Just B.empty)) >>= (`shouldSatisfy` all (== (Just 0, [])))

  it "streams a value past the limit in pieces, with its total when the server sent one" $
    forM_ [(True, 8000), (False, 8000), (False, 7), (True, streamWholeLimit + 1)] $ \(known, size) -> do
      let v = value (streamWholeLimit + 1)
          bytes = rowBytes (Plp known size) (Just v)
      results <- decodedAt (TIBigVarBinary 0xFFFF) seen (someCuts bytes) bytes
      forM_ results $ \(total, chunks) -> do
        total `shouldBe` (if known then Just (fromIntegral (B.length v)) else Nothing)
        B.concat chunks `shouldBe` v
        -- One chunk lying in one payload arrives as one piece.
        when (size < B.length v) $ length chunks `shouldSatisfy` (> 1)

  it "decodes text whole or in pieces, a surrogate pair cut by the chunks included" $ do
    let small = T.replicate 3 "a\128512\28450"
        large = T.replicate (streamWholeLimit `div` 8 + 1) "a\128512\28450"
        ti = TINVarChar 0xFFFF (Collation 0 0)
    forM_ [Plp True 7, Plp False 7] $ \d -> do
      decodedAt ti seenText Nothing (rowBytes d (Just (TE.encodeUtf16LE small))) >>= (`shouldSatisfy` all (== [small]))
      let bytes = rowBytes d (Just (TE.encodeUtf16LE large))
      results <- decodedAt ti seenText (someCuts bytes) bytes
      forM_ results $ \chunks -> T.concat chunks `shouldBe` large

  it "converts a FoldingCell's value whole up to the limit and folds a longer one" $ do
    forM_ [(d, n) | d <- [Plp True 8000, Plp False 8000, Plp False 7], n <- [0, 100, streamWholeLimit]] $ \(d, n) -> do
      let bytes = rowBytes d (Just (value n))
      decodedAt (TIBigVarBinary 0xFFFF) (singleField folding) (someCuts bytes) bytes
        >>= (`shouldSatisfy` all (== Left (value n)))
    forM_ [Plp True 8000, Plp False 8000, Plp False 7] $ \d -> do
      let v = value (streamWholeLimit + 1)
          bytes = rowBytes d (Just v)
      decodedAt (TIBigVarBinary 0xFFFF) (singleField folding) (someCuts bytes) bytes
        >>= (`shouldSatisfy` all (either (const False) ((== v) . snd)))
    decodedAt (TIBigVarBinary 8000) (singleField folding) Nothing (rowBytes Short (Just (value 100)))
      >>= (`shouldSatisfy` all (== Left (value 100)))

  it "decodes a FoldingCell's NULL through nullableField, and refines both ways of reading" $ do
    decodedAt (TIBigVarBinary 0xFFFF) (singleField (nullableField folding)) Nothing (rowBytes (Plp True 7) Nothing)
      >>= (`shouldSatisfy` all (== Nothing))
    let sized = refineField (Right . either B.length (B.length . snd)) folding
    forM_ [100, streamWholeLimit + 1] $ \n -> do
      let bytes = rowBytes (Plp False 8000) (Just (value n))
      decodedAt (TIBigVarBinary 0xFFFF) (singleField sized) (someCuts bytes) bytes >>= (`shouldSatisfy` all (== n))

  it "decodes a long text with fieldDecoder whole up to the limit and a chunk at a time past it, to the same text" $ do
    let utf8 = Collation 0x04E00409 0
        cp1252 = Collation 0x00D00409 0x34
    codec <- either (fail . show) pure (collationCodec utf8)
    latin <- either (fail . show) pure (collationCodec cp1252)
    let cases =
          [ (TINVarChar 0xFFFF cp1252, Utf16.decodeUtf16LE, TE.encodeUtf16LE (T.replicate 11000 "a\128512\28450b") <> B.pack [0x3D, 0xD8, 0x41, 0x00])
          , (TIBigVarChar 0xFFFF cp1252, decodeCodec latin, B.pack (take 70000 (cycle [0x41, 0xE9, 0x80, 0x9F, 0x20])))
          , (TIBigVarChar 0xFFFF utf8, decodeCodec codec, B.concat (replicate 7000 (B.pack [0x61, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0xED, 0xA0, 0x80, 0xC3, 0xFF, 0xE2, 0x82])))
          ]
    forM_ cases $ \(ti, whole, bytes) -> forM_ [B.take 100 bytes, B.take streamWholeLimit bytes, bytes] $ \v ->
      forM_ [Plp True 7, Plp False 8000, Plp False 4096] $ \d -> do
        let row = rowBytes d (Just v)
        decodedAt ti (fieldRowDecoder @Text) (someCuts row) row >>= (`shouldSatisfy` all (== whole v))
        decodedAt ti (fieldRowDecoder @LT.Text) (someCuts row) row >>= (`shouldSatisfy` all ((== whole v) . LT.toStrict))

  it "decodes NULL without running a nullable consumer" $ do
    ran <- newIORef False
    let decoder = singleField (nullableField (streamField (\_ -> writeIORef ran True)))
    forM_ [(Plp True 7, TIBigVarBinary 0xFFFF), (Short, TIBigVarBinary 8000)] $ \(d, ti) ->
      decodedAt ti decoder Nothing (rowBytes d Nothing) >>= (`shouldSatisfy` all (== Nothing))
    readIORef ran `shouldReturn` False
