{-# LANGUAGE BangPatterns #-}

-- | MARS against a plain connection, on a live server: what a
-- 'connectMars' connection costs where nothing is interleaved, and what
-- interleaving buys or costs where it is.  They run when
-- @HMSSQL_TEST_PASSWORD@ is set, on the connection "Bench.Live" describes
-- (the same @HMSSQL_TEST_*@ variables), and are skipped otherwise.
--
-- Every group runs the same work over a plain connection (@plain@) and over
-- a MARS connection (@MARS@), side by side, and tasty-bench prints the
-- ratio to the plain one.  Each has connections of its own, and the tables
-- it reads are @#temp@ tables the connections create.
--
-- * @SELECT 1@: the price of an SMP header and a window acknowledgement on
--   a request that does nothing else.
-- * One stream of 10,000 and of 200,000 @(Int32, Text)@ rows, read with
--   'withQueryS' and counted: the price of SMP framing and windowing per
--   packet.
-- * Four streams of 50,000 rows: on MARS read round-robin (a row from each
--   in turn, all four open at once), and one after another on both kinds
--   of connection; a plain connection can't interleave, so the
--   comparison is what interleaving costs when it isn't needed.
-- * A large parameter, 1 MB and 4 MB of @varbinary(max)@: the client's
--   sending side, held back by the server's window.
-- * Nested N+1: a stream of 1,000 rows and one 'query1' per row, as MARS
--   allows (the inner request runs while the outer response is open),
--   against the list read first and then the 1,000 queries, which is
--   what a plain connection needs, on either kind of connection.
-- * 'connectMarsWindow' 4, 16, 64 (the default) and 256, for one stream
--   of 10,000 and of 200,000 rows: how far the server may send ahead of the
--   client's acknowledgements.
--
-- The interesting numbers here are latency: CPU time is the client's, and
-- a window stall costs none.  So this group is measured by the clock
-- (@hmssql-bench/Main.hs@ sets the wall-time mode for it and for "Bench.Live"):
--
-- > stack bench --benchmark-arguments '-p Mars'
--
-- Numbers from the machine this was written on (an Apple silicon laptop,
-- SQL Server 2025 in Docker on the same machine, TLS 1.3 over loopback,
-- @--time-mode wall@, default RTS options), 2026-09-30.  The machine was
-- shared with test runs and other benchmarks, so these are indicative, and
-- the spread matters: three runs while it was quiet agree within 1 to 5%
-- for most benchmarks, but a run on the loaded machine took up to twice as
-- long (nested N+1 530 ms instead of 290 ms), and on either kind of
-- connection a benchmark now and then takes 1.5 times its usual time
-- (200000 rows: 66 ms in one run, 100 ms in two others; the same
-- happened to @window 64@ and to a plain @SELECT 1@).  The ratios within
-- one run are the reliable part.  Times in ms, plain / MARS (ratio),
-- the typical run:
--
-- > SELECT 1                       0.37  / 0.38   (1.02)
-- > one stream, 10000 rows         3.45  / 3.49   (1.01)
-- > one stream, 200000 rows        66.5  / 67.7   (1.02)
-- > four streams of 50000 rows     64.9 one after another / 65.7 on MARS one
-- >                                after another (1.01) / 63.3 round-robin (0.98)
-- > varbinary(max) 1 MB parameter  13.4 to 18.2 / 18.7  (1.0 to 1.4)
-- > varbinary(max) 4 MB parameter  53.4  / 66.2   (1.24; 1.17 in another run)
-- > nested N+1, 1000 rows          290 list first / 303 MARS list first (1.04)
-- >                                / 291 MARS nested (1.00)
-- > window 4, 16, 64, 256          10000 rows  3.65, 3.53, 3.42, 3.45
-- >                                200000 rows 73.7, 70.0, 67.3, 66.6
--
-- So MARS costs nothing measurable on a round trip or a stream, interleaving
-- four streams costs nothing either (and reads no faster than one after
-- another: it is not parallelism), a nested query per row costs what a query
-- per row from a list does, a window of 4 packets is about 10% slower on a
-- large stream and 16 is nearly the default's speed, and the large parameter
-- is the one place a MARS connection is slower (about a fifth at 4 MB).
-- See docs/dev/testing.md for how to compare runs.
module Bench.Mars (benchmarks) where

import Control.DeepSeq (NFData (..))
import Control.Monad (foldM, forM_)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Streaming (Of, Stream)
import Test.Tasty.Bench

import Hmssql

-- | Connections, for 'envWithCleanup' (which wants an 'NFData' resource).
newtype Conns = Conns [Connection]

instance NFData Conns where
  rnf (Conns cs) = cs `seq` ()

benchmarks :: IO [Benchmark]
benchmarks = lookupEnv "HMSSQL_TEST_PASSWORD" >>= \case
  Nothing -> do
    hPutStrLn stderr "HMSSQL_TEST_PASSWORD is not set: the MARS benchmarks are skipped"
    pure []
  Just password -> do
    info <- connectInfoFromEnv password
    pure
      [ bgroup "Mars"
          [ withPair info [] $ \plain mars -> bgroup "SELECT 1 round trip"
              [ bench "plain" $ whnfIO (select1 plain)
              , bcompareTo "SELECT 1 round trip" "plain" $ bench "MARS" $ whnfIO (select1 mars)
              ]
          , streamGroup info "one stream, 10000 rows" 10000
          , streamGroup info "one stream, 200000 rows" 200000
          , withPair info [] $ \plain mars -> bgroup "four streams, 50000 rows each"
              [ bench "plain, one after another" $ whnfIO (sequentially plain 4 50000)
              , bcompareTo "four streams, 50000 rows each" "plain, one after another" $
                  bench "MARS, one after another" $ whnfIO (sequentially mars 4 50000)
              , bcompareTo "four streams, 50000 rows each" "plain, one after another" $
                  bench "MARS, round-robin" $ whnfIO (roundRobin mars 50000)
              ]
          , withPair info [] $ \plain mars -> bgroup "large parameter"
              [ bgroup name
                  [ bench "plain" $ whnfIO (largeParam plain payload)
                  , bcompareTo name "plain" $ bench "MARS" $ whnfIO (largeParam mars payload)
                  ]
              | (name, payload) <- [("varbinary(max) 1MB", oneMB), ("varbinary(max) 4MB", fourMB)]
              ]
          , withPair info [nplus1Table] $ \plain mars -> bgroup "nested N+1, 1000 rows"
              [ bench "plain, list first" $ whnfIO (listFirst plain)
              , bcompareTo "nested N+1, 1000 rows" "plain, list first" $ bench "MARS, list first" $ whnfIO (listFirst mars)
              , bcompareTo "nested N+1, 1000 rows" "plain, list first" $ bench "MARS, nested" $ whnfIO (nested mars)
              ]
          , bgroup "window"
              [ windowGroup info ("one stream, " ++ show rows ++ " rows") rows | rows <- [10000, 200000] ]
          ]
      -- Pin encryption for these cases so that setting the general benchmark
      -- environment to plaintext cannot silently remove coverage of SMP over
      -- TLS. EncryptOn also works on servers that predate strict TDS 8.0.
      , bgroup "MarsTLS"
          [ streamGroup info { connectEncryption = EncryptOn } "TLS one stream, 10000 rows" 10000
          , withPair info { connectEncryption = EncryptOn } [] $ \plain mars ->
              bgroup "TLS varbinary(max) 4MB parameter"
                [ bench "plain" $ whnfIO (largeParam plain fourMB)
                , bcompareTo "TLS varbinary(max) 4MB parameter" "plain" $
                    bench "MARS" $ whnfIO (largeParam mars fourMB)
                ]
          ]
      ]

-- | A plain and a MARS connection, each having run the given setup batches.
withPair :: ConnectInfo -> [[Text]] -> (Connection -> Connection -> Benchmark) -> Benchmark
withPair info tables k =
  envWithCleanup
    (do plain <- open info { connectMars = False }
        mars <- open info { connectMars = True }
        pure (Conns [plain, mars]))
    (\(Conns cs) -> mapM_ close cs)
    -- Lazy: the tree is built (to list or filter it) before the resource exists.
    (\ ~(Conns cs) -> k (cs !! 0) (cs !! 1))
  where
    open i = do
      c <- connect i
      forM_ (concat tables) (execute c . rawSql)
      pure c

-- | The tasty-bench pattern for a benchmark named by its group and its own
-- name (the last two fields of its path), to compare against.
bcompareTo :: String -> String -> Benchmark -> Benchmark
bcompareTo group name = bcompare ("$(NF-1) == \"" ++ group ++ "\" && $NF == \"" ++ name ++ "\"")

select1 :: Connection -> IO Int32
select1 conn = do
  Only n <- query1 conn "SELECT 1"
  pure n

-- | A stream of this many rows of @(Int32, Text)@.
rowsQuery :: Int -> Query
rowsQuery n = "SELECT value, CONCAT(N'name-', value) FROM GENERATE_SERIES(1, " <> param (fromIntegral n :: Int32) <> ")"

-- | Read a stream to its end with 'withQueryS', counting the rows.
countRows :: Connection -> Int -> IO Int
countRows conn n = withQueryS conn (rowsQuery n) $ \s ->
  S.length_ (S.map (\(_ :: Int32, _ :: Text) -> ()) s)

-- | A plain and a MARS connection reading one stream.
streamGroup :: ConnectInfo -> String -> Int -> Benchmark
streamGroup info name n = withPair info [] $ \plain mars -> bgroup name
  [ bench "plain" $ whnfIO (countRows plain n)
  , bcompareTo name "plain" $ bench "MARS" $ whnfIO (countRows mars n)
  ]

-- | One stream per 'connectMarsWindow', each on a connection of its own.
windowGroup :: ConnectInfo -> String -> Int -> Benchmark
windowGroup info name n =
  envWithCleanup
    (Conns <$> mapM (\w -> connect info { connectMars = True, connectMarsWindow = w }) windows)
    (\(Conns cs) -> mapM_ close cs)
    (\ ~(Conns cs) -> bgroup name
        [ (if w == 4 then id else bcompareTo name "window 4") $
            bench ("window " ++ show w) $ whnfIO (countRows (cs !! i) n)
        | (i, w) <- zip [0 ..] windows ])
  where
    windows = [4, 16, 64, 256]

-- | Four streams of @n@ rows read one after another.
sequentially :: Connection -> Int -> Int -> IO Int
sequentially conn streams n = sum <$> mapM (const (countRows conn n)) [1 .. streams]

-- | Four streams open at once, a row from each in turn until all are done.
roundRobin :: Connection -> Int -> IO Int
roundRobin conn n =
  withQueryS conn (rowsQuery n) $ \a ->
  withQueryS conn (rowsQuery n) $ \b ->
  withQueryS conn (rowsQuery n) $ \c ->
  withQueryS conn (rowsQuery n) $ \d -> go 0 [a, b, c, d]
  where
    go :: Int -> [Stream (Of (Int32, Text)) IO ()] -> IO Int
    go !count [] = pure count
    go !count streams = do
      (count', live) <- foldM step (count, []) streams
      go count' (reverse live)
    step (!count, live) s = S.next s >>= \case
      Left () -> pure (count, live)
      Right (_, rest) -> pure (count + 1, rest : live)

largeParam :: Connection -> B.ByteString -> IO Int
largeParam conn payload = do
  Only len <- query1 conn (mkQuery "SELECT DATALENGTH(@p1)" (Only payload))
  pure (fromIntegral (len :: Int32))

oneMB, fourMB :: B.ByteString
oneMB = B.replicate (1024 * 1024) 0x78
fourMB = B.replicate (4 * 1024 * 1024) 0x78
{-# NOINLINE oneMB #-}
{-# NOINLINE fourMB #-}

-- | 1,000 parents (@#parent@) and, for each, one child row (@#child@) to
-- look up by key.
nplus1Table :: [Text]
nplus1Table =
  [ "CREATE TABLE #parent (id int NOT NULL PRIMARY KEY, name nvarchar(50) NOT NULL)"
  , "CREATE TABLE #child (id int NOT NULL PRIMARY KEY, detail nvarchar(50) NOT NULL)"
  , "INSERT INTO #parent SELECT value, CONCAT(N'parent-', value) FROM GENERATE_SERIES(1, 1000)"
  , "INSERT INTO #child SELECT value, CONCAT(N'child-', value) FROM GENERATE_SERIES(1, 1000)"
  ]

lookupChild :: Connection -> Int32 -> IO Int
lookupChild conn i = do
  Only (d :: Text) <- query1 conn ("SELECT detail FROM #child WHERE id = " <> param i)
  pure (T.length d)

-- | The parents read into a list, then one query each.
listFirst :: Connection -> IO Int
listFirst conn = do
  parents <- query conn "SELECT id, name FROM #parent ORDER BY id" :: IO [(Int32, Text)]
  sum <$> mapM (\(i, _) -> lookupChild conn i) parents

-- | One query per parent while the parents' stream is open (MARS).
nested :: Connection -> IO Int
nested conn = withQueryS conn "SELECT id, name FROM #parent ORDER BY id" $ \parents ->
  S.sum_ (S.mapM (\(i :: Int32, _ :: Text) -> lookupChild conn i) parents)

connectInfoFromEnv :: String -> IO ConnectInfo
connectInfoFromEnv password = do
  host <- var "HMSSQL_TEST_HOST" "::1"
  port <- var "HMSSQL_TEST_PORT" "1433"
  user <- var "HMSSQL_TEST_USER" "sa"
  database <- var "HMSSQL_TEST_DATABASE" "hmssql_test"
  cert <- lookupEnv "HMSSQL_TEST_CERT"
  tlsHost <- var "HMSSQL_TEST_TLS_HOSTNAME" "localhost"
  serverName <- var "HMSSQL_TEST_SERVER_NAME" ""
  encryption <- var "HMSSQL_TEST_ENCRYPTION" "strict"
  pure defaultConnectInfo
    { connectHost = host
    , connectPort = port
    , connectUser = user
    , connectPassword = T.pack password
    , connectDatabase = database
    , connectServerName = serverName
    , connectEncryption = case encryption of
        "on" -> EncryptOn
        "req" -> EncryptReq
        "off" -> EncryptOff
        "notsup" -> EncryptNotSup
        _ -> EncryptStrict
    , connectTls = defaultTlsSettings
        { tlsCaCertificateFiles = maybe [] pure cert
        , tlsHostNameInCertificate = if T.null tlsHost then Nothing else Just tlsHost
        }
    }
  where
    var name def = maybe def T.pack <$> lookupEnv name
