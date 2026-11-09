-- | Materialization helpers for assertions about in-memory wire fixtures.
module RecipeParameters where
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Hmssql.Encoding
import qualified Hmssql.BulkCopy as Bulk
import Hmssql.Tds.TypeInfo
import Hmssql.Tds.Context
import Hmssql.Tds.Client
import Hmssql.Tds.Packet (headerLength)
import Hmssql.Tds.PacketWriter
import Hmssql.Query.Types
parameterBytes :: ParamValue -> RawBytes
parameterBytes (ParamBytes b) = b
parameterBytes (ParamLazy b) = Just (LB.toStrict b)
parameterBytes (ParamStream _) = error "effectful source in a strict wire fixture"
encodedBytes :: Either String EncodedParam -> Either String (TypeInfo, RawBytes)
encodedBytes = fmap (\(ti, v) -> (ti, parameterBytes v))
encodeFieldBytes encoder ctx = encodedBytes . encodeParam encoder ctx
encodeBulkCellBytes ctx col (ti, bytes) = parameterBytes <$> Bulk.encodeBulkCell ctx col (ti, ParamBytes bytes)
byteParam name status ti bytes = RpcParam name status ti (ParamBytes bytes)
requestBytes :: TdsContext -> Request -> IO LB.ByteString
requestBytes ctx req = do
  packets <- newIORef []
  runPacketWriter ctx (requestPacketType req) (\p -> modifyIORef' packets (B.drop headerLength p :)) (requestBody req ctx)
  LB.fromChunks . reverse <$> readIORef packets
-- RpcParam no longer has Eq: a source is effectful. Compare strict fixtures
-- through their declared types and bytes instead of inventing source equality.
rpcView (RpcRequest proc options params) = (proc, options, [(rpcParamName p, rpcParamStatus p, rpcParamType p, parameterBytes (rpcParamValue p)) | p <- params])
