-- | Differential result shapes: the same random table (see
-- "Differential.Schema") read in different ways must decode identically:
--
-- * as ROW and as NBCROW tokens.  SQL Server 2025 never sends NBCROW over
--   TDS 8.0 (strict encryption), but over TDS 7.4 it sends NBCROW for rows
--   with enough NULLs; the select is also padded with NULL columns, so every
--   row is mostly NULL and comes as NBCROW;
-- * at packet sizes 512, 4096 and 32767 (which the server caps), over both
--   TDS versions;
-- * with 'query', 'queryS' (streaming) and 'queryMulti' (the table selected
--   twice in one batch).
--
-- Which row tokens the server sent is checked on the raw response
-- ('rowTokenKinds'), since hmssql's 'TRow' doesn't distinguish them.
module Differential.ShapeSpec (spec) where

import Wire.RecipeGet (getToken)
import Control.Exception (bracket, finally)
import Control.Monad (forM_, void)
import qualified Data.Binary.Get as Get
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import Data.Word (Word8)
import Hedgehog
import qualified Streaming.Prelude as S
import Test.Hspec
import Test.Hspec.Hedgehog

import Differential.Schema
import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Tds.Context
import Hmssql.Connection (connectionContext)
import Hmssql.Connection.Internal (readWholeMessage, sendMessage, withConnectionLock)
import Hmssql.Tds.Client (putSqlBatch)
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Token (Token (..))
import LiveProperty (liveHedgehog)
import TestDb

data Conns = Conns
  { tableName :: Text -- ^ a global temporary table, visible to every connection
  , base :: Connection -- ^ TDS 8.0, 4096-byte packets; creates the table
  , others :: [(String, Connection)]
    -- ^ TDS 8.0 and 7.4 at packet sizes 512, 4096 (7.4 only) and 32767
  , raw74 :: Connection -- ^ TDS 7.4, only for 'rowTokenKinds'
  }

withConns :: (Conns -> IO a) -> IO a
withConns act = do
  strict <- testConnectInfo EncryptStrict
  on <- testConnectInfo EncryptOn
  name <- ("##" <>) <$> uniqueName "hmssql_diff_shape"
  let with ci size = bracket (connect ci { connectPacketSize = size }) close
  with strict 4096 $ \b ->
    with strict 512 $ \s512 -> with strict 32767 $ \s32767 ->
      with on 512 $ \o512 -> with on 4096 $ \o4096 -> with on 32767 $ \o32767 ->
        with on 4096 $ \raw ->
          act Conns
            { tableName = name
            , base = b
            , others =
                [ ("TDS 8.0, packet size 512", s512)
                , ("TDS 8.0, packet size 32767", s32767)
                , ("TDS 7.4, packet size 512", o512)
                , ("TDS 7.4, packet size 4096", o4096)
                , ("TDS 7.4, packet size 32767", o32767)
                ]
            , raw74 = raw
            }
            `finally` void (execute b (rawSql ("DROP TABLE IF EXISTS " <> name)))

spec :: Spec
spec = around withConns $ do
  describe "a random table read as ROW/NBCROW, at three packet sizes, streamed and as multiple result sets" $ do
    it "the connections use the requested TDS versions and packet sizes (the server caps the largest)" $ \Conns{..} -> do
      ctxs <- mapM (connectionContext . snd) others
      map tdsVersion ctxs `shouldBe` [Tds80, Tds80, Tds74, Tds74, Tds74]
      let sizes = map tdsPacketSize ctxs
      -- 512 and 4096 are granted as asked; 32767 is capped by the server
      -- (16384 on SQL Server 2025, 16192 behind Azure SQL's gateway).
      map (sizes !!) [0, 2, 3] `shouldBe` [512, 512, 4096]
      forM_ (map (sizes !!) [1, 4]) $ \s -> s `shouldSatisfy` (\x -> x >= 4096 && x <= 32767)
    modifyMaxShrinks (const 60) $ withCases 30 $
      it "decodes identically (30 tables)" $ \cs -> liveHedgehog (shapeProperty cs)
    slow $ modifyMaxShrinks (const 60) $ withCases 1500 $
      it "decodes identically (1500 tables)" $ \cs -> liveHedgehog (shapeProperty cs)

-- | The row tokens (0xD1 ROW, 0xD2 NBCROW) of a batch's response, read from
-- the raw message.
rowTokenKinds :: Connection -> Text -> IO [Word8]
rowTokenKinds conn sql = do
  ctx <- connectionContext conn
  body <- withConnectionLock conn $ do
    sendMessage conn PTSqlBatch (putSqlBatch ctx sql)
    snd <$> readWholeMessage conn
  pure (go ctx Nothing (LB.fromStrict body))
  where
    go ctx cols bs
      | LB.null bs = []
      | otherwise = case Get.runGetOrFail (getToken ctx cols) bs of
          Left (_, _, e) -> error ("rowTokenKinds: " ++ e)
          Right (rest, _, tok) ->
            let kind = LB.head bs
                cols' = case tok of
                  TColMetaData cs | not (null cs) -> Just cs
                  _ -> cols
             in [kind | kind == 0xD1 || kind == 0xD2] ++ go ctx cols' rest

-- | Rows as comparable values ('show' distinguishes -0.0 from 0.0).
norm :: [SqlRow] -> [[String]]
norm = map (map show . sqlRowValues)

shapeProperty :: Conns -> PropertyT IO ()
shapeProperty Conns{..} = do
  cs <- evalIO (collationsFor <$> testSqlVersion)
  t <- forAllWith (scriptFor tableName) (genTable cs)
  let n = length (tableColumns t)
      sel = selectSql tableName t
      padded = paddedSelectSql 60 tableName t
      readWith c q = queryMWith sqlRowDecoder c (rawSql q)
      nulls = replicate 60 SqlNull
  rows <- evalIO $ do
    setupTable base tableName t
    readWith base sel
  length rows === length (tableRows t)
  let cols = map sqlRowColumns (take 1 rows)

  annotate "streamed with queryS"
  streamed <- evalIO (querySMWith sqlRowDecoder base (rawSql sel) >>= S.toList_)
  norm streamed === norm rows
  map sqlRowColumns streamed === map sqlRowColumns rows

  annotate "queryMulti, the table selected twice"
  multi <- evalIO (queryMulti base (rawSql (sel <> ";\n" <> sel)))
  length multi === 2
  mapM_ (\rs -> norm (resultRows rs) === norm rows) multi
  case multi of
    [a, b] -> do
      resultColumns a === resultColumns b
      mapM_ (=== resultColumns a) cols
    _ -> failure

  annotate "padded with NULL columns"
  pad <- evalIO (readWith base padded)
  map (take n) (norm pad) === norm rows
  map (take n . sqlRowColumns) pad === map sqlRowColumns rows
  mapM_ (\r -> drop n (sqlRowValues r) === nulls) pad

  annotate "row tokens over TDS 7.4"
  plainKinds <- evalIO (rowTokenKinds raw74 sel)
  padKinds <- evalIO (rowTokenKinds raw74 padded)
  length plainKinds === length rows
  classify "ROW tokens" (0xD1 `elem` plainKinds)
  classify "NBCROW tokens without padding" (0xD2 `elem` plainKinds)
  padKinds === map (const 0xD2) rows

  forM_ others $ \(label, c) -> do
    annotate label
    other <- evalIO (readWith c sel)
    norm other === norm rows
    map sqlRowColumns other === map sqlRowColumns rows
    otherPad <- evalIO (querySMWith sqlRowDecoder c (rawSql padded) >>= S.toList_)
    norm otherPad === norm pad
