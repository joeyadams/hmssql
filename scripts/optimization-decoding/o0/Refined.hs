{-# LANGUAGE GADTs #-}
module Main where
import Bench.Tokens
import qualified Recipes0 as O0
import qualified Recipes1 as O1
import Data.Int
import Data.Coerce
import GHC.Generics
import Hmssql.Decoding
import Hmssql.Tds.Context
import Control.DeepSeq
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
import System.Environment
import qualified Data.ByteString as B
newtype Refined = Refined Int32 deriving (Generic, NFData)
instance FromSqlField Refined where
  fieldDecoder = refineField (Right . Refined) (fieldDecoder @Int32)
main = do
  [packetArg] <- getArgs
  let packet = read packetArg
  forM_ [(head datasets, "refineField", Typed "" (rowDecoder @(Refined,Int64))), (head datasets, "builtin", Typed "" (rowDecoder @(Int32,Int64)))] $ \(ds, name, typed) -> case typed of
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
      putStrLn $ name ++ "," ++ show ((allocated_bytes after - allocated_bytes before) `div` 10) ++ "," ++ show (gcdetails_live_bytes (gc after))
cut n bytes | B.null bytes = []
            | otherwise = let (a,b) = B.splitAt n bytes in a : cut n b
