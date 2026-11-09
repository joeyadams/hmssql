#!/usr/bin/env bash
# Measure forty distinct uses of each API, excluding the empty module overhead.
# Usage: scripts/api-code-size.sh OUTPUT-DIRECTORY [MODULE ...]
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$scripts/.." && pwd)
out=${1:?output directory required}
shift
mkdir -p "$out"
out=$(cd "$out" && pwd)
read -r -a modules <<< "$(python3 "$scripts/api-code-size-program.py" "$out")"
if [ $# -gt 0 ]; then modules=("$@"); fi
cd "$repo"
compile() {
  stack exec -- ghc -O1 -c -i"$out/src" -odir "$out" -hidir "$out" \
    -package hmssql -package Decimal -package uuid-types -package time \
    -package text -package bytestring -package streaming \
    "$out/src/$1.hs" > "$out/$1.log" 2>&1 \
    || { cat "$out/$1.log" >&2; exit 1; }
}
text_size() {
  size -A "$out/$1.o" | awk '$1 ~ /^\.text($|\.)/ { n += $2 } END { print n + 0 }'
}
compile CallRecords
compile Empty
empty=$(text_size Empty)
for module in "${modules[@]}"; do
  compile "$module"
  bytes=$(text_size "$module")
  awk -v name="$module" -v bytes="$bytes" -v empty="$empty" \
    'BEGIN { printf "%-20s %9d bytes %8.1f per call\n", name, bytes, (bytes-empty)/40 }'
done
