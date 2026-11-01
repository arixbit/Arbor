#!/usr/bin/env bash
# Install cargo-nextest from its prebuilt release.
#
# The Rust suite is a set of separate test binaries that `cargo test` runs one
# after another; nextest runs every test case in its own process and keeps all
# cores busy, which is most of the difference between a three minute and a
# sub-minute engine suite. The binary is downloaded, never built: a
# `cargo install cargo-nextest` would spend minutes compiling the tool inside
# the job it is supposed to speed up.
#
# usage: install-nextest.sh [--directory DIR]
set -euo pipefail

version=0.9.150
archive_name=cargo-nextest-$version-universal-apple-darwin.tar.gz
checksum=82a759b4d218d38359424196ab244c470e8f7c7d149c814fbbeef4d67c3c301a
url="https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$version/$archive_name"

directory=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/arbor-nextest

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

binary=$directory/cargo-nextest
if [[ -x "$binary" ]] && [[ "$("$binary" --version 2>/dev/null)" == *"$version"* ]]; then
  echo "cargo-nextest $version already installed at $binary"
else
  archive=$directory/$archive_name
  mkdir -p -- "$directory"
  if [[ ! -f "$archive" ]]; then
    echo "downloading cargo-nextest $version"
    curl --fail --silent --show-error --location --retry 3 \
      --output "$archive.download" "$url"
    mv -- "$archive.download" "$archive"
  fi
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check --status
  tar -xzf "$archive" -C "$directory"
  if [[ ! -x "$binary" ]]; then
    echo "nextest archive did not contain $binary" >&2
    exit 1
  fi
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$directory" >> "$GITHUB_PATH"
fi
"$binary" --version
