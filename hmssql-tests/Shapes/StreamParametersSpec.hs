-- | Lazy and effectful request values use the same writer as strict values.
module Shapes.StreamParametersSpec (spec) where
import Control.Exception
import Data.IORef
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Streaming.Prelude as S
import qualified Streaming as S
import Test.Hspec
import Hmssql
import Hmssql.Encoding
import Hmssql.Errors
import Hmssql.Query
import TestDb

spec :: Spec
spec = around withTestDb $ describe "streamed parameters" $ do
  it "sends several streams among small parameters, ignoring empty chunks" $ \conn -> do
    let bytes = B.replicate 100000 42
        source = sourceOf (S.each [B.empty, B.take 13 bytes, B.drop 13 bytes])
    query conn ("SELECT " <> param (7 :: Int) <> ", " <> param (binaryStream source) <> ", " <> param (LB.fromStrict bytes))
      `shouldReturn` [(7 :: Int, bytes, bytes)]

  it "can send a Query again but cannot resend its streaming Request" $ \conn -> do
    let q = "SELECT " <> param (binaryStream (sourceOf (S.each ["hello"])))
    query conn q `shouldReturn` [Only ("hello" :: B.ByteString)]
    query conn q `shouldReturn` [Only ("hello" :: B.ByteString)]
    request <- queryRequest conn q
    responseS conn request >>= S.effects
    (responseS conn request >>= S.effects) `shouldThrow` (\(_ :: EncodeError) -> True)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "keeps the source resource open through sending and closes it afterwards" $ \conn -> do
    opened <- newIORef False
    closed <- newIORef False
    let source = Source $ \use -> bracket_
          (writeIORef opened True) (writeIORef closed True)
          (use (S.yield "hello" >> S.effect (readIORef opened >>= \yes -> (yes `shouldBe` True) >> pure (pure ()))))
    query conn ("SELECT " <> param (binaryStream source)) `shouldReturn` [Only ("hello" :: B.ByteString)]
    readIORef closed `shouldReturn` True

  it "rejects a request made by its own source" $ \conn -> do
    let source = Source $ \use -> do
          query1 @(Only Int) conn "SELECT 1" `shouldThrow` (\ReentrantSource -> True)
          use (S.yield "hello")
    query conn ("SELECT " <> param (binaryStream source)) `shouldReturn` [Only ("hello" :: B.ByteString)]

  it "streams lazy text with surrogate pairs" $ \conn -> do
    let text = T.replicate 10000 "a😀漢"
    query conn ("SELECT " <> param (LT.fromStrict text)) `shouldReturn` [Only text]

  it "runs a source masked" $ \conn -> do
    let source = sourceIO $ do
          getMaskingState `shouldReturn` MaskedInterruptible
          pure (S.yield "hello")
    query conn ("SELECT " <> param (binaryStream source)) `shouldReturn` [Only ("hello" :: B.ByteString)]

  it "refuses streamed output parameters" $ \conn ->
    callProcedure conn "sp_executesql" [outParam "@stmt" (binaryStream (sourceOf (S.yield "hello")))]
      `shouldThrow` (\(_ :: EncodeError) -> True)
