-- | Tests found by mutation testing of "Hmssql.Decoding".
module Mutation.DecodingSpec (spec) where

import RecipeDecoding
import Data.Binary.Put (Put)
import qualified Data.ByteString as B
import Data.Time (Day)
import Data.UUID.Types (UUID)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Decoding
import Hmssql.Tds.Context
import Hmssql.Tds.Value (rowFromValues)
import MockServer (doneToken)
import Protocol.MockTokens
import TestDb

-- | A mock response of one column of the given type holding the given bytes.
oneValue :: TypeInfo -> B.ByteString -> [Put]
oneValue ti bs = [colMetaData [("v", ti)], row [(ti, Just bs)], doneToken 0x10 1]

spec :: Spec
spec = do
  describe "SqlRow decoding (sqlRowDecoderFor)" $
    it "reports the first column that doesn't decode" $ do
      let cols = [ColumnInfo n TIGuid 1 0 Nothing | n <- ["a", "b", "c"]]
          bad = Just (B.replicate 17 0xAB)
          good = Just (B.replicate 16 0xAB)
      case compileRowDecoder (sqlRowDecoderFor cols) defaultTdsContext cols of
        Left err -> expectationFailure (show err)
        Right decode -> do
          badResult <- decodeFixture cols decode [good, bad, bad]
          fmap (const ()) badResult `shouldSatisfy` \case
            Left (DecodeError (Just "b") _) -> True
            _ -> False
          (fmap (length . sqlRowValues) <$> decodeFixture cols decode [good, Nothing, good]) `shouldReturn` Right 3

  describe "values with trailing bytes (mock server)" $ do
    -- A value longer than its type is malformed; decoding a prefix of it
    -- would hide the corruption.
    it "a 17-byte uniqueidentifier value is a DecodeError" $
      withScriptedTokens (oneValue TIGuid (B.replicate 17 0xAB)) $ \conn -> do
        r <- within (trySync (query conn "SELECT v" :: IO [Only UUID]))
        expectDecodeError r
        expectUsable conn
    it "a 4-byte date value is a DecodeError" $
      withScriptedTokens (oneValue TIDateN (B.pack [1, 0, 0, 0])) $ \conn -> do
        r <- within (trySync (query conn "SELECT v" :: IO [Only Day]))
        expectDecodeError r
        expectUsable conn
    it "a 17-byte uniqueidentifier value is a DecodeError as a SqlValue too" $
      withScriptedTokens (oneValue TIGuid (B.replicate 17 0xAB)) $ \conn -> do
        r <- within (trySync (query conn "SELECT v" :: IO [Only SqlValue]))
        expectDecodeError r
        expectUsable conn

  around withTestDb $ describe "SqlValue and undecodable collations" $ do
    -- 'sqlValueDecoder' checks a single-byte column's collation when the
    -- columns arrive, like the Text decoder, so the failure doesn't depend on
    -- the data.
    let dbcs = "SELECT CAST(NULL AS varchar(10)) COLLATE Japanese_CI_AS AS v"
    it "rejects a double-byte varchar column holding only NULL" $ \conn -> do
      r <- trySync (query conn dbcs :: IO [Only SqlValue])
      expectDecodeError r
    it "rejects a double-byte varchar column with no rows" $ \conn -> do
      r <- trySync (query conn (dbcs <> " WHERE 1 = 0") :: IO [Only SqlValue])
      expectDecodeError r
    it "rejects it in queryMulti too" $ \conn -> do
      r <- trySync (queryMulti conn dbcs)
      expectDecodeError r
