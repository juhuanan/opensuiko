#!/usr/bin/env python3
"""Extract the printable strings from the WAR mode's files, classified.

The war overlays (`DATA/16_WAR/WAR_*.BIN`) and their scenario data (`WAR1.BIN`)
are PSY-Q builds that kept their symbol names and their libgs debug printf
strings, so a string dump is close to a source-level map of the mode. This tool
does not decode anything: it reports offsets and bytes, and classifies each run so
the three kinds stay distinguishable.

  printf   contains a '%' conversion -- a debug or UI format string
  symbol   a bare C identifier or dotted name, no spaces -- a symbol or opcode name
  step     begins with "STEP " -- a named script step
  text     anything else printable (window labels, dialogue, resource names)

Usage:
    war_strings.py                     # every WAR file, summary + counts
    war_strings.py --file WAR1.BIN     # one file, every string
    war_strings.py --anomalies         # the strings that are NOT plain ASCII
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402

_KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_ISO = os.path.join(_KIT, "extracted", "iso_files.json")
WAR_DIR = "DATA/16_WAR/"

_PRINTF = re.compile(r"%[-+ #0-9.]*[diouxXeEfgGcspr%]")
_SYMBOL = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{2,}$")


def war_files():
    with open(_ISO) as f:
        recs = json.load(f)
    out = {}
    for r in recs:
        p = r.get("path", "")
        if p.startswith(WAR_DIR) and not r.get("dir"):
            out[p.rsplit("/", 1)[-1]] = r
    return out


def load(name):
    r = war_files()[name]
    return disc.extract(r["lba"], r["size"]), r


def strings(data, min_len=4):
    """[(offset, bytes)] of printable runs, including 0x0A and 0x09 inside a run."""
    out = []
    start = None
    for i, b in enumerate(data):
        ok = 32 <= b < 127 or b in (0x09, 0x0A)
        if ok and start is None:
            start = i
        elif not ok and start is not None:
            if i - start >= min_len:
                out.append((start, data[start:i]))
            start = None
    if start is not None and len(data) - start >= min_len:
        out.append((start, data[start:]))
    return out


def cstrings(data, min_len=4):
    """Only runs that are NUL-DELIMITED and preceded by a NUL, i.e. real C strings.

    `strings()` takes any printable run, which inside a code section matches MIPS
    instruction bytes constantly: `0x3C 0x64 0x38 0x22` is `lui $a0,0x3822` and
    also reads as the text `<d8"`. Requiring a NUL on both sides removes almost all
    of that, so a bare identifier reported here is a name the build actually
    emitted rather than four opcode bytes that happen to be letters.
    """
    out = []
    n = len(data)
    # offset 0 counts as preceded by a NUL: that is where `war_init_routine` sits,
    # and requiring a real leading NUL silently dropped the one symbol we had.
    data = b"\0" + data
    n = len(data)
    i = 0
    while i < n:
        if data[i] != 0:
            i += 1
            continue
        j = i + 1
        while j < n and data[j] != 0:
            j += 1
        if j - (i + 1) >= min_len:
            out.append((i, data[i + 1:j]))       # the offset in the ORIGINAL file
        i = j
    return out


def symbol_names(data, min_len=4):
    """`(offset, name)` for NUL-delimited runs that look like identifiers."""
    out = []
    for off, raw in cstrings(data, min_len):
        try:
            s = raw.decode("ascii")
        except UnicodeDecodeError:
            continue
        s = s.strip()
        if _SYMBOL.match(s):
            out.append((off, s))
    return out


def printf_strings(data, min_len=4):
    """`(offset, format)` for NUL-delimited runs containing a conversion."""
    out = []
    for off, raw in cstrings(data, min_len):
        try:
            s = raw.decode("ascii")
        except UnicodeDecodeError:
            continue
        if _PRINTF.search(s):
            out.append((off, s))
    return out


def classify(raw):
    s = raw.decode("ascii", "replace")
    if s.startswith("STEP "):
        return "step", s
    if _PRINTF.search(s):
        return "printf", s
    body = s.strip()
    if body and _SYMBOL.match(body):
        return "symbol", body
    return "text", s


def dump(name, verbose=False, min_len=4):
    data, rec = load(name)
    found = [(off, k, s) for off, raw in strings(data, min_len)
             for k, s in [classify(raw)]]
    counts = {}
    for _o, k, _s in found:
        counts[k] = counts.get(k, 0) + 1
    print("=== %s  (%d B, lba %d)  %d strings: %s"
          % (name, len(data), rec["lba"], len(found),
             ", ".join("%s=%d" % kv for kv in sorted(counts.items()))))
    if verbose:
        for off, kind, s in found:
            show = s.replace("\n", "\\n").replace("\t", "\\t")
            print("  %-7s %#08x  %s" % (kind, off, show))
    return found, counts


def anomalies(name, min_len=6):
    """Runs that LOOK like they should be text but are not clean ASCII.

    A symbol table read with the wrong stride, or a compressed block, shows up
    here as near-miss printable runs.
    """
    data, _rec = load(name)
    out = []
    for i in range(0, len(data) - min_len):
        run = data[i:i + min_len]
        if all(32 <= b < 127 for b in run):
            continue
        # a run with exactly one non-printable byte in an otherwise ASCII window
        win = data[max(0, i - 24):i + 24]
        printable = sum(1 for b in win if 32 <= b < 127)
        if printable >= 40 and any(32 <= b < 127 for b in run):
            out.append((i, bytes(win)))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--file", default=None, help="dump one file in full")
    ap.add_argument("--min", type=int, default=4, help="minimum run length")
    ap.add_argument("--anomalies", action="store_true")
    ap.add_argument("--names", action="store_true",
                    help="NUL-delimited identifier names only (real symbols)")
    ap.add_argument("--printf", dest="printfs", action="store_true",
                    help="NUL-delimited format strings only")
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "war_strings.txt"))
    args = ap.parse_args(argv)

    if args.names or args.printfs:
        names = sorted(war_files()) if not args.file else [args.file]
        for name in names:
            data, _r = load(name)
            fns = symbol_names(data, args.min) if args.names \
                else printf_strings(data, args.min)
            seen = []
            for off, s in fns:
                if args.names and s not in seen:
                    seen.append(s)
            print("=== %s: %d" % (name, len(fns)))
            if args.names:
                for k in range(0, len(seen), 6):
                    print("   " + "  ".join(seen[k:k + 6]))
            else:
                for off, s in fns:
                    print("  %#08x  %s" % (off, s.replace("\n", "\\n")))
        return 0

    if args.file:
        dump(args.file, verbose=True, min_len=args.min)
        return 0

    lines = []
    for name in sorted(war_files()):
        found, counts = dump(name, min_len=args.min)
        lines.append("=== %s ===" % name)
        for off, kind, s in found:
            lines.append("%-7s %#08x  %s"
                         % (kind, off, s.replace("\n", "\\n")))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\nfull dump -> %s (%d lines)" % (args.out, len(lines)))

    if args.anomalies:
        for name in sorted(war_files()):
            a = anomalies(name)
            print("%s: %d near-miss windows" % (name, len(a)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
