# GHC's native I/O manager on Windows: a crash with a few dozen busy sockets

Found while making hmssql work under WinIO with network 3.3 (2026-10-03).
Not reported upstream yet. A fix is on the GHC branch
`wip/winio-completion-packets` (2026-11-07), not yet submitted: see
"Upstream status".

With the native I/O manager (`+RTS --io-manager=native`) and network's
calls going through it, a program that has a few dozen sockets busy at
once crashes with an access violation inside the manager's handling of
completions. 32 connections crashed it in every run, 24 in most, and 16
in none. The default I/O manager is not affected.

hmssql met it on a path that sent its own socket and pipe operations
through the manager's `withOverlapped`. One group of its test suite,
64 connections each sending and receiving 64 KiB over MARS and TLS,
crashed in most runs, at
`GHC.Internal.Event.Windows.$wprocessCompletion`. The repro here uses
none of hmssql: network's `recv` and `sendAll` are enough.

## Environment

| | |
|---|---|
| OS | Windows 10 Pro 10.0.19045, x86_64, in a QEMU virtual machine with 16 logical processors |
| GHC | 9.12.4.20260713 (the third release candidate of 9.12.5), a ghcup bindist, `-threaded` |
| network | 3.3.0.0, from its repository at `7868459` (2026-09), with the change of its pull request 628 applied so that it builds |

It reproduces as well with GHC master `20334e1d1f` (2026-11-06) and
network master `1f6aa85` (3.3.0.0, 2026-11-04, with the same change),
on another Windows 10 machine.

network's code for the manager is compiled only when GHC defines
`__IO_MANAGER_WINIO__ >= 2`, which no release did by 2026-11-07: GHC
9.12.4 and 9.14.1 define 1. So the repro needs a pre-release of 9.12.5 or
of 9.14.2, or GHC master.

## Files

* `ManyConnections.hs`: a loopback echo server and N clients in one
  process, with network's own calls. On each client connection one
  thread receives all the time and another sends all the time, 100
  messages of 65,537 bytes, so that every socket has a read and a write
  in progress.

## Build and run

With a GHC and a network as above (`cabal` or `stack` with network 3.3
as a dependency):

```sh
ghc -O1 -threaded -rtsopts "-with-rtsopts=-N" docs/dev/upstream/ghc-winio-many-connections/ManyConnections.hs -o many-connections.exe
./many-connections.exe 32 100 65537 +RTS --io-manager=native -RTS
./many-connections.exe 64 100 65537
```

## Observed output

Five runs at each count under the native manager, and three under the
default one:

| I/O manager | Connections | Runs that crashed | Runs that completed |
|---|---|---|---|
| native | 16 | 0 | 5 |
| native | 24 | 4 | 1 |
| native | 32 | 5 | 0 |
| native | 64 | 5 | 0 |
| default | 64 | 0 | 3 |

With GHC master and network master, 32 connections crashed in 5 runs of
5 under the native manager, 16 in none of 2, and none crashed under the
default manager.

A crashing run prints this and exits with status 11:

```
I/O manager: winio (native)

Access violation in generated code when reading 0xffffffffffffffff

 Attempting to reconstruct a stack trace...

   Frame	Code address
 * 0x2fae6fda30	0x7ff6ebf20212 ...\many-connections.exe+0x70212
```

The address read was `0xffffffffffffffff` in three runs of four and a
heap address in the fourth. The code address was the same in all four,
and `llvm-nm` puts it in `stg_deRefStablePtrzh`, ten bytes in. In
hmssql's test binary the same crash was at
`GHC.Internal.Event.Windows.$wprocessCompletion`, 0x5a7 bytes in.

Other observations, one run each: it crashed with 64 connections and
messages of 1,000 bytes, with `-N4`, and with `-N1`. A version of the
probe that called the manager's `withOverlapped` directly, with
`ReadFile` and `WriteFile` or with `WSARecv` and `WSASend`, crashed the
same way. A lighter pattern did not crash: 64 connections that each sent
a message and then waited for its echo, 300 times, ran three times
without a fault.

## Expected output

```
I/O manager: winio (native)
32 connections, 100 messages of 65537 bytes each, all echoed: 0 connections failed
```

## Analysis

The manager dereferences a stable pointer that it takes from the
completed operation's data, and that pointer is invalid. The cause was
found in GHC's source in November 2026: completion packets that outlived
their requests. So the fault is GHC's, not network's. The threshold
between 16 and 32 connections, each with two or three operations in
progress, would fit something that happens once about 64 operations are
outstanding at a time, which is a supposition.

## What hmssql does

hmssql met this first on a path of its own through the manager, which
was removed for it in October 2026. Since November 2026, under the
native manager with network 3.3 or later and a GHC that defines
`__IO_MANAGER_WINIO__` as 2 or more, hmssql's TCP goes through network's
own calls and its Shared Memory and Named Pipes through the manager
([design.md](../../design.md#platform-workarounds)). So hmssql has this
exposure there, as every user of network's sockets does: its test suite
over MARS crashed this way in three runs of four with GHC master of
2026-11-06, and over plain TCP in none of three. Everywhere else hmssql
does its own overlapped I/O, whose completions stay off the manager's
port.

A program that uses network's `recv` and `send` under the native manager
on many connections has this exposure in its own code.

## Upstream status

Not reported. The repro needs only GHC and network, so it can go into an
issue as it is.

A fix is on the GHC branch `wip/winio-completion-packets` (commits
`73e9beb738` and `16069bfc8c` on master `20334e1d1f`, 2026-11-07), with
fixes for other faults of the manager, not yet submitted. With it,
hmssql's test suite ran 21 times threaded under the native manager, 12
of them over MARS, with no crash. This repro's own result on the branch
was not recorded.
