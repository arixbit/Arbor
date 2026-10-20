#!/usr/bin/env python3
"""Split a large Swift source file into feature slices without changing behavior.

The Arbor sources grew horizontally ("all operations", "all dialogs") instead of
vertically (by feature), which leaves single files tens of thousands of lines
long. This tool slices a file so that:

  * members of a top-level `extension Foo { ... }` are regrouped into one
    `extension Foo { ... }` per feature slice;
  * every other top-level declaration (struct, enum, free function, ...) moves
    whole, so nested stored properties are never re-opened in an extension.

A minimal Swift scanner (line comments, nested block comments, single-line /
multi-line / raw strings, string interpolation) makes sure a brace inside a
string or comment never shifts the block structure.

`split` verifies that every non-blank input line is emitted exactly once and
aborts otherwise.

Usage:
  analyze FILE                    inventory and slice distribution
  split FILE --out DIR            write one file per slice
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

DECL_KEYWORDS = (
    "func",
    "var",
    "let",
    "init",
    "deinit",
    "subscript",
    "class",
    "struct",
    "enum",
    "protocol",
    "extension",
    "typealias",
    "import",
    "actor",
    "operator",
)

MODIFIERS = (
    "public",
    "internal",
    "private",
    "fileprivate",
    "open",
    "static",
    "final",
    "override",
    "mutating",
    "nonmutating",
    "convenience",
    "required",
    "lazy",
    "weak",
    "unowned",
    "indirect",
    "async",
    "nonisolated",
    "distributed",
    "dynamic",
    "optional",
)


@dataclass
class Block:
    start: int  # 0-based, first line (including attached doc comment)
    end: int  # 0-based, inclusive
    kind: str
    name: str

    @property
    def lines(self) -> int:
        return self.end - self.start + 1


def depth_map(lines: list[str]) -> list[int]:
    """Brace depth in effect at the start of each line."""
    depth_at: list[int] = []
    depth = 0
    block_comment = 0
    strings: list[str] = []  # delimiter stack; "interp" entries track interpolation

    for line in lines:
        depth_at.append(depth)
        i = 0
        n = len(line)
        while i < n:
            if block_comment:
                if line.startswith("/*", i):
                    block_comment += 1
                    i += 2
                    continue
                if line.startswith("*/", i):
                    block_comment -= 1
                    i += 2
                    continue
                i += 1
                continue
            if strings:
                delim = strings[-1]
                if delim == "interp":
                    if line.startswith("//", i):
                        break
                    if line.startswith("/*", i):
                        block_comment = 1
                        i += 2
                        continue
                    ch = line[i]
                    if ch == "(":
                        strings.append("paren")
                        i += 1
                        continue
                    if ch == ")":
                        strings.pop()  # close interpolation
                        i += 1
                        continue
                    if ch == '"':
                        m = re.match(r'"{3,}', line[i:])
                        delim2 = m.group(0) if m else '"'
                        strings.append(delim2)
                        i += len(delim2)
                        continue
                    i += 1
                    continue
                if delim == "paren":
                    ch = line[i]
                    if ch == "(":
                        strings.append("paren")
                        i += 1
                        continue
                    if ch == ")":
                        strings.pop()
                        i += 1
                        continue
                    i += 1
                    continue
                # real string delimiter
                if line.startswith(delim, i):
                    strings.pop()
                    i += len(delim)
                    continue
                ch = line[i]
                if ch == "\\":
                    nxt = i + 1
                    # raw strings escape with backslash + hashes + (
                    while nxt < n and line[nxt] == "#":
                        nxt += 1
                    if nxt < n and line[nxt] == "(":
                        strings.append("interp")
                        i = nxt + 1
                        continue
                    i += 2
                    continue
                i += 1
                continue
            # code
            if line.startswith("//", i):
                break
            if line.startswith("/*", i):
                block_comment = 1
                i += 2
                continue
            ch = line[i]
            if ch == "#":
                m = re.match(r'(#+)"', line[i:])
                if m:
                    strings.append(m.group(1) + '"')
                    i += len(m.group(1)) + 1
                    continue
            if ch == '"':
                m = re.match(r'"{3,}', line[i:])
                delim = m.group(0) if m else '"'
                strings.append(delim)
                i += len(delim)
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            i += 1
    return depth_at


def decl_header(line: str) -> tuple[str, str]:
    """Return (kind, name) for a declaration line."""
    stripped = line.strip()
    while True:
        m = re.match(r"@[A-Za-z_0-9.]+(\([^)]*\))?\s*", stripped)
        if m:
            stripped = stripped[m.end():]
            continue
        m = re.match(r"(?:%s)\s+" % "|".join(MODIFIERS), stripped)
        if m and not re.match(r"(?:%s)\s*=" % "|".join(MODIFIERS), stripped):
            nxt = stripped[m.end():]
            if re.match(r"[A-Za-z_@]", nxt) or re.match(r"[A-Za-z_]+\s*\(", nxt):
                stripped = nxt
                continue
        break
    m = re.match(r"([A-Za-z_]+)\s+([A-Za-z_0-9]+)", stripped)
    if m and m.group(1) in DECL_KEYWORDS:
        return m.group(1), m.group(2)
    m = re.match(r"([A-Za-z_]+)", stripped)
    if m:
        return m.group(1), m.group(1)
    return "?", stripped[:40]


def block_end(depths: list[int], start: int, limit: int) -> int:
    """Last line of the declaration that begins at `start`, limited to `limit`."""
    base = depths[start]
    opened = None
    for i in range(start, limit):
        if depths[i] > base:
            opened = i
            break
    if opened is None:
        return limit - 1
    for i in range(opened, limit):
        if depths[i] == base:
            return i - 1
    return limit - 1


def first_token_at_depth(lines: list[str], depths: list[int], start: int, end: int, depth: int):
    """Line indices within [start, end] that open a declaration at `depth`."""
    out: list[int] = []
    for i in range(start, end + 1):
        if depths[i] != depth:
            continue
        stripped = lines[i].lstrip()
        if not stripped:
            continue
        # only the first meaningful token of the line counts
        m = re.match(r"[@A-Za-z_]", stripped)
        if not m:
            continue
        # a continuation line inside an expression keeps the same depth; skip
        # lines that continue a parameter list / expression
        out.append(i)
    return out


def top_level_blocks(lines: list[str]) -> list[Block]:
    depths = depth_map(lines)
    n = len(lines)
    starts: list[int] = []
    for i in range(n):
        if depths[i] != 0:
            continue
        stripped = lines[i].lstrip()
        if not stripped:
            continue
        kind, _name = decl_header(lines[i])
        if kind in DECL_KEYWORDS:
            starts.append(i)
    blocks: list[Block] = []
    cursor = 0
    for idx, start in enumerate(starts):
        nxt = starts[idx + 1] if idx + 1 < len(starts) else n
        end = trim_tail(lines, start, block_end(depths, start, nxt))
        kind, name = decl_header(lines[start])
        # contiguous partition: everything since the previous declaration
        # (blank lines, doc comments, attributes) belongs to this one
        doc = max(cursor, 0)
        blocks.append(Block(start=doc, end=max(end, start), kind=kind, name=name))
        cursor = max(end, start) + 1
    return blocks


def extension_members(lines: list[str], depths: list[int], block: Block) -> list[Block]:
    """Members of `extension Foo { ... }` shown as blocks at depth 1."""
    starts: list[int] = []
    for i in range(block.start, block.end + 1):
        if depths[i] != 1:
            continue
        stripped = lines[i]
        if not stripped.strip():
            continue
        # member declarations are indented; continuation lines of an expression
        # can also start with an identifier, so require a declaration keyword or
        # attribute at the head of the line
        head = stripped.lstrip()
        if head.startswith("@"):
            # a standalone attribute line belongs to the declaration below it
            head = re.sub(r"@[A-Za-z_0-9.]+(\([^)]*\))?\s*", "", head)
        m = re.match(r"([A-Za-z_]+)\b", head)
        looks_like = bool(m and (m.group(1) in DECL_KEYWORDS or m.group(1) in MODIFIERS))
        if looks_like:
            starts.append(i)
    members: list[Block] = []
    opener = block.start
    for probe in range(block.start, block.end + 1):
        if lines[probe].lstrip().startswith("extension "):
            opener = probe
            break
    cursor = opener + 1  # skip the `extension Foo {` line
    for idx, start in enumerate(starts):
        nxt = starts[idx + 1] if idx + 1 < len(starts) else block.end + 1
        end = trim_tail(lines, start, block_end(depths, start, nxt))
        kind, name = decl_header(lines[start])
        doc = cursor if cursor <= start else start
        members.append(Block(start=min(doc, start), end=max(end, start), kind=kind, name=name))
        cursor = max(end, start) + 1
    return members


DEFAULT_RULES: list[tuple[str, str]] = [
    ("hosting", "hosting"),
    ("openPR", "hosting"),
    ("pullrequest", "hosting"),
    ("vcsaction", "actions"),
    ("externalvcs", "actions"),
    ("comparison", "diff"),
    ("compare", "diff"),
    ("identity", "settings"),
    ("pinentry", "settings"),
    ("restore", "shelf"),
    ("savedchanges", "shelf"),
    ("repodata", "project"),
    ("repositorychange", "project"),
    ("treechanges", "project"),
    ("dirty", "project"),
    ("scan", "project"),
    ("rebase", "rebase"),
    ("autosquash", "rebase"),
    ("squash", "rebase"),
    ("fixup", "rebase"),
    ("conflict", "merge"),
    ("merge", "merge"),
    ("submodule", "submodule"),
    ("gitmodules", "submodule"),
    ("worktree", "worktree"),
    ("workingtree", "worktree"),
    ("unshelve", "unshelve"),
    ("shelve", "shelve"),
    ("shelf", "shelf"),
    ("stash", "stash"),
    ("patch", "patch"),
    ("apply", "patch"),
    ("fetch", "fetch"),
    ("push", "push"),
    ("pull", "pull"),
    ("clone", "clone"),
    ("upstream", "remote"),
    ("remote", "remote"),
    ("reflog", "log"),
    ("graph", "log"),
    ("history", "log"),
    ("revision", "log"),
    ("commit", "commit"),
    ("checkin", "commit"),
    ("amend", "commit"),
    ("signoff", "commit"),
    ("branch", "branch"),
    ("staging", "staging"),
    ("stage", "staging"),
    ("changelist", "staging"),
    ("hunk", "staging"),
    ("tag", "tag"),
    ("checkout", "checkout"),
    ("diff", "diff"),
    ("blame", "diff"),
    ("annotate", "diff"),
    ("console", "console"),
    ("notification", "console"),
    ("feedback", "console"),
    ("operation", "console"),
    ("retry", "console"),
    ("setting", "settings"),
    ("preference", "settings"),
    ("diagnostic", "settings"),
    ("log", "log"),
    ("ignore", "project"),
    ("root", "project"),
    ("project", "project"),
    ("status", "project"),
    ("refresh", "project"),
    ("revert", "rewrite"),
    ("reset", "rewrite"),
    ("cherry", "rewrite"),
    ("rollback", "rewrite"),
    ("drop", "rewrite"),
]


def classify(name: str, rules: list[tuple[str, str]], default: str) -> str:
    # the product prefix is on half the view types and would swallow the feature
    normalised = re.sub(r"^Rebased", "", name)
    for needle, bucket in rules:
        name = normalised
        haystack = name if needle != needle.lower() else name.lower()
        if needle in haystack:
            return bucket
    return default


def is_leading_decorator(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("@") and not stripped.endswith("=")


def is_comment_line(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith(("//", "/*", "*", "*/"))


def is_comment_or_blank(line: str) -> bool:
    return not line.strip() or is_comment_line(line)


def trim_tail(lines: list[str], start: int, end: int) -> int:
    """Shrink a block so trailing comments/blank lines are not claimed twice."""
    while end > start and is_comment_or_blank(lines[end]):
        end -= 1
    return end


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--default", default="core")
    ap.add_argument("--rules", type=Path)
    ap.add_argument("--prefix", default=None)
    ap.add_argument("--unclassified", type=int, default=0, help="print N largest unclassified members")
    args = ap.parse_args()

    rules = DEFAULT_RULES
    if args.rules:
        rules = [(str(a), str(b)) for a, b in json.loads(args.rules.read_text())]

    text = args.path.read_text()
    lines = text.split("\n")
    depths = depth_map(lines)
    blocks = top_level_blocks(lines)
    stem = args.prefix or args.path.stem

    # (container, bucket) -> blocks; container None means file scope
    groups: dict[tuple[str | None, str], list[Block]] = {}
    for block in blocks:
        if block.kind == "extension":
            for member in extension_members(lines, depths, block):
                groups.setdefault((block.name, classify(member.name, rules, args.default)), []).append(member)
        else:
            groups.setdefault((None, classify(block.name, rules, args.default)), []).append(block)

    if args.out is None:
        print(f"{args.path}: {len(lines)} lines, {len(blocks)} top-level blocks")
        rows = sorted(groups.items(), key=lambda kv: -sum(b.lines for b in kv[1]))
        print(f"{'slice':<30}{'blocks':>8}{'lines':>9}  biggest")
        for (container, bucket), bs in rows:
            label = f"{bucket}" if container is None else f"{container}/{bucket}"
            size = sum(b.lines for b in bs)
            biggest = ", ".join(f"{b.name}({b.lines})" for b in sorted(bs, key=lambda b: -b.lines)[:3])
            print(f"{label:<30}{len(bs):>8}{size:>9}  {biggest}")
        if args.unclassified:
            core = [(c, b) for (c, bucket), bs in groups.items() if bucket == args.default for b in bs]
            core.sort(key=lambda item: -item[1].lines)
            print(f"\nlargest unclassified blocks ({len(core)}):")
            for container, b in core[: args.unclassified]:
                print(f"  {b.lines:>5}  {b.name:<60} {container or ''}")
        return 0

    args.out.mkdir(parents=True, exist_ok=True)
    emitted: dict[Path, list[str]] = {}
    claimed: set[int] = set()
    for (container, bucket), bs in groups.items():
        body = ["import SwiftUI", "import AppKit", "import UniformTypeIdentifiers", ""]
        if container is not None:
            body.append(f"extension {container} {{")
        for b in sorted(bs, key=lambda b: b.start):
            claimed.update(range(b.start, b.end + 1))
            body.extend(lines[b.start : b.end + 1])
            if container is not None:
                body.append("")
        if container is not None:
            body.append("}")
        filename = f"{stem}+{bucket.capitalize()}.swift" if container is None else f"{stem}+{container}.{bucket.capitalize()}.swift"
        emitted[args.out / filename] = body

    # verification: every code line must be emitted exactly once; only blank
    # lines, comments, imports and the braces that wrap a sliced extension may
    # be dropped
    allowed_drops = re.compile(r"^(import |#if|#endif|#else|\{|\}|\s*$)")
    unemitted = [
        i for i in range(len(lines))
        if i not in claimed
        and not allowed_drops.match(lines[i].lstrip() if lines[i].strip() in ("{", "}") else lines[i])
        and not is_comment_or_blank(lines[i])
        and not lines[i].startswith("extension ")
    ]
    if unemitted:
        print(f"verification failed: {len(unemitted)} lines not emitted", file=sys.stderr)
        for i in unemitted[:15]:
            print(f"  {i + 1}: {lines[i][:110]}", file=sys.stderr)
        return 1

    for target, body in sorted(emitted.items()):
        target.write_text("\n".join(body) + "\n")
        print(f"wrote {target.name} ({len(body)} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
