-- | Tests found by mutation testing of "Hmssql.Connection.Locking".
module Mutation.LockingSpec (spec) where

import Control.Concurrent
import Test.Hspec

import Hmssql.Connection.Locking

spec :: Spec
spec = describe "Mutex" $
  it "stays held by the outer level after a nested level exits" $ do
    m <- newMutex
    me <- myThreadId
    (owner, entered) <- withMutex m $ do
      withMutex m (pure ())
      owner <- fmap show <$> mutexOwner m
      -- Another thread must still be kept out.
      entered <- newEmptyMVar
      _ <- forkIO (withMutex m (putMVar entered ()))
      threadDelay 100_000
      (,) owner <$> tryTakeMVar entered
    (owner, entered) `shouldBe` (Just (drop (length ("ThreadId " :: String)) (show me)), Nothing)
