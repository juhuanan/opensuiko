"""Independent raw-record checks for the VB6 village population candidate."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))

from export_first_room import source
from export_vb6_room0_population import export
from export_vb6_room0_initializer import export as export_initializer
from export_vb6_room0_actors import export as export_actors
from export_vb6_room0_dialogue import export as export_dialogue
import maindec

BASE = 0x80010000


def pointer(data, offset):
    value = struct.unpack_from('<I', data, offset)[0]
    return None if value == 0 else value - BASE


def terms(data, offset):
    if offset is None:
        return []
    result = []
    while True:
        opcode = data[offset]
        offset += 1
        if opcode == 6:
            return result
        if opcode in (7, 8):
            index, mask = data[offset:offset + 2]
            offset += 2
            result.append({'kind': 'story_mask_set' if opcode == 7 else 'story_mask_clear',
                           'flag': {'id': f'scenario_{index:04}', 'mask': mask}})
        elif opcode in (0x0b, 0x0c):
            offset += 2
            result.append({'kind': 'unsupported', 'semantics': f'event_predicate_{opcode:02x}'})
        elif opcode == 4:
            offset += 1
            result.append({'kind': 'unsupported', 'semantics': 'event_predicate_04'})
        elif opcode == 5:
            result.append({'kind': 'interaction'})
        else:
            raise AssertionError(f'unexpected predicate byte {opcode:#x}')


class VillagePopulation(unittest.TestCase):
    def test_dialogue_transition_flags_and_exit_wait_are_static_instructions(self):
        # Opening and closing set one bit per box; the sprite manager clears it.
        expected = {
            0x8013B164: 0x9442C028, 0x8013B174: 0x34420002,
            0x8013B178: 0x34420001, 0x8013B180: 0xA422C028,
            0x8013B390: 0x9442C028, 0x8013B3A0: 0x34420002,
            0x8013B3A4: 0x34420001, 0x8013B3AC: 0xA422C028,
            0x8013E30C: 0x92420001, 0x8013E314: 0x14400012,
            0x8013E354: 0xA422C028, 0x8013E370: 0x92420001,
            0x8013E3A0: 0xA0350000, 0x8013E3F4: 0xA422C028,
            0x8013E0AC: 0x9442C028, 0x8013E0B4: 0x30420003,
            0x8013E0C4: 0xAC24AF84,
        }
        for address, word in expected.items():
            self.assertEqual(maindec.mword(address), word, hex(address))

    def test_raw_records_predicates_and_initializer_gate(self):
        packet, proof = export()
        data, _ = source('/VB6.BIN')
        self.assertEqual(packet, json.loads((ROOT / 'game/assets/scenes/population/vb6_room0.json').read_text()))
        self.assertEqual(proof, json.loads((ROOT / 'kit/data/reports/vb6_room0_population.json').read_text()))
        table = pointer(data, pointer(data, 0) + 8)
        entities = pointer(data, table)
        count = data[table + 4]
        self.assertEqual(count, 10)
        self.assertEqual(len(packet['entities']), count)
        self.assertEqual(packet['source']['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(packet['content_sha256'], 'aa048a2a8f0ae4b7540b1483264e4ce02f3a9e100fc4a43f601a98584489bcbb')
        for index, entity in enumerate(packet['entities']):
            offset = entities + index * 24
            x, y, flags, character = struct.unpack_from('<HHHH', data, offset)
            classification, event, stream = (pointer(data, offset + n) for n in (12, 16, 20))
            self.assertEqual(entity['source_order'], index)
            self.assertEqual((entity['position']['source_x'], entity['position']['source_y']), (x, y))
            self.assertEqual(entity['source_character_id'], character or None)
            self.assertEqual(entity['population_candidate'], bool(character and flags & 0x101))
            self.assertEqual(entity['classification']['terms'], terms(data, classification))
            self.assertEqual(entity['event_selection']['terms'], terms(data, event))
            self.assertEqual(proof['entities'][index]['event_stream_offset'], stream)
        self.assertEqual([e['source_order'] for e in packet['entities'] if e['record_role'] == 'initialization'], [6])
        self.assertEqual(proof['entities'][6]['event_stream_offset'], 0x34944)
        self.assertEqual(packet['entities'][6]['event_selection']['terms'], [
            {'kind': 'story_mask_set', 'flag': {'id': 'scenario_0015', 'mask': 8}},
            {'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0015', 'mask': 16}},
        ])
        self.assertEqual([e['source_character_id'] for e in packet['entities'] if e['population_candidate']], [136, 136, 148])

    def test_initializer_release_has_source_order_identity_and_gate(self):
        content, proof = export_initializer()
        data, _ = source('/VB6.BIN')
        self.assertEqual(data[0x34944:0x34949], bytes([0x30, 0x3a, 1, 0x31, 0xfd]))
        self.assertEqual(proof['selector'], 1)
        self.assertEqual(proof['target'], 'vb6_room0_entity_08')
        program = content['programs'][0]
        self.assertEqual([c['kind'] for c in program['commands']],
                         ['continue_tick', 'release_actor', 'yield_tick', 'end_stream'])
        self.assertEqual(program['commands'][1]['actor'], proof['target'])
        self.assertEqual(program['conditions'], [
            {'kind': 'story_mask_set', 'flag': {'id': 'scenario_0015', 'mask': 8}},
            {'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0015', 'mask': 16}},
        ])
        self.assertEqual(content, json.loads((ROOT / 'game/assets/events/vb6_room0_initializer.json').read_text()))
        self.assertEqual(proof, json.loads((ROOT / 'kit/data/reports/vb6_room0_initializer.json').read_text()))

    def test_actor_bindings_and_animation_clocks_match_raw_sources(self):
        bindings, packet, timing, proof, ground = export_actors()
        data, _ = source('/VB6.BIN')
        table = pointer(data, pointer(data, 0) + 8)
        entities = pointer(data, table)
        self.assertEqual([row['entity'] for row in packet['actors']], [7, 8, 9])
        for actor in packet['actors']:
            offset = entities + actor['entity'] * 24
            flags = struct.unpack_from('<H', data, offset + 4)[0]
            cursor = pointer(data, offset + 12)
            while data[cursor] != 6:
                self.assertIn(data[cursor], (7, 8))
                cursor += 3
            cursor += 1
            self.assertEqual(actor['variant'], data[cursor + 1] & 3)
            self.assertEqual(actor['speed'], (flags >> 2) & 1)
            self.assertEqual(actor['auto_animate'], bool(flags & 0x200))
        resources = {row['id']: row for row in proof['resources']}
        for animation in timing['animations']:
            native = int(animation['graphic'].rsplit('_', 1)[1])
            table = pointer(data, resources[native]['context'] + 20)
            for variant, clip in enumerate(animation['clips']):
                descriptor = pointer(data, table + variant * 4)
                self.assertEqual(clip['flags'], data[descriptor + 1])
                self.assertEqual(clip['ticks'], [data[descriptor + 5 + 2 * i] or 256 for i in range(data[descriptor])])
                self.assertEqual(len(clip['bounds']), len(clip['ticks']))
        for value, path in ((bindings, 'game/assets/scenes/bindings/vb6_room0.json'),
                            (packet, 'game/assets/field_ordinary_actors_vb6_room0.json'),
                            (timing, 'game/assets/field_ordinary_animations_vb6_room0.json'),
                            (proof, 'kit/data/reports/vb6_room0_actors.json'),
                            (ground, 'game/assets/field_vb6_room0_initial_ground.json')):
            self.assertEqual(value, json.loads((ROOT / path).read_text()))

    def test_initial_ground_query_against_raw_scenery(self):
        _, packet, _, _, ground = export_actors()
        data, _ = source('/VB6.BIN')
        root = pointer(data, 0)
        room = pointer(data, root + 8)
        sections = pointer(data, root + 4)
        section = pointer(data, sections + 4 * data[room + 5])
        records = pointer(data, section + 0x28)
        count = struct.unpack_from('<H', data, section + 0x24)[0]
        context = pointer(data, pointer(data, section + 0x20))
        descriptors, sheets = pointer(data, context + 20), pointer(data, context + 16)
        self.assertEqual(maindec.mword(0x8012f05c), 0xa0400006)
        self.assertEqual(maindec.mword(0x8012f0a4), 0xa0400007)
        self.assertEqual(maindec.mword(0x8012f0b4), 0x0c04b8c2)
        self.assertEqual(maindec.mword(0x8012f0c4), 0x1040002e)
        for actor, actual in zip(packet['actors'], ground['actors'], strict=True):
            x, y = actor['x'] // 8, actor['y'] // 8
            query, surface = 0, 0
            for index in range(count):
                ox, oy, kind, order, level = data[records + 5 * index:records + 5 * index + 5]
                descriptor = pointer(data, descriptors + 4 * kind)
                sheet = pointer(data, sheets + 4 * data[descriptor + 4])
                width, height = data[sheet + 2] // 8, data[sheet + 3] // 8
                if level not in (0, 1) or order in (0, 1) or not (ox - 1 <= x < ox + width and oy - 1 <= y < oy + height) or query & 255:
                    continue
                query = 0
                for bit, (dx, dy) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
                    sx, sy = x + dx - ox, y + dy - oy
                    if 0 <= sx < width and 0 <= sy < height:
                        value = data[sheet + 8 + 8 * data[sheet] + sy * width + sx]
                        query |= (1 << (8 + bit)) | ((value & 1) << bit) | ((value & 2) << (3 + bit))
                surface = 0 if query & 15 else index + 1
            self.assertEqual(surface, 0)
            self.assertEqual(actual, {'actor': actor['id'], 'x': actor['x'], 'y': actor['y'], 'query': query})

    def test_village_conversations_match_source_stream_and_text(self):
        outputs = export_dialogue()
        for path, value in outputs.items():
            self.assertEqual(value, json.loads(path.read_text()))
        content = outputs[ROOT / 'game/assets/events/vb6_room0_dialogue.json']
        proof = outputs[ROOT / 'kit/data/reports/vb6_room0_dialogue.json']
        data, _ = source('/VB6.BIN')
        exit_program = outputs[ROOT / 'game/assets/events/vb6_room0_world_exit.json']
        table = pointer(data, pointer(data, 0) + 8)
        entities = pointer(data, table)
        exit_stream = pointer(data, entities + 24 + 20)
        self.assertEqual(data[exit_stream:exit_stream + 9], bytes.fromhex('09 27 10 03 fb 01 56 55 fd'))
        self.assertEqual(exit_program['programs'][0]['commands'], [
            {'kind': 'story_or', 'flag': {'id': 'scenario_0039', 'mask': 16}},
            {'kind': 'world_transition', 'destination': 'region_b', 'x': 86, 'y': 85},
        ])
        expected = ('It\'s true! \nI really saw an elf! \nAw shucks, \nnobody believes me...',
                    'Up ahead is the Great Forest. \nEven we don\'t set foot in \nthere. \nIt\'s like a huge maze.')
        for index, row in enumerate(proof['conversations']):
            self.assertEqual(data[row['stream']:row['stream'] + 8], bytes((11, index + 1, 4, 0, index, 2, 12, 253)))
            tokens = content['texts'][index]['tokens']
            text = ''.join(token.get('text', '\n' if token['kind'] == 'newline' else '') for token in tokens)
            self.assertEqual(text, expected[index])
            self.assertEqual(content['programs'][index]['entity'], row['entity'])


if __name__ == '__main__':
    unittest.main()
