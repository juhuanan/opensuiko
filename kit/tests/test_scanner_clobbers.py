#!/usr/bin/env python3
"""Counterexample tests for the four scanner issue classes in
`kit/docs/asset_pipeline_consolidation_plan.md` §1:

  1. load clobbers        (a load destination staying tracked with its old offset)
  2. operations mistaken as copies
  3. cross-register arithmetic
  4. pointer invalidation

Synthetic instruction windows only -- **no disc required**. Both scanners accept
an injected `reader(va) -> word or None`, mirroring
`mips_writers.writer_of(..., reader=)`; these tests drive them directly through
that hook. Every test here is the case the *pre-fix* code got WRONG, asserted to
now produce the honest answer, so reverting a fix makes it fail.

The pre-fix behaviour each test pins is recorded in
`kit/docs/scanner_pointer_invalidation.md`; the old side was
independently reproduced against the pinned revision by
`kit/tools/verify_old_scanners.py`.

Run:  .venv/bin/python kit/tests/test_scanner_clobbers.py
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import gs_scan  # noqa: E402
import scan_structptr  # noqa: E402

# --- encoder helpers (MIPS I) -------------------------------------------------
# Register numbers. gs_scan's tracked seeds use $s0=16 in the review's example.
ZERO, AT, V0, V1, A0, A1, A2, A3 = 0, 1, 2, 3, 4, 5, 6, 7
T0, T1, T2, GP, RA = 8, 9, 10, 28, 31
S0, S1 = 16, 17


def I(op, rs, rt, imm):
    return (op << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)


def R(op, rs, rt, rd, fn):
    return (op << 26) | (rs << 21) | (rt << 16) | (rd << 11) | fn


def lui(rt, imm):        return I(0x0F, 0, rt, imm)
def addiu(rt, rs, imm):  return I(0x09, rs, rt, imm)
def addi(rt, rs, imm):   return I(0x08, rs, rt, imm)
def ori(rt, rs, imm):    return I(0x0D, rs, rt, imm)
def lw(rt, rs, off):     return I(0x23, rs, rt, off)
def lb(rt, rs, off):     return I(0x20, rs, rt, off)
def lh(rt, rs, off):     return I(0x21, rs, rt, off)
def lbu(rt, rs, off):    return I(0x24, rs, rt, off)
def sw(rt, rs, off):     return I(0x2B, rs, rt, off)
def sb(rt, rs, off):     return I(0x28, rs, rt, off)
def addu(rd, rs, rt):    return R(0, rs, rt, rd, 0x21)
def or_(rd, rs, rt):     return R(0, rs, rt, rd, 0x25)
def jal(tgt):            return I(0x03, 0, 0, 0) | ((tgt >> 2) & 0x03FFFFFF)
def jr(rs):              return R(0, rs, 0, 0, 0x08)
NOP = 0

# The h2da seed idiom gs_scan's P2 sweep looks for.
H2DA_OFF = 0xDB24          # -0x24DC as a 16-bit immediate


class GsWindow:
    """A synthetic code image for gs_scan: reader(va) -> word or None.

    gs_scan's P2 sweep only runs while `i < n - 610`, and it needs a
    `lw $rt,-0x24DC($gp)` seed, so the window is padded to 700 words with the
    code placed early. (Reproduction pitfall: a short fixture silently yields
    zero records and makes the scanner look innocent.)
    """

    def __init__(self, code, at=10, pad=700):
        words = [0] * max(pad, at + len(code) + 8)
        for k, w in enumerate(code):
            words[at + k] = w
        self.mem = {gs_scan.MBASE + k * 4: w for k, w in enumerate(words)}
        self.at = at
        self.code = code

    def reader(self, va):
        return self.mem.get(va)

    def run(self):
        return gs_scan.scan(reader=self.reader)

    def descs(self):
        return [r[6] for r in self.run()]


class StructWindow:
    """A synthetic code image for scan_structptr: reader(va) -> word or None."""

    def __init__(self, code, at=0x100):
        self.base = scan_structptr.BASE
        words = [0] * (at + len(code) + 8)
        for k, w in enumerate(code):
            words[at + k] = w
        self.mem = {self.base + k * 4: w for k, w in enumerate(words)}
        self.end = self.base + len(words) * 4
        self.at = at

    def reader(self, va):
        return self.mem.get(va)

    def va(self, k):
        """VA of the k-th instruction of `code` (0-based)."""
        return self.base + (self.at + k) * 4

    def run(self):
        return scan_structptr.scan(reader=self.reader, end_va=self.end, quiet=True)


# =============================================================================
# Class 1 -- load clobbers (gs_scan defect 1 and 2)
# =============================================================================
class TestGsScanLoadClobber(unittest.TestCase):
    """The MEM branch used to record and then `continue`, so an instruction that
    is BOTH a memory access and a writer never reached the generic write
    detection: a load whose destination is its own tracked base left the base
    tracked with its old offset."""

    def test_self_clobbering_load_does_not_leave_the_base_tracked(self):
        # The review's exact proven example. NOP included deliberately, so delay
        # slots are not the cause -- the old `continue` was.
        w = GsWindow([lw(S0, GP, H2DA_OFF),   # seed: s0 = gs base
                      lw(S0, S0, 0),           # s0 = *(gs+0)  -- clobbers its own base
                      NOP,
                      lw(V0, S0, 4)])          # must NOT be gs+0x4
        d = w.descs()
        self.assertIn('gs+0x0', d, "the indexing load itself is a real access")
        self.assertNotIn('gs+0x4', d,
                         "base register was clobbered by its own load; the old code "
                         "emitted a false gs+0x4 here")
        self.assertEqual(len(d), 1, "expected exactly one record, got %r" % d)

    def test_self_clobbering_load_without_a_nop_keeps_the_delay_slot_value(self):
        # Without the NOP the follow-up access sits in the clobbering load's
        # DELAY SLOT, where MIPS I says the load's result is not yet visible --
        # so `gs+0x4` is the CORRECT answer here, and this is deliberately NOT a
        # counterexample. Recorded because it is the trap that makes a naive
        # version of this test wrong: the old `continue` bug and the delay-slot
        # rule produce the same output on this particular window.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lw(S0, S0, 0),
                      lw(V0, S0, 4)])
        self.assertIn('gs+0x4', w.descs(),
                      "the delay slot still sees the pre-load value")

    def test_self_clobbering_load_then_nop_then_access_is_not_gs_plus_4(self):
        # The counterexample needs the access OUTSIDE the delay slot: this is
        # the review's proven window (NOP included deliberately).
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lw(S0, S0, 0),
                      NOP,
                      lw(V0, S0, 4)])
        self.assertNotIn('gs+0x4', w.descs(),
                         "outside the delay slot the clobber must be visible")

    def test_lb_destination_invalidates(self):
        # Defect 2: the generic write list omitted 0x20 (lb) and 0x21 (lh).
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lb(S0, S0, 0),           # lb writes s0 -- must invalidate
                      NOP,
                      lw(V0, S0, 4)])
        self.assertNotIn('gs+0x4', w.descs(),
                         "lb destination was never invalidated by the old opcode list")

    def test_lh_destination_invalidates(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lh(S0, S0, 0),
                      NOP,
                      lw(V0, S0, 4)])
        self.assertNotIn('gs+0x4', w.descs(),
                         "lh destination was never invalidated by the old opcode list")

    def test_lbu_destination_invalidates(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lbu(S0, S0, 0),
                      NOP,
                      lw(V0, S0, 4)])
        self.assertNotIn('gs+0x4', w.descs())

    def test_addi_destination_invalidates(self):
        # Defect 2: 0x08 (addi) was missing from the write list entirely.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addi(S0, ZERO, 0x40),    # s0 = 0x40, no longer the gs pointer
                      NOP,
                      lw(V0, S0, 4)])
        self.assertNotIn('gs+0x4', w.descs(),
                         "addi destination was never invalidated by the old opcode list")

    def test_0x1f_is_not_a_writer(self):
        # Defect 2: 0x1F is not a MIPS I opcode at all; the old list included it.
        # It must not invalidate anything, and the honest records must survive.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      I(0x1F, S0, S0, 0x10),   # unassigned opcode
                      NOP,
                      lw(V0, S0, 4)])
        self.assertIn('gs+0x4', w.descs(),
                      "an unassigned opcode must not be treated as a write")


class TestGsScanDelaySlot(unittest.TestCase):
    """MIPS I: a load's result is not visible to the instruction in its delay
    slot, so the destination is invalidated from pc+8 -- not at pc+4."""

    def test_delay_slot_instruction_still_sees_the_pre_load_value(self):
        # `lw $v0,4($s0)` sits in the delay slot of `lw $s0,0($s0)`; the load's
        # result is not yet visible, so this IS a genuine gs+0x4 access.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lw(S0, S0, 0),           # clobbers s0, visible from pc+8
                      lw(V0, S0, 4)])          # delay slot: still the gs pointer
        self.assertIn('gs+0x4', w.descs(),
                      "a delay-slot instruction must still see the pre-load value")

    def test_instruction_after_the_delay_slot_is_invalidated(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lw(S0, S0, 0),
                      NOP,                     # delay slot consumed
                      lw(V0, S0, 4)])          # now the clobber is visible
        self.assertNotIn('gs+0x4', w.descs())


# =============================================================================
# Class 2 -- operations mistaken as copies
# =============================================================================
class TestOperationsMistakenForCopies(unittest.TestCase):
    """`addu rd,rs,rt`/`or rd,rs,rt` with two live sources is arithmetic, not a
    copy. The old code propagated whichever operand was tracked and stamped a
    constant offset on it."""

    def test_non_move_addu_with_unprovable_addend_is_explicitly_unknown(self):
        # The orchestrator's independent counterexample (2026-10-04).
        # OLD -> ['gs+0x16+idx']  (a CONCRETE offset that was never provable)
        # NEW -> ['gs+?+idx']     (base is gs, offset honestly unknown)
        w = GsWindow([lw(S0, GP, H2DA_OFF),    # s0 = gs base
                      addiu(V1, ZERO, 0x40),   # v1 untracked, non-zero
                      addu(T0, S0, V1),        # base + UNPROVABLE offset
                      NOP,
                      sw(V0, T0, 0x16)])
        d = w.descs()
        self.assertEqual(d, ['gs+?+idx'],
                         "a non-move addu must surface as explicitly-unknown, not "
                         "as a fabricated gs+0x16 and not by vanishing; got %r" % d)
        for x in d:
            self.assertFalse(x.startswith('gs+0x16'),
                             "must not fabricate a concrete offset")

    def test_non_move_addu_does_not_vanish(self):
        # The other half of the same requirement: "unknown" must not become
        # "absent". Exactly one record, and it must be the unknown form.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addiu(V1, ZERO, 0x40),
                      addu(T0, S0, V1),
                      NOP,
                      sw(V0, T0, 0x16)])
        recs = w.run()
        self.assertEqual(len(recs), 1,
                         "the access must stay reported, not disappear: %r" % recs)

    def test_no_range_guard_suppresses_an_unknown_offset(self):
        # The `-0x400 <= off < 0x8000` window exists to reject offsets that cannot
        # be game-state fields, and is only meaningful for a COMPUTED offset. An
        # unknown offset must never be tested against it: that would turn
        # "offset unknown" into "record absent", which is the single failure mode
        # this whole change exists to prevent. Verified on the pre-fix draft,
        # which placed the `gs+?` emission behind the same range test.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addiu(V1, ZERO, 0x7FFF),   # large, untracked addend
                      addu(T0, S0, V1),          # offset NOT provable
                      NOP,
                      lw(V0, T0, 0x7FFC),        # even a wild immediate must emit
                      lw(V0, T0, 0x0)])
        d = w.descs()
        self.assertEqual(d, ['gs+?+idx', 'gs+?+idx'],
                         "an unknown offset must never be range-gated away; got %r" % d)

    def test_range_guard_still_applies_to_a_computed_offset(self):
        # The control: the window must still reject a definite nonsense offset, or
        # the fix would have removed the guard entirely instead of scoping it.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      NOP,
                      lw(V0, S0, 0x7FFC)])       # s0 is tracked with offset 0
        # 0x7FFC is inside the window, so this one IS claimed -- use a negative
        # offset beyond -0x400 instead.
        self.assertEqual(w.descs(), ['gs+0x7FFC'])
        w2 = GsWindow([lw(S0, GP, H2DA_OFF),
                       NOP,
                       lw(V0, S0, -0x1000)])
        self.assertEqual(w2.descs(), [],
                         "a definite out-of-window offset must still be rejected")

    def test_non_move_or_does_not_propagate_a_tracked_pointer(self):
        # `or rd,rs,rt` with two live sources is likewise not a copy.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addiu(V1, ZERO, 0x40),
                      or_(T0, S0, V1),
                      NOP,
                      sw(V0, T0, 0x16)])
        d = w.descs()
        self.assertEqual(d, ['gs+?+idx'], "got %r" % d)

    def test_genuine_move_is_still_followed(self):
        # The control: a real move must keep propagating, or this fix would have
        # traded a false positive for a false negative.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addu(T0, S0, ZERO),      # t0 = s0 (a genuine move)
                      NOP,
                      lw(V0, T0, 0x24)])
        self.assertEqual(w.descs(), ['gs+0x24'])

    def test_provably_zero_addend_keeps_its_exact_offset(self):
        # `addu $a0,$zero,$zero` then `addu $v0,$gs,$a0`: the addend is locally
        # provable as zero, so the exact offset must be preserved rather than
        # downgraded to unknown. (71 of the 185 downgrades on the real body were
        # this shape, e.g. 0x800c4f18 -> 0x800c4f2c.)
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addu(A0, ZERO, ZERO),    # a0 = 0, locally provable
                      addu(T0, S0, A0),
                      NOP,
                      lbu(V1, T0, 0x1AF4)])
        self.assertEqual(w.descs(), ['gs+0x1AF4'],
                         "a locally-provable zero addend must keep its exact offset")


# =============================================================================
# Class 3 -- cross-register arithmetic
# =============================================================================
class TestCrossRegisterArithmetic(unittest.TestCase):
    """`addiu rd,rs,imm` with rd != rs produces the source base PLUS the addend.
    The old code either silently reused the source offset (dropping the addend)
    or dropped the register."""

    def test_cross_register_addiu_keeps_its_addend(self):
        # lui B; addiu t0,t1,0x100 ; lw v0,0x24(t0) == gs + 0x100 + 0x24
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addiu(T0, S0, 0x100),    # t0 = gs + 0x100
                      NOP,
                      lw(V0, T0, 0x24)])
        self.assertEqual(w.descs(), ['gs+0x124'],
                         "the 0x100 addend was dropped")

    def test_same_register_addiu_folds(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      addiu(S0, S0, 0x10),
                      NOP,
                      lw(V0, S0, 0x24)])
        self.assertEqual(w.descs(), ['gs+0x34'])

    def test_addend_is_preserved_through_a_delay_slot(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      NOP,
                      addiu(T0, S0, 0x100),
                      lw(V0, T0, 0x24)])
        self.assertEqual(w.descs(), ['gs+0x124'])

    def test_addend_out_of_the_plausible_window_is_not_claimed(self):
        # A huge addend is not a game-state field offset; the honest answer is to
        # not claim the access rather than to invent a wrapped one.
        w = GsWindow([lw(S0, GP, H2DA_OFF),
                      lui(T0, 0x8018),         # t0 is a different base entirely
                      NOP,
                      lw(V0, T0, 0x340)])
        self.assertNotIn('gs+0x340', w.descs())


# =============================================================================
# Class 4 -- pointer invalidation (scan_structptr defects 5, 7, 8, 9)
# =============================================================================
STRUCT_FC = 0x00FC


def struct_seed(reg=S0, basereg=V1):
    """`lui $basereg,0x800b ; lw $reg,0xfc($basereg)` -- the detected idiom."""
    return [lui(basereg, 0x800B), lw(reg, basereg, STRUCT_FC)]


class TestStructPtrInvalidation(unittest.TestCase):
    """`tracked` used to be a set that was never invalidated, so any later
    clobber still read as the struct pointer. On the real body 20 of 119 records
    were stale for this reason."""

    def test_control_seed_then_access_is_recorded(self):
        w = StructWindow(struct_seed() + [NOP, sw(V0, S0, 0x34)])
        recs = w.run()
        self.assertEqual(len(recs), 1, "the control case must be detected: %r" % recs)
        self.assertEqual(recs[0][3], 0x34)

    def test_tracked_register_overwritten_by_lui_stops_being_tracked(self):
        # The review's 0x80016828 example: `lui $v0,0x800a` then an access off
        # $v0 was emitted as `struct+0x340`.
        w = StructWindow(struct_seed(S0, V1) + [
            NOP,
            sw(V0, S0, 0x34),        # genuine
            lui(S0, 0x800A),         # $s0 is now 0x800a0000, NOT the struct ptr
            NOP,
            lw(V0, S0, 0x340),       # must NOT be struct+0x340
        ])
        offs = [r[3] for r in w.run()]
        self.assertIn(0x34, offs)
        self.assertNotIn(0x340, offs,
                         "a register overwritten by lui must stop being tracked")

    def test_tracked_register_overwritten_by_a_load_stops_being_tracked(self):
        # The review's 0x800164c4 shape: `lw $v1,0xfc($v1)` reloads the register
        # from memory, so the old identity is gone.
        w = StructWindow(struct_seed(S0, V1) + [
            NOP,
            lw(S0, S0, 0),           # s0 = *(s0) -- no longer the struct pointer
            NOP,
            lw(V0, S0, 0x38),        # must NOT be struct+0x38
        ])
        offs = [r[3] for r in w.run()]
        self.assertNotIn(0x38, offs,
                         "a register overwritten by a load must stop being tracked")

    def test_tracked_register_overwritten_by_a_call_result_is_not_tracked(self):
        # A call clobbers the volatile registers; a later access through one of
        # them is not a struct access.
        w = StructWindow(struct_seed(V0, V1) + [
            NOP,
            jal(scan_structptr.BASE + 0x800),
            NOP,
            sw(V0, V0, 0x34),
        ])
        offs = [r[3] for r in w.run()]
        self.assertNotIn(0x34, offs,
                         "a call result must not read as the struct pointer")

    def test_non_move_addu_does_not_propagate_in_structptr(self):
        # The same "operation mistaken for a copy" rule as in gs_scan: this is
        # the 0x800168e4 `addu $v1,$v1,$v0` record that was labelled struct+0x3.
        w = StructWindow(struct_seed(S0, V1) + [
            NOP,
            addiu(V0, ZERO, 0x348),  # v0 = 0x348, a different base
            addu(S0, S0, V0),        # s0 = struct + 0x348 (arithmetic, not a copy)
            NOP,
            sb(V0, S0, 0x3),
        ])
        offs = [r[3] for r in w.run()]
        self.assertNotIn(0x3, offs,
                         "a non-move addu must not propagate the struct identity")

    def test_addiu_on_a_tracked_register_keeps_tracking_with_the_addend(self):
        # Defect 8: the old `addiu` case was a literal `pass` whose comment
        # claimed it kept tracking -- it did nothing, and the branch was dead
        # code because the register was never added to `tracked` either.
        w = StructWindow(struct_seed() + [
            NOP,
            addiu(S0, S0, 0x10),     # s0 = struct + 0x10
            NOP,
            lw(V0, S0, 0x24),        # struct + 0x34
        ])
        offs = [r[3] for r in w.run()]
        self.assertIn(0x34, offs,
                      "addiu must keep tracking with its addend; got %r" % offs)

    def test_scan_starts_after_the_loads_delay_slot(self):
        # Defect 7: the scan used to start at lpc+4, INSIDE the delay slot, where
        # the loaded pointer is not yet visible. An access placed entirely in the
        # delay slot must therefore not be attributed to this load.
        w = StructWindow(struct_seed(S0, V1) + [
            sw(V0, S0, 0x34),        # delay slot of the seed load: s0 not yet live
            NOP,
        ])
        self.assertEqual(w.run(), [],
                         "an access in the seed load's delay slot must not be "
                         "attributed to that load")

    def test_access_after_the_delay_slot_is_recorded(self):
        w = StructWindow(struct_seed(S0, V1) + [
            NOP,                     # the delay slot
            sw(V0, S0, 0x34),        # now the pointer is live
        ])
        self.assertEqual([r[3] for r in w.run()], [0x34])

    def test_scan_stops_at_jr_ra(self):
        # Defect 9: the walk crosses branches and jal but must stop at the
        # function return.
        w = StructWindow(struct_seed(S0, V1) + [
            NOP,
            sw(V0, S0, 0x34),
            jr(RA),                  # return
            NOP,
            sw(V0, S0, 0x38),        # unreachable; must not be reported
        ])
        offs = [r[3] for r in w.run()]
        self.assertIn(0x34, offs)
        self.assertNotIn(0x38, offs, "the walk must stop at jr $ra")


class TestStructPtrBaseWalk(unittest.TestCase):
    """Defect 6: `base_is_800B0000` had a private backward walk whose writer list
    omitted every load opcode and every call, so it walked through a clobbering
    load. It now reuses `mips_writers`."""

    def test_load_of_the_base_register_is_not_walked_through(self):
        # lui a0,0x800b ; lw a0,0x10(a0) ; lw s0,0xfc(a0)
        # The nearest writer of a0 is a LOAD, not the lui, so this is not the
        # 0x800B0000 idiom and must not be treated as a struct-ptr load.
        at = 0x100
        code = [lui(A0, 0x800B),
                lw(A0, A0, 0x10),
                NOP,
                lw(S0, A0, STRUCT_FC)]
        w = StructWindow(code)
        recs = w.run()
        self.assertEqual(recs, [],
                         "the base walk must not step over a clobbering load")

    def test_direct_lui_then_load_is_detected(self):
        # The positive control for the same walk.
        w = StructWindow(struct_seed())
        self.assertTrue(scan_structptr.base_is_800B0000(
            w.va(1), V1, reader=w.reader))

    def test_base_walk_does_not_accept_a_stale_lui(self):
        # lui a0,0x800b ; lw a0,0x10(a0) ; lw s0,0xfc(a0)
        # At the final load the nearest writer of a0 is the LOAD, so a0 is not
        # provably 0x800B0000 -- the private walk used to step over it and
        # accept the much older lui.
        w = StructWindow([lui(A0, 0x800B),
                          lw(A0, A0, 0x10),
                          NOP,
                          lw(S0, A0, STRUCT_FC)])
        self.assertFalse(scan_structptr.base_is_800B0000(
            w.va(3), A0, reader=w.reader),
            "the base walk must not step over a clobbering load")


class TestReaderInjection(unittest.TestCase):
    """S2: both scanners must run with no disc present."""

    def test_gs_scan_runs_without_the_disc(self):
        w = GsWindow([lw(S0, GP, H2DA_OFF), NOP, lw(V0, S0, 0x24)])
        self.assertEqual(w.descs(), ['gs+0x24'])

    def test_structptr_runs_without_the_disc(self):
        w = StructWindow(struct_seed() + [NOP, sw(V0, S0, 0x34)])
        self.assertEqual(len(w.run()), 1)

    def test_injected_reader_is_not_the_disc_reader(self):
        # A reader covering a tiny range must not fall back to the disc: outside
        # the window it returns None and the walk stops.
        w = GsWindow([lw(S0, GP, H2DA_OFF), NOP, lw(V0, S0, 0x24)])
        self.assertIsNone(w.reader(gs_scan.MBASE - 4))
        self.assertIsNone(w.reader(0xDEADBEEF))


if __name__ == "__main__":
    unittest.main(verbosity=2)
