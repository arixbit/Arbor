#!/usr/bin/env bash
# Install the Xcode project generator from its prebuilt release.
#
# `brew install xcodegen` works, but it can trigger a Homebrew self-update and
# it always installs whatever is current, which silently changes the generated
# project format. The pinned archive below is the cheapest deterministic
# option: one small download, no compilation, no package-manager state.
#
# usage: install-xcodegen.sh [--directory DIR]
set -euo pipefail

version=2.46.0
checksum=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
url="https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"

directory=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/arbor-xcodegen

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory)
      [[ $# -ge 2 ]] || { echo "--directory requires a path" >&2; exit 2; }
      directory=$2
      shift 2
      ;;
    *)
      echo "unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

binary=$directory/xcodegen/bin/xcodegen
if [[ -x "$binary" ]] && [[ "$("$binary" --version 2>/dev/null | head -1)" == *"$version"* ]]; then
  echo "xcodegen $version already installed at $binary"
else
  archive=$directory/xcodegen.zip
  mkdir -p -- "$directory"
  if [[ ! -f "$archive" ]]; then
    echo "downloading xcodegen $version"
    curl --fail --silent --show-error --location --retry 3 \
      --output "$archive.download" "$url"
    mv -- "$archive.download" "$archive"
  fi
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check --status
  rm -rf -- "$directory/xcodegen"
  unzip -q -o "$archive" -d "$directory"
  if [[ ! -x "$binary" ]]; then
    echo "xcodegen archive did not contain $binary" >&2
    exit 1
  fi
fi

bin_dir=$(dirname -- "$binary")
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi
"$binary" --version
