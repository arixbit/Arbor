# Distribution metadata

Arbor's supported public package is an unsigned arm64 DMG/ZIP. It does not
require an Apple Developer account or App Store review. The first launch may
need an explicit Gatekeeper approval; the checksum and installation steps are
documented in [the macOS installation guide](../docs/macos-installation.md).

`../Casks/arbor.rb` is the current, release-pinned Homebrew Cask. The file in
`Casks/arbor.rb.template` is the same Cask with version and checksum fields
left for the next release. Update both from the release's `SHA256SUMS` before
publishing a new tap revision.

## Homebrew tap

For the standard command, copy `../Casks/arbor.rb` into a separate GitHub
repository named `homebrew-arbor` at `Casks/arbor.rb`, then users can run:

```sh
brew tap arixbit/arbor && brew trust --tap arixbit/arbor && brew install --cask arbor
```

Until that separate tap repository exists, the Arbor repository itself can be
used as a custom tap remote:

```sh
brew tap arixbit/arbor https://github.com/arixbit/Arbor.git && brew trust --tap arixbit/arbor && brew install --cask arbor
```

`brew trust` confirms that the tap source is allowed to run as Homebrew DSL;
it does not sign the app. Homebrew only downloads and copies the app; it cannot
make an unsigned app Apple-trusted. Users may still need Finder's **Open** or the app-specific
`xattr -dr com.apple.quarantine "/Applications/Arbor.app"` fallback.
