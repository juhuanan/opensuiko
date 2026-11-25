#!/usr/bin/env python3
"""War mode (DATA/16_WAR) map and UI graphics.

Every `WAR_*.BIN` overlay carries a set of **16-byte resource descriptors**::

    +0x0  u32  dims: width in the low half, height in the high half
    +0x4  u32  resource id
    +0x8  u32  -> an array of u32 pointers to blocks
    +0xC  u32  -> a pointer whose *value* is the 256-colour RGB555 CLUT
                 (for the sky it points into an array of 15 palettes)

Each block is `[u32 compressed_size][LZSS payload]` (the game's own
`text_decode_stream @0x800C3144`; canonical port `kit/tools/lzss.py` v2.0.0) and
every block referenced this way decodes to **exactly 16,384 bytes** -- a 128x128
8bpp page -- with full input consumption.

Descriptors are found **structurally**, never from a table of known offsets:
a 4-aligned 4-word window whose dims are a sane (w,h), whose id is a small
integer, whose two pointers are inside the overlay, and whose pointer array
reaches at least one 16,384-byte block.  The id's *high* byte varies per
scenario (KUWA says `0x0103` where GARA says `0x0203`), so nothing keys off it.

Three resource kinds fall out, and they are the same in every overlay:

* **sprite atlas** -- one block, `(w,h)` like `64x22`, `82x20`, `34x10`,
  `32x5`, `8x1`. These are the mode's *sprites*: rank-and-file soldier units
  (several poses each, with red/blue/green unit flags), spell and impact
  effect frames, and the `Defeat` banner. Six of them per overlay.
* **terrain grid** -- `20x15`, five blocks of *byte values 0..14*: not an image.
  A 128x128 grid of terrain-type codes.
* **map background** -- `20x15` with three blocks (castle, terrain) and `16x12`
  with three or four (sky).

Usage:
    python3 war_map.py --list
    python3 war_map.py --file WAR_KUWA.BIN --out kit/work/war_map
"""
from __future__ import annotations

import argparse
import collections
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import lzss  # noqa: E402
import war_graphics as _wg  # noqa: E402
import war_text as _wt  # noqa: E402

OVERLAY_BASE = _wt.OVERLAY_BASE
PAGE_BYTES = 0x4000
PAGE_W = 128
PAGE_H = 128
GRID_MAX = 0x20          # a block whose max byte is this low is a code grid
DESC_WORDS = 4

#: categorical colours for the terrain grids (index -> RGB)
GRID_COLOURS = [
    (0, 0, 0), (86, 140, 66), (124, 170, 74), (176, 164, 96), (120, 120, 120),
    (206, 206, 206), (92, 112, 200), (62, 92, 160), (200, 124, 64), (160, 92, 52),
    (240, 220, 120), (208, 96, 176), (120, 200, 200), (240, 150, 40), (150, 90, 220),
    (60, 150, 90), (230, 230, 90), (60, 60, 90), (250, 250, 250), (150, 30, 30),
]


def decode_block(data: bytes, off: int) -> bytes:
    """`[u32 size][LZSS]`, strict: consumption and output size are asserted."""
    size = struct.unpack_from("<I", data, off)[0]
    if size == 0 or off + 4 + size > len(data):
        raise ValueError(f"block at 0x{off:06X} claims {size} bytes")
    out, used = lzss.decode_container(data[off : off + 4 + size])
    if used != 4 + size:
        raise ValueError(f"block at 0x{off:06X}: consumed {used} of {4 + size}")
    return out


def _array(data: bytes, off: int, limit: int = 64) -> list[int]:
    n = len(data)
    out = []
    o = off
    while o + 4 <= n and len(out) < limit:
        v = struct.unpack_from("<I", data, o)[0]
        if not (OVERLAY_BASE <= v < OVERLAY_BASE + n):
            break
        out.append(v - OVERLAY_BASE)
        o += 4
    return out


def _try_block(data: bytes, off: int) -> bytes | None:
    try:
        out = decode_block(data, off)
    except Exception:
        return None
    return out if len(out) == PAGE_BYTES else None


def descriptors(data: bytes) -> list[dict]:
    """Every resource descriptor, found structurally."""
    n = len(data)
    out = []
    for o in range(0, n - 16, 4):
        dims, rid, arr_ptr, clut_ptr = struct.unpack_from("<4I", data, o)
        w, h = dims & 0xFFFF, dims >> 16
        if not (1 <= w <= 128 and 1 <= h <= 128):
            continue
        if not (1 <= rid <= 0xFFFF):
            continue
        if not (OVERLAY_BASE <= arr_ptr < OVERLAY_BASE + n):
            continue
        if not (OVERLAY_BASE <= clut_ptr < OVERLAY_BASE + n):
            continue
        clut = struct.unpack_from("<I", data, clut_ptr - OVERLAY_BASE)[0]
        if not (OVERLAY_BASE <= clut < OVERLAY_BASE + n):
            continue
        ptrs = _array(data, arr_ptr - OVERLAY_BASE)
        blocks = []
        for p in ptrs:
            buf = _try_block(data, p)
            if buf is not None:
                blocks.append((p, buf))
        if not blocks:
            continue
        out.append(
            {
                "off": o,
                "w": w,
                "h": h,
                "id": rid,
                "clut_off": clut - OVERLAY_BASE,
                "clut_ptr": clut_ptr - OVERLAY_BASE,
                "array_off": arr_ptr - OVERLAY_BASE,
                "array": ptrs,
                "blocks": blocks,
                "kind": classify(blocks),
            }
        )
    # A shifted read of a real record is filtered by the dims test (the id word
    # is ~0x0101, which is > 128), so each record is found at exactly its own
    # offset.  Two genuinely different resources can share dims AND id AND a
    # block count (KUWA has two 82x20 atlases), so dedupe by position only.
    out.sort(key=lambda d: (d["off"], -len(d["array"])))
    kept: list[dict] = []
    for d in out:
        if kept and d["off"] - kept[-1]["off"] < 16:
            continue
        kept.append(d)
    return kept


def classify(blocks: list[tuple[int, bytes]]) -> str:
    """`atlas` | `grid` | `map`, from the decoded content rather than the id."""
    if not blocks:
        return "empty"
    bufs = [b for _p, b in blocks]
    if len(bufs) == 1:
        return "atlas"
    if all(max(b) <= GRID_MAX for b in bufs):
        return "grid"
    return "map"


def rgb555(word: int) -> tuple[int, int, int]:
    return _wg.rgb555(word)


def render_page(data: bytes, buf: bytes, clut_off: int, w: int = PAGE_W, h: int = PAGE_H):
    from PIL import Image

    lut = _wg.palette_lut(data, clut_off)
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            i = y * w + x
            px[x, y] = lut[buf[i]] if i < len(buf) else (0, 0, 0)
    return im


def render_grid(buf: bytes, w: int = PAGE_W, h: int = PAGE_H):
    from PIL import Image

    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            v = buf[y * w + x]
            px[x, y] = GRID_COLOURS[v % len(GRID_COLOURS)]
    return im


def render(data: bytes, d: dict):
    if d["kind"] == "grid":
        return [render_grid(b) for _p, b in d["blocks"]]
    return [render_page(data, b, d["clut_off"]) for _p, b in d["blocks"]]


def war_files() -> list[str]:
    return [n for n, _rec in _wt.war_files()]


def load(name: str) -> bytes:
    return _wt.load(name)


def summary(name: str, data: bytes) -> list[str]:
    lines = []
    for d in descriptors(data):
        kinds = collections.Counter()
        if d["kind"] == "grid":
            for _p, b in d["blocks"]:
                kinds[max(b)] += 1
        lines.append(
            f"  @0x{d['off']:06X} id={d['id']:#06x} {d['w']:3d}x{d['h']:<3d} "
            f"clut=0x{d['clut_off']:06X} arr={len(d['array']):2d} "
            f"blocks={len(d['blocks'])} kind={d['kind']}"
            + (f" grid_max={sorted(kinds)}" if kinds else "")
        )
    return lines


def write_assets(outdir: str) -> dict:
    import json

    os.makedirs(outdir, exist_ok=True)
    man = {}
    for name in war_files():
        data = load(name)
        ds = descriptors(data)
        if not ds:
            continue
        entry = []
        for i, d in enumerate(ds):
            ims = render(data, d)
            for j, im in enumerate(ims):
                p = os.path.join(
                    outdir, f"{name.replace('.BIN','')}_{d['kind']}{i:02d}_{j}.png"
                )
                im.save(p)
            entry.append(
                {
                    "off": d["off"], "id": d["id"], "dims": [d["w"], d["h"]],
                    "kind": d["kind"], "clut_off": d["clut_off"],
                    "block_offsets": [b[0] for b in d["blocks"]],
                    "block_output_bytes": [len(b[1]) for b in d["blocks"]],
                }
            )
        man[name] = entry
    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    return man


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--file")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args(argv)

    if args.list:
        for name in war_files():
            data = load(name)
            print(f"=== {name}  {len(data)} B")
            for line in summary(name, data):
                print(line)
        return 0

    names = war_files() if (args.all or args.out) else ([args.file] if args.file else [])
    if not names:
        ap.error("need --list, --file, --all or --out")
    for name in names:
        data = load(name)
        print(f"=== {name}")
        for line in summary(name, data):
            print(line)
    if args.out:
        man = write_assets(args.out)
        n = sum(len(v) for v in man.values())
        print(f"wrote {n} descriptors across {len(man)} files under {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
