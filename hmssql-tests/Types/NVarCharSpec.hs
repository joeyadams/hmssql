-- | char/varchar/nchar/nvarchar (fixed, variable and @(max)@), including UTF-8
-- and default (ASCII-only) collations, NULL/empty/space handling, embedded
-- NUL, non-BMP characters, PLP boundary sizes, and decoding into every
-- supported Haskell text type.
module Types.NVarCharSpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_)
import Data.Int (Int32)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import Data.Word (Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestDb

-- | Whether a parameter was declared @nvarchar(max)@/@varchar(max)@ (as
-- opposed to a bounded length): @sql_variant@ cannot hold a @(max)@ type, so
-- @CAST(@p1 AS sql_variant)@ fails with error 529 exactly when it is.
isMaxParam :: ToSqlField a => Connection -> a -> IO Bool
isMaxParam conn v = do
  r <- try (query1 conn (mkQuery "SELECT CAST(SQL_VARIANT_PROPERTY(CAST(@p1 AS sql_variant), 'MaxLength') AS int)" (Only v))
             :: IO (Only (Maybe Int32)))
  case r of
    Left e | sqlErrorNumber e == 529 -> pure True
           | otherwise -> throwIO e
    Right _ -> pure False

withPacketSize :: Word32 -> (Connection -> IO a) -> IO a
withPacketSize sz act = do
  ci <- defaultTestConnectInfo
  withConnection ci { connectPacketSize = sz } act

emoji :: Text
emoji = "\x1F600" -- U+1F600 GRINNING FACE, a surrogate pair in UTF-16

spec :: Spec
spec = do
 around withTestDb $ do
  describe "empty string, single space, and NULL" $ do
    it "distinguishes them for nvarchar" $ \conn -> do
      r <- query1 conn "SELECT CAST('' AS nvarchar(10)), CAST(' ' AS nvarchar(10)), CAST(NULL AS nvarchar(10))"
      r `shouldBe` ("" :: Text, " " :: Text, Nothing :: Maybe Text)

    it "distinguishes them for varchar (default collation, ASCII-only)" $ \conn -> do
      r <- query1 conn "SELECT CAST('' AS varchar(10)), CAST(' ' AS varchar(10)), CAST(NULL AS varchar(10))"
      r `shouldBe` ("" :: Text, " " :: Text, Nothing :: Maybe Text)

    it "round trips an empty Text parameter" $ \conn -> do
      Only t <- query1 conn ("SELECT " <> param ("" :: Text))
      t `shouldBe` ("" :: Text)

  describe "char(n)/nchar(n) padding" $ do
    it "right-pads char(n) with spaces" $ \conn -> do
      Only t <- query1 conn "SELECT CAST('ab' AS char(5))"
      t `shouldBe` ("ab   " :: Text)

    it "right-pads nchar(n) with spaces" $ \conn -> do
      Only t <- query1 conn "SELECT CAST(N'ab' AS nchar(5))"
      t `shouldBe` ("ab   " :: Text)

    it "keeps trailing spaces already present, up to n" $ \conn -> do
      Only t <- query1 conn "SELECT CAST(N'ab   ' AS nchar(6))"
      t `shouldBe` ("ab    " :: Text)

  describe "embedded NUL characters" $ do
    it "round trips a NUL byte in an nvarchar(max) parameter" $ \conn -> do
      let t = "a\0b" :: Text
      Only t' <- query1 conn ("SELECT " <> param t)
      t' `shouldBe` t

    it "round trips a NUL byte through a temp table nvarchar column" $ \conn -> do
      _ <- execute conn "CREATE TABLE #nulchar (v nvarchar(10))"
      _ <- execute conn ("INSERT INTO #nulchar (v) VALUES (" <> param ("a\0b" :: Text) <> ")")
      Only t <- query1 conn "SELECT v FROM #nulchar"
      t `shouldBe` ("a\0b" :: Text)

  describe "non-BMP characters (surrogate pairs)" $ do
    it "round trips a lone non-BMP character" $ \conn -> do
      Only t <- query1 conn ("SELECT " <> param emoji)
      t `shouldBe` emoji

    it "round trips a non-BMP character at the start" $ \conn -> do
      let t = emoji <> "abc"
      Only t' <- query1 conn (mkQuery "SELECT @p1" (Only t))
      t' `shouldBe` t

    it "round trips a non-BMP character in the middle" $ \conn -> do
      let t = "ab" <> emoji <> "cd"
      Only t' <- query1 conn (mkQuery "SELECT @p1" (Only t))
      t' `shouldBe` t

    it "round trips a non-BMP character at the end" $ \conn -> do
      let t = "abc" <> emoji
      Only t' <- query1 conn ("SELECT " <> param t)
      t' `shouldBe` t

    it "round trips several consecutive non-BMP characters" $ \conn -> do
      let t = T.concat (replicate 5 emoji)
      Only t' <- query1 conn (mkQuery "SELECT @p1" (Only t))
      t' `shouldBe` t

    it "counts a surrogate pair as one LEN() unit pair (2 UTF-16 code units)" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT LEN(@p1), DATALENGTH(@p1)" (Only emoji)) :: IO (Int, Int)
      r `shouldBe` (2, 4)

  describe "lone surrogates stored by the server" $ do
    -- NCHAR(0xD800) is a lone (unpaired) high surrogate: 2 bytes on the wire
    -- (0x00 0xD8 little-endian), not a valid UTF-16 sequence.  hmssql
    -- decodes the ill-formed code unit to one U+FFFD (see
    -- hmssql-tests/Types/Utf16Spec.hs for the other cases and decode sites).
    it "decodes NCHAR(0xD800) without crashing" $ \conn -> do
      r <- try (query1 conn "SELECT NCHAR(0xD800)" :: IO (Only Text))
      case r of
        Right (Only t) -> t `shouldBe` "\xFFFD"
        Left (e :: DecodeError) -> expectationFailure ("decoding crashed: " ++ show e)

  describe "boundary: nvarchar(n) vs nvarchar(max) parameter encoding" $ do
    it "declares a bounded type at exactly 4000 characters" $ \conn -> do
      isMaxParam conn (T.replicate 4000 "x") `shouldReturn` False

    it "switches to nvarchar(max) at 4001 characters" $ \conn -> do
      isMaxParam conn (T.replicate 4001 "x") `shouldReturn` True

  describe "sizes around PLP chunk/packet boundaries" $ do
    let sizes = [0, 1, 2, 4000, 4001, 7999, 8000, 8001, 8002, 15999, 16000, 16001, 23999, 24000, 24001] :: [Int]
    forM_ sizes $ \n ->
      it ("round trips an nvarchar(max) parameter of length " ++ show n) $ \conn -> do
        let t = T.replicate n "a"
        Only t' <- query1 conn (mkQuery "SELECT @p1" (Only t))
        t' `shouldBe` t
        Only dlen <- query1 conn (mkQuery "SELECT DATALENGTH(@p1)" (Only t)) :: IO (Only Int)
        dlen `shouldBe` n * 2

  describe "varchar with a UTF-8 collation" $ skipBeforeSql2019 "UTF-8 collations" $ do
    it "round trips general unicode text through a temp table column" $ \conn -> do
      _ <- execute conn "CREATE TABLE #utf8v (v varchar(200) COLLATE Latin1_General_100_CI_AS_SC_UTF8)"
      let t = "héllo wörld - \20013\25991" :: Text
      _ <- execute conn ("INSERT INTO #utf8v (v) VALUES (" <> param t <> ")")
      Only t' <- query1 conn "SELECT v FROM #utf8v"
      t' `shouldBe` t

    it "round trips a non-BMP character through a temp table column" $ \conn -> do
      _ <- execute conn "CREATE TABLE #utf8nb (v varchar(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8)"
      _ <- execute conn ("INSERT INTO #utf8nb (v) VALUES (" <> param emoji <> ")")
      Only t' <- query1 conn "SELECT v FROM #utf8nb"
      t' `shouldBe` emoji

  describe "varchar/char with default collation, ASCII-only data" $ do
    it "round trips ASCII text through a temp table varchar(max) column" $ \conn -> do
      _ <- execute conn "CREATE TABLE #asciiv (v varchar(max))"
      let t = "Hello, World! 0123456789" :: Text
      _ <- execute conn (mkQuery "INSERT INTO #asciiv (v) VALUES (@p1)" (Only t))
      Only t' <- query1 conn "SELECT v FROM #asciiv"
      t' `shouldBe` t

    it "round trips ASCII text through a temp table char(n) column, padded" $ \conn -> do
      _ <- execute conn "CREATE TABLE #asciic (v char(10))"
      _ <- execute conn (mkQuery "INSERT INTO #asciic (v) VALUES (@p1)" (Only ("abc" :: Text)))
      Only t' <- query1 conn "SELECT v FROM #asciic"
      t' `shouldBe` ("abc       " :: Text)

  describe "decoding mismatches and NULL" $ do
    it "rejects decoding an int column as Text, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT 42 AS n" :: IO (Only Text))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects decoding a varbinary column as Text, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(0x01 AS varbinary(1)) AS n" :: IO (Only Text))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects NULL into a non-Maybe Text, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS nvarchar(10)) AS n" :: IO (Only Text))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "decoding into every supported text type" $ do
    it "decodes nvarchar into String" $ \conn -> do
      Only s <- query1 conn "SELECT N'h\233llo'" :: IO (Only String)
      s `shouldBe` "h\233llo"

    it "decodes nvarchar into lazy Text" $ \conn -> do
      Only t <- query1 conn "SELECT N'h\233llo'" :: IO (Only LT.Text)
      t `shouldBe` LT.pack "h\233llo"

    it "decodes ansi char/varchar raw bytes into ByteString" $ \conn -> do
      Only b <- query1 conn "SELECT CAST('abc' AS varchar(10))" :: IO (Only B.ByteString)
      b `shouldBe` B.pack [97, 98, 99]

  describe "SqlValue dynamic decoding" $ do
    it "decodes nvarchar, varchar and NULL text columns as SqlValue" $ \conn -> do
      [ResultSet cols [SqlRow _ vals]] <- queryMulti conn
        "SELECT N'a' AS a, CAST('b' AS varchar(5)) AS b, CAST(NULL AS nvarchar(5)) AS c"
      map columnName cols `shouldBe` ["a", "b", "c"]
      vals `shouldBe` [SqlText "a", SqlText "b", SqlNull]

  describe "hedgehog: Text round trips" $ do
    it "round trips arbitrary unicode Text via SELECT @p1" $ \conn -> liveHedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 3000) Gen.unicode
      Only t' <- evalIO $ query1 conn ("SELECT " <> param t)
      t' === t

    it "round trips arbitrary unicode Text through a temp table, matching DATALENGTH" $ \conn -> liveHedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 3000) Gen.unicode
      let expectedBytes = B.length (T.encodeUtf16LE t)
      evalIO $ do
        _ <- execute conn "IF OBJECT_ID('tempdb..#hh_nv') IS NULL CREATE TABLE #hh_nv (v nvarchar(max))"
        _ <- execute conn "DELETE FROM #hh_nv"
        _ <- execute conn (mkQuery "INSERT INTO #hh_nv (v) VALUES (@p1)" (Only t))
        pure ()
      (t', dlen) <- evalIO (query1 conn "SELECT v, DATALENGTH(v) FROM #hh_nv" :: IO (Text, Int))
      t' === t
      dlen === expectedBytes

  slow $ describe "hedgehog: large Text round trips (slow)" $ do
    it "round trips unicode Text up to 100k characters" $ \conn -> liveHedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 100000) Gen.unicode
      Only t' <- evalIO $ query1 conn (mkQuery "SELECT @p1" (Only t))
      t' === t

 describe "PLP across different negotiated packet sizes" $ do
  let packetSizes = [512, 4096, 32767] :: [Word32]
  forM_ packetSizes $ \sz ->
    it ("round trips nvarchar(max) across boundaries at packet size " ++ show sz) $
      withPacketSize sz $ \conn -> do
        let so = fromIntegral sz :: Int
            lens = [max 0 (so - 1), so, so + 1, max 0 (2 * so - 1), 2 * so, 2 * so + 1]
        forM_ lens $ \len -> do
          let t = T.replicate len "x"
          Only t' <- query1 conn ("SELECT " <> param t)
          t' `shouldBe` t
