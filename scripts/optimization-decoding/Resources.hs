{-# LANGUAGE GADTs #-}
module Main where
import Bench.Tokens
import Hmssql.Decoding
import Hmssql.Tds.Context
import Control.DeepSeq
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
import System.Environment
import qualified Data.ByteString as B
main = do
  [packetArg] <- getArgs
  let packet = read packetArg
  forM_ datasets $ \ds -> case dsTyped ds of
    Typed _ dec -> do
      let bytes = responseBody ds
          chunks = cut packet bytes
          action = decodeRows (compileRowDecoder dec) defaultTdsContext chunks >>= evaluate . force
      evaluate (force chunks)
      action
      performGC
      before <- getRTSStats
      replicateM_ 10 action
      performGC
      after <- getRTSStats
      putStrLn $ dsName ds ++ "," ++ show ((allocated_bytes after - allocated_bytes before) `div` 10) ++ "," ++ show (gcdetails_live_bytes (gc after))
cut n bytes | B.null bytes = []
            | otherwise = let (a,b) = B.splitAt n bytes in a : cut n b
