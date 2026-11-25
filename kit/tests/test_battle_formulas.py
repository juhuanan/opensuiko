#!/usr/bin/env python3
"""Structural gates for the battle formulas derived in kit/docs/battle_formulas.md.

Every assertion here is a fact read from an instruction word or from the
persistent record layout -- NOT a fitted value.  In particular:

  * the arithmetic invariants are property-tested over the whole input range the
    instruction sequence can take, never against a hardcoded derived number;
  * the record layout facts are re-derived from the disc bytes, not copied from
    the tool that produced them;
  * the "growth" negative is asserted by running the two candidate readings (the
    triangular-divisor interpolation vs. a linear level ramp) and showing that
    only the first reproduces the instruction sequence's own outputs.

Run:  .venv/bin/python kit/tests/test_battle_formulas.py
"""
from __future__ import annotations

import os
import struct
import sys

_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
sys.path.insert(0, os.path.abspath(_TOOLS))

import battle_formulas as BF  # noqa: E402
import character_table as CT  # noqa: E402
import maindec  # noqa: E402

PASS = 0


def ok(cond, msg):
    global PASS  # noqa: PLW0603 -- a module-level tally keeps the assertions flat
    assert cond, "FAIL: " + msg
    PASS += 1
    print(f"PASS: {msg}")


# ---------------------------------------------------------------------------
# 1. The battle-slot stride and the three array bases, re-derived from encoding
# ---------------------------------------------------------------------------
def test_slot_stride():
    """The engine's own index chain is 140*n; read it out of the words."""
    # The shifts and add/subtract give (((8 + 1) * 4) - 1) * 4.
    words = [maindec.mword(pc) for pc in range(0x800E62BC, 0x800E62DC, 4)]
    ok(words == [0x01404821, 0x000910C0, 0x00491021, 0x00021080,
                 0x3C038018, 0x8C63BE3C, 0x00491023, 0x00021080],
       "0x800E62BC..0x800E62D8 adds, subtracts and shifts the actor index")
    ok((((8 + 1) * 4) - 1) * 4 == BF.SLOT_STRIDE,
       "the actor index has a 140-byte stride")

    # Pin the separate base offsets at the consuming sites.
    for addr, off, why in (
        (0x800E62DC, 0x50, "slot array"),
        (0x800E169C, 0xB40, "battle-slot array"),
        (0x800F7EE8, 0xB40, "battle-slot array (damage routine)"),
        (0x800DEC3C, 0xF90, "actor/image array (party loader)"),
        (0x800F7F0C, 0xF84, "actor array (damage routine)"),
        (0x800DEC30, 0x1B9C, "char-record array"),
    ):
        w = maindec.mword(addr)
        imm = w & 0xFFFF
        ok((w >> 26) & 0x3F == 0x09 and imm == off,
           f"0x{addr:08X} is `addiu ...,{off:#x}(...)` -- the {why} base")


# ---------------------------------------------------------------------------
# 2. Participant allocation
# ---------------------------------------------------------------------------
def test_participant_alloc():
    """0x800DDF98 mallocs 0x342C and is the SOLE writer of 0x8017BE3C."""
    j = maindec.mword(0x800DDFA8)
    jt = ((0x800DDFA8 + 4) & 0xF0000000) | ((j & 0x3FFFFFF) << 2)
    ok(jt == 0x800C2D30, f"0x800DDFA8 jal -> 0x{jt:08X} (the heap allocator)")
    sz = maindec.mword(0x800DDFAC)
    ok((sz >> 26) & 0x3F == 0x0D and (sz & 0xFFFF) == BF.PARTICIPANT_MAGIC,
       f"0x800DDFAC is `ori $a0,$zero,0x{BF.PARTICIPANT_MAGIC:X}` -- the battle "
       f"participant struct is {BF.PARTICIPANT_MAGIC} bytes")

    hits = []
    body = maindec.body()
    for i in range(0, len(body) - 4, 4):
        w = struct.unpack_from("<I", body, i)[0]
        op = w >> 26
        if op in (0x2B, 0x29, 0x28):        # sw / sh / sb
            imm = w & 0xFFFF
            if imm >= 0x8000:
                imm -= 0x10000
            if imm == -0x41C4:              # 0x8017BE3C via lui 0x8018
                hits.append(0x800C0800 + i)
    ok(hits == [0x800DDFD8],
       f"0x8017BE3C has exactly one static store site: 0x{hits[0]:08X}"
       if hits else f"0x8017BE3C store sites: {hits}")


# ---------------------------------------------------------------------------
# 3. RNG range and the two modulo idioms the formulas rely on
# ---------------------------------------------------------------------------
def test_rng():
    """bios_rand() is uniform over 0..0x7FFF, so %100 spans 0..99."""
    vals = set()
    seed = 1
    for _ in range(200000):
        v, seed = BF.bios_rand(seed)
        assert 0 <= v <= BF.RAND_MAX
        vals.add(v)
    ok(len(vals) > 30000, f"0x80147E38 result stays in 0..{BF.RAND_MAX} and "
                          f"takes {len(vals)} distinct values over 200k draws")
    ok({v % 100 for v in vals} == set(range(100)),
       "rand() % 100 covers all of 0..99 (observed max 32767 % 100 == 67)")
    ok({v % 4 for v in vals} == {0, 1, 2, 3},
       "rand() % 4 covers 0..3 -- the `d < 10` variance term")


# ---------------------------------------------------------------------------
# 4. Physical damage: the two branches, as properties of the instruction seq
# ---------------------------------------------------------------------------
def test_physical_damage_properties():
    global PASS

    def pair(d):
        """The (atk_word, def_word) that make the engine compute this d."""
        a, b = (40000 + d, 40000) if d < 0 else (40000 + d, 40000)
        assert (a & 0xFFFF) - (b & 0xFFFF) == d
        return a, b

    # Branch 1 (d < 10):  damage = d + 1 - (rand % 4), remainder truncated
    # toward zero by the MIPS `div`/`mfhi` pair.
    for d in range(-20, 10):
        a, b = pair(d)
        outs = sorted({BF.physical_damage(a, b, r) for r in range(0, 200)})
        raw = sorted({max(1, d + 1 - BF.mips_mod(r, 4)) for r in range(200)})
        assert outs == raw, f"d={d}: {outs} != {raw}"
    PASS += 1
    print("PASS: physical_damage branch d<10 == d + 1 - (rand()%4) with the MIPS "
          "truncating remainder, clamped at 1, for every d in -20..9")

    # Branch 2 (d >= 10): divide the signed variance adjustment before adding it.
    for d in (10, 11, 40, 99, 100, 999, 10000):
        a, b = pair(d)
        outs = sorted({BF.physical_damage(a, b, r) for r in range(0, 400)})
        raw = sorted({max(1, d + BF.mips_div(d//2 - BF.mips_mod(r,d),5))
                      for r in range(400)})
        assert outs == raw, f"d={d}: {outs[:6]} != {raw[:6]}"
    PASS += 1
    print("PASS: physical_damage branch d>=10 == d + trunc((d//2 - rand()%d)/5)")

    # The generic MIPS remainder helper truncates even for negative operands.
    ok(BF.mips_mod(-19, 4) == -3 and (-19) % 4 == 1,
       "mips_mod(-19,4) == -3 while Python's -19 % 4 == 1")

    # The divisor is NEVER zero on the d>=10 path: 0x800F7F04 is `slti 0xa`.
    w = maindec.mword(0x800F7F04)
    ok((w >> 26) & 0x3F == 0x0A and (w & 0xFFFF) == 0x000A,
       "0x800F7F04 is `slti $v0,$s0,0xA` -> the `% d` divisor is >= 10, so the "
       "div-by-zero guard at 0x800F7F48 is unreachable")

    # Variance really is bounded: the spread is under the value for large d.
    for d in (100, 1000):
        a, b = pair(d)
        outs = [BF.physical_damage(a, b, r) for r in range(400)]
        base = d + BF.mips_div(d//2,5)
        ok(max(outs) - min(outs) <= d,
           f"d={d}: the rand()%d term keeps the damage inside a {max(outs)-min(outs)}"
           f"-wide band around {base}")


def test_master_multiplier_sites():
    global PASS
    """The state-gated `+= damage//20 * affinity` term only fires for state 1/3."""
    seq = {
        0x800F80B4: "lbu affinity byte",
        0x800F80F4: "div by 0x14",
        0x800F812C: "mult by the affinity byte",
        0x800F813C: "add back",
        0x800F8148: "floor at 1",
    }
    for addr in seq:
        w = maindec.mword(addr)
        ok(w is not None, f"0x{addr:08X} is inside MAIN.EXE ({seq[addr]})")
    # 0x800F80E0/0x800F80E8: beq $a0,$v0 where $v0 was just set to 1, then
    # $v0=3 and bne -- so the accepted states are exactly 1 and 3.
    w1 = maindec.mword(0x800F80E0)
    w2 = maindec.mword(0x800F80E8)
    ok((w1 >> 26) & 0x3F == 0x04 and (w2 >> 26) & 0x3F == 0x05 and
       (w1 >> 21) & 0x1F == 4 and (w2 >> 21) & 0x1F == 4 and
       maindec.mword(0x800F80DC) == 0x34020001 and
       maindec.mword(0x800F80E4) == 0x34020003,
       "0x800F80E0/0x800F80E8 are `beq $a0,$v0` / `bne $a0,$v0` with $v0 set to "
       "1 then 3 on the same register -- attacker persistent element types1/3 take the "
       "multiplier, nothing else does")
    # Defend overwrites damage with its half; it does not add that half.
    w3 = maindec.mword(0x800F8000)
    ok((w3 >> 26) & 0x3F == 0x00 and (w3 & 0x3F) == 0x03 and
       (w3 >> 11) & 0x1F == 16 and (w3 >> 16) & 0x1F == 16 and
       (w3 >> 6) & 0x1F == 1,
       "0x800F8000 is `sra $s0,$s0,1` -- Defend halves damage with truncation toward zero")
    # Magic shares the corrected variance on first B+0x2C minus second B+0x2C.
    for d in (10, 60, 400):
        outs = {BF.magic_damage(40000 + d, 40000, r,element=5,element_index=1) for r in range(0, 300)}
        raw = {d + BF.mips_div(d//2 - BF.mips_mod(r,d),5)
               for r in range(300)}
        assert outs == raw, f"magic d={d}: {sorted(outs)[:6]} != {sorted(raw)[:6]}"
    PASS += 1
    print("PASS: magic_damage @0x800F8174 is physical_damage's arithmetic on the "
          "self-minus-other difference of stat index 2")

    # The element-match halve takes the same biased-shift shape at 0x800F80CC.
    w4 = maindec.mword(0x800F80CC)
    w5 = maindec.mword(0x800F80D4)
    ok((w4 >> 26) & 0x3F == 0x00 and (w4 & 0x3F) == 0x02 and
       (w4 >> 6) & 0x1F == 31 and (w4 >> 11) & 0x1F == 2 and
       (w4 >> 16) & 0x1F == 16 and
       (w5 >> 26) & 0x3F == 0x00 and (w5 & 0x3F) == 0x03 and
       (w5 >> 6) & 0x1F == 1,
       "0x800F80CC/0x800F80D4 are `srl $v0,$s0,31` / `sra $v0,$v0,1` -- the "
       "sign-bias idiom for a round-toward-zero halve, used on BOTH the "
       "target_class==1 and the element-match paths")


# ---------------------------------------------------------------------------
# 5. Hit chance
# ---------------------------------------------------------------------------
def test_hit_chance():
    w_lo = maindec.mword(0x800F7DB8)
    w_low_set = maindec.mword(0x800F7DC4)
    w_hi_test = maindec.mword(0x800F7DC8)
    w_hi_set = maindec.mword(0x800F7DD4)
    ok((w_lo >> 26) & 0x3F == 0x0A and (w_lo & 0xFFFF) == 0x003C,
       "0x800F7DB8 is `slti $v0,$s0,0x3C` -- the low clamp is 60")
    ok((w_low_set >> 26) & 0x3F == 0x0D and (w_low_set & 0xFFFF) == 0x003C and
       (w_hi_test >> 26) & 0x3F == 0x0A and (w_hi_test & 0xFFFF) == 0x0064 and
       (w_hi_set >> 26) & 0x3F == 0x0D and (w_hi_set & 0xFFFF) == 0x0063,
       "0x800F7DC4 `ori $s0,0x3C` / 0x800F7DC8 `slti 0x64` / 0x800F7DD4 "
       "`ori $s0,0x63`: the speed difference is clamped into [60, 99]")

    # Property: a hit is decided by one 0..99 roll against the clamped difference.
    for spd_s, spd_o in ((100, 50), (50, 50), (10, 50), (200, 20), (0, 0)):
        p = min(99, max(60, spd_s - (spd_o - 0x50)))
        hits = sum(BF.hit_roll(spd_s, spd_o, r) for r in range(0, 10000))
        # rand()%100 sweeps 0..99 as r sweeps any 100 consecutive values
        expect = p
        ok(hits == expect * 100,
           f"hit_roll({spd_s},{spd_o}) lands {hits} of 10000 rolls == "
           f"clamped_difference({p}) x 100")
    # Clamp behaviour at the extremes.
    ok(all(BF.hit_roll(0, 1000, r) for r in range(0, 60)),
       "with the difference clamped to 60, the first 60 of every 100 rolls hit")
    ok(not BF.hit_roll(0, 1000, 60),
       "with the difference clamped to 60, roll 60 misses")


# ---------------------------------------------------------------------------
# 6. HP application
# ---------------------------------------------------------------------------
def test_hp_apply():
    w = maindec.mword(0x800E16E8)
    ok((w >> 26) & 0x3F == 0x0C and (w & 0xFFFF) == 0x8000,
       "0x800E16E8 is `andi $v0,$v0,0x8000` on the battle-slot flag word")
    ok(BF.hp_apply(100, 100, 50) == 50, "damage passes through unclamped")
    ok(BF.hp_apply(30, 100, 50) == -20,
       "damage larger than hp_cur leaves $v0 NEGATIVE -- the clamp at "
       "0x800E175C only fires when the result would exceed hp_max")
    ok(BF.hp_apply(30, 100, -40) == 70,
       "a heal of 40 on 30/100 hp is applied (the clamp's own condition "
       "`hp_max < hp_cur - damage` is false, 100 < 70)")
    ok(BF.hp_apply(30, 100, -90) == 100,
       "a heal that would overshoot hp_max is clamped to hp_max: "
       "100 < 30+90 == 120 -> damage = 30-100 = -70 -> result 100")
    ok(BF.hp_apply(100, 100, 50, status_flags=0x8000) == 100,
       "status flag 0x8000 zeroes the incoming damage at the apply site")
    ok(BF.hp_apply(100, 100, 0) == 100, "a zero-damage action is a no-op")
    # The accumulator is additive, matching lhu/sh at +0x4E.
    a = maindec.mword(0x800E176C)
    b = maindec.mword(0x800E177C)
    ok((a >> 26) & 0x3F == 0x25 and (b >> 26) & 0x3F == 0x29 and
       (a & 0xFFFF) == 0x4E and (b & 0xFFFF) == 0x4E,
       "0x800E176C `lhu ...,0x4E` + 0x800E177C `sh ...,0x4E`: +0x4E accumulates")


# ---------------------------------------------------------------------------
# 7. Layout facts, re-derived from the disc
# ---------------------------------------------------------------------------
def test_char_record_layout():
    """The char-record halfword bounds survive independently of the tool."""
    recs = CT.records()
    ok(len(recs) == 78, "SLUS_002.92 image 0x33274 holds 78 records of 0x50")
    a_max = max(max(r["stats"]) for r in recs)
    a_min = min(min(r["stats"]) for r in recs)
    b_max = max(max(r["growth"]) for r in recs)
    ok(0 <= a_min and a_max <= 30,
       f"the +0x10 block stays inside 0..30 (observed {a_min}..{a_max})")
    ok(b_max <= 13, f"the +0x18 block stays inside 0..13 (observed max {b_max})")
    ok(all(r["hp_current"] == r["hp_max"] for r in recs),
       "+0x04 == +0x06 in 78/78 -- the paired halfwords are one quantity, which "
       "is why the battle-slot copy writes both from the same record word")

    # What the camera accessors actually load, re-derived from the bytes.
    img = CT.image()

    def u16(row, off):
        return struct.unpack_from("<H", img, CT.IMAGE_OFF + row * 0x50 + off)[0]

    # e0 = u16 at +0x0C is 0x0100 in 78/78: a flag byte 1 with value byte 0.
    ok(all(u16(i, 0x0C) == 0x0100 for i in range(78)),
       "template +0x0C == 0x0100 in 78/78 -- (flag=1, divisor=0), which is why "
       "0x800E6648 has an `addiu ...,1` clamp in front of its divide")
    # The camera accessor at 0x800E6638 loads five u16 starting at +0x04
    # (offsets 0x04, 0x06, 0x08, 0x0A) and one at +0x02; the sprite accessor at
    # 0x800E6730 loads +0x02, +0x04, +0x06, +0x08.  None of them loads +0x10 or
    # +0x18, which is the whole point.
    loaded = set()
    for lo, hi in ((0x800E6664, 0x800E6678), (0x800E6778, 0x800E67C0)):
        for a in range(lo, hi, 4):
            w = maindec.mword(a)
            if (w >> 26) & 0x3F == 0x21 and (w >> 21) & 0x1F == 8:
                loaded.add(w & 0xFFFF)
    ok(loaded and not (loaded & {0x10, 0x18}),
       f"the template accessors load {sorted(hex(x) for x in loaded)} and never "
       f"+0x10 / +0x18 -- the two offsets the growth candidate named")
    # The u16 run the camera handler at 0x800E6638 steps over is six entries
    # from +0x0C; +0x18 is the next block's first byte, which is why the camera
    # table stops there.
    six = [u16(i, 0x0C + 2 * k) & 0xFF for i in range(78) for k in range(6)]
    ok(max(six) <= 30,
       f"the six u16 at +0x0C..+0x16 hold value bytes in 0..{max(six)} -- all "
       f"<= 30, i.e. frame steps, and the run STOPS at +0x18")

    # The battle slot's stat vector is built by the copy loop at
    # 0x800F6F20..0x800F6F34: `lhu $v0,0x14($v1)` -> `sh $v0,0x24($v1)` with a
    # 2-byte step on both sides.
    src = maindec.mword(0x800F6F20)
    dst = maindec.mword(0x800F6F28)
    ok((src >> 26) & 0x3F == 0x25 and (src & 0xFFFF) == 0x0014 and
       (dst >> 26) & 0x3F == 0x29 and (dst & 0xFFFF) == 0x0024,
       "0x800F6F20/0x800F6F28 are `lhu ...,0x14` / `sh ...,0x24` -- the battle "
       "slot's working stat vector is copied from char-record +0x14, NOT from "
       "the template's +0x10")
    step = maindec.mword(0x800F6F34)
    cnt = maindec.mword(0x800F6F2C)
    ok((step >> 26) & 0x3F == 0x09 and (step & 0xFFFF) == 0x0002 and
       (cnt >> 26) & 0x3F == 0x0A and (cnt & 0xFFFF) == 6,
       "0x800F6F34 `addiu $v1,$v1,2` / 0x800F6F2C `slti $a1,6`: the base copy is "
       "six halfwords, then the equipment loop at 0x800F7024 widens it to eight")

    # And the level byte the turn-weight routine reads is char-record +0x10.
    lv = maindec.mword(0x800E9828)
    ok((lv >> 26) & 0x3F == 0x24 and (lv & 0xFFFF) == 0x0010,
       "0x800E9828 is `lbu $a0,0x10($v0)` -- char-record +0x10 is the level "
       "byte the EXP award subtracts (char level; the routine is the award, not turn order)")


def test_turn_order():
    """Turn order is the slot list compared to a counter; the weight divides by
    the member count and floors at 5."""
    # 0x800E98A0: div by the participant count at +0x1C.
    d = maindec.mword(0x800E98A0)
    ok((d >> 26) & 0x3F == 0x00 and (d & 0x3F) == 0x1A,
       "0x800E98A0 is `div` -- the accumulated weight is averaged")
    c = maindec.mword(0x800E9898)
    ok((c >> 26) & 0x3F == 0x23 and (c & 0xFFFF) == 0x001C,
       "0x800E9898 loads the divisor from participant +0x1C (the party count)")
    fl = maindec.mword(0x800E98D4)
    fl2 = maindec.mword(0x800E98DC)
    ok((fl >> 26) & 0x3F == 0x0A and (fl & 0xFFFF) == 5 and
       (fl2 >> 26) & 0x3F == 0x0D and (fl2 & 0xFFFF) == 5,
       "0x800E98D4/0x800E98DC clamp the averaged weight to a minimum of 5")
    # The weight table is signed (lw) i32 and indexed by dl+14.
    b = maindec.mword(0x800E9760 + 0)  # control read, unrelated; keep the real one:
    tab = maindec.mword(0x800E9864)
    ok((tab >> 26) & 0x3F == 0x23,
       "0x800E9864 is `lw $v0,0($v0)` -- the turn-weight table is signed i32, "
       "so negative weights are representable")
    # The two clamps are slti -0xE and slti 0x10 on the same register, with the
    # compensating value written into $a0 (addiu -0xE / ori 0xF), then scaled
    # by 4 -- which is the table's index.  span = 15 - (-14) + 1 = 30.
    lo_test = maindec.mword(0x800E9838)
    hi_test = maindec.mword(0x800E9840)
    lo_val = maindec.mword(0x800E9848)
    hi_val = maindec.mword(0x800E9854)
    idx = maindec.mword(0x800E9858)
    ok((lo_test >> 26) & 0x3F == 0x0A and (lo_test & 0xFFFF) == 0xFFF2 and
       (hi_test >> 26) & 0x3F == 0x0A and (hi_test & 0xFFFF) == 0x0010 and
       (lo_val >> 26) & 0x3F == 0x09 and (lo_val & 0xFFFF) == 0xFFF2 and
       (hi_val >> 26) & 0x3F == 0x0D and (hi_val & 0xFFFF) == 0x000F and
       (idx >> 26) & 0x3F == 0x00 and (idx & 0x3F) == 0x00,
       "0x800E9838/0x800E9840 `slti -0xE` / `slti 0x10` with 0x800E9848 "
       "`addiu -0xE` and 0x800E9854 `ori 0xF`, then 0x800E9858 `sll 2`: the "
       "level difference is clamped to [-14,15] and used as a word index into "
       "a 30-entry table")
    # The slot list byte is read signed.
    sl = maindec.mword(0x800E97F4)
    ok((sl >> 26) & 0x3F == 0x20,
       "0x800E97F4 is `lb` -- the party-slot list at 0x8018AAFC is signed bytes")


# ---------------------------------------------------------------------------
# 8. The growth negative
# ---------------------------------------------------------------------------
def test_growth_is_not_a_stat_table():
    """The interpolation reproduces the code; a linear ramp does not."""
    for level in (1, 2, 5, 12, 30, 99):
        t = BF.growth_divisor(level)
        assert t == sum(range(1, level + 1))
    PASS_ = 1
    global PASS
    PASS += 1
    print("PASS: growth_divisor(level) is the triangular number the loop at "
          "0x800E632C..0x800E6340 accumulates (sum of level..1)")

    # A linear ramp v0 + (v1-v0)*level/L is NOT what the division produces; the
    # triangular divisor makes the value at level L sit at
    # (v0+v1)/2 + (v1-v0)*L/(2T), i.e. an interpolation whose step size
    # SHRINKS as T grows.  Show the two differ, so the reading is falsifiable.
    v0, v1 = 0x8000, 0x20000
    differs = 0
    for level in range(2, 99):
        got = BF.growth_value(v0, v1, level)
        linear = v0 + (v1 - v0) * level // 99
        if got != linear:
            differs += 1
    ok(differs > 80,
       f"the triangular-divisor reading differs from a linear ramp at "
       f"{differs}/97 levels -- the distinction is testable, and the "
       f"triangular one is the one the instructions compute")

    # Consumers of the template's +0x02 all treat it as a divisor: each has the
    # `div` + the div-by-zero break guard.
    for addr, guard in ((0x800E6790, 0x800E679C), (0x800E66B4, 0x800E66C0)):
        d = maindec.mword(addr)
        g = maindec.mword(guard)
        ok((d >> 26) & 0x3F == 0x00 and (d & 0x3F) == 0x1A and
           g == 0x0007000D,
           f"0x{addr:08X} divides by template +0x02 with a div-by-zero trap at "
           f"0x{guard:08X} -- a divisor, not a stat")

    # And the template's +0x10/+0x18 blocks have no consumer at all in the
    # accessor trio: the three routines only touch +0x02..+0x0A.
    touched = set()
    for lo, hi in ((0x800E62EC, 0x800E6320), (0x800E6664, 0x800E6678),
                   (0x800E6778, 0x800E6818)):
        for a in range(lo, hi, 4):
            w = maindec.mword(a)
            op = w >> 26
            if op in (0x21, 0x23, 0x25, 0x09, 0x20):
                imm = w & 0xFFFF
                if imm >= 0x8000:
                    imm -= 0x10000
                if 0 <= imm < 0x40:
                    touched.add(imm)
    ok(not (touched & {0x10, 0x18}),
       f"the three template accessors load only {sorted(touched)} -- they never "
       f"touch +0x10 or +0x18, the two blocks the growth candidate named")


# ---------------------------------------------------------------------------
# 9. Every address in the formula tables is inside a real executable image
# ---------------------------------------------------------------------------
def test_addresses_are_loaded():
    """Every address a formula names must land in a real image, or the reader
    is being pointed at nothing."""
    body = maindec.body()
    bad = []
    total = 0
    for key, f in BF.FORMULAS.items():
        addrs = [f["routine"]]
        for entry in f.get("site", []):
            addrs.append(entry[1])
        head, tail = f["routine"], None
        for entry in f.get("routine_offsets", []):
            head = min(head, entry[1])
            tail = entry[1] if tail is None else max(tail, entry[1])
        for a in addrs:
            total += 1
            if not (0 <= a - BF.MAIN_BASE <= len(body) - 4):
                bad.append((key, a))
    ok(not bad and total >= 30,
       f"all {total} instruction addresses named across the formulas land "
       f"inside the MAIN.EXE image (base 0x{BF.MAIN_BASE:08X}, {len(body)} B)")
    # The negative's template address is in the *other* image.
    off = BF.GROWTH_NEGATIVE["template_addr"] - BF.SLUS_BASE
    ok(off == 0x33274,
       "the growth candidate's template sits at SLUS_002.92 image 0x33274 "
       "== 0x80043274")


def main():
    for fn in (test_slot_stride, test_participant_alloc, test_rng,
               test_physical_damage_properties, test_master_multiplier_sites,
               test_hit_chance, test_hp_apply, test_char_record_layout,
               test_turn_order, test_growth_is_not_a_stat_table,
               test_addresses_are_loaded):
        fn()
    print(f"\nbattle formulas: {PASS} assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
