-- | Test-only adapter for assertions written with binary's Get combinators.
-- It interprets the library recipe over each input buffer; there is no wire
-- layout here and it is not an independent reference parser. Consumer effects
-- are forbidden. Each decoder continuation must be driven once.
module Wire.RecipeGet (getToken, getTypeInfo, getDecimalInfo, getValue, getRowValue, recipeGet) where
import Data.Word (Word8)
import Control.Exception (try)
import qualified Data.Binary.Get as G
import qualified Data.Binary.Get.Internal as G
import qualified Data.ByteString as B
import Streaming (inspect)
import System.IO.Unsafe (unsafePerformIO)
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo
import Hmssql.Tds.Token
import qualified Hmssql.Tds.Parser as P
import qualified Hmssql.Tds.Value as V

recipeGet :: P.Parser a -> G.Get a
recipeGet recipe = do
  bytes <- G.get
  G.put B.empty
  drive (P.parse recipe bytes)
  where
    drive s = case unsafePerformIO (try (inspect s)) of
      Left (P.ProtocolError message) -> fail message
      Right (Left (P.Got a rest)) -> G.put rest >> pure a
      Right (Right (P.NeedMore k)) -> do
        G.ensureN 1
        bytes <- G.get
        G.put B.empty
        drive (k (P.More bytes))
      Right (Right P.RunConsumer{}) -> fail "consumer in a wire-test recipe"

getToken :: TdsContext -> Maybe [ColumnInfo] -> G.Get Token
getToken _ctx cols = recipeGet (readToken (compileResultSet <$> cols))
getTypeInfo :: TdsContext -> G.Get TypeInfo
getTypeInfo _ctx = recipeGet readTypeInfo
getDecimalInfo :: (Word8 -> Word8 -> a) -> G.Get a
getDecimalInfo = recipeGet . readDecimalInfo
getValue, getRowValue :: TdsContext -> TypeInfo -> G.Get RawBytes
getValue _ = value . V.valueShape
getRowValue _ = value . V.rowShape
value :: V.ColumnShape -> G.Get RawBytes
value shape = recipeGet $ V.cellHead shape >>= \case
  V.NullCell -> pure Nothing
  cell -> V.ownedValue lobAllocAhead cell
