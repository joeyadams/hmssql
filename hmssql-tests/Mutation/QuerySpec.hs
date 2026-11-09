-- | Tests found by mutation testing of "Hmssql.Query" (mock server).
module Mutation.QuerySpec (spec) where

import Data.Int (Int32)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Mutation.TokenSpec (doneFamily)
import Protocol.MockTokens

spec :: Spec
spec = do
  describe "affected row counts" $ do
    it "counts DONE, DONEPROC and DONEINPROC tokens that carry DONE_COUNT" $
      withScriptedTokens
        [ doneFamily 0xFF 0x11 2   -- DONEINPROC, MORE | COUNT
        , doneFamily 0xFE 0x11 3   -- DONEPROC, MORE | COUNT
        , doneFamily 0xFD 0x01 100 -- DONE, MORE, no COUNT: ignored
        , doneFamily 0xFD 0x10 5   -- DONE, COUNT
        ] $ \conn -> do
          within (execute conn "UPDATE ...") `shouldReturn` 10
          expectUsable conn

  describe "typed result sets" $ do
    it "an empty result set followed directly by the next one's metadata" $
      withScriptedTokens
        [ colMetaData [("a", TIIntN 4)]
        , colMetaData [("b", TIIntN 4)]
        , row [(TIIntN 4, int32 7)]
        , doneFamily 0xFD 0x10 1
        ] $ \conn -> do
          let sets = (,) <$> resultSet @(Only Int32) <*> resultSet @(Only Int32)
          within (queryResultSets sets conn "SELECT ...") `shouldReturn` ([], [Only 7])
          expectUsable conn
