#!/usr/bin/env python3
"""The world map's DRAW TRANSFORM, and a terrain-layer renderer for it.

Static, disc-only analysis of the user's own Suikoden (PS1, SLUS_002.92 v1.1)
dump.  No emulator, no save states, no VRAM oracle.  Reference document:
`kit/docs/world_map_render.md`.

WHAT THE PLANE IS
-----------------
`D = *(0x80080000)` is the currently loaded `DATA/*/*_DATA.BIN`; `S = D->0x00`
is a **tile-field header**, byte-for-byte the same layout as the one
`area_tile_materials.load_room_materials` already parses for rooms:

    S+0x00 u16 w          (160 in every area)
    S+0x02 u16 h          (120)
    S+0x04 u8  count      (5)    -- how many 128x128 8bpp tile pages
    S+0x05 u8  pal_count  (3 or 16)
    S+0x08 ptr[count]     -- the tile-page pointers (16384 B LZSS each)
    S+0x0C ptr[pal_count] -- the 256-word RGB555 CLUT pointers, 512 B apart
    S+0x10 ptr[count]     -- 64 bytes per page: ONE palette selector per tile
    S+0x14 ptr            -- `[u32 len][LZSS]` -> w*h*2 B of u16 TILE CODES

So `world_map.md`'s "5 x 64-byte blocks whose meaning is open" is the per-atlas
**palette-selector table**, and the 160x120 u16 plane is a **tilemap**, not a
picture.  A cell is a 9-bit code: `atlas = code >> 6` (0..4), `tile = code & 63`.
Rendering `code & 0xFF` straight through a CLUT (what
`enemy_sprites.parse_worldmap` + `worldmap_all_areas.png` do) draws a
*colour-coded tile-id map*, which is recognisable-looking but is NOT the map the
game shows.

THE TRANSFORM  (`tile_field_renderer @ 0x8014CEB4`)
---------------------------------------------------
`L` is the material struct `0x800C3704(S)` builds.  The renderer is called with
`L+0x10`, so its `s5->0x0c` is `L+0x1c` (scroll x in pixels) and `s5->0x0e` is
`L+0x1e` (scroll y).  The world map sets exactly those two fields from the
camera cell `(col,row)`:

    0x80127DB0  lhu $v1, 0x8016F298      # camera col, in cells
    0x80127DB8  sll $v1, $v1, 4          # -> pixels
    0x80127DBC  sh  $v1, 0x1c($v0)       # L+0x1c = SX
    0x80127DC4  lhu $v0, 0x8016F29A      # camera row
    0x80127DCC  sll $v0, $v0, 4
    0x80127DD0  sh  $v0, 0x1e($v1)       # L+0x1e = SY

and the per-cell constants:

    0x800C4518  sb 0x10 -> L+0x01        # cellH = 16
    0x800C451C  sb 0x10 -> L+0x00        # cellW = 16
    0x800C4520  lhu S+0x00 -> L+0x02     # mw = 160
    0x800C452C  lhu S+0x02 -> L+0x04     # mh = 120
    0x800C4554  ori 0x140 -> L+0x18      # viewport 320 wide
    0x800C4558  ori 0xf0  -> L+0x1a      # viewport 240 tall

The cell index is then (`cw`/`ch` are `cellW`/`cellH`; `mw`/`mh` the map size):

    t3 = floor_mod(SX, mw*cw)        # 0x8014D074 div / 0x8014D09C mfhi
                                     #   sign fix: 0x8014D0B8 bgez / 0x8014D0C0 addu
    t6 = floor_mod(SY, mh*ch)        # 0x8014D0D0 div / 0x8014D0F8 mfhi
                                     #   sign fix: 0x8014D100 bgez / 0x8014D108 addu
    col = (t3 mod (mw*cw)) / cw      # 0x8014D1E4 div / 0x8014D20C mfhi / 0x8014D214 div / 0x8014D23C mflo
    row = (t6 mod (mh*ch)) / ch      # 0x8014D248 div / 0x8014D270 mfhi / 0x8014D278 div / 0x8014D2A0 mflo
    index = col + mw*row             # 0x8014D2AC mult / 0x8014D2B4 mflo / 0x8014D2B8 addu

Inside the walk the column counter is wrapped by a *compare-and-subtract*, not a
mask and not a division:

    0x8014D3FC  addiu $s1, $s1, 1        # next cell code index
    0x8014D400  div   $s1, $a0           # $a0 = mw
    0x8014D428  mfhi  $v0
    0x8014D430  bne   $v0, $zero, ...    # still inside the row?
    0x8014D438  subu  $s1, $s1, $a0      # no -> wrap the column back to 0

and the row loop re-enters the modulo at `0x8014D248`.  So all four of the
mechanisms that were searched for are present: a `div`/`mfhi` modulo, a `mult`
scaling, a signed-clamped subtraction, and a compare-and-subtract wrap.

CONSEQUENCE
-----------
The field is drawn as a **torus**: the whole 160x120 cells (2560x1920 px) repeat
in both axes.  The stored art is *not* toroidal (world_map_render.md §3 measured
that on the code plane; the composed art shows it directly), so where the camera
crosses an edge the window wraps to the opposite edge and a **hard seam** is
visible. Requested down/east movement tests the current row/column before
stepping, allowing the final step to row105/column140. The direction resolver
can then redirect movement onto the other axis; those two guards alone do not
prove global camera bounds. A real B-map conditional sliding case reaches107
(test_worldmap_points.py). The region table also contains two records whose
return-camera value is (63,107), but campaign reachability remains R057.

USAGE
-----
    .venv/bin/python kit/tools/world_map_render.py --verify
    .venv/bin/python kit/tools/world_map_render.py --dump
    .venv/bin/python kit/tools/world_map_render.py --json
    .venv/bin/python kit/tools/world_map_render.py --render kit/work/worldmap_render

Renders are **candidates for the user's image gate**, never accepted art.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

import disc                                    # noqa: E402
import lzss                                    # noqa: E402
from psx_vram import rgb555                    # noqa: E402

# ---------------------------------------------------------------------------
# provenance
# ---------------------------------------------------------------------------

MAIN_EXE = "MAIN.EXE"
MAIN_HEADER_BYTES = 2048
MAIN_BASE = 0x800C0800          # PS-X EXE t_addr of MAIN.EXE's image
AREA_BASE = 0x80080000          # the load base of the current *_DATA.BIN
TILE_PAGE_BYTES = 16384         # 128x128, 8bpp

#: every `DATA/*/*_DATA.BIN` that carries a world-map header (from
#: `enemy_sprites.area_files()`; kept here so this tool is self-contained).
AREA_FILES = (
    "DATA/01_AREA.A/A_DATA.BIN",
    "DATA/02_AREA.B/B_DATA.BIN",
    "DATA/02_AREA.B/J_DATA.BIN",
    "DATA/06_AREA.C/C_DATA.BIN",
    "DATA/07_AREA.D/D_DATA.BIN",
    "DATA/07_AREA.D/K_DATA.BIN",
    "DATA/08_AREA.E/E_DATA.BIN",
    "DATA/09_AREA.F/F_DATA.BIN",
    "DATA/10_AREA.G/G_DATA.BIN",
    "DATA/11_AREA.H/H_DATA.BIN",
    "DATA/15_AREA.Z/Z_DATA.BIN",
)

# ---------------------------------------------------------------------------
# the transform, as data, with an address per term
# ---------------------------------------------------------------------------

#: The header `S = *(*(0x80080000))`.  `meaning` is what the consumer does with
#: it; `addr` is where the consumer was read.
HEADER = {
    "w":        {"off": 0x00, "type": "u16", "meaning": "map width in cells",
                 "addr": 0x800C4520, "note": "copied to L+0x02 (mw)"},
    "h":        {"off": 0x02, "type": "u16", "meaning": "map height in cells",
                 "addr": 0x800C452C, "note": "copied to L+0x04 (mh)"},
    "count":    {"off": 0x04, "type": "u8", "meaning": "number of tile pages",
                 "addr": 0x800C3734, "note": "loop bound for the atlas table"},
    "pal_count": {"off": 0x05, "type": "u8", "meaning": "number of CLUTs",
                  "addr": 0x800C3790, "note": "loop bound for the CLUT table"},
    "atlases":  {"off": 0x08, "type": "ptr[count]", "meaning": "tile-page pointer table",
                 "addr": 0x800C3754, "note": "0x800C3704 walks it"},
    "cluts":    {"off": 0x0C, "type": "ptr[pal_count]", "meaning": "CLUT pointer table",
                 "addr": 0x800C37A0, "note": "each is loaded by 0x800C3C5C (LoadImage)"},
    "etab":     {"off": 0x10, "type": "ptr[count]", "meaning": "64 palette-selector bytes per page",
                 "addr": 0x800C42F0, "note": "read by 0x800C42F0, consumed via the 8-byte descriptor"},
    "tilemap":  {"off": 0x14, "type": "ptr", "meaning": "[u32 len][LZSS] -> w*h*2 B of u16 tile codes",
                 "addr": 0x800C4538, "note": "L+0x0c = S+0x14"},
}

#: The draw transform, term by term.  `addr` is the instruction that performs it.
TRANSFORM = {
    "cell_w":   {"value": 16,  "addr": 0x800C451C, "word": 0xA0A20000,
                 "meaning": "L+0x00 = 0x10; destination tile width in px"},
    "cell_h":   {"value": 16,  "addr": 0x800C4518, "word": 0xA0A20001,
                 "meaning": "L+0x01 = 0x10; destination tile height in px"},
    "mw":       {"value": 160, "addr": 0x800C4520, "word": 0x94820000,
                 "meaning": "L+0x02 = S.w; the horizontal wrap period, in cells"},
    "mh":       {"value": 120, "addr": 0x800C452C, "word": 0x94820002,
                 "meaning": "L+0x04 = S.h; the vertical wrap period, in cells"},
    "sx":       {"addr": 0x8014D068, "word": 0x86A2000C,
                 "meaning": "lh s5+0x0c = L+0x1c = camera col << 4"},
    "sy":       {"addr": 0x8014D0C4, "word": 0x86A2000E,
                 "meaning": "lh s5+0x0e = L+0x1e = camera row << 4"},
    "mod_x":    {"addr": 0x8014D074, "word": 0x0058001A, "word2": 0x00005810,
                 "addr2": 0x8014D09C,
                 "meaning": "div sx,(mw*cw); mfhi -> sx mod (mw*cw)"},
    "fix_x":    {"addr": 0x8014D0B8, "word": 0x05610002, "addr2": 0x8014D0C0,
                 "word2": 0x01785821,
                 "meaning": "bgez; addu t3,t3,(mw*cw) -- signed -> floor modulo"},
    "mod_y":    {"addr": 0x8014D0D0, "word": 0x0058001A, "word2": 0x00007010,
                 "addr2": 0x8014D0F8,
                 "meaning": "div sy,(mh*ch); mfhi -> sy mod (mh*ch)"},
    "fix_y":    {"addr": 0x8014D100, "word": 0x05C10003, "addr2": 0x8014D108,
                 "word2": 0x01D87021,
                 "meaning": "bgez; addu t6,t6,(mh*ch)"},
    "col":      {"addr": 0x8014D1E4, "word": 0x0218001A, "addr2": 0x8014D20C,
                 "word2": 0x00001810, "addr3": 0x8014D214, "word3": 0x006C001A,
                 "addr4": 0x8014D23C, "word4": 0x00001812,
                 "meaning": "col = (sx mod (mw*cw)) / cw  (div, mfhi, div, mflo)"},
    "row":      {"addr": 0x8014D248, "word": 0x02CF001A, "addr2": 0x8014D270,
                 "word2": 0x00001010, "addr3": 0x8014D278, "word3": 0x005E001A,
                 "addr4": 0x8014D2A0, "word4": 0x00001012,
                 "meaning": "row = (sy mod (mh*ch)) / ch"},
    "index":    {"addr": 0x8014D2AC, "word": 0x03020018, "addr2": 0x8014D2B4,
                 "word2": 0x00001012, "addr3": 0x8014D2B8, "word3": 0x00628821,
                 "meaning": "index = col + mw*row"},
    "col_wrap": {"addr": 0x8014D3FC, "word": 0x26310001, "addr2": 0x8014D400,
                 "word2": 0x0224001A, "addr3": 0x8014D428, "word3": 0x00001010,
                 "addr4": 0x8014D438, "word4": 0x02248823,
                 "meaning": "the walk: div s1,mw; mfhi; if 0 then subu s1,s1,mw "
                            "(compare-and-subtract column wrap)"},
    "lookup":   {"addr": 0x8014D2BC, "word": 0x8CA3000C, "addr2": 0x8014D2C8,
                 "word2": 0x94440000,
                 "meaning": "lw tilemap=L+0x0c; lhu (index*2)"},
}

#: Header facts read by the loader path, for `--verify`.
LOADER = {
    "state":        0x8017A0B8,   # the world-map module state
    "state_state":  0x8012700C - 0x40,  # (documentation only)
    "load_desc":    0x80126FA4,   # sw D -> state+0x2c
    "load_buf":     0x80126FF8,   # sw malloc(w*h*2) -> state+0x10
    "decode":       0x8012700C,   # jal text_decode_stream (0x800C3144)
    "camera_col":   0x8016F298,
    "camera_row":   0x8016F29A,
    "cam_col_set":  0x80131DD4,   # sh rec[+2] -> camera col
    "cam_row_set":  0x80131E00,   # sh rec[+4]+2 -> camera row
    "cam_value":    0x80131DC8,   # lhu rec[+2]
    "cam_value2":   0x80131DF0,   # lhu rec[+4]
    "cam_bias":     0x80131DF8,   # addiu +2
    "clamp_east":   0x80127748,   # slti col+19, 0x9f
    "clamp_south":  0x801276E8,   # slti row+14, 0x77
    "region_table": 0x80170064,   # u32 ptr[map_id]; record stride 14
    "region_stride": 14,
    "region_sel":   0x80127BCC,   # sw *(0x80170064 + map_id*4) -> state+0x30
}

#: Instruction words `--verify` insists on.  (addr, word, what it is)
EVIDENCE = (
    (0x8014D068, 0x86A2000C, "lh $v0,0xc($s5)   -- SX = L+0x1c"),
    (0x8014D074, 0x0058001A, "div $v0,$t8       -- SX by (mw*cellW)"),
    (0x8014D09C, 0x00005810, "mfhi $t3          -- t3 = SX mod (mw*cellW)"),
    (0x8014D0B8, 0x05610002, "bgez $t3          -- signed correction"),
    (0x8014D0C0, 0x01785821, "addu $t3,$t3,$t8  -- += modulus"),
    (0x8014D0C4, 0x86A2000E, "lh $v0,0xe($s5)   -- SY = L+0x1e"),
    (0x8014D0D0, 0x0058001A, "div $v0,$t8       -- SY by (mh*cellH)"),
    (0x8014D0F8, 0x00007010, "mfhi $t6          -- t6 = SY mod (mh*cellH)"),
    (0x8014D100, 0x05C10003, "bgez $t6"),
    (0x8014D108, 0x01D87021, "addu $t6,$t6,$t8"),
    (0x8014D1E4, 0x0218001A, "div $s0,$t8      -- column path"),
    (0x8014D20C, 0x00001810, "mfhi $v1"),
    (0x8014D214, 0x006C001A, "div $v1,$t4"),
    (0x8014D23C, 0x00001812, "mflo $v1          -- v1 = COLUMN"),
    (0x8014D248, 0x02CF001A, "div $s6,$t7      -- row path"),
    (0x8014D270, 0x00001010, "mfhi $v0"),
    (0x8014D278, 0x005E001A, "div $v0,$fp"),
    (0x8014D2A0, 0x00001012, "mflo $v0          -- v0 = ROW"),
    (0x8014D2A4, 0x97B80088, "lhu $t8,0x88($sp) -- t8 = mw"),
    (0x8014D2AC, 0x03020018, "mult $t8,$v0      -- mw*row"),
    (0x8014D2B4, 0x00001012, "mflo $v0"),
    (0x8014D2B8, 0x00628821, "addu $s1,$v1,$v0  -- s1 = col + mw*row"),
    (0x8014D2BC, 0x8CA3000C, "lw $v1,0xc($a1)   -- the tilemap"),
    (0x8014D2C0, 0x00111040, "sll $v0,$s1,1"),
    (0x8014D2C8, 0x94440000, "lhu $a0,0x0($v0)  -- the tile CODE"),
    (0x8014D400, 0x0224001A, "div $s1,$a0       -- walk: mod by mw"),
    (0x8014D428, 0x00001010, "mfhi $v0"),
    (0x8014D438, 0x02248823, "subu $s1,$s1,$a0  -- compare-and-subtract column wrap"),
    (0x800C4518, 0xA0A20001, "sb $v0,0x1($a1)   -- L+0x01 = 0x10 (cellH)"),
    (0x800C451C, 0xA0A20000, "sb $v0,0x0($a1)   -- L+0x00 = 0x10 (cellW)"),
    (0x800C4520, 0x94820000, "lhu $v0,0x0($a0)  -- mw = S+0x00"),
    (0x800C452C, 0x94820002, "lhu $v0,0x2($a0)  -- mh = S+0x02"),
    (0x800C4538, 0x8C830014, "lw $v1,0x14($a0)  -- tilemap = S+0x14"),
    (0x800C459C, 0xACA3000C, "sw $v1,0xc($a1)   -- L+0x0c = tilemap"),
    (0x800C4554, 0x34020140, "ori $v0,$zero,0x140 -- viewport 320"),
    (0x800C4558, 0xA4A20018, "sh $v0,0x18($a1)  -- L+0x18 = 320"),
    (0x80127DB0, 0x9463F298, "lhu $v1,0x8016F298 -- camera col"),
    (0x80127DB8, 0x00031900, "sll $v1,$v1,4      -- cells -> px"),
    (0x80127DBC, 0xA443001C, "sh $v1,0x1c($v0)   -- L+0x1c = SX"),
    (0x80127DC4, 0x9442F29A, "lhu $v0,0x8016F29A -- camera row"),
    (0x80127DCC, 0x00021100, "sll $v0,$v0,4"),
    (0x80127DD0, 0xA462001E, "sh $v0,0x1e($v1)   -- L+0x1e = SY"),
    (0x80127748, 0x2842009F, "slti $v0,$v0,0x9f  -- east clamp, col+19 < 159"),
    (0x801276E8, 0x28420077, "slti $v0,$v0,0x77  -- south clamp, row+14 < 119"),
    (0x80131DC8, 0x94420002, "lhu $v0,0x2($v0)   -- region record col"),
    (0x80131DD4, 0xA422F298, "sh $v0,0x8016F298  -- set camera col"),
    (0x80131DF0, 0x94420004, "lhu $v0,0x4($v0)   -- region record row"),
    (0x80131DF8, 0x24420002, "addiu $v0,$v0,2    -- +2 bias"),
    (0x80131E00, 0xA422F29A, "sh $v0,0x8016F29A  -- set camera row"),
    (0x80126FA4, 0x3C038018, "lui $v1,0x8018     -- the world-map loader head"),
    (0x80126FA8, 0x8C63A0B8, "lw $v1,-0x5f48($v1) -- = 0x8017A0B8, THE module state"),
    (0x80126FAC, 0x3C028008, "lui $v0,0x8008"),
    (0x80126FB0, 0x8C420000, "lw $v0,0x0($v0)     -- D = *(0x80080000)"),
    (0x80126FC0, 0xAC62002C, "sw $v0,0x2c($v1)   -- state+0x2c = D  (NOT S)"),
    (0x80126FC4, 0x8C500000, "lw $s0,0x0($v0)    -- S = D->0x00"),
    (0x80126FD8, 0x00620018, "mult $v1,$v0       -- w * (h*2)"),
    (0x80126FF8, 0xAC620010, "sw $v0,0x10($v1)   -- state+0x10 = the cell buffer"),
    (0x8012700C, 0x0C030C51, "jal 0x800C3144     -- text_decode_stream(S+0x14) into it"),
    # The world map's OWN tile setup, on the SAME state and the SAME S:
    (0x80127D88, 0x8C42A0B8, "lw $v0,-0x5f48($v0) -- the same 0x8017A0B8"),
    (0x80127D90, 0x8C42002C, "lw $v0,0x2c($v0)   -- D"),
    (0x80127D98, 0x8C440000, "lw $a0,0x0($v0)    -- S = D->0x00, the SAME S"),
    (0x80127D9C, 0x0C030DC1, "jal 0x800C3704     -- build the material L from that S"),
    (0x80127DB4, 0xAC820014, "sw $v0,0x14($a0)   -- state+0x14 = L"),
    (0x80127DD8, 0x8C820010, "lw $v0,0x10($a0)   -- state+0x10 = the DECODED 160x120 plane"),
    (0x80127DE0, 0xAC62000C, "sw $v0,0xc($v1)    -- L+0x0c = that plane (DELAY SLOT of the jal above)"),
    # ... and L+0x0c is what the tile renderer reads as the tilemap, indexing
    # it as lhu(index*2) and then indexing a count*64-entry 8-byte table.
    (0x800C4330, 0x00082240, "sll $a0,$t0,9      -- malloc(count << 9) = count*64*8-byte slots"),
    (0x800C4400, 0x8EC30010, "lw $v1,0x10($s6)   -- the S+0x10 table, read by the descriptor build"),
    (0x800C440C, 0x00431021, "addu $v0,$v0,$v1   -- &table[atlas]"),
    (0x800C4410, 0x8C510000, "lw $s1,0x0($v0)    -- s1 = that atlas's 64-byte block, used as DATA"),
)

# ---------------------------------------------------------------------------
# disc access
# ---------------------------------------------------------------------------


def _iso_records():
    path = os.path.join(_KIT, "extracted", "iso_files.json")
    with open(path) as fh:
        return json.load(fh)


def _read(name):
    rec = next(r for r in _iso_records() if r["path"] == name)
    return disc.extract(rec["lba"], rec["size"]), rec


def mainexe_image():
    """MAIN.EXE's headerless image (base 0x800C0800) straight off the disc.

    `disc.extract()` returns the 2048-byte PS-X EXE header **plus** the image,
    and the header's `t_addr` is the base of the **image only**.  Slicing the
    header off (and checking `t_addr`) is what keeps every address below right.
    """
    raw, _rec = _read(MAIN_EXE)
    if raw[:8] != b"PS-X EXE":
        raise ValueError("MAIN.EXE lacks the PS-X EXE signature")
    t_addr, t_size = struct.unpack_from("<II", raw, 0x18)
    if t_addr != MAIN_BASE:
        raise ValueError("MAIN.EXE t_addr is %#x, expected %#x" % (t_addr, MAIN_BASE))
    image = raw[MAIN_HEADER_BYTES:MAIN_HEADER_BYTES + t_size]
    if len(image) != t_size:
        raise ValueError("short MAIN.EXE image: %d of %d" % (len(image), t_size))
    return image


def word(image, va):
    off = va - MAIN_BASE
    if off < 0 or off + 4 > len(image):
        raise ValueError("address %#x outside the MAIN.EXE image" % va)
    return struct.unpack_from("<I", image, off)[0]


# ---------------------------------------------------------------------------
# the world-map header / tile field
# ---------------------------------------------------------------------------


class WorldMapError(ValueError):
    pass


def _to_file(d, va):
    off = va - AREA_BASE
    return off if 0 <= off < len(d) else None


def parse_worldmap(d):
    """Parse one `*_DATA.BIN` world-map header + tile field.

    Raises `WorldMapError` when anything does not hold, rather than returning a
    plausible-looking partial structure.
    """
    n = len(d)
    if n < 0x20:
        raise WorldMapError("area file too short")
    d_off = _to_file(d, struct.unpack_from("<I", d, 0)[0])
    if d_off is None or d_off + 0x20 > n:
        raise WorldMapError("descriptor pointer out of file")
    s_off = _to_file(d, struct.unpack_from("<I", d, d_off)[0])
    if s_off is None or s_off + 0x18 > n:
        raise WorldMapError("scene descriptor pointer out of file")

    w, h = struct.unpack_from("<HH", d, s_off + 0x00)
    count = d[s_off + 0x04]
    pal_count = d[s_off + 0x05]
    if not (1 <= count <= 16 and 1 <= pal_count <= 32):
        raise WorldMapError("implausible count/pal_count %d/%d" % (count, pal_count))

    def table(field, size, k):
        base = _to_file(d, struct.unpack_from("<I", d, s_off + field)[0])
        if base is None or base + size * k > n:
            raise WorldMapError("field %#x pointer out of file" % field)
        return struct.unpack_from("<I", d, base + 4 * k)[0], base

    pages, page_offsets = [], []
    for k in range(count):
        o, _ = table(0x08, 4 * count, k)
        o = _to_file(d, o)
        if o is None or o + 4 > n:
            raise WorldMapError("tile page %d pointer out of file" % k)
        ln = struct.unpack_from("<I", d, o)[0]
        if ln == 0 or o + 4 + ln > n:
            raise WorldMapError("tile page %d stream out of file" % k)
        raw = lzss.decode_strict(d[o + 4:o + 4 + ln])
        if len(raw) != TILE_PAGE_BYTES:
            raise WorldMapError("tile page %d decoded to %d bytes" % (k, len(raw)))
        pages.append(raw)
        page_offsets.append(o)

    cluts, clut_offsets = [], []
    for k in range(pal_count):
        o, _ = table(0x0C, 4 * pal_count, k)
        o = _to_file(d, o)
        if o is None or o + 512 > n:
            raise WorldMapError("CLUT %d pointer out of file" % k)
        words = struct.unpack_from("<256H", d, o)
        cluts.append([rgb555(v) for v in words])
        clut_offsets.append(o)

    etabs, etab_offsets = [], []
    for k in range(count):
        o, _ = table(0x10, 4 * count, k)
        o = _to_file(d, o)
        if o is None or o + 64 > n:
            raise WorldMapError("etab %d pointer out of file" % k)
        etabs.append(tuple(d[o:o + 64]))
        etab_offsets.append(o)

    t_off = _to_file(d, struct.unpack_from("<I", d, s_off + 0x14)[0])
    if t_off is None or t_off + 4 > n:
        raise WorldMapError("tilemap pointer out of file")
    tlen = struct.unpack_from("<I", d, t_off)[0]
    if tlen == 0 or t_off + 4 + tlen > n:
        raise WorldMapError("tilemap stream out of file")
    tilemap = lzss.decode_strict(d[t_off + 4:t_off + 4 + tlen])
    if len(tilemap) != w * h * 2:
        raise WorldMapError("tilemap decoded to %d bytes, expected %d"
                            % (len(tilemap), w * h * 2))
    codes = struct.unpack_from("<%dH" % (w * h), tilemap, 0)

    worst = max(codes)
    if worst >= count * 64:
        raise WorldMapError("tile code %d exceeds count*64 = %d" % (worst, count * 64))
    for at, sel in enumerate(etabs):
        if sel and max(sel) >= pal_count:
            raise WorldMapError("atlas %d selects palette %d, only %d declared"
                                % (at, max(sel), pal_count))

    return {
        "d_off": d_off, "s_off": s_off,
        "w": w, "h": h, "count": count, "pal_count": pal_count,
        "pages": pages, "page_offsets": page_offsets,
        "cluts": cluts, "clut_offsets": clut_offsets,
        "etabs": etabs, "etab_offsets": etab_offsets,
        "codes": codes, "tilemap_off": t_off, "tilemap_len": tlen,
        "pixel_w": w * HEADER_TILE_W, "pixel_h": h * HEADER_TILE_H,
    }


HEADER_TILE_W = 0x10
HEADER_TILE_H = 0x10


def tile_of(plane, code):
    """`(atlas, tile, palette)` for one cell, or None when the cell is empty."""
    atlas = code >> 6
    tile = code & 63
    if atlas >= plane["count"]:
        return None
    palette = plane["etabs"][atlas][tile] % plane["pal_count"]
    return atlas, tile, palette


def tile_pixels(plane, atlas, tile, palette):
    """The 16x16 RGB rows of one tile, in engine order (8 tiles per page row)."""
    page = plane["pages"][atlas]
    pal = plane["cluts"][palette]
    ty, tx = divmod(tile, 8)
    base = ty * 16 * 128 + tx * 16
    return [[pal[page[base + y * 128 + x]] for x in range(16)] for y in range(16)]


# ---------------------------------------------------------------------------
# the transform, executable
# ---------------------------------------------------------------------------


def floor_mod(value, modulus):
    """MIPS signed `div` + `mfhi` + the renderer's `bgez / addu` sign fix.

    Python's `%` already floors for a positive modulus; the explicit branch is
    kept so the sign convention is stated in one place.
    """
    if modulus <= 0:
        raise ValueError("modulus must be positive")
    r = value % modulus
    return r + modulus if r < 0 else r


def cell_index(sx, sy, mw, mh, cw=HEADER_TILE_W, ch=HEADER_TILE_H):
    """The engine's `tile_field_renderer @ 0x8014CEB4` source-cell transform.

    `sx`/`sy` are the layer scroll in PIXELS (`L+0x1c`/`L+0x1e`); `mw`/`mh` the
    map size in CELLS.  Returns `(index, col, row)`.
    """
    col = floor_mod(sx, mw * cw) // cw
    row = floor_mod(sy, mh * ch) // ch
    return col + mw * row, col, row


def camera_window(col, row, cols=20, rows=15):
    """The `(col,row)` cells a 20x15 window shows, with the engine's wrap.

    The camera is the window's top-left cell, so screen cell `(rx,ry)` reads
    `((col+rx) mod mw, (row+ry) mod mh)`.
    """
    return [[(col + rx) % 160, (row + ry) % 120] for ry in range(rows)
            for rx in range(cols)]


# ---------------------------------------------------------------------------
# region tables (the per-map "screen" table that places the camera)
# ---------------------------------------------------------------------------


def region_tables(image):
    """`*(0x80170064 + map_id*4)` -> the 14-byte region records.

    Record: `u8 kind` (8 = terminator), `u8 pad`, `s16 col`, `s16 row`, then 8
    more bytes.  `0x80131DC8` reads `+2` as the camera column and `0x80131DF0`
    reads `+4`, adds 2, and stores it as the camera row.
    """
    base = LOADER["region_table"]
    out = {}
    for map_id in range(16):
        ptr = word(image, base + 4 * map_id)
        if not (MAIN_BASE <= ptr < MAIN_BASE + len(image)):
            continue
        off = ptr - MAIN_BASE
        recs = []
        for k in range(64):
            raw = image[off + 14 * k:off + 14 * k + 14]
            if len(raw) < 14 or raw[0] == 8:
                break
            col, row = struct.unpack_from("<hh", raw, 2)
            recs.append({"record": k, "kind": raw[0], "col": col, "row": row,
                         "camera": [col, row + 2], "raw": raw.hex()})
        out[map_id] = {"offset": ptr, "records": recs}
    return out


def out_of_plane(rec, mw=160, mh=120, cols=20, rows=15):
    """True when this record's window leaves the stored plane (so it wraps)."""
    c, r = rec["camera"]
    return c < 0 or r < 0 or c + cols > mw or r + rows > mh


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------


def compose(plane, col0=0, row0=0, cols=None, rows=None, wrap=True):
    """Render terrain only; world rendering also needs the water underlay and Hero.

    export_world_art.py/world_view.zig preserve those layers and source clocks.
    """
    from PIL import Image

    w, h = plane["w"], plane["h"]
    cols = w if cols is None else cols
    rows = h if rows is None else rows
    img = Image.new("RGB", (cols * 16, rows * 16))
    px = img.load()
    cache = {}
    for ry in range(rows):
        for rx in range(cols):
            cy, cx = row0 + ry, col0 + rx
            if wrap:
                cy %= h
                cx %= w
            elif not (0 <= cx < w and 0 <= cy < h):
                continue
            code = plane["codes"][cy * w + cx]
            t = tile_of(plane, code)
            if t is None:
                continue
            key = t
            if key not in cache:
                cache[key] = tile_pixels(plane, *t)
            tile = cache[key]
            ox, oy = rx * 16, ry * 16
            for y in range(16):
                rowpix = tile[y]
                for x in range(16):
                    px[ox + x, oy + y] = rowpix[x]
    return img


def viewport(plane, cam_col, cam_row, cols=20, rows=15, wrap=True):
    """The 320x240 in-game window at camera cell `(cam_col, cam_row)`."""
    return compose(plane, cam_col, cam_row, cols, rows, wrap=wrap)


def load_plane(path):
    rec = next(r for r in _iso_records() if r["path"] == path)
    d = disc.extract(rec["lba"], rec["size"])
    plane = parse_worldmap(d)
    plane["path"] = path
    plane["lba"] = rec["lba"]
    plane["size"] = rec["size"]
    return plane


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------


def verify(image=None, verbose=True):
    """Re-derive every instruction word and every structural constant."""
    image = mainexe_image() if image is None else image
    bad = []
    for addr, want, what in EVIDENCE:
        got = word(image, addr)
        if got != want:
            bad.append("%#010x: want %08X got %08X  (%s)" % (addr, want, got, what))
    if verbose:
        for addr, want, what in EVIDENCE:
            print("  %#010x  %08X  %s" % (addr, want, what))
    if bad:
        raise AssertionError("instruction evidence does not re-derive:\n  "
                             + "\n  ".join(bad))
    return True


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def cmd_dump(image):
    print("MAIN.EXE image base %#x, %d bytes" % (MAIN_BASE, len(image)))
    print()
    print("== the transform ==")
    for name, t in TRANSFORM.items():
        addrs = " ".join(
            "%#x=%08X" % (t[k], t[v]) for k, v in
            (("addr", "word"), ("addr2", "word2"), ("addr3", "word3"),
             ("addr4", "word4")) if k in t)
        print("  %-9s %-28s %s" % (name, t["meaning"], addrs))
    print()
    print("== region tables (*0x80170064) ==")
    for map_id, tab in region_tables(image).items():
        recs = tab["records"]
        wrap = [r["record"] for r in recs if out_of_plane(r)]
        print("  map %-2d @%#010x  %2d records%s"
              % (map_id, tab["offset"], len(recs),
                 "   WRAPS at records %s" % wrap if wrap else ""))
    print()
    print("== planes ==")
    for path in AREA_FILES:
        p = load_plane(path)
        print("  %-30s S+0x%04x w=%d h=%d count=%d pal=%d codes<=%d"
              % (path, p["s_off"], p["w"], p["h"], p["count"], p["pal_count"],
                 max(p["codes"])))


def cmd_json(image, planes=None):
    planes = AREA_FILES if planes is None else planes
    out = {
        "method": "world_map_render/1",
        "main_base": "%#x" % MAIN_BASE,
        "transform": TRANSFORM,
        "header": HEADER,
        "loader": {k: ("%#x" % v if isinstance(v, int) and v > 0xFFFF else v)
                   for k, v in LOADER.items()},
        "evidence": [{"addr": "%#x" % a, "word": "%08X" % w, "what": s}
                     for a, w, s in EVIDENCE],
        "region_tables": region_tables(image),
        "planes": [],
    }
    for path in planes:
        p = load_plane(path)
        out["planes"].append({
            "path": path, "lba": p["lba"], "size": p["size"],
            "s_offset": p["s_off"], "w": p["w"], "h": p["h"],
            "count": p["count"], "pal_count": p["pal_count"],
            "cells": p["w"] * p["h"], "cell_w": HEADER_TILE_W, "cell_h": HEADER_TILE_H,
            "pixel_w": p["pixel_w"], "pixel_h": p["pixel_h"],
            "code_max": max(p["codes"]),
            "atlas_histogram": [sum(1 for c in p["codes"] if c >> 6 == a)
                                for a in range(p["count"])],
            "etab_values": sorted({v for e in p["etabs"] for v in e}),
            "tilemap_offset": p["tilemap_off"],
        })
    return out


def cmd_render(image, outdir):
    from PIL import Image, ImageDraw

    os.makedirs(outdir, exist_ok=True)
    made = []

    def save(img, name):
        path = os.path.join(outdir, name)
        img.save(path)
        made.append(path)
        return path

    planes = [(p, load_plane(p)) for p in AREA_FILES]

    # 1. every plane, composed at 16 px/cell, downscaled 1/4 for the sheet.
    tiles = []
    for path, p in planes:
        img = compose(p)
        tag = path.split("/")[1].replace("_", " ")
        tiles.append({"label": "%s  w%d h%d  %dx%d px" % (tag, p["w"], p["h"],
                                                          p["pixel_w"], p["pixel_h"]),
                      "image": img.resize((640, 480), Image.NEAREST)})
    _sheet(tiles, os.path.join(outdir, "worldmap_composed_all_areas.png"),
           "WORLD MAP, drawn from the tile field: cell = atlas*64+tile, "
           "palette = etab[atlas][tile].  Every plane reduced 4x.  CANDIDATE "
           "for the user's image gate -- not promoted.", 2, cols=3)
    made.append(os.path.join(outdir, "worldmap_composed_all_areas.png"))

    # 2. the in-game 20x15 window (320x240) at every region camera of map 1.
    tab1 = region_tables(image)[1]["records"]
    wins = []
    e = dict(planes)["DATA/08_AREA.E/E_DATA.BIN"]
    for r in tab1:
        c, rw = r["camera"]
        img = viewport(e, c, rw)
        wins.append({"label": "rec %d cam(%d,%d)%s"
                     % (r["record"], c, rw, " WRAP" if out_of_plane(r) else ""),
                     "image": img})
    _sheet(wins, os.path.join(outdir, "worldmap_region_windows_E.png"),
           "Area E drawn as the game draws it: the 320x240 (20x15 cell) window "
           "at every camera of region map 1.  CANDIDATE; user-gated.", 1, cols=7)
    made.append(os.path.join(outdir, "worldmap_region_windows_E.png"))

    # 3. the seam, explicitly: the two records whose window leaves the plane.
    seam = []
    for path, p in planes:
        if "E_DATA" not in path and "A_DATA" not in path and "Z_DATA" not in path:
            continue
        wrapped = viewport(p, 63, 107, wrap=True)
        clamped = compose(p, 63, 107, 20, 15, wrap=False)
        for label, img in (("wrap (engine)", wrapped),
                           ("no wrap (reference)", clamped)):
            d = ImageDraw.Draw(img)
            d.rectangle([0, 0, 319, 239], outline=(255, 0, 255))
            seam.append({"label": "%s %s" % (path.split("/")[-1], label),
                         "image": img})
    _sheet(seam, os.path.join(outdir, "worldmap_wrap_seam.png"),
           "THE WRAP, shown rather than hidden.  Camera cell (63,107) is region "
           "map 1 record 42 (and map 9 record 42) -- 2 rows past the 120-row "
           "plane.  The 15-row window covers rows 107..121, so the engine's "
           "torus (top) draws the map's rows 0-1 along the bottom of the "
           "screen; the reference (bottom) shows the field as stored.  "
           "CANDIDATE; user-gated.", 2, cols=2)
    made.append(os.path.join(outdir, "worldmap_wrap_seam.png"))

    # 4. one full-resolution composed plane for close inspection.
    save(compose(e), "worldmap_composed_E_full.png")
    save(viewport(e, 63, 107), "worldmap_viewport_E_cam_63_107.png")
    save(viewport(e, 63, 41), "worldmap_viewport_E_cam_63_41.png")
    return made


def _sheet(items, path, caption, scale, cols=1):
    from PIL import Image, ImageDraw
    if not items:
        return
    cell_w = max(it["image"].width for it in items) * scale
    cell_h = max(it["image"].height for it in items) * scale
    bar = 14
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w, rows * (cell_h + bar) + 40),
                      (16, 16, 16))
    dr = ImageDraw.Draw(sheet)
    for i, it in enumerate(items):
        cx = (i % cols) * cell_w
        cy = (i // cols) * (cell_h + bar)
        img = it["image"]
        if scale != 1:
            img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
        sheet.paste(img, (cx, cy))
        dr.text((cx + 3, cy + cell_h + 1), it["label"][:60], fill=(235, 235, 235))
    for i, line in enumerate(_wrap(caption, cols * cell_w // 7)):
        dr.text((4, rows * (cell_h + bar) + 2 + i * 12), line, fill=(255, 220, 120))
    sheet.save(path)


def _wrap(text, width):
    words, lines, cur = text.split(), [], ""
    for word in words:
        if len(cur) + len(word) + 1 > width:
            lines.append(cur)
            cur = word
        else:
            cur = (cur + " " + word).strip()
    if cur:
        lines.append(cur)
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--verify", action="store_true",
                    help="re-derive every cited instruction word")
    ap.add_argument("--dump", action="store_true", help="print the transform and tables")
    ap.add_argument("--json", action="store_true", help="emit the derived data as JSON")
    ap.add_argument("--render", metavar="OUTDIR", help="write candidate renders")
    args = ap.parse_args(argv)

    if not (args.verify or args.dump or args.json or args.render):
        ap.print_help()
        return 2

    image = mainexe_image()
    if args.verify:
        verify(image)
        print("PASS: every cited instruction word re-derives from MAIN.EXE")
    if args.dump:
        cmd_dump(image)
    if args.json:
        print(json.dumps(cmd_json(image), indent=2, sort_keys=True))
    if args.render:
        for path in cmd_render(image, args.render):
            print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
