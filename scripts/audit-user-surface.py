#!/usr/bin/env python3
"""对账「用户在 Rebased 里点得到的东西」与 Arbor 的实际入口。

`scripts/audit-git-actions.py` 是自下而上的：枚举 git4idea 注册的 action/group id，
再看 parity 矩阵有没有提到。它回答不了三件事，这三件事都会让功能悄悄漏掉：

1. 平台动作。`Vcs.ShowHistoryForBlock` 这类 id 由 platform 注册、只被 Git 菜单引用，
   既不进 git4idea 的 174 个 id，也不会有 parity 矩阵行——它从来没被核销过。
2. 装配关系。`<add-to-group group-id anchor relative-to-action>` 决定用户在哪一层菜单
   里点得到；id 存在不等于入口可达。
3. 面板与工具窗。Commit / Stage / Log / Saved Patches / Working Trees 不是 action，
   矩阵只记 controller 不记「用户在哪看见它」。

本脚本把三份描述文件里的 action/group/attach 关系还原成用户可见的 surface 树，
再把每个叶子节点归到四类之一：

    covered    parity 矩阵有行（功能已按 id 核销）
    declared   git4idea 声明的 action，但没有矩阵行
    platform   被 Git 菜单引用、但不是 git4idea 声明的平台动作
    container  分组容器，本身不承载功能

`declared` 与 `platform` 都必须由人在 baseline 里逐条给结论，否则脚本失败。
这样「从来没被核销过的平台动作」不会第二次从审计里漏过去。

用法：
  python3 scripts/audit-user-surface.py                # 人读：surface 树 + 缺口
  python3 scripts/audit-user-surface.py --json         # 机器读
  python3 scripts/audit-user-surface.py --surface log  # 只打一棵树
  python3 scripts/audit-user-surface.py --write-baseline
  python3 scripts/audit-user-surface.py --write-snapshot scripts/user-surface.json
  python3 scripts/audit-user-surface.py --snapshot scripts/user-surface.json

`--intellij` 指向 intellij-community 仓库里的 `plugins/git4idea`，默认
`/Users/arix/src/rebased/plugins/git4idea`。找不到源码时打印提示并退出 0，
方便在没有参考源码的机器上跑 CI。

`scripts/user-surface.json` 是从参考源码还原出来的 surface 快照，**故意提交进
仓库**：它是外部仓库的派生数据，不从本项目源码生成。CI 没装参考源码，所以用
`--snapshot` 复核台账；改了参考端或基线时重新 `--write-snapshot`。

baseline 文件每行 `<verdict>\t<id>\t<note>`，verdict 取值：

    covered         矩阵记不下但 Arbor 有等价入口（平台 id、class-only action）
    accepted-gap    确认缺失，待补
    out-of-scope    明确不复刻（IDE 宿主能力、插件平台、纯布局）
    not-a-surface   平台动作，但在原生应用里没有用户可见面（如 Jump to Source）
    container       平台分组，参考描述文件里没有子节点可展开

`covered` 与 `not-a-surface` 都是人工结论，脚本只负责把没有结论的项拦住。
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_INTELLIJ = Path("/Users/arix/src/rebased/plugins/git4idea")

DESCRIPTORS = (
    "backend/resources/intellij.vcs.git.backend.xml",
    "shared/resources/intellij.vcs.git.shared.xml",
    "frontend/resources/intellij.vcs.git.frontend.xml",
)

BUNDLES = (
    "shared/resources/messages/GitBundle.properties",
    "frontend/resources/messages/GitFrontendBundle.properties",
)

# 平台动作（`Vcs.ShowHistoryForBlock` 这类）的文案在 platform 的资源里。
# 这些路径相对 git4idea 模块，仓库不在同一台机器上时自动跳过。
PLATFORM_BUNDLES = (
    "../../platform/platform-resources-en/src/messages/ActionsBundle.properties",
    "../../platform/dvcs-impl/shared/resources/messages/DvcsBundle.properties",
)

# 用户实际浏览路径，顺序即文档顺序。每项是一个 surface：名字、说明、根分组。
SURFACES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("vcs-menu", "主菜单 VCS > Git", ("Git.MainMenu",)),
    ("local-changes", "Local Changes / Uncommitted Changes 子菜单",
     ("Git.MainMenu.LocalChanges",)),
    ("file-actions", "文件动作分组", ("Git.FileActions",)),
    ("file-context", "项目树 / 文件右键", ("Git.ContextMenu",)),
    ("changes-view", "Changes 视图右键", ("ChangesViewPopupMenu",)),
    ("stage", "Stage 工具窗",
     ("Git.Stage.Tree.Menu", "Git.Stage.Index.File.Menu",
      "Git.Stage.Local.File.Menu", "Git.Stage.Toolbar")),
    ("log", "Log 工具窗",
     ("Git.Log.ContextMenu", "Git.Log.Toolbar", "Git.Log.Branches.Settings")),
    ("branches", "Branches 弹窗",
     ("Git.Branch.Backend", "Git.Branches.List", "Git.Branches.Popup.Settings")),
    ("stash", "Stash / Shelf", ("Git.Stash.Operations.ContextMenu",)),
    ("hosting", "托管平台",
     ("Git.Hosting.Open.In.Browser.Group", "Git.Hosting.Copy.Link.Group")),
    ("working-trees", "Working Trees",
     ("Git.WorkingTrees.ToolwindowGroup.Toolbar",
      "Git.WorkingTrees.ToolwindowGroup.Popup")),
    ("toolbar", "工具栏 / VCS widget",
     ("VcsToolbarActions", "SegmentedVcsActionsBarGroup",
      "Vcs.ToolbarWidget.CreateRepository", "MainToolbarVCSGroup")),
    ("ongoing", "进行中操作恢复",
     ("GitMergeRebaseWidgetGroup", "Git.Ongoing.Rebase.Actions")),
)

# 平台分组：被 Git 菜单引用、但子节点在 platform 描述文件里，本脚本无法展开。
PLATFORM_GROUPS = {
    "ChangesViewPopupMenu",
    "ChangesView.GroupBy",
    "ContextHelp",
    "MainToolbarVCSGroup",
    "Patch.MainMenu",
    "SegmentedVcsActionsBarGroup",
    "VcsToolbarActions",
}

VERDICTS = ("covered", "accepted-gap", "out-of-scope", "not-a-surface", "container")


# --------------------------------------------------------------------------
# 参考端：把 XML 还原成 surface 树
# --------------------------------------------------------------------------

def unescape_properties(value: str) -> str:
    """Properties 里的 \\u2026 之类在这里还原成真字符。"""
    if "\\u" not in value:
        return value
    try:
        return value.encode("utf-8").decode("unicode_escape")
    except UnicodeDecodeError:
        return value


def load_bundles(intellij: Path) -> dict[str, str]:
    props: dict[str, str] = {}
    # 先读 git4idea 自己的 bundle，再用 platform 的补上平台动作的文案。
    for rel in BUNDLES + PLATFORM_BUNDLES:
        path = intellij / rel
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            props.setdefault(key.strip(), unescape_properties(value.strip()))
    return props


class Surface:
    """一个 surface 图：节点 id -> 节点信息。"""

    def __init__(self) -> None:
        self.kind: dict[str, str] = {}          # id -> action | group
        self.klass: dict[str, str | None] = {}
        self.children: dict[str, list[str]] = {}
        self.attached: dict[str, list[tuple[str, str | None, str | None]]] = {}
        self.declared: set[str] = set()          # git4idea 自己声明的 id
        self.separators: dict[str, list[str]] = {}

    def child_order(self, group_id: str) -> list[str]:
        """按嵌套声明顺序叠加 add-to-group 装配结果。"""
        order = list(self.children.get(group_id, []))
        for child, relative_to, anchor in self.attached.get(group_id, []):
            if relative_to and relative_to in order:
                index = order.index(relative_to)
                order.insert(index if anchor == "before" else index + 1, child)
            elif anchor == "first":
                order.insert(0, child)
            else:
                order.append(child)
        # 同名分组可能被多个文件重复装配，保留首次出现。
        seen: set[str] = set()
        unique: list[str] = []
        for child in order:
            if child in seen:
                continue
            seen.add(child)
            unique.append(child)
        return unique


def parse_descriptor(path: Path, surface: Surface) -> None:
    """遍历一份描述文件，收集嵌套子节点与装配边。"""

    def walk(node: ET.Element, group_id: str | None) -> None:
        for child in node:
            tag = child.tag.split("}")[-1]
            if tag == "separator":
                if group_id:
                    surface.separators.setdefault(group_id, []).append("---")
                continue
            if tag == "reference":
                ref = child.get("ref")
                if group_id and ref:
                    surface.children.setdefault(group_id, []).append(ref)
                continue
            if tag not in ("action", "group"):
                continue
            node_id = child.get("id") or f"class:{child.get('class', '')}"
            surface.kind.setdefault(node_id, tag)
            surface.klass.setdefault(node_id, child.get("class"))
            surface.declared.add(node_id)
            surface.children.setdefault(node_id, [])
            if group_id:
                surface.children.setdefault(group_id, []).append(node_id)
            for sub in child:
                if sub.tag.split("}")[-1] != "add-to-group":
                    continue
                target = sub.get("group-id")
                if not target:
                    continue
                surface.attached.setdefault(target, []).append(
                    (node_id, sub.get("relative-to-action"), sub.get("anchor"))
                )
            if tag == "group":
                walk(child, node_id)

    root = ET.parse(path).getroot()
    for node in root:
        tag = node.tag.split("}")[-1]
        if tag == "actions":
            walk(node, None)
        elif tag == "group":
            node_id = node.get("id") or f"class:{node.get('class', '')}"
            surface.kind.setdefault(node_id, "group")
            surface.klass.setdefault(node_id, node.get("class"))
            surface.declared.add(node_id)
            surface.children.setdefault(node_id, [])
            for sub in node:
                if sub.tag.split("}")[-1] == "add-to-group" and sub.get("group-id"):
                    surface.attached.setdefault(sub.get("group-id"), []).append(
                        (node_id, sub.get("relative-to-action"), sub.get("anchor"))
                    )
            walk(node, node_id)


def build_surface(intellij: Path) -> Surface:
    surface = Surface()
    for rel in DESCRIPTORS:
        path = intellij / rel
        if path.is_file():
            parse_descriptor(path, surface)
    return surface


# --------------------------------------------------------------------------
# 本端：矩阵、文案目录
# --------------------------------------------------------------------------

def load_matrix(path: Path) -> dict[str, dict]:
    if not path.is_file():
        return {}
    return {row["intellij_action_id"]: row for row in csv.DictReader(path.open())}


def load_catalog(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    return {normalize(key) for key in data.get("strings", {})}


def normalize(text: str) -> str:
    text = text.replace("\u2026", "...").replace("...", "")
    text = re.sub(r"[_&]", "", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def load_baseline(path: Path) -> dict[str, tuple[str, str]]:
    """id -> (verdict, note)。"""
    entries: dict[str, tuple[str, str]] = {}
    if not path.is_file():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        verdict, node_id = parts[0].strip(), parts[1].strip()
        note = parts[2].strip() if len(parts) > 2 else ""
        entries[node_id] = (verdict, note)
    return entries


# --------------------------------------------------------------------------
# 归类与报告
# --------------------------------------------------------------------------

def class_candidates(klass: str) -> list[str]:
    """`a.b.Outer$Inner` 既要能匹配 `Outer$Inner`，也要能匹配 `Inner`。"""
    base = klass.rsplit(".", 1)[-1]
    names = [base]
    if "$" in base:
        names.append(base.split("$", 1)[1])
    return names


def build_matrix_index(path: Path) -> tuple[dict[str, dict], dict[str, dict]]:
    """返回 (id -> 行, class 短名 -> 行)。

    git4idea 里有一批 action 只声明 class、没有 id（例如
    `GitRebaseBranchAction`）。矩阵用 `(ClassName)` 这种合成 id 记它们，
    所以再建一个 class 索引。
    """
    rows = load_matrix(path)
    by_class: dict[str, dict] = {}
    for row in rows.values():
        klass = row.get("intellij_action_class", "").strip()
        if not klass or klass in ("-", "current verification override"):
            continue
        for name in class_candidates(klass):
            by_class.setdefault(name, row)
    return rows, by_class


def classify(node_id: str, kind: str, origin: str, matrix: dict[str, dict],
             by_class: dict[str, dict],
             baseline: dict[str, tuple[str, str]]) -> tuple[str, str]:
    """返回 (覆盖类别, 明细分)。origin 为 git4idea 或 platform。"""
    if node_id in PLATFORM_GROUPS:
        return "container", "platform group"
    if kind == "group":
        return "container", ""
    if node_id in matrix:
        return "covered", matrix[node_id]["status"]
    if node_id.startswith("class:"):
        for name in class_candidates(node_id[len("class:"):]):
            if name in by_class:
                return "covered", by_class[name]["status"]
            synthetic = f"({name})"
            if synthetic in matrix:
                return "covered", matrix[synthetic]["status"]
    if node_id in baseline:
        return baseline[node_id][0], baseline[node_id][1]
    return ("declared" if origin == "git4idea" else "platform"), ""


def collect_surface(surface: Surface, roots: tuple[str, ...],
                    props: dict[str, str]) -> list[dict]:
    """深度优先展开一棵 surface 树，返回带归类的节点列表。"""
    rows: list[dict] = []
    seen: set[str] = set()

    # 直接从 bundle 建 id -> 文案，包括平台动作（它们不在 surface.kind 里）。
    labels: dict[str, str] = {}
    for key, value in props.items():
        for prefix in ("action.", "group."):
            if key.startswith(prefix) and key.endswith(".text"):
                labels.setdefault(key[len(prefix):-len(".text")], value)
                break

    def label(node_id: str) -> str:
        if node_id in labels:
            return labels[node_id].replace("_", "")
        if node_id == "$Delete":
            return "Delete"
        if node_id.startswith("class:"):
            bare = node_id[len("class:"):]
            for name in class_candidates(bare):
                if name in labels:
                    return labels[name].replace("_", "")
            return bare.rsplit(".", 1)[-1].split("$")[-1]
        return node_id

    def walk(node_id: str, depth: int, trail: tuple[str, ...]) -> None:
        if node_id in trail or node_id in seen:
            return
        seen.add(node_id)
        # 被引用但未在 git4idea 里声明的 id 是平台动作；它们没有子节点，按叶子算。
        node_kind = "group" if node_id in PLATFORM_GROUPS else surface.kind.get(node_id, "action")
        origin = "git4idea" if node_id in surface.declared else "platform"
        text = label(node_id)
        rows.append({
            "id": node_id,
            "label": text,
            "depth": depth,
            "kind": node_kind,
            "class": surface.klass.get(node_id),
            "origin": origin,
        })
        for child in surface.child_order(node_id):
            walk(child, depth + 1, trail + (node_id,))
        seen.discard(node_id)

    for root in roots:
        walk(root, 0, ())
    return rows


def classify_rows(rows: list[dict], matrix: dict[str, dict],
                  by_class: dict[str, dict],
                  baseline: dict[str, tuple[str, str]],
                  catalog: set[str]) -> list[dict]:
    """给结构行补上覆盖类别；快照与实时解析共用这一条路径。"""
    for row in rows:
        state, detail = classify(row["id"], row["kind"], row["origin"],
                                 matrix, by_class, baseline)
        row["state"] = state
        row["detail"] = detail
        row["label_in_arbor"] = normalize(row["label"]) in catalog
    return rows


def write_snapshot(path: Path, report: dict[str, list[dict]],
                   titles: dict[str, str]) -> None:
    keys = ("id", "label", "depth", "kind", "class", "origin")
    payload = {
        "generated_from": "git4idea descriptors",
        "surfaces": {
            name: {"title": titles.get(name, name),
                   "nodes": [{key: row.get(key) for key in keys} for row in rows]}
            for name, rows in report.items()
        },
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def load_snapshot(path: Path) -> dict[str, list[dict]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {name: entry["nodes"] for name, entry in payload["surfaces"].items()}


def write_baseline(path: Path, gaps: list[tuple[str, str]]) -> None:
    lines = [
        "# 用户可见 surface 的人工判定台账。",
        "# 每行：<verdict>\\t<id>\\t<note>",
        "# verdict: covered | accepted-gap | out-of-scope | not-a-surface | container",
        "# covered 表示 Arbor 有等价入口，但矩阵无法记录（平台 id 或 class-only action）。",
        "# 生成：python3 scripts/audit-user-surface.py --write-baseline",
        "",
    ]
    for node_id, note in sorted(gaps):
        lines.append(f"accepted-gap\t{node_id}\t{note}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--intellij", type=Path, default=DEFAULT_INTELLIJ)
    ap.add_argument("--matrix", type=Path, default=Path("docs/git-parity-matrix.csv"))
    ap.add_argument("--catalog", type=Path, default=Path("Arbor/Localizable.xcstrings"))
    ap.add_argument("--baseline", type=Path,
                    default=Path("scripts/user-surface-baseline.txt"))
    ap.add_argument("--surface", help="只打印指定 surface")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--write-baseline", action="store_true",
                    help="把当前未判定的缺口写进 baseline")
    ap.add_argument("--write-snapshot", type=Path,
                    help="把还原出的 surface 树存成快照（可提交，供无参考源码的机器复核）")
    ap.add_argument("--snapshot", type=Path,
                    help="从快照读取 surface 树，不解析参考源码")
    args = ap.parse_args()

    matrix, by_class = build_matrix_index(args.matrix)
    catalog = load_catalog(args.catalog)
    baseline = load_baseline(args.baseline)

    selected = [s for s in SURFACES if not args.surface or s[0] == args.surface]
    if args.surface and not selected:
        known = ", ".join(s[0] for s in SURFACES)
        print(f"unknown surface {args.surface!r}; known: {known}", file=sys.stderr)
        return 2

    if args.snapshot:
        if not args.snapshot.is_file():
            print(f"snapshot not found at {args.snapshot}", file=sys.stderr)
            return 2
        loaded = load_snapshot(args.snapshot)
        report = {name: loaded[name] for name, _t, _r in selected if name in loaded}
    else:
        if not args.intellij.is_dir():
            print(f"git4idea source not found at {args.intellij}; nothing to audit",
                  file=sys.stderr)
            return 0
        surface = build_surface(args.intellij)
        props = load_bundles(args.intellij)
        report = {name: collect_surface(surface, roots, props)
                  for name, _title, roots in selected}

    declared_ids = {row["id"] for rows in report.values() for row in rows
                    if row["origin"] == "git4idea"}

    for rows in report.values():
        classify_rows(rows, matrix, by_class, baseline, catalog)

    if args.write_snapshot:
        titles = {name: title for name, title, _roots in SURFACES}
        write_snapshot(args.write_snapshot, report, titles)
        print(f"snapshot written: {args.write_snapshot}")
        return 0

    leaves = [row for rows in report.values() for row in rows
              if row["kind"] == "action"]
    undecided = [row for row in leaves if row["state"] in ("declared", "platform")]
    covered = [row for row in leaves if row["state"] == "covered"]
    accepted = [row for row in leaves
                if row["state"] in ("accepted-gap", "out-of-scope", "not-a-surface")]

    # 同一个动作会在多个 surface 里出现；台账按 id 记一次。
    undecided_by_id: dict[str, dict] = {}
    for name, rows in report.items():
        for row in rows:
            if row["kind"] != "action" or row["state"] not in ("declared", "platform"):
                continue
            undecided_by_id.setdefault(row["id"], {**row, "surfaces": []})
            undecided_by_id[row["id"]]["surfaces"].append(name)

    if args.write_baseline:
        write_baseline(args.baseline,
                       [(row["id"], row["label"]) for row in undecided_by_id.values()])
        print(f"baseline written: {args.baseline} ({len(undecided_by_id)} entries)")
        return 0

    if args.json:
        json.dump({
            "surfaces": {
                name: [row for row in rows if row["kind"] == "action"]
                for name, rows in report.items()
            },
            "summary": {
                "leaves": len(leaves),
                "covered": len(covered),
                "judged": len(accepted),
                "undecided": len(undecided_by_id),
            },
            "undecided": list(undecided_by_id.values()),
        }, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 1 if undecided_by_id else 0

    print(f"git4idea-declared ids : {len(declared_ids)}")
    print(f"visible leaves        : {len(leaves)}")
    print(f"covered by matrix     : {len(covered)}")
    print(f"judged in baseline    : {len(accepted)}")
    print(f"undecided             : {len(undecided_by_id)}")
    print()

    for name, title, _roots in selected:
        rows = report[name]
        leaf_rows = [row for row in rows if row["kind"] == "action"]
        if not leaf_rows:
            continue
        print(f"== {title} ({name}) — {len(leaf_rows)} 个动作")
        for row in rows:
            if row["kind"] == "group":
                if row["state"] == "container" and not row["depth"]:
                    print(f"    {row['label']}  <{row['id']}>")
                continue
            mark = {
                "covered": "✓",
                "declared": "?",
                "platform": "!",
                "accepted-gap": "×",
                "out-of-scope": "-",
                "not-a-surface": "n/a",
            }.get(row["state"], "?")
            print(f"  {mark:>3s} {'  ' * row['depth']}{row['label']}  [{row['id']}]")
        print()

    if undecided_by_id:
        print("未判定项（必须在 scripts/user-surface-baseline.txt 里给结论）:")
        for row in undecided_by_id.values():
            origin = "platform" if row["state"] == "platform" else "declared"
            where = ",".join(dict.fromkeys(row["surfaces"]))
            print(f"  {origin:9s} {row['id']:52s} {row['label']:38s} {where}")
        print("\n接受现状：python3 scripts/audit-user-surface.py --write-baseline")
        return 1

    gap_notes = {row["id"]: row["detail"] for row in accepted
                 if row["state"] == "accepted-gap"}
    if gap_notes:
        print(f"台账里还有 {len(gap_notes)} 个已知缺口:")
        for node_id, note in gap_notes.items():
            print(f"  × {node_id:52s} {note}")
        print("\n没有未判定项；补齐后把 baseline 对应行改成 covered。")
        return 0

    print("所有可见动作都已核销。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
