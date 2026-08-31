# macOS Installation

## Public unsigned package

The automated GitHub release workflow publishes the supported public arm64
unsigned package. It is named `Arbor-VERSION-unsigned-arm64.dmg` (and
`.zip`) to make its Gatekeeper status explicit.

This package is for Apple Silicon (arm64) Macs running macOS 14 or later.
Intel Macs currently require a locally built universal archive.

1. Download `SHA256SUMS` and the DMG or ZIP from the same GitHub Release.
2. Verify the checksum:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Open the DMG and drag `Arbor.app` to `/Applications`, or extract the ZIP
   and move the app there.

Because the app is not signed or notarized, Gatekeeper may report that
Apple cannot verify the developer, or may use the word "damaged" when
rejecting an unsigned app. That wording can be misleading, but it can also
indicate a real signature, corruption, or modification problem. After checking
the checksum, Control-click the app in Finder and choose **Open**, or use
**System Settings > Privacy & Security > Open Anyway**. This approval is per
app.

If macOS still refuses to open the verified package, remove only Arbor's
quarantine marker as a last resort:

```sh
xattr -dr com.apple.quarantine "/Applications/Arbor.app"
```

This does not sign, notarize, or repair the app. Do not run it when the
checksum does not match, and do not disable Gatekeeper globally. A production
package that is correctly signed and notarized should not require this step.

Do not disable Gatekeeper globally, remove security controls for unrelated
applications, or open a package whose checksum does not match the release.

## Homebrew

Homebrew installs the same release directly into `/Applications`. Until a
dedicated `homebrew-arbor` repository is published, use the source repository
as a custom tap remote:

```sh
brew tap arixbit/arbor https://github.com/arixbit/Arbor.git && brew trust --tap arixbit/arbor && brew install --cask arbor
```

With a dedicated tap, the command is:

```sh
brew tap arixbit/arbor && brew trust --tap arixbit/arbor && brew install --cask arbor
```

`brew trust` confirms the tap source, not the app's Apple signature. Homebrew
does not sign or notarize the app. The first launch may still require Finder's
**Open/Open Anyway**, or the app-specific quarantine command above.

## Optional Apple-trusted package

An Apple-trusted download would require a Developer ID Application certificate,
notarization, and stapling. That is optional for Arbor's unsigned distribution,
and the maintainer release procedure is in [RELEASE.md](../RELEASE.md).
