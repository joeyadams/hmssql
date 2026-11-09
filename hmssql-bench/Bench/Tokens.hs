{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Synthetic result sets, as the bytes of a server's response, for the
-- benchmarks that decode without a server ("Bench.Decode", "Bench.Mock"):
-- COLMETADATA, one ROW (or NBCROW) token per row, and a final DONE.  Each
-- 'Dataset' also carries a typed decoder, so the same bytes are measured
-- raw, typed and as 'SqlRow'.
module Bench.Tokens
  ( -- * Datasets
    Dataset (..)
  , Typed (..)
  , datasets
  , responseBody
  , Output (..)
  , outputs
  , valueOutputs

    -- * Parsing as the connection does
  , packetPayloads
  , framedResponse
  , tokens
  , walked
  , decodeRows
  , sqlRowCompiler
  , tokenBytes
  ) where

import Control.DeepSeq (NFData (..))
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (setBit)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int16, Int32, Int64)
import qualified Data.List as List
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import qualified Streaming.Prelude as S

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Decoding
import Hmssql.Encoding (encodeParam, ParamValue (..))
import Hmssql.Tds.Context
import Hmssql.Tds.Packet (PacketStatus (..), PacketType (..), headerLength, splitIntoPackets)
import Hmssql.Tds.Primitives
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Reader (rowReader)
import Hmssql.Tds.Token (Token (..), readToken, compileResultSet)
import Hmssql.Tds.TypeInfo (RawBytes, maxLength, putTypeInfo, putValue)

------------------------------------------------------------------------------
-- NFData for the decoded values the library doesn't give one

instance NFData Money where
  rnf (Money m) = rnf m

instance NFData DateTimeOffset where
  rnf (DateTimeOffset u o) = rnf u `seq` rnf o

instance NFData SqlValue where
  -- Every constructor's field is strict, and the decoders evaluate what
  -- they build; WHNF of the field is what is left to force.
  rnf v = v `seq` ()

instance NFData SqlRow where
  rnf (SqlRow _ vals) = rnf vals

------------------------------------------------------------------------------
-- Datasets

data IntRow = IntRow !Int32 !Int64
  deriving stock (Generic)
  deriving anyclass (NFData, FromSqlRow)

data NullableRow = NullableRow !(Maybe Int32) !(Maybe Text) !(Maybe Decimal) !(Maybe LocalTime) !(Maybe Int64)
  deriving stock (Generic)
  deriving anyclass (NFData, FromSqlRow)

-- deepseq supplies tuple instances only through arity nine. These erased
-- wrappers force every field without allocating a replacement list or record.
newtype IntTuple10 = IntTuple10 (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)
instance NFData IntTuple10 where
  rnf (IntTuple10 (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9)) = a0 `seq` a1 `seq` a2 `seq` a3 `seq` a4 `seq` a5 `seq` a6 `seq` a7 `seq` a8 `seq` a9 `seq` ()

newtype IntTuple11 = IntTuple11 (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)
instance NFData IntTuple11 where
  rnf (IntTuple11 (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)) = a0 `seq` a1 `seq` a2 `seq` a3 `seq` a4 `seq` a5 `seq` a6 `seq` a7 `seq` a8 `seq` a9 `seq` a10 `seq` ()

newtype IntTuple12 = IntTuple12 (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)
instance NFData IntTuple12 where
  rnf (IntTuple12 (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)) = a0 `seq` a1 `seq` a2 `seq` a3 `seq` a4 `seq` a5 `seq` a6 `seq` a7 `seq` a8 `seq` a9 `seq` a10 `seq` a11 `seq` ()

-- | A column: its name, wire type, whether it is nullable, and its value in
-- row @i@ (from 1).
data Column = Column Text TypeInfo Bool (Int -> RawBytes)

-- | A decoder for a dataset's rows, with the 'NFData' of what it builds.
data Typed = forall a. NFData a => Typed String (RowDecoder a)

-- | A date and time value's parts: the modified Julian day, the picoseconds and the
-- offset in minutes.
data Parts = Parts !Int !Int64 !Int16
  deriving stock (Generic)
  deriving anyclass (NFData)

dayTimeParts :: FieldDecoder Parts
dayTimeParts = dayTimeFieldDecoder "Parts" (\d ps -> Parts (fromInteger (toModifiedJulianDay d)) ps 0)
{-# INLINE dayTimeParts #-}

offsetParts :: FieldDecoder Parts
offsetParts = dateTimeOffsetFieldDecoder "Parts" (\d ps m -> Parts (fromInteger (toModifiedJulianDay d)) ps m)
{-# INLINE offsetParts #-}

-- An integer from its little-endian bytes, as an application might read one.
int32Bytes :: FieldDecoder Int32
int32Bytes = fieldDecoderFor "i32" (const True) (\_ _ b -> Right $! B.foldr (\w a -> a * 256 + fromIntegral w) 0 b)
{-# INLINE int32Bytes #-}
int64Bytes :: FieldDecoder Int64
int64Bytes = fieldDecoderFor "i64" (const True) (\_ _ b -> Right $! B.foldr (\w a -> a * 256 + fromIntegral w) 0 b)
{-# INLINE int64Bytes #-}
int32Row :: RowDecoder Int32
int32Row = inlinedField int32Bytes
{-# NOINLINE int32Row #-}
int64Row :: RowDecoder Int64
int64Row = inlinedField int64Bytes
{-# NOINLINE int64Row #-}

int32NullableRow, int32MaybeRow :: RowDecoder (Maybe Int32)
int32NullableRow = inlinedField (nullableField int32Bytes)
{-# NOINLINE int32NullableRow #-}
int32MaybeRow = inlinedNullableField int32Bytes
{-# NOINLINE int32MaybeRow #-}
int64NullableRow, int64MaybeRow :: RowDecoder (Maybe Int64)
int64NullableRow = inlinedField (nullableField int64Bytes)
{-# NOINLINE int64NullableRow #-}
int64MaybeRow = inlinedNullableField int64Bytes
{-# NOINLINE int64MaybeRow #-}

-- A column's value through its type's own row decoder, chosen by its type.
typedValue :: ColumnInfo -> RowDecoder SqlValue
typedValue col = case columnType col of
  TIInt4 -> SqlInt32 <$> fieldRowDecoder
  TIInt8 -> SqlInt64 <$> fieldRowDecoder
  TINVarChar _ _ -> SqlText <$> fieldRowDecoder
  TIDecimalN _ _ -> SqlDecimal <$> fieldRowDecoder
  TIDateTime2N _ -> SqlDateTime <$> fieldRowDecoder
  _ -> singleField sqlValueDecoder

-- A large value's decoders as an application writes them: every chunk kept and
-- joined, so that what is measured is the streaming itself.
streamedText :: RowDecoder Text
streamedText = singleField (streamTextField (\_ chunks -> T.concat <$> S.toList_ chunks))
streamedBytes :: RowDecoder B.ByteString
streamedBytes = singleField (streamField (\v -> B.concat <$> S.toList_ (valueChunks v)))

-- A pure fold over a value's chunks, as a 'StreamingCell' written by hand: the
-- value's length, with no consumer and so no 'IO'.
foldedBytes :: RowDecoder Int
foldedBytes = singleField $ fieldDecoderCompiled $ \_ _ -> Right $ StreamingCell $ \case
  StreamedNull -> pure (Left (DecodeFailed (DecodeError Nothing "NULL")))
  StreamedWhole b -> pure (Right (B.length (P.valueBytes b)))
  StreamedBytes _ chunks -> Right <$> S.fold_ (\n b -> n + B.length b) 0 id chunks

dayTimeRow, offsetRow :: RowDecoder Parts
dayTimeRow = inlinedField dayTimeParts
{-# NOINLINE dayTimeRow #-}
offsetRow = inlinedField offsetParts
{-# NOINLINE offsetRow #-}

data Dataset = Dataset
  { dsName :: String
    -- ^ Stable, used in benchmark names.
  , dsColumns :: [Column]
  , dsRows :: Int
  , dsNbcRow :: Bool
    -- ^ Send rows as NBCROW (null bitmap) rather than ROW.
  , dsTyped :: Typed
  }

-- | The result sets the decoding benchmarks read.  Row counts keep each
-- response between a few hundred KB and a few MB.
datasets :: [Dataset]
datasets =
  [ Dataset "int bigint x10000" [intCol "i", bigintCol "b"] 10_000 False
      (Typed "(Int32, Int64)" (rowDecoder @(Int32, Int64)))
  , Dataset "nvarchar(50) x10000" [nvarcharCol "s" 50 shortText] 10_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "nvarchar(50) CJK x10000" [nvarcharCol "s" 50 cjkText] 10_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "nvarchar(1000) x1000" [nvarcharCol "s" 1000 (\i -> T.replicate 100 (T.pack (show (i `mod` 10))) <> T.replicate 900 "x")] 1_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "varchar(100) cp1252 x10000" [varcharCol "s" latin1 cp1252Text] 10_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "varchar(100) utf8 x10000" [varcharCol "s" utf8Collation utf8Text] 10_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "decimal(18,4) x10000" [decimalCol "d" False] 10_000 False
      (Typed "Only Decimal" (rowDecoder @(Only Decimal)))
  , Dataset "datetime2 datetimeoffset x10000" [datetime2Col "t" False, datetimeoffsetCol "o"] 10_000 False
      (Typed "(LocalTime, DateTimeOffset)" (rowDecoder @(LocalTime, DateTimeOffset)))
  , Dataset "uniqueidentifier x10000" [guidCol "g"] 10_000 False
      (Typed "Only UUID" (rowDecoder @(Only UUID)))
  , Dataset "nvarchar(max) short x10000" [Column "s" (TINVarChar maxLength latin1) False (Just . utf16 . shortText)] 10_000 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "varbinary(max) 4MB x1" [Column "b" (TIBigVarBinary maxLength) False (\_ -> Just (B.replicate (4 * 1024 * 1024) 0x78))] 1 False
      (Typed "Only ByteString" (rowDecoder @(Only B.ByteString)))
  , Dataset "nvarchar(max) 4MB x1" [Column "s" (TINVarChar maxLength latin1) False (\_ -> Just (utf16 (T.replicate (2 * 1024 * 1024) "y")))] 1 False
      (Typed "Only Text" (rowDecoder @(Only Text)))
  , Dataset "nvarchar(max) short streamed x10000" [Column "s" (TINVarChar maxLength latin1) False (Just . utf16 . shortText)] 10_000 False
      (Typed "streamTextField" streamedText)
  , Dataset "varbinary(max) short x10000" [Column "b" (TIBigVarBinary maxLength) False (Just . T.encodeUtf8 . shortText)] 10_000 False
      (Typed "Only ByteString" (rowDecoder @(Only B.ByteString)))
  , Dataset "varbinary(max) short streamed x10000" [Column "b" (TIBigVarBinary maxLength) False (Just . T.encodeUtf8 . shortText)] 10_000 False
      (Typed "streamField" streamedBytes)
  , Dataset "varbinary(max) short folded x10000" [Column "b" (TIBigVarBinary maxLength) False (Just . T.encodeUtf8 . shortText)] 10_000 False
      (Typed "StreamingCell fold" foldedBytes)
  , Dataset "varbinary(max) 4MB folded x1" [Column "b" (TIBigVarBinary maxLength) False (\_ -> Just (B.replicate (4 * 1024 * 1024) 0x78))] 1 False
      (Typed "StreamingCell fold" foldedBytes)
  , Dataset "varbinary(max) 4MB streamed x1" [Column "b" (TIBigVarBinary maxLength) False (\_ -> Just (B.replicate (4 * 1024 * 1024) 0x78))] 1 False
      (Typed "streamField" streamedBytes)
  , Dataset "nvarchar(max) 4MB streamed x1" [Column "s" (TINVarChar maxLength latin1) False (\_ -> Just (utf16 (T.replicate (2 * 1024 * 1024) "y")))] 1 False
      (Typed "streamTextField" streamedText)
  , Dataset "nullable half NULL NBCROW x10000" nullableCols 10_000 True
      (Typed "Maybe x5" (rowDecoder @(Maybe Int32, Maybe Text, Maybe Decimal, Maybe LocalTime, Maybe Int64)))
  , Dataset "nullable no NULL ROW x10000" (map noNulls nullableCols) 10_000 False
      (Typed "Maybe x5" (rowDecoder @(Maybe Int32, Maybe Text, Maybe Decimal, Maybe LocalTime, Maybe Int64)))
  , Dataset "50 columns x1000" wideCols 1_000 False
      (Typed "[SqlValue] (applicative)" (sequenceA (replicate 50 (singleField sqlValueDecoder))))
    -- The same row with each column's decoder chosen by its type, as a program that
    -- builds its queries at runtime would have it, through the types' own row decoders.
  , Dataset "50 columns byColumn x1000" wideCols 1_000 False
      (Typed "[SqlValue] (byColumn)" (traverse (const (byColumn typedValue)) (replicate 50 ())))
    -- The same rows as two of the above, into records with derived instances, which
    -- compose their fields through the generic decoder rather than a tuple's.
  , Dataset "int bigint record x10000" [intCol "i", bigintCol "b"] 10_000 False
      (Typed "IntRow" (rowDecoder @IntRow))
  , Dataset "nullable half NULL NBCROW record x10000" nullableCols 10_000 True
      (Typed "NullableRow" (rowDecoder @NullableRow))
    -- The same rows again, with a decoder composed by hand from 'singleField', as an
    -- application writes one for 'queryWith': RowDecoder's own Functor and
    -- Applicative instances rather than a tuple's or the generic composition.
  , Dataset "int bigint applicative x10000" [intCol "i", bigintCol "b"] 10_000 False
      (Typed "(Int32, Int64) (applicative)" ((,) <$> singleField (fieldDecoder @Int32) <*> singleField (fieldDecoder @Int64)))
  , Dataset "nullable half NULL NBCROW applicative x10000" nullableCols 10_000 True
      (Typed "Maybe x5 (applicative)"
        ((,,,,) <$> singleField (fieldDecoder @(Maybe Int32)) <*> singleField (fieldDecoder @(Maybe Text))
          <*> singleField (fieldDecoder @(Maybe Decimal)) <*> singleField (fieldDecoder @(Maybe LocalTime))
          <*> singleField (fieldDecoder @(Maybe Int64))))
  ] ++
  -- Keep wide tuples separate from the 50-column list decoder. Each arity
  -- exercises its own shared applicative worker and its caller-side wrapper.
  [ Dataset ("tuple" ++ show n ++ " int x10000")
      [intCol ("i" <> tshow i) | i <- [1 .. n]] 10_000 False typed
  | (n, typed) <-
      [ (7 :: Int, Typed "tuple7" (rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      , (8, Typed "tuple8" (rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      , (9, Typed "tuple9" (rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      , (10, Typed "tuple10" (IntTuple10 <$> rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      , (11, Typed "tuple11" (IntTuple11 <$> rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      , (12, Typed "tuple12" (IntTuple12 <$> rowDecoder @(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)))
      ]
  ] ++
  [ Dataset "refineField int x10000" [intCol "i"] 10_000 False
      (Typed "refined Int32" (singleField (refineField nonnegative (fieldDecoder @Int32))))
    -- The rows of "int bigint x10000" through decoders of the bytes as an application
    -- writes them ('fieldDecoderFor'), through 'singleField' and through 'inlinedField',
    -- whose copy of the cell's read takes the conversion inline.
  , Dataset "int bigint fieldDecoderFor x10000" [intCol "i", bigintCol "b"] 10_000 False
      (Typed "(Int32, Int64) (singleField)" ((,) <$> singleField int32Bytes <*> singleField int64Bytes))
  , Dataset "int bigint fieldDecoderFor inlined x10000" [intCol "i", bigintCol "b"] 10_000 False
      (Typed "(Int32, Int64) (inlinedField)" ((,) <$> int32Row <*> int64Row))
    -- The same integers nullable, half the rows NULL in one column or the other: through
    -- 'singleField', through 'inlinedField' of 'nullableField', and through
    -- 'inlinedNullableField', which handles the NULL in the copy.
  , Dataset "nullable int bigint fieldDecoderFor x10000" nullableInts 10_000 True
      (Typed "Maybe (Int32, Int64) (singleField)" ((,) <$> singleField (nullableField int32Bytes) <*> singleField (nullableField int64Bytes)))
  , Dataset "nullable int bigint fieldDecoderFor inlined x10000" nullableInts 10_000 True
      (Typed "Maybe (Int32, Int64) (inlinedField . nullableField)" ((,) <$> int32NullableRow <*> int64NullableRow))
  , Dataset "nullable int bigint fieldDecoderFor inlinedNullable x10000" nullableInts 10_000 True
      (Typed "Maybe (Int32, Int64) (inlinedNullableField)" ((,) <$> int32MaybeRow <*> int64MaybeRow))
    -- The rows of "datetime2 datetimeoffset x10000" from their parts, as an
    -- application that writes the values out reads them, through each path.
  , Dataset "datetime2 datetimeoffset parts x10000" [datetime2Col "t" False, datetimeoffsetCol "o"] 10_000 False
      (Typed "Parts x2 (singleField)" ((,) <$> singleField dayTimeParts <*> singleField offsetParts))
  , Dataset "datetime2 datetimeoffset parts inlined x10000" [datetime2Col "t" False, datetimeoffsetCol "o"] 10_000 False
      (Typed "Parts x2 (inlinedField)" ((,) <$> dayTimeRow <*> offsetRow))
  ]
  where
    nonnegative x = if x >= 0 then Right x else Left "negative benchmark value"
    nullableInts =
      [ nullable 2 (Column "ni" (TIIntN 4) True (Just . int32))
      , nullable 3 (Column "nb" (TIIntN 8) True (Just . int64))
      ]
    nullableCols =
      [ nullable 2 (Column "ni" (TIIntN 4) True (Just . int32))
      , nullable 3 (nvarcharCol "ns" 50 shortText)
      , nullable 2 (decimalCol "nd" True)
      , nullable 3 (datetime2Col "nt" True)
      , nullable 2 (Column "nb" (TIIntN 8) True (Just . int64))
      ]
    -- NULL in every @k@th row, so most rows have some NULLs and some
    -- values; without NULLs, rows whose number no @k@ divides.
    nullable k (Column n ti _ f) = Column n ti True (\i -> if i `mod` k == 0 then Nothing else f i)
    noNulls (Column n ti _ f) = Column n ti True (\i -> f (i * 6 + 1))
    wideCols = concat
      [ [ Column ("i" <> tshow j) TIInt4 False (Just . int32 . (+ j))
        , Column ("b" <> tshow j) TIInt8 False (Just . int64 . (+ j))
        , nvarcharCol ("s" <> tshow j) 20 shortText
        , decimalCol ("d" <> tshow j) False
        , datetime2Col ("t" <> tshow j) False
        ]
      | j <- [1 .. 10]
      ]

intCol, bigintCol, guidCol, datetimeoffsetCol :: Text -> Column
intCol n = Column n TIInt4 False (Just . int32)
bigintCol n = Column n TIInt8 False (\i -> Just (int64 (i * 1_000_000_007)))
guidCol n = Column n TIGuid False (\i -> Just (put (putGuid (UUID.fromWords 0x12345678 (fromIntegral i) 0x9abcdef0 (fromIntegral (i * 7))))))
datetimeoffsetCol n = Column n (TIDateTimeOffsetN 7) False $ \i ->
  Just (putOrDie (putDateTimeOffset 7 (DateTimeOffset (UTCTime (fromGregorian 2026 1 1) (fromIntegral (i `mod` 86400) + 0.1234567)) 120)))

nvarcharCol :: Text -> Word16 -> (Int -> Text) -> Column
nvarcharCol n len f = Column n (TINVarChar (2 * len) latin1) False (Just . utf16 . f)

varcharCol :: Text -> Collation -> (Int -> Text) -> Column
varcharCol n coll f = Column n (TIBigVarChar 100 coll) False (Just . enc . f)
  where
    enc t
      | coll == utf8Collation = T.encodeUtf8 t
      | otherwise = B.pack (map (fromIntegral . fromEnum) (T.unpack t))  -- Latin-1 subset of cp1252

decimalCol :: Text -> Bool -> Column
decimalCol n nullableType = Column n (TIDecimalN 18 4) nullableType $ \i ->
  Just (put (putDecimal 18 4 (Decimal 4 (fromIntegral i * 12_345_678 - 5_000_000_000 :: Integer))))

datetime2Col :: Text -> Bool -> Column
datetime2Col n nullableType = Column n (TIDateTime2N 7) nullableType $ \i ->
  Just (putOrDie (putDateTime2 7 (LocalTime (addDays (fromIntegral (i `mod` 3650)) (fromGregorian 2020 1 1)) (TimeOfDay 12 34 56.1234567))))

shortText, cjkText, cp1252Text, utf8Text :: Int -> Text
shortText i = "name-" <> tshow i
cjkText i = "\26085\26412\35486\12398\21517\21069\12486\12461\12473\12488" <> tshow i
cp1252Text i = "Caf\233 cr\232me br\251l\233e n\186 " <> tshow i
utf8Text i = "Stra\223e \8364 \26085\26412 " <> tshow i

-- | SQL_Latin1_General_CP1_CI_AS (code page 1252).
latin1 :: Collation
latin1 = Collation 0x00D00409 0x34

-- | Latin1_General_100_CI_AS_SC_UTF8.
utf8Collation :: Collation
utf8Collation = Collation 0x04E00409 0

int32 :: Int -> B.ByteString
int32 = put . Put.putInt32le . fromIntegral

int64 :: Int -> B.ByteString
int64 = put . Put.putInt64le . fromIntegral

utf16 :: Text -> B.ByteString
utf16 = T.encodeUtf16LE

tshow :: Show a => a -> Text
tshow = T.pack . show

put :: Put -> B.ByteString
put = LB.toStrict . Put.runPut

putOrDie :: Either String Put -> B.ByteString
putOrDie = either error put

-- | A procedure's response with one large output parameter, as
-- 'Hmssql.callProcedure' reads it: a RETURNVALUE token, then a final
-- DONEPROC.
data Output = Output
  { outName :: String
    -- ^ Stable, used in benchmark names.
  , outBody :: B.ByteString
  }

outputs :: [Output]
outputs =
  [ Output "int" (outputBody (TIIntN 4) (Just (int32 42)))
  , Output "varbinary(max) 4MB" (outputBody (TIBigVarBinary maxLength) (Just (B.replicate (4 * 1024 * 1024) 0x78)))
  , Output "nvarchar(max) 4MB" (outputBody (TINVarChar maxLength latin1) (Just (utf16 (T.replicate (2 * 1024 * 1024) "y"))))
  ]

outputBody :: TypeInfo -> RawBytes -> B.ByteString
outputBody ti v = tokenBytes
  [ do Put.putWord8 0xAC
       Put.putWord16le 0      -- ordinal
       putBVarChar "@out"
       Put.putWord8 1         -- an output parameter
       Put.putWord32le 0      -- user type
       Put.putWord16le 0x0001 -- nullable
       putTypeInfo defaultTdsContext ti
       putValue defaultTdsContext ti v
  , do Put.putWord8 0xFE
       Put.putWord16le 0
       Put.putWord16le 0xE0   -- EXECUTE
       Put.putWord64le 0
  ]

-- Each SqlValue family travels through RETURNVALUE and the public output-value
-- decoder. Building the canned bytes happens before measurement; encoding the
-- request and decoding the returned value remain inside the measured action.
valueOutputs :: [(String, SqlValue, B.ByteString)]
valueOutputs = map make
  [ ("NULL", SqlNull), ("bit", SqlBool True), ("tinyint", SqlWord8 42)
  , ("smallint", SqlInt16 42), ("int", SqlInt32 42), ("bigint", SqlInt64 42)
  , ("real", SqlFloat 1.25), ("float", SqlDouble 1.25)
  , ("decimal", SqlDecimal (Decimal 4 123456)), ("money", SqlMoney (Money 12.3456))
  , ("uniqueidentifier", SqlGuid UUID.nil), ("date", SqlDate day)
  , ("time", SqlTime (TimeOfDay 12 34 56))
  , ("datetime2", SqlDateTime (LocalTime day (TimeOfDay 12 34 56)))
  , ("datetimeoffset", SqlDateTimeOffset (DateTimeOffset (UTCTime day 12345) 120))
  , ("nvarchar", SqlText "output value"), ("varbinary", SqlBinary "output bytes")
  , ("xml", SqlXml "<output/>")
  ]
  where
    day = fromGregorian 2026 1 1
    make (name, value) = case encodeParam (fieldEncoder @SqlValue) defaultTdsContext value of
      Right (ti, ParamBytes bytes) -> (name, value, outputBody ti bytes)
      _ -> error "The output benchmark requires a finite in-memory value."

------------------------------------------------------------------------------
-- Response bytes

-- | The response's token stream: COLMETADATA, the rows, DONE with a count.
responseBody :: Dataset -> B.ByteString
responseBody Dataset{..} = tokenBytes $
  colMetaData dsColumns
    : [ if dsNbcRow then nbcRow vals else row vals
      | i <- [1 .. dsRows]
      , let vals = [(ti, f i) | Column _ ti _ f <- dsColumns]
      ]
    ++ [done]

tokenBytes :: [Put] -> B.ByteString
tokenBytes = LB.toStrict . Put.runPut . sequence_

colMetaData :: [Column] -> Put
colMetaData cols = do
  Put.putWord8 0x81
  Put.putWord16le (fromIntegral (length cols))
  mapM_ column cols
  where
    column (Column name ti nullableCol _) = do
      Put.putWord32le 0
      Put.putWord16le (if nullableCol then 0x0001 else 0)
      putTypeInfo defaultTdsContext ti
      putBVarChar name

row :: [(TypeInfo, RawBytes)] -> Put
row vals = Put.putWord8 0xD1 >> mapM_ (uncurry (putValue defaultTdsContext)) vals

nbcRow :: [(TypeInfo, RawBytes)] -> Put
nbcRow vals = do
  Put.putWord8 0xD2
  let n = length vals
      nullAt = [i | (i, (_, v)) <- zip [0 ..] vals, not (isJust v)]
      bitmap = [List.foldl' setBit (0 :: Word8) [i `mod` 8 | i <- nullAt, i `div` 8 == j] | j <- [0 .. (n + 7) `div` 8 - 1]]
  mapM_ Put.putWord8 bitmap
  mapM_ (\(ti, v) -> maybe (pure ()) (const (putValue defaultTdsContext ti v)) v) vals

done :: Put
done = do
  Put.putWord8 0xFD
  Put.putWord16le 0x0010  -- DONE_COUNT
  Put.putWord16le 0xC1    -- SELECT
  Put.putWord64le 0

-- | The payloads of the 4096-byte packets the response arrives in, as the
-- connection hands them to the token parser.
packetPayloads :: B.ByteString -> [B.ByteString]
packetPayloads = map (B.drop headerLength) . framedResponse

-- | The response as the packets a server sends.
framedResponse :: B.ByteString -> [B.ByteString]
framedResponse = splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) . LB.fromStrict

------------------------------------------------------------------------------
-- Parsing

-- | Materialized tokens through the library's sole token recipe.
tokens :: TdsContext -> [B.ByteString] -> IO [Token]
tokens _ctx chunks = fst <$> P.parseChunks (go Nothing []) chunks
  where
    go cols acc = P.peekToken >>= \case
      Nothing -> pure (reverse acc)
      Just _ -> do
        token <- readToken cols
        let nextCols = case token of TColMetaData cs -> Just (compileResultSet cs); _ -> cols
        go nextCols (token : acc)

-- The old rows benchmark now exercises the same parser as tokens. Keep its
-- name and dataset for comparison; the second parser itself no longer exists.
walked :: TdsContext -> [B.ByteString] -> IO [Token]
walked = tokens

-- | Decode as the connection does, directly while the recipe reads each row.  The
-- row's recipe is 'rowReader''s, called from the loop as the connection's driver
-- calls it, with the failure caught here by 'P.attempt'.  'rowRecipe' is that
-- 'P.attempt' as a closure of its own around the row's recipe, one more unknown call
-- per row that the connection doesn't make, since its driver takes a row's failure
-- itself ('P.runParserAt').  Through 'rowRecipe', a typed @decimal(18,4)@ row here
-- took 1.11 times as long as through this loop (six alternating pairs, 2026-11-04),
-- which has the same calls as the row's recipe had when it caught its own failure.
decodeRows :: (TdsContext -> [ColumnInfo] -> Either DecodeError (CompiledRow a))
  -> TdsContext -> [B.ByteString] -> IO [a]
decodeRows compile ctx chunks = fst <$> P.parseChunks (go Nothing Nothing []) chunks
  where
    go cols decoder acc = P.peekToken >>= \case
      Nothing -> pure (reverse acc)
      Just code | code == 0xD1 || code == 0xD2 -> case decoder of
        Nothing -> fail "row before metadata"
        Just recipe -> do
          result <- P.attempt recipe
          case result of
            Left err -> error (show err)
            Right value -> go cols decoder (value : acc)
      Just _ -> readToken cols >>= \case
        TColMetaData cs -> case compile ctx cs of
          Left err -> error (show err)
          Right row -> go (Just (compileResultSet cs)) (Just (rowReader row 1048576)) acc
        _ -> go cols decoder acc

sqlRowCompiler :: TdsContext -> [ColumnInfo] -> Either DecodeError (CompiledRow SqlRow)
sqlRowCompiler ctx cols = compileRowDecoder (sqlRowDecoderFor cols) ctx cols
