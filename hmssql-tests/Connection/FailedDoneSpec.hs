-- | A response to the session setup, reset or release batch that says the
-- request failed only by a DONE flagged DONE_ERROR or DONE_SRVERROR, with
-- no ERROR token (how the server refuses a reset under MARS, with another
-- request active), is a failure, 'SevereError', never success: 'connect'
-- throws it and returns no connection; the request that a pending reset
-- with a session setup goes before throws it, and the connection is
-- broken; 'release' with a transaction open gives 'False', and the
-- connection is broken.  Against the mock server, with each kind of
-- failed DONE.
module Connection.FailedDoneSpec (spec) where

import Control.Exception
import Control.Monad (forM_, void)
import Data.Binary.Put (Put)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock (batchText)
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Connection.Internal (Connection (..), renewLease)
import Hmssql.Errors
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (Done (..))
import Hmssql.Transaction
import MockServer

-- | Log in, then answer every SQL batch with the tokens @answer@ gives for
-- its text and RESETCONNECTION bit, until the client closes the
-- connection; returns every batch, with its bit.
recordingServer :: (Text -> Bool -> [Put]) -> MockConn -> IO [(Text, Bool)]
recordingServer answer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let loop acc = recvMessageWithReset mc >>= \case
        Nothing -> pure (reverse acc)
        Just (PTSqlBatch, resetting, body) -> do
          let sql = batchText body
          sendTokens mc (answer sql resetting)
          loop ((sql, resetting) : acc)
        Just (ptype, _, _) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))
  loop []

-- | The ways a response says it failed without an ERROR token, with the
-- status of the DONE that says so.
failedDones :: [(String, [Put], Word16)]
failedDones =
  [ ("a final DONE flagged DONE_ERROR", [doneToken 0x0002 0], 0x0002)
  , ("a final DONE flagged DONE_SRVERROR", [doneToken 0x0100 0], 0x0100)
  , ("a statement's DONE flagged DONE_ERROR, then a final DONE", [doneToken 0x0003 0, doneToken 0 0], 0x0003)
  ]

-- | As SQL Server answers a batch that succeeds: the reset acknowledgement
-- if it carries the RESETCONNECTION bit, a begin-transaction ENVCHANGE for
-- @BEGIN TRAN@, and a final DONE.
succeeding :: Text -> Bool -> [Put]
succeeding sql resetting =
  [resetConnectionEnvChange | resetting]
    ++ [beginTransactionEnvChange 1 | "BEGIN TRAN" `T.isPrefixOf` sql]
    ++ [doneToken 0 0]

-- | 'succeeding', except that a batch carrying the RESETCONNECTION bit
-- fails with the given tokens alone.
refusingReset :: [Put] -> Text -> Bool -> [Put]
refusingReset failed sql resetting
  | resetting = failed
  | otherwise = succeeding sql resetting

setup :: [Text]
setup = ["SET ARITHABORT ON", "SET NOCOUNT ON"]

setupBatch :: Text
setupBatch = T.intercalate "\n" setup

-- | A 'SevereError' for the batch, carrying the DONE with the status.
isSevere :: Text -> Word16 -> SomeException -> Bool
isSevere sql status e = case fromException e of
  Just se -> doneStatus (severeErrorDone se) == status && severeErrorStatement se == Just sql
  Nothing -> False

-- | The reason a failed DONE to a reset gives: the refusal, or for
-- DONE_SRVERROR on a batch hmssql reads itself, the DONE's own.
isRefusal :: UnusableReason -> Bool
isRefusal = \case
  ResetRefused Nothing -> True
  ServerFailedConnection _ -> True
  _ -> False

-- | The connection is broken by the refusal, and the next request says so.
checkBroken :: Connection -> IO ()
checkBroken conn = do
  readIORef (connBroken conn) >>= \case
    Just r | isRefusal r -> pure ()
    other -> expectationFailure ("expected broken by the refusal, got " ++ show other)
  try (execute conn "SELECT 3") >>= \case
    Left (ConnectionBroken r) | isRefusal r -> pure ()
    Left e -> expectationFailure ("expected ConnectionBroken with the refusal, got " ++ show e)
    Right n -> expectationFailure ("the broken connection answered " ++ show n)

mockOutcome :: Either SomeException r -> IO r
mockOutcome = either (\e -> throwIO (userError ("mock: " ++ show e))) pure

spec :: Spec
spec = forM_ failedDones $ \(label, failed, status) -> describe ("a response with " ++ label ++ " and no ERROR token (mock server)") $ do
  it "to the session setup batch at connect: connect throws SevereError, and returns no connection" $
    withMockServer (recordingServer (\_ _ -> failed)) $ \srv -> do
      r <- within 30 $ try (connect (mockConnectInfo srv) { connectSessionSetup = setup })
      case r of
        Left e | isSevere setupBatch status e -> pure ()
        Left e -> expectationFailure ("expected the SevereError, got " ++ show e)
        Right conn -> close conn >> expectationFailure "connected"
      -- The setup batch, then nothing: the client closed the connection.
      nextResult srv >>= mockOutcome >>= (`shouldBe` [(setupBatch, False)])

  -- The request with the reset pending sends the setup batch, carrying
  -- the bit, before itself; it never goes out.
  forM_ [ ("execute", \conn -> void (execute conn "SELECT 2"))
        , ("withTransaction", \conn -> withTransaction conn (void (execute conn "SELECT 2")))
        , ("begin", begin) ] $ \(request, act) ->
    it ("to the reset batch (with a session setup): " ++ request ++ " throws SevereError, and the connection is broken") $
      withMockServer (recordingServer (refusingReset failed)) $ \srv -> do
        within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = setup } $ \conn -> do
          reset conn
          try (act conn) >>= \case
            Left e | isSevere setupBatch status e -> pure ()
            Left e -> expectationFailure ("expected the SevereError, got " ++ show e)
            Right () -> expectationFailure (request ++ " succeeded")
          checkBroken conn
        nextResult srv >>= mockOutcome >>= (`shouldBe` [(setupBatch, False), (setupBatch, True)])

  -- With a transaction open, 'release' resets at once: by a SELECT 1, or
  -- by the setup batch, carrying the bit.
  forM_ [("without a session setup", [], "SELECT 1"), ("with a session setup", setup, setupBatch)] $ \(which, s, resetBatch) ->
    it ("to release's reset with a transaction open, " ++ which ++ ": release gives False, and the connection is broken") $
      withMockServer (recordingServer (refusingReset failed)) $ \srv -> do
        within 30 $ withConnection (mockConnectInfo srv) { connectSessionSetup = s } $ \conn -> do
          _ <- execute conn "BEGIN TRAN"
          inTransaction conn `shouldReturn` True
          release conn `shouldReturn` False
          renew conn `shouldThrow` \(ConnectionBroken r) -> isRefusal r
          renewLease conn >>= checkBroken
        nextResult srv >>= mockOutcome >>= (`shouldBe`
          [(setupBatch, False) | not (null s)] ++ [("BEGIN TRAN", False), (resetBatch, True)])
