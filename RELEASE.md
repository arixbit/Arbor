# Arbor Release Guide

## V1 scope

The V1 release is `1.0.0`. The local release script builds the Rust engine,
runs the Rust and Swift test suites, creates an arm64 macOS archive, packages
an app DMG and ZIP, and writes `SHA256SUMS`.

```sh
./scripts/release.sh 1.0.0
```

By default the archive is explicitly unsigned (`ARBOR_UNSIGNED=1`). This is
appropriate for local QA only and must not be presented as a production
download. Set `ARBOR_UNSIGNED=0` and provide `DEVELOPER_ID_APPLICATION` for
an exportable signed archive. Notarization additionally requires an existing
`NOTARY_KEYCHAIN_PROFILE` configured for `xcrun notarytool`.

## Production checklist

1. Review `CHANGELOG.md`, `DEPENDENCY_LICENSES.md`, and the generated
   `SHA256SUMS`.
2. Build with a Developer ID Application certificate and verify the exported
   app with `spctl`.
3. Submit and staple both DMG and ZIP with `notarytool`.
4. Sign the ZIP with Sparkle's `sign_update` using a keychain item, then
   update `distribution/appcast.xml.template` and the Homebrew Cask template
   with immutable URLs and checksums.
5. Publish the artifacts and release notes in the configured release
   repository.

GitHub, Sparkle, Homebrew, Apple Developer, and notarization credentials are
external to this repository and are deliberately not stored in source or
release artifacts.
