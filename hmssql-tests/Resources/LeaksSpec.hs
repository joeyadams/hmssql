{-# LANGUAGE DerivingStrategies #-}

-- | Resource leaks under repetition (N=200 of each scenario): threads, file
-- descriptors, heap and server sessions must return to baseline, not grow
-- with N.  This is a different concern from the single-instance correctness
-- checks in Concurrency.CloseSpec (e.g. "a connection dropped without close
-- is closed once it is garbage") -- those check *that* cleanup happens once;
-- these check it keeps happening cleanly, and without a per-connection cost
-- that accumulates, at scale.
--
-- All 'slow' (each scenario opens/closes on the order of 200 real
-- connections): run with @HMSSQL_TEST_SLOW=1@.
module Resources.LeaksSpec (spec) where

import Control.Exception
import Control.Monad (forM_, replicateM_, void)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Streaming.Prelude as S
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Transaction
import Concurrency.Harness (uniqueAppName, waitForSessionCount)
import MockServer
import Resources.Helpers
import TestDb

-- | Repetitions per scenario.
n :: Int
n = 200

-- | Threads, fds and heap high-water mark, taken after 'settle'.  Named to
-- avoid clashing with 'Hmssql.Snapshot' (an isolation level).
data ResourceSnapshot = ResourceSnapshot
  { snThreads :: !Int
  , snFds :: !(Maybe Int)
  , snBackends :: !(Maybe Int)
    -- ^ On Windows, the handles hmssql's backends have open: an exact
    -- count, where 'snFds' there is a coarse one.
  , snHeap :: !(Maybe Word64)
  }
  deriving stock (Show)

snapshot :: IO ResourceSnapshot
snapshot = do
  settle
  ResourceSnapshot <$> threadCount <*> fdCount <*> backendHandles <*> heapLiveBytes

-- | Generous slack, so ordinary test-suite noise (other specs' leftover
-- threads winding down, GC bookkeeping) doesn't fail the test; growth
-- proportional to N (200) would dwarf this.
noGrowth :: ResourceSnapshot -> ResourceSnapshot -> Expectation
noGrowth before after = do
  (snThreads after - snThreads before) `shouldSatisfy` (<= 10)
  case (snFds before, snFds after) of
    (Just f0, Just f1) -> (f1 - f0) `shouldSatisfy` (<= 20 + fdSlack)
    _ -> pure () -- /dev/fd not listable here; skip the fd assertion
  -- On Windows, exactly: every handle opened since was closed.
  backendHandlesReturnTo (snBackends before)
  case (snHeap before, snHeap after) of
    (Just h0, Just h1) ->
      (toInteger h1 - toInteger h0) `shouldSatisfy` (< 16 * 1024 * 1024)
    _ -> expectationFailure "RTS stats are off: link the test suite with -with-rtsopts=-T"

appConnectInfo :: Text -> IO ConnectInfo
appConnectInfo prefix = do
  app <- uniqueAppName prefix
  ci <- defaultTestConnectInfo
  pure ci { connectApplicationName = app }

-- | A connection opened and then dropped without being closed.  Not inlined,
-- so nothing in the caller keeps it alive (mirrors Concurrency.CloseSpec's
-- @openAndDrop@, which isn't exported).
openAndDrop :: ConnectInfo -> IO ()
openAndDrop ci = do
  conn <- connect ci
  Only (1 :: Int) <- query1 conn "SELECT 1"
  pure ()
{-# NOINLINE openAndDrop #-}

bigQuery :: Text
bigQuery = "SELECT TOP 300000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

sessionsGoneFor :: Text -> Expectation
sessionsGoneFor app = waitForSessionCount 20 performMajorGC app 0 `shouldReturn` 0

spec :: Spec
spec = slow $ describe ("resource leaks (N=" ++ show n ++ ")") $ do
  it "200 connect+close cycles leave threads, fds, heap and sessions at baseline" $ do
    ci <- appConnectInfo "leak_connect_close"
    before <- snapshot
    forM_ [1 .. n] $ \_ -> do
      conn <- connect ci
      Only (1 :: Int) <- query1 conn "SELECT 1"
      close conn
    after <- snapshot
    noGrowth before after
    sessionsGoneFor (connectApplicationName ci)

  describe "200 failed connects" $ do
    it "wrong password leaves threads, fds and heap at baseline" $ do
      ci <- defaultTestConnectInfo
      before <- snapshot
      forM_ [1 .. n] $ \_ -> do
        r <- try (withConnection ci { connectPassword = "definitely the wrong password" } (\_ -> pure ())) :: IO (Either SomeException ())
        case r of
          Left _ -> pure ()
          Right () -> expectationFailure "connected with a wrong password"
      after <- snapshot
      noGrowth before after

    it "a nonexistent database leaves threads, fds and heap at baseline" $ do
      ci <- masterConnectInfo
      name <- uniqueName "hmssql_test_leak_nonexistent"
      before <- snapshot
      forM_ [1 .. n] $ \_ -> do
        r <- try (withConnection ci { connectDatabase = name } (\_ -> pure ())) :: IO (Either SomeException ())
        case r of
          Left _ -> pure ()
          Right () -> expectationFailure "connected to a nonexistent database"
      after <- snapshot
      noGrowth before after

    it "a wrong port leaves threads, fds and heap at baseline" $ do
      ci <- defaultTestConnectInfo
      before <- snapshot
      forM_ [1 .. n] $ \_ -> do
        r <- timeout 5_000_000 (try (withConnection ci { connectPort = "14330" } (\_ -> pure ())) :: IO (Either SomeException ()))
        case r of
          Just (Left _) -> pure ()
          Just (Right ()) -> expectationFailure "connected on the wrong port"
          Nothing -> expectationFailure "wrong-port connect did not fail within 5s"
      after <- snapshot
      noGrowth before after

    it "a TLS hostname mismatch leaves threads, fds and heap at baseline" $ do
      ci <- testConnectInfo EncryptOn
      before <- snapshot
      forM_ [1 .. n] $ \_ -> do
        r <- try (withConnection ci
          { connectHost = "127.0.0.1"
          , connectTls = (connectTls ci)
              { tlsTrustServerCertificate = False, tlsHostNameInCertificate = Just "not-the-right-host" }
          } (\_ -> pure ())) :: IO (Either SomeException ())
        case r of
          Left _ -> pure ()
          Right () -> expectationFailure "connected despite the hostname mismatch"
      after <- snapshot
      noGrowth before after

    it "the server closing during PRELOGIN leaves threads, fds and heap at baseline" $
      -- The mock closes the socket as soon as it has read the client's
      -- PRELOGIN, without ever answering it.
      withMockServer (\mc -> void (recvMessage mc)) $ \srv -> do
        before <- snapshot
        forM_ [1 .. n] $ \_ -> do
          r <- try (withConnection (mockConnectInfo srv) (\_ -> pure ())) :: IO (Either SomeException ())
          case r of
            Left _ -> pure ()
            Right () -> expectationFailure "connected despite the server closing during PRELOGIN"
        after <- snapshot
        noGrowth before after

  it "200 connections abandoned without close are all cleaned up once garbage" $ do
    ci <- appConnectInfo "leak_abandoned"
    before <- snapshot
    forM_ [1 .. n] $ \_ -> openAndDrop ci
    sessionsGoneFor (connectApplicationName ci)
    after <- snapshot
    noGrowth before after

  it "200 queries interrupted by a client-side timeout leave threads, fds, heap and sessions at baseline" $ do
    ci <- appConnectInfo "leak_query_timeout"
    before <- snapshot
    forM_ [1 .. n] $ \_ -> do
      conn <- connect ci
      _ <- timeout 20_000 (query conn (rawSql bigQuery) :: IO [Only Int])
      close conn `catch` \(_ :: SomeException) -> pure ()
    sessionsGoneFor (connectApplicationName ci)
    after <- snapshot
    noGrowth before after

  it "200 streams abandoned mid-way leave threads, fds, heap and sessions at baseline" $ do
    ci <- appConnectInfo "leak_stream_abandon"
    before <- snapshot
    forM_ [1 .. n] $ \_ -> do
      conn <- connect ci
      s <- queryS conn (rawSql bigQuery)
      _ <- S.toList_ (S.take 5 s) :: IO [Only Int]
      close conn
    sessionsGoneFor (connectApplicationName ci)
    after <- snapshot
    noGrowth before after

  it "200 resets on one connection leave threads, fds and heap at baseline" $
    withTestDb $ \conn -> do
      before <- snapshot
      replicateM_ n $ do
        reset conn
        Only (1 :: Int) <- query1 conn "SELECT 1"
        pure ()
      after <- snapshot
      noGrowth before after
      -- the connection (and its one session) is still perfectly usable
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)

  it "200 withTransaction bodies that throw leave threads, fds and heap at baseline" $
    withTestDb $ \conn -> do
      _ <- execute conn "CREATE TABLE #leak_txn (i int)"
      before <- snapshot
      replicateM_ n $ do
        -- a real parameter, not (), so this still exercises the sp_executesql
        -- (RPC) path rather than degrading to a plain batch
        r <- try (withTransaction conn (void (execute conn (mkQuery "INSERT INTO #leak_txn VALUES (@p1)" (Only (1 :: Int)))) >> throwIO (userError "boom")))
          :: IO (Either SomeException ())
        case r of
          Left _ -> pure ()
          Right () -> expectationFailure "withTransaction didn't propagate the exception"
      after <- snapshot
      noGrowth before after
      query1 conn "SELECT COUNT(*) FROM #leak_txn" `shouldReturn` Only (0 :: Int)
      inTransaction conn `shouldReturn` False
