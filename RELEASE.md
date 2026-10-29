# Arbor Release Guide

## V1 scope

The V1 release line is `1.0.x`; the current patch release is `1.0.27`. The
local release script builds the Rust engine,
runs the Rust and Swift test suites, creates an arm64 macOS archive, packages
an app DMG and ZIP, signs the ZIP for Sparkle, and writes `appcast.xml` and
`SHA256SUMS`. It generates the Xcode project and
UniFFI bindings before invoking Xcode, so the command also works from a clean
clone.

```sh
ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.27
```

Unsigned artifacts are named `Arbor-VERSION-unsigned-arm64.dmg` and
`Arbor-VERSION-unsigned-arm64.zip`. They are the supported public distribution
when an Apple Developer account is not available. The bundle is sealed with an
ad-hoc signature so Sparkle can validate its structure; this does not provide
an Apple-trusted developer identity or notarization. Label the release as
unsigned so users know that Gatekeeper approval may be required. Users should
verify `SHA256SUMS`, then use Finder's Control-click **Open** or **System
Settings > Privacy & Security > Open Anyway** for that app. Never tell users to
disable Gatekeeper globally.

For a production download, set `ARBOR_UNSIGNED=0`, provide
`DEVELOPER_ID_APPLICATION`, and configure `NOTARY_KEYCHAIN_PROFILE` for
`xcrun notarytool`. The signed artifacts are named
`Arbor-VERSION-arm64.dmg` and `Arbor-VERSION-arm64.zip`. Verify the app before
publishing:

```sh
spctl -a -vv --type open /path/to/Arbor.app
xcrun stapler validate /path/to/Arbor-VERSION-arm64.dmg
```

The GitHub Actions workflow publishes unsigned arm64 artifacts when a `v*` tag
is pushed. Apple signing certificates and notarization credentials are only
needed for an optional Apple-trusted release. Sparkle's separate EdDSA signing
key is required for every release, including unsigned builds.

## Local test packages

For a fresh checkout without the release signing key, run:

```sh
./scripts/release.sh 1.0.28 --local
```

This runs the Rust and Swift suites and creates an ad-hoc-signed DMG and ZIP
plus `SHA256SUMS` under `build/releases/1.0.28-local/`. The filenames include
`local` and no `appcast.xml` is generated. The app retains the supplied version;
the checked-in version is unchanged. These packages are for manual testing,
not the public update channel. Existing public release artifacts are kept in
their separate version directory. Public builds still require the matching
Sparkle private key.

## Sparkle updates

The application embeds Sparkle 2.10.1. Project generation downloads the pinned
official archive and verifies its SHA-256 before embedding the framework.
The menu and settings use Sparkle's download, verification, installation, and
relaunch UI. One application-wide updater checks daily; the previous automatic
check preference is migrated on first launch. Automatic installation and
system-profile uploads are off by default.

The public EdDSA key is `ARBOR_SPARKLE_PUBLIC_KEY` in `Arbor/project.yml`.
The corresponding private key must remain available for future updates. For
local releases it is stored under the `com.arbor.app` account in the login
Keychain. Initial key setup uses:

```sh
./scripts/prepare-sparkle.sh
./build/Sparkle/bin/generate_keys --account com.arbor.app
```

For a new application, copy the printed public key into that build setting.
For Arbor's existing update channel, restore the corresponding private key
instead of replacing the public key with a new one.

For tag builds, export that same private key with Sparkle's `generate_keys -x`
option and store its file contents as the GitHub Actions repository secret
`SPARKLE_EDDSA_PRIVATE_KEY`. CI passes it to Sparkle through stdin; it is not
included in the app, command arguments, or release assets. The release workflow
fails before building if this secret is missing. Local builds use the Keychain
unless this environment variable is supplied.
In GitHub, add it under **Settings > Secrets and variables > Actions > New
repository secret**. The value is the exported file's complete base64 string.

`scripts/sign-update.sh` uses Sparkle's official `generate_appcast` tool with
only the final ZIP as input. The resulting feed contains the archive signature,
size, version, OS requirements, and architecture requirements. Both ZIP and feed
are uploaded in the same GitHub release. The app's stable feed URL is
`https://github.com/arixbit/Arbor/releases/latest/download/appcast.xml`.
Every subsequent release must keep publishing this asset.

Version 1.0.26 predates the embedded updater. Users must manually install a
release containing Sparkle once; later releases can be installed in the app.

## Public unsigned release checklist

The split between the two workflows: `ci-test.yml` runs the full Rust and
Swift suites on every main push, while `release.yml` packages a tagged commit
with `ARBOR_SKIP_TESTS=1` (tests already ran) plus a shared Rust cache. Run
`./scripts/release.sh VERSION` locally without the flag when you want the
full local validation before tagging.

1. Review `CHANGELOG.md`, `DEPENDENCY_LICENSES.md`, and the generated
   `SHA256SUMS`.
2. Confirm the app bundle version matches the tag and the artifacts are named
   `Arbor-VERSION-unsigned-arm64.*`.
3. Confirm `appcast.xml` points to the ZIP for this version and has an EdDSA
   signature. Push the tag; GitHub Actions publishes the release, feed, and
   checksums.
4. Update `Casks/arbor.rb` with the release version and the sha256 from the
   published `SHA256SUMS` (the CI-built DMG hash differs from a local build),
   then push the Cask bump.
5. Copy the updated Cask into the `homebrew-arbor` tap when that repository is
   available.

## Optional Apple-trusted release

1. Build with a Developer ID Application certificate and verify the exported
   app with `spctl`.
2. Submit and staple both DMG and ZIP with `notarytool`.
3. The release script signs the final ZIP and generates its Sparkle feed.
   Update the Cask to the signed `Arbor-VERSION-arm64.*` names.
4. Publish the signed artifacts and release notes.

GitHub, Sparkle, Homebrew, Apple Developer, and notarization credentials are
external to this repository and are deliberately not stored in source or
release artifacts.
