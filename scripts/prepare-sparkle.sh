#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
package="$repo_root/build/Sparkle-$version.tar.xz"
destination="$repo_root/build/Sparkle"

if [[ -f "$destination/.arbor-version" && "$(cat "$destination/.arbor-version")" == "$version" && -d "$destination/Sparkle.framework" ]]; then
  exit 0
fi

mkdir -p -- "$repo_root/build"
if [[ ! -f "$package" ]]; then
  curl --fail --location --retry 3 \
    --output "$package.download" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
  mv -- "$package.download" "$package"
fi
printf '%s  %s\n' "$checksum" "$package" | shasum -a 256 --check --status
mkdir -p -- "$destination"
tar -xf "$package" -C "$destination"
printf '%s\n' "$version" > "$destination/.arbor-version"
