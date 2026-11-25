#!/usr/bin/env python3
"""Batch the ordinary counter response, strike, hurt and return scripts from disc."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import shutil

import area_encounter_tables
import battle_bin
import battle_unite_camera
import character_table
from export_first_room import ROOT, source
from export_physical_runes import LATER_ENEMIES, recipient_resources, stream
from export_unite_programs import animation_resource, compile_operations, program_schema
import maindec
import preparation


def ordinary_selector_proof(raw, origin, callback):
    """Normalize relocated jumps and pin the complete shared front selector."""
    start=callback-area_encounter_tables.BASE
    if not 0<=start<=len(raw)-0x174:raise ValueError('ordinary selector outside source')
    body=bytearray(raw[start:start+0x174])
    for offset in range(0,len(body),4):
        word=struct.unpack_from('<I',body,offset)[0]
        if word>>26 not in (2,3):continue
        target=((callback+offset+4)&0xf0000000)|((word&0x3ffffff)<<2)
        relocated=target-callback+0x80080004
        struct.pack_into('<I',body,offset,(word&0xfc000000)|((relocated>>2)&0x3ffffff))
    if hashlib.sha256(body).hexdigest()!='9c901e462024912c44d42860ecfd768b3bfbde347e0242b65eac190d3ea1afd3':
        raise ValueError('ordinary selector changed')
    return dict(id='ordinary_selector',source=origin,source_offset=start,byte_length=len(body),
                sha256=hashlib.sha256(raw[start:start+len(body)]).hexdigest())


def build(include_area_a=True, include_later=False):
    programs = {}; proofs = {}; resources = {}; resource_proofs = []
    defenders = []; enemies = []; shared_animations = set()
    parry_attackers = []; parry_defenders = []; melee_enemies = []; party_reactions = []; melee_refusals = []
    party_capabilities = []; enemy_capabilities = []
    main, main_origin = source('MAIN.EXE')
    cooperation = None
    local_effects = {6: 'ally_throw', 9: 'fixed_projectile'}
    owner_effects = {}
    owner_callbacks = []
    ivy_report = None

    def add(identifier, raw, origin, offset, table, prefix, base=0):
        operations, spans = stream(raw, origin, offset, table, base)
        local = local_effects if prefix == 'melee/strong_arm' else owner_effects.get(prefix)
        instructions, blocked, effects = compile_operations(operations, prefix, local, prefix.rsplit('/', 1)[-1])
        if blocked or set(effects) - {'blue_afterimages', 'ally_throw', 'fixed_projectile', 'recipient_spin', 'crow_dive', 'ivy_vine'}:
            raise ValueError(f'unbound counter program {identifier}: {blocked or effects}')
        programs[identifier] = dict(id=identifier, instructions=instructions)
        proofs[identifier] = dict(id=identifier, spans=spans, operations=operations)
        return dict(operations=operations)

    def children(raw, origin, roots, prefix, table=None, base=0):
        _, dependencies = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table, base)
        for child in dependencies:
            identifier = prefix + '/auxiliary/' + child['id'].replace(':', '_')
            instructions, blocked, effects = compile_operations(child['operations'], prefix if child['resource'] == 'member' else None,
                local_effects if prefix == 'melee/strong_arm' else None, prefix.rsplit('/', 1)[-1])
            permitted = {'blue_afterimages', 'ally_throw', 'fixed_projectile'}
            if prefix == 'melee/kobold_type_2': permitted.add('aimed_projectile')
            if blocked or set(effects) - permitted:
                raise ValueError(f'unbound counter child {identifier}: {blocked or effects}')
            programs[identifier] = dict(id=identifier, instructions=instructions)
            proofs[identifier] = dict(id=identifier, operations=child['operations'],
                spans=[{key: child[key] for key in ('source', 'source_offset', 'byte_length', 'sha256')}])

    cover = {}
    for role, address in (('guard', 0x8016C270), ('ward', 0x8016C29C), ('return', 0x8016C2B4)):
        key = 'cover/' + role
        add(key, main, main_origin, maindec.EXE_HEADER + address - maindec.MBASE,
            0, 'cover', maindec.MBASE - maindec.EXE_HEADER)
        cover[role + '_program'] = key

    for record in character_table.records():
        weapon = maindec.mword(0x80165890 + 4 * record['weapon_id'])
        weapon_range = main[maindec.EXE_HEADER + weapon - maindec.MBASE + 0x56]
        if weapon_range not in (1, 2, 3):
            raise ValueError('unknown counter weapon range')
        identifier = preparation.stable_id(record['name'])
        party_capabilities.append(dict(id=identifier, source=main_origin,
            source_offset=maindec.EXE_HEADER + weapon - maindec.MBASE + 0x56, weapon_range=weapon_range))
        prefix = 'counter/' + identifier
        raw, origin = source('/' + record['sprite_file'])
        table = struct.unpack_from('<I', raw, 32)[0]
        binding = dict(id=identifier)
        roots = []
        for role, slot in ((('response', 3), ('strike', 5), ('hurt', 2)) if weapon_range & 1 else (('response', 3),)):
            key = prefix + '/' + role
            roots.append(dict(script=slot, **add(key, raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0], table, prefix)))
            binding[role + '_program'] = key
        children(raw, origin, roots, prefix)
        party_reactions.append(dict(id=identifier, response_program=binding['response_program']))
        parry_prefix = 'parry/' + identifier
        attacking = dict(id=identifier)
        attacking_roots = []
        for role, slot in ((('attack', 1), ('return', 4)) if weapon_range & 1 else ()):
            key = parry_prefix + '/' + role
            attacking_roots.append(dict(script=slot, **add(key, raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0], table, parry_prefix)))
            attacking[role + '_program'] = key
        children(raw, origin, attacking_roots, parry_prefix)
        if weapon_range & 1:
            parry_attackers.append(attacking)
        selected = {0, 1, 2, 5, 6}
        for program in programs.values():
            if not program['id'].startswith((prefix + '/', parry_prefix + '/')):
                continue
            for instruction in program['instructions']:
                command = instruction.get('command', {})
                if 'animation' in command:
                    selected.add(command['animation'])
        resource, proof = animation_resource(identifier, raw, origin, selected)
        resources[identifier] = resource
        proof['weapon_range'] = weapon_range
        resource_proofs.append(proof)
        if weapon_range & 1:
            defenders.append(binding)

    for _, original in recipient_resources(include_later):
        identifier = original['id']
        raw, origin = source('/' + original['source']['file'].split('/')[-1])
        record = original['record_source_offset']
        counterable = bool(struct.unpack_from('<H', raw, record + 0x26)[0] & 1)
        can_parry = bool(struct.unpack_from('<H', raw, record + 0x26)[0] & 2)
        callback = struct.unpack_from('<I', raw, record + 48)[0]
        ordinary_melee = (callback in (0x80080018, 0x80080490, 0x8008018C) and origin['file'].endswith('C_DATA.BIN')) or (
            include_area_a and (identifier, callback) in (('bonbon', 0x80080004), ('mosquito', 0x80080004), ('wild_boar', 0x80080760), ('crow', 0x80080604), ('red_soldier_ant', 0x80080ADC)) and origin['file'].endswith('A_DATA.BIN'))
        if include_later and identifier in {name for _,_,name in LATER_ENEMIES}:
            expected=next((region,native) for region,native,name in LATER_ENEMIES if name==identifier)
            if not origin['file'].endswith(expected[0].upper()+'_DATA.BIN') or original['local_enemy_id']!=expected[1]:
                raise ValueError('inconsistent later enemy identity')
            selector=ordinary_selector_proof(raw,origin,callback)
            selector['id']=identifier+'_ordinary_selector'
            owner_callbacks.append(selector)
            ordinary_melee=True
        if callback == 0x8008018C and identifier != 'kobold_type_2':
            raise ValueError('unexpected source archer callback')
        if callback == 0x80080490:
            from export_enemy_magic import SOURCE_BLOCKS
            first,last,digest = SOURCE_BLOCKS[1]
            if hashlib.sha256(raw[first-area_encounter_tables.BASE:last-area_encounter_tables.BASE]).hexdigest() != digest:
                raise ValueError('Kobold magic/ordinary decision changed')
        if ordinary_melee:
            table = struct.unpack_from('<I', raw, record + 40)[0] - area_encounter_tables.BASE
            if identifier in ('ivy', 'mad_ivy'):
                import enemy_ivy
                if ivy_report is None:ivy_report=enemy_ivy.build()
                actor=next(a for a in ivy_report['actors'] if a['id']==identifier)
                if actor['source']!=origin or actor['record_offset']!=record:raise ValueError('Ivy actor identity changed')
                owner_effects['melee/'+identifier]={9:'ivy_vine'}
                for index,block in enumerate(actor['blocks']):
                    owner_callbacks.append(dict(id=identifier+'_vine_'+str(index),source=origin,
                        source_offset=block['offset'],byte_length=block['size'],sha256=block['sha256']))
            if identifier == 'crow':
                if struct.unpack_from('<I',raw,table+20)[0] != 0x80080438:
                    raise ValueError('Crow dive callback changed')
                for role, start, end, digest in (
                    ('curve',0x178,0x438,'99e345f23ec200bfe1233263e159ed09504c501003e749a132e150d95960ddeb'),
                    ('dive',0x438,0x604,'efd64337f9b2e8ffebae233a7c68b46a215bac946707f1623ce8812905031cbf'),
                    ('selection',0x604,0x760,'f7b1c2b988290b84698e7ac73a31083e21497088dba0c96c7f34296bd65ca8b7')):
                    if hashlib.sha256(raw[start:end]).hexdigest() != digest:
                        raise ValueError('Crow dive callback changed')
                    owner_callbacks.append(dict(id='crow_'+role,source=origin,source_offset=start,
                                                byte_length=end-start,sha256=digest))
                owner_effects['melee/crow'] = {5:'crow_dive'}
            if identifier == 'wild_boar':
                digest = 'b4b9c71324c3c6ddc80c253a424a4937a1822aa2b6c07715b0c67d87c983395d'
                if struct.unpack_from('<I',raw,table+20)[0] != 0x800808d4 or hashlib.sha256(raw[0x8d4:0x950]).hexdigest() != digest:
                    raise ValueError('Wild boar recipient callback changed')
                owner_effects['melee/wild_boar'] = {(2,5): 'recipient_spin'}
                owner_callbacks.append(dict(id='wild_boar_recipient_spin',source=origin,
                    source_offset=0x8d4,byte_length=0x7c,sha256=digest))
            for slot in (1, 2, 4):
                operations, _ = stream(raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0] - area_encounter_tables.BASE, table, area_encounter_tables.BASE)
                _, blocked, effects = compile_operations(operations, 'melee/' + identifier, local_effects if identifier == 'strong_arm' else owner_effects.get('melee/' + identifier))
                if blocked or set(effects) - {'blue_afterimages', 'ally_throw', 'recipient_spin', 'crow_dive', 'ivy_vine'}:
                    unbound_local_effects=[]
                    for operation in operations:
                        if operation['op']==35 and (operation['args'][0]==1 or
                                (identifier=='wild_boar' and slot==2 and operation['args'][0]==2)):
                            index=operation['args'][1]
                            unbound_local_effects.append(dict(mode=operation['args'][0],slot=index,pointer_source_offset=table+4*index,
                                target=struct.unpack_from('<I',raw,table+4*index)[0]))
                    melee_refusals.append(dict(id=identifier, source=origin, script=slot, unsupported=blocked, effects=effects, local_effects=unbound_local_effects))
                    ordinary_melee = False
        enemy_capabilities.append(dict(id=identifier, source=origin, source_offset=record + 0x26,
            feature_bits=struct.unpack_from('<H', raw, record + 0x26)[0]))
        binding = dict(id=identifier, counterable=counterable, attack_program=None, return_program=None)
        if counterable or can_parry or ordinary_melee or identifier == 'kobold_type_2':
            base = area_encounter_tables.BASE
            table = struct.unpack_from('<I', raw, record + 40)[0] - base
            roots = []
            if counterable:
                prefix = 'counter/' + identifier
                for role, slot in (('attack', 1), ('return', 4)):
                    key = prefix + '/' + role
                    roots.append(dict(script=slot, **add(key, raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0] - base, table, prefix, base)))
                    binding[role + '_program'] = key
            if can_parry:
                prefix = 'parry/' + identifier
                guard = dict(id=identifier)
                guard_roots = []
                for role, slot in (('response', 3), ('strike', 5), ('hurt', 2)):
                    key = prefix + '/' + role
                    guard_roots.append(dict(script=slot, **add(key, raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0] - base, table, prefix, base)))
                    guard[role + '_program'] = key
                roots.extend(guard_roots)
                parry_defenders.append(guard)
            if any(op['op'] == 24 and op['args'][0] & 1 for root in roots for op in root['operations']):
                raise ValueError('counter enemy member child needs its relocated source binding')
            if can_parry:
                children(raw, origin, guard_roots, prefix)
            if ordinary_melee:
                prefix = 'melee/' + identifier
                melee = dict(id=identifier)
                if identifier in ('ivy', 'mad_ivy'):
                    art={a['role']:a for a in next(a for a in ivy_report['actors'] if a['id']==identifier)['art']}
                    melee['vine_art']=dict(strip=art['vine']['pose'],leaves=[art['leaf_even']['pose'],art['leaf_odd']['pose']],
                        leaf_extents=[art['leaf_even']['destination_extent'],art['leaf_odd']['destination_extent']])
                melee_roots = []
                for role, slot in (('attack', 1), ('hurt', 2), ('return', 4)):
                    key = prefix + '/' + role
                    melee_roots.append(dict(script=slot, **add(key, raw, origin, struct.unpack_from('<I', raw, table + 4 * slot)[0] - base, table, prefix, base)))
                    melee[role + '_program'] = key
                if identifier == 'red_soldier_ant':
                    special = {}
                    for role, address in (('attack', 0x800A5460), ('hurt', 0x800A5550)):
                        key = prefix + '/special_' + role
                        melee_roots.append(dict(script='special_' + role, **add(key, raw, origin, address - base, table, prefix, base)))
                        special[role + '_program'] = key
                    melee['special'] = special
                if identifier == 'strong_arm':
                    cooperation = dict(id=identifier, allies=['kobold_type_1', 'kobold_type_2', 'kobold_type_3', 'strong_arm'])
                    for role, address in (('fallback',0x800A5424),('approach',0x800A5528),('lift',0x800A555C),('launch',0x800A5578)):
                        key = prefix + '/' + role
                        melee_roots.append(dict(script=role, **add(key, raw, origin, address-base, table, prefix, base)))
                        cooperation[role + '_program'] = key
                children(raw, origin, melee_roots, prefix, table+base, base)
                roots.extend(melee_roots)
                melee_enemies.append(melee)
            selected = {0, 1}
            for root in roots:
                selected.update(op['args'][0] for op in root['operations'] if op['op'] == 4)
            for program in programs.values():
                if not program['id'].startswith('melee/' + identifier + '/'):
                    continue
                for instruction in program['instructions']:
                    command = instruction.get('command', {})
                    if 'animation' in command: selected.add(command['animation'])
                    if command.get('child', {}).get('resource') == identifier: selected.add(command['child']['animation'])
            if identifier in ('ivy', 'mad_ivy'):selected.update((10,11,12))
            resource, proof = animation_resource(identifier, raw, origin, selected,
                section=original['section_offset'], base=base,animation_table_end=original.get('animation_table_end'))
            proof.update(record_source_offset=record, counterable=counterable, can_parry=can_parry)
            resources[identifier] = resource
            resource_proofs.append(proof)
        enemies.append(binding)

    for program in programs.values():
        for instruction in program['instructions']:
            child = instruction.get('command', {}).get('child')
            if child and child['resource'] == 'shared_impacts':
                shared_animations.add(child['animation'])
    sections, _, errors, raw = battle_bin.parse(need_atlases=False)
    if errors:
        raise ValueError(errors)
    lba, size = battle_bin.battle_bin_lba()
    origin = dict(file=battle_bin.DISC_PATH, lba=lba, size=size, sha256=hashlib.sha256(raw).hexdigest())
    resource, proof = animation_resource('shared_impacts', raw, origin, shared_animations,
        section=sections[0]['header_offset'], base=battle_bin.LOAD_BASE)
    resources['shared_impacts'] = resource
    resource_proofs.append(proof)
    callbacks = []
    for role, start, end in (('response', 0x800F5DB4, 0x800F5E90),
                             ('strike', 0x800F5F98, 0x800F6030),
                             ('contact', 0x800F6030, 0x800F6118),
                             ('return', 0x800F5CD0, 0x800F5DB4),
                             ('ordinary_hit', 0x800F5960, 0x800F5ABC),
                             ('ordinary_miss', 0x800F5C1C, 0x800F5CD0)):
        offset = maindec.EXE_HEADER + start - maindec.MBASE
        callbacks.append(dict(id=role, source=main_origin, source_offset=offset,
            byte_length=end - start, sha256=hashlib.sha256(main[offset:offset + end - start]).hexdigest()))
    callbacks.extend(owner_callbacks)
    packet = dict(schema='suikoden-counter-actors/8' if include_area_a else 'suikoden-counter-actors/5',
        programs=dict(schema=program_schema(programs.values(),8), programs=[programs[key] for key in sorted(programs)]),
        animations=dict(schema='suikoden-actor-animations/1', resources=[resources[key] for key in sorted(resources)]),
        defenders=defenders, enemies=enemies, parries=dict(attackers=parry_attackers, defenders=parry_defenders),
        melee=dict(enemies=melee_enemies, party_reactions=party_reactions), cover=cover, cooperation=cooperation)
    raw, origin = source('/C_DATA.BIN')
    cooperation_proof = dict(source=origin, callbacks=[dict(address=a,source_offset=a-0x80080000,
        byte_length=b-a,sha256=hashlib.sha256(raw[a-0x80080000:b-0x80080000]).hexdigest())
        for a,b in ((0x80081050,0x80081250),(0x80081250,0x80081550))],
        callback_slots={6:0x80081250,9:0x80081050}, eligible_order='ascending enemy slots; other, active, byte flags zero',
        partner_turn='retained; opcode9 only sets completion when that actor is the current coordinator owner')
    proof = dict(schema='suikoden-counter-actors-proof/5', producer='export_counter_actors.py v17', status='candidate',cooperation=cooperation_proof,
        programs=[proofs[key] for key in sorted(proofs)], resources=resource_proofs, callbacks=callbacks,
        party_capabilities=party_capabilities, enemy_capabilities=enemy_capabilities, melee_refusals=melee_refusals,
        scope='Weapon-range-qualified party scripts3/5/2 and counterable A/B/C enemy scripts1/4; '
              'parry-qualified party scripts1/4 and enemy scripts3/5/2; source '
              + ('BonBon, Mosquito, Wild boar, Crow, Red Soldier Ant and ' if include_area_a else '') + 'C ordinary melee and archer scripts1/2/4 and all party dodge scripts3. '
              + ('Red Soldier Ant special attacker and recipient scripts are included. ' if include_area_a else '') +
              ('Qualified D/E/F/G/H/Z ordinary/counter/parry actors and Rabbit Bird\'s proven extended animation table are included. ' if include_later else '') +
              'The original attacker uses the counter striker\'s hurt script with its own animation resource. '
              'Common protector/ward/return descriptors use owner highlight-mask waits and all78 party resources. '
              'Source callbacks govern signal1, signal2, HP submission and signal4 return. '
              'Export does not grant canonical rune availability, live admission or media acceptance.')
    return packet, proof


def export(output):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('counter actor programs are candidates; promotion is separate')
    packet, proof = build()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'counter_actors.json').write_text(json.dumps(packet, separators=(',', ':')) + '\n')
    (output / 'provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
    return packet, proof


def combine(actors, counters):
    from export_physical_runes import merge_libraries
    if actors['schema'] != 'suikoden-unite-actors/11' or counters['schema'] not in ('suikoden-counter-actors/1', 'suikoden-counter-actors/2', 'suikoden-counter-actors/3', 'suikoden-counter-actors/4', 'suikoden-counter-actors/5', 'suikoden-counter-actors/8'):
        raise ValueError('unsupported counter library combination')
    result = copy.deepcopy(actors)
    merge_libraries(result, counters)
    result.update(schema='suikoden-unite-actors/12', counter=dict(
        defenders=copy.deepcopy(counters['defenders']), enemies=copy.deepcopy(counters['enemies'])))
    if 'parries' in counters:
        result['schema'] = 'suikoden-unite-actors/13'
        result['counter']['parries'] = copy.deepcopy(counters['parries'])
    if 'melee' in counters:
        result['schema'] = 'suikoden-unite-actors/14'
        result['counter']['melee'] = copy.deepcopy(counters['melee'])
    if 'cover' in counters:
        result['schema'] = 'suikoden-unite-actors/16'
        result['counter']['cover'] = copy.deepcopy(counters['cover'])
    if 'cooperation' in counters:
        result['schema'] = 'suikoden-unite-actors/18'
        result['counter']['cooperation'] = copy.deepcopy(counters['cooperation'])
    return result


def graphic_roots(packet):
    """Bind each donor hurt descriptor to the resource that actually receives it."""
    result = []
    for defender in packet['defenders']:
        result.extend((defender['id'], defender[role + '_program']) for role in ('response', 'strike'))
    for enemy in packet['enemies']:
        if enemy['counterable']:
            result.extend((enemy['id'], enemy[role + '_program']) for role in ('attack', 'return'))
    if 'parries' in packet:
        for attacker in packet['parries']['attackers']:
            result.extend((attacker['id'], attacker[role + '_program']) for role in ('attack', 'return'))
            for defender in packet['parries']['defenders']:
                result.append((attacker['id'], defender['hurt_program']))
        for defender in packet['parries']['defenders']:
            result.extend((defender['id'], defender[role + '_program']) for role in ('response', 'strike'))
    if 'melee' in packet:
        for recipient in packet['melee']['party_reactions']:
            result.append((recipient['id'], recipient['response_program']))
            for enemy in packet['melee']['enemies']:
                result.append((recipient['id'], enemy['hurt_program']))
                if 'special' in enemy:
                    result.append((recipient['id'], enemy['special']['hurt_program']))
        for enemy in packet['melee']['enemies']:
            result.extend((enemy['id'], enemy[role + '_program']) for role in ('attack', 'return'))
            if 'special' in enemy:
                result.append((enemy['id'], enemy['special']['attack_program']))
    if 'cover' in packet:
        for party in packet['melee']['party_reactions']:
            result.extend((party['id'], program) for program in packet['cover'].values())
    if 'cooperation' in packet:
        binding = packet['cooperation']
        result.append((binding['id'], binding['fallback_program']))
        for identifier in binding['allies']:
            result.extend((identifier, binding[role + '_program']) for role in ('approach', 'lift', 'launch'))
    return result


def export_parry_review(journey, output):
    """One authored review setup; source enemy stats/art do not grant a campaign encounter."""
    import export_world_travel
    journey = Path(journey)
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('parry review is a candidate; promotion is separate')
    content = json.loads((journey / 'battle/trial.json').read_text())
    actors = json.loads((journey / 'battle/unites.json').read_text())
    world = export_world_travel.battle_export('c')
    identifier = actors['counter']['parries']['defenders'][0]['id']
    enemy = copy.deepcopy(next(row for row in world['enemies'] if row['id'] == identifier))
    if identifier not in {row['id'] for row in actors['counter']['melee']['enemies']}:
        raise ValueError('parry review needs a bound source melee policy')
    content['schema'] = 'suikoden-battle-trial/29'
    content['protection'] = copy.deepcopy(world['protection'])
    enemy['action_policy'] = 'source_melee'
    resource = next(row for row in actors['animations']['resources'] if row['id'] == identifier)
    idle = next(row for row in resource['clips'] if row['id'] == 0)['frames'][0]['pose']
    graphic = next(row for row in content['unite_graphics'] if row['id'] == identifier)
    enemy['sprite'] = next(row for row in graphic['poses'] if row['id'] == idle)['sprite']
    enemy['attack'] = [dict(pose=enemy['sprite'], ticks=1, source_pose=idle)]
    content['enemies'].append(enemy)
    encounter = next(row for row in world['encounters'] if identifier in row['enemies'])
    index = encounter['enemies'].index(identifier)
    content['encounters'] = [dict(id='parry_review', title='Parry source actor review', enemies=[identifier],
        experience_per_member=0, positions=[encounter['positions'][index]], enemy_rows=[encounter['enemy_rows'][index]])]
    output.mkdir(parents=True, exist_ok=True)
    for filename in ('actors.png', 'floor.png', 'ground.png', 'unites.json', 'spells.json', 'spell_effects.png'):
        shutil.copyfile(journey / 'battle' / filename, output / filename)
    import export_spell_scenes
    export_spell_scenes.export(journey / 'battle', output, extra_hurt_ids=(identifier,))
    spell_proof = json.loads((output / 'provenance.json').read_text())
    (output / 'trial.json').write_text(json.dumps(content, separators=(',', ':')) + '\n')
    origin = json.loads((journey / 'battle/provenance.json').read_text())
    proof = dict(schema='suikoden-parry-review-proof/1', status='candidate',
        setup='Authored single-enemy review using source C enemy stats, placement and ordinary melee policy.',
        counter_actor_programs=origin['counter_actor_programs'], actor_graphics=origin['physical_graphics'],
        spell_art=spell_proof,
        native_launched=False, media_accepted=False, promoted=False)
    (output / 'provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
    filenames=('actors.png','floor.png','ground.png','unites.json','trial.json','spells.json','spell_effects.png','provenance.json')
    (output / 'manifest.json').write_text(json.dumps(dict(schema='suikoden-spell-review/1',status='candidate',
        files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in filenames}),indent=2)+'\n')
    return content, proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'kit/work/build/counter_actors')
    export(parser.parse_args().output)
