{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.IORef
import GHC.Stats
import System.Mem
import Hmssql.Query
import qualified Hmssql.Query.Types as Q
import Hmssql.Encoding
import Data.Int
import Hmssql.Tds.Context
import qualified Hmssql.Tds.Value as V
import qualified Hmssql.Tds.Parser as P
import System.Environment
queryParamsX i = encodeParams rowEncoder (NamedParams [("x",SqlParam (fromIntegral i::Int32))])
appendLiterals a b = case (a,b) of
 (Q.Query 0 (Q.Piece [Q.Static x] []), Q.Query 0 (Q.Piece [Q.Static y] [])) -> rawSql (x <> y)
 _ -> a <> b
main = do
 [mode] <- getArgs
 ref <- newIORef (0::Int)
 let payload = B.replicate 200 0
     shapes = [(i,V.ConstantCell (V.Sized 4)) | i <- [0..49]]
     act i = case mode of
       "skip" -> P.parseChunks (V.skipCells B.empty shapes) [B.drop (i `mod` 2) (B.cons 0 payload)] >>= evaluate >> pure ()
       "lexFast" -> let t = T.replicate 100000 (if even i then "x" else "y")
                    in evaluate (T.length (queryText (if T.any (== '@') t then mkQuery t () else rawSql t))) >> pure ()
       "composeFast" -> evaluate (T.length (queryText (foldl appendLiterals mempty (replicate (1000 + i `mod` 2) "x")))) >> pure ()
       "lex" -> evaluate (T.length (queryText (mkQuery (T.replicate 100000 (if even i then "x" else "y")) ()))) >> pure ()
       "named" -> evaluate (sum [T.length n + either length (const 1) (e defaultTdsContext) | (n,e) <- queryParamsX i]) >> pure ()
       "compose" -> evaluate (T.length (queryText (mconcat (replicate (1000 + i `mod` 2) "x")))) >> pure ()
       _ -> fail mode
 act 0
 performGC
 before <- getRTSStats
 forM_ [1..10000] $ \i -> act i >> modifyIORef' ref (+1)
 performGC
 after <- getRTSStats
 print (allocated_bytes after - allocated_bytes before, max_live_bytes after)
