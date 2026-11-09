-- | Shapes of the streaming query API (queryS / queryS): partial
-- consumption followed by a new request, zero-row streams, errors that
-- occur before any row is yielded, and draining of later result sets.
module Shapes.StreamingSpec (spec) where

import Control.Exception (try)
import Data.IORef
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $
  describe "streaming (queryS)" $ do
    it "consumes a few rows, then a different parameterized query runs cleanly" $ \conn -> do
      s <- queryS conn (mkQuery "SELECT TOP (@p1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns" (Only (100 :: Int)))
      firstFew <- S.toList_ (S.take 3 s) :: IO [Only Int]
      map fromOnly firstFew `shouldBe` [1, 2, 3]
      r <- query1 conn (mkQuery "SELECT @p1 * 2" (Only (21 :: Int)))
      r `shouldBe` Only (42 :: Int)

    it "streams a result set with zero rows, then the connection is usable" $ \conn -> do
      s <- queryS conn "SELECT TOP 0 1 AS x"
      rows <- S.toList_ s :: IO [Only Int]
      rows `shouldBe` []
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "throws immediately when the error precedes any row" $ \conn -> do
      r <- try $ do
        s <- queryS conn "RAISERROR('immediate', 16, 1); SELECT 1"
        S.toList_ s :: IO [Only Int]
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "immediate"
        Right rows -> expectationFailure ("got rows: " ++ show rows)
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)

    it "drains a later result set automatically once the first is fully consumed" $ \conn -> do
      s <- queryS conn "SELECT 1 AS x UNION ALL SELECT 2; SELECT 99 AS y"
      rows <- S.toList_ s :: IO [Only Int]
      map fromOnly rows `shouldBe` [1, 2]
      -- the second set (99) must be drained, not leaked into the next request
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

    it "querySMWith drains later sets the same way" $ \conn -> do
      s <- querySMWith sqlRowDecoder conn "SELECT 1; SELECT 2; SELECT 3"
      rows <- S.toList_ s
      map sqlRowValues rows `shouldBe` [[SqlInt32 1]]
      query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int)

    it "counts rows while streaming a moderately large result set" $ \conn -> do
      s <- queryS conn "SELECT TOP 10000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      n <- newIORef (0 :: Int)
      S.mapM_ (\(Only (_ :: Int)) -> modifyIORef' n (+ 1)) s
      readIORef n `shouldReturn` 10000
