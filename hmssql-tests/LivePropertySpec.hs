-- | "LiveProperty", the runner of the properties that talk to the server:
-- it runs and shrinks as hspec-hedgehog does, and stops shrinking a case
-- whose smaller cases keep passing.  No server: the properties here fail
-- when told to.
module LivePropertySpec (spec) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.List (isInfixOf)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Core.Spec

import LiveProperty

-- | Run the property as hspec would, with its default settings: the
-- result, and how many cases ran.  The property counts a case with the
-- action it is given, after its 'forAll' (a smaller case runs the
-- property again from there).
runLive :: (PropertyT IO Int -> PropertyT IO ()) -> IO (ResultStatus, Int)
runLive mk = do
  runs <- newIORef 0
  let tick = liftIO (atomicModifyIORef' runs (\k -> (k + 1, k + 1)))
  Result _ status <- evaluateExample (liveHedgehog (mk tick)) defaultParams ($ ()) (\_ -> pure ())
  (,) status <$> readIORef runs

-- | The start of the note 'liveHedgehog' adds when it stops shrinking.
-- Not written out in a test: hedgehog's report quotes the source lines
-- around a failure, and would contain it.
stoppedNote :: String
stoppedNote = "Shrinking stopped after"

failureText :: ResultStatus -> Maybe String
failureText = \case
  Failure _ (ColorizedReason s) -> Just s
  Failure _ (Reason s) -> Just s
  _ -> Nothing

spec :: Spec
spec = describe "liveHedgehog" $ do
  it "passes a property that holds" $ do
    (status, runs) <- runLive $ \tick -> do
      xs <- forAll (Gen.list (Range.linear 0 50) (Gen.int (Range.constant 0 9)))
      _ <- tick
      reverse (reverse xs) === xs
    case status of
      Success -> pure ()
      other -> expectationFailure ("expected success, got " ++ show other)
    runs `shouldBe` 100

  it "shrinks a failure the case causes, as hedgehog does" $ do
    -- One number, whose smallest failing value is 500 and which hedgehog
    -- shrinks to it exactly (a list summing to 500 can stop at a local
    -- minimum such as [286, 214]).  The last case to fail is the case
    -- shrinking ended with.
    lastFailed <- newIORef Nothing
    (status, _) <- runLive $ \_ -> do
      x <- forAll (Gen.int (Range.constant 0 1000))
      when (x >= 500) $ liftIO (writeIORef lastFailed (Just x))
      assert (x < 500)
    case failureText status of
      Nothing -> expectationFailure ("expected a failure, got " ++ show status)
      Just text -> text `shouldSatisfy` (not . (stoppedNote `isInfixOf`))
    readIORef lastFailed `shouldReturn` Just (500 :: Int)

  it "stops shrinking once 1000 smaller cases in a row have passed, and reports the case" $ do
    -- One failure, at the fifth case, and never again: as a request the
    -- server refused for a while.  The case has some thousands of smaller ones.
    (status, runs) <- runLive $ \tick -> do
      xs <- forAll (Gen.list (Range.singleton 300) (Gen.int (Range.constant 0 1000)))
      n <- tick
      when (n == 5) $ do
        annotate ("failed once, with " ++ show (length xs) ++ " elements")
        failure
    case failureText status of
      Nothing -> expectationFailure ("expected a failure, got " ++ show status)
      Just text -> do
        text `shouldSatisfy` ("Shrinking stopped after 1000 smaller cases in a row passed" `isInfixOf`)
        text `shouldSatisfy` ("failed once, with 300 elements" `isInfixOf`)
    runs `shouldBe` 5 + shrinkAttempts
