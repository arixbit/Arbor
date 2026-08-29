#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 /path/to/Arbor.app /path/to/Arbor.dmg [volume-name]" >&2
  exit 2
fi

app_path=$(cd -- "$1" && pwd -P)
output_path=$2
volume_name=${3:-Arbor}

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "expected an existing .app directory: $app_path" >&2
  exit 2
fi

mkdir -p -- "$(dirname -- "$output_path")"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/arbor-dmg.XXXXXX")
cleanup() { rm -rf -- "$stage_dir"; }
trap cleanup EXIT

ditto "$app_path" "$stage_dir/Arbor.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname "$volume_name" -srcfolder "$stage_dir" -ov -format UDZO "$output_path"
