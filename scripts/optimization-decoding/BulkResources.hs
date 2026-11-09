{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications #-}
module Main where
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors
import TestConfig (defaultTestConnectInfo)
import qualified Streaming.Prelude as S
import Data.Int
import Data.Char (ord)
import Data.List (isPrefixOf)
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
main = defaultTestConnectInfo >>= \ci -> withConnection ci $ \conn -> do
  _ <- execute conn "CREATE TABLE #optimization_probe (v tinyint NOT NULL)"
  cols <- describeBulkColumns conn (bulkCopy "#optimization_probe")
  let bc = (bulkCopy "#optimization_probe") { bulkColumns = DescribedColumns cols }
  forM_ [False,True] $ \bad -> do
    let rows = [Only (if bad && i == 501 then 300 else 42 :: Int64) | i <- [0..999 :: Int]]
        action = do
          result <- try (bulkInsertSWith bc conn (S.each rows)) :: IO (Either EncodeError Int64)
          case result of
            Right n | not bad && n == 1000 -> pure ()
            Left (EncodeError msg) | bad && "bulk copy: row 501 (from 0)" `isPrefixOf` msg -> pure ()
            _ -> fail ("unexpected synthetic bulk result: " ++ show result)
          checksum <- evaluate (sum (map ord (show result)))
          pure checksum
        clear = void (execute conn "TRUNCATE TABLE #optimization_probe")
    _ <- evaluate (sum [v | Only v <- rows])
    _ <- action
    clear
    forM_ [1..3 :: Int] $ \iteration -> do
      performGC
      before <- getRTSStats
      checksum <- action
      performGC
      after <- getRTSStats
      saved <- query1 conn "SELECT COUNT_BIG(*), COALESCE(SUM(CONVERT(bigint,v)),0) FROM #optimization_probe" :: IO (Int64,Int64)
      print (bad,iteration,allocated_bytes after - allocated_bytes before,gcdetails_live_bytes (gc after),checksum,saved)
      clear
