#!/usr/bin/env python3
"""Formation/range rules checked against MAIN's complete attack-target builder."""
from pathlib import Path
import json
import hashlib
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import maindec
import character_table
from export_first_room import source

RANGES = {1: 'short', 2: 'long', 3: 'medium'}


def reference_vectors():
    vectors = []
    for code, name in RANGES.items():
        for slot in range(6):
            for enemy_slots in ((0, 1, 2), (3, 4, 5), (0, 1, 2, 3, 4, 5), (1, 4, 5), (4,), ()):
                flags = [not (code == 1 and slot >= 3) and (code == 2 or target < 3) for target in enemy_slots]
                vectors.append(dict(weapon_range=name, slot=slot,
                    enemy_rows=['front' if target < 3 else 'back' for target in enemy_slots], expected=flags))
    return vectors


class BattleRangeTests(unittest.TestCase):
    def test_complete_source_consumer_and_spawn_writer(self):
        main,_ = source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        for first,last,digest in (
            (0x800eec20,0x800eedd0,'31f6218e1decccea11aa98a204888b5563247575daa900cc9b54804095ec9a50'),
            (0x800df0b0,0x800df118,'9bab8e7b77461ad224c16ac0e2156471e0df6c4fe16b667aa0403c44a08be127')):
            self.assertEqual(hashlib.sha256(main[2048+first-base:2048+last-base]).hexdigest(),digest)
        for address,expected in {
            0x800eec4c:0x90630044, 0x800eec74:0x90630056,
            0x800eec78:0x34020001, 0x800eec7c:0x10620016,
            0x800eec84:0x34020002, 0x800eec88:0x14620026,
            0x800eeca0:0xac6231a4, 0x800eecb8:0xac66318c,
            0x800eecd8:0x28820004, 0x800eecf0:0xac6031a4,
            0x800eed04:0xac60318c, 0x800eed74:0x90620b84,
            0x800eed7c:0x28420004, 0x800eed88:0xaca8318c,
            0x800eed9c:0xace231a4, 0x800eeda0:0xaca0318c,
            0x800df0f4:0x26a20001, 0x800df0f8:0xa2420044,
            0x800df0fc:0x26520054, 0x800df108:0x26b50001,
            0x800df10c:0x2aa20006,
        }.items():
            self.assertEqual(struct.unpack_from('<I',main,2048+address-base)[0],expected,hex(address))

    def test_all_108_retained_vectors_match_independent_row_rule(self):
        vectors=reference_vectors()
        self.assertEqual(len(vectors),108)
        self.assertEqual(vectors, json.loads((ROOT / 'game/tests/fixtures/battle_range.json').read_text()))

    def test_candidate_exports_actual_weapon_classes_and_enemy_rows(self):
        content = json.loads((ROOT / 'game/tests/fixtures/demo_batch.json').read_text())
        image = character_table.image()
        # Slice the seed table independently of records() and the exporter.
        records = {}
        for i in range(78):
            raw = image[character_table.IMAGE_OFF + 80*i:character_table.IMAGE_OFF + 80*(i+1)]
            records[struct.unpack_from('<I', raw)[0]] = raw
        expected = ['medium', 'medium', 'short', 'short', 'medium', 'medium']
        for profile, native_id, name in zip(content['party'], (8, 2, 6, 35, 3, 32), expected):
            weapon = records[native_id][0x44]
            pointer = struct.unpack_from('<I', maindec.body(), 0x80165890 - maindec.MBASE + 4*weapon)[0]
            code = maindec.body()[pointer - maindec.MBASE + 0x56]
            self.assertEqual(profile['weapon_range'], name)
            self.assertEqual(RANGES[code], name)
        data, _ = source('/A_DATA.BIN')
        word=lambda address:struct.unpack_from('<I',data,address-0x80080000)[0]
        directory=word(word(word(0x80080000)+12))
        selectors=word(directory+8)
        for encounter,number in zip(content['encounters'][:3],(1,2,5)):
            record=word(selectors+4*number)
            roster=data[record-0x80080000+4:record-0x80080000+10]
            slots=[slot for slot,enemy in enumerate(roster) if enemy]
            self.assertEqual(len(slots),len(encounter['enemies']))
            self.assertEqual(encounter['source_slots'],slots)
            self.assertEqual(encounter['enemy_rows'],['front' if slot<3 else 'back' for slot in slots])
        for i, encounter in enumerate(content['encounters'][3:]):
            self.assertEqual(encounter['enemy_rows'], content['encounters'][i % 3]['enemy_rows'])


if __name__ == '__main__':
    if '--write-fixture' in sys.argv:
        (ROOT / 'game/tests/fixtures/battle_range.json').write_text(json.dumps(reference_vectors(), indent=2) + '\n')
    else:
        unittest.main()
