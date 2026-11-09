{-# LANGUAGE ExistentialQuantification, GADTs, InstanceSigs, MagicHash #-}
-- | Turning the columns of a result set into Haskell values.
--
-- 'FromSqlField' decodes one column, with instances for the usual types
-- ("Hmssql.Types" has the table of which SQL types each accepts);
-- 'FromSqlRow' decodes a row, derived for a record or given for a tuple.
-- A new field decoder is usually 'refineField' over an existing one (an
-- enumeration from a @varchar@, a JSON column), or 'fieldDecoderFor' from
-- the value's bytes.
--
-- A 'FieldDecoder' checks its column's 'ColumnInfo' once per result set,
-- rejecting an incompatible SQL type before any row is read.  It then reads
-- each value whole, or gives it to a consumer as it arrives ('streamField').
-- 'RowDecoder' composes field decoders applicatively and knows how many
-- columns it consumes, so a whole result set is type-checked before the
-- first row is decoded.  'RowDecoderMonadic' is a monadic variant for shapes
-- only known at runtime.
module Hmssql.Decoding
  ( -- * Field decoders
    FromSqlField (fieldDecoder, fieldRowDecoder)
  , FieldDecoder (..)
  , fieldDecoderFor
  , fieldDecoderForTypes
  , refineField
  , nullableField
  , RawValue (..)

    -- * Field decoders from a value's parts #parts#
    -- | The date and time types decode to the @time@ package's types, and @decimal@
    -- to 'Decimal', which are built from 'Integer's.  For code that writes a value
    -- straight out, as JSON or text, or keeps it in a type of its own, these decoders
    -- give your function the value's parts instead: a date's 'Day', its picoseconds
    -- since midnight and its offset in minutes, or a decimal's sign, magnitude and
    -- scale.  A value is checked as the built-in decoders check it, and a NULL
    -- is a 'DecodeError' unless the decoder is wrapped in 'nullableField'.
    --
    -- > -- the minutes since midnight of a datetime2 or datetime column
    -- > minuteOfDay :: FieldDecoder Int
    -- > minuteOfDay = dayTimeFieldDecoder "minute of day" $ \_ ps ->
    -- >   fromIntegral (ps `quot` 60_000_000_000_000)
  , dayTimeFieldDecoder
  , dateTimeOffsetFieldDecoder
  , timeFieldDecoder
  , decimalFieldDecoder

    -- * Streaming a large value #streaming#
    -- | A decoder normally reads a whole value into memory.  'streamField' instead
    -- gives each value to your function as it arrives, so a column of any size can go
    -- to a file or a socket without being held in memory:
    --
    -- > import qualified Data.ByteString as B
    -- > import qualified Streaming.Prelude as S
    -- > import System.IO (IOMode (..), withBinaryFile)
    -- >
    -- > saveDocument :: Connection -> Int -> FilePath -> IO ()
    -- > saveDocument conn docId path =
    -- >   query1With (singleField (streamField toFile)) conn
    -- >     ("SELECT payload FROM dbo.documents WHERE id = " <> param docId)
    -- >   where
    -- >     toFile value = withBinaryFile path WriteMode $ \h ->
    -- >       S.mapM_ (B.hPut h) (valueChunks value)
    --
    -- 'streamTextField' does the same for character data, with the chunks decoded to
    -- 'Text'.  Either one composes with other columns like any field decoder:
    --
    -- > (,) <$> singleField (fieldDecoder @Int) <*> singleField (streamField toFile)
    --
    -- Your function runs once per row, on the thread reading the rows, and these rules
    -- come with it:
    --
    -- * A value of at most 'streamWholeLimit' (64 KiB) is read whole first, and your
    --   function gets it as one chunk; only a larger one arrives in pieces.  Given a
    --   value whole, your function may run before rows read ahead of it reach you.
    -- * Bytes it doesn't read are skipped, so it can stop early.
    -- * An exception it throws ends the query: the statement is canceled, and the
    --   exception reaches the caller as it was thrown, with the connection still
    --   usable.  To report a bad value as a 'DecodeError' instead, return an
    --   @Either String@ and wrap the decoder in @'refineField' id@.
    -- * The stream is valid only until the function returns.
    -- * A NULL is a 'DecodeError' unless the decoder is wrapped in 'nullableField'.
    -- * It must not make a request on its own connection.  On a MARS connection it may
    --   make requests beside the stream.
    -- * The connection is locked while it runs, and the statement may be holding locks
    --   on the server, so slow work there holds up other work.
    --
    -- When one column's value decides what to do with a later one, such as a name for
    -- the file, use cells instead ("Hmssql.Query#g:cells").  Whole rows can be streamed
    -- with "Hmssql.Query#g:streaming", and large parameters can be sent as they are read
    -- with "Hmssql.Encoding#g:streaming".
  , ValueStream (..), streamField, streamTextField

    -- * Row decoders
  , FromSqlRow (..)
  , RowDecoder (..)
  , singleField
  , inlinedField
  , inlinedNullableField
  , byColumn
  , genericFromSqlRow

    -- * Monadic row decoders
  , RowDecoderMonadic (..)
  , singleFieldM
  , remainingColumns
  , toMonadicRowDecoder
  , sqlRowDecoder

    -- * Values known only at runtime
  , sqlValueDecoder
  , sqlRowDecoderFor

    -- * Running decoders
    -- | What a field decoder compiles to, and how a row decoder is run: for code
    -- that reads a response itself (the low-level part of "Hmssql.Query") or
    -- decodes values it already holds.  Nothing here is needed to use the query
    -- functions.
  , compileField
  , CellDecoder (..)
  , StreamedValue (..)
  , streamWholeLimit
  , ReadFailure (..)
  , decodeCell
  , fieldDecoderCompiled
  , readCellRecipe
  , compileRowDecoder
  , compileRowDecoderFor
  , compileMonadicRowDecoder
  , skipRowDecoder
  , CompiledRow (..)
  , Prepared (..)
  , rowRecipe
  , decodeColumnChunks
  , decodeColumnText
  ) where

import Control.Monad (when)
import Streaming (Stream, Of)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Coerce (Coercible, coerce)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int16, Int32, Int64, Int8)
import GHC.Exts (Int64#)
import GHC.Int (Int64 (I64#))
import Data.Primitive.SmallArray (indexSmallArray)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Time
import Data.Tuple.Only (Only (..))
import Data.UUID.Types (UUID)
import Data.Word (Word64, Word8)
import GHC.Generics

import Hmssql.Errors (DecodeError (..))
import Hmssql.SqlValue
import Hmssql.Internal.SqlDataType (SqlDataType (..))
import Hmssql.Tds.Scalar
import Hmssql.Tds.CodePage (decodeCodecChunks)
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.Value
import Hmssql.Tds.Token (ColumnInfo (..), ResultSetInfo, compileResultSet, rsColumnArray, rsColumnCount, rsColumns, rsCells)
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

import Hmssql.Tds.Parser (Parser)
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Reader (CompiledRow (..), Prepared (..), ReadFailure (..), rowRecipe)

-- | How to decode one column.  Given the connection's context and the column, it
-- returns a 'CellDecoder' for the column's values, or why it can't decode them.
--
-- The check runs when a result set's columns arrive, before its first row, so
-- a type mismatch is reported even for an empty result.
newtype FieldDecoder a = FieldDecoder
  (TdsContext -> ColumnInfo -> Either String (CellDecoder a))

-- | How to decode a column's values, once the column has been checked.  There
-- are two ways, because nearly every value is small and a few are too large to
-- hold in memory; the ordinary way is much the cheaper, since it runs no 'IO'
-- and needs no stream or exception handler per value.
data CellDecoder a
  -- Why two conversions: most values lie within one packet and are read as a
  -- slice of it, so a conversion that keeps those bytes must copy them, or the
  -- value would keep the whole packet alive.  A value that crossed packets was
  -- assembled into a buffer of its own, and copying that again would double the
  -- work on the largest values.  Conversions that keep nothing (integers, text
  -- decoded to a new array) use one function for both.
  --
  -- Why a closure per column, rather than a selection and a reader that inline
  -- into one function per row: that was tried (value-streaming-research.md,
  -- "Full-suite comparison").  Once a row inlined, each bind's continuation was
  -- used in the completed branch and captured in the suspended one, so Core made
  -- it a heap closure per bind, 1.2 to 1.8 times this allocation.  One unknown
  -- call per cell is the cheaper price for a parser that can suspend.
  = CellDecoder (Either String a) (ValueReader a) (ValueReader a)
    -- ^ The ordinary way: the whole value is read, and then converted by a pure
    -- function.  The fields are the result for a NULL, which stays lazy until a NULL
    -- is decoded, and two conversions.  The first takes bytes borrowed from a receive
    -- buffer, and the second takes bytes in a buffer of their own.
    --
    -- Nothing ever overwrites borrowed bytes, so a conversion that keeps them still
    -- gets correct data.  The danger is memory: they hold the whole receive buffer of
    -- up to 32 KiB, so keeping small values from many rows could keep far more memory
    -- than those values need.  So the first conversion should copy any bytes it keeps.
    -- The second can keep them as they are, and a conversion that keeps none, such as
    -- an integer's, can use the same function for both.
  | FoldingCell (Either String a) (ValueReader a) (ValueReader a)
      (Stream (Of B.ByteString) Parser () -> Parser (Either ReadFailure a))
    -- ^ A value of any length, converted with no consumer: one of at most
    -- 'streamWholeLimit' bytes read whole and converted by the first three fields,
    -- as 'CellDecoder''s are, and a longer one given as it arrives to the fourth, a
    -- recipe that follows 'StreamingCell''s two rules below.  Its pieces may be slices
    -- of a receive buffer, so it copies what it keeps.  This is for a conversion
    -- that can work a piece at a time, such as writing text out as JSON, so that a
    -- long value is never held whole as it came, while a short one costs what a
    -- 'CellDecoder' costs.
  | StreamingCell (StreamedValue -> Parser (Either ReadFailure a))
    -- ^ The way to read a value as it arrives.  'streamField' and 'streamTextField'
    -- build this; see "Hmssql.Decoding#g:streaming".  Writing one by hand has two rules:
    --
    -- * The recipe must read its value to the end, even when it fails, because the
    --   next column's bytes come straight after it.
    -- * A value that can't be decoded must be a 'DecodeFailed'.  The rest of the row
    --   is then read past, the response is drained, and the 'DecodeError' is thrown
    --   from the query, with the connection still usable.  When 'P.consume' gives
    --   'Nothing', the response is being thrown away, and the result is 'ReadDiscarded'.
    --
    -- A failure is returned because a thrown one would end the recipe, and with it the
    -- reading of the row.  So a recipe throws, as 'fail' does, only when the bytes
    -- can't be read at all, and the connection is then broken.  A consumer's exception
    -- is neither: it ends the query at once, as described at "Hmssql.Decoding#g:streaming".

-- | A value as a 'StreamingCell' receives it: NULL, the whole value, or its total
-- length if known and a stream of its bytes.  A value of at most 'streamWholeLimit'
-- bytes is read whole first, since giving it to the consumer as it arrives costs
-- several times what reading it does; a larger one is streamed.
data StreamedValue
  = StreamedNull
  | StreamedWhole !P.ValueBytes
    -- ^ The value, read whole.  As for 'CellDecoder''s conversions, 'P.Borrowed'
    -- bytes are a slice of a receive buffer, so a recipe that keeps them copies
    -- them ('P.keepBytes').
  | StreamedBytes !(Maybe Int64) (Stream (Of B.ByteString) Parser ())

-- | The largest value a 'StreamingCell' is given whole, 64 KiB.  Up to this size a
-- value read whole and handed over costs about what 'fieldDecoder' does, where
-- streaming it cost seven times as much for a value of 100 bytes; past it, the
-- stream's cost per value is small beside the value's own bytes, and what is held
-- at once stays bounded.
streamWholeLimit :: Int
streamWholeLimit = 64 * 1024

instance Functor CellDecoder where
  fmap f (CellDecoder onNull borrowed owned) =
    CellDecoder (fmap f onNull) (fmap f . borrowed) (fmap f . owned)
  fmap f (FoldingCell onNull borrowed owned fold) =
    FoldingCell (fmap f onNull) (fmap f . borrowed) (fmap f . owned) (fmap (fmap f) . fold)
  fmap f (StreamingCell d) = StreamingCell (fmap (fmap f) . d)

instance Functor FieldDecoder where
  fmap = mapField
  {-# INLINE fmap #-}

-- Out of line: the comment at 'nullableField'.
mapField :: (a -> b) -> FieldDecoder a -> FieldDecoder b
mapField f (FieldDecoder compile) = FieldDecoder $ \ctx col -> fmap (fmap f) (compile ctx col)
{-# OPAQUE mapField #-}

-- | Run a 'FieldDecoder' against a column: the 'CellDecoder' for its values, or
-- why it can't decode them.
compileField :: FieldDecoder a -> TdsContext -> ColumnInfo -> Either String (CellDecoder a)
compileField (FieldDecoder compile) = compile
{-# INLINE compileField #-}

-- | A decoder from a function that checks the column and chooses how to decode
-- its values.  For a decoder 'fieldDecoderFor' can't express.
fieldDecoderCompiled :: (TdsContext -> ColumnInfo -> Either String (CellDecoder a)) -> FieldDecoder a
fieldDecoderCompiled = FieldDecoder
{-# INLINE fieldDecoderCompiled #-}

-- | Decode a value already in memory ('Nothing' is NULL).  A 'StreamingCell' gives
-- a 'Left', because it reads its value as the value arrives.
decodeCell :: CellDecoder a -> RawBytes -> Either String a
decodeCell (CellDecoder onNull _ owned) = maybe onNull owned
decodeCell (FoldingCell onNull _ owned _) = maybe onNull owned
decodeCell (StreamingCell _) = const (Left "a streaming field requires a live value stream")

-- The value is forced before it is returned: as a thunk it would hold the bytes
-- it reads, and through a borrowed slice, the packet they arrived in.
cellDecoder :: Either String a -> ValueReader a -> CellDecoder a
cellDecoder onNull decode = CellDecoder onNull converted converted
  where converted bytes = decode bytes >>= evaluated
{-# INLINE cellDecoder #-}

instance Semigroup (FieldDecoder a) where
  FieldDecoder f <> FieldDecoder g = FieldDecoder $ \ctx col -> case f ctx col of
    Right d -> Right d
    Left e1 -> case g ctx col of
      Right d -> Right d
      Left e2 -> Left (e1 ++ "; " ++ e2)
  {-# INLINE (<>) #-}

-- | Types that decode from one column.  The usual Haskell types have
-- instances, and "Hmssql.Types" has the table of which SQL types each
-- accepts.  'Maybe' accepts NULL; without it, a NULL is a 'DecodeError'.
-- An instance of your own defines 'fieldDecoder', usually with
-- 'refineField' over a built-in type's decoder.
class FromSqlField a where
  -- | The decoder of one column of this type.
  fieldDecoder :: FieldDecoder a

  -- | A row decoder of one column of this type, the same as @'singleField'
  -- 'fieldDecoder'@.  Tuples, 'Only' and derived 'FromSqlRow' instances read their
  -- columns with it, and the built-in types' are faster than 'singleField'.  An
  -- instance doesn't define it.
  fieldRowDecoder :: RowDecoder a
  fieldRowDecoder = RowDecoder (\ctx rs i -> compileRowAt (rowDecoderWith NoNulls) ctx rs i) 1

  -- The rest are not exported.  'fieldRowDecoder' of 'Maybe' this type, which the
  -- 'Maybe' instance's 'fieldRowDecoder' is.
  nullableRowDecoder :: RowDecoder (Maybe a)
  nullableRowDecoder = RowDecoder (\ctx rs i -> compileRowAt (rowDecoderWith Nulls) ctx rs i) 1

  -- Both row decoders, which a built-in instance compiles as one
  -- ('cellRowDecoder').
  rowDecoderWith :: Nulls a b -> RowDecoder b
  rowDecoderWith nulls = singleField (nullsField nulls fieldDecoder)

-- A built-in type's row decoders are compiled once, here, as one function for the
-- type and 'Maybe' the type ('rowDecoderWith', which takes a 'Nulls'), with the
-- conversion inlined at one place ('cellRowDecoder', 'P.prefixedRowValue'): a value that
-- lies in the payload behind a fixed width or a one- or two-byte length.  The
-- conversion is then a known call given the slice's fields, or inlined, rather than an
-- unknown call given a 'B.ByteString' built for it that returns an 'Either'.  A field
-- of a tuple or a derived record refers to its type's row decoder and holds no code of
-- its own for the cell.
--
-- Measured against 'singleField' out of line (64799fb), on 2026-11-04 with GHC 9.12.4,
-- in bytes allocated per query: a typed @(Int32, Int64)@ row in Mock.query 2,864,247
-- rather than 3,661,904 (0.78), the nullable five-column row 7,943,905 rather than
-- 9,566,082 (0.83), and their derived-record forms 0.80 and 0.84.  In Decode, per
-- 10,000 rows: @nvarchar(50)@ 0.93, @decimal(18,4)@ 0.96, @datetime2@ with
-- @datetimeoffset@ 0.97, @uniqueidentifier@ 0.89.  A @max@ value goes through the
-- shared path and allocates as before.  The full program of scripts/code-size.sh has
-- 79,088 bytes of FromRows object code (67 per field) rather than 111,304, and
-- Decoding.o is 511 KB rather than 325 KB.  Timed roughly, three alternating pairs
-- on an idle machine, the typed cases took 0.92 of the time in Decode and 0.87 in
-- Mock.query (geometric means), from 0.78 for @(Int32, Int64)@ to 1.02 for a short
-- @nvarchar(max)@.
--
-- Why one place.  With the whole cell's read inlined into each type's two row
-- decoders, Decoding.o was 1.23 MB, and the allocation 0.83 and 0.91 of the above.
-- Each step that made the copies small, in Decoding.o's .text:
--
-- * Only the common delimiters inlined, each with the conversion, and the rest
--   through an out-of-line read: 771 KB.
-- * One copy for both row decoders, through 'Nulls': 670 KB.  Each instance's
--   'rowDecoderWith' is NOINLINE, or GHC inlines it into the two methods that apply it
--   to a constructor, and there are two copies again.
-- * The delimiter's fast path in one out-of-line function ('P.prefixedRowValue''s
--   @valueSpan@), which returns where the value lies, so the conversion has one call
--   site; and every slower case through 'sharedCell': 520 KB.  The slow path through
--   the inlined decoder instead kept a second copy of each conversion in its closures.
-- * The out-of-range and invalid-length messages out of line: 503 KB.  The integer
--   types' copies are still the largest, about 5.4 KB each with 'integerAt'.
-- * 'fieldRowDecoder' as a constructor, below: 511 KB with the methods' wrappers.
--
-- The large conversions, of the date and time types, 'Decimal' and 'Money', are out of
-- line and called from the copy ('localTimeReader' and the others): a second copy of
-- one each would be a large share of the copy, for a few per cent of what the
-- conversion allocates anyway.
--
-- Why 'fieldRowDecoder' is a constructor around a call rather than @rowDecoderWith
-- NoNulls@.  That was a thunk, which a field of a derived record evaluated in its own
-- code, 92 bytes per field rather than 67.  A constructor of a known function is an
-- unfolding GHC sees through, so a field refers to the function.
--
-- Why each built-in type's decoder is a top-level INLINE definition beside its
-- instance.  'fieldDecoder' isn't INLINE, because a hand-written @singleField
-- fieldDecoder@ would copy the decoder into every use (2.8 KB per field of a
-- ten-field applicative decoder), and in the library GHC didn't inline it into
-- the row decoders by itself, nor through 'GHC.Exts.inline': the allocation stayed
-- at the out-of-line figure.  So the instance's 'fieldDecoder' is the INLINE
-- definition, compiled once as the method, and its 'rowDecoderWith' gives the
-- same definition to 'cellRowDecoder', where it inlines.  A rewrite of
-- @singleField fieldDecoder@ to 'fieldRowDecoder' never fires, because the
-- class-op rule rewrites 'fieldDecoder' first.
--
-- Why a type of the user's gets the shared 'singleField'.  GHC inlines a default
-- method into each instance (it shows as a Compulsory unfolding in the interface, on
-- 9.10.3 and 9.12.4), so a default of 'cellRowDecoder' would give each such type a
-- copy of the cell's read, for a decoder usually built with 'refineField' over a
-- built-in one, whose conversion is an unknown call anyway.  With 'singleField' a field
-- of the type costs what a built-in type's does.
--
-- INLINE or INLINABLE on a row decoder method undoes all this.  GHC copies either
-- from a default method to the instance's method, and the instance's method is then
-- a constructor application whose unfolding is the whole cell read; GHC looks through
-- a constructor application's unfolding at any size, so every field got the copy
-- again (the quick program was 3.5 MB rather than 0.53 MB, measured on 9fcfe0d).

-- | A decoder from a value's bytes, given a name for error messages, the wire
-- types it accepts and the conversion.  A NULL is a 'DecodeError' unless the
-- decoder is wrapped in 'nullableField'.  The bytes may be part of a receive
-- buffer, so a conversion should copy any it keeps, as 'CellDecoder' explains.
fieldDecoderFor :: String -> (TypeInfo -> Bool)
  -> (TdsContext -> TypeInfo -> B.ByteString -> Either String a) -> FieldDecoder a
fieldDecoderFor name accepts decode = compiledFieldDecoder name accepts
  (\ctx ti -> Right (ctx, ti)) (\(ctx, ti) bs -> decode ctx ti bs)
{-# INLINE fieldDecoderFor #-}

-- | 'fieldDecoderFor', accepting by SQL data type rather than by wire type.  The
-- conversion still receives the column's 'TypeInfo'.
fieldDecoderForTypes :: String -> (SqlDataType -> Bool)
  -> (TdsContext -> TypeInfo -> B.ByteString -> Either String a) -> FieldDecoder a
fieldDecoderForTypes name accepts = fieldDecoderFor name (hasDataType accepts)

compiledFieldDecoder :: String -> (TypeInfo -> Bool)
  -> (TdsContext -> TypeInfo -> Either String s) -> (s -> ValueReader a) -> FieldDecoder a
compiledFieldDecoder name accepts select reader = FieldDecoder $ \ctx col ->
  let ti = columnType col
   in if accepts ti
        then do
          selected <- select ctx ti
          pure (cellDecoder (nullAs name) (reader selected))
        else Left (rejectAs name ti)
{-# INLINE compiledFieldDecoder #-}

nullAs :: String -> Either String a
nullAs name = Left $ "SQL NULL cannot be decoded as " ++ name ++ "; use Maybe " ++ name

evaluated :: a -> Either String a
evaluated a = a `seq` Right a

bytesDecoder :: String -> (TypeInfo -> Bool) -> (B.ByteString -> a) -> FieldDecoder a
bytesDecoder name accepts mk = FieldDecoder $ \_ col ->
  let ti = columnType col
   in if accepts ti
        then Right $ CellDecoder (nullAs name)
          (\bytes -> Right $! mk (B.copy bytes)) (\bytes -> Right $! mk bytes)
        else Left (rejectAs name ti)
{-# INLINE bytesDecoder #-}

-- | Decode NULL as 'Nothing', keeping the inner decoder's type check.  A streaming
-- consumer isn't called for a NULL.
nullableField :: FieldDecoder a -> FieldDecoder (Maybe a)
nullableField (FieldDecoder compile) = FieldDecoder $ \ctx col -> fmap nullableCell (compile ctx col)
-- Out of line, as 'refineField' and 'FieldDecoder''s 'fmap' are, so that a use is a
-- call, not a copy of the adapter: a use of @Maybe Int32@ in each module that names
-- the type, and a decoder an application composes where it is written.  The cell's
-- reading is the same closures either way.  In a module of 40 functions each calling
-- 'Hmssql.Query.queryWith' with one column so adapted, the code per function was 944
-- bytes with 'nullableField' INLINE, 3,240 with 'refineField' and 800 with 'fmap'.
{-# OPAQUE nullableField #-}

nullableCell :: CellDecoder a -> CellDecoder (Maybe a)
nullableCell (CellDecoder _ borrowed owned) =
  CellDecoder (Right Nothing) (fmap Just . borrowed) (fmap Just . owned)
nullableCell (FoldingCell _ borrowed owned fold) =
  FoldingCell (Right Nothing) (fmap Just . borrowed) (fmap Just . owned) (fmap (fmap Just) . fold)
nullableCell (StreamingCell d) = StreamingCell $ \case
  StreamedNull -> pure (Right Nothing)
  cell -> fmap (fmap Just) (d cell)
{-# INLINE nullableCell #-}

-- Which of a type's two row decoders: of the type, or of 'Maybe' the type.  A
-- built-in type compiles both as one function, which takes this.
data Nulls a b where
  NoNulls :: Nulls a a
  Nulls :: Nulls a (Maybe a)

nullsField :: Nulls a b -> FieldDecoder a -> FieldDecoder b
nullsField NoNulls = id
nullsField Nulls = nullableField
{-# INLINE nullsField #-}

nullsCell :: Nulls a b -> CellDecoder a -> CellDecoder b
nullsCell NoNulls = id
nullsCell Nulls = nullableCell
-- Out of line: it runs once per result set, and inlined, every built-in type's row
-- decoder held a copy of 'nullableCell'.
{-# NOINLINE nullsCell #-}

instance FromSqlField a => FromSqlField (Maybe a) where
  fieldDecoder = nullableField fieldDecoder
  fieldRowDecoder = nullableRowDecoder
  {-# INLINE fieldRowDecoder #-}

-- | Convert a decoded value further.  A 'Left' becomes a 'DecodeError' naming the
-- column.  The inner decoder's type check and NULL handling still apply.
--
-- > instance FromSqlField Status where
-- >   fieldDecoder = refineField parseStatus fieldDecoder
refineField :: (a -> Either String b) -> FieldDecoder a -> FieldDecoder b
refineField f (FieldDecoder compile) = FieldDecoder $ \ctx col -> do
  d <- compile ctx col
  let refined = either (Left . DecodeFailed . DecodeError (Just (columnName col))) Right . f
  pure $ case d of
    CellDecoder onNull borrowed owned -> CellDecoder (onNull >>= f)
      (\bytes -> borrowed bytes >>= f) (\bytes -> owned bytes >>= f)
    FoldingCell onNull borrowed owned fold -> FoldingCell (onNull >>= f)
      (\bytes -> borrowed bytes >>= f) (\bytes -> owned bytes >>= f)
      (\chunks -> (>>= refined) <$> fold chunks)
    StreamingCell read -> StreamingCell $ \cell -> do
      result <- read cell
      pure $ result >>= refined
-- Out of line: the comment at 'nullableField'.
{-# OPAQUE refineField #-}

-- | The bytes of any column's value as the server sends them, including the CLR
-- types hmssql doesn't otherwise decode.
newtype RawValue = RawValue B.ByteString deriving stock (Eq, Show)

-- The built-in types' decoders, each INLINE: the type's 'fieldDecoder',
-- compiled once as the method, and the decoder 'cellRowDecoder' inlines (the
-- comment at 'FromSqlField').
rawValueDecoder :: FieldDecoder RawValue
rawValueDecoder = bytesDecoder "RawValue" (const True) RawValue
{-# INLINE rawValueDecoder #-}

instance FromSqlField RawValue where
  fieldDecoder = rawValueDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder rawValueDecoder
  {-# NOINLINE rowDecoderWith #-}

-- | An integer type whose range is within the range of 'Int64'.
boundedInteger :: forall a. (Integral a, Bounded a) => String -> FieldDecoder a
boundedInteger name = compiledFieldDecoder name isIntegerType (\_ ti -> Right (unsignedByteType ti)) $ \unsigned bs ->
  case integerAt unsigned bs of
    Left e -> Left e
    Right (I64# i) -> inBounds name i
{-# INLINE boundedInteger #-}

-- The range check, given the integer unboxed.  GHC's last float-out pass makes the
-- check, a closed lambda once 'outOfRange' is out of line, a function of its own,
-- after the pass that gives a function a worker taking its arguments unboxed; given
-- an 'Int64', each @Int32@ cell read through 'fieldDecoder' allocated its box, 16
-- bytes, which for a hand-written @(Int32, Int64)@ decoder was 2,844,575 bytes per
-- query in Mock.query rather than 3,004,528.  Given an 'Int64#', the function takes
-- it unboxed.
inBounds :: forall a. (Integral a, Bounded a) => String -> Int64# -> Either String a
inBounds name i
  | I64# i < fromIntegral (minBound @a) || I64# i > fromIntegral (maxBound @a) = Left (outOfRange name (I64# i))
  | otherwise = Right (fromIntegral (I64# i))
{-# INLINE inBounds #-}

-- Out of line, so that a copy of a bounded integer's conversion doesn't hold the
-- message's 'show'.
outOfRange :: String -> Int64 -> String
outOfRange name i = "value " ++ show i ++ " is out of range for " ++ name
{-# NOINLINE outOfRange #-}

-- The conversions of the date and time types and of 'Decimal' and 'Money', compiled
-- once, out of line, for their field decoders and their row decoders.  Inlined into
-- the row decoders, each would be a second copy of a large conversion per type, which
-- allocates far more than the call costs.  A known call still takes the slice's
-- fields unboxed, though it returns an 'Either': GHC doesn't return a sum type
-- unboxed from a function that isn't a join point.  The bang keeps GHC from
-- eta-reducing a definition to the function it calls; it did, and then the INLINE
-- 'localTimeValue', unsaturated, wasn't inlined, and the call took a boxed slice.
decimalReader :: DecimalColumn -> ValueReader Decimal
decimalReader column !bs = case column of
  DecimalColumn precision scale -> readDecimal precision scale bs
  OtherDecimal ti -> decimalValue ti bs
{-# NOINLINE decimalReader #-}

-- What 'decimalReader' needs of a column's type, taken from it once per column, with
-- the precision and scale boxed there.  Given the 'TypeInfo', whose fields are
-- unpacked, the reader boxed both for each value, 32 bytes, as 'readDecimal' takes
-- them boxed: a hand-written decoder of the nullable NBCROW rows, half of whose
-- decimals are NULL, allocated 7,884,063 bytes per query in Mock.query rather than
-- 7,724,622.
data DecimalColumn = DecimalColumn Precision Scale | OtherDecimal TypeInfo

decimalColumn :: TypeInfo -> DecimalColumn
decimalColumn = \case
  TIDecimalN precision scale -> DecimalColumn precision scale
  TINumericN precision scale -> DecimalColumn precision scale
  ti -> OtherDecimal ti
moneyValue :: ValueReader Money
moneyValue !bs = readMoney bs
{-# NOINLINE moneyValue #-}
localTimeReader :: TypeInfo -> ValueReader LocalTime
localTimeReader ti !bs = localTimeValue ti bs
{-# NOINLINE localTimeReader #-}
utcTimeReader :: TypeInfo -> ValueReader UTCTime
utcTimeReader ti !bs = case ti of
  TIDateTimeOffsetN s -> dtoUtcTime <$> readDateTimeOffset s bs
  _ -> dayTimeValue utcTimeOf ti bs
{-# NOINLINE utcTimeReader #-}
dayValue :: ValueReader Day
dayValue !bs = readDate bs
{-# NOINLINE dayValue #-}

intDecoder :: FieldDecoder Int
intDecoder = boundedInteger "Int"
{-# INLINE intDecoder #-}

-- | @bit@ and the integer types.  A value out of range is a 'DecodeError', as it
-- is for the other fixed-size integers below.
instance FromSqlField Int where
  fieldDecoder = intDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder intDecoder
  {-# NOINLINE rowDecoderWith #-}

int8Decoder :: FieldDecoder Int8
int8Decoder = boundedInteger "Int8"
{-# INLINE int8Decoder #-}

-- | @bit@ and the integer types.
instance FromSqlField Int8 where
  fieldDecoder = int8Decoder
  rowDecoderWith = cellRowDecoder fieldDecoder int8Decoder
  {-# NOINLINE rowDecoderWith #-}

int16Decoder :: FieldDecoder Int16
int16Decoder = boundedInteger "Int16"
{-# INLINE int16Decoder #-}

-- | @bit@ and the integer types.
instance FromSqlField Int16 where
  fieldDecoder = int16Decoder
  rowDecoderWith = cellRowDecoder fieldDecoder int16Decoder
  {-# NOINLINE rowDecoderWith #-}

int32Decoder :: FieldDecoder Int32
int32Decoder = boundedInteger "Int32"
{-# INLINE int32Decoder #-}

-- | @bit@ and the integer types.
instance FromSqlField Int32 where
  fieldDecoder = int32Decoder
  rowDecoderWith = cellRowDecoder fieldDecoder int32Decoder
  {-# NOINLINE rowDecoderWith #-}

int64Decoder :: FieldDecoder Int64
int64Decoder = compiledFieldDecoder "Int64" isIntegerType (\_ ti -> Right (unsignedByteType ti)) integerAt
{-# INLINE int64Decoder #-}

-- | @bit@ and the integer types.
instance FromSqlField Int64 where
  fieldDecoder = int64Decoder
  rowDecoderWith = cellRowDecoder fieldDecoder int64Decoder
  {-# NOINLINE rowDecoderWith #-}

word8Decoder :: FieldDecoder Word8
word8Decoder = boundedInteger "Word8"
{-# INLINE word8Decoder #-}

-- | @bit@ and the integer types.
instance FromSqlField Word8 where
  fieldDecoder = word8Decoder
  rowDecoderWith = cellRowDecoder fieldDecoder word8Decoder
  {-# NOINLINE rowDecoderWith #-}

-- | Integer types, and @decimal@ / @numeric@ with scale 0 (such as
-- @decimal(38,0)@, which 'Integer' parameters beyond @bigint@ are sent as).
instance FromSqlField Integer where
  fieldDecoder = compiledFieldDecoder "Integer" (\ti -> isIntegerType ti || isScale0 ti) (\_ ti -> Right ti) $ \ti bs ->
    if isScale0 ti
      then decimalMantissa <$> decimalValue ti bs
      else toInteger <$> integerValue ti bs
    where
      isScale0 = \case
        TIDecimalN _ 0 -> True
        TINumericN _ 0 -> True
        _ -> False

boolDecoder :: FieldDecoder Bool
boolDecoder = compiledFieldDecoder "Bool" (hasDataType (== TyBit)) (\_ _ -> Right ()) (\_ -> bitValue)
{-# INLINE boolDecoder #-}

-- | @bit@.
instance FromSqlField Bool where
  fieldDecoder = boolDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder boolDecoder
  {-# NOINLINE rowDecoderWith #-}

doubleDecoder :: FieldDecoder Double
doubleDecoder = compiledFieldDecoder "Double" isFloatType (\_ _ -> Right ()) (\_ -> readFloating)
{-# INLINE doubleDecoder #-}

-- | @real@ and @float@.
instance FromSqlField Double where
  fieldDecoder = doubleDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder doubleDecoder
  {-# NOINLINE rowDecoderWith #-}

floatDecoder :: FieldDecoder Float
floatDecoder = compiledFieldDecoder "Float" isFloatType (\_ _ -> Right ()) (\_ -> float32Value)
{-# INLINE floatDecoder #-}

-- | @real@.  A @float@ value that takes eight bytes is a 'DecodeError', rather
-- than being narrowed.
instance FromSqlField Float where
  fieldDecoder = floatDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder floatDecoder
  {-# NOINLINE rowDecoderWith #-}

decimalDecoder :: FieldDecoder Decimal
decimalDecoder = compiledFieldDecoder "Decimal"
  (\ti -> isDecimalType ti || isMoneyType ti || isIntegerType ti)
  (\_ ti -> Right (decimalColumn ti))
  decimalReader
{-# INLINE decimalDecoder #-}

-- | Accepts @decimal@, @numeric@, @money@, @smallmoney@ and integer types.
instance FromSqlField Decimal where
  fieldDecoder = decimalDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder decimalDecoder
  {-# NOINLINE rowDecoderWith #-}

moneyDecoder :: FieldDecoder Money
moneyDecoder = compiledFieldDecoder "Money" isMoneyType (\_ _ -> Right ()) (\_ -> moneyValue)
{-# INLINE moneyDecoder #-}

-- | @money@ and @smallmoney@, with all four decimal places.
instance FromSqlField Money where
  fieldDecoder = moneyDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder moneyDecoder
  {-# NOINLINE rowDecoderWith #-}

uuidDecoder :: FieldDecoder UUID
uuidDecoder = compiledFieldDecoder "UUID" (hasDataType (== TyUniqueIdentifier)) (\_ _ -> Right ()) (\_ -> readGuid)
{-# INLINE uuidDecoder #-}

-- | @uniqueidentifier@.
instance FromSqlField UUID where
  fieldDecoder = uuidDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder uuidDecoder
  {-# NOINLINE rowDecoderWith #-}

-- Strings ------------------------------------------------------------------

textDecoder :: FieldDecoder Text
textDecoder = FieldDecoder $ \_ col -> do
  enc <- textEncodingOf (columnType col)
  let read = textValue enc
  pure (CellDecoder (nullAs "Text") read read)
{-# INLINE textDecoder #-}

-- | Accepts Unicode types, and single-byte types in UTF-8 or a supported
-- single-byte code page.  The collation is checked when the result set's
-- columns arrive, before any rows are decoded.
instance FromSqlField Text where
  fieldDecoder = textDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder textDecoder
  {-# NOINLINE rowDecoderWith #-}

lazyTextDecoder :: FieldDecoder LT.Text
lazyTextDecoder = LT.fromStrict <$> textDecoder
{-# INLINE lazyTextDecoder #-}

-- | As 'Text', with the whole value read into memory first.  To read a large value
-- as it arrives, use 'streamTextField'.
instance FromSqlField LT.Text where
  fieldDecoder = lazyTextDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder lazyTextDecoder
  {-# NOINLINE rowDecoderWith #-}

stringDecoder :: FieldDecoder String
stringDecoder = T.unpack <$> textDecoder
{-# INLINE stringDecoder #-}

instance {-# OVERLAPPING #-} FromSqlField String where
  fieldDecoder = stringDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder stringDecoder
  {-# NOINLINE rowDecoderWith #-}

byteStringDecoder :: FieldDecoder B.ByteString
byteStringDecoder = bytesDecoder "ByteString" (\ti -> isBinaryType ti || isAnsiType ti) id
{-# INLINE byteStringDecoder #-}

-- | Accepts binary types and also the raw bytes of single-byte character types.
instance FromSqlField B.ByteString where
  fieldDecoder = byteStringDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder byteStringDecoder
  {-# NOINLINE rowDecoderWith #-}

lazyByteStringDecoder :: FieldDecoder LB.ByteString
lazyByteStringDecoder = LB.fromStrict <$> byteStringDecoder
{-# INLINE lazyByteStringDecoder #-}

-- | As a strict 'B.ByteString', with the whole value read into memory first.  To
-- read a large value as it arrives, use 'streamField'.
instance FromSqlField LB.ByteString where
  fieldDecoder = lazyByteStringDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder lazyByteStringDecoder
  {-# NOINLINE rowDecoderWith #-}

-- Dates and times ---------------------------------------------------------

localTimeDecoder :: FieldDecoder LocalTime
localTimeDecoder = compiledFieldDecoder "LocalTime" isLocalTimeType (\_ ti -> Right ti) localTimeReader
{-# INLINE localTimeDecoder #-}

-- | @datetime@, @smalldatetime@, @datetime2@ and @date@ (at midnight).
instance FromSqlField LocalTime where
  fieldDecoder = localTimeDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder localTimeDecoder
  {-# NOINLINE rowDecoderWith #-}

utcTimeDecoder :: FieldDecoder UTCTime
utcTimeDecoder = compiledFieldDecoder "UTCTime"
  (\ti -> isLocalTimeType ti || isDateTimeOffsetType ti)
  (\_ ti -> Right ti)
  utcTimeReader
{-# INLINE utcTimeDecoder #-}

-- | Zoneless types are taken to be UTC; @datetimeoffset@ is converted to UTC.
instance FromSqlField UTCTime where
  fieldDecoder = utcTimeDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder utcTimeDecoder
  {-# NOINLINE rowDecoderWith #-}

dateTimeOffsetDecoder :: FieldDecoder DateTimeOffset
dateTimeOffsetDecoder = compiledFieldDecoder "DateTimeOffset" isDateTimeOffsetType
  (\_ ti -> case ti of
    TIDateTimeOffsetN s -> Right s
    _ -> Left "not datetimeoffset")
  readDateTimeOffset
{-# INLINE dateTimeOffsetDecoder #-}

instance FromSqlField DateTimeOffset where
  fieldDecoder = dateTimeOffsetDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder dateTimeOffsetDecoder
  {-# NOINLINE rowDecoderWith #-}

zonedTimeDecoder :: FieldDecoder ZonedTime
zonedTimeDecoder = dateTimeOffsetToZonedTime <$> dateTimeOffsetDecoder
{-# INLINE zonedTimeDecoder #-}

instance FromSqlField ZonedTime where
  fieldDecoder = zonedTimeDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder zonedTimeDecoder
  {-# NOINLINE rowDecoderWith #-}

dayDecoder :: FieldDecoder Day
dayDecoder = compiledFieldDecoder "Day" (hasDataType (== TyDate)) (\_ _ -> Right ()) (\_ -> dayValue)
{-# INLINE dayDecoder #-}

-- | @date@.
instance FromSqlField Day where
  fieldDecoder = dayDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder dayDecoder
  {-# NOINLINE rowDecoderWith #-}

timeOfDayDecoder :: FieldDecoder TimeOfDay
timeOfDayDecoder = compiledFieldDecoder "TimeOfDay" (hasDataType (== TyTime))
  (\_ ti -> case ti of
    TITimeN s -> Right s
    _ -> Left "not time")
  readTime
{-# INLINE timeOfDayDecoder #-}

-- | @time@ at any scale.
instance FromSqlField TimeOfDay where
  fieldDecoder = timeOfDayDecoder
  rowDecoderWith = cellRowDecoder fieldDecoder timeOfDayDecoder
  {-# NOINLINE rowDecoderWith #-}

-- Decoders from a value's parts --------------------------------------------

-- | A decoder of the types 'LocalTime' accepts (@date@, @datetime@,
-- @smalldatetime@ and @datetime2@), given a name for error messages and a
-- function of each value's day and picoseconds since midnight, which are 0 for
-- a @date@.  A @datetime@'s picoseconds are rounded down, as 'LocalTime''s are,
-- and a day count or a time count out of range is a 'DecodeError', as it is for
-- 'LocalTime'.
dayTimeFieldDecoder :: String -> (Day -> Int64 -> a) -> FieldDecoder a
dayTimeFieldDecoder name k = compiledFieldDecoder name isLocalTimeType (\_ ti -> Right ti) (dayTimeValue k)
{-# INLINE dayTimeFieldDecoder #-}

-- | A decoder of @datetimeoffset@, given a name for error messages and a
-- function of each value's day and picoseconds since midnight, both in UTC, and
-- its offset in minutes, as 'DateTimeOffset' holds them.  The value is checked as
-- 'DateTimeOffset' is: the offset must lie within ±14:00, and the local date
-- must be in range.
dateTimeOffsetFieldDecoder :: String -> (Day -> Int64 -> Int16 -> a) -> FieldDecoder a
dateTimeOffsetFieldDecoder name k = compiledFieldDecoder name isDateTimeOffsetType
  (\_ ti -> case ti of
    TIDateTimeOffsetN s -> Right s
    _ -> Left "not datetimeoffset")
  (readDateTimeOffsetWith k)
{-# INLINE dateTimeOffsetFieldDecoder #-}

-- | A decoder of @time@ at any scale, given a name for error messages and a
-- function of each value's picoseconds since midnight.
timeFieldDecoder :: String -> (Int64 -> a) -> FieldDecoder a
timeFieldDecoder name k = compiledFieldDecoder name (hasDataType (== TyTime))
  (\_ ti -> case ti of
    TITimeN s -> Right s
    _ -> Left "not time")
  (readTimeWith k)
{-# INLINE timeFieldDecoder #-}

-- | A decoder of the types 'Decimal' accepts (@decimal@, @numeric@, @money@,
-- @smallmoney@ and the integer types), given a name for error messages and a
-- function of each value's parts: whether it is negative, the high and low 64 bits
-- of its magnitude, and its scale.  A @decimal@ is checked as 'Decimal' checks it,
-- a @money@ value has scale 4 and an integer scale 0, and a zero is never negative.
-- The high bits are 0 unless the value needs more than 64, which only a @decimal@
-- of precision 20 or more can.
--
-- > -- a value's whole part, when its magnitude fits 64 bits
-- > wholePart :: FieldDecoder (Maybe Integer)
-- > wholePart = decimalFieldDecoder "whole part" $ \negative hi lo scale ->
-- >   if hi /= 0 then Nothing
-- >   else Just ((if negative then negate else id) (toInteger (lo `quot` 10 ^ scale)))
decimalFieldDecoder :: String -> (Bool -> Word64 -> Word64 -> Word8 -> a) -> FieldDecoder a
decimalFieldDecoder name k = compiledFieldDecoder name
  (\ti -> isDecimalType ti || isMoneyType ti || isIntegerType ti)
  (\_ ti -> Right (decimalColumn ti))
  (decimalPartsReader k)
{-# INLINE decimalFieldDecoder #-}

-- 'decimalReader' for 'decimalFieldDecoder''s function.  The bang is
-- 'decimalReader''s.
decimalPartsReader :: (Bool -> Word64 -> Word64 -> Word8 -> a) -> DecimalColumn -> ValueReader a
decimalPartsReader k column !bs = case column of
  DecimalColumn precision scale -> readDecimalWith k precision scale bs
  OtherDecimal ti
    | isMoneyType ti -> (`signed` 4) =<< moneyUnits bs
    | otherwise -> (`signed` 0) =<< integerValue ti bs
  where
    signed i scale = Right $! k (i < 0) 0 (if i < 0 then negate (fromIntegral i) else fromIntegral i) scale
{-# INLINE decimalPartsReader #-}

------------------------------------------------------------------------------
-- Dynamic values

-- | Any column as a 'SqlValue' (the 'FromSqlField' instance), with the
-- reader chosen by the column's type.
sqlValueDecoder :: FieldDecoder SqlValue
sqlValueDecoder = FieldDecoder $ \ctx col -> do
  let ti = columnType col
  -- Reject a single-byte column whose collation can't be decoded up front,
  -- as the Text decoder does.  (A sql_variant's collation is per value.)
  when (isAnsiType ti) $ () <$ columnTextDecoder ti
  case ti of
    TIUdt _ -> Left (unsupportedUdt ti "as SqlValue")
    _ -> pure ()
  -- Select the scalar reader once per column and evaluate its SqlValue
  -- result before returning it. Binary values keep their ownership paths.
  Right $ if isBinaryType ti
    then CellDecoder (Right SqlNull)
      (\bytes -> Right $! SqlBinary (B.copy bytes)) (\bytes -> Right $! SqlBinary bytes)
    else case selectSqlValueReader ctx ti of
      SelectedReader reader -> cellDecoder (Right SqlNull) reader

instance FromSqlField SqlValue where
  fieldDecoder = sqlValueDecoder

-- | A compiled part prepares a recipe once per allocation bound. Column
-- positions are captured at compilation, and the NBCROW bitmap is the recipe's
-- read-only environment.  A cell that fails reads past the rest of the row and
-- then fails the recipe ('P.failValue'), which stops composition before any later
-- consumer runs; the row compiler catches it ('P.attempt').  The skip comes from the
-- result set's compiled shapes, captured per column, so no decoder carries a skip
-- recipe of its own.  The recipe is 'Prepared' for the reason 'CompiledRow' gives: a
-- part not inlined into its row, such as each column of a 'SqlRow', was otherwise
-- prepared again for every row.
data RowPart a = RowPart (Int -> Prepared (P.Recipe B.ByteString a))

-- | A decoder of a whole row, with a fixed column count, checked against a result
-- set's columns before its first row.  Compose it with its 'Applicative' instance.
-- It has no 'Monad' instance; use 'RowDecoderMonadic' when later columns depend on
-- earlier values.
data RowDecoder a = RowDecoder
  { compileRowAt :: TdsContext -> ResultSetInfo -> Int -> Either DecodeError (RowPart a)
  , numExpectedColumns :: !Int
  }

-- The instances call their combinators out of line, so that a decoder an application
-- composes, such as @(,) \<$\> singleField a \<*\> singleField b@, is a few calls where
-- it is written rather than its own copy of the composition: a function calling
-- 'Hmssql.Query.queryWith' with that decoder was 1,563 bytes of object code, and is
-- 283.  The rules below turn a chain of '<*>' into one call of a lift function of its
-- length, so that a row applies the combining function once, to all its values;
-- through 'apRowCalled' alone, each step of a row held a partial application of it,
-- 176 bytes per row of five columns.  The combining function is then an unknown call
-- once per row, beside the columns' recipes, which were unknown calls already
-- ('singleField' is out of line).  The library's own compositions use the inlined
-- 'mapRow' and 'liftRow', whose recipe knows the combining function.
instance Functor RowDecoder where
  fmap = mapRowCalled
  {-# INLINE fmap #-}

instance Applicative RowDecoder where
  pure a = RowDecoder (\_ _ _ -> Right (RowPart (\_ -> Prepared (pure a)))) 0
  (<*>) = apRowCalled
  {-# INLINE (<*>) #-}
  liftA2 = liftRowCalled
  {-# INLINE liftA2 #-}

mapRow :: (a -> b) -> RowDecoder a -> RowDecoder b
mapRow f (RowDecoder c n) = RowDecoder
  (\ctx rs i -> do
    RowPart prepare <- c ctx rs i
    pure $ RowPart $ \ahead -> case prepare ahead of
      Prepared read -> Prepared (fmap f read)) n
{-# INLINE mapRow #-}

liftRow :: (a -> b -> c) -> RowDecoder a -> RowDecoder b -> RowDecoder c
liftRow f (RowDecoder ca na) (RowDecoder cb nb) = RowDecoder
  (\ctx rs i -> do
    RowPart prepareA <- ca ctx rs i
    -- Strict, because out of line 'cb' is an unknown call and took a thunk.
    RowPart prepareB <- cb ctx rs $! i + na
    -- The parts are closures built by 'singleField' or a type's 'fieldRowDecoder',
    -- so GHC calls them without seeing into them; 'P.dynamic' spares the second its
    -- position's box, and the first gets the position as it came.
    pure $ RowPart $ \ahead -> case (prepareA ahead, prepareB ahead) of
      (Prepared readA, Prepared readB) -> Prepared (liftA2 f readA (P.dynamic readB))) (na + nb)
{-# INLINE liftRow #-}

apRow :: RowDecoder (a -> b) -> RowDecoder a -> RowDecoder b
apRow = liftRow id
{-# INLINE apRow #-}

mapRowCalled :: (a -> b) -> RowDecoder a -> RowDecoder b
mapRowCalled = mapRow
{-# OPAQUE mapRowCalled #-}

liftRowCalled :: (a -> b -> c) -> RowDecoder a -> RowDecoder b -> RowDecoder c
liftRowCalled = liftRow
{-# OPAQUE liftRowCalled #-}

apRowCalled :: RowDecoder (a -> b) -> RowDecoder a -> RowDecoder b
apRowCalled = apRow
{-# OPAQUE apRowCalled #-}

-- 'liftA2' with '(:)', as 'traverse' and 'sequenceA' of a list compose, so that the
-- cons is built where the values are rather than through an unknown call.
consRowCalled :: RowDecoder a -> RowDecoder [a] -> RowDecoder [a]
consRowCalled = liftRow (:)
{-# OPAQUE consRowCalled #-}

-- The lift functions of three to twelve columns, which the rules make of a chain of
-- '<*>' and which the tuples of those lengths are.  Each is the chain itself, inlined
-- here once: the lambda gives its function a known arity, so that GHC eliminates the
-- partial applications between the steps and the row calls @f@ once with all its
-- values.  A chain longer than twelve goes on through 'apRowCalled'.
lift3RowCalled :: (a -> b -> c -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder r
lift3RowCalled f d1 d2 d3 = mapRow (\x1 x2 x3 -> f x1 x2 x3) d1 `apRow` d2 `apRow` d3
{-# OPAQUE lift3RowCalled #-}

lift4RowCalled :: (a -> b -> c -> d -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder r
lift4RowCalled f d1 d2 d3 d4 = mapRow (\x1 x2 x3 x4 -> f x1 x2 x3 x4) d1 `apRow` d2 `apRow` d3 `apRow` d4
{-# OPAQUE lift4RowCalled #-}

lift5RowCalled :: (a -> b -> c -> d -> e -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder r
lift5RowCalled f d1 d2 d3 d4 d5 = mapRow (\x1 x2 x3 x4 x5 -> f x1 x2 x3 x4 x5) d1 `apRow` d2 `apRow` d3 `apRow` d4 `apRow` d5
{-# OPAQUE lift5RowCalled #-}

lift6RowCalled :: (a -> b -> c -> d -> e -> g -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder r
lift6RowCalled f d1 d2 d3 d4 d5 d6 = mapRow (\x1 x2 x3 x4 x5 x6 -> f x1 x2 x3 x4 x5 x6) d1 `apRow` d2 `apRow` d3 `apRow` d4 `apRow` d5 `apRow` d6
{-# OPAQUE lift6RowCalled #-}

-- Seven to eleven columns are two of the smaller recipes, one applied to the
-- other through 'id', rather than a recipe of their own: the first takes the
-- leading columns and the second the last five (three, for seven), which keeps
-- each unknown application small enough for the RTS's generic apply without a
-- further frame.  That is 96,568 bytes less of library code, and 2.2% to 5.4%
-- less allocation per row of seven to eleven columns (GHC 9.12.4, 2026-11-04,
-- docs/dev/performance-research.md, "The ideas run").  Split the same way, twelve columns
-- allocated more, so 'lift12RowCalled' below stays one recipe.
lift7RowCalled :: (a -> b -> c -> d -> e -> g -> h -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder r
lift7RowCalled f d1 d2 d3 d4 d5 d6 d7 = lift4RowCalled id (lift4RowCalled f d1 d2 d3 d4) d5 d6 d7
{-# OPAQUE lift7RowCalled #-}

lift8RowCalled :: (a -> b -> c -> d -> e -> g -> h -> i -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder r
lift8RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 = lift6RowCalled id (lift3RowCalled f d1 d2 d3) d4 d5 d6 d7 d8
{-# OPAQUE lift8RowCalled #-}

lift9RowCalled :: (a -> b -> c -> d -> e -> g -> h -> i -> j -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder r
lift9RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 = lift6RowCalled id (lift4RowCalled f d1 d2 d3 d4) d5 d6 d7 d8 d9
{-# OPAQUE lift9RowCalled #-}

lift10RowCalled :: (a -> b -> c -> d -> e -> g -> h -> i -> j -> k -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder k -> RowDecoder r
lift10RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 = lift6RowCalled id (lift5RowCalled f d1 d2 d3 d4 d5) d6 d7 d8 d9 d10
{-# OPAQUE lift10RowCalled #-}

lift11RowCalled :: (a -> b -> c -> d -> e -> g -> h -> i -> j -> k -> l -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder k -> RowDecoder l -> RowDecoder r
lift11RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 = lift6RowCalled id (lift6RowCalled f d1 d2 d3 d4 d5 d6) d7 d8 d9 d10 d11
{-# OPAQUE lift11RowCalled #-}

lift12RowCalled :: (a -> b -> c -> d -> e -> g -> h -> i -> j -> k -> l -> m -> r) -> RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder k -> RowDecoder l -> RowDecoder m -> RowDecoder r
lift12RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12 = mapRow (\x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 -> f x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12) d1 `apRow` d2 `apRow` d3 `apRow` d4 `apRow` d5 `apRow` d6 `apRow` d7 `apRow` d8 `apRow` d9 `apRow` d10 `apRow` d11 `apRow` d12
{-# OPAQUE lift12RowCalled #-}

{-# RULES
"RowDecoder/fmap-ap" forall f d1 d2. apRowCalled (mapRowCalled f d1) d2 = liftRowCalled f d1 d2
"RowDecoder/lift2-ap" forall f d1 d2 d3. apRowCalled (liftRowCalled f d1 d2) d3 = lift3RowCalled f d1 d2 d3
"RowDecoder/lift3-ap" forall f d1 d2 d3 d4. apRowCalled (lift3RowCalled f d1 d2 d3) d4 = lift4RowCalled f d1 d2 d3 d4
"RowDecoder/lift4-ap" forall f d1 d2 d3 d4 d5. apRowCalled (lift4RowCalled f d1 d2 d3 d4) d5 = lift5RowCalled f d1 d2 d3 d4 d5
"RowDecoder/lift5-ap" forall f d1 d2 d3 d4 d5 d6. apRowCalled (lift5RowCalled f d1 d2 d3 d4 d5) d6 = lift6RowCalled f d1 d2 d3 d4 d5 d6
"RowDecoder/lift6-ap" forall f d1 d2 d3 d4 d5 d6 d7. apRowCalled (lift6RowCalled f d1 d2 d3 d4 d5 d6) d7 = lift7RowCalled f d1 d2 d3 d4 d5 d6 d7
"RowDecoder/lift7-ap" forall f d1 d2 d3 d4 d5 d6 d7 d8. apRowCalled (lift7RowCalled f d1 d2 d3 d4 d5 d6 d7) d8 = lift8RowCalled f d1 d2 d3 d4 d5 d6 d7 d8
"RowDecoder/lift8-ap" forall f d1 d2 d3 d4 d5 d6 d7 d8 d9. apRowCalled (lift8RowCalled f d1 d2 d3 d4 d5 d6 d7 d8) d9 = lift9RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9
"RowDecoder/lift9-ap" forall f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10. apRowCalled (lift9RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9) d10 = lift10RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10
"RowDecoder/lift10-ap" forall f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11. apRowCalled (lift10RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10) d11 = lift11RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11
"RowDecoder/lift11-ap" forall f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12. apRowCalled (lift11RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11) d12 = lift12RowCalled f d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12
"RowDecoder/cons" forall d ds. liftRowCalled (:) d ds = consRowCalled d ds
  #-}

-- | A row decoder of one column, with this field decoder.  For a type's own decoder,
-- 'fieldRowDecoder' is the same.
singleField :: FieldDecoder a -> RowDecoder a
singleField decoder = RowDecoder
  (\ctx rs i -> case columnAt rs i of
    Left err -> Left err
    Right col -> case compileField decoder ctx col of
      Left err -> Left (DecodeError (Just (columnName col)) err)
      Right d -> Right (cellPart rs i col d)) 1
-- Out of line: inlined, every field of every row type got its own copy of the
-- cell's reading, 25 KB of object code per field in a program of fifty derived
-- records (29.9 MB in all, 617 s to compile); out of line it is one copy here.
-- OPAQUE rather than NOINLINE, so that it isn't split into a worker returning the
-- decoder's two fields unboxed: each use then rebuilt the 'RowDecoder' from them,
-- once per field type in a module.  The derived instances of code-size.sh --quick
-- are 35,544 bytes instead of 37,672, and of the full program 111,208 instead of
-- 111,304 (its larger instances grew slightly).  ('productDecoder' OPAQUE made the
-- quick ones 45,927: its operands are then lazy, a thunk each.)
{-# OPAQUE singleField #-}

-- | 'singleField', compiled as a built-in type's 'fieldRowDecoder' is.  The
-- reading of a value that lies in the packet behind a fixed width or a one- or
-- two-byte length is copied around the decoder's conversion, which the copy then
-- calls as a known function on the value's place in the buffer, rather than as an
-- unknown function on a 'B.ByteString' made for it.  The result decodes exactly
-- what 'singleField' decodes: the column's type is checked once per result set, a
-- NULL is a 'DecodeError' unless the decoder allows it, and a value cut by a
-- packet, like every value of a @max@, legacy LOB or @sql_variant@ column, is read
-- through 'singleField''s own path.
--
-- It pays for a decoder of your own whose conversion is small and runs for many
-- rows, such as one made by 'fieldDecoderFor'.  A large conversion, such as a
-- date's, is cheaper left a call through 'singleField', as the built-in date and
-- time decoders leave theirs, because inlined it allocates more than the call
-- saves.
--
-- Each use is a copy of the cell's reading, a few kilobytes of object code where
-- 'singleField' is one call, so bind the result once at the top level with
-- @NOINLINE@, which keeps GHC from copying the binding into its uses.  The
-- conversion inlines into the copy when its definition is visible there, which an
-- @INLINE@ definition or one in the same module is.
--
-- > idField :: RowDecoder Builder
-- > idField = inlinedField (fieldDecoderFor "id" isIdType (\_ _ bytes -> Right (idDigits bytes)))
-- > {-# NOINLINE idField #-}
inlinedField :: FieldDecoder a -> RowDecoder a
inlinedField d = cellRowDecoder d d NoNulls
{-# INLINE inlinedField #-}

-- | 'inlinedField' of a nullable column, with the NULL and the 'Just' handled in
-- the copy as well.  Use it rather than @'inlinedField' . 'nullableField'@, which
-- gains nothing over 'singleField', because 'nullableField' is out of line and the
-- copy can't see the conversion through it.  'singleField' needs no such
-- counterpart, since its conversion is a call either way, so
-- @'singleField' . 'nullableField'@ is its nullable form.
inlinedNullableField :: FieldDecoder a -> RowDecoder (Maybe a)
inlinedNullableField d = cellRowDecoder d d Nulls
{-# INLINE inlinedNullableField #-}

-- | A row decoder of one column, chosen by the function from the column's
-- 'ColumnInfo' when a result set's columns arrive, before its first row; the
-- decoder chosen reads every value of the column, and must read one column.  This
-- is for a program that builds its queries and their decoders at runtime and
-- decodes a column by what the server says it is, such as a long column through a
-- 'FoldingCell' and a short one through its type's 'fieldRowDecoder'.  The choice
-- costs nothing per row, where 'RowDecoderMonadic' makes it for every row and
-- reads each column through 'singleField'.
--
-- > -- a long text a piece at a time, any other whole
-- > textOrFold :: RowDecoder Summary
-- > textOrFold = byColumn $ \col ->
-- >   if columnIsLong col then singleField folded else summarize <$> fieldRowDecoder @Text
byColumn :: (ColumnInfo -> RowDecoder a) -> RowDecoder a
byColumn choose = RowDecoder
  (\ctx rs i -> case columnAt rs i of
    Left err -> Left err
    Right col -> case choose col of
      RowDecoder compile 1 -> compile ctx rs i
      RowDecoder _ n -> Left (DecodeError (Just (columnName col))
        ("byColumn chose a decoder of " ++ show n ++ " columns, not 1"))) 1
-- Out of line, as 'singleField' is: what it builds is per result set.
{-# OPAQUE byColumn #-}

-- The column a one-column decoder at this index reads, or why there is none.
columnAt :: ResultSetInfo -> Int -> Either DecodeError ColumnInfo
columnAt rs i
  | i < 0 || i >= rsColumnCount rs =
      Left (DecodeError Nothing ("expected 1 column, got " ++ show (max 0 (rsColumnCount rs - i))))
  | otherwise = Right (indexSmallArray (rsColumnArray rs) i)
{-# NOINLINE columnAt #-}

-- The recipe of a column at an index, with its cell decoder: the general read, which
-- calls the conversion through the decoder.
cellPart :: ResultSetInfo -> Int -> ColumnInfo -> CellDecoder a -> RowPart a
cellPart rs i col d = RowPart $ \ahead ->
  let shape = rowShape (columnType col)
      present = P.liftParser (cellHead shape >>= readCellRecipe col d ahead)
      absent = P.liftParser (readCellRecipe col d ahead NullCell)
   in Prepared $ P.recover (P.ask >>= \bitmap -> if columnNull bitmap i then absent else present) (skipLater rs i)
{-# NOINLINE cellPart #-}

-- A failed cell's handler: read past the rest of the row and fail it.  The handler
-- asks for the bitmap itself, so that it captures nothing of the row and is built
-- once per column.  Given the bitmap from outside, it was a closure and a thunk for
-- every cell.
skipLater :: ResultSetInfo -> Int -> ReadFailure -> P.Recipe B.ByteString a
skipLater rs i = \failure -> do
  bitmap <- P.ask
  P.liftParser (skipCells bitmap later)
  P.failValue failure
  where later = drop (i + 1) (rsCells rs)
{-# NOINLINE skipLater #-}

-- A present cell, read whole through its decoder: the cells 'cellRowDecoder' doesn't
-- read inline.  Behind 'Prepared', as a row's recipe is, so that what it builds for a
-- column it builds once: returning the recipe, it was a function of the cell's input
-- too, and as 'cellPart''s read a 'SqlRow' of an int and a bigint allocated 80 bytes
-- more per row.  'cellPart' has its own copy of this read even so: through this
-- function, an extra unknown call per cell, a typed row of 50 columns, each a
-- 'SqlValue' through 'singleField', took 1.10 times as long, for 17 KB of code saved.
otherCell :: ColumnInfo -> CellDecoder a -> Int -> ColumnShape -> Prepared (Parser a)
otherCell col d ahead shape = Prepared (cellHead shape >>= readCellRecipe col d ahead)
{-# NOINLINE otherCell #-}

-- 'otherCell' with the cell decoder of the type's out-of-line 'fieldDecoder', so that
-- a type's row decoder holds no second copy of its conversion for the cells that
-- aren't read inline.  It compiles the decoder once, the first time a column's recipe
-- needs it.
sharedCell :: Nulls a b -> FieldDecoder a -> TdsContext -> ColumnInfo -> Int -> ColumnShape -> Prepared (Parser b)
sharedCell nulls shared ctx col ahead shape = case compileField shared ctx col of
  Right d -> otherCell col (nullsCell nulls d) ahead shape
  Left err -> Prepared (P.failValue (DecodeFailed (DecodeError (Just (columnName col)) err)))
{-# NOINLINE sharedCell #-}

-- A built-in type's row decoders, the copies the comment at 'FromSqlField' describes,
-- and an application's through 'inlinedField': 'singleField' of the second decoder,
-- with its conversion inlined at one place, for a value that lies in the payload
-- behind a fixed width or a one- or two-byte length.  Those are every column but the
-- @max@, legacy LOB and @sql_variant@ ones.  Every other cell is read by 'sharedCell'
-- through the first decoder, which for a built-in type is its 'fieldDecoder', out of
-- line.  It takes two arguments, so that an instance's @cellRowDecoder fieldDecoder
-- int32Decoder@ inlines.  Both decoders' compile functions run, once per result set
-- each, which is harmless because a 'FieldDecoder''s is pure.
cellRowDecoder :: forall a b. FieldDecoder a -> FieldDecoder a -> Nulls a b -> RowDecoder b
cellRowDecoder shared inlined = \nulls -> RowDecoder
  (\ctx rs i -> case columnAt rs i of
    Left err -> Left err
    Right col -> case compileField inlined ctx col of
      Left err -> Left (DecodeError (Just (columnName col)) err)
      -- A folding cell reads a long column's values, none of which is read inline.
      Right d@FoldingCell{} -> Right (cellPart rs i col (nullsCell nulls d))
      Right (CellDecoder onNull borrowed _) ->
        let shape = rowShape (columnType col)
            -- The delimiter as 'P.prefixedRowValue' takes it, evaluated here, once per
            -- column.  Inlined into the cell, the shape was two constructors per
            -- fixed-width cell.
            !width = case shape of
              ConstantCell (Sized _) -> 0
              ByteLength -> 1
              ShortLength -> 2
              _ -> -1 :: Int
            !marker = case shape of
              ConstantCell (Sized n) -> n
              ShortLength -> 0xFFFF
              _ -> 0
            named = DecodeFailed . DecodeError (Just (columnName col))
            -- The conversion is known here, so it takes the slice's fields rather than
            -- a 'B.ByteString' built for it, and its 'Either' goes: the gain over
            -- 'singleField''s unknown call.
            convert bytes = case borrowed bytes of
              Left e -> Left (named e)
              Right v -> Right (case nulls of
                NoNulls -> v
                Nulls -> Just v)
            nullValue :: P.Recipe env b
            nullValue = case nulls of
              NoNulls -> either (P.failValue . named) pure onNull
              Nulls -> pure Nothing
         in Right $ RowPart $ \ahead ->
              let other = case sharedCell nulls shared ctx col ahead shape of Prepared recipe -> recipe
                  present = P.prefixedRowValue i width marker convert nullValue (P.liftParser other)
               in Prepared $ P.recover
                    present
                    (skipLater rs i)
      Right d -> Right (cellPart rs i col (nullsCell nulls d))) 1
{-# INLINE cellRowDecoder #-}

-- | Types that decode from a whole row, one column per field in order.
-- Tuples of up to twelve fields and 'Only' have instances.  Derive one for
-- a record whose fields are 'FromSqlField' types, one field per column of
-- the @SELECT@, in order:
--
-- > data Customer = Customer { customerId :: Int, name :: Text, birthDate :: Maybe Day }
-- >   deriving stock (Show, Generic)
-- >   deriving anyclass (FromSqlRow)
--
-- The column types are checked against the fields before the first row is
-- decoded, and a mismatch is a 'DecodeError' naming the column.  For a row
-- decoder written by hand, see 'singleField'.
class FromSqlRow a where
  rowDecoder :: RowDecoder a
  default rowDecoder :: (Generic a, GRowDecoder (Rep a)) => RowDecoder a
  rowDecoder = genericFromSqlRow

-- | Check a row decoder against a result set's columns, before any row is read.  A
-- wrong column count or an incompatible type is a 'DecodeError'.
compileRowDecoder :: RowDecoder a -> TdsContext -> [ColumnInfo] -> Either DecodeError (CompiledRow a)
compileRowDecoder dec ctx cols = compileRowDecoderFor dec ctx (compileResultSet cols)

-- | 'compileRowDecoder' for columns already prepared with 'compileResultSet'.
compileRowDecoderFor :: RowDecoder a -> TdsContext -> ResultSetInfo -> Either DecodeError (CompiledRow a)
compileRowDecoderFor dec ctx rs
  | rsColumnCount rs /= numExpectedColumns dec = Left $ DecodeError Nothing $
      "result has " ++ show (rsColumnCount rs) ++ " column(s) but the row type expects " ++ show (numExpectedColumns dec)
  | otherwise = do
      RowPart prepare <- compileRowAt dec ctx rs 0
      -- A cell that fails reads past the rest of the row and fails the recipe, and
      -- the failure is left in it for the driver ('P.runParserAt'), so a row that
      -- decodes costs no 'Right'.
      pure $ CompiledRow $ \ahead -> case prepare ahead of
        Prepared read -> Prepared $ do
          bitmap <- rowBitmap (rsColumnCount rs)
          P.withEnv bitmap (P.dynamic read)

-- | A decoder of every column as a 'SqlValue'.  A column with no such conversion
-- fails on the first row rather than at the check, so an empty result set still
-- gives its columns.
sqlRowDecoderFor :: [ColumnInfo] -> RowDecoder SqlRow
sqlRowDecoderFor cols = RowDecoder compile n
  where
    n = length cols
    -- Each column is compiled once, and a row is one loop over the columns'
    -- recipes that builds the list.  'traverse' with 'singleField' went through the
    -- general 'liftA2' once per column, which built a partial application of (:)
    -- per cell and a recipe closure per level.
    compile ctx rs i = do
      parts <- traverse (compileRowAt (singleField deferred) ctx rs) (take n [i ..])
      pure $ RowPart $ \ahead ->
        -- Built whole before the closure that reads a row.  Left as a thunk beside
        -- it, GHC 9.14.1 moved the building of the columns' array into that closure's
        -- loop, once for every cell (bugs-found.md, "Memory and performance").
        let !cells = prepareAll ahead parts
         in Prepared (SqlRow cols <$> values cells)
    prepareAll _ [] = []
    prepareAll ahead (RowPart prepare : parts) = case prepare ahead of
      Prepared read -> let !rest = prepareAll ahead parts in read : rest
    -- 'liftA2' rather than a bind: a bind's continuation is one closure shared by
    -- the completed and the suspended branches, 16 bytes per cell, where 'liftA2'
    -- calls the rest of the loop directly and builds a closure only to suspend.
    values [] = pure []
    values (cell : cells) = liftA2 (:) (P.dynamic cell) (values cells)
    -- A compile error becomes a per-row one: a generic reader should still learn
    -- the columns of an empty result set it couldn't have decoded.
    deferred = FieldDecoder $ \ctx col -> case compileField sqlValueDecoder ctx col of
      Left err -> Right (CellDecoder (Left err) (const (Left err)) (const (Left err)))
      Right result -> Right result

-- The instances of 'Only' and the tuples are compiled here, once for each arity: an
-- instance's decoder is a function of the fields' row decoders, out of line, so that
-- a use such as @query conn sql :: IO [(Int32, Text)]@ refers to a decoder built by a
-- call with the fields' instances, rather than to a copy of the row's composition.  With
-- the instances INLINE, every row type used in a module got its own copy: in a module
-- of 40 functions each calling 'Hmssql.Query.query', with 16 'Only' types the code
-- was 593 bytes per function and with eight tuple types of two to six fields 1,449;
-- now 206 and 193 (a 'query' of a record type is 167).  The row's reading is the same
-- code as before: each field is its type's 'fieldRowDecoder', compiled in the
-- library, so nothing per row depended on knowing the types, and within each arity
-- the composition is still inlined into one recipe.  OPAQUE, as 'singleField' is, so
-- that a use isn't a worker's unboxed result boxed again (about 50 bytes per row type).
instance FromSqlField a => FromSqlRow (Only a) where
  rowDecoder = onlyDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b) => FromSqlRow (a, b) where
  rowDecoder = tuple2 fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c) => FromSqlRow (a, b, c) where
  rowDecoder = tuple3 fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d) => FromSqlRow (a, b, c, d) where
  rowDecoder = tuple4 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e) => FromSqlRow (a, b, c, d, e) where
  rowDecoder = tuple5 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f) => FromSqlRow (a, b, c, d, e, f) where
  rowDecoder = tuple6 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g) => FromSqlRow (a, b, c, d, e, f, g) where
  rowDecoder = tuple7 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g, FromSqlField h) => FromSqlRow (a, b, c, d, e, f, g, h) where
  rowDecoder = tuple8 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g, FromSqlField h, FromSqlField i) => FromSqlRow (a, b, c, d, e, f, g, h, i) where
  rowDecoder = tuple9 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g, FromSqlField h, FromSqlField i, FromSqlField j) => FromSqlRow (a, b, c, d, e, f, g, h, i, j) where
  rowDecoder = tuple10 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g, FromSqlField h, FromSqlField i, FromSqlField j, FromSqlField k) => FromSqlRow (a, b, c, d, e, f, g, h, i, j, k) where
  rowDecoder = tuple11 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

instance (FromSqlField a, FromSqlField b, FromSqlField c, FromSqlField d, FromSqlField e, FromSqlField f, FromSqlField g, FromSqlField h, FromSqlField i, FromSqlField j, FromSqlField k, FromSqlField l) => FromSqlRow (a, b, c, d, e, f, g, h, i, j, k, l) where
  rowDecoder = tuple12 fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder fieldRowDecoder

onlyDecoder :: RowDecoder a -> RowDecoder (Only a)
onlyDecoder a = mapRow Only a
{-# OPAQUE onlyDecoder #-}

-- A tuple of three or more fields is the lift function of its length with the
-- constructor, so that each row applies the constructor once, to all its values, and
-- the composition is the one an application's chain of '<*>' of that length is
-- rewritten to.  Composed before from a balanced tree of pairs and triples, each row
-- of five columns built a pair and a triple beside the tuple, 56 bytes: Mock.query
-- of the nullable NBCROW rows allocated 8,245,012 bytes and allocates 7,713,338,
-- and Hmssql.Decoding's object code is 3 KB smaller with the lift functions than it
-- was with the tuples' own compositions.
tuple2 :: RowDecoder a -> RowDecoder b -> RowDecoder (a, b)
tuple2 a b = liftRow (,) a b
{-# OPAQUE tuple2 #-}
tuple3 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder (a, b, c)
tuple3 a b c = lift3RowCalled (,,) a b c
{-# OPAQUE tuple3 #-}
tuple4 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder (a, b, c, d)
tuple4 a b c d = lift4RowCalled (,,,) a b c d
{-# OPAQUE tuple4 #-}
tuple5 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder (a, b, c, d, e)
tuple5 a b c d e = lift5RowCalled (,,,,) a b c d e
{-# OPAQUE tuple5 #-}
tuple6 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder (a, b, c, d, e, f)
tuple6 a b c d e f = lift6RowCalled (,,,,,) a b c d e f
{-# OPAQUE tuple6 #-}
tuple7 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder (a, b, c, d, e, f, g)
tuple7 a b c d e f g = lift7RowCalled (,,,,,,) a b c d e f g
{-# OPAQUE tuple7 #-}
tuple8 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder h -> RowDecoder (a, b, c, d, e, f, g, h)
tuple8 a b c d e f g h = lift8RowCalled (,,,,,,,) a b c d e f g h
{-# OPAQUE tuple8 #-}
tuple9 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder (a, b, c, d, e, f, g, h, i)
tuple9 a b c d e f g h i = lift9RowCalled (,,,,,,,,) a b c d e f g h i
{-# OPAQUE tuple9 #-}
tuple10 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder (a, b, c, d, e, f, g, h, i, j)
tuple10 a b c d e f g h i j = lift10RowCalled (,,,,,,,,,) a b c d e f g h i j
{-# OPAQUE tuple10 #-}
tuple11 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder k -> RowDecoder (a, b, c, d, e, f, g, h, i, j, k)
tuple11 a b c d e f g h i j k = lift11RowCalled (,,,,,,,,,,) a b c d e f g h i j k
{-# OPAQUE tuple11 #-}
tuple12 :: RowDecoder a -> RowDecoder b -> RowDecoder c -> RowDecoder d -> RowDecoder e -> RowDecoder f -> RowDecoder g -> RowDecoder h -> RowDecoder i -> RowDecoder j -> RowDecoder k -> RowDecoder l -> RowDecoder (a, b, c, d, e, f, g, h, i, j, k, l)
tuple12 a b c d e f g h i j k l = lift12RowCalled (,,,,,,,,,,,) a b c d e f g h i j k l
{-# OPAQUE tuple12 #-}

-- | The decoder a derived 'FromSqlRow' instance uses: one column per field of a
-- record or product constructor, in order.
genericFromSqlRow :: forall a. (Generic a, GRowDecoder (Rep a)) => RowDecoder a
genericFromSqlRow = case gRowDecoder @(Rep a) @() of
  GDecoder d -> recordDecoder ((to :: Rep a () -> a) . coerce) d
{-# INLINE genericFromSqlRow #-}

-- The generic decoder shares its composition.  A derived instance is a chain of calls
-- to 'fieldRowDecoder', 'productDecoder' and 'recordDecoder', all out of line, so a
-- record's instance holds no copy of a row's reading.  With the composition inlined
-- into every instance, through 'RowDecoder''s 'fmap' and 'liftA2' and 'to', a
-- derived instance was 2,150 bytes of object code per field once 'singleField' was
-- out of line; with this it was 790 in a module of twelve records, of which about 700
-- were the field decoders inlined into the module, and under 100 with those out of
-- line too.  With each field taking its type's 'fieldRowDecoder', it is 67 in the
-- full program of scripts/code-size.sh.  A tuple's composition is compiled here once
-- (the comment above the tuple instances), and so is a hand-written one (the comment
-- above 'RowDecoder''s instances).
--
-- A 'GDecoder' is the decoder of a type coercible to the representation type, so
-- that the 'M1' and 'K1' wrappers cost nothing.  They are newtypes, but a 'RowDecoder'
-- can't be coerced across them, because its result type is nominal through 'Stream',
-- so the coercion is kept here and applied to the values, in the product's combining
-- function and at the record before 'to'.  Mapping each wrapper over its field's
-- decoder instead gave each field three layers of composition.
data GDecoder f p = forall a. Coercible a (f p) => GDecoder (RowDecoder a)

class GRowDecoder f where
  gRowDecoder :: GDecoder f p
instance (GRowDecoder f, GRowDecoder g) => GRowDecoder (f :*: g) where
  gRowDecoder :: forall p. GDecoder (f :*: g) p
  gRowDecoder = case gRowDecoder @f @p of
    GDecoder da -> case gRowDecoder @g @p of
      GDecoder db -> GDecoder (productDecoder da db :: RowDecoder ((f :*: g) p))
  {-# INLINE gRowDecoder #-}
instance GRowDecoder f => GRowDecoder (M1 i c f) where
  gRowDecoder :: forall p. GDecoder (M1 i c f) p
  gRowDecoder = case gRowDecoder @f @p of GDecoder d -> GDecoder d
  {-# INLINE gRowDecoder #-}
instance FromSqlField a => GRowDecoder (K1 i a) where
  gRowDecoder = GDecoder (fieldRowDecoder @a)
  {-# INLINE gRowDecoder #-}

-- The combining function is inside, where it is one closure.  Given to 'liftA2' at
-- each product as '(:*:)' cast, GHC eta-expanded it into a closure per product, and
-- out of line on its own it was worker-wrappered into a wrapper per product.
productDecoder :: forall a b f g p. (Coercible a (f p), Coercible b (g p))
  => RowDecoder a -> RowDecoder b -> RowDecoder ((f :*: g) p)
productDecoder = liftRow (\a b -> coerce a :*: coerce b)
{-# NOINLINE productDecoder #-}

-- Out of line so that 'to' is called, not copied into the row's recipe.
recordDecoder :: (a -> b) -> RowDecoder a -> RowDecoder b
recordDecoder = mapRow
{-# NOINLINE recordDecoder #-}

-- | A row decoder that runs per row, so later columns can depend on earlier values
-- or on the columns themselves ('remainingColumns').  Each row must read all the
-- columns.  Its checks run per row, so an empty result set isn't checked at all.
newtype RowDecoderMonadic a = RowDecoderMonadic
  { runRowDecoderMonadic :: TdsContext -> ResultSetInfo -> Int -> B.ByteString -> Int
      -> Parser (Either ReadFailure a, Int)
  }

instance Functor RowDecoderMonadic where
  fmap f (RowDecoderMonadic d) = RowDecoderMonadic $ \ctx rs ahead bitmap i -> do
    (r, j) <- d ctx rs ahead bitmap i
    pure (fmap f r, j)

instance Applicative RowDecoderMonadic where
  pure a = RowDecoderMonadic $ \_ _ _ _ i -> pure (Right a, i)
  mf <*> ma = mf >>= \f -> fmap f ma

instance Monad RowDecoderMonadic where
  RowDecoderMonadic d >>= k = RowDecoderMonadic $ \ctx rs ahead bitmap i -> do
    (r, j) <- d ctx rs ahead bitmap i
    case r of
      Left err -> pure (Left err, j)
      Right a -> runRowDecoderMonadic (k a) ctx rs ahead bitmap j

-- | Decode the next column with this field decoder.
singleFieldM :: FieldDecoder a -> RowDecoderMonadic a
singleFieldM = toMonadicRowDecoder . singleField

-- | The columns not yet read.
remainingColumns :: RowDecoderMonadic [ColumnInfo]
remainingColumns = RowDecoderMonadic $ \_ rs _ _ i -> pure (Right (drop i (rsColumns rs)), i)

-- | Read the next columns with a 'RowDecoder'.
toMonadicRowDecoder :: RowDecoder a -> RowDecoderMonadic a
toMonadicRowDecoder dec = RowDecoderMonadic $ \ctx rs ahead bitmap i -> do
  let n = numExpectedColumns dec
      remaining = max 0 (rsColumnCount rs - i)
  if remaining < n then pure (Left (DecodeFailed (DecodeError Nothing
      (if remaining == 0 && n == 1 then "no more columns" else
       "result has " ++ show remaining ++ " column(s) but the row type expects " ++ show n))), i)
    else case compileRowAt dec ctx rs i of
      Left err -> pure (Left (DecodeFailed err), i)
      Right (RowPart prepare) | Prepared read <- prepare ahead -> do
        result <- P.attempt (P.withEnv bitmap read)
        pure $ case result of
          -- The cell that failed read past the rest of the row.
          Left err -> (Left err, rsColumnCount rs)
          Right value -> (Right value, i + n)

-- | Decode the remaining columns as 'SqlValue's, keeping their 'ColumnInfo's.
sqlRowDecoder :: RowDecoderMonadic SqlRow
sqlRowDecoder = do
  cols <- remainingColumns
  SqlRow cols <$> mapM (const (singleFieldM sqlValueDecoder)) cols

-- | Prepare a 'RowDecoderMonadic' to read rows.  A failed conversion or a wrong
-- column count is reported once the rest of the row has been read past, so the
-- following rows can still be read.
compileMonadicRowDecoder :: RowDecoderMonadic a -> TdsContext -> [ColumnInfo] -> CompiledRow a
compileMonadicRowDecoder dec ctx cols = CompiledRow $ \ahead -> Prepared $ do
  bitmap <- rowBitmap n
  (result, consumed) <- runRowDecoderMonadic dec ctx rs ahead bitmap 0
  skipCells bitmap (drop consumed (rsCells rs))
  case result of
    Left err -> P.failValue err
    Right a | consumed == n -> pure a
    Right _ -> P.failValue $ DecodeFailed $ DecodeError Nothing $
      "result has " ++ show n ++ " column(s) but the row decoder consumed " ++ show consumed
  where
    rs = compileResultSet cols
    n = rsColumnCount rs

-- | A non-NULL value's bytes as they arrive, with its column and its total length
-- if the server sent it.  A chunk is safe to keep.  The stream is valid only
-- inside its consumer, and bytes the consumer doesn't read are skipped.
data ValueStream = ValueStream
  { valueColumn :: !ColumnInfo
  , valueLength :: !(Maybe Int64)
  , valueChunks :: Stream (Of B.ByteString) IO ()
  }

-- | A decoder that gives any non-NULL value to a consumer as it arrives, so a large
-- value needn't be in memory.  A NULL is a 'DecodeError' unless the decoder is
-- wrapped in 'nullableField'.  The consumer runs on the thread reading the rows.
-- Reading this stream twice or after the consumer returns throws
-- 'Hmssql.Errors.ResultAbandoned'. On a plain connection, the consumer
-- must not use the connection; on MARS it may use other responses.
streamField :: (ValueStream -> IO a) -> FieldDecoder a
streamField use = FieldDecoder $ \_ col -> Right $ StreamingCell $ \case
  StreamedNull -> pure (Left (DecodeFailed (DecodeError (Just (columnName col)) "SQL NULL cannot be streamed; use nullableField")))
  StreamedWhole bytes -> maybe (Left ReadDiscarded) Right
    <$> P.consumeWhole (P.keepBytes bytes) (use . ValueStream col (Just (fromIntegral (B.length (P.valueBytes bytes)))))
  StreamedBytes total chunks -> maybe (Left ReadDiscarded) Right <$> P.consume chunks (use . ValueStream col total)

-- | 'streamField' for character and XML columns, as 'Text' chunks.  A column whose
-- encoding can't be decoded is rejected before any row is read.
streamTextField :: (ColumnInfo -> Stream (Of Text) IO () -> IO a) -> FieldDecoder a
streamTextField use = FieldDecoder $ \ctx col -> do
  encoding <- textEncodingOf (columnType col)
  compileField (streamField (\v -> use col (decodeTextChunks encoding (valueChunks v)))) ctx col

decodeTextChunks :: Monad m => TextEncoding -> Stream (Of B.ByteString) m r -> Stream (Of Text) m r
decodeTextChunks TextUtf16 = Utf16.decodeUtf16Chunks
decodeTextChunks (TextCodec codec) = decodeCodecChunks codec

-- | Read past each row of a result set without decoding it or keeping its values
-- in memory.
skipRowDecoder :: [ColumnInfo] -> CompiledRow ()
skipRowDecoder cols =
  let info = compileResultSet cols
   in CompiledRow $ \_ -> Prepared $ do
        bitmap <- rowBitmap (rsColumnCount info)
        skipCells bitmap (rsCells info)

-- | Read and decode one value, given the column, its decoder, the column's
-- 'Hmssql.Connection.connectValueAllocAhead' and the value's header.  A value that
-- doesn't decode fails the recipe ('P.failValue') once its bytes have been read.
readCellRecipe :: ColumnInfo -> CellDecoder a -> Int -> Cell -> Parser a
readCellRecipe col decoder ahead cell = case decoder of
  CellDecoder onNull borrowed owned -> whole onNull borrowed owned
  FoldingCell onNull borrowed owned fold
    | withinLimit cell -> whole onNull borrowed owned
    | otherwise -> foldingCellRecipe col onNull borrowed owned fold ahead cell
  StreamingCell read -> streamingCellRecipe col read ahead cell
  where
    -- Both uses are in tail position, so this is a join point, compiled once.
    whole onNull borrowed owned = case cell of
      -- The common case, a value of known length, goes straight to its conversion.
      Sized n -> P.convertBytes ahead n (failed . borrowed) (failed . owned)
      _ -> do
        value <- wholeValueBytes ahead cell
        case value of
          -- A drain took over while this value was being assembled.  The row has no
          -- result now, and the drain ignores this one.
          DiscardedValue -> P.failValue ReadDiscarded
          NullValue -> named onNull
          PresentValue (P.Borrowed bytes) -> named (borrowed bytes)
          PresentValue (P.Owned bytes) -> named (owned bytes)
    failed = either (Left . DecodeFailed . DecodeError (Just (columnName col))) Right
    named = either P.failValue pure . failed
{-# INLINE readCellRecipe #-}

-- A value read whole, converted.
presentCell :: ColumnInfo -> Either String a -> ValueReader a -> ValueReader a -> WholeValue -> Parser a
presentCell col onNull borrowed owned = \case
  -- A drain took over while this value was being assembled.  The row has no
  -- result now, and the drain ignores this one.
  DiscardedValue -> P.failValue ReadDiscarded
  NullValue -> named onNull
  PresentValue (P.Borrowed bytes) -> named (borrowed bytes)
  PresentValue (P.Owned bytes) -> named (owned bytes)
  where named = either P.failValue pure . failed col
{-# INLINE presentCell #-}

failed :: ColumnInfo -> Either String a -> Either ReadFailure a
failed col = either (Left . DecodeFailed . DecodeError (Just (columnName col))) Right
{-# INLINE failed #-}

-- Whether a value is NULL or of a length known to be within 'streamWholeLimit'.
withinLimit :: Cell -> Bool
withinLimit = \case
  Sized n -> n <= streamWholeLimit
  Unsized (Just total) -> total <= fromIntegral streamWholeLimit
  Unsized Nothing -> False
  NullCell -> True
{-# INLINE withinLimit #-}

-- The reading of a value past the limit or of a total not sent, by a folding cell,
-- and of any value by a streaming one, out of line: each is read in one place,
-- rather than in every copy of 'readCellRecipe', since its value is a long one,
-- whose reading costs far more than the call.  Inlined there, with 'boundedValue',
-- they made "Hmssql.Decoding" 62 KB larger.  A folding cell's short value is read
-- by 'readCellRecipe' itself: through a call here, a short @nvarchar(max)@ into
-- 'Text' allocated 96 bytes more.
foldingCellRecipe :: ColumnInfo -> Either String a -> ValueReader a -> ValueReader a
  -> (Stream (Of B.ByteString) Parser () -> Parser (Either ReadFailure a)) -> Int -> Cell -> Parser a
foldingCellRecipe col onNull borrowed owned fold ahead cell = boundedValue ahead streamWholeLimit cell >>= \case
  Right value -> presentCell col onNull borrowed owned value
  Left chunks -> fold chunks >>= either P.failValue pure
{-# NOINLINE foldingCellRecipe #-}

streamingCellRecipe :: ColumnInfo -> (StreamedValue -> Parser (Either ReadFailure a)) -> Int -> Cell -> Parser a
streamingCellRecipe _ read ahead cell = streamed >>= read >>= either P.failValue pure
  where
    streamed = boundedValue ahead streamWholeLimit cell >>= \case
      Right NullValue -> pure StreamedNull
      Right (PresentValue bytes) -> pure (StreamedWhole bytes)
      Right DiscardedValue -> P.failValue ReadDiscarded
      Left chunks -> pure (StreamedBytes (cellLength cell) chunks)
{-# NOINLINE streamingCellRecipe #-}

-- | Decode a stream of a character column's bytes to 'Text' chunks, or why the
-- column's encoding can't be decoded.
decodeColumnChunks :: Monad m => TypeInfo -> Either String (Stream (Of B.ByteString) m r -> Stream (Of Text) m r)
decodeColumnChunks ti = decodeTextChunks <$> textEncodingOf ti
