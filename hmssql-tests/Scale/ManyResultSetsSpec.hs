-- | 10,000 result sets in a single batch, decoded both dynamically
-- ('queryMulti'\/'queryMulti') and with the typed 'ResultSets' monad
-- ('resultSet' via 'queryResultSets'), confirming all of them come back in
-- order with the right values, and that residency doesn't grow with the
-- number of result sets.
module Scale.ManyResultSetsSpec (spec) where

import Control.Monad (replicateM)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Stats (getRTSStats, getRTSStatsEnabled, max_live_bytes)
import System.Mem (performMajorGC)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import TestDb

setCount :: Int
setCount = 10000

-- | @SELECT 1; SELECT 2; ...; SELECT 10000;@ -- one result set per
-- statement, each with a single row carrying its own 1-based index, so
-- every set is distinguishable and easy to check.
manySets :: Text
manySets = T.intercalate "; " ["SELECT " <> T.pack (show i) | i <- [1 .. setCount]]

spec :: Spec
spec = around withTestDb $
  describe "10,000 result sets in one batch" $ do
    slow $ it "queryMulti decodes all of them, in order, in bounded memory" $ \conn -> do
      enabled <- getRTSStatsEnabled
      if not enabled then expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T" else do
        performMajorGC
        before <- max_live_bytes <$> getRTSStats
        sets <- queryMulti conn (rawSql manySets)
        length sets `shouldBe` setCount
        let values = map (map sqlRowValues . resultRows) sets
        values `shouldBe` [[[SqlInt32 (fromIntegral i)]] | i <- [1 .. setCount]]
        performMajorGC
        after <- max_live_bytes <$> getRTSStats
        -- 10,000 sets of one small int row each is tiny once decoded (a few
        -- hundred KB); a generous ceiling here mainly guards against
        -- something pathological like retaining per-set overhead that scales
        -- with the *total* response size rather than the small amount of
        -- actual data.
        fromIntegral (after - before) `shouldSatisfy` (< (64 * 1024 * 1024 :: Int))

    -- A subset via the typed ResultSets monad: replicateM works for any
    -- Monad, so this drives 'resultSet' (and hence 'nextResultSet') 2,000
    -- times in sequence over the same kind of batch.
    slow $ it "queryResultSets / resultSet decodes a subset of the same shape" $ \conn -> do
      let n = 2000
          sql = T.intercalate "; " ["SELECT " <> T.pack (show i) | i <- [1 .. n]]
      rows <- queryResultSets (replicateM n resultSet) conn (rawSql sql)
      (rows :: [[Only Int64]]) `shouldBe` [[Only (fromIntegral i)] | i <- [1 .. n]]
