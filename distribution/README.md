# Distribution templates

The appcast and Homebrew Cask here are intentionally templates. They are not
production metadata until a real release repository, immutable artifact URL,
SHA256, Sparkle signature, and notarization record exist. The templates point
to the signed arm64 artifact names (`Arbor-VERSION-arm64.dmg` and
`Arbor-VERSION-arm64.zip`); do not substitute the unsigned QA artifacts from
the automated tag workflow.
