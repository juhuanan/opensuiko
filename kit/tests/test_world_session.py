"""One normal-input source Roc victory followed by menu Save and fresh-process Load."""
from pathlib import Path
import argparse
import copy
import json
import subprocess
import struct
import sys
import tempfile
import shutil
from collections import deque

from test_world_replay import supplied_packet, primary_save, service_walk

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))


def verify_village_exit(executable, field, art, temporary_root=None):
    def run(*args):
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='suikoden-village-exit-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        packet['checkpoint']['story']['scenario'] = dict(schema='suikoden-event-story/1', scenario='\0' * 240)
        packet['checkpoint']['story']['forest_elf_seen'] = True
        packet['steps'] = [{'buttons': {'direction': 'up'}}, {}]
        recipe = root / 'world.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        run('--check-world-session', field, art, recipe, slots, 'village_exit_write')
        before = json.loads((slots / 'village-exit.json').read_text())
        after = json.loads((slots / 'village-exit-post.json').read_text())
        assert before['snapshot']['scene_event']['instance']['execution']['pc'] == 0
        assert after['snapshot']['scene_event']['instance']['execution']['pc'] == 1
        assert ord(after['snapshot']['ownership']['story']['scenario']['scenario'][39]) == 0x10
        packet['steps'] = []; recipe.write_text(json.dumps(packet))
        run('--check-world-session', field, art, recipe, slots, 'village_exit_read')
        run('--check-world-session', field, art, recipe, slots, 'village_exit_post_read')
        return dict(ordinary_exit=True, fresh_process_restart_before_and_after_prefix=True,
                    isolated_saves=True, native_window_launched=False)


def verify_village_session(executable, field, art, temporary_root=None):
    def run(*args):
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
    room = next(r for r in json.loads((field / 'room.json').read_text())['rooms'] if r['id'] == 'vb6_village')
    width = room['width'] // 8
    start, goal = (33, 43), (35, 30)
    queue, parent = deque([start]), {start: None}
    directions = ((0, -1, 'up'), (1, 0, 'right'), (0, 1, 'down'), (-1, 0, 'left'))
    while queue and goal not in parent:
        x, y = queue.popleft()
        for dx, dy, direction in directions:
            nx, ny = x + dx, y + dy
            if not (0 <= nx < width and 0 <= ny < room['height'] // 8):
                continue
            if any(event['id'] != 'elf_sighting' and event['x'] <= nx * 8 < event['x'] + event['w'] and event['y'] <= ny * 8 < event['y'] + event['h'] for event in room.get('events', [])):
                continue
            if room['walkable'][ny * width + nx] != '1' or (nx, ny) in parent:
                continue
            parent[nx, ny] = ((x, y), direction)
            queue.append((nx, ny))
    assert goal in parent
    path = []
    node = goal
    while node != start:
        node, direction = parent[node]
        path.append(direction)
    steps = [{'buttons': {'direction': 'up'}}, {}]
    for direction in reversed(path):
        steps.extend([{'buttons': {'direction': direction}}, {}, {}, {}])
    steps.append({'buttons': {'direction': 'up', 'confirm': True}})
    with tempfile.TemporaryDirectory(prefix='suikoden-village-session-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        packet['checkpoint']['story']['scenario'] = dict(schema='suikoden-event-story/1', scenario='\0' * 240)
        packet['checkpoint']['story']['forest_elf_seen'] = True
        packet['steps'] = steps
        recipe = root / 'world.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        run('--check-world-session', field, art, recipe, slots, 'village_write')
        saved = json.loads((slots / 'world-slot1.json').read_text())
        assert saved['schema'] == 'suikoden-world-session/8'
        assert saved['travel_receipt'] == 1
        assert saved['village_actors']['initializer_batch'] is None
        assert saved['party_ledger']['last_receipt'] == 1
        run('--check-world-session', field, art, recipe, slots, 'village_read')
        assert json.loads((slots / 'world-slot1.json').read_text()) == saved
        return dict(ordinary_entry_walk_and_talk=True, fresh_process_load=True,
                    isolated_saves=True, native_window_launched=False)


def verify_party_menu(executable, field, art, temporary_root=None):
    def run(*args):
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='suikoden-party-menu-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        packet['steps'] = []
        recipe = root / 'world.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        run('--check-world-session', field, art, recipe, slots, 'party_write')
        saved = json.loads((slots / 'world-slot1.json').read_text())
        assert saved['schema'] == 'suikoden-world-session/5'
        assert saved['party_ledger']['last_receipt'] == 1
        run('--check-world-session', field, art, recipe, slots, 'party_read')
        assert json.loads((slots / 'world-slot1.json').read_text()) == saved
        return dict(ordinary_menu_transfer=True, field_return=True, fresh_process_load=True,
                    receipt=1, isolated_saves=True, native_window_launched=False)


def verify(executable, field, art, temporary_root=None, battle_art=None, candidate_entry=None, previous_executable=None, previous_c7_executable=None, previous_c8_executable=None, previous_c9_executable=None):
    import maindec
    assert struct.unpack_from('<3I', maindec.body(), 0x80147e38 - maindec.MBASE) == (0x240a00a0, 0x01400008, 0x2409002f)

    def run(*args, success=True, binary=executable):
        result = subprocess.run([str(binary), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stdout + result.stderr)
        return result

    with tempfile.TemporaryDirectory(prefix='suikoden-live-world-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        checkpoint = packet['checkpoint']
        # Existing bounded source Roc witness's preconditions, never a new-game seed.
        checkpoint['levels'] = ''.join(chr(14) for _ in range(6))
        checkpoint['experience'] = [0] * 6
        checkpoint['formation'] = ''.join(chr(i) for i in range(6))
        for member, stats in zip(checkpoint['party'], checkpoint['stats']):
            member.update(hp=100, max_hp=100, status='healthy')
            stats.update(speed=0, defense=40)
        checkpoint['stats'][0].update(attack=180, skill=9999, luck=0, speed=24)
        profiles = {p['id']: p for p in json.loads((field / 'battle/trial.json').read_text())['party']}
        commands = [{'buttons': {'confirm': True}}, {'buttons': {'confirm': True}}]
        for index, member in enumerate(checkpoint['party'][1:], 1):
            if not (index >= 3 and profiles[member['id']]['weapon_range'] == 'short'):
                commands.append({'buttons': {'navigation': 'down'}})
            commands.append({'buttons': {'confirm': True}})
        prefix = packet['steps'][:90] + [{}, {'buttons': {'confirm': True}}] + commands + [{'buttons': {'confirm': True}}, {}]
        packet['steps'] = prefix + [{}] * 383 + [{'buttons': {'confirm': True}}, {}]
        packet['draws'] = [0, 3 * (32767 // 8)] + [51] * 29 + [0, 0]
        write_recipe = root / 'adventure.json'; write_recipe.write_text(json.dumps(packet))
        sandbox = root / 'world-slots'; sandbox.mkdir()
        extra = [] if battle_art is None else [battle_art]
        run('--check-world-session', field, art, write_recipe, sandbox, 'write', *extra)
        saved = json.loads((sandbox / 'world-slot1.json').read_text())
        assert saved['schema'] == 'suikoden-world-session/2'
        assert saved['position']['state']['mode'] == 'world'
        assert saved['position']['random_cursor'] == 33
        assert saved['ownership']['money'] == checkpoint['money'] + 70
        assert saved['ownership']['experience'] == [33] * 6
        assert saved['ownership']['party'][0]['hp'] == 16
        assert any(slot and slot['id'] == 'feather' for slot in saved['ownership']['party'][0]['inventory']['slots'])
        assert saved['ownership']['reserves'] == checkpoint['reserves']
        # A fresh process receives NO earlier input sequence, only the content/RNG contract.
        resume = copy.deepcopy(packet); resume['steps'] = []
        read_recipe = root / 'restart.json'; read_recipe.write_text(json.dumps(resume))
        run('--check-world-session', field, art, read_recipe, sandbox, 'read', *extra)
        assert json.loads((sandbox / 'world-slot1.json').read_text()) == saved
        legacy = copy.deepcopy(saved)
        legacy['schema'] = 'suikoden-world-session/1'
        legacy['position']['schema'] = 'suikoden-world-checkpoint/2'
        del legacy['position']['bios_state']
        del legacy['position']['region']
        (sandbox / 'world-slot1.json').write_text(json.dumps(legacy))
        run('--check-world-session', field, art, read_recipe, sandbox, 'read', *extra)

        seeded = copy.deepcopy(packet)
        seeded.update(schema='suikoden-world-replay/2', bios_seed=1, draws=[],
                      steps=[{'buttons': {'direction': 'down'}}] * 93)
        seed_recipe = root / 'seeded.json'; seed_recipe.write_text(json.dumps(seeded))
        seed_slots = root / 'seeded-slots'; seed_slots.mkdir()
        run('--check-world-session', field, art, seed_recipe, seed_slots, 'write', *extra)
        seed_saved = json.loads((seed_slots / 'world-slot1.json').read_text())
        assert seed_saved['position']['random_cursor'] > 0
        # Independent Python recurrence, not the port's future-draw implementation.
        state = 1
        for _ in range(seed_saved['position']['random_cursor']):
            state = (state * 1103515245 + 12345) & 0xffffffff
        assert seed_saved['position']['bios_state'] == state
        future = []
        for _ in range(16):
            state = (state * 1103515245 + 12345) & 0xffffffff
            future.append((state >> 16) & 32767)
        expected = json.loads((seed_slots / 'expected-live-world.json').read_text())
        assert expected['next_draws'] == future
        seeded['steps'] = []
        seed_recipe.write_text(json.dumps(seeded))
        run('--check-world-session', field, art, seed_recipe, seed_slots, 'read', *extra)
        if previous_executable is not None:
            old_slots = root / 'previous-port-slots'; old_slots.mkdir()
            previous_recipe = copy.deepcopy(seeded)
            previous_recipe['steps'] = [{'buttons': {'direction': 'down'}}] * 93
            previous_path = root / 'previous-port.json'; previous_path.write_text(json.dumps(previous_recipe))
            run('--check-world-session', field, art, previous_path, old_slots, 'write', *extra,
                binary=previous_executable)
            previous_recipe['steps'] = []
            previous_path.write_text(json.dumps(previous_recipe))
            run('--check-world-session', field, art, previous_path, old_slots, 'read', *extra)
        connected = (art / 'region-c/scene.json').exists()
        if connected:
            region_packet = copy.deepcopy(seeded)
            region_packet['region_c'] = True
            package = json.loads((field / 'room.json').read_text())
            region_packet['steps'] = service_walk(package, checkpoint['story'], forest=True)
            c_recipe = root / 'connected-c.json'; c_recipe.write_text(json.dumps(region_packet))
            c_slots = root / 'connected-c-slots'; c_slots.mkdir()
            run('--check-world-session', field, art, c_recipe, c_slots, 'write', *extra)
            c_slot = c_slots / 'world-slot1.json'
            c_bytes = c_slot.read_bytes(); c_saved = json.loads(c_bytes)
            assert c_saved['position']['region'] == 'region_c'
            assert c_saved['position']['state']['camera'] == dict(x=59, y=38)
            assert c_saved['ownership']['story']['kobold_world_exit_reached']
            assert c_saved['ownership']['reserves'] == checkpoint['reserves']
            region_packet['steps'] = []
            c_recipe.write_text(json.dumps(region_packet))
            run('--check-world-session', field, art, c_recipe, c_slots, 'read', *extra)
            assert c_slot.read_bytes() == c_bytes
            if previous_executable is not None and battle_art is not None:
                # The earlier C6 port reads its own asset schema; pixels/anchors must be unchanged.
                legacy_art = root / 'legacy-c6-art'; legacy_art.mkdir()
                for name in ('scene.json', 'actors.png', 'floor.png'):
                    shutil.copyfile(battle_art / name, legacy_art / name)
                if (battle_art / 'region-c/scene.json').exists():
                    legacy_c = legacy_art / 'region-c'; legacy_c.mkdir()
                    old_scene = json.loads((battle_art / 'region-c/scene.json').read_text())
                    old_scene['schema'] = 'suikoden-world-battle-art/6'
                    old_scene['c_tracks'].pop('low_hp', None)
                    old_scene['c_tracks'].pop('extra_party_attacks', None)
                    old_scene['c_tracks'].pop('repeated_hurt', None)
                    old_scene['c_tracks'].pop('misses', None)
                    (legacy_c / 'scene.json').write_text(json.dumps(old_scene))
                    for name in ('actors.png', 'floor.png'):
                        shutil.copyfile(battle_art / 'region-c' / name, legacy_c / name)
                old_c = copy.deepcopy(seeded); old_c['region_c'] = True
                old_c['steps'] = service_walk(package, checkpoint['story'], forest=True)
                old_path = root / 'previous-c-port.json'; old_path.write_text(json.dumps(old_c))
                old_slots = root / 'previous-c-slots'; old_slots.mkdir()
                run('--check-world-session', field, art, old_path, old_slots, 'write', legacy_art, binary=previous_executable)
                original_c_bytes = (old_slots / 'world-slot1.json').read_bytes()
                old_c['steps'] = []; old_path.write_text(json.dumps(old_c))
                run('--check-world-session', field, art, old_path, old_slots, 'read', *extra)
                assert (old_slots / 'world-slot1.json').read_bytes() == original_c_bytes
                old_c['steps'] = service_walk(package, checkpoint['story'], forest=True)
                old_path.write_text(json.dumps(old_c))
                earlier_media_slots = root / 'earlier-c-media-slots'; earlier_media_slots.mkdir()
                run('--check-world-session', field, art, old_path, earlier_media_slots, 'write', legacy_art)
                earlier_media_bytes = (earlier_media_slots / 'world-slot1.json').read_bytes()
                old_c['steps'] = []; old_path.write_text(json.dumps(old_c))
                run('--check-world-session', field, art, old_path, earlier_media_slots, 'read', *extra)
                assert (earlier_media_slots / 'world-slot1.json').read_bytes() == earlier_media_bytes
            for version, previous_c in ((7, previous_c7_executable), (8, previous_c8_executable), (9, previous_c9_executable)):
                if previous_c is None or battle_art is None:
                    continue
                legacy_art = root / f'legacy-c{version}-art'; legacy_art.mkdir()
                for name in ('scene.json', 'actors.png', 'floor.png'):
                    shutil.copyfile(battle_art / name, legacy_art / name)
                legacy_c = legacy_art / 'region-c'; legacy_c.mkdir()
                old_scene = json.loads((battle_art / 'region-c/scene.json').read_text())
                old_scene['schema'] = f'suikoden-world-battle-art/{version}'
                if version == 9:
                    old_scene['c_tracks']['extra_party_attacks'] = [entry for entry in old_scene['c_tracks']['extra_party_attacks'] if entry['id'] == 'gremio']
                    for entry in old_scene['c_tracks']['extra_party_attacks']:
                        entry.pop('target_hurt', None)
                else:
                    old_scene['c_tracks'].pop('extra_party_attacks', None)
                    old_scene['c_tracks'].pop('repeated_hurt', None)
                if version == 7:
                    old_scene['c_tracks'].pop('low_hp', None)
                (legacy_c / 'scene.json').write_text(json.dumps(old_scene))
                for name in ('actors.png', 'floor.png'):
                    shutil.copyfile(battle_art / 'region-c' / name, legacy_c / name)
                old = copy.deepcopy(seeded); old['region_c'] = True
                old['steps'] = service_walk(package, checkpoint['story'], forest=True)
                old_path = root / f'previous-c{version}.json'; old_path.write_text(json.dumps(old))
                old_slots = root / f'previous-c{version}-slots'; old_slots.mkdir()
                run('--check-world-session', field, art, old_path, old_slots, 'write', legacy_art, binary=previous_c)
                old_bytes = (old_slots / 'world-slot1.json').read_bytes()
                old['steps'] = []; old_path.write_text(json.dumps(old))
                run('--check-world-session', field, art, old_path, old_slots, 'read', *extra)
                assert (old_slots / 'world-slot1.json').read_bytes() == old_bytes
            region_packet['region_c'] = False
            c_recipe.write_text(json.dumps(region_packet))
            run('--check-world-session', field, art, c_recipe, c_slots, 'read', *extra, success=False)
            assert c_slot.read_bytes() == c_bytes
        c_fight = connected and battle_art is not None and (battle_art / 'region-c/scene.json').exists()
        if c_fight:
            case = copy.deepcopy(packet)
            case.update(schema='suikoden-world-replay/2', region_c=True, draws=[0, 0] + [51] * 254)
            c_misses = json.loads((battle_art / 'region-c/scene.json').read_text())['schema'] in ('suikoden-world-battle-art/7', 'suikoden-world-battle-art/8', 'suikoden-world-battle-art/9', 'suikoden-world-battle-art/10')
            c_low_hp = json.loads((battle_art / 'region-c/scene.json').read_text())['schema'] in ('suikoden-world-battle-art/8', 'suikoden-world-battle-art/9', 'suikoden-world-battle-art/10')
            if c_misses:
                source_misses = json.loads((ROOT / 'game/tests/fixtures/world_c_archer_misses.json').read_text())
                case['draws'] = [0, 0] + [51] * 8 + [row[1] for row in source_misses['draws']] + [51] * 100
            supplied = case['checkpoint']
            rules = json.loads((field / 'battle/trial.json').read_text())['systems']
            boar = next(index for index, rune in enumerate(rules['runes']) if rune['id'] == 'boar')
            capacity = [sum(50 > threshold for threshold in row) for row in rules['magic_thresholds']]
            supplied['runes'] = [None, None, boar, None, None, None]
            supplied['loadouts'] = [{} for _ in range(6)]
            for index, (member, stats) in enumerate(zip(supplied['party'], supplied['stats'])):
                hp = 300 if index == 0 and not c_misses else 100
                member.update(hp=hp, max_hp=hp, status='healthy', balloons=0, rune_charges=[0] * 4, max_rune_charges=capacity)
                stats.update(attack=180 if index == 0 else 10, skill=255 if index == 0 else 20,
                             defense=40, speed=24 if index == 0 else 0, magic=50, luck=0)
            forest = service_walk(package, supplied['story'], forest=True)
            first = forest + [{'buttons': {'direction': 'right'}}] * 80 + [{}, {'buttons': {'confirm': True}}] + commands + [{'buttons': {'confirm': True}}, {}]
            case['steps'] = first + [{}] * 320
            c_fight_recipe = root / 'connected-c-fight.json'; c_fight_recipe.write_text(json.dumps(case))
            probe = run('--check-world-replay', field, art, c_fight_recipe, *extra)
            rows = [json.loads(line) for line in probe.stdout.splitlines() if line.startswith('{')]
            assert rows[-1]['battle_phase'] == 'battle_menu' and rows[-1]['battle_round'] == 2, rows[-1]
            assert rows[-1]['battle_enemy_hp'] == [0, 120] and rows[-1]['party'][0]['hp'] == (100 if c_misses else 200)
            if c_misses:
                assert [member['hp'] for member in rows[-1]['party']] == [100] * 6
            second = [{}, {'buttons': {'confirm': True}}] + commands + [{'buttons': {'confirm': True}}, {}]
            case['steps'] += second + [{}] * 382 + [{'buttons': {'confirm': True}}]
            c_fight_recipe.write_text(json.dumps(case))
            c_fight_slots = root / 'c-fight-slots'; c_fight_slots.mkdir()
            run('--check-world-session', field, art, c_fight_recipe, c_fight_slots, 'write', *extra)
            saved_fight = json.loads((c_fight_slots / 'world-slot1.json').read_text())
            assert saved_fight['position']['region'] == 'region_c'
            assert saved_fight['position']['state']['camera'] == dict(x=64, y=38)
            assert saved_fight['ownership']['money'] == supplied['money'] + 300
            assert saved_fight['ownership']['levels'] == ''.join(chr(15) for _ in range(6))
            assert saved_fight['ownership']['experience'] == [700] * 6
            assert saved_fight['ownership']['reserves'] == supplied['reserves']
            knockout = copy.deepcopy(case)
            knockout['draws'] = [0, 0] + [51] * 254
            for index, member in enumerate(knockout['checkpoint']['party']):
                member.update(hp=300 if index == 0 else (24 if c_low_hp else 50) if index == 1 else 100,
                              max_hp=300 if index == 0 else 100)
            source_knockout = json.loads((ROOT / 'game/tests/fixtures/world_c_archer_gremio_knockout.json').read_text())
            promoted = source_knockout['launch']['formation']
            surviving_commands = [{'buttons': {'confirm': True}}, {'buttons': {'confirm': True}}]
            for index, member in enumerate(knockout['checkpoint']['party'][2:], 2):
                if not (promoted.index(index) >= 3 and profiles[member['id']]['weapon_range'] == 'short'):
                    surviving_commands.append({'buttons': {'navigation': 'down'}})
                surviving_commands.append({'buttons': {'confirm': True}})
            knockout['steps'] = first + [{}] * 320
            knockout_recipe = root / 'c-knockout-fight.json'; knockout_recipe.write_text(json.dumps(knockout))
            probe = run('--check-world-replay', field, art, knockout_recipe, *extra)
            down = [json.loads(line) for line in probe.stdout.splitlines() if line.startswith('{')][-1]
            assert down['battle_phase'] == 'battle_menu' and down['party'][1]['hp'] == 0
            assert down['party'][1]['status'] == 'unconscious'
            knockout['steps'] += [{}, {'buttons': {'confirm': True}}] + surviving_commands + [{'buttons': {'confirm': True}}, {}] + [{}] * 382 + [{'buttons': {'confirm': True}}]
            knockout_recipe.write_text(json.dumps(knockout))
            knockout_slots = root / 'c-knockout-slots'; knockout_slots.mkdir()
            run('--check-world-session', field, art, knockout_recipe, knockout_slots, 'write', *extra)
            knockout_slot = knockout_slots / 'world-slot1.json'
            knockout_bytes = knockout_slot.read_bytes()
            owned = json.loads(knockout_bytes)['ownership']
            assert owned['party'][1]['hp'] == 0 and owned['party'][1]['status'] == 'unconscious'
            assert owned['money'] == supplied['money'] + 300
            assert owned['levels'] == ''.join(chr(14 if i == 1 else 15) for i in range(6))
            assert owned['experience'] == [700, 0, 700, 700, 700, 700]
            assert owned['formation'] == ''.join(chr(i) for i in promoted)
            assert owned['reserves'] == supplied['reserves']
            knockout['steps'] = []; knockout_recipe.write_text(json.dumps(knockout))
            run('--check-world-session', field, art, knockout_recipe, knockout_slots, 'read', *extra)
            assert knockout_slot.read_bytes() == knockout_bytes
            c_gremio = json.loads((battle_art / 'region-c/scene.json').read_text())['schema'] in ('suikoden-world-battle-art/9', 'suikoden-world-battle-art/10')
            if c_gremio:
                gremio = copy.deepcopy(case)
                source_gremio = json.loads((ROOT / 'game/tests/fixtures/world_c_archer_gremio_attack.json').read_text())
                gremio['draws'] = [0, 0] + [51] * 8 + [row[1] for row in source_gremio['draws']] + [51] * 100
                for index, (member, stats) in enumerate(zip(gremio['checkpoint']['party'], gremio['checkpoint']['stats'])):
                    hp = 200 if index == 0 else 300 if index == 1 else 100
                    member.update(hp=hp, max_hp=hp, status='healthy')
                    stats.update(attack=180 if index == 1 else 10, skill=255 if index == 1 else 20,
                                 speed=24 if index == 1 else 0, defense=40, magic=50, luck=0)
                gremio_commands = []
                for index, member in enumerate(gremio['checkpoint']['party']):
                    if index == 1:
                        gremio_commands += [{'buttons': {'confirm': True}}, {'buttons': {'confirm': True}}]
                    else:
                        if not (index >= 3 and profiles[member['id']]['weapon_range'] == 'short'):
                            gremio_commands.append({'buttons': {'navigation': 'down'}})
                        gremio_commands.append({'buttons': {'confirm': True}})
                gremio['steps'] = forest + [{'buttons': {'direction': 'right'}}] * 80 + [{}, {'buttons': {'confirm': True}}] + gremio_commands + [{'buttons': {'confirm': True}}, {}] + [{}] * (len(source_gremio['rows']) + 1)
                gremio_recipe = root / 'c-gremio-fight.json'; gremio_recipe.write_text(json.dumps(gremio))
                probe = run('--check-world-replay', field, art, gremio_recipe, *extra)
                middle = [json.loads(line) for line in probe.stdout.splitlines() if line.startswith('{')][-1]
                assert middle['battle_phase'] == 'battle_menu' and middle['battle_round'] == 2
                assert middle['battle_enemy_hp'] == [0, 120]
                assert [member['hp'] for member in middle['party']] == [150, 200, 100, 100, 100, 100]
                gremio['steps'] += [{}, {'buttons': {'confirm': True}}] + gremio_commands + [{'buttons': {'confirm': True}}, {}] + [{}] * (len(source_gremio['second']) + 32) + [{'buttons': {'confirm': True}}]
                gremio_recipe.write_text(json.dumps(gremio))
                gremio_slots = root / 'c-gremio-slots'; gremio_slots.mkdir()
                run('--check-world-session', field, art, gremio_recipe, gremio_slots, 'write', *extra)
                gremio_slot = gremio_slots / 'world-slot1.json'; gremio_bytes = gremio_slot.read_bytes()
                owned = json.loads(gremio_bytes)['ownership']
                assert owned['money'] == supplied['money'] + 300
                assert owned['levels'] == ''.join(chr(15) for _ in range(6)) and owned['experience'] == [700] * 6
                assert all(member['status'] == 'healthy' for member in owned['party'])
                assert owned['reserves'] == supplied['reserves']
                gremio['steps'] = []; gremio_recipe.write_text(json.dumps(gremio))
                run('--check-world-session', field, art, gremio_recipe, gremio_slots, 'read', *extra)
                assert gremio_slot.read_bytes() == gremio_bytes
            c_party = json.loads((battle_art / 'region-c/scene.json').read_text())['schema'] == 'suikoden-world-battle-art/10'
            if c_party:
                party = copy.deepcopy(case)
                source_party = json.loads((ROOT / 'game/tests/fixtures/world_c_party_all_commands.json').read_text())
                party['draws'] = [0, 0] + [51] * 8 + [row[1] for row in source_party['draws']] + [51] * 100
                for index, (member, stats) in enumerate(zip(party['checkpoint']['party'], party['checkpoint']['stats'])):
                    hp = source_party['initial_hp'][index]
                    member.update(hp=hp, max_hp=source_party['initial_max_hp'][index], status='healthy')
                    stats.update(source_party['initial_stats'][index])
                    stats['magic'] = 50  # Existing prototype rune-capacity precondition; no spells are selected.
                attacks = {row['actor']: row['target'] for row in source_party['commands']}
                party_commands = []
                for index, member in enumerate(party['checkpoint']['party']):
                    if index in attacks:
                        party_commands.append({'buttons': {'confirm': True}})
                        party_commands += [{'buttons': {'navigation': 'down'}}] * attacks[index]
                        party_commands.append({'buttons': {'confirm': True}})
                    else:
                        if not (index >= 3 and profiles[member['id']]['weapon_range'] == 'short'):
                            party_commands.append({'buttons': {'navigation': 'down'}})
                        party_commands.append({'buttons': {'confirm': True}})
                party['steps'] = forest + [{'buttons': {'direction': 'right'}}] * 80 + [{}, {'buttons': {'confirm': True}}] + party_commands + [{'buttons': {'confirm': True}}, {}] + [{}] * (len(source_party['rows']) + 32) + [{'buttons': {'confirm': True}}]
                party_recipe = root / 'c-party-fight.json'; party_recipe.write_text(json.dumps(party))
                party_slots = root / 'c-party-slots'; party_slots.mkdir()
                run('--check-world-session', field, art, party_recipe, party_slots, 'write', *extra)
                party_slot = party_slots / 'world-slot1.json'; party_bytes = party_slot.read_bytes()
                owned = json.loads(party_bytes)['ownership']
                assert owned['money'] == supplied['money'] + 300
                assert owned['levels'] == ''.join(chr(15) for _ in range(6)) and owned['experience'] == [700] * 6
                assert owned['reserves'] == supplied['reserves']
                assert json.loads(party_bytes)['position']['region'] == 'region_c'
                party['steps'] = []; party_recipe.write_text(json.dumps(party))
                run('--check-world-session', field, art, party_recipe, party_slots, 'read', *extra)
                assert party_slot.read_bytes() == party_bytes
            case['steps'] = []; c_fight_recipe.write_text(json.dumps(case))
            run('--check-world-session', field, art, c_fight_recipe, c_fight_slots, 'read', *extra)
            assert json.loads((c_fight_slots / 'world-slot1.json').read_text()) == saved_fight
        entry = {key: packet[key] for key in ('checkpoint', 'prototype_retry_seed', 'update_hz', 'draws')}
        entry.update(schema='suikoden-world-session-entry/1', origin='prototype_checkpoint', random_source='supplied_tape')
        entry_path = root / 'entry.json'; entry_path.write_text(json.dumps(entry, indent=2) + '\n')
        run('--check-world-session-entry', field, art, entry_path, *extra)
        scripted = copy.deepcopy(entry); scripted['steps'] = []
        invalid_entry = root / 'not-a-live-entry.json'; invalid_entry.write_text(json.dumps(scripted))
        rejected = run('--check-world-session-entry', field, art, invalid_entry, *extra, success=False)
        assert 'UnknownField' in rejected.stderr
        seeded_entry = copy.deepcopy(entry)
        seeded_entry.update(schema='suikoden-world-session-entry/2', random_source='bios_seed',
                            bios_seed=1, draws=[], region_c=connected)
        entry_path.write_text(json.dumps(seeded_entry, indent=2) + '\n')
        run('--check-world-session-entry', field, art, entry_path, *extra)
        invalid = copy.deepcopy(seeded_entry); del invalid['bios_seed']
        invalid_entry.write_text(json.dumps(invalid))
        rejected = run('--check-world-session-entry', field, art, invalid_entry, *extra, success=False)
        assert 'InvalidRandomSource' in rejected.stderr
        if candidate_entry is not None:
            candidate_entry = candidate_entry.resolve()
            accepted = (ROOT / 'kit/work/accepted').resolve()
            if accepted in (candidate_entry, *candidate_entry.parents):
                raise ValueError('entry output is a generated candidate, never accepted content')
            candidate_entry.parent.mkdir(parents=True, exist_ok=True)
            candidate_entry.write_text(entry_path.read_text())
            if c_fight:
                c_entry = {key: case[key] for key in ('checkpoint', 'prototype_retry_seed', 'update_hz', 'draws')}
                c_entry.update(schema='suikoden-world-session-entry/2', origin='prototype_checkpoint', random_source='supplied_tape', region_c=True)
                c_entry_path = candidate_entry.with_name(candidate_entry.stem + '-c-archers.json')
                c_entry_path.write_text(json.dumps(c_entry, indent=2) + '\n')
                run('--check-world-session-entry', field, art, c_entry_path, *extra)
                if c_gremio:
                    gremio_entry = {key: gremio[key] for key in ('checkpoint', 'prototype_retry_seed', 'update_hz', 'draws')}
                    gremio_entry.update(schema='suikoden-world-session-entry/2', origin='prototype_checkpoint', random_source='supplied_tape', region_c=True)
                    gremio_entry_path = candidate_entry.with_name(candidate_entry.stem + '-c-gremio.json')
                    gremio_entry_path.write_text(json.dumps(gremio_entry, indent=2) + '\n')
                    run('--check-world-session-entry', field, art, gremio_entry_path, *extra)
                if c_party:
                    party_entry = {key: party[key] for key in ('checkpoint', 'prototype_retry_seed', 'update_hz', 'draws')}
                    party_entry.update(schema='suikoden-world-session-entry/2', origin='prototype_checkpoint', random_source='supplied_tape', region_c=True)
                    party_entry_path = candidate_entry.with_name(candidate_entry.stem + '-c-party.json')
                    party_entry_path.write_text(json.dumps(party_entry, indent=2) + '\n')
                    run('--check-world-session-entry', field, art, party_entry_path, *extra)
        return dict(steps=len(packet['steps']), draw_cursor=33, experience=[33] * 6,
                    money_award=70, direct_restart_without_input_prefix=True,
                    seeded_restart=True, seeded_cursor=seed_saved['position']['random_cursor'],
                    legacy_tape_migration=True, future_draws_checked=16,
                    connected_c_restart=connected, c_fight_rewards_restart=c_fight,
                    c_miss_fight=c_fight and c_misses, c_knockout_rewards_restart=c_fight,
                    c_low_hp_rewards_restart=c_fight and c_low_hp,
                    c_gremio_attack_rewards_restart=c_fight and c_gremio,
                    c_party_commands_rewards_restart=c_fight and c_party,
                    previous_c9_binary_migration=connected and previous_c9_executable is not None and battle_art is not None,
                    previous_c8_binary_migration=connected and previous_c8_executable is not None and battle_art is not None,
                    previous_c7_binary_migration=connected and previous_c7_executable is not None and battle_art is not None,
                    previous_c_binary_migration=connected and previous_executable is not None and battle_art is not None,
                    previous_binary_migration=previous_executable is not None)


def verify_field_effects(executable, field, art, temporary_root=None, battle_art=None, recruitment=True):
    """Existing episode interactions exercise shared ownership and actual slot restart."""
    def run(*args):
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        return result
    with tempfile.TemporaryDirectory(prefix='suikoden-world-roster-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        checkpoint = packet['checkpoint']
        checkpoint['reserves'] = [None] * len(checkpoint['reserves'])
        checkpoint['story'].update(recruitment_tier=1, maas_recruited=False,
                                   maas_recruitment_blocked=False,
                                   castle_name='Toran' + chr(0) * 3)
        packet.update(schema='suikoden-world-replay/2', bios_seed=1, draws=[])
        package = json.loads((field / 'room.json').read_text())
        if not recruitment:
            checkpoint['story'].update(heard_forest_warning=False,
                                      forest_treasure_needle=False, forest_treasure_water=False)
        packet['steps'] = service_walk(package, checkpoint['story'], recruitment=recruitment,
                                       interactions=not recruitment)
        if not recruitment:
            # The existing process harness also requires continuing world/RNG activity.
            packet['steps'] += [{'buttons': {'direction': 'down'}}] * 93
        steps = len(packet['steps'])
        recipe = root / 'join.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        extra = [] if battle_art is None else [battle_art]
        run('--check-world-session', field, art, recipe, slots, 'write', *extra)
        path = slots / 'world-slot1.json'
        original = path.read_bytes(); saved = json.loads(original)
        assert saved['position']['state']['mode'] == 'world'
        if recruitment:
            assert saved['ownership']['story']['maas_recruited']
            reserve = saved['ownership']['reserves']
            assert reserve[0]['member']['id'] == 'maas' and reserve[0]['level'] == 18
            assert all(member is None for member in reserve[1:])
            assert saved['position']['random_cursor'] >= 119
            assert saved['ownership']['party'] == checkpoint['party']
        else:
            assert all(saved['ownership']['story'][flag] for flag in
                       ('heard_forest_warning', 'forest_treasure_needle', 'forest_treasure_water'))
            for item, uses in [('needle', 4), ('water_rune_piece', 0)]:
                def count(party):
                    return sum(slot is not None and slot['id'] == item and slot['uses'] == uses
                               for member in party for slot in member['inventory']['slots'])
                assert count(saved['ownership']['party']) == count(checkpoint['party']) + 1
            assert saved['ownership']['reserves'] == checkpoint['reserves']
        packet['steps'] = []; recipe.write_text(json.dumps(packet))
        run('--check-world-session', field, art, recipe, slots, 'read', *extra)
        assert path.read_bytes() == original
        return dict(shared_recruitment_restart=recruitment, shared_field_effects_restart=not recruitment, isolated=True,
                    supplied_tier=1, canonical_access=False,
                    random_cursor=saved['position']['random_cursor'],
                    steps=steps)


def verify_bribe(executable, field, art, temporary_root=None, battle_art=None, previous_executable=None, transactional=False):
    def run(binary, *args):
        result = subprocess.run([str(binary), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='suikoden-world-bribe-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run(executable, '--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        checkpoint = packet['checkpoint']
        checkpoint['money'] = 1500
        packet['draws'] = [0, 3 * (32767 // 8)] + [51] * 16
        packet['steps'] = packet['steps'][:90] + [{}, {'buttons': {'navigation': 'down'}},
                          {'buttons': {'navigation': 'down'}}, {'buttons': {'confirm': True}},
                          {'buttons': {'confirm': True}}]
        recipe = root / 'bribe.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        extra = [] if battle_art is None else [battle_art]
        run(executable, '--check-world-session', field, art, recipe, slots, 'bribe_write' if transactional else 'write', *extra)
        path = slots / 'world-slot1.json'
        original = path.read_bytes(); saved = json.loads(original)
        assert saved['position']['state']['mode'] == 'world'
        assert saved['position']['random_cursor'] == 2
        assert saved['ownership']['money'] == 1500 - 210
        if transactional:
            assert saved['battle_receipt'] == 1
            assert saved['party_ledger']['last_receipt'] is None
        for key in ['party', 'levels', 'experience', 'stats', 'formation', 'weapon_levels', 'equipment', 'loadouts', 'runes', 'storage', 'reserves']:
            assert saved['ownership'][key] == checkpoint[key]
        packet['steps'] = []; recipe.write_text(json.dumps(packet))
        run(executable, '--check-world-session', field, art, recipe, slots, 'bribe_read' if transactional else 'read', *extra)
        assert path.read_bytes() == original
        if previous_executable is not None:
            packet.update(schema='suikoden-world-replay/2', bios_seed=1, draws=[],
                          steps=[{'buttons': {'direction': 'down'}}] * 93)
            package = json.loads((field / 'room.json').read_text())
            regions = [False, True] if (art / 'region-c/scene.json').exists() else [False]
            for connected in regions:
                packet['region_c'] = connected
                packet['steps'] = (service_walk(package, checkpoint['story'], forest=True)
                                   if connected else [{'buttons': {'direction': 'down'}}] * 93)
                recipe.write_text(json.dumps(packet))
                prior = root / ('prior-c-slots' if connected else 'prior-b-slots'); prior.mkdir()
                run(previous_executable, '--check-world-session', field, art, recipe, prior, 'write', *extra)
                old_bytes = (prior / 'world-slot1.json').read_bytes()
                packet['steps'] = []; recipe.write_text(json.dumps(packet))
                run(executable, '--check-world-session', field, art, recipe, prior, 'read', *extra)
                assert (prior / 'world-slot1.json').read_bytes() == old_bytes
        return dict(bribe_restart=True, transactional=transactional, price=210, random_cursor=2, future_draws_checked=16,
                    no_rewards_or_owned_member_changes=True,
                    previous_field_writer_migration=previous_executable is not None)


def verify_free_will(executable, field, art, temporary_root=None, battle_art=None, region='c', previous_executable=None, previous_battle_art=None, transactional=False):
    assert region in ('b', 'c')
    assert battle_art is not None and (battle_art / ('region-c/scene.json' if region == 'c' else 'scene.json')).exists()
    def run(*args, binary=executable):
        result = subprocess.run([str(binary), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='suikoden-world-free-will-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        checkpoint = packet['checkpoint']
        if transactional and region == 'c':
            checkpoint['story']['scenario'] = dict(schema='suikoden-event-story/1', scenario='\0' * 240)
            checkpoint['story']['forest_elf_seen'] = True
        source_case = json.loads((ROOT / 'game/tests/fixtures' / ('world_c_free_will.json' if region == 'c' else 'world_b_party_source.json')).read_text())
        if region == 'b':
            source_case.update(initial_hp=[300] * 6, initial_max_hp=[300] * 6,
                               initial_stats=[dict(zip(('attack', 'skill', 'defense', 'speed', 'magic', 'luck'),
                                                       (row[6], row[1], row[7], row[3], row[4], row[5])))
                                              for row in source_case['stats']],
                               rows=source_case['samples'], free_will_source_commands=source_case['commands'])
        content = json.loads((field / 'battle/trial.json').read_text())
        rules = content['systems']
        boar = next(index for index, rune in enumerate(rules['runes']) if rune['id'] == 'boar')
        capacity = [sum(50 > threshold for threshold in row) for row in rules['magic_thresholds']]
        checkpoint.update(levels=chr(14) * 6, experience=[0] * 6,
                          formation=''.join(chr(i) for i in range(6)),
                          runes=[None, None, boar, None, None, None],
                          loadouts=[{} for _ in range(6)])
        for index, (member, stats) in enumerate(zip(checkpoint['party'], checkpoint['stats'])):
            member.update(hp=source_case['initial_hp'][index], max_hp=source_case['initial_max_hp'][index],
                          status='healthy', balloons=0, rune_charges=[0] * 4, max_rune_charges=capacity)
            stats.update(source_case['initial_stats'][index]); stats['magic'] = 50
        packet.update(schema='suikoden-world-replay/2', region_c=region == 'c')
        packet['draws'] = ([0, 0] + [51] * 8 + [row[1] for row in source_case['draws']] if region == 'c'
                           else [0, 3 * (32767 // 8)] + [51] * 7 + [row['value'] for row in source_case['draws']]) + [51] * 100
        package = json.loads((field / 'room.json').read_text())
        approach = (service_walk(package, checkpoint['story'], forest=True)
                    + [{'buttons': {'direction': 'right'}}] * 80 if region == 'c'
                    else packet['steps'][:90])
        packet['steps'] = (approach
                           + [{}] + [{'buttons': {'navigation': 'down'}}] * 3
                           + [{'buttons': {'confirm': True}}]
                           + [{}] * (len(source_case['rows']) + 32)
                           + [{'buttons': {'confirm': True}}])
        steps = len(packet['steps'])
        recipe = root / 'free-will.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'slots'; slots.mkdir()
        run('--check-world-session', field, art, recipe, slots, 'combat_write' if transactional else 'write', battle_art)
        path = slots / 'world-slot1.json'
        original = path.read_bytes(); saved = json.loads(original)
        if transactional:
            assert saved['schema'] == ('suikoden-world-session/8' if region == 'c' else 'suikoden-world-session/7')
            assert saved['battle_receipt'] == 1 and saved['party_ledger']['last_receipt'] == 1
            if region == 'c':
                assert saved['travel_receipt'] == 1
        assert saved['position']['region'] == 'region_' + region and saved['position']['state']['mode'] == 'world'
        owned = saved['ownership']
        assert owned['money'] == checkpoint['money'] + (300 if region == 'c' else 70)
        assert owned['levels'] == chr(15 if region == 'c' else 14) * 6
        assert owned['experience'] == [700 if region == 'c' else 33] * 6
        profiles = {profile['id']: profile for profile in content['party']}
        for index, member in enumerate(owned['party']):
            gain = (rules['hp_growth'][profiles[member['id']]['growth'][0] * 3] + 51) >> 8 if region == 'c' else 0
            assert member['hp'] == source_case['rows'][-1]['party_hp'][index] + gain
            assert member['max_hp'] == source_case['initial_max_hp'][index] + gain
        assert owned['reserves'] == checkpoint['reserves']
        packet['steps'] = []; recipe.write_text(json.dumps(packet))
        run('--check-world-session', field, art, recipe, slots, 'combat_read' if transactional else 'read', battle_art)
        assert path.read_bytes() == original
        if previous_executable is not None:
            assert region == 'b' and previous_battle_art is not None
            packet.update(bios_seed=1, draws=[], region_c=False,
                          steps=[{'buttons': {'direction': 'down'}}] * 93)
            recipe.write_text(json.dumps(packet))
            prior = root / 'prior-b-slots'; prior.mkdir()
            run('--check-world-session', field, art, recipe, prior, 'write', previous_battle_art,
                binary=previous_executable)
            prior_path = prior / 'world-slot1.json'; prior_bytes = prior_path.read_bytes()
            packet['steps'] = []; recipe.write_text(json.dumps(packet))
            run('--check-world-session', field, art, recipe, prior, 'read', battle_art)
            assert prior_path.read_bytes() == prior_bytes
        return dict(free_will_restart=True, region=region, source_commands=source_case['free_will_source_commands'],
                    source_updates=len(source_case['rows']), source_draws=len(source_case['draws']),
                    ordinary_input_updates=steps, random_cursor=saved['position']['random_cursor'],
                    future_draws_checked=16, previous_b_writer_migration=previous_executable is not None,
                    canonical_entry=False)


def verify_field_handoff(executable, field, art, temporary_root=None, dialogue=False, reconstruction=False):
    def run(*args, success=True):
        result = subprocess.run([str(executable), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result
    with tempfile.TemporaryDirectory(prefix='suikoden-field-handoff-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        scenario = [0] * 240; scenario[15] = 8
        packet['checkpoint']['story']['scenario'] = dict(schema='suikoden-event-story/1', scenario=''.join(map(chr, scenario)))
        package = json.loads((field / 'room.json').read_text())
        arrival_points = {}
        walking = service_walk(package, packet['checkpoint']['story'], forest=True, points=arrival_points)
        packet['steps'] = walking[:arrival_points['entered_vb6_kobold_village']] + [{}] * 500 + [{'buttons': {'confirm': True}}] + [{}] * 200 + [{'buttons': {'confirm': True}}] + [{}] * 400 + [{'buttons': {'confirm': True}}] + [{}] * 80
        packet['draws'] = [255] * 4096
        recipe = root / 'source-arrival.json'; recipe.write_text(json.dumps(packet))
        empty = dict(packet, steps=[])
        empty_recipe = root / 'source-empty.json'; empty_recipe.write_text(json.dumps(empty))
        slots = root / 'internal-checkpoint'; slots.mkdir()
        phase = 'reconstruction' if reconstruction else 'dialogue' if dialogue else 'handoff'
        run('--check-world-session', field, art, recipe, slots, phase + '_checkpoint_write')
        path = slots / (phase + '-event.json'); original = path.read_bytes()
        record = json.loads(original); snapshot = record['snapshot']; scene = snapshot['scene_event']
        if reconstruction:
            assert scene['schema'] == 'suikoden-field-event/18'
            assert scene['reconstruction']['arrival']['receipt']['batch'] == 20
            assert scene['reconstruction']['followon']['receipt']['program'] == 'vb6_r06_entity07_followon'
            assert [entry['entity'] for entry in scene['initializations'][:2]] == [6, 8]
            assert scene['initializations'][1]['pump_pc'] == 6
            assert scene['ordinary_actors']['slots'][0]['avatar']['motion']['x'] == 192
            assert scene['blocker']['reason'] == 'source_gate_unknown'
        else:
            assert scene['schema'] == 'suikoden-field-event/17'
            assert scene['instance']['program_id'] == 'vb6_r06_entity07_followon'
            if dialogue:
                assert scene['text_job']['text'] == 6 and scene['text_job']['state']['cursor'] >= 3
                assert scene['boxes'][0]['anchor'] == {'x': 200, 'y': 176}
                assert scene['boxes'][0]['image'] == 1
            else:
                assert scene['instance']['execution']['pc'] == 1
            assert scene['completed_event']['receipt']['program'] == 'vb6_r06_first_arrival'
            assert scene['completed_event']['receipt']['batch'] == 20
            assert scene['initializations'][0]['entity'] == 6
            assert scene['ordinary_actors']['slots'][0]['avatar']['motion']['x'] == (192 if dialogue else 16)
        run('--check-world-session', field, art, empty_recipe, slots, phase + '_checkpoint_read')
        assert path.read_bytes() == original
        if reconstruction:
            changes = (
                (lambda s:s['scene_event']['reconstruction']['arrival']['receipt'].update(batch=21),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event']['reconstruction']['followon']['receipt'].update(batch=999),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event'].update(schema='suikoden-field-event/16', reconstruction=None),'InvalidFieldEventReceipt'),
                (lambda s:(s['scene_event'].update(schema='suikoden-field-event/16', reconstruction=None, initialization_count=1), s['scene_event']['initializations'].__setitem__(1, None)),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event']['initializations'][1].update(pump_pc=5),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event']['ordinary_actors']['slots'][0]['avatar']['motion'].update(x=24),'InvalidFieldActorState'),
                (lambda s:s['ownership']['story']['scenario'].update(scenario=s['ownership']['story']['scenario']['scenario'][:15]+chr(40)+s['ownership']['story']['scenario']['scenario'][16:]),'InvalidFieldEventStory'),
            )
        else:
            changes = (
                (lambda s:s['scene_event']['completed_event']['receipt'].update(batch=21),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event']['initializations'][0]['receipt'].update(instance=99),'InvalidFieldEventReceipt'),
                (lambda s:s['scene_event']['position_history'].update(x_batch=2),'InvalidFieldActorPositionHistory'),
                (lambda s:s['scene_event']['ordinary_actors']['slots'][0]['avatar']['motion'].update(x=24),'InvalidFieldActorState'),
                (lambda s:s['ownership']['story']['scenario'].update(scenario=s['ownership']['story']['scenario']['scenario'][:15]+chr(104)+s['ownership']['story']['scenario']['scenario'][16:]),'InvalidFieldEventStory'),
            )
        for change, expected in changes:
            altered = json.loads(original); change(altered['snapshot']); path.write_text(json.dumps(altered))
            failure = run('--check-world-session', field, art, empty_recipe, slots, phase + '_checkpoint_read', success=False)
            assert expected in failure.stderr, failure.stderr
        path.write_bytes(original)
        run('--check-world-session', field, art, empty_recipe, slots, phase + '_checkpoint_read')
        return dict(fresh_process_world_handoff=True,dialogue_checkpoint=dialogue,prior_event_batch=20,initializer=[6, 8] if reconstruction else 6,actor_x=192 if dialogue or reconstruction else 16,
                    future_updates_checked=3,forgery_rejected=True,source_facts='diagnostic',
                    ground='diagnostic',live_e7=False,reconstruction=reconstruction,native_window_launched=False,media_accepted=False)


def verify_field_event_host(executable, field, art, temporary_root=None, previous_executable=None):
    def run(*args, success=True, binary=executable):
        result = subprocess.run([str(binary), *map(str, args)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result
    def dialogue_draws(result):
        rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        return rows[-1]['field_dialogue_draws']
    def follower_draws(result):
        rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        row=rows[-1]
        assert row['field_unsupported_follower_graphics']==[4]
        assert [actor['character'] for actor in row['field_followers']]==[2,6,35,38]
        return row['field_followers']
    def hero_draw(result):
        rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        return rows[-1]['field_hero_draw']
    with tempfile.TemporaryDirectory(prefix='suikoden-field-event-host-', dir=temporary_root) as temporary:
        root = Path(temporary)
        bootstrap = root / 'bootstrap'; bootstrap.mkdir()
        run('--check-persistence', bootstrap, 'write')
        packet = supplied_packet(json.loads(primary_save(bootstrap).read_text()))
        scenario = [0] * 240; scenario[15] = 8
        packet['checkpoint']['story']['scenario'] = dict(schema='suikoden-event-story/1', scenario=''.join(map(chr, scenario)))
        package = json.loads((field / 'room.json').read_text())
        arrival_points = {}
        walking = service_walk(package, packet['checkpoint']['story'], forest=True, points=arrival_points)
        entered = walking[:arrival_points['entered_vb6_kobold_village']]
        packet['steps'] = entered + [{}] * 500 + [{'buttons': {'confirm': True}}] + [{}] * 200 + [{'buttons': {'confirm': True}}] + [{}] * 400 + [{'buttons': {'confirm': True}}] + [{}] * 80
        packet['draws'] = [255] * 4096
        recipe = root / 'source-arrival.json'; recipe.write_text(json.dumps(packet))
        slots = root / 'internal-checkpoint'; slots.mkdir()
        run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_write')
        path = slots / 'internal-event.json'; original = path.read_bytes()
        record = json.loads(original); snapshot = record['snapshot']; scene = snapshot['scene_event']
        assert snapshot['ownership']['room'] == 'vb6_kobold_village'
        position = [snapshot['ownership']['x'], snapshot['ownership']['y']]
        assert position == [scene['hero']['x'], scene['hero']['y']]
        assert position == [216, 200]
        assert ord(snapshot['ownership']['story']['scenario']['scenario'][15]) == 40
        assert ord(snapshot['ownership']['story']['scenario']['scenario'][38]) == 2
        assert scene['actor_count'] == 23 and all(not actor['placed'] for actor in scene['actors'][:23])
        assert scene['initialization_done'] and scene['initialization_count'] == 1
        initialized = scene['initializations'][0]
        assert (initialized['entity'], initialized['pump_pc'], initialized['receipt']['instance']) == (6, 3, 1)
        assert initialized['receipt']['program'] == 'vb6_room6_init_06'
        assert (scene['receipt']['instance'], scene['receipt']['batch']) == (2, 20)
        assert scene['instance']['execution']['pc'] == 28
        assert scene['instance']['pending'] is None and not scene['instance']['execution']['active']
        assert scene['blocker'] is None and scene['party_queue'] is None and scene['text_job'] is None
        assert all(box == dict(phase='closed',transition=0,anchor=None,speaker=None,image=None) for box in scene['boxes'])
        dispatch_slots=root/'dispatch-checkpoint';dispatch_slots.mkdir()
        run('--check-world-session',field,art,recipe,dispatch_slots,'dispatch_checkpoint_write')
        dispatch_path=dispatch_slots/'dispatch-event.json';dispatch_bytes=dispatch_path.read_bytes()
        dispatch_snapshot=json.loads(dispatch_bytes)['snapshot']
        assert dispatch_snapshot['schema']=='suikoden-world-session/4'
        assert dispatch_snapshot['source_dispatch']['phase']=='free_selection'
        assert ord(dispatch_snapshot['source_dispatch']['construction_story']['scenario'][15])==8
        assert ord(dispatch_snapshot['source_dispatch']['construction_story']['scenario'][38])==0
        steps = len(packet['steps']); packet['steps'] = []; recipe.write_text(json.dumps(packet))
        run('--check-world-session',field,art,recipe,dispatch_slots,'dispatch_checkpoint_read')
        assert dispatch_path.read_bytes()==dispatch_bytes
        for key in ('population_sha256','dispatch_sha256','bundle_sha256','predicates_sha256'):
            invalid_dispatch=json.loads(dispatch_bytes);invalid_dispatch['snapshot']['source_dispatch'][key]='0'*64
            dispatch_path.write_text(json.dumps(invalid_dispatch))
            try:
                refused=run('--check-world-session',field,art,recipe,dispatch_slots,'dispatch_checkpoint_read',success=False)
                assert 'InvalidFieldDispatchState' in refused.stderr
            finally:
                dispatch_path.write_bytes(dispatch_bytes)
        run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read')
        assert path.read_bytes() == original
        if previous_executable is not None:
            run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read', binary=previous_executable)
            assert path.read_bytes() == original
        future_path=slots/'internal-event-future.json'; future_bytes=future_path.read_bytes()
        supplied=json.loads(original); supplied['snapshot']['schema']='suikoden-world-session/3'; supplied['snapshot']['area_commands']=dict(cached=0x422,area=0x422)
        future_text=future_bytes.decode()
        assert future_text.count('"schema":"suikoden-world-session/2"')==1
        future_text=future_text.replace('"schema":"suikoden-world-session/2"','"schema":"suikoden-world-session/3"',1)
        field_start=future_text.index('"scene_event":')+len('"scene_event":')
        _,field_end=json.JSONDecoder().raw_decode(future_text,field_start)
        supplied_future=(future_text[:field_end]+',"area_commands":{"cached":1058,"area":1058}'+future_text[field_end:]).encode()
        path.write_text(json.dumps(supplied)); future_path.write_bytes(supplied_future)
        try:
            run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read')
        finally:
            path.write_bytes(original); future_path.write_bytes(future_bytes)
        legacy=json.loads(original); legacy['snapshot']['schema']='suikoden-world-session/2'; legacy['snapshot'].pop('area_commands',None)
        path.write_text(json.dumps(legacy))
        try:
            run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read')
        finally:
            path.write_bytes(original)
        record['snapshot']['scene_event']['initializations'][0]['receipt']['instance'] = 2
        path.write_text(json.dumps(record))
        try:
            refused = run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read', success=False)
            assert 'InvalidFieldEventReceipt' in refused.stderr
        finally:
            path.write_bytes(original)
        oversized = json.loads(original)
        oversized_instance = oversized['snapshot']['scene_event']['instance']
        # Deliberately invalid payload tests the bounded codec even after normal program completion.
        oversized_instance['pending'] = dict(batch=dict(id=21,effects=[dict(kind='label')]*65),next=oversized_instance['execution'],story_writes=[])
        path.write_text(json.dumps(oversized))
        try:
            refused = run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read', success=False)
            assert 'UnexpectedToken' in refused.stderr
        finally:
            path.write_bytes(original)
        invalid_box = json.loads(original)
        invalid_box['snapshot']['scene_event']['boxes'][0]['transition'] = 21
        path.write_text(json.dumps(invalid_box))
        try:
            refused = run('--check-world-session', field, art, recipe, slots, 'event_checkpoint_read', success=False)
            assert 'InvalidFieldDialogue' in refused.stderr
        finally:
            path.write_bytes(original)
        body_packet = dict(packet)
        body_packet['steps'] = walking[:arrival_points['entered_vb6_kobold_village']] + [{}] * 180
        body_recipe = root / 'body-arrival.json'; body_recipe.write_text(json.dumps(body_packet))
        body_slots = root / 'body-checkpoint'; body_slots.mkdir()
        body_result=run('--check-world-session', field, art, body_recipe, body_slots, 'event_checkpoint_write')
        body_draws=dialogue_draws(body_result);body_followers=follower_draws(body_result)
        assert any(piece.get('sprite',{}).get('y')==170 for piece in body_draws)
        body_path = body_slots / 'internal-event.json'; body_bytes = body_path.read_bytes()
        body_record = json.loads(body_bytes); job = body_record['snapshot']['scene_event']['text_job']
        assert job['kind'] == 'body' and 0 < job['state']['cursor'] < 10, (job['kind'],job['state']['cursor'])
        body_packet['steps'] = []; body_recipe.write_text(json.dumps(body_packet))
        body_result=run('--check-world-session', field, art, body_recipe, body_slots, 'event_checkpoint_read')
        assert dialogue_draws(body_result)==body_draws and follower_draws(body_result)==body_followers
        assert body_path.read_bytes() == body_bytes
        body_record['snapshot']['scene_event']['text_job']['text'] = 255
        body_path.write_text(json.dumps(body_record))
        try:
            refused = run('--check-world-session', field, art, body_recipe, body_slots, 'event_checkpoint_read', success=False)
            assert 'InvalidFieldDialogue' in refused.stderr
        finally:
            body_path.write_bytes(body_bytes)
        image_packet = dict(packet)
        image_packet['steps'] = entered + [{}] * 500 + [{'buttons': {'confirm': True}}] + [{}] * 45
        image_recipe = root / 'image-arrival.json'; image_recipe.write_text(json.dumps(image_packet))
        image_slots = root / 'image-checkpoint'; image_slots.mkdir()
        image_draws=dialogue_draws(run('--check-world-session', field, art, image_recipe, image_slots, 'event_checkpoint_write'))
        assert image_draws[9]['sprite']['width']==64 and image_draws[9]['sprite']['x']==224
        assert any(piece.get('sprite',{}).get('y')==158 for piece in image_draws[10:])
        image_path = image_slots / 'internal-event.json'; image_bytes = image_path.read_bytes()
        image_record = json.loads(image_bytes); image_scene = image_record['snapshot']['scene_event']
        assert image_scene['boxes'][1]['image'] == 0 and image_scene['boxes'][1]['speaker'] == 4
        assert image_scene['text_job']['kind'] == 'prefix' and 0 < image_scene['text_job']['state']['cursor'] < 7
        image_packet['steps'] = []; image_recipe.write_text(json.dumps(image_packet))
        assert dialogue_draws(run('--check-world-session', field, art, image_recipe, image_slots, 'event_checkpoint_read'))==image_draws
        assert image_path.read_bytes() == image_bytes
        image_record['snapshot']['scene_event']['boxes'][1]['image'] = 255
        image_path.write_text(json.dumps(image_record))
        try:
            refused = run('--check-world-session', field, art, image_recipe, image_slots, 'event_checkpoint_read', success=False)
            assert 'InvalidFieldDialogue' in refused.stderr
        finally:
            image_path.write_bytes(image_bytes)
        hero_packet=dict(packet);hero_packet['steps']=entered+[{}]*60
        hero_recipe=root/'moving-hero.json';hero_recipe.write_text(json.dumps(hero_packet))
        hero_slots=root/'moving-hero-checkpoint';hero_slots.mkdir()
        hero_result=run('--check-world-session',field,art,hero_recipe,hero_slots,'event_checkpoint_write')
        hero_drawn=hero_draw(hero_result);assert hero_drawn['character']==8
        hero_path=hero_slots/'internal-event.json';hero_bytes=hero_path.read_bytes();hero_record=json.loads(hero_bytes)
        hero_scene=hero_record['snapshot']['scene_event']
        assert hero_scene['alignment'] is not None and hero_scene['hero_sprite']['animation']['remaining']>0
        hero_packet['steps']=[];hero_recipe.write_text(json.dumps(hero_packet))
        assert hero_draw(run('--check-world-session',field,art,hero_recipe,hero_slots,'event_checkpoint_read'))==hero_drawn
        assert hero_path.read_bytes()==hero_bytes
        for change,expected in ((lambda s:s['hero_sprite']['animation'].update(remaining=0),'InvalidFieldHeroAnimation'),
                                (lambda s:s['hero_sprite'].update(emitted_frame=255),'InvalidFieldHeroAnimation'),
                                (lambda s:s.update(hero_sha256='0'*64),'FieldEventIdentityMismatch'),
                                (lambda s:s.update(schema='suikoden-field-event/10',hero_sprite=None,hero_sha256=''),'FieldEventIdentityMismatch')):
            invalid=json.loads(hero_bytes);change(invalid['snapshot']['scene_event'])
            hero_path.write_text(json.dumps(invalid))
            refused=run('--check-world-session',field,art,hero_recipe,hero_slots,'event_checkpoint_read',success=False)
            assert expected in refused.stderr
        hero_path.write_bytes(hero_bytes)
        motion_packet=dict(packet);motion_packet['steps']=entered+[{}]*124
        motion_recipe=root/'moving-follower.json';motion_recipe.write_text(json.dumps(motion_packet))
        motion_slots=root/'moving-follower-checkpoint';motion_slots.mkdir()
        motion_result=run('--check-world-session',field,art,motion_recipe,motion_slots,'event_checkpoint_write')
        moving_draws=follower_draws(motion_result)
        motion_path=motion_slots/'internal-event.json';motion_bytes=motion_path.read_bytes();motion_record=json.loads(motion_bytes)
        moving_follower=motion_record['snapshot']['scene_event']['party_queue']['followers'][0]
        assert moving_follower['position']['offset_x'] or moving_follower['position']['offset_y'],moving_follower
        assert moving_follower['sprite']['animation']['remaining']>0
        motion_packet['steps']=[];motion_recipe.write_text(json.dumps(motion_packet))
        assert follower_draws(run('--check-world-session',field,art,motion_recipe,motion_slots,'event_checkpoint_read'))==moving_draws
        assert motion_path.read_bytes()==motion_bytes
        motion_record['snapshot']['scene_event']['party_queue']['followers'][0]['sprite']['animation']['remaining']=0
        motion_path.write_text(json.dumps(motion_record))
        refused=run('--check-world-session',field,art,motion_recipe,motion_slots,'event_checkpoint_read',success=False)
        assert 'InvalidFieldPartyGraphics' in refused.stderr
        motion_path.write_bytes(motion_bytes)
        legacy_active=json.loads(motion_bytes)
        legacy_active['snapshot']['scene_event']['schema']='suikoden-field-event/9'
        legacy_active['snapshot']['scene_event']['graphics_sha256']=''
        motion_path.write_text(json.dumps(legacy_active))
        refused=run('--check-world-session',field,art,motion_recipe,motion_slots,'event_checkpoint_read',success=False)
        assert 'FieldEventIdentityMismatch' in refused.stderr
        motion_path.write_bytes(motion_bytes)
        changed_field=root/'changed-field';changed_field.mkdir()
        for entry in field.iterdir():
            if entry.name!='field-ui':
                (changed_field/entry.name).symlink_to(entry.resolve(),target_is_directory=entry.is_dir())
        shutil.copytree(field/'field-ui',changed_field/'field-ui')
        ui_path=changed_field/'field-ui/ui.json';ui_bytes=ui_path.read_bytes();ui=json.loads(ui_bytes)
        ui['portraits'][0]['id']='viktor_portrait';ui_path.write_text(json.dumps(ui))
        refused=run('--check-world-session',changed_field,art,image_recipe,image_slots,'event_checkpoint_read',success=False)
        assert 'InvalidFieldDialogueArt' in refused.stderr
        ui_path.write_bytes(ui_bytes)
        changed_ui=json.loads(ui_bytes);changed_ui['followers'][0]['character']=4
        ui_path.write_text(json.dumps(changed_ui))
        refused=run('--check-world-session',changed_field,art,image_recipe,image_slots,'event_checkpoint_read',success=False)
        assert 'InvalidFieldPartyGraphics' in refused.stderr
        ui_path.write_bytes(ui_bytes)
        atlas_path=changed_field/'field-ui/atlas.png';atlas_bytes=atlas_path.read_bytes()
        atlas_path.write_bytes(atlas_bytes+b'changed')
        refused=run('--check-world-session',changed_field,art,image_recipe,image_slots,'event_checkpoint_read',success=False)
        assert 'FieldDialogueAtlasMismatch' in refused.stderr
        shutil.rmtree(changed_field/'field-ui')
        refused=run('--check-world-session',changed_field,art,image_recipe,image_slots,'event_checkpoint_read',success=False)
        assert 'MissingFieldDialogueArt' in refused.stderr
        assert not (slots / 'world-slot1.json').exists()
        return dict(ordinary_field_inputs=steps, selected_staged_actors=23, spawned_actors=0,
                    entry_position=position, initialized_entities=[6], initializer_pump_pc=3,
                    initializer_story_byte38=2, acknowledged_arrival_batches=20, first_arrival_program_completed=True, source_story_byte15=40,
                    party_spread_completed=True,
                    dialogue_output_fresh_restart=True,body_draw_pieces=len(body_draws),image_draw_pieces=len(image_draws),
                    hero_alignment_draw_restart=True,invalid_hero_sprite_rejected=True,active_legacy_hero_rejected=True,
                    gremio_follower_draw_restart=True,moving_follower_restart=True,invalid_sprite_rejected=True,unsupported_follower_graphics=[4],
                    drawn_temporary_followers=4,party_follower_draw_restart=True,active_legacy_scene_rejected=True,invalid_follower_resource_rejected=True,
                    invalid_ui_identity_rejected=True,changed_ui_atlas_rejected=True,missing_ui_explicit=True,
                    all_three_dialogues_completed=True, party_return_released=True, image_mid_name_restart=True, invalid_image_rejected=True, mid_body_cursor=job['state']['cursor'], mid_body_fresh_restart=True, future_updates_checked=3, invalid_box_rejected=True, invalid_text_rejected=True,
                    fresh_process_internal_restart=True, prior_input_replayed=False,
                    supplied_area_command_fresh_process_restart=True, version2_internal_checkpoint_migration=True,
                    previous_binary_reads_current_checkpoint=previous_executable is not None,
                    source_dispatch_e7_blocker_fresh_process_restart=True,source_dispatch_gates_supplied=True,
                    tampered_receipt_rejected=True, oversized_pending_rejected=True, user_cutscene_saving_enabled=False,
                    scene_complete=False, media_accepted=False)


if __name__ == '__main__':
    if len(sys.argv) == 1:
        from bundle_macos import verify_packaged_saves

        executable = ROOT / 'game/zig-out/bin/suikoden-journey'
        content = ROOT / 'kit/work/build/canonical'
        with tempfile.TemporaryDirectory(prefix='suikoden-current-session-') as directory:
            print(verify_packaged_saves(executable, content, directory), end='')
        raise SystemExit(0)

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, default=ROOT / 'game/zig-out/bin/suikoden-journey')
    parser.add_argument('--field', type=Path, default=ROOT / 'kit/work/build/journey')
    parser.add_argument('--art', type=Path, default=ROOT / 'kit/work/build/world-travel-art')
    parser.add_argument('--battle-art', type=Path)
    parser.add_argument('--temporary-root', type=Path)
    parser.add_argument('--candidate-entry', type=Path)
    parser.add_argument('--previous-executable', type=Path)
    parser.add_argument('--previous-battle-art', type=Path)
    parser.add_argument('--previous-c7-executable', type=Path)
    parser.add_argument('--previous-c8-executable', type=Path)
    parser.add_argument('--previous-c9-executable', type=Path)
    parser.add_argument('--recruitment-only', action='store_true')
    parser.add_argument('--field-effects-only', action='store_true')
    parser.add_argument('--bribe-only', action='store_true')
    parser.add_argument('--free-will-only', action='store_true')
    parser.add_argument('--transactional', action='store_true')
    parser.add_argument('--b-party-only', action='store_true')
    parser.add_argument('--field-event-only', action='store_true')
    parser.add_argument('--handoff-only', action='store_true')
    parser.add_argument('--dialogue-handoff-only', action='store_true')
    parser.add_argument('--reconstruction-only', action='store_true')
    parser.add_argument('--party-menu-only', action='store_true')
    parser.add_argument('--village-only', action='store_true')
    parser.add_argument('--village-exit-only', action='store_true')
    args = parser.parse_args()
    if args.village_exit_only:
        print(json.dumps(verify_village_exit(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root), sort_keys=True))
        raise SystemExit(0)
    if args.village_only:
        print(json.dumps(verify_village_session(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root), sort_keys=True))
        raise SystemExit(0)
    if args.party_menu_only:
        print(json.dumps(verify_party_menu(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root), sort_keys=True))
        raise SystemExit(0)
    if args.handoff_only or args.dialogue_handoff_only or args.reconstruction_only:
        print(json.dumps(verify_field_handoff(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.dialogue_handoff_only, args.reconstruction_only), sort_keys=True))
        raise SystemExit(0)
    if args.field_event_only:
        print(json.dumps(verify_field_event_host(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.previous_executable), sort_keys=True))
        raise SystemExit(0)
    if args.free_will_only or args.b_party_only:
        print(json.dumps(verify_free_will(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.battle_art, 'b' if args.b_party_only else 'c', args.previous_executable, args.previous_battle_art, args.transactional), sort_keys=True))
        raise SystemExit(0)
    if args.bribe_only:
        print(json.dumps(verify_bribe(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.battle_art, args.previous_executable, args.transactional), sort_keys=True))
        raise SystemExit(0)
    if args.recruitment_only or args.field_effects_only:
        print(json.dumps(verify_field_effects(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.battle_art, recruitment=not args.field_effects_only), sort_keys=True))
        raise SystemExit(0)
    print(json.dumps(verify(args.executable.resolve(), args.field.resolve(), args.art.resolve(), args.temporary_root, args.battle_art, args.candidate_entry, args.previous_executable, args.previous_c7_executable, args.previous_c8_executable, args.previous_c9_executable), sort_keys=True))
