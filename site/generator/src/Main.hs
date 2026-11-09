{-# LANGUAGE OverloadedStrings #-}
-- | Builds the HTML site for hmssql's guide from the Markdown in @docs/guide@.
--
-- The guide stays plain Markdown that reads well on GitHub. The generator
-- relies only on what the guide does anyway:
--
-- * The nested list under "Contents" in the guide's README is the tree in the
--   sidebar, and its order is the reading order that the Previous and Next
--   links follow.
-- * A relative link to another page of the guide becomes a link to its HTML
--   page; a relative link to anything else in the repository goes to GitHub.
-- * A code span whose text is a name, a qualified name or a module that the
--   Haddock documents links to it, and so do the names in Haskell code
--   blocks.
--
-- A broken link, or an anchor that no heading has, fails the build.
module Main (main) where

import Api
import CMarkGFM
import Control.Monad (forM, forM_, unless, when)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isLower, isMark, isSpace)
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Highlight
import System.Directory
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath
import System.IO (hPutStrLn, stderr)

data Opts = Opts
  { optGuide  :: FilePath  -- ^ the guide's Markdown
  , optApi    :: FilePath  -- ^ the Haddock output, already copied into the site
  , optOut    :: FilePath  -- ^ the site's root
  , optRoot   :: FilePath  -- ^ the repository's root
  , optRepo   :: Text      -- ^ the repository on GitHub, for links out of the guide
  , optBranch :: Text
  }

usage :: String
usage = "usage: hmssql-guide-site --guide DIR --api DIR --out DIR --repo URL [--root DIR] [--branch NAME]"

parseOpts :: [String] -> Either String Opts
parseOpts = go (Opts "" "" "" "." "" "main")
  where
    go o [] | null (optGuide o) || null (optApi o) || null (optOut o) || T.null (optRepo o) = Left usage
            | otherwise = Right o
    go o ("--guide" : v : rest) = go o { optGuide = v } rest
    go o ("--api" : v : rest) = go o { optApi = v } rest
    go o ("--out" : v : rest) = go o { optOut = v } rest
    go o ("--root" : v : rest) = go o { optRoot = v } rest
    go o ("--repo" : v : rest) = go o { optRepo = T.dropWhileEnd (== '/') (T.pack v) } rest
    go o ("--branch" : v : rest) = go o { optBranch = T.pack v } rest
    go _ _ = Left usage

-- | A page of the guide. The guide's README is the home page.
data Page = Page
  { pageSrc      :: FilePath        -- ^ relative to the guide, with forward slashes
  , pageOut      :: FilePath        -- ^ relative to the site's root
  , pageNav      :: Text            -- ^ its title in the sidebar
  , pageDesc     :: Text            -- ^ its line in the contents
  , pageSection  :: Maybe Text      -- ^ Nothing for the home page
  , pageDoc      :: Node
  , pageHeadings :: [Heading]       -- ^ in document order
  }

data Heading = Heading
  { headingLevel :: Int
  , headingText  :: Text
  , headingSlug  :: Text
  }

data Ctx = Ctx
  { ctxOpts     :: Opts
  , ctxGuideRel :: FilePath          -- ^ the guide's directory relative to the repository
  , ctxPages    :: Map FilePath Page -- ^ by pageSrc
  , ctxApi      :: ApiIndex
  , ctxErrors   :: IORef [String]
  , ctxUnlinked :: IORef (Set Text)
  }

main :: IO ()
main = do
  opts <- either (\e -> hPutStrLn stderr e >> exitFailure) pure . parseOpts =<< getArgs
  root <- canonicalizePath (optRoot opts)
  guide <- canonicalizePath (optGuide opts)
  let guideRel = posix (makeRelative root guide)
  api <- loadApi (optApi opts)

  readme <- readMarkdown (guide </> "README.md")
  sections <- either (\e -> hPutStrLn stderr ("README.md: " ++ e) >> exitFailure) pure (contentsOf readme)
  let home = mkPage "README.md" "Overview" "" Nothing readme
  sectionPages <- forM sections $ \(name, entries) -> do
    ps <- forM entries $ \(src, nav, desc) -> do
      exists <- doesFileExist (guide </> src)
      unless exists $ hPutStrLn stderr ("README.md: the contents list " ++ src ++ ", which doesn't exist") >> exitFailure
      mkPage src nav desc (Just name) <$> readMarkdown (guide </> src)
    pure (name, ps)
  let pages = home : concatMap snd sectionPages

  errors <- newIORef []
  unlinked <- newIORef Set.empty
  let ctx = Ctx opts guideRel (Map.fromList [(pageSrc p, p) | p <- pages]) api errors unlinked

  forM_ (zip3 (Nothing : map Just pages) pages (map Just (drop 1 pages) ++ [Nothing])) $ \(prev, page, next) -> do
    body <- renderPage ctx page
    let html = pageHtml ctx sectionPages prev page next body
        out = optOut opts </> pageOut page
    createDirectoryIfMissing True (takeDirectory out)
    T.writeFile out html

  let index = Aeson.object
        [ "pages" Aeson..= [ (T.pack (pageOut p), titleOf p, fromMaybe "" (pageSection p)) | p <- pages ]
        , "sections" Aeson..= concat [ [ (i, h, a, prose, code) | (h, a, prose, code) <- searchSections p ] | (i, p) <- zip [0 :: Int ..] pages ]
        , "api" Aeson..= searchEntries api
        ]
  createDirectoryIfMissing True (optOut opts </> "assets")
  BL.writeFile (optOut opts </> "assets" </> "search-index.js")
    ("window.HMSSQL_SEARCH = " <> Aeson.encode index <> ";\n")

  names <- readIORef unlinked
  unless (Set.null names) $
    hPutStrLn stderr ("Code spans that name nothing in the Haddock: " ++ T.unpack (T.intercalate ", " (Set.toList names)))
  errs <- readIORef errors
  unless (null errs) $ do
    mapM_ (hPutStrLn stderr) (reverse errs)
    exitFailure
  putStrLn ("Wrote " ++ show (length pages) ++ " pages to " ++ optOut opts)

readMarkdown :: FilePath -> IO Node
readMarkdown path = commonmarkToNode [optSmart, optUnsafe] [extTable, extStrikethrough, extAutolink] <$> T.readFile path

mkPage :: FilePath -> Text -> Text -> Maybe Text -> Node -> Page
mkPage src nav desc section doc = Page
  { pageSrc = src
  , pageOut = if src == "README.md" then "index.html" else replaceExtension src "html"
  , pageNav = nav
  , pageDesc = desc
  , pageSection = section
  , pageDoc = doc
  , pageHeadings = slugify [ (n, plainText kids) | Node _ (HEADING n) kids <- universe doc ]
  }

-- | The page's own title: its first heading.
titleOf :: Page -> Text
titleOf p = case pageHeadings p of
  h : _ -> headingText h
  [] -> pageNav p

-- The contents ------------------------------------------------------------

-- | The sections and pages that the list under the README's "Contents"
-- heading names. Each item of that list is a section: its first paragraph is
-- the section's name, and its own list links the pages, each followed by a
-- dash and a line saying what the page covers.
contentsOf :: Node -> Either String [(Text, [(FilePath, Text, Text)])]
contentsOf (Node _ _ blocks) =
  case dropWhile (not . isContents) blocks of
    _ : Node _ (LIST _) items : _ -> forM items section
    _ -> Left "no list follows a \"Contents\" heading"
  where
    isContents (Node _ (HEADING 2) kids) = T.strip (plainText kids) == "Contents"
    isContents _ = False
    section (Node _ ITEM (Node _ PARAGRAPH name : rest)) =
      case [items | Node _ (LIST _) items <- rest] of
        [items] -> (,) (T.strip (plainText name)) <$> forM items entry
        _ -> Left ("the section " ++ T.unpack (plainText name) ++ " has no list of pages")
    section _ = Left "a contents item isn't a section name followed by a list"
    entry (Node _ ITEM (Node _ PARAGRAPH inlines : _)) =
      case break isLink inlines of
        (_, Node _ (LINK url _) label : after) ->
          Right (T.unpack url, T.strip (plainText label), T.strip (T.dropWhile (`elem` ("—–-:" :: String)) (T.strip (plainText after))))
        _ -> Left "a page in the contents has no link"
    entry _ = Left "a page in the contents isn't a paragraph"
    isLink (Node _ (LINK _ _) _) = True
    isLink _ = False

-- Rendering ----------------------------------------------------------------

data Env = Env
  { envCtx    :: Ctx
  , envPage   :: Page
  , envTight  :: Bool
  , envInLink :: Bool
  , envSlugs  :: IORef [Heading]
  }

renderPage :: Ctx -> Page -> IO Text
renderPage ctx page = do
  slugs <- newIORef (pageHeadings page)
  render (Env ctx page False False slugs) (pageDoc page)

render :: Env -> Node -> IO Text
render env (Node _ ty kids) = case ty of
  DOCUMENT -> inner
  PARAGRAPH
    | envTight env -> inner
    | otherwise -> wrap "<p>" "</p>\n" <$> inner
  BLOCK_QUOTE -> wrap "<blockquote>\n" "</blockquote>\n" <$> renderWith env { envTight = False }
  HTML_BLOCK t -> pure t
  CUSTOM_BLOCK enter exit -> wrap enter exit <$> inner
  CODE_BLOCK info t -> pure (codeBlock env (T.takeWhile (not . isSpace) (T.strip info)) t)
  HEADING n -> do
    h <- atomicModifyIORef' (envSlugs env) (\hs -> (drop 1 hs, take 1 hs))
    body <- inner
    let slug = maybe "" headingSlug (listToMaybe h)
        tag = "h" <> T.pack (show n)
    pure $ if n == 1
      then "<h1>" <> body <> "</h1>\n"
      else "<" <> tag <> " id=\"" <> slug <> "\">" <> body
             <> "<a class=\"anchor\" href=\"#" <> slug <> "\" aria-label=\"Link to this section\">#</a></" <> tag <> ">\n"
  LIST attrs -> do
    items <- renderWith env { envTight = listTight attrs }
    pure $ case listType attrs of
      BULLET_LIST -> "<ul>\n" <> items <> "</ul>\n"
      ORDERED_LIST ->
        let start = if listStart attrs == 1 then "" else " start=\"" <> T.pack (show (listStart attrs)) <> "\""
        in "<ol" <> start <> ">\n" <> items <> "</ol>\n"
  ITEM -> wrap "<li>" "</li>\n" <$> inner
  TEXT t -> pure (escapeHtml t)
  SOFTBREAK -> pure "\n"
  LINEBREAK -> pure "<br>\n"
  HTML_INLINE t -> pure t
  CUSTOM_INLINE enter exit -> wrap enter exit <$> inner
  CODE t -> codeSpan env t
  EMPH -> wrap "<em>" "</em>" <$> inner
  STRONG -> wrap "<strong>" "</strong>" <$> inner
  STRIKETHROUGH -> wrap "<del>" "</del>" <$> inner
  LINK url title -> do
    href <- resolveLink env url
    body <- renderWith env { envInLink = True }
    pure ("<a href=\"" <> escapeHtml href <> "\"" <> titleAttr title <> ">" <> body <> "</a>")
  IMAGE url title -> do
    src <- resolveLink env url
    pure ("<img src=\"" <> escapeHtml src <> "\" alt=\"" <> escapeHtml (plainText kids) <> "\"" <> titleAttr title <> ">")
  TABLE aligns -> table aligns
  TABLE_ROW -> inner
  TABLE_CELL -> inner
  THEMATIC_BREAK -> pure "<hr>\n"
  FOOTNOTE_REFERENCE -> inner
  FOOTNOTE_DEFINITION -> inner
  where
    inner = renderWith env
    renderWith e = T.concat <$> mapM (render e) kids
    wrap a b t = a <> t <> b
    titleAttr t = if T.null t then "" else " title=\"" <> escapeHtml t <> "\""
    table aligns = do
      rows <- forM kids $ \(Node _ _ cells) ->
        forM (zip (aligns ++ repeat NoAlignment) cells) $ \(align, cell) -> do
          body <- render env { envTight = True } cell
          pure (alignAttr align, body)
      let row tag cells = "<tr>" <> T.concat [ "<" <> tag <> a <> ">" <> b <> "</" <> tag <> ">" | (a, b) <- cells ] <> "</tr>\n"
      pure $ case rows of
        [] -> ""
        header : body ->
          "<div class=\"table-wrap\"><table>\n<thead>\n" <> row "th" header <> "</thead>\n<tbody>\n"
            <> T.concat (map (row "td") body) <> "</tbody>\n</table></div>\n"
    alignAttr a = case a of
      LeftAligned -> " style=\"text-align:left\""
      CenterAligned -> " style=\"text-align:center\""
      RightAligned -> " style=\"text-align:right\""
      NoAlignment -> ""


codeSpan :: Env -> Text -> IO Text
codeSpan env t
  | envInLink env = pure plain
  | Just href <- apiHref True env t = pure ("<a class=\"api\" href=\"" <> escapeHtml href <> "\">" <> plain <> "</a>")
  | otherwise = do
      when (looksLikeName t) $ modifyIORef' (ctxUnlinked (envCtx env)) (Set.insert t)
      pure plain
  where
    plain = "<code>" <> escapeHtml t <> "</code>"

-- | Whether a code span is shaped like a Haskell name rather than SQL, a type
-- expression or a command, so that failing to link it is worth reporting.
looksLikeName :: Text -> Bool
looksLikeName t =
  not (T.null t)
    && T.all (\c -> isAlphaNum c || c `elem` ("_'." :: String)) t
    && T.any isLower t
    && not (T.isSuffixOf "." t)

codeBlock :: Env -> Text -> Text -> Text
codeBlock env lang t =
  "<div class=\"code-block\"><pre" <> cls <> "><code>" <> highlight (apiHref False env) lang (T.dropWhileEnd (== '\n') t)
    <> "</code></pre></div>\n"
  where
    cls = if T.null lang then "" else " class=\"lang-" <> escapeHtml lang <> "\""

-- | A link to the Haddock for a name, from the current page. A code span
-- links to any module, and a name in a code block only to the public ones.
apiHref :: Bool -> Env -> Text -> Maybe Text
apiHref anyModule env t = href <$> resolveName anyModule (ctxApi (envCtx env)) t
  where
    href (Internal h) = rootPrefix (envPage env) <> "api/" <> h
    href (External url) = url

rootPrefix :: Page -> Text
rootPrefix p = T.replicate (length (filter (== '/') (pageOut p))) "../"

-- | Rewrites a link in the Markdown for the site, and records an error when
-- its target doesn't exist.
resolveLink :: Env -> Text -> IO Text
resolveLink env url
  | "://" `T.isInfixOf` url || "mailto:" `T.isPrefixOf` url = pure url
  | Just frag <- T.stripPrefix "#" url = do
      checkAnchor page frag
      pure url
  | otherwise = do
      let (path, frag) = T.breakOn "#" url
          fragment = T.drop 1 frag
          inGuide = collapse (takeDirectory (pageSrc page) </> T.unpack path)
          inRepo = collapse (ctxGuideRel ctx </> inGuide)
      case Map.lookup inGuide (ctxPages ctx) of
        Just target -> do
          unless (T.null fragment) (checkAnchor target fragment)
          pure (rootPrefix page <> T.pack (pageOut target) <> frag)
        Nothing -> do
          let local = optRoot (ctxOpts ctx) </> inRepo
          isFile <- doesFileExist local
          isDir <- doesDirectoryExist local
          unless (isFile || isDir) $
            report ("links to " ++ T.unpack url ++ ", which doesn't exist")
          let kind = if isDir then "/tree/" else "/blob/"
          pure (optRepo (ctxOpts ctx) <> kind <> optBranch (ctxOpts ctx) <> "/" <> T.pack inRepo <> frag)
  where
    ctx = envCtx env
    page = envPage env
    report msg = modifyIORef' (ctxErrors ctx) ((ctxGuideRel ctx </> pageSrc page ++ ": " ++ msg) :)
    checkAnchor target frag =
      unless (frag `elem` map headingSlug (pageHeadings target)) $
        report ("links to #" ++ T.unpack frag ++ " in " ++ pageSrc target ++ ", which has no such heading")

-- | Normalises a relative path, resolving the .. components.
collapse :: FilePath -> FilePath
collapse = posix . joinPath . reverse . foldl' step [] . splitDirectories
  where
    step (d : ds) ".." | d /= ".." = ds
    step ds "." = ds
    step ds c = c : ds

posix :: FilePath -> FilePath
posix = map (\c -> if c == '\\' then '/' else c)

-- Headings and text ----------------------------------------------------------

-- | Every node, in document order.
universe :: Node -> [Node]
universe n@(Node _ _ kids) = n : concatMap universe kids

plainText, proseText :: [Node] -> Text
plainText = textOf True
proseText = textOf False

-- | The text of some nodes, with or without their code blocks. Blocks are
-- separated by a space.
textOf :: Bool -> [Node] -> Text
textOf withCode = T.concat . map go
  where
    go (Node _ ty kids) = case ty of
      TEXT t -> t
      CODE t -> t
      CODE_BLOCK _ t -> if withCode then t else ""
      SOFTBREAK -> " "
      LINEBREAK -> " "
      PARAGRAPH -> textOf withCode kids <> " "
      ITEM -> textOf withCode kids <> " "
      TABLE_CELL -> textOf withCode kids <> " "
      _ -> textOf withCode kids

-- | GitHub's anchors for headings, so that a link with an anchor works the
-- same on GitHub and on the site: lowercase, with spaces as hyphens and other
-- punctuation dropped, and a counter added to a repeated anchor.
slugify :: [(Int, Text)] -> [Heading]
slugify = go Map.empty
  where
    go _ [] = []
    go seen ((level, text) : rest) =
      let base = T.map (\c -> if c == ' ' then '-' else c)
                   (T.filter (\c -> isAlphaNum c || isMark c || c `elem` ("-_ " :: String)) (T.toLower (T.strip text)))
          n = Map.findWithDefault (0 :: Int) base seen
          slug = if n == 0 then base else base <> "-" <> T.pack (show n)
      in Heading level text slug : go (Map.insert base (n + 1) seen) rest

-- | A page's text for the search, one entry per section: the heading, its
-- anchor, the prose and the code. The text before the first section belongs
-- to the page's title. The home page's contents list is left out, because
-- every page's own entry already matches its title.
searchSections :: Page -> [(Text, Text, Text, Text)]
searchSections page = filter keep (go (titleOf page) "" [] [] blocks (pageHeadings page))
  where
    Node _ _ blocks = pageDoc page
    keep (h, _, prose, code) =
      not (T.null prose && T.null code) && not (pageSrc page == "README.md" && h == "Contents")
    flush h a prose code = (h, a, squash prose, squash code)
    -- hs is the headings not yet passed, so that each section gets the
    -- anchor the renderer gave its heading.
    go h a prose code [] _ = [flush h a prose code]
    go h a prose code (b@(Node _ ty _) : bs) hs =
      let hs' = drop (length [() | Node _ (HEADING _) _ <- universe b]) hs
      in case (ty, hs) of
           (HEADING 1, _) -> go h a prose code bs hs'
           (HEADING _, next : _) -> flush h a prose code : go (headingText next) (headingSlug next) [] [] bs hs'
           _ -> go h a (prose ++ [proseText [b]]) (code ++ [t | Node _ (CODE_BLOCK _ t) _ <- universe b]) bs hs'
    squash = T.unwords . T.words . T.unwords

-- The page --------------------------------------------------------------------

pageHtml :: Ctx -> [(Text, [Page])] -> Maybe Page -> Page -> Maybe Page -> Text -> Text
pageHtml ctx sections prev page next body = T.concat
  [ "<!doctype html>\n<html lang=\"en\" data-root=\"", root, "\">\n<head>\n"
  , "<meta charset=\"utf-8\">\n"
  , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
  , "<meta name=\"color-scheme\" content=\"light dark\">\n"
  , "<title>", escapeHtml title, "</title>\n"
  , if T.null (pageDesc page) then "" else "<meta name=\"description\" content=\"" <> escapeHtml (pageDesc page) <> "\">\n"
  , "<link rel=\"icon\" href=\"", root, "assets/icon.svg\" type=\"image/svg+xml\">\n"
  , "<link rel=\"stylesheet\" href=\"", root, "assets/guide.css\">\n"
  , "<script src=\"", root, "assets/guide.js\" defer></script>\n"
  , "</head>\n<body>\n"
  , "<a class=\"skip\" href=\"#content\">Skip to the content</a>\n"
  , "<header class=\"topbar\">\n"
  , "<button class=\"nav-toggle\" type=\"button\" aria-label=\"Show the contents\" aria-controls=\"sidebar\" aria-expanded=\"false\">"
  , "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M3 6h18M3 12h18M3 18h18\"/></svg></button>\n"
  , "<a class=\"brand\" href=\"", root, "index.html\"><span class=\"brand-name\">hmssql</span><span class=\"brand-sub\">guide</span></a>\n"
  , "<div class=\"search\" role=\"search\">\n"
  , "<svg class=\"search-icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"/><path d=\"M20 20l-3.5-3.5\"/></svg>\n"
  , "<input id=\"search-input\" type=\"search\" placeholder=\"Search the guide and the API\" autocomplete=\"off\" spellcheck=\"false\" "
  , "aria-label=\"Search\" aria-controls=\"search-results\" aria-expanded=\"false\">\n"
  , "<kbd class=\"search-key\" aria-hidden=\"true\">/</kbd>\n"
  , "<div id=\"search-results\" class=\"search-results\" role=\"listbox\" hidden></div>\n"
  , "</div>\n"
  , "<nav class=\"toplinks\" aria-label=\"Site\">"
  , "<a href=\"", root, "api/index.html\">API reference</a>"
  , "<a href=\"", repo, "\">GitHub</a></nav>\n"
  , "</header>\n"
  , "<div class=\"layout\">\n"
  , "<nav id=\"sidebar\" class=\"sidebar\" aria-label=\"Guide\">\n", tree
  , "<div class=\"toplinks-mobile\"><a href=\"", root, "api/index.html\">API reference</a><a href=\"", repo, "\">GitHub</a></div>\n"
  , "</nav>\n"
  , "<main id=\"content\" class=\"content\">\n<article class=\"prose\">\n"
  , maybe "" (\s -> "<p class=\"eyebrow\">" <> escapeHtml s <> "</p>\n") (pageSection page)
  , body
  , "</article>\n"
  , pager
  , "<footer class=\"page-footer\"><a href=\"", repo, "/blob/", optBranch (ctxOpts ctx), "/"
  , T.pack (ctxGuideRel ctx </> pageSrc page), "\">This page's Markdown on GitHub</a></footer>\n"
  , "</main>\n</div>\n</body>\n</html>\n"
  ]
  where
    root = rootPrefix page
    repo = escapeHtml (optRepo (ctxOpts ctx))
    title = case pageSection page of
      Nothing -> "hmssql guide"
      Just _ -> titleOf page <> " · hmssql guide"
    link p = root <> T.pack (pageOut p)
    current p = pageSrc p == pageSrc page
    item p = T.concat
      [ "<li><a href=\"", link p, "\"", if current p then " aria-current=\"page\"" else "", ">"
      , escapeHtml (pageNav p), "</a>"
      , if current p then onThisPage else ""
      , "</li>\n" ]
    onThisPage = case [h | h <- pageHeadings page, headingLevel h == 2] of
      [] -> ""
      hs -> "<ul class=\"on-page\">" <> T.concat
              [ "<li><a href=\"#" <> headingSlug h <> "\">" <> escapeHtml (headingText h) <> "</a></li>" | h <- hs ]
              <> "</ul>"
    tree = T.concat
      [ "<ul class=\"tree\">\n", maybe "" item (Map.lookup "README.md" (ctxPages ctx)), "</ul>\n"
      , T.concat
          [ "<p class=\"tree-section\">" <> escapeHtml name <> "</p>\n<ul class=\"tree\">\n" <> T.concat (map item ps) <> "</ul>\n"
          | (name, ps) <- sections ]
      ]
    pager = T.concat
      [ "<nav class=\"pager\" aria-label=\"Previous and next pages\">"
      , maybe "<span></span>" (pagerLink "prev" "Previous") prev
      , maybe "<span></span>" (pagerLink "next" "Next") next
      , "</nav>\n" ]
    pagerLink cls label p = T.concat
      [ "<a class=\"", cls, "\" href=\"", link p, "\" rel=\"", cls, "\">"
      , "<span class=\"pager-dir\">", label, "</span>"
      , "<span class=\"pager-title\">", escapeHtml (pageNav p), "</span></a>" ]
