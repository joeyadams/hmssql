{-# LANGUAGE MagicHash #-}
-- | Finding the positional parameter references (@\@p1@, @\@p2@, ...) in
-- T-SQL text, so that 'Hmssql.Query.mkQuery' can turn them into placeholders
-- that renumber when queries are concatenated.
--
-- This is not a T-SQL parser.  It only knows enough of the lexical
-- structure to leave alone what is inside string literals (@'...'@ and
-- @N'...'@, with @''@ for a quote), quoted identifiers (@\"...\"@ with
-- @\"\"@, and @[...]@ with @]]@) and comments (@-- ...@ to the end of the
-- line, and @\/* ... *\/@, which T-SQL nests).  Everything unterminated
-- runs to the end of the text; the scanner never fails.
module Hmssql.Query.Lexer
  ( Fragment (..)
  , lexPlaceholders
  , isVariableChar
  ) where

import Data.Char (GeneralCategory (..), generalCategory, isDigit)
import qualified Data.Text as T
import Data.Text.Internal (Text (..))
import Hmssql.Internal.Derived

-- | A piece of SQL text, or a reference to a positional parameter (1-based).
data Fragment
  = Static !Text
  | Placeholder !Int

instance Show Fragment where
  showsPrec p = \case
    Static a -> showCon1 p "Static"# a
    Placeholder a -> showCon1 p "Placeholder"# a
  {-# OPAQUE showsPrec #-}

instance Eq Fragment where
  x == y = case (x, y) of
    (Static a, Static a') -> eq a a'
    (Placeholder a, Placeholder a') -> a == a'
    _ -> False
  {-# OPAQUE (==) #-}

-- | Split T-SQL text into static text and positional placeholders.
--
-- A placeholder is @\@p@ (either case) followed by one or more ASCII digits,
-- standing alone as a name: the character before the @\@@ is not @\@@ or a
-- character of a variable name (so @\@\@p1@ and @x\@p1@ are text), and the
-- character after the digits is not one either (so @\@p1x@, @\@p1_old@ and
-- @\@p1é@ are other variables).  @\@P01@ is placeholder 1.  More than nine
-- digits is text (no request has that many parameters).
--
-- Adjacent static text is merged; the result concatenates back to the input
-- with each placeholder rendered as @\@pN@.
--
-- The scanner only finds the placeholders; the static text between two of
-- them is one slice of the input.  (Building it from the pieces the
-- scanner passes over, appending as it went, was quadratic in the number
-- of special characters between placeholders: every @-@ of @a - b@, every
-- @''@ in a string, every @/@ or @*@ in a comment.)
lexPlaceholders :: Text -> [Fragment]
lexPlaceholders whole@(Text arr off0 len0) = fragments off0 (go Nothing whole)
  where
    -- The static text from @from@ to the next placeholder, and so on.
    fragments from = \case
      [] -> static from (off0 + len0)
      (start, end, n) : ps -> static from start ++ Placeholder n : fragments end ps
    static a b = [Static (Text arr a (b - a)) | b > a]

    -- The placeholders in @t@, as the offsets (into the input's array) of
    -- their @\@@ and of the end of their digits, and their numbers.
    -- @prev@ is the character before @t@, if any.
    go :: Maybe Char -> Text -> [(Int, Int, Int)]
    go prev t
      | T.null t = []
      | otherwise =
          let (plain, rest) = T.span ordinary t
              prev' = if T.null plain then prev else Just (T.last plain)
           in special prev' rest

    special prev t = case T.uncons t of
      Nothing -> []
      Just (c, rest) -> case c of
        '\'' -> skipQuoted '\'' rest
        '"' -> skipQuoted '"' rest
        '[' -> skipQuoted ']' rest
        '-' | "--" `T.isPrefixOf` t -> go (Just '-') (T.dropWhile (/= '\n') t)
        '/' | "/*" `T.isPrefixOf` t -> go (Just '/') (blockComment (1 :: Int) (T.drop 2 t))
        '@' | placeholderMayStart prev
            , Just (p, afterP) <- T.uncons rest
            , p == 'p' || p == 'P'
            , (digits, after) <- T.span isAsciiDigit afterP
            , not (T.null digits), T.length digits <= 9
            , maybe True (not . isVariableChar) (fst <$> T.uncons after)
            -> (offset t, end digits, T.foldl' (\n d -> n * 10 + fromEnum d - fromEnum '0') 0 digits)
                 : go (Just (T.last digits)) after
        _ -> go (Just c) rest

    -- Where a non-empty text starts and ends in the input's array.  (An
    -- empty one may be text's shared empty value, at offset 0.)
    offset (Text _ o _) = o
    end (Text _ o l) = o + l

    -- Not the start of anything the scanner looks at.
    ordinary c = c /= '\'' && c /= '"' && c /= '[' && c /= '-' && c /= '/' && c /= '@'

    -- A quoted region after its opening character: up to the closing one,
    -- where a doubled closing character stays inside.  (For @[...]@ the
    -- closing character differs from the opening one; a doubled @]@ is an
    -- escaped bracket, as for quotes.)  The character before what follows
    -- is the closing one, or the region's last (or the opening one) if it
    -- is unterminated.
    skipQuoted close = region False
      where
        -- @doubled@: a doubled closing character came before @t@.
        region doubled t =
          let (body, rest) = T.break (== close) t
           in case T.uncons rest of
                Nothing -> go (Just (lastOf doubled body)) rest
                Just (_, afterClose)
                  | Just (c, afterDouble) <- T.uncons afterClose, c == close -> region True afterDouble
                  | otherwise -> go (Just close) afterClose
        -- An unterminated region's last character: of its body, or of the
        -- doubled closing character before it, or the opening character.
        lastOf doubled body
          | not (T.null body) = T.last body
          | doubled = close
          | otherwise = opening
        opening = case close of
          ']' -> '['
          q -> q

    -- @/* ... */@ after its opening, nesting; an unterminated one runs to
    -- the end.  What follows it.
    blockComment :: Int -> Text -> Text
    blockComment 0 rest = rest
    blockComment d rest
      | T.null rest = rest
      | "/*" `T.isPrefixOf` rest = blockComment (d + 1) (T.drop 2 rest)
      | "*/" `T.isPrefixOf` rest = blockComment (d - 1) (T.drop 2 rest)
      | otherwise = blockComment d (T.dropWhile (\c -> c /= '/' && c /= '*') (T.drop 1 rest))

    placeholderMayStart = \case
      Nothing -> True
      Just c -> not (isVariableChar c)

isAsciiDigit :: Char -> Bool
isAsciiDigit c = isDigit c && c <= '9'

-- | A character of a T-SQL variable name after the leading @\@@: a letter,
-- combining mark, decimal digit or letter number from the Basic
-- Multilingual Plane, or one of @\@@, @#@, @$@ and @_@.  (SQL Server
-- rejects surrogates in identifiers, so nothing above U+FFFF.)
isVariableChar :: Char -> Bool
isVariableChar c = c <= '\xFFFF' && (c `elem` ("@#$_" :: String) || case generalCategory c of
  UppercaseLetter -> True
  LowercaseLetter -> True
  TitlecaseLetter -> True
  ModifierLetter -> True
  OtherLetter -> True
  NonSpacingMark -> True
  SpacingCombiningMark -> True
  DecimalNumber -> True
  LetterNumber -> True
  _ -> False)
