#!/usr/bin/env bash
# Capture the visual baseline for the Commit and Log screens.
#
# Same fixture, same window size (1642×1015), two applications: this one and
# the reference build Arbor is modelled on. Screenshots land in
# build/visual-baseline/png/ and the report is docs/visual-baseline.md.
#
# usage: visual-baseline.sh [--reference] [--no-build]
#   --reference  also resize and capture the Rebased window; it must already
#                have the fixture project open
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="$ROOT_DIR/build/visual-baseline"
REFERENCE=false
BUILD_APP=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reference) REFERENCE=true; shift ;;
    --no-build) BUILD_APP=false; shift ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done

# Only this run's result bundles may feed the captures.
rm -rf "$OUT_DIR"/xcresult*

ARGS=(--report "$OUT_DIR/xcresult")
if [[ "$BUILD_APP" == false ]]; then
  ARGS+=(--no-build)
fi

# ui-smoke.sh runs one test class per invocation, so the reference capture is a
# second call that reuses the build.
"$ROOT_DIR/scripts/ui-smoke.sh" "${ARGS[@]}" \
  --only ArborUIVisualCaptureUITests/testCaptureArborCommitAndLog

if [[ "$REFERENCE" == true ]]; then
  "$ROOT_DIR/scripts/ui-smoke.sh" --no-build --report "$OUT_DIR/xcresult-reference" \
    --only ArborUIVisualCaptureUITests/testCaptureRebasedCommitAndLog
fi

rm -rf "$OUT_DIR/shots" "$OUT_DIR/png"
mkdir -p "$OUT_DIR/png"
for bundle in "$OUT_DIR"/xcresult*/; do
  [[ -d "$bundle" ]] || continue
  result="$(find "$bundle" -maxdepth 1 -name '*.xcresult' | head -1)"
  [[ -n "$result" ]] || continue
  staging="$(mktemp -d)"
  if xcrun xcresulttool export attachments --path "$result" --output-path "$staging" >/dev/null 2>&1; then
    python3 - "$staging" "$OUT_DIR/png" <<'PY'
import json, pathlib, shutil, sys

staging, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifest = json.loads((staging / "manifest.json").read_text())
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "").split("_")[0]
        if name.startswith(("arbor-", "rebased-")):
            shutil.copy(staging / attachment["exportedFileName"], target / f"{name}.png")
PY
  fi
  rm -rf "$staging"
done

echo "captures in $OUT_DIR/png:"
ls -1 "$OUT_DIR/png" || true
