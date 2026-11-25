"""C formation1 candidate pixels and action samples against independent original consumers."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import tempfile
from copy import deepcopy
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_world_battle as export
from export_first_room import source
from test_battle_trial_export import source_pose
from test_world_region_c import archer_trace
from test_world_party_actions import check as party_cases


def check():
    party = party_cases()
    witness = archer_trace('world_c_archer_two_round_visual')
    reference = witness['rows']
    defended = archer_trace('world_c_archer_misses_defend')
    retained = archer_trace('world_c_archer_misses_retained')
    assert defended['draws'] == retained['draws']
    for before, after in zip(defended['rows'], retained['rows'], strict=True):
        for target in (0, 1):
            base, actual = before['visuals'][target], after['visuals'][target]
            assert actual == dict(base, offset=[base['offset'][0], base['offset'][1] - 2])
    import maindec
    assert struct.unpack_from('<10H', maindec.body(), 0x8016C094 - maindec.MBASE) == (15, 0, 1, 22, 20, 21, 16, 0, 1, 0)
    for hp in (1, 24, 25, 49, 50, 51):
        boundary = archer_trace(f'world_c_archer_gremio_{hp}')
        assert boundary['rows'][58]['party_hp'][1] == max(0, hp - 50)
        assert not boundary['rows'][93]['party_down'][1]
        assert boundary['rows'][94]['party_down'][1] == (hp <= 50)
        assert boundary['rows'][94]['visuals'][1]['pose'] == (3 if hp <= 50 else 2)
    knockout = archer_trace('world_c_archer_gremio_knockout')
    assert knockout['launch']['formation'] == [0, 3, 2, 1, 4, 5]
    assert knockout['second'][-1]['party_hp'] == [100, 0, 100, 100, 100, 100]
    assert knockout['rewards']['experience'] == [1700, 0, 1700, 1700, 1700, 1700]
    with tempfile.TemporaryDirectory(prefix='suikoden-c-battle-art-') as temporary:
        output = Path(temporary)
        scene, proof = export.export_c(output)
        assert scene == json.loads((ROOT / 'game/tests/fixtures/world_c_party_art.json').read_text())
        legacy = deepcopy(scene); legacy['schema'] = 'suikoden-world-battle-art/9'
        legacy['c_tracks']['extra_party_attacks'] = [entry for entry in legacy['c_tracks']['extra_party_attacks'] if entry['id'] == 'gremio']
        for entry in legacy['c_tracks']['extra_party_attacks']:
            del entry['target_hurt']
        for actor in legacy['actors']:
            actor.pop('impact_offsets', None)
        assert legacy == json.loads((ROOT / 'game/tests/fixtures/world_c_archer_art_gremio.json').read_text())
        legacy['schema'] = 'suikoden-world-battle-art/8'
        del legacy['c_tracks']['extra_party_attacks']; del legacy['c_tracks']['repeated_hurt']
        assert legacy == json.loads((ROOT / 'game/tests/fixtures/world_c_archer_art_lowhp.json').read_text())
        legacy['schema'] = 'suikoden-world-battle-art/7'; del legacy['c_tracks']['low_hp']
        assert legacy == json.loads((ROOT / 'game/tests/fixtures/world_c_archer_art_misses.json').read_text())
        legacy['schema'] = 'suikoden-world-battle-art/6'; del legacy['c_tracks']['misses']
        assert legacy == json.loads((ROOT / 'game/tests/fixtures/world_c_archer_art.json').read_text())
        assert scene['region'] == 'region_c' and scene['encounter'] == 'world_c_encounter_1'
        assert not proof['media_accepted'] and not proof['promoted'] and not proof['native_launched']
        assert not any(origin['file'].endswith(('A_DATA.BIN', 'B_DATA.BIN')) for origin in proof['sources'])
        samples = 0
        for actor, visual, begin, track in ((6, 2, 1, 'attack'), (7, 3, 4, 'attack'), (0, 0, 56, 'hurt'), (1, 1, 59, 'hurt'), (6, 2, 189, 'hurt')):
            for index, actual in enumerate(scene['actors'][actor][track]):
                expected = reference[begin + index - 1]['visuals'][visual]
                assert all(actual[key] == expected[key] for key in actual), (actor, track, index)
                samples += 1
        for index, actual in enumerate(scene['c_tracks']['hero_attacks'][0]['after_hit']):
            expected = reference[117 + index - 1]['visuals'][0]
            assert all(actual[key] == expected[key] for key in actual), ('hero', index)
            samples += 1
        for enemy, begin in ((0, 41), (1, 44)):
            track = scene['c_tracks']['projectiles'][enemy][enemy]
            for index, actual in enumerate(track):
                expected = next(row for row in reference[begin + index - 1]['projectiles'] if row['owner'] == enemy + 6)
                assert all(actual[key] == expected[key] for key in actual), ('projectile', enemy, index)
                samples += 1
        second = witness['second']
        for actor, visual, begin, track in ((7, 3, 32, 'attack'), (0, 0, 87, 'hurt'), (7, 3, 220, 'hurt')):
            for index, actual in enumerate(scene['actors'][actor][track]):
                expected = second[begin + index - 1]['visuals'][visual]
                assert all(actual[key] == expected[key] for key in actual), ('second', actor, track, index)
                samples += 1
        for index, actual in enumerate(scene['c_tracks']['hero_attacks'][1]['after_hit']):
            expected = second[148 + index - 1]['visuals'][0]
            assert all(actual[key] == expected[key] for key in actual), ('second Hero', index)
            samples += 1
        for index, actual in enumerate(scene['c_tracks']['projectiles'][1][0]):
            expected = next(row for row in second[72 + index - 1]['projectiles'] if row['owner'] == 7)
            assert all(actual[key] == expected[key] for key in actual), ('second projectile', index)
            samples += 1
        missed = archer_trace('world_c_archer_misses')
        for rows, owner, target, begin in ((missed['rows'], 0, 0, 1), (missed['rows'], 1, 1, 4), (missed['second'], 1, 0, 32)):
            for index, actual in enumerate(scene['c_tracks']['misses']['dodges'][target]):
                expected = rows[begin + index - 1]['visuals'][target]
                assert all(actual[key] == expected[key] for key in actual), ('dodge', owner, target, index)
                samples += 1
            for index, actual in enumerate(scene['c_tracks']['misses']['projectiles'][owner][target]):
                expected = next(row for row in rows[begin + 40 + index - 1]['projectiles'] if row['owner'] == owner + 6)
                assert all(actual[key] == expected[key] for key in actual), ('overshoot', owner, target, index)
                samples += 1
        for target, rows, begin in ((0, missed['rows'], 117), (1, missed['second'], 148)):
            for index, actual in enumerate(scene['c_tracks']['hero_attacks'][target]['unhurt']):
                expected = rows[begin + index - 1]['visuals'][0]
                assert all(actual[key] == expected[key] for key in actual), ('unhurt attack', target, index)
                samples += 1
        low_hit = archer_trace('world_c_archer_gremio_24')
        low_miss = archer_trace('world_c_archer_gremio_lowhp_miss')
        for rows, track in ((low_hit['rows'], scene['c_tracks']['low_hp']['projectiles'][1]), (low_miss['rows'], scene['c_tracks']['low_hp']['miss_projectiles'][1])):
            for index, actual in enumerate(track):
                expected = next(row for row in rows[44 + index - 1]['projectiles'] if row['owner'] == 7)
                assert all(actual[key] == expected[key] for key in actual), ('low-HP aim', index)
                samples += 1
        for index, actual in enumerate(scene['c_tracks']['low_hp']['dodge']):
            expected = low_miss['rows'][4 + index - 1]['visuals'][1]
            assert all(actual[key] == expected[key] for key in actual), ('low-HP dodge', index)
            samples += 1
        gremio = archer_trace('world_c_archer_gremio_attack')
        gremio_misses = archer_trace('world_c_archer_gremio_attack_misses')
        alternate = archer_trace('world_c_archer_gremio_attack_target1')
        assert alternate['rows'][-1]['enemy_hp'] == [120, 0]
        nonlethal = archer_trace('world_c_archer_gremio_attack_nonlethal')
        assert nonlethal['rows'][-1]['enemy_hp'] == [103, 120]
        for rows, target, begin, variant in ((gremio['rows'], 0, 117, 'after_hit'), (gremio['second'], 1, 148, 'unhurt'), (gremio_misses['rows'], 0, 125, 'unhurt'), (alternate['rows'], 1, 120, 'after_hit')):
            track = scene['c_tracks']['extra_party_attacks'][0]['targets'][target][variant]
            for index, actual in enumerate(track):
                expected = rows[begin + index - 1]['visuals'][1]
                assert all(actual[key] == expected[key] for key in actual), ('Gremio attack', variant, target, index)
                samples += 1
        for index, actual in enumerate(scene['c_tracks']['repeated_hurt'][0]):
            expected = gremio['second'][87 + index - 1]['visuals'][0]
            assert all(actual[key] == expected[key] for key in actual), ('repeated Hero hurt', index)
            samples += 1
        ordinary = party['all_nonlethal']['rows']
        for member, begin in ((2, 117), (4, 332), (5, 442)):
            tracks = next(entry for entry in scene['c_tracks']['extra_party_attacks'] if entry['id'] == scene['actors'][member]['id'])
            for index, actual in enumerate(tracks['targets'][0]['unhurt']):
                expected = ordinary[begin + index - 1]['party_visuals'][member]
                assert all(actual[key] == expected[key] for key in actual), ('ordinary party', member, index)
                samples += 1
        for member, target, begin in ((2, 0, 173), (1, 1, 290), (4, 0, 405), (5, 0, 515)):
            tracks = next(entry for entry in scene['c_tracks']['extra_party_attacks'] if entry['id'] == scene['actors'][member]['id'])
            for index, actual in enumerate(tracks['target_hurt'][target]):
                expected = ordinary[begin + index - 1]['visuals'][2 + target]
                assert all(actual[key] == expected[key] for key in actual), ('ordinary target reaction', member, index)
                samples += 1
        poses = 0
        with Image.open(output / 'actors.png') as atlas:
            for index, (actor, details) in enumerate(zip(scene['actors'][:7], proof['actors'][:7])):
                origin = proof['sources'][0 if index == 6 else index + 2]
                raw, actual_origin = source('/' + origin['file'].split('/')[-1])
                assert origin == actual_origin
                seen = set()
                for animation, clip in enumerate(actor['animations']):
                    for step, frame in enumerate(clip):
                        if frame['pose'] in seen:
                            continue
                        expected, ax, ay = source_pose(raw, details['section'], 0x80080000 if index == 6 else 0, animation, step)
                        pose = actor['poses'][frame['pose']]; rect = pose['rect']
                        actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                        assert actual.size == expected.size and actual.tobytes() == expected.tobytes(), (actor['id'], animation, step)
                        assert (pose['anchor_x'], pose['anchor_y']) == (ax, ay)
                        seen.add(frame['pose']); poses += 1
        raw, _ = source('/C_DATA.BIN')
        pointer = lambda offset: int.from_bytes(raw[offset:offset + 4], 'little') - 0x80080000
        directory = pointer(pointer(pointer(0) + 12))
        height = pointer(directory + 16)
        grid = proof['heightfield']
        count = (grid['across'] + 1) * (grid['down'] + 1)
        assert len(grid['vertices']) == count
        assert [row[2] for row in grid['vertices']] == list(struct.unpack_from('<' + str(count) + 'h', raw, height))
        hashes = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in ('scene.json', 'actors.png', 'floor.png', 'provenance.json')}
        export.export_c(output)
        assert hashes == {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in hashes}
    try:
        export.export_c(ROOT / 'kit/work/accepted/battle_c')
    except ValueError:
        pass
    else:
        raise AssertionError('candidate exporter accepted the reviewed staging tree')
    print(f'PASS: C battle {samples} retained action/projectile samples, {poses} independent pose pixels/anchors, source heightfield and deterministic candidate')


if __name__ == '__main__':
    check()
