{-# LANGUAGE BangPatterns, OverloadedStrings #-}
module Main where
import Hmssql.Tds.Client
import qualified Data.Binary.Put as P
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import Control.Exception
import GHC.Stats
import System.Environment
import System.Mem
main = do
  [count] <- getArgs
  let logins = [defaultLogin7 {l7UserName = T.pack ("user" ++ show i), l7AppName = "resource-probe", l7Database = "example"} | i <- [0..31 :: Int]]
  _ <- evaluate (loop logins 32)
  performGC
  before <- getRTSStats
  result <- evaluate (loop logins (read count))
  performGC
  after <- getRTSStats
  print (allocated_bytes after - allocated_bytes before, gcdetails_live_bytes (gc after), result)
loop :: [Login7] -> Int -> Int
loop logins n = go 0 0
  where
    go !i !acc | i == n = acc
               | otherwise = go (i+1) (acc + fromIntegral (B.length (P.runPut (putLogin7 (logins !! (i `mod` 32))))))
{-# NOINLINE loop #-}
