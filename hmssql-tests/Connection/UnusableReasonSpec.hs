{-# LANGUAGE DerivingStrategies #-}

-- | 'unusableReason' and 'renew', against their haddock: every constructor of
-- 'UnusableReason', each produced by what makes it true, against the mock
-- server; what the reason says about a handle as opposed to the connection;
-- and a 'renew' that refuses a connection the server ended while it idled.
module Connection.UnusableReasonSpec (spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Exception
import Control.Monad (forM_, unless, void)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus)
import System.Mem.Weak (deRefWeak)
import qualified Streaming.Prelude as S
import Test.Hspec

import Compat (windowsNetworkTcp)
import Concurrency.Harness (within)
import Concurrency.Mock (batchText, colMetaBigint, rowBigint)
import Hmssql
import Hmssql.Connection (cancelActiveStatement, reset)
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (Done (..))
import Hmssql.Types (ServerMessage (..))
import MockServer
import Protocol.MockTokens (packet, tokenBytes)
import TestConfig (killSession, sessionIdentity, withTestDb)

-- | Thrown by a test: as a synchronous exception to a thread that is reading,
-- to the reader thread, and out of a transaction's body.
data Sabotage = Sabotage
  deriving stock (Eq, Show)

instance Exception Sabotage

isSabotage :: SomeException -> Bool
isSabotage e = fromException e == Just Sabotage

isCancelled :: SomeException -> Bool
isCancelled e = fromException e == Just AsyncCancelled

-- | Log in, then give each message to @answer@ until the client closes the
-- connection.  An answer of no tokens sends nothing.
serving :: (MockConn -> PacketType -> Bool -> Text -> IO [Put]) -> MockConn -> IO ()
serving answer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let loop = recvMessageWithReset mc >>= \case
        Nothing -> pure ()
        Just (ptype, resetting, body) -> do
          toks <- answer mc ptype resetting (batchText body)
          unless (null toks) (sendTokens mc toks)
          loop
  loop

-- | A connection to a mock server that answers with these tokens.
withAnswer :: (MockConn -> PacketType -> Bool -> Text -> IO [Put]) -> (ConnectInfo -> IO a) -> IO a
withAnswer answer act = withMockServer (serving answer) (within 30 . act . mockConnectInfo)

-- | Every batch succeeds, except the ones this says something else for.
answering :: (Bool -> Text -> Maybe [Put]) -> MockConn -> PacketType -> Bool -> Text -> IO [Put]
answering f _ ptype resetting sql = pure $ case ptype of
  PTSqlBatch -> case f resetting sql of
    Just toks -> toks
    Nothing -> [resetConnectionEnvChange | resetting] ++ [beginTransactionEnvChange 1 | "BEGIN TRAN" `T.isPrefixOf` sql] ++ [doneToken 0 0]
  _ -> [doneToken 0 0]

-- | The server closes the connection after the login, or resets it, and
-- waits for the client to close its side.
idleEnd :: (MockConn -> IO ()) -> MockConn -> IO ()
idleEnd end mc = do
  _ <- serveLogin defaultLoginResponse mc
  end mc
  void (recvMessageWithReset mc)

-- | Wait until the reader thread has recorded the end of the connection.
awaitEnded :: Connection -> IO ()
awaitEnded conn = atomically $ readTVar (connEnded conn) >>= check . isJust

-- | Wait until the thread is waiting for the reader thread, which is the
-- only thing it waits for in STM while reading a response.
awaitReading :: Async a -> IO ()
awaitReading a = threadStatus (asyncThreadId a) >>= \case
  ThreadBlocked BlockedOnSTM -> pure ()
  _ -> yield >> threadDelay 1000 >> awaitReading a

unexpected :: Maybe UnusableReason -> Expectation
unexpected r = expectationFailure ("unexpected reason: " ++ show r)

selectOne :: Connection -> IO ()
selectOne conn = void (execute conn "SELECT 1")

refusal :: ServerMessage
refusal = ServerMessage 50000 1 16 "refused" "mock" "" 1

fatal :: ServerMessage
fatal = ServerMessage 50001 1 20 "fatal" "mock" "" 1

setup :: [Text]
setup = ["SET ARITHABORT ON"]

setupBatchText :: Text
setupBatchText = T.intercalate "\n" setup

spec :: Spec
spec = do
  describe "a connection nothing has happened to" $
    it "has no reason" $
      withAnswer (answering (\_ _ -> Nothing)) $ \ci -> withConnection ci $ \conn -> do
        unusableReason conn >>= \case
          Nothing -> pure ()
          r -> unexpected r
        selectOne conn
        unusableReason conn >>= \case
          Nothing -> pure ()
          r -> unexpected r

  describe "every UnusableReason" $ do
    it "Closed ClosedByClient: close" $
      withAnswer (answering (\_ _ -> Nothing)) $ \ci -> do
        conn <- connect ci
        close conn
        unusableReason conn >>= \case
          Just (Closed ClosedByClient) -> pure ()
          r -> unexpected r

    it "Closed ClosedByServer: the server closes an idle connection" $
      withMockServer (idleEnd shutdownSend) $ \srv -> within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
        awaitEnded conn
        unusableReason conn >>= \case
          Just (Closed ClosedByServer) -> pure ()
          r -> unexpected r

    it "Closed TransportFailed: the server resets an idle connection" $
      withMockServer (idleEnd resetConnection) $ \srv -> within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
        awaitEnded conn
        unusableReason conn >>= \case
          Just (Closed (TransportFailed _)) -> pure ()
          -- On Windows with TCP through network's calls, network's receive
          -- reads a reset that arrived before it began as the end of the
          -- stream (design.md, "Windows: GHC's native I/O manager").
          Just (Closed ClosedByServer) | windowsNetworkTcp -> pure ()
          r -> unexpected r

    it "ServerProtocolViolation: a token hmssql doesn't know, and the next request says the same" $
      withAnswer (answering (\_ _ -> Just [Put.putWord8 0x01, doneToken 0 0])) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \(ProtocolError _) -> True
        unusableReason conn >>= \case
          Just (ServerProtocolViolation _) -> pure ()
          r -> unexpected r
        selectOne conn `shouldThrow` \case
          ConnectionBroken (ServerProtocolViolation _) -> True
          _ -> False

    it "FatalServerError: an ERROR token of severity 20, with the socket still open" $
      withAnswer (answering (\_ _ -> Just [errorToken fatal, doneToken 0x0002 0])) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \e -> sqlError e == fatal
        unusableReason conn >>= \case
          Just (FatalServerError msg) -> msg `shouldBe` fatal
          r -> unexpected r
        selectOne conn `shouldThrow` \case
          ConnectionBroken (FatalServerError msg) -> msg == fatal
          _ -> False

    it "ServerFailedConnection: DONE_SRVERROR with no ERROR token, with the socket still open" $
      withAnswer (answering (\_ _ -> Just [doneToken 0x0100 0])) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \e -> severeErrorServerError e
        unusableReason conn >>= \case
          Just (ServerFailedConnection d) -> doneStatus d `shouldBe` 0x0100
          r -> unexpected r
        selectOne conn `shouldThrow` \case
          ConnectionBroken (ServerFailedConnection _) -> True
          _ -> False

    it "SendFailed: an interruption part-way through a message" $ do
     if windowsNetworkTcp
      then pendingWith "on Windows with TCP through network's calls nothing interrupts a send part-way; Concurrency.Send states the consequence"
      else do
      gotFirst <- newEmptyMVar
      finished <- newEmptyMVar
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            -- Take one packet and stop reading, so the client's send blocks.
            _ <- recvPacket mc
            putMVar gotFirst ()
            takeMVar finished
      withMockServer handler $ \srv -> within 30 $ do
        withConnection (mockConnectInfo srv) $ \conn -> do
          void (race (execute conn (rawSql ("SELECT 1 -- " <> T.replicate 8_000_000 "x"))) (takeMVar gotFirst))
          unusableReason conn >>= \case
            Just (SendFailed e) -> e `shouldSatisfy` isCancelled
            other -> unexpected other
        putMVar finished ()

    it "ReadFailed: a synchronous exception thrown to the thread reading a response" $ do
      got <- newEmptyMVar
      let answer _ ptype _ _ = [] <$ (if ptype == PTSqlBatch then putMVar got () else pure ())
      withAnswer answer $ \ci -> withConnection ci $ \conn -> do
        a <- async (selectOne conn)
        takeMVar got
        awaitReading a
        throwTo (asyncThreadId a) Sabotage
        r <- waitCatch a
        either isSabotage (const False) r `shouldBe` True
        unusableReason conn >>= \case
          Just (ReadFailed e) -> e `shouldSatisfy` isSabotage
          other -> unexpected other

    it "DrainFailed: an interruption while draining a cancelled response" $ do
      attention <- newEmptyMVar
      let answer mc ptype _ _ = case ptype of
            PTSqlBatch -> [] <$ sendRaw mc (packet False (tokenBytes [colMetaBigint "n", rowBigint 1]))
            PTAttention -> [] <$ putMVar attention ()
            _ -> pure []
      withAnswer answer $ \ci -> withConnection ci $ \conn -> do
        rows <- queryS conn "SELECT n"
        S.next rows >>= \case
          Right (Only (1 :: Int64), _) -> pure ()
          _ -> expectationFailure "expected the first row"
        void (race (cancelActiveStatement conn) (takeMVar attention))
        unusableReason conn >>= \case
          Just (DrainFailed e) -> e `shouldSatisfy` isCancelled
          other -> unexpected other

    describe "ResetRefused" $ do
      let refusedAnswers =
            [ ("an ERROR token", [errorToken refusal, doneToken 0x0002 0], Just refusal)
            , ("a failed DONE with no ERROR token", [doneToken 0x0002 0], Nothing)
            ]
      forM_ refusedAnswers $ \(what, toks, expected) -> do
        it ("the setup batch carrying a reset, refused by " ++ what) $
          withAnswer (answering (\resetting _ -> if resetting then Just toks else Nothing)) $ \ci ->
            withConnection ci { connectSessionSetup = setup } $ \conn -> do
              reset conn
              try @SomeException (selectOne conn) >>= (`shouldSatisfy` either (const True) (const False))
              unusableReason conn >>= \case
                Just (ResetRefused msg) -> msg `shouldBe` expected
                r -> unexpected r

        it ("release's SELECT 1 carrying a reset, refused by " ++ what) $
          withAnswer (answering (\resetting _ -> if resetting then Just toks else Nothing)) $ \ci ->
            withConnection ci $ \conn -> do
              _ <- execute conn "BEGIN TRAN"
              release conn `shouldReturn` False
              unusableReason conn >>= \case
                Just (ResetRefused msg) -> msg `shouldBe` expected
                r -> unexpected r

    it "ResetFailed: an interruption while reading the setup batch that carries a reset" $ do
      got <- newEmptyMVar
      let answer _ ptype resetting sql
            | ptype == PTSqlBatch && resetting && sql == setupBatchText = [] <$ putMVar got ()
            | otherwise = pure [doneToken 0 0]
      withAnswer answer $ \ci -> withConnection ci { connectSessionSetup = setup } $ \conn -> do
        reset conn
        void (race (selectOne conn) (takeMVar got))
        unusableReason conn >>= \case
          Just (ResetFailed e) -> e `shouldSatisfy` isCancelled
          r -> unexpected r

    it "RollbackFailed: the server refuses the rollback after the body failed" $ do
      let answer _ ptype _ sql = pure $ case ptype of
            PTTransactionManager -> [beginTransactionEnvChange 1, doneToken 0 0]
            PTSqlBatch | "IF @@TRANCOUNT" `T.isPrefixOf` sql -> [errorToken refusal, doneToken 0x0002 0]
            _ -> [doneToken 0 0]
      withAnswer answer $ \ci -> withConnection ci $ \conn -> do
        withTransaction conn (throwIO Sabotage) `shouldThrow` (== Sabotage)
        unusableReason conn >>= \case
          Just (RollbackFailed e) -> fmap sqlError (fromException e) `shouldBe` Just refusal
          r -> unexpected r

    it "ReaderThreadDied: the reader thread gets an exception it doesn't expect" $
      withAnswer (answering (\_ _ -> Nothing)) $ \ci -> withConnection ci $ \conn -> do
        Just weak <- readIORef (connReader conn)
        Just tid <- deRefWeak weak
        throwTo tid Sabotage
        awaitEnded conn
        unusableReason conn >>= \case
          Just (ReaderThreadDied e) -> e `shouldSatisfy` isSabotage
          r -> unexpected r
        selectOne conn `shouldThrow` \case
          ConnectionBroken (ReaderThreadDied _) -> True
          _ -> False

  describe "what is not a reason" $ do
    it "DONE_ERROR alone leaves no reason, and the connection answers the next request" $
      withAnswer (answering (\_ sql -> if sql == "SELECT 1" then Just [doneToken 0x0002 0] else Nothing)) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \e -> not (severeErrorServerError e)
        unusableReason conn >>= \case
          Nothing -> pure ()
          r -> unexpected r
        void (execute conn "SELECT 2")

    it "a nonfatal server error leaves no reason" $
      withAnswer (answering (\_ sql -> if sql == "SELECT 1" then Just [errorToken refusal, doneToken 0x0002 0] else Nothing)) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \e -> sqlError e == refusal
        unusableReason conn >>= \case
          Nothing -> pure ()
          r -> unexpected r

  describe "the connection, not the handle" $ do
    it "a released handle to a healthy connection has no reason, though a request through it throws ConnectionReleased" $
      withAnswer (answering (\_ _ -> Nothing)) $ \ci -> withConnection ci $ \conn -> do
        release conn `shouldReturn` True
        unusableReason conn >>= \case
          Nothing -> pure ()
          r -> unexpected r
        selectOne conn `shouldThrow` \ConnectionReleased -> True

    it "a released handle reports a connection that ended later" $ do
      closeNow <- newEmptyMVar
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            takeMVar closeNow
            shutdownSend mc
            void (recvMessageWithReset mc)
      withMockServer handler $ \srv -> within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
        release conn `shouldReturn` True
        putMVar closeNow ()
        awaitEnded conn
        unusableReason conn >>= \case
          Just (Closed ClosedByServer) -> pure ()
          r -> unexpected r

    it "close is reported over the failure that came before it" $
      withAnswer (answering (\_ _ -> Just [errorToken fatal, doneToken 0x0002 0])) $ \ci -> do
        conn <- connect ci
        selectOne conn `shouldThrow` \e -> sqlError e == fatal
        close conn
        unusableReason conn >>= \case
          Just (Closed ClosedByClient) -> pure ()
          r -> unexpected r

  describe "renew" $ do
    it "refuses a connection the server closed while it idled, leaves the old handle current, and then says ConnectionBroken" $
      withMockServer (idleEnd shutdownSend) $ \srv -> within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
        awaitEnded conn
        renew conn `shouldThrow` \case
          ConnectionClosedBy ClosedByServer -> True
          _ -> False
        renew conn `shouldThrow` \case
          ConnectionBroken (Closed ClosedByServer) -> True
          _ -> False
        -- The old handle is still current: release answers instead of
        -- throwing ConnectionReleased.
        release conn `shouldReturn` False

    it "refuses a connection the server reset while it idled" $
      withMockServer (idleEnd resetConnection) $ \srv -> within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
        awaitEnded conn
        renew conn `shouldThrow` \case
          ConnectionClosedBy (TransportFailed _) -> True
          -- As in "Closed TransportFailed" above.
          ConnectionClosedBy ClosedByServer -> windowsNetworkTcp
          _ -> False

    it "refuses a connection broken by a fatal error, through a released handle too" $
      withAnswer (answering (\_ _ -> Just [errorToken fatal, doneToken 0x0002 0])) $ \ci -> withConnection ci $ \conn -> do
        selectOne conn `shouldThrow` \e -> sqlError e == fatal
        release conn `shouldReturn` False
        renew conn `shouldThrow` \case
          ConnectionBroken (FatalServerError _) -> True
          _ -> False

    it "refuses a closed connection" $
      withAnswer (answering (\_ _ -> Nothing)) $ \ci -> do
        conn <- connect ci
        close conn
        renew conn `shouldThrow` \case
          ConnectionClosedBy ClosedByClient -> True
          _ -> False

    it "sends nothing: the mock sees no packet between the login and the first request" $ do
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            let loop acc = recvMessageWithReset mc >>= \case
                  Just (PTSqlBatch, _, body) -> sendTokens mc [doneToken 0 0] >> loop (batchText body : acc)
                  Just (_, _, _) -> loop acc
                  Nothing -> pure (reverse acc)
            loop []
      withMockServer handler $ \srv -> do
        within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
          conn' <- renew conn
          void (execute conn' "SELECT 1")
        nextResult srv >>= \case
          Right batches -> batches `shouldBe` (["SELECT 1"] :: [Text])
          Left e -> expectationFailure ("mock: " ++ show e)

    -- The loop of the recipe in "Hmssql.Connection#g:pools", over a list in
    -- place of a pool.
    it "lets a borrow destroy a dead connection and take the next" $
      withMockServer (idleEnd shutdownSend) $ \dead -> withAnswer (answering (\_ _ -> Nothing)) $ \ci -> do
        conn1 <- connect (mockConnectInfo dead)
        conn2 <- connect ci
        awaitEnded conn1
        pool <- newIORef [conn1, conn2]
        destroyed <- newIORef (0 :: Int)
        let borrow = do
              conn0 <- atomicModifyIORef' pool (\cs -> (drop 1 cs, cs !! 0))
              try (renew conn0) >>= \case
                Right conn -> pure conn
                Left (e :: SomeException)
                  | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                  | otherwise -> close conn0 >> modifyIORef' destroyed (+ 1) >> borrow
        conn <- borrow
        selectOne conn
        readIORef destroyed `shouldReturn` 1
        close conn

  describe "live server" $ around withTestDb $
    it "renew refuses a session killed while it idled, and the next connection works" $ \conn -> within 30 $ do
      victim <- sessionIdentity conn
      killSession victim
      awaitEnded conn
      unusableReason conn >>= \case
        Just (Closed _) -> pure ()
        r -> unexpected r
      renew conn `shouldThrow` \case
        ConnectionClosedBy reason -> case reason of
          ClosedByClient -> False
          _ -> True
      withTestDb $ \next -> query1 next "SELECT 1" `shouldReturn` Only (1 :: Int)
