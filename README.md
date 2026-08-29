# Arbor

Arbor is a native macOS Git workbench. It combines a SwiftUI interface with a
Rust Git engine for status, staging, history graphs, branch
operations, conflict resolution, rebase, remotes, and hosting integrations.

## Build and test

Requirements: macOS 14+, Xcode command-line tools, Rust stable, and `cargo`.

```sh
cargo test --manifest-path arbor-engine/Cargo.toml
xcodebuild -project Arbor/Arbor.xcodeproj -scheme Arbor \
  -destination 'platform=macOS' test
```

For a local artifact, use `scripts/release.sh 1.0.0`. The default output is
explicitly unsigned and arm64; signing and notarization require the external
Apple Developer credentials described in [RELEASE.md](RELEASE.md). A universal
archive additionally requires an x86_64 Rust static library and can be selected
with `ARBOR_ARCHS="arm64 x86_64"`.

## Diagnostics and privacy

Arbor writes a small, structured rolling diagnostic log under
`~/Library/Logs/Arbor/`. It records operation names, repository basenames,
versions, and error codes—not access tokens, credential-bearing remote URLs,
commit messages, or file contents. Logs are exported only after the user
chooses a destination.

The release target is MIT-licensed. Third-party dependency license status is
tracked separately in [DEPENDENCY_LICENSES.md](DEPENDENCY_LICENSES.md) and
must be reviewed before a public release.
