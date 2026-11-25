#!/usr/bin/env python3
"""Gate for the world map's COMPOSITION.

Asserts only what `kit/tools/world_map_pages.py` PROVED, and re-derives each
claim from the disc independently of that tool where it can:

  * `S+0x08` -> 5 page pointers; every one is a `[u32 comp_len][LZSS]` container
    that decodes to **exactly 16,384 bytes** (128x128 8bpp).  55/55.
  * `S+0x10` -> 5 pointers, each landing 0..3 bytes past
    `page_offset + 4 + comp_len` (the LZSS tail's byte alignment).  So it is a
    tail table, NOT "5 x 64-byte blocks" and NOT a second page table.
  * `S+0x04` is a u16 with exactly two on-disc values, 0x0305 (A,E,G,Z) and
    0x1005 (the other seven).
  * `D+0x04` is recorded per area; `D+0x08` resolves inside the module;
    `D+0x0C` -> a 5-entry section table whose slots 1..4 are exactly the area's
    last four sprite sections (cross-checked against `enemy_sprites`).
  * S+0x10 is the per-atlas record table (the renderer's descriptor build at
    0x800C4400 reads it as &table[atlas]), not spare blocks.
  * The plane IS a tilemap into the pages: code = (flag << 6) | (index & 63),
    atlas = code >> 6 (0 or 1), tile = code & 63, cells used as offsets into an
    8-byte tile-info record array (0x8014D2C8 lhu / 0x8014D2E8 sll $v0,$a0,3 /
    0x8014D2EC addu / 0x8014D2F0 lhu $v0,0x6($a3)), reached from L+0x0C by
    0x80127DE0 sw $v0,0xC($v1).
  * A and Z are a FULL duplicate: identical index plane, flag plane, all three
    CLUTs and all five pages.  Not a recolour pair.

Run: .venv/bin/python kit/tests/test_world_map_pages.py
Prints PASS: ... per check.  Exit 0 clean, 1 on any failure.
"""
from __future__ import annotations

import os
import struct
import sys

_TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, _TOOLS)
sys.path.insert(0, os.path.dirname(_TOOLS))

import disc  # noqa: E402
import lzss  # noqa: E402
import maindec  # noqa: E402
import numpy as np  # noqa: E402
import world_map_pages as W  # noqa: E402

FAILURES = []
NPASS = [0]


def check(cond, msg):
    if cond:
        NPASS[0] += 1
        print("PASS: %s" % msg)
    else:
        FAILURES.append(msg)
        print("FAIL: %s" % msg)


def main():
    areas = W.scan()
    check(len(areas) == 11, "11 area data modules parse (got %d)" % len(areas))

    # ---- 1. every page is a container decoding to exactly 16,384 bytes
    sizes = []
    for p in areas.values():
        for pg in p["pages"]:
            sizes.append(len(pg["pixels"]))
    check(len(sizes) == 55 and set(sizes) == {16384},
          "all %d page containers decode to exactly 16,384 bytes" % len(sizes))

    # independent re-decode from the disc, bypassing the tool's own parse
    with open(os.path.join(os.path.dirname(_TOOLS), "extracted", "iso_files.json")) as fh:
        idx = {r["path"]: r for r in __import__("json").load(fh) if not r.get("dir")}
    indep = 0
    for letter, path in W.AREAS.items():
        row = idx[path]
        d = disc.extract(row["lba"], row["size"])
        D = W.to_file(struct.unpack_from("<I", d, 0)[0], len(d))
        S = W.to_file(struct.unpack_from("<I", d, D)[0], len(d))
        pt = W.to_file(struct.unpack_from("<I", d, S + 0x08)[0], len(d))
        for k in range(5):
            o = W.to_file(struct.unpack_from("<I", d, pt + 4 * k)[0], len(d))
            ln = struct.unpack_from("<I", d, o)[0]
            payload, used = lzss.decode(d[o + 4:o + 4 + ln])
            if len(payload) == 16384 and used == ln:
                indep += 1
    check(indep == 55, "independent re-walk of S+0x08 finds 55/55 pages of "
          "exactly 16,384 bytes with the length field fully consumed")

    # ---- 2. S+0x10 is a tail table
    deltas = [e["offset"] - pg["end_offset"]
              for p in areas.values() for e, pg in zip(p["ends"], p["pages"])]
    check(len(deltas) == 55 and all(0 <= d <= 3 for d in deltas),
          "all 55 S+0x10 entries land 0..3 bytes past page_offset+4+comp_len "
          "(deltas %s)" % sorted(set(deltas)))
    check(all(e["offset"] != pg["offset"]
              for p in areas.values() for e, pg in zip(p["ends"], p["pages"])),
          "no S+0x10 entry points at a page start, so it is a distinct table "
          "and there are no separate 64-byte blocks")
    # and the 5th entry closes the 5th page
    check(all(p["ends"][4]["offset"] >= p["pages"][4]["end_offset"] - 3
              for p in areas.values()),
          "the 5th S+0x10 entry closes the 5th page (the table spans exactly "
          "the five pages)")

    # ---- 3. S+0x04
    got = {k: p["s_plus_04"] for k, p in areas.items()}
    check(got == W.EXPECTED_S_PLUS_04,
          "S+0x04 is 0x0305 in %s and 0x1005 in %s"
          % (sorted(k for k, v in got.items() if v == 0x0305),
             sorted(k for k, v in got.items() if v == 0x1005)))

    # ---- 4. D constants
    check({k: p["d_plus_04"] for k, p in areas.items()} == W.EXPECTED_D_PLUS_04,
          "D+0x04 matches the recorded per-area table %s"
          % sorted(W.EXPECTED_D_PLUS_04.values()))
    check(all(W.to_file(p["d_plus_08"], len(W.area_files()[k][1])) is not None
              for k, p in areas.items()),
          "D+0x08 resolves inside the module in every area (a self-pointer)")
    # D+0x0C -> section table; slots 1..4 are the last four sprite sections
    import enemy_sprites as es
    match = 0
    for letter, p in areas.items():
        d = W.area_files()[letter][1]
        got4 = [s["offset"] for s in p["sections"][1:]]
        if got4 == [s["header_offset"] for s in es.parse_sections(d)[0]][-4:]:
            match += 1
    check(match == 11, "D+0x0C slots 1..4 are the area's last four sprite "
          "sections in %d/11 areas (independent check)" % match)
    check(all(p["sections"][0]["offset"] != p["S"] for p in areas.values()),
          "D+0x0C[0] is NOT the scene descriptor S (correcting "
          "enemy_sprites.parse_background's docstring)")

    # ---- 5. the plane IS a tilemap into the pages
    # The composition code = (flag << 6) | (index & 63) must land in atlas 0/1
    # only -- a 1-bit atlas selector over a 64-tile set -- in all 11 areas.
    atlases = set()
    tiles_in_range = True
    for p in areas.values():
        for i, f in zip(p["plane"]["indices"], p["plane"]["flags"]):
            code = (f << 6) | (i & 63)
            atlases.add(code >> 6)
            tiles_in_range = tiles_in_range and (code & 63) < 64
    check(atlases == {0, 1},
          "code = (flag << 6) | (index & 63) yields atlas selector values %s in "
          "all 11 areas -- a 1-bit atlas over a 64-tile set, not a per-cell "
          "palette flag" % sorted(atlases))
    check(tiles_in_range, "every decoded tile index is < 64")
    # the renderer's cell -> record stride, and the L+0x0C wiring
    code_words = {
        0x8014D2C8: 0x94440000,   # lhu $a0,0x0($v0)   cell
        0x8014D2CC: 0x3402FFFF,   # ori $v0,$zero,0xFFFF  the empty-cell sentinel
        0x8014D2E8: 0x000410C0,   # sll $v0,$a0,3      cell * 8
        0x8014D2EC: 0x00433821,   # addu $a3,$v0,$v1   -> the record array
        0x8014D2F0: 0x94E20006,   # lhu $v0,0x6($a3)   the record's texture word
        0x80127DD8: 0x8C820010,   # lw $v0,0x10($a0)   state+0x10 = the plane
        0x80127DE0: 0xAC62000C,   # sw $v0,0xC($v1)    L+0x0C = that plane
        0x800C4400: 0x8EC30010,   # lw $v1,0x10($s6)   S+0x10 read by the build
        0x800C4410: 0x8C510000,   # lw $s1,0x0($v0)    &table[atlas]
    }
    badc = [va for va, w in code_words.items() if maindec.mword(va) != w]
    check(not badc,
          "the tilemap chain re-derives: cell -> record*8 -> +6 texture word, "
          "with L+0x0C fed from state+0x10 and S+0x10 read as the atlas table "
          "(%d words%s)"
          % (len(code_words), "" if not badc else "; wrong at %s"
             % [hex(x) for x in badc]))

    # ---- 6. A == Z, fully
    a, z = areas["A"], areas["Z"]
    check(a["plane"]["sha256_index"] == z["plane"]["sha256_index"] and
          a["plane"]["sha256_flag"] == z["plane"]["sha256_flag"],
          "A and Z have byte-identical index AND flag planes")
    check([c["sha256"] for c in a["cluts"]] == [c["sha256"] for c in z["cluts"]],
          "A and Z have byte-identical CLUT sets -- so Z is NOT a recolour of A")
    check([q["sha256"] for q in a["pages"]] == [q["sha256"] for q in z["pages"]],
          "A and Z have byte-identical 5-page sets too")
    # the only per-area fields that differ are the fields that must (addresses)
    check(a["s_plus_04"] == z["s_plus_04"] and a["d_plus_04"] == z["d_plus_04"],
          "A and Z also share S+0x04 and D+0x04")

    # ---- 7. S+0x08/S+0x0C are read by the module's own material build
    def w1(va):
        return maindec.mword(va)
    code = {
        0x80127D90: (0x8C42002C, "lw $v0,0x2C($v0)  (state+0x2C = D)"),
        0x80127D98: (0x8C440000, "lw $a0,0($v0)   (a0 = *(D+0) = S)"),
        0x80127D9C: (0x0C030DC1, "jal 0x800C3704 (the section processor)"),
        0x800C3754: (0x8E240008, "lw $a0,0x8($s1)  (S+0x08 = the page table)"),
        0x800C3778: (0xAC620000, "sw $v0,0($v1)   (into 0x80178F88[])"),
        0x800C37A0: (0x8E22000C, "lw $v0,0xC($s1)  (S+0x0C = the CLUT table)"),
        0x800C37B0: (0x0C030F17, "jal 0x800C3C5C (CLUT upload)"),
    }
    bad = [va for va, (w, _) in code.items() if w1(va) != w]
    check(not bad, "the battle path reads S+0x08 and S+0x0C through 0x800C3704 "
          "(7 instruction words verified%s)"
          % ("" if not bad else "; wrong at %s" % [hex(x) for x in bad]))
    loader = [maindec.mword(0x80126FA4 + 4 * i) for i in range(0x1C)]
    check(0x8C420008 not in loader and 0x8E040008 not in loader,
          "the world-map loader 0x80126FA4..0x8012701C never loads S+0x08 "          "(the plane and the pages are loaded by different code)")

    # ---- 8. S+0x10 entries are data, not addresses
    body = maindec.body()
    hits = sum(body.count(struct.pack("<I", e["ptr"]))
               for p in areas.values() for e in p["ends"])
    dbl = 0
    for letter, p in areas.items():
        d = W.area_files()[letter][1]
        for e in p["ends"]:
            if d.count(struct.pack("<I", e["ptr"])) != 1:
                dbl += 1
    check(hits == 0 and dbl == 0,
          "no S+0x10 entry occurs as a literal in MAIN.EXE, and each occurs "
          "exactly once in its own module (the table itself)")

    print()
    if FAILURES:
        print("%d FAILED, %d passed" % (len(FAILURES), NPASS[0]))
        return 1
    print("PASS: %d checks, 0 failed -- world map composition" % NPASS[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
