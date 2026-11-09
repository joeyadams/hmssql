-- | Benchmarks against a live server: request round trips, row decoding,
-- parameters, inserts, large values, connecting and session reuse.  They
-- run when @HMSSQL_TEST_PASSWORD@ is set, on the connection the test
-- suite's variables describe (@HMSSQL_TEST_HOST@, @_PORT@, @_USER@,
-- @_DATABASE@, @_CERT@, @_TLS_HOSTNAME@, @_SERVER_NAME@, @_ENCRYPTION@;
-- see docs/dev/testing.md), and are skipped with a note otherwise.
--
-- Each group has a connection of its own, and the data it reads lives in
-- @#temp@ tables that connection creates when it opens (10,000 rows of the
-- "Bench.Tokens" column types, 1000 rows of 50 columns, one 4 MB row of
-- LOBs), so nothing is left on the server.  The result sets of @query@
-- have the same names and shapes as "Bench.Decode"'s and "Bench.Mock"'s,
-- for comparison.
--
-- These are measured by the clock (@hmssql-bench/Main.hs@ sets the wall-time
-- mode for this group and "Bench.Mars"), so the server's time and the
-- network's are counted.  For the client's CPU alone, see "Bench.Mock".
module Bench.Live (benchmarks) where

import Control.DeepSeq (NFData (..))
import Control.Monad (forM_, void)
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Int (Int32, Int64)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Test.Tasty.Bench

import Hmssql
import Hmssql.Connection (cancelActiveStatement, reset)

import Hmssql.Query
import Hmssql.BulkCopy
import Hmssql.Types
import Bench.Encode (insertRow, insertRowParams, insertRowSql, insertRows, intParams, textParams)
import Bench.Tokens (Dataset (..), Typed (..), datasets)

-- | A connection, for 'envWithCleanup' (which wants an 'NFData' resource).
newtype Conn = Conn Connection

instance NFData Conn where
  rnf (Conn c) = c `seq` ()

benchmarks :: IO [Benchmark]
benchmarks = lookupEnv "HMSSQL_TEST_PASSWORD" >>= \case
  Nothing -> do
    hPutStrLn stderr "HMSSQL_TEST_PASSWORD is not set: the benchmarks against a server are skipped"
    pure []
  Just password -> do
    info <- connectInfoFromEnv password
    statementNumber <- newIORef (0 :: Int)
    pure
      [ bgroup "Live"
          [ withConn info [benchTable] $ \conn -> bgroup "round trip"
              [ bench "SELECT 1 as a batch" $ whnfIO (query1 conn "SELECT 1" :: IO (Only Int32))
              , bench "SELECT @p1 through sp_executesql" $ whnfIO (query1 conn ("SELECT " <> param (1 :: Int32)) :: IO (Only Int32))
              , bench "execute of a no-op batch" $ whnfIO (execute conn "SET NOCOUNT ON")
              , bench "SELECT a row by primary key" $
                  whnfIO (query1 conn ("SELECT i, ns, d FROM #bench WHERE id = " <> param (4321 :: Int32)) :: IO (Int32, Text, Decimal))
              ]
          , withConn info [] $ \conn -> bgroup "decode 10000 rows"
              [ bench "(Int32, Text) with query" $ nfIO (query conn tenThousand :: IO [(Int32, Text)])
              , bench "(Int32, Text) folded, counted" $
                  whnfIO (queryFold conn tenThousand (0 :: Int) (\n (_ :: (Int32, Text)) -> pure (n + 1)))
              , bench "(Int32, Text) streamed, summed" $
                  whnfIO (queryS conn tenThousand >>= S.sum_ . S.map (\(i :: Int32, _ :: Text) -> fromIntegral i :: Int64))
              , bench "SqlRow with queryMulti" $ nfIO (concatMap resultRows <$> queryMulti conn tenThousand)
              ]
          , withConn info [benchTable, lobTable, wideTable] $ \conn -> bgroup "query"
              [ bgroup name
                  [ case dsTyped (dataset dsKey) of
                      Typed _ dec -> bench "typed" $ nfIO (queryWith dec conn sql)
                  , bench "SqlRow" $ nfIO (concatMap resultRows <$> queryMulti conn sql)
                  ]
              | (name, dsKey, sql) <- selects
              ]
          , withConn info [benchTable] $ \conn -> bgroup "params"
              [ bench "1 int param" $ whnfIO (query1 conn (intParams 1) :: IO (Only Int))
              , bench "100 int params" $ whnfIO (query1 conn (intParams 100) :: IO (Only Int))
              , bench "2000 int params" $ whnfIO (query1 conn (intParams 2000) :: IO (Only Int))
              , bench "2000 nvarchar(20) params" $ whnfIO (query1 conn (textParams 2000) :: IO (Only Int))
                -- A statement the server hasn't seen, run with strings of
                -- ten lengths: if the declaration follows the length, that
                -- is ten compilations; if not, one.  Server time.
              , bench "a new statement with 10 string lengths" $ whnfIO $ do
                  n <- atomicModifyIORef' statementNumber (\k -> (k + 1, k))
                  forM_ [1 .. 10] $ \len -> query1 conn
                    (mkQuery ("SELECT COUNT(*) FROM #bench WHERE ns = @p1 AND i > 0 /* " <> T.pack (show n) <> " */")
                      (Only (T.replicate len "x"))) :: IO (Only Int)
              ]
          , withConn info [] $ \conn -> bgroup "large params"
              [ bench "varbinary(max) 4MB" $
                  whnfIO (query1 conn (mkQuery "SELECT DATALENGTH(@p1)" (Only (B.replicate (4 * 1024 * 1024) 0x78))) :: IO (Only Int64))
              , bench "nvarchar(max) 1M chars" $
                  whnfIO (query1 conn (mkQuery "SELECT LEN(@p1)" (Only (T.replicate (1024 * 1024) "y"))) :: IO (Only Int64))
                -- Read: an output parameter (RETURNVALUE) set by the server.
              , bench "varbinary(max) 4MB OUTPUT" $ nfIO $ outputValue conn B.empty
                  "SET @out = CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'x'), 4194304))"
                  "@out varbinary(max) OUTPUT"
              , bench "nvarchar(max) 4MB OUTPUT" $ nfIO $ outputValue conn T.empty
                  "SET @out = REPLICATE(CONVERT(nvarchar(max), N'y'), 2097152)"
                  "@out nvarchar(max) OUTPUT"
              ]
          , withConn info [insertTable] $ \conn -> bgroup "insert"
              [ bench "100 rows, one INSERT of 300 params" $
                  whnfIO (execute conn ("TRUNCATE TABLE #t; " <> insertRows 100))
              , bench "100 rows, one INSERT each" $ whnfIO (insertEach conn)
              , bench "100 rows, one INSERT each, in a transaction" $ whnfIO (withTransaction conn (insertEach conn))
              , bench "100 rows, executeStatements of one INSERT each" $ whnfIO (truncateT conn >> executeStatements conn (map insertRow [1 .. 100]))
              , bench "100 rows, executeMany" $ whnfIO (truncateT conn >> executeMany conn insertRowSql (map insertRowParams [1 .. 100]))
              , bench "100 rows, bulkInsert" $ whnfIO (truncateT conn >> bulkInsert conn "#t" (map insertRowParams [1 .. 100]))
              , bench "100 rows, bulkInsert (columns described)" $ whnfIO (truncateT conn >> bulkInsertWith tCopy conn (map insertRowParams [1 .. 100]))
              , bench "1000 rows, one INSERT each" $ whnfIO (truncateT conn >> mapM_ (execute conn . insertRow) [1 .. 1000])
              , bench "1000 rows, executeMany" $ whnfIO (truncateT conn >> executeMany conn insertRowSql (map insertRowParams [1 .. 1000]))
                -- 3000 parameters don't fit in one statement (2100 at most).
              , bench "1000 rows, executeStatements of two INSERTs of 500 rows" $
                  whnfIO (truncateT conn >> executeStatements conn [insertRows 500, insertRows 500])
              , bench "1000 rows, bulkInsert" $ whnfIO (truncateT conn >> bulkInsert conn "#t" (map insertRowParams [1 .. 1000]))
              , bench "10000 rows, executeMany" $ whnfIO (truncateT conn >> executeMany conn insertRowSql (map insertRowParams [1 .. 10000]))
              , bench "10000 rows, bulkInsert" $ whnfIO (truncateT conn >> bulkInsert conn "#t" (map insertRowParams [1 .. 10000]))
              ]
          , withConn info [benchTable] $ \conn -> bgroup "session"
              [ bench "stream 10 of 10000 rows, then cancelActiveStatement" $ whnfIO $ do
                  queryS conn "SELECT i FROM #bench" >>= S.effects . S.take 10 . S.map (\(Only (_ :: Int32)) -> ())
                  cancelActiveStatement conn
              , bench "withTransaction around SELECT 1" $ whnfIO (withTransaction conn (query1 conn "SELECT 1" :: IO (Only Int32)))
              ]
            -- A reset drops the temp tables: a connection of its own.
          , withConn info [] $ \conn -> bgroup "reset"
              [ bench "reset, then SELECT 1" $ whnfIO (reset conn >> (query1 conn "SELECT 1" :: IO (Only Int32)))
                -- 'renew' works on any handle, so each round starts from
                -- the one 'withConn' gave, stale after the first round.
              , bench "renew, release, renew, then SELECT 1" $ whnfIO $ do
                  _ <- renew conn >>= release
                  c <- renew conn
                  query1 c "SELECT 1" :: IO (Only Int32)
              , bench "renew, BEGIN TRANSACTION, release (resets at once)" $ whnfIO $ do
                  c <- renew conn
                  _ <- execute c "BEGIN TRANSACTION"
                  release c
              ]
          , bgroup "connect"
              [ bench "connect+close" $ whnfIO (connect info >>= close)
              ]
          ]
      ]
  where
    tenThousand = "SELECT TOP 10000 a.column_id, a.name FROM sys.all_columns a CROSS JOIN sys.all_columns b"

    -- The name, the "Bench.Tokens" dataset whose decoder reads it, the query.
    selects :: [(String, String, Query)]
    selects =
      [ same "int bigint x10000" "SELECT i, b FROM #bench"
      , same "nvarchar(50) x10000" "SELECT ns FROM #bench"
      , same "nvarchar(1000) x1000" "SELECT nl FROM #bench WHERE id <= 1000"
      , same "varchar(100) cp1252 x10000" "SELECT vc FROM #bench"
      , same "varchar(100) utf8 x10000" "SELECT vu FROM #bench"
      , same "decimal(18,4) x10000" "SELECT d FROM #bench"
      , same "datetime2 datetimeoffset x10000" "SELECT dt2, dto FROM #bench"
      , same "uniqueidentifier x10000" "SELECT g FROM #bench"
      , same "nvarchar(max) short x10000" "SELECT nm FROM #bench"
      , same "varbinary(max) 4MB x1" "SELECT vb FROM #lob"
      , same "nvarchar(max) 4MB x1" "SELECT nv FROM #lob"
        -- The server chooses between ROW and NBCROW itself.
      , ("nullable half NULL x10000", "nullable half NULL NBCROW x10000", "SELECT ni, nns, nd, ndt, nb FROM #bench")
      , same "50 columns x1000" "SELECT * FROM #wide"
      ]
      where
        same name sql = (name, name, sql)

    dataset key = case filter ((== key) . dsName) datasets of
      ds : _ -> ds
      [] -> error ("Bench.Live: no dataset " ++ show key)

    truncateT conn = void $ execute conn "TRUNCATE TABLE #t"

    -- #t with its columns described, so bulkInsert doesn't query them.
    tCopy = (bulkCopy "#t")
      { bulkColumns = DescribedColumns
          [ BulkColumn "a" (TIIntN 4) False False
          , BulkColumn "b" (TINVarChar (2 * 50) (Collation 0 0)) False False
          , BulkColumn "c" (TIDecimalN 10 2) False False ] }

    insertEach conn = do
      void $ execute conn "TRUNCATE TABLE #t"
      forM_ [1 .. 100 :: Int32] $ \i -> execute conn $
        "INSERT INTO #t (a, b, c) VALUES (" <> param i <> ", " <> param ("row " <> T.pack (show i)) <> ", " <> param (fromIntegral i + 0.99 :: Double) <> ")"

-- | A connection for a group of benchmarks, with these tables created.
-- | The value of the one output parameter of a statement run by
-- @sp_executesql@ with this declaration (of the type of the given value).
outputValue :: (ToSqlField a, FromSqlField a) => Connection -> a -> Text -> Text -> IO a
outputValue conn v stmt decl = do
  res <- callProcedure conn "sp_executesql" [inParam "" stmt, inParam "" decl, outParam "@out" v]
  case map decodeReturnValue (procOutputValues res) of
    [Right x] -> pure x
    r -> fail ("outputValue: " ++ show (length r) ++ " values, or not decoded")

withConn :: ConnectInfo -> [[Text]] -> (Connection -> Benchmark) -> Benchmark
withConn info tables k =
  envWithCleanup
    (connect info >>= \c -> mapM_ (execute c . rawSql) (concat tables) >> pure (Conn c))
    (\(Conn c) -> close c)
    (\ ~(Conn c) -> k c)

-- | 10,000 rows of the "Bench.Tokens" column types (@nl@ only in the first
-- 1000), and the nullable columns, NULL in every second or third row.
benchTable :: [Text]
benchTable =
  [ "CREATE TABLE #bench (\
    \ id int NOT NULL PRIMARY KEY, i int NOT NULL, b bigint NOT NULL,\
    \ ns nvarchar(50) NOT NULL, nl nvarchar(1000) NOT NULL,\
    \ vc varchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,\
    \ vu varchar(100) COLLATE Latin1_General_100_CI_AS_SC_UTF8 NOT NULL,\
    \ d decimal(18,4) NOT NULL, dt2 datetime2 NOT NULL, dto datetimeoffset NOT NULL,\
    \ g uniqueidentifier NOT NULL, nm nvarchar(max) NOT NULL,\
    \ ni int NULL, nns nvarchar(50) NULL, nd decimal(18,4) NULL, ndt datetime2 NULL, nb bigint NULL)"
  , "INSERT INTO #bench SELECT value, value, CAST(value AS bigint) * 1000000007,\
    \ CONCAT(N'name-', value), CASE WHEN value <= 1000 THEN REPLICATE(CAST(value % 10 AS nchar(1)), 100) + REPLICATE(N'x', 900) ELSE N'' END,\
    \ CONCAT('Caf', CHAR(233), ' cr', CHAR(232), 'me ', value),\
    \ CONCAT(N'Stra', NCHAR(223), N'e ', NCHAR(8364), N' ', NCHAR(26085), NCHAR(26412), N' ', value),\
    \ CAST(value AS decimal(18,4)) * 1234.5678 - 500000,\
    \ DATEADD(day, value % 3650, CAST('2020-01-01T12:34:56.1234567' AS datetime2)),\
    \ TODATETIMEOFFSET(DATEADD(second, value % 86400, CAST('2026-01-01T00:00:00.1234567' AS datetime2)), 120),\
    \ NEWID(), CONCAT(N'name-', value),\
    \ CASE WHEN value % 2 = 0 THEN NULL ELSE value END,\
    \ CASE WHEN value % 3 = 0 THEN NULL ELSE CONCAT(N'name-', value) END,\
    \ CASE WHEN value % 2 = 0 THEN NULL ELSE CAST(value AS decimal(18,4)) * 1234.5678 END,\
    \ CASE WHEN value % 3 = 0 THEN NULL ELSE DATEADD(day, value % 3650, CAST('2020-01-01T12:34:56.1234567' AS datetime2)) END,\
    \ CASE WHEN value % 2 = 0 THEN NULL ELSE CAST(value AS bigint) * 1000000007 END\
    \ FROM GENERATE_SERIES(1, 10000)"
  ]

-- | One row: a 4 MB @varbinary(max)@ and a 2M-character @nvarchar(max)@.
lobTable :: [Text]
lobTable =
  [ "CREATE TABLE #lob (vb varbinary(max) NOT NULL, nv nvarchar(max) NOT NULL)"
  , "INSERT INTO #lob VALUES (CAST(REPLICATE(CAST('x' AS varchar(max)), 4194304) AS varbinary(max)),\
    \ REPLICATE(CAST(N'y' AS nvarchar(max)), 2097152))"
  ]

-- | 1000 rows of 50 columns: ten each of int, bigint, nvarchar(20),
-- decimal(18,4) and datetime2, like "Bench.Tokens"'s.
wideTable :: [Text]
wideTable =
  [ "CREATE TABLE #wide (" <> T.intercalate ", " (concatMap column [1 .. 10 :: Int]) <> ")"
  , "INSERT INTO #wide SELECT " <> T.intercalate ", " (concatMap value [1 .. 10 :: Int]) <> " FROM GENERATE_SERIES(1, 1000)"
  ]
  where
    column j = let n = T.pack (show j) in
      [ "i" <> n <> " int NOT NULL", "b" <> n <> " bigint NOT NULL", "s" <> n <> " nvarchar(20) NOT NULL"
      , "d" <> n <> " decimal(18,4) NOT NULL", "t" <> n <> " datetime2 NOT NULL" ]
    value j = let n = T.pack (show j) in
      [ "value + " <> n, "CAST(value AS bigint) * 1000000007 + " <> n, "CONCAT(N'name-', value)"
      , "CAST(value AS decimal(18,4)) * 1234.5678", "DATEADD(day, value % 3650, CAST('2020-01-01T12:34:56.1234567' AS datetime2))" ]

insertTable :: [Text]
insertTable = ["CREATE TABLE #t (a int NOT NULL, b nvarchar(50) NOT NULL, c decimal(10,2) NOT NULL)"]

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
