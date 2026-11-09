-- | Differential encoding: the random tables of "Differential.Schema" are
-- filled twice, once with T-SQL literals and once with hmssql parameters
-- (one @INSERT ... VALUES (\@p1, ...)@ per row, a 'SqlValue' per column).
-- The server's canonical rendering of the parameter table must equal both
-- the rendering of the literal table and the canonical form of the Haskell
-- values that were sent.
module Differential.EncodeSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, unless, void, when)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import Test.Hspec
import Test.Hspec.Hedgehog

import Differential.Schema
import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Encoding
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo (typeInfoSqlName)
import LiveProperty (liveHedgehog)
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "random tables inserted with SqlValue parameters" $ do
    modifyMaxShrinks (const 60) $ withCases 30 $
      it "hold what the literals and the Haskell values say (30 tables)" $ \conn ->
        liveHedgehog (encodeProperty conn)
    slow $ modifyMaxShrinks (const 60) $ withCases 1500 $
      it "hold what the literals and the Haskell values say (1500 tables)" $ \conn ->
        liveHedgehog (encodeProperty conn)

  -- An untyped NULL is declared nvarchar(max), which the server won't
  -- convert to sql_variant: it needs a typed NULL.
  describe "NULL parameters into a sql_variant column" $ do
    it "SqlNull is refused (error 206)" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #v; CREATE TABLE #v (v sql_variant NULL)"
      execute conn (mkQuery "INSERT INTO #v VALUES (@p1)" (Only SqlNull)) `shouldThrow` sqlErrorNumbered 206
    it "Nothing :: Maybe Text is refused (error 206)" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #v; CREATE TABLE #v (v sql_variant NULL)"
      execute conn (mkQuery "INSERT INTO #v VALUES (@p1)" (Only (Nothing :: Maybe Text))) `shouldThrow` sqlErrorNumbered 206
    it "Nothing :: Maybe Int32 (a typed NULL)" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #v; CREATE TABLE #v (v sql_variant NULL)"
      void $ execute conn (mkQuery "INSERT INTO #v VALUES (@p1)" (Only (Nothing :: Maybe Int32)))
      query conn "SELECT v FROM #v" `shouldReturn` [Only SqlNull]
    it "RawParam (TISqlVariant 8016, Nothing) (a sql_variant NULL)" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #v; CREATE TABLE #v (v sql_variant NULL)"
      void $ execute conn (mkQuery "INSERT INTO #v VALUES (@p1)" (Only (RawParam (TISqlVariant 8016, Nothing))))
      query conn "SELECT v FROM #v" `shouldReturn` [Only SqlNull]

  describe "untyped NULL parameters" $ do
    it "are declared nvarchar(max)" $ \_ -> do
      let declared :: ToSqlField a => a -> Either String Text
          declared a = typeInfoSqlName . fst <$> encodeParam fieldEncoder defaultTdsContext a
      declared SqlNull `shouldBe` Right "nvarchar(max)"
      declared (Nothing :: Maybe Text) `shouldBe` Right "nvarchar(max)"
      declared (Nothing :: Maybe SqlParam) `shouldBe` Right "nvarchar(max)"
      declared (Nothing :: Maybe RawParam) `shouldBe` Right "nvarchar(max)"
      declared (SqlParam SqlNull) `shouldBe` Right "nvarchar(max)"
      -- a NULL of a concrete type keeps that type
      declared (Nothing :: Maybe Int32) `shouldBe` Right "int"
      declared (Nothing :: Maybe B.ByteString) `shouldBe` Right "varbinary(max)"

    it "read back as NULL" $ \conn -> do
      query1 conn (mkQuery "SELECT @p1, @p2, @p3" (SqlNull, Nothing :: Maybe Text, SqlParam SqlNull))
        `shouldReturn` (SqlNull, Nothing :: Maybe Text, SqlNull)
      -- an expression typed by the parameter stays Unicode
      query1 conn ("SELECT ISNULL(" <> param SqlNull <> ", N'\233\x4E2D')") `shouldReturn` Only ("\233\x4E2D" :: Text)
      -- and isn't truncated
      let long = T.replicate 5000 "\233"
      -- Created in a batch: a #temp table created inside an RPC is dropped when
      -- the RPC returns.
      void $ execute conn "DROP TABLE IF EXISTS #l; CREATE TABLE #l (c nvarchar(max) NOT NULL)"
      void $ execute conn (mkQuery "INSERT INTO #l VALUES (@p1)" (Only long))
      query conn (mkQuery "SELECT ISNULL(@p1, c) FROM #l" (Only SqlNull)) `shouldReturn` [Only long]

    forM_ untypedNulls $ \(nullName, nullParam) -> describe nullName $ do
      forM_ nullTargets $ \(ty, insertOk, comparable) -> do
        it ((if insertOk then "inserts into " else "is refused by ") ++ T.unpack ty) $ \conn -> do
          void $ execute conn (rawSql ("DROP TABLE IF EXISTS #n; CREATE TABLE #n (v " <> ty <> " NULL)"))
          r <- try (execute conn (mkQuery "INSERT INTO #n VALUES (@p1); UPDATE #n SET v = @p1" (Only nullParam)))
          if insertOk
            then do
              either (\(e :: SqlServerError) -> expectationFailure (show e)) (const (pure ())) r
              query conn "SELECT CASE WHEN v IS NULL THEN 1 ELSE 0 END FROM #n" `shouldReturn` [Only (1 :: Int)]
            else case r of
              -- 257 "Implicit conversion ... is not allowed", or 206
              -- "Operand type clash" for image and sql_variant
              Left e -> msgNumber (sqlError e) `shouldSatisfy` (`elem` [206, 257])
              Right _ -> expectationFailure "inserted"
        when comparable $
          it ("compares with " ++ T.unpack ty) $ \conn -> do
            void $ execute conn (rawSql ("DROP TABLE IF EXISTS #n; CREATE TABLE #n (v " <> ty <> " NULL)"))
            query conn (mkQuery "SELECT COUNT(*) FROM #n WHERE v = @p1 OR @p1 = v" (Only nullParam))
              `shouldReturn` [Only (0 :: Int)]
        when insertOk $
          it ("is passed to a procedure parameter of type " ++ T.unpack ty) $ \conn -> do
            void $ execute conn "DROP PROCEDURE IF EXISTS #pn"
            void $ execute conn (rawSql ("CREATE PROCEDURE #pn (@a " <> ty <> ") AS SELECT CASE WHEN @a IS NULL THEN 1 ELSE 0 END"))
            let p = inParam "@a" nullParam
            res <- callProcedure conn "#pn" [p]
            map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]
      -- nvarchar(max) doesn't convert to sql_variant (error 206 "Operand
      -- type clash") wherever it would have to
      it "is refused by a sql_variant comparison (error 206)" $ \conn -> do
        void $ execute conn "DROP TABLE IF EXISTS #n; CREATE TABLE #n (v sql_variant NULL)"
        (query conn (mkQuery "SELECT COUNT(*) FROM #n WHERE v = @p1" (Only nullParam)) :: IO [Only Int])
          `shouldThrow` sqlErrorNumbered 206
      it "is refused by a sql_variant procedure parameter (error 206)" $ \conn -> do
        void $ execute conn "DROP PROCEDURE IF EXISTS #pn"
        void $ execute conn "CREATE PROCEDURE #pn (@a sql_variant) AS SELECT CASE WHEN @a IS NULL THEN 1 ELSE 0 END"
        let p = inParam "@a" nullParam
        callProcedure conn "#pn" [p] `shouldThrow` sqlErrorNumbered 206

    it "work as the initial value of an output parameter (nvarchar(max))" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #po"
      void $ execute conn
        "CREATE PROCEDURE #po (@i int OUTPUT, @t nvarchar(max) OUTPUT, @u nvarchar(10) OUTPUT) AS \
        \SELECT @i = 5, @t = REPLICATE(CAST(N'\233' AS nvarchar(max)), 5000), @u = NULL"
      let pi' = outParam "@i" SqlNull
      let pt = outParam "@t" (Nothing :: Maybe Text)
      let pu = outParam "@u" SqlNull
      res <- callProcedure conn "#po" [pi', pt, pu]
      map (decodeReturnValue @SqlValue) (procOutputValues res)
        `shouldBe` [Right (SqlText "5"), Right (SqlText (T.replicate 5000 "\233")), Right SqlNull]

sqlErrorNumbered :: Int32 -> Selector SqlServerError
sqlErrorNumbered n e = sqlErrorNumber e == n

-- | NULLs whose SQL type hmssql doesn't know.
untypedNulls :: [(String, SqlParam)]
untypedNulls =
  [ ("SqlNull", SqlParam SqlNull)
  , ("Nothing :: Maybe Text", SqlParam (Nothing :: Maybe Text))
  , ("Nothing :: Maybe SqlParam", SqlParam (Nothing :: Maybe SqlParam))
  ]

-- | Column types for an untyped NULL: whether the server converts an
-- @nvarchar(max)@ NULL to it implicitly, and whether it has an @=@ operator
-- that accepts one.
nullTargets :: [(Text, Bool, Bool)]
nullTargets =
  [ (t, True, True)
  | t <- [ "int", "bigint", "smallint", "tinyint", "bit", "numeric(10,2)"
         , "decimal(38,10)", "money", "smallmoney", "float", "real", "date", "time", "datetime"
         , "datetime2", "datetimeoffset", "smalldatetime", "uniqueidentifier", "char(10)"
         , "varchar(10)", "varchar(max)", "nchar(10)", "nvarchar(10)", "nvarchar(max)", "hierarchyid" ] ]
  ++ [ (t, True, False) | t <- ["text", "ntext", "xml", "geography", "geometry"] ]
  -- the server converts no string type to binary implicitly
  ++ [ (t, False, True) | t <- ["binary(10)", "varbinary(10)", "varbinary(max)"] ]
  -- nor nvarchar(max) to sql_variant (206; comparisons are tested apart)
  ++ [ (t, False, False) | t <- ["image", "sql_variant"] ]

encodeProperty :: Connection -> PropertyT IO ()
encodeProperty conn = do
  cs <- evalIO (collationsFor <$> testSqlVersion)
  t <- forAllWith (scriptFor "#lit") (genTable cs)
  (lit, par) <- evalIO $ do
    setupTable conn "#lit" t
    createTable conn "#par" t
    let ins = paramInsertSql "#par" t
    forM_ (zip [1 ..] (tableRows t)) $ \(i, row) ->
      execute conn (mkQuery ins (rowParams t i row))
    (,) <$> readCanon conn "#lit" t <*> readCanon conn "#par" t
  length par === length (tableRows t)
  let mismatches =
        [ "row " ++ show i ++ ", " ++ T.unpack (colName col) ++ " " ++ T.unpack (colTypeSql (colType col))
            ++ ":\n  sent:           " ++ showCell cell
            ++ "\n  parameter table: " ++ show p
            ++ "\n  literal table:   " ++ show l
            ++ "\n  Haskell value:   " ++ either ("<" ++) show hs
        | (i, row, lrow, prow) <- zip4' [1 :: Int ..] (tableRows t) lit par
        , (col, cell, l, p) <- zip4' (tableColumns t) row lrow prow
        , colType col /= TRowVersion
        , let hs = case cell of
                CVal _ v _ -> canonHs (colType col) v
                _ -> Right Nothing
              -- the server normalizes XML, so only the literal table says
              -- what it should hold
              hsOk = colType col == TXml || hs == Right p
              litOk = not (exactLit cell) || l == p
        , not (hsOk && litOk)
        ]
  unless (null mismatches) $ do
    annotate (unlines (take 10 mismatches))
    failure
  where
    exactLit = \case
      CVal _ _ e -> e
      _ -> True
    showCell = \case
      CVal _ v _ -> show v
      c -> show c

zip4' :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4' (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4' as bs cs ds
zip4' _ _ _ _ = []
