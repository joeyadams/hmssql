-- | 'Query' is SQL text with its parameters, built with 'mkQuery', 'param',
-- 'namedParam', 'rawSql', 'escapeIdentifier' and string literals, and
-- composed with '<>'.  These are its algebraic rules: concatenation
-- renumbers positional placeholders so any two queries compose, named
-- parameters keep their names, the text renders with @\@pN@, a placeholder
-- with no parameter is reported rather than sent, and 'Show' never shows a
-- value.  No server needed.
module Sql.QuerySpec (spec) where

import RecipeParameters
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql
import Hmssql.Types
import Hmssql.Encoding (FieldEncoder (..))
import Hmssql.Query.Types (Fragment (..), QueryParam (..), queryFragments, queryParams, queryProblem)
import Hmssql.Tds.Context

-- | The parameters as they would be sent: name and encoded value.
encoded :: Query -> [(Text, Either String (TypeInfo, Maybe B.ByteString))]
encoded q = [(paramName p, encodedBytes (paramEncode p defaultTdsContext)) | p <- queryParams q]

-- | The @\@pN@ references in rendered text, in order of appearance (an
-- implementation independent of the lexer, on purpose).
references :: Text -> [Int]
references t = case T.breakOn "@p" t of
  (_, rest)
    | T.null rest -> []
    | otherwise ->
        let (digits, after) = T.span (\c -> c >= '0' && c <= '9') (T.drop 2 rest)
         in (if T.null digits then id else (read (T.unpack digits) :)) (references after)

-- | A random query and the values of its positional parameters, in order.
-- (Nothing that 'references' would misread, such as a string literal
-- containing @\@p9@; the lexer's rules are 'Sql.LexerSpec'.)
genPiece :: Gen (Query, [Int32])
genPiece = Gen.choice
  [ do
      x <- val
      pure (param x, [x])
  , do
      x <- val
      pure ("(" <> param x <> " + 1)", [x])
  , do
      x <- val
      y <- val
      pure (mkQuery "@p2 - @p1" (x, y), [x, y])
  , do
      x <- val
      pure (mkQuery "@p1 * @p1" (Only x), [x])
  , do
      x <- val
      y <- val
      z <- val
      pure (mkQuery "COALESCE(@p3, @p1, @p2, '@q')" (x, y, z), [x, y, z])
  , do
      x <- val
      pure (mkQuery "SELECT @a /* @p1 */" (NamedParams [("a", SqlParam x)]) <> param x, [x])
  , do
      name <- Gen.element ["s", "@t", "u"]
      x <- val
      pure (namedParam name x, [])
  , pure ("1", [])
  , pure (rawSql "@q1 /* text */", [])
  , pure (escapeIdentifier "a]b", [])
  , pure (mempty, [])
  ]
  where
    val = Gen.int32 (Range.linearFrom 0 (-1000) 1000)

int32Encoded :: Int32 -> Either String (TypeInfo, Maybe B.ByteString)
int32Encoded x = encodeFieldBytes fieldEncoder defaultTdsContext x

spec :: Spec
spec = do
  describe "building" $ do
    it "a string literal is verbatim text with no parameters" $ do
      let q = "SELECT @p1 FROM [t] -- @p2" :: Query
      queryText q `shouldBe` "SELECT @p1 FROM [t] -- @p2"
      queryParams q `shouldSatisfy` null
      queryProblem q `shouldBe` Nothing

    it "mkQuery turns @pN into placeholders and keeps named references as text" $ do
      let q = mkQuery "SELECT @p2, @p1, @name" (1 :: Int, 2 :: Int)
      queryFragments q `shouldBe` [Static "SELECT ", Placeholder 2, Static ", ", Placeholder 1, Static ", @name"]
      map fst (encoded q) `shouldBe` ["", ""]

    it "param is one placeholder with its value" $ do
      let q = "WHERE id = " <> param (7 :: Int32)
      queryText q `shouldBe` "WHERE id = @p1"
      encoded q `shouldBe` [("", int32Encoded 7)]

    it "namedParam is @name in the text and a named parameter, with or without the @" $ do
      queryText (namedParam "skip" (1 :: Int) <> " " <> namedParam "@top" (2 :: Int)) `shouldBe` "@skip @top"
      map fst (encoded (namedParam "skip" (1 :: Int) <> namedParam "@top" (2 :: Int))) `shouldBe` ["@skip", "@top"]

    it "escapeIdentifier brackets the name and doubles ]" $ do
      queryText (escapeIdentifier "a]b") `shouldBe` "[a]]b]"
      queryText (escapeIdentifier "plain") `shouldBe` "[plain]"
      queryText (escapeIdentifier "") `shouldBe` "[]"

    it "rawSql is verbatim, and empty text adds no fragment" $ do
      queryFragments (rawSql "") `shouldBe` []
      queryFragments ("" :: Query) `shouldBe` []
      queryFragments (rawSql "@p1 @P2") `shouldBe` [Static "@p1 @P2"]

  describe "concatenation" $ do
    it "keeps a placeholder apart from adjacent text that would continue its name" $ do
      queryText ("x = " <> param (1 :: Int) <> "1") `shouldBe` "x = @p1 1"
      queryText ("N" <> param (1 :: Int)) `shouldBe` "N @p1"
      queryText (param (1 :: Int) <> param (2 :: Int)) `shouldBe` "@p1 @p2"
      queryText ("(" <> param (1 :: Int) <> ")") `shouldBe` "(@p1)"
      queryText (param (1 :: Int) <> " + 1") `shouldBe` "@p1 + 1"

    it "renumbers the right operand's placeholders past the left's positional parameters" $ do
      let q = mkQuery "SELECT @p1" (Only (1 :: Int)) <> ", " <> mkQuery "@p2, @p1" (2 :: Int, 3 :: Int) <> ", " <> param (4 :: Int)
      queryText q `shouldBe` "SELECT @p1, @p3, @p2, @p4"
      map fst (encoded q) `shouldBe` ["", "", "", ""]

    it "named parameters don't take a number" $ do
      let q = namedParam "a" (1 :: Int) <> " " <> param (2 :: Int) <> " " <> namedParam "b" (3 :: Int) <> " " <> param (4 :: Int)
      queryText q `shouldBe` "@a @p1 @b @p2"
      map fst (encoded q) `shouldBe` ["@a", "", "@b", ""]

    it "for any queries, the rendered text refers to exactly the positional parameters, in order" $ hedgehog $ do
      pieces <- forAll $ Gen.list (Range.linear 0 12) genPiece
      let q = mconcat (map fst pieces)
          expected = concatMap snd pieces
      annotateShow q
      queryProblem q === Nothing
      -- Every positional parameter is referenced, and the references are 1..n.
      let refs = references (queryText q)
      length (filter (T.null . fst) (encoded q)) === length expected
      sort (dedupe refs) === (if null expected then [] else [1 .. length expected])
      -- The values are in order.
      [v | ("", v) <- encoded q] === map int32Encoded expected

    it "is associative, and mconcat agrees with foldr (<>)" $ hedgehog $ do
      (a, _) <- forAll genPiece
      (b, _) <- forAll genPiece
      (c, _) <- forAll genPiece
      let same x y = do
            queryFragments x === queryFragments y
            encoded x === encoded y
      same ((a <> b) <> c) (a <> (b <> c))
      same (mconcat [a, b, c]) (foldr (<>) mempty [a, b, c])
      same (mempty <> a) a
      same (a <> mempty) a

    it "is linear: a 5000-piece chain flattens the same whichever way it associates" $ do
      let ps = [ "(" <> param i <> ")" | i <- [1 .. 5000 :: Int32] ]
          same x y = do
            queryFragments x `shouldBe` queryFragments y
            map fst (encoded x) `shouldBe` map fst (encoded y)
      same (foldr (<>) mempty ps) (mconcat ps)
      same (foldl (<>) mempty ps) (mconcat ps)
      queryText (foldl (<>) mempty ps) `shouldSatisfy` T.isSuffixOf "(@p4999)(@p5000)"
      queryProblem (foldl (<>) mempty ps) `shouldBe` Nothing

  describe "what can't be sent" $ do
    it "a placeholder with no parameter to refer to is reported, not silently renamed" $ do
      queryProblem (mkQuery "SELECT @p1" ()) `shouldSatisfy` maybe False ("@p1" `isInfixOf`)
      queryProblem (mkQuery "SELECT @p3" (1 :: Int, 2 :: Int)) `shouldSatisfy` maybe False ("@p3" `isInfixOf`)
      queryProblem (mkQuery "SELECT @p0" (Only (1 :: Int))) `shouldSatisfy` maybe False ("@p0" `isInfixOf`)
      queryProblem (mkQuery "DECLARE @p1 int" (NamedParams [("x", SqlParam (1 :: Int))])) `shouldSatisfy` maybe False ("@p1" `isInfixOf`)

    it "an unreferenced parameter is fine (the server declares it unused)" $
      queryProblem (mkQuery "SELECT 1" (1 :: Int, 2 :: Int)) `shouldBe` Nothing

    it "a value the encoder refuses is reported by that parameter's encoder" $ do
      let q = param (10 ^ (40 :: Int) :: Integer)
      case encoded q of
        [("", Left _)] -> pure ()
        other -> expectationFailure (show (map fst other))

  describe "Show" $
    it "shows the text as sent, never a value" $ do
      let secret = "hunter2-do-not-show" :: Text
          q = "SELECT name FROM t WHERE pw = " <> param secret <> " AND x = " <> namedParam "x" secret
      show q `shouldBe` show ("SELECT name FROM t WHERE pw = @p1 AND x = @x" :: Text)
      show q `shouldNotSatisfy` (T.unpack secret `isInfixOf`)

dedupe :: [Int] -> [Int]
dedupe = go []
  where
    go _ [] = []
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise = x : go (x : seen) xs
