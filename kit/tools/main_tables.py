#!/usr/bin/env python3
"""MAIN.EXE's long-tail data tables: items, equipment, places, characters.

The gap report (`kit/docs/asset_gap_report.md`) called the data/table
payload the largest remaining hole.  The *names* for those tables turned out to
be in MAIN.EXE as **fixed-stride records of NUL-terminated strings in the game's
own text encoding**, which is what makes the tables findable at all: the stride
is constant, so a run of consecutive readable names locates a table with no
guessed offset.

| table | base | stride | entries | name source |
|---|---|---|---|---|
| items | `0x80169798` | `0x24` | 66 | "Failure urn", "Octopus urn", ... |
| equipment | `0x80168780` | `0x28` | 58 | "Bandanna", "Headband", "Robe", ... |

Item record (36 B):

```
+0x00  name   NUL-terminated, game text encoding
+0x18  u32    PRICE              (Failure urn 20, Octopus urn 1000, Vase 5000, ...)
+0x1C  u32    CATEGORY mask      (0x1000 urns, 0x2000 dishes/statues, 0x4000 paintings)
+0x20  u32    unused here
```

Equipment record (40 B):

```
+0x00  name   NUL-terminated
+0x18  u32    PRICE              (Bandanna 50, Headband 300, Pointed hat 1200, ...)
+0x1C  u32    class/sub-type     (byte 0 is the class: 0x80 head, 0xA0 body;
                                  byte 2 is a sub-type: head 0x02/0x03,
                                  body 0x0C/0x18/0x1C/0x38)
+0x24  u32    running index      (byte 3: 1, 2, 5, 9, 14, 20, 27, 35 in the head
                                  group -- it does not restart at the body group)
```

**What is proven and what is not.** The stride, the entry counts, the names and
the price field are derived and pinned by `kit/tests/test_main_tables.py`. The
*meaning* of the `+0x1C` and `+0x24` words is only partly derived (the slot byte
tracks the head/body grouping, the running index increases monotonically inside
a group) and is reported raw rather than named.

Usage:
    python3 main_tables.py --items
    python3 main_tables.py --equip
    python3 main_tables.py --all --json kit/work/main_tables.json
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
import disc_iso  # noqa: E402
import war_text as _wt  # noqa: E402

MAIN_LBA = 17976
MAIN_SIZE = 757760          # 2048 header + image
MAIN_BASE = 0x800C0800      # t_addr of the image
NAME_TABLE_START = 0x800C0800  # image base
_ISO = os.path.join(_KIT, "extracted", "iso_files.json")

#: (label, base address, stride, proven entry count)
TABLES = [
    ("items", 0x80169798, 0x24, 66),
    ("equipment", 0x80168780, 0x28, 58),
]

#: the field offsets inside a record, as proven by `test_main_tables.py`
PRICE_OFF = 0x18

#: byte-packed NUL-terminated name lists, in index order.  These are not
#: fixed-stride: the names are laid end to end, so they are read by scanning.
#: `characters` is 124 long and its first 108 entries ARE the portrait index
#: (see `kit/docs/face_portraits_decoded.md` section 5c) -- the war
#: leader-quote table is indexed by it, which is the independent cross-check.
NAME_LISTS = [
    ("characters", 0x80170104, 0x80170780, 124),
    ("places", 0x80170780, 0x80170CA0, 43),
]


def read_name_list(label: str) -> list[dict]:
    """A byte-packed NUL-terminated name list, in order."""
    ent = next(t for t in NAME_LISTS if t[0] == label)
    _l, lo, hi, _count = ent
    img = main_image()
    alpha = set(range(0x11, 0x2B)) | set(range(0x2B, 0x45)) | {0x53, 0x5C, 0x10}
    a, b = lo - MAIN_BASE, hi - MAIN_BASE
    out = []
    i = a
    while i < b:
        if img[i] in alpha:
            j = i
            while j < b and img[j] in alpha:
                j += 1
            if 3 <= j - i <= 20 and j < b and img[j] == 0:
                name, _u = _wt.decode(img, i, j - i)
                out.append({"index": len(out), "off": i, "addr": MAIN_BASE + i,
                            "name": name})
                i = j
                continue
        i += 1
    return out


def main_image() -> bytes:
    return disc_iso.main_image(_ISO)      # strip the PS-EXE header: image[i] is MAIN_BASE + i


def _name(img: bytes, off: int, limit: int) -> str:
    name, _used = _wt.decode(img, off, limit)
    return name


def read_table(label: str) -> tuple[int, int, list[dict]]:
    """`(base, stride, records)` for a proven table."""
    ent = next(t for t in TABLES if t[0] == label)
    _l, base, stride, count = ent
    img = main_image()
    out = []
    for i in range(count):
        off = base - MAIN_BASE + i * stride
        raw = img[off : off + stride]
        name = _name(img, off, stride)
        price = struct.unpack_from("<I", raw, PRICE_OFF)[0]
        out.append(
            {
                "index": i,
                "off": off,
                "name": name,
                "price": price,
                "field_1c": struct.unpack_from("<I", raw, 0x1C)[0] if stride > 0x1C else None,
                "field_20": struct.unpack_from("<I", raw, 0x20)[0] if stride > 0x20 else None,
                "field_24": struct.unpack_from("<I", raw, 0x24)[0] if stride > 0x24 else None,
            }
        )
    return base, stride, out


def strided_name_tables(min_count: int = 12) -> list[dict]:
    """Every fixed-stride run of >= `min_count` readable names in MAIN.

    The stride is searched rather than assumed, so this is how the tables above
    were found -- and how a further one would be.
    """
    img = main_image()
    n = len(img)
    alpha = set(range(0x11, 0x2B)) | set(range(0x2B, 0x45)) | {0x53, 0x5C, 0x10}

    def ok(a):
        j = a
        while j < n and img[j] in alpha:
            j += 1
        return j if (j < n and img[j] == 0 and 3 <= j - a <= 24) else None

    found = []
    for stride in range(0x10, 0x44, 4):
        a = 0
        while a < n:
            if ok(a):
                cnt = 0
                cur = a
                while cur < n and ok(cur):
                    cnt += 1
                    cur += stride
                if cnt >= min_count:
                    name = _name(img, a, 32)
                    found.append({"base": MAIN_BASE + a, "off": a, "stride": stride,
                                  "count": cnt, "first": name})
                    a = cur
                else:
                    a += 1
            else:
                a += 1
    return found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--items", action="store_true")
    ap.add_argument("--equip", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--scan", action="store_true",
                    help="list every fixed-stride name run in MAIN")
    ap.add_argument("--characters", action="store_true",
                    help="the character name list (index == portrait index)")
    ap.add_argument("--places", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    if args.characters or args.places:
        for label, flag in (("characters", args.characters), ("places", args.places)):
            if not flag:
                continue
            recs = read_name_list(label)
            print(f"=== {label}: {len(recs)} names")
            for r in recs:
                print(f"  [{r['index']:3d}] 0x{r['addr']:08X} {r['name']}")
        return 0

    if args.scan:
        for t in sorted(strided_name_tables(), key=lambda t: (-t["count"], t["stride"])):
            print(f"  base 0x{t['base']:08X} stride 0x{t['stride']:02X} "
                  f"count={t['count']:3d} first={t['first']!r}")
        return 0

    if args.all or args.json:
        data = {}
        for label, _b, _s, _c in TABLES:
            base, stride, recs = read_table(label)
            data[label] = {"base": base, "stride": stride, "records": recs}
        if args.json:
            with open(args.json, "w") as f:
                json.dump(data, f, indent=1)
            print(f"wrote {args.json}")
        for label, d in data.items():
            print(f"{label}: {len(d['records'])} records, stride 0x{d['stride']:X}, "
                  f"base 0x{d['base']:08X}")
        return 0

    for label, flag in (("items", args.items), ("equipment", args.equip)):
        if not flag:
            continue
        base, stride, recs = read_table(label)
        print(f"=== {label}  0x{base:08X} stride 0x{stride:X}  {len(recs)} entries")
        for r in recs:
            print(f"  [{r['index']:3d}] {r['name'][:24]:26s} price={r['price']:7d} "
                  f"f1c=0x{r['field_1c']:08X}"
                  + (f" f24={r['field_24']}" if stride > 0x24 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
