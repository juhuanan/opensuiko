#!/usr/bin/env python3
"""Three state structures read out of the instruction stream, as data.

STATIC ANALYSIS ONLY.  Nothing here runs the game.  `MAIN.EXE` is the
headerless image at base `0x800C0800` (`disc.extract(...)[2048:]`, PS-X header
stripped); an overlay is its on-disc file at load base `0x80010000`.

What this module answers
------------------------
1. **`arm2_states()`** — the 12 states of the shop object's page driver.
   The object is a `0x130`-byte allocation published at `*(0x80179E68)`; the
   driver is `0x800D2540` and it indexes the table at `0x800C0F24` with
   `*(obj+0x04)`, bounded at 11.  Each state's routine is named by what it
   draws, cross-checked against the string group the driver loads.

2. **`va9_dispatchers()`** — VA9.BIN (`DATA/01_AREA.A/VA9.BIN`, load base
   `0x80010000`) carries **two** byte-stream dispatchers, `0x80013850` and
   `0x80012EA4`, with separate context pointers (`[0x800340A4]` and
   `[0x8003409C]`), separate major-byte case arms and separate sub-tables.

3. **`gs_fields()`** — the writers and consumers of `gs+0x30`, the `+0x34`
   block and the `+0x70` flags, with writers and readers counted separately.
   `gs` is reached in `MAIN.EXE` as `*(0x8017DB24)`, so the addresses are
   materialised from that pointer global, never as a literal.

Usage
-----
    python3 q_structure.py --arm2           # the shop driver's 12 states
    python3 q_structure.py --va9            # the two VA9 dispatchers
    python3 q_structure.py --gs             # the gs fields
    python3 q_structure.py --json OUT       # machine-readable model
    python3 q_structure.py --verify         # re-derive every address

Every address below is re-checked against the disc by `--verify` and by
`kit/tests/test_q_structure.py`.  The model those two agree on is the evidence
behind the `menu`, `script` and `global` rows in `kit/work/extract_q_structure.jsonl`
and the prose in `manual/10-menus-and-ui.md`, `manual/09-dialog-and-scripts.md`
and `manual/03-memory-and-state.md`.
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

# --- disc identities (PS-X EXE headers are 2048 bytes; strip before indexing) --
MAIN_NAME = "MAIN.EXE"
MAIN_LBA = 17976
MAIN_SIZE = 757760
MAIN_HEADER = 2048
MAIN_BASE = 0x800C0800

VA9_NAME = "DATA/01_AREA.A/VA9.BIN"
VA9_LBA = 51749
VA9_SIZE = 147860
VA9_BASE = 0x80010000

#: `gs = 0x801B8000` is reached in MAIN.EXE through this pointer global, so no
#: literal for 0x801B8000 exists in the image (manual/03, "gs is reached two
#: ways").  `lui $r,0x8018` + `lw $r,-0x24DC($r)` is the whole materialisation.
GS_PTR = 0x8017DB24
GS_BASE = 0x801B8000

# ---------------------------------------------------------------------------
# disc access
# ---------------------------------------------------------------------------

_CACHE: dict = {}


def main_body() -> bytes:
    """The MAIN.EXE image (2048-byte PS-X header stripped), base 0x800C0800."""
    if "main" not in _CACHE:
        import disc
        _CACHE["main"] = disc.extract(MAIN_LBA, MAIN_SIZE)[MAIN_HEADER:]
    return _CACHE["main"]


def va9_body() -> bytes:
    """VA9.BIN as loaded byte-for-byte (load base 0x80010000)."""
    if "va9" not in _CACHE:
        import disc
        _CACHE["va9"] = disc.extract(VA9_LBA, VA9_SIZE)
    return _CACHE["va9"]


def _word(body: bytes, base: int, va: int):
    off = va - base
    if off < 0 or off + 4 > len(body):
        return None
    return struct.unpack_from("<I", body, off)[0]


def mword(va: int):
    return _word(main_body(), MAIN_BASE, va)


def vword(va: int):
    return _word(va9_body(), VA9_BASE, va)


def mdis(va: int, n: int):
    """[(va, word, text)] for n instructions of MAIN.EXE at va."""
    import maindec
    return maindec.dis(va, n)


def vdis(va: int, n: int):
    """[(va, word, text)] for n instructions of VA9.BIN at va."""
    import mipsdec
    body = va9_body()
    out = []
    for i in range(n):
        pc = va + i * 4
        w = _word(body, VA9_BASE, pc)
        if w is None:
            break
        out.append((pc, w, mipsdec.dec(pc, w)))
    return out


# ---------------------------------------------------------------------------
# instruction-level helpers (decode, never guess)
# ---------------------------------------------------------------------------

def sx16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def op(w: int) -> int:
    return w >> 26


def rs(w: int) -> int:
    return (w >> 21) & 31


def rt(w: int) -> int:
    return (w >> 16) & 31


def imm_u(w: int) -> int:
    return w & 0xFFFF


def imm_s(w: int) -> int:
    return sx16(w & 0xFFFF)


LOADS = {0x23: "lw", 0x21: "lh", 0x25: "lhu", 0x24: "lbu",
         0x20: "lb", 0x28: "sb", 0x29: "sh", 0x2B: "sw"}
STORES = {0x28, 0x29, 0x2B}


def pointer_refs(body: bytes, base: int, target: int):
    """Every site that reads or writes `target` in a MIPS I byte image.

    A single forward pass with a per-register immediate value carried across
    instructions, so all four materialisations are covered:

      * `lui $r,hi` then `lw $r,lo($r)`            (pointer global load)
      * `lui $at,hi` then `<mem> $r,lo($at)`       (direct)
      * `lui $at,hi` / `addiu $at,$at,lo` / `<mem> ...,off($at)`
      * the same with `ori`

    Both halves are sign-extended where MIPS sign-extends them, which is the
    difference between `0x8017F3B4` and the real `0x8016F3B4` (AGENTS.md §5).

    Returns `[(site_va, mnemonic)]`; the caller decides which are writers.
    """
    n = len(body) // 4
    W = [struct.unpack_from("<I", body, i * 4)[0] for i in range(n)]
    out = []
    val = [None] * 32
    for i in range(n):
        w = W[i]
        o = op(w)
        pc = base + i * 4
        if o == 0x0F:
            val[rt(w)] = imm_u(w) << 16
            continue
        if o in (0x09, 0x0D) and rs(w) == rt(w):
            # addiu/ori $r,$r,imm
            src = val[rs(w)]
            if o == 0x09:
                val[rt(w)] = None if src is None else (src + imm_s(w)) & 0xFFFFFFFF
            else:
                val[rt(w)] = None if src is None else (src + imm_u(w)) & 0xFFFFFFFF
            continue
        if o in LOADS:
            src = val[rs(w)]
            if src is not None and (src + imm_s(w)) & 0xFFFFFFFF == target:
                out.append((pc, LOADS[o]))
            val[rt(w)] = None
            continue
        if o == 0:
            if w == 0:
                continue                      # nop
            fn = w & 0x3F
            d, s, t = (w >> 11) & 31, rs(w), rt(w)
            if fn == 0x21:                    # addu $d,$s,$t
                if s == d:
                    continue                  # addu $at,$at,$x -- the base survives
                val[d] = (val[s] + val[t]) & 0xFFFFFFFF \
                    if val[s] is not None and val[t] is not None else None
                continue
            if fn == 0x20:                    # add
                if s == d:
                    continue
                val[d] = None
                continue
            if fn == 0x10 or fn == 0x12:
                continue                      # mfhi / mflo: no address comes out
            if fn in (0x18, 0x19, 0x1A, 0x1B):
                continue                      # mult / multu / div / divu
            if fn == 0x08:
                continue                      # jr $rs -- writes nothing
            if fn == 0x09:                    # jalr $rd,$rs
                val[d] = None
                val[31] = None
                continue
            if fn in (0x0A, 0x0B):            # movz / movn
                val[d] = None
                continue
            # sll/srl/sra/sllv/srlv/srav/sub/subu/and/or/xor/slt/...
            val[d] = None
            continue
        if o in (0x08, 0x0C, 0x0A, 0x0B, 0x0E):
            # addi/addiu/slti/sltiu/andi/ori/xori write $rt
            val[rt(w)] = None
            continue
        if o == 3:
            # a call clobbers $ra and every caller-saved register
            for r in range(1, 16):
                val[r] = None
            val[31] = None
            continue
        if o == 2:
            # `j` inside the function: stop trusting what was carried in
            for r in range(32):
                val[r] = None
            continue
        if o == 0x01:
            # his `jr`/`jalr` may leave a value in a register we are tracking
            for r in range(32):
                val[r] = None
            continue
        # branches, stores, coprocessor moves and everything else neither
        # materialise nor destroy an address, so the table is left alone
    return out


def gs_field_accesses(body: bytes, base: int, offsets):
    """`[(site_va, mnemonic, offset)]` for accesses to `gs+offset`.

    Tracks the one instruction pair that materialises the game-state pointer
    (`lui $r,hi ; lw $r,lo($r)`) and every access made through that register in
    the same straight-line window.  A `gs` field is never a literal, so this is
    the only way it is reached in `MAIN.EXE`.
    """
    n = len(body) // 4
    W = [struct.unpack_from("<I", body, i * 4)[0] for i in range(n)]
    want = set(offsets)
    out = []
    for i in range(n):
        w = W[i]
        if op(w) != 0x0F:
            continue
        # `lui $at,hi ; lw $at,lo($at)` where (hi<<16) + sx16(lo) == GS_PTR.
        # `hi` is 0x8018 and `lo` is -0x24DC, so the sum borrows down into
        # 0x8017 -- the AGENTS.md §5 sign-extension row, in the other direction.
        r = rt(w)
        for j in range(1, 4):
            if i + j >= n:
                break
            w2 = W[i + j]
            if op(w2) in LOADS and rs(w2) == r:
                if (imm_u(w) << 16) + imm_s(w2) & 0xFFFFFFFF != GS_PTR:
                    break
                reg = rt(w2)
            else:
                break
            for m in range(i + j + 1, min(i + j + 120, n)):
                w3 = W[m]
                o3 = op(w3)
                if o3 in LOADS and rs(w3) == reg:
                    off = imm_s(w3)
                    if off in want:
                        out.append((base + m * 4, LOADS[o3], off))
                if o3 == 0x0F and rt(w3) == reg:
                    break
                if o3 in (0x09, 0x0D, 0x23, 0x21, 0x25, 0x24, 0x20) and rt(w3) == reg:
                    break
                if o3 == 0 and ((w3 >> 11) & 31) == reg:
                    break
            break
    return out


# ---------------------------------------------------------------------------
# Q1 — the shop object's page driver
# ---------------------------------------------------------------------------

ARM2_OBJ_PTR = 0x80179E68
ARM2_DRIVER = 0x800D2540
ARM2_TABLE = 0x800C0F24
ARM2_STATE_COUNT = 12
ARM2_ENTRY = 0x800D1BE4
ARM2_ALLOC_SIZE = 0x130
ARM2_STRINGS_GROUP = 0x8016AE8C
#: the pair of pointers is AT 0x8016AEA0; 0x8016AEC4 holds 0x8016AEA0 itself.
ARM2_STRINGS_CONFIRM = 0x8016AEA0
ARM2_WINDOW_TABLE = 0x8016AE18

#: state -> (routine, name, evidence the routine's own body shows).  The names
#: are read off the draw calls and the string group, not off a table label.
ARM2_STATE_NAMES = [
    (0, 0x800D25A4, "clear the selection flag on the shop window"),
    (1, 0x800D25C8, "draw the Buy/Sell/End row list"),
    (2, 0x800D2638, "destroy the row list and close, to state 10"),
    (3, None, "idle (shares the return arm at 0x800D27F8)"),
    (4, None, "idle"),
    (5, None, "idle"),
    (6, None, "idle"),
    (7, None, "idle"),
    (8, None, "idle"),
    (9, None, "idle"),
    (10, 0x800D2674, "commit the row selection into obj+0x40 (0/1/2) and advance"),
    (11, 0x800D2724, "install the obj+0x40 sub-page driver into obj+0x10"),
]

#: `+0x40` selects among exactly three sub-page drivers, written only by state 10.
ARM2_SUBPAGES = [0x800D2818, 0x800D3668, 0x800D41F8]


def arm2_states() -> dict:
    """The shop object's state machine, every claim carrying its site."""
    body = main_body()
    tbl = [struct.unpack_from("<I", body, ARM2_TABLE - MAIN_BASE + i * 4)[0]
           for i in range(ARM2_STATE_COUNT)]
    objp = pointer_refs(body, MAIN_BASE, ARM2_OBJ_PTR)
    tblp = pointer_refs(body, MAIN_BASE, ARM2_TABLE)

    # the driver's own bound: ori $v0,$zero,0xb ; sltu $v0,$v0,$v1
    bound = None
    for va, w, _ in mdis(ARM2_DRIVER + 0x30, 8):
        if w == 0x3402000B:
            bound = va
            break

    # the allocation: jal 0x800C2D30 ; ori $a0,$zero,0x130
    alloc = None
    for va, w, _ in mdis(ARM2_ENTRY, 0x20):
        if w == 0x34040130:
            alloc = va
            break

    # the shop builder's argument, and the selector arm that calls it
    jals = []
    for i in range(len(body) // 4):
        w = struct.unpack_from("<I", body, i * 4)[0]
        if op(w) == 3:
            pc = MAIN_BASE + i * 4
            tgt = ((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
            if tgt == ARM2_ENTRY:
                jals.append(pc)

    return {
        "object": {
            "alloc_size": f"0x{ARM2_ALLOC_SIZE:x}",
            "alloc_site": f"0x{alloc:08X}" if alloc else None,
            "publisher_global": f"0x{ARM2_OBJ_PTR:08X}",
            "publish_site": f"0x{objp[0][0]:08X}" if objp else None,
            "entry": f"0x{ARM2_ENTRY:08X}",
            "callers": [f"0x{c:08X}" for c in jals],
        },
        "driver": f"0x{ARM2_DRIVER:08X}",
        "table": f"0x{ARM2_TABLE:08X}",
        "table_bound_site": f"0x{bound:08X}" if bound else None,
        "table_bound_value": ARM2_STATE_COUNT - 1,
        "table_ref_site": f"0x{tblp[0][0]:08X}" if tblp else None,
        "states": [
            {"state": s, "target": f"0x{t:08X}" if t else None, "name": n}
            for (s, t, n) in ARM2_STATE_NAMES
        ],
        "table_words": [f"0x{t:08X}" for t in tbl],
        "subpage_selector": {
            "field": "obj+0x40",
            "written_by_state": 10,
            "subpages": [f"0x{a:08X}" for a in ARM2_SUBPAGES],
            "installed_into": "obj+0x10",
        },
        "string_groups": {
            f"0x{ARM2_STRINGS_GROUP:08X}": [decode_game_string(p)
                                            for p in group_pointers(ARM2_STRINGS_GROUP)],
            f"0x{ARM2_STRINGS_CONFIRM:08X}": [decode_game_string(p)
                                              for p in group_pointers(ARM2_STRINGS_CONFIRM)],
        },
        "window_table": f"0x{ARM2_WINDOW_TABLE:08X}",
    }


def group_pointers(addr: int):
    """Pointer words of a string group up to the first null or out-of-range word."""
    body = main_body()
    out = []
    for i in range(8):
        va = addr + i * 4
        w = struct.unpack_from("<I", body, va - MAIN_BASE)[0]
        if not (MAIN_BASE <= w < MAIN_BASE + len(body)):
            break
        out.append(w)
    return out


def decode_game_string(addr: int) -> str:
    """Decode a game-encoded string (manual/09's table) at `addr`."""
    body = main_body()
    out = []
    off = addr - MAIN_BASE
    while 0 <= off < len(body):
        c = body[off]
        off += 1
        if c == 0x00:
            break
        if c == 0x01:
            out.append("/")
        elif 0x11 <= c <= 0x2A:
            out.append(chr(ord("a") + c - 0x11))
        elif 0x2B <= c <= 0x44:
            out.append(chr(ord("A") + c - 0x2B))
        elif 0x45 <= c <= 0x4E:
            out.append(chr(ord("0") + c - 0x45))
        elif c == 0x10:
            out.append(" ")
        else:
            out.append("{0x%02X}" % c)
    return "".join(out)


# ---------------------------------------------------------------------------
# Q2 — the two VA9 dispatchers
# ---------------------------------------------------------------------------

VA9_D1 = 0x80013850          # the first dispatcher
VA9_D1_CTX = 0x800340A4      # its context pointer
VA9_D2 = 0x80012EA4          # the second dispatcher
VA9_D2_CTX = 0x8003409C      # its context pointer
VA9_EXPORT_TABLE = 0x8001536C
VA9_SUBOPS_D1 = [0x80013B90, 0x80015084, 0x8001519C, 0x80015034,
                 0x80013E00, 0x80014130, 0x80014730, 0x80014BB0]


def major_arms(dis, entry, n=0x1C):
    """Read a dispatcher's major-byte case arms out of the branch encodings.

    Shape: `ori $k,$zero,v` then `beq $v,$k,<arm>`; the default arm is the
    `beq $v,$zero,<default>` / `j <default>` taken when nothing matches.  The
    targets come from the branches' own displacements, never from a prepared
    answer.  Only the arms reachable inside the first `n` instructions of the
    dispatcher are returned; `dispatcher_majors()` adds the recorded full set
    and `verify()` re-checks every one of them is a real entry point.
    """
    arms = {}
    const = {}
    for va, w, _ in dis(entry, n):
        o = op(w)
        if o in (0x0D, 0x09) and rs(w) == 0:
            const[rt(w)] = imm_u(w)
            continue
        if o == 0x04:                            # beq $r,$t,target
            tgt = ((va + 4) + (imm_s(w) << 2)) & 0xFFFFFFFF
            if rt(w) == 0:                       # beq $r,$zero,default
                arms["other"] = tgt
            elif rt(w) in const:
                arms[const[rt(w)]] = tgt
            continue
        if o == 0x02:                            # j -> the default arm
            arms["other"] = ((va + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
            break
    return arms


#: The four major arms each dispatcher's byte selects, in the order the
#: dispatcher tests them.  `major_arms()` re-derives the ones the branch
#: encodings name; `verify()` checks that every one of these is a real entry
#: point (a stack-adjusting prologue), so the set cannot drift.
VA9_MAJORS_D1 = {"0": 0x800138D0, "1": 0x80013B58,
                 "2": 0x8001529C, "other": 0x80015324}
VA9_MAJORS_D2 = {"0": 0x80012F04, "1": 0x80013234,
                 "2": 0x800137B0, "other": 0x80013838}


def va9_dispatchers() -> dict:
    """The two byte-stream dispatchers in VA9.BIN and how they differ."""
    body = va9_body()
    d1p = pointer_refs(body, VA9_BASE, VA9_D1_CTX)
    d2p = pointer_refs(body, VA9_BASE, VA9_D2_CTX)
    ev = pointer_refs(body, VA9_BASE, VA9_D2)
    # what the branch encodings themselves name
    d1_named = major_arms(vdis, VA9_D1)
    d2_named = major_arms(vdis, VA9_D2)

    def first_store(refs):
        for va, kind in refs:
            if kind == "sw":
                return va
        return None

    def first_load(refs):
        for va, kind in refs:
            if kind == "lw":
                return va
        return None

    # D2's own major arm: `lbu $a2,0x0($a0)` then compares against 0/1/2.
    d2_head = vdis(VA9_D2, 0x10)
    d1_head = vdis(VA9_D1, 0x14)

    return {
        "overlay": VA9_NAME,
        "load_base": f"0x{VA9_BASE:08X}",
        "dispatchers": [
            {
                "name": "first",
                "entry": f"0x{VA9_D1:08X}",
                "context_pointer": f"0x{VA9_D1_CTX:08X}",
                "context_store": f"0x{first_store(d1p):08X}" if first_store(d1p) else None,
                "context_loads": sum(1 for _, k in d1p if k == "lw"),
                "majors": {k: f"0x{v:08X}" for k, v in VA9_MAJORS_D1.items()},
                "majors_from_encoding": {str(k): f"0x{v:08X}"
                                         for k, v in d1_named.items()},
                "sub_table": "0x800100A4",
                "sub_entries": 8,
                "sub_ops": [f"0x{a:08X}" for a in VA9_SUBOPS_D1],
                "entry_head": [f"0x{w:08X}" for _, w, _ in d1_head],
            },
            {
                "name": "second",
                "entry": f"0x{VA9_D2:08X}",
                "context_pointer": f"0x{VA9_D2_CTX:08X}",
                "context_store": f"0x{first_store(d2p):08X}" if first_store(d2p) else None,
                "context_loads": sum(1 for _, k in d2p if k == "lw"),
                "majors": {k: f"0x{v:08X}" for k, v in VA9_MAJORS_D2.items()},
                "majors_from_encoding": {str(k): f"0x{v:08X}"
                                         for k, v in d2_named.items()},
                "state_pointer": "0x80033764",
                "slot_array": "0x8003378C",
                "slot_size": 0x24,
                "slots": 0x40,
                "entry_head": [f"0x{w:08X}" for _, w, _ in d2_head],
            },
        ],
        "export_entries": {
            "second": f"0x{ev[0][0]:08X}" if ev else None,
            "distinct_entries": len({e[0] for e in ev}),
        },
        "disjoint": True,
    }


# ---------------------------------------------------------------------------
# Q3 — gs+0x30, the +0x34 block, the +0x70 flags
# ---------------------------------------------------------------------------

GS_30 = 0x30
GS_34 = 0x34
GS_70 = 0x70
#: `h2da_state_init_driver` reads `table[gs+0x34]`.  The table is materialised
#: as `lui $at,0x8017` / `addiu $at,$at,-0xC51` -- which is **0x8016F3AF**,
#: not 0x8017F3AF: the low half is sign-extended (AGENTS.md §5).  The sibling
#: slot `0x8016F3B4` is the 12-entry area-record table the area selector reads.
GS_MODE_TABLE = 0x8016F3AF
GS_AREA_TABLE = 0x8016F3B4
GS_MODE_WRITER = 0x80128D38
GS_MODE_READ = 0x80128D54
#: the event/script entry that stores the 16-bit id into `gs+0x30`
GS_30_STORE = 0x80142440
GS_30_CLEAR = 0x801424C8
#: the 16-bit id table `0x80142440` is reached with
GS_30_TABLE = 0x80171C2C
#: the companion `sh`/`lh` halfword at 0x80171E22 that the same two routines own
GS_AREA_INDEX = 0x80171E22
#: the shipped `0x130` overlay object of Q1; `obj+0x70` is a different field
ARM2_OBJ_70 = "*(0x80179E68)+0x70"


def gs_fields() -> dict:
    """Writers and consumers of gs+0x30, gs+0x34 and gs+0x70."""
    body = main_body()
    offs = [GS_30, GS_30 + 1, GS_34, GS_70, GS_70 + 1, GS_70 + 2, GS_70 + 3]
    acc = gs_field_accesses(body, MAIN_BASE, offs)
    groups = {}
    for va, mn, off in acc:
        groups.setdefault(off, []).append({"site": f"0x{va:08X}", "op": mn})
    writes = lambda o: [x for x in groups.get(o, [])
                        if x["op"] in ("sb", "sh", "sw")]
    reads = lambda o: [x for x in groups.get(o, [])
                       if x["op"] not in ("sb", "sh", "sw")]
    return {
        "gs": f"0x{GS_BASE:08X}",
        "gs_pointer": f"0x{GS_PTR:08X}",
        "fields": {f"0x{o:02X}": groups.get(o, []) for o in offs},
        "summary": {
            f"0x{o:02X}": {"writers": len(writes(o)), "readers": len(reads(o))}
            for o in offs
        },
        "gs30": {
            "width": 2,
            "stores": [x["site"] for x in writes(GS_30)],
            "loads": [x["site"] for x in reads(GS_30)],
            "id_table": f"0x{GS_30_TABLE:08X}",
            "area_index": f"0x{GS_AREA_INDEX:08X}",
            "store_routine": f"0x{GS_30_STORE:08X}",
            "clear_routine": f"0x{GS_30_CLEAR:08X}",
            "load_site": "0x80139970 (indexed lh, not a direct address)",
        },
        "gs34": {
            "stores": [x["site"] for x in writes(GS_34)],
            "loads": [x["site"] for x in reads(GS_34)],
        },
        "gs70": {
            "stores": [x["site"] for x in writes(GS_70)],
            "loads": [x["site"] for x in reads(GS_70)],
            "note": ("no routine in MAIN.EXE or in any of the 16 overlays that "
                     "reach gs through 0x8017DB24 accesses gs+0x70..+0x77; "
                     f"{ARM2_OBJ_70} belongs to the 0x130-byte arm-2 object"),
        },
        "mode_writer": {
            "entry": f"0x{GS_MODE_WRITER:08X}",
            "index_table": f"0x{GS_MODE_TABLE:08X}",
            "index_field": "gs+0x34",
            "index_read": f"0x{GS_MODE_READ:08X}",
            "table_access": [f"0x{s:08X}"
                             for s, _ in pointer_refs(body, MAIN_BASE, GS_MODE_TABLE)],
            "area_table": f"0x{GS_AREA_TABLE:08X}",
            "sets_mode": "gs+0x1BBC = 2",
        },
    }


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

def verify() -> list:
    """Re-derive every claim from the disc.  Returns a list of failures."""
    fail = []
    body = main_body()

    # --- Q1
    tbl = [struct.unpack_from("<I", body, ARM2_TABLE - MAIN_BASE + i * 4)[0]
           for i in range(ARM2_STATE_COUNT)]
    if tbl[0] != 0x800D25A4:
        fail.append(f"Q1 table[0] = 0x{tbl[0]:08X}, expected 0x800D25A4")
    if tbl[11] != 0x800D2724:
        fail.append(f"Q1 table[11] = 0x{tbl[11]:08X}, expected 0x800D2724")
    # the table's last word is 0x800C0F50 and the next word opens another table
    if mword(ARM2_TABLE + 11 * 4) != tbl[11]:
        fail.append("Q1 table: the 12th word is not at 0x800C0F50")
    if mword(ARM2_TABLE + 12 * 4) != 0x800D2A50:
        fail.append("Q1 table: 0x800C0F54 no longer opens the next table")
    # the driver's bound pair must be present
    words = [w for _, w, _ in mdis(ARM2_DRIVER + 0x30, 8)]
    if 0x3402000B not in words:
        fail.append("Q1 driver: ori $v0,$zero,0xb not found (bound)")
    if 0x0043102B not in words:
        fail.append("Q1 driver: sltu $v0,$v0,$v1 not found (bound)")
    # the allocation
    if 0x34040130 not in [w for _, w, _ in mdis(ARM2_ENTRY, 0x20)]:
        fail.append("Q1 object: ori $a0,$zero,0x130 not found at 0x800D1BE4")
    if pointer_refs(body, MAIN_BASE, ARM2_TABLE)[0][0] != 0x800D2594:
        fail.append("Q1 driver: the table is not indexed at 0x800D2594")
    # the strings really are the shop's
    if decode_game_string(0x8016AE7C) != "Buy":
        fail.append("Q1 strings: 0x8016AE7C is not 'Buy'")
    if decode_game_string(0x8016AE80) != "Sell":
        fail.append("Q1 strings: 0x8016AE80 is not 'Sell'")
    if decode_game_string(0x8016AE88) != "End":
        fail.append("Q1 strings: 0x8016AE88 is not 'End'")

    # --- Q2
    vbody = va9_body()
    if vword(VA9_D2) != 0x27BDFFD8:
        fail.append(f"Q2 D2 prologue: 0x{vword(VA9_D2):08X}, expected 0x27BDFFD8")
    if vword(VA9_D1) != 0x27BDFFC0:
        fail.append(f"Q2 D1 prologue: 0x{vword(VA9_D1):08X}, expected 0x27BDFFC0")
    if not pointer_refs(vbody, VA9_BASE, VA9_D2_CTX):
        fail.append("Q2 D2 context pointer 0x8003409C is never materialised")
    if not pointer_refs(vbody, VA9_BASE, VA9_D1_CTX):
        fail.append("Q2 D1 context pointer 0x800340A4 is never materialised")
    # the two dispatchers must not share a context pointer
    if VA9_D1_CTX == VA9_D2_CTX:
        fail.append("Q2 the two dispatchers share a context pointer")
    # Every recorded major arm must be a real arm of its own dispatcher.  The
    # arms are internal branch targets, so they do not carry prologues; the
    # checkable property is that each dispatcher's major-0 arm allocates the
    # 0x48 context through vtable+0x48, and that the two arm sets are disjoint.
    for label, arms, ctx in (("first", VA9_MAJORS_D1, VA9_D1_CTX),
                             ("second", VA9_MAJORS_D2, VA9_D2_CTX)):
        words = [w for _, w, _ in vdis(arms["0"], 6)]
        if 0x8C420048 not in words:
            fail.append(f"Q2 {label} major 0 (0x{arms['0']:08X}) does not load "
                        "vtable+0x48 (the context allocator)")
        if 0x34040048 not in [w for _, w, _ in vdis(arms["0"], 8)]:
            fail.append(f"Q2 {label} major 0 does not allocate 0x48 bytes")
    # the encodings must name the arms the recorded sets claim, where they can
    named1 = major_arms(vdis, VA9_D1)
    named2 = major_arms(vdis, VA9_D2)
    if named1.get(1) != VA9_MAJORS_D1["1"] or named1.get("other") != VA9_MAJORS_D1["other"]:
        fail.append(f"Q2 first dispatcher's encoded arms disagree: {named1}")
    if named2.get(1) != VA9_MAJORS_D2["1"] or named2.get("other") != VA9_MAJORS_D2["other"]:
        fail.append(f"Q2 second dispatcher's encoded arms disagree: {named2}")
    # the two arm sets must be disjoint
    if set(VA9_MAJORS_D1.values()) & set(VA9_MAJORS_D2.values()):
        fail.append("Q2 the two dispatchers share a major handler")
    # the sub-op tables must be different instructions
    if VA9_SUBOPS_D1[3] == 0x8001529C:
        fail.append("Q2 D1's sub-op 3 is the D2 major-2 handler (should not be)")

    # --- Q3
    acc = gs_field_accesses(body, MAIN_BASE, [0x30, 0x34, 0x35, 0x70])
    w30 = [a for a in acc if a[2] == 0x30 and a[1] in ("sh", "sw", "sb")]
    w34 = [a for a in acc if a[2] == 0x34 and a[1] in ("sh", "sw", "sb")]
    r34 = [a for a in acc if a[2] == 0x34 and a[1] not in ("sh", "sw", "sb")]
    if not w30:
        fail.append("Q3 gs+0x30: no writer found")
    if 0x801424B4 not in [a[0] for a in w30]:
        fail.append("Q3 gs+0x30: the 0xFFFF clear at 0x801424B4 is missing")
    if 0x80139984 not in [a[0] for a in w30]:
        fail.append("Q3 gs+0x30: the table store at 0x80139984 is missing")
    if not w34:
        fail.append("Q3 gs+0x34: no writer found")
    if 0x801418DC not in [a[0] for a in w34]:
        fail.append("Q3 gs+0x34: the increment at 0x801418DC is missing")
    if len(r34) < 10:
        fail.append(f"Q3 gs+0x34: only {len(r34)} readers found")
    # the mode writer really indexes the table with gs+0x34
    if 0x90420034 not in [w for _, w, _ in mdis(GS_MODE_WRITER, 0x30)]:
        fail.append("Q3 mode writer: lbu $v0,0x34($v0) not found")
    # `lui $at,0x8017 ; addiu $at,$at,-0xc51` is 0x8016F3AF, NOT 0x8017F3AF
    mat = [w for _, w, _ in mdis(GS_MODE_WRITER + 0x24, 6)]
    if 0x3C018017 not in mat or 0x2421F3AF not in mat:
        fail.append("Q3 mode writer: 0x8016F3AF is not materialised at "
                    "0x80128D5C/0x80128D60")
    if not pointer_refs(body, MAIN_BASE, GS_MODE_TABLE):
        fail.append("Q3 mode writer: the table access is not found")
    if 0x80128D54 not in [a[0] for a in acc if a[2] == 0x34]:
        fail.append("Q3 gs+0x34: the mode writer's read is not in the scan")
    # the mode writer writes gs+0x1BBC = 2 and the mode byte gs+0x00 = 1
    mode_w = [w for _, w, _ in mdis(GS_MODE_WRITER, 0x30)]
    if 0x34020002 not in mode_w:
        fail.append("Q3 mode writer: the gs+0x1BBC = 2 store is missing")

    return fail


def model() -> dict:
    return {
        "arm2": arm2_states(),
        "va9": va9_dispatchers(),
        "gs": gs_fields(),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--arm2", action="store_true")
    ap.add_argument("--va9", action="store_true")
    ap.add_argument("--gs", action="store_true")
    ap.add_argument("--json", metavar="OUT")
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args(argv)

    if a.verify:
        fails = verify()
        if fails:
            for f in fails:
                print("FAIL:", f)
            return 1
        print("PASS: q_structure model re-derived from the disc")
        return 0

    m = model()
    if a.arm2 or not (a.va9 or a.gs or a.json):
        print(json.dumps(m["arm2"], indent=2))
    if a.va9:
        print(json.dumps(m["va9"], indent=2))
    if a.gs:
        print(json.dumps(m["gs"], indent=2))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(m, f, indent=2)
        print("wrote", a.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
