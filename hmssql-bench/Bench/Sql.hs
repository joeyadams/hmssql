-- | Building queries: composition with '<>' in every association, 'mkQuery'
-- lexing a long text, rendering.  No server needed.
--
-- Composition is expected to be linear in the number of pieces: a 'Query'
-- is a tree, and '<>' is one node.  The first version renumbered
-- placeholders at every '<>', which made a right-associated chain of 2100
-- pieces (the most a request can carry) cost half a second.
module Bench.Sql (benchmarks) where

import Control.DeepSeq (NFData (..))
import Data.Int (Int32)
import Data.List (intersperse)
import qualified Data.Text as T
import Test.Tasty.Bench

import Hmssql

-- | Pieces that a benchmark composes, already built (so that building them
-- is not measured).
newtype Pieces = Pieces [Query]

instance NFData Pieces where
  rnf (Pieces qs) = foldr (\q r -> rnf (queryText q) `seq` r) () qs

-- | @(\@p1), (\@p2), ...@ as one piece per value, separated by commas.
valueRows :: Int -> Pieces
valueRows n = Pieces (intersperse ", " [ "(" <> param (fromIntegral i :: Int32) <> ")" | i <- [1 .. n] ])

benchmarks :: Benchmark
benchmarks = bgroup "Sql"
  [ bgroup "compose"
      [ env (pure (valueRows n)) $ \ ~(Pieces ps) -> bgroup (show n ++ " pieces")
          [ bench "foldr (<>)" $ nf (queryText . foldr (<>) mempty) ps
          , bench "foldl (<>)" $ nf (queryText . foldl (<>) mempty) ps
          , bench "mconcat" $ nf (queryText . mconcat) ps
          ]
      | n <- [100, 2100, 10000]
      ]
  , bgroup "mkQuery"
      [ bench "lex 100 KB of text with strings, comments and 50 placeholders" $
          nf (queryText . (`mkQuery` fiftyParams)) longText
      , bench "lex 100 KB of plain text" $
          nf (queryText . (`mkQuery` ())) (T.replicate 100_000 "x")
        -- Special characters between placeholders: each used to be a
        -- static piece of its own, appended to the text before it.
      , bench "lex 20000 subtractions" $
          nf (queryText . (`mkQuery` ())) ("SELECT " <> T.intercalate " - " (replicate 20_000 "a"))
      , bench "lex a string with 20000 doubled quotes" $
          nf (queryText . (`mkQuery` ())) ("SELECT '" <> T.replicate 20_000 "x''" <> "'")
      , bench "lex a comment with 20000 slashes" $
          nf (queryText . (`mkQuery` ())) ("SELECT 1 /* " <> T.replicate 20_000 "a/b " <> "*/")
      ]
  , bgroup "render"
      [ env (pure (valueRows 2100)) $ \ ~(Pieces ps) ->
          bench "queryText of 2100 pieces" $ nf queryText (mconcat ps)
      ]
  ]
  where
    fiftyParams = [SqlParam (i :: Int) | i <- [1 .. 50]]
    longText = T.replicate 1000
      "SELECT 'it''s a string', N'@p3', [col]]umn], \"quoted\" /* @p1 in a /* nested */ comment */ -- and a line\n\
      \  WHERE x = @p7 AND y = @P12 AND z <> @@ROWCOUNT AND w = @p50;\n"
