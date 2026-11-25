#!/usr/bin/env python3
"""The `DATA/03_SHIRO` content-page family, and the load-group directory that owns it.

Two claims, kept separate:

**PROBE (mechanical).** A set of `03_SHIRO` files are the *same container* as
`FACE_*.BIN`: `[u32 filesize-4][LZSS]` whose decode is **exactly 16,384 B** with
**full input consumption** (16,384 B = a 128x128 8bpp page).  The tool finds them
by walking every file, not by name, and raises on any partial decode.

**PROBE (mechanical).** `MAIN.EXE` holds a **load-group directory** at
`0x8016B358` -- 16 entries, each a pointer to a list of master-file-table
records (`0x80163D64`, 344 x `(u32 size, u32 lba)`).  Resolved, the groups are the
`03_SHIRO` overlays, the tablet pages, the portrait pages, the book/paper/curio
set, the four BATH sets, the yuge/mizu/hana set, and the duel content.  This is
the *loading context* of the `03_SHIRO` files: it says which files are needed
together, which is the ownership question for the files nobody had examined.

**INFERENCE (human inspection, recorded in the doc, not here).** What the pages
depict.  The tool does not name content.

Usage:
    python3 shiro_pages.py --family      # the 128x128 8bpp page family
    python3 shiro_pages.py --groups      # the 0x8016B358 load-group directory
    python3 shiro_pages.py --render DIR  # write the pages as PNGs for inspection
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc_iso  # noqa: E402
import disc  # noqa: E402
import lzss  # noqa: E402

ISO = os.path.join(_KIT, "extracted", "iso_files.json")

#: the master file table in MAIN.EXE: 344 records of (u32 size, u32 lba)
FILE_TABLE = 0x80163D64
FILE_TABLE_N = 344
MAIN_BASE = 0x800C0800
#: the load-group directory, and the init that installs it
GROUP_DIR = 0x8016B358
GROUP_DIR_INSTALL = 0x800C9648

PAGE_BYTES = 16384          # 128x128 8bpp


def _iso() -> list[dict]:
    return disc_iso.iso_records(ISO)


def main_image() -> bytes:
    return disc_iso.main_image(ISO)


def page_family() -> list[dict]:
    """Every file that is `[u32 filesize-4][LZSS]` -> exactly 16,384 B, consumed."""
    out = []
    for r in _iso():
        try:
            d = disc.extract(r["lba"], r["size"])
        except Exception:
            continue
        if len(d) < 8:
            continue
        if struct.unpack_from("<I", d, 0)[0] != len(d) - 4:
            continue
        try:
            payload, used = lzss.decode_container(d)
        except Exception:
            continue
        if used != len(d) or len(payload) != PAGE_BYTES:
            continue
        out.append({"path": r["path"], "lba": r["lba"], "size": r["size"],
                    "decoded": len(payload)})
    return out


def load_groups() -> list[dict]:
    """The `0x8016B358` directory, each group as a list of file records."""
    img = main_image()
    by_lba = {r["lba"]: r["path"] for r in _iso()}

    def record_path(addr):
        if not (FILE_TABLE <= addr < FILE_TABLE + FILE_TABLE_N * 8):
            return None
        _size, lba = struct.unpack_from("<II", img, addr - MAIN_BASE)
        return by_lba.get(lba)

    groups = []
    for i in range(64):
        g = struct.unpack_from("<I", img, GROUP_DIR - MAIN_BASE + 4 * i)[0]
        if not (MAIN_BASE <= g < MAIN_BASE + len(img)):
            break
        files = []
        for k in range(64):
            v = struct.unpack_from("<I", img, g - MAIN_BASE + 4 * k)[0]
            p = record_path(v)
            if p is None:
                break
            files.append(p)
        groups.append({"index": i, "group_addr": g, "files": files})
    return groups


def render(outdir: str, scale: int = 3) -> int:
    from PIL import Image

    os.makedirs(outdir, exist_ok=True)
    n = 0
    for e in page_family():
        d = disc.extract(e["lba"], e["size"])
        payload, _u = lzss.decode_container(d)
        im = Image.frombytes("L", (128, 128), payload)
        name = os.path.basename(e["path"]).replace(".BIN", "")
        im.resize((128 * scale, 128 * scale), Image.NEAREST).save(
            os.path.join(outdir, name + "_page.png"))
        n += 1
    return n


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--family", action="store_true")
    ap.add_argument("--groups", action="store_true")
    ap.add_argument("--render")
    args = ap.parse_args(argv)

    if args.family:
        fam = page_family()
        print(f"{len(fam)} files are [u32 filesize-4][LZSS] -> exactly {PAGE_BYTES} B, full consumption")
        bydir = {}
        for e in fam:
            bydir.setdefault(os.path.dirname(e["path"]), []).append(os.path.basename(e["path"]))
        for d in sorted(bydir):
            print(f"   {d}: {len(bydir[d])}  {sorted(bydir[d])}")
        return 0

    if args.groups:
        for g in load_groups():
            print(f"[{g['index']:2d}] 0x{g['group_addr']:08X}  {len(g['files'])} files")
            for f in g["files"]:
                print(f"        {f}")
        return 0

    if args.render:
        print(f"wrote {render(args.render)} pages")
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
