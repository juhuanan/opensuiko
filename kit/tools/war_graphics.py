#!/usr/bin/env python3
"""War mode (DATA/16_WAR) graphics: portrait blocks.

The `WAR_*.BIN` overlays are loaded at `0x80010000` and are **not** compressed
as a whole -- but the art inside them is, in the game's own codec
(`text_decode_stream @0x800C3144`; canonical port `kit/tools/lzss.py` v2.0.0).

The portrait bank is a table of 8-byte rows::

    +0x0  u32  -> a block: [u32 compressed_size][LZSS payload]
    +0x4  u32  -> a 256-colour CLUT (RGB555, 512 bytes)

The table is located without guessing an offset: find the 0x200-strided run of
256-colour palettes (the bank, 9 entries in the nine selector-reachable
overlays), then find the run of 8-byte table rows whose second word is one of
those palette addresses.

Every block decodes to **exactly 4096 bytes** with full input consumption and
4-byte padding to the next block -- a 64x64 8bpp portrait, one per leader.
The portraits are per-battle: the nine overlays do not share one set.

Usage:
    python3 war_graphics.py --list
    python3 war_graphics.py --file WAR_KUWA.BIN --sheet kit/work/war_render/kowa.png
    python3 war_graphics.py --all --out kit/work/war_render
"""
from __future__ import annotations

import argparse
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import war_text as _wt  # noqa: E402  (file table + decoding conventions)
import lzss  # noqa: E402

OVERLAY_BASE = _wt.OVERLAY_BASE

PALETTE_STRIDE = 0x200
PALETTE_ENTRIES = 256
PALETTE_BYTES = PALETTE_ENTRIES * 2
TABLE_STRIDE = 8
BLOCK_OUT_SIZE = 0x1000
PORTRAIT_W = 64
PORTRAIT_H = 64

#: how many palettes the bank has in the nine selector-reachable overlays
EXPECTED_BANK = 9


def rgb555(word: int) -> tuple[int, int, int]:
    return (
        (word & 0x1F) * 255 // 31,
        ((word >> 5) & 0x1F) * 255 // 31,
        ((word >> 10) & 0x1F) * 255 // 31,
    )


def is_palette(data: bytes, off: int) -> bool:
    """A 256-word RGB555 run: entry 0 clear, no alpha bits, almost all used.

    The filter is the one that first found these runs in
    `kit/docs/war_mode.md` section 8; it is re-stated here rather than
    imported so this module stands on its own.
    """
    if off < 0 or off + PALETTE_BYTES > len(data):
        return False
    words = struct.unpack_from("<256H", data, off)
    if words[0] != 0:
        return False
    if any(w & 0x8000 for w in words):
        return False
    return sum(1 for w in words if w) >= 240


def palette_bank(data: bytes) -> list[int]:
    """Longest run of `0x200`-strided palettes: the block CLUT bank."""
    best: list[int] = []
    off = 0
    n = len(data)
    while off + PALETTE_BYTES <= n:
        if is_palette(data, off):
            run = [off]
            p = off + PALETTE_STRIDE
            while p + PALETTE_BYTES <= n and is_palette(data, p):
                run.append(p)
                p += PALETTE_STRIDE
            if len(run) > len(best):
                best = run
            off = p
        else:
            off += 2
    return best


def portrait_table(data: bytes) -> tuple[int, list[tuple[int, int]]]:
    """`(table_offset, [(block_off, palette_off)])`, or `(-1, [])`.

    Anchored on the palette bank, then grown into the maximal run of
    `TABLE_STRIDE` rows whose second word is one of the bank's addresses, so
    it cannot lock onto a single coincidental word.
    """
    bank = palette_bank(data)
    if not bank:
        return -1, []
    words = {struct.pack("<I", OVERLAY_BASE + p) for p in bank}
    n = len(data)
    best: tuple[int, list[tuple[int, int]]] = (-1, [])
    # `words` is a set, so iterate deterministically and keep the LONGEST run:
    # taking the first hit made the result depend on set ordering.
    for want in sorted(words):
        for hit in range(4, n - 4, 4):
            if data[hit : hit + 4] != want:
                continue
            # `hit` is a row's SECOND word (the palette), so the neighbouring
            # palette words are at hit +/- TABLE_STRIDE, not +/- 4.
            start = hit
            while start - TABLE_STRIDE >= 4 and data[start - 8 : start - 4] in words:
                start -= TABLE_STRIDE
            end = hit
            while end + TABLE_STRIDE <= n - 4 and data[end + 8 : end + 12] in words:
                end += TABLE_STRIDE
            if (end - start) // TABLE_STRIDE < 8:
                continue
            row0 = start - 4
            if row0 < 0:
                continue
            rows = []
            k = 0
            while row0 + TABLE_STRIDE * (k + 1) <= n:
                p, q = struct.unpack_from("<II", data, row0 + TABLE_STRIDE * k)
                if not (OVERLAY_BASE <= p < OVERLAY_BASE + n):
                    break
                if not (OVERLAY_BASE <= q < OVERLAY_BASE + n):
                    break
                rows.append((p - OVERLAY_BASE, q - OVERLAY_BASE))
                k += 1
            if len(rows) > len(best[1]):
                best = (row0, rows)
    return best


def decode_block(data: bytes, off: int) -> tuple[bytes, int, int]:
    """`(indices, compressed_size, padding)` for the block at `off`.

    The block is self-delimiting: `[u32 compressed_size][payload]`, padded with
    0-3 bytes to a 4-byte boundary.  Strict decode: a truncated stream raises
    rather than returning a plausible-looking partial image.
    """
    size = struct.unpack_from("<I", data, off)[0]
    if size == 0 or off + 4 + size > len(data):
        raise ValueError(f"block at 0x{off:06X} claims {size} bytes past the end")
    out, used = lzss.decode_container(data[off : off + 4 + size])
    if used != 4 + size:
        raise ValueError(f"block at 0x{off:06X}: consumed {used} of {4 + size}")
    return out, size, 0


def blocks(data: bytes) -> list[dict]:
    """Every portrait block, decoded, in table order."""
    table_off, rows = portrait_table(data)
    out = []
    for i, (off, pal) in enumerate(rows):
        indices, size, _pad = decode_block(data, off)
        out.append(
            {"index": i, "off": off, "comp_size": size, "pal_off": pal,
             "indices": indices, "table_off": table_off}
        )
    return out


def palette_lut(data: bytes, pal_off: int) -> list[tuple[int, int, int]]:
    return [
        rgb555(struct.unpack_from("<H", data, pal_off + 2 * i)[0])
        for i in range(PALETTE_ENTRIES)
    ]


def render(data: bytes, blk: dict, w: int = PORTRAIT_W, h: int = PORTRAIT_H):
    from PIL import Image

    im = Image.new("RGB", (w, h))
    px = im.load()
    lut = palette_lut(data, blk["pal_off"])
    buf = blk["indices"]
    for y in range(h):
        for x in range(w):
            i = y * w + x
            px[x, y] = lut[buf[i]] if i < len(buf) else (0, 0, 0)
    return im


def sheet(data: bytes, cols: int = 14, scale: int = 1):
    from PIL import Image

    bs = blocks(data)
    rows_n = (len(bs) + cols - 1) // cols
    im = Image.new("RGB", (cols * PORTRAIT_W, rows_n * PORTRAIT_H))
    for b in bs:
        tile = render(data, b)
        im.paste(tile, ((b["index"] % cols) * PORTRAIT_W,
                        (b["index"] // cols) * PORTRAIT_H))
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    return im, bs


def war_files() -> list[str]:
    return [n for n, _rec in _wt.war_files()]


def load(name: str) -> bytes:
    return _wt.load(name)


def summary(name: str, data: bytes) -> str:
    bank = palette_bank(data)
    table_off, rows = portrait_table(data)
    return (f"{name:15s} size={len(data):7d} palbank={len(bank)} "
            f"table={'none' if table_off < 0 else f'0x{table_off:06X}'} rows={len(rows)}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="summarise every war file")
    ap.add_argument("--file", help="one war file")
    ap.add_argument("--all", action="store_true", help="every war file")
    ap.add_argument("--out", help="write per-file portrait sheets under this dir")
    ap.add_argument("--sheet", help="write one sheet PNG here")
    ap.add_argument("--cols", type=int, default=14)
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--digest", action="store_true",
                    help="print a digest of the decoded portrait set")
    args = ap.parse_args(argv)

    if args.list:
        for n in war_files():
            print(summary(n, load(n)))
        return 0

    names = war_files() if (args.all or args.out) else ([args.file] if args.file else [])
    if not names:
        ap.error("need --list, --file, --all, --out or --sheet")
    for n in names:
        d = load(n)
        if args.digest or not (args.out or args.sheet):
            bs = blocks(d)
            import hashlib

            h = hashlib.sha256()
            for b in bs:
                h.update(b["indices"])
            sizes = sorted({len(b["indices"]) for b in bs})
            print(f"{n:15s} blocks={len(bs)} out_sizes={sizes} "
                  f"digest={h.hexdigest()[:16]}")
        if args.sheet:
            im, bs = sheet(d, args.cols, args.scale)
            if not bs:
                print(f"{n}: no portrait blocks, nothing written")
                continue
            im.save(args.sheet)
            print(f"wrote {args.sheet} ({im.width}x{im.height})")
        if args.out:
            im, bs = sheet(d, args.cols, args.scale)
            if not bs:
                print(f"{n}: no portrait blocks, nothing written")
                continue
            os.makedirs(args.out, exist_ok=True)
            p = os.path.join(args.out, n.replace(".BIN", "_portraits.png"))
            im.save(p)
            print(f"wrote {p} ({len(bs)} portraits, {im.width}x{im.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
