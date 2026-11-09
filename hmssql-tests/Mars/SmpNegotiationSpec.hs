-- | Negotiating MARS and starting SMP, against the mock server
-- ("Mars.MockSmp"): PRELOGIN asks for MARS only when 'connectMars' does,
-- and a server that doesn't grant it (or grants it unasked) is refused
-- before LOGIN7; once logged in, the client's first packet is the SYN for
-- session 0, with its window, and the session setup batch follows as DATA
-- on that session, not as plain TDS.  A failed setup (a failed DONE
-- without an ERROR token) fails 'connect' with 'SevereError' and leaves
-- nothing behind: the socket is closed and the reader thread stopped.
module Mars.SmpNegotiationSpec (spec) where

import Control.Concurrent (ThreadId, threadDelay)
import Control.Exception
import Control.Monad (filterM, forM_)
import Data.Binary.Put (Put)
import qualified Data.Text as T
import Data.Word (Word16, Word32, Word8)
import GHC.Conc (ThreadStatus (..), listThreads, threadStatus)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (batchText)
import Hmssql
import Hmssql.Connection (connectionMars)
import Hmssql.Errors
import Hmssql.Tds.Client (Prelogin (..), PreloginOption (..))
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (Done (..))
import Mars.MockSmp
import MockServer (doneToken)
import Resources.Helpers (threadLabelOf)
import TestDb (serial)

marsOption :: Prelogin -> [Word8]
marsOption (Prelogin opts) = [m | PLMars m <- opts]

-- | The live threads labelled as a connection's reader.
liveReaders :: IO [ThreadId]
liveReaders = do
  ts <- listThreads
  flip filterM ts $ \t -> do
    label <- threadLabelOf t
    status <- threadStatus t
    pure (label == Just "hmssql: connection reader" && status `notElem` [ThreadFinished, ThreadDied])

-- | The reader threads alive but those given, once they have ended, or
-- after 10 s those still alive.  'close' stops a reader with 'killThread',
-- which returns once the exception has been raised in it, and the thread
-- then has its exit still to run when it is next scheduled (the library
-- doesn't wait for that: docs/dev/design.md, "Connection lifecycle").
-- Under load that took long enough for a check made just after 'connect'
-- threw to see the reader alive.  A reader that was never stopped waits
-- on its socket for good, and is still there after the bound.
readersLeftBeyond :: [ThreadId] -> IO [ThreadId]
readersLeftBeyond before = go (1000 :: Int)
  where
    go n = do
      left <- filter (`notElem` before) <$> liveReaders
      if null left || n <= 0 then pure left else threadDelay 10_000 >> go (n - 1)

-- | Of each packet: flags, SID, SEQNUM, WNDW.
headers :: [SmpIn] -> [(Word8, Word16, Word32, Word32)]
headers = map (\p -> (inFlags p, inSid p, inSeq p, inWindow p))

setup :: [T.Text]
setup = ["SET ARITHABORT ON", "SET NOCOUNT ON"]

setupBatch :: T.Text
setupBatch = T.intercalate "\n" setup

spec :: Spec
spec = do
  describe "negotiating MARS (mock server)" $ do
    forM_ [("answers MARS = 0", Just 0), ("leaves the MARS option out", Nothing)] $ \(what, answer) ->
      it ("connectMars against a server that " ++ what ++ ": MarsNotSupported, and nothing more is sent") $
        withSmpServer defaultSmpConfig { cfgMars = answer } $ \srv -> do
          r <- within 30 $ try (connect (smpConnectInfo srv))
          case r of
            Left MarsNotSupported -> pure ()
            Right conn -> close conn >> expectationFailure "connected"
          out <- nextOutcome srv
          marsOption (outPrelogin out) `shouldBe` [1]
          (outLoggedIn out, outClientClosed out) `shouldBe` (False, True)

    it "a server that answers MARS = 1 unasked: ProtocolError, and nothing more is sent" $
      withSmpServer defaultSmpConfig $ \srv -> do
        r <- within 30 $ try (connect (smpConnectInfo srv) { connectMars = False })
        case r of
          Left (ProtocolError msg) -> msg `shouldContain` "MARS"
          Right conn -> close conn >> expectationFailure "connected"
        out <- nextOutcome srv
        marsOption (outPrelogin out) `shouldBe` [0]
        (outLoggedIn out, outClientClosed out) `shouldBe` (False, True)

    it "PRELOGIN asks for MARS (option 1) only with connectMars" $ do
      withSmpServer defaultSmpConfig { cfgMars = Just 0 } $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) { connectMars = False } $ \_ -> pure ()
        out <- nextOutcome srv
        marsOption (outPrelogin out) `shouldBe` [0]
        (outLoggedIn out, outReceived out) `shouldBe` (True, [])
      withSmpServer defaultSmpConfig $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) $ \_ -> pure ()
        out <- nextOutcome srv
        marsOption (outPrelogin out) `shouldBe` [1]

    it "connectionMars: True when the server answers MARS = 1, False without connectMars when it answers 0" $ do
      withSmpServer defaultSmpConfig $ \srv ->
        within 30 $ withConnection (smpConnectInfo srv) $ \conn -> connectionMars conn `shouldBe` True
      withSmpServer defaultSmpConfig { cfgMars = Just 0 } $ \srv ->
        within 30 $ withConnection (smpConnectInfo srv) { connectMars = False } $ \conn ->
          connectionMars conn `shouldBe` False

  describe "starting SMP (mock server)" $ do
    it "sends the SYN for session 0, with SEQNUM 0 and the window, first; nothing else without a request" $
      withSmpServer defaultSmpConfig $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) $ \_ -> threadDelay 50_000
        out <- nextOutcome srv
        headers (outReceived out) `shouldBe` [(flagSyn, 0, 0, 64)]
        outViolations out `shouldBe` []

    forM_ [(1, 4), (3, 4), (4, 4), (64, 64), (1000, 1000), (maxBound, 0x7FFFFFFF)] $ \(asked, sent) ->
      it ("advertises a window of " ++ show sent ++ " for connectMarsWindow " ++ show asked) $
        withSmpServer defaultSmpConfig $ \srv -> do
          within 30 $ withConnection (smpConnectInfo srv) { connectMarsWindow = asked } $ \conn ->
            query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)
          out <- nextOutcome srv
          -- The SYN, the request, and with a window under 32 (an ACK
          -- every packet) the ACK for the response's one packet.
          [(inFlags p, inWindow p) | p <- outReceived out]
            `shouldBe` [(flagSyn, sent), (flagData, sent)] ++ [(flagAck, sent + 1) | sent < 32]
          outViolations out `shouldBe` []

    it "runs the session setup batch as DATA on session 0, after the SYN, not as plain TDS" $
      withSmpServer defaultSmpConfig $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) { connectSessionSetup = setup } $ \conn ->
          query1 conn "SELECT 6" `shouldReturn` Only (6 :: Int)
        out <- nextOutcome srv
        -- The second request's window counts the setup response's packet.
        headers (outReceived out) `shouldBe` [(flagSyn, 0, 0, 64), (flagData, 0, 1, 64), (flagData, 0, 2, 65)]
        [(cmSid msg, cmType msg, batchText (cmBody msg)) | msg <- outMessages out]
          `shouldBe` [(0, PTSqlBatch, setupBatch), (0, PTSqlBatch, "SELECT 6")]
        outViolations out `shouldBe` []

  -- Serial: it counts the process's reader threads.
  serial $ describe "a MARS connection's session setup failing with a failed DONE and no ERROR token (mock server)" $
    forM_ failedDones $ \(label, failed, status) ->
      it (label ++ ": connect throws SevereError, the socket is closed, and no reader thread is left") $ do
        let answer m msg = respondOn m (cmSid msg) failed
        before <- liveReaders
        withSmpServer defaultSmpConfig { cfgRespond = Just answer } $ \srv -> do
          r <- within 30 $ try (connect (smpConnectInfo srv) { connectSessionSetup = setup })
          case r of
            Left e | Just se <- fromException e ->
              (doneStatus (severeErrorDone se), severeErrorStatement se) `shouldBe` (status, Just setupBatch)
            Left e -> expectationFailure ("expected the SevereError, got " ++ show e)
            Right conn -> close conn >> expectationFailure "connected"
          out <- nextOutcome srv
          outClientClosed out `shouldBe` True
          headers (outReceived out) `shouldBe` [(flagSyn, 0, 0, 64), (flagData, 0, 1, 64)]
          outViolations out `shouldBe` []
        readersLeftBeyond before `shouldReturn` []

-- | As in "Connection.FailedDoneSpec": the ways a response says it failed
-- without an ERROR token, with the status of the DONE that says so.
failedDones :: [(String, [Put], Word16)]
failedDones =
  [ ("a final DONE flagged DONE_ERROR", [doneToken 0x0002 0], 0x0002)
  , ("a final DONE flagged DONE_SRVERROR", [doneToken 0x0100 0], 0x0100)
  , ("a statement's DONE flagged DONE_ERROR, then a final DONE", [doneToken 0x0003 0, doneToken 0 0], 0x0003)
  ]
