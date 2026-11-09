-- A completed response may still have a live callback scope. Its cleanup
-- must not adopt or disturb later requests/transactions on the same owner.
module Transaction.ConsumedScopeSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void, when)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Transaction (inTransaction)
import TestDb

spec :: Spec
spec = forM_ [False, True] $ \transactionInsideScope ->
    forM_ [False, True] $ \rollbackAtEnd ->
        it ("retains independent data effects after a fully consumed callback, transaction inside=" ++ show transactionInsideScope ++ ", rollback=" ++ show rollbackAtEnd) $ do
            ci <- defaultTestConnectInfo
            withScratchSchema ci "consumed_scope" $ \schema -> withConnection ci $ \writer -> do
                let table = schema <> ".target"
                    readRows = rawSql ("SELECT id,label FROM " <> table <> " ORDER BY id")
                    ordinary n = void $ execute writer (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1,@p2)") (row n))
                    bulk n = void $ bulkInsert writer table [row n]
                    finishA = bulk 21 >> when rollbackAtEnd boom
                    inside = withTransaction writer $ ordinary 20 >> finishA
                    scoped expected next = withQueryS writer readRows $ \stream -> do
                        S.toList_ stream `shouldReturn` expected
                        next
                    action =
                        if transactionInsideScope
                            then scoped [row 10] inside
                            else withTransaction writer $ ordinary 20 >> scoped [row 10, row 20] finishA
                void $ execute writer (rawSql ("CREATE TABLE " <> table <> "(id int PRIMARY KEY,label nvarchar(30)); INSERT INTO " <> table <> " VALUES(10,N'10|😀  ')"))
                if rollbackAtEnd then action `shouldThrow` anyIOException else action
                inTransaction writer `shouldReturn` False
                query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
                ordinary 30
                withTransaction writer (ordinary 40 >> bulk 41 >> boom) `shouldThrow` anyIOException
                inTransaction writer `shouldReturn` False
                withConnection ci $ \observer ->
                    query observer readRows `shouldReturn` map row ([10] ++ (if rollbackAtEnd then [] else [20, 21]) ++ [30])

row :: Int32 -> (Int32, Text)
row n = (n, T.pack (show n) <> "|😀  ")
boom :: IO ()
boom = throwIO (userError "consumed callback rollback")
