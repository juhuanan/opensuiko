#!/usr/bin/env python3
"""Gate for the per-level growth rules in kit/tools/growth_rules.py.

Every assertion below is either

  * an **instruction word** read out of MAIN.EXE / SLUS_002.92 (the encoding is
    the fact -- the immediates are compared, never a fitted number), or
  * a **static source contract** for the complete level-up and tier helpers,
    with independent arithmetic checked against the Python model, or
  * a **disc byte** (the SLUS default game-state block and its 78 x 0x50
    character table).

Nothing here is asserted because a document says so.

Run:  .venv/bin/python kit/tests/test_growth_rules.py
"""
from __future__ import annotations

import os
import struct
import sys

_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
sys.path.insert(0, os.path.abspath(_TOOLS))

import growth_rules as GR  # noqa: E402
import maindec  # noqa: E402
from test_character_growth_storage import growth_source_tables

PASS = 0

def ok(cond, msg):
    global PASS
    assert cond, "FAIL: " + msg
    PASS += 1
    print(f"PASS: {msg}")


# ---------------------------------------------------------------------------
# 1. The record: offsets, stride, bound, level byte
# ---------------------------------------------------------------------------
def test_record_layout():
    ok(GR.RECORD_STRIDE == 0x50, "the record stride is 0x50 (addiu v1,v1,0x50 "
                                 "@0x8013878C)")
    ok(GR.RECORD_COUNT == 0x4E, "the record count is 78 (slti v0,a1,0x4E "
                                "@0x80138784) and 78 == 0x4E")
    # The linker's bound is the end of the table: 0x294 + 78*0x50.
    w = maindec.mword(0x800C4A38)
    imm = w & 0xFFFF
    ok((w >> 26) == 0x0A and imm == 0x1AF4,
       f"0x800C4A38 is `slti v0,a0,0x1AF4` (word {w:#010x}) and "
       f"0x294 + 78*0x50 == 0x{GR.RECORD_BASE_OFF + GR.RECORD_COUNT * GR.RECORD_STRIDE:04X}")
    ok(GR.RECORD_BASE_OFF + GR.RECORD_COUNT * GR.RECORD_STRIDE
       == GR.RECORD_TABLE_END_OFF,
       "the table ends exactly at 0x1AF4 -- no room for a second packed table "
       "at a 0x40 stride")
    # The level byte: the growth routine increments +0x0D, and the gate routine
    # compares gs+0x2A1 (= 0x294+0x0D) as a level.
    w = maindec.mword(0x800E9CEC)
    ok((w >> 26) == 0x24 and ((w >> 21) & 0x1F) == 19 and ((w >> 16) & 0x1F) == 2
       and (w & 0xFFFF) == 0x0D,
       f"0x800E9CEC is `lbu v0,0x0D(s3)` (word {w:#010x}): the level byte")
    w = maindec.mword(0x800E9CF4)
    ok((w >> 26) == 0x0B and (w & 0xFFFF) == 0x63,
       "0x800E9CF4 is `sltiu v0,v0,0x63` -- the level cap is 99")
    w = maindec.mword(0x800E9D18)
    ok((w >> 26) == 0x28 and (w & 0xFFFF) == 0x0D,
       "0x800E9D18 is `sb v0,0x0D(s3)` -- the level is incremented here")
    w = maindec.mword(0x8013D7AC)
    ok((w >> 26) == 0x24 and (w & 0xFFFF) == 0x2A1,
       "0x8013D7AC reads `0x2A1(v1)` with v1 = gs: 0x294+0x0D == 0x2A1, so that "
       "routine tests the same level byte")
    ok(GR.RECORD["level"][0] == 0x0D and GR.RECORD["exp"][0] == 0x0E,
       "level +0x0D / exp +0x0E are adjacent (the save lead's own fingerprint)")


def test_record_is_what_the_battle_code_reads():
    """char_ptr->0x1C is set to gs+0x294+0x50*j -- so the growth target IS the
    persistent record, not a copy."""
    w = maindec.mword(0x800C4A08)
    ok((w >> 26) == 0x0D and (w & 0xFFFF) == 0x8294,
       "0x800C4A08 is `ori v1,v1,0x8294` with v1 = 0x801B0000 (lui @0x800C4A04): "
       "the record table base is spelled out absolutely exactly once")
    w = maindec.mword(0x800C4A30)
    ok((w >> 26) == 0x2B and ((w >> 21) & 0x1F) == 16 and (w & 0xFFFF) == 0x1C,
       "0x800C4A30 is `sw v1,0x1C(s0)` in the id-match loop -- char_ptr+0x1C = "
       "the matching gs record")
    img = GR._slus_image()
    w = struct.unpack_from("<I", img, 0x8001B43C - GR.SLUS_BASE)[0]
    ok((w >> 26) == 0x0D and (w & 0xFFFF) == 0x8294,
       "SLUS_002.92 carries the same linker (0x8001B43C), so both modules agree "
       "on the record base")


# ---------------------------------------------------------------------------
# 2. The boot seeder: where the record table comes from
# ---------------------------------------------------------------------------
def test_boot_seeder():
    img = GR._slus_image()
    B = GR.SLUS_BASE
    w = struct.unpack_from("<I", img, 0x80017550 - B)[0]
    w2 = struct.unpack_from("<I", img, 0x80017554 - B)[0]
    ok((w >> 26) == 0x0F and (w & 0xFFFF) == 0x8004 and
       (w2 >> 26) == 0x09 and (w2 & 0xFFFF) == 0x2FE0,
       "SLUS 0x80017550/54 is `lui a2,0x8004; addiu a2,a2,0x2FE0` -- the source "
       "of the default game-state block")
    w = struct.unpack_from("<I", img, 0x8001754C - B)[0]
    w2 = struct.unpack_from("<I", img, 0x80017560 - B)[0]
    ok((w >> 26) == 0x0F and (w & 0xFFFF) == 0x801B and
       (w2 >> 26) == 0x0D and (w2 & 0xFFFF) == 0x8000,
       "SLUS 0x8001754C/60 builds the destination 0x801B8000 == the game-state base")
    for a in (0x80017564, 0x800175BC):
        w = struct.unpack_from("<I", img, a - B)[0]
        ok((w >> 26) == 0x09 and (w & 0xFFFF) == 0x1D60,
           f"SLUS 0x{a:08X} is `addiu t0,a2,0x1D60` -- the copy is exactly the "
           f"0x1D60-byte persistent payload")
    clear = struct.unpack_from("<I", img, 0x800175F8 - B)[0]
    gs_ptr = struct.unpack_from("<I", img, 0x800420C0 - B)[0]
    ok(clear == 0xA0400002 and gs_ptr == 0x801B8000,
       "SLUS 0x800175F8 clears gs+0x02 after the seed copy")
    ok(GR.TEMPLATE_VA == 0x80043274 and
       GR.TEMPLATE_VA == GR.BOOT_SEED_SRC + GR.RECORD_BASE_OFF,
       "the 78 x 0x50 block the corpus calls the character template is "
       "0x80042FE0 + 0x294 == 0x80043274 -- it is the *inside* of the default "
       "game-state block, not a separate table")

    blk = GR.boot_seed_block()
    ok(len(blk) == 0x1D60, "the default block is 0x1D60 bytes, matching the "
                           "memcard payload length")
    ok(blk[0x08] == 8 and all(b == 0xFF for b in blk[0x09:0x0E]),
       f"default party[0] = {blk[0x08]} (the Hero) and the rest 0xFF -- the "
       f"block is a real new-game state, so its +0x294 table is the level-1 table")
    ok(struct.unpack_from("<I", blk, 0x1C)[0] == 1500,
       "default gold (gs+0x1C) = 1500 -- a plausible new-game value, not padding")

    recs = GR.template_records()
    ok(len(recs) == GR.RECORD_COUNT and all(len(r) == GR.RECORD_STRIDE for r in recs),
       "78 records of 0x50 bytes")
    ok(all(r[GR.RECORD["level"][0]] == 1 for r in recs),
       "every default record is level 1 (so the level-1 template == the "
       "persistent record layout)")
    ok(all(struct.unpack_from("<H", r, GR.RECORD["exp"][0])[0] == 0
           for r in recs[:71] + recs[72:]),
       "77 of the 78 default records start at 0 EXP (record 71 ships with 12 -- "
       "shipped data, below the 1000 threshold)")
    ok(max(struct.unpack_from("<H", r, GR.RECORD["exp"][0])[0] for r in recs) < 1000,
       "no default record starts above the 1000 EXP level threshold")
    ok(all(max(r[0x10:0x16]) <= 30 for r in recs),
       "the six stat bytes are <= 30 at level 1")
    ok(all(max(r[0x18:0x1E]) <= 13 for r in recs),
       "the six growth bytes are <= 13 -- inside the 48-entry table's domain")


def test_camera_readers_do_not_read_this_table():
    """The 'the template is not a stat table' refutation assumed those three
    routines read it.  They do not: they dereference slot+0x0C, and their
    divisor is lh(record+0x02), which is 0 in all 78 template records -- and a
    0 divisor hits the compiler's `break`."""
    for ptr_addr in (0x800E62E4, 0x800E665C, 0x800E6758):
        w = maindec.mword(ptr_addr)
        ok((w >> 26) == 0x23 and (w & 0xFFFF) == 0x0C,
           f"0x{ptr_addr:08X} loads the record pointer from slot+0x0C -- the "
           f"record is an indirection, not the table base")
    w = maindec.mword(0x800E62EC)
    ok((w >> 26) == 0x21 and (w & 0xFFFF) == 0x02,
       "0x800E62EC is `lh t0,0x02(record)` -- the value the triangular loop and "
       "the division use")
    recs = GR.template_records()
    z = sum(1 for r in recs if struct.unpack_from("<h", r, 0x02)[0] == 0)
    ok(z == 78,
       f"lh(record+0x02) == 0 in {z}/78 template records; the accessor divides "
       f"by the triangular number of that value (0x800E6358 `div a2,a3` with "
       f"the break guard 0x800E6364), so it cannot be reading these records")


# ---------------------------------------------------------------------------
# 3. Static growth and HP table indexing
# ---------------------------------------------------------------------------
def test_growth_function_matches_stat_index():
    growth_source_tables()
    immediate = lambda pc: maindec.mword(pc) & 0xFFFF
    special_class = immediate(0x800E9C40)
    common = (immediate(0x800E9C50), immediate(0x800E9C9C))
    early = (immediate(0x800E9C3C), immediate(0x800E9C5C))
    late = (immediate(0x800E9C48), immediate(0x800E9C78))
    for rate in range(16):
        if immediate(0x800E9C28) <= rate < immediate(0x800E9C34):
            edges = early
        elif rate == special_class:
            edges = late
        else:
            edges = common
        for level in range(1, 100):
            assert GR.stat_index(level, rate) == 3 * rate + sum(level >= edge for edge in edges)
    ok(True, "the source tier thresholds match stat_index() for all 99 x 16 inputs")


def test_growth_function_bands():
    """The band edges are the immediates in the words, not a reading."""
    ok(GR.tier_bands(0) == (20, 60) and GR.tier_bands(8) == (20, 60),
       "growth < 9 uses the 20/60 bands (slti 0x14 @0x800E9C30, slti 0x3c "
       "@0x800E9C48)")
    ok(GR.tier_bands(9) == (15, 60) and GR.tier_bands(10) == (15, 60),
       "growth 9..10 uses the 15/60 bands (slti 0xf @0x800E9C3C)")
    ok(GR.tier_bands(11) == (20, 60) and GR.tier_bands(13) == (20, 60),
       "growth 11..13 falls through to the 20/60 bands")
    ok(GR.tier_bands(14) == (60, 80),
       "growth == 14 uses the 60/80 bands (beq 14 @0x800E9C44, slti 0x50 "
       "@0x800E9C78) and returns 42/43/44 = 3*14 + tier")
    ok(GR.stat_index(59, 14) == 42 and GR.stat_index(60, 14) == 43
       and GR.stat_index(80, 14) == 44,
       "rate 14: 42 below level 60, 43 from 60, 44 from 80")
    ok(all(GR.stat_index(lv, rt) == 3 * rt + (0 if lv < 20 else 1 if lv < 60 else 2)
           for lv in range(1, 100) for rt in range(0, 9)),
       "for growth < 9 the index is exactly 3*rate + (0/1/2) by level band")


def test_hp_index_uses_first_growth_byte():
    edges = tuple(maindec.mword(pc) & 0xFFFF for pc in (0x800E9DBC, 0x800E9DD0))
    for g0 in range(16):
        for level in range(1, 100):
            assert GR.hp_index(level, g0) == 3 * g0 + sum(level >= edge for edge in edges)
    ok(True, "the static HP tier chain matches hp_index() for all 99 x 16 inputs")
    ok(maindec.mword(0x800E9D0C) == 0x92740018,
       "0x800E9D0C is lbu s4,0x18(s3), the first record growth byte")


def test_gain_arithmetic():
    """The mask/shift pair, over the RNG's whole output range (0..0x7FFF)."""
    for bits, right, left, shift in ((8, 0x800E9D58, 0x800E9D60, 0x800E9D78),
                                     (9, 0x800E9E18, 0x800E9E20, 0x800E9E38)):
        right_word, left_word, shift_word = (maindec.mword(pc) for pc in (right, left, shift))
        assert (right_word & 63, left_word & 63, shift_word & 63) == (3, 0, 3)
        assert all(word >> 26 == 0 for word in (right_word, left_word, shift_word))
        right_bits, left_bits, result_bits = ((word >> 6) & 31 for word in (right_word, left_word, shift_word))
        assert (right_bits, left_bits, result_bits) == (bits, bits, 8)
        # The earlier source check pins the subtraction between the two shifts
        # and the table addition. The RNG service returns non-negative values.
        assert all(GR.gain(1000, draw, bits) ==
                   (1000 + draw - ((draw >> right_bits) << left_bits)) >> result_bits
                   for draw in range(0x8000))
        ok(True, f"the {bits}-bit source remainder and gain agree for all 32768 RNG values")


def test_no_rng_consumed_at_max_level():
    n = [0]

    def rand():
        n[0] += 1
        return 0

    rec = bytearray(GR.template_records()[0])
    rec[GR.RECORD["level"][0]] = GR.MAX_LEVEL
    r = GR.level_up(rec, rand)
    ok(r["skipped"] and n[0] == 0,
       "at level 99 the routine returns at 0x800E9CF8 before any growth: the "
       "level does not move and rand() is not called")


def test_level_up_rng_order_and_record_writes():
    seq = []

    def rand():
        seq.append(len(seq))
        return 0x7FFF

    rec = bytearray(GR.template_records()[0])
    before = bytes(rec)
    growth_before = bytes(rec[0x18:0x1E])
    r = GR.level_up(rec, rand)
    ok(len(seq) == 7,
       f"one level-up consumes exactly 7 rand() calls (6 stats + 1 HP); got {len(seq)}")
    ok(r["level"] == 2 and rec[GR.RECORD["level"][0]] == 2,
       "the level byte advances by exactly one per level-up")
    ok(bytes(rec[0x18:0x1E]) == growth_before,
       "the growth bytes +0x18..+0x1D are NEVER written by the level-up routine "
       "-- they are the static per-character source, and the six current values "
       "at +0x10..+0x15 are the sinks")
    changed = {i for i in range(0x50) if rec[i] != before[i]}
    ok(changed <= {0x04, 0x05, 0x06, 0x07, 0x0D} | set(range(0x10, 0x16)),
       f"the only bytes the level-up routine writes are the level, the six stats "
       f"and the HP pair; written set = {sorted(hex(c) for c in changed)}")
    # The clamp is min(0xFF, cur+gain), saturating rather than wrapping.
    t = GR.stat_table()
    lo = min(t[GR.stat_index(1, rt)] >> 8 for rt in range(14))
    hi = max((t[GR.stat_index(1, rt)] + 0xFF) >> 8 for rt in range(14))
    ok(lo == 0 and hi <= 8,
       f"a level-1 gain is {lo}..{hi} points for every growth class actually in "
       f"the template (rate <= 13) -- small integer growth, not a score")


def test_stats_saturate():
    """cur + gain >= 0x100 stores 0xFF (slti 0x100 @0x800E9D8C), not a wrap."""
    w = maindec.mword(0x800E9D8C)
    ok((w >> 26) == 0x0A and (w & 0xFFFF) == 0x100,
       "0x800E9D8C is `slti v0,v0,0x100` -- the 0xFF saturation guard")
    rec = bytearray(GR.template_records()[0])
    rec[GR.RECORD["stats"][0]] = 254
    rec[GR.RECORD["growth"][0]] = 13
    GR.level_up(rec, lambda: 0x7FFF)
    ok(rec[GR.RECORD["stats"][0]] == 0xFF,
       "a stat at 254 with a 2+ gain saturates at 0xFF")


# ---------------------------------------------------------------------------
# 4. EXP -> level
# ---------------------------------------------------------------------------
def test_exp_thresholds():
    w = maindec.mword(0x800E89D4)
    ok((w >> 26) == 0x0A and (w & 0xFFFF) == 0x3E8,
       "0x800E89D4 is `slti v1,v1,0x3E8`: the level threshold is 1000")
    w = maindec.mword(0x800E8A04)
    ok((w >> 26) == 0x09 and (w & 0xFFFF) == 0xFC18,
       "0x800E8A04 subtracts 0x3E8 (addiu -0x3E8 == 0xFC18) per level")
    w = maindec.mword(0x800E8A20)
    ok((w >> 26) == 0x03 and
       ((w & 0x03FFFFFF) << 2) | 0x80000000 == GR.LEVEL_UP_ROUTINE,
       "0x800E8A20 calls the level-up routine 0x800E9CC4")
    w = maindec.mword(0x8013903C)
    ok((w >> 26) == 0x0B and (w & 0xFFFF) == 0x3E8,
       "the event-script EXP opcode uses the same 1000 (sltiu @0x8013903C) and "
       "adds 10 per call (addiu 0xa @0x80139024)")


def test_exp_to_level_is_flat():
    """Every 1000 of total EXP buys exactly one level; the leftover is kept."""
    for total in (0, 1, 999, 1000, 1001, 2999, 3000, 7777):
        rec = bytearray(GR.template_records()[0])
        r = GR.battle_exp(rec, total, lambda: 0)
        want_lv = 1 + total // 1000
        ok(rec[GR.RECORD["level"][0]] == want_lv
           and r["leftover_exp"] == total % 1000
           and struct.unpack_from("<H", rec, GR.RECORD["exp"][0])[0] == total % 1000,
           f"{total} EXP -> level {want_lv} with {total % 1000} carried")
    # A pool larger than one level's worth loops: 2500 at level 1 -> levels 2,3.
    rec = bytearray(GR.template_records()[0])
    r = GR.battle_exp(rec, 2500, lambda: 0)
    ok([x["level"] for x in r["levels"]] == [2, 3] and r["leftover_exp"] == 500,
       "one award of 2500 EXP grants two levels (the loop re-tests at "
       "0x800E8A44) and carries 500")


def test_drain_matches_the_flat_rule():
    """The 16-point drain 0x800E8ABC and the flat rule agree, step for step.

    This is what makes the simple port rule safe: the drain's chunk size is
    `pool if pool < 17 else 16` (`slti a2,0x11` @0x800E8AFC, `bne` to 0x800E8B7C
    when the pool is the smaller) -- NOT a blind 16, which would over-draw a
    1..16 pool and leave the counter running.
    """
    bad = 0
    for e0 in (0, 1, 15, 16, 100, 500, 983, 984, 999):
        for pool in range(0, 3000, 11):
            a = bytearray(GR.template_records()[0])
            struct.pack_into("<H", a, GR.RECORD["exp"][0], e0)
            b = bytearray(a)
            list(GR.drain_exp(a, pool, lambda: 0))
            GR.battle_exp(b, pool, lambda: 0)
            if (a[GR.RECORD["level"][0]],
                struct.unpack_from("<H", a, GR.RECORD["exp"][0])[0]) != \
               (b[GR.RECORD["level"][0]],
                struct.unpack_from("<H", b, GR.RECORD["exp"][0])[0]):
                bad += 1
    ok(bad == 0,
       f"the 16-point drain and the flat 1000-per-level rule agree on the final "
       f"(level, exp) for all {9 * len(range(0, 3000, 11))} sampled "
       f"(starting exp, pool) pairs")
    w = maindec.mword(0x800E8AFC)
    ok((w >> 26) == 0x0A and (w & 0xFFFF) == 0x11,
       "0x800E8AFC is `slti v0,a2,0x11` -- the pool-size branch (17), the "
       "immediate the chunk rule rests on")


def test_level_cap_holds():
    rec = bytearray(GR.template_records()[0])
    rec[GR.RECORD["level"][0]] = 98
    r = GR.battle_exp(rec, 5000, lambda: 0)
    ok(rec[GR.RECORD["level"][0]] == 99 and len(r["levels"]) >= 1
       and r["levels"][-1]["skipped"],
       "the level byte stops at 99 even when the pool would buy more levels")


# ---------------------------------------------------------------------------
# 5. The tables themselves
# ---------------------------------------------------------------------------
def test_tables_are_image_data():
    st, hp = GR.stat_table(), GR.hp_table()
    ok(len(st) == GR.TABLE_ENTRIES and len(hp) == GR.TABLE_ENTRIES,
       "both gain tables are 48 words")
    ok(0x8016BE08 + 4 * GR.TABLE_ENTRIES == 0x8016BEC8,
       "the HP table (0x8016BE08) ends exactly where the stat table (0x8016BEC8) "
       "begins -- two 48-word arrays, no gap")
    w = maindec.mword(0x800E9D00)
    ok((w >> 26) == 0x0F and (w & 0xFFFF) == 0x8017,
       "0x800E9D00 is `lui s6,0x8017`; with 0x800E9D04 `addiu s6,s6,-0x4138` "
       "(sign-extended) that is 0x8016BEC8 -- the stat table base")
    w = maindec.mword(0x800E9E04)
    ok((w >> 26) == 0x09 and (w & 0xFFFF) == 0xBE08,
       "0x800E9E04 is `addiu v1,v1,-0x41F8` (0xBE08) -> 0x8016BE08, the HP table")
    ok(all(0 <= v < 0x100000 for v in st + hp),
       "every table entry is a plausible 1/256-unit gain, not an address")
    rates = {r[GR.RECORD["growth"][0] + i]
             for r in GR.template_records() for i in range(6)}
    ok(max(rates) <= 13,
       f"the highest growth byte in the default table is {max(rates)}, so the "
       f"template only ever addresses table indices 0..{3 * max(rates) + 2}")
    ok(3 * max(rates) + 2 < GR.TABLE_ENTRIES,
       "the addressed range stays inside the 48-word table")


def test_expected_gains_are_sane():
    """A cross-check that the units are points-per-level, not raw scores."""
    t = GR.stat_table()
    lo = GR.expected_gain(t[GR.stat_index(1, 0)])
    hi = GR.expected_gain(t[GR.stat_index(1, 8)])
    ok(0.3 <= lo <= 1.2 and 4.0 <= hi <= 4.6,
       f"at level 1 the weakest growth class expects {lo:.2f} points/level and "
       f"the strongest {hi:.2f} -- a level-99 character totals a few hundred "
       f"points, which is the scale the battle formulas consume")
    hp = GR.hp_table()
    ok(3.0 <= GR.expected_gain(hp[GR.hp_index(1, 6)]) <= 11.0,
       "HP growth is 3..11 points per level at level 1 -- the HP scale the "
       "damage formula's operands live in")


def test_addresses_resolve():
    """Every address in ADDR is inside the image it claims."""
    main_len = len(maindec.body())
    for key, (va, image, _what) in GR.ADDR.items():
        if image == "MAIN":
            ok(0 <= va - GR.MAIN_BASE < main_len - 4,
               f"ADDR[{key}] = 0x{va:08X} is inside the MAIN.EXE image")
        else:
            ok(0 <= va - GR.SLUS_BASE < len(GR._slus_image()) - 4,
               f"ADDR[{key}] = 0x{va:08X} is inside the SLUS_002.92 image")


def main():
    for fn in (test_record_layout,
               test_record_is_what_the_battle_code_reads,
               test_boot_seeder,
               test_camera_readers_do_not_read_this_table,
               test_growth_function_matches_stat_index,
               test_growth_function_bands,
               test_hp_index_uses_first_growth_byte,
               test_gain_arithmetic,
               test_no_rng_consumed_at_max_level,
               test_level_up_rng_order_and_record_writes,
               test_stats_saturate,
               test_exp_thresholds,
               test_exp_to_level_is_flat,
               test_drain_matches_the_flat_rule,
               test_level_cap_holds,
               test_tables_are_image_data,
               test_expected_gains_are_sane,
               test_addresses_resolve):
        fn()
    print(f"\ngrowth rules: {PASS} assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
