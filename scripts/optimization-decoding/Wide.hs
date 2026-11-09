{-# LANGUAGE GADTs, FlexibleInstances #-}
module Main where
import Bench.Tokens
import Data.Int
import Hmssql.Decoding
import Hmssql.Tds.Context
import Control.DeepSeq
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
import System.Environment
import qualified Data.ByteString as B
instance NFData (Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64) where
  rnf (x0,x1,x2,x3,x4,x5,x6,x7,x8,x9) = x0 `seq` x1 `seq` x2 `seq` x3 `seq` x4 `seq` x5 `seq` x6 `seq` x7 `seq` x8 `seq` x9 `seq` ()
instance NFData (Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64) where
  rnf (x0,x1,x2,x3,x4,x5,x6,x7,x8,x9,x10) = x0 `seq` x1 `seq` x2 `seq` x3 `seq` x4 `seq` x5 `seq` x6 `seq` x7 `seq` x8 `seq` x9 `seq` x10 `seq` ()
instance NFData (Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64) where
  rnf (x0,x1,x2,x3,x4,x5,x6,x7,x8,x9,x10,x11) = x0 `seq` x1 `seq` x2 `seq` x3 `seq` x4 `seq` x5 `seq` x6 `seq` x7 `seq` x8 `seq` x9 `seq` x10 `seq` x11 `seq` ()
main = do
  [packetArg] <- getArgs
  let packet = read packetArg
  forM_ [(7, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64))),
    (8, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64))),
    (9, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64))),
    (10, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64))),
    (11, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64))),
    (12, Typed "" (rowDecoder @(Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64,Int64)))] $ \(width, typed) -> case typed of
    Typed _ dec -> do
      let ds = (head datasets) { dsColumns = take width (cycle (dsColumns (head datasets))) }
          bytes = responseBody ds
          chunks = cut packet bytes
          action = decodeRows (compileRowDecoder dec) defaultTdsContext chunks >>= evaluate . force
      evaluate (force chunks)
      action
      performGC
      before <- getRTSStats
      replicateM_ 10 action
      performGC
      after <- getRTSStats
      putStrLn $ show width ++ "," ++ show ((allocated_bytes after - allocated_bytes before) `div` 10) ++ "," ++ show (gcdetails_live_bytes (gc after))
cut n bytes | B.null bytes = []
            | otherwise = let (a,b) = B.splitAt n bytes in a : cut n b
