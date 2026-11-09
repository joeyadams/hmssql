# GHC's native I/O manager on Windows: a thread killed during a file read may never end

Found while making hmssql work under WinIO (2026-10-03). Not reported
upstream yet, and no existing GHC issue was found for it. The GHC branch
`wip/winio-completion-packets` (2026-11-07) changes the wait that the
analysis below suspects: see "Upstream status".

With the native I/O manager (`+RTS --io-manager=native`), a Haskell
thread that receives an asynchronous exception while it is inside a file
read sometimes never comes back. `killThread` returns, and the target
never ends: it stays blocked in a foreign call for good. About 1 kill in
100 of those that came before the read had finished did this. The
default I/O manager is not affected.

hmssql met it in `connect`. With TLS, every connect reads the CA
certificate files named in `tlsCaCertificateFiles`, and a `timeout` or a
`killThread` that landed in that read left the connecting thread stuck.
Two tests of `Concurrency.Close`, which kill connects at random points,
hung in every run of their group under the native manager with strict
encryption, and in none without TLS.

## Environment

| | |
|---|---|
| OS | Windows 10 Pro 10.0.19045, x86_64, in a QEMU virtual machine with 16 logical processors |
| GHC | 9.12.4, and 9.12.4.20260713 (the third release candidate of 9.12.5), ghcup bindists, `-threaded` |
| Libraries | base and bytestring as shipped with each compiler |

## Files

* `KilledRead.hs`: the repro. Sixteen threads each read a small file
  with `Data.ByteString.readFile`, 1,000 times each, every read on a
  thread of its own that is killed 0 to 3,000 µs after it starts. A
  watchdog reports a reader that has not ended 10 s after it was killed,
  with its `threadStatus`.

## Build and run

From the repository root, with any small file as the argument (the runs
below read a certificate of 1,158 bytes):

```sh
ghc -O1 -threaded -rtsopts "-with-rtsopts=-N" -outputdir killed-read.o docs/dev/upstream/ghc-winio-file-read/KilledRead.hs -o killed-read.exe
./killed-read.exe some-small-file +RTS --io-manager=native -RTS
./killed-read.exe some-small-file
```

## Observed output

One run of each, 16,000 reads apiece:

| GHC | I/O manager | Readers killed in time, and ended | Readers that finished first | Readers that never ended |
|---|---|---|---|---|
| 9.12.4.20260713 | native | 3,174 | 12,795 | 31 |
| 9.12.4.20260713 | default | 10,566 | 5,434 | 0 |
| 9.12.4 | native | 3,684 | 12,283 | 33 |
| 9.12.4 | default | 10,933 | 5,067 | 0 |

Under the native manager the program prints a line for each stuck
reader, and then never exits, since the stuck threads' parents wait for
them:

```
thread 2, round 497: the killed reader has not ended after 10 s (ThreadBlocked BlockedOnForeignCall)
thread 4, round 496: the killed reader has not ended after 10 s (ThreadBlocked BlockedOnForeignCall)
...
16 threads x 1000 rounds: 3174 readers were killed in time and ended, 12795 finished first, 31 never ended
```

A first version of the repro killed each reader within 400 µs. No reader
got as far as its read by then, every kill ended its thread, and nothing
hung. The hang needs the kill to land later, in the read itself or in
what follows it.

## Expected output

```
16 threads x 1000 rounds: N readers were killed in time and ended, M finished first, 0 never ended
```

## Analysis

Not established: the stuck thread's stack was not read, because the
machine has no debugger. What is known:

* The thread's status is `BlockedOnForeignCall`, so it is inside a safe
  foreign call, and it stays there.
* It happens only under the native manager, where a file read is an
  overlapped operation that the manager waits for, and where an
  exception during that wait makes the manager cancel the operation and
  wait for the cancellation.
* Interrupting network's `recv` on a socket under the same manager
  (network 3.3.0.0, 4,800 interruptions from 16 threads) never hung. So
  it is not every interrupted wait.

A supposition, not checked against this repro: the manager's
cancellation waits for the cancelled operation with a blocking call on
the file handle, and for a file that wait is not always released.
Reading GHC's source in November 2026 found that the manager does wait
for a cancelled request in a blocking `GetOverlappedResult`, a safe
foreign call, and that this wait was what froze the non-threaded runtime
when a pending socket receive was killed and its socket closed. That fits
the stuck thread's status here.

## Workaround in hmssql

The certificate files are read under `uninterruptibleMask_` on Windows
(`buildCertificateStore` in `Hmssql.Connection.Tls`), so no exception
arrives during the read. The read is short, and on other platforms a
regular file's read can't be interrupted either. It is the only file
hmssql reads ([design.md](../../design.md#platform-workarounds)). Its
socket and pipe operations go through the manager when it is built
against network 3.3 with a GHC that defines `__IO_MANAGER_WINIO__` as 2,
and they were not seen to hang this way: network's receive was
interrupted 4,800 times from 16 threads, and a pipe read 1,000 times on
the GHC branch below and 300 times on GHC master, and every one
returned.

A program that reads files with `timeout` or `killThread` around the
read, under the native manager, has the same exposure in its own code.

## Upstream status

Not reported. The repro needs nothing but GHC, so it can go into a GHC
issue as it is.

The GHC branch `wip/winio-completion-packets` (commits `73e9beb738` and
`16069bfc8c` on master `20334e1d1f`, 2026-11-07), not yet submitted,
cancels an interrupted request with `CancelIoEx` and waits for it
uninterruptibly on the `MVar` the manager fills when the completion
arrives, in place of the blocking `GetOverlappedResult`. That fixed the
freeze of the non-threaded runtime, and the branch has fixes for other
faults of the manager as well. This repro's result on the branch was not
recorded, so whether it fixes this hang is not known.
