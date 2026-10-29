#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ || ( $# -eq 2 && "$2" != "--local" ) ]]; then
  echo "usage: $0 VERSION [--local] (for example 1.0.0 or 1.0.0-beta.1)" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=$1
release_dir="$repo_root/build/releases/$version"
local_build=false
if [[ "${2:-}" == "--local" ]]; then
  if [[ "${ARBOR_UNSIGNED:-1}" != "1" ]]; then
    echo "--local requires ARBOR_UNSIGNED=1 (the default)" >&2
    exit 2
  fi
  local_build=true
  release_dir="$repo_root/build/releases/$version-local"
fi
archive_dir="$release_dir/archive"
archive_path="$archive_dir/Arbor.xcarchive"
arch_label=${ARBOR_ARCHS:-arm64}
arch_label=${arch_label// /-}
if [[ "$local_build" == true ]]; then
  artifact_stem="Arbor-$version-local-$arch_label"
elif [[ "${ARBOR_UNSIGNED:-1}" == "1" ]]; then
  artifact_stem="Arbor-$version-unsigned-$arch_label"
else
  artifact_stem="Arbor-$version-$arch_label"
fi
dmg_path="$release_dir/$artifact_stem.dmg"
zip_path="$release_dir/$artifact_stem.zip"
app_path="$archive_path/Products/Applications/Arbor.app"

# The app target supports macOS 14+; native Rust dependencies must use the
# same deployment target before Xcode links the static archive.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

mkdir -p -- "$release_dir"
# A rerun must not leave an old naming variant for the tag workflow to upload.
rm -f -- \
  "$release_dir/Arbor-$version.dmg" \
  "$release_dir/Arbor-$version.zip" \
  "$release_dir"/Arbor-"$version"-*.dmg \
  "$release_dir"/Arbor-"$version"-*.zip \
  "$release_dir/SHA256SUMS" \
  "$release_dir/appcast.xml" \
  "$release_dir/CHANGELOG.md"
cargo fmt --manifest-path "$repo_root/arbor-engine/Cargo.toml" --check
# Tag builds reuse the validation already performed on main by ci-test.yml;
# set ARBOR_SKIP_TESTS=1 to skip the two full test suites. Local release runs
# keep the default (tests on) so the packaged artifact is the tested one.
if [[ "${ARBOR_SKIP_TESTS:-0}" != "1" ]]; then
  cargo test --manifest-path "$repo_root/arbor-engine/Cargo.toml" --all-targets
fi
cargo build --manifest-path "$repo_root/arbor-engine/Cargo.toml" --release
"$repo_root/scripts/generate-swift-bindings.sh" >/dev/null
"$repo_root/scripts/generate-xcode-project.sh"
if [[ "${ARBOR_SKIP_TESTS:-0}" != "1" ]]; then
  xcodebuild -project "$repo_root/Arbor/Arbor.xcodeproj" -scheme Arbor \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
fi

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

if [[ "${ARBOR_UNSIGNED:-1}" == "1" ]]; then
  # Seal the app while preserving Sparkle's upstream-signed framework/helpers.
  # The update generator rejects partially signed Apple Silicon bundles.
  codesign --force --sign - "$app_path"
  codesign --verify --deep --strict "$app_path"
fi

"$repo_root/scripts/make-dmg.sh" "$app_path" "$dmg_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
# Release notes must show only the current version's section; shipping the
# full historical changelog made every release page several screens long.
awk -v header="## $version" '
  $0 == header || index($0, header " ") == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$repo_root/CHANGELOG.md" > "$release_dir/CHANGELOG.md"

if [[ "${ARBOR_UNSIGNED:-1}" != "1" ]]; then
  notary_profile=${NOTARY_KEYCHAIN_PROFILE:-}
  if [[ -z "$notary_profile" ]]; then
    echo "set NOTARY_KEYCHAIN_PROFILE for signed notarization" >&2
    exit 2
  fi
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg_path"
  xcrun notarytool submit "$zip_path" \
    --keychain-profile "$notary_profile" --wait
  spctl -a -vv --type open "$app_path"
fi

checksum_files=("$(basename "$dmg_path")" "$(basename "$zip_path")")
if [[ "$local_build" != true ]]; then
  "$repo_root/scripts/sign-update.sh" "$zip_path"
  checksum_files+=(appcast.xml)
fi

(
  cd -- "$release_dir"
  shasum -a 256 "${checksum_files[@]}"
) > "$release_dir/SHA256SUMS"

echo "Local release artifacts: $release_dir"
if [[ "$local_build" == true ]]; then
  echo "STATUS: local-test (no update feed; do not publish to the release channel)"
elif [[ "${ARBOR_UNSIGNED:-1}" == "1" ]]; then
  echo "STATUS: unsigned-public (not Apple-trusted; Gatekeeper approval may be required)"
fi
