#!/usr/bin/env python3
"""Static contract verification for the exported opening field slice (O01-O04, B16)."""
from __future__ import annotations

import json
import inspect
import copy
import struct
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "kit/tools"))

import export_opening_field_package as exporter  # noqa: E402
import room_battle_package as rbp  # noqa: E402
import maindec  # noqa: E402
import battle_placement  # noqa: E402
import export_route_battles  # noqa: E402


EXPECTED_ROOMS = [rid for _, _, rid in exporter.OPENING_ROOMS]


class OpeningFieldPackageTests(unittest.TestCase):
    def test_route_spell_atlas_compaction_preserves_pixels_and_offsets(self) -> None:
        image = Image.new("RGBA", (64, 4190))
        entries = [dict(x=0, y=0, w=32, h=64, dx=-17, dy=31),
                   dict(x=16, y=4126, w=48, h=64, dx=5, dy=-32)]
        for index, entry in enumerate(entries):
            for y in range(entry["h"]):
                for x in range(entry["w"]):
                    image.putpixel((entry["x"] + x, entry["y"] + y), (x, y, index, (x + y) % 256))
        expected = [image.crop((e["x"], e["y"], e["x"] + e["w"], e["y"] + e["h"])).tobytes() for e in entries]
        packed = export_route_battles._compact_spell_atlas(entries, image)
        self.assertLessEqual(max(packed.size), 4096)
        self.assertEqual([(e["dx"], e["dy"]) for e in entries], [(-17, 31), (5, -32)])
        for entry, pixels in zip(entries, expected, strict=True):
            self.assertEqual(packed.crop((entry["x"], entry["y"], entry["x"] + entry["w"], entry["y"] + entry["h"])).tobytes(), pixels)
        with self.assertRaisesRegex(ValueError, "outside source atlas"):
            export_route_battles._compact_spell_atlas([dict(x=63, y=0, w=2, h=1)], image)

    @classmethod
    def setUpClass(cls) -> None:
        cls.pkg_dir = ROOT / "kit/work/build/canonical"
        cls.fe_path = ROOT / "game/assets/campaign/opening/field_events.json"
        cls.fe = json.loads(cls.fe_path.read_text(encoding="utf-8"))
        cls.journey = json.loads((cls.pkg_dir / "journey.json").read_text(encoding="utf-8"))
        cls.rooms_by_id = {r["room"]: r for r in cls.fe["rooms"]}
        cls.room_pkg = json.loads((cls.pkg_dir / "room.json").read_text(encoding="utf-8"))
        cls.field_rooms = {r["id"]: r for r in cls.room_pkg["rooms"]}
        cls.trial = json.loads((cls.pkg_dir / "battle/trial.json").read_text(encoding="utf-8"))
        cls.ui = json.loads((cls.pkg_dir / "ui.json").read_text(encoding="utf-8"))

    def test_all_field_rooms_export_the_shared_static_scenery_model(self) -> None:
        from field_scenery import export_model, room_model, room_relocations, room_templates
        for binding in self.fe['rooms']:
            fname, number = exporter.ROOM_TO_SRC[binding['room']]
            data, _ = exporter.source(fname)
            room = self.field_rooms[binding['room']]
            model = room['scenery_model']
            self.assertEqual(model, room_model(data, number))
            rbp.validate_room_scenery(room, self.room_pkg['schema'])
            templates = room_templates(data, number)
            self.assertEqual(model['initial_count'] + len(templates) + len(room_relocations(data, number)),
                             len(model['objects']))
            static = export_model(data, number)
            self.assertEqual(model['objects'][:model['initial_count']], static['objects'])
            section = exporter.scene.section_off(data, exporter.scene.room_record(data, number)['section'])
            count = struct.unpack_from('<H', data, section + 0x24)[0]
            pointer = struct.unpack_from('<I', data, section + 0x28)[0]
            offset = pointer - exporter.scene.RAM_BASE
            expected = count if 0 <= offset < len(data) else 0
            self.assertEqual(model['initial_count'], expected)
            for index, obj in enumerate(model['objects'][:model['initial_count']]):
                x, y, kind, order, layer = struct.unpack_from('<5B', data, offset + index * 5)
                self.assertEqual((obj['x'], obj['y'], obj['layer'], obj['collides']), (x * 8, y * 8, layer, order not in (0, 1)))
                def pointer_at(address):
                    return struct.unpack_from('<I', data, address)[0] - exporter.scene.RAM_BASE
                context = pointer_at(pointer_at(section + 0x20))
                descriptor = pointer_at(pointer_at(context + 0x14) + kind * 4)
                sheet = pointer_at(pointer_at(context + 0x10) + data[descriptor + 4] * 4)
                width, height = data[sheet + 2] // 8, data[sheet + 3] // 8
                begin = sheet + 8 + data[sheet] * 8
                self.assertEqual((obj['width_cells'], obj['height_cells']), (width, height))
                self.assertEqual(obj['mask'], ''.join(str(value) for value in data[begin:begin + width * height]))
        castle = self.field_rooms['ve3_room_5']
        model = castle['scenery_model']
        opened = model['initial_count']
        self.assertEqual(model['objects'][opened], dict(model['objects'][1], x=160, y=16))
        original_draws = [draw for draw in castle['draws'] if draw.get('scenery_object') == 1]
        open_draws = [draw for draw in castle['draws'] if draw.get('scenery_object') == opened]
        self.assertTrue(open_draws)
        self.assertEqual([(draw['rect'], draw['x'] - 1840, draw['y'] - 1984) for draw in original_draws],
                         [(draw['rect'], draw['x'], draw['y']) for draw in open_draws])
        programs = {p['entity']: p for p in self.rooms_by_id['ve3_room_5']['content']['programs']}
        for entity in (3, 4):
            commands = [c for c in programs[entity]['commands'] if c['kind'] in ('scenery_append', 'scenery_stage')]
            self.assertEqual(commands, [{'kind': 'scenery_append', 'scenery_object': opened},
                                        {'kind': 'scenery_stage', 'scenery_object': 0}])
        sample = copy.deepcopy(self.field_rooms['va1_room_2'])
        with self.assertRaisesRegex(ValueError, 'room17'):
            rbp.validate_room_scenery(sample, rbp.WORLD_ENTRY_SCHEMA)
        sample['scenery_model']['terrain'] = sample['scenery_model']['terrain'][:-1]
        with self.assertRaisesRegex(ValueError, 'terrain'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_MODEL_SCHEMA)
        sample = copy.deepcopy(self.field_rooms['va1_room_2'])
        sample['scenery_model']['objects'][0]['collides'] = 1
        with self.assertRaisesRegex(ValueError, 'object'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_MODEL_SCHEMA)

    def test_scenery_draw_bindings_require_the_model_and_version(self) -> None:
        links = [(room, draw) for room in self.room_pkg['rooms'] for draw in room['draws'] if draw.get('scenery_object') is not None]
        self.assertEqual(sum(draw['scenery_object'] < room['scenery_model']['initial_count'] for room, draw in links), 22734)
        for room, draw in links:
            self.assertLess(draw['scenery_object'], len(room['scenery_model']['objects']))
            self.assertIsNone(draw.get('prop'))
        sample = copy.deepcopy(self.field_rooms['va1_room_2'])
        with self.assertRaisesRegex(ValueError, 'room18'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_MODEL_SCHEMA)
        draw = next(draw for draw in sample['draws'] if draw.get('scenery_object') is not None)
        draw['scenery_object'] = len(sample['scenery_model']['objects'])
        with self.assertRaisesRegex(ValueError, 'defined scenery object'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_DRAW_SCHEMA)
        draw['scenery_object'] = 0
        draw['prop'] = 0
        with self.assertRaisesRegex(ValueError, 'also be a prop'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_DRAW_SCHEMA)
        sample.pop('scenery_model')
        with self.assertRaisesRegex(ValueError, 'requires a scenery model'):
            rbp.validate_room_scenery(sample, rbp.SCENERY_DRAW_SCHEMA)

    def test_packet_shape_and_limits(self) -> None:
        self.assertEqual(self.fe["schema"], rbp.CURRENT_SCHEMA)
        self.assertLessEqual(self.fe_path.stat().st_size, rbp.MAX_BYTES)
        self.assertEqual([r["room"] for r in self.fe["rooms"]], EXPECTED_ROOMS)
        for room in self.fe["rooms"]:
            c, d, p = room["content"], room["dialogue"], room["population"]
            self.assertLessEqual(len(c["programs"]), 255)
            self.assertLessEqual(len(room["actors"]), 64)
            self.assertLessEqual(len(c["texts"]), 1024)
            self.assertLessEqual(len(d["anchors"]), 1024)
            self.assertLessEqual(len(d["prefixes"]), 1024)
            self.assertLessEqual(len(d["images"]), 64)
            prefix_indices = {entry["text"] for entry in d["prefixes"] if entry["text"] is not None}
            for prog in c["programs"]:
                self.assertLessEqual(len(prog["commands"]), 512)
                for idx, cmd in enumerate(prog["commands"]):
                    if cmd["kind"] == "text":
                        txt_idx = next(i for i, t in enumerate(c["texts"]) if t["id"] == cmd["text"])
                        self.assertNotIn(txt_idx, prefix_indices)
                    if cmd["kind"] in ("room_transition", "world_transition"):
                        if idx + 1 != len(prog["commands"]):
                            self.assertEqual(cmd["kind"], "room_transition")
                            self.assertEqual(prog["commands"][idx + 1]["kind"], "end_stream")
                            self.assertTrue(any(c["kind"] in ("branch_choice", "branch_castle_tier") for c in prog["commands"][:idx]))
                        if cmd.get('return_to_entry') or cmd.get('retain_world_region'):
                            self.assertIn(c['schema'], ('suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'))
                            self.assertNotIn('destination', cmd)
                        else:
                            self.assertIn(cmd["destination"], self.field_rooms)
            for txt in c["texts"]:
                for tok in txt["tokens"]:
                    if tok["kind"] in ("pace", "countdown"):
                        self.assertIn(tok["value"], range(256))
                    if tok["kind"] == "glyph":
                        self.assertEqual(len(tok["text"]), 1)
            if p["schema"] in ("suikoden-scene-population/3", "suikoden-scene-population/4"):
                self.assertGreaterEqual(len(p["entities"]), 0)
            else:
                self.assertGreater(len(p["entities"]), 0)

        frame = {'rect': {'x': 0, 'y': 0, 'w': 1, 'h': 1}, 'anchor_x': 0, 'anchor_y': 0, 'ticks': 1}
        clips = [{'direction': direction, 'idle_frame': 1, 'frames': [frame] * 4}
                 for direction in ('down', 'up', 'left', 'right')]
        bank = [{'character': index, 'id': f'character_{index}', 'clips': clips} for index in range(7)]
        rbp.validate_party_art(bank, (1, 1), expanded=True)
        with self.assertRaises(ValueError):
            rbp.validate_party_art(bank, (1, 1))
        bank[-1]['character'] = bank[0]['character']
        with self.assertRaises(ValueError):
            rbp.validate_party_art(bank, (1, 1), expanded=True)

    def test_camera_push_packet_capability_and_payload(self) -> None:
        packet = copy.deepcopy(self.fe)
        packet['rooms'] = [row for row in packet['rooms'] if row['content']['schema'] != 'suikoden-event-ir/29']
        for room in packet['rooms']:
            for program in room['content']['programs']:
                if any('facility' in command or command['kind'] == 'branch_party' for command in program['commands']):
                    program['commands'] = [{'kind': 'end_stream'}]
                    for key in ('anchors', 'prefixes', 'descriptor_changes'):
                        room['dialogue'][key] = [row for row in room['dialogue'].get(key, [])
                                                 if row['program'] != program['id']]
        kept = {row['room'] for row in packet['rooms']}
        packet['opening_world_exits'] = [ref for ref in packet['opening_world_exits'] if ref['room'] in kept]
        packet['opening_battles'] = [ref for ref in packet['opening_battles'] if ref['room'] in kept]
        packet['schema'] = 'suikoden-battle-field-events/51'
        room = next(row for row in packet['rooms'] if row['room'] == 'va4_room_6')
        room['content']['schema'] = 'suikoden-event-ir/28'
        room['population']['schema'] = 'suikoden-scene-population/3'
        room['content']['forward_branches'] = rbp.forward_graph(room['content'])
        for reference in room['population']['programs']:
            reference['namespace'] = room['content']['schema']
        inherited = next(row for row in packet['rooms'] if row['room'] == 'vb1_room_0')
        inherited['content']['schema'] = 'suikoden-event-ir/28'
        for reference in inherited['population']['programs']:
            reference['namespace'] = inherited['content']['schema']
        commands = next(program['commands'] for program in room['content']['programs'] if program['entity'] == 1)
        commands.insert(0, {'kind': 'camera_push', 'push': dict(dx=-16, dy=-8, updates=8, repeats=256),
                            'wait': dict(kind='camera_push', id='camera_push')})
        def check(value):
            return rbp._read_room_events(json.dumps(value).encode(), set(self.field_rooms),
                                        {encounter['id'] for encounter in self.trial['encounters']}, None, self.pkg_dir)
        check(packet)
        packet['schema'] = 'suikoden-battle-field-events/50'
        with self.assertRaisesRegex(ValueError, 'packet51'):
            check(packet)
        packet['schema'] = 'suikoden-battle-field-events/51'
        for bad in (dict(dx=True), dict(dx=24), dict(updates=7), dict(repeats=0), dict(repeats=257)):
            previous = dict(commands[0]['push'])
            commands[0]['push'].update(bad)
            with self.assertRaisesRegex(ValueError, 'camera push'):
                check(packet)
            commands[0]['push'] = previous
        commands[0]['wait']['id'] = 'other_clock'
        with self.assertRaisesRegex(ValueError, 'camera push'):
            check(packet)

    def test_constructor_guards_require_current_format_and_actor_initializer(self) -> None:
        pose = dict(rect=dict(x=0, y=0, w=8, h=8), anchor_x=4, anchor_y=8, ticks=1)
        command = dict(kind='place_actor', actor='test_visitor', x=40, y=32, if_actor_constructed=True)
        program = dict(id='test_initializer', entry='initialization', trigger='none',
                       commands=[dict(kind='continue_tick'), command, dict(kind='yield_tick'), dict(kind='end_stream')])
        binding = dict(room='test_room', actors=[dict(id='test_visitor', poses=[pose] * 4)],
                       content=dict(id='test_events', schema='suikoden-event-ir/29', forward_branches=True,
                                    actors=[dict(id='test_visitor')], programs=[program]),
                       population=dict(schema='suikoden-scene-population/3', programs=[], entities=[]))
        packet = dict(schema=rbp.CURRENT_SCHEMA, rooms=[binding])

        def check():
            return rbp._read_room_events(json.dumps(packet).encode(), {'test_room'}, set(), None, self.pkg_dir)

        self.assertEqual(check(), ([], False))
        packet['schema'] = 'suikoden-battle-field-events/52'
        with self.assertRaisesRegex(ValueError, 'constructor guards require the current field-event format'):
            check()
        packet['schema'] = rbp.CURRENT_SCHEMA
        program['entry'] = 'ordinary'
        with self.assertRaisesRegex(ValueError, 'invalid constructor-guarded actor command'):
            check()
        program['entry'] = 'initialization'
        command['actor'] = 'hero'
        with self.assertRaisesRegex(ValueError, 'invalid constructor-guarded actor command'):
            check()
        command['actor'] = 'test_visitor'
        command['if_actor_constructed'] = False
        with self.assertRaisesRegex(ValueError, 'invalid constructor-guarded actor command'):
            check()

    def test_standalone_save_points_bind_existing_placed_interactions(self) -> None:
        save_points = []
        for binding in self.fe['rooms']:
            for program in binding['content']['programs']:
                if (not any(command.get('facility') == 'save_point' for command in program['commands'])
                        or any(command['kind'] == 'choice' for command in program['commands'])):
                    continue
                self.assertEqual(program['trigger'], 'interaction')
                self.assertEqual(program['commands'], [{'kind': 'service', 'facility': 'save_point'}, {'kind': 'end_stream'}])
                entity = binding['population']['entities'][program['entity']]
                self.assertEqual(entity['position']['placement'], 'placed')
                self.assertEqual(entity['record_role'], 'event')
                self.assertEqual(entity['event']['program_id'], program['id'])
                fname, number = exporter.ROOM_TO_SRC[binding['room']]
                data, _ = exporter.source(fname)
                source_entity = exporter.scene.entities(data, exporter.scene.room_record(data, number))[program['entity']]
                self.assertEqual((source_entity['id'], source_entity['flags']), (0, 2))
                stream = source_entity['stream_offsets'][2]
                code = exporter.decode_stream(data, start=stream, max_insns=10)
                end = next(i for i, row in enumerate(code) if row[1] == 0xfd)
                self.assertEqual(code[end - 1][1:3], (0x43, b'\x07\xff'))
                save_points.append((binding['room'], program['entity']))
        self.assertIn(('vc5_room_0', 6), save_points)
        self.assertIn(('va1_room_2', 23), save_points)
        self.assertEqual(len(save_points), 16)

    def test_campaign_packet_compatibility(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = [Path(temporary) / name for name in ("base.json", "opening.json")]
            for path, version, room in zip(paths, (18, 21), ("base", "opening")):
                path.write_text(json.dumps({"schema": f"suikoden-battle-field-events/{version}", "rooms": [{"room": room}]}))
            merged = json.loads(rbp.combine_room_events(paths))
            self.assertEqual(merged["schema"], "suikoden-battle-field-events/21")
            self.assertEqual([r["room"] for r in merged["rooms"]], ["base", "opening"])
            paths[0].write_text(json.dumps({"schema": "suikoden-battle-field-events/17", "rooms": [{"room": "base"}]}))
            with self.assertRaisesRegex(ValueError, "same schema"):
                rbp.combine_room_events(paths)
        legacy = copy.deepcopy(self.fe)
        legacy["schema"] = "suikoden-battle-field-events/19"
        for room in legacy['rooms']:
            disabled = set()
            for program in room['content']['programs']:
                if any('facility' in command for command in program['commands']):
                    disabled.add(program['id'])
                    program['commands'] = [{'kind': 'end_stream'}]
            for field in ('anchors', 'prefixes'):
                room['dialogue'][field] = [row for row in room['dialogue'][field] if row['program'] not in disabled]
            if room['dialogue']['schema'] == 'suikoden-field-dialogue/9':
                room['dialogue']['schema'] = 'suikoden-field-dialogue/8'
                for anchor in room['dialogue']['anchors']:
                    if anchor.get('actor') == 'hero':
                        anchor.pop('actor')
                        anchor['point'] = dict(x=8, y=8)
                        program = next(p for p in room['content']['programs'] if p['id'] == anchor['program'])
                        command = program['commands'][anchor['command']]
                        command.pop('actor')
                        command['layout'] = 0
            if room['content']['schema'] not in ('suikoden-event-ir/17', 'suikoden-event-ir/26', 'suikoden-event-ir/27', 'suikoden-event-ir/28', 'suikoden-event-ir/29'):
                continue
            room['content']['schema'] = 'suikoden-event-ir/2'
            room['content'].pop('forward_branches', None)
            if room['dialogue']['schema'] == 'suikoden-field-dialogue/10':
                room['dialogue']['schema'] = 'suikoden-field-dialogue/8'
                for anchor in room['dialogue']['anchors']:
                    if anchor.pop('interaction_actor', None):
                        anchor['point'] = dict(x=8, y=8)
            for reference in room['population']['programs']:
                reference['namespace'] = 'suikoden-event-ir/2'
            for entity in room['population']['entities']:
                entity['classification']['terms'] = [term for term in entity['classification']['terms'] if term['kind'] in ('story_mask_set', 'story_mask_clear')]
            for program in room['content']['programs']:
                if any(command['kind'] == 'camera_push' for command in program['commands']):
                    program['commands'] = [{'kind': 'end_stream'}]
                if program['entry'] == 'initialization' and any(command['kind'] in ('place_actor', 'actor_transition', 'scenery_stage', 'scenery_append', 'set_camera') for command in program['commands']):
                    program['commands'] = [{'kind': 'end_stream'}]
                if program['entry'] == 'ordinary' and any(command['kind'] == 'place_actor' for command in program['commands']):
                    program['commands'] = [{'kind': 'end_stream'}]
                if program.pop('owner_actors', None) or program.pop('owner_actor', None):
                    entity = room['population']['entities'][program['entity']]
                    entity.update(record_role='character', population_candidate=True, source_character_id=255, resource_id='legacy_actor', resource_domain='area_character_context', classification={'pointer_state': 'present', 'terms': []})
                    entity['position'] = dict(source_x=1, source_y=1, x=8, y=8, placement='placed')
                for command in program['commands']:
                    if command['kind'] in ('fade_in', 'party_load', 'advance_character', 'recruit_mark_loaded'):
                        command.clear()
                        command['kind'] = 'label'
                        continue
                    command.pop('world_point', None)
                    command.pop('world_entry', None)
                    if command.pop('return_to_entry', False):
                        command.update(destination='world_a', x=73, y=49)
                    if command.pop('retain_world_region', False):
                        command['destination'] = 'world_a'
        with self.assertRaisesRegex(ValueError, "Soul Eater progression requires campaign schema 20"):
            rbp._read_room_events(json.dumps(legacy).encode(), set(self.field_rooms),
                                  {e["id"] for e in self.trial["encounters"]}, None, self.pkg_dir)
        legacy["schema"] = "suikoden-battle-field-events/18"
        for room in legacy["rooms"]:
            if room["content"]["schema"] == "suikoden-event-ir/2":
                room["content"]["schema"] = "suikoden-event-ir/1"
                room["population"]["schema"] = "suikoden-scene-population/2"
                for ref in room["population"]["programs"]:
                    ref["namespace"] = "suikoden-event-ir/1"
            if room["population"]["schema"] == "suikoden-scene-population/4":
                room["population"]["schema"] = "suikoden-scene-population/2"
            for entity in room["population"]["entities"]:
                if entity["record_role"] == "event" and entity["position"]["placement"] == "placed":
                    entity.update(record_role="character", population_candidate=True,
                                  source_character_id=255, resource_id="legacy_prop", resource_domain="area_character_context")
            for program in room["content"]["programs"]:
                for command in program["commands"]:
                    if command["kind"] in ("soul_eater_advance", "service", "chest_grant"):
                        command["kind"] = "label"
        with self.assertRaisesRegex(ValueError, "world transition requires campaign schema 19"):
            rbp._read_room_events(json.dumps(legacy).encode(), set(self.field_rooms),
                                  {e["id"] for e in self.trial["encounters"]}, None, self.pkg_dir)

    def test_toran_launch_requires_tai_ho_and_preserves_the_decline_path(self) -> None:
        for room_id, entity in (('vb5bg_room_0', 1), ('vb5cg_room_0', 2)):
            room = self.rooms_by_id[room_id]
            program = next(p for p in room['content']['programs'] if p['entity'] == entity)
            self.assertEqual(program['owner_actor'], f'{room_id}_actor_{entity:02}_020')
            commands = program['commands']
            branch_index = next(i for i, c in enumerate(commands) if c['kind'] == 'branch_choice')
            branch = commands[branch_index + 1]
            self.assertEqual((branch['kind'], branch['index']), ('branch_party', 32))
            missing_pilot, launch = branch['targets']
            decline = commands[branch_index]['target']
            self.assertLess(missing_pilot, decline)
            self.assertLess(decline, launch)
            for path in (commands[missing_pilot:decline], commands[decline:launch]):
                self.assertEqual(path[-1]['kind'], 'end_stream')
                self.assertTrue(all(c['kind'] not in ('story_or', 'world_mode', 'world_transition') for c in path))
            self.assertEqual(commands[-2:], [
                {'kind': 'world_mode', 'code': 12},
                {'kind': 'world_transition', 'destination': 'world_j', 'x': 100, 'y': 75},
            ])

    def test_fire_spears_and_return_boat_keep_their_source_handoffs(self) -> None:
        grant = next(p for p in self.rooms_by_id['vg3_room_1']['content']['programs'] if p['entity'] == 2)
        commands = grant['commands']
        index = next(i for i, c in enumerate(commands) if c['kind'] == 'shared_inventory_edit')
        item = commands[index]['inventory']
        self.assertEqual(item['give'], 'fire_spear')
        flag = {'kind': 'story_or', 'flag': {'id': 'scenario_0199', 'mask': 32}}
        self.assertIn(flag, commands[index + 1:item['failure_target']])
        self.assertNotIn(flag, commands[item['failure_target']:])

        departure = next(p for p in self.rooms_by_id['vg1_room_0']['content']['programs'] if p['entity'] == 43)
        commands = departure['commands']
        choice = next(c for c in commands if c['kind'] == 'branch_choice')
        self.assertEqual(commands[choice['target']], {'kind': 'end_stream'})
        data, _ = exporter.source('/VG1.BIN')
        self.assertEqual(commands[-2:], [
            {'kind': 'world_mode', 'code': data[0x29C1E]},
            {'kind': 'world_transition', 'destination': 'world_j', 'x': data[0x29C22], 'y': data[0x29C23]},
        ])

    def test_world_entry_metadata_and_entrances_match_source_rows(self) -> None:
        from area_data_select import area_table
        self.assertEqual(self.room_pkg['schema'], 'suikoden-room/18')
        self.assertEqual(self.room_pkg['initial_world_entry'], 'world_a_point_9')
        regions = {'world_' + Path(row['path']).name.removesuffix('_DATA.BIN').lower(): row['index'] for row in area_table()}
        entries = {row['id']: row for row in self.room_pkg['world_entries']}
        for entry in entries.values():
            pointer = maindec.mword(0x80170064 + 4 * regions[entry['world_room']])
            raw = maindec.body()[pointer - maindec.MBASE + 14 * entry['point']:pointer - maindec.MBASE + 14 * (entry['point'] + 1)]
            x, y = struct.unpack_from('<2H', raw, 2)
            self.assertEqual((entry['return_x'], entry['return_y']), ((x + 10) * 8, (y + 10) * 8))
        for world in self.field_rooms.values():
            for exit in world['exits']:
                if exit.get('world_entry') is None:
                    continue
                entry = entries[exit['world_entry']]
                pointer = maindec.mword(0x80170064 + 4 * regions[world['id']])
                raw = maindec.body()[pointer - maindec.MBASE + 14 * entry['point']:pointer - maindec.MBASE + 14 * (entry['point'] + 1)]
                kind, room, x, y, sx, sy = struct.unpack_from('<BBHHBB', raw)
                self.assertIn(kind, (0, 2))
                if kind == 2:
                    self.assertEqual(maindec.mword(0x8016F37C + 2 * 4), 0x80128740)
                    self.assertEqual(maindec.mword(0x8012874C), 0x904201A1)
                    self.assertEqual(maindec.mword(0x80128754), 0x30420001)
                    self.assertEqual(maindec.mword(0x8012875C), 0x38420001)
                    self.assertEqual(exit['conditions'], [{'kind': 'story_mask_clear', 'flag': {'id': 'scenario_0017', 'mask': 1}}])
                self.assertEqual((exit['x'], exit['y'], exit['w'], exit['h']), ((x + 10) * 8, (y + 8) * 8, 16, 16))
                self.assertEqual((exit['room'], exit['spawn_x'], exit['spawn_y']), (f"{entry['area']}_room_{room}", sx * 8, sy * 8))
        variants = [exit for exit in self.field_rooms['world_c']['exits'] if exit['world_entry'] in ('world_c_point_3', 'world_c_point_4')]
        self.assertEqual([exit['room'] for exit in variants], ['vc4_room_0', 'vc5_room_0'])
        self.assertEqual([(exit['x'], exit['y']) for exit in variants], [(variants[0]['x'], variants[0]['y'])] * 2)
        self.assertIsNone(variants[1].get('conditions'))
        malformed = copy.deepcopy(self.room_pkg)
        malformed['world_entries'][0]['return_x'] = self.field_rooms['world_a']['width']
        with self.assertRaisesRegex(ValueError, 'world entry return'):
            rbp.validate_world_entries(malformed)
        malformed = copy.deepcopy(self.room_pkg)
        malformed['initial_world_entry'] = 'unknown'
        with self.assertRaisesRegex(ValueError, 'initial world entry'):
            rbp.validate_world_entries(malformed)

    def test_region_c_audience_leaves_hero_on_the_exit_side(self) -> None:
        data, _ = exporter.source('/VC4.BIN')
        self.assertEqual(data[0x27D4E:0x27D55], bytes.fromhex('10 1d 14 09 12 04 fd'))
        program = next(p for p in self.rooms_by_id['vc4_room_11']['content']['programs'] if p['entity'] == 4)
        self.assertEqual(program['commands'][-3:], [
            {'kind': 'align_hero', 'x': 232, 'y': 160, 'wait': {'kind': 'alignment', 'id': 'alignment'}},
            {'kind': 'story_or', 'flag': {'id': 'scenario_0018', 'mask': 4}},
            {'kind': 'end_stream'},
        ])

    def test_valeria_recovers_hero_relative_growth_from_the_recruitment_scene(self) -> None:
        from maindec import mword
        data, _ = exporter.source('/VC4.BIN')
        self.assertEqual(data[0x27089:0x27092], bytes.fromhex('1f 00 4b 01 24 02 4a 00 24'))
        self.assertEqual(mword(0x8013919C), 0x9082000D)  # Read the hero record's level.
        self.assertEqual(mword(0x801391A8), 0x00431021)  # Add the remaining operand.
        programs = self.rooms_by_id['vc4_room_0']['content']['programs']
        commands = next(p['commands'] for p in programs if p['entity'] == 5)
        first = next(i for i, c in enumerate(commands) if c['kind'] == 'party_load')
        self.assertEqual(commands[first:first + 3], [
            {'kind': 'party_load', 'character': 'valeria'},
            {'kind': 'advance_character', 'character': 'valeria', 'level_advances': 2, 'add_hero_level': True},
            {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': 36}},
        ])

    def test_tigerwolf_arrival_returns_control_on_the_walkable_terrace(self) -> None:
        room = self.rooms_by_id['va9_room_0']
        programs = {p['entity']: p for p in room['content']['programs']}
        entrance = programs[0]['commands'][-2]
        self.assertEqual(programs[0]['commands'][-1], {'kind': 'end_stream'})
        self.assertEqual(entrance['kind'], 'place_hero')
        departure = next(c for c in programs[3]['commands'] if c['kind'] == 'align_hero')
        self.assertEqual((entrance['x'], entrance['y']), (departure['x'], departure['y']))
        field = self.field_rooms['va9_room_0']
        width = field['width'] // 8
        south_exit = programs[8]['selection'][1]['min']
        x, y = entrance['x'] // 8, entrance['y'] // 8
        self.assertTrue(all(field['walkable'][row * width + x] == '1'
                            for row in range(y, south_exit + 1)))

    def test_dragon_return_continues_when_milia_is_outside_the_party(self) -> None:
        from maindec import mword
        data, _ = exporter.source('/VF3.BIN')
        self.assertEqual(data[0x4860D:0x48612], bytes.fromhex('20 1d 45 ff 1d'))
        self.assertEqual(mword(0x8013A2C8), 0x16220010)  # Unmatched slot skips both removal calls.
        self.assertEqual(mword(0x8013A310), 0x2A420006)  # Scan all six slots.
        programs = self.rooms_by_id['vf3_room_2']['content']['programs']
        commands = next(p['commands'] for p in programs if p['entity'] == 9)
        self.assertEqual(commands[1:3], [
            {'kind': 'party_leave', 'character': 'milia', 'value': 1},
            {'kind': 'recruit_toggle', 'index': 29, 'mask': 1},
        ])

    def test_dragon_ride_home_uses_each_castle_tiers_dock(self) -> None:
        data, _ = exporter.source('/VF3.BIN')
        from event_script_reachability import callback_cursor
        self.assertEqual(callback_cursor(data, 0x47EEF)['operands'], 0)
        room = self.rooms_by_id['vf3_room_0']
        commands = next(p['commands'] for p in room['content']['programs'] if p['entity'] == 2)
        branch = next(c for c in commands if c['kind'] == 'branch_castle_tier')
        for target, dock, entry in zip(branch['targets'],
                ('vb5bg_room_0', 'vb5cg_room_0', 'vb5cg_room_0'),
                ('world_b_point_24', 'world_b_point_16', 'world_b_point_16'), strict=True):
            arrival = next(c for c in commands[target:] if c['kind'] == 'room_transition')
            self.assertEqual((arrival['destination'], arrival['world_entry']), (dock, entry))

    def test_moravia_briefing_keeps_the_morning_scene_handoff(self) -> None:
        room = self.rooms_by_id['vb5b4_room_3']
        programs = {p['entity']: p for p in room['content']['programs']}
        for entity, kind, xy in ((6, 'align_hero', (184, 96)),
                                 (7, 'place_hero', (40, 88)),
                                 (8, 'place_hero', (40, 88))):
            moves = [c for c in programs[entity]['commands'] if c['kind'] in ('align_hero', 'place_hero')]
            self.assertEqual((moves[-1]['kind'], moves[-1]['x'], moves[-1]['y']), (kind, *xy))

    def test_upgraded_dock_hands_off_to_the_shared_cinematic(self) -> None:
        dock = self.rooms_by_id['vb5cg_room_3']
        program = next(p for p in dock['content']['programs'] if p['entity'] == 10)
        transition = next(c for c in program['commands'] if c['kind'] == 'room_transition')
        self.assertEqual((transition['destination'], transition['world_point']), ('vb9_room_0', 43))
        cinematic = self.rooms_by_id[transition['destination']]
        scene = next(p for p in cinematic['content']['programs'] if p['entity'] == 3)
        self.assertIn('vb5c3_room_2', {c.get('destination') for c in scene['commands']})

    def test_final_dock_scene_marks_its_completion_and_returns_to_the_tier_council(self) -> None:
        dock, _ = exporter.source('/VB5BG.BIN')
        self.assertEqual(dock[0x49023:0x49026], bytes.fromhex('09 20 40'))
        self.assertEqual(dock[0x49030:0x49036], bytes.fromhex('03 fc 1a 05 ff ff'))
        staging, _ = exporter.source('/VB5B2.BIN')
        self.assertEqual(staging[0x3893F:0x38945], bytes.fromhex('03 fc 14 00 14 14'))
        self.assertEqual(staging[0x38A17:0x38A1D], bytes.fromhex('03 fc 1b 00 14 14'))
        program = next(p for p in self.rooms_by_id['vb5bg_room_0']['content']['programs'] if p['entity'] == 19)
        commands = program['commands']
        flag = {'id': 'scenario_0032', 'mask': 64}
        self.assertIn({'kind': 'story_mask_clear', 'flag': flag}, program['conditions'])
        branch = next(i for i, c in enumerate(commands) if c['kind'] == 'branch_castle_tier')
        self.assertIn({'kind': 'story_or', 'flag': flag}, commands[:branch])
        self.assertEqual([(commands[i]['destination'], commands[i]['world_point']) for i in commands[branch]['targets']],
                         [('vb5b3_room_0', 27), ('vb5c4_room_0', 20), ('vb5c4_room_0', 20)])

    def test_teo_rematch_unlocks_the_fourth_soul_eater_spell_before_leaving(self) -> None:
        from event_vm_semantics import handler_table
        source, _ = exporter.source('/VB7D.BIN')
        self.assertEqual(source[0xC728:0xC72A], bytes.fromhex('42 0f'))
        self.assertEqual(handler_table()[0x42], 0x801398F8)
        self.assertEqual(maindec.mword(0x800C1AFC), 0x80141AC4)
        self.assertEqual(maindec.mword(0x80141AD0), 0x94620018)
        self.assertEqual(maindec.mword(0x80141AD8), 0x24420001)
        self.assertEqual(maindec.mword(0x80141AE0), 0xA4620018)
        rematch = self.rooms_by_id['vb7d_room_1']
        program = next(p for p in rematch['content']['programs'] if p['entity'] == 3)
        kinds = [command['kind'] for command in program['commands']]
        self.assertEqual(kinds.count('soul_eater_advance'), 1)
        self.assertLess(kinds.index('soul_eater_advance'), kinds.index('room_transition'))

    def test_gregminster_arrival_walk_returns_control_on_the_street(self) -> None:
        source, _ = exporter.source('/VAC.BIN')
        self.assertEqual(source[0x4130D:0x41315], bytes.fromhex('07 80 01 65 07 80 02 78'))
        self.assertEqual(source[0x4133B:0x41340], bytes.fromhex('32 80 00 14 05'))
        programs = {p['entity']: p for p in self.rooms_by_id['vac_room_0']['content']['programs']}
        place = next(c for c in programs[14]['commands'] if c['kind'] == 'place_hero')
        align = next(c for c in programs[15]['commands'] if c['kind'] == 'align_hero')
        self.assertEqual((align['x'], align['y']), (place['x'], place['y'] - 20 * 8))
        self.assertEqual((align['x'], align['y']), (808, 800))

    def test_final_assault_musters_viktor_and_flik_before_party_selection(self) -> None:
        source, _ = exporter.source('/VAC.BIN')
        self.assertEqual(source[0x41380:0x41395], bytes.fromhex(
            '20 ff 1f ff 23 1f ff 11 4a 00 23 4a 00 11 09 19 01 43 ff 07 fd'))
        program = next(p for p in self.rooms_by_id['vac_room_0']['content']['programs'] if p['entity'] == 15)
        party = [c for c in program['commands'] if c['kind'] in ('party_dismiss', 'party_load', 'area_action', 'party_select')]
        self.assertEqual([c['kind'] for c in party],
                         ['party_dismiss', 'party_load', 'party_load', 'area_action', 'area_action', 'party_select'])
        self.assertEqual([c['character'] for c in party[1:3]], ['viktor', 'flik'])
        self.assertEqual([c['area'] for c in party[3:5]],
                         [{'kind': 'auxiliary_party_add', 'character': i} for i in (35, 17)])

    def test_dwarven_trail_and_village_keep_their_supported_walkways(self) -> None:
        from export_first_room import collision_sources, combine_ground, scenery_query, terrain_query, walkable_grid
        for filename, room, expected in [('/VC1.BIN', 7, 4), ('/VC2.BIN', 0, 7)]:
            data, _ = exporter.source(filename)
            section = exporter.scene.section_off(data, exporter.scene.room_record(data, room)['section'])
            width, _, ground = walkable_grid(data, section)
            objects = collision_sources(data, section)
            exported = self.field_rooms[f'{Path(filename).stem.lower()}_room_{room}']['walkable']
            differences = [(index % width, index // width) for index, (base, cell) in enumerate(zip(ground, exported, strict=True)) if base != cell]
            self.assertEqual(len(differences), expected)
            for x, y in differences:
                self.assertEqual(exported[y * width + x], '1')
                self.assertEqual(combine_ground(terrain_query(data, section, x, y), *scenery_query(objects, x, y, 1), 1), 0)

    def test_vault_switch_repositions_existing_barriers(self) -> None:
        room = self.rooms_by_id['vc3_room_5']
        initial = self.field_rooms['vc3_room_5']['scenery_model']['initial_count']
        programs = {p['entity']: p for p in room['content']['programs']}
        def effects(entity, kind):
            return [c['scenery_object'] - initial for c in programs[entity]['commands'] if c['kind'] == kind]
        self.assertEqual(effects(3, 'scenery_stage'), [0, 6, 9, 10])
        self.assertEqual(effects(2, 'scenery_restore'), effects(3, 'scenery_stage'))
        self.assertEqual(effects(7, 'scenery_stage'), [2, 4, 7])

    def test_vault_conveyors_wait_for_hero_movement(self) -> None:
        content = self.rooms_by_id['vc3_room_15']['content']
        tracks = {track['id']: track for track in content['tracks']}
        conveyors = [program for program in content['programs'] if any(c['kind'] == 'queue_track' for c in program['commands'])]
        self.assertEqual(len(conveyors), 14)
        for program in conveyors:
            commands = program['commands']
            movement = [i for i, command in enumerate(commands) if command['kind'] == 'queue_track']
            self.assertEqual(len(movement), 3)
            for i in movement:
                self.assertEqual(tracks[commands[i]['track']]['actor'], 'hero')
                self.assertEqual(commands[i + 1]['kind'], 'wait_tracks')
            self.assertIn(commands[-2]['kind'], ('story_or', 'story_andnot'))

    def test_vault_lock_clue_matches_plate_inputs_and_gate(self) -> None:
        room = self.rooms_by_id['vc3_room_21']
        content = room['content']
        programs = {p['entity']: p for p in content['programs']}
        text_id = next(c['text'] for c in programs[2]['commands'] if c['kind'] == 'text')
        text = next(text for text in content['texts'] if text['id'] == text_id)
        tokens = ''.join(t['text'] if t['kind'] == 'glyph' else '\n' for t in text['tokens'])
        solution = ' '.join(tokens.splitlines()[:2]).split()
        self.assertEqual(len(solution), 8)
        pattern = sum(('Left', 'Right').index(plate) << step for step, plate in enumerate(solution))
        flag = {'id': 'scenario_0023', 'mask': 255}
        for entity, plate in ((5, 0), (10, 1)):
            self.assertIn({'kind': 'sequence_input', 'flag': flag, 'parameter': pattern, 'value': plate},
                          programs[entity]['commands'])
        gate = next(c['scenery_object'] for c in programs[4]['commands'] if c['kind'] == 'scenery_append')
        self.assertIn({'kind': 'scenery_stage', 'scenery_object': gate}, programs[15]['commands'])

    def test_explicit_world_returns_use_region_files_and_source_camera_coordinates(self) -> None:
        from area_data_select import area_table
        regions = {row['index']: 'world_' + Path(row['path']).name.removesuffix('_DATA.BIN').lower()
                   for row in area_table() if row['path'] is not None}
        grids = {(name, 0): (room['width'] // 8, room['height'] // 8, room['walkable'])
                 for name, room in self.field_rooms.items() if name.startswith('world_')}
        self.assertEqual(maindec.mword(0x80127144), 0x24630008)
        self.assertEqual(maindec.mword(0x80127164), 0x24A5000A)
        for operands, expected in [([251, 1, 71, 32], ('world_b', (648, 320))),
                                   ([251, 0, 50, 101], ('world_a', (480, 872))),
                                   ([251, 1, 86, 4], ('world_b', (768, 96))),
                                   ([251, 1, 86, 85], ('world_b', (768, 744)))]:
            self.assertEqual(exporter.explicit_world_target(operands, regions, grids), expected)
        from event_script_reachability import loader_file_slots
        _, slots, _ = loader_file_slots()
        for filename, operands, expected in [('/VB1.BIN', [254, 86, 14], (96, 22)),
                                             ('/VA8.BIN', [254, 33, 49], (43, 57)),
                                             ('/VA8.BIN', [254, 22, 26], (32, 34))]:
            self.assertEqual(exporter.retained_world_return(operands, regions, grids, filename, slots),
                             dict(kind='world_transition', retain_world_region=True, x=expected[0], y=expected[1]))
        ambiguous = dict(grids)
        ambiguous[('world_z', 0)] = grids[('world_a', 0)]
        self.assertEqual(exporter.retained_world_return([254, 33, 49], regions, ambiguous, '/VA8.BIN', slots),
                         dict(kind='world_transition', retain_world_region=True, x=43, y=57))
        self.assertIsNone(exporter.retained_world_return([254, 255, 255], regions, ambiguous, '/VA8.BIN', slots))
        self.assertEqual(regions[9], 'world_j')
        self.assertEqual(regions[11], 'world_z')
        self.assertEqual(exporter.explicit_world_target([251, 11, 50, 101], regions, grids), ('world_z', (480, 872)))
        self.assertEqual(exporter.explicit_world_target([251, 9, 50, 101], regions, grids), ('world_j', (480, 872)))
        self.assertIsNone(exporter.explicit_world_target([251, 99, 50, 101], regions, grids))
        self.assertIsNone(exporter.explicit_world_target([251, 1, 255, 255], regions, grids))
        with self.assertRaisesRegex(ValueError, 'explicit world return'):
            exporter.explicit_world_target([255], regions, grids)
        for fields in ({'destination': 'world_a'}, {'return_to_entry': True}, {'x': 255}, {'retain_world_region': False}):
            malformed = copy.deepcopy(self.fe)
            binding = next(row for row in malformed['rooms'] if row['room'] == 'va8_room_0')
            command = next(program for program in binding['content']['programs'] if program['entity'] == 1)['commands'][-1]
            command.update(fields)
            with self.assertRaises(ValueError):
                rbp._read_room_events(json.dumps(malformed).encode(), set(self.field_rooms),
                                      {encounter['id'] for encounter in self.trial['encounters']}, None, self.pkg_dir)

    def test_cross_area_warps_use_loader_tables(self) -> None:
        from event_script_reachability import loader_file_slots
        _, slots, _ = loader_file_slots()
        for filename, index, target in [('/VAA.BIN', 3, 'va4_room_0'),
                                        ('/VAA.BIN', 0, 'va1_room_0'),
                                        ('/VA1.BIN', 9, 'vaa_room_0'),
                                        ('/VA4.BIN', 9, 'vaa_room_0')]:
            self.assertEqual(exporter.cross_area_room(filename, index, 0, slots), target)
        self.assertEqual(exporter.cross_area_room('/VAA.BIN', 3, 2, slots), 'va4_room_2')
        ambiguous = slots + [dict(region=99, index=0, file='DATA/01_AREA.A/VAA.BIN'),
                             dict(region=99, index=3, file='DATA/01_AREA.A/VA2.BIN')]
        self.assertIsNone(exporter.cross_area_room('/VAA.BIN', 3, 0, ambiguous))
    def test_optional_facilities_bind_only_reachable_callers(self) -> None:
        for room, index, facility in [('va1_room_2', 23, 'save_point'), ('va2_room_0', 42, 'cup_game'),
                                      ('vb5c3_room_0', 11, 'card_game'), ('vb5c3_room_0', 12, 'cup_game'),
                                      ('vb5c3_room_0', 7, 'library'), ('vb5c3_room_0', 18, 'library'),
                                      ('vb5ca_room_3', 5, 'window_styles'), ('vb5ba_room_3', 4, 'sound_themes'),
                                      ('vb5ca_room_3', 4, 'sound_themes'), ('vb5a1_room_1', 2, 'music_player')]:
            binding = self.rooms_by_id[room]
            entity = binding['population']['entities'][index]
            self.assertEqual(entity['event']['status'], 'resolved')
            program = next(p for p in binding['content']['programs'] if p['id'] == entity['event']['program_id'])
            self.assertEqual(program['commands'][-2], {'kind': 'service', 'facility': facility})
        greeting = next(p for p in self.rooms_by_id['va2_room_0']['content']['programs'] if p['entity'] == 12)
        self.assertFalse(any(c.get('facility') for c in greeting['commands']))

    def test_field_service_inventory_matches_the_current_packet(self) -> None:
        from audit_field_services import audit
        inventory = audit(self.fe_path.read_bytes())
        saved = json.loads((ROOT / 'kit/data/reports/field_service_inventory.json').read_text())
        self.assertEqual(inventory, saved)
        self.assertEqual(inventory['interactions_with_frontiers'], 0)
        self.assertTrue(all(row['facility'] for row in inventory['interactions']
                            if row['requests'] or row.get('special_content')))
        self.assertTrue(all(caller['package_event_status'] == 'resolved'
                            for game in inventory['catalogued_minigames'] for caller in game['callers']))

    def test_kasios_music_indices_match_the_hq_dispatch_table(self) -> None:
        from jukebox_music import AUTHORED, playlist_indices
        data, _ = exporter.source('DATA/03_SHIRO/SD_TEST.BIN')
        dispatch = tuple(request & 0xff for request, _ in struct.iter_unpack('<II', data[0x7640:0x76c0]))
        self.assertEqual(dispatch, (4, 5, 7, 9, 10, 12, 15, 17, 18, 21, 22, 23, 24, 25, 26, 27))
        self.assertEqual(playlist_indices(), dispatch)
        self.assertTrue(AUTHORED.keys() <= set(dispatch))

    def test_kimberly_recruitment_advances_the_record_with_no_party_insert(self) -> None:
        data, _ = exporter.source('/VD1.BIN')
        self.assertEqual(data[0x4b14b:0x4b151], bytes.fromhex('45 2d 4b 00 2d 10'))
        self.assertEqual(maindec.mword(0x801391e8), 0x0c03a731)
        self.assertEqual(maindec.mword(0x80139200), 0x0c032983)
        commands = next(p['commands'] for p in self.rooms_by_id['vd1_room_1']['content']['programs']
                        if p['id'] == 'vd1_room_1_e00_interaction')
        self.assertEqual(commands[-3:], [
            {'kind': 'recruit_toggle', 'index': 45},
            {'kind': 'advance_character', 'character': 'kimberly', 'level_advances': 16},
            {'kind': 'end_stream'},
        ])

    def test_soniere_passage_switch_swaps_both_scenery_pairs(self) -> None:
        raw, _ = exporter.source('/VD5.BIN')
        binding = self.rooms_by_id['vd5_room_1']
        scenery = self.field_rooms['vd5_room_1']['scenery_model']['objects']
        for entity, start, end, operation in (
            (13, 0x4aee0, 0x4aeff, 'story_or'),
            (14, 0x4af00, 0x4af21, 'story_andnot'),
        ):
            instructions = exporter.decode_stream(raw, start, max_insns=12)
            source_pair = []
            for offset, opcode, args, _ in instructions:
                if offset >= end:
                    break
                if opcode == 0x40:
                    selector, slot, x, y = args
                    self.assertEqual(selector, 0xfe)
                    self.assertEqual((scenery[slot]['x'], scenery[slot]['y']), (x * 8, y * 8))
                    source_pair.append(('scenery_restore', slot))
                elif opcode == 0x0f:
                    source_pair.append(('scenery_stage', args[0]))
            program = next(p for p in binding['content']['programs'] if p['entity'] == entity)
            commands = program['commands']
            self.assertIn({'kind': operation, 'flag': {'id': 'scenario_0196', 'mask': 8}}, commands)
            self.assertEqual(len(source_pair), 4)
            self.assertEqual([(c['kind'], c['scenery_object']) for c in commands if 'scenery_object' in c],
                             source_pair)

    def test_soniere_cell_doors_rebuild_from_their_story_state(self) -> None:
        raw, _ = exporter.source('/VD5.BIN')
        room = self.rooms_by_id['vd5_room_7']
        programs = {p['entity']: p for p in room['content']['programs']}
        for closed, opened, ordinary in ((17, 18, 0), (19, 20, 2), (21, 22, 5), (23, 24, 11), (25, 26, 8)):
            for entity in (closed, opened):
                offset = 0x4b160 + (entity - 17) * 12
                self.assertEqual(raw[offset:offset + 3], b'\x30\x40\xfe')
                self.assertEqual(raw[offset + 6], 0x0f)
                self.assertEqual(programs[entity]['commands'][1],
                                 {'kind': 'scenery_stage', 'scenery_object': raw[offset + 7]})
            self.assertEqual([c for c in programs[ordinary]['commands'] if 'scenery_object' in c], [
                {'kind': 'scenery_restore', 'scenery_object': opened - 17},
                {'kind': 'scenery_stage', 'scenery_object': closed - 17},
            ])

    def test_soniere_escape_preserves_the_inventory_and_castle_handoffs(self) -> None:
        raw, _ = exporter.source('/VD5.BIN')
        self.assertEqual(raw[0x4ae4c:0x4ae56], bytes.fromhex('50 02 02 20 fe 02 42 0f 20 ff'))
        commands = next(p['commands'] for p in self.rooms_by_id['vd5_room_1']['content']['programs']
                        if p['entity'] == 0)
        for effect in (
            {'kind': 'warehouse_deposit', 'character': 'gremio'},
            {'kind': 'recruit_toggle', 'index': 2, 'mask': 2},
            {'kind': 'soul_eater_advance'},
            {'kind': 'party_dismiss'},
        ):
            self.assertIn(effect, commands)
        branch = next(c for c in commands if c['kind'] == 'branch_castle_tier')
        self.assertEqual([commands[i]['destination'] for i in branch['targets']],
                         ['vb5b4_room_3', 'vb5c4_room_3', 'vb5c4_room_7'])
        self.assertTrue(all(commands[i + 1]['kind'] == 'end_stream' for i in branch['targets']))

    def test_library_callback_collects_the_eight_bound_book_items(self) -> None:
        data, _ = exporter.source('/VB5C3.BIN')
        entity = exporter.scene.entities(data, exporter.scene.room_record(data, 0))[18]
        entry = entity['stream_offsets'][2]
        self.assertEqual(data[entry:entry + 4], bytes.fromhex('43 80 07 fd'))
        books, proof = exporter.source('DATA/03_SHIRO/BOOKS.BIN')
        self.assertEqual((proof['lba'], proof['size']), exporter.service_extent('BOOKS'))
        ledger = json.loads((ROOT / 'game/assets/campaign_policies/item_shared_ledger.json').read_text())
        for index, item_id in enumerate(struct.unpack_from('<8I', books, 0x3dcc)):
            item = next(row for row in ledger['items'] if row['source_item_id'] == item_id)
            self.assertEqual((item['id'], item['ownership']), (f'old_book_vol_{index + 1}', 'shared_key'))
            self.assertEqual(books[0x3df0 + index], 1 << index)
        self.assertEqual(struct.unpack_from('<I', books, 0x198)[0], 0xa0820035)
        self.assertEqual(struct.unpack_from('<I', books, 0xb68)[0], 0x90620035)
        self.assertEqual(maindec.mword(0x80165608 + 0x170), 0x800ca408)

    def test_window_selector_collects_sets_and_saves_two_preferences(self) -> None:
        data, _ = exporter.source('DATA/03_SHIRO/WIN_SEL.BIN')
        self.assertEqual(list(struct.iter_unpack('<HBB', data[0x3dc8:0x3dd8])),
                         [(95, 36, 0), (96, 36, 1), (97, 36, 2), (98, 36, 3)])
        words = {0x0754: 0xa0621b7c, 0x076c: 0xa0621b7d, 0x0ec0: 0xa0830190, 0x0f1c: 0x90420190,
                 0x2420: 0x34030005, 0x28e8: 0x24440007}
        for offset, word in words.items():
            self.assertEqual(struct.unpack_from('<I', data, offset)[0], word)

    def test_melodye_selector_sets_availability_and_keeps_the_confirmed_bank(self) -> None:
        data, _ = exporter.source('DATA/03_SHIRO/MEL_SEL.BIN')
        self.assertEqual(list(struct.iter_unpack('<HBB', data[0x3d1c:0x3d2c])),
                         [(91, 36, 4), (92, 36, 5), (93, 36, 6), (94, 36, 7)])
        self.assertEqual(struct.unpack_from('<5H', data, 0x3d54), (33, 34, 35, 36, 77))
        words = {0x00d8: 0x90441b7e, 0x092c: 0xa0831b7e, 0x0e88: 0xa0830190, 0x0ee4: 0x90420190,
                 0x2368: 0xac30e9a4, 0x237c: 0x0040f809, 0x23f4: 0x34030005}
        for offset, word in words.items():
            self.assertEqual(struct.unpack_from('<I', data, offset)[0], word)

    def test_field_recovery_offers_keep_the_three_source_outcomes(self) -> None:
        from event_script_decode import switch_2f_targets
        from event_script_reachability import walk
        for room, index, branch, expected in (
            ('vf3_room_1', 4, 0x480fa, ('party_restore', 'end_stream', 'service')),
            ('vh1_room_1', 5, 0x497a3, ('end_stream', 'service', 'party_restore')),
        ):
            fname, _ = exporter.ROOM_TO_SRC[room]
            data, _ = exporter.source(fname)
            result = []
            for start in switch_2f_targets(data, branch).values():
                instructions = [data[row['offset']:row.get('end', row['offset'] + 1)] for row in walk(data, [start])['nodes']]
                proof = {b'\x4c\x02\x00': 'party_restore', b'\x43\x07\xff': 'service'}
                effects = [proof[raw] for raw in instructions if raw in proof]
                result.append(effects[0] if effects else 'end_stream')
            self.assertEqual(tuple(result), expected)
            program = next(pr for pr in self.rooms_by_id[room]['content']['programs'] if pr['entity'] == index)
            for i, cmd in enumerate(program['commands']):
                if cmd['kind'] == 'branch_choice':
                    self.assertEqual(tuple(program['commands'][target]['kind'] for target in (i + 1, *cmd['targets'])), expected)
                    break
            else:
                self.fail(f'{room} lacks its recovery choice')

    def test_closed_inn_variants_preserve_interaction_without_saving(self) -> None:
        for room, indices in (('va3_room_2', (10, 26, 27)), ('vz3_room_2', (4,))):
            binding = self.rooms_by_id[room]
            for index in indices:
                entity = binding['population']['entities'][index]
                program = next(p for p in binding['content']['programs'] if p['entity'] == index)
                self.assertEqual(entity['event']['status'], 'resolved')
                self.assertEqual([c['kind'] for c in program['commands']],
                                 ['open_box', 'wait_boxes', 'text', 'wait_for_accept', 'close_box', 'wait_boxes', 'end_stream'])

    def test_scripted_battles_resolve_section_tables_and_require_exported_capabilities(self) -> None:
        import maindec
        for pc, word in {0x801394F8: 0x8CA2001C, 0x80139500: 0x00622021,
                         0x80139558: 0x00041080, 0x8013957C: 0x8CA30020,
                         0x80139588: 0x8C430000, 0x80139594: 0x0C04B2EF}.items():
            self.assertEqual(maindec.mword(pc), word)
        spells = json.loads((self.pkg_dir / 'battle/spells.json').read_text())
        battle_data = (self.trial, spells)
        cases = [('/VB1.BIN', 5, 0, 0x3A2F8, 'vb1_school'),
                 ('/VA3.BIN', 1, 0, 0x51EF8, 'va3_raid'),
                 ('/VA2.BIN', 3, 0, 0x405B0, 'va2_rescue_pair'),
                 ('/VA2.BIN', 3, 1, 0x405E8, 'va2_rescue_squad'),
                 ('/VA2.BIN', 0, 0, 0x40604, 'va2_s0_e11'),
                 ('/VA4.BIN', 3, 0, 0x67554, 'va4_golem'),
                 ('/VA7.BIN', 9, 0, 0x5BDF8, 'va7_r9_b0'),
                 ('/VA7.BIN', 9, 1, 0x5BE14, 'va7_r9_b1'),
                 ('/VA7.BIN', 13, 0, 0x5BE4C, 'va7_r13_b0'),
                 ('/VA7.BIN', 13, 1, 0x5BE30, 'va7_r13_b1')]
        for filename, room, selector, expected, identifier in cases:
            data, _ = exporter.source(filename)
            record = exporter.scene.room_record(data, room)
            section = exporter.scene.section_off(data, record['section'])
            count, table = struct.unpack_from('<2I', data, section + 28)
            directory, = struct.unpack_from('<I', data, table - 0x80010000 + 4 * (count + selector))
            self.assertEqual(directory - 0x80010000, expected)
            self.assertEqual(battle_placement.scripted_directory(data, section, selector, 0x80010000), expected)
            self.assertEqual(export_route_battles.scripted_encounter(data, section, selector, filename, battle_data), identifier)
        absent = copy.deepcopy(self.trial)
        absent['encounters'] = [row for row in absent['encounters'] if row['id'] != identifier]
        self.assertIsNone(export_route_battles.scripted_encounter(data, section, selector, filename, (absent, spells)))
        self.assertIsNone(export_route_battles.scripted_encounter(data, section, selector, filename, (self.trial, {'hurt_poses': []})))
        wrong = copy.deepcopy(self.trial)
        next(row for row in wrong['encounters'] if row['id'] == identifier)['positions'][0]['x'] += 1
        with self.assertRaisesRegex(ValueError, 'positions disagree'):
            export_route_battles.scripted_encounter(data, section, selector, filename, (wrong, spells))
        with self.assertRaisesRegex(ValueError, 'special forced-battle selector'):
            battle_placement.scripted_directory(data, section, 255, 0x80010000)

    def test_props_keep_source_positions_without_character_resources(self) -> None:
        props = []
        for room in self.fe["rooms"]:
            for entity in room["population"]["entities"]:
                if entity["record_role"] != "event" or entity["position"]["placement"] != "placed":
                    continue
                props.append(entity)
                source = room["population"]["source"]
                data, _ = exporter.source('/' + source['file'].rsplit('/', 1)[-1])
                record = exporter.scene.room_record(data, source['room'])
                if entity['source_order'] < record['entity_count']:
                    offset = record['entity_off'] + 24 * entity['source_order']
                    x, y, flags, raw_cid = struct.unpack_from('<4H', data, offset)
                    self.assertEqual(raw_cid and (flags & 0x101), 0)
                    self.assertEqual((entity['position']['x'], entity['position']['y']), (x * 8, y * 8))
                else:
                    self.assertEqual(entity['event']['reference'], 'vb5a2_room_0_overnight_authored')
                    ground = self.field_rooms[room['room']]
                    width = ground['width'] // 8
                    position = entity['position']
                    self.assertEqual(ground['walkable'][position['source_y'] * width + position['source_x']], '1')
                self.assertEqual(room["population"]["schema"], "suikoden-scene-population/4")
                self.assertEqual(entity["trigger"], "interaction")
                self.assertFalse(entity["population_candidate"])
                for key in ("source_character_id", "resource_id", "resource_domain"):
                    self.assertIsNone(entity[key])
                self.assertFalse(any(actor["entity"] == entity["source_order"] for actor in room["actors"]))
        self.assertGreater(len(props), 0)
        for index in (2, 3, 4):
            bed = self.rooms_by_id["va1_room_3"]["population"]["entities"][index]
            self.assertEqual(bed["record_role"], "event")
            self.assertEqual((bed["position"]["x"], bed["position"]["y"]), (192, 248))
        gremio = self.rooms_by_id["va1_room_1"]["population"]["entities"][5]
        self.assertEqual(gremio["source_character_id"], 2)

    def test_lenankamp_final_raid_and_odessa_handoff(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        programs = {p["entity"]: p for p in self.rooms_by_id["va3_room_1"]["content"]["programs"]}
        approach, soldier, odessa = (programs[i] for i in (26, 35, 39))
        self.assertEqual(data[0x29A54:0x29A57], bytes((9, 9, 128)))
        self.assertIn({"kind": "align_hero", "x": 320, "y": 424, "wait": {"kind": "alignment", "id": "alignment"}}, approach["commands"])
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0009", "mask": 128}}, approach["commands"])
        self.assertEqual(data[0x29EA8:0x29EB0], bytes.fromhex("09 0a 01 41 07 47 00 fd"))
        self.assertEqual([c["battle"] for c in soldier["commands"] if c["kind"] == "battle"], ["va3_raid"])
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0010", "mask": 1}}, soldier["commands"])
        self.assertEqual(data[0x29BEE:0x29BF1], bytes((0x50, 0, 85)))
        self.assertEqual(maindec.mword(0x80138918), 0x0C032943)  # Shared append.
        self.assertEqual(maindec.mword(0x80138920), 0x0804E276)  # Return without branching on append result.
        item_index, = [i for i, c in enumerate(odessa["commands"]) if c.get("inventory", {}).get("give") == "earrings"]
        flag_index, = [i for i, c in enumerate(odessa["commands"]) if c.get("flag") == {"id": "scenario_0010", "mask": 2}]
        advance_index, = [i for i, c in enumerate(odessa["commands"]) if c["kind"] == "soul_eater_advance"]
        self.assertLess(item_index, flag_index)
        self.assertEqual(advance_index, flag_index + 1)
        self.assertEqual(odessa["commands"][-1], {"kind": "room_transition", "destination": "va3_room_2", "x": 248, "y": 248})
        self.assertEqual(data[0x29D14:0x29D1D], bytes.fromhex("09 0a 02 42 0f 03 02 1f 1f"))
        rune_record = maindec.mword(0x8016A0E4)
        self.assertEqual(maindec.mword(rune_record + 24) & 0xFFFF, 1)
        self.assertEqual(maindec.mword(0x800C1AC0 + 15 * 4), 0x80141AC4)
        self.assertEqual(maindec.mword(0x80141AC8), 0x8C63A0E4)  # Soul Eater record pointer.
        self.assertEqual(maindec.mword(0x80141AD0), 0x94620018)  # Read spell count.
        self.assertEqual(maindec.mword(0x80141AD8), 0x24420001)  # Increment once.
        self.assertEqual(maindec.mword(0x80141AE0), 0xA4620018)  # Store spell count.
        ledger = json.loads((ROOT / "game/assets/campaign_policies/item_shared_ledger.json").read_text())
        records = ledger if isinstance(ledger, list) else ledger["items"]
        item, = [r for r in records if r["source_item_id"] == 85]
        self.assertEqual((item["id"], item["ownership"]), ("earrings", "shared_key"))

    def test_seika_entrance_mathiu_and_source_actor_aliases(self) -> None:
        data, origin = exporter.source("/VB1.BIN")
        table = maindec.mword(0x80170068)
        point = maindec.body()[table - maindec.MBASE:table - maindec.MBASE + 14]
        self.assertEqual(point[:8], bytes.fromhex("00 00 56 00 0c 00 20 4a"))
        descriptor = maindec.mword(maindec.mword(0x8016F680))
        self.assertEqual((maindec.mword(descriptor), maindec.mword(descriptor + 4)), (origin["size"], origin["lba"]))
        entrance, = [x for x in self.field_rooms["world_b"]["exits"] if x["room"] == "vb1_room_0"]
        self.assertEqual((entrance["x"], entrance["y"], entrance["spawn_x"], entrance["spawn_y"]), (768, 160, 256, 592))
        town = {q["entity"]: q for q in self.rooms_by_id["vb1_room_0"]["content"]["programs"]}
        school = {q["entity"]: q for q in self.rooms_by_id["vb1_room_5"]["content"]["programs"]}
        self.assertEqual(data[0x20334:0x2033B], bytes.fromhex("09 27 01 03 fe 56 0e"))
        self.assertEqual(town[0]["commands"][-1], {"kind": "world_transition", "retain_world_region": True, "x": 96, "y": 22})
        for program, offset, byte, mask in ((town[14], 0x20392, 45, 1), (town[12], 0x20455, 10, 32),
                                           (town[13], 0x2050E, 10, 32), (school[5], 0x214C0, 20, 8), (school[10], 0x20E53, 10, 64)):
            self.assertEqual(data[offset:offset + 3], bytes((9, byte, mask)))
            self.assertIn({"kind": "story_or", "flag": {"id": f"scenario_{byte:04d}", "mask": mask}}, program["commands"])
        # Classification-null records get constructor count-1, not a new actor.
        self.assertEqual(maindec.mword(0x8012F2F4), 0x9042DBFC)
        self.assertEqual(maindec.mword(0x8012F2FC), 0x244200FF)
        self.assertEqual(maindec.mword(0x8012F304), 0xA2020000)
        # Rejected non-null classifiers reserve a descriptor and advance the count.
        self.assertEqual(maindec.mword(0x8013D8F4), 0x34020001)
        self.assertEqual(maindec.mword(0x8012EF34), 0x341500FF)
        self.assertEqual(maindec.mword(0x8013D9BC), 0x34020002)
        self.assertEqual(maindec.mword(0x8012F334), 0xA0550014)
        self.assertEqual(maindec.mword(0x8012F380), 0x24420001)
        self.assertEqual(maindec.mword(0x8012F388), 0xAC22DBFC)
        self.assertEqual(maindec.mword(0x8013D44C), 0x90C40008)
        self.assertEqual(maindec.mword(0x8013D468), 0x90620014)
        self.assertEqual(maindec.mword(0x8013D470), 0x1044FFE0)
        for number, aliases in ((0, (13, 14)), (5, (4, 5))):
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, number))
            parent = None
            independently_resolved = {}
            for entity in entities:
                if not entity["flags"] & 0x101:
                    continue
                if entity["stream_offsets"][0] is None:
                    independently_resolved[entity["index"]] = parent
                else:
                    parent = entity["index"]
            room = self.rooms_by_id[f"vb1_room_{number}"]
            for alias in aliases:
                expected_parent = 12 if number == 0 else 3
                self.assertEqual(independently_resolved[alias], expected_parent)
                position = room['population']['entities'][alias]['position']
                self.assertEqual((position['x'], position['y']), (entities[alias]['x_half'] * 8, entities[alias]['y_half'] * 8))
                program = next(program for program in room['content']['programs'] if program['entity'] == alias)
                actor = next(actor for actor in room['actors'] if actor['entity'] == expected_parent)
                self.assertEqual(program['owner_actors'], [actor['id']])
                self.assertEqual(room['population']['entities'][alias]['classification']['pointer_state'], 'null')
                self.assertFalse(any(actor['entity'] == alias for actor in room['actors']))
        art = json.loads((ROOT / "kit/work/build/opening/canonical_field_art.json").read_text())
        self.assertIn("lzss.py/2.0.0", art["decoder"])
        self.assertEqual(art["room_sources"]["vb1_room_0"]["source"], origin)
        self.assertEqual(art["room_sources"]["vb1_room_5"]["room"], 5)
        from export_scene_population import inherits_actor, interaction_actor_candidates, actor_allocation_order
        unresolved = copy.deepcopy(exporter.scene.entities(data, exporter.scene.room_record(data, 0)))
        raw_room = exporter.scene.room_record(data, 0)
        raw_slots = [i for i in range(raw_room['entity_count'])
                     if struct.unpack_from('<H', data, raw_room['entity_off'] + 24*i + 4)[0] & 0x101
                     and struct.unpack_from('<I', data, raw_room['entity_off'] + 24*i + 12)[0] != 0]
        self.assertEqual(actor_allocation_order(unresolved), raw_slots)
        self.assertEqual(interaction_actor_candidates(data, unresolved, 13), [12])
        null_classifier = copy.deepcopy(unresolved)
        null_classifier[12]['stream_ptrs'][0] = 0
        null_classifier[12]['stream_offsets'][0] = None
        self.assertEqual(interaction_actor_candidates(data, null_classifier, 13), [11])
        unresolved[12]['stream_offsets'][0] = None
        self.assertIsNone(interaction_actor_candidates(data, unresolved, 13))
        unresolved[13]['stream_ptrs'][0] = 1
        self.assertFalse(inherits_actor(unresolved[13]))
        for owners in ([], ['not_an_actor'], [town[13]['owner_actors'][0], next(actor['id'] for actor in self.rooms_by_id['vb1_room_0']['actors'] if actor['entity'] != 12)], town[13]['owner_actors'] * 2):
            malformed = copy.deepcopy(self.fe)
            binding = next(row for row in malformed['rooms'] if row['room'] == 'vb1_room_0')
            program = next(program for program in binding['content']['programs'] if program['entity'] == 13)
            program['owner_actors'] = owners
            with self.assertRaises(ValueError):
                rbp._read_room_events(json.dumps(malformed).encode(), set(self.field_rooms),
                                      {encounter['id'] for encounter in self.trial['encounters']}, None, self.pkg_dir)
        self.assertEqual(set(art["room_sources"]), set(EXPECTED_ROOMS))
        for name, digest in art["producer_sha256"].items():
            self.assertEqual(digest, exporter.hashlib.sha256((ROOT / "kit/tools" / name).read_bytes()).hexdigest())

    def test_stationary_actor_initializers_use_source_allocation_and_complete_pumps(self) -> None:
        data, _ = exporter.source('/VA3.BIN')
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 1))
        self.assertEqual(data[0x29EB0:0x29EDF], bytes.fromhex(
            '30 07 00 01 11 07 00 02 24 07 02 01 0f 07 02 02 21 '
            '07 03 01 0b 07 03 02 27 07 04 01 0b 07 04 02 21 '
            '11 00 03 11 02 02 11 03 00 11 04 02 31 fd'))
        predicate = entities[28]['stream_offsets'][1]
        self.assertEqual(data[predicate:predicate + 7], bytes.fromhex('07 07 01 08 08 01 06'))
        self.assertEqual(maindec.mword(0x8013CA04), 0xA0820000)
        self.assertEqual(maindec.mword(0x8013CA34), 0xA0820001)
        self.assertEqual([maindec.mword(0x80171B98 + 4*i) for i in range(4)], [1, 3, 0, 2])
        room = self.rooms_by_id['va3_room_1']
        program = next(program for program in room['content']['programs'] if program['entity'] == 28)
        self.assertEqual(program['entry'], 'initialization')
        self.assertTrue(rbp.actor_initialization(room['content'], program))
        ids = {actor['entity']: actor['id'] for actor in room['actors']}
        expected = [{'kind': 'continue_tick'}]
        for entity, x, y in ((4, 136, 288), (9, 120, 264), (14, 88, 312), (15, 88, 264)):
            expected += [{'kind': 'place_actor', 'actor': ids[entity], 'x': x},
                         {'kind': 'place_actor', 'actor': ids[entity], 'y': y}]
        expected += [{'kind': 'actor_transition', 'actor': ids[entity], 'transition': direction}
                     for entity, direction in ((4, 2), (9, 0), (14, 1), (15, 0))]
        expected += [{'kind': 'yield_tick'}, {'kind': 'end_stream'}]
        self.assertEqual(program['commands'], expected)
        own = next(program for program in room['content']['programs'] if program['entity'] == 14)
        self.assertEqual(own['owner_actor'], ids[14])
        self.assertEqual(room['population']['entities'][14]['position']['placement'], 'off_map_staging')
        self.assertTrue(any(anchor.get('interaction_actor') for anchor in room['dialogue']['anchors'] if anchor['program'] == own['id']))
        for mutation in (0x40, 0x80, 0x3f):
            altered = bytearray(data)
            altered[0x29EB2] = mutation
            self.assertIsNone(exporter.compile_actor_initializer(altered, entities, entities[28], program['conditions']))
        altered = bytearray(data)
        altered[0x29EDE] = 0x30
        self.assertEqual(exporter.compile_actor_initializer(altered, entities, entities[28], program['conditions']),
                         exporter.compile_actor_initializer(data, entities, entities[28], program['conditions']))
        moving = copy.deepcopy(entities)
        moving[4]['flags'] |= 0x20
        self.assertIsNone(exporter.compile_actor_initializer(data, moving, moving[28], program['conditions']))

    def test_constructor_motion_initializers_preserve_speed_semantics(self) -> None:
        data, _ = exporter.source('/VA1.BIN')
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 1))
        program = next(p for p in self.rooms_by_id['va1_room_1']['content']['programs'] if p['entity'] == 3)
        self.assertEqual(data[0x3C290:0x3C2B7], bytes.fromhex(
            '30 07 00 01 27 07 00 02 0b 07 00 00 00 '
            '07 02 01 0c 07 02 02 08 07 02 00 00 '
            '07 01 01 1b 07 01 02 0b 07 01 00 00 31 fd'))
        # Constructor, script writer and movement consumer independently name the same speed byte.
        for address, word in ((0x8012F030, 0x00031882), (0x8012F034, 0x30630001),
                              (0x8012F038, 0xA0430005), (0x8013C9DC, 0xA2020005),
                              (0x8012F8CC, 0x92020005), (0x8012F8D4, 0x00621023),
                              (0x8012F8D8, 0xA2020002)):
            self.assertEqual(maindec.mword(address), word)
        writes = [c for c in program['commands'] if c['kind'] == 'actor_motion']
        self.assertEqual(len(writes), 3)
        self.assertTrue(all(c['value'] == 0 for c in writes))
        for speed in (1, 2, True):
            malformed = copy.deepcopy(self.fe)
            room = next(r for r in malformed['rooms'] if r['room'] == 'va1_room_1')
            entry = next(p for p in room['content']['programs'] if p['entity'] == 3)
            next(c for c in entry['commands'] if c['kind'] == 'actor_motion')['value'] = speed
            with self.assertRaises(ValueError):
                rbp._read_room_events(json.dumps(malformed).encode(), set(self.field_rooms),
                                      {e['id'] for e in self.trial['encounters']}, None, self.pkg_dir)
        altered = bytearray(data)
        altered[0x3C29C] = 1
        self.assertIsNone(exporter.compile_actor_initializer(altered, entities, entities[3], program['conditions']))
        faster = copy.deepcopy(entities)
        faster[5]['flags'] |= 4
        compiled = exporter.compile_actor_initializer(altered, faster, faster[3], program['conditions'])
        self.assertIsNotNone(compiled)
        self.assertEqual(next(c for c in compiled if c['kind'] == 'actor_motion')['value'], 1)

    def test_initializer_first_pump_discards_the_unarmed_tail(self) -> None:
        main, _ = exporter.source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        for address, word in {
            0x801318C4: 0x3C018017, 0x801318C8: 0xA0201C28,
            0x8013F31C: 0x0C04F85F, 0x8013F324: 0x0C04F80A,
            0x8013F340: 0x24420018, 0x8013F354: 0x1440FFEC,
            0x8013D230: 0xA022A180, 0x8013D240: 0xA020A180,
            0x801329A8: 0x34020001, 0x801329B0: 0xA0221C28,
            0x80132B80: 0x90421C28, 0x80132B90: 0x10400007,
        }.items():
            self.assertEqual(struct.unpack_from('<I', main, 2048 + address - base)[0], word)
            self.assertEqual(maindec.mword(address), word)
        data, _ = exporter.source('/VA3.BIN')
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 1))
        self.assertEqual(data[0x299D8:0x299EA], bytes.fromhex('30 07 00 01 00 07 00 02 46 07 00 00 00 31 09 09 40 fd'))
        room = self.rooms_by_id['va3_room_1']
        program = next(p for p in room['content']['programs'] if p['entity'] == 25)
        self.assertEqual([c['kind'] for c in program['commands']],
                         ['continue_tick', 'place_actor', 'place_actor', 'actor_motion', 'yield_tick', 'end_stream'])
        self.assertEqual([c.get('x', c.get('y')) for c in program['commands'] if c['kind'] == 'place_actor'], [0, 560])
        self.assertTrue(rbp.actor_initialization(room['content'], program))
        # Hero coordinate pairs and facing use the same first-pump compiler.
        raw = bytes.fromhex('30 07 80 01 0a 07 80 02 0b 11 80 03 31 09 00 01 fd')
        compiled = exporter.compile_actor_initializer(raw, [], {'stream_offsets': [None, None, 0]}, [])
        self.assertEqual(compiled, [{'kind': 'continue_tick'}, {'kind': 'place_hero', 'x': 80, 'y': 88},
                                    {'kind': 'actor_transition', 'actor': 'hero', 'transition': 2},
                                    {'kind': 'yield_tick'}, {'kind': 'end_stream'}])

    def test_initializer_staging_preserves_the_ordinary_actor_slot(self) -> None:
        main, _ = exporter.source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        for address, word in {
            0x8013C8A4: 0x8C620008, 0x8013C8AC: 0x1040000B,
            0x8013C8C0: 0xA0600005, 0x8013C8C8: 0x340200FE,
            0x8013C8CC: 0x340200F0, 0x8013C8D0: 0xA0620000,
            0x8013C8D8: 0xA0620001, 0x8012FD30: 0x8E320008,
            0x8012FD78: 0x92240000, 0x8012FDA0: 0x000420C0,
            0x8012FDC4: 0x92220001, 0x8012FDD8: 0x000210C0,
        }.items():
            self.assertEqual(struct.unpack_from('<I', main, 2048 + address - base)[0], word)
            self.assertEqual(maindec.mword(address), word)
        data, _ = exporter.source('/VA1.BIN')
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 1))
        event, _ = exporter.decode_predicate(data, entities[27]['stream_offsets'][1], 'event', full=True)
        conditions = [t for t in event['terms'] if t['kind'] in ('story_mask_set', 'story_mask_clear')]
        commands = exporter.compile_actor_initializer(data, entities, entities[27], conditions)
        staged = next(i for i, c in enumerate(commands) if c.get('x') == c.get('y') == 2032)
        self.assertEqual(commands[staged], {'kind': 'place_actor', 'x': 2032, 'y': 2032, '_source_actor': 5})
        self.assertEqual(commands[staged + 1], {'kind': 'actor_motion', 'value': 0, '_source_actor': 5})
        self.assertFalse(any(c['kind'] == 'release_actor' for c in commands))
        faster = copy.deepcopy(entities)
        faster[5]['flags'] |= 4
        self.assertIsNone(exporter.compile_actor_initializer(data, faster, faster[27], conditions))
        for count in (32, 33):
            stream = data + b'\x30' + b'\x3a\x00' * count + b'\x31\xfd'
            entity = dict(entities[27], stream_offsets=[None, None, len(data)])
            compiled = exporter.compile_actor_initializer(stream, entities, entity, conditions)
            self.assertEqual(compiled is not None, count == 32)
        for tail in (b'\x30\x3a', bytes.fromhex('30 07 80 01 0a 07 80 02')):
            entity = dict(entities[27], stream_offsets=[None, None, len(data)])
            self.assertIsNone(exporter.compile_actor_initializer(data + tail, entities, entity, conditions))
        room = self.rooms_by_id['va1_room_1']
        self.assertEqual(struct.unpack_from('<4H', data, entities[4]['offset']), (39, 11, 0, 0))
        prop = room['population']['entities'][4]
        self.assertEqual(prop['record_role'], 'event')
        self.assertFalse(prop['population_candidate'])
        self.assertIsNone(prop['source_character_id'])
        self.assertFalse(any(actor['entity'] == 4 for actor in room['actors']))
        for index in (5, 6, 9):
            self.assertEqual(struct.unpack_from('<2H', data, entities[index]['offset']), (254, 254))
            self.assertEqual(room['population']['entities'][index]['position']['placement'], 'off_map_staging')
            self.assertNotIn(('/VA1.BIN', 1, index), exporter.PLACEMENT_OVERRIDES)

    def test_source_camera_pushes_keep_exact_facing_push_and_end(self) -> None:
        import field_camera_push
        count = 0
        for binding in self.fe['rooms']:
            fname, number = exporter.ROOM_TO_SRC[binding['room']]
            data, _ = exporter.source(fname)
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, number))
            for program in binding['content']['programs']:
                if not any(command['kind'] == 'camera_push' for command in program['commands']):
                    continue
                count += 1
                self.assertIn(binding['content']['schema'], ('suikoden-event-ir/28', 'suikoden-event-ir/29'))
                start = entities[program['entity']]['stream_offsets'][2]
                raw = data[start:start + 7]
                self.assertEqual((raw[0], raw[1], raw[3], raw[6]), (0x11, 0x80, 0x21, 0xFD))
                self.assertEqual(program['commands'], [
                    {'kind': 'actor_transition', 'actor': 'hero', 'transition': maindec.mword(0x80171B98 + raw[2] * 4)},
                    {'kind': 'camera_push', 'push': field_camera_push.request(raw[4], raw[5]), 'wait': {'kind': 'camera_push', 'id': 'camera_push'}},
                    {'kind': 'end_stream'}])
        self.assertEqual(count, 46)

    def source_programs(self, binding, entities):
        authored = {'vb5a1_room_0_intruder', 'vb5a2_room_0_overnight', 'vb5a2_room_0_rescue_council',
                    'vb5a2_room_0_rescue_briefing', 'vb5a2_room_0_prison_orders'}
        if binding['room'] in ('vb5b3_room_0', 'vb5c4_room_0'):
            authored.update(f"{binding['room']}_{step}" for step in ('rescue_briefing', 'rescue_party', 'prison_orders'))
        for program in binding['content']['programs']:
            if program['entity'] < len(entities):
                yield program, entities[program['entity']]
            else:
                self.assertIn(program['id'], authored)
                owner = binding['population']['entities'][program['entity']]
                self.assertEqual(owner['event']['reference'], f"{program['id']}_authored")

    def test_direction_predicates_use_shared_selection_for_every_room(self) -> None:
        self.assertEqual([maindec.mword(0x80171708 + 4 * i) for i in range(4)], list(exporter.PAD_DIRECTION_MASKS))
        for address, word in ((0x800C1A10, 0x8013DD38), (0x8013DD3C, 0x92020000),
                              (0x8013DD44, 0x8C63BDCC), (0x8013DD48, 0x00021080),
                              (0x8013DD50, 0x24211708), (0x8013DD58, 0x8C220000),
                              (0x8013DD60, 0x00621824), (0x8013DD64, 0x146000A7)):
            self.assertEqual(maindec.mword(address), word)
        for index, mask in enumerate((0x1000, 0x2000, 0x4000, 0x8000)):
            raw = bytes((4, index, 6))
            partial, proof = exporter.decode_predicate(raw, 0, 'event')
            full, _ = exporter.decode_predicate(raw, 0, 'event', full=True)
            normalized = exporter.normalize_event_predicate(partial, proof)
            self.assertEqual(normalized, full)
            self.assertEqual(exporter.event_selection_term(normalized['terms'][0]), {'kind': 'pressed_mask', 'mask': mask})
        checked = 0
        for binding in self.fe['rooms']:
            fname, number = exporter.ROOM_TO_SRC[binding['room']]
            data, _ = exporter.source(fname)
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, number))
            for program, entity in self.source_programs(binding, entities):
                full, _ = exporter.decode_predicate(data, entity['stream_offsets'][1], 'event', full=True)
                for term in full['terms']:
                    if term['kind'] == 'pressed_mask':
                        self.assertIn({'kind': 'pressed_mask', 'mask': term['mask']}, program['selection'])
                        checked += 1
        self.assertGreaterEqual(checked, 53)
        partial, proof = exporter.decode_predicate(bytes((4, 4, 6)), 0, 'event')
        self.assertEqual(exporter.normalize_event_predicate(partial, proof)['terms'][0]['kind'], 'unsupported')

    def test_local_flag_predicates_are_lowered_for_every_event(self) -> None:
        for index, opcode in ((19, 9), (0, 10)):
            raw = bytes((opcode, index, 0x81, 6))
            predicate, proof = exporter.decode_predicate(raw, 0, 'event')
            normalized = exporter.normalize_event_predicate(predicate, proof)
            self.assertEqual(normalized['terms'], [{'kind': 'room_mask_set' if opcode == 9 else 'room_mask_clear',
                                                     'index': index, 'mask': 0x81}])
        predicate, proof = exporter.decode_predicate(bytes((9, 20, 1, 6)), 0, 'event')
        self.assertEqual(exporter.normalize_event_predicate(predicate, proof)['terms'][0]['kind'], 'unsupported')
        for room, entity, mask in (('va1_room_3', 12, 1), ('va1_room_7', 6, 2)):
            data, _ = exporter.source('/VA1.BIN')
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, int(room.rsplit('_', 1)[1])))
            offset = entities[entity]['stream_offsets'][1]
            self.assertEqual(data[offset:offset + 5], bytes((5, 9, 5, mask, 6)))
            binding = self.rooms_by_id[room]
            program = next(p for p in binding['content']['programs'] if p['entity'] == entity)
            self.assertIn({'kind': 'room_mask_set', 'index': 5, 'mask': mask}, program['selection'])
            self.assertIn({'kind': 'room_mask_set', 'index': 5, 'mask': mask}, binding['population']['entities'][entity]['event_selection']['terms'])
        for address, word in ((0x800C1A24, 0x8013DDB4), (0x800C1A28, 0x8013DDCC),
                              (0x8013DDB8, 0x34050001), (0x8013DDD0, 0x00002821),
                              (0x8013DDBC, 0x0C04F5B3), (0x8013DDD4, 0x0C04F5B3),
                              (0x8013DDC0, 0x00003021), (0x8013D6EC, 0x90430280),
                              (0x8013D724, 0x00621024), (0x8013D740, 0x00621024)):
            self.assertEqual(maindec.mword(address), word)

    def test_static_eligibility_predicates_share_full_decoder_semantics(self) -> None:
        for raw in (bytes((0x0e, 30, 6)), bytes((0x10, 107, 6)), bytes((0x11, 0, 6)),
                    bytes((0x19, 31, 6)), bytes((0x14, 255, 4, 6))):
            partial, proof = exporter.decode_predicate(raw, 0, 'event')
            full, _ = exporter.decode_predicate(raw, 0, 'event', full=True)
            self.assertEqual(exporter.normalize_event_predicate(partial, proof), full)
        for raw in (bytes((0x0e, 0, 6)), bytes((0x10, 108, 6)), bytes((0x14, 0, 5, 6))):
            partial, proof = exporter.decode_predicate(raw, 0, 'event')
            self.assertEqual(exporter.normalize_event_predicate(partial, proof)['terms'][0]['kind'], 'unsupported')
        for address, word in ((0x800C1A38, 0x8013DE04), (0x800C1A40, 0x8013DE38),
                              (0x800C1A50, 0x8013DEE8), (0x8013DE08, 0x0C04F4CC),
                              (0x8013D388, 0x8C421B9C), (0x8013D398, 0x144A0004),
                              (0x8013DE50, 0x90431AF4), (0x8013DE58, 0x30620001),
                              (0x8013DE68, 0x30620002), (0x8013DE9C, 0x30620002),
                              (0x8013DFEC, 0x30620001), (0x8013DFF8, 0x30620002), (0x8013DEF0, 0x26100002),
                              (0x8013DEF8, 0x90420034), (0x8013DF00, 0x0043102B)):
            self.assertEqual(maindec.mword(address), word)
        for fname, room_number, room_id in exporter.OPENING_ROOMS:
            data, _ = exporter.source(fname)
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, room_number))
            for program, entity in self.source_programs(self.rooms_by_id[room_id], entities):
                full, _ = exporter.decode_predicate(data, entity['stream_offsets'][1], 'event', full=True)
                for term in full['terms']:
                    if term['kind'] == 'party_contains':
                        expected = {'kind': term['kind'], 'index': term['character_id']}
                    elif term['kind'] in ('recruit_present', 'recruit_absent', 'recruit_ever'):
                        expected = {'kind': term['kind'], 'index': term['slot']}
                    elif term['kind'] == 'stage_at_least':
                        expected = {'kind': term['kind'], 'min': term['stage']}
                    else:
                        continue
                    if program['entry'] == 'initialization':
                        self.assertEqual(program['selection'], [])
                    else:
                        self.assertIn(expected, program['selection'], (room_id, program['entity']))
                    self.assertIn(term, self.rooms_by_id[room_id]['population']['entities'][program['entity']]['event_selection']['terms'])
        room = self.rooms_by_id['vb1_room_4']
        program = next(p for p in room['content']['programs'] if p['entity'] == 5)
        self.assertEqual(program['selection'], [{'kind': 'party_contains', 'index': 30},
                                                {'kind': 'stage_at_least', 'min': 2}])
        guard = next(p for p in self.rooms_by_id['vb2_room_8']['content']['programs'] if p['entity'] == 1)
        self.assertIn({'kind': 'recruit_present', 'index': 32}, guard['selection'])

    def test_money_predicates_keep_source_units_and_program_guards(self) -> None:
        for operand in (0, 1, 100, 255):
            raw = bytes((0x0d, operand, 6))
            predicate, proof = exporter.decode_predicate(raw, 0, 'event')
            full, _ = exporter.decode_predicate(raw, 0, 'event', full=True)
            self.assertEqual(exporter.normalize_event_predicate(predicate, proof), full)
            self.assertEqual(full['terms'], [{'kind': 'money_at_least', 'amount': operand * 100}])
        for address, word in ((0x800C1A34, 0x8013DC28), (0x8013DC3C, 0x00041040),
                              (0x8013DC40, 0x00441021), (0x8013DC44, 0x000210C0),
                              (0x8013DC48, 0x8C63001C), (0x8013DC4C, 0x00441021),
                              (0x8013DC50, 0x00021080), (0x8013DC54, 0x0062182A)):
            self.assertEqual(maindec.mword(address), word)
        room = self.rooms_by_id['vb6_room_12']
        program = next(p for p in room['content']['programs'] if p['entity'] == 3)
        self.assertIn({'kind': 'money_at_least', 'amount': 10000}, program['selection'])
        self.assertIn({'kind': 'money_at_least', 'amount': 10000}, room['population']['entities'][3]['event_selection']['terms'])

    def test_dice_returns_after_counted_callback_and_wait(self) -> None:
        data, _ = exporter.source('/VB2.BIN')
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 8))
        for entity in (0, 1):
            start = entities[entity]['stream_offsets'][2]
            self.assertEqual(data[start:start + 4], bytes((0x3D, 0x12, 3, 2)))
            self.assertEqual(data[start + 4:start + 4 + data[start + 3]], bytes((entity + 1, 4)))
            wait = start + 4 + data[start + 3]
            self.assertEqual(data[wait:wait + 3], bytes((0x3D, 0x14, 3)))
            room, x, y = data[wait + 3:wait + 6]
            program = next(p for p in self.rooms_by_id['vb2_room_8']['content']['programs'] if p['entity'] == entity)
            self.assertEqual(program['commands'], [
                {'kind': 'fixed_dice'},
                {'kind': 'room_transition', 'destination': f'vb2_room_{room}', 'x': x * 8, 'y': y * 8},
            ])

    def test_founding_grows_recruits_then_recovers_and_dismisses_active_party(self) -> None:
        from event_script_decode import decode_stream

        for file, number, entity, character, offset, raw, expected in (
            ('/VB5G.BIN', 1, 2, 'yam_koo', 0x2d85, b'\x00\x26\x08', ['advance_character']),
            ('/VB7.BIN', 4, 4, 'luc', 0x229, b'\x00\x1a\x0b', ['advance_character', 'party_restore', 'party_dismiss']),
        ):
            data, _ = exporter.source(file)
            self.assertEqual(data[offset:offset + 4], b'\x4b' + raw)
            (decoded,) = decode_stream(data, offset, max_insns=1)
            self.assertEqual(decoded[:3], (offset, 0x4b, raw))
            if character == 'luc':
                self.assertEqual(data[0x26d:0x272], b'\x4c\x02\x00\x20\xff')
            room = self.rooms_by_id[f'{file[1:-4].lower()}_room_{number}']
            program = next(p for p in room['content']['programs'] if p['entity'] == entity)
            roster = [command for command in program['commands'] if command['kind'] in (*expected, 'party_join')]
            self.assertEqual([command['kind'] for command in roster], expected)
            self.assertEqual(roster[0], {'kind': 'advance_character', 'character': character, 'level_advances': raw[2]})
            if character == 'yam_koo':
                self.assertEqual(data[0x2d89:0x2d8b], b'\x42\x02')
                self.assertEqual(data[0x2d92:0x2d94], b'\x42\x14')
                self.assertEqual([c['code'] for c in program['commands'] if c['kind'] == 'world_mode'], [2, 20])
        for pc, word in ((0x800c1ac8, 0x801418c0), (0x801418cc, 0x90620034),
                         (0x801418d4, 0x24420001), (0x801418dc, 0xa0620034)):
            self.assertEqual(maindec.mword(pc), word)

    def test_later_toran_docks_enable_boat_control_on_boarding(self) -> None:
        for name, entities, offset in (
            ('/VB5BG.BIN', (10, 11), 0x48f59),
            ('/VB5CG.BIN', (19, 20), 0x49809),
        ):
            data, _ = exporter.source(name)
            self.assertEqual(data[offset:offset + 7], bytes.fromhex('42 0c 03 fb 09 64 4b'))
            room = self.rooms_by_id[f'{name[1:-4].lower()}_room_0']
            for entity in entities:
                program = next(p for p in room['content']['programs'] if p['entity'] == entity)
                commands = program['commands']
                branch = next(i for i, c in enumerate(commands) if c['kind'] == 'branch_choice')
                self.assertEqual(commands[branch + 2], {'kind': 'world_mode', 'code': 12})
                self.assertEqual(commands[commands[branch + 3]['target']],
                                 {'kind': 'world_transition', 'destination': 'world_j', 'x': 100, 'y': 75})
                self.assertEqual(commands[commands[branch]['target'] + 2]['kind'], 'end_stream')

    def test_milich_both_approaches_preserve_party_and_release_required_members(self) -> None:
        data, _ = exporter.source('/VD6.BIN')
        room = self.rooms_by_id['vd6_room_0']
        for entity, growth, release in ((0, 0x47b65, 0x47bd3), (1, 0x47ef0, 0x47f5e)):
            self.assertEqual(data[growth - 2:growth + 4], bytes.fromhex('45 1c 4b 00 1c 1f'))
            self.assertEqual(data[release:release + 6], bytes.fromhex('4a 01 23 4a 01 11'))
            program = next(p for p in room['content']['programs'] if p['entity'] == entity)
            effects = [c for c in program['commands'] if c['kind'] in ('advance_character', 'party_join', 'area_action')]
            self.assertEqual(effects, [
                {'kind': 'advance_character', 'character': 'milich', 'level_advances': 31},
                {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_remove', 'character': 35}},
                {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_remove', 'character': 17}},
            ])

    def test_expanded_councils_offer_prison_preparation_from_the_same_advisor(self) -> None:
        for room_id in ('vb5b3_room_0', 'vb5c4_room_0'):
            with self.subTest(room=room_id):
                room = self.rooms_by_id[room_id]
                advisor = next(actor for actor in room['actors'] if actor['id'] == f'{room_id}_rescue_advisor')
                entity = room['population']['entities'][advisor['entity']]
                self.assertEqual(entity['source_character_id'], 27)
                floor = self.field_rooms[room_id]
                x, y = (entity['position'][axis] // 8 for axis in ('x', 'y'))
                self.assertEqual(floor['walkable'][(y + 1) * (floor['width'] // 8) + x], '1')
                programs = {p['id']: p for p in room['content']['programs']}
                for suffix, effect in (('rescue_briefing', 'shared_inventory_edit'),
                                       ('rescue_party', 'party_select'), ('prison_orders', 'shared_inventory_edit')):
                    program = programs[f'{room_id}_{suffix}']
                    owners = program.get('owner_actors') or [program.get('owner_actor')]
                    self.assertEqual(owners, [advisor['id']])
                    self.assertIn(effect, [command['kind'] for command in program['commands']])

    def test_pahn_defeat_accepts_a_character_already_outside_the_active_party(self) -> None:
        data, _ = exporter.source('/VB7D.BIN')
        self.assertEqual(data[0xc2e0:0xc2e3], bytes.fromhex('20 fe 06'))
        program = next(p for p in self.rooms_by_id['vb7d_room_0']['content']['programs'] if p['entity'] == 5)
        self.assertIn({'kind': 'party_leave', 'character': 'pahn', 'value': 1}, program['commands'])

    def test_first_teo_war_branches_enter_the_existing_duel_room(self) -> None:
        war, provenance = exporter.source('/WAR_TEO1.BIN')
        self.assertEqual(provenance['lba'], 183191)
        self.assertEqual(struct.unpack_from('<I', war, 0x33C)[0], 0x8002620C)
        self.assertEqual([war[offset] for offset in (0x16280, 0x16290, 0x162BC)], [1, 41, 20])
        for room_id, entity, offsets in (
            ('vb5b3_room_0', 85, (0x2F2FB, 0x2F32F, 0x2F363)),
            ('vb5c4_room_0', 96, (0x3CE91, 0x3CEC5, 0x3CEF9)),
        ):
            fname, _ = exporter.ROOM_TO_SRC[room_id]
            field, _ = exporter.source(fname)
            self.assertTrue(all(field[offset:offset + 3] == b'\x47\xff\x04' for offset in offsets))
            binding = self.rooms_by_id[room_id]['content']
            commands = next(p['commands'] for p in binding['programs'] if p['entity'] == entity and p['entry'] == 'ordinary')
            sites = [i for i, command in enumerate(commands) if command.get('battle') == 'war:teo_before_fire_spear']
            self.assertEqual(len(sites), 3)
            expected = {'kind': 'room_transition', 'destination': 'vb7d_room_0',
                        'x': 160, 'y': 160, 'world_entry': 'world_b_point_41'}
            for site in sites:
                handoff = commands[site + 1]
                if handoff['kind'] == 'jump':
                    handoff = commands[handoff['target']]
                self.assertEqual(handoff, expected)

    def test_pahn_duel_aftermath_returns_to_the_current_castle_tier(self) -> None:
        data, _ = exporter.source('/VB7D.BIN')
        programs = self.rooms_by_id['vb7d_room_0']['content']['programs']
        for entity, site in ((3, 0xc247), (5, 0xc2e3)):
            self.assertEqual(data[site:site + 6], bytes.fromhex('03 fd 03 00 20 11'))
            commands = next(p['commands'] for p in programs if p['entity'] == entity)
            branch = next(command for command in commands if command['kind'] == 'branch_castle_tier')
            self.assertEqual([(commands[i]['destination'], commands[i]['world_point']) for i in branch['targets']], [
                ('vb5b3_room_0', 27), ('vb5c3_room_0', 19), ('vb5c3_room_0', 19),
            ])

    def test_kasumi_briefing_uses_the_council_approach_and_reopens_from_the_dock(self) -> None:
        for name, entity, growth, departure, point, dock in (
            ('/VB5B3.BIN', 84, 0x2f261, 0x2f29d, 24, 'vb5bg_room_0'),
            ('/VB5C4.BIN', 95, 0x3cdf9, 0x3ce35, 16, 'vb5cg_room_0'),
        ):
            data, _ = exporter.source(name)
            self.assertEqual(data[growth - 2:growth + 4], bytes.fromhex('45 17 4b 00 17 25'))
            self.assertEqual(data[departure:departure + 7], bytes((3, 0xfa, 1, point, 0, 0xfe, 0xfe)))
            room = self.rooms_by_id[f'{name[1:-4].lower()}_room_0']
            briefing = next(p for p in room['content']['programs'] if p['entity'] == entity)
            launch = next(p for p in room['content']['programs'] if p['entity'] == entity + 1)
            self.assertEqual(briefing['selection'], launch['selection'])
            commands = briefing['commands']
            self.assertEqual([c for c in commands if c['kind'] in ('party_dismiss', 'party_join', 'advance_character')], [
                {'kind': 'party_dismiss'},
                {'kind': 'advance_character', 'character': 'kasumi', 'level_advances': 37},
            ])
            self.assertEqual(commands[-1], {'kind': 'room_transition', 'destination': dock,
                                            'x': 128, 'y': 344, 'world_point': point})

    def test_scarleticia_councils_recruit_liukan_and_muster_viktor_and_flik(self) -> None:
        for file, entity, muster, growth in (
            ('/VB5B3.BIN', 51, 0x2edac, 0x2ed85),
            ('/VB5B3.BIN', 52, 0x2ee01, None),
            ('/VB5C4.BIN', 61, 0x3c950, 0x3c929),
            ('/VB5C4.BIN', 62, 0x3c9a8, None),
        ):
            with self.subTest(file=file, entity=entity):
                data, _ = exporter.source(file)
                self.assertEqual(data[muster:muster + 14], bytes.fromhex('20 ff 1f ff 23 4a 00 23 1f ff 11 4a 00 11'))
                room = self.rooms_by_id[f'{file[1:-4].lower()}_room_0']
                program = next(p for p in room['content']['programs'] if p['entity'] == entity)
                roster = [c for c in program['commands'] if c['kind'] in (
                    'advance_character', 'party_join', 'party_dismiss', 'party_load', 'area_action')]
                expected = [
                    {'kind': 'party_dismiss'},
                    {'kind': 'party_load', 'character': 'viktor'},
                    {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': 35}},
                    {'kind': 'party_load', 'character': 'flik'},
                    {'kind': 'area_action', 'area': {'kind': 'auxiliary_party_add', 'character': 17}},
                ]
                if growth is not None:
                    self.assertEqual(data[growth:growth + 4], b'\x4b\x00\x07\x12')
                    expected.insert(0, {'kind': 'advance_character', 'character': 'liukan', 'level_advances': 18})
                self.assertEqual(roster, expected)

    def test_rejected_compilation_cannot_publish_partial_text_or_tracks(self) -> None:
        original = exporter.compile_program
        signature = inspect.signature(original)
        rejected = []
        def compile_with_partial_failure(*args, **kwargs):
            result = original(*args, **kwargs)
            if result is None:
                arguments = signature.bind(*args, **kwargs).arguments
                arguments['pool'].get_body_text([{'kind': 'glyph', 'text': 'discard rejected text'}])
                arguments['pool'].get_speaker_text('discard rejected speaker')
                arguments['pool'].images.append({'id': 'discard_rejected_image'})
                arguments['pool'].image_map[-1] = len(arguments['pool'].images) - 1
                arguments['room_tracks'].append({'id': 'discard_rejected_track'})
                rejected.append(True)
            return result
        with patch.object(exporter, 'compile_program', compile_with_partial_failure):
            packet = exporter.build_package(ROOT / 'kit/work/build/opening/canonical_field_art.json')
        self.assertTrue(rejected)
        self.assertEqual(packet, self.fe)

    def test_quiet_conversations_qualify_by_source_capabilities(self) -> None:
        self.assertIsNone(exporter.event_selection_term({'kind': 'party_absent', 'index': 0}))
        art = json.loads((ROOT / 'kit/work/build/opening/canonical_field_art.json').read_text())
        samples = (('/VB1.BIN', 5, 26), *[('/VB2.BIN', 0, i) for i in (29, 30, 32)],
                   *[('/VB2.BIN', 5, i) for i in (7, 8, 9, 11)], ('/VB2.BIN', 6, 15))
        for file, room_number, entity in samples:
            data, _ = exporter.source(file)
            room_id = f'{file[1:-4].lower()}_room_{room_number}'
            record = exporter.scene.room_record(data, room_number)
            section = exporter.scene.section_off(data, record['section'])
            width, height, _ = exporter.area_room_walkable_grid(data, section, file, room_number)
            program = next(p for p in self.rooms_by_id[room_id]['content']['programs'] if p['entity'] == entity)
            self.assertNotIn((file, room_number, entity), exporter.FORCE_SOURCE_ONLY)
            self.assertTrue(exporter.static_conversation(data, room_number, entity, room_id, program, art, width, height))
            changed = copy.deepcopy(program)
            changed['commands'].insert(0, {'kind': 'story_or', 'flag': {'id': 'scenario_0001', 'mask': 1}})
            self.assertFalse(exporter.static_conversation(data, room_number, entity, room_id, changed, art, width, height))
            changed = copy.deepcopy(program)
            changed['conditions'].append({'kind': 'story_mask_set', 'flag': {'id': 'scenario_0001', 'mask': 1}})
            self.assertFalse(exporter.static_conversation(data, room_number, entity, room_id, changed, art, width, height))
        data, _ = exporter.source('/VB2.BIN')
        record = exporter.scene.room_record(data, 0)
        entities = exporter.scene.entities(data, record)
        section = exporter.scene.section_off(data, record['section'])
        width, height, _ = exporter.area_room_walkable_grid(data, section, '/VB2.BIN', 0)
        program = next(p for p in self.rooms_by_id['vb2_room_0']['content']['programs'] if p['entity'] == 30)
        for unported_flag in (4, 8, 0x10, 0x200):
            changed = bytearray(data)
            struct.pack_into('<H', changed, entities[30]['offset'] + 4, entities[30]['flags'] | unported_flag)
            self.assertFalse(exporter.static_conversation(changed, 0, 30, 'vb2_room_0', program, art, width, height))
        missing = dict(art, character_clips=dict(art['character_clips']))
        del missing['character_clips'][f"vb2_room_0_character_{entities[30]['id']:03d}"]
        self.assertFalse(exporter.static_conversation(data, 0, 30, 'vb2_room_0', program, missing, width, height))

    def test_level_predicate_uses_character_identity_and_stored_record_level(self) -> None:
        data, _ = exporter.source('/VB6.BIN')
        self.assertEqual(data[0x35F34:0x35F41], bytes.fromhex('07 a0 08 0e 04 13 04 23 14 ff 02 05 06'))
        for raw in (bytes((0x13, 4, 35, 6)), bytes((0x13, 109, 99, 6)),
                    bytes((0x13, 0, 35, 6)), bytes((0x13, 4, 0, 6)), bytes((0x13, 255, 255, 6))):
            partial, proof = exporter.decode_predicate(raw, 0, 'event')
            full, _ = exporter.decode_predicate(raw, 0, 'event', full=True)
            self.assertEqual(exporter.normalize_event_predicate(partial, proof), full)
            term = full['terms'][0]
            self.assertEqual(exporter.event_selection_term(term), {'kind': 'level_at_least', 'index': raw[1], 'min': raw[2]})
        for address, word in ((0x800C1A4C, 0x8013DEC8), (0x8013DECC, 0x92040000),
                              (0x8013DED4, 0x92050000), (0x8013DED8, 0x0C04F5E2),
                              (0x8013D79C, 0x8C620294), (0x8013D7A4, 0x14440008),
                              (0x8013D7AC, 0x906202A1), (0x8013D7B4, 0x0045102B),
                              (0x8013D7C8, 0x24C60005), (0x8013D7CC, 0x28C20186),
                              (0x8013D7D4, 0x24630050)):
            self.assertEqual(maindec.mword(address), word)
        room = self.rooms_by_id['vb6_room_12']
        program = next(p for p in room['content']['programs'] if p['entity'] == 5)
        self.assertIn({'kind': 'level_at_least', 'index': 4, 'min': 35}, program['selection'])
        self.assertIn({'kind': 'level_at_least', 'character_id': 4, 'level': 35}, room['population']['entities'][5]['event_selection']['terms'])

    def test_item_predicates_preserve_carried_versus_equipped_source_checks(self) -> None:
        for opcode in (0x17, 0x18):
            for source_id in (0, 1, 80, 255):
                raw = bytes((opcode, source_id, 6))
                partial, proof = exporter.decode_predicate(raw, 0, 'event')
                full, _ = exporter.decode_predicate(raw, 0, 'event', full=True)
                self.assertEqual(exporter.normalize_event_predicate(partial, proof), full)
                self.assertEqual(exporter.event_selection_term(full['terms'][0]),
                                 {'kind': 'has_item', 'index': source_id, 'require_key': opcode == 0x18})
        for address, word in ((0x800C1A5C, 0x8013DFB0), (0x800C1A60, 0x8013DFB0),
                              (0x8013DFB0, 0x92040000), (0x8013DFBC, 0x0C04F5F9),
                              (0x8013D7F0, 0x91620003), (0x8013D81C, 0x9043000E),
                              (0x8013D834, 0x8C421B9C), (0x8013D844, 0x90E3001F),
                              (0x8013D864, 0x94620020), (0x8013D874, 0x108D0018),
                              (0x8013D884, 0x9442001C), (0x8013D88C, 0x30420080),
                              (0x8013D898, 0x80620022), (0x8013D8A0, 0x10400004)):
            self.assertEqual(maindec.mword(address), word)

    def test_item_predicate_export_versions_and_shared_owner_gate_are_structural(self) -> None:
        original = exporter.normalize_event_predicate
        personal = next(row for row in exporter._SHARED_LEDGER['items'] if row['id'] == 'medicine')
        shared = next(row for row in exporter._SHARED_LEDGER['items'] if row['ownership'] == 'shared_key')
        for item in (personal, shared):
            def with_item(ev, proof):
                result = original(ev, proof)
                if any(term['kind'] == 'interaction' for term in result['terms']):
                    result['terms'].append({'kind': 'has_item', 'item_id': item['source_item_id'], 'require_key': False})
                return result
            with patch.object(exporter, 'normalize_event_predicate', with_item):
                packet = exporter.build_package(ROOT / 'kit/work/build/opening/canonical_field_art.json',
                                                rooms=(('/VB2.BIN', 5, 'vb2_room_5'),))
            room = packet['rooms'][0]
            interactions = [p for p in room['content']['programs'] if p['trigger'] == 'interaction']
            self.assertTrue(interactions)
            self.assertEqual(room['content']['schema'], 'suikoden-event-ir/27')
            self.assertTrue(all({'kind': 'has_item', 'index': item['source_item_id'], 'require_key': False} in p['selection'] for p in interactions))

    def test_recruitment_handins_remove_the_required_items(self) -> None:
        for room_id, entity, recruit, items in (
            ('vd1_room_7', 0, 57, ((0x4B8DC, 155, 'opal'),)),
            ('ve2_room_0', 3, 90, ((0x46913, 161, 'red_flower_seeds'),
                                  (0x46926, 162, 'blue_flower_seeds'),
                                  (0x46939, 163, 'yellow_flower_seeds'))),
        ):
            with self.subTest(room=room_id):
                filename, _ = exporter.ROOM_TO_SRC[room_id]
                data, _ = exporter.source(filename)
                room = self.rooms_by_id[room_id]
                program = next(p for p in room['content']['programs'] if p['entity'] == entity)
                commands = program['commands']
                grant = commands.index({'kind': 'recruit_toggle', 'index': recruit})
                edits = [command['inventory']['take'] for command in commands[:grant]
                         if command['kind'] == 'shared_inventory_edit']
                self.assertEqual(edits, [name for _, _, name in items])
                for offset, item_id, _ in items:
                    self.assertEqual(data[offset:offset + 3], bytes((0x49, 0xFD, item_id)))
                    self.assertIn({'kind': 'has_item', 'index': item_id, 'require_key': False}, program['selection'])

    def test_recruitment_count_predicates_preserve_the_source_thresholds(self) -> None:
        for room_id, entity, count in (
            ('vb4_room_0', 12, 80),
            ('vb5b3_room_6', 7, 107),
            ('vb5c4_room_8', 7, 107),
        ):
            with self.subTest(room=room_id):
                filename, room_number = exporter.ROOM_TO_SRC[room_id]
                data, _ = exporter.source(filename)
                source = exporter.scene.entities(data, exporter.scene.room_record(data, room_number))[entity]
                terms, proof = exporter.decode_predicate(data, source['stream_offsets'][1], 'event', full=True)
                self.assertIn({'kind': 'recruit_count_at_least', 'count': count}, terms['terms'])
                threshold = next(term for term in proof['terms'] if term['opcode'] == 0x16)
                self.assertEqual(data[threshold['offset']:threshold['offset'] + 2], bytes((0x16, count)))
                room = self.rooms_by_id[room_id]
                program = next(p for p in room['content']['programs'] if p['entity'] == entity)
                self.assertIn({'kind': 'recruit_count_at_least', 'index': count}, program['selection'])

    def test_lenankamp_post_delivery_return(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        program = next(p for p in self.rooms_by_id["va3_room_2"]["content"]["programs"] if p["entity"] == 5)
        commands = program["commands"]
        self.assertEqual(data[0x2A70E:0x2A711], bytes.fromhex("10 1f 1e"))
        self.assertEqual(data[0x2A7A7:0x2A7AD], bytes.fromhex("20 6d 39 09 09 20"))
        self.assertIn({"kind": "party_leave", "character": "odessa"}, commands)
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0009", "mask": 32}}, commands)
        self.assertIn({"kind": "story_mask_set", "flag": {"id": "scenario_0009", "mask": 16}}, program["conditions"])
        self.assertIn({"kind": "story_mask_clear", "flag": {"id": "scenario_0009", "mask": 32}}, program["conditions"])
        leave = next(i for i, c in enumerate(commands) if c["kind"] == "party_leave")
        write = next(i for i, c in enumerate(commands) if c["kind"] == "story_or")
        self.assertLess(leave, write)
        hideout = self.rooms_by_id["va3_room_1"]["population"]["entities"][25]
        self.assertEqual(hideout["event"]["status"], "resolved")
        original = exporter.scene.entities(data, exporter.scene.room_record(data, 1))[25]
        self.assertEqual(original["flags"], 16)
        self.assertEqual(data[0x299E5:0x299EA], bytes.fromhex("31 09 09 40 fd"))

    def test_o01_choices_and_no_inn_save(self) -> None:
        def find_prog(room_id: str, pid: str) -> dict:
            return next(p for p in self.rooms_by_id[room_id]["content"]["programs"] if p["id"] == pid)

        def text_for_choice(room_id: str, prog: dict) -> list[str]:
            texts = {t["id"]: t["tokens"] for t in self.rooms_by_id[room_id]["content"]["texts"]}
            out = []
            for i, cmd in enumerate(prog["commands"]):
                if cmd["kind"] == "choice":
                    prev_text = next(
                        c["text"] for c in reversed(prog["commands"][:i]) if c["kind"] == "text"
                    )
                    rendered = "".join(
                        "\n" if tok["kind"] == "newline" else tok.get("text", "")
                        for tok in texts[prev_text]
                    )
                    out.append((cmd["options"], rendered))
            return out

        # 2-option Emperor Barbarosa choice
        c_emp = text_for_choice("vaa_room_2", find_prog("vaa_room_2", "vaa_room_2_e22_interaction"))
        self.assertEqual(c_emp, [(2, "Yes, Your Highness.\nI don't wanna.")])

        # 3-option Kraze Magician's Island choice & Gremio/Cleo choices
        c_kraze = text_for_choice("vaa_room_1", find_prog("vaa_room_1", "vaa_room_1_e34_interaction"))
        self.assertEqual(len(c_kraze), 1)
        self.assertEqual(c_kraze[0][0], 3)
        self.assertEqual(len(c_kraze[0][1].split("\n")), 3)

        c_gremio = text_for_choice("va1_room_1", find_prog("va1_room_1", "va1_room_1_e04_interaction"))
        self.assertEqual(c_gremio[0][0], 3)
        self.assertEqual(len(c_gremio[0][1].split("\n")), 3)

        c_cleo = text_for_choice("va1_room_2", find_prog("va1_room_2", "va1_room_2_e11_interaction"))
        self.assertEqual(c_cleo[0][0], 3)
        self.assertEqual(len(c_cleo[0][1].split("\n")), 3)

        # AGENTS.md §1 Rule 9: Innkeeper handles Staying only (no Save option)
        for pid in ("va1_room_3_e02_interaction", "va1_room_3_e03_interaction", "va1_room_3_e04_interaction"):
            c_inn = text_for_choice("va1_room_3", find_prog("va1_room_3", pid))
            self.assertEqual(c_inn, [(2, "Stay\nDon't stay")])

    def test_o02_dungeon_town_world_connectivity_and_guard(self) -> None:
        graph: dict[str, set[str]] = {rid: set() for rid in self.field_rooms}
        for rid, room in self.field_rooms.items():
            for ex in room["exits"]:
                graph[rid].add(ex["room"])
        for room in self.fe["rooms"]:
            src = room["room"]
            for prog in room["content"]["programs"]:
                for cmd in prog["commands"]:
                    if cmd['kind'] == 'world_transition':
                        if cmd.get('return_to_entry') or cmd.get('retain_world_region'):
                            area = self.field_rooms[src]['source_area']
                            graph[src].update(entry['world_room'] for entry in self.room_pkg['world_entries'] if entry['area'] == area)
                        else:
                            graph[src].add(cmd['destination'])
                    if cmd["kind"] == "room_transition":
                        dst = cmd["destination"]
                        dst_room = self.field_rooms[dst]
                        w = dst_room["width"] // 8
                        self.assertEqual(cmd["x"] % 8, 0)
                        self.assertEqual(cmd["y"] % 8, 0)
                        self.assertEqual(dst_room["walkable"][(cmd["y"] // 8) * w + (cmd["x"] // 8)], "1")
                        graph[src].add(dst)

        # Whole opening component reachable from starting throne room vaa_room_2
        seen = set()
        queue = ["vaa_room_2"]
        while queue:
            cur = queue.pop(0)
            if cur in seen:
                continue
            seen.add(cur)
            queue.extend(graph.get(cur, ()))
        region_ab_areas = {
            self.field_rooms[ex["room"]].get("source_area")
            for wid in ("world_a", "world_b")
            for ex in self.field_rooms[wid]["exits"]
        }
        expected_ab = [
            rid for rid in EXPECTED_ROOMS
            if self.field_rooms[rid].get("source_area") in region_ab_areas
        ]
        for expected in expected_ab + ["world_a", "world_b", "world_c", "world_d", "world_e", "world_f", "world_h", "world_k", "world_z"]:
            self.assertIn(expected, seen)

    def test_lenankamp_world_point_and_viktor_farewell(self) -> None:
        data, origin = exporter.source("/VA3.BIN")
        point = maindec.mword(0x80170064) - maindec.MBASE + 2 * 14
        row = maindec.body()[point:point + 14]
        descriptor = maindec.mword(maindec.mword(0x8016F67C) + 2 * 4)
        self.assertEqual((maindec.mword(descriptor), maindec.mword(descriptor + 4)),
                         (origin["size"], origin["lba"]))
        self.assertEqual(row[:8], bytes.fromhex("00 00 3c 00 48 00 2f 5b"))
        x = (int.from_bytes(row[2:4], "little") + 10) * 8
        y = (int.from_bytes(row[4:6], "little") + 8) * 8
        entry = next(e for e in self.field_rooms["world_a"]["exits"] if e["room"] == "va3_room_0")
        self.assertEqual((entry["x"], entry["y"], entry["w"], entry["h"], entry["spawn_x"], entry["spawn_y"]),
                         (x, y, 16, 16, row[6] * 8, row[7] * 8))
        content = self.rooms_by_id["va3_room_0"]["content"]
        programs = {p["entity"]: p for p in content["programs"]}
        self.assertEqual(data[0x28D78:0x28D7B], bytes.fromhex("03 ff fd"))
        for i in (0, 1):
            cmd = programs[i]["commands"][-1]
            self.assertEqual(cmd, {'kind': 'world_transition', 'return_to_entry': True})
            point = next(entry for entry in self.room_pkg['world_entries'] if entry['id'] == 'world_a_point_2')
            self.assertEqual((point['return_x'], point['return_y']), (x, y + 16))
        self.assertEqual(data[0x28D70:0x28D77], bytes.fromhex("07 06 08 08 06 10 06"))
        self.assertEqual(data[0x28E5A:0x28E60], bytes.fromhex("09 06 10 20 23 fd"))
        farewell = programs[11]
        self.assertEqual([(c["kind"], c["flag"]["mask"]) for c in farewell["conditions"]],
                         [("story_mask_set", 8), ("story_mask_clear", 16)])
        cmds = farewell["commands"]
        self.assertEqual(cmds[-3:], [{"kind": "story_or", "flag": {"id": "scenario_0006", "mask": 16}},
                                    {"kind": "party_leave", "character": "viktor"}, {"kind": "end_stream"}])
        texts = {t["id"]: t["tokens"] for t in content["texts"]}
        bodies = [texts[c["text"]] for c in cmds if c["kind"] == "text"]
        self.assertEqual(len(bodies), 3)
        self.assertIn({"kind": "player_name"}, bodies[0])
        self.assertEqual([t["value"] for t in bodies[0] if t["kind"] == "pace"], [5, 3])
        self.assertTrue(exporter.tokens_to_str_preview(bodies[0]).endswith("so take a look around."))

        e44 = next(p for p in self.rooms_by_id["va1_room_0"]["content"]["programs"] if p["id"] == "va1_room_0_e44_ordinary")
        self.assertEqual(e44["conditions"], [{"kind": "story_mask_set", "flag": {"id": "scenario_0006", "mask": 8}}])
        self.assertFalse(any(c["kind"] == "story_or" for c in e44["commands"]))

    def test_keyaki_inn_and_hideout_source_sequence(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        inn = self.rooms_by_id["va3_room_2"]["content"]
        hideout = self.rooms_by_id["va3_room_1"]["content"]

        def commands(content, entity, kind):
            program = next(p for p in content["programs"] if p["entity"] == entity)
            return [c for c in program["commands"] if c["kind"] == kind]

        self.assertEqual(data[0x28CFC:0x28D05], bytes.fromhex("0b 2e 30 0c 1e 1e 04 00 06"))
        for room in ("va3_room_1", "va3_room_2"):
            dialogue = self.rooms_by_id[room]["dialogue"]
            image = next(i for i, pic in enumerate(dialogue["images"]) if pic["character"] == 109)
            self.assertTrue(any(p.get("image") == image for p in dialogue["prefixes"]))
        self.assertEqual(data[0x2BFEC:0x2BFEE], bytes((70, 1)))
        for keeper in (12, 28):
            self.assertEqual(commands(inn, keeper, "inn_stay"), [{"kind": "inn_stay", "amount": 70}])
        self.assertEqual(commands(inn, 11, "inn_stay"), [])
        self.assertEqual([c["options"] for c in commands(inn, 11, "choice")], [2, 2])
        self.assertEqual(data[0x2A3EE:0x2A3F6], bytes.fromhex("07 80 01 33 07 80 02 0a"))
        self.assertEqual(commands(inn, 11, "place_hero"), [{"kind": "place_hero", "x": 51 * 8, "y": 10 * 8}])
        for offset, content, entity, index, mask in (
            (0x2A5FA, inn, 11, 6, 32), (0x2A6FF, inn, 9, 6, 64),
            (0x2923D, hideout, 23, 6, 128), (0x29378, hideout, 24, 7, 1),
        ):
            self.assertEqual(data[offset:offset + 3], bytes((9, index, mask)))
            self.assertEqual(commands(content, entity, "story_or")[0]["flag"],
                             {"id": f"scenario_{index:04d}", "mask": mask})
        self.assertEqual(data[0x2A707:0x2A70B], bytes.fromhex("03 01 25 09"))
        self.assertEqual(commands(inn, 9, "room_transition"), [
            {"kind": "room_transition", "destination": "va3_room_1", "x": 37 * 8, "y": 9 * 8}])
        for offset, content, direction, heading, cells in (
            (0x2A644, inn, "up", 0, 3), (0x291D4, hideout, "down", 2, 4),
        ):
            self.assertEqual(data[offset:offset + 5], bytes((0x32, 0x80, heading, cells, 5)))
            track = next(t for t in content["tracks"] if t["id"].startswith("va3_room_2_e15_" if direction == "up" else "va3_room_1_e03_"))
            self.assertEqual(track["actor"], "hero")
            self.assertEqual(track["commands"], [{"kind": "move", "direction": direction, "cells": cells},
                                                 {"kind": "finish"}])

    def test_bandit_rescue_prerequisites_and_party_return(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        content = self.rooms_by_id["va3_room_1"]["content"]
        program = next(p for p in content["programs"] if p["entity"] == 38)
        self.assertEqual(data[0x29098:0x290A1], bytes.fromhex("07 07 01 08 07 20 0f 23 06"))
        self.assertEqual(program["conditions"], [
            {"kind": "story_mask_set", "flag": {"id": "scenario_0007", "mask": 1}},
            {"kind": "story_mask_clear", "flag": {"id": "scenario_0007", "mask": 32}},
        ])
        self.assertEqual(program["selection"], [{"kind": "party_absent", "index": 35}])
        self.assertEqual(data[0x295CE:0x295D5], bytes.fromhex("12 00 23 1c 00 03 02"))
        header = exporter.scene.ptr_at(data, 0)
        text_tables = exporter.scene.ptr_at(data, header + 20)
        join_table = exporter.scene.ptr_at(data, text_tables + 3 * 4)
        text_offset = exporter.scene.ptr_at(data, join_table + 2 * 4)
        self.assertEqual(exporter.tokens_to_str_preview(exporter.decode_text_tokens(data, text_offset)), "joins party!")
        self.assertEqual(data[0x295D9:0x295DE], bytes.fromhex("1f 02 09 18 20"))
        self.assertEqual(program["commands"][-3:], [
            {"kind": "party_join", "character": "viktor"},
            {"kind": "story_or", "flag": {"id": "scenario_0024", "mask": 32}},
            {"kind": "end_stream"},
        ])
        self.assertEqual([c["options"] for c in program["commands"] if c["kind"] == "choice"], [2, 2, 2])

    def test_tigerwolf_entrance_geometry_and_encounters(self) -> None:
        data, origin = exporter.source("/VA8.BIN")
        point = maindec.mword(0x80170064) - maindec.MBASE + 7 * 14
        row = maindec.body()[point:point + 14]
        self.assertEqual(row[:8], bytes.fromhex("00 00 21 00 2f 00 16 27"))
        descriptor = maindec.mword(maindec.mword(0x8016F67C) + 7 * 4)
        self.assertEqual((maindec.mword(descriptor), maindec.mword(descriptor + 4)), (origin["size"], origin["lba"]))
        entrance = next(e for e in self.field_rooms["world_a"]["exits"] if e["room"] == "va8_room_0")
        self.assertEqual((entrance["x"], entrance["y"], entrance["spawn_x"], entrance["spawn_y"]),
                         (344, 440, row[6] * 8, row[7] * 8))
        start = self.rooms_by_id["va8_room_0"]["content"]
        intro = next(p for p in start["programs"] if p["entity"] == 2)
        self.assertEqual(data[0x2211E:0x22121], bytes((9, 8, 2)))
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": 2}}, intro["commands"])
        return_program = next(p for p in start["programs"] if p["entity"] == 1)
        self.assertEqual(data[0x22074:0x22078], bytes.fromhex("03 fe 21 31"))
        self.assertEqual(return_program["commands"][-1],
                         {"kind": "world_transition", "retain_world_region": True, "x": 43, "y": 57})
        world = self.field_rooms["world_a"]
        self.assertEqual(world["walkable"][57 * (world["width"] // 8) + 43], "0")
        self.assertEqual(world["walkable"][56 * (world["width"] // 8) + 43], "1")
        for room_id, rate in enumerate((2, 2, 3, 2, 3)):
            section = exporter.scene.section_off(data, exporter.scene.room_record(data, room_id)["section"])
            config = exporter.scene.ptr_at(data, section + 56)
            self.assertEqual((data[config], data[config + 2]), (rate, 60))
            self.assertEqual(exporter.scene.ptr_at(data, config + 4), 0x2A8DC)
            encounters = next(r for r in self.journey["field_encounters"]["rooms"] if r["room"] == f"va8_room_{room_id}")
            self.assertEqual((encounters["rate"], encounters["counter_threshold"]), (rate, 60))
            self.assertEqual([c["id"] for c in encounters["candidates"]], [f"va8_ord_{i}" for i in range(1, 6)])
        for room_number, previous, entry in ((2, 1, (65, 39)), (4, 3, (49, 39))):
            previous_room = exporter.scene.room_record(data, previous)
            stream = exporter.scene.entities(data, previous_room)[1]["stream_offsets"][2]
            self.assertEqual(data[stream:stream + 4], bytes((3, room_number, *entry)))
            section = exporter.scene.section_off(data, exporter.scene.room_record(data, room_number)["section"])
            from export_first_room import walkable_grid
            _, _, ground_only = walkable_grid(data, section)
            projected = self.field_rooms[f"va8_room_{room_number}"]["walkable"]
            self.assertGreater(sum(a == "1" and b == "0" for a, b in zip(projected, ground_only)), 0)
        room = self.field_rooms["va8_room_2"]
        section = exporter.scene.section_off(data, exporter.scene.room_record(data, 2)["section"])
        self.assertEqual((room["width"], room["height"]), (
            int.from_bytes(data[section:section + 2], "little") * 16,
            int.from_bytes(data[section + 2:section + 4], "little") * 16))
        self.assertEqual(room["height"], 352)
        companion = exporter.scene.section_off(data, exporter.scene.room_record(data, 2)['byte9'])
        self.assertEqual(exporter.scene.ptr_at(data, companion + 0x14), exporter.scene.ptr_at(data, section + 0x18))
        self.assertEqual(room['draws'][0]['rect']['h'], room['height'])
        self.assertEqual(room['draws'][1]['rect']['h'], int.from_bytes(data[companion + 2:companion + 4], 'little') * 16)
        self.assertEqual(room['draws'][1]['rect']['h'], 384)

    def test_northern_tigerwolf_and_sarady_arrival(self) -> None:
        mountain, _ = exporter.source("/VA8.BIN")
        town, town_origin = exporter.source("/VA5.BIN")
        for point, expected, room_id, spawn, origin in (
            (8, "00 09 17 00 1a 00 11 08", "va8_room_9", (136, 64), {"size": len(mountain), "lba": 51625}),
            (4, "00 00 16 00 08 00 1d 2b", "va5_room_0", (232, 344), town_origin),
        ):
            offset = maindec.mword(0x80170064) - maindec.MBASE + point * 14
            record = maindec.body()[offset:offset + 14]
            self.assertEqual(record[:8], bytes.fromhex(expected))
            descriptor = maindec.mword(maindec.mword(0x8016F67C) + point * 4)
            self.assertEqual((maindec.mword(descriptor), maindec.mword(descriptor + 4)), (origin["size"], origin["lba"]))
            entrance = next(e for e in self.field_rooms["world_a"]["exits"] if e["room"] == room_id)
            self.assertEqual((entrance["x"], entrance["y"]),
                             ((int.from_bytes(record[2:4], "little") + 10) * 8,
                              (int.from_bytes(record[4:6], "little") + 8) * 8))
            self.assertEqual((entrance["spawn_x"], entrance["spawn_y"]), spawn)
        for number, rate in ((6, 2), (7, 3), (8, 2), (9, 2)):
            section = exporter.scene.section_off(mountain, exporter.scene.room_record(mountain, number)["section"])
            config = exporter.scene.ptr_at(mountain, section + 56)
            self.assertEqual(mountain[config:config + 8], bytes((rate, 0, 60, 0)) + bytes.fromhex("dc a8 03 80"))
            encounter = next(r for r in self.journey["field_encounters"]["rooms"] if r["room"] == f"va8_room_{number}")
            self.assertEqual((encounter["rate"], encounter["counter_threshold"]), (rate, 60))
            self.assertEqual([c["id"] for c in encounter["candidates"]], [f"va8_ord_{i}" for i in range(1, 6)])
        northern = self.rooms_by_id["va8_room_9"]["content"]["programs"]
        leave = next(p for p in northern if p["entity"] == 2)
        self.assertEqual(mountain[0x22910:0x22914], bytes.fromhex("03 fe 16 1a"))
        self.assertEqual(leave["commands"][-1], {"kind": "world_transition", "retain_world_region": True, "x": 32, "y": 34})
        programs = {p["entity"]: p for p in self.rooms_by_id["va5_room_0"]["content"]["programs"]}
        self.assertEqual(town[0x13A40:0x13A42], bytes.fromhex("03 ff"))
        self.assertEqual(maindec.mword(0x80131DF8), 0x24420002)  # Return camera adds two source rows.
        self.assertEqual(programs[0]["commands"][-1], {"kind": "world_transition", "return_to_entry": True})
        self.assertEqual(town[0x13AE1:0x13AE4], bytes.fromhex("09 08 80"))
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": 128}}, programs[4]["commands"])
        self.assertIn({"kind": "story_mask_clear", "flag": {"id": "scenario_0008", "mask": 128}}, programs[4]["conditions"])
        self.assertNotIn("va5_room_0", [r["room"] for r in self.journey["field_encounters"]["rooms"]])
        for room, entities in (("va8_room_7", (2,)), ("va8_room_8", (3,)), ("va8_room_9", (4, 5))):
            for entity in entities:
                reference = self.rooms_by_id[room]["population"]["entities"][entity]["event"]
                self.assertEqual(reference["status"], "resolved")
        for entity in (2, 3):
            self.assertEqual(self.rooms_by_id["va5_room_0"]["population"]["entities"][entity]["event"]["status"], "resolved")

    def test_sarady_overnight_delivery_and_morning(self) -> None:
        data, _ = exporter.source("/VA5.BIN")
        room = self.rooms_by_id["va5_room_1"]
        programs = {p["entity"]: p for p in room["content"]["programs"]}
        guard = programs[0]
        self.assertIn({"kind": "story_mask_clear", "flag": {"id": "scenario_0009", "mask": 16}}, guard["conditions"])
        self.assertFalse(any(c["kind"] == "align_hero" for c in guard["commands"]))
        for entity, offset, mask in ((2, 0x13C3E, 1), (13, 0x13CB1, 2), (6, 0x13CD1, 4), (3, 0x13E7F, 8), (4, 0x13F83, 16)):
            self.assertEqual(data[offset:offset + 3], bytes((9, 9, mask)))
            self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0009", "mask": mask}}, programs[entity]["commands"])
        stay = programs[13]["commands"]
        self.assertEqual([c["options"] for c in stay if c["kind"] == "choice"], [2])
        self.assertFalse(any(c["kind"] in ("inn_stay", "money_edit", "service") for c in stay))
        self.assertEqual(data[0x13FA3:0x13FA6], bytes.fromhex("43 06 01"))
        self.assertEqual(data[0x1481C:0x1481E], bytes.fromhex("32 01"))
        self.assertIn({"kind": "inn_stay", "amount": 50}, programs[15]["commands"])
        self.assertEqual(data[0x13C91:0x13C99], bytes.fromhex("07 80 01 1d 07 80 02 13"))
        self.assertIn({"kind": "place_hero", "x": 232, "y": 152}, stay)
        odessa = room["population"]["entities"][6]
        self.assertEqual(data[0x13C71:0x13C79], bytes.fromhex("07 00 01 23 07 00 02 23"))
        self.assertEqual((odessa["position"]["x"], odessa["position"]["y"]), (280, 280))
        delivery = programs[3]["commands"]
        self.assertEqual(data[0x13E7C:0x13E7F], bytes.fromhex("50 01 b1"))
        take, = [c for c in delivery if c["kind"] == "shared_inventory_edit"]
        self.assertEqual(take["inventory"]["take"], "blueprint")
        self.assertLess(delivery.index(take), next(i for i, c in enumerate(delivery) if c["kind"] == "story_or"))
        self.assertEqual(data[0x13F61:0x13F69], bytes.fromhex("07 80 01 27 07 80 02 17"))
        self.assertEqual(data[0x13F80:0x13F83], bytes.fromhex("4c 02 ff"))
        for entity in (4, 5):
            self.assertIn({"kind": "place_hero", "x": 312, "y": 184}, programs[entity]["commands"])
            self.assertIn({"kind": "party_restore"}, programs[entity]["commands"])

    def test_ledon_overnight_source_handoff_and_morning(self) -> None:
        data, _ = exporter.source("/VA8.BIN")
        outside = {p["entity"]: p for p in self.rooms_by_id["va8_room_5"]["content"]["programs"]}
        inside = {p["entity"]: p for p in self.rooms_by_id["va8_room_10"]["content"]["programs"]}
        self.assertEqual(data[0x224C5:0x224C8], bytes.fromhex("09 08 04"))
        self.assertEqual(data[0x22533:0x22537], bytes.fromhex("03 0a 17 26"))
        self.assertEqual(data[0x22A4D:0x22A55], bytes.fromhex("07 80 01 27 07 80 02 1c"))
        self.assertEqual(outside[5]["commands"][-1],
                         {"kind": "room_transition", "destination": "va8_room_10", "x": 312, "y": 224})
        self.assertEqual(outside[3]["commands"][-1],
                         {"kind": "room_transition", "destination": "va8_room_10", "x": 184, "y": 304})
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": 4}}, outside[5]["commands"])
        tea = inside[3]["commands"]
        self.assertEqual([c["options"] for c in tea if c["kind"] == "choice"], [2, 2, 2])
        self.assertEqual(data[0x22BFC:0x22C00], bytes.fromhex("03 0a ff 1c"))
        entities = exporter.scene.entities(data, exporter.scene.room_record(data, 10))
        self.assertEqual(entities[4]["stream_offsets"][1], entities[5]["stream_offsets"][1])
        predicate = entities[5]["stream_offsets"][1]
        self.assertEqual(data[predicate:predicate + 10], bytes.fromhex("0b ff ff 0c 1c 1c 08 08 08 06"))
        self.assertFalse(any(c["kind"] == "room_transition" for c in tea))
        self.assertEqual(data[0x22E47:0x22E4F], bytes.fromhex("07 80 01 0b 07 80 02 0b"))
        self.assertIn({"kind": "place_hero", "x": 88, "y": 88}, tea)
        self.assertEqual(data[0x22E82:0x22E85], bytes.fromhex("09 08 08"))
        self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": 8}}, tea)
        self.assertIn({"kind": "hero_x_inclusive", "min": 255, "max": 255}, inside[5]["selection"])  # Scene 5 uses off-map reload sentinel x=255 while scene 3 folds the continuation.
        for entity, offset, mask in ((11, 0x22E97, 16), (12, 0x22EF7, 32), (6, 0x22FAB, 64)):
            self.assertEqual(data[offset:offset + 3], bytes((9, 8, mask)))
            self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": mask}}, inside[entity]["commands"])
        self.assertEqual(data[0x22FB3:0x22FB6], bytes.fromhex("4c 02 ff"))
        self.assertIn({"kind": "party_restore"}, inside[6]["commands"])
        self.assertEqual(inside[6]["commands"][-1],
                         {"kind": "room_transition", "destination": "va8_room_5", "x": 128, "y": 128})
        for entity, offsets, expected in (
            (7, (0x22E17, 0x22E1B), (5, 11)),
            (8, (0x22E2F, 0x22E33), (17, 11)),
            (9, (0x22E3B, 0x22E3F), (17, 21)),
            (10, (0x22E23, 0x22E27), (5, 21)),
            (11, (0x22E4F, 0x22E53), (31, 22)),
            (12, (0x22E57, 0x22E5B), (36, 22)),
        ):
            x, y = (data[offset + 3] for offset in offsets)
            self.assertEqual((x, y), expected)
            character = self.rooms_by_id["va8_room_10"]["population"]["entities"][entity]
            self.assertEqual((character["position"]["x"], character["position"]["y"]), (x * 8, y * 8))
            self.assertIn({"kind": "story_mask_set", "flag": {"id": "scenario_0008", "mask": 8}}, character["classification"]["terms"])

    def test_odessa_return_choices_and_blueprint(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        content = self.rooms_by_id["va3_room_1"]["content"]
        programs = {p["entity"]: p for p in content["programs"]}
        self.assertEqual(data[0x29EB1:0x29EB9], bytes.fromhex("07 00 01 11 07 00 02 24"))
        for entity in (6, 7):
            actor = self.rooms_by_id["va3_room_1"]["population"]["entities"][entity]
            self.assertEqual((actor['position']['x'], actor['position']['y']), (0, 0))
            program = next(program for program in self.rooms_by_id['va3_room_1']['content']['programs'] if program['entity'] == entity)
            self.assertEqual(program['owner_actors'], ['va3_room_1_actor_04_109'])
            commands = programs[entity]["commands"]
            joins = [c for c in commands if c["kind"] == "party_join"]
            self.assertEqual(joins, [{"kind": "party_join", "character": "odessa", "level_advances": 5}])
            item, = [c for c in commands if c["kind"] == "shared_inventory_edit"]
            self.assertEqual(item["inventory"]["give"], "blueprint")
            self.assertIn({"kind": "story_or", "flag": {"id": "scenario_0008", "mask": 1}}, commands)
        self.assertEqual(data[0x2974D:0x29750], bytes((9, 7, 128)))
        self.assertEqual(data[0x29877:0x2987E], bytes.fromhex("4b 00 6d 05 50 00 b1"))
        self.assertEqual(data[0x299B5:0x299BC], bytes.fromhex("4b 00 6d 05 50 00 b1"))
        self.assertEqual(data[0x29893:0x29896], bytes((9, 8, 1)))
        self.assertEqual(data[0x299D3:0x299D6], bytes((9, 8, 1)))
        profile = next(p for p in self.trial["party"] if p["id"] == "odessa")
        self.assertEqual(profile["rune"], "wind")
        self.assertTrue(profile["rune_locked"])
        self.assertTrue(any(g["id"] == "odessa" for g in self.trial["unite_graphics"]))

    def test_lenankamp_raid_source_formation_and_profiles(self) -> None:
        data, _ = exporter.source("/VA3.BIN")
        base = 0x80010000
        word = lambda offset: struct.unpack_from("<I", data, offset)[0]
        # Independently follow room -> section -> resource slot -> battle directory.
        root = word(0) - base
        room = word(root + 8) - base + 16
        sections = word(root + 4) - base
        section = word(sections + 4 * data[room + 5]) - base
        self.assertEqual(word(section + 28), 13)
        resources = word(section + 32) - base
        directory = word(resources + 4 * word(section + 28)) - base
        self.assertEqual(directory, 0x51EF8)
        selectors = word(directory + 8) - base
        self.assertEqual(word(selectors), 1)
        descriptor = word(selectors + 4) - base
        self.assertEqual(word(descriptor), 5)
        self.assertEqual(list(data[descriptor + 4:descriptor + 10]), [3, 2, 3, 1, 1, 0])
        encounter = next(e for e in self.trial["encounters"] if e["id"] == "va3_raid")
        self.assertEqual(encounter["enemies"], [f"va3_soldier_{i}" for i in (3, 2, 3, 1, 1)])
        self.assertEqual(encounter["source_slots"], list(range(5)))
        positions = word(word(descriptor + 20) - base) - base
        enemies = word(directory + 12) - base
        expected_positions = []
        for slot, local_id in enumerate((3, 2, 3, 1, 1)):
            record = word(enemies + 4 * local_id) - base
            x, y, z = struct.unpack_from("<3h", data, positions + 6 * slot)
            flags = struct.unpack_from("<H", data, record + 38)[0]
            expected_positions.append({"x": x - 128, "y": y, "z": z - (10 if flags & 32 else 0)})
        self.assertEqual(encounter["positions"], expected_positions)
        self.assertEqual(encounter["escape_allowed"], not bool(word(descriptor + 12) & 0x80000000))
        self.assertEqual(encounter["battlefield"], "va3_raid")
        proof = json.loads((self.pkg_dir / "battle/provenance.json").read_text())["lenankamp_raid"]
        self.assertEqual(proof["source"], exporter.source("/VA3.BIN")[1])
        self.assertEqual(proof["directory_offset"], directory)
        self.assertIn("lzss.py/2.0.0", proof["codec"])
        self.assertEqual(proof["media_acceptance"], "pending")
        with Image.open(self.pkg_dir / "battle/spell_effects.png") as image:
            self.assertLessEqual(max(image.size), 4096)
        programs = {p["entity"]: p for p in self.rooms_by_id["va3_room_1"]["content"]["programs"]}
        for entity, offset, mask in ((30, 0x29E15, 1), (31, 0x29E15, 1), (32, 0x29E66, 2), (33, 0x29E66, 2)):
            self.assertEqual(data[offset:offset + 5], bytes((9, 47, mask, 0x47, 0)))
            commands = programs[entity]["commands"]
            flag = {"id": "scenario_0047", "mask": mask}
            self.assertIn({"kind": "story_mask_clear", "flag": flag}, programs[entity]["conditions"])
            writer, = [i for i, c in enumerate(commands) if c.get("flag") == flag]
            battle_index, = [i for i, c in enumerate(commands) if c["kind"] == "battle"]
            self.assertLess(writer, battle_index)
            self.assertEqual(commands[battle_index], {"kind": "battle", "battle": "va3_raid", "defeat_ends_run": True})
        for local_id, offset in ((1, 0x599B4), (2, 0x5AE08), (3, 0x5BFA8)):
            record = word(enemies + 4 * local_id) - base
            self.assertEqual(record, offset)
            profile = next(e for e in self.trial["enemies"] if e["id"] == f"va3_soldier_{local_id}")
            level, hp, attack, skill, defense, speed = struct.unpack_from("<6H", data, record + 16)
            self.assertEqual((profile["level"], profile["max_hp"]), (level, hp))
            self.assertEqual(profile["stats"], dict(attack=attack, skill=skill, defense=defense,
                speed=speed, magic=data[record + 28], luck=data[record + 29]))
            self.assertEqual(profile["target_policy"], "any_row" if local_id == 1 else "front_first")

    def test_rockland_rescue_formations_and_flags(self) -> None:
        data, _ = exporter.source("/VA2.BIN")
        section = exporter.scene.section_off(data, exporter.scene.room_record(data, 3)["section"])
        first_battle_slot = int.from_bytes(data[section + 28:section + 32], "little")
        table = exporter.scene.ptr_at(data, section + 32)
        self.assertEqual(first_battle_slot, 7)
        for selector, offset, encounter_id, roster in (
            (0, 0x405B0, "va2_rescue_pair", [2, 2, 0, 0, 0, 0]),
            (1, 0x405E8, "va2_rescue_squad", [3, 3, 3, 1, 1, 4]),
        ):
            directory = exporter.scene.ptr_at(data, table + 4 * (first_battle_slot + selector))
            self.assertEqual(directory, offset)
            _, formations = battle_placement.directory_encounters(data, directory, 0x80010000)
            selectors = int.from_bytes(data[directory + 8:directory + 12], "little") - 0x80010000
            self.assertEqual(int.from_bytes(data[selectors:selectors + 4], "little"), 1)
            descriptor = int.from_bytes(data[selectors + 4:selectors + 8], "little") - 0x80010000
            self.assertEqual(list(data[descriptor + 4:descriptor + 10]), roster)
            self.assertEqual(formations[0]["roster"], roster)
            encounter = next(e for e in self.trial["encounters"] if e["id"] == encounter_id)
            self.assertEqual(encounter["source_slots"], [s["slot"] for s in formations[0]["slots"]])
            self.assertEqual(encounter["positions"], [dict(zip("xyz", s["world"])) for s in formations[0]["slots"]])
            self.assertEqual(encounter["battlefield"], "va2_rescue")
        captain = next(e for e in self.trial["enemies"] if e["id"] == "va2_captain")
        self.assertEqual(captain["level"], int.from_bytes(data[0x4D230:0x4D232], "little"))
        self.assertEqual(captain["max_hp"], int.from_bytes(data[0x4D232:0x4D234], "little"))
        programs = {p["entity"]: p for p in self.rooms_by_id["va2_room_3"]["content"]["programs"]}
        for entity, source_offset, mask, selector in ((18, 0x27408, 1, 0), (19, 0x27454, 2, 0), (21, 0x274BC, 4, 1)):
            self.assertEqual(data[source_offset:source_offset + 3], bytes((9, 46, mask)))
            commands = programs[entity]["commands"]
            self.assertTrue(any(c.get("flag") == {"id": "scenario_0046", "mask": mask} for c in commands))
            battle, = [c for c in commands if c["kind"] == "battle"]
            self.assertEqual(battle["battle"], "va2_rescue_pair" if selector == 0 else "va2_rescue_squad")
            self.assertTrue(battle["defeat_ends_run"])

    def test_o03_rockland_opening_battles(self) -> None:
        enc = next(e for e in self.trial["encounters"] if e["id"] == "va2_s0_e11")
        self.assertFalse(enc["escape_allowed"])
        self.assertEqual(enc["battlefield"], "va2_s0")
        self.assertEqual(enc["enemies"], ["empire_soldier_3", "empire_soldier_2", "empire_soldier_1"])
        self.assertTrue(any(b["id"] == "va2_s0" for b in self.trial.get("battlefields", [])))

        expected_refs = [
            {"room": "va2_room_0", "program": f"va2_room_0_e{i}_ordinary"} for i in (35, 36, 37)
        ] + [
            {"room": "va4_room_3", "program": "va4_room_3_e03_ordinary"},
            {"room": "va7_room_9", "program": "va7_room_9_e02_ordinary"},
            {"room": "va7_room_9", "program": "va7_room_9_e03_ordinary"},
            {"room": "va7_room_13", "program": "va7_room_13_e01_ordinary"},
            {"room": "va7_room_13", "program": "va7_room_13_e03_ordinary"},
        ]
        self.assertEqual(self.fe["opening_battles"], expected_refs)
        va2_progs = {p["id"]: p for p in self.rooms_by_id["va2_room_0"]["content"]["programs"]}
        for ref in expected_refs[:3]:
            prog = va2_progs[ref["program"]]
            battles = [c for c in prog["commands"] if c["kind"] == "battle"]
            self.assertEqual(len(battles), 1)
            self.assertEqual(battles[0]["battle"], "va2_s0_e11")
            self.assertTrue(battles[0]["defeat_ends_run"])
            aligns = [c for c in prog["commands"] if c["kind"] == "align_hero"]
            self.assertTrue(aligns)
            for cmd in aligns:
                self.assertEqual(cmd.get("wait"), {"kind": "alignment", "id": "alignment"})

    def test_o04_and_b16_party_joins_and_soul_eater(self) -> None:
        def ops_of(room_id: str, pid: str) -> list[tuple[str, dict]]:
            prog = next(p for p in self.rooms_by_id[room_id]["content"]["programs"] if p["id"] == pid)
            return [(c["kind"], c) for c in prog["commands"]]

        self.assertIn("ted", [c["character"] for k, c in ops_of("va1_room_2", "va1_room_2_e02_ordinary") if k == "party_join"])
        self.assertIn("ted", [c["character"] for k, c in ops_of("va1_room_2", "va1_room_2_e21_ordinary") if k == "party_leave"])
        self.assertIn("gremio", [c["character"] for k, c in ops_of("va1_room_2", "va1_room_2_e22_ordinary") if k == "party_join"])
        self.assertEqual(
            [c["character"] for k, c in ops_of("va1_room_1", "va1_room_1_e22_ordinary") if k == "party_join"],
            ["pahn", "cleo"],
        )
        for pid in ("va1_room_1_e19_ordinary", "va1_room_1_e20_ordinary", "va1_room_1_e21_ordinary"):
            self.assertIn("ted", [c["character"] for k, c in ops_of("va1_room_1", pid) if k == "party_join"])
        self.assertIn("ted", [c["character"] for k, c in ops_of("va1_room_0", "va1_room_0_e39_ordinary") if k == "party_leave"])

        e08_ops = ops_of("va1_room_1", "va1_room_1_e08_interaction")
        self.assertIn("pahn", [c["character"] for k, c in e08_ops if k == "party_leave"])
        self.assertIn(("hero", "soul_eater"), [(c["character"], c["rune"]) for k, c in e08_ops if k == "rune_grant"])

        viktor_joins = [c for k, c in ops_of("va1_room_0", "va1_room_0_e37_interaction") if k == "party_join"]
        self.assertEqual([(c["character"], c.get("level_advances")) for c in viktor_joins], [("viktor", 6)])

    def test_glyphs_portraits_and_reproducibility(self) -> None:
        font_chars = {g["character"] for g in self.ui["glyphs"]}
        self.assertIn(":", font_chars)
        self.assertIn("&", font_chars)
        with Image.open(self.pkg_dir / "atlas.png") as atlas:
            aw, ah = atlas.size
        for room in self.fe["rooms"]:
            for txt in room["content"]["texts"]:
                for tok in txt["tokens"]:
                    if tok["kind"] == "glyph":
                        self.assertIn(tok["text"], font_chars)
            for img in room["dialogue"]["images"]:
                r = img["atlas_rect"]
                self.assertGreaterEqual(r["x"], 0)
                self.assertGreaterEqual(r["y"], 0)
                self.assertLessEqual(r["x"] + r["w"], aw)
                self.assertLessEqual(r["y"] + r["h"], ah)
            for actor in room["actors"]:
                for pose in actor["poses"]:
                    r = pose["rect"]
                    self.assertLessEqual(r["x"] + r["w"], aw)
                    self.assertLessEqual(r["y"] + r["h"], ah)

        rebuilt = exporter.build_package(ROOT / "kit/work/build/opening/canonical_field_art.json")
        self.assertEqual(rebuilt, self.fe)

    def test_o06_o07_m01_b01_b02_b04_contracts(self) -> None:
        def find_prog(room_id: str, pid: str) -> dict:
            return next(p for p in self.rooms_by_id[room_id]["content"]["programs"] if p["id"] == pid)

        # O06 VA4 Golem + party split/rejoin + flight back
        golem = find_prog("va4_room_3", "va4_room_3_e03_ordinary")
        self.assertEqual([c["battle"] for c in golem["commands"] if c["kind"] == "battle"], ["va4_golem"])
        e08 = find_prog("va4_room_10", "va4_room_10_e08_interaction")
        self.assertEqual([c["character"] for c in e08["commands"] if c["kind"] == "party_leave"], ["gremio", "cleo", "pahn", "ted"])
        e10 = find_prog("va4_room_10", "va4_room_10_e10_ordinary")
        self.assertEqual([c["character"] for c in e10["commands"] if c["kind"] == "party_join"], ["gremio", "pahn", "cleo", "ted"])

        # O07 VA7 scripted fights (Queen Ant, Ted solo Soul Eater, Bandits, Varkas & Sydonia)
        r9_b1 = find_prog("va7_room_9", "va7_room_9_e03_ordinary")
        self.assertEqual(
            [(c["kind"], c["character"]) for c in r9_b1["commands"] if c["kind"] in ("party_leave", "party_join")],
            [
                ("party_leave", "hero"),
                ("party_leave", "gremio"),
                ("party_leave", "cleo"),
                ("party_leave", "pahn"),
                ("party_join", "hero"),
                ("party_leave", "ted"),
                ("party_join", "gremio"),
                ("party_join", "pahn"),
                ("party_join", "cleo"),
                ("party_join", "ted"),
            ],
        )
        encs = {e["id"]: e for e in self.trial["encounters"]}
        self.assertEqual(encs["va7_r9_b0"]["scripted_finish"], {"after_round": 2, "wait_ticks": 12})
        self.assertEqual(encs["va7_r9_b1"]["scripted_finish"], {"after_round": 1, "wait_ticks": 60})
        self.assertEqual(encs["va7_r13_b1"]["battlefield"], "va7_ord1")

        # M03 Kwaba gates + VB6 0x0F Elf spell loop
        self.assertEqual(find_prog("va6_room_0", "va6_room_0_e03_ordinary")["commands"][-2]["y"], 136)
        self.assertEqual(find_prog("va6_room_0", "va6_room_0_e04_ordinary")["commands"][-2]["y"], 184)
        vb6_spell = find_prog("vb6_room_1", "vb6_room_1_e02_ordinary")
        self.assertEqual([t["index"] for t in vb6_spell["selection"] if t["kind"] == "party_absent"], [4, 9, 75, 51])

        # B01 + B02 + B04 VB6 forest encounters & vb6_ord battlefield
        fe_cfg = self.journey["field_encounters"]
        self.assertEqual(fe_cfg["schema"], "suikoden-field-movement-encounters/3")
        self.assertEqual(fe_cfg["suppress_when"], {"kind": "story_mask_set", "flag": {"id": "scenario_0043", "mask": 64}})
        self.assertTrue(fe_cfg["clear_suppression_on_world_entry"])
        by_room = {r["room"]: r for r in fe_cfg["rooms"]}
        for rn in range(1, 6):
            row = by_room[f"vb6_room_{rn}"]
            self.assertEqual((row["rate"], row["counter_threshold"]), (2, 60))
            self.assertEqual([c["id"] for c in row["candidates"]], [f"vb6_ord_{i}" for i in range(1, 9)])
        vb6_bf = next(b for b in self.trial["battlefields"] if b["id"] == "vb6_ord")
        self.assertEqual((vb6_bf["ground"]["across"], vb6_bf["ground"]["down"], len(vb6_bf["scenery"])), (16, 16, 0))
        for i in range(1, 9):
            self.assertEqual(encs[f"vb6_ord_{i}"]["battlefield"], "vb6_ord")

    def test_chapter1_services_and_sarady_detour(self) -> None:
        def find_prog(room_id: str, pid: str) -> dict:
            return next(p for p in self.rooms_by_id[room_id]["content"]["programs"] if p["id"] == pid)

        va1_r6_item = find_prog("va1_room_6", "va1_room_6_e03_interaction")
        self.assertIn({"kind": "service", "selector": 2, "index": 0, "shop_items": ["medicine", "antitoxin"]}, va1_r6_item["commands"])
        va1_r6_armor = find_prog("va1_room_6", "va1_room_6_e07_interaction")
        self.assertIn(
            {"kind": "service", "selector": 2, "index": 3, "shop_items": ["bandanna", "headband", "robe", "tunic", "leather_coat", "wooden_shoes", "wing_boots"]},
            va1_r6_armor["commands"],
        )
        va1_r8_rune = find_prog("va1_room_8", "va1_room_8_e02_interaction")
        self.assertIn({"kind": "service", "selector": 4, "index": 2}, va1_r8_rune["commands"])
        va1_r11_appraise = find_prog("va1_room_11", "va1_room_11_e02_interaction")
        self.assertIn({"kind": "service", "selector": 5, "index": 1}, va1_r11_appraise["commands"])
        va5_r2_shop = find_prog("va5_room_2", "va5_room_2_e04_interaction")
        self.assertIn({"kind": "service", "selector": 2, "index": 0, "shop_items": ["medicine", "water_crystal"]}, va5_r2_shop["commands"])

        fortune = find_prog("va5_room_3", "va5_room_3_e01_interaction")
        prosperity = find_prog("va5_room_3", "va5_room_3_e02_interaction")
        self.assertEqual([c["item_name"] for c in fortune["commands"] if c["kind"] == "chest_grant"], ["fortune_crystal"])
        self.assertEqual([c["item_name"] for c in prosperity["commands"] if c["kind"] == "chest_grant"], ["prosperity_crystal"])
        for door_ent, dest in ((8, "va1_room_6"), (10, "va1_room_6"), (12, "va1_room_7"), (14, "va1_room_8"), (16, "va1_room_9"), (18, "va1_room_11"), (20, "va1_room_13"), (22, "va1_room_14"), (24, "va1_room_15")):
            door = find_prog("va1_room_0", f"va1_room_0_e{door_ent:02d}_ordinary")
            self.assertEqual([c["destination"] for c in door["commands"] if c["kind"] == "room_transition"], [dest])

    def test_source_chests_keep_their_flag_on_success_and_message_on_both_outcomes(self) -> None:
        import item_tables
        main, _ = exporter.source('MAIN.EXE')
        base = struct.unpack_from('<I', main, 24)[0]
        for address, word in {
            0x80137374: 0xA0480478, 0x80137384: 0xA0470479,
            0x801379D8: 0x30420020, 0x80137A5C: 0x00431026,
            0x80137A60: 0xA0820190, 0x8013BB30: 0x00431025,
            0x8012D528: 0x94820474, 0x8012D538: 0x0C04DE6B,
        }.items():
            self.assertEqual(struct.unpack_from('<I', main, 2048 + address - base)[0], word)
            self.assertEqual(maindec.mword(address), word)
        count = 0
        for room in self.fe['rooms']:
            file, number = exporter.ROOM_TO_SRC[room['room']]
            data, _ = exporter.source(file)
            entities = exporter.scene.entities(data, exporter.scene.room_record(data, number))
            for program, entity in self.source_programs(room, entities):
                start = entity['stream_offsets'][2]
                raw = data[start:start + 9]
                if entity['flags'] != 0x20 or len(raw) != 9 or raw[0] != 9 or raw[3:5] != b'\x41\x74' or raw[5] != 0x49 or raw[7:] != b'\x49\xff':
                    continue
                count += 1
                classification = entity['stream_offsets'][0]
                self.assertEqual(data[classification:classification + 4], bytes((8, raw[1], raw[2], 6)))
                commands = program['commands']
                grant = commands[0]
                self.assertEqual(grant['kind'], 'chest_grant')
                self.assertEqual(grant['flag'], {'id': exporter.story_id(raw[1]), 'mask': raw[2]})
                self.assertFalse(any(c['kind'] == 'story_or' and c['flag'] == grant['flag'] for c in commands))
                failure = grant['failure_target']
                success_text = next(c for c in commands[1:failure] if c['kind'] == 'text')
                failure_text = next(c for c in commands[failure:] if c['kind'] == 'text')
                self.assertEqual(success_text['text'], failure_text['text'])
                message = next(t for t in room['content']['texts'] if t['id'] == success_text['text'])
                self.assertEqual(message['tokens'], exporter.decode_text_tokens(item_tables.acquisition_message(raw[6]), 0))
                for offset in (1, failure + 1):
                    self.assertEqual(commands[offset]['actor'], 'hero')
                    anchor = next(a for a in room['dialogue']['anchors'] if a['program'] == program['id'] and a['command'] == offset)
                    self.assertEqual(anchor['actor'], 'hero')
        self.assertEqual(count, 83)

    def test_chapter2_rockland_and_mt_seifu_chests_and_services(self) -> None:
        def find_prog(room_id: str, pid: str) -> dict:
            return next(p for p in self.rooms_by_id[room_id]["content"]["programs"] if p["id"] == pid)

        inn_stay = find_prog("va2_room_4", "va2_room_4_e01_interaction")
        self.assertIn({"kind": "inn_stay", "amount": 30}, inn_stay["commands"])
        self.assertEqual([c["options"] for c in inn_stay["commands"] if c["kind"] == "choice"], [2])
        item_shop = find_prog("va2_room_5", "va2_room_5_e01_interaction")
        self.assertIn({"kind": "service", "selector": 2, "index": 0, "shop_items": ["medicine", "escape_talisman", "antitoxin"]}, item_shop["commands"])
        armory = find_prog("va2_room_6", "va2_room_6_e03_interaction")
        self.assertIn(
            {"kind": "service", "selector": 2, "index": 2, "shop_items": ["headband", "tunic", "leather_coat", "gloves", "leggings", "wooden_shield"]},
            armory["commands"],
        )
        for room_id, pid, item in (
            ("va2_room_3", "va2_room_3_e27_interaction", "medicine"),
            ("va2_room_7", "va2_room_7_e05_interaction", "brass_armor"),
            ("va2_room_8", "va2_room_8_e01_interaction", "hex_doll"),
            ("va7_room_1", "va7_room_1_e02_interaction", "boots"),
            ("va7_room_1", "va7_room_1_e03_interaction", "medicine"),
            ("va7_room_3", "va7_room_3_e01_interaction", "vase"),
            ("va7_room_6", "va7_room_6_e02_interaction", "medicine"),
            ("va7_room_6", "va7_room_6_e04_interaction", "leggings"),
            ("va7_room_11", "va7_room_11_e02_interaction", "thunder_rune_piece"),
        ):
            prog = find_prog(room_id, pid)
            self.assertEqual([c["item_name"] for c in prog["commands"] if c["kind"] == "chest_grant"], [item])
        for room_id, pid, amount in (
            ("va2_room_9", "va2_room_9_e01_interaction", 700),
            ("va2_room_9", "va2_room_9_e02_interaction", 1000),
            ("va7_room_4", "va7_room_4_e01_interaction", 1000),
        ):
            prog = find_prog(room_id, pid)
            self.assertIn({"kind": "money_edit", "parameter": 3, "amount": amount}, prog["commands"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
