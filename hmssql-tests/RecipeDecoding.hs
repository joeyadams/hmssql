module RecipeDecoding (decodeFixture) where
import Control.Exception
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Parser as P

decodeFixture :: [ColumnInfo] -> CompiledRow a -> [RawBytes] -> IO (Either DecodeError a)
decodeFixture columns compiled values = do
  let bytes = LB.toStrict $ Put.runPut $ Put.putWord8 0xD1 >> sequence_ (zipWith cell columns values)
      cell col value = case lengthKind (columnType col) of
        LongLen -> case value of
          Nothing -> Put.putWord8 0
          Just bs -> Put.putWord8 1 >> Put.putWord8 0 >> Put.putWord64le 0 >> Put.putWord32le (fromIntegral (B.length bs)) >> Put.putByteString bs
        _ -> putValueUnchecked (columnType col) value
  (result, _) <- P.parseChunks (rowRecipe compiled 1048576) [bytes]
  case result of
    Left (DecodeFailed err) -> pure (Left err)
    Left ReadDiscarded -> throwIO (userError "a fixture row was discarded")
    Right a -> pure (Right a)
