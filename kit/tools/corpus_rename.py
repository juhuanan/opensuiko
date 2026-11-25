#!/usr/bin/env python3
"""One-shot migration: date-stamped doc filenames -> clean note names.

Chosen by the user 2026-10-06 (over the additive-only option): rename the 149
date-stamped notes to clean titles, move the date into frontmatter, and rewrite
every inbound reference.

What it does, in order:

1. **Maps** `foo_bar_20261006.md` -> `foo_bar.md`, recording the date.
   A date suffix is **kept** only where stripping it would collide — currently
   exactly two pairs (`PIPELINE_corrections_*`, `decode_04play_consumer_*`).
2. **Renames with `git mv`**, so history follows the file.
3. **Rewrites every inbound reference** — 936 registry `source` fields (preserving
   any `:line` suffix), tool/test/AGENTS docstrings, and doc prose including bare
   backticked names.
4. **Injects YAML frontmatter** with only derivable facts: `title` (the name,
   de-underscored), `date` (from the old filename, or `null`), and `aliases`
   (the old name) so old citations still resolve in Obsidian and in search.
   `status` is deliberately NOT invented — it cannot be derived mechanically and
   guessing it would be the kind of claim this corpus forbids.
5. **Writes a mapping file** (`kit/docs/CORPUS_RENAMES.md`) as the traceable record.

`--check` (default) prints the mapping and the rewrite counts and changes nothing.
`--apply` does it. Both are safe to re-run.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys

_KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_ROOT = os.path.dirname(_KIT)
DOCS = os.path.join(_KIT, "docs")
REGISTRY = os.path.join(_KIT, "data", "registry", "extract_D.jsonl")
DATE_RE = re.compile(r"^(.*?)_(\d{4})(\d{2})(\d{2})$")


def build_mapping() -> dict[str, tuple[str, str | None]]:
    """`{old basename without .md: (new stem, date or None)}`."""
    docs = sorted(os.path.basename(p)[:-3] for p in glob.glob(os.path.join(DOCS, "*.md")))
    staged: list[tuple[str, str, str | None]] = []
    for b in docs:
        m = DATE_RE.match(b)
        if m:
            iso = f"{m.group(2)}-{m.group(3)}-{m.group(4)}"
            staged.append((b, m.group(1), iso))
        else:
            staged.append((b, b, None))
    # keep the date where stripping it would collide
    dupes = {s for _b, s, _d in staged if sum(1 for _x, y, _z in staged if y == s) > 1}
    out: dict[str, tuple[str, str | None]] = {}
    for b, stem, iso in staged:
        if iso and stem in dupes:
            out[b] = (b, iso)      # unchanged: the date is the discriminator
        elif iso:
            out[b] = (stem, iso)
        else:
            out[b] = (b, None)
    return out


def ref_files() -> list[str]:
    files = [REGISTRY,
             os.path.join(_ROOT, "AGENTS.md"),
             os.path.join(_ROOT, "README.md")]
    files += glob.glob(os.path.join(_KIT, "tools", "*.py"))
    files += glob.glob(os.path.join(_KIT, "tests", "*.py"))
    files += glob.glob(os.path.join(_KIT, "tools", "*.sh"))
    files += glob.glob(os.path.join(DOCS, "*.md"))
    return [f for f in files if os.path.exists(f)]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--docs", default=DOCS, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    mapping = build_mapping()
    renamed = {k: v for k, v in mapping.items() if k != v[0]}
    kept_coll = sum(1 for k, v in mapping.items() if k == v[0] and v[1] is not None)
    kept_undated = sum(1 for k, v in mapping.items() if k == v[0] and v[1] is None)
    print(f"{len(mapping)} notes; {len(renamed)} to rename; "
          f"{kept_coll} keep their name because the date is the discriminator; "
          f"{kept_undated} were never date-stamped")

    # ---- how many references would change
    counts = {"registry": 0, "code": 0, "docs": 0}
    for f in ref_files():
        kind = ("registry" if f == REGISTRY
                else "docs" if f.startswith(args.docs) else "code")
        with open(f, errors="replace") as fh:
            txt = fh.read()
        for old, (new, _d) in renamed.items():
            counts[kind] += txt.count(old)
    print("references to rewrite:", counts, "total", sum(counts.values()))

    if not args.apply:
        print("\nmapping (first 15):")
        for old, (new, d) in sorted(renamed.items())[:15]:
            print(f"   {old}.md  ->  {new}.md   (date {d})")
        print("\ndry run: nothing changed.  re-run with --apply")
        return 0

    # ---- 1. rewrite references (before renaming, so the old names are findable)
    for f in ref_files():
        with open(f, errors="replace") as fh:
            txt = fh.read()
        orig = txt
        for old, (new, _d) in renamed.items():
            if old == new:
                continue
            # `kit/docs/<old>.md` and bare `<old>.md`
            txt = txt.replace(f"kit/docs/{old}.md", f"kit/docs/{new}.md")
            txt = re.sub(rf"(?<![A-Za-z0-9_./-]){re.escape(old)}\.md",
                         f"{new}.md", txt)
            # the other citation form: a backticked bare name, and any wikilink.
            # Both are unambiguous because of the surrounding delimiters.
            txt = txt.replace(f"`{old}`", f"`{new}`")
            txt = txt.replace(f"[[{old}]]", f"[[{new}]]")
            txt = txt.replace(f"[[{old}|", f"[[{new}|")
        if txt != orig:
            with open(f, "w") as fh:
                fh.write(txt)

    # ---- 2. git mv
    subprocess.run(["git", "add", "-A", "--", args.docs], cwd=_ROOT, check=False)
    for old, (new, _d) in sorted(renamed.items()):
        src = os.path.join(args.docs, old + ".md")
        dst = os.path.join(args.docs, new + ".md")
        if os.path.exists(src):
            subprocess.run(["git", "mv", src, dst], cwd=_ROOT, check=True)

    # ---- 3. frontmatter
    for old, (new, date) in sorted(mapping.items()):
        p = os.path.join(args.docs, new + ".md")
        if not os.path.exists(p):
            continue
        with open(p, errors="replace") as fh:
            txt = fh.read()
        if txt.startswith("---\n"):
            continue
        title = new.replace("_", " ")
        al = f"[{old}]" if old != new else "[]"
        fm = (f"---\ntitle: {title}\ndate: {date}\naliases: {al}\n---\n\n")
        with open(p, "w") as fh:
            fh.write(fm + txt)

    # ---- 4. the mapping record
    lines = ["# Corpus renames — old note name -> new (2026-10-06)", "",
             "The user chose clean note titles over stable date-stamped filenames.",
             "Every inbound reference was rewritten in the same change (936 registry",
             "`source` fields preserving their `:line` suffixes, 76 tool/test/AGENTS",
             "references, and doc prose). Each renamed note also carries its old name",
             "in `aliases:` frontmatter, so an old citation still resolves in Obsidian",
             "and in a full-text search.", "",
             "A date suffix is kept only where stripping it would collide.", "",
             "| old | new | date |", "|---|---|---|"]
    for old, (new, d) in sorted(mapping.items()):
        if old != new:
            lines.append(f"| `{old}` | `{new}` | {d} |")
    lines += ["", f"{len(renamed)} renames.", ""]
    with open(os.path.join(args.docs, "CORPUS_RENAMES.md"), "w") as fh:
        fh.write("\n".join(lines))
    print(f"applied: {len(renamed)} renames, frontmatter added, CORPUS_RENAMES.md written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
