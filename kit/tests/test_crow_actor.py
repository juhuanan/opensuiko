#!/usr/bin/env python3
"""Static Crow callback contracts and independent signed-word curve vectors."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
from export_unite_programs import compile_operations
from export_physical_runes import stream

WINDOWS = ((0x178, 0x438, '99e345f23ec200bfe1233263e159ed09504c501003e749a132e150d95960ddeb'),
           (0x438, 0x604, 'efd64337f9b2e8ffebae233a7c68b46a215bac946707f1623ce8812905031cbf'),
           (0x604, 0x760, 'f7b1c2b988290b84698e7ac73a31083e21497088dba0c96c7f34296bd65ca8b7'))


def word(value):
    return (value + 2**31) % 2**32 - 2**31


def quotient(value, denominator):
    return (1 if value >= 0 else -1) * (abs(value) // denominator)


def vectors():
    raw, origin = source('/A_DATA.BIN')
    for start, end, digest in WINDOWS:
        if hashlib.sha256(raw[start:end]).hexdigest() != digest:
            raise ValueError('Crow callback source changed')
    cases = []
    for start, target in (([819200, -126969, 1], [-503797, 266253, 15]),
                          ([-1234567, 765431, -409603], [345671, -819201, 207]),
                          ([2147479552, -2147483629, 2147418112], [-1879048193, 1610612739, -4096])):
        control = [target[0], target[1], 0]
        end = [word(2*target[0]-start[0]), target[1], -409600]
        positions = []
        for age in range(30):
            point = []
            for a, b, c in zip(start, control, end, strict=True):
                curve = quotient(word(word(word(a-2*b+c)*age)*age), 900)
                linear = quotient(word(word(b-a)*2*age), 30)
                point.append(word(a+curve+linear))
            positions.append(point)
        cases.append(dict(start=start, target=target, positions=positions))
    return dict(source=origin, cases=cases)


class CrowActor(unittest.TestCase):
    def test_curve_vectors_reproduce_the_native_semantic_fixture(self):
        self.assertEqual(vectors(), json.loads((ROOT/'game/tests/fixtures/crow_dive.json').read_text()))

    def test_record_callback_slot_and_all_three_source_windows(self):
        raw, _ = source('/A_DATA.BIN')
        self.assertEqual(struct.unpack_from('<I', raw, 0x21a5c+48)[0], 0x80080604)
        self.assertEqual(struct.unpack_from('<I', raw, 0x21a5c+40)[0], 0x800a1a9c)
        self.assertEqual(struct.unpack_from('<I', raw, 0x21a9c+20)[0], 0x80080438)
        vectors()
        for address, expected in {0x800801fc:0x00470018, 0x8008020c:0x00470018,
                                  0x80080218:0x34090384, 0x8008025c:0x3408001e,
                                  0x80080424:0xad620000, 0x80080428:0x2842001e,
                                  0x800804d4:0xae020058, 0x80080524:0xaca20014,
                                  0x8008054c:0xaca20024, 0x80080570:0x28420010,
                                  0x800805ac:0x08020179, 0x800805b4:0x0c02005e,
                                  0x800805dc:0x34030063, 0x8008064c:0x92420045,
                                  0x8008065c:0x92620005, 0x800806b8:0x28630033}.items():
            self.assertEqual(struct.unpack_from('<I', raw, address-0x80080000)[0], expected, hex(address))

    def test_existing_compiler_can_lower_the_qualified_local_callback(self):
        raw, origin = source('/A_DATA.BIN')
        operations, _ = stream(raw, origin, 0x21adc, 0x21a9c, 0x80080000)
        code, blocked, effects = compile_operations(operations, 'melee/crow', {5:'crow_dive'})
        self.assertEqual(blocked, [])
        self.assertEqual(effects, ['crow_dive'])
        self.assertIn(dict(command=dict(effect=dict(id='crow_dive', binding='self'))), code)


if __name__ == '__main__':
    unittest.main()
