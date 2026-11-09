-- | The typed 'ResultSets' monad ('resultSet', 'resultSetWith',
-- 'resultSetMWith', 'skipResultSet', 'queryResultSets') at points of misuse:
-- asking for a result set the batch doesn't have (confirming
-- 'nextResultSet' throws 'UnexpectedResult' end to end, both when the batch
-- is exhausted and when it never had a result set at all), skipping result
-- sets, decoding a result set with the wrong column count, and composing
-- 'resultSet'\/'skipResultSet' over a batch that mixes rowful and rowless
-- statements.  'Shapes.BatchesSpec' already covers rowless-statement
-- skipping for the untyped 'queryMulti'; this checks the same thing for the
-- separate 'nextResultSet' code path that backs the typed monad.
module Api.ResultSetsMisuseSpec (spec) where

import Control.Exception (try)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "asking for a result set that isn't there" $ do
    it "throws UnexpectedResult when the batch's result sets are exhausted" $ \conn -> do
      let sets = (,) <$> resultSet <*> resultSet :: ResultSets ([Only Int], [Only Int])
      r <- try (queryResultSets sets conn "SELECT 1") :: IO (Either UnexpectedResult ([Only Int], [Only Int]))
      case r of
        Left (UnexpectedResult msg) -> msg `shouldBe` "expected another result set"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "throws UnexpectedResult when the batch never produces a result set at all" $ \conn -> do
      r <- try (queryResultSets (resultSet :: ResultSets [Only Int]) conn "DECLARE @x int = 1")
             :: IO (Either UnexpectedResult [Only Int])
      case r of
        Left (UnexpectedResult msg) -> msg `shouldBe` "expected another result set"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "an action that asks for nothing at all succeeds even against a rowless batch" $ \conn ->
      queryResultSets (pure ()) conn "DECLARE @x int = 1" `shouldReturn` ()

  describe "skipResultSet" $ do
    it "advances past a result set without decoding its rows" $ \conn -> do
      let sets = skipResultSet *> resultSet :: ResultSets [Only Int]
      rs <- queryResultSets sets conn "SELECT 999; SELECT 2"
      rs `shouldBe` [Only 2]

    it "mixes resultSet and skipResultSet over a batch with rowful and rowless statements interleaved" $ \conn -> do
      let sets = do
            a <- resultSet :: ResultSets [Only Int]
            skipResultSet
            c <- resultSet :: ResultSets [Only Int]
            pure (a, c)
      (a, c) <- queryResultSets sets conn "SELECT 1; DECLARE @z int = 1; SELECT 2; SELECT 3"
      a `shouldBe` [Only 1]
      c `shouldBe` [Only 3]

  describe "rowless statements between result sets" $
    it "are skipped automatically while composing resultSet calls, like queryMulti" $ \conn -> do
      let sets = (,) <$> resultSet <*> resultSet :: ResultSets ([Only Int], [Only Int])
      (a, b) <- queryResultSets sets conn "SELECT 1; DECLARE @x int = 1; SELECT 2"
      a `shouldBe` [Only 1]
      b `shouldBe` [Only 2]

  describe "resultSetMWith" $
    it "exposes the next result set's column metadata alongside its dynamically decoded rows" $ \conn -> do
      ResultSet cols rows <- queryResultSets (resultSetMWith sqlRowDecoder) conn "SELECT 1 AS a, N'x' AS b"
      map columnName cols `shouldBe` ["a", "b"]
      map sqlRowValues rows `shouldBe` [[SqlInt32 1, SqlText "x"]]

  describe "a decode failure while reading a result set" $
    it "drains the rest of the batch and leaves the connection usable" $ \conn -> do
      let sets = resultSet :: ResultSets [(Int, Int)]
      r <- try (queryResultSets sets conn "SELECT 1; SELECT 2") :: IO (Either DecodeError [(Int, Int)])
      case r of
        Left (DecodeError _ msg) -> do
          msg `shouldContain` "has 1 column"
          msg `shouldContain` "expects 2"
        Right v -> expectationFailure ("decoded " ++ show v)
      -- the second SELECT was drained along with the rest of the batch, so
      -- it must not leak into the next request
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
