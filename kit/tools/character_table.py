#!/usr/bin/env python3
"""The78 new-game character records in SLUS_002.92, each0x50 bytes.

SLUS80017544 copies the0x1D60-byte default block from80042FE0 to801B8000.
Its character array starts at+0x294, hence source80043274 (image offset33274).
The78 ids independently match the04_PLAY roster; portrait indices are a
separate name-bridged space. MAIN's cached handle+1C points at these persistent
records. See character_record_fields.md for field consumers and explicit opaque
bytes; growth_rules.md and damage_instruction_correction.md own those rules.

Inventory has nine four-byte entries, bounded by count+1F; it ends exactly at
weapon id+44. Spell-tier charges are the four bytes+09..+0C, not paired words.
The initial record bytes are disc-derived; field meanings come from consumers.
Legacy element_coefficients stores five rune-piece counts, in Fire/Water/Wind/
Thunder/Earth order; element_type selects the active kind1..5 (0 means none).
The writer and counter gates are traced in weapon_rune_fragments.md.

Usage: character_table.py --list | --record 35 | --json output.json
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
import disc  # noqa: E402
import face_portraits as _fp  # noqa: E402

EXE = "SLUS_002.92"
IMAGE_OFF = 0x33274
STRIDE = 0x50
COUNT = 78


def image() -> bytes:
    with open(os.path.join(_KIT, "extracted", "iso_files.json"), encoding="utf-8") as f:
        rec = next(r for r in json.load(f) if r.get("path") == EXE)
    data = disc.extract(rec["lba"], rec["size"])
    # PS-EXE: t_addr at +0x18, image at +0x800
    return data[2048:]


def records() -> list[dict]:
    img = image()
    names = _fp.sprite_names()
    out = []
    for i in range(COUNT):
        o = IMAGE_OFF + i * STRIDE
        raw = img[o : o + STRIDE]
        if len(raw) < STRIDE:
            break
        cid = struct.unpack_from("<I", raw, 0)[0]
        out.append(
            {
                "row": i,
                "off": o,
                "addr": 0x80010000 + o,
                "id": cid,
                "name": names.get(cid, (None, None))[0],
                "sprite_file": names.get(cid, (None, None))[1],
                "hp_max": struct.unpack_from("<H", raw, 0x04)[0],
                "hp_current": struct.unpack_from("<H", raw, 0x06)[0],
                "spell_index0": raw[8],
                "spell_charges": list(raw[9:13]),
                "level": raw[0x0D],
                "experience": struct.unpack_from("<H", raw, 0x0E)[0],
                "stats": list(raw[0x10:0x16]),
                "status": raw[0x16],
                "opaque_17": raw[0x17],
                "growth": list(raw[0x18:0x1E]),
                "opaque_1e": raw[0x1E],
                "inventory_count": raw[0x1F],
                "inventory": [
                    {"id": struct.unpack_from("<H", raw, 0x20+4*k)[0],
                     "slot_flags": raw[0x22+4*k], "uses": raw[0x23+4*k]}
                    for k in range(9)
                ],
                "weapon_id": raw[0x44],
                "weapon_level": raw[0x45],
                "element_type": raw[0x46],
                "element_coefficients": list(raw[0x47:0x4C]),
                "rune_id": raw[0x4C],
                "rune_locked": raw[0x4D],
                "opaque_tail": list(raw[0x4E:0x50]),
            }
        )
    return out


def by_id() -> dict[int, dict]:
    return {r["id"]: r for r in records()}


def portrait_index(cid: int) -> int | None:
    """The portrait index for a character id, bridged **by name only**.

    Returns `None` when the name is ambiguous or missing, rather than guessing.
    """
    chars = _fp.character_names()
    rec = by_id().get(cid)
    if rec is None or not rec["name"]:
        return None
    hits = [i for i, n in enumerate(chars) if n == rec["name"]]
    return hits[0] if len(hits) == 1 else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--record", type=int)
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    recs = records()
    if args.json:
        with open(args.json, "w") as f:
            json.dump(recs, f, indent=1)
        print(f"wrote {args.json} ({len(recs)} records)")
        return 0

    if args.record is not None:
        r = by_id()[args.record]
        print(json.dumps(r, indent=1))
        return 0

    if args.list:
        print(f"{'row':>3} {'id':>4} {'name':18} {'HP':>7}  stats            growth")
        for r in recs:
            print(f"{r['row']:3d} {r['id']:4d} {str(r['name']):18} "
                  f"{r['hp_current']:3d}/{r['hp_max']:<3d}  "
                  f"{' '.join(f'{v:2d}' for v in r['stats']):16} "
                  f"{' '.join(f'{v:2d}' for v in r['growth'])}")
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
