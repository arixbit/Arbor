#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to generate Arbor/Arbor.xcodeproj" >&2
  echo "install it with: brew install xcodegen" >&2
  exit 2
fi

# Xcodegen materializes values from the spec into a referenced Info.plist. Keep
# the checked-in template with build-setting placeholders so release version
# overrides continue to work and generation stays side-effect free.
info_plist="$repo_root/Arbor/Info.plist"
saved_info_plist=$(mktemp "${TMPDIR:-/tmp}/arbor-info-plist.XXXXXX")
cleanup() {
  cp -- "$saved_info_plist" "$info_plist"
  rm -f -- "$saved_info_plist"
}
trap cleanup EXIT
cp -- "$info_plist" "$saved_info_plist"

xcodegen generate \
  --spec "$repo_root/Arbor/project.yml" \
  --project "$repo_root/Arbor" \
  --quiet
