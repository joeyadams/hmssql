#!/usr/bin/env bash
# Link a small consumer and retain its GNU linker map for dependency attribution.
# Usage: scripts/link-size.sh OUTPUT-DIRECTORY
# The application is compiled without split sections; dependencies retain the
# flags with which they were built. Compare libraries built with the same policy.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
out=${1:?output directory required}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$scripts/.."
stack exec -- ghc -O1 -fno-split-sections -threaded -rtsopts -package hmssql \
  -package text -odir "$out" -hidir "$out" "$scripts/link-size-program.hs" \
  "-optl-Wl,-Map,$out/link.map" -o "$out/application" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log" >&2; exit 1; }
size -A "$out/application" | awk '$1 == ".text" || $1 == ".data" || $1 == ".rodata"'
wc -c < "$out/application"
python3 "$scripts/link-map-size.py" "$out/link.map"
