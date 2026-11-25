#!/usr/bin/env python3
"""`VC61.BIN` — what it is, derived (2026-10-06).

`VC61.BIN` (`DATA/06_AREA.C/`, LBA 99384, 31,412 B) was the one genuinely
unexplained file in the overlay/table class.  It is now characterised, and the
characterisation is a **derivation with a decisive contrast**, not a guess.

**What it is not** (each refuted, with the evidence):

| reading | refuted by |
|---|---|
| Form-2 audio misread | its sectors are Mode 2 **Form 1** (submode `0x00`, coding `0x00`) read from the raw `.bin`, identical to every sibling, so `disc.extract()` is correct |
| MIPS code | **0** `jr $ra` and **0** function prologues across all 31,412 B, while its siblings have 3..67 and 1..55 |
| an LZSS container | no `[u32 len]` framing; an MSB-first-flag variant also fails full consumption |
| a TIM | the single `0x10000000` match (0x6F0) has `blocks == 0` -- not a header |

**What it is:** a **data module stored pre-relocated for load address
`0x80080000`**.  It contains 117 `u32` slots in the RAM range `0x80010000 ..
0x801FFFFF`; **99 of them fall inside `[0x80080000, 0x80080000 + 0x7AB4)`, i.e.
inside this very file**, while the natural alternative base `0x80010000` fits only
**2 of 117**.  The remaining pointers address the area-C overlay's RAM image
(`0x8007xxxx`, and two at `0x8001xxxx`).

`0x80080000` is **exactly where the sibling overlay `VC6.BIN` ends**
(`0x80010000 + 0x70000`), which is independent corroboration and explains the
name: `VC6` + `1` is the second, contiguously-loaded part of the VC6 module.

Layout: content is **26,796 B (`0x68AC`)**, followed by **4,616 B of zero
padding** to the 31,412-byte file size.

**Derived structure.** Eleven records of `0x30` bytes at `0x450..0x630`, each 12
little-endian `u32` holding **16.16 fixed-point whole numbers**
(`0x00400000` = 64.0, `0x00F00000` = 240.0, `0xFFD00000` = -48.0):

```
[0, 64, W, W, W, V, 0, 0, D, 0, C, 0]
```

with `64` constant in all 11, the dimension **triple-equal**
(`W` in 240/256/304/320/368), `V` in {0, 7, -5, -10}, `D` in {-48, -44} and `C`
in {22, 38, 40}.  The stride, the field positions, the constant and the
triple-equality are proven; **the meaning of the fields is NOT derived** and is
not guessed here.

One game-text name appears in the whole file: **`"Dragon"` at `0x3F4`** (game
text table, not ASCII).  Everything else that scores as a "name" is random-byte
coincidence, so this is not a name table.

**The named remaining hop:** which loader path reads VC61 and what its records
mean.  The executable pair carries a `(size, LBA)` file table (MAIN.EXE
`0x801644D0` / `SLUS_002.92` `0x80045778`) whose VC61 entry is `(31412, 99384)`,
but that table carries **no load base**, which is why the base had to be derived
from the self-pointer fit.

Usage:
    python3 vc61_module.py --report
    python3 vc61_module.py --pointers
    python3 vc61_module.py --table
"""
from __future__ import annotations

import argparse
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
sys.path.insert(0, _TOOLS)
import disc  # noqa: E402

NAME = "VC61.BIN"
SIBS = ["VC1.BIN", "VC2.BIN", "VC3.BIN", "VC4.BIN", "VC5.BIN", "VC6.BIN", "VCD.BIN"]
#: derived from the self-pointer fit; equals VC6's end (0x80010000 + 0x70000)
LOAD_BASE = 0x80080000
#: the sibling overlay VC61 loads after
VC6_BASE, VC6_SIZE = 0x80010000, 0x70000
JR_RA = bytes.fromhex("0800e003")     # jr $ra = 0x03E00008, little-endian
REC_STRIDE = 0x30
RAM_LO, RAM_HI = 0x80010000, 0x801FFFFF


def load(name: str = NAME) -> bytes:
    import json

    with open(os.path.join(_KIT, "extracted", "iso_files.json")) as fh:
        recs = [r for r in json.load(fh) if not r.get("dir")]
    r = next(x for x in recs if x["path"].endswith("/" + name))
    return disc.extract(r["lba"], r["size"])


def is_code(d: bytes) -> dict:
    """The not-code evidence: `jr $ra` and function prologues."""
    jr = d.count(JR_RA)
    pro = 0
    for o in range(0, len(d) - 4, 4):
        w = struct.unpack_from("<I", d, o)[0]
        if (w >> 26) == 0x09 and ((w >> 21) & 0x1F) == 29:
            imm = w & 0xFFFF
            if imm & 0x8000:
                imm -= 0x10000
            if imm < 0:
                pro += 1
    return {"jr_ra": jr, "prologues": pro}


def content_len(d: bytes) -> tuple[int, int]:
    """`(content, zero_padding)` -- the file is zero-padded at the end."""
    c = len(d.rstrip(b"\0"))
    return c, len(d) - c


def pointers(d: bytes) -> list[tuple[int, int]]:
    """Every `u32` slot holding a RAM address, as `(offset, value)`."""
    out = []
    for o in range(0, len(d) - 4, 2):
        w = struct.unpack_from("<I", d, o)[0]
        if RAM_LO <= w <= RAM_HI:
            out.append((o, w))
    return out


def base_fit(d: bytes, base: int) -> tuple[int, int]:
    """`(inside, total)` for a candidate load base."""
    p = pointers(d)
    n = len(d)
    return sum(1 for _o, w in p if base <= w < base + n), len(p)


def best_base(d: bytes) -> list[tuple[int, int]]:
    """Candidate load bases ranked by how many pointers are self-references."""
    n = len(d)
    out = []
    for b in range(0x80010000, 0x80100000, 0x10):
        out.append((base_fit(d, b)[0], b))
    out.sort(reverse=True)
    return out


def fixed_records(d: bytes) -> list[dict]:
    """The `0x30`-stride 16.16 whole-number records.

    A record qualifies only if all twelve `u32` are whole numbers in 16.16
    (low half zero), field 1 is the constant `0x00400000` (64.0), and fields
    2/3/4 are equal and non-zero.  That is a strict signature, so the run is
    delimited by the data rather than by an assumed count.
    """
    def u32(o):
        return struct.unpack_from("<I", d, o)[0]

    hits = []
    for o in range(0, len(d) - REC_STRIDE, 4):
        vals = [u32(o + 4 * k) for k in range(12)]
        if (all((v & 0xFFFF) == 0 for v in vals) and vals[1] == 0x00400000
                and vals[2] == vals[3] == vals[4] and vals[2] != 0):
            hits.append(o)
    runs = []
    for o in hits:
        if runs and o - runs[-1][-1] == REC_STRIDE:
            runs[-1].append(o)
        else:
            runs.append([o])
    runs = [r for r in runs if len(r) >= 4]
    if not runs:
        return []
    run = max(runs, key=len)
    out = []
    for o in run:
        vals = [struct.unpack_from("<i", d, o + 4 * k)[0] >> 16 for k in range(12)]
        out.append({"off": o, "values": vals})
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--pointers", action="store_true")
    ap.add_argument("--table", action="store_true")
    args = ap.parse_args(argv)

    d = load()
    if args.pointers:
        for o, w in pointers(d):
            print(f"  0x{o:05X} -> 0x{w:08X}")
        return 0
    if args.table:
        for r in fixed_records(d):
            print(f"  0x{r['off']:04X}: {r['values']}")
        return 0

    code = is_code(d)
    c, pad = content_len(d)
    inside, tot = base_fit(d, LOAD_BASE)
    print(f"{NAME}: {len(d)} B")
    print(f"  code evidence   : jr $ra={code['jr_ra']} prologues={code['prologues']}")
    print(f"  content/padding : 0x{c:X} ({c} B) + {pad} B of zeros")
    print(f"  RAM pointers    : {tot}")
    print(f"  self-referential: {inside}/{tot} inside [0x{LOAD_BASE:08X}, "
          f"0x{LOAD_BASE + len(d):08X})")
    print(f"  alternative base: {base_fit(d, 0x80010000)[0]}/{tot} at 0x80010000")
    print(f"  VC6 ends at     : 0x{VC6_BASE + VC6_SIZE:08X}"
          f"  (equal to the derived base: {VC6_BASE + VC6_SIZE == LOAD_BASE})")
    tbl = fixed_records(d)
    print(f"  16.16 records   : {len(tbl)} at 0x{tbl[0]['off']:X}..0x{tbl[-1]['off']:X}"
          f" stride 0x{REC_STRIDE:X}")
    print("\n  siblings (code evidence, for contrast):")
    for s in SIBS:
        try:
            ds = load(s)
        except StopIteration:
            continue
        cs = is_code(ds)
        print(f"    {s:10s} {len(ds):8d} B  jr $ra={cs['jr_ra']:4d} prologues={cs['prologues']:4d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
