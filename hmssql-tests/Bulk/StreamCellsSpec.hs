module Bulk.StreamCellsSpec (spec) where
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec
import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ describe "bulk stream cells" $ do
  it "sends several large streams among small values" $ \conn -> do
    _ <- execute conn "CREATE TABLE #bulk_stream_cells(i int, b varbinary(max), t nvarchar(max))"
    let bytes = B.replicate 50000 42
        text = T.replicate 4000 "a😀漢"
        row i = (i, binaryStream (sourceOf (S.each [B.take 17 bytes, B.drop 17 bytes])), textStream (sourceOf (S.yield text)))
    bulkInsert conn "#bulk_stream_cells" (map row [1..3 :: Int]) `shouldReturn` 3
    query conn "SELECT i,b,t FROM #bulk_stream_cells ORDER BY i" `shouldReturn` [(i,bytes,text) | i <- [1..3 :: Int]]

  it "widens a bounded column when the batch's first cell streams" $ \conn -> do
    _ <- execute conn "CREATE TABLE #bulk_stream_bounded(b varbinary(20))"
    let source = binaryStream (sourceOf (S.yield "hello"))
    bulkInsert conn "#bulk_stream_bounded" [Only source] `shouldReturn` 1
    query conn "SELECT b FROM #bulk_stream_bounded" `shouldReturn` [Only ("hello" :: B.ByteString)]

  it "refuses a later stream when the first row selected a bounded wire type" $ \conn -> do
    _ <- execute conn "CREATE TABLE #bulk_stream_later(b varbinary(20))"
    let rows = [[SqlParam ("first" :: B.ByteString)], [SqlParam (binaryStream (sourceOf (S.yield "later")))]]
    bulkInsert conn "#bulk_stream_later" rows `shouldThrow` (\(_ :: EncodeError) -> True)
    query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)
