#!/usr/bin/env bash
# Run Arbor's UI smoke suite.
#
# The suite clicks every visible control on a main surface and requires an
# observable change. It runs against a throwaway Git repository built by
# scripts/make-ui-fixture.sh, and against the app bundle passed in
# ARBOR_UI_APP_PATH.
#
# usage: ui-smoke.sh [--no-build] [--only TestName] [--dump] [--report DIR]
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_DIR="${ARBOR_UI_APP_PATH:-$ROOT_DIR/.build/DerivedData/Build/Products/Debug/Arbor.app}"
SMOKE_PROJECT="$ROOT_DIR/.build/UISmoke/ArborUISmoke.xcodeproj"
SMOKE_DERIVED="$ROOT_DIR/.build/UISmoke/DerivedData"
BUILD_APP=true
ONLY_TEST=""
DUMP=false
RESULT_BUNDLE=""
FOCUS_LABEL=""
FOCUS_SURFACE="commit"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      BUILD_APP=false
      shift
      ;;
    --only)
      [[ $# -ge 2 ]] || { echo "--only requires a test name" >&2; exit 2; }
      ONLY_TEST="$2"
      shift 2
      ;;
    --dump)
      DUMP=true
      shift
      ;;
    --focus)
      [[ $# -ge 2 ]] || { echo "--focus requires a control label" >&2; exit 2; }
      FOCUS_LABEL="$2"
      if [[ $# -ge 4 && "$3" == "--surface" ]]; then
        FOCUS_SURFACE="$4"
        shift 2
      fi
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || { echo "--report requires a directory" >&2; exit 2; }
      RESULT_BUNDLE="$2"
      shift 2
      ;;
    *)
      echo "unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 2
fi

if [[ "$BUILD_APP" == true ]]; then
  # Cargo handles incremental builds; an existing library may be stale, and
  # the Swift bindings must match the library before Xcode compiles the app.
  cargo build --release --manifest-path "$ROOT_DIR/arbor-engine/Cargo.toml"
  "$ROOT_DIR/scripts/generate-swift-bindings.sh" >/dev/null
  "$ROOT_DIR/scripts/generate-xcode-project.sh"
  xcodebuild \
    -project "$ROOT_DIR/Arbor/Arbor.xcodeproj" \
    -scheme Arbor \
    -configuration Debug \
    -sdk macosx \
    -derivedDataPath "$ROOT_DIR/.build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build >/dev/null
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "built app not found at $APP_DIR" >&2
  exit 2
fi

# The UI test runner is sandboxed, so git cannot run inside the test process.
# Build one template repository here and let each test copy it into its own
# container, so tests stay isolated from each other.
FIXTURE_TEMPLATE="$ROOT_DIR/.build/UISmoke/fixture-template"
"$ROOT_DIR/scripts/make-ui-fixture.sh" "$FIXTURE_TEMPLATE" >/dev/null

mkdir -p "$(dirname -- "$SMOKE_PROJECT")/.."
TEST_ARGS=()
if [[ -n "$FOCUS_LABEL" ]]; then
  # The UI test runner is sandboxed and there is no supported way to pass a
  # parameter through xcodebuild, so the request is handed over as a file the
  # runner can read inside the checkout.
  python3 - "$FOCUS_LABEL" "$FOCUS_SURFACE" > "$(dirname -- "$SMOKE_PROJECT")/focus.json" <<'PYEOF'
import json, sys
print(json.dumps({"label": sys.argv[1], "surface": sys.argv[2]}))
PYEOF
  TEST_ARGS+=("-only-testing:ArborUISmokeUITests/ArborUISmokeFocusUITests")
else
  rm -f "$(dirname -- "$SMOKE_PROJECT")/focus.json"
fi

mkdir -p "$(dirname -- "$SMOKE_PROJECT")"
xcodegen generate --spec "$ROOT_DIR/ui-smoke/project.yml" --project "$(dirname -- "$SMOKE_PROJECT")" --quiet

# XcodeGen writes the newest project format it knows unless the spec pins one.
# The suite must stay runnable on the older Xcode in CI, so fail here instead of
# letting xcodebuild report an unreadable project.
smoke_project_file="$SMOKE_PROJECT/project.pbxproj"
if ! grep -q '^[[:space:]]*objectVersion = 63;[[:space:]]*$' "$smoke_project_file"; then
  echo "unsupported Xcode project format in $smoke_project_file (expected objectVersion 63)" >&2
  exit 1
fi

if [[ -n "$ONLY_TEST" ]]; then
  TEST_ARGS+=("-only-testing:ArborUISmokeUITests/$ONLY_TEST")
fi
if [[ -n "$RESULT_BUNDLE" ]]; then
  mkdir -p "$RESULT_BUNDLE"
  TEST_ARGS+=("-resultBundlePath" "$RESULT_BUNDLE/$(date +%Y%m%d-%H%M%S).xcresult")
fi

# xcodebuild forwards TEST_RUNNER_* settings into the (sandboxed) UI test
# runner as environment variables; a plain export does not reach it.
xcodebuild test \
  -project "$SMOKE_PROJECT" \
  -scheme ArborUISmoke \
  -destination 'platform=macOS' \
  -derivedDataPath "$SMOKE_DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  "TEST_RUNNER_ARBOR_UI_APP_PATH=$APP_DIR" \
  "TEST_RUNNER_ARBOR_UI_FIXTURE_TEMPLATE=$FIXTURE_TEMPLATE" \
  "TEST_RUNNER_ARBOR_UI_DUMP=$([[ "$DUMP" == true ]] && echo 1 || echo 0)" \
  "TEST_RUNNER_ARBOR_UI_TRACE=${ARBOR_UI_TRACE:-0}" \
  ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}
