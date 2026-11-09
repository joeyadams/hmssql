{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}

-- | The hedgehog 'Command' shared by "Model.ConnectionSpec" and
-- "Model.ParallelSpec": one command for every operation of "Model.Machine",
-- whose postcondition compares the "Model.Runner" result with the model.
module Model.Commands
  ( OpIn (..)
  , opCommand
  , checkResult
  ) where

import Control.Monad (forM_, unless, when)
import Data.IORef
import Data.Kind (Type)
import Hedgehog

import Model.Machine
import Model.Runner

newtype OpIn (v :: Type -> Type) = OpIn Op
  deriving stock (Show)

instance FunctorB OpIn where
  bmap _ (OpIn o) = OpIn o

instance TraversableB OpIn where
  btraverse _ (OpIn o) = pure (OpIn o)

-- | The one command: any operation, weighted by the state.
opCommand :: OpWeights -> IORef (Maybe Env) -> Command Gen (PropertyT IO) Model
opCommand w envRef = Command gen exec
  [ Require $ \m (OpIn op) -> valid m op
  , Update $ \m (OpIn op) _ -> fst (step m op)
  , Ensure $ \before after (OpIn op) r -> checkResult before after op r
  ]
  where
    gen m = Just (OpIn <$> genOp w m)
    exec (OpIn op) = evalIO $ readIORef envRef >>= \case
      Nothing -> fail "no connection"
      Just env -> runOp env op

-- | Compare what happened with what the model predicts.
--
-- After a 'Cut' the connection may be broken ('AliveOrBroken'): the runner
-- reports whether it is, and a broken one is held to 'brokenExpect'
-- instead.  Whether it is broken is checked too: only a 'Cut' may break a
-- connection the model has alive, and a broken one stays broken.
checkResult :: Model Concrete -> Model Concrete -> Op -> Result -> Test ()
checkResult before after op r
  | outcomeOk && infosOk && pendingOk && inTxOk && brokenOk = success
  | otherwise = do
      -- Annotate only the failing operation.
      annotate (summary before)
      unless brokenOk $ do
        annotate $ "connection marked broken: before " ++ show (rBrokenBefore r) ++ ", after "
          ++ show (rBroken r) ++ " (outcome " ++ show (rOutcome r) ++ ")"
        failure
      case exOutcome ex of
        OneOf [o] -> rOutcome r === o
        OneOf os -> do
          annotate ("outcome " ++ show (rOutcome r) ++ ", expected one of " ++ show os)
          assert outcomeOk
        AnyOutcome -> do
          annotate ("outcome " ++ show (rOutcome r) ++ ", expected no hang or unknown exception")
          assert outcomeOk
      forM_ (exInfos ex) $ \infos -> do
        unless infosOk $ annotate "INFO message numbers:"
        rInfos r === infos
      unless pendingOk $ annotate "reset pending (hmssql's view):"
      when checkPending $ rResetPending r === mResetPending after
      unless inTxOk $ annotate "inTransaction:"
      when checkInTx $ rInTransaction r === clientInTransaction after
  where
    brokenBranch = rBrokenBefore r && mLife before == AliveOrBroken
    ex = case brokenExpect before op of
      Just broken | brokenBranch -> broken
      _ -> snd (step before op)
    isCut = case op of
      Cut{} -> True
      _ -> False
    brokenOk
      | not (usable after) = True
      -- Broken for good (only 'close' ends it, and the model follows that).
      | rBrokenBefore r = rBroken r && mLife before == AliveOrBroken
      -- Only an interruption at an arbitrary point may break it, and then
      -- the operation reports the interruption.
      | rBroken r = isCut && rOutcome r == OInterrupted
      | otherwise = True
    outcomeOk = case exOutcome ex of
      OneOf os -> rOutcome r `elem` os
      AnyOutcome -> case rOutcome r of
        OFail FHang -> False
        OFail (FOther _) -> False
        _ -> True
    infosOk = maybe True (== rInfos r) (exInfos ex)
    checkPending = rClientChecked r && usable after && not brokenBranch && not (rBroken r)
    checkInTx = checkPending && mSynced after
    pendingOk = not checkPending || rResetPending r == mResetPending after
    inTxOk = not checkInTx || rInTransaction r == clientInTransaction after

-- | The model state before the failing operation, briefly.
summary :: Model v -> String
summary m = unlines
  [ "model before: trancount " ++ show (mTranCount m) ++ ", savepoints " ++ show (map fst (mSavepoints m))
      ++ ", frames " ++ show (length (mFrames m)) ++ ", reset pending " ++ show (mResetPending m)
      ++ ", streams " ++ show (mStreams m) ++ ", synced " ++ show (mSynced m)
      ++ (if mDrainsNext m then ", an abandoned Cut to drain" else "") ++ ", " ++ show (mLife m)
      ++ (if cfgMars (mCfg m) then ", MARS" else "")
  , "  " ++ show (mOpts m)
  , "  db " ++ show (mDb m) ++ ", ctx " ++ show (mCtx m) ++ ", " ++ show (mTables m)
  ]
