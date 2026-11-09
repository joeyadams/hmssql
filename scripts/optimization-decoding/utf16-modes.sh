#!/usr/bin/env bash
# Correctness only: compile the decoder at each optimization/inlining setting
# against the same reference corpus. Build hmssql first; this does not time it.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
out=${1:-$(mktemp -d)}
mkdir -p "$out"
out=$(cd "$out" && pwd)
python3 - "$repo/hmssql/src/Hmssql/Tds/Utf16.hs" "$out" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
helper = "writeW16" if "writeW16 ::" in source else "writeW32"
assert "{-# OPTIONS_GHC -O2 #-}" in source, "Expected the decoder's explicit -O2 setting"
assert "{-# INLINE " + helper + " #-}" in source, "Expected an inline private store helper"
for opt in [0, 1, 2]:
    for mode in ["INLINE", "NOINLINE"]:
        directory = Path(sys.argv[2]) / f"O{opt}-{mode.lower()}"
        directory.mkdir(exist_ok=True)
        variant = source.replace("{-# OPTIONS_GHC -O2 #-}", "{-# OPTIONS_GHC -O" + str(opt) + " #-}")
        variant = variant.replace("module Hmssql.Tds.Utf16", "module ProbeUtf16")
        variant = variant.replace("{-# INLINE " + helper + " #-}", "{-# " + mode + " " + helper + " #-}")
        (directory / "ProbeUtf16.hs").write_text(variant)
PY
cd "$repo"
for opt in 0 1 2; do
  for mode in inline noinline; do
    mode_dir="$out/O${opt}-${mode}"
    stack exec -- ghc -O1 -threaded -rtsopts -XBangPatterns -XMultiWayIf -XLambdaCase \
      -i"$mode_dir" -odir "$mode_dir" -hidir "$mode_dir" \
      -package hmssql -package primitive -package streaming \
      "$script_dir/Utf16Boundaries.hs" -o "$mode_dir/check" > "$mode_dir/compile.log" 2>&1
    "$mode_dir/check" +RTS -N1 -A64k -RTS > "$mode_dir/result.txt"
    printf '%s: ' "O${opt}-${mode}"
    cat "$mode_dir/result.txt"
  done
done
