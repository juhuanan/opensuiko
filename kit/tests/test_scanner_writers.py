#!/usr/bin/env python3
"""Unit tests for the shared MIPS register-writer walk (kit/tools/mips_writers.py).

Synthetic instruction windows only -- no disc required. The walk was extracted
from scan_abs.py/scan_stores.py on 2026-10-04 because both private copies
ignored loads as writers and dropped cross-register addends, turning a loaded
value into a confident wrong constant. These tests pin the corrected behaviour
and the MIPS I delay-slot rule that lets the walk stay precise where it can.

Run:  .venv/bin/python kit/tests/test_scanner_writers.py
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

from mips_writers import dst_reg, resolve_reg, writer_of  # noqa: E402
from mipsdec import BASE, dec  # noqa: E402

# --- encoder helpers (MIPS I) -------------------------------------------------
ZERO, AT, V0, V1, A0, T0, T1, T2, S1, SP, RA = 0, 1, 2, 3, 4, 8, 9, 10, 17, 29, 31


def lui(rt, imm):        return (0x0F << 26) | (rt << 16) | (imm & 0xFFFF)
def addiu(rt, rs, imm):  return (0x09 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm):    return (0x0D << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def lw(rt, rs, off):     return (0x23 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def sw(rt, rs, off):     return (0x2B << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def addu(rd, rs, rt):    return (rs << 21) | (rt << 16) | (rd << 11) | 0x21
def or_(rd, rs, rt):     return (rs << 21) | (rt << 16) | (rd << 11) | 0x25
def jal(tgt):            return (0x03 << 26) | ((tgt >> 2) & 0x03FFFFFF)
NOP = 0


class Window:
    """A synthetic code image: reader(va) -> word or None."""

    def __init__(self, words):
        # words: list of (offset_from_BASE, word)
        self.mem = {BASE + off: w for off, w in words}
        self.end = BASE + 4 * len(words)

    def reader(self, va):
        return self.mem.get(va)

    def resolve(self, last_off, reg):
        """Resolve `reg` at the store that sits at offset `last_off`."""
        return resolve_reg(BASE + last_off, reg, reader=self.reader)


class TestWalkThroughLoad(unittest.TestCase):
    """A load must be visible as a writer, so its result is UNKNOWN, not a
    stale constant. This is the defect that produced 223 wrong addresses on the
    real SLUS_002.92 body."""

    def test_load_after_lui_is_not_resolved_to_the_lui(self):
        w = Window([(0, lui(T0, 0x800B)),
                    (4, lw(T0, T1, 0)),
                    (8, NOP),
                    (12, sw(V0, T0, 0xFC))])
        v, why = w.resolve(12, T0)
        self.assertIsNone(v, "loaded value must stay unresolved, got %s"
                          % (hex(v) if v is not None else v))
        self.assertIn("lw", why)

    def test_load_through_addiu_is_not_resolved_to_the_loaded_address(self):
        # The review's worst case: the reported store address was the address
        # the register was loaded FROM (0x800a00fc), not a constant. The NOP
        # keeps the store OUT of the load's delay slot, which is the situation
        # the real code (0x80011a7c..0x80011abc) is in.
        w = Window([(0, lui(T1, 0x800A)),
                    (4, addiu(T1, T1, 0xFC)),
                    (8, lw(T1, T1, 0)),
                    (12, NOP),
                    (16, sw(V0, T1, 0))])
        v, why = w.resolve(16, T1)
        self.assertIsNone(v, "expected UNKNOWN, got %s" % (hex(v) if v else v))
        self.assertIn("lw", why)

    def test_call_writes_ra_so_ra_is_not_a_stale_constant(self):
        w = Window([(0, lui(RA, 0x800B)),
                    (4, jal(BASE + 0x40)),
                    (8, NOP),
                    (12, sw(V0, RA, 0xFC))])
        v, _ = w.resolve(12, RA)
        self.assertIsNone(v, "jal result must not be treated as a constant")

    def test_unclassified_write_from_memory_chain_is_unresolved(self):
        # addu t0,t1,t2 is not a move; it must not be walked through as a copy.
        w = Window([(0, lui(T1, 0x800B)),
                    (4, addu(T0, T1, T2)),
                    (8, sw(V0, T0, 0xFC))])
        v, why = w.resolve(8, T0)
        self.assertIsNone(v)
        self.assertIn("non-move", why)


class TestCrossRegisterArithmetic(unittest.TestCase):
    """The addend must survive when source and destination differ."""

    def test_cross_register_addiu_keeps_its_addend(self):
        w = Window([(0, lui(T1, 0x800B)),
                    (4, addiu(T0, T1, 0xFC)),
                    (8, sw(V0, T0, 0))])
        v, _ = w.resolve(8, T0)
        self.assertEqual(v, 0x800B00FC, "addend 0xfc was dropped")

    def test_same_register_addiu_chain_folds(self):
        w = Window([(0, lui(T0, 0x800A)),
                    (4, addiu(T0, T0, 0x5D74)),
                    (8, addiu(T0, T0, -4)),
                    (12, sw(V0, T0, 0))])
        v, _ = w.resolve(12, T0)
        self.assertEqual(v, 0x800A5D70)

    def test_ori_after_addiu_folds_in_application_order(self):
        # lui B; addiu +0x10; ori 0xfc  ==  (B + 0x10) | 0xfc
        w = Window([(0, lui(T0, 0x800B)),
                    (4, addiu(T0, T0, 0x10)),
                    (8, ori(T0, T0, 0xFC)),
                    (12, sw(V0, T0, 0))])
        v, _ = w.resolve(12, T0)
        self.assertEqual(v, 0x800B00FC)

    def test_addiu_after_ori_folds_in_application_order(self):
        # lui B; ori 0xfc; addiu +0x10  ==  (B | 0xfc) + 0x10
        # A single accumulate-as-offset formula cannot express both orders.
        w = Window([(0, lui(T0, 0x800B)),
                    (4, ori(T0, T0, 0xFC)),
                    (8, addiu(T0, T0, 0x10)),
                    (12, sw(V0, T0, 0))])
        v, _ = w.resolve(12, T0)
        self.assertEqual(v, ((0x800B0000 | 0xFC) + 0x10) & 0xFFFFFFFF)

    def test_ori_from_lui_resolves(self):
        w = Window([(0, lui(T1, 0x800B)),
                    (4, ori(AT, T1, 0xFC)),
                    (8, sw(V0, AT, 0))])
        v, _ = w.resolve(8, AT)
        self.assertEqual(v, 0x800B00FC)

    def test_addiu_from_zero_is_a_constant(self):
        w = Window([(0, addiu(T0, ZERO, 0x1234)),
                    (4, sw(V0, T0, 0))])
        v, _ = w.resolve(4, T0)
        self.assertEqual(v, 0x1234)

    def test_move_forms_are_followed(self):
        w = Window([(0, lui(T1, 0x800B)),
                    (4, or_(T0, T1, ZERO)),
                    (8, sw(V0, T0, 0))])
        v, _ = w.resolve(8, T0)
        self.assertEqual(v, 0x800B0000)


class TestDelaySlots(unittest.TestCase):
    """On MIPS I a load's result is not visible to its delay-slot instruction,
    so a load at addr-4 must be skipped -- the old value is the correct one."""

    def test_load_in_the_delay_slot_does_not_clobber(self):
        w = Window([(0, lui(T0, 0x800B)),
                    (4, lw(T0, T1, 0)),      # delay slot of nothing; writes t0
                    (8, sw(V0, T0, 0xFC))])  # sw sits in lw's delay slot
        v, why = w.resolve(8, T0)
        self.assertEqual(v, 0x800B0000,
                         "the store sees the pre-load value; got %s (%s)"
                         % (hex(v) if v else v, why))

    def test_call_in_the_delay_slot_does_not_clobber_ra(self):
        w = Window([(0, lui(RA, 0x800B)),
                    (4, jal(BASE + 0x80)),
                    (8, sw(V0, RA, 0xFC))])   # sw sits in jal's delay slot
        v, _ = w.resolve(8, RA)
        self.assertEqual(v, 0x800B0000)


class TestShippedWatchlistUnchanged(unittest.TestCase):
    """The three hits the scanners shipped must still resolve identically:
    their base uses `lui $at,0x800b` immediately before the store."""

    def test_lui_at_then_store_resolves(self):
        w = Window([(0, lui(AT, 0x800B)),
                    (4, sw(V0, AT, 0xFC))])
        v, _ = w.resolve(4, AT)
        self.assertEqual(v, 0x800B0000)
        # and the caller adds the immediate to reach the watchlist target
        self.assertEqual((v + 0xFC) & 0xFFFFFFFF, 0x800B00FC)


class TestWriterClassification(unittest.TestCase):
    """dst_reg must name every instruction that genuinely writes a GPR."""

    def _dst(self, word):
        return dst_reg(dec(BASE, word)[1])

    def test_loads_write_their_rt(self):
        for enc in (lw(T0, T1, 4),):
            self.assertEqual(self._dst(enc), T0)

    def test_lui_and_immediate_arith_write_rt(self):
        self.assertEqual(self._dst(lui(T0, 0x800B)), T0)
        self.assertEqual(self._dst(addiu(T0, T1, 4)), T0)
        self.assertEqual(self._dst(ori(T0, T1, 4)), T0)

    def test_call_writes_ra(self):
        self.assertEqual(self._dst(jal(BASE + 8)), RA)

    def test_plain_jr_writes_nothing(self):
        self.assertIsNone(self._dst((RA << 21) | 0x08))

    def test_nop_writes_nothing(self):
        self.assertIsNone(self._dst(NOP))

    def test_zero_register_is_never_a_writer(self):
        self.assertIsNone(writer_of(BASE + 4, ZERO, reader=Window([(0, lui(ZERO, 1))]).reader))


if __name__ == "__main__":
    unittest.main(verbosity=2)
