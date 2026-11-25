#!/usr/bin/env python3
"""Per-level growth for Suikoden (PS1, SLUS_002.92 v1.1) -- the derived rules.

This is the last underived battle rule in the corpus.  It is now derived, and
the derivation is **static and disc-derived**: every number below was read out
of an instruction word (MAIN.EXE, PS-X EXE ``t_addr`` 0x800C0800, or
SLUS_002.92, ``t_addr`` 0x80010000) through ``tools/disc.py``.  No emulator, no
save state, no capture.  See ``kit/docs/growth_rules.md`` for the write-up and
``kit/work/extract_growth.jsonl`` for the machine-readable claims.

THE RULE, in one paragraph
--------------------------
The persistent per-character record is the 78 x 0x50 table at
``gs(0x801B8000) + 0x294`` (its *identity* with the record the battle code reads
is proven: ``char_ptr->0x1C`` is set to ``gs + 0x294 + 0x50*j`` by the linker at
0x800C49B8 / 0x8001B3EC, matching the record whose first word equals the
character-id byte).  A level costs a flat **1000** experience (record ``+0x0E``,
u16).  Each level-up runs ``0x800E9CC4`` with the record, which increments the
level byte ``+0x0D`` (cap 99, ``sltiu 0x63``) and then, for each of the six stat
bytes ``+0x10..+0x15``, adds

    gain_i = (stat_table[3*g_i + tier(new_level, g_i)] + (rand() & 0xFF)) >> 8

where ``g_i`` is the per-stat growth byte at ``+0x18+i`` and ``stat_table`` is
the 48-word table at ``0x8016BEC8``.  HP max/cur (``+0x04``/``+0x06``) grow with
the *same* pattern out of a second 48-word table at ``0x8016BE08``, indexed by
growth byte ``+0x18`` (stat 0's growth), with a 9-bit random term::

    hp_gain = (hp_table[3*g0 + tier(new_level, g0)] + (rand() & 0x1FF)) >> 8

So growth is **table-driven and random**: each level, each stat gains
``floor((table + u)/256)`` where ``u`` is uniform; the *expected* gain is
``table/256`` (0.4 .. 4 points for stats, 3 .. 20 for HP).  It is neither a
fixed step nor a per-level curve: the table lookup is the per-character growth
class, the tier is the level band.

RNG consumption order (matters for a bit-exact port): six ``rand()`` calls, one
per stat in index order 0..5, then one more for HP -- exactly 7 per level, and
none at all on the paths that do not level.

WHAT IS NOT DERIVED
-------------------
The *amount* a given battle awards (the per-member pool the victory sequence
reads) has no static writer in this corpus; see ``OPEN`` below for the exact
searches.  Everything about EXP -> level *given* an amount is proven.

Addresses are instruction addresses inside the named image.  ``ADDR`` collects
them; the gate re-reads the instruction words and asserts the encodings.
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

import maindec  # noqa: E402  (MAIN.EXE image, base 0x800C0800)

MAIN_BASE = 0x800C0800
SLUS_BASE = 0x80010000

# ---------------------------------------------------------------------------
# 1. The record (0x50 bytes).  Every offset carries the instruction that fixes
#    it; `layer` says which image the address is in.
# ---------------------------------------------------------------------------
RECORD_STRIDE = 0x50
RECORD_COUNT = 78
RECORD_BASE_OFF = 0x294          # gs(0x801B8000) + 0x294
#: 0x294 + 78*0x50 -- the linker's own bound (`slti 0x1AF4` at 0x800C4A38).
RECORD_TABLE_END_OFF = 0x1AF4

RECORD = {
    # name          off   size  fixed by (MAIN unless noted)      meaning
    "id":         (0x00, 4, 0x800C4A1C, "character id, lookup key"),
    "hp_max":     (0x04, 2, 0x800DED6C, "HP maximum (loader -> slot +0x10)"),
    "hp_cur":     (0x06, 2, 0x800DED74, "HP current (loader -> slot +0x12)"),
    "level":      (0x0D, 1, 0x800E9D18, "level, 1..99 (written on level-up)"),
    "exp":        (0x0E, 2, 0x800E8A88, "EXP toward the next level, 0..999"),
    "stats":      (0x10, 6, 0x800DED94, "six stat bytes (current values)"),
    "status":     (0x16, 1, 0x800DEDB0, "status byte copied to battle flags; rest clears16..17"),
    "growth":     (0x18, 6, 0x800E9D20, "six growth-rate bytes (the SOURCE)"),
    "weapon":     (0x44, 1, 0x800EEC4C, "weapon id into table 0x80165890"),
    "rune":       (0x4C, 1, 0x800E98EC, "rune id; Fortune 0x16 doubles EXP award"),
}

#: The record's first word is the key the scan compares (0x8013875C).
#: Status-screen loops800CF954/800CF9B4 pair these disc labels with columns0..5.
#: Keep the legacy constant/export-key spelling for existing consumers.
STAT_NAMES_INFERRED = ("PWR", "SKL", "DEF", "SPD", "MGC", "LUK")

# ---------------------------------------------------------------------------
# 2. The two gain tables, both inside the MAIN.EXE image (data, read with `lw`)
# ---------------------------------------------------------------------------
STAT_TABLE_VA = 0x8016BEC8       # lui 0x8017 @0x800E9D00 + addiu -0x4138 @0x800E9D04
HP_TABLE_VA = 0x8016BE08         # lui 0x8017 @0x800E9E00 + addiu -0x41F8 @0x800E9E04
TABLE_ENTRIES = 48               # 3 * 16 growth classes; indices 0..47
HP_TABLE_ADDR = 0x800E9E04
STAT_TABLE_ADDR = 0x800E9D04

#: Gains are (table + u) >> 8 with u uniform over 8 bits (stats) or 9 (HP).
STAT_RAND_BITS = 8
HP_RAND_BITS = 9

EXP_PER_LEVEL = 1000             # 0x3E8; slti @0x800E89D4, addiu -0x3E8 @0x800E8A04
EXP_SCRIPT_STEP = 10             # event-script "add exp" opcode; 0x80139024
EXP_DRAIN_CHUNK = 0x10           # victory animation drains the pool 16 at a time
MAX_LEVEL = 0x63                 # 99; sltiu @0x800E9CF4, early return @0x800E9CF8

#: Level bands the stat table's tier is chosen from, per growth class.
#: 0x800E9C2C `slti a1,9` / 0x800E9C34 `slti a1,0xb` / 0x800E9C40 `ori 0xe` +
#: 0x800E9C44 `beq a1,14`; the band edges are 0x800E9C30/0x800E9C3C/0x800E9C48/
#: 0x800E9C78.
STAT_TIER_BANDS = {
    "rate<9": (20, 60),
    "9..10": (15, 60),
    "11..13": (20, 60),
    "rate==14": (60, 80),
}
HP_TIER_BANDS = (20, 60)         # 0x800E9DBC `slti s5,0x14` / 0x800E9DE8 `slti 0x3c`

# ---------------------------------------------------------------------------
# 3. The routines
# ---------------------------------------------------------------------------
LEVEL_UP_ROUTINE = 0x800E9CC4    # main entry: level++, six stats, HP
GROWTH_FN = 0x800E9C28           # f(new_level, growth_byte) -> table index
BATTLE_EXP_APPLY = 0x800E8914    # victory state 0: bank the pool, level up
BATTLE_EXP_DRAIN = 0x800E8ABC    # 16-at-a-time banking for the animation
SCRIPT_EXP_HANDLER = 0x80138FB0  # event-script op 3/4: +10 exp, wrap 1000
SCRIPT_LEVEL_HANDLER = 0x801390D8  # event-script ops that set level 0/1/2
REST_OP_HANDLER = 0x80138D00     # hp_cur = hp_max, status = 0
SAVEBUF_SCAN = 0x8013875C        # base +0x294, bound slti 0x4E, stride 0x50
LINKER_MAIN = 0x800C49B8         # char_ptr->0x1C = the matching gs record
LINKER_SLUS = 0x8001B3EC
BOOT_SEED_FN = 0x80017544        # SLUS: copy the default game state into gs
BOOT_SEED_SRC = 0x80042FE0       # SLUS image: the default 0x1D60 payload
BOOT_SEED_DST = 0x801B8000       # = gs base
BOOT_SEED_LEN = 0x1D60           # `addiu t0,a2,0x1d60` @0x80017564 / 0x800175BC
TEMPLATE_VA = BOOT_SEED_SRC + RECORD_BASE_OFF   # 0x80043274, 78 x 0x50

ADDR = {
    "record_base_off": (0x8013876C, "MAIN", "addiu v1,v0,0x294 -- the scan base"),
    "record_bound": (0x800C4A38, "MAIN", "slti v0,a0,0x1AF4 = 0x294+78*0x50"),
    "record_stride": (0x8013878C, "MAIN", "addiu v1,v1,0x50"),
    "record_scan_bound": (0x80138784, "MAIN", "slti v0,a1,0x4E = 78"),
    "linker_store": (0x800C4A30, "MAIN", "sw v1,0x1c(s0): char_ptr+0x1C = record"),
    "linker_base": (0x800C4A08, "MAIN", "ori v1,v1,0x8294 = gs+0x294"),
    "linker_base_slus": (0x8001B43C, "SLUS", "the same store in SLUS"),
    "boot_seed_src": (0x80017554, "SLUS", "addiu a2,a2,0x2fe0 -> 0x80042FE0"),
    "boot_seed_dst": (0x8001754C, "SLUS", "lui a3,0x801b; ori a3,0x8000"),
    "boot_seed_len": (0x80017564, "SLUS", "addiu t0,a2,0x1d60"),
    "template_addr": (TEMPLATE_VA, "SLUS", "boot_seed_src + 0x294"),
    "level_read": (0x800E9CEC, "MAIN", "lbu v0,0xd(s3)"),
    "level_cap": (0x800E9CF4, "MAIN", "sltiu v0,v0,0x63"),
    "level_write": (0x800E9D18, "MAIN", "sb v0,0xd(s3)"),
    "level_turn_weight": (0x800E982C, "MAIN", "lbu v0,0xd(v1) (turn-weight level)"),
    "level_gate_script": (0x8013D7AC, "MAIN", "lbu v0,0x2a1(v1) = gs+0x294+0x0D"),
    "exp_write": (0x800E8A88, "MAIN", "sh v0,0xe(a1)"),
    "exp_threshold": (0x800E89D4, "MAIN", "slti v1,v1,0x3e8"),
    "exp_subtract": (0x800E8A04, "MAIN", "addiu v0,v0,-0x3e8"),
    "exp_clear": (0x800E8A18, "MAIN", "sh zero,0xe(v0)"),
    "exp_levelup_call": (0x800E8A20, "MAIN", "jal 0x800E9CC4"),
    "exp_drain": (0x800E8B70, "MAIN", "addiu v0,v0,-0x10; sw v0,0x10(v1)"),
    "exp_drain_branch": (0x800E8AFC, "MAIN", "slti v0,a2,0x11: pool<17 moves whole"),
    "growth_fn_call": (0x800E9D24, "MAIN", "jal 0x800E9C28"),
    "growth_byte_read": (0x800E9D20, "MAIN", "lbu a1,0x18(s1), s1 = record+i"),
    "growth_loop_bound": (0x800E9DB0, "MAIN", "slti v0,s2,0x6"),
    "growth_loop_stride": (0x800E9DB8, "MAIN", "addiu s1,s1,1"),
    "stat_table_base": (0x800E9D04, "MAIN", "addiu s6,s6,-0x4138 -> 0x8016BEC8"),
    "hp_table_base": (0x800E9E04, "MAIN", "addiu v1,v1,-0x41f8 -> 0x8016BE08"),
    "stat_rand_index": (0x800E9D48, "MAIN", "sll v0,s0,2 then lw table[s0]"),
    "stat_rand_mask": (0x800E9D74, "MAIN", "addiu v0,v0,0xff; sra 8 -> u & 0xFF"),
    "stat_gain_shift": (0x800E9D78, "MAIN", "sra v1,v0,8"),
    "stat_clamp": (0x800E9D8C, "MAIN", "slti v0,v0,0x100 -> 0xFF else sum"),
    "hp_gain_shift": (0x800E9E38, "MAIN", "sra v0,v0,8 after a 9-bit mask"),
    "hp_gain_mask": (0x800E9E14, "MAIN", "addiu a1,a0,0x1ff; sra 9 -> u & 0x1FF"),
    "hp_add_max": (0x800E9E50, "MAIN", "sh v0,0x4(s3)"),
    "hp_add_cur": (0x800E9E64, "MAIN", "sh v0,0x6(s3)"),
    "hp_growth_byte": (0x800E9D0C, "MAIN", "lbu s4,0x18(s3): growth[0] drives HP"),
    "tier_rate_lt9": (0x800E9C2C, "MAIN", "slti v0,a1,0x9"),
    "tier_rate_lt11": (0x800E9C34, "MAIN", "slti v0,a1,0xb"),
    "tier_rate_14": (0x800E9C44, "MAIN", "beq a1,14 -> the 60/80 band"),
    "tier_band_a": (0x800E9C30, "MAIN", "slti v0,a0,0x14 (level<20)"),
    "tier_band_b": (0x800E9C3C, "MAIN", "slti v0,a0,0xf (level<15)"),
    "tier_band_c": (0x800E9C48, "MAIN", "slti v0,a0,0x3c (level<60)"),
    "tier_band_d": (0x800E9C78, "MAIN", "slti v0,a0,0x50 (level<80)"),
    "tier_return_base": (0x800E9C98, "MAIN", "addu v0,v0,a1: 3*rate"),
    "tier_return_plus1": (0x800E9CB0, "MAIN", "addiu v0,v0,0x1"),
    "tier_return_plus2": (0x800E9CB8, "MAIN", "addiu v0,v0,0x2"),
    "tier_const_42_43_44": (0x800E9C74, "MAIN", "ori v0,0x2a / 0x2b / 0x2c"),
    "hp_tier_band": (0x800E9DBC, "MAIN", "slti s5,0x14 / 0x800E9DE8 slti 0x3c"),
    "script_exp_add": (0x80139024, "MAIN", "addiu v1,v1,0xa"),
    "script_exp_wrap": (0x80139048, "MAIN", "divu v1,0x3e8; mfhi"),
    "script_exp_levelup": (0x80139068, "MAIN", "jal 0x800E9CC4"),
    "rest_hp_full": (0x80138D30, "MAIN", "sh v0,0x6(v1): hp_cur = hp_max"),
}

#: What is still missing, with the searches that were run.  This is a *result*:
#: the negative is bounded and reproducible, not an excuse.
OPEN = {
    "battle_exp_award_amount": {
        "question": ("What fills battle_context(*(0x80179FD0)) + 0x10 + 4*idx, "
                     "the per-member EXP pool the victory sequence banks?"),
        "status": "open - no static writer exists in this corpus",
        "searched": [
            "MAIN.EXE, image-wide: every instruction with immediate 0x10 in a "
            "store (swl/swr/sw/sh/sb), with the base register traced back to a "
            "load of *(0x80179FD0) through addu/ori/addiu/sll aliasing.  The only "
            "hits are the drain/clear inside the victory sequence itself "
            "(0x800E8A0C, 0x800E8A9C, 0x800E8B78, 0x800E8BA0, 0x800E8BEC) and "
            "0x800E9908, which writes B+0x14 (the turn weight), not B+0x10.",
            "MAIN.EXE, image-wide: `addiu rX, <B-alias>, 0x10` (i.e. passing "
            "B+0x10 to a helper such as memcpy) - zero hits.",
            "all 110 disc files the inventory types as MIPS overlay: no `jal` to "
            "the growth routine and no load of *(0x80179FD0) at all.",
            "SLUS_002.92: no load of *(0x80179FD0) (it uses its own gs pointer "
            "literal at 0x800420C0).",
        ],
        "cannot_rule_out": [
            "a bulk write through a pointer this scan cannot follow (a store via "
            "a register loaded from a table, or a DMA), and",
            "a writer in an overlay the inventory does not type as code.",
        ],
        "note": ("The consumers are fully derived: 0x800E8914 banks the pool "
                 "1000 at a time and calls the growth routine; 0x800E8ABC drains "
                 "it 16 at a time for the on-screen count.  Only the award "
                 "arithmetic is missing, and it is not needed to reproduce the "
                 "level-up rule."),
    },
    "stat_column_semantics": {
        "question": "Which of the six stat bytes is PWR/SKL/DEF/SPD/MGC/LUK?",
        "status": "inferred from the external save-format lead, cross-checked "
                  "against the template's character profiles",
        "searched": [
            "the template's own data: column 4 = 27 with growth 8 for Luc and "
            "Crowley (the two mages), column 0 = 30 / column 2 = 22 / column 4 = "
            "1 for Fu Su Lu, column 3 = 25 for Krin and 24 for Kasumi (the fast "
            "characters), column 1 = 21 for Kirkis (the elf archer).",
        ],
        "cannot_rule_out": [
            "an intra-column permutation the code alone does not reveal - no "
            "instruction names these bytes; the growth *rule* is column-agnostic.",
        ],
    },
    "external_lead_stride": {
        "question": "A 2011 fan post gives the save block as 0x510 + 0x40*C.",
        "status": "field map corroborated, stride refuted by the disc",
        "searched": [
            "the payload IS gs (memcard_save_stage_copy 0x80129CA8 copies 0x1D60 "
            "bytes from 0x801B8000 with no repacking), and the in-memory table is "
            "78 x 0x50 with the bound 0x1AF4 written by the linker at 0x800C4A38; "
            "a 0x40 stride cannot be the same table.",
            "their field offsets (level +0x15, exp +0x16, stats +0x18, growth "
            "+0x20) land exactly on our record+0x0D/+0x0E/+0x10/+0x18 once their "
            "block base is recognised as our record base minus 8.",
        ],
    },
}


# ---------------------------------------------------------------------------
# readers
# ---------------------------------------------------------------------------
def stat_table() -> list[int]:
    """The 48-word six-stat gain table (0x8016BEC8), read from the image."""
    return [maindec.mword(STAT_TABLE_VA + 4 * i) for i in range(TABLE_ENTRIES)]


def hp_table() -> list[int]:
    """The 48-word HP gain table (0x8016BE08), read from the image."""
    return [maindec.mword(HP_TABLE_VA + 4 * i) for i in range(TABLE_ENTRIES)]


def _slus_image():
    """SLUS_002.92's PS-X EXE image (header stripped), base 0x80010000."""
    import character_table as ct  # reuses the corpus's anchored read
    return ct.image()


def template_records():
    """The 78 x 0x50 default-record block at SLUS 0x80043274 (bytes)."""
    img = _slus_image()
    base = TEMPLATE_VA - SLUS_BASE
    return [bytes(img[base + i * RECORD_STRIDE:
                      base + (i + 1) * RECORD_STRIDE]) for i in range(RECORD_COUNT)]


def boot_seed_block():
    """The whole default game-state payload the boot seeder copies (0x1D60 B)."""
    img = _slus_image()
    o = BOOT_SEED_SRC - SLUS_BASE
    return bytes(img[o:o + BOOT_SEED_LEN])


# ---------------------------------------------------------------------------
# the growth function, replicated from 0x800E9C28
# ---------------------------------------------------------------------------
def tier_bands(rate: int) -> tuple[int, int]:
    """The level band edges the stat table's tier uses for a growth class."""
    if rate < 9:
        return STAT_TIER_BANDS["rate<9"]
    if rate < 11:
        return STAT_TIER_BANDS["9..10"]
    if rate == 14:
        return STAT_TIER_BANDS["rate==14"]
    return STAT_TIER_BANDS["11..13"]


def stat_index(level: int, rate: int) -> int:
    """f(new_level, growth_byte) -- the stat table index, 0x800E9C28.

    Returns ``3*rate + tier`` with the band edges above; for rate == 14 the
    function returns the constants 42/43/44, which is the same arithmetic
    (3*14 + 0/1/2) with the 60/80 bands.
    """
    a, b = tier_bands(rate)
    tier = 0 if level < a else (1 if level < b else 2)
    return 3 * rate + tier


def hp_index(level: int, growth0: int) -> int:
    """The HP table index, built inline at 0x800E9DBC..0x800E9DEC.

    HP always uses the 20/60 bands -- there is no per-class special case on this
    path -- and always growth byte ``+0x18``.
    """
    a, b = HP_TIER_BANDS
    tier = 0 if level < a else (1 if level < b else 2)
    return 3 * growth0 + tier


def gain(table_value: int, rand_value: int, bits: int) -> int:
    """``(table + (rand & mask)) >> 8`` -- the shift is 8 in both paths.

    The MIPS sequence masks with a sign-adjusted ``sra``/``sll`` pair
    (0x800E9D74 for 8 bits, 0x800E9E14 for 9), which is exactly ``& 0xFF`` /
    ``& 0x1FF`` for a non-negative ``rand()`` (the BIOS rand() is 0..0x7FFF).
    """
    return (table_value + (rand_value & ((1 << bits) - 1))) >> 8


def expected_gain(table_value: int) -> float:
    """The mean of ``gain`` over the uniform random term (the port's shortcut)."""
    return table_value / 256.0


# ---------------------------------------------------------------------------
# the level-up routine, replicated from 0x800E9CC4
# ---------------------------------------------------------------------------
def level_up(record: bytearray, rand) -> dict:
    """Run one level-up on a 0x50 record **in place**.

    ``record`` must be a mutable 0x50-byte record.  ``rand`` is a callable
    returning the next 0..0x7FFF value (the BIOS LCG); it is called exactly 7
    times: six stats in index order, then HP.

    Returns a dict describing what happened, including ``skipped`` when the
    record is already at MAX_LEVEL (0x800E9CF4 -> early return at 0x800E9CF8:
    no level increment, no growth, no RNG).
    """
    lvl = record[RECORD["level"][0]]
    if lvl >= MAX_LEVEL:
        return {"skipped": True, "level": lvl, "stat_gains": [], "hp_gain": 0}

    record[RECORD["level"][0]] = lvl + 1
    new_level = lvl + 1

    stat_gains = []
    t = stat_table()
    for i in range(6):
        rate = record[RECORD["growth"][0] + i]
        idx = stat_index(new_level, rate)
        g = gain(t[idx], rand(), STAT_RAND_BITS)
        cur = record[RECORD["stats"][0] + i]
        record[RECORD["stats"][0] + i] = 0xFF if cur + g >= 0x100 else cur + g
        stat_gains.append(g)

    h = hp_table()
    g0 = record[RECORD["growth"][0]]
    hp_gain = gain(h[hp_index(new_level, g0)], rand(), HP_RAND_BITS)
    for off in (RECORD["hp_max"][0], RECORD["hp_cur"][0]):
        v = struct.unpack_from("<H", record, off)[0]
        struct.pack_into("<H", record, off, (v + hp_gain) & 0xFFFF)

    return {"skipped": False, "level": new_level,
            "stat_gains": stat_gains, "hp_gain": hp_gain}


def battle_exp(record: bytearray, exp_total: int, rand) -> dict:
    """The battle EXP rule: ``exp_total`` experience is consumed 1000/level.

    This is the *net* effect of the victory loop at 0x800E8914 state 0
    (0x800E89D4 test, 0x800E8A04 subtract, 0x800E8A18 clear, 0x800E8A20 call,
    0x800E8A44 re-test): the pool and the record's counter are one total, and
    every 1000 of it buys exactly one level.  The leftover returns to the
    record's counter (the 16-at-a-time drain at 0x800E8ABC is only the on-screen
    animation of the same movement).
    """
    total = struct.unpack_from("<H", record, RECORD["exp"][0])[0] + exp_total
    levels = []
    while total >= EXP_PER_LEVEL:
        total -= EXP_PER_LEVEL
        r = level_up(record, rand)
        levels.append(r)
        if r["skipped"]:
            # At MAX_LEVEL the routine does not consume the level; the engine's
            # loop keeps subtracting from the pool and terminates the same way.
            break
    struct.pack_into("<H", record, RECORD["exp"][0], total & 0xFFFF)
    return {"levels": levels, "leftover_exp": total}


def drain_exp(record: bytearray, pool: int, rand):
    """The victory-sequence drain at 0x800E8ABC, **faithfully**, as a generator.

    Yields ``(record_exp, pool, levelup_or_None)`` per engine step.  The code is
    two branches on the pool size (`slti a2,0x11` @0x800E8AFC, `bne` @0x800E8B18):

    * ``pool < 17`` (0x800E8B7C): if ``exp + pool < 1000`` then ``exp += pool``
      and ``pool = 0`` (0x800E8BC4..0x800E8BEC); otherwise the record's exp is
      folded into the pool, ``pool = pool - 1000 + exp``, ``exp = 0`` and one
      level is taken (0x800E8B98..0x800E8BB4).
    * ``pool >= 17`` (0x800E8B20): the 16-point chunk.  If ``exp + 16 < 1000``
      then ``exp += 16`` and ``pool -= 16`` (0x800E8B48..0x800E8B78); otherwise
      the same fold-and-level (0x800E8B3C..0x800E8BAC).

    Both branches keep the pool non-negative, and the net effect is exactly
    :func:`battle_exp` -- the gate checks that over a sweep.
    """
    while pool > 0:
        e = struct.unpack_from("<H", record, RECORD["exp"][0])[0]
        if pool < EXP_DRAIN_CHUNK + 1:
            if e + pool < EXP_PER_LEVEL:
                struct.pack_into("<H", record, RECORD["exp"][0], e + pool)
                pool = 0
                yield (e + pool, 0, None)
            else:
                pool = pool - EXP_PER_LEVEL + e
                struct.pack_into("<H", record, RECORD["exp"][0], 0)
                r = level_up(record, rand)
                yield (0, pool, r)
        else:
            if e + EXP_DRAIN_CHUNK < EXP_PER_LEVEL:
                struct.pack_into("<H", record, RECORD["exp"][0], e + EXP_DRAIN_CHUNK)
                pool -= EXP_DRAIN_CHUNK
                yield (e + EXP_DRAIN_CHUNK, pool, None)
            else:
                pool = pool - EXP_PER_LEVEL + e
                struct.pack_into("<H", record, RECORD["exp"][0], 0)
                r = level_up(record, rand)
                yield (0, pool, r)


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------
def growth_rows() -> list[dict]:
    """One row per (growth class, level band) -> table index and expected gain."""
    rows = []
    for rate in range(16):
        for band, lvl in (("low", 1), ("mid", 40), ("high", 80)):
            idx = stat_index(lvl, rate)
            rows.append({"rate": rate, "band": band, "level": lvl,
                         "stat_index": idx,
                         "stat_table": stat_table()[idx] if idx < TABLE_ENTRIES else None,
                         "hp_index": hp_index(lvl, rate),
                         "hp_table": hp_table()[hp_index(lvl, rate)]
                         if hp_index(lvl, rate) < TABLE_ENTRIES else None})
    return rows


def as_json() -> dict:
    return {
        "record": {k: {"off": v[0], "size": v[1], "fixed_by": hex(v[2]),
                       "meaning": v[3]} for k, v in RECORD.items()},
        "record_stride": RECORD_STRIDE,
        "record_count": RECORD_COUNT,
        "record_base": "gs(0x801B8000)+0x294",
        "record_table_end": hex(RECORD_TABLE_END_OFF),
        "exp_per_level": EXP_PER_LEVEL,
        "max_level": MAX_LEVEL,
        "stat_table_va": hex(STAT_TABLE_VA),
        "hp_table_va": hex(HP_TABLE_VA),
        "stat_table": stat_table(),
        "hp_table": hp_table(),
        "stat_tier_bands": {k: list(v) for k, v in STAT_TIER_BANDS.items()},
        "hp_tier_bands": list(HP_TIER_BANDS),
        "template_va": hex(TEMPLATE_VA),
        "boot_seed": {"fn": hex(BOOT_SEED_FN), "src": hex(BOOT_SEED_SRC),
                      "dst": hex(BOOT_SEED_DST), "len": hex(BOOT_SEED_LEN)},
        "stat_names_inferred": list(STAT_NAMES_INFERRED),
        "addr": {k: {"addr": hex(v[0]), "image": v[1], "what": v[2]}
                 for k, v in ADDR.items()},
        "open": OPEN,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="the derived data")
    ap.add_argument("--tables", action="store_true", help="the two gain tables")
    ap.add_argument("--template", type=int, metavar="ROW",
                    help="dump one default record from SLUS 0x80043274")
    ap.add_argument("--levelup", type=int, metavar="LEVEL",
                    help="simulate one level-up at LEVEL with a fixed RNG")
    args = ap.parse_args(argv)

    if args.tables:
        st, hp = stat_table(), hp_table()
        print("stat table @ 0x%08X (6 stats, index = 3*rate + tier)" % STAT_TABLE_VA)
        for r in range(16):
            print("  rate %2d: %s" % (r, " ".join("%5d" % st[3 * r + t]
                                                  for t in range(3))))
        print("hp table   @ 0x%08X (growth byte +0x18, bands 20/60)" % HP_TABLE_VA)
        for r in range(16):
            print("  rate %2d: %s" % (r, " ".join("%5d" % hp[3 * r + t]
                                                  for t in range(3))))
        return 0

    if args.template is not None:
        rec = template_records()[args.template]
        print("record %d: id=%d level=%d exp=%d hp=%d/%d" % (
            args.template, struct.unpack_from("<I", rec, 0)[0],
            rec[RECORD["level"][0]],
            struct.unpack_from("<H", rec, RECORD["exp"][0])[0],
            struct.unpack_from("<H", rec, RECORD["hp_cur"][0])[0],
            struct.unpack_from("<H", rec, RECORD["hp_max"][0])[0]))
        print("  stats  %s" % list(rec[0x10:0x16]))
        print("  growth %s" % list(rec[0x18:0x1E]))
        return 0

    if args.levelup is not None:
        rec = bytearray(template_records()[0])
        rec[RECORD["level"][0]] = args.levelup

        def rand():
            return 0  # the minimum of the random term: floor(table/256)
        r = level_up(rec, rand)
        print(json.dumps(r, indent=1))
        return 0

    if args.json:
        print(json.dumps(as_json(), indent=1))
        return 0

    print(__doc__.split("Usage:")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
