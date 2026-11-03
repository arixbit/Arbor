#!/usr/bin/env python3
"""把「参考实现的界面」和「Arbor 的界面」逐控件对账。

`docs/visual-baseline.md` 的 C1–C9 / L1–L8 是人工盯图写出来的，每次发版都要
重新盯一遍。这个脚本把那件事变成一次可重跑的比对：两侧的无障碍树由
`ui-smoke/ArborUIParityUITests.swift` 导出（`scripts/ui-parity.sh` 会自动跑），
这里对同一块画布上的具名控件做三方对账：

    参考有、Arbor 没有     → 缺控件（按钮没做、菜单项漏了）
    Arbor 有、参考没有     → 多出来的东西（多一行标题、多一个分组）
    同名但位置/尺寸不同     → 布局偏差（栏宽、换行、间距）
    同名但可用状态不同     → 状态偏差（参考能点，Arbor 灰着）

像素比的是「长得像不像」，这里比的是「该有的东西在不在、在不在同一个地方」。
字体不同会让像素比对满屏报错，但不会让一个按钮的 label 变样，所以这一层才是
「按钮对不上」的判据。像素热图（`ui-parity-diff.swift`）只负责回答「哪儿」。

用法：
  python3 scripts/ui-parity.py                        # 用 build/parity/tree 下已有的导出
  python3 scripts/ui-parity.py --surface commit
  python3 scripts/ui-parity.py --markdown             # 生成可粘进 docs 的表格
  python3 scripts/ui-parity.py --move-threshold 4     # 位置差多少 pt 才算不一致
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# XCUITest 的 debugDescription 一行一个元素：
#   Button, 0x10a, {{100.0, 200.0}, {80.0, 20.0}}, identifier: 'commit', label: 'Commit'
# 帧是屏幕绝对坐标，所以比较前必须减去窗口原点，否则两个 App 窗口位置不同就全歪。
FRAME_RE = re.compile(r"\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}")
ATTR_RE = re.compile(r"(\w+): (?:'((?:[^'\\]|\\.)*)'|([^,]*))")
INDENT_RE = re.compile(r"^(\s*)")
ROLE_PAREN_RE = re.compile(r"\s*\([^)]*\)\s*$")
FLAG_RE = re.compile(r"(?:^|, )(Disabled|Selected|Focused|Keyboard Focused)(?=,|$)")
# JetBrains 平台给没被布局的组件（表格行、隐藏控件）发哨兵坐标，比如
# INT_MIN 附近的值、0×0、负尺寸。这些坐标对「在哪儿」毫无意义，只能参与按名字比对。
SENTINEL = 1_000_000

# 两个 App 对这些角色的叫法一致，但分组不同：控件类用来对「有没有这个入口」，
# 文本类用来对「这一行字是什么」。分开比对可以避免把标签文字和按钮互相配错。
CONTROL_ROLES = {
    "button", "menubutton", "menuitem", "checkbox", "radiobutton", "popupbutton",
    "textfield", "searchfield", "tab", "tabgroup", "toolbar", "slider", "combobox",
    "link", "disclosuretriangle", "stepper", "segmentedcontrol", "switch", "splitter",
}
TEXT_ROLES = {"statictext", "cell", "text", "heading", "label", "row", "listitem"}

# 这些角色的「名字」在两种实现之间本来就没有可比性：图标没有文字、容器没有
# 语义、窗口标题是两个 App 各自的名字。
EXCLUDED_ROLES = {
    "image", "group", "other", "window", "application", "scrollview", "scrollarea",
    "splitgroup", "splitter", "progressindicator", "scrollbar", "menubar", "toolbar",
}

# 名字里这些尾巴是装饰或快捷键提示，跨 App 一定不一样。
TRAILING_NOISE = re.compile(r"\s*(?:\.{2,}|…|\(\s*[⌘⌥⌃⇧A-Za-z0-9+↩␣]+\s*\))\s*$")


@dataclass
class Node:
    role: str
    name: str
    x: float
    y: float
    w: float
    h: float
    depth: int
    disabled: bool = False
    selected: bool = False
    identifier: str = ""

    @property
    def bucket(self) -> str:
        if self.role in CONTROL_ROLES:
            return "control"
        if self.role in TEXT_ROLES:
            return "text"
        return "other"

    @property
    def key(self) -> str:
        return f"{self.bucket}|{normalize(self.name)}"

    @property
    def box(self) -> str:
        return f"{self.x:.0f},{self.y:.0f} {self.w:.0f}×{self.h:.0f}"

    @property
    def placed(self) -> bool:
        """这个节点的坐标能不能拿来比位置。

        JetBrains 平台给表格单元格发的是 0×0 或者负尺寸，坐标常常是
        (-200, -59) 这种窗口外的哨兵值；拿它算偏移只会凭空造出「位置不一致」。
        """
        return (
            abs(self.x) < SENTINEL and abs(self.y) < SENTINEL
            and self.w > 0 and self.h > 0
            and self.x >= -2 and self.y >= -2
        )

    @property
    def commentable(self) -> bool:
        return bool(self.name) and not self.name.isspace() and self.role not in EXCLUDED_ROLES


def normalize(name: str) -> str:
    """跨 App 比较用：去掉省略号、快捷键提示、大小写与多余空白。"""
    text = name.strip()
    previous = None
    while previous != text:
        previous = text
        text = TRAILING_NOISE.sub("", text).strip()
    return re.sub(r"\s+", " ", text).casefold()


def parse_tree(path: Path) -> list[Node]:
    nodes: list[Node] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        # 导出里带分段标题和箭头前缀：`Element subtree:`、`→Application`、`↳Window`。
        stripped = line.strip().lstrip("→↳ ").strip()
        if stripped.startswith(("Attributes:", "Element subtree:")):
            # 段首的 Attributes 行只是根节点的副本，跳过避免重复计数。
            continue
        frame = FRAME_RE.search(stripped)
        if not frame or "," not in stripped:
            continue
        depth = len(INDENT_RE.match(line).group(1)) // 2
        role = ROLE_PAREN_RE.sub("", stripped.split(",", 1)[0].replace("→", "").replace("↳", "")).strip().casefold()
        x, y, w, h = (float(group) for group in frame.groups())
        remainder = stripped[frame.end():]

        attributes: dict[str, str] = {}
        for key, quoted, bare in ATTR_RE.findall(remainder):
            value = quoted if quoted is not None else bare.strip()
            attributes.setdefault(key, value)
        flags = set(FLAG_RE.findall(remainder))

        # label 是用户看见的字，title 是页签/窗口标题，value 是输入框内容和列表
        # 正文；按下述顺序取第一个非空的当作这个节点的身份。
        raw = (
            attributes.get("label")
            or attributes.get("title")
            or attributes.get("value")
            or attributes.get("placeholderValue")
            or ""
        )
        name = raw.replace("\\n", " ").replace("\\'", "'").strip()
        nodes.append(Node(
            role=role, name=name, x=x, y=y, w=w, h=h, depth=depth,
            disabled="Disabled" in flags,
            selected="Selected" in flags,
            identifier=attributes.get("identifier", ""),
        ))

    # 归一化到窗口原点，两侧画布才能逐点相减。
    origin = next((node for node in nodes if node.role == "window"), None)
    if origin:
        dx, dy = origin.x, origin.y
        for node in nodes:
            node.x -= dx
            node.y -= dy
    return nodes


def canvas(nodes: list[Node]) -> tuple[float, float]:
    window = next((node for node in nodes if node.role == "window"), None)
    return (window.w, window.h) if window else (0.0, 0.0)


def comparable(nodes: list[Node]) -> list[Node]:
    return [node for node in nodes if node.commentable]


@dataclass
class Pairing:
    matched: list[tuple[Node, Node]]
    missing: list[Node]
    extra: list[Node]


def pair(reference: list[Node], replica: list[Node]) -> Pairing:
    """按（类别, 归一化名字）配对；同名多次出现时按阅读顺序一一对应。"""
    buckets: dict[str, list[Node]] = {}
    for node in replica:
        buckets.setdefault(node.key, []).append(node)
    for nodes in buckets.values():
        nodes.sort(key=lambda n: (round(n.y), round(n.x)))

    matched: list[tuple[Node, Node]] = []
    missing: list[Node] = []
    used: set[int] = set()
    for node in sorted(reference, key=lambda n: (round(n.y), round(n.x))):
        candidates = buckets.get(node.key, [])
        while candidates and id(candidates[0]) in used:
            candidates.pop(0)
        if candidates:
            counterpart = candidates.pop(0)
            used.add(id(counterpart))
            matched.append((node, counterpart))
        else:
            missing.append(node)
    extra = [node for node in replica if id(node) not in used]
    return Pairing(matched, missing, extra)


KINDS = {
    "missing": "参考有 · Arbor 缺",
    "unreliable": "参考侧坐标不可用",
    "extra": "Arbor 多出来",
    "moved": "位置不一致",
    "resized": "尺寸不一致",
    "state": "可用状态不一致",
}


@dataclass
class Row:
    kind: str
    role: str
    name: str
    detail: str
    x: float
    y: float
    count: int = 1

    @property
    def text(self) -> str:
        """说明文字。同名控件重复出现时把次数写在后面，而不是列 N 行。"""
        return f"{self.detail}（共 {self.count} 处）" if self.count > 1 else self.detail


def build_rows(pairing: Pairing, threshold: float) -> list[Row]:
    rows: list[Row] = []
    for node in pairing.missing:
        # 参考平台没给坐标的节点（表格单元格、隐藏控件）不能当成「Arbor 缺了」，
        # 它只是没法定位。单独一类，免得真正的问题被 6 倍重复淹掉。
        kind = "missing" if node.placed else "unreliable"
        rows.append(Row(kind, node.role, node.name, f"在 {node.box}", node.x, node.y))
    for node in pairing.extra:
        rows.append(Row("extra", node.role, node.name, f"在 {node.box}", node.x, node.y))
    for reference_node, replica_node in pairing.matched:
        dx = replica_node.x - reference_node.x
        dy = replica_node.y - reference_node.y
        dw = replica_node.w - reference_node.w
        dh = replica_node.h - reference_node.h
        if reference_node.disabled != replica_node.disabled:
            state = "参考可点 · Arbor 灰着" if replica_node.disabled else "参考灰着 · Arbor 可点"
            rows.append(Row("state", reference_node.role, reference_node.name, state,
                            reference_node.x, reference_node.y))
        elif not (reference_node.placed and replica_node.placed):
            # 参考平台没给这个控件坐标（表格行常见），位置比不出来，不编一个结论。
            continue
        elif max(abs(dx), abs(dy)) > threshold:
            rows.append(Row(
                "moved", reference_node.role, reference_node.name,
                f"偏 {dx:+.0f},{dy:+.0f} pt（{reference_node.box} → {replica_node.box}）",
                reference_node.x, reference_node.y,
            ))
        elif max(abs(dw), abs(dh)) > threshold:
            rows.append(Row(
                "resized", reference_node.role, reference_node.name,
                f"尺寸 {dw:+.0f}×{dh:+.0f} pt（{reference_node.box} → {replica_node.box}）",
                reference_node.x, reference_node.y,
            ))
    order = {kind: index for index, kind in enumerate(KINDS)}
    rows.sort(key=lambda row: (order[row.kind], round(row.y / 8), round(row.x)))
    return collapse_duplicates(rows)


def collapse_duplicates(rows: list[Row]) -> list[Row]:
    """同名同角色的重复行合成一条。

    JetBrains 的表格把每一行都报成同一个单元格文本（实测 log 表 7 行全是
    “Initial commit”），不合并的话 126 条「缺失」里大部分只是同一行重复了 7 次。
    """
    collapsed: list[Row] = []
    seen: dict[tuple[str, str, str], Row] = {}
    for row in rows:
        if row.kind not in {"missing", "extra", "unreliable"}:
            collapsed.append(row)
            continue
        key = (row.kind, row.role, row.name)
        if key in seen:
            seen[key].count += 1
            continue
        seen[key] = row
        collapsed.append(row)
    return collapsed


def columns(nodes: list[Node], width: float) -> list[tuple[float, float, str]]:
    """顶层分栏：宽而高的容器按 x 排序，用来对「左栏多宽、右栏从哪儿开始」。"""
    canvas = max((node.w for node in nodes), default=width)
    result: list[tuple[float, float, str]] = []
    seen: set[tuple[int, int, int, int]] = set()
    for node in sorted(nodes, key=lambda n: (n.x, n.y)):
        if node.role in {"window", "application"} or node.depth > 4:
            continue
        if node.w < width * 0.08 or node.h < 200:
            continue
        # 铺满整个窗口的容器是根节点，不是一栏，列出来只会淹没真正的分栏。
        if node.w >= canvas * 0.98:
            continue
        signature = (round(node.x), round(node.y), round(node.w), round(node.h))
        if signature in seen:
            continue
        if any(abs(node.x - x) < 2 and abs(node.w - w) < 2 for x, w, _ in result):
            continue
        seen.add(signature)
        result.append((node.x, node.w, node.role))
    return result


def role_census(rows: list[Row]) -> list[tuple[str, list[int]]]:
    """按角色统计，用来判断「这一栏是真的缺，还是两种实现暴露方式不同」。"""
    order = list(KINDS)
    roles: dict[str, list[int]] = {}
    for row in rows:
        roles.setdefault(row.role, [0] * len(order))[order.index(row.kind)] += 1
    return sorted(roles.items(), key=lambda entry: -sum(entry[1]))


def render_html(surface: str, rows: list[Row], reference_nodes: list[Node],
                replica_nodes: list[Node], matched: int, shot: Path | None) -> str:
    counts = {kind: sum(1 for row in rows if row.kind == kind) for kind in KINDS}
    stats = "".join(
        f'<div class="stat{" bad" if kind in {"missing", "extra", "state"} and counts[kind] else ""}">'
        f"<b>{counts[kind]}</b><span>{KINDS[kind]}</span></div>"
        for kind in KINDS
    )

    sections = []
    for kind, title in KINDS.items():
        subset = [row for row in rows if row.kind == kind]
        if not subset:
            continue
        body = "".join(
            f"<tr><td class='n'>{index + 1}</td><td class='role'>{html.escape(row.role)}</td>"
            f"<td class='name'>{html.escape(row.name)}</td><td class='detail'>{html.escape(row.text)}</td></tr>"
            for index, row in enumerate(subset)
        )
        sections.append(
            f"<h2>{title}<span class='count'>{len(subset)}</span></h2>"
            f"<div class='scroll'><table><thead><tr><th>#</th><th>角色</th><th>名字</th>"
            f"<th>说明</th></tr></thead><tbody>{body}</tbody></table></div>"
        )
    if not sections:
        sections.append("<p class='ok'>两侧的具名控件完全对得上，位置、尺寸和可用状态都在阈值以内。</p>")

    left = columns(reference_nodes, 1642)
    right = columns(replica_nodes, 1642)
    column_rows = "".join(
        f"<tr><td>第 {index + 1} 栏</td><td>{lw:.0f} pt @ x={lx:.0f}</td>"
        f"<td>{rw:.0f} pt @ x={rx:.0f}</td>"
        f"<td>{'一致' if abs(lw - rw) <= 2 and abs(lx - rx) <= 2 else '不一致'}</td></tr>"
        for index, ((lx, lw, _), (rx, rw, _)) in enumerate(zip(left, right))
    )
    column_block = (
        "<h2>顶层分栏</h2><div class='scroll'><table><thead><tr><th>栏</th><th>参考</th>"
        f"<th>Arbor</th><th>结论</th></tr></thead><tbody>{column_rows}</tbody></table></div>"
        if column_rows else ""
    )

    census = role_census(rows)
    census_columns = "".join(f"<th>{title}</th>" for title in KINDS.values())
    census_rows = "".join(
        f"<tr><td class='role'>{html.escape(role)}</td>"
        + "".join(f"<td>{count}</td>" for count in counts) + "</tr>"
        for role, counts in census
    )
    census_block = (
        f"<h2>按角色统计</h2><div class='scroll'><table><thead><tr><th>角色</th>"
        f"{census_columns}</tr></thead><tbody>{census_rows}</tbody></table></div>"
    ) if census_rows else ""

    screenshot = (
        f"<h2>参考界面</h2><img class='shot' src='data:image/png;base64,"
        f"{base64.b64encode(shot.read_bytes()).decode()}' alt='参考界面'>"
        if shot else ""
    )

    reference_named = len(comparable(reference_nodes))
    replica_named = len(comparable(replica_nodes))
    coverage = matched / reference_named * 100 if reference_named else 0

    return f"""<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>控件对账 · {html.escape(surface)}</title>
<style>
  :root {{ color-scheme: light dark; --fg:#1c1c1e; --dim:#6b6b70; --line:#d8d8dc;
           --bg:#fff; --panel:#f5f5f7; --bad:#b3261e; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --fg:#f2f2f7; --dim:#9a9aa0; --line:#3a3a3e; --bg:#141416;
             --panel:#1e1e21; --bad:#ff6b5e; }}
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; padding:24px 20px 60px; background:var(--bg); color:var(--fg);
          font:15px/1.55 -apple-system, "SF Pro Text", "PingFang SC", system-ui, sans-serif; }}
  h1 {{ font-size:19px; margin:0 0 4px; }}
  .sub {{ color:var(--dim); font-size:13px; margin-bottom:20px; }}
  .stats {{ display:flex; flex-wrap:wrap; gap:10px; margin-bottom:8px; }}
  .stat {{ background:var(--panel); border:1px solid var(--line); border-radius:10px;
           padding:10px 14px; min-width:112px; }}
  .stat b {{ display:block; font-size:20px; font-variant-numeric:tabular-nums; }}
  .stat span {{ color:var(--dim); font-size:12px; }}
  .stat.bad b {{ color:var(--bad); }}
  h2 {{ font-size:15px; margin:26px 0 10px; padding-bottom:6px; border-bottom:1px solid var(--line);
        display:flex; align-items:baseline; gap:8px; }}
  .count {{ color:var(--dim); font-size:13px; font-weight:400; }}
  table {{ width:100%; border-collapse:collapse; font-size:13px; }}
  th, td {{ text-align:left; padding:7px 8px; border-bottom:1px solid var(--line);
            vertical-align:top; font-variant-numeric:tabular-nums; }}
  th {{ color:var(--dim); font-weight:600; font-size:12px; }}
  td.n {{ color:var(--dim); width:2.2em; }}
  td.role {{ color:var(--dim); white-space:nowrap; }}
  td.name {{ font-weight:500; word-break:break-word; }}
  td.detail {{ color:var(--dim); }}
  .scroll {{ overflow-x:auto; }}
  .shot {{ display:block; width:100%; height:auto; border:1px solid var(--line); border-radius:10px; }}
  .ok {{ color:var(--dim); }}
  .note {{ color:var(--dim); font-size:12.5px; margin-top:22px; line-height:1.7; }}
  code {{ background:var(--panel); padding:1px 5px; border-radius:4px; font-size:12px; }}
</style></head><body>

<h1>控件对账：Arbor vs 参考实现</h1>
<div class="sub">{html.escape(surface)} · 参考 {reference_named} 个具名节点 · Arbor {replica_named} 个 ·
  配对上 {matched} 个（{coverage:.0f}%）</div>

<div class="stats">{stats}</div>

{screenshot}
{''.join(sections)}
{column_block}
{census_block}

<p class="note">
数据来源：两侧的无障碍树导出（<code>build/parity/tree/rebased-{html.escape(surface)}.txt</code>
与 <code>arbor-{html.escape(surface)}.txt</code>）。坐标已归一化到窗口原点，单位 pt。<br>
先看「参考有 · Arbor 缺」：这些是参考实现里用户点得到、而 Arbor 里根本没有入口的东西。<br>
「配对上」偏低不一定代表缺控件——两种实现的暴露方式不同（图标按钮、自绘列表项可能
没有文字标签），所以配不上的文本类节点要结合截图判断。
</p>
</body></html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default="build/parity", help="导出目录（默认 build/parity）")
    parser.add_argument("--surface", default=None, help="只处理某个界面，如 commit / log")
    parser.add_argument("--move-threshold", type=float, default=3.0,
                        help="位置/尺寸差多少 pt 以上算不一致（默认 3）")
    parser.add_argument("--markdown", action="store_true", help="同时写出 markdown 表格")
    parser.add_argument("--limit", type=int, default=8, help="终端里每类最多列几条（默认 8）")
    args = parser.parse_args()

    root = Path(args.dir)
    tree_dir = root / "tree"
    if not tree_dir.is_dir():
        print(f"没有找到无障碍树导出目录 {tree_dir}，先跑 ./scripts/ui-parity.sh", file=sys.stderr)
        return 2

    discovered = {
        path.name.split("-", 1)[1].rsplit(".", 1)[0]
        for path in tree_dir.glob("arbor-*.txt")
    }
    surfaces = [args.surface] if args.surface else sorted(discovered)
    if not surfaces:
        print(f"{tree_dir} 里没有 arbor-*.txt，先跑 ./scripts/ui-parity.sh", file=sys.stderr)
        return 2

    exit_code = 0
    for surface in surfaces:
        reference_path = tree_dir / f"rebased-{surface}.txt"
        replica_path = tree_dir / f"arbor-{surface}.txt"
        if not replica_path.exists():
            print(f"跳过 {surface}：缺少 {replica_path}", file=sys.stderr)
            exit_code = 1
            continue
        if not reference_path.exists():
            print(
                f"跳过 {surface}：缺少参考导出 {reference_path}\n"
                f"  在装了 Rebased、且已经在它里面打开 visual-fixture 项目的机器上跑：\n"
                f"    ./scripts/ui-parity.sh --reference",
                file=sys.stderr,
            )
            exit_code = 1
            continue

        reference_nodes = parse_tree(reference_path)
        replica_nodes = parse_tree(replica_path)
        pairing = pair(comparable(reference_nodes), comparable(replica_nodes))
        rows = build_rows(pairing, args.move_threshold)

        shot = root / "png" / f"rebased-{surface}.png"
        (root / f"{surface}-controls.html").write_text(
            render_html(surface, rows, reference_nodes, replica_nodes,
                        len(pairing.matched), shot if shot.exists() else None),
            encoding="utf-8",
        )
        (root / f"{surface}-controls.json").write_text(
            json.dumps({
                "surface": surface,
                "matched": len(pairing.matched),
                "reference_named": len(comparable(reference_nodes)),
                "replica_named": len(comparable(replica_nodes)),
                "rows": [row.__dict__ for row in rows],
            }, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        if args.markdown:
            (root / f"{surface}-controls.md").write_text(render_markdown(surface, rows), encoding="utf-8")

        counts = {kind: sum(1 for row in rows if row.kind == kind) for kind in KINDS}
        coverage = len(pairing.matched) / max(len(comparable(reference_nodes)), 1) * 100
        left_canvas, right_canvas = canvas(reference_nodes), canvas(replica_nodes)
        if max(abs(left_canvas[0] - right_canvas[0]), abs(left_canvas[1] - right_canvas[1])) > 2:
            print(f"  注意：两侧画布不一样大（参考 {left_canvas[0]:.0f}×{left_canvas[1]:.0f} vs "
                  f"Arbor {right_canvas[0]:.0f}×{right_canvas[1]:.0f} pt）。"
                  f"右侧的「位置不一致」要先排除这个原因：窗口被屏幕宽度限住了。")
        print(f"\n{surface}: 参考 {len(comparable(reference_nodes))} 个具名节点，"
              f"配对上 {len(pairing.matched)} 个（{coverage:.0f}%）")
        for kind, title in KINDS.items():
            print(f"  {title:<18}{counts[kind]:4d}")
        for kind in ("missing", "extra", "state"):
            subset = [row for row in rows if row.kind == kind][:args.limit]
            if subset:
                print(f"  {KINDS[kind]}：")
                for row in subset:
                    print(f"    · {row.role} {row.name!r} — {row.text}")
        print(f"  → {root / f'{surface}-controls.html'}")

    return exit_code


def render_markdown(surface: str, rows: list[Row]) -> str:
    counts = {kind: sum(1 for row in rows if row.kind == kind) for kind in KINDS}
    lines = [
        f"## {surface}", "",
        "| 类别 | 数量 |", "| --- | --- |",
        *(f"| {KINDS[kind]} | {counts[kind]} |" for kind in KINDS),
        "", "| 类别 | 角色 | 名字 | 说明 |", "| --- | --- | --- | --- |",
    ]
    for row in rows:
        name = row.name.replace("|", "\\|")
        detail = row.text.replace("|", "\\|")
        lines.append(f"| {KINDS[row.kind]} | {row.role} | {name} | {detail} |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
