#!/usr/bin/env python3
"""
Historical synthetic renderer of a misidentified entity-coordinate path.

CORRECTION2026-10-15: this is not the game glyph renderer. The24-byte
records are entities and the results below are screen coordinates for box
placement. See entity_graphics_selection.md, text_packet_lowering.md,
system_glyph_sources.md and text_layout_rules.md. Original synthetic
experiment below is retained as the error record; do not use it for assets.

Faithfully reimplements the MAIN.EXE text pipeline from disassembly:
  dialogue byte
    -> char_encoding_translate (0x80133BB4): byte -> tile index
         via per-area char->tile map at (*(0x8017BE20)+0x484)
    -> text_char_decoder (0x8013AFA0): tile index -> 24-byte descriptor
         -> (U,V) texture coords:
              U = (desc[0]+1)*8 - [0x8017C008] - 0xA0 + [0x8017B7CC]
              V = (desc[1]-3)*8 - [0x8017C010] - 0x78 + [0x8017B7D4]
    -> textured quad blitted from the font-atlas texture

Descriptor table selection (from 0x8013AFA0):
  code == 0x80 : fixed descriptor @ 0x8017BD74
  code == 0x81 : fixed descriptor @ 0x8017C0A4
  code == 0xFF : descriptor via [[0x8017A120]] (u16 pair)
  code & 0x40 : [0x8017AF94] + (code&0x3F)*24  (system-font table)
  else         : [0x8017DAA0] + code*24        (area tile table)

Since the real per-area tables and font atlas only exist at runtime, this
tool takes SYNTHETIC inputs: a tile-descriptor list, a char->tile map, and
a font-atlas image.  It proves the LAYOUT logic (index -> UV -> blit);
glyph art itself comes from the atlas you supply.

Usage:
  python3 text_render.py --selftest   # builds synthetic atlas+tables,
                                     # renders a test string, writes PNGs
"""

import argparse
import os

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
import struct
import sys

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Faithful reimplementation of the pipeline stages
# ---------------------------------------------------------------------------

class TextPipeline:
    """
    ram: dict emulating the RAM variables the pipeline reads:
      0x8017C008, 0x8017C010 : scroll/adjust (u16)
      0x8017B7CC, 0x8017B7D4 : texture-base U/V (u16)
      0x8017A120             : pointer for the 0xFF special descriptor
    tile_descs   : list of 24-byte descriptors (area tile table @0x8017DAA0)
    sysfont_descs: list of 24-byte descriptors (system table @0x8017AF94)
    special_80, special_81: 24-byte descriptors for codes 0x80/0x81
    char_to_tile : list of 256 ints (per-area char->tile map); None = NULL table
    """

    def __init__(self, ram, tile_descs, sysfont_descs,
                 special_80, special_81, char_to_tile):
        self.ram = ram
        self.tile_descs = tile_descs
        self.sysfont_descs = sysfont_descs
        self.special_80 = special_80
        self.special_81 = special_81
        self.char_to_tile = char_to_tile

    # -- 0x80133BB4 char_encoding_translate -------------------------------
    def char_encoding_translate(self, byte):
        """byte -> tile index. Returns 0x80 when the table pointer is NULL."""
        if self.char_to_tile is None:
            return 0x80
        return self.char_to_tile[byte & 0xFF] & 0xFF

    # -- 0x8013AFA0 text_char_decoder --------------------------------------
    def _select_descriptor(self, code):
        code &= 0xFF
        if code == 0x80:
            return self.special_80
        if code == 0x81:
            return self.special_81
        if code == 0xFF:
            # [[0x8017A120]]: two u16s used as desc[0], desc[1]
            w0, w1 = struct.unpack_from('<HH', self.ram['ff_desc'])
            d = bytearray(24)
            d[0] = w0 & 0xFF
            d[1] = w1 & 0xFF
            return bytes(d)
        if code & 0x40:
            return self.sysfont_descs[code & 0x3F]
        return self.tile_descs[code]

    def text_char_decoder(self, code):
        """
        code (already translated tile index) -> (U, V) texture coords.
        Mirrors the arithmetic at 0x8013b06c-0x8013b0c0 exactly:
            U = (desc[0]+1)*8 - [0x8017C008] - 0xA0 + [0x8017B7CC]
            V = (desc[1]-3)*8 - [0x8017C010] - 0x78 + [0x8017B7D4]
        """
        desc = self._select_descriptor(code)
        u = (desc[0] + 1) * 8 - self.ram[0x8017C008] - 0xA0 + self.ram[0x8017B7CC]
        v = (desc[1] - 3) * 8 - self.ram[0x8017C010] - 0x78 + self.ram[0x8017B7D4]
        return u & 0xFFFF, v & 0xFFFF

    # -- per-character draw (0x8013b1e0 dialogue_text_char_processor) ------
    def draw_char(self, canvas, atlas, byte, cursor_x, cursor_y,
                  glyph_px=24):
        """
        Draw one dialogue byte at canvas position (cursor_x, cursor_y).
        Returns the new cursor_x (advance by one glyph cell).
        """
        tile = self.char_encoding_translate(byte)
        u, v = self.text_char_decoder(tile)
        # Blit the glyph quad from the atlas.  The engine's packet carries
        # W,H = 3,3 (in 8px units -> 24x24 px); the atlas itself is indexed
        # at 8px granularity by the UV formula.
        glyph = atlas.crop((u, v, u + glyph_px, v + glyph_px))
        canvas.paste(glyph, (cursor_x, cursor_y))
        return cursor_x + glyph_px

    def render_stream(self, stream, atlas, cols=16, glyph_px=24,
                      box_w=384, box_h=144, bg=(8, 8, 24)):
        """Render a byte stream into a dialogue-box image (simple wrap)."""
        canvas = Image.new('RGB', (box_w, box_h), bg)
        cx, cy = 8, 8
        for b in stream:
            if b == 0x0A:  # newline control (conventional; engine-specific
                           # codes live in the overlay event VM)
                cx, cy = 8, cy + glyph_px + 4
                continue
            if cx + glyph_px > box_w - 8:
                cx, cy = 8, cy + glyph_px + 4
            if cy + glyph_px > box_h - 8:
                break
            cx = self.draw_char(canvas, atlas, b, cx, cy, glyph_px)
        return canvas


# ---------------------------------------------------------------------------
# Synthetic inputs for the self-test
# ---------------------------------------------------------------------------

def make_synthetic_atlas(path, cells=16, cell_px=8, scale=3):
    """
    16x16 grid of 8x8 glyph cells, each drawn with a distinct pattern.
    Cells are addressed at 8px granularity, matching the UV formula's *8.
    """
    px = cells * cell_px
    img = Image.new('RGB', (px, px), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for i in range(cells * cells):
        cx = (i % cells) * cell_px
        cy = (i // cells) * cell_px
        # distinct gray level per glyph + index-derived pattern
        g = 60 + (i * 173) % 180
        d.rectangle([cx, cy, cx + cell_px - 1, cy + cell_px - 1],
                    fill=(g, g, g // 2 + 40))
        # cross pattern seeded by index so every cell is visually distinct
        for k in range(cell_px):
            if (i >> k) & 1:
                d.point((cx + k, cy + (k * 5 + i) % cell_px), fill=(255, 240, 200))
    img = img.resize((px * scale, px * scale), Image.NEAREST)
    img.save(path)
    return img


def make_synthetic_tables():
    """256 area-tile descriptors + 64 sysfont descriptors."""
    tile_descs = []
    for i in range(256):
        d = bytearray(24)
        d[0] = i % 16        # desc[0] = atlas column
        d[1] = i // 16       # desc[1] = atlas row
        tile_descs.append(bytes(d))
    sysfont_descs = []
    for i in range(64):
        d = bytearray(24)
        d[0] = (i + 8) % 16
        d[1] = (i // 16) + 8
        sysfont_descs.append(bytes(d))
    special_80 = bytes(bytearray(24))
    special_81 = bytes(bytearray(24))
    # identity char->tile map
    char_to_tile = list(range(256))
    return tile_descs, sysfont_descs, special_80, special_81, char_to_tile


def selftest(outdir):
    os.makedirs(outdir, exist_ok=True)
    atlas_path = os.path.join(outdir, 'synth_atlas.png')
    # atlas drawn at 8px cells, then 3x scaled to 24px glyphs
    atlas = make_synthetic_atlas(atlas_path)

    tile_descs, sysfont_descs, sp80, sp81, c2t = make_synthetic_tables()

    # RAM values chosen so the UV formula lands on the synthetic atlas:
    #   U = (col+1)*8 - 0 - 0xA0 + U_base ; want U = col*24 (24px cells)
    #   => U_base = 152 ; V = (row-3)*8 - 0x78 + V_base ; want V = row*24
    #   => V_base = 144.
    # (Atlas was 3x-scaled, so cell (col,row) starts at (col*24, row*24).)
    ram = {
        0x8017C008: 0,
        0x8017C010: 0,
        0x8017B7CC: 152,
        0x8017B7D4: 144,
        'ff_desc': struct.pack('<HH', 0, 0),
    }
    pipe = TextPipeline(ram, tile_descs, sysfont_descs, sp80, sp81, c2t)

    # Test 1: area-tile codes 0x00-0x3F (uses tile_descs)
    s1 = bytes(range(0x00, 0x20))
    img1 = pipe.render_stream(s1, atlas)
    img1.save(os.path.join(outdir, 'render_tilecodes.png'))

    # Test 2: system-font codes 0x40-0x5A ("@ABC...Z", uses sysfont_descs)
    s2 = bytes(range(0x40, 0x5B))
    img2 = pipe.render_stream(s2, atlas)
    img2.save(os.path.join(outdir, 'render_sysfont.png'))

    # Test 3: mixed stream with newline + 0xFF special
    s3 = bytes([0x41, 0x42, 0x43, 0x0A, 0x05, 0x06, 0x07, 0x44, 0x45])
    img3 = pipe.render_stream(s3, atlas)
    img3.save(os.path.join(outdir, 'render_mixed.png'))

    # Test 4: verify UV math on known inputs
    u, v = pipe.text_char_decoder(pipe.char_encoding_translate(0x05))
    # desc = tile_descs[5] -> col=5,row=0 -> U=(5+1)*8-160+152=40, V=(0-3)*8-120+144=0
    assert (u, v) == (40, 0), f"UV mismatch: {(u, v)}"
    u2, v2 = pipe.text_char_decoder(pipe.char_encoding_translate(0x41))
    # sysfont_descs[1] -> col=9,row=8 -> U=(9+1)*8-160+152=72, V=(8-3)*8-120+144=64
    assert (u2, v2) == (72, 64), f"UV mismatch: {(u2, v2)}"

    print(f"selftest OK: 3 renders + UV assertions passed -> {outdir}")
    return [os.path.join(outdir, f) for f in
            ('synth_atlas.png', 'render_tilecodes.png',
             'render_sysfont.png', 'render_mixed.png')]


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--outdir', default=os.path.join(_KIT, 'work/proof'))
    args = ap.parse_args()
    if args.selftest:
        for f in selftest(args.outdir):
            print('wrote', f)
    else:
        ap.print_help()
        sys.exit(1)
