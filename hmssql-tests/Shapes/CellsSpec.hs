-- | The nested cell stream keeps the row's continuation until its cells end.
module Shapes.CellsSpec (spec) where

import Control.Monad (void)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Streaming as Streaming
import qualified Streaming.Prelude as S
import Test.Hspec
import Hmssql
import Hmssql.Connection.Internal (connectionContext)
import Hmssql.Tds.Context (tdsPacketSize)
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Query
import TestDb

spec :: Spec
spec = around withTestDb $ describe "generic cell streams" $ do
  it "decodes a streamed value, an ordinary value, and NULL in column order" $ \conn -> do
    let payload = B.replicate 100000 42
    withQueryCells conn ("SELECT " <> param payload <> ", 42, CAST(NULL AS int)") $ \cols rows -> do
      length cols `shouldBe` 3
      Right row <- Streaming.inspect rows
      Right bytes <- Streaming.inspect row
      (count, afterBytes) <- cellDecoded (streamField (S.sum_ . S.map B.length . valueChunks)) bytes
      count `shouldBe` Right (B.length payload)
      Right number <- Streaming.inspect afterBytes
      (n, afterNumber) <- cellDecoded (fieldDecoder @Int) number
      n `shouldBe` Right 42
      Right nullCell <- Streaming.inspect afterNumber
      (v, afterNull) <- cellDecoded (fieldDecoder @(Maybe Int)) nullCell
      v `shouldBe` Right Nothing
      Left nextRows <- Streaming.inspect afterNull
      Streaming.inspect nextRows >>= \case
        Left () -> pure ()
        Right _ -> expectationFailure "unexpected extra row"

  it "decodes a FoldingCell's value whole up to the limit and folds a longer one, then goes on" $ \conn -> do
    let folding = fieldDecoderCompiled $ \_ _ -> Right $ FoldingCell (Left "NULL")
          (\b -> Right (False, B.length b)) (\b -> Right (False, B.length b))
          (\chunks -> Right . (,) True <$> S.sum_ (S.map B.length chunks))
    withQueryCells conn ("SELECT " <> param (B.replicate 100 1) <> ", " <> param (B.replicate (streamWholeLimit + 1) 2) <> ", 5") $ \_ rows -> do
      Right row <- Streaming.inspect rows
      Right short <- Streaming.inspect row
      (first, afterShort) <- cellDecoded folding short
      first `shouldBe` Right (False, 100)
      Right long <- Streaming.inspect afterShort
      (second, afterLong) <- cellDecoded folding long
      second `shouldBe` Right (True, streamWholeLimit + 1)
      Right number <- Streaming.inspect afterLong
      (n, _) <- cellDecoded (fieldDecoder @Int) number
      n `shouldBe` Right 5

  it "skips unread values when a scope ends between chunk pulls" $ \conn -> do
    withQueryCells conn ("SELECT " <> param (B.replicate 100000 42) <> ", 99") $ \_ rows -> do
      Right row <- Streaming.inspect rows
      Right Cell{cellValue = CellBytes _ chunks} <- Streaming.inspect row
      Right (_, more) <- S.next chunks
      void (S.next more)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  it "rejects a replayed row pull" $ \conn ->
    withQueryCells conn "SELECT 1" $ \_ rows -> do
      Right _ <- Streaming.inspect rows
      Streaming.inspect rows `shouldThrow` (\ResultAbandoned -> True)

  it "returns a conversion error with the following cell still readable" $ \conn ->
    withQueryCells conn "SELECT CAST('x' AS varchar(10)), 42" $ \_ rows -> do
      Right row <- Streaming.inspect rows
      Right first <- Streaming.inspect row
      (bad, after) <- cellDecoded (fieldDecoder @Int) first
      bad `shouldSatisfy` either (const True) (const False)
      Right second <- Streaming.inspect after
      (number, _) <- cellDecoded (fieldDecoder @Int) second
      number `shouldBe` Right 42

  it "decodes text without losing the continuation after the value" $ \conn -> do
    let text = T.replicate 5000 "a😀漢"
    withQueryCells conn ("SELECT " <> param text <> ", 7") $ \_ rows -> do
      Right row <- Streaming.inspect rows
      Right first <- Streaming.inspect row
      decoded S.:> after <- S.toList (cellText first)
      T.concat decoded `shouldBe` text
      Right second <- Streaming.inspect after
      (number, _) <- cellDecoded (fieldDecoder @Int) second
      number `shouldBe` Right 7

  it "returns metadata and an empty stream for an empty result set" $ \conn ->
    withQueryCells conn "SELECT TOP 0 1 AS value" $ \cols rows -> do
      length cols `shouldBe` 1
      Streaming.inspect rows >>= \case
        Left () -> pure ()
        Right _ -> expectationFailure "empty set produced a row"

  it "passes the connection context and allocation bound to a cell decoder" $ \_ ->
    withTestDbWith (\ci -> ci { connectPacketSize = 512, connectValueAllocAhead = 17 }) $ \conn -> do
      context <- connectionContext conn
      withQueryCells conn "SELECT CAST(0x010203 AS varbinary(max))" $ \_ rows -> do
        Right row <- Streaming.inspect rows
        Right cell <- Streaming.inspect row
        cellAllocAhead cell `shouldBe` 17
        tdsPacketSize (cellContext cell) `shouldBe` tdsPacketSize context
        let decoder = fieldDecoderFor "context" (const True) (\ctx _ bytes -> Right (tdsPacketSize ctx, B.length bytes))
        (result, _) <- cellDecoded decoder cell
        result `shouldBe` Right (tdsPacketSize context, 3)
