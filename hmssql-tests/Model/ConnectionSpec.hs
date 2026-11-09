-- | Model-based (state-machine) tests of a 'Connection': random sequences of
-- 20-80 operations (queries, DML on #temp tables and a real table, streams,
-- transactions in SQL and through 'withTransaction', errors of several
-- kinds, SET options, USE, SESSION_CONTEXT, reset, sp_reset_connection,
-- release (then a renewed handle), interrupted WAITFORs, queries under a
-- 'System.Timeout.timeout' that may land anywhere, KILL, close ...) run
-- against one connection, and each
-- result, and the session's state as the server reports it, is compared
-- with "Model.Machine".  With @HMSSQL_TEST_SESSION_SETUP=arithabort@, the
-- connection has a session setup ('nonEmptySetup'), so a reset costs a
-- batch of its own; by default it has none, and a reset rides on the next
-- request.
--
-- The machine runs twice, whatever @HMSSQL_TEST_MARS@ says: on a
-- connection without MARS, where a request abandons the stream left open,
-- and on a MARS connection ('connectMars'), where up to four streams are
-- open at once, read, read to their ends and cancelled between the other
-- operations, and a transaction can't begin or commit beside one that is
-- unfinished ('TransactionRequestsActive').
--
-- A failure prints the shrunk sequence of operations ("Var n = OpIn ...");
-- @HMSSQL_MODEL_TRACE=1@ logs every operation run, with its outcome.
module Model.ConnectionSpec (spec) where

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

sequentialProperty :: Shared -> PropertyT IO ()
sequentialProperty sh = do
  envRef <- liftIO (newIORef Nothing)
  let initial :: forall v. Model v
      initial = initialModel (cfgFor sh)
  actions <- forAll (Gen.sequential (Range.linear 20 80) initial [opCommand defaultWeights envRef])
  env <- evalIO (newEnv False sh)
  evalIO (writeIORef envRef (Just env))
  executeSequential initial actions
  -- On failure, the next 'newEnv' (or 'withShared') releases it.
  evalIO (releaseEnv env)

spec :: Spec
spec = withModelFixture $ do
  around (withShared False) $ describe "a Connection, against a model of its session" machine
  around (withShared True) $ describe "a MARS Connection, against a model of its session" machine
  where
    machine = do
      modifyMaxShrinks (const 200) $ withCases 150 $
        it "agrees with the model over random operation sequences (150 sequences)" $ \sh ->
          liveHedgehog (sequentialProperty sh)
      slow $ modifyMaxShrinks (const 400) $ withCases 5000 $
        it "agrees with the model over random operation sequences (5000 sequences)" $ \sh ->
          liveHedgehog (sequentialProperty sh)
