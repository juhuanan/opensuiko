#!/usr/bin/env python3
"""The per-battle EXP *award* for Suikoden (PS1, SLUS_002.92 v1.1) -- derived.

This is the last underived battle rule.  The *consumers* were already proven
(`kit/docs/growth_rules.md` sections 3 and 6): the victory sequence reads a
per-participant pool at ``battle_context + 0x10 + 4*idx`` and adds it to the
persistent character record's EXP halfword ``+0x0E``, levelling up at a flat
1000 per level.  What was missing was the **writer** of that pool.  It is

    0x800E9744   award_battle_exp()          (MAIN.EXE, called once per battle
                                             from 0x800E8244, in the battle-result
                                             handler registered at 0x800DE178)

and the value it writes for participant ``i`` is::

    if actorB[i].0x45 != 0:      award = 0            # out of action
    else:
        s = sum over enemy slots j of
                XP[clamp(enemy_level(e_j) - char_level(i), -14, 15)]
        award = s / party_count                       # MIPS signed div, trunc
        if award < 5: award = 5
        if char_record(i).0x4C == 0x16: award *= 2

``XP`` is the 30-word table at **0x8016BDC8** (index ``dl`` at
``0x8016BDC8 + 4*dl``, so the table body spans 0x8016BD90..0x8016BE07 and the
HP growth table starts at exactly 0x8016BE08).  Its entries are
1, 2, 3, 5, 7, 10, 15, 20, 30, 50, 70, 90, 120, 160, 200, 400, 900, 1600,
2600, 3900, 5100, 6000, 6900, 7500, 8000, 8500, 9000, 9300, 9700, 10000.

The result is stored in the battle context (the 0x2258-byte block at
``*(0x80179FD0)``) at ``+0x10 + 4*i``, which is exactly what the victory
sequence reads back.

WHY THE PREVIOUS PASS MISSED IT
-------------------------------
The writer *was* found before and mis-read.  It writes through a base of
``B + 4*i`` with an immediate ``0x10`` (``0x800E9908``/``0x800E98D0`` use
``$a3 = $t8 + 4`` and ``0x10($a3)``), so an immediate-offset search for
``0x14``/``0x18`` or for ``addiu rX, <B-alias>, 0x10`` cannot see it, and the
corpus recorded the store as "the turn-order weight at ``B+0x14``" -- which is
the **index-1 slot of the same pool array** (``B + 0x10 + 4*1``).  The table it
reads was recorded as "the turn-order weight table 0x8016BDC8" whose entries
were tabulated from the wrong end (dl=-14 read as 200 instead of 1), which is
why its tail looked non-monotone: the tail *was* the HP growth table.

Record byte ``+0x4C`` stores the equipped rune. Table entry ``0x16`` is the
Fortune Rune, which doubles the award after the floor.

Provenance: MAIN.EXE (PS-X EXE, ``t_addr`` 0x800C0800, image 755,712 B) read
through ``tools/disc.py`` -> ``tools/maindec.py``.  Static only: no emulator,
no save state, no capture.

Usage::

    .venv/bin/python kit/tools/exp_award.py --json
    .venv/bin/python kit/tools/exp_award.py --table
    .venv/bin/python kit/tools/exp_award.py --award --level 5 --enemies 6,6,7
    .venv/bin/python kit/tools/exp_award.py --audit
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
MAIN_END = MAIN_BASE + 755712

# ---------------------------------------------------------------------------
# 1. the rule, every term with the instruction that fixes it
# ---------------------------------------------------------------------------
#: the battle-context pointer: ``lui $at,0x8018`` + ``sw $v0,-0x6030($at)``
#: at 0x800E81B8 in the block allocator; ``malloc(0x2258)``.
BLOCK_PTR = 0x80179FD0
BLOCK_ALLOC = (0x800E81A8, 0x800E81AC, 0x800E81B8)

#: the routine that writes the pool, and its single call site.
AWARD_FN = 0x800E9744
AWARD_FN_END = 0x800E993C          # exclusive: after the `jr $ra` delay slot
AWARD_CALL = 0x800E8244            # `jal 0x800E9744` in the battle-result handler
AWARD_CALL_SITE = 0x800DE178       # who registers that handler

#: the pool slot for participant i: ``sw ...,0x10($a3)`` with ``$a3 = B + 4*i``.
#: i runs 1..party_count and party_count <= 6, so the pool is the six words
#: B+0x14..B+0x28 and B+0x2C is the participant *index*, not a slot.
POOL_BASE_OFF = 0x10
POOL_STRIDE = 4
POOL_MAX_PARTY = 6
POOL_SLOT_LO = POOL_BASE_OFF + POOL_STRIDE          # 0x14
POOL_SLOT_HI = POOL_BASE_OFF + POOL_STRIDE * POOL_MAX_PARTY   # 0x28
POOL_SLOT_WRITE = 0x800E9870       # `sw $v1,0x10($t1)`
POOL_SLOT_ZERO = 0x800E97B4        # `sw $zero,0x10($a3)`
POOL_READ = 0x800E89C8             # `lw $v0,0x10($v0)`, `$v0 = B + 4*idx`
POOL_INDEX_FIELD = 0x2C            # B+0x2C, starts at 1 (0x800E88F0)
POOL_INDEX_START = 0x800E88F0      # `sw $a1,0x2c($v1)`, `$a1` = the state value 1
POOL_INDEX_INC = 0x800E8C34        # `sw $v1,0x2c($a0)`

#: the XP table: ``lui $s1,0x8017`` / ``addiu $s1,$s1,-0x4238``
XP_TABLE = 0x8016BDC8
XP_TABLE_SITE = (0x800E9764, 0x800E9768)
XP_TABLE_READ = 0x800E9864         # `lw $v0,0x0($v0)` after the clamp
XP_INDEX_MIN = -14
XP_INDEX_MAX = 15
XP_ENTRIES = XP_INDEX_MAX - XP_INDEX_MIN + 1        # 30
#: the table body in address order (dl = -14 .. +15)
XP_TABLE_LO = XP_TABLE + 4 * XP_INDEX_MIN           # 0x8016BD90
XP_TABLE_HI = XP_TABLE + 4 * XP_INDEX_MAX + 4       # 0x8016BE08 == HP growth

#: the level-difference clamp: `slti $a0,-0xe` / `slti $v0,0x10`
DIFF_CLAMP_SITES = (0x800E9838, 0x800E9848, 0x800E9840, 0x800E9854)

#: the per-enemy "present" flag array (runtime BSS): ``addiu $s2,$s2,-0x5504``
#: on ``lui $s2,0x8018``; word ``1+j`` gates enemy slot ``j``.
PRESENT_FLAG_BASE = 0x8017AAF8
PRESENT_FLAG_LUI = 0x800E9774
PRESENT_FLAG_ADD = 0x800E9778
PRESENT_FLAG_READ = 0x800E9804     # `lw $v0,0x0($t0)` / `bne $v0,1`
PRESENT_FLAG_REQUIRED = 1
PRESENT_FLAG_WRITERS = (0x800E2E74, 0x801143C4, 0x80116124)

#: enemy selection: id byte at array A[party_count+1+j] + 0x00
PARTY_COUNT_OFF = 0x1C             # G+0x1C (0x800E9898 `lw $v1,0x1c($t2)`)
ENEMY_COUNT_OFF = 0x20             # G+0x20 (0x800E97B8 `lw $v0,0x20($t2)`)
UNIT_COUNT_OFF = 0x24              # G+0x24 (party + enemies)
ACTOR_A_BASE = 0x50                # G+0x50, stride 140 (0x8C)
ACTOR_A_STRIDE = 140
ACTOR_B_BASE = 0xB40               # G+0xB40, stride 84 (0x54)
ACTOR_B_STRIDE = 84
ACTOR_B_FLAG_OFF = 0x45            # spawn writes 0: 0x800DEDA4 `sb $zero,0x45($s2)`
ACTOR_B_FLAG_READ = 0x800E979C     # `lbu $v0,0x45($t5)` / `beq $v0,$zero`
PARTY_SLOT_BASE = 0xF84            # G+0xF84, stride 12: `lw $t3,0x0($t4)`
PARTY_SLOT_STRIDE = 12
ENEMY_TABLE_OFF = 0x1344           # G+0x1344 -> per-area enemy record pointers
ENEMY_LEVEL_OFF = 0x10             # enemy record +0x10 (enemy_sprites.py)
CHAR_LEVEL_OFF = 0x0D              # record +0x0D (growth_rules.md section 1)
CHAR_CLASS_OFF = 0x4C              # record +0x4C (`lbu $v1,0x4c($v0)`)

#: the post-division floor and the doubling class
MIN_AWARD = 5
MIN_AWARD_SITES = (0x800E98D4, 0x800E98DC, 0x800E98E0)
DOUBLE_CLASS = 0x16
DOUBLE_SITES = (0x800E98EC, 0x800E98F0, 0x800E98F4, 0x800E9904, 0x800E9908)

#: the consumer, so the port can see both ends
CONSUMER_SITES = {
    "record_exp_write": 0x800E8A88,     # `sh $v0,0xe($a1)`
    "record_exp_clear": 0x800E8A18,     # `sh $zero,0xe($v0)`
    "level_threshold": 0x800E89D4,      # `slti $v1,$v1,0x3e8`
    "level_up_call": 0x800E8A20,        # `jal 0x800E9CC4`
}


def sx16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v >= 0x80000000 else v


def mword(va: int):
    return maindec.mword(va)


# ---------------------------------------------------------------------------
# 2. the XP table (disc bytes)
# ---------------------------------------------------------------------------
def xp_table() -> list[int]:
    """The 30 XP values in dl order (-14 .. +15), read from the image.

    The entry for a level difference ``dl`` is the signed (here: plain
    positive) word at ``0x8016BDC8 + 4*dl``, i.e. index 0 of this list is the
    word at 0x8016BD90 and index 29 is the word at 0x8016BE04.
    """
    return [mword(XP_TABLE + 4 * dl) for dl in range(XP_INDEX_MIN, XP_INDEX_MAX + 1)]


def diff_index(enemy_level: int, char_level: int) -> int:
    """``clamp(enemy_level - char_level, -14, 15)`` -- the two ``slti`` sites."""
    d = enemy_level - char_level
    if d < XP_INDEX_MIN:
        return XP_INDEX_MIN
    if d > XP_INDEX_MAX:
        return XP_INDEX_MAX
    return d


def xp_for_diff(dl: int) -> int:
    if not (XP_INDEX_MIN <= dl <= XP_INDEX_MAX):
        raise ValueError("dl outside the proven clamp [-14, 15]")
    return xp_table()[dl - XP_INDEX_MIN]


# ---------------------------------------------------------------------------
# 3. the plain-Python rule (what the port uses)
# ---------------------------------------------------------------------------
def enemy_exp_sum(enemy_levels, char_level: int) -> int:
    """Sum of XP[clamp(enemy_level - char_level)] over the encounter's enemies."""
    return sum(xp_for_diff(diff_index(el, char_level)) for el in enemy_levels)


def pool_entry(char_level: int, char_class: int, enemy_levels, party_count: int,
               out_of_action: bool = False) -> int:
    """The award for ONE participant, exactly as 0x800E9744 computes it.

    ``out_of_action`` is the ``actorB[i].0x45 != 0`` branch of 0x800E97A4: the
    slot is zeroed and the participant receives nothing.

    The division is the MIPS ``div`` at 0x800E98A0 (truncation toward zero);
    the sum is non-negative here, so it is a floor.  ``party_count`` >= 1.
    """
    if party_count < 1:
        raise ValueError("party_count must be >= 1 (the div at 0x800E98A0)")
    if out_of_action:
        return 0
    s = enemy_exp_sum(enemy_levels, char_level)
    v = abs(s) // party_count if s >= 0 else -((-s) // party_count)
    if v < MIN_AWARD:
        v = MIN_AWARD
    if char_class == DOUBLE_CLASS:
        v *= 2
    return v


def award_pool(char_levels, char_classes, enemy_levels,
               out_of_action=None) -> list[int]:
    """The whole pool, indices ``1..party_count`` (index 0 is unused).

    ``char_levels``/``char_classes`` are the party in battle order (slot i is
    ``G + 0xF84 + 12*i``); ``enemy_levels`` is the encounter's enemy levels in
    the order the enemy actors occupy array A (slots party_count+1, +2, ...).
    The returned list has ``len(char_levels)+1`` entries.
    """
    n = len(char_levels)
    if out_of_action is None:
        out_of_action = [False] * n
    out = [0]
    for i in range(n):
        out.append(pool_entry(char_levels[i], char_classes[i], enemy_levels,
                              n, bool(out_of_action[i])))
    return out


# ---------------------------------------------------------------------------
# 4. the re-execution harness: run the real instruction words
# ---------------------------------------------------------------------------
class _Mem:
    """Byte-addressed memory; unset bytes read 0 (the image is preloaded)."""

    def __init__(self):
        self.b = {}

    def rb(self, a):
        return self.b.get(a & 0xFFFFFFFF, 0)

    def sb(self, a, v):
        self.b[a & 0xFFFFFFFF] = v & 0xFF

    def rh(self, a):
        a &= 0xFFFFFFFF
        return self.rb(a) | (self.rb(a + 1) << 8)

    def sh(self, a, v):
        self.sb(a, v)
        self.sb(a + 1, v >> 8)

    def rw(self, a):
        a &= 0xFFFFFFFF
        return (self.rb(a) | (self.rb(a + 1) << 8) |
                (self.rb(a + 2) << 16) | (self.rb(a + 3) << 24))

    def sw(self, a, v):
        v &= 0xFFFFFFFF
        for k in range(4):
            self.sb(a + k, v >> (8 * k))


_REGN = ["zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
         "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
         "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
         "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra"]

# synthetic layout: the three globals the routine dereferences, then the
# participant state, the character/enemy records and the present flags.
G_ADDR = 0x80210000
B_ADDR = 0x80220000
CHAR_REC_BASE = 0x80230000
CHAR_PTR_BASE = 0x80240000
ENEMY_ARR = 0x80250000
ENEMY_REC_BASE = 0x80260000
STACK = 0x801FFF00


def exec_award_pool(char_levels, char_classes, enemy_levels,
                    out_of_action=None, present=None,
                    enemy_ids=None) -> list[int]:
    """Execute 0x800E9744..0x800E993C against a synthetic battle and return the pool.

    This is the *second* implementation: the first is the hand transcription in
    :func:`pool_entry`.  Every instruction word comes from the disc through
    ``maindec.mword``; only the data it operates on is synthetic.  The EXP table
    words are loaded from the image, so the arithmetic uses the real table.

    ``enemy_ids`` defaults to 1..len(enemy_levels); ``present`` defaults to all
    ones.  The routine iterates enemy slots ``j = 0 .. G[0x20]`` inclusive,
    where ``G[0x20]`` is the encounter's non-zero roster count, so the array A
    slot for ``j`` is ``party_count + 1 + j``; slots past the last enemy are
    left with id 0 (a fresh game state) and are skipped.
    """
    n = len(char_levels)
    if out_of_action is None:
        out_of_action = [False] * n
    if enemy_ids is None:
        enemy_ids = list(range(1, len(enemy_levels) + 1))
    if present is None:
        present = [1] * len(enemy_levels)

    mem = _Mem()
    mem.sw(0x8017BE3C, G_ADDR)          # G = *(0x8017BE3C)
    mem.sw(BLOCK_PTR, B_ADDR)           # B = *(0x80179FD0)
    mem.sw(G_ADDR + PARTY_COUNT_OFF, n)
    mem.sw(G_ADDR + ENEMY_COUNT_OFF, len(enemy_levels))
    mem.sw(G_ADDR + UNIT_COUNT_OFF, n + len(enemy_levels))
    mem.sw(G_ADDR + ENEMY_TABLE_OFF, ENEMY_ARR)
    # the XP table: the real disc words
    for k, v in enumerate(xp_table()):
        mem.sw(XP_TABLE_LO + 4 * k, v)
    # runner code and data beyond the image: the routine only touches the
    # addresses above, so nothing else needs backing.
    for j, lvl in enumerate(enemy_levels):
        rec = ENEMY_REC_BASE + 0x100 * j
        mem.sb(rec + ENEMY_LEVEL_OFF, lvl)
        mem.sw(ENEMY_ARR + 4 * enemy_ids[j], rec)
    # array A slot for enemy j = party_count + 1 + j: byte 0 = the enemy id
    for j, eid in enumerate(enemy_ids):
        slot = G_ADDR + ACTOR_A_BASE + ACTOR_A_STRIDE * (n + 1 + j)
        mem.sb(slot, eid)
    # present flags: word (1+j) of the array at 0x8017AAF8
    for j, p in enumerate(present):
        mem.sw(PRESENT_FLAG_BASE + 4 * (1 + j), p)
    for i in range(1, n + 1):
        rec = CHAR_REC_BASE + 0x20 * i
        cptr = CHAR_PTR_BASE + 0x20 * i
        mem.sb(rec + CHAR_LEVEL_OFF, char_levels[i - 1])
        mem.sb(rec + CHAR_CLASS_OFF, char_classes[i - 1])
        # the proven chain: G+0xF84+12*i -> char struct, char struct+0x1C -> record
        mem.sw(G_ADDR + PARTY_SLOT_BASE + PARTY_SLOT_STRIDE * i, cptr)
        mem.sw(cptr + 0x1C, rec)
        mem.sb(G_ADDR + ACTOR_B_BASE + ACTOR_B_STRIDE * i + ACTOR_B_FLAG_OFF,
               1 if out_of_action[i - 1] else 0)

    r = dict.fromkeys(_REGN, 0)
    r["sp"] = STACK
    r["ra"] = 0

    def rdv(i):
        return r[_REGN[i]]

    def wrv(i, v):
        if i:
            r[_REGN[i]] = v & 0xFFFFFFFF

    def exec_one(pc, w):
        """Execute one non-branch word; return True if it was `jr $ra`."""
        op = w >> 26
        rs, rt, rd = (w >> 21) & 0x1F, (w >> 16) & 0x1F, (w >> 11) & 0x1F
        sh = (w >> 6) & 0x1F
        if op == 0:
            fn = w & 0x3F
            if fn == 0x00:                                  # sll
                wrv(rd, rdv(rt) << sh)
            elif fn == 0x21:                                # addu
                wrv(rd, rdv(rs) + rdv(rt))
            elif fn == 0x23:                                # subu
                wrv(rd, rdv(rs) - rdv(rt))
            elif fn == 0x2A:                                # slt (signed)
                wrv(rd, 1 if s32(rdv(rs)) < s32(rdv(rt)) else 0)
            elif fn == 0x1A:                                # div
                a, b = s32(rdv(rs)), s32(rdv(rt))
                if b == 0:
                    raise AssertionError("divide by zero at 0x%08X" % pc)
                q = abs(a) // abs(b)
                if (a < 0) != (b < 0):
                    q = -q
                r["_lo"], r["_hi"] = q & 0xFFFFFFFF, (a - q * b) & 0xFFFFFFFF
            elif fn == 0x12:                                # mflo
                wrv(rd, r.get("_lo", 0))
            elif fn == 0x08:                                # jr $ra
                return True
            elif fn in (0x0D, 0x30):                        # break: the div guards
                raise AssertionError("break at 0x%08X (%#x)" % (pc, fn))
            else:
                raise AssertionError("unhandled SPECIAL fn=%#x at 0x%08X" % (fn, pc))
        elif op == 0x0F:                                    # lui
            wrv(rt, (w & 0xFFFF) << 16)
        elif op == 0x09:                                    # addiu
            wrv(rt, rdv(rs) + sx16(w))
        elif op == 0x0D:                                    # ori
            wrv(rt, rdv(rs) | (w & 0xFFFF))
        elif op == 0x0A:                                    # slti
            wrv(rt, 1 if s32(rdv(rs)) < sx16(w) else 0)
        elif op == 0x23:                                    # lw
            wrv(rt, mem.rw(rdv(rs) + sx16(w)))
        elif op == 0x20:                                    # lb
            v = mem.rb(rdv(rs) + sx16(w))
            wrv(rt, v - 0x100 if v & 0x80 else v)
        elif op == 0x24:                                    # lbu
            wrv(rt, mem.rb(rdv(rs) + sx16(w)))
        elif op == 0x2B:                                    # sw
            mem.sw(rdv(rs) + sx16(w), rdv(rt))
        else:
            raise AssertionError("unhandled op=%#x at 0x%08X" % (op, pc))
        return False

    pc = AWARD_FN
    steps = 0
    while pc < AWARD_FN_END:
        steps += 1
        if steps > 20000:
            raise AssertionError("the award routine ran away")
        w = mword(pc)
        if w is None:
            raise AssertionError("no instruction word at 0x%08X" % pc)
        op = w >> 26
        rs, rt = (w >> 21) & 0x1F, (w >> 16) & 0x1F
        if op in (0x04, 0x05, 0x01, 0x06, 0x02):
            # branch / jump: the *delay slot* executes in both directions
            if op == 0x02:
                nxt = ((pc + 4) & 0xF0000000) | ((w & 0x03FFFFFF) << 2)
            else:
                if op == 0x04:
                    take = rdv(rs) == rdv(rt)
                elif op == 0x05:
                    take = rdv(rs) != rdv(rt)
                elif op == 0x01:
                    take = s32(rdv(rs)) < 0
                else:                                       # blez
                    take = s32(rdv(rs)) <= 0
                nxt = (pc + 4 + (sx16(w) << 2)) if take else pc + 8
            done = exec_one(pc + 4, mword(pc + 4))
            if done:
                break
            pc = nxt
        else:
            if exec_one(pc, w):
                break
            pc += 4

    return [s32(mem.rw(B_ADDR + POOL_BASE_OFF + POOL_STRIDE * i))
            for i in range(n + 1)]


# ---------------------------------------------------------------------------
# 5. the audit: where the pool is written, image-wide
# ---------------------------------------------------------------------------
def block_loads() -> list[int]:
    """Every `lui/addiu-or-lui` + `lw` pair that loads *(0x80179FD0)."""
    out = []
    for va in range(MAIN_BASE, MAIN_END - 8, 4):
        i0 = mword(va)
        if i0 is None or (i0 >> 26) != 0x0F or (i0 & 0xFFFF) != 0x8018:
            continue
        rt = (i0 >> 16) & 0x1F
        i1 = mword(va + 4)
        if i1 is None or (i1 >> 26) != 0x23 or ((i1 >> 21) & 0x1F) != rt:
            continue
        if sx16(i1) == -0x6030:
            out.append(va + 4)
    return out


def address_xrefs(target: int) -> list[int]:
    """Sites that build ``target`` from a ``lui`` + ``addiu``/``ori`` pair.

    The address is formed from the full encoding: ``hi = imm << 16`` then the
    sign-extended low half, so a ``lui 0x8018`` with a negative immediate lands
    at 0x8017xxxx (AGENTS.md section 5).
    """
    out = []
    for va in range(MAIN_BASE, MAIN_END - 12, 4):
        i0 = mword(va)
        if i0 is None or (i0 >> 26) != 0x0F:
            continue
        hi = (i0 & 0xFFFF) << 16
        rt = (i0 >> 16) & 0x1F
        for k in (1, 2):
            ik = mword(va + 4 * k)
            if ik is None or ((ik >> 21) & 0x1F) != rt:
                continue
            op = ik >> 26
            if op in (0x09, 0x0D):
                if ((hi + sx16(ik)) & 0xFFFFFFFF) == target:
                    out.append(va)
                    break
    return out


def pool_writers() -> list[dict]:
    """Every non-stack store in the battle band whose immediate targets the pool.

    The band is the span of the code that loads *(0x80179FD0).  Restricting to
    it is what makes the enumeration finite; the argument that no *other*
    function can write the pool is that no `jal` in the band passes a
    ``B``-derived pointer except ``B+0x2238`` (0x800E957C, the status text
    formatter) -- see the doc.

    Two shapes reach a slot and both must be scanned: a base of ``B + 4*i`` with
    immediate ``0x10`` (what 0x800E9744 emits) and a base of ``B`` with
    immediate ``0x14..0x28`` (what the victory drain emits).  The immediates
    scanned are therefore 0x10, 0x14 .. 0x28 (participants 1..6); B+0x2C is the
    participant index field and is deliberately not in this set.
    """
    loads = block_loads()
    lo, hi = min(loads) - 0x100, max(loads) + 0x100
    offs = {POOL_BASE_OFF} | set(range(POOL_SLOT_LO, POOL_SLOT_HI + 1, POOL_STRIDE))
    out = []
    for va in range(lo, hi, 4):
        w = mword(va)
        if w is None or (w >> 26) not in (0x28, 0x29, 0x2A, 0x2B):
            continue
        rs = (w >> 21) & 0x1F
        off = sx16(w)
        if rs in (29, 30):                      # sp / fp: frame, not the block
            continue
        if off in offs:
            out.append({"site": va, "op": w >> 26, "base": _REGN[rs],
                        "value": _REGN[(w >> 16) & 0x1F], "off": off})
    return out


POOL_TOUCH_WHITELIST = {
    # out-of-action branch + normal path (slot = 0)
    0x800E97B0, 0x800E97B4,
    # the accumulator, the post-division store, the floor, the doubling
    0x800E9870, 0x800E98D0, 0x800E98E0, 0x800E9908,
    # the victory sequence's own reads/writes (the consumer)
    0x800E8A0C, 0x800E8A9C, 0x800E8B78, 0x800E8BA0, 0x800E8BEC,
}

#: The stores the scan above finds at a pool immediate whose base is *not* the
#: battle context.  Each one is accounted for by its base register, so the
#: whitelist is exhaustive for the block.
NON_POOL_STORES = {
    0x800E87EC: "base $s0 = B + 0x8C*idx + <const> inside the 0x800E86F4 loop "
                "is a GPU primitive (fields +0x03..+0x12), not the pool",
    0x800E9100: "base $a0 = *(0x8017DB24) -- the game-state gold word S+0x1C "
                "(+ potch, clamped to 0xF423F)",
    0x800E9110: "same S+0x1C clamp",
}
#: B+0x2C (immediate 0x2C, i.e. outside the scanned set) is the participant
#: index: written at 0x800E88F0, 0x800E8AA0, 0x800E8B58 and 0x800E8C34 and read
#: at 0x800E8954/0x800E89B4/0x800E8ABC/0x800E8D0C.  It is the field the victory
#: loop walks, and it sits immediately after the six pool slots.

BAND_CALL_WHITELIST = {
    # (site, target, why)
    0x800E957C: (0x800D4EC0, "jal text_formatter; its delay slot 0x800E9580 passes "
                             "a1 = B+0x2238, the status text buffer"),
}


# ---------------------------------------------------------------------------
# 6. serialisation
# ---------------------------------------------------------------------------
def as_json() -> dict:
    loads = block_loads()
    return {
        "rule": "per-battle EXP award",
        "source": "MAIN.EXE 0x800E9744 (called once from 0x800E8244)",
        "image_base": hex(MAIN_BASE),
        "formula": ("out_of_action: 0 ; else award = "
                    "max(5, sum_j XP[clamp(enemy_level(j) - char_level, -14, 15)] "
                    "/ party_count) ; award *= 2 if record[0x4C] == 0x16"),
        "terms": {
            "award_fn": hex(AWARD_FN),
            "award_fn_call": hex(AWARD_CALL),
            "handler_registration": hex(AWARD_CALL_SITE),
            "block_ptr": hex(BLOCK_PTR),
            "block_alloc": [hex(a) for a in BLOCK_ALLOC],
            "pool_slot": {"base_off": POOL_BASE_OFF, "stride": POOL_STRIDE,
                          "write": hex(POOL_SLOT_WRITE),
                          "zero": hex(POOL_SLOT_ZERO),
                          "read_by_consumer": hex(POOL_READ),
                          "index_field": POOL_INDEX_FIELD,
                          "index_start": hex(POOL_INDEX_START),
                          "index_increment": hex(POOL_INDEX_INC)},
            "xp_table": {"base": hex(XP_TABLE),
                         "site": [hex(a) for a in XP_TABLE_SITE],
                         "read": hex(XP_TABLE_READ),
                         "dl_range": [XP_INDEX_MIN, XP_INDEX_MAX],
                         "span": [hex(XP_TABLE_LO), hex(XP_TABLE_HI)],
                         "entries": xp_table()},
            "diff_clamp": [hex(a) for a in DIFF_CLAMP_SITES],
            "present_flags": {"base": hex(PRESENT_FLAG_BASE),
                              "build": [hex(PRESENT_FLAG_LUI), hex(PRESENT_FLAG_ADD)],
                              "read": hex(PRESENT_FLAG_READ),
                              "required": PRESENT_FLAG_REQUIRED,
                              "writers": [hex(a) for a in PRESENT_FLAG_WRITERS]},
            "enemy_selection": {"party_count_off": PARTY_COUNT_OFF,
                                "enemy_count_off": ENEMY_COUNT_OFF,
                                "unit_count_off": UNIT_COUNT_OFF,
                                "actor_a_base": ACTOR_A_BASE,
                                "actor_a_stride": ACTOR_A_STRIDE,
                                "enemy_table_off": ENEMY_TABLE_OFF,
                                "enemy_level_off": ENEMY_LEVEL_OFF},
            "out_of_action_flag": {"actor_b_base": ACTOR_B_BASE,
                                   "actor_b_stride": ACTOR_B_STRIDE,
                                   "off": ACTOR_B_FLAG_OFF,
                                   "read": hex(ACTOR_B_FLAG_READ),
                                   "spawn_zeroes_it": 0x800DEDA4},
            "min_award": {"value": MIN_AWARD, "sites": [hex(a) for a in MIN_AWARD_SITES]},
            "doubling": {"class": DOUBLE_CLASS, "rune_name": "Fortune Rune", "sites": [hex(a) for a in DOUBLE_SITES]},
            "char_record": {"level_off": CHAR_LEVEL_OFF, "class_off": CHAR_CLASS_OFF},
            "consumer": {k: hex(v) for k, v in CONSUMER_SITES.items()},
        },
        "audit": {
            "block_loads_in": [hex(min(loads)), hex(max(loads))],
            "block_load_count": len(loads),
            "pool_writers": [{"site": hex(p["site"]), "base": p["base"],
                              "value": p["value"], "off": hex(p["off"])}
                             for p in pool_writers()],
            "xp_table_xrefs": [hex(a) for a in address_xrefs(XP_TABLE)],
        },
        "open": [
            "campaign reachability of an award with zero eligible enemies",
        ],
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="the rule as data")
    ap.add_argument("--table", action="store_true", help="the XP table")
    ap.add_argument("--award", action="store_true", help="one award")
    ap.add_argument("--audit", action="store_true", help="the image-wide scan")
    ap.add_argument("--level", type=int, default=1, help="character level")
    ap.add_argument("--class", dest="cls", type=lambda s: int(s, 0), default=0,
                    help="equipped rune byte (0x4C); 0x16 is Fortune")
    ap.add_argument("--enemies", default="", help="comma-separated enemy levels")
    ap.add_argument("--party", type=int, default=1, help="party count")
    args = ap.parse_args(argv)

    if args.json:
        print(json.dumps(as_json(), indent=1))
        return 0
    if args.table:
        for dl in range(XP_INDEX_MIN, XP_INDEX_MAX + 1):
            print("dl=%+3d  %#010x  %6d" % (dl, XP_TABLE + 4 * dl, xp_for_diff(dl)))
        return 0
    if args.audit:
        loads = block_loads()
        print("block loads of *(0x%08X): %d sites, 0x%08X..0x%08X"
              % (BLOCK_PTR, len(loads), min(loads), max(loads)))
        print("stores at pool-slot offsets B+0x14..B+0x28 with a non-stack base:")
        for p in pool_writers():
            mark = "whitelist" if p["site"] in POOL_TOUCH_WHITELIST else "UNKNOWN"
            print("  %08x  %s,%#x(%s)  [%s]"
                  % (p["site"], p["value"], p["off"], p["base"], mark))
        print("address xrefs to the XP table 0x%08X: %s"
              % (XP_TABLE, [hex(a) for a in address_xrefs(XP_TABLE)]))
        return 0
    if args.award:
        lv = [int(x) for x in args.enemies.split(",") if x.strip()]
        for i in range(1, args.party + 1):
            print("slot %d: %d" % (i, pool_entry(args.level, args.cls, lv, args.party)))
        return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
