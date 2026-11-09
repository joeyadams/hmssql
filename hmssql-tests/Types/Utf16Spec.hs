-- | Decoding of ill-formed UTF-16 from the server.
--
-- SQL Server treats nchar/nvarchar data as UCS-2 code units and never
-- validates them, so values (and identifiers, and message text) can hold
-- unpaired surrogates.  hmssql decodes every such unit to exactly one
-- U+FFFD, per the Unicode Standard's recommended practice, at every UTF-16
-- decode site: column values of every Unicode type, sql_variant, output
-- parameters, column names, ERROR/INFO messages and ENVCHANGE strings.
module Types.Utf16Spec (spec) where

import Wire.RecipeGet (getToken)
import Control.Exception (try)
import Data.Bits (shiftL, shiftR, (.|.))
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Char (chr)
import Data.IORef
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word16, Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Errors
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives (decodeUtf16LE)
import Hmssql.Tds.Token
import MockServer
import TestDb

-- | Little-endian bytes of a sequence of code units.
units :: [Word16] -> B.ByteString
units = B.pack . concatMap (\u -> [fromIntegral u, fromIntegral (u `shiftR` 8)])

-- | Reference decoder: one scalar per well-formed unit or surrogate pair,
-- one U+FFFD per ill-formed unit.
reference :: [Word16] -> String
reference = \case
  h : l : rest
    | isHigh h && isLow l ->
        chr (0x10000 + ((fromIntegral h - 0xD800) `shiftL` 10) + (fromIntegral l - 0xDC00)) : reference rest
  u : rest
    | isHigh u || isLow u -> '\xFFFD' : reference rest
    | otherwise -> chr (fromIntegral u) : reference rest
  [] -> []
  where
    isHigh u = u >= 0xD800 && u <= 0xDBFF
    isLow u = u >= 0xDC00 && u <= 0xDFFF

-- | The decoder as it was before the single-pass one: validate, then
-- 'T.decodeUtf16LE', or one 'Char' per step for ill-formed input.
oldDecodeUtf16LE :: B.ByteString -> Text
oldDecodeUtf16LE bs
  | wellFormed 0 = T.decodeUtf16LE bs
  | otherwise = T.unfoldrN ((len + 1) `div` 2) step 0
  where
    len = B.length bs
    unit :: Int -> Int
    unit i = fromIntegral (B.index bs i) .|. (fromIntegral (B.index bs (i + 1)) `shiftL` 8)
    isLow u = u >= 0xDC00 && u <= 0xDFFF
    wellFormed i
      | i >= len = True
      | i + 1 >= len = False
      | u < 0xD800 || u > 0xDFFF = wellFormed (i + 2)
      | u <= 0xDBFF && i + 3 < len && isLow (unit (i + 2)) = wellFormed (i + 4)
      | otherwise = False
      where
        u = unit i
    step i
      | i >= len = Nothing
      | i + 1 >= len = Just ('\xFFFD', len)
      | u < 0xD800 || u > 0xDFFF = Just (chr u, i + 2)
      | u <= 0xDBFF && i + 3 < len && isLow lo =
          Just (chr (0x10000 + ((u - 0xD800) `shiftL` 10) + (lo - 0xDC00)), i + 4)
      | otherwise = Just ('\xFFFD', i + 2)
      where
        u = unit i
        lo = unit (i + 2)

-- | Code units biased towards surrogates.
genUnits :: Gen [Word16]
genUnits = Gen.list (Range.linear 0 64) $ Gen.frequency
  [ (3, Gen.word16 (Range.constant 0xD800 0xDBFF))
  , (3, Gen.word16 (Range.constant 0xDC00 0xDFFF))
  , (2, Gen.word16 (Range.constant 0 0x7F))
  , (2, Gen.word16 Range.constantBounded)
  ]

-- | Parse a whole byte string as tokens.
parseTokens :: B.ByteString -> Either String [Token]
parseTokens bs
  | B.null bs = Right []
  | otherwise = case Get.runGetOrFail (getToken defaultTdsContext Nothing) (LB.fromStrict bs) of
      Left (_, _, err) -> Left err
      Right (rest, _, tok) -> (tok :) <$> parseTokens (LB.toStrict rest)

-- | A token with a USHORT length prefix.
lengthPrefixed :: Word8 -> B.ByteString -> B.ByteString
lengthPrefixed ty body = B.pack [ty, fromIntegral len, fromIntegral (len `div` 256)] <> body
  where len = B.length body

-- | B_VARCHAR / US_VARCHAR from raw code units.
bVarChar, usVarChar :: [Word16] -> B.ByteString
bVarChar us = B.singleton (fromIntegral (length us)) <> units us
usVarChar us = B.pack [fromIntegral n, fromIntegral (n `div` 256)] <> units us
  where n = length us

int32le :: Int32 -> B.ByteString
int32le n = B.pack [fromIntegral (n `shiftR` s) | s <- [0, 8, 16, 24]]

-- | ERROR (0xAA) or INFO (0xAB) with the given raw message text.
messageBytes :: Word8 -> [Word16] -> B.ByteString
messageBytes ty msg = lengthPrefixed ty $
  int32le 50000 <> B.pack [1, 16] <> usVarChar msg <> bVarChar [0x73] <> bVarChar [] <> int32le 1

-- | "a", lone high surrogate, "b".
loneHigh :: [Word16]
loneHigh = [0x61, 0xD800, 0x62]

spec :: Spec
spec = do
  describe "decodeUtf16LE" $ do
    let cases :: [(String, [Word8], Text)]
        cases =
          [ ("empty", [], "")
          , ("lone high surrogate", [0x00, 0xD8], "\xFFFD")
          , ("lone low surrogate", [0x00, 0xDC], "\xFFFD")
          , ("lone low surrogate then ASCII", [0x00, 0xDC, 0x41, 0x00], "\xFFFD\&A")
          , ("lone high surrogate then ASCII", [0x00, 0xD8, 0x41, 0x00], "\xFFFD\&A")
          , ("reversed pair", [0x00, 0xDC, 0x00, 0xD8], "\xFFFD\xFFFD")
          , ("reversed pair then ASCII", [0x00, 0xDC, 0x00, 0xD8, 0x41, 0x00], "\xFFFD\xFFFD\&A")
          , ("two highs then a low", [0x00, 0xD8, 0x00, 0xD8, 0x00, 0xDC], "\xFFFD\x10000")
          , ("high surrogate at end", [0x41, 0x00, 0x3D, 0xD8], "A\xFFFD")
          , ("valid pair", [0x3D, 0xD8, 0x00, 0xDE], "\x1F600")
          , ("U+FFFF and U+E000", [0xFF, 0xFF, 0x00, 0xE0], "\xFFFF\xE000")
          , ("odd length: trailing byte", [0x41, 0x00, 0x42], "A\xFFFD")
          , ("odd length: single byte", [0x41], "\xFFFD")
          , ("odd length: high surrogate then trailing byte", [0x00, 0xD8, 0x00], "\xFFFD\xFFFD")
          ]
    mapM_ (\(name, bytes, expected) -> it name $ decodeUtf16LE (B.pack bytes) `shouldBe` expected) cases

    it "round trips valid UTF-16 exactly" $ hedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 100) Gen.unicode
      decodeUtf16LE (T.encodeUtf16LE t) === t

    it "decodes arbitrary code units to one char per scalar or ill-formed unit" $ hedgehog $ do
      us <- forAll genUnits
      T.unpack (decodeUtf16LE (units us)) === reference us

    it "decodes a trailing odd byte to one extra U+FFFD" $ hedgehog $ do
      us <- forAll genUnits
      b <- forAll $ Gen.word8 Range.constantBounded
      decodeUtf16LE (units us <> B.singleton b) === decodeUtf16LE (units us) <> "\xFFFD"

    it "matches the reference on long runs of ASCII and other units, at any offset" $ hedgehog $ do
      -- Runs of ASCII of every length around the decoder's 8-unit steps,
      -- between units of every other kind, sometimes thousands of units
      -- (past the size at which the decoder copies to cut its slack).
      segs <- forAll $ Gen.list (Range.linear 0 40) $ Gen.frequency
        [ (4, Gen.list (Range.linear 0 40) (Gen.word16 (Range.constant 0 0x7F)))
        , (3, genUnits)
        , (1, Gen.list (Range.linear 0 20) (Gen.word16 (Range.constant 0x80 0x7FF)))
        , (1, Gen.list (Range.linear 0 20) (Gen.word16 (Range.constant 0x800 0xD7FF)))
        , (1, Gen.list (Range.linear 0 2000) (Gen.word16 (Range.constant 0x20 0x7E)))
        ]
      odd' <- forAll Gen.bool
      pre <- forAll $ Gen.bytes (Range.linear 0 9)
      post <- forAll $ Gen.bytes (Range.linear 0 9)
      let us = concat segs
          v = units us <> (if odd' then B.singleton 0x41 else B.empty)
          expected = T.pack (reference us ++ ['\xFFFD' | odd'])
      decodeUtf16LE (B.take (B.length v) (B.drop (B.length pre) (pre <> v <> post))) === expected
      decodeUtf16LE v === expected
      oldDecodeUtf16LE v === expected

    it "equals text's decodeUtf16LE on well-formed UTF-16" $ hedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 300) $ Gen.frequency
        [(6, Gen.ascii), (2, Gen.latin1), (2, Gen.unicode), (1, Gen.element ("\26085\26412\128512" :: String))]
      let v = T.encodeUtf16LE t
      decodeUtf16LE v === T.decodeUtf16LE v
      decodeUtf16LE v === t

    it "never fails on arbitrary bytes" $ hedgehog $ do
      bs <- forAll $ Gen.bytes (Range.linear 0 100)
      let t = decodeUtf16LE bs
      T.length t === length (reference (bytesToUnits bs)) + (B.length bs `mod` 2)

  describe "token parsing" $ do
    it "decodes an ERROR message with a lone surrogate" $
      fmap (map msgText . errors) (parseTokens (messageBytes 0xAA loneHigh)) `shouldBe` Right ["a\xFFFD\&b"]

    it "decodes an INFO message with a reversed pair" $
      fmap (map msgText . infos) (parseTokens (messageBytes 0xAB [0xDC00, 0xD800]))
        `shouldBe` Right ["\xFFFD\xFFFD"]

    it "decodes a column name with a lone surrogate" $ do
      -- COLMETADATA: 1 column, UserType, Flags, INT4, ColName.
      let bytes = B.pack [0x81, 1, 0] <> B.replicate 6 0 <> B.singleton 0x38 <> bVarChar loneHigh
      fmap (map (map columnName) . colMeta) (parseTokens bytes) `shouldBe` Right [["a\xFFFD\&b"]]

    it "decodes a database ENVCHANGE with lone surrogates" $ do
      let bytes = lengthPrefixed 0xE3 $ B.singleton 1 <> bVarChar loneHigh <> bVarChar [0xDC00]
      parseTokens bytes `shouldBe` Right [TEnvChange (ECDatabase "\xFFFD" "a\xFFFD\&b")]

    it "decodes a language ENVCHANGE ending in a high surrogate" $ do
      let bytes = lengthPrefixed 0xE3 $ B.singleton 2 <> bVarChar [0x61, 0xDBFF] <> bVarChar []
      parseTokens bytes `shouldBe` Right [TEnvChange (ECLanguage "" "a\xFFFD")]

  describe "mock server" $ do
    let raw = Put.putByteString
        login extra = [loginAckToken Tds74 "Microsoft SQL Server", raw extra, doneToken 0 0]
    it "reports a routing target with a lone surrogate" $ do
      let routingData = B.pack [0, 0xE9, 0x03] <> usVarChar loneHigh
          envc = lengthPrefixed 0xE3 $
            B.singleton 20 <> B.pack [fromIntegral (B.length routingData), 0] <> routingData <> B.pack [0, 0]
      -- Redirected ten times by a server to itself, which then redirects
      -- to the target with the surrogate: one redirect too many, reported
      -- rather than followed.
      logins <- newIORef (0 :: Int)
      let handler port mc = do
            n <- atomicModifyIORef' logins (\n -> (n + 1, n))
            serveLogin (if n < 10 then login (redirect port) else login envc) mc
          redirect port = LB.toStrict (Put.runPut (routingEnvChange "127.0.0.1" (read port)))
      withMockServerAt handler $ \srv -> do
        r <- timeout 10_000_000 $ try $ withConnection (mockConnectInfo srv) (\_ -> pure ())
        r `shouldBe` Just (Left (LoginRedirected "a\xFFFD\&b" 1001))

    it "survives a login-time database ENVCHANGE with a lone surrogate" $ do
      let envc = lengthPrefixed 0xE3 $ B.singleton 1 <> bVarChar loneHigh <> bVarChar [0x78]
      withMockServer (cannedLoginServer (login envc)) $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (mockConnectInfo srv) $ \conn -> execute conn "SELECT 1"
        r `shouldBe` Just 0

    it "reports an error message with a lone surrogate" $ do
      let handler c = do
            _ <- serveLogin defaultLoginResponse c
            serveRequests (\_ _ -> pure [raw (messageBytes 0xAA loneHigh), doneToken 0x0002 0]) c
      withMockServer handler $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (mockConnectInfo srv) $ \conn -> try (execute conn "SELECT 1")
        case r of
          Just (Left e) -> sqlErrorMessage e `shouldBe` "a\xFFFD\&b"
          other -> expectationFailure ("expected a SqlServerError, got " ++ show (fmap (either (const "Left") show) other))

  around withTestDb $ describe "live" $ do
    describe "column values" $ do
      let exprs :: [(String, Text, Text)]
          exprs =
            [ ("a lone high surrogate", "NCHAR(0xD800)", "\xFFFD")
            , ("a lone low surrogate", "NCHAR(0xDC00)", "\xFFFD")
            , ("a reversed pair", "NCHAR(0xDC00) + NCHAR(0xD800)", "\xFFFD\xFFFD")
            , ("a high surrogate at the end", "N'ab' + NCHAR(0xD83D)", "ab\xFFFD")
            , ("a lone surrogate between characters", "N'a' + NCHAR(0xDFFF) + N'b'", "a\xFFFD\&b")
            , ("a valid pair built from halves", "NCHAR(0xD83D) + NCHAR(0xDE00)", "\x1F600")
            ]
          types :: [Text]
          types = ["nchar(4)", "nvarchar(10)", "nvarchar(max)", "ntext"]
      mapM_
        ( \ty -> describe (T.unpack ty) $ mapM_
            ( \(name, e, expected) -> it name $ \conn -> do
                let padded
                      | ty == "nchar(4)" = expected <> T.replicate (4 - B.length (T.encodeUtf16LE expected) `div` 2) " "
                      | otherwise = expected
                Only t <- query1 conn (rawSql ("SELECT CAST(" <> e <> " AS " <> ty <> ")"))
                t `shouldBe` padded
            )
            exprs
        )
        types

      it "decodes a bare NCHAR(0xD800) (nchar(1))" $ \conn ->
        query1 conn "SELECT NCHAR(0xD800)" `shouldReturn` Only ("\xFFFD" :: Text)

      it "decodes lone surrogates in sql_variant" $ \conn -> do
        [row] <- queryMWith sqlRowDecoder conn "SELECT CAST(NCHAR(0xD800) AS sql_variant), CAST(CAST(N'x' + NCHAR(0xDC00) AS nchar(3)) AS sql_variant)"
        sqlRowValues row `shouldBe` [SqlText "\xFFFD", SqlText "x\xFFFD "]

      it "decodes a long nvarchar(max) with pairs and lone surrogates across PLP chunks" $ \conn -> do
        Only t <- query1 conn
          "SELECT N'a' + REPLICATE(CAST(NCHAR(0xD83D) + NCHAR(0xDE00) + NCHAR(0xD800) AS nvarchar(max)), 20000)"
        t `shouldBe` "a" <> T.replicate 20000 "\x1F600\xFFFD"

      it "decodes an output parameter with a lone surrogate" $ \conn -> do
        _ <- execute conn "CREATE OR ALTER PROCEDURE #hmssql_utf16 @b nvarchar(50) OUTPUT AS SET @b = N'a' + NCHAR(0xD800) + N'b'"
        let pb = outParam "@b" ("" :: Text)
        res <- callProcedure conn "#hmssql_utf16" [pb]
        map decodeReturnValue (procOutputValues res) `shouldBe` [Right ("a\xFFFD\&b" :: Text)]

    it "decodes a column name with a lone surrogate" $ \conn -> do
      [rs] <- queryMulti conn
        "DECLARE @s nvarchar(200) = N'SELECT 1 AS ' + QUOTENAME(N'a' + NCHAR(0xD800) + N'b'); EXEC (@s)"
      map columnName (resultColumns rs) `shouldBe` ["a\xFFFD\&b"]
      map sqlRowValues (resultRows rs) `shouldBe` [[SqlInt32 1]]

    it "decodes an error message with a lone surrogate" $ \conn -> do
      r <- try $ execute conn "DECLARE @m nvarchar(100) = N'x' + NCHAR(0xD800) + N'y'; THROW 50000, @m, 1"
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "x\xFFFDy"
        Right n -> expectationFailure ("no error: " ++ show n)

    it "keeps the connection usable after such an error" $ \conn -> do
      _ <- try @SqlServerError $ execute conn "DECLARE @m nvarchar(100) = NCHAR(0xDC00); RAISERROR(@m, 16, 1)"
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  it "live: decodes an info message with a lone surrogate" $ do
    ref <- newIORef []
    ci <- defaultTestConnectInfo
    withConnection ci { connectOnInfoMessage = \m -> modifyIORef ref (msgText m :) } $ \conn -> do
      writeIORef ref []
      _ <- execute conn "DECLARE @m nvarchar(100) = N'p' + NCHAR(0xDBFF); PRINT @m"
      pure ()
    readIORef ref `shouldReturn` ["p\xFFFD"]
  where
    errors toks = [m | TError m <- toks]
    infos toks = [m | TInfo m <- toks]
    colMeta toks = [cs | TColMetaData cs <- toks]

bytesToUnits :: B.ByteString -> [Word16]
bytesToUnits bs = [fromIntegral (B.index bs i) .|. (fromIntegral (B.index bs (i + 1)) `shiftL` 8) | i <- [0, 2 .. B.length bs - 2]]
