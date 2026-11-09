{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Session reset: @sp_reset_connection@ and the RESETCONNECTION status bit
-- ('reset'), and the session setup that 'connect' applies.
--
-- 'defaultSessionSetup' is empty, so what a reset restores is compared
-- with an explicit setup: 'reSetup' (which 'reset' re-runs, in a batch of
-- its own before the next request, and @sp_reset_connection@ does not) and
-- @[]@ (the RESETCONNECTION bit rides on the next request: no extra round
-- trip).  RESETCONNECTION keeps the isolation level on SQL Server, and puts
-- READ COMMITTED back on Azure SQL Database ('keptLevel');
-- @sp_reset_connection@ resets it on both.
--
-- On Azure SQL Database there is no @USE@ ('messUpSql' leaves it out), and
-- the gateway sets CONTEXT_INFO to a tracing GUID at login, so 'getProps'
-- reads it there as \"the value a test set, or nothing\".
module ResetSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent (forkIO, isEmptyMVar, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (forConcurrently)
import Control.Exception
import Control.Monad (forM_, mfilter, replicateM_, void)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Bits ((.&.), (.|.))
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Functor ((<&>))
import Data.Int (Int64)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import qualified Streaming.Prelude as S
import System.Timeout (Timeout, timeout)
import Test.Hspec

import Concurrency.Mock (batchText)
import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Errors
import Hmssql.Connection
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer
import OpenResponses (isMarsConnection)
import TestDb

-- | Everything a reset is expected to restore, read in one query.
data Props = Props
  { propOptions :: !Int
  , propTextSize :: !Int
  , propLanguage :: !Text
  , propDateFormat :: !Text
  , propDateFirst :: !Int
  , propIsolation :: !Int
  , propLockTimeout :: !Int
  , propDeadlockPriority :: !Int
  , propDatabase :: !Text
  , propTranCount :: !Int
  , propContextInfo :: !(Maybe B.ByteString)
  , propSessionContext :: !(Maybe Text)
  , propTempTable :: !(Maybe Int)
  , propCursor :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

getProps :: Connection -> IO Props
getProps conn = do
  -- Under IMPLICIT_TRANSACTIONS ('messUp' turns it on) the SELECT starts a
  -- transaction.  On a MARS connection a batch may not leave a transaction
  -- it started open (error 3997, and the server rolls it back), so there
  -- the batch commits it; without MARS it stays open, as it always has.
  let sql = "SELECT @@OPTIONS, @@TEXTSIZE, @@LANGUAGE, s.date_format, s.date_first, \
            \  s.transaction_isolation_level, s.lock_timeout, s.deadlock_priority, \
            \  DB_NAME(), @@TRANCOUNT, CONTEXT_INFO(), \
            \  CONVERT(nvarchar(100), SESSION_CONTEXT(N'hmssql_reset')), \
            \  OBJECT_ID('tempdb..#hmssql_reset'), CURSOR_STATUS('global', 'hmssql_reset_cursor') \
            \FROM sys.dm_exec_sessions s WHERE s.session_id = @@SPID"
  p <- query1 conn $ rawSql $ if isMarsConnection conn
    then "DECLARE @hmssql_trancount int = @@TRANCOUNT; " <> sql <> "; IF @@TRANCOUNT > @hmssql_trancount COMMIT"
    else sql
  azure <- testServerIsAzure
  -- Azure's gateway gives every session a tracing GUID in CONTEXT_INFO at
  -- login (and a reset leaves it NULL): there, only a value a test set
  -- counts, and anything else reads as cleared.
  pure $ if azure
    then p { propContextInfo = mfilter ((`elem` testContextInfos) . B.take 2) (propContextInfo p) }
    else p

-- | The first two bytes of every CONTEXT_INFO the tests here set.
testContextInfos :: [B.ByteString]
testContextInfos = ["\x12\x34", "\x01\x02", "\x43\x21"]

-- | Change everything 'Props' covers.  The isolation level it sets is
-- 'messUpIsolation'.  Ends with @USE tempdb@, except on Azure SQL Database
-- (no USE there, error 40508).
messUpSql :: IO Query
messUpSql = testServerIsAzure <&> \azure -> rawSql (messUp <> (if azure then "" else "; USE tempdb"))

messUp :: Text
messUp =
  "SET TEXTSIZE 12345; SET ANSI_NULLS OFF; SET QUOTED_IDENTIFIER OFF; SET ANSI_PADDING OFF; \
  \SET ANSI_WARNINGS OFF; SET CONCAT_NULL_YIELDS_NULL OFF; SET ARITHABORT OFF; \
  \SET NUMERIC_ROUNDABORT ON; SET CURSOR_CLOSE_ON_COMMIT ON; SET NOCOUNT ON; SET XACT_ABORT ON; \
  \SET ANSI_NULL_DFLT_ON OFF; SET LANGUAGE Deutsch; SET DATEFORMAT ydm; SET DATEFIRST 3; \
  \SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; SET LOCK_TIMEOUT 1234; SET DEADLOCK_PRIORITY LOW; \
  \SET CONTEXT_INFO 0x1234; EXEC sp_set_session_context N'hmssql_reset', N'v'; \
  \CREATE TABLE #hmssql_reset (i int); \
  \DECLARE hmssql_reset_cursor CURSOR GLOBAL FOR SELECT 1; OPEN hmssql_reset_cursor; \
  \SET IMPLICIT_TRANSACTIONS ON"

-- | @sys.dm_exec_sessions.transaction_isolation_level@ values.
readCommitted, serializable :: Int
readCommitted = 2
serializable = 4

-- | The isolation level 'messUp' sets (SERIALIZABLE).
messUpIsolation :: Int
messUpIsolation = serializable

-- | The isolation level after a RESETCONNECTION (a 'reset' whose setup
-- doesn't set one) that found the given level: SQL Server keeps it, Azure
-- SQL Database puts READ COMMITTED back.
keptLevel :: Int -> IO Int
keptLevel level = testServerIsAzure <&> \azure -> if azure then readCommitted else level

-- @@OPTIONS bits
optImplicitTransactions, optCursorCloseOnCommit, optAnsiWarnings, optAnsiPadding, optAnsiNulls,
  optArithAbort, optQuotedIdentifier, optNoCount, optAnsiNullDfltOn, optConcatNullYieldsNull,
  optNumericRoundAbort, optXactAbort :: Int
optImplicitTransactions = 2
optCursorCloseOnCommit = 4
optAnsiWarnings = 8
optAnsiPadding = 16
optAnsiNulls = 32
optArithAbort = 64
optQuotedIdentifier = 256
optNoCount = 512
optAnsiNullDfltOn = 1024
optConcatNullYieldsNull = 4096
optNumericRoundAbort = 8192
optXactAbort = 16384

hasOpt :: Props -> Int -> Bool
hasOpt p bit = propOptions p .&. bit /= 0

-- | A session setup whose effects differ from the login state (ARITHABORT
-- is off at login, the lock timeout -1), so a test can tell whether a
-- reset re-ran it: 'reset' does, @sp_reset_connection@ doesn't.  Two
-- statements, so the reset's setup batch is a joined one, as 'connect's is.
reSetup :: [Text]
reSetup = ["SET ARITHABORT ON", "SET LOCK_TIMEOUT 4321"]

-- | The two kinds of session setup whose resets differ: 'reSetup' (one
-- setup batch precedes the next request) and none (the next request
-- carries the RESETCONNECTION bit itself).
setups :: [(String, [Text])]
setups = [("with a session setup", reSetup), ("without a session setup", [])]

data Method = SpResetConnection | ResetFlag
  deriving stock (Eq, Show)

-- | Reset, then make a request so the flag takes effect.
doReset :: Method -> Connection -> IO ()
doReset m conn = do
  case m of
    SpResetConnection -> void (callProcedure conn "sp_reset_connection" [])
    ResetFlag -> reset conn
  Only (_ :: Int) <- query1 conn "SELECT 1"
  pure ()

-- | A connection with the given session setup (whatever
-- @HMSSQL_TEST_SESSION_SETUP@ says).
withSetup :: [Text] -> (Connection -> IO a) -> IO a
withSetup setup = withTestDbWith (\ci -> ci { connectSessionSetup = setup })

connectInfoWith :: [Text] -> IO ConnectInfo
connectInfoWith setup = do
  ci <- defaultTestConnectInfo
  pure ci { connectSessionSetup = setup }

-- | The properties of a fresh connection with this session setup.
freshProps :: [Text] -> IO Props
freshProps setup = do
  ci <- connectInfoWith setup
  withConnection ci getProps

-- | What each method should leave on a connection with 'reSetup' whose
-- isolation level was the given one: @sp_reset_connection@ returns to the
-- state right after login (READ COMMITTED, and the session setup is not
-- re-run); 'reset' also re-runs the session setup, and keeps the isolation
-- level ('keptLevel').
expectedAfter :: Method -> Int -> IO Props
expectedAfter m levelBefore = case m of
  SpResetConnection -> freshProps []
  ResetFlag -> do
    kept <- keptLevel levelBefore
    (\p -> p { propIsolation = kept }) <$> freshProps reSetup

-- | A real table (so its contents survive a reset) with a unique name.
withTable :: (Text -> IO a) -> IO a
withTable act = do
  name <- ("dbo." <>) <$> uniqueName "reset"
  withTestDb $ \c -> void $ execute c (rawSql ("CREATE TABLE " <> name <> " (id int PRIMARY KEY, v int)"))
  act name `finally` withTestDb (\c -> void $ execute c (rawSql ("DROP TABLE IF EXISTS " <> name)))

count :: Connection -> Text -> IO Int
count conn table = fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table))

-- | Packets read by the server on a session, seen from another connection.
-- A MARS connection has a row for the physical connection (which counts
-- the packets before the SMP sessions started) and one for each SMP session
-- (which counts that session's), all with the same @session_id@: the sum
-- counts every packet, in both modes.
serverReads :: Connection -> Int -> IO Int64
serverReads monitor spid = fromOnly <$> query1 monitor
  (mkQuery "SELECT CAST(SUM(num_reads) AS bigint) FROM sys.dm_exec_connections WHERE session_id = @p1" (Only spid))

expectSqlError :: Int -> IO a -> IO ()
expectSqlError number act = try act >>= \case
  Left e -> fromIntegral (sqlErrorNumber e) `shouldBe` number
  Right _ -> expectationFailure ("expected SQL Server error " ++ show number)

-- | The exception is 'ConnectionBroken' whose cause is a 'Timeout'.
isBrokenByTimeout :: SomeException -> Bool
isBrokenByTimeout e = case fromException e of
  Just (ConnectionBroken (reasonCause -> cause)) -> isJust (fromException cause :: Maybe Timeout)
  Nothing -> False

------------------------------------------------------------------------------
-- Mock server

-- | The next message, with its type, whether its first packet carries the
-- RESETCONNECTION bit, and the whole body; Nothing once the client closed
-- the connection.
recvWithReset :: MockConn -> IO (Maybe (PacketType, Bool, B.ByteString))
recvWithReset mc = recvPacket mc >>= \case
  Nothing -> pure Nothing
  Just (hdr, body) -> do
    let resetBit = headerStatus hdr .&. statusResetConnection /= PacketStatus 0
        go acc h
          | headerStatus h .&. statusEndOfMessage /= PacketStatus 0 = pure (B.concat (reverse acc))
          | otherwise = recvPacket mc >>= \case
              Nothing -> throwIO (MockUnexpected "client closed mid-message")
              Just (h', b) -> go (b : acc) h'
    whole <- go [body] hdr
    pure (Just (headerType hdr, resetBit, whole))

-- | Log in, then answer every SQL batch with a bare DONE until the client
-- closes the connection; returns each batch's text and whether it carried
-- the RESETCONNECTION bit.
recordingServer :: MockConn -> IO [(Text, Bool)]
recordingServer mc = do
  _ <- serveLogin defaultLoginResponse mc
  let loop acc = recvWithReset mc >>= \case
        Nothing -> pure (reverse acc)
        Just (PTSqlBatch, resetBit, body) -> do
          sendTokens mc [doneToken 0 0]
          loop ((batchText body, resetBit) : acc)
        Just (ptype, _, _) -> throwIO (MockUnexpected ("expected a SQL batch, got " ++ show ptype))
  loop []

-- | Log in and answer the setup batch at connect; then take the setup batch
-- after the reset and never answer it.  Returns that batch (text and
-- RESETCONNECTION bit) and the types of the messages the client sent after
-- it, until it closed the connection.
stallingSetupServer :: MockConn -> IO ((Text, Bool), [PacketType])
stallingSetupServer mc = do
  _ <- serveLogin defaultLoginResponse mc
  _ <- recvWithReset mc
  sendTokens mc [doneToken 0 0]
  recvWithReset mc >>= \case
    Just (PTSqlBatch, resetBit, body) -> do
      let rest acc = recvWithReset mc >>= \case
            Nothing -> pure (reverse acc)
            Just (ptype, _, _) -> rest (ptype : acc)
      after <- rest []
      pure ((batchText body, resetBit), after)
    other -> throwIO (MockUnexpected ("expected the setup batch, got " ++ show (fmap (\(t, _, _) -> t) other)))

spec :: Spec
spec = do
  describe "session setup" $ do
    it "is empty by default: the login (fODBC) gives the ANSI options, ARITHABORT stays off, TEXTSIZE is -1" $ do
      defaultSessionSetup `shouldBe` []
      p <- freshProps defaultSessionSetup
      propTextSize p `shouldBe` (-1)
      map (hasOpt p)
        [ optAnsiNulls, optQuotedIdentifier, optAnsiPadding, optAnsiWarnings
        , optConcatNullYieldsNull, optAnsiNullDfltOn ]
        `shouldBe` replicate 6 True
      map (hasOpt p) [optArithAbort, optNumericRoundAbort, optImplicitTransactions, optCursorCloseOnCommit]
        `shouldBe` replicate 4 False
      (propTranCount p, propIsolation p, propLanguage p, propDateFormat p) `shouldBe` (0, readCommitted, "us_english", "mdy")
      -- The documented opt-in changes ARITHABORT and nothing else.
      p' <- freshProps ["SET ARITHABORT ON"]
      p' `shouldBe` p { propOptions = propOptions p .|. optArithAbort }

    it "without a session setup, login (fODBC) already sets the ANSI options" $ do
      p <- freshProps []
      -- TEXTSIZE -1 is unlimited: nothing is truncated.
      propTextSize p `shouldBe` (-1)
      map (hasOpt p)
        [ optAnsiNulls, optQuotedIdentifier, optAnsiPadding, optAnsiWarnings
        , optConcatNullYieldsNull, optAnsiNullDfltOn ]
        `shouldBe` replicate 6 True
      map (hasOpt p) [optArithAbort, optNumericRoundAbort, optImplicitTransactions, optCursorCloseOnCommit]
        `shouldBe` replicate 4 False
      ci <- connectInfoWith []
      withConnection ci $ \c -> do
        (a :: Text, b :: B.ByteString) <- query1 c
          "SELECT REPLICATE(CONVERT(nvarchar(max), N'x'), 100000), \
          \CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'y'), 100000))"
        (T.length a, B.length b) `shouldBe` (100000, 100000)

    it "runs a multi-statement setup as one batch, at connect and after a reset" $ do
      -- The second statement uses a variable the first declares, which
      -- works only if both are in one batch.
      ci <- connectInfoWith ["DECLARE @ctx varbinary(128) = 0x4321", "SET CONTEXT_INFO @ctx"]
      withConnection ci $ \conn -> do
        let contextInfo = fmap (B.take 2) . propContextInfo <$> getProps conn
        contextInfo `shouldReturn` Just "\x43\x21"
        _ <- execute conn "SET CONTEXT_INFO 0x0102"
        contextInfo `shouldReturn` Just "\1\2"
        -- The reset clears CONTEXT_INFO; the setup, run again, sets it.
        reset conn
        contextInfo `shouldReturn` Just "\x43\x21"

    describe "on the wire (mock server)" $ do
      it "is sent as one batch at connect, and again with the RESETCONNECTION bit before the request after a reset" $
        withMockServer recordingServer $ \srv -> do
          withConnection (mockConnectInfo srv) { connectSessionSetup = reSetup } $ \conn -> do
            _ <- execute conn "SELECT 1"
            reset conn
            reset conn
            _ <- execute conn "SELECT 2"
            void $ execute conn "SELECT 3"
          let setupSql = "SET ARITHABORT ON\nSET LOCK_TIMEOUT 4321"
          nextResult srv >>= \case
            Left e -> expectationFailure ("mock: " ++ show e)
            Right batches -> batches `shouldBe`
              [ (setupSql, False), ("SELECT 1", False)
              , (setupSql, True), ("SELECT 2", False)
              , ("SELECT 3", False) ]

      it "without a session setup, the request after a reset carries the RESETCONNECTION bit itself" $
        withMockServer recordingServer $ \srv -> do
          withConnection (mockConnectInfo srv) { connectSessionSetup = [] } $ \conn -> do
            _ <- execute conn "SELECT 1"
            reset conn
            _ <- execute conn "SELECT 2"
            void $ execute conn "SELECT 3"
          nextResult srv >>= \case
            Left e -> expectationFailure ("mock: " ++ show e)
            Right batches -> batches `shouldBe` [("SELECT 1", False), ("SELECT 2", True), ("SELECT 3", False)]

      it "breaks the connection when reading the setup batch after a reset is interrupted (ConnectionBroken wrapping the interruption)" $
        withMockServer stallingSetupServer $ \srv -> do
          withConnection (mockConnectInfo srv) { connectSessionSetup = reSetup } $ \conn -> do
            reset conn
            timeout 300_000 (execute conn "SELECT 1") `shouldReturn` Nothing
            r <- try (execute conn "SELECT 2")
            case r of
              Left e | isBrokenByTimeout e -> pure ()
              other -> expectationFailure ("expected ConnectionBroken (timeout), got " ++ show other)
          nextResult srv >>= \case
            Left e -> expectationFailure ("mock: " ++ show e)
            -- The request itself was never sent: only the Attention that
            -- the interrupted read sends.
            Right (setupBatch, after) -> do
              setupBatch `shouldBe` ("SET ARITHABORT ON\nSET LOCK_TIMEOUT 4321", True)
              after `shouldBe` [PTAttention]

  -- Both methods on a connection with 'reSetup': sp_reset_connection
  -- returns to the login state; reset re-runs the setup and keeps the
  -- isolation level.
  forM_ [SpResetConnection, ResetFlag] $ \m -> describe (show m) $ around (withSetup reSetup) $ do
    let restoresName = case m of
          SpResetConnection -> "restores the login state (not re-running the session setup)"
          ResetFlag -> "restores the login state and re-runs the session setup"
    it restoresName $ \conn -> do
      expected <- expectedAfter m messUpIsolation
      messUpSql >>= void . execute conn
      changed <- getProps conn
      changed `shouldNotBe` expected
      propTempTable changed `shouldNotBe` Nothing
      map (hasOpt changed) [optNoCount, optXactAbort] `shouldBe` [True, True]
      doReset m conn
      p <- getProps conn
      p `shouldBe` expected
      map (hasOpt p) [optNoCount, optXactAbort] `shouldBe` [False, False]
      kept <- keptLevel serializable
      propIsolation p `shouldBe` (if m == ResetFlag then kept else readCommitted)
      inTransaction conn `shouldReturn` False

    it "restores the session state when reset inside BEGIN TRAN" $ \conn -> do
      expected <- expectedAfter m readCommitted
      begin conn
      _ <- execute conn "SET TEXTSIZE 12345; SET ANSI_NULLS OFF; SET QUOTED_IDENTIFIER OFF; \
                         \CREATE TABLE #hmssql_reset (i int)"
      inTransaction conn `shouldReturn` True
      doReset m conn
      getProps conn `shouldReturn` expected
      inTransaction conn `shouldReturn` False

    it (case m of
          SpResetConnection -> "does not re-run the session setup"
          ResetFlag -> "re-runs the session setup") $ \conn -> do
      _ <- execute conn "SET ARITHABORT OFF; SET LOCK_TIMEOUT 1"
      doReset m conn
      p <- getProps conn
      (hasOpt p optArithAbort, propLockTimeout p) `shouldBe` case m of
        SpResetConnection -> (False, -1)
        ResetFlag -> (True, 4321)

    it "keeps the fODBC ANSI options on even if they were turned off" $ \conn -> do
      _ <- execute conn "SET ANSI_NULLS OFF; SET QUOTED_IDENTIFIER OFF; SET ANSI_PADDING OFF; \
                         \SET ANSI_WARNINGS OFF; SET CONCAT_NULL_YIELDS_NULL OFF"
      doReset m conn
      p <- getProps conn
      map (hasOpt p)
        [ optAnsiNulls, optQuotedIdentifier, optAnsiPadding, optAnsiWarnings, optConcatNullYieldsNull ]
        `shouldBe` replicate 5 True
      -- TEXTSIZE is the login's; ARITHABORT comes from the session setup,
      -- which only reset re-runs.
      (hasOpt p optArithAbort, propTextSize p) `shouldBe` (m == ResetFlag, -1)

    it "rolls back an open transaction" $ \conn -> withTable $ \t -> do
      begin conn
      _ <- execute conn (rawSql ("INSERT INTO " <> t <> " VALUES (1, 1)"))
      inTransaction conn `shouldReturn` True
      count conn t `shouldReturn` 1
      doReset m conn
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
      count conn t `shouldReturn` 0
      withTestDb $ \other -> count other t `shouldReturn` 0
      -- The bookkeeping is consistent: a new transaction works.
      withTransaction conn $ void $ execute conn (rawSql ("INSERT INTO " <> t <> " VALUES (2, 2)"))
      inTransaction conn `shouldReturn` False
      withTestDb $ \other -> count other t `shouldReturn` 1
      begin conn
      inTransaction conn `shouldReturn` True
      rollback conn
      inTransaction conn `shouldReturn` False

    it "releases locks" $ \conn -> withTable $ \t -> do
      resource <- uniqueName "reset_lock"
      _ <- execute conn (rawSql ("INSERT INTO " <> t <> " VALUES (1, 1)"))
      Only (r :: Int) <- query1 conn $ mkQuery
        "DECLARE @r int; EXEC @r = sp_getapplock @Resource = @p1, @LockMode = 'Exclusive', \
        \@LockOwner = 'Session', @LockTimeout = 0; SELECT @r" (Only resource)
      r `shouldSatisfy` (>= 0)
      begin conn
      _ <- execute conn (rawSql ("UPDATE " <> t <> " SET v = 2 WHERE id = 1"))
      let tryLocks other = do
            Only (applock :: Int) <- query1 other $ mkQuery
              "DECLARE @r int; EXEC @r = sp_getapplock @Resource = @p1, @LockMode = 'Exclusive', \
              \@LockOwner = 'Session', @LockTimeout = 0; \
              \IF @r >= 0 EXEC sp_releaseapplock @Resource = @p1, @LockOwner = 'Session'; SELECT @r"
              (Only resource)
            row <- try (query1 other (rawSql ("SET LOCK_TIMEOUT 0; SELECT v FROM " <> t <> " WITH (READCOMMITTEDLOCK) WHERE id = 1")))
            pure (applock >= 0, either (\(_ :: SqlServerError) -> Nothing) (\(Only v) -> Just (v :: Int)) row)
      withTestDb $ \other -> do
        tryLocks other `shouldReturn` (False, Nothing)
        doReset m conn
        tryLocks other `shouldReturn` (True, Just 1)

    it "drops #temp tables and closes cursors" $ \conn -> do
      _ <- execute conn "CREATE TABLE #hmssql_reset (i int); INSERT INTO #hmssql_reset VALUES (1); \
                         \DECLARE hmssql_reset_cursor CURSOR GLOBAL FOR SELECT i FROM #hmssql_reset; \
                         \OPEN hmssql_reset_cursor"
      p <- getProps conn
      (propTempTable p /= Nothing, propCursor p) `shouldBe` (True, 1)
      doReset m conn
      p' <- getProps conn
      (propTempTable p', propCursor p') `shouldBe` (Nothing, -3)
      -- The names can be used again.
      _ <- execute conn "CREATE TABLE #hmssql_reset (i int); \
                         \DECLARE hmssql_reset_cursor CURSOR GLOBAL FOR SELECT 1; \
                         \DEALLOCATE hmssql_reset_cursor"
      pure ()

    it "clears CONTEXT_INFO and SESSION_CONTEXT" $ \conn -> do
      _ <- execute conn "SET CONTEXT_INFO 0x0102; EXEC sp_set_session_context N'hmssql_reset', N'v'"
      p <- getProps conn
      (fmap (B.take 2) (propContextInfo p), propSessionContext p) `shouldBe` (Just "\1\2", Just "v")
      doReset m conn
      p' <- getProps conn
      (propContextInfo p', propSessionContext p') `shouldBe` (Nothing, Nothing)

    skipOnAzure "no USE (error 40508)" $ it "reverts the database after USE" $ \conn -> do
      db <- testDatabaseName
      _ <- execute conn "USE tempdb"
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only ("tempdb" :: Text)
      doReset m conn
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only db

    it (case m of
          SpResetConnection -> "reverts the isolation level"
          ResetFlag -> "keeps the isolation level (RESETCONNECTION keeps it; Azure SQL Database reverts it)") $ \conn -> do
      _ <- execute conn "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
      propIsolation <$> getProps conn `shouldReturn` serializable
      doReset m conn
      kept <- keptLevel serializable
      propIsolation <$> getProps conn `shouldReturn` case m of
        SpResetConnection -> readCommitted
        ResetFlag -> kept

    it (case m of
          SpResetConnection -> "when nothing happened, still undoes the session setup"
          ResetFlag -> "is harmless when nothing happened") $ \conn -> do
      expected <- expectedAfter m readCommitted
      doReset m conn
      getProps conn `shouldReturn` expected

    it "can be repeated" $ \conn -> do
      expected <- expectedAfter m readCommitted
      doReset m conn
      doReset m conn
      getProps conn `shouldReturn` expected
      messUpSql >>= void . execute conn
      doReset m conn
      kept <- keptLevel messUpIsolation
      getProps conn `shouldReturn` expected
        { propIsolation = if m == ResetFlag then kept else readCommitted }

  describe "reset" $ do
    forM_ setups $ \(label, setup) -> describe label $ around (withSetup setup) $ do
      it "resets once, however often it is called" $ \conn -> do
        reset conn
        reset conn
        _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
        -- The reset was consumed by the CREATE; the table survives.
        propTempTable <$> getProps conn `shouldNotReturn` Nothing

      it "happens even if the request after it fails" $ \conn -> do
        expected <- freshProps setup
        messUpSql >>= void . execute conn
        reset conn
        expectSqlError 50000 $ execute conn "THROW 50000, N'after reset', 1"
        kept <- keptLevel messUpIsolation
        getProps conn `shouldReturn` expected { propIsolation = kept }

      it "is left pending by a request that fails before sending" $ \conn -> do
        _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
        reset conn
        -- More than 38 digits: rejected while encoding the parameters.
        r <- try (execute conn ("SELECT " <> param (Decimal 0 (10 ^ (40 :: Int)) :: Decimal)))
        case r of
          Left (EncodeError _) -> pure ()
          Right _ -> expectationFailure "no EncodeError"
        propTempTable <$> getProps conn `shouldReturn` Nothing

      it "applies to a streaming query" $ \conn -> do
        _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
        reset conn
        s <- queryS conn "SELECT TOP 50000 OBJECT_ID('tempdb..#hmssql_reset') FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        rows <- S.toList_ s
        (length rows, all (== Only (Nothing :: Maybe Int)) rows) `shouldBe` (50000, True)

      it "waits for a stream that is being read, then applies to the next request" $ \conn -> do
        _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
        s <- queryS conn "SELECT TOP 300000 OBJECT_ID('tempdb..#hmssql_reset') FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        firstRows <- S.toList_ (S.take 10 s)
        reset conn
        -- The running query saw the table: it started before the reset.
        firstRows `shouldSatisfy` all (/= Only (Nothing :: Maybe Int))
        propTempTable <$> getProps conn `shouldReturn` Nothing
        r <- try (S.toList_ s)
        case r of
          Left ResultAbandoned -> pure ()
          Right rows -> expectationFailure ("read " ++ show (length rows) ++ " more rows")

      it "carries over a large (multi-packet) request" $ \conn -> do
        _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
        reset conn
        let big = T.replicate 100000 "z"
        (len, tbl) <- query1 conn (mkQuery "SELECT DATALENGTH(@p1), OBJECT_ID('tempdb..#hmssql_reset')" (Only big))
        (len :: Int64, tbl :: Maybe Int) `shouldBe` (200000, Nothing)
        reset conn
        (len', tbl') <- query1 conn (rawSql ("SELECT DATALENGTH(N'" <> big <> "'), OBJECT_ID('tempdb..#hmssql_reset')"))
        (len' :: Int64, tbl' :: Maybe Int) `shouldBe` (200000, Nothing)

      it "survives concurrent use" $ \conn -> do
        expected <- freshProps setup
        results <- forConcurrently [1 .. 16 :: Int] $ \i -> do
          replicateM_ 5 $ do
            reset conn
            query1 conn ("SELECT " <> param i) `shouldReturn` Only i
          pure i
        results `shouldBe` [1 .. 16]
        getProps conn `shouldReturn` expected

      -- An interruption of the request's read keeps the connection (the
      -- reset went out with the setup batch or the request); one that
      -- lands before the request is sent leaves the reset pending, for the
      -- next request.  One that interrupts the send, or the read of the
      -- setup batch, breaks the connection.
      it "after an interruption, leaves the session reset and set up, or the connection broken (ConnectionBroken wrapping the interruption)" $ \_ -> do
        expected <- freshProps setup
        ci <- connectInfoWith setup
        connRef <- newIORef =<< connect ci
        flip finally (readIORef connRef >>= close) $
          forM_ (concat (replicate 3 [0, 10, 50, 100, 200, 500, 1000, 2000, 5000])) $ \delay -> do
            conn <- readIORef connRef
            _ <- execute conn "SET ARITHABORT OFF; SET TEXTSIZE 12345; SET LOCK_TIMEOUT 1; \
                               \IF OBJECT_ID('tempdb..#hmssql_reset') IS NULL CREATE TABLE #hmssql_reset (i int)"
            reset conn
            _ <- timeout delay (query1 conn "SELECT 1" :: IO (Only Int))
            try (getProps conn) >>= \case
              Right p -> p `shouldBe` expected
              Left e
                | isBrokenByTimeout e -> do
                    close conn
                    connect ci >>= writeIORef connRef
                | otherwise -> expectationFailure ("after the interruption: " ++ show e)

      if null setup
        then it "costs no extra request" $ \conn -> do
          Only (spid :: Int) <- query1 conn "SELECT @@SPID"
          withTestDb $ \monitor -> do
            let requestsFor act = do
                  before <- serverReads monitor spid
                  _ <- act
                  after <- serverReads monitor spid
                  pure (after - before)
            plain <- requestsFor (query1 conn "SELECT 1" :: IO (Only Int))
            _ <- execute conn "CREATE TABLE #hmssql_reset (i int)"
            withReset <- requestsFor (reset conn >> (query1 conn "SELECT OBJECT_ID('tempdb..#hmssql_reset')" :: IO (Only (Maybe Int))))
            withReset `shouldBe` plain
            propTempTable <$> getProps conn `shouldReturn` Nothing
        -- num_reads counts packets: the setup batch must fit in one.
        else it "costs one extra request (the session setup)" $ \_ ->
          withTestDbWith (\ci -> ci { connectSessionSetup = setup, connectPacketSize = 4096 }) $ \conn -> do
            Only (spid :: Int) <- query1 conn "SELECT @@SPID"
            withTestDb $ \monitor -> do
              let requestsFor act = do
                    before <- serverReads monitor spid
                    _ <- act
                    after <- serverReads monitor spid
                    pure (after - before)
              plain <- requestsFor (query1 conn "SELECT 1" :: IO (Only Int))
              withReset <- requestsFor (reset conn >> (query1 conn "SELECT 1" :: IO (Only Int)))
              withReset `shouldBe` plain + 1

    describe "without a session setup" $
      it "returns to the login state, except for the isolation level" $ do
        expected <- freshProps []
        ci <- connectInfoWith []
        withConnection ci $ \conn -> do
          messUpSql >>= void . execute conn
          reset conn
          -- RESETCONNECTION keeps the isolation level on SQL Server
          -- (sp_reset_connection doesn't), and there is no session setup
          -- batch to set one.
          kept <- keptLevel messUpIsolation
          getProps conn `shouldReturn` expected { propIsolation = kept }

    describe "with a custom session setup" $ do
      it "re-runs the custom setup, which can set the isolation level back" $ do
        -- RESETCONNECTION keeps the level messUp set; the setup sets READ
        -- COMMITTED itself.
        let setup = ["SET LOCK_TIMEOUT 4321", "SET DATEFORMAT dmy", "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"]
        expected <- freshProps setup
        (propLockTimeout expected, propDateFormat expected) `shouldBe` (4321, "dmy")
        ci <- connectInfoWith setup
        withConnection ci $ \conn -> do
          messUpSql >>= void . execute conn
          reset conn
          getProps conn `shouldReturn` expected

      it "breaks the connection if the setup fails after a reset" $ withTable $ \t -> do
        -- Succeeds at connect, fails on the second run.
        let setup =
              [ "INSERT INTO " <> t <> " (id, v) SELECT COUNT(*) + 1, 0 FROM " <> t <> "; \
                \IF (SELECT COUNT(*) FROM " <> t <> ") > 1 RAISERROR('setup failed on purpose', 16, 1)" ]
        ci <- connectInfoWith setup
        withConnection ci $ \conn -> do
          query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
          reset conn
          r <- try (query1 conn "SELECT 2" :: IO (Only Int))
          case r of
            Left e -> sqlErrorMessage e `shouldBe` "setup failed on purpose"
            Right v -> expectationFailure ("got " ++ show v)
          r' <- try (query1 conn "SELECT 3" :: IO (Only Int))
          case r' of
            Left (ConnectionBroken (reasonCause -> cause)) -> fmap sqlErrorMessage (fromException cause) `shouldBe` Just "setup failed on purpose"
            Right v -> expectationFailure ("got " ++ show v)

    describe "isolation level" $ do
      forM_ setups $ \(label, setup) ->
        it ("keeps a level set by hand (RESETCONNECTION keeps the isolation level; Azure SQL Database reverts it), " ++ label ++ "; sp_reset_connection resets it") $
          withSetup setup $ \conn -> do
            _ <- execute conn "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
            propIsolation <$> getProps conn `shouldReturn` serializable
            reset conn
            kept <- keptLevel serializable
            propIsolation <$> getProps conn `shouldReturn` kept
            _ <- callProcedure conn "sp_reset_connection" []
            propIsolation <$> getProps conn `shouldReturn` readCommitted

      it "lets the session setup choose another level" $ do
        ci <- connectInfoWith ["SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"]
        withConnection ci $ \conn -> do
          propIsolation <$> getProps conn `shouldReturn` 3
          _ <- execute conn "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
          reset conn
          propIsolation <$> getProps conn `shouldReturn` 3

    -- Calling reset inside withTransaction is unsupported: the transaction
    -- ends with TransactionEndedEarly.
    forM_ setups $ \(label, setup) -> describe ("and transactions, " ++ label) $ around (withSetup setup) $ do
      let insert conn t i = void $ execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1, @p1)") (Only (i :: Int)))
          endedEarly :: IO a -> IO ()
          endedEarly act = try act >>= \case
            Left TransactionEndedEarly -> pure ()
            Left e -> expectationFailure ("threw " ++ show e)
            Right _ -> expectationFailure "no TransactionEndedEarly"

      it "reset in the body rolls the transaction back instead of committing (TransactionEndedEarly)" $ \conn -> withTable $ \t -> do
        endedEarly $ withTransaction conn $ do
          insert conn t 1
          reset conn
        inTransaction conn `shouldReturn` False
        count conn t `shouldReturn` 0
        -- The reset was carried out.
        propTranCount <$> getProps conn `shouldReturn` 0
        withTransaction conn (insert conn t 2)
        count conn t `shouldReturn` 1

      it "a request after reset in the body sees the transaction rolled back" $ \conn -> withTable $ \t -> do
        endedEarly $ withTransaction conn $ do
          insert conn t 1
          reset conn
          query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
          inTransaction conn `shouldReturn` False
        count conn t `shouldReturn` 0
        withTransaction conn (insert conn t 2)
        count conn t `shouldReturn` 1

      it "an exception after reset in the body propagates unchanged" $ \conn -> withTable $ \t -> do
        r <- try $ withTransaction conn $ do
          insert conn t 1
          reset conn
          throwIO (userError "boom")
        case r of
          Left e -> show (e :: IOException) `shouldContain` "boom"
          Right () -> expectationFailure "no exception"
        inTransaction conn `shouldReturn` False
        count conn t `shouldReturn` 0

      it "reset in withTransactionLevel ends it with TransactionEndedEarly, and the cleanup sets READ COMMITTED back" $ \conn -> do
        _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
        endedEarly $ withTransactionLevel Serializable conn $ do
          propIsolation <$> getProps conn `shouldReturn` serializable
          reset conn
        -- Neither REPEATABLE READ (the level before the transaction) nor
        -- SERIALIZABLE (which the reset alone would keep).
        propIsolation <$> getProps conn `shouldReturn` readCommitted

      it "withTransactionLevel after reset starts from the reset session, and sets READ COMMITTED back" $ \conn -> withTable $ \t -> do
        _ <- execute conn "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; CREATE TABLE #hmssql_reset (i int)"
        reset conn
        withTransactionLevel Serializable conn $ do
          p <- getProps conn
          (propIsolation p, propTempTable p, propTranCount p) `shouldBe` (serializable, Nothing, 1)
          insert conn t 1
        propIsolation <$> getProps conn `shouldReturn` readCommitted
        count conn t `shouldReturn` 1

      it "withTransaction after reset refuses a transaction begun by hand (TransactionAlreadyActive)" $ \conn -> withTable $ \t -> do
        begin conn
        insert conn t 1
        reset conn
        r <- try (withTransaction conn (insert conn t 2))
        case r of
          Left TransactionAlreadyActive -> pure ()
          other -> expectationFailure ("got " ++ either show (const "success") other)
        -- Nothing was sent: the reset is still pending, and the next
        -- request rolls the transaction begun by hand back.
        inTransaction conn `shouldReturn` True
        query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
        inTransaction conn `shouldReturn` False
        withTestDb $ \other -> query other (rawSql ("SELECT id FROM " <> t)) `shouldReturn` ([] :: [Only Int])
        withTransaction conn (insert conn t 2)
        withTestDb $ \other -> query other (rawSql ("SELECT id FROM " <> t)) `shouldReturn` [Only (2 :: Int)]
        -- Without a reset, it is refused too.
        begin conn
        r' <- try (withTransaction conn (insert conn t 3))
        case r' of
          Left TransactionAlreadyActive -> pure ()
          other -> expectationFailure ("got " ++ either show (const "success") other)
        rollback conn

      it "reset from another thread waits for the transaction to end" $ \conn -> withTable $ \t -> do
        inBody <- newEmptyMVar
        resetDone <- newEmptyMVar
        _ <- withTransaction conn $ do
          insert conn t 1
          _ <- forkIO $ putMVar inBody () >> reset conn >> putMVar resetDone ()
          takeMVar inBody
          threadDelay 100000
          -- The other thread is still waiting for the connection.
          isEmptyMVar resetDone `shouldReturn` True
          insert conn t 2
        takeMVar resetDone
        -- The transaction committed; the reset applies to the next request.
        count conn t `shouldReturn` 2
        inTransaction conn `shouldReturn` False

  describe "RESETCONNECTION framing" $ do
    let ctx = defaultTdsContext
        statuses body = [B.index p 1 | p <- splitIntoPackets ctx PTSqlBatch statusResetConnection (LB.fromStrict body)]
    it "is set on the first packet only" $ do
      let ss = statuses (B.replicate 10000 0)
      ss `shouldBe` [0x08, 0x00, 0x01]

    it "is not repeated when packet IDs wrap around" $ do
      let ss = statuses (B.replicate (300 * 4088) 0)
      length ss `shouldBe` 300
      take 1 ss `shouldBe` [0x08]
      filter (/= 0) (drop 1 ss) `shouldBe` [0x01]

    it "is set with EOM on a single-packet message" $
      statuses "x" `shouldBe` [0x09]
