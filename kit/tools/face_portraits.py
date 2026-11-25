#!/usr/bin/env python3
"""Dialogue portraits (`DATA/03_SHIRO/DATA/FACE_*.BIN`) -- the asset collection.

Format (see `kit/docs/face_portraits_decoded.md`)::

    FACE_nn.BIN:  [u32 payload_len == filesize-4][LZSS payload]
                  -> EXACTLY 16,384 bytes, full consumption
                  -> a 128x128 8bpp page = four 64x64 portraits, row-major 2x2

27 files x 4 cells = **108 portraits**, and all 108 are **byte-identical** to
war portrait planes 0..107, so each one takes its 256-colour CLUT from the war
bank row for the identical plane (`kit/tools/war_graphics.py`).

Companion tables, all read from the disc and all *verified as tables*:

* `names()`   -- 108 NUL-terminated character names, reached through the u32
  pointer array at `STONE.BIN 0x5220`.  Index 0 points at a placeholder slot
  (`0x96` filler, not text), which is what a player-named hero looks like.
* `order()`   -- the 108-byte array at `STONE.BIN 0x4B40`; a permutation of
  0..107.
* quotes are `war_text.leader_quotes()` of a war overlay.

**The alignment between the portrait order and the name order is NOT derived.**
Portrait 0 is the hero (green headband) and name 0 is the placeholder hero slot,
which is consistent; but portrait 7 is unmistakably Viktor while `name[7]` is
Pesmerga and the war `quote[7]` is Varkas.  So `character_index` is deliberately
left `None` in the manifest: the names ship as a companion list for the user to
align, not as an answer.  Do not "fix" this by guessing.

Usage:
    python3 face_portraits.py --list
    python3 face_portraits.py --names
    python3 face_portraits.py --sheet kit/work/face_render/all108.png
    python3 face_portraits.py --out kit/work/face_render
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import disc_iso  # noqa: E402
import lzss  # noqa: E402
import war_graphics as _wg  # noqa: E402
import war_text as _wt  # noqa: E402
import main_tables as _mt  # noqa: E402

FACE_PREFIX = "DATA/03_SHIRO/DATA/FACE_"
STONE = "DATA/03_SHIRO/STONE.BIN"
PLAY_PREFIX = "DATA/04_PLAY/"

PAGE_BYTES = 16384
PAGE_W = 128
PORTRAIT_W = 64
PORTRAIT_H = 64
CELLS_PER_PAGE = 4

NAME_TABLE_OFF = 0x5220      # u32 pointer array, 108 entries
ORDER_TABLE_OFF = 0x4B40     # 108-byte permutation of 0..107
STONE_BASE = 0x80080000      # STONE.BIN's load address (its word 0 is 0x80080268)

#: the war file whose palette bank + plane order the portraits are matched to.
#: All nine share planes 0..110, so any selector-reachable one works.
REFERENCE_WAR = "WAR_KUWA.BIN"


def _iso() -> list[dict]:
    return disc_iso.iso_records(os.path.join(_KIT, "extracted", "iso_files.json"), include_dirs=True)


def face_records() -> list[dict]:
    recs = [r for r in _iso() if r.get("path", "").startswith(FACE_PREFIX) and not r.get("dir")]
    recs.sort(key=lambda r: r["path"])
    return recs


def stone() -> bytes:
    rec = next(r for r in _iso() if r.get("path") == STONE)
    return disc.extract(rec["lba"], rec["size"])


def decode_page(data: bytes) -> bytes:
    """`[u32 len][LZSS]` -> the 128x128 page.  Strict: consumption is asserted."""
    size = struct.unpack_from("<I", data, 0)[0]
    if size != len(data) - 4:
        raise ValueError(f"header {size} != filesize-4 ({len(data) - 4})")
    out, used = lzss.decode_container(data)
    if used != len(data):
        raise ValueError(f"consumed {used} of {len(data)}")
    if len(out) != PAGE_BYTES:
        raise ValueError(f"page is {len(out)} bytes, expected {PAGE_BYTES}")
    return out


def page_cells(page: bytes) -> list[bytes]:
    """The four 64x64 cells, row-major 2x2 (verified by byte-identity to war)."""
    out = []
    for r in range(2):
        for c in range(2):
            buf = bytearray()
            for y in range(PORTRAIT_H):
                o = (r * PORTRAIT_H + y) * PAGE_W + c * PORTRAIT_W
                buf += page[o : o + PORTRAIT_W]
            out.append(bytes(buf))
    return out


def _reference() -> tuple[list[dict], dict[str, int]]:
    war = _wg.load(REFERENCE_WAR)
    planes = _wg.blocks(war)
    by_hash = {hashlib.sha256(p["indices"]).hexdigest(): i for i, p in enumerate(planes)}
    return planes, by_hash


def portraits() -> list[dict]:
    """All 108 portraits, in FACE page/cell order, with their CLUT."""
    planes, by_hash = _reference()
    out = []
    n = 0
    for rec in face_records():
        data = disc.extract(rec["lba"], rec["size"])
        for cell, buf in enumerate(page_cells(decode_page(data))):
            h = hashlib.sha256(buf).hexdigest()
            plane = by_hash.get(h)
            out.append(
                {
                    "index": n,
                    "face_file": rec["path"],
                    "lba": rec["lba"],
                    "file_size": rec["size"],
                    "cell": cell,
                    "war_plane": plane,
                    "clut_off": planes[plane]["pal_off"] if plane is not None else None,
                    "sha256": h,
                    "indices": buf,
                }
            )
            n += 1
    return out


def character_names() -> list[str]:
    """The portrait names, in portrait order.

    MAIN.EXE carries a byte-packed list of **124 character names** at
    `0x80170104`, and **its first 108 entries ARE the portrait index**:
    `[0] Hero` (and portrait 0 is the hero), `[4] Viktor`, `[44] Sylvina`,
    `[48] Kuromimi`, `[106] Pesmerga`, `[107] Crowley`.

    The independent cross-check is the war **leader-quote table**, which is
    indexed the same way: `quote[4]` is *"I am Viktor! Remember it!"*,
    `quote[7]` is *"Never heard of Varkas of Mt. Seifu?"* (and `name[7]` is
    Varkas), `quote[50]` is *"I am Grenseal of the Thunder."* (Grenseal),
    `quote[36]` is *"Hurry up, Hix!"* (Tengaar) and `quote[37]` replies as Hix.
    Fourteen such self-identifying lines line up, which is what makes this a
    derivation rather than a guess.
    """
    return [r["name"] for r in _mt.read_name_list("characters")]


def sprite_names() -> dict[int, tuple[str, str]]:
    """`{character_id: (name, source_file)}` from the `DATA/04_PLAY` sprite files.

    Each of the 78 three-letter files starts with a one-byte **character id**
    followed by a NUL-terminated name in the game's own text encoding::

        byte 0   u8   character id
        byte 1.. NUL-terminated name

    and **that id is the portrait index**.  This is the derivation that names
    the portraits: 8 is `Hero`, 2 is `Gremio`, 4 is `Kirkis`, 12 is `Varkas`,
    20 is `Kasumi`, 33 is `Valeria`, 34 is `Viktor`.
    """
    out: dict[int, tuple[str, str]] = {}
    recs = [r for r in _iso() if r.get("path", "").startswith(PLAY_PREFIX) and not r.get("dir")]
    for r in sorted(recs, key=lambda r: r["path"]):
        d = disc.extract(r["lba"], 0x40)
        cid = d[0]
        j = 1
        while j < 40 and _wt.is_text_byte(d[j]):
            j += 1
        name, _used = _wt.decode(d, 1, j - 1)
        if name:
            out[cid] = (name, r["path"].rsplit("/", 1)[-1])
    return out


def names() -> list[dict]:
    """The 108-entry name table at `STONE.BIN 0x5220`."""
    d = stone()
    out = []
    o = NAME_TABLE_OFF
    while o + 4 <= len(d):
        v = struct.unpack_from("<I", d, o)[0]
        if not (STONE_BASE <= v < STONE_BASE + len(d)):
            break
        off = v - STONE_BASE
        text, _ = _wt.decode(d, off, 24)
        out.append({"index": len(out), "name_ptr_off": o, "name_off": off, "name": text})
        o += 4
    return out


def order() -> list[int]:
    """The 108-byte permutation at `STONE.BIN 0x4B40`."""
    return list(stone()[ORDER_TABLE_OFF : ORDER_TABLE_OFF + 108])


def character_name(i: int) -> str | None:
    """Name for a *character* index, or None for the player-named hero slot."""
    ns = names()
    if not (0 <= i < len(ns)):
        return None
    t = ns[i]["name"]
    return None if t.startswith("\\x") else t


def render(p: dict, war: bytes | None = None):
    from PIL import Image

    war = war if war is not None else _wg.load(REFERENCE_WAR)
    lut = _wg.palette_lut(war, p["clut_off"])
    im = Image.new("RGB", (PORTRAIT_W, PORTRAIT_H))
    px = im.load()
    buf = p["indices"]
    for y in range(PORTRAIT_H):
        for x in range(PORTRAIT_W):
            px[x, y] = lut[buf[y * PORTRAIT_W + x]]
    return im


def sheet(cols: int = 12, scale: int = 1):
    from PIL import Image

    ps = portraits()
    rows = (len(ps) + cols - 1) // cols
    im = Image.new("RGB", (cols * PORTRAIT_W, rows * PORTRAIT_H))
    for p in ps:
        im.paste(render(p), ((p["index"] % cols) * PORTRAIT_W,
                             (p["index"] // cols) * PORTRAIT_H))
    if scale != 1:
        im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    return im, ps


def write_assets(outdir: str) -> dict:
    """Per-portrait PNGs plus `manifest.json`.  Returns the manifest."""
    os.makedirs(outdir, exist_ok=True)
    ps = portraits()
    ns = names()
    for p in ps:
        render(p).save(os.path.join(outdir, "FACE_%03d.png" % p["index"]))
    man = {
        "class": "dialogue_portraits",
        "source": FACE_PREFIX + "FACE_01..27.BIN",
        "decoder": "kit/tools/lzss.py v2.0.0 (text_decode_stream @0x800C3144)",
        "container": "[u32 payload_len == filesize-4][LZSS] -> exactly 16384 B, full consumption",
        "page": "128x128 8bpp, four 64x64 portraits, row-major 2x2",
        "count": len(ps),
        "clut_source": f"war bank rows of {REFERENCE_WAR} (planes are byte-identical)",
        "character_index_source": (
            "MAIN.EXE's character name list at 0x80170104, whose first 108 entries ARE "
            "the portrait index: [0] Hero, [4] Viktor, [44] Sylvina, [48] Kuromimi, "
            "[106] Pesmerga, [107] Crowley. Cross-checked against the war leader-quote "
            "table, which shares the index (quote[4]='I am Viktor!', quote[50]='I am "
            "Grenseal of the Thunder.', quote[36]='Hurry up, Hix!' for Tengaar)."
        ),
        "character_index_beware": (
            "Two OTHER verified index spaces do NOT coincide with the portraits: the "
            "STONE tablet table (Viktor = 12) and the DATA/04_PLAY one-byte id "
            "(Viktor = 35, Hero = 8). Use neither."
        ),
        "play_character_ids": {str(k): v[0] for k, v in sprite_names().items()},
        "play_names_note": (
            "DATA/04_PLAY/*.BIN each begin with u8 <character id> + a NUL-terminated "
            "name; those 78 names are proven and agree with the corpus's "
            "user-confirmed entries, but the id is a sprite id, not a portrait index."
        ),
        "names": [n["name"] for n in ns],
        "order_0x4B40": order(),
        "portraits": [
            dict({k: v for k, v in p.items() if k != "indices"},
                 name=(character_names()[p["index"]]
                       if p["index"] < len(character_names()) else None))
            for p in ps
        ],
    }
    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    return man


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="summarise the 27 files")
    ap.add_argument("--names", action="store_true", help="print the 108-name table")
    ap.add_argument("--order", action="store_true", help="print the 0x4B40 permutation")
    ap.add_argument("--sheet", help="write one 108-portrait sheet here")
    ap.add_argument("--out", help="write per-portrait PNGs + manifest.json here")
    ap.add_argument("--cols", type=int, default=12)
    ap.add_argument("--scale", type=int, default=1)
    args = ap.parse_args(argv)

    if args.list:
        for r in face_records():
            print(f"{r['path']:36s} lba={r['lba']:6d} size={r['size']:6d} -> 16384 B / 4 cells")
        return 0

    if args.names:
        for n in names():
            if n["name"].startswith("\\x"):
                print(f"  [{n['index']:3d}] (placeholder -- player-named hero)")
            else:
                print(f"  [{n['index']:3d}] {n['name']}")
        return 0

    if args.order:
        print(" ".join(str(v) for v in order()))
        return 0

    if args.sheet:
        im, ps = sheet(args.cols, args.scale)
        im.save(args.sheet)
        print(f"wrote {args.sheet} ({len(ps)} portraits, {im.width}x{im.height})")
        return 0

    if args.out:
        man = write_assets(args.out)
        print(f"wrote {man['count']} portraits + manifest.json under {args.out}")
        return 0

    ap.error("need --list, --names, --order, --sheet or --out")
    return 2


if __name__ == "__main__":
    sys.exit(main())
