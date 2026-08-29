# Changelog

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
