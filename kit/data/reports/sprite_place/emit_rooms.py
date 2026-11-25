#!/usr/bin/env python3
"""Emit the verified area entity-placement table for one BIN (scratch, 2026-10-03).

Chain verified in MAIN.EXE:
  S        = u32@0                       (overlay loaded at 0x80010000)
  roomtab  = u32@(S+8)                   16-byte records, indexed by game_state[1]
  room+0   = u32 -> 24-byte entry array
  room+4   = u8  entry count
  room+5   = u8  section index into table2
  table2   = u32@(S+4)
  section  = u32@(table2 + 4*room[5])
  entry+0  = u16 X (8-pixel units, same space as 0x8017BD74)
  entry+2  = u16 Y (8-pixel units, same space as 0x8017BD75)
  entry+4  = u16 flags (0x20/0x40 -> walker entity; 0x01/0x100 -> interaction)
  entry+6  = u16 id
  entry+0xC= u32 0x06-delimited behaviour stream pointer
Provenance: disc/Suikoden (v1.1).iso, iso_files.json LBA, disc.extract.
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "kit", "tools"))
BASE = 0x80010000


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def off_of(d, v):
    o = v - BASE
    return o if 0 <= o < len(d) else None


def main(name):
    import json as _json
    recs = _json.load(open(os.path.join(ROOT, "kit", "extracted", "iso_files.json")))
    rec = [e for e in recs if e.get("path", "").endswith("/" + name)][0]
    from disc import extract
    d = extract(rec["lba"], rec["size"])
    s = off_of(d, u32(d, 0))
    t2 = off_of(d, u32(d, s + 4))
    rt = off_of(d, u32(d, s + 8))
    out = {
        "provenance": {
            "disc_file": rec["path"], "lba": rec["lba"], "size": rec["size"],
            "reader": "kit/tools/disc.py extract", "load_base": hex(BASE),
            "decoder": "none (raw little-endian structs)",
        },
        "S": s, "table2": t2, "roomtab": rt, "rooms": [],
    }
    for i in range(64):
        o = rt + 16 * i
        if o + 16 > len(d):
            break
        et = off_of(d, u32(d, o))
        if et is None:
            break
        cnt = d[o + 4]
        sidx = d[o + 5]
        sec = off_of(d, u32(d, t2 + 4 * sidx)) if t2 + 4 * sidx + 4 <= len(d) else None
        room = {"index": i, "record_off": o, "entrytab": et, "count": cnt,
                "section_index": sidx, "section": sec, "entities": []}
        if sec is not None:
            room["section_dims"] = [u16(d, sec), u16(d, sec + 2)]
        for k in range(cnt):
            eo = et + 24 * k
            if eo + 24 > len(d):
                break
            fl = u32(d, eo + 4)
            room["entities"].append({
                "n": k, "off": eo, "X": u16(d, eo), "Y": u16(d, eo + 2),
                "flags": hex(fl), "id": u16(d, eo + 6),
                "stream": u32(d, eo + 0xC),
                "kind": ("walker" if (fl & 0x60) else
                         "interaction" if (fl & 0x101) else "inactive"),
            })
        out["rooms"].append(room)
    dst = os.path.join(HERE, name.replace(".BIN", "") + "_rooms.json")
    with open(dst, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote", dst, "rooms:", len(out["rooms"]),
          "walkers:", sum(1 for r in out["rooms"] for e in r["entities"] if e["kind"] == "walker"))


if __name__ == "__main__":
    for a in sys.argv[1:] or ["VB5.BIN"]:
        main(a)
