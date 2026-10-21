# Changelog

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
