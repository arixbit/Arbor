#!/usr/bin/env python3
"""把 Arbor 的控件树变成可提交进仓库的基线，并检查它有没有漂移。

参考对账（`ui-parity.py`）回答「参考实现有、我有没有」，需要 Rebased 在场，只能
本地跑。这个脚本回答另一个问题：**上个批准的样子，这次变了什么**。它只读 Arbor
自己的无障碍树，不需要参考 App，所以能进 CI——发版前那句「我打开看一眼」由它代替。

基线是文本，可以直接 diff、可以 review、可以追问「这行是谁改的」。

用法：
  scripts/ui-snapshot.sh            # 检查：和基线不一致就失败并列出差异
  scripts/ui-snapshot.sh --update   # 认可当前界面，重写基线

归一化是这里唯一有难度的事。树里混着对象地址、pid、每次运行都不同的 fixture 名、
容器绝对路径、本地时区的日期——这些不抹平，基线每次都不同。还有一类更麻烦的：
**含可变文案的控件，宽度本身就跟着变**。fixture 名是随机 8 位十六进制，在比例字体
下宽度是 210 还是 213 pt 取决于抽到哪几个字符，于是它右边的按钮整体平移 2-3 pt。
这类节点不记坐标，并且几何比较带容差，否则每个 PR 都会报一堆假警报。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FRAME_RE = re.compile(r"\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}")
ATTR_RE = re.compile(r"(\w+): (?:'((?:[^'\\]|\\.)*)'|([^,]*))")
INDENT_RE = re.compile(r"^(\s*)")
ROLE_PAREN_RE = re.compile(r"\s*\([^)]*\)\s*$")
FLAG_RE = re.compile(r"(?:^|, )(Disabled|Selected|Focused|Keyboard Focused)(?=,|$)")

# 每次运行都变的东西。
FIXTURE_NAME = re.compile(r"arbor-ui-fixture-[0-9A-Fa-f]{6,}")
ABSOLUTE_PATH = re.compile(r"(?:/Users|/private|/tmp|/var|/Applications)[^\s,，)）]*")
DATE_STAMP = re.compile(r"\b\d{1,2}/\d{1,2}/\d{2,4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AP]M|上午|下午)?")
HASH = re.compile(r"\b[0-9a-f]{7,40}\b")
COUNT_NOISE = re.compile(r"\b\d+\s*(?:files?|个文件)\b")
VOLATILE = re.compile(r"0x[0-9a-f]{6,}|\bpid: \d+\b")

# 几何容差。实测最大的系统性噪声是 6 pt：标题栏那个 fixture 名是随机 8 位十六进制，
# 比例字体下宽度随字符变化，它右边的按钮整体跟着平移。真正的布局回归（多一个按钮、
# 分栏变窄、控件被裁）至少是十几个pt起步，而且结构变化（名字/状态）本来就精确比对。
GEOMETRY_TOLERANCE = 8.0

VARIES = "<varies>"

# 窗口内的浮层（分支弹层这类）没有独立的无障碍子树，导出时首行带一个裁剪矩形：
# `#CLIP x,y,w,h`。只保留落在这块区域里的节点，基线才只包含浮层本身。
CLIP_RE = re.compile(r"^#CLIP (\d+),(\d+),(\d+),(\d+)$")


def normalize_name(name: str) -> tuple[str, bool]:
    """返回（规范化后的名字，这个名字里是否含「每次都变的内容」）。

    含可变内容的节点不该记几何：文本长度一变，SwiftUI 算出来的宽度跟着变，
    拿它当漂移是假警报。这种节点仍然记录「在、叫什么、什么状态」，只是不记录坐标。
    """
    text = VOLATILE.sub("", name)
    volatile = False
    for pattern, placeholder in (
        (FIXTURE_NAME, "<fixture>"),
        (ABSOLUTE_PATH, "<path>"),
        (DATE_STAMP, "<date>"),
        (HASH, "<hash>"),
        (COUNT_NOISE, "<count>"),
    ):
        if pattern.search(text):
            volatile = True
            text = pattern.sub(placeholder, text)
    return re.sub(r"\s+", " ", text).strip(), volatile


def parse_tree(path: Path) -> tuple[list[dict], tuple[float, float]]:
    """把 XCUITest 的树导出读成节点列表，坐标归一化到窗口原点。"""
    nodes: list[dict] = []
    clip: tuple[float, float, float, float] | None = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip().lstrip("→↳ ").strip()
        clip_match = CLIP_RE.match(stripped)
        if clip_match:
            clip = tuple(float(group) for group in clip_match.groups())  # type: ignore[assignment]
            continue
        if stripped.startswith(("Attributes:", "Element subtree:")):
            continue
        frame = FRAME_RE.search(stripped)
        if not frame:
            continue
        role = ROLE_PAREN_RE.sub("", stripped.split(",", 1)[0].replace("→", "").replace("↳", "")).strip()
        x, y, w, h = (float(group) for group in frame.groups())
        remainder = stripped[frame.end():]
        attributes: dict[str, str] = {}
        for key, quoted, bare in ATTR_RE.findall(remainder):
            attributes.setdefault(key, quoted if quoted is not None else bare.strip())
        raw = (
            attributes.get("label")
            or attributes.get("title")
            or attributes.get("value")
            or attributes.get("placeholderValue")
            or ""
        )
        name, volatile = normalize_name(raw.replace("\\n", " "))
        nodes.append({
            "depth": len(INDENT_RE.match(line).group(1)) // 2,
            "role": role.casefold(),
            "name": name,
            "volatile": volatile,
            "x": x, "y": y, "w": w, "h": h,
            # Selected 是焦点/选中态，取决于打开时机和点击顺序，不是布局的
            # 一部分；放进基线会让闸门随机红（实测弹层里每行都在抖）。
            "flags": tuple(
                sorted(flag for flag in set(FLAG_RE.findall(remainder)) if flag != "Selected")
            ),
        })

    # popover/sheet 这类界面是从整棵树里剪出来的，不一定带 window 行；没有窗口就
    # 以第一个节点为原点，坐标才是相对这块界面的，不会随它在屏幕上的位置漂移。
    window = next((node for node in nodes if node["role"] == "window"), None)
    origin = window or (nodes[0] if nodes else None)
    origin_x, origin_y = (origin["x"], origin["y"]) if origin else (0.0, 0.0)
    size = (origin["w"], origin["h"]) if origin else (0.0, 0.0)
    for node in nodes:
        node["x"] -= origin_x
        node["y"] -= origin_y

    if clip is not None:
        clip_x, clip_y, clip_w, clip_h = clip
        nodes = [
            node for node in nodes
            if node["role"] != "window"
            and node["x"] >= clip_x - 2 and node["y"] >= clip_y - 2
            and node["x"] + node["w"] <= clip_x + clip_w + 2
            and node["y"] + node["h"] <= clip_y + clip_h + 2
        ]
        size = (clip_w, clip_h)

    for node in nodes:
        node["box"] = VARIES if node["volatile"] else (
            f"{node['x']:.0f},{node['y']:.0f} {node['w']:.0f}×{node['h']:.0f}")
    return nodes, size


def render(nodes: list[dict]) -> list[str]:
    """基线的文本形态：一个控件一行，可以直接 diff / review。"""
    base = nodes[0]["depth"] if nodes else 0
    lines: list[str] = []
    for node in nodes:
        indent = "  " * max(node["depth"] - base, 0)
        flags = (" [" + "|".join(node["flags"]) + "]") if node["flags"] else ""
        lines.append(f"{indent}{node['role']}\t{node['name'] or '—'}\t{node['box']}{flags}")
    return lines


def geometry(box: str) -> tuple[float, float, float, float] | None:
    if box == VARIES:
        return None
    match = re.match(r"(-?\d+),(-?\d+) (-?\d+)×(-?\d+)$", box)
    return tuple(float(group) for group in match.groups()) if match else None


def compare(baseline: list[dict], current: list[dict], tolerance: float) -> list[str]:
    """逐节点比较；结构变了才退回整行比较，几何差异带容差。

    树是无序容器的稳定序列（导出顺序固定），所以按位置配对是安全的：一旦某个
    控件增删，后面整体错位，这时统一按「结构变了」报告，不逐条硬配。
    """
    same_shape = (
        [(node["role"], node["name"], node["flags"]) for node in baseline]
        == [(node["role"], node["name"], node["flags"]) for node in current]
    )
    if not same_shape:
        return []

    lines: list[str] = []
    for index, (before, after) in enumerate(zip(baseline, current)):
        if before["volatile"] or after["volatile"]:
            continue
        left, right = geometry(before["box"]), geometry(after["box"])
        if not left or not right:
            continue
        delta = [abs(a - b) for a, b in zip(left, right)]
        if max(delta) <= tolerance:
            continue
        lines.append(
            f"  {after['role']} {after['name'] or '—'!r}："
            f"{int(left[0])},{int(left[1])} {int(left[2])}×{int(left[3])}"
            f" → {int(right[0])},{int(right[1])} {int(right[2])}×{int(right[3])}"
            f"（差 {int(max(delta))} pt，行 {index + 1}）"
        )
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tree", default="build/parity/tree", help="无障碍树导出目录")
    parser.add_argument("--baseline", default="ui-smoke/snapshots", help="基线目录")
    parser.add_argument("--update", action="store_true", help="用当前界面重写基线")
    parser.add_argument("--tolerance", type=float, default=GEOMETRY_TOLERANCE,
                        help=f"几何差多少 pt 以上算漂移（默认 {GEOMETRY_TOLERANCE:.0f}）")
    parser.add_argument("--skip", default="",
                        help="逗号分隔的界面名，跳过不进基线（结构不稳定、还没法比的那些）")
    parser.add_argument("--report", action="store_true",
                        help="只报告不失败。CI 首跑用它观察噪声，稳定后再改成严格模式")
    args = parser.parse_args()

    tree_dir, baseline_dir = Path(args.tree), Path(args.baseline)
    skip = {name.strip() for name in args.skip.split(",") if name.strip()}
    surfaces = [
        path.name[len("arbor-"):-len(".txt")]
        for path in sorted(tree_dir.glob("arbor-*.txt"))
        if path.name[len("arbor-"):-len(".txt")] not in skip
    ]
    if not surfaces:
        print(f"{tree_dir} 里没有 arbor-*.txt，先跑 ./scripts/ui-snapshot.sh", file=sys.stderr)
        return 2

    baseline_dir.mkdir(parents=True, exist_ok=True)
    drifted = False
    for surface in surfaces:
        nodes, size = parse_tree(tree_dir / f"arbor-{surface}.txt")
        lines = render(nodes)
        header = f"# Arbor UI snapshot · {surface} · {size[0]:.0f}×{size[1]:.0f} pt"
        target = baseline_dir / f"{surface}.txt"

        if args.update or not target.exists():
            verb = "已写入" if args.update else "首次建立"
            target.write_text(header + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
            print(f"{surface}: {verb} {target}（{len(lines)} 个节点）")
            continue

        previous_lines = target.read_text(encoding="utf-8").splitlines()
        previous_header = previous_lines[0]
        previous_nodes, _ = parse_tree_text(previous_lines[1:])

        # 画布尺寸不同时坐标不可比（分辨率更小的机器会把窗口裁窄），只比结构。
        size_stable = previous_header == header
        tolerance = args.tolerance if size_stable else float("inf")

        geometry_drift = compare(previous_nodes, nodes, tolerance)
        structure_drift = [
            line for line in _structure_diff(previous_nodes, nodes, previous_lines[1:], lines)
        ]

        if not geometry_drift and not structure_drift:
            print(f"{surface}: 与基线一致（{len(lines)} 个节点）")
            continue

        # 画布尺寸不同时只报告不失败：低分辨率 runner 上窗口会被裁窄，控件跟着重排，
        # 那不是「界面坏了」，是比对环境不支持。同一块画布下的漂移才拦。
        drifted = drifted or (not args.report and size_stable)
        print(f"\n{surface}: 与基线不一致"
              f"（结构 {len(structure_drift)} 行 · 几何 {len(geometry_drift)} 处）")
        if not size_stable:
            print(f"  注意：画布尺寸变了（{previous_header.strip('# ')} → {header.strip('# ')}），"
                  f"只比结构、不判失败。")
        for line in structure_drift[:60]:
            print(line)
        if len(structure_drift) > 60:
            print(f"  …还有 {len(structure_drift) - 60} 行；完整基线：{target}")
        for line in geometry_drift[:40]:
            print(line)
        if len(geometry_drift) > 40:
            print(f"  …还有 {len(geometry_drift) - 40} 处")

    if drifted:
        print(
            "\n界面和基线不一致。如果这些变化是本意，跑 ./scripts/ui-snapshot.sh --update\n"
            "把新界面认可为基线，并在提交信息里说明改了什么。",
            file=sys.stderr,
        )
        return 1
    return 0


def parse_tree_text(lines: list[str]) -> tuple[list[dict], tuple[float, float]]:
    """把基线文件读回节点。基线是自己写的格式，不需要再走无障碍树解析。"""
    nodes: list[dict] = []
    for line in lines:
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        parts = line.strip().split("\t")
        if len(parts) < 2:
            continue
        # 无名字的容器在基线里渲染成「—」，读回来要还原成空串，否则
        # 结构比较会把每个容器都当成「改名了」。
        role, name = parts[0], ("" if parts[1] == "—" else parts[1])
        rest = "\t".join(parts[2:]) if len(parts) > 2 else ""
        flags: tuple[str, ...] = ()
        if rest.rstrip().endswith("]"):
            rest, _, tail = rest.rpartition("[")
            flags = tuple(part for part in tail[:-1].split("|") if part)
        tokens = rest.split()
        box = ""
        if tokens and tokens[0] == VARIES:
            box = VARIES
        elif markers := [token for token in tokens if re.match(r"^-?\d+,-?\d+$", token)]:
            index = tokens.index(markers[0])
            box = " ".join(tokens[index:index + 2])
        node = {
            "depth": indent // 2,
            "role": role,
            "name": name,
            "volatile": box == VARIES,
            "flags": flags,
            "box": box,
        }
        coords = geometry(box) if box else None
        node["x"], node["y"], node["w"], node["h"] = coords if coords else (0.0, 0.0, 0.0, 0.0)
        nodes.append(node)
    return nodes, (0.0, 0.0)


def _structure_diff(before: list[dict], after: list[dict],
                    before_lines: list[str], after_lines: list[str]) -> list[str]:
    """结构差异：哪些控件在、叫什么、什么状态。几何由 compare() 单独判。"""
    def skeleton(node: dict) -> str:
        flags = (" [" + "|".join(node["flags"]) + "]") if node["flags"] else ""
        return f"{'  ' * max(node['depth'], 0)}{node['role']}\t{node['name'] or '—'}{flags}"

    old = [skeleton(node) for node in before]
    new = [skeleton(node) for node in after]
    if old == new:
        return []
    import difflib
    return [line for line in difflib.unified_diff(old, new, n=1, lineterm="")
            if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))]


if __name__ == "__main__":
    sys.exit(main())
