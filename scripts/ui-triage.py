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
def load_aliases() -> dict[str, str]:
    """别名表把参考的叫法换成 Arbor 的叫法，回查要用 Arbor 那边的名字。"""
    path = ROOT / "scripts/parity-aliases.tsv"
    aliases: dict[str, str] = {}
    if not path.exists():
        return aliases
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = [cell.strip() for cell in line.split("\t")]
        if len(cells) >= 2:
            aliases[cells[0].casefold()] = cells[1]
    return aliases


ALIASES = load_aliases()
VERDICTS = (
    "to-build", "design-difference", "naming", "out-of-scope",
)


def load_verdicts() -> dict[str, tuple[str, str]]:
    """每条缺口的人工结论。和 user-surface-baseline.txt 同一个思路：
    脚本只负责把没有结论的项拦住，判断仍然是人给。
    """
    path = ROOT / "scripts/ui-gaps-baseline.txt"
    verdicts: dict[str, tuple[str, str]] = {}
    if not path.exists():
        return verdicts
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = [cell.strip() for cell in line.split("\t")]
        if len(cells) < 2 or cells[0] not in VERDICTS:
            continue
        verdicts[alias_key(cells[1])] = (cells[0], cells[2] if len(cells) > 2 else "")
    return verdicts




# 这些角色名是参考平台给容器/表格起的名字，不是用户能看见的文案，回查没有意义。
STRUCTURAL_ROLES = {"outline", "outlinerow", "table", "cell", "tabgroup", "group", "other"}


# 和 ui-parity.py 同一套归一化：省略号、尾随冒号、快捷键提示都不算差异。
NOISE = re.compile(r"\s*(?:\.{2,}|…|\(\s*[⌘⌥⌃⇧A-Za-z0-9+↩␣]+\s*\)|:)\s*$")


def alias_key(name: str) -> str:
    text = name.strip()
    previous = None
    while previous != text:
        previous = text
        text = NOISE.sub("", text).strip()
    return text.casefold()


def searchable(name: str) -> str | None:
    text = ALIASES.get(alias_key(name), name.strip())
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

    verdicts = load_verdicts()

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

    # 没有人工结论的条目拦住：不然清单会越挂越长，没人再信它。
    unjudged = [
        row for row in absent
        if alias_key(row["name"]) not in verdicts
    ]
    pending = [
        row for row in absent
        if verdicts.get(alias_key(row["name"]), ("",))[0] == "to-build"
    ]
    print(f"  其中已判为待补                {len(pending)}")
    print(f"  没有结论的需要补上            {len(unjudged)}")
    print("\n疑似真缺（值得排期）：")
    for row in absent:
        print(f"  · {row['surface']:<7} {row['role']:<10} {row['name']}")

    if unjudged:
        print("\n以下条目还没有结论，补进 scripts/ui-gaps-baseline.txt：", file=sys.stderr)
        for row in unjudged:
            print(f"  {row['surface']:<7} {row['role']:<10} {row['name']}", file=sys.stderr)

    if args.write_doc:
        target = Path(args.write_doc)

        def grouped(items):
            """按名字合并：同一个缺口在两个界面上都报时只写一行。"""
            merged = {}
            for item in items:
                key = alias_key(item["name"])
                verdict, note = verdicts.get(key, ("未结论", ""))
                merged.setdefault(key, {
                    "name": item["name"], "verdict": verdict, "note": note, "surfaces": set(),
                })["surfaces"].add(item["surface"])
            return list(merged.values())

        items = grouped(absent)
        pending = [item for item in items if item["verdict"] == "to-build"]
        judged = [item for item in items if item["verdict"] != "to-build"]

        text = [
            "# 界面对账得出的缺口清单", "",
            "由 `scripts/ui-triage.py` 生成，**不要手改**；人给的结论在",
            "`scripts/ui-gaps-baseline.txt` 里。", "",
            "重新生成：`./scripts/ui-parity.sh --reference &&",
            "python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md`", "",
            "判定方法：把「参考有、Arbor 缺」的每个名字回查 Arbor 的源码和本地化表。",
            "源码里有 → 功能在做、只是叫法或入口位置不同；没有 → 才进下面的清单，",
            "而且每一项都必须在 baseline 里给出结论，缺结论时脚本会失败。", "",
            "## 待补", "", "| 缺口 | 出现界面 | 说明 |", "| --- | --- | --- |",
        ]
        for item in pending:
            text.append(f"| {item['name']} | {', '.join(sorted(item['surfaces']))} | {item['note']} |")
        text += ["", "## 已判定：不复刻或已有等价入口", "",
                 "| 结论 | 缺口 | 界面 | 理由 |", "| --- | --- | --- | --- |"]
        for item in sorted(judged, key=lambda entry: entry["name"]):
            text.append(f"| {item['verdict']} | {item['name']} | "
                        f"{', '.join(sorted(item['surfaces']))} | {item['note']} |")
        text += ["", "## 附录：源码里有，只是叫法或入口位置不同", "",
                 "这些不是缺口。要压掉对账噪声，把它们写进 `scripts/parity-aliases.tsv`。", ""]
        for row in sorted(found, key=lambda item: (item["surface"], item["name"])):
            text.append(f"- `{row['surface']}` {row['role']} `{row['name']}` → `{row['where']}`")
        target.write_text("\n".join(text) + "\n", encoding="utf-8")
        print(f"\n→ {target}")

    return 1 if unjudged else 0


if __name__ == "__main__":
    sys.exit(main())
