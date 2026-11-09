#!/usr/bin/env bash
# Compile a fixed-work allocation and residency probe against the current build.
# Usage: scripts/resource-probe.sh OUTPUT-DIRECTORY [--repo BUILT-CHECKOUT]
#        [--bench-dir BENCH-SOURCE-DIRECTORY]
# The resulting executable accepts --list or a dataset name and iteration count.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$scripts/.." && pwd)
bench_dir=$scripts/../hmssql-bench
out=${1:?output directory required}
shift
while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=$(cd "$2" && pwd); shift 2 ;;
    --bench-dir) bench_dir=$(cd "$2" && pwd); shift 2 ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$repo"
stack exec -- ghc -O1 -threaded -rtsopts -with-rtsopts=-T \
  -XOverloadedStrings -XTypeApplications -XNumericUnderscores -XLambdaCase \
  -XScopedTypeVariables -XBangPatterns -XNamedFieldPuns -XOverloadedRecordDot \
  -i"$bench_dir" -odir "$out" -hidir "$out" \
  -package hmssql -package Decimal -package uuid-types -package time \
  -package text -package bytestring -package binary -package deepseq \
  "$scripts/resource-probe.hs" -o "$out/resource-probe" > "$out/build.log" 2>&1 \
  || { cat "$out/build.log" >&2; exit 1; }
echo "$out/resource-probe"
