{-# LANGUAGE ExistentialQuantification #-}
-- | Turning Haskell values into parameters.
--
-- 'ToSqlField' encodes one value as one parameter, with a fixed wire type
-- per Haskell type ("Hmssql.Types" has the table); 'ToSqlRow' encodes a
-- value as a list of parameters: a tuple, a record with a derived
-- instance, a list, 'Only', or 'NamedParams'.  A new 'ToSqlField'
-- instance is usually 'contramap' over an existing encoder; one that
-- must choose the wire type itself builds a 'FieldEncoder', or the
-- caller sends a 'RawParam'.  A large value can be read as it is sent, rather
-- than held in memory; see "Hmssql.Encoding#g:streaming".
module Hmssql.Encoding
  ( -- * Field encoders
    FieldEncoder (..)
  , ToSqlField (fieldEncoder)
  , RawParam (..)
  , SqlParam (..)
  , EncodedParam

    -- * Sending a large value #streaming#
    -- | A parameter is normally encoded into memory before it is sent.  'binaryStream'
    -- and 'textStream' instead read the value as it is sent, so a value of any size can
    -- come from a file or a socket without being held in memory:
    --
    -- > import qualified Data.ByteString as B
    -- > import Control.Monad (unless)
    -- > import Streaming (lift)
    -- > import qualified Streaming.Prelude as S
    -- > import System.IO (IOMode (..), withBinaryFile)
    -- >
    -- > fileSource :: FilePath -> Source B.ByteString
    -- > fileSource path = Source $ \use -> withBinaryFile path ReadMode (use . chunks)
    -- >   where
    -- >     chunks h = do
    -- >       chunk <- lift (B.hGetSome h 65536)
    -- >       unless (B.null chunk) (S.yield chunk >> chunks h)
    -- >
    -- > insertDocument :: Connection -> FilePath -> IO Int64
    -- > insertDocument conn path = execute conn $
    -- >   "INSERT INTO dbo.documents (payload) VALUES (" <> param (binaryStream (fileSource path)) <> ")"
    --
    -- A 'Source' opens what it needs when sending starts and closes it when sending ends,
    -- so a 'Hmssql.Query.Query' built on this one can be sent again.  'sourceOf' wraps a
    -- stream you already have, which can be sent only once.  These rules come with it:
    --
    -- * A source must not make a request on its own connection, which throws
    --   'Hmssql.Errors.ReentrantSource'.  On a MARS connection it may read a stream that
    --   was opened earlier.
    -- * If a source throws, the request is abandoned, the exception reaches the caller,
    --   and the connection stays usable.
    -- * An output parameter can't be streamed.
    --
    -- A lazy 'LB.ByteString' or 'LT.Text' parameter is read as it is sent too, without
    -- any of this.  To stream a large value in a result instead, see
    -- "Hmssql.Decoding#g:streaming".
  , ParamValue (..), Source (..), sourceOf, sourceIO
  , StreamParam (..), binaryStream, textStream, streamAs, lazyAs

    -- * Row encoders
  , RowEncoder (..)
  , ToSqlRow (..)
  , divideRow
  , singleParam
  , genericToSqlRow

    -- * Named parameters
  , NamedParam
  , NamedParams (..)
  ) where

import Data.Binary.Put (Put)
import Data.Bits (shiftR)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Functor.Contravariant (Contravariant (..))
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Time
import Data.Tuple.Only (Only (..))
import Data.UUID.Types (UUID)
import Data.Word (Word64, Word8)
import Foreign.Storable (pokeByteOff)
import GHC.Float (castDoubleToWord64, castFloatToWord32)
import GHC.Generics

import Hmssql.Tds.Parameter
import qualified Streaming.Prelude as S
import Hmssql.SqlValue (SqlValue (..))
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

-- | A parameter's wire type and value.
type EncodedParam = (TypeInfo, ParamValue)

-- | How a value of a type becomes one parameter: its wire type and bytes,
-- or why it can't be sent (what the query functions throw as
-- 'Hmssql.Errors.EncodeError').  The 'TdsContext' is the connection's,
-- for an encoding that depends on the negotiated protocol.
data FieldEncoder a = FieldEncoder
  { encodeParam :: TdsContext -> a -> Either String EncodedParam
  , nullParamType :: TdsContext -> TypeInfo
    -- ^ The type to declare when the value is NULL (@Nothing@ of the
    -- 'Maybe' instance).
  }

-- | An encoder of @b@ from an encoder of @a@ and a conversion: how most
-- 'ToSqlField' instances for a newtype or an enumeration are written.
--
-- > import Data.Functor.Contravariant (contramap)
-- >
-- > instance ToSqlField Status where
-- >   fieldEncoder = contramap statusText fieldEncoder
instance Contravariant FieldEncoder where
  contramap f (FieldEncoder enc nt) = FieldEncoder (\ctx -> enc ctx . f) nt

-- | Types that can be sent as one parameter, through 'Hmssql.Query.param'
-- or as a field of a 'ToSqlRow' value.  The usual Haskell types have
-- instances, and "Hmssql.Types" has the table of which SQL type each is
-- sent as.  An instance of your own defines 'fieldEncoder', usually with
-- 'Data.Functor.Contravariant.contramap' over a built-in type's encoder.
class ToSqlField a where
  fieldEncoder :: FieldEncoder a
  -- Not exported: how a derived 'ToSqlRow' instance holds a strict field of this
  -- type.  The 'Int32', 'Int64' and 'Double' instances hold it unpacked, and every
  -- other instance, including the ones applications write, keeps the default.
  fieldParam :: a -> FieldParams -> FieldParams
  fieldParam = FieldParam fieldEncoder
  {-# INLINE fieldParam #-}

instance ToSqlField a => ToSqlField (Maybe a) where
  fieldEncoder = maybeEncoder fieldEncoder

-- Out of line, and OPAQUE so that a use isn't a worker's result boxed again: inlined,
-- each module that sent a @Maybe Int32@ built its own encoder for it, and the derived
-- 'ToSqlRow' instances of code-size.sh --quick were 29,437 bytes of object code
-- instead of 28,965.  Encoding a parameter is then an unknown call of the inner
-- encoder, once per parameter.
maybeEncoder :: FieldEncoder a -> FieldEncoder (Maybe a)
maybeEncoder inner = FieldEncoder
  { encodeParam = \ctx -> \case
      Nothing -> Right (nullParamType inner ctx, ParamBytes Nothing)
      Just a -> encodeParam inner ctx a
  , nullParamType = nullParamType inner
  }
{-# OPAQUE maybeEncoder #-}

-- | Send a value with an explicit wire type.
newtype RawParam = RawParam (TypeInfo, RawBytes)

instance ToSqlField RawParam where
  fieldEncoder = FieldEncoder
    { encodeParam = \_ (RawParam (ti, bytes)) -> Right (ti, ParamBytes bytes)
    , nullParamType = const untypedNull
    }

-- | Any value with a 'ToSqlField' instance, so a parameter list can mix types.
data SqlParam = forall a. ToSqlField a => SqlParam a

instance ToSqlField SqlParam where
  fieldEncoder = FieldEncoder
    { encodeParam = \ctx (SqlParam a) -> encodeParam fieldEncoder ctx a
    , nullParamType = const untypedNull
    }

defaultCollation :: Collation
defaultCollation = Collation 0 0

-- | The type declared for a NULL whose SQL type isn't known: 'SqlNull', and
-- the NULL of 'Text', 'SqlParam' and 'RawParam' (so @Nothing :: Maybe Text@).
--
-- It is @nvarchar(max)@, so an expression typed by the parameter, such as
-- @ISNULL(\@p, col)@ with an @nvarchar(max)@ @col@, is not truncated.  The
-- server converts it implicitly to most column and operand types, but not
-- to @binary@, @varbinary@ or @image@ (declare those NULLs typed, e.g.
-- @Nothing :: Maybe ByteString@), and not to @sql_variant@: a NULL bound to
-- a @sql_variant@ column or parameter fails with error 206 (operand type
-- clash).  Bind a typed NULL there instead, e.g. @Nothing :: Maybe Int32@,
-- or @RawParam (TISqlVariant 8016, Nothing)@.
untypedNull :: TypeInfo
untypedNull = TINVarChar maxLength defaultCollation

-- | A little-endian integer type of @n@ bytes, written directly.
intType :: Integral a => TypeInfo -> Int -> FieldEncoder a
intType ti n = FieldEncoder
  { encodeParam = \_ a -> Right (ti, ParamBytes (Just (littleEndian n (fromIntegral a))))
  , nullParamType = const ti
  }
{-# INLINE intType #-}

-- | The low @n@ bytes of @w@, little-endian.
littleEndian :: Int -> Word64 -> B.ByteString
littleEndian n w = BI.unsafeCreate n $ \p ->
  let go i x
        | i >= n = pure ()
        | otherwise = pokeByteOff p i (fromIntegral x :: Word8) >> go (i + 1) (x `shiftR` 8)
   in go 0 w

-- | A type whose values are always @n@ bytes long.
fixedType :: TypeInfo -> Int -> (a -> Put) -> FieldEncoder a
fixedType ti n put = FieldEncoder
  { encodeParam = \_ a -> Right (ti, ParamBytes (Just (runPutSized n (put a))))
  , nullParamType = const ti
  }

-- | Like 'fixedType', for encoders that reject some values.
checkedType :: TypeInfo -> Int -> (a -> Either String Put) -> FieldEncoder a
checkedType ti n put = FieldEncoder
  { encodeParam = \_ a -> (\pt -> (ti, ParamBytes (Just (runPutSized n pt)))) <$> put a
  , nullParamType = const ti
  }

instance ToSqlField Bool where
  fieldEncoder = contramap fromEnum (intType TIBitN 1)

-- | @smallint@: @tinyint@ is unsigned, so it can't hold negative values.
instance ToSqlField Int8 where fieldEncoder = intType (TIIntN 2) 2
-- | @tinyint@.
instance ToSqlField Word8 where fieldEncoder = intType (TIIntN 1) 1
instance ToSqlField Int16 where fieldEncoder = intType (TIIntN 2) 2
instance ToSqlField Int32 where
  fieldEncoder = intType (TIIntN 4) 4
  fieldParam = Int32Param
  {-# INLINE fieldParam #-}
instance ToSqlField Int64 where
  fieldEncoder = intType (TIIntN 8) 8
  fieldParam = Int64Param
  {-# INLINE fieldParam #-}
instance ToSqlField Int where fieldEncoder = intType (TIIntN 8) 8

-- | @bigint@, or @decimal(38,0)@ beyond its range; values of 39 or more
-- digits are rejected.
instance ToSqlField Integer where
  fieldEncoder = FieldEncoder
    { encodeParam = \_ i -> if
        | i >= toInteger (minBound @Int64) && i <= toInteger (maxBound @Int64) ->
            Right (TIIntN 8, ParamBytes (Just (littleEndian 8 (fromInteger i))))
        | abs i < 10 ^ (38 :: Int) ->
            Right (TIDecimalN 38 0, ParamBytes (Just (runPutSized 17 (putDecimal 38 0 (Decimal 0 i)))))
        | otherwise ->
            Left $ "Integer value " ++ show i ++ " does not fit in decimal(38,0)"
    , nullParamType = const (TIIntN 8)
    }

instance ToSqlField Double where
  fieldEncoder = contramap castDoubleToWord64 (intType (TIFltN 8) 8)
  fieldParam = DoubleParam
  {-# INLINE fieldParam #-}
instance ToSqlField Float where fieldEncoder = contramap castFloatToWord32 (intType (TIFltN 4) 4)

-- | @decimal(p,s)@ with the value's own scale @s@ and just enough precision
-- @p@ for its digits (so 0.001 is @decimal(3,3)@, 1000000 @decimal(7,0)@).
-- Values needing more than 38 digits, or a scale above 38, are rejected.
instance ToSqlField Decimal where
  fieldEncoder = FieldEncoder
    { encodeParam = \_ d@(Decimal scale mantissa) ->
        let digits = length (show (abs mantissa))
            precision = max digits (fromIntegral scale)
         in if
              | scale > 38 ->
                  Left $ "decimal value " ++ show d ++ " has " ++ show scale
                    ++ " decimal places; SQL Server allows at most 38"
              | precision > 38 ->
                  Left $ "decimal value " ++ show d ++ " has " ++ show precision
                    ++ " digits; SQL Server allows at most 38"
              | otherwise ->
                  let p = fromIntegral precision
                   in Right (TIDecimalN p scale, ParamBytes (Just (runPutSized 17 (putDecimal p scale d))))
    , nullParamType = const (TIDecimalN 38 10)
    }

-- | @money@; values outside its range (±922,337,203,685,477.58) are rejected.
instance ToSqlField Money where
  fieldEncoder = checkedType (TIMoneyN 8) 8 (\m -> maybe (Right (putMoney8 m)) Left (money8Problem m))
instance ToSqlField UUID where fieldEncoder = fixedType TIGuid 16 putGuid

-- | Any length of string.  A value of up to 4000 UTF-16 code units is declared
-- @nvarchar(4000)@, and a longer one or a NULL ('Nothing') is declared
-- @nvarchar(max)@.  "Hmssql.Types" says when the difference matters.
instance ToSqlField Text where
  fieldEncoder = FieldEncoder
    { encodeParam = \_ t ->
        let bs = Utf16.encodeUtf16LE t
            len = if B.length bs > 8000 then maxLength else 8000
         in Right (TINVarChar len defaultCollation, ParamBytes (Just bs))
    , nullParamType = const untypedNull
    }

-- | Declared as 'Text' is, by the same rule.  A value too long for
-- @nvarchar(4000)@ is forced as it is sent, so it needn't all be in memory.  A
-- shorter one is forced before sending.  Choosing the declaration forces the
-- value as far as its 4001st code unit or its end.
instance ToSqlField LT.Text where
  fieldEncoder = FieldEncoder encode (const untypedNull)
    where
      -- Walking whole chunks forces exactly the input the limit allows.  A
      -- chunk is strict and already in memory, so measuring one past the
      -- budget costs no laziness, and the next chunk is forced only when this
      -- one fit.
      encode _ text
        | fits 4000 (LT.toChunks text) = Right (TINVarChar 8000 defaultCollation,
            ParamBytes (Just (Utf16.encodeUtf16LE (LT.toStrict text))))
        | otherwise = Right (TINVarChar maxLength defaultCollation,
            ParamLazy (LB.fromChunks (concatMap utf16Chunks (LT.toChunks text))))
      fits _ [] = True
      fits left (chunk : rest) =
        let units = Utf16.utf16Length (T.take (left + 1) chunk)
         in units <= left && fits (left - units) rest
instance {-# OVERLAPPING #-} ToSqlField String where fieldEncoder = contramap T.pack fieldEncoder

-- | Any length of bytes.  A value of up to 8000 bytes is declared
-- @varbinary(8000)@, and a longer one or a NULL ('Nothing') is declared
-- @varbinary(max)@.  "Hmssql.Types" says when the difference matters.
instance ToSqlField B.ByteString where
  fieldEncoder = FieldEncoder
    { encodeParam = \_ bs ->
        let len = if B.length bs > 8000 then maxLength else 8000
         in Right (TIBigVarBinary len, ParamBytes (Just bs))
    , nullParamType = const (TIBigVarBinary maxLength)
    }

-- | Declared as a strict 'B.ByteString' is, by the same rule.  A value too long
-- for @varbinary(8000)@ is forced as it is sent, so it needn't all be in memory.
-- A shorter one is forced before sending.  Choosing the declaration forces the
-- value as far as its 8001st byte or its end.
instance ToSqlField LB.ByteString where
  fieldEncoder = FieldEncoder (\_ bytes -> Right (lazyBinary bytes)) (const (TIBigVarBinary maxLength))
    where
      lazyBinary bytes
        | LB.null (LB.drop 8000 bytes) = (TIBigVarBinary 8000, ParamBytes (Just (LB.toStrict bytes)))
        | otherwise = (TIBigVarBinary maxLength, ParamLazy bytes)

-- | @datetime2(7)@, rounded to 100 ns (carrying into the next day; a leap
-- second counts as the following second).  Years 1 through 9999.
instance ToSqlField LocalTime where fieldEncoder = checkedType (TIDateTime2N 7) 8 (putDateTime2 7)

-- | @datetime2(7)@ holding the UTC clock time (zoneless).
instance ToSqlField UTCTime where
  fieldEncoder = contramap toLocal fieldEncoder
    where
      -- time's negative-clock conversion narrows the hours to Int. Split
      -- whole days first so a huge clock cannot wrap before the date check.
      -- Keep positive clocks on the existing path, including leap seconds.
      toLocal t@(UTCTime day clock)
        | clock < 0 =
            let (days, within) = diffTimeToPicoseconds clock `divMod` 86400000000000000
             in LocalTime (addDays days day) (timeToTimeOfDay (picosecondsToDiffTime within))
        | otherwise = utcToLocalTime utc t

-- | @datetimeoffset(7)@, rounded like 'LocalTime'.  The offset must be within
-- ±14:00 and both the UTC and the local time within years 1 through 9999.
instance ToSqlField DateTimeOffset where fieldEncoder = checkedType (TIDateTimeOffsetN 7) 10 (putDateTimeOffset 7)
-- | As 'DateTimeOffset'.  The offset is checked before it is narrowed to the
-- wire's 16-bit minute count.
instance ToSqlField ZonedTime where
  fieldEncoder = FieldEncoder
    { encodeParam = \ctx zt ->
        let mins = timeZoneMinutes (zonedTimeZone zt)
         in if mins < -840 || mins > 840
              then Left $ "datetimeoffset value " ++ show zt ++ ": the UTC offset must be between -14:00 and +14:00"
              else encodeParam dto ctx (zonedTimeToDateTimeOffset zt)
    , nullParamType = nullParamType dto
    }
    where
      dto = fieldEncoder @DateTimeOffset

-- | @date@, years 1 through 9999.
instance ToSqlField Day where fieldEncoder = checkedType TIDateN 3 putDate

-- | @time(7)@, rounded to 100 ns but never past 23:59:59.9999999 (there is no
-- next day to carry into; a leap second also becomes 23:59:59.9999999).
instance ToSqlField TimeOfDay where fieldEncoder = checkedType (TITimeN 7) 5 (putTime 7)

-- | Each constructor is sent as the wire type 'Hmssql.Decoding.FromSqlField' 'SqlValue'
-- decodes it from, so @SELECT \@p1@ returns the same 'SqlValue': 'SqlXml' as
-- @xml@ (UTF-16 with a byte order mark, no schema collection), 'SqlText' as
-- @nvarchar@, and so on.  'SqlNull' is an @nvarchar(max)@ NULL, which
-- the server won't convert to @sql_variant@ (error 206).
instance ToSqlField SqlValue where
  fieldEncoder = FieldEncoder
    { encodeParam = \ctx -> \case
        SqlNull -> Right (untypedNull, ParamBytes Nothing)
        SqlBool b -> enc ctx b
        SqlWord8 i -> enc ctx i
        SqlInt16 i -> enc ctx i
        SqlInt32 i -> enc ctx i
        SqlInt64 i -> enc ctx i
        SqlFloat f -> enc ctx f
        SqlDouble d -> enc ctx d
        SqlDecimal d -> enc ctx d
        SqlMoney m -> enc ctx m
        SqlGuid g -> enc ctx g
        SqlDateTime t -> enc ctx t
        SqlDate d -> enc ctx d
        SqlTime t -> enc ctx t
        SqlDateTimeOffset d -> enc ctx d
        SqlText t -> enc ctx t
        SqlBinary b -> enc ctx b
        -- The server detects an xml value's encoding from its bytes (XML
        -- 1.0 appendix F), so a UTF-16 document not starting with @<@ (text
        -- only, e.g. @"a"@) needs the byte order mark to be read as UTF-16.
        SqlXml t -> Right (TIXml Nothing, ParamBytes (Just ("\xFF\xFE" <> Utf16.encodeUtf16LE t)))
    , nullParamType = const untypedNull
    }
    where
      enc :: forall a. ToSqlField a => TdsContext -> a -> Either String EncodedParam
      enc = encodeParam fieldEncoder

------------------------------------------------------------------------------
-- Row encoders

-- | Produces each parameter with its name (@""@ means positional, @\@pN@
-- by position among the positional ones; otherwise the name with its
-- leading @\@@) and its encoding for a connection.  The parameters, their
-- number and their names never depend on the connection; only the encoded
-- values may.
newtype RowEncoder a = RowEncoder
  { encodeParams :: a -> [(Text, TdsContext -> Either String EncodedParam)]
  }

-- | An encoder of @b@ from an encoder of @a@ and a conversion.
instance Contravariant RowEncoder where
  contramap f (RowEncoder enc) = RowEncoder (enc . f)

-- | Combine two encoders over a product: the parameters of the first, then
-- those of the second.  For a 'ToSqlRow' written by hand, e.g. a record
-- with a field that is sent as two parameters.
divideRow :: (a -> (b, c)) -> RowEncoder b -> RowEncoder c -> RowEncoder a
divideRow split (RowEncoder eb) (RowEncoder ec) = RowEncoder $ \a ->
  let (b, c) = split a in eb b ++ ec c

-- | A row of one positional parameter.
singleParam :: FieldEncoder a -> RowEncoder a
singleParam (FieldEncoder enc _) = RowEncoder $ \a -> [("", \ctx -> enc ctx a)]

-- | Types that can be sent as a list of parameters: the @\@p1@, @\@p2@,
-- ... of 'Hmssql.Query.mkQuery', or a row of 'Hmssql.Query.executeMany' or
-- 'Hmssql.BulkCopy.bulkInsert'.  Derive it for a record whose fields are
-- 'ToSqlField' types, one parameter per field in order:
--
-- > data NewCustomer = NewCustomer { newName :: Text, newBirthDate :: Maybe Day }
-- >   deriving stock (Generic)
-- >   deriving anyclass (ToSqlRow)
--
-- Tuples of up to ten fields, @()@, 'Only', a list of one 'ToSqlField'
-- type, a list of 'SqlParam' to mix types, and 'NamedParams' have
-- instances.
class ToSqlRow a where
  rowEncoder :: RowEncoder a
  default rowEncoder :: (Generic a, GRowEncoder (Rep a)) => RowEncoder a
  rowEncoder = genericToSqlRow

instance ToSqlRow () where
  rowEncoder = RowEncoder (const [])

instance ToSqlField a => ToSqlRow (Only a) where
  rowEncoder = genericToSqlRow

-- | Any number of parameters of the same type.
instance ToSqlField a => ToSqlRow [a] where
  rowEncoder = RowEncoder $ map (\a -> ("", \ctx -> encodeParam fieldEncoder ctx a))

-- | A parameter's name and its value.
type NamedParam = (Text, SqlParam)

-- | Parameters that the SQL text refers to by name.  The leading @\@@ is
-- optional.  A name must be a T-SQL variable name, and not of the form
-- @\@pN@, which is reserved for the positional parameters; the query
-- functions check both before sending anything.  Bulk copy matches the
-- names, with that one @\@@ removed, against the table's columns
-- ("Hmssql.BulkCopy").
--
-- > mkQuery "UPDATE dbo.customer SET email = @email WHERE id = @id"
-- >   (NamedParams [("email", SqlParam newEmail), ("id", SqlParam customerId)])
newtype NamedParams = NamedParams [NamedParam]

instance ToSqlRow NamedParams where
  rowEncoder = RowEncoder $ \(NamedParams ps) -> map encodeNamed ps
    where
      encodeNamed (name, SqlParam a)
        | T.null name = ("@", const (Left "empty parameter name"))
        | otherwise = (withAt name, \ctx -> encodeParam fieldEncoder ctx a)
      withAt n
        | "@" `T.isPrefixOf` n = n
        | otherwise = "@" <> n

-- The tuples are encoded as records are, so that a call site such as
-- @mkQuery text (a, b, c)@ allocates a 'FieldParams' rather than having a closure
-- of its own for each parameter.
instance (ToSqlField a, ToSqlField b) => ToSqlRow (a, b) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c) => ToSqlRow (a, b, c) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d) => ToSqlRow (a, b, c, d) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e) => ToSqlRow (a, b, c, d, e) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e, ToSqlField f) => ToSqlRow (a, b, c, d, e, f) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e, ToSqlField f, ToSqlField g) => ToSqlRow (a, b, c, d, e, f, g) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e, ToSqlField f, ToSqlField g, ToSqlField h) => ToSqlRow (a, b, c, d, e, f, g, h) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e, ToSqlField f, ToSqlField g, ToSqlField h, ToSqlField i) => ToSqlRow (a, b, c, d, e, f, g, h, i) where
  rowEncoder = genericToSqlRow

instance (ToSqlField a, ToSqlField b, ToSqlField c, ToSqlField d, ToSqlField e, ToSqlField f, ToSqlField g, ToSqlField h, ToSqlField i, ToSqlField j) => ToSqlRow (a, b, c, d, e, f, g, h, i, j) where
  rowEncoder = genericToSqlRow

-- | The encoder a derived 'ToSqlRow' instance uses: one positional
-- parameter per field of a record (or product constructor), in order.
genericToSqlRow :: forall a. (Generic a, GRowEncoder (Rep a)) => RowEncoder a
genericToSqlRow = RowEncoder (\a -> fieldEntries (gFieldParams (from a) NoFieldParams))
{-# INLINE genericToSqlRow #-}

-- The object code of a record's encoder only takes the record apart and
-- allocates its 'FieldParams': per field, one constructor holding the type's
-- static 'FieldEncoder', the value and the rest.  The names, the closures and
-- the encoding itself are in 'fieldEntries', once for every record.  Built from
-- 'divideRow' and 'singleParam', each field had a closure of its own with its
-- type's encoding inlined into it, and a thunk that took the field out of a
-- lazily built 'Rep' tree, log2 n cases deep.  In the 50-record program of
-- scripts/code-size.sh that was 583,373 bytes of ToSqlRow instances, 491 per
-- field, in 4.3 s; this is 84,285 bytes, 71 per field, in 1.4 s.
--
-- A strict 'Int32', 'Int64' or 'Double' field of a record is held in a constructor
-- of its own, unpacked, which saves the encoder's word and the box that GHC
-- otherwise rebuilds around an unpacked record field.  The 50-record program
-- went from 83,813 to 74,061 bytes, and a row of five numeric fields allocates
-- 2,296 bytes in place of 2,576, for 13,728 bytes of library code in the hidden
-- class method and the three cases of 'fieldEntries' (GHC 9.12.4, 2026-11-04).
-- One shared constructor for the three types saved 224 bytes of that and cost
-- 32 bytes per field, so the cases stay separate.  Every other type, and every
-- lazy field, goes through 'FieldParam'.

-- | Values, each with the encoder of its type.
data FieldParams
  = forall a. FieldParam (FieldEncoder a) a FieldParams
  | Int32Param {-# UNPACK #-} !Int32 FieldParams
  | Int64Param {-# UNPACK #-} !Int64 FieldParams
  | DoubleParam {-# UNPACK #-} !Double FieldParams
  | NoFieldParams

-- | Positional parameters of the values.
fieldEntries :: FieldParams -> [(Text, TdsContext -> Either String EncodedParam)]
fieldEntries = \case
  -- The spine is built at once, as every consumer walks all of it: a thunk
  -- for the rest was 3 words more per field.
  FieldParam fe a rest -> let !entries = fieldEntries rest in ("", \ctx -> encodeParam fe ctx a) : entries
  Int32Param a rest -> let !entries = fieldEntries rest in ("", \ctx -> encodeParam fieldEncoder ctx a) : entries
  Int64Param a rest -> let !entries = fieldEntries rest in ("", \ctx -> encodeParam fieldEncoder ctx a) : entries
  DoubleParam a rest -> let !entries = fieldEntries rest in ("", \ctx -> encodeParam fieldEncoder ctx a) : entries
  NoFieldParams -> []
{-# NOINLINE fieldEntries #-}

class GRowEncoder f where
  -- | The fields, in order, before the rest.
  gFieldParams :: f x -> FieldParams -> FieldParams

instance (GRowEncoder f, GRowEncoder g) => GRowEncoder (f :*: g) where
  gFieldParams (a :*: b) rest = gFieldParams a (gFieldParams b rest)
  {-# INLINE gFieldParams #-}

instance {-# OVERLAPPABLE #-} GRowEncoder f => GRowEncoder (M1 i c f) where
  gFieldParams (M1 a) = gFieldParams a
  {-# INLINE gFieldParams #-}

-- A record of one field is only newtype wrappers in its generic representation,
-- so walking its parameters (to count them, or to render the SQL) never forced
-- the record, even when the field is strict.  The unpacked constructors would
-- force it, so a record of one field keeps 'FieldParam'.
instance {-# OVERLAPPING #-} ToSqlField a => GRowEncoder (M1 C constructor (M1 S metadata (K1 i a))) where
  gFieldParams (M1 (M1 (K1 a))) = FieldParam fieldEncoder a
  {-# INLINE gFieldParams #-}

-- Only a field its constructor already forces may be held unpacked, because
-- building the 'FieldParams' then forces nothing that was not forced before, and
-- counting the parameters or rendering the SQL must not evaluate a lazy field.
-- The selector's strictness is static, so a derived encoder has one of the two
-- branches and not the case.
instance {-# OVERLAPPING #-} (Selector metadata, ToSqlField a) => GRowEncoder (M1 S metadata (K1 i a)) where
  gFieldParams selector@(M1 (K1 a)) = case selDecidedStrictness selector of
    DecidedLazy -> FieldParam fieldEncoder a
    _ -> fieldParam a
  {-# INLINE gFieldParams #-}

-- A field without selector metadata promises no strictness.
instance ToSqlField a => GRowEncoder (K1 i a) where
  gFieldParams (K1 a) = FieldParam fieldEncoder a
  {-# INLINE gFieldParams #-}

-- | A parameter read as it is sent, so a large value needn't be in memory.  Its
-- type is a @(max)@ type or @xml@; any other is an 'Hmssql.Errors.EncodeError'
-- before anything is sent.
data StreamParam = StreamParam !TypeInfo !ParamValue

instance ToSqlField StreamParam where
  fieldEncoder = FieldEncoder
    (\_ (StreamParam ti value) -> maybe (Right (ti, value)) Left (paramValueProblem ti value))
    (const untypedNull)

-- | A @varbinary(max)@ parameter, read from the source as it is sent.
binaryStream :: Source B.ByteString -> StreamParam
binaryStream = streamAs (TIBigVarBinary maxLength)

-- | An @nvarchar(max)@ parameter, read from the source as it is sent.
textStream :: Source Text -> StreamParam
textStream (Source source) = streamAs (TINVarChar maxLength defaultCollation) $
  Source (\use -> source (use . (\stream -> S.for stream (S.each . utf16Chunks))))

-- | The text in UTF-16LE, a bounded piece at a time, so that one large 'Text'
-- doesn't need all of its encoding in memory.  The split is by character, so
-- no piece ends inside a surrogate pair.
utf16Chunks :: Text -> [B.ByteString]
utf16Chunks text
  | T.null text = []
  | otherwise = let (here, rest) = T.splitAt 2048 text in Utf16.encodeUtf16LE here : utf16Chunks rest

-- | A parameter of the given @(max)@ or @xml@ type, read from the source as it
-- is sent.  The bytes are the caller's to encode for that type.  For UTF-16,
-- their total must be an even number of bytes.
streamAs :: TypeInfo -> Source B.ByteString -> StreamParam
streamAs ti = StreamParam ti . ParamStream

-- | 'streamAs' for lazy bytes, forced as they are sent.
lazyAs :: TypeInfo -> LB.ByteString -> StreamParam
lazyAs ti = StreamParam ti . ParamLazy
