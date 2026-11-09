{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
-- | Parameter ENCODING matrix.
--
-- Two things this module checks:
--
-- 1. Implicit conversion: a 'ToSqlField' value declares one wire type
--    (documented in "Hmssql.Encoding"); sending it against a compatible but
--    different column type relies on the server's own implicit conversion.
--    Each case here compares hmssql's parameter against the server
--    converting the equivalent string literal, so a change in hmssql's wire
--    type (or a server version change) that breaks the conversion shows up
--    here rather than downstream.
-- 2. Parameter list shapes: tuples of every arity 1-10, a 'Generic' record,
--    and a hedgehog property that round-trips every 'SqlValue' constructor
--    exactly via @SELECT \@p1@ (XML generated in the server's canonical
--    serialization; non-canonical XML is compared against the server's own
--    @CAST(... AS xml)@).
--
-- @[SqlParam]@ and 'NamedParams' (both @\@name@ and bare names, duplicate
-- names, case sensitivity) are already covered by "QuerySpec".
module Types.ParamMatrixSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Fixed (Fixed (..))
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Data.Word (Word8)
import GHC.Float (castWord32ToFloat, castWord64ToDouble)
import GHC.Generics (Generic)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestDb

------------------------------------------------------------------------------
-- Implicit conversions: hmssql's parameter vs. the server's own literal cast

-- | Compare @CAST(\@p1 AS <ty>)@ against @CAST('<literal>' AS <ty>)@, i.e. the
-- server's own conversion of an equivalent string.
convertsLike
  :: forall a b. (ToSqlField a, Eq b, Show b, FromSqlField b)
  => Connection -> Text -> a -> Text -> IO ()
convertsLike conn ty val literal = do
  (fromParam, fromLiteral) <- query1 conn $ mkQuery
    ("SELECT CAST(@p1 AS " <> ty <> "), CAST('" <> literal <> "' AS " <> ty <> ")")
    (Only val)
  (fromParam :: b) `shouldBe` fromLiteral

-- | Like 'convertsLike', but the literal is spliced into the SQL unquoted
-- (for hex/numeric literals such as @0x01020000@, where quoting would make
-- the server read it as text instead of a hex constant).
convertsLikeRaw
  :: forall a b. (ToSqlField a, Eq b, Show b, FromSqlField b)
  => Connection -> Text -> a -> Text -> IO ()
convertsLikeRaw conn ty val literal = do
  (fromParam, fromLiteral) <- query1 conn $ mkQuery
    ("SELECT CAST(@p1 AS " <> ty <> "), CAST(" <> literal <> " AS " <> ty <> ")")
    (Only val)
  (fromParam :: b) `shouldBe` fromLiteral

-- | Both conversions fail with the same SQL Server error number.
overflowsLike :: ToSqlField a => Connection -> Text -> a -> Text -> IO ()
overflowsLike conn ty val literal = do
  r1 <- try (query1 conn (mkQuery ("SELECT CAST(@p1 AS " <> ty <> ")") (Only val))) :: IO (Either SqlServerError (Only Decimal))
  r2 <- try (query1 conn (rawSql ("SELECT CAST('" <> literal <> "' AS " <> ty <> ")"))) :: IO (Either SqlServerError (Only Decimal))
  case (r1, r2) of
    (Left e1, Left e2) -> sqlErrorNumber e1 `shouldBe` sqlErrorNumber e2
    _ -> expectationFailure ("expected both to fail: " ++ show (fmap (const ()) r1, fmap (const ()) r2))

spec :: Spec
spec = around withTestDb $ do
  describe "implicit conversions (parameter cast to a different but compatible column type)" $ do
    it "Text (nvarchar) into varchar, char, nchar, uniqueidentifier, xml and date" $ \conn -> do
      convertsLike @Text @Text conn "varchar(20)" "hello" "hello"
      convertsLike @Text @Text conn "char(10)" "abc" "abc       "
      convertsLike @Text @Text conn "nchar(10)" "abc" "abc       "
      convertsLike @Text @UUID conn "uniqueidentifier"
        "6F9619FF-8B86-D011-B42D-00C04FC964FF" "6F9619FF-8B86-D011-B42D-00C04FC964FF"
      convertsLike @Text @Text conn "xml" "<a>b</a>" "<a>b</a>"
      convertsLike @Text @Day conn "date" "2020-05-06" "2020-05-06"
      convertsLike @Text @LocalTime conn "datetime" "2020-05-06T01:02:03" "2020-05-06T01:02:03"

    it "Double (float) into decimal, real and int" $ \conn -> do
      convertsLike @Double @Decimal conn "decimal(20,10)" 3.5 "3.5"
      convertsLike @Double @Float conn "real" 1.25 "1.25"
      convertsLike @Double @Int conn "int" 42.0 "42"

    it "LocalTime (datetime2(7)) into datetime, smalldatetime and date" $ \conn -> do
      let lt = LocalTime (fromGregorian 2020 5 6) (TimeOfDay 1 2 3)
      convertsLike @LocalTime @LocalTime conn "datetime" lt "2020-05-06T01:02:03"
      convertsLike @LocalTime @LocalTime conn "smalldatetime" lt "2020-05-06T01:02:00"
      convertsLike @LocalTime @Day conn "date" lt "2020-05-06"

    it "UUID (uniqueidentifier) into char(36)" $ \conn -> do
      let u = UUID.fromWords 0x6F9619FF 0x8B86D011 0xB42D00C0 0x4FC964FF
      convertsLike @UUID @Text conn "char(36)" u "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    it "Int (bigint) into decimal, money, and float" $ \conn -> do
      convertsLike @Int @Decimal conn "decimal(20,0)" 12345 "12345"
      convertsLike @Int @Money conn "money" 100 "100.00"
      convertsLike @Int @Double conn "float" 7 "7"

    it "Bool (bit) into int and tinyint" $ \conn -> do
      convertsLike @Bool @Int conn "int" True "1"
      convertsLike @Bool @Word8 conn "tinyint" False "0"

    it "ByteString (varbinary) into binary(n), fixed-width, zero-padded" $ \conn -> do
      convertsLikeRaw @B.ByteString @B.ByteString conn "binary(4)" (B.pack [1, 2]) "0x01020000"

    it "Money into decimal and float" $ \conn -> do
      let m = Money (MkFixed 12345) -- 1.2345
      convertsLike @Money @Decimal conn "decimal(10,4)" m "1.2345"
      convertsLike @Money @Double conn "float" m "1.2345"

    it "Decimal into money, float and a wider/narrower decimal" $ \conn -> do
      convertsLike @Decimal @Money conn "money" 1.5 "1.5"
      convertsLike @Decimal @Double conn "float" 1.5 "1.5"
      convertsLike @Decimal @Decimal conn "decimal(4,1)" 1.5 "1.5"

    it "a narrower-than-needed target fails loudly, exactly like the server's own CAST of the literal" $ \conn ->
      overflowsLike @Int conn "decimal(3,0)" 12345 "12345"

  describe "tuples of every arity 1-10 as a parameter list" $ do
    it "arity 1 (Only)" $ \conn ->
      query1 conn ("SELECT " <> param (1 :: Int)) `shouldReturn` Only (1 :: Int)
    it "arity 2" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2" (1 :: Int, 2 :: Int)) `shouldReturn` (1 :: Int, 2 :: Int)
    it "arity 3" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3" (1 :: Int, 2 :: Int, 3 :: Int)) `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int)
    it "arity 4" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4" (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int)
    it "arity 5" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5" (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int)
    it "arity 6" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6" (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int)
    it "arity 7" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6, @p7" (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int)
    it "arity 8" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8"
          (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int, 8 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int, 8 :: Int)
    it "arity 9" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9"
          (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int, 8 :: Int, 9 :: Int))
        `shouldReturn` (1 :: Int, 2 :: Int, 3 :: Int, 4 :: Int, 5 :: Int, 6 :: Int, 7 :: Int, 8 :: Int, 9 :: Int)
    it "arity 10, heterogeneous types" $ \conn -> do
      r <- query1 conn (mkQuery "SELECT @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9, @p10"
             ( 1 :: Int, "two" :: Text, 3.0 :: Double, True, 5 :: Int16
             , 6 :: Int32, 7 :: Int64, 8 :: Word8, -9 :: Int8, UUID.nil ))
      r `shouldBe`
        ( 1 :: Int, "two" :: Text, 3.0 :: Double, True, 5 :: Int16
        , 6 :: Int32, 7 :: Int64, 8 :: Word8, -9 :: Int8, UUID.nil )

  describe "Generic records as a parameter list" $ do
    it "sends fields positionally, in declaration order" $ \conn -> do
      let point = Point { px = 3 :: Int, py = "north" :: Text }
      r <- query1 conn (mkQuery "SELECT @p1, @p2" point)
      r `shouldBe` (3 :: Int, "north" :: Text)

  describe "hedgehog: every SqlValue constructor round-trips exactly as a parameter" $ do
    -- Enough tests that each covered constructor (at least 5% of the
    -- values) shows up: with 100, a constructor at 4% was missing from
    -- about one run in fifty, failing the coverage check.
    withCases 400 $ it "SELECT @p1 returns the same SqlValue" $ \conn -> liveHedgehog $ do
      sv <- forAll genSqlValue
      cover 1 "SqlNull" (isNullV sv)
      cover 1 "SqlText" (isTextV sv)
      cover 1 "SqlDateTimeOffset" (isDtoV sv)
      cover 1 "SqlXml" (isXmlV sv)
      Only sv' <- evalIO $ query1 conn ("SELECT " <> param sv)
      sv' === sv

  describe "SqlXml parameters" $ do
    it "SqlXml is sent as xml, so it comes back as SqlXml (not SqlText)" $ \conn -> do
      Only sv' <- query1 conn ("SELECT " <> param (SqlXml "<a/>"))
      sv' `shouldBe` SqlXml "<a/>"

    it "SqlXml supports the xml data type methods (it is an xml value on the server)" $ \conn ->
      query1 conn ("SELECT " <> param (SqlXml "<a x=\"42\"/>") <> ".value('(/a/@x)[1]', 'int')")
        `shouldReturn` Only (42 :: Int)

    it "an empty SqlXml is an empty xml value, not NULL" $ \conn ->
      query1 conn (mkQuery "SELECT @p1, CASE WHEN @p1 IS NULL THEN 1 ELSE 0 END" (Only (SqlXml "")))
        `shouldReturn` (SqlXml "", 0 :: Int)

    it "a text-only SqlXml (not starting with '<') is read as UTF-16, not as a single-byte encoding" $ \conn -> do
      query1 conn ("SELECT " <> param (SqlXml "a")) `shouldReturn` Only (SqlXml "a")
      query1 conn (mkQuery "SELECT @p1" (Only (SqlXml "h\233llo <b/>"))) `shouldReturn` Only (SqlXml "h\233llo <b/>")

    it "an XML declaration naming a single-byte encoding fails exactly as CAST of the nvarchar does" $ \conn -> do
      let x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>" :: Text
      r1 <- try (query1 conn (mkQuery "SELECT @p1" (Only (SqlXml x)))) :: IO (Either SqlServerError (Only SqlValue))
      r2 <- try (query1 conn ("SELECT CAST(" <> param x <> " AS xml)")) :: IO (Either SqlServerError (Only SqlValue))
      either (Just . sqlErrorNumber) (const Nothing) r1 `shouldBe` Just 9402
      either (Just . sqlErrorNumber) (const Nothing) r2 `shouldBe` Just 9402

    it "a large SqlXml spanning several PLP chunks round-trips" $ \conn -> do
      let x = "<a>" <> T.replicate 20000 "\233" <> "</a>"
      query1 conn ("SELECT " <> param (SqlXml x)) `shouldReturn` Only (SqlXml x)

    it "malformed SqlXml is rejected by the server with an XML parsing error" $ \conn -> do
      r <- try (query1 conn (mkQuery "SELECT @p1" (Only (SqlXml "<a>")))) :: IO (Either SqlServerError (Only SqlValue))
      either (Just . sqlErrorNumber) (const Nothing) r `shouldBe` Just 9400

    it "hedgehog: non-canonical XML comes back as the server's own CAST normalizes it" $ \conn -> liveHedgehog $ do
      nodes <- forAll genXmlNodes
      messy <- forAll (renderMessy nodes)
      (sv, viaCast) <- evalIO $ query1 conn (mkQuery "SELECT @p1, CAST(@p2 AS xml)" (SqlXml messy, messy))
      sv === viaCast
      sv === SqlXml (renderCanonical nodes)

data Point = Point { px :: !Int, py :: !Text }
  deriving (Eq, Show, Generic)

instance ToSqlRow Point

isNullV, isTextV, isDtoV, isXmlV :: SqlValue -> Bool
isNullV SqlNull = True
isNullV _ = False
isTextV (SqlText _) = True
isTextV _ = False
isDtoV (SqlDateTimeOffset _) = True
isDtoV _ = False
isXmlV (SqlXml _) = True
isXmlV _ = False

------------------------------------------------------------------------------
-- Generators

day1 :: Integer -> Int -> Int -> Day
day1 = fromGregorian

-- | A day safely away from the 0001/9999 edges, so a +/-14:00 offset never
-- pushes the local time out of range (edge cases are covered by
-- Types.TimeBoundarySpec).
genSafeDay :: Gen Day
genSafeDay = ModifiedJulianDay <$> Gen.integral
  (Range.constant (toModifiedJulianDay (day1 2 1 2)) (toModifiedJulianDay (day1 9998 12 30)))

-- | An exact multiple of 100ns within a day: encodes/decodes at scale 7
-- without any rounding, so round trips are exact.
genExactTimeOfDay :: Gen TimeOfDay
genExactTimeOfDay = do
  u <- Gen.integral (Range.constant 0 (86400 * 10000000 - 1))
  pure (timeToTimeOfDay (picosecondsToDiffTime (u * 100000)))

genExactLocalTime :: Gen LocalTime
genExactLocalTime = LocalTime <$> genSafeDay <*> genExactTimeOfDay

genOffset :: Gen Int16
genOffset = Gen.integral (Range.constant (-840) 840)

genDto :: Gen DateTimeOffset
genDto = do
  off <- genOffset
  local <- genExactLocalTime
  pure $ DateTimeOffset (localTimeToUTC (minutesToTimeZone (fromIntegral off)) local) off

genDecimalValid :: Gen Decimal
genDecimalValid = do
  s <- Gen.int (Range.linear 0 38)
  m <- Gen.integral (Range.linearFrom 0 (1 - 10 ^ (38 :: Int)) (10 ^ (38 :: Int) - 1))
  pure (Decimal (fromIntegral s) m)

genMoney :: Gen Money
genMoney = Money . MkFixed <$> Gen.integral (Range.linearFrom 0 (-9223372036854775808) 9223372036854775807 :: Range.Range Integer)

genText :: Gen Text
genText = Gen.text (Range.linear 0 30) Gen.unicode

genBytes :: Gen B.ByteString
genBytes = Gen.bytes (Range.linear 0 30)

genFiniteFloat :: Gen Float
genFiniteFloat = castWord32ToFloat <$> Gen.filter ok (Gen.word32 Range.linearBounded)
  where
    ok w = let f = castWord32ToFloat w in not (isNaN f) && not (isInfinite f)

genFiniteDouble :: Gen Double
genFiniteDouble = castWord64ToDouble <$> Gen.filter ok (Gen.word64 Range.linearBounded)
  where
    ok w = let d = castWord64ToDouble w in not (isNaN d) && not (isInfinite d)

genSqlValue :: Gen SqlValue
genSqlValue = Gen.frequency
  [ (3, pure SqlNull)
  , (3, SqlBool <$> Gen.bool)
  , (3, SqlWord8 <$> Gen.word8 Range.linearBounded)
  , (3, SqlInt16 <$> Gen.int16 Range.linearBounded)
  , (3, SqlInt32 <$> Gen.int32 Range.linearBounded)
  , (3, SqlInt64 <$> Gen.int64 Range.linearBounded)
  , (3, SqlFloat <$> genFiniteFloat)
  , (3, SqlDouble <$> genFiniteDouble)
  , (3, SqlDecimal <$> genDecimalValid)
  , (3, SqlMoney <$> genMoney)
  , (3, SqlGuid <$> genUUID)
  , (3, SqlDateTime <$> genExactLocalTime)
  , (3, SqlDate <$> genSafeDay)
  , (3, SqlTime <$> genExactTimeOfDay)
  , (3, SqlDateTimeOffset <$> genDto)
  , (3, SqlText <$> genText)
  , (3, SqlBinary <$> genBytes)
  , (3, SqlXml . renderCanonical <$> genXmlNodes)
  ]
  where
    genUUID = UUID.fromWords <$> w32 <*> w32 <*> w32 <*> w32
    w32 = Gen.word32 Range.linearBounded

------------------------------------------------------------------------------
-- XML generators

-- | An XML fragment (SQL Server's @xml@ accepts any number of top-level
-- elements and text nodes, including none).  No two text nodes are adjacent
-- and none is whitespace-only, since the server merges or drops those.
data XmlNode = XElem Text [(Text, Text)] [XmlNode] | XText Text
  deriving (Show)

genXmlNodes :: Gen [XmlNode]
genXmlNodes = genXmlContent (3 :: Int)

genXmlContent :: Int -> Gen [XmlNode]
genXmlContent depth = do
  n <- Gen.int (Range.linear 0 (if depth <= 0 then 1 else 4))
  noAdjacentText <$> Gen.list (Range.singleton n) (genXmlNode depth)
  where
    noAdjacentText (XText a : XText b : rest) = noAdjacentText (XText (a <> b) : rest)
    noAdjacentText (x : rest) = x : noAdjacentText rest
    noAdjacentText [] = []

genXmlNode :: Int -> Gen XmlNode
genXmlNode depth = Gen.frequency
  [ (2, XText <$> genXmlText)
  , ( if depth <= 0 then 0 else 3
    , XElem <$> Gen.element ["a", "b", "item", "x1", "\233l\233ment"]
        <*> (Gen.subsequence ["p", "q", "r"] >>= traverse (\k -> (\v -> (k, v)) <$> genXmlAttrValue))
        <*> genXmlContent (depth - 1) )
  , (if depth <= 0 then 3 else 0, XText <$> genXmlText)
  ]

-- | Text that is not whitespace-only (the server drops such text nodes).
genXmlText :: Gen Text
genXmlText = do
  t <- Gen.text (Range.linear 1 12) genXmlChar
  pure (if T.all (== ' ') t then t <> "z" else t)

-- | Attribute values: no tab/newline/CR (the server normalizes those).
genXmlAttrValue :: Gen Text
genXmlAttrValue = Gen.text (Range.linear 0 8) genXmlChar

genXmlChar :: Gen Char
genXmlChar = Gen.frequency
  [ (6, Gen.alphaNum)
  , (2, Gen.element (" &<>\"'" :: String))
  , (1, Gen.element ['\233', '\20013', '\x1F600'])
  ]

-- | SQL Server's own serialization: empty elements as @<a/>@, attributes in
-- double quotes, @&amp; &lt; &gt;@ escaped in text and additionally @&quot;@
-- in attributes.
renderCanonical :: [XmlNode] -> Text
renderCanonical = T.concat . map node
  where
    node (XText t) = escText t
    node (XElem n as cs) =
      "<" <> n <> T.concat [" " <> k <> "=\"" <> escAttr v <> "\"" | (k, v) <- as]
        <> if null cs then "/>" else ">" <> renderCanonical cs <> "</" <> n <> ">"
    escText = T.concatMap $ \case
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      c -> T.singleton c
    escAttr = T.concatMap $ \case
      '"' -> "&quot;"
      c -> escText (T.singleton c)

-- | The same document written in some of the many other ways XML allows:
-- an XML declaration, @<a></a>@, single-quoted attributes, whitespace around
-- @=@ and before @>@, character and entity references, CDATA sections, and
-- whitespace-only text between elements (which the server drops).
renderMessy :: [XmlNode] -> Gen Text
renderMessy nodes = do
  decl <- Gen.element ["", "", "<?xml version=\"1.0\"?>", "<?xml version=\"1.0\" encoding=\"UTF-16\"?>"]
  body <- content True nodes
  pure (decl <> body)
  where
    content _ [] = pure ""
    content prevElem (x : rest) = do
      let isElem = \case XElem{} -> True; XText{} -> False
          nextElem = maybe True isElem (safeHead rest)
      ws <- if prevElem && isElem x then Gen.element ["", "", " ", "\n  ", "\t"] else pure ""
      nx <- node x
      trailing <- if null rest && isElem x && nextElem then Gen.element ["", " \n"] else pure ""
      more <- content (isElem x) rest
      pure (ws <> nx <> trailing <> more)
    safeHead (y : _) = Just y
    safeHead [] = Nothing
    node (XText t) = Gen.frequency
      [ (3, T.concat <$> traverse textChar (T.unpack t))
      , (1, if "]]>" `T.isInfixOf` t then T.concat <$> traverse textChar (T.unpack t)
            else pure ("<![CDATA[" <> t <> "]]>"))
      ]
    node (XElem n as cs) = do
      attrs <- T.concat <$> traverse attr as
      sp <- Gen.element ["", " ", "\n"]
      inner <- content True cs
      closeStyle <- Gen.bool
      pure $ if null cs && closeStyle
        then "<" <> n <> attrs <> sp <> "/>"
        else "<" <> n <> attrs <> sp <> ">" <> inner <> "</" <> n <> sp <> ">"
    attr (k, v) = do
      q <- Gen.element ['"', '\'']
      eq <- Gen.element ["=", " = ", "=\n"]
      vs <- T.concat <$> traverse (attrChar q) (T.unpack v)
      pure (" " <> k <> eq <> T.singleton q <> vs <> T.singleton q)
    textChar = \case
      '&' -> Gen.element ["&amp;", "&#38;", "&#x26;"]
      '<' -> Gen.element ["&lt;", "&#60;"]
      '>' -> Gen.element [">", "&gt;", "&#x3E;"]
      '"' -> Gen.element ["\"", "&quot;"]
      '\'' -> Gen.element ["'", "&apos;"]
      c -> Gen.frequency [(5, pure (T.singleton c)), (1, pure (charRef c))]
    attrChar q = \case
      '&' -> pure "&amp;"
      '<' -> pure "&lt;"
      c | c == q -> Gen.element [charRef c, if c == '"' then "&quot;" else "&apos;"]
      c -> Gen.frequency [(5, pure (T.singleton c)), (1, pure (charRef c))]
    charRef c = "&#" <> T.pack (show (fromEnum c)) <> ";"
