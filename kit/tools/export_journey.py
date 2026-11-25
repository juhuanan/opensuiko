#!/usr/bin/env python3
"""Connected village / Great Forest episode candidate; original inputs stay in Python."""
import argparse
import copy
import json
import struct
from export_battle_audio import encounter_music
import journey_battle
import preparation
import character_table
from pathlib import Path
from PIL import Image
import export_first_room as field
import export_demo_batch as combat
import area_scene as scene
from psx_vram import rgb555_to_rgb888
from war_text import decode

ROOT = Path(__file__).resolve().parents[2]
ROOMS = {0:'vb6_village',1:'vb6_forest_edge',2:'vb6_forest_paths',3:'vb6_forest_crossing',4:'vb6_forest_bend',5:'vb6_forest_clearing',6:'vb6_kobold_village',10:'vb6_blacksmith'}

def field_event_bindings():
    names={'Hero','Gremio','Pahn','Viktor','Yam Koo','Tai Ho','Maas'}
    records=[dict(id=preparation.stable_id(row['name']),source_character=row['id'])
             for row in character_table.records() if row['name'] in names]
    assert len(records)==len(names) and len({row['source_character'] for row in records})==len(names)
    return dict(schema='suikoden-field-event-party/1',records=records,
                provenance=dict(source=field.source('SLUS_002.92')[1],decoder='character_table.records; preparation.stable_id',
                                consumer='SLUS_002.92 0x80017544; MAIN area prefix 0x80139CAC/0x80139D20/0x80139DF4',
                                scope='Existing supported party identities only; not recruitment or canonical initial party'))

def maas_recruitment(content):
    """Named first-join state; catalogue availability never satisfies the story gate."""
    import item_tables
    seed=next(row for row in character_table.records() if row['id']==70)
    data,_=field.source('/VB6.BIN')
    predicate=scene.entities(data,scene.room_record(data,10))[3]['stream_offsets'][1]
    assert data[predicate:predicate+4]==bytes.fromhex('114614ff')
    commit=data[0x35D19:0x35D21]
    assert commit[:5]==bytes.fromhex('45464b0046') and commit[6:]==bytes.fromhex('4215')
    profile=next(row for row in content['party'] if row['id']=='maas')
    assert (seed['inventory_count'],seed['inventory'][0],seed['rune_id'],seed['status']) == (1,dict(id=11,slot_flags=2,uses=0),0,0)
    gear=next(row for row in item_tables.items() if row['id']==11)
    item=preparation.stable_id(gear['name'])
    body=next(i for i,row in enumerate(content['systems']['equipment']) if row['id']==item)
    capacity=[sum(seed['stats'][4]>threshold for threshold in row) for row in content['systems']['magic_thresholds']]
    owned=dict(member=dict(id='maas',name=seed['name'],hp=seed['hp_current'],max_hp=seed['hp_max'],
        status='healthy',rune_charges=seed['spell_charges'],max_rune_charges=capacity,
        inventory=dict(slots=[dict(id=item,uses=0)]+[None]*8)),
        level=seed['level'],experience=seed['experience'],stats=profile['stats'],
        weapon_level=seed['weapon_level'],loadout=dict(body=body),rune=None)
    return dict(schema='suikoden-recruitment/1',member='maas',minimum_tier=data[predicate+4],level_advances=commit[5],seed=owned)

def maas_conversation(data, weapon_limit):
    tables=scene.ptr_at(data,scene.root(data)+20)
    table=scene.ptr_at(data,tables+2*4)
    offsets=[scene.ptr_at(data,table+4*i) for i in range(1,5)]
    intro,choices,accepted,declined=offsets
    # MAIN control06/selector1 substitutes the eight-glyph castle name, not END.
    end=data.index(0,accepted)
    marker=data.index(bytes((6,1)),accepted,end)
    assert data[accepted:marker].count(6)==0
    joined=scene.ptr_at(data,scene.ptr_at(data,tables+3*4)+4)
    entity=scene.entities(data,scene.room_record(data,10))[3]
    assert data[entity['stream_offsets'][1]:entity['stream_offsets'][1]+8]==bytes.fromhex('114614ff01050600')
    return dict(id='maas',name='Maas',x=entity['x_half']*8,y=entity['y_half']*8,
        pages=[p.strip() for p in decode(data,intro)[0].split('[---]')],
        service='blacksmith',weapon_limit=weapon_limit,minimum_recruitment_tier=1,
        hidden_by='maas_recruited',absent_by='maas_recruitment_blocked',
        recruitment=dict(choices=decode(data,choices)[0].splitlines(),
            accepted_prefix=decode(data,accepted,length=marker-accepted)[0],
            accepted_suffix=decode(data,marker+2)[0],
            declined=[p.strip() for p in decode(data,declined)[0].split('[---]')],joined=decode(data,joined)[0]))

def transition(data, number, entry_index, prefix=b''):
    entry=scene.entities(data,scene.room_record(data,number))[entry_index]
    predicate,stream=entry['stream_offsets'][1:]
    raw=data[predicate:predicate+12]
    assert raw[0]==11
    rect=dict(x=raw[1]*8,y=0,w=(raw[2]-raw[1]+1)*8,h=384)
    if raw[3]==12:
        assert raw[6]==6 or raw[6:9]==bytes.fromhex('04 00 06')
        rect.update(y=raw[4]*8,h=(raw[5]-raw[4]+1)*8)
        if raw[6]==4:
            assert combat.maindec.mword(0x80171708)==0x1000
            rect['direction']='up'
    else: assert raw[3]==6
    assert data[stream:stream+len(prefix)]==prefix
    op,target,x,y,end=data[stream+len(prefix):stream+len(prefix)+5]
    assert op==3 and end==253 and target in ROOMS
    return dict(**rect,room=ROOMS[target],spawn_x=x*8,spawn_y=y*8),dict(room=number,entity=entry_index,predicate=predicate,stream=stream,prefix=prefix.hex())

def export(output, include_unites=True):
    output=Path(output)
    if ROOT/'kit/work/accepted' in (output.resolve(),*output.resolve().parents):raise ValueError('candidate output only')
    package=field.export(output)
    package["schema"]="suikoden-room/7"
    battle=combat.export(output/'battle', roster_override=[(8,'hero','Hero',100,35,23,28,24),(2,'gremio','Gremio',120,31,27,24,20),(6,'pahn','Pahn',150,41,28,22,18),(35,'viktor','Viktor',155,44,26,21,20),(38,'yam_koo','Yam Koo',105,33,24,29,26),(32,'tai_ho','Tai Ho',110,36,24,28,27)])
    # Fixed framing leaves room for both stages of Fisherman's native approach.
    battle['camera']['focal_length']*=0.8
    battle['camera']['center_x']+=48
    battle['camera']['center_y']+=42
    battle['sprite_scale']*=0.8
    battle['schema']='suikoden-battle-trial/33'
    import export_world_travel
    battle['protection'], protection_proof = export_world_travel.protection_export()
    battle['initial_party']=[p['id'] for p in battle['party']]
    battle['systems']['additional_unites']=[dict(name='Fisherman attack',members=['tai_ho','yam_koo'],power=3,recovery_rounds=1)]
    for index,rune,magic in ((0,'fire',65),(1,'flowing',145),(4,'wind',115)):
        battle['party'][index]['rune']=rune
        battle['party'][index]['stats']['magic']=magic
    area,_=field.source('/A_DATA.BIN')
    _,_,directory,_=combat.trial.encounters.chain(area)
    enemy_table=struct.unpack_from('<I',area,directory-combat.trial.encounters.BASE+12)[0]
    ground,_=combat.trial.ground_tiles(area,directory)
    vertices,across,down,tiles=combat.trial.visuals.battle_ground_mesh(area)
    battle['ground']={'across':across,'down':down,'vertices':[combat.trial.world_position(v) for v in vertices],'tiles':[int(v) for v in tiles]}
    pixels,mask=combat.trial.visuals.render_ground(ground,vertices,across,down,tiles,H=combat.trial.visuals.PROJ_H*0.576,screen_offset=(24,38))
    background=Image.new('RGB',combat.trial.visuals.SCREEN);background.paste(pixels,(0,0),mask);background.save(output/'battle/floor.png')
    ground.save(output/'battle/ground.png')
    actor_atlas=field.Atlas()
    with Image.open(output/'battle/actors.png') as image:
        actor_atlas.image=Image.new('RGBA',(4096,4096));actor_atlas.image.paste(image,(0,0));actor_atlas.y=image.height+1
    sections, errors = combat.trial.enemy_sprites.parse_sections(area)
    if errors: raise ValueError(errors)
    by_offset = {s['header_offset']: s for s in sections}
    enemy_proof = []
    for native_id, stable_id in ((3, 'crow'), (5, 'red_soldier_ant'), (2, 'mosquito')):
        profile, proof = combat.trial.enemy_profile(area, enemy_table, native_id, stable_id, actor_atlas, by_offset)
        address = combat.trial.encounters.BASE + proof['record_offset']
        profile['stats']['magic'], profile['stats']['luck'] = struct.unpack_from('<2H', area, proof['record_offset']+28)
        proof.update(decision_callback=f"0x{struct.unpack_from('<I',area,proof['record_offset']+48)[0]:08X}",original_name=profile['name'])
        battle['enemies'].append(profile); enemy_proof.append(proof)
    import item_tables
    from export_shop import consumables
    item_ids={row['id']:preparation.stable_id(row['name']) for row in item_tables.items()}
    item_uses={row['id']:row['uses'] for row in consumables()[0]}
    for enemy in battle['enemies']:
        index = journey_battle.ENEMY_IDS[enemy['id']]
        address=struct.unpack_from('<I',area,enemy_table-combat.trial.encounters.BASE+4*index)[0]
        raw=area[address-combat.trial.encounters.BASE:address-combat.trial.encounters.BASE+64]
        enemy['drops']=[dict(item=item_ids.get(raw[54+2*i]),uses=item_uses.get(item_ids.get(raw[54+2*i]),0),rate=raw[55+2*i],identified=raw[54+2*i] not in (114,115,120)) for i in range(3)]
        assert all(raw[54+2*i]==0 or raw[54+2*i] in item_ids for i in range(3))
    journey_battle.export_rules(battle,area,enemy_table)
    bonbon = next(e for e in battle['enemies'] if e['id']=='bonbon')
    bonbon_record=struct.unpack_from('<I',area,enemy_table-combat.trial.encounters.BASE+4)[0]-combat.trial.encounters.BASE
    bonbon['motion']=journey_battle.bonbon_motion(area,bonbon_record)
    # shortcut: retain the candidate's static pose until enemy animation/hit/KO tracks are exported.
    bonbon['attack']=[dict(pose=bonbon['sprite'],ticks=bonbon['motion']['duration'])]
    placements = combat.trial.battle_placement.area_encounters(area)
    _, _, _, selectors = combat.trial.encounters.chain(area)
    _, selected = combat.trial.encounters.selectors_table(area, selectors)
    for placement in placements['encounters']:
        number=placement['index']
        if any(row['id']==f'area_a_{number}' for row in battle['encounters']):continue
        title={4:'Crows',6:'Red Soldier Ant',9:'Boar and Crows'}.get(number)
        address = selected[number-1]
        native = [v for v in area[address-combat.trial.encounters.BASE+4:address-combat.trial.encounters.BASE+10] if v]
        names = {v:k for k,v in journey_battle.ENEMY_IDS.items()}
        roster = [names[v] for v in native]
        if title is None:title=' / '.join(dict.fromkeys(next(e['name'] for e in battle['enemies'] if e['id']==id) for id in roster))
        levels = [next(e['level'] for e in battle['enemies'] if e['id']==id) for id in roster]
        award = combat.trial.exp_award.award_pool([5]*6,[0]*6,levels)[1]
        flags = struct.unpack_from('<I',area,address-combat.trial.encounters.BASE+12)[0]
        battle['encounters'].append(dict(id=f'area_a_{number}',title=title,enemies=roster,
            **encounter_music(flags),
            experience_per_member=award,escape_allowed=not bool(flags&0x80000000),
            positions=[combat.trial.world_position(slot['world']) for slot in placements['encounters'][number-1]['slots']],
            source_slots=[slot['slot'] for slot in placements['encounters'][number-1]['slots']],
            enemy_rows=['front' if slot['slot']<3 else 'back' for slot in placements['encounters'][number-1]['slots']]))
    records={r['id']:r for r in character_table.records()}
    # Catalogue availability does not recruit Maas or change the prototype party.
    seed=records[70]
    actor,provenance=field.source('/'+seed['sprite_file'])
    _,seed_provenance=field.source('SLUS_002.92')
    poses,animations,proof=combat.trial.section_art(actor,struct.unpack_from('<I',actor,36)[0])
    frames,motion=combat.trial.attack_schedule(actor,poses,animations,actor_atlas)
    weapon_address=combat.maindec.mword(0x80165890+4*seed['weapon_id'])
    range_code=combat.maindec.body()[weapon_address-combat.maindec.MBASE+0x56]
    battle['party'].append(dict(id='maas',name=seed['name'],max_hp=seed['hp_max'],level=seed['level'],
        stats=dict(zip(('attack','skill','defense','speed','magic','luck'),seed['stats'],strict=True)),
        growth=seed['growth'],weapon_range={1:'short',2:'long',3:'medium'}[range_code],
        sprite=combat.trial.pack_pose(actor_atlas,poses[animations[0][0][0]]),
        foot_offset_y=combat.trial.foot_offset_y(poses[animations[0][0][0]]),attack=frames,motion=motion,rune=None))
    tracks=[]
    for profile,native_id in zip(battle['party'],(8,2,6,35,38,32,70),strict=True):
        actor,provenance=field.source('/'+records[native_id]['sprite_file'])
        poses,animations,proof=combat.trial.section_art(actor,struct.unpack_from('<I',actor,36)[0])
        unite='talisman' if native_id in (2,6) else 'fisherman' if native_id in (32,38) else None
        profile.update(journey_battle.export_tracks(actor,poses,animations,actor_atlas,unite))
        if unite:journey_battle.bind_unite_scene(profile, 0 if unite == 'talisman' else 1)
        tracks.append(dict(id=profile['id'],source=provenance,**proof,cast_descriptor='MAIN.EXE:0x8016C194',unite_script=9 if unite else None))
        if unite:
            tracks[-1]['trail']=dict(helper='MAIN.EXE:0x800F14B4',allocation_animation=5,
                allocation_pose=animations[5][0][0],modulation='RGB555 channels times source RGB8, divide128, clamp31',
                blend='average',**{k:profile['unite_scenes'][-1]['track']['trail'][k] for k in ('start','stop')})
    import export_physical_runes
    import export_counter_actors
    import export_enemy_magic
    physical_packet,physical_proof=export_physical_runes.build(include_later=include_unites)
    counter_packet,counter_proof=export_counter_actors.build(include_area_a=include_unites,include_later=include_unites)
    if include_unites and not {'bonbon','wild_boar','crow','red_soldier_ant','mosquito'} <= {row['id'] for row in counter_packet['melee']['enemies']}:
        raise ValueError('Area A source actor binding missing')
    graphic_packet=copy.deepcopy(physical_packet)
    export_physical_runes.merge_libraries(graphic_packet,counter_packet)
    magic_plan,_,magic_proof=export_enemy_magic.build()
    export_physical_runes.merge_libraries(graphic_packet,dict(programs=magic_plan['programs'],animations=dict(schema='suikoden-actor-animations/1',resources=[magic_plan['resource']])))
    graphic_ids={p['id'] for p in battle['party']+battle['enemies']}
    if include_unites:graphic_ids.update(name for _,_,name in export_physical_runes.LATER_ENEMIES)
    graphic_ids.update(member for technique in physical_packet['techniques'] if technique['id']!='clone' for member in technique['members'])
    graphic_ids.update(member['id'] for member in counter_packet['parries']['defenders'])
    graphic_ids.add(magic_plan['id'])
    if counter_packet.get('cooperation'): graphic_ids.update(counter_packet['cooperation']['allies'])
    roots=export_counter_actors.graphic_roots(counter_packet)+[(magic_plan['id'],magic_plan['programs']['programs'][0]['id'])]
    battle['unite_graphics'],physical_art=export_physical_runes.graphics(graphic_packet,physical_proof,actor_atlas,graphic_ids,roots)
    item_art = journey_battle.append_item_art(battle, actor_atlas)
    actor_atlas.save(output/'battle/actors.png')
    battle_origin=json.loads((output/'battle/provenance.json').read_text())
    battle_origin['enemies'].extend(enemy_proof)
    battle_origin['preparation']=preparation.export(battle,(8,2,6,35,38,32,70))
    maas=battle['party'][-1]
    maas['stats']['attack']+=maas['weapon']['powers'][maas['weapon']['initial_level']-1]
    battle_origin['reserve_catalogue']=dict(id='maas',native_id=70,source=provenance,record_image_offset=seed['off'],
        record_source=seed_provenance,record_file_offset=2048+seed['off'],**proof,attack_scripts=[1,4],initially_owned=False,
        policy='Catalogue availability alone does not recruit Maas. Journey recruitment exports the owned template, worn coat and source join growth separately; canonical story prerequisites remain required.')
    battle_origin['connected_episode']=dict(exporter='export_journey.py v28 + journey_battle.py v9',tracks=tracks,
        rules='MAIN.EXE spell callbacks and 0x80125B28 elemental helper; A_DATA enemy callbacks and reward bytes; test_journey_battle.py',
        port_choices=['Authored initial party, levels, MGC and Fire/Flowing/Wind assignment; fields are explicitly exported.',
            'Caster gestures and both paired script-9 Unites use disc-derived poses, durations and leap stages; effect overlays and shadows remain port presentation.',
            'Front-first enemies follow the original chooser. At round boundaries living rear party members fill KO front vacancies in identity order; queued actions retain their owners.',
            'Poison uses source battle/field amounts and field recovery; the modern field invokes its service on each actual moving update; idle, collision and pause do not consume poison draws. Mosquito recipient script2 attempts source poison with raw threshold20 before its first wait.'])
    battle_origin['presentation']['framing_zoom']=0.576
    battle_origin['presentation']['screen_offset']=[24,38]
    battle_origin['schema']='suikoden-journey-battle-provenance/1'
    battle_origin['exporter']='export_journey.py v28 + journey_battle.py v9 + export_demo_batch.py v6'
    battle_origin['rules']['bonbon_motion']=('A_DATA record0x8009F3FC, script table0x8009F154, scripts1/2/4; shared actor playback with native12-tick approach and30-tick return' if include_unites else 'A_DATA record0x8009F3FC, script table0x8009F154, scripts1/4; native12-tick approach and30-tick return; static candidate pose remains')
    battle_origin['rules']['spells']='MAIN.EXE complete spell rules via journey_magic.py and spell_rules.py; elemental helper0x80125B28; independent callback checks in test_magic_expansion.py and test_journey_battle.py'
    battle_origin['rules']['expanded_magic']='journey_magic.py v1;12 damage callback operands, five enemy coefficients, Rain of Kindness300/cure, additive Fog/Clay bonuses and Copper Flesh; test_magic_expansion.py independently executes original consumers'
    battle_origin['rules']['enemy_choices']='A_DATA callbacks0x80080004/0x80080760 front,0x80080604 all rows; ordered49% acceptance scans. Ant0x80080ADC selects its double physical strike when floor(roll*100/32767)%100 >=77'
    battle_origin['rules']['drops']='A_DATA records0x8009F3FC/0x800A33DC/0x800A1A5C/0x800A5348 +0x36..0x3B; original chooser0x800E9940'
    battle_origin['rules']['revival_art']='MAIN.EXE descriptor0x8016C400 selects animation3/down and2/recovery; zero-rotation/unflipped packet endpoint sampling; source F-record flags/durations and independent VRAM checks across78 characters'
    battle_origin['rules']['fisherman']='Unite ID2, Tai Ho32/Yam Koo38;0x800F9920, two script9 tracks,0x800F9488 count2/multiplier30'
    battle_origin['port_choices']=battle_origin['connected_episode']['port_choices']+[
        'Starting party and encounter placements are authored; selected A_DATA rosters, enemy stats and reward tables are source-derived.',
        'The fixed camera framing and perspective-scaled contact shadows are port presentation. Bribe, native Free Will AI and spell-effect art/audio are outside this episode.',
        'Owned Bandanna/Headband are starting test inventory. Five gear slots and weapon upgrades are supported. Rune pieces and urn use remain outside this episode; rune-service placement and other passive/physical runes remain unfinished. Basic healing/cure items use the shared item catalog.']
    import export_unite_programs
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory(prefix='unite-programs-',dir=output) as temporary:
        _,program_proof=export_unite_programs.export(Path(temporary))
        shutil.copyfile(Path(temporary)/'unites.json',output/'battle/unites.json')
    battle_origin['unite_actor_programs']=program_proof
    battle_origin['physical_actor_programs']=physical_proof
    battle_origin['counter_actor_programs']=counter_proof
    battle_origin['protection']=protection_proof
    battle_origin['physical_graphics']=physical_art
    battle_origin['item_actor_art']=item_art
    with (output/'battle/unites.json').open() as stream:
        combined=export_physical_runes.combine(json.load(stream),physical_packet)
    combined=export_counter_actors.combine(combined,counter_packet)
    combined=export_enemy_magic.combine(combined,magic_plan)
    battle_origin['enemy_magic_programs']=magic_proof
    (output/'battle/unites.json').write_text(json.dumps(combined,separators=(',',':'))+'\n')
    (output/'battle/provenance.json').write_text(json.dumps(battle_origin,indent=2)+'\n')
    (output/'battle/trial.json').write_text(json.dumps(battle,indent=2)+'\n')
    import export_enemy_regional
    import export_spell_scenes
    hurt_ids=tuple(row['id'] for row in counter_packet['melee']['enemies'] if row['id'] not in export_spell_scenes.ENEMY_IDS)
    if include_unites:
        hurt_ids+=('beast_commander','killer_rabbit','ninja_master','dagon','whip_wolf','holly_fairy','sorcerer','siren','earth_golem')
        hurt_ids+=tuple(identifier for _,_,identifier in export_enemy_regional.RECIPIENTS)
    with tempfile.TemporaryDirectory(prefix='spell-scenes-',dir=output) as temporary:
        export_spell_scenes.export(output/'battle',Path(temporary),extra_hurt_ids=hurt_ids)
        for name in ('spell_effects.png','spells.json'):
            shutil.copyfile(Path(temporary)/name,output/'battle'/name)
        shutil.copyfile(Path(temporary)/'provenance.json',output/'battle/spells.provenance.json')
        battle=json.loads((Path(temporary)/'trial.json').read_text())
        (output/'battle/trial.json').write_text(json.dumps(battle,indent=2)+'\n')
    data,source=field.source('/VB6.BIN')
    atlas=field.Atlas()
    atlas.image=Image.new("RGBA",(4096,4096))
    previous=Image.open(output/'atlas.png').convert('RGBA')
    atlas.image.paste(previous,(0,0));atlas.y=previous.height+1
    origin=json.loads((output/'provenance.json').read_text())
    origin['journey']=dict(exporter='export_journey.py v4',source=source,room_links=[],rooms=[])
    for number in (1,2,3,4,5,6,10):
        rec=scene.room_record(data,number);sec=scene.section_off(data,rec['section'])
        animation=field.frame_table(data,sec)
        vram,materials=scene.load_scene_materials(data,sec,source)
        review,prims,meta=scene.scene_compose(data,number,vram,npc_entities={4,5} if number==2 else set())
        assert not meta['scenery']['unresolved']
        selected_entities={4,5} if number==2 else set()
        assert not any(row.get('entity') in selected_entities for row in meta['npc']['unresolved'])
        review.save(output/f'{ROOMS[number]}_review.png')
        draws=[]
        for key,section in (('primary',sec),('secondary',scene.section_off(data,rec['byte9']))):
            layer=meta[key];codes=struct.unpack_from(f"<{layer['w']*layer['h']}H",data,layer['offset'])
            mats=scene.load_map_materials(data,section,set(codes))
            image,_=scene.map_layer_image(data,layer['offset'],layer['w'],layer['h'],mats,rgb555_to_rgb888,semi_transparent=key=='secondary')
            draws.append(dict(rect=atlas.add(image),x=0,y=0,depth=scene.GROUND_DEPTH_ORIGIN-layer['tag']))
        for prim in prims:
            image=scene._prim_to_tile(prim,rgb555_to_rgb888)
            if image is None:continue
            draw=dict(rect=atlas.add(image),x=prim['left'],y=prim['top'],depth=scene.GROUND_DEPTH_ORIGIN-prim['tag'])
            if number==2 and prim.get('kind')=='npc' and prim.get('entity') in (4,5):draw['hidden_by']='forest_treasure_needle' if prim['entity']==4 else 'forest_treasure_water'
            if prim.get('kind')=='scenery' and prim['type'] in animation:
                draw['frames']=[]
                for frame,ticks in enumerate(animation[prim['type']]):
                    candidates,_=scene.scenery_primitives(data,sec,vram,0,frame,source)
                    variant=next(p for p in candidates if p['object']==prim['object'] and p['vertex']==prim['vertex'])
                    tile=scene._prim_to_tile(variant,rgb555_to_rgb888)
                    assert tile is not None
                    draw['frames'].append(dict(rect=atlas.add(tile),x=variant['left'],y=variant['top'],ticks=ticks))
            draws.append(draw)
        width,height,grid=field.walkable_grid(data,sec)
        room=dict(id=ROOMS[number],title='Blacksmith' if number==10 else 'Kobold village' if number==6 else 'Great Forest - '+{1:'edge',2:'branching paths',3:'crossing',4:'bend',5:'clearing'}[number],width=width*8,height=height*8,walkable=grid,draws=draws,npcs=[],exits=[])
        for index,prefix in ({1:((0,bytes.fromhex('41 33')),(1,b'')),2:tuple((i,b'') for i in range(4)),3:tuple((i,b'') for i in range(6)),4:tuple((i,b'') for i in range(4)),5:((0,b''),(1,b'')),6:((0,b''),),10:((0,b''),)}[number]):
            door,proof=transition(data,number,index,prefix)
            door['h']=min(door['h'],room['height']-door['y'])
            room['exits'].append(door);origin['journey']['room_links'].append(proof)
        if number==6:
            entity=scene.entities(data,rec)[1]
            predicate,stream=entity['stream_offsets'][1:]
            assert data[stream:stream+6]==bytes.fromhex('03 fb 02 3b 26 fd')
            assert data[predicate:predicate+4]==bytes.fromhex('0b 2d 2d 06')
            room['events']=[dict(id='kobold_world_exit',name='Kobold village world exit',x=360,y=0,w=8,h=height*8,
                flag='kobold_world_exit_reached',pages=['The road continues beyond the Kobold village.\nWorld travel is not available yet.'])]
            origin['journey']['kobold_exit']=dict(room=6,entity=1,predicate=predicate,stream=stream,
                region=2,world_coordinates=[59,38],omission='world-map travel; interior doors11/12/13 and conditional population await later episode work')
        if number==10:
            entity=scene.entities(data,rec)[6]
            stream=entity['stream_offsets'][2]
            assert data[stream:stream+4]==bytes.fromhex('43 03 02 fd')
            args=scene.ptr_at(data,scene.root(data)+16)
            context=scene.ptr_at(data,args+12+data[stream+2]*4)
            limit=data[scene.ptr_at(data,context)]
            greeting_offset=scene.ptr_at(data,context+4)
            greeting,_=decode(data,greeting_offset)
            room['npcs'].append(dict(id='forest_blacksmith',name='Blacksmith',x=entity['x_half']*8,y=entity['y_half']*8,pages=[greeting],service='blacksmith',weapon_limit=limit,marker='service'))
            room['npcs'].insert(0,maas_conversation(data,limit))
            origin['journey']['maas_recruitment']=dict(source=source,room=10,entity=3,
                predicate=0x35CB0,event=0x35CD4,commit=0x35D19,
                owned_record_source=seed_provenance,owned_record_file_offset=2048+records[70]['off'],
                parser='export_journey.py v8; character_table.py; preparation.py; war_text.py glyphs with MAIN nested castle control06/01',
                consumers=['MAIN.EXE:0x8013DB6C','MAIN.EXE:0x801396E0','MAIN.EXE:0x801390D8','MAIN.EXE:0x800C4ECC'],
                scope='Episode controller only; canonical tier/name acquisition, original actor/cue scheduling, world roster access and native review remain incomplete')
            origin['journey']['blacksmith']=dict(room=10,entity=6,stream=stream,context=context,greeting=greeting_offset,level_limit=limit,consumers=['MAIN.EXE:0x801397D0','MAIN.EXE:0x800D58A8','MAIN.EXE:0x800D629C'])
        if number==2:
            for entity,id,flag,item,uses in [(4,'forest_chest_needle','forest_treasure_needle','Needle',4),(5,'forest_chest_water','forest_treasure_water','Water rune piece',0)]:
                e=scene.entities(data,rec)[entity]
                room['npcs'].append(dict(id=id,name='Chest',marker='treasure',x=e['x_half']*8,y=e['y_half']*8,hidden_by=flag,pages=[f'Found {item}'+(f' ({uses} uses).' if uses else '.')]))
        elif number==1:
            room['events']=[dict(id='forest_entered',name='Great Forest',x=24,y=0,w=8,h=height*8,flag='forest_entered',pages=['A forest path lies ahead.'])]
        package['rooms'].append(room)
        origin['journey']['rooms'].append(dict(room=number,record=rec,materials=materials,omitted_npcs=meta['npc']['unresolved'],omitted_entities=[i for i,e in enumerate(scene.entities(data,rec)) if e['id'] and i not in selected_entities]))
    village=next(r for r in package['rooms'] if r['id']=='vb6_village')
    door,proof=transition(data,0,0,bytes.fromhex('41 6c'))
    village['exits'].append(door);origin['journey']['room_links'].append(proof)
    smith_door,smith_proof=transition(data,0,5,bytes.fromhex('11 80 00 0e 0a 02'))
    village['exits'].append(smith_door);origin['journey']['room_links'].append(smith_proof)
    tables=scene.ptr_at(data,scene.root(data)+20);table=scene.ptr_at(data,tables)
    pages=[];texts=[]
    for index in (1,2):
        address=scene.ptr_at(data,table+4*index);text,_=decode(data,address)
        pages.extend(p.strip() for p in text.split('[---]'));texts.append(dict(table=0,index=index,offset=address))
    village['events'].append(dict(id='elf_sighting',name='Forest encounter',x=240,y=296,w=56,h=8,flag='forest_elf_seen',requires='heard_forest_warning',pages=pages))
    origin['journey']['elf_dialogue']=texts
    origin['port_choices'].extend(['Connected episode uses source room0..5 links, collision and dialogue, with an authored six-member starting party (including Tai Ho/Yam Koo), Hero Fire/MGC65, Gremio Flowing/MGC145, Yam Koo Wind/MGC115, and objective sequence.',
        'Elf encounter retains source dialogue but omits original actor movement and uses the chapter warning as its explicit starting prerequisite.',
        'Blacksmith room10 uses the source counter and level-five cap; a named UI service marker replaces its unexported actor choreography. Recruitment-dependent visibility is outside this episode.',
        'Forest rooms1..5 retain their native maze links and scenery animation durations; the Kobold-village transition is outside this episode. Encounters use the independently checked A_DATA test rosters, not an asserted canonical VB6 encounter schedule.',
        'Treasure event spots use authored chest-shaped UI markers because the original appearance script is not exported; markers disappear after the persistent source-linked flag; treasure insertion is atomic and a full party inventory keeps the chest closed.'])
    config=dict(schema='suikoden-journey/2',title='Suikoden',battle='battle/trial.json',recruitment=maas_recruitment(battle),
        encounters=[dict(id='forest_edge_bonbons',room='vb6_forest_edge',x=200,y=0,w=16,h=384,encounter='area_a_2',flag='forest_battle_one_won'),
                    dict(id='forest_paths_crows',room='vb6_forest_paths',x=160,y=0,w=16,h=384,encounter='area_a_4',flag='forest_battle_two_won'),
                    dict(id='forest_clearing_ant',room='vb6_forest_clearing',x=120,y=0,w=16,h=256,encounter='area_a_6',flag='forest_battle_three_won')],
        treasures=[dict(npc='forest_chest_needle',room='vb6_forest_paths',item='needle',uses=4,flag='forest_treasure_needle'),
                   dict(npc='forest_chest_water',room='vb6_forest_paths',item='water_rune_piece',uses=0,flag='forest_treasure_water')])
    atlas.save(output/'atlas.png')
    from export_field_dialogue import export_art
    export_art(output/'field-ui')
    for name,value in [('room.json',package),('provenance.json',origin),('journey.json',config)]:
        (output/name).write_text(json.dumps(value,indent=2)+'\n')
    if include_unites:
        import assemble_battle_review
        import export_unite_review
        with tempfile.TemporaryDirectory(prefix='journey-unites-',dir=output.parent) as temporary:
            review=Path(temporary)/'review'
            review_proof=export_unite_review.export(review,include_flash=True,include_master=True,include_couple=True,include_warriors=True,include_martial=True,include_beat=True,include_trick=True,base=output,scenario_records=(10,14,15,16,27,29,31),extra_hurt_ids=hurt_ids)
            _,ranged_bindings,ranged_proof,graphic_proof=assemble_battle_review.add_ranged_assets(output)
            flash=assemble_battle_review.add_flash_assets(output,review,review_proof)
            master=assemble_battle_review.add_master_assets(output,review,review_proof)
            linked=assemble_battle_review.add_couple_assets(output,review,review_proof,include_warriors=True)
            martial=assemble_battle_review.add_martial_assets(output,review,review_proof)
            beat=assemble_battle_review.add_beat_assets(output,review,review_proof)
            trick=assemble_battle_review.add_trick_assets(output,review,review_proof)
            with Image.open(output/'battle/actors.png') as image:
                previous=image.convert('RGBA')
            if previous.width > 4096 or previous.height >= 4096:
                raise ValueError('physical member profiles exceed the runtime atlas')
            actor_atlas=field.Atlas()
            actor_atlas.image=Image.new('RGBA',(4096,4096))
            actor_atlas.image.paste(previous,(0,0)); actor_atlas.y=previous.height+1
            battle=json.loads((output/'battle/trial.json').read_text())
            physical_profiles=journey_battle.append_physical_profiles(battle,actor_atlas,physical_packet)
            actor_atlas.save(output/'battle/actors.png')
            (output/'battle/trial.json').write_text(json.dumps(battle,separators=(',',':'))+'\n')
            unite_members=assemble_battle_review.add_unite_member_assets(output,review,review_proof)
            couple=dict(linked, members=[row for row in linked['members'] if row['id'] in ('eileen','lepant')],
                        attacks=[row for row in linked['attacks'] if row['id'] in ('eileen','lepant')])
            warriors=dict(linked, members=[row for row in linked['members'] if row['id'] in ('tengaar','hix')],
                          attacks=[row for row in linked['attacks'] if row['id'] in ('tengaar','hix')])
        import battle_actor_atlas
        battle_actor_atlas.compact_package(output/'battle','before_later_enemies')
        battle=json.loads((output/'battle/trial.json').read_text())
        with Image.open(output/'battle/actors.png') as image:
            actor_atlas=field.Atlas()
            actor_atlas.image=Image.new('RGBA',(4096,4096))
            actor_atlas.image.paste(image,(0,0));actor_atlas.y=image.height+1
        later_enemies=journey_battle.append_later_enemies(battle,actor_atlas)
        actor_atlas.save(output/'battle/actors.png')
        for enemy in battle['enemies']:
            if enemy['id'] in ('bonbon','wild_boar','crow','mosquito'):enemy['action_policy']='source_melee'
        (output/'battle/trial.json').write_text(json.dumps(battle,separators=(',',':'))+'\n')
        actor_path=output/'battle/unites.json'
        actors=json.loads(actor_path.read_text())
        ant=next(row for row in actors['counter']['melee']['enemies'] if row['id']=='red_soldier_ant')
        if 'special' not in ant:raise ValueError('Ant special actor binding missing')
        actors['schema']='suikoden-unite-actors/30'
        actor_path.write_text(json.dumps(actors,separators=(',',':'))+'\n')
        import unite_reaction_assets
        import battle_unite_camera
        spell_path=output/'battle/spells.json'
        spells=json.loads(spell_path.read_text())
        source_rows=battle_unite_camera.report()
        reactions=unite_reaction_assets.reactions(source_rows,include_sounds=True)
        extra_reactions=[row for row in spells['unite_reactions'] if row['record'] in (27,29)]
        reactions=[r for r in reactions if r['record']!=27]
        if [{key:value for key,value in row.items() if key!='sounds'} for row in reactions] != [row for row in spells['unite_reactions'] if row['record'] not in (27,29)]:
            raise ValueError('recipient sound export changed existing reaction behavior')
        reactions.extend(extra_reactions)
        spells['unite_reactions']=reactions
        spells['schema']='suikoden-spell-scenes/50'
        spell_path.write_text(json.dumps(spells,separators=(',',':'))+'\n')
        sound_sources={(row['index'],row.get('variant',0)):row['target_reaction'] for row in unite_reaction_assets.reaction_rows(source_rows)}
        import unite_martial_controller
        sound_sources.update({(29,index+1):row for index,row in enumerate(unite_martial_controller.recipient_programs()['source'])})
        import unite_beat_controller
        first,final=unite_beat_controller.recipient_programs()['source']
        sound_sources.update({(27,1):first,(27,0):final})
        spell_proof_path=output/'battle/spells.provenance.json'
        spell_proof=json.loads(spell_proof_path.read_text())
        spell_proof['ordinary_dust']=export_spell_scenes.add_ordinary_dust(output/'battle')
        spell_proof['recipient_sounds']=[dict(record=row['record'],variant=row.get('variant',0),events=row['sounds'],
            source=sound_sources[(row['record'],row.get('variant',0))]) for row in reactions if row.get('sounds')]
        spell_proof_path.write_text(json.dumps(spell_proof,indent=2)+'\n')
        battle_origin=json.loads((output/'battle/provenance.json').read_text())
        party_melee=assemble_battle_review.add_party_melee_assets(output)
        import export_enemy_orders
        battle=json.loads((output/'battle/trial.json').read_text())
        actors=json.loads(actor_path.read_text())
        with Image.open(output/'battle/actors.png') as image:
            commander_atlas=field.Atlas()
            commander_atlas.image=Image.new('RGBA',(4096,4096))
            commander_atlas.image.paste(image,(0,0));commander_atlas.y=image.height+1
        commander=export_enemy_orders.append_content(battle,actors,commander_atlas)
        import export_enemy_rabbit
        rabbit=export_enemy_rabbit.append_content(battle,actors,commander_atlas)
        import export_enemy_ninja
        ninja=export_enemy_ninja.append_content(battle,actors,commander_atlas)
        import export_enemy_dagon
        dagon=export_enemy_dagon.append_content(battle,actors,commander_atlas)
        import export_enemy_whip_wolf
        whip_wolf=export_enemy_whip_wolf.append_content(battle,actors,commander_atlas)
        import export_enemy_holly_fairy
        holly_fairy=export_enemy_holly_fairy.append_content(battle,actors,commander_atlas)
        import export_enemy_area_magic
        area_magic=export_enemy_area_magic.append_content(battle,actors,commander_atlas)
        regional=export_enemy_regional.append_content(battle,actors,commander_atlas)
        commander_atlas.save(output/'battle/actors.png')
        (output/'battle/trial.json').write_text(json.dumps(battle,separators=(',',':'))+'\n')
        actor_path.write_text(json.dumps(actors,separators=(',',':'))+'\n')
        battle_origin['commander']=commander
        battle_origin['rabbit']=rabbit
        battle_origin['ninja']=ninja
        battle_origin['dagon']=dagon
        battle_origin['whip_wolf']=whip_wolf
        battle_origin['holly_fairy']=holly_fairy
        battle_origin['area_magic']=area_magic
        battle_origin['regional_enemies']=regional
        battle_origin['party_melee']=party_melee
        battle_origin['later_enemy_catalogue']=later_enemies
        battle_origin['physical_member_profiles']=physical_profiles
        battle_origin['unite_member_profiles']=unite_members
        battle_origin.update(party_ranged_actors=ranged_proof,party_ranged_bindings=ranged_bindings,
            party_ranged_graphics=graphic_proof,flash=flash,master_pupil=master,couple=couple,warriors=warriors,martial_arts=martial,beat_em_up=beat,trick=trick)
        (output/'battle/provenance.json').write_text(json.dumps(battle_origin,indent=2)+'\n')
        battle_actor_atlas.compact_package(output/'battle','complete_journey')
    import hashlib
    files=('room.json','journey.json','atlas.png','provenance.json','battle/trial.json','battle/actors.png','battle/floor.png','battle/ground.png','battle/provenance.json','battle/unites.json','battle/spell_effects.png','battle/spells.json','battle/spells.provenance.json','field-ui/ui.json','field-ui/atlas.png','field-ui/provenance.json')
    manifest=dict(schema='suikoden-journey-manifest/1',status='candidate',files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in files})
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return package,config,json.loads((output/'battle/trial.json').read_text())

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'kit/work/build/journey');a=p.parse_args()
    package,_,_=export(a.out);print(f"Exported connected journey: {len(package['rooms'])} rooms; candidate only")
