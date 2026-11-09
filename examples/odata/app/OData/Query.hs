-- | The query options of a request, and the statements they compile to.
--
-- A request is a tree: the requested set at the root, and a level under
-- it for each collection property that @$expand@ names.  Each level is
-- one statement, and the statements are built so that their streams can
-- be zipped: the root numbers its rows with @ROW_NUMBER()@, and a child
-- statement joins its table to the parent's /key relation/, the parent's
-- statement reduced to its key columns and row numbers, so that every
-- child row carries its parent's number and comes sorted by it.  Reading
-- the streams side by side, the children of a parent are the next rows
-- of the child stream with the parent's number ("OData.Expand").
--
-- The request's text never reaches the SQL.  Property names are matched
-- against the model and emitted as the model's names, bracket-quoted with
-- 'escapeIdentifier', and @$top@ and @$skip@ become parameters.  A
-- statement is a 'Query', built with '<>' from pieces that carry their
-- parameters with them.
module OData.Query
  ( Options (..)
  , parseOptions
  , Level (..)
  , compile
  ) where

import Control.Monad (foldM, forM, unless, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as T

import Hmssql
import OData.Model

------------------------------------------------------------------------------
-- Options

data Options = Options
  { select :: Maybe [Text]
    -- ^ 'Nothing' selects every property.
  , orderby :: [(Text, Bool)]
    -- ^ A property, and whether it is descending.
  , top :: Maybe Int64
  , skip :: Maybe Int64
  , expand :: [(Text, Options)]
    -- ^ A collection property, and the options in its parentheses.
  }

noOptions :: Options
noOptions = Options Nothing [] Nothing Nothing []

-- | The query string's options, already percent-decoded.
parseOptions :: [(Text, Text)] -> Either Text Options
parseOptions = foldM apply noOptions
  where
    apply opts (name, value) = case name of
      "$select" -> Right opts { select = Just (map T.strip (T.splitOn "," value)) }
      "$orderby" -> (\o -> opts { orderby = o }) <$> mapM orderItem (T.splitOn "," value)
      "$top" -> (\n -> opts { top = Just n }) <$> positive name value
      "$skip" -> (\n -> opts { skip = Just n }) <$> nonNegative name value
      "$expand" -> (\e -> opts { expand = e }) <$> parseExpand value
      _ -> Left ("unknown query option " <> name)
    orderItem item = case T.words item of
      [p] -> Right (p, False)
      [p, "asc"] -> Right (p, False)
      [p, "desc"] -> Right (p, True)
      _ -> Left ("malformed $orderby item \"" <> T.strip item <> "\"")

nonNegative, positive :: Text -> Text -> Either Text Int64
nonNegative name value = case T.decimal value of
  Right (n, "") | n <= toInteger (maxBound :: Int64) -> Right (fromInteger n)
  _ -> Left (name <> " must be a non-negative integer, not \"" <> value <> "\"")
positive name value = case nonNegative name value of
  Right 0 -> Left (name <> " must be at least 1")
  other -> other

-- | @$expand=a,b($select=x;$orderby=y desc;$expand=c)@: items separated by
-- commas, each a property name with optional options in parentheses,
-- separated by semicolons.
parseExpand :: Text -> Either Text [(Text, Options)]
parseExpand value = splitOutsideParens ',' value >>= mapM (item . T.strip)
  where
    item text = case T.break (== '(') text of
      (name, "") -> Right (name, noOptions)
      (name, rest) | T.isSuffixOf ")" rest -> do
        parts <- splitOutsideParens ';' (T.drop 1 (T.dropEnd 1 rest))
        pairs <- forM parts $ \part -> case T.breakOn "=" (T.strip part) of
          (k, v) | not (T.null v) -> Right (k, T.drop 1 v)
          _ -> Left ("malformed option \"" <> part <> "\" in $expand=" <> name <> "(...)")
        (,) name <$> parseOptions pairs
      _ -> Left ("malformed $expand item \"" <> text <> "\"")

-- | Split on a separator, except inside parentheses.
splitOutsideParens :: Char -> Text -> Either Text [Text]
splitOutsideParens sep = go (0 :: Int) "" []
  where
    go depth current acc text = case T.uncons text of
      Nothing
        | depth /= 0 -> Left "unbalanced parentheses"
        | otherwise -> Right (reverse (current : acc))
      Just (c, rest)
        | c == sep && depth == 0 -> go depth "" (current : acc) rest
        | c == '(' -> go (depth + 1) (T.snoc current c) acc rest
        | c == ')' && depth == 0 -> Left "unbalanced parentheses"
        | c == ')' -> go (depth - 1) (T.snoc current c) acc rest
        | otherwise -> go depth (T.snoc current c) acc rest

------------------------------------------------------------------------------
-- Statements

-- | One level of the tree: the set, the columns its statement returns,
-- and the collection properties expanded under it.
data Level = Level
  { levelSet :: EntitySet
  , selected :: [Column]
  , isRoot :: Bool
  , statement :: Query
  , children :: [(Text, Level)]
  }

-- | Compile a request.  Each statement's columns come in the order
-- "OData.Decode" reads them: the parent's row number (not at the root),
-- the selected columns, and the row's own number.
compile :: Model -> EntitySet -> Options -> Either Text Level
compile model = level Nothing
  where
    level :: Maybe Parent -> EntitySet -> Options -> Either Text Level
    level parent set opts = do
      cols <- selectedColumns set opts.select
      order <- orderBy set opts.orderby
      when (isJust parent && (isJust opts.top || isJust opts.skip)) $
        Left "$top and $skip inside $expand are not supported"
      let keyAlias k keys = ident ("__k" <> T.pack (show (length (takeWhile (/= k) keys) + 1)))
          source = case parent of
            Nothing -> ident set.setName <> " AS t"
            Just p ->
              "(" <> p.relation <> ") AS p JOIN " <> ident set.setName <> " AS t ON "
                <> joinWith " AND " ["t." <> ident c <> " = p." <> keyAlias k p.keys | (c, k) <- p.join]
          -- A child level is sorted by its parent's row number first.
          orderClause = "ORDER BY " <> commaSep (["p.[__rn]" | isJust parent] ++ order)
          rowNumber = "ROW_NUMBER() OVER (" <> orderClause <> ") AS [__rn]"
          paged = isJust opts.top || isJust opts.skip
          statement =
            "SELECT " <> commaSep (["p.[__rn]" | isJust parent] ++ ["t." <> ident c.colName | c <- cols] ++ [rowNumber])
              <> " FROM " <> source <> " " <> orderClause <> paging opts
          -- The key relation, for the children's statements.  A derived
          -- table may have an ORDER BY only with an OFFSET, which is
          -- what a paged root needs anyway.
          relation =
            "SELECT " <> commaSep (["t." <> ident k <> " AS " <> keyAlias k set.keyColumns | k <- set.keyColumns] ++ [rowNumber])
              <> " FROM " <> source <> (if paged then " " <> orderClause <> paging opts else mempty)
      children <- forM opts.expand $ \(name, nested) -> do
        nav <- maybe (Left (name <> " is not a collection property of " <> set.setName)) Right (lookupNavigation set name)
        child <- maybe (Left (nav.navTarget <> " is not served")) Right (lookupSet model nav.navTarget)
        (,) name <$> level (Just Parent { relation, keys = set.keyColumns, join = nav.navJoin }) child nested
      pure Level { levelSet = set, selected = cols, isRoot = isNothing parent, statement, children }

-- | A level as its children's statements see it: its key relation, the
-- key columns the relation's @__k1@, @__k2@, ... stand for, and the foreign
-- key as (child column, key column) pairs.
data Parent = Parent
  { relation :: Query
  , keys :: [Text]
  , join :: [(Text, Text)]
  }

-- | @OFFSET \@skip ROWS FETCH NEXT \@top ROWS ONLY@, or nothing.
paging :: Options -> Query
paging opts
  | isJust opts.top || isJust opts.skip =
      " OFFSET " <> namedParam "skip" (fromMaybe 0 opts.skip) <> " ROWS"
        <> maybe mempty (\n -> " FETCH NEXT " <> namedParam "top" n <> " ROWS ONLY") opts.top
  | otherwise = mempty

-- | The @$orderby@ keys, then the key columns not among them, so that
-- the order is total and the row numbers mean the same in every
-- statement.  A set with no key and no @$orderby@ gets an arbitrary order.
orderBy :: EntitySet -> [(Text, Bool)] -> Either Text [Query]
orderBy set items = do
  keys <- forM items $ \(name, desc) -> do
    col <- property set name
    pure ("t." <> ident col.colName <> if desc then " DESC" else " ASC")
  let tiebreak = ["t." <> ident k <> " ASC" | k <- set.keyColumns, k `notElem` map fst items]
  pure $ case keys ++ tiebreak of
    [] -> ["(SELECT NULL)"]
    order -> order

-- | The columns in schema order, restricted to @$select@.
selectedColumns :: EntitySet -> Maybe [Text] -> Either Text [Column]
selectedColumns set = \case
  Nothing -> Right set.columns
  Just names -> do
    mapM_ (property set) names
    let cols = [c | c <- set.columns, c.colName `elem` names]
    unless (not (null cols)) $ Left "$select must name at least one property"
    pure cols

property :: EntitySet -> Text -> Either Text Column
property set name = case lookupColumn set name of
  Just col -> Right col
  Nothing
    | isJust (lookupNavigation set name) -> Left (name <> " is a collection property of " <> set.setName <> "; it goes in $expand")
    | otherwise -> Left (name <> " is not a property of " <> set.setName)

ident :: Text -> Query
ident = escapeIdentifier

commaSep :: [Query] -> Query
commaSep = joinWith ", "

joinWith :: Query -> [Query] -> Query
joinWith _ [] = mempty
joinWith sep (q : qs) = q <> foldMap (sep <>) qs
