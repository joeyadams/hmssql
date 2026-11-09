# Linear types in a real Haskell library: one solved problem, and why there aren't more

2026-10-30 · Joey Adams

## Summary

Linear types solved one real problem in hmssql, a native Haskell client for SQL Server, and we could find no second one worth solving with them. The problem was a buffer written after it had already been wrapped as an immutable `ByteString`. Linear types closed it with no extra copies and no measurable slowdown, and misuse that used to compile now doesn't.

The benefit is limited for a reason that isn't a flaw in the feature. In Haskell, a garbage collector and immutable data already prevent the bugs that ownership prevents in Rust, so a linear type only earns its place where a program deliberately steps outside those defaults. We stepped outside them in one place, and the conversion caught no existing bug there.

So "a solution in search of a problem" is half right. The problems are real, but rare, and they sit at the boundary with mutable memory. Borrow checking is everywhere in Rust because it replaces the garbage collector, while Haskell's linear types only add a narrow guarantee on top of one.

## What happened afterwards

hmssql removed the linear types on the day this was written. The code below is the linear version as it was on 2026-10-30, and the numbers are from that version. A packet's storage is now private to `Hmssql.Tds.PacketWriter`, which makes the `ByteString` only after the packet's last write, so nothing outside that module can see a packet while it is mutable. [design.md](design.md#who-owns-a-packets-bytes) has the current contract.

## The problem: a buffer written after it became a ByteString

hmssql had one place where an immutable `ByteString` was mutated, and it was on purpose. SQL Server's MARS feature runs several requests over one connection by putting a 16-byte SMP header in front of each TDS packet. Avoiding a copy forces three things:

- The header and the packet must share a buffer. Each `TLS.sendData` chunk becomes its own record, and hmssql sends each SMP packet as one record.
- The header's sequence number and window are only known under the send lock, because a window must not go backwards on the wire.
- So the header is written after the rest of the packet is finished, which is after the producer has handed it over.

The old sender looked like this. The comment was the whole safety argument:

```haskell
forM_ (zip (iterate (+ 1) (sent + 1)) now) $ \(seqNum, BI.BS fp len) ->
  -- The room is this packet's own (nothing else refers to it yet).
  BI.unsafeWithForeignPtr fp $ \ptr -> pokeSmpHeader ptr SmpData (smpSid smp) len seqNum window
```

The bulk copy producer received `B.ByteString -> IO ()` and an `Int` saying how much room to leave. That contract could be broken in four ways, and the compiler objected to none of them:

| What the producer could do | What would happen |
| --- | --- |
| Leave too little room | The SMP header overwrites the packet's own TDS header |
| Send fewer than 16 bytes | A write past the end of the allocation |
| Send a literal or a shared `ByteString` | Writing into static memory, or changing bytes another holder can see |
| Keep or reuse a buffer after sending it | Corrupted output, since the plain-socket path holds packets in a pending list after `send` returns |

The garbage collector doesn't help with any of this. A `ForeignPtr` keeps the allocation alive, but two aliases of it still see each other's writes, so keeping memory alive doesn't make the mutation legitimate.

The message's framing rules were also only conventions: every packet but the last must be full, because SQL Server resets the connection on a short one, and the last must be marked end-of-message.

Nothing had gone wrong on the wire. Bulk copy was the only producer and it kept every rule. This was a hazard in an exposed internal API, found while cleaning that API up.

## The solution: a packet isn't a ByteString until its last write

The fix is a type distinction: a buffer that still has a write to come is a linear value, and only consuming it produces a `ByteString`. Two small modules hold this, about 320 of the library's 17,800 lines, and they add no dependency.

`Hmssql.Tds.PacketWriter` holds the abstract types, with no constructors exported. A producer now receives a `PacketWriter` and must thread it to the end:

```haskell
writeBytes    :: B.ByteString -> PacketWriter %1 -> IO PacketWriter
finishMessage :: PacketWriter %1 -> IO (Ur ())
packetBytes   :: OwnedPacket %1 -> Ur B.ByteString
smpDataPackets :: Word16 -> Word32 -> Word32 -> [OwnedPacket] %1 -> IO (Ur [B.ByteString])
```

Each buffer is allocated with the 16 bytes of room, so room stops being a promise. `finishMessage` is the only way to consume a writer, so the full-packet and end-of-message rules are now in the types too. The header write is the last thing that happens to the buffer, and what comes back is immutable:

```haskell
smpDataPackets sid window seqNum (OwnedPacket fp len : rest) = L.do
  let total = smpHeaderLength + len
  BI.unsafeWithForeignPtr fp $ \p -> pokeSmpHeader p SmpData sid total seqNum window
  Ur later <- smpDataPackets sid window (seqNum + 1) rest
  L.pure (Ur (BI.BS fp total : later))
```

Three details may be useful to anyone trying the same thing.

**A linear `do` over plain `IO`, not a new monad.** `Hmssql.Tds.Linear` is a set of `QualifiedDo` operators on base's `IO`. Any action without a linear variable in it is already a valid statement, so existing code needs no lifting:

```haskell
loop !i s !out = L.do
  Ur step <- L.ur (S.next s)
  case step of
    Left x -> L.do
      writeIORef after (Just (i, x))
      settled out
    Right (row, s') -> L.do
      Ur cells <- L.ur (either (throwIO . rowProblem i) pure (convert row))
      out' <- writeRow layout cells out
      loop (i + 1) s' out'
```

**Linear values come from continuations.** A plain `x <- allocate` binds `x` as unrestricted, which defeats the point. So the first writer arrives through `runPacketWriter`'s continuation, and each later buffer is allocated by a function that consumes the previous writer. A complete message body uses an unrestricted description instead: `Frames` can be reused freely, and each `takeFrames` call allocates fresh owned buffers, so reusing it shares no storage.

**One `unsafeCoerce` is unavoidable.** A linear bind can't be typed from base's `IO`, because the state token is unrestricted and matching on the unboxed result makes the value unrestricted too. So everything goes through one function that changes only the arrow:

```haskell
unsafeToLinear :: (a -> b) -> (a %1 -> b)
unsafeToLinear = unsafeCoerce

(>>=) :: IO a %1 -> (a %1 -> IO b) %1 -> IO b
(>>=) = unsafeToLinear (\act -> unsafeToLinear (\k -> act P.>>= \a -> k a))
```

This rests on two assumptions. A multiplicity is erased, so both arrows share closures and calling conventions. And each wrapped function really does run its linear argument at most once, which the type checker can't see through the coercion. We test both directly, as the next section describes.

## What it delivered: real guarantees, no bugs found, and a cost we could remove

The conversion turned every misuse in the table above into a compile error, and it caught no actual bug. A test runs `ghc` on 11 forbidden uses, including finishing twice, writing after finishing, dropping a writer, smuggling one out through `Ur`, and keeping a packet in an `IORef`. Each must fail with GHC's multiplicity error, GHC-18872. The test has to run the compiler, because `-fdefer-type-errors` doesn't defer these errors.

No multiplicity error ever pointed at a mistake in the library code, either in the old code or during the port. Bulk copy had kept its contract, and the errors made during the work were caught by ordinary type errors, benchmarks and tests. The value here is prevention, and that is all we can honestly claim.

**What linearity doesn't cover:**

- An exception can leave a linear value unconsumed, so the types rule out a second use, not a lost one. The memory is garbage-collected, so that part is harmless. A message cut short isn't harmless, and the existing machinery still handles it: a producer's exception cancels the request with an Attention, and a failed send breaks the connection.
- `unsafeWriteSized` hands its callback a raw `Ptr`, so the byte count, the bounds and the pointer's lifetime are still trusted. A check after the write catches a wrong count, but it can't undo an out-of-bounds write.
- The kernel module itself is trusted, as any module with a hidden constructor is.

**Testing the coercion.** The tests had to be able to fail with corrupted memory, so we checked them against 19 deliberately broken copies of the two modules. Coercions that change the calling convention crashed with SIGBUS, SIGABRT or SIGSEGV. Wrappers that ran an action twice, or dropped the handler or the lock, failed or hung. Buffer reuse, a missing room and use-after-free showed up as changed bytes. Two mutants hung rather than failed, which still stops the suite but reports nothing useful. One thing we didn't expect: GHC 9.12.4 panics compiling the wrong coercion when it's inlined, so those mutants needed `NOINLINE` to reach the tests at all.

**The performance story is the most useful finding.** The first working version made bulk framing 78% slower, for reasons that had nothing to do with linearity's semantics.

| Stage | Allocated | CPU |
| --- | --- | --- |
| `IORef`s (before) | 180 KB | 57 µs |
| First linear port | 602 KB | 107 µs |
| Layout bound in lambda | 268 KB | 61–64 µs |
| Environment field lazy | 212 KB | 59–60 µs |
| `settled` and a bang | 164 KB | 56.5 µs |

These are from the hmssql benchmark `Encode.bulk`, 1000 rows, framing only, on GHC 9.12.4 and macOS, 2026-10-30. The CPU times are typical of paired runs, and individual runs varied by a few microseconds.

Each step was found by reading the benchmark's allocation column, and then GHC's compiled output:

1. **Bind the layout inside the `Ptr` lambda.** Outside it, the call isn't saturated and the layout becomes a chain of closures.
2. **Make the writer's environment field lazy.** A strict field must be evaluated when the unboxed fields are boxed again, and GHC does that in a thunk.
3. **End loops with `settled`, not `L.pure`, and add a bang.** The loop then takes the writer apart and builds a new one, so GHC passes its fields unboxed.

The result is about 56.5 µs for 1000 rows of framing against about 57 µs for the old `IORef` version, and a 10,000-row load into a local server is no slower. These numbers are from GHC 9.12.4 on macOS. The catch is that none of this is protected: removing one bang compiles fine and quietly brings the allocation back.

**Other costs we paid:**

- `LinearTypes` implies `MonoLocalBinds` from GHC 9.10, which broke unrelated local bindings until those modules set `NoMonoLocalBinds`.
- Up to GHC 9.10, `Ur x <- m` counts as a failable pattern, so the linear `do` needs a `fail` that is never called.
- Linear variables can't cross base's `catch` or `withMVar`, so the kernel needs linear wrappers for both. Everything else in the send path stays ordinary `IO`.

## Why the benefit stops there

Linear types don't remove copies; a different memory layout removes copies, and linear types only make that layout safe when it needs a write after handover. This change added no copy and removed none. We looked for more places in hmssql where that applies, and found none worth converting.

| Where | What happens today | What linear types would add |
| --- | --- | --- |
| Framing a large parameter | One copy into packets: 0.16 ms for 4 MB at 32 KB packets, 0.53 ms at 4 KB, against 6.7 to 11.9 ms for the whole send over TLS | Nothing needed. A saving of 1 to 8% at most, and laying the body out in packets is plain pointer code, which must still finish validating before anything is sent |
| A bulk row that crosses a packet boundary | Encoded into a temporary buffer, then copied across packets | Nothing. The callback needs one contiguous span. A segmented encoder could avoid this copy with no change to ownership |
| Small parameters | 2000 ints take 527 µs and 3.4 MB. The cost looks like allocation per value, not the 4-byte copies (not profiled) | Nothing. Writing values straight through a layout function needs no ownership |
| Reads on a plain socket | Already zero-copy: `recv` goes into an arena, and rows are parsed in place from immutable slices | Nothing to remove |
| Reads over TLS | The `tls` package allocates each record's plaintext. A copy into an arena is deliberate, and cut one 32 MiB read's peak from 370 MB to 160 MB | Nothing. The allocation belongs to `tls`, and the copy is what fixes the memory |
| Copying a value out of a row | Done so a value doesn't keep its whole packet alive | Nothing. It's a retention problem, not a safety one |
| Recycling receive arenas | Not done. Each arena is left to the garbage collector | Doesn't fit. Slices of one arena reach many rows and, under MARS, many sessions, so they'd need reference counts, not one owner |
| A linear `Connection` | One owner is a documented rule, backed by a mutex | Doesn't fit. Every user would need linear `do`, and a connection must survive `timeout`, which abandons linear values |

Three reasons sit behind that table.

**Almost all our memory is finished when it's wrapped.** A `ByteString` built by `unsafeCreate` is complete before anyone sees it, so nobody can observe a half-written one. The SMP header was the only case that needed a write afterwards, and it took a wire format plus a lock to force it.

**Haskell's memory problems here aren't ownership problems.** The worst ones in this library's history are about retention: finalizers keeping pinned blocks alive, and a 32 MiB read leaving 180 MiB live until a second major GC. A slice can't dangle in Haskell, because the collector keeps its buffer alive. The failure is too much memory rather than wrong memory, and linearity says nothing about either a thunk or a pinned block. Our own 78% regression was a thunk and some closures.

**Linearity doesn't survive contact with exceptions.** In a database client, `timeout` and `killThread` are ordinary control flow. An exception skips the rest of a linear chain, so anything that must be released still needs `bracket`. The types can rule out a second use, but they can't promise a release. That is why our guarantee is safe only because the resource is plain memory.

There's also the matter of reach. Linear code stays viable here because it's in four modules out of a whole library, and no user of hmssql ever sees it. Extending it to the value encoders would put `%1` in the signature of anything writing to a buffer, and the hottest paths are tuned closely. The cost section above shows how easily that kind of tuning goes wrong without a compile error.

## Rust: the same goal sounds alike, but the job is different

Rust's borrow checker is prevalent because it does the garbage collector's job, while Haskell's linear types are an optional check added beside a garbage collector. They also check different things, and the [Linear Haskell paper](https://arxiv.org/abs/1710.09756) (section 6.3) calls them dual. Uniqueness is a non-aliasing analysis, while linearity is a cardinality analysis.

| | Rust ownership and borrowing | Haskell linear types |
| --- | --- | --- |
| What it says | By default, this value has one owner, and shared access or mutable access, never both | This function uses its argument once, if its result is used once |
| Attached to | The value and its type | The function arrow |
| Who is constrained | Everyone holding the value | Only the callee |
| Default | On for every non-`Copy` value | Off, and opted into per function |
| Who frees memory | Ownership: the compiler inserts the free | The garbage collector, regardless |
| Using a value less than once | Allowed: it's dropped, and its destructor normally runs | Rejected by the type checker |
| Temporary access | `&` and `&mut`, with lifetimes | None in GHC. The paper only sketches borrowing as future work |

**Why it's everywhere in Rust.** Three things make it unavoidable there:

- **It manages the heap.** The Rust book says the [main purpose of ownership](https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html) "is to manage heap data". Without a collector, every heap value needs an answer to who frees it and when. No Rust program can opt out of that question.
- **Mutation is ordinary.** The [rule of one `&mut` or many `&`](https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html) is how safe Rust rules out dangling references: a slice into a `Vec` can't stay in use across a `push` that might reallocate it (error E0502, checked with rustc 1.99.1). With [`Send` and `Sync`](https://doc.rust-lang.org/book/ch16-04-extensible-concurrency-sync-and-send.html), which govern what crosses threads, it also rules out data races, though not deadlocks. Haskell gets most of that from immutable data, and what's left goes through `MVar` and STM, with no static check of how they're used.
- **Moves would be unbearable without borrows.** The paper's explanation is direct: Rust needs borrowing so much because "unique values are the default". Passing a value to read it would otherwise consume it.

The rule is a default rather than an absolute. [`RefCell`](https://doc.rust-lang.org/book/ch15-05-interior-mutability.html) moves the same check to runtime, where a violation panics, and `Rc` and `Arc` share ownership through a reference count. That's the mirror image of Haskell: Rust opts out of a static default where it must, and Haskell opts in.

**Why it struggles to be relevant in Haskell.** Each of those pressures is already gone, and some of Rust's machinery would fight the language:

- **The collector already prevents the bugs.** Use-after-free and double free don't arise in ordinary Haskell, so a borrow checker would be solving a solved problem for almost every value.
- **Aliasing is free.** Sharing an immutable value is safe and common, and laziness and closures rely on it. Haskell's default is the reverse of Rust's, and the paper says so: non-linear code is the norm, with extra effort spent only where an invariant needs it.
- **Delimited access already exists.** `runST` and the `withForeignPtr` style cover many scoped uses, as the paper notes in section 6.4. They fit our problem less well, because a packet has to travel from a producer through an effectful send path to the lock where its header is chosen. A transferable capability can make that trip more naturally than a scope can.
- **Borrowing has a cost Haskell minds.** The paper points out that a borrow must outlive the call, which rules out tail calls in general. Functional loops depend on those.

**What this felt like in practice.** The same writer in Rust is shorter, because `&mut` means no threading:

```rust
impl PacketWriter {
    fn write_bytes(&mut self, bs: &[u8]) { self.buf.extend_from_slice(bs); }
    fn finish(self) -> Vec<u8> { self.buf }
}
```

The Haskell version threads `out1`, `out2`, `out3` through a qualified `do`. It needed unboxing work to match the performance of the code it replaced, and that work isn't checked by anything. In Rust, calling `write_bytes` after `finish` is rejected (error E0382, checked with rustc 1.99.1), and that is the same class of protection we built.

The closest Rust analogue to sealing a packet is [`BytesMut::freeze`](https://docs.rs/bytes/latest/bytes/struct.BytesMut.html#method.freeze) in the `bytes` crate. It consumes the mutable handle and returns an immutable `Bytes` at zero cost, which is the same move as `packetBytes`. It needs no extra machinery, because a move already consumes the handle.

**Haskell wins on one point, and only on paper.** Rust's move-only types are [affine, not linear](https://faultlore.com/blah/linear-rust/): a writer that is never finished compiles and is simply dropped. Haskell's type checker rejects that, which is how `finishMessage` guarantees a complete message on every path that returns. Rust would need a runtime check in `Drop`. But an exception still abandons the writer in Haskell, and only Rust's unwinding runs cleanup automatically. Real linear types are hard in Rust for that same reason, since panics are [the main problem](https://faultlore.com/blah/linear-rust/) for a must-use type.

**Uniqueness wasn't free in Haskell either.** A linear function can't assume it holds the only pointer, since the paper's own example passes an unrestricted value to one. We got uniqueness by hiding constructors and handing the first writer through a continuation. In Rust, that property comes with every owned value.

## Is it a solution in search of a problem?

From this one case: no, but the problem is narrow, and few programs have it. Our use was exactly what the [2018 paper](https://arxiv.org/abs/1710.09756) proposed: safe in-place update, and enforcing a protocol. Its conclusion says GHC already had the low-level primitives, and that linearity moves the burden of proof from the programmer to the compiler. That's an accurate description of what happened here. Linear types added no capability we lacked, because the old code worked and was just as fast. They replaced a comment with a compile error.

**Linear types seem worth trying when all of these hold:**

- Memory is written after another part of the program has received it, and a copy is too expensive.
- The hazard is worth a compile error: it would corrupt memory or the wire, and tests wouldn't reliably show it.
- The linear code can stay behind a small internal API, so users never have to write `%1`.
- An exception that abandons the value is harmless, as it is for garbage-collected memory, or something else already recovers from it.

Few Haskell libraries will meet all four. The paper's other suggestions look like better fits than most, such as off-heap data, foreign heaps and RDMA, but this case doesn't test them.

**If you try it, here's what we'd pass on:**

- Use `QualifiedDo` over base's `IO` before reaching for a new monad. It kept the change small.
- Hand linear values out through continuations, and hide the constructors. The arrow alone doesn't give you uniqueness.
- Watch the allocation column from the first benchmark. Linear threading turns mutable state into values, and GHC's unboxing of them is easy to lose silently.
- Test the coercion you'll probably need, against mutants that break it.

**What might widen the use.** Three gaps stood out, and we haven't tried to solve any of them:

- **Borrowing.** With no `&mut` equivalent, every step threads a new name. The paper sketches an extension, and it would address the most tedious part.
- **Optimisation.** We saw no speedup from linearity itself, and had to arrange the unboxing by hand. The paper leaves using multiplicities as optimiser input to future work.
- **Support in `base`.** A linear `IO` bind and linear `catch` currently mean writing your own `unsafeCoerce` or adding a dependency. GHC's [user guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/linear_types.html) also still calls the extension experimental.

None of those would make linear types Rust's borrow checker, because the garbage collector would still be doing that job.

**How far to trust this.** It's one library and one change, written up the day it landed, so it says nothing about long-term maintenance. All numbers are from GHC 9.12.4 on macOS, with the type checking and tests also passing on 9.6.6 and 9.14.1. The unboxing was only confirmed on 9.12.4, so it isn't a promise for other compilers. Framing benchmarks exclude the socket and TLS, and the live comparison is only two runs. The full live test suite, the Docker matrix, and the Windows and Azure paths weren't run. hmssql's code was largely written by AI agents under its owner's direction, including this change and this write-up, so a reader should check the code rather than take the claims on trust.

## Sources

- Bernardy, Boespflug, Newton, Peyton Jones and Spiwack, [Linear Haskell: practical linearity in a higher-order polymorphic language](https://arxiv.org/abs/1710.09756), POPL 2018: sections 1, 2, 6.3, 6.4, 7 and 8.
- GHC User's Guide, [Linear types](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/linear_types.html).
- The Rust Programming Language, [What is ownership?](https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html) and [References and borrowing](https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html), [Interior mutability](https://doc.rust-lang.org/book/ch15-05-interior-mutability.html), and [`Send` and `Sync`](https://doc.rust-lang.org/book/ch16-04-extensible-concurrency-sync-and-send.html).
- The `bytes` crate, [`BytesMut`](https://docs.rs/bytes/latest/bytes/struct.BytesMut.html).
- The Rustonomicon, [Leaking](https://doc.rust-lang.org/nomicon/leaking.html).
- Gankra, [The Pain Of Real Linear Types In Rust](https://faultlore.com/blah/linear-rust/).
- hmssql's linear version of 2026-10-30, which is not in the published history: benchmarks, tests and compiled output (STG), all measured that day.
