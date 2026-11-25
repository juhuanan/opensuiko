#!/usr/bin/env python3
"""Export Commander programs and source art/profile/formation candidate bindings."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera
from export_first_room import ROOT, source
from export_physical_runes import stream
from export_physical_runes import merge_libraries
from export_unite_programs import animation_resource, compile_operations, program_schema

BASE = 0x80080000
BLOCKS = (
    (0xf00, 0x11b0, '2752f45ff3dd0df19e5b65870250cd8ddfa048f7143d7b9cd9277d22c6a267d1'),
    (0x11b0, 0x1374, 'b3260161d091bdf228403cf869b389d34e0a1bd900f039a0ba4a0ddeb43fafcd'),
    (0x1374, 0x145c, 'f63348ffba4c9ce686aac7acbef9d6ed3759115a93177c3044eb311bc87ecafe'),
    (0x145c, 0x14f4, '56418ca2dd6f5db0470738cdaab9502e563a335e2087467dc4997d206e68f993'),
    (0x14f4, 0x15b8, '1d87cde3d7119a1a66e20e7e0541713e78af21bb2a3c9e81d4f4d4b5e9c7b977'),
)


def combine(actors, plan=None):
    """Retain existing actors and add Commander callbacks to the current bundle."""
    if actors['schema'] not in ('suikoden-unite-actors/31', 'suikoden-unite-actors/32', 'suikoden-unite-actors/33', 'suikoden-unite-actors/34', 'suikoden-unite-actors/35', 'suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):
        raise ValueError('Commander orders need the complete shared actor library')
    plan = build() if plan is None else plan
    if actors.get('commander') not in (None, plan['binding']):
        raise ValueError('Conflicting Commander binding')
    result = copy.deepcopy(actors)
    merge_libraries(result, plan)
    result.update(schema='suikoden-unite-actors/'+str(max(32,int(actors['schema'].rsplit('/',1)[1]))), commander=plan['binding'])
    return result


def append_content(battle, actors, atlas):
    """Attach source Commander art/profile and whole qualified B formations."""
    from export_physical_runes import graphics
    from export_world_travel import battle_export, squirrel_knockout_ticks
    plan = build()
    combined = combine(actors, plan)
    identifier = plan['binding']['id']
    if any(row['id'] == identifier for row in battle['enemies']):
        raise ValueError('Commander profile already present')
    roots = [(identifier, plan['binding'][role+'_program']) for role in ('order', 'solo')]
    art, art_proof = graphics(combined, dict(resources=[plan['provenance']['resource']]),
        atlas, {identifier}, roots, existing_graphics=battle['unite_graphics'])
    graphic = art[0]
    existing = next((row for row in battle['unite_graphics'] if row['id'] == identifier and row.get('record') is None), None)
    if existing is None:
        battle['unite_graphics'].append(graphic)
    else:
        poses = {row['id']: row for row in existing['poses']}
        for pose in graphic['poses']:
            if pose['id'] in poses:
                current = poses[pose['id']]
                for key, value in pose.items():
                    current['ordinary' if key == 'sprite' and 'ordinary' in current else key] = value
            else:
                existing['poses'].append(pose)
    overlay = battle_export('b')
    profile = copy.deepcopy(next(row for row in overlay['enemies'] if row['id'] == identifier))
    raw, _ = source('/B_DATA.BIN')
    table = struct.unpack_from('<I', raw, plan['provenance']['record_source_offset']+40)[0]-BASE
    profile.update(action_policy='source_commander', knockout_ticks=squirrel_knockout_ticks(raw, table))
    for name in ('commander', 'commander_order'):
        profile.pop(name)
    resource = next(row for row in combined['animations']['resources'] if row['id'] == identifier)
    idle = next(clip for clip in resource['clips'] if clip['id'] == 0)['frames'][0]['pose']
    pose = next(row for row in graphic['poses'] if row['id'] == idle)['sprite']
    profile['sprite'] = copy.deepcopy(pose)
    profile['attack'] = [dict(pose=copy.deepcopy(pose), ticks=1, source_pose=idle)]
    battle['enemies'].append(profile)
    supported = {row['id'] for row in battle['enemies']}
    existing_ids = {row['id'] for row in battle['encounters']}
    formations = []
    for index, encounter in enumerate(overlay['encounters'], 1):
        key = 'area_b_'+str(index)
        if key in existing_ids or not set(encounter['enemies']) <= supported:
            continue
        encounter = copy.deepcopy(encounter)
        encounter['id'] = key
        battle['encounters'].append(encounter)
        formations.append(key)
    battle['schema'] = 'suikoden-battle-trial/'+str(max(36,int(battle['schema'].rsplit('/',1)[1])))
    actors.clear()
    actors.update(combined)
    return dict(component=plan['provenance'], graphics=art_proof, formations=formations,
        scope='Source Commander and whole qualified B diagnostic formations; original field placement, audio and media acceptance remain separate.')


def build():
    raw, origin = source('/B_DATA.BIN')
    pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - BASE
    directory = pointer(pointer(pointer(0) + 12))
    record = pointer(pointer(directory + 12) + 3 * 4)
    table = pointer(record + 40)
    section = pointer(record + 44)
    if (record, table, struct.unpack_from('<I', raw, record + 48)[0]) != (0x22208, 0x22248, BASE + 0xf00):
        raise ValueError('Commander record or script table changed')
    callbacks = []
    for first, last, digest in BLOCKS:
        if hashlib.sha256(raw[first:last]).hexdigest() != digest:
            raise ValueError('Commander callback changed')
        callbacks.append(dict(source=origin, source_offset=first, byte_length=last-first, sha256=digest))
    # The solo descriptor is selected by the decision callback, not a script-table slot.
    if struct.unpack_from('<2I', raw, 0x1148) != (0x3c06800a, 0x24c62374):
        raise ValueError('Commander solo descriptor reference changed')
    prefix = 'commander/beast_commander'
    programs = []; proofs = []; roots = []
    for role, offset in (('order', pointer(table + 4)), ('recipient', pointer(table + 8)), ('solo', 0x22374)):
        operations, spans = stream(raw, origin, offset, table, BASE)
        instructions, blocked, effects = compile_operations(operations, prefix, member_resource='beast_commander')
        if blocked or effects:
            raise ValueError('Unbound Commander actor program: ' + role)
        identifier = prefix + '/' + role
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=operations, spans=spans))
        roots.append(dict(script=role, operations=operations))
    _, main_origin = source('MAIN.EXE')
    _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table + BASE, BASE)
    if [(child['resource'], child['id'], child['source_offset']) for child in children] != [('member', 'member:5', 0x223b8)]:
        raise ValueError('Commander child dependency changed')
    for child in children:
        instructions, blocked, effects = compile_operations(child['operations'], prefix, member_resource='beast_commander')
        if blocked or effects:
            raise ValueError('Unbound Commander child program')
        identifier = prefix + '/auxiliary/' + child['id'].replace(':', '_')
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=child['operations'],
                           spans=[{key: child[key] for key in ('source', 'source_offset', 'byte_length', 'sha256')}]))
    selected = {0, 1, 3}
    for program in programs:
        for instruction in program['instructions']:
            command = instruction.get('command', {})
            if 'animation' in command:
                selected.add(command['animation'])
            if 'child' in command:
                selected.add(command['child']['animation'])
    resource, resource_proof = animation_resource('beast_commander', raw, origin, selected, section, BASE)
    binding = dict(id='beast_commander', order_program=prefix+'/order', solo_program=prefix+'/solo',
                   recipient_program=prefix+'/recipient', selection_delay=struct.unpack_from('<I', raw, 0x1340)[0] & 65535)
    return dict(schema='suikoden-enemy-orders/1', binding=binding,
        programs=dict(schema=program_schema(programs), programs=programs),
        animations=dict(schema='suikoden-actor-animations/1', resources=[resource]),
        provenance=dict(producer='export_enemy_orders.py v1', record_source_offset=record,
            source=origin, callbacks=callbacks, programs=proofs, resource=resource_proof,
            scope='Source scripts and actor resources. Battle controller, allies, art, audio and campaign admission remain separate.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'kit/work/build/enemy_orders/orders.json')
    args = parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.output.resolve(), *args.output.resolve().parents):
        raise ValueError('Enemy-order exports are candidates; accepted promotion is separate')
    packet = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(packet, separators=(',', ':')) + '\n')
    print(f'Exported {len(packet["programs"]["programs"])} Commander programs to {args.output}')
