{-# LANGUAGE MagicHash #-}
-- | Hold the Request itself alive while observing the heap after its first
-- large chunk was sent. This catches library references, not caller retention.
module Scale.ParameterResidencySpec (spec) where
import Control.Exception (evaluate)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Word (Word64)
import GHC.Exts (keepAlive#)
import GHC.IO (IO (..))
import GHC.Stats
import System.IO.Unsafe (unsafeInterleaveIO)
import System.Mem (performMajorGC)
import qualified Streaming as S
import qualified Streaming.Prelude as S
import Test.Hspec
import Hmssql
import Hmssql.Encoding
import Hmssql.Query
import Hmssql.Query.Types (Request)
import TestDb

live :: IO Word64
live = do
  performMajorGC
  stats <- getRTSStats
  let !bytes = gcdetails_live_bytes (gc stats)
  pure bytes

keep :: a -> IO b -> IO b
keep holder (IO action) = IO (\state -> keepAlive# holder state action)

makeRequest :: Bool -> Connection -> IORef Int -> IO () -> IO Request
makeRequest lazy conn size observe = do
  n <- readIORef size
  bytes <- evaluate (B.replicate n 42)
  if lazy then do
    tailBytes <- unsafeInterleaveIO (observe >> pure LB.empty)
    queryRequest conn ("SELECT DATALENGTH(" <> param (LB.fromStrict bytes <> tailBytes) <> ")")
  else queryRequest conn ("SELECT DATALENGTH(" <> param (binaryStream (sourceOf (S.yield bytes >> S.effect (observe >> pure (pure ()))))) <> ")")
{-# NOINLINE makeRequest #-}

spec :: Spec
spec = serial $ around withTestDb $ describe "parameter source residency" $
  mapM_ (\lazy -> it (if lazy then "releases the head of a lazy value during its send" else "releases a source chunk before pulling the next") $ \conn -> do
    size <- newIORef (32 * 1024 * 1024)
    observed <- newIORef Nothing
    before <- live
    request <- makeRequest lazy conn size (live >>= writeIORef observed . Just)
    keep request (responseS conn request >>= S.effects)
    seen <- readIORef observed
    case seen of
      Nothing -> expectationFailure "the source tail was not pulled"
      Just during -> (during - min during before) `shouldSatisfy` (< 16 * 1024 * 1024)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)) [False, True]
