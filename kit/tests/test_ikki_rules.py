#!/usr/bin/env python3
"""Independent static duel-rule witnesses and headless reference-vector generator."""
import argparse
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit' / 'tools'))
import disc
import ikki_animations as animation
import ikki_palettes as source
from war_text import decode as decode_text

FIXTURE = ROOT / 'game' / 'tests' / 'fixtures' / 'duel_vectors.json'
DATA = ROOT / 'game' / 'assets' / 'duels.json'
KIND = {1: 'normal', 2: 'defended', 4: 'desperate_success', 8: 'desperate_failure'}
COMMAND = ('attack', 'defend', 'desperate_attack')


def reference_damage(hp, attack, defense, kind, roll):
    difference = attack - defense
    base = difference if difference > 0 else 1
    amount = base + ((base // 100 * roll) % 10)
    if kind == 'defended':
        amount //= 2
    if kind in ('desperate_success', 'desperate_failure'):
        if kind == 'desperate_success':
            amount *= 2
        quarter = hp // 4
        if amount > quarter:
            amount = quarter
    return amount


def reference_choice(roll):
    return ((roll * 3) // 32767) % 3


def make_vectors():
    damage_cases = [
        (1000, 160, 80, 'normal', 0, 80),
        (1000, 160, 80, 'defended', 0, 40),
        (1000, 160, 80, 'desperate_success', 0, 160),
        (1000, 160, 80, 'desperate_failure', 0, 80),
        (100, 500, 20, 'normal', 32767, 488),
        (100, 500, 20, 'defended', 32767, 244),
        (100, 500, 20, 'desperate_success', 32767, 25),
        (100, 500, 20, 'desperate_failure', 32767, 25),
        (3, 160, 80, 'desperate_success', 0, 0),
        (3, 160, 80, 'desperate_failure', 0, 0),
        (1000, 1, 200, 'normal', 32767, 1),
        (1000, 200, 100, 'normal', 12345, 105),
    ]
    for hp, attack, defense, kind, roll, expected in damage_cases:
        assert reference_damage(hp, attack, defense, kind, roll) == expected
    choice_rolls = (0, 10922, 10923, 21844, 21845, 32766, 32767)
    choices = [reference_choice(roll) for roll in choice_rolls]
    assert choices == [0, 0, 1, 1, 2, 2, 0]
    rounds = []
    for record in animation.extract()['overlays']:
        name = Path(record['overlay']).stem
        duel_id = {'PAN_TEO': 'pahn_teo', 'SHU_KWA': 'shu_kwanda', 'SHU_TEO': 'shu_teo'}[name]
        for outcome in range(1, 10):
            schedule = animation.schedule(record, outcome)
            hp = [1000, 1000]
            events = []
            source_hits = [event for event in schedule['events'] if event['op'] == 14]
            source_hits.sort(key=lambda event: (event['tick'], event['actor']))
            for event in source_hits:
                target = event['actor']
                kind = KIND[event['args'][0]]
                amount = reference_damage(hp[target], 160, 80, kind, 0)
                hp[target] -= amount
                if hp[target] > 1000:
                    hp[target] = 1000
                events.append({'tick': event['tick'], 'target': target, 'kind': kind,
                               'damage': amount, 'hp': hp.copy()})
            player, opponent = COMMAND[(outcome - 1) // 3], COMMAND[(outcome - 1) % 3]
            rounds.append({'duel': duel_id, 'player': player, 'opponent': opponent,
                           'choice_roll': (0, 12000, 24000)[(outcome - 1) % 3],
                           'hp': hp, 'events': events,
                           'exchange_updates': schedule['updates_to_quiescence'], 'round_pause': 20})
    return {
        'schema': 'suikoden.duel-reference.v1',
        'damage': [dict(zip(('hp', 'attack', 'defense', 'kind', 'roll', 'damage'), row)) for row in damage_cases],
        'opponent_choices': [{'roll': roll, 'choice': choice} for roll, choice in zip(choice_rolls, choices)],
        'rounds': rounds,
    }


def verify_static_sources(export):
    root_overlays = {row['path'] for row in source._iso()
                     if row['path'].startswith(source.OVERLAY_DIR) and row['path'].endswith('.BIN')
                     and '/' not in row['path'][len(source.OVERLAY_DIR):]}
    assert root_overlays == {source.OVERLAY_DIR + name for name in source.OVERLAYS}
    assert len(export['duels']) == 3
    # Raw instruction witnesses, checked independently in every overlay.
    instructions = {
        0x3974: 0xA6420000, 0x3980: 0xA6420002, 0x399C: 0x0040F809,
        0x39D4: 0x84E20000, 0x39DC: 0xACC206A8, 0x39E0: 0x85020000,
        0x39EC: 0xACC206A4, 0x39FC: 0xA46206AC, 0x3A14: 0x25290010,
        0x3A18: 0x25080004, 0x3A28: 0x24E70004,
        0x467C: 0x946506B8, 0x4684: 0x948206BC,
        0x4688: 0x948306BA, 0x4690: 0x00A38023, 0x469C: 0x34100001,
        0x46C4: 0x34030064, 0x46F8: 0x00620018, 0x4704: 0x3403000A,
        0x4730: 0x00003810, 0x47A8: 0x30620001, 0x47E0: 0x001017C2,
        0x47F4: 0x00108043, 0x4818: 0x8C8206A4, 0x4824: 0x00108040,
        0x482C: 0x00021083, 0x4988: 0xA4A006BC, 0x498C: 0x00501023,
        0x4990: 0xACA206A4, 0x4994: 0x0062102A, 0x49A0: 0xACA306A4,
        0x78C0: 0x00021840, 0x78C8: 0x34027FFF, 0x78F8: 0x34020003,
        0x7924: 0x00001010, 0x7AE8: 0x8C620008, 0x7AF0: 0x2442FFFF,
        0x7B24: 0x8C6206A4, 0x7B30: 0x34020078, 0x7B6C: 0x8C6206C0,
        0x7B78: 0x34020078, 0x7C10: 0x2442FFFF, 0x7C2C: 0x0C021998,
        0x1FE8: 0x0C02118D, 0x1FEC: 0x00002021, 0x1FF0: 0x0C02118D,
        0x1FF4: 0x34040001,
    }
    for duel in export['duels']:
        name = Path(duel['provenance']['disc_file']).name
        raw = source.overlay(name)
        assert len(raw) == duel['provenance']['size']
        assert disc.extract(duel['provenance']['lba'], len(raw)) == raw
        for offset, expected in instructions.items():
            actual = struct.unpack_from('<I', raw, offset)[0]
            assert actual == expected, (name, hex(offset), hex(actual), hex(expected))
        hp_offset, attack_offset = (0x9B68, 0x9B88) if name == 'PAN_TEO.BIN' else (0x9B4C, 0x9B6C)
        maximum_hp, current_hp = struct.unpack_from('<HH', raw, hp_offset)
        attack, defense = struct.unpack_from('<HH', raw, attack_offset)
        assert duel['initial_opponent'] == {
            'maximum_hp': maximum_hp, 'hp': current_hp, 'attack': attack, 'defense': defense,
        }, name
        # Independent cue pointer walk, without the producer's semantic export.
        cue_table = animation.materialized(raw, 0x7204)
        cues = []
        for previous in range(3):
            row = animation.pointer(raw, cue_table + 4 * previous)
            cues.append([decode_text(raw, animation.pointer(raw, row + 4 * current))[0]
                         for current in range(3)])
        assert cues == duel['cues']
        assert duel['round_pause_updates'] == 20 and duel['defeat_prelude_updates'] == 120
        assert len(duel['exchanges']) == 9
        assert {exchange['id'] for exchange in duel['exchanges']} == {
            f'{player}__{opponent}' for player in COMMAND for opponent in COMMAND}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-fixtures', action='store_true')
    args = parser.parse_args()
    export = json.loads(DATA.read_text())
    verify_static_sources(export)
    vectors = make_vectors()
    if args.write_fixtures:
        FIXTURE.write_text(json.dumps(vectors, indent=2) + '\n')
    elif FIXTURE.exists():
        assert json.loads(FIXTURE.read_text()) == vectors
    print('IKKI rules PASS: 3 duels, 27 exchanges, independent entry stats/cues/RNG/damage/timing witnesses')


if __name__ == '__main__':
    main()
