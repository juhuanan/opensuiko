"""Static source checks and retained vectors for the opening initialization."""
from hashlib import sha256
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec as main
import opening_events
from export_first_room import source
from test_entity_predicates import assert_words, check_dispatch
from test_field_initializers import check_consumers

FIXTURES = ROOT / 'game/tests/fixtures'


def retained(name, digest):
    data = (FIXTURES / name).read_bytes()
    assert sha256(data).hexdigest() == digest, name
    return json.loads(data)


def source_programs():
    data, _ = source('/VAA.BIN')

    def pointer(offset):
        return struct.unpack_from('<I', data, offset)[0] - 0x80010000

    room = pointer(pointer(0) + 8) + 2 * 16
    entries, count = pointer(room), data[room + 4]
    assert (room, entries, count) == (0x4F890, 0x51010, 26)
    initializers = [i for i in range(count)
                    if struct.unpack_from('<H', data, entries + i * 24 + 4)[0] & 0x10]
    assert initializers == [23, 24]
    result = []
    for index, predicate, stream in ((23, b'\x06', b'\x41\x11\xfd'),
                                      (24, b'\x07\x00\x40\x06',
                                       bytes.fromhex('30 3a 00 3a 01 3a 02 3a 03 3a 09 3a 08 3a 07 31 fd'))):
        address = entries + 24 * index
        guard_at, stream_at = pointer(address + 16), pointer(address + 20)
        assert data[guard_at:guard_at + len(predicate)] == predicate, index
        assert data[stream_at:stream_at + len(stream)] == stream, index
        result.append((guard_at, stream_at, predicate))
    return result


def assert_span(start, end, digest):
    region = main.body()[start - main.MBASE:end - main.MBASE]
    assert sha256(region).hexdigest() == digest, hex(start)


class OpeningEvents(unittest.TestCase):
    def test_complete_room_initialization_driver_matches_order_conditions_and_one_pump_policy(self):
        check_consumers()
        source_programs()
        assert_words({
            # Selection clears text-busy and reloop; ordinary frame pumping reads its own enable.
            0x8013E17C: (0x3C018018, 0xA420C028),
            0x8013E1BC: (0x3C018018, 0xA020A180),
            0x80132B80: (0x90421C28,),
            0x80132B90: (0x10400007,),
        })
        cases = retained('opening_initialization.json',
                         'f82a01643558dc325a3c3fc5490c32a5f54e0ac2a0bc5f2193e79f350c56279d')
        expected = {(mask, flag, None) for mask in range(128) for flag in (False, True)}
        expected.update((127, flag, cached) for flag in (False, True) for cached in (129, 513))
        self.assertEqual(len(cases), len(expected))
        self.assertEqual({(row['attached_mask'], row['flag'], row['cached_cue']) for row in cases}, expected)
        for row in cases:
            programs = ['vaa_room2_init_23', 'vaa_room2_init_24'] if row['flag'] else ['vaa_room2_init_23']
            self.assertEqual((row['programs'], row['selected']), (programs, programs[-1]))
            self.assertEqual((row['cursor'], row['active'], row['reloop']), (9 if row['flag'] else 1, False, False))

    def test_exports_and_reference_vectors_are_current(self):
        runtime, evidence = opening_events.export()
        self.assertEqual(runtime, json.loads((ROOT / 'game/assets/opening_events.json').read_text()))
        self.assertEqual(evidence, json.loads((ROOT / 'kit/data/reports/opening_events.json').read_text()))
        self.assertEqual([(row['predicate'], row['stream']) for row in evidence['programs']],
                         [(guard, stream) for guard, stream, _ in source_programs()])
        assert_span(0x80139930, 0x8013999C, 'f6b4984a549cc260f5dd650d0e4ffcacdbeadfe41b961a65018cd9c29bb4a220')
        assert_span(0x80142440, 0x80142534, 'cb7e1afb98df643c810541eb6b12887e3231ca4c98f9bcdede277617b54abddd')
        self.assertEqual(main.mword(0x80171718 + 4 * 0x41), 0x80139930)
        self.assertEqual(struct.unpack_from('<H', main.body(), 0x80171C2C + 2 * 0x11 - main.MBASE), (129,))
        assert_words({
            # Skip queueing if cue is cached. Cue 129 is outside the cache writer's range.
            0x80142454: (0x84631E22, 0x00101400, 0x00022403, 0x10830015),
            0x80142468: (0x2602FDFF, 0x3042FFFF, 0x2C420245, 0x10400003),
            0x80142480: (0xA4251E22, 0x0C030C41),
            0x80139984: (0xA6220030,),
            # FD retries on either low busy bit and clears the active byte on completion.
            0x8013E0E0: (0x9442C028, 0, 0x30420003, 0x10400009),
            0x8013E100: (0x2442FFFF, 0x3C018018, 0xAC22AF84),
            0x8013E118: (0xA0201C28,),
        })
        cases = retained('opening_events.json',
                         'bb531bac36bd302bc7e2f1950d62f0aab8419d5ddb3c653170f5921b3fe96091')
        expected = {('vaa_room2_init_24', mask, None) for mask in range(128)}
        expected.update(('vaa_room2_init_23', 127, cached) for cached in (None, 129, 513))
        self.assertEqual(len(cases), len(expected))
        self.assertEqual({(row['program'], row['attached_mask'], row['cached_cue']) for row in cases}, expected)
        for row in cases:
            first, busy_low, busy_high, finished = row['ticks']
            self.assertEqual(row['busy'], [0, 1, 2, 4])
            self.assertEqual([tick['active'] for tick in row['ticks']], [True, True, True, False])
            self.assertEqual([busy_low['cursor'], busy_high['cursor'], finished['cursor']],
                             [first['cursor'], first['cursor'], first['cursor'] + 1])

    def test_conditions_match_original_initialization_predicates_for_all_flag_bytes(self):
        check_dispatch()
        assert_words({
            # Predicate 07 requires a bit set in the scenario byte bank.
            0x8013DD84: (0x02002021, 0x34050001, 0x0C04F5B3, 0x34060001),
            0x8013D708: (0x00431021, 0x90430190),
            0x8013D724: (0x00621024, 0x10400008, 0x24840001),
        })
        runtime, _ = opening_events.export()
        for program, (_, _, predicate) in zip(runtime['programs'], source_programs(), strict=True):
            condition = program['condition']
            self.assertIn(condition, ('always', 'story_0006'))
            for flag in range(256):
                source_matches = predicate[0] == 6 or bool(flag & predicate[2])
                runtime_matches = condition == 'always' or bool(flag & 0x40)
                self.assertEqual(source_matches, runtime_matches, (program['id'], flag))

    def test_unsupported_commands_and_truncated_streams_fail_closed(self):
        for raw in (b'\x09\x00\x40\xfd', b'\x41', b'\x3a\x80\xfd', b'\x30'):
            with self.assertRaises(ValueError):
                opening_events.compile_stream(raw, 0)

    def test_descriptor_staging_all_selector_families_and_missing_objects(self):
        self.assertEqual(main.mword(0x80171718 + 4 * 0x3A), 0x8013C82C)
        assert_span(0x8013C82C, 0x8013C8E4, 'f765f6c42173870c9ed748a04f4cf9b51cb49c8c6dee84566d3082448669dcb8')
        assert_words({
            # 0x40-family indices are masked to six bits. Both arrays use 24-byte descriptors.
            0x8013C84C: (0x30620040, 0x10400008, 0x3062003F, 0x00021840, 0x3C048018, 0x8C84AF94,
                         0x00621821, 0x000318C0, 0x0804F229, 0x00641821),
            0x8013C874: (0x306400FF, 0x34020080, 0x10820007, 0x00041040, 0x3C038018, 0x8C63DAA0,
                         0x00441021, 0x000210C0, 0x0804F229, 0x00431821, 0x3C038018, 0x2463BD74),
            # The null-child branch skips all writes. Fixed descriptor 0x80 uses cell X=240.
            0x8013C8A4: (0x8C620008, 0, 0x1040000B, 0, 0x3C028018, 0x2442BD74, 0x10620003, 0xA0600005,
                         0x0804F234, 0x340200FE, 0x340200F0, 0xA0620000, 0x340200FE, 0xA0620001, 0x03E00008),
            # Parent coordinate bytes and the separate child pointer have distinct consumers.
            0x8012FD30: (0x8E320008,), 0x8012FD78: (0x92240000,),
            0x8012FDA0: (0x000420C0,), 0x8012FDC4: (0x92220001,),
            0x8012FDD8: (0x000210C0,),
        })


if __name__ == '__main__':
    unittest.main()
