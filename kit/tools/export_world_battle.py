"""Candidate B/C source formations and shared actor art; no window or promotion."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import copy
import shutil
from PIL import Image
import battle_mock as geometry
import character_table
import preparation
from export_battle_trial import section_art, pack_pose, ground_tiles, world_position, foot_offset_y
from export_first_room import Atlas, ROOT, source
from export_world_travel import battle_export, party_attack_timing
import area_encounter_tables as encounters


def c_actor_profiles(overlay, library, graphics):
    """Bind existing source C profiles to the common actor atlas."""
    bound={row['id'] for row in library['counter']['melee']['enemies']}
    profiles=[copy.deepcopy(row) for row in overlay['enemies'] if row['id'] in bound]
    for enemy in profiles:
        if enemy['id']=='kobold_type_2':
            enemy['action_policy']='source_projectile';enemy['front_projectile']=None
        resource=next(row for row in library['animations']['resources'] if row['id']==enemy['id'])
        idle=next(row for row in resource['clips'] if row['id']==0)['frames'][0]['pose']
        graphic=next(row for row in graphics if row['id']==enemy['id'] and row.get('record') is None)
        entry=next(row for row in graphic['poses'] if row['id']==idle)
        enemy['sprite']=copy.deepcopy(entry.get('ordinary',entry['sprite']))
        enemy['attack']=[dict(pose=enemy['sprite'],ticks=1,source_pose=idle)]
    return profiles


def export_c_actors(journey, output):
    """Bind source archer/melee/magic formations, retaining the shared atlas prefix."""
    output=Path(output).resolve();journey=Path(journey)
    accepted=(ROOT/'kit/work/accepted').resolve()
    if accepted in (output,*output.parents):raise ValueError('candidate exporter cannot write accepted staging')
    content=json.loads((journey/'battle/trial.json').read_text())
    library=json.loads((journey/'battle/unites.json').read_text())
    if library['schema'] not in ('suikoden-unite-actors/15', 'suikoden-unite-actors/17', 'suikoden-unite-actors/19', 'suikoden-unite-actors/21', 'suikoden-unite-actors/22', 'suikoden-unite-actors/23', 'suikoden-unite-actors/24', 'suikoden-unite-actors/25', 'suikoden-unite-actors/26', 'suikoden-unite-actors/27', 'suikoden-unite-actors/28', 'suikoden-unite-actors/29', 'suikoden-unite-actors/30', 'suikoden-unite-actors/31', 'suikoden-unite-actors/32', 'suikoden-unite-actors/34', 'suikoden-unite-actors/35', 'suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):raise ValueError('C actors need the complete shared actor and magic bindings')
    overlay=battle_export('c')
    bound={row['id'] for row in library['counter']['melee']['enemies']}
    selected=[row for row in overlay['encounters'] if set(row['enemies'])<=bound]
    if not selected:raise ValueError('no source C formations have complete actor bindings')
    overlay['schema']='suikoden-world-battle/31'
    content['schema']=content['schema'] if content['schema'] in {f'suikoden-battle-trial/{version}' for version in range(33,47)} else 'suikoden-battle-trial/32'
    content['encounters']=copy.deepcopy(selected)
    content.pop('battlefields',None)
    content['enemies']=c_actor_profiles(overlay,library,content['unite_graphics'])
    for name in ('protection','round_start','party_attacks'):
        content[name]=copy.deepcopy(overlay[name])
    raw,origin=source('/C_DATA.BIN');_,_,directory,_=encounters.chain(raw)
    word=lambda address:struct.unpack_from('<I',raw,address-encounters.BASE)[0]
    base=Image.open(journey/'battle/actors.png').convert('RGBA')
    atlas=Atlas();atlas.image=Image.new('RGBA',(base.width,4096));atlas.image.paste(base,(0,0));atlas.y=base.height+1
    scenery_section=word(directory+4)-encounters.BASE
    poses,clips,scenery_proof=section_art(raw,scenery_section,encounters.BASE)
    packed=[pack_pose(atlas,pose) for pose in poses]
    records=word(directory+20)-encounters.BASE;count=struct.unpack_from('<h',raw,records)[0]
    if not 0<=count<=32:raise ValueError('invalid source C scenery count')
    content['scenery']=[]
    for index in range(count):
        animation,x,y,z=struct.unpack_from('<4h',raw,records+8+index*8)
        content['scenery'].append(dict(sprite=packed[clips[animation][0][0]],position=world_position((x,y,z))))
    terrain,ground_proof=ground_tiles(raw,directory)
    vertices,across,down,tiles=geometry.battle_ground_mesh(raw)
    content['ground']=dict(across=across,down=down,vertices=[world_position(v) for v in vertices],tiles=[int(v) for v in tiles])
    output.mkdir(parents=True,exist_ok=True)
    archer,archer_proof=export_c(output/'archer_source')
    archer_atlas=Image.open(output/'archer_source/actors.png').convert('RGBA')
    remapped={}
    def relocate(pose):
        pose=copy.deepcopy(pose)
        rect=pose['rect'];key=tuple(rect[name] for name in ('x','y','w','h'))
        if key not in remapped:
            x,y,w,h=key;remapped[key]=atlas.add(archer_atlas.crop((x,y,x+w,y+h)))
        pose['rect']=copy.deepcopy(remapped[key])
        return pose
    for actor in archer['actors']:
        actor['poses']=[relocate(pose) for pose in actor['poses']]
    for entry in archer['scenery']:entry['sprite']=relocate(entry['sprite'])
    archer['atlas_width']=atlas.image.width;archer['atlas_height']=atlas.y+atlas.row_height
    overlay['presentation']=archer
    atlas.save(output/'actors.png');terrain.save(output/'ground.png')
    raster,mask=geometry.render_ground(terrain,vertices,across,down,tiles,H=geometry.PROJ_H*.8,screen_offset=(0,17))
    floor=Image.new('RGB',geometry.SCREEN);floor.paste(raster,(0,0),mask);floor.save(output/'floor.png')
    spells=json.loads((journey/'battle/spells.json').read_text())
    for identifier in {identifier for row in selected for identifier in row['enemies']}:
        if not any(row['id']==identifier and row.get('knockout') for row in spells['hurt_poses']):
            raise ValueError('journey spell atlas is missing source C hurt/KO art')
    for name in ('unites.json','spells.json','spell_effects.png'):shutil.copyfile(journey/'battle'/name,output/name)
    (output/'trial.json').write_text(json.dumps(content,separators=(',',':'))+'\n')
    overlay['actor_content']=content
    (output/'world.json').write_text(json.dumps(overlay,separators=(',',':'))+'\n')
    proof=dict(schema='suikoden-world-actor-proof/1',status='candidate',producer='export_world_battle.py export_c_actors/5',
        region='region_c',source=origin,encounters=[row['id'] for row in selected],
        atlas_prefix=dict(source='journey/battle/actors.png',width=base.width,height=base.height,rgba_sha256=hashlib.sha256(base.tobytes()).hexdigest()),
        ground=ground_proof,scenery=scenery_proof,archer_art=archer_proof,actors=json.loads((journey/'battle/provenance.json').read_text())['counter_actor_programs'],
        spell_art=json.loads((journey/'battle/spells.provenance.json').read_text()),
        limits=['Source formations and metadata; canonical campaign entry and GPU/human media review remain separate.',
                'Common cover and source projectile scripts are bound; broader status, action overlap and other enemy callbacks remain unqualified.'],native_launched=False,media_accepted=False,promoted=False)
    (output/'provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
    files=('world.json','trial.json','actors.png','floor.png','ground.png','unites.json','spells.json','spell_effects.png','provenance.json')
    (output/'manifest.json').write_text(json.dumps(dict(schema='suikoden-world-actor-manifest/1',status='candidate',
        files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in files}),indent=2)+'\n')
    return overlay,proof


def impact_offsets(data,proof):
    return [[((data[off+6+i]-data[off+4+i]+128)%256)-128 for i in range(2)] for off in proof['poses']]


def action_samples(data, section, table, base, animations, home, target, scripts, initial_offset=(0,0), animation_flags=None, initial_position=None, initial_animation=0, signal_ticks=None, return_pose=None):
    """Resolve this slice's linear scripts into named pose/world samples at export."""
    from actor_script import OP_LEN_HW
    word=lambda offset:struct.unpack_from('<I',data,offset)[0]-base
    flags=animation_flags or [data[word(word(section+20)+4*i)+1] for i in range(len(animations))]
    def walk(index):
        pc=index-base if table is None else word(table+4*index)
        for _ in range(128):
            op=struct.unpack_from('<H',data,pc)[0]
            if op in (0,1):return
            n=OP_LEN_HW.get(op)
            if not n:raise ValueError('unsupported B presentation script')
            yield op,struct.unpack_from('<'+'h'*(n-1),data,pc+2);pc+=2*n
        raise ValueError('unterminated B presentation script')
    clock=animation_end=movement_end=0;events=[(0,initial_animation)];moves=[];offsets=[(0,list(initial_offset))];point=list(initial_position or home);release=None;return_idle=None
    for script in scripts:
        for op,args in walk(script):
            if op==4:
                clip=args[0];events.append((clock,clip));animation_end=clock+sum(t or 256 for e,t in animations[clip])
            elif op==5:clock=max(clock,animation_end)
            elif op==3:clock+=args[0]
            elif op in (23,33,22):
                if op==22:
                    duration=args[0];destination=list(home);velocity=[0,0,0];linear=True
                else:
                    mode,duration,x,y,z=args[:5]
                    if op==33:
                        if mode not in (1,3):raise ValueError('unsupported B linear destination')
                        destination=list(home) if mode==3 else [point[i]+v for i,v in enumerate((x,y,z))];velocity=[0,0,0];linear=True
                    else:
                        if mode not in (1,2,3) or duration<2:raise ValueError('unsupported B leap destination')
                        reference=point if mode==1 else target if mode==2 else home
                        destination=[reference[0]+x,reference[1]+y,z];velocity=[v/2 for v in args[5:]];linear=False
                moves.append((max(1,clock),duration,list(point),destination,velocity,linear));point=destination;movement_end=max(1,clock)+duration
            elif op==21:clock=max(clock,movement_end)
            elif op==28:
                if signal_ticks is None or args not in signal_ticks:raise ValueError('unresolved presentation signal wait')
                clock=max(clock,signal_ticks[args])
            elif op==25:
                if args[0]!=1:raise ValueError('unsupported B drawing offset')
                offsets.append((clock,list(args[1:])))
            elif op==43:
                duration,x,y=args
                if duration:
                    first=offsets[-1][1]
                    for step in range(1,duration+1):offsets.append((movement_end-duration+step-1,[round(first[i]+(v-first[i])*step/duration) for i,v in enumerate((x,y))]))
                else:offsets.append((clock,[x,y]))
            elif op==44:
                if args!=(1,9):raise ValueError('unsupported B cover ownership wait')
                # The cover return track starts after the independently verified protector release.
            elif op==26 and args==(0,4) and script==1:return_idle=clock
            elif op==16 and args in ((0,1),(0,8)):release=clock
            elif op not in (9,13,14,15,16,24,26,27,34,38,39,44):raise ValueError('B presentation opcode changed')
    duration=release if scripts==[1,4] else clock
    samples=[]
    for tick in range(1,duration+1):
        selected,started=0,0
        for when,clip in events:
            if when<=tick:selected,started=clip,when
        elapsed=tick-started;clip=animations[selected];total=sum(t or 256 for e,t in clip)
        if flags[selected]&2:elapsed%=total
        pose=clip[-1][0]
        for e,t in clip:
            if elapsed<(t or 256):pose=e;break
            elapsed-=t or 256
        if tick==return_idle:pose=animations[0][0][0] if return_pose is None else return_pose
        position=list(initial_position or home)
        for start,n,first,last,velocity,linear in moves:
            if tick<start:break
            t=min(n,tick-start+1)
            if t==n:position=list(last)
            elif linear:position=[first[i]+int((last[i]-first[i])*4096/n)*t/4096 for i in range(3)]
            else:
                import math
                acceleration=[math.trunc((last[i]-first[i]-velocity[i]*n)/(n*(n-1)/2)*4096)/4096 for i in range(3)]
                position=[first[i]+velocity[i]*t+acceleration[i]*t*(t-1)/2 for i in range(3)]
        shift=list(initial_offset)
        for when,value in offsets:
            if when<=tick:shift=value
        samples.append(dict(position=world_position(position),pose=pose,offset=shift))
    return samples


def export(output):
    output=Path(output).resolve()
    if ROOT/'kit/work/accepted' in (output,*output.parents):raise ValueError('candidate export cannot write accepted content')
    raw,origin=source('/B_DATA.BIN');sources=[origin,source('MAIN.EXE')[1]]
    _,_,directory,_=encounters.chain(raw)
    word=lambda address:struct.unpack_from('<I',raw,address-encounters.BASE)[0]
    atlas=Atlas();actors=[];proof=[];decoded={}
    def actor(identifier,data,section,base=0):
        poses,animations,details=section_art(data,section,base)
        packed=[pack_pose(atlas,pose) for pose in poses]
        actors.append(dict(id=identifier,impact_offsets=impact_offsets(data,details),foot_offset_y=foot_offset_y(poses[animations[0][0][0]]),poses=packed,animations=[[dict(pose=e,ticks=t or 256) for e,t in clip] for clip in animations]))
        proof.append(dict(id=identifier,**details));decoded[identifier]=(data,section,base,animations)
    names=('hero','gremio','pahn','viktor','yam_koo','tai_ho')
    records={preparation.stable_id(row['name']):row for row in character_table.records()}
    for identifier in names:
        data,origin=source('/'+records[identifier]['sprite_file']);sources.append(origin)
        actor(identifier,data,struct.unpack_from('<I',data,36)[0])
    enemy=word(word(directory+12)+4*4)
    actor('roc',raw,word(enemy+44)-encounters.BASE,encounters.BASE)
    terrain,ground_proof=ground_tiles(raw,directory)
    vertices,across,down,tiles=geometry.battle_ground_mesh(raw)
    ground,mask=geometry.render_ground(terrain,vertices,across,down,tiles,H=geometry.PROJ_H*.72,screen_offset=(0,17))
    floor=Image.new('RGB',geometry.SCREEN);floor.paste(ground,(0,0),mask)
    scenery_offset=word(directory+4)-encounters.BASE
    poses,clips,scenery_proof=section_art(raw,scenery_offset,encounters.BASE)
    packed=[pack_pose(atlas,pose) for pose in poses]
    records_offset=word(directory+20)-encounters.BASE
    count=struct.unpack_from('<h',raw,records_offset)[0]
    if not 0<=count<=1024:raise ValueError('invalid B scenery count')
    scenery=[]
    for index in range(count):
        clip,x,y,z=struct.unpack_from('<4h',raw,records_offset+8+index*8)
        if not 0<=clip<len(clips) or not clips[clip]:raise ValueError('invalid B scenery clip')
        scenery.append(dict(sprite=packed[clips[clip][0][0]],position=world_position((x,y,z))))
    overlay=battle_export();encounter=next(row for row in overlay['encounters'] if row['id']=='world_b_encounter_4')
    rotation,translation,_=geometry.battle_camera()
    scene=dict(schema='suikoden-world-battle-art/5',region='region_b',encounter=encounter['id'],atlas='actors.png',background='floor.png',atlas_width=atlas.image.width,atlas_height=atlas.y+atlas.row_height,actors=actors,scenery=scenery,formation_slots=[world_position(p) for p in geometry.party_world_positions()],enemy_positions=encounter['positions'],camera=dict(transform=[[v/4096 for v in rotation[i*3:i*3+3]]+[translation[i]] for i in range(3)],focal_length=geometry.PROJ_H*1.44,center_x=320,center_y=202),sprite_scale=geometry.battle_scale_q12()/4096*1.44)
    homes=geometry.party_world_positions()
    hero_home=homes[0];roc_home=(-108,0,-10);roc_settled=(-108,0,0)
    for actor in actors:
        data,section,base,clips=decoded[actor['id']]
        if actor['id'] not in ('hero','roc'):actor['attack']=[];actor['hurt']=[];continue
        table=0x236C8 if base else struct.unpack_from('<I',data,32)[0]
        own,target=(hero_home,roc_settled) if actor['id']=='hero' else (roc_home,hero_home)
        actor['attack']=action_samples(data,section,table,base,clips,own,target,[1,4],(0,-2) if actor['id']=='hero' else (0,0))
        other_data,other_section,other_base,other_clips=decoded['roc' if actor['id']=='hero' else 'hero']
        other_table=0x236C8 if other_base else struct.unpack_from('<I',other_data,32)[0]
        own_flags=[data[struct.unpack_from('<I',data,struct.unpack_from('<I',data,section+20)[0]-base+4*i)[0]-base+1] for i in range(len(clips))]
        actor['hurt']=action_samples(other_data,other_section,other_table,other_base,clips,own,own,[2],animation_flags=own_flags,initial_position=hero_home if actor['id']=='hero' else roc_settled)[:13 if actor['id']=='hero' else 36]
    # Resolve the common cover scripts against the actual Roc reaction; no original pointers reach Zig.
    import maindec
    main=maindec.body();guard_home=geometry.party_world_positions()[1]
    for actor in actors:
        actor['cover']=[];actor['covered_attack']=[];actor['settled_attack']=[]
    for index,role in ((0,'ward'),(1,'guard')):
        actor=actors[index];data,section,base,clips=decoded[actor['id']]
        frames=struct.unpack_from('<I',data,section+20)[0]-base
        flags=[data[struct.unpack_from('<I',data,frames+4*i)[0]-base+1] for i in range(len(clips))]
        script=0x8016C29C if role=='ward' else 0x8016C270
        home=hero_home if role=='ward' else guard_home
        approach=action_samples(main,0,None,maindec.MBASE,clips,home,hero_home,[script],animation_flags=flags,initial_animation=2 if role=='ward' else 0)
        track=approach+[approach[-1]]*(48-len(approach))
        if role=='guard':
            roc_data,roc_section,roc_base,_=decoded['roc']
            reaction=action_samples(roc_data,roc_section,0x236C8,roc_base,clips,home,home,[2],animation_flags=flags,initial_position=hero_home)[:13]
            track+=reaction
        else:
            track+=[track[-1]]*14
            returning=action_samples(main,0,None,maindec.MBASE,clips,home,home,[0x8016C2B4],animation_flags=flags,initial_position=(home[0]+20,home[1],home[2]),initial_animation=2)
            track+=returning[:10]
            table=struct.unpack_from('<I',data,32)[0]
            actor['covered_attack']=action_samples(data,section,table,base,clips,home,roc_settled,[1,4])[:128]
        actor['cover']=track
    roc_data,roc_section,roc_base,roc_clips=decoded['roc']
    actors[-1]['covered_attack']=action_samples(roc_data,roc_section,0x236C8,roc_base,roc_clips,roc_home,(hero_home[0]+20,hero_home[1],hero_home[2]),[1,4])[:144]
    actors[-1]['settled_attack']=action_samples(roc_data,roc_section,0x236C8,roc_base,roc_clips,roc_home,hero_home,[1,4],initial_position=roc_settled)[:144]
    # The default stance replaces the released actor; it is not an extra attack recovery.
    actors[0]['attack']=actors[0]['attack'][:128];actors[-1]['attack']=actors[-1]['attack'][:144]
    offsets=struct.unpack_from('<12h',maindec.body(),0x8016C338-maindec.MBASE)
    particles=[]
    for tick in range(1,30):
        row=[]
        for index in range(4):
            velocity=[int(v*4096/30) for v in offsets[index*3:index*3+3]]
            acceleration=[int(-v*30/435) for v in velocity]
            row.append(world_position([(v*tick+a*tick*(tick-1)//2)/4096 for v,a in zip(velocity,acceleration)]))
        particles.append(row)
    scene['medicine_particles']=particles
    extras=[]
    roc_data,roc_section,roc_base,roc_clips=decoded['roc']
    roc_frames=struct.unpack_from('<I',roc_data,roc_section+20)[0]-roc_base
    roc_flags=[roc_data[struct.unpack_from('<I',roc_data,roc_frames+4*i)[0]-roc_base+1] for i in range(len(roc_clips))]
    for index in (0,1,2,4,5):
        identifier=names[index]
        data,section,base,clips=decoded[identifier]
        table=struct.unpack_from('<I',data,32)[0]
        timing=party_attack_timing(identifier)
        target=dict(unhurt=action_samples(data,section,table,base,clips,homes[index],roc_settled,[1,4],return_pose=clips[9][-1][0])[:timing['release_tick']-1],
                    after_hit=action_samples(data,section,table,base,clips,homes[index],roc_settled,[1,4],initial_offset=(0,-2),return_pose=clips[9][-1][0])[:timing['release_tick']-1])
        reaction=action_samples(data,section,table,base,roc_clips,roc_home,roc_home,[2],animation_flags=roc_flags,initial_position=roc_settled)[:timing['target_release_delay']]
        restored=action_samples(data,section,table,base,roc_clips,roc_home,roc_home,[2],animation_flags=roc_flags)[:timing['target_release_delay']]
        extras.append(dict(id=identifier,targets=[target],target_hurt=[reaction],restored_target_hurt=[restored]))
    scene['schema']='suikoden-world-battle-art/12'
    scene['extra_party_attacks']=extras
    output.mkdir(parents=True,exist_ok=True);floor.save(output/'floor.png');atlas.save(output/'actors.png')
    (output/'scene.json').write_text(json.dumps(scene,separators=(',',':'))+'\n')
    provenance=dict(schema='suikoden-world-battle-art-proof/1',status='candidate',sources=sources,producer='kit/tools/export_world_battle.py',decoder='export_battle_trial.section_art/ground_tiles; lzss.decode_strict v2; descriptor pieces and per-tile palettes',actors=proof,ground=ground_proof,heightfield=dict(across=across,down=down,vertices=vertices,tiles=tiles),scenery=dict(**scenery_proof,records_offset=records_offset,count=count),presentation=dict(source_crop=[0,36,320,168],scale=2,framing_zoom=.72,framing_offset_y=17,limits=['unlit terrain: source flat-light shading remains unexported','fixed source camera with explicit crop/zoom adaptation; original dynamic camera choreography remains outside this slice','source descriptor anchors and statically compiled ordinary/cover action/reaction samples; original death palette flashing is not reproduced','shared native/CPU depth composition; perspective billboard scaling and flat party shadows are labeled port presentation','diagnostic supplied party/checkpoint; no canonical campaign entry']),outputs={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('scene.json','actors.png','floor.png')},native_launched=False,media_accepted=False,promoted=False)
    (output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    return scene,provenance


def export_c(output):
    """C formation1 candidate; resolve the checked archer scripts into ordinary samples."""
    from actor_script import OP_LEN_HW
    from copy import deepcopy
    output=Path(output).resolve()
    if (ROOT/'kit/work/accepted').resolve() in (output,*output.parents):
        raise ValueError('candidate exporter cannot write accepted staging')
    raw,origin=source('/C_DATA.BIN');sources=[origin,source('MAIN.EXE')[1]]
    _,_,directory,_=encounters.chain(raw)
    word=lambda offset:struct.unpack_from('<I',raw,offset)[0]-encounters.BASE
    record=word(word(directory-encounters.BASE+12)+4*2)
    section=word(record+44);table=word(record+40)
    def script(slot):
        cursor=word(table+4*slot);ops=[]
        for _ in range(128):
            op=struct.unpack_from('<H',raw,cursor)[0]
            if op in (0,1):return ops
            count=OP_LEN_HW[op];ops.append((op,struct.unpack_from('<'+'h'*(count-1),raw,cursor+2)));cursor+=2*count
        raise ValueError('unterminated C archer script')
    shot=script(1);child=script(6);retreat=script(4)
    assert [op for op,_ in shot]==[15,15,9,4,5,4,5,24,28,4,5,26]
    assert next(args for op,args in shot if op==24)==(11,17,6,10,0,-24)
    assert [op for op,_ in child]==[34,30,35,31,14,13,33,3,26,3,26,21,2]
    assert next(args for op,args in child if op==33)==(3,15,0,0,0)
    assert next(args for op,args in retreat if op==23)==(3,20,0,0,0,0,0,0)
    atlas=Atlas();actors=[];proof=[];decoded={};hits=[]
    records={preparation.stable_id(row['name']):row for row in character_table.records()}
    for identifier in ('hero','gremio','pahn','viktor','yam_koo','tai_ho','kobold_type_2'):
        if identifier=='kobold_type_2':data,offset,base=raw,section,encounters.BASE
        else:
            data,source_proof=source('/'+records[identifier]['sprite_file']);sources.append(source_proof)
            offset,base=struct.unpack_from('<I',data,36)[0],0
        poses,clips,details=section_art(data,offset,base)
        actors.append(dict(id=identifier,impact_offsets=impact_offsets(data,details),foot_offset_y=foot_offset_y(poses[clips[0][0][0]]),poses=[pack_pose(atlas,pose) for pose in poses],animations=[[dict(pose=e,ticks=t or 256) for e,t in clip] for clip in clips],attack=[],hurt=[],cover=[],covered_attack=[],settled_attack=[]))
        decoded[identifier]=(data,offset,base,clips);proof.append(dict(id=identifier,**details))
        if base==0:
            descriptor=details['poses'][clips[0][0][0]]
            hits.append([data[descriptor+6]-data[descriptor+4],data[descriptor+7]-data[descriptor+5]])
    actors.append(deepcopy(actors[-1]));proof.append(deepcopy(proof[-1]))
    overlay=battle_export('c');encounter=overlay['encounters'][0]
    homes=geometry.party_world_positions();enemy_homes=[[position[key] for key in ('x','y','z')] for position in encounter['positions']]
    clips=decoded['kobold_type_2'][3]
    assert clips[7]==[(0,1)] and sum(t for _,t in clips[8])==40 and sum(t for _,t in clips[9])==37
    assert not clips[10] and clips[11]==[(5,1)] and not clips[12] and clips[17]==[(6,1)]
    start=1+sum(t for _,t in clips[8]);flight=15;impact=start+flight
    finish=impact+sum(t for _,t in clips[9]);return_begin=finish+1;return_end=return_begin+1+20;release=return_end+1
    assert (start,impact,release)==(41,56,116)
    def pose_at(clip,tick):
        for pose,duration in clip:
            if tick<duration:return pose
            tick-=duration
        return clip[-1][0]
    for index,home in enumerate(enemy_homes,6):
        for tick in range(1,release+1):
            pose=pose_at(clips[8],tick-1) if tick<impact else pose_at(clips[9],tick-impact) if tick<finish else clips[11][0][0] if return_begin<=tick<return_end else clips[0][0][0]
            actors[index]['attack'].append(dict(position=world_position(home),pose=pose,offset=[0,0]))
        hero_data,hero_section,_,_=decoded['hero'];hero_table=struct.unpack_from('<I',hero_data,32)[0]
        own_flags=[raw[word(word(section+20)+4*i)+1] for i in range(len(clips))]
        actors[index]['hurt']=action_samples(hero_data,hero_section,hero_table,0,clips,home,home,[2],animation_flags=own_flags)[:36]
    hero_attacks=[]
    for home in enemy_homes:
        data,offset,base,own_clips=decoded['hero'];own_table=struct.unpack_from('<I',data,32)[0]
        hero_attacks.append(dict(unhurt=action_samples(data,offset,own_table,base,own_clips,homes[0],home,[1,4])[:128],after_hit=action_samples(data,offset,own_table,base,own_clips,homes[0],home,[1,4],initial_offset=(0,-2))[:128]))
    for index in range(2):
        data,offset,base,own_clips=decoded[actors[index]['id']]
        flags=[data[struct.unpack_from('<I',data,struct.unpack_from('<I',data,offset+20)[0]+4*i)[0]+1] for i in range(len(own_clips))]
        actors[index]['hurt']=action_samples(raw,section,table,encounters.BASE,own_clips,homes[index],homes[index],[2],animation_flags=flags)[:36]
    projectiles=[]
    for home in enemy_homes:
        targets=[]
        for target,hit in zip(homes[:2],hits[:2]):
            first=[int((v+delta)*4096) for v,delta in zip(home,(10,0,-24))]
            last=[v*4096 for v in target];velocity=[int((b-a)/flight) for a,b in zip(first,last)]
            point=first[:];offset=[0,0];track=[]
            for step in range(flight+2):
                if 0<step<=flight:
                    point=[v+delta for v,delta in zip(point,velocity)]
                    offset=[v+int((goal-v)/(flight-step+1)) for v,goal in zip(offset,hit)]
                    if step==flight:point=last[:]
                track.append(dict(position=world_position([v/4096 for v in point]),pose=clips[17][0][0],offset=offset[:]))
            targets.append(track)
        projectiles.append(targets)
    terrain,ground_proof=ground_tiles(raw,directory)
    vertices,across,down,tiles=geometry.battle_ground_mesh(raw)
    ground,mask=geometry.render_ground(terrain,vertices,across,down,tiles,H=geometry.PROJ_H*.72,screen_offset=(0,17))
    floor=Image.new('RGB',geometry.SCREEN);floor.paste(ground,(0,0),mask)
    scenery_offset=word(directory-encounters.BASE+4)
    poses,scenery_clips,scenery_proof=section_art(raw,scenery_offset,encounters.BASE)
    packed=[pack_pose(atlas,pose) for pose in poses]
    records_offset=word(directory-encounters.BASE+20);count=struct.unpack_from('<h',raw,records_offset)[0]
    if not 0<=count<=32:raise ValueError('invalid C scenery count')
    scenery=[]
    for index in range(count):
        clip,x,y,z=struct.unpack_from('<4h',raw,records_offset+8+index*8)
        if not 0<=clip<len(scenery_clips) or not scenery_clips[clip]:raise ValueError('invalid C scenery clip')
        scenery.append(dict(sprite=packed[scenery_clips[clip][0][0]],position=world_position((x,y,z))))
    rotation,translation,_=geometry.battle_camera()
    dodges=[]
    for index in range(2):
        data,offset,base,own_clips=decoded[actors[index]['id']];own_table=struct.unpack_from('<I',data,32)[0]
        # The child sets owner signal1 on52; the earlier target slot observes it on53.
        track=[dict(position=world_position(homes[index]),pose=own_clips[0][0][0],offset=[0,0]) for _ in range(52)]
        track+=action_samples(data,offset,own_table,base,own_clips,homes[index],homes[index],[3],signal_ticks={(1,2):5,(1,4):42})[:-1]
        assert len(track)==(113 if index==0 else 118)
        dodges.append(track)
    missed_projectiles=[]
    for targets in projectiles:
        row=[]
        for track in targets:
            extended=deepcopy(track[:16]);last=extended[-1]
            velocity={key:track[1]['position'][key]-track[0]['position'][key] for key in ('x','y','z')}
            for step in range(1,31):extended.append(dict(position={key:last['position'][key]+velocity[key]*step for key in velocity},pose=last['pose'],offset=last['offset'][:]))
            extended.append(deepcopy(extended[-1]));row.append(extended)
        missed_projectiles.append(row)
    low_data,low_section,low_base,low_clips=decoded['gremio']
    low_descriptor=proof[1]['poses'][low_clips[2][0][0]]
    low_hit=[low_data[low_descriptor+6]-low_data[low_descriptor+4],low_data[low_descriptor+7]-low_data[low_descriptor+5]]
    low_projectiles=[];low_misses=[]
    for owner in range(2):
        for original,output_tracks in ((projectiles[owner][1],low_projectiles),(missed_projectiles[owner][1],low_misses)):
            track=deepcopy(original);offset=[0,0]
            for step,sample in enumerate(track):
                if 0<step<=flight:offset=[v+int((goal-v)/(flight-step+1)) for v,goal in zip(offset,low_hit)]
                sample['offset']=offset[:]
            output_tracks.append(track)
    low_dodge=[dict(position=world_position(homes[1]),pose=low_clips[2][0][0],offset=[0,0]) for _ in range(52)]
    low_dodge+=action_samples(low_data,low_section,struct.unpack_from('<I',low_data,32)[0],low_base,low_clips,homes[1],homes[1],[3],initial_animation=2,signal_ticks={(1,2):5,(1,4):42})[:-1]
    low_hp=dict(target='gremio',dodge=low_dodge,projectiles=low_projectiles,miss_projectiles=low_misses)
    extra_attacks=[]
    for index in (1,2,4,5):
        identifier=actors[index]['id'];timing=next(row for row in overlay['party_attacks'] if row['id']==identifier)
        data,offset,base,own_clips=decoded[identifier];own_table=struct.unpack_from('<I',data,32)[0]
        enemy_flags=[raw[word(word(section+20)+4*i)+1] for i in range(len(clips))]
        targets=[];reactions=[]
        for home in enemy_homes:
            targets.append(dict(unhurt=action_samples(data,offset,own_table,base,own_clips,homes[index],home,[1,4],return_pose=own_clips[9][-1][0])[:timing['release_tick']-1],after_hit=action_samples(data,offset,own_table,base,own_clips,homes[index],home,[1,4],initial_offset=(0,-2),return_pose=own_clips[9][-1][0])[:timing['release_tick']-1]))
            reactions.append(action_samples(data,offset,own_table,base,clips,home,home,[2],animation_flags=enemy_flags)[:timing['target_release_delay']])
        extra_attacks.append(dict(id=identifier,targets=targets,target_hurt=reactions))
    repeated_hurt=[]
    for index in range(2):
        data,offset,base,own_clips=decoded[actors[index]['id']]
        flags=[data[struct.unpack_from('<I',data,struct.unpack_from('<I',data,offset+20)[0]+4*i)[0]+1] for i in range(len(own_clips))]
        repeated_hurt.append(action_samples(raw,section,table,encounters.BASE,own_clips,homes[index],homes[index],[2],animation_flags=flags,initial_offset=(0,-2))[:36])
    scene=dict(schema='suikoden-world-battle-art/13',region='region_c',encounter=encounter['id'],atlas='actors.png',background='floor.png',atlas_width=atlas.image.width,atlas_height=atlas.y+atlas.row_height,actors=actors,scenery=scenery,formation_slots=[world_position(home) for home in homes],enemy_positions=encounter['positions'],camera=dict(transform=[[v/4096 for v in rotation[i*3:i*3+3]]+[translation[i]] for i in range(3)],focal_length=geometry.PROJ_H*1.44,center_x=320,center_y=202),sprite_scale=geometry.battle_scale_q12()/4096*1.44,medicine_particles=[],c_tracks=dict(hero_attacks=hero_attacks,projectile_start_tick=start,projectiles=projectiles,misses=dict(dodges=dodges,projectiles=missed_projectiles),low_hp=low_hp,extra_party_attacks=extra_attacks,repeated_hurt=repeated_hurt))
    output.mkdir(parents=True,exist_ok=True);floor.save(output/'floor.png');atlas.save(output/'actors.png')
    # Compact temporal samples stay within the existing bounded scene loader.
    encoded=json.dumps(scene,separators=(',',':'))+'\n'
    if len(encoded.encode())>512*1024:raise ValueError('C scene exceeds bounded runtime loader')
    (output/'scene.json').write_text(encoded)
    provenance=dict(schema='suikoden-world-battle-art-proof/2',status='candidate',sources=sources,producer='kit/tools/export_world_battle.py export_c',decoder='section_art/ground_tiles; lzss.decode_strict v2.0.0; C scripts1/2/4/6, party ordinary scripts1/4 and dodge3, retained hit offsets; descriptor hotpoints; named Q12 linear projectile samples',actors=proof,ground=ground_proof,heightfield=dict(across=across,down=down,vertices=vertices,tiles=tiles),scenery=dict(**scenery_proof,records_offset=records_offset,count=count),limits=['unlit source terrain; fixed camera crop/zoom and port billboards/shadows','five eligible ordinary attackers in the initial six-member roster; back-row short-range Viktor Defend; direct Gremio KO/low-HP Defend and source front/rear promotion; critical impacts/white/camera require spell-scenes39 bindings and misses require world-battle26 dodge data; interception/counters, protection, rune/item/unite presentation and other initial formations remain unsupported','damage/MISS popups, death palette flashing and native audio not reproduced'],outputs={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('scene.json','actors.png','floor.png')},native_launched=False,media_accepted=False,promoted=False)
    (output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    return scene,provenance


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--region',choices=('b','c','c-actors'),default='b')
    parser.add_argument('--journey',type=Path,default=ROOT/'kit/work/build/journey')
    args=parser.parse_args();output=args.output or ROOT/'kit/work/build'/('world-battle-art' if args.region=='b' else 'world-c-battle-art')
    scene,proof=export_c_actors(args.journey,args.output or ROOT/'kit/work/build/world_c_actors') if args.region=='c-actors' else (export if args.region=='b' else export_c)(output)
    if args.region=='c-actors':print(f"Exported {len(scene['actor_content']['encounters'])} source C actor formations; candidate only")
    else:print(f"Exported {scene['encounter']} candidate: {len(scene['actors'])} actor atlases; no promotion")
