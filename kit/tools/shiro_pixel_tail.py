#!/usr/bin/env python3
"""The `03_SHIRO` pixel long tail: BATH geometry, STONE index statistics,
and the load-group ownership of PAPER / YUGE / MIZU / HANA / CURIO.

> CORRECTION2026-10-15: the index-statistic negative below is superseded by
> stone_composite.py and stone_composite_palettes.md. The alleged BSS palettes
> are embedded in the last2048 disc bytes; the coloured composite has structure.
> Historical interpretations below are retained as an error record.

> **CORRECTION 2026-10-08** — the STONE draw trace below is superseded.
> `0x800833D4` loads vtable `+0x6C`, which is `GetTpage` (`0x8014AB0C`), not
> `LoadImage`; the `0x240`/`0x100` pair at `0x800833D8`/`0x800833E0` are that
> call's `x` and `y` arguments and the result is stored at `POLY_FT4 +0x16`, so
> this overlay *does* sample the page it uploads.  The RECT table at
> `0x80084CDC` holds **18** entries (the loader's own bound is
> `slti $v0,$v0,0x12`), not two runs of 16, and `0x80084D6C` is a 14-entry
> 20-byte page-coordinate table read by the composite at `0x80081334`, which
> samples all 18 rects.  The `+0x780` field is a display-list head (read at
> `0x80081F88`, written back at `0x80081FB4`), not a texture-page word.
> Canonical: `kit/tools/q_stone.py`, gate `kit/tests/test_q_stone.py`, page
> `manual/04-rendering.md`.  The bit-depth negative in (b) is unaffected.

Three independent probes, all from the disc through `kit/tools/disc.py` and the
canonical `kit/tools/lzss.py` v2.0.0 (`text_decode_stream @0x800C3144`).  Every
container decode is checked for **full input consumption**; a partial decode is
an error here, never a page.

(a) BATH geometry -- **SOLVED**.  Each of the 24 `BATH_*.BIN` is
    `[u32 filesize-4][LZSS]` -> exactly 16,384 B.  `bath_init @0x80080460`
    caches the directory groups 4..8; `bath_sound_load` case 2 takes the file
    index from `[state+4]`, indexes the RECT table at `0x80085884` with it
    (`lw v0,0x4(s0); sll v0,v0,3; addu at,0x80085884`), and LoadImages the
    decode buffer to that RECT.  So file *i* of a bank -> RECT *i*, each
    64x128 halfwords = **128x128 8bpp**, and the six RECTs tile a **384x256**
    sheet at VRAM `x 0x2C0..0x380` words, `y 0..0x100`.  The bank comes from
    the state byte `[state+0x3D]`, which also selects the 256-colour RGB555
    palette at `0x8008D114 + bank*0x200`.  Rendered, the sheets are legible
    bath-house scenes -- this is the gate image.

(b) STONE bit depth -- **PRECISE NEGATIVE**.  The 18 `STONE_nn.BIN` also decode
    to exactly 16,384 B, and `stone_lookup_step @0x80080F54` decodes one into
    `0x80091A44` and LoadImages it to VRAM `(0x240,0x100)` 64x128 halfwords via
    `stone_loadimage_wrap_a @0x80083D98` -- so the page *is* an uploaded texture.
    But it has **no raster structure**: lag-1 autocorrelation <= 0.055 (a
    legible sibling page: 0.69), and the 4x4 block-variance ratio is 1.13-1.36
    for all 18 pages against 2.1-14.1 for every legible sibling family.  It
    stays a negative under 8/4/16 bpp, both nibble orders, 8x8..32x32 tile
    grids, chunk interleaves k=2..512, bit-reverse, NOT, XOR 0x80, row/column
    delta, transpose and contiguous bit-planes.  The tool publishes the numbers,
    never an image: this is an honest negative.

(c) Ownership of `PAPER` / `YUGE` / `MIZU` / `HANA` / `CURIO` -- **SOLVED by the
    readers**.  The 16-entry directory at `0x8016B358` (installed by
    `0x800C9650`) is read by exactly three `03_SHIRO` overlays and the duel
    overlays:

        group 1  (STONE_00..11)              STONE.BIN  @0x800802BC  lw a0,0x14b8(v1)
        group 3  (BOOK/PAPER/CURIO_0)        BOOKS.BIN  @0x800802D4  lw v1,0x14b8(v1)
        group 4-7(BATH_00..35)               BATH.BIN   @0x800804A8  lw v1,0x14b8(v0)
        group 8  (YUGE/MIZU/CURIO_0/HANA)    BATH.BIN   @0x800804A8, 0x20(v1)
        group 2  (FACE_01..27)               VB5A2/VB5B3/VB5B4/VB5C4
        group 15 (VC61/VB5A21/VB5B31)        VB5A1/A2/B1/B2/B3/C1/C2/C3/CG, VS1, VAD

    Each reader's group list is then indexed by a state counter and handed to the
    game-state loader `vtable[0x10] = cd_read_sectors_struct @0x800C2EF8`:
    BOOKS.BIN `0x800804B0..0x800804D8` (`dir[3][idx]` -> `0x80087518`) and
    BATH.BIN `0x8008095C..0x80080994` (`dir[8][idx]` -> load buffer
    `[0x80088114]`).  BATH's own debug string for group 8 is
    **`csr_data_steam`** (`0x8008006C`, printed at `0x800805B8`).

Usage:
    python3 shiro_pixel_tail.py --bath               # geometry + palette report
    python3 shiro_pixel_tail.py --bath --render DIR  # the gated scene sheets
    python3 shiro_pixel_tail.py --stone              # the bit-depth negative
    python3 shiro_pixel_tail.py --groups             # the ownership table
    python3 shiro_pixel_tail.py --json PATH          # all three as data
"""
from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import disc_iso  # noqa: E402
import lzss  # noqa: E402
from psx_vram import rgb555  # noqa: E402

ISO = os.path.join(_KIT, "extracted", "iso_files.json")
PAGE_BYTES = 16384                      # 128x128 8bpp, or 256x128 4bpp, ...

# ---------------------------------------------------------------------------
# (a) BATH
# ---------------------------------------------------------------------------
BATH_DIR = "DATA/03_SHIRO/DATA"
BATH_BANK_FILES = [[f"BATH_{b}{i}.BIN" for i in range(6)] for b in range(4)]

BATH_OVERLAY = "DATA/03_SHIRO/BATH.BIN"
BATH_BASE = 0x80080000
#: 6 x (x, y, w, h) u16 -- the LoadImage destination of file index i (64x128 words)
BATH_RECT_TABLE = 0x80085884
#: 4 x u32 -- 256-colour RGB555 palette of bank b, uploaded to VRAM (0, 0x1E0)
BATH_CLUT_TABLE = 0x80085874
BATH_CLUT_DATA = 0x8008D114
CLUT_BYTES = 512
#: five more 512-byte palettes the overlay uploads by hand to VRAM rows 0x1E0-0x1E4
BATH_EXTRA_CLUTS = [0x8008D914, 0x8008DB14, 0x8008DD14, 0x8008DF14, 0x8008E114]
#: readers / consumers, all in BATH.BIN
BATH_DIR_READ = 0x800804A8            # lw v1,0x14b8(v0)     -> the directory
BATH_BANK_CACHE = [0x8008CFCC, 0x8008CFD0, 0x8008CFD4, 0x8008CFD8]
BATH_CSR_CACHE = 0x8008D0FC           # dir[8] -- BATH calls it "csr_data_steam"
BATH_CSR_DEBUG = 0x8008006C           # "csr_data_steam = %x\n"
BATH_CSR_DEBUG_SITE = 0x800805B8      # addiu $a0,$a0,0x6c
BATH_BANK_SELECT = 0x80081348         # lbu v1,0x3d(s0) -- bank byte
BATH_BANK_LOAD = 0x8008135C           # at = 0x8008CFCC + bank*4
BATH_CSR_LOAD = 0x8008095C            # dir[8][ [0x8008D104]+4 ] -> [0x80088114]
BATH_RECT_USE = 0x800813FC            # lw v0,0x4(s0); sll v0,v0,3 -> rect table
BATH_BANK_PALETTE = 0x8008D114
BATH_STATE = 0x8008D104               # malloc(0x718) state; +4 = file index

# VRAM geometry: each RECT is w=0x40 halfwords (128 bytes) x h=0x80 rows.
BATH_PAGE_W = 128                     # 8bpp pixels
BATH_PAGE_H = 128
BATH_SHEET_W = 384                    # 3 columns x 2 rows
BATH_SHEET_H = 256

# ---------------------------------------------------------------------------
# (b) STONE
# ---------------------------------------------------------------------------
STONE_FILES = [f"STONE_{i:02X}.BIN" for i in range(18)]
STONE_OVERLAY = "DATA/03_SHIRO/STONE.BIN"
STONE_BASE = 0x80080000
STONE_RECT_TABLE = 0x80084CDC         # 16 x (x,y,w,h) u16 -- LoadImage rects
STONE_LOOKUP = 0x80080F54             # stone_lookup_step
STONE_WRAP = 0x80083D98               # stone_loadimage_wrap_a: rect w=0x40,h=0x80
STONE_LOADIMAGE_RECT = (0x240, 0x100, 0x40, 0x80)
STONE_DECODE_DST = 0x80091A44
STONE_PAGE_INDEX = 0x80084BC0         # (record_index, ?) byte pairs, by state 0x2D
STONE_FONT_A = 0x80085A0C             # 4bpp 128x128 kanji page (verified legible)
STONE_FONT_B = 0x80087A0C
STONE_CLUT16 = 0x8008DA0C             # 16-colour CLUT uploaded to VRAM (0x140,0x180)
STONE_STR_TABLE = 0x80085848          # 113 x u32 -> zero-terminated glyph-code strings
STONE_STR_POOL = 0x8008562C           # the 536-byte pool those pointers share
STONE_GRID = 0x80081D74               # stone_texpage_grid: one 8x12 quad per code
STONE_TILE_HELPER = 0x800824A0        # code byte -> (u,v)
STONE_DIR_READ = 0x800802BC           # lw a0,0x14b8(v1)
STONE_FACE_CACHE = 0x800A1EFC         # dir[2] -- the FACE list, == stone_lookup_step's table
STONE_PAGE_CACHE = 0x8008DA3C         # dir[1] -- the STONE page list
STONE_PAGE_LOAD = 0x800805E8          # loader(dir[1][idx], 0x8009DA44)
STONE_NAME_TABLE = 0x80085220         # 108 x u32 -> the short names, tablet order
#: (portrait_index | quadrant, mode) byte pairs indexed by the state byte 0x2D
STONE_ID_TABLE = 0x80084BC0
STONE_ID_ENTRIES = 142

#: the STONE page upload: `stone_loadimage_wrap_a` with w=0x40, h=0x80
#: (`ori $v0,$zero,0x40` @0x80083DB0 and `ori $v0,$zero,0x80` @0x80083DB8), so
#: the file maps at 0x80080000 with **no file header** (`lui 0x8008; addiu
#: 0x4CDC` at 0x8008070C hits the rect table on disc).
STONE_LOADIMAGE_DST = (0x240, 0x100)
#: the state struct the loader fills: `sw $v0,-0x25d4($at)` @0x800802B8 with
#: `lui $at,0x800A` -> 0x800A1F1C.  +0x04 is the file index (0..17), +0x00 the
#: per-frame status the page-load loop sets to 1 and clears to 0 at 18/18.
STONE_STATE = 0x800A1F1C
STONE_STATE_INDEX = 0x04
STONE_PAGE_COUNT = 18
#: the page loop: index -> table[i] record -> loader(vtable+0x10), decode
#: (vtable+0x84) and rect table[i] (LoadImage, vtable+0x70)
STONE_PAGE_LOAD_LOOP = 0x800806B4
#: the draw-entry gate: `lbu $v0,0x2d($s0); sltiu $v0,$v0,0x24` -> font A,
#: else font B (both in-file pages at 0x80085A0C / 0x80087A0C)
STONE_FONT_PICK = 0x80081FCC
#: the second half of the tablet's quad emitter: `jal 0x800824A0` (code -> u,v)
#: then 20-byte textured quads with `sh $v0,0x16($s0)` = the CLUT word from
#: `gpu_texpage_word_build` (vtable+0x8C) with VRAM (0x140, 0x180)
STONE_GRID_LO = 0x80081E28
STONE_GRID_HI = 0x800821B8
#: one big tablet quad, `POLY_FT4` (tag 9 = 0x2C) sampling the 4bpp page at
#: VRAM (0x380, 0) with the 16-colour CLUT at (0, 0x1FF)
STONE_QUAD_FT4 = 0x80081988
#: the second byte of each state pair is a nibble added to state[0x2F] and
#: used as the low nibble of a CLUT word: `lbu 0x2f` + `lbu table[0x2d*2+1]`,
#: `andi 0xf`, `addiu 0xa1, 0x1ea` -> `gpu_texpage_word_build(0, 0x1EA..0x1F9)`
STONE_MODE_READ = 0x80083390        # lbu $a1,0x0($at), at = 0x80084BC1 + 2*0x2D
STONE_MODE_ADD = 0x8008339C         # lbu $v0,0x2f($s2)
STONE_MODE_MASK = 0x800833B0        # andi $a1,$a1,0xf
STONE_MODE_BIAS = 0x800833B8        # addiu $a1,$a1,0x1ea
#: 16 x (x, y, w, h) u16 -- a second, x-referenced rect run (the LoadImage of a
#: page at file i+4); NOT read by any instruction in the overlay
STONE_RECT_TABLE2 = 0x80084D0C

#: the probe: (label, decoder) -- every decoder returns a 2-D index plane
def _stone_layouts(a):
    """Candidate layouts of one 16,384 B page.  `a` is a uint8 numpy array."""
    import numpy as np
    out = {}
    out["8bpp 128x128"] = a.reshape(128, 128)
    out["8bpp 64x256"] = a.reshape(64, 256)
    out["8bpp 256x64"] = a.reshape(256, 64)
    out["4bpp lo-nibble 256x128"] = np.stack([a & 0xF, a >> 4], 1).reshape(128, 256)
    out["4bpp hi-nibble 256x128"] = np.stack([a >> 4, a & 0xF], 1).reshape(128, 256)
    out["16bpp 64x128"] = a.reshape(64, 128, 2)[:, :, 0]
    out["16bpp 128x64"] = a.reshape(128, 64, 2)[:, :, 0]
    bitrev = np.array([int(f"{x:08b}"[::-1], 2) for x in range(256)], np.uint8)
    out["8bpp bit-reversed"] = bitrev[a].reshape(128, 128)
    out["8bpp NOT"] = (~a).reshape(128, 128)
    out["8bpp XOR 0x80"] = (a ^ 0x80).reshape(128, 128)
    m = a.reshape(128, 128).astype(np.int32)
    out["8bpp row-delta"] = (np.cumsum(m, axis=1) & 0xFF)
    out["8bpp col-delta"] = (np.cumsum(m, axis=0) & 0xFF)
    out["8bpp transposed"] = m.T.copy()
    p = a.reshape(4, -1)
    out["2bpp 4-plane"] = ((p[0] & 3) * 64 + (p[1] & 3) * 16
                           + (p[2] & 3) * 4 + (p[3] & 3)).reshape(64, 64)
    p8 = a.reshape(8, -1)
    out["1bpp 8-plane"] = sum(((p8[i] >> 7) & 1) << i for i in range(8)).reshape(32, 64)
    return out


def block_ratio(plane, k=4):
    """var(k x k block means) / (var(pixels)/k^2).

    1.0 = the block means are exactly what i.i.d. pixels would give (no spatial
    structure).  A **constant region inflates this**, which is the trap this
    probe fell into first: `noise + a solid rectangle` scores 9-15 from the
    rectangle alone.  It is therefore always read against the same statistic on
    a fully shuffled copy (see `structure()`), which keeps the marginal
    distribution and destroys contiguity.
    """
    import numpy as np
    m = np.asarray(plane, dtype=float)
    h, w = m.shape
    if h < k or w < k or m.var() == 0:
        return float("nan")
    b = m[: h // k * k, : w // k * k].reshape(h // k, k, w // k, k).mean(axis=(1, 3))
    return float(b.var() / (m.var() / (k * k)))


def structure(plane, k=4, seed=0):
    """`(block_ratio, null_ratio, real/null)` for one candidate image plane.

    The null is the same pixels fully shuffled into the same shape: it keeps the
    marginal distribution and destroys all contiguity, so ~1 means the plane's
    block structure is no more than its own histogram predicts.  Shuffling only
    *within rows* is the wrong null here -- it preserves vertical structure and
    collapses the ratio for genuinely legible pages.
    """
    import numpy as np
    m = np.asarray(plane, dtype=float)
    rs = np.random.RandomState(seed)
    null = rs.permutation(m.ravel()).reshape(m.shape)
    b, n = block_ratio(m, k), block_ratio(null, k)
    return b, n, (b / n if n and not math.isnan(n) else float("nan"))


def nonzero_box(a):
    """`(row0, row1, col0, col1)` of the non-zero bytes -- the data extent.

    Every STONE page is a *variable-size* image zero-padded into the
    16,384-byte upload buffer; the boxes come out 128x128, 128x64, 112x128 or
    112x64.  Sizing the probe to that box is what separates the page's real
    extent from the padding.
    """
    import numpy as np
    m = np.asarray(a, dtype=np.uint8).reshape(128, 128)
    nz = m != 0
    if not nz.any():
        return (0, 0, 0, 0)
    rows = np.where(nz.any(axis=1))[0]
    cols = np.where(nz.any(axis=0))[0]
    return (int(rows.min()), int(rows.max()), int(cols.min()), int(cols.max()))


def lag1_autocorr(a):
    import numpy as np
    f = np.asarray(a, dtype=float).ravel()
    f = f - f.mean()
    d = float((f * f).sum())
    return float((f[:-1] * f[1:]).sum() / d) if d else 0.0


# ---------------------------------------------------------------------------
# (c) the 16-entry load-group directory at 0x8016B358
# ---------------------------------------------------------------------------
MAIN = "MAIN.EXE"
MAIN_BASE = 0x800C0800
MASTER_TABLE = 0x80163D64
MASTER_COUNT = 344
GROUP_DIR = 0x8016B358
GROUP_DIR_SLOT = 0x14B8
GROUP_DIR_INSTALL = 0x800C9650        # sw $v0,0x14b8($v1)
GROUP_COUNT = 16
#: known-by-name anchors, used by the gate to prove the index space is right
GROUP_ANCHORS = {
    1: "STONE_00.BIN",
    3: "PAPER_0.BIN",
    4: "BATH_00.BIN",
    8: "MIZU_00.BIN",
    15: "VC61.BIN",
}

#: the overlays whose reader sites the gate pins (file -> group offsets read)
EXPECTED_READERS = {
    "DATA/03_SHIRO/BATH.BIN": [0x10, 0x14, 0x18, 0x1C, 0x20],
    "DATA/03_SHIRO/BOOKS.BIN": [0x0C],
    "DATA/03_SHIRO/STONE.BIN": [0x04, 0x08],
}


# ===========================================================================
# disc plumbing
# ===========================================================================
def iso() -> list[dict]:
    return disc_iso.iso_records(ISO)


def record(path: str) -> dict:
    return disc_iso.iso_record(path, ISO)


def raw(path: str) -> bytes:
    return disc_iso.extract_path(path, ISO)


def decode_page(path: str) -> bytes:
    """`[u32 filesize-4][LZSS]` -> exactly one page, full input consumption."""
    blob = raw(path)
    head = struct.unpack_from("<I", blob, 0)[0]
    if head != len(blob) - 4:
        raise ValueError(f"{path}: header {head} != filesize-4")
    out, used = lzss.decode_container(blob)
    if used != len(blob):
        raise ValueError(f"{path}: partial decode ({used}/{len(blob)})")
    if len(out) != PAGE_BYTES:
        raise ValueError(f"{path}: {len(out)} B is not one page")
    return out


def main_image() -> bytes:
    return disc_iso.main_image(ISO)


def overlay(path: str) -> tuple[int, bytes]:
    """`(load_base, image)` for a 03_SHIRO overlay.

    These overlays are a pointer header followed by the image; the first word is
    the entry address and the file maps 1:1 from the base, which is the DATA
    region `0x80080000` for every `03_SHIRO` overlay (checked by resolving the
    file's own absolute table references, e.g. BATH's `[0x80085870]`).
    """
    d = raw(path)
    w0 = struct.unpack_from("<I", d, 0)[0]
    base = 0x80080000 if 0x80080000 <= w0 < 0x800A0000 else 0x80010000
    return base, d


def overlay_word(path: str, addr: int) -> int:
    base, d = overlay(path)
    off = addr - base
    if not (0 <= off + 4 <= len(d)):
        raise ValueError(f"{path}: {addr:#x} is outside the image")
    return struct.unpack_from("<I", d, off)[0]


# ===========================================================================
# (a) BATH
# ===========================================================================
def bath_rects() -> list[tuple[int, int, int, int]]:
    base, d = overlay(BATH_OVERLAY)
    off = BATH_RECT_TABLE - base
    return [struct.unpack_from("<4H", d, off + 8 * i) for i in range(6)]


def bath_clut_table() -> list[int]:
    base, d = overlay(BATH_OVERLAY)
    off = BATH_CLUT_TABLE - base
    return list(struct.unpack_from("<4I", d, off))


def bath_palette(bank: int) -> list[int]:
    base, d = overlay(BATH_OVERLAY)
    off = BATH_CLUT_DATA + bank * CLUT_BYTES - base
    if not (0 <= off + CLUT_BYTES <= len(d)):
        raise ValueError(f"BATH palette {bank} lies outside the overlay")
    return list(struct.unpack_from("<256H", d, off))


def bath_report() -> dict:
    rects = bath_rects()
    pal_tbl = bath_clut_table()
    _base, d = overlay(BATH_OVERLAY)
    banks = []
    for b in range(4):
        addr = BATH_CLUT_DATA + b * CLUT_BYTES
        off = addr - BATH_BASE
        in_file = 0 <= off + CLUT_BYTES <= len(d)
        pal = bath_palette(b) if in_file else []
        banks.append({
            "bank": b,
            "files": [f"{BATH_DIR}/{n}" for n in BATH_BANK_FILES[b]],
            "palette_addr": addr,
            "palette_in_file": in_file,
            "palette_distinct": len(set(pal)) if pal else 0,
            "palette_first": pal[:4],
        })
    return {
        "page_bytes": PAGE_BYTES,
        "page_shape": [BATH_PAGE_W, BATH_PAGE_H, "8bpp"],
        "rect_table": BATH_RECT_TABLE,
        "rects": [list(r) for r in rects],
        "sheet": [BATH_SHEET_W, BATH_SHEET_H],
        "clut_table": BATH_CLUT_TABLE,
        "clut_table_values": pal_tbl,
        "banks": banks,
        "clut_source_outside_file": not any(b["palette_in_file"] for b in banks),
        "clut_implied_extent": max(BATH_CLUT_DATA + 4 * CLUT_BYTES,
                                   max((b["palette_addr"] for b in banks), default=0)),
        "bath_file_len": len(d),
        "extra_cluts": BATH_EXTRA_CLUTS,
        "bank_select_addr": BATH_BANK_SELECT,
        "rect_use_addr": BATH_RECT_USE,
        "dir_read_addr": BATH_DIR_READ,
        "csr_cache": BATH_CSR_CACHE,
        "csr_debug_string": "csr_data_steam = %x",
        "csr_debug_addr": BATH_CSR_DEBUG,
        "csr_load_addr": BATH_CSR_LOAD,
    }


def bath_render(outdir: str) -> list[str]:
    """Compose each bank's 3x2 sheet with a palette **read from the overlay**.

    NOTE: the four palette addresses the overlay's own table holds
    (`0x8008D114 + 0x200*b`) lie beyond `BATH.BIN`'s file extent, so no palette
    on this path is disc-derived; see `bath_report()["clut_source_outside_file"]`.
    This routine therefore renders with the *bytes at that file offset when
    they exist*, and refuses to guess otherwise.
    """
    from PIL import Image
    import numpy as np

    os.makedirs(outdir, exist_ok=True)
    rects = bath_rects()
    _base, d = overlay(BATH_OVERLAY)
    written = []
    for b in range(4):
        off = BATH_CLUT_DATA + b * CLUT_BYTES - BATH_BASE
        if not (0 <= off + CLUT_BYTES <= len(d)):
            raise ValueError(
                f"BATH palette {b} at 0x{BATH_CLUT_DATA + b * CLUT_BYTES:08X} is "
                f"outside BATH.BIN ({len(d)} B); it is written at runtime, so no "
                f"disc-derived palette exists for this bank")
        lut = np.array([rgb555(w) for w in bath_palette(b)], dtype=np.uint8)
        canvas = np.zeros((BATH_SHEET_H, BATH_SHEET_W, 3), dtype=np.uint8)
        for i, name in enumerate(BATH_BANK_FILES[b]):
            page = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"),
                                 dtype=np.uint8).reshape(BATH_PAGE_H, BATH_PAGE_W)
            x, y, _w, _h = rects[i]
            col = (x - rects[0][0]) // 0x40
            row = (y - rects[0][1]) // 0x80
            canvas[row * BATH_PAGE_H:(row + 1) * BATH_PAGE_H,
                   col * BATH_PAGE_W:(col + 1) * BATH_PAGE_W] = lut[page]
        p = os.path.join(outdir, f"bath_bank{b}_sheet.png")
        Image.fromarray(canvas).resize((BATH_SHEET_W * 2, BATH_SHEET_H * 2),
                                       Image.NEAREST).save(p)
        written.append(p)
    return written


# ===========================================================================
# (b) STONE
# ===========================================================================
def stone_rects() -> list[tuple[int, int, int, int]]:
    base, d = overlay(STONE_OVERLAY)
    off = STONE_RECT_TABLE - base
    return [struct.unpack_from("<4H", d, off + 8 * i) for i in range(18)]


def stone_probe() -> dict:
    """Structure statistics for the 18 STONE pages and for the siblings.

    Numeric index-space statistics do not establish the structure of the
    coloured raster. Use stone_composite.py for the traced palette lookup.
    """
    import numpy as np

    def stats(name: str) -> dict:
        a = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        r0, r1, c0, c1 = nonzero_box(a)
        box = a.reshape(128, 128)[r0:r1 + 1, c0:c1 + 1]
        b, n, rel = structure(box, 4)
        fb, fn, frel = structure(a.reshape(128, 128), 4)
        return {
            "file": name,
            "bytes": len(a),
            "distinct": int(len(np.unique(a))),
            "zero_frac": round(float((a == 0).mean()), 4),
            "box": [r0, r1, c0, c1],
            "lag1": round(lag1_autocorr(a), 4),
            # inside the page's own non-zero extent, against a shuffled null
            "box_blocks": round(rel, 3),
            # the whole padded buffer, for contrast (padding inflates this)
            "full_blocks": round(frel, 3),
            "full_ratio": round(fb, 2),
            "full_null": round(fn, 2),
        }

    stone = [stats(n) for n in STONE_FILES]
    siblings = [stats(n) for n in (
        "BATH_00.BIN", "BATH_10.BIN", "FACE_01.BIN", "BOOK_0.BIN",
        "CURIO_0.BIN", "MIZU_00.BIN", "HANA.BIN", "YUGE_00.BIN",
        "PAPER_0.BIN", "PAPER_2.BIN")]

    # the layout sweep, on three representative pages
    layouts = {}
    for name in ("STONE_00.BIN", "STONE_06.BIN", "STONE_0D.BIN"):
        a = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        layouts[name] = {k: round(structure(v, 4)[2], 3)
                         for k, v in _stone_layouts(a).items()}
        # chunk interleaves: split the page into k consecutive chunks and read
        # them round-robin (a common "loader-friendly" scramble)
        for k in (2, 4, 8, 16, 32, 64, 128, 256, 512):
            t = a.reshape(k, -1).T.ravel()
            layouts[name][f"chunk-interleave k={k}"] = round(
                structure(t.reshape(128, 128), 4)[2], 3)
    return {
        "stone": stone,
        "siblings": siblings,
        "layouts": layouts,
        "rects": [list(r) for r in stone_rects()],
        "loadimage_rect": list(STONE_LOADIMAGE_RECT),
        "lookup_addr": STONE_LOOKUP,
        "wrap_addr": STONE_WRAP,
        "decode_dst": STONE_DECODE_DST,
        "str_table": STONE_STR_TABLE,
        "str_pool": STONE_STR_POOL,
        "str_entries": (STONE_FONT_A - STONE_STR_TABLE) // 4,
        "font_a": STONE_FONT_A,
        "font_b": STONE_FONT_B,
        "clut16": STONE_CLUT16,
    }


def stone_code_strings() -> list[list[int]]:
    """The overlay's own glyph-code strings -- the tablet's text source.

    `stone_texpage_grid @0x80081D74` reads `table[a0 & 0xFF]` at `0x80085848`
    and walks the zero-terminated byte string it points at, emitting one 8x12
    quad per code (code `0x10` is special, `0x00` ends).  The table runs from
    `0x80085848` up to the font page at `0x80085A0C` = **113 entries**, whose
    pointers share a 536-byte pool at `0x8008562C`.  None of this comes from the
    loadable `STONE_nn` pages.
    """
    base, d = overlay(STONE_OVERLAY)
    out = []
    for i in range((STONE_FONT_A - STONE_STR_TABLE) // 4):
        p = struct.unpack_from("<I", d, STONE_STR_TABLE - base + 4 * i)[0]
        if not (base <= p < base + len(d)):
            break
        s, o = [], p - base
        while o < len(d) and d[o]:
            s.append(d[o])
            o += 1
        out.append(s)
    return out


def stone_table() -> dict:
    """The state -> portrait table at `0x80084BC0`, and the alignment proof.

    `stone_lookup_step` does `idx = byte_table[state*2]; idx &= 0x1FC;`
    `record = dir[2][idx/4]` -- so the first byte of each pair is a
    four-byte-aligned index into the **FACE** group (27 pages of four 64x64
    portraits each), and its low two bits are the quadrant the loader drops.  The
    first 108 entries are therefore a permutation of 0..107 -- and they align
    108/108 with `STONE.BIN 0x5220`'s short names against MAIN's portrait-order
    names at exactly that index.  The `0x4B40` permutation the corpus chased does
    **not** (0/108 index-wise).
    """
    base, d = overlay(STONE_OVERLAY)
    pairs = [(d[STONE_ID_TABLE - base + 2 * i], d[STONE_ID_TABLE - base + 2 * i + 1])
             for i in range(STONE_ID_ENTRIES)]
    first = [a for a, _b in pairs]

    import face_portraits as fp
    main = fp.character_names()
    stone_names = [e["name"] for e in fp.names()]

    aligned, mismatches = 0, []
    for k, p in enumerate(first[:108]):
        s = stone_names[k]
        m = main[p] if p < len(main) else None
        if k == 0 or (m and (m.startswith(s) or m.endswith(s))):
            aligned += 1
        else:
            mismatches.append({"state": k, "stone": s, "portrait": p, "main": m})

    perm = list(d[0x4B40:0x4B40 + 108])
    indexwise = sum(1 for k in range(108)
                    if main[k] and (main[k].startswith(stone_names[k])
                                    or main[k].endswith(stone_names[k])))
    return {
        "table": STONE_ID_TABLE,
        "entries": STONE_ID_ENTRIES,
        "first_108_is_permutation": sorted(first[:108]) == list(range(108)),
        "portrait_of_state": first,
        "mode_of_state": [b for _a, b in pairs],
        "mode_range": [min(b for _a, b in pairs), max(b for _a, b in pairs)],
        "aligned": aligned,
        "mismatches": mismatches,
        "viktor_state": 12,
        "viktor_portrait": first[12],
        "viktor_main_name": main[first[12]],
        "order_4b40_indexwise": indexwise,
        "lookup_masks_index_with": "0x1FC (byte & 0xFC) -> dir[2] record",
    }


# ===========================================================================
# (c) the load-group directory
# ===========================================================================
def load_groups() -> list[dict]:
    img = main_image()
    by_lba = {r["lba"]: r["path"] for r in iso()}

    def path_for(ptr: int):
        if not (MASTER_TABLE <= ptr < MASTER_TABLE + MASTER_COUNT * 8):
            return None
        _size, lba = struct.unpack_from("<II", img, ptr - MAIN_BASE)
        return by_lba.get(lba)

    groups = []
    for i in range(GROUP_COUNT):
        g = struct.unpack_from("<I", img, GROUP_DIR - MAIN_BASE + 4 * i)[0]
        files, o = [], g - MAIN_BASE
        for k in range(64):
            v = struct.unpack_from("<I", img, o + 4 * k)[0]
            p = path_for(v)
            if p is None:
                break
            files.append(p)
        groups.append({"index": i, "group_addr": g, "files": files})
    return groups


def binary_image(path: str) -> tuple[int, bytes]:
    """`(load_base, body)` for any code binary on the disc."""
    blob = raw(path)
    b = os.path.basename(path)
    if b == MAIN:
        return MAIN_BASE, blob[2048:]
    if b.startswith("SLUS"):
        return struct.unpack_from("<I", blob, 0x18)[0], blob[2048:]
    w0 = struct.unpack_from("<I", blob, 0)[0]
    return (0x80080000 if 0x80080000 <= w0 < 0x800A0000 else 0x80010000), blob


def _writes_rt(w: int, rt: int) -> bool:
    """Does this instruction overwrite `$rt` (the register holding the base)?

    Conservative: stores (0x28-0x2B) and branches do not, and R-type
    instructions write `rd` in bits 15-11 (except the ones that write hi/lo or
    nothing).  A missed clobber can only add a false group offset, so the R-type
    cases are filtered properly rather than ignored.
    """
    op = w >> 26
    if op == 0:
        fn = w & 0x3F
        if fn in (0x08, 0x0C, 0x0D, 0x18, 0x19, 0x1A, 0x1B):
            return False                    # jr / syscall / break / mult / div
        return ((w >> 11) & 0x1F) == rt
    if op in set(range(0x08, 0x10)) or op in set(range(0x20, 0x27)) \
            or op in set(range(0x30, 0x34)):
        return ((w >> 16) & 0x1F) == rt
    return False


def bath_draw_trace() -> dict:
    """The page loop's *destination* side: LoadImage, not a sampling draw.

    `BATH.BIN 0x80081348..0x8008148C` is the per-page step of the bank load:

        0x80081348  lbu  $v1,0x3d($s0)     ; the bank byte -> a DIRECTORY GROUP
        0x80081358  sll  $v1,$v1,2
        0x80081360  addiu $at,$at,-0x3034  ; 0x8008CFCC = read_dt_tbl[0]
        0x80081368  lw   $v1,0($at)        ; read_dt_tbl[bank] = dir[4+bank]
        0x80081374  addu $v0,$v0,$v1       ; [state+4] = the file index
        0x8008138C  jalr vtable+0x10       ; loader(dir[4+bank][idx], [0x80088114])
        ...
        0x800813FC  lw   $v0,0x4($s0)      ; the same file index
        0x80081408  sll  $v0,$v0,3
        0x80081420  addiu $at,$at,0x5884   ; the RECT table
        0x80081470  jalr vtable+0x70       ; LoadImage(rect[idx], page)

    So the bank byte does **not** select a draw and does not appear in any
    texture-page or CLUT word in the overlay: it selects which directory group
    (4..7 = `BATH_00..05` / `10..15` / `20..25` / `30..35`) supplies the six
    pages.  What each bank depicts is then a property of the disc pages
    themselves, which is why the tool reports the per-bank page list and does
    not name a room.
    """
    base, d = overlay(BATH_OVERLAY)

    def w(a):
        return struct.unpack_from("<I", d, a - base)[0]

    return {
        "bank_select": BATH_BANK_SELECT,
        "w_bank": w(BATH_BANK_SELECT),
        "group_table": BATH_BANK_CACHE[0],
        "group_read": 0x80081368,
        "loader_call": 0x8008138C,
        "loadimage_rect_read": 0x8008141C,
        "loadimage_call": 0x80081470,
        "rect_table": BATH_RECT_TABLE,
        "rect_use": BATH_RECT_USE,
        "w_rect_use": w(BATH_RECT_USE),
        "page_counter": 0x80081478,      # addiu $v0,$v0,0x1 ; slti 6
        "loop_bound": 6,
        #: the OTHER two `lbu $v0,0x3d($s0)` sites: the page counter (0x80081308)
        #: and the per-bank BGM id (`lh` from the table at 0x800858D4, then
        #: vtable+0xAC = the SE/BGM player 0x800C3104)
        "bank_read_sites": [0x80081308, 0x80081348, 0x800814C4],
        "bank_sound_table": 0x800858D4,
        "bank_sound_ids": [0x434, 0x434, 0x435, 0x436],
        "bank_sound_slot": 0xAC,
        "bank_sound_player": 0x800C3104,
        "bank_cycle": 4,
        "banks": [{"bank": b, "group": 4 + b,
                   "files": list(BATH_BANK_FILES[b])} for b in range(4)],
        "status": "bank -> directory group AND bank -> BGM id proven; the "
                  "bank -> ROOM assignment is a content fact of the four page "
                  "sets and is not derivable from the code",
    }


def stone_page_load() -> dict:
    """The instruction-level trace of the page loop, and what it does *not* feed.

    `stone_resource_init` runs this loop once per page (`slti 0x12` = 18):

        0x800806B4  lw   $v0,0x1bc4($v0)      ; the vtable
        0x800806C0  lw   $a0,0($a1)           ; dir[1][idx]  (the file record)
        0x800806CC  lw   $v0,0x84($v0)        ; vtable+0x84 = decode
        0x800806D0  lui  $a2,0x8009
        0x800806D4  addiu $a2,$a2,0x1a44      ; decode destination
        0x800806E4  lw   $v0,0x1f1c($v0)      ; the state struct
        0x800806F8  lw   $v0,0x4($v0)         ; file index (0..17)
        0x800806F8  sll  $v0,$v0,3            ; 8 bytes per rect record
        0x80080708  lwl  $a0,0x4cdf($at)      ; rect w|h  (un-aligned halfword read)
        0x80080718  lwr  $a0,0x4cdc($at)      ; rect x|y
        0x80080728  lwl  $a1,0x4ce3($at)
        0x80080738  lwr  $a1,0x4ce0($at)
        0x80080754  lw   $v0,0x70($v0)        ; vtable+0x70 = LoadImage
        0x80080760  jalr $v0

    16 bytes each):
    So the page is **read-only** in this path: it lands on the disc-declared
    `[u32 filesize-4][LZSS]` container, decodes to one 16,384 B buffer, and the
    buffer is LoadImage'd to RECT *i* of `0x80084CDC`.  The only in-file
    consumer of `0x80084CDC` is the `addiu $at,0x4CDC` half of one of those two
    halfword loads (`0x8008070C`; its sibling is built as `0x4CDF` at
    `0x80080700`), so nothing else in the overlay reads the table, let alone
    samples what it uploads.
    """
    base, d = overlay(STONE_OVERLAY)

    def w(a):
        return struct.unpack_from("<I", d, a - base)[0]

    return {
        "loop_head": STONE_PAGE_LOAD_LOOP,
        "loop_count": STONE_PAGE_COUNT,
        "state": STONE_STATE,
        "state_index_off": STONE_STATE_INDEX,
        "w_load_state": w(0x800806E4),
        "w_load_index": w(0x800806F8),
        "w_sll3": w(0x800806F8),
        "loadimage_slot": 0x70,
        "decode_slot": 0x84,
        "vtable_addr": 0x80165608,
        "rect_table": STONE_RECT_TABLE,
        "rect_table2": STONE_RECT_TABLE2,
        "rect_table_readers": [0x8008070C],
        "rect_table2_readers": [],
        "wrap_w": w(0x80083DB0),
        "wrap_h": w(0x80083DB8),
        "loadimage_dst": list(STONE_LOADIMAGE_DST),
        "caller_rect": [0x80081024, 0x8008102C],
    }


def stone_draw_trace() -> dict:
    """What samples VRAM `(0x240,0x100)`: the answer, and the negative.

    Two draws in `STONE.BIN` reference the rect family, both at the
    `x0 = 0x2C0 / y = 0x40` end of it, and neither is `(0x240,0x100)`:

    * `0x80081418..0x80081470` (this is **BATH.BIN**, not STONE -- see
      `bath_draw_trace()`) loads `rects[[state+4]*8]` and issues LoadImage.
    * `STONE.BIN 0x800833D8` issues `LoadImage(1, 0, 0x240, 0x100)` -- i.e. the
      **opposite** direction (it is a *store* into that VRAM region from the
      pointer table at `0x80085584`, a glyph-string table).

    The STONE_nn pages are therefore written to `(0x240,0x100)+` and nothing in
    the overlay reads that VRAM region back as a texture: the overlay's own quad
    emitters take their CLUT word from `gpu_texpage_word_build` (vtable+0x8C,
    `(a1<<6)|((a0>>4)&0x3F)`) at `(0x140,0x180)` / `(0,0x1EA..0x1F9)` /
    `(0x140,0x1FF)`, and their texpage comes from the engine's draw-state field
    (`lw ...,0x780(...)`), never from a rect-table byte.

    The negative is recorded, not asserted as a refutation: the draw could live
    in another overlay via the same `vtable[0x1BC4]` indirection.
    """
    base, d = overlay(STONE_OVERLAY)

    def w(a):
        return struct.unpack_from("<I", d, a - base)[0]

    return {
        "loadimage_into_region": {
            "site": 0x800833D8,
            "w_a2": w(0x800833D8),          # ori $a2,$zero,0x240
            "w_a3": w(0x800833E0),          # ori $a3,$zero,0x100
            "note": "LoadImage(1, 0, 0x240, 0x100) -- a write, not a sample",
        },
        "quad_emitters": {
            "grid": [STONE_GRID_LO, STONE_GRID_HI],
            "grid_clut_call": 0x80081E94,   # gpu_texpage_word_build(a0=?, a1=0x180)
            "grid_clut_a1": 0x180,
            "grid_clut_table_args": w(0x80081E94),
            "clut_builder": 0x8014ABD4,
            "clut_builder_formula": "(a1<<6)|((a0>>4)&0x3F)",
            #: the emitter's own stores: `ori $v0,9; sb $v0,0x3($s0)` and
            #: `ori $v0,0x2c; sb $v0,0x7($s0)` @0x800819C8/0x800819CC
            "ft4": STONE_QUAD_FT4,
            "ft4_tag": 9,
            "ft4_size": 0x2C,
            "ft4_page_arg": 0x380,
            "ft4_clut_call": 0x80081A1C,
            "ft4_clut_arg": 0x1FF,
        },
        "fonts": {
            "pick": STONE_FONT_PICK,
            "w_threshold": w(0x80081FD4),   # sltiu $v0,$v0,0x24
            "font_a": STONE_FONT_A,
            "font_b": STONE_FONT_B,
            "loadimage": [0x80080478, 0x800804B0],
        },
        "tpage_samples_of_240_100": [],
        "status": "superseded by kit/tools/q_stone.py: 0x800833D4 loads "
                  "GetTpage (vtable+0x6C), its 0x240/0x100 arguments are the "
                  "page, and the 18-rect table at 0x80084CDC is read as data "
                  "by the 20-byte page table at 0x80084D6C via 0x80081334",
    }


def stone_second_byte() -> dict:
    """The second byte of each of the 142 state pairs at `0x80084BC0`.

    It is the **tablet name's CLUT selector nibble**, combined with the state
    byte `0x2F`:

        0x80083378  lbu  $v0,0x2d($s2)     ; the state byte
        0x80083380  sll  $v0,$v0,1
        0x80083388  addiu $at,$at,0x4bc1   ; base + 2*state + 1
        0x80083390  lbu  $a1,0x0($at)      ; <-- the SECOND byte of the pair
        0x8008339C  lbu  $v0,0x2f($s2)     ; a per-frame counter, zeroed at init
        0x800833A8  addu $a1,$a1,$v0
        0x800833B0  andi $a1,$a1,0xf
        0x800833B8  addiu $a1,$a1,0x1ea
        0x800833AC  lw   $v0,0x8c($v1)     ; gpu_texpage_word_build
        0x800833B4  jalr $v0               ; -> CLUT word (a1<<6)|(a0>>4 & 0x3F)

    `a0` is zero at the call sites, so the word is `(0x1EA+n)<<6` with
    `n = (byte2 + state[0x2F]) & 0xF` -- a CLUT at VRAM `(0, 0x1EA..0x1F9)`.
    Measured on the 142 pairs the raw values are `{0:51, 1:21, 2:24, 3:4, 4:3,
    5:3, 6:2, 7:10, 8:20}` plus **three out-of-band rows** (0x80 at states
    13 and 28, 0xA0 at state 22) whose low nibble is what the code actually
    uses.  The recorded "0..8" range is right for the in-band rows and misses
    those three.
    """
    base, d = overlay(STONE_OVERLAY)
    pairs = [(d[STONE_ID_TABLE - base + 2 * i],
              d[STONE_ID_TABLE - base + 2 * i + 1])
             for i in range(STONE_ID_ENTRIES)]
    modes = [b for _a, b in pairs]
    return {
        "table": STONE_ID_TABLE,
        "read_site": STONE_MODE_READ,
        "read_bytes": [d[STONE_MODE_READ - base + k] for k in range(4)],
        "w_read": struct.unpack_from("<I", d, STONE_MODE_READ - base)[0],
        "w_add": struct.unpack_from("<I", d, STONE_MODE_ADD - base)[0],
        "w_mask": struct.unpack_from("<I", d, STONE_MODE_MASK - base)[0],
        "w_bias": struct.unpack_from("<I", d, STONE_MODE_BIAS - base)[0],
        "state_2f_writer": 0x80080E3C,          # sb $zero,0x2f($s0)
        "clut_indices": modes,
        "in_band": sorted({b for b in modes if b <= 8}),
        "out_of_band": [{"state": i, "byte": b} for i, b in enumerate(modes)
                        if b > 8],
        "clut_vram_range": [0x1EA, 0x1F9],
        "clut_word_base": 0x1EA << 6,
    }


PAPER_PROBE_FILES = (f"PAPER_{i}.BIN" for i in range(6))
#: siblings the same container+decoder produces; a legible page scores >= 8
STONE_LEGIBLE_SIBLINGS = ("BATH_00.BIN", "BATH_10.BIN", "FACE_01.BIN",
                          "BOOK_0.BIN", "CURIO_0.BIN", "MIZU_00.BIN",
                          "HANA.BIN", "YUGE_00.BIN", "PAPER_2.BIN")


def paper_probe() -> dict:
    """`PAPER_0`/`PAPER_1` against the rest of their own family.

    Same container, same decoder, same 16,384 B page size; the only difference
    is the null-calibrated 4x4 block ratio inside the page (no zero padding
    here -- all six PAPER pages are dense, zero-fraction 0.000).  `PAPER_0` and
    `PAPER_1` land in the `STONE_nn` band (~1.3) while `PAPER_2..5` and every
    other sibling land at 10-14, so the two are **the same open question as
    `STONE_nn`, in the same directory**, not a separate format.
    """
    import numpy as np

    out = []
    for name in list(PAPER_PROBE_FILES):
        a = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        rel = structure(a.reshape(128, 128), 4)[2]
        out.append({
            "file": name,
            "rel": round(rel, 3),
            "zero_frac": round(float((a == 0).mean()), 4),
            "distinct": int(len(np.unique(a))),
            "lag1": round(lag1_autocorr(a), 4),
            "class": "no-structure (STONE-like)" if rel < 4 else "legible page",
        })
    stone = []
    for name in STONE_FILES:
        a = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        r0, r1, c0, c1 = nonzero_box(a)
        box = a.reshape(128, 128)[r0:r1 + 1, c0:c1 + 1]
        stone.append(round(structure(box, 4)[2], 3))
    sib = {}
    for name in STONE_LEGIBLE_SIBLINGS:
        a = np.frombuffer(decode_page(f"{BATH_DIR}/{name}"), dtype=np.uint8)
        r0, r1, c0, c1 = nonzero_box(a)
        box = a.reshape(128, 128)[r0:r1 + 1, c0:c1 + 1]
        sib[name] = round(structure(box, 4)[2], 3)
    return {"paper": out, "stone_rel": stone, "siblings": sib,
            "paper_no_structure": [e["file"] for e in out if e["rel"] < 4]}


def dir_readers() -> list[dict]:
    """Every site that loads the directory pointer, and the groups it selects.

    Finds `lw $rt, 0x14b8($rs)` -- the only access form any of the six known
    readers uses -- and then every `lw $rx, imm($rt)` with a small aligned
    immediate, since the directory is an array of pointers (offset = 4*group).
    The walk stops when `$rt` is overwritten, which is what keeps the later
    `lw $a0,0($v0)` of an indexed group list from reading as "group 0".  A list
    that an `addu` then indexes with a register is flagged `computed_index`.
    """
    out = []
    for r in iso():
        b = os.path.basename(r["path"])
        if not (b.endswith(".BIN") or b.endswith(".EXE") or b.startswith("SLUS")):
            continue
        if r["size"] < 0x800 or r["size"] > 1_600_000:
            continue
        try:
            base, d = binary_image(r["path"])
        except Exception:
            continue
        n = len(d) // 4
        for i in range(n):
            w = struct.unpack_from("<I", d, i * 4)[0]
            if (w >> 26) != 0x23 or (w & 0xFFFF) != GROUP_DIR_SLOT:
                continue
            rt = (w >> 16) & 0x1F
            offs, computed, list_reg = [], False, None
            for j in range(1, 25):
                if i + j >= n:
                    break
                w2 = struct.unpack_from("<I", d, (i + j) * 4)[0]
                op2 = w2 >> 26
                if op2 == 0x23 and ((w2 >> 21) & 0x1F) == rt:
                    im2 = w2 & 0xFFFF
                    if im2 <= 0x3C and im2 % 4 == 0:
                        offs.append(im2)
                        list_reg = (w2 >> 16) & 0x1F
                if op2 == 0 and (w2 & 0x3F) == 0x21 and list_reg is not None:
                    if ((w2 >> 21) & 0x1F) == list_reg \
                            or ((w2 >> 16) & 0x1F) == list_reg:
                        computed = True
                if _writes_rt(w2, rt):
                    break
            if offs or computed:
                out.append({"file": r["path"], "addr": base + i * 4,
                            "group_offsets": offs, "computed_index": computed,
                            "groups": [o // 4 for o in offs]})
    return sorted(out, key=lambda h: (h["file"], h["addr"]))


def owners() -> dict:
    """group index -> the readers that select it, plus the resolution of the
    group's first file name (so the index space is anchored, not assumed)."""
    groups = load_groups()
    readers = dir_readers()
    by_group: dict[int, list[dict]] = {}
    for h in readers:
        for g in h["groups"]:
            by_group.setdefault(g, []).append(
                {"file": h["file"], "addr": h["addr"],
                 "computed_index": h["computed_index"]})
    return {
        "groups": groups,
        "readers": readers,
        "by_group": {str(g): v for g, v in sorted(by_group.items())},
        "unread": [i for i in range(GROUP_COUNT) if i not in by_group],
    }


# ===========================================================================
# CLI
# ===========================================================================
def _fmt_groups(rep: dict) -> None:
    for g in rep["groups"]:
        names = [os.path.basename(p) for p in g["files"]]
        rs = rep["by_group"].get(str(g["index"]), [])
        who = ", ".join(f"{os.path.basename(x['file'])}@{x['addr']:#x}"
                        + (" (computed idx)" if x["computed_index"] else "")
                        for x in rs) or "**no reader found**"
        head = f"[{g['index']:2d}] 0x{g['group_addr']:08X} {len(g['files'])} files"
        print(f"{head}\n     files: {', '.join(names[:6])}"
              + (" ..." if len(names) > 6 else ""))
        print(f"     read by: {who}")
    print(f"groups with no reader found: {rep['unread']}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bath", action="store_true")
    ap.add_argument("--stone", action="store_true")
    ap.add_argument("--groups", action="store_true")
    ap.add_argument("--draw", action="store_true",
                    help="the STONE_nn / BATH upload-and-draw instruction trace")
    ap.add_argument("--paper", action="store_true",
                    help="PAPER_0/PAPER_1 against the rest of their family")
    ap.add_argument("--render", metavar="DIR")
    ap.add_argument("--json", metavar="PATH")
    args = ap.parse_args(argv)

    if args.render:
        for p in bath_render(args.render):
            print("wrote", p)

    if args.bath:
        rep = bath_report()
        print(f"BATH: {len(BATH_BANK_FILES) * 6} files -> "
              f"{rep['page_bytes']} B = {rep['page_shape'][0]}x{rep['page_shape'][1]} "
              f"{rep['page_shape'][2]} pages")
        print(f"  RECT table 0x{rep['rect_table']:08X} (file i -> rect i):")
        for i, r in enumerate(rep["rects"]):
            print(f"    [{i}] x={r[0]:#5x} y={r[1]:#5x} w={r[2]:#5x} h={r[3]:#5x}"
                  f"  -> 128x128 px at sheet ({((r[0]-rep['rects'][0][0])//0x40)*128},"
                  f"{(r[1]-rep['rects'][0][1])//0x80*128})")
        print(f"  sheet = {rep['sheet'][0]}x{rep['sheet'][1]} 8bpp at VRAM "
              f"(x 0x{rep['rects'][0][0]:X}..0x{rep['rects'][2][0]+0x40:X} words, "
              f"y 0..0x{rep['rects'][5][1]+0x80:X})")
        print(f"  CLUT table 0x{rep['clut_table']:08X} = "
              + ", ".join(f"0x{v:08X}" for v in rep["clut_table_values"]))
        print(f"    each target is OUTSIDE BATH.BIN ({rep['bath_file_len']} B): "
              f"clut_source_outside_file={rep['clut_source_outside_file']}, "
              f"implied extent 0x{rep['clut_implied_extent']:08X} -- the palettes "
              f"are written at runtime and are NOT in this file")
        for b in rep["banks"]:
            print(f"    bank {b['bank']}: {b['palette_distinct']} distinct colours "
                  f"@0x{b['palette_addr']:08X} (in file: {b['palette_in_file']})  "
                  f"{', '.join(os.path.basename(x) for x in b['files'][:2])} ...")
        print(f"  bank byte [state+0x3D] @0x{rep['bank_select_addr']:08X}; "
              f"rect indexed by [state+4] @0x{rep['rect_use_addr']:08X}")
        print(f"  group 8 cached at 0x{rep['csr_cache']:08X}, "
              f"named '{rep['csr_debug_string'].strip()}' by 0x{rep['csr_debug_addr']:08X}")

    if args.stone:
        rep = stone_probe()
        print("STONE: 18 pages, each 16,384 B; uploaded to VRAM (0x240,0x100) "
              "64x128 halfwords by stone_loadimage_wrap_a @0x%08X" % STONE_WRAP)
        print("  box = non-zero bounding box (row0-row1, col0-col1); "
              "rel = 4x4 block-ratio excess over the shuffled null INSIDE that "
              "box (>=8 = a legible page, ~1 = noise)")
        print("  page            zeros  box                 lag1    rel")
        for s in rep["stone"]:
            b = s["box"]
            print(f"  {s['file']:14s} {s['zero_frac']:6.3f} "
                  f"{b[0]:3d}-{b[1]:3d},{b[2]:3d}-{b[3]:3d}  {s['lag1']:6.3f} {s['box_blocks']:6.2f}")
        print("  -- legible siblings, same container and same decoder --")
        for s in rep["siblings"]:
            b = s["box"]
            print(f"  {s['file']:14s} {s['zero_frac']:6.3f} "
                  f"{b[0]:3d}-{b[1]:3d},{b[2]:3d}-{b[3]:3d}  {s['lag1']:6.3f} {s['box_blocks']:6.2f}")
        print("  layout sweep (block-ratio excess over the shuffled null; "
              
              "~1 = no structure, >8 = real image):")
        for name, lay in rep["layouts"].items():
            vals = ", ".join(f"{k}={v}" for k, v in sorted(lay.items(),
                                                           key=lambda kv: kv[1]))
            print(f"    {name}: {vals}")
        print("  the tablet's TEXT does not come from these pages: "
              "stone_texpage_grid @0x%08X walks the overlay's own "
              "zero-terminated glyph-code strings (table 0x%08X -> pool 0x%08X), "
              "one 8x12 quad per code, glyphs from the 4bpp pages 0x%08X/0x%08X"
              % (STONE_GRID, STONE_STR_TABLE, STONE_STR_POOL,
                 STONE_FONT_A, STONE_FONT_B))
        strs = stone_code_strings()
        print(f"  {len(strs)} code strings, {sum(len(s) for s in strs)} codes, "
              f"code range {min(c for s in strs for c in s)}"
              f"..{max(c for s in strs for c in s)}")
        print("  first three: " + "; ".join(
            " ".join(f"{c:#04x}" for c in s) for s in strs[:3]))
        t = stone_table()
        print(f"  the state byte 0x2D -> portrait index table @0x{t['table']:08X} "
              f"({t['entries']} pairs; first byte = portrait index | quadrant):")
        print(f"    first 108 first-bytes are a permutation of 0..107: "
              f"{t['first_108_is_permutation']};  state 12 -> {t['viktor_portrait']} "
              f"= {t['viktor_main_name']}")
        print(f"    stone-name 0x80085220 alignment via that table: "
              f"{t['aligned']}/108 (the 0x4B40 order scores "
              f"{t['order_4b40_indexwise']}/108 index-wise)")
        m = stone_second_byte()
        print("  the SECOND byte of each pair is the name's CLUT nibble: "
              f"table[0x2D*2+1] @0x{m['table']:08X}+1 read at 0x{m['read_site']:08X}, "
              f"added to state[0x2F] (zeroed at 0x{m['state_2f_writer']:08X}), "
              f"`andi 0xf` then +0x1EA -> CLUT word (0x1EA..0x1F9)<<6 at VRAM "
              f"(0, 0x{m['clut_vram_range'][0]:X}..0x{m['clut_vram_range'][1]:X})")
        dist = {}
        for b in m["clut_indices"]:
            dist[b] = dist.get(b, 0) + 1
        print("    values: " + ", ".join(f"{k}:{dist[k]}" for k in sorted(dist))
              + f"; out of the recorded 0..8 band: {m['out_of_band']}")
        print("  Index statistics only; coloured sampler: stone_composite.py (user-gated).")

    if args.groups:
        _fmt_groups(owners())

    if args.draw:
        p = stone_page_load()
        print("STONE page load loop @0x%08X (state 0x%08X+%d = the file index, "
              "18 pages):" % (p["loop_head"], p["state"], p["state_index_off"]))
        print("  loader = vtable[0x%02X] (record -> 0x80091A44), decode = "
              "vtable[0x%02X], LoadImage = vtable[0x%02X] with the RECT taken "
              "from 0x%08X + index*8 (readers %s)"
              % (p["loadimage_slot"] - 4, p["decode_slot"],
                 p["loadimage_slot"], p["rect_table"],
                 ", ".join(f"0x{a:08X}" for a in p["rect_table_readers"])))
        print("  stone_loadimage_wrap_a @0x%08X builds w=%#x h=%#x; the caller at "
              "0x%08X passes (%#x, %#x), the FACE path's hard-coded destination. "
              "That rect appears in NEITHER 16-entry run (its byte pattern is "
              "not in the file at all), so it is call-site data, not table data"
              % (STONE_WRAP, p["wrap_w"] & 0xFFFF, p["wrap_h"] & 0xFFFF,
                 p["caller_rect"][0],
                 p["loadimage_dst"][0], p["loadimage_dst"][1]))
        print("  rect table 2 @0x%08X (16 more rects, stride 8): readers %s"
              % (p["rect_table2"], p["rect_table2_readers"] or "NONE"))
        t = stone_draw_trace()
        print("  what SAMPLES VRAM (0x240,0x100): %s" % t["status"])
        print("    only in-file reference to the region is a WRITE: LoadImage "
              "(site 0x%08X, a2=%#x a3=%#x)"
              % (t["loadimage_into_region"]["site"],
                 t["loadimage_into_region"]["w_a2"] & 0xFFFF,
                 t["loadimage_into_region"]["w_a3"] & 0xFFFF))
        q = t["quad_emitters"]
        print("    the tablet's own quads use vtable+0x8C %s = %s, CLUT base "
              "(0x140,0x%X); its POLY_FT4 (tag %d, size 0x%X) is loaded from "
              "0x%X with CLUT (0,0x%X)"
              % (hex(q["clut_builder"]), q["clut_builder_formula"],
                 q["grid_clut_a1"], q["ft4_tag"], q["ft4_size"],
                 q["ft4_page_arg"], q["ft4_clut_arg"]))
        print("    glyph pages: pick at 0x%08X is `sltiu 0x24` -> 0x%08X / 0x%08X"
              % (t["fonts"]["pick"], t["fonts"]["font_a"], t["fonts"]["font_b"]))
        b = bath_draw_trace()
        print("BATH page step @0x%08X: bank byte -> read_dt_tbl[bank] = dir[4+bank] "
              "(group table 0x%08X); file index -> loader, then LoadImage from "
              "0x%08X" % (b["bank_select"], b["group_table"], b["loadimage_call"]))
        print("  banks: " + "; ".join(
            f"{x['bank']} -> dir[{x['group']}] ({x['files'][0]}..{x['files'][-1]})"
            for x in b["banks"]))
        print("  bank -> room: %s" % b["status"])

    if args.paper:
        p = paper_probe()
        print("PAPER vs its own family (null-calibrated 4x4 block ratio; "
              "~1 = no structure, >=8 = a legible page):")
        for e in p["paper"]:
            print(f"  {e['file']:12s} rel={e['rel']:6.2f} zerofrac={e['zero_frac']:.3f} "
                  f"distinct={e['distinct']:4d} lag1={e['lag1']:6.3f}  {e['class']}")
        print("  STONE_nn band: %.2f..%.2f" % (min(p["stone_rel"]), max(p["stone_rel"])))
        print("  legible siblings: " + ", ".join(
            f"{k.replace('.BIN','')}={v}" for k, v in sorted(p["siblings"].items())))
        print(f"  no-structure PAPER pages: {p['paper_no_structure']} -- the same "
              f"open question as STONE_nn, not a separate format")

    if args.json:
        data = {"bath": bath_report(), "stone": stone_probe(),
                "stone_ids": stone_table(), "ownership": owners(),
                "stone_page_load": stone_page_load(),
                "stone_draw": stone_draw_trace(),
                "stone_second_byte": stone_second_byte(),
                "bath_draw": bath_draw_trace(),
                "paper": paper_probe()}
        with open(args.json, "w") as f:
            json.dump(data, f, indent=1)
        print("wrote", args.json)

    if not any((args.bath, args.stone, args.groups, args.json, args.render,
                args.draw, args.paper)):
        print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
