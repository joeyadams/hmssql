-- | Applicative laws compare both values and the order/multiplicity of SQL
-- effects. Comparing SELECT constants alone misses duplicated statements.
module Shapes.BatchLawsSpec (spec) where

import Control.Monad (void)
import Data.Int (Int32)
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery
import TestDb

spec :: Spec
spec = around withTestDb $ describe "BatchQuery laws" $ do
  it "Functor identity preserves results and effects" $ \conn ->
    equivalent conn (fmap id (step 7)) (step 7)
  it "Functor composition preserves results and effects" $ \conn ->
    equivalent conn (fmap ((+ 3) . (* 2)) (step 7)) (fmap (+ 3) (fmap (* 2) (step 7)))
  it "Applicative identity preserves results and effects" $ \conn ->
    equivalent conn (pure id <*> step 7) (step 7)
  it "Applicative composition keeps the three statements in order" $ \conn -> do
    let u = (+) <$> step 3
        v = (*) <$> step 5
        w = step 7
    equivalent conn (pure (.) <*> u <*> v <*> w) (u <*> (v <*> w))
  it "Applicative homomorphism needs no statements" $ \conn ->
    equivalent conn (pure (+ 3) <*> pure (7 :: Int32)) (pure 10)
  it "Applicative interchange preserves the effectful function" $ \conn -> do
    let u = (+) <$> step 3
    equivalent conn (u <*> pure 7) (pure ($ 7) <*> u)
  it "fmap agrees with pure application" $ \conn ->
    equivalent conn (fmap (+ 3) (step 7)) (pure (+ 3) <*> step 7)
  it "left sequencing retains both SQL effects" $ \conn ->
    equivalent conn (step 3 <* step 7) (const <$> step 3 <*> step 7)
  it "right sequencing retains both SQL effects" $ \conn ->
    equivalent conn (step 3 *> step 7) ((\_ b -> b) <$> step 3 <*> step 7)
  it "traverse preserves order, including duplicate values" $ \conn -> do
    void $ execute conn "CREATE TABLE #law (ordinal int IDENTITY, value int NOT NULL)"
    runBatchQuery conn (traverse step [3, 1, 3, 9]) `shouldReturn` [3, 1, 3, 9]
    query conn "SELECT value FROM #law ORDER BY ordinal" `shouldReturn` map Only [3, 1, 3, 9 :: Int32]
  it "empty traverse and pure prefixes/suffixes do not consume results" $ \conn -> do
    void $ execute conn "CREATE TABLE #law (ordinal int IDENTITY, value int NOT NULL)"
    runBatchQuery conn ((,,) <$> traverse step [] <*> (pure () *> step 4 <* pure ()) <*> traverse step [])
      `shouldReturn` ([], 4, [])
    query conn "SELECT value FROM #law ORDER BY ordinal" `shouldReturn` [Only (4 :: Int32)]

step :: Int32 -> BatchQuery Int32
step n = fromOnly <$> batchQuery1 (mkQuery "INSERT INTO #law(value) VALUES (@p1); SELECT @p1" (Only n))

equivalent :: (Eq a, Show a) => Connection -> BatchQuery a -> BatchQuery a -> Expectation
equivalent conn lhs rhs = do
  void $ execute conn "CREATE TABLE #law (ordinal int IDENTITY, value int NOT NULL)"
  a <- observe lhs
  void $ execute conn "TRUNCATE TABLE #law"
  b <- observe rhs
  a `shouldBe` b
  where
    observe batch = do
      result <- runBatchQuery conn batch
      effects <- query conn "SELECT value FROM #law ORDER BY ordinal" :: IO [Only Int32]
      pure (result, effects)
