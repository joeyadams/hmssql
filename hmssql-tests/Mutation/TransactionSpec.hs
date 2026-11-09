{-# LANGUAGE DerivingStrategies #-}

-- | Tests found by mutation testing of "Hmssql.Transaction" (and the
-- pending reset and transaction descriptor it checks).
module Mutation.TransactionSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (forM_, void, when)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import Data.Int (Int16)
import qualified Data.Text as T
import Data.Word (Word8)
import System.Timeout (timeout)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Mock (batchText, tmBeginLevel)
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Transaction
import Hmssql.Types
import Hmssql.Tds.Packet (PacketType (..))
import MockServer
import OpenResponses (isMarsConnection)
import Protocol.MockTokens
import TestDb

level :: Connection -> IO Int16
level conn = fromOnly <$> query1 conn
  "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID"

endedEarly :: IO a -> IO ()
endedEarly act = try act >>= \case
  Left TransactionEndedEarly -> pure ()
  Left e -> expectationFailure ("threw " ++ show e)
  Right _ -> expectationFailure "no TransactionEndedEarly"

-- | The mock's side of an interrupted 'withTransactionLevel': answer the
-- Transaction Manager request that begins the transaction in two packets,
-- the second one late, then return its isolation-level byte (Nothing if
-- it was another request) and the text of the next batch (the cleanup),
-- acknowledging the Attention the interrupted read sends on the way.
interruptedBeginServer :: MockConn -> IO (Maybe Word8, T.Text)
interruptedBeginServer mc = do
  _ <- serveLogin defaultLoginResponse mc
  (ptype, body) <- recvMessage mc
  let begun = if ptype == PTTransactionManager then tmBeginLevel body else Nothing
  sendRaw mc $ packet False $ tokenBytes [envChangeToken 8 (B.pack ([8, 1, 2, 3, 4, 5, 6, 7, 8] ++ [0]))]
  -- The client is interrupted before the response's DONE arrives.
  threadDelay 1_000_000
  sendRaw mc $ packet True $ tokenBytes [doneToken 0 0]
  let next = recvMessage mc >>= \case
        (PTAttention, _) -> sendTokens mc [doneToken 0x20 0] >> next
        (_, body') -> do
          sendTokens mc [doneToken 0 0]
          pure (begun, batchText body')
  next

-- | What 'transactionServer' received: a SQL batch's text, an RPC, or a
-- Transaction Manager request that begins a transaction, with its
-- isolation-level byte.
data Received = Batch T.Text | Rpc | TmBegin Word8
  deriving stock (Eq, Show)

-- | A mock server that tracks one transaction: a Transaction Manager
-- request that begins one (TM_BEGIN_XACT) or BEGIN TRANSACTION starts one
-- with a new descriptor, ROLLBACK and COMMIT end it (reported with
-- ENVCHANGEs, as SQL Server does).  Returns every request, until the
-- client closes the connection.
transactionServer :: MockConn -> IO [Received]
transactionServer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let begin d = envChangeToken 8 (B.pack (8 : descriptor d ++ [0]))
      rollback d = envChangeToken 10 (B.pack (0 : 8 : descriptor d))
      commit d = envChangeToken 9 (B.pack (0 : 8 : descriptor d))
      descriptor :: Word8 -> [Word8]
      descriptor d = [d, 0, 0, 0, 0, 0, 0, 0]
      -- The statements of a batch, in order, with the transaction (its
      -- descriptor) open before them and the next free descriptor.
      run open next acc = \case
        [] -> (open, next, reverse acc)
        stmt : more
          | stmt == "BEGIN TRANSACTION" -> run (Just next) (next + 1) (begin next : acc) more
          | stmt `elem` ["ROLLBACK TRANSACTION", "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"] ->
              run Nothing next (maybe acc (\d -> rollback d : acc) open) more
          | stmt == "COMMIT TRANSACTION" -> run Nothing next (maybe acc (\d -> commit d : acc) open) more
          | otherwise -> run open next acc more
      loop open next received = recvMessageMaybe mc >>= \case
        Nothing -> pure (reverse received)
        -- An RPC changes no transaction here.  (One DONEPROC: one RPC.)
        Just (PTRpc, _) -> do
          sendTokens mc [Put.putWord8 0xFE >> Put.putWord16le 0 >> Put.putWord16le 0 >> Put.putWord64le 0]
          loop open next (Rpc : received)
        Just (PTTransactionManager, body) -> case tmBeginLevel body of
          Just lvl -> do
            sendTokens mc [begin next, doneToken 0 0]
            loop (Just next) (next + 1) (TmBegin lvl : received)
          Nothing -> throwIO (MockUnexpected "a Transaction Manager request other than TM_BEGIN_XACT")
        Just (PTSqlBatch, body) -> do
          let sql = batchText body
              stmts = map T.strip (T.splitOn ";" sql)
          if any ("SELEC " `T.isPrefixOf`) stmts
            then do
              -- A batch that doesn't compile runs nothing.
              sendTokens mc [messageToken 0xAA (ServerMessage 102 1 15 "Incorrect syntax" "mock" "" 1), doneToken 0x02 0]
              loop open next (Batch sql : received)
            else do
              let (open', next', toks) = run open next [] stmts
              sendTokens mc (toks ++ [doneToken 0 0])
              loop open' next' (Batch sql : received)
        Just (ptype, _) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))
  loop Nothing 1 []

spec :: Spec
spec = do
  describe "withTransactionLevel interrupted while reading the begin request's response (mock server)" $
    it "drains it, and sets the level back to READ COMMITTED in the cleanup" $ withMockServer interruptedBeginServer $ \srv -> do
      withConnection (mockConnectInfo srv) $ \conn ->
        timeout 300_000 (withTransactionLevel Serializable conn (void (execute conn "SELECT 1")))
          `shouldReturn` Nothing
      nextResult srv >>= \case
        Left e -> expectationFailure ("mock: " ++ show e)
        Right (begun, cleanup) -> do
          -- SERIALIZABLE, set by the begin request itself.
          begun `shouldBe` Just 4
          cleanup `shouldBe` "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; SET TRANSACTION ISOLATION LEVEL READ COMMITTED"

  describe "withTransaction checks the transaction's identity (mock server)" $ do
    it "commits the transaction it began" $ withMockServer transactionServer $ \srv -> do
      withConnection (mockConnectInfo srv) $ \conn -> do
        withTransaction conn (void (execute conn "SELECT 1"))
        inTransaction conn `shouldReturn` False
      nextResult srv >>= \case
        Left e -> expectationFailure ("mock: " ++ show e)
        Right received -> received `shouldBe` [TmBegin 0, Batch "SELECT 1", Batch "COMMIT TRANSACTION"]

    it "rolls back, instead of committing, a transaction the body began in its place (TransactionEndedEarly)" $
      withMockServer transactionServer $ \srv -> do
        withConnection (mockConnectInfo srv) $ \conn -> do
          endedEarly $ withTransaction conn $ do
            _ <- execute conn "ROLLBACK TRANSACTION; BEGIN TRANSACTION"
            inTransaction conn `shouldReturn` True
          inTransaction conn `shouldReturn` False
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right received -> received `shouldBe`
            [TmBegin 0, Batch "ROLLBACK TRANSACTION; BEGIN TRANSACTION", Batch "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"]

    it "rolls back, instead of committing, with a reset pending (TransactionEndedEarly)" $
      withMockServer transactionServer $ \srv -> do
        withConnection (mockConnectInfo srv) $ \conn ->
          endedEarly $ withTransaction conn (execute conn "SELECT 1" >> reset conn)
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right received -> received `shouldBe` [TmBegin 0, Batch "SELECT 1", Batch "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"]

    -- A reset before the body's first request rolls the transaction back
    -- on a real server (TransactionSpec checks); the mock ignores the
    -- RESETCONNECTION bit.

  describe "withTransaction begins with a Transaction Manager request of its own, before the body (mock server)" $ do
    let receivedBy body = withMockServer transactionServer $ \srv -> do
          _ <- withConnection (mockConnectInfo srv) body
          nextResult srv >>= either (\e -> fail ("mock: " ++ show e)) pure
    it "before a first batch" $
      receivedBy (\conn -> withTransaction conn (void (execute conn "SELECT 1") >> void (execute conn "SELECT 2")))
        `shouldReturn` [TmBegin 0, Batch "SELECT 1", Batch "SELECT 2", Batch "COMMIT TRANSACTION"]
    it "with the isolation level's byte (no SET), and the level set back in the COMMIT batch" $
      receivedBy (\conn -> withTransactionLevel Serializable conn (void (execute conn "SELECT 1")))
        `shouldReturn` [ TmBegin 4, Batch "SELECT 1"
                       , Batch "COMMIT TRANSACTION; SET TRANSACTION ISOLATION LEVEL READ COMMITTED" ]
    it "before a first RPC" $
      receivedBy (\conn -> withTransaction conn (void (execute conn ("SELECT " <> param (1 :: Int)))))
        `shouldReturn` [TmBegin 0, Rpc, Batch "COMMIT TRANSACTION"]
    it "before executeStatements" $
      receivedBy (\conn -> withTransaction conn (void (executeStatements conn ["SELECT 1"])))
        `shouldReturn` [TmBegin 0, Rpc, Batch "COMMIT TRANSACTION"]
    forM_ [ "CREATE PROCEDURE p AS SELECT 1", "CREATE TABLE t (i int)", ";WITH x AS (SELECT 1 AS a) SELECT a FROM x", "   ", "" ] $ \sql ->
      it ("before any batch, sent as it is: " ++ show sql) $
        receivedBy (\conn -> withTransaction conn (void (execute conn (rawSql sql))))
          `shouldReturn` [TmBegin 0, Batch sql, Batch "COMMIT TRANSACTION"]
    it "and commits when the body makes no request" $
      receivedBy (\conn -> do
        withTransaction conn (inTransaction conn `shouldReturn` True)
        inTransaction conn `shouldReturn` False)
        `shouldReturn` [TmBegin 0, Batch "COMMIT TRANSACTION"]
    it "and rolls back when the body throws before its first request" $
      receivedBy (\conn -> do
        r <- try (withTransaction conn (throwIO (userError "boom") :: IO ()))
        either (\(e :: IOException) -> show e `shouldContain` "boom") pure r
        inTransaction conn `shouldReturn` False)
        `shouldReturn` [TmBegin 0, Batch "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION"]
    it "after the session setup that a pending reset runs, which carries the reset" $
      withMockServer transactionServer $ \srv -> do
        withConnection (mockConnectInfo srv) { connectSessionSetup = ["SET ARITHABORT ON"] } $ \conn -> do
          reset conn
          withTransaction conn (void (execute conn "SELECT 1"))
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right received -> received `shouldBe`
            [Batch "SET ARITHABORT ON", Batch "SET ARITHABORT ON", TmBegin 0, Batch "SELECT 1", Batch "COMMIT TRANSACTION"]

  liveSpec

-- | A batch that ends the transaction begun before it, after a pause.  Sent
-- with 'queryS' and left unread, it is still running when the next request
-- starts, unless the test waits ('awaitCommitted').
endingBatch :: Query
endingBatch = rawSql endingBatchText

endingBatchText :: T.Text
endingBatchText = "SELECT 1; WAITFOR DELAY '00:00:00.100'; COMMIT TRANSACTION"

sessionId :: Connection -> IO Int16
sessionId conn = fromOnly <$> query1 conn "SELECT @@SPID"

-- | Wait, asking from another connection, until the session has no request
-- running and no transaction open: its batch has run to the end, COMMIT
-- and all, and only the client's read of the response is left.  Without
-- the wait, the Attention that the next request sends (the response is
-- unread) could cancel the batch before its COMMIT ran, leaving the
-- transaction open (TransactionAlreadyActive, in about one run in twenty
-- before 'endingBatch' had its pause; in most runs with it).
awaitCommitted :: Int16 -> IO ()
awaitCommitted spid = withTestDb $ \observer -> do
  let busy = fromOnly <$> query1 observer (mkQuery
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.dm_exec_requests WHERE session_id = @p1) \
        \  OR EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE session_id = @p1 AND open_transaction_count > 0) \
        \  THEN 1 ELSE 0 END" (Only spid))
      go :: Int -> IO ()
      go n = busy >>= \case
        (0 :: Int) -> pure ()
        _ | n <= 0 -> expectationFailure "the session's batch still runs, or its transaction is still open, after 30 s"
          | otherwise -> threadDelay 10_000 >> go (n - 1)
  go 3000

liveSpec :: Spec
liveSpec = around withTestDb $ do
  -- RESETCONNECTION keeps the isolation level (SQL Server; Azure SQL
  -- Database puts READ COMMITTED back); withTransactionLevel sets READ
  -- COMMITTED back when it ends (here with TransactionEndedEarly: reset
  -- inside withTransaction is unsupported).
  forM_ [("without a session setup", []), ("with a session setup", ["SET ARITHABORT ON"])] $ \(label, setup) ->
    describe ("reset inside withTransactionLevel, " ++ label) $ aroundWith (\act _ -> withTestDbWith (\ci -> ci { connectSessionSetup = setup }) act) $
      it "a request after the reset is out of the transaction but keeps SERIALIZABLE (not on Azure); the cleanup sets READ COMMITTED back" $ \conn -> do
        azure <- testServerIsAzure
        _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
        endedEarly $ withTransactionLevel Serializable conn $ do
          level conn `shouldReturn` 4
          reset conn
          -- This request carries the reset: the transaction is rolled back,
          -- the level is kept (SQL Server) or back to READ COMMITTED (Azure).
          query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
          level conn `shouldReturn` (if azure then 2 else 4)
        -- Neither REPEATABLE READ, the level before the transaction, nor
        -- SERIALIZABLE, which the reset kept.
        level conn `shouldReturn` 2

  describe "rollback" $
    it "is a no-op when an unread response ended the transaction" $ \conn -> do
      spid <- sessionId conn
      begin conn
      -- The COMMIT's ENVCHANGE is still unread when rollback starts.
      _ <- queryS conn endingBatch :: IO (Stream (Of (Only Int)) IO ())
      awaitCommitted spid
      rollback conn
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)

  describe "withTransaction" $ do
    it "runs the body with the caller's masking state" $ \conn -> do
      withTransaction conn getMaskingState `shouldReturn` Unmasked
      withTransactionLevel ReadCommitted conn getMaskingState `shouldReturn` Unmasked
      mask_ (withTransaction conn getMaskingState) `shouldReturn` MaskedInterruptible
    -- Under MARS the unread response is the caller's to finish: withTransaction
    -- refuses to begin beside it (TransactionRequestsActive, naming it), and
    -- starts once it has been read (its COMMIT's ENVCHANGE with it).
    it "starts when an unread response ended the previous transaction" $ \conn -> do
      spid <- sessionId conn
      begin conn
      s <- queryS conn endingBatch :: IO (Stream (Of (Only Int)) IO ())
      awaitCommitted spid
      when (isMarsConnection conn) $ do
        try (withTransaction conn (pure ())) >>= \case
          Left (TransactionRequestsActive [stmt]) -> stmt `shouldBe` endingBatchText
          other -> expectationFailure ("expected TransactionRequestsActive, got " ++ show other)
        inTransaction conn `shouldReturn` True
        S.toList_ s `shouldReturn` [Only 1]
        inTransaction conn `shouldReturn` False
      withTransaction conn (query1 conn "SELECT @@TRANCOUNT") `shouldReturn` Only (1 :: Int)
      inTransaction conn `shouldReturn` False
