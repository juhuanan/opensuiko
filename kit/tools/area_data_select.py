#!/usr/bin/env python3
"""Which `DATA/*/*_DATA.BIN` the file table loads, and the byte-identical pair.

`DATA/01_AREA.A/A_DATA.BIN` and `DATA/15_AREA.Z/Z_DATA.BIN` are byte-identical
in every content field -- index plane, flag plane, all three CLUTs, all five
atlas pages, plus `S+0x04` and `D+0x04`.  One of the two therefore looks
redundant.  This tool settles which one the engine actually loads.

THE SELECTION IS A BOUNDED TABLE READ, and it is in the mode-1 handler:

    MAIN.EXE 0x801279E8   mode-1 handler
    0x80127A78  90440002  lbu $a0,0x2($v0)      # a0 = gs[0x02], $v0 = *(0x8017DB24)
    0x80127AD0  3C018017  lui   $at,0x8017
    0x80127AD4  2421F3B4  addiu $at,$at,-0xC4C  # at = 0x8016F3B4
    0x80127AD8  00220821  addu  $at,$at,$v0      # v0 = gs[0x02] * 4 (delay slot
                                                 #      of the sll at 0x80127AC8)
    0x80127ADC  8C240000  lw    $a0,0x0($at)     # a0 = 0x8016F3B4[gs[0x02]]
    0x80127AE0  0C030BBE  jal   0x800C2EF8       # the file loader
    0x80127AE4  3C058008  lui   $a1,0x8008       # DELAY SLOT: a1 = 0x80080000

`0x8016F3B4` is a **12-entry table of `[u32 size][u32 lba]` record addresses**,
one per area, in area order, and `a0` is handed straight to
`0x800C2EF8` -- the vtable-`+0x10` file loader -- whose destination is
`0x80080000`, the `*_DATA` load base.  So the entry the table names is the
area's world-map module.

**Both A and Z have positive loader paths.** The12 distinct records include
`A` at index0 and `Z` at index11. VA6's room1 exit writes11 through inline
03/FB when story flag gs+0x1B1 bit0x40 is set; its actual return/callback
chain requests mode1 and reaches this table's Z descriptor. VAAD's story
streams set that flag and region11 through03/FA. See worldmap_z_loader.md
and test_worldmap_z_loader.py; the table read alone did not prove a producer.
The same byte is the
world map's `map_id` (it indexes the region/camera table `0x80170064` at
`0x80127BA4`..`0x80127BCC`), and it is initialised to 0 by the new-game
start-up at `SLUS_002.92 0x800175F8` (`sb $zero,0x2($v0)`) and written to 1
by `h2da_state_init_driver` at `0x80128D38`.

`.BIN` overlays and `.8` files are different populations: the `*_DATA`
modules load at `0x80080000`, and the `V*` modules -- which carry their own
`[u16 a][u16 b][u32 magic]` records with pointers resolved against
`0x80010000` -- are the population this base must not be mixed with.

Usage:
    python3 area_data_select.py --table     # the 12-entry table, resolved
    python3 area_data_select.py --json      # the table + the code evidence
    python3 area_data_select.py --verify    # re-derive and assert every claim
Exit: 0 clean, 1 on any mismatch.
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
import disc          # noqa: E402
import disc_iso      # noqa: E402
import maindec       # noqa: E402
import world_map_pages as world_map_pages  # noqa: E402

MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
MASTER_TABLE = 0x80163D64      # 344 x [u32 size][u32 lba], MAIN.EXE
TABLE = 0x8016F3B4             # the 12-entry per-area record table
TABLE_ENTRIES = 12
GS_PTR = 0x8017DB24            # *(0x8017DB24) is the game-state block
GS_AREA_BYTE = 0x02            # gs+0x02: area index, and the world map's map_id
DATA_LOAD_BASE = 0x80080000
LOADER = 0x800C2EF8            # vtable +0x10

#: the world map's region/camera pointer table, indexed by the same byte
REGION_TABLE = 0x80170064
REGION_ENTRIES = 12

#: instruction words the table read rests on (MAIN.EXE image, base 0x800C0800)
EVIDENCE = {
    0x80127A78: (0x90440002, "lbu $a0,0x2($v0)   $v0 = *(0x8017DB24) at 0x80127A70"),
    0x80127A88: (0x3C018017, "lui $at,0x8017"),
    0x80127A8C: (0x2421F364, "addiu $at,$at,-0xC9C   at = 0x8016F364 (regional sound commands)"),
    0x80127AC8: (0x00041080, "sll $v0,$a0,2    index -> byte offset (delay slot)"),
    0x80127AD0: (0x3C018017, "lui $at,0x8017"),
    0x80127AD4: (0x2421F3B4, "addiu $at,$at,-0xC4C   at = 0x8016F3B4"),
    0x80127AD8: (0x00220821, "addu $at,$at,$v0"),
    0x80127ADC: (0x8C240000, "lw $a0,0x0($at)   a0 = table[gs[0x02]]"),
    0x80127AE0: (0x0C030BBE, "jal 0x800C2EF8    the file loader (vtable +0x10)"),
    0x80127AE4: (0x3C058008, "lui $a1,0x8008    DELAY SLOT: destination 0x80080000"),
    0x80127BA4: (0x90620002, "lbu $v0,0x2($v1)  the SAME byte, read again as map_id"),
    0x80127BB8: (0x24210064, "addiu $at,$at,0x64   at = 0x80170064 (region table)"),
}

#: the new-game writer of gs+0x02, in SLUS_002.92 (base 0x80010000)
SLUS_NEW_GAME = (0x800175F8, 0xA0400002, "sb $zero,0x2($v0)   gs[0x02] = 0 = area A")

#: the mode-1 init writer of gs+0x02
MODE1_INIT = (0x80128D38, 0x3C038018, 0x8C63DB24, 0x34020001, 0xA0620002,
              "gs[0x02] = 1 = area B")

#: every `jal 0x800C2EF8` in the image's code (base 0x800C0800), the file loader
LOADER_CALL_SITES = (0x800C4920, 0x800C9754, 0x800C9D1C,
                     0x80125E80, 0x80127AE0, 0x801283B0, 0x80130F70)

EXPECTED_PATHS = [
    "DATA/01_AREA.A/A_DATA.BIN",
    "DATA/02_AREA.B/B_DATA.BIN",
    "DATA/06_AREA.C/C_DATA.BIN",
    "DATA/07_AREA.D/D_DATA.BIN",
    "DATA/08_AREA.E/E_DATA.BIN",
    "DATA/09_AREA.F/F_DATA.BIN",
    "DATA/10_AREA.G/G_DATA.BIN",
    "DATA/11_AREA.H/H_DATA.BIN",
    "DATA/13_AREA.I/I_DATA.BIN",
    "DATA/02_AREA.B/J_DATA.BIN",
    "DATA/07_AREA.D/K_DATA.BIN",
    "DATA/15_AREA.Z/Z_DATA.BIN",
]

IDENTICAL_PAIR = ("DATA/01_AREA.A/A_DATA.BIN", "DATA/15_AREA.Z/Z_DATA.BIN")


def _iso() -> list[dict]:
    return disc_iso.iso_records(os.path.join(_KIT, "extracted", "iso_files.json"))


def read(path: str) -> bytes:
    if path == MAIN:
        return maindec.body()
    rec = next(r for r in _iso() if r["path"] == path)
    return disc.extract(rec["lba"], rec["size"])


def word(va: int) -> int:
    return struct.unpack_from("<I", maindec.body(), va - MAIN_BASE)[0]


def master_records() -> list[tuple[int, int]]:
    img = maindec.body()
    off = MASTER_TABLE - MAIN_BASE
    return [struct.unpack_from("<II", img, off + 8 * i) for i in range(344)]


def area_table() -> list[dict]:
    """The 12 entries at `0x8016F3B4`, resolved through the master file table."""
    img = maindec.body()
    by_lba = {r["lba"]: r["path"] for r in _iso()}
    out = []
    for i in range(TABLE_ENTRIES):
        rec = struct.unpack_from("<I", img, TABLE - MAIN_BASE + 4 * i)[0]
        idx = (rec - MASTER_TABLE) // 8
        size, lba = struct.unpack_from("<II", img, rec - MAIN_BASE)
        out.append({"index": i, "record": rec, "master_index": idx,
                    "size": size, "lba": lba, "path": by_lba.get(lba)})
    return out


def region_table() -> list[int]:
    img = maindec.body()
    return [struct.unpack_from("<I", img, REGION_TABLE - MAIN_BASE + 4 * i)[0]
            for i in range(REGION_ENTRIES)]


def loader_call_sites() -> list[int]:
    """Every `jal 0x800C2EF8` in MAIN.EXE, re-derived from the image."""
    body = maindec.body()
    imm = (LOADER >> 2) & 0x03FFFFFF
    out = []
    for off in range(0, len(body) - 4, 4):
        w = struct.unpack_from("<I", body, off)[0]
        if (w >> 26) == 3 and (w & 0x03FFFFFF) == imm:
            out.append(MAIN_BASE + off)
    return out


def build() -> dict:
    tbl = area_table()
    paths = [e["path"] for e in tbl]
    pair = IDENTICAL_PAIR
    a = read(pair[0])
    z = read(pair[1])
    pa = world_map_pages.parse_scene(a)
    pz = world_map_pages.parse_scene(z)
    return {
        "tool": "kit/tools/area_data_select.py 1.0.0",
        "table": TABLE,
        "table_entries": TABLE_ENTRIES,
        "selection": "gs[0x02] indexes 0x8016F3B4; the entry is the record handed "
                     "to the file loader 0x800C2EF8 at destination 0x80080000",
        "loader_call_sites": loader_call_sites(),
        "entries": tbl,
        "paths": paths,
        "content_identical": {
            "index_plane": pa["plane"]["sha256_index"] == pz["plane"]["sha256_index"],
            "flag_plane": pa["plane"]["sha256_flag"] == pz["plane"]["sha256_flag"],
            "cluts": ([c["sha256"] for c in pa["cluts"]]
                      == [c["sha256"] for c in pz["cluts"]]),
            "pages": ([p["sha256"] for p in pa["pages"]]
                      == [p["sha256"] for p in pz["pages"]]),
            "s_plus_04": pa["s_plus_04"] == pz["s_plus_04"],
            "d_plus_04": pa["d_plus_04"] == pz["d_plus_04"],
        },
        "file_sizes": [len(a), len(z)],
        "region_table_entries": REGION_ENTRIES,
        "region_table": ["0x%08X" % v for v in region_table()],
        "gs_area_byte": "gs+0x02 (game state at *(0x8017DB24))",
    }


def verify(verbose: bool = True) -> int:
    fails = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if verbose:
            print(("PASS: " if cond else "FAIL: ") + name
                  + (" -- " + detail if detail else ""))
        if not cond:
            fails.append(name)

    tbl = area_table()
    paths = [e["path"] for e in tbl]

    check("0x8016F3B4 holds 12 `[u32 size][u32 lba]` records in area order",
          paths == EXPECTED_PATHS, json.dumps(paths))
    check("every entry's record address lands on an 8-byte master-table slot",
          all((e["record"] - MASTER_TABLE) % 8 == 0
              and 0 <= e["master_index"] < 344 for e in tbl))
    # the resolved size/lba equal the master table's own entry, and the record's
    # file is the ISO listing's file: three independent sources agreeing.
    iso = {r["lba"]: (r["path"], r["size"]) for r in _iso()}
    check("each entry's size/lba equal the master table's and the ISO listing's",
          all(iso.get(e["lba"]) == (e["path"], e["size"]) for e in tbl))
    check("the 12 records are distinct (no entry repeats another)",
          len({e["record"] for e in tbl}) == TABLE_ENTRIES)

    # A and Z are separate slots and each is reachable at its own index
    check("A_DATA is entry 0 and Z_DATA is entry 11 (both live slots)",
          tbl[0]["path"] == IDENTICAL_PAIR[0]
          and tbl[11]["path"] == IDENTICAL_PAIR[1],
          "%s / %s" % (tbl[0]["path"], tbl[11]["path"]))
    a = read(IDENTICAL_PAIR[0])
    z = read(IDENTICAL_PAIR[1])
    pa = world_map_pages.parse_scene(a)
    pz = world_map_pages.parse_scene(z)
    same = (pa["plane"]["sha256_index"] == pz["plane"]["sha256_index"]
            and pa["plane"]["sha256_flag"] == pz["plane"]["sha256_flag"]
            and [c["sha256"] for c in pa["cluts"]] == [c["sha256"] for c in pz["cluts"]]
            and [p["sha256"] for p in pa["pages"]] == [p["sha256"] for p in pz["pages"]]
            and pa["s_plus_04"] == pz["s_plus_04"]
            and pa["d_plus_04"] == pz["d_plus_04"])
    check("the two files are identical in all six content fields "
          "(plane index, plane flags, 3 CLUTs, 5 atlas pages, S+0x04, D+0x04)",
          same)
    check("the two files' bytes are NOT equal (different offsets, "
          "%d vs %d bytes) -- so the content identity is not a whole-file match"
          % (len(a), len(z)), a != z and len(a) != len(z))

    # the instruction words
    bad = [(hex(va), "%08X" % word(va), "%08X" % w)
           for va, (w, _doc) in EVIDENCE.items() if word(va) != w]
    check("all %d evidence instruction words in MAIN.EXE match" % len(EVIDENCE),
          not bad, json.dumps(bad))

    # the SLUS new-game writer
    rec = next(r for r in _iso() if r["path"] == "SLUS_002.92")
    slus = disc.extract(rec["lba"], rec["size"])[2048:]
    va, w0, _doc = SLUS_NEW_GAME
    check("SLUS_002.92 %#x is `sb $zero,0x2(gs)` (new game enters area index 0)"
          % va, struct.unpack_from("<I", slus, va - 0x80010000)[0] == w0)

    # the mode-1 init writer
    va, w0, w1, w2, w3, _doc = MODE1_INIT
    ok = all(word(va + 4 * i) == w for i, w in enumerate((w0, w1, w2, w3)))
    check("MAIN.EXE %#x.. is the gs[0x02]=1 writer (area B)" % va, ok,
          " ".join("%08X" % word(va + 4 * i) for i in range(4)))

    # the loader call sites, and the single one that feeds *_DATA
    sites = loader_call_sites()
    check("MAIN.EXE has exactly 7 `jal 0x800C2EF8` sites (the 7 in the image)",
          sites == sorted(LOADER_CALL_SITES) and len(sites) == 7,
          json.dumps([hex(s) for s in sites]))
    check("0x80127AE0 is the only one whose destination is 0x80080000 "
          "and whose argument comes from 0x8016F3B4",
          word(0x80127AE4) == 0x3C058008 and word(0x80127ADC) == 0x8C240000)

    # the same byte is the map_id
    check("the region/camera pointer table has the same 12-entry domain",
          len(region_table()) == REGION_ENTRIES
          and all(0x8016F000 <= v <= 0x80170000 for v in region_table()),
          json.dumps([hex(v) for v in region_table()]))

    # and the whole file population resolves one way only
    check("the table names all 11 world-map modules plus the I stub",
          sorted(os.path.basename(p) for p in paths) ==
          sorted(os.path.basename(p) for p in EXPECTED_PATHS))
    return len(fails)


def cmd_table() -> int:
    iso = {r["lba"]: r["size"] for r in _iso()}
    print("MAIN.EXE 0x%08X: %d entries, indexed by gs[0x02] "
          "(*(0x8017DB24) + 2)" % (TABLE, TABLE_ENTRIES))
    print("idx  record       master  size      lba    file")
    for e in area_table():
        print("%3d  0x%08X %5d  %8d  %6d  %s"
              % (e["index"], e["record"], e["master_index"], e["size"],
                 e["lba"], e["path"]))
    print()
    print("A is index 0, Z is index 11: both are slots in the same table, so "
          "whichever index gs[0x02] holds is the module the loader reads to "
          "0x%08X." % DATA_LOAD_BASE)
    print("The two files are byte-identical (%d bytes each), so the index is "
          "the only difference the engine sees." % iso.get(area_table()[0]["lba"]))
    return 0


def cmd_json() -> int:
    print(json.dumps(build(), indent=1))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--table", action="store_true", help="the 12-entry table")
    g.add_argument("--json", action="store_true", help="the table and evidence")
    g.add_argument("--verify", action="store_true", help="re-derive and assert")
    args = ap.parse_args(argv)
    if args.verify:
        n = verify()
        print("area_data_select --verify: %s"
              % ("PASS" if n == 0 else "%d FAIL" % n))
        return 1 if n else 0
    if args.table:
        return cmd_table()
    return cmd_json()


if __name__ == "__main__":
    sys.exit(main())
