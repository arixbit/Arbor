#!/usr/bin/env python3
"""Audit localizable SwiftUI literals against Arbor/Localizable.xcstrings.

This intentionally checks the common SwiftUI label APIs used by Arbor. It is
an audit aid, not a Swift parser: dynamic strings and interpolated literals
are reported separately so they cannot silently look translated.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


CALLS = (
    "Text",
    "Label",
    "Button",
    "Menu",
    "Toggle",
    "TextField",
    "SecureField",
    "CommandMenu",
)
CALL_PATTERN = re.compile(
    rf"\b(?:{'|'.join(CALLS)})\s*\(\s*\"((?:\\.|[^\"\\])*)\""
)
HELP_PATTERN = re.compile(
    r"\.(?:help|accessibilityLabel)\(\s*\"((?:\\.|[^\"\\])*)\""
)
ARGUMENT_PATTERN = re.compile(
    r"\b(?:title|prompt|description)\s*:\s*\"((?:\\.|[^\"\\])*)\""
)


def decode_swift_string(value: str) -> str:
    # Swift and JSON use the same escapes for the literals relevant here.
    try:
        return json.loads(f'"{value}"')
    except json.JSONDecodeError:
        return value


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def scan_file(path: Path) -> list[tuple[str, int]]:
    source = path.read_text(encoding="utf-8")
    matches: list[tuple[str, int]] = []
    for pattern in (CALL_PATTERN, HELP_PATTERN, ARGUMENT_PATTERN):
        for match in pattern.finditer(source):
            value = decode_swift_string(match.group(1))
            if value and "\\(" not in value:
                matches.append((value, line_number(source, match.start())))
    return matches


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--strings", type=Path)
    parser.add_argument(
        "--paths",
        nargs="*",
        default=["Arbor"],
        help="relative files/directories to scan (default: Arbor)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    strings_path = (args.strings or root / "Arbor/Localizable.xcstrings").resolve()

    catalog = json.loads(strings_path.read_text(encoding="utf-8"))
    catalog_keys = set(catalog.get("strings", {}))
    occurrences: dict[str, list[str]] = {}
    for raw_path in args.paths:
        path = (root / raw_path).resolve()
        files = [path] if path.is_file() else sorted(path.rglob("*.swift"))
        for swift_file in files:
            for value, line in scan_file(swift_file):
                occurrences.setdefault(value, []).append(
                    f"{swift_file.relative_to(root)}:{line}"
                )

    missing = sorted(set(occurrences) - catalog_keys)
    untranslated = sorted(
        key
        for key in occurrences
        if key in catalog_keys
        if catalog.get("strings", {}).get(key, {}).get("localizations", {}).get("zh-Hans")
        is None
    )

    print(f"Scanned literals: {len(occurrences)}")
    print(f"Missing catalog keys: {len(missing)}")
    for key in missing:
        print(f"MISSING\t{key}\t{' / '.join(occurrences[key])}")
    print(f"Missing zh-Hans translations: {len(untranslated)}")
    for key in untranslated:
        print(f"UNTRANSLATED\t{key}\t{' / '.join(occurrences[key])}")
    return 1 if missing or untranslated else 0


if __name__ == "__main__":
    sys.exit(main())
