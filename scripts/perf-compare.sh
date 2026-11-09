#!/usr/bin/env bash
# Compare the working tree with an earlier commit, in code size first and then in
# speed.  It builds the library and the benchmark in both, the earlier commit in a
# temporary worktree, and then measures, with nothing building:
#
# * the code size: scripts/code-size.sh against each build, and the .text of the
#   library's own objects;
# * the time and allocation of the benchmark groups that need no server (Decode,
#   Mock, Encode and Sql), the two binaries alternating, pinned to one CPU
#   (scripts/bench-compare.py).
#
# Usage: scripts/perf-compare.sh [--quick] [--pairs N] [--cpu N]
#        [--baseline-bench BINARY] BASE-COMMIT [OUTPUT-DIRECTORY]
#
# --quick measures the code size of 12 records instead of 50, and times one pair.
# --pairs sets how many times each binary runs (default 5, because the 4 MB cases are
# bimodal).  --cpu picks the CPU to pin the benchmarks to (default the last).
# The earlier commit's build is kept in ~/.cache/hmssql/perf-compare, by commit, so a
# second comparison against it doesn't rebuild it.  The default run took 5 minutes,
# the two builds included, and the timing is only meaningful on an idle machine.
# See docs/dev/testing.md, "Comparing two commits".
# --baseline-bench uses an explicitly prepared binary for timing only, useful when
# both libraries need the same newly expanded benchmark harness. Code-size figures
# still come from BASE-COMMIT. The supplied binary is copied into the result folder.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
quick= pairs=5 baseline_bench= cpu=$(( $(getconf _NPROCESSORS_ONLN) - 1 ))
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=--quick; pairs=1; shift ;;
    --pairs) pairs=$2; shift 2 ;;
    --cpu) cpu=$2; shift 2 ;;
    --baseline-bench) baseline_bench=$(realpath "$2"); shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { sed -n '12p' "$0" | sed 's/^# //' >&2; exit 2; }
sha=$(git -C "$repo" rev-parse --short=7 "$1^{commit}")
head=$(git -C "$repo" rev-parse --short=7 HEAD)
[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ] || head="$head+"
cache=${XDG_CACHE_HOME:-$HOME/.cache}/hmssql/perf-compare
out=${2:-$cache/runs/$(date +%Y%m%d-%H%M%S)-$sha-$head}
mkdir -p "$out"
size_name=code-size${quick:+-quick}.txt
log() { echo "$*" >&2; }

# Stack's build directory in a checkout, with forward slashes: on Windows stack
# prints backslashes, which xargs reads as escapes.
dist_dir() { (cd "$1" && stack path --dist-dir) | sed 's|\\|/|g'; }

# The package directories of the library and of the benchmark in a checkout:
# hmssql/ and hmssql-bench/, or, in a commit from before the library had a folder
# of its own, the checkout itself with the benchmark as a component of hmssql.
lib_dir() { if [ -f "$1/hmssql/package.yaml" ]; then echo "$1/hmssql"; else echo "$1"; fi; }
bench_dir() { if [ -f "$1/hmssql/package.yaml" ]; then echo "$1/hmssql-bench"; else echo "$1"; fi; }
bench_target() { if [ -f "$1/hmssql/package.yaml" ]; then echo hmssql-bench:bench:hmssql-bench; else echo hmssql:bench:hmssql-bench; fi; }

# The .text of the objects compiled from the library's src/, so that objects left
# from deleted modules don't count.
library_text() {
  local dist lib
  dist=$(dist_dir "$1")
  lib=$(lib_dir "$1")
  (cd "$lib/src" && find . -name '*.hs') | sed 's|^\./||; s|\.hs$|.o|' |
    while read -r o; do [ -f "$lib/$dist/build/$o" ] && echo "$lib/$dist/build/$o"; done |
    xargs size -A | awk '$1 ~ /^\.text($|\.)/ { s += $2 } END { print s }'
}

# build DIRECTORY DESTINATION: build the benchmark in a checkout and keep its binary
# and the library's .text in DESTINATION.
build() {
  log "building $(basename "$2") in $1"
  (cd "$1" && stack build --bench --no-run-benchmarks "$(bench_target "$1")") \
    > "$2/build.log" 2>&1 || { log "build failed; see $2/build.log"; exit 1; }
  cp "$(bench_dir "$1")/$(dist_dir "$1")/build/hmssql-bench/hmssql-bench" "$2/bench"
  library_text "$1" > "$2/library-text.txt"
}

base=$cache/$sha new=$out/new
mkdir -p "$base" "$new"
wt=
if [ ! -x "$base/bench" ] || [ ! -f "$base/$size_name" ]; then
  wt=$cache/worktree-$sha
  [ -d "$wt" ] || git -C "$repo" worktree add --detach "$wt" "$sha" > /dev/null
  build "$wt" "$base"
fi
build "$repo" "$new"

timing_base=$base/bench
if [ -n "$baseline_bench" ]; then
  [ -x "$baseline_bench" ] || { log "baseline benchmark is not executable: $baseline_bench"; exit 1; }
  cp "$baseline_bench" "$out/base-bench"
  timing_base=$out/base-bench
fi

log "measuring code size"
if [ -n "$wt" ]; then
  "$repo/scripts/code-size.sh" $quick --repo "$wt" "$base/code-size" > "$base/$size_name"
  git -C "$repo" worktree remove --force "$wt"
fi
"$repo/scripts/code-size.sh" $quick "$new/code-size" > "$new/$size_name"

log "timing $pairs pair(s) on CPU $cpu"
python3 "$repo/scripts/bench-compare.py" "$timing_base" "$new/bench" \
  '$2 == "Decode" || $2 == "Mock" || $2 == "Encode" || $2 == "Sql"' \
  "$pairs" "$cpu" "$out" > "$out/time.txt"

{
  echo "$head against $sha${quick:+ (quick)}"
  if [ -n "$baseline_bench" ]; then
    echo "Timing baseline uses the supplied matching harness: $baseline_bench"
  fi
  echo
  printf '%-14s %12s %12s %7s\n' "Code (.text)" "$sha" "$head" ratio
  row() { printf '%-14s %12d %12d %7.3f\n' "$1" "$2" "$3" "$(awk -v a="$3" -v b="$2" 'BEGIN { print a / b }')"; }
  for m in FromRows ToRows Records; do
    row "$m" "$(awk -v m=$m '$1 == m { print $2 }' "$base/$size_name")" \
             "$(awk -v m=$m '$1 == m { print $2 }' "$new/$size_name")"
  done
  row library "$(cat "$base/library-text.txt")" "$(cat "$new/library-text.txt")"
  tail -n 1 "$new/$size_name"
  echo
  echo "Time and allocation, $head / $sha, median of $pairs pair(s); below 1 is better"
  cat "$out/time.txt"
} | tee "$out/summary.txt"
log "results in $out"
