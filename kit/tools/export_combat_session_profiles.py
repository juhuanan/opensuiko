#!/usr/bin/env python3
"""Build a private six-member combat profile/atlas candidate from B and D facts."""
import argparse
from collections import Counter
import hashlib
import json
import re
from pathlib import Path
import struct

import character_table
import export_battle_trial as trial
from export_first_room import Atlas, ROOT, source
import item_tables
import maindec
import preparation


def build(party, magic, ids, output, bindings=None, party_sha256=None, bindings_sha256=None):
    output = output.resolve()
    if (ROOT / 'kit/work/accepted').resolve() in (output, *output.parents):
        raise ValueError('candidate export cannot write accepted content')
    if party['schema'] != 'suikoden-party-source-facts/1' or len(party['characters']) != 78:
        raise ValueError('invalid B source catalogue')
    if len(ids) == 0 or len(ids) > 6 or len(set(ids)) != len(ids):
        raise ValueError('select one to six distinct members')
    by_id = {row['id']: row for row in party['characters']}
    if len(by_id) != 78 or any(name not in by_id for name in ids):
        raise ValueError('unknown or duplicate source identity')
    if magic.get('schema') != 'suikoden-magic-actions-catalogue/1':
        raise ValueError('invalid D magic catalogue')
    if not bindings or bindings.get('schema') != 'suikoden-magic-ownership-bindings/1' or bindings.get('roster_content_sha256') != party_sha256 or not bindings_sha256:
        raise ValueError('missing or mismatched D ownership bindings')
    runes = {row['name']: row['key'] for row in magic['runes']}
    if len(runes) != len(magic['runes']) or len(set(runes.values())) != len(runes):
        raise ValueError('duplicate magic rune identity')
    records = {row['id']: row for row in character_table.records()}
    atlas = Atlas()
    profiles, unsupported = [], []
    for name in ids:
        row = by_id[name]
        seed = row['seed']
        if any(value is None for value in seed['weapon']['names']):
            unsupported.append(dict(id=name, reason='unresolved_weapon_name'))
            continue
        ted = bindings['ted']
        is_masked_ted = (name == ted['character_id'] and row['source_character_id'] == ted['source_character_id'] and seed['rune_source_id'] == ted['source_rune_id'] and seed['rune_locked'] and ted['locked'])
        if (seed['rune_unresolved'] and not is_masked_ted) or (seed['rune_name'] is not None and seed['rune_name'] not in runes):
            unsupported.append(dict(id=name, reason='unresolved_named_rune'))
            continue
        try:
            native = records[row['source_character_id']]
            data, provenance = source('/' + row['resource'])
            if hashlib.sha256(data).hexdigest() != row['resource_sha256']:
                raise ValueError('source_resource_digest_mismatch')
            poses, animations, proof = trial.section_art(data, struct.unpack_from('<I', data, 36)[0])
            frames, motion = trial.attack_schedule(data, poses, animations, atlas)
            idle = poses[animations[0][0][0]]
            pointer = maindec.mword(0x80165890 + 4 * native['weapon_id'])
            range_code = maindec.body()[pointer - maindec.MBASE + 0x56]
            weapon = dict(initial_level=seed['weapon']['level'], names=seed['weapon']['names'],
                          powers=seed['weapon']['powers'],
                          upgrade_costs=[maindec.mword(0x8016AF2C + 4 * i) for i in range(16)])
            stats = seed['stats']
            profile = dict(id=name, name=row['name'], max_hp=seed['max_hp'], level=seed['level'],
                           stats=dict(attack=stats[0] + weapon['powers'][weapon['initial_level'] - 1],
                                      skill=stats[1], defense=stats[2], speed=stats[3], magic=stats[4], luck=stats[5]),
                           growth=row['growth'], rune_locked=seed['rune_locked'],
                           rune=ted['rune_id'] if is_masked_ted else runes.get(seed['rune_name']), weapon=weapon,
                           weapon_range={1: 'short', 2: 'long', 3: 'medium'}[range_code],
                           sprite=trial.pack_pose(atlas, idle), foot_offset_y=trial.foot_offset_y(idle),
                           attack=frames, motion=motion)
            dependency = 'masked_rune_32_requires_integrator_rune_capacity_and_locked_load' if is_masked_ted else None
            profiles.append(dict(profile=profile, required_dependency=dependency, resource=row['resource'], resource_sha256=row['resource_sha256'],
                                 resource_provenance=provenance, sprite_proof=proof))
        except (ValueError, KeyError, IndexError, struct.error) as exc:
            unsupported.append(dict(id=name, reason=str(exc)))
    if not profiles:
        raise ValueError('no selected member has complete proven profile and art: ' + repr(unsupported))
    source_items = item_tables.items()
    counts = Counter(preparation.stable_id(row['name']) for row in source_items if row['name'])
    equipment = []
    for item in source_items:
        flags = item_tables.half(item['addr'] + 28)
        if not flags & 0x80 or not item['name']:
            continue
        name = preparation.stable_id(item['name'])
        key = f'{name}__source_{item["id"]}' if counts[name] > 1 else name
        kind = {0x80: 'head', 0xa0: 'body', 0xc0: 'shield', 0xe0: 'accessory'}[flags & 0xe0]
        allowed = [p['profile']['id'] for p in profiles if key in by_id[p['profile']['id']]['allowed_equipment']]
        equipment.append(dict(id=key, name=item['name'], category=kind,
                              bonuses=list(struct.unpack_from('<8b', maindec.body(), item['addr'] - maindec.MBASE + 32)),
                              allowed_members=allowed))
    output.mkdir(parents=True, exist_ok=True)
    atlas.save(output / 'actors.png')
    result = dict(schema='suikoden-combat-profile-candidate/1', atlas='actors.png',
                  atlas_sha256=hashlib.sha256((output / 'actors.png').read_bytes()).hexdigest(), profiles=profiles,
                  equipment=equipment, weapon_pieces=bindings['pieces'], unsupported=unsupported,
                  catalogue_sha256=hashlib.sha256(json.dumps(party, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                  magic_catalogue_sha256=hashlib.sha256(json.dumps(magic, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                  ownership_bindings_sha256=bindings_sha256,
                  status='candidate resources; human media review and host composition pending')
    profile_bytes = (json.dumps(result, indent=2) + '\n').encode()
    (output / 'profiles.json').write_bytes(profile_bytes)
    (output / 'profiles.sha256').write_text(hashlib.sha256(profile_bytes).hexdigest() + '\n')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--party', type=Path, required=True)
    parser.add_argument('--magic', type=Path, required=True)
    parser.add_argument('--bindings', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all', action='store_true', help='export each source-qualified member into a separate candidate atlas')
    parser.add_argument('ids', nargs='*')
    args = parser.parse_args()
    party_bytes = args.party.read_bytes()
    binding_bytes = args.bindings.read_bytes()
    party = json.loads(party_bytes)
    magic = json.loads(args.magic.read_text())
    bindings = json.loads(binding_bytes)
    party_sha256 = hashlib.sha256(party_bytes).hexdigest()
    bindings_sha256 = hashlib.sha256(binding_bytes).hexdigest()
    output = args.output.resolve()
    if (ROOT / 'kit/work/accepted').resolve() in (output, *output.parents):
        raise ValueError('candidate export cannot write accepted content')
    if party.get('schema') != 'suikoden-party-source-facts/1' or len(party.get('characters', [])) != 78:
        raise ValueError('invalid B source catalogue')
    ids = [row['id'] for row in party['characters']]
    if len(set(ids)) != 78 or any(not re.fullmatch(r'[a-z0-9_]+', name) for name in ids):
        raise ValueError('invalid B character identities')
    if magic.get('schema') != 'suikoden-magic-actions-catalogue/1':
        raise ValueError('invalid D magic catalogue')
    if bindings.get('schema') != 'suikoden-magic-ownership-bindings/1' or bindings.get('roster_content_sha256') != party_sha256:
        raise ValueError('missing or mismatched D ownership bindings')
    if args.all:
        if args.ids:
            parser.error('--all cannot be combined with member IDs')
        rows = []
        for character in party['characters']:
            name, seed = character['id'], character['seed']
            if any(value is None for value in seed['weapon']['names']):
                rows.append(dict(id=name, status='unsupported', reason='unresolved_weapon_name'))
                continue
            try:
                result = build(party, magic, [name], args.output / name, bindings, party_sha256, bindings_sha256)
                item = result['profiles'][0]
                rows.append(dict(id=name, status='candidate_requires_dependency' if item['required_dependency'] else 'candidate',
                                 required_dependency=item['required_dependency'], atlas=f'{name}/actors.png',
                                 profiles=f'{name}/profiles.json', resource_sha256=item['resource_sha256']))
            except (ValueError, KeyError, IndexError, struct.error) as exc:
                rows.append(dict(id=name, status='unsupported', reason=str(exc)))
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'manifest.json').write_text(json.dumps(dict(schema='suikoden-combat-profile-set/1', members=rows), indent=2) + '\n')
        print('candidate profiles:', sum(row['status'].startswith('candidate') for row in rows), 'of', len(rows))
        print('guarded or unsupported:', [row for row in rows if row['status'] != 'candidate'])
    else:
        if not args.ids:
            parser.error('provide member IDs or --all')
        result = build(party, magic, args.ids, args.output, bindings, party_sha256, bindings_sha256)
        print('profiles:', ', '.join(p['profile']['id'] for p in result['profiles']))
        print('unsupported:', result['unsupported'])


if __name__ == '__main__':
    main()
