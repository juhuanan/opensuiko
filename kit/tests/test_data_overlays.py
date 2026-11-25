#!/usr/bin/env python3
"""The `DATA/**.BIN` overlay population: independent re-derivation.

Everything here is re-implemented from the disc with `disc` + `lzss` + plain
`struct`/`numpy`; `kit/tools/data_overlays.py` is not imported, so a bug in the
tool cannot make this pass. Disc required. Run:

    python3 kit/tests/test_data_overlays.py

What is asserted, and why each is a fact rather than a reading:

* the population is **344** files, and three independent sources agree byte for
  byte (the ISO listing, the master file table in `SLUS_002.92` at `0x8004500c`,
  the same table in `MAIN.EXE` at `0x80163D64`);
* every one of the 344 is MODE2 **Form 1** in every sector, so nothing here is
  CD-XA audio read through the Form 1 user field;
* **133** files are exactly one `[u32 comp_len][LZSS]` container and each
  decodes to exactly **16,384** B with full consumption of the declared region;
* **104** files contain an aligned `jr $ra`, of which **1** is a page container
  (`SKY2_1`) whose match is inside the LZSS bitstream and is therefore not code
  -- so only 103 files are code, and the code test must not run on compressed
  bytes;
* the `[u16 a][u16 b][u32 magic]` section record with magic `0x8101..0x8107` and
  `a, b <= 0x40` occurs **1,345** times across **177** overlays;
* **118** overlays hold a pointer-addressed page bank (a run of consecutive
  4-byte in-file pointers, each target a 16,384-byte container), **886** pages
  in all -- with the 133 whole-file containers, **1,019** page-shaped containers
  in the population;
* **78** overlays are the `DATA/04_PLAY` character containers, and the 78-entry
  id registry at `0x80044D94` resolves to exactly those files;
* `VC61.BIN`, the last file the corpus listed as unexplained, holds a 4-entry
  page table at file `0xA94` and its four targets decode to 16,384 B each;
* exactly **10** overlays are claimed by no engine table, and they are the ten
  the corpus already names individually;
* the `class` column of `kit/extracted/bin_overlay_inventory_final.csv`
  disagrees with the `jr $ra` test on **82** of the 344 files, which is why the
  "~102 DATA/TABLE overlays" figure built on it is not a set.
"""
from pathlib import Path
import csv
import json
import os
import re
import struct
import sys

import numpy as np

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import lzss  # noqa: E402

SLUS_BASE, MAIN_BASE = 0x80010000, 0x800C0800
SLUS_TABLE, MAIN_TABLE = 0x8004500C, 0x80163D64
GROUP_DIR = 0x8016B358
ID_REGISTRY, ID_COUNT = 0x80044D94, 78
TABLE_COUNT = 344
JR_RA = 0x03E00008
PAGE = 16384
#: precondition only: every page container measured declares 0x46C..0x409F
COMP_LO, COMP_HI = 0x300, 0x5000
MAGIC_LO, MAGIC_HI = 0x8101, 0x8107
DIM_MAX = 0x40
BASES = (0x80010000, 0x80080000)

UNOWNED = [
    "DATA/00_INIT/BATTLE.BIN",
    "DATA/00_INIT/SEQ.BIN",
    "DATA/02_AREA.B/J_DATA.BIN",
    "DATA/02_AREA.B/VB5I0.BIN",
    "DATA/02_AREA.B/VB5I2.BIN",
    "DATA/02_AREA.B/VB5I3.BIN",
    "DATA/02_AREA.B/VB5I4.BIN",
    "DATA/06_AREA.C/VCD.BIN",
    "DATA/13_AREA.I/I_DATA.BIN",
    "DATA/16_WAR/W_HEADER.BIN",
]


def iso() -> list[dict]:
    with open(_KIT / "extracted" / "iso_files.json", encoding="utf-8") as fh:
        return [r for r in json.load(fh) if not r.get("dir")]


def blob(path: str) -> bytes:
    rec = next(r for r in iso() if r["path"] == path)
    return disc.extract(rec["lba"], rec["size"])


def image(name: str) -> bytes:
    return blob(name)[2048:]


def population() -> list[dict]:
    return sorted((r for r in iso()
                   if r["path"].startswith("DATA/") and r["path"].endswith(".BIN")),
                  key=lambda r: r["lba"])


def words(data: bytes) -> np.ndarray:
    n = len(data) - (len(data) % 4)
    return np.frombuffer(data[:n], dtype="<u4")


def page_container(data: bytes, off: int):
    """The preconditioned page-container test, re-implemented from scratch."""
    if off % 4 or off + 8 > len(data):
        return None
    ln = struct.unpack_from("<I", data, off)[0]
    if not (COMP_LO <= ln <= COMP_HI) or off + 4 + ln > len(data):
        return None
    try:
        out, used = lzss.decode_container(data, off)
    except Exception:
        return None
    return len(out)


def bank_size(data: bytes) -> int:
    """Longest run of consecutive 4-byte in-file pointers whose targets are pages."""
    n = len(data)
    w = words(data)
    if not len(w):
        return 0
    memo: dict[int, int] = {}
    best = 0
    for base in BASES:
        sel = [int(i) for i in np.flatnonzero((w >= base + 4) & (w < base + n))]
        runs: list[list[int]] = []
        run: list[int] = []
        for i in sel:
            if run and i != run[-1] + 1:
                runs.append(run)
                run = []
            run.append(i)
        if run:
            runs.append(run)
        for run in sorted(runs, key=len, reverse=True):
            if len(run) < 2 or len(run) <= best:
                break
            block = 0
            for i in run:
                off = int(w[i]) - base
                if off not in memo:
                    memo[off] = page_container(data, off) or 0
                block = block + 1 if memo[off] == PAGE else 0
                best = max(best, block)
    return best


def section_records(data: bytes) -> int:
    w = words(data)
    k = 0
    for idx in np.flatnonzero((w >= MAGIC_LO) & (w <= MAGIC_HI)):
        o = int(idx) * 4
        if o < 4:
            continue
        a, b = struct.unpack_from("<HH", data, o - 4)
        if a <= DIM_MAX and b <= DIM_MAX:
            k += 1
    return k


def check() -> None:
    # ---- the population, three ways -------------------------------------
    pop = population()
    iso_tbl = [(r["size"], r["lba"]) for r in pop]
    si, mi = image("SLUS_002.92"), image("MAIN.EXE")
    slus = [struct.unpack_from("<II", si, SLUS_TABLE - SLUS_BASE + 8 * i)
            for i in range(TABLE_COUNT)]
    main = [struct.unpack_from("<II", mi, MAIN_TABLE - MAIN_BASE + 8 * i)
            for i in range(TABLE_COUNT)]
    assert len(pop) == 344, len(pop)
    assert slus == main == iso_tbl, "the two master tables and the ISO listing differ"
    print("PASS: overlay population is 344 `DATA/**.BIN` files, and the SLUS "
          "master table @0x8004500C, the MAIN master table @0x80163D64 and the "
          "ISO listing are byte-identical (344 records of [u32 size][u32 lba])")

    # ---- sector form ----------------------------------------------------
    img, sector, _off = disc.resolve_raw()
    form2 = []
    with open(img, "rb") as fh:
        for r in pop:
            for i in range((r["size"] + 2047) // 2048):
                fh.seek((r["lba"] + i) * sector + 15)
                if fh.read(8)[2] & 0x20:
                    form2.append((r["path"], i))
                    break
    assert not form2, form2[:5]
    print("PASS: every sector of all 344 overlays is MODE2 Form 1 (submode bit "
          "0x20 clear), so none is CD-XA audio read through the Form 1 user field")

    # ---- per-file facts -------------------------------------------------
    by_lba = {r["lba"]: r["path"] for r in pop}
    single_page, jr_all, jr_in_container = set(), set(), []
    sec_files, sec_records = 0, 0
    bank_files, bank_pages = 0, 0
    for r in pop:
        d = blob(r["path"])
        n = len(d)
        whole = None
        try:
            out, used = lzss.decode_container(d, 0)
        except Exception:
            out, used = None, 0
        if used == n and out is not None:
            assert len(out) == PAGE, (r["path"], len(out))
            single_page.add(r["path"])
            whole = r["path"]
        w = words(d)
        if len(w) and bool((w == JR_RA).any()):
            jr_all.add(r["path"])
            if whole:
                jr_in_container.append(r["path"])
        k = section_records(d)
        if k:
            sec_files += 1
            sec_records += k
        nb = bank_size(d)
        if nb >= 2:
            bank_files += 1
            bank_pages += nb

    assert len(single_page) == 133, len(single_page)
    print("PASS: 133 overlays are exactly one `[u32 comp_len][LZSS]` container, "
          "each decoding to exactly 16,384 B with full consumption of the "
          "declared region (a 128x128 8bpp page)")

    assert len(jr_all) == 104, len(jr_all)
    assert jr_in_container == ["DATA/12_IKKI/DATA/SKY2_1.BIN"], jr_in_container
    code_files = len(jr_all) - len(jr_in_container)
    assert code_files == 103
    print("PASS: 104 overlays contain an aligned `jr $ra`, and exactly one of "
          "them (SKY2_1) is a page container whose match sits inside the LZSS "
          "bitstream -- so only 103 files are code, and the code test must not "
          "be run on compressed bytes")

    assert sec_files == 177 and sec_records == 1345, (sec_files, sec_records)
    print("PASS: the `[u16 a][u16 b][u32 magic]` section record with magic "
          "0x8101..0x8107 and a,b <= 0x40 occurs 1345 times in 177 overlays")

    assert bank_files == 118 and bank_pages == 886, (bank_files, bank_pages)
    assert len(single_page) + bank_pages == 1019
    print("PASS: 118 overlays hold a pointer-addressed page bank (consecutive "
          "4-byte in-file pointers, every target a 16,384-byte container), 886 "
          "pages in all -- with the 133 whole-file containers, 1,019 "
          "page-shaped containers in the population")

    # ---- 04_PLAY and its id registry ------------------------------------
    play = sorted(r["path"] for r in pop if r["path"].startswith("DATA/04_PLAY/"))
    reg = []
    for i in range(ID_COUNT):
        _oid, desc = struct.unpack_from("<II", si, ID_REGISTRY - SLUS_BASE + 8 * i)
        lba = struct.unpack_from("<I", si, desc - SLUS_BASE + 4)[0]
        reg.append(by_lba[lba])
    assert len(play) == 78 and sorted(reg) == play, (len(play), len(reg))
    print("PASS: 78 overlays are `DATA/04_PLAY` character containers, and the "
          "78-entry id registry @0x80044D94 resolves to exactly those files")

    # ---- the last unexplained file is a page bank -----------------------
    vc = blob("DATA/06_AREA.C/VC61.BIN")
    table = [struct.unpack_from("<I", vc, 0xA94 + 4 * i)[0] - 0x80080000
             for i in range(4)]
    assert table == [0xABC, 0x1960, 0x27E0, 0x361C], [hex(x) for x in table]
    assert [page_container(vc, o) for o in table] == [PAGE] * 4
    va = blob("DATA/01_AREA.A/VA4B.BIN")
    vtable = [struct.unpack_from("<I", va, 0x1479C + 4 * i)[0] - 0x80010000
              for i in range(9)]
    assert [page_container(va, o) for o in vtable] == [PAGE] * 9
    print("PASS: VC61.BIN -- the corpus's last unexplained overlay -- holds a "
          "4-entry page table at file 0xA94 (0xABC/0x1960/0x27E0/0x361C) and all "
          "four decode to 16,384 B; VA4B's 9-entry table at 0x1479C does the same")

    # ---- the unowned residual -------------------------------------------
    groups = set()
    for i in range(16):
        g = struct.unpack_from("<I", mi, GROUP_DIR - MAIN_BASE + 4 * i)[0]
        for k in range(64):
            v = struct.unpack_from("<I", mi, g - MAIN_BASE + 4 * k)[0]
            if not (MAIN_TABLE <= v < MAIN_TABLE + TABLE_COUNT * 8):
                break
            lba = struct.unpack_from("<I", mi, v - MAIN_BASE + 4)[0]
            groups.add(by_lba[lba])
    reg_set = set(reg)
    # the dialogue consumer is the fourth owner: the corpus records one decoded
    # section per dialogue overlay in this tracked file.
    corpus = (_KIT / "work" / "decoded_text" / "dialogue_found.txt").read_text(
        encoding="utf-8", errors="replace")
    dialogue = {m.group(1) for m in
                re.finditer(r"^--- ([A-Z0-9]+\.BIN) \(\d+ dialogue", corpus, re.M)}
    assert len(dialogue) == 79, len(dialogue)
    unowned = sorted(r["path"] for r in pop
                     if r["path"] not in groups and r["path"] not in reg_set
                     and r["path"] not in single_page
                     and r["path"] not in jr_all
                     and os.path.basename(r["path"]) not in dialogue)
    assert unowned == UNOWNED, unowned
    print("PASS: exactly 10 overlays are claimed by no engine table and no "
          "dialogue consumer (not in the 0x8016B358 directory, not an "
          "id-registry sprite, not a whole-file container, no code), and they "
          "are the ten the corpus already names individually")

    # ---- the `class` column the "~102" rests on is unsound ---------------
    with open(_KIT / "extracted" / "bin_overlay_inventory_final.csv",
              encoding="utf-8") as fh:
        inv = {row["file"]: row for row in csv.DictReader(fh)}
    assert len(inv) == 344
    disagree = sorted(p for p, row in inv.items()
                      if (row["class"] == "CODE") != (p in jr_all))
    assert len(disagree) == 82, len(disagree)
    data_table_with_code = sorted(p for p, row in inv.items()
                                  if row["class"] == "DATA/TABLE" and p in jr_all)
    assert data_table_with_code == ["DATA/01_AREA.A/VA4B.BIN",
                                    "DATA/12_IKKI/DATA/SKY2_1.BIN"]
    n_dt = sum(1 for row in inv.values() if row["class"] == "DATA/TABLE")
    assert n_dt == 233, n_dt
    print("PASS: `bin_overlay_inventory_final.csv` labels 233 of 344 overlays "
          "`DATA/TABLE` and its `class` column disagrees with the `jr $ra` test "
          "on 82 files, including two labelled DATA/TABLE that carry code bytes "
          "(VA4B's four one-instruction stub entries at offsets 4/12/20/28, and "
          "SKY2_1's single hit inside a compressed stream) -- so the class "
          "column, and the `~102` figure built on it, is not reproducible as a set")


if __name__ == "__main__":
    check()
