#!/usr/bin/env python3
"""Batch physical-rune actor programs from the disc; candidate data, no promotion."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile

import battle_bin
import battle_unite_camera
import character_table
from export_first_room import ROOT, source
from export_unite_programs import actor_pool, animation_resource, compile_operations
import journey_battle
import maindec
import preparation

TECHNIQUES=(('boar',8,0x800F8A9C,0x800F8B2C),('shrike',9,0x800F8FB4,0x800F9024),
            ('falcon',10,0x800F8C24,0x800F8CB4),('hate',11,0x800F8D00,0x800F8F70),
            ('trick',12,0x800F9064,0x800F90D4),('clone',13,0x800F8B78,0x800F8BEC))
CALLBACKS=(('airborne_recipient',8,0x800F3544,0x800F387C,'8283a2379640247221b6d82b497a3363eabd41c65295394e56658d51429ea1d0'),
           ('decoy_retaliation',10,0x800F387C,0x800F3AA0,'85704a5ee002912a7a8e50bb92f6cdde2f2f4ed5959999d4f79c3c8c35637381'))

LATER_ENEMIES=(('b',2,'flying_squirrel'),('b',4,'roc'),('d',2,'mad_ivy'),('f',1,'ivy'),('e',3,'hell_hound'),('e',4,'grave_master'),('g',2,'grizzly_bear'),
               ('h',1,'rabbit_bird'),('z',2,'simurgh'),('z',3,'orc'))


def callback_proofs(body,origin):
    result=[]
    for identifier,slot,first,last,digest in CALLBACKS:
        offset=first-maindec.MBASE
        actual=hashlib.sha256(body[offset:last-maindec.MBASE]).hexdigest()
        if maindec.mword(0x8016BB70+4*slot)!=first or actual!=digest:
            raise ValueError('physical-rune callback source changed: '+identifier)
        result.append(dict(id=identifier,source=origin,source_offset=offset+maindec.EXE_HEADER,
                           byte_length=last-first,sha256=actual,dispatch_slot=slot))
    return result


def stream(raw, origin, offset, table=None, base=0, header=0):
    """Follow tail dispatches while retaining each original contiguous span."""
    operations=[];spans=[];seen=set()
    while True:
        if offset in seen:raise ValueError('cyclic physical-rune tail dispatch')
        seen.add(offset)
        rows=journey_battle.script_at(raw,offset)
        size=sum(2+2*len(args) for _,args in rows)
        if not 0<=offset<offset+size<=len(raw):raise ValueError('physical-rune stream outside source')
        spans.append(dict(source=origin,source_offset=offset+header,byte_length=size,
                          sha256=hashlib.sha256(raw[offset:offset+size]).hexdigest()))
        tail=rows[-1][0]==36
        operations.extend(dict(op=op,args=list(args)) for op,args in (rows[:-1] if tail else rows))
        if len(operations)>512:raise ValueError('physical-rune program exceeds instruction budget')
        if not tail:break
        index=rows[-1][1][0]
        if table is None or table<0 or not 0<=index<128 or table+4*index+4>len(raw):raise ValueError('unbound physical-rune tail dispatch')
        spans[-1]['tail_slot']=index
        offset=struct.unpack_from('<I',raw,table+4*index)[0]-base
    return operations,spans


def initial_camera(identifier):
    if identifier in ('shrike','trick'):return None
    if identifier=='hate':
        values=struct.unpack_from('<12i',maindec.body(),0x8016C9DC-maindec.MBASE)
        return dict(updates=maindec.mword(0x800F8D44)&65535,binding='absolute',
                    **{key:list(values[i*3:i*3+3]) for i,key in enumerate(('position_q12','angles_q12','translation_q12','scale_q12'))})
    # The common helper leaves the translation target unchanged.
    return dict(updates=maindec.mword(0x800F896C)&65535,binding='recipient',
                position_q12=[0,0,-81920],angles_q12=[-3145728,0,2490368],
                scale_q12=[21299200]*3,preserve_translation=True)


def recipient_resources(include_later=False, extra_enemies=()):
    """Use the same stable enemy identities as the existing battle exporters."""
    import area_encounter_tables as encounters
    import battle_placement
    import export_world_travel
    species=(*(LATER_ENEMIES if include_later else ()),*extra_enemies)
    result=[]
    for region in ('a','b','c',*sorted({r for r,_,_ in species}-{'a','b','c'})):
        raw,origin=source('/'+region.upper()+'_DATA.BIN')
        _,_,directory,_=encounters.chain(raw)
        table=struct.unpack_from('<I',raw,directory-encounters.BASE+12)[0]-encounters.BASE
        if region=='a':ids={v:k for k,v in journey_battle.ENEMY_IDS.items()}
        elif region in ('b','c'):
            travel,_=export_world_travel.export(region);ids={}
            for placement,entry in zip(battle_placement.area_encounters(raw)['encounters'],travel['encounters'],strict=True):
                for native,identifier in zip(placement['roster'],entry['enemies'],strict=True):
                    if not native:continue
                    if ids.get(native,identifier)!=identifier:raise ValueError('inconsistent physical recipient identity')
                    ids[native]=identifier
        else:ids={native:identifier for r,native,identifier in species if r==region}
        for native,identifier in sorted(ids.items()):
            record=struct.unpack_from('<I',raw,table+4*native)[0]-encounters.BASE
            section=struct.unpack_from('<I',raw,record+44)[0]-encounters.BASE
            extent=None
            if identifier=='rabbit_bird':
                frames=struct.unpack_from('<I',raw,section+20)[0]-encounters.BASE
                extent=struct.unpack_from('<I',raw,section+8)[0]-encounters.BASE
                last=struct.unpack_from('<I',raw,frames+13*4)[0]-encounters.BASE
                if struct.unpack_from('<H',raw,section+2)[0]!=13 or extent-frames!=14*4 or raw[last:last+8]!=bytes.fromhex('02010100030f000a'):
                    raise ValueError('Rabbit Bird return animation extent changed')
            resource,proof=animation_resource(identifier,raw,origin,{0,1},section=section,base=encounters.BASE,animation_table_end=extent)
            proof.update(role='recipient',local_enemy_id=native,record_source_offset=record)
            if identifier in ('ivy','mad_ivy'):proof['inclusive_effect_animations']=[10,11,12]
            result.append((resource,proof))
    return result


def build(include_later=False):
    records=character_table.records()
    by_rune={r['rune_id']:r for r in records if r['rune_id'] in range(8,13)}
    main,main_origin=source('MAIN.EXE');body=main[maindec.EXE_HEADER:]
    if body!=maindec.body():raise ValueError('physical-rune MAIN image mismatch')
    callbacks=callback_proofs(body,main_origin)
    programs={};proofs={};resources={};requests={};techniques=[];initializers=[]
    def add(identifier,raw,origin,offset,table,prefix,base=0,header=0):
        ops,spans=stream(raw,origin,offset,table,base,header)
        instructions,blocked,effects=compile_operations(ops,prefix)
        if blocked:raise ValueError(f'unlowered physical program {identifier}: {blocked}')
        value=dict(id=identifier,instructions=instructions)
        if identifier in programs and programs[identifier]!=value:raise ValueError('inconsistent physical program')
        programs[identifier]=value
        proofs[identifier]=dict(id=identifier,spans=spans,operations=ops,host_effects=effects)
        return ops
    for ordinal,(identifier,rune,callback,multiplier) in enumerate(TECHNIQUES,1):
        descriptor=maindec.mword(0x8016A630+4*ordinal)
        if maindec.mword(descriptor+28)!=callback:raise ValueError('physical-rune initializer changed')
        word=maindec.mword(multiplier)
        if word>>16!=0x3402:raise ValueError('physical-rune numerator writer changed')
        prefix='physical/'+identifier
        if identifier=='clone':
            raw,origin,base,header=body,main_origin,maindec.MBASE,maindec.EXE_HEADER
            table=None;offsets=[0x8016C83C-base,0x8016C908-base]
            members=records
        else:
            member=by_rune[rune];raw,origin=source('/'+member['sprite_file']);base=header=0
            table=struct.unpack_from('<I',raw,32)[0]
            offsets=[struct.unpack_from('<I',raw,table+4*i)[0] for i in (13,14)]
            members=[member]
        roots=[]
        for role,offset in zip(('owner','recipient'),offsets,strict=True):
            ops=add(prefix+'/'+role,raw,origin,offset,table,prefix,base,header)
            roots.append(dict(script=role,operations=ops))
        _,children=battle_unite_camera.auxiliary_scripts(raw,origin,roots,main_origin)
        for child in children:
            key=child['id'].replace(':','_')
            child_id=prefix+'/auxiliary/'+key
            instructions,blocked,effects=compile_operations(child['operations'],prefix if child['resource']=='member' else None)
            if blocked:raise ValueError(f'unlowered physical child {child_id}: {blocked}')
            programs[child_id]=dict(id=child_id,instructions=instructions)
            proofs[child_id]=dict(id=child_id,spans=[{k:child[k] for k in ('source','source_offset','byte_length','sha256')}],
                                  operations=child['operations'],host_effects=effects)
        if identifier=='hate':
            offset=struct.unpack_from('<I',raw,table+15*4)[0]
            add(prefix+'/auxiliary/hate',raw,origin,offset,table,prefix)
        selected={0}
        for program in programs.values():
            if not program['id'].startswith(prefix+'/'):continue
            for instruction in program['instructions']:
                command=instruction.get('command',{})
                if 'animation' in command:selected.add(command['animation'])
                if command.get('child',{}).get('resource')==prefix:selected.add(command['child']['animation'])
        if identifier=='hate':selected.add(18)
        member_ids=[]
        for member in members:
            stable=preparation.stable_id(member['name']);member_ids.append(stable)
            request=requests.setdefault(stable,dict(record=member,animations={0}))
            request['animations'].update(selected)
        technique=dict(id=identifier,numerator=word&65535,denominator=10,members=member_ids,
            owner_program=prefix+'/owner',recipient_program=prefix+'/recipient',initial_camera=initial_camera(identifier),
            recipient_dispatch_signal=2,damage_signal=2,ready_signal=4,
            recovery_boundaries=2 if identifier in ('boar','clone') else 0)
        if identifier=='hate':technique['auxiliary']=dict(owner_value=1,program=prefix+'/auxiliary/hate',resource=member_ids[0],animation=18,
            position_offset_q12=[-40960,0,-81920],home='recipient',attachment='recipient_current_pose')
        techniques.append(technique)
        initializers.append(dict(id=prefix,source=main_origin,descriptor=descriptor,callback=callback,numerator_writer=multiplier))
    # Resolve member-relative resource names into the actual character resource.
    for technique in techniques:
        if technique['id']=='clone':continue
        prefix='physical/'+technique['id']
        for program in programs.values():
            if not program['id'].startswith(prefix+'/'):continue
            for instruction in program['instructions']:
                child=instruction.get('command',{}).get('child')
                if child and child['resource']==prefix:child['resource']=technique['members'][0]
    resource_proof=[]
    for stable,request in sorted(requests.items()):
        raw,origin=source('/'+request['record']['sprite_file'])
        resource,proof=animation_resource(stable,raw,origin,request['animations'])
        resources[stable]=resource;resource_proof.append(proof)
    for resource,proof in recipient_resources(include_later):
        if resource['id'] in resources:raise ValueError('duplicate physical recipient identity')
        resources[resource['id']]=resource;resource_proof.append(proof)
    add('common/decoy_response',body,main_origin,0x8016C448-maindec.MBASE,None,'physical/trick',maindec.MBASE,maindec.EXE_HEADER)
    shared={ins['command']['child']['animation'] for program in programs.values() for ins in program['instructions']
            if ins.get('command',{}).get('child',{}).get('resource')=='shared_impacts'}
    sections,_,errors,raw=battle_bin.parse(need_atlases=False)
    if errors:raise ValueError(errors)
    lba,size=battle_bin.battle_bin_lba();origin=dict(file=battle_bin.DISC_PATH,lba=lba,size=size,sha256=hashlib.sha256(raw).hexdigest())
    resource,proof=animation_resource('shared_impacts',raw,origin,shared,section=sections[0]['header_offset'],base=battle_bin.LOAD_BASE)
    resources['shared_impacts']=resource;resource_proof.append(proof)
    packet=dict(schema='suikoden-physical-actors/2',programs=dict(schema='suikoden-actor-programs/7',programs=[programs[k] for k in sorted(programs)]),
                animations=dict(schema='suikoden-actor-animations/1',resources=[resources[k] for k in sorted(resources)]),techniques=techniques)
    proof=dict(schema='suikoden-physical-actors-proof/2',producer='export_physical_runes.py v6',status='candidate',programs=[proofs[k] for k in sorted(proofs)],initializers=initializers,resources=resource_proof,callbacks=callbacks,actor_pool=actor_pool(),
        scope='Batch source programs/resources for all six techniques, shared airborne and decoy callbacks, and the decoy enemy response. '+('Qualified D/E/F/G/H/Z recipient resources are included. ' if include_later else '')+'Clone resource coverage does not grant rune attachment or canonical availability. Live physical scheduling, Hate auxiliary ownership, art/camera/SFX integration and media acceptance remain separate.')
    return packet,proof


def export(output):
    output=Path(output).resolve();accepted=(ROOT/'kit/work/accepted').resolve()
    if accepted in (output,*output.parents):raise ValueError('physical actor programs are candidates; promotion is separate')
    packet,proof=build();output.mkdir(parents=True,exist_ok=True)
    (output/'physical_runes.json').write_text(json.dumps(packet,separators=(',',':'))+'\n')
    (output/'provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
    import export_unite_programs
    with tempfile.TemporaryDirectory(prefix='physical-unites-',dir=output) as temporary:
        _,unite_proof=export_unite_programs.export(Path(temporary))
        unites=json.loads((Path(temporary)/'unites.json').read_text())
    combined=combine(unites,packet)
    (output/'battle_actors.json').write_text(json.dumps(combined,separators=(',',':'))+'\n')
    combined_proof=dict(schema='suikoden-battle-actors-proof/1',status='candidate',producer='export_physical_runes.py v6',
        physical=proof,unites=unite_proof,scope='One semantic library and19-slot actor pool; native live physical and Unite consumers. Graphical admission, camera/media acceptance and promotion remain separate.')
    (output/'battle_actors.provenance.json').write_text(json.dumps(combined_proof,indent=2)+'\n')
    return packet,proof


def combine(unites,physical):
    """Use one program/resource library and actor pool for both action families."""
    if unites['schema']!='suikoden-unite-actors/10' or physical['schema']!='suikoden-physical-actors/2':
        raise ValueError('unsupported combined actor packet')
    result=copy.deepcopy(unites)
    merge_libraries(result,physical)
    result.update(schema='suikoden-unite-actors/11',physical=copy.deepcopy(physical['techniques']))
    return result


def merge_libraries(result,extra):
    """Merge concrete action families, refusing conflicting program or clip identities."""
    schemas = ('suikoden-actor-programs/7', 'suikoden-actor-programs/8', 'suikoden-actor-programs/9', 'suikoden-actor-programs/10', 'suikoden-actor-programs/11', 'suikoden-actor-programs/12', 'suikoden-actor-programs/13')
    if result['programs']['schema'] not in schemas or extra['programs']['schema'] not in schemas:
        raise ValueError('unsupported actor program schema')
    programs={p['id']:p for p in result['programs']['programs']}
    resources={r['id']:r for r in result['animations']['resources']}
    for program in extra['programs']['programs']:
        if program['id'] in programs and programs[program['id']]!=program:raise ValueError('conflicting actor program')
        programs[program['id']]=copy.deepcopy(program)
    for resource in extra['animations']['resources']:
        existing=resources.get(resource['id'])
        if existing is None:
            resources[resource['id']]=copy.deepcopy(resource);continue
        if existing['pose_count']!=resource['pose_count']:
            if resource['id'] != 'shared_impacts' or {existing['pose_count'], resource['pose_count']} != {82,98}:
                raise ValueError('conflicting actor pose table')
            existing['pose_count']=98
        clips={c['id']:c for c in existing['clips']}
        for clip in resource['clips']:
            if clip['id'] in clips and clips[clip['id']]!=clip:raise ValueError('conflicting actor animation')
            clips[clip['id']]=copy.deepcopy(clip)
        existing['clips']=[clips[k] for k in sorted(clips)]
    result['programs']['programs']=[programs[k] for k in sorted(programs)]
    result['programs']['schema'] = schemas[max(schemas.index(result['programs']['schema']), schemas.index(extra['programs']['schema']))]
    result['animations']['resources']=[resources[k] for k in sorted(resources)]


def graphic_requests(packet, identifiers, program_roots=()):
    """Resolve frozen primary poses and secondary children from the shared programs."""
    resources={r['id']:r for r in packet['animations']['resources']}
    programs={p['id']:p for p in packet['programs']['programs']}
    wanted=set(identifiers)
    if not wanted<=resources.keys() or 'shared_impacts' in wanted:raise ValueError('unknown physical graphic resource')
    requests={identifier:dict(trails=set(),secondary=set(),white=set()) for identifier in wanted}
    visited=set()
    def walk(program,identifier,animation=0,secondary=False,white_variants=False):
        if identifier=='shared_impacts':return
        key=(program,identifier,animation,secondary,white_variants)
        if key in visited:return
        visited.add(key)
        request=requests.setdefault(identifier,dict(trails=set(),secondary=set(),white=set()))
        drawing_white=False
        clips={c['id']:c for c in resources[identifier]['clips']}
        def select(index):
            if index not in clips:raise ValueError('missing physical graphic animation')
            if secondary:request['secondary'].update(f['pose'] for f in clips[index]['frames'])
            if drawing_white:request['white'].update(f['pose'] for f in clips[index]['frames'])
        select(animation)
        for instruction in programs[program]['instructions']:
            command=instruction.get('command',{})
            if 'animation' in command:animation=command['animation'];select(animation)
            if white_variants and 'reset_draw' in command:
                drawing_white=not command['reset_draw'];select(animation)
            if command.get('effect',{}).get('id')=='blue_afterimages':request['trails'].add(clips[animation]['frames'][0]['pose'])
            if 'child' in command:
                child=command['child'];walk(child['program'],child['resource'],child['animation'],child['draw_record'],white_variants)
    techniques=packet.get('techniques',[])
    members=set(next(t['members'] for t in techniques if t['id']=='clone')) if techniques else set()
    for technique in techniques:
        for identifier in wanted & set(technique['members']):walk(technique['owner_program'],identifier)
        for identifier in wanted-members:walk(technique['recipient_program'],identifier)
        if 'auxiliary' in technique and wanted & set(technique['members']):
            child=technique['auxiliary'];walk(child['program'],child['resource'],child['animation'])
    for identifier,program in program_roots:
        if identifier in wanted:walk(program,identifier,white_variants=True)
    for enemy in packet.get('counter',{}).get('melee',{}).get('enemies',[]):
        projectile=enemy.get('projectile')
        if projectile and enemy['id'] in wanted:
            walk(projectile['child_program'],enemy['id'],projectile['animation'],secondary=True,white_variants=True)
    return requests


def graphics(packet, proof, atlas, identifiers, program_roots=(), existing_graphics=()):
    """Batch source art into the existing actor atlas without granting party membership."""
    import export_battle_trial as art
    requests=graphic_requests(packet,identifiers,program_roots)
    resources={r['id']:r for r in packet['animations']['resources']}
    sources={r['id']:r for r in proof['resources']}
    result=[];provenance=[]
    existing={row['id']:{pose['id']:pose for pose in row['poses']} for row in existing_graphics if row.get('record') is None}
    def pack(value, prior=None):
        if prior is not None:
            image,ax,ay=value;r=prior['rect']
            if (image.size,ax,ay)==((r['w'],r['h']),prior['anchor_x'],prior['anchor_y']) and atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes()==image.tobytes():return copy.deepcopy(prior)
        return art.pack_pose(atlas,value)
    white_palette=white_proof=None
    if any(request['white'] for request in requests.values()):
        main,main_origin=source('MAIN.EXE')
        offset=maindec.EXE_HEADER+0x8016B8A8-maindec.MBASE
        white_palette=struct.unpack_from('<32H',main,offset)
        white_proof=dict(source=main_origin,source_offset=offset,byte_length=64,sha256=hashlib.sha256(main[offset:offset+64]).hexdigest())
    for identifier,request in sorted(requests.items()):
        row=sources[identifier];origin=row['source'];section=row['section_offset'];base=row['pointer_base']
        raw,actual=source('/'+origin['file'].split('/')[-1])
        if actual!=origin:raise ValueError('physical graphic source changed')
        selected=[c['id'] for c in resources[identifier]['clips']]
        extent=dict(animation_table_end=row['animation_table_end']) if 'animation_table_end' in row else {}
        poses,animations,details=art.section_art(raw,section,base,animation_indices=selected,selected_poses_only=True,axis_aligned_packet=True,**extent)
        inclusive_poses=set()
        if row.get('inclusive_effect_animations'):
            effect_poses,effect_clips,_=art.section_art(raw,section,base,animation_indices=row['inclusive_effect_animations'],selected_poses_only=True,**extent)
            inclusive_poses={pose for animation in row['inclusive_effect_animations'] for pose,_ in effect_clips[animation]}
            for pose in inclusive_poses:poses[pose]=effect_poses[pose]
        secondary=None
        if request['secondary']:
            secondary_clips=[c['id'] for c in resources[identifier]['clips']
                             if any(frame['pose'] in request['secondary'] for frame in c['frames'])]
            secondary,_,_=art.section_art(raw,section,base,animation_indices=secondary_clips,selected_poses_only=True,individual_pieces=True,**extent)
        white_poses=None
        if request['white']:
            white_poses,_,_=art.section_art(raw,section,base,animation_indices=selected,selected_poses_only=True,axis_aligned_packet=True,palette_override=white_palette,**extent)
        entries=[];bindings=[]
        for pose in sorted({f['pose'] for clip in resources[identifier]['clips'] for f in clip['frames']}):
            value=poses[pose]
            mode='ordinary'
            if pose in inclusive_poses:mode='inclusive_effect'
            prior=existing.get(identifier,{}).get(pose,{})
            entry=dict(id=pose,sprite=pack(value,prior.get('ordinary',prior.get('sprite'))))
            if pose in request['white']:entry['white']=pack(white_poses[pose],prior.get('white'))
            if pose in request['secondary']:
                entry['pieces']=[art.pack_pose(atlas,piece) for piece in secondary[pose]]
                mode='ordinary_and_secondary_pieces'
            if pose in request['trails']:
                entry['trail']=journey_battle.export_blue_poses(raw,poses,atlas,pose,section,base)
            entries.append(entry)
            bindings.append(dict(id=pose,source_offset=details['poses'][pose],mode=mode,frozen_trail=pose in request['trails'],**({'white':True} if pose in request['white'] else {})))
        result.append(dict(id=identifier,poses=entries))
        provenance.append(dict(id=identifier,source=origin,section_offset=section,pointer_base=base,animations=selected,poses=bindings,
            decoder='lzss.py v'+__import__('lzss').__version__,art_decoder='export_battle_trial.py section_art; ordinary packet footprint; secondary pieces and named effects use inclusive UV'))
        if request['white']:provenance[-1]['white_palette']=white_proof
    return result,provenance


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'kit/work/build/physical_runes')
    packet,proof=export(parser.parse_args().out)
    print(f"{len(packet['techniques'])} techniques; {len(packet['programs']['programs'])} physical programs; {len(packet['animations']['resources'])} resources; combined battle_actors.json; candidate only")
