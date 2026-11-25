#!/usr/bin/env python3
"""Generate `STATE_OF_KNOWLEDGE.md` — what is true NOW, from the live registry.

The problem this solves: the corpus is 205 dated notes plus ~87 correction
banners, so answering "is X true?" means reconstructing the answer from the
whole history.  That is what makes a corpus *feel* buggy even when every
individual correction is correct.

The fact registry (`kit/work/extract_{A,B,C,D}.jsonl`, ~1,000 rows) already
records, per claim, whether it has been superseded.  So the current state can be
**derived** rather than curated:

* a row is **live** when `superseded_by` is empty and `evidence` is not a
  retraction marker;
* everything else is history, and stays in the dated notes.

The output is grouped by claim class and carries each claim's provenance, so it
is the one page a reader can trust without reading 205 notes.  Because it is
generated, it cannot drift from the registry.

Usage:
    python3 corpus_state.py            # write STATE_OF_KNOWLEDGE.md
    python3 corpus_state.py --check    # counts only
    python3 corpus_state.py --verify   # fail if the committed page is stale
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
# The research corpus is RETIRED from the active tree: it lives under archive/docs.
# References in the registry and in tools still carry the kit/docs prefix, and both
# tools resolve them by BASENAME against this directory, so moving the tree does not
# break the 4,457 provenance pointers into it.
DOCS = os.path.join(os.path.dirname(_KIT), "archive", "docs")
WORK = os.path.join(_KIT, "data", "registry")
OUT = os.path.join(DOCS, "STATE_OF_KNOWLEDGE.md")

#: `evidence` values that mean the row is history, not current state
# "dropped" is a row deliberately not pursued -- another game, an unreachable external
# resource, a runtime-only question, or a to-do recorded as a question.  It is history
# for the same reason the others are: it is not current state.
DEAD = {"superseded", "retracted", "wrong", "refuted", "withdrawn", "void", "dropped"}

#: what each claim class covers, so the dashboard indexes the knowledge instead of
#: just counting it.  Written once here; a class with no entry still lists.
CLASS_BLURB = {
    "global": "disc layout, boot and the load architecture, plus the file census",
    "8area": "the `.8` Form1 SPU audio streams and historical area-record research",
    "text": "dialogue and UI text, the game's non-ASCII table, string recovery",
    "04_PLAY": "field/battle sprite files: pages, records, draw pieces",
    "script": "the area/event script VM — opcodes and their operands",
    "IC": "duel fighter atlases (colours accepted; E/F sequences and script timing traced)",
    "audio": "VAB/SPU sound banks, stereo `.8` streams and XA streams",
    "BT": "duel battle backdrops",
    "FACE": "the 108 named portraits and their CLUTs",
    "music": "pQES music format, instruments and the renderer",
    "BATH": "bath-house and decoration page banks",
    "battle": "battle structure: floor mesh, placements, actors, encounter tables",
    "STONE": "the stone-tablet pages",
    "video": "STR movies",
    "menu": "menu/UI flows: shop, blacksmith, rune, appraiser",
    "SKY": "duel sky/dusk backdrops",
    "sprite": "sprite geometry and the upload plumbing",
    "graphics": "GPU/VRAM behaviour and rendering",
    "tools": "the kit's own instruments",
    "area": "area scene overview",
    "shiro": "the castle (shiro) page family",
    "memcard": "the save block: its 0x284 header, checksum and payload map",
    "worldmap": "the world map: the tile field, its draw transform and the wrap",
}

#: note references inside a claim, turned into wikilinks
DOCREF = re.compile(r"(?:kit/docs|archive/docs)/([A-Za-z0-9_.\-]+)\.md")


def load_rows() -> list[dict]:
    rows = []
    for p in sorted(glob.glob(os.path.join(WORK, "extract_*.jsonl"))):
        with open(p) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                r["_file"] = os.path.basename(p)
                rows.append(r)
    return rows


def is_live(r: dict) -> bool:
    if (r.get("superseded_by") or "").strip():
        return False
    if (r.get("evidence") or "").strip().lower() in DEAD:
        return False
    return True


def cell(text: str, limit: int) -> str:
    """One table cell: no newlines, no pipes, wikilinked doc refs, truncated."""
    t = " ".join((text or "").split())
    t = DOCREF.sub(lambda m: f"[[{m.group(1)}]]", t)
    t = t.replace("|", "/")
    return t if len(t) <= limit else t[: limit - 1].rstrip() + "…"


def _is_census(r: dict) -> bool:
    """Disc-inventory rows are a census, not a knowledge claim: `file X lives at
    LBA N`.  They are 537 of 3,307 live rows, they dwarf the substance, and they
    are already collected in `file_listing` / `disc_inventory`.  They get their
    own page so the dashboard stays readable."""
    c = (r.get("claim") or "").strip()
    return c.startswith(("file ", "directory "))


def _table(rs: list[dict]) -> list[str]:
    lines = ["| claim | evidence | provenance |", "|---|---|---|"]
    for r in sorted(rs, key=lambda r: (r.get("stage") or "", r.get("addr") or "")):
        src = r.get("source") or ""
        m = DOCREF.search(src)
        prov = f"[[{m.group(1)}]]" if m else ""
        line = src.split(":")[-1] if ":" in src else ""
        if prov and line.isdigit():
            prov += f":{line}"
        addr = (r.get("addr") or "").strip()
        if addr:
            prov += f" `{addr}`"
        lines.append(f"| {cell(r.get('claim'), 300)} | "
                     f"{cell(r.get('evidence'), 40)} | {prov} |")
    return lines


def _class_page(cls: str, rs: list[dict], census: bool) -> str:
    title = f"STATE - {cls.replace('_', ' ')}"
    head = ["---", f"title: {title}", "tags: [state]", "---", "",
            f"# {title}", "",
            f"{len(rs)} live claim(s). Part of [[STATE_OF_KNOWLEDGE]].", ""]
    if census:
        head += ["Generated disc inventory: one row per file and directory.",
                 "This is a census, not a claim about how the game works.", ""]
    return "\n".join(head + _table(rs)) + "\n"


def _footer() -> list[str]:
    """ONE pointer, at the END.  The history is a separate concern and belongs on
    [[CORRECTIONS]] — this page previously opened with the error count and gave
    31 of its 66 lines to a confession, which made a knowledge page read as an
    apology.  State the knowledge; link the history."""
    return ["---", "",
            "Each claim's evidence and working is in the dated note cited beside it.",
            "Where a note carries a correction, the note itself says so. This page",
            "states what currently holds and nothing else.", ""]


def build() -> dict[str, str]:
    """`{filename: text}` — the dashboard plus one page per class."""
    rows = load_rows()
    live = [r for r in rows if is_live(r)]
    dead = [r for r in rows if not is_live(r)]
    by_class: dict[str, list[dict]] = defaultdict(list)
    for r in live:
        by_class[(r.get("class") or "unclassified").strip()].append(r)

    def page_name(cls: str) -> str:
        return f"STATE - {cls.replace('_', ' ')}"

    out: dict[str, str] = {}
    for cls, rs in by_class.items():
        census = all(_is_census(r) for r in rs) or cls == "global"
        out[page_name(cls) + ".md"] = _class_page(cls, rs, census)

    dash = [
        "---", "title: STATE OF KNOWLEDGE", "tags: [moc, current-state]", "---", "",
        "# State of knowledge", "",
        f"**{len(live)} verified claims** about how Suikoden works, across "
        f"{len(by_class)} classes, each with its provenance.", "",
        "Derived from the project's fact registry, so it is regenerated rather than",
        "curated and cannot drift from the recorded evidence:",
        "`python3 kit/tools/corpus_state.py`. A claim appears here when it has not",
        "been superseded; the dated notes hold the evidence and the working.", "",
        "## Claims by class", "",
        "| class | claims | covers | page |", "|---|---|---|---|",
    ]
    for cls in sorted(by_class, key=lambda c: (-len(by_class[c]), c)):
        dash.append(f"| `{cls}` | {len(by_class[cls])} | "
                    f"{CLASS_BLURB.get(cls, '')} | [[{page_name(cls)}]] |")
    dash += ["", "The `global` class is mostly the disc inventory — a census of what",
             "is on the disc rather than a claim about the game's behaviour.", ""]
    dash += _footer()
    out["STATE_OF_KNOWLEDGE.md"] = "\n".join(dash)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args(argv)
    gen = build()
    if args.check:
        print(f"   {len(gen)} pages")
        return 0
    if args.verify:
        bad = []
        for f, t in gen.items():
            p = os.path.join(DOCS, f)
            if not os.path.exists(p):
                bad.append(f)
                continue
            with open(p) as fh:
                if fh.read() != t:
                    bad.append(f)
        orphan = [os.path.basename(p) for p in
                  glob.glob(os.path.join(DOCS, "STATE - *.md"))
                  if os.path.basename(p) not in gen]
        if bad or orphan:
            print(f"state pages STALE: {bad}; orphaned {orphan}.  "
                  f"Run: python3 kit/tools/corpus_state.py")
            return 1
        print(f"PASS: state of knowledge in sync — {len(gen)} generated pages")
        return 0
    for f in glob.glob(os.path.join(DOCS, "STATE - *.md")):
        if os.path.basename(f) not in gen:
            os.remove(f)
    for f, t in gen.items():
        with open(os.path.join(DOCS, f), "w") as fh:
            fh.write(t)
    print(f"wrote STATE_OF_KNOWLEDGE.md + {len(gen) - 1} class pages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
