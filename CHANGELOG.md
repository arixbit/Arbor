# Changelog

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
