-- Wide tuple recipes must preserve order, nullable framing, and recovery when
-- their internal applicative composition is split into smaller recipes.
module Api.WideRowDecoderSpec (spec) where

import Control.Monad (forM_)
import Data.Bits (setBit)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import qualified Data.Text as T
import Test.Hspec
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Tds.Context (defaultTdsContext)
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo

wideDecoders :: [(Int, RowDecoder [Maybe Int32])]
wideDecoders =
  [ (7, (\(a0, a1, a2, a3, a4, a5, a6) -> [a0, a1, a2, a3, a4, a5, a6]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  , (8, (\(a0, a1, a2, a3, a4, a5, a6, a7) -> [a0, a1, a2, a3, a4, a5, a6, a7]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  , (9, (\(a0, a1, a2, a3, a4, a5, a6, a7, a8) -> [a0, a1, a2, a3, a4, a5, a6, a7, a8]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  , (10, (\(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) -> [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  , (11, (\(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10) -> [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  , (12, (\(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) -> [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11]) <$> rowDecoder @(Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32, Maybe Int32))
  ]

spec :: Spec
spec = describe "wide tuple recipe composition" $
  forM_ wideDecoders $ \(width, decoder) -> describe (show width ++ " columns") $ do
    let columns = [ColumnInfo (T.pack (show i)) (TIIntN 4) 1 0 Nothing | i <- [0 .. width - 1]]
        values = [if i `mod` 3 == 0 then Nothing else Just (fromIntegral i) | i <- [0 .. width - 1]]
        encoded = map (fmap (LB.toStrict . Put.runPut . Put.putInt32le)) values
        compile = either (error . show) id (compileRowDecoder decoder defaultTdsContext columns)
    forM_ [False, True] $ \nbc -> forM_ [1, 7, 4096] $ \chunk ->
      it ("reads " ++ (if nbc then "NBCROW" else "ROW") ++ " in chunks of " ++ show chunk) $ do
        (result, rest) <- P.parseChunks (rowRecipe compile 1048576) (chunks chunk (wire nbc encoded))
        either (expectationFailure . show) (`shouldBe` values) result
        B.concat rest `shouldBe` B.empty
    it "drains a failed field across a composition boundary and reads the next row" $ do
      let badIndex = width - 5
          malformed = [if i == badIndex then Just (B.pack [1, 2, 3]) else value | (i, value) <- zip [0 ..] encoded]
          payload = wire False malformed <> wire True encoded
      ((first, second), rest) <- P.parseChunks ((,) <$> rowRecipe compile 1048576 <*> rowRecipe compile 1048576) (chunks 1 payload)
      case first of
        Left (DecodeFailed (DecodeError column _)) -> column `shouldBe` Just (T.pack (show badIndex))
        other -> expectationFailure ("expected a named field failure, got " ++ show other)
      either (expectationFailure . show) (`shouldBe` values) second
      B.concat rest `shouldBe` B.empty

wire :: Bool -> [RawBytes] -> B.ByteString
wire nbc values = LB.toStrict $ Put.runPut $ do
  Put.putWord8 (if nbc then 0xD2 else 0xD1)
  if nbc then Put.putByteString bitmap else pure ()
  forM_ values $ \value -> case value of
    Nothing | nbc -> pure ()
    _ -> putValueUnchecked (TIIntN 4) value
  where
    bitmap = B.pack [foldl setBit 0 [i `mod` 8 | (i, Nothing) <- zip [0 ..] values, i `div` 8 == b] | b <- [0 .. (length values - 1) `div` 8]]

chunks :: Int -> B.ByteString -> [B.ByteString]
chunks n bytes
  | B.null bytes = []
  | otherwise = let (first, rest) = B.splitAt n bytes in first : chunks n rest
