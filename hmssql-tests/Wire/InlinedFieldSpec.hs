-- | 'inlinedField' and 'inlinedNullableField' decode a row as 'singleField'
-- does, for every delimiter and at every cut of the row; and the decoders from a
-- value's parts give the parts the built-in date and time decoders are made of.
module Wire.InlinedFieldSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int16, Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
import Test.Hspec

import Hmssql.Decoding
import Hmssql.Errors (DecodeError (..))
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo (TypeInfo (..))

-- A column of the row, with its value's bytes on the wire (behind the
-- delimiter its type has), or 'Nothing' for NULL.
data Col = Col Text TypeInfo (Maybe B.ByteString)

colInfo :: Col -> ColumnInfo
colInfo (Col name ti _) = ColumnInfo name ti 1 0 Nothing

-- The value with its delimiter, as a ROW token carries it.  An NBCROW leaves a
-- NULL out, which 'rowBytes' does.
delimited :: TypeInfo -> Maybe B.ByteString -> Put.Put
delimited ti value = case ti of
  TINVarChar 0xFFFF _ -> plp
  TIBigVarBinary 0xFFFF -> plp
  TINVarChar _ _ -> maybe (Put.putWord16le 0xFFFF) (\v -> Put.putWord16le (fromIntegral (B.length v)) >> Put.putByteString v) value
  _ -> maybe (Put.putWord8 0) (\v -> Put.putWord8 (fromIntegral (B.length v)) >> Put.putByteString v) value
  where
    -- the total, then chunks of at most 7 bytes, then the terminator
    plp = case value of
      Nothing -> Put.putWord64le 0xFFFFFFFFFFFFFFFF
      Just v -> do
        Put.putWord64le (fromIntegral (B.length v))
        let chunks b | B.null b = pure ()
                     | otherwise = let (h, t) = B.splitAt 7 b in Put.putWord32le (fromIntegral (B.length h)) >> Put.putByteString h >> chunks t
        chunks v
        Put.putWord32le 0

-- A ROW token, or an NBCROW token whose bitmap marks the NULLs, then a sentinel.
rowBytes :: Bool -> [Col] -> B.ByteString
rowBytes nbc cols = LB.toStrict $ Put.runPut $ do
  Put.putWord8 (if nbc then 0xD2 else 0xD1)
  if nbc then mapM_ Put.putWord8 bitmap else pure ()
  forM_ cols $ \(Col _ ti v) -> case v of
    Nothing | nbc -> pure ()
    _ -> delimited ti v
  Put.putWord8 0xFE
  where
    nulls = [i | (i, Col _ _ Nothing) <- zip [0 :: Int ..] cols]
    bitmap = [ fromIntegral (sum [2 ^ (i - 8 * b) | i <- nulls, i `div` 8 == b] :: Int)
             | b <- [0 .. (length cols + 7) `div` 8 - 1] ]

put :: Either String Put.Put -> B.ByteString
put = either error (LB.toStrict . Put.runPut)

utf16 :: Text -> B.ByteString
utf16 = TE.encodeUtf16LE

local :: LocalTime
local = LocalTime (fromGregorian 2026 11 4) (TimeOfDay 13 45 12.3456789)

offsetValue :: DateTimeOffset
offsetValue = DateTimeOffset (UTCTime (fromGregorian 2026 2 20) 50700.25) (-300)

-- Every type the shapes reach: a fixed width behind a one-byte length, a
-- two-byte length, and PLP; and each date and time type.
columns :: [Maybe B.ByteString -> Col]
columns =
  [ Col "int" (TIIntN 4)
  , Col "name" (TINVarChar 100 (Collation 0 0))
  , Col "doc" (TINVarChar 0xFFFF (Collation 0 0))
  , Col "dt2" (TIDateTime2N 7)
  , Col "dto" (TIDateTimeOffsetN 3)
  , Col "time" (TITimeN 4)
  , Col "date" TIDateN
  , Col "datetime" (TIDateTimeN 8)
  , Col "smalldt" (TIDateTimeN 4)
  ]

values :: [B.ByteString]
values =
  [ put (Right (Put.putInt32le (-7)))
  , utf16 "caf\233 \128512"
  , utf16 (T.replicate 5 "long value ")
  , put (putDateTime2 7 local)
  , put (putDateTimeOffset 3 offsetValue)
  , put (putTime 4 (localTimeOfDay local))
  , put (putDate (localDay local))
  , put (putDateTime8 local)
  , put (putDateTime4 local)
  ]

-- The rows: every value present, and each column NULL in turn, in both tokens.
rows :: [(Bool, [Col])]
rows = [(False, present)] ++
  [ (nbc, [if i == j then mk Nothing else c | (j, mk, c) <- zip3 [0 ..] columns present])
  | i <- [0 .. length columns - 1 :: Int], nbc <- [False, True] ]
  where present = zipWith ($) columns (map Just values)

-- Each column's built-in decoder, and a decoder of the same values from its parts,
-- shown so that one row decoder holds every column.
builtIn, fromParts :: [FieldDecoder String]
builtIn =
  [ show <$> fieldDecoder @Int32
  , show <$> fieldDecoder @Text
  , show <$> fieldDecoder @Text
  , show <$> fieldDecoder @LocalTime
  , show <$> fieldDecoder @DateTimeOffset
  , show <$> fieldDecoder @TimeOfDay
  , show <$> fieldDecoder @LocalTime
  , show <$> fieldDecoder @LocalTime
  , show <$> fieldDecoder @LocalTime
  ]
fromParts =
  [ fieldDecoderFor "Int32 bytes" (const True) (\_ _ b -> Right (show (fromIntegral (B.foldr (\w a -> a * 256 + fromIntegral w) (0 :: Int64) b) :: Int32)))
  , fieldDecoderFor "UTF-16 bytes" (const True) (\_ _ b -> Right (show (TE.decodeUtf16LE b)))
  , fieldDecoderFor "UTF-16 bytes" (const True) (\_ _ b -> Right (show (TE.decodeUtf16LE b)))
  , dayTimeFieldDecoder "day and time" (\d ps -> show (localTimeOf d ps))
  , dateTimeOffsetFieldDecoder "offset" (\d ps m -> show (DateTimeOffset (utcTimeOf d ps) m))
  , timeFieldDecoder "time" (show . picosecondsToTimeOfDay)
  , dayTimeFieldDecoder "day and time" (\d ps -> show (localTimeOf d ps))
  , dayTimeFieldDecoder "day and time" (\d ps -> show (localTimeOf d ps))
  , dayTimeFieldDecoder "day and time" (\d ps -> show (localTimeOf d ps))
  ]

-- The row decoded at every cut, with a small and a large allowance ahead, by
-- each of the row decoders; the results, and the sentinel after the row.
decodedAtEveryCut :: [Col] -> Bool -> RowDecoder [Maybe String] -> IO [Either String [Maybe String]]
decodedAtEveryCut cols nbc decoder = do
  compiled <- either (fail . show) pure (compileRowDecoder decoder defaultTdsContext (map colInfo cols))
  let bytes = rowBytes nbc cols
  fmap concat $ mapM (\ahead -> mapM (\cut -> do
    ((result, marker), rest) <- P.parseChunks ((,) <$> rowRecipe compiled ahead <*> P.word8)
      [B.take cut bytes, B.empty, B.drop cut bytes]
    marker `shouldBe` 0xFE
    all B.null rest `shouldBe` True
    pure (either (Left . failure) Right result)) [0 .. B.length bytes]) [8, 1_000_000]
  where
    failure = \case
      DecodeFailed (DecodeError col msg) -> show col ++ ": " ++ msg
      ReadDiscarded -> "discarded"

spec :: Spec
spec = do
  it "decodes every delimiter, with and without NULLs, as singleField does, at every cut" $
    forM_ rows $ \(nbc, cols) -> do
      let reference = traverse (singleField . nullableField) builtIn
      expected <- decodedAtEveryCut cols nbc reference
      take 1 expected `shouldSatisfy` all (either (const False) (const True))
      let decoders =
            [ traverse inlinedNullableField builtIn
            , traverse (inlinedField . nullableField) builtIn
            , traverse inlinedNullableField fromParts
            , traverse (singleField . nullableField) fromParts
            ]
      forM_ decoders $ \d -> decodedAtEveryCut cols nbc d `shouldReturn` expected

  it "fails a NULL in a column decoded without nullableField, naming the column, and reads past the row" $
    forM_ [(nbc, cols, nullName) | (nbc, cols) <- rows, Col nullName _ Nothing <- take 1 [c | c@(Col _ _ Nothing) <- cols]] $ \(nbc, cols, nullName) -> do
      let check d = do
            results <- decodedAtEveryCut cols nbc (traverse (fmap Just) d)
            forM_ results $ \r -> case r of
              Left msg -> msg `shouldStartWith` show (Just nullName)
              Right _ -> expectationFailure "accepted a NULL"
      check (map singleField builtIn)
      check (map inlinedField builtIn)
      check (map inlinedField fromParts)

  it "rejects a column of another type before any row, as singleField does" $ do
    let cols = [colInfo (Col "n" (TIIntN 4) Nothing)]
        rejected d = case compileRowDecoder d defaultTdsContext cols of
          Left (DecodeError col _) -> col `shouldBe` Just "n"
          Right _ -> expectationFailure "accepted an int column"
    rejected (inlinedField (dayTimeFieldDecoder "day" (\_ _ -> ())))
    rejected (inlinedNullableField (dateTimeOffsetFieldDecoder "offset" (\_ _ _ -> ())))
    rejected (singleField (timeFieldDecoder "time" (const ())))

  it "gives a date's day with no picoseconds, and a datetimeoffset's UTC parts with its offset" $ do
    let decode d ti bytes = case compileField d defaultTdsContext (ColumnInfo "c" ti 1 0 Nothing) of
          Left e -> Left e
          Right cell -> decodeCell cell (Just bytes)
    decode (dayTimeFieldDecoder "day" (,)) TIDateN (put (putDate (fromGregorian 2026 11 4)))
      `shouldBe` Right (fromGregorian 2026 11 4, 0)
    decode (dateTimeOffsetFieldDecoder "offset" (,,)) (TIDateTimeOffsetN 7) (put (putDateTimeOffset 7 offsetValue))
      `shouldBe` Right (fromGregorian 2026 2 20, 50_700_250_000_000_000, -300 :: Int16)
    decode (timeFieldDecoder "time" id) (TITimeN 7) (put (putTime 7 (TimeOfDay 1 2 3.5)))
      `shouldBe` Right 3_723_500_000_000_000
    decode (dayTimeFieldDecoder "day" (,)) (TIDateTime2N 7) (B.replicate 8 0xFF)
      `shouldSatisfy` either (const True) (const False)
