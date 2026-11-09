-- | @Nothing :: Maybe ByteString@ is declared @varbinary(max)@, so an
-- expression typed by it (@ISNULL(\@p, col)@) isn't truncated; the server
-- refuses to convert a @(max)@ type to @sql_variant@ (error 206), so a NULL
-- for a @sql_variant@ needs a typed NULL (as for the untyped NULL's
-- @nvarchar(max)@).  A non-NULL value keeps its own length.
module Types.BinaryNullSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Encoding
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo (typeInfoSqlName)
import TestDb

sqlErrorNumbered :: Int32 -> Selector SqlServerError
sqlErrorNumbered n e = sqlErrorNumber e == n

declared :: ToSqlField a => a -> Either String Text
declared a = typeInfoSqlName . fst <$> encodeParam fieldEncoder defaultTdsContext a

nullBytes :: Maybe B.ByteString
nullBytes = Nothing

-- | Column types, and whether a binary NULL inserts into (and, for the
-- second flag, compares with) each.
targets :: [(Text, Bool, Bool)]
targets =
  [ (t, True, True) | t <- ["binary(10)", "varbinary(10)", "varbinary(max)", "int", "bigint", "bit"
                           , "decimal(10,2)", "money", "datetime", "uniqueidentifier", "nvarchar(10)", "nvarchar(max)"
                           , "varchar(max)", "hierarchyid"] ]
  ++ [ (t, True, False) | t <- ["image", "xml", "geography"] ]
  -- no implicit conversion from varbinary (257), or none from a large type (206)
  ++ [ (t, False, False) | t <- ["text", "ntext", "float", "datetime2", "date", "time", "datetimeoffset", "sql_variant"] ]

spec :: Spec
spec = do
  it "a NULL ByteString is declared varbinary(max); non-NULL values varbinary(8000) or (max)" $ do
    declared nullBytes `shouldBe` Right "varbinary(max)"
    declared (Nothing :: Maybe LB.ByteString) `shouldBe` Right "varbinary(max)"
    -- Whatever the length up to 8000, so the server reuses one plan.
    declared (Just (B.replicate 10 0)) `shouldBe` Right "varbinary(8000)"
    declared (Just B.empty) `shouldBe` Right "varbinary(8000)"
    declared (Just (B.replicate 8000 0)) `shouldBe` Right "varbinary(8000)"
    declared (Just (B.replicate 8001 0)) `shouldBe` Right "varbinary(max)"
    declared (Just ("x" :: Text)) `shouldBe` Right "nvarchar(4000)"
    declared (Just (T.replicate 4000 "x")) `shouldBe` Right "nvarchar(4000)"
    declared (Just (T.replicate 4001 "x")) `shouldBe` Right "nvarchar(max)"
    -- untyped NULLs
    declared (Nothing :: Maybe SqlValue) `shouldBe` Right "nvarchar(max)"
    declared (Nothing :: Maybe Text) `shouldBe` Right "nvarchar(max)"

  around withTestDb $ do
    -- varbinary(max) doesn't convert to sql_variant (error 206 "Operand type
    -- clash"); a typed NULL of a type that does is the way to store a NULL.
    it "is refused by a sql_variant column (error 206); a sql_variant NULL isn't" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #bv; CREATE TABLE #bv (v sql_variant NULL)"
      execute conn (mkQuery "INSERT INTO #bv VALUES (@p1)" (Only nullBytes)) `shouldThrow` sqlErrorNumbered 206
      (query conn (mkQuery "SELECT COUNT(*) FROM #bv WHERE v = @p1" (Only nullBytes)) :: IO [Only Int])
        `shouldThrow` sqlErrorNumbered 206
      void $ execute conn (mkQuery "INSERT INTO #bv VALUES (@p1)" (Only (RawParam (TISqlVariant 8016, Nothing))))
      query conn "SELECT v FROM #bv" `shouldReturn` [Only SqlNull]

    it "is refused by a sql_variant procedure parameter (error 206)" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #bp; EXEC ('CREATE PROCEDURE #bp @a sql_variant AS SELECT CASE WHEN @a IS NULL THEN 1 ELSE 0 END')"
      callProcedure conn "#bp" [inParam "@a" nullBytes] `shouldThrow` sqlErrorNumbered 206

    it "is not truncated by ISNULL (an expression typed by the parameter)" $ \conn -> do
      let long = B.replicate 10000 0x61
      -- Created in a batch: a #temp table created inside an RPC is dropped when
      -- the RPC returns.
      void $ execute conn "DROP TABLE IF EXISTS #bl; CREATE TABLE #bl (c varbinary(max) NOT NULL)"
      void $ execute conn (mkQuery "INSERT INTO #bl VALUES (@p1)" (Only long))
      query conn (mkQuery "SELECT ISNULL(@p1, c) FROM #bl" (Only nullBytes)) `shouldReturn` [Only long]

    it "reads back as a NULL varbinary" $ \conn -> do
      query conn ("SELECT " <> param nullBytes) `shouldReturn` [Only nullBytes]
      query conn (mkQuery "SELECT ISNULL(@p1, 0x0102)" (Only nullBytes)) `shouldReturn` [Only (B.pack [1, 2])]
      rows <- query conn ("SELECT " <> param nullBytes) :: IO [Only SqlValue]
      rows `shouldBe` [Only SqlNull]

    forM_ targets $ \(ty, insertOk, comparable) -> do
      it ((if insertOk then "inserts into " else "is refused by ") ++ T.unpack ty) $ \conn -> do
        void $ execute conn (rawSql ("DROP TABLE IF EXISTS #bn; CREATE TABLE #bn (v " <> ty <> " NULL)"))
        r <- try (execute conn (mkQuery "INSERT INTO #bn VALUES (@p1); UPDATE #bn SET v = @p1" (Only nullBytes)))
        if insertOk
          then do
            either (\(e :: SqlServerError) -> expectationFailure (show e)) (const (pure ())) r
            query conn "SELECT CASE WHEN v IS NULL THEN 1 ELSE 0 END FROM #bn" `shouldReturn` [Only (1 :: Int)]
          else case r of
            Left e -> sqlErrorNumber e `shouldSatisfy` (`elem` [206, 257])
            Right _ -> expectationFailure "inserted"
      when comparable $
        it ("compares with " ++ T.unpack ty) $ \conn -> do
          void $ execute conn (rawSql ("DROP TABLE IF EXISTS #bn; CREATE TABLE #bn (v " <> ty <> " NULL)"))
          query conn (mkQuery "SELECT COUNT(*) FROM #bn WHERE v = @p1 OR @p1 = v" (Only nullBytes)) `shouldReturn` [Only (0 :: Int)]

    it "as an output parameter's initial value is varbinary(max)" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #bo; EXEC ('CREATE PROCEDURE #bo @b varbinary(max) OUTPUT AS SET @b = CAST(REPLICATE(CAST(''a'' AS varchar(max)), 10000) AS varbinary(max))')"
      res <- callProcedure conn "#bo" [outParam "@b" nullBytes]
      map decodeReturnValue (procOutputValues res) `shouldBe` [Right (Just (B.replicate 10000 0x61))]
