# Reviewing a change

How to review a change to hmssql, whatever its shape: one fix with a
reproduction and a reason, a feature such as table-valued parameters
written in a long session with an agent, or a round of hardening that
someone needed and ran unattended. The method is the same. Learn the
contract from the documents as they are *before* the change, read the
diff against that contract, and test every doubt against the server
rather than argue it. The contributor's own account of the change,
whether a pull request description, the commit messages or the
documents the change rewrote, is read after the contract, not instead
of it.

## Read first, at the base commit

Read these in the version the change starts from, so that the change's
account of itself doesn't set the expectations it is reviewed against:

* `CLAUDE.md`: the index of areas, "Design decisions not to reopen",
  "Cleaning up after a change" and "English voice".
* `docs/dev/design.md`, the sections of every area the diff touches
  (the index in `CLAUDE.md` names them). Each decision there carries
  the alternative it rejected; a change that picks the rejected
  alternative is reopening the decision.
* `docs/dev/limitations.md`, whole: what hmssql doesn't do on purpose,
  with the reason. A fix of something listed there is a decision, not a
  bug fix, and a feature listed there as not planned needs the use case
  the entry asks for.
* `docs/dev/backlog.md`, whole: what is planned, which says what a
  feature was expected to look like, and "Checks to revisit", which
  records what was seen once and not explained.
* `docs/dev/bugs-found.md` and `docs/dev/protocol-notes.md`, the
  sections of the areas touched: what went wrong before, and what the
  server was measured to do.
* The research record of the area, if it has one
  (`docs/dev/mars-research.md`, `windows-research.md`,
  `value-streaming-research.md` or `performance-research.md`): what was
  tried and rejected, with the numbers, which a change may be about to
  try again.
* `hmssql-tests/CLAUDE.md`, `docs/CLAUDE.md` and the suite map in
  `docs/dev/testing.md`: the rules the tests and documents must keep.

Then survey the change: the commit list, the diff by file, which files
are library, tests, scripts and documents, and for the library every
behaviour that changed, each as one line. The review is of those lines.
A round of many small changes is reviewed as that many changes; a
feature is one change with many parts, reviewed as a whole as well.

## What kind of change it is

Each kind has a question that comes before the rest.

**A fix.** Is there a reproduction, and is it a test in the suite? Does
the fix address the cause the reproduction shows, or the symptom? Is the
behaviour it changes a documented one, in which case the document is
changed in the same diff and the decision reopened with a reason? A fix
that comes with a business case says what went wrong for whom; that is
the reason to keep, in `bugs-found.md`, not the fix itself.

**A feature.** Is it on the backlog, and does it match what the backlog
entry described, or is it in `limitations.md` as not planned, and if so
has the case for it been made? Does it fit the design: no new dependency
without a reason in `design.md`, the `Query` and `Request` style of API,
one owner per connection, errors found before anything is sent? Does it
cover its whole class (every type of a family, MARS as well as plain
connections, Azure as well as SQL Server, the RPC path as well as bulk
copy, the decoder as well as the encoder), or does it say in
`limitations.md` what it leaves out? Is it tested under the matrix's
configurations, and is the server fact it relies on recorded in
`protocol-notes.md` with the server it was measured on? A feature
written with an agent tends to be complete in the easy direction and
thin in the other, and to arrive with documents that describe the
session rather than the behaviour; both are checked below.

**A hardening round.** What was the threat, and is it one this library
faces? A client library's attacker is a hostile or broken server, or
untrusted input reaching a query; a check against anything else costs
every caller for nothing. Does each check refuse only what would be
lost or wrong, or also what the server accepts? Is each one placed off
the hot paths? A round made of many unattended sessions is also where
findings about one machine get written up as facts about the server;
see the questions on contradictions and on the runner's machine.

## The questions, change by change

**Does it reopen a tradeoff?** A deliberate tradeoff has a known
downside, and a fix of that downside reintroduces the other side of it.
Examples of tradeoffs in `design.md`: an interrupted drain breaks the
connection rather than resuming; `timeout` around a request leaves a
transaction in the state the drain finds, not a guaranteed one; sends
run under plain `mask_`; `reset` is a lazy flag; an untyped NULL is
`nvarchar(max)`; a `Double` into a `decimal` column is rounded on the
client. A change on any of these needs a reason that answers the
rejected alternative in `design.md`, and the paragraph there rewritten.
Without that, reject it.

**Does it introduce a problem of its own?** Read each change for what it
does to the inputs it wasn't written for: the other sign, the empty
value, NULL, the `(max)` form, the fixed-length form, a value on the
other side of a boundary, the MARS connection, a packet boundary. A fix
that moves a failure from one input to another is not a fix.

**Is it validation the server doesn't need?** A check that refuses what
SQL Server accepts, and that any client (including hmssql's own
decoders) reads back without trouble, makes calls fail for no gain.
Keep a check that prevents a real, silent loss: a value stored as `?`,
a truncation, a NULL where a value was given, a wrong column. Drop a
check that merely finds the input unusual. The test for a kept check
must show the neighbouring valid inputs still pass.

**Is it complete?** A fix for one case of a class, and not the class:
fixed for the negative sign and not the positive, for bulk copy and not
the RPC parameter, for the named row and not the positional, for one
type of a family and not the others, for the plain connection and not
MARS. Ask what the class is, and look at every member. A change that
adopts a new rule in one place and keeps the old one next to it (exact
arithmetic with the old rounding, say) is the usual shape of this.

**Does it contradict an earlier measurement?** A finding that reverses a
fact in `protocol-notes.md`, `limitations.md` or a test's comment is not
wrong for that, but it is the first thing to retest, since one of the
two was measured on a different server, a different machine or a flaky
test. Retest on the local server, and if it holds, rewrite the earlier
statement in place.

**Could the finding be the runner's machine?** A hang, a timing, a
network behaviour or a crash seen on one machine may be that machine.
The account of such a finding says what was ruled out and what wasn't,
and names the machine; one that presents it as the server's or the
library's behaviour without that is overstated, whatever it turns out
to be. `Connection.Disconnect`'s hang after a `KILL`, seen from one Mac
(`backlog.md`, "Checks to revisit"), is the example.

**Does it cost in a hot path?** Anything per row, per cell, per packet
or per byte sent is a hot path (`design.md`, "Reading and writing
bytes: which layer"). A check or a conversion added there to cover an
unlikely input is paid by every row. So is code inlined into every
module that names a row type. Measure the change against its base with
`scripts/perf-compare.sh`, which compares code size and time
(`docs/dev/testing.md`, "Measuring a change" and "Comparing two
commits"), and read the Core where the benchmarks don't reach.

**Is it tested, and is the test a test?** Every behaviour change has a
test that fails without it. The test's expectation comes from somewhere
independent of the code under test: the server's own conversion of the
same value, a literal, exact arithmetic. A test that compares the
library with itself, or that passes with the change reverted, is not
evidence. Check the rules in `hmssql-tests/CLAUDE.md`: no timing widened, no
`KILL` by id, an `MVar` where two things must be ordered, a scratch
database only when the database itself changes.

**Is the code where it belongs, and is it explained?** A function goes
in the module of its area, and a test in the module of its area, named
for what it tests and not for the session or the campaign that wrote
it. A comment says what the code does and why, in the developer voice.
If the commit message explains and the code doesn't, put the explanation
in the code. If what a change is, where it belongs or how it should be
organised can't be told, reject it rather than guess.

**Are the documents right, and in the right place?** Run the "Cleaning
up after a change" list in `CLAUDE.md` in reverse: for each change,
find its paragraph in `design.md` (a decision), `protocol-notes.md` (a
server fact, with the server it was measured on), `limitations.md` (a
gap), `backlog.md` (removed when done), `bugs-found.md` (a bug, with
cause and fix), the research record of its area (a measurement of a
spike or a probe), `testing.md` (a run's results and what it
established), the Haddock and the guide. A paragraph in the wrong
document is moved; a test narrative in `protocol-notes.md` or
`design.md` is cut; a "previously" or "existing" banner is rewritten.
`hmssql/ChangeLog.md` stays one entry describing the release, not a log of the
change. No plan, report, checklist of the work, working notes, run
manifest or credentials go in the tree, apart from a card at the repo
root on a local branch, and no absolute path of a developer's machine
and no commit hash of this repository, which the release's squash
erases.

**Is the voice right?** The rules in `CLAUDE.md`, "English voice":
conjunctions kept, lists with their "and" or "or", no list inside a
list, no clipped pairs, the jargon kept and no baby words. Prose that
reads as a sequence of claims ("Protect X. Preserve Y. Retain Z.") is
rewritten into sentences that say what hmssql does and why.

**Does it build the way the repository builds?** A package's
`package.yaml` edited and `hpack` run in its folder; a new test module discovered; formatting as the
neighbours; no new dependency without a reason in `design.md`; the
examples and the guide's examples still run (`DocExamplesSpec`).

## Test what is doubted

An argument about what the server does is settled by asking the server.
For each doubt, write the smallest test that would fail if the doubt is
right, in the module of its area, and run it on the local server
(`source ~/.hmssql-test-env`; `stack test --ta '--match /Area/'`), plain
and with `HMSSQL_TEST_MARS=1` where the path differs. Then run the
whole suite without the slow tests at the head of the change, since a
contributor who ran selected modules has not shown the rest still
passes; for a feature, the matrix configurations it touches as well.
Keep the tests that found something, as regressions, and record the
server facts they measured in `protocol-notes.md`.

## Report

For each change, one of: accept; accept with the document or code
change named; retest, with what to run; reject, with the reason. Lead
with what must not merge, then what is wrong, then what is untidy. A
review worth recording gets a row in `development.md`; its defects go
in `bugs-found.md`, and the report itself stays out of the tree.
