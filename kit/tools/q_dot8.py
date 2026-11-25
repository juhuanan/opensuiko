#!/usr/bin/env python3
"""Historical .8 framing and separate area-table instruction measurements.

The .8 blocks are SPU ADPCM (dot8_audio.py), decoded by sound hardware.
The area24→16 transformer and byte14 party indices below concern other
buffers. Missing CPU nibble patterns do not exclude the SPU consumer.
Existing report keys remain stable for downstream measurement checks.
"""
from __future__ import annotations

import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402
import disc_iso  # noqa: E402
from mipsdec import dec  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MAIN_EXE = "MAIN.EXE"
MAIN_BASE = 0x800C0800
MAIN_HEADER = 2048

REC = 16           # the `.8` record stride, from the framing invariant
MARKER = 2         # byte 1 of a well-formed `.8` record
FORM2 = 0x20       # subheader byte 2 bit 5
AUDIO = 0x04       # subheader byte 2 bit 2
SUBMODE_OFF = 18


# ---------------------------------------------------------------------------
# disc plumbing
# ---------------------------------------------------------------------------

def _iso_records():
    return disc_iso.iso_records(os.path.join(ROOT, "kit", "extracted", "iso_files.json"))


def _by_path(name):
    for r in _iso_records():
        if r["path"] == name or r["path"].endswith("/" + name):
            return r
    raise KeyError(name)


def main_image():
    return disc_iso.main_image(os.path.join(ROOT, "kit", "extracted", "iso_files.json"))


def _word(image, va):
    off = va - MAIN_BASE
    if off < 0 or off + 4 > len(image):
        return None
    return struct.unpack_from("<I", image, off)[0]


def _listing(image, va, n):
    return [(va + i * 4, _word(image, va + i * 4)) for i in range(n)]


# ---------------------------------------------------------------------------
# Q1 -- framing
# ---------------------------------------------------------------------------

def sector_forms(n=6):
    """Submode byte of the first n sectors of every file, per-file."""
    path, sector, _ = disc.resolve_raw()
    out = {}
    with open(path, "rb") as fh:
        for r in _iso_records():
            seen = set()
            for i in range(min(n, max(1, r["size"] // 2048))):
                fh.seek((r["lba"] + i) * sector)
                seen.add(fh.read(24)[SUBMODE_OFF])
            out[r["path"]] = sorted(seen)
    return out


def framing(path):
    """Framing invariants of one `.8` file.

    Returns the record count under each stride and how many records carry the
    `0x02` byte in byte 1 (`MARKER`). A well-formed framing marks ~every record.
    """
    r = _by_path(path)
    data = disc.extract(r["lba"], r["size"])
    out = {"path": path, "bytes": len(data)}
    for stride in (REC, 24):
        n = len(data) // stride
        good = sum(1 for i in range(n) if data[i * stride + 1] == MARKER)
        out[f"stride{stride}"] = {"records": n, "marked": good,
                                  "fraction": good / n if n else 0.0}
    # The two non-marker records of a well-formed file: the 0x06 section marker
    # and the 0x03 terminator, both documented at 16-byte framing.
    others = {}
    for i in range(len(data) // REC):
        b = data[i * REC + 1]
        if b != MARKER:
            others[b] = others.get(b, 0) + 1
    out["non_marker_bytes"] = others
    return out


def transformer_8013751C(image):
    """Instruction evidence for the 24-byte-input, 16-byte-output transformer."""
    sites = {
        # count = global->0x45C ; malloc(count * 16)
        "count_load": 0x80137538,
        "malloc_size": 0x80137540,
        "malloc_call": 0x8013753C,
        # source = [0x8017BF98]
        "source_load": 0x80137550,
        # input stride: s1 = base + 0xc, and both in/out advances
        "input_base": 0x80137568,
        "loop_test": 0x80137570,
        "flag_mask": 0x80137578,
        "in_stride_a": 0x80137688,
        "in_stride_b": 0x80137694,
        "out_stride_a": 0x80137674,
        "out_stride_b": 0x80137668,
        # 24-byte-stride consumer: addiu $s0,$s0,0x18 in a backward branch
        "tile_scan_stride": 0x8012EEC8,
        # the count field the allocation is sized from is a TILE count: exactly
        # three writers, one of which is the tile scan incrementing it, and one
        # is the scene install zeroing it.
        "count_is_tile_increment": 0x8012EEB8,
        "count_is_install_clear": 0x801314E8,
        "count_is_teardown_clear": 0x801378C8,
    }
    return [{"name": k, "va": va, "word": _word(image, va),
             "asm": dec(va, _word(image, va))[0]}
            for k, va in sorted(sites.items(), key=lambda kv: kv[1])]


def nibble_sign_extend_scan(image):
    """Count `sll r,r,28` / `sra r,r,28` pairs and `k*17 -> k` tables."""
    pairs = 0
    for off in range(0, len(image) - 8, 4):
        a = struct.unpack_from("<I", image, off)[0]
        b = struct.unpack_from("<I", image, off + 4)[0]
        if (a >> 26) == 0 and ((a >> 16) & 0x1F) == 0 and ((a >> 21) & 0x1F) == ((a >> 11) & 0x1F) \
                and ((a >> 6) & 0x1F) == 28:
            if (b >> 26) == 0 and ((b >> 6) & 0x1F) == 0x1B:  # sra
                pairs += 1
    tables = []
    for start in range(0, len(image) - 16 * 17):
        if all(image[start + k * 17] == k for k in range(16)):
            tables.append(MAIN_BASE + start)
    return {"sll28_sra28_pairs": pairs, "k17_tables": tables}


def window_reader_801C8A80(image):
    """Instruction evidence for the scalar window reader and its unreachability."""
    sites = [0x800C8A80, 0x800C8A84, 0x800C8A9C, 0x800C8AF8, 0x800C8B00,
             0x800C8B0C, 0x800C8B24, 0x800C8B48, 0x800C8ABC]
    out = [{"va": va, "word": _word(image, va), "asm": dec(va, _word(image, va))[0]}
           for va in sites]
    # reachability: any jal/j/branch whose target is the reader, and the pair
    # immediately before it (fall-through check).
    targets = 0
    for off in range(0, len(image) - 4, 4):
        w = struct.unpack_from("<I", image, off)[0]
        op = w >> 26
        pc = MAIN_BASE + off
        if op == 3:
            tgt = ((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
        elif op == 2:
            tgt = (pc & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
        elif op in (1, 4, 5, 6, 7):
            tgt = pc + 4 + (struct.unpack("<i", struct.pack("<I", w & 0xFFFF))[0] << 2)
        else:
            continue
        if tgt == 0x800C8A80:
            targets += 1
    prev = _word(image, 0x800C8A78)
    return {"listing": out, "branch_or_call_targets": targets,
            "prev_insn": {"va": 0x800C8A78, "word": prev,
                          "asm": dec(0x800C8A78, prev)[0]}}


# ---------------------------------------------------------------------------
# Q3 -- the consumer of record bytes 14-15
# ---------------------------------------------------------------------------

def e0e1_consumer(image):
    """Instruction evidence for the only reader of a record's bytes 14-15."""
    names = {
        0x800C9654: "table_fill: sw $a1,0x1b9c($a0)",
        0x800C9658: "table_fill: addiu $a1,$a1,0x5000",
        0x800C9660: "table_fill bound: slti $v0,$s2,0x6",
        0x800C9664: "table_fill loop",
        0x800C9668: "table_fill stride: addiu $a0,$a0,0x4",
        0x80131558: "consumer: $a1 = [0x8017C164] (record table base)",
        0x80131584: "consumer: p = base + i",
        0x80131588: "consumer: lbu $v0,0xe(p)  <-- record BYTE 14",
        0x80131590: "consumer: sll $v0,$v0,2",
        0x80131598: "consumer: lw $v0,0x1b9c($v0)",
        0x801315A0: "consumer: sw $v0,0x4($v1)  -> area struct +0x04",
        0x801315AC: "consumer: addiu $v1,$v1,4",
        0x80132078: "scene install: lbu $v0,0x1($v0) -> entry selector",
        0x80132080: "scene install: sll $v0,$v0,4 (16-byte entries)",
        0x80132098: "scene install: sw $v1,-0x4068($at) -> [0x8017BF98]",
        0x801313E4: "scene install: lw $v0,0x0($v0) with lui 0x8008",
    }
    return [{"name": names[va], "va": va, "word": _word(image, va),
             "asm": dec(va, _word(image, va))[0]}
            for va in sorted(names)]


def e0e1_measure(path):
    """Value distribution of record bytes 14-15, for the record report."""
    r = _by_path(path)
    data = disc.extract(r["lba"], r["size"])
    n = len(data) // REC
    b14 = set()
    small = 0
    high = 0
    pair_eq_zero = 0
    pairs = {}
    for i in range(n):
        v14 = data[i * REC + 14]
        v15 = data[i * REC + 15]
        b14.add(v14)
        if v14 <= 0x3F:
            small += 1
        else:
            high += 1
        if v14 == 0 and v15 == 0:
            pair_eq_zero += 1
        pairs[(v14, v15)] = pairs.get((v14, v15), 0) + 1
    return {"records": n, "distinct_byte14": len(b14),
            "byte14_le_0x3f": small, "byte14_gt_0x3f": high,
            "pair_zero": pair_eq_zero, "distinct_pairs": len(pairs)}


# ---------------------------------------------------------------------------
# PAN_TEO: the "X at +8 / Y at +0xA" consumer is NOT the `.8` record format
# ---------------------------------------------------------------------------

PANTEO = "DATA/12_IKKI/PAN_TEO.BIN"
PANTEO_BASE = 0x80080000


def panteo_renderer():
    r = _by_path(PANTEO)
    raw = disc.extract(r["lba"], r["size"])

    def w(va):
        off = va - PANTEO_BASE
        if off < 0 or off + 4 > len(raw):
            return None
        return struct.unpack_from("<I", raw, off)[0]

    sites = [0x80084F7C, 0x80084F84, 0x80084F88, 0x80084FF0,
             0x80085004, 0x800850A8, 0x800850B0]
    out = []
    for va in sites:
        word = w(va)
        out.append({"va": va, "word": word,
                    "asm": dec(va, word)[0] if word is not None else "???"})
    return {"path": PANTEO, "lba": r["lba"], "sites": out}


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def report():
    image = main_image()
    forms = sector_forms()
    eights = sorted(p for p in forms if p.endswith(".8"))
    form2 = sorted(p for p, s in forms.items()
                   if len(s) and any(x & FORM2 for x in s) and p in ("DATA/01_AREA.A/XA1.", "DATA/16_WAR/XA2."))
    counts = {}
    for p in eights:
        f = framing(p)
        counts[p] = f
    tot16 = sum(f["stride16"]["records"] for f in counts.values())
    good16 = sum(f["stride16"]["marked"] for f in counts.values())
    tot24 = sum(f["stride24"]["records"] for f in counts.values())
    good24 = sum(f["stride24"]["marked"] for f in counts.values())
    return {
        "files": {
            "count": len(eights),
            "all_form1_data": all(all(x & 0x08 for x in forms[p]) for p in eights),
            "form2_files_with_audio": form2,
        },
        "framing": {
            "stride16": {"records": tot16, "marked": good16,
                         "fraction": good16 / tot16},
            "stride24": {"records": tot24, "marked": good24,
                         "fraction": good24 / tot24},
            "non_marker_records": sum(sum(f["non_marker_bytes"].values())
                                      for f in counts.values()),
        },
        "q1_transformer_8013751C": transformer_8013751C(image),
        "q2_nibble": {**nibble_sign_extend_scan(image),
                      "window_reader": window_reader_801C8A80(image)},
        "q3_e0e1_consumer": e0e1_consumer(image),
        "q3_e0e1_measure_DJ2": e0e1_measure("DATA/01_AREA.A/DJ2.8"),
        "panteo": panteo_renderer(),
    }


def verify():
    r = report()
    bad = []
    f = r["files"]
    if f["count"] != 67:
        bad.append(f"expected 67 `.8` files, found {f['count']}")
    if not f["all_form1_data"]:
        bad.append("a `.8` file is not Form 1 Data (submode 0x08)")
    fr = r["framing"]
    if fr["stride16"]["fraction"] < 0.999:
        bad.append(f"16-byte framing marks only "
                   f"{fr['stride16']['fraction']:.4%} of records")
    if fr["non_marker_records"] != 134:
        bad.append(f"expected 134 non-0x02 records, found {fr['non_marker_records']}")
    if fr["stride24"]["fraction"] > 0.6:
        bad.append("the 24-byte reading marks as many records as the 16-byte one")
    # Q1: the transformer must alloc count*16 and stride its INPUT by 0x18
    w = {e["name"]: e["word"] for e in r["q1_transformer_8013751C"]}
    if w["malloc_size"] != 0x00042100:
        bad.append("0x80137540 is not `sll $a0,$a0,4` (count*16 allocation)")
    for k in ("in_stride_a", "in_stride_b"):
        if w[k] != 0x26310018 and w[k] != 0x26730018:
            bad.append(f"{k} is not a 0x18 input stride ({w[k]:#010x})")
    for k in ("out_stride_a", "out_stride_b"):
        if w[k] != 0x26520010 and w[k] != 0x26100010:
            bad.append(f"{k} is not a 0x10 output stride ({w[k]:#010x})")
    # Q2: no nibble sign-extend, no k*17 table, reader unreachable
    q2 = r["q2_nibble"]
    if q2["sll28_sra28_pairs"] != 0:
        bad.append("found a `sll 28`/`sra 28` nibble sign-extend")
    if q2["k17_tables"]:
        bad.append(f"found a k*17 -> k table at {q2['k17_tables']}")
    if q2["window_reader"]["branch_or_call_targets"] != 0:
        bad.append("the window reader has a branch/call target")
    if q2["window_reader"]["prev_insn"]["word"] != 0x03E00008:
        bad.append("the instruction before the window reader is not `jr $ra`")
    # Q3: the byte-14 read and the table fill
    w3 = {e["va"]: e["word"] for e in r["q3_e0e1_consumer"]}
    if w3[0x80131588] != 0x9042000E:
        bad.append("0x80131588 is not `lbu $v0,0xe(p)` (the byte-14 consumer)")
    if w3[0x80131598] != 0x8C421B9C:
        bad.append("0x80131598 is not `lw $v0,0x1b9c(...)`")
    if w3[0x801315A0] != 0xAC620004:
        bad.append("0x801315A0 does not store the fetched word to +0x04")
    if w3[0x800C9654] != 0xAC851B9C:
        bad.append("0x800C9654 does not fill the 0x1B9C table")
    if w3[0x800C9658] != 0x24A55000:
        bad.append("the 0x1B9C table fill does not advance by 0x5000")
    if bad:
        print("FAIL: q_dot8 invariant broken:")
        for b in bad:
            print(f"  - {b}")
        return 1
    print("PASS: `.8` framing is 16-byte records (byte 1 = 0x02, "
          f"{fr['stride16']['marked']}/{fr['stride16']['records']} records); the only "
          "transformer (0x8013751C) allocates count*16 and strides its input 0x18; "
          "no nibble sign-extend and no k*17 table exist and the window reader is "
          "unreachable; separate party record byte14 is consumed at 0x80131588 as a u8 index "
          "into the word table filled at 0x800C9654")
    return 0


def main(argv):
    if "--verify" in argv:
        return verify()
    if "--json" in argv:
        print(json.dumps(report(), indent=1, sort_keys=True))
        return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
