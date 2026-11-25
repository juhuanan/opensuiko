#!/usr/bin/env python3
"""Corpus link integrity: every doc reference must resolve.

The corpus carries ~1,050 inbound references to `kit/docs/*.md` — 936 in the
fact registry's `source` fields, 76 in tools/tests/AGENTS, and the rest in doc
prose. Those references are the corpus's provenance chain: a `source` field that
points at a file that no longer exists is a **trap**, exactly like a superseded
claim left marked `proven`.

This gate pins the state measured on 2026-10-06, when all but a handful resolved,
so that adding a wiki layer cannot silently break the chain.

Checks:
  1. every `kit/docs/<name>` reference mentioned anywhere resolves to a real
     file (this scanner's own docstring is skipped, since it shows the form);
  2. every `[[wikilink]]` in a doc resolves to a real note (by basename, the way
     Obsidian resolves them), or is in the explicit external-link allowlist;
  3. the two allowlisted absences stay deliberate — a new absence fails.

Run:  python3 kit/tests/test_corpus_links.py
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

_KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_ROOT = os.path.dirname(_KIT)
# The research corpus is retired to archive/docs; references still carry the kit/docs
# prefix and resolve by basename, so the provenance chain survives the move.
DOCS = os.path.join(_ROOT, "archive", "docs")
REGISTRY = os.path.join(_KIT, "data", "registry", "extract_D.jsonl")

#: references that are deliberately unresolved.  Each needs a reason, and a NEW
#: entry here is a deliberate act rather than an accident.
ALLOWED_MISSING = {
    # the corpus records this one as absent from the working tree, and says so
    "VB6_h0_missing_houses_20261004.md": "documented absent; PIPELINE.md says so",
    # a negative fixture: a tool test asserts behaviour for a missing doc
    "does_not_exist_20261004.md": "deliberate negative fixture in a tool test",
    # named in prose as things that *should* exist / were intended, not as links
    "audio_rip.md": "prose reference to a doc that was never written",
    "stone_decode.md": "prose reference to a doc that was never written",
}

#: `kit/docs/<name>.md`, with an optional trailing `:line` or `:line-line`
PATH_RE = re.compile(r"(?:kit/docs|archive/docs)/([A-Za-z0-9_.\-]+\.md)")
#: `[[target]]` or `[[target|alias]]`, optionally with a `#heading`.
#:
#: NOTE the target charset is deliberately narrow.  This corpus already uses
#: `[[...]]` for **address/index notation** — `[[0x80178F58]]`, `[[$s0+0x14]]`,
#: `[[record+0x2C]]` — so a permissive pattern matches ten pieces of code and
#: zero links.  A note name must start with a letter and contain no `$`, `+`,
#: `[` or `#`; that excludes every observed notation and admits real links.
WIKI_RE = re.compile(
    r"\[\[([A-Za-z][A-Za-z0-9_\- .]*?)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]")


def doc_basenames() -> set[str]:
    return {os.path.basename(p) for p in glob.glob(os.path.join(DOCS, "*.md"))}


def ref_files() -> list[str]:
    """Every text file that may cite a doc.  RECURSIVE: the first migration pass
    only scanned `kit/tools/*.py` and `kit/tests/*.py`, and a reference inside a
    SUBDIRECTORY survived it, so this walks."""
    out = [os.path.join(_ROOT, "AGENTS.md"), os.path.join(_ROOT, "README.md")]
    for sub in ("tools", "tests"):
        for root, _d, fs in os.walk(os.path.join(_KIT, sub)):
            if "__pycache__" in root:
                continue
            out += [os.path.join(root, f) for f in fs if f.endswith((".py", ".sh"))]
    out += glob.glob(os.path.join(_KIT, "data", "registry", "extract_*.jsonl"))
    out += glob.glob(os.path.join(_ROOT, "archive", "goals", "**", "*.md"), recursive=True)
    return [f for f in out if os.path.exists(f)]


def scan_path_refs(names: set[str]) -> dict[str, int]:
    """Every `kit/docs/X.md` reference anywhere, and what it fails to resolve."""
    broken: dict[str, int] = {}
    _bump = broken.__setitem__
    # 1. the registry
    with open(REGISTRY) as f:
        for line in f:
            if not line.strip():
                continue
            src = json.loads(line).get("source", "")
            for m in PATH_RE.finditer(src):
                if m.group(1) not in names:
                    _bump(m.group(1), broken.get(m.group(1), 0) + 1)
    # 2. tools, tests, AGENTS, the reading order
    # RECURSIVE: the first migration pass only scanned kit/tools/*.py and
    # kit/tests/*.py, and a reference inside a SUBDIRECTORY survived it.  Walk.
    files = ref_files()
    for f in files:
        if not os.path.exists(f):
            continue
        if os.path.basename(f) == os.path.basename(__file__):
            # this scanner documents the reference FORM in its own docstring
            # (`kit/docs/X.md`), which would otherwise fail its own check
            continue
        with open(f, errors="replace") as fh:
            for m in PATH_RE.finditer(fh.read()):
                if m.group(1) not in names:
                    _bump(m.group(1), broken.get(m.group(1), 0) + 1)
    # 3. doc -> doc
    for p in glob.glob(os.path.join(DOCS, "*.md")):
        with open(p, errors="replace") as fh:
            for m in PATH_RE.finditer(fh.read()):
                if m.group(1) not in names:
                    _bump(m.group(1), broken.get(m.group(1), 0) + 1)
    return broken


def scan_wikilinks(names: set[str]) -> dict[str, list[str]]:
    """`{unresolved target: [files that link it]}`."""
    out: dict[str, list[str]] = {}
    for p in glob.glob(os.path.join(DOCS, "*.md")):
        with open(p, errors="replace") as fh:
            for m in WIKI_RE.finditer(fh.read()):
                t = m.group(1).strip()
                if t in names:
                    continue
                # Obsidian also resolves by title without the extension
                if t + ".md" in names:
                    continue
                if t in ALLOWED_MISSING:
                    continue
                out.setdefault(t, []).append(os.path.basename(p))
    return out


def check() -> None:
    names = doc_basenames()
    assert len(names) > 150, f"only {len(names)} docs found — is DOCS right?"

    broken = scan_path_refs(names)
    unexpected = {k: v for k, v in broken.items() if k not in ALLOWED_MISSING}
    assert not unexpected, (
        "unresolved kit/docs references (a provenance pointer is a trap):\n  "
        + "\n  ".join(f"{k} x{v}" for k, v in sorted(unexpected.items())))
    # the allowlisted ones must still be the only ones, and still present
    for k in ALLOWED_MISSING:
        assert k not in names, f"{k} now EXISTS — remove it from ALLOWED_MISSING"

    wik = scan_wikilinks(names)
    assert not wik, ("unresolved [[wikilinks]]:\n  "
                     + "\n  ".join(f"{k} <- {v}" for k, v in sorted(wik.items())))

    # ---- no renamed old name may survive outside the mapping file
    renames = {}
    rp = os.path.join(DOCS, "CORPUS_RENAMES.md")
    if os.path.exists(rp):
        with open(rp) as fh:
            for line in fh:
                m = re.match(r"\| `([^`]+)` \| `([^`]+)` \|", line)
                if m:
                    renames[m.group(1)] = m.group(2)
    leftovers = {}
    for f in ref_files() + glob.glob(os.path.join(DOCS, "*.md")):
        if os.path.abspath(f) == os.path.abspath(rp):
            continue                      # the mapping file names them by design
        with open(f, errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                if line.startswith("aliases:"):
                    continue              # a note's own old name is its alias
                for old in renames:
                    if old in line:
                        leftovers.setdefault(os.path.relpath(f, _ROOT), []).append((i, old))
    assert not leftovers, (
        f"{len(leftovers)} file(s) still cite a RENAMED old note name:\n  "
        + "\n  ".join(f"{f}:{v[0][0]} {v[0][1]}" for f, v in sorted(leftovers.items())[:12]))

    n_wiki = 0
    for p in glob.glob(os.path.join(DOCS, "*.md")):
        with open(p, errors="replace") as fh:
            n_wiki += len(WIKI_RE.findall(fh.read()))
    print(f"PASS: corpus links resolve — {len(names)} docs; {len(renames)} renames "
          f"with 0 surviving old names; "
          f"{len(ALLOWED_MISSING)} allowlisted absences (each deliberate); "
          f"{n_wiki} wikilinks all resolve")


if __name__ == "__main__":
    check()
