#!/usr/bin/env python3
"""Coverage census: which disc files have a *known* format, and which do not.

This is a gap report, not a decoder.  It walks every file in
`kit/extracted/iso_files.json`, runs a set of **format detectors** that this
project has actually proven (see `kit/docs/PIPELINE.md`), and reports:

* a per-directory census of known formats, and
* the files that **no** detector claims -- the honest unknown list.

A file is only labelled when a detector proves the format, so "unknown" means
"nothing this kit can currently identify", not "uninteresting".

Usage:
    python3 asset_coverage.py                 # per-directory census + unknowns
    python3 asset_coverage.py --unknowns      # just the unknown files
    python3 asset_coverage.py --dir DATA/03_SHIRO/DATA
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402
import lzss  # noqa: E402

ISO = os.path.join(_KIT, "extracted", "iso_files.json")
OVERLAY_BASE = 0x80010000
MAX_READ = 8 << 20        # only sniff the head of huge files


def iso_files() -> list[dict]:
    with open(ISO) as f:
        return [r for r in json.load(f) if not r.get("dir")]


def head(rec: dict) -> bytes:
    n = min(rec["size"], MAX_READ)
    return disc.extract(rec["lba"], n)


# --------------------------------------------------------------------------
# detectors: each returns a label or None.  They are deliberately strict.
# --------------------------------------------------------------------------

def det_shiftjis_text(d: bytes, rec: dict):
    """A CP932/Shift-JIS document.  `DATA/00_INIT/SOUND.573` is one."""
    if len(d) < 512:
        return None
    try:
        t = d.decode("cp932")
    except Exception:
        return None
    # must contain real kana/kanji and CRLF line structure
    kana = sum(1 for c in t if "\u3040" <= c <= "\u30ff" or "\u4e00" <= c <= "\u9fff")
    if kana < 200 or t.count("\r\n") < 20:
        return None
    return f"Shift-JIS text document ({kana} kana/kanji chars)"


def det_psx_exe(d: bytes, rec: dict):
    return "PS-X EXE" if d[:8] == b"PS-X EXE" else None


def det_ccs(d: bytes, rec: dict):
    return "CCS script (LNK)" if d[:3] == b"LNK" else None


def det_str(d: bytes, rec: dict):
    if rec.get("type") == "STR video" or b"\x00\x01\x01\x60" in d[:0x800]:
        return "STR video (MDEC + XA)"
    return None


def det_vab(d: bytes, rec: dict):
    t = rec.get("type", "")
    if t in ("VAB header", "VAB body"):
        return t
    if d[:4] == b"pBAV":
        return "VAB header"
    return None


def det_xa(d: bytes, rec: dict):
    if rec.get("type") == "XA audio":
        return "XA audio (Form 2)"
    if d[:4] == b"\x0c\x0c\x1c\x1c" or rec["path"].upper().endswith((".XA", "XA2.")):
        return "XA audio (Form 2)"
    return None


def det_lzss_container(d: bytes, rec: dict):
    """`[u32 payload == filesize-4][LZSS]` -- FACE, IC, and the war pages."""
    if len(d) < 8:
        return None
    size = struct.unpack_from("<I", d, 0)[0]
    if size != rec["size"] - 4:
        return None
    try:
        out, used = lzss.decode_container(d)
    except Exception:
        return None
    if used != rec["size"]:
        return None
    return f"LZSS container -> {len(out)} B"


def _war_descriptor(d: bytes):
    n = len(d)
    for o in range(0, n - 16, 4):
        dims, rid, ap, cp = struct.unpack_from("<4I", d, o)
        w, h = dims & 0xFFFF, dims >> 16
        if not (1 <= w <= 128 and 1 <= h <= 128) or not (1 <= rid <= 0xFFFF):
            continue
        if not (OVERLAY_BASE <= ap < OVERLAY_BASE + n):
            continue
        if not (OVERLAY_BASE <= cp < OVERLAY_BASE + n):
            continue
        clut = struct.unpack_from("<I", d, cp - OVERLAY_BASE)[0]
        if not (OVERLAY_BASE <= clut < OVERLAY_BASE + n):
            continue
        q = ap - OVERLAY_BASE
        for _ in range(64):
            if q + 4 > n:
                break
            v = struct.unpack_from("<I", d, q)[0]
            if not (OVERLAY_BASE <= v < OVERLAY_BASE + n):
                break
            p = v - OVERLAY_BASE
            sz = struct.unpack_from("<I", d, p)[0] if p + 4 <= n else 0
            if 0x100 <= sz <= 0x8000 and p + 4 + sz <= n:
                try:
                    out, used = lzss.decode_container(d[p : p + 4 + sz])
                    if used == 4 + sz and len(out) == 0x4000:
                        return o
                except Exception:
                    pass
            q += 4
    return None


def det_war(d: bytes, rec: dict):
    if not rec["path"].startswith("DATA/16_WAR/"):
        return None
    if _war_descriptor(d) is None:
        return None
    return "WAR overlay (16-byte resource descriptors)"


def det_area_overlay(d: bytes, rec: dict):
    """A MIPS overlay for an AREA dir: code at 0x80010000 with a section table.

    Discriminated by opcode concentration, not by the ISO type label.
    """
    # applied to EVERY file: whether a file is MIPS code is a fact about its
    # bytes, not about its directory name (the AREA dirs are "02_AREA.B", so a
    # "/AREA." path test silently missed all 39 of 02_AREA.B's overlays).
    if len(d) < 0x1000:
        return None
    WORK = {0, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF}
    # Best 2 KB window in the first 64 KB: the overlays are code-then-data, so a
    # 16 KB average dilutes below the threshold even for real code.
    best = 0.0
    for a in range(0, max(0, min(len(d), 0x10000) - 0x800), 0x800):
        c = collections.Counter()
        for i in range(a, a + 0x800, 4):
            c[struct.unpack_from("<I", d, i)[0] >> 26] += 1
        share = 100.0 * sum(v for k, v in c.items() if k in WORK) / max(1, sum(c.values()))
        best = max(best, share)
    if best > 55.0:
        return f"area/MIPS overlay (code {best:.0f}% in a 2 KB window)"
    return None


def det_play_sprite(d: bytes, rec: dict):
    """`DATA/04_PLAY` character sprite: `u8 id` + NUL-terminated name.

    NOT a `[u32 len]` container -- that was a wrong guess and cost this census
    78 false negatives.  See `face_portraits.sprite_names`.
    """
    if not rec["path"].startswith("DATA/04_PLAY/"):
        return None
    import war_text as _wt
    j = 1
    while j < 40 and j < len(d) and _wt.is_text_byte(d[j]):
        j += 1
    if j < 3 or j >= len(d) or d[j] != 0:
        return None
    name, _u = _wt.decode(d, 1, j - 1)
    if not name or not name[0].isalpha():
        return None
    return f"04_PLAY character sprite: id={d[0]} name={name!r}"


def det_face(d: bytes, rec: dict):
    if rec["path"].startswith("DATA/03_SHIRO/DATA/FACE_"):
        return "FACE portrait page -> 16384 B (solved)"
    return None


def det_ikki_atlas(d: bytes, rec: dict):
    if rec["path"].startswith("DATA/12_IKKI/DATA/"):
        return "IKKI duel atlas (container proven, CLUT unknown)"
    return None


def det_audio_dot8(d: bytes, rec: dict):
    if rec["path"].upper().endswith(".8"):
        return "audio (Form-2 misread, see dot8_is_xa_audio)"
    return None


DETECTORS = [
    det_psx_exe, det_shiftjis_text, det_ccs, det_str, det_xa, det_vab, det_face, det_ikki_atlas,
    det_audio_dot8, det_play_sprite, det_war, det_lzss_container,
    det_area_overlay,
]


def classify(rec: dict) -> tuple[str, str]:
    d = head(rec)
    labels = []
    for det in DETECTORS:
        try:
            lab = det(d, rec)
        except Exception as e:  # a detector must never hide a file
            lab = f"DETECTOR ERROR {det.__name__}: {e}"
        if lab:
            labels.append(lab)
    if not labels:
        return "UNKNOWN", ""
    return labels[0], " | ".join(labels[1:])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--unknowns", action="store_true")
    ap.add_argument("--dir")
    ap.add_argument("--json", help="write the full classification here")
    args = ap.parse_args(argv)

    recs = iso_files()
    rows = []
    for r in recs:
        lab, extra = classify(r)
        rows.append({"path": r["path"], "size": r["size"], "lba": r["lba"],
                     "label": lab, "also": extra})
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rows, f, indent=1)

    if args.unknowns:
        for x in rows:
            if x["label"] == "UNKNOWN":
                print(f"{x['path']:52s} {x['size']:9d}")
        n = sum(1 for x in rows if x["label"] == "UNKNOWN")
        print(f"\n{n} unknown of {len(rows)} files")
        return 0

    if args.dir:
        for x in rows:
            if os.path.dirname(x["path"]) == args.dir:
                print(f"{x['path']:52s} {x['size']:9d}  {x['label']}"
                      + (f"   [{x['also']}]" if x["also"] else ""))
        return 0

    by = collections.defaultdict(list)
    for x in rows:
        by[os.path.dirname(x["path"])].append(x)
    print(f"{'directory':22s} {'files':>5s} {'MB':>8s}  labels")
    for d in sorted(by):
        fs = by[d]
        c = collections.Counter(x["label"] for x in fs)
        mb = sum(x["size"] for x in fs) / 1e6
        pre = ", ".join(f"{k}x{v}" for k, v in c.most_common(4))
        print(f"{d or '(root)':22s} {len(fs):5d} {mb:8.2f}  {pre}")
    n = sum(1 for x in rows if x["label"] == "UNKNOWN")
    print(f"\n{n} files with no known format, of {len(rows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
