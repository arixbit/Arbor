# Arbor Release Guide

## V1 scope

The V1 release line is `1.0.x`; the current patch release is `1.0.18`. The
local release script builds the Rust engine,
runs the Rust and Swift test suites, creates an arm64 macOS archive, packages
an app DMG and ZIP, and writes `SHA256SUMS`. It generates the Xcode project and
UniFFI bindings before invoking Xcode, so the command also works from a clean
clone.

```sh
ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.18
```

Unsigned artifacts are named `Arbor-VERSION-unsigned-arm64.dmg` and
`Arbor-VERSION-unsigned-arm64.zip`. They are the supported public distribution
when an Apple Developer account is not available. Label the release as
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
is pushed. Signing certificates, notarization credentials, and Sparkle keys
stay outside the repository. They are only needed for an optional
Apple-trusted release.

## Public unsigned release checklist

1. Review `CHANGELOG.md`, `DEPENDENCY_LICENSES.md`, and the generated
   `SHA256SUMS`.
2. Confirm the app bundle version matches the tag and the artifacts are named
   `Arbor-VERSION-unsigned-arm64.*`.
3. Update `Casks/arbor.rb` and `distribution/Casks/arbor.rb.template` with the
   release version and DMG SHA256.
4. Push the tag; GitHub Actions publishes the release and its checksums.
5. Copy the updated Cask into the `homebrew-arbor` tap when that repository is
   available.

## Optional Apple-trusted release

1. Build with a Developer ID Application certificate and verify the exported
   app with `spctl`.
2. Submit and staple both DMG and ZIP with `notarytool`.
3. Sign the ZIP with Sparkle's `sign_update` using a keychain item, then update
   the appcast and Cask to the signed `Arbor-VERSION-arm64.*` names.
4. Publish the signed artifacts and release notes.

GitHub, Sparkle, Homebrew, Apple Developer, and notarization credentials are
external to this repository and are deliberately not stored in source or
release artifacts.
