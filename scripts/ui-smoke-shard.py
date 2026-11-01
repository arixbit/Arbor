#!/usr/bin/env python3
"""Split the UI smoke suite into balanced, disjoint shards.

The suite drives one real window at a time, so its test cases cannot run in
parallel on one machine: two runs would fight over the same menu bar, sheet and
accessibility tree. The only way to shorten it is to give each machine its own
share of the suite, which is what this script computes.

Test classes are discovered from `ui-smoke/**/*.swift`, so a new class cannot be
forgotten: it is either in WEIGHTS and placed by its measured cost, or placed
with DEFAULT_WEIGHT. `--check-discovery` fails when a file defines test methods
whose class was not discovered, which is the only way a class could silently
fall outside every shard.

usage:
    ui-smoke-shard.py <index> <total>    # class names for that shard, one per line
    ui-smoke-shard.py --check-discovery  # fail if a test class was not discovered
    ui-smoke-shard.py --verify <total>   # print the plan, fail if it is incomplete
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Measured wall-clock seconds per class on a macos-15 runner, from the full
# suite in run 41205194566 (40 tests, 1342s of test execution). Refresh these
# from the "Test Suite '<class>' passed ... in N seconds" lines when the suite
# changes shape; a stale weight only costs a little balance, never coverage.
WEIGHTS = {
    "ArborUIUserFlowUITests": 557,
    "ArborUIVisualCaptureUITests": 401,
    "ArborUISmokeUITests": 227,
    "ArborUISmokeContractUITests": 50,
    "ArborUISmokeProjectTreeUITests": 38,
    "ArborUIConflictUITests": 18,
    "ArborUISmokeFeedbackUITests": 18,
    "ArborUIDiagnosticsUITests": 17,
    "ArborUISmokeNavigationUITests": 14,
    "ArborUISmokeFocusUITests": 1,
}

DEFAULT_WEIGHT = 30

CLASS_PATTERN = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.MULTILINE)
TEST_PATTERN = re.compile(r"^\s*(?:@\w+\s+)*func\s+test\w*\s*\(", re.MULTILINE)


def smoke_sources(root: Path) -> list[Path]:
    return sorted(root.glob("ui-smoke/**/*.swift"))


def discover(root: Path) -> list[str]:
    """Every test class, in a stable order."""
    classes: list[str] = []
    for path in smoke_sources(root):
        for name in CLASS_PATTERN.findall(path.read_text(encoding="utf-8")):
            if name not in classes:
                classes.append(name)
    return classes


def undiscovered(root: Path) -> list[str]:
    """Files that carry test methods but whose class was not discovered."""
    problems = []
    for path in smoke_sources(root):
        text = path.read_text(encoding="utf-8")
        if TEST_PATTERN.search(text) and not CLASS_PATTERN.findall(text):
            problems.append(str(path.relative_to(root)))
    return problems


def plan(root: Path, total: int) -> list[list[str]]:
    if total < 1:
        raise SystemExit("total must be at least 1")
    shards: list[list[str]] = [[] for _ in range(total)]
    load = [0] * total
    # Longest-processing-time first onto the least loaded shard. Deterministic:
    # equal weights fall back to name order.
    for name in sorted(discover(root), key=lambda n: (-WEIGHTS.get(n, DEFAULT_WEIGHT), n)):
        target = load.index(min(load))
        shards[target].append(name)
        load[target] += WEIGHTS.get(name, DEFAULT_WEIGHT)
    return shards


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("index", nargs="?", type=int, help="shard index, zero based")
    parser.add_argument("total", nargs="?", type=int, help="number of shards")
    parser.add_argument("--check-discovery", action="store_true", help="fail if a test class was not discovered")
    parser.add_argument("--verify", action="store_true", help="print the plan and fail if it is incomplete")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root",
    )
    args = parser.parse_args(argv)

    problems = undiscovered(args.root)
    if problems:
        print("no test class discovered in: " + ", ".join(problems), file=sys.stderr)
        return 1

    if args.check_discovery:
        print(f"discovered {len(discover(args.root))} test classes")
        return 0

    if args.verify:
        if args.index is None:
            parser.error("--verify needs the shard count")
        shards = plan(args.root, args.index)
        assigned = [name for shard in shards for name in shard]
        if len(assigned) != len(set(assigned)):
            print("a test class was assigned to more than one shard", file=sys.stderr)
            return 1
        missing = set(discover(args.root)) - set(assigned)
        if missing:
            print(f"unassigned test classes: {sorted(missing)}", file=sys.stderr)
            return 1
        for index, shard in enumerate(shards):
            weight = sum(WEIGHTS.get(n, DEFAULT_WEIGHT) for n in shard)
            print(f"shard {index}: ~{weight}s {shard}")
        return 0

    if args.index is None or args.total is None:
        parser.error("expected <index> <total>")
    if not 0 <= args.index < args.total:
        parser.error("index must be smaller than the shard count")
    for name in plan(args.root, args.total)[args.index]:
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
