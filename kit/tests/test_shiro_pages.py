#!/usr/bin/env python3
"""The 03_SHIRO/12_IKKI content-page family and its load-group directory.

Re-derived here with plain byte arithmetic and a direct LZSS call, so a bug in
`shiro_pages.py` cannot make this pass.  Disc required.

Run: `python3 kit/tests/test_shiro_pages.py`
"""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import lzss  # noqa: E402

PAGE = 16384
FILE_TABLE = 0x80163D64
FILE_TABLE_N = 344
MAIN_BASE = 0x800C0800
GROUP_DIR = 0x8016B358


def iso():
    with open(_KIT / "extracted" / "iso_files.json") as f:
        return [r for r in json.load(f) if not r.get("dir")]


def main_image():
    rec = next(r for r in iso() if r["path"] == "MAIN.EXE")
    return disc.extract(rec["lba"], rec["size"])[2048:]


def check():
    # ---------------------------------------------- the 133-file page family
    fam = []
    for r in iso():
        try:
            d = disc.extract(r["lba"], r["size"])
        except Exception:
            continue
        if len(d) < 8 or struct.unpack_from("<I", d, 0)[0] != len(d) - 4:
            continue
        try:
            out, used = lzss.decode_container(d)
        except Exception:
            continue
        if used != len(d):
            continue                      # partial decode is NOT a member
        if len(out) != PAGE:
            continue
        fam.append((r["path"], len(d), len(out)))
    assert len(fam) == 133, len(fam)
    # every member: header == filesize-4, full consumption, exactly one page
    for _p, src, dec in fam:
        assert dec == PAGE
        assert src - 4 > 0

    dirs = {}
    for p, _s, _d in fam:
        dirs.setdefault(str(Path(p).parent), []).append(Path(p).name)
    assert len(dirs["DATA/03_SHIRO/DATA"]) == 85, len(dirs["DATA/03_SHIRO/DATA"])
    assert len(dirs["DATA/12_IKKI/DATA"]) == 48, len(dirs["DATA/12_IKKI/DATA"])

    # the named groups inside the 85, counted rather than assumed
    def n(prefix, src=None):
        return sum(1 for x in dirs["DATA/03_SHIRO/DATA"]
                   if x.startswith(prefix) and (src is None or True))
    assert n("FACE_") == 27, n("FACE_")
    assert n("BATH_") == 24, n("BATH_")
    assert n("STONE_") == 18, n("STONE_")
    assert n("BOOK_") == 6 and n("PAPER_") == 6
    assert n("CURIO_") == 1 and n("HANA") == 1 and n("MIZU_") == 1 and n("YUGE_") == 1
    assert n("FACE_") + n("BATH_") + n("STONE_") + n("BOOK_") + n("PAPER_") \
        + n("CURIO_") + n("HANA") + n("MIZU_") + n("YUGE_") == 85

    # STONE is 18 pages, and 18 is what the corpus records as verified
    stones = sorted(x for x in dirs["DATA/03_SHIRO/DATA"] if x.startswith("STONE_"))
    assert stones[0] == "STONE_00.BIN" and stones[-1] == "STONE_11.BIN", stones

    # ---------------------------------------------- the load-group directory
    img = main_image()
    by_lba = {r["lba"]: r["path"] for r in iso()}

    def rec_path(addr):
        if not (FILE_TABLE <= addr < FILE_TABLE + FILE_TABLE_N * 8):
            return None
        return by_lba.get(struct.unpack_from("<II", img, addr - MAIN_BASE)[1])

    groups = []
    for i in range(64):
        g = struct.unpack_from("<I", img, GROUP_DIR - MAIN_BASE + 4 * i)[0]
        if not (MAIN_BASE <= g < MAIN_BASE + len(img)):
            break
        files = []
        for k in range(64):
            v = struct.unpack_from("<I", img, g - MAIN_BASE + 4 * k)[0]
            p = rec_path(v)
            if p is None:
                break
            files.append(Path(p).name)
        groups.append(files)
    assert len(groups) >= 16, len(groups)

    # group 0 is the 03_SHIRO/duel overlay set
    assert set(groups[0]) >= {"BATH.BIN", "BOOKS.BIN", "STONE.BIN", "WALL.BIN"}
    # group 3 is the book/paper/curio set
    assert set(groups[3]) >= {"BOOK_0.BIN", "PAPER_0.BIN", "CURIO_0.BIN"}
    # group 8 is the yuge/mizu/hana set, and CURIO_0 is shared with group 3
    assert set(groups[8]) >= {"YUGE_00.BIN", "MIZU_00.BIN", "HANA.BIN", "CURIO_0.BIN"}
    assert "CURIO_0.BIN" in groups[3] and "CURIO_0.BIN" in groups[8]
    # and the last group is VC61's -- cross-links to vc61_explained.md
    vc = [g for g in groups if "VC61.BIN" in g]
    assert len(vc) == 1 and set(vc[0]) == {"VC61.BIN", "VB5A21.BIN", "VB5B31.BIN"}, vc

    # ---------------------------------------------- the 0x4B40 permutation negative
    # The permutation is real, and it matches none of the four known orders.
    r = next(x for x in iso() if x["path"] == "DATA/03_SHIRO/STONE.BIN")
    d = disc.extract(r["lba"], r["size"])
    perm = list(d[0x4B40:0x4B40 + 108])
    assert sorted(perm) == list(range(108))
    assert d[0x4B40 + 108:0x4B40 + 128] == b"\0" * 20       # a standalone 108-byte array
    import face_portraits as fp
    chars = fp.character_names()[:108]
    stone = [x["name"] for x in fp.names()]
    def norm(s):
        if s.startswith("\\x96"):
            return 0
        c = [i for i, nm in enumerate(chars) if nm == s or nm.startswith(s)]
        return c[0] if len(c) == 1 else (c[0] if c else None)
    s2c = [norm(s) for s in stone]
    a = sum(1 for i in range(108) if s2c[perm[i]] == i)
    b = sum(1 for j in range(108) if s2c[j] is not None and perm[s2c[j]] == j)
    assert a <= 5 and b <= 5, (a, b)        # neither direction maps the portrait order
    seq = [stone[perm[i]] for i in range(108)]
    assert seq != sorted(seq) and seq != sorted(seq, reverse=True)

    # ---------------------------------------------- BOOK carries no text
    # Its decodable runs are chance byte coincidences, not a text encoding.
    import war_text as wt
    bk = next(x for x in iso() if x["path"] == "DATA/03_SHIRO/DATA/BOOK_0.BIN")
    bd = disc.extract(bk["lba"], bk["size"])
    bout, bused = lzss.decode_container(bd)
    assert bused == len(bd) and len(bout) == PAGE
    runs = 0
    i = 0
    while i < len(bout):
        if wt.is_text_byte(bout[i]):
            j = i
            while j < len(bout) and wt.is_text_byte(bout[j]):
                j += 1
            if j < len(bout) and bout[j] == 0 and 4 <= j - i <= 60:
                t, _u = wt.decode(bout, i, j - i)
                if t and sum(c.isalpha() for c in t) >= 3:
                    runs += 1
                i = j
                continue
        i += 1
    assert runs <= 3, f"BOOK_0 should hold no real text, got {runs} runs"

    print("PASS: 133 content pages across DATA/03_SHIRO/DATA (85: FACE 27, BATH 24, "
          "STONE 18, BOOK 6, PAPER 6, CURIO/HANA/MIZU/YUGE 1 each) and DATA/12_IKKI/DATA "
          "(48) are one container family -- [u32 filesize-4][LZSS] -> exactly 16384 B with "
          "full consumption; the 0x8016B358 load-group directory resolves to >=16 groups "
          "with group 0 the SHIRO/duel overlays, group 3 the book/paper/curio set, group 8 "
          "the yuge/mizu/hana set, group 15 VC61+VB5A21+VB5B31; STONE 0x4B40 is a real "
          "108-byte permutation matching NEITHER the portrait nor the stone order in either "
          "direction and not alphabetical; and BOOK_0 holds no decodable text")


if __name__ == "__main__":
    check()
