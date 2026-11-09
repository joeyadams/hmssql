-- | Streamed fields share the ordinary query and row-decoder path.
module Shapes.ValueStreamingSpec (spec) where

import Control.Exception
import qualified Data.ByteString as B
import Data.IORef
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec
import Hmssql
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Query
import TestDb

spec :: Spec
spec = around withTestDb $ describe "streamed fields" $ do
  it "streams several values among ordinary columns" $ \conn -> do
    let bytes = B.replicate 100000 42
        text = T.replicate 5000 "a😀漢"
        decoder = (,,) <$> singleField (streamField (S.sum_ . S.map B.length . valueChunks))
          <*> singleField (fieldDecoder @Int)
          <*> singleField (streamTextField (\_ -> fmap T.concat . S.toList_))
    queryWith decoder conn ("SELECT " <> param bytes <> ", 42, " <> param text)
      `shouldReturn` [(B.length bytes, 42, text)]

  it "gives each value of at most streamWholeLimit as one chunk and streams a larger one, row by row" $ \conn -> do
    let decoder = (,) <$> singleField (fieldDecoder @Int)
          <*> singleField (streamField (\v -> map B.length <$> S.toList_ (valueChunks v)))
        sizes = [10, streamWholeLimit, streamWholeLimit + 1, 3]
        rows = T.intercalate ", " [T.pack ("(" ++ show k ++ ", " ++ show n ++ ")") | (k, n) <- zip [1 :: Int ..] sizes]
    results <- queryWith decoder conn $ rawSql $ "SELECT k, CAST(REPLICATE(CAST('*' AS varchar(max)), n) AS varbinary(max))"
      <> " FROM (VALUES " <> rows <> ") AS t (k, n) ORDER BY k"
    map fst results `shouldBe` [1 .. 4]
    map (sum . snd) results `shouldBe` sizes
    map (length . snd) results `shouldSatisfy` \case
      [1, 1, n, 1] -> n > 1
      _ -> False

  it "skips a value the consumer leaves unread before reading the next column" $ \conn -> do
    let decoder = (,) <$> singleField (streamField (const (pure ()))) <*> singleField (fieldDecoder @Int)
    queryWith decoder conn ("SELECT " <> param (B.replicate 100000 42) <> ", 17")
      `shouldReturn` [((), 17)]

  it "closes the value stream when its consumer returns" $ \conn -> do
    saved <- newIORef Nothing
    _ <- queryWith (singleField (streamField (\v -> writeIORef saved (Just (valueChunks v))))) conn "SELECT CAST(0x010203 AS varbinary(max))"
    readIORef saved >>= \case
      Nothing -> expectationFailure "consumer did not run"
      Just stream -> S.next stream `shouldThrow` (\ResultAbandoned -> True)

  it "rejects a second pull from a point that was already consumed" $ \conn -> do
    let use v = do
          _ <- S.next (valueChunks v)
          S.next (valueChunks v) `shouldThrow` (\ResultAbandoned -> True)
    queryWith (singleField (streamField use)) conn "SELECT CAST(0x010203 AS varbinary(max))" `shouldReturn` [()]

  it "accepts NULL without running a nullable consumer" $ \conn -> do
    ran <- newIORef False
    result <- queryWith (singleField (nullableField (streamField (\_ -> writeIORef ran True)))) conn "SELECT CAST(NULL AS varbinary(max))"
    result `shouldBe` [Nothing]
    readIORef ran `shouldReturn` False

  it "does not run later consumers after a field fails" $ \conn -> do
    ran <- newIORef False
    let decoder = (,) <$> singleField (refineField (\(_ :: Int) -> Left "reject") fieldDecoder)
          <*> singleField (streamField (\_ -> writeIORef ran True))
    (queryWith decoder conn "SELECT 1, CAST(0x010203 AS varbinary(max))" :: IO [((), ())])
      `shouldThrow` (\(_ :: DecodeError) -> True)
    readIORef ran `shouldReturn` False
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "runs consumers in the caller's masking state" $ \conn -> do
    let decoder = singleField (streamField (const getMaskingState))
    queryWith decoder conn "SELECT 1" `shouldReturn` [Unmasked]
    mask_ (queryWith decoder conn "SELECT 1") `shouldReturn` [MaskedInterruptible]

  it "propagates a consumer exception and leaves the connection reusable" $ \conn -> do
    let decoder = singleField (streamField (\_ -> throwIO (userError "consumer failed")))
    (queryWith decoder conn ("SELECT " <> param (B.replicate 100000 42)) :: IO [()])
      `shouldThrow` (\(_ :: IOException) -> True)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "treats a streaming cell's Left as the row's failure: the connection stays usable" $ \conn -> do
    -- It reads its value to the end first, which every streaming cell must do.
    let refused = fieldDecoderCompiled $ \_ _ -> Right $ StreamingCell $ \value -> do
          case value of
            StreamedNull -> pure ()
            StreamedBytes _ chunks -> S.effects chunks
          pure (Left (DecodeFailed (DecodeError (Just "refused") "refused")))
        decoder = (,) <$> singleField (refused :: FieldDecoder ()) <*> singleField (fieldDecoder @Int)
    queryWith decoder conn ("SELECT " <> param (B.replicate 100000 42) <> ", 17 UNION ALL SELECT 0x00, 18")
      `shouldThrow` (== DecodeError (Just "refused") "refused")
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "reports a consumer's Left through refineField as a DecodeError naming the column" $ \conn -> do
    let decoder = singleField (refineField id (streamField (\_ -> pure (Left "bad payload" :: Either String ()))))
    (queryWith decoder conn ("SELECT " <> param (B.replicate 100000 42) <> " AS payload") :: IO [()])
      `shouldThrow` (== DecodeError (Just "payload") "bad payload")
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "abandons a stream whose consumer threw, without running the consumer again" $ \conn -> do
    calls <- newIORef (0 :: Int)
    let decoder = singleField (streamField (\_ -> modifyIORef' calls (+ 1) >> throwIO (userError "consumer failed")))
    rows <- querySWith decoder conn ("SELECT " <> param (B.replicate 100000 42) <> " UNION ALL SELECT 0x00")
    S.effects rows `shouldThrow` (\(e :: IOException) -> show e == "user error (consumer failed)")
    S.effects rows `shouldThrow` (\ResultAbandoned -> True)
    readIORef calls `shouldReturn` 1
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "treats a failure thrown by a streaming cell's recipe as breaking the connection" $ \conn -> do
    let malformed = fieldDecoderCompiled $ \_ _ -> Right $ StreamingCell $ \_ -> fail "malformed"
    (queryWith (singleField (malformed :: FieldDecoder ())) conn "SELECT 1" :: IO [()])
      `shouldThrow` (\(_ :: ProtocolError) -> True)
    (query1 conn "SELECT 42" :: IO (Only Int)) `shouldThrow` (\(_ :: ConnectionBroken) -> True)

  it "preserves an asynchronous consumer exception and drains before reuse" $ \conn -> do
    let decoder = singleField (streamField (\_ -> throwIO ThreadKilled))
    (queryWith decoder conn ("SELECT " <> param (B.replicate 100000 42)) :: IO [()])
      `shouldThrow` (== ThreadKilled)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)
