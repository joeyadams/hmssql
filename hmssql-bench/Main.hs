-- | The benchmark suite: @stack bench@, or @stack bench --benchmark-arguments
-- "-p '\$2 == \"Decode\"'"@ for one group.  Pure benchmarks always run;
-- "Bench.Mock" runs the client against an in-process mock server; the
-- benchmarks against a real server run when @HMSSQL_TEST_PASSWORD@ is set
-- (see "Bench.Live", and "Bench.Mars" for MARS against a plain connection).  See docs/dev/testing.md, "Benchmarks", for the groups,
-- baselines and how to add one.
module Main (main) where

import Test.Tasty (Timeout (..), adjustOption, localOption, mkTimeout)
import Test.Tasty.Bench

import qualified Bench.Decode
import qualified Bench.Encode
import qualified Bench.Live
import qualified Bench.Mars
import qualified Bench.Mock
import qualified Bench.Sql

main :: IO ()
main = do
  live <- Bench.Live.benchmarks
  mars <- Bench.Mars.benchmarks
  -- The groups against a server are measured by the clock, whatever
  -- --time-mode says.  Their requests mostly wait, and tasty-bench plans
  -- its iterations within the timeout by the time it measures: measuring
  -- CPU time, it planned for a third of what a run took, and "100 int
  -- params" was killed as a TIMEOUT in 3 runs of 4.
  defaultMain $ map (adjustOption defaultTimeout) $
    [Bench.Sql.benchmarks, Bench.Decode.benchmarks, Bench.Encode.benchmarks, Bench.Mock.benchmarks]
      ++ map (localOption WallTime) (live ++ mars)
  where
    -- A benchmark whose measurements are noisy keeps doubling its
    -- iterations to reach the target deviation; stop it after 30 s, with
    -- the precision reached by then.  (--timeout on the command line
    -- replaces this.)
    defaultTimeout = \case
      NoTimeout -> mkTimeout 30_000_000
      t -> t
