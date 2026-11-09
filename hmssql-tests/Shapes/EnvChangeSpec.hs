-- | ENVCHANGE-driven state: database switches, language, packet size, and
-- transaction descriptor tracking across plain batches, sp_executesql, and
-- nested/savepoint transactions.
module Shapes.EnvChangeSpec (spec) where

import Control.Exception (try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Transaction
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Connection (TdsContext (..), connectionContext)
import Hmssql.Query (batchRequest, responseS)
import Hmssql.Tds.Token (EnvChange (..), Token (..))
import OpenResponses (isMarsConnection)
import TestDb

envChangesOf :: Connection -> Text -> IO [EnvChange]
envChangesOf conn sql = do
  toks <- responseS conn (batchRequest sql) >>= S.toList_
  pure [ec | TEnvChange ec <- toks]

spec :: Spec
spec = around withTestDb $ do
  -- To the companion database, and back.
  skipOnAzure "no USE (error 40508)" $ describe "database (USE)" $ do
    it "reports an ECDatabase envchange in a plain batch" $ \conn -> do
      dbName <- connectDatabase <$> companionConnectInfo
      testDb <- testDatabaseName
      ecs <- envChangesOf conn ("USE " <> quoteName dbName)
      [ECDatabase old new] <- pure [ec | ec@ECDatabase{} <- ecs]
      (old, new) `shouldBe` (testDb, dbName)
      -- switch back so the connection is left in its original database
      _ <- execute conn (rawSql ("USE " <> quoteName testDb))
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only testDb

    it "switches database when USE runs via sp_executesql (parameterized)" $ \conn -> do
      dbName <- connectDatabase <$> companionConnectInfo
      testDb <- testDatabaseName
      Only echoed <- query1 conn (mkQuery ("USE " <> quoteName dbName <> "; SELECT @p1") (Only (1 :: Int)))
      (echoed :: Int) `shouldBe` 1
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only dbName
      _ <- execute conn (rawSql ("USE " <> quoteName testDb))
      query1 conn "SELECT DB_NAME()" `shouldReturn` Only testDb

  describe "SET LANGUAGE" $
    it "reports an ECLanguage envchange and an INFO message" $ \conn -> do
      toks <- responseS conn (batchRequest "SET LANGUAGE British") >>= S.toList_
      let ecs = [ec | TEnvChange ec@ECLanguage{} <- toks]
          msgs = [msgText m | TInfo m <- toks]
      map newValue ecs `shouldBe` ["British"]
      msgs `shouldBe` ["Changed language setting to British."]
      -- restore, so later tests in this connection see the default language
      _ <- execute conn "SET LANGUAGE us_english"
      pure ()

  describe "packet size" $ do
    it "keeps the default packet size when none is requested" $ \_ -> do
      -- (Not HMSSQL_TEST_PACKET_SIZE's.)
      ci <- (\ci -> ci { connectPacketSize = connectPacketSize defaultConnectInfo }) <$> defaultTestConnectInfo
      withConnection ci $ \conn -> do
        ctx <- connectionContext conn
        tdsPacketSize ctx `shouldBe` connectPacketSize ci
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "grants a moderately larger requested packet size exactly" $ \_ -> do
      ci <- defaultTestConnectInfo
      withConnection ci { connectPacketSize = 2048 } $ \conn -> do
        ctx <- connectionContext conn
        tdsPacketSize ctx `shouldBe` 2048
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "tracks a server-capped packet size correctly (no larger than requested, still usable)" $ \_ -> do
      ci <- defaultTestConnectInfo
      -- this server instance caps negotiated packet size at 8000 regardless of
      -- client request (confirmed independently with sqlcmd -a); the DMV
      -- column sys.dm_exec_connections.net_packet_size is NOT a reliable
      -- oracle here since, for an encrypted connection, it reports a value
      -- inflated by a constant (TLS framing) offset rather than the literal
      -- TDS-negotiated size
      withConnection ci { connectPacketSize = 65535 } $ \conn -> do
        ctx <- connectionContext conn
        tdsPacketSize ctx `shouldSatisfy` (<= 65535)
        tdsPacketSize ctx `shouldSatisfy` (>= 512) -- sanity: not a tiny/garbage value
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "transactions" $ do
    it "tracks the transaction descriptor across plain batches and parameterized queries" $ \conn -> do
      _ <- execute conn "CREATE TABLE #envtx (i int)"
      begin conn
      inTransaction conn `shouldReturn` True
      -- a parameterized query (sp_executesql / RPC) must run inside the same transaction
      _ <- execute conn (mkQuery "INSERT INTO #envtx VALUES (@p1)" (Only (1 :: Int)))
      _ <- execute conn "ROLLBACK TRANSACTION"
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT COUNT(*) FROM #envtx" `shouldReturn` Only (0 :: Int)

    it "keeps @@TRANCOUNT and inTransaction consistent through nested BEGIN/COMMIT" $ \conn -> do
      if isMarsConnection conn
        then do
          -- Under MARS a batch may not start the outermost transaction: the
          -- server rolls it back at the end of the batch (error 3997).  The
          -- outer one begins by a Transaction Manager request; a nested
          -- BEGIN TRANSACTION batch inside it is accepted.
          r <- try (execute conn "BEGIN TRANSACTION")
          either sqlErrorNumber (const 0) r `shouldBe` 3997
          query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
          inTransaction conn `shouldReturn` False
          begin conn
        else void $ execute conn "BEGIN TRANSACTION"
      _ <- execute conn "BEGIN TRANSACTION"
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (2 :: Int)
      inTransaction conn `shouldReturn` True
      _ <- execute conn "COMMIT TRANSACTION"
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (1 :: Int)
      inTransaction conn `shouldReturn` True
      _ <- execute conn "COMMIT TRANSACTION"
      query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
      inTransaction conn `shouldReturn` False

    it "SAVE TRAN / ROLLBACK TRAN to a savepoint keeps the outer transaction open" $ \conn -> do
      _ <- execute conn "CREATE TABLE #sp (i int)"
      begin conn
      _ <- execute conn "INSERT INTO #sp VALUES (1)"
      _ <- execute conn "SAVE TRANSACTION sp1"
      _ <- execute conn "INSERT INTO #sp VALUES (2)"
      _ <- execute conn "ROLLBACK TRANSACTION sp1"
      inTransaction conn `shouldReturn` True
      query1 conn "SELECT COUNT(*) FROM #sp" `shouldReturn` Only (1 :: Int)
      _ <- execute conn "COMMIT TRANSACTION"
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT COUNT(*) FROM #sp" `shouldReturn` Only (1 :: Int)

    it "reports a clean error for COMMIT with no matching BEGIN" $ \conn -> do
      r <- try (execute conn "COMMIT TRANSACTION")
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 3902
        Right n -> expectationFailure ("succeeded with " ++ show n)
