# Contributing to Arbor

Arbor is an MIT-licensed open-source project. Pull requests should keep the
working tree buildable from a clean clone and should include focused tests for
behavioral changes.

## Source of truth

- Swift application and tests live under `Arbor/`.
- Rust engine and tests live under `arbor-engine/`.
- `Arbor/project.yml` is the Xcode project source of truth.
- `arbor-engine/generated/`, `Arbor/Arbor.xcodeproj/`, `target/`, `.build/`,
  and release output are generated locally and are intentionally ignored.

Before running Xcode, build the Rust release library and run the generators:

```sh
cargo build --manifest-path arbor-engine/Cargo.toml --release
./scripts/generate-swift-bindings.sh
./scripts/generate-xcode-project.sh
```

Do not commit generated build output, signing certificates, notarization
credentials, private keys, or repository-specific tokens. Avoid speculative
compatibility code or unused placeholders; when a change removes a code path,
remove its imports and tests in the same pull request.
