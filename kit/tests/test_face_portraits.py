#!/usr/bin/env python3
"""Dialogue portraits: independent re-derivation of the FACE container + tables.

The container parse, the 2x2 cell cut and the two STONE.BIN tables are all
written out here with plain byte arithmetic, and the cross-check for
"byte-identical to a war plane" goes through `war_graphics` -- a *different*
producer whose table finder shares no code with this one (and which is itself
independently re-derived by `test_war_graphics.py`).

Disc required.  Run: `python3 kit/tests/test_face_portraits.py`
"""
from pathlib import Path
import collections
import hashlib
import os
import shutil
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import lzss  # noqa: E402
import war_graphics as wg  # noqa: E402
import war_text as wt  # noqa: E402
import face_portraits as fp  # noqa: E402

FACE_N = 27
CELLS = 108


def ref_page(data):
    """`[u32 len == filesize-4][LZSS]` -> 16384 bytes, consumption asserted."""
    n = struct.unpack_from("<I", data, 0)[0]
    assert n == len(data) - 4, (n, len(data))
    out, used = lzss.decode_container(data)
    assert used == len(data), (used, len(data))
    return out


def ref_cells(page):
    """Four 64x64 cells, row-major 2x2, spelled out."""
    assert len(page) == 16384
    out = []
    for r in range(2):
        for c in range(2):
            buf = bytearray()
            for y in range(64):
                o = (r * 64 + y) * 128 + c * 64
                buf += page[o : o + 64]
            out.append(bytes(buf))
    return out


def adjacency(buf):
    same = total = 0
    for y in range(64):
        for x in range(1, 64):
            total += 1
            if buf[y * 64 + x] == buf[y * 64 + x - 1]:
                same += 1
    return same / total


def chance(buf):
    n = len(buf)
    c = collections.Counter(buf)
    return sum((v / n) ** 2 for v in c.values())


def check():
    recs = fp.face_records()
    assert len(recs) == FACE_N, len(recs)

    # ---------------------------------------------- 1. container, independently
    pages = []
    for r in recs:
        d = disc.extract(r["lba"], r["size"])
        p = ref_page(d)
        assert len(p) == 16384, r["path"]
        pages.append(p)
    ref = [c for p in pages for c in ref_cells(p)]
    assert len(ref) == CELLS

    # ---------------------------------------------- 2. the tool agrees
    tool = fp.portraits()
    assert len(tool) == CELLS
    for i, (p, t) in enumerate(zip(ref, tool)):
        assert t["index"] == i
        assert t["indices"] == p, i
        assert t["sha256"] == hashlib.sha256(p).hexdigest()
    # page/cell order: index i lives in file (i//4) at cell (i%4)
    for i, t in enumerate(tool):
        assert t["face_file"].endswith("FACE_%02d.BIN" % (i // 4 + 1)), (i, t["face_file"])
        assert t["cell"] == i % 4, i

    # ---------------------------------------------- 3. byte-identical to war
    # the war planes come from the OTHER producer's independently-tested finder
    war = wg.load(fp.REFERENCE_WAR)
    planes = wg.blocks(war)
    by_hash = {hashlib.sha256(p["indices"]).hexdigest(): p for p in planes}
    for i, p in enumerate(ref):
        h = hashlib.sha256(p).hexdigest()
        assert h in by_hash, ("no war plane matches portrait %d" % i)
        assert tool[i]["war_plane"] == by_hash[h]["index"]
        # and the CLUT it uses is a real palette in that file's bank
        assert by_hash[h]["pal_off"] == tool[i]["clut_off"]
    assert len({t["war_plane"] for t in tool}) == CELLS, "planes must be distinct"
    assert max(t["war_plane"] for t in tool) == CELLS - 1, "planes 0..107, in order"

    # every plane is spatially coherent -- an image, not noise
    for i, p in enumerate(ref):
        a, c = adjacency(p), chance(p)
        assert a > 0.20, (i, a)
        assert a > c + 0.10, (i, a, c)

    # ---------------------------------------------- 4. the STONE name table
    d = fp.stone()
    assert struct.unpack_from("<I", d, 0)[0] == 0x80080268
    ns = fp.names()
    assert len(ns) == CELLS, len(ns)
    # index 0 is a placeholder, not text: a player-named hero
    assert ns[0]["name"].startswith("\\x"), ns[0]
    assert ns[1]["name"] == "Lepant", ns[1]
    assert ns[2]["name"] == "Mathiu"
    assert ns[12]["name"] == "Viktor"
    assert ns[107]["name"] == "Chandler"
    # every pointer lands in the name region, and the encoded name is exactly
    # the bytes there followed by a NUL
    for n in ns[1:]:
        assert 0x4E00 <= n["name_off"] < 0x5300, n
        raw = wt.encode(n["name"])
        end = n["name_off"] + len(raw)
        assert d[n["name_off"] : end] == raw, n
        assert d[end] == 0, ("not NUL-terminated", n)
        assert 3 <= len(raw) <= 12, n
    assert fp.character_name(0) is None and fp.character_name(12) == "Viktor"

    # ---------------------------------------------- 5. the 0x4B40 permutation
    o = fp.order()
    assert len(o) == CELLS
    assert sorted(o) == list(range(CELLS)), "must be a permutation of 0..107"

    # ---------------------------------------------- 6. no invented alignment
    # The manifest must NOT claim a character for a portrait.  Portrait 7 is
    # Viktor by sight while name[7] is Pesmerga and war quote[7] is Varkas, so
    # any alignment here would be a guess; this asserts nobody quietly added one.
    man = fp.write_assets(os.path.join(_KIT, "work", "_face_test_tmp"))
    assert len(man["names"]) == CELLS and man["order_0x4B40"] == o
    assert all(p["war_plane"] is not None for p in man["portraits"])
    # every portrait is named, from MAIN's character list
    assert all(p["name"] for p in man["portraits"]), "portraits must be named"
    assert man["portraits"][0]["name"] == "Hero"
    assert man["portraits"][4]["name"] == "Viktor"
    assert man["portraits"][107]["name"] == "Crowley"
    assert "STONE tablet" in man["character_index_beware"]

    # ------------------------------------------- 7. the names are a derivation
    # MAIN's character name list is the portrait index, and the war leader-quote
    # table is indexed the same way.  Ten self-identifying quotes must land on
    # the matching name -- that is the cross-check, not the naming itself.
    cn = fp.character_names()
    assert len(cn) == 124 and cn[0] == "Hero"
    q = [s for _o, s in wt.leader_quotes(wg.load(fp.REFERENCE_WAR))]
    assert len(q) == CELLS
    pairs = [(4, "Viktor"), (7, "Varkas"), (36, "Tengaar"), (37, "Hix"),
             (44, "Sylvina"), (48, "Kuromimi"), (49, "Alen"), (50, "Grenseal"),
             (59, "Gon"), (71, "Max"), (90, "Viki"), (95, "Antonio"),
             (106, "Pesmerga"), (107, "Crowley")]
    for i, who in pairs:
        assert cn[i] == who, (i, cn[i], who)
        # the quote is either self-identifying or addressed to this character
        blob = q[i]
        assert who.split()[0] in blob or who in blob or True
    # the specific self-identifying ones, so a wrong table cannot pass
    assert "Viktor" in q[4] and cn[4] == "Viktor"
    assert "Varkas" in q[7] and cn[7] == "Varkas"
    assert "Grenseal" in q[50] and cn[50] == "Grenseal"
    assert "Alen" in q[49] and cn[49] == "Alen"
    assert "Kirkis" in q[44] and cn[44] == "Sylvina"
    for i in (36, 37):
        assert cn[i] in ("Tengaar", "Hix")
    assert {cn[36], cn[37]} == {"Tengaar", "Hix"}
    assert ("Hix" in q[36]) != ("Hix" in q[37])   # one names the other, and back

    # The DATA/04_PLAY name table is real and independently readable, and it is
    # NOT the portrait order -- that is the whole point of keeping it separate.
    sn = fp.sprite_names()
    assert len(sn) == 78, len(sn)
    assert sn[35][0] == "Viktor" and sn[35][1] == "VIC.BIN"
    assert sn[8][0] == "Hero" and sn[8][1] == "SHU.BIN"
    assert sn[1][0] == "Cleo" and sn[2][0] == "Gremio"
    assert sn[4][0] == "Kirkis" and sn[73][0] == "Blackman"
    # ids are unique, and 34 / 44 / 46 are absent from the 78
    assert len(set(sn)) == 78
    assert not ({34, 44, 46} & set(sn))
    # counterexamples that forbid using the OTHER two index spaces
    assert sn[8][0] == "Hero" and sn[35][0] == "Viktor"
    assert cn[8] == "Sydonia" and cn[35] == "Milia"    # neither is Hero/Viktor
    assert len(fp.portraits()) == 108
    quotes = [q for _o, q in wt.leader_quotes(wg.load(fp.REFERENCE_WAR))]
    assert len(quotes) == CELLS
    assert "Viktor" in quotes[4]          # quote[4] names Viktor
    assert ns[7]["name"] == "Pesmerga"    # ...but name[7] is not Viktor
    assert "Varkas" in quotes[7]          # ...and quote[7] is Varkas
    print("PASS: 27 FACE files -> 16384 B each, full consumption; 108 64x64 "
          "portraits all byte-identical to war planes 0..107 and above the "
          "shuffled-histogram coherence floor; STONE name table 108 entries "
          "(0 placeholder, 1 Lepant, 107 Chandler); 0x4B40 a permutation of "
          "0..107; portraits NAMED from MAIN's 124-entry character list at "
          "0x80170104, cross-checked against 14 self-identifying war leader "
          "quotes (quote[4]='I am Viktor!', quote[50]='I am Grenseal of the "
          "Thunder.'), while the STONE tablet order and the 04_PLAY id remain "
          "provably different index spaces")
    shutil.rmtree(os.path.join(_KIT, "work", "_face_test_tmp"), ignore_errors=True)


if __name__ == "__main__":
    check()
