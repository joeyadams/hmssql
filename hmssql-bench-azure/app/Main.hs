-- | Connect and query latency against one server, for comparing Azure SQL's
-- connection policies: /Proxy/, where every packet goes through the
-- gateway on port 1433, and /Redirect/ (the default from inside Azure),
-- where the login is redirected to the node hosting the database and
-- 'connect' follows it.
--
-- The server is the one the test suite's variables name (@HMSSQL_TEST_HOST@,
-- @_PORT@, @_USER@, @_PASSWORD@, @_DATABASE@, @_SERVER_NAME@, @_CERT@,
-- @_TLS_HOSTNAME@).  For each encryption mode in @BENCH_ENCRYPTIONS@
-- (@strict,on@ by default) it times, in order:
--
-- * the first connect and the first of each query, cold: the process has
--   not resolved the host or loaded a certificate store yet, and the server
--   may not have the plans or the connection's route cached;
-- * a warm-up (@BENCH_WARMUP@ connects and queries, not counted);
-- * @BENCH_CONNECTS@ connects, each followed by one @SELECT 1@ (the first
--   request of a new connection) and a close;
-- * on one connection: @BENCH_ROUND_TRIPS@ @SELECT 1@ round trips, and
--   @BENCH_TRANSFERS@ each of 10,000 short rows, 2000 rows of 1000
--   characters (4 MB), and a 1 MB parameter.
--
-- Each connection's endpoint is logged: the address its socket is connected
-- to, which is the gateway under Proxy and the database's node after a
-- redirect, and, for the first, what the server says it is
-- (@CONNECTIONPROPERTY@), so a run shows whether it was redirected at all.
-- Lines starting with @RESULT@ are tab-separated, for collecting runs:
-- label, encryption, measurement, count, then min, median, p90, p99, max
-- and mean in milliseconds.  @BENCH_LABEL@ is the label (the connection
-- policy, say).
module Main (main) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (forM, forM_, replicateM, replicateM_, void)
import qualified Data.ByteString as B
import Data.Int (Int32, Int64)
import Data.List (intercalate, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Network.Socket as Socket
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import Text.Printf (printf)

import Hmssql
import Hmssql.Connection.Backend (backendSocket)
import Hmssql.Connection.Internal (connBackend)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  password <- lookupEnv "HMSSQL_TEST_PASSWORD" >>= maybe (fail "HMSSQL_TEST_PASSWORD is not set") pure
  label <- var "BENCH_LABEL" "unlabelled"
  encryptions <- splitOn ',' <$> var "BENCH_ENCRYPTIONS" "strict,on"
  settings <- Settings
    <$> num "BENCH_WARMUP" 5
    <*> num "BENCH_CONNECTS" 30
    <*> num "BENCH_ROUND_TRIPS" 500
    <*> num "BENCH_TRANSFERS" 20
  base <- connectInfoFromEnv password
  now <- getCurrentTime
  printf "hmssql-bench-azure: %s, %s to %s port %s, database %s\n"
    label (show now) (T.unpack (connectHost base)) (T.unpack (connectPort base)) (T.unpack (connectDatabase base))
  printf "settings: warm-up %d, connects %d, round trips %d, transfers %d\n"
    (warmup settings) (connects settings) (roundTrips settings) (transfers settings)
  addrs <- Socket.getAddrInfo (Just Socket.defaultHints { Socket.addrSocketType = Socket.Stream })
    (Just (T.unpack (connectHost base))) (Just (T.unpack (connectPort base)))
  printf "%s resolves to %s\n" (T.unpack (connectHost base)) (intercalate ", " (map (show . Socket.addrAddress) addrs))
  forM_ encryptions $ \enc ->
    run label settings base { connectEncryption = encryptionFrom enc } enc

data Settings = Settings
  { warmup :: !Int
  , connects :: !Int
  , roundTrips :: !Int
  , transfers :: !Int
  }

run :: String -> Settings -> ConnectInfo -> String -> IO ()
run label Settings{..} ci enc = do
  printf "\n== encryption %s\n" enc
  let result = report label enc

  -- Cold: the first connect of this mode (of the process, for the first
  -- mode) and the first run of each query.
  (tConnect, conn) <- timed (connect ci) >>= \case
    (_, Left (e :: SomeException)) -> do
      printf "connect failed: %s\n" (displayException e)
      exitFailure
    (t, Right c) -> pure (t, c)
  peer <- peerName conn
  printf "cold connect: %.1f ms, to %s\n" (ms tConnect) peer
  serverView conn
  tSelect1 <- fst <$> timed (selectOne conn)
  tRows <- fst <$> timed (shortRows conn)
  tWide <- fst <$> timed (wideRows conn)
  tUpload <- fst <$> timed (upload conn)
  printf "cold queries: SELECT 1 %.1f ms, 10000 rows %.1f ms, 4 MB of rows %.1f ms, 1 MB parameter %.1f ms\n"
    (ms tSelect1) (ms tRows) (ms tWide) (ms tUpload)
  close conn
  result "cold connect" [tConnect]
  result "cold SELECT 1" [tSelect1]

  -- Warm-up, not counted.
  replicateM_ warmup $ do
    c <- connect ci
    selectOne c >> shortRows c >> wideRows c >> upload c
    close c

  -- Connects, each with its first request.
  samples <- forM [1 .. connects] $ \_ -> do
    (t, c) <- timed' (connect ci)
    p <- peerName c
    (t1, _) <- timed' (selectOne c)
    close c
    pure (t, t1, p)
  let endpoints = Map.fromListWith (+) [(p, 1 :: Int) | (_, _, p) <- samples]
  printf "connects reached: %s\n" (intercalate ", " [p ++ " x" ++ show n | (p, n) <- Map.toList endpoints])
  result "connect" [t | (t, _, _) <- samples]
  result "first SELECT 1" [t | (_, t, _) <- samples]
  result "connect + first SELECT 1" [t + t1 | (t, t1, _) <- samples]

  -- Requests on one warm connection.
  withConnection ci $ \c -> do
    p <- peerName c
    printf "queries on one connection, to %s\n" p
    result "SELECT 1" =<< replicateM roundTrips (fst <$> timed' (selectOne c))
    result "10000 short rows" =<< replicateM transfers (fst <$> timed' (shortRows c))
    result "2000 rows of 1000 chars" =<< replicateM transfers (fst <$> timed' (wideRows c))
    result "1 MB parameter" =<< replicateM transfers (fst <$> timed' (upload c))

-- | What the server says about the connection.
serverView :: Connection -> IO ()
serverView conn = do
  rows <- query conn
    "SELECT CONVERT(nvarchar(128), @@SERVERNAME), \
    \CONVERT(nvarchar(64), CONNECTIONPROPERTY('local_net_address')), \
    \CONVERT(int, CONNECTIONPROPERTY('local_tcp_port')), \
    \CONVERT(nvarchar(64), CONNECTIONPROPERTY('client_net_address'))"
    :: IO [(Maybe Text, Maybe Text, Maybe Int32, Maybe Text)]
  forM_ rows $ \(name, local, port, client) ->
    printf "server's view: @@SERVERNAME %s, local address %s port %s, client address %s\n"
      (shown name) (shown local) (maybe "?" show port) (shown client)
  where shown = maybe "NULL" T.unpack

selectOne :: Connection -> IO ()
selectOne c = void (query1 c "SELECT 1" :: IO (Only Int32))

shortRows :: Connection -> IO ()
shortRows c = do
  rows <- query c "SELECT value, CONCAT(N'row ', value) FROM GENERATE_SERIES(1, 10000)" :: IO [(Int32, Text)]
  expect "short rows" 10000 (length rows)

wideRows :: Connection -> IO ()
wideRows c = do
  rows <- query c "SELECT value, REPLICATE(N'x', 1000) FROM GENERATE_SERIES(1, 2000)" :: IO [(Int32, Text)]
  expect "wide rows" 2000 (length rows)

upload :: Connection -> IO ()
upload c = do
  Only n <- query1 c ("SELECT DATALENGTH(" <> param megabyte <> ")") :: IO (Only Int64)
  expect "parameter bytes" 1_000_000 (fromIntegral n)

megabyte :: B.ByteString
megabyte = B.replicate 1_000_000 0x61
{-# NOINLINE megabyte #-}

expect :: String -> Int -> Int -> IO ()
expect what want got
  | want == got = pure ()
  | otherwise = fail (what ++ ": expected " ++ show want ++ ", got " ++ show got)

------------------------------------------------------------------------------

-- | Time an action, in nanoseconds, catching a failure.
timed :: IO a -> IO (Double, Either SomeException a)
timed act = do
  t0 <- getMonotonicTimeNSec
  r <- try (act >>= evaluate)
  t1 <- getMonotonicTimeNSec
  pure (fromIntegral (t1 - t0), r)

-- | Time an action that must succeed.
timed' :: IO a -> IO (Double, a)
timed' act = timed act >>= \case
  (t, Right a) -> pure (t, a)
  (_, Left e) -> fail (displayException e)

ms :: Double -> Double
ms = (/ 1e6)

-- | Print a line of statistics, and its RESULT line.
report :: String -> String -> String -> [Double] -> IO ()
report label enc what ts = do
  let xs = sort (map ms ts)
      n = length xs
      at q = xs !! min (n - 1) (floor (q * fromIntegral n :: Double))
      mean = sum xs / fromIntegral n
  printf "%-26s n=%-4d min %8.2f  p50 %8.2f  p90 %8.2f  p99 %8.2f  max %8.2f  mean %8.2f ms\n"
    what n (xs !! 0) (at 0.5) (at 0.9) (at 0.99) (xs !! (n - 1)) mean
  printf "RESULT\t%s\t%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n"
    label enc what n (xs !! 0) (at 0.5) (at 0.9) (at 0.99) (xs !! (n - 1)) mean

------------------------------------------------------------------------------

connectInfoFromEnv :: String -> IO ConnectInfo
connectInfoFromEnv password = do
  host <- varT "HMSSQL_TEST_HOST" "::1"
  port <- varT "HMSSQL_TEST_PORT" "1433"
  user <- varT "HMSSQL_TEST_USER" "sa"
  database <- varT "HMSSQL_TEST_DATABASE" "hmssql_test"
  cert <- lookupEnv "HMSSQL_TEST_CERT"
  tlsHost <- varT "HMSSQL_TEST_TLS_HOSTNAME" ""
  serverName <- varT "HMSSQL_TEST_SERVER_NAME" ""
  pure defaultConnectInfo
    { connectHost = host
    , connectPort = port
    , connectUser = user
    , connectPassword = T.pack password
    , connectDatabase = database
    , connectServerName = serverName
    , connectApplicationName = "hmssql-bench-azure"
    , connectTls = defaultTlsSettings
        { tlsCaCertificateFiles = maybe [] pure cert
        , tlsHostNameInCertificate = if T.null tlsHost then Nothing else Just tlsHost
        }
    }

encryptionFrom :: String -> Encryption
encryptionFrom = \case
  "strict" -> EncryptStrict
  "on" -> EncryptOn
  "req" -> EncryptReq
  "off" -> EncryptOff
  "notsup" -> EncryptNotSup
  other -> error ("unknown encryption " ++ other ++ " (strict, on, req, off, notsup)")

var :: String -> String -> IO String
var name def = fromMaybe def <$> lookupEnv name

varT :: String -> Text -> IO Text
varT name def = maybe def T.pack <$> lookupEnv name

num :: String -> Int -> IO Int
num name def = maybe def read <$> lookupEnv name

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest

-- | The address the connection reached, to tell the gateway from a node.
peerName :: Connection -> IO String
peerName conn = case backendSocket (connBackend conn) of
  Just sock -> show <$> Socket.getPeerName sock
  Nothing -> pure "a connection that is not over a socket"
