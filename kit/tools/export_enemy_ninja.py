"""Static Ninja Master ordinary/special actors; live AI admission is separate."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera
from export_first_room import ROOT, source
from export_physical_runes import stream
from export_unite_programs import animation_resource, compile_operations, program_schema, projectile_callbacks

BASE = 0x80080000
BLOCKS = (
    (0x178, 0x364, 'e0c73966a838b21b03fcb4f1d64b4c9a3d7cab04d420515b3b9fa1c1bbc09c29'),
    (0x364, 0x570, 'b844256cab6e9f7e023d015aaed488e9c50584dc7c7d25d31b0fe954be24f58e'),
)


def combine(actors, plan=None):
    """Merge qualified Ninja callbacks without admitting a battle profile."""
    from export_physical_runes import merge_libraries
    if actors['schema'] not in ('suikoden-unite-actors/34', 'suikoden-unite-actors/35', 'suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):
        raise ValueError('Ninja Master needs the complete shared actor library')
    plan = build() if plan is None else plan
    result = copy.deepcopy(actors)
    merge_libraries(result, plan)
    for rows, binding in (
        (result['counter']['enemies'], plan['capability']),
        (result['counter']['melee']['enemies'], plan['melee']),
        (result['counter']['parries']['defenders'], plan['defender']),
        (result['counter']['ranged']['dodges'], dict(id='ninja_master', response_program=plan['defender']['response_program'])),
        (result['counter']['party_melee']['dodges'], dict(id='ninja_master', response_program=plan['defender']['response_program'])),
    ):
        previous = next((row for row in rows if row['id'] == 'ninja_master'), None)
        if previous is None:
            rows.append(copy.deepcopy(binding))
        elif previous != binding:
            raise ValueError('Conflicting Ninja Master binding')
    result['schema'] = 'suikoden-unite-actors/'+str(max(35,int(actors['schema'].rsplit('/',1)[1])))
    return result


def append_content(battle, actors, atlas):
    """Add source Ninja art/profile and every complete qualified Z formation."""
    import journey_battle
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks
    if any(row['id']=='ninja_master' for row in battle['enemies']):
        raise ValueError('Ninja Master profile already present')
    plan=build(); combined=combine(actors,plan)
    roots=[('ninja_master',binding[key]) for binding in (plan['ordinary'],plan['special'],plan['defender'])
           for key in binding if key.endswith('_program')]
    art,proof=graphics(combined,dict(resources=[plan['provenance']['resource']]),atlas,{'ninja_master'},roots,
                       existing_graphics=battle['unite_graphics'])
    battle['unite_graphics'].extend(art)
    catalogue=journey_battle.append_later_enemies(battle,atlas,(('z',1,'ninja_master'),))
    profile=battle['enemies'][-1]
    raw,_=source('/Z_DATA.BIN'); record=plan['provenance']['record_source_offset']
    table=struct.unpack_from('<I',raw,record+40)[0]-BASE
    profile.update(action_policy='source_ninja',knockout_ticks=squirrel_knockout_ticks(raw,table),
                   effect_offset=list(struct.unpack_from('<2h',raw,record+60)))
    resource=next(r for r in combined['animations']['resources'] if r['id']=='ninja_master')
    idle=next(c for c in resource['clips'] if c['id']==0)['frames'][0]['pose']
    pose=next(p for p in art[0]['poses'] if p['id']==idle)['sprite']
    profile['sprite']=copy.deepcopy(pose)
    profile['attack']=[dict(pose=copy.deepcopy(pose),ticks=1,source_pose=idle)]
    battle['schema']='suikoden-battle-trial/'+str(max(38,int(battle['schema'].rsplit('/',1)[1])))
    actors.clear();actors.update(combined)
    return dict(component=plan['provenance'],graphics=proof,catalogue=catalogue,
                scope='Source Ninja and whole qualified Z diagnostic formations; field placement, audio and media acceptance remain separate.')


def build():
    raw, origin = source('/Z_DATA.BIN')
    pointer = lambda offset: struct.unpack_from('<I', raw, offset)[0] - BASE
    directory = pointer(pointer(pointer(0) + 12))
    record = pointer(pointer(directory + 12) + 4)
    table, section = pointer(record + 40), pointer(record + 44)
    if (record, table, section, pointer(record + 48), struct.unpack_from('<H', raw, record+38)[0]) != (0x20788, 0x207c8, 0x20d20, 0x178, 2):
        raise ValueError('Ninja Master record, scripts or decision changed')
    blocks = []
    for first, last, digest in BLOCKS:
        if hashlib.sha256(raw[first:last]).hexdigest() != digest:
            raise ValueError('Ninja Master decision or special callback changed')
        blocks.append(dict(source=origin, source_offset=first, byte_length=last-first, sha256=digest))
    programs = []; proofs = []; roots = []; selected = {0, 1}
    ordinary = dict(id='ninja_master'); special = dict(id='ninja_master')
    defender = dict(id='ninja_master')
    for binding, role, offset in (
        (ordinary, 'attack', pointer(table + 4)),
        (ordinary, 'hurt', pointer(table + 8)),
        (ordinary, 'return', pointer(table + 16)),
        (special, 'owner', 0x207e8),
        (special, 'recipient', 0x208d4),
        (special, 'return', 0x20a9c),
        (defender, 'response', pointer(table + 12)),
        (defender, 'strike', pointer(table + 20)),
    ):
        operations, spans = stream(raw, origin, offset, table, BASE)
        instructions, blocked, effects = compile_operations(operations, 'melee/ninja_master', member_resource='ninja_master')
        if blocked or set(effects) - {'blue_afterimages'}:
            raise ValueError('Unbound Ninja Master actor: ' + role)
        family = 'ordinary' if binding is ordinary else 'special' if binding is special else 'defense'
        identifier = 'melee/ninja_master/' + family + '/' + role
        binding[role + '_program'] = identifier
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=operations, spans=spans))
        roots.append(dict(script=identifier, operations=operations))
        for instruction in instructions:
            command = instruction.get('command', {})
            if 'animation' in command:
                selected.add(command['animation'])
            if 'child' in command and command['child']['resource'] == 'ninja_master':
                selected.add(command['child']['animation'])
    _, main_origin = source('MAIN.EXE')
    _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table + BASE, BASE)
    for child in children:
        member = child['resource'] == 'member'
        instructions, blocked, effects = compile_operations(child['operations'], 'melee/ninja_master' if member else None,
                                                            member_resource='ninja_master' if member else None)
        allowed = {'aimed_projectile'} if child['id'] == 'member:6' else set()
        if blocked or set(effects) - allowed:
            raise ValueError('Unbound Ninja Master child')
        identifier = 'melee/ninja_master/auxiliary/' + child['id'].replace(':', '_')
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=child['operations'],
                           spans=[{key: child[key] for key in ('source', 'source_offset', 'byte_length', 'sha256')}]))
        if member:
            selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command', {}))
    resource, resource_proof = animation_resource('ninja_master', raw, origin, selected, section, BASE)
    defender['hurt_program'] = ordinary['hurt_program']
    melee = dict(ordinary, special=dict(attack_program=special['owner_program'], hurt_program=special['recipient_program'],
        return_program=special['return_program'], damage_numerator=3, damage_denominator=2))
    return dict(schema='suikoden-enemy-ninja/2', ordinary=ordinary, special=special, melee=melee,
        defender=defender, capability=dict(id='ninja_master', counterable=False, attack_program=None, return_program=None),
        decision=dict(target_policy='front_first', secondary_scale=100, secondary_divisor=32767,
                      secondary_threshold=51),
        impact=dict(damage_numerator=3, damage_denominator=2, contact_signal=2, return_signal=4),
        programs=dict(schema=program_schema(programs), programs=programs),
        animations=dict(schema='suikoden-actor-animations/1', resources=[resource]),
        provenance=dict(producer='export_enemy_ninja.py v2', source=origin,
            record_source_offset=record, callbacks=blocks, projectile_callbacks=projectile_callbacks(),
            programs=proofs, resource=resource_proof,
            scope='Source actor component, with shared MAIN impact dependencies. Live decision, signal/HP coordinator, art, camera, sound and formation admission remain separate.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'kit/work/build/enemy_ninja/actors.json')
    args = parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.output.resolve(), *args.output.resolve().parents):
        raise ValueError('Ninja Master exports are candidates; accepted promotion is separate')
    packet = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(packet, indent=2) + '\n')
    print(args.output)
