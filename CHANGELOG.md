# Changelog

## Unreleased

Commit layout: the window no longer empties out while committing.

- Commit mode kept its change list on the left and replaced the rest of the
  window with an empty placeholder. The Log editor now stays in the centre, the
  same way the reference application keeps history visible while committing,
  and the Project tool window starts expanded below the Commit surface
- The Log now loads whenever it is on screen instead of only in Log mode, so
  branch, tag, commit and push operations refresh it from the Commit surface
  too
- The project tree rendered hardcoded Chinese ("项目", "项目文件", "重试", the
  empty-project and error states) inside an English interface; those strings
  are catalog keys with zh-Hans translations now
- The left tool-window column was 386 pt wide at a 1642 pt window. It is now
  628 pt (52 rail + 564 panel + 12 divider), the exact figure measured from
  the reference window, with the details inspector widened to 460 pt so the
  commit actions and the changes browser stop clipping
- The selected Log row now carries the accessibility "selected" trait and a
  localized label, so VoiceOver announces the current commit and automation
  can tell an already-selected row from a dead one

UI correctness: clicks that changed nothing now fail a test instead of shipping.

- Added `ui-smoke/`: an XCUITest suite that clicks every visible control on the
  Commit workbench, Log workbench, project tree, branches popover and Settings,
  and requires an observable change. A control that reacts with nothing is a
  `DEAD` failure, with the coordinate and a screenshot. Runs locally with
  `./scripts/ui-smoke.sh` and in CI via `.github/workflows/ui-smoke.yml`
- Toolbar icon buttons exposed their SF Symbol name as the accessibility label
  (`Arrow Down Circle`, `Selected`), so VoiceOver read the icon instead of the
  action and the controls could not be addressed by name. Update, Commit, Push,
  Fetch, Refresh and Search now carry explicit labels
- Operation Log "Clear" stayed enabled when the only remaining entry was the
  running operation, which `clearHistory()` deliberately keeps: the button was
  clickable and did nothing. It is now disabled when there is nothing to remove
- The commit inspector, Operation Log, Git Console, tasks view and Operations
  picker rendered hardcoded Chinese inside an English interface (commit
  metadata, action buttons, empty states). They now use catalog keys with
  `zh-Hans` translations
- Commit action feedback no longer infers success by string-prefix matching on
  a Chinese message; the level travels with the message
- `scripts/i18n-audit.py --only-hardcoded` records the remaining Chinese
  literals in `scripts/i18n-hardcoded-baseline.txt` and fails on new ones, so
  the count can only go down

## 1.0.23 - 2026-10-22

Performance release: keep worktrees with large change lists responsive. A
sampled 1.0.22 run on a big repository showed the main thread spending most of
its time inside SwiftUI layout while the window kept every changed file
materialized as a row, and the Log Changes tree rebuilt and re-sorted itself on
every body evaluation.

- The Commit panel change list is now a lazy stack: rows, checkboxes, drag
  sources and context menus are only built for the visible range, so a worktree
  with thousands of edits no longer allocates a view per file (measured with
  2,000 changes: 1.4 GB footprint and 65% CPU before, 363 MB and 0% after)
- Change rows no longer resolve their name and parent folder through
  `URL(fileURLWithPath:)`, which ran a `getcwd` syscall for every row of every
  render and displayed the checkout's absolute prefix (`/Users/you/repo/dir`)
  instead of the repository-relative folder
- The change tree rows are memoized against the status snapshot and the
  grouping mode instead of being re-sorted and rebuilt on every body evaluation
- The Log Changes tree sorts each directory once instead of on every insert,
  and its context-menu selection snapshot is computed once per render instead
  of once per row; a 4,080-file commit now scrolls in 0.48s instead of 2.46s
- The Project tool window resolves a file or directory status from a
  per-snapshot index instead of scanning every changed entry for every visible
  row, and file icons no longer resolve relative names against the working
  directory
- New unit tests pin the project-tree status aggregation rules (a conflict
  wins, otherwise the first notable kind)

## 1.0.22 - 2026-10-21

Performance release: keep the VCS Log usable on large histories. A sampled
run on a big repository showed the main thread spending most of its time in
SwiftUI layout and equality checks while the process footprint grew to tens of
gigabytes, because the commit graph was rebuilt and fully re-laid-out on every
UI update.

- The LinearBek graph model is now memoized outside the SwiftUI body and only
  rebuilt when the commit list or the collapse state actually changes, instead
  of on every hover, selection, and scroll tick; commit-list change detection
  uses a copy-on-write buffer fast path and no longer maps and compares the
  whole ID list on each body evaluation
- The graph Canvas and the edge/node hit-target overlays only cover the visible
  rows plus a buffer window rather than the entire history, so hovering no
  longer re-strokes every edge and SwiftUI no longer creates one hit-target
  view per graph edge and node in the repository
- Collapse/expand actions are pre-resolved per row during the graph build,
  which replaces an O(rows x fragments) scan on every render; `visibleEdges`
  is materialized once instead of being refiltered on every access
- Commit rows no longer receive the whole graph model, and the workspace split
  view hosts stop reporting intrinsic sizes so divider drags no longer repeat
  full SwiftUI layout inside AppKit constraint updates
- Root-qualified commit identity is passed as a flag instead of a generic
  closure; new unit tests cover graph cache reuse, invalidation, identity, and
  stale merge action pruning

## 1.0.21 - 2026-10-21

Feature release: wire the dormant "自动检查更新" toggle to real GitHub
release checks. The toggle previously had no backing implementation, so an
installed release could never learn that a newer version existed without
manually browsing the Releases page.

- AppUpdateChecker: read-only `releases/latest` GET, numeric tag comparison
  against the running `CFBundleShortVersionString`, and at most one automatic
  check per 24h per install, eight seconds after the first window appears
- Update availability is surfaced through the existing feedback center with a
  one-click "打开下载页" action; the automatic path stays silent on failures
- New "检查更新…" application-menu item and a settings row with an instant
  re-check; the toggle now defaults to enabled
- Update checks never run under XCTest hosts; tag comparison, payload
  parsing, and the 24-hour window are covered by unit tests

## 1.0.20 - 2026-10-21

Patch release: stop the repository watcher from retriggering its own refresh.
`git status` creates `.git/index.lock` to refresh stat data; the file watcher
reported that transient lock as a metadata change, so the refresh that ran the
status produced the event that scheduled the next refresh. An idle repository
therefore kept the app at roughly 65-70% CPU with a full SwiftUI re-layout
twice per second.

- Run read-only status queries with `GIT_OPTIONAL_LOCKS=0` so they cannot write
  the index (worktree status, ignored-path expansion, conflict probes, and
  nested submodule checks)
- Ignore transient Git metadata lock files (`*.lock`) in the repository file
  watcher as a fallback for external Git versions
- Add a command-environment unit test and watcher tests for the contract

## 1.0.19 - 2026-10-21

Feature release: complete the Git LFS integration (track, status marking,
fetch/pull/push/prune/checkout with cancellation and credential-broker
authentication), add a Git hooks manager, and make the branches popup
resizable. The codebase was restructured into feature directories with the
workspace state extracted into observable models; behavior is covered by the
full Swift and Rust test suites.

- Git LFS: capability probe, tracked patterns, file list, per-path downloads,
  pointer badges in the changes list, download button in the file viewer,
  push coverage warning when hooks are missing, and network commands routed
  through the credential broker
- Git hooks manager: list, enable/disable, edit, install sample, delete,
  honoring `core.hooksPath`; non-executable hooks are now ignored like Git
  does instead of failing the commit
- Branches popup: drag-to-resize with per-project persistence and
  "Restore Default Size"
- Maintenance: feature-directory restructure, workspace state models, dead and
  duplicated code removal, and a pull stash restore fix that now uses the
  captured preservation message

## 1.0.18 - 2026-08-31

V1 patch release: align the Git workbench with the JetBrains Git workflow
audit, including hosting review details, conflict actions, changelists, Shelf
storage, blame actions, and multi-root recovery. The local launcher now falls
back to an unsigned Debug build when no signing identity is configured.

## 1.0.17 - 2026-08-30

V1 patch release: publish the About window that explains Arbor's Git
workbench purpose and links to the open-source repository, with version,
platform, architecture, and license details.

## 1.0.16 - 2026-08-30

V1 patch release: add an About window that explains Arbor's Git workbench
purpose and links to the open-source repository, with version, platform,
architecture, and license details.

## 1.0.15 - 2026-08-30

V1 patch release: use lexical parent traversal while compacting normalized
dirty scopes, avoiding repeated Foundation URL walks on older macOS runners.

## 1.0.14 - 2026-08-29

V1 patch release: simplify the dirty-scope folder-promotion fast path to
avoid Set hashing and closure traversal on older Swift runtimes.

## 1.0.13 - 2026-08-29

V1 patch release: keep the large single-directory dirty-scope fast path free
of Foundation URL normalization until after its lexical checks, avoiding an
Xcode 15.4 macOS Runner stall.

## 1.0.12 - 2026-08-29

V1 patch release: remove a redundant 50,001-file stress fixture that could
stall the Xcode 15.4 macOS release runner; the 30-file folder-promotion test
already covers the behavior under test. The release job now also has a
45-minute timeout so a future runner stall fails visibly instead of hanging.

## 1.0.11 - 2026-08-29

V1 patch release: avoid per-path URL normalization before promoting large
single-directory filesystem event batches on older macOS runners.

## 1.0.10 - 2026-08-29

V1 patch release: bound large single-directory filesystem event batches before
the general dirty-scope ancestor walk, keeping macOS 14 CI responsive.

## 1.0.9 - 2026-08-29

V1 patch release: make asynchronous Swift captures explicit so the Xcode 15.4
release runner accepts the workspace operations target.

## 1.0.8 - 2026-08-29

V1 patch release: keep the Xcode 15.4 test target compatible with Swift's
trailing-comma parsing rules.

## 1.0.7 - 2026-08-29

V1 patch release: restore Xcode 15.4 compatibility for graph traversal and
signature loading concurrency.

## 1.0.6 - 2026-08-29

V1 patch release: restore Xcode 15.4 compatibility for the macOS release
workflow and keep the generated project, notification handling, and release
metadata buildable from a clean clone.

## 1.0.5 - 2026-08-29

V1 patch release: generate an Xcode 15-compatible project so the public macOS
release workflow can build and test on its Xcode 15.4 runner.

## 1.0.4 - 2026-08-29

V1 patch release: make the merge-preserving rebase regression test inspect
the rewritten history from the current HEAD instead of retaining old branch
refs in the lookup.

## 1.0.3 - 2026-08-29

V1 patch release: ensure nested submodule clones inherit the repository's
effective SSH command, and make the cancellation regression fixture wait for
the SSH process to start before cancelling it.

## 1.0.2 - 2026-08-29

V1 patch release: make test repositories use an explicit `main` initial
branch, repair the golden bare-remote clone fixture, and make tag pruning
explicit with Git's `--prune --prune-tags` options.

## 1.0.1 - 2026-08-29

V1 patch release: make the push rejection regression test independent of the
host Git default branch so the release workflow is reproducible on CI.

## 1.0.0 - 2026-08-29

Arbor V1 is the first release-ready native macOS Git workbench built with a
Rust engine and SwiftUI client.

Highlights:

- Git status, staging, partial staging, three-way conflict resolution, merge,
  rebase, cherry-pick, revert, reset, uncommit, and history editing.
- Branches, tags, worktrees, remotes, fetch/pull/push, protected-branch
  checks, credential prompts, SSH settings, and GPG/pinentry support.
- Shelf, Stash, Recently Deleted, local changelists, imported patches, and
  conflict-safe local-change preservation with retry/recovery actions.
- Multi-root projects with root-qualified operations, nested submodules,
  hosting permalinks, and GitHub/GitLab/Bitbucket pull request and issue
  integration.
- English and Simplified Chinese UI, diagnostics export, and local unsigned
  archive generation.

V1 intentionally does not claim IntelliJ-native DataContext, VFS/PSI,
DialogWrapper, VcsNotifier, Swing/UI automation, plugin-platform, or remote
development lifecycle parity. Those boundaries are recorded in the parity
report and matrix.
