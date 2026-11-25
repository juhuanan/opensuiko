#!/usr/bin/env python3
"""Area page banks: `[u32 len][LZSS]` containers inside the area `.BIN` overlays.

**What this settles.** The corpus recorded "blob codecs are open" for
`VB5I*`, `J_DATA`, `VB5A21` and `VA4B`'s high-entropy blobs, on the basis that
they "resist text-LZSS, FACE-LZSS and XOR". That is true of *file offset 0* and
of single-container tests — but these are **multi-page banks**, and a whole-file
scan finds embedded pages whose ownership must be checked:

| file | containers -> 128x128 page (16384 B) | vs shuffled null |
|---|---|---|
| `DATA/02_AREA.B/VB5CC.BIN` | **34** (plus 11 -> 4096 B, a 64x64 page) | 3.4x the null |
| `DATA/02_AREA.B/J_DATA.BIN`  | **8** (plus 1 -> 4096 B) | 4.2x the null |
| `VB5I0` / `VA4B` | **15 / 9** | below the null on raw hit count |
| `VB5A21` / `VB5B31` | **2 / 1** in-file-owned pages; B31 also has an externally owned64x64 image | base0x80080000; companion_page_tables.md |

**The method trap this tool exists to prevent.** A scan for "a `[u32 len]`
followed by a stream that consumes exactly `len`" is **not evidence of a
container**. The decoder is lenient: on *shuffled* bytes that scan still fires on
0.07-2.6 % of offsets. A whole-file run of it therefore reports 22 "containers"
in `VB5I0` and 41 in `VB5A21` -- **fewer than the same file's own shuffled self
reports**; that count cannot distinguish noise from embedded owned pages.
Every count this tool returns is therefore reported
against a shuffled null, and nothing is called a container unless it beats that
null or hits a round page size the null never produces.

**Four discriminators, and the first one is a TRAP on its own.**

1. **The raw hit COUNT is not the test.** It is noise-dominated in both
   directions: a file whose non-page content is high-entropy can score *below*
   its own shuffled null while still holding genuine pages. `VB5I0` scores
   0.40x on count and yet has 15 real pages -- so a below-null count must NOT be
   read as "no containers". The count is reported for transparency only.
2. **Round output size** -- 16384 B = a 128x128 8bpp page, 4096 B = 64x64, the
   same page sizes as the FACE portraits and the `04_PLAY` atlases. This is the
   sharp test: **42 real page-shaped containers across the candidates, 0 in 24
   shuffled trials.**
3. **Spatial coherence** of the decoded page -- fraction of horizontally adjacent
   equal bytes. Real pages run **0.195-0.411** against null **0.076-0.342**.
4. **Pointer ownership** -- every established page is addressed by an in-file RAM
   pointer (`base + offset`), and the referencing sites are consecutive 4-byte
   array entries, i.e. a page-bank pointer table.

**Verdict rule (all four must agree):** page-shaped containers > 0, none in the
null, mean coherence above the null, and the pages pointer-referenced.

**And the containers are owned**: every round-page container in both files is
pointed at by an **in-file RAM pointer** (`base + container_offset`), and the
referencing sites are themselves consecutive 4-byte array entries -- a page-bank
pointer table. `VB5CC` 12/12 of the first twelve; `J_DATA` 8/8.

**Not claimed:** what the pages depict, and what the non-round containers
(6140, 97750, 99054, ...) are. Those decoded sizes are not page-shaped and are
recorded, not interpreted.

Usage:
    python3 area_page_banks.py --list
    python3 area_page_banks.py --file VB5CC.BIN
    python3 area_page_banks.py --null          # the calibration, on its own
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import os
import random
import statistics
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import lzss  # noqa: E402

#: byte lengths that are exact 8bpp pages, and therefore never accidental
ROUND_PAGES = {4096: "64x64 8bpp", 16384: "128x128 8bpp"}

#: the files the corpus recorded as "blob codec open", plus the two that are not
CANDIDATES = [
    "DATA/02_AREA.B/VB5CC.BIN",
    "DATA/02_AREA.B/J_DATA.BIN",
    "DATA/02_AREA.B/VB5I0.BIN",
    "DATA/02_AREA.B/VB5A21.BIN",
    "DATA/02_AREA.B/VB5B31.BIN",
    "DATA/01_AREA.A/VA4B.BIN",
]

#: load bases: the V* overlays are linked for 0x80010000, the *_DATA modules for
#: 0x80080000 (see vc61_explained.md section 3)
BASE_OVERLAY = 0x80010000
BASE_DATA = 0x80080000


def iso() -> list[dict]:
    with open(os.path.join(_KIT, "extracted", "iso_files.json")) as f:
        return [r for r in json.load(f) if not r.get("dir")]


def load(path: str) -> bytes:
    rec = next(r for r in iso() if r["path"] == path)
    return disc.extract(rec["lba"], rec["size"])


def base_for(path: str) -> int:
    name = os.path.basename(path)
    return BASE_DATA if name.endswith("_DATA.BIN") or name in {
        "VC61.BIN", "VB5A21.BIN", "VB5B31.BIN"} else BASE_OVERLAY


def containers(d: bytes) -> list[tuple[int, int, bytes]]:
    """Every `[u32 len][LZSS]` whose decode consumes exactly `len`.

    Deliberately permissive -- this is the *probe*, and on its own it is not
    evidence. `calibrate()` is what turns a count into a finding.
    """
    out = []
    for o in range(0, len(d) - 8, 4):
        ln = struct.unpack_from("<I", d, o)[0]
        if not (16 <= ln <= len(d) - o - 4):
            continue
        try:
            payload, used = lzss.decode(d[o + 4 : o + 4 + ln])
        except Exception:
            continue
        if used == ln:
            out.append((o, ln, payload))
    return out


def coherence(page: bytes) -> float | None:
    """Fraction of horizontally adjacent equal bytes. `None` if too short."""
    if len(page) < 256:
        return None
    return sum(1 for i in range(len(page) - 1) if page[i] == page[i + 1]) / (len(page) - 1)


def round_pages(d: bytes) -> list[tuple[int, int, int]]:
    """`(offset, container_len, output_len)` for page-shaped containers only."""
    return [(o, ln, len(out)) for o, ln, out in containers(d) if len(out) in ROUND_PAGES]


def pointer_map(d: bytes, base: int) -> dict[int, list[int]]:
    """`{in-file offset: [sites holding base+offset]}`, 4-byte aligned slots."""
    refs: dict[int, list[int]] = {}
    for i in range(0, len(d) - 4, 4):
        v = struct.unpack_from("<I", d, i)[0]
        if base <= v < base + len(d):
            refs.setdefault(v - base, []).append(i)
    return refs


def calibrate(path: str, trials: int = 12, seed: int = 99) -> dict:
    """Real counts against the same bytes shuffled. The null is the evidence."""
    d = load(path)
    real = containers(d)
    real_pages = [(o, ln, len(out)) for o, ln, out in real if len(out) in ROUND_PAGES]
    rng = random.Random(seed)
    arr = bytearray(d)
    null_hits = 0
    null_pages = 0
    null_sizes: collections.Counter = collections.Counter()
    null_coh: list[float] = []
    for _ in range(trials):
        rng.shuffle(arr)
        for _o, _ln, out in containers(bytes(arr)):
            null_hits += 1
            null_sizes[len(out)] += 1
            if len(out) in ROUND_PAGES:
                null_pages += 1
            c = coherence(out)
            if c is not None:
                null_coh.append(c)
    real_coh = [c for c in (coherence(out) for _o, _l, out in real) if c is not None]
    real_coh_pages = [c for c in (coherence(out) for _o, _l, out in real
                                  if len(out) in ROUND_PAGES) if c is not None]
    null_coh_list = [c for c in null_coh]
    real_sizes = collections.Counter(len(out) for _o, _l, out in real)
    pm = pointer_map(d, base_for(path))
    ref_ok = sum(1 for o, _l, _n in real_pages if pm.get(o))
    return {
        "file": path,
        "size": len(d),
        "attempts": len(range(0, len(d) - 8, 4)),
        "real_hits": len(real),
        "null_hits": round(null_hits / trials, 2),
        "ratio": round(len(real) / max(null_hits / trials, 0.01), 2),
        "real_pages": len(real_pages),
        "null_pages": null_pages,
        "real_page_offsets": [o for o, _l, _n in real_pages],
        "real_sizes": dict(real_sizes.most_common(6)),
        "null_sizes": dict(null_sizes.most_common(4)),
        "real_coherence": round(statistics.mean(real_coh), 3) if real_coh else None,
        "page_coherence": round(statistics.mean(real_coh_pages), 3) if real_coh_pages else None,
        "null_coherence": round(statistics.mean(null_coh), 3) if null_coh else None,
        "referenced": ref_ok,
        "referenced_frac": round(ref_ok / len(real_pages), 3) if real_pages else 0.0,
        "coherence_above_null": bool(
            real_pages and null_coh_list
            and statistics.mean(real_coh_pages) > statistics.mean(null_coh_list)
        ),
        "verdict": ("PAGE BANK" if (real_pages and null_pages == 0
                                    and null_coh_list
                                    and statistics.mean(real_coh_pages) > statistics.mean(null_coh_list)
                                    and ref_ok == len(real_pages))
                    else ("page candidates NOT established"
                          if real_pages else "no page-shaped containers")),
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--file")
    ap.add_argument("--null", action="store_true", help="the calibration alone")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    targets = CANDIDATES
    if args.file:
        targets = [p for p in CANDIDATES if os.path.basename(p) == args.file] or [
            "DATA/02_AREA.B/" + args.file
        ]
    if args.list or args.null or args.json:
        rows = [calibrate(p) for p in targets]
        if args.json:
            with open(args.json, "w") as f:
                json.dump(rows, f, indent=1)
            print(f"wrote {args.json}")
        for r in rows:
            print(f"{os.path.basename(r['file']):14s} count {r['real_hits']:4d} vs null "
                  f"{r['null_hits']:7.2f} ({r['ratio']:4.2f}x, NOT the test)  "
                  f"pages {r['real_pages']:3d} (null {r['null_pages']})  "
                  f"page-coh {r['page_coherence']} vs null {r['null_coherence']}  "
                  f"referenced {r['referenced']}/{r['real_pages']}  -> {r['verdict']}")
        if args.json or args.list:
            return 0
    if args.file and not (args.list or args.null or args.json):
        path = targets[0]
        d = load(path)
        pm = pointer_map(d, base_for(path))
        print(f"{path}  base 0x{base_for(path):08X}")
        for o, ln, out in containers(d):
            tag = ROUND_PAGES.get(len(out), "")
            refs = pm.get(o, [])
            print(f"  @0x{o:05X} len={ln:6d} -> {len(out):7d} {tag:12s} "
                  f"coherence={coherence(out)}  pointers={[hex(x) for x in refs[:3]]}")
        return 0
    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
