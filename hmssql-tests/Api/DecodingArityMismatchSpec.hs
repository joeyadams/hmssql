{-# LANGUAGE DeriveGeneric #-}
-- | 'RowDecoder' (not 'RowDecoderMonadic') checked against a result set whose
-- column count doesn't match, for shapes 'Types.SqlValueSpec' doesn't already
-- cover (it only tries a 2-tuple against 2 vs 3 columns).  Every case here
-- should produce a specific 'DecodeError' from 'compileRowDecoder' before any
-- row is decoded -- never a crash, a hang, or silently wrong data -- covering
-- 'Only' (arity 1), a wide (12-element) tuple, and a 'Generic'-derived
-- record, each against both too few and too many columns, plus confirming
-- 'queryS' applies the same up-front check before yielding any row.
module Api.DecodingArityMismatchSpec (spec) where

import Control.Exception (try)
import Data.Text (Text)
import GHC.Generics (Generic)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Errors
import TestDb

-- | A 3-field record decoded positionally via 'genericFromSqlRow'.
data Triple = Triple { tA :: !Int, tB :: !Text, tC :: !Bool }
  deriving (Eq, Show, Generic)

instance FromSqlRow Triple

type Wide12 = (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int)

spec :: Spec
spec = around withTestDb $
  describe "compileRowDecoder column-count mismatches" $ do
    describe "Only (expects 1 column)" $ do
      it "reports a clear error against 2 columns (too many)" $ \conn -> do
        r <- try (query1 conn "SELECT 1, 2") :: IO (Either DecodeError (Only Int))
        case r of
          Left (DecodeError col msg) -> do
            col `shouldBe` Nothing
            msg `shouldContain` "has 2 column"
            msg `shouldContain` "expects 1"
          Right v -> expectationFailure ("decoded " ++ show v)
        -- the connection is still usable: the response was drained
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

      it "reports a clear error against 3 columns (too many)" $ \conn -> do
        r <- try (query1 conn "SELECT 1, 2, 3") :: IO (Either DecodeError (Only Int))
        case r of
          Left (DecodeError _ msg) -> do
            msg `shouldContain` "has 3 column"
            msg `shouldContain` "expects 1"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    describe "a 12-element tuple (expects 12 columns)" $ do
      it "reports a clear error against 11 columns (too few)" $ \conn -> do
        r <- try (query1 conn "SELECT 1,2,3,4,5,6,7,8,9,10,11") :: IO (Either DecodeError Wide12)
        case r of
          Left (DecodeError _ msg) -> do
            msg `shouldContain` "has 11 column"
            msg `shouldContain` "expects 12"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

      it "reports a clear error against 13 columns (too many)" $ \conn -> do
        r <- try (query1 conn "SELECT 1,2,3,4,5,6,7,8,9,10,11,12,13") :: IO (Either DecodeError Wide12)
        case r of
          Left (DecodeError _ msg) -> do
            msg `shouldContain` "has 13 column"
            msg `shouldContain` "expects 12"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    describe "a Generic-derived record with 3 fields (expects 3 columns)" $ do
      it "reports a clear error against 2 columns (too few)" $ \conn -> do
        r <- try (query1 conn "SELECT 1, N'x'") :: IO (Either DecodeError Triple)
        case r of
          Left (DecodeError _ msg) -> do
            msg `shouldContain` "has 2 column"
            msg `shouldContain` "expects 3"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

      it "reports a clear error against 4 columns (too many)" $ \conn -> do
        r <- try (query1 conn "SELECT 1, N'x', CAST(1 AS bit), 99") :: IO (Either DecodeError Triple)
        case r of
          Left (DecodeError _ msg) -> do
            msg `shouldContain` "has 4 column"
            msg `shouldContain` "expects 3"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

      it "still succeeds, and binds positionally, when the count matches" $ \conn ->
        query1 conn "SELECT 1, N'x', CAST(1 AS bit)" `shouldReturn` Triple 1 "x" True

    describe "streaming (queryS) sees the same up-front check" $
      it "throws the DecodeError once the stream is pulled, not before" $ \conn -> do
        s <- queryS conn "SELECT 1, 2"
        r <- try (S.toList_ s) :: IO (Either DecodeError [Only Int])
        case r of
          Left (DecodeError _ msg) -> msg `shouldContain` "expects 1"
          Right v -> expectationFailure ("decoded " ++ show v)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
