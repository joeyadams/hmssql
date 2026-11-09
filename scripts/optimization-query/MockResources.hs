{-# LANGUAGE OverloadedStrings #-}
module Main where
import Bench.Mock
import Bench.Tokens
import Hmssql
import Hmssql.Query
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
import System.Environment
import Data.Int
main = do
 [mode] <- getArgs
 let body = if mode == "bare" || mode == "param" then tokenBytes [done 0] else responseBody (head datasets)
 bracket (startMock body) stopMock $ \m -> do
   let act = case mode of
        "bare" -> void (execute (mockConn m) "SELECT")
        "param" -> void (execute (mockConn m) ("SELECT " <> param (1::Int32)))
        "drain" -> void (execute (mockConn m) "SELECT")
        _ -> query (mockConn m) "SELECT" >>= evaluate . sum . map (\(x,y) -> fromIntegral (x::Int32)+(y::Int64)) >> pure ()
   act
   performGC
   before <- getRTSStats
   replicateM_ 100 act
   performGC
   after <- getRTSStats
   print (allocated_bytes after - allocated_bytes before,max_live_bytes after)
