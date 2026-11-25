"""Static source anchors for the VB6 room6 follow-on transition."""
from pathlib import Path
import json
import hashlib
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source, collision_sources, scenery_query
import maindec
import export_field_followons
import area_scene


class FollowOnSource(unittest.TestCase):
    def test_candidate_export_reproduces_without_live_admission(self):
        outputs = export_field_followons.outputs()
        for path, expected in outputs.items():
            self.assertEqual(path.read_text(), expected)
        report = json.loads(outputs[ROOT / 'kit/data/reports/field_followons.json'])
        self.assertEqual(report['instructions'][-1]['opcode'], 3)
        self.assertEqual(len(report['bindings']), 2)
        self.assertEqual([entry['entity'] for entry in report['reconstruction_initializers']], [6, 8, 28])
        initializer8 = report['reconstruction_initializers'][1]['conditions']['terms']
        self.assertEqual([(term['kind'], term['flag']['id'], term['flag']['mask']) for term in initializer8],
                         [('story_mask_clear', 'scenario_0016', 1), ('story_mask_set', 'scenario_0015', 64)])
        self.assertIn('not admitted', report['limitations'][0])
        candidate = json.loads(outputs[ROOT / 'game/assets/events/vb6_room6_e7.json'])
        program = candidate['programs'][0]
        self.assertEqual(program['commands'][-1], {'kind': 'room_transition',
                         'destination': 'vb6_kobold_village', 'x': 216, 'y': 200})
        self.assertEqual(program['commands'][-2]['flag'], {'id': 'scenario_0015', 'mask': 64})
        self.assertEqual(candidate['programs'][1]['id'], 'vb6_r06_init_08')

    def test_e7_stream_and_terminal_source(self):
        data, _ = source('/VB6.BIN')
        self.assertEqual(data[0x35164:0x35189], bytes.fromhex(
            '07 00 01 02 07 00 02 19 32 00 01 16 05 33 11 80 03 '
            '0b 00 12 00 0e 1c 00 00 06 02 0c 46 09 0f 40 03 06 1b 19 fd'))
        self.assertEqual(data[0x3518c:0x3519d], bytes.fromhex(
            '30 07 00 01 18 07 00 02 19 11 00 01 11 80 03 31 fd'))
        anchors = {
            0x8013e0ac: 0x9442c028,  # low-two-bit text-busy state
            0x8013e0b4: 0x30420003,
            0x8013e0c4: 0xac24af84,  # busy path restores the opcode cursor
            0x8013e0d0: 0x0c04efe5,  # clear path reads transition operands
            0x8013e0d8: 0x00408021,  # retains transition result
            0x8013e118: 0xa0201c28,  # inline exit clears the active stream
            0x8013e12c: 0xac22dc4c,  # inline exit signals completion
            0x8013c144: 0xa0450001,  # ordinary format writes the room
            0x8013c174: 0xa4a40004,  # writes half-cell X
            0x8013c180: 0x34020002,  # ordinary format returns transition kind 2
            0x8013c22c: 0xa4a30006,  # writes half-cell Y in the return path
            0x8013ca00: 0x0c04f1d4,  # actor X stores then recomputes depth
            0x8013ca04: 0xa0820000,
            0x8013ca30: 0x0c04f1d4,  # actor Y stores then recomputes depth
            0x8013ca34: 0xa0820001,
            0x8013c798: 0x00021023,  # unattached ground depth is negative Y
            0x8013c7a0: 0xa0820016,
        }
        for address, expected in anchors.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))
        self.assertEqual((6, 27 * 8, 25 * 8), (data[0x35185], data[0x35186] * 8, data[0x35187] * 8))

    def test_room6_actor_metadata_matches_source_records(self):
        data, _ = source('/VB6.BIN')
        room = area_scene.room_record(data, 6)
        entries = area_scene.entities(data, room)
        packet = json.loads((ROOT / 'game/assets/field_ordinary_actors_vb6.json').read_text())
        animation = json.loads((ROOT / 'game/assets/field_ordinary_animations_vb6.json').read_text())
        self.assertEqual(len(packet['actors']), 26)
        for actor in packet['actors']:
            entry = entries[actor['entity']]
            self.assertEqual((actor['x'], actor['y']), (entry['x_half'] * 8, entry['y_half'] * 8))
        first = packet['actors'][0]
        self.assertEqual((first['entity'], first['resource'], first['graphic']),
                         (7, 'vb6_room6_character_014', 'vb6_character_014'))
        x, y, _flags, character = struct.unpack_from('<4H', data, 0x357d4)
        self.assertEqual((character, x * 8, y * 8), (14, first['x'], first['y']))
        resources = area_scene.character_bindings(data, area_scene.section_off(data, room['section']))
        context = resources[14]['context']
        self.assertEqual(context, 0x3e22c)
        table = area_scene.ptr_at(data, context + 20)
        actual = next(row for row in animation['animations'] if row['graphic'] == first['graphic'])
        for variant, clip in enumerate(actual['clips']):
            descriptor = area_scene.ptr_at(data, table + 4 * variant)
            self.assertEqual(clip['ticks'], [data[descriptor + 5 + 2*i] or 256 for i in range(data[descriptor])])
            self.assertEqual(clip['flags'], data[descriptor + 1])
        self.assertEqual(sum(actor['resource'] == 'party_character_008' for actor in packet['actors']), 2)

    def test_arrival_actor_context_preserves_source_identity(self):
        load = lambda name: json.loads((ROOT / 'game/assets' / name).read_text())
        arrival = load('field_ordinary_actors_vb6_arrival.json')
        followon = load('field_ordinary_actors_vb6.json')
        context = load('vb6_field_context_actors.json')
        existing = load('vb6_field_context.json')
        content = load('events/vb6_room6_field_host.json')
        self.assertEqual(arrival['actors'], followon['actors'])
        for key in ('scene', 'binding_sha256', 'population_sha256'):
            self.assertEqual(arrival[key], followon[key])
        self.assertEqual(arrival['event_sha256'], content['content_sha256'])
        self.assertEqual(context['event_sha256'], content['content_sha256'])
        self.assertEqual(context['ordinary_sha256'], arrival['content_sha256'])
        self.assertEqual(context['population_sha256'], arrival['population_sha256'])
        for key in existing:
            if key != 'content_sha256':
                self.assertEqual(context[key], existing[key])
        for value in (arrival, context):
            expected = value.pop('content_sha256')
            self.assertEqual(hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest(), expected)

    def test_followon_candidate_references_source_program_without_rewriting_baseline(self):
        load = lambda name: json.loads((ROOT / 'game/assets' / name).read_text())
        composite = load('events/vb6_room6_followons.json')
        arrival = load('events/vb6_room6_field_host.json')
        followon = load('events/vb6_room6_e7.json')
        bundle = load('scenes/events/vb6_room6_followons.json')
        policy = load('scenes/dispatch/vb6_room6_followons.json')
        baseline = load('scenes/dispatch/vaa_vb6.json')
        actors = load('field_ordinary_actors_vb6_followons.json')
        context = load('vb6_field_context_followons.json')
        self.assertEqual(composite['programs'], arrival['programs'] + followon['programs'])
        self.assertEqual(composite['actors'], arrival['actors'])
        self.assertEqual(actors['actors'], load('field_ordinary_actors_vb6_arrival.json')['actors'])
        self.assertEqual(actors['event_sha256'], composite['content_sha256'])
        self.assertEqual(context['event_sha256'], composite['content_sha256'])
        self.assertEqual(context['ordinary_sha256'], actors['content_sha256'])
        scene = next(row for row in policy['scenes'] if row['id'] == 'vb6_room6')
        old = next(row for row in baseline['scenes'] if row['id'] == 'vb6_room6')
        entry = next(row for row in scene['entries'] if row['source_order'] == 7)
        self.assertEqual(next(row for row in old['entries'] if row['source_order'] == 7)['status'], 'blocked_unsupported')
        self.assertEqual(entry['status'], 'executable')
        self.assertEqual(entry['program']['content_sha256'], followon['content_sha256'])
        self.assertEqual(entry['program']['program_id'], followon['programs'][0]['id'])
        self.assertEqual(scene['bundle']['content_sha256'], bundle['content_sha256'])
        self.assertEqual(bundle['entries'][7]['program'], {k: v for k, v in entry['program'].items() if k != 'entry'})
        for value in (composite, bundle, policy):
            expected = value['content_sha256']
            value['content_sha256'] = ''
            self.assertEqual(hashlib.sha256((json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest(), expected)

    def test_e7_actor_and_raw_scenery_x_bound(self):
        data, _ = source('/VB6.BIN')
        room = area_scene.room_record(data, 6)
        actor = area_scene.entities(data, room)[7]
        scenery = area_scene.scenery_records(data, area_scene.section_off(data, room['section']))
        self.assertEqual((actor['x_half'], actor['y_half'], actor['flags']), (254, 254, 3))
        self.assertEqual(len(scenery), 36)
        # This bounds raw records only; it does not prove their runtime state.
        self.assertLessEqual(max(record['x_half'] for record in scenery) + (255 >> 3), actor['x_half'])
        self.assertEqual(scenery_query(collision_sources(data, area_scene.section_off(data, room['section'])), 254, 254), (0, 0))
        anchors = {
            0x8012f05c: 0xa0400006,  # constructor clears retained attachment
            0x8012f0a8: 0x96840000,  # constructor passes source X
            0x8012f0b4: 0x0c04b8c2,  # scenery query
            0x8012f0c4: 0x1040002e,  # zero result retains cleared attachment
            0x8012e8f4: 0x94630024,  # scenery count comes from the section
            0x8012e944: 0x8c440028,  # scenery records come from the section
            0x8012e95c: 0xa0430000,  # builder copies source X into query record
            0x8012e340: 0x910b0000,  # scenery X is an unsigned byte
            0x8012e354: 0x91020004,  # scenery width is an unsigned byte
            0x8012e368: 0x000210c3,  # width is divided by eight
            0x8012e370: 0x0082102a,  # query requires X less than X + width
            0x8012e374: 0x10400081,
        }
        for address, expected in anchors.items():
            self.assertEqual(maindec.mword(address), expected, hex(address))

    def test_vb6_surface_packet_matches_source_footprints(self):
        data, _ = source('/VB6.BIN')
        room = area_scene.room_record(data, 6)
        section = area_scene.section_off(data, room['section'])
        records = area_scene.scenery_records(data, section)
        context = area_scene.contexts(data, section)[0]['offset']
        objects = []
        for record in records:
            sheet = area_scene.descriptor_sheet(data, context, record['type'])['sheet']
            width, height = data[sheet + 2] // 8, data[sheet + 3] // 8
            mask_start = sheet + 8 + data[sheet] * 8
            objects.append((record, width, height, data[mask_start:mask_start + width * height]))
        tile_width = area_scene.u16(data, section)
        tile_height = area_scene.u16(data, section + 2)
        tiles = area_scene.ptr_at(data, section + 0x14)
        packed = area_scene.ptr_at(data, section + 0x30)

        def source_terrain(x, y):
            bits = 0
            for bit, (dx, dy) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
                cx, cy = x + dx, y + dy
                code = struct.unpack_from('<H', data, tiles + 2 * ((cy // 2) * tile_width + cx // 2))[0]
                value = (data[packed + code // 2] >> (4 * ((code + 1) & 1))) & 15
                bits |= ((value >> ((cy & 1) * 2 + (cx & 1))) & 1) << bit
            return bits

        def source_scenery(x, y, level):
            result, selected = 0, 0
            for n, (record, width, height, mask) in enumerate(objects):
                if record['b4'] not in (level, level + 1) or record['order'] in (0, 1) or result & 255:
                    continue
                ox, oy = x - record['x_half'], y - record['y_half']
                if not (-1 <= ox < width and -1 <= oy < height):
                    continue
                result = 0
                for bit, (dx, dy) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
                    mx, my = ox + dx, oy + dy
                    if 0 <= mx < width and 0 <= my < height:
                        value = mask[my * width + mx]
                        result |= (1 << (8 + bit)) | ((value & 1) << bit) | ((value & 2) << (3 + bit))
                selected = 0 if result & 15 else n + 1
            return result, selected

        packet = json.loads((ROOT / 'game/assets/field_surfaces_vb6.json').read_text())
        self.assertEqual((packet['schema'], packet['scene']), ('suikoden-field-surfaces/1', 'vb6_room6'))
        self.assertEqual(len(packet['cells']), 2666)
        cells = {}
        for cell in packet['cells']:
            self.assertEqual((cell['x'] % 8, cell['y'] % 8), (0, 0))
            self.assertIn(cell['height'], (0, 1))
            x, y, level = cell['x'] // 8, cell['y'] // 8, cell['height']
            self.assertNotIn((x, y, level), cells)
            cells[x, y, level] = cell
        source_count = 0
        for level in (0, 1):
            for y in range(tile_height * 2 - 1):
                for x in range(tile_width * 2 - 1):
                    query, index = source_scenery(x, y, level)
                    if not query:
                        self.assertNotIn((x, y, level), cells)
                        continue
                    source_count += 1
                    cell = cells[x, y, level]
                    terrain = source_terrain(x, y)
                    low, upper, coverage = query & 15, (query >> 4) & 15, (query >> 8) & 15
                    if level and index:
                        solid = (low & coverage) | (terrain & ~coverage)
                    elif level or (index and upper & ~low):
                        solid = low | (terrain & ~coverage)
                    else:
                        # MAIN's ground fallback masks scenery before adding terrain at 0x8012DC34.
                        solid = terrain | (low & ~upper)
                    self.assertEqual(cell['walkable'], solid == 0)
                    expected = None
                    if index and upper:
                        obj = records[index - 1]
                        expected = {'id': f"scenery_{obj['index']}", 'height': obj['b4'], 'depth': 256 - obj['order']}
                    self.assertEqual(cell['support'], expected)
        self.assertEqual(source_count, len(packet['cells']))
        self.assertEqual(sum(cell['support'] is not None for cell in packet['cells']), 6)
        actors = json.loads((ROOT / 'game/assets/field_ordinary_actors_vb6.json').read_text())['actors']
        for actor in actors:
            self.assertEqual(source_scenery(actor['x'] // 8, actor['y'] // 8, 0)[1], 0)
        for x in range(2, 25):
            self.assertEqual(source_scenery(x, 25, 0), (0, 0))


if __name__ == '__main__':
    unittest.main()
