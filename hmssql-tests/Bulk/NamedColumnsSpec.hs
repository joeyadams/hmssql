-- | Named rows must not alias distinct columns through Unicode case folding.
module Bulk.NamedColumnsSpec (spec) where

import Control.Monad (void)
import Data.Int (Int32)
import Data.Text (Text)
import Test.Hspec
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import LiveProperty (liveHedgehog)

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Errors (EncodeError (..))
import TestDb

spec :: Spec
spec = skipOnAzure "changes the test database's collation" $
  aroundAll withCaseSensitiveDb $
    aroundWith (\action ci -> withConnection ci action) $
      describe "named bulk columns in a case-sensitive catalog" $ do
        it "preserves values for column names differing only in case" $ \conn -> do
          table <- target conn "([a] int,[A] int)"
          bulkInsert conn table [named [("A",2),("a",1)],named [("a",3),("A",4)]] `shouldReturn` 2
          query conn (rawSql ("SELECT [a],[A] FROM " <> table <> " ORDER BY [a]")) `shouldReturn` [(1 :: Int32,2 :: Int32),(3,4)]
        it "preserves case and literal @ after sequential column renames" $ \conn -> do
          table <- target conn "([a] int,[A] int,[b] int,[B] int)"
          bulkInsert conn table [named [("@a",1),("@A",2),("@b",3),("@B",4)]] `shouldReturn` 1
          void $ execute conn (mkQuery "EXEC sp_rename @p1,@p2,N'COLUMN'" (table<>".b","@a" :: Text))
          void $ execute conn (mkQuery "EXEC sp_rename @p1,@p2,N'COLUMN'" (table<>".B","@A" :: Text))
          bulkInsert conn table [named [("@@A",14),("A",12),("@@a",13),("a",11)]] `shouldReturn` 1
          query conn (rawSql ("SELECT [a],[A],[@a],[@A] FROM "<>table<>" ORDER BY [a]")) `shouldReturn` [(1 :: Int32,2 :: Int32,3 :: Int32,4 :: Int32),(11,12,13,14)]
        it "preserves case after removing parameter-style @ prefixes" $ \conn -> do
          table <- target conn "([a] int,[A] int)"
          bulkInsert conn table [named [("@a",7),("@A",8)]] `shouldReturn` 1
          query1 conn (rawSql ("SELECT [a],[A] FROM " <> table)) `shouldReturn` (7 :: Int32,8 :: Int32)
        it "preserves distinct names that Unicode case folding expands to the same text" $ \conn -> do
          table <- target conn "([ß] int,[ss] int)"
          bulkInsert conn table [named [("ß",7),("ss",8)]] `shouldReturn` 1
          query1 conn (rawSql ("SELECT [ß],[ss] FROM " <> table)) `shouldReturn` (7 :: Int32,8 :: Int32)
        it "does not reuse one value for an ambiguous case-insensitive match" $ \conn -> do
          table <- target conn "([a] int,[A] int)"
          bulkInsert conn table [named [("a",7),("Aa",9)]] `shouldThrow` \(EncodeError _) -> True
          query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table)) `shouldReturn` Only (0 :: Int32)
        it "rejects duplicate exact names before inserting a row" $ \conn -> do
          table <- target conn "([a] int,[A] int)"
          bulkInsert conn table [named [("a",7),("a",9)]] `shouldThrow` \(EncodeError _) -> True
          query1 conn (rawSql ("SELECT COUNT(*) FROM " <> table)) `shouldReturn` Only (0 :: Int32)
        it "keeps unambiguous case-insensitive matching alongside exact matches" $ \conn -> do
          table <- target conn "([a] int,[A] int,[value] int)"
          bulkInsert conn table [named [("a",1),("A",2),("VALUE",3)]] `shouldReturn` 1
          query1 conn (rawSql ("SELECT [a],[A],[value] FROM " <> table)) `shouldReturn` (1 :: Int32,2 :: Int32,3 :: Int32)
        it "keeps legacy case-insensitive matching when there is only one matching column" $ \conn -> do
          table <- target conn "([Value] int)"
          bulkInsert conn table [named [("@vAlUe",17)]] `shouldReturn` 1
          query1 conn (rawSql ("SELECT [Value] FROM " <> table)) `shouldReturn` Only (17 :: Int32)

        withCases 20 $ it "preserves generated rows under name permutations and optional @ prefixes" $ \conn -> liveHedgehog $ do
          let genInt = Gen.int32 Range.linearBounded
              genValues = (,,,,) <$> genInt <*> genInt <*> genInt <*> genInt <*> genInt
          values <- forAll $ Gen.list (Range.linear 1 15) genValues
          orders <- forAll $ traverse (const (Gen.shuffle [0..5 :: Int])) values
          prefixes <- forAll $ traverse (const (Gen.list (Range.singleton 6) Gen.bool)) values
          let expected = zipWith (\i (a,b,c,d,e) -> (i,a,b,c,d,e)) [1..] values
              names = ["ID","a","A","ß","ss","VALUE"]
              input (i,a,b,c,d,e) order flags = named
                [ ((if flags !! j then "@" else "") <> names !! j,[i,a,b,c,d,e] !! j)
                | j <- order ]
              rows = zipWith3 input expected orders prefixes
          actual <- evalIO $ do
            table <- target conn "([id] int PRIMARY KEY,[a] int,[A] int,[ß] int,[ss] int,[Value] int)"
            bulkInsert conn table rows `shouldReturn` fromIntegral (length rows)
            query conn (rawSql ("SELECT [id],[a],[A],[ß],[ss],[Value] FROM " <> table <> " ORDER BY [id]"))
          actual === (expected :: [(Int32,Int32,Int32,Int32,Int32,Int32)])

named :: [(Text,Int32)] -> NamedParams
named = NamedParams . map (\(name,value) -> (name,SqlParam value))

target :: Connection -> Text -> IO Text
target conn definition = do
  name <- uniqueName "bulk_named"
  void $ execute conn $ rawSql ("CREATE TABLE " <> name <> " " <> definition)
  pure name

withCaseSensitiveDb :: (ConnectInfo -> IO a) -> IO a
withCaseSensitiveDb action = withScratchDatabase "bulk_named" $ \ci -> do
  master <- masterConnectInfo
  withConnection master $ \conn -> void $ execute conn $ rawSql ("ALTER DATABASE " <> quoteName (connectDatabase ci) <> " COLLATE Latin1_General_100_BIN2")
  action ci
