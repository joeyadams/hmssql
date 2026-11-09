{-# LANGUAGE BangPatterns, DeriveGeneric, OverloadedStrings #-}
-- Fixed-work allocation and residency measurements; this program never reads a clock.
-- Compile with: stack exec -- ghc -O1 -rtsopts -package hmssql scripts/encoding-resource-probe.hs -o /tmp/encoding-probe
-- Run one case per process: /tmp/encoding-probe row 10000 +RTS -T -A4m
module Main where
import Control.Exception (evaluate)
import Control.Monad (foldM)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import Data.Int
import Data.IORef
import GHC.Generics (Generic)
import GHC.Stats
import System.Mem
import System.Environment
import qualified Data.Text as T
import Hmssql.Query (mkQuery, queryRequestFor)
import Hmssql.Query.Types (Request (..))
import Hmssql.Encoding
import Hmssql.BulkCopy
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo
import Hmssql.Tds.Parameter
import Hmssql.Tds.PacketWriter
import Hmssql.Tds.Packet

data R = R !Int32 !Int64 !Double !Int32 !Int64 deriving Generic
instance ToSqlRow R
encodeRow :: Int -> Int
encodeRow i = sum [ case f defaultTdsContext of Right (_,ParamBytes (Just b)) -> B.length b + fromIntegral (B.head b); _ -> 0 | (_,f) <- encodeParams rowEncoder (R (fromIntegral i) (fromIntegral i) (fromIntegral i) (fromIntegral i) (fromIntegral i)) ]
{-# NOINLINE encodeRow #-}
bulk :: Int -> Int
bulk i = case encodeParam (fieldEncoder :: FieldEncoder Int32) defaultTdsContext (fromIntegral i) >>= encodeBulkCell defaultTdsContext (BulkColumn "x" (TIIntN 8) False False) of
 Right (ParamBytes (Just b)) -> B.length b + fromIntegral (B.head b)
 _ -> 0
{-# NOINLINE bulk #-}
value :: Int -> Int
value i = fromIntegral $ LB.length $ BB.toLazyByteString (BB.word8 0 <> writeValue (TIIntN 4) (Just (B.pack [fromIntegral i,0,0,0])))
{-# NOINLINE value #-}
packet :: Int -> IO Int
packet i = do
 ref <- newIORef 0
 runPacketWriter defaultTdsContext PTRpc (\b -> modifyIORef' ref (+ B.length b)) $ \out -> mapM_ (\j -> writeParamValueWith out (BB.word8 0) (TIIntN 4) (ParamBytes (Just (B.pack [fromIntegral (i+j),0,0,0])))) [1..100]
 readIORef ref
{-# NOINLINE packet #-}
request :: Int -> IO Int
request i = do
 req <- queryRequestFor defaultTdsContext (mkQuery queryText [fromIntegral (i+j) :: Int32 | j <- [1..100]])
 ref <- newIORef 0
 runPacketWriter defaultTdsContext (requestPacketType req) (\b -> modifyIORef' ref (+ B.length b)) (requestBody req defaultTdsContext)
 readIORef ref
{-# NOINLINE request #-}
queryText = "SELECT " <> T.intercalate "," ["@p" <> T.pack (show j) | j <- [1..100 :: Int]]
main = do
 [mode,nstr] <- getArgs
 let n = read nstr
 performGC
 before <- getRTSStats
 result <- foldM (\ !acc i -> do
   x <- case mode of
     "row" -> evaluate (encodeRow i)
     "bulk" -> evaluate (bulk i)
     "value" -> evaluate (value i)
     "packet" -> packet i
     "request" -> request i
     _ -> error ("Unknown case: " ++ mode)
   pure (acc+x)) 0 [1..n]
 _ <- evaluate result
 performGC
 after <- getRTSStats
 print (mode,n,result,allocated_bytes after - allocated_bytes before,max_live_bytes after,max_mem_in_use_bytes after)
