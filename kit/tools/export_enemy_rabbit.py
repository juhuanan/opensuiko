"""Static Killer Rabbit actor scripts, return hops and projectile contracts."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import battle_bin
import battle_unite_camera
from export_first_room import ROOT, source
from export_physical_runes import stream
from export_unite_programs import animation_resource, compile_operations, program_schema

BASE = 0x80080000
BLOCKS = (
    (0x1e0,0x3a8,'c2be412f3ac8c25cd30f8776f47440bb641fdacdb8943be3bbf136d818116e88'),
    (0x3a8,0x664,'f10ca7b3286a3079b712f34cc94f33241cb22e1eb1484bf98b2d21022cbf3807'),
    (0x664,0x988,'e346180e41b3bedf8b3687c4085890fa3dc6e3281a6d407999d0157a29a02a7a'),
    (0x988,0xaf4,'7de6033a360530dd35cae1dfcdb66efb3f7f4ace500cd423a203db7fe319d2c8'),
    (0xaf4,0xb44,'cb94d418b37c2b8e2e144239a7c2b682cc62334d8f0d9e1db7e9f434b197f209'),
    (0xb44,0xc1c,'abbc5c4ebcdd68bcd9145fca72d95984cd52211699f9c4230be3482555c6db6e'),
)


def combine(actors,plan=None):
    """Merge both Rabbit branches into the complete shared actor library."""
    from export_physical_runes import merge_libraries
    if actors['schema'] not in ('suikoden-unite-actors/32','suikoden-unite-actors/33','suikoden-unite-actors/34','suikoden-unite-actors/35','suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):
        raise ValueError('Rabbit requires the complete shared actor library')
    plan=build() if plan is None else plan
    result=copy.deepcopy(actors);merge_libraries(result,plan)
    bindings=result['counter']['melee']['enemies']
    previous=next((row for row in bindings if row['id']=='killer_rabbit'),None)
    if previous is None:bindings.append(copy.deepcopy(plan['ordinary']))
    elif previous!=plan['ordinary']:raise ValueError('Conflicting Rabbit binding')
    result['schema']='suikoden-unite-actors/'+str(max(34,int(actors['schema'].rsplit('/',1)[1])))
    return result


def append_content(battle,actors,atlas):
    """Batch source Rabbit art/profile and every newly qualified B formation."""
    from export_physical_runes import graphics
    from export_world_travel import battle_export,squirrel_knockout_ticks
    if any(row['id']=='killer_rabbit' for row in battle['enemies']):raise ValueError('Rabbit profile already present')
    plan=build();combined=combine(actors,plan);identifier='killer_rabbit'
    roots=[(identifier,plan['ordinary'][role+'_program']) for role in ('attack','return')]
    roots.append((identifier,plan['projectile']['owner_program']))
    art,proof=graphics(combined,dict(resources=[plan['provenance']['resource']]),atlas,{identifier},roots,existing_graphics=battle['unite_graphics'])
    existing=next((row for row in battle['unite_graphics'] if row['id']==identifier and row.get('record') is None),None)
    if existing is None:battle['unite_graphics'].append(art[0])
    else:
        poses={row['id']:row for row in existing['poses']}
        for pose in art[0]['poses']:
            if pose['id'] not in poses:existing['poses'].append(pose)
            else:
                current=poses[pose['id']]
                for key,value in pose.items():current['ordinary' if key=='sprite' and 'ordinary' in current else key]=value
    overlay=battle_export('b')
    profile=copy.deepcopy(next(row for row in overlay['enemies'] if row['id']==identifier))
    raw,_=source('/B_DATA.BIN');table=struct.unpack_from('<I',raw,plan['provenance']['record_source_offset']+40)[0]-BASE
    profile.update(action_policy='source_rabbit',knockout_ticks=squirrel_knockout_ticks(raw,table))
    profile['effect_offset']=list(struct.unpack_from('<2h',raw,plan['provenance']['record_source_offset']+60))
    profile.pop('projectile');profile.pop('ordinary_timing')
    resource=next(row for row in combined['animations']['resources'] if row['id']==identifier)
    idle=next(clip for clip in resource['clips'] if clip['id']==0)['frames'][0]['pose']
    pose=next(row for row in art[0]['poses'] if row['id']==idle)['sprite']
    profile['sprite']=copy.deepcopy(pose)
    profile['attack']=[dict(pose=copy.deepcopy(pose),ticks=1,source_pose=idle)]
    battle['enemies'].append(profile)
    supported={row['id'] for row in battle['enemies']};existing_ids={row['id'] for row in battle['encounters']};formations=[]
    for index,encounter in enumerate(overlay['encounters'],1):
        key='area_b_'+str(index)
        if key in existing_ids or not set(encounter['enemies'])<=supported:continue
        encounter=copy.deepcopy(encounter);encounter['id']=key
        battle['encounters'].append(encounter);formations.append(key)
    battle['schema']='suikoden-battle-trial/'+str(max(37,int(battle['schema'].rsplit('/',1)[1])))
    actors.clear();actors.update(combined)
    return dict(component=plan['provenance'],graphics=proof,formations=formations,
        scope='Source Rabbit and whole qualified B diagnostic formations; original field admission, audio and media acceptance remain separate.')


def build():
    raw,origin=source('/B_DATA.BIN')
    pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-BASE
    directory=pointer(pointer(pointer(0)+12))
    record=pointer(pointer(directory+12)+4)
    table=pointer(record+40);section=pointer(record+44)
    if (record,table,struct.unpack_from('<I',raw,record+48)[0],struct.unpack_from('<I',raw,table+32)[0],struct.unpack_from('<I',raw,table+24)[0]) != (0x1f748,0x1f788,0x80080664,0x800803a8,0x80080af4):
        raise ValueError('Rabbit record, decision or local callback changed')
    blocks=[]
    for first,last,digest in BLOCKS:
        if hashlib.sha256(raw[first:last]).hexdigest()!=digest:
            raise ValueError('Rabbit decision, initializer or motion callback changed')
        blocks.append(dict(source=origin,source_offset=first,byte_length=last-first,sha256=digest))
    word=lambda offset:struct.unpack_from('<I',raw,offset)[0]
    states=list(struct.unpack_from('<5I',raw,4))
    levels=list(struct.unpack_from('<4i',raw,0x1f8b0))
    if states!=[0x8008064c,0x80080418,0x8008064c,0x80080530,0x80080614] or levels!=[0,20,-20,0]:
        raise ValueError('Rabbit return state or waypoint table changed')
    motion=dict(steps=word(0x450)&65535,hop_updates=word(0x548)&65535,
        y_levels_q12=[value*4096 for value in levels],
        initial_velocity_q12=[0,0,struct.unpack('<h',struct.pack('<H',word(0x558)&65535))[0]])
    programs=[];proofs=[];roots=[];selected={0,1,3,11}
    binding=dict(id='killer_rabbit')
    for role,slot in (('attack',1),('hurt',2),('return',4)):
        operations,spans=stream(raw,origin,pointer(table+4*slot),table,BASE)
        instructions,blocked,effects=compile_operations(operations,'melee/killer_rabbit',{8:'rabbit_return'})
        if blocked or set(effects)-{'rabbit_return'}:
            raise ValueError('Unbound Rabbit ordinary program: '+role)
        identifier='melee/killer_rabbit/'+role
        binding[role+'_program']=identifier
        programs.append(dict(id=identifier,instructions=instructions))
        proofs.append(dict(id=identifier,operations=operations,spans=spans))
        roots.append(dict(script=slot,operations=operations))
        selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command',{}))
    projectile=dict(owner_program='melee/killer_rabbit/projectile_owner',
        child_program='melee/killer_rabbit/projectile_child',resource='killer_rabbit',
        animation=16,home='target_home',position_xy='owner_current',position_z_q12=-81920,
        spin_step=word(0xb20)&65535)
    for role,offset in (('owner',0x1f8f0),('child',0x1f92c)):
        operations,spans=stream(raw,origin,offset,table,BASE)
        instructions,blocked,effects=compile_operations(operations,'melee/killer_rabbit',{6:'rabbit_projectile_spin'})
        if blocked or set(effects)-{'rabbit_projectile_spin'}:
            raise ValueError('Unbound Rabbit projectile program: '+role)
        identifier=projectile[role+'_program']
        programs.append(dict(id=identifier,instructions=instructions))
        proofs.append(dict(id=identifier,operations=operations,spans=spans))
        selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command',{}))
    selected.add(projectile['animation'])
    camera_bytes=raw[0x1f8c0:0x1f8f0]
    if hashlib.sha256(camera_bytes).hexdigest()!='eb4e07df100281bace966ef2eaa6db7e0575c54d92d32f04851d427da67baf66':
        raise ValueError('Rabbit launch camera changed')
    values=struct.unpack('<12i',camera_bytes)
    projectile['camera']=dict(updates=word(0x7c8)&65535,
        target={key:list(values[index*3:index*3+3]) for index,key in enumerate(('position','angles','c','d'))})
    binding['projectile']={key:projectile[key] for key in ('owner_program','child_program','animation','position_z_q12','camera')}
    resource,resource_proof=animation_resource('killer_rabbit',raw,origin,selected,section,BASE)
    main,main_origin=source('MAIN.EXE')
    image_base=struct.unpack_from('<I',main,24)[0]
    camera_offset=2048+0x800f6110-image_base
    camera_helper=main[camera_offset:camera_offset+0x1c4]
    camera_digest='a9d5ebe82b6a1c6e670e83267fb1e727f632e0b4671592126e1c26c082d45966'
    if hashlib.sha256(camera_helper).hexdigest()!=camera_digest:
        raise ValueError('Rabbit camera setter changed')
    _,children=battle_unite_camera.auxiliary_scripts(raw,origin,roots,main_origin,table+BASE,BASE)
    for child in children:
        instructions,blocked,effects=compile_operations(child['operations'])
        if blocked or effects or child['resource']!='shared':
            raise ValueError('Unbound Rabbit ordinary child')
        child['playback']='shared_actor_program'
        programs.append(dict(id='melee/killer_rabbit/auxiliary/'+child['id'].replace(':','_'),instructions=instructions))
    sections,_,errors,shared_raw=battle_bin.parse(need_atlases=False)
    if errors:raise ValueError(errors)
    lba,size=battle_bin.battle_bin_lba()
    shared_origin=dict(file=battle_bin.DISC_PATH,lba=lba,size=size,sha256=hashlib.sha256(shared_raw).hexdigest())
    shared,shared_proof=animation_resource('shared_impacts',shared_raw,shared_origin,{0},sections[0]['header_offset'],battle_bin.LOAD_BASE)
    return dict(schema='suikoden-enemy-rabbit/1',ordinary=binding,return_motion=motion,projectile=projectile,
        programs=dict(schema=program_schema(programs),programs=programs),
        animations=dict(schema='suikoden-actor-animations/1',resources=[resource,shared]),
        provenance=dict(producer='export_enemy_rabbit.py v5',source=origin,record_source_offset=record,
            programs=proofs,resource=resource_proof,children=children,shared_resource=shared_proof,callbacks=blocks,
            return_dispatch=dict(source_offset=4,targets=states),return_levels=dict(source_offset=0x1f8b0,values=levels),
            camera=dict(source=origin,source_offset=0x1f8c0,byte_length=48,sha256=hashlib.sha256(camera_bytes).hexdigest(),
                setter=dict(source=main_origin,source_offset=camera_offset,byte_length=len(camera_helper),sha256=camera_digest)),
            scope='Ordinary and projectile actor components with shared impact dependency, return-hop/spin callbacks and launch camera. Normal art/admission, audio and media acceptance remain separate.'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'kit/work/build/enemy_rabbit/ordinary.json')
    args=parser.parse_args();output=args.output.resolve()
    if (ROOT/'kit/work/accepted').resolve() in (output,*output.parents):
        raise ValueError('Rabbit source exports cannot write accepted staging')
    packet=build();output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(packet,separators=(',',':'))+'\n')
    print(f'Exported {len(packet["programs"]["programs"])} Rabbit actor programs; no normal admission')
