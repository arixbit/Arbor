#!/usr/bin/env bash
# 把「参考实现 vs Arbor」的界面对账变成一条命令。
#
# 两层，各自的职责：
#
#   控件层  scripts/ui-parity.py       两个 App 的无障碍树逐控件对账
#                                      → 缺了什么、多了什么、哪儿挪了、差多少 pt
#   像素层  scripts/ui-parity-diff.swift 同一窗口尺寸的两张截图
#                                      → 差异热图，回答「哪里看起来不一样」
#
# 像素比对会被字体和图标渲染放大，控件比对不会：一个按钮的 label 不会因为换个
# 运行时就不一样。所以先看控件报告定位问题，再用热图确认视觉表现。
#
# usage: ui-parity.sh [--reference] [--no-build] [--surface commit|log]
#
#   --reference  同时导出 Rebased 的无障碍树。需要 Rebased 已在运行，并且已经
#                在它里面打开了 visual-fixture 项目（scripts/make-ui-fixture.sh）
#   --no-build   复用上一次的 Debug 构建
#   --surface    只比对一个界面，默认 commit 和 log 都比
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="$ROOT_DIR/build/parity"
REFERENCE=false
BUILD_APP=true
SURFACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reference) REFERENCE=true; shift ;;
    --no-build) BUILD_APP=false; shift ;;
    --surface)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--surface 需要一个界面名" >&2; exit 2; }
      SURFACE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR/tree" "$OUT_DIR/png"

SMOKE_ARGS=(--report "$OUT_DIR/xcresult")
if [[ "$BUILD_APP" == false ]]; then
  SMOKE_ARGS+=(--no-build)
fi

# 每次导出都重新开始，避免上一次的残留被当成这次的结果。
rm -f "$OUT_DIR/tree"/*.txt

echo "== 导出 Arbor 的无障碍树 =="
"$ROOT_DIR/scripts/ui-smoke.sh" "${SMOKE_ARGS[@]}" \
  --only ArborUIParityUITests/testDumpArborTrees

if [[ "$REFERENCE" == true ]]; then
  echo "== 导出 Rebased 的无障碍树 =="
  "$ROOT_DIR/scripts/ui-smoke.sh" --no-build --report "$OUT_DIR/xcresult-reference" \
    --only ArborUIParityUITests/testDumpRebasedTrees
fi

# 导出器被沙箱拦住时，树是以附件形式回来的，从结果包里取出来。
echo "== 提取无障碍树 =="
for bundle in "$OUT_DIR"/xcresult*/; do
  [[ -d "$bundle" ]] || continue
  result="$(find "$bundle" -maxdepth 1 -name '*.xcresult' | head -1)"
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
        if not name.startswith("tree-"):
            continue
        shutil.copy(staging / attachment["exportedFileName"], target / f"{name[5:]}.txt")
PY
  fi
  rm -rf "$staging"
done
ls -1 "$OUT_DIR/tree" 2>/dev/null || true

# 控件报告用到的参考截图和视觉基线是同一份，直接复用已有基线图。
for surface in commit log; do
  source_png="$ROOT_DIR/docs/images/baseline/rebased-$surface.png"
  [[ -f "$source_png" ]] || continue
  cp "$source_png" "$OUT_DIR/png/rebased-$surface.png"
done

echo "== 控件对账 =="
PARITY_ARGS=(--dir "$OUT_DIR" --markdown)
[[ -n "$SURFACE" ]] && PARITY_ARGS+=(--surface "$SURFACE")
python3 "$ROOT_DIR/scripts/ui-parity.py" "${PARITY_ARGS[@]}" || true

# 像素层：只有在两侧截图都在的时候才有意义。
for surface in commit log; do
  replica="$ROOT_DIR/docs/images/baseline/arbor-$surface.png"
  reference="$ROOT_DIR/docs/images/baseline/rebased-$surface.png"
  [[ -f "$replica" && -f "$reference" ]] || continue
  [[ -z "$SURFACE" || "$SURFACE" == "$surface" ]] || continue
  echo "== 像素热图：$surface =="
  swift "$ROOT_DIR/scripts/ui-parity-diff.swift" \
    --replica "$replica" --reference "$reference" \
    --out "$OUT_DIR" --label "$surface" --tolerance 70
done

echo
echo "报告："
ls -1 "$OUT_DIR"/*.html 2>/dev/null || echo "  （没有生成报告，先看上面的跳过原因）"
