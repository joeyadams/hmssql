-- | The model of "Model.ConnectionSpec", with two threads using one
-- connection at once ('executeParallel'): after a sequential prefix, two
-- branches of operations run concurrently, and some interleaving of them
-- must agree with the model.  A 'Connection' is meant for one thread at a
-- time, but sharing one is documented to be safe (README, "Concurrency
-- model"): every operation here is one request (or 'reset'), which the
-- connection lock serializes, so each should take effect atomically; what
-- is tested is that concurrent requests never see each other's results,
-- errors, INFO messages or session state half-way, and that nothing breaks
-- the connection.
--
-- Streams, 'withTransaction', close/KILL and interruptions span several
-- operations or depend on timing, so they are left out; 'release' too, as
-- one thread's would make the other's handle stale.  It runs on a
-- connection without MARS and on a MARS connection ('connectMars'), where
-- the requests of the two threads take turns on its SMP sessions.
module Model.ParallelSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (modifyMaxShrinks)

import LiveProperty (liveHedgehog)
import Model.Commands
import Model.Machine
import Model.Runner
import TestDb

parallelProperty :: Shared -> PropertyT IO ()
parallelProperty sh = do
  envRef <- liftIO (newIORef Nothing)
  let initial :: forall v. Model v
      initial = initialModel (cfgFor sh)
  actions <- forAll $
    Gen.parallel (Range.linear 1 15) (Range.linear 1 6) initial [opCommand parallelWeights envRef]
  env <- evalIO (newEnv True sh)
  evalIO (writeIORef envRef (Just env))
  executeParallel initial actions
  evalIO (releaseEnv env)

spec :: Spec
spec = withModelFixture $ do
  around (withShared False) $ describe "a Connection used by two threads, against the model" machine
  around (withShared True) $ describe "a MARS Connection used by two threads, against the model" machine
  where
    machine = do
      modifyMaxShrinks (const 100) $ withCases 100 $
        it "some interleaving agrees with the model (100 runs)" $ \sh ->
          liveHedgehog (parallelProperty sh)
      slow $ modifyMaxShrinks (const 200) $ withCases 3000 $
        it "some interleaving agrees with the model (3000 runs)" $ \sh ->
          liveHedgehog (parallelProperty sh)
