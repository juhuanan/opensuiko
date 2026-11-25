#!/usr/bin/env python3
"""The per-area encounter table in the `DATA/*/*_DATA.BIN` overlays.

**What was already known (do not re-derive).** `battle_placement_resolved.md`
§3 resolves the encounter *struct* and its consumer: the enemy IDs are bytes at
`encounter+4+slot` (six slots, zero skips an actor), and `aux = *(encounter+0x14)`
dereferences to the position table. It also gives the pointer chain that selects
one encounter:

```
D          = *(80080000)                  # area descriptor, word 0 of the file
resources  = *(D + 0x0C)
directory  = *resources
selectors  = *(directory + 0x08)          # [count, encounter pointers...]
encounter  = *(selectors + 4*gs[1BC0])
```

`enemy_sprites.find_enemy_tables` separately locates the per-area **enemy roster**
(`u32 count` + `count` record pointers; each record `+0x2C` -> its sprite
section), which is what bounds the IDs used here.

**What this tool adds.** It validates the whole class instead of one example: it
chases `selectors` in each of the nine area files the corpus's root layout
supports and **validates every struct the pointer array names** -- 100 of 100
pointers resolve to a struct, and in all 90 of them two fields are constant
(`+0xC` = 100, `+0x10` = 0) and every ID is within the area's roster. It also
re-derives the per-area counts (A-H sum = **77**, `E` = **11**) that
`battle_placement_resolved.md` records, from the disc bytes alone.

**A model this tool disproves, deliberately kept.** The structs are *not* a
contiguous `0x18`-stride table. That is a tempting reading -- `D`, `F` and `H`
happen to be exactly `0x18`-spaced, and for `E` and `Z` the first pointer sits
where a `selectors - 0x18*count` table would start -- but the real spacings
include `0x30`, `0x48`, `0x60`, `0x78` and **negative** gaps, so the pointers are
not sorted and the structs are not packed. An earlier version of this tool
computed `start = selectors - 0x18*count`, which *forces* the table to end at
`selectors` and then "found" a stride; it reported 127 records where the truth is
90. `--stride-trap` reproduces that circular result so the mistake stays visible.

Struct layout (all 90 validated structs agree):

```
+0x00  u32  active         the number of NON-ZERO roster bytes -- see below
+0x04  u8   roster[6]      six enemy ID slots, 1-based into the area's enemy
                           roster; 0 = empty slot (consumed at 0x800DEEF4)
+0x0A  u16  0              padding
+0x0C  u32  100            constant in all 90 structs
+0x10  u32  0              constant in all 90 structs
+0x14  u32  aux            RAM pointer, in-file (corpus: `positions = *aux`)
```

**The corroborated field.** `active` at `+0x00` is not a slot span: it equals
the number of non-zero bytes in `roster[6]` in **90 of 90** structs, with zero
mismatches, and its distribution over the nine areas is 1:21, 2:23, 3:16, 4:17,
5:9, 6:4. That is a *test*, not a delimiter -- nothing in the walk uses it to
find the structs -- and it is what makes the six-byte roster reading a
derivation rather than a guess. The roster is always six bytes wide, which
matches the corpus's "visits all **six roster slots**" at `0x800DEE44`.

**Probe vs inference.** *Proven*: the pointer array resolves 100/100, the field
offsets, the two constant fields across all 90 structs, that every ID is within
the file's enemy-roster count, the A-H sum of 77 and `E` = 11, and that the
structs are **not** uniformly strided. *Disproven here*: that the structs form a
contiguous `0x18`-stride table.
*Inference*: calling the table "the encounter table" follows the corpus's own
`battle_placement_resolved.md` §3, which resolves the consumer; the tool
does not re-derive that consumer. *Not derived*: the meaning of the constant
`100`, and the structure of the `aux` chain (the corpus documents it as
`positions = *aux`; this tool only checks the pointer is in-file).

**A negative this tool also carries.** The `class` column of
`kit/extracted/bin_overlay_inventory_final.csv` labels 233 files `DATA/TABLE`,
and that label is **unsound**: it was assigned by absence of a function prologue,
and the "code share" heuristic it leans on scores **100 %** on a run of zeros
(opcode 0 is in the workhorse set) -- see `--code-test`, which reproduces the
false positive at `VC61.BIN` 0x7000. Use `--triage` instead, which counts
`jr $ra` and `addiu sp,sp,-N` prologues.

Usage:
    python3 area_encounter_tables.py --encounters
    python3 area_encounter_tables.py --triage
    python3 area_encounter_tables.py --code-test
    python3 area_encounter_tables.py --json kit/work/area_tables.json
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import enemy_sprites as _es  # noqa: E402

ISO = os.path.join(_KIT, "extracted", "iso_files.json")
INVENTORY_CSV = os.path.join(_KIT, "extracted", "bin_overlay_inventory_final.csv")

BASE = 0x80080000        # load base of the area `*_DATA.BIN` overlays
STRIDE = 0x18            # encounter record size
PRIMARY = "ABCDEFGH"     # the eight areas whose chain the corpus supports
CONST_0C = 100
CONST_10 = 0
MAX_SLOTS = 8            # the id field is 8 bytes wide


def iso_files() -> list[dict]:
    with open(ISO) as f:
        return [r for r in json.load(f) if not r.get("dir")]


def area_data_files() -> list[dict]:
    """The eleven `DATA/*/*_DATA.BIN` overlays, in area order."""
    out = []
    for r in iso_files():
        b = os.path.basename(r["path"])
        if b.endswith("_DATA.BIN") and r["size"] > 0x1000:
            out.append(r)
    return sorted(out, key=lambda r: r["path"])


def load(rec: dict) -> bytes:
    return disc.extract(rec["lba"], rec["size"])


def u32(d: bytes, off: int) -> int:
    return struct.unpack_from("<I", d, off)[0]


def chain(d: bytes, base: int = BASE):
    """The corpus's descriptor chain. Returns `(D, resources, directory, selectors)`
    as RAM addresses, or raises `ValueError` when a link leaves the file."""
    n = len(d)

    def rd(addr: int) -> int:
        off = addr - base
        if not (0 <= off <= n - 4):
            raise ValueError("chain link 0x%08X is outside the file" % addr)
        return u32(d, off)

    D = u32(d, 0)
    if not (base <= D < base + n):
        raise ValueError("word 0 (0x%08X) is not an in-file pointer" % D)
    resources = rd(D + 0x0C)
    directory = rd(resources)
    selectors = rd(directory + 0x08)
    return D, resources, directory, selectors


def selectors_table(d: bytes, selectors: int):
    """`(count, [pointer addresses])` for `selectors = [count, ptr...]`."""
    off = selectors - BASE
    count = u32(d, off)
    if not (1 <= count <= 64) or off + 4 + 4 * count > len(d):
        raise ValueError("selectors count %d does not fit the file" % count)
    return count, [u32(d, off + 4 + 4 * i) for i in range(count)]


def encounter_structs(d: bytes, selectors: int, section_count: int | None = None):
    """The encounter structs named by `selectors`, each one validated.

    A failure is an error, not a silent skip: the claim is that *every* pointer
    resolves and *every* struct satisfies the layout.
    """
    count, ptrs = selectors_table(d, selectors)
    out = []
    for k, p in enumerate(ptrs):
        o = p - BASE
        if not (0 <= o <= len(d) - STRIDE):
            raise ValueError("struct %d: 0x%08X is outside the file" % (k, p))
        active = u32(d, o)
        roster = list(d[o + 4 : o + 0x0A])          # always six slots
        nonzero = sum(1 for x in roster if x)
        const_0c, const_10 = u32(d, o + 0x0C), u32(d, o + 0x10)
        aux = u32(d, o + 0x14)
        if active != nonzero:
            raise ValueError("struct %d: active=%d but roster %s has %d non-zero"
                             % (k, active, roster, nonzero))
        if const_0c != CONST_0C:
            raise ValueError("struct %d: +0xC is %d, not %d" % (k, const_0c, CONST_0C))
        if const_10 != CONST_10:
            raise ValueError("struct %d: +0x10 is %d, not 0" % (k, const_10))
        if not (BASE <= aux < BASE + len(d)):
            raise ValueError("struct %d: aux 0x%08X is outside the file" % (k, aux))
        if section_count is not None and any(x > section_count for x in roster):
            raise ValueError("struct %d: roster %s exceeds the roster count %d"
                             % (k, roster, section_count))
        out.append({"index": k, "off": o, "active": active, "roster": roster,
                    "ids": [x for x in roster if x], "aux": aux,
                    "padding_nonzero": any(d[o + 0x0A : o + 0x0C])})
    return count, ptrs, out


def gaps(ptrs: list[int]) -> list[int]:
    """Signed spacing between consecutive struct pointers."""
    return [ptrs[i + 1] - ptrs[i] for i in range(len(ptrs) - 1)]


def encounter_count_raw(d: bytes, selectors: int) -> int:
    return u32(d, selectors - BASE)


def stride_trap(d: bytes, selectors: int):
    """Reproduce the circular `start = selectors - 0x18*count` reading.

    Kept so the mistake in this tool's first version stays reproducible: it
    forces the table to end at `selectors` and then reports a stride that was
    assumed rather than measured.
    """
    count = u32(d, selectors - BASE)
    start = selectors - BASE - STRIDE * count
    if start < 0:
        return 0, start
    k = 0
    while start + (k + 1) * STRIDE <= len(d):
        o = start + k * STRIDE
        if k >= count:
            break
        k += 1
    return k, start


def sections_for(d: bytes):
    """The area's enemy roster, via the corpus's `enemy_sprites` detector.

    `parse_sections` returns `(sections, errors)`.
    """
    sections, _errors = _es.parse_sections(d)
    return _es.find_enemy_tables(d, sections)


def area_encounters() -> list[dict]:
    """Every area: roster count, selectors, validated encounter structs."""
    out = []
    for r in area_data_files():
        d = load(r)
        row = {"file": r["path"], "lba": r["lba"], "size": r["size"]}
        try:
            _D, _res, _dir, sel = chain(d)
        except ValueError as e:
            row["error"] = str(e)
            out.append(row)
            continue
        tables = sections_for(d)
        row["roster_count"] = tables[0]["count"] if tables else None
        row["selectors"] = sel
        try:
            count, ptrs, structs = encounter_structs(d, sel, row["roster_count"])
            row["encounter_count"] = count
            row["structs"] = structs
            row["gaps"] = gaps(ptrs)
            row["constants"] = sorted({(u32(d, s["off"] + 0x0C),
                                        u32(d, s["off"] + 0x10)) for s in structs})
        except ValueError as e:
            row["error"] = str(e)
        out.append(row)
    return out


# ---------------------------------------------------------------------------
# code/data triage
# ---------------------------------------------------------------------------

def code_signals(d: bytes) -> dict:
    """Count the two signals that actually distinguish MIPS code from data.

    * `jr $ra` (0x03E00008) -- every real function ends with one.
    * `addiu sp,sp,-N` with a sane N -- the standard prologue.

    Deliberately NOT used: opcode-share, which scores 100 % on a run of zeros.
    """
    jr = pro = 0
    for i in range(0, len(d) - 4, 4):
        w = u32(d, i)
        if w == 0x03E00008:
            jr += 1
        elif (w >> 26) == 0x09 and ((w >> 21) & 31) == 29 and ((w >> 16) & 31) == 29:
            imm = w & 0xFFFF
            if 0 < imm < 0x2000:
                pro += 1
    return {"jr_ra": jr, "prologues": pro}


def verdict(d: bytes) -> str:
    s = code_signals(d)
    if s["jr_ra"] >= 2 or s["prologues"] >= 2:
        return "CODE"
    if s["jr_ra"] or s["prologues"]:
        return "CODE?"
    return "DATA"


def workhorse_share(d: bytes, off: int, span: int = 0x800) -> float:
    """The unsound heuristic, kept so its failure mode stays reproducible."""
    work = {0, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF}
    c = collections.Counter()
    for i in range(off, min(off + span, len(d)) - 4, 4):
        c[u32(d, i) >> 26] += 1
    return 100.0 * sum(v for k, v in c.items() if k in work) / max(1, sum(c.values()))


def triage() -> list[dict]:
    """Reclassify the tracked `DATA/TABLE` class by content."""
    import csv
    with open(INVENTORY_CSV) as f:
        rows = list(csv.DictReader(f))
    by_path = {r["path"]: r for r in iso_files()}
    out = []
    for r in rows:
        if not r["class"].startswith("DATA"):
            continue
        rec = by_path.get(r["file"])
        if rec is None or rec["size"] < 16:
            continue
        d = load(rec)
        s = code_signals(d)
        out.append({"file": r["file"], "size": rec["size"],
                    "old_class": r["class"], "verdict": verdict(d),
                    "jr_ra": s["jr_ra"], "prologues": s["prologues"]})
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--encounters", action="store_true")
    ap.add_argument("--triage", action="store_true")
    ap.add_argument("--stride-trap", action="store_true",
                    help="reproduce the circular 0x18-stride reading this tool first made")
    ap.add_argument("--code-test", action="store_true",
                    help="reproduce the unsound heuristic's zero-run false positive")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    if args.code_test:
        rec = next(r for r in iso_files() if r["path"] == "DATA/06_AREA.C/VC61.BIN")
        d = load(rec)
        best = (0.0, 0)
        for a in range(0, len(d) - 0x800, 0x800):
            s = workhorse_share(d, a)
            if s > best[0]:
                best = (s, a)
        s, a = best
        seg = d[a : a + 0x20]
        print("VC61.BIN: best 'code share' window %.1f%% at 0x%06X" % (s, a))
        print("  bytes:", seg.hex())
        print("  all zero:", not any(seg))
        print("  jr $ra =", code_signals(d)["jr_ra"],
              " prologues =", code_signals(d)["prologues"])
        print("  => the heuristic's maximum is a zero run. It is unsound.")
        return 0

    if args.triage:
        rows = triage()
        c = collections.Counter(r["verdict"] for r in rows)
        print("re-triaged %d DATA-class files by content:" % len(rows))
        for k, v in c.most_common():
            print("  %-6s %4d" % (k, v))
        print("\nfiles the old class called DATA/TABLE that are CODE by jr $ra:")
        for r in rows:
            if r["verdict"].startswith("CODE") and not r["file"].endswith("_DATA.BIN"):
                print("  %-40s jr=%-4d pro=%-4d size=%d"
                      % (r["file"], r["jr_ra"], r["prologues"], r["size"]))
        return 0

    if args.stride_trap:
        print("The circular reading: start = selectors - 0x18*count, i.e. the")
        print("table is *defined* to end at selectors, then 'validated'.\n")
        print("%-14s %-6s %-8s %s" % ("file", "count", "trap_n", "note"))
        for r in area_data_files():
            d = load(r)
            try:
                _D, _res, _dir, sel = chain(d)
            except ValueError:
                continue
            count = encounter_count_raw(d, sel)
            n, start = stride_trap(d, sel)
            print("%-14s %-6d %-8d table 0x%06X..0x%06X"
                  % (os.path.basename(r["path"]), count, n, start, sel - BASE))
        print("\nThe real structs are at the `selectors` pointer targets, which are")
        print("NOT 0x18 apart. See --encounters.")
        return 0

    data = area_encounters()
    if args.json:
        with open(args.json, "w") as f:
            json.dump(data, f, indent=1)
        print("wrote", args.json)
    if args.encounters or not args.json:
        tot = ok = 0
        print("%-14s %-6s %-10s %-4s %-4s %-22s %s" %
              ("file", "roster", "selectors", "cnt", "ok", "signed gaps", "ids used"))
        for row in data:
            b = os.path.basename(row["file"])
            if "error" in row:
                print("%-14s %-6s %-10s %-4s %-4s %s" %
                      (b, row.get("roster_count", "-"), "-", "-", "-", row["error"]))
                continue
            ids = sorted({x for s in row["structs"] for x in s["roster"] if x})
            tot += row["encounter_count"]
            ok += len(row["structs"])
            g = ",".join(("%+d" % x) for x in sorted(set(row["gaps"])))
            acts = sorted({s["active"] for s in row["structs"]})
            print("%-14s %-6s 0x%08X %-4d %-4d %-22s %s" %
                  (b, row["roster_count"], row["selectors"], row["encounter_count"],
                   len(row["structs"]), g[:22], ids))
        prim = sum(r.get("encounter_count", 0) for r in data
                   if os.path.basename(r["file"])[0] in PRIMARY)
        print("\nvalidated structs = %d of %d named by selectors" % (ok, tot))
        import collections as _c
        dist = _c.Counter(s["active"] for r in data for s in r.get("structs", []))
        print("active-count distribution: %s"
              % ", ".join("%d:%d" % kv for kv in sorted(dist.items())))
        print("primary A-H encounter count = %d  (corpus records 77)" % prim)
    return 0


if __name__ == "__main__":
    sys.exit(main())
