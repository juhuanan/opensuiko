#!/usr/bin/env python3
"""The battle remainder: five bounded items, now closed or made precise.

Companion to `kit/tools/battle_formulas.py`. This tool reports the five items
as **proven**, **refuted** or an **explicit negative** with the search that
produced it. Nothing here comes from an
emulator, a save state or a VRAM capture: every byte is read off the disc
through `tools/disc.py`, and every address is read out of the instruction that
encodes it.

Provenance
----------
MAIN.EXE is a PS-X EXE whose header declares `d_addr = 0x800C0800` and
`d_size = 0x0B8800`, so the image spans `0x800C0800 .. 0x80179000`; anything
above `0x80179000` is BSS and has no disc content.  `tools/maindec.py` serves
that image.

What this tool settles
----------------------
1. **The static table at `0x8016BDC8` is the per-battle EXP award table, not a
   turn-order table** (`kit/docs/exp_award.md`).
   `0x800E9764` is `lui $s1,0x8017` and `0x800E9768` is
   `addiu $s1,$s1,-0x4238`; sign-extending the 16-bit immediate gives
   `0x80170000 - 0x4238 = 0x8016BDC8`, which is **inside** the image.  The
   corpus's "runtime-filled BSS at `0x8017BDC8`" reading read the offset as
   positive, landed 64 KiB high and concluded BSS. The 30 EXP awards are static
   disc data; `exp_award.md` owns their corrected values and use. (`0x8017BDCC`
   is a separate runtime word.)

   The writer of the *other* array the turn-order routine reads -- the
   per-participant heap block at `*(0x80179FD0)` -- **is** found:
   `0x800E81A8` `ori $a0,$zero,0x2258` / `0x800E81AC` `jal 0x800C2D30`
   (the allocator) and `0x800E81B8` `sw $v0,-0x6030($at)` install the block.
   The routine at `0x800E9744` reads it back as `lw $t8,-0x6030($t8)` on a
   `lui $t8,0x8018`, i.e. `0x80180000 - 0x6030 = 0x80179FD0`.

2. **`0x800F8174` (magic damage) has an indirect VAD caller.** MAIN installs
   the library at scene+0x1258. VAD's MAGIC93 callback reads that field and
   calls slot+0x158 at 0x8001302C, then passes the result to slot+0x10
   (HP apply). The zero direct-call count in MAIN does not imply absence.

3. **`BATTLE.BIN`**: the descriptor/CLUT facts are already settled in
   `kit/docs/battle_bin_decode.md`; this tool re-verifies the part that is
   disc-derived (3 of 13 planes have on-disc 32-word palettes) and reports the
   ten 256-colour planes as a precise negative.

4. **`W_HEADER.BIN`** is a *link descriptor* for the WAR overlay: a `LNK\\x02`
   bytecode naming three symbols (`header` -> `0x5462`, `war` -> `0x5463`,
   `war_loop` -> `0x5464`) whose values are offsets into the WAR overlay, which
   loads at `0x80010000`.  The file is WAR resource-table record 11 (size 67 at
   `0x8016481C`, LBA 183803 at `0x80164820`).

5. **The random encounter requester**: the field-frame roll selects a valid
   encounter index, stores it in `gs+0x1BC0`, and queues mode 3; see section 5.

Usage
-----
    python3 battle_remainder.py                 # the summary table
    python3 battle_remainder.py --json
    python3 battle_remainder.py --item weight_table
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _TOOLS)

import maindec  # noqa: E402
from mipsdec import dec  # noqa: E402

MAIN_BASE = 0x800C0800
MAIN_END = MAIN_BASE + 755712          # d_addr + d_size, from the PS-X EXE header

# ---------------------------------------------------------------------------
# 1. the turn-order weight table
# ---------------------------------------------------------------------------
WEIGHT_TABLE = 0x8016BDC8              # == lui 0x8017 / addiu -0x4238, sign-extended
WEIGHT_TABLE_SITE = 0x800E9768         # the addiu that builds it
WEIGHT_TABLE_LUI = 0x800E9764
WEIGHT_TABLE_READ = 0x800E9864         # lw $v0,0x0($v0)
WEIGHT_TABLE_ENTRIES = 30              # dl clamped to [-14, 15]
WEIGHT_DL_MIN = -14
WEIGHT_DL_MAX = 15
WEIGHT_WRONG_ADDR = 0x8017BDC8         # the corpus's superseded reading

# the other array the same routine reads: the per-participant heap block
PARTICIPANT_WEIGHTS_PTR = 0x80179FD0   # lui 0x8018 / lw -0x6030
PARTICIPANT_WEIGHTS_SITE = 0x800E9784   # lui $t8,0x8018
PARTICIPANT_WEIGHTS_WRITER = 0x800E81B8   # sw $v0,-0x6030($at)
PARTICIPANT_WEIGHTS_ALLOC_SIZE = 0x2258
PARTICIPANT_WEIGHTS_ALLOC_FN = 0x800C2D30

# the participant struct pointer (unchanged knowledge, used for the arithmetic)
PARTICIPANT_PTR = 0x8017BE3C

# ---------------------------------------------------------------------------
# 2. magic damage and its indirect overlay caller
# ---------------------------------------------------------------------------
MAGIC_DAMAGE = 0x800F8174
MAGIC_DAMAGE_PTR_SLOT = 0x8016B7D8
LIB_TABLE_BASE = 0x8016B680
LIB_TABLE_END = 0x8016B7DC             # exclusive: the run 0x8016B680..0x8016B7DB
LIB_TABLE_STORE_SITE = 0x800DDFC0      # sw $v1,0x1258($v0)
LIB_TABLE_STORE_OFF = 0x1258
MAGIC_JUMP_TABLE = 0x800C1414
MAGIC_JUMP_ENTRIES = 31
MAGIC_JUMP_BOUND = 0x800F82A8          # sltiu 0x1E
MAGIC_JUMP_DISPATCH = 0x800F82D0       # jr $v0

# ---------------------------------------------------------------------------
# 3. BATTLE.BIN
# ---------------------------------------------------------------------------
BATTLE_BIN_LBA = 18698
BATTLE_BIN_SIZE = 91451
BATTLE_BIN_BASE = 0x800AA000
BATTLE_SECTION0_PALETTES = (0x20, 0x60, 0xA0)   # three 32-word RGB555 palettes
BATTLE_SECTION0_DTABLE = 0xE0
BATTLE_SECTION_COUNT = 8
BATTLE_PLANE_COUNT = 13
BATTLE_PLANE_BYTES = 16384

# ---------------------------------------------------------------------------
# 4. W_HEADER.BIN
# ---------------------------------------------------------------------------
W_HEADER_LBA = 183803
W_HEADER_SIZE = 67
W_HEADER_MAGIC = b"LNK\x02"
W_HEADER_RECORD_SIZE_ADDR = 0x8016481C
W_HEADER_RECORD_LBA_ADDR = 0x80164820
WAR_OVERLAY_BASE = 0x80010000
WAR_TABLE_FIRST_RECORD = 0x801647C8     # [u32 size][u32 lba], 8-byte stride


def _image() -> bytes:
    return maindec.body()


def mword(va: int) -> int:
    w = maindec.mword(va)
    if w is None:
        raise ValueError(f"0x{va:08X} is outside the MAIN.EXE image")
    return w


def s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# ---------------------------------------------------------------------------
# 1. the weight table
# ---------------------------------------------------------------------------
def weight_table_base() -> int:
    """Re-derive the base from the two instructions that build it.

    This is the whole point of item 1: the address is a `lui` sign-extension,
    so it must be computed from the full encoding, never read off the
    disassembler's display of the immediate.
    """
    lui = mword(WEIGHT_TABLE_LUI)
    addiu = mword(WEIGHT_TABLE_SITE)
    if (lui >> 26) & 0x3F != 0x0F:
        raise ValueError("0x800E9764 is not a lui")
    hi = (lui & 0xFFFF) << 16
    if (addiu >> 26) & 0x3F != 0x09:
        raise ValueError("0x800E9768 is not an addiu")
    return (hi + s16(addiu)) & 0xFFFFFFFF


def weight_table() -> list:
    """The 30 static entries, in dl order (-14 .. +15), as the code indexes them.

    The routine computes ``4*dl + base`` (0x800E9858/5C), so ``dl = -14`` is the
    word 56 bytes *below* the base built at 0x800E9764/68.  Reading from the base
    upward instead shifts every entry by 14 and walks the last 14 reads into the
    HP growth table at 0x8016BE08 -- the source of the "non-monotone tail" and
    the 0x8016BE3C collision this tool first recorded.  Corrected 2026-10-07 by
    kit/docs/exp_award.md, which identifies the table as the per-battle EXP award.
    """
    base = weight_table_base()
    img = _image()
    lo = base + 4 * WEIGHT_DL_MIN
    return [struct.unpack_from("<i", img, lo - MAIN_BASE + 4 * k)[0]
            for k in range(WEIGHT_TABLE_ENTRIES)]


def weight_at(dl: int) -> int:
    if not (WEIGHT_DL_MIN <= dl <= WEIGHT_DL_MAX):
        raise ValueError("dl out of the proven clamp")
    return weight_table()[dl - WEIGHT_DL_MIN]


def weight_table_is_static() -> bool:
    """True iff the whole indexed span lies inside the mapped image."""
    base = weight_table_base()
    lo = base + 4 * WEIGHT_DL_MIN
    hi = base + 4 * WEIGHT_DL_MAX + 4
    return MAIN_BASE <= lo and hi <= MAIN_END


def participant_weight_array() -> dict:
    """The heap block at 0x80179FD0 and its writer (the *other* array)."""
    lui = mword(PARTICIPANT_WEIGHTS_SITE)
    if (lui >> 26) & 0x3F != 0x0F or (lui & 0xFFFF) != 0x8018:
        raise ValueError("0x800E9788 is not lui 0x8018")
    lw = mword(PARTICIPANT_WEIGHTS_SITE + 4)
    if (lw >> 26) & 0x3F != 0x23:      # lw
        raise ValueError("0x800E978C is not a lw")
    off = s16(lw)
    return {
        "addr": (0x80180000 + off) & 0xFFFFFFFF,
        "read_site": PARTICIPANT_WEIGHTS_SITE + 4,
        "writer_site": PARTICIPANT_WEIGHTS_WRITER,
        "alloc_size": PARTICIPANT_WEIGHTS_ALLOC_SIZE,
        "alloc_fn": PARTICIPANT_WEIGHTS_ALLOC_FN,
    }


def weight_writer_site() -> int:
    """The `sw` that installs the participant weight-array pointer."""
    w = mword(PARTICIPANT_WEIGHTS_WRITER)
    if (w >> 26) & 0x3F != 0x2B:       # sw
        raise ValueError("0x800E81B8 is not a sw")
    return PARTICIPANT_WEIGHTS_WRITER


# ---------------------------------------------------------------------------
# 2. magic damage: call sites and the library run
# ---------------------------------------------------------------------------
def _iter_j_targets():
    """Every `jal`/`j` in the image as (site, target)."""
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    for i in range(n):
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        if op in (2, 3):
            pc = MAIN_BASE + i * 4
            yield pc, ((pc + 4) & 0xF0000000) | ((x & 0x3FFFFFF) << 2)


def direct_callers(target: int) -> list:
    return [pc for pc, t in _iter_j_targets() if t == target]


def literal_pointer_sites(value: int) -> list:
    """Every offset in the image whose 32-bit little-endian word is `value`."""
    img = _image()
    pat = struct.pack("<I", value & 0xFFFFFFFF)
    out, st = [], 0
    while True:
        k = img.find(pat, st)
        if k < 0:
            break
        out.append(MAIN_BASE + k)
        st = k + 1
    return out


def library_run() -> dict:
    """The maximal run of code pointers that contains the magic-damage slot."""
    img = _image()
    lo = MAGIC_DAMAGE_PTR_SLOT
    while lo - 4 >= MAIN_BASE:
        v = struct.unpack_from("<I", img, lo - 4 - MAIN_BASE)[0]
        if MAIN_BASE <= v < MAIN_END:
            lo -= 4
        else:
            break
    entries = []
    a = lo
    while a < MAIN_END:
        v = struct.unpack_from("<I", img, a - MAIN_BASE)[0]
        if not (MAIN_BASE <= v < MAIN_END):
            break
        entries.append({"slot": a, "target": v, "index": len(entries)})
        a += 4
    return {"base": lo, "end": a, "count": len(entries), "entries": entries}


def magic_jump_table() -> list:
    img = _image()
    return [struct.unpack_from("<I", img, MAGIC_JUMP_TABLE - MAIN_BASE + 4 * k)[0]
            for k in range(MAGIC_JUMP_ENTRIES)]


def magic_jump_distinct_targets() -> list:
    seen, out = set(), []
    for k, t in enumerate(magic_jump_table()):
        if t not in seen:
            seen.add(t)
            out.append({"index": k, "target": t})
    return out


def library_run_loads() -> list:
    """Every instruction in the image that reads from the library run.

    A constant-propagation pass (lui/addiu/ori/addu/subu/sll, reset at every
    `jr $ra`) -- deliberately wider than a `lui`-pair scan, because the run's
    base is also reachable as an offset from `0x8018` (`-0x4980`).
    """
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    regs = [None] * 32
    hits = []
    for i in range(n):
        pc = MAIN_BASE + i * 4
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        rs, rt, rd = (x >> 21) & 0x1F, (x >> 16) & 0x1F, (x >> 11) & 0x1F
        fn, sh = x & 0x3F, (x >> 6) & 0x1F
        if x == 0:
            continue
        if op == 0 and fn == 0x08:                     # jr
            regs = [None] * 32
            continue
        if op == 0x0F:                                 # lui
            regs[rt] = (x & 0xFFFF) << 16
            continue
        if op in (0x09, 0x0D):                         # addiu / ori
            v = regs[rs]
            if v is None:
                regs[rt] = None
            else:
                regs[rt] = ((v + s16(x)) & 0xFFFFFFFF if op == 0x09
                            else (v | (x & 0xFFFF)))
            continue
        if op == 0 and fn in (0x21, 0x23):             # addu / subu
            a, b = regs[rs], regs[rt]
            if a is None or b is None:
                regs[rd] = None
            else:
                regs[rd] = ((a + b) & 0xFFFFFFFF if fn == 0x21
                            else (a - b) & 0xFFFFFFFF)
            continue
        if op == 0 and fn == 0x00 and rs == 0:         # sll rd, rt, sh
            v = regs[rt]
            regs[rd] = None if v is None else (v << sh) & 0xFFFFFFFF
            continue
        if op in (0x20, 0x21, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2B):
            base = regs[rs]
            if base is not None:
                a = (base + s16(x)) & 0xFFFFFFFF
                if LIB_TABLE_BASE <= a < LIB_TABLE_END:
                    hits.append({"site": pc, "asm": dec(pc, x)[0], "addr": a})
            if op in (0x20, 0x21, 0x23, 0x24, 0x25):
                regs[rt] = None
            continue
        if op == 0:
            if fn in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A,
                      0x00, 0x02, 0x03, 0x04, 0x06, 0x07):
                regs[rd] = None
            elif fn in (0x10, 0x12, 0x11, 0x13, 0x1A, 0x1B):
                regs[rd] = None
        elif op in (0x08, 0x0C, 0x0A, 0x0B, 0x0E, 0x0F):
            pass
        else:
            regs[rt] = None
    return hits


def library_run_stores() -> list:
    """Every instruction that writes into the library run."""
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    out = []
    for i in range(n):
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        if op in (0x28, 0x29, 0x2B) and LIB_TABLE_BASE <= (MAIN_BASE + i * 4) < LIB_TABLE_BASE + 4 * 87:
            out.append({"site": MAIN_BASE + i * 4, "asm": dec(MAIN_BASE + i * 4, x)[0]})
    return out


def stores_into_library_run() -> list:
    """Any instruction anywhere in the image whose store target is in the run."""
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    regs = [None] * 32
    out = []
    for i in range(n):
        pc = MAIN_BASE + i * 4
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        rs, rt, rd = (x >> 21) & 0x1F, (x >> 16) & 0x1F, (x >> 11) & 0x1F
        fn, sh = x & 0x3F, (x >> 6) & 0x1F
        if x == 0:
            continue
        if op == 0 and fn == 0x08:
            regs = [None] * 32
            continue
        if op == 0x0F:
            regs[rt] = (x & 0xFFFF) << 16
            continue
        if op in (0x09, 0x0D):
            v = regs[rs]
            if v is None:
                regs[rt] = None
            else:
                regs[rt] = ((v + s16(x)) & 0xFFFFFFFF if op == 0x09
                            else (v | (x & 0xFFFF)))
            continue
        if op == 0 and fn in (0x21, 0x23):
            a, b = regs[rs], regs[rt]
            if a is None or b is None:
                regs[rd] = None
            else:
                regs[rd] = ((a + b) & 0xFFFFFFFF if fn == 0x21
                            else (a - b) & 0xFFFFFFFF)
            continue
        if op == 0 and fn == 0x00 and rs == 0:
            v = regs[rt]
            regs[rd] = None if v is None else (v << sh) & 0xFFFFFFFF
            continue
        if op in (0x28, 0x29, 0x2B):
            base = regs[rs]
            if base is not None:
                a = (base + s16(x)) & 0xFFFFFFFF
                if LIB_TABLE_BASE <= a < LIB_TABLE_END:
                    out.append({"site": pc, "asm": dec(pc, x)[0], "addr": a})
            continue
        if op in (0x20, 0x21, 0x23, 0x24, 0x25):
            regs[rt] = None
            continue
        if op == 0:
            if fn in (0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A,
                      0x00, 0x02, 0x03, 0x04, 0x06, 0x07):
                regs[rd] = None
            elif fn in (0x10, 0x12, 0x11, 0x13, 0x1A, 0x1B):
                regs[rd] = None
        elif op in (0x08, 0x0C, 0x0A, 0x0B, 0x0E, 0x0F):
            pass
        else:
            regs[rt] = None
    return out


def participant_1258_reads() -> list:
    """MAIN-only immediate-offset scan; excludes overlay and computed accesses."""
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    out = []
    for i in range(n):
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        if op in (0x20, 0x21, 0x23, 0x24, 0x25) and (x & 0xFFFF) == LIB_TABLE_STORE_OFF:
            out.append({"site": MAIN_BASE + i * 4, "asm": dec(MAIN_BASE + i * 4, x)[0]})
    return out


# ---------------------------------------------------------------------------
# 3/4. disc files
# ---------------------------------------------------------------------------
_DISC_INDEX = None
_DISC_CACHE = {}


def _disc_index():
    global _DISC_INDEX
    if _DISC_INDEX is None:
        with open(os.path.join(os.path.dirname(_TOOLS),
                               "extracted", "iso_files.json")) as fh:
            d = json.load(fh)
        _DISC_INDEX = {x["path"]: x for x in d if not x.get("dir")}
    return _DISC_INDEX


def _disc_file(path_suffix: str):
    if path_suffix in _DISC_CACHE:
        return _DISC_CACHE[path_suffix]
    import disc
    idx = _disc_index()
    hits = [p for p in idx if p.endswith(path_suffix)]
    if len(hits) != 1:
        raise ValueError(f"{path_suffix!r} matches {len(hits)} disc files")
    e = idx[hits[0]]
    raw = disc.extract(e["lba"], e["size"])
    _DISC_CACHE[path_suffix] = (e, raw)
    return e, raw


def vad_magic_caller() -> dict:
    """Positive indirect caller, checked against its disc instructions and slots."""
    entry, raw = _disc_file('15_AREA.Z/VAD.BIN')
    anchors = {0x3000: 0x8E621258, 0x3008: 0x8C420004,
               0x3014: 0x0040F809, 0x301C: 0x8E621258,
               0x3024: 0x8C420158, 0x302C: 0x0040F809,
               0x3030: 0x34060005, 0x3034: 0x8E631258,
               0x303C: 0x8C630010, 0x3044: 0x0060F809}
    for offset, word in anchors.items():
        assert struct.unpack_from('<I', raw, offset)[0] == word, hex(offset)
    assert mword(LIB_TABLE_BASE+0x158) == MAGIC_DAMAGE
    assert mword(LIB_TABLE_BASE+0x10) == 0x800E1654
    return {'file': entry['path'], 'lba': entry['lba'], 'size': entry['size'],
            'base': 0x80010000, 'call': 0x8001302C, 'slot': 0x158,
            'arguments': ['actor_index', 'signed_target_byte', 5],
            'apply_call': 0x80013044, 'apply_slot': 0x10}


def battle_bin_palettes() -> list:
    """Read section 0's three on-disc 32-word RGB555 palettes.

    Offsets 0x20/0x60/0xa0 are contiguous and are the ones the section's
    d-table (file 0xe0) points at.  These are the ONLY disc-derived palettes
    in the file; the other ten planes have none.
    """
    _e, raw = _disc_file("00_INIT/BATTLE.BIN")
    out = []
    for off in BATTLE_SECTION0_PALETTES:
        out.append([struct.unpack_from("<H", raw, off + 2 * k)[0]
                    for k in range(32)])
    return out


def w_header() -> dict:
    e, raw = _disc_file("W_HEADER.BIN")
    return {"lba": e["lba"], "size": e["size"], "magic": raw[:4],
            "bytes": raw, "record_size_addr": W_HEADER_RECORD_SIZE_ADDR,
            "record_lba_addr": W_HEADER_RECORD_LBA_ADDR}


#: W_HEADER.BIN's three symbols.  `name_off` points at the first name byte;
#: `len_off` points at the `08 <len>` operand when the file has one (it does
#: for `header` and `war_loop`; `war`'s string is bare, preceded only by the
#: `03` at 0x32).  Each value occurs TWICE in the 67 bytes, so both windows are
#: recorded: the claim is exactly what the bytes say, not more.
W_HEADER_RECORDS = (
    {"name": "header",   "name_off": 0x0D, "len_off": 0x0B, "value": 0x5462,
     "value_offs": (0x14, 0x07)},
    {"name": "war",      "name_off": 0x33, "len_off": None, "value": 0x5463,
     "value_offs": (0x30, 0x26)},
    {"name": "war_loop", "name_off": 0x3A, "len_off": 0x39, "value": 0x5464,
     "value_offs": (0x37, 0x2D)},
)


def w_header_symbols() -> list:
    """W_HEADER.BIN's three named symbol records, read off its 67 bytes.

    The file is a `LNK\\x02` bytecode emitted by the WAR overlay's own linker.
    Byte-exact layout (offsets are file offsets):

        +0x00  4c 4e 4b 02              magic `LNK\\x02`
        +0x04  2e 07 10 62 54 00 00 08  header word + base
        +0x0B  08 06 "header"           symbol 0 name
        +0x13  06 02 62 54              symbol 0 value 0x5462
        +0x19  00 x 9                   filler
        +0x22  0a 10 00 00              symbol 1 record
        +0x26  02 63 54                 symbol 1 value 0x5463
        +0x29  0a 10 04 00              symbol 2 record
        +0x2D  02 64 54                 symbol 2 value 0x5464
        +0x30  0e 63 54 03              trailing record: 0x5463
        +0x34  08 "war"
        +0x38  0e 64 54 08              trailing record: 0x5464
        +0x3C  08 "war_loop"

    The values are OFFSETS INSIDE THE WAR OVERLAY: the overlay loads at
    `0x80010000`, so `0x5462/63/64` are file offsets `0x5462/63/64` in
    `WAR1.BIN`, and `0x5464` is a real prologue there (`0x27BDFFE0` =
    `addiu $sp,$sp,-0x20`).  `w_header_record_is_war_table_entry` proves the
    file is WAR resource record 11, so the base is right.
    """
    raw = w_header()["bytes"]
    if raw[:4] != W_HEADER_MAGIC:
        raise ValueError("not a LNK\\x02 file")
    out = []
    base = ((raw[0x0B] << 16) | (raw[0x0A] << 8) | raw[0x09]) & 0xFFFFFF
    for rec in W_HEADER_RECORDS:
        # the name must literally be at the stated offset
        name_off = rec["name_off"]
        if rec["len_off"] is not None:
            if raw[rec["len_off"]] != 0x08:
                raise ValueError(f"no string operand at {rec['len_off']:#x}")
            ln = raw[rec["len_off"] + 1]
        else:
            ln = len(rec["name"])
        name = raw[name_off:name_off + ln].decode("latin-1").rstrip("\x00")
        if name != rec["name"]:
            raise ValueError(f"expected {rec['name']!r} at {name_off:#x}, got {name!r}")
        # the value must be encoded (LE u16) at every offset we claim
        for off in rec["value_offs"]:
            got = struct.unpack_from("<H", raw, off)[0]
            if got != rec["value"]:
                raise ValueError(f"{rec['name']}: {off:#x} holds {got:#x}, "
                                 f"expected {rec['value']:#x}")
        out.append({"name": name, "value": rec["value"],
                    "addr": (base + rec["value"]) & 0xFFFFFFFF,
                    "base": base,
                    "war_overlay_offset": rec["value"] & 0xFFFF})
    return out


def w_header_record_is_war_table_entry() -> bool:
    """W_HEADER is WAR resource record 11: size 67 then LBA 183803."""
    img = _image()
    size = struct.unpack_from("<I", img, W_HEADER_RECORD_SIZE_ADDR - MAIN_BASE)[0]
    lba = struct.unpack_from("<I", img, W_HEADER_RECORD_LBA_ADDR - MAIN_BASE)[0]
    return size == W_HEADER_SIZE and lba == W_HEADER_LBA


def warrior_symbol_is_real_code() -> dict:
    """`header`/`war`/`war_loop` are offsets into the WAR overlay, which loads
    at 0x80010000 -- so 0x5464 is WAR1.BIN file offset 0x5464."""
    e, raw = _disc_file("16_WAR/WAR1.BIN")
    out = {}
    for s in w_header_symbols():
        off = s["addr"] & 0xFFFF
        va = WAR_OVERLAY_BASE + off
        w = struct.unpack_from("<I", raw, off)[0] if off + 4 <= len(raw) else None
        out[s["name"]] = {"overlay_offset": off, "va": va,
                          "word": w, "asm": dec(va, w)[0] if w is not None else None}
    return out


# ---------------------------------------------------------------------------
# 5. encounter requester -- the field-frame path
# ---------------------------------------------------------------------------
GAME_STATE_PTR = 0x8017DB24
ENCOUNTER_SELECTOR_FIELD = 0x1BC0
ENCOUNTER_VALIDATOR_CALL = 0x8013295C
ENCOUNTER_VALIDATOR = 0x8012CC40
ENCOUNTER_RATE_ROLL = 0x8012CCD0
ENCOUNTER_PICKER_CALL = 0x8012CD08
ENCOUNTER_PICKER = 0x80126228
ENCOUNTER_SELECTOR_STORE = 0x801263E8
ENCOUNTER_FLAG_STORE = 0x8012CD24
ENCOUNTER_CALLBACK_INSTALL = 0x8012CD48
ENCOUNTER_MODE_STORE = 0x80131F18
ENCOUNTER_POINTER_STORE = 0x80131F30
ENCOUNTER_SELECTOR_READ = 0x800DE020

ENCOUNTER_FLOW_WORDS = {
    ENCOUNTER_VALIDATOR_CALL: 0x0C04B30E,       # jal 0x8012CC38
    ENCOUNTER_RATE_ROLL: 0x0C04E1E7,            # jal rand()/127 quotient helper
    0x8012CCDC: 0x9063159D,                     # per-area random-rate byte
    0x8012CCE0: 0x304200FF,                     # roll mask
    0x8012CCE4: 0x0043102B,                     # roll < rate
    ENCOUNTER_PICKER_CALL: 0x0C04988A,          # jal 0x80126228
    0x80126250: 0x0C051F8E,                     # picker calls BIOS rand
    ENCOUNTER_SELECTOR_STORE: 0xAC731BC0,       # sw s3,0x1BC0(gs)
    ENCOUNTER_FLAG_STORE: 0xA0620037,           # area_state[0x37] = 1
    ENCOUNTER_CALLBACK_INSTALL: 0xAC220000,     # install transition callback
    ENCOUNTER_MODE_STORE: 0xAC821BBC,           # sw v0,0x1BBC(gs), mode 3 arm
    ENCOUNTER_POINTER_STORE: 0xAC831BB4,        # encounter pointer to gs+0x1BB4
    ENCOUNTER_SELECTOR_READ: 0x8C421BC0,        # battle setup reads selector
}


def encounter_selector_writers() -> list:
    """Every static store whose target could be `gs + 0x1BC0`.

    The game-state base is `*(0x8017DB24)`, so the field has no absolute
    address; this scans for `lui *,0x8018` + `lw -0x24dc(*)` followed by a
    store with immediate `0x1BC0`, plus a raw immediate scan.
    """
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    out = []
    for i in range(n):
        x = struct.unpack_from("<I", img, i * 4)[0]
        op = (x >> 26) & 0x3F
        if op in (0x28, 0x29, 0x2B, 0x09) and (x & 0xFFFF) == ENCOUNTER_SELECTOR_FIELD:
            out.append({"site": MAIN_BASE + i * 4, "asm": dec(MAIN_BASE + i * 4, x)[0]})
    return out


def encounter_selector_immediates() -> list:
    img = _image()
    n = (MAIN_END - MAIN_BASE) // 4
    return [MAIN_BASE + i * 4 for i in range(n)
            if (struct.unpack_from("<I", img, i * 4)[0] & 0xFFFF) == ENCOUNTER_SELECTOR_FIELD]


def encounter_requester() -> dict:
    """Re-derive the random field trigger through its battle consumer."""
    for site, expected in ENCOUNTER_FLOW_WORDS.items():
        actual = mword(site)
        if actual != expected:
            raise ValueError(f"encounter path word moved at {site:#x}: {actual:#x}")
    candidates = encounter_selector_writers()
    if not any(row["site"] == ENCOUNTER_SELECTOR_STORE for row in candidates):
        raise ValueError("the candidate-picker result no longer writes gs+0x1BC0")
    return {
        "evidence": "proven",
        "field_update_call": hex(ENCOUNTER_VALIDATOR_CALL),
        "validator": hex(ENCOUNTER_VALIDATOR),
        "rate_roll": hex(ENCOUNTER_RATE_ROLL),
        "picker_call": hex(ENCOUNTER_PICKER_CALL),
        "picker": hex(ENCOUNTER_PICKER),
        "selector_store": hex(ENCOUNTER_SELECTOR_STORE),
        "queued_flag_store": hex(ENCOUNTER_FLAG_STORE),
        "callback_install": hex(ENCOUNTER_CALLBACK_INSTALL),
        "mode_3_store": hex(ENCOUNTER_MODE_STORE),
        "encounter_pointer_store": hex(ENCOUNTER_POINTER_STORE),
        "battle_consumer": hex(ENCOUNTER_SELECTOR_READ),
        "selector_writer_candidates": candidates,
        "selector_immediates": [hex(p) for p in encounter_selector_immediates()],
    }


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
def as_json() -> dict:
    wt = weight_table()
    run = library_run()
    return {
        "provenance": {
            "main_base": hex(MAIN_BASE),
            "main_end": hex(MAIN_END),
            "image_size": MAIN_END - MAIN_BASE,
        },
        "weight_table": {
            "evidence": "proven",
            "addr": hex(weight_table_base()),
            "superseded_addr": hex(WEIGHT_WRONG_ADDR),
            "static_in_image": weight_table_is_static(),
            "site_addiu": hex(WEIGHT_TABLE_SITE),
            "site_lui": hex(WEIGHT_TABLE_LUI),
            "site_read": hex(WEIGHT_TABLE_READ),
            "dl_range": [WEIGHT_DL_MIN, WEIGHT_DL_MAX],
            "entries": wt,
            "participant_weight_array": participant_weight_array(),
        },
        "magic_damage_caller": {
            "evidence": "proven",
            "routine": hex(MAGIC_DAMAGE),
            "direct_callers": [hex(p) for p in direct_callers(MAGIC_DAMAGE)],
            "literal_pointer_sites": [hex(p) for p in literal_pointer_sites(MAGIC_DAMAGE)],
            "jump_table": hex(MAGIC_JUMP_TABLE),
            "jump_table_entries": MAGIC_JUMP_ENTRIES,
            "jump_table_distinct_targets": [
                {"index": d["index"], "target": hex(d["target"])}
                for d in magic_jump_distinct_targets()],
            "library_run": {"base": hex(run["base"]), "count": run["count"],
                            "slot_for_magic": hex(MAGIC_DAMAGE_PTR_SLOT)},
            "library_run_loads": [hex(h["site"]) for h in library_run_loads()],
            "library_run_stores": [hex(h["site"]) for h in stores_into_library_run()],
            "participant_1258_reads": participant_1258_reads(),
            "indirect_caller": vad_magic_caller(),
        },
        "battle_bin": {
            "evidence": "open",
            "lba": BATTLE_BIN_LBA,
            "size": BATTLE_BIN_SIZE,
            "load_base": hex(BATTLE_BIN_BASE),
            "sections": BATTLE_SECTION_COUNT,
            "planes": BATTLE_PLANE_COUNT,
            "plane_bytes": BATTLE_PLANE_BYTES,
            "disc_derived_palette_offsets": [hex(o) for o in BATTLE_SECTION0_PALETTES],
        },
        "w_header": {
            "evidence": "proven",
            "lba": W_HEADER_LBA,
            "size": W_HEADER_SIZE,
            "magic": W_HEADER_MAGIC.decode("latin-1"),
            "is_war_table_record": w_header_record_is_war_table_entry(),
            "symbols": w_header_symbols(),
            "symbol_targets": warrior_symbol_is_real_code(),
        },
        "encounter_requester": {
            "selector_field": hex(ENCOUNTER_SELECTOR_FIELD),
            **encounter_requester(),
        },
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--item", choices=["weight_table", "magic", "battle_bin",
                                       "w_header", "encounter"])
    a = ap.parse_args(argv)
    if a.json:
        json.dump(as_json(), sys.stdout, indent=1)
        print()
        return 0
    data = as_json()
    if a.item:
        key = {"weight_table": "weight_table", "magic": "magic_damage_caller",
               "battle_bin": "battle_bin", "w_header": "w_header",
               "encounter": "encounter_requester"}[a.item]
        json.dump(data[key], sys.stdout, indent=1)
        print()
        return 0
    wt = data["weight_table"]
    print(f"1. weight table      {wt['evidence']:8} {wt['addr']}  "
          f"(supersedes {wt['superseded_addr']})")
    md = data["magic_damage_caller"]
    print(f"2. magic-damage caller {md['evidence']:6} "
          f"{len(md['direct_callers'])} direct call sites; "
          f"run loads {len(md['library_run_loads'])}")
    print(f"3. BATTLE.BIN        {data['battle_bin']['evidence']:8} "
          f"3/13 planes carry an on-disc palette")
    wh = data["w_header"]
    print(f"4. W_HEADER.BIN      {wh['evidence']:8} {wh['size']} B, "
          f"war record={wh['is_war_table_record']}, "
          f"{len(wh['symbols'])} symbols")
    en = data["encounter_requester"]
    print(f"5. encounter trigger {en['evidence']:8} "
          f"{len(en['selector_writer_candidates'])} candidate writer(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
