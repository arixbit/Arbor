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

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request:
formatting and the two audits on Ubuntu, the Rust engine suite and the Swift
unit suite on macOS in parallel. `.github/workflows/ui-smoke.yml` runs the
click-and-assert suite on pull requests, split across three machines.

Two rules keep that setup honest:

- **Require `CI` and `UI smoke`, not the individual jobs.** Both are aggregator
  jobs that always report, including for a pull request that only touched
  documentation and skipped everything heavy. A required check that is filtered
  out of a run never reports, and the pull request then waits forever.
- **Do not add a `paths:` filter to a workflow that is required.** Filter inside
  the run, as `scripts/ci/classify-changes.sh` does.

The UI smoke suite cannot run its cases in parallel on one machine, so
`scripts/ui-smoke-shard.py` splits its test classes across machines. The number
of machines is `UI_SMOKE_SHARDS` in the workflow; the split is derived from the
test classes in `ui-smoke/`, and the gate fails if a class is not discovered. A
new test class is therefore always part of a shard, and its weight in that
script only affects how evenly the shards are balanced.
