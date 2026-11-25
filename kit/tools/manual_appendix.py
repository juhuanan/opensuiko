#!/usr/bin/env python3
"""Generate the manual's appendices from the fact registry and the pages' own citations.

The manual under `manual/` is hand-written, closed-ended prose: it states what the
game does and never argues with itself. Evidence lives in three GENERATED appendices
so that a claim cannot quietly outlive its proof:

  * `appendix-a-routines.md`    every virtual address cited anywhere in the manual,
                                with the page that cites it and, where the labels
                                file knows it, the routine's name.
  * `appendix-b-open-questions.md`  the one place in the manual that admits a gap.
                                Generated from registry rows whose `evidence` is
                                `open`, so a page can stay silent about the unknown
                                instead of hedging.
  * `appendix-c-provenance.md`  the per-page mapping from a page to the instruction
                                addresses it rests on and the registry claims that
                                mention those addresses.

Usage:
    python kit/tools/manual_appendix.py            # write the three appendices
    python kit/tools/manual_appendix.py --verify   # fail if they are out of date
    python kit/tools/manual_appendix.py --check    # report counts, write nothing
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANUAL = ROOT / "manual"
WORK = ROOT / "kit" / "data" / "registry"
LABELS = ROOT / "kit" / "data" / "catalogs" / "function_labels.csv"

GENERATED = ("appendix-a-routines.md", "appendix-b-open-questions.md",
             "appendix-c-provenance.md")

# A virtual address, as the pages write them. Anchored to 0x80 so that small
# constants (0x1AF4, 0x2258) are not mistaken for addresses.
ADDR_RE = re.compile(r"\b0x(80[0-9A-Fa-f]{6})\b")


def pages() -> list[Path]:
    """The hand-written manual pages, in reading order.

    The set comes from the TABLE OF CONTENTS, not from a glob. The contents are the
    manual's manifest -- the link gate already treats them that way -- and globbing
    instead let a stray file promote itself: a zero-byte `$var.md` left by a bad shell
    redirect became a "page", got a section in Appendix C, and was thereby linked from
    the contents' own appendix, which made the orphan check pass. Taking the manifest as
    the source of truth closes that loop.
    """
    toc = MANUAL / "README.md"
    listed: list[str] = []
    if toc.exists():
        for raw in re.findall(r"\[[^\]]*\]\(([^)]+)\)", toc.read_text(encoding="utf-8")):
            name = raw.strip().split("#", 1)[0].strip()
            if name.endswith(".md") and name not in GENERATED and name != "README.md":
                if name not in listed:
                    listed.append(name)
    out = [MANUAL / n for n in listed if (MANUAL / n).is_file()]
    if not out:                                    # no manifest yet: fall back
        out = [p for p in sorted(MANUAL.glob("*.md"))
               if p.name not in GENERATED and p.name != "README.md"]
    return out


def title(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return path.stem


def citations(text: str) -> list[str]:
    """Distinct addresses cited in a page, in first-appearance order."""
    seen, out = set(), []
    for m in ADDR_RE.finditer(text):
        a = "0x" + m.group(1).upper()
        if a not in seen:
            seen.add(a)
            out.append(a)
    return out


def load_labels() -> dict[str, str]:
    """address -> routine name, from the tracked labels file if it is present."""
    out: dict[str, str] = {}
    if not LABELS.exists():
        return out
    import csv
    with LABELS.open(newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            # the labels file has ragged rows; DictReader yields None keys for them
            keys = {k.strip().lower(): (v or "").strip()
                    for k, v in row.items() if isinstance(k, str)}
            addr = keys.get("address") or keys.get("addr") or keys.get("va") or ""
            name = keys.get("name") or keys.get("label") or keys.get("function") or ""
            if addr.startswith("0x") and name:
                out[addr.upper()] = name
    return out


def registry() -> list[dict]:
    rows: list[dict] = []
    for path in sorted(WORK.glob("extract_*.jsonl")):
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            r["_file"] = path.name
            rows.append(r)
    return rows


def norm_addr(value) -> str | None:
    if not isinstance(value, str):
        return None
    m = re.search(r"0x(80[0-9A-Fa-f]{6})", value)
    return ("0x" + m.group(1).upper()) if m else None


HEADER = "<!-- GENERATED by kit/tools/manual_appendix.py -- do not edit by hand. -->\n"


def render_a(ps: list[Path], labels: dict[str, str]) -> str:
    cites: dict[str, list[str]] = {}
    for p in ps:
        for a in citations(p.read_text(encoding="utf-8")):
            cites.setdefault(a, []).append(p.name)
    lines = [
        "# Appendix A — Routine index",
        "",
        "Every virtual address cited anywhere in this manual, with the page that cites it. "
        "Generated from the pages themselves, so it cannot fall out of step with them.",
        "",
        f"**{len(cites)} addresses across {len(ps)} pages.**",
        "",
        "| Address | Routine | Cited by |",
        "|---|---|---|",
    ]
    for a in sorted(cites, key=lambda x: int(x, 16)):
        who = ", ".join(f"[{n}]({n})" for n in sorted(set(cites[a])))
        lines.append(f"| `{a}` | {labels.get(a, '—')} | {who} |")
    lines += ["", "## See also", "",
              "- [The manual's table of contents](README.md)",
              "- [Appendix B — Open questions](appendix-b-open-questions.md)",
              "- [Appendix C — Provenance](appendix-c-provenance.md)", ""]
    return "\n".join(lines)


def render_b(rows: list[dict]) -> str:
    opens = [r for r in rows if (r.get("evidence") or "").strip() == "open"]
    opens.sort(key=lambda r: ((r.get("class") or ""), (r.get("addr") or "")))
    lines = [
        "# Appendix B — Open questions",
        "",
        "What is not yet determined. This is the only place in the manual that admits a "
        "gap: the sections themselves state what the game does and stay silent about the "
        "rest, rather than hedging. Generated from registry rows whose evidence is `open`, "
        "so the list cannot drift from the fact registry.",
        "",
        f"**{len(opens)} open questions.**",
        "",
    ]
    if not opens:
        lines += ["None recorded.", ""]
    else:
        by_class: dict[str, list[dict]] = {}
        for r in opens:
            by_class.setdefault(r.get("class") or "(unclassified)", []).append(r)
        for cls in sorted(by_class):
            lines += [f"## {cls}", "",
                      "| Address | Question | Source |", "|---|---|---|"]
            for r in by_class[cls]:
                claim = (r.get("claim") or "").replace("|", "\\|").strip()
                addr = r.get("addr") or "—"
                src = r.get("_file") or ""
                lines.append(f"| `{addr}` | {claim} | `{src}` |")
            lines.append("")
    lines += ["## See also", "",
              "- [The manual's table of contents](README.md)",
              "- [Appendix C — Provenance](appendix-c-provenance.md)", ""]
    return "\n".join(lines)


def render_c(ps: list[Path], rows: list[dict]) -> str:
    by_addr: dict[str, list[dict]] = {}
    for r in rows:
        a = norm_addr(r.get("addr"))
        if a:
            by_addr.setdefault(a, []).append(r)
    lines = [
        "# Appendix C — Provenance",
        "",
        "The mapping from each page of this manual to the instruction addresses it rests "
        "on and the registry claims that mention those addresses. The prose is written by "
        "hand; this page is generated, so a statement cannot outlive the evidence for it.",
        "",
        "**The claim text below is quoted verbatim from the fact registry.** The registry "
        "is an error record by design, so some rows quote an earlier correction or name "
        "what a claim supersedes. That wording is the registry's, not the manual's: the "
        "pages themselves carry no history, and this appendix is the one place where the "
        "evidence is reproduced as it was recorded.",
        "",
    ]
    for p in ps:
        addrs = citations(p.read_text(encoding="utf-8"))
        linked = [(a, by_addr[a]) for a in addrs if a in by_addr]
        lines += [f"## [{title(p)}]({p.name})", "",
                  f"{len(addrs)} addresses cited; {len(linked)} have registry claims.", ""]
        if linked:
            lines += ["| Address | Registry claim | Evidence | Source |",
                      "|---|---|---|---|"]
            for a, rs in linked:
                for r in rs:
                    claim = (r.get("claim") or "").replace("|", "\\|").strip()
                    if len(claim) > 160:
                        claim = claim[:157].rstrip() + "…"
                    ev = (r.get("evidence") or "").strip()
                    lines.append(f"| `{a}` | {claim} | {ev} | `{r.get('_file')}` |")
            lines.append("")
    lines += ["## See also", "",
              "- [The manual's table of contents](README.md)",
              "- [Appendix A — Routine index](appendix-a-routines.md)", ""]
    return "\n".join(lines)


def build() -> dict[str, str]:
    ps = pages()
    rows = registry()
    labels = load_labels()
    return {
        "appendix-a-routines.md": HEADER + render_a(ps, labels),
        "appendix-b-open-questions.md": HEADER + render_b(rows),
        "appendix-c-provenance.md": HEADER + render_c(ps, rows),
    }


def main(argv: list[str]) -> int:
    mode = "write"
    if "--verify" in argv:
        mode = "verify"
    elif "--check" in argv:
        mode = "check"

    out = build()
    if mode == "check":
        for name, text in out.items():
            print(f"  {name}: {len(text.splitlines())} lines")
        print(f"manual appendices: {len(pages())} pages, up to date check skipped")
        return 0

    if mode == "verify":
        bad = []
        for name, text in out.items():
            path = MANUAL / name
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current != text:
                bad.append(name)
        if bad:
            print("FAIL: manual appendices are out of date: " + ", ".join(bad))
            print("      run: python kit/tools/manual_appendix.py")
            return 1
        print(f"PASS: manual appendices in sync ({len(out)} files, {len(pages())} pages)")
        return 0

    MANUAL.mkdir(parents=True, exist_ok=True)
    for name, text in out.items():
        (MANUAL / name).write_text(text, encoding="utf-8")
    print(f"wrote {len(out)} appendices from {len(pages())} pages and "
          f"{len(registry())} registry rows")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
