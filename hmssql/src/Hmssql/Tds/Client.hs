{-# LANGUAGE MagicHash #-}
-- | Messages sent from the client to the server.
--
-- [MS-TDS 2.2.6 Client Messages](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/7ea9ee1a-b461-41f2-9004-141c0e712935)
module Hmssql.Tds.Client
  ( -- * PRELOGIN
    Prelogin (..)
  , PreloginOption (..)
  , Encryption (..)
  , encryptionWord
  , encryptionFromWord
  , putPrelogin
  , getPrelogin

    -- * LOGIN7
  , Login7 (..)
  , Feature (..)
  , featureUtf8Support
  , featureFedAuthToken
  , defaultLogin7
  , putLogin7
  , login7Problem
  , obfuscatePassword

    -- * SQLBatch and RPC
  , putAllHeaders
  , putSqlBatch
  , sqlBatchProblem, sqlBatchBuilder, rpcRequestBuilder, rpcParamBuilder, allHeadersBuilder
  , sqlBatchBody
  , RpcRequest (..)
  , RpcProc (..)
  , RpcParam (..)
  , paramByRef
  , paramDefault
  , procSpExecuteSql
  , putRpcRequest
  , rpcRequestBody
  , rpcRequestBodyUnchecked
  , newRpcWriter, writeRpcRequests
  , rpcRequestProblem
  , rpcParamProblem

    -- * Transaction Manager requests
  , tmBeginTransactionBuilder
  , tmBeginTransactionBody
  ) where

import Control.Exception (throwIO)
import Data.IORef
import Hmssql.Errors (EncodeError (..))
import Hmssql.Internal.Derived
import Hmssql.Tds.Parameter
import Hmssql.Tds.PacketWriter (PacketWriter, writeBuilder)
import Control.Monad (foldM, foldM_, forM_, when)
import Data.Binary.Get (Get)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put, PutM)
import qualified Data.Binary.Put as Put
import Data.Bits (shiftL, shiftR, xor, (.|.), (.&.))
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.List (intersperse, sortOn)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text.Internal as TI
import qualified Data.Text as T
import Data.Word (Word16, Word32, Word8)

import Hmssql.Tds.Packet (maxSqlBatchPackets, packetPayloadSize)
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives (ucs2Length)
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

------------------------------------------------------------------------------
-- PRELOGIN

-- | How much of the connection is encrypted ('Hmssql.Connection.connectEncryption').
-- The first four are the values of the ENCRYPTION option of PRELOGIN, where
-- the client and the server negotiate.  'EncryptStrict' is TDS 8.0, which
-- never negotiates.
data Encryption
  = EncryptOff
    -- ^ Encrypt the login packet only, or the whole session if the server
    -- requires it.  If the server doesn't support encryption at all,
    -- nothing is encrypted, not even the password.  (0x00)
  | EncryptOn
    -- ^ Encrypt the whole session, and fail if the server doesn't support
    -- encryption.  The default.  (0x01)
  | EncryptNotSup
    -- ^ Encrypt nothing, and fail if the server requires encryption.  (0x02)
  | EncryptReq
    -- ^ Encryption required.  It behaves as 'EncryptOn' does.  (0x03)
  | EncryptStrict
    -- ^ TDS 8.0: TLS from the first byte, before any PRELOGIN, and a
    -- failure against a server that doesn't support TDS 8.0.  (0x04, which
    -- is never sent, since there is no PRELOGIN to send it in)
  deriving stock (Eq, Show)

encryptionWord :: Encryption -> Word8
encryptionWord = \case
  EncryptOff -> 0x00
  EncryptOn -> 0x01
  EncryptNotSup -> 0x02
  EncryptReq -> 0x03
  EncryptStrict -> 0x04

encryptionFromWord :: Word8 -> Maybe Encryption
encryptionFromWord = \case
  0x00 -> Just EncryptOff
  0x01 -> Just EncryptOn
  0x02 -> Just EncryptNotSup
  0x03 -> Just EncryptReq
  0x04 -> Just EncryptStrict
  _ -> Nothing

-- | One option of a PRELOGIN message.
data PreloginOption
  = PLVersion !Word8 !Word8 !Word16 !Word16   -- ^ major, minor, build, sub-build
  | PLEncryption !Word8
  | PLInstance !B.ByteString
  | PLThreadId !(Maybe Word32)
  | PLMars !Word8
  | PLTraceId !B.ByteString !B.ByteString !Word32
  | PLFedAuthRequired !Word8
  | PLNonce !B.ByteString
  | PLUnknown !Word8 !B.ByteString

instance Show PreloginOption where
  showsPrec p = \case
    PLVersion a b c e -> showCon p "PLVersion"# [Arg a, Arg b, Arg c, Arg e]
    PLEncryption a -> showCon1 p "PLEncryption"# a
    PLInstance a -> showCon1 p "PLInstance"# a
    PLThreadId a -> showCon1 p "PLThreadId"# a
    PLMars a -> showCon1 p "PLMars"# a
    PLTraceId a b c -> showCon p "PLTraceId"# [Arg a, Arg b, Arg c]
    PLFedAuthRequired a -> showCon1 p "PLFedAuthRequired"# a
    PLNonce a -> showCon1 p "PLNonce"# a
    PLUnknown a b -> showCon p "PLUnknown"# [Arg a, Arg b]
  {-# OPAQUE showsPrec #-}

instance Eq PreloginOption where
  x == y = case (x, y) of
    (PLVersion a b c e, PLVersion a' b' c' e') -> a == a' && b == b' && c == c' && e == e'
    (PLEncryption a, PLEncryption a') -> a == a'
    (PLInstance a, PLInstance a') -> eq a a'
    (PLThreadId a, PLThreadId a') -> eq a a'
    (PLMars a, PLMars a') -> a == a'
    (PLTraceId a b c, PLTraceId a' b' c') -> eq a a' && eq b b' && c == c'
    (PLFedAuthRequired a, PLFedAuthRequired a') -> a == a'
    (PLNonce a, PLNonce a') -> eq a a'
    (PLUnknown a b, PLUnknown a' b') -> a == a' && eq b b'
    _ -> False
  {-# OPAQUE (==) #-}

-- | A PRELOGIN message: its options, in order.
newtype Prelogin = Prelogin [PreloginOption]
  deriving stock (Eq)

instance Show Prelogin where
  showsPrec p (Prelogin a) = showCon1 p "Prelogin"# a
  {-# OPAQUE showsPrec #-}

optionToken :: PreloginOption -> Word8
optionToken = \case
  PLVersion{} -> 0x00
  PLEncryption{} -> 0x01
  PLInstance{} -> 0x02
  PLThreadId{} -> 0x03
  PLMars{} -> 0x04
  PLTraceId{} -> 0x05
  PLFedAuthRequired{} -> 0x06
  PLNonce{} -> 0x07
  PLUnknown t _ -> t

optionPayload :: PreloginOption -> B.ByteString
optionPayload = LB.toStrict . Put.runPut . \case
  PLVersion ma mi b sb -> Put.putWord8 ma >> Put.putWord8 mi >> Put.putWord16be b >> Put.putWord16be sb
  PLEncryption e -> Put.putWord8 e
  PLInstance name -> Put.putByteString name >> Put.putWord8 0
  PLThreadId Nothing -> pure ()
  PLThreadId (Just t) -> Put.putWord32le t
  PLMars m -> Put.putWord8 m
  PLTraceId c a s -> Put.putByteString c >> Put.putByteString a >> Put.putWord32le s
  PLFedAuthRequired f -> Put.putWord8 f
  PLNonce n -> Put.putByteString n
  PLUnknown _ bs -> Put.putByteString bs

putPrelogin :: Prelogin -> Put
putPrelogin (Prelogin opts) = do
  let payloads = map optionPayload opts
      tableLength = 5 * length opts + 1
  foldM_ putIndex tableLength (zip opts payloads)
  Put.putWord8 0xFF
  mapM_ Put.putByteString payloads
  where
    putIndex :: Int -> (PreloginOption, B.ByteString) -> PutM Int
    putIndex offset (opt, payload) = do
      Put.putWord8 $ optionToken opt
      Put.putWord16be $ fromIntegral offset
      Put.putWord16be $ fromIntegral $ B.length payload
      pure $ offset + B.length payload

getPrelogin :: Get Prelogin
getPrelogin = do
  entries <- getEntries
  let tableLength = 5 * length entries + 1
      end = maximum (tableLength : [o + l | (_, o, l) <- entries])
  -- Offsets count from the start of the message, so a non-empty option
  -- can't start inside the option table.
  forM_ entries $ \(t, o, l) ->
    when (l > 0 && o < tableLength) $
      fail $ "getPrelogin: option " ++ show t ++ " at offset " ++ show o ++ ", inside the option table"
  payload <- Get.getByteString (end - tableLength)
  let slice o l = B.take l (B.drop (o - tableLength) payload)
  Prelogin <$> mapM (\(t, o, l) -> decodeOption t (slice o l)) (sortOn (\(_, o, _) -> o) entries)
  where
    getEntries = do
      t <- Get.getWord8
      if t == 0xFF
        then pure []
        else do
          o <- fromIntegral <$> Get.getWord16be
          l <- fromIntegral <$> Get.getWord16be
          ((t, o, l) :) <$> getEntries

    decodeOption :: Word8 -> B.ByteString -> Get PreloginOption
    decodeOption t bs = case t of
      0x00 -> run $ PLVersion <$> Get.getWord8 <*> Get.getWord8 <*> Get.getWord16be <*> Get.getWord16be
      0x01 -> run $ PLEncryption <$> Get.getWord8
      0x02 -> pure $ PLInstance (B.takeWhile (/= 0) bs)
      0x03 | B.null bs -> pure $ PLThreadId Nothing
           | otherwise -> run $ PLThreadId . Just <$> Get.getWord32le
      0x04 -> run $ PLMars <$> Get.getWord8
      0x05 -> run $ PLTraceId <$> Get.getByteString 16 <*> Get.getByteString 16 <*> Get.getWord32le
      0x06 -> run $ PLFedAuthRequired <$> Get.getWord8
      0x07 -> pure $ PLNonce bs
      _ -> pure $ PLUnknown t bs
      where
        run g = case Get.runGetOrFail g (LB.fromStrict bs) of
          Right (_, _, v) -> pure v
          Left (_, _, err) -> fail $ "getPrelogin: option " ++ show t ++ ": " ++ err

------------------------------------------------------------------------------
-- LOGIN7

-- | A LOGIN7 feature extension.
-- [MS-TDS 2.2.6.4 FeatureExt](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/773a62b6-ee89-4c02-9e5e-344882630aac)
data Feature = Feature
  { featureId :: !Word8
  , featureData :: !B.ByteString
  }

instance Eq Feature where
  Feature a b == Feature a' b' = a == a' && eq b b'
  {-# OPAQUE (==) #-}

-- | As derived, except that the data of a FEDAUTH feature (an access
-- token) is shown as @<redacted>@.
instance Show Feature where
  showsPrec p Feature{..} = showRecord p "Feature"#
    [ "featureId"# := featureId
    , if featureId == fedAuthFeatureId
        then "featureData"# := Verbatim "<redacted>"
        else "featureData"# := featureData
    ]
  {-# OPAQUE showsPrec #-}

-- | Tell the server we can handle UTF-8 collations.
featureUtf8Support :: Feature
featureUtf8Support = Feature 0x0A (B.singleton 0x01)

-- | The FEDAUTH feature extension.
fedAuthFeatureId :: Word8
fedAuthFeatureId = 0x02

-- | Federated authentication with an access token the caller obtained
-- (MS-TDS calls the library "Security Token", 0x01): the token, UTF-16
-- encoded, goes in LOGIN7 and the server validates it; there is no further
-- exchange, unlike the MSAL library's, where the server first names the
-- token issuer (FEDAUTHINFO).
--
-- The first argument echoes the server's PRELOGIN answer to the
-- FEDAUTHREQUIRED option (the client must send that option to use this
-- feature), and the last is the nonce from that answer, if the server sent
-- one, which it only does when the client sent one.
featureFedAuthToken :: Bool -> Text -> Maybe B.ByteString -> Feature
featureFedAuthToken echo token nonce = Feature fedAuthFeatureId $ LB.toStrict $ Put.runPut $ do
  -- Options: bFedAuthLibrary in the upper 7 bits, fFedAuthEcho the lowest.
  Put.putWord8 $ (0x01 `shiftL` 1) .|. (if echo then 0x01 else 0x00)
  let bytes = Utf16.encodeUtf16LE token
  Put.putWord32le $ fromIntegral $ B.length bytes
  Put.putByteString bytes
  mapM_ Put.putByteString nonce

-- | A LOGIN7 message, which 'putLogin7' writes; start from 'defaultLogin7'.
data Login7 = Login7
  { l7Version :: !TdsVersion
  , l7PacketSize :: !Word32
  , l7ClientProgVer :: !Word32
  , l7ClientPid :: !Word32
  , l7ConnectionId :: !Word32
  , l7OptionFlags1 :: !Word8
  , l7OptionFlags2 :: !Word8
  , l7TypeFlags :: !Word8
  , l7OptionFlags3 :: !Word8
  , l7TimeZone :: !Int32
  , l7Collation :: !Word32
  , l7HostName :: !Text
  , l7UserName :: !Text
  , l7Password :: !Text
  , l7AppName :: !Text
  , l7ServerName :: !Text
  , l7LibraryName :: !Text
  , l7Language :: !Text
  , l7Database :: !Text
  , l7ClientId :: !B.ByteString
    -- ^ 6 bytes, nominally the MAC address.
  , l7Features :: ![Feature]
  }

instance Eq Login7 where
  Login7 a b c e f g h i j k l m n o q r s t u v w
      == Login7 a' b' c' e' f' g' h' i' j' k' l' m' n' o' q' r' s' t' u' v' w' =
    eq a a' && b == b' && c == c' && e == e' && f == f' && g == g' && h == h' && i == i'
      && j == j' && k == k' && l == l' && eq m m' && eq n n' && eq o o' && eq q q'
      && eq r r' && eq s s' && eq t t' && eq u u' && eq v v' && eq w w'
  {-# OPAQUE (==) #-}

-- | As derived, except that a non-empty password is shown as @<redacted>@.
instance Show Login7 where
  showsPrec p Login7{..} = showRecord p "Login7"#
    [ "l7Version"# := l7Version, "l7PacketSize"# := l7PacketSize
    , "l7ClientProgVer"# := l7ClientProgVer, "l7ClientPid"# := l7ClientPid
    , "l7ConnectionId"# := l7ConnectionId, "l7OptionFlags1"# := l7OptionFlags1
    , "l7OptionFlags2"# := l7OptionFlags2, "l7TypeFlags"# := l7TypeFlags
    , "l7OptionFlags3"# := l7OptionFlags3, "l7TimeZone"# := l7TimeZone
    , "l7Collation"# := l7Collation, "l7HostName"# := l7HostName
    , "l7UserName"# := l7UserName
    , "l7Password"# := Verbatim (if T.null l7Password then "\"\"" else "<redacted>")
    , "l7AppName"# := l7AppName, "l7ServerName"# := l7ServerName
    , "l7LibraryName"# := l7LibraryName, "l7Language"# := l7Language
    , "l7Database"# := l7Database, "l7ClientId"# := l7ClientId
    , "l7Features"# := l7Features
    ]
  {-# OPAQUE showsPrec #-}

-- | TDS 7.4, 4096-byte packets, empty names, and the UTF-8 feature.
defaultLogin7 :: Login7
defaultLogin7 = Login7
  { l7Version = Tds74
  , l7PacketSize = 4096
  , l7ClientProgVer = 0
  , l7ClientPid = 0
  , l7ConnectionId = 0
  , l7OptionFlags1 = 0x80 .|. 0x40 .|. 0x20   -- fSetLang | fDatabase (fatal if missing) | fUseDB
  , l7OptionFlags2 = 0x02 .|. 0x01            -- fODBC | fLanguage (fatal if missing)
  , l7TypeFlags = 0
  , l7OptionFlags3 = 0
  , l7TimeZone = 0
  , l7Collation = 0
  , l7HostName = ""
  , l7UserName = ""
  , l7Password = ""
  , l7AppName = ""
  , l7ServerName = ""
  , l7LibraryName = "hmssql"
  , l7Language = ""
  , l7Database = ""
  , l7ClientId = B.replicate 6 0
  , l7Features = [featureUtf8Support]
  }

-- | Swap the nibbles of each byte, then XOR with 0xA5.
obfuscatePassword :: B.ByteString -> B.ByteString
obfuscatePassword = B.map $ \b -> ((b `shiftL` 4) .|. (b `shiftR` 4)) `xor` 0xA5

login7FixedLength :: Int
login7FixedLength = 94

-- | Why 'putLogin7' can't encode this login, if it can't: its strings
-- (host, user, password, application, server, library, language and
-- database names) are located by 16-bit offsets from the start of the
-- message, so together they must end by byte 65535.  (Written modulo 65536
-- instead, a long application name would shift where the server reads the
-- following fields from.)  The server's own limit of 128 characters per
-- field is left to the server.  The message gives the length of each field
-- but the password's.
login7Problem :: Login7 -> Maybe String
login7Problem l
  | end > 0xFFFF = Just $
      "the LOGIN7 strings are " ++ show (end - login7FixedLength) ++ " bytes long"
        ++ " (host " ++ show (ucs2Length (l7HostName l)) ++ ", user " ++ show (ucs2Length (l7UserName l))
        ++ ", application " ++ show (ucs2Length (l7AppName l))
        ++ ", server " ++ show (ucs2Length (l7ServerName l)) ++ ", library " ++ show (ucs2Length (l7LibraryName l))
        ++ ", language " ++ show (ucs2Length (l7Language l)) ++ ", database " ++ show (ucs2Length (l7Database l))
        ++ " UTF-16 code units, and the password); the wire format's 16-bit offsets allow at most "
        ++ show (0xFFFF - login7FixedLength - 4) ++ " bytes"
  | otherwise = Nothing
  where
    end = login7FixedLength + (if null (l7Features l) then 0 else 4)
      + 2 * sum (map ucs2Length [ l7HostName l, l7UserName l, l7Password l, l7AppName l
                                , l7ServerName l, l7LibraryName l, l7Language l, l7Database l ])

-- | Fails (with 'error') if there is a 'login7Problem'.
putLogin7 :: Login7 -> Put
putLogin7 l = do
  mapM_ (\p -> error ("putLogin7: " ++ p)) (login7Problem l)
  let ucs2 = Utf16.encodeUtf16LE
      hasFeatures = not (null (l7Features l))
      flags3 = l7OptionFlags3 l .|. (if hasFeatures then 0x10 else 0)
      -- FeatureExt: each feature's id, length and data, then a terminator.
      featureExtLength
        | hasFeatures = sum [5 + B.length featureData | Feature{..} <- l7Features l] + 1
        | otherwise = 0
      -- Data section in wire order.  The extension slot holds a DWORD offset
      -- to FeatureExt, which is appended after everything else.
      hostName = ucs2 (l7HostName l)
      userName = ucs2 (l7UserName l)
      password = obfuscatePassword (ucs2 (l7Password l))
      appName = ucs2 (l7AppName l)
      serverName = ucs2 (l7ServerName l)
      libraryName = ucs2 (l7LibraryName l)
      language = ucs2 (l7Language l)
      database = ucs2 (l7Database l)
      extensionLen = if hasFeatures then 4 else 0
      firstHalf = [hostName, userName, password, appName, serverName]
      secondHalf = [libraryName, language, database]
      dataBeforeFeatures = sum (map B.length firstHalf) + extensionLen + sum (map B.length secondHalf)
      featureOffset = login7FixedLength + dataBeforeFeatures
      totalLength = featureOffset + featureExtLength

  Put.putWord32le $ fromIntegral totalLength
  Put.putWord32le $ tdsVersionWord (l7Version l)
  Put.putWord32le $ l7PacketSize l
  Put.putWord32le $ l7ClientProgVer l
  Put.putWord32le $ l7ClientPid l
  Put.putWord32le $ l7ConnectionId l
  Put.putWord8 $ l7OptionFlags1 l
  Put.putWord8 $ l7OptionFlags2 l
  Put.putWord8 $ l7TypeFlags l
  Put.putWord8 flags3
  Put.putInt32le $ l7TimeZone l
  Put.putWord32le $ l7Collation l

  off1 <- foldM putOffsetLength login7FixedLength firstHalf
  off2 <- putOffsetLengthBytes off1 extensionLen
  off3 <- foldM putOffsetLength off2 secondHalf
  Put.putByteString $ B.take 6 (l7ClientId l <> B.replicate 6 0)
  _ <- putOffsetLengthBytes off3 0   -- SSPI
  _ <- putOffsetLengthBytes off3 0   -- AttachDBFile
  _ <- putOffsetLengthBytes off3 0   -- ChangePassword
  Put.putWord32le 0                  -- cbSSPILong

  mapM_ Put.putByteString firstHalf
  if hasFeatures then Put.putWord32le (fromIntegral featureOffset) else pure ()
  mapM_ Put.putByteString secondHalf
  when hasFeatures $ do
    forM_ (l7Features l) $ \Feature{..} -> do
      Put.putWord8 featureId
      Put.putWord32le $ fromIntegral $ B.length featureData
      Put.putByteString featureData
    Put.putWord8 0xFF
  where
    -- Lengths are in characters for strings; the extension slot is in bytes.
    putOffsetLength :: Int -> B.ByteString -> PutM Int
    putOffsetLength offset bs = do
      Put.putWord16le $ fromIntegral offset
      Put.putWord16le $ fromIntegral (B.length bs `div` 2)
      pure $ offset + B.length bs

    putOffsetLengthBytes :: Int -> Int -> PutM Int
    putOffsetLengthBytes offset len = do
      Put.putWord16le $ fromIntegral offset
      Put.putWord16le $ fromIntegral len
      pure $ offset + len

------------------------------------------------------------------------------
-- SQLBatch and RPC

-- | ALL_HEADERS with a single Transaction Descriptor header.
-- MS-TDS 2.2.5.3 Packet Data Stream Headers
putAllHeaders :: TdsContext -> Put
putAllHeaders = Put.putBuilder . allHeadersBuilder

allHeadersBuilder :: TdsContext -> BB.Builder
allHeadersBuilder ctx =
  BB.word32LE 22 <> BB.word32LE 18 <> BB.word16LE 0x0002 <>
  BB.word64LE descriptor <> BB.word32LE 1
  where TransactionDescriptor descriptor = maybe (TransactionDescriptor 0) id (tdsTransaction ctx)

-- | The server's packet-count limit for a SQL batch. Most text fits using
-- its UTF-8 byte count as a bound, avoiding a separate whole-text scan.
sqlBatchProblem :: TdsContext -> Text -> Maybe String
sqlBatchProblem ctx sql@(TI.Text _ _ utf8Length)
  | utf8Length <= limit `div` 2 = Nothing
  | actual <= limit = Nothing
  | otherwise = Just ("SQL batch too large: its " ++ show (actual + 22) ++
      " bytes exceed the limit of " ++ show maxSqlBatchPackets ++ " packets")
  where
    limit = fromIntegral maxSqlBatchPackets * packetPayloadSize ctx - 22
    actual = 2 * Utf16.utf16Length sql

putSqlBatch :: TdsContext -> Text -> Put
putSqlBatch ctx = Put.putBuilder . sqlBatchBuilder ctx

sqlBatchBuilder :: TdsContext -> Text -> BB.Builder
sqlBatchBuilder ctx sql = allHeadersBuilder ctx <> Utf16.utf16LEBuilder sql

sqlBatchBody :: TdsContext -> Text -> LB.ByteString
sqlBatchBody ctx = BB.toLazyByteString . sqlBatchBuilder ctx

-- | The body of a Transaction Manager request that begins a transaction
-- (MS-TDS 2.2.6.9, TM_BEGIN_XACT): ALL_HEADERS, the request type (5), the
-- isolation level (0 keeps the session's; 1 READ UNCOMMITTED, 2 READ
-- COMMITTED, 3 REPEATABLE READ, 4 SERIALIZABLE, 5 SNAPSHOT, which the
-- session then keeps after the transaction), and an empty transaction
-- name.
tmBeginTransactionBuilder :: TdsContext -> Word8 -> BB.Builder
tmBeginTransactionBuilder ctx level = allHeadersBuilder ctx <> BB.word16LE 5 <> BB.word8 level <> BB.word8 0

tmBeginTransactionBody :: TdsContext -> Word8 -> LB.ByteString
tmBeginTransactionBody ctx = BB.toLazyByteString . tmBeginTransactionBuilder ctx

-- | The procedure an RPC calls: by its identifier ('procSpExecuteSql' is
-- @sp_executesql@) or by name.
data RpcProc
  = RpcProcId !Word16
  | RpcProcName !Text

instance Show RpcProc where
  showsPrec p = \case
    RpcProcId a -> showCon1 p "RpcProcId"# a
    RpcProcName a -> showCon1 p "RpcProcName"# a
  {-# OPAQUE showsPrec #-}

instance Eq RpcProc where
  x == y = case (x, y) of
    (RpcProcId a, RpcProcId a') -> a == a'
    (RpcProcName a, RpcProcName a') -> eq a a'
    _ -> False
  {-# OPAQUE (==) #-}

procSpExecuteSql :: RpcProc
procSpExecuteSql = RpcProcId 10

-- | A parameter of an RPC.
data RpcParam = RpcParam
  { rpcParamName :: !Text
    -- ^ Including the leading @\@@; may be empty for positional parameters.
  , rpcParamStatus :: !Word8
  , rpcParamType :: !TypeInfo
  , rpcParamValue :: !ParamValue
  }

instance Show RpcParam where
  showsPrec p (RpcParam a b c e) = showRecord p "RpcParam"#
    [ "rpcParamName"# := a, "rpcParamStatus"# := b, "rpcParamType"# := c
    , "rpcParamValue"# := e
    ]
  {-# OPAQUE showsPrec #-}

-- | Status flag: the parameter is an output parameter.
paramByRef :: Word8
paramByRef = 0x01

-- | Status flag: use the procedure's default value.
paramDefault :: Word8
paramDefault = 0x02

-- | One RPC: the procedure, the option flags and the parameters.
data RpcRequest = RpcRequest
  { rpcProc :: !RpcProc
  , rpcOptions :: !Word16
  , rpcParams :: ![RpcParam]
  }

instance Show RpcRequest where
  showsPrec p (RpcRequest a b c) =
    showRecord p "RpcRequest"# ["rpcProc"# := a, "rpcOptions"# := b, "rpcParams"# := c]
  {-# OPAQUE showsPrec #-}

-- | One or more RPCs in a single request, separated by the 0xFF batch flag.
--
-- Fails (with 'error') if 'rpcRequestProblem' finds a problem; callers
-- check first.  (Writing a name or value length modulo the size of its
-- length prefix would make the server read the rest as further fields: a
-- 300-character parameter name would go out as a 44-character name followed
-- by what the server takes for the parameter's type and value.)
putRpcRequest :: TdsContext -> [RpcRequest] -> Put
putRpcRequest ctx reqs = Put.putLazyByteString (rpcRequestBody ctx reqs)

-- | The bytes of 'putRpcRequest': fails (with 'error', when forced) if
-- 'rpcRequestProblem' finds a problem.
rpcRequestBody :: TdsContext -> [RpcRequest] -> LB.ByteString
rpcRequestBody ctx reqs = case mapMaybe rpcRequestProblem reqs of
  p : _ -> error ("putRpcRequest: " ++ p)
  [] -> rpcRequestBodyUnchecked ctx reqs

-- | Build a checked request's bytes with the same Builder used for sending.
rpcRequestBodyUnchecked :: TdsContext -> [RpcRequest] -> LB.ByteString
rpcRequestBodyUnchecked ctx = BB.toLazyByteString . rpcRequestBuilder ctx

rpcRequestBuilder :: TdsContext -> [RpcRequest] -> BB.Builder
rpcRequestBuilder ctx requests = allHeadersBuilder ctx <> go requests
  where
    go [] = mempty
    go [r] = request r
    go (r : rs) = request r <> BB.word8 0xFF <> go rs
    request RpcRequest{..} = proc rpcProc <> BB.word16LE rpcOptions <> foldMap rpcParamBuilder rpcParams
    proc (RpcProcId pid) = BB.word16LE 0xFFFF <> BB.word16LE pid
    proc (RpcProcName name) = BB.word16LE (fromIntegral (Utf16.utf16Length name)) <> Utf16.utf16LEBuilder name

rpcParamBuilder :: RpcParam -> BB.Builder
rpcParamBuilder param@RpcParam{..} = rpcParamHeader param <> case rpcParamValue of
  ParamBytes bytes -> writeValue rpcParamType bytes
  _ -> error "streamed RPC values require writeRpcRequests"

-- Shared by the sender and the in-memory serializer, so the two can't disagree.
-- Inlined so that its Builder composes with the value's at the call site.
rpcParamHeader :: RpcParam -> BB.Builder
rpcParamHeader RpcParam{..} =
  BB.word8 (fromIntegral (Utf16.utf16Length rpcParamName)) <> Utf16.utf16LEBuilder rpcParamName <>
  BB.word8 rpcParamStatus <> writeTypeInfo rpcParamType
{-# INLINE rpcParamHeader #-}

-- | Why 'putRpcRequest' can't encode this RPC, if it can't: a procedure name
-- of 65535 or more UTF-16 code units (NameLenProcID is a USHORT, and 0xFFFF
-- announces a procedure ID instead), or an 'rpcParamProblem'.
rpcRequestProblem :: RpcRequest -> Maybe String
rpcRequestProblem RpcRequest{..} = case rpcProc of
  RpcProcName name
    | ucs2Length name >= 0xFFFF ->
        Just $ "the procedure name is " ++ show (ucs2Length name)
          ++ " UTF-16 code units long; the wire format allows at most 65534"
  _ -> listToMaybe (mapMaybe rpcParamProblem rpcParams)

-- | Why a parameter can't be sent, if it can't: a name of more than 255
-- UTF-16 code units (a B_VARCHAR; SQL Server's own limit is 128 characters,
-- which it reports itself), a 'typeInfoProblem', or a 'valueProblem'.
rpcParamProblem :: RpcParam -> Maybe String
rpcParamProblem RpcParam{..}
  | ucs2Length rpcParamName > 0xFF = Just $
      "parameter name " ++ show (T.take 20 rpcParamName <> "...") ++ " is "
        ++ show (ucs2Length rpcParamName) ++ " UTF-16 code units long; the wire format allows at most 255"
        ++ " (and SQL Server at most 128 characters)"
  | otherwise = (("parameter " ++ label ++ ": ") ++) <$>
      maybe (if rpcParamStatus .&. paramByRef /= 0 && streamed rpcParamValue then Just "output parameters cannot stream" else paramValueProblem rpcParamType rpcParamValue) Just (typeInfoProblem rpcParamType)
  where
    label = if T.null rpcParamName then "(positional)" else T.unpack rpcParamName

-- | The writer of these requests.  In-memory requests can be sent any number
-- of times.  Requests with lazy or effectful values can be sent once: the
-- writer takes them out of a reference as it starts, so the request no longer
-- keeps a lazy value's head alive while it is sent, and a value is read once
-- no matter how many threads try.  A query builds a new writer per send.
newRpcWriter :: [RpcRequest] -> IO (TdsContext -> PacketWriter -> IO ())
newRpcWriter requests
  | not (any (any (streamed . rpcParamValue) . rpcParams) requests) = pure (\ctx out -> writeRpcRequests ctx out requests)
  | otherwise = do
      remaining <- newIORef (Just requests)
      pure $ \ctx out -> do
        pending <- atomicModifyIORef' remaining (\r -> (Nothing, r))
        case pending of
          Nothing -> throwIO (EncodeError "a request containing lazy or streamed parameters can be sent only once")
          Just rs -> writeRpcRequests ctx out rs

-- | Write requests whose types, names and values have been validated at
-- construction, in order, with one separator between requests.

-- Plain traversal of the lists is deliberate.  Once 'newRpcWriter' has taken the
-- requests, nothing refers to a parameter after its turn, and a private reference
-- per list would protect nothing more (Scale.ParameterResidency checks retention).
writeRpcRequests :: TdsContext -> PacketWriter -> [RpcRequest] -> IO ()
writeRpcRequests ctx out requests = do
  writeBuilder out (allHeadersBuilder ctx)
  sequence_ (intersperse (writeBuilder out (BB.word8 0xFF)) (map writeRequest requests))
  where
    writeRequest RpcRequest{..} =
      let header = (case rpcProc of
            RpcProcId pid -> BB.word16LE 0xFFFF <> BB.word16LE pid
            RpcProcName name -> BB.word16LE (fromIntegral (Utf16.utf16Length name)) <> Utf16.utf16LEBuilder name) <> BB.word16LE rpcOptions
       -- The request's header goes in one Builder with its first parameter.
       -- Later parameters have only their own header, so a many-parameter
       -- request pays nothing for this (measured: 3.5% less allocation for a
       -- one-integer request, no change with many parameters).
       in case rpcParams of
            [] -> writeBuilder out header
            first : rest -> do
              writeParamValueWith out (header <> rpcParamHeader first)
                (rpcParamType first) (rpcParamValue first)
              forM_ rest $ \param@RpcParam{..} ->
                writeParamValueWith out (rpcParamHeader param) rpcParamType rpcParamValue
