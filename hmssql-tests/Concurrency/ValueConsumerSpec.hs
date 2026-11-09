-- | Interrupting user code must not wait for the unread value to arrive.
module Concurrency.ValueConsumerSpec (spec) where
import Control.Concurrent (throwTo)
import Control.Concurrent.Async (withAsync, waitCatch, asyncThreadId)
import Control.Concurrent.MVar
import Control.Exception (finally, AsyncException (..), fromException)
import Control.Monad (void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import Data.IORef
import qualified Streaming.Prelude as S
import Test.Hspec
import Hmssql
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Types
import Hmssql.Tds.Packet (PacketType (..))
import MockServer
import Protocol.MockTokens (packet, packetsOf, tokenBytes, colMetaData, goodResponse, within)

spec :: Spec
spec = it "returns from an interrupted consumer before the server finishes its row" $ do
  release <- newEmptyMVar
  attention <- newEmptyMVar
  escaped <- newIORef Nothing
  entered <- newEmptyMVar
  tailRan <- newIORef False
  -- A first chunk past 'streamWholeLimit', of which only "abc" arrives before the
  -- stall: a value no larger is read whole before its consumer runs.
  let chunkLength = streamWholeLimit + 1
      server mc = do
        _ <- serveLogin defaultLoginResponse mc
        _ <- recvMessage mc
        sendRaw mc $ packet False $ tokenBytes
          [ colMetaData [("prefix", TIInt4), ("blob", TIBigVarBinary 0xFFFF), ("tail", TIInt4)]
          , Put.putWord8 0xD1 >> Put.putInt32le 7 >> Put.putWord64le 0xFFFFFFFFFFFFFFFE
          , Put.putWord32le (fromIntegral chunkLength) >> Put.putByteString "abc"
          ]
        (kind, _) <- recvMessage mc
        kind `shouldBe` PTAttention
        putMVar attention ()
        takeMVar release
        mapM_ (sendRaw mc) $ packetsOf 4096 $ tokenBytes
          [ Put.putByteString (B.replicate (chunkLength - 3) 0x78)
          , Put.putWord32le 0, Put.putInt32le 99, doneToken 0x02 0 ]
        sendTokens mc [doneToken 0x20 0]
        _ <- recvMessage mc
        sendTokens mc goodResponse
      consume value = S.next (valueChunks value) >>= \case
        Left () -> fail "value ended before the stall"
        Right (_, rest) -> do
          writeIORef escaped (Just rest)
          putMVar entered ()
          S.effects rest
      decoder = (,,) <$> singleField (fieldDecoder @Int)
        <*> singleField (streamField consume)
        <*> singleField (streamField (\_ -> writeIORef tailRan True))
  withMockServer server $ \srv -> withConnection (mockConnectInfo srv) $ \conn ->
    withAsync (queryWith decoder conn "stream") $ \worker ->
      (do
        within (takeMVar entered)
        throwTo (asyncThreadId worker) ThreadKilled
        result <- within (waitCatch worker)
        result `shouldSatisfy` either (\err -> fromException err == Just ThreadKilled) (const False)
        within (takeMVar attention)
        readIORef escaped >>= \case
          Nothing -> expectationFailure "consumer did not run"
          Just stream -> S.next stream `shouldThrow` (\ResultAbandoned -> True)
        putMVar release ()
        query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)
        readIORef tailRan `shouldReturn` False)
      `finally` void (tryPutMVar release ())
