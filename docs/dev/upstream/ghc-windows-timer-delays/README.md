# GHC's default I/O manager on Windows: timers stall when many pending delays expire

Found while running hmssql's test suite against SQL Server 2019 on
Windows (2026-10-08). Not reported upstream yet.

With the threaded runtime and the default I/O manager on Windows, a
program that has tens of thousands of `threadDelay`s pending fires no
timer for seconds at a time once those delays begin to expire. Every
`threadDelay`, `registerDelay` and `System.Timeout.timeout` in the
process is late by that much. The native I/O manager
(`+RTS --io-manager=native`) is not affected.

A delay need not be waited for to count. `System.Timeout.timeout` forks
a thread that sleeps in one `threadDelay` and kills it when the action
returns, but the delay stays pending until its time comes: the manager
has no way to withdraw one. So a program that calls `timeout` with a
long limit around many short actions builds up the same pending delays
as one with that many sleeping threads.

hmssql met it in its test suite. The model tests wait for each of about
9,700 operations under a `timeout` of 15 seconds, and the mock SMP server
sends each packet under one of 20 seconds. Later in the run, a test
whose own `timeout` of 200 ms had to fire while the server waited one
second failed in 9 whole-suite runs of 12, because the timeout did not
fire within the second. In the failing runs two more `threadDelay`s
beside it, of 50 ms and 200 ms, did not return within that second
either, while a bound thread that slept in a foreign call kept its
20 ms ticks, and at every tick `IOManagerThread` was running. The repro
here uses none of hmssql.

## Environment

| | |
|---|---|
| OS | Windows 10 Pro 10.0.19045, x86_64, 32 logical processors |
| GHC | 9.12.4, a Stack installation, `-threaded`, `-N` |

## Files

* `ManyDelays.hs`: forks threads at a steady rate, each of which sleeps
  in one `threadDelay`, and meanwhile times a `threadDelay` of 200 ms
  again and again. The forking is paced by the clock, so it doesn't
  depend on a timer itself.

## Build and run

```sh
ghc -O1 -threaded -rtsopts "-with-rtsopts=-N" docs/dev/upstream/ghc-windows-timer-delays/ManyDelays.hs -o many-delays.exe
./many-delays.exe 10000 3 8      # 10,000 threads a second, each sleeping 3 s, for 8 s
./many-delays.exe 10000 3 8 +RTS --io-manager=native -RTS
```

## Observed output

With 10,000 threads a second that each sleep 3 seconds, the 200 ms delay
is on time until the first of them expire, and then is not:

```
at   2.8 s,   28015 delays started: a 200 ms delay took    200 ms
at   3.0 s,   30176 delays started: a 200 ms delay took    216 ms
at   4.1 s,   41113 delays started: a 200 ms delay took   1094 ms
at  10.8 s,  107669 delays started: a 200 ms delay took   6656 ms
```

One run of each:

| I/O manager | Threads a second | Each sleeps | Pending at most | The longest 200 ms delay |
|---|---|---|---|---|
| default | 10,000 | 3 s | 30,000 | 6,757 ms |
| default | 2,000 | 15 s | 30,000 | 4,919 ms |
| default | 2,000 | 3 s | 6,000 | 214 ms |
| default | 1,000 | 15 s | 15,000 | 210 ms |
| default | 1,000 | 3 s | 3,000 | 204 ms |
| native | 10,000 | 3 s | 30,000 | 202 ms |

While nothing expires, the count of pending delays does no harm: with
20,000 threads a second that each sleep 20 seconds, the 200 ms delay was
on time for 12 seconds, with 245,000 delays pending.

## Expected output

Every line within a few milliseconds of 200 ms, as under the native
manager.

## Analysis

The default manager's timer thread (`service_loop` in
`GHC.Internal.Conc.POSIX`, which is the Windows code despite its name)
keeps the pending delays in a list sorted by time. It adds new ones with
`foldr insertDelay old new`, an insertion sort that is lazy: an
insertion costs nothing until the list is read up to the place the new
delay belongs. Only the head of the list is read, to find the next
delay to fire, so the insertions of every delay that belongs further
back are left as a stack of suspended calls over the tail. When the
head expires and is taken off, each of those suspended insertions has to
take one more step before the next head is known. Taking one delay off
therefore costs about as many steps as there are later delays, and a run
of expiring delays costs the square of their number. The thread does
nothing else meanwhile, and no timer fires. This reading of the source
fits the measurements, but was not checked with a profile.

In the standalone program the stall needs about 30,000 pending delays.
In hmssql's test suite it came with fewer: the five helpers that were
counted had started about 13,000 timeouts by then, and the rest of the
suite's were not counted. There the timer thread shares the processors
with sixteen tests and the collector.

## What hmssql does

The library uses no timer of its own for a request, so nothing in it
adds to the pending delays. Its test suite's helpers that wait for each
operation or each packet use `timeoutInSlices` (`hmssql-tests/Compat.hs`), whose
forked thread sleeps 50 ms at a time on Windows, so that a call that
returns leaves a delay of at most that behind. With it the test that
failed passed in seven whole-suite runs of seven.

An application on Windows that calls `timeout` around every query is
exposed in the same way, once the product of its request rate and its
limit reaches the tens of thousands
([limitations.md](../../limitations.md#windows)).
