-- | Tests found by mutation testing of "Hmssql.Tds.Token" (mock server).
module Mutation.TokenSpec (spec, doneFamily) where

import Wire.RecipeGet (getToken)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Word (Word16, Word64, Word8)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Tds.Context
import Hmssql.Tds.Token
import MockServer (errorToken)
import Protocol.MockTokens

-- | Parse a whole byte string as tokens.
parseTokens :: B.ByteString -> Either String [Token]
parseTokens bs
  | B.null bs = Right []
  | otherwise = case Get.runGetOrFail (getToken defaultTdsContext Nothing) (LB.fromStrict bs) of
      Left (_, _, err) -> Left err
      Right (rest, _, tok) -> (tok :) <$> parseTokens (LB.toStrict rest)

doneBytes :: B.ByteString
doneBytes = tokenBytes [doneFamily 0xFD 0 0]

-- | An ENVCHANGE token of the given type and value bytes.
envChange :: Word8 -> [Word8] -> B.ByteString
envChange ty values = B.pack ([0xE3, fromIntegral len, fromIntegral (len `div` 256), ty] ++ values)
  where len = 1 + length values

-- | Replace the USHORT length after the token type byte.
withLength :: Int -> B.ByteString -> B.ByteString
withLength n tok = B.take 1 tok <> B.pack [fromIntegral n, fromIntegral (n `div` 256)] <> B.drop 3 tok

msg :: ServerMessage
msg = ServerMessage 50000 1 16 "boom" "srv" "" 1

-- | A DONE-family token: 0xFD DONE, 0xFE DONEPROC, 0xFF DONEINPROC.
doneFamily :: Word8 -> Word16 -> Word64 -> Put
doneFamily ty status rows = do
  Put.putWord8 ty
  Put.putWord16le status
  Put.putWord16le 0
  Put.putWord64le rows

spec :: Spec
spec = do
  describe "length-prefixed tokens (pure)" $ do
    let err = tokenBytes [errorToken msg]
        len = B.length err - 3
    it "an ERROR token parses when its length covers exactly its fields" $
      parseTokens (err <> doneBytes) `shouldBe` Right [TError msg, TDone (Done 0 0 0)]
    it "an ERROR token whose length is shorter than its fields is rejected" $
      -- The length leaves out the LineNumber; reading past it would take
      -- bytes that belong to the next token.
      parseTokens (withLength (len - 4) err <> doneBytes) `shouldSatisfy` isLeft
    it "an ERROR token whose length covers the next token is rejected" $
      parseTokens (withLength (len + B.length doneBytes) err <> doneBytes) `shouldSatisfy` isLeft
    it "an ORDER token of odd length is rejected" $
      -- Length 3: one column number and the first byte of the DONE that
      -- follows, which must not be taken as the start of the next token.
      parseTokens (B.pack [0xA9, 3, 0, 1, 0] <> doneBytes) `shouldSatisfy` isLeft
    it "a routing ENVCHANGE with a non-empty old value is rejected" $
      parseTokens
        (envChange 20 ([0x0B, 0x00, 0x00, 0x99, 0x05, 0x03, 0x00, 0x64, 0x00, 0x62, 0x00, 0x31, 0x00] ++ [1, 0]) <> doneBytes)
        `shouldSatisfy` isLeft
    it "a begin-transaction ENVCHANGE carrying both values takes the new descriptor" $
      parseTokens (envChange 8 ([8, 1, 0, 0, 0, 0, 0, 0, 0] ++ [8, 2, 0, 0, 0, 0, 0, 0, 0]) <> doneBytes)
        `shouldBe` Right [TEnvChange (ECBeginTransaction (TransactionDescriptor 1)), TDone (Done 0 0 0)]

  describe "the end of a response" $ do
    -- MS-TDS 2.2.7.6-2.2.7.8: any DONE-family token without DONE_MORE ends
    -- the response.
    it "a DONEINPROC without DONE_MORE ends the response" $
      withScriptedTokens
        [ colMetaData [("x", TIIntN 4)], row [(TIIntN 4, int32 7)], doneFamily 0xFF 0x10 1 ] $ \conn -> do
          within (query conn "SELECT 7") `shouldReturn` [Only (7 :: Int32)]
          expectUsable conn
    it "a DONEPROC without DONE_MORE ends the response" $
      withScriptedTokens
        [ colMetaData [("x", TIIntN 4)], row [(TIIntN 4, int32 7)], doneFamily 0xFE 0x10 1 ] $ \conn -> do
          within (query conn "SELECT 7") `shouldReturn` [Only (7 :: Int32)]
          expectUsable conn
