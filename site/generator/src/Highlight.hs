{-# LANGUAGE OverloadedStrings #-}
-- | Syntax highlighting for the guide's code blocks, as HTML.
--
-- The guide has Haskell, SQL and YAML blocks. A small lexer per language is
-- enough for them, and unlike a highlighting library it lets a Haskell
-- identifier that hmssql exports link to its Haddock.
module Highlight
  ( highlight
  , escapeHtml
  ) where

import Data.Char (isAlphaNum, isDigit, isHexDigit, isLower, isSpace, isUpper, toUpper)
import Data.List (intercalate)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

-- | Highlights a code block's text in the language its info string names,
-- and links each Haskell identifier the lookup resolves. An unknown language
-- comes back escaped and otherwise untouched.
highlight :: (Text -> Maybe Text) -> Text -> Text -> Text
highlight link lang src = case T.toLower lang of
  "haskell" -> T.concat (map (renderHaskell link) (lexHaskell src))
  "hs"      -> T.concat (map (renderHaskell link) (lexHaskell src))
  "sql"     -> T.concat (map renderPlain (lexSql src))
  "yaml"    -> T.concat (map renderPlain (lexYaml src))
  _         -> escapeHtml src

escapeHtml :: Text -> Text
escapeHtml = T.concatMap esc
  where
    esc '<' = "&lt;"
    esc '>' = "&gt;"
    esc '&' = "&amp;"
    esc '"' = "&quot;"
    esc c   = T.singleton c

data Tok
  = Plain Text
  | Keyword Text
  | Comment Text
  | Pragma Text
  | Str Text
  | Num Text
  | Con Text      -- a constructor, type or class name, possibly qualified
  | Var Text      -- a variable name, possibly qualified
  | Op Text
  | Glyph Text    -- reserved operators such as :: and ->

span_ :: Text -> Text -> Text
span_ cls t = "<span class=\"hl-" <> cls <> "\">" <> escapeHtml t <> "</span>"

renderPlain :: Tok -> Text
renderPlain tok = case tok of
  Plain t   -> escapeHtml t
  Keyword t -> span_ "kw" t
  Comment t -> span_ "com" t
  Pragma t  -> span_ "pragma" t
  Str t     -> span_ "str" t
  Num t     -> span_ "num" t
  Con t     -> span_ "con" t
  Var t     -> escapeHtml t
  Op t      -> span_ "op" t
  Glyph t   -> span_ "glyph" t

renderHaskell :: (Text -> Maybe Text) -> Tok -> Text
renderHaskell link tok = case tok of
  Con t | Just href <- link t -> anchor href ("<span class=\"hl-con\">" <> escapeHtml t <> "</span>")
  Var t | Just href <- link t -> anchor href (escapeHtml t)
  _ -> renderPlain tok
  where
    anchor href body = "<a class=\"api\" href=\"" <> escapeHtml href <> "\">" <> body <> "</a>"

-- Haskell ------------------------------------------------------------------

haskellKeywords :: Set Text
haskellKeywords = Set.fromList
  [ "case", "class", "data", "default", "deriving", "do", "else", "family"
  , "forall", "foreign", "if", "import", "in", "infix", "infixl", "infixr"
  , "instance", "let", "mdo", "module", "newtype", "of", "pattern", "proc"
  , "qualified", "rec", "then", "type", "where", "hiding", "as", "via"
  , "stock", "anyclass" ]

haskellGlyphs :: Set Text
haskellGlyphs = Set.fromList ["::", "=", "->", "<-", "=>", "|", "\\", "@", "~", "..", "∷", "→", "←", "⇒"]

isSymbol' :: Char -> Bool
isSymbol' c = c `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)

isIdChar :: Char -> Bool
isIdChar c = isAlphaNum c || c == '_' || c == '\''

lexHaskell :: Text -> [Tok]
lexHaskell s = case T.uncons s of
  Nothing -> []
  Just (c, rest)
    | "{-#" `T.isPrefixOf` s ->
        let (body, after) = T.breakOn "#-}" s
        in Pragma (body <> T.take 3 after) : lexHaskell (T.drop 3 after)
    | "{-" `T.isPrefixOf` s ->
        let (body, after) = blockComment 0 s
        in Comment body : lexHaskell after
    | isSpace c ->
        let (ws, after) = T.span isSpace s in Plain ws : lexHaskell after
    | c == '-', lineComment s ->
        let (body, after) = T.break (== '\n') s in Comment body : lexHaskell after
    | c == '"' ->
        let (body, after) = stringLit '"' rest in Str (T.cons c body) : lexHaskell after
    | c == '\'', Just (body, after) <- charLit rest ->
        Str (T.cons c body) : lexHaskell after
    | isDigit c ->
        let (n, after) = number s in Num n : lexHaskell after
    | isUpper c ->
        let (name, after) = qualified s in classify name : lexHaskell after
    | isLower c || c == '_' ->
        let (name, after) = T.span isIdChar s
        in (if name `Set.member` haskellKeywords then Keyword name else Var name) : lexHaskell after
    | isSymbol' c ->
        let (op, after) = T.span isSymbol' s
        in (if op `Set.member` haskellGlyphs then Glyph op else Op op) : lexHaskell after
    | otherwise -> Plain (T.singleton c) : lexHaskell rest
  where
    -- A run of two or more dashes starts a comment unless another symbol
    -- follows, as in the operator -->.
    lineComment t =
      let (dashes, after) = T.span (== '-') t
      in T.length dashes >= 2 && maybe True (not . isSymbol' . fst) (T.uncons after)
    classify name
      | T.any (== '.') name, Just (_, l) <- T.unsnoc name, not (isIdChar l) = Op name
      | lastPart name /= "" && isLower (T.head (lastPart name)) = Var name
      | otherwise = Con name
    lastPart = snd . T.breakOnEnd "."

-- A possibly qualified name that starts with a capital: M.N.x, M.N.T or M.+.
qualified :: Text -> (Text, Text)
qualified s =
  let (con, after) = T.span isIdChar s
  in case T.uncons after of
       Just ('.', more) -> case T.uncons more of
         Just (d, _)
           | isUpper d -> let (q, rest) = qualified more in (con <> "." <> q, rest)
           | isLower d || d == '_' ->
               let (v, rest) = T.span isIdChar more in (con <> "." <> v, rest)
         _ -> (con, after)
       _ -> (con, after)

blockComment :: Int -> Text -> (Text, Text)
blockComment = go ""
  where
    go acc depth t
      | "{-" `T.isPrefixOf` t = go (acc <> "{-") (depth + 1) (T.drop 2 t)
      | "-}" `T.isPrefixOf` t =
          if depth <= 1 then (acc <> "-}", T.drop 2 t) else go (acc <> "-}") (depth - 1) (T.drop 2 t)
      | otherwise = case T.uncons t of
          Nothing -> (acc, "")
          Just (c, rest) -> go (T.snoc acc c) depth rest

-- The rest of a string literal after its opening quote, with the closing one.
stringLit :: Char -> Text -> (Text, Text)
stringLit q = go ""
  where
    go acc t = case T.uncons t of
      Nothing -> (acc, "")
      Just ('\\', rest) -> case T.uncons rest of
        Just (e, rest') -> go (acc <> T.pack ['\\', e]) rest'
        Nothing -> (T.snoc acc '\\', "")
      Just (c, rest)
        | c == q -> (T.snoc acc c, rest)
        | c == '\n' -> (acc, t)
        | otherwise -> go (T.snoc acc c) rest

-- A character literal after its opening quote, or Nothing when the quote is
-- something else, such as a promoted constructor.
charLit :: Text -> Maybe (Text, Text)
charLit t = case T.unpack (T.take 2 t) of
  ['\\', _] ->
    let (body, after) = T.break (== '\'') t
    in if T.length body <= 6 && not (T.null after) then Just (body <> "'", T.drop 1 after) else Nothing
  [c, '\''] | c /= '\'' -> Just (T.pack [c, '\''], T.drop 2 t)
  _ -> Nothing

number :: Text -> (Text, Text)
number s
  | "0x" `T.isPrefixOf` s || "0X" `T.isPrefixOf` s =
      let (h, after) = T.span (\c -> isHexDigit c || c == '_') (T.drop 2 s) in (T.take 2 s <> h, after)
  | otherwise =
      let (int, after) = T.span (\c -> isDigit c || c == '_') s
      in case T.uncons after of
           Just ('.', more) | Just (d, _) <- T.uncons more, isDigit d ->
             let (frac, after') = T.span (\c -> isDigit c || c == '_') more
                 (ex, after'') = exponent after'
             in (int <> "." <> frac <> ex, after'')
           _ -> let (ex, after') = exponent after in (int <> ex, after')
  where
    exponent t = case T.uncons t of
      Just (e, more) | e == 'e' || e == 'E' ->
        let (sign, more') = T.span (`elem` ("+-" :: String)) more
            (ds, after) = T.span isDigit more'
        in if T.null ds then ("", t) else (T.singleton e <> sign <> ds, after)
      _ -> ("", t)

-- SQL ------------------------------------------------------------------------

sqlKeywords :: Set Text
sqlKeywords = Set.fromList $ map (T.map toUpper)
  [ "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case"
  , "check", "clustered", "column", "commit", "constraint", "create", "cross"
  , "database", "declare", "default", "delete", "desc", "distinct", "drop"
  , "else", "end", "exec", "execute", "exists", "foreign", "from", "go", "grant"
  , "group", "having", "identity", "if", "in", "index", "inner", "insert"
  , "into", "is", "join", "key", "left", "like", "login", "merge", "nonclustered"
  , "not", "null", "off", "on", "or", "order", "output", "primary", "procedure"
  , "proc", "references", "return", "right", "rollback", "select", "set"
  , "table", "then", "top", "tran", "transaction", "union", "unique", "update"
  , "use", "user", "values", "view", "when", "where", "while", "with" ]

lexSql :: Text -> [Tok]
lexSql s = case T.uncons s of
  Nothing -> []
  Just (c, rest)
    | "--" `T.isPrefixOf` s ->
        let (body, after) = T.break (== '\n') s in Comment body : lexSql after
    | "/*" `T.isPrefixOf` s ->
        let (body, after) = T.breakOn "*/" s in Comment (body <> T.take 2 after) : lexSql (T.drop 2 after)
    | isSpace c -> let (ws, after) = T.span isSpace s in Plain ws : lexSql after
    | c == '\'' -> let (body, after) = sqlString rest in Str (T.cons c body) : lexSql after
    | (c == 'N' || c == 'n'), Just ('\'', more) <- T.uncons rest ->
        let (body, after) = sqlString more in Str (T.pack [c, '\''] <> body) : lexSql after
    | c == '[' -> let (body, after) = T.breakOn "]" s in Plain (body <> T.take 1 after) : lexSql (T.drop 1 after)
    | isDigit c -> let (n, after) = number s in Num n : lexSql after
    | isAlphaNum c || c == '_' || c == '@' || c == '#' ->
        let (w, after) = T.span (\x -> isAlphaNum x || x `elem` ("_@#$" :: String)) s
        in (if T.toUpper w `Set.member` sqlKeywords then Keyword w else Plain w) : lexSql after
    | otherwise -> Plain (T.singleton c) : lexSql rest
  where
    sqlString = go ""
      where
        go acc t = case T.uncons t of
          Nothing -> (acc, "")
          Just ('\'', more) | Just ('\'', more') <- T.uncons more -> go (acc <> "''") more'
          Just ('\'', more) -> (T.snoc acc '\'', more)
          Just (x, more) -> go (T.snoc acc x) more

-- YAML -----------------------------------------------------------------------

lexYaml :: Text -> [Tok]
lexYaml = intercalate [Plain "\n"] . map line . T.splitOn "\n"
  where
    line l =
      let (body, comment) = T.breakOn "#" l
          (indent, rest) = T.span isSpace body
          keyed = case T.breakOn ":" rest of
            (k, v) | not (T.null v), not (T.null k), T.all (\c -> isAlphaNum c || c `elem` ("-_ " :: String)) k ->
              [Plain indent, Con k, Plain v]
            _ -> [Plain body]
      in keyed ++ [Comment comment | not (T.null comment)]
