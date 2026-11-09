{-# LANGUAGE BangPatterns #-}
module Main where
import Hmssql.SqlType
import qualified Data.Text as T
import Control.Exception
import GHC.Stats
import System.Environment
import System.Mem
main = do
  [count] <- getArgs
  performGC
  before <- getRTSStats
  _ <- evaluate (loop 35)
  performGC
  warm <- getRTSStats
  result <- evaluate (loop (read count))
  performGC
  after <- getRTSStats
  print (allocated_bytes warm - allocated_bytes before, allocated_bytes after - allocated_bytes warm, gcdetails_live_bytes (gc after), result)
loop :: Int -> Int
loop n = go 0 0
  where
    go !i !acc | i == n = acc
               | otherwise = go (i+1) (acc + T.length (dataTypeName (toEnum (i `mod` 35))))
{-# NOINLINE loop #-}
