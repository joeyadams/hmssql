-- | What a connection closed in the middle of a response keeps alive while
-- it is still referenced (by a pool entry, say), once the stream reading
-- the response is gone.  "Resources.ClosedConnection" covers a connection
-- closed between requests; here the response's unread bytes (the rest of
-- the packet or received chunk the stream stopped in) must be dropped too.
module Resources.ClosedMidResponseSpec (spec) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Resources.Helpers (keptAliveByEach)
import TestDb

-- | Closed connections kept.
count :: Int
count = 50

-- | As in "Resources.ClosedConnection": less than a reader thread's stack,
-- and less than a received chunk (up to 32 KiB) or a packet.
bound :: Word64
bound = 16 * 1024

-- | As in "Resources.ClosedConnection".
connectingAtOnce :: Int
connectingAtOnce = 8

-- | Far more than one packet, so the response is still arriving when the
-- stream stops after its first row.
manyRows :: Text
manyRows =
  "SELECT TOP 100000 CAST(REPLICATE('x', 200) AS varchar(200)) AS v \
  \FROM sys.all_columns a CROSS JOIN sys.all_columns b"

spec :: Spec
spec = describe "a connection closed while a stream is being read, still referenced" $
  forM_ [EncryptStrict, EncryptOn, EncryptNotSup] $ \enc ->
    (if enc == EncryptNotSup then skipIfEncryptionRequired else id) $
    it ("keeps little alive once the stream is gone (" ++ show enc ++ ")") $ do
      ci <- testConnectInfo enc
      sem <- newQSem connectingAtOnce
      -- Closed again after the first reading, which is what keeps them
      -- referenced during it (close is idempotent).
      per <- keptAliveByEach close $
        forConcurrently [1 .. count] $ \_ -> bracket_ (waitQSem sem) (signalQSem sem) $ do
          conn <- connect ci
          firstRow conn
          close conn
          pure conn
      -- The same once more, as in "Resources.ClosedConnection": what it
      -- loads once in a process stays alive through both readings.
      withConnection ci firstRow
      per `shouldSatisfy` (< bound)
  where
    -- Read the first row of a long result and drop the stream.
    firstRow conn = do
      s <- queryS conn (rawSql manyRows) :: IO (S.Stream (S.Of (Only Text)) IO ())
      S.next s >>= \case
        Right (Only v, _) -> v `shouldBe` mconcat (replicate 200 "x")
        Left () -> expectationFailure "no rows"
