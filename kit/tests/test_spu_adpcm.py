#!/usr/bin/env python3
"""SPU decoder checks against Mednafen's little-endian word extraction.

Literal byte fixtures pin nibble order independently of the packing helper.
Whole-bank comparisons exercise cross-block history in both existing tools.
"""
import os
import sys
import unittest

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, 'tools'))
sys.path.insert(0, os.path.join(KIT, 'tools', 'seq'))

import vab_to_wav  # noqa: E402
from export_first_room import source  # noqa: E402
from render_seq import decode_adpcm, FILTERS  # noqa: E402


def reference_decode(data):
    """Spec transcription of PS_SPU::RunDecoder, written from the reference.

    Deliberately naive and independent of render_seq.decode_adpcm: same
    arithmetic the hardware does, expressed as directly as possible, with the
    state carried across the whole stream.
    """
    out = []
    m1 = m2 = 0
    for b in range(len(data) // 16):
        blk = data[b * 16:b * 16 + 16]
        shift = blk[0] & 0x0F
        weight = (blk[0] >> 4) & 0x0F
        illegal_shift = shift > 12
        if illegal_shift:
            shift = 8
        if weight > 4:
            weight = 0
        w1, w2 = ((0, 0), (60, 0), (115, -52), (98, -55), (122, -60))[weight]
        for offset in range(2, 16, 2):
            word = int.from_bytes(blk[offset:offset + 2], 'little')
            if illegal_shift:
                word &= 0x8888
            coded = word << 12
            for _ in range(4):
                s = coded & 0xF000
                if s & 0x8000:
                    s -= 0x10000
                s >>= shift
                s += (m1 * w1) >> 6
                s += (m2 * w2) >> 6
                s = max(-32768, min(32767, s))
                out.append(s)
                m2, m1 = m1, s
                coded >>= 4
    return out


def make_block(shift, weight, nibbles):
    """Build a 16-byte block from 28 nibbles (low-first packing)."""
    assert len(nibbles) == 28
    blk = bytearray(16)
    blk[0] = (weight << 4) | shift
    blk[1] = 0
    for i in range(14):
        blk[2 + i] = nibbles[2 * i] | (nibbles[2 * i + 1] << 4)
    return bytes(blk)


class TestNibbleOrder(unittest.TestCase):
    def test_low_nibble_comes_first(self):
        # Literal 0x80 must decode as 0, -32768, regardless of make_block.
        blk = bytes([0, 0] + [0x80] * 14)
        got, _ = decode_adpcm(blk)
        self.assertEqual(len(got), 28)
        # shift 0, weight 0 -> sample = int16(nib << 12) exactly
        self.assertEqual(got[0], 0)
        self.assertEqual(got[1], -32768)
        self.assertEqual(got[2], 0)
        self.assertEqual(got[3], -32768)

    def test_adjacent_pairs_are_not_swapped(self):
        nibbles = [(i % 8) for i in range(28)]
        blk = make_block(shift=6, weight=0, nibbles=nibbles)
        got, _ = decode_adpcm(blk)
        want = reference_decode(blk)
        self.assertEqual(got, want)


class TestBlockHistory(unittest.TestCase):
    def test_filter_taps_carry_across_blocks(self):
        """Two loud blocks back to back must show continuity, not a reset.

        With weight 1 (w1=60) the second block's early samples are dominated by
        the carried DecodeM1. If history were reset per block, the very first
        sample of block 2 would be computed from m1=m2=0 and the two decoders
        would disagree -- which is precisely how the original bug presented.
        """
        nibbles = [7] * 28
        blk = make_block(shift=4, weight=1, nibbles=nibbles)
        stream = blk + blk            # two blocks, same content
        got, _ = decode_adpcm(stream)
        want = reference_decode(stream)
        self.assertEqual(len(got), 56)
        self.assertEqual(got, want)
        # Block 2's first sample is sample index 28.
        self.assertNotEqual(got[28], got[0])   # history changed the result

    def test_single_block_matches_reference(self):
        nibbles = [(i * 5) % 16 for i in range(28)]
        blk = make_block(shift=5, weight=4, nibbles=nibbles)
        self.assertEqual(decode_adpcm(blk)[0], reference_decode(blk))


class TestIllegalShiftMasking(unittest.TestCase):
    def test_large_shift_discards_bits_instead_of_scaling(self):
        """Spec: `(int16)(x & 0xF000) >> shift`, masking to 16 bits first.

        `(sign_extended(nib) << 12) >> shift` is NOT the same operation: it
        keeps the sign bits and shifts them down, producing a large negative
        value instead of a small one.
        """
        nibbles = [8] * 28            # nibble 8 -> 0x8000, the sign bit
        blk = make_block(shift=12, weight=0, nibbles=nibbles)
        got, _ = decode_adpcm(blk)
        want = reference_decode(blk)
        # int16(0x8000) = -32768; -32768 >> 12 = -8
        self.assertEqual(got[0], -8)
        self.assertEqual(got, want)

    def test_illegal_shift_is_forced_to_eight(self):
        nibbles = [(i * 3) % 16 for i in range(28)]
        blk = make_block(shift=13, weight=2, nibbles=nibbles)   # 13 > 12
        got, _ = decode_adpcm(blk)
        forced = make_block(shift=8, weight=2, nibbles=[n & 8 for n in nibbles])
        self.assertEqual(got, decode_adpcm(forced)[0])

    def test_out_of_range_weight_uses_zero_filter(self):
        nibbles = [(i * 3) % 16 for i in range(28)]
        blk = make_block(shift=6, weight=9, nibbles=nibbles)    # 9 > 4
        got, _ = decode_adpcm(blk)
        zero = make_block(shift=6, weight=0, nibbles=nibbles)
        self.assertEqual(got, decode_adpcm(zero)[0])


class TestWholeBankAgreement(unittest.TestCase):
    """Require byte-exact agreement on bank data read directly from the disc."""

    def _check(self, name):
        data, _ = source(f'/{name}.VB')
        self.assertGreater(len(data), 0)
        got, _ = decode_adpcm(data)
        want = reference_decode(data)
        self.assertEqual(len(got), len(want))
        self.assertEqual(got, want, '%s decode diverges from reference' % name)

    def test_orch(self):
        self._check('ORCH')

    def test_hnk1(self):
        self._check('HNK1')

    def test_hnk2(self):
        self._check('HNK2')


class TestIndependentToolAgreement(unittest.TestCase):
    """Cross-check the separately implemented stateful block decoder."""

    def _check(self, name):
        data, _ = source(f'/{name}.VB')
        vab_to_wav.reset_decoder_state()
        other = []
        for b in range(len(data) // 16):
            other.extend(vab_to_wav.decode_adpcm_block(data[b * 16:b * 16 + 16]))
        got, _ = decode_adpcm(data)
        self.assertEqual(len(got), len(other))
        self.assertEqual(got, other, '%s: independent decoders disagree' % name)

    def test_orch(self):
        self._check('ORCH')

    def test_hnk1(self):
        self._check('HNK1')

    def test_hnk2(self):
        self._check('HNK2')


if __name__ == '__main__':
    unittest.main(verbosity=2)
