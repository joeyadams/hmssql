-- | Streaming a 10-million-row result set stays in bounded client memory.
--
-- This scales up the pattern in @RobustnessSpec@'s "memory" block (400k rows,
-- checked with 'GHC.Stats.getRTSStats' \/ 'max_live_bytes' around a
-- 'performMajorGC') to 10 million rows, to make sure the flat-memory
-- guarantee ("Memory stays flat regardless of result size", per README) holds
-- well past the smaller size already covered elsewhere.
module Scale.StreamingResidencySpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import GHC.Stats (getRTSStats, getRTSStatsEnabled, max_live_bytes)
import System.Mem (performMajorGC)
import Test.Hspec

import Hmssql
import TestDb

rowCount :: Int
rowCount = 10000000

-- | Two bigint columns per row, generated from a self cross join of
-- @sys.all_columns@ (~12,900 rows on this server, so a two-way cross join
-- comfortably covers 10 million); the exact values don't matter, only the
-- row shape and count.
bigQuery :: Text
bigQuery =
  "SELECT TOP " <> T.pack (show rowCount) <> " \
  \CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) AS a, CAST(1 AS bigint) AS b \
  \FROM sys.all_columns x CROSS JOIN sys.all_columns y"

spec :: Spec
spec = around withTestDb $
  describe "streaming 10 million rows" $
    slow $ it "stays in bounded memory" $ \conn -> do
      enabled <- getRTSStatsEnabled
      if not enabled then expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T" else do
        performMajorGC
        before <- max_live_bytes <$> getRTSStats
        s <- queryS conn (rawSql bigQuery)
        n <- S.length_ (S.map (\(a :: Int64, b :: Int64) -> a `seq` b `seq` ()) s)
        n `shouldBe` rowCount
        performMajorGC
        after <- max_live_bytes <$> getRTSStats
        -- Each row is 2 bigints (~16 bytes on the wire plus TDS framing); a
        -- streamed pass should need only a small, constant amount of buffer
        -- space regardless of row count. Materializing all 10M rows as a
        -- list of boxed (Int64, Int64) pairs would cost on the order of
        -- 10e6 * ~80 bytes =~ 800 MB, so a ceiling of 96 MiB is both well
        -- below that (proving we're not accidentally materializing) and
        -- has ample headroom over the true streaming footprint for GC
        -- fragmentation, socket/decode buffers, and RTS bookkeeping.
        fromIntegral (after - before) `shouldSatisfy` (< (96 * 1024 * 1024 :: Int))
