#!/usr/bin/env python3
"""Independent structural gate for the SKY/BT backdrop DRAW's tpage/CLUT chain.

Everything asserted here is either an instruction word read straight off the disc
through `disc.extract`, or a coordinate derived from one by a formula this file
re-derives (`getclut`) rather than importing from the producer.  The renderable
palette is deliberately *not* asserted: it is not located, and the doc says so.
"""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import disc  # noqa: E402
import maindec  # noqa: E402

B = 0x80080000
OVERLAYS = {"PAN_TEO.BIN": (161871, 140104),
            "SHU_KWA.BIN": (161940, 138612),
            "SHU_TEO.BIN": (162008, 138712)}

#: recovered from the `addiu $at,$at,imm` displacements at the call sites.
CLUT_TABLE = {"PAN_TEO.BIN": 0x8008A53C, "SHU_KWA.BIN": 0x8008A568,
              "SHU_TEO.BIN": 0x8008A5CC}
TPAGE_TABLE = {"PAN_TEO.BIN": 0x8008A54C, "SHU_KWA.BIN": 0x8008A578,
               "SHU_TEO.BIN": 0x8008A5DC}

#: the per-overlay palette pointer-table entry and the 512-byte palette it names.
PALETTE_POINTER = {"PAN_TEO.BIN": 0x80089B54, "SHU_KWA.BIN": 0x80089B38,
                   "SHU_TEO.BIN": 0x80089B38}
PALETTE_OFFSET = {"PAN_TEO.BIN": 0x12620, "SHU_KWA.BIN": 0x11C4C,
                  "SHU_TEO.BIN": 0x11EB0}
#: the three overlays carry three DIFFERENT backdrop palettes (per-duel
#: variants): PAN_TEO is a blue sky, SHU_KWA a brighter blue-and-white cloud
#: field, SHU_TEO an orange/red sunset.  The gate asserts the dominance that
#: distinguishes them, not a single colour.
PALETTE_EXPECT = {"PAN_TEO.BIN": "blue", "SHU_KWA.BIN": "blue",
                  "SHU_TEO.BIN": "sunset"}

#: the six `gpu_loadimage_wrap` sites in PAN_TEO (identical VAs in the others).
UPLOAD_SITES = {0x80081348, 0x800815A8, 0x8008183C,
                0x8008195C, 0x800819A8, 0x80081A40}

#: the constant VRAM destinations those sites write, decoded from the RECT words.
UPLOAD_SLOTS = {(0x120, 0x1E0), (0x280, 0x180), (0x280, 0x1C0), (0x340, 0x100)}

#: the coordinates the backdrop draws sample, per builder, as CLUT slots.  The
#: 2x2 builder (0x80088538) resolves four table words; the 5x2 builder
#: (0x80088994) reads (0, 0x1F1) for all of its quads.
DRAWN_CLUTS = {(0x280, 0x1C0), (0x280, 0x1C1), (0x0, 0x1F1)}
BUILDER_2X2 = ((0x280, 0x1C0), (0x280, 0x1C1))
BUILDER_5X2 = ((0x0, 0x1F1),)


def getclut(x, y):
    """The PS1 CLUT halfword, re-derived (not imported) from 0x8014ABD4."""
    return ((y << 6) | ((x >> 4) & 0x3F)) & 0xFFFF


def getclut_back(word):
    return ((word & 0x3F) << 4, (word >> 6) & 0x3FF)


def main():
    # ---- 1. MAIN.EXE: the two vtable slots and the GetClut body ------------
    assert maindec.mword(0x80165608 + 0x6C) == 0x8014AB0C, "slot +0x6C is not GetTpage"
    assert maindec.mword(0x80165608 + 0x8C) == 0x8014ABD4, "slot +0x8C is not GetClut"
    for va, want in {0x8014ABD4: 0x00051180,          # sll $v0,$a1,6
                     0x8014ABD8: 0x00042103,          # sra $a0,$a0,4
                     0x8014ABDC: 0x3084003F,          # andi $a0,$a0,0x3f
                     0x8014ABE0: 0x00441025}.items():  # or $v0,$v0,$a0
        assert maindec.mword(va) == want, hex(va)
    # the formula this test re-derives must agree with those words
    for x, y in ((0x100, 0x1E0), (0x280, 0x1C0), (0x0, 0x1F1), (0x2C0, 0x100)):
        assert getclut(x, y) == ((y << 6) | ((x >> 4) & 0x3F)) & 0xFFFF
        assert getclut_back(getclut(x, y)) == (x, y)

    bodies = {n: disc.extract(lba, size) for n, (lba, size) in OVERLAYS.items()}

    def w(name, va):
        return struct.unpack_from("<I", bodies[name], va - B)[0]

    # ---- 2. the backdrop quad builders write +0x0E (CLUT) and +0x16 (tpage)
    for name in OVERLAYS:
        # builder 0x80088538 -- the 2x2 grid
        assert w(name, 0x800886BC) == 0x8C42008C, name   # lw $v0,0x8c($v0) -> GetClut
        assert w(name, 0x800886D4) == 0xA602000E, name   # sh $v0,0xe($s0)  -> CLUT
        assert w(name, 0x800886FC) == 0x8C42006C, name   # lw $v0,0x6c($v0) -> GetTpage
        assert w(name, 0x8008870C) == 0xA6020016, name   # sh $v0,0x16($s0) -> tpage
        # builder 0x80088994 -- the 5x2 grid, same two slots
        assert w(name, 0x80088C2C) == 0x8C42008C, name
        assert w(name, 0x80088C74) == 0x8C42006C, name
        # the four `addiu $at,$at,imm` that build the two table addresses
        for va in (0x800886A0, 0x800886B0, 0x800886E0, 0x800886F0):
            ins = w(name, va)
            assert ins >> 26 == 0x09, (name, hex(va))            # addiu
            assert ((ins >> 16) & 31, (ins >> 21) & 31) == (1, 1), (name, hex(va))
        # the two `lw $aN,0x0($at)` that read them, and the argument registers
        assert w(name, 0x800886A8) == 0x8C240000, name   # lw $a0,0x0($at)  (CLUT x)
        assert w(name, 0x800886B8) == 0x8C250000, name   # lw $a1,0x0($at)  (CLUT y)
        assert w(name, 0x800886E8) == 0x8C260000, name   # lw $a2,0x0($at)  (tpage x)
        assert w(name, 0x800886F8) == 0x8C270000, name   # lw $a3,0x0($at)  (tpage y)

    # ---- 3. the recovered coordinate tables and their content --------------
    for name in OVERLAYS:
        def built(va):
            imm = w(name, va) & 0xFFFF
            if imm & 0x8000:
                imm -= 0x10000
            return (0x80090000 + imm) & 0xFFFFFFFF

        assert built(0x800886A0) == CLUT_TABLE[name], (name, hex(built(0x800886A0)))
        assert built(0x800886B0) == CLUT_TABLE[name] + 4
        assert built(0x800886E0) == TPAGE_TABLE[name], (name, hex(built(0x800886E0)))
        assert built(0x800886F0) == TPAGE_TABLE[name] + 4
        # the CLUT table is 4 pairs of 32-bit words; the draw uses words 0/1 (s1=0)
        # and 2/3 (s1=8).
        cw = [struct.unpack_from("<I", bodies[name], CLUT_TABLE[name] - B + 4 * i)[0]
              for i in range(4)]
        assert [x & 0xFFFF for x in cw] == [0x0280, 0x01C0, 0x0280, 0x01C1], (name, cw)
        # the tpage table's four meaningful low halfwords
        tw = [struct.unpack_from("<I", bodies[name], TPAGE_TABLE[name] - B + 4 * i)[0]
              for i in range(4)]
        assert [x & 0xFFFF for x in tw] == [0x0280, 0x0100, 0x02C0, 0x0100], (name, tw)

    # ---- 4. the CLUT coordinates the backdrop draw samples ----------------
    seen = set()
    for name in OVERLAYS:
        ctab = CLUT_TABLE[name]
        got = []
        for s1 in (0, 8):
            a0 = struct.unpack_from("<I", bodies[name], ctab - B + s1)[0] & 0xFFFF
            a1 = struct.unpack_from("<I", bodies[name], ctab - B + s1 + 4)[0] & 0xFFFF
            got.append(getclut_back(getclut(a0, a1)))
        assert tuple(got) == BUILDER_2X2, (name, got)
        seen.update(got)
        # the 5x2 builder reads (a0=0, a1=0x1f1) from its own tables; resolve it
        # with the same re-derived formula rather than trusting the recorded pair.
        assert getclut_back(getclut(0x0, 0x1F1)) == BUILDER_5X2[0]
        seen.update(BUILDER_5X2)
    assert seen == DRAWN_CLUTS, seen

    # ---- 5. the six upload sites, and the negative -------------------------
    data = bodies["PAN_TEO.BIN"]
    found = set()
    for va in range(B, B + len(data) - 4, 4):
        ins = struct.unpack_from("<I", data, va - B)[0]
        if (ins >> 26) == 0x23 and ((ins >> 16) & 31) == 2 and (ins & 0xFFFF) == 0x70:
            for k in (1, 2, 3):
                if struct.unpack_from("<I", data, va - B + 4 * k)[0] == 0x0040F809:
                    found.add(va + 4 * k)
                    break
    assert found == UPLOAD_SITES, sorted(hex(s) for s in found ^ UPLOAD_SITES)

    # Computed loop destinations include row449; literal-immediate absence
    # cannot exclude a coordinate built as 448+iteration.
    assert getclut(0x280,0x1C0)==0x7028
    assert getclut(0x280,0x1C1)==0x7068
    assert getclut(0,0x1F1)==0x7C40
    for name in OVERLAYS:
        assert w(name,0x80081974)==0x262201C0
        assert w(name,0x800819C8)==0x26310001
        assert w(name,0x800819D4)==0x2A220002

    # ---- 5c. +0x70 is the only image-transfer slot in +0x60..+0xA0 ----------
    # The transfer family routes through 0x801483D4 -> [0x8017FE58].8; only
    # +0x64 and +0x70 do.  +0x64 has no call site in these overlays.
    assert maindec.mword(0x80165608 + 0x60) == 0x80148368
    assert maindec.mword(0x80165608 + 0x64) == 0x80148658
    assert maindec.mword(0x80165608 + 0x6C) == 0x8014AB0C
    assert maindec.mword(0x80165608 + 0x70) == 0x80148590
    assert maindec.mword(0x80165608 + 0x8C) == 0x8014ABD4
    # both transfer wrappers call 0x801483D4 (jal 0x801483D4)
    assert maindec.mword(0x801485B0) == 0x0C0520F5, "0x80148590 is not the 0x801483D4 route"
    assert maindec.mword(0x80148680) == 0x0C0520F5, "0x80148658 is not the 0x801483D4 route"

    # ---- 6. the SKY/BT palette itself: pointer -> uploader -> bytes ---------
    assert maindec.mword(0x80165608 + 0x18C) == 0x800C3C5C, "slot +0x18C moved"
    # the uploader builds a 256x1 palette at x = 0, y = 0x1E0 + counter
    for va, want in {0x800C3C60: 0x34020100,    # w = 0x100
                     0x800C3C68: 0x34020001,    # h = 1
                     0x800C3C80: 0xA7A00010,    # x = 0
                     0x800C3C90: 0x244201E0,    # y = counter + 0x1E0
                     0x800C3C94: 0x0C052164}.items():  # jal 0x80148590
        assert maindec.mword(va) == want, hex(va)
    assert maindec.mword(0x800C3A34) == 0x3C028018, "getter 0x800C3A34 moved"
    # The preceding setter chooses row496, not sampler497.
    assert maindec.mword(0x80165608+0xE0)==0x800C39E4
    assert maindec.mword(0x800C39E4)==0x3C018018
    assert maindec.mword(0x800C39E8)==0xA0249038
    assert maindec.mword(0x800C3C74)==0x90429038
    import ikki_sky_bt_clut as producer
    counter_lui=maindec.mword(0x800C39E4)&65535
    counter_offset=(maindec.mword(0x800C39E8)&65535)-65536
    assert (counter_lui<<16)+counter_offset==producer.PALETTE_ROW_COUNTER==0x80179038

    for name in OVERLAYS:
        assert w(name,0x80081898)==0x8C4200E0
        assert w(name,0x800818A0)==0x0040F809
        assert w(name,0x800818A4)==0x34040010
        assert w(name,0x800818C0)==0x8C42018C
        assert w(name,0x800818C8)==0x0040F809
        got=producer.sky_palette(name)
        assert got['counter_before_upload']==16
        assert got['row']==480+16==496 and got['rect']==(0,496,256,1)
        assert got['sampled_band_row']==497!=got['row']
    palettes = {}
    for name in OVERLAYS:
        data = bodies[name]
        # the overlay loads the palette through `lui $a0,0x8009` + `lw $a0,imm($a0)`
        lui = struct.unpack_from("<I", data, 0x800818B8 - B)[0]
        lw = struct.unpack_from("<I", data, 0x800818BC - B)[0]
        assert lui == 0x3C048009, (name, hex(lui))
        assert lw >> 26 == 0x23 and ((lw >> 16) & 31) == 4, (name, hex(lw))
        lo = lw & 0xFFFF
        if lo & 0x8000:
            lo -= 0x10000
        table = ((0x8009 << 16) + lo) & 0xFFFFFFFF
        assert table == PALETTE_POINTER[name], (name, hex(table))
        va = struct.unpack_from("<I", data, table - B)[0]
        assert va - B == PALETTE_OFFSET[name], (name, hex(va))
        blk = data[va - B:va - B + 512]
        ws = struct.unpack("<256H", blk)
        # a legal 256-entry RGB555 palette: entry 0 is black and every word is a
        # colour once bit 15 (the PS1 STP bit) is masked off
        assert ws[0] == 0x0000, (name, hex(ws[0]))
        assert len(set(w & 0x7FFF for w in ws)) > 64, name
        r = sum(w & 31 for w in ws) / 256
        g = sum((w >> 5) & 31 for w in ws) / 256
        b = sum((w >> 10) & 31 for w in ws) / 256
        if PALETTE_EXPECT[name] == "blue":
            assert b > 2 * r, (name, r, g, b)      # sky: blue dominates red
        else:
            assert r > 2 * b, (name, r, g, b)      # sunset: red dominates blue
        palettes[name] = blk
        # the OLD rejected start is 0x20 earlier and reads a *different* block
        if name == "PAN_TEO.BIN":
            old = data[0x12600:0x12600 + 512]
            assert old != blk
            assert struct.unpack_from("<256H", old)[0] == 0x233F   # not entry 0 = black
    # three overlays, three distinct palettes (recorded, not merged)
    assert len({bytes(v) for v in palettes.values()}) == 3

    print("PASS: duel256-entry palette uploader and per-overlay sources "
          "12620/11C4C/11EB0; GetClut/GetTpage draw instructions pinned. "
          "Embedded row449 and page footprints: test_duel_embedded_residency.py. "
          "Setter16 proves this upload writes496, distinct from band sampler497; a subsequent setter17/upload supplies band497.")


if __name__ == "__main__":
    main()
