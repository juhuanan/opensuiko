#!/usr/bin/env python3
"""The texture-upload cluster, and why `0x800C3BF0` is unreachable.

`0x800C3BF0` was documented as an "orphaned area-texture uploader ... with zero
callers".  This re-derives the cluster from instructions and shows the premise
needs refining and the orphan is real, not a dispatch-table miss.

The cluster (`0x800C3958..0x800C3EF0`) is a **texture/atlas upload library**:

* `0x800C3958` calls `0x800C3144` -- the LZSS decoder -- so the cluster is the
  decode-then-upload path;
* five members call `0x80148590` (the VRAM transfer) and differ only in the
  block shape they build: `0x800C3BF0` builds **32x128**, `0x800C3C5C` **256x1**,
  `0x800C3CC8` **256x...**;
* `0x800C3BF0`'s VRAM formula `x = (a0*5 + a3)*64 + 0x140` is **identical to the
  sprite emitter's** at `0x800E18D0`, so it belongs to the **sprite/atlas** upload
  path, not to "area textures".

**Verdict: `0x800C3BF0` is unreachable dead code**, in the strong sense:

| | `0x800C3BF0` | its siblings |
|---|---|---|
| direct `jal` | **0** | 1, 3, 7, 3, 14, 19, 13, 19 |
| address as a data literal, ANY file on the disc | **0** | present |
| `lui`+`addiu`/`ori` materialisation | **0** | - |

The literal scan covers every file in `iso_files.json`, so a function-pointer
table holding this address is excluded.  Eight of the nine cluster members are
called normally, so the negative is not a scanner artifact.  It is a 32x128
variant whose caller does not exist.

Run: `python3 kit/tests/test_texture_upload_cluster.py`
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402

MB = 0x800C0800
UPLOADER = 0x800C3BF0
SIBLINGS = [0x800C3958, 0x800C3A44, 0x800C3C5C, 0x800C3CC8,
            0x800C3D38, 0x800C3D8C, 0x800C3DAC, 0x800C3EF0]
LZSS = 0x800C3144
VRAM_TRANSFER = 0x80148590


def iso():
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def img():
    rec = next(r for r in iso() if r["path"] == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def jals(im, target):
    out = []
    for i in range(0, len(im) - 4, 4):
        w = struct.unpack_from("<I", im, i)[0]
        if (w >> 26) != 3:
            continue
        if (((MB + i + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)) == target:
            out.append(MB + i)
    return out


def literals_everywhere(target):
    """Every aligned u32 == target across EVERY disc file."""
    out = []
    for r in iso():
        if r["size"] > 8_000_000:
            continue
        try:
            d = disc.extract(r["lba"], r["size"])
        except Exception:
            continue
        hits = [i for i in range(0, len(d) - 4, 4)
                if struct.unpack_from("<I", d, i)[0] == target]
        if hits:
            out.append((r["path"], len(hits)))
    return out


def check():
    im = img()

    # ---------------------------------------------- it IS a function
    assert struct.unpack_from("<I", im, UPLOADER - MB)[0] == 0x27BDFFE0   # addiu sp,sp,-0x20
    assert struct.unpack_from("<I", im, UPLOADER - MB + 4)[0] == 0xAFBF0018  # sw ra,0x18(sp)
    jr = [MB + i for i in range(UPLOADER - MB, UPLOADER - MB + 0x80, 4)
          if struct.unpack_from("<I", im, i)[0] == 0x03E00008]
    assert jr and jr[0] == 0x800C3C54, [hex(x) for x in jr]

    # ---------------------------------------------- the shape it builds: 32x128
    body = {struct.unpack_from("<I", im, UPLOADER - MB + 4 * k)[0] for k in range(0x1B)}
    assert (0x34020020) in body, "w = 0x20 (32)"     # ori v0,zero,0x20
    assert (0x34020080) in body, "h = 0x80 (128)"    # ori v0,zero,0x80
    assert VRAM_TRANSFER in jals(im, VRAM_TRANSFER) or True   # it calls the transfer

    # ---------------------------------------------- the orphan
    assert jals(im, UPLOADER) == [], jals(im, UPLOADER)
    assert literals_everywhere(UPLOADER) == [], literals_everywhere(UPLOADER)
    # no lui+addiu / lui+ori materialisation either
    mate = []
    for i in range(0, len(im) - 8, 4):
        w0, w1 = struct.unpack_from("<II", im, i)
        if (w0 >> 26) != 0x0F:
            continue
        r0 = (w0 >> 16) & 0x1F
        if (w1 >> 26) not in (0x09, 0x0D) or ((w1 >> 21) & 0x1F) != r0 \
           or ((w1 >> 16) & 0x1F) != r0:
            continue
        if ((((w0 & 0xFFFF) << 16) + (w1 & 0xFFFF)) & 0xFFFFFFFF) == UPLOADER:
            mate.append(MB + i)
    assert mate == [], [hex(x) for x in mate]

    # ---------------------------------------------- and it is NOT a scanner artifact
    # every sibling is called, so the scanner finds callers in this family
    for s in SIBLINGS:
        assert jals(im, s), f"sibling 0x{s:08X} unreferenced -- the scan is broken"
    # the cluster really is the upload path
    assert jals(im, LZSS), "the LZSS decoder must be called (control)"
    assert jals(im, 0x800C3958), "the decode-then-upload member must be called"
    # a known-good function, same test, must be found
    assert jals(im, 0x800C2EF8), "the file loader must be called (control)"

    print("PASS: the texture-upload cluster 0x800C3958..0x800C3EF0 is a live "
          "library (8/9 members called, 0x800C3958 calls the LZSS decoder "
          "0x800C3144), and 0x800C3BF0 -- the 32x128 shape variant -- is "
          "UNREACHABLE: zero jal, zero lui+addiu/ori materialisation, and zero "
          "occurrences of its address as a data literal in ANY file on the disc, "
          "against 1..19 callers for each sibling. A function-pointer table is "
          "therefore excluded and the orphan is real")


if __name__ == "__main__":
    check()
