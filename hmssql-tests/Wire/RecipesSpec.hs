{-# LANGUAGE OverloadedStrings #-}
-- | Reader recipes consume each envelope once, regardless of packet cuts.
module Wire.RecipesSpec (spec) where

import Control.Exception (AsyncException (..), throwIO, try)
import Control.Monad (forM_, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Streaming as Streaming
import Data.IORef
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import qualified Hmssql.Tds.Utf16 as Utf16
import Hmssql.Tds.CodePage (collationCodec, decodeCodecChunks, decodeCodec)
import Hmssql.Tds.Primitives (Collation (..))
import Data.Word (Word8, Word64)
import Test.Hspec
import Hmssql.Tds.Parser (Parser, ProtocolError (..))
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Value as V

wire :: Put.Put -> B.ByteString
wire = LB.toStrict . Put.runPut

atEveryCut :: (Eq a, Show a) => Parser a -> B.ByteString -> a -> Expectation
atEveryCut recipe input expected = forM_ [0 .. B.length input] $ \i -> do
  (actual, rest) <- P.parseChunks recipe [B.take i input, B.empty, B.drop i input]
  actual `shouldBe` expected
  all B.null rest `shouldBe` True

runStream :: Streaming.Stream P.Await IO (P.Got a) -> IO (P.Got a)
runStream s = Streaming.inspect s >>= \case
  Left got -> pure got
  Right _ -> fail "the recipe suspended again"

spec :: Spec
spec = describe "sequential reader recipes" $ do
  describe "the module's examples" $ do
    let shortValue :: Parser B.ByteString
        shortValue = P.word8 >>= \n -> P.boundedBytes (fromIntegral n)
    it "gives the same answer wherever the packets end" $ do
      P.parseChunks shortValue ["\3abcdef"] `shouldReturn` ("abc", ["def"])
      P.parseChunks shortValue ["\3a", "b", "cdef"] `shouldReturn` ("abc", ["def"])
    it "suspends at the end of a payload, and continues from the next one" $
      case P.runParser shortValue "\3a" of
        Right _ -> expectationFailure "finished without its input"
        Left suspended -> Streaming.inspect suspended >>= \case
          Right (P.NeedMore continue) -> do
            P.Got value rest <- runStream (continue (P.More "bcdef"))
            (value, rest) `shouldBe` ("abc", "def")
          _ -> expectationFailure "expected a request for more input"
    it "reads a token with its own length, through isolate and count" $ do
      let names = do
            size <- P.word16le
            P.isolate (fromIntegral size) $ do
              n <- P.word8
              P.count (fromIntegral n) P.bVarChar
      atEveryCut names (B.pack [7, 0, 2, 1, 0x61, 0, 1, 0x62, 0]) ["a", "b"]
    it "reads an environment" $ do
      let plusBase :: P.Recipe Word8 Word8
          plusBase = (+) <$> P.ask <*> P.liftParser P.word8
      P.parseChunks (P.withEnv 10 plusBase) ["\5"] `shouldReturn` (15, [])
    it "runs a recipe to its end with runFrom, fetching payloads from an action" $ do
      input <- newIORef ["b", "cdef"]
      let feed = atomicModifyIORef' input $ \case
            [] -> ([], P.EndOfMessage)
            c : cs -> (cs, P.More c)
      P.Got value rest <- P.runFrom feed shortValue "\3a"
      (value, rest) `shouldBe` ("abc", "def")
  it "reads mixed primitive widths at every cut" $
    atEveryCut ((,,,) <$> P.word8 <*> P.word16le <*> P.word32le <*> P.word64le)
      (wire (Put.putWord8 3 >> Put.putWord16le 1234 >> Put.putWord32le 56789 >> Put.putWord64le 123456789012))
      (3, 1234, 56789, 123456789012)

  it "reuses a recipe's environment through applicative and monadic suspensions" $ do
    let recipe = do
          triple <- (,,) <$> P.ask <*> ((+ 1) <$> P.liftParser P.word32le) <*> P.ask
          after <- P.ask
          pure (triple, after)
    forM_ [17, 29 :: Int] $ \env ->
      atEveryCut (P.withEnv env recipe) (B.pack [1, 2, 3, 4])
        ((env, 0x04030202, env), env)

  it "reads an empty value without requesting another packet" $ do
    P.parseChunks (P.bytes 0 0) [] `shouldReturn` (B.empty, [])
    P.parseChunks (P.skip 0) [] `shouldReturn` ((), [])

  it "assembles spanning values with allocation bounds including zero" $
    forM_ [0, 1, 7, 32, 1024] $ \ahead ->
      atEveryCut (P.ownedBytes ahead 100) (B.pack [0 .. 99]) (B.pack [0 .. 99])

  it "checks truncated input instead of accepting an incomplete primitive" $ do
    result <- try (P.parseChunks P.word64le [B.pack [1,2,3]])
      :: IO (Either ProtocolError (Word64, [B.ByteString]))
    case result of
      Left _ -> pure ()
      Right _ -> expectationFailure "accepted a truncated word"

  it "reads an NBCROW bitmap cut inside its bytes" $ do
    let cols = replicate 17 (ColumnInfo "n" (TIIntN 4) 1 0 Nothing)
        input = B.pack [0xD2, 0xFF, 0xFF, 1]
    atEveryCut (readToken (Just (compileResultSet cols))) input
      (TRow (V.rowFromValues (replicate 17 Nothing)))

  it "reads and skips the same PLP envelope, retaining the next value" $
    forM_ [0, 200, 0x80000001, 0xFFFFFFFFFFFFFFFE] $ \total -> do
      let value = B.pack [0 .. 199]
          input = wire $ do
            Put.putWord64le total
            Put.putWord32le 13 >> Put.putByteString (B.take 13 value)
            Put.putWord32le 187 >> Put.putByteString (B.drop 13 value)
            Put.putWord32le 0 >> Put.putWord8 42
      atEveryCut (do cell <- V.cellHead V.PlpValue
                     result <- V.ownedValue 16 cell
                     end <- P.word8
                     pure (result, end)) input (Just value, 42)
      atEveryCut (V.cellHead V.PlpValue >>= V.skipValue >> P.word8) input 42

  it "does not repeat effects before a saved suspension" $ do
    count <- newIORef (0 :: Int)
    let recipe = P.effect (modifyIORef' count (+ 1)) >> P.word32le
    P.parseChunks recipe (map B.singleton [1,2,3,4]) `shouldReturn` (0x04030201, [])
    readIORef count `shouldReturn` 1

  it "normalizes a value cursor before feeding and after completion" $ do
    count <- newIORef (0 :: Int)
    let recipe = do
          P.effect (modifyIORef' count (+ 1))
          value <- P.word8
          P.effect (modifyIORef' count (+ 1))
          pure value
    current <- newIORef (P.parse recipe B.empty)
    P.runAwait (P.feedRunner (throwIO ThreadKilled)) current
      `shouldThrow` (== ThreadKilled)
    readIORef count `shouldReturn` 1
    P.Got value rest <- P.runAwait (P.feedRunner (pure (P.More "*"))) current
    (value, rest) `shouldBe` (42, B.empty)
    P.Got again remaining <- P.runAwait (P.feedRunner (fail "unexpected feed")) current
    (again, remaining) `shouldBe` (42, B.empty)
    readIORef count `shouldReturn` 2

  it "never runs a rejected nested consumer, even through outer cleanup" $ do
    calls <- newIORef (0 :: Int)
    rejected <- newIORef False
    let isNested (ProtocolError message) = message == "a value recipe cannot invoke a nested consumer"
        source = Streaming.effect $ do
          _ <- P.consume (pure ()) (\_ -> modifyIORef' calls (+ 1))
          pure (pure ())
        use chunks = do
          result <- try (S.effects chunks)
          writeIORef rejected (either isNested (const False) result)
    result <- try (void (P.parseChunks (P.consume source use) [])) :: IO (Either ProtocolError ())
    readIORef rejected `shouldReturn` True
    readIORef calls `shouldReturn` 0
    result `shouldSatisfy` either isNested (const False)

  it "checks that a bounded metadata envelope is consumed exactly" $ do
    result <- try (P.parseChunks (P.isolate 2 P.word8) [B.pack [1,2,3]])
      :: IO (Either ProtocolError (Word8, [B.ByteString]))
    case result of
      Left _ -> pure ()
      Right _ -> expectationFailure "ignored a metadata byte"


  it "decodes UTF-16 across every byte and surrogate boundary" $ do
    let inputs = [Utf16.encodeUtf16LE "a😀漢😀b", B.pack [0,216,1,216,0,220,97,0,0]]
    forM_ inputs $ \input -> forM_ [0 .. B.length input] $ \i -> do
      decoded <- S.toList_ (Utf16.decodeUtf16Chunks (S.each [B.take i input, B.drop i input]))
      T.concat decoded `shouldBe` Utf16.decodeUtf16LE input

  it "decodes UTF-8 split inside a character, including incomplete sequences" $ do
    codec <- either (fail . show) pure (collationCodec (Collation 0x04E00409 0))
    let input = B.pack [97, 0xf0, 0x9f, 0x98, 0x80, 0xe6, 0xbc, 0xa2, 0xe2, 0x82]
    forM_ [0 .. B.length input] $ \i -> do
      decoded <- S.toList_ (decodeCodecChunks codec (S.each [B.take i input, B.drop i input]))
      T.concat decoded `shouldBe` decodeCodec codec input

  it "releases an assembling value when a drain takes over at a packet boundary" $ do
    let recipe = do
          value <- P.bytesValue 8 4
          next <- P.word8
          pure (case value of Nothing -> True; _ -> False, next)
    first <- Streaming.inspect (P.parse recipe (B.singleton 1))
    case first of
      Right (P.NeedMore continue) -> do
        result <- Streaming.inspect (continue (P.Discard (B.pack [2,3,4,9])))
        case result of
          Left (P.Got actual rest) -> do
            actual `shouldBe` (True, 9)
            rest `shouldBe` B.empty
          _ -> expectationFailure "drain did not finish the value"
      _ -> expectationFailure "value did not suspend"
