#!/bin/sh
# Builds the documentation site: the guide in docs/guide as HTML, with
# hmssql's Haddock, hyperlinked source included, under api/.
#
#   site/build.sh                    builds the site into _site/
#   site/build.sh --publish REMOTE   builds it, then force-pushes _site/ as the
#                                    one commit of REMOTE's gh-pages branch
#
# GitHub Pages serves that branch once the repository's settings say so
# (Settings, Pages, "Deploy from a branch", gh-pages, the root folder). The
# site is always the latest build; nothing keeps older versions.
#
# The steps:
#
# 1. `stack haddock` for the library alone, with the theme in site/haddock.
#    The theme can't live in stack.yaml's haddock-arguments: Stack passes
#    those arguments both to Cabal (run in the package directory) and to its
#    own index steps (run elsewhere), so a relative --theme path only resolves
#    in one of them, and Haddock then prints "Theme not found" and exits 0.
#    hmssql.css imports linuwial.css, which --built-in-themes puts in the
#    output; the first --theme is the default and the built-ins become Styles
#    menu alternates. --source-css styles the hyperlinked source pages.
# 2. Copy hmssql's own pages into _site/api, and point the links into its
#    dependencies, which Haddock writes as ../text-2.1.4/..., at Hackage.
#    collapse-instances.sh then makes collapsed instances the default.
# 3. Build and run the guide generator in site/generator, which reads the
#    guide's Markdown and the Haddock's doc-index.json.
set -eu

usage="usage: $(basename "$0") [--publish REMOTE]"
publish=""
case "${1:-}" in
  "") ;;
  --publish) publish=${2:?$usage} ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

site=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$site")
out="$repo/_site"
cd "$repo"

github=$(sed -n 's/^github: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' hmssql/package.yaml)
[ -n "$github" ] || { echo "$(basename "$0"): no github field in hmssql/package.yaml" >&2; exit 1; }

# 1. The Haddock. Stack remembers having built it and skips Haddock when
#    nothing changed, even if the output has gone since, so a missing output
#    forces a rebuild.
haddock="$repo/hmssql/$(stack path --dist-dir)/doc/html/hmssql"
build_haddock() {
  stack haddock hmssql --haddock-hyperlink-source \
    --haddock-arguments "\"--theme=$site/haddock/hmssql.css\" --built-in-themes \"--source-css=$site/haddock/source.css\"" \
    "$@"
}
build_haddock
[ -f "$haddock/doc-index.json" ] || build_haddock --force-dirty

# 2. Copy it, without the package's ChangeLog.md and the Hoogle and
#    interface files. Haddock never clears its output directory, and Stack
#    skips Haddock when nothing changed, so the directory can't be cleared
#    first either; instead the pages of modules that Haddock's contents no
#    longer list, removed or renamed since, are left out, and so is the old
#    theme.
rm -rf "$out"
mkdir -p "$out/api"
cp -R "$haddock/." "$out/api"
rm -rf "$out/api/ChangeLog.md" "$out/api/hmssql.haddock" "$out/api/hmssql.txt" "$out/api/Dark.css"
listed=$(grep -o 'href="Hmssql[A-Za-z0-9-]*\.html' "$out/api/index.html" | sed 's/^href="//' | sort -u)
for page in "$out/api"/Hmssql*.html; do
  name=$(basename "$page")
  echo "$listed" | grep -qx "$name" || rm "$page" "$out/api/src/$(echo "${name%.html}" | tr - .).html" 2>/dev/null || true
done
for page in "$out/api/src"/Hmssql*.html; do
  name=$(basename "$page" .html)
  echo "$listed" | grep -qx "$(echo "$name" | tr . -).html" || rm -f "$page"
done
find "$out/api" \( -name '*.html' -o -name 'doc-index.json' \) -print0 |
  xargs -0 perl -i -pe 's#(href=\\?")\.\./([A-Za-z0-9.-]+?-[0-9][0-9.]*)/#${1}https://hackage.haskell.org/package/${2}/docs/#g'
"$site/haddock/collapse-instances.sh" "$out/api"

# 3. The guide.
stack --stack-yaml "$site/generator/stack.yaml" build
mkdir -p "$out/assets"
cp "$site/assets/"* "$out/assets/"
stack --stack-yaml "$site/generator/stack.yaml" exec -- hmssql-guide-site \
  --guide docs/guide --api "$out/api" --out "$out" --root . \
  --repo "https://github.com/$github"

# Without this file, GitHub Pages runs the site through Jekyll.
touch "$out/.nojekyll"

if [ -n "$publish" ]; then
  url=$(git remote get-url "$publish")
  head=$(git rev-parse --short HEAD)
  dirty=$(git status --porcelain | head -n 1)
  tmp=$(mktemp -d)
  cp -R "$out/." "$tmp"
  git -C "$tmp" init -q -b gh-pages
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "Build the site from $head${dirty:+, with uncommitted changes}"
  git -C "$tmp" push -f "$url" gh-pages
  rm -rf "$tmp"
fi
