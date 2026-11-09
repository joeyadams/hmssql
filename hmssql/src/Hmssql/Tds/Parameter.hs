-- | A parameter's value, which is in memory, lazy, or read from a source as it
-- is sent, and how a value is written.
module Hmssql.Tds.Parameter
  ( ParamValue (..), Source (..), sourceOf, sourceIO, paramValueProblem
  , streamed, writeParamValue, writeParamValueWith
  ) where
import Control.Exception (throwIO)
import Control.Monad (when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Builder as BB
import Data.Word (Word8)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (plusPtr)
import Foreign.Storable (pokeByteOff)
import Streaming (Stream, Of)
import qualified Streaming.Prelude as S
import Hmssql.Errors (EncodeError (..))
import Hmssql.Tds.TypeInfo
import Hmssql.Tds.PacketWriter

-- | Where a streamed parameter's bytes come from.  It is a function of what
-- consumes the stream, so a resource can be scoped to exactly the send, for
-- example with @withBinaryFile@.  A bare stream couldn't scope one, and a second
-- send would run it from wherever it had got to.
newtype Source a = Source (forall r. (Stream (Of a) IO () -> IO r) -> IO r)
-- | Use an existing stream.  Holding on to the stream yourself keeps whatever
-- it has produced alive, and a stream can be sent only once.
sourceOf :: Stream (Of a) IO () -> Source a
sourceOf stream = Source (\use -> use stream)
-- | A stream made by this action when sending starts.  For a resource to release
-- after the send, use the 'Source' constructor.
sourceIO :: IO (Stream (Of a) IO ()) -> Source a
sourceIO open = Source (\use -> open >>= use)

-- | An in-memory value ('Nothing' is NULL), lazy bytes read as they are sent,
-- or a source run as it is sent.  A request holding either of the last two can
-- be sent only once; a query builds a new request each time it is sent.
--
-- The constructors are public so that libraries can inspect and build values.
data ParamValue = ParamBytes !RawBytes | ParamLazy LB.ByteString | ParamStream !(Source B.ByteString)
instance Show ParamValue where
  showsPrec n (ParamBytes b) = showParen (n > 10) (showString "ParamBytes " . showsPrec 11 b)
  showsPrec _ (ParamLazy _) = showString "ParamLazy <bytes>"
  showsPrec _ (ParamStream _) = showString "ParamStream <source>"

-- | Whether the value is sent as it is read, so it isn't in memory to check.
streamed :: ParamValue -> Bool
streamed (ParamBytes _) = False
streamed _ = True

-- | Why a value can't be sent in this type, if it can't.  A value sent as it is
-- read has no length ahead of time, so only a PLP type can carry it.
paramValueProblem :: TypeInfo -> ParamValue -> Maybe String
paramValueProblem ti (ParamBytes value) = valueProblem ti value
paramValueProblem ti _ = case lengthKind ti of
  Plp -> typeInfoProblem ti
  _ -> Just "a lazy or streamed parameter requires a PLP (max or xml) type"

-- | Write a parameter's value, which has been checked already
-- ('paramValueProblem').  A lazy or streamed value is written as a PLP value
-- of unknown total length, in chunks of at most 8000 bytes, with the source's
-- empty chunks left out; a UTF-16 source must end on a code unit boundary.
writeParamValue :: PacketWriter -> TypeInfo -> ParamValue -> IO ()
writeParamValue out = writeParamValueWith out mempty

-- | 'writeParamValue', with what comes before the value, such as the parameter's
-- header, in the same Builder.  A BYTE-length scalar is poked straight after the
-- header rather than composed with it; every other value runs the writer once
-- for both.
writeParamValueWith :: PacketWriter -> BB.Builder -> TypeInfo -> ParamValue -> IO ()
writeParamValueWith out prefix ti value = case value of
    -- Poked, a BYTE-length scalar allocates 147 bytes less per parameter than it
    -- did composed into the header's Builder (a packet of 100 parameters, GHC
    -- 9.12.4, 2026-11-04).  Poking every non-PLP kind the same way was more code
    -- and saved only 98 bytes, so the other kinds keep the Builder.
    ParamBytes bytes
      | ByteLen <- lengthKind ti -> writeBuilder out prefix >> writeByteLengthValue out bytes
      | otherwise -> writeBuilder out (prefix <> writeValue ti bytes)
    ParamLazy bytes -> send (sourceOf (S.each (LB.toChunks bytes)))
    ParamStream source -> send source
  where
    -- Checking the odd total before the terminator means a bad value never
    -- completes a message: the failure is handled as a source that threw.
    send (Source use) = inSource out $ do
      writeBuilder out (prefix <> BB.word64LE 0xFFFFFFFFFFFFFFFE)
      oddBytes <- use (go False)
      when (unicode && oddBytes) (throwIO (EncodeError "UTF-16 stream ended with an odd byte count"))
      writeBuilder out (BB.word32LE 0)
    go !parity source = S.next source >>= \case
      Left () -> pure parity
      Right (bytes, next) -> do
        pieces bytes
        go (parity /= odd (B.length bytes)) next
    -- Input chunks never reach the wire as they are.  An empty one would be the
    -- PLP terminator, and SQL Server's bulk parser refuses chunks over 8000 bytes.
    pieces bytes
      | B.null bytes = pure ()
      | otherwise = do
          let (chunk, rest) = B.splitAt 8000 bytes
          writeBuilder out (BB.word32LE (fromIntegral (B.length chunk)) <> BB.byteString chunk)
          pieces rest
    unicode = case ti of TINVarChar _ _ -> True; _ -> False

-- | Poke a BYTE-length value, checked already, as 'Hmssql.Tds.TypeInfo.writeValue'
-- would write it: its length in one byte, then its bytes.  NULL and an empty
-- value are both a zero length byte.  The payload is an immutable 'B.ByteString',
-- held alive through the copy, and the destination is the writer's private
-- packet storage; neither pointer leaves this function.
writeByteLengthValue :: PacketWriter -> RawBytes -> IO ()
writeByteLengthValue writer bytes =
  let payload = maybe B.empty id bytes
      n = B.length payload
   in unsafeWriteSized writer (1 + n) $ \p -> do
        pokeByteOff p 0 (fromIntegral n :: Word8)
        case payload of
          BI.BS src _ -> BI.unsafeWithForeignPtr src $ \from -> copyBytes (p `plusPtr` 1) from n
