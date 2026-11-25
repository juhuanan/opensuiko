#!/usr/bin/env python3
"""
decode_8.py — Structural decoder for Suikoden PS1 `.8` container files.

Parses the 16-byte record structure proven from MAIN.EXE loader code:
  +0: u16 tag      (0x2xx = data, 0x3xx = file terminator)
  +2: u8  payload[14]

Does NOT claim payload semantics — per-tag payload meaning awaits
identification of the record parser (possibly in an area overlay).

Usage:
  python3 decode_8.py FILE.8            # dump record summary
  python3 decode_8.py --all            # validate all 67 .8 files in the ISO
  python3 decode_8.py --tags FILE.8    # tag histogram

Disc: resolved via kit/tools/disc.py ($SUIKODEN_DISC or disc/*.iso|*.bin)
File list: kit/extracted/iso_files.json
Docs: kit/docs/container_8.md
"""

import json
import os
import struct
import sys
from collections import Counter

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)


FILES_JSON = os.path.join(_KIT, "extracted/iso_files.json")

RECORD_SIZE = 16
# Tag categories by high nibble (observed across all 67 files):
#   0x2xx: data records (interleaved command stream)
#   0x3xx: control/terminator (exactly one, as the final record)
#   0x6xx: section marker (exactly one per file, ~25% position)
#   0x20C: padding (usually zero payload; file headers may use with payload)
TAG_PAD = 0x20C


def load_file_list():
    with open(FILES_JSON) as f:
        return json.load(f)


def read_8(path=None, lba=None, size=None):
    """Read raw bytes of a .8 file (from ISO by lba/size, or a direct path)."""
    if path and os.path.exists(path) and not path.endswith(".iso"):
        with open(path, "rb") as f:
            return f.read()
    files = load_file_list()
    if lba is None:
        t = [x for x in files if x["path"] == path]
        if not t:
            raise ValueError(f"not in ISO index: {path}")
        lba, size = t[0]["lba"], t[0]["size"]
    # Read through tools/disc.py: it handles both .iso (2048-byte sectors) and
    # .bin (MODE2/2352, payload at byte 24), so this works either way.
    import sys as _sys
    _sys.path.insert(0, _TOOLS)
    import disc as _disc
    return _disc.extract(lba, size)


def parse_records(data):
    """Yield (index, tag, payload) for each 16-byte record."""
    if len(data) % RECORD_SIZE:
        raise ValueError(f"size {len(data)} not a multiple of 16")
    n = len(data) // RECORD_SIZE
    for i in range(n):
        off = i * RECORD_SIZE
        tag = struct.unpack("<H", data[off:off + 2])[0]
        yield i, tag, data[off + 2:off + 16]


def category(tag):
    hi = tag & 0xF00
    if hi == 0x200:
        return "data"
    if hi == 0x300:
        return "control"
    if hi == 0x600:
        return "marker"
    return "unknown"


def validate(data, name=""):
    """Structural validation. Returns (ok, issues, stats)."""
    issues = []
    tags = Counter()
    n_pad = 0
    last_tag = None
    n = 0
    for i, tag, payload in parse_records(data):
        n += 1
        last_tag = tag
        tags[tag] += 1
        cat = category(tag)
        if cat == "unknown":
            issues.append(f"record {i}: unknown tag 0x{tag:03X}")
        if tag == TAG_PAD:
            n_pad += 1
            # 0x20C is usually zero padding, but file headers may use it
            # with payload (observed in CDSE18.8 records 2-3)
        # control tags must only appear as the final record
        if (tag & 0xF00) == 0x300 and i != len(data) // 16 - 1:
            issues.append(f"record {i}: control tag 0x{tag:03X} not at end")
    if last_tag is None or (last_tag & 0xF00) != 0x300:
        issues.append(
            f"missing 0x3xx terminator (last tag "
            f"{('0x%03X' % last_tag) if last_tag is not None else 'none'})"
        )
    stats = {
        "records": n,
        "distinct_tags": len(tags),
        "data_tags": sum(c for t, c in tags.items()
                         if (t & 0xF00) == 0x200),
        "pad_records": n_pad,
        "terminator": "0x%03X" % last_tag if last_tag is not None else None,
    }
    return (not issues), issues, stats, tags


def cmd_dump(path):
    data = read_8(path)
    ok, issues, stats, tags = validate(data, path)
    print(f"file: {path}")
    print(f"size: {len(data)} bytes, {stats['records']} records")
    print(f"distinct tags: {stats['distinct_tags']}, "
          f"data records: {stats['data_tags']}, "
          f"pad records: {stats['pad_records']}")
    print(f"terminator: {stats['terminator']}")
    print(f"structural validation: {'OK' if ok else 'FAILED'}")
    for iss in issues[:10]:
        print(f"  ! {iss}")
    if len(issues) > 10:
        print(f"  ... and {len(issues) - 10} more")


def cmd_tags(path):
    data = read_8(path)
    _, _, _, tags = validate(data, path)
    print(f"tag histogram for {path}:")
    for tag in sorted(tags):
        cat = category(tag)
        print(f"  0x{tag:03X} [{cat:7s}]: {tags[tag]}")


def cmd_all():
    files = load_file_list()
    eights = [f for f in files if f["path"].endswith(".8")]
    clean, failed = 0, []
    term_tags = Counter()
    for f in eights:
        data = read_8(lba=f["lba"], size=f["size"])
        ok, issues, stats, _ = validate(data, f["path"])
        term_tags[stats["terminator"]] += 1
        if ok:
            clean += 1
        else:
            failed.append((f["path"], issues))
    print(f"validated {len(eights)} .8 files: "
          f"{clean} clean, {len(failed)} with issues")
    print(f"terminator distribution: {dict(sorted(term_tags.items()))}")
    for p, issues in failed:
        print(f"FAIL {p}:")
        for iss in issues[:5]:
            print(f"  ! {iss}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "--all":
        cmd_all()
    elif sys.argv[1] == "--tags" and len(sys.argv) == 3:
        cmd_tags(sys.argv[2])
    else:
        cmd_dump(sys.argv[1])


if __name__ == "__main__":
    main()
