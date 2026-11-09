-- | Reset on a MARS connection, against the mock server ("Mars.MockSmp"),
-- for the answers SQL Server gives rarely or never, and so the live tests
-- ("MarsTx.ResetSpec", "MarsTx.ResetGateSpec") can't reach:
--
-- * A reset-carrying request cancelled before it was answered: SQL Server
--   has always applied and acknowledged the reset in the cancelled
--   response.  If the acknowledgement is missing all the same, the reset is
--   asked for again, and the next request carries the bit; with it, the
--   next request doesn't.
-- * A reset refused (a DONE flagged as failed, with no ERROR token and no
--   acknowledgement: how the server answers one sent beside an active
--   request, which the client never does).  Without a session setup the
--   request throws 'SevereError', is not taken for success, and asks for
--   no second reset; the acknowledgement arriving later, on another
--   response, is applied there (it ends the transaction).  With a session
--   setup, the setup batch that carried the bit fails and the connection
--   is broken.
-- * The session setup at connect, run on session 0 once SMP has started,
--   answered with such a DONE: 'connect' throws 'SevereError' and returns
--   no connection.
module Mars.SmpResetSpec (spec) where

import Control.Exception
import Control.Monad (forM_, void)
import Data.Binary.Put (Put)
import Data.IORef
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (answerSelect, batchText, doneAttn, doneFinal, selectedNumber)
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (Done (..))
import Hmssql.Transaction
import Mars.MockSmp
import MockServer

-- | Answer each message with what the function gives for it, on its
-- session; 'Nothing' leaves it unanswered (a statement still running).
answering :: (ClientMsg -> IO (Maybe [Put])) -> SmpMock -> ClientMsg -> IO ()
answering answer m msg = answer msg >>= mapM_ (respondOn m (cmSid msg))

-- | The batch's text, or "" for another message.
textOf :: ClientMsg -> Text
textOf ClientMsg{..}
  | cmType == PTSqlBatch = batchText cmBody
  | otherwise = ""

-- | What SQL Server answers with no reset involved: @BEGIN TRAN@ begins
-- transaction 1, @SELECT n@ gives @n@, an Attention is acknowledged,
-- anything else gets a final DONE.
plain :: ClientMsg -> [Put]
plain msg
  | cmType msg == PTAttention = [doneAttn]
  | "BEGIN TRAN" `T.isPrefixOf` textOf msg = [beginTransactionEnvChange 1, doneFinal 0]
  | Just n <- selectedNumber (textOf msg) = answerSelect n
  | otherwise = [doneFinal 0]

-- | The type, RESETCONNECTION bit and text of every message the client sent.
sent :: SmpOutcome -> [(PacketType, Bool, Text)]
sent out = [(cmType msg, cmReset msg, textOf msg) | msg <- outMessages out]

-- | A 'SevereError' carrying a DONE with this status.
isSevere :: Word16 -> SomeException -> Bool
isSevere status e = case fromException e of
  Just se -> doneStatus (severeErrorDone se) == status
  Nothing -> False

refusedDone :: Put
refusedDone = doneToken 0x0002 0

spec :: Spec
spec = describe "reset on a MARS connection (mock server)" $ do
  describe "a reset-carrying request cancelled before it was answered" $
    forM_ [(False, "without the reset's acknowledgement: the reset is asked for again, and the next request carries the bit"), (True, "with it: the next request carries no bit")] $ \(acked, label) ->
      it ("answered with the Attention's acknowledgement " ++ label) $ do
        let answer msg
              | textOf msg == "WAITFOR DELAY '00:01:00'" = pure Nothing
              | cmType msg == PTAttention = pure (Just ([resetConnectionEnvChange | acked] ++ [doneAttn]))
              | otherwise = pure (Just (plain msg))
        withSmpServer defaultSmpConfig { cfgRespond = Just (answering answer) } $ \srv -> do
          within 30 $ withConnection (smpConnectInfo srv) { connectSessionSetup = [] } $ \conn -> do
            reset conn
            resp <- startResponse conn (batchRequest "WAITFOR DELAY '00:01:00'")
            cancelResponse resp
            readIORef (connResetPending conn) `shouldReturn` not acked
            query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
            readIORef (connResetPending conn) `shouldReturn` False
          out <- nextOutcome srv
          outViolations out `shouldBe` []
          sent out `shouldBe`
            [ (PTSqlBatch, True, "WAITFOR DELAY '00:01:00'"), (PTAttention, False, "")
            , (PTSqlBatch, not acked, "SELECT 2") ]

  describe "a refused reset (a failed DONE, no ERROR token, no acknowledgement)" $ do
    it "without a session setup: the request throws SevereError; no second reset is asked for; the acknowledgement on a later response ends the transaction" $ do
      refusedOnce <- newIORef False
      let answer msg
            | cmReset msg = do
                writeIORef refusedOnce True
                pure (Just [refusedDone])
            | otherwise = readIORef refusedOnce >>= \case
                -- The server's pending reset, acknowledged on the next
                -- response: the transaction's rollback, then the
                -- acknowledgement.
                True -> do
                  writeIORef refusedOnce False
                  pure (Just ([rollbackTransactionEnvChange 1, resetConnectionEnvChange] ++ plain msg))
                False -> pure (Just (plain msg))
      withSmpServer defaultSmpConfig { cfgRespond = Just (answering answer) } $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) { connectSessionSetup = [] } $ \conn -> do
          void $ execute conn "BEGIN TRAN"
          inTransaction conn `shouldReturn` True
          reset conn
          execute conn "SELECT 2" `shouldThrow` isSevere 0x0002
          readIORef (connResetPending conn) `shouldReturn` False
          readIORef (connBroken conn) >>= (`shouldSatisfy` isNothing)
          query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int)
          inTransaction conn `shouldReturn` False
          query1 conn "SELECT 4" `shouldReturn` Only (4 :: Int)
        out <- nextOutcome srv
        outViolations out `shouldBe` []
        sent out `shouldBe`
          [ (PTSqlBatch, False, "BEGIN TRAN"), (PTSqlBatch, True, "SELECT 2")
          , (PTSqlBatch, False, "SELECT 3"), (PTSqlBatch, False, "SELECT 4") ]

    it "with a session setup: the setup batch carrying the bit throws SevereError, the request never goes out, and the connection is broken" $ do
      let answer msg = pure $ Just $ if cmReset msg then [refusedDone] else plain msg
      withSmpServer defaultSmpConfig { cfgRespond = Just (answering answer) } $ \srv -> do
        within 30 $ withConnection (smpConnectInfo srv) { connectSessionSetup = ["SET ARITHABORT ON"] } $ \conn -> do
          reset conn
          (query1 conn "SELECT 2" :: IO (Only Int)) `shouldThrow` isSevere 0x0002
          try (query1 conn "SELECT 3" :: IO (Only Int)) >>= \case
            Left (ConnectionBroken (ResetRefused Nothing)) -> pure ()
            other -> expectationFailure ("expected ConnectionBroken (ResetRefused Nothing), got " ++ show other)
        out <- nextOutcome srv
        outViolations out `shouldBe` []
        sent out `shouldBe` [(PTSqlBatch, False, "SET ARITHABORT ON"), (PTSqlBatch, True, "SET ARITHABORT ON")]

  it "the session setup at connect, on session 0, answered with a failed DONE and no ERROR token: connect throws SevereError and returns no connection" $ do
    let answer msg = pure $ Just $ if cmType msg == PTSqlBatch then [refusedDone] else plain msg
    withSmpServer defaultSmpConfig { cfgRespond = Just (answering answer) } $ \srv -> do
      r <- within 30 $ try (connect (smpConnectInfo srv) { connectSessionSetup = ["SET ARITHABORT ON"] })
      case r of
        Left e | isSevere 0x0002 e -> pure ()
        Left e -> expectationFailure ("expected the SevereError, got " ++ show e)
        Right conn -> close conn >> expectationFailure "connected"
      out <- nextOutcome srv
      outViolations out `shouldBe` []
      outClientClosed out `shouldBe` True
      sent out `shouldBe` [(PTSqlBatch, False, "SET ARITHABORT ON")]
