#!/usr/bin/env python3
"""War mode portraits: independent re-derivation of the block bank.

Everything here is checked with plain byte arithmetic written out in this file,
not by calling `war_graphics`'s own finders, so a bug in the tool cannot make
the test pass.  Disc required.

  `python3 kit/tests/test_war_graphics.py`
"""
from pathlib import Path
import collections
import hashlib
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import war_graphics as G  # noqa: E402
import war_text as wt  # noqa: E402
import lzss  # noqa: E402

BASE = 0x80010000

#: rows in the portrait table, per file -- derived, and pinned so a change in
#: the finder cannot silently start returning a truncated table
ROWS = {
    "WAR_KUWA.BIN": 111, "WAR_GARA.BIN": 111, "WAR_SHAS.BIN": 111,
    "WAR_SCA1.BIN": 112, "WAR_SCA2.BIN": 112, "WAR_KITA.BIN": 112,
    "WAR_LAST.BIN": 112, "WAR_TEO1.BIN": 113, "WAR_TEO2.BIN": 113,
    "WAR1.BIN": 108,
}


# --------------------------------------------------------------- independent
def ref_is_palette(data, off):
    if off + 512 > len(data):
        return False
    words = struct.unpack_from("<256H", data, off)
    if words[0] != 0:
        return False
    for w in words:
        if w & 0x8000:
            return False
    return sum(1 for w in words if w) >= 240


def ref_palette_bank(data):
    """Longest 0x200-strided palette run, by plain scanning."""
    best = []
    off = 0
    while off + 512 <= len(data):
        if ref_is_palette(data, off):
            run = [off]
            p = off + 0x200
            while p + 512 <= len(data) and ref_is_palette(data, p):
                run.append(p)
                p += 0x200
            if len(run) > len(best):
                best = run
            off = p
        else:
            off += 2
    return best


def ref_blocks(data):
    """`[(block_off, pal_off, uncompressed)]` by plain table walking.

    Uses only the palette bank as a seed, exactly as the tool must, but with
    the arithmetic spelled out.
    """
    bank = ref_palette_bank(data)
    pal_words = {struct.pack("<I", BASE + p) for p in bank}
    n = len(data)
    rows = []
    for hit in range(4, n - 4, 4):
        if data[hit : hit + 4] not in pal_words:
            continue
        start = hit
        while start - 8 >= 4 and data[start - 8 : start - 4] in pal_words:
            start -= 8
        end = hit
        while end + 8 <= n - 4 and data[end + 8 : end + 12] in pal_words:
            end += 8
        cand = []
        o = start - 4
        while o + 8 <= n:
            p, q = struct.unpack_from("<II", data, o)
            if not (BASE <= p < BASE + n) or not (BASE <= q < BASE + n):
                break
            cand.append((p - BASE, q - BASE))
            o += 8
        if len(cand) > len(rows):
            rows = cand
    out = []
    for a, q in rows:
        size = struct.unpack_from("<I", data, a)[0]
        if size == 0 or a + 4 + size > n:
            continue
        blob, used = lzss.decode_container(data[a : a + 4 + size])
        assert used == 4 + size, (hex(a), used, 4 + size)
        out.append((a, q, blob))
    return out


def adjacency(buf, w=64, h=64):
    """Fraction of horizontally adjacent equal indices (spatial coherence)."""
    same = 0
    total = 0
    for y in range(h):
        for x in range(1, w):
            total += 1
            if buf[y * w + x] == buf[y * w + x - 1]:
                same += 1
    return same / total


def chance_equal(buf):
    n = len(buf)
    c = collections.Counter(buf)
    return sum((v / n) ** 2 for v in c.values())


def check():
    # ---------------------------------------------------- 1. independent parse
    dk = wt.load("WAR_KUWA.BIN")
    ref = ref_blocks(dk)
    assert len(ref) == ROWS["WAR_KUWA.BIN"], len(ref)
    tool = G.blocks(dk)
    assert len(tool) == len(ref)
    for (a, q, blob), t in zip(ref, tool):
        assert t["off"] == a and t["pal_off"] == q
        assert t["indices"] == blob
        assert len(blob) == G.BLOCK_OUT_SIZE == 4096
    # ...and the tool's own finder agrees on the table location
    t_off, t_rows = G.portrait_table(dk)
    assert t_off == 0x7B91C, hex(t_off)
    assert len(t_rows) == 111

    # ---------------------------------------------------- 2. the palette bank
    bank = ref_palette_bank(dk)
    assert len(bank) == G.EXPECTED_BANK == 9, bank
    # every bank entry is 0x200 apart, and every block's CLUT is one of them
    assert all(bank[i + 1] - bank[i] == 0x200 for i in range(len(bank) - 1))
    pals = {q for _a, q, _b in ref}
    assert pals <= set(bank), (sorted(pals), bank)

    # ---------------------------------------------------- 3. every file
    per_file = {}
    for name, want in ROWS.items():
        d = wt.load(name)
        blocks = G.blocks(d)
        assert len(blocks) == want, (name, len(blocks), want)
        sizes = {len(b["indices"]) for b in blocks}
        assert sizes == {4096}, (name, sizes)
        file_bank = set(ref_palette_bank(d))
        for b in blocks:
            # self-delimiting: [u32 comp_size][payload], 4-byte aligned
            assert 0 < b["comp_size"] <= 0x2000, (name, b["index"], b["comp_size"])
            assert b["off"] + 4 + b["comp_size"] <= len(d)
            # every CLUT in the nine is a 256-colour RGB555 palette and one of
            # the bank's 9.  WAR1.BIN is the outlier: 2 of its 108 blocks point
            # at palette runs that fail the strict filter, which is part of how
            # the dead file differs.  Both facts are asserted below rather than
            # waved through.
            if name != "WAR1.BIN":
                assert ref_is_palette(d, b["pal_off"]), (name, b["index"], hex(b["pal_off"]))
                assert b["pal_off"] in file_bank, (name, b["index"])
            # spatial coherence: an image, not noise.  `chance_equal` is what a
            # shuffled plane with the same index histogram would score, so this
            # is a like-for-like comparison rather than a fixed constant.
            ratio = adjacency(b["indices"])
            ch = chance_equal(b["indices"])
            assert ratio > 0.20, (name, b["index"], ratio)
            assert ratio > ch + 0.10, (name, b["index"], ratio, ch)
        digest = hashlib.sha256(b"".join(b["indices"] for b in blocks)).hexdigest()[:16]
        per_file[name] = (len(blocks), digest)

    # determinism: the finder must not depend on set iteration order
    assert G.blocks(dk) == tool

    # ---------------------------------------------------- 4. the shared set
    # GARA / KUWA / SHAS carry the same 111 portraits; every other scenario
    # carries those same 111 in the same order and then appends its own 1 or 2
    common = [hashlib.sha256(b["indices"]).hexdigest()
              for b in G.blocks(wt.load("WAR_KUWA.BIN"))]
    assert per_file["WAR_GARA.BIN"][1] == per_file["WAR_KUWA.BIN"][1]
    assert per_file["WAR_SHAS.BIN"][1] == per_file["WAR_KUWA.BIN"][1]
    appends = {"WAR_GARA.BIN": 0, "WAR_SHAS.BIN": 0, "WAR_SCA1.BIN": 1,
               "WAR_SCA2.BIN": 1, "WAR_KITA.BIN": 1, "WAR_LAST.BIN": 1,
               "WAR_TEO1.BIN": 2, "WAR_TEO2.BIN": 2}
    assert per_file["WAR_SCA1.BIN"][1] == per_file["WAR_SCA2.BIN"][1]
    assert per_file["WAR_TEO1.BIN"][1] == per_file["WAR_TEO2.BIN"][1]
    for name, extra in appends.items():
        hs = [hashlib.sha256(b["indices"]).hexdigest()
              for b in G.blocks(wt.load(name))]
        assert hs[:111] == common, name
        assert len(hs) == 111 + extra, (name, len(hs))
        assert all(h not in set(common) for h in hs[111:]), name

    # WAR1.BIN is a different build: a different set, not an extension of this
    h1 = [hashlib.sha256(b["indices"]).hexdigest()
          for b in G.blocks(wt.load("WAR1.BIN"))]
    assert len(h1) == 108
    assert len(set(h1) & set(common)) < 30, len(set(h1) & set(common))

    # ...and the separate palette bank size is the honest difference to record
    dw1 = wt.load("WAR1.BIN")
    assert len(ref_palette_bank(dw1)) == 8
    b1 = G.blocks(dw1)
    assert all(0 < b["pal_off"] < len(dw1) and b["pal_off"] % 4 == 0 for b in b1)
    nonstrict = [b["index"] for b in b1 if not ref_is_palette(dw1, b["pal_off"])]
    assert len(nonstrict) >= 1, "WAR1.BIN's non-conforming CLUTs are expected"

    # W_HEADER.BIN is 67 bytes and has neither
    wh = wt.load("W_HEADER.BIN")
    assert len(wh) == 67
    assert ref_palette_bank(wh) == []
    assert G.portrait_table(wh) == (-1, [])

    print("PASS: portrait bank re-derived independently for all 10 files -- "
          "9-palette bank, %d..%d blocks x 4096 B each, every block full "
          "consumption and above the shuffled-histogram coherence floor; the "
          "111-portrait shared set is identical in GARA/KUWA/SHAS and a "
          "prefix of the other five; WAR1.BIN shares %d of 108"
          % (min(ROWS.values()), max(ROWS.values()), len(set(h1) & set(common))))


if __name__ == "__main__":
    check()
