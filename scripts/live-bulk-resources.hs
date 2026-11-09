{-# LANGUAGE OverloadedStrings #-}
-- Fixed-work client allocation/residency for the Live.insert 10,000-row shape.
-- Compile at -O1 with -threaded -rtsopts and packages hmssql, Decimal, and text.
-- Source ~/.hmssql-test-env, then run with +RTS -T -N1 -A4m. No clock is read.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (bracket, evaluate)
import Control.Monad (forM_, replicateM)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32, Int64)
import qualified Data.Text as T
import Foreign.StablePtr (freeStablePtr, newStablePtr)
import GHC.Stats
import Hmssql
import Hmssql.BulkCopy (bulkInsert)
import System.Environment (getEnv, lookupEnv)
import System.Mem (performGC)

main :: IO ()
main = do
  password <- getEnv "HMSSQL_TEST_PASSWORD"
  host <- var "HMSSQL_TEST_HOST" "::1"
  port <- var "HMSSQL_TEST_PORT" "1433"
  user <- var "HMSSQL_TEST_USER" "sa"
  database <- var "HMSSQL_TEST_DATABASE" "hmssql_test"
  cert <- lookupEnv "HMSSQL_TEST_CERT"
  tlsHost <- var "HMSSQL_TEST_TLS_HOSTNAME" "localhost"
  let info = defaultConnectInfo
        { connectHost = host, connectPort = port, connectUser = user
        , connectPassword = T.pack password, connectDatabase = database
        , connectEncryption = EncryptOn
        , connectTls = defaultTlsSettings
            { tlsCaCertificateFiles = maybe [] pure cert
            , tlsHostNameInCertificate = if T.null tlsHost then Nothing else Just tlsHost
            }
        }
      rows :: [(Int32, T.Text, Decimal)]
      rows = [(fromIntegral i, T.pack ("row " ++ show i), Decimal 2 (fromIntegral i * 100 + 99)) | i <- [1 .. 10000 :: Int]]
  _ <- evaluate (force rows)
  bracket (newStablePtr rows) freeStablePtr $ \_ ->
    bracket (connect info) close $ \conn -> do
      execute_ conn "CREATE TABLE #t (a int NOT NULL, b nvarchar(50) NOT NULL, c decimal(10,2) NOT NULL)"
      let load = execute_ conn "TRUNCATE TABLE #t" >> bulkInsert conn "#t" rows
      _ <- load
      performGC
      before <- getRTSStats
      counts <- replicateM 10 load
      forM_ counts $ \n -> if n == 10000 then pure () else fail "Unexpected bulk row count."
      Only actual <- query1 conn "SELECT COUNT_BIG(*) FROM #t" :: IO (Only Int64)
      if actual == 10000 then pure () else fail "The final bulk load has the wrong row count."
      performGC
      after <- getRTSStats
      putStrLn "rows_per_load,loads,allocated_per_load,max_live_bytes,max_rts_mem_bytes,live_before,live_after"
      putStrLn $ "10000,10," ++ show ((allocated_bytes after - allocated_bytes before) `div` 10)
        ++ "," ++ show (max_live_bytes after) ++ "," ++ show (max_mem_in_use_bytes after)
        ++ "," ++ show (gcdetails_live_bytes (gc before)) ++ "," ++ show (gcdetails_live_bytes (gc after))
  where
    var name fallback = maybe fallback T.pack <$> lookupEnv name
