#!/bin/sh
# Make "Collapse All Instances By Default" the default in generated Haddock
# docs.  Arguments are directories to search for generated documentation.
#
# Haddock has no option for this, and the docs can't carry the setting either:
# it lives in the browser, in localStorage under the key "global", which the
# Options menu writes.  localStorage is scoped per origin, and every file://
# page is its own origin in Safari (and in Chrome without
# --allow-file-access-from-files), so the box you tick on one module page is
# forgotten as soon as you follow a link to the next one.
#
# So patch the default instead.  Haddock copies haddock-bundle.min.js next to
# the HTML it writes, and that bundle starts from a hard-coded preference
# record, {defaultInstanceState: Open, rememberToggles: true}.  Flipping the
# first field to Closed collapses instances on every page load, with the
# Options checkbox already ticked.  The menu still works, and a preference
# localStorage does manage to remember still overrides the patched default.
#
# Haddock rewrites the bundle whenever it regenerates the docs, so this has to
# run after every documentation build.
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") DIR..." >&2
  exit 2
fi

# The enum object holding Open/Closed is minified, so match whatever it's
# called this time rather than a fixed name.  Re-running is a no-op: by then
# the field already reads Closed and nothing matches.
find "$@" -name haddock-bundle.min.js -print0 |
  xargs -0 perl -i -pe 's/(defaultInstanceState: *[A-Za-z_\$][\w\$]*\.)Open/${1}Closed/g'

# A Haddock update could rename the field itself out from under that pattern.
# Say so, rather than quietly handing back stock documentation.
unpatched=$(find "$@" -name haddock-bundle.min.js -print0 |
  xargs -0 grep -LE 'defaultInstanceState: *[A-Za-z_$][A-Za-z0-9_$]*\.Closed' |
  wc -l | tr -d ' ')
if [ "$unpatched" -ne 0 ]; then
  echo "$(basename "$0"): warning: left $unpatched haddock-bundle.min.js file(s)" >&2
  echo "  unpatched; Haddock's preference record may have changed shape." >&2
fi
