#!/usr/bin/env python3
"""Fail a workflow gate when any job it depends on did not pass.

GitHub treats a skipped job as satisfied for branch protection, which is what
makes a documentation-only pull request mergeable without running the heavy
jobs. A failed or cancelled job is not satisfied, and a gate that only lists
`needs:` would stop at the first failure; this reads every dependency instead so
the gate reports one clear result per job.

usage: NEEDS='<toJSON(needs)>' check-needs.py
"""

from __future__ import annotations

import json
import os
import sys

# Results that let the gate pass. `skipped` is included deliberately: the
# documentation-only path skips the heavy jobs, not the gate.
ALLOWED = ("success", "skipped")


def main() -> int:
    raw = os.environ.get("NEEDS")
    if not raw:
        print("NEEDS is not set", file=sys.stderr)
        return 2
    needs = json.loads(raw)
    blocking = {}
    for name, job in needs.items():
        result = job.get("result")
        print(f"{name}: {result}")
        if result not in ALLOWED:
            blocking[name] = result
    if blocking:
        print(f"blocking results: {blocking}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
