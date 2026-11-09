-- NamedParams puts one @ before a name, and bulk copy removes that one:
-- a column whose name itself starts with @ is reached with a second.
module Bulk.AtNameEvolutionSpec (spec) where

import Control.Monad (void)
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError)
import TestDb

spec :: Spec
spec = around withTestDb $ do
    it "uses literal names after a column is renamed to start with @" $ \conn -> do
        ci <- defaultTestConnectInfo
        withScratchSchema ci "at_evolution" $ \schema -> do
            let table = schema <> ".target"
            exec conn ("CREATE TABLE " <> table <> "(id int,a int,b int)")
            bulkInsert conn table [named [("@id", 1), ("@a", 101), ("@b", 202)]] `shouldReturn` 1
            void $ execute conn (mkQuery "EXEC sp_rename @p1,@p2,N'COLUMN'" (table <> ".b", "@a" :: Text))
            columns <- describeBulkColumns conn (bulkCopy table)
            map bulkColumnName columns `shouldBe` ["id", "a", "@a"]
            bulkInsert conn table [named [("@@a", 404), ("id", 2), ("a", 303)]] `shouldReturn` 1
            query conn (rawSql ("SELECT id,[a],[@a] FROM " <> table <> " ORDER BY id")) `shouldReturn` [(1 :: Int32, 101 :: Int32, 202 :: Int32), (2, 303, 404)]
    it "keeps a, @a, @@a and @ distinct under reordered named rows" $ \conn -> do
        exec conn "CREATE TABLE #literal_at(id int,[a] int,[@a] int,[@@a] int,[@] int)"
        bulkInsert conn "#literal_at" [named [("@@", 505), ("@@@a", 404), ("@@a", 303), ("a", 202), ("id", 101)]] `shouldReturn` 1
        query1 conn "SELECT id,[a],[@a],[@@a],[@] FROM #literal_at" `shouldReturn` (101 :: Int32, 202 :: Int32, 303 :: Int32, 404 :: Int32, 505 :: Int32)
    it "allows unambiguous case folding while keeping literal @ names" $ \conn -> do
        exec conn "CREATE TABLE #folded_at(id int,[a] int,[@a] int)"
        bulkInsert conn "#folded_at" [named [("@@A", 33), ("ID", 11), ("A", 22)]] `shouldReturn` 1
        query1 conn "SELECT id,[a],[@a] FROM #folded_at" `shouldReturn` (11 :: Int32, 22 :: Int32, 33 :: Int32)
    it "does not guess between literal names and parameter-style aliases" $ \conn -> do
        exec conn "CREATE TABLE #ambiguous_at(id int,[a] int,[@a] int)"
        bulkInsert conn "#ambiguous_at" [named [("id", 1), ("a", 2), ("@a", 3)]] `shouldThrow` (\(_ :: EncodeError) -> True)
        query1 conn "SELECT COUNT(*) FROM #ambiguous_at" `shouldReturn` Only (0 :: Int32)
    it "removes exactly one prefix whatever the other columns are called" $ \conn -> do
        exec conn "CREATE TABLE #one_prefix(id int,[a] int,[@a] int DEFAULT 999)"
        let selected = (bulkCopy "#one_prefix"){bulkColumns = NamedColumns ["id", "a"]}
        bulkInsertWith selected conn [named [("@a", 8), ("id", 7)]] `shouldReturn` 1
        bulkInsertWith selected conn [named [("@@a", 8), ("@@id", 7)]] `shouldThrow` (\(_ :: EncodeError) -> True)
        query1 conn "SELECT id,[a],[@a] FROM #one_prefix" `shouldReturn` (7 :: Int32, 8 :: Int32, 999 :: Int32)

named :: [(Text, Int32)] -> NamedParams
named = NamedParams . map (\(name, value) -> (name, SqlParam value))
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
