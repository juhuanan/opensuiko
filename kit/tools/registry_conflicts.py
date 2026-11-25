#!/usr/bin/env python3
"""Report addresses whose registry rows disagree about whether the question is settled.

The registry is a LOG of claims. Each row carries its own `evidence`, and a later
workstream that answers an earlier row's question is supposed to go back and supersede
it — but nothing forces that, and nothing detects its absence. So an address can end up
holding both "OPEN: no encounter trigger was found statically" and "the encounter
requester is statically connected" as peers, and every generated view prints both.

That is how a settled question keeps reading as open. This tool makes the backlog
visible and countable: for each address it groups the evidence states and reports the
ones that carry a PROVEN row alongside a row that still claims the question is open.

It is a REVIEW QUEUE, not an error. A proven fact and an unrelated open question can
legitimately share an address, so each entry needs a human decision: supersede the
stale row, or record why both hold.

    python kit/tools/registry_conflicts.py            # the queue
    python kit/tools/registry_conflicts.py --count    # just the number
    python kit/tools/registry_conflicts.py --json
"""
from __future__ import annotations

import collections
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(ROOT, "kit", "data", "registry")
SETTLED = "proven"
UNSETTLED = ("open",)


def rows():
    out = []
    for path in sorted(glob.glob(os.path.join(WORK, "extract_*.jsonl"))):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                r["_file"] = os.path.basename(path)
                out.append(r)
    return out


def conflicts(rs):
    by = collections.defaultdict(list)
    for r in rs:
        a = (r.get("addr") or "").strip()
        if a and a != "—":
            by[a].append(r)
    out = []
    for a, group in by.items():
        states = {((r.get("evidence") or "?").strip()) for r in group}
        if SETTLED in states and any(u in states for u in UNSETTLED):
            # A reviewed entry is one where the co-existence was examined and found
            # legitimate -- a proven fact and a different open question sharing an
            # address. Without this marker the queue could never reach zero, and a
            # queue that cannot be emptied is one nobody works.
            if any("conflict reviewed" in (r.get("note") or "") for r in group):
                continue
            out.append((a, sorted(group, key=lambda r: (r.get("evidence") or ""))))
    return sorted(out, key=lambda t: t[0])


def main(argv):
    rs = rows()
    conf = conflicts(rs)
    if "--count" in argv:
        print(f"{len(conf)} address(es) carry both a proven row and an open row")
        return 0
    if "--json" in argv:
        print(json.dumps([{"addr": a,
                           "rows": [{"evidence": r.get("evidence"), "claim": r.get("claim"),
                                     "source": r.get("_file")} for r in g]}
                          for a, g in conf], indent=1))
        return 0
    print(f"# Registry conflicts — {len(conf)} address(es) hold a proven row and an open row")
    print("# Each entry needs a decision: supersede the stale row, or say why both hold.\n")
    for a, group in conf:
        print(f"{a}")
        for r in group:
            print(f"   [{(r.get('evidence') or '?'):10s}] {(r.get('claim') or '')[:150]}")
            print(f"              {r.get('_file')}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
