#!/usr/bin/env bash
# Build only: the parent orchestration decides when timing can run on an idle host.
# Usage: scripts/cjk-decode-probe.sh OUTPUT-DIRECTORY --repo BUILT-CHECKOUT
# Both builds use this exact source; inputs are prepared at runtime by env.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
out=${1:?output directory required}
shift
repo=$(cd "$scripts/.." && pwd)
if [ "${1:-}" = --repo ]; then repo=$(cd "$2" && pwd); shift 2; fi
[ $# -eq 0 ] || { echo "unexpected argument: $1" >&2; exit 2; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$repo"
stack exec -- ghc -O1 -threaded -rtsopts -with-rtsopts=-T -fforce-recomp \
  -package hmssql -package text -package bytestring -package deepseq -package tasty-bench \
  -ddump-simpl -dsuppress-all \
  -odir "$out" -hidir "$out" "$scripts/cjk-decode-probe.hs" \
  "-optl-Wl,-Map,$out/link.map" -o "$out/cjk-decode" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log" >&2; exit 1; }
cp "$out/build.log" "$out/driver.core"
objdump -dr "$out/Main.o" > "$out/driver.asm"
nm -S "$out/cjk-decode" > "$out/symbols.txt"
sha256sum "$scripts/cjk-decode-probe.hs" > "$out/source.sha256"
echo "$out/cjk-decode"
