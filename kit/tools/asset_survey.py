#!/usr/bin/env python3
"""Static asset survey for Suikoden PS1 disc.

Walks every extracted .BIN plus known side assets, computes size/entropy/
header fingerprints, and runs format detectors (FACE-LZSS, .8 records, TIM,
PS1 ADPCM, offset tables, MIPS code-likeness). Writes asset_survey.csv.
"""
import os, math, hashlib, struct, csv, json, sys
from collections import Counter

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from face_decompress import face_decompress, FaceDecodeError

KIT = os.path.dirname(TOOLS)
OVERLAY_ROOT = os.path.join(KIT, "extracted", "bin_overlays")
WORK = os.path.join(KIT, "work")
OUT = os.path.join(WORK, "asset_survey.csv")

# LBA table: path -> lba (optional input; a missing/bad table is reported, not
# swallowed -- every row then simply has an empty lba column).
LBA = {}
_lba_path = os.path.join(KIT, "extracted", "overlay_lba_table.json")
if os.path.exists(_lba_path):
    try:
        with open(_lba_path) as f:
            j = json.load(f)
    except (OSError, ValueError, KeyError, TypeError) as ex:
        print("LBA table load failed (%s): %s" % (_lba_path, ex), file=sys.stderr)
    else:
        for e in j["static_table"]["entries"]:
            LBA[e["path"]] = e["lba"]

# code-bearing set from the triage survey (optional input, same policy)
CODE_FILES = set()
_survey_path = os.path.join(WORK, "overlay_survey.csv")
if os.path.exists(_survey_path):
    try:
        with open(_survey_path) as f:
            r = csv.DictReader(f)
            for row in r:
                CODE_FILES.add(row["file"])
    except (OSError, ValueError) as ex:
        print("survey load failed (%s): %s" % (_survey_path, ex), file=sys.stderr)


def entropy(data):
    if not data:
        return 0.0
    n = len(data)
    return -sum(v / n * math.log2(v / n) for v in Counter(data).values())


def face_test(data):
    """Try FACE LZSS from offset 4.

    Returns (ok, out_len, out_entropy, zero_ratio, tail_truncated). A stream
    that ends mid-token is still FACE data; the partial decode is measured so
    detection is not lost, and the truncation is flagged to the caller.
    """
    if len(data) < 64:
        return (False, 0, 0.0, 0.0, False)
    hdr = struct.unpack_from("<I", data, 0)[0]
    hdr_close = abs(hdr - len(data)) < 512  # FACE headers ~ filesize
    truncated = False
    try:
        out = face_decompress(bytes(data), 4)
    except FaceDecodeError:
        out = face_decompress(bytes(data), 4, strict=False)
        truncated = True
    if len(out) < len(data) * 1.5:
        return (False, 0, 0.0, 0.0, truncated)
    oe = entropy(out)
    zr = sum(1 for b in out if b == 0) / len(out)
    # Tight bounds: real FACE output is ent 4.2-5.0, zeros 44-54%.
    # Random input degenerates to ent ~1.4, zeros ~87% (verified control),
    # so require the genuine profile, not just "decompressible".
    ok = 3.5 < oe < 6.0 and 0.35 < zr < 0.65 and hdr_close
    return (ok, len(out), oe, zr, truncated)


def eight_test(data):
    # tolerate trailing bytes (e.g. PASS.8 has 6 trailing bytes)
    body = data[: len(data) // 16 * 16]
    if len(body) < 64:
        return None
    n = len(body) // 16
    n2 = n3 = n6 = nother = 0
    for i in range(n):
        t = struct.unpack_from("<H", data, i * 16)[0]
        if 0x200 <= t <= 0x2FF:
            n2 += 1
        elif 0x300 <= t <= 0x3FF:
            n3 += 1
        elif 0x600 <= t <= 0x6FF:
            n6 += 1
        else:
            nother += 1
    if n2 / n > 0.5 and n3 >= 1 and n6 >= 1:
        return f"8rec 2xx={n2} 3xx={n3} 6xx={n6} other={nother}"
    if n2 / n > 0.8:
        return f"8rec-ish 2xx-dom {n2}/{n}"
    return None


def adpcm_test(data):
    """PS1 ADPCM: 16-byte blocks, header byte predictor<=4 (allow 5), shift<=12."""
    nblocks = len(data) // 16
    if nblocks < 4:
        return 0.0
    good = 0
    for i in range(nblocks):
        b0 = data[i * 16]
        if (b0 >> 4) <= 5 and (b0 & 0xF) <= 12:
            good += 1
    return good / nblocks


def offset_table_test(data):
    """Check if file starts with an increasing u32 offset table."""
    if len(data) < 32:
        return None
    vals = struct.unpack_from("<8I", data, 0)
    if vals[0] == 0 or vals[0] > len(data):
        return None
    ok = all(vals[i] < vals[i + 1] <= len(data) for i in range(7))
    if ok:
        return "offtab8:" + ",".join(str(v) for v in vals)
    # try 4-entry
    vals4 = vals[:4]
    if all(vals4[i] < vals4[i + 1] <= len(data) for i in range(3)) and vals4[0] > 16:
        return "offtab4:" + ",".join(str(v) for v in vals4)
    return None


def mips_score(data):
    n = len(data) // 4
    if n == 0:
        return 0.0
    s = 0
    for i in range(n):
        w = struct.unpack_from("<I", data, i * 4)[0]
        op = w >> 26
        if op in (0x0F, 0x09, 0x08, 0x23, 0x2B, 0x03, 0x02, 0x2B):
            s += 1
        elif w == 0x03E00008 or w == 0x00000000:
            s += 1
    return s / n


def classify(path, rel, data):
    notes = []
    guess = "unknown"
    size = len(data)
    ent = entropy(data)
    hdr = data[:16].hex()

    if size == 0:
        return ("empty", "zero-size file", ent, hdr)

    # known formats by filename (verified in prior work)
    base = os.path.basename(path)
    if base == "SEQ.BIN":
        guess = "pQES-music"
        notes.append("music sequences (known format)")
        return (guess, "; ".join(notes), ent, hdr, LBA.get(rel, ""), 0.0)
    if base in ("ORCH.VB",):
        guess = "PS1-ADPCM"
        notes.append("decoded to WAV in prior work")
        return (guess, "; ".join(notes), ent, hdr, LBA.get(rel, ""), 0.0)
    if base in ("ORCH.VA",):
        guess = "VAB-bank"
        notes.append("pBAV magic: PS1 VAB sound bank (instruments for ORCH.VB)")
        return (guess, "; ".join(notes), ent, hdr, LBA.get(rel, ""), 0.0)

    # TIM magic
    if data[:4] == b"\x10\x00\x00\x00":
        guess = "TIM?"
        notes.append("TIM magic 10000000")

    # FACE LZSS (only worth trying on high-entropy data)
    face = (False, 0, 0.0, 0.0, False)
    if ent > 6.5:
        face = face_test(data)
    if face[0]:
        guess = "FACE-LZSS"
        note = (f"decompresses {size}->{face[1]} ent {face[2]:.2f} "
                f"zeros {face[3]*100:.0f}%")
        if face[4]:
            note += " (tail truncated: final token incomplete)"
        notes.append(note)

    # .8 records (before ADPCM: .8 headers false-positive the ADPCM block test)
    eight = eight_test(data)
    if eight and guess == "unknown":
        guess = ".8-records"
        notes.append(eight)
    elif eight:
        notes.append(eight)

    # ADPCM (skip if already identified as .8)
    ad = adpcm_test(data)
    if ad > 0.90 and ent > 6.0 and not eight:
        if guess == "unknown":
            guess = "ADPCM?"
        notes.append(f"adpcm-blocks {ad*100:.0f}%")

    # offset table
    ot = offset_table_test(data)
    if ot:
        notes.append(ot)
        if guess == "unknown":
            guess = "offset-table?"

    # ascii / text
    asc = sum(1 for b in data if 0x20 <= b < 0x7F or b in (10, 13, 9)) / size
    if asc > 0.7:
        if guess == "unknown":
            guess = "ascii-text?"
        notes.append(f"ascii {asc*100:.0f}%")

    # code likeness
    ms = mips_score(data)
    if rel in CODE_FILES:
        notes.append(f"code-bearing(survey) mips {ms:.2f}")
        if guess == "unknown":
            guess = "code-overlay"
    elif ms > 0.30 and guess == "unknown":
        guess = "code?"
        notes.append(f"mips-like {ms:.2f}")

    # compressed-unknown heuristic
    if guess == "unknown" and ent > 7.0:
        guess = "compressed-unknown"
    elif guess == "unknown" and ent > 6.0:
        guess = "packed?"

    zr = sum(1 for b in data if b == 0) / size
    if zr > 0.5:
        notes.append(f"zeros {zr*100:.0f}%")

    lba = LBA.get(rel, "")
    return (guess, "; ".join(notes), ent, hdr, lba, ms)


def main():
    files = []
    for dirpath, _, filenames in os.walk(OVERLAY_ROOT):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, OVERLAY_ROOT)
            files.append((rel, p))
    # side assets
    for extra in ["ORCH.VA", "ORCH.VB", "SEQ.BIN"]:
        p = os.path.join(WORK, extra)
        if os.path.exists(p):
            files.append(("WORK/" + extra, p))
    # Scratch .8 extraction dir, if a previous run left one. Optional: the
    # canonical .8 files are read from the disc-extracted tree elsewhere.
    ex8 = os.path.join(WORK, "extract8")
    if os.path.isdir(ex8):
        for fn in sorted(os.listdir(ex8)):
            if fn.endswith(".8"):
                files.append(("extract8/" + fn, os.path.join(ex8, fn)))
    for extra in ["DJ2.8", "PASS.8"]:
        p = os.path.join(WORK, extra)
        if os.path.exists(p):
            files.append(("WORK/" + extra, p))

    files.sort()
    print(f"scanning {len(files)} files...", file=sys.stderr)

    md5seen = {}
    rows = []
    for rel, p in files:
        with open(p, "rb") as f:
            data = f.read()
        md5 = hashlib.md5(data).hexdigest()[:12]
        guess, notes, ent, hdr, lba, ms = classify(p, rel, data)
        if md5 in md5seen:
            notes = (notes + "; " if notes else "") + f"DUP of {md5seen[md5]}"
        else:
            md5seen[md5] = rel
        rows.append({
            "path": rel, "size": len(data), "entropy": f"{ent:.2f}",
            "header_hex": hdr, "md5": md5, "lba": lba,
            "format_guess": guess, "notes": notes,
        })
        print(f"  {rel} {len(data)} e={ent:.2f} -> {guess}", file=sys.stderr)

    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["path", "size", "entropy", "header_hex",
                                          "md5", "lba", "format_guess", "notes"])
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {OUT} ({len(rows)} rows)", file=sys.stderr)


if __name__ == "__main__":
    main()
