{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Cancelling a response with an Attention.
--
-- A read interrupted by an asynchronous exception sends the Attention at
-- once, from the interrupted thread, and abandons its stream handle; the
-- next request drains the cancelled response up to the acknowledgement.  A
-- response abandoned without an exception (an unconsumed 'queryS' stream) is
-- cancelled by the next request, which sends the Attention itself.  Either
-- way there is exactly one Attention per response.  If the drain is
-- interrupted, the position in the cancelled response is unknown, so the
-- connection is broken: every later request throws 'ConnectionBroken'
-- carrying that interruption, and the cancelled stream fails instead of
-- silently ending early.  Precise timing comes from the scripted mock
-- server; the live tests reach the same states by retrying with varying
-- delays until the connection's state shows them.
module Concurrency.AttentionSpec (spec) where

import UnusableCause (reasonCause, brokenCause)
import qualified RecipeState
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, replicateM, when)
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness
import Concurrency.Mock
import Hmssql
import Hmssql.Errors
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (ActiveResponse (..), Connection (..))
import OpenResponses (isMarsConnection, openResponses)
import TestDb

bigStream :: Connection -> IO (S.Stream (S.Of (Only Int64)) IO ())
bigStream conn = queryS conn (rawSql bigStreamText)

bigStreamText :: Text
bigStreamText = "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | Start a big stream, read two rows, then interrupt the request that
-- cancels and drains it (the stream was abandoned without an exception, so
-- that request sends the Attention): a watcher thread interrupts it shortly
-- after it has marked the Attention as sent.  Retries (with varying delays)
-- until the interruption lands mid-drain, which breaks the connection;
-- returns the rest of the stream and the cause the connection carries.
--
-- An interruption that lands after the drain, while the request waits for
-- its own response, leaves the connection usable (it cancels that request
-- in turn), so the next attempt can use it.
--
-- Under MARS a request leaves the stream alone; the drain is
-- 'cancelActiveStatement''s, which the request follows.
--
-- The watcher runs on a capability of its own and waits by spinning, not
-- with 'threadDelay': the drain mostly decodes rows that have already
-- arrived, so it seldom blocks, and a watcher sharing the drain's
-- capability (where 'forkIO' puts it), or waking from 'threadDelay' onto
-- it, would usually not run again until the drain was over.
interruptedDrain :: Connection -> IO (S.Stream (S.Of (Only Int64)) IO (), SomeException)
interruptedDrain conn = go (0 :: Int) []
  where
    cancelling = if isMarsConnection conn then cancelActiveStatement conn else pure ()
    go attempt hist
      -- R: the request finished first; I: interrupted after the drain.
      | attempt >= 100 = throwIO (DrainNeverWaited (reverse hist))
      | otherwise = do
          s <- bigStream conn
          xs S.:> rest <- S.toList (S.splitAt 2 s)
          xs `shouldBe` [Only 1, Only 2]
          -- The stream's response (under MARS the request an earlier attempt
          -- interrupted may still be open beside it).
          [ar] <- filter ((== Just bigStreamText) . arStatement) <$> openResponses conn
          me <- myThreadId
          (cap, _) <- threadCapability me
          caps <- getNumCapabilities
          let pause = [0, 20, 50, 100, 200] !! (attempt `mod` 5) :: Word64
              -- Spinning with 'yield', which is a safe point (a loop that
              -- never allocates would hold up every garbage collection).
              spinUntil t = getMonotonicTimeNSec >>= \now -> when (now < t) (yield >> spinUntil t)
              watch = RecipeState.attentionSent ar >>= \case
                False -> yield >> watch
                True -> do
                  t <- getMonotonicTimeNSec
                  spinUntil (t + pause * 1000)
                  throwTo me Interrupt
          r <- mask $ \restore -> do
            w <- forkOnWithUnmask ((cap + 1) `mod` caps) ($ watch)
            -- The watcher may be about to interrupt; stop it without
            -- receiving that interruption here.  Stopped on every exit:
            -- the 'try' catches only the interruption, and a watcher left
            -- behind by another exception (a failed request, the test's
            -- time limit) would spin for the rest of the run.
            let stop = uninterruptibleMask_ (killThread w)
            r <- try (restore (cancelling >> query1 conn "SELECT 1" :: IO (Only Int))) `onException` stop
            stop
            pure r
          b <- brokenCause conn
          case (r, b) of
            (Left Interrupt, Just cause)
              | isInterrupt cause -> pure (rest, cause)
            (_, Just cause) -> throwIO (userError ("broken by something other than the interruption: " ++ show cause))
            (Left Interrupt, Nothing) -> go (attempt + 1) ('I' : hist)
            (Right _, Nothing) -> go (attempt + 1) ('R' : hist)

-- | 'interruptedDrain' ran out of attempts: every interruption landed
-- after the drain (I) or after the request (R), in the order given.
newtype DrainNeverWaited = DrainNeverWaited String
  deriving Show

instance Exception DrainNeverWaited

-- | A test that starts from 'interruptedDrain'.  Over TCP the drain of a
-- big stream takes milliseconds, and an attempt that lands in it is
-- required.  Over a pipe to a local server the drain can be over before
-- any interruption lands (docs/dev/windows-research.md, "A drain too
-- short to interrupt"): the test then has no state to check and is
-- reported as pending, with the attempts.  The mock-server tests below
-- check the same guarantees on a drain that is made to wait, on every
-- transport.
fromInterruptedDrain :: IO () -> IO ()
fromInterruptedDrain test = test `catch` \(DrainNeverWaited hist) -> do
  transport <- testNetTransport
  if transport == "TCP"
    then expectationFailure ("could not interrupt a drain: " ++ hist)
    else pendingWith $
      "no interruption landed in a drain over " ++ T.unpack transport ++ " in " ++ show (length hist)
        ++ " attempts (" ++ hist ++ "); the mock-server tests cover an interrupted drain"

-- | The cause inside a 'ConnectionBroken' is 'System.Timeout.timeout''s.
brokenByTimeout :: Either ConnectionBroken a -> Bool
brokenByTimeout = \case
  Left (ConnectionBroken (reasonCause -> cause)) -> isTimeout cause
  Right _ -> False

spec :: Spec
spec = do
  describe "live server" $ do
    it "an interrupted cancel-drain breaks the connection: later requests throw ConnectionBroken carrying the interruption, and close still works" $
      fromInterruptedDrain $ within 120 $ forM_ [1 .. 3 :: Int] $ \_ -> withTestDb $ \conn -> do
        (_, cause) <- interruptedDrain conn
        isInterrupt cause `shouldBe` True
        -- Refused, twice, with the interruption as the cause; never another
        -- request's leftovers.
        _ <- expectBrokenBy isInterrupt conn
        within 10 (close conn)

    it "after an interrupted cancel-drain, every later request, interrupted or not, throws ConnectionBroken carrying that first interruption" $
      fromInterruptedDrain $ withTestDb $ \conn -> within 60 $ do
        _ <- interruptedDrain conn
        forM_ [1 .. 3 :: Int] $ \_ -> do
          r <- try (timeout 200 (query1 conn "SELECT 1" :: IO (Only Int)))
          case r of
            Left (ConnectionBroken (reasonCause -> cause)) | isInterrupt cause -> pure ()
            -- The timeout fired before the request got as far as being refused.
            Right Nothing -> pure ()
            other -> expectationFailure ("expected ConnectionBroken carrying Interrupt, got " ++ show other)
        _ <- expectBrokenBy isInterrupt conn
        pure ()

    it "a stream whose cancellation was interrupted fails with ConnectionBroken instead of ending early without an error" $
      fromInterruptedDrain $ withTestDb $ \conn -> within 60 $ do
        (rest, _) <- interruptedDrain conn
        -- Two rows were read.  A silently truncated rest would be taken for
        -- the whole result: reading it must fail.
        r <- try (S.length_ rest)
        case r of
          Left (ConnectionBroken (reasonCause -> cause)) | isInterrupt cause -> pure ()
          Left other -> expectationFailure ("the stream failed with " ++ show other)
          Right n -> expectationFailure ("the cancelled stream went on for " ++ show n ++ " rows")

  describe "mock server" $ do
    it "an interrupted cancel-drain breaks the connection: one Attention, and later requests throw ConnectionBroken (carrying the timeout) without sending anything" $ do
      -- The two sides take turns through these rather than by sleeping, so
      -- that under load the client does not close the connection before the
      -- mock has finished with it.
      laterDone <- newEmptyMVar
      ackSent <- newEmptyMVar
      let script io = do
            q <- expectBatch io
            -- Part of a result: metadata and three rows, no END_OF_MESSAGE.
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3])
            expectAttention io
            -- Hold the acknowledgement back until the client has timed out
            -- and made its later requests.
            within 10 (takeMVar laterDone)
            -- Anything those requests sent (a second Attention, say) has
            -- been written to the socket by now; collecting for a second
            -- gives the mock's reader time to pick it up.
            extra <- collectFor io 1_000_000
            mSendPacket io True (tokenBytes [doneAttn])
            putMVar ackSent ()
            rest <- serveSelects io
            pure (q, [t | (t, _) <- extra], rest)
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first <- S.toList_ (S.take 1 s)
        -- Sends the Attention for the abandoned stream, then waits for the
        -- acknowledgement, and is interrupted.
        cancelling <- timeout 200_000 (query1 conn "SELECT 2" :: IO (Only Int64))
        later <- replicateM 3 (try (timeout 200_000 (query1 conn "SELECT 2" :: IO (Only Int64))))
        putMVar laterDone ()
        -- Stay connected until the mock has stopped collecting; the
        -- acknowledgement it then sends must not revive the connection.
        within 10 (takeMVar ackSent)
        final <- try (query1 conn "SELECT 5" :: IO (Only Int64))
        pure (first, cancelling, later, final)
      case results of
        (first, cancelling, later, final) -> do
          first `shouldBe` [Only (1 :: Int64)]
          cancelling `shouldBe` Nothing
          map brokenByTimeout later `shouldBe` [True, True, True]
          brokenByTimeout final `shouldBe` True
      case outcome of
        Left e -> expectationFailure ("mock: " ++ show e)
        Right (_, extra, rest) -> do
          -- One Attention was already expected above; no second one follows
          -- (its acknowledgement would be read as the next response).
          extra `shouldBe` []
          -- Nothing is sent on the broken connection.
          rest `shouldBe` []

    it "a stream whose cancellation was interrupted fails with ConnectionBroken instead of ending early" $ do
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3])
            expectAttention io
            threadDelay 500_000
            -- The rest of the (cancelled) result, then the acknowledgement.
            mSendPacket io True (tokenBytes [rowBigint 4, doneAttn])
            serveSelects io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first S.:> more <- S.toList (S.splitAt 1 s)
        cancelled <- timeout 200_000 (query1 conn "SELECT 2" :: IO (Only Int64))
        -- Wait for the rest to arrive, then read the stream on.
        threadDelay 700_000
        rest <- try (S.toList_ more)
        final <- try (query1 conn "SELECT 6" :: IO (Only Int64))
        pure (first, cancelled, rest, final)
      case results of
        (first, cancelled, rest, final) -> do
          first `shouldBe` [Only (1 :: Int64)]
          cancelled `shouldBe` Nothing
          -- Rows 2 and 3 were in the buffer, row 4 came after the Attention:
          -- the result is incomplete, so reading it on must fail.
          brokenByTimeout rest `shouldBe` True
          brokenByTimeout final `shouldBe` True
      -- The broken connection sent nothing more.
      either (\e -> expectationFailure ("mock: " ++ show e)) (`shouldBe` []) outcome

    it "a consumer interrupted while waiting for rows sends the Attention at once, before any other request" $ do
      attnSeen <- newEmptyMVar
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1])
            -- Nothing more until the Attention.
            expectAttention io
            putMVar attnSeen ()
            mSendPacket io True (tokenBytes [rowBigint 2, doneAttn])
            serveSelects io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first S.:> more <- S.toList (S.splitAt 1 s)
        waited <- timeout 200_000 (S.toList_ more)
        -- No request is made here: the Attention must come from the
        -- interrupted read.
        seen <- timeout 5_000_000 (takeMVar attnSeen)
        -- The handle was abandoned: reading on would end at the
        -- acknowledgement, silently missing rows.
        again <- try (S.toList_ more)
        final <- within 10 (query1 conn "SELECT 3")
        pure (first, waited, seen, either (\ResultAbandoned -> Nothing) Just again, final)
      results `shouldBe` ([Only (1 :: Int64)], Nothing, Just (), Nothing, Only (3 :: Int64))
      either (\e -> expectationFailure ("mock: " ++ show e)) (`shouldBe` ["SELECT 3"]) outcome

    it "recovers when a consumer is killed while the server pauses mid-token" $ do
      let row5 = tokenBytes [rowBigint 5]
          script io = do
            _ <- expectBatch io
            -- Metadata, a row, and the first half of the next row's bytes.
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 4] <> B.take 4 row5)
            -- Sent by the killed consumer.
            expectAttention io
            mSendPacket io False (B.drop 4 row5)
            mSendPacket io True (tokenBytes [doneFinal 2, doneAttn])
            serveSelects io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        got <- newIORef []
        started <- newEmptyMVar
        done <- newEmptyMVar
        tid <- forkIO $ do
          r <- try $ do
            s <- queryS conn "SELECT paused"
            S.mapM_ (\(Only (n :: Int64)) -> modifyIORef' got (n :) >> putMVar started ()) s
          putMVar done r
        takeMVar started
        -- The consumer is now blocked mid-token, waiting for the rest.
        threadDelay 100_000
        killThread tid
        outcomeOfConsumer <- takeMVar done
        final <- within 10 (query1 conn "SELECT 7")
        (,,) <$> readIORef got <*> pure (either (Just . show @SomeException) (const Nothing) outcomeOfConsumer) <*> pure final
      results `shouldBe` ([4], Just (show ThreadKilled), Only (7 :: Int64))
      either (\e -> expectationFailure ("mock: " ++ show e)) (`shouldBe` ["SELECT 7"]) outcome

    it "treats an acknowledgement in a message of its own like one at the end of the response" $ do
      let script io = do
            _ <- expectBatch io
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1])
            expectAttention io
            -- The cancelled response ends normally, the ack follows separately.
            mSendMessage io [rowBigint 2, doneFinal 2]
            threadDelay 100_000
            mSendMessage io [doneAttn]
            serveSelects io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        _ <- S.toList_ (S.take 1 s) :: IO [Only Int64]
        a <- within 10 (query1 conn "SELECT 8")
        b <- within 10 (query1 conn "SELECT 9")
        pure (a, b)
      results `shouldBe` (Only (8 :: Int64), Only (9 :: Int64))
      either (\e -> expectationFailure ("mock: " ++ show e)) (`shouldBe` ["SELECT 8", "SELECT 9"]) outcome
