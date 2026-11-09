{-# LANGUAGE ViewPatterns #-}
-- | A fatal ERROR must end reuse before the peer sends EOF or SMP FIN.
module Protocol.FatalErrorSpec (spec) where

import UnusableCause (reasonCause, brokenCause)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception
import Control.Monad (forM_, void)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Int (Int64)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock
import Hmssql
import Hmssql.BatchQuery
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Query (callProcedure)
import Hmssql.Connection.Internal (Connection (..), nextToken, renewLease, startRequest)
import Hmssql.Errors
import Hmssql.Tds.Packet
import Hmssql.Types (ServerMessage (..))
import Mars.MockSmp
import MockServer (errorToken)

fatal :: ServerMessage
fatal = ServerMessage 50001 1 20 "fatal" "mock" "" 1

expectFatal :: IO a -> IO ()
expectFatal act = try @SomeException act >>= \case
  Left e | Just se <- fromException e -> sqlError se `shouldBe` fatal
  Left e -> expectationFailure ("expected the fatal server message, got " ++ show e)
  Right _ -> expectationFailure "expected the fatal server message"

expectBrokenFatal :: IO a -> IO ()
expectBrokenFatal act = try act >>= \case
  Left (ConnectionBroken (reasonCause -> e)) | Just se <- fromException e -> sqlError se `shouldBe` fatal
  Left e -> expectationFailure ("expected ConnectionBroken carrying the fatal message, got " ++ show e)
  Right _ -> expectationFailure "the broken connection accepted work"

-- Both peers stay open until the client closes. In the cancellation case
-- the fatal message is sent only after the Attention, so the drain must
-- parse it. Otherwise it is the request's response, with or without DONE.
withFatal :: Bool -> Bool -> Bool -> [Put] -> (Connection -> IO ()) -> IO ()
withFatal mars draining eom toks act
  | mars = withSmpServer defaultSmpConfig { cfgRespond = Just respond } $ \srv -> do
      within 10 $ withConnection (smpConnectInfo srv) act
      out <- nextOutcome srv
      outViolations out `shouldBe` []
      outErrors out `shouldBe` []
  | otherwise = do
      (_, outcome) <- withScripted script $ \ci -> within 10 $ withConnection ci act
      either (expectationFailure . show) (`shouldBe` []) outcome
  where
    partial = [colMetaBigint "n", rowBigint 1]
    respond m msg
      | draining && cmType msg /= PTAttention = respondPackets m (cmSid msg) [tdsPacket False (tokenBytes partial)]
      | otherwise = respondPackets m (cmSid msg) [tdsPacket eom (tokenBytes toks)]
    script io = do
      _ <- mRecv io 5_000_000
      if draining
        then mSendPacket io False (tokenBytes partial) >> expectAttention io
        else pure ()
      mSendPacket io eom (tokenBytes toks)
      serveSelects io

spec :: Spec
spec = forM_ [False, True] $ \mars -> describe (if mars then "fatal ERROR over MARS" else "fatal ERROR over plain TDS") $ do
  it "refuses pooling after a fatal ERROR and final DONE, before EOF" $
    withFatal mars False True [errorToken fatal, doneFinal 0] $ \conn -> do
      expectFatal (execute conn "SELECT 1")
      expectBrokenFatal (execute conn "SELECT 2")
      release conn `shouldReturn` False

  forM_ [("batch", \c -> void (runBatchQuery c (traverse batchExecute statements))),
         ("executeStatements", \c -> void (executeStatements c statements))] $ \(label, consume) ->
    forM_ [False, True] $ \second -> it (label ++ " attributes a fatal error to the current statement (second " ++ show second ++ ")") $ do
      let doneProc = Put.putWord8 0xFE >> Put.putWord16le 1 >> Put.putWord16le 0 >> Put.putWord64le 0
      withFatal mars False False ([doneProc | second] ++ [errorToken fatal]) $ \conn -> do
        try (consume conn) >>= \case
          Left se -> do
            sqlError se `shouldBe` fatal
            sqlErrorStatement se `shouldBe` Just (if second then "SELECT 2" else "SELECT 1")
          Right _ -> expectationFailure "expected SqlServerError"
        release conn `shouldReturn` False

  forM_ [19, 25] $ \severity -> it ("severity " ++ show severity ++ " has the correct reuse policy") $
    withFatal mars False True [errorToken (fatal { msgClass = severity }), doneFinal 0] $ \conn -> do
      try (execute conn "SELECT 1") >>= \case
        Left se -> msgClass (sqlError se) `shouldBe` severity
        Right _ -> expectationFailure "expected SqlServerError"
      release conn `shouldReturn` (severity < 20)

  forM_ [False, True] $ \earlier -> describe (if earlier then "after a nonfatal ERROR" else "as the first ERROR") $ do
    let toks = [errorToken (fatal { msgNumber = 50000, msgClass = 16 }) | earlier] ++ [errorToken fatal]
        consumers =
          [ ("execute", void . (`execute` "SELECT 1"))
          , ("procedure", \c -> void (callProcedure c "p" []))
          , ("batch", \c -> void (runBatchQuery c (batchExecute "SELECT 1")))
          , ("raw tokens", \c -> do
                ar <- startRequest c PTSqlBatch (const mempty)
                let loop = nextToken c ar >>= maybe (pure ()) (const loop)
                loop)
          ]
    forM_ consumers $ \(label, consume) -> it (label ++ " throws the fatal message without waiting for DONE or EOF") $
      withFatal mars False False toks $ \conn -> do
        expectFatal (consume conn)
        readTVarIO (connEnded conn) >>= (`shouldSatisfy` maybe True (const False))
        expectBrokenFatal (execute conn "SELECT 2")
        release conn `shouldReturn` False

    forM_ [False, True] $ \releasing -> it (if releasing then "release rejects a fatal cancellation drain before EOF" else "cancellation throws the fatal message before EOF") $
      withFatal mars True False toks $ \conn -> do
        stream <- queryS conn "SELECT 1"
        Right (Only (1 :: Int64), _) <- S.next stream
        if releasing
          then release conn `shouldReturn` False
          else expectFatal (cancelActiveStatement conn)
        brokenCause conn >>= \case
          Just e | Just se <- fromException e -> sqlError se `shouldBe` fatal
          other -> expectationFailure ("expected a fatal broken cause, got " ++ show other)
        readTVarIO (connEnded conn) >>= (`shouldSatisfy` maybe True (const False))
        conn' <- if releasing then renewLease conn else pure conn
        expectBrokenFatal (execute conn' "SELECT 2")
        release conn' `shouldReturn` False
  where
    statements = ["SELECT 1", "SELECT 2", "SELECT 3"]
