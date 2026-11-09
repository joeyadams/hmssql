{-# LANGUAGE BangPatterns, LambdaCase, ScopedTypeVariables, TypeApplications #-}
-- This probe performs a fixed amount of work and never reads a clock. Run each
-- dataset in a fresh process so that the maximum residency belongs to that case.
module Main (main) where

import Bench.Tokens
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (replicateM_)
import qualified Data.ByteString as B
import Foreign.StablePtr (freeStablePtr, newStablePtr)
import GHC.Stats
import Hmssql.Decoding (compileRowDecoder)
import Hmssql.Tds.Context (defaultTdsContext)
import System.Environment (getArgs)
import System.Mem (performGC)
import Text.Read (readMaybe)

main :: IO ()
main = getArgs >>= \case
  ["--list"] -> mapM_ (putStrLn . dsName) datasets
  [name, count] | Just n <- readMaybe count, n > (0 :: Int) ->
    case filter ((== name) . dsName) datasets of
      [ds] -> measure ds n
      _ -> fail ("Unknown dataset: " ++ name)
  _ -> fail "Usage: resource-probe --list | DATASET ITERATIONS +RTS -T -N1 -A4m"

measure :: Dataset -> Int -> IO ()
measure ds n = case dsTyped ds of
  Typed _ decoder -> do
    let payloads = packetPayloads (responseBody ds)
        action = decodeRows (compileRowDecoder decoder) defaultTdsContext payloads
          >>= evaluate . force
    _ <- evaluate (sum (map B.length payloads))
    -- Keep the input and action alive across both collections. Otherwise a
    -- fixture collected after the last iteration could hide retained output.
    inputRoot <- newStablePtr action
    _ <- action
    performGC
    before <- getRTSStats
    replicateM_ n action
    performGC
    after <- getRTSStats
    result <- action
    outputRoot <- newStablePtr result
    performGC
    held <- getRTSStats
    freeStablePtr outputRoot
    freeStablePtr inputRoot
    putStrLn "dataset,iterations,allocated_per_operation,input_live_bytes,output_live_bytes,max_live_bytes,rts_mem_bytes"
    putStrLn $ show (dsName ds) ++ "," ++ show n ++ ","
      ++ show ((allocated_bytes after - allocated_bytes before) `div` fromIntegral n) ++ ","
      ++ show (gcdetails_live_bytes (gc after)) ++ ","
      ++ show (gcdetails_live_bytes (gc held)) ++ ","
      ++ show (max_live_bytes held) ++ "," ++ show (gcdetails_mem_in_use_bytes (gc held))
