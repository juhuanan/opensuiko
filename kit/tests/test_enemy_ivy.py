"""Independent static Ivy consumers, source pixels and native curve witnesses."""
import hashlib
import json
import math
from fractions import Fraction
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import enemy_ivy
from export_first_room import source
from test_export_unite_review import vram_pose


def word(value):
    return (value + 2**31) % 2**32 - 2**31


def curve(points):
    """Bernstein polynomial with the source's separate truncation/wrap corrections."""
    result = []
    for k in range(13):
        point = []
        for a, b, c in zip(*points, strict=True):
            quadratic = (a - 2*b + c)*k*k
            linear = (b-a)*2*k
            exact = Fraction((12-k)**2*a + 2*k*(12-k)*b + k*k*c, 144)
            exact += Fraction(word(word(a-2*b+c)*k*k)-quadratic, 144)
            exact += Fraction(word(word(b-a)*2*k)-linear, 12)
            q = Fraction(word(word(a-2*b+c)*k*k), 144)
            l = Fraction(word(word(b-a)*2*k), 12)
            exact += int(q)-q + int(l)-l
            point.append(word(int(exact)))
        result.append(point)
    return result


def vectors():
    cases = []
    for start, home in (
        ([-524288, -204800, 0], [0, -204800, 0]),
        ([-524288, 327680, -40960], [0, 204800, 0]),
        ([-11, 23, -37], [17, -61, 43]),
        ([5, 7, 9], [19, -13, 1638400]),
        ([2147483600, -2147483600, -2147483600], [-2147483600, 2147483600, 2147483600]),
    ):
        midpoint = [word(a + int(Fraction(word(b-a), 2))) for a, b in zip(start, home)]
        tip = midpoint.copy()
        tip[2] = word(tip[2] - 245760)
        velocity = [int(Fraction(word(b-a), 10)) for a, b in zip(midpoint, home)]
        frames = []
        for update in range(16):
            if 1 <= update <= 10:
                tip = [word(a+b) for a, b in zip(tip, velocity)]
            elif update >= 12:
                tip[0] = word(tip[0] - 16384)
                tip[2] = min(tip[2], 0)
            frames.append(dict(stage=1 if update <= 10 else 2, visible=update != 0,
                               remaining=max(0, 10-update), end=tip.copy(), points=curve([start, midpoint, tip])))
        cases.append(dict(start=start, home=home, frames=frames))
    return dict(schema='suikoden-ivy-clock-witness/1', cases=cases)


class IvySourceTests(unittest.TestCase):
    def test_source_report_and_native_witness_are_current(self):
        self.assertEqual(enemy_ivy.build(), json.loads(enemy_ivy.REPORT.read_text()))
        self.assertEqual(vectors(), json.loads((ROOT/'game/tests/fixtures/ivy_vine.json').read_text()))

    def test_relocated_controller_bodies_and_curve_consumers_agree(self):
        d, _ = source('/D_DATA.BIN')
        f, _ = source('/F_DATA.BIN')
        for d_start, f_start, size, immediates in (
            (0x5c0, 0x370, 0x8e4, {0x8a0: (0xea4, 0xc54)}),
            (0xea4, 0xc54, 0xb54, {0x344: (0x10, 4), 0x42c: (0x20, 0x14),
                                  0x468: (0x20, 0x14), 0x48c: (0x20, 0x14)}),
        ):
            for off in range(0, size, 4):
                a = struct.unpack_from('<I', d, d_start+off)[0]
                b = struct.unpack_from('<I', f, f_start+off)[0]
                if off in immediates:
                    self.assertEqual((a & 65535, b & 65535), immediates[off])
                    a = a & 0xffff0000 | b & 65535
                elif a >> 26 in (2, 3):
                    a = a & 0xfc000000 | (((a & 0x3ffffff) - (d_start-f_start)//4) & 0x3ffffff)
                self.assertEqual(a, b, hex(off))
        self.assertEqual(d[0x19f8:0x1c38], f[0x17a8:0x19e8])
        # The full curve body is pinned; these independent words identify its three-axis consumer.
        for address, expected in {0xd14: 0x1840000f, 0xd70: 0x2442c000, 0xdc8: 0x3402000c,
                                  0xe48: 0x2aa2000d, 0x1330: 0x2aa2000c,
                                  0x14f4: 0xa4c70008, 0x154c: 0x2aa20003,
                                  0x1768: 0x2aa20003}.items():
            self.assertEqual(struct.unpack_from('<I', f, address)[0], expected)
        main, _ = source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        self.assertEqual(struct.unpack_from('<I', main, 2048+0x8016b680+0x70-base)[0], 0x8014f068)

    def test_source_parts_match_independent_vram_sampling_and_export(self):
        report = enemy_ivy.build()
        with tempfile.TemporaryDirectory(prefix='ivy-art-') as temporary:
            enemy_ivy.export_art(temporary, report)
            for actor in report['actors']:
                raw, _ = source('/'+actor['source']['file'].split('/')[-1])
                for art in actor['art']:
                    expected, ax, ay = vram_pose(raw, actor['section_offset'], art['pose'], base=0x80080000)
                    with Image.open(Path(temporary)/art['path']) as actual:
                        self.assertEqual(actual.tobytes(), expected.tobytes())
                        self.assertEqual(actual.size, (art['width'], art['height']))
                        self.assertEqual(hashlib.sha256(actual.tobytes()).hexdigest(), art['rgba_sha256'])
                    self.assertEqual(art['anchor'], [ax, ay])
            with self.assertRaisesRegex(ValueError, 'accepted staging'):
                enemy_ivy.export_art(ROOT/'kit/work/accepted/ivy', report)

    def test_renderer_import_and_root_calibration_have_an_independent_integer_derivation(self):
        main, _ = source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        word_at = lambda address: struct.unpack_from('<I', main, 2048+address-base)[0]
        self.assertEqual([word_at(a) for a in (0x800ddfb8, 0x800ddfbc, 0x800ddfc0)],
                         [0x3c038017, 0x2463b680, 0xac431258])
        self.assertEqual(word_at(0x8016b6f0), 0x8014f068)
        roots = struct.unpack_from('<192h', main, 2048+0x8017242c-base)
        self.assertEqual(list(roots), [math.isqrt((64+i)<<18) for i in range(192)])
        self.assertEqual(word_at(0x8014f0c4), 0x3c0d8017)
        self.assertEqual(word_at(0x8014f0cc), 0x85ad242c)

    def test_initializer_updater_and_curve_mutations_refuse_export(self):
        original = enemy_ivy.source
        for changed_path, offset in (('/F_DATA.BIN', 0x370), ('/F_DATA.BIN', 0xc54), ('/F_DATA.BIN', 0x17a8),
                                     ('MAIN.EXE', 2048+0x8014f068-0x800c0800), ('MAIN.EXE', 2048+0x8017242c-0x800c0800)):
            def changed(path):
                raw, origin = original(path)
                if path == changed_path:
                    raw = bytearray(raw)
                    raw[offset] ^= 1
                    raw = bytes(raw)
                return raw, origin
            with patch.object(enemy_ivy, 'source', side_effect=changed):
                with self.assertRaisesRegex(ValueError, 'vine source changed|segment normalizer changed'):
                    enemy_ivy.build()


if __name__ == '__main__':
    unittest.main()
