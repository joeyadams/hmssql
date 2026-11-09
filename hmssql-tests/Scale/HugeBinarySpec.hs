-- | A very large @varbinary(max)@ round trip, split across several rows so
-- that streaming ('queryS') can plausibly hold bounded memory while
-- materializing ('query') holds it all at once -- a single huge value in a
-- single row (as "LargeValueSpec" already covers up to 268 MB) can't show
-- that distinction, since decoding one column's value is never itself
-- streamed; only the sequence of *rows* is.
--
-- Target size: 1 GiB total (8 rows of 128 MiB each). Checked empirically
-- with sqlcmd before committing to this size: building a 1 GiB
-- @varbinary(max)@ server-side via @REPLICATE@ took about 2.6 seconds and
-- succeeded without issue (SQL Server's max LOB size is 2 GiB, so 1 GiB has
-- headroom), and reading it back over a local TLS connection is expected to
-- take well under a minute. If this ever proves too slow or flaky in CI, cut
-- @rowsCount@ (and hence total size) in half to fall back to 512 MiB.
module Scale.HugeBinarySpec (spec) where

import Control.Exception (evaluate)
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import GHC.Stats (getRTSStats, getRTSStatsEnabled, max_live_bytes)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import TestDb

rowsCount :: Int
rowsCount = 8

chunkBytes :: Int
chunkBytes = 128 * 1024 * 1024 -- 128 MiB

totalBytes :: Int64
totalBytes = fromIntegral rowsCount * fromIntegral chunkBytes

byteFor :: Int -> Int
byteFor i = 0x41 + i -- 'A', 'B', 'C', ... one distinct byte value per row

-- | @rowsCount@ rows, each @chunkBytes@ of a single repeated byte (distinct
-- per row), built server-side the way "LargeValueSpec" does.
hugeRowsQuery :: Text
hugeRowsQuery =
  "SELECT idx, blob FROM (" <> T.intercalate " UNION ALL " [rowSql i | i <- [0 .. rowsCount - 1]] <> ") t ORDER BY idx"
  where
    rowSql i =
      "SELECT " <> tshow i <> " AS idx, \
      \CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), CHAR(" <> tshow (byteFor i) <> ")), " <> tshow chunkBytes <> ")) AS blob"

tshow :: Show a => a -> Text
tshow = T.pack . show

timed :: Double -> IO a -> IO (a, Double)
timed limit act = do
  t0 <- getMonotonicTime
  r <- timeout (round (limit * 1e6)) (act >>= evaluate)
  t1 <- getMonotonicTime
  case r of
    Nothing -> expectationFailure ("took more than " ++ show limit ++ " s") >> fail "timed out"
    Just a -> pure (a, t1 - t0)

spec :: Spec
-- At least 4096-byte packets: over TLS with 512-byte ones, reading 1 GiB can
-- take more than the 120 s allowed on a busy machine.  (Memory with small
-- packets is tested by "Scale.TlsSmallPacketMemory".)
spec = around (withTestDbWith (\ci -> ci { connectPacketSize = max 4096 (connectPacketSize ci) })) $
  describe "a 1 GiB varbinary(max) round trip, split across 8 rows" $ slow $ do
    it "streaming (queryS) processes it all in bounded memory" $ \conn -> do
      enabled <- getRTSStatsEnabled
      if not enabled then expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T" else do
        performMajorGC
        before <- max_live_bytes <$> getRTSStats
        totalRef <- newIORef (0 :: Int64)
        (_, _) <- timed 120 $ do
          s <- queryS conn (rawSql hugeRowsQuery)
          S.mapM_ (\(idx :: Int, blob :: B.ByteString) -> do
                      (B.length blob, B.all (== fromIntegral (byteFor idx)) blob) `shouldBe` (chunkBytes, True)
                      modifyIORef' totalRef (+ fromIntegral (B.length blob)))
            s
        total <- readIORef totalRef
        total `shouldBe` totalBytes
        performMajorGC
        after <- max_live_bytes <$> getRTSStats
        -- One row at a time, and each row's value in one copy: the
        -- row reader ('Hmssql.Tds.Token.RowReader') holds the value's
        -- buffer and a packet, 1.25 rows' worth at most while the last
        -- quarter of a value longer than 16 MiB is copied to its final
        -- buffer (measured: 1.03 rows at the major GCs).  Joining the
        -- packets took two rows' worth, and the bound was four.
        fromIntegral (after - before) `shouldSatisfy` (< (3 * chunkBytes `div` 2))

    it "materializing (query) also completes, holding it all in memory at once" $ \conn -> do
      -- Unlike the streaming case above, this necessarily holds all 8 rows'
      -- ByteStrings (the full 1 GiB, plus decoding overhead) live at once,
      -- since 'query' returns the whole list only once every row has been
      -- decoded. We don't assert a memory *floor* here (that would be
      -- fragile), just that it completes in reasonable time.
      (rows, _) <- timed 120 (query conn (rawSql hugeRowsQuery) :: IO [(Int, B.ByteString)])
      length rows `shouldBe` rowsCount
      sum [fromIntegral (B.length blob) | (_, blob) <- rows] `shouldBe` totalBytes
      sequence_ [B.all (== fromIntegral (byteFor idx)) blob `shouldBe` True | (idx, blob) <- rows]
