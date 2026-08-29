# Arbor

Arbor is a native macOS Git workbench. It combines a SwiftUI interface with a
Rust Git engine for status, staging, history graphs, branch
operations, conflict resolution, rebase, remotes, and hosting integrations.

## Build and test

Requirements: macOS 14+, Xcode command-line tools, Rust stable, `cargo`, and
`xcodegen` (`brew install xcodegen`).

The checked-in source of truth is `Arbor/project.yml`. The build scripts
generate the Xcode project and the matching UniFFI Swift bindings in ignored
generated directories, so a clean clone remains reproducible without
committing machine-generated files.

```sh
cargo test --manifest-path arbor-engine/Cargo.toml
cargo build --manifest-path arbor-engine/Cargo.toml --release
./scripts/generate-swift-bindings.sh
./scripts/generate-xcode-project.sh
xcodebuild -project Arbor/Arbor.xcodeproj -scheme Arbor \
  -destination 'platform=macOS' test
```

For a local artifact, use `ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.0`. The
default output is explicitly unsigned and arm64; signing and notarization
require the external Apple Developer credentials described in
[RELEASE.md](RELEASE.md).

## Download and install

Download packages from the repository's [Releases](https://github.com/arixbit/Arbor/releases)
page. The automated tag workflow currently publishes an arm64 **unsigned QA**
DMG and ZIP named `Arbor-VERSION-unsigned-arm64.*`. These packages are for
Apple Silicon (arm64) and macOS 14 or later only. Intel users currently need
to build a universal archive themselves; an Intel package is not published.
These packages are for testing only and are not Apple-trusted production releases. Verify the
published `SHA256SUMS` before opening an artifact, then drag `Arbor.app` from
the DMG to `/Applications` (or extract the ZIP and move it there).

An unsigned download can trigger a macOS warning because it has no Developer
ID signature or notarization. In Finder, Control-click the app and choose
**Open**, or use **System Settings > Privacy & Security > Open Anyway** after
verifying the checksum. Do not disable Gatekeeper globally or run an
unverified binary. A production package must be signed with a Developer ID
Application certificate and notarized; the required command and verification
steps are in [RELEASE.md](RELEASE.md). See the full
[macOS installation guide](docs/macos-installation.md) for the exact QA flow.

Arbor is open source under the MIT license. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the repository source-of-truth and generated-file rules.

## Diagnostics and privacy

Arbor writes a small, structured rolling diagnostic log under
`~/Library/Logs/Arbor/`. It records operation names, repository basenames,
versions, and error codes—not access tokens, credential-bearing remote URLs,
commit messages, or file contents. Logs are exported only after the user
chooses a destination.

The release target is MIT-licensed. Third-party dependency license status is
tracked separately in [DEPENDENCY_LICENSES.md](DEPENDENCY_LICENSES.md) and
must be reviewed before a public release.
