#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 VERSION (for example 1.0.0 or 1.0.0-beta.1)" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=$1
release_dir="$repo_root/build/releases/$version"
archive_dir="$release_dir/archive"
archive_path="$archive_dir/Arbor.xcarchive"
app_path="$archive_path/Products/Applications/Arbor.app"

# The app target supports macOS 14+; native Rust dependencies must use the
# same deployment target before Xcode links the static archive.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

mkdir -p -- "$release_dir"
cargo fmt --manifest-path "$repo_root/arbor-engine/Cargo.toml" --check
cargo test --manifest-path "$repo_root/arbor-engine/Cargo.toml" --all-targets
cargo build --manifest-path "$repo_root/arbor-engine/Cargo.toml" --release
xcodebuild -project "$repo_root/Arbor/Arbor.xcodeproj" -scheme Arbor \
  -destination 'platform=macOS' test

CONFIGURATION=Release MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" \
  ARBOR_UNSIGNED="${ARBOR_UNSIGNED:-1}" \
  "$repo_root/scripts/archive.sh" "$archive_dir"

if [[ ! -d "$app_path" ]]; then
  echo "archive did not contain Arbor.app: $app_path" >&2
  exit 1
fi

if [[ -d "$archive_dir/exported/Arbor.app" ]]; then
  app_path="$archive_dir/exported/Arbor.app"
fi

archive_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
if [[ "$archive_version" != "$version" ]]; then
  echo "archive version mismatch: expected $version, got $archive_version" >&2
  exit 1
fi

"$repo_root/scripts/make-dmg.sh" "$app_path" "$release_dir/Arbor-$version.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_dir/Arbor-$version.zip"
cp "$repo_root/CHANGELOG.md" "$release_dir/CHANGELOG.md"

if [[ "${ARBOR_UNSIGNED:-1}" != "1" ]]; then
  notary_profile=${NOTARY_KEYCHAIN_PROFILE:-}
  if [[ -z "$notary_profile" ]]; then
    echo "set NOTARY_KEYCHAIN_PROFILE for signed notarization" >&2
    exit 2
  fi
  xcrun notarytool submit "$release_dir/Arbor-$version.dmg" \
    --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$release_dir/Arbor-$version.dmg"
  xcrun notarytool submit "$release_dir/Arbor-$version.zip" \
    --keychain-profile "$notary_profile" --wait
  spctl -a -vv --type open "$app_path"
fi

(
  cd -- "$release_dir"
  shasum -a 256 Arbor-"$version".{dmg,zip}
) > "$release_dir/SHA256SUMS"

echo "Local release artifacts: $release_dir"
if [[ "${ARBOR_UNSIGNED:-1}" == "1" ]]; then
  echo "STATUS: unsigned-local (not notarized; do not publish as production)"
fi
