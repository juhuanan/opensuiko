#!/usr/bin/env python3
"""Batch named actor instructions, retaining dynamic waits instead of flattening clocks."""
import argparse
import json
import hashlib
import struct
from pathlib import Path

import battle_unite_camera as source
import character_table
import preparation
import journey_battle
import maindec
import battle_bin

ROOT = Path(__file__).resolve().parents[2]


def actor_pool():
    ranges=((0x800E5E60,0x800E5EDC,'70f1e7c1538af0bc3684183c74c83f80a2876217eba11f718bfe8174ecbc96e0'),
            (0x800E0D5C,0x800E0E64,'5272a1c28b0d1197974d911afdf04d808a7044fee7cf9f3ddfdd347d1a44097b'))
    blocks=[]
    for start,end,digest in ranges:
        if hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest()!=digest:
            raise ValueError('Unite actor pool or auxiliary sweep changed')
        blocks.append(dict(address=start,size=end-start,sha256=digest))
    return dict(blocks=blocks,usable_actor_slots=19,
                auxiliary_capacity='19 minus combatant count',allocation='descending',
                sweep='ascending after all combatants; newborns in later slots run this update')


def actor_graphics():
    start,end=0x800E6D38,0x800E7468
    digest='966184d6c5472725da1a01378af65a1e1b60591be3ecc326f4d73c103dba416c'
    if hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest()!=digest:
        raise ValueError('Unite auxiliary graphic writer changed')
    return dict(address=start,size=end-start,sha256=digest,corner_extents='raw width/height bytes',
                rotation='own draw angles when record flag4; otherwise camera XY and Z360',
                local_translation=[0,0,1024],local_scale='battle scene scale',
                scope='One-piece child textures and normal secondary quads; vertical flag2 and mixed per-pixel blending remain unbound')


def program_schema(programs, legacy=7):
    version=legacy
    for program in programs:
        for instruction in program['instructions']:
            command=instruction.get('command',{})
            if 'hold_coordinator_dispatch' in command or 'tail_return' in command:version=max(version,13)
            if 'color' in command:version=max(version,12)
            if 'resume_motion' in command:version=max(version,9)
            if 'status' in command:
                version=max(version,11 if command['status']['kind'] in ('balloon','sleep') else 10)
    return f'suikoden-actor-programs/{version}'


def compile_operations(operations, member=None, local_effects=None, member_resource=None):
    instructions = []
    unsupported = []
    effects = set()
    anchors = ('absolute', 'self', 'owner', 'home')
    for index, row in enumerate(operations):
        if instructions and instructions[-1] == dict(halt={}):
            unsupported.append(dict(operation=index, reason='instructions after terminal'))
            break
        op, args = row['op'], row['args']
        command = None
        if op in (0, 1):
            instructions.append(dict(halt={}))
        elif op == 2:
            instructions.extend([dict(command=dict(teardown={})), dict(halt={})])
        elif op == 3 and 0 <= args[0] <= 32767:
            instructions.append(dict(delay=args[0]))
        elif op == 4:
            command = dict(animation=args[0])
        elif (op == 42 and len(args) == 4 and args[0] == 3 and 0 <= args[2] <= 4 and 1 <= args[3] <= 1000
              and next((item['args'] for item in operations[index+1:] if item['op'] in (35,42)),None) == [0,13]):
            command = dict(palette_cycle=dict(variants=list(range(args[2],args[2]+3)),updates=args[3]))
        elif op == 6:
            command = dict(translucent=bool(args[0] & 255))
        elif op == 8:
            command = dict(visible=bool(args[0]))
        elif op in (5, 21):
            instructions.append(dict(wait={('animation_done' if op == 5 else 'movement_done'): {}}))
        elif op == 23 and args[0] in range(4) and 2 <= args[1] <= 1000:
            velocity = args[5:] if op == 23 else (0, 0, 0)
            command = dict(motion=dict(anchor=anchors[args[0]], updates=args[1], offset=args[2:5], velocity_q12=[v*2048 for v in velocity]))
        elif op == 33 and args[0] in range(4) and args[1] <= 1000:
            command = dict(motion=dict(anchor=anchors[args[0]], updates=max(1,args[1]), offset=args[2:5], velocity_q12=[0,0,0], kind='snap' if args[1] <= 0 else 'linear'))
        elif op == 22 and 1 <= args[0] <= 1000:
            command = dict(motion=dict(anchor='home', updates=args[0], offset=[0,0,0], velocity_q12=[0,0,0], kind='linear'))
        elif op == 37 and member == 'melee/wild_boar' and args == [10]:
            command = dict(resume_motion=args[0])
        elif op == 24 and member is not None and not args[0] & ~15 and args[1] >= 0 and args[2] >= 0:
            flags, animation, script, *offset = args
            kind = 'member' if flags & 1 else 'shared'
            command = dict(child=dict(program=f'{member}/auxiliary/{kind}_{script}', resource=(member_resource or member) if flags & 1 else 'shared_impacts',
                animation=animation, owner='owner' if flags & 4 else 'self',
                home='parent_owner' if flags & 8 else 'spawn', draw_record=bool(flags & 2), offset=offset))
        elif op in (26, 27, 28, 29) and args[0] in (0, 1):
            mask = dict(target='self' if args[0] == 0 else 'owner', bits=args[1] & 65535)
            key = 'signal_set' if op in (26, 28) else 'signal_clear'
            if op in (28, 29): instructions.append(dict(wait={key: mask}))
            else: command = {key: mask}
        elif op in (30, 31):
            if op == 31: instructions.append(dict(wait=dict(shared_value=args[0])))
            else: command = dict(shared_value=args[0])
        elif op in (13, 14):
            command = dict(record_flags=dict(bits=args[0] & 255, set=op == 13))
        elif op in (15, 16) and args[0] in (0, 1):
            command = dict(highlight=dict(target='owner' if args[0] == 1 else 'self', bits=args[1] & 255, set=op == 15))
        elif op == 44 and args[0] in (0, 1) and 0 <= args[1] <= 255:
            instructions.append(dict(wait=dict(highlight_clear=dict(target='owner' if args[0] else 'self', bits=args[1]))))
        elif op == 9 and args == [0]:
            command = dict(release_actor=True)
        elif op == 9 and args == [5] and member is not None:
            command = dict(hold_coordinator_dispatch=True)
        elif op == 36 and args == [4] and member is not None:
            instructions.extend([dict(command=dict(tail_return=True)), dict(halt={})])
        elif op == 40 and args == [7,100]:
            command = dict(recovery=2)
        elif op == 40 and args[0] in (0,1,4,5,6) and 0 <= args[1] <= 100:
            command = dict(status=dict(kind={0:'poison',1:'balloon',4:'accuracy_reduced',5:'sleep',6:'rune_blocked'}[args[0]],threshold_percent=args[1]))
        elif op == 34 and args[0] >= 0:
            command = dict(sound=args[0])
        elif op == 35 and args[0] == 1 and local_effects and args[1] in local_effects:
            identifier = local_effects[args[1]]
            effects.add(identifier)
            command = dict(effect=dict(id=identifier, binding='self'))
        elif op == 35 and args[0] == 2 and local_effects and (2,args[1]) in local_effects:
            identifier = local_effects[(2,args[1])]
            effects.add(identifier)
            command = dict(effect=dict(id=identifier, binding='owner'))
        elif op == 35 and args[0] == 0 and args[1] >= 0:
            identifier = {1:'aimed_projectile',2:'spinning_projectile',4:'blue_afterimages',8:'airborne_recipient',10:'decoy_retaliation',13:'palette_cycle'}.get(args[1],f'unbound_shared_actor_effect_{args[1]}')
            effects.add(identifier)
            command = dict(effect=dict(id=identifier, binding='shared'))
        elif op in (38, 39):
            command = dict(reset_draw=op == 39)
        elif op == 41 and len(args) == 3 and all(isinstance(v,int) and not isinstance(v,bool) and -32768 <= v <= 65535 for v in args):
            command = dict(color=[v & 255 for v in args])
        elif op == 43 and args[0] in range(3):
            command = dict(offsets=dict(anchor=anchors[args[0]], value=args[1:3]))
        elif op == 25 and args[0] in (0, 1, 2):
            command = dict(offsets=dict(anchor='owner' if args[0] == 2 else 'absolute', value=args[1:3] if args[0] == 1 else [0, 0], from_sprite=args[0] == 2, immediate=True))
        elif op in (17, 18, 19) and 0 < args[0] <= 1000:
            command = dict(camera=dict(channel={17:'angles',18:'translation',19:'scale'}[op], updates=args[0], value_q12=[v*4096 for v in args[1:]]))
        elif op == 20 and args[0] in range(3) and 0 < args[1] <= 1000:
            command = dict(camera=dict(channel='focus', anchor=anchors[args[0]], updates=args[1], value_q12=args[2:4]+[args[4] if args[0] == 0 else 0]))
        else:
            unsupported.append(dict(operation=index, opcode=op, operands=args))
        if command is not None:
            instructions.append(dict(command=command))
    if not instructions or instructions[-1] != dict(halt={}):
        unsupported.append(dict(reason='missing terminal instruction'))
    return (None if unsupported else instructions), unsupported, sorted(effects)


def animation_resource(identifier, raw, origin, selected, section=None, base=0, pose_table_end=None, animation_table_end=None):
    section = struct.unpack_from('<I',raw,36)[0] if section is None else section
    animations, flags, _ = source.animation_frames(raw, section=section, base=base, animation_table_end=animation_table_end)
    pose_count = struct.unpack_from('<H',raw,section)[0]
    entries = struct.unpack_from('<I',raw,section+16)[0]-base
    declared_pose_count = pose_count
    if pose_table_end is not None:
        if not entries + 4 * pose_count <= pose_table_end <= len(raw) or (pose_table_end - entries) % 4 or (pose_table_end - entries) // 4 > 256:
            raise ValueError(f'Invalid proven pose table extent in {identifier}')
        pose_count = (pose_table_end - entries) // 4
    if pose_count == 0 or not 0 <= entries <= len(raw)-4*pose_count:
        raise ValueError(f'Invalid pose table in {identifier}')
    clips = []
    for index in sorted(selected):
        if not 0 <= index < len(animations): raise ValueError(f'Unbound animation in {identifier}:{index}')
        frames = []
        for pose, updates in animations[index]:
            if pose >= pose_count: raise ValueError(f'Unbound animation pose in {identifier}:{index}')
            entry = struct.unpack_from('<I',raw,entries+pose*4)[0]-base
            if not 0 <= entry <= len(raw)-8: raise ValueError(f'Invalid pose header in {identifier}:{pose}')
            frames.append(dict(pose=pose,updates=updates or 256,attachment=[raw[entry+6]-raw[entry+4],raw[entry+7]-raw[entry+5]]))
        clips.append(dict(id=index,advances=bool(flags[index]&1),loop=bool(flags[index]&2),semitransparent=bool(flags[index]&4),frames=frames))
    proof = dict(id=identifier,source=origin,section_offset=section,pointer_base=base,animations=sorted(selected))
    if pose_table_end is not None:
        proof.update(declared_pose_count=declared_pose_count,pose_table_end=pose_table_end)
    if animation_table_end is not None:
        proof.update(declared_animation_count=struct.unpack_from('<H',raw,section+2)[0],animation_table_end=animation_table_end)
    return dict(id=identifier,pose_count=pose_count,clips=clips), proof



def projectile_callbacks():
    rows = []
    for identifier, slot, start, end, expected in (
        ('aimed_projectile',1,0x800F0B24,0x800F0DAC,'af93df1f116dd99020cbcc6c2e7ebdc5cd130297027856c050f464b1ba45232c'),
        ('spinning_projectile',2,0x800F0DAC,0x800F1018,'0f18456e58dedd3b5bf867b6e09a405e6314926d4ad393b07d7efbc74a96e435')):
        data = maindec.body()[start-maindec.MBASE:end-maindec.MBASE]
        if maindec.mword(0x8016BB70+4*slot) != start or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f'Projectile callback changed: {identifier}')
        rows.append(dict(id=identifier,source='MAIN.EXE',lba=maindec.EXE_LBA,address=start,size=len(data),sha256=expected))
    return rows


def export(output, include_flash=False, include_master=False, include_couple=False, include_warriors=False, include_martial=False, include_beat=False, include_trick=False):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('Actor programs are candidates; accepted promotion is separate')
    names = {row['id']: preparation.stable_id(row['name']) for row in character_table.records()}
    definitions, proofs, unites = {}, {}, []
    requested = {}
    catalogue = json.loads(source.CATALOGUE.read_text())['records']
    rows = source.report()
    for row in rows:
        members = []
        for member in row['member_scripts']:
            prefix = names[member['id']]
            request = requested.setdefault(member['id'], dict(id=prefix, source=member['source'], animations={0}))
            ids = []
            streams = [(f'{prefix}/unite_{s["script"]}', s) for s in member['scripts']]
            streams += [(f'{prefix}/auxiliary/{s["id"].replace(":", "_")}', s) for s in member['auxiliary_scripts']]
            for identifier, stream in streams:
                if stream.get('resource', 'member') == 'member':
                    request['animations'].update(item['args'][0] for item in stream['operations'] if item['op'] == 4)
                    request['animations'].update(item['args'][1] for item in stream['operations'] if item['op'] == 24 and item['args'][0] & 1)
                instructions, blocked, effects = compile_operations(stream['operations'], prefix if stream.get('resource', 'member') == 'member' else None)
                proof = dict(id=identifier, source=stream.get('source', member['source']), source_offset=stream['source_offset'],
                    byte_length=stream['byte_length'], sha256=stream['sha256'], unsupported=blocked, host_effects=effects)
                if identifier in proofs and proofs[identifier] != proof:
                    raise ValueError(f'Inconsistent actor program {identifier}')
                proofs[identifier] = proof
                if instructions is not None:
                    definitions[identifier] = dict(id=identifier, instructions=instructions)
                if '/auxiliary/' not in identifier: ids.append(identifier)
            members.append(dict(id=prefix, programs=ids))
        returning = catalogue[row['index']]['recovery_source'].get('return_script')
        if (include_master and row['index'] == 31) or (include_martial and row['index'] == 29) or (include_trick and row['index'] == 14):
            returning = 0x8016D214
        if include_warriors and row['index'] == 15:
            returning = row['controller_research']['returns']['program']
        if returning is not None:
            selected = {args[0] for op,args in journey_battle.script_at(maindec.body(),returning-maindec.MBASE) if op == 4}
            for member in row['member_scripts']: requested[member['id']]['animations'].update(selected)
        unites.append(dict(record=row['index'], name=row['name'], members=members,
                           return_program={0x8016D214:'common/unite_return',0x8016D258:'common/fisherman_return',None:None}[returning]))
        if include_trick and row['index'] == 14:
            import unite_trick_controller
            trick = unite_trick_controller.build()
            unites[-1].update(dispatch_after=1,wave_heights=trick['phases'][1]['heights'])
            for member in members:member['entry_program']=member['programs'][0]
            requested[39]['animations'].add(19)
        if include_flash and row['index'] == 10:
            unites[-1].update(dispatch_after=row['primary_startup']['first_actor_sweep'],
                controller=dict(mode='owner_clock',return_at=192,vfx='flash',trigger_member=0,signal=16,
                                recipient_at=0,recipient_variant=0,recipient_rolls=[],damage_at=161,cleanup_at=193))
        if include_master and row['index'] == 31:
            schedule = row['sweep_research']
            unites[-1]['dispatch_after'] = schedule['startup']['first_actor_sweep']
            for entry in schedule['entries']:
                member = members[entry['member']]
                member['entry_program'] = f"{member['id']}/unite_{entry['setup']}"
                member['loop_program'] = f"{member['id']}/unite_{entry['strike']}"
        if include_couple and row['index'] == 16:
            contract = row['controller_research']
            if [member['id'] for member in row['member_scripts']] != [0, 30]:
                raise ValueError('Couple members changed')
            for member, script in zip(members, (11, 9), strict=True):
                member['entry_program'] = f"{member['id']}/unite_{script}"
            trigger, damage = contract['trigger'], contract['damage']
            unites[-1].update(dispatch_after=1, damage_member=damage['member'], impact_effect=damage['start_impact_animation'],
                transition=dict(trigger_member=trigger['member'], signal=trigger['signal'], dispatches=[dict(
                    member=trigger['starts_member'], program=f"{members[trigger['starts_member']]['id']}/unite_{trigger['script']}")]))
        if include_warriors and row['index'] == 15:
            import export_spell_scenes
            contract = row['controller_research']
            phases, trigger, recipient, motion = contract['phases'], contract['trigger'], contract['recipient'], contract['motion']
            hold, travel, recovery = (phase['updates'] for phase in phases)
            unites[-1].update(dispatch_after=1, controller=dict(mode='orbit', vfx='warriors',
                trigger_member=trigger['member'], signal=trigger['signal'],
                recipient_at=hold + recipient['age'] + 1, recipient_variant=1, recipient_rolls=[],
                damage_at=hold + travel + recovery, cleanup_at=hold + travel + recovery + 1,
                orbit=dict(anchor_member=motion['anchor_member'], hold_updates=hold, divisor=motion['divisor'], base_z_q12=motion['base_z_q12'],
                    heights_q12=[motion['sine_amplitude']*export_spell_scenes.effect_sine(age*motion['sine_step']) for age in range(travel)],
                    sounds=[dict(at=1,id=phases[0]['start_sound']),
                            dict(at=hold+1,id=phases[1]['start_sound']),
                            dict(at=hold+recipient['age']+1,id=phases[1]['impact_sound'])])))
        if 'scene_controller' in row:
            contract=row['scene_controller']['contract']
            import export_spell_scenes
            from battle_drops import trunc
            phase_lengths=[phase['updates'] for phase in contract['phases']]
            unites[-1].update(dispatch_after=1,controller=dict(vfx=row['scene_controller']['id'],
                trigger_member=contract['trigger']['member'],signal=contract['trigger']['signal'],
                recipient_at=phase_lengths[0]+1,recipient_variant=1,
                recipient_rolls=[trunc(export_spell_scenes.effect_sine(age*64),16) for age in range(phase_lengths[1])],
                damage_at=sum(phase_lengths[:3]),cleanup_at=sum(phase_lengths)))
        if 'family_schedule' in row:
            schedule=row['family_schedule']
            unites[-1].update(dispatch_after=schedule['startup']['first_actor_sweep'],damage_target_signal=schedule['damage_target_signal'])
        if 'phase_schedule' in row:
            phase=row['phase_schedule']
            for entry in phase['entries']:
                member=members[entry['member']]
                member['entry_program']=f"{member['id']}/unite_{entry['script']}"
                if entry.get('deferred_entry'):member['deferred_entry']=True
                if entry.get('start_after'):member['start_after']=entry['start_after']
            transition=phase['transition']
            unites[-1]['transition']=dict(trigger_member=transition['trigger_member'],signal=transition['signal'],
                dispatches=[dict(member=d['member'],program=f"{members[d['member']]['id']}/unite_{d['script']}") for d in transition['dispatches']])
            unites[-1]['embedded_returns']=phase['embedded_returns']
            if phase['admission']=='native_vm_scene_bound_visual_acceptance_pending':unites[-1]['dispatch_after']=phase['startup']['first_actor_sweep']
            if 'assist' in phase:
                variant=phase['assist'].get('variant',1)
                members[phase['assist']['member']].update(reaction_on_hit=True)
                if variant:members[phase['assist']['member']]['reaction_variant']=variant
            if 'damage_target_signal' in phase:unites[-1]['damage_target_signal']=phase['damage_target_signal']
            if 'damage_member' in phase:unites[-1].update(damage_member=phase['damage_member'],damage_signal=phase['damage_signal'])
        if 'group_schedule' in row:
            schedule=row['group_schedule']
            unites[-1]['dispatch_after']=schedule['startup']['first_actor_sweep']
            unites[-1]['damage_member']=schedule['damage_member']
            members[schedule['assist_member']].update(reaction_on_hit=True,reaction_group=True)
            for member,fan in zip(row['member_scripts'],schedule['fans'],strict=True):
                requested[member['id']]['animations'].add(fan['animation'])
                members[fan['member']]['fan']=dict(animation=fan['animation'],rolls=fan['rolls'],node_angles=fan['node_angles'],velocity_q12=fan['velocity_q12'][0],anchor_z=fan['anchor_z'],signal=fan['trigger_signal'])
        if 'primary_startup' in row and row['index'] not in source.STARTUP_ONLY_RECORDS:
            unites[-1]['dispatch_after']=row['primary_startup']['first_actor_sweep']
        elif row['callback_schedule'] is not None:
            schedule=row['callback_schedule']
            unites[-1]['dispatch_after']=schedule['startup']['first_callback']
            assists={item['member'] for item in schedule['assists']}
            for member,dispatch in zip(members,schedule['dispatches'],strict=True):
                if dispatch['callback_counter']:member['start_after']=dispatch['callback_counter']
                if dispatch['member'] in assists:member['reaction_on_hit']=True
        if row['target_reaction']['binding']['kind']=='null_shared_helper_reaction':unites[-1]['damage_reaction']=False
        if 'direct_assists' in row:
            if row['direct_assists']['after_damage']:unites[-1]['assist_after_damage']=True
            for assist in row['direct_assists']['assists']:
                member=members[assist['member']]
                member.update(reaction_on_hit=True,reaction_variant=assist['variant'])
                if 'hit_camera' in assist:member['hit_camera']=assist['hit_camera']
    if include_martial:
        import unite_martial_controller
        martial = unite_martial_controller.actor_programs()
        contract = unite_martial_controller.build()
        binding = unites[29]
        finish = contract['finish']
        binding.update(dispatch_after=1, damage_reaction=False,
                       target_queue=dict(recipient_return=finish['recipient_return_counter'],
                                         damage=finish['damage_counter'], cleanup=finish['cleanup_counter']))
        for member, stage, source_member, resource in zip(binding['members'], martial['bindings'], contract['members'], martial['animations']['resources'], strict=True):
            if member['id'] != stage['id'] or resource['id'] != member['id']:
                raise ValueError('Martial arts actor identity changed')
            member.update(programs=[stage['setup'], stage['strike']], entry_program=stage['setup'], loop_program=stage['strike'])
            requested[source_member['id']]['animations'].update(clip['id'] for clip in resource['clips'])
            for name, origin in ((stage['setup'], source_member['scripts'][0]), (stage['strike'], martial['borrowed_strike'])):
                program = next(p for p in martial['programs']['programs'] if p['id'] == name)
                definitions[name] = program
                proofs[name] = dict(id=name, source=origin.get('source', contract['members'][0]['source'] if name == stage['strike'] else source_member['source']),
                                    source_offset=origin['source_offset'], byte_length=origin['byte_length'], sha256=origin['sha256'],
                                    unsupported=[], host_effects=[])
    if include_beat:
        import unite_beat_controller
        beat = unite_beat_controller.actor_programs()
        beat_contract = beat['source']
        binding = unites[27]
        binding.update(dispatch_after=1, return_program=None, embedded_returns=True,
                       damage_member=1, beat_child=beat['child'],
                       transition=dict(trigger_member=0,signal=16,dispatches=[dict(member=1,program=beat['members'][1]['followup'])]))
        for member, stage, source_member, resource in zip(binding['members'], beat['members'], beat_contract['members'], beat['animations']['resources'], strict=True):
            if member['id'] != stage['id'] or member['id'] != resource['id']:
                raise ValueError('Beat em up actor identity changed')
            stages=[('entry',source_member['entry'])]
            if 'followup' in stage:stages.append(('followup',source_member['followup']))
            member.update(programs=[stage[key] for key,_ in stages],entry_program=stage['entry'])
            if source_member['id']==6:member.update(reaction_on_hit=True,reaction_variant=1)
            requested[source_member['id']]['animations'].update(clip['id'] for clip in resource['clips'])
            if source_member['id']==13:stages.append(('child',beat_contract['child']['script']))
            for key, origin in stages:
                name=beat['child']['program'] if key=='child' else stage[key]
                definitions[name]=next(p for p in beat['programs']['programs'] if p['id']==name)
                proofs[name]=dict(id=name,source=origin['source'],source_offset=origin['source_offset'],
                                  byte_length=origin['byte_length'],sha256=origin['sha256'],unsupported=[],host_effects=[])
    _, main_source = source.field.source('MAIN.EXE')
    body = maindec.body()
    for address, identifier in ((0x8016D214,'common/unite_return'),(0x8016D258,'common/fisherman_return')):
        operations = [dict(op=op,args=list(args)) for op,args in journey_battle.script_at(body,address-maindec.MBASE)]
        instructions, blocked, effects = compile_operations(operations)
        length = sum(2+2*len(row['args']) for row in operations)
        offset = address-maindec.MBASE
        proofs[identifier] = dict(id=identifier, source=main_source, source_offset=offset+maindec.EXE_HEADER,
            byte_length=length, sha256=hashlib.sha256(body[offset:offset+length]).hexdigest(), unsupported=blocked,host_effects=effects)
        if instructions is not None: definitions[identifier] = dict(id=identifier,instructions=instructions)
    resources, resource_proof = [], []
    for native_id, request in sorted(requested.items()):
        raw, origin = source.field.source('/'+request['source']['file'].split('/')[-1])
        resource, origin = animation_resource(request['id'], raw, origin, request['animations'])
        resources.append(resource)
        resource_proof.append(origin)
    shared = {instruction['command']['child']['animation'] for program in definitions.values()
              for instruction in program['instructions'] if 'child' in instruction.get('command',{})
              and instruction['command']['child']['resource'] == 'shared_impacts'}
    if shared:
        sections, _, errors, raw = battle_bin.parse(need_atlases=False)
        if errors: raise ValueError(errors)
        lba, size = battle_bin.battle_bin_lba()
        origin = dict(file=battle_bin.DISC_PATH,lba=lba,size=size,sha256=hashlib.sha256(raw).hexdigest())
        resource, origin = animation_resource('shared_impacts',raw,origin,shared,
            section=sections[0]['header_offset'],base=battle_bin.LOAD_BASE)
        resources.append(resource)
        resource_proof.append(origin)
    output.mkdir(parents=True, exist_ok=True)
    packet = dict(schema=program_schema(definitions.values()), programs=[definitions[k] for k in sorted(definitions)])
    proof = dict(schema='suikoden-actor-programs-proof/1', producer='export_unite_programs.py v32' if include_trick else 'export_unite_programs.py v31' if include_beat else 'export_unite_programs.py v30' if include_martial else 'export_unite_programs.py v29', status='candidate',
        actor_effects=projectile_callbacks(), actor_pool=actor_pool(), actor_graphics=actor_graphics(),
        scene_controllers=[dict(record=row['index'],**row['scene_controller']) for row in rows if 'scene_controller' in row],
        family_controllers=[dict(record=row['index'],**row['family_schedule']) for row in rows if 'family_schedule' in row],
        phase_controllers=[dict(record=row['index'],**row['phase_schedule']) for row in rows if 'phase_schedule' in row], unites=unites, programs=[proofs[k] for k in sorted(proofs)], resources=resource_proof,
        group_controllers=[dict(record=row['index'],**row['group_schedule']) for row in rows if 'group_schedule' in row],
        pending_linked_controllers=[dict(record=row['index'],**row['controller_research']) for row in rows if (row['index'] == 15 and not include_warriors) or (row['index'] == 16 and not include_couple)],
        scope='Twenty-five records have live candidate schedules, including all three Wild Arrow group controllers and Lepant Family. Other initializer families, KO, audio, overlapping actions and visual acceptance remain unfinished.')
    if include_flash:
        proof['flash_controller']=rows[10]['controller_research']
        proof['scope']='Twenty-six records have candidate schedules including Flash. KO, audio, overlapping actions and visual acceptance remain unfinished.'
    if include_master:
        proof['master_pupil_controller'] = rows[31]['sweep_research']
        proof['scope'] = 'Candidate schedules include Master pupil; KO, audio, overlapping actions and visual acceptance remain unfinished.'
    if include_couple:
        proof['couple_controller'] = rows[16]['controller_research']
        proof['scope'] = 'Candidate schedules include Couple; KO, audio, overlapping actions and visual acceptance remain unfinished.'
    if include_warriors:
        proof['warriors_controller'] = rows[15]['controller_research']
        proof['scope'] = 'Candidate schedules include Warriors; KO, audio, overlapping actions and visual acceptance remain unfinished.'
    if include_martial:
        proof['martial_controller'] = contract
        proof['scope'] = 'Candidate schedules include Martial arts; KO, overlap and human media acceptance remain unfinished.'
    if include_beat:
        proof['beat_controller'] = beat_contract
        proof['scope'] = 'Candidate actor bindings include Beat em up; battle art, package integration, KO, overlap and human media acceptance remain unfinished.'
    if include_trick:
        proof['trick_controller'] = trick
        proof['scope'] = 'Candidate bindings include Trick; battle rendering, KO/overlap and human media acceptance remain unfinished.'
    (output / 'programs.json').write_text(json.dumps(packet, indent=2)+'\n')
    (output / 'animations.json').write_text(json.dumps(dict(schema='suikoden-actor-animations/1',resources=resources),indent=2)+'\n')
    bundle = dict(schema='suikoden-unite-actors/29' if include_trick else 'suikoden-unite-actors/28' if include_beat else 'suikoden-unite-actors/27' if include_martial else 'suikoden-unite-actors/26' if include_warriors else 'suikoden-unite-actors/24' if include_couple else 'suikoden-unite-actors/23' if include_master else 'suikoden-unite-actors/22' if include_flash else 'suikoden-unite-actors/10',programs=packet,animations=dict(schema='suikoden-actor-animations/1',resources=resources),unites=unites)
    (output / 'unites.json').write_text(json.dumps(bundle,separators=(',',':'))+'\n')
    (output / 'provenance.json').write_text(json.dumps(proof, indent=2)+'\n')
    return packet, proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/unite_programs')
    packet, proof = export(parser.parse_args().out)
    print(f"{len(packet['programs'])} instruction programs; {sum(bool(p['unsupported']) for p in proof['programs'])} blocked programs; all {len(proof['unites'])} records inventoried")
