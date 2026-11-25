"""Named join state and growth vectors from the original record and event consumer."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table
import growth_rules
import maindec
from export_journey import maas_recruitment, maas_conversation
from export_first_room import source


def vectors():
    image = character_table.image()[character_table.IMAGE_OFF:character_table.IMAGE_OFF + 78 * 80]
    row = next(i for i in range(78) if struct.unpack_from('<I', image, i * 80)[0] == 70)
    content = json.loads((ROOT / 'game/tests/fixtures/journey_battle.json').read_text())
    definition = maas_recruitment(content)
    equipment = definition['seed']['loadout']['body']
    assert content['systems']['equipment'][equipment]['id'] == 'leather_coat'
    data, _ = source('/VB6.BIN')
    assert data[0x35D1B:0x35D1F] == bytes([0x4B, 0, 70, 17])
    advances = data[0x35D1E]
    original = image[row * 80:(row + 1) * 80]
    # The source normalizer scans each nine-byte row backwards for the last
    # threshold below MGC, then writes that index plus one at record+9..+12.
    base = 0x8016A60C - maindec.MBASE
    thresholds = maindec.body()[base:base + 36]
    tiers = [thresholds[i:i + 9] for i in range(0, len(thresholds), 9)]
    assert all(list(tier) == sorted(tier) for tier in tiers)
    result = []
    for level, varied in ((1, False), (1, True), (12, True), (98, True), (99, True)):
        draws = [((i * 997 + 51) & 32767) if varied else 51 for i in range(7 * min(advances, 99 - level))]
        actual = bytearray(original)
        actual[13] = level
        supplied = iter(draws)
        for _ in range(advances):
            growth_rules.level_up(actual, lambda: next(supplied))
        assert next(supplied, None) is None
        actual[8] = 0
        actual[9:13] = bytes(sum(threshold < actual[20] for threshold in tier) for tier in tiers)
        expected = dict(level=actual[13], experience=struct.unpack_from('<H', actual, 14)[0],
            hp=struct.unpack_from('<H', actual, 6)[0], max_hp=struct.unpack_from('<H', actual, 4)[0],
            stats=list(actual[16:22]), charges=list(actual[9:13]))
        # Source join preserves the owned template's worn coat and weapon/rune bytes.
        assert actual[31:80] == original[31:80]
        result.append(dict(level=level, draws=draws, expected=expected))
    return result


class MaasRecruitment(unittest.TestCase):
    def test_castle_substitution_and_decline_service_are_source_controls(self):
        data, _ = source('/VB6.BIN')
        conversation = maas_conversation(data, 5)
        self.assertEqual(conversation['recruitment']['accepted_suffix'], ' Castle.')
        self.assertEqual(conversation['recruitment']['joined'], 'joins!')
        self.assertNotIn('<end>', conversation['recruitment']['accepted_prefix'])
        # The original nested-string setup binds selector1 to GS's eight-byte castle name.
        self.assertEqual(tuple(maindec.mword(pc) for pc in range(0x800C4EF4, 0x800C4F14, 4)),
                         (0x3C038018, 0x8C63DB24, 0, 0x24621B84, 0x3C018018, 0xAC22C1DC,
                          0x03E00008, 0xA0601B8C))
        self.assertEqual(data[0x35D32:0x35D36], bytes.fromhex('430302fd'))

    def test_seed_is_original_owned_record_not_an_episode_party_copy(self):
        content = json.loads((ROOT / 'game/tests/fixtures/journey_battle.json').read_text())
        definition = maas_recruitment(content)
        raw = character_table.image()[0x33274 + 65 * 80:0x33274 + 66 * 80]
        seed = definition['seed']
        self.assertEqual((seed['level'], seed['member']['hp'], seed['weapon_level']), (raw[13], struct.unpack_from('<H', raw, 6)[0], raw[69]))
        self.assertEqual(seed['member']['inventory']['slots'], [dict(id='leather_coat', uses=0)] + [None] * 8)
        self.assertEqual(seed['rune'], None)
        self.assertEqual((definition['minimum_tier'], definition['level_advances']), (1, 17))
        self.assertEqual(json.loads((ROOT / 'game/tests/fixtures/journey.json').read_text())['recruitment'], definition)

    def test_growth_fixture_matches_source_tables_and_join_amount(self):
        self.assertEqual(json.loads((ROOT / 'game/tests/fixtures/maas_recruitment.json').read_text()), vectors())


if __name__ == '__main__':
    if '--write-fixtures' in sys.argv:
        (ROOT / 'game/tests/fixtures/maas_recruitment.json').write_text(json.dumps(vectors(), indent=2) + '\n')
    else:
        unittest.main()
