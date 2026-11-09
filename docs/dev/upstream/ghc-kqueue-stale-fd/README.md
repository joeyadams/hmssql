# GHC kqueue IO manager: stale registration, then a failed `closeFdWith` that wedges the IO manager

Found while testing hmssql on macOS (September 2026). Two GHC defects combine:

* **A. Stale registration** (GHC 9.6 to 9.12; fixed in 9.14). If a thread
  starts to wait on a descriptor (`threadWaitRead`/`threadWaitWrite`) just
  after another thread closed it, the wait fails with EBADF, but the IO
  manager keeps the failed registration in its callback table.
* **B. `closeFdWith` is not exception-safe** (every version checked,
  including 9.14.1 and GHC master). When the kernel later gives that number
  to a new descriptor, `closeFdWith` on it asks kqueue to delete a filter the
  kernel doesn't have, gets ENOENT and throws `kevent: does not exist`. It
  throws before closing the descriptor and before putting back the
  callback-table lock it took for the descriptor's bucket (fd mod 32). The
  descriptor stays open, and every later wait on a descriptor in the same
  bucket blocks forever.

With `network`, the failure is worse: `Network.Socket.close` marks the socket
closed (fd -1) before calling `closeFdWith`, so after the failure nothing,
not even the socket's finalizer, closes the descriptor. It leaks for the life
of the process. (network's documentation says `close` does not throw; here
it does.)

On GHC 9.14 and later, A can no longer occur, so reaching B takes some other
disagreement between the IO manager's table and the kernel. `Minimal2.hs`
closes the descriptor with close(2) behind the IO manager's back. That is
misuse, but it shows that one failed kevent call is enough to leave the IO
manager wedged.

## Environment

| | |
|---|---|
| OS | macOS 15.6.1 (build 24G90), `sw_vers`; Darwin 24.6.0, arm64 (aarch64-apple-darwin) |
| GHC | 9.10.3 from ghcup (`The Glorious Glasgow Haskell Compilation System, version 9.10.3`), `-threaded` |
| Also run with | GHC 9.6.6, 9.8.4, 9.12.2 and 9.14.1 (ghcup bindists; `Minimal.hs` and `Minimal2.hs` only on 9.6.6 and 9.8.4) |
| network | 3.2.8.0 (Stackage `lts-24.45`, which hmssql's `stack.yaml` used at the time) |
| ghc-internal / base | 9.1003.0 / 4.20.2.0 (with GHC 9.10.3) |

## Files

* `Minimal.hs`: A and B with boot packages only (`base`, `unix`). This is the
  repro for the GHC issue.
* `Minimal2.hs`: B alone, reproducible on GHC 9.14.1. The stale registration
  comes from close(2) behind the IO manager's back.
* `Kev.hs`: the original repro with `network` sockets, the same scenario as
  `Minimal2.hs`, via `Network.Socket.close`.
* `Kev2.hs`: A and B through `network` (`Socket.close`, then
  `threadWaitWrite` on the closed descriptor). It also checks that
  `shutdown` wakes a thread blocked in `sendAll` on a full socket (Unix
  socket pair and TCP loopback), which is what hmssql's `close` relies
  on (see "Workarounds in hmssql").

## Build and run

From the repository root. `-threaded` is required: the non-threaded RTS
doesn't use the event manager.

```sh
ghc -threaded -package unix -outputdir /tmp/minimal.o docs/dev/upstream/ghc-kqueue-stale-fd/Minimal.hs -o /tmp/minimal && /tmp/minimal
ghc -threaded -package unix -outputdir /tmp/minimal2.o docs/dev/upstream/ghc-kqueue-stale-fd/Minimal2.hs -o /tmp/minimal2 && /tmp/minimal2
stack exec --package network -- ghc -threaded -outputdir /tmp/kev1.o docs/dev/upstream/ghc-kqueue-stale-fd/Kev.hs -o /tmp/kev1 && /tmp/kev1
stack exec --package network -- ghc -threaded -outputdir /tmp/kev2.o docs/dev/upstream/ghc-kqueue-stale-fd/Kev2.hs -o /tmp/kev2 && /tmp/kev2
```

(For another GHC, use `ghc-9.14.1` etc. in place of `ghc`.) Each program
finishes within a few seconds. A hang is caught by a 2-second `timeout` and
reported.

## Observed output

These results were deterministic: each program was run at least three times
on the machine above, with the same output every time.

`Minimal.hs`, GHC 9.6.6, 9.8.4, 9.10.3 and 9.12.2:

```
1. threadWaitWrite on the closed fd 13: Left kevent: invalid argument (Bad file descriptor)
2. closeFdWith on the fd's next owner: Left kevent: does not exist (No such file or directory)
   fd 13 still open afterwards: True
3. threadWaitRead on readable fd 45 (same bucket): timed out after 2 s (blocked on the bucket lock)
```

`Minimal.hs`, GHC 9.14.1 (A is fixed, so B doesn't arise here):

```
1. threadWaitWrite on the closed fd 13: Left kevent: invalid argument (Bad file descriptor)
2. closeFdWith on the fd's next owner: Right ()
   fd 13 still open afterwards: False
3. threadWaitRead on readable fd 45 (same bucket): returned
```

`Minimal2.hs`, GHC 9.6.6, 9.8.4, 9.10.3, 9.12.2 and 9.14.1 (identical):

```
1. closeFdWith: Left kevent: does not exist (No such file or directory)
   fd 12 still open afterwards: True
2. threadWaitRead on readable fd 44 (same bucket): timed out after 2 s (blocked on the bucket lock)
```

`Kev.hs`, GHC 9.10.3, network 3.2.8.0:

```
Socket.close: Left kevent: does not exist (No such file or directory)
fd 12 still open after the failed close: True
wait on fd 44 (same stripe): HUNG (stripe poisoned)
```

`Kev2.hs`, GHC 9.10.3, network 3.2.8.0:

```
threadWaitWrite on the closed fd: Left kevent: invalid argument (Bad file descriptor)
Socket.close of the fd's next owner: Left kevent: does not exist (No such file or directory)
sender after shutdown: Just (Left Network.Socket.sendBuf: resource vanished (Broken pipe))
TCP sender after shutdown: Just (Left Network.Socket.sendBuf: resource vanished (Broken pipe))
```

### On Linux (epoll)

The same two defects are in the epoll backend. `Minimal.hs` and
`Minimal2.hs`, built with `ghc-<ver> -threaded -package unix` and run on
Ubuntu (kernel 6.8, x86_64) on 2026-10-25, give the macOS results with
epoll's messages, the same on 9.6.6, 9.8.4, 9.10.3 and 9.12.4:

```
1. threadWaitWrite on the closed fd 14: Left modifyFdOnce: invalid argument (Bad file descriptor)
2. closeFdWith on the fd's next owner: Left epollControl: does not exist (No such file or directory)
   fd 14 still open afterwards: True
3. threadWaitRead on readable fd 46 (same bucket): timed out after 2 s (blocked on the bucket lock)
```

On 9.14.1 `Minimal.hs` gives `Right ()`, `False` and `returned`, as on
macOS, and `Minimal2.hs` still wedges the bucket. The descriptor numbers
differ by one or two between versions. In hmssql's test suite this is
how the live tests hung for hours in the test matrix (GHC 9.6.6): a mock
server closed a socket under its own reader, and a later connection to
SQL Server was given a descriptor in the wedged bucket
(`docs/dev/bugs-found.md`, "In the test suite").

## Expected output

* `threadWaitWrite`/`threadWaitRead` on a closed descriptor fails with EBADF
  and leaves no trace in the IO manager (as on 9.14.1).
* `closeFdWith` closes the descriptor. If the backend fails to remove a
  registration the kernel no longer has, that is harmless and should be
  ignored or at least not stop the close. Either way, the callback-table
  locks are put back.
* A wait on another descriptor that happens to share the bucket is not
  affected: `threadWaitRead` on a readable descriptor returns at once.

## Analysis

Sources: the hyperlinked sources shipped with the ghcup bindists
(`~/.ghcup/ghc/<ver>/share/doc/ghc-<ver>/html/libraries/ghc-internal-*/src/`)
for 9.10.3, 9.12.2 and 9.14.1. GHC master was read from the GitHub mirror
(`github.com/ghc/ghc`, `master`) on 2026-09-25. In the GHC tree, the modules
are `libraries/ghc-internal/src/GHC/Internal/Event/{Manager.hs,Thread.hs,KQueue.hsc}`.
Before 9.10, the same code was in `base` as `GHC.Event.*`. Line numbers
are omitted because the hyperlinked sources are post-CPP/hsc2hs.

* **Buckets.** `GHC.Internal.Event.Manager`: each event manager (one per
  capability with `-threaded`) has `callbackArraySize = 32` callback tables,
  each an `MVar (IntTable [FdData])`; `hashFd fd = fromIntegral fd .&.
  (callbackArraySize - 1)`, and `callbackTableVar mgr fd` selects the one
  for `fd`. On Darwin, `haveOneShot = False`, so every registration goes
  through `I.modifyFd` (EV_ADD/EV_DELETE) rather than `modifyFdOnce`.

* **A: `registerFd_`** (`GHC.Internal.Event.Manager`), called from
  `threadWait` in `GHC.Internal.Event.Thread`. Under `withMVar
  (callbackTableVar mgr fd)`, it first inserts the new `FdData` into the
  table (`IT.insertWith`), then calls the backend. It undoes the insert
  (`IT.reset fd' oldFdd tbl`) only when the backend *returns* `False`. The
  kqueue backend's `kqueueControl` (`GHC.Internal.Event.KQueue`) returns
  `True` for EINTR and `False` for EINVAL and ENOTSUP, and for any other
  errno calls `throwErrno "kevent"`. EV_ADD on a closed descriptor fails
  with EBADF, so it throws (`kevent: invalid argument (Bad file
  descriptor)`, since `errnoToIOError` maps EBADF to `InvalidArgument`). The
  exception leaves `withMVar` with the insert in place: the table now says
  the number is registered for writing, and the kernel has no such filter.

  Fixed on master and in 9.14 by commit `69960230cc2c04a8b554ae8b7ebb85626749bf45`
  ("Handle exceptions from IO manager backend", 2024-10-10, referencing
  #21969). It wraps the backend calls in `` `onException` undoRegistration ``.
  The installed 9.10.3 and 9.12.2 sources do not have it, and `Minimal.hs`
  reproduces A on both, and on 9.6.6 and 9.8.4 (where the code is in `base`).

* **B: `closeFdWith`** (`GHC.Internal.Event.Thread`). Inside
  `uninterruptibleMask_`, it `takeMVar`s the callback table for `fd` from
  every event manager, then runs
  `cbApps <- zipWithM (\mgr table -> M.closeFd_ mgr table fd) mgrs tables`
  and then `` close fd `finally` sequence_ (zipWith3 finish mgrs tables cbApps) ``,
  where `finish` puts the table back. Only `close fd` is protected by the
  `finally`. `closeFd_` (`GHC.Internal.Event.Manager`) deletes the entry
  (`IT.delete`) and, when it had events, calls `I.modifyFd ... oldEvs
  mempty` (EV_DELETE). For a filter the kernel doesn't have, kevent fails
  with ENOENT, `kqueueControl` throws `kevent: does not exist`, and
  `closeFdWith` exits with:
  * the descriptor not closed (`close fd` never ran);
  * the taken `MVar`s never put back, so the bucket `fd mod 32` is locked
    for good in every event manager. The next `registerFd_`,
    `unregisterFd_`, `closeFdWith` or `threadWait*` on any descriptor in
    that bucket blocks forever: an `uninterruptibleMask_`'d `takeMVar` in
    `closeFdWith`, an interruptible `withMVar` elsewhere;
  * the callbacks of the deleted registrations never run. A thread blocked
    in `threadWait` on the old descriptor is never woken (`Kev.hs`'s and
    `Minimal2.hs`'s waiter threads never print).

  Master's `closeFdWith`, `closeFd_` and `kqueueControl` are the same as in
  9.10.3 (read on 2026-09-25), and `Minimal2.hs` reproduces B on 9.14.1.
  The epoll backend behaves the same ("On Linux (epoll)", above).

* **network.** `Network.Socket.close` (network 3.2.8.0,
  `Network.Socket.Types`) is `invalidateSocket s (\_ -> return ()) $ \oldfd
  -> closeFdWith closeFd (toFd oldfd)`: `invalidateSocket` swaps the fd for
  -1 first, so when `closeFdWith` throws, the socket is already marked
  closed and its finalizer won't close the descriptor either.

**How A arises in real code.** One thread closes a socket while another is
in network's send (or receive) loop: that thread got the descriptor before
the close, its `send` fails with EAGAIN, and it calls `threadWaitWrite` on
the number just after the close. That is the race hmssql had. See below.

## Impact on hmssql

Seen once, in the `connect` stress test during a full-suite run on macOS.
`connect`'s cleanup after a timeout closed its socket, got `kevent: does not
exist`, and:

* the `IOException` replaced the `Timeout` that `connect` should have thrown;
* the socket's descriptor stayed open for the rest of the process (network
  had already marked it closed);
* the bucket lock stayed taken, so any later wait on a descriptor with the
  same number mod 32 would hang. In a long-running process, that means
  random connections hanging forever.

The stale registration came from hmssql's own `close`. When `close` ran
while another thread was sending on the connection, it closed the socket to
interrupt the send, which is exactly the race described above.

## Workarounds in hmssql

* **A socket close that fails no longer replaces `connect`'s exception or
  leaks the descriptor.** Every cleanup-time close (`connect`'s failure
  paths, `close`, the goodbye's cleanup, and the finalizer of a connection
  dropped without `close`) goes through `closeSocket` in
  `Hmssql.Connection.Backend`. It runs masked and throws no
  synchronous exception. If `Socket.close` failed after marking the socket
  closed, it closes the descriptor directly with close(2), not through
  `closeFdWith` again, which would block on the lock the failed call left
  taken. This limits the damage: the right exception, and no descriptor
  leak. It can't release the bucket lock.
* **`close` no longer closes the socket under a thread that is sending on
  it.** It calls `shutdown(SHUT_RDWR)` on the socket,
  which makes a blocked send fail at once with EPIPE (`Kev2.hs` checks this
  for Unix and TCP sockets), and closes it only once the sender has released
  the send lock. The reader thread was already stopped before the close.
  hmssql therefore no longer waits on a descriptor it may have closed, so it
  doesn't create the stale registration itself. Other code in the same
  process still can on GHC < 9.14.

## Draft GHC issue

**Title:** `closeFdWith` leaves the fd open and its callback-table lock taken when the kqueue backend throws (`kevent: does not exist`)

**Body:**

> ## Summary
>
> On macOS (kqueue IO manager), if `closeFdWith` finds a registration for
> the fd in the event manager's table that the kernel no longer has, the
> backend's EV_DELETE fails with ENOENT and `kqueueControl` throws
> `kevent: does not exist`. `closeFdWith` then exits without closing the fd
> and without putting back the callback-table `MVar`s it took. Every later
> `threadWaitRead`/`threadWaitWrite`/`closeFdWith` on any fd in the same
> bucket (`fd .&. 31`) blocks forever.
>
> Before 9.14, such a stale registration arises from ordinary use:
> `threadWaitWrite` on an fd another thread has just closed (a
> `Network.Socket.close` racing a `send` is enough) fails with EBADF but
> leaves the registration in the table. That part was fixed by 69960230
> ("Handle exceptions from IO manager backend", #21969), which has not been
> included in 9.10.3 or 9.12.2 (A also reproduces on 9.6.6 and 9.8.4). The `closeFdWith` part
> remains on 9.14.1 and master, and any other disagreement between the
> table and the kernel still triggers it.
>
> ## Reproduction (boot packages only, `ghc -threaded -package unix`)
>
> ```haskell
> -- Minimal2.hs: reproduces on 9.6.6, 9.8.4, 9.10.3, 9.12.2, 9.14.1
> import Control.Concurrent
> import Control.Exception
> import Foreign.C.Types (CInt (..))
> import GHC.Conc (closeFdWith)
> import System.IO.Error (tryIOError)
> import System.Posix.IO
> import System.Posix.Types (Fd (..))
> import System.Timeout (timeout)
>
> foreign import ccall unsafe "close" c_close :: CInt -> IO CInt
>
> main :: IO ()
> main = do
>   (r1, _w1) <- createPipe
>   (r2, _w2) <- createPipe
>   _ <- forkIO $ do
>     x <- try (threadWaitRead r1)
>     putStrLn ("   waiter: " ++ show (x :: Either SomeException ()))
>   threadDelay 100000
>   let Fd n = r1
>   _ <- c_close n            -- kernel drops the filter; the table keeps it
>   _ <- dupTo r2 r1          -- the number now names another pipe
>   closeFd r2
>   c <- tryIOError (closeFdWith closeFd r1)
>   putStrLn ("1. closeFdWith: " ++ show c)
>   open <- tryIOError (queryFdOption r1 CloseOnExec)
>   putStrLn ("   fd " ++ show r1 ++ " still open afterwards: " ++ show (either (const False) (const True) open))
>   (r3, w3) <- createPipe
>   let fd = r1 + 32          -- same bucket
>   _ <- dupTo r3 fd
>   _ <- fdWrite w3 "x"
>   t <- timeout 2000000 (threadWaitRead fd)
>   putStrLn ("2. threadWaitRead on readable fd " ++ show fd ++ " (same bucket): "
>             ++ maybe "timed out after 2 s" (const "returned") t)
> ```
>
> The close(2) behind the IO manager's back only stands in for the stale
> registration. On 9.10/9.12, the same result comes from legitimate calls
> alone: `closeFdWith closeFd w`, then `threadWaitWrite w` (fails with
> EBADF, leaves the registration), then `dupTo` another fd onto `w`, then
> `closeFdWith closeFd w`.
>
> Observed (macOS 15.6.1 arm64; GHC 9.10.3, 9.12.2, 9.14.1):
>
> ```
> 1. closeFdWith: Left kevent: does not exist (No such file or directory)
>    fd 12 still open afterwards: True
> 2. threadWaitRead on readable fd 44 (same bucket): timed out after 2 s
> ```
>
> The waiter thread is never woken either.
>
> Expected: `closeFdWith` closes the fd and releases the table locks even if
> the backend fails. The wait on fd 44 returns at once.
>
> ## Cause
>
> In `GHC.Internal.Event.Thread.closeFdWith`, the calls
> `M.closeFd_ mgr table fd` (which call `I.modifyFd ... mempty`, i.e.
> EV_DELETE) run after the `takeMVar`s but outside the
> `` close fd `finally` sequence_ (zipWith3 finish mgrs tables cbApps) ``
> that puts the tables back. An exception from the backend skips both the
> close and the `putMVar`s. `GHC.Internal.Event.KQueue.kqueueControl`
> throws for any errno other than EINTR/EINVAL/ENOTSUP, including ENOENT
> from EV_DELETE of a filter that is already gone.
>
> ## Possible fixes
>
> 1. Make `closeFdWith` exception-safe: run the `closeFd_` calls so that an
>    exception from one still closes the fd, puts every table back, and runs
>    the callbacks (with `evtClose`), then rethrow or drop the error.
> 2. When a deregistration fails because the filter is already gone
>    (ENOENT from an EV_DELETE-only change list), treat it as success, since
>    that is the state being asked for.
>
> Found through hmssql (a SQL Server client). Details and the network-based
> repros: <link to docs/dev/upstream/ghc-kqueue-stale-fd in the hmssql repository>.

Before filing, search the GHC tracker for an existing report, and check the
current state of #21969 and whether 69960230 was backported to 9.10/9.12.
The tracker (gitlab.haskell.org) couldn't be read from here.
