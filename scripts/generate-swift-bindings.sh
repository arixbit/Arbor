#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
engine_dir="$repo_root/arbor-engine"
library_path="$engine_dir/target/release/libarbor_engine.dylib"
output_dir="$engine_dir/generated/swift"

if [[ ! -f "$library_path" ]]; then
  echo "Rust release library not found: $library_path" >&2
  echo "run cargo build --release --manifest-path arbor-engine/Cargo.toml first" >&2
  exit 2
fi

mkdir -p -- "$output_dir"
(
  cd "$engine_dir"
  cargo run --release --bin uniffi-bindgen -- \
    generate \
    --library \
    --language swift \
    --out-dir "$output_dir" \
    "$library_path"
)
