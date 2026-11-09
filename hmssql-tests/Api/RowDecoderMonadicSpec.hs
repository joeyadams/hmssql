-- | 'RowDecoderMonadic' (the monadic row decoder: 'singleFieldM',
-- 'remainingColumns', 'toMonadicRowDecoder', 'sqlRowDecoder') at its edges.
-- It consumes columns left to right, and where the applicative 'RowDecoder'
-- is checked against the columns once by 'compileRowDecoder', a
-- 'RowDecoderMonadic' is checked per row: 'Hmssql.Query.compilerForM'
-- requires it to have consumed every column, and reports a row it decoded
-- only part of as a 'DecodeError'.  This module pins down that check, and
-- that 'singleFieldM' running out of columns, 'toMonadicRowDecoder' (which
-- carries its own exact-count check on the slice it's given), and
-- 'nullableField'\/'refineField' at their edges all fail cleanly with a
-- 'DecodeError' rather than a crash or a hang.
module Api.RowDecoderMonadicSpec (spec) where

import Control.Exception (try)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "singleFieldM running out of columns" $
    it "throws a DecodeError with no column name once columns are exhausted" $ \conn -> do
      let decoder =
            (,,)
              <$> singleFieldM (fieldDecoder :: FieldDecoder Int)
              <*> singleFieldM (fieldDecoder :: FieldDecoder Int)
              <*> singleFieldM (fieldDecoder :: FieldDecoder Int)
      r <- try (queryMWith decoder conn "SELECT 1") :: IO (Either DecodeError [(Int, Int, Int)])
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Nothing
          msg `shouldBe` "no more columns"
        Right v -> expectationFailure ("decoded " ++ show v)
      -- the response was drained, so the connection is still usable
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "remainingColumns" $ do
    it "reports every column, untouched, before any singleFieldM call" $ \conn -> do
      -- It consumes nothing itself, so the decoder consumes the columns it
      -- reported: compilerForM requires the whole row.
      let decoder = do
            cols <- remainingColumns
            cols <$ mapM_ (const (singleFieldM sqlValueDecoder)) cols
      [cols] <- queryMWith decoder conn "SELECT 1 AS a, N'x' AS b, CAST(1 AS bit) AS c"
      map columnName cols `shouldBe` ["a", "b", "c"]

    it "is empty once every column has been consumed" $ \conn -> do
      let decoder = singleFieldM (fieldDecoder :: FieldDecoder Int) >> remainingColumns
      [cols] <- queryMWith decoder conn "SELECT 1"
      cols `shouldBe` []

  describe "consuming fewer columns than the result set has" $ do
    it "is a DecodeError naming both counts, and the connection stays usable" $ \conn -> do
      let decoder = singleFieldM (fieldDecoder :: FieldDecoder Int)
      r <- try (queryMWith decoder conn "SELECT 1 AS n, N'unused' AS s, CAST(2.5 AS float) AS f")
        :: IO (Either DecodeError [Int])
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Nothing
          msg `shouldBe` "result has 3 column(s) but the row decoder consumed 1"
        Right v -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    -- The extreme case: a decoder declaring no fields at all ('pure ()')
    -- consumes nothing, so every result set with a column is refused.
    it "a decoder that consumes nothing is refused for every result set with a column" $ \conn -> do
      r <- try (queryMWith (pure ()) conn "SELECT 1, 2, 3, 4, 5") :: IO (Either DecodeError [()])
      case r of
        Left (DecodeError _ msg) ->
          msg `shouldBe` "result has 5 column(s) but the row decoder consumed 0"
        Right v -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "toMonadicRowDecoder" $ do
    it "still enforces the exact column count of the RowDecoder it wraps, against the slice it's given" $ \conn -> do
      let decoder = toMonadicRowDecoder (rowDecoder :: RowDecoder (Int, Int, Int, Int))
      r <- try (queryMWith decoder conn "SELECT 1, 2, 3") :: IO (Either DecodeError [(Int, Int, Int, Int)])
      case r of
        Left (DecodeError _ msg) -> do
          msg `shouldContain` "has 3 column"
          msg `shouldContain` "expects 4"
        Right v -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "drains a failed applicative prefix from its actual position after earlier columns" $ \conn -> do
      let reject :: FieldDecoder Int
          reject = refineField (const (Left "rejected prefix")) (fieldDecoder @Int)
          prefix = (,,) <$> singleField (fieldDecoder @Int)
            <*> singleField reject <*> singleField (fieldDecoder @Int)
          decoder = singleFieldM (fieldDecoder @Int) >> toMonadicRowDecoder prefix
      queryMWith decoder conn "SELECT 1 AS a, 2 AS b, 3 AS bad, 4 AS c, 5 AS d"
        `shouldThrow` (\(DecodeError col msg) -> col == Just "bad" && msg == "rejected prefix")
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  describe "nullableField via singleFieldM" $ do
    it "decodes a non-NULL value as Just" $ \conn -> do
      [a] <- queryMWith (singleFieldM (nullableField (fieldDecoder :: FieldDecoder Int))) conn "SELECT CAST(1 AS int)"
      a `shouldBe` Just (1 :: Int)

    it "decodes SQL NULL as Nothing" $ \conn -> do
      [a] <- queryMWith (singleFieldM (nullableField (fieldDecoder :: FieldDecoder Int))) conn "SELECT CAST(NULL AS int)"
      a `shouldBe` (Nothing :: Maybe Int)

  describe "refineField via singleFieldM" $ do
    it "passes through a successful refinement" $ \conn -> do
      let positive :: FieldDecoder Int
          positive = refineField (\i -> if i > 0 then Right i else Left "must be positive") fieldDecoder
      rs <- queryMWith (singleFieldM positive) conn "SELECT 5 AS n"
      rs `shouldBe` [5 :: Int]

    it "reports a failing refinement as a DecodeError naming the column" $ \conn -> do
      let positive :: FieldDecoder Int
          positive = refineField (\i -> if i > 0 then Right i else Left ("must be positive, got " ++ show i)) fieldDecoder
      r <- try (queryMWith (singleFieldM positive) conn "SELECT -5 AS n") :: IO (Either DecodeError [Int])
      case r of
        Left (DecodeError col msg) -> do
          col `shouldBe` Just "n"
          msg `shouldBe` "must be positive, got -5"
        Right v -> expectationFailure ("decoded " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "sqlRowDecoder (built from remainingColumns/singleFieldM)" $
    it "decodes zero remaining columns as an empty SqlRow, not an error" $ \conn -> do
      let decoder = singleFieldM (fieldDecoder :: FieldDecoder Int) >> sqlRowDecoder
      [SqlRow cols vals] <- queryMWith decoder conn "SELECT 1"
      cols `shouldBe` []
      vals `shouldBe` []
