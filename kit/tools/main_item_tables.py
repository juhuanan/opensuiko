#!/usr/bin/env python3
"""MAIN.EXE's global item-class tables: weapons, runes, unite attacks, consumables.

Companion to `main_tables.py` (items, equipment, characters, places) and to
`character_table.py` (the per-character stat template in SLUS_002.92).  This one
covers the tables **Tier 2 item C** asked about -- monsters, shops, recipes,
growth -- and records what IS there, what is only partly resolved, and what is a
proven negative.

PROBE vs INFERENCE is kept separate on purpose:

* `name_runs()` and `region_map()` are **probe**: they read NUL-terminated names
  out of the image with the game's own text table and report where they are.
  No stride is assumed.
* `weapons()`, `runes()`, `unite_attacks()`, `consumables()` are **inference**:
  they assert a stride and a count.  Each carries the field that corroborates
  it, marked `derived`, and every other field is reported raw.

What is PROVEN here (see `kit/docs/main_item_tables.md`):

| table | base | stride | count | corroborated by |
|---|---|---|---|---|
| weapons, tier names | `0x80166000` | `0x58`/weapon, 3 sub-records of `0x1C` | **16 weapons / 48 names** | the three names of every group are the same weapon's upgrade tiers (Wind Rod / Gale Rod / Gust Rod; Kirinji / Kirinji 2 / Kirinji 3; Darts / Ruby Darts / Crystal Darts) and land at exactly `+0`, `+0x1C`, `+0x38` in all 16 blocks |
| runes | `0x8016A1B0` | `0x24` | **31** | 31 distinct rune names, and the byte block inside each record is an ascending run |
| unite attacks | `0x8016CD0C` | `0x24` | **26** | 26 distinct "<who> attack" names |
| consumables | `0x801686CC` | `0x24` | **5** | Medicine, Antitoxin, Needle, Mega medicine, Escape talisman; the 6th `0x24` slot is `Bandanna`, i.e. the equipment table's first record, so 5 is the boundary |

What is NOT resolved, and is reported as such rather than guessed:

* **A second cluster of unite attacks.**  The run at `0x8016CD0C` is 26
  consecutive `0x24` records, but the surrounding name region holds **36**
  "<who> attack" names through `0x8016D17C` (adding e.g. "Martial arts attack",
  "Lepant family attack", "Master pupil attack").  The stride changes after
  record 26 and is **not resolved**.
* **The rest of the weapon-name region** (`0x80166580`..`~0x80167640`, ~49 more
  weapon names).  Its groups are still 3 names, but the first sub-record is
  `0x20` rather than `0x1C`, i.e. the fixed-stride reading does NOT extend.  Not
  claimed.
* **Field meanings** everywhere except where a corroboration is stated.  In
  particular the weapon power bytes (`+0x15` of each sub-record and the 4 bytes
  at `+0x54`) are reported raw: they are NOT monotone across tiers in general, so
  calling them "attack power" would be a guess.

Usage:
    python3 main_item_tables.py --weapons
    python3 main_item_tables.py --runes
    python3 main_item_tables.py --unite
    python3 main_item_tables.py --consumables
    python3 main_item_tables.py --map          # every name region in MAIN's data area
    python3 main_item_tables.py --json OUT.json
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import war_text as _wt  # noqa: E402

MAIN_BASE = 0x800C0800
MAX_NAME = 0x1C          # a name never spans a record boundary in these tables

#: (label, base address, stride, proven count, name offset inside the record)
TABLES = [
    ("weapons", 0x80166000, 0x58, 16, 0x00),
    ("runes", 0x8016A1B0, 0x24, 31, 0x00),
    ("unite_attacks", 0x8016CD0C, 0x24, 26, 0x00),
    ("consumables", 0x801686CC, 0x24, 5, 0x00),
]

#: the three tier sub-records inside one weapon block
WEAPON_SUB = (0x00, 0x1C, 0x38)
WEAPON_TAIL = 0x54


def image() -> bytes:
    """MAIN.EXE with the 2048-byte PS-X header stripped (image base 0x800C0800)."""
    with open(os.path.join(_KIT, "extracted", "iso_files.json")) as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def name_at(img: bytes, off: int, limit: int = MAX_NAME):
    """The NUL-terminated game-text name at `off`, or None.

    `limit` is the field width: a name that does not terminate inside it is not a
    name in this table, it is data that happens to use text-range bytes.
    """
    n = len(img)
    if off < 0 or off >= n or not _wt.is_text_byte(img[off]):
        return None
    j = off
    while j < off + limit and j < n and _wt.is_text_byte(img[j]):
        j += 1
    if j >= off + limit or j >= n or img[j] != 0 or j - off < 3:
        return None
    t, _used = _wt.decode(img, off, j - off)
    return t if t and t[0].isalnum() else None


def record(img: bytes, base: int, stride: int, i: int, name_off: int = 0) -> dict:
    o = base - MAIN_BASE + i * stride
    raw = img[o : o + stride]
    return {
        "index": i,
        "off": o,
        "addr": base + i * stride,
        "name": name_at(img, o + name_off, stride - name_off),
        "raw": raw.hex(),
    }


def table(label: str) -> list[dict]:
    """The claimed records of one table, with the name read at its proven offset."""
    _l, base, stride, count, name_off = next(t for t in TABLES if t[0] == label)
    img = image()
    return [record(img, base, stride, i, name_off) for i in range(count)]


def weapons() -> list[dict]:
    """16 weapons x 0x58; three tier names at +0x00 / +0x1C / +0x38.

    The `tiers` list is the corroborated part: three names per weapon, and the
    power bytes at `+0x15` of each sub-record plus the 4 bytes at `+0x54` are
    reported **raw** because their meaning is not derived.
    """
    img = image()
    out = []
    for i in range(16):
        o = 0x80166000 - MAIN_BASE + i * 0x58
        tiers = []
        for k, so in enumerate(WEAPON_SUB):
            nm = name_at(img, o + so, 0x1C)
            # the byte just above +0x14 -- the word at +0x14 is this value << 8
            word = struct.unpack_from("<I", img, o + so + 0x14)[0]
            tiers.append({"tier": k + 1, "name": nm, "off": so,
                          "word_14": word, "byte_15": img[o + so + 0x15]})
        out.append({
            "index": i, "addr": 0x80166000 + i * 0x58,
            "tiers": tiers,
            "names": [t["name"] for t in tiers],
            "tail_54": struct.unpack_from("<I", img, o + WEAPON_TAIL)[0],
        })
    return out


# --------------------------------------------------------------------------
# PROBE -- no stride assumed
# --------------------------------------------------------------------------

def name_runs(min_count: int = 8, strides=(0x24, 0x28, 0x58)):
    """Every run of >= `min_count` consecutive records that each start with a name.

    This is the instrument that found the tables; it assumes only that names are
    left-aligned in their record, which is what the proven tables do.
    """
    img = image()
    n = len(img)
    out = []
    for stride in strides:
        o = 0
        while o < n:
            cnt = 0
            cur = o
            while cnt < 400 and cur < n and name_at(img, cur, stride):
                cnt += 1
                cur += stride
            if cnt >= min_count:
                names = [name_at(img, o + stride * k, stride) for k in range(cnt)]
                out.append({"base": MAIN_BASE + o, "stride": stride, "count": cnt,
                            "first": names[0], "last": names[-1], "names": names})
                o = cur
            else:
                o += 1
    return out


def region_map() -> list[dict]:
    """Flat map of every named region in MAIN's data area, with its span.

    Reads names with no stride at all, then merges consecutive ones whose gap is
    below a threshold -- so the output is a map of where data *is*, not a claim
    about its record size.
    """
    img = image()
    lo, hi = 0x80166000 - MAIN_BASE, 0x8016D400 - MAIN_BASE
    hits = []
    i = lo
    while i < hi:
        nm = name_at(img, i, 0x30)
        if nm:
            hits.append((MAIN_BASE + i, nm))
            i += len(_wt.encode(nm)) + 1
        else:
            i += 1
    regions = []
    for addr, nm in hits:
        if regions and addr - regions[-1]["end"] < 0x60:
            regions[-1]["end"] = addr + len(_wt.encode(nm)) + 1
            regions[-1]["names"].append(nm)
        else:
            regions.append({"start": addr, "end": addr + len(_wt.encode(nm)) + 1,
                            "names": [nm]})
    for r in regions:
        r["count"] = len(r["names"])
        r["sample"] = r["names"][:3] + (["..."] if r["count"] > 6 else []) + r["names"][-3:]
    return [r for r in regions if r["count"] >= 3]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--weapons", action="store_true")
    ap.add_argument("--runes", action="store_true")
    ap.add_argument("--unite", action="store_true")
    ap.add_argument("--consumables", action="store_true")
    ap.add_argument("--runs", action="store_true")
    ap.add_argument("--map", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    if args.weapons:
        for w in weapons():
            print(f"  [{w['index']:2d}] 0x{w['addr']:08X} "
                  f"{' / '.join(str(t['name']) for t in w['tiers'])}"
                  f"   bytes+0x15={[t['byte_15'] for t in w['tiers']]} tail=0x{w['tail_54']:X}")
        return 0
    for label, flag in (("runes", args.runes), ("unite_attacks", args.unite),
                        ("consumables", args.consumables)):
        if flag:
            recs = table(label)
            print(f"=== {label}: {len(recs)} records")
            for r in recs:
                print(f"  [{r['index']:2d}] 0x{r['addr']:08X} {r['name']}")
            return 0
    if args.runs:
        for r in name_runs():
            print(f"  base 0x{r['base']:08X} stride 0x{r['stride']:X} count={r['count']:3d} "
                  f"{r['first']!r} .. {r['last']!r}")
        return 0
    if args.map:
        for r in region_map():
            print(f"  0x{r['start']:08X}..0x{r['end']:08X} n={r['count']:4d}  {r['sample']}")
        return 0
    if args.json:
        data = {label: table(label) for label, *_ in TABLES}
        data["weapons"] = weapons()
        with open(args.json, "w") as f:
            json.dump(data, f, indent=1)
        print(f"wrote {args.json}")
        return 0
    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
