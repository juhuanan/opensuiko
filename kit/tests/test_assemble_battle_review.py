#!/usr/bin/env python3
"""Candidate assembly preserves inputs and publishes only after checks pass."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import assemble_battle_review as assembly


class Assembly(unittest.TestCase):
    def test_regional_battlefield_import_binds_matching_formations_and_preserves_atlas_prefixes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate, source = root / 'journey', root / 'region'
            battle = candidate / 'battle'
            battle.mkdir(parents=True)
            source.mkdir()
            position = dict(x=4, y=5, z=6)
            formation = dict(id='regional_fight', enemies=['enemy'], source_slots=[2],
                             positions=[position], enemy_rows=['front'])
            ground = dict(across=1, down=1, vertices=[position] * 4, tiles=[0])
            scenery = dict(position=position, sprite=dict(rect=dict(x=1, y=1, w=2, h=2), anchor_x=1, anchor_y=2))
            original = dict(schema='suikoden-battle-trial/43', encounters=[formation, dict(id='fallback')],
                            ground=ground, scenery=[], atlas='actors.png')
            trial = battle / 'trial.json'
            trial.write_text(json.dumps(original))
            (battle / 'provenance.json').write_text('{}')
            Image.new('RGBA', (64, 32), (20, 10, 5, 255)).save(battle / 'ground.png')
            Image.new('RGBA', (32, 4), (40, 50, 60, 255)).save(battle / 'actors.png')
            (source / 'trial.json').write_text(json.dumps(dict(
                ground=ground, scenery=[scenery], encounters=[formation], atlas='actors.png')))
            (source / 'provenance.json').write_text(json.dumps(dict(
                schema='suikoden-world-actor-proof/1', region='coast', source={'file': 'coast.bin'},
                encounters=[formation['id']])))
            Image.new('RGBA', (32, 32), (7, 8, 9, 255)).save(source / 'ground.png')
            Image.new('RGBA', (8, 8), (10, 100, 200, 128)).save(source / 'actors.png')
            (source / 'manifest.json').write_text(json.dumps(dict(
                schema='suikoden-world-actor-manifest/1',
                files={path.name: assembly.bundle_macos.digest(path) for path in source.iterdir()})))

            regional_ground = source / 'ground.png'
            original_pixels = regional_ground.read_bytes()
            regional_ground.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'source hash/path mismatch: ground.png'):
                assembly.append_battlefield.append(candidate, source)
            regional_ground.write_bytes(original_pixels)

            incompatible = json.loads(trial.read_text())
            incompatible['encounters'][0]['source_slots'] = [0]
            trial.write_text(json.dumps(incompatible))
            with self.assertRaisesRegex(ValueError, 'incompatible Journey formation regional_fight'):
                assembly.append_battlefield.append(candidate, source)
            self.assertEqual(json.loads(trial.read_text()), incompatible)
            trial.write_text(json.dumps(original))

            assembly.append_battlefield.append(candidate, source)
            installed = json.loads(trial.read_text())
            self.assertEqual(installed['schema'], 'suikoden-battle-trial/44')
            self.assertEqual(installed['encounters'], [dict(formation, battlefield='coast'), dict(id='fallback')])
            self.assertEqual(installed['ground'], ground)
            field = installed['battlefields'][0]
            self.assertEqual(field['ground_atlas'], dict(x=0, y=32, w=32, h=32))
            sprite = field['scenery'][0]['sprite']
            self.assertEqual((sprite['anchor_x'], sprite['anchor_y']), (1, 2))
            with Image.open(battle / 'ground.png') as packed:
                self.assertEqual(packed.getpixel((0, 0)), (20, 10, 5, 255))
                self.assertEqual(packed.getpixel((0, 32)), (7, 8, 9, 255))
            with Image.open(battle / 'actors.png') as packed:
                self.assertEqual(packed.getpixel((0, 0)), (40, 50, 60, 255))
                self.assertEqual(packed.getpixel((sprite['rect']['x'], sprite['rect']['y'])), (10, 100, 200, 128))

    @patch.object(assembly.export_battle_audio, 'export')
    @patch('battle_actor_atlas.compact_package', return_value=None)
    def test_transaction_and_input_protection(self, packing, music_export):
        with tempfile.TemporaryDirectory(prefix='battle-assembly-') as temporary:
            root = Path(temporary)
            base, battle, output = root / 'base', root / 'battle', root / 'result'
            base.mkdir(); battle.mkdir()
            for name in ('room.json', 'journey.json', 'atlas.png', 'ui.json',
                         'party/catalogue.json', 'party/ownership_bindings.json'):
                path = base / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(name)
            (base / 'battle').mkdir(); (base / 'battle/old').write_text('preserved')
            room_events = assembly.ROOM_BATTLE_PATH
            (base / room_events).write_text('base room events')
            names = ('trial.json', 'actors.png', 'floor.png', 'ground.png', 'provenance.json',
                     'unites.json', 'spells.json', 'spell_effects.png', 'spells.provenance.json')
            (battle / 'battle').mkdir()
            for name in names:
                (battle / 'battle' / name).write_text('{}' if name.endswith('.json') else name)
            (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/19')))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/46')))
            (battle / 'manifest.json').write_text('{}')
            manifest = {'files': {'battle/' + name: 'unused' for name in names}}
            def profiles(candidate, work):
                work.mkdir()
                (work / 'report.json').write_text('{}')
                return 0
            def sounds(actors, folder, reactions=()):
                folder.mkdir(parents=True)
                (folder / 'battle_sfx.json').write_text('{}')
                return {'cues': [], 'unsupported': []}
            def music(folder):
                for name in assembly.bundle_macos.BATTLE_AUDIO_FILES:
                    (folder / Path(name).name).write_text(name)
            music_export.side_effect = music
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export', side_effect=profiles), \
                 patch.object(assembly, 'add_ranged_assets', return_value=({}, [], {}, [])), \
                 patch.object(assembly.export_unite_review, 'export', return_value={}), \
                 patch.object(assembly, 'add_flash_assets', return_value={}), \
                 patch.object(assembly, 'add_master_assets', return_value={}), \
                 patch.object(assembly.export_battle_sfx, 'export', side_effect=sounds), \
                 patch.object(assembly.subprocess, 'run', side_effect=RuntimeError('check failed')):
                with self.assertRaisesRegex(RuntimeError, 'check failed'):
                    assembly.assemble(base, battle, output, root / 'binary')
                self.assertFalse(output.exists())
                self.assertEqual((base / 'battle/old').read_text(), 'preserved')
                self.assertEqual(music_export.call_count, 1)
            with self.assertRaisesRegex(ValueError, 'overlap'):
                assembly.assemble(base, battle, base / 'nested', root / 'binary')
            region = root / 'region'
            with self.assertRaisesRegex(ValueError, 'overlap'):
                assembly.assemble(base, battle, region / 'nested', root / 'binary', (region,))
            (battle / 'battle/unites.json').write_text(json.dumps(dict(
                schema='suikoden-unite-actors/40', counter={'party_melee': []})))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/52')))
            (battle / 'battle/trial.json').write_text(json.dumps({'encounters': [{'enemies': ['new_enemy']}]}))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export') as build_profiles:
                with self.assertRaisesRegex(ValueError, "MissingCounterKnockout for enemy 'new_enemy'"):
                    assembly.assemble(base, battle, output, root / 'binary')
                build_profiles.assert_not_called()
                self.assertFalse(output.exists())
            (battle / 'battle/trial.json').write_text('{}')
            (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/23')))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/47')))
            proof = dict(party_ranged_bindings=[], party_ranged_actors={}, party_ranged_graphics=[], flash={}, master_pupil={})
            (battle / 'battle/provenance.json').write_text(json.dumps(proof))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export', side_effect=profiles), \
                 patch.object(assembly, 'add_ranged_assets') as ranged, \
                 patch.object(assembly.export_unite_review, 'export') as review, \
                 patch.object(assembly.export_battle_sfx, 'export', side_effect=sounds), \
                 patch.object(assembly.subprocess, 'run'):
                self.assertEqual(assembly.assemble(base, battle, output, root / 'binary'), output.resolve())
                ranged.assert_not_called()
                review.assert_not_called()
                self.assertEqual(json.loads((output / 'battle/unites.json').read_text())['schema'], 'suikoden-unite-actors/23')
                packaged = json.loads((output / 'manifest.json').read_text())['files']
                self.assertEqual((output / room_events).read_text(), 'base room events')
                self.assertEqual(packaged[room_events], assembly.hashlib.sha256(b'base room events').hexdigest())
                for name in assembly.bundle_macos.BATTLE_AUDIO_FILES:
                    self.assertEqual((output / name).read_text(), name)
                    self.assertEqual(packaged[name], assembly.hashlib.sha256(name.encode()).hexdigest())
                self.assertFalse((base / 'audio/battle.json').exists())
            shutil.rmtree(output)
            (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/24')))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/48')))
            proof['couple'] = {'status': 'candidate'}
            (battle / 'battle/provenance.json').write_text(json.dumps(proof))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export', side_effect=profiles), \
                 patch.object(assembly, 'add_ranged_assets') as ranged, \
                 patch.object(assembly.export_unite_review, 'export') as review, \
                 patch.object(assembly.export_battle_sfx, 'export', side_effect=sounds), \
                 patch.object(assembly.subprocess, 'run'):
                self.assertEqual(assembly.assemble(base, battle, output, root / 'binary'), output.resolve())
                ranged.assert_not_called(); review.assert_not_called()
                self.assertEqual(json.loads((output / 'battle/provenance.json').read_text())['couple'], proof['couple'])
            shutil.rmtree(output)
            (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/29')))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/51')))
            for name in ('warriors','martial_arts','beat_em_up','trick'):
                proof[name] = {'status': 'candidate', 'family': name}
            (battle / 'battle/provenance.json').write_text(json.dumps(proof))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export', side_effect=profiles), \
                 patch.object(assembly, 'add_ranged_assets') as ranged, \
                 patch.object(assembly.export_unite_review, 'export') as review, \
                 patch.object(assembly.export_battle_sfx, 'export', side_effect=sounds), \
                 patch.object(assembly.subprocess, 'run'):
                self.assertEqual(assembly.assemble(base, battle, output, root / 'binary'), output.resolve())
                ranged.assert_not_called(); review.assert_not_called()
                merged = json.loads((output / 'battle/provenance.json').read_text())
                for name in ('couple','warriors','martial_arts','beat_em_up','trick'):
                    self.assertEqual(merged[name], proof[name])
                wave = dict(id='holly_fairy', owner_program='melee/holly_fairy/wave_owner')
                (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/52')))
                (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/38', enemy_wave=wave)))
                (battle / room_events).write_text('updated room events')
                manifest['files'][room_events] = 'unused'
                assembly.assemble(base, battle, root / 'wave-result', root / 'binary')
                self.assertEqual((root / 'wave-result' / room_events).read_text(), 'updated room events')
                self.assertEqual((base / room_events).read_text(), 'base room events')
                del manifest['files'][room_events]
                first, second = root / 'first.json', root / 'second.json'
                first.write_text(json.dumps(dict(schema='suikoden-battle-field-events/17', rooms=[dict(room='hall')])))
                second.write_text(json.dumps(dict(schema='suikoden-battle-field-events/17', rooms=[dict(room='yard')])))
                base_rooms = dict(schema='suikoden-room/6', start_room='hall', rooms=[dict(id='hall', exits=[]), dict(id='gate')])
                (base / 'room.json').write_text(json.dumps(base_rooms))
                field_rooms = root / 'field-rooms'
                (field_rooms / 'field').mkdir(parents=True)
                scenery = 'field/yard.png'
                Image.new('RGBA', (8, 8), (10, 100, 200, 255)).save(field_rooms / scenery)
                authored = [dict(id='hall', exits=[dict(room='yard')]), dict(id='yard', scenery_atlas=scenery)]
                (field_rooms / 'room.json').write_text(json.dumps(dict(schema='suikoden-room/13', rooms=authored)))
                combined = assembly.assemble(base, battle, root / 'combined', root / 'binary',
                                             room_events=[first, second], field_rooms=field_rooms)
                payload = (combined / room_events).read_bytes()
                self.assertEqual(json.loads(payload)['rooms'], [{'room': 'hall'}, {'room': 'yard'}])
                self.assertEqual(json.loads((combined / 'room.json').read_text()), dict(
                    schema='suikoden-room/13', start_room='hall', rooms=[authored[0], dict(id='gate'), authored[1]]))
                packaged = json.loads((combined / 'manifest.json').read_text())['files']
                self.assertEqual(packaged[room_events], assembly.hashlib.sha256(payload).hexdigest())
                self.assertEqual(packaged[scenery], assembly.bundle_macos.digest(field_rooms / scenery))
                self.assertEqual(json.loads((base / 'room.json').read_text()), base_rooms)
                self.assertEqual((base / room_events).read_text(), 'base room events')
                rejected = root / 'duplicate'
                with self.assertRaisesRegex(ValueError, 'duplicate room'):
                    assembly.assemble(base, battle, rejected, root / 'binary', room_events=[first, first])
                self.assertFalse(rejected.exists())
                packaged_wave = json.loads((root / 'wave-result/battle/unites.json').read_text())
                self.assertEqual(packaged_wave['schema'], 'suikoden-unite-actors/38')
                self.assertEqual(packaged_wave['enemy_wave'], wave)
            shutil.rmtree(output)
            commander = dict(id='beast_commander', selection_delay=60)
            (battle / 'battle/unites.json').write_text(json.dumps(dict(schema='suikoden-unite-actors/32', commander=commander)))
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/52')))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest), \
                 patch.object(assembly.export_opening_profiles, 'export', side_effect=profiles), \
                 patch.object(assembly.export_battle_sfx, 'export', side_effect=sounds), \
                 patch.object(assembly.subprocess, 'run'):
                assembly.assemble(base, battle, output, root / 'binary')
                packaged_actors = json.loads((output / 'battle/unites.json').read_text())
                self.assertEqual(packaged_actors['schema'], 'suikoden-unite-actors/32')
                self.assertEqual(packaged_actors['commander'], commander)
                merged = json.loads((output / 'battle/provenance.json').read_text())
                for name in ('couple','warriors','martial_arts','beat_em_up','trick'):
                    self.assertEqual(merged[name], proof[name])
            shutil.rmtree(output)
            (battle / 'battle/spells.json').write_text(json.dumps(dict(schema='suikoden-spell-scenes/45')))
            with patch.object(assembly.check_journey_package, 'check', return_value=[]), \
                 patch.object(assembly.bundle_macos, 'checked_content', return_value=manifest):
                with self.assertRaisesRegex(ValueError, 'incompatible schema'):
                    assembly.assemble(base, battle, output, root / 'binary')
            output.mkdir()
            with self.assertRaisesRegex(ValueError, 'new candidate'):
                assembly.assemble(base, battle, output, root / 'binary')

    def test_flash_relocates_art_and_preserves_existing_party(self):
        with tempfile.TemporaryDirectory(prefix='battle-flash-') as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            destination = candidate / 'battle'
            source = root / 'review/record_10'
            destination.mkdir(parents=True); source.mkdir(parents=True)
            (root/'review/shared').mkdir()
            members = ('liukan', 'fukien', 'kai')
            sprite = {'rect': {'x': 0, 'y': 0, 'w': 2, 'h': 2}, 'anchor_x': 1, 'anchor_y': 1}
            profiles = [dict(id=name, attack=[], motion=None, sprite=sprite) for name in members]
            graphics = [dict(id=name, poses=[dict(id=0, sprite=sprite)]) for name in members]
            source_trial = dict(party=profiles, unite_graphics=graphics,
                medicine_timings=[dict(id=name) for name in members],
                systems=dict(equipment=[dict(id='cap', allowed_members=['kai'])],
                             runes=[dict(id='water', allowed_members=list(members))]))
            base_trial = dict(party=[dict(id='hero')], unite_graphics=[], medicine_timings=[], initial_party=['hero'],
                systems=dict(equipment=[dict(id='cap', allowed_members=['hero'])],
                             runes=[dict(id='water', allowed_members=['hero'])]))
            base_binding = dict(record=10, members=[dict(id=name, programs=[name]) for name in members], return_program='return')
            source_binding = dict(base_binding, dispatch_after=1, controller=dict(mode='owner_clock'))
            programs = [dict(id=name) for name in (*members, 'return')]
            resources = [dict(id=name, clips=[dict(id=0)]) for name in members]
            actors = dict(schema='suikoden-unite-actors/21', unites=[base_binding],
                          programs=dict(programs=programs), animations=dict(resources=resources))
            source_actors = dict(actors, schema='suikoden-unite-actors/22', unites=[source_binding])
            spells = dict(schema='suikoden-spell-scenes/46', unite_scenes=[])
            source_spells = dict(schema='suikoden-spell-scenes/47', unite_scenes=[dict(id='flash', program=dict(tracks=[[dict(piece=None)]]))])
            for path, value in ((destination/'trial.json', base_trial), (destination/'unites.json', actors),
                                (destination/'spells.json', spells), (destination/'spells.provenance.json', {}),
                                (source/'trial.json', source_trial), (source/'unites.json', source_actors),
                                (source/'spells.json', source_spells),
                                (root/'review/shared/provenance.json', dict(extra_unite_scenes=[dict(id='flash', program_sha256='source')]))):
                path.write_text(json.dumps(value))
            Image.new('RGBA', (4, 2), (1, 2, 3, 255)).save(destination/'actors.png')
            Image.new('RGBA', (2, 2), (4, 5, 6, 255)).save(source/'actors.png')
            with patch.object(assembly, 'flash_attack', return_value=([dict(ticks=1)], dict(duration=1), {})), \
                 patch.object(assembly.preparation, 'bind_weapon_elements', side_effect=lambda value: value.update(schema='suikoden-battle-trial/33')):
                result = assembly.add_flash_assets(candidate, root/'review', dict(members=[], actor_programs=dict(sha256='source')))
            updated = json.loads((destination/'trial.json').read_text())
            self.assertEqual(updated['initial_party'], ['hero'])
            self.assertEqual([row['id'] for row in updated['party']], ['hero', *members])
            self.assertEqual(updated['systems']['equipment'][0]['allowed_members'], ['hero', 'kai'])
            self.assertEqual(updated['systems']['runes'][0]['allowed_members'], ['hero', *members])
            self.assertEqual(result['atlas_rectangles'], 1)
            with Image.open(destination/'actors.png') as image:
                self.assertEqual(image.getpixel((0, 0)), (1, 2, 3, 255))
                rect = updated['party'][1]['sprite']['rect']
                self.assertEqual(image.getpixel((rect['x'], rect['y'])), (4, 5, 6, 255))
            self.assertEqual(json.loads((destination/'unites.json').read_text())['unites'][0], source_binding)
            self.assertEqual(json.loads((destination/'spells.json').read_text())['schema'], 'suikoden-spell-scenes/47')
            with self.assertRaisesRegex(ValueError, 'schemas|already present'):
                assembly.add_flash_assets(candidate, root/'review', dict(members=[], actor_programs=dict(sha256='source')))

    def test_master_merge_keeps_existing_art_and_rejects_conflicts(self):
        with tempfile.TemporaryDirectory(prefix='battle-master-') as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            destination = candidate / 'battle'
            source = root / 'review/record_31'
            destination.mkdir(parents=True); source.mkdir(parents=True)
            (root/'review/actor_programs').mkdir()
            sprite = {'rect': {'x': 0, 'y': 0, 'w': 2, 'h': 2}, 'anchor_x': 1, 'anchor_y': 1}
            white = {'rect': {'x': 2, 'y': 0, 'w': 2, 'h': 2}, 'anchor_x': 1, 'anchor_y': 1}
            members = ('hero', 'kai')
            old = dict(record=31, name='Master pupil attack', members=[dict(id=name, programs=[name+'/setup', name+'/strike']) for name in members], return_program=None)
            new = dict(record=31, name=old['name'], members=[dict(row, entry_program=row['programs'][0], loop_program=row['programs'][1]) for row in old['members']], return_program='common/return', dispatch_after=1)
            programs = [dict(id=name) for row in old['members'] for name in row['programs']] + [dict(id='common/return')]
            resources = [dict(id=name, clips=[dict(id=0)]) for name in members]
            actors = dict(schema='suikoden-unite-actors/22', unites=[old], programs=dict(programs=programs), animations=dict(resources=resources))
            source_actors = dict(actors, schema='suikoden-unite-actors/23', unites=[new])
            trial = dict(party=[dict(id=name) for name in members], unite_graphics=[dict(id=name, poses=[dict(id=0, sprite=sprite)]) for name in members])
            source_trial = dict(unite_graphics=[dict(id=name, poses=[dict(id=0, sprite=sprite, white=white), dict(id=1, sprite=white)]) for name in members])
            spells = dict(unite_reactions=[dict(record=31, variant=0)])
            for path, value in ((destination/'trial.json', trial), (destination/'unites.json', actors), (destination/'spells.json', spells),
                                (source/'trial.json', source_trial), (source/'unites.json', source_actors), (source/'spells.json', spells),
                                (root/'review/actor_programs/provenance.json', dict(master_pupil_controller=dict(footprint=dict(mode='axis_aligned_packet', initial_angles=[0, 0, 0]))))):
                path.write_text(json.dumps(value))
            Image.new('RGBA', (2, 2), (1, 2, 3, 255)).save(destination/'actors.png')
            image = Image.new('RGBA', (4, 2), (1, 2, 3, 255))
            image.paste((255, 255, 255, 255), (2, 0, 4, 2))
            image.save(source/'actors.png')
            bad = root/'bad'
            shutil.copytree(candidate, bad)
            image.putpixel((0, 0), (9, 9, 9, 255))
            image.save(source/'actors.png')
            proof = dict(members=[], actor_programs=dict(sha256='source'))
            with self.assertRaisesRegex(ValueError, 'pose 0 sprite differs'):
                assembly.add_master_assets(bad, root/'review', proof)
            self.assertEqual(json.loads((bad/'battle/unites.json').read_text()), actors)
            image.putpixel((0, 0), (1, 2, 3, 255))
            image.save(source/'actors.png')
            result = assembly.add_master_assets(candidate, root/'review', proof)
            updated = json.loads((destination/'trial.json').read_text())
            self.assertEqual(updated['unite_graphics'][0]['poses'][0]['sprite'], sprite)
            self.assertEqual(len(updated['unite_graphics'][0]['poses']), 2)
            self.assertEqual(json.loads((destination/'unites.json').read_text())['unites'][0], new)
            self.assertEqual(json.loads((destination/'unites.json').read_text())['schema'], 'suikoden-unite-actors/23')
            self.assertEqual(result['atlas_rectangles'], 1)
            with Image.open(destination/'actors.png') as image:
                rect = updated['unite_graphics'][0]['poses'][0]['white']['rect']
                self.assertEqual(image.getpixel((rect['x'], rect['y'])), (255, 255, 255, 255))


if __name__ == '__main__':
    unittest.main()
