{-# LANGUAGE GADTs, OverloadedStrings #-}
module Main where
import qualified Bench.MockProbe as M
import Bench.Tokens
import Hmssql
import Hmssql.Query
import Control.DeepSeq
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Environment
import System.Mem
main = do
  [mode,count] <- getArgs
  let n = read count
  if mode == "connect"
    then bracket (M.startMock (tokenBytes [M.done 0])) M.stopMock $ \m ->
      measure n (connect (M.resetOnClose (M.mockConnectInfo (M.mockPort m))) >>= close)
    else do
      let ds = head datasets
      bracket (M.startMock (responseBody ds)) M.stopMock $ \m -> case dsTyped ds of
        Typed _ dec -> measure n (queryWith dec (M.mockConn m) "SELECT" >>= evaluate . force)
measure :: Int -> IO a -> IO ()
measure n action = do
  replicateM_ 3 action
  performGC
  before <- getRTSStats
  replicateM_ n action
  performGC
  after <- getRTSStats
  print ((allocated_bytes after - allocated_bytes before) `div` fromIntegral n, gcdetails_live_bytes (gc after))
