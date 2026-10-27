# Dependency Licenses

Arbor's application code is released under the MIT license in `LICENSE`.
The Rust engine uses crates from crates.io. The dependency graph is locked in
`arbor-engine/Cargo.lock`; license metadata for the resolved graph is provided
by Cargo package metadata and must be reviewed whenever dependencies change.

Direct runtime dependencies:

The macOS app embeds [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle),
licensed under the Sparkle license (BSD-style) with the bundled third-party
notices. The complete upstream license is shipped in
`Arbor/Resources/Sparkle-LICENSE.txt`. Its release archive is pinned and
SHA-256 checked by `scripts/prepare-sparkle.sh`.

| Crate | License | Source |
|---|---|---|
| `gix` | MIT OR Apache-2.0 | https://github.com/GitoxideLabs/gitoxide |
| `uniffi` | MPL-2.0 | https://github.com/mozilla/uniffi-rs |
| `libc` | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| `regex` | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| `tempfile` | MIT OR Apache-2.0 | https://github.com/StephanDumont/tempfile |
| `tree-sitter` | MIT | https://github.com/tree-sitter/tree-sitter |
| `tree-sitter-language` | MIT | https://github.com/tree-sitter/tree-sitter |
| `streaming-iterator` | MIT OR Apache-2.0 | https://github.com/rust-it/streaming-iterator |
| `tree-sitter-*` grammars | MIT | https://github.com/tree-sitter |

`gix`, `uniffi`, and their transitive dependencies may include additional
MIT, Apache-2.0, BSD, ISC, Zlib, Unicode, Unlicense, or compatible dual
licenses. The exact versions and checksums are the locked Cargo graph. Before
any public redistribution, regenerate this inventory from the lockfile and
ship the applicable license texts and notices required by those packages.

This repository does not vendor third-party license text into the application
bundle yet; the production release checklist must be completed before a
public, signed distribution.
