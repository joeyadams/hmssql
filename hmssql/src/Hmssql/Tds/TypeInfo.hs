{-# LANGUAGE MagicHash #-}
{-# LANGUAGE QualifiedDo #-}
-- | Column/parameter type descriptors and the length-prefixed value encodings
-- that go with them.
--
-- [MS-TDS 2.2.5.4 Data Type Definitions](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/ffb02215-af07-4b50-8545-1fd522106c68)
module Hmssql.Tds.TypeInfo
  ( TypeInfo (..)
  , XmlSchema (..)
  , UdtInfo (..)
  , maxLength
  , RawBytes
  , readDecimalInfo
  , readTypeInfo
  , putTypeInfo
  , putValue
  , putValueUnchecked
  , LengthKind (..)
  , lengthKind
  , valueProblem
  , typeInfoProblem
  , typeInfoSqlName
  , isNullableType
    -- * The wire layouts, written to any sink
  , writeTypeInfo
  , writeValue
  ) where

import Control.Monad (when)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Internal as BBI
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word32, Word8)
import Text.Printf (printf)

import Hmssql.Internal.Derived
import qualified Hmssql.Tds.Parser as P
import qualified Hmssql.Tds.Parser.OutOfLine as O
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import qualified Hmssql.Tds.Utf16 as Utf16

-- | Sentinel length for @varchar(max)@, @nvarchar(max)@, @varbinary(max)@.
maxLength :: Word16
maxLength = 0xFFFF

-- | The schema collection of a typed @xml@ column or parameter.
data XmlSchema = XmlSchema
  { xmlDbName :: !Text
  , xmlOwningSchema :: !Text
  , xmlSchemaCollection :: !Text
  }

instance Show XmlSchema where
  showsPrec p (XmlSchema a b c) = showRecord p "XmlSchema"#
    [ "xmlDbName"# := a, "xmlOwningSchema"# := b, "xmlSchemaCollection"# := c ]
  {-# OPAQUE showsPrec #-}

instance Eq XmlSchema where
  XmlSchema a b c == XmlSchema a' b' c' = eq a a' && eq b b' && eq c c'
  {-# OPAQUE (==) #-}

-- | MS-TDS 2.2.5.5.2 UDT_INFO, as the server sends it in COLMETADATA
-- and RETURNVALUE.
data UdtInfo = UdtInfo
  { udtMaxLength :: !Word16
    -- ^ The largest serialized value in bytes, 0xFFFF if unlimited.  The
    -- values themselves are always PLP.
  , udtDbName :: !Text
  , udtSchemaName :: !Text
  , udtTypeName :: !Text
  , udtAssemblyQualifiedName :: !Text
  }

instance Show UdtInfo where
  showsPrec p (UdtInfo a b c e f) = showRecord p "UdtInfo"#
    [ "udtMaxLength"# := a, "udtDbName"# := b, "udtSchemaName"# := c, "udtTypeName"# := e
    , "udtAssemblyQualifiedName"# := f
    ]
  {-# OPAQUE showsPrec #-}

instance Eq UdtInfo where
  UdtInfo a b c e f == UdtInfo a' b' c' e' f' =
    a == a' && eq b b' && eq c c' && eq e e' && eq f f'
  {-# OPAQUE (==) #-}

-- | A type as the wire describes it (MS-TDS 2.2.5.4 TYPE_INFO): the
-- token's type byte with its length, precision and scale, or collation,
-- as the server sends it in COLMETADATA and a client sends it for a
-- parameter.  The wire has fewer types than T-SQL (@int@ arrives as
-- @TIIntN 4@ or @TIInt4@; @json@ and @vector@ as character types):
-- "Hmssql.SqlType" names the declared type.  'Hmssql.Encoding.RawParam' takes one to send
-- a value with a wire type of your choosing.
data TypeInfo
  = TINull                              -- ^ 0x1F
  | TIBit                               -- ^ 0x32
  | TIInt1                              -- ^ 0x30
  | TIInt2                              -- ^ 0x34
  | TIInt4                              -- ^ 0x38
  | TIInt8                              -- ^ 0x7F
  | TIMoney4                            -- ^ 0x7A
  | TIMoney8                            -- ^ 0x3C
  | TIDateTime4                         -- ^ 0x3A
  | TIDateTime8                         -- ^ 0x3D
  | TIFlt4                              -- ^ 0x3B
  | TIFlt8                              -- ^ 0x3E

  | TIBitN                              -- ^ 0x68
  | TIIntN !Word8                       -- ^ 0x26, length 1/2/4/8
  | TIMoneyN !Word8                     -- ^ 0x6E, length 4/8
  | TIDateTimeN !Word8                  -- ^ 0x6F, length 4/8
  | TIFltN !Word8                       -- ^ 0x6D, length 4/8

  | TIGuid                              -- ^ 0x24
  | TIDecimalN !Precision !Scale        -- ^ 0x6A
  | TINumericN !Precision !Scale        -- ^ 0x6C

  | TIDateN                             -- ^ 0x28
  | TITimeN !Scale                      -- ^ 0x29
  | TIDateTime2N !Scale                 -- ^ 0x2A
  | TIDateTimeOffsetN !Scale            -- ^ 0x2B

  | TIBigChar !Word16 !Collation        -- ^ 0xAF
  | TIBigVarChar !Word16 !Collation     -- ^ 0xA7, 0xFFFF = max
  | TIText !Word32 !Collation           -- ^ 0x23
  | TINChar !Word16 !Collation          -- ^ 0xEF
  | TINVarChar !Word16 !Collation       -- ^ 0xE7, 0xFFFF = max
  | TINText !Word32 !Collation          -- ^ 0x63

  | TIBigBinary !Word16                 -- ^ 0xAD
  | TIBigVarBinary !Word16              -- ^ 0xA5, 0xFFFF = max
  | TIImage !Word32                     -- ^ 0x22

  | TIXml !(Maybe XmlSchema)            -- ^ 0xF1
  | TISqlVariant !Word32                -- ^ 0x62
  | TIUdt !UdtInfo
    -- ^ 0xF0, a CLR user-defined type (@hierarchyid@, @geometry@,
    -- @geography@, ...).  Parsed so a result containing one can be read
    -- past, but not decoded ("Hmssql.Decoding" rejects it except as raw
    -- bytes) nor sent ('typeInfoProblem').

instance Show TypeInfo where
  showsPrec p = \case
    TINull -> showString "TINull"
    TIBit -> showString "TIBit"
    TIInt1 -> showString "TIInt1"
    TIInt2 -> showString "TIInt2"
    TIInt4 -> showString "TIInt4"
    TIInt8 -> showString "TIInt8"
    TIMoney4 -> showString "TIMoney4"
    TIMoney8 -> showString "TIMoney8"
    TIDateTime4 -> showString "TIDateTime4"
    TIDateTime8 -> showString "TIDateTime8"
    TIFlt4 -> showString "TIFlt4"
    TIFlt8 -> showString "TIFlt8"
    TIBitN -> showString "TIBitN"
    TIIntN a -> showCon1 p "TIIntN"# a
    TIMoneyN a -> showCon1 p "TIMoneyN"# a
    TIDateTimeN a -> showCon1 p "TIDateTimeN"# a
    TIFltN a -> showCon1 p "TIFltN"# a
    TIGuid -> showString "TIGuid"
    TIDecimalN a b -> showCon p "TIDecimalN"# [Arg a, Arg b]
    TINumericN a b -> showCon p "TINumericN"# [Arg a, Arg b]
    TIDateN -> showString "TIDateN"
    TITimeN a -> showCon1 p "TITimeN"# a
    TIDateTime2N a -> showCon1 p "TIDateTime2N"# a
    TIDateTimeOffsetN a -> showCon1 p "TIDateTimeOffsetN"# a
    TIBigChar a b -> showCon p "TIBigChar"# [Arg a, Arg b]
    TIBigVarChar a b -> showCon p "TIBigVarChar"# [Arg a, Arg b]
    TIText a b -> showCon p "TIText"# [Arg a, Arg b]
    TINChar a b -> showCon p "TINChar"# [Arg a, Arg b]
    TINVarChar a b -> showCon p "TINVarChar"# [Arg a, Arg b]
    TINText a b -> showCon p "TINText"# [Arg a, Arg b]
    TIBigBinary a -> showCon1 p "TIBigBinary"# a
    TIBigVarBinary a -> showCon1 p "TIBigVarBinary"# a
    TIImage a -> showCon1 p "TIImage"# a
    TIXml a -> showCon1 p "TIXml"# a
    TISqlVariant a -> showCon1 p "TISqlVariant"# a
    TIUdt a -> showCon1 p "TIUdt"# a
  {-# OPAQUE showsPrec #-}

instance Eq TypeInfo where
  x == y = case (x, y) of
    (TINull, TINull) -> True
    (TIBit, TIBit) -> True
    (TIInt1, TIInt1) -> True
    (TIInt2, TIInt2) -> True
    (TIInt4, TIInt4) -> True
    (TIInt8, TIInt8) -> True
    (TIMoney4, TIMoney4) -> True
    (TIMoney8, TIMoney8) -> True
    (TIDateTime4, TIDateTime4) -> True
    (TIDateTime8, TIDateTime8) -> True
    (TIFlt4, TIFlt4) -> True
    (TIFlt8, TIFlt8) -> True
    (TIBitN, TIBitN) -> True
    (TIIntN a, TIIntN a') -> a == a'
    (TIMoneyN a, TIMoneyN a') -> a == a'
    (TIDateTimeN a, TIDateTimeN a') -> a == a'
    (TIFltN a, TIFltN a') -> a == a'
    (TIGuid, TIGuid) -> True
    (TIDecimalN a b, TIDecimalN a' b') -> a == a' && b == b'
    (TINumericN a b, TINumericN a' b') -> a == a' && b == b'
    (TIDateN, TIDateN) -> True
    (TITimeN a, TITimeN a') -> a == a'
    (TIDateTime2N a, TIDateTime2N a') -> a == a'
    (TIDateTimeOffsetN a, TIDateTimeOffsetN a') -> a == a'
    (TIBigChar a b, TIBigChar a' b') -> a == a' && eq b b'
    (TIBigVarChar a b, TIBigVarChar a' b') -> a == a' && eq b b'
    (TIText a b, TIText a' b') -> a == a' && eq b b'
    (TINChar a b, TINChar a' b') -> a == a' && eq b b'
    (TINVarChar a b, TINVarChar a' b') -> a == a' && eq b b'
    (TINText a b, TINText a' b') -> a == a' && eq b b'
    (TIBigBinary a, TIBigBinary a') -> a == a'
    (TIBigVarBinary a, TIBigVarBinary a') -> a == a'
    (TIImage a, TIImage a') -> a == a'
    (TIXml a, TIXml a') -> eq a a'
    (TISqlVariant a, TISqlVariant a') -> a == a'
    (TIUdt a, TIUdt a') -> eq a a'
    _ -> False
  {-# OPAQUE (==) #-}

-- | Whether the wire encoding of this type can carry NULL.
isNullableType :: TypeInfo -> Bool
isNullableType = \case
  TIBit -> False
  TIInt1 -> False
  TIInt2 -> False
  TIInt4 -> False
  TIInt8 -> False
  TIMoney4 -> False
  TIMoney8 -> False
  TIDateTime4 -> False
  TIDateTime8 -> False
  TIFlt4 -> False
  TIFlt8 -> False
  _ -> True

------------------------------------------------------------------------------

-- | A column's or parameter's TYPE_INFO, as COLMETADATA and RETURNVALUE carry it.
readTypeInfo :: P.Parser TypeInfo
readTypeInfo = O.word8 O.>>= \case
  0x1F -> pure TINull
  0x32 -> pure TIBit
  0x30 -> pure TIInt1
  0x34 -> pure TIInt2
  0x38 -> pure TIInt4
  0x7F -> pure TIInt8
  0x7A -> pure TIMoney4
  0x3C -> pure TIMoney8
  0x3A -> pure TIDateTime4
  0x3D -> pure TIDateTime8
  0x3B -> pure TIFlt4
  0x3E -> pure TIFlt8

  0x68 -> TIBitN O.<$ O.word8
  0x26 -> TIIntN O.<$> lengthIn [1, 2, 4, 8]
  0x6E -> TIMoneyN O.<$> lengthIn [4, 8]
  0x6F -> TIDateTimeN O.<$> lengthIn [4, 8]
  0x6D -> TIFltN O.<$> lengthIn [4, 8]

  0x24 -> TIGuid O.<$ lengthIn [16]
  0x6A -> O.word8 O.*> readDecimalInfo TIDecimalN
  0x6C -> O.word8 O.*> readDecimalInfo TINumericN

  0x28 -> pure TIDateN
  0x29 -> TITimeN O.<$> getScale
  0x2A -> TIDateTime2N O.<$> getScale
  0x2B -> TIDateTimeOffsetN O.<$> getScale

  0xAF -> TIBigChar O.<$> O.word16le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)
  0xA7 -> TIBigVarChar O.<$> O.word16le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)
  0x23 -> TIText O.<$> O.word32le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)
  0xEF -> TINChar O.<$> O.word16le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)
  0xE7 -> TINVarChar O.<$> O.word16le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)
  0x63 -> TINText O.<$> O.word32le O.<*> (Collation O.<$> O.word32le O.<*> O.word8)

  0xAD -> TIBigBinary O.<$> O.word16le
  0xA5 -> TIBigVarBinary O.<$> O.word16le
  0x22 -> TIImage O.<$> O.word32le

  0xF1 -> O.do
    present <- O.word8
    if present == 0
      then pure $ TIXml Nothing
      else TIXml . Just O.<$> (XmlSchema O.<$> P.bVarChar O.<*> P.bVarChar O.<*> P.usVarChar)
  0x62 -> TISqlVariant O.<$> O.word32le

  0xF0 -> fmap TIUdt $
    UdtInfo O.<$> O.word16le O.<*> P.bVarChar O.<*> P.bVarChar O.<*> P.bVarChar O.<*> P.usVarChar
  0xF3 -> fail "readTypeInfo: table-valued parameters are not supported"
  code -> fail $ "readTypeInfo: unknown data type 0x" ++ printf "%02x" code
  where
    lengthIn allowed = O.do
      len <- O.word8
      when (len `notElem` allowed) $
        fail $ "readTypeInfo: invalid length " ++ show len
      pure len
    getScale = O.do
      s <- O.word8
      when (s > 7) $ fail $ "readTypeInfo: invalid scale " ++ show s
      pure s

-- | Precision and scale of @decimal@ / @numeric@, which must satisfy
-- 1 <= precision <= 38 and scale <= precision (MS-TDS 2.2.5.5.1.3).
readDecimalInfo :: (Precision -> Scale -> a) -> P.Parser a
readDecimalInfo mk = O.do
  p <- O.word8
  s <- O.word8
  when (p < 1 || p > 38) $ fail $ "invalid decimal precision " ++ show p
  when (s > p) $ fail $ "invalid decimal scale " ++ show s ++ " for precision " ++ show p
  pure (mk p s)

-- | TYPE_INFO as a 'Put': 'writeTypeInfo'.
putTypeInfo :: TdsContext -> TypeInfo -> Put
putTypeInfo _ctx = Put.putBuilder . writeTypeInfo

------------------------------------------------------------------------------
-- The wire layouts, written

-- | A B_VARCHAR: a one-byte count of UTF-16 code units, then the text.
-- Fails (with 'error') for more than 255 units, which the count can't
-- hold; 'typeInfoProblem' refuses such names first.
bVarChar :: Text -> BB.Builder
bVarChar t
  | n > 0xFF = error $ "bVarChar: " ++ show n ++ " UTF-16 code units do not fit in a B_VARCHAR (at most 255)"
  | otherwise = BB.word8 (fromIntegral n) <> BB.byteString bs
  where
    bs = Utf16.encodeUtf16LE t
    n = B.length bs `div` 2
{-# NOINLINE bVarChar #-}

-- | A US_VARCHAR: a two-byte count, then the text; fails past 65535 units.
usVarChar :: Text -> BB.Builder
usVarChar t
  | n > 0xFFFF = error $ "usVarChar: " ++ show n ++ " UTF-16 code units do not fit in a US_VARCHAR (at most 65535)"
  | otherwise = BB.word16LE (fromIntegral n) <> BB.byteString bs
  where
    bs = Utf16.encodeUtf16LE t
    n = B.length bs `div` 2
{-# NOINLINE usVarChar #-}
-- Both out of line: only an XML schema or a UDT has these names, and inlined, each
-- of the seven was a copy of the UTF-16 encoder in 'writeTypeInfo', 6.8 KB in all.
-- (Sharing the other layouts of 'writeTypeInfo' the same way saved 7 KB more, but
-- each parameter then allocated 16 to 64 bytes more, the boxed fields and the joined
-- Builders' continuations.)

-- | TYPE_INFO (MS-TDS 2.2.5.6): the type byte, then what the type
-- carries (a length, a precision and scale, a collation, names).
writeTypeInfo :: TypeInfo -> BB.Builder
writeTypeInfo = \case
  TINull -> BB.word8 0x1F
  TIBit -> BB.word8 0x32
  TIInt1 -> BB.word8 0x30
  TIInt2 -> BB.word8 0x34
  TIInt4 -> BB.word8 0x38
  TIInt8 -> BB.word8 0x7F
  TIMoney4 -> BB.word8 0x7A
  TIMoney8 -> BB.word8 0x3C
  TIDateTime4 -> BB.word8 0x3A
  TIDateTime8 -> BB.word8 0x3D
  TIFlt4 -> BB.word8 0x3B
  TIFlt8 -> BB.word8 0x3E

  TIBitN -> BB.word8 0x68 <> BB.word8 1
  TIIntN n -> BB.word8 0x26 <> BB.word8 n
  TIMoneyN n -> BB.word8 0x6E <> BB.word8 n
  TIDateTimeN n -> BB.word8 0x6F <> BB.word8 n
  TIFltN n -> BB.word8 0x6D <> BB.word8 n

  TIGuid -> BB.word8 0x24 <> BB.word8 16
  TIDecimalN p sc -> BB.word8 0x6A <> decimalInfo p sc
  TINumericN p sc -> BB.word8 0x6C <> decimalInfo p sc

  TIDateN -> BB.word8 0x28
  TITimeN sc -> BB.word8 0x29 <> BB.word8 sc
  TIDateTime2N sc -> BB.word8 0x2A <> BB.word8 sc
  TIDateTimeOffsetN sc -> BB.word8 0x2B <> BB.word8 sc

  TIBigChar len col -> BB.word8 0xAF <> BB.word16LE len <> collation col
  TIBigVarChar len col -> BB.word8 0xA7 <> BB.word16LE len <> collation col
  TIText len col -> BB.word8 0x23 <> BB.word32LE len <> collation col
  TINChar len col -> BB.word8 0xEF <> BB.word16LE len <> collation col
  TINVarChar len col -> BB.word8 0xE7 <> BB.word16LE len <> collation col
  TINText len col -> BB.word8 0x63 <> BB.word32LE len <> collation col

  TIBigBinary len -> BB.word8 0xAD <> BB.word16LE len
  TIBigVarBinary len -> BB.word8 0xA5 <> BB.word16LE len
  TIImage len -> BB.word8 0x22 <> BB.word32LE len

  TIXml Nothing -> BB.word8 0xF1 <> BB.word8 0
  TIXml (Just XmlSchema{..}) ->
    BB.word8 0xF1 <> BB.word8 1 <> bVarChar xmlDbName <> bVarChar xmlOwningSchema <> usVarChar xmlSchemaCollection
  TISqlVariant len -> BB.word8 0x62 <> BB.word32LE len
  -- The COLMETADATA form, which 'readTypeInfo' reads.  (An RPC parameter
  -- would have the shorter UDT_INFO_IN_RPC; 'typeInfoProblem' refuses UDT
  -- parameters.)
  TIUdt UdtInfo{..} ->
    BB.word8 0xF0 <> BB.word16LE udtMaxLength <> bVarChar udtDbName <> bVarChar udtSchemaName
      <> bVarChar udtTypeName <> usVarChar udtAssemblyQualifiedName
  where
    decimalInfo p sc = BB.word8 (fromIntegral (precisionToLength p) + 1) <> BB.word8 p <> BB.word8 sc
    collation (Collation info sortId) = BB.word32LE info <> BB.word8 sortId
-- Out of line.  INLINE, it was 25 KB of object code at each of its five copies (three
-- in Tds.Client's RPC writers, two here), 119 KB of the library in all; out of line
-- it is one call per parameter, and the RPC encoding benchmarks allocate the same.

-- | A value as RPC parameters carry it, after its TYPE_INFO: nothing for
-- a type with no value, the bytes of a fixed-length type, else a length
-- prefix (whose NULL spelling depends on the kind, 'LengthKind') and the
-- bytes, or PLP chunks.  Nothing is checked here: a value too long for its
-- length prefix wraps, and an empty BYTE-length or @sql_variant@ payload is
-- written as NULL.  'putValue' checks with 'valueProblem' first; this is for
-- values checked already.
writeValue :: TypeInfo -> RawBytes -> BB.Builder
writeValue ti rb = BBI.builder (writeValueStep ti rb)
{-# INLINE writeValue #-}

-- The framing is compiled once, as a function of the Builder's continuation and
-- buffer together rather than one returning a Builder, so a caller composes it
-- without allocating a Builder closure first.  Out of line as a Builder-returning
-- function, 'writeValue' cost the sender 32 bytes of allocation per parameter;
-- as this step it costs nothing over the inlined copy, and the copies the sender,
-- the in-memory serializer and the tests had are one (19,752 bytes less of
-- library code, GHC 9.12.4, 2026-11-04).  This touches no buffer itself.
writeValueStep :: TypeInfo -> RawBytes -> BBI.BuildStep a -> BBI.BuildStep a
writeValueStep ti rb next range = BBI.runBuilderWith (valueBuilder ti rb) next range
{-# NOINLINE writeValueStep #-}

valueBuilder :: TypeInfo -> RawBytes -> BB.Builder
valueBuilder ti rb = case (lengthKind ti, rb) of
  (NoValue, _) -> mempty
  (Fixed _, Just bs) -> BB.byteString bs
  (Fixed _, Nothing) -> mempty  -- ruled out by 'lengthProblem'
  (ByteLen, Nothing) -> BB.word8 0
  (ByteLen, Just bs) -> BB.word8 (fromIntegral (B.length bs)) <> BB.byteString bs
  (UShortCharBin, Nothing) -> BB.word16LE 0xFFFF
  (UShortCharBin, Just bs) -> BB.word16LE (fromIntegral (B.length bs)) <> BB.byteString bs
  (LongLen, Nothing) -> BB.word32LE 0xFFFFFFFF
  (LongLen, Just bs) -> BB.word32LE (fromIntegral (B.length bs)) <> BB.byteString bs
  (VariantLen, Nothing) -> BB.word32LE 0
  (VariantLen, Just bs) -> BB.word32LE (fromIntegral (B.length bs)) <> BB.byteString bs
  (Plp, Nothing) -> BB.word64LE 0xFFFFFFFFFFFFFFFF
  (Plp, Just bs) -> BB.word64LE (fromIntegral (B.length bs)) <> chunks bs
  where
    -- One chunk (up to 1 GiB), as SqlClient sends a value it holds: a
    -- value of 8 KiB or more is then referred to by the message body, not
    -- copied into it (binary copies anything shorter, which 8000-byte
    -- chunks would all be), and is copied once, when it is framed.
    chunks b
      | B.null b = BB.word32LE 0
      | otherwise =
          let (chunk, rest) = B.splitAt plpChunk b
           in BB.word32LE (fromIntegral (B.length chunk)) <> BB.byteString chunk <> chunks rest
{-# INLINE valueBuilder #-}

-- | The largest PLP chunk sent.
plpChunk :: Int
plpChunk = 0x40000000

------------------------------------------------------------------------------
-- Values

-- | An undecoded column or parameter value; 'Nothing' is SQL NULL.
type RawBytes = Maybe B.ByteString

-- | How a type's values are delimited on the wire ('lengthKind').
data LengthKind
  = Fixed !Int
  | ByteLen         -- ^ 1-byte length, 0 = NULL
  | UShortCharBin   -- ^ 2-byte length, 0xFFFF = NULL
  | LongLen         -- ^ 4-byte length, 0xFFFFFFFF = NULL
  | VariantLen      -- ^ 4-byte length, 0 = NULL (@sql_variant@)
  | Plp             -- ^ partially length-prefixed
  | NoValue

-- | How values of the type are delimited.
lengthKind :: TypeInfo -> LengthKind
lengthKind = \case
  TINull -> NoValue
  TIBit -> Fixed 1
  TIInt1 -> Fixed 1
  TIInt2 -> Fixed 2
  TIInt4 -> Fixed 4
  TIInt8 -> Fixed 8
  TIMoney4 -> Fixed 4
  TIMoney8 -> Fixed 8
  TIDateTime4 -> Fixed 4
  TIDateTime8 -> Fixed 8
  TIFlt4 -> Fixed 4
  TIFlt8 -> Fixed 8

  TIBitN -> ByteLen
  TIIntN _ -> ByteLen
  TIMoneyN _ -> ByteLen
  TIDateTimeN _ -> ByteLen
  TIFltN _ -> ByteLen
  TIGuid -> ByteLen
  TIDecimalN _ _ -> ByteLen
  TINumericN _ _ -> ByteLen
  TIDateN -> ByteLen
  TITimeN _ -> ByteLen
  TIDateTime2N _ -> ByteLen
  TIDateTimeOffsetN _ -> ByteLen

  TIBigChar _ _ -> UShortCharBin
  TIBigVarChar len _ | len == maxLength -> Plp
                     | otherwise -> UShortCharBin
  TIText _ _ -> LongLen
  TINChar _ _ -> UShortCharBin
  TINVarChar len _ | len == maxLength -> Plp
                   | otherwise -> UShortCharBin
  TINText _ _ -> LongLen

  TIBigBinary _ -> UShortCharBin
  TIBigVarBinary len | len == maxLength -> Plp
                     | otherwise -> UShortCharBin
  TIImage _ -> LongLen

  TIXml _ -> Plp
  TISqlVariant _ -> VariantLen
  TIUdt _ -> Plp

-- | Why 'putValue' can't write this value for this type, if it can't: a
-- fixed-length type given the wrong number of bytes or NULL, or a value too
-- long for its length prefix, which would otherwise be written modulo 256
-- (or 65536, ...).  A USHORT length of 0xFFFF would even read as NULL.
lengthProblem :: TypeInfo -> RawBytes -> Maybe String
lengthProblem ti rb = case (lengthKind ti, rb) of
  (Fixed n, Just bs)
    | B.length bs /= n -> Just $ name ++ " requires exactly " ++ show n ++ " bytes, not " ++ show (B.length bs)
  (Fixed _, Nothing) -> Just $ name ++ " cannot be NULL"
  (ByteLen, Just bs) -> atMost 0xFF bs
  (UShortCharBin, Just bs) -> atMost 0xFFFE bs
  (LongLen, Just bs) -> atMost 0x7FFFFFFF bs
  (VariantLen, Just bs) -> atMost 0xFFFFFFFE bs
  _ -> Nothing
  where
    name = T.unpack (typeInfoSqlName ti)
    atMost :: Integer -> B.ByteString -> Maybe String
    atMost limit bs
      | toInteger (B.length bs) > limit = Just $
          "a " ++ show (B.length bs) ++ "-byte " ++ name ++ " value is too long for its length prefix (at most "
            ++ show limit ++ " bytes)"
      | otherwise = Nothing

-- | Why a value can't be sent as a parameter of this type, if it can't:
-- a 'lengthProblem', or an empty value of a type whose length prefix uses 0
-- for NULL (every BYTE-length type, and @sql_variant@), which the server
-- would read as NULL.
valueProblem :: TypeInfo -> RawBytes -> Maybe String
valueProblem ti rb = case lengthProblem ti rb of
  Just p -> Just p
  Nothing -> case (lengthKind ti, rb) of
    (ByteLen, Just bs) | B.null bs -> emptyIsNull
    (VariantLen, Just bs) | B.null bs -> emptyIsNull
    _ -> Nothing
  where
    emptyIsNull = Just $
      "an empty " ++ T.unpack (typeInfoSqlName ti) ++ " value would be read as NULL (use Nothing for NULL)"

-- | Why a parameter can't have this type, if it can't: a precision or
-- scale SQL Server doesn't have (a @decimal@ or @numeric@ precision outside
-- 1 through 38 or a scale above the precision, MS-TDS 2.2.5.5.1.3; a
-- @time@, @datetime2@ or @datetimeoffset@ scale above 7, 2.2.5.4.2), XML
-- schema names too long for their length prefixes, or a CLR user-defined
-- type, which hmssql doesn't send.
typeInfoProblem :: TypeInfo -> Maybe String
typeInfoProblem = \case
  TIDecimalN p s -> decimalProblem "decimal" p s
  TINumericN p s -> decimalProblem "numeric" p s
  TITimeN s -> scaleProblem "time" s
  TIDateTime2N s -> scaleProblem "datetime2" s
  TIDateTimeOffsetN s -> scaleProblem "datetimeoffset" s
  TIUdt u -> Just $
    "CLR user-defined type (" ++ T.unpack (typeInfoSqlName (TIUdt u)) ++ ") parameters are not supported;"
      ++ " send the value as varbinary(max) (its serialized form) or nvarchar and convert it in the query"
  TIXml (Just XmlSchema{..})
    | ucs2Length xmlDbName > 0xFF || ucs2Length xmlOwningSchema > 0xFF || ucs2Length xmlSchemaCollection > 0xFFFF ->
        Just "an XML schema collection name is too long"
  _ -> Nothing

decimalProblem :: String -> Precision -> Scale -> Maybe String
decimalProblem name p s
  | p < 1 || p > 38 = Just $ "invalid " ++ name ++ " precision " ++ show p ++ " (1 through 38)"
  | s > p = Just $ "invalid " ++ name ++ " scale " ++ show s ++ " for precision " ++ show p ++ " (at most the precision)"
  | otherwise = Nothing

-- | Write a value as it appears in RPC parameters. Fails (with 'error')
-- if 'valueProblem' finds invalid framing, including a non-NULL empty
-- payload whose length would encode NULL. This does not validate the
-- type declaration or the payload's semantic value.
putValue :: TdsContext -> TypeInfo -> RawBytes -> Put
putValue _ctx ti rb = case valueProblem ti rb of
  Just p -> error ("putValue: " ++ p)
  Nothing -> putValueUnchecked ti rb

-- | 'putValue' __without the check__, for a value checked with
-- 'valueProblem'. Invalid lengths can wrap or encode NULL ('writeValue').
putValueUnchecked :: TypeInfo -> RawBytes -> Put
putValueUnchecked ti = Put.putBuilder . writeValue ti

------------------------------------------------------------------------------

-- | The T-SQL type declaration for a parameter of this type, as used in the
-- @\@params@ argument of @sp_executesql@.
typeInfoSqlName :: TypeInfo -> Text
typeInfoSqlName = \case
  TINull -> "sql_variant"
  TIBit -> "bit"
  TIInt1 -> "tinyint"
  TIInt2 -> "smallint"
  TIInt4 -> "int"
  TIInt8 -> "bigint"
  TIMoney4 -> "smallmoney"
  TIMoney8 -> "money"
  TIDateTime4 -> "smalldatetime"
  TIDateTime8 -> "datetime"
  TIFlt4 -> "real"
  TIFlt8 -> "float"
  TIBitN -> "bit"
  TIIntN 1 -> "tinyint"
  TIIntN 2 -> "smallint"
  TIIntN 4 -> "int"
  TIIntN _ -> "bigint"
  TIMoneyN 4 -> "smallmoney"
  TIMoneyN _ -> "money"
  TIDateTimeN 4 -> "smalldatetime"
  TIDateTimeN _ -> "datetime"
  TIFltN 4 -> "real"
  TIFltN _ -> "float"
  TIGuid -> "uniqueidentifier"
  TIDecimalN p s -> "decimal(" <> tshow p <> "," <> tshow s <> ")"
  TINumericN p s -> "numeric(" <> tshow p <> "," <> tshow s <> ")"
  TIDateN -> "date"
  TITimeN s -> "time(" <> tshow s <> ")"
  -- The declarations of the common parameters, without building them
  -- (@sp_executesql@'s @\@params@ names every parameter's type).
  TIDateTime2N 7 -> "datetime2(7)"
  TIDateTimeOffsetN 7 -> "datetimeoffset(7)"
  TINVarChar 8000 _ -> "nvarchar(4000)"
  TINVarChar 0xFFFF _ -> "nvarchar(max)"
  TIBigVarBinary 8000 -> "varbinary(8000)"
  TIBigVarBinary 0xFFFF -> "varbinary(max)"
  TIDateTime2N s -> "datetime2(" <> tshow s <> ")"
  TIDateTimeOffsetN s -> "datetimeoffset(" <> tshow s <> ")"
  TIBigChar len _ -> "char(" <> tshow len <> ")"
  TIBigVarChar len _ -> "varchar(" <> sizeOrMax len <> ")"
  TIText _ _ -> "text"
  TINChar len _ -> "nchar(" <> tshow (len `div` 2) <> ")"
  TINVarChar len _ -> "nvarchar(" <> (if len == maxLength then "max" else tshow (len `div` 2)) <> ")"
  TINText _ _ -> "ntext"
  TIBigBinary len -> "binary(" <> tshow len <> ")"
  TIBigVarBinary len -> "varbinary(" <> sizeOrMax len <> ")"
  TIImage _ -> "image"
  TIXml _ -> "xml"
  TISqlVariant _ -> "sql_variant"
  -- System CLR types are declared by name; others need their schema.
  TIUdt UdtInfo{..}
    | udtSchemaName == "sys" -> udtTypeName
    | otherwise -> quote udtSchemaName <> "." <> quote udtTypeName
  where
    quote n = "[" <> T.replace "]" "]]" n <> "]"
    tshow :: Show a => a -> Text
    tshow = T.pack . show
    sizeOrMax len = if len == maxLength then "max" else tshow len
