{-# LANGUAGE MagicHash #-}
-- | How a value is delimited on the wire, apart from packets and from what is
-- done with the value.  A value is read in two steps: 'cellHead' reads its
-- delimiter, and the caller then says what it wants of the payload, which is
-- all of it ('wholeValueBytes'), its pieces as they arrive ('valueStream') or
-- nothing ('skipValue').
module Hmssql.Tds.Value
  ( Row, rowColumnCount, rowCell, rowCellLength
  , rowValues, rowFromValues
  , ColumnShape (..), Cell (..), cellLength, rowShape, valueShape, cellHead
  , valueStream, boundedValue, WholeValue (..), wholeValueBytes, ownedValue, skipValue, foldValue, rowBitmap, columnNull, cellAt, skipCells
  ) where

import Streaming (Stream, Of (..))
import qualified Streaming as S
import qualified Streaming.Prelude as S
import Data.Primitive.SmallArray
import Data.Bits (testBit)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Word (Word64)
import Hmssql.Internal.Derived
import Hmssql.Tds.Parser (Parser)
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.TypeInfo (RawBytes, TypeInfo, LengthKind (..), lengthKind)

-- | How a column's values are delimited, chosen once from its metadata.  A
-- value with no delimiter of its own (a fixed width, or no value at all) keeps
-- its 'Cell' here, so that every row shares it.
data ColumnShape = ConstantCell !Cell | ByteLength | ShortLength | LongLength | TextPointer | Variant | PlpValue
  deriving stock (Eq)

instance Show ColumnShape where
  showsPrec p = \case
    ConstantCell a -> showCon1 p "ConstantCell"# a
    ByteLength -> showString "ByteLength"
    ShortLength -> showString "ShortLength"
    LongLength -> showString "LongLength"
    TextPointer -> showString "TextPointer"
    Variant -> showString "Variant"
    PlpValue -> showString "PlpValue"
  {-# OPAQUE showsPrec #-}

-- | What a value's delimiter said: NULL, a known length, or a PLP value whose
-- total length may or may not be known.  The payload still follows.
data Cell = NullCell | Sized !Int | Unsized !(Maybe Word64)
  deriving stock (Eq)

instance Show Cell where
  showsPrec p = \case
    NullCell -> showString "NullCell"
    Sized a -> showCon1 p "Sized"# a
    Unsized a -> showCon1 p "Unsized"# a
  {-# OPAQUE showsPrec #-}

-- | How a RETURNVALUE's value is delimited: as a column's, except that a legacy
-- @text@, @ntext@ or @image@ value has no text pointer in front of it.
valueShape :: TypeInfo -> ColumnShape
valueShape ti = case lengthKind ti of
  Fixed n -> ConstantCell (Sized n)
  ByteLen -> ByteLength
  UShortCharBin -> ShortLength
  LongLen -> LongLength
  VariantLen -> Variant
  Plp -> PlpValue
  NoValue -> ConstantCell NullCell

-- | How a column's value is delimited in a ROW: as 'valueShape' says, with a
-- text pointer and timestamp in front of a legacy @text@, @ntext@ or @image@
-- value.
rowShape :: TypeInfo -> ColumnShape
rowShape ti = case valueShape ti of
  LongLength -> TextPointer
  s -> s

-- | Read a value's delimiter.  Each form has its own way to say NULL.
cellHead :: ColumnShape -> Parser Cell
-- The argument is on the left so that the INLINE pragma fires only where
-- 'cellHead' is applied, and @noinline cellHead@ calls the compiled copy.
cellHead shape = case shape of
  ConstantCell cell -> pure cell
  ByteLength -> size 0 <$> P.word8
  ShortLength -> size 0xFFFF <$> P.word16le
  LongLength -> size 0xFFFFFFFF <$> P.word32le
  Variant -> (\n -> if n == 0 then NullCell else size 0xFFFFFFFF n) <$> P.word32le
  TextPointer -> P.word8 >>= \case
    0 -> pure NullCell
    n -> P.skip (fromIntegral n + 8) >> (size 0xFFFFFFFF <$> P.word32le)
  PlpValue -> P.word64le >>= \case
    0xFFFFFFFFFFFFFFFF -> pure NullCell
    0xFFFFFFFFFFFFFFFE -> pure (Unsized Nothing)
    n -> pure (Unsized (Just n))
  where size null n = if n == null then NullCell else Sized (fromIntegral n)
{-# INLINE cellHead #-}

-- | The value's declared length, if it has one that fits an 'Int64'.
cellLength :: Cell -> Maybe Int64
cellLength (Sized n) = Just (fromIntegral n)
cellLength (Unsized (Just n)) | n <= fromIntegral (maxBound :: Int64) = Just (fromIntegral n)
cellLength _ = Nothing

-- | Fold over the pieces of a value's payload: one piece for a sized value,
-- or a PLP value's chunks, with the chunk headers read here.  The step must
-- consume exactly the length it is given, whether it reads, collects or skips.
foldValue :: (a -> Int -> Parser a) -> a -> Cell -> Parser a
foldValue use initial = \case
  NullCell -> pure initial
  Sized n -> use initial n
  Unsized _ -> go initial
  where
    go a = plpChunkLength >>= \n -> if n == 0 then pure a else use a n >>= go
{-# INLINE foldValue #-}

-- | A PLP chunk's length header.
plpChunkLength :: Parser Int
plpChunkLength = fromIntegral <$> P.word32le

-- The stream form of 'foldValue', for a consumer that pulls.  The two stay
-- separate: skipping through a Stream would allocate one per skipped cell, and
-- a drain that skips asks for nothing, where assembling a 16 MiB value only to
-- drop it cost 44 MB.
segments :: Cell -> Stream (Of Int) Parser ()
segments = \case
  NullCell -> pure ()
  Sized n -> S.yield n
  Unsized _ -> plpChunks

-- A PLP value's chunk lengths from here to its terminator.
plpChunks :: Stream (Of Int) Parser ()
plpChunks = S.effect $ do
  n <- plpChunkLength
  pure (if n == 0 then pure () else S.yield n >> plpChunks)

-- | The value's payload as it arrives, in pieces.  A PLP value's chunk headers
-- are read here and never appear in the stream.
valueStream :: Cell -> Stream (Of B.ByteString) Parser ()
valueStream cell = S.for (segments cell) pieces

-- The next this many bytes of a value, in pieces as they arrive.
pieces :: Int -> Stream (Of B.ByteString) Parser ()
pieces 0 = pure ()
pieces n = S.effect $ do
  bs <- P.chunk n
  pure (S.yield bs >> pieces (n - B.length bs))

-- | A value for a consumer: read whole ('Right') if it is at most this many bytes,
-- given the allocation bound of 'wholeValueBytes' and the limit, or else its payload
-- as it arrives ('Left', as 'valueStream').  A PLP value whose total isn't known
-- (@xml@, and @json@) is read a chunk at a time until it ends within the limit;
-- once a chunk would take it past, the stream starts with the chunks already read,
-- so at most the limit is ever held.  A whole value is 'Owned' unless it lay in one
-- payload, and a drain that takes over while it is read gives 'DiscardedValue'.
boundedValue :: Int -> Int -> Cell -> Parser (Either (Stream (Of B.ByteString) Parser ()) WholeValue)
boundedValue ahead limit cell = case cell of
  Unsized Nothing -> gatheredPlpValue ahead limit
  _ | within -> Right <$> wholeValueBytes ahead cell
    | otherwise -> pure (Left (valueStream cell))
  where
    within = case cell of
      Sized n -> n <= limit
      Unsized (Just total) -> total <= fromIntegral limit
      _ -> True
{-# NOINLINE boundedValue #-}

-- 'boundedValue' of a PLP value whose total isn't known.
gatheredPlpValue :: Int -> Int -> Parser (Either (Stream (Of B.ByteString) Parser ()) WholeValue)
gatheredPlpValue ahead limit = gather [] 0
  where
    -- The chunks are read into bytes of their own, with no drain's discarding, which
    -- the limit makes cheap: a value read whole during a drain is never converted.
    gather held size = plpChunkLength >>= \n ->
      if n == 0 then pure (Right (PresentValue (P.Owned (B.concat (reverse held)))))
      else if size + n > limit then pure (Left (S.each (reverse held) >> pieces n >> S.for plpChunks pieces))
      else P.ownedBytes ahead n >>= \bytes -> gather (bytes : held) (size + n)
{-# NOINLINE gatheredPlpValue #-}

-- | Pass over a value's payload.
skipValue :: Cell -> Parser ()
skipValue cell = foldValue (\() -> P.skip) () cell
{-# INLINE skipValue #-}

-- | A value read whole: NULL, present, or discarded because a drain took over
-- the response while the value was being assembled.
data WholeValue = NullValue | PresentValue !P.ValueBytes | DiscardedValue

-- | Read all of a value into bytes of its own, as an output parameter's value
-- is kept.  A value discarded by a drain comes back as empty bytes, which only
-- the drain sees.
ownedValue :: Int -> Cell -> Parser RawBytes
ownedValue ahead cell = wholeValueBytes ahead cell >>= \case
  NullValue -> pure Nothing
  PresentValue value -> pure (Just (P.keepBytes value))
  DiscardedValue -> pure (Just B.empty)

-- | Read all of a value: a slice if it lies in the buffer, otherwise one buffer of
-- its own.
wholeValueBytes :: Int -> Cell -> Parser WholeValue
wholeValueBytes ahead = \case
  NullCell -> pure NullValue
  Sized n -> maybe DiscardedValue PresentValue <$> P.bytesValue ahead n
  Unsized total -> wholePlpValue ahead total
{-# INLINE wholeValueBytes #-}

-- Ownership while collecting a PLP value. A drain releases any saved bytes.
data Gathered = NothingYet | OneSlice !B.ByteString | Growing !P.Accumulator | Dropped

-- One payload fragment stays borrowed, even if its closing delimiter arrives
-- later. From the second fragment onward, use the bounded accumulator.
wholePlpValue :: Int -> Maybe Word64 -> Parser WholeValue
wholePlpValue ahead total = do
  accumulated <- foldValue pieces NothingYet (Unsized total)
  case accumulated of
    NothingYet -> pure (PresentValue (P.Borrowed B.empty))
    OneSlice bytes -> pure (PresentValue (P.Borrowed bytes))
    Growing acc -> PresentValue . P.Owned <$> P.effect (P.finish acc)
    Dropped -> pure DiscardedValue
  where
    pieces gathered 0 = pure gathered
    pieces Dropped n = P.skip n >> pure Dropped
    pieces NothingYet n = fragment n (pure . OneSlice)
    pieces (OneSlice first) n = fragment n $ \bytes -> Growing <$> P.effect (do
      acc <- P.append ahead (P.accumulator total) first
      P.append ahead acc bytes)
    pieces (Growing acc) n = fragment n $ \bytes -> Growing <$> P.effect (P.append ahead acc bytes)
    fragment n add = P.chunkOrDiscard n >>= \case
      Nothing -> P.skip n >> pure Dropped
      Just bytes -> add bytes >>= \next -> pieces next (n - B.length bytes)
{-# NOINLINE wholePlpValue #-}

-- | A row's token byte, and an NBCROW's null bitmap. Empty means a ROW, where each
-- delimiter says for itself whether its value is NULL.
rowBitmap :: Int -> Parser B.ByteString
rowBitmap n = P.word8 >>= \case
  0xD1 -> pure B.empty
  0xD2 -> P.boundedBytes ((n + 7) `div` 8)
  _ -> fail "expected ROW or NBCROW"
{-# INLINE rowBitmap #-}

-- | Whether the bitmap marks this column NULL, in which case it has no bytes at all.
columnNull :: B.ByteString -> Int -> Bool
columnNull bitmap i = not (B.null bitmap) && testBit (B.index bitmap (i `div` 8)) (i `mod` 8)
{-# INLINE columnNull #-}

-- | Read one column's delimiter, including its NBCROW null bit.
cellAt :: B.ByteString -> Int -> ColumnShape -> Parser Cell
cellAt bitmap i shape = if columnNull bitmap i then pure NullCell else cellHead shape
{-# INLINE cellAt #-}

-- | Read past these columns of a row, given as their indexes and shapes.
skipCells :: B.ByteString -> [(Int, ColumnShape)] -> Parser ()
-- A recursion under 'P.oneShotRecipe' rather than 'mapM_': each tail's recipe is
-- built after the cell before it is skipped and run once, so GHC passes the input
-- through the recursive call instead of allocating a closure per cell.  Draining
-- 100 responses of 10,000 @int@ and @bigint@ rows allocated 559 MB this way and
-- 815 MB with 'mapM_' (GHC 9.12.4, 2026-11-04).  A probe that skipped fixed-width
-- cells alone went the other way, from 27.8 to 32.0 MB, and the drain is the path
-- that matters.
skipCells bitmap = go
  where
    go [] = pure ()
    go ((i, shape) : later) = P.oneShotRecipe $ do
      cell <- cellAt bitmap i shape
      skipValue cell
      go later

-- | A row's values, each read whole into bytes of its own, for the token-level
-- interface ('Hmssql.Tds.Token.TRow').  A typed row decoder never builds one.
newtype Row = Row (SmallArray RawBytes)
  deriving stock (Eq)

instance Show Row where
  showsPrec d r = showParen (d > 10) $ showString "rowFromValues " . showsPrec 11 (rowValues r)

-- | How many columns the row has.
rowColumnCount :: Row -> Int
rowColumnCount (Row cells) = sizeofSmallArray cells

-- | A row from its values.
rowFromValues :: [RawBytes] -> Row
rowFromValues = Row . smallArrayFromList

-- | The value at a column, counted from 0; 'error' past the last.
rowCell :: Row -> Int -> RawBytes
rowCell (Row cells) i
  | i >= 0 && i < sizeofSmallArray cells = indexSmallArray cells i
  | otherwise = error ("column " ++ show i ++ " of a row of " ++ show (sizeofSmallArray cells) ++ " columns")

-- | The length of the value at a column, or -1 for NULL.
rowCellLength :: Row -> Int -> Int
rowCellLength row i = maybe (-1) B.length (rowCell row i)

-- | The row's values, in column order.
rowValues :: Row -> [RawBytes]
rowValues row = [rowCell row i | i <- [0 .. rowColumnCount row - 1]]
