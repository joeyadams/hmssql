# The test suite

`hmssql-tests` is an hspec suite found by hspec-discover: every
`hmssql-tests/**/*Spec.hs` exporting `spec` runs under its module name (`Wire`,
`Query`, `Types.Decimal`, `Mars.Cancel`). `docs/dev/testing.md` documents
the environment variables, the helpers, the suite map and the methods.

## Running

* Without `HMSSQL_TEST_PASSWORD`, the pure and mock tests run and the live
  ones are skipped. `source ~/.hmssql-test-env` first for a live run; the
  file is the developer's and its presence is permission to use the local
  server. If it is missing, ask rather than dig for the password.
* `HMSSQL_TEST_MARS=1` gives every test connection `connectMars = True`.
  A test whose statement differs under MARS says so with `testMars`, and a
  test of something MARS doesn't have asks for a plain connection.
* `HMSSQL_TEST_SLOW=1` includes the slow tests; `HMSSQL_TEST_KNOWN_BUGS=1`
  runs the tests pending on a known bug (`knownBug`);
  `HMSSQL_TEST_PROPERTY_SCALE` multiplies every property's case count.
  Property counts come from hspec's `maxSuccess`, not hedgehog's
  `withTests`.
* Concurrent runs from several worktrees are safe. When several agents
  edit test modules in one tree, none of them may run `stack build` or
  `stack test`; type-check instead with `stack exec -- ghc -fno-code -itest
  <default-extensions> File.hs`.

## Writing tests

* A test of usage that the library no longer supports states the
  consequence (the exception, the abandoned stream), rather than being
  deleted.
* Fix a test that flakes under load by synchronizing on an event (an
  `MVar` handoff), never by widening a timing. Reproduce load with `yes >
  /dev/null` at twice the core count while looping the built binary
  (`.stack-work/dist/.../hmssql-tests --match '/Area.'`), copied to the
  scratch directory first so a rebuild doesn't change it mid-loop. Kill
  only your own `yes`.
* A test doesn't assume how fast one thing goes beside another, such as
  commits beside reads: a commit waits for the disk, 5 ms on the Linux
  machine. A reader that has to race with writers waits for a change to
  be committed (`MarsTx.SnapshotSpec`'s `withWriters`).
* A test that compares two readings of the live heap keeps what the
  process loaded once alive at both, or the difference includes it: the
  system certificate store's cache (2.6 MB) dies after the last `connect`
  a process can reach. To measure what values keep alive, use
  `Resources.Helpers.keptAliveByEach`, and connect once more afterwards.
  A reading kept for later is evaluated first: an unevaluated
  `gcdetails_live_bytes (gc s)` keeps the whole `RTSStats` record, which
  showed as 1.2 KB of growth a reading in `Resources.StalledServer`.
* A thread a test forks catches every exception (`try @SomeException`)
  and hands it to the test, and the test waits for it on every exit: an
  exception that escapes a forked thread is printed as "Uncaught
  exception" and fails nothing.  A thread that loops until it is killed
  is the exception: a `try @SomeException` inside its loop catches the
  `killThread` too, and the thread goes on for the rest of the process.
  Such a loop rethrows `SomeAsyncException`, and the test checks that the
  thread ended (`Concurrency.CancelModel`'s window poller).
* A hedgehog property that talks to the server runs through
  `LiveProperty.liveHedgehog`, not hspec-hedgehog's `hedgehog`, so that
  a failure the server caused can't make hedgehog try every smaller case
  ([bugs-found.md](../docs/dev/bugs-found.md#in-the-test-suite)).
* A helper that waits under a long limit for each operation, message or
  packet uses `Compat.timeoutInSlices`, not `timeout`. On Windows a
  `timeout` that returns leaves its delay pending until the limit
  passes, and thousands of those stall every timer in the process when
  they expire (`docs/dev/upstream/ghc-windows-timer-delays`). A test's
  own `timeout` around a call to hmssql stays `timeout`.
* A test `KILL`s a session only through `killSession` (`TestConfig`), never
  by its id alone: once the session ends, its id goes to the next session,
  another test's or the killer's own.
* A test of what locks do (a reader that waits behind a writer, or holds a
  shared lock) reads `WITH (READCOMMITTEDLOCK)`: Azure SQL Database has
  `READ_COMMITTED_SNAPSHOT` on, where a plain READ COMMITTED reader takes
  no locks.
* A mock test that waits for the client to close must accept a TCP reset
  as the close: `isResourceVanishedError` counts (see
  `hmssql-tests/Concurrency/Mock.hs`).
* Read a thread's label with `Resources.Helpers.threadLabelOf`, never
  `GHC.Conc.threadLabel`: on an unlabelled thread it can crash the process
  in the garbage collector (GHC #27618). `length <$> listThreads` keeps an
  unevaluated thunk of every `ThreadId`, which looks like a thread leak.
* New performance measurements go in `hmssql-bench/Bench/<Area>.hs`, not in hspec
  tests. A benchmark that guards a fixed regression states the old numbers
  in its module comment.
* A live test with a time bound writes as little as its check needs. On
  Azure SQL Database under the whole suite the log rate is the limit: an
  `UPDATE` of 30,000 rows waited up to 42 s in `LOG_RATE_GOVERNOR`, where
  one row took 0.2 s ([protocol-notes.md](../docs/dev/protocol-notes.md#azure-sql-database)).
* Prefer the shared database, with `#temp` tables, `uniqueName` objects or
  a `withScratchSchema`, over a scratch database. A test that needs a
  second database or SNAPSHOT isolation uses the companion database
  (`companionConnectInfo`), with unique names there too. A scratch database
  is only for a test that changes the database itself: on Azure SQL each
  one takes 25 to 60 s.

## Triage

* For a SIGSEGV, read the crash report's `procPath` and parent first: a
  binary under `/private/tmp/*/hmssql-tests` with a Python parent is a
  mutation-testing mutant, not shipped code. Reproduce with a small
  allocation area (`+RTS -A64k -N4`); a `-debug` build in a separate
  `--work-dir` gives RTS symbols; lldb can't attach here.
* For a run that hangs with threads `BlockedOnMVar` and sockets in
  CLOSE-WAIT with bytes unread, check for a wedged bucket of GHC's IO
  manager (before 9.14): the stuck descriptors share their number mod 32
  and are in no epoll set (`/proc/PID/fdinfo` of the eventpoll
  descriptors). Some code in the process closed a socket under a thread
  starting to wait on it, usually a mock
  ([protocol-notes.md](../docs/dev/protocol-notes.md#platform-and-tooling)).
* Known timing bounds that miss under heavy load (`Cancel` "a timeout
  returns promptly") are left alone.
