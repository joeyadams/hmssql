{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
module Main where
import Control.Concurrent
import Control.Concurrent.Async
import Control.DeepSeq
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import Data.Functor.Identity
import Data.IORef
import Data.Maybe
import Data.Ratio
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
import GHC.Clock (getMonotonicTimeNSec)
import qualified Database.ODBC.SQLServer as O
import System.Environment
import System.Exit
import System.IO
import System.Timeout
import Text.Printf

type Counts = IORef (Int,Int)
check :: Counts -> String -> Bool -> IO ()
check counts name ok = do
  modifyIORef' counts (\(n,f) -> (n+1, f + if ok then 0 else 1))
  putStrLn $ (if ok then "PASS " else "FAIL ") ++ name

section :: Counts -> String -> IO () -> IO ()
section counts label action = do
  putStrLn $ "SECTION " ++ label
  action `catch` \(e :: SomeException) -> do
    putStrLn $ "EXCEPTION " ++ label ++ " " ++ displayException e
    check counts (label ++ " completed") False

setting :: String -> String -> IO String
setting key def = fromMaybe def <$> lookupEnv key

connectionString :: Bool -> IO Text
connectionString mars = do
  password <- getEnv "HMSSQL_TEST_PASSWORD"
  host <- setting "ODBC_TEST_HOST" "localhost"
  port <- setting "HMSSQL_TEST_PORT" "1433"
  user <- setting "HMSSQL_TEST_USER" "sa"
  db <- setting "HMSSQL_TEST_DATABASE" "master"
  cert <- setting "HMSSQL_TEST_CERT" ""
  encrypt <- setting "ODBC_TEST_ENCRYPT" "strict"
  pin <- setting "ODBC_TEST_PIN_CERT" "1"
  let attrs = [("Driver","ODBC Driver 18 for SQL Server"), ("Server","tcp:"++host++","++port),
               ("UID",user), ("PWD",password), ("Database",db), ("Encrypt",encrypt),
               ("TrustServerCertificate","No"), ("MARS_Connection",if mars then "Yes" else "No"),
               ("APP","hmssql-haskell-odbc-experiment"), ("LongAsMax","Yes")]
               ++ [("ServerCertificate",cert) | pin == "1"]
      quote = T.replace "}" "}}" . T.pack
  pure $ T.concat [T.pack k <> "={" <> quote v <> "};" | (k,v) <- attrs]

withConn :: Bool -> (O.Connection -> IO a) -> IO a
withConn mars f = connectionString mars >>= \cs -> bracket (O.connect cs) O.close f

q :: Text -> O.Query
q = O.rawUnescapedText

clock :: IO Double
clock = (/1e9) . fromIntegral <$> getMonotonicTimeNSec

timed :: IO a -> IO (Double,a)
timed f = do start <- clock; x <- f; end <- clock; pure (end-start,x)

scalarInt :: O.Connection -> O.Query -> IO Int
scalarInt c sql = do
  xs <- O.query c sql :: IO [Int]
  case xs of [x] -> pure x; _ -> error "expected one integer"

sample :: Text
sample = "Renée / Łódź / 東京 / مرحبا / 😀 / café"

dates :: [(String,Int)]
dates = [("2026-10-29 14:35:42.1234567",-240), ("2026-07-01 09:12:33.7654321",330),
         ("2026-01-15 08:00:00",-210), ("2026-03-08 01:59:59.9999999",-300),
         ("2026-10-29 18:35:42.0000001",0)]

dateTests :: Counts -> O.Connection -> IO ()
dateTests counts c = do
  O.exec c "CREATE TABLE #dates (v datetimeoffset(7))"
  forM_ dates $ \(str,offset) -> do
    let local = read str :: LocalTime
        zt = ZonedTime local (minutesToTimeZone offset)
        insert = "INSERT INTO #dates VALUES (" <> O.toSql (O.Datetimeoffset zt) <> ")"
    putStrLn $ "OBS datetimeoffset rendered=" ++ T.unpack (O.renderQuery insert)
    O.exec c insert
    rows <- O.query c "SELECT v FROM #dates" :: IO [Identity ZonedTime]
    let exact = case rows of
          [Identity actual] -> zonedTimeToLocalTime actual == local && timeZoneMinutes (zonedTimeZone actual) == offset
          _ -> False
    putStrLn $ "OBS datetimeoffset result=" ++ show rows
    check counts ("datetimeoffset local fields, fraction and original offset: " ++ str) exact
    O.exec c "DELETE FROM #dates"
  nulls <- O.query c "SELECT CAST(NULL AS datetimeoffset(7))" :: IO [Maybe O.Datetimeoffset]
  check counts "datetimeoffset NULL" (nulls == [Nothing])
  let dt = read "2026-10-29 14:35:42.1234567" :: LocalTime
  returned <- O.query c ("SELECT CAST(" <> O.toSql (O.Datetime2 dt) <> " AS datetime2(7))") :: IO [LocalTime]
  check counts "datetime2 100ns precision" (returned == [dt])

-- Exact expected values: parse digits into an Integer and retain scale.
decimalRational :: String -> Rational
decimalRational str = sign * (read digits % (10 ^ scale))
  where
    sign = if take 1 str == "-" then -1 else 1
    unsigned = if take 1 str == "-" then drop 1 str else str
    (whole, frac) = break (=='.') unsigned
    scale = length (drop 1 frac)
    digits = (if null whole then "0" else whole) ++ drop 1 frac

decimalTests :: Counts -> O.Connection -> IO ()
decimalTests counts c = forM_ fixtures $ \(p,s,txt) -> do
  let ty = T.pack $ "decimal("++show p++","++show s++")"
      select = q $ "SELECT CAST(" <> T.pack txt <> " AS " <> ty <> ")"
  rows <- O.query c select :: IO [O.Value]
  putStrLn $ "OBS decimal type=" ++ T.unpack ty ++ " input=" ++ txt ++ " output=" ++ show rows
  case rows of
    [O.DoubleValue d] -> do
      check counts ("decimal exact rational representation: " ++ txt) (toRational d == decimalRational txt)
      actual <- O.query c ("SELECT CONVERT(nvarchar(100), CAST(" <> O.toSql d <> q (" AS "<>ty<>"))")) :: IO [Text]
      putStrLn $ "OBS decimal writeback=" ++ show actual ++ " rendered=" ++ T.unpack (O.renderQuery (O.toSql d))
      check counts ("decimal read/write retains stored value and scale: " ++ txt) (actual == [T.pack txt])
    _ -> check counts "decimal has a supported result representation" False
  exactText <- O.query c (q $ "SELECT CONVERT(nvarchar(100), CAST("<>T.pack txt<>" AS "<>ty<>"))") :: IO [Text]
  check counts ("explicit SQL text cast preserves decimal: " ++ txt) (exactText == [T.pack txt])
  where fixtures :: [(Int,Int,String)]
        fixtures = [(9,2,"1234.56"),(9,2,"-19.95"),(9,2,"0.00"),(9,2,"0.01"),
                    (18,4,"12345678901234.5678"),(18,4,"42.5000"),(19,6,"1.234567"),
                    (28,10,"987654321012345678.1234567890"),
                    (38,18,"12345678901234567890.123456789012345678"),
                    (38,0,"12345678901234567890123456789012345678")]

unicodeTests :: Counts -> O.Connection -> IO ()
unicodeTests counts c = do
  O.exec c "CREATE TABLE #text (n nvarchar(max), v varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8)"
  forM_ [sample,T.replicate 4096 sample,"", "O'Brien 😀"] $ \txt -> do
    O.exec c ("INSERT INTO #text VALUES (" <> O.toSql txt <> "," <> O.toSql txt <> ")")
    rows <- O.query c "SELECT n,v FROM #text" :: IO [(Text,B.ByteString)]
    check counts ("Unicode nvarchar Text + UTF8 varchar bytes, chars="++show (T.length txt))
      (rows == [(txt,TE.encodeUtf8 txt)])
    decoded <- O.query c "SELECT CONVERT(nvarchar(max),v) FROM #text" :: IO [Text]
    check counts "explicit SQL Unicode cast preserves UTF8 varchar" (decoded == [txt])
    O.exec c "DELETE FROM #text"
  O.exec c "INSERT INTO #text VALUES (NULL,NULL)"
  nulls <- O.query c "SELECT n,v FROM #text" :: IO [(Maybe Text,Maybe B.ByteString)]
  check counts "Unicode NULL distinct from empty" (nulls == [(Nothing,Nothing)])
  direct <- try (O.query c "SELECT CAST('hello' AS varchar(10))" :: IO [Text]) :: IO (Either O.ODBCException [Text])
  putStrLn $ "OBS varchar requested as Text=" ++ show direct
  decNull <- O.query c "SELECT CAST(NULL AS decimal(18,4))" :: IO [O.Value]
  check counts "decimal NULL preserved" (decNull == [O.NullValue])

-- All delayed server batches finish within four seconds even when the
-- Haskell timeout cannot cancel them. Temp-table writes detect real cancellation.
cancelTests :: Counts -> Bool -> O.Connection -> IO ()
cancelTests counts mars c = do
  spid <- scalarInt c "SELECT @@SPID"
  O.exec c "SET NOCOUNT ON; CREATE TABLE #late (id int)"
  withConn False $ \observer -> do
    done <- newEmptyMVar
    worker <- async $ do
      result <- timed $ timeout 250000 $ O.exec c "WAITFOR DELAY '00:00:04'; INSERT INTO #late VALUES (1)"
      putMVar done ()
      pure result
    threadDelay 1000000
    running <- scalarInt observer (q $ "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id=" <> T.pack (show spid) <> " AND wait_type='WAITFOR'")
    finished <- not <$> isEmptyMVar done
    putStrLn $ "OBS timeout at_1s running_waitfor="++show running++" caller_finished="++show finished
    (elapsed, result) <- wait worker
    printf "OBS timeout mars=%s requested_s=0.25 elapsed_s=%.6f result=%s\n" (show mars) elapsed (show result)
    check counts "Haskell timeout returns within 1 second" (elapsed < 1 && result == Nothing)
    writes <- scalarInt c "SELECT COUNT(*) FROM #late"
    check counts "timeout prevents post-delay server write" (writes == 0)
    reuse counts c spid "after timeout"
    O.exec c "DELETE FROM #late"
    started <- newEmptyMVar
    target <- async $ putMVar started () >> O.exec c "WAITFOR DELAY '00:00:04'; INSERT INTO #late VALUES (2)"
    takeMVar started
    let awaitWait 0 = pure False
        awaitWait n = do
          waiting <- scalarInt observer (q $ "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id="<>T.pack(show spid)<>" AND wait_type='WAITFOR'")
          if waiting > 0 then pure True else threadDelay 10000 >> awaitWait (n-1 :: Int)
    observed <- awaitWait 100
    check counts "observer sees running query before killThread" observed
    killStart <- clock
    (killTime,()) <- timed $ killThread (asyncThreadId target)
    _ <- waitCatch target
    killEnd <- clock
    printf "OBS killThread mars=%s call_s=%.6f completion_s=%.6f\n" (show mars) killTime (killEnd-killStart)
    check counts "killed query's worker finishes within 1 second" (killEnd-killStart < 1)
    afterKill <- scalarInt c "SELECT COUNT(*) FROM #late"
    check counts "killThread prevents post-delay server write" (afterKill == 0)
    reuse counts c spid "after killThread"
  (stopTime, total) <- timed $ O.stream c
    "SELECT TOP (100000) a.object_id, REPLICATE('x',1000) FROM sys.all_objects a CROSS JOIN sys.all_objects b"
    (\n (_ :: (Int,B.ByteString)) -> pure $ if n == (9::Int) then O.Stop 10 else O.Continue (n+1)) 0
  printf "OBS early_stream_stop mars=%s total_s=%.6f rows=%d\n" (show mars) stopTime total
  check counts "stream Stop returns after ten rows promptly" (total == 10 && stopTime < 1)
  reuse counts c spid "after early stream Stop"
  exception <- try $ O.stream c "SELECT TOP (10000) object_id FROM sys.all_objects"
      (\(_ :: ()) (_ :: Int) -> throwIO (userError "test callback exception")) ()
  check counts "stream callback exception reaches caller" (case exception of Left (_ :: IOException) -> True; _ -> False)
  reuse counts c spid "after stream callback exception"
  unless mars $ do
    O.exec c "BEGIN TRANSACTION; INSERT INTO #late VALUES (3)"
    (elapsed, _) <- timed $ timeout 250000 (O.exec c "WAITFOR DELAY '00:00:02'")
    state <- O.query c "SELECT XACT_STATE(), @@TRANCOUNT" :: IO [(Int,Int)]
    printf "OBS timeout_transaction elapsed_s=%.6f state=%s\n" elapsed (show state)
    O.exec c "ROLLBACK"
    remaining <- scalarInt c "SELECT COUNT(*) FROM #late WHERE id=3"
    check counts "caller rollback after interruption undoes write" (remaining == 0)
    reuse counts c spid "after transaction rollback"
  where
    reuse cs conn sid label = do
      v <- scalarInt conn "SELECT 42"
      sid' <- scalarInt conn "SELECT @@SPID"
      check cs ("same connection usable "++label) (v == 42 && sid == sid')

marsTest :: Counts -> Bool -> O.Connection -> IO ()
marsTest counts mars c = do
  gate <- newEmptyMVar
  entered <- newEmptyMVar
  streamWorker <- async $ O.stream c
    "SELECT TOP (10000) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) FROM sys.all_objects a CROSS JOIN sys.all_objects b"
    (\(n,total) (i :: Int) -> do
      when (n == 0) (putMVar entered () >> takeMVar gate)
      pure $ O.Continue (n+1,total+i)) (0::Int,0::Int)
  takeMVar entered
  (elapsed, nested) <- timed $ timeout 300000 (scalarInt c "SELECT 42")
  printf "OBS overlap mars=%s second_query_s=%.6f second_result=%s\n" (show mars) elapsed (show nested)
  putMVar gate ()
  streamed <- wait streamWorker
  check counts "stream completes after callback gate released" (streamed == (10000,50005000))
  when mars $ check counts "MARS permits another query while a stream is open" (nested == Just 42)
  v <- scalarInt c "SELECT 42"
  check counts "connection reusable after overlapping-query attempt" (v == 42)

benchmark :: Counts -> Bool -> O.Connection -> IO ()
benchmark counts mars c = do
  O.exec c "SET NOCOUNT ON; CREATE TABLE #perf (id bigint NOT NULL, txt nvarchar(100) NOT NULL, dto datetimeoffset(7) NOT NULL)"
  O.exec c ("INSERT INTO #perf SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), " <> O.toSql sample <>
    ", CAST('2026-10-29T12:34:56.1234567+05:30' AS datetimeoffset(7)) FROM sys.all_objects a CROSS JOIN sys.all_objects b")
  let sql = "SELECT id, txt, dto FROM #perf"
      validate (i,t,O.Datetimeoffset z) = i >= 1 && i <= 100000 && t == sample &&
        zonedTimeToLocalTime z == (read "2026-10-29 12:34:56.1234567" :: LocalTime) && timeZoneMinutes (zonedTimeZone z) == 330
      step (!n,!total,!valid) row@(i,_,_) = pure $ O.Continue (n+1,total+i,valid && validate row)
  forM_ [-1..4::Int] $ \roundNo -> do
    forM_ (if odd roundNo then [True,False] else [False,True]) $ \streaming -> do
      (elapsed,(n,total,valid)) <- timed $ do
        result <- if streaming
          then O.stream c sql step (0::Int,0::Int,True)
          else do
            rows <- O.query c sql :: IO [(Int,Text,O.Datetimeoffset)]
            evaluate $ foldl' (\(!count,!acc,!ok) row@(i,_,_) -> (count+1,acc+i,ok && validate row)) (0,0,True) rows
        evaluate (force result)
      check counts "benchmark mixed rows verified" (n == 100000 && total == 5000050000 && valid)
      when (roundNo >= 0) $ printf "BENCH fetch mars=%d api=%s round=%d rows=100000 seconds=%.6f rows_per_sec=%.0f\n"
        (fromEnum mars) (if streaming then "stream" else "query" :: String) roundNo elapsed (100000/elapsed)
    (elapsed,values) <- timed $ replicateM 200 (scalarInt c "SELECT 1")
    check counts "benchmark SELECT 1 values" (all (==1) values)
    when (roundNo >= 0) $ printf "BENCH select1 mars=%d round=%d iterations=200 us_per_query=%.3f\n" (fromEnum mars) roundNo (elapsed*1e6/200)
    (connections,()) <- timed $ replicateM_ 10 (withConn mars (const $ pure ()))
    when (roundNo >= 0) $ printf "BENCH connect_close mars=%d round=%d iterations=10 ms_per_connection=%.3f\n" (fromEnum mars) roundNo (connections*100)
  let bytes = B.pack [fromIntegral (i*37+i `div` 256) | i <- [0..4*1024*1024-1::Int]]
  _ <- evaluate (force bytes)
  O.exec c "CREATE TABLE #blob (v varbinary(max))"
  forM_ [-1..4::Int] $ \roundNo -> do
    O.exec c "DELETE FROM #blob"
    (up,()) <- timed $ O.exec c ("INSERT INTO #blob VALUES ("<>O.toSql (O.Binary bytes)<>")")
    (down,values) <- timed $ O.query c "SELECT v FROM #blob" :: IO (Double,[O.Binary])
    check counts "4MiB binary exact" (values == [O.Binary bytes])
    when (roundNo >= 0) $ printf "BENCH blob mars=%d round=%d upload_MiB_per_sec=%.3f download_MiB_per_sec=%.3f\n" (fromEnum mars) roundNo (4/up) (4/down)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  unless (args `elem` [[],["--connect-only"],["--types-only"],["--tests-only"],["--bench-only"]]) $
    die "Usage: odbc-haskell-probe [--connect-only|--types-only|--tests-only|--bench-only]"
  counts <- newIORef (0,0)
  putStrLn "ENV package=odbc-0.3.0 api=Database.ODBC.SQLServer unmodified_hackage_release=True"
  putStrLn $ "ENV mode="++show args
  withConn False $ \c -> do
    meta <- O.query c "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(100)), CAST(DATABASEPROPERTYEX(DB_NAME(),'Collation') AS nvarchar(100))" :: IO [(Text,Text)]
    print meta
    let types = do
          section counts "datetime" (dateTests counts c)
          section counts "decimal" (decimalTests counts c)
          section counts "unicode" (unicodeTests counts c)
    case args of
      ["--connect-only"] -> scalarInt c "SELECT 42" >>= check counts "connect/query" . (==42)
      ["--types-only"] -> types
      ["--bench-only"] -> pure ()
      _ -> do
        types
        section counts "cancellation mars=0" (cancelTests counts False c)
        section counts "overlap mars=0" (marsTest counts False c)
        withConn True $ \m -> do
          section counts "cancellation mars=1" (cancelTests counts True m)
          section counts "overlap mars=1" (marsTest counts True m)
  when (null args || args == ["--bench-only"]) $
    forM_ [False,True] $ \mars -> withConn mars $ \c -> section counts ("benchmark mars="++show mars) (benchmark counts mars c)
  (n,f) <- readIORef counts
  printf "SUMMARY checks=%d failures=%d\n" n f
  when (f > 0) exitFailure
