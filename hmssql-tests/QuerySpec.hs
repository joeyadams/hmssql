module QuerySpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.IORef
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestConfig
import TestDb (skipBeforeSql2019)

spec :: Spec
spec = around withTestDb $ do
  mars <- runIO testMars
  describe "a query without parameters: sent as a plain batch" $ do
    it "selects a literal" $ \conn -> do
      r <- query1 conn "SELECT 2 + 2"
      r `shouldBe` Only (4 :: Int)

    it "decodes several columns" $ \conn -> do
      r <- query1 conn "SELECT CAST(1 AS bit), CAST(42 AS bigint), N'héllo', CAST(3.25 AS float)"
      r `shouldBe` (True, 42 :: Int64, "héllo" :: Text, 3.25 :: Double)

    it "decodes NULL as Nothing" $ \conn -> do
      r <- query1 conn "SELECT CAST(NULL AS int), 7"
      r `shouldBe` (Nothing :: Maybe Int, 7 :: Int)

    it "rejects NULL for a non-Maybe type" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS int)" :: IO (Only Int))
      case r of
        Left (DecodeError _ _) -> pure ()
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects a type mismatch before reading rows" $ \conn -> do
      r <- try (query conn "SELECT N'x'" :: IO [Only Int])
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "nvarchar"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "returns many rows" $ \conn -> do
      rows <- query conn "SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns"
      map fromOnly rows `shouldBe` [1 .. 1000 :: Int64]

    it "folds the rows as they arrive (queryFold)" $ \conn -> do
      n <- queryFold conn "SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns" (0 :: Int64) $
        \acc (Only i) -> pure (acc + i)
      n `shouldBe` sum [1 .. 1000]

    -- The step runs in the middle of the response; one that makes another
    -- request abandons the rest of it, and no step runs for the rows the
    -- fold already had (they belong to a result the API has given up).
    -- Under MARS the step's request runs beside the response, which it
    -- leaves alone: the fold goes on to the end.
    it (if mars
          then "runs every step when each makes another request, which runs beside the response (queryFold, MARS)"
          else "runs no step after one that abandons the response with another request (queryFold)") $ \conn -> do
      steps <- newIORef (0 :: Int)
      r <- try $ queryFold conn "SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns" () $
        \() (Only (i :: Int64)) -> do
          modifyIORef' steps (+ 1)
          query1 conn ("SELECT " <> param i) `shouldReturn` Only i
      case r of
        Left ResultAbandoned | not mars -> pure ()
        Right () | mars -> pure ()
        Left ResultAbandoned -> expectationFailure "the fold was abandoned"
        Right () -> expectationFailure "the fold completed"
      readIORef steps `shouldReturn` (if mars then 1000 else 1)
      -- The connection is usable.
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)

    it "reports server errors" $ \conn -> do
      r <- try (execute conn "RAISERROR('boom', 16, 1)")
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 50000
          sqlErrorMessage e `shouldBe` "boom"
        Right n -> expectationFailure ("succeeded with " ++ show n)
      -- connection still usable
      r2 <- query1 conn "SELECT 1"
      r2 `shouldBe` Only (1 :: Int)

    it "reports syntax errors with the statement" $ \conn -> do
      r <- try (execute conn "SELEC 1")
      case r of
        Left e -> sqlErrorStatement e `shouldBe` Just "SELEC 1"
        Right n -> expectationFailure ("succeeded with " ++ show n)

  describe "a query with parameters: sent through sp_executesql" $ do
    it "round-trips scalar types" $ \conn -> do
      let d = fromGregorian 2024 2 29
          tod = TimeOfDay 13 45 (30.1234567)
          lt = LocalTime d tod
          dto = DateTimeOffset (UTCTime d 3600) (-300)
          uuid = UUID.fromWords 1 2 3 4
      r <- query1 conn $ mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9"
             (123 :: Int, "text" :: Text, 1.5 :: Double, d, tod, lt, dto, uuid, B.pack [1, 2, 3])
      r `shouldBe` (123 :: Int, "text" :: Text, 1.5 :: Double, d, tod, lt, dto, uuid, B.pack [1, 2, 3])

    it "round-trips decimals and money" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @p1, CAST(@p2 AS money), @p3" (12345.678 :: Decimal, Money 99.9999, -0.5 :: Decimal))
      r `shouldBe` (12345.678 :: Decimal, Money 99.9999, -0.5 :: Decimal)

    it "sends NULL parameters" $ \conn -> do
      r <- query1 conn ("SELECT " <> param (Nothing :: Maybe Int) <> ", " <> param (Just "x" :: Maybe Text))
      r `shouldBe` (Nothing :: Maybe Int, Just "x" :: Maybe Text)

    it "sends large text as nvarchar(max)" $ \conn -> do
      let big = T.replicate 20000 "ab"
      Only r <- query1 conn ("SELECT " <> param big)
      r `shouldBe` big

    it "counts affected rows" $ \conn -> do
      _ <- execute conn "CREATE TABLE #t (i int)"
      n <- execute conn (mkQuery "INSERT INTO #t VALUES (@p1), (@p2), (@p3)" (1 :: Int, 2 :: Int, 3 :: Int))
      n `shouldBe` 3

    it "sends a heterogeneous [SqlParam] list" $ \conn -> do
      r <- query1 conn $ mkQuery "SELECT @p1, @p2, @p3"
             [SqlParam (7 :: Int), SqlParam ("x" :: Text), SqlParam (Nothing :: Maybe UUID)]
      r `shouldBe` (7 :: Int, "x" :: Text, Nothing :: Maybe UUID)

  describe "named parameters" $ do
    it "binds by name, not position" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @b, @a" (NamedParams [("a", SqlParam (1 :: Int)), ("b", SqlParam ("two" :: Text))]))
      r `shouldBe` ("two" :: Text, 1 :: Int)

    it "allows a name to be used several times in the SQL" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @n + @n" (NamedParams [("n", SqlParam (21 :: Int))]))
      r `shouldBe` Only (42 :: Int)

    it "accepts names with or without a leading @" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @a, @b" (NamedParams [("@a", SqlParam (1 :: Int)), ("b", SqlParam (2 :: Int))]))
      r `shouldBe` (1 :: Int, 2 :: Int)

    it "sends NULL through SqlParam" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @x" (NamedParams [("x", SqlParam (Nothing :: Maybe Int))]))
      r `shouldBe` Only (Nothing :: Maybe Int)

    it "rejects duplicate names" $ \conn -> do
      r <- try (query1 conn (mkQuery "SELECT @a" (NamedParams [("a", SqlParam (1 :: Int)), ("@A", SqlParam (2 :: Int))])) :: IO (Only Int))
      case r of
        Left (EncodeError msg) -> msg `shouldContain` "duplicate"
        Right v -> expectationFailure ("succeeded with " ++ show v)

    it "rejects an empty name" $ \conn -> do
      r <- try (query1 conn (mkQuery "SELECT 1" (NamedParams [("", SqlParam (1 :: Int))])) :: IO (Only Int))
      case r of
        Left (EncodeError _) -> pure ()
        Right v -> expectationFailure ("succeeded with " ++ show v)

  describe "the Query type against the server" $ do
    it "runs a query without parameters as a batch: a #temp table it creates outlives it" $ \conn -> do
      _ <- execute conn "CREATE TABLE #t (i int)"
      execute conn ("INSERT INTO #t VALUES (" <> param (1 :: Int) <> ")") `shouldReturn` 1

    it "runs a query without parameters as a batch: SET NOCOUNT ON persists, but not when sent with a parameter" $ \conn -> do
      _ <- execute conn "CREATE TABLE #t (i int)"
      -- Inside sp_executesql the SET reverts when the call returns.
      query1 conn ("SET NOCOUNT ON; SELECT " <> param (1 :: Int)) `shouldReturn` Only (1 :: Int)
      execute conn "INSERT INTO #t VALUES (1)" `shouldReturn` 1
      -- A batch's SET stays for the session: DONE no longer carries a count.
      _ <- execute conn "SET NOCOUNT ON"
      execute conn "INSERT INTO #t VALUES (2)" `shouldReturn` 0
      query1 conn "SELECT COUNT(*) FROM #t" `shouldReturn` Only (2 :: Int)

    it "reports a failing parameterized query with its text as sent, placeholders included" $ \conn -> do
      r <- try (query1 conn ("SELECT 1/" <> param (0 :: Int)) :: IO (Only Int))
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 8134
          sqlErrorStatement e `shouldBe` Just "SELECT 1/@p1"
        Right v -> expectationFailure ("succeeded with " ++ show v)

    it "numbers positional parameters across <> and binds named ones among them" $ \conn -> do
      let q = "SELECT " <> param (1 :: Int) <> ", " <> namedParam "b" ("two" :: Text) <> ", " <> param (3 :: Int)
      queryText q `shouldBe` "SELECT @p1, @b, @p2"
      query1 conn q `shouldReturn` (1 :: Int, "two" :: Text, 3 :: Int)

    it "renumbers mkQuery's placeholders when composed with param" $ \conn -> do
      let q = mkQuery "SELECT @p2, @p1" (1 :: Int, 2 :: Int) <> ", " <> param (3 :: Int)
      queryText q `shouldBe` "SELECT @p2, @p1, @p3"
      query1 conn q `shouldReturn` (2 :: Int, 1 :: Int, 3 :: Int)

    it "refuses one name for two parameters across <>, before sending anything" $ \conn -> do
      _ <- execute conn "CREATE TABLE #t (i int)"
      let viaNamedParam = "INSERT INTO #t VALUES (" <> namedParam "a" (1 :: Int) <> "), (" <> namedParam "A" (2 :: Int) <> ")"
          viaNamedParams = mkQuery "INSERT INTO #t VALUES (@a), " (NamedParams [("a", SqlParam (1 :: Int))])
            <> mkQuery "(@a)" (NamedParams [("@a", SqlParam (2 :: Int))])
      forM_ [viaNamedParam, viaNamedParams] $ \q -> do
        r <- try (execute conn q)
        case r of
          Left (EncodeError msg) -> msg `shouldContain` "duplicate"
          Right n -> expectationFailure ("succeeded with " ++ show n)
      query1 conn "SELECT COUNT(*) FROM #t" `shouldReturn` Only (0 :: Int)

    it "refuses a named parameter called @pN, which is reserved for the positional ones" $ \conn -> do
      let qs = [ "SELECT " <> namedParam "p1" (1 :: Int)
               , mkQuery "SELECT 1" (NamedParams [("p1", SqlParam (1 :: Int))])
               ]
      forM_ qs $ \q -> do
        r <- try (query1 conn q :: IO (Only Int))
        case r of
          Left (EncodeError msg) -> msg `shouldContain` "reserved"
          Right v -> expectationFailure ("succeeded with " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "refuses a placeholder with no parameter in mkQuery; rawSql leaves @p1 to the server" $ \conn -> do
      r <- try (query1 conn (mkQuery "SELECT @p1" ()) :: IO (Only Int))
      case r of
        Left (EncodeError msg) -> msg `shouldContain` "@p1"
        Right v -> expectationFailure ("succeeded with " ++ show v)
      r2 <- try (query1 conn (rawSql "SELECT @p1") :: IO (Only Int))
      case r2 of
        Left e -> sqlErrorNumber e `shouldBe` 137 -- must declare the scalar variable
        Right v -> expectationFailure ("succeeded with " ++ show v)

    it "keeps a placeholder apart from text that could continue its name" $ \conn -> do
      let q = "SELECT CAST(" <> param (5 :: Int) <> "AS int)"
      queryText q `shouldBe` "SELECT CAST(@p1 AS int)"
      query1 conn q `shouldReturn` Only (5 :: Int)

    it "escapes an identifier with escapeIdentifier" $ \conn -> do
      [ResultSet cols _] <- queryMulti conn ("SELECT 1 AS " <> escapeIdentifier "a]b")
      map columnName cols `shouldBe` ["a]b"]

  describe "server types" $ do
    it "decodes date/time family in binary" $ \conn -> do
      r <- query1 conn "SELECT CAST('2020-05-06' AS date), CAST('10:20:30.1234567' AS time), CAST('2020-05-06 10:20:30.123' AS datetime2(3)), CAST('2020-05-06 10:20:30 +02:00' AS datetimeoffset(0)), CAST('2020-05-06 10:20:30' AS datetime), CAST('2020-05-06 10:20:00' AS smalldatetime)"
      let d = fromGregorian 2020 5 6
      r `shouldBe`
        ( d
        , TimeOfDay 10 20 30.1234567
        , LocalTime d (TimeOfDay 10 20 30.123)
        , DateTimeOffset (UTCTime d (8 * 3600 + 20 * 60 + 30)) 120
        , LocalTime d (TimeOfDay 10 20 30)
        , LocalTime d (TimeOfDay 10 20 0)
        )

    it "decodes varchar(max) larger than a packet" $ \conn -> do
      Only r <- query1 conn "SELECT REPLICATE(CAST('x' AS varchar(max)), 100000)"
      T.length r `shouldBe` 100000

    it "decodes uniqueidentifier and varbinary" $ \conn -> do
      r <- query1 conn "SELECT CAST('01020304-0506-0708-090a-0b0c0d0e0f10' AS uniqueidentifier), CAST(0xDEADBEEF AS varbinary(8))"
      r `shouldBe` (UUID.fromWords 0x01020304 0x05060708 0x090a0b0c 0x0d0e0f10, B.pack [0xDE, 0xAD, 0xBE, 0xEF])

    it "decodes dynamically" $ \conn -> do
      [ResultSet cols [SqlRow _ vals]] <- queryMulti conn "SELECT 1 AS a, N'b' AS b, CAST(NULL AS int) AS c, CAST(1.5 AS decimal(3,1)) AS d"
      map columnName cols `shouldBe` ["a", "b", "c", "d"]
      vals `shouldBe` [SqlInt32 1, SqlText "b", SqlNull, SqlDecimal 1.5]

    it "decodes sql_variant" $ \conn -> do
      Only v <- query1 conn "SELECT CAST(CAST(7 AS int) AS sql_variant)"
      v `shouldBe` SqlInt32 7

    it "decodes NBCROW rows from a table with NULLs" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nbc (a int NULL, b nvarchar(10) NULL, c date NULL, d varbinary(10) NULL)"
      _ <- execute conn "INSERT INTO #nbc VALUES (1, NULL, '2001-02-03', NULL), (NULL, N'x', NULL, 0x01), (NULL, NULL, NULL, NULL)"
      rows <- query conn "SELECT a, b, c, d FROM #nbc ORDER BY a, b"
      rows `shouldBe`
        [ (Nothing, Nothing, Nothing, Nothing)
        , (Nothing, Just "x", Nothing, Just (B.pack [1]))
        , (Just (1 :: Int), Nothing :: Maybe Text, Just (fromGregorian 2001 2 3), Nothing :: Maybe B.ByteString)
        ]

    it "decodes legacy text, ntext and image columns" $ \conn -> do
      _ <- execute conn "CREATE TABLE #legacy (t text NULL, n ntext NULL, i image NULL)"
      _ <- execute conn "INSERT INTO #legacy VALUES ('abc', N'déf', 0x0102), (NULL, NULL, NULL)"
      rows <- query conn "SELECT t, n, i FROM #legacy ORDER BY CASE WHEN t IS NULL THEN 1 ELSE 0 END"
      rows `shouldBe`
        [ (Just ("abc" :: Text), Just ("déf" :: Text), Just (B.pack [1, 2]))
        , (Nothing, Nothing, Nothing)
        ]

    skipBeforeSql2019 "UTF-8 collations" $ it "decodes varchar with a UTF-8 collation" $ \conn -> do
      Only t <- query1 conn "SELECT CAST(N'héllo wörld' AS varchar(50)) COLLATE Latin1_General_100_CI_AS_SC_UTF8"
      t `shouldBe` ("héllo wörld" :: Text)

    it "decodes real and float" $ \conn -> do
      r <- query1 conn "SELECT CAST(1.5 AS real), CAST(2.25 AS float)"
      r `shouldBe` (1.5 :: Float, 2.25 :: Double)

    it "decodes xml" $ \conn -> do
      Only v <- query1 conn "SELECT CAST('<a><b>1</b></a>' AS xml)"
      v `shouldBe` SqlXml "<a><b>1</b></a>"

  describe "multiple result sets" $ do
    it "returns each set" $ \conn -> do
      sets <- queryMulti conn "SELECT 1; SELECT N'a', N'b'; SELECT 3"
      map (map sqlRowValues . resultRows) sets `shouldBe`
        [[[SqlInt32 1]], [[SqlText "a", SqlText "b"]], [[SqlInt32 3]]]

    it "query takes the first set and drains the rest" $ \conn -> do
      rows <- query conn "SELECT 1; SELECT 2; SELECT 3"
      rows `shouldBe` [Only (1 :: Int)]
      r <- query1 conn "SELECT 9"
      r `shouldBe` Only (9 :: Int)

  describe "every result set with one row decoder" $ do
    it "queryMultiWith decodes each set, empty ones included" $ \conn -> do
      sets <- queryMultiWith (rowDecoder :: RowDecoder (Only Int)) conn
        "SELECT 1; SELECT 2 WHERE 1 = 0; SELECT 3"
      map (map fromOnly . resultRows) sets `shouldBe` [[1], [], [3 :: Int]]

    it "queryMultiWith checks an empty set's columns, which has no row to check" $ \conn -> do
      r <- try (queryMultiWith (rowDecoder :: RowDecoder (Only Int)) conn
                 "SELECT 1; SELECT N'x', N'y' WHERE 1 = 0")
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "2 column"
        Right v -> expectationFailure ("decoded " ++ show (map (length . resultRows) v))

    it "queryMultiMWith adapts to each set's columns" $ \conn -> do
      sets <- queryMultiMWith sqlRowDecoder conn "SELECT 1; SELECT N'a', N'b'"
      map (map sqlRowValues . resultRows) sets `shouldBe`
        [[[SqlInt32 1]], [[SqlText "a", SqlText "b"]]]

  describe "the conveniences over query and execute" $ do
    it "execute_ runs the statement and discards the count" $ \conn -> do
      execute_ conn "CREATE TABLE #conv (i int NOT NULL)"
      execute_ conn "INSERT INTO #conv (i) VALUES (1), (2)"
      query conn "SELECT i FROM #conv ORDER BY i" `shouldReturn` [Only (1 :: Int), Only 2]

    it "execute_ still throws the server's error" $ \conn -> do
      r <- try (execute_ conn "RAISERROR(N'nope', 16, 1)")
      case r of
        Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 50000
        Right () -> expectationFailure "the statement succeeded"

    it "query1With and queryMayWith take a decoder instead of the row type's instance" $ \conn -> do
      let dec = singleField (fieldDecoder :: FieldDecoder Int)
      query1With dec conn "SELECT 7" `shouldReturn` 7
      queryMayWith dec conn "SELECT 7" `shouldReturn` Just 7
      queryMayWith dec conn "SELECT TOP 0 7" `shouldReturn` Nothing

    it "query1With throws UnexpectedResult without exactly one row" $ \conn -> do
      let dec = singleField (fieldDecoder :: FieldDecoder Int)
      forM_ ["SELECT TOP 0 7", "SELECT 7 UNION ALL SELECT 8"] $ \sql -> do
        r <- try (query1With dec conn (rawSql sql))
        case r of
          Left (UnexpectedResult _) -> pure ()
          Right v -> expectationFailure ("decoded " ++ show v)

  describe "typed result sets" $ do
    let batch = "DECLARE @x int; SET @x = 1; SELECT @x; SELECT N'a', N'b' WHERE 1=0; SELECT CAST(3 AS bigint)"
        three = (,,) <$> resultSet <*> resultSet <*> resultSet

    it "decodes each set with its own type, skipping rowless statements" $ \conn -> do
      r <- queryResultSets three conn batch
      r `shouldBe` ([Only (1 :: Int)], [] :: [(Text, Text)], [Only (3 :: Int64)])

    it "fails when asking for more sets than returned" $ \conn -> do
      r <- try (queryResultSets ((,) <$> three <*> resultSet) conn batch)
      case r of
        Left (UnexpectedResult msg) -> msg `shouldContain` "result set"
        Right (v :: (([Only Int], [(Text, Text)], [Only Int64]), [Only Int])) -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)

    it "reports a type mismatch in a later set" $ \conn -> do
      r <- try (queryResultSets ((,) <$> resultSet <*> resultSet) conn batch)
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "column"
        Right (v :: ([Only Int], [Only Int])) -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)

    it "still throws a server error raised after the last set" $ \conn -> do
      r <- try (queryResultSets resultSet conn "SELECT 1; RAISERROR('late', 16, 1)")
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "late"
        Right (v :: [Only Int]) -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)

    it "skips a set and keeps column metadata" $ \conn -> do
      (rows, ResultSet cols dyn) <- queryResultSets ((,) <$> (skipResultSet *> resultSet) <*> resultSetMWith sqlRowDecoder) conn
        "SELECT 1; SELECT N'a', N'b' WHERE 1=0; SELECT CAST(3 AS bigint) AS n"
      rows `shouldBe` ([] :: [(Text, Text)])
      map columnName cols `shouldBe` ["n"]
      map sqlRowValues dyn `shouldBe` [[SqlInt64 3]]

    it "lets a later decoder depend on earlier rows" $ \conn -> do
      let sets = do
            flags <- resultSet
            case flags of
              [Only (1 :: Int)] -> map fromOnly <$> resultSet
              _ -> pure []
      r <- queryResultSets sets conn (mkQuery "SELECT @flag; SELECT @v" (NamedParams [("flag", SqlParam (1 :: Int)), ("v", SqlParam ("yes" :: Text))]))
      r `shouldBe` ["yes" :: Text]

  describe "refineField" $ do
    let okOnly = refineField (\t -> if t == ("ok" :: Text) then Right () else Left "bad") fieldDecoder

    it "passes through successful refinements" $ \conn -> do
      r <- queryWith (singleField okOnly) conn "SELECT N'ok'"
      r `shouldBe` [()]

    it "reports a failed refinement as a DecodeError on the column" $ \conn -> do
      r <- try (queryWith (singleField okOnly) conn "SELECT N'nope' AS c")
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Just "c"
          msg `shouldBe` "bad"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "keeps NULL handling when wrapped in nullableField" $ \conn -> do
      r <- queryWith (singleField (nullableField okOnly)) conn "SELECT CAST(NULL AS nvarchar(10))"
      r `shouldBe` [Nothing]

  describe "streaming" $ do
    it "streams rows" $ \conn -> do
      s <- queryS conn "SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      n <- S.sum_ (S.map fromOnly s :: S.Stream (S.Of Int64) IO ())
      n `shouldBe` sum [1 .. 5000]

    it "cancels an abandoned stream on the next request" $ \conn -> do
      s <- queryS conn "SELECT TOP 200000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      firstFew <- S.toList_ (S.take 3 s) :: IO [Only Int64]
      map fromOnly firstFew `shouldBe` [1, 2, 3]
      r <- query1 conn "SELECT 42"
      r `shouldBe` Only (42 :: Int)

  describe "transactions" $ do
    it "commits" $ \conn -> do
      _ <- execute conn "CREATE TABLE #tx (i int)"
      withTransaction conn $ do
        inTransaction conn `shouldReturn` True
        _ <- execute conn "INSERT INTO #tx VALUES (1)"
        pure ()
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT COUNT(*) FROM #tx" `shouldReturn` Only (1 :: Int)

    it "rolls back on exception" $ \conn -> do
      _ <- execute conn "CREATE TABLE #tx2 (i int)"
      r <- try $ withTransaction conn $ do
        _ <- execute conn "INSERT INTO #tx2 VALUES (1)"
        _ <- execute conn "RAISERROR('fail', 16, 1)"
        pure ()
      case r of
        Left (_ :: SqlServerError) -> pure ()
        Right () -> expectationFailure "no error"
      inTransaction conn `shouldReturn` False
      query1 conn "SELECT COUNT(*) FROM #tx2" `shouldReturn` Only (0 :: Int)

  describe "stored procedures" $ do
    it "returns status, output params and result sets" $ \conn -> do
      _ <- execute conn "CREATE OR ALTER PROCEDURE #hmssql_test @a int, @b nvarchar(50) OUTPUT AS BEGIN SET @b = CONCAT(N'got ', @a); SELECT @a * 2; RETURN 7 END"
      let pa = inParam "@a" (21 :: Int32)
      let pb = outParam "@b" ("" :: Text)
      res <- callProcedure conn "#hmssql_test" [pa, pb]
      procReturnStatus res `shouldBe` Just 7
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 42]]]
      case procOutputValues res of
        [rv] -> decodeReturnValue rv `shouldBe` Right ("got 21" :: Text)
        other -> expectationFailure ("outputs: " ++ show other)
