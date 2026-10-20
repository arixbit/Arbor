#!/usr/bin/env python3
"""对账 Rebased(intellij-community) git4idea 的 action 全集与 Arbor 的 parity 矩阵。

用途：回答「还有哪些 Git action 没覆盖」。判定规则是反的——先枚举
git4idea 注册的全部 action/group id，再看矩阵里有没有提到；没提到的按
「容器」与「叶子」分开列，因为绝大多数未覆盖项是 context menu / toolbar /
gear popup 这类分组容器，本身不是功能。

用法：
  python3 scripts/audit-git-actions.py [--intellij PATH] [--matrix PATH]

`--intellij` 指向 intellij-community 仓库里的 `plugins/git4idea`，默认
`/Users/arix/src/rebased/plugins/git4idea`。找不到源码时打印提示并退出 0，
方便在没有参考源码的机器上跑 CI。
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

SKIP_MARKERS = ("/testResources/", "/tests/")


def collect(intellij: Path) -> dict[str, dict]:
    """id -> {tag, class, file, children[], references[]}"""
    ids: dict[str, dict] = {}
    for xml in sorted(intellij.rglob("*.xml")):
        rel = "/" + xml.as_posix()
        if any(marker in rel for marker in SKIP_MARKERS):
            continue
        text = xml.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"<(action|group)\b([^>]*)>", text):
            tag, attrs = match.group(1), match.group(2)
            id_match = re.search(r'\bid="([^"]+)"', attrs)
            if not id_match:
                continue
            action_id = id_match.group(1)
            class_match = re.search(r'\bclass="([^"]+)"', attrs)
            entry = ids.setdefault(action_id, {
                "tag": tag,
                "class": class_match.group(1) if class_match else None,
                "file": str(xml.relative_to(intellij)),
                "children": [],
                "references": [],
                "parents": [],
            })
            if tag == "group":
                body_match = re.search(
                    r"<group\b[^>]*\bid=\"%s\"[^>]*?>(.*?)</group>" % re.escape(action_id),
                    text,
                    re.S,
                )
                if body_match:
                    body = body_match.group(1)
                    entry["children"] = re.findall(r'<action\b[^>]*\bid="([^"]+)"', body)
                    entry["children"] += re.findall(r'<group\b[^>]*\bid="([^"]+)"', body)
                    entry["references"] = re.findall(r'<reference\b[^>]*\bref="([^"]+)"', body)
                tail = text[match.end(): match.end() + 2000]
                entry["parents"] = re.findall(r'<add-to-group group-id="([^"]+)"', tail)
    return ids


def matrix_text(path: Path) -> str:
    rows = list(csv.DictReader(path.open()))
    return "\n".join(" ".join(row.values()) for row in rows)


def classify(action_id: str, entry: dict, uncovered_children: list[str]) -> str:
    if entry["tag"] == "group":
        if entry["class"] and "ActionGroup" in entry["class"]:
            return "动作分组"
        if entry["class"] and ("Settings" in entry["class"] or "Filter" in entry["class"]):
            return "设置/过滤菜单"
        if entry["parents"]:
            return "上下文菜单/工具栏容器"
        return "占位/锚点分组"
    return "叶子动作"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--intellij", type=Path,
                    default=Path("/Users/arix/src/rebased/plugins/git4idea"))
    ap.add_argument("--matrix", type=Path, default=Path("docs/git-parity-matrix.csv"))
    ap.add_argument("--json", action="store_true", help="输出机器可读结果")
    args = ap.parse_args()

    if not args.intellij.is_dir():
        print(f"git4idea source not found at {args.intellij}; nothing to audit", file=sys.stderr)
        return 0
    if not args.matrix.is_file():
        print(f"parity matrix not found at {args.matrix}", file=sys.stderr)
        return 2

    ids = collect(args.intellij)
    blob = matrix_text(args.matrix)
    uncovered = sorted(i for i in ids if i not in blob)

    report = []
    for action_id in uncovered:
        entry = ids[action_id]
        uncovered_children = [
            child for child in entry["children"] + entry["references"] if child not in blob
        ]
        report.append({
            "id": action_id,
            "kind": classify(action_id, entry, uncovered_children),
            "tag": entry["tag"],
            "class": entry["class"],
            "file": entry["file"],
            "children": entry["children"] + entry["references"],
            "uncovered_children": uncovered_children,
            "parents": entry["parents"],
        })

    if args.json:
        json.dump({"total": len(ids), "uncovered": report}, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0

    leaves = [r for r in report if r["tag"] == "action"]
    print(f"git4idea registered ids : {len(ids)}")
    print(f"matrix mentions          : {len(ids) - len(uncovered)}")
    print(f"uncovered                : {len(uncovered)}  "
          f"(groups {len(report) - len(leaves)}, actions {len(leaves)})")
    print()
    for item in report:
        print(f"{item['id']:44s} {item['kind']:14s} {item['file']}")
        if item["children"]:
            print(f"{'':44s} children={len(item['children'])} "
                  f"uncovered={item['uncovered_children'] or 'none'}")
    if leaves:
        print("\n叶子动作（真正需要补的功能入口）:")
        for item in leaves:
            print(f"  {item['id']}")
    else:
        print("\n没有未覆盖的叶子动作：所有未覆盖项都是容器。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
