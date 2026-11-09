{-# LANGUAGE OverloadedStrings #-}
-- | The general prefixed reader preserves its caller's environment. The row
-- reader alone interprets a ByteString environment as an NBCROW null bitmap.
module Wire.PrefixedValueSpec (spec) where

import qualified Data.ByteString as B
import Test.Hspec
import qualified Hmssql.Tds.Parser as P

-- parseChunks starts with an empty payload. Prime a byte so each test can choose
-- whether prefixedValue itself sees a complete or fragmented delimiter/value.
readWith :: env -> P.Recipe env a -> [B.ByteString] -> IO (a, [B.ByteString])
readWith env recipe = P.parseChunks (P.peekWord8 >> P.withEnv env recipe)

spec :: Spec
spec = do
  it "accepts the original signature with an Int environment" $ do
    let recipe :: P.Recipe Int (Int, Int)
        recipe = (,)
          <$> P.prefixedValue 1 0 (Right . B.length) (pure (-1)) (fail "unexpected fallback")
          <*> P.ask
    readWith 37 recipe ["\3abc!"] `shouldReturn` ((3, 37), ["!"])

  it "passes the Int environment to NULL after consuming its delimiter" $ do
    let recipe :: P.Recipe Int Int
        recipe = P.prefixedValue 1 0 (Right . B.length) P.ask (fail "unexpected fallback")
    readWith 37 recipe ["\0!"] `shouldReturn` (37, ["!"])

  it "preserves the environment through a fragmented fallback" $ do
    let fallback :: P.Recipe Int (Int, B.ByteString, Int)
        fallback = do
          before <- P.ask
          n <- P.liftParser P.word8
          bytes <- P.liftParser (P.bytes 0 (fromIntegral n))
          after <- P.ask
          pure (before, bytes, after)
        recipe = P.prefixedValue 1 0
          (Right . (\bytes -> (0, bytes, 0))) (pure (0, B.empty, 0)) fallback
    readWith 37 recipe ["\3a", "b", "c!"] `shouldReturn` ((37, "abc", 37), ["!"])

  it "does not interpret a ByteString environment as a bitmap" $ do
    let recipe :: P.Recipe B.ByteString (B.ByteString, B.ByteString)
        recipe = (,)
          <$> P.prefixedValue 1 0 Right (pure "NULL") (fail "unexpected fallback")
          <*> P.ask
    readWith "\255" recipe ["\3abc!"] `shouldReturn` (("abc", "\255"), ["!"])

  it "passes a ByteString environment unchanged to its NULL recipe" $ do
    let recipe :: P.Recipe B.ByteString B.ByteString
        recipe = P.prefixedValue 1 0 Right P.ask (fail "unexpected fallback")
    readWith "\255" recipe ["\0!"] `shouldReturn` ("\255", ["!"])

  it "interprets a bitmap only through the separate row entry point" $ do
    let recipe = P.prefixedRowValue 8 1 0 Right (pure "NULL") (fail "unexpected fallback")
    P.parseChunks (P.withEnv "\0\1" recipe) ["!"] `shouldReturn` ("NULL", ["!"])
