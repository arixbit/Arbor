#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
configuration=${CONFIGURATION:-Release}
archive_dir=${1:-"$repo_root/build/archives"}
archive_path="$archive_dir/Arbor.xcarchive"

mkdir -p -- "$archive_dir"

xcode_args=(
  xcodebuild
  -project "$repo_root/Arbor/Arbor.xcodeproj"
  -scheme Arbor
  -configuration "$configuration"
  -archivePath "$archive_path"
  ARCHS="${ARBOR_ARCHS:-arm64}"
  archive
)

if [[ -n "${MARKETING_VERSION:-}" ]]; then
  xcode_args+=(MARKETING_VERSION="$MARKETING_VERSION")
fi
if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then
  xcode_args+=(CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION")
fi

if [[ "${ARBOR_UNSIGNED:-0}" == "1" ]]; then
  echo "Creating explicitly unsigned local archive"
  xcode_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
elif [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  xcode_args+=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION")
else
  echo "set DEVELOPER_ID_APPLICATION or ARBOR_UNSIGNED=1" >&2
  exit 2
fi

"${xcode_args[@]}"

if [[ "${ARBOR_UNSIGNED:-0}" != "1" ]]; then
  export_dir="$archive_dir/exported"
  mkdir -p -- "$export_dir"
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$repo_root/scripts/ExportOptions.plist"
fi
