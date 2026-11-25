#!/usr/bin/env python3
"""Candidate reproducibility and static checks of source tables and progression."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import character_table
import export_demo_batch
import exp_award
import maindec
from test_canonical_start import assert_main_words
from test_character_equipment_stats import check_stat_consumer
from test_character_growth_storage import growth_source_tables, source_level_up
from test_character_record_fields import magic_capacity_vectors


def progression_vectors():
    content = json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text())
    stats, hp = growth_source_tables()
    growth = []
    for member, profile in enumerate(content['party']):
        for level in (1, 14, 19, 59, 79, 98, 99):
            for randoms in ([0] * 7, [0, 1, 127, 255, 256, 32767, 511]):
                raw = bytearray(80)
                raw[13] = level
                raw[4:8] = struct.pack('<HH', profile['max_hp'], profile['max_hp'] - 20)
                raw[16:22] = bytes(profile['stats'][key] for key in ('attack', 'skill', 'defense', 'speed', 'magic', 'luck'))
                raw[24:30] = bytes(profile['growth'])
                after = source_level_up(raw, randoms, stats, hp)
                maximum, current = struct.unpack_from('<HH', after, 4)
                growth.append(dict(member=member, level=level, randoms=randoms,
                    new_level=after[13], stats=list(after[16:22]), max_hp=maximum, hp=current))
    awards = []
    for encounter_index, encounter in enumerate(content['encounters'][:3]):
        enemies = [next(e['level'] for e in content['enemies'] if e['id'] == id) for id in encounter['enemies']]
        for levels in ([5]*6, [1, 3, 8, 15, 30, 99]):
            awards.append(dict(encounter=encounter_index, levels=levels,
                expected=exp_award.award_pool(levels, [0]*6, enemies)[1:]))
    return dict(growth=growth, awards=awards)


class DemoBatchTests(unittest.TestCase):
    def test_rune_ownership_tiers_and_magic_capacity_from_source(self):
        content = json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text())
        rules = content['systems']
        capacity = magic_capacity_vectors()
        self.assertEqual(capacity, json.loads((ROOT / 'game/tests/fixtures/magic_capacity.json').read_text()))
        self.assertEqual(capacity, [[sum(mgc > t for t in row) for row in rules['magic_thresholds']] for mgc in range(256)])
        image, base = maindec.body(), maindec.MBASE
        self.assertEqual(hashlib.sha256(image[0x800EF67C-base:0x800EF86C-base]).hexdigest(),
                         '5250cd7b442e2fd686e7ee5dbca9c56ea2870d12ef372042002b447efc635b9e')
        assert_main_words({
            # Highest tier requires both a spell ID and a charge. Rows then draw in descending order.
            0x800EF720: (0x8EC3001C, 0x02A41021, 0x9051001A, 0x00641821, 0x90720008,
                         0x12200028, 0, 0x12400026, 0, 0x0080A021),
            0x800EF78C: (0x00111080, 0x00571021, 0x8C450000, 0x02602021, 0x0C051AED, 0x34060012),
            0x800EF7C4: (0x02004021, 0x1D00FFE2, 0x02602021, 0x0803BE10, 0x02801021),
            0x800EF7D8: (0x2484FFFF, 0x1C80FFD0, 0),
        })
        templates = {r['id']: r for r in character_table.records()}
        for profile, native_id in zip(content['party'], (8, 2, 6, 35, 3, 32)):
            rune = templates[native_id]['rune_id']
            name = export_demo_batch.item_tables.literal_at(maindec.mword(0x8016A0E0 + 4*rune), 20) if rune else None
            self.assertEqual(profile['rune'], name.removesuffix(' Rune').lower().replace(' ', '_') if name else None)
        runes = export_demo_batch.item_tables.runes()
        descriptors = set(struct.unpack_from('<31I', image, 0x8016A0E4-base))
        names = struct.unpack_from('<33I', image, 0x8016D340-base)
        spell_slots = {row['id']: i for i, row in enumerate(rules['spells'])}
        for rune in runes:
            if not any(rune['spell_ids']):
                continue
            self.assertIn(rune['addr'], descriptors)
            offset = rune['addr'] - base
            self.assertEqual(image[offset + 0x16], 0)
            count, = struct.unpack_from('<H', image, offset + 0x18)
            self.assertEqual(count, 4)
            spell_ids = list(image[offset + 0x1B:offset + 0x1B + count])
            self.assertEqual(spell_ids, rune['spell_ids'])
            for spell_id in spell_ids:
                self.assertTrue(export_demo_batch.item_tables.name_at(names[spell_id - 1], 24))
            exported = next(r for r in rules['runes'] if r['name'] == rune['name'])
            self.assertEqual(exported['spells'], [spell_slots.get(f'spell_{sid}') for sid in spell_ids])

    def test_reproducible_candidate_matches_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            one, two = Path(temp) / 'a', Path(temp) / 'b'
            content = export_demo_batch.export(one)
            export_demo_batch.export(two)
            self.assertEqual(content, json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text()))
            for filename in ('trial.json', 'actors.png', 'floor.png', 'ground.png', 'provenance.json'):
                self.assertEqual(hashlib.sha256((one / filename).read_bytes()).hexdigest(), hashlib.sha256((two / filename).read_bytes()).hexdigest())

    def test_export_protects_accepted_content(self):
        with self.assertRaisesRegex(ValueError, 'cannot write accepted content'):
            export_demo_batch.export(ROOT / 'kit/work/accepted/demo_batch')

    def test_encounter_exit_permission_comes_from_source_flag(self):
        content = json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text())
        area, _ = export_demo_batch.source('/A_DATA.BIN')
        _, _, _, selectors = export_demo_batch.trial.encounters.chain(area)
        _, selected = export_demo_batch.trial.encounters.selectors_table(area, selectors)
        for encounter, source_number in zip(content['encounters'], (1, 2, 5)):
            raw = struct.unpack_from('<i', area, selected[source_number-1] - 0x80080000 + 12)[0]
            self.assertEqual(encounter['escape_allowed'], raw >= 0)
        for i in range(3, 9):
            self.assertEqual(content['encounters'][i]['escape_allowed'], content['encounters'][i % 3]['escape_allowed'])

    def test_source_tables_and_equipment_from_source(self):
        content = json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text())
        rules = content['systems']
        for key, start in [('stat_growth', 0x8016BEC8), ('hp_growth', 0x8016BE08), ('experience', 0x8016BD90)]:
            self.assertEqual(rules[key], [maindec.mword(start + 4*i) for i in range(len(rules[key]))])
        templates = {r['id']: r for r in character_table.records()}
        for profile, id in zip(content['party'], (8, 2, 6, 35, 3, 32)):
            self.assertEqual(profile['growth'], templates[id]['growth'])
        check_stat_consumer()
        for item, native_id in zip(rules['equipment'], (1, 2), strict=True):
            descriptor = maindec.mword(0x80167658 + 4 * native_id) - maindec.MBASE
            image = maindec.body()
            self.assertTrue(image[descriptor + 0x1C] & 0x80)
            self.assertEqual(item['bonuses'], list(struct.unpack_from('<8b', image, descriptor + 0x20)))
        self.assertEqual(rules['unite']['members'], ['pahn', 'gremio'])
        self.assertEqual([maindec.body()[0x8016CD0C - maindec.MBASE + i] for i in (26, 27)], [6, 2])

    def test_retained_progression_vectors_match(self):
        self.assertEqual(progression_vectors(), json.loads((ROOT / 'game/tests/fixtures/demo_progression.json').read_text()))


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        (ROOT / 'game/tests/fixtures/demo_progression.json').write_text(json.dumps(progression_vectors(), indent=2) + '\n')
        (ROOT / 'game/tests/fixtures/magic_capacity.json').write_text(json.dumps(magic_capacity_vectors(), indent=2) + '\n')
    else:
        unittest.main()
