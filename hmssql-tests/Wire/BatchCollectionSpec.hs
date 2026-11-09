-- | Collecting may keep batches reversed internally; streaming must still yield
-- rows in wire order, including when a packet ends in the middle of a row.
module Wire.BatchCollectionSpec (spec) where

import Control.Monad (forM_)
import Data.Int (Int32)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Types (TypeInfo (..))
import MockServer (doneToken)
import Protocol.MockTokens

spec :: Spec
spec = describe "row order across packet batches" $
  forM_ [[4088], [7], [1, 13, 2, 31]] $ \sizes ->
    describe (show sizes) $ do
      let expected = map Only [1 .. 1000 :: Int32]
          bytes = tokenBytes $ colMetaData [("i", TIInt4)] :
            [row [(TIInt4, int32 i)] | i <- [1 .. 1000]] ++ [doneToken 0x10 1000]
          run = withScripted (packetize sizes bytes) ThenServe
      it "collects rows in order" $
        run $ \conn -> query conn "SELECT" `shouldReturn` expected
      it "streams rows in order" $
        run $ \conn -> (queryS conn "SELECT" >>= S.toList_) `shouldReturn` expected
      it "folds rows in order" $
        run $ \conn -> queryFold conn "SELECT" [] (\acc r -> pure (r : acc)) `shouldReturn` reverse expected
