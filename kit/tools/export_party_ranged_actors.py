#!/usr/bin/env python3
"""Batch source party body attacks and ranged member-projectile families."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera
import battle_bin
import area_encounter_tables
import character_table
from export_first_room import ROOT, source
from export_physical_runes import recipient_resources, stream
from export_unite_programs import animation_resource, compile_operations, projectile_callbacks
import maindec
import preparation
from export_world_travel import critical_camera


def build(melee=False, include_later=False):
    main, main_origin = source('MAIN.EXE')
    if main[maindec.EXE_HEADER:] != maindec.body():
        raise ValueError('ranged actor MAIN image mismatch')
    programs, resources, bindings, proofs, excluded = {}, [], [], [], []
    for record in character_table.records():
        weapon = maindec.mword(0x80165890 + 4 * record['weapon_id'])
        offset = maindec.EXE_HEADER + weapon - maindec.MBASE + 0x56
        if not 0 <= offset < len(main):
            raise ValueError('weapon range outside MAIN image')
        if main[offset] not in (1,2,3):raise ValueError('unknown source weapon range')
        if not melee and main[offset] != 2:
            continue
        identifier = preparation.stable_id(record['name'])
        raw, origin = source('/' + record['sprite_file'])
        table = struct.unpack_from('<I', raw, 32)[0]
        prefix = ('party_melee/' if melee else 'ranged/') + identifier
        roots, source_programs = [], []
        for role, slot in (('attack', 1), ('return', 4)):
            address = struct.unpack_from('<I', raw, table + 4 * slot)[0]
            operations, spans = stream(raw, origin, address, table)
            instructions, blocked, effects = compile_operations(operations, prefix, member_resource=identifier)
            if blocked:
                raise ValueError(f'unbound ranged {identifier}/{role}: {blocked}')
            roots.append(dict(script=slot, operations=operations))
            source_programs.append(dict(id=prefix + '/' + role, instructions=instructions,
                                        spans=spans, operations=operations, effects=effects))
        _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table, 0)
        if melee and main[offset] == 2 and any(child['resource'] == 'member' for child in children):continue
        if not melee and not any(child['resource'] == 'member' for child in children):
            excluded.append(dict(id=identifier, reason='no member-projectile child in attack or return scripts'))
            continue
        supported_reactions = True
        for role, slot in (('hurt', 2), ('critical_hurt', 8)):
            address = struct.unpack_from('<I', raw, table + 4 * slot)[0]
            operations, spans = stream(raw, origin, address, table)
            instructions, blocked, effects = compile_operations(operations, prefix, member_resource=identifier)
            if blocked or effects:
                if melee and main[offset] == 2 and not blocked and set(effects) == {'palette_cycle'}:
                    excluded.append(dict(id=identifier,reason='non-projectile recipient palette cycle has no material binding',role=role,operations=operations,spans=spans))
                    supported_reactions = False
                    break
                raise ValueError(f'unbound ranged {identifier}/{role}: {blocked or effects}')
            roots.append(dict(script=slot, operations=operations))
            source_programs.append(dict(id=prefix + '/' + role, instructions=instructions,
                                        spans=spans, operations=operations, effects=effects))
        if not supported_reactions:continue
        _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table, 0)
        for child in children:
            if child['resource'] not in ('member', 'shared'):
                raise ValueError(f'unknown ranged child for {identifier}')
            instructions, blocked, effects = compile_operations(child['operations'],
                prefix if child['resource'] == 'member' else None, member_resource=identifier)
            if blocked or set(effects) - {'aimed_projectile', 'spinning_projectile'}:
                raise ValueError(f'unbound ranged child for {identifier}: {blocked or effects}')
            source_programs.append(dict(id=prefix + '/auxiliary/' + child['id'].replace(':', '_'),
                instructions=instructions, operations=child['operations'], effects=effects,
                spans=[{key: child[key] for key in ('source', 'source_offset', 'byte_length', 'sha256')}]))
        selected = {0}
        for program in source_programs:
            if program['id'].endswith(('/hurt', '/critical_hurt')) or '/auxiliary/shared_' in program['id']:
                continue
            for instruction in program['instructions']:
                command = instruction.get('command', {})
                if 'animation' in command:
                    selected.add(command['animation'])
                if 'child' in command:
                    if command['child']['resource'] != identifier:
                        raise ValueError('ranged child resource differs from owner')
                    selected.add(command['child']['animation'])
        resource, resource_proof = animation_resource(identifier, raw, origin, selected)
        resources.append(resource)
        for program in source_programs:
            key = program['id']
            if key in programs:
                raise ValueError('duplicate ranged program')
            programs[key] = dict(id=key, instructions=program['instructions'])
        bindings.append(dict(id=identifier, attack_program=prefix + '/attack', return_program=prefix + '/return', hurt_program=prefix + '/hurt', critical_hurt_program=prefix + '/critical_hurt'))
        proofs.append(dict(id=identifier, weapon_source=main_origin, weapon_range_offset=offset,
            resource=resource_proof, programs=[{key: value for key, value in row.items() if key != 'instructions'}
                                               for row in source_programs]))
    dodges, target_proofs = [], []
    for _, original in recipient_resources(include_later):
        raw, origin = source('/' + original['source']['file'].split('/')[-1])
        record = original['record_source_offset']
        if not struct.unpack_from('<H', raw, record + 0x26)[0] & 4:
            continue
        identifier = original['id']
        base = area_encounter_tables.BASE
        table = struct.unpack_from('<I', raw, record + 40)[0] - base
        address = struct.unpack_from('<I', raw, table + 12)[0] - base
        operations, spans = stream(raw, origin, address, table, base)
        key = ('party_melee/dodge/' if melee else 'ranged/dodge/') + identifier
        instructions, blocked, effects = compile_operations(operations, key, member_resource=identifier)
        if blocked or effects or (not melee and any('child' in row.get('command', {}) for row in instructions)):
            raise ValueError(f'unbound enemy dodge {identifier}: {blocked or effects}')
        if melee:
            _, dependencies = battle_unite_camera.auxiliary_scripts(raw, origin, [dict(script=3, operations=operations)], main_origin, table + base, base)
            for child in dependencies:
                code, blocked, effects = compile_operations(child['operations'], key if child['resource'] == 'member' else None, member_resource=identifier)
                if blocked or effects:raise ValueError(f'unbound enemy dodge child {identifier}: {blocked or effects}')
                child_id = key + '/auxiliary/' + child['id'].replace(':', '_')
                programs[child_id] = dict(id=child_id, instructions=code)
        selected = {0, 1} | {row['command']['animation'] for row in instructions
                          if 'animation' in row.get('command', {})}
        resource, resource_proof = animation_resource(identifier, raw, origin, selected,
            section=original['section_offset'], base=base)
        resources.append(resource)
        programs[key] = dict(id=key, instructions=instructions)
        dodges.append(dict(id=identifier, response_program=key))
        target_proofs.append(dict(id=identifier, resource=resource_proof, operations=operations, spans=spans,
                                  capability_source_offset=record + 0x26))
        if melee:target_proofs[-1]['children']=dependencies
    shared = {instruction['command']['child']['animation'] for program in programs.values()
              for instruction in program['instructions']
              if instruction.get('command', {}).get('child', {}).get('resource') == 'shared_impacts'}
    sections, _, errors, raw = battle_bin.parse(need_atlases=False)
    if errors:
        raise ValueError(errors)
    lba, size = battle_bin.battle_bin_lba()
    origin = dict(file=battle_bin.DISC_PATH, lba=lba, size=size, sha256=hashlib.sha256(raw).hexdigest())
    section = sections[0]
    table = section['tables']['f']
    pose_end = min(struct.unpack_from('<I', raw, table + 4 * index)[0] - battle_bin.LOAD_BASE
                   for index in range(section['b_f_count']))
    if (section['a_e_count'], pose_end - section['tables']['e']) != (82, 98 * 4):
        raise ValueError('shared critical impact pose-table extent changed')
    resource, shared_proof = animation_resource('shared_impacts', raw, origin, shared,
        section=section['header_offset'], base=battle_bin.LOAD_BASE, pose_table_end=pose_end)
    resources.append(resource)
    packet = dict(schema='suikoden-party-melee-actors/1' if melee else 'suikoden-party-ranged-actors/1',
                  programs=dict(schema='suikoden-actor-programs/8', programs=[programs[key] for key in sorted(programs)]),
                  animations=dict(schema='suikoden-actor-animations/1', resources=sorted(resources, key=lambda row: row['id'])),
                  bindings=sorted(bindings, key=lambda row: row['id']), critical_camera=critical_camera(),
                  dodges=sorted(dodges, key=lambda row: row['id']))
    proof = dict(schema='suikoden-party-melee-actors-proof/1' if melee else 'suikoden-party-ranged-actors-proof/1', status='candidate',
                 callbacks=projectile_callbacks(), characters=proofs, targets=target_proofs, excluded=excluded, shared=shared_proof,
                 scope='Source member attack, return, projectile and ordinary/critical target hurt scripts and selected animation metadata. '
                       'Gameplay admission, rendering and media acceptance remain separate.')
    if melee:
        blocks=((0x800f4834,0x800f491c,'7417f24adf42f0b9b17c56c41fc1db755a52fcef6717773d3781178ec309d744'),
                (0x800f5960,0x800f5abc,'2771f25a7922a48e9c123054851c58b2c7f5760a0f81ecf827bf2d57f34f91c5'),
                (0x800f5abc,0x800f5c1c,'0ecf1756e867628d12a71f3b1697404f4dcbe7b3c8a452b017a10e6a7c241120'),
                (0x800f5c1c,0x800f5cd0,'1ebb8d5a8071c007bf00389ab0781beec5239ad69aca8d6ed08c623f3532a7a6'),
                (0x800f5cd0,0x800f5db4,'d2d57199dfcdb4c0657b05d1e26ead50d03a32099a6d5efeea46107ea96cfe53'))
        proof['ordinary_callbacks']=[]
        for first,last,digest in blocks:
            offset=maindec.EXE_HEADER+first-maindec.MBASE
            if hashlib.sha256(main[offset:offset+last-first]).hexdigest()!=digest:raise ValueError('ordinary party callback changed')
            proof['ordinary_callbacks'].append(dict(source=main_origin,source_offset=offset,byte_length=last-first,sha256=digest))
        proof['scope']='Source melee-style and non-projectile long attack/return, attacker-owned normal/critical recipient descriptors, source enemy dodges and shared children; ordinary callback windows are pinned. Runtime, rendering and media acceptance require their own checks.'
    return packet, proof


def export(output):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('ranged actors are candidates; promotion is separate')
    packet, proof = build()
    output.mkdir(parents=True, exist_ok=True)
    for name, value in (('ranged_actors.json', packet), ('provenance.json', proof)):
        (output / name).write_text(json.dumps(value, indent=2) + '\n')
    return packet, proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    packet, proof = export(args.out)
    print(f"{len(packet['bindings'])} ranged actors; {len(proof['excluded'])} different long-range action families")
