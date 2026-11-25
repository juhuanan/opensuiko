#!/usr/bin/env python3
"""Export source-backed, semantic Suikoden I duel rules for the headless Zig core."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import ikki_animations as animation
import ikki_palettes as source
from war_text import decode as decode_text

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 'suikoden.duel-rules.v1'
COMMANDS = ('attack', 'defend', 'desperate_attack')
FIGHTERS = {
    'PAN': ('pahn', 'Pahn'),
    'SHU': ('hero', 'Hero'),
    'KWA': ('kwanda', 'Kwanda Rosman'),
    'TEO': ('teo', 'Teo McDohl'),
}
DUEL_IDS = {
    'PAN_TEO.BIN': 'pahn_teo',
    'SHU_KWA.BIN': 'shu_kwanda',
    'SHU_TEO.BIN': 'shu_teo',
}
HIT_KINDS = {1: 'normal', 2: 'defended', 4: 'desperate_success', 8: 'desperate_failure'}


def initial_opponent(raw):
    # The initializer replaces the player's row from live party data before copying both rows.
    hp = animation.materialized(raw, 0x39C4) + 4
    stats = animation.materialized(raw, 0x39BC) + 16
    maximum_hp, current_hp = struct.unpack_from('<HH', raw, hp)
    attack, defense = struct.unpack_from('<HH', raw, stats + 12)
    return {'maximum_hp': maximum_hp, 'hp': current_hp, 'attack': attack, 'defense': defense}


def extract():
    overlays = {Path(record['overlay']).name: record for record in animation.extract()['overlays']}
    duels = []
    for name in source.OVERLAYS:
        raw = source.overlay(name)
        record = overlays[name]
        cue_table = animation.materialized(raw, 0x7204)
        cues = []
        for previous in range(3):
            row = animation.pointer(raw, cue_table + previous * 4)
            cues.append([decode_text(raw, animation.pointer(raw, row + current * 4))[0]
                         for current in range(3)])
        fighters = []
        for family in record['families']:
            stable_id, display_name = FIGHTERS[family['family']]
            fighters.append({'id': stable_id, 'name': display_name,
                             'defeat_updates': family['animations'][48]['total_ticks']})
        exchanges = []
        for round_record in record['rounds']:
            outcome = round_record['outcome_id']
            schedule = animation.schedule(record, outcome)
            hits = []
            for event in schedule['events']:
                if event['op'] != 14:
                    continue
                flags = event['args'][0]
                if flags not in HIT_KINDS:
                    raise ValueError(f'unsupported combat flags {flags:#x}')
                hits.append({'tick': event['tick'], 'target': 'player' if event['actor'] == 0 else 'opponent',
                             'kind': HIT_KINDS[flags]})
            hits.sort(key=lambda hit: (hit['tick'], hit['target'] != 'player'))
            exchanges.append({
                'id': f"{COMMANDS[(outcome - 1) // 3]}__{COMMANDS[(outcome - 1) % 3]}",
                'player': COMMANDS[(outcome - 1) // 3],
                'opponent': COMMANDS[(outcome - 1) % 3],
                'updates': schedule['updates_to_quiescence'],
                'hits': hits,
            })
        duels.append({
            'id': DUEL_IDS[name],
            'fighters': fighters,
            'initial_opponent': initial_opponent(raw),
            'cues': cues,
            'round_pause_updates': 20,
            'defeat_prelude_updates': 120,
            'exchanges': exchanges,
            'provenance': {
                'disc_file': source.OVERLAY_DIR + name,
                'lba': source._rec(source.OVERLAY_DIR + name)['lba'],
                'size': len(raw),
                'sha256': hashlib.sha256(raw).hexdigest(),
                'decoder': 'ikki_animations.py paired static scheduler; direct MIPS combat consumer',
            },
        })
    return {
        'schema': SCHEMA,
        'target': 'Suikoden I US v1.1 / SLUS_002.92',
        'tick_unit': 'one duel update call',
        'commands': list(COMMANDS),
        'duels': duels,
        'entry_state': 'Campaign supplies the player snapshot. The duel overlay supplies the opponent snapshot.',
    }


def opponent_choice(roll):
    """0x80087898: one BIOS rand input, including its 32767 boundary."""
    if not 0 <= roll <= 32767:
        raise ValueError('BIOS rand outside 0..32767')
    return ((3 * roll) // 32767) % 3


def damage(target_hp, attacker_attack, target_defense, kind, roll):
    """Semantic form of the common damage consumer at overlay 0x80084634."""
    base = max(attacker_attack - target_defense, 1)
    amount = base + ((base // 100 * roll) % 10)
    if kind == 'defended':
        amount //= 2
    elif kind == 'desperate_success':
        amount = min(amount * 2, target_hp // 4)
    elif kind == 'desperate_failure':
        amount = min(amount, target_hp // 4)
    elif kind != 'normal':
        raise ValueError(f'unknown hit kind {kind}')
    return amount


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'game' / 'assets' / 'duels.json')
    args = parser.parse_args()
    report = extract()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(f"exported {len(report['duels'])} duels, {sum(len(d['exchanges']) for d in report['duels'])} exchanges -> {args.out}")


if __name__ == '__main__':
    main()
