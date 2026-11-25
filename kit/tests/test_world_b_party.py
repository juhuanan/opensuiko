"""Region B party tracks against static clocks and the retained Roc round."""
from collections import Counter
from hashlib import sha256
from pathlib import Path
import argparse
import json
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from export_first_room import source
from export_world_travel import party_attack_timing, roc_timings, squirrel_knockout_ticks

FIXTURES = ROOT / 'game/tests/fixtures'
PARTY = ('hero', 'gremio', 'pahn', 'viktor', 'yam_koo', 'tai_ho')
WITNESS_SHA256 = '1cee6c590950f5ac0d5cc1091e8123aea2331270ad54315b06bb2e7666032db0'


def check_clocks(witness):
    samples = witness['samples']
    assert [sample['tick'] for sample in samples] == list(range(1, 776))
    draws = witness['draws']
    assert len(draws) == 38 and all(draw['value'] == 51 for draw in draws)
    draws_at = Counter(draw['tick'] for draw in draws)
    consumed = 0
    for sample in samples:
        consumed += draws_at[sample['tick']]
        assert sample['draws'] == consumed, sample['tick']
    assert consumed == len(draws)

    raw, _ = source('/B_DATA.BIN')
    roc = roc_timings(raw)
    assert not samples[roc['duration'] - 1]['enemy_lock']
    assert not samples[roc['impact_tick'] + roc['target_release_delay'] - 1]['party_locks'][0]
    expected_events = [dict(tick=roc['impact_tick'], kind='physical', actor=6, target=0)]
    commands = [event for event in witness['source_events'] if event['kind'] == 'command']
    assert [event['actor'] for event in commands] == [1, 0, 2, 4, 5]
    impacts = []
    for command in commands:
        actor, start = command['actor'], command['tick']
        timing = party_attack_timing(PARTY[actor])
        impact = start + timing['impact_tick'] - 1
        release = start + timing['release_tick'] - 1
        assert all(row['party_locks'][actor] for row in samples[start - 1:release - 1]), PARTY[actor]
        assert not samples[release - 1]['party_locks'][actor], PARTY[actor]
        expected_events.extend((command, dict(tick=impact, kind='physical', actor=actor, target=6)))
        impacts.append(impact)
    assert witness['source_events'] == expected_events
    assert [after['tick'] for before, after in zip(samples, samples[1:])
            if before['enemy_hp'] != after['enemy_hp']] == impacts

    death = impacts[-1] + party_attack_timing('tai_ho')['target_release_delay']
    release = death + squirrel_knockout_ticks(raw, 0x236C8) - 1
    assert not samples[death - 2]['enemy_down'] and samples[death - 1]['enemy_down']
    assert all(row['enemy_lock'] for row in samples[death - 1:release - 1])
    assert not samples[release - 1]['enemy_lock']
    assert samples[release]['coordinator']['stage'] == 'round_ready'


def compare(scene, witness):
    assert scene['schema'] in ('suikoden-world-battle-art/11','suikoden-world-battle-art/12')
    legacy = dict(scene)
    legacy['schema'] = 'suikoden-world-battle-art/5'
    legacy['actors']=[{k:v for k,v in actor.items() if k!='impact_offsets'} for actor in legacy['actors']]
    entries = {entry['id']: entry for entry in legacy.pop('extra_party_attacks')}
    assert legacy == json.loads((FIXTURES / 'world_roc_art.json').read_text())
    compared, restored = 0, False
    for event in witness['source_events']:
        actor = event['actor']
        if actor >= 6:
            continue
        entry = entries[PARTY[actor]]
        begin = event['tick'] - 1
        if event['kind'] == 'command':
            offset = witness['samples'][begin]['party_visuals'][actor]['offset']
            variant = 'after_hit' if offset != [0, 0] else 'unhurt'
            for index, actual in enumerate(entry['targets'][0][variant]):
                expected = witness['samples'][begin + index]['party_visuals'][actor]
                assert all(actual[key] == expected[key] for key in actual), (PARTY[actor], variant, begin + index + 1, actual, expected)
                assert expected['visible']
                compared += 1
        else:
            variant = 'restored_target_hurt' if restored else 'target_hurt'
            for index, actual in enumerate(entry[variant][0]):
                expected = witness['samples'][begin + index]['roc']
                assert all(actual[key] == expected[key] for key in actual), (PARTY[actor], variant, begin + index + 1, actual, expected)
                compared += 1
            restored = True
    assert len(witness['samples']) == 775 and len(witness['draws']) == 38
    assert witness['samples'][-1]['enemy_hp'] == 0
    assert witness['samples'][-1]['party_hp'] == [216, 300, 300, 300, 300, 300]
    return compared


def check(candidate=None):
    payload = (FIXTURES / 'world_b_party_source.json').read_bytes()
    assert sha256(payload).hexdigest() == WITNESS_SHA256
    witness = json.loads(payload)
    check_clocks(witness)
    if candidate is None:
        import export_world_battle

        with tempfile.TemporaryDirectory(prefix='suikoden-b-party-source-') as temporary:
            scene, _ = export_world_battle.export(Path(temporary))
    else:
        scene = json.loads(candidate.read_text())
    compared = compare(scene, witness)
    assert json.loads((FIXTURES / 'world_b_party_art.json').read_text()) == scene
    print(f'PASS: five source party attack clocks, {compared} action/reaction samples, 775 retained updates and 38 draws')
    return compared


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path)
    args = parser.parse_args()
    check(args.candidate)
