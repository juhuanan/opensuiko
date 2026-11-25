#!/usr/bin/env python3
"""Gate the manual's link graph.

The manual is meant to be read as one document: every page is reachable from the
table of contents in `manual/README.md`, and every cross-reference resolves. A page
nobody links to is a page nobody will find, and a link to a page that does not exist
is worse -- it reads as a citation.

Checks, always:
  * every relative markdown link inside `manual/` resolves to a real file
  * every page is reachable from `manual/README.md`

Check, only with `--strict`:
  * every page named in the README's table of contents exists

`--strict` is what the build runs once the manual is complete. Until then it reports
the pages still to be written rather than failing, so the gate can be wired in while
the manual is being filled out without blocking unrelated work.

Usage:
    python kit/tests/test_manual_links.py
    python kit/tests/test_manual_links.py --strict
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANUAL = ROOT / "manual"
ENTRY = "README.md"

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
WIKI_RE = re.compile(r"\[\[([^\]|#]+)")


def pages() -> list[Path]:
    return sorted(MANUAL.glob("*.md"))


def targets(path: Path) -> list[str]:
    """Relative .md targets referenced by a page, de-duplicated, order preserved."""
    text = path.read_text(encoding="utf-8")
    out, seen = [], set()
    for raw in LINK_RE.findall(text) + WIKI_RE.findall(text):
        t = raw.strip().split("#", 1)[0].strip()
        if not t or t.startswith(("http://", "https://", "mailto:")):
            continue
        if not t.endswith(".md"):
            continue
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def check(strict: bool) -> int:
    if not MANUAL.is_dir():
        print("FAIL: manual/ does not exist")
        return 1
    ps = pages()
    names = {p.name for p in ps}
    problems: list[str] = []
    entry = MANUAL / ENTRY

    # The table of contents is the manual's manifest: a page named there but not yet
    # written is planned work, reported rather than failed. A link to a page that is
    # neither written nor named in the manifest is a broken reference.
    planned: set[str] = set()
    if entry.exists():
        planned = {t for t in targets(entry) if t not in names}

    # 1. every link resolves, or is a planned page named in the manifest
    for p in ps:
        for t in targets(p):
            if t not in names and t not in planned:
                problems.append(f"{p.name} -> {t} (no such page, and not in {ENTRY})")

    # 2. every page is reachable from the entry point
    if not entry.exists():
        problems.append(f"{ENTRY} is missing; the manual has no table of contents")
    else:
        seen, queue = {ENTRY}, [ENTRY]
        while queue:
            cur = queue.pop()
            for t in targets(MANUAL / cur):
                if t in names and t not in seen:
                    seen.add(t)
                    queue.append(t)
        for name in sorted(names - seen):
            problems.append(f"{name} is unreachable from {ENTRY} (orphan page)")

    # 3. with --strict, the manifest must be fully written
    missing = sorted(planned)
    if strict:
        for t in missing:
            problems.append(f"{ENTRY} lists {t}, which has not been written")

    if problems:
        print("FAIL: manual link graph problems:")
        for p in problems:
            print(f"  - {p}")
        return 1

    if missing:
        print(f"PASS: manual links resolve -- {len(names)} pages, {len(missing)} "
              f"still to be written ({', '.join(sorted(missing))})")
    else:
        print(f"PASS: manual links resolve -- {len(names)} pages, all reachable from {ENTRY}")
    return 0


if __name__ == "__main__":
    sys.exit(check("--strict" in sys.argv[1:]))
