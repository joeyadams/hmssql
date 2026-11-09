-- | Decoding single-byte character data (char, varchar, text, and varchar in
-- sql_variant) according to its collation's code page.
--
-- The ground truth is the server itself: the code page of each collation is
-- @COLLATIONPROPERTY(name, 'CodePage')@, and the decoding of each byte is the
-- server's own conversion to nvarchar.
module Types.CodePageSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM, forM_, replicateM, void)
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Hedgehog (failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Text.Printf (printf)

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.CodePage
import TestDb

spec :: Spec
spec = do
  describe "decode tables" $ do
    it "decode bytes 0x00-0x7F as ASCII in every single-byte code page" $
      forM_ singleByteCodePages $ \cp -> case singleByteDecoder cp of
        Nothing -> expectationFailure ("no decoder for " ++ show cp)
        Just dec -> do
          dec (B.pack [0 .. 127]) `shouldBe` T.pack ['\0' .. '\127']
          T.length (dec allBytes) `shouldBe` 256

    it "decode known characters, including bytes the code page leaves undefined" $ do
      let dec cp = maybe (error "no decoder") ($ B.pack [0x80, 0x81, 0x98, 0xDB, 0xE9]) (singleByteDecoder cp)
      dec 1252 `shouldBe` "\x20AC\x0081\x02DC\x00DB\x00E9"
      dec 1251 `shouldBe` "\x0402\x0403\x0098\x042B\x0439"
      dec 874 `shouldBe` "\x20AC\x0081\x0098\xF8C1\x0E49"
      dec 437 `shouldBe` "\x00C7\x00FC\x00FF\x2588\x0398"

    it "decode a string as the concatenation of its bytes, in every single-byte code page" $ hedgehog $ do
      -- ASCII runs of every length around the decoder's eight-byte steps,
      -- other bytes between them, sometimes thousands of bytes (past the
      -- size at which the decoder copies to cut its slack).
      cp <- forAll $ Gen.element singleByteCodePages
      bs <- forAll $ fmap B.concat $ Gen.list (Range.linear 0 30) $ Gen.frequency
        [ (4, Gen.bytes (Range.linear 0 40) >>= \b -> pure (B.map (`mod` 0x80) b))
        , (3, Gen.bytes (Range.linear 0 10))
        , (1, B.replicate <$> Gen.int (Range.linear 0 3000) <*> Gen.word8 (Range.constant 0x20 0x7E))
        ]
      case singleByteDecoder cp of
        Nothing -> failure
        Just dec -> dec bs === T.concat (map (dec . B.singleton) (B.unpack bs))

    it "have no decoder for double-byte code pages" $
      forM_ [932, 936, 949, 950, 65001] $ \cp ->
        (cp, void (singleByteDecoder cp)) `shouldBe` (cp, Nothing)

  around withTestDb $ do
    describe "every collation on the server" $ do
      it "maps to the server's code page" $ \conn -> do
        collations <- filter (\c -> collCodePage c /= 0) <$> serverCollations conn
        mismatches <- fmap concat $ forM (chunksOf 1000 collations) $ \chunk -> do
          let sql =
                "SET NOCOUNT ON; CREATE TABLE #m ("
                  <> commas [quoteName (collName c) <> " varchar(1) COLLATE " <> collName c <> " NULL" | c <- chunk]
                  <> "); INSERT #m DEFAULT VALUES; SELECT * FROM #m; DROP TABLE #m;"
          [got] <- queryMWith columnCodePages conn (rawSql sql)
          pure [ (collName c, collCodePage c, g)
               | (c, g) <- zip chunk got
               , g /= Just (fromIntegral (collCodePage c)) ]
        noFailures mismatches

      it "with a single-byte code page decodes all 256 byte values as the server does" $ \conn -> do
        collations <- filter (\c -> collCodePage c `elem` map fromIntegral singleByteCodePages) <$> serverCollations conn
        -- At least one collation per code page, and each SQL collation sort ID.
        length collations `shouldSatisfy` (> 2000)
        failures <- fmap concat $ forM (chunksOf 250 collations) $ \chunk -> do
          let names = map collName chunk
              sql =
                "SET NOCOUNT ON; DECLARE @b varbinary(256) = " <> allBytesLiteral <> "; CREATE TABLE #b ("
                  <> commas [quoteName n <> " varchar(256) COLLATE " <> n | n <- names]
                  <> "); INSERT #b SELECT " <> commas ["@b" | _ <- names]
                  <> "; SELECT " <> commas [ quoteName n <> ", " <> quoteName n <> ", CAST(" <> quoteName n <> " AS nvarchar(256))"
                                           | n <- names ]
                  <> " FROM #b; DROP TABLE #b;"
              row = replicateM (length names) $
                (,,) <$> singleFieldM (fieldDecoder @Text) <*> singleFieldM (fieldDecoder @B.ByteString) <*> singleFieldM (fieldDecoder @Text)
          [vals] <- queryMWith row conn (rawSql sql)
          pure [ (n, byteDiffs expected got)
               | (n, (got, raw, expected)) <- zip names vals
               , raw /= allBytes || got /= expected ]
        noFailures failures

      skipBeforeSql2019 "UTF-8 collations" $ it "with UTF-8 decodes UTF-8" $ \conn -> do
        collations <- filter (\c -> collCodePage c == 65001) <$> serverCollations conn
        length collations `shouldSatisfy` (> 1000)
        failures <- fmap concat $ forM (chunksOf 250 collations) $ \chunk -> do
          let names = map collName chunk
              sql =
                "SET NOCOUNT ON; DECLARE @s nvarchar(50) = @p1; CREATE TABLE #u ("
                  <> commas [quoteName n <> " varchar(50) COLLATE " <> n | n <- names]
                  <> "); INSERT #u SELECT " <> commas ["@s" | _ <- names]
                  <> "; SELECT " <> commas [quoteName n | n <- names] <> " FROM #u; DROP TABLE #u;"
          [vals] <- queryMWith (replicateM (length names) (singleFieldM (fieldDecoder @Text))) conn (mkQuery sql (Only unicodeSample))
          pure [(n, v) | (n, v) <- zip names vals, v /= unicodeSample]
        noFailures failures

    describe "column types" $
      forM_ representativeCollations $ \coll ->
        it ("char, varchar, varchar(max), text and sql_variant in " ++ T.unpack coll) $ \conn -> do
          let setup =
                "SET NOCOUNT ON; DECLARE @b varbinary(256) = " <> allBytesLiteral <> "; \
                \CREATE TABLE #t (ch char(256) COLLATE " <> coll <> ", vc varchar(256) COLLATE " <> coll <> ", \
                \  vm varchar(max) COLLATE " <> coll <> ", tx text COLLATE " <> coll <> ", sv sql_variant, sc sql_variant); \
                \INSERT #t (ch, vc, vm) VALUES (@b, @b, @b); UPDATE #t SET tx = vc, sv = vc, sc = ch; "
              select = "SELECT ch, vc, vm, tx, sv, sc, CAST(vc AS nvarchar(256)) FROM #t"
          void $ execute conn (rawSql setup)
          [(ch, vc, vm, tx, sv, sc, expected)] <- query conn select
          T.length expected `shouldBe` 256
          (ch, vc, vm, tx) `shouldBe` (expected, expected, expected, expected :: Text)
          (sv, sc) `shouldBe` (SqlText expected, SqlText expected)
          -- The dynamic decoding path
          [SqlRow _ vals] <- queryMWith sqlRowDecoder conn select
          vals `shouldBe` replicate 7 (SqlText expected)
          -- Other text types and NULL
          [(s, lt, n)] <- query conn "SELECT vc, vm, CAST(NULL AS varchar(10)) COLLATE Latin1_General_CI_AS FROM #t"
          (T.pack s, LT.toStrict lt, n) `shouldBe` (expected, expected, Nothing :: Maybe Text)
          -- Raw bytes are unchanged
          [Only raw] <- query conn "SELECT vm FROM #t"
          raw `shouldBe` allBytes

    -- A scratch database: the test changes the database's own collation,
    -- which needs the database to itself (ALTER DATABASE ... COLLATE fails
    -- with error 5030 while another connection uses it).
    it "uses the database's default collation" $ \_ ->
      withScratchDatabase "codepage" $ \ci -> withConnection ci $ \conn ->
        forM_ ["Greek_CI_AS", "SQL_Latin1_General_CP850_CI_AS", "Vietnamese_CI_AS"] $ \coll -> do
          void $ execute conn (rawSql ("ALTER DATABASE CURRENT COLLATE " <> coll))
          [Only dbColl] <- query conn "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128))"
          dbColl `shouldBe` coll
          void $ execute conn "CREATE TABLE dbo.codepage_default (v varchar(256))"
          void $ execute conn (rawSql ("INSERT dbo.codepage_default VALUES (" <> allBytesLiteral <> ")"))
          [(lit, col, sv, expected)] <- query conn
            ( rawSql ("SELECT CAST(" <> allBytesLiteral <> " AS varchar(256)), v, CAST(v AS sql_variant), \
              \CAST(v AS nvarchar(256)) FROM dbo.codepage_default") )
          T.length expected `shouldBe` 256
          (lit, col, sv) `shouldBe` (expected, expected :: Text, SqlText expected)
          void $ execute conn "DROP TABLE dbo.codepage_default"

    describe "double-byte collations" $
      forM_ doubleByteCollations $ \(coll, cp, sample) ->
        it ("are rejected with a clear error, and still decode as ByteString, in " ++ T.unpack coll) $ \conn -> do
          -- No parameters: a #temp table created inside sp_executesql would
          -- be dropped when it returns.
          void $ execute conn
            ( rawSql ("SET NOCOUNT ON; CREATE TABLE #d (v varchar(20) COLLATE " <> coll <> ", \
              \n varchar(20) COLLATE " <> coll <> " NULL, sv sql_variant); \
              \INSERT #d (v) VALUES (N'" <> sample <> "'); UPDATE #d SET sv = v;") )
          let expectDbcsError :: IO a -> IO ()
              expectDbcsError act = try act >>= \case
                Left (DecodeError _ msg) -> do
                  msg `shouldSatisfy` isInfixOf ("code page " ++ show (cp :: Int))
                  msg `shouldSatisfy` isInfixOf "ByteString"
                Right _ -> expectationFailure "expected a DecodeError"
          expectDbcsError (query conn "SELECT v FROM #d" :: IO [Only Text])
          expectDbcsError (query conn "SELECT v FROM #d" :: IO [Only String])
          -- The column is rejected up front, even when it only holds NULL.
          expectDbcsError (query conn "SELECT n FROM #d" :: IO [Only (Maybe Text)])
          expectDbcsError (query conn "SELECT v FROM #d" :: IO [Only SqlValue])
          expectDbcsError (queryMWith sqlRowDecoder conn "SELECT v FROM #d")
          -- A sql_variant's collation is only known per value.
          expectDbcsError (query conn "SELECT sv FROM #d" :: IO [Only SqlValue])
          [(raw, expectedRaw, viaNvarchar)] <- query conn "SELECT v, CAST(v AS varbinary(20)), CAST(v AS nvarchar(20)) FROM #d"
          raw `shouldBe` (expectedRaw :: B.ByteString)
          B.length raw `shouldSatisfy` (> T.length sample)
          viaNvarchar `shouldBe` sample
          -- nvarchar in the same collation is unaffected.
          [Only nv] <- query conn (mkQuery ("SELECT CAST(@p1 AS nvarchar(20)) COLLATE " <> coll) (Only sample))
          nv `shouldBe` sample

------------------------------------------------------------------------------

data Coll = Coll
  { collName :: !Text
  , collCodePage :: !Int
  }

serverCollations :: Connection -> IO [Coll]
serverCollations conn = map (uncurry Coll) <$> query conn
  "SELECT name, CAST(COLLATIONPROPERTY(name, 'CodePage') AS int) FROM sys.fn_helpcollations() ORDER BY name"

-- | The code page hmssql derives from each column's collation.
columnCodePages :: RowDecoderMonadic [Maybe CodePage]
columnCodePages = do
  cols <- remainingColumns
  forM cols $ \col -> do
    _ <- singleFieldM (fieldDecoder @(Maybe RawValue))
    pure $ case columnType col of
      TIBigVarChar _ c -> collationCodePage c
      _ -> Nothing

singleByteCodePages :: [CodePage]
singleByteCodePages = [437, 850, 874, 1250, 1251, 1252, 1253, 1254, 1255, 1256, 1257, 1258]

-- | A Windows collation and a SQL collation (where there is one) per code page.
representativeCollations :: [Text]
representativeCollations =
  [ "SQL_Latin1_General_CP437_CI_AS", "SQL_Latin1_General_CP850_BIN2", "SQL_Scandinavian_CP850_CI_AS"
  , "Thai_CI_AS"
  , "Czech_CI_AS", "SQL_Czech_CP1250_CI_AS"
  , "Cyrillic_General_CI_AS", "SQL_Latin1_General_CP1251_CI_AS"
  , "Latin1_General_CI_AS", "Latin1_General_100_BIN2", "SQL_Latin1_General_CP1_CI_AS", "SQL_EBCDIC037_CP1_CS_AS"
  , "Greek_CI_AS", "SQL_Latin1_General_CP1253_CI_AS"
  , "Turkish_CI_AS", "SQL_Latin1_General_CP1254_CI_AS"
  , "Hebrew_CI_AS", "SQL_Latin1_General_CP1255_CI_AS"
  , "Arabic_CI_AS", "SQL_Latin1_General_CP1256_CI_AS"
  , "Estonian_CI_AS", "SQL_Latin1_General_CP1257_CI_AS"
  , "Vietnamese_CI_AS"
  ]

doubleByteCollations :: [(Text, Int, Text)]
doubleByteCollations =
  [ ("Japanese_CI_AS", 932, "日本語テキスト")
  , ("Chinese_PRC_CI_AS", 936, "简体中文")
  , ("Korean_Wansung_CI_AS", 949, "한국어")
  , ("Chinese_Taiwan_Stroke_CI_AS", 950, "繁體中文")
  ]

unicodeSample :: Text
unicodeSample = "héllo Ω € ☃ 😀"

allBytes :: B.ByteString
allBytes = B.pack [0 .. 255]

allBytesLiteral :: Text
allBytesLiteral = T.pack ("0x" ++ concatMap (printf "%02X") (B.unpack allBytes))

-- | The first few bytes whose decoding differs.
byteDiffs :: Text -> Text -> [(Int, Char, Char)]
byteDiffs expected got
  | T.length expected /= T.length got = [(-1, '?', '?')]
  | otherwise = take 8 [(i, e, g) | (i, e, g) <- zip3 [0 ..] (T.unpack expected) (T.unpack got), e /= g]

commas :: [Text] -> Text
commas = T.intercalate ", "

-- | Like @`shouldBe` []@, but keeps the report (and hspec's diff) small.
noFailures :: Show a => [a] -> Expectation
noFailures [] = pure ()
noFailures xs = expectationFailure $
  show (length xs) ++ " failure(s); the first few:\n" ++ unlines (map show (take 10 xs))

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (a, b) = splitAt n xs in a : chunksOf n b
