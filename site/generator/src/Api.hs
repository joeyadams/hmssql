{-# LANGUAGE OverloadedStrings #-}
-- | The names hmssql's Haddock documents, read from the @doc-index.json@
-- Haddock writes for its quick-jump search, so that the guide can link a
-- name to its documentation.
module Api
  ( ApiIndex
  , loadApi
  , Link (..)
  , resolveName
  , searchEntries
  ) where

import Data.Aeson (FromJSON (..), eitherDecodeFileStrict, withObject, (.:))
import Data.Char (isAlphaNum, isAscii, isLower, isUpper, ord)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))

data Entry = Entry
  { entryNames  :: Text
  , entryModule :: Text
  , entryLink   :: Text
  , entryHtml   :: Text
  }

instance FromJSON Entry where
  parseJSON = withObject "doc-index entry" $ \o ->
    Entry <$> o .: "name" <*> o .: "module" <*> o .: "link" <*> o .: "display_html"

-- | Where one exporting module documents a name.
data Target = Target
  { targetModule :: Text
  , targetHref   :: Text   -- ^ relative to the Haddock directory
  , targetIsType :: Bool   -- ^ a type or class, rather than a value or constructor
  }

data ApiIndex = ApiIndex
  { apiNames    :: Map Text [Target]  -- ^ best target first
  , apiModules  :: Set Text
  , apiExternal :: Map Text Text      -- ^ names from other packages, to their Hackage pages
  }

-- | Where a name is documented: in hmssql's Haddock, relative to its
-- directory, or on Hackage.
data Link = Internal Text | External Text

-- | Reads @doc-index.json@ from a Haddock output directory.
--
-- An entry's @name@ holds the declaration's own name followed by its
-- constructors, fields or methods, and its @link@ points at the first of
-- them. The others are anchored on the same page as @v:@ names.
loadApi :: FilePath -> IO ApiIndex
loadApi dir = do
  entries <- either fail pure =<< eitherDecodeFileStrict (dir </> "doc-index.json")
  let targets =
        [ (name, Target (entryModule e) href isType)
        | e <- entries
        , let page = T.takeWhile (/= '#') (entryLink e)
        , (i, name) <- zip [0 :: Int ..] (T.words (entryNames e))
        , isIdentifier name
        , let href | i == 0 = entryLink e
                   | otherwise = page <> "#v:" <> anchorId name
              isType = "#t:" `T.isInfixOf` href
        ]
      names = Map.map (sortOn rank) (Map.fromListWith (++) [(n, [t]) | (n, t) <- targets])
  pure ApiIndex
    { apiNames = names
    , apiModules = Set.fromList (map entryModule entries)
    , apiExternal = Map.fromList (concatMap (externalLinks . entryHtml) entries)
    }

-- | The links to other packages in an entry's signature, as names and their
-- Hackage pages. Haddock writes them relative to its own directory, as
-- @<a href="../text-2.1.4/Data-Text.html#t:Text" ...>Text</a>@, and
-- build.sh has already pointed them at Hackage by the time this reads them;
-- either form is understood.
externalLinks :: Text -> [(Text, Text)]
externalLinks html =
  [ (name, url)
  | chunk <- drop 1 (T.splitOn "<a href=\"" html)
  , let (target, rest) = T.breakOn "\"" chunk
        name = T.takeWhile (/= '<') (T.drop 1 (T.dropWhile (/= '>') rest))
  , Just url <- [hackage target]
  , isIdentifier name
  ]
  where
    hackage target
      | "https://hackage.haskell.org/package/" `T.isPrefixOf` target = Just target
      | Just rel <- T.stripPrefix "../" target
      , (pkg, page) <- T.breakOn "/" rel
      , not (T.null pkg), T.length page > 1 =
          Just ("https://hackage.haskell.org/package/" <> pkg <> "/docs" <> page)
      | otherwise = Nothing

-- | Which of a name's exporting modules to link to. The module where the name
-- belongs by topic comes first, then the umbrella module @Hmssql@, then the
-- wire-protocol modules, and the internal ones last. A type wins over a
-- constructor of the same name.
rank :: Target -> (Int, Bool, Int, Text)
rank t = (tier t, not (targetIsType t), length (T.splitOn "." (targetModule t)), targetModule t)

tier :: Target -> Int
tier t
  | any (`elem` ["Internal", "Unsafe", "Lexer"]) parts = 3
  | "Hmssql.Tds" `T.isPrefixOf` m = 2
  | m == "Hmssql" = 1
  | otherwise = 0
  where
    m = targetModule t
    parts = T.splitOn "." m

-- | The Haddock page and anchor for a code span's text, relative to the
-- Haddock directory: a module name, a qualified name such as
-- @Hmssql.Query.query@, or a bare name.
--
-- With the first argument False, a bare name links only to the public
-- modules, not to the wire protocol's or the internal ones. Code blocks
-- resolve their names that way, because a short name such as @parse@ in an
-- example is more likely a local binding than a reference. A qualified name
-- or a module links to any of them. A name hmssql doesn't export, but which
-- appears in its signatures, such as @Text@, links to Hackage.
resolveName :: Bool -> ApiIndex -> Text -> Maybe Link
resolveName anyModule api t
  | t `Set.member` apiModules api = Just (Internal (moduleFile t))
  | Just targets <- Map.lookup t (apiNames api)
  , target : _ <- filter (\x -> anyModule || tier x <= 1) targets = Just (Internal (targetHref target))
  | (q, name) <- T.breakOnEnd "." t
  , not (T.null q)
  , let m = T.dropEnd 1 q
  , m `Set.member` apiModules api
  , Just targets <- Map.lookup name (apiNames api) =
      Internal . targetHref <$> listToMaybe [x | x <- targets, targetModule x == m]
  | otherwise = External <$> Map.lookup t (apiExternal api)

moduleFile :: Text -> Text
moduleFile m = T.replace "." "-" m <> ".html"

-- | The search entries for the API: each name once, with the module it links
-- to, then each module.
searchEntries :: ApiIndex -> [(Text, Text, Text)]
searchEntries api =
  [ (name, targetModule t, targetHref t)
  | (name, t : _) <- Map.toList (apiNames api)
  ]
  ++ [(m, "module", moduleFile m) | m <- Set.toList (apiModules api)]

isIdentifier :: Text -> Bool
isIdentifier n = case T.uncons n of
  Just (c, rest) -> (isLower c || isUpper c || c == '_') && T.all (\x -> isAlphaNum x || x `elem` ("_'" :: String)) rest
  Nothing -> False

-- | Haddock's anchor encoding: letters, digits, @:@, @_@ and @.@ stay, and any
-- other character becomes @-NN-@ with its code point.
anchorId :: Text -> Text
anchorId = T.concatMap esc
  where
    esc c | (isAscii c && isAlphaNum c) || c `elem` (":_." :: String) = T.singleton c
          | otherwise = "-" <> T.pack (show (ord c)) <> "-"
