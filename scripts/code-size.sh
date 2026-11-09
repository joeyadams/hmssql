#!/usr/bin/env bash
# The object code of a program with many records: the generated records of
# scripts/code-size-program.py, compiled at -O1 against the hmssql built in this
# working tree, as an application's own modules are.  It prints the size of the
# .text section of the records, of their FromSqlRow instances and of their ToSqlRow
# instances, with each module's compile time and the bytes per field.  See
# docs/dev/testing.md, "Code size".
#
# Usage: scripts/code-size.sh [--quick] [--check] [--repo DIRECTORY]
#        [--cabal-builddir DIRECTORY --compiler PATH] [OUTPUT-DIRECTORY]
#
# --quick compiles 12 of the 50 records, for iterating; report the full program.
# --repo compiles against the hmssql built in another checkout, such as a worktree
# of an older commit (scripts/perf-compare.sh does this).
# Run `stack build` first.  Compile times are only comparable on an idle machine.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$scripts/.." && pwd)
quick= check= cabal_dir= compiler=ghc
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=--quick; shift ;;
    --check) check=1; shift ;;
    --repo) repo=$(cd "$2" && pwd); shift 2 ;;
    --cabal-builddir) cabal_dir=$2; shift 2 ;;
    --compiler) compiler=$2; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
out=${1:-$(mktemp -d)}
mkdir -p "$out"
python3 "$scripts/code-size-program.py" "$out/src" $quick > /dev/null
fields=$(grep -c ' :: !' "$out/src/Records.hs")
cd "$repo"
# Cabal's execution environment supplies both the inplace library and its exact
# dependency package databases. This also lets the compiler matrix use the same
# generated application that a local Stack build measures.
ghc_command=(stack exec -- ghc)
package_flags=(-package hmssql -package Decimal -package uuid-types -package time -package text -package bytestring)
if [ -n "$cabal_dir" ]; then
  # Cabal must elaborate the environment for the same compiler it will run.
  # Otherwise a different default GHC silently replaces the cached build plan.
  ghc_command=(cabal exec "--builddir=$cabal_dir" "--with-compiler=$compiler" -- "$compiler")
  # The environment exposes exact dependency IDs; only the local library needs
  # exposing here. Other named -package flags can also
  # expose another installed version and make imports such as Data.Text ambiguous.
  package_flags=(-package hmssql)
fi
failed=0
for m in Records FromRows ToRows; do
  start=$(date +%s.%N)
  "${ghc_command[@]}" -O1 -c -i"$out/src" -odir "$out" -hidir "$out" \
    "${package_flags[@]}" \
    "$out/src/$m.hs" > "$out/$m.log" 2>&1 || { echo "$m failed; see $out/$m.log"; exit 1; }
  end=$(date +%s.%N)
  text=$(size -A "$out/$m.o" | awk '$1 ~ /^\.text($|\.)/ { n += $2 } END { print n + 0 }')
  printf '%-9s %10d bytes  %6.0f per field  %6.1f s\n' "$m" "$text" "$(awk -v t="$text" -v f="$fields" 'BEGIN { print t / f }')" "$(awk -v s="$start" -v e="$end" 'BEGIN { print e - s }')"
  if [ -n "$check" ] && [ "$m" != Records ]; then
    # Measure the caller's cost, not the whole library. These budgets leave
    # compiler-version headroom while catching an encoder or decoder body
    # accidentally inlined into every field of an application's records.
    limit=${HMSSQL_CODE_SIZE_FIELD_LIMIT:-100}
    if (( text > fields * limit )); then
      echo "$m exceeds the $limit-byte-per-field budget ($text / $fields)" >&2
      failed=1
    fi
  fi
done
echo "($fields fields; objects in $out)"
exit "$failed"
