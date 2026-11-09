-- | Building requests without a server: a 'Query' encoded as the packets
-- the connection would send ('queryRequestFor', then the request body run
-- and framed as 'Hmssql.Connection.Internal.sendFramed' frames it).
-- The queries are built by 'env', so what is measured is parameter
-- encoding and checking, the @sp_executesql@ RPC and the framing; the
-- @INSERT@ benchmark also composes its query, as an application would.
module Bench.Encode
  ( benchmarks
    -- * Queries "Bench.Live" sends too
  , intParams
  , textParams
  , insertRows
  , insertRow
  , insertRowSql
  , insertRowParams
  ) where

import Data.IORef
import Hmssql.Tds.PacketWriter (runPacketWriter)
import Control.DeepSeq (NFData (..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32, Int64)
import Data.List (intersperse)
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Test.Tasty.Bench

import Hmssql
import Hmssql.Types
import Hmssql.BulkCopy
import Hmssql.Query (executeStatementsRequestsFor, queryRequestFor)
import Hmssql.Query.Types (Request (..))
import Hmssql.Encoding (encodeParam, EncodedParam, ParamValue (..))
import Hmssql.Tds.Context
import Hmssql.Tds.Packet (PacketStatus (..), PacketType (..), frameSegments)
import Hmssql.Tds.TypeInfo (RawBytes)

-- | A query, built by 'env'.
newtype Q = Q Query

instance NFData Q where
  rnf (Q q) = rnf (queryText q)

-- | A message body, built by 'env'.
newtype Body = Body LB.ByteString

instance NFData Body where
  rnf (Body b) = rnf b

benchmarks :: Benchmark
benchmarks = bgroup "Encode"
  [ bgroup "request"
      [ request "SELECT 1 batch" (pure "SELECT 1")
      , request "1 int param" (pure (intParams 1))
      , bench "1 int param, literal mkQuery text built per call" $ nfAppIO (packetBytes . literalQuery) 42
      , request "100 int params" (pure (intParams 100))
      , request "2000 int params" (pure (intParams 2000))
      , request "100 mixed params" (pure (mixedParams 100))
      , request "2000 nvarchar(20) params" (pure (textParams 2000))
      , bench "INSERT 100 rows x 3 params, composed" $
          nfAppIO (packetBytes . insertRows) 100
      , bench "executeStatements of 100 one-row INSERTs, composed" $
          nfAppIO (\n -> manyPacketBytes (map insertRow [1 .. n])) 100
      , bench "executeStatements of 1000 one-row INSERTs, composed" $
          nfAppIO (\n -> manyPacketBytes (map insertRow [1 .. n])) 1000
      ]
  , bgroup "bulk"
      [ env (pure (bulkFix 100)) $ \ ~(BulkFix ctx cols rows) ->
          bench "bulk load 100 rows framed" (whnf (bulkTotal ctx cols) rows)
      , env (pure (bulkFix 1000)) $ \ ~(BulkFix ctx cols rows) ->
          bench "bulk load 1000 rows framed" (whnf (bulkTotal ctx cols) rows)
      ]
  , bgroup "large params"
      [ request "varbinary(max) 4MB" (pure (mkQuery "SELECT DATALENGTH(@p1)" (Only (B.replicate (4 * 1024 * 1024) 0x78))))
      , request "nvarchar(max) 1M chars" (pure (mkQuery "SELECT LEN(@p1)" (Only (T.replicate (1024 * 1024) "y"))))
      , request "10 nvarchar(max) 100K chars" (pure (mkQuery "SELECT 1" [SqlParam (T.replicate 100_000 (T.singleton c)) | c <- ['a' .. 'j']]))
      ]
  , bgroup "batch"
      [ request "SQL batch 1M chars" (pure (rawSql ("SELECT 1 /*" <> T.replicate (1024 * 1024 - 14) "z" <> "*/")))
      ]
  , bgroup "framing"
      [ env (pure (Body (LB.fromStrict (B.replicate (4 * 1024 * 1024) 0x78)))) $ \ ~(Body b) -> bgroup "4MB"
          [ bench ("packet size " ++ show size) $
              whnf (sum . map B.length . frameSegments tlsChunk defaultTdsContext { tdsPacketSize = size } PTRpc (PacketStatus 0)) b
          | size <- [4096, 32767]
          ]
      ]
  ]
  where
    request name mk = env (Q <$> mk) $ \ ~(Q q) -> bench name (nfIO (packetBytes q))

-- | The request's packets, as the connection would send them over TLS
-- (a packet per chunk, 'Hmssql.Connection.Internal.sendFramed'); their total
-- length.
packetBytes :: Query -> IO Int
packetBytes q = queryRequestFor defaultTdsContext q >>= requestPacketBytes

requestPacketBytes :: Request -> IO Int
requestPacketBytes req = do
  count <- newIORef 0
  let ctx = defaultTdsContext
  runPacketWriter ctx (requestPacketType req) (\packet -> modifyIORef' count (+ B.length packet)) (requestBody req ctx)
  readIORef count

manyPacketBytes :: [Query] -> IO Int
manyPacketBytes qs = executeStatementsRequestsFor defaultTdsContext qs >>= fmap sum . mapM requestPacketBytes

tlsChunk :: Int
tlsChunk = 0

-- | A query as applications write one: 'mkQuery' of a literal with
-- identifiers, a string and comments (the lexer's slow characters),
-- built anew for each call with its parameter.  'mkQuery' inlines, so the
-- literal is lexed once per run: before that, each call lexed it again.
literalQuery :: Int32 -> Query
literalQuery i = mkQuery
  "SELECT [o].[id], [o].[placed_at], [c].[name] FROM [dbo].[orders] AS [o]\n\
  \  JOIN [dbo].[customers] AS [c] ON [c].[id] = [o].[customer_id]\n\
  \  WHERE [o].[id] = @p1 AND [o].[status] <> 'cancelled' -- open orders only\n\
  \  /* newest first */ ORDER BY [o].[placed_at] DESC"
  (Only i)
{-# NOINLINE literalQuery #-}

intParams :: Int -> Query
intParams n = mkQuery (valuesOf n) [SqlParam (fromIntegral i :: Int32) | i <- [1 .. n]]

textParams :: Int -> Query
textParams n = mkQuery (valuesOf n) [SqlParam (T.pack ("value number " ++ show i)) | i <- [1 .. n]]

-- | @SELECT COUNT(*) FROM (VALUES (\@p1), ...) v(x)@
valuesOf :: Int -> T.Text
valuesOf n = "SELECT COUNT(*) FROM (VALUES " <> T.intercalate ", " ["(@p" <> T.pack (show i) <> ")" | i <- [1 .. n]] <> ") v(x)"

-- | Parameters of ten types, in turn.
mixedParams :: Int -> Query
mixedParams n = mkQuery ("SELECT " <> T.intercalate ", " ["@p" <> T.pack (show i) | i <- [1 .. n]]) (take n (cycle kinds))
  where
    kinds =
      [ SqlParam (42 :: Int32)
      , SqlParam ("some text" :: T.Text)
      , SqlParam (Decimal 4 (123_456_789 :: Integer))
      , SqlParam (UTCTime (fromGregorian 2026 9 26) 45_296.123_456_7)
      , SqlParam (UUID.fromWords 0x12345678 0x9abcdef0 0x0fedcba9 0x87654321)
      , SqlParam (Nothing :: Maybe Int64)
      , SqlParam (B.replicate 16 0xAB)
      , SqlParam (3.25 :: Double)
      , SqlParam True
      , SqlParam (fromGregorian 2026 9 26)
      ]

-- | @INSERT INTO #t (a, b, c) VALUES (\@p1, \@p2, \@p3), ...@ composed from
-- one piece per row.
insertRows :: Int -> Query
insertRows n = "INSERT INTO #t (a, b, c) VALUES " <> mconcat (intersperse ", " (map rowOf [1 .. n]))
  where
    rowOf i = "(" <> param (fromIntegral i :: Int32) <> ", " <> param (T.pack ("row " ++ show i)) <> ", " <> param (Decimal 2 (fromIntegral i * 100 + 99 :: Integer)) <> ")"

-- | One row of 'insertRows' as a statement of its own, composed.
insertRow :: Int -> Query
insertRow i = "INSERT INTO #t (a, b, c) VALUES (" <> param a <> ", " <> param b <> ", " <> param c <> ")"
  where
    (a, b, c) = insertRowParams i

-- | 'insertRow' for 'Hmssql.executeMany': the text, and a row's parameters.
insertRowSql :: T.Text
insertRowSql = "INSERT INTO #t (a, b, c) VALUES (@p1, @p2, @p3)"

insertRowParams :: Int -> (Int32, T.Text, Decimal)
insertRowParams i = (fromIntegral i, T.pack ("row " ++ show i), Decimal 2 (fromIntegral i * 100 + 99 :: Integer))


-- | A bulk load's context, columns and converted rows, for 'bulkTotal'.
data BulkFix = BulkFix TdsContext [BulkColumn] [[RawBytes]]

instance NFData BulkFix where
  rnf (BulkFix _ cols rows) = rnf (map bulkColumnName cols) `seq` rnf (map (map (fmap B.length)) rows)

-- | @n@ rows of 'insertRowParams', converted to each column's wire type,
-- for the bulk-load framing benchmark: what 'Hmssql.BulkCopy.bulkInsert'
-- builds per row before framing.
bulkFix :: Int -> BulkFix
bulkFix n = BulkFix ctx cols [rowBytes i | i <- [1 .. n]]
  where
    ctx = defaultTdsContext
    cols =
      [ BulkColumn "a" (TIIntN 4) False False
      , BulkColumn "b" (TINVarChar (2 * 50) (Collation 0 0)) False False
      , BulkColumn "c" (TIDecimalN 10 2) False False ]
    rowBytes i =
      let (a, b, c) = insertRowParams i
       in [ conv (cols !! 0) (ep a), conv (cols !! 1) (ep b), conv (cols !! 2) (ep c) ]
    ep :: ToSqlField x => x -> EncodedParam
    ep x = either error id (encodeParam fieldEncoder ctx x)
    conv col e = case either error id (encodeBulkCell ctx col e) of
      ParamBytes bytes -> bytes
      _ -> error "stream in a strict bulk fixture"

-- | The total bytes of the packets a bulk load of the rows frames into.
bulkTotal :: TdsContext -> [BulkColumn] -> [[RawBytes]] -> Int
bulkTotal ctx cols rows = sum (map B.length (bulkLoadPackets ctx "#t" cols rows))
