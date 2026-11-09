-- | Tests found by mutation testing of "Hmssql.Connection.Internal" (how
-- transport failures and 'close' are reported) and "Hmssql.Transaction"
-- (which error of the begin request is reported), against the mock server.
module Mutation.TransportSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, replicateM_, unless, void)
import Data.Int (Int32)
import Data.Maybe (isJust)
import Compat (timeoutInSlices)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Packet (PacketType (..))
import MockServer

within :: IO a -> IO a
within act = timeoutInSlices 20_000_000 act >>= maybe (throwIO (userError "timed out")) pure

describeReason :: SomeException -> String
describeReason e = case fromException e of
  Just (ConnectionClosedBy ClosedByServer) -> "ClosedByServer"
  Just (ConnectionClosedBy ClosedByClient) -> "ClosedByClient"
  Just (ConnectionClosedBy (TransportFailed cause))
    | isJust (fromException cause :: Maybe IOException) -> "TransportFailed IOException"
    | otherwise -> "TransportFailed " ++ show cause
  Nothing -> "not ConnectionClosed: " ++ show e

message :: Int32 -> ServerMessage
message n = ServerMessage n 1 16 "boom" "mock" "" 1

spec :: Spec
spec = do
  describe "a transport failure (mock server)" $
    it "a connection reset is TransportFailed with the IOException, not ClosedByServer" $ do
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            _ <- recvMessage mc
            resetConnection mc
      withMockServer handler $ \srv -> do
        r <- within $ withConnection (mockConnectInfo srv) $ \conn ->
          try (query1 conn "SELECT 1" :: IO (Only Int32))
        _ <- nextResult srv
        either describeReason show r `shouldBe` "TransportFailed IOException"

  describe "close from another thread (mock server)" $
    it "always fails the waiting request with ClosedByClient" $ do
      -- The mock never answers, so the request waits until 'close'.
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            _ <- recvMessageMaybe mc
            _ <- recvMessageMaybe mc
            pure ()
      withMockServer handler $ \srv ->
        replicateM_ 30 $ do
          conn <- connect (mockConnectInfo srv)
          result <- newEmptyMVar
          _ <- forkIO $ try (query1 conn "SELECT 1" :: IO (Only Int32)) >>= putMVar result
          threadDelay 20_000
          close conn
          r <- within (takeMVar result)
          _ <- nextResult srv
          either describeReason show r `shouldBe` "ClosedByClient"

  describe "withTransactionLevel's begin request (mock server), before the body's first batch or RPC" $
    forM_ [("a batch", void . flip execute "SELECT 1"), ("an RPC", \conn -> void (execute conn ("SELECT " <> param (1 :: Int32))))] $ \(label, request) ->
      it ("reports the response's first error, the body's first request " ++ label) $ do
        let handler mc = do
              _ <- serveLogin defaultLoginResponse mc
              (ptype, _) <- recvMessage mc
              unless (ptype == PTTransactionManager) $
                throwIO (MockUnexpected ("expected the begin request, got " ++ show ptype))
              sendTokens mc [errorToken (message 50001), errorToken (message 50002), doneToken 0x02 0]
              serveRequests (\_ _ -> pure [doneToken 0 0]) mc
        withMockServer handler $ \srv -> do
          r <- within $ withConnection (mockConnectInfo srv) $ \conn ->
            try (withTransactionLevel Serializable conn (request conn))
          case r of
            Left e -> sqlErrorNumber e `shouldBe` 50001
            Right () -> expectationFailure "the transaction started"
          nextResult srv >>= either (\e -> expectationFailure ("mock: " ++ show e)) pure
