#!/usr/bin/env bash
# Fixed-work allocation/residency and caller object-code probes; no clocks.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$(mktemp -d)}
mkdir -p "$out/Bench"
out=$(cd "$out" && pwd)
cd "$repo"
stack build hmssql > "$out/build.log" 2>&1
# The benchmark fixture remains unchanged; expose its setup only in this copy.
sed 's/module Bench.Mock (benchmarks) where/module Bench.Mock where/' hmssql-bench/Bench/Mock.hs > "$out/Bench/Mock.hs"
opts=(-O1 -rtsopts -fforce-recomp -package hmssql -odir "$out" -hidir "$out")
for probe in Resources Receive; do
  stack exec -- ghc "${opts[@]}" "scripts/optimization-query/$probe.hs" -o "$out/$probe" > "$out/$probe.build.log" 2>&1
done
stack exec -- ghc "${opts[@]}" -threaded -XExistentialQuantification -XLambdaCase \
  -XNumericUnderscores -XOverloadedStrings -XScopedTypeVariables -XTypeApplications \
  -i"$out" -ihmssql-bench -package tasty-bench scripts/optimization-query/MockResources.hs \
  -o "$out/MockResources" > "$out/MockResources.build.log" 2>&1
for mode in skip named lex lexFast compose composeFast; do
  printf '%s ' "$mode"
  "$out/Resources" "$mode" +RTS -T
done
for mode in bare param rows drain; do
  printf 'mock %s ' "$mode"
  "$out/MockResources" "$mode" +RTS -T -N1
done
printf 'buffered receive '
"$out/Receive" +RTS -T
for probe in Calls CallsProc CallsText CallsMany CallsBulk CallsStream; do
  stack exec -- ghc "${opts[@]}" -c -ddump-simpl -dsuppress-all \
    "scripts/optimization-query/$probe.hs" > "$out/$probe.core" 2>&1
  size -A "$out/$probe.o"
done
