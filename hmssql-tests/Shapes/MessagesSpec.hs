-- | PRINT/RAISERROR INFO messages: ordering relative to rows and result
-- sets, volume, and messages with no rows at all.
module Shapes.MessagesSpec (spec) where

import Control.Monad (void)
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Query (batchRequest, responseS)
import Hmssql.Tds.Token (Token (..))
import TestDb

data Ev = EMsg !Text | ESet | ERow
  deriving (Eq, Show)

tag :: Token -> Maybe Ev
tag = \case
  TInfo m -> Just (EMsg (msgText m))
  TColMetaData _ -> Just ESet
  TRow _ -> Just ERow
  _ -> Nothing

eventsOf :: Connection -> Text -> IO [Ev]
eventsOf conn sql = do
  toks <- responseS conn (batchRequest sql) >>= S.toList_
  pure (mapMaybe tag toks)

spec :: Spec
spec = around withTestDb $ do
  describe "ordering" $ do
    it "interleaves PRINT with rows and result sets in execution order" $ \conn -> do
      events <- eventsOf conn "PRINT 'a'; SELECT 1 AS x; PRINT 'b'; SELECT 2 AS x UNION ALL SELECT 3; PRINT 'c'"
      events `shouldBe` [EMsg "a", ESet, ERow, EMsg "b", ESet, ERow, ERow, EMsg "c"]

    it "interleaves RAISERROR (severity <=10) the same way as PRINT" $ \conn -> do
      events <- eventsOf conn "SELECT 1 AS x; RAISERROR('note', 5, 1); SELECT 2 AS x"
      events `shouldBe` [ESet, ERow, EMsg "note", ESet, ERow]

    it "delivers messages through connectOnInfoMessage in the same order" $ \_ -> do
      log_ <- newIORef []
      ci <- defaultTestConnectInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' log_ (msgText m :) } $ \conn ->
        void (execute conn "PRINT 'x'; SELECT 1; PRINT 'y'; SELECT 2; PRINT 'z'")
      -- login itself produces a couple of INFO messages (database, language) first
      (take 3 <$> readIORef log_) `shouldReturn` ["z", "y", "x"]

  describe "volume" $
    it "delivers many messages (10,000 PRINTs)" $ \conn -> do
      let n = 10000 :: Int
          sql = T.intercalate "; " ["PRINT 'm" <> T.pack (show i) <> "'" | i <- [1 .. n]]
      events <- eventsOf conn sql
      length events `shouldBe` n
      [EMsg first] <- pure (take 1 events)
      first `shouldBe` "m1"
      [EMsg lastMsg] <- pure (drop (n - 1) events)
      lastMsg `shouldBe` T.pack ("m" ++ show n)

  describe "no rows" $
    it "delivers a message from a batch with no result sets" $ \conn -> do
      events <- eventsOf conn "PRINT 'only'"
      events `shouldBe` [EMsg "only"]
