#!/usr/bin/env python3
"""Where a `04_PLAY` piece is DRAWN: the destination, traced to instructions.

`play_sprite_geometry.py` solves the **source rectangle**; `play_cycle_anchor.py`
measures the **vertical anchor** from the art.  This closes the destination in
**code** — the hop both of those left open — by reading the quad emitter.

The chain, all in `MAIN.EXE` (headerless image at base `0x800C0800`):

| address | what it is |
|---|---|
| `0x800E1618` | **slot allocator**: linear scan of the 20 slots at `struct+0x2560`, stride `0x90`, returning the first with `+0x00 == 0`, else `-1`. `struct = *(0x8017BE3C)` |
| `0x800E1654` | **draw-list writer**: per character, gets a slot, accumulates the animation counter at slot-table `+0x4E`, and appends `(character index, amount)` at `draw_list[slot]+0x08` / `+0x0C` |
| `0x800E1BF8` | **the quad emitter**: walks all 20 slots; for an armed slot it projects the Q12 world position and writes the quad's corners into a 40-byte packet at `slot + 0x40 + 40*n` |

The emitter's destination, instruction for instruction (`+0x08` is the packet's
x halfword and `+0x0A` its y):

```
800e1ce4  lh   $v1,0x18($sp)      ; X = projection output
800e1cf0  lh   $a2,0x132c($v0)    ;     + struct[0x132C]   (scene screen offset x)
800e1cf4  lw   $a3,0x2570($a0)    ;     - W                (the piece's width)
800e1d18  addu $v1,$v1,$a2
800e1d1c  subu $v1,$v1,$a3
800e1d20  sh   $v1,0x8($s0)       ; packet x  = left

800e1ce8  lh   $a1,0x1a($sp)      ; Y = projection output
800e1cf8  lh   $t0,0x132e($v0)    ;     + struct[0x132E]   (scene screen offset y)
800e1cfc  lw   $t1,0x2574($a0)    ;     - H                (the piece's height)
800e1d24  addu $a1,$a1,$t0
800e1d28  subu $a1,$a1,$t1
800e1d2c  sh   $a1,0xa($s0)       ; packet y  = top
```

so

```
left   = proj_x(world) + scene_x - W        right  = left + W     (800e1d40/44)
top    = proj_y(world) + scene_y - H        bottom = top  + H     (800e1d50/54)
```

**The rule is BOTTOM-RIGHT anchored**: the rect's bottom edge sits at the
projected Y and its right edge at the projected X.  That agrees with the
measured art anchor on the vertical axis (`top = cy - h`; the measured 1 px
"foot inset" is where the *content* sits inside the rect, not a separate term).

The three Q12 inputs come from `record[0x257C] / [0x2580] / [0x2584]`, each
`sra`'d by 12 and passed to `0x8014F5C4` (the projection).

**What is NOT closed, and cannot be from MAIN alone.**  `+0x2570` and `+0x2574`
(the W/H the anchor needs) and `+0x257C..+0x2598` (the Q12 position + velocity)
are **never written anywhere in MAIN.EXE** — an exhaustive scan over every
store-ish opcode finds only reads, plus the emitter's own accumulation of the
velocity into the position.  They are populated from outside MAIN (an area or
battle overlay, or a struct copy).  So the link from the e-record's `w`/`h` to
`+0x2570`/`+0x2574` is **inferred from role, not proven from a writer** — the
`--writers` mode prints the empty result that is the evidence for that.

Usage:
    python3 sprite_dest_trace.py --trace
    python3 sprite_dest_trace.py --formula
    python3 sprite_dest_trace.py --writers 0x2570
    python3 sprite_dest_trace.py --slots
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
import mipsdec  # noqa: E402

KEY = "MAIN.EXE"
MAIN_BASE = 0x800C0800
GLOBAL_STRUCT = 0x8017BE3C      # *(0x8017BE3C): lui 0x8018 + (-0x41C4)
GLOBAL_COUNT = 0x8017AAD8       # *(0x8017AAD8): lui 0x8018 + (-0x5528)
SLOT_ARRAY = 0x2560
SLOT_STRIDE = 0x90
SLOT_COUNT = 0x14               # slti 0x14 = 20
DRAW_RECORDS = 0x40             # 40-byte packets inside each slot
PROJECT = 0x8014F5C4
ALLOCATOR = 0x800E1618
WRITER = 0x800E1654
EMITTER = 0x800E1BF8

#: the destination arithmetic, as (address, expected disassembly text)
DEST_SEQUENCE = [
    (0x800E1CE4, "lh $v1,0x18($sp)"),
    (0x800E1CE8, "lh $a1,0x1a($sp)"),
    (0x800E1CF0, "lh $a2,0x132c($v0)"),
    (0x800E1CF4, "lw $a3,0x2570($a0)"),
    (0x800E1CF8, "lh $t0,0x132e($v0)"),
    (0x800E1CFC, "lw $t1,0x2574($a0)"),
    (0x800E1D18, "addu $v1,$v1,$a2"),
    (0x800E1D1C, "subu $v1,$v1,$a3"),
    (0x800E1D20, "sh $v1,0x8($s0)"),
    (0x800E1D24, "addu $a1,$a1,$t0"),
    (0x800E1D28, "subu $a1,$a1,$t1"),
    (0x800E1D2C, "sh $a1,0xa($s0)"),
    (0x800E1D34, "lhu $v0,0x2570($a0)"),
    (0x800E1D40, "addu $v0,$v1,$v0"),
    (0x800E1D44, "sh $v0,0x10($s0)"),
    (0x800E1D48, "lhu $v0,0x2574($a0)"),
    (0x800E1D50, "addu $v0,$a1,$v0"),
    (0x800E1D54, "sh $v0,0x1a($s0)"),
]

#: store-ish opcodes, for the writer scan
STORE_OPS = {0x28: "sb", 0x29: "sh", 0x2A: "swl", 0x2B: "sw", 0x2E: "swr",
             0x39: "swc1", 0x3D: "sdc1", 0x3F: "sd"}


def image() -> bytes:
    with open(os.path.join(_KIT, "extracted", "iso_files.json")) as fh:
        rec = next(r for r in json.load(fh) if r.get("path") == KEY)
    return disc.extract(rec["lba"], rec["size"])[2048:]


def word(img: bytes, va: int) -> int:
    return struct.unpack_from("<I", img, va - MAIN_BASE)[0]


def dis(va: int, img: bytes | None = None) -> str:
    img = img or image()
    return mipsdec.dec(va, word(img, va))[0]


def trace(img: bytes | None = None) -> list[dict]:
    """Decode the destination sequence and report any instruction that moved."""
    img = img or image()
    out = []
    for va, want in DEST_SEQUENCE:
        got = dis(va, img)
        out.append({"addr": va, "want": want, "got": got, "match": got == want})
    return out


def formula() -> str:
    return ("left  = proj_x(world_q12) + struct[0x132C] - W\n"
            "top   = proj_y(world_q12) + struct[0x132E] - H\n"
            "right = left + W\n"
            "bottom= top  + H\n"
            "  W = record[+0x2570], H = record[+0x2574], struct = *(0x8017BE3C)")


def writers(off: int, img: bytes | None = None) -> list[tuple[int, str]]:
    """Every store in MAIN with this 16-bit offset.  Empty is the evidence."""
    img = img or image()
    n = len(img)
    out = []
    for i in range(0, n - 4, 4):
        w = struct.unpack_from("<I", img, i)[0]
        op = w >> 26
        if op not in STORE_OPS:
            continue
        v = w & 0xFFFF
        if v >= 0x8000:
            v -= 0x10000
        if v == off:
            out.append((MAIN_BASE + i, STORE_OPS[op]))
    return out


def slot_layout() -> dict:
    """The draw-list geometry, read from the allocator and the emitter loops."""
    img = image()
    return {
        "struct_ptr": GLOBAL_STRUCT,
        "array_off": SLOT_ARRAY,
        "stride": SLOT_STRIDE,
        "count": SLOT_COUNT,
        "array_bytes": SLOT_COUNT * SLOT_STRIDE,
        "end_off": SLOT_ARRAY + SLOT_COUNT * SLOT_STRIDE,
        "draw_records_off": DRAW_RECORDS,
        "allocator": ALLOCATOR,
        "writer": WRITER,
        "emitter": EMITTER,
        "project": PROJECT,
        "allocator_scan": dis(0x800E1628, img),
        "allocator_bound": dis(0x800E163C, img),
        "emitter_loop_bound": dis(0x800E1E0C, img),
        "packet_base": dis(0x800E1C54, img),
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--formula", action="store_true")
    ap.add_argument("--writers", help="offset, e.g. 0x2570")
    ap.add_argument("--slots", action="store_true")
    args = ap.parse_args(argv)

    if args.formula:
        print(formula())
        return 0
    if args.writers:
        off = int(args.writers, 0)
        w = writers(off)
        print(f"stores to +0x{off:04X} in {KEY}: {len(w)}")
        for a, o in w:
            print(f"  0x{a:08X}  {o}")
        if not w:
            print("  (none -- the field is populated outside MAIN.EXE)")
        return 0
    if args.slots:
        for k, v in slot_layout().items():
            print(f"  {k:20s} {v if not isinstance(v, int) else hex(v)}")
        return 0
    if args.trace:
        rows = trace()
        for r in rows:
            mark = "ok  " if r["match"] else "DRIFT"
            print(f"  {mark} 0x{r['addr']:08X}  {r['got']}")
        bad = [r for r in rows if not r["match"]]
        print(f"\n{len(rows) - len(bad)}/{len(rows)} instructions match the documented "
              f"destination sequence")
        print()
        print(formula())
        return 0
    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
