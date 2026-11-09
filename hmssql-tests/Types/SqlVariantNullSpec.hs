-- | NULL @sql_variant@ values: the server sends them with a zero length
-- ([MS-TDS] 2.2.5.2.3, SSVARIANT), not the 0xFFFFFFFF of other LONGLEN types.
module Types.SqlVariantNullSpec (spec) where

import Wire.RecipeGet (getValue)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Encoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo (putValue)
import TestDb

variantNull :: RawParam
variantNull = RawParam (TISqlVariant 8016, Nothing)

spec :: Spec
spec = do
  describe "wire" $ do
    it "reads a zero-length sql_variant as NULL" $ do
      let bytes = LB.pack [0, 0, 0, 0]
      Get.runGet (getValue defaultTdsContext (TISqlVariant 8016)) bytes `shouldBe` Nothing
    it "writes a NULL sql_variant as a zero length" $
      Put.runPut (putValue defaultTdsContext (TISqlVariant 8016) Nothing) `shouldBe` LB.pack [0, 0, 0, 0]

  around withTestDb $ do
    it "decodes CAST(NULL AS sql_variant) as SqlNull" $ \conn ->
      query1 conn "SELECT CAST(NULL AS sql_variant)" `shouldReturn` Only SqlNull

    it "decodes CAST(NULL AS sql_variant) as Nothing" $ \conn ->
      query1 conn "SELECT CAST(NULL AS sql_variant)" `shouldReturn` Only (Nothing :: Maybe SqlValue)

    it "decodes SESSIONPROPERTY of an unknown option as NULL" $ \conn ->
      query1 conn "SELECT SESSIONPROPERTY('bogus')" `shouldReturn` Only SqlNull

    it "still decodes non-NULL SESSIONPROPERTY values" $ \conn ->
      query1 conn "SELECT SESSIONPROPERTY('ANSI_NULLS')" `shouldReturn` Only (SqlInt32 1)

    it "decodes a sql_variant column mixing NULL and non-NULL rows" $ \conn -> do
      _ <- execute conn "CREATE TABLE #sv (id int NOT NULL, v sql_variant NULL)"
      -- One INSERT per row: a multi-row VALUES would unify the base types.
      _ <- execute conn
        "INSERT INTO #sv VALUES (1, NULL); INSERT INTO #sv VALUES (2, CAST(5 AS int)); \
        \INSERT INTO #sv VALUES (3, NULL); INSERT INTO #sv VALUES (4, N'abc'); \
        \INSERT INTO #sv VALUES (5, CAST(1.5 AS decimal(3,1))); INSERT INTO #sv VALUES (6, NULL); \
        \INSERT INTO #sv VALUES (7, CAST('2001-02-03' AS date)); INSERT INTO #sv VALUES (8, NULL)"
      rows <- query conn "SELECT id, v FROM #sv ORDER BY id"
      rows `shouldBe`
        [ (1 :: Int, SqlNull), (2, SqlInt32 5), (3, SqlNull), (4, SqlText "abc")
        , (5, SqlDecimal 1.5), (6, SqlNull), (7, SqlDate (read "2001-02-03")), (8, SqlNull) ]
      mrows <- query conn "SELECT v FROM #sv WHERE id IN (1, 2) ORDER BY id"
      mrows `shouldBe` [Only Nothing, Only (Just (SqlInt32 5))]

    it "decodes an all-NULL sql_variant column (NBCROW)" $ \conn -> do
      _ <- execute conn "CREATE TABLE #sv2 (a sql_variant NULL, b sql_variant NULL, c int NULL)"
      _ <- execute conn "INSERT INTO #sv2 VALUES (NULL, NULL, 1), (NULL, 2, NULL)"
      rows <- query conn "SELECT a, b, c FROM #sv2 ORDER BY c DESC"
      rows `shouldBe` [(SqlNull, SqlNull, Just (1 :: Int)), (SqlNull, SqlInt32 2, Nothing)]

    it "sends a NULL sql_variant parameter" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT CASE WHEN @p1 IS NULL THEN 1 ELSE 0 END, @p1, SQL_VARIANT_PROPERTY(@p1, 'BaseType')" (Only variantNull))
      r `shouldBe` (1 :: Int, SqlNull, SqlNull)

    it "inserts a NULL sql_variant parameter into a table" $ \conn -> do
      _ <- execute conn "CREATE TABLE #sv3 (v sql_variant NULL)"
      _ <- execute conn (mkQuery "INSERT INTO #sv3 VALUES (@p1)" (Only variantNull))
      query1 conn "SELECT COUNT(*) FROM #sv3 WHERE v IS NULL" `shouldReturn` Only (1 :: Int)

    it "decodes a NULL sql_variant output parameter" $ \conn -> do
      let stmt = "SET @out = NULL" :: Text
      let p1 = inParam "" stmt
      let p2 = inParam "" ("@out sql_variant OUTPUT" :: Text)
      let out = outParam "@out" variantNull
      res <- callProcedure conn "sp_executesql" [p1, p2, out]
      map (decodeReturnValue @SqlValue) (procOutputValues res) `shouldBe` [Right SqlNull]
      map (decodeReturnValue @(Maybe SqlValue)) (procOutputValues res) `shouldBe` [Right Nothing]

    it "decodes a non-NULL sql_variant output parameter" $ \conn -> do
      let p1 = inParam "" ("SET @out = CAST(42 AS bigint)" :: Text)
      let p2 = inParam "" ("@out sql_variant OUTPUT" :: Text)
      let out = outParam "@out" variantNull
      res <- callProcedure conn "sp_executesql" [p1, p2, out]
      map (decodeReturnValue @SqlValue) (procOutputValues res) `shouldBe` [Right (SqlInt64 42)]
