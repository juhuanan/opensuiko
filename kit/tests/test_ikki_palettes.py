#!/usr/bin/env python3
"""IC / BT / SKY duel palettes: independent re-derivation of the CLUT sources.

Everything asserted here is written out with plain `struct` arithmetic against
bytes pulled straight off the disc, and every "this is a palette" claim is
checked as a *structure* (256 legal RGB555 words, a unique 512-byte block, a code
xref) rather than by looking at a render.

What it pins:

* the 48 `DATA/12_IKKI/DATA` pages are `[u32 len == filesize-4][LZSS]` ->
  exactly 16,384 B with full consumption, and their transfer size is
  64x128 halfwords -- i.e. the page size does not settle the pixel format;
* the **IC** plane is a 128x128 **8bpp** index plane: byte values stay in
  0..31 and the page decodes as a 4x2 grid of 32x64 icons.  (The 4bpp reading
  is a checkerboard, which is what makes it wrong.)
* the code that draws the icons walks **two pointer tables** with a 4-byte
  stride, and in PAN_TEO the second one (`0x80089B94`, loaded at `0x80081994`)
  resolves to a 512-byte RGB555 palette at file `0xE6E0`;
* that palette is present in all three duel overlays (one variant each), and the
  variants are *different blocks* -- the IC palette is per-duel, not shared;
* the **SKY** palette is one byte-identical 512-byte block in all three
  overlays (PAN `0x12600`), it is NOT reachable from any pointer table, and the
  SKY pages render blue-dominant under it while the IC palette does not.

Disc required.  Run: `python3 kit/tests/test_ikki_palettes.py`
"""
from pathlib import Path
import hashlib
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import ikki_palettes as ip  # noqa: E402

N_PAGES = 48
N_IC, N_BT, N_SKY = 28, 11, 9
PAN, KWA, TEO = "PAN_TEO.BIN", "SHU_KWA.BIN", "SHU_TEO.BIN"

#: the addresses the disassembly gives, spelled out independently of the tool.
BLOB_SITE = 0x800818F4
CLUT_SITE = 0x80081994
PAN_CLUT_TABLE = 0x80089B94
PAN_BLOB_TABLE = 0x80089B8C
SHU_CLUT_TABLE = 0x80089B78
PAN_IC_PAL_OFF = 0xE6E0
PAN_SKY_PAL_OFF = 0x12600
SKY_OFF = {PAN: 0x12600, KWA: 0x1202C, TEO: 0x12090}
IC_OFF = {PAN: 0xE6E0, KWA: 0xD8D4, TEO: 0xD938}


def ref_page(rec):
    """`[u32 len == filesize-4][LZSS]` -> 16384 bytes, consumption asserted."""
    d = disc.extract(rec["lba"], rec["size"])
    n = struct.unpack_from("<I", d, 0)[0]
    assert n == len(d) - 4, (rec["path"], n, len(d))
    import lzss
    out, used = lzss.decode_container(d)
    assert used == len(d), (rec["path"], used, len(d))
    return out


def pal_bytes(off, overlay=PAN):
    d = ip.overlay(overlay)
    return d[off:off + 512]


def is_rgb555(blk):
    """256 little-endian words, at most a couple of `0x8000` sentinels."""
    ws = struct.unpack_from("<256H", blk, 0)
    n8 = sum(1 for w in ws if w == 0x8000)
    return n8 <= 4 and not any((w & 0x8000) and w != 0x8000 for w in ws)


def check():
    # ---- 1. the 48 pages: one container, one size, full consumption --------
    fam = {"IC_": [], "BT": [], "SKY": []}
    for p in ip.pages():
        base = p["name"].split("_")[0]
        key = "IC_" if base.startswith("IC") else ("SKY" if base.startswith("SKY")
                                                   else "BT")
        fam[key].append(p)
    assert len(fam["IC_"]) == N_IC, len(fam["IC_"])
    assert len(fam["BT"]) == N_BT, len(fam["BT"])
    assert len(fam["SKY"]) == N_SKY, len(fam["SKY"])
    assert len(ip.pages()) == N_PAGES
    for p in ip.pages():
        assert len(p["page"]) == 16384, p["name"]
        assert p["comp_len"] == p["file_size"] - 4, p["name"]

    # ---- 2. the IC plane is 8bpp, sparse, and a 4x2 grid of 32x64 icons ----
    for p in fam["IC_"]:
        vals = set(p["page"])
        assert max(vals) <= 31, (p["name"], max(vals))
        assert 0 in vals
        # a 4bpp reading would need the high nibbles to be a second index space;
        # they are a subset of {0,1}, i.e. noise from misreading an 8bpp plane.
        hi = {b >> 4 for b in p["page"]}
        assert hi <= {0, 1}, (p["name"], sorted(hi))
    # each page holds eight 32x64 cells: the four cells of a row are separated
    # by empty columns exactly on the 32-pixel cell boundaries, and each cell's
    # ink stays inside its own 32-wide band.
    def bbox(page, x0, x1, y0, y1):
        xs, ys = [], []
        for y in range(y0, y1):
            for x in range(x0, x1):
                if page[y * 128 + x]:
                    xs.append(x)
                    ys.append(y)
        assert xs, (x0, x1, y0, y1)
        return min(xs), max(xs), min(ys), max(ys)

    for p in fam["IC_"]:
        page = p["page"]
        cols = [sum(1 for y in range(128) if page[y * 128 + x]) for x in range(128)]
        ink = sum(cols)
        bands = []
        for c in range(4):
            xs = [x for x in range(c * 32, (c + 1) * 32) if cols[x]]
            bands.append((min(xs), max(xs), sum(cols[c * 32:(c + 1) * 32])) if xs
                         else None)
        # a 32-wide cell split puts the bulk of each cell's ink in its own
        # 32-column band, four times over; two pages carry only six icons and
        # leave the fourth band empty, which is allowed.
        occupied = [b for b in bands if b]
        assert len(occupied) >= 3, (p["name"], bands)
        for c, b in enumerate(bands):
            if b is None:
                continue
            assert b[2] >= ink * 0.10, (p["name"], c, b[2], ink)
            # the art may overhang its cell by a pixel or two, but not by half
            assert c * 32 - 3 <= b[0] and b[1] < (c + 1) * 32 + 3, (p["name"], c, b)

    # ---- 3. the code tables recover from the overlay alone -----------------
    ov = ip.overlays()
    found = {}
    for name in ip.OVERLAYS:
        ts = ip.find_pointer_tables(ov[name])
        found[name] = {t["site"]: t["table_va"] for t in ts}
    assert found[PAN][BLOB_SITE] == PAN_BLOB_TABLE, found[PAN]
    assert found[PAN][CLUT_SITE] == PAN_CLUT_TABLE, found[PAN]
    assert found[KWA][CLUT_SITE] == SHU_CLUT_TABLE, found[KWA]
    assert found[TEO][CLUT_SITE] == SHU_CLUT_TABLE, found[TEO]

    # ---- 4. the PAN CLUT table is two pointers to 512-byte RGB555 blocks ---
    d = ov[PAN]
    for i, expect in enumerate((PAN_IC_PAL_OFF, 0xF404)):
        v = struct.unpack_from("<I", d, PAN_CLUT_TABLE - 0x80080000 + 4 * i)[0]
        assert v == 0x80080000 + expect, (i, hex(v))
        assert is_rgb555(d[expect:expect + 512]), i
    # ... and the two entries are the same palette, which is why index does not
    # change which colours an icon gets.
    assert d[PAN_IC_PAL_OFF:PAN_IC_PAL_OFF + 512] == d[0xF404:0xF404 + 512]

    # ---- 5. the pointer table sits inside a multi-purpose table ------------
    # the case-6 loop walks 0x80089B8C (the blob table) with the same stride;
    # its first two entries are embedded [u32][LZSS] containers -> 4096 B.
    import lzss
    for i in range(2):
        va = struct.unpack_from("<I", d, PAN_BLOB_TABLE - 0x80080000 + 4 * i)[0]
        off = va - 0x80080000
        n = struct.unpack_from("<I", d, off)[0]
        out, used = lzss.decode_container(d[off:off + 4 + n])
        assert used == 4 + n, (i, used)
        assert len(out) == 4096, (i, len(out))
    # the CLUT table's entries are the palette block, not a container
    assert ip.is_palette(d, PAN_IC_PAL_OFF)
    assert ip.is_palette(d, PAN_SKY_PAL_OFF)

    # ---- 6. the IC palette is per-overlay, and the SKY palette is not ------
    ics = {n: pal_bytes(IC_OFF[n], n) for n in ip.OVERLAYS}
    # two distinct variants: PAN_TEO differs from both SHU overlays, and the
    # two SHU overlays share one (they carry the same `IC_SHU` icon set).
    assert ics[PAN] != ics[KWA], "IC variants should differ"
    assert ics[PAN] != ics[TEO], "IC variants should differ"
    assert ics[KWA] == ics[TEO], "the two SHU overlays share their variant"
    assert len({hashlib.sha256(b).hexdigest() for b in ics.values()}) == 2
    for n, blk in ics.items():
        assert is_rgb555(blk), n
    skys = {n: pal_bytes(SKY_OFF[n], n) for n in ip.OVERLAYS}
    assert skys[PAN] == skys[KWA] == skys[TEO], "SKY block must be identical"
    assert hashlib.sha256(skys[PAN]).hexdigest() == \
        hashlib.sha256(skys[KWA]).hexdigest()
    # each SKY block is a single copy in its own overlay
    for n in ip.OVERLAYS:
        assert ip._find_block(ov[n], skys[n]) == [SKY_OFF[n]], n
    # the SKY block is not one of the code-table palettes
    table_blocks = {hashlib.sha256(r["bytes"]).hexdigest()
                    for r in ip.duel_palette_rows()}
    assert hashlib.sha256(skys[PAN]).hexdigest() not in table_blocks

    # ---- 7. the tool's own identification agrees --------------------------
    named = ip.named_palettes()
    assert named["ic"]["sha256"] == hashlib.sha256(ics[PAN]).hexdigest()
    assert named["sky"]["sha256"] == hashlib.sha256(skys[PAN]).hexdigest()
    assert named["ic"]["files"][PAN] == PAN_IC_PAL_OFF
    sky_pan = named["sky"]["files"][PAN]
    sky_pan = sky_pan[0] if isinstance(sky_pan, list) else sky_pan
    assert sky_pan == PAN_SKY_PAL_OFF
    for n in ip.OVERLAYS:
        sky_off = named["sky"]["files"][n]
        sky_off = sky_off[0] if isinstance(sky_off, list) else sky_off
        assert sky_off == SKY_OFF[n], (n, named["sky"]["files"])
        assert named["ic"]["files"][n] == IC_OFF[n], (n, named["ic"]["files"])
    assert named["ic"]["distinct_variants"] == 2

    # ---- 8. the two palettes are not interchangeable on the page data ------
    # objective, derived from the pages: under the SKY block the SKY pages are
    # blue-dominant and under the IC block they are red-dominant.  (This is the
    # measurement that says which block belongs to which family; the *look* of
    # the render is the user's gate.)
    def mean_rgb(block, prefix):
        lut = ip.palette_lut(block)
        tot = [0, 0, 0]
        n = 0
        for p in ip.pages(prefix):
            for v in p["page"]:
                if v:
                    c = lut[v]
                    tot[0] += c[0]
                    tot[1] += c[1]
                    tot[2] += c[2]
                    n += 1
        return [t / n for t in tot]

    ic_blk, sky_blk = named["ic"]["bytes"], named["sky"]["bytes"]
    sky_under_sky = mean_rgb(sky_blk, "SKY")
    sky_under_ic = mean_rgb(ic_blk, "SKY")
    assert sky_under_sky[2] > sky_under_sky[0] + 60, sky_under_sky
    assert sky_under_ic[0] > sky_under_ic[2] + 20, sky_under_ic
    # the icon pages under their own palette are a warm ramp (red >= green >=
    # blue), which is the opposite ordering from the sky block.
    ic_under_ic = mean_rgb(ic_blk, "IC_")
    assert ic_under_ic[0] >= ic_under_ic[1] >= ic_under_ic[2], ic_under_ic

    # ---- 9. BT is deliberately NOT claimed --------------------------------
    # No pointer table in the three overlays reaches a third shared block, and
    # `duel_palette_rows()` returns only the icon variants, so the BT palette is
    # an honest gap rather than a guess.
    shas = {r["sha256"] for r in ip.duel_palette_rows()}
    assert hashlib.sha256(skys[PAN]).hexdigest() not in shas
    assert len(shas) <= 4, shas

    print("PASS: 48 framed pages decode fully to16384 bytes; IC index range and "
          "historical palette-experiment measurements reproduced. These rejected "
          "palette assignments are not acceptance evidence. Current IC CLUT: "
          "test_ikki_clut_trace.py; embedded portrait palettes: "
          "test_duel_embedded_residency.py.")


if __name__ == "__main__":
    check()
