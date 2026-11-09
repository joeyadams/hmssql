{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Hedgehog properties that talk to the server, run as hspec-hedgehog's
-- 'Test.Hspec.Hedgehog.hedgehog' runs them (the case count, the shrink
-- limit and the seed from hspec's QuickCheck settings), with one bound
-- more: shrinking stops once 'shrinkAttempts' smaller cases in a row have
-- passed, and the item fails with the case as far as it had shrunk.
--
-- Hedgehog's shrink limit counts the shrinks it accepts, not the cases it
-- tries.  A case that failed for a reason outside it (a request the
-- server refused while it was out of memory, a session killed by another
-- test) has smaller cases that all pass, and hedgehog tries every one of
-- them before it reports the failure.  For a large value that is
-- unbounded in practice: a random table of "Differential.Schema" can have
-- more than 140,000, and each one tried stays in memory until the last,
-- since the generator's tree keeps every shrunk value it has made (78 KB
-- each for a large table; 11 GB after 142,000, measured 2026-10-15).
-- Against the server each of them is a round trip or more, so such a
-- property shrinks for hours while the process grows.  A real failure
-- usually finds a smaller failing case among the first few candidates;
-- 'shrinkAttempts' passing ones in a row says the failure was not the
-- case's own, or not worth finding more of.
module LiveProperty
  ( LiveProperty
  , liveHedgehog
  , shrinkAttempts
  ) where

import Control.Exception
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isSpace)
import Data.IORef
import Data.List (dropWhileEnd)
import Hedgehog (PropertyT, property)
import Hedgehog.Internal.Config (UseColor (..))
import Hedgehog.Internal.Property
  ( DiscardLimit (..), Property (..), PropertyConfig (..), ShrinkLimit (..)
  , TerminationCriteria (..), TestCount (..), TestLimit (..) )
import Hedgehog.Internal.Report
import Hedgehog.Internal.Runner (checkReport)
import qualified Hedgehog.Internal.Seed as Seed
import Hedgehog.Internal.Source (ColumnNo (..), LineNo (..), Span (..))
import Test.Hspec.Core.Spec
import Test.QuickCheck (Args (..))

-- | A property for the server, to be run by hspec: 'liveHedgehog'.
newtype LiveProperty = LiveProperty (PropertyT IO ())

-- | Run the property as a spec item ('LiveProperty'), in place of
-- hspec-hedgehog's @hedgehog@.
liveHedgehog :: PropertyT IO () -> LiveProperty
liveHedgehog = LiveProperty

-- | How many smaller cases in a row may pass before shrinking stops.
shrinkAttempts :: Int
shrinkAttempts = 1000

-- | What stops the property from inside hedgehog's search.  Of an
-- asynchronous type, so that hedgehog, which turns every other exception
-- of a case into that case's failure, lets it through.
data ShrinkingStopped = ShrinkingStopped
  deriving (Show)

instance Exception ShrinkingStopped where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

instance Example LiveProperty where
  type Arg LiveProperty = ()
  evaluateExample p = evaluateExample (\() -> p)

instance Example (a -> LiveProperty) where
  type Arg (a -> LiveProperty) = a
  evaluateExample mk params aroundAction progressCallback = do
    ref <- newIORef (Result "" (Pending Nothing Nothing))
    aroundAction $ \a -> do
      let LiveProperty body = mk a
          qc = paramsQuickCheckArgs params
          maxTests = maxSuccess qc
      -- The failure being shrunk, with its report, and the cases tried
      -- since it was found.
      shrinking <- newIORef Nothing
      tried <- newIORef (0 :: Int)
      -- Counted at the end of the case: a smaller case runs the property
      -- again from its last 'forAll' only, and a case that fails doesn't
      -- reach the end (it is the next shrink, which starts the count
      -- again).
      let bounded = do
            body
            liftIO $ readIORef shrinking >>= \case
              Nothing -> pure ()
              Just _ -> do
                n <- atomicModifyIORef' tried (\k -> (k + 1, k + 1))
                when (n >= shrinkAttempts) $ throwIO ShrinkingStopped
          prop = property bounded
          cfg = (propertyConfig prop)
            { propertyTerminationCriteria = case propertyTerminationCriteria (propertyConfig prop) of
                EarlyTermination c _ -> EarlyTermination c (TestLimit maxTests)
                NoEarlyTermination c _ -> NoEarlyTermination c (TestLimit maxTests)
                NoConfidenceTermination _ -> NoConfidenceTermination (TestLimit maxTests)
            , propertyDiscardLimit = DiscardLimit (maxDiscardRatio qc * maxTests)
            , propertyShrinkLimit = ShrinkLimit (maxShrinks qc)
            }
          testCount report = let TestCount n = reportTests report in n
          onProgress report = do
            case reportStatus report of
              Running -> pure ()
              Shrinking f -> do
                writeIORef shrinking (Just (report, f))
                writeIORef tried 0
            progressCallback (testCount report, maxTests)
      -- A seed from hspec's when it has one (--seed), so that a run can
      -- be repeated; hedgehog's report gives its own for one case.
      seed <- case replay qc of
        Nothing -> Seed.random
        Just (g, _) -> pure (Seed.from (fromIntegral (hashString (show g))))
      outcome <- try (checkReport cfg 0 seed (propertyTest prop) onProgress)
      result <- case outcome of
        Right report -> pure report
        Left ShrinkingStopped -> readIORef shrinking >>= \case
          Nothing -> throwIO (userError "LiveProperty: shrinking stopped before it started")
          Just (report, f) -> pure report
            { reportStatus = Failed f
                { failureFootnotes = failureFootnotes f ++
                    [ "Shrinking stopped after " ++ show shrinkAttempts ++ " smaller cases in a row passed"
                        ++ " (LiveProperty): this case may have failed for a reason outside it, such as the server." ]
                }
            }
      let render color = unlines . unindent . lines . dropWhileEnd isSpace
            <$> renderResultWith config color (Just "") result
          config = defaultConfig
            { configContext = Context 3
            , configPrintFailedAtLocation = False
            , configPrintReproduceMessage = False
            , configPrintPrefixIcons = DisablePrefixIcons
            }
      case reportStatus result of
        Failed f -> do
          text <- render EnableColor
          let at Span{..} = Location
                { locationFile = spanFile
                , locationLine = let LineNo l = spanStartLine in l
                , locationColumn = let ColumnNo c = spanStartColumn in c
                }
          writeIORef ref $ Result "" $ Failure (at <$> failureLocation f) (ColorizedReason text)
        GaveUp -> render DisableColor >>= writeIORef ref . Result "" . Failure Nothing . Reason
        OK -> render DisableColor >>= \text -> writeIORef ref (Result text Success)
    readIORef ref
    where
      unindent xs = let k = minimum (maxBound : map (length . takeWhile (== ' ')) xs) in map (drop k) xs
      hashString = foldl (\h c -> h * 33 + fromEnum c) (5381 :: Int)
