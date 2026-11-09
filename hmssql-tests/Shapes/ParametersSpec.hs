-- | Shapes of parameterized requests: counts, names, NULLs, and interaction
-- with multi-statement / multi-result-set batches.  A query with parameters
-- is sent through sp_executesql; one without is a plain batch.
module Shapes.ParametersSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.UUID.Types (UUID)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "parameter counts" $ do
    it "runs with 0 parameters, as a plain batch (a #temp table it creates outlives it)" $ \conn -> do
      query1 conn "CREATE TABLE #s (i int); SELECT 1" `shouldReturn` Only (1 :: Int)
      query1 conn "SELECT COUNT(*) FROM #s" `shouldReturn` Only (0 :: Int)

    it "runs with 1 parameter through sp_executesql (a #temp table it creates is dropped when it returns)" $ \conn -> do
      query1 conn ("CREATE TABLE #s (i int); SELECT " <> param (1 :: Int)) `shouldReturn` Only (1 :: Int)
      r <- try (query1 conn "SELECT COUNT(*) FROM #s" :: IO (Only Int))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 208 -- invalid object name
        Right v -> expectationFailure ("#s outlived sp_executesql: " ++ show v)

    it "accepts 2098 parameters (2 more are used internally by sp_executesql)" $ \conn -> do
      let n = 2098 :: Int
          params = [SqlParam (i :: Int) | i <- [1 .. n]]
          sql = "SELECT " <> T.intercalate " + " ["@p" <> T.pack (show i) | i <- [1 .. n]]
      Only total <- query1 conn (mkQuery sql params)
      total `shouldBe` (sum [1 .. n] :: Int)

    it "reports a clean server error for 2099 parameters" $ \conn -> do
      let n = 2099 :: Int
          params = [SqlParam (i :: Int) | i <- [1 .. n]]
          sql = "SELECT " <> T.intercalate " + " ["@p" <> T.pack (show i) | i <- [1 .. n]]
      r <- try (query1 conn (mkQuery sql params) :: IO (Only Int))
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8003
        Right v -> expectationFailure ("succeeded with " ++ show v)
      -- connection still usable
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "parameter names" $ do
    it "accepts a unicode parameter name" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @héllo" (NamedParams [("héllo", SqlParam (5 :: Int))]))
      r `shouldBe` Only (5 :: Int)

    it "accepts a parameter named like a T-SQL keyword" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @select, @order" (NamedParams [("select", SqlParam (1 :: Int)), ("order", SqlParam (2 :: Int))]))
      r `shouldBe` (1 :: Int, 2 :: Int)

    it "allows an unused declared parameter" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @a" (NamedParams [("a", SqlParam (1 :: Int)), ("unused", SqlParam (99 :: Int))]))
      r `shouldBe` Only (1 :: Int)

    it "allows a parameter referenced many times" $ \conn -> do
      r <- query1 conn ("SELECT " <> namedParam "n" ("x" :: Text) <> ", @n, @n")
      r `shouldBe` ("x" :: Text, "x" :: Text, "x" :: Text)

  describe "NULL parameters of every type" $ do
    it "sends NULL for int/bigint/bit/float/real" $ \conn -> do
      r <- query1 conn $ mkQuery "SELECT @p1, @p2, @p3, @p4, @p5"
             (Nothing :: Maybe Int, Nothing :: Maybe Int64, Nothing :: Maybe Bool, Nothing :: Maybe Double, Nothing :: Maybe Float)
      r `shouldBe` (Nothing :: Maybe Int, Nothing :: Maybe Int64, Nothing :: Maybe Bool, Nothing :: Maybe Double, Nothing :: Maybe Float)

    it "sends NULL for decimal/money" $ \conn -> do
      r <- query1 conn ("SELECT " <> param (Nothing :: Maybe Decimal) <> ", " <> param (Nothing :: Maybe Money))
      r `shouldBe` (Nothing :: Maybe Decimal, Nothing :: Maybe Money)

    it "sends NULL for text/binary/uniqueidentifier" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @p1, @p2, @p3" (Nothing :: Maybe Text, Nothing :: Maybe B.ByteString, Nothing :: Maybe UUID))
      r `shouldBe` (Nothing :: Maybe Text, Nothing :: Maybe B.ByteString, Nothing :: Maybe UUID)

    it "sends NULL for date/time family" $ \conn -> do
      r <- query1 conn $ mkQuery "SELECT @p1, @p2, @p3, @p4"
             (Nothing :: Maybe Day, Nothing :: Maybe TimeOfDay, Nothing :: Maybe LocalTime, Nothing :: Maybe DateTimeOffset)
      r `shouldBe` (Nothing :: Maybe Day, Nothing :: Maybe TimeOfDay, Nothing :: Maybe LocalTime, Nothing :: Maybe DateTimeOffset)

  describe "sp_executesql with multiple result sets and errors" $ do
    it "returns each set when parameters are used across statements" $ \conn -> do
      -- Haskell's Int maps to SQL bigint, not int
      sets <- queryMulti conn (mkQuery "SELECT @p1; SELECT @p2, @p2" (1 :: Int, "x" :: Text))
      map (map sqlRowValues . resultRows) sets `shouldBe` [[[SqlInt64 1]], [[SqlText "x", SqlText "x"]]]

    it "throws, with no partial result, when a later statement errors" $ \conn -> do
      r <- try (queryMulti conn (mkQuery "SELECT @p1; RAISERROR('late', 16, 1); SELECT @p1" (Only (1 :: Int))))
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "late"
        Right v -> expectationFailure ("succeeded with " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
