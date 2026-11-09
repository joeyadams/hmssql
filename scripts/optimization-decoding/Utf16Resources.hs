{-# LANGUAGE BangPatterns #-}
module Main where
import qualified Hmssql.Tds.Utf16 as U
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.ByteString as B
import Control.DeepSeq
import Control.Exception
import Control.Monad
import GHC.Stats
import System.Mem
import System.Environment
main = do
  [which] <- getArgs
  let decoder = if which == "ours" then U.decodeUtf16LE else E.decodeUtf16LEWith lenientDecode
  forM_ [("ASCII", "name-12345 "), ("Latin", "Caf\233 cr\232me br\251l\233e n\186 1 "), ("CJK", "\26085\26412\35486\12398\12486\12461\12473\12488"), ("emoji", "\128512a")] $ \(name, chars) ->
    forM_ [50,4000] $ \n -> do
      let inputs = [B.take (2*(n+i)) $ E.encodeUtf16LE $ T.replicate (n+i) (T.pack chars) | i <- [0..31]]
      evaluate (force inputs)
      evaluate (loop decoder inputs 32)
      performGC
      before <- getRTSStats
      count <- evaluate (loop decoder inputs 10000)
      performGC
      after <- getRTSStats
      putStrLn $ name ++ "," ++ show n ++ "," ++ show ((allocated_bytes after - allocated_bytes before) `div` 10000) ++ "," ++ show (gcdetails_live_bytes (gc after)) ++ "," ++ show count
loop :: (B.ByteString -> T.Text) -> [B.ByteString] -> Int -> Int
loop decoder inputs limit = go 0 0
  where go !i !acc | i == limit = acc
                   | otherwise = go (i+1) (acc + T.length (decoder (inputs !! (i `mod` 32))))
{-# NOINLINE loop #-}
