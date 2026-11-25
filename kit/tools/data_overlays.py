#!/usr/bin/env python3
"""The `DATA/**.BIN` overlay population: what each file is, and what reads it.

`archive/docs/disc_inventory.md` carries a residue class, "other data overlays",
recorded as **~102 files, inventoried but never parsed** and called "the
highest-risk area for missed content".  The figure is not reproducible from any
artifact in the tree, so this tool re-derives the population from the disc three
independent ways and classifies every member of it:

1. `kit/extracted/iso_files.json` -- every `DATA/**.BIN` record, sorted by LBA;
2. the master file table in `SLUS_002.92` at `0x8004500c` -- 344 records of
   `[u32 size][u32 lba]`;
3. the master file table in `MAIN.EXE` at `0x80163D64` -- the same table.

All three are byte-identical, and the count is **344**, not ~102.

Each file is then classified from bytes only, with a re-derivable reason:

```
form        Form 1 / Form 2, from the raw MODE2 subheader of every sector
            (submode bit 0x20).  Nothing in this population is Form 2, so no
            file here is CD-XA audio and `disc.extract()` is the right reader.
header      ps-exe | [u32 entry][ASCII name] | pointer-table | self-pointer |
            none -- the first word's relation to the file and the bytes after it
code        aligned `jr $ra` (0x03E00008) and `addiu sp,sp,-N` counts.
            A `jr $ra` inside a `[u32 len][LZSS]` container is NOT code: the
            compressed stream is byte-biased, so one aligned match there is not
            evidence of an instruction (SKY2_1 is the worked counterexample).
container   the file is exactly one aligned `[u32 comp_len][LZSS]` container,
            decoded with `lzss.decode_container` and full consumption of the
            declared region; the decoded size is reported.
pages       page-shaped containers (exactly 16,384 B out = a 128x128 8bpp page)
            reached by a run of consecutive in-file RAM pointers -- a page bank.
sections    `[u16 a][u16 b][u32 magic]` records with magic in 0x8101..0x8107 and
            a <= 0x40, b <= 0x40.  These are the 04_PLAY S1/S2 section headers,
            and they are NOT 04_PLAY-specific.
owner       the 16-entry load-group directory at `0x8016B358`, the 78-entry
            `04_PLAY` id registry at `0x80044D94`, and the per-file dialogue
            sections recorded in `kit/work/decoded_text/dialogue_found.txt`.
```

Usage:
    python3 data_overlays.py                  # the census
    python3 data_overlays.py --list           # one line per file
    python3 data_overlays.py --file VA4B.BIN  # one file's evidence, re-derived
    python3 data_overlays.py --unowned        # the files no table claims
    python3 data_overlays.py --json OUT
    python3 data_overlays.py --verify         # re-derive and assert the census
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
from collections import Counter, defaultdict

import numpy as np

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc          # noqa: E402
import disc_iso      # noqa: E402
import lzss          # noqa: E402
import resource_groups as rg   # noqa: E402

ISO_FILES = os.path.join(_KIT, "extracted", "iso_files.json")
DIALOGUE = os.path.join(_KIT, "work", "decoded_text", "dialogue_found.txt")

#: the two copies of the master file table
SLUS = "SLUS_002.92"
MAIN = "MAIN.EXE"
SLUS_BASE = 0x80010000
MAIN_BASE = 0x800C0800
SLUS_TABLE = 0x8004500C
MAIN_TABLE = 0x80163D64
TABLE_COUNT = 344

#: the 04_PLAY id registry (in SLUS_002.92)
ID_REGISTRY = 0x80044D94
ID_REGISTRY_COUNT = 78

OVERLAY_BASES = (0x80010000, 0x80080000)

JR_RA = 0x03E00008
#: the section-header magic family, established by the `[u16 a<=0x40][u16 b<=0x40]`
#: prefix: 0x8101..0x8107 all validate, 0x8100 and >= 0x8108 do not.
MAGIC_LO, MAGIC_HI = 0x8101, 0x8107
SECTION_DIM_MAX = 0x40

PAGE_BYTES = 16384          # a 128x128 8bpp page
SMALL_PAGE = 4096           # a 64x64 page


# --------------------------------------------------------------------------
# disc reads
# --------------------------------------------------------------------------
def _iso() -> list[dict]:
    return disc_iso.iso_records(ISO_FILES)


def _by_path() -> dict[str, dict]:
    return {r["path"]: r for r in _iso()}


def read(path: str) -> bytes:
    r = _by_path()[path]
    return disc.extract(r["lba"], r["size"])


def image(name: str) -> bytes:
    """The headerless PS-EXE image of `name` (base from its PS-X header)."""
    r = _by_path()[name]
    blob = disc.extract(r["lba"], r["size"])
    return blob[2048:] if blob[:8] == b"PS-X EXE" else blob


# --------------------------------------------------------------------------
# the population, derived three ways
# --------------------------------------------------------------------------
def population() -> list[dict]:
    """Every `DATA/**.BIN` file, sorted by LBA."""
    out = [r for r in _iso()
           if r["path"].endswith(".BIN") and r["path"].startswith("DATA/")]
    out.sort(key=lambda r: r["lba"])
    return out


def master_table(image_name: str, addr: int, base: int) -> list[tuple[int, int]]:
    """`[u32 size][u32 lba]` x 344 from one of the two master file tables."""
    img = image(image_name)
    off = addr - base
    return [struct.unpack_from("<II", img, off + 8 * i)
            for i in range(TABLE_COUNT)]


def population_cross_check() -> dict:
    """Do the two master tables and the ISO listing agree, entry for entry?"""
    iso = [(r["size"], r["lba"]) for r in population()]
    slus = master_table(SLUS, SLUS_TABLE, SLUS_BASE)
    main = master_table(MAIN, MAIN_TABLE, MAIN_BASE)
    return {
        "count_iso": len(iso),
        "count_slus": len(slus),
        "count_main": len(main),
        "slus_equals_main": slus == main,
        "table_equals_iso": slus == iso,
        "ok": len(iso) == TABLE_COUNT and slus == main == iso,
    }


def id_registry() -> list[dict]:
    """The 78-entry `04_PLAY` overlay-id registry, re-derived from SLUS."""
    img = image(SLUS)
    off = ID_REGISTRY - SLUS_BASE
    iso = _by_path()
    by_lba = {r["lba"]: r["path"] for r in iso.values()}
    out = []
    for i in range(ID_REGISTRY_COUNT):
        oid, desc = struct.unpack_from("<II", img, off + 8 * i)
        size, lba = struct.unpack_from("<II", img, desc - SLUS_BASE)
        out.append({"id": oid, "desc": desc, "size": size, "lba": lba,
                    "path": by_lba.get(lba)})
    return out


def load_groups() -> list[dict]:
    """The 16-entry `0x8016B358` directory, each group's file records."""
    return rg.groups()


def dialogue_files() -> dict[str, int]:
    """overlay basename -> dialogue string count, from the decoded corpus."""
    out: dict[str, int] = {}
    if not os.path.exists(DIALOGUE):
        return out
    with open(DIALOGUE, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    for m in re.finditer(r"^--- ([A-Z0-9]+\.BIN) \((\d+) dialogue strings\) ---",
                         text, re.M):
        out[m.group(1)] = int(m.group(2))
    return out


# --------------------------------------------------------------------------
# per-file facts
# --------------------------------------------------------------------------
def sector_forms(lba: int, size: int) -> Counter:
    """Count Form 1 / Form 2 sectors by reading the raw MODE2 subheader.

    `disc.extract()` returns the Form 1 user field regardless, so a Form 2 file
    read through it desynchronises by 276 B/sector.  This is the check that
    says whether that can happen: raw byte 15 is the mode, bytes 16..23 the
    subheader, and submode bit 0x20 marks Form 2.
    """
    img, sector, off = disc.resolve_raw()
    nsec = (size + 2047) // 2048
    forms: Counter = Counter()
    with open(img, "rb") as fh:
        for i in range(nsec):
            fh.seek((lba + i) * sector + 15)
            hdr = fh.read(8)
            if len(hdr) < 8:
                forms["short"] += 1
                continue
            forms["Form2" if hdr[2] & 0x20 else "Form1"] += 1
    return forms


def _words(data: bytes) -> np.ndarray:
    n = len(data) - (len(data) % 4)
    return np.frombuffer(data[:n], dtype="<u4")


def code_evidence(data: bytes) -> dict:
    """Aligned `jr $ra` and `addiu sp,sp,-N` counts and the first hit offset."""
    w = _words(data)
    if not len(w):
        return {"jr": 0, "prologue": 0, "first_jr": None}
    jr = np.flatnonzero(w == JR_RA)
    pro = np.flatnonzero((w >> 16) == 0x27BD)
    pro = pro[np.flatnonzero(w[pro] & 0x8000)] if len(pro) else pro
    return {"jr": int(len(jr)), "prologue": int(len(pro)),
            "first_jr": int(jr[0] * 4) if len(jr) else None}


def container(data: bytes) -> dict | None:
    """Exactly one aligned `[u32 comp_len][LZSS]` container for the whole file."""
    try:
        out, used = lzss.decode_container(data, 0)
    except Exception:
        return None
    if used != len(data):
        return None
    return {"comp_len": len(data) - 4, "out_len": len(out), "used": used,
            "page": len(out) in (PAGE_BYTES, SMALL_PAGE)}


def _container_at(data: bytes, off: int, lo: int = 0x300, hi: int = 0x5000):
    """(out_len, used) for an aligned container at `off`, or None.

    `lo`/`hi` are a *precondition* on the declared compressed length, not the
    test: every 16,384-byte page container measured in this population declares
    between `0x46C` and `0x409F`, so a candidate outside `[0x300, 0x5000]` is
    rejected before the decoder is asked.  The test itself is still "decodes to
    a 16,384-byte page with full consumption of the declared region".
    """
    if off % 4 or off + 4 > len(data):
        return None
    ln = struct.unpack_from("<I", data, off)[0]
    if not (lo <= ln <= hi) or off + 4 + ln > len(data):
        return None
    try:
        out, used = lzss.decode_container(data, off)
    except Exception:
        return None
    return (len(out), used)


def page_bank(data: bytes) -> dict | None:
    """A run of consecutive in-file RAM pointers whose targets are pages.

    Scans pointer tables, not containers: the two methods are independent, which
    is why a bank found this way corroborates the container-scan tool
    (`area_page_banks.py`) rather than repeating it.
    """
    n = len(data)
    w = _words(data)
    if not len(w):
        return None
    memo: dict[int, int] = {}

    def out_len(off: int) -> int:
        if off not in memo:
            memo[off] = (_container_at(data, off) or (0, 0))[0]
        return memo[off]

    best = None
    for base in OVERLAY_BASES:
        sel = [int(i) for i in np.flatnonzero((w >= base + 4) & (w < base + n))]
        runs: list[list[int]] = []
        run: list[int] = []
        for idx in sel:
            if run and idx != run[-1] + 1:
                runs.append(run)
                run = []
            run.append(idx)
        if run:
            runs.append(run)
        # longest first, so a bound on the remaining runs prunes almost all of
        # them without decoding anything (a run of L entries holds <= L pages).
        runs.sort(key=len, reverse=True)
        for run in runs:
            if len(run) < 2:
                break
            if best is not None and len(run) <= best["page_count"]:
                break
            hits = [(k, int(w[j]) - base) for k, j in enumerate(run)
                    if out_len(int(w[j]) - base) == PAGE_BYTES]
            if len(hits) < 2:
                continue
            # the page pointers form their own consecutive table; take the
            # longest consecutive block of them.
            block: list[tuple[int, int]] = []
            cur: list[tuple[int, int]] = []
            for k, off in hits:
                if cur and k != cur[-1][0] + 1:
                    if len(cur) > len(block):
                        block = cur
                    cur = []
                cur.append((k, off))
            if len(cur) > len(block):
                block = cur
            if len(block) >= 2 and (best is None or len(block) > best["page_count"]):
                best = {"base": base, "table": run[block[0][0]] * 4,
                        "count": len(block), "run": len(run),
                        "pages": [off for _k, off in block],
                        "page_count": len(block)}
    return best


def header_form(data: bytes) -> dict:
    """The file's first-word relation to itself, and the ASCII name if present."""
    n = len(data)
    out = {"form": "none", "word0": None, "entry": None, "name": None,
           "ptr_run": 0}
    if n < 4:
        return out
    w0 = struct.unpack_from("<I", data, 0)[0]
    out["word0"] = w0
    if data[:8] == b"PS-X EXE":
        out["form"] = "ps-exe"
        return out
    # a monotone run of base-relative self-pointers from offset 0
    run, prev = 0, -1
    i = 0
    while i + 4 <= n:
        w = struct.unpack_from("<I", data, i)[0]
        off = None
        for b in OVERLAY_BASES:
            if b + 4 <= w < b + n:
                off = w - b
        if off is not None and off > prev:
            run += 1
            prev = off
            i += 4
        else:
            break
    out["ptr_run"] = run
    entry = None
    for b in OVERLAY_BASES:
        if b + 4 <= w0 < b + n:
            entry = w0 - b
    out["entry"] = entry
    name = None
    if entry is not None:
        raw = bytearray()
        for c in data[4:68]:
            if c == 0:
                break
            raw.append(c)
        if len(raw) >= 3 and all(32 <= c < 127 for c in raw[:-1]) \
                and (32 <= raw[-1] < 127 or raw[-1] == 0x0A):
            name = raw.decode("latin1")
    out["name"] = name
    if entry is not None and name:
        out["form"] = "entry-name"
    elif run >= 2:
        out["form"] = "pointer-table"
    elif entry is not None:
        out["form"] = "self-pointer"
    return out


def sections(data: bytes) -> list[dict]:
    """`[u16 a][u16 b][u32 magic]` records, magic in the validated family."""
    n = len(data)
    w = _words(data)
    out = []
    if not len(w):
        return out
    lo = np.flatnonzero((w >= MAGIC_LO) & (w <= MAGIC_HI))
    for idx in lo:
        idx = int(idx)
        off = idx * 4
        if off < 4 or off + 4 > n:
            continue
        a, b = struct.unpack_from("<HH", data, off - 4)
        if a <= SECTION_DIM_MAX and b <= SECTION_DIM_MAX:
            out.append({"off": off, "magic": int(w[idx]), "a": a, "b": b})
    return out


def family(path: str) -> str:
    base = os.path.basename(path)
    d = os.path.dirname(path)
    if path.startswith("DATA/04_PLAY/"):
        return "04_PLAY"
    if d.endswith("/DATA") and "12_IKKI" in d:
        if base.startswith("BT"):
            return "BT"
        if base.startswith("IC_"):
            return "IC"
        if base.startswith("SKY"):
            return "SKY"
    if d.endswith("03_SHIRO/DATA"):
        for pre, name in (("FACE_", "FACE"), ("STONE_", "STONE"),
                          ("BATH_", "BATH"), ("BOOK_", "BOOK"),
                          ("PAPER_", "PAPER"), ("YUGE_", "YUGE"),
                          ("MIZU_", "MIZU")):
            if base.startswith(pre):
                return name
        if base.startswith("HANA"):
            return "HANA"
        if base.startswith("CURIO"):
            return "CURIO"
    if d.endswith("16_WAR"):
        return "WAR"
    if "_AREA." in d:
        return "area-overlay"
    if "03_SHIRO" in d:
        return "shiro-overlay"
    if "00_INIT" in d:
        return "init"
    if "05_BATLE" in d:
        return "battle"
    if "12_IKKI" in d:
        return "ikki-overlay"
    return "root"


# --------------------------------------------------------------------------
# classification
# --------------------------------------------------------------------------
def classify(rec: dict) -> str:
    """The file's container kind.

    This is deliberately *not* exclusive with `holds_pages`: an overlay can be a
    code module and carry a sprite-section page bank at the same time (VA1 is
    both), so the page bank is recorded as a property, not as a class.
    """
    base = os.path.basename(rec["path"])
    if rec["family"] == "04_PLAY":
        return "character-sprite"
    if rec["container"] and rec["container"]["out_len"] == PAGE_BYTES:
        return "atlas-page"
    if base == "SEQ.BIN":
        return "music"
    if base == "BATTLE.BIN":
        return "sprite-archive"
    if base == "W_HEADER.BIN":
        return "header"
    if rec["size"] <= 16:
        return "stub"
    if rec["code"]["jr"] >= 1:
        return "code-overlay"
    return "data-module"


def build() -> dict:
    """The whole census, re-derived from the disc."""
    dial = dialogue_files()
    groups = load_groups()
    group_of = {}
    for g in groups:
        for f in g["files"]:
            if f["path"]:
                group_of[f["path"]] = g["index"]
    idreg = {r["path"]: r["id"] for r in id_registry() if r["path"]}

    records = []
    for r in population():
        path = r["path"]
        data = read(path)
        cont = container(data)
        bank = page_bank(data)
        code = code_evidence(data)
        secs = sections(data)
        base = os.path.basename(path)
        rec = {
            "path": path,
            "lba": r["lba"],
            "size": r["size"],
            "family": family(path),
            "forms": dict(sector_forms(r["lba"], r["size"])),
            "header": header_form(data),
            "code": code,
            "container": cont,
            "bank": bank,
            "sections": len(secs),
            "section_magics": sorted({s["magic"] for s in secs}),
            "group": group_of.get(path),
            "play_id": idreg.get(path),
            "dialogue_strings": dial.get(base),
        }
        rec["class"] = classify(rec)
        rec["code_in_container"] = bool(cont and cont["out_len"] == PAGE_BYTES
                                        and code["jr"] >= 1)
        # "no engine table claims it": not in the 0x8016B358 directory, not one
        # of the 78 id-registry sprites, not a decoded dialogue overlay, not a
        # whole-file container, and not a code module.  An *in-file* pointer
        # table is not an engine owner, so a page bank does not clear this.
        rec["unowned"] = (rec["group"] is None and path not in idreg
                          and rec["dialogue_strings"] is None
                          and not cont and code["jr"] == 0)
        records.append(rec)

    classes = Counter(r["class"] for r in records)
    banks = [r for r in records if r["bank"]]
    return {
        "population": len(records),
        "cross_check": population_cross_check(),
        "classes": dict(sorted(classes.items())),
        "bank_files": len(banks),
        "bank_pages": sum(r["bank"]["page_count"] for r in banks),
        "section_files": sum(1 for r in records if r["sections"]),
        "section_records": sum(r["sections"] for r in records),
        "code_files": sum(1 for r in records
                          if r["code"]["jr"] >= 1 and not r["container"]),
        "code_in_container": sum(1 for r in records
                                 if r["code"]["jr"] >= 1 and r["container"]),
        "pages_total": sum(1 for r in records
                           if r["container"]
                           and r["container"]["out_len"] == PAGE_BYTES)
        + sum(r["bank"]["page_count"] for r in banks),
        "dialogue_files": sum(1 for r in records
                              if r["dialogue_strings"] is not None),
        "unowned": sorted(r["path"] for r in records if r["unowned"]),
        "records": records,
        "load_groups": [{"index": g["index"], "files": [f["path"] for f in g["files"]]}
                        for g in groups],
        "id_registry": id_registry(),
    }


# --------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------
def verify(verbose: bool = True) -> int:
    """Re-derive the census and assert the invariants it rests on.

    Returns the number of failures (0 = PASS).
    """
    fails = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if verbose:
            print(("PASS: " if cond else "FAIL: ") + name + (" -- " + detail if detail else ""))
        if not cond:
            fails.append(name)

    out = build()
    recs = out["records"]
    by_path = {r["path"]: r for r in recs}
    ck = out["cross_check"]

    check("population is 344 `DATA/**.BIN` files", len(recs) == 344,
          "count=%d" % len(recs))
    check("SLUS master table == MAIN master table == ISO listing",
          bool(ck["ok"]), json.dumps(ck))
    check("SLUS and MAIN tables are byte-identical", ck["slus_equals_main"])

    check("every overlay is MODE2 Form 1 (none is CD-XA audio)",
          all(set(r["forms"]) == {"Form1"} for r in recs),
          "non-Form-1: %s" % [r["path"] for r in recs
                              if set(r["forms"]) != {"Form1"}][:5])

    groups = out["load_groups"]
    members = sorted({p for g in groups for p in g["files"]})
    check("the 0x8016B358 directory has 16 groups", len(groups) == 16)
    check("the directory lists 144 distinct files", len(members) == 144,
          "count=%d" % len(members))
    check("every directory member is in the population",
          all(p in by_path for p in members))

    pages = [r for r in recs if r["class"] == "atlas-page"]
    check("133 files are exactly one [u32 comp_len][LZSS] container", len(pages) == 133,
          "count=%d" % len(pages))
    check("each of those decodes to exactly 16,384 B (128x128 8bpp)",
          all(r["container"]["out_len"] == PAGE_BYTES for r in pages))
    check("every atlas page is owned by the 0x8016B358 directory",
          all(r["group"] is not None for r in pages))
    dir_classes = Counter(by_path[p]["class"] for p in members)
    check("the 144 directory members are 133 pages + 8 code overlays + 3 data modules",
          dir_classes == {"atlas-page": 133, "code-overlay": 8,
                          "data-module": 3},
          json.dumps(dict(dir_classes)))

    play = [r for r in recs if r["class"] == "character-sprite"]
    check("78 files are the DATA/04_PLAY character containers", len(play) == 78,
          "count=%d" % len(play))
    check("the 78-entry id registry resolves to those same 78 files",
          {r["path"] for r in play} ==
          {r["path"] for r in out["id_registry"] if r["path"]})

    check("103 files contain at least one aligned `jr $ra`",
          out["code_files"] == 103, "count=%d" % out["code_files"])

    # the S1/S2 section record, and that it is not 04_PLAY-specific
    with_sec = [r for r in recs if r["sections"]]
    outside = [r for r in with_sec if r["family"] != "04_PLAY"]
    check("section records occur in 177 files", len(with_sec) == 177,
          "count=%d" % len(with_sec))
    check("99 of those files are outside DATA/04_PLAY", len(outside) == 99,
          "count=%d" % len(outside))
    check("the whole population carries 1345 validated section records",
          out["section_records"] == 1345, "count=%d" % out["section_records"])
    check("every 04_PLAY file carries exactly two section records",
          all(r["sections"] == 2 for r in play))

    # the code test must not be applied inside a compressed stream
    sky = by_path.get("DATA/12_IKKI/DATA/SKY2_1.BIN")
    check("SKY2_1 is one exact container (so its jr $ra is inside the bitstream)",
          bool(sky and sky["container"] and sky["container"]["out_len"] == PAGE_BYTES
               and sky["code"]["jr"] == 1))
    check("SKY2_1 is classified as an atlas page, not as code",
          bool(sky and sky["class"] == "atlas-page"))

    # VC61's page bank, and the bank instrument generally
    vc = by_path.get("DATA/06_AREA.C/VC61.BIN")
    check("VC61 holds a 4-entry page table at file 0xA94",
          bool(vc and vc["bank"] and vc["bank"]["page_count"] == 4
               and vc["bank"]["table"] == 0xA94),
          json.dumps(vc["bank"]) if vc else "missing")
    vd = read(vc["path"]) if vc else b""
    check("VC61's four pages each decode to 16,384 B",
          bool(vc and all((_container_at(vd, o) or (0, 0))[0] == PAGE_BYTES
                          for o in vc["bank"]["pages"])))
    va4 = by_path.get("DATA/01_AREA.A/VA4B.BIN")
    check("VA4B holds a 9-entry page table at file 0x1479C",
          bool(va4 and va4["bank"] and va4["bank"]["page_count"] == 9
               and va4["bank"]["table"] == 0x1479C),
          json.dumps(va4["bank"]) if va4 else "missing")
    check("118 files hold a pointer-addressed page bank, 886 pages in all",
          out["bank_files"] == 118 and out["bank_pages"] == 886,
          "%d files, %d pages" % (out["bank_files"], out["bank_pages"]))
    check("the population holds 1,019 page-shaped containers (133 + 886)",
          out["pages_total"] == 1019, "count=%d" % out["pages_total"])
    check("no file's page bank lists the same page offset twice",
          all(len(set(r["bank"]["pages"])) == r["bank"]["page_count"]
              for r in recs if r["bank"]))

    # the unowned residual
    expected = sorted([
        "DATA/00_INIT/BATTLE.BIN", "DATA/00_INIT/SEQ.BIN",
        "DATA/02_AREA.B/J_DATA.BIN", "DATA/02_AREA.B/VB5I0.BIN",
        "DATA/02_AREA.B/VB5I2.BIN", "DATA/02_AREA.B/VB5I3.BIN",
        "DATA/02_AREA.B/VB5I4.BIN", "DATA/06_AREA.C/VCD.BIN",
        "DATA/13_AREA.I/I_DATA.BIN", "DATA/16_WAR/W_HEADER.BIN",
    ])
    check("exactly 10 files have no engine-table owner, and they are the known ten",
          out["unowned"] == expected, json.dumps(out["unowned"]))

    check("class counts sum to the population",
          sum(out["classes"].values()) == len(recs))
    return len(fails)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _line(r: dict) -> str:
    cont = r["container"]
    bits = [r["class"]]
    if cont:
        bits.append("container=%d->%d" % (cont["comp_len"], cont["out_len"]))
    if r["bank"]:
        bits.append("bank=%d@0x%X" % (r["bank"]["page_count"], r["bank"]["table"]))
    if r["code"]["jr"]:
        bits.append("jr=%d" % r["code"]["jr"])
    if r["sections"]:
        bits.append("sec=%d" % r["sections"])
    if r["group"] is not None:
        bits.append("group=%d" % r["group"])
    if r["dialogue_strings"] is not None:
        bits.append("dialogue=%d" % r["dialogue_strings"])
    return "%-16s %-40s %8d  %s" % (
        bits[0], r["path"], r["size"], " ".join(bits[1:]))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="one line per file")
    ap.add_argument("--file", help="re-derive one file's evidence")
    ap.add_argument("--unowned", action="store_true",
                    help="files no table claims")
    ap.add_argument("--json", help="write the census as JSON")
    ap.add_argument("--verify", action="store_true",
                    help="re-derive and assert the census")
    args = ap.parse_args(argv)

    if args.verify:
        n = verify()
        print("data_overlays --verify: %s" % ("PASS" if n == 0 else "%d FAIL" % n))
        return 1 if n else 0

    if args.file:
        want = args.file
        out = build()
        hit = [r for r in out["records"]
               if r["path"] == want or os.path.basename(r["path"]) == want]
        if not hit:
            print("no such overlay: %s" % want)
            return 1
        for r in hit:
            print(json.dumps(r, indent=1))
        return 0

    out = build()
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=1)
        print("wrote %s" % args.json)
        return 0

    if args.unowned:
        for r in out["records"]:
            if r["unowned"]:
                print(_line(r))
        return 0

    if args.list:
        for r in out["records"]:
            print(_line(r))
        return 0

    ck = out["cross_check"]
    print("overlay population (DATA/**.BIN): %d files" % out["population"])
    print("  ISO listing %d == SLUS table %d == MAIN table %d : %s"
          % (ck["count_iso"], ck["count_slus"], ck["count_main"],
             "byte-identical" if ck["ok"] else "MISMATCH"))
    print("classes:")
    for k, v in sorted(out["classes"].items(), key=lambda kv: -kv[1]):
        print("  %5d  %s" % (v, k))
    print("code-bearing files (>=1 aligned `jr $ra`): %d" % out["code_files"])
    print("files with a pointer-addressed page bank: %d (%d pages)"
          % (out["bank_files"], out["bank_pages"]))
    print("files with dialogue sections: %d" % out["dialogue_files"])
    print("section-record files: %d (%d outside DATA/04_PLAY), %d records"
          % (out["section_files"],
             sum(1 for r in out["records"] if r["sections"]
                 and r["family"] != "04_PLAY"),
             out["section_records"]))
    print("files no engine table claims: %d" % len(out["unowned"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
