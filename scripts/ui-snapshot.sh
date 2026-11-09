#!/usr/bin/env bash
# 检查 Arbor 的界面有没有偏离已批准的基线。
#
# 和 ui-parity.sh 的分工：
#   ui-parity.sh    和参考实现比「该有的有没有」，需要 Rebased，本地跑
#   ui-snapshot.sh  和上一次批准的界面比「变了什么」，只要 Arbor，能进 CI
#
# 无障碍树是本仓库里最接近「用户到底看见哪些控件」的东西：一个按钮消失、换文案、
# 变灰、挪位置，都会在树上留一行。把树归一化后提交进仓库，发版前就不用靠人打开
# 看一眼——机器会说出哪一行变了。
#
# usage: ui-snapshot.sh [--update] [--report] [--no-build]
#
#   --update   认可当前界面，重写 ui-smoke/snapshots/
#   --report   只报告差异，不失败（CI 首跑观察噪声用）
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="$ROOT_DIR/build/parity"
BASELINE_DIR="$ROOT_DIR/ui-smoke/snapshots"
BUILD_APP=true
UPDATE=false
REPORT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE=true; shift ;;
    --report) REPORT=true; shift ;;
    --no-build) BUILD_APP=false; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR/tree"
# 上一次的导出必须清掉，否则「没导出成功」会被当成「界面没变」。
rm -f "$OUT_DIR"/tree/arbor-*.txt

SMOKE_ARGS=(--report "$OUT_DIR/xcresult-snapshot")
[[ "$BUILD_APP" == false ]] && SMOKE_ARGS+=(--no-build)

"$ROOT_DIR/scripts/ui-smoke.sh" "${SMOKE_ARGS[@]}" \
  --only ArborUIParityUITests/testDumpArborTrees

# 导出器在沙箱里写不了仓库，树是作为附件回来的。
for bundle in "$OUT_DIR"/xcresult-snapshot/; do
  [[ -d "$bundle" ]] || continue
  # 一次运行可能留下多个结果包，取最新的那个：取第一个会把上一次的旧树当成这次的。
  result="$(find "$bundle" -maxdepth 1 -name '*.xcresult' | sort | tail -1)"
  [[ -n "$result" ]] || continue
  staging="$(mktemp -d)"
  if xcrun xcresulttool export attachments --path "$result" --output-path "$staging" >/dev/null 2>&1; then
    python3 - "$staging" "$OUT_DIR/tree" <<'PY'
import json, pathlib, shutil, sys
staging, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
target.mkdir(parents=True, exist_ok=True)
for test in json.loads((staging / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "").split("_")[0]
        if name.startswith("tree-"):
            shutil.copy(staging / attachment["exportedFileName"], target / f"{name[5:]}.txt")
PY
  fi
  rm -rf "$staging"
done

if ! ls "$OUT_DIR"/tree/arbor-*.txt >/dev/null 2>&1; then
  echo "没有取到无障碍树，导出测试可能失败了" >&2
  exit 2
fi

SNAPSHOT_ARGS=(--tree "$OUT_DIR/tree" --baseline "$BASELINE_DIR")
[[ "$UPDATE" == true ]] && SNAPSHOT_ARGS+=(--update)
[[ "$REPORT" == true ]] && SNAPSHOT_ARGS+=(--report)
python3 "$ROOT_DIR/scripts/ui-snapshot.py" "${SNAPSHOT_ARGS[@]}"
