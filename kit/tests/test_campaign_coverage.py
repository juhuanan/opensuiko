"""The implementation ledger must not turn a source census into shipped chapters."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import campaign_coverage
from room_battle_package import PATH as ROOM_BATTLE_PATH


def authored_room_battle(room, encounter):
    digest = '0' * 64
    story = dict(id='scenario_0001', storage='scenario', byte_index=1)
    flag = dict(id=story['id'], mask=1)
    commands = [dict(kind='story_or', flag=flag), dict(kind='battle', battle=encounter), dict(kind='end_stream')]
    content = dict(schema='suikoden-event-ir/1', id='test_room_events', content_sha256=digest,
                   story_values=[dict(story, initial=0)], programs=[
                       dict(id='test_guard', entry='ordinary', entity=0, trigger='none', commands=commands),
                   ])
    population = dict(
        schema='suikoden-scene-population/2', id='test_room_population', content_sha256=digest,
        source=dict(file='authored_fixture', lba=0, size=1, sha256=digest, room=0),
        coordinate_contract=dict(source_units='half_cell', pixel_units='pixel', source_to_pixel='pixel = source * 8',
                                 axes='x_right_y_down', origin='room_top_left',
                                 source_coordinate_max=255, pixel_coordinate_max=2040,
                                 room_half_width=room['width'] // 8, room_half_height=room['height'] // 8),
        duplicate_policy='preserve_source_records', story_values=[story],
        programs=[dict(id='test_guard', namespace=content['schema'], content_id=content['id'])],
        entities=[dict(id='test_guard_owner', source_order=0, record_role='event', population_candidate=False,
                       source_character_id=None, resource_id=None, resource_domain=None, initialization_order=None,
                       position=dict(source_x=0, source_y=0, x=0, y=0, placement='not_applicable'),
                       classification=dict(pointer_state='null', terms=[]),
                       event_selection=dict(pointer_state='present', terms=[dict(kind='story_mask_clear', flag=flag)]),
                       trigger='ordinary', event=dict(reference='test_guard_stream', status='resolved', program_id='test_guard'))],
    )
    return dict(schema='suikoden-battle-field-events/3',
                rooms=[dict(room=room['id'], content=content, population=population)])


class CampaignCoverage(unittest.TestCase):
    def test_first_town_south_exit_follows_retained_world_point(self):
        import maindec
        from event_script_reachability import build
        from export_first_room import source

        area, origin = source('/VA1.BIN')

        def file_offset(at):
            return struct.unpack_from('<I', area, at)[0] - 0x80010000

        room_table = file_offset(file_offset(0) + 8)
        entry = file_offset(room_table)
        self.assertEqual(area[entry + 4:entry + 6], b'\0\0')
        predicate, stream = file_offset(entry + 16), file_offset(entry + 20)
        self.assertEqual((predicate, stream), (0x3B25C, 0x3B400))
        self.assertEqual(area[predicate:predicate + 7], bytes.fromhex('0b5a700c6d6d06'))
        self.assertEqual(area[stream:stream + 3], bytes.fromhex('03fffd'))
        graph = build(['VA1.BIN'])['overlays'][0]
        owner = next(row for row in graph['entries'] if row['room'] == row['entry'] == 0)
        self.assertEqual((owner['record'], owner['offset']), (entry, stream))

        area_table = maindec.mword(0x8016F67C)
        descriptor = maindec.mword(area_table)
        self.assertEqual((maindec.mword(descriptor), maindec.mword(descriptor + 4)),
                         (origin['size'], origin['lba']))
        point = maindec.mword(0x80170064) - maindec.MBASE
        kind, room, x, y, field_x, field_y = struct.unpack_from('<BBHHBB', maindec.body(), point)
        self.assertEqual((kind, room, field_x, field_y), (0, 0, 101, 108))
        self.assertEqual((x, y + 2), (63, 41))
        _, world_origin = source('/A_DATA.BIN')
        world = maindec.mword(0x8016F3B4)
        self.assertEqual((maindec.mword(world), maindec.mword(world + 4)),
                         (world_origin['size'], world_origin['lba']))

        anchors = {
            0x8013BFB8: 0x14620003, 0x8013BFC0: 0x0804F08C, 0x8013BFC4: 0x34020001,
            0x8013E0D0: 0x0C04EFE5, 0x8013F12C: 0x0C04F80A, 0x80132B98: 0x0C04FC44,
            0x801327C8: 0x10620009, 0x8013280C: 0xA0620035, 0x80131FB4: 0x0C04C752,
            0x80132030: 0xAC831BBC, 0x801314C0: 0xA4430090, 0x801314C4: 0xA4440092,
            0x80131D70: 0x14620024, 0x80131D88: 0x1462001E, 0x80131DD4: 0xA422F298,
            0x80131DF8: 0x24420002, 0x80131E00: 0xA422F29A, 0x80127AE0: 0x0C030BBE,
        }
        for address, expected in anchors.items():
            with self.subTest(address=hex(address)):
                self.assertEqual(maindec.mword(address), expected)

    def test_first_town_story_exits_follow_choice_and_flag_chain(self):
        import maindec
        from area_scene import entities, room_record
        from event_script_decode import switch_2f_targets
        from event_script_reachability import data_ranges, load_dialogue, walk
        from export_first_room import source

        area, _ = source('/VA1.BIN')
        room_zero = entities(area, room_record(area, 0))
        room_five = entities(area, room_record(area, 5))
        contexts = data_ranges(area, 'VA1.BIN', load_dialogue())
        cases = (
            (room_zero[41], '07052008060806', 0x3B5BD, '090540'),
            (room_five[1], '07054008058006', 0x3E0B0, '090580fd'),
            (room_zero[37], '0506', 0x3B7EC, '090604'),
            (room_zero[43], '0706040806080b606a0c525206', 0x3B9EB, '09060810656d03fffd'),
            (room_zero[44], '07060806', 0x3BA4D, '03fffd'),
        )
        for owner, predicate_hex, target, tail_hex in cases:
            _, predicate, stream = owner['stream_offsets']
            with self.subTest(stream=hex(stream)):
                expected_predicate, expected_tail = bytes.fromhex(predicate_hex), bytes.fromhex(tail_hex)
                self.assertEqual(area[predicate:predicate + len(expected_predicate)], expected_predicate)
                self.assertEqual(area[target:target + len(expected_tail)], expected_tail)
                self.assertIn(target, {node['offset'] for node in walk(area, [stream], contexts)['nodes']})

        classification = room_zero[37]['stream_offsets'][0]
        self.assertEqual(area[classification:classification + 7], bytes.fromhex('07058008060406'))
        self.assertEqual(area[0x3B82D:0x3B832], bytes.fromhex('03003f1bfd'))
        for switch, next_prompt in ((0x3B738, 0x3B767), (0x3B767, 0x3B796), (0x3B796, 0x3B7B7)):
            default, accepted = (switch_2f_targets(area, switch)[mode] for mode in (0, 1))
            cutoff = [(next_prompt, next_prompt + 1, 'end of response')] + contexts
            declined = {node['offset'] for node in walk(area, [default], cutoff)['nodes']}
            self.assertIn(next_prompt, declined)
            self.assertNotIn(0x3B7EC, declined)
            path = {node['offset'] for node in walk(area, [accepted], contexts)['nodes']}
            self.assertTrue({0x3B7EC, 0x3B82D} <= path)
        for branch in switch_2f_targets(area, 0x3B9BE).values():
            path = {node['offset'] for node in walk(area, [branch], contexts)['nodes']}
            self.assertTrue({0x3B9EB, 0x3B9EE, 0x3B9F1} <= path)

        self.assertEqual(maindec.mword(0x8013BF5C), 0xA025BD6C)
        self.assertEqual(maindec.mword(0x8013A540), 0x9042BD6C)
        self.assertEqual(maindec.mword(0x8013CBF8), 0x00431025)
        self.assertEqual(maindec.mword(0x8013CC00), 0xA0820190)

    def test_opening_escape_prerequisites_cross_va2_and_va7(self):
        from area_scene import entities, room_record
        from event_script_reachability import data_ranges, load_dialogue, walk
        from export_first_room import source

        cases = (
            ('VA2.BIN', 3, 11, '08032006', 0x270CD, '090320fd'),
            ('VA7.BIN', 13, 5, '0703200b1b1b0c1b1b08040106', 0x256D5, '090401'),
            ('VA2.BIN', 3, 13, '07032007040108040206', 0x27385, '090402'),
            ('VA1.BIN', 0, 39, '08031007040206', 0x3B5A2, '090310'),
            ('VA1.BIN', 2, 15, '07031008040806', 0x3D651, '090408fd'),
            ('VA1.BIN', 2, 16, '07031008040806', 0x3D651, '090408fd'),
            ('VA1.BIN', 1, 29, '08044007040806', 0x3C4C1, '090440'),
            ('VA1.BIN', 1, 24, '07044007040808050106', 0x3C63A, '090501'),
            ('VA1.BIN', 1, 32, '07050108050406', 0x3C74D, '090504fd'),
            ('VA1.BIN', 1, 8, '0507050408050806', 0x3C791, '090508'),
            ('VA1.BIN', 1, 33, '0705080805200b16180c1f1f06', 0x3CC7E, '090520'),
        )
        dialogue = load_dialogue()
        for filename, room, index, guard_hex, write, tail_hex in cases:
            with self.subTest(file=filename, room=room, entity=index):
                area, _ = source('/' + filename)
                _, predicate, stream = entities(area, room_record(area, room))[index]['stream_offsets']
                guard, tail = bytes.fromhex(guard_hex), bytes.fromhex(tail_hex)
                self.assertEqual(area[predicate:predicate + len(guard)], guard)
                self.assertEqual(area[write:write + len(tail)], tail)
                path = walk(area, [stream], data_ranges(area, filename, dialogue))
                self.assertTrue(any(node['offset'] == write and node.get('opcode') == 9 for node in path['nodes']))

    def test_va1_soul_eater_grant_follows_the_effect_callback(self):
        import maindec
        from area_scene import entities, room_record
        from event_script_reachability import data_ranges, load_dialogue, walk
        from export_first_room import source
        from war_text import decode

        area, _ = source('/VA1.BIN')
        callback_site, grant = 0x3C99C, 0x3C9B3
        self.assertEqual(area[callback_site:callback_site + 5], bytes.fromhex('3d00100a0b'))
        self.assertEqual(area[grant:grant + 2], bytes.fromhex('420e'))
        stream = entities(area, room_record(area, 1))[8]['stream_offsets'][2]
        contexts = data_ranges(area, 'VA1.BIN', load_dialogue())
        path = walk(area, [stream], contexts)
        self.assertEqual(path['frontier'], [])
        nodes = {node['offset']: node for node in path['nodes']}
        self.assertEqual(nodes[callback_site]['next'], [callback_site, 0x3C9A1])
        self.assertEqual(nodes[callback_site]['callback'], dict(target=0x80010188, operands=3))
        self.assertEqual(nodes[grant]['opcode'], 0x42)
        self.assertIn(0x3CA94, nodes)

        # Check the cursor arithmetic independently of the full-body hash.
        deltas = (
            ((0x268, 0x2AC, 0x2F0, 0x504, 0x528, 0x54C, 0x570, 0x594), -2),
            ((0x9E0, 0xA04), -2),
            ((0xA40, 0xA64, 0xA88), 3),
        )
        for sites, expected in deltas:
            words = [struct.unpack_from('<I', area, site)[0] for site in sites]
            self.assertTrue(all(word >> 16 == 0x2442 for word in words))
            self.assertEqual(sum(int.from_bytes(area[site:site + 2], 'little', signed=True) for site in sites), expected)
        changed = bytearray(area)
        changed[0xA88] ^= 1
        self.assertEqual(walk(changed, [callback_site])['frontier'][0]['reason'],
                         'overlay callback continuation unresolved')

        self.assertEqual(maindec.mword(0x80142C84), 0xAC22DA44)
        self.assertEqual(maindec.mword(0x80171718 + 4 * 0x42), 0x801398F8)
        self.assertEqual(maindec.mword(0x80139918), 0x0C050605)
        self.assertEqual(maindec.mword(0x800C1AC0 + 4 * 0x0E), 0x80141AB0)
        self.assertEqual(maindec.mword(0x80141AB0), 0x0C04E1D7)
        self.assertEqual(maindec.mword(0x80141AB4), 0x34040008)
        self.assertEqual(maindec.mword(0x80141AB8), 0x34030001)
        self.assertEqual(maindec.mword(0x80141AC0), 0xA043004C)
        name = maindec.mword(0x8016A0E4) - maindec.MBASE
        self.assertEqual(decode(maindec.body(), name)[0], 'Soul Eater')

    def test_ordinary_field_inventory_follows_room_rate_and_directory(self):
        from export_first_room import source

        report = campaign_coverage.field_encounters()
        summary = report['summary']
        self.assertEqual(summary['room_status'], dict(no_configuration=656, resolved=227, zero_rate=8))
        self.assertEqual((summary['directories'], summary['formations'], summary['unresolved_battlefields']), (31, 294, 0))
        field, proof = source('/VB6.BIN')
        vb6 = {row['room']: row for row in report['rooms'] if row['source_file'] == proof['file']}
        self.assertEqual([room for room, row in vb6.items() if row['status'] == 'resolved'], [1, 2, 3, 4, 5])
        self.assertEqual(vb6[6]['status'], 'no_configuration')
        config = report['configurations'][vb6[1]['configuration']]
        self.assertEqual(config['source_offset'], 0x34078)
        self.assertEqual((config['rate'], config['counter_threshold']), (2, 60))
        self.assertEqual(field[0x34078:0x34080], bytes.fromhex('02003c001c3d0780'))
        directory = report['directories'][config['directory']]
        self.assertEqual(directory['selectors_offset'], 0x63CF0)
        addresses = struct.unpack_from('<9I', field, 0x63CF0)
        self.assertEqual(addresses[0], 8)
        self.assertEqual([entry['descriptor_offset'] + 0x80010000 for entry in directory['formations']], list(addresses[1:]))
        self.assertEqual([entry['enemy_level_sum'] for entry in directory['formations']], [20, 60, 120, 40, 31, 46, 78, 30])
        self.assertEqual([(enemy['id'], enemy['offset'], enemy['name'], enemy['level']) for enemy in directory['enemies']], [
            (1, 0x5CC2C, 'Kobold', 20), (2, 0x5E074, 'Kobold', 20),
            (3, 0x5F3FC, 'Holly Spirit', 21), (4, 0x616E0, 'Holly Boy', 5),
        ])
        ground = directory['battlefield']['ground']
        self.assertEqual((ground['across'], ground['down'], ground['used_palettes']), (16, 16, [1]))
        self.assertEqual(ground['height_range'], [-180, 78])
        self.assertIsNone(directory['battlefield']['scenery'])
        dormant = next(row for row in report['rooms'] if row['source_file'].endswith('/VD6.BIN') and row['room'] == 0)
        self.assertEqual(dormant['status'], 'zero_rate')
        self.assertEqual(report['configurations'][dormant['configuration']]['counter_threshold'], 60)

        raw, proof = source('/VB5.BIN')
        track = report['directories'][f'{proof["file"]}#800645e0']
        ground = track['battlefield']['ground']
        self.assertEqual(ground['palette_offsets'][:4], [0x548AC, None, None, None])
        self.assertEqual(struct.unpack_from('<4I', raw, 0x65130), (0x800648AC, 0, 0, 0))
        self.assertEqual(ground['used_palettes'], [0])
        from battle_placement import directory_battlefield
        changed = bytearray(raw)
        struct.pack_into('<I', changed, 0x65130, 0)
        with self.assertRaisesRegex(ValueError, 'used battlefield palette is missing'):
            directory_battlefield(changed, 0x545E0, 0x80010000)

    def test_vb6_kobold_sources_match_region_c_after_relocation(self):
        from battle_placement import area_encounters
        from export_first_room import source
        from mipsdec import jtarget

        field, _ = source('/VB6.BIN')
        region, _ = source('/C_DATA.BIN')
        field_base, region_base = 0x80010000, 0x80080000
        directory = struct.unpack_from('<I', field, 0x3407C)[0] - field_base
        field_table = struct.unpack_from('<I', field, directory + 0x0C)[0] - field_base
        field_records = [address - field_base for address in struct.unpack_from('<3I', field, field_table + 4)]
        region_records = {slot['enemy_id']: slot['stats_offset']
                          for formation in area_encounters(region)['encounters'] for slot in formation['slots']}
        offset = field_records[0] - region_records[1]
        self.assertEqual(field_records, [region_records[index] + offset for index in (1, 2, 3)])
        start = struct.unpack_from('<I', region, region_records[1] + 0x28)[0] - region_base
        end = region_records[3]
        self.assertEqual((start, end, offset), (0x20B84, 0x23BE4, 0x3B818))
        relocated_callbacks = {}
        for index in (1, 2):
            a = struct.unpack_from('<I', region, region_records[index] + 0x30)[0]
            b = struct.unpack_from('<I', field, field_records[index - 1] + 0x30)[0]
            relocated_callbacks[region_records[index] + 0x30] = b
            length = 0x174
            for relative in range(0, length, 4):
                c_word = struct.unpack_from('<I', region, a - region_base + relative)[0]
                f_word = struct.unpack_from('<I', field, b - field_base + relative)[0]
                if c_word != f_word:
                    self.assertEqual((c_word >> 26, f_word >> 26), (2, 2))
                    target = jtarget(a + relative, c_word) - a
                    self.assertEqual(jtarget(b + relative, f_word) - b, target)
                    self.assertIn(target, range(0, length, 4))

        relocation = field_base + offset - region_base
        pointer_count = 0
        for address in range(start, end, 4):
            c_word = struct.unpack_from('<I', region, address)[0]
            f_word = struct.unpack_from('<I', field, address + offset)[0]
            if address in relocated_callbacks:
                self.assertEqual(f_word, relocated_callbacks[address])
            elif c_word != f_word:
                self.assertTrue(region_base + start <= c_word < region_base + end, hex(address))
                self.assertEqual(f_word, c_word + relocation, hex(address))
                pointer_count += 1
        self.assertEqual(pointer_count, 75)

    def test_vb6_holly_records_use_distinct_special_selectors(self):
        import maindec
        from export_first_room import source

        data, _ = source('/VB6.BIN')
        self.assertEqual(struct.unpack_from('<I', data, 0x5F3FC + 0x30)[0], 0x80010330)
        self.assertEqual(struct.unpack_from('<I', data, 0x616E0 + 0x30)[0], 0x80010F54)
        self.assertEqual(maindec.mword(0x800DDFC0), 0xAC431258)
        self.assertEqual((maindec.mword(0x8016B680), maindec.mword(0x8016B684)),
                         (0x80147E38, 0x800E3820))
        anchors = {
            0x80010378: 0x90420044, 0x80010380: 0x2C420004, 0x80010384: 0x1440000F,
            0x80010394: 0x8C420004, 0x80010398: 0x3C068007, 0x8001039C: 0x24C6F554,
            0x800103A4: 0x00802821, 0x800103AC: 0x244204DC, 0x800103B0: 0xAE42000C,
            0x80011098: 0xA0540049, 0x800110BC: 0x9042000D, 0x800110C4: 0x28420004,
            0x800110C8: 0x14400022, 0x800110E8: 0x34030064, 0x8001111C: 0x2863001A,
            0x80011120: 0x1460000B, 0x8001112C: 0xAE431264, 0x80011124: 0x3403001E,
            0x80011138: 0x3C068007, 0x8001113C: 0x24C61840,
        }
        for address, word in anchors.items():
            with self.subTest(address=hex(address)):
                self.assertEqual(struct.unpack_from('<I', data, address - 0x80010000)[0], word)
        self.assertNotEqual(data[0x5F554:0x5F564], data[0x61840:0x61850])

    def test_field_encounter_suppression_is_sampled_before_ordinary_picking(self):
        import maindec
        from area_scene import entities, room_record
        from event_script_reachability import data_ranges, load_dialogue, walk
        from export_first_room import source
        from mipsdec import sx16

        controls = campaign_coverage.field_encounters()['trigger_controls']
        suppression = controls['story_suppression']
        getter, toggle = maindec.mword(0x800C1B38 + 4 * 0x19), maindec.mword(0x800C1AC0 + 4 * 0x19)
        self.assertEqual((getter, toggle), (0x80141D4C, 0x80141BE8))
        scenario = (maindec.mword(getter + 0x0C) & 0xFFFF) - 0x190
        mask = maindec.mword(getter + 0x14) & 0xFFFF
        self.assertEqual((suppression['scenario_byte'], suppression['mask']), (scenario, mask))
        self.assertEqual((scenario, mask, suppression['sampled_on']), (43, 0x40, 'room_load'))
        self.assertEqual((maindec.mword(toggle + 0x14) & 0xFFFF, suppression['cleared_on']), (mask, 'world_entry'))
        for address, expected in ((0x8013212C, 0x8013213C), (0x8012CC58, 0x8012CD28)):
            branch = maindec.mword(address)
            self.assertEqual(branch >> 26, 5)
            self.assertEqual(address + 4 + 4 * sx16(branch), expected)
        self.assertEqual(controls['explicit_battle'], dict(opcode=0x47, operand='encounter_index',
                                                         transition_mask=4, skips_ordinary_picker=True))

        area, origin = source('/VB3.BIN')
        cases = (
            (12, 2, 0x42F84, '4219030e0e03fd'),
            (14, 0, 0x43098, '4219030c281cfd'),
            (20, 8, 0x432D2, '4219'),
        )
        self.assertEqual(suppression['candidate_toggle_sites'],
                         [dict(source_file=origin['file'], offset=site) for _, _, site, _ in cases])
        contexts = data_ranges(area, 'VB3.BIN', load_dialogue())
        for room, index, site, command_hex in cases:
            stream = entities(area, room_record(area, room))[index]['stream_offsets'][2]
            command = bytes.fromhex(command_hex)
            self.assertEqual(area[site:site + len(command)], command)
            reached = walk(area, [stream], contexts)['nodes']
            self.assertTrue(any(node['offset'] == site and node.get('opcode') == 0x42 for node in reached))

    def test_package_reports_room_event_owner_and_each_bound_encounter(self):
        fixtures = campaign_coverage.ROOT / 'game/tests/fixtures'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'battle').mkdir()
            (root / 'room.json').symlink_to(fixtures / 'journey_room.json')
            (root / 'journey.json').symlink_to(fixtures / 'journey.json')
            (root / 'battle/trial.json').symlink_to(fixtures / 'journey_unites_battle.json')
            before = campaign_coverage.battle_package_report(root)
            self.assertEqual(before['summary']['runtime_room_battle_requests'], 0)

            room = json.loads((root / 'room.json').read_text())['rooms'][0]
            packet = authored_room_battle(room, 'area_a_1')
            (root / ROOM_BATTLE_PATH).write_text(json.dumps(packet))
            report = campaign_coverage.battle_package_report(root)
            self.assertEqual(report['summary']['runtime_room_battle_requests'], 1)
            self.assertEqual(report['runtime_room_battle_requests'], [
                dict(room=room['id'], owner='test_guard_owner', program='test_guard', command=1, encounter='area_a_1'),
            ])
            self.assertEqual(report['runtime_field_triggers'], before['runtime_field_triggers'])
            self.assertEqual(report['summary']['source_only_entries'], before['summary']['source_only_entries'])

            for key, bad, diagnostic in (
                ('room', 'unknown_room', 'unknown room'),
                ('battle', 'unknown_encounter', 'unknown encounter'),
                ('program_id', 'unknown_program', 'unresolved program'),
            ):
                with self.subTest(key=key):
                    binding = packet['rooms'][0]
                    row = {'room': binding, 'battle': binding['content']['programs'][0]['commands'][1],
                           'program_id': binding['population']['entities'][0]['event']}[key]
                    original = row[key]
                    row[key] = bad
                    (root / ROOM_BATTLE_PATH).write_text(json.dumps(packet))
                    with self.assertRaisesRegex(ValueError, f'{ROOM_BATTLE_PATH}: .*{diagnostic}'):
                        campaign_coverage.battle_package_report(root)
                    row[key] = original
            packet['rooms'][0]['content']['programs'][0]['commands'].insert(0, dict(kind='choice', box=0, options=2))
            (root / ROOM_BATTLE_PATH).write_text(json.dumps(packet))
            with self.assertRaisesRegex(ValueError, 'without schema-5 dialogue'):
                campaign_coverage.battle_package_report(root)

    def test_scripted_battle_inventory_cross_checks_source_callers_and_runtime_placement(self):
        import area_scene
        from export_first_room import source

        fixtures = campaign_coverage.ROOT / 'game/tests/fixtures'
        journey = json.loads((fixtures / 'journey.json').read_text())
        combat = json.loads((fixtures / 'journey_unites_battle.json').read_text())
        report = campaign_coverage.battle_report(journey, combat)
        self.assertEqual(report['summary']['legacy_layout_probe_matches'], 50)
        self.assertEqual(report['summary']['source_entries_with_encounter'], 50)
        self.assertEqual(report['summary']['field_owner_records'], 54)
        self.assertEqual(report['summary']['field_owner_records_with_unsupported_terms'], 7)
        self.assertEqual(report['summary']['scripted_battlefields'], 21)
        self.assertEqual(report['summary']['regional_battlefields'], 9)
        self.assertEqual(report['summary']['source_only_entries'], 50)
        self.assertEqual(report['summary']['opening_entries_matched'], 3)
        self.assertEqual(report['summary']['boss_outcomes_with_unproven_end'], 8)
        self.assertEqual(report['summary']['boss_source_finish_kinds'], {
            'ordinary_live_count': 3, 'round_end_without_rewards': 2,
            'restores_boss_hp_and_clears_defeat_on_teardown': 1,
            'weakening_on_actor_selection': 1, 'knockout_phase_switch': 1,
        })
        self.assertEqual(len({row['id'] for row in report['bosses'] if row['name'] == 'Neclord'}), 2)

        callbacks = {Path(row['source']).stem: row for row in report['boss_action_callbacks']}
        expected_actions = {
            'VB8': (0x80010004,),
            'VE1': (0x80013D18, 0x80013E98, 0x80014070),
            'VC3': (0x8001186C, 0x80012290, 0x80012340),
            'VE3': (0x8001675C, 0x800168DC, 0x80016AB4),
            'VAC': (0x80013B1C, 0x80013D08, 0x80013DB8),
            'VF2': (0x800199C8, 0x80019B7C, 0x80019C2C),
        }
        self.assertEqual(set(callbacks), set(expected_actions))
        for overlay, addresses in expected_actions.items():
            actions = callbacks[overlay]['actions']
            self.assertEqual([int(action['entry'], 0) for action in actions], list(addresses))
            if len(addresses) == 3:
                self.assertEqual([phase['continuations'][0]['target'] for phase in actions[:2]],
                                 [hex(address) for address in addresses[1:]])
                self.assertEqual(actions[2]['action_delays'], [dict(site=hex(addresses[-1] + 0x34), updates=30)])
                overlay_bytes, _ = source(callbacks[overlay]['source'])
                offset = addresses[-1] - area_scene.RAM_BASE + 0x30
                self.assertEqual(overlay_bytes[offset:offset + 8], bytes.fromhex('1e000234641282ac'))
        names = {row['id']: row['name'] for row in report['bosses']}
        self.assertEqual({names[id] for id in callbacks['VB8']['boss_ids']}, {'Anji', 'Kanak', 'Leonardo'})
        self.assertEqual([call['kind'] for call in callbacks['VF2']['actions'][0]['calls']], ['debug_print', 'random'])
        self.assertEqual([call['descriptor'] for call in callbacks['VC3']['actions'][1]['calls']], ['0x80048a34'])

        callers = {row['mode']: row for row in report['request_sites']}
        self.assertEqual(set(callers), {3, 4})
        self.assertEqual(callers[3]['graph_entries'], ['battle_0000'])
        self.assertEqual(callers[4]['graph_entries'], [])
        self.assertEqual(callers[3]['candidate_roots'], [dict(room=0, entity=35, stream=0x267B4)])
        self.assertEqual(callers[4]['candidate_roots'], [dict(room=0, entity=42, stream=0x26420)])
        entry = next(row for row in report['source_entries'] if row['id'] == 'battle_0000')
        self.assertEqual(entry['opening_entry'], 'va2_r00_e35_battle')
        remaining = {row['id']: {term for owner in row['field_owners'] for term in owner['unsupported_terms']}
                     for row in report['source_entries'] if any(owner['unsupported_terms'] for owner in row['field_owners'])}
        self.assertEqual(remaining, {
            'battle_0017': {'event_predicate_0f'},
            'battle_0018': {'event_predicate_0f', 'event_predicate_12'},
            'battle_0025': {'event_predicate_0e', 'event_predicate_14'},
            **{f'battle_{index:04d}': {'event_predicate_04'} for index in range(28, 32)},
        })
        raw, _ = source('/VA2.BIN')
        entity = area_scene.entities(raw, area_scene.room_record(raw, entry['room']))[35]
        self.assertIn(entry['stream'], entity['stream_offsets'])
        self.assertEqual(raw[entry['request_offset']:entry['request_offset'] + 3], bytes.fromhex('47 00 fd'))
        opening_admissions = report['opening_admissions']
        expected_bands = [([58, 62], [52, 52]), ([74, 78], [52, 52]), ([62, 64], [32, 32])]
        for (id, admission), (x, y) in zip(opening_admissions.items(), expected_bands, strict=True):
            expected = bytes.fromhex('07 04 01 08 04 02 08 22 08') + bytes([11, *x, 12, *y, 6])
            offset = admission['predicate_offset']
            self.assertEqual(raw[offset:offset + len(expected)], expected, id)
            self.assertEqual(admission['inclusive_half_cells'], dict(x=x, y=y))
            self.assertEqual(admission['event_selection']['terms'][-2:], [
                dict(kind='coordinate_range', coordinate=dict(axis=axis, first=limits[0], last=limits[1]))
                for axis, limits in (('x', x), ('y', y))
            ])
            self.assertEqual(admission['story'][2], dict(byte_index=34, mask=8, required='clear'))
            self.assertEqual(admission['pre_effect'], dict(kind='story_or', byte_index=34, mask=8))
            lead_in = admission['lead_in']
            ops = [site['opcode'] for site in lead_in]
            self.assertEqual(ops, [raw[site['offset']] for site in lead_in], id)
            self.assertEqual(ops.count(0x02), 2, id)
            self.assertEqual(ops.count(0x17), 3, id)
            self.assertEqual(ops[-4:], [0x2f, 0x46, 0x09, 0x47], id)
            switch, wait_site, _, battle_site = lead_in[-4:]
            choice_site, = [site for site in lead_in if site['opcode'] == 0x05]
            self.assertEqual(raw[choice_site['offset']:switch['offset']], b'\x05\x00\x02\x01\x18')
            self.assertEqual(choice_site['choice'], dict(initial_row=0, rows=2, result='ui_mode'))
            self.assertEqual(raw[switch['offset']:switch['offset'] + 3], b'\x2f\x82\xfc')
            self.assertEqual(switch['ui_mode_targets'], {0: wait_site['offset'], 1: battle_site['offset'] + 3})
            self.assertEqual(raw[battle_site['offset'] + 2:battle_site['offset'] + 5], b'\xfd\xfc\x4d')
            alternate = battle_site['offset'] + 3
            self.assertEqual(raw[alternate:alternate + 8], b'\xfc\x4d\0\x0b\x10\x3c\x3b\xfd')
            self.assertEqual(switch['alternate_actions'], [
                dict(kind='advance_tile_variant', descriptor=11), dict(kind='align_hero', x=480, y=472),
            ])
            self.assertEqual(lead_in[-1]['offset'], {'va2_r00_e35_battle': 0x267F0,
                                                   'va2_r00_e36_battle': 0x2683E,
                                                   'va2_r00_e37_battle': 0x26893}[id])
            pans = [site['motion'] for site in lead_in if site['opcode'] == 0x08]
            duration = 40 if id == 'va2_r00_e35_battle' else 32
            self.assertEqual(pans, [dict(kind='pan', dx=0, dy=dy, updates=duration) for dy in (-1, 1)], id)
            timers = [site['motion']['updates'] for site in lead_in if site['opcode'] == 0x0A]
            self.assertEqual(timers, [50, 50, 25] if id == 'va2_r00_e37_battle' else [25, 25], id)
            for site in (site for site in lead_in if site['opcode'] == 0x10):
                cell_x, cell_y = raw[site['offset'] + 1:site['offset'] + 3]
                self.assertEqual(site['motion'], dict(kind='align_hero', x=cell_x * 8, y=cell_y * 8))
            portrait_sites = [site for site in lead_in if site['opcode'] == 0x12]
            self.assertEqual([raw[site['offset'] + 1:site['offset'] + 3] for site in portrait_sites],
                             [b'\x01\x7c', b'\x01\x7c', b'\x01\x08'], id)
            self.assertEqual([site['speaker'] for site in portrait_sites], [
                dict(slot=1, code=code, name_pointer=pointer, image_lookup='active_party')
                for code, pointer in ((0x7c, 0x8017055C), (0x7c, 0x8017055C), (8, None))
            ], id)
        word = lambda offset: struct.unpack_from('<I', raw, offset)[0]
        self.assertEqual(word(0x305C), 0x80035FEC)
        records = [word(0x25FEC + 4 * i) for i in range(10)]
        self.assertEqual(word(0x26014), 0)
        self.assertEqual([word(pointer - 0x80010000) for pointer in records],
                         [127, 128, 121, 125, 12, 31, 103, 200, 201, 202])
        import maindec
        self.assertEqual(maindec.mword(0x8013FB78), 0x34020008)
        self.assertEqual(maindec.mword(0x8013FB7C), 0x10A20007)
        self.assertEqual(maindec.mword(0x8013FBA4), 0x0C04FD61)
        self.assertEqual(maindec.mword(0x8013FA50), 0x2CA2006E)
        self.assertEqual(maindec.mword(0x80170778), 0x8017055C)
        self.assertEqual(maindec.mword(0x8013BDE0), 0x30635041)
        self.assertEqual(maindec.mword(0x8013BE00), 0x2C620040)
        self.assertEqual(maindec.mword(0x8013BE10), 0x34110001)
        self.assertEqual(maindec.mword(0x8013BF18), 0x2442FFFD)
        self.assertEqual(maindec.mword(0x8013BF38), 0x90A5C018)
        self.assertEqual(maindec.mword(0x8013BF5C), 0xA025BD6C)
        self.assertEqual(maindec.mword(0x8013A540), 0x9042BD6C)
        self.assertEqual(maindec.mword(0x8013B3EC), 0x0C04ECBD)
        self.assertEqual(maindec.mword(0x80138B90), 0x26100001)
        self.assertEqual(maindec.mword(0x8013CC94), 0x000318C0)  # Write duration * 8.
        self.assertEqual(maindec.mword(0x8013EDBC), 0x24E2FFFE)  # Consume two units per tick.
        self.assertEqual(maindec.mword(0x8013CCD8), 0x00031080)  # Write duration * 4 + duration.
        self.assertTrue(all(maindec.mword(addr) >> 26 != 0x2B for addr in range(0x8013EE04, 0x8013EE48, 4)))
        self.assertEqual(maindec.mword(0x800C1A00 + 8 * 4), 0x8013DD9C)
        self.assertEqual(maindec.mword(0x8013DDA0), 0x00002821)
        self.assertEqual(maindec.mword(0x8013DDA4), 0x0C04F5B3)
        self.assertEqual(maindec.mword(0x8013D714), 0x10400008)
        self.assertEqual(maindec.mword(0x8013D744), 0x1040FFFA)
        self.assertEqual(maindec.mword(0x8013DCF4), 0x0062102B)
        self.assertEqual(maindec.mword(0x8013DD20), 0x0062102B)
        self.assertEqual(maindec.mword(0x80171718 + 9 * 4), 0x8013CBBC)
        self.assertEqual(maindec.mword(0x8013CBF8), 0x00431025)
        self.assertEqual(maindec.mword(0x8013CC00), 0xA0820190)
        binding = entry['source_encounter']
        self.assertEqual((binding['section'], binding['entry'], binding['directory'], binding['outcome']),
                         (0, 11, '0x80050604', 'va2-s0-e11'))
        self.assertEqual(raw[0x26044:0x26048], bytes.fromhex('04060580'))
        self.assertEqual(raw[0x4060c:0x40610], bytes.fromhex('a8050580'))
        self.assertEqual(raw[0x405a8:0x405b0], bytes.fromhex('0100000078050580'))
        self.assertEqual(raw[0x40578:0x40588], bytes.fromhex('03000000030201000000000000000080'))
        encounter, = binding['encounters']
        self.assertFalse(encounter['escape_allowed'])
        self.assertEqual(encounter['enemy_names'], ['Empire Soldier'] * 3)
        self.assertEqual([slot['world'] for slot in encounter['slots']], [(-158, 50, 0), (-128, 0, 0), (-158, -50, 0)])
        self.assertEqual(entry['matching_layout_probe'], 'area_a_1')
        for row in report['source_entries']:
            if row['opening_entry']:
                self.assertEqual(row['source_encounter'], {
                    **binding, 'after_request': dict(offset=row['request_offset'] + 2, opcode=0xFD),
                })
        dragon = next(row for row in report['source_entries'] if row['id'] == 'battle_0027')['source_encounter']
        self.assertEqual((dragon['section'], dragon['entry'], dragon['directory']), (13, 2, '0x8008036c'))
        data, provenance = source('/VC61.BIN')
        self.assertEqual(dragon['directory_source'], dict(provenance, load_address='0x80080000'))
        self.assertEqual(struct.unpack_from('<6I', data, 0x36C),
                         (0x80073A1C, 0x80072454, 0x800803EC, 0x800803CC, 0x800720FC, 0x80073714))
        self.assertEqual(struct.unpack_from('<2I', data, 0x3EC), (1, 0x800803D4))
        self.assertEqual(data[0x3D8:0x3DE], bytes.fromhex('01 00 00 00 00 00'))
        self.assertEqual(data[0x3E0:0x3E4], bytes.fromhex('00 00 00 C0'))
        self.assertEqual(data[0x3F4:0x3FB], bytes.fromhex('2E 22 11 17 1F 1E 00'))
        boss, = dragon['encounters']
        self.assertEqual((boss['address'], boss['archive'], boss['escape_allowed'], boss['enemy_names']),
                         ('0x800803d4', 'boss', False, ['Dragon']))
        slot, = boss['slots']
        self.assertEqual(slot['world'], (-128, 0, 0))
        self.assertEqual((slot['actor_script_table'], slot['decision_callback']), ('0x80080674', '0x80012594'))
        self.assertEqual(struct.unpack_from('<3I', data, 0x41C), (0x80080674, 0x80080AA4, 0x80012594))
        code, _ = source('/VC6.BIN')
        self.assertEqual(code[0x26DC:0x26E8], bytes.fromhex('0180023c142742240c0042ae'))
        self.assertEqual(code[0x27A4:0x27B0], bytes.fromhex('0180023cc42742240c0002ae'))
        self.assertEqual(code[0x27F4:0x27FC], bytes.fromhex('1e000234641282ac'))
        # The ordinary loader indexes slot 7 of the companion's script table.
        finish = boss['ordinary_finish']
        self.assertEqual(struct.unpack_from('<I', data, 0x690)[0], 0x80080764)
        self.assertEqual(struct.unpack_from('<3H', data, 0x76E), (35, 0, 3))
        self.assertEqual(struct.unpack_from('<2H', data, 0x780), (3, 90))
        self.assertEqual(struct.unpack_from('<4H', data, 0x78C), (3, 1, 30, 99))
        self.assertEqual(maindec.mword(0x800E0C9C), 0x0C038B6B)
        self.assertEqual(maindec.mword(0x800E2E1C), 0x8C46001C)
        self.assertEqual(maindec.mword(0x800E2E58), 0xAC82002C)
        self.assertEqual(maindec.mword(0x8016BB7C), 0x800F1018)
        self.assertEqual(maindec.mword(0x800F7510), 0x90620045)
        self.assertEqual((finish['descriptor'], finish['effect_callback'], finish['waits'], finish['cleanup_state']),
                         ('0x80080764', '0x800f1018', [90, 1], 99))
        self.assertEqual(finish['completion'], dict(kind='live_count', remaining_enemies=0,
                                                   ready_after_updates=31, reward_gate='both_result_flags_clear'))
        self.assertEqual(code[0x3E1F2:0x3E1F8], bytes.fromhex('09 23 20 47 00 FD'))
        self.assertEqual(finish['field'], dict(before_request=dict(offset=0x3E1F2, story_byte=35, mask=32),
                                              after_request=dict(offset=0x3E1F7, opcode=0xFD)))
        changed = bytearray(code + data)
        changed[len(code) + 0x76E] = 36
        with self.assertRaisesRegex(ValueError, 'Dragon knockout descriptor changed'):
            campaign_coverage.dragon_ordinary_finish(changed, boss, 0x3E1F5)
        changed[len(code) + 0x76E] = 35
        changed[0x3E1F4] = 16
        with self.assertRaisesRegex(ValueError, 'Dragon field transition changed'):
            campaign_coverage.dragon_ordinary_finish(changed, boss, 0x3E1F5)

        field = next(row for row in report['scripted_battlefields'] if row['id'] == dragon['battlefield'])
        self.assertTrue(field['source']['file'].endswith('/VC6.BIN'))
        self.assertEqual((field['ground']['section_offset'], field['scenery']['section_offset']),
                         (0x63A1C, 0x62454))
        special = area_scene.entities(raw, area_scene.room_record(raw, 0))[42]
        self.assertIn(0x26420, special['stream_offsets'])
        self.assertEqual(raw[0x26430:0x26434], bytes.fromhex('47 ff 0b 03'))

        encounter = next(row for row in combat['encounters'] if row['id'] == entry['matching_layout_probe'])
        encounter['positions'][0]['x'] += 1
        report = campaign_coverage.battle_report(journey, combat)
        changed = next(row for row in report['source_entries'] if row['id'] == entry['id'])
        self.assertIsNone(changed['matching_layout_probe'])
        self.assertEqual(changed['source_encounter'], binding)

    def test_boss_knockout_and_encounter_finish_controls(self):
        from export_first_room import source
        from spell_scene_source import Image
        import character_table

        assets = campaign_coverage.ROOT / 'game/assets'
        outcomes = json.loads((assets / 'battle_systems/outcomes.json').read_text())
        _, knockouts, finishes = campaign_coverage.boss_sources(outcomes)
        expected = {
            'E087cabb581': ('VB8', 0x8002D424, 0x80029100),
            'E1297acc081': ('VB8', 0x8002B3A4, 0x80029100),
            'E709b118be5': ('VE1', 0x80067F7C, 0x800676E0),
            'E82ca8c3ea9': ('VC3', 0x80048958, 0x80041AC4),
            'E88b459cb7e': ('VE3', 0x8009E048, 0x8008B4D8),
            'E8b09f21d4e': ('VAC', 0x8007477C, 0x80073EE0),
            'Ebd6d7e0209': ('VF2', 0x8006B374, 0x8006B410),
            'Efc7641e48e': ('VB8', 0x8002975C, 0x80029100),
        }
        self.assertEqual(set(knockouts), set(expected))
        for boss_id, (overlay, table, descriptor) in expected.items():
            data, _ = source(f'/{overlay}.BIN')
            self.assertEqual(struct.unpack_from('<I', data, table - 0x80010000 + 28)[0], descriptor)
            self.assertEqual(knockouts[boss_id]['descriptor'], hex(descriptor))
            if overlay != 'VF2':
                self.assertEqual(data[descriptor - 0x80010000 + 32:descriptor - 0x80010000 + 38],
                                 bytes.fromhex('03 00 5a 00 08 00'))
                self.assertEqual(knockouts[boss_id]['waits'], [1, 90, 1])

        ordinary = {'vc3-s0-e6', 'vc3-s29-e2', 'vac-s28-e3'}
        self.assertEqual({key for key, rows in finishes.items() if rows[0]['kind'] == 'ordinary_live_count'}, ordinary)
        self.assertEqual(len(finishes), 8)
        for key in ('vb8-s0-e14', 'vb8-s1-e4'):
            self.assertEqual((finishes[key][0]['kind'], finishes[key][0]['round_at_least']),
                             ('round_end_without_rewards', 6))
        self.assertEqual(finishes['ve1-s0-e14'][0]['kind'], 'restores_boss_hp_and_clears_defeat_on_teardown')
        later_neclord = finishes['ve3-s20-e10'][0]
        self.assertEqual(later_neclord['element_coefficients_after'], [2, 2, 2, 2, 2, 1])
        self.assertEqual(next(row['name'] for row in character_table.records()
                              if row['id'] == later_neclord['actor_id']), 'Viktor')
        core = knockouts['Ebd6d7e0209']
        self.assertEqual((core['countdown'], core['rebind_at_remaining'], core['later_knockout']['descriptor']),
                         (60, 30, '0x80054fa4'))

        data, _ = source('/VF2.BIN')
        changed = bytearray(data)
        changed[0x44FA4] ^= 1
        with self.assertRaisesRegex(ValueError, 'replacement knockout descriptor changed'):
            campaign_coverage.boss_knockout(Image(changed, 0x80010000), 0x8006B374)
        data, _ = source('/VB8.BIN')
        changed = bytearray(data)
        changed[0x180] = 5
        with self.assertRaisesRegex(ValueError, 'finishing control changed'):
            campaign_coverage.boss_encounter_finish(Image(changed, 0x80010000), 0x8002ECB0)

    def test_battlefield_resources_follow_the_selected_directory(self):
        from export_first_room import source

        assets = campaign_coverage.ROOT / 'game/assets'
        graph = json.loads((assets / 'campaign/middle/battle_graph.json').read_text())
        outcomes = json.loads((assets / 'battle_systems/outcomes.json').read_text())
        bindings, fields = campaign_coverage.script_encounters(graph['entries'], outcomes)
        by_id = {row['id']: row for row in fields}
        opening = by_id[bindings['battle_0000']['battlefield']]
        forest = by_id[bindings['battle_0003']['battlefield']]
        self.assertEqual(bindings['battle_0005']['battlefield'], forest['id'])
        self.assertEqual(forest['directories'], ['0x800505b0', '0x800505e8', '0x800505cc'])
        self.assertEqual(len(forest['scenery']['placements']), 16)
        self.assertIsNone(opening['scenery'])

        raw, _ = source('/VA2.BIN')
        self.assertEqual(raw[0x40604:0x4060c], bytes.fromhex('a02d058000000000'))
        self.assertEqual(raw[0x40614:0x4061c], bytes.fromhex('64b2058000000000'))
        self.assertEqual(raw[0x42da0:0x42da6], bytes.fromhex('100010000407'))
        ground = opening['ground']
        self.assertEqual(ground['page_offsets'], [0x42DB8, 0x45278, 0x48080, 0x4AAC4])
        self.assertEqual(ground['tile_map_offset'], 0x42B24)
        self.assertEqual(ground['height_map_offset'], 0x4B264)
        codes = {int.from_bytes(raw[0x42B24 + i:0x42B26 + i], 'little') for i in range(0, 512, 2)}
        self.assertEqual({raw[0x42D50 + code] for code in codes}, {6})
        self.assertEqual(ground['used_palettes'], [6])
        self.assertEqual(ground['height_range'], [-144, 14])

        pirates = by_id[bindings['battle_0025']['battlefield']]
        self.assertEqual(pirates['ground']['used_palettes'], [0])
        self.assertEqual(len(pirates['ground']['palette_offsets']), 1)
        vb8, _ = source('/VB8.BIN')
        self.assertEqual(list(vb8[0x1EF04:0x1EF08]), [1, 0, 2, 2])

        regional = campaign_coverage.regional_battlefields()
        self.assertEqual(sum(row['encounter_count'] for row in regional), 90)
        area_a = next(row for row in regional if row['source']['file'].endswith('/A_DATA.BIN'))
        self.assertEqual(area_a['directory'], '0x80096650')
        self.assertEqual(area_a['ground']['used_palettes'], [5])
        self.assertEqual(area_a['ground']['height_map_offset'], 0x1C40C)
        self.assertEqual(len(area_a['scenery']['placements']), 20)

    def test_scripted_escape_returns_to_a_stream_exit_with_separate_teardown_effects(self):
        import character_table
        import maindec
        from export_first_room import source

        assets = campaign_coverage.ROOT / 'game/assets'
        graph = json.loads((assets / 'campaign/middle/battle_graph.json').read_text())
        outcomes = json.loads((assets / 'battle_systems/outcomes.json').read_text())
        bindings, _ = campaign_coverage.script_encounters(graph['entries'], outcomes)
        can_escape = {id: row for id, row in bindings.items() if any(enc['escape_allowed'] for enc in row['encounters'])}
        self.assertEqual(set(can_escape), {'battle_0013', 'battle_0024'})
        for id, overlay, offset, callback in (
            ('battle_0013', '/VA7.BIN', 0x250A2, '0x80010288'),
            ('battle_0024', '/VB6.BIN', 0x353EE, None),
        ):
            data, _ = source(overlay)
            self.assertEqual(data[offset:offset + 3], bytes.fromhex('4701fd'))
            row = can_escape[id]
            self.assertEqual(row['after_request'], dict(offset=offset + 2, opcode=0xFD))
            encounter, = row['encounters']
            self.assertEqual(encounter['teardown_callback'], callback)
            cleanup_word = encounter['auxiliary_offset'] + 0x10
            self.assertEqual(int.from_bytes(data[cleanup_word:cleanup_word + 4], 'little'), int(callback, 0) if callback else 0)

        va7, _ = source('/VA7.BIN')
        ted_fight, = can_escape['battle_0013']['encounters']
        self.assertEqual((ted_fight['round_callback'], ted_fight['command_setup_callback'],
                          ted_fight['initialization_callback']), ('0x800101c8', '0x8001019c', '0x80010268'))
        self.assertEqual(va7[0x318B0:0x318C0], bytes.fromhex('c80101809c0101806802018088020180'))
        self.assertEqual(va7[0x268:0x280], bytes.fromhex('a40b8294900f838ca60b82a41c00638c010002344c0062a0'))
        self.assertEqual(va7[0x1C8:0x1CC], bytes.fromhex('3c000234'))
        self.assertEqual(va7[0x234:0x238], bytes.fromhex('340082ac'))
        self.assertTrue(va7[4:].startswith(b'ted_exit_func\n\0'))
        self.assertEqual(va7[0x358:0x360], bytes.fromhex('200002344c0062a0'))
        self.assertEqual(va7[0x25096:0x250A2], bytes.fromhex('20fc0820fc0220fc0120fc06'))
        self.assertEqual([maindec.mword(0x8016A0E0 + index * 4) for index in (1, 32)], [0x8016A168, 0x8016A18C])
        actor_runes = {row['id']: row['rune_id'] for row in character_table.records()}
        self.assertEqual((actor_runes[8], actor_runes[108]), (0, 32))
        self.assertFalse(bindings['battle_0025']['encounters'][0]['escape_allowed'])
        self.assertEqual(bindings['battle_0025']['after_request']['opcode'], 9)

    def test_tracked_inventory_and_episode_are_distinct(self):
        value = campaign_coverage.write(verify=True)
        summary = value["summary"]
        self.assertEqual(summary["runtime_rooms"], 11)
        self.assertEqual(summary["runtime_source_overlays"], 1)
        self.assertEqual(summary["runtime_source_rooms"], 10)
        self.assertEqual(summary["runtime_authored_world_rooms"], 1)
        world=next(room for room in value["runtime_episode"]["rooms"] if room["id"]=="world_a")
        self.assertIsNone(world["source_room"])
        self.assertIsNone(world["source_file"])
        self.assertIn("authored prototype",world["state"])
        self.assertGreater(summary["distinct_loader_overlays"], summary["runtime_source_overlays"])
        self.assertEqual(summary["canonical_chapters_complete"], 0)
        self.assertEqual(value["campaign_progression"]["completed_blocks"], [])
        self.assertGreater(summary["unresolved_frontiers"], 0)
        self.assertIn("not campaign feasibility", value["source_inventory"]["scope"])
        room_ids = {room["id"] for room in value["runtime_episode"]["rooms"]}
        for encounter in value["runtime_episode"]["encounter_triggers"]:
            self.assertIn(encounter["room"], room_ids)
        self.assertIn("vb6_kobold_village", room_ids)
        connection=value['next_world_connection']
        self.assertTrue(connection['runtime_state'].startswith('active;'))
        self.assertEqual(connection['exit'],dict(region='region_c',camera_cells=dict(x=59,y=38)))
        self.assertEqual(connection['return_entrance']['spawn_pixels'],dict(x=352,y=216))
        self.assertEqual(connection['return_entrance']['source_point'],6)
        recruitment=value['next_recruitment_event']
        self.assertTrue(recruitment['runtime_state'].startswith('active;'))
        self.assertEqual(recruitment['character'],'maas')
        self.assertEqual(recruitment['eligibility']['minimum_recruitment_tier'],1)
        self.assertEqual(recruitment['join_growth']['level_advances'],17)




    def test_kobold_next_edge_has_original_point_and_exit_consumers(self):
        from test_worldmap_points import kobold_connection_cases
        self.assertEqual(len(kobold_connection_cases()),4)

    def assert_main_words(self, slices):
        import maindec

        for address, words in slices.items():
            self.assertEqual(
                tuple(maindec.mword(address + 4 * i) for i in range(len(words))),
                words, hex(address))

    def test_maas_candidate_eligibility_retains_recruit_flags_and_tier(self):
        import maindec
        from export_first_room import source
        import area_scene

        data, _ = source('/VB6.BIN')
        entity = area_scene.entities(data, area_scene.room_record(data, 10))[3]
        predicate = entity['stream_offsets'][1]
        self.assertEqual(data[predicate:predicate + 8], bytes.fromhex('114614ff01050600'))
        for opcode, arm in [(0x11, 0x8013DE6C), (0x14, 0x8013DEE8), (5, 0x8013DD74)]:
            self.assertEqual(maindec.mword(0x800C1A00 + 4 * opcode), arm)
        self.assert_main_words({
            # Resolve the classifier jump table, then read and mask the recruit byte.
            0x8013DC08: (0x00031080, 0x3C01800C, 0x24211A00, 0x00220821, 0x8C220000,
                         0, 0x00400008),
            0x8013DE6C: (0x26100001, 0x92030000, 0x3C028018, 0x8C42DB24, 0, 0x00621021,
                         0x90431AF4, 0, 0x30620001, 0x1440FF4D, 0x26100001, 0x0804F7E2,
                         0x30620002),
            0x8013DF88: (0x1040001E, 0x00001021, 0x0804F806, 0),
            # The following tier test reads the second operand and rejects if below it.
            0x8013DEE8: (0x3C028018, 0x8C42DB24, 0x26100002, 0x92030000, 0x90420034, 0,
                         0x0043102B, 0x1040003F, 0x26100001, 0x0804F806, 0x00001021),
            # Only a successful interaction service result reaches the 06 terminator.
            0x8013DD74: (0x0C04F4F3, 0x26100001, 0x0804F7FF, 0x304200FF),
            0x8013DFFC: (0x10400006, 0x00001021, 0x92030000, 0x34020006, 0x1462FEFB,
                         0x34020019, 0x34020001),
        })

    def test_maas_recruit_flag_set_and_explicit_toggle_are_distinct(self):
        self.assert_main_words({
            # Both forms consume one byte first. FF publishes a two-byte cursor and XORs bit 0.
            0x801396F0: (0x24820001, 0x3C018018, 0xAC22AF84, 0x90850000, 0x340200FF,
                         0x14A2000D, 0x24820002, 0x3C018018, 0xAC22AF84),
            0x8013971C: (0x90820001, 0, 0x00621821, 0x90621AF4, 0, 0x38420001,
                         0x0804E5E2, 0xA0621AF4),
            # Ordinary assignment clears a pending record before setting bit 0.
            0x8013974C: (0x90621AF4, 0, 0x30420002, 0x10400002, 0, 0xA0601AF4),
            0x80139770: (0x00651821, 0x90621AF4, 0, 0x34420001, 0x0C04E57F, 0xA0621AF4),
            # Its tier updater scans all 108 flags. Neither routine calls RNG.
            0x80139614: (0x90431AF4, 0, 0x30620001, 0x14400003, 0x30620002, 0x10400002, 0,
                         0x24A50001, 0x24840001, 0x2882006C, 0x1440FFF5),
        })
        import maindec
        from mipsdec import jtarget

        calls = []
        for address in range(0x801395FC, 0x80139798, 4):
            word = maindec.mword(address)
            if word >> 26 == 3:
                calls.append(jtarget(address, word))
        self.assertEqual(calls, [0x801395FC])

    def test_maas_post_join_selector_requests_a_position_preserving_field_refresh(self):
        import maindec

        self.assertEqual(maindec.mword(0x800C1AC0 + 4 * 21), 0x80141B68)
        self.assertEqual(maindec.mword(0x800C1B38 + 4 * 21), 0x80141CEC)
        self.assert_main_words({
            0x80141B68: (0x3C038018, 0x8C63DB24, 0, 0x906201B6, 0, 0x34420010,
                         0x08050713, 0xA06201B6),
            0x80141CEC: (0x3C028018, 0x8C42DB24, 0, 0x904201B6, 0x08050760, 0x30420010),
            # Refresh is taken only on completion, outside an active stream, with bit 0x10.
            0x80132C70: (0x8C63DC4C, 0x34020001, 0x1462001D, 0, 0x3C028017, 0x90421C28, 0,
                         0x14400018),
            0x80132CAC: (0x0C050717, 0x34040015, 0x1040000E, 0),
            0x80132CBC: (0x3C038018, 0x8C63DB24, 0x3C028018, 0x9042BD74, 0, 0xA4620004,
                         0x3C048018, 0x9084BD75, 0x906201B6, 0x34100002, 0xA4640006, 0x38420010,
                         0xA06201B6),
        })

    def test_maas_join_growth_uses_original_event_amount_and_target_record(self):
        import character_table
        from export_first_room import source
        from test_maas_recruitment import vectors

        data, _ = source('/VB6.BIN')
        self.assertEqual(data[0x35D19:0x35D21], bytes.fromhex('45464b0046114215'))
        base = character_table.IMAGE_OFF
        image = character_table.image()[base:base + 78 * 80]
        record_ids = [struct.unpack_from('<I', image, index * 80)[0] for index in range(78)]
        self.assertEqual([index for index, ident in enumerate(record_ids) if ident == 70], [65])
        self.assert_main_words({
            # Scan the 78 persistent records by ID, retaining the matched pointer.
            0x80138768: (0x308400FF, 0x24430294, 0x8C620000, 0, 0x10440006, 0x00601021,
                         0x24A50001, 0x28A2004E, 0x1440FFF9, 0x24630050),
            0x801390F4: (0x24620001, 0x3C018018, 0xAC22AF84, 0x90710000, 0x24620002,
                         0x3C018018, 0xAC22AF84, 0x90640001),
            0x80139134: (0x0C04E1D7, 0, 0x34040008, 0x0C04E1D7, 0x00409021),
            # Operation zero consumes its third byte as the number of growth iterations.
            0x8013914C: (0x1460000A, 0x00402021, 0x3C038018, 0x8C63AF84, 0, 0x24620001,
                         0x3C018018, 0xAC22AF84, 0x90700000, 0x0804E47E, 0x320200FF),
            0x801391E8: (0x0C03A731, 0x02402021, 0x2610FFFF, 0x320200FF, 0x1440FFFB, 0,
                         0x0C032983, 0x02402021),
            0x800E9CEC: (0x9262000D, 0, 0x2C420063, 0x1040005B),
            0x800E9D2C: (0x0C051F8E,),
            0x800E9DB0: (0x2A420006, 0x1440FFDA, 0x26310001),
            0x800E9DF0: (0x0C051F8E,),
            # The charge normalizer writes four bytes of the same record.
            0x800CA60C: (0xA0800008, 0x34060001, 0x3C078017, 0x24E7A60C, 0x90880014,
                         0x34030008, 0x24E50008, 0x90A20000, 0, 0x0048102A),
            0x800CA648: (0x00861021, 0x24630001, 0xA0430008, 0x24C60001, 0x28C20005,
                         0x1440FFF0, 0x24E70009),
        })
        retained = campaign_coverage.ROOT / 'game/tests/fixtures/maas_recruitment.json'
        self.assertEqual(vectors(), json.loads(retained.read_text()))


if __name__ == "__main__":
    unittest.main()
