# Contributing to Arbor

Arbor is an MIT-licensed open-source project. Pull requests should keep the
working tree buildable from a clean clone and should include focused tests for
behavioral changes.

## Source of truth

- Swift application and tests live under `Arbor/`.
- Rust engine and tests live under `arbor-engine/`.
- `Arbor/project.yml` is the Xcode project source of truth.
- Build, release, and audit scripts live under `scripts/`; the local app launcher
  is `script/build_and_run.sh`.
- Product checklists and implementation plans live under `docs/development/`;
  the shared translation glossary is `docs/i18n-terms.md`.
- Original icon assets live under `design/`, including `design/vector-kit/`.
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
