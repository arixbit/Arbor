# Arbor Release Guide

## V1 scope

The V1 release line is `1.0.x`; the current patch release is `1.0.35`. The
local release script builds the Rust engine,
runs the Rust and Swift test suites, creates an arm64 macOS archive, packages
an app DMG and ZIP, signs the ZIP for Sparkle, and writes `appcast.xml` and
`SHA256SUMS`. It generates the Xcode project and
UniFFI bindings before invoking Xcode, so the command also works from a clean
clone.

```sh
ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.35
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

## UI baseline before tagging

The release script runs the unit suites, which cannot see a misplaced or renamed
control. Check the UI against the committed baseline before tagging:

```sh
./scripts/ui-snapshot.sh
```

It exports the accessibility tree of the Commit, Log and Settings surfaces,
normalises it and compares it with `ui-smoke/snapshots/`. A drift fails the
command and lists the controls that changed. When the change is intended:

```sh
./scripts/ui-snapshot.sh --update
```

commit the new baseline, and say what changed in the release notes. The same
check runs on every pull request (report-only for now), so a drift usually
shows up long before a release.

`./scripts/ui-parity.sh --reference` additionally compares the replica against
the reference application, control by control. It needs that application
running with the fixture project and only works on a developer machine; see
`docs/ui-parity.md`.

## 已修复：非当前分支 pull 的临时 worktree 撞名

`pull_non_current_branch_{rebases,merges}_into_selected_branch_without_checkout`
曾经在整机有负载时偶发失败，约 12 次全量跑出现 1 次，报错是 `index.lock: File
exists` 或「worktree 里有不该存在的 untracked 文件」。

根因：非当前分支的 pull 要开一个临时 worktree，名字是
`arbor-pull-{pid}-{时间戳}-{commit}`。这三个都可能在并发下重复——pid 在同一进程里
相同，两个用例共用同一份 fixture 因此 commit id 相同，而 `SystemTime` 在本机的
分辨率是 1 µs，两个线程只要落在同一个微秒就会算出**同一个路径**。

修复：名字里加一个进程内自增序号，唯一性由构造保证，不再依赖时钟。
修复后 pull 测试连跑 30 次、引擎全量连跑 5 次均无失败。

顺带一个观察：CI 用 `cargo nextest`，每个用例独立进程，pid 天然不同——所以这个
撞名**只在发布脚本这条路**上（`cargo test` 同进程多线程）才出现。CI 全绿不代表
发布脚本能过，跑 `release.sh` 前值得先手工 `cargo test --all-targets` 一次。

复现/诊断时带上埋点可以看到临时 worktree 的路径和每条 git 命令的结果：

```sh
ARBOR_PULL_TRACE=1 cargo test --manifest-path arbor-engine/Cargo.toml --test pull -- --nocapture
```

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
