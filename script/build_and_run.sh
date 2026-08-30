#!/usr/bin/env bash
set -euo pipefail

MODE="run"
PROJECT_PATH="${ARBOR_PROJECT_PATH:-}"
OPEN_LOG=false
APP_NAME="Arbor"
BUNDLE_ID="com.arbor.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SIGNING_IDENTITY="${ARBOR_CODE_SIGN_IDENTITY:-}"
SIGNING_TEAM="${ARBOR_DEVELOPMENT_TEAM:-}"

# Keep Rust's native objects aligned with the Xcode target. Without this,
# clang-backed Rust dependencies can silently use the current SDK's minimum
# version and make a macOS 14 link emit newer-deployment warnings.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

# Xcode can expose the executable's full path as its process name, so
# `pkill -x Arbor` does not reliably remove an older DerivedData build. Read
# the process table and kill only the exact binary path; this also avoids a
# broad pattern matching the shell that launched this script.
while read -r pid; do
  [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
done < <(ps -axo pid=,args= | awk -v expected="$APP_BINARY" '$2 == expected { print $1 }')

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      OPEN_LOG=true
      shift
      ;;
    run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
      MODE="$1"
      shift
      ;;
    --project)
      [[ $# -ge 2 ]] || { echo "--project requires a directory" >&2; exit 2; }
      PROJECT_PATH="$2"
      shift 2
      ;;
    *)
      # A bare directory is a convenient project argument for local runs.
      [[ -z "$PROJECT_PATH" ]] || { echo "unexpected argument: $1" >&2; exit 2; }
      PROJECT_PATH="$1"
      shift
      ;;
  esac
done

# Running from a Git checkout should show that checkout instead of presenting
# an empty welcome window. Do not auto-open an unborn development repository:
# it has no HEAD and would look like a broken Git Log. An explicit --project
# or ARBOR_PROJECT_PATH wins.
if [[ -z "$PROJECT_PATH" && -e "$ROOT_DIR/.git" ]] \
  && git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  PROJECT_PATH="$ROOT_DIR"
fi

if [[ -n "$PROJECT_PATH" && ! -d "$PROJECT_PATH" ]]; then
  echo "project directory does not exist: $PROJECT_PATH" >&2
  exit 2
fi

# XcodeGen recreates the project below, so preserve a Team selected in Xcode
# before generation. An explicit environment value takes precedence.
if [[ -z "$SIGNING_TEAM" && -f "$ROOT_DIR/Arbor/Arbor.xcodeproj/project.pbxproj" ]]; then
  SIGNING_TEAM=$(xcodebuild \
    -project "$ROOT_DIR/Arbor/Arbor.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | awk -F'= ' '$1 ~ /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*$/ && $2 != "" { print $2; exit }')
fi

SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ "$SIGNING_IDENTITIES" == *"Apple Development:"* ]]; then
    SIGNING_IDENTITY="Apple Development"
  elif [[ "$SIGNING_IDENTITIES" == *"Developer ID Application:"* ]]; then
    SIGNING_IDENTITY="Developer ID Application"
  fi
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  cat >&2 <<'EOF'
No valid macOS code-signing identity was found.
The Debug app cannot be launched ad hoc on this macOS version.
Open Arbor.xcodeproj in Xcode, add your Apple Account in Xcode Settings > Accounts,
then choose an Apple Development Team under Arbor > Signing & Capabilities.
EOF
  exit 2
fi

if [[ -z "$SIGNING_TEAM" ]]; then
  cat >&2 <<'EOF'
No development team is configured for Arbor.
Open Arbor.xcodeproj in Xcode, select the Arbor target, and choose a Team under
Signing & Capabilities. Or rerun with ARBOR_DEVELOPMENT_TEAM=<10-character-team-id>.
EOF
  exit 2
fi

# The Rust cdylib embeds UniFFI metadata and the checked-in Swift binding
# embeds the matching API checksum.  Rebuild both from this workspace before
# Xcode copies the library; otherwise a stale generated Swift file can pass
# compilation and abort the app at startup with a checksum mismatch.
cargo build \
  --release \
  --manifest-path "$ROOT_DIR/arbor-engine/Cargo.toml" \
  --quiet
"$ROOT_DIR/scripts/generate-swift-bindings.sh" >/dev/null
"$ROOT_DIR/scripts/generate-xcode-project.sh"

xcodebuild \
  -project "$ROOT_DIR/Arbor/Arbor.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$SIGNING_TEAM" \
  build

open_app() {
  local -a app_args=()
  if [[ -n "$PROJECT_PATH" ]]; then
    app_args+=("$PROJECT_PATH")
  fi
  if [[ "$OPEN_LOG" == true ]]; then
    app_args+=("--log")
  fi
  if [[ ${#app_args[@]} -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "${app_args[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    # macOS may expose a truncated path as the process name. Match the
    # exact binary argument instead of relying on the display name.
    for _ in {1..10}; do
      if ps -axo pid=,args= \
        | awk -v expected="$APP_BINARY" '$2 == expected { found = 1 } END { exit found ? 0 : 1 }'; then
        exit 0
      fi
      sleep 0.5
    done
    echo "Arbor did not remain running after launch: $APP_BINARY" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [--project PATH] [--log]" >&2
    exit 2
    ;;
esac
