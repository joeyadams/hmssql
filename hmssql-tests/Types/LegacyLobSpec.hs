-- | Legacy LOB types (text/ntext/image), sql_variant carrying character or
-- binary data, wide rows with many @(max)@ columns, NBCROW mixing many LOB
-- NULLs, and server-generated large/unknown-length values (FOR JSON,
-- FOR XML, STRING_AGG, REPLICATE).
module Types.LegacyLobSpec (spec) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "legacy text/ntext/image mixed with NULLs (NBCROW)" $ do
    it "decodes a wide row mixing several LOB columns with NULLs" $ \conn -> do
      _ <- execute conn "CREATE TABLE #wide_lob (a nvarchar(max), b varbinary(max), c text, d ntext, e image, f nvarchar(max))"
      _ <- execute conn
        "INSERT INTO #wide_lob VALUES (N'aaa', 0x0102, 'ccc', N'ddd', 0x0304, NULL), \
        \                             (NULL, NULL, NULL, NULL, NULL, N'fff'), \
        \                             (NULL, NULL, NULL, NULL, NULL, NULL)"
      rows <- query conn "SELECT a, b, c, d, e, f FROM #wide_lob ORDER BY (CASE WHEN a IS NOT NULL THEN 0 WHEN f IS NOT NULL THEN 1 ELSE 2 END)"
        :: IO [(Maybe Text, Maybe B.ByteString, Maybe Text, Maybe Text, Maybe B.ByteString, Maybe Text)]
      rows `shouldBe`
        [ (Just "aaa", Just (B.pack [1, 2]), Just "ccc", Just "ddd", Just (B.pack [3, 4]), Nothing)
        , (Nothing, Nothing, Nothing, Nothing, Nothing, Just "fff")
        , (Nothing, Nothing, Nothing, Nothing, Nothing, Nothing)
        ]

  describe "wide rows with many (max) columns" $ do
    it "decodes a row with 20 nvarchar(max) columns of varying sizes" $ \conn -> do
      let colExpr i = "REPLICATE(CAST(N'x' AS nvarchar(max)), " <> T.pack (show (i * 137)) <> ") AS c" <> T.pack (show i)
          sql = "SELECT " <> T.intercalate ", " (map colExpr [1 .. 20 :: Int])
      [row] <- queryMWith sqlRowDecoder conn (rawSql sql)
      let lens = [T.length t | SqlText t <- sqlRowValues row]
      length lens `shouldBe` 20
      lens `shouldBe` [i * 137 | i <- [1 .. 20]]

  describe "sql_variant carrying character or binary data" $ do
    it "decodes sql_variant containing nvarchar" $ \conn -> do
      Only v <- query1 conn "SELECT CAST(N'hello' AS sql_variant)"
      v `shouldBe` SqlText "hello"

    it "decodes sql_variant containing varbinary" $ \conn -> do
      Only v <- query1 conn "SELECT CAST(CAST(0x0102 AS varbinary(10)) AS sql_variant)"
      v `shouldBe` SqlBinary (B.pack [1, 2])

    it "decodes sql_variant containing char, padded" $ \conn -> do
      Only v <- query1 conn "SELECT CAST(CAST('ab' AS char(5)) AS sql_variant)"
      v `shouldBe` SqlText "ab   "

    it "decodes a NULL sql_variant" $ \conn ->
      query1 conn "SELECT CAST(NULL AS sql_variant)" `shouldReturn` Only SqlNull

  describe "server-generated large/unknown-length text" $ do
    it "decodes FOR JSON PATH output" $ \conn -> do
      Only (j :: Text) <- query1 conn "SELECT (SELECT 1 AS a, N'x' AS b FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)"
      T.isInfixOf "\"a\":1" j `shouldBe` True
      T.isInfixOf "\"b\":\"x\"" j `shouldBe` True

    it "decodes a FOR JSON PATH output spanning multiple PLP chunks" $ \conn -> do
      _ <- execute conn "CREATE TABLE #wj (i int)"
      _ <- execute conn "INSERT INTO #wj SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      Only (j :: Text) <- query1 conn "SELECT (SELECT i FROM #wj FOR JSON PATH)"
      T.length j `shouldSatisfy` (> 24000)
      length (T.breakOnAll "\"i\":" j) `shouldBe` 5000

    it "decodes FOR XML PATH output" $ \conn -> do
      _ <- execute conn "CREATE TABLE #fx (i int)"
      _ <- execute conn "INSERT INTO #fx VALUES (1), (2), (3)"
      Only (x :: Text) <- query1 conn "SELECT (SELECT i AS [i] FROM #fx FOR XML PATH(''))"
      T.isInfixOf "<i>1</i>" x `shouldBe` True
      T.isInfixOf "<i>2</i>" x `shouldBe` True
      T.isInfixOf "<i>3</i>" x `shouldBe` True

    it "STRING_AGG output switches to nvarchar(max) beyond 8000 characters" $ \conn -> do
      _ <- execute conn "CREATE TABLE #sa (v nvarchar(10))"
      _ <- execute conn "INSERT INTO #sa SELECT TOP (1000) RIGHT('0000000000' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS varchar(10)), 10) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      -- STRING_AGG's own result has an 8000-byte limit unless its argument is
      -- already a (max) type; CAST widens it to nvarchar(max).
      Only (agg :: Text) <- query1 conn "SELECT STRING_AGG(CAST(v AS nvarchar(max)), ',') FROM #sa"
      T.length agg `shouldSatisfy` (> 8000)

    it "REPLICATE produces nvarchar(max) beyond the non-max limit" $ \conn -> do
      Only (t :: Text) <- query1 conn "SELECT REPLICATE(CAST(N'ab' AS nvarchar(max)), 5000)"
      T.length t `shouldBe` 10000

    it "REPLICATE produces varbinary(max) beyond the non-max limit" $ \conn -> do
      Only (b :: B.ByteString) <- query1 conn "SELECT REPLICATE(CAST(0x01 AS varbinary(max)), 10000)"
      B.length b `shouldBe` 10000
