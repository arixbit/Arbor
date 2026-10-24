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
# SwiftUI localizes Text/Button/... implicitly, but explicit String(localized:)
# and AppKit NSAlert properties bypass those initializers. They need the same
# catalog coverage or a Chinese interface silently shows English.
LOCALIZED_PATTERN = re.compile(
    r"\bString\s*\(\s*localized:\s*\"((?:\\.|[^\"\\])*)\""
)
APPKIT_PATTERN = re.compile(
    r"\b(?:messageText|informativeText)\s*=\s*\"((?:\\.|[^\"\\])*)\""
)
APPKIT_TITLE_PATTERN = re.compile(
    r"\baddButton\s*\(\s*withTitle:\s*\"((?:\\.|[^\"\\])*)\""
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
    for pattern in (
        CALL_PATTERN,
        HELP_PATTERN,
        ARGUMENT_PATTERN,
        LOCALIZED_PATTERN,
        APPKIT_PATTERN,
        APPKIT_TITLE_PATTERN,
    ):
        for match in pattern.finditer(source):
            value = decode_swift_string(match.group(1))
            if value and "\\(" not in value:
                matches.append((value, line_number(source, match.start())))
    return matches


CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")


def hardcoded_chinese(path: Path) -> list[tuple[str, int]]:
    """Literals that hand Chinese text to a user-facing API.

    A Chinese literal is not a translation: it is untranslated English UI
    showing Chinese text (or the reverse) and it never passes through the
    string catalog. `--update-hardcoded-baseline` records the current debt so
    the count can only go down.
    """
    source = path.read_text(encoding="utf-8")
    hits: list[tuple[str, int]] = []
    for pattern in (
        CALL_PATTERN,
        HELP_PATTERN,
        ARGUMENT_PATTERN,
        LOCALIZED_PATTERN,
        APPKIT_PATTERN,
        APPKIT_TITLE_PATTERN,
    ):
        for match in pattern.finditer(source):
            value = decode_swift_string(match.group(1))
            if value and "\\(" not in value and CJK_PATTERN.search(value):
                hits.append((value, line_number(source, match.start())))
    return hits


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
    parser.add_argument(
        "--hardcoded-baseline",
        type=Path,
        help="baseline file of accepted Chinese literals (default: scripts/i18n-hardcoded-baseline.txt)",
    )
    parser.add_argument(
        "--only-hardcoded",
        action="store_true",
        help="exit non-zero only for newly introduced Chinese literals",
    )
    parser.add_argument(
        "--update-hardcoded-baseline",
        action="store_true",
        help="rewrite the baseline with the current Chinese literals",
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

    hardcoded: list[tuple[str, str, int]] = []
    for raw_path in args.paths:
        path = (root / raw_path).resolve()
        files = [path] if path.is_file() else sorted(path.rglob("*.swift"))
        for swift_file in files:
            if "Tests" in swift_file.parts:
                continue
            for value, line in hardcoded_chinese(swift_file):
                hardcoded.append((str(swift_file.relative_to(root)), value, line))

    baseline_path = (
        args.hardcoded_baseline
        if args.hardcoded_baseline is not None
        else root / "scripts/i18n-hardcoded-baseline.txt"
    )
    hardcoded_entries = sorted({f"{path}\t{value}" for path, value, _ in hardcoded})

    if args.update_hardcoded_baseline:
        baseline_path.write_text("\n".join(hardcoded_entries) + "\n", encoding="utf-8")
        print(f"wrote {len(hardcoded_entries)} hardcoded entries to {baseline_path}")

    baseline: set[str] = set()
    if baseline_path.exists():
        baseline = {
            line for line in baseline_path.read_text(encoding="utf-8").splitlines() if line
        }

    introduced = sorted(set(hardcoded_entries) - baseline)
    retired = sorted(baseline - set(hardcoded_entries))

    missing = sorted(set(occurrences) - catalog_keys)
    untranslated = sorted(
        key
        for key in occurrences
        if key in catalog_keys
        if catalog.get("strings", {}).get(key, {}).get("localizations", {}).get("zh-Hans")
        is None
    )

    if args.only_hardcoded:
        print(f"Hardcoded Chinese UI literals: {len(hardcoded_entries)} (baseline {len(baseline)})")
        for entry in introduced:
            print(f"HARDCODED\t{entry}")
        if retired:
            print(
                f"Note: {len(retired)} baseline entries no longer exist; "
                "rerun with --update-hardcoded-baseline to ratchet the baseline down."
            )
        return 1 if introduced else 0

    print(f"Scanned literals: {len(occurrences)}")
    print(f"Missing catalog keys: {len(missing)}")
    for key in missing:
        print(f"MISSING\t{key}\t{' / '.join(occurrences[key])}")
    print(f"Missing zh-Hans translations: {len(untranslated)}")
    for key in untranslated:
        print(f"UNTRANSLATED\t{key}\t{' / '.join(occurrences[key])}")

    print(f"Hardcoded Chinese UI literals: {len(hardcoded_entries)} (baseline {len(baseline)})")
    for entry in introduced:
        print(f"HARDCODED\t{entry}")
    if retired and not args.update_hardcoded_baseline:
        print(
            f"Note: {len(retired)} baseline entries no longer exist; "
            "rerun with --update-hardcoded-baseline to ratchet the baseline down."
        )
    return 1 if missing or untranslated or introduced else 0


if __name__ == "__main__":
    sys.exit(main())
