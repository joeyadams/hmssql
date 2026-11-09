-- | Every legal precision/scale pair, including extrema and zero. The
-- server's conversion of decimal text is an independent encoding oracle;
-- compare RPC parameters, bulk copy, typed and dynamic decoders with it.
module Types.DecimalMatrixSpec (spec) where

import Control.Monad (forM_, void)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ describe "decimal precision and scale matrix" $
  forM_ [1..38 :: Int] $ \precision ->
    forM_ [0..precision] $ \scale ->
      it ("decimal(" ++ show precision ++ "," ++ show scale ++ ") across RPC, bulk and server conversion") $ \conn -> do
        let typ = "decimal(" <> tshow precision <> "," <> tshow scale <> ")"
            limit = 10 ^ precision - 1 :: Integer
            mantissas = [-limit,-1,0,1,limit]
            values = map (Decimal (fromIntegral scale)) mantissas :: [Decimal]
            rows = zip [1..] values :: [(Int32,Decimal)]
        void $ execute conn $ rawSql ("CREATE TABLE #rpc (id int,v " <> typ <> "); CREATE TABLE #bulk (id int,v " <> typ <> "); CREATE TABLE #oracle (id int,v " <> typ <> ")")
        executeMany conn "INSERT INTO #rpc VALUES (@p1,@p2)" rows `shouldReturn` replicate 5 1
        bulkInsert conn "#bulk" rows `shouldReturn` 5
        -- An explicit cast preserves scale; adding decimal expressions here
        -- would apply SQL Server's arithmetic precision/scale reduction.
        forM_ rows $ \(i,value) -> void $ execute conn $
          mkQuery ("INSERT INTO #oracle VALUES (@p1,CAST(@p2 AS " <> typ <> "))") (i,T.pack (show value))
        query conn "SELECT v FROM #oracle ORDER BY id" `shouldReturn` map Only values
        query conn "SELECT v FROM #rpc ORDER BY id" `shouldReturn` map Only values
        query conn "SELECT v FROM #bulk ORDER BY id" `shouldReturn` map Only values
        decoded <- query conn "SELECT v FROM #rpc ORDER BY id" :: IO [Only Decimal]
        map (decimalPlaces . fromOnly) decoded `shouldBe` replicate 5 (fromIntegral scale)
        query conn "SELECT v FROM #oracle ORDER BY id" `shouldReturn` map (Only . SqlDecimal) values
        if scale == 0
          then query conn "SELECT v FROM #rpc ORDER BY id" `shouldReturn` map Only mantissas
          else pure ()

tshow :: Show a => a -> Text
tshow = T.pack . show
