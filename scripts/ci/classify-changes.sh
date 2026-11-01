#!/usr/bin/env bash
# Decide whether a run must exercise the code or only touched documentation.
#
# The workflows never filter with `paths:` at the workflow level: a filtered-out
# workflow does not report its checks at all, and a required check that never
# reports leaves a pull request waiting forever. Instead every run starts, this
# script classifies the diff, and the heavy jobs are skipped from inside the run
# while the gate job still reports.
#
# Writes `code=true|false` to $GITHUB_OUTPUT, and prints it.
#
# usage: classify-changes.sh
set -euo pipefail

emit() {
  echo "code=$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "code=$1" >> "$GITHUB_OUTPUT"
  fi
}

# Documentation-only paths. Anything else -- sources, scripts, workflows,
# project specs, assets -- means the suites must run.
is_doc() {
  case "$1" in
    *.md) return 0 ;;
    docs/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the changed paths for this event, or __UNKNOWN__ when the range cannot
# be reconstructed (a force push, a brand-new branch, a manual run).
changed_files() {
  local event=${GITHUB_EVENT_NAME:-local}
  local before=${BEFORE_SHA:-}
  local after=${AFTER_SHA:-${GITHUB_SHA:-HEAD}}

  case "$event" in
    pull_request)
      if [[ -n "${BASE_SHA:-}" && -n "${HEAD_SHA:-}" ]] \
        && git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
        git diff --name-only "${BASE_SHA}...${HEAD_SHA}" --
        return
      fi
      ;;
    push)
      if [[ -n "$before" && ! "$before" =~ ^0+$ ]] \
        && git cat-file -e "${before}^{commit}" 2>/dev/null; then
        git diff --name-only "${before}..${after}" --
        return
      fi
      if git rev-parse --quiet --verify "${after}~1" >/dev/null 2>&1; then
        git diff --name-only "${after}~1..${after}" --
        return
      fi
      ;;
  esac
  echo "__UNKNOWN__"
}

# An unknown diff is not evidence that only documentation changed, and neither
# is an empty one.
saw_path=false
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  saw_path=true
  if [[ "$path" == "__UNKNOWN__" ]] || ! is_doc "$path"; then
    emit true
    exit 0
  fi
done < <(changed_files)

if [[ "$saw_path" == "false" ]]; then
  emit true
  exit 0
fi

echo "documentation-only change" >&2
emit false
