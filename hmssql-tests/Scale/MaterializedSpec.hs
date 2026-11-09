-- | Materializing a million-row result set with 'query'\/'query' completes
-- promptly. Uses the @timed@ idiom from "LargeValueSpec" (a
-- 'System.Timeout.timeout' with a wall-clock measurement) rather than a hard
-- assertion on wall time, so the test fails loudly (rather than hanging the
-- suite) if materializing regresses to something pathological.
module Scale.MaterializedSpec (spec) where

import Control.Exception (evaluate)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import TestDb

rowCount :: Int
rowCount = 1000000

bigQuery :: Text
bigQuery =
  "SELECT TOP " <> T.pack (show rowCount) <> " \
  \CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) AS a, CAST(1 AS bigint) AS b \
  \FROM sys.all_columns x CROSS JOIN sys.all_columns y"

-- | Run an action, failing the test if it takes more than @limit@ seconds.
timed :: Double -> IO a -> IO (a, Double)
timed limit act = do
  t0 <- getMonotonicTime
  r <- timeout (round (limit * 1e6)) (act >>= evaluate)
  t1 <- getMonotonicTime
  case r of
    Nothing -> expectationFailure ("took more than " ++ show limit ++ " s") >> fail "timed out"
    Just a -> pure (a, t1 - t0)

spec :: Spec
spec = around withTestDb $
  describe "materializing 1 million rows" $
    it "completes within a generous time bound" $ \conn -> do
      (rows, _) <- timed 60 (query conn (rawSql bigQuery) :: IO [(Int64, Int64)])
      length rows `shouldBe` rowCount
      -- spot-check ordering/content rather than just the count
      rows !! 0 `shouldBe` (1, 1)
      last rows `shouldBe` (fromIntegral rowCount, 1)
