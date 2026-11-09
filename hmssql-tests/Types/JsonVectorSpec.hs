-- | SQL Server 2025's native @json@ and @vector@ types.  hmssql has no
-- explicit support for either: the server downgrades them to text for a
-- TDS 7.4/8.0 client, and this checks that they decode as such (never a
-- hang, a crash, or garbled data).
module Types.JsonVectorSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import TestDb

-- | 15s: generous, but a genuine hang should never happen.
withTimeout :: IO a -> IO (Maybe a)
withTimeout = timeout 15_000_000

spec :: Spec
spec = skipBeforeSql2025 "json and vector" $ around withTestDb $ do
  describe "the json type" $ do
    it "decodes CAST('{...}' AS json) as text, without hanging" $ \conn -> do
      r <- withTimeout (try (query1 conn "SELECT CAST('{\"a\":1}' AS json)" :: IO (Only Text)))
      case r of
        Nothing -> expectationFailure "BUG: query hung for 15s decoding a json value"
        Just (Right (Only t)) -> T.isInfixOf "\"a\":1" t `shouldBe` True
        Just (Left (e :: SomeException)) ->
          expectationFailure ("json type not decoded; hmssql raised: " ++ show e)

    it "decodes a NULL json value, without hanging" $ \conn -> do
      r <- withTimeout (try (query1 conn "SELECT CAST(NULL AS json)" :: IO (Only (Maybe Text))))
      case r of
        Nothing -> expectationFailure "BUG: query hung for 15s decoding a NULL json value"
        Just (Right (Only t)) -> t `shouldBe` Nothing
        Just (Left (e :: SomeException)) ->
          expectationFailure ("json type not decoded; hmssql raised: " ++ show e)

    -- Connection must still be usable after whatever happened above.
    it "leaves the connection usable afterwards" $ \conn -> do
      r <- withTimeout (try (query1 conn "SELECT CAST('{}' AS json)" :: IO (Only Text)) :: IO (Either SomeException (Only Text)))
      case r of
        Nothing -> expectationFailure "BUG: query hung for 15s"
        _ -> pure ()
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "the vector type" $ do
    it "decodes a vector column as its bracketed text form, without hanging" $ \conn -> do
      _ <- execute conn "CREATE TABLE #vec (v vector(3))"
      _ <- execute conn "INSERT INTO #vec VALUES ('[1,2,3]')"
      r <- withTimeout (try (query1 conn "SELECT v FROM #vec" :: IO (Only Text)))
      case r of
        Nothing -> expectationFailure "BUG: query hung for 15s decoding a vector value"
        -- The server downgrades vector to a bracketed textual form for a
        -- TDS 7.4/8.0 client (observed: "[1.0000000e+000,2.0000000e+000,3.0000000e+000]").
        Just (Right (Only t)) -> (T.isPrefixOf "[" t && T.isSuffixOf "]" t) `shouldBe` True
        Just (Left (e :: SomeException)) ->
          expectationFailure ("vector type not decoded; hmssql raised: " ++ show e)

    it "leaves the connection usable afterwards" $ \conn -> do
      _ <- execute conn "CREATE TABLE #vec2 (v vector(3))"
      _ <- execute conn "INSERT INTO #vec2 VALUES ('[1,2,3]')"
      r <- withTimeout (try (query1 conn "SELECT v FROM #vec2" :: IO (Only Text)) :: IO (Either SomeException (Only Text)))
      case r of
        Nothing -> expectationFailure "BUG: query hung for 15s"
        _ -> pure ()
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
