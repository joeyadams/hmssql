-- | An Attention is an SMP DATA packet, so it needs a slot in the server's
-- receive window for its session (R25 of the MARS review: can a cancel
-- then block in an exception handler?).  The server keeps its window four
-- packets ahead of what it has consumed and ACKs as it consumes, and it
-- consumes a session's request even while the connection's one running
-- statement, on another session, waits for a lock: so a request that fills
-- the window leaves room for its Attention within a round trip.  Here a
-- request of 1 to 8 packets (a fresh session's window is 4) is interrupted
-- while the server can't run it; the timeout returns on time, the
-- Attention has gone out, and the connection is usable afterwards.
module Mars.AttentionWindowSpec (spec) where

import qualified RecipeState
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, void)
import Data.IORef (readIORef)
import Data.Int (Int32)
import qualified Data.Text as T
import Streaming (Of, Stream)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (elapsed, within)
import Hmssql
import Hmssql.Connection (TdsContext (..), cancelActiveStatement, connectionContext)
import Hmssql.Connection.Internal (ActiveResponse (..))
import Hmssql.Query (ResponseReader)
import Mars.Harness
import OpenResponses (connectionBroken, openResponses)
import TestDb

spec :: Spec
spec = describe "an Attention and the server's receive window" $
  forM_ [1, 3, 4, 5, 8 :: Int] $ \packets ->
    it ("a timeout on a request of " ++ show packets ++ " packets, while another session's statement waits for a lock, returns on time and cancels it") $
      withScanTable 100 $ \table -> withMarsConn $ \conn -> withTestDb $ \holder -> withObserver $ \obs -> within 60 $ do
        ctx <- connectionContext conn
        spid <- spidOf conn
        let payload = fromIntegral (tdsPacketSize ctx) - 8 :: Int
            -- A SQL batch (ALL_HEADERS, 22 bytes, then the text in UTF-16)
            -- that ends half-way through its last packet.
            bodyBytes = (packets - 1) * payload + payload `div` 2
            prefix = "SELECT CAST(1 AS int) --"
            sql = prefix <> T.replicate ((bodyBytes - 22) `div` 2 - T.length prefix) "x"
        release <- newEmptyMVar
        held <- newEmptyMVar
        holderDone <- newEmptyMVar
        _ <- forkIO $ (try @SomeException $ withTransaction holder $ do
          _ <- execute holder (rawSql ("UPDATE " <> table <> " SET pad = 'held'"))
          putMVar held ()
          takeMVar release) >>= putMVar holderDone
        takeMVar held
        -- Let the holder go in the end, whatever happens here.
        _ <- forkIO $ threadDelay 20_000_000 >> void (tryPutMVar release ())
        -- Session 0: a scan waiting for the holder's locks, which holds up
        -- every other session's statement.
        -- (Lock-based: under RCSI, on in Azure SQL Database, a plain scan
        -- reads row versions and doesn't wait.)
        _ <- startRowReader conn (rawSql ("SELECT id FROM " <> table <> " WITH (READCOMMITTEDLOCK)")) :: IO (ResponseReader, Stream (Of (Only Int32)) IO ())
        awaitLockWait obs spid
        (r, t) <- elapsed $ timeout 300_000 (query1 conn (rawSql sql) :: IO (Only Int32))
        r `shouldBe` Nothing
        t `shouldSatisfy` (< 2)
        connectionBroken conn `shouldReturn` False
        -- The request's response is cancelled (the Attention went out) and
        -- waits to be drained.
        others <- filter (\ar -> arStatement ar == Just sql) <$> openResponses conn
        case others of
          [ar] -> RecipeState.attentionSent ar `shouldReturn` True
          _ -> expectationFailure ("expected the interrupted request's response, found " ++ show (length others))
        void (tryPutMVar release ())
        takeMVar holderDone >>= either throwIO pure
        cancelActiveStatement conn
        expectClean conn
