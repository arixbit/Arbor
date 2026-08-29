# macOS Installation

## QA package

The automated GitHub release workflow currently publishes an arm64 unsigned
QA package. It is intentionally named `Arbor-VERSION-unsigned-arm64.dmg` (and
`.zip`) so it cannot be confused with a production build.

This package is for Apple Silicon (arm64) Macs running macOS 14 or later.
Intel Macs currently require a locally built universal archive.

1. Download `SHA256SUMS` and the DMG or ZIP from the same GitHub Release.
2. Verify the checksum:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Open the DMG and drag `Arbor.app` to `/Applications`, or extract the ZIP
   and move the app there.

Because the QA app is not signed or notarized, Gatekeeper may report that
Apple cannot verify the developer. After checking the checksum, Control-click
the app in Finder and choose **Open**, or use **System Settings > Privacy &
Security > Open Anyway**. This approval is per app.

Do not disable Gatekeeper globally, remove security controls for unrelated
applications, or open a package whose checksum does not match the release.

## Production package

A production download must be signed with an Apple Developer ID Application
certificate, submitted to Apple's notarization service, and stapled before it
is published. The maintainer release procedure is in [RELEASE.md](../RELEASE.md).
Users should not need an exception in macOS for a correctly signed and
notarized package.
