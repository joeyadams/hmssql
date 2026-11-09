# Fixed-work decoding experiment drivers

These are the resource drivers behind the decoding measurements of the ideas run in
`docs/dev/performance-research.md` ("The ideas run, 2026-11-04", under "Decoding").
They do not read a clock. Build the library first; compile each Main into its own
scratch output directory to avoid reusing another driver's Main.o. Use GHC 9.12.4
and `-O1 -threaded -rtsopts`, and run with `+RTS -T -N1 -RTS`.

The general driver files are `Resources.hs`,
`Utf16Resources.hs`, and `o0/Recipes0.hs`, `o0/Recipes1.hs`, `o0/Resources.hs`.
Additional drivers retained here:

* `Wide.hs`: widths 7 through 12; argument `4096` is the payload size.
* `o0/Refined.hs`: custom refineField versus built-in decoding; argument `4096`.
* `SqlTypeResources.hs`: argument `100000` name lookups.
* `LoginResources.hs`: argument `10000` encodings of prebuilt LOGIN7 variants.
* `MockResources.hs`: arguments `connect 100` or `query 20`.
* `BulkResources.hs`: no arguments; three successful and three failed live loads,
  each after warmup, checking error text and the stored row count/sum. It imports
  `TestConfig` and uses the test environment's database with a private temporary
  table. Source `~/.hmssql-test-env` before running it; do not print that file.

The row drivers import `Bench.Tokens`, so compile with `-ibench` and the benchmark
extensions: `-XBangPatterns -XLambdaCase -XNumericUnderscores -XOverloadedStrings
-XTypeApplications -XScopedTypeVariables`. Refined also needs `-XDeriveGeneric
-XDeriveAnyClass` and the `o0` source directory on its import path. The live bulk
driver imports `TestConfig` with `-itest`, and also needs `-XNamedFieldPuns
-XOverloadedRecordDot -XRecordWildCards`.

Expose the packages imported by each driver. The row probes use `hmssql`,
`Decimal`, `Only`, `uuid-types`, `binary` and `deepseq`; the mock also uses
`tasty-bench`, `network` and `streaming`; the live bulk probe uses `hspec` and
`streaming`. For example, a scalar probe can be compiled with:

```sh
out=$(mktemp -d)
stack exec -- ghc -O1 -threaded -rtsopts -package hmssql -package binary \
  -odir "$out" -hidir "$out" scripts/optimization-decoding/LoginResources.hs \
  -o "$out/login-resources"
"$out/login-resources" 10000 +RTS -T -N1 -RTS
```

`MockResources` deliberately reuses the benchmark server instead of retaining a
second copy. Generate its temporary helper module before compilation, and add
that temporary directory to GHC's import path:

```sh
mkdir -p "$out/Bench"
sed 's/module Bench.Mock (benchmarks) where/module Bench.MockProbe where/' \
  hmssql-bench/Bench/Mock.hs > "$out/Bench/MockProbe.hs"
```

The raw general dataset rows include commas in dataset names: split from the
right for their final two numeric columns. A probe's post-GC live bytes are not
peak residency. Mock/live network probes can have small scheduling-dependent
allocation variation despite a fixed operation count; report it rather than
interpreting it as elapsed time or an exact per-call cost.

`Utf16Boundaries.hs` is an independent reference corpus for a store-width change.
It covers every 16-bit code unit, odd trailing bytes, input slice offsets, mixed
ASCII/BMP/surrogate runs, output growth/shrink boundaries and streaming chunk cuts.
`utf16-modes.sh OUTPUT_DIRECTORY` copies the decoder into a private temporary
module and runs this corpus at `-O0`, `-O1` and `-O2`, with its private 16-bit or
32-bit store helper both INLINE and NOINLINE. Each of the six runs checks 333,752
cases with frequent GC. The runner uses the current already-built hmssql only for
its unchanged byte-reading helpers; it does not modify repository source or read
a clock.
