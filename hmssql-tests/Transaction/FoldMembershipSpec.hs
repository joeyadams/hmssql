-- Successful fold callbacks may use the same MARS connection. Fully consume
-- the finite fold before ending its transaction; no callback is interrupted.
module Transaction.FoldMembershipSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void, when)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy (bulkInsert)
import Hmssql.Transaction (inTransaction)
import MarsTx.Harness (marsConnectInfo)
import TestDb

spec :: Spec
spec = forM_ [False, True] $ \rollbackAtEnd ->
    it ("keeps successful MARS fold callback writes in their transaction, rollback=" ++ show rollbackAtEnd) $ do
        ci <- marsConnectInfo
        withScratchSchema ci "fold_membership" $ \schema -> withConnection ci $ \writer -> do
            let table = schema <> ".target"
                readRows = rawSql ("SELECT id,label FROM " <> table <> " ORDER BY id")
                ordinary n = void $ execute writer (mkQuery ("INSERT INTO " <> table <> " VALUES(@p1,@p2)") (row n))
                bulk n = void $ bulkInsert writer table [row n]
                action = withTransaction writer $ do
                    visited <- queryFold writer "SELECT v FROM (VALUES(20),(21)) AS source(v) ORDER BY v" [] $ \seen (Only n) -> do
                        ordinary n
                        inTransaction writer `shouldReturn` True
                        query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (1 :: Int32, 1 :: Int32)
                        pure (seen ++ [n])
                    visited `shouldBe` [20, 21 :: Int32]
                    bulk 22
                    when rollbackAtEnd boom
            void $ execute writer (rawSql ("CREATE TABLE " <> table <> "(id int PRIMARY KEY,label nvarchar(30)); INSERT INTO " <> table <> " VALUES(10,N'10|😀  ')"))
            if rollbackAtEnd then action `shouldThrow` anyIOException else action
            inTransaction writer `shouldReturn` False
            query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
            ordinary 30
            withTransaction writer (ordinary 40 >> bulk 41 >> boom) `shouldThrow` anyIOException
            inTransaction writer `shouldReturn` False
            query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
            withConnection ci $ \observer ->
                query observer readRows `shouldReturn` map row ([10] ++ (if rollbackAtEnd then [] else [20, 21, 22]) ++ [30])

row :: Int32 -> (Int32, Text)
row n = (n, T.pack (show n) <> "|😀  ")
boom :: IO ()
boom = throwIO (userError "rollback after fully consumed MARS fold")
