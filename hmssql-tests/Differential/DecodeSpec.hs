-- | Differential decoding: random tables filled with T-SQL literals (no
-- hmssql parameters), read back as 'SqlRow's, and every cell compared with
-- the server's own canonical rendering of it (see "Differential.Schema").
module Differential.DecodeSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Differential.Schema
import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.CodePage (decodeUtf8Lenient)
import LiveProperty (liveHedgehog)
import TestDb

spec :: Spec
spec = do
  -- Ill-formed sequences become U+FFFD, but not necessarily as many as the
  -- server's own conversion makes, so these compare modulo runs of U+FFFD.
  describe "decodeUtf8Lenient" $ do
    it "decodes well-formed UTF-8" $
      decodeUtf8Lenient "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80" `shouldBe` "a\xE9\x20AC\x1F600"
    it "replaces a truncated sequence at the end with U+FFFD" $ do
      -- (The server trims these when storing, so there is nothing to
      -- compare with.)
      collapseFFFD (decodeUtf8Lenient "A\xC3") `shouldBe` "A\xFFFD"
      collapseFFFD (decodeUtf8Lenient "A\xE2\x82") `shouldBe` "A\xFFFD"
      collapseFFFD (decodeUtf8Lenient "A\xF0\x9F\x98") `shouldBe` "A\xFFFD"
      collapseFFFD (decodeUtf8Lenient "\xF4\x8F") `shouldBe` "\xFFFD"
      collapseFFFD (decodeUtf8Lenient "A\xE0") `shouldBe` "A\xFFFD"
    it "replaces overlong forms, encoded surrogates and code points above U+10FFFF with U+FFFD" $ do
      collapseFFFD (decodeUtf8Lenient "\xE0\x80\xAF") `shouldBe` "\xFFFD"
      collapseFFFD (decodeUtf8Lenient "\xED\xA0\x80") `shouldBe` "\xFFFD"
      collapseFFFD (decodeUtf8Lenient "\xF4\x90\x80\x80") `shouldBe` "\xFFFD"
      collapseFFFD (decodeUtf8Lenient "\xF0\x8F\x80") `shouldBe` "\xFFFD"
      collapseFFFD (decodeUtf8Lenient "\xED\xA0") `shouldBe` "\xFFFD"
    it "replaces bytes that can't start a sequence with U+FFFD" $
      collapseFFFD (decodeUtf8Lenient "\x80\xBF\xC0\xC1\xF5\xF8\xFF") `shouldBe` "\xFFFD"
    it "keeps the characters around an ill-formed sequence" $ do
      collapseFFFD (decodeUtf8Lenient "A\xE2\x82\x42") `shouldBe` "A\xFFFD\&B"
      collapseFFFD (decodeUtf8Lenient "\xE0\xA0\xC3\xA9") `shouldBe` "\xFFFD\xE9"
      collapseFFFD (decodeUtf8Lenient "A\xF0\x9F\x98\xF0\x9F\x98\x80") `shouldBe` "A\xFFFD\x1F600"
    it "never fails, and decodes well-formed input exactly (hedgehog)" $ hedgehog $ do
      bs <- forAllWith (T.unpack . hexText) genUtf8ish
      let t = decodeUtf8Lenient bs
      _ <- evalNF t
      case T.decodeUtf8' bs of
        Right exact -> t === exact
        -- every U+FFFD in the result replaces something ill-formed (or was
        -- itself in the input), and the rest round-trips
        Left _ -> T.filter (/= '\xFFFD') t === T.filter (/= '\xFFFD') (wellFormedParts bs)

  around withTestDb specWithDb

specWithDb :: SpecWith Connection
specWithDb = do
  describe "random tables inserted as T-SQL literals, read back as SqlRow" $ do
    modifyMaxShrinks (const 60) $ withCases 50 $
      it "match the server's canonical rendering of every cell (50 tables)" $ \conn ->
        liveHedgehog (decodeProperty conn)
    slow $ modifyMaxShrinks (const 60) $ withCases 3000 $
      it "match the server's canonical rendering of every cell (3000 tables)" $ \conn ->
        liveHedgehog (decodeProperty conn)

  -- hmssql's U+FFFDs may differ in number from the server's, so the
  -- comparisons collapse runs of U+FFFD.
  describe "invalid UTF-8 in a UTF-8 varchar column" $ skipBeforeSql2019 "UTF-8 collations" $ do
    forM_ invalidUtf8 $ \(label, bytes) ->
      it ("decodes " ++ label ++ " as the server converts it to nvarchar, modulo runs of U+FFFD") $ \conn -> do
        _ <- execute conn $ rawSql
          ( "DROP TABLE IF EXISTS #u; \
            \CREATE TABLE #u (v varchar(20) COLLATE Latin1_General_100_CI_AS_SC_UTF8); \
            \INSERT INTO #u VALUES (" <> hexLiteral bytes <> ")" )
        [(Only (stored :: B.ByteString), Only (serverText :: Text))] <-
          zip <$> query conn "SELECT CAST(v AS varbinary(20)) FROM #u"
              <*> query conn "SELECT CAST(v AS nvarchar(20)) FROM #u"
        -- the server keeps the bytes; hmssql should read the text the
        -- server itself makes of them, up to the number of U+FFFD
        stored `shouldBe` bytes
        [Only (decoded :: SqlValue)] <- query conn "SELECT v FROM #u"
        case decoded of
          SqlText t -> collapseFFFD t `shouldBe` collapseFFFD serverText
          v -> expectationFailure ("not SqlText: " ++ show v)
        [Only t] <- query conn "SELECT v FROM #u"
        collapseFFFD t `shouldBe` collapseFFFD serverText

    it "decodes it in char, varchar(max) and sql_variant as the server does, modulo runs of U+FFFD" $ \conn -> do
      _ <- execute conn
        "DROP TABLE IF EXISTS #u; \
        \CREATE TABLE #u (id int, c char(12) COLLATE Latin1_General_100_CI_AS_SC_UTF8, \
        \  m varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8, s sql_variant); \
        \INSERT INTO #u (id, c, m) VALUES (1, 0x41808042, 0x41808042), (2, 0xEDA080, 0xEDA080), \
        \  (3, 0xF4908080, 0xF4908080), (4, 0xC328, 0xC328); \
        \UPDATE #u SET s = CAST(m AS varchar(20)) COLLATE Latin1_General_100_CI_AS_SC_UTF8"
      got <- query conn "SELECT c, m, s FROM #u ORDER BY id"
      expected <- query conn
        "SELECT CAST(c AS nvarchar(12)), CAST(m AS nvarchar(max)), CAST(s AS nvarchar(20)) FROM #u ORDER BY id"
      length got `shouldBe` 4
      let collapsed (c, m, s) = (collapseFFFD c, collapseFFFD m, s')
            where s' = case s of SqlText t -> SqlText (collapseFFFD t); v -> v
      map collapsed got `shouldBe` [ collapsed (c, m, SqlText s) | (c :: Text, m :: Text, s :: Text) <- expected ]
      query conn "SELECT SQL_VARIANT_PROPERTY(s, 'Collation') FROM #u WHERE id = 1"
        `shouldReturn` [Only (SqlText "Latin1_General_100_CI_AS_SC_UTF8")]

    withCases 100 $
      it "decodes random bytes stored in a UTF-8 column as the server converts them, modulo runs of U+FFFD" $ \conn ->
        liveHedgehog (utf8Property conn)

-- | Ill-formed UTF-8 that a varbinary literal stores unchanged in a UTF-8
-- varchar.  (A sequence truncated at the end of the value is trimmed, and a
-- value starting with a byte that can't start a sequence is rejected.)
invalidUtf8 :: [(String, B.ByteString)]
invalidUtf8 =
  [ ("a lead byte followed by ASCII (C3 28)", B.pack [0xC3, 0x28])
  , ("a lone continuation byte (41 80 42)", B.pack [0x41, 0x80, 0x42])
  , ("a run of continuation bytes (41 80 80 80 BF 42)", B.pack [0x41, 0x80, 0x80, 0x80, 0xBF, 0x42])
  , ("a 2-byte overlong (41 C0 AF 42)", B.pack [0x41, 0xC0, 0xAF, 0x42])
  , ("a 2-byte overlong (41 C1 BF 42)", B.pack [0x41, 0xC1, 0xBF, 0x42])
  , ("a 3-byte overlong (E0 80 AF)", B.pack [0xE0, 0x80, 0xAF])
  , ("a 4-byte overlong (F0 80 82 AC 41)", B.pack [0xF0, 0x80, 0x82, 0xAC, 0x41])
  , ("an encoded high surrogate (ED A0 80)", B.pack [0xED, 0xA0, 0x80])
  , ("an encoded surrogate pair (ED A0 80 ED B0 80)", B.pack [0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80])
  , ("an encoded low surrogate (ED BF BF 41)", B.pack [0xED, 0xBF, 0xBF, 0x41])
  , ("a code point above U+10FFFF (F4 90 80 80)", B.pack [0xF4, 0x90, 0x80, 0x80])
  , ("a 4-byte form with lead F5 (41 F5 80 80 80 42)", B.pack [0x41, 0xF5, 0x80, 0x80, 0x80, 0x42])
  , ("an FF byte (41 FF 42)", B.pack [0x41, 0xFF, 0x42])
  , ("an FE byte (41 FE 42)", B.pack [0x41, 0xFE, 0x42])
  , ("a truncated 3-byte sequence before ASCII (E2 82 41)", B.pack [0xE2, 0x82, 0x41])
  , ("a truncated 4-byte sequence before ASCII (F0 9F 98 41)", B.pack [0xF0, 0x9F, 0x98, 0x41])
  , ("a truncated 3-byte sequence before a 2-byte one (E0 A0 C3 A9)", B.pack [0xE0, 0xA0, 0xC3, 0xA9])
  , ("a truncated 4-byte sequence before a 2-byte one (41 F0 9F 98 C3 A9)", B.pack [0x41, 0xF0, 0x9F, 0x98, 0xC3, 0xA9])
  ]

-- | Random bytes, biased towards (fragments of) UTF-8 sequences, stored in a
-- UTF-8 varchar through an implicit conversion from varbinary (which, unlike
-- a varchar parameter, keeps most ill-formed sequences), then read back both
-- by hmssql and as the server's own conversion to nvarchar.
utf8Property :: Connection -> PropertyT IO ()
utf8Property conn = do
  values <- forAllWith (show . map hexText) $ Gen.list (Range.linear 1 20) genUtf8ish
  rows <- evalIO $ do
    _ <- execute conn
      "DROP TABLE IF EXISTS #r; \
      \CREATE TABLE #r (id int, v varchar(200) COLLATE Latin1_General_100_CI_AS_SC_UTF8)"
    forM_ (zip [1 :: Int ..] values) $ \(i, bs) -> do
      -- the server rejects a value that starts with a byte that can't
      -- start a sequence (error 9833)
      r <- try (execute conn (mkQuery "INSERT INTO #r VALUES (@p1, @p2)" (i, bs)))
      either (\(_ :: SqlServerError) -> pure ()) (const (pure ())) r
    query conn
      "SELECT v, CAST(v AS varbinary(200)), CAST(CAST(v AS nvarchar(200)) AS varbinary(400)) FROM #r ORDER BY id"
  cover 30 "ill-formed UTF-8 stored" $
    any (\(_, stored, _) -> either (const True) (const False) (T.decodeUtf8' stored)) (rows :: [(Text, B.ByteString, B.ByteString)])
  forM_ rows $ \(decoded, stored, utf16) -> do
    annotate (T.unpack (hexText stored))
    collapseFFFD decoded === collapseFFFD (T.decodeUtf16LE utf16)

-- | Collapse each run of consecutive U+FFFD into one.
collapseFFFD :: Text -> Text
collapseFFFD = T.concat . map squash . T.group
  where squash g = if T.head g == '\xFFFD' then "\xFFFD" else g

-- | The well-formed sequences of some bytes, decoded, with a U+FFFD for each
-- maximal ill-formed stretch between them (a reference for
-- 'decodeUtf8Lenient', found by trying each prefix length at each position).
wellFormedParts :: B.ByteString -> Text
wellFormedParts = go
  where
    go bs
      | B.null bs = ""
      | otherwise = case [ (t, n) | n <- [1 .. min 4 (B.length bs)]
                                  , Right t <- [T.decodeUtf8' (B.take n bs)], T.length t == 1 ] of
          (t, n) : _ -> t <> go (B.drop n bs)
          [] -> "\xFFFD" <> go (B.drop 1 bs)

genUtf8ish :: Gen B.ByteString
genUtf8ish = B.concat <$> Gen.list (Range.linear 0 12) piece
  where
    piece = Gen.frequency
      [ (3, B.singleton <$> Gen.word8 (Range.constant 0x20 0x7E))
      , (3, T.encodeUtf8 . T.singleton <$> Gen.unicode)
      , (2, B.take <$> Gen.int (Range.constant 1 3) <*> (T.encodeUtf8 . T.singleton <$> Gen.unicode))
      , (3, B.singleton <$> Gen.word8 (Range.constant 0x80 0xBF))
      , (3, B.singleton <$> Gen.element [0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xED, 0xEF, 0xF0, 0xF1, 0xF4, 0xF5, 0xF8, 0xFE, 0xFF])
      , (1, B.singleton <$> Gen.word8 Range.constantBounded)
      ]

isLob :: ColType -> Bool
isLob = \case
  TStr _ LenMax _ -> True
  TVarBinary LenMax -> True
  TText _ -> True
  TNText -> True
  TImage -> True
  TXml -> True
  _ -> False

hexLiteral :: B.ByteString -> Text
hexLiteral bs = "0x" <> hexText bs

decodeProperty :: Connection -> PropertyT IO ()
decodeProperty conn = do
  cs <- evalIO (collationsFor <$> testSqlVersion)
  t <- forAllWith (scriptFor "#t") (genTable cs)
  let ncols = length (tableColumns t)
      nrows = length (tableRows t)
  classify "20+ columns" (ncols >= 20)
  classify "100+ rows" (nrows >= 100)
  classify "no rows" (nrows == 0)
  classify "a sql_variant column" (any ((== TVariant) . colType) (tableColumns t))
  classify "a (max) or LOB column" (any (isLob . colType) (tableColumns t))
  (rows, canon) <- evalIO $ do
    setupTable conn "#t" t
    rows <- queryMWith sqlRowDecoder conn (rawSql (selectSql "#t" t))
    canon <- readCanon conn "#t" t
    pure (rows, canon)
  length canon === length (tableRows t)
  length rows === length canon
  let cols = tableColumns t
      mismatches =
        [ "row " ++ show i ++ ", " ++ T.unpack (colName col) ++ " " ++ T.unpack (colTypeSql (colType col))
            ++ ":\n  server:  " ++ show srv
            ++ "\n  hmssql:  " ++ show v
            ++ "\n  as text: " ++ either ("<" ++) show hs
        | (i, r, cr) <- zip3 [1 :: Int ..] rows canon
        , (col, v, srv) <- zip3 cols (sqlRowValues r) cr
        , let hs = canonHs (colType col) v
        , hs /= Right srv
        ]
  unless (null mismatches) $ do
    annotate (unlines (take 10 mismatches))
    failure
  -- the column metadata agrees with the schema
  forM_ (take 1 rows) $ \r -> do
    map columnName (sqlRowColumns r) === map colName cols
    map columnIsNullable (sqlRowColumns r) === map colNullable cols
