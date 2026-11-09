# GHC `threadLabel` on an unlabelled thread: a null pointer the GC follows

Found while testing hmssql on macOS (September 2026). Already reported and
fixed upstream as [GHC #27618](https://gitlab.haskell.org/ghc/ghc/-/issues/27618)
(MR !16468), but not in any GHC release yet: see "Upstream status".

For a thread that has no label, the `threadLabel#` primop returns tag 0 and a
**null pointer** in its `ByteArray#` result. That result is a GC pointer, and
the code that calls the primop may keep it as one: `threadLabel` (from
`GHC.Conc.Sync`, base 4.18 and later) checks the heap for the `Just` it may
build *before* it looks at the tag. When that check fails, the thread saves
both results on its stack, the null pointer in a slot the stack frame's
bitmap marks as a pointer. A major GC that runs while the frame is there
follows it and crashes in `evacuate`. (A minor GC skips pointers outside the
heap, so it survives.)

The heap check fails when the nursery block is full, and also whenever
another capability has asked for a GC or the scheduler wants the capability
back (both set `HpLim` to 0). So a program that reads the labels of
unlabelled threads while GCs happen crashes now and then, and one that also
forces major GCs from another thread crashes at once.

## Environment

| | |
|---|---|
| OS | macOS 15.6.1 (build 24G90); Darwin 24.6.0, arm64 |
| GHC | 9.6.6, 9.8.4, 9.10.3, 9.12.2, 9.12.4 and 9.14.1 (ghcup bindists), `-threaded` |
| hmssql | GHC 9.12.4 (Stackage `nightly-2026-09-27`), test suite built at `-O0` (the `dev` flag) |

## Files

* `Minimal.hs`: the crash, with `base` only. Ten unlabelled threads have
  their labels read 200,000 times while another thread runs
  `performMajorGC` back to back.
* `Workaround.hs`: the same with `threadLabelOf`, a wrapper that tests the
  tag before anything can check the heap (see "Workaround in hmssql").

## Build and run

From the repository root. `-threaded` and `+RTS -N` put the GC requests on
another capability. Build at `-O0`: see "Optimisation" below.

```sh
ghc -O0 -threaded -rtsopts -outputdir /tmp/tl-minimal.o docs/dev/upstream/ghc-threadlabel-null/Minimal.hs -o /tmp/tl-minimal && /tmp/tl-minimal +RTS -N
ghc -O0 -threaded -rtsopts -outputdir /tmp/tl-workaround.o docs/dev/upstream/ghc-threadlabel-null/Workaround.hs -o /tmp/tl-workaround && /tmp/tl-workaround +RTS -N
```

(For another GHC, use `ghc-9.14.1` etc. in place of `ghc`.)

## Observed output

Each program was run 10 times with each GHC.

`Minimal.hs` crashed in 10 of 10 runs with GHC 9.6.6, 9.8.4, 9.10.3,
9.12.2, 9.12.4 and 9.14.1, within a fraction of a second: it printed
nothing and exited with status 139 (SIGSEGV). The macOS crash reports
(checked for 9.6.6, 9.12.4 and 9.14.1) show `EXC_BAD_ACCESS`,
`KERN_INVALID_ADDRESS at 0x0000000000000000`, in `evacuate`.

`Workaround.hs` ran without a crash in 10 of 10 runs with each of those
GHCs, at `-O0` and `-O1`:

```
20000 rounds of threadLabelOf on 10 unlabelled threads: no crash; labels [Just "named",Nothing]
```

## Expected output

```
20000 rounds of threadLabel on 10 unlabelled threads: no crash
```

## Analysis

* **The primop.** `stg_threadLabelzh` in `rts/PrimOps.cmm` (GHC 9.6 to
  9.14.1) ends with `return (0, 0)` when `StgTSO_label(tso)` is 0. The
  disassembly of the 9.12.4 and 9.14.1 RTS shows it:
  `mov w23, #0x0; mov w22, #0x0` (R2, the `ByteArray#`, and R1, the tag),
  then a return to the frame on the stack.

* **The caller.** `threadLabel` in `GHC.Internal.Conc.Sync` (9.14.1) is

  ```haskell
  threadLabel (ThreadId t) = IO $ \s ->
      case threadLabel# t s of
        (# s', 1#, lbl #) ->
            let lbl' = utf8DecodeByteArray# lbl
            in (# s', Just lbl' #)
        (# s', 0#, _ #) -> (# s', Nothing #)
        _ -> error "threadLabel: impossible"
  ```

  As compiled in the 9.12.4 and 9.14.1 bindists, the primop's continuation
  starts with one heap check of 40 bytes (the `Just` and the thunk for
  `lbl'`), and branches on the tag only after it. On failure it pushes a
  frame holding both results, the label as a pointer, and calls
  `stg_gc_noregs`. Nothing is wrong with that code as such: it only goes
  wrong because the primop put a null pointer where a pointer must be.

* **The crash.** With hmssql's test binary linked against the debug RTS
  (`-debug`), the crashing thread's backtrace was `evacuate` ←
  `scavenge_small_bitmap` ← `scavenge_stack` ← `scavenge_one` ←
  `scavenge_mutable_list` ← `GarbageCollect`: a dirty stack on the mutable
  list, one of its frames holding the null pointer. `+RTS -DS` found nothing
  at the GC before, so the pointer got there in between.

* **Optimisation.** At `-O0`, a call to `threadLabel` goes to base's
  compiled code above. At `-O1` and above, `threadLabel` is inlined into
  the caller and compiled there, and whether the null pointer lives across
  a heap check depends on the call site. `Minimal.hs` doesn't crash at
  `-O1` or `-O2`. A loop that summed the labels' lengths and compared each
  label with `Just "x"` crashed in 10 of 10 runs at `-O1` (9.12.4 and
  9.14.1), and in none at `-O2`.

## Upstream status

Checked on the GitHub mirror (`github.com/ghc/ghc`) on 2026-09-29.

* Fixed on `master` by `809294f14cf6939b249d93af92c0ae174dda5b4a` (Luite
  Stegeman, "rts: make stg_threadLabelzh return a valid pointer for
  unlabeled threads", committed 2026-09-16), which fixes #27618. The primop
  now returns `stg_DEAD_SLOT_closure`, a new static closure, instead of 0.
  It adds the regression test `testsuite/tests/rts/T27618.hs`, which reads
  labels on 8 threads while another runs `performMajorGC`, at `-O2` with
  `-N4 -A32k`.
* Backported to `ghc-9.14` as `a878ad4faddd` (2026-09-16). The tag
  `ghc-9.14.2-rc2` has it; `ghc-9.14.2-rc1` and `ghc-9.14.1-release` don't.
* Not on `ghc-9.12` or `ghc-9.10`: both still `return (0, 0)`.

hmssql's resolver uses GHC 9.12.4, so a backport to 9.12 would help. If one
is wanted, ask on #27618.

## Impact on hmssql

The library doesn't call `threadLabel`; its tests did. The full suite
(built at `-O0`) crashed once, on 2026-09-29, in `Resources.ConnectReader`.
Before each of its 3000 connects, that test reads the label of every thread
in the process to find the connection reader threads, and most threads in
the test process have no label. With `+RTS -A64k -N4`, nearly every run of
that test crashed; with `-A1m`, one in six.

## Workaround in hmssql

`threadLabelOf` in `hmssql-tests/Resources/Helpers.hs` calls `threadLabel#` itself:

```haskell
threadLabelOf (ThreadId t) = IO $ \s -> case threadLabel# t s of
  (# s', 0#, _ #) -> (# s', Nothing #)
  (# s', _, label #) -> labelled label s'
```

where `labelled` is NOINLINE and does the decoding and the allocation. The
primop's continuation then allocates nothing, so it has no heap check: it
returns the static `Nothing`, or tail-calls `labelled` with a label that
exists. The generated Cmm was checked at `-O0` and `-O1`. The tests use it
in place of `threadLabel`, and `Resources.HelpersSpec` runs the scenario of
`Minimal.hs` against it (with `threadLabel` there, that test crashed in 5 of
5 runs). It can go once hmssql requires a GHC with the fix.
