-- | Failed rows leave their cursor after the value that failed, then skip once.
module Wire.RowFailureSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Hmssql.Decoding
import Hmssql.Errors (DecodeError (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Collation (..))
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Token (ColumnInfo (..), compileResultSet, rsCells)
import Hmssql.Tds.TypeInfo (TypeInfo (..))
import qualified Hmssql.Tds.Value as V

columns :: [ColumnInfo]
columns = map (\name -> ColumnInfo name TIInt4 1 0 Nothing)
  ["first", "prefix", "bad", "unvisited", "tail"]

reject, never :: FieldDecoder Int32
reject = refineField (const (Left "rejected")) (fieldDecoder @Int32)
never = fieldDecoderFor "unused" (const True) (\_ _ _ -> error "later conversion ran")

-- Fixed-width payloads make every unread column visible before the sentinel.
-- NBCROW also exercises a failing NULL whose payload is omitted entirely.
wireRows :: [B.ByteString]
wireRows = [row False False, row True False, row True True]
  where
    row nbc nullThird = LB.toStrict $ Put.runPut $ do
      Put.putWord8 (if nbc then 0xD2 else 0xD1)
      if nbc then Put.putWord8 (if nullThird then 4 else 0) else pure ()
      Put.putInt32le 1
      Put.putInt32le 2
      if nullThird then pure () else Put.putInt32le 3
      Put.putInt32le 4
      Put.putInt32le 5
      Put.putWord8 0xFE

atEveryCut :: ([B.ByteString] -> Expectation) -> Expectation
atEveryCut check = forM_ wireRows $ \bytes -> forM_ [0 .. B.length bytes] $ \cut ->
  check [B.take cut bytes, B.empty, B.drop cut bytes]

assertFailure :: Either ReadFailure a -> Expectation
assertFailure = \case
  Right _ -> expectationFailure "accepted a failing field"
  Left (DecodeFailed (DecodeError col _)) -> col `shouldBe` Just "bad"
  Left ReadDiscarded -> expectationFailure "a row that was read is discarded"

spec :: Spec
spec = do
  it "skips an applicative failure's suffix and preserves the following byte at every cut" $ do
    let decoder = (,,,,) <$> singleField (fieldDecoder @Int32)
          <*> singleField (fieldDecoder @Int32) <*> singleField reject
          <*> singleField never <*> singleField never
    compiled <- either (fail . show) pure (compileRowDecoder decoder defaultTdsContext columns)
    atEveryCut $ \chunks -> do
      ((result, marker), rest) <- P.parseChunks
        ((,) <$> rowRecipe compiled 8 <*> P.word8) chunks
      assertFailure result
      marker `shouldBe` 0xFE
      all B.null rest `shouldBe` True

  it "reads past the rest of the row for a failed monadic prefix, and says so, at every cut" $ do
    let prefix = (,,) <$> singleField (fieldDecoder @Int32)
          <*> singleField reject <*> singleField never
        decoder = singleFieldM (fieldDecoder @Int32) >> toMonadicRowDecoder prefix
        info = compileResultSet columns
        recipe = do
          bitmap <- V.rowBitmap 5
          (result, next) <- runRowDecoderMonadic decoder defaultTdsContext info 8 bitmap 0
          V.skipCells bitmap (drop next (rsCells info))
          marker <- P.word8
          pure (result, next, marker)
    atEveryCut $ \chunks -> do
      ((result, next, marker), rest) <- P.parseChunks recipe chunks
      assertFailure result
      next `shouldBe` 5
      marker `shouldBe` 0xFE
      all B.null rest `shouldBe` True

  -- A built-in type's row decoder reads a value that lies in the payload inline and
  -- every other cell through its out-of-line field decoder ('cellRowDecoder'): a cut in
  -- a delimiter or a value, a NULL in the bitmap or in the delimiter, and a @max@ value
  -- each take the other path at some cut.
  it "reads a tuple of built-in types, with NULLs, at every cut" $
    forM_ [(nbc, nulls) | nbc <- [False, True], nulls <- [False, True]] $ \(nbc, nulls) -> do
      compiled <- either (fail . show) pure
        (compileRowDecoder (rowDecoder @(Int32, Maybe Int32, Maybe Text, Text, Int64)) defaultTdsContext typedColumns)
      let bytes = typedRow nbc nulls
          expected = (1, if nulls then Nothing else Just 2, if nulls then Nothing else Just "h\233llo", T.replicate 30 "max ", 5)
      forM_ [0 .. B.length bytes] $ \cut -> do
        ((result, marker), rest) <- P.parseChunks
          ((,) <$> rowRecipe compiled 8 <*> P.word8) [B.take cut bytes, B.empty, B.drop cut bytes]
        either (expectationFailure . show) (`shouldBe` expected) result
        marker `shouldBe` 0xFE
        all B.null rest `shouldBe` True

  it "fails a built-in type's out-of-range value, naming its column, and reads past the row at every cut" $ do
    let cols = [ColumnInfo "big" (TIIntN 8) 1 0 Nothing, ColumnInfo "after" TIInt4 1 0 Nothing]
        bytes = LB.toStrict $ Put.runPut $ do
          Put.putWord8 0xD1
          Put.putWord8 8 >> Put.putInt64le (2 ^ (40 :: Int))
          Put.putInt32le 7
          Put.putWord8 0xFE
    compiled <- either (fail . show) pure (compileRowDecoder (rowDecoder @(Int32, Int32)) defaultTdsContext cols)
    forM_ [0 .. B.length bytes] $ \cut -> do
      ((result, marker), rest) <- P.parseChunks
        ((,) <$> rowRecipe compiled 8 <*> P.word8) [B.take cut bytes, B.empty, B.drop cut bytes]
      case result of
        Left (DecodeFailed (DecodeError col _)) -> col `shouldBe` Just "big"
        other -> expectationFailure ("expected a failure of column big, got " ++ show (fmap (const ()) other))
      marker `shouldBe` 0xFE
      all B.null rest `shouldBe` True

typedColumns :: [ColumnInfo]
typedColumns =
  [ ColumnInfo "fixed" TIInt4 1 0 Nothing
  , ColumnInfo "bytelen" (TIIntN 4) 1 0 Nothing
  , ColumnInfo "shortlen" (TINVarChar 40 collation) 1 0 Nothing
  , ColumnInfo "plp" (TINVarChar 0xFFFF collation) 1 0 Nothing
  , ColumnInfo "bigint" (TIIntN 8) 1 0 Nothing
  ]
  where collation = Collation 0x00d00409 0x34

-- A row of 'typedColumns', as ROW or NBCROW, with its two nullable columns NULL or
-- not, and the sentinel after it.  The @max@ value comes in two chunks.
typedRow :: Bool -> Bool -> B.ByteString
typedRow nbc nulls = LB.toStrict $ Put.runPut $ do
  Put.putWord8 (if nbc then 0xD2 else 0xD1)
  if nbc then Put.putWord8 (if nulls then 0x06 else 0) else pure ()
  Put.putInt32le 1
  case (nulls, nbc) of
    (False, _) -> Put.putWord8 4 >> Put.putInt32le 2
    (True, False) -> Put.putWord8 0
    (True, True) -> pure ()
  case (nulls, nbc) of
    (False, _) -> Put.putWord16le (fromIntegral (B.length short)) >> Put.putByteString short
    (True, False) -> Put.putWord16le 0xFFFF
    (True, True) -> pure ()
  Put.putWord64le (fromIntegral (B.length long))
  let (a, b) = B.splitAt 50 long
  mapM_ (\c -> Put.putWord32le (fromIntegral (B.length c)) >> Put.putByteString c) [a, b]
  Put.putWord32le 0
  Put.putWord8 8 >> Put.putInt64le 5
  Put.putWord8 0xFE
  where
    short = TE.encodeUtf16LE "h\233llo"
    long = TE.encodeUtf16LE (T.replicate 30 "max ")
