-- | Helpers for the live tests of transactions, reset and bulk copy on MARS
-- connections ("MarsTx.*Spec"): MARS connections whatever
-- @HMSSQL_TEST_MARS@ says, tables of a test's own, streams that can be
-- cancelled, what the connection's sessions hold, and the errors the tests
-- expect.
module MarsTx.Harness
  ( -- * Connections
    marsConnectInfo
  , withMarsConn
  , withMarsConnWith
  , withMarsConnTo
    -- * Tables
  , withTable
  , withIntTable
  , insertKey
  , keysIn
  , countIn
  , canTakeKeys
    -- * Rows to read
  , numbersSql
  , numbersTable
  , numbers
  , WideRow
  , wideRow
    -- * Streams
  , openS
  , openSQuery
  , openWide
    -- * Sessions
  , busySids
  , openSids
  , reservedSid
  , awaitArrived
  , withMarsConnArriving
  , allArrived
  , noResponseOpen
    -- * The server's state
  , tranCount
  , sessionLevel
  , levelSql
  , lockTimeout
  , tempTableExists
    -- * Expected failures
  , sqlErrorOf
  , failsWithSql
  , requestsActive
  , shouldEndEarly
  , shouldBeAbandoned
  , conversionError
  , readCounting
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception
import Control.Monad (forM, forM_, unless, void)
import Data.Int (Int16, Int32)
import Data.IORef
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Connection.Internal
  ( ActiveResponse (..), Connection (..), Mars (..), Session (..), SmpLink (..), SmpSession (..), allSessions )
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Query.Internal (compilerFor, streamFirstResultSet)
import Hmssql.Transaction
import TestDb

------------------------------------------------------------------------------
-- Connections

-- | The default test connection settings with MARS on, whatever
-- @HMSSQL_TEST_MARS@ says.
marsConnectInfo :: IO ConnectInfo
marsConnectInfo = (\ci -> ci { connectMars = True }) <$> defaultTestConnectInfo

-- | A MARS connection to the shared test database.
withMarsConn :: (Connection -> IO a) -> IO a
withMarsConn = withMarsConnWith id

-- | 'withMarsConn' with a window of at least 64 packets
-- (@HMSSQL_TEST_MARS_WINDOW@ may set less), for a test that waits for a
-- response of 100 rows to arrive whole ('awaitArrived'): a smaller window
-- parks it at the window, where it never does.
withMarsConnArriving :: (Connection -> IO a) -> IO a
withMarsConnArriving = withMarsConnWith (\ci -> ci { connectMarsWindow = max 64 (connectMarsWindow ci) })

-- | 'withMarsConn' with some settings changed (MARS stays on).
withMarsConnWith :: (ConnectInfo -> ConnectInfo) -> (Connection -> IO a) -> IO a
withMarsConnWith f act = do
  ci <- marsConnectInfo
  withConnection (f ci) { connectMars = True } act

-- | A MARS connection with these settings (a scratch database's, say).
withMarsConnTo :: ConnectInfo -> (Connection -> IO a) -> IO a
withMarsConnTo ci = withConnection ci { connectMars = True }

------------------------------------------------------------------------------
-- Tables

-- | A table of the test's own in the shared test database, with the given
-- column definitions, dropped afterwards.
withTable :: Text -> Text -> (Text -> IO a) -> IO a
withTable prefix columns act = do
  t <- ("dbo." <>) <$> uniqueName prefix
  withTestDb $ \conn -> void $ execute conn (rawSql ("CREATE TABLE " <> t <> " (" <> columns <> ")"))
  act t `finally` withTestDb (\conn -> void $ execute conn (rawSql ("DROP TABLE IF EXISTS " <> t)))

-- | 'withTable' @(i int PRIMARY KEY)@.
withIntTable :: Text -> (Text -> IO a) -> IO a
withIntTable prefix = withTable prefix "i int PRIMARY KEY"

insertKey :: Connection -> Text -> Int -> IO ()
insertKey conn t i = void $ execute conn (mkQuery ("INSERT INTO " <> t <> " VALUES (@p1)") (Only i))

-- | The keys of an 'withIntTable' table, as another connection sees them.
keysIn :: Text -> IO [Int]
keysIn t = withTestDb $ \other ->
  map fromOnly <$> query other (rawSql ("SELECT i FROM " <> t <> " ORDER BY i"))

countIn :: Connection -> Text -> IO Int
countIn conn t = fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t))

-- | Another connection inserts the keys and deletes them again: nothing
-- holds their locks (error 1222) and none of them is committed (2627).  A
-- lock left behind is held until the connection closes, so a short
-- @LOCK_TIMEOUT@ tells it apart; not 0, which under the load of a whole
-- suite run met a lock the server was still releasing.
canTakeKeys :: Text -> [Int] -> IO ()
canTakeKeys t keys = withTestDb $ \other -> do
  _ <- execute other "SET LOCK_TIMEOUT 2000"
  forM_ keys (insertKey other t)
  forM_ keys $ \k -> execute other (mkQuery ("DELETE FROM " <> t <> " WHERE i = @p1") (Only k))

------------------------------------------------------------------------------
-- Rows to read

-- | @n@ rows @(i int, pad varchar(50))@, @i@ from 1, in order: about 60
-- bytes each, so 100,000 rows are far more than a window of packets.
numbersSql :: Int -> Text
numbersSql n = "SELECT n.i, n.pad FROM " <> numbersTable n <> " ORDER BY n.i"

-- | The rows of 'numbersSql' as a derived table @n@.  (The @ORDER BY@ is
-- outside it: inside, with the @TOP@, the server numbers the whole cross
-- join before it returns a row.)
numbersTable :: Int -> Text
numbersTable n =
  "(SELECT TOP (" <> T.pack (show n) <> ") \
  \CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) AS i, REPLICATE('x', 50) AS pad \
  \FROM sys.all_columns a CROSS JOIN sys.all_columns b) AS n"

numbers :: Int -> Query
numbers = rawSql . numbersSql

-- | A row of 'numbers'.
type WideRow = (Int32, Text)

wideRow :: WideRow -> Int
wideRow (i, _) = fromIntegral i

------------------------------------------------------------------------------
-- Streams

-- | 'queryS' with its reader, for 'cancelResponse'.
openS :: FromSqlRow r => Connection -> Text -> IO (ResponseReader, Stream (Of r) IO ())
openS conn = openSQuery conn . rawSql

openSQuery :: FromSqlRow r => Connection -> Query -> IO (ResponseReader, Stream (Of r) IO ())
openSQuery conn q = do
  req <- queryRequest conn q
  resp <- startResponse conn req
  pure (resp, streamFirstResultSet (compilerFor rowDecoder) resp (drainResponse resp))

-- | 'openS' of 'numbers'.
openWide :: Connection -> Int -> IO (ResponseReader, Stream (Of WideRow) IO ())
openWide conn = openS conn . numbersSql

------------------------------------------------------------------------------
-- Sessions

sessionSid :: Session -> Int
sessionSid = maybe (-1) (fromIntegral . smpSid) . sessSmp

-- | The SMP sessions with a response not read to its end (busy).
busySids :: Connection -> IO [Int]
busySids conn = do
  sessions <- allSessions conn
  catMaybes <$> forM sessions (\s -> fmap (const (sessionSid s)) <$> readIORef (sessResponse s))

-- | The open SMP sessions.
openSids :: Connection -> IO [Int]
openSids conn = map sessionSid <$> allSessions conn

-- | The session reserved for a bulk load, if any.
reservedSid :: Connection -> IO (Maybe Int)
reservedSid conn = case connMars conn of
  Nothing -> pure Nothing
  Just mars -> fmap sessionSid <$> readIORef (marsReserved mars)

-- | Whether every open response has fully arrived: its last packet is
-- queued on its session (or read).
allArrived :: Connection -> IO Bool
allArrived conn = do
  sessions <- allSessions conn
  pending <- forM sessions $ \s -> readIORef (sessResponse s) >>= \case
    Nothing -> pure False
    Just ar -> case sessSmp s of
      Nothing -> pure False
      Just smp -> (<= arEomBase ar) <$> readTVarIO (linkEoms (smpLink smp))
  pure (not (or pending))

-- | Wait (at most 10 s) until 'allArrived'.
awaitArrived :: Connection -> IO ()
awaitArrived conn = go (1000 :: Int)
  where
    go 0 = expectationFailure "the responses did not arrive in 10 s"
    go n = do
      done <- allArrived conn
      unless done $ threadDelay 10_000 >> go (n - 1)

-- | No session is busy.
noResponseOpen :: Connection -> IO ()
noResponseOpen conn = busySids conn `shouldReturn` []

------------------------------------------------------------------------------
-- The server's state

tranCount :: Connection -> IO Int
tranCount conn = fromOnly <$> query1 conn "SELECT @@TRANCOUNT"

-- | The session's isolation level, as the server reports it.
sessionLevel :: Connection -> IO IsolationLevel
sessionLevel conn = do
  Only (n :: Int16) <- query1 conn "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID"
  case n of
    1 -> pure ReadUncommitted
    2 -> pure ReadCommitted
    3 -> pure RepeatableRead
    4 -> pure Serializable
    5 -> pure Snapshot
    _ -> fail ("unexpected transaction_isolation_level " ++ show n)

levelSql :: IsolationLevel -> Text
levelSql = \case
  ReadUncommitted -> "READ UNCOMMITTED"
  ReadCommitted -> "READ COMMITTED"
  RepeatableRead -> "REPEATABLE READ"
  Snapshot -> "SNAPSHOT"
  Serializable -> "SERIALIZABLE"

lockTimeout :: Connection -> IO Int
lockTimeout conn = fromOnly <$> query1 conn "SELECT @@LOCK_TIMEOUT"

-- | Whether @#name@ exists for the session.
tempTableExists :: Connection -> Text -> IO Bool
tempTableExists conn name =
  (== (1 :: Int)) . fromOnly <$> query1 conn (rawSql ("SELECT CASE WHEN OBJECT_ID(N'tempdb..#" <> name <> "') IS NULL THEN 0 ELSE 1 END"))

------------------------------------------------------------------------------
-- Expected failures

-- | The number of the 'SqlServerError' the action throws.
sqlErrorOf :: IO a -> IO Int
sqlErrorOf act = try act >>= \case
  Left (e :: SqlServerError) -> pure (fromIntegral (sqlErrorNumber e))
  Right _ -> expectationFailure "expected a SqlServerError" >> pure 0

-- | The action fails with this SQL Server error.
failsWithSql :: IO a -> Int -> IO ()
failsWithSql act n = sqlErrorOf act `shouldReturn` n

-- | The statements of the 'TransactionRequestsActive' the action throws.
requestsActive :: IO a -> IO [Text]
requestsActive act = try act >>= \case
  Left (TransactionRequestsActive stmts) -> pure stmts
  Left e -> expectationFailure ("expected TransactionRequestsActive, got " ++ show e) >> pure []
  Right _ -> expectationFailure "expected TransactionRequestsActive" >> pure []

shouldEndEarly :: IO a -> IO ()
shouldEndEarly act = try act >>= \case
  Left TransactionEndedEarly -> pure ()
  Left e -> expectationFailure ("expected TransactionEndedEarly, got " ++ show e)
  Right _ -> expectationFailure "expected TransactionEndedEarly"

-- | Reading on throws 'ResultAbandoned'.
shouldBeAbandoned :: IO a -> IO ()
shouldBeAbandoned act = try act >>= \case
  Left ResultAbandoned -> pure ()
  Right _ -> expectationFailure "expected ResultAbandoned, the read succeeded"

-- | A request that fails with a conversion error (245), which under
-- @XACT_ABORT ON@ ends the transaction.
conversionError :: Connection -> IO ()
conversionError conn = (query conn "SELECT CAST('x' AS int)" :: IO [Only Int]) `failsWithSql` 245

-- | How many rows the stream delivers, and the number of the SQL Server
-- error it then ends with (0 for none).
readCounting :: Stream (Of a) IO () -> IO (Int, Int)
readCounting s = do
  seen <- newIORef 0
  r <- try (S.mapM_ (\_ -> modifyIORef' seen (+ 1)) s)
  n <- readIORef seen
  pure (n, either (fromIntegral . sqlErrorNumber) (const 0) r)
