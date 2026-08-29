# Arbor Release Guide

## V1 scope

The V1 release line is `1.0.x`; the current patch release is `1.0.12`. The
local release script builds the Rust engine,
runs the Rust and Swift test suites, creates an arm64 macOS archive, packages
an app DMG and ZIP, and writes `SHA256SUMS`. It generates the Xcode project and
UniFFI bindings before invoking Xcode, so the command also works from a clean
clone.

```sh
ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.12
```

Unsigned artifacts are named `Arbor-VERSION-unsigned-arm64.dmg` and
`Arbor-VERSION-unsigned-arm64.zip`. They are appropriate for local QA only and
must be labelled as such in a public release. A downloaded unsigned app can
show a Gatekeeper warning; users should verify `SHA256SUMS`, then use Finder's
Control-click **Open** or **System Settings > Privacy & Security > Open Anyway**
for that app. Never tell users to disable Gatekeeper globally.

For a production download, set `ARBOR_UNSIGNED=0`, provide
`DEVELOPER_ID_APPLICATION`, and configure `NOTARY_KEYCHAIN_PROFILE` for
`xcrun notarytool`. The signed artifacts are named
`Arbor-VERSION-arm64.dmg` and `Arbor-VERSION-arm64.zip`. Verify the app before
publishing:

```sh
spctl -a -vv --type open /path/to/Arbor.app
xcrun stapler validate /path/to/Arbor-VERSION-arm64.dmg
```

The GitHub Actions workflow publishes unsigned QA artifacts when a `v*` tag is
pushed. Signing certificates, notarization credentials, and Sparkle keys stay
outside the repository; a maintainer must configure them before publishing a
production release.

## Production checklist

1. Review `CHANGELOG.md`, `DEPENDENCY_LICENSES.md`, and the generated
   `SHA256SUMS`.
2. Build with a Developer ID Application certificate and verify the exported
   app with `spctl`.
3. Submit and staple both DMG and ZIP with `notarytool`.
4. Sign the ZIP with Sparkle's `sign_update` using a keychain item, then
   update `distribution/appcast.xml.template` and the Homebrew Cask template
   with immutable URLs and checksums. These templates refer to the signed
   `Arbor-VERSION-arm64.*` names, never the unsigned QA names.
5. Publish the artifacts and release notes in the configured release
   repository.

GitHub, Sparkle, Homebrew, Apple Developer, and notarization credentials are
external to this repository and are deliberately not stored in source or
release artifacts.
