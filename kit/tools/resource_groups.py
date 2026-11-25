#!/usr/bin/env python3
"""The resource-group directory: how `VC61.BIN` (and friends) are loaded.

`VC61.BIN` was the last genuinely unexplained file in the overlay class
(`vc61_explained.md`).  This tool resolves the chain that loads it, and
with it *what it is*.

The chain, read from instructions:

```
base = *(0x8017C20C)                 ; the subsystem struct
dir  = *(base + 0x14b8) = 0x8016B358 ; the resource-group directory
grp  = dir[15]          = 0x8016B670 ; <- { VC61, VB5A21, VB5B31 }
rec  = grp[index]                    ; a file record (size, lba) in MAIN's master table
fn   = gs[0x1bc4][0x10] = 0x800C2EF8 ; the FILE LOADER
fn(rec, dest)                        ; load it
```

`gs[0x1bc4]` is a vtable installed by the same init that installs `dir`
(`0x800C960C..0x800C9650`); its `+0x10` slot is `0x800C2EF8`, the loader, so the
directory entries are passed straight to the loader.

**What `VC61` is.**  The three members of group 15 are the **data companions of
code overlays**, named by the convention `<overlay>` + `1`:

| code overlay | `jr $ra` | companion | `jr $ra` |
|---|---|---|---|
| `VC6.BIN` | 67 (CODE) | **`VC61.BIN`** | 0 (DATA) |
| `VB5A2.BIN` | 80 (CODE) | `VB5A21.BIN` | 0 (DATA) |
| `VB5B3.BIN` | 74 (CODE) | `VB5B31.BIN` | 0 (DATA) |

So **`VC61.BIN` is the data companion of the `VC6.BIN` overlay** — area C's scene
overlay.  This *restores* the "VC6 + 1" name reading arrived at early in the
session, with the corrected reason: not "the contiguously-loaded second part of
VC6" (that was refuted — `0x80080000` is the shared `*_DATA` base) but **the data
module belonging to that overlay**.

**What is still open.**  The *contents* of the three companions (VC61 carries
eleven `0x30`-byte records of twelve 16.16 values; see
`vc61_explained.md`), and whether index 0 is ever selected — `VC6.BIN`
itself is not among the 14 overlays that read `dir[15]`.

Usage:
    python3 resource_groups.py --groups           # the 16 groups
    python3 resource_groups.py --consumers        # who reads dir[15], and which index
    python3 resource_groups.py --companions       # the <overlay> -> <overlay>1 pairs
    python3 resource_groups.py --json kit/work/resource_groups.json
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
import disc_iso  # noqa: E402

MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
MASTER_TABLE = 0x80163D64
MASTER_COUNT = 344
#: the subsystem struct, and the directory slot the init installs
STRUCT_PTR = 0x8017C20C
DIR_SLOT = 0x14B8
DIR = 0x8016B358
#: the vtable whose +0x10 is the loader
VTABLE = 0x80165608
LOADER = 0x800C2EF8
GROUPS = 16
JR_RA = 0x03E00008
OVERLAY_BASE = 0x80010000


def _iso():
    return disc_iso.iso_records(os.path.join(_KIT, "extracted", "iso_files.json"))


def main_image() -> bytes:
    return disc_iso.main_image(os.path.join(_KIT, "extracted", "iso_files.json"))


def _path_for_lba(lba: int):
    return next((r["path"] for r in _iso() if r["lba"] == lba), None)


def groups() -> list[dict]:
    """The 16 load groups: `dir[i]` -> the file records it lists."""
    img = main_image()
    out = []
    for i in range(GROUPS):
        g = struct.unpack_from("<I", img, DIR - MAIN_BASE + 4 * i)[0]
        files, go = [], g - MAIN_BASE
        for k in range(64):
            v = struct.unpack_from("<I", img, go + 4 * k)[0]
            if not (MASTER_TABLE <= v < MASTER_TABLE + MASTER_COUNT * 8):
                break
            size, lba = struct.unpack_from("<II", img, v - MAIN_BASE)
            files.append({"size": size, "lba": lba, "path": _path_for_lba(lba),
                          "record": (v - MASTER_TABLE) // 8})
        out.append({"index": i, "group": g, "files": files})
    return out


def vtable() -> list[int]:
    img = main_image()
    return [struct.unpack_from("<I", img, VTABLE - MAIN_BASE + 4 * i)[0] for i in range(24)]


def _jr_count(path: str) -> int:
    rec = next(r for r in _iso() if r["path"] == path)
    d = disc.extract(rec["lba"], rec["size"])
    return sum(1 for i in range(0, len(d) - 4, 4) if struct.unpack_from("<I", d, i)[0] == JR_RA)


def companions() -> list[dict]:
    """`<overlay>1` -> its `<overlay>` code overlay, with the code/data evidence.

    The convention runs the other way from the obvious one: the DIRECTORY member
    is the data module and its name is the code overlay's name plus `1`.  So
    `VC61` -> `VC6`, `VB5A21` -> `VB5A2`, `VB5B31` -> `VB5B3`.
    """
    out = []
    for g in groups():
        for f in g["files"]:
            data = f["path"]
            base = os.path.basename(data)
            if not base.endswith("1.BIN"):
                continue
            code = os.path.join(os.path.dirname(data), base[:-5] + ".BIN")
            if not any(r["path"] == code for r in _iso()):
                continue
            out.append({"group": g["index"], "code": code, "data": data,
                        "code_jr": _jr_count(code), "data_jr": _jr_count(data)})
    return out


def consumers() -> list[dict]:
    """Every overlay that reads `dir[*(base+0x14b8)]`, and the index it selects."""
    out = []
    for r in _iso():
        p = r["path"]
        b = os.path.basename(p)
        if not (p.startswith("DATA/") and (b.startswith("V") or b.endswith("_DATA.BIN"))):
            continue
        if r["size"] > 1_500_000:
            continue
        try:
            d = disc.extract(r["lba"], r["size"])
        except Exception:
            continue
        for i in range(0, len(d) - 20, 4):
            w = struct.unpack_from("<I", d, i)[0]
            if (w >> 26) != 0x23:
                continue
            imm = w & 0xFFFF
            imm = imm - 0x10000 if imm & 0x8000 else imm
            if imm != DIR_SLOT:
                continue
            rt = (w >> 16) & 0x1F
            idx = None
            for j in (1, 2, 3, 4):
                w2 = struct.unpack_from("<I", d, i + 4 * j)[0]
                if (w2 >> 26) == 0x23 and ((w2 >> 21) & 0x1F) == rt:
                    im2 = w2 & 0xFFFF
                    im2 = im2 - 0x10000 if im2 & 0x8000 else im2
                    if 0 <= im2 <= 0x3C and im2 % 4 == 0:
                        idx = im2 // 4
                    break
            if idx is not None:
                out.append({"file": p, "addr": OVERLAY_BASE + i, "index": idx})
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--groups", action="store_true")
    ap.add_argument("--consumers", action="store_true")
    ap.add_argument("--companions", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"groups": groups(), "consumers": consumers(),
                       "companions": companions(), "vtable": vtable()}, f, indent=1)
        print("wrote", args.json)
        return 0

    if args.groups:
        for g in groups():
            names = [os.path.basename(x["path"] or "?") for x in g["files"]]
            print(f"dir[{g['index']:2d}] 0x{g['group']:08X}  {names}")
        return 0

    if args.consumers:
        for c in consumers():
            g = groups()[c["index"]]
            names = [os.path.basename(x["path"] or "?") for x in g["files"]]
            print(f"  {os.path.basename(c['file']):12s} 0x{c['addr']:08X} "
                  f"-> dir[{c['index']}] {names}")
        return 0

    if args.companions:
        for c in companions():
            print(f"  {c['code']} (jr={c['code_jr']}) -> {c['data']} (jr={c['data_jr']})"
                  f"   group {c['group']}")
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
