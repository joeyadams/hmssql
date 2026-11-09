# Documentation: where things go, and in which voice

The voice rules are in the root `CLAUDE.md` ("English voice"), and so is
the index of where each area is documented and the checklist to run after
a change ("Where to look before changing an area", "Cleaning up after a
change"). This file has the details of the layout.

## The two sections

* `guide/` is for people using hmssql: nineteen short pages in seven
  sections, one folder per section (`getting-started/`, `queries/`,
  `writing-data/`, `streaming/`, `decoders-and-encoders/`,
  `errors-and-security/` and `under-the-hood/`). `guide/README.md` is the
  contents page; its nested list is the tree the HTML site shows, and the
  order of the pages in it is the reading order, which the site's Previous
  and Next links follow across section boundaries. Pages are named by
  topic, without numbers. New text there is in the user voice. A page is
  short, starts with the thing the reader needs, and may end with a brief
  "How it works" section. Add a section to the right page before adding a
  page; a new page goes in the folder of its section and into the contents
  page at its place in the reading order, and nothing else lists it.
* The guide is plain Markdown, and `site/build.sh` turns it into the HTML
  site with the Haddock under `api/`; "The HTML site" below has the
  details. The site relies on three things the guide does anyway: links
  between pages are relative `.md` links, a code span holding exactly a
  name or module hmssql exports (`` `withTransaction` ``,
  `` `Hmssql.BulkCopy` ``) links to its Haddock, and each page's headings
  give the anchors, as on GitHub. Pages carry no footers or navigation of
  their own, and the build fails on a broken link or anchor.
* `dev/` is for people working on hmssql, in the developer voice.
  `dev/README.md` indexes it, one row per document. The documents are by
  area, not by feature or by session: a feature adds to the sections of
  its area in each document. The one document per topic is the research
  record (`dev/mars-research.md`, `dev/windows-research.md`,
  `dev/value-streaming-research.md` and `dev/performance-research.md`),
  and the one folder per topic is an upstream bug report with its repro
  (`dev/upstream/`). `dev/review-checklist.md` is how to review a change. `dev/linear-types.md` is an exception the owner made,
  a write-up for the Haskell community rather than part of the project's
  memory.

## The HTML site

`site/build.sh` builds the guide and hmssql's Haddock into `_site/`, a
static site with no server side, and `site/build.sh --publish REMOTE`
force-pushes it as the one commit of the remote's `gh-pages` branch, which
GitHub Pages serves. It always holds the latest build: there is one
version, and the hosted Haddock is for reviewing hmssql before it is on
Hackage, so it comes off the site once Hackage has it. The whole build
takes about fifteen seconds once Stack has built the dependencies' docs.

* `site/generator` is a small Haskell program with its own `stack.yaml`, so
  it never enters a package of the project. It parses the Markdown with cmark-gfm and
  renders the HTML itself, because cmark-gfm can't render a table it
  didn't parse, and because the code blocks need highlighting of their
  own. `Highlight.hs` lexes Haskell, SQL and YAML so that a Haskell name
  hmssql exports links to its Haddock. A highlighting library would have cost
  minutes of compile time and given no way to add the links.
* The names come from the `doc-index.json` that Haddock writes for its
  quick-jump search. A code span links only when its text is exactly a
  name, a qualified name or a module, so SQL keywords and type names such
  as `varchar` stay plain. A name exported from several modules links to
  the module of its topic before the umbrella `Hmssql`, then to the
  `Hmssql.Tds` modules, then to the internal ones. A name in a code block
  links only to the public modules, because a short name there, such as
  `parse`, is more often a local binding than a reference. A name from another
  package, such as `Text`, links to Hackage at the version hmssql was built
  against. The build prints the code spans that look like names and link
  nowhere, so a renamed function the guide still mentions shows up there.
* The sidebar is the README's contents list, the Previous and Next links
  follow its order, and the README itself is the home page. Links to
  anything else in the repository go to GitHub at
  `https://github.com/<github>/blob/main/...`, with `github` from
  `hmssql/package.yaml`. The anchors follow GitHub's rules, so a link with an
  anchor works the same on GitHub and on the site.
* The search is `site/assets/guide.js`, over an index the generator writes
  as `assets/search-index.js`: each section of each page with its heading,
  prose and code, and every name in the Haddock. It loads when the search
  box is first used, and it is a script rather than JSON so that the site
  works from `file://` too.
* The colors follow the reader's light or dark preference, through
  `prefers-color-scheme`, in the guide (`site/assets/guide.css`) and in
  the Haddock (`site/haddock/hmssql.css` over Haddock's Linuwial theme,
  and `site/haddock/source.css` for the hyperlinked source). There is no
  switch on the page.
* The Haddock never links to the guide. Someone reading it on Hackage
  shouldn't be sent to another site, so the guide links to the Haddock
  and not back, and the build doesn't add one to the Haddock's pages
  either.

## Placement

* A new behaviour decision goes in `dev/design.md`, in the section for its
  area, with the alternative it rejected. The design document is the
  contract; the Haddock and the guide follow it.
* A server or protocol fact, as measured, goes in `dev/protocol-notes.md`,
  with the conditions it was measured under.
* A gap or an unsupported feature goes in `dev/limitations.md`, with its
  workaround and whether it is planned. Planned work goes in
  `dev/backlog.md`; done work is removed from it.
* A bug found and fixed goes in `dev/bugs-found.md`, by area, with cause
  and fix.
* The findings of a research spike or a set of probes go in one
  `dev/<topic>-research.md`: the questions asked, how they were measured,
  the answers with their numbers and their conditions, what the
  implementation then did differently, and what stays unverified. The
  server facts go into `dev/protocol-notes.md` as well. The write-up of
  each probe, the plan written from them and the reports of a review are
  working documents: their decisions go into `dev/design.md`, their
  defects into `dev/bugs-found.md`, and the documents themselves stay out
  of `docs/`. A plan that a session runs from can be a card at the repo root
  for a while (root `CLAUDE.md`, "Cards at the repo root").
* `dev/history.md` is the lineage and who-did-what; keep new work out of
  it beyond a line in its timeline. `dev/development.md` records how the AI sessions and reviews went:
  one row per session, and a paragraph for an incident or a lesson.
* `hmssql/ChangeLog.md` stays one entry, "0.1.0 (unreleased)".
* Don't create working-notes files (a running questions file, a findings
  file). Fold the content into the documents above.
* Measurements are kept as tables in the research record, not as raw
  dumps (JSON, CSV or logs) under `docs/`. A script under `scripts/` that
  regenerates them is better than the dump.
* Commit hashes of this repository aren't references: the history is
  squashed before a release. Say what the state was and when.

## Conventions

* Edit in place. A document describes the current state of hmssql. When a
  statement is superseded, rewrite it; don't add "since implemented",
  "update" or "previously" banners above it. The history of a decision is
  in `dev/development.md` and in git.
* Links are relative Markdown links, and the link text names the file or
  says what it is. When a document moves, rewrite the links to it and the
  texts of those links together, and check anchors.
* The Haskell examples in `README.md` and the guide are run against the
  live test database by `hmssql-tests/DocExamplesSpec.hs`, adapted to `#temp`
  tables. Keep them runnable, and update the spec when an example changes.
* Dates are absolute (2026-09-30), not "today" or "last week".
* Server facts are stated for the server they were measured on (SQL Server
  2025 on Linux, or Azure SQL Database); say when something differs.
* The documents aren't shipped with the package. The library has a folder
  of its own, `hmssql/`, whose only document is `ChangeLog.md`, so a new
  document under `docs/` needs no change to `hmssql/package.yaml`.
