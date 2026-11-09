#!/usr/bin/env python3
"""判定对账报告里的「缺」到底是真缺，还是叫法/入口位置不同。

`ui-parity.py` 说「参考有这个控件、Arbor 的树里没有同名节点」。这句话不等于功能
没做：同一个功能可能在 Arbor 里叫另一个名字、放在另一个菜单里、或者暴露成另一种
角色。直接照着清单开发会重复造一遍已有功能。

这个脚本拿每个缺失的名字回查 Arbor 的源码和本地化表：出现过 → 功能在，是叫法或
入口位置的差异；一次都没出现 → 才值得排进开发清单。

用法：
  python3 scripts/ui-triage.py                 # 读写 build/parity/*-controls.json
  python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRS = ("Arbor",)
LOCALIZATION = "Arbor/Localizable.xcstrings"

# 参考里这些名字是自绘控件拼出来的句子，按整串回查没有意义。
# 这些角色名是参考平台给容器/表格起的名字，不是用户能看见的文案，回查没有意义。
STRUCTURAL_ROLES = {"outline", "outlinerow", "table", "cell", "tabgroup", "group", "other"}


def searchable(name: str) -> str | None:
    text = name.strip()
    if not text or len(text) < 3:
        return None
    # IDE 宿主能力，不是 Git 工作台的控件。
    if re.search(r"^(Psi\w+|IDE project settings)", text):
        return None
    # 表格行拼出来的句子（「Changes 2 files」），数字随仓库内容变。
    # 表格行拼出来的「X N files」「not checked」，不是可检索的控件文案。
    if re.search(r"(files?|not checked)$", text):
        return None
    text = re.sub(r"\b\d+\b", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    # 「App.swift src not checked」这种是表格行拼出来的，去掉状态尾巴。
    text = re.sub(r"\s+(not checked|checked|unchecked)$", "", text, flags=re.I)
    # 带动态内容的（路径、文件名、哈希）不当作可检索的字面量。
    if re.search(r"[<>/]", text) or not text:
        return None
    return text


def load_corpus() -> str:
    chunks: list[str] = []
    for directory in SOURCE_DIRS:
        for path in (ROOT / directory).rglob("*.swift"):
            if "ArborTests" in path.parts:
                continue
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
    localization = ROOT / LOCALIZATION
    if localization.exists():
        chunks.append(localization.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(chunks).casefold()


def locate(name: str, corpus: str) -> str | None:
    """返回命中的源文件名；没命中就是真缺的候选。"""
    needle = name.casefold()
    if needle not in corpus:
        return None
    for directory in SOURCE_DIRS:
        for path in (ROOT / directory).rglob("*.swift"):
            if "ArborTests" in path.parts:
                continue
            if needle in path.read_text(encoding="utf-8", errors="replace").casefold():
                return str(path.relative_to(ROOT))
    return LOCALIZATION


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default="build/parity", help="对账报告目录")
    parser.add_argument("--write-doc", default=None, help="把结果写成 markdown，如 docs/ui-gaps.md")
    args = parser.parse_args()

    report_dir = Path(args.dir)
    reports = sorted(report_dir.glob("*-controls.json"))
    if not reports:
        print(f"{report_dir} 里没有 *-controls.json，先跑 ./scripts/ui-parity.sh --reference",
              file=sys.stderr)
        return 2

    corpus = load_corpus()
    rows: list[dict] = []
    for report_path in reports:
        data = json.loads(report_path.read_text(encoding="utf-8"))
        surface = data.get("surface", report_path.stem)
        for row in data.get("rows", []):
            if row.get("kind") != "missing" or row.get("role") in STRUCTURAL_ROLES:
                continue
            name = row["name"]
            needle = searchable(name)
            where = locate(needle, corpus) if needle else None
            rows.append({
                "surface": surface,
                "role": row["role"],
                "name": name,
                "where": where,
                "searchable": needle,
            })

    found = [row for row in rows if row["where"]]
    absent = [row for row in rows if not row["where"] and row["searchable"]]

    print(f"「参考有 · Arbor 缺」{len(rows)} 条：")
    print(f"  源码里有 → 叫法/入口位置不同  {len(found)}")
    print(f"  源码里没有 → 疑似真缺          {len(absent)}")
    print("\n疑似真缺（值得排期）：")
    for row in absent:
        print(f"  · {row['surface']:<7} {row['role']:<10} {row['name']}")

    if args.write_doc:
        target = Path(args.write_doc)
        lines = [
            "# 界面对账得出的缺口清单", "",
            "由 `scripts/ui-triage.py` 从 `build/parity/*-controls.json` 生成，**不要手改**。",
            "重新生成：`./scripts/ui-parity.sh --reference && "
            "python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md`", "",
            "判定方法：把「参考有、Arbor 缺」的每个名字回查 Arbor 的源码和本地化表。"
            "源码里出现过的，说明功能在做、只是叫法或入口位置不同；一次都没出现的才是"
            "真缺。", "",
            "## 疑似真缺", "",
            "| 界面 | 角色 | 名字 |", "| --- | --- | --- |",
        ]
        for row in sorted(absent, key=lambda item: (item["surface"], item["name"])):
            lines.append(f"| {row['surface']} | {row['role']} | {row['name']} |")
        lines += ["", "## 源码里有：叫法或入口位置不同", "",
                  "| 界面 | 名字 | 出现在 |", "| --- | --- | --- |"]
        for row in sorted(found, key=lambda item: (item["surface"], item["name"])):
            lines.append(f"| {row['surface']} | {row['name']} | `{row['where']}` |")
        lines += ["", "## 附：无法通过源码检索判定的条目", "",
                  "名字里带路径、文件名或动态内容，回查没有意义，需要人工看截图。", ""]
        for row in rows:
            if not row["searchable"] or row["where"]:
                continue
            lines.append(f"- `{row['surface']}` {row['role']} `{row['name']}`")
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"\n→ {target}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
