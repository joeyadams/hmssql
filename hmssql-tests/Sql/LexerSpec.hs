-- | 'Hmssql.Query.mkQuery' finds the positional parameter references (@\@p1@,
-- @\@p2@, ...) in its text so that they renumber when queries are
-- concatenated.  These are the lexical rules it follows: what counts as a
-- placeholder, what is left alone (string literals, quoted identifiers,
-- comments, other variables), and that nothing makes the scanner fail.  No
-- server needed.
module Sql.LexerSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql.Query.Lexer

-- | The text back, with placeholders in their canonical spelling.
rendered :: [Fragment] -> Text
rendered = T.concat . map (\case Static t -> t; Placeholder n -> "@p" <> T.pack (show n))

placeholders :: [Fragment] -> [Int]
placeholders frags = [n | Placeholder n <- frags]

spec :: Spec
spec = do
  describe "the scanner" $ do
    it "agrees with the first, appending implementation on SQL-ish text" $ hedgehog $ do
      t <- forAll $ T.concat <$> Gen.list (Range.linear 0 60) (Gen.element
        ["'", "''", "\"", "[", "]", "]]", "-", "--", "/", "/*", "*/", "*", "@", "@@", "@p", "@P", "@p1", "@p12",
         "0", "7", "x", "_", "é", "\n", " ", "N'", "#", "$", "\x1F600"])
      lexPlaceholders t === referenceLex t

  describe "placeholders" $ do
    it "finds @pN, numbered as written" $
      lexPlaceholders "SELECT @p1, @p2 WHERE x = @p10 AND y = @p2"
        `shouldBe` [Static "SELECT ", Placeholder 1, Static ", ", Placeholder 2, Static " WHERE x = ", Placeholder 10, Static " AND y = ", Placeholder 2]

    it "is case-insensitive, like T-SQL names (@P1 is placeholder 1)" $
      lexPlaceholders "SELECT @P1, @p1" `shouldBe` [Static "SELECT ", Placeholder 1, Static ", ", Placeholder 1]

    it "reads leading zeros as part of the number (@p01 is placeholder 1)" $
      placeholders (lexPlaceholders "SELECT @p01, @p0") `shouldBe` [1, 0]

    it "finds a placeholder at the start, at the end and alone" $ do
      lexPlaceholders "@p1 + 1" `shouldBe` [Placeholder 1, Static " + 1"]
      lexPlaceholders "SELECT @p1" `shouldBe` [Static "SELECT ", Placeholder 1]
      lexPlaceholders "@p7" `shouldBe` [Placeholder 7]
      lexPlaceholders "" `shouldBe` []

    it "leaves other variables alone: a name that goes on after the digits" $
      forM_ ["@p1x", "@p1_old", "@p1\233", "@p1\x0661", "@p1@", "@p1#", "@p1$", "@p12a"] $ \name ->
        (name, lexPlaceholders ("SELECT " <> name)) `shouldBe` (name, [Static ("SELECT " <> name)])

    it "leaves other variables alone: @p without digits, @@ROWCOUNT, @@p1" $
      forM_ ["@p", "@px", "@@ROWCOUNT", "@@p1", "@P", "@q1", "@1"] $ \name ->
        (name, lexPlaceholders ("SELECT " <> name)) `shouldBe` (name, [Static ("SELECT " <> name)])

    it "needs the @ to start a name (x@p1 is one identifier)" $
      forM_ ["x@p1", "1@p1", "_@p1", "#@p1", "\233@p1"] $ \t ->
        (t, lexPlaceholders t) `shouldBe` (t, [Static t])

    it "accepts a placeholder right after punctuation or an operator" $
      lexPlaceholders "(@p1,@p2)=@p3" `shouldBe` [Static "(", Placeholder 1, Static ",", Placeholder 2, Static ")=", Placeholder 3]

    it "treats more than nine digits as text" $
      lexPlaceholders "SELECT @p1234567890" `shouldBe` [Static "SELECT @p1234567890"]

  describe "what is skipped" $ do
    it "string literals, with '' for a quote, and N'' strings" $ do
      lexPlaceholders "SELECT '@p1', N'@p2', 'it''s @p3', @p4"
        `shouldBe` [Static "SELECT '@p1', N'@p2', 'it''s @p3', ", Placeholder 4]
      lexPlaceholders "SELECT '' + @p1" `shouldBe` [Static "SELECT '' + ", Placeholder 1]

    it "quoted identifiers, with \"\" for a quote" $
      lexPlaceholders "SELECT \"@p1\", \"a\"\"@p2\", @p3"
        `shouldBe` [Static "SELECT \"@p1\", \"a\"\"@p2\", ", Placeholder 3]

    it "bracketed identifiers, with ]] for a bracket" $
      lexPlaceholders "SELECT [@p1], [a]]@p2], @p3 FROM [t]"
        `shouldBe` [Static "SELECT [@p1], [a]]@p2], ", Placeholder 3, Static " FROM [t]"]

    it "line comments, to the end of the line" $
      lexPlaceholders "SELECT 1 -- @p1\n, @p2 --@p3"
        `shouldBe` [Static "SELECT 1 -- @p1\n, ", Placeholder 2, Static " --@p3"]

    it "block comments, nested as T-SQL nests them" $ do
      lexPlaceholders "SELECT /* @p1 */ @p2" `shouldBe` [Static "SELECT /* @p1 */ ", Placeholder 2]
      lexPlaceholders "SELECT /* a /* @p1 */ @p1 */ @p2" `shouldBe` [Static "SELECT /* a /* @p1 */ @p1 */ ", Placeholder 2]
      lexPlaceholders "/**/@p1" `shouldBe` [Static "/**/", Placeholder 1]

    it "a lone quote, bracket or comment opener runs to the end of the text" $
      forM_ ["SELECT @x'", "SELECT @x[", "SELECT @x/*", "SELECT @x\"", "SELECT @x /* @p1", "SELECT 'abc"] $ \t ->
        (t, lexPlaceholders (t <> " @p1")) `shouldBe` (t, [Static (t <> " @p1")])

    it "a single - or / is an operator" $
      lexPlaceholders "SELECT 1-@p1, 2/@p2, -@p3" `shouldBe` [Static "SELECT 1-", Placeholder 1, Static ", 2/", Placeholder 2, Static ", -", Placeholder 3]

    it "temp tables, ODBC escapes and money literals are text" $
      forM_ ["SELECT * FROM #t", "SELECT * FROM ##g", "SELECT {fn NOW()}", "SELECT $1.50", "SELECT {ts '2024-01-01 00:00:00'}"] $ \t ->
        (t, lexPlaceholders t) `shouldBe` (t, [Static t])

  describe "the result" $ do
    it "merges adjacent static text" $
      lexPlaceholders "a'b'[c]--d\n/*e*/f" `shouldBe` [Static "a'b'[c]--d\n/*e*/f"]

    it "concatenates back to the text for any input (the scanner never fails)" $ hedgehog $ do
      t <- forAll $ Gen.text (Range.linear 0 40) $ Gen.frequency
        [ (6, Gen.element (T.unpack "@p12xN_ ,()=\233"))
        , (3, Gen.element (T.unpack "'\"[]-/*\n"))
        , (1, Gen.unicode)
        ]
      -- Placeholders may be respelled (@P01 -> @p1), so compare up to that.
      let canonical = T.toLower . T.replace "@p0" "@p"
      canonical (rendered (lexPlaceholders t)) === canonical t
      -- A rendered placeholder is one the scanner finds again.
      map canonical (T.words (rendered (lexPlaceholders t))) === map canonical (T.words (rendered (lexPlaceholders (rendered (lexPlaceholders t)))))

  describe "isVariableChar" $
    it "accepts letters, marks, digits, letter numbers and @#$_ from the BMP" $ do
      forM_ ("aZ09_@#$\233\x0301\x0661\x2163\x53D8" :: String) $ \c -> (c, isVariableChar c) `shouldBe` (c, True)
      forM_ (" ,;()'\"[]-/*=.\x00A0\x200D\x00B2\x1D400" :: String) $ \c -> (c, isVariableChar c) `shouldBe` (c, False)

-- | The scanner as it was first written, which built static text by
-- appending (quadratic in the special characters between placeholders);
-- the current one must find the same fragments.
referenceLex :: Text -> [Fragment]
referenceLex = merge . go Nothing
  where
    -- @prev@ is the character before @t@, if any.
    go :: Maybe Char -> Text -> [Fragment]
    go prev t
      | T.null t = []
      | otherwise =
          let (plain, rest) = T.span (`notElem` ("'\"[-/@" :: String)) t
              prev' = if T.null plain then prev else Just (T.last plain)
           in static plain ++ special prev' rest

    special prev t = case T.uncons t of
      Nothing -> []
      Just (c, rest) -> case c of
        '\'' -> skipQuoted '\'' t
        '"' -> skipQuoted '"' t
        '[' -> skipQuoted ']' t
        '-' | "--" `T.isPrefixOf` t -> let (comment, rest') = T.break (== '\n') t in static comment ++ go (Just '-') rest'
        '/' | "/*" `T.isPrefixOf` t -> let (comment, rest') = blockComment t in static comment ++ go (Just '/') rest'
        '@' | placeholderMayStart prev
            , Just (p, afterP) <- T.uncons rest
            , p == 'p' || p == 'P'
            , (digits, after) <- T.span isAsciiDigitRef afterP
            , not (T.null digits), T.length digits <= 9
            , maybe True (not . isVariableChar) (fst <$> T.uncons after)
            -> Placeholder (read (T.unpack digits)) : go (Just (T.last digits)) after
        _ -> Static (T.singleton c) : go (Just c) rest

    -- A quoted region: the opening character, then up to the closing one,
    -- where a doubled closing character stays inside.  (For @[...]@ the
    -- closing character differs from the opening one; a doubled @]@ is an
    -- escaped bracket, as for quotes.)
    skipQuoted close t =
      let (region, rest) = quotedRegion close (T.drop 1 t)
       in static (T.take 1 t <> region) ++ go (Just (if T.null region then T.head t else T.last region)) rest

    quotedRegion close t =
      let (body, rest) = T.break (== close) t
       in case T.uncons rest of
            Nothing -> (body, rest)
            Just (_, afterClose)
              | Just (c, afterDouble) <- T.uncons afterClose, c == close ->
                  let (more, rest') = quotedRegion close afterDouble
                   in (body <> T.pack [close, close] <> more, rest')
              | otherwise -> (body <> T.singleton close, afterClose)

    -- @/* ... */@, nesting; an unterminated one runs to the end.
    blockComment t = depth (1 :: Int) (T.drop 2 t) (T.take 2 t)
      where
        depth 0 rest acc = (acc, rest)
        depth d rest acc
          | T.null rest = (acc, rest)
          | "/*" `T.isPrefixOf` rest = depth (d + 1) (T.drop 2 rest) (acc <> "/*")
          | "*/" `T.isPrefixOf` rest = depth (d - 1) (T.drop 2 rest) (acc <> "*/")
          | otherwise =
              let (chunk, rest') = T.break (`elem` ("/*" :: String)) (T.drop 1 rest)
               in depth d rest' (acc <> T.take 1 rest <> chunk)

    placeholderMayStart = \case
      Nothing -> True
      Just c -> not (isVariableChar c)

    static t = [Static t | not (T.null t)]

    merge (Static a : Static b : rest) = merge (Static (a <> b) : rest)
    merge (f : rest) = f : merge rest
    merge [] = []


isAsciiDigitRef :: Char -> Bool
isAsciiDigitRef c = c >= '0' && c <= '9'
