-- Only the two decoder-definition modules differ in optimization level. The
-- driver, fixture preparation, and library use the same optimized code.
module Main (main) where

import Bench.Tokens
import qualified Recipes0 as O0
import qualified Recipes1 as O1
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Hmssql.Decoding (compileRowDecoder)
import Hmssql.Tds.Context (defaultTdsContext)
import Test.Tasty.Bench

main :: IO ()
main = defaultMain
  [ env (evaluate (force (packetPayloads (responseBody ds)))) $ \chunks ->
      case typed of
        Typed _ decoder -> bench name $
          nfIO (decodeRows (compileRowDecoder decoder) defaultTdsContext chunks)
  | (datasetName, name, typed) <-
      [ ("int bigint x10000", "pair-O0", Typed "" O0.pair)
      , ("int bigint x10000", "pair-O1", Typed "" O1.pair)
      , ("nullable half NULL NBCROW x10000", "nullable-O0", Typed "" O0.nullable)
      , ("nullable half NULL NBCROW x10000", "nullable-O1", Typed "" O1.nullable)
      ]
  , ds <- filter ((== datasetName) . dsName) datasets
  ]
