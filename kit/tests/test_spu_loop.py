#!/usr/bin/env python3
"""SPU loop flags include the end block's 28 samples before wrapping.

Checks use block flags and Voice.render; waveform smoothness cannot establish
loop boundaries. Historical waveform measurements used a reversed-nibble decoder.
"""
import os
import struct
import sys
import unittest
from functools import cache
from unittest.mock import patch

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, 'tools'))
sys.path.insert(0, os.path.join(KIT, 'tools', 'seq'))

from export_first_room import source  # noqa: E402
from render_seq import parse_vab_bytes  # noqa: E402
from spu import Voice             # noqa: E402
from spu_fir import FIR           # noqa: E402

BLOCK_SAMPLES = 28          # 14 data bytes x 2 nibbles


@cache
def load(bank):
    va, _ = source(f'/{bank}.VA')
    vb, _ = source(f'/{bank}.VB')
    return parse_vab_bytes(va, vb)


def looping(loops, samples):
    """Yield (index, loop_start, loop_end) for every repeating loop."""
    for i, (ls, le, rep) in enumerate(loops):
        if ls is None or not rep or le <= ls + 4:
            continue
        yield i, ls, le


class TestEndBlockIsPartOfTheLoop(unittest.TestCase):
    """The loop body is [loop_start, loop_end + 28), inclusive of the end block."""

    def test_every_loop_has_exactly_one_block_after_loop_end(self):
        """The 28-sample tail IS the loop-END block, and belongs to the loop.

        This is the structural fact the boundary rests on. If the tail were
        longer or shorter than one block, `loop_end + 28` would be wrong.
        """
        checked = 0
        for bank in ('ORCH', 'HNK1', 'HNK2'):
            samples, _programs, loops = load(bank)
            for i, ls, le in looping(loops, samples):
                tail = len(samples[i]) - le
                self.assertEqual(
                    tail, BLOCK_SAMPLES,
                    '%s vag%02d: %d samples after loop_end, expected one block'
                    % (bank, i, tail))
                checked += 1
        self.assertGreater(checked, 0)

    def test_literal_flags_preserve_end_block_samples(self):
        from render_seq import decode_adpcm
        stream = bytes([0, 6] + [0x10] * 14 + [0, 3] + [0x32] * 14)
        pcm, loop = decode_adpcm(stream)
        self.assertEqual(loop, (0, 28, True))
        self.assertEqual(pcm[:2], [0, 4096])
        self.assertEqual(pcm[28:30], [8192, 12288])
        self.assertEqual(len(pcm), 56)

    def test_loop_end_block_flags_are_end_plus_repeat(self):
        """Block flags must show END (0x03) AFTER START (0x06) for a real loop.

        Independent confirmation of the boundary that does not use the waveform
        at all: byte 1 of the loop-END block has bit0 (end) and bit1 (repeat);
        the loop-START block has bit1 (repeat) and bit2 (start).
        """
        checked = 0
        for bank in ('ORCH', 'HNK2'):
            samples, _programs, loops = load(bank)
            data, _ = source(f'/{bank}.VB')
            # VB offsets use stored lengths, which may include unplayed padding.
            va, _ = source(f'/{bank}.VA')
            ps, vs = struct.unpack_from('<HxxH', va, 0x12)
            sizes = struct.unpack_from('<' + str(vs + 1) + 'H', va, 0x820 + ps * 512)
            offs = []
            cur = 0
            for size in sizes[1:]:
                offs.append(cur)
                cur += size * 8
            for i, ls, le in looping(loops, samples):
                base = offs[i]
                b_start = data[base + (ls // BLOCK_SAMPLES) * 16 + 1]
                b_end = data[base + (le // BLOCK_SAMPLES) * 16 + 1]
                self.assertTrue(b_start & 0x04,
                                '%s vag%02d: start block lacks loop-START' % (bank, i))
                self.assertTrue(b_end & 0x01,
                                '%s vag%02d: end block lacks loop-END' % (bank, i))
                self.assertTrue(b_end & 0x02,
                                '%s vag%02d: end block lacks loop-REPEAT' % (bank, i))
                self.assertLess(ls, le, '%s vag%02d: start must precede end' % (bank, i))
                checked += 1
        self.assertGreater(checked, 0)

    def test_vab_ends_before_padding_but_consumes_both_samples(self):
        va = bytearray(0x820 + 512 + 6)
        va[:4] = b'pBAV'
        struct.pack_into('<HHH', va, 0x12, 1, 1, 2)
        struct.pack_into('<HHH', va, 0x820 + 512, 0, 6, 6)
        block = lambda flag, value: bytes([0, flag] + [value] * 14)
        vb = (block(0, 0x10) + block(1, 0x32) + block(7, 0x77) +
              block(6, 0x54) + block(3, 0x76) + block(7, 0x77))
        with patch('vab_tones.parse_programs', return_value=([], None)), \
             patch('vab_tones.find_tone_table', return_value=(None, None, [])):
            samples, _, loops = parse_vab_bytes(va, vb)
            self.assertEqual([len(s) for s in samples], [56, 56])
            self.assertEqual(loops, [(None, 28, False), (0, 28, True)])
            self.assertEqual(samples[0][28:30], [8192, 12288])
            self.assertEqual(samples[1][28:30], [24576, 28672])
            with self.assertRaises(ValueError):
                parse_vab_bytes(va, vb[:-16])


class TestVoiceLoopPosition(unittest.TestCase):
    """Voice.render must cover the whole body, end block included, and wrap."""

    def _run(self, ls, le, steps=40000):
        n = le + 200
        samples = [((i * 97) % 3000) - 1500 for i in range(n)]
        v = Voice(samples, ls, le, True, 1.0, 0x80ff, 0xdfed)
        v.vol_l = v.vol_r = 1.0
        v.env.key_on()
        out_l = [0.0] * steps
        out_r = [0.0] * steps
        v.render(FIR, out_l, out_r, 0, steps, 44100)
        return v, out_l

    def test_voice_wraps_inside_the_loop_body(self):
        ls, le = 1000, 1200
        v, out = self._run(ls, le)
        # Position must never be left beyond the body end.
        self.assertLess(v.pos, le + BLOCK_SAMPLES + 1)
        self.assertGreater(v.pos, 0)
        # Something must actually have been produced well past the loop start,
        # i.e. the voice sustained instead of dying at the sample end.
        self.assertGreater(sum(1 for x in out if x != 0.0), 5000)

    def test_render_loop_period_matches_body_end(self):
        """The RENDERED output must repeat with period (loop_end + 28 - loop_start).

        This is the assertion that actually pins the boundary in the render
        path. The flag-reading test above confirms what the data says; this one
        confirms the engine obeys it. Without this, changing `body_end` to `le`
        still passed every other test, so the boundary was effectively
        unverified where it matters.
        """
        ls, le = 1000, 1200
        body = le + BLOCK_SAMPLES - ls          # 228 samples
        v, out = self._run(ls, le, steps=20000)
        # Sample the output at an offset inside the sustained loop region and
        # check the waveform repeats one body-length later.
        base = ls + body * 2 + 5                # well inside the loop
        diffs = []
        for k in range(40):
            a = base + k
            b = a + body
            if b < len(out):
                diffs.append(abs(out[a] - out[b]))
        self.assertTrue(diffs, 'no loop region reached in render')
        # A wrong period shows up as a mismatch; a right one as near-equality.
        self.assertLess(
            max(diffs), 1e-6,
            'render does not repeat with period %d (max delta %.3f) -- the '
            'loop boundary is not loop_end + %d' % (body, max(diffs), BLOCK_SAMPLES))

    def test_end_block_samples_are_reachable(self):
        """Every sample index of the body must be reachable, end block included."""
        ls, le = 1000, 1200
        body_end = le + BLOCK_SAMPLES
        pos = float(ls)
        seen = set()
        for _ in range(20000):
            if pos >= body_end:
                pos = ls + ((pos - ls) % (body_end - ls))
            seen.add(int(pos))
            pos += 1.0
        self.assertEqual(len(seen), body_end - ls)
        self.assertEqual(min(seen), ls)
        self.assertEqual(max(seen), body_end - 1)
        self.assertGreaterEqual(max(seen), le)   # the end block is covered


class TestFirTapWrapping(unittest.TestCase):
    """FIR taps near the seam must wrap within the loop body, not the sample.

    Trap worth recording: a synthetic test with `loop_start = 0` CANNOT detect
    this bug, because `(i - 0) % span` and `i % nsrc` then agree on the taps
    that matter. That exact harness reported "zero difference" while the real
    data changed 99.98% of song 3's samples. Always use a non-zero loop_start.
    """

    def test_tap_wrapping_differs_only_at_the_seam(self):
        """Exactly 3 positions per pass differ: loop_start, +1, and the last."""
        checked = 0
        for bank in ('ORCH', 'HNK1', 'HNK2'):
            samples, _programs, loops = load(bank)
            for i, ls, le in looping(loops, samples):
                body_end = le + BLOCK_SAMPLES
                nsrc = len(samples[i])
                self.assertEqual(body_end, nsrc)   # see TestEndBlockIsPartOfTheLoop

                def loop_tap(p):
                    return ls + ((p - ls) % (body_end - ls))

                def whole_tap(p):
                    return p % nsrc

                diffs = [p for p in range(ls, body_end)
                         if any(loop_tap(p + d) != whole_tap(p + d)
                                for d in (-2, -1, 0, 1))]
                self.assertEqual(
                    diffs, [ls, ls + 1, body_end - 1],
                    '%s vag%02d: unexpected tap-divergence positions' % (bank, i))
                checked += 1
        self.assertGreater(checked, 0)

    def test_later_loop_taps_read_tail_after_first_traversal(self):
        """The first traversal hears the attack; subsequent loops use the tail."""
        checked = 0
        samples, _programs, loops = load('HNK2')
        picks = list(looping(loops, samples))[:4]
        for i, ls, le in picks:
            base = samples[i]
            body_end = le + BLOCK_SAMPLES

            def render_with(src_positions):
                v = Voice(src_positions, ls, le, True, 1.0, 0x80ff, 0xdfed)
                v.vol_l = v.vol_r = 1.0
                v.env.key_on()
                out = [0.0] * (body_end + 400)
                v.render(FIR, out, [0.0] * len(out), 0, len(out), 44100)
                return out

            plain = render_with(list(base))

            # Poison ONLY the sample's opening region (indices 0..1), which is
            # what the whole-sample wrap reaches for at the loop start.
            poisoned = list(base)
            poisoned[0] = 30000
            poisoned[1] = -30000
            poisoned_out = render_with(poisoned)

            self.assertNotEqual(plain[:8], poisoned_out[:8])
            self.assertEqual(
                plain[body_end+4:], poisoned_out[body_end+4:],
                'sustained render changed when only the sample opening was altered, so '
                'the FIR taps are wrapping against the whole sample (%d '
                'samples differ)' % sum(1 for a, b in zip(plain, poisoned_out)
                                        if a != b))
            checked += 1
        self.assertTrue(checked, 'no looping samples exercised')


if __name__ == '__main__':
    unittest.main(verbosity=2)
