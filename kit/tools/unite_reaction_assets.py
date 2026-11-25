#!/usr/bin/env python3
"""Export shared Unite impact art from the disc; no native windows or promotion."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

import battle_bin
import battle_unite_camera
import export_battle_trial
from export_first_room import Atlas

ROOT = Path(__file__).resolve().parents[2]
VERSION = 'unite-reaction-assets/15'


def reaction_rows(rows):
    for row in rows:
        yield row
        for variant in row.get('direct_assists',{}).get('variants',[]):
            yield dict(index=row['index'],variant=variant['variant'],target_reaction=variant['reaction'])
        if 'scene_controller' in row:
            yield dict(index=row['index'],variant=1,target_reaction=row['scene_controller']['recipient_source'])
        if row['index'] == 15:
            yield dict(index=row['index'],variant=1,target_reaction=row['controller_research']['recipient'])
        if 'assist' in row.get('phase_schedule',{}):
            yield dict(index=row['index'],variant=1,target_reaction=row['phase_schedule']['assist'])


def reactions(rows, *, lock_handoffs=((17, 1, 2),), include_sounds=False, inherited_locks=()):
    """Lower descriptor behavior into named events, retaining callback blockers."""
    programs = []
    handoffs = set()
    pending_locks = set(inherited_locks)
    for row in reaction_rows(rows):
        source = row['target_reaction']
        if 'operations' not in source:
            continue
        key = row['index']
        handoff = any(key == record and row.get('variant') == second for record, _, second in lock_handoffs) and key in handoffs
        if handoff:
            handoffs.remove(key)
        program = dict(record=row['index'], duration=source['local_timing']['duration']-1,
                       poses=[], white=[], offsets=[], motions=[], impacts=[], blocker=None)
        cycle = None
        inherited = (key,row.get('variant',0)) in pending_locks
        if inherited:pending_locks.remove((key,row.get('variant',0)))
        acquired = held = handoff or inherited
        for op,tick in zip(source['operations'],source['local_timing']['operation_ticks'],strict=True):
            if op['op'] not in (15,16) or op['args'][0]!=0 or not op['args'][1]&8:continue
            at=max(0,tick-1)
            if op['op']==15:
                if at!=0:raise ValueError('Unbound recipient lock interval')
                acquired=held=True
            else:
                if held and at!=program['duration']:raise ValueError('Unbound recipient lock release')
                held=False
        if held:
            if any(key == record and row.get('variant') == first for record, first, _ in lock_handoffs) and key not in handoffs:
                handoffs.add(key)
                program['retain_lock']=True
            else:
                raise ValueError('Unreleased recipient lock')
        if not acquired:program['locks_target']=False
        if row.get('variant'):program['variant']=row['variant']
        binding=source.get('recipient_binding')
        if binding:
            program['flip']=dict(start=binding['flip']['start']-1,stop=binding['flip']['stop']-1)
            program['focus_z_pulses']=[dict(at=p['at']-1,delta_q12=p['delta_q12'][2]) for p in binding['camera_pulses']]
        for op, tick in zip(source['operations'], source['local_timing']['operation_ticks'], strict=True):
            at = max(0, tick-1)
            code, args = op['op'], op['args']
            if code==35 and binding and args==[0,8]:
                continue
            elif code == 42 and len(args)==4 and args[:2]==[3,0] and args[2] in (1,4) and 1<=args[3]<=1000:
                if row['index']==30 and row.get('variant')==2 and not any(other['op']==35 for other in source['operations']):
                    continue
                if cycle is not None:raise ValueError('Multiple recipient palette cycles are unbound')
                cycle = dict(row=args[2],period=args[3])
            elif code == 35 and args == [0,13] and cycle is not None and 'start' not in cycle:
                cycle['start'] = at
            elif code == 30 and args == [99] and cycle is not None and 'start' in cycle and 'stop' not in cycle:
                cycle['stop'] = at
            elif code == 33 and len(args)==5 and args[0]==3:
                _, updates, x, y, z = args
                program['motions'].append(dict(at=at, updates=max(1,updates), home=True,
                    linear=True, offset_q12=[v*4096 for v in (x,y,z)],
                    velocity_q12=[0]*3, linear_offset=True))
            elif code in (33,35,42):
                program['blocker'] = 'callback-owned reaction motion/animation'
            elif code == 4:
                program['poses'].append(dict(at=at, animation=args[0]))
            elif code == 34 and include_sounds:
                if len(args)!=1 or not 0<=args[0]<=65535:raise ValueError('Unbound recipient sound request')
                program.setdefault('sounds',[]).append(dict(at=at,id=args[0]))
            elif code in (38,39):
                program['white'].append(dict(at=at, enabled=code==38))
            elif code == 41:
                if len(args)!=3 or any(not 0<=value<=255 for value in args):raise ValueError('Unbound recipient colour')
                program.setdefault('colors',[]).append(dict(at=at,rgb=args))
            elif code == 40:
                if args[0]!=5 or not 0<=args[1]<=100:raise ValueError('Unbound recipient status attempt')
                program.setdefault('status_attempts',[]).append(dict(at=at,kind='enemy_sleep',failure_percent=args[1]))
            elif code in (26,27):
                if len(args)!=2 or args[0]!=0 or not -32768<=args[1]<=65535 or args[1]==0:
                    raise ValueError('Unbound recipient signal')
                program.setdefault('signals',[]).append(dict(at=at,bits=args[1]&65535,set=code==26))
            elif code == 25:
                if args[0] != 1:
                    raise ValueError('Unbound recipient screen-offset mode')
                program['offsets'].append(dict(at=at, offset=args[1:]))
            elif code == 23:
                mode, updates, x,y,z, vx,vy,vz = args
                if mode not in (0,1,3) or updates < 2:
                    raise ValueError('Unbound recipient jump binding')
                program['motions'].append(dict(at=at, updates=updates, home=mode==3,
                    linear=False, offset_q12=[v*4096 for v in (x,y,z)],
                    velocity_q12=[v*2048 for v in (vx,vy,vz)]))
                if mode==0:program['motions'][-1]['absolute']=True
            elif code == 22:
                program['motions'].append(dict(at=at, updates=args[0], home=True,
                    linear=True, offset_q12=[0]*3, velocity_q12=[0]*3))
            elif code == 24:
                flags, animation, child, *offset = args
                if flags or (child!=0 and not (binding and child==13)):
                    raise ValueError('Unbound common impact spawn')
                program['impacts'].append(dict(at=at, animation=animation, offset=offset))
                if child==13:program['impacts'][-1]['centered']=False
            elif code not in (0,3,14,15,16,21,30,34):
                raise ValueError(f'Unbound recipient reaction opcode {code}')
        if cycle is not None:
            if 'start' not in cycle or 'stop' not in cycle or cycle['start'] >= cycle['stop']:
                raise ValueError('Unterminated recipient palette cycle')
            program['palette_cycle'] = cycle
        if program['blocker'] is not None:
            for name in ('poses','white','offsets','motions','impacts'):
                program[name] = []
            program.pop('flip',None);program.pop('focus_z_pulses',None)
            program.pop('colors',None);program.pop('status_attempts',None);program.pop('signals',None)
            program.pop('palette_cycle',None)
            program.pop('sounds',None)
        latest = max((event['at'] for key in ('poses','white','offsets','motions','impacts','colors','signals','focus_z_pulses','sounds') for event in program.get(key, ())), default=-1)
        program['duration'] = max(program['duration'], latest + 1)
        programs.append(program)
    if handoffs:
        raise ValueError('Unreleased recipient lock')
    if pending_locks:
        raise ValueError('Unbound inherited recipient lock')
    return programs


def build():
    rows = battle_unite_camera.report()
    spawns = []
    for row in reaction_rows(rows):
        reaction = row['target_reaction']
        clocks = reaction.get('local_timing', {}).get('operation_ticks', [])
        for index, operation in enumerate(reaction.get('operations', [])):
            if operation['op'] != 24:
                continue
            flags, animation, script, x, y, z = operation['args']
            if flags & 1 or (script != 0 and not (reaction.get('recipient_binding') and script==13)):
                raise ValueError('Unbound Unite impact resource or child descriptor')
            spawns.append(dict(record=row['index'], operation=index,
                               local_tick=clocks[index], animation=animation,
                               offset=[x, y, z], flags=flags))
            if row.get('variant'):spawns[-1]['variant']=row['variant']
            if script==13:spawns[-1]['child']=13
    # Ordinary and ranged critical reactions use the same shared constructor and bank.
    import export_party_ranged_actors
    ranged, ranged_proof = export_party_ranged_actors.build()
    ranged_critical = {instruction['command']['child']['animation']
                       for program in ranged['programs']['programs'] if program['id'].endswith('/critical_hurt')
                       for instruction in program['instructions'] if 'child' in instruction.get('command', {})}
    selected = sorted({s['animation'] for s in spawns}|{18,19}|ranged_critical)
    sections, _, errors, data = battle_bin.parse()
    if errors:
        raise ValueError(errors)
    section = sections[0]
    table=section['tables']['f']
    pose_end=min(struct.unpack_from('<I',data,table+4*i)[0]-battle_bin.LOAD_BASE for i in range(section['b_f_count']))
    if (section['a_e_count'],pose_end-section['tables']['e'])!=(82,98*4):
        raise ValueError('shared impact pose-table extension changed')
    poses, animations, proof = export_battle_trial.section_art(
        data, section['header_offset'], battle_bin.LOAD_BASE, animation_indices=selected,pose_table_end=pose_end)
    used = sorted({pose for animation in selected for pose, _ in animations[animation]})
    entries, images = [], []
    for pose in used:
        image, ax, ay = poses[pose]
        images.append(image)
        entries.append(dict(id=pose, dx=-ax, dy=-ay, w=image.width, h=image.height,
                            source_offset=proof['poses'][pose],
                            rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest()))
    clips = []
    for animation in selected:
        frames = [dict(entry=pose, ticks=ticks or 256) for pose, ticks in animations[animation]]
        if not frames:
            raise ValueError('Empty selected Unite impact animation')
        offset = proof['animations'][animation]
        if data[offset + 1] != 1:
            raise ValueError('Unbound Unite impact animation flags')
        clips.append(dict(id=animation, frames=frames, duration=sum(f['ticks'] for f in frames),
                          source_offset=offset, flags=data[offset + 1]))
    lba, size = battle_bin.battle_bin_lba()
    packet = dict(schema='suikoden-unite-impacts/9', producer=VERSION, status='candidate',
                  atlas='impacts.png', entries=entries, animations=clips, spawns=spawns,
                  reactions=reactions(rows), ranged_critical_animations=sorted(ranged_critical),
                  ranged_critical_sources=[dict(id=row['id'], spans=next(p['spans'] for p in row['programs'] if p['id'].endswith('/critical_hurt'))) for row in ranged_proof['characters']],
                  source=dict(file=battle_bin.DISC_PATH, lba=lba, size=size,
                              sha256=hashlib.sha256(data).hexdigest(), decoder=battle_bin.DECODER_ID,
                              section=section['header_offset'],
                              atlas_offsets=section['atlas_offsets'],
                              palette_offsets=section['palette_offsets'],declared_pose_count=82,pose_table_count=98,pose_table_end=pose_end),
                  scope='Decoded shared impact art and actor-local spawn clocks. Recipient centering, '
                        'frame-driver birth/teardown timing and native binding are qualified separately; callback-owned reactions retain blockers.')
    return packet, images


def export(output):
    packet, images = build()
    output.mkdir(parents=True, exist_ok=True)
    atlas = Atlas()
    for entry, image in zip(packet['entries'], images, strict=True):
        entry['rect'] = atlas.add(image)
    atlas.save(output / packet['atlas'])
    packet['atlas_sha256'] = hashlib.sha256((output / packet['atlas']).read_bytes()).hexdigest()
    (output / 'impacts.json').write_text(json.dumps(packet, indent=2) + '\n')
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/unite_reactions')
    args = parser.parse_args()
    packet = export(args.out)
    print(f"Exported {len(packet['animations'])} shared impacts for {len(packet['spawns'])} Unite spawn sites")
