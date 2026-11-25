"""Source B/C foot-travel and simulation battle data; no playback or promotion."""
from pathlib import Path
import json
import struct
from export_battle_audio import encounter_music
import re
import lzss
import area_encounter_tables as encounters
import battle_placement
import maindec
import war_text
import world_map_render
from export_first_room import source, village_content

ROOT=Path(__file__).resolve().parents[2]


def export(region='b'):
    if region not in ('b','c'):raise ValueError('unsupported travel region')
    main,main_origin=source('MAIN.EXE')
    assert main[maindec.EXE_HEADER:]==maindec.body()
    data,origin=source(f'/{region.upper()}_DATA.BIN')
    plane=world_map_render.parse_worldmap(data)
    threshold=struct.unpack_from('<H',data,plane['d_off']+4)[0]
    _,_,directory,selectors=encounters.chain(data)
    enemy_table=struct.unpack_from('<I',data,directory-encounters.BASE+12)[0]-encounters.BASE
    placements=battle_placement.area_encounters(data)['encounters']
    roster={}
    for encounter in placements:
        for slot in encounter['slots']:
            native=slot['enemy_id'];offset=slot['stats_offset']
            name=war_text.decode(data[offset:offset+64],length=16)[0]
            identifier=re.sub('[^a-z0-9]+','_',name.lower()).strip('_')
            roster[native]=dict(id=identifier,name=name,level=data[offset+16])
    # Distinct local species may share the displayed name (three C-region Kobolds).
    names=[enemy['id'] for enemy in roster.values()]
    for native,enemy in roster.items():
        if names.count(enemy['id'])>1:enemy['id']+=f'_type_{native}'
    candidates=[]
    for encounter in placements:
        ids=[roster[native]['id'] if native else None for native in encounter['roster']]
        candidates.append(dict(id=f"world_{region}_encounter_{encounter['index']}",enemies=ids,enemy_level_sum=sum(roster[native]['level'] for native in encounter['roster'] if native)))
    region_index=1 if region=='b' else 2
    entry_index=5 if region=='b' else 6
    room='vb6_village' if region=='b' else 'vb6_kobold_village'
    points=[];table=maindec.mword(0x80170064+4*region_index)
    for index in range(64):
        offset=table-maindec.MBASE+index*14
        raw=maindec.body()[offset:offset+14]
        if raw[0]==8:break
        x,y=struct.unpack_from('<2H',raw,2)
        if x==y==0:continue
        points.append(dict(id=room if index==entry_index else f'world_{region}_point_{index}',x=x,y=y,destination=('village' if region=='b' else room) if index==entry_index else None,spawn_x=raw[6]*8,spawn_y=raw[7]*8))
    else:raise ValueError('world point table has no terminator')
    if region=='b':
        village=next(point for point in points if point['id']=='vb6_village')
        assert (village['x'],village['y'],village['spawn_x'],village['spawn_y'])==(86,83,264,344)
    area,area_proof=source('/VB6.BIN')
    if region=='c':
        import area_scene
        entity=area_scene.entities(area,area_scene.room_record(area,6))[1]
        predicate,stream=entity['stream_offsets'][1:]
        assert area[predicate:predicate+4]==bytes.fromhex('0b2d2d06')
        assert area[stream:stream+6]==bytes.fromhex('03fb023b26fd')
        entry=next(point for point in points if point['id']==room)
        assert (entry['x'],entry['y'],entry['spawn_x'],entry['spawn_y'])==(59,36,352,216)
        result=dict(schema='suikoden-world-travel/2',id='region_c',width=plane['w'],height=plane['h'],walkable=''.join('1' if code>=threshold else '0' for code in plane['codes']),points=points,return_camera=dict(x=area[stream+3],y=area[stream+4]),field_room=room,field_exit=dict(x=360,y=0,w=8,h=384),field_exit_event='kobold_world_exit',enemies=list(roster.values()),encounters=candidates)
        proof=dict(schema='suikoden-world-travel-proof/2',producer='kit/tools/export_world_travel.py export(c)',decoder=f'world_map_render.py parse_worldmap; lzss.py {lzss.__version__}',sources=[main_origin,origin,area_proof],world_table=hex(table),threshold=threshold,selectors=hex(selectors),exit_source=dict(room=6,entity=1,predicate=predicate,stream=stream),enemy_records=[dict(id=enemy['id'],local_id=native,stats_offset=struct.unpack_from('<I',data,enemy_table+4*native)[0]-encounters.BASE,decision_callback=hex(struct.unpack_from('<I',data,struct.unpack_from('<I',data,enemy_table+4*native)[0]-encounters.BASE+48)[0])) for native,enemy in roster.items()],scope='C walking/point/encounter metadata and the proven Kobold return edge. Source metadata only; runtime coverage and media acceptance are separate gates, with no substitution with B enemies.')
        proof['battle_overlay']=dict(schema='suikoden-world-battle/30',producer='battle_export(c)',scope='C records/rosters; the two-archer formation1 retains its bounded source-art path. The combined schema31 actor package binds formations2–8, including mixed archer/melee/magic and Strong Arm, through source actor programs, target selection, HP/KO ownership and shared graphics. Wider action combinations, canonical campaign entry and media acceptance remain unfinished.',source_case='game/tests/fixtures/world_c_archer_two_round.json',unsupported_policies=[],decoder='64-byte enemy records; original script7 OP_LEN_HW/clock checks; shared source melee and enemy-magic actor programs; independent static driver, byte-arithmetic and graphic consumers')
        proof['battle_overlay']['dodge_sources']=[]
        for identifier,filename in (('hero','SHU.BIN'),('gremio','GRE.BIN')):
            member,member_origin=source('/'+filename)
            table=struct.unpack_from('<I',member,32)[0]
            proof['battle_overlay']['dodge_sources'].append(dict(id=identifier,**member_origin,script_index=3,script_offset=struct.unpack_from('<I',member,table+12)[0],decoder='archer_dodge_timings; actor_script.OP_LEN_HW; owner-signal wait plus character-specific return; independent original consumer'))
        proof['battle_overlay']['ordinary_party_cases']=['game/tests/fixtures/world_c_party_'+name+'.json' for name in ('distinct','same','same_nonlethal','all_commands','all_nonlethal','distinct_misses')]
        proof['battle_overlay']['gremio_attack_cases']=['game/tests/fixtures/world_c_archer_gremio_attack'+suffix+'.json' for suffix in ('','_misses','_target1','_nonlethal')]
        proof['battle_overlay']['party_attack_sources']=[]
        for identifier,filename in (('hero','SHU.BIN'),('gremio','GRE.BIN'),('pahn','PAN.BIN'),('yam_koo','YAM.BIN'),('tai_ho','TAI.BIN')):
            member,member_origin=source('/'+filename)
            table=struct.unpack_from('<I',member,32)[0]
            proof['battle_overlay']['party_attack_sources'].append(dict(id=identifier,**member_origin,scripts=[dict(index=index,file_offset=struct.unpack_from('<I',member,table+4*index)[0]) for index in (1,4)],timing=party_attack_timing(identifier),decoder='party_attack_timing; actor_script.OP_LEN_HW and original f-record clocks; independently checked by complete C driver'))
        proof['battle_overlay']['miss_source_case']='game/tests/fixtures/world_c_archer_misses.json'
        proof['battle_overlay']['knockout_source_case']='game/tests/fixtures/world_c_archer_gremio_knockout.json'
        proof['battle_overlay']['low_hp_source_cases']=['game/tests/fixtures/world_c_archer_gremio_'+suffix+'.json' for suffix in ('1','24','25','lowhp_miss')]
        proof['battle_overlay']['low_hp_scope']='Source-backed direct unprotected Defend Gremio only, schema8 stance/aim/dodge samples; selected protectors/counters/other commands remain unsupported. Native24-HP knockout victory/promotion/rewards/return and exact C6/C7 slot migration are checked separately.'
        return result,proof
    assert area[0x348B0:0x348B9]==bytes.fromhex('09 27 10 03 fb 01 56 55 fd')
    _,exit_event,_=village_content(area)
    field_exit={key:exit_event[key] for key in ('x','y','w','h')}
    result=dict(field_exit=field_exit,schema='suikoden-world-travel/1',id='region_b',width=plane['w'],height=plane['h'],walkable=''.join('1' if code>=threshold else '0' for code in plane['codes']),points=points,return_camera=dict(x=86,y=85),enemies=list(roster.values()),encounters=candidates)
    proof=dict(schema='suikoden-world-travel-proof/1',producer='kit/tools/export_world_travel.py',decoder=f'kit/tools/world_map_render.py parse_worldmap; lzss.py {lzss.__version__}',sources=[main_origin,origin,area_proof],world_table=hex(table),threshold=threshold,selectors=hex(selectors),mode='foot',scope='Region B/VB6 edge and eight source candidate records. Other entrances report unsupported; draw inputs are supplied externally at the BIOS rand boundary; no PRNG algorithm or native battle/media completion is implied.')
    unsupported=['killer_rabbit','beast_commander']
    supported=[i for i,entry in enumerate(candidates,1) if not any(enemy in unsupported for enemy in entry['enemies'])]
    proof['protection']=protection_export()[1]
    proof['medicine_sources']=[dict(id=timing['id'],**source('/'+filename)[1],decoder='medicine_timings; original S1 f-record clips13/14/15 and MAIN scripts8016C194/8016C1C0/8016C2F0') for timing,filename in zip(medicine_timings(),('SHU.BIN','GRE.BIN','PAN.BIN','VIC.BIN','YAM.BIN','TAI.BIN'))]
    proof['battle_overlay']=dict(schema='suikoden-world-battle/13',supported_encounters=supported,escape_menu_encounters=list(range(1,9)),unsupported_policies=unsupported,partial_actions={'hero':['ordinary_squirrel_attack','critical_squirrel_attack','ordinary_roc_attack','ordinary_roc_repeated_rounds'],'party':['medicine_all_six_users_and_targets_with_self_use_and_separate_recovery_locks'],'roc':['single_enemy_ordinary_and_unprotected_party_knockout','gremio_defend_cover_without_auto_revival'],'killer_rabbit':['projectile','ordinary','interception_without_sacrificial_buddha'],'beast_commander':['solo_sleep_action','single_squirrel_order']},timing_decoder='kit/tools/export_world_travel.py rabbit_timings, roc_timings, commander_timings and commander_order_timings; actor_script.OP_LEN_HW; world-battle/13',knockout_decoder='squirrel_knockout_ticks: script slot7;92 timed updates and two opcode30 yields, independently checked against complete source lifecycles',party_attack_source=dict(**source('/SHU.BIN')[1],decoder='party_attack_timing: concurrent animation/movement waits; source VM independently checked'),timing_scope='Named actor-local clocks include launch as1; single-Squirrel coordinator and Hero ordinary Attack overlap are bounded subsets; general scheduling and presentation remain unfinished.',presentation='Simulation bounds only; no atlas or terrain package. validateAtlas refuses this content.',enemy_records=[dict(id=enemy['id'],local_id=native,file_offset=struct.unpack_from('<I',data,enemy_table+4*native)[0]-encounters.BASE,decision_callback=hex(struct.unpack_from('<I',data,struct.unpack_from('<I',data,enemy_table+4*native)[0]-encounters.BASE+48)[0])) for native,enemy in roster.items()])
    proof['battle_overlay']['round_start']=dict(source=['0x800F64F0','0x800F6B98','0x800F6DA8','0x800F7098','0x800F7288'],decoder='checked original rand%3 and30-update picker wait; next-round stats/HP lifecycle independently compared',scope='two ordinary bound Roc rounds with active healthy members; camera choreography remains outside current presentation')
    return result,proof


def rabbit_timings(data):
    """Named update counts, independently checked through the original outer driver."""
    from actor_script import OP_LEN_HW
    def script(address):
        cursor=address-encounters.BASE;rows=[]
        for _ in range(64):
            op=struct.unpack_from('<H',data,cursor)[0]
            if op in (0,1):return rows
            count=OP_LEN_HW.get(op)
            if not count:raise ValueError('unsupported Rabbit projectile script')
            rows.append((op,struct.unpack_from('<'+'h'*(count-1),data,cursor+2)))
            cursor+=2*count
        raise ValueError('unterminated Rabbit projectile script')
    child=script(0x8009F92C)
    expected=[(8,(0,)),(3,(33,)),(8,(1,)),(35,(1,6)),(23,(3,30,0,0,-24,-9,-9,-9)),(3,(20,)),(26,(1,1)),(21,()),(26,(1,2)),(23,(2,30,0,0,0,9,9,0)),(21,()),(26,(1,4)),(2,())]
    if child!=expected:raise ValueError('Rabbit projectile source changed')
    parent=script(0x8009F8F0)
    if parent!=[(15,(0,1)),(15,(1,8)),(4,(7,)),(5,()),(3,(10,)),(4,(8,)),(3,(20,)),(34,(1296,)),(5,()),(28,(0,4)),(4,(9,)),(5,()),(9,(0,)),(16,(0,1))]:raise ValueError('Rabbit owner script changed')
    section=struct.unpack_from('<I',data,0x1F748+44)[0]-encounters.BASE
    table=struct.unpack_from('<I',data,section+20)[0]-encounters.BASE
    def duration(index):
        frame=struct.unpack_from('<I',data,table+4*index)[0]-encounters.BASE
        if data[frame+1]!=1:raise ValueError('Rabbit animation must terminate')
        return sum(data[frame+5+2*i] or 256 for i in range(data[frame]))
    if duration(7)+10+max(20,duration(8))>=93:raise ValueError('Rabbit owner no longer waits for projectile')
    contact=child[1][1][0]+child[4][1][1]
    returned=contact+child[9][1][1]
    # Logic callbacks precede actor updates; the owner updates before its auxiliary slot.
    projectile=dict(impact_tick=contact+1,release_tick=returned+1,duration=returned+1+duration(9))
    ordinary=script(0x8009F7B4);retreat=script(0x8009F85C)
    expected=[(30,(0,)),(14,(2,)),(15,(0,1)),(15,(1,8))]
    for ticks in (20,15,15):expected += [(4,(20,)),(23,(1,ticks,0,0,0,0,0,-6)),(21,())]
    expected += [(4,(17,)),(5,()),(4,(18,)),(26,(0,1)),(23,(2,15,-6,0,-24,0,0,-6)),(21,()),(26,(0,2)),(4,(19,)),(23,(1,20,-24,0,0,0,0,-6)),(21,()),(26,(0,4))]
    if ordinary!=expected:raise ValueError('Rabbit ordinary attack script changed')
    expected=[(9,(0,)),(30,(1,)),(35,(1,8)),(4,(20,)),(31,(2,)),(30,(3,)),(3,(1,)),(21,())]
    for _ in range(2):expected += [(4,(20,)),(30,(3,)),(3,(1,)),(21,())]
    expected += [(30,(4,)),(13,(2,)),(16,(0,1)),(16,(0,255))]
    if retreat!=expected:raise ValueError('Rabbit return script changed')
    hop_word=struct.unpack_from('<I',data,0x548)[0]
    if hop_word!=0x3402000A:raise ValueError('Rabbit return-hop duration changed')
    jumps=[args for op,args in ordinary if op==23]
    impact=1+sum(jump[1] for jump in jumps[:3])+duration(17)+jumps[3][1]+1
    return_tick=impact+jumps[4][1]
    hops=sum(op==30 and args==(3,) for op,args in retreat)
    normal=dict(impact_tick=impact,return_tick=return_tick,duration=return_tick+2+hops*((hop_word&65535)+1))
    return dict(projectile=projectile,ordinary=normal)


def commander_order_timings(raw):
    from actor_script import OP_LEN_HW
    half=lambda address:struct.unpack_from('<H',raw,address-encounters.BASE)[0]
    word=lambda address:struct.unpack_from('<I',raw,address-encounters.BASE)[0]
    def walk(start):
        rows=[];pc=start
        for _ in range(100):
            op=half(pc);n=OP_LEN_HW[op]
            if n is None:raise ValueError('unsupported order script')
            rows.append(tuple(half(pc+2*i) for i in range(n or 1)))
            if op in (0,1):return rows
            pc+=2*n
        raise ValueError('unterminated order script')
    def animation(section,index):
        p=word(word(section+20)+4*index);return sum(raw[p-encounters.BASE+5+2*i] for i in range(raw[p-encounters.BASE]))
    owner=walk(0x800A2268);attack=walk(0x800A1000);retreat=walk(0x800A1070);hurt=walk(0x800A10E0)
    if [v[1] for v in owner if v[0]==4]!=[7,8,9,0] or (40,4,20) not in hurt:raise ValueError('Commander order scripts changed')
    section=0x800A25E0;windup=animation(section,7)+animation(section,8)
    launch=windup+1;owner_release=windup+next(v[1] for v in owner if v[0]==3)+animation(section,9)+animation(section,0)
    section=0x800A1348
    durations=[v[2] for v in attack if v[0] in (23,33)]
    if durations!=[10,1,20]:raise ValueError('ordered attack movement changed')
    impact=animation(section,4)+sum(durations)+next(v[1] for v in attack if v[0]==3)+animation(section,7)+1
    returning=impact+animation(section,9)
    retmove=sum(v[2] for v in retreat if v[0] in (23,33))+next(v[1] for v in retreat if v[0]==3)+animation(section,12)
    return dict(launch_tick=launch,owner_release_tick=owner_release),dict(impact_tick=impact,return_tick=returning,status_tick=impact+next(v[1] for v in hurt if v[0]==3)-1,target_release_tick=impact+next(v[1] for v in hurt if v[0]==3)+next(v[2] for v in hurt if v[0]==23)+1+next(v[1] for v in hurt if v[0]==22)-1,duration=returning+retmove,status_percent=20)


def commander_timings(raw):
    from actor_script import OP_LEN_HW
    half=lambda address:struct.unpack_from('<H',raw,address-encounters.BASE)[0]
    word=lambda address:struct.unpack_from('<I',raw,address-encounters.BASE)[0]
    def walk(start):
        result=[];pc=start
        for _ in range(100):
            op=half(pc);n=OP_LEN_HW[op]
            if n is None:raise ValueError('unsupported Commander script branch')
            result.append(tuple(half(pc+2*i) for i in range(n or 1)))
            if op in (0,1):return result
            pc+=2*n
        raise ValueError('unterminated Commander script')
    owner=walk(0x800A2374);aux=walk(0x800A23B8);target=walk(0x800A229C)
    if [x[1] for x in owner if x[0]==4]!=[16,17,18] or aux!=[(33,3,60,65531,0,65516),(21,),(26,1,2),(2,),(0,)]:raise ValueError('Commander action scripts changed')
    if (24,9,19,5,5,0,65506) not in owner or (40,5,30) not in target:raise ValueError('Commander status action changed')
    section=word(0x800A2208+44);ft=word(section+20)
    def animation(index):
        p=word(ft+4*index);return sum(raw[p-encounters.BASE+5+2*i] for i in range(raw[p-encounters.BASE]))
    spawn=animation(16)+animation(17);contact=spawn+aux[0][2]+1
    initial=next(row[1] for row in target if row[0]==3)
    motion=next(row[2] for row in target if row[0]==23)
    home=next(row[2] for row in target if row[0]==33)
    status=contact+initial+motion
    return dict(auxiliary_spawn_tick=spawn,auxiliary_release_tick=contact,reaction_tick=contact,owner_release_tick=contact+animation(18),status_tick=status,duration=status+home,status_percent=30)


def protection_export():
    import character_table
    import preparation
    records=character_table.records()
    names={row['id']:preparation.stable_id(row['name']) for row in records}
    characters=[];sources=[]
    for row in records:
        raw,origin=source('/'+row['sprite_file'])
        if raw[0]!=row['id']:raise ValueError('character header identity changed')
        characters.append(dict(id=names[row['id']],character_type=raw[10]))
        sources.append(dict(id=names[row['id']],source=origin,character_type_offset=10))
    pairs=[];offset=0x8016C814-maindec.MBASE
    while maindec.body()[offset]!=255:
        ward,protector=maindec.body()[offset:offset+2];offset+=2
        pairs.append(dict(ward=names[ward],protector=names[protector]))
        if len(pairs)>108:raise ValueError('unterminated protector table')
    raw,_=source('/B_DATA.BIN')
    half=lambda address:struct.unpack_from('<H',raw,address-0x80080000)[0]
    if (half(0x8009EFD0),half(0x8009EFE4),half(0x8009F06C),half(0x8009F074))!=(3,23,3,33):raise ValueError('common hurt clocks changed')
    hurt=half(0x8009EFD2)+half(0x8009EFE8)+half(0x8009F06E)+half(0x8009F078)
    ward=struct.unpack_from('<H',maindec.body(),0x8016C2BE-maindec.MBASE)[0]
    return dict(characters=characters,pairs=pairs,hurt_duration=hurt,ward_return_duration=ward),dict(table='0x8016C814',selector='0x800F79E0',eligibility='0x800F8604',sources=sources,scope='Settled single-action selection and Rabbit interception without Sacrificial Buddha. Common hurt duration includes impact update; ward starts on guard release or the following update according to party order. Normal protector KO uses the same return clocks; Sacrificial Buddha auto-revival and overlapping locks remain separate.',hurt_script='0x8009EFBC',ward_return_script='0x8016C2B4',timing_decoder='3+32+1+10 actor updates; ward movement10; source VM comparison')


def squirrel_knockout_ticks(data, table=0x20FD8):
    from actor_script import OP_LEN_HW
    cursor=struct.unpack_from('<I',data,table+7*4)[0]-encounters.BASE;rows=[]
    for _ in range(32):
        op=struct.unpack_from('<H',data,cursor)[0]
        if op==0:break
        count=OP_LEN_HW.get(op)
        if not count:raise ValueError('unsupported Squirrel knockout script')
        rows.append((op,struct.unpack_from('<'+'h'*(count-1),data,cursor+2)));cursor+=2*count
    else:raise ValueError('unterminated Squirrel knockout script')
    if rows!=[(15,(0,1)),(30,(0,)),(35,(0,3)),(14,(1,)),(4,(3,)),(6,(1,)),(3,(1,)),(3,(90,)),(8,(0,)),(6,(0,)),(3,(1,)),(30,(99,)),(16,(0,1)),(16,(0,255))]:raise ValueError('Squirrel knockout script changed')
    # Each opcode30 initializes a yielded callback before its next-update resume.
    return sum(args[0] for op,args in rows if op==3)+sum(op==30 for op,args in rows)


def medicine_timings(identifiers=None):
    from battle_unite_camera import animation_frames
    import character_table
    import preparation
    records={preparation.stable_id(r['name']):r for r in character_table.records()};result=[]
    assert struct.unpack_from('<21H',maindec.body(),0x8016C194-maindec.MBASE)==(15,0,1,4,13,5,4,14,5,26,0,8,3,60,4,15,5,16,0,1,0)
    assert maindec.mword(0x800F247C)==0x3402001E and maindec.mword(0x800F2784)==0x2442FFFC and maindec.mword(0x800F278C)==0x28420081
    for stable in identifiers if identifiers is not None else ('hero','gremio','pahn','viktor','yam_koo','tai_ho'):
        data=source('/'+records[stable]['sprite_file'])[0]
        clips,flags,_=animation_frames(data)
        if any(flags[index]!=1 for index in (13,14,15)):raise ValueError('item animation flags changed')
        duration=lambda i:sum(t or 256 for p,t in clips[i])
        assert duration(14)==1
        start=duration(13)+duration(14)+1;pending=start+30+1;fade=(255-128+3)//4
        result.append(dict(id=stable,target_start=start,pending_tick=pending,impact_tick=pending+1,target_release=pending+fade+1,owner_release=start+60+duration(15)-1))
    return result


def round_start_timing():
    # The original round launcher consumes rand%3 and installs the30-update picker wait.
    assert maindec.mword(0x800F70A0)==0x34030003 and maindec.mword(0x800F7288)==0x3403001E
    return dict(camera_choices=3,selection_delay=30)


def roc_timings(data):
    """Static script deadlines; animation and movement progress concurrently."""
    from actor_script import OP_LEN_HW
    word=lambda address:struct.unpack_from('<I',data,address-encounters.BASE)[0]
    def walk(index):
        cursor=word(0x800A36C8+4*index)-encounters.BASE;rows=[]
        for _ in range(128):
            op=struct.unpack_from('<H',data,cursor)[0]
            if op==0:return rows
            count=OP_LEN_HW.get(op)
            if not count:raise ValueError('unsupported Roc script')
            rows.append((op,struct.unpack_from('<'+'h'*(count-1),data,cursor+2)));cursor+=2*count
        raise ValueError('unterminated Roc script')
    frames=word(0x800A39BC+20);clock=animation=movement=0;impact=returned=released=None
    for index in (1,4):
        for op,args in walk(index):
            if op==4:
                frame=word(frames+4*args[0])-encounters.BASE
                animation=clock+sum(data[frame+5+2*i] or 256 for i in range(data[frame]))
            elif op==5:clock=max(clock,animation)
            elif op==3:clock+=args[0]
            elif op in (23,33):movement=clock+args[1]
            elif op==21:clock=max(clock,movement)
            elif op==26 and args==(0,2):impact=clock+1
            elif op==26 and args==(0,4):returned=clock+1
            elif op==16 and args==(0,1):released=clock
            elif op not in (9,15,16,26,34):raise ValueError('Roc attack timing opcode changed')
    hurt=walk(2)
    if any(op in (23,33) for op,args in hurt):raise ValueError('Roc reaction movement changed')
    delay=sum(args[0] for op,args in hurt if op==3)
    if not 1<impact<returned<released or not 0<delay<released-impact:raise ValueError('invalid Roc clocks')
    return dict(impact_tick=impact,return_tick=returned,duration=released,target_release_delay=delay)


def party_attack_sequence(identifier="hero"):
    """A named party member's ordinary scripts share animation/movement clocks."""
    from actor_script import OP_LEN_HW
    import character_table,preparation
    record=next((row for row in character_table.records() if preparation.stable_id(row['name'])==identifier),None)
    if record is None:raise ValueError('unknown party attack identity')
    data,_=source('/'+record['sprite_file']);table=struct.unpack_from('<I',data,32)[0];section=struct.unpack_from('<I',data,36)[0]
    frames=struct.unpack_from('<I',data,section+20)[0]
    def walk(index):
        pc=struct.unpack_from('<I',data,table+4*index)[0];rows=[]
        for _ in range(128):
            op=struct.unpack_from('<H',data,pc)[0]
            if op in (0,1):return rows
            count=OP_LEN_HW.get(op)
            if not count:raise ValueError('unsupported party attack script')
            rows.append((op,struct.unpack_from('<'+'h'*(count-1),data,pc+2)));pc+=count*2
        raise ValueError('unterminated party attack script')
    clock=animation=movement=0;dodge=impact=returned=released=None;leaps=[]
    for index in (1,4):
        for op,args in walk(index):
            if op==4:
                frame=struct.unpack_from('<I',data,frames+4*args[0])[0]
                if data[frame+1]!=1:raise ValueError('looping party attack animation')
                animation=clock+sum(data[frame+5+2*i] or 256 for i in range(data[frame]))
            elif op==5:clock=max(clock,animation)
            elif op==3:clock+=args[0]
            elif op==23:
                mode,duration,x,y,z,vx,vy,vz=args
                if mode not in (2,3) or duration<2:raise ValueError('unsupported ordinary attack leap')
                leaps.append(dict(start=max(1,clock)-1,home=mode==3,leap=dict(ticks=duration,acceleration_step=1/4096,
                    offset=dict(zip('xyz',(x,y,z))),velocity=dict(zip('xyz',(vx/2,vy/2,vz/2))))))
                movement=clock+duration
            elif op==21:clock=max(clock,movement)
            elif op==26 and args==(0,1):dodge=clock
            elif op==26 and args==(0,2):impact=clock
            elif op==26 and args==(0,4):returned=clock
            elif op==16 and args==(0,1):released=clock-1
            elif op not in (9,13,14,15,16,26,34,43):raise ValueError('party attack timing opcode changed')
    def reaction(index):
        clock=movement=0;spawns=[];white=[]
        for op,args in walk(index):
            if op==3:clock+=args[0]
            elif op==23:movement=max(1,clock)+args[1]
            elif op==21:clock=max(clock,movement)
            elif op==22:
                if args!=(1,):raise ValueError('party target return changed')
                movement=clock
            elif op==24:
                flags,animation,child,*offset=args
                if flags or child:raise ValueError('unbound ordinary impact resource')
                spawns.append(dict(at=max(0,clock-1),animation=animation,offset=offset))
            elif op in (38,39):white.append(dict(at=max(0,clock-1),enabled=op==38))
            elif op not in (4,16,25,26,27,34,38,39):raise ValueError('party reaction timing opcode changed')
        return clock,spawns,white
    clock,ordinary,white=reaction(2)
    critical_clock,critical,critical_white=reaction(8)
    if critical_clock!=clock or critical_white!=white:raise ValueError('ordinary/critical body reaction differs')
    result=dict(id=identifier,impact_tick=impact+1,return_tick=returned+1,release_tick=released+1,target_release_delay=clock)
    if not 0<impact<returned<released or clock<=0:raise ValueError('invalid party attack clocks')
    if len(leaps)!=2 or leaps[0]['home'] or not leaps[1]['home']:raise ValueError('unsupported ordinary attack stages')
    result['motion']=dict(approach_start=leaps[0]['start'],approach=leaps[0]['leap'],impact_tick=result['impact_tick'],
        ready_tick=result['return_tick'],return_start=leaps[1]['start'],retreat=leaps[1]['leap'],duration=result['release_tick'])
    result['impacts']=dict(ordinary=ordinary,critical=critical,white=white)
    result['critical_camera']=critical_camera()
    if dodge is None or not 0<dodge<impact:raise ValueError('missing party dodge signal')
    result['dodge_start_tick']=dodge+1
    return result


def party_attack_timing(identifier="hero"):
    # Retained source witnesses use the original clock-only record.
    return {key:value for key,value in party_attack_sequence(identifier).items() if key not in ('motion','impacts','critical_camera','dodge_start_tick')}


def enemy_dodge(data,table):
    """Lower the shared enemy script3 into two jumps and an owner-ready wait."""
    from actor_script import OP_LEN_HW
    cursor=struct.unpack_from('<I',data,table+12)[0]-encounters.BASE;rows=[]
    for _ in range(32):
        op=struct.unpack_from('<H',data,cursor)[0]
        if op==0:break
        count=OP_LEN_HW.get(op)
        if not count:raise ValueError('unsupported enemy dodge script')
        rows.append((op,struct.unpack_from('<'+'h'*(count-1),data,cursor+2)));cursor+=2*count
    expected=[(27,(0,2)),(4,(11,)),(23,(1,15,-32,0,0,0,0,-6)),(21,()),(4,(0,)),
        (28,(1,2)),(26,(0,2)),(3,(1,)),(28,(1,4)),(3,(10,)),(23,(3,15,0,0,0,0,0,-6)),(21,()),(16,(0,8))]
    if rows!=expected or op!=0:raise ValueError('enemy dodge source changed')
    def leap(args):
        _,ticks,x,y,z,vx,vy,vz=args
        return dict(ticks=ticks,offset=dict(zip('xyz',(x,y,z))),velocity=dict(zip('xyz',(vx/2,vy/2,vz/2))),acceleration_step=1/4096)
    return dict(animation=rows[1][1][0],back=leap(rows[2][1]),ready_wait=rows[9][1][0],retreat=leap(rows[10][1]))


def critical_camera():
    values=list(struct.unpack_from('<12i',maindec.body(),0x8016C7E4-maindec.MBASE))
    z=((maindec.mword(0x800F6314)&65535)<<16)|(maindec.mword(0x800F6318)&65535)
    values[2]=z-(1<<32) if z&(1<<31) else z
    return dict(updates=maindec.mword(0x800F6330)&65535,
        target={key:values[i*3:i*3+3] for i,key in enumerate(('position','angles','c','d'))})


def archer_dodge_timings():
    """Target script3 returns after the C owner signal,10-update wait and own motion."""
    from actor_script import OP_LEN_HW
    import character_table
    records={row['name'].lower():row for row in character_table.records()}
    result=[]
    for identifier in ('hero','gremio'):
        data=source('/'+records[identifier]['sprite_file'])[0]
        table=struct.unpack_from('<I',data,32)[0];cursor=struct.unpack_from('<I',data,table+12)[0];ops=[]
        for _ in range(64):
            op=struct.unpack_from('<H',data,cursor)[0]
            if op in (0,1):break
            count=OP_LEN_HW[op];ops.append((op,struct.unpack_from('<'+'h'*(count-1),data,cursor+2)));cursor+=2*count
        assert [op for op,_ in ops[:9]]==[4,23,21,4,28,26,3,28,3]
        assert ops[7:9]==[(28,(1,4)),(3,(10,))]
        movement,args=ops[9]
        assert movement in (23,33) and args[0]==3 and args[1] in (10,15)
        result.append(dict(id=identifier,target_release_tick=93+10+args[1]+1))
    return result


def battle_export(region='b'):
    """Simulation overlay only; original pose bounds are not an assembled atlas."""
    import item_tables
    import preparation
    data,_=source(f'/{region.upper()}_DATA.BIN')
    travel,proof=export(region)
    _,_,directory,_=encounters.chain(data)
    table=struct.unpack_from('<I',data,directory-encounters.BASE+12)[0]-encounters.BASE
    item_names={row['id']:preparation.stable_id(row['name']) for row in item_tables.items()}
    from export_shop import consumables
    uses={item['id']:item['uses'] for item in consumables()[0]} if region=='c' else {}
    profiles=[]
    for enemy in travel['enemies']:
        # Encounter order is not the local enemy-id order.
        local=next(row['local_id'] for row in proof['enemy_records'] if row['id']==enemy['id']) if region=='c' else next(slot['enemy_id'] for entry in battle_placement.area_encounters(data)['encounters'] for slot in entry['slots'] if war_text.decode(data[slot['stats_offset']:],length=16)[0]==enemy['name'])
        offset=struct.unpack_from('<I',data,table+4*local)[0]-encounters.BASE
        raw=data[offset:offset+64]
        hp,attack,skill,defense,speed,magic,luck=struct.unpack_from('<7H',raw,18)
        flags=struct.unpack_from('<H',raw,38)[0]
        encoded=struct.unpack_from('<h',raw,52)[0]
        money=int(encoded/10)*100 if encoded&1 else encoded
        section=struct.unpack_from('<I',raw,44)[0]-encounters.BASE
        ft=struct.unpack_from('<I',data,section+20)[0]-encounters.BASE
        animation=struct.unpack_from('<I',data,ft)[0]-encounters.BASE
        neutral=data[animation+4]
        et=struct.unpack_from('<I',data,section+16)[0]-encounters.BASE
        pose=struct.unpack_from('<I',data,et+neutral*4)[0]-encounters.BASE
        count,_,width,height,ax,ay=data[pose:pose+6]
        for piece in range(count):
            x,y,_,_,wm,hm,_,_=data[pose+8+8*piece:pose+16+8*piece]
            width=max(width,x+wm+1);height=max(height,y+hm+1)
        affinities=dict(zip(('fire','water','earth','lightning','wind'),[('neutral','weak','resistant','immune')[v] for v in raw[32:37]]))
        enemy = dict(enemy, other_affinity=('neutral','weak','resistant','immune')[raw[0x25]], death_immune=bool(flags & 0x4000), airborne=bool(flags & 0x20))
        if region=='c':
            supported=enemy['id']=='kobold_type_2'
            melee=enemy['id'] in ('kobold_type_1', 'strong_arm')
            source_magic=enemy['id']=='kobold_type_3'
            if melee and (struct.unpack_from('<I',raw,48)[0]!=0x80080018 or flags!=(12 if enemy['id']=='strong_arm' else 3)):
                raise ValueError('Kobold ordinary melee policy/capability changed')
            drops=[dict(item=item_names[raw[54+2*i]] if raw[54+2*i] else None,uses=uses.get(item_names.get(raw[54+2*i]),0),rate=raw[55+2*i]) for i in range(3)]
            if supported:
                assert struct.unpack_from('<I',raw,48)[0]==0x8008018C and flags==4
                assert section==0x22B90
            profiles.append(dict(**enemy,max_hp=hp,money=money,stats=dict(attack=attack,skill=skill,defense=defense,speed=speed,magic=magic,luck=luck),sprite=dict(rect=dict(x=0,y=0,w=width,h=height),anchor_x=ax,anchor_y=ay),attack=[],target_policy='front_first',action_policy='front_projectile' if supported else 'source_melee' if melee else 'source_magic' if source_magic else 'unsupported',front_projectile=dict(impact_tick=56,target_release_tick=92,owner_release_tick=116,dodges=archer_dodge_timings()) if supported else None,knockout_ticks=squirrel_knockout_ticks(data,struct.unpack_from('<I',raw,40)[0]-encounters.BASE) if supported or melee or source_magic else None,affinities=affinities,fire_affinity=affinities['fire'],dodges_attacks=bool(flags&4),unavoidable_attack=bool(flags&8),drops=drops))
            continue
        supported=enemy['id'] in ('flying_squirrel','roc')
        if enemy['id']=='killer_rabbit' and flags!=12:raise ValueError('Rabbit counter/forced-hit flags changed')
        if supported and (struct.unpack_from('<I',raw,48)[0]!=0x8008006C or flags&0x8002):raise ValueError('unsupported region-B policy')
        drops=[dict(item=item_names[raw[54+2*i]] if raw[54+2*i] else None,uses=0,rate=raw[55+2*i]) for i in range(3)]
        profiles.append(dict(**enemy,knockout_ticks=squirrel_knockout_ticks(data,0x236C8 if enemy['id']=='roc' else 0x20FD8) if supported else None,max_hp=hp,money=money,stats=dict(attack=attack,skill=skill,defense=defense,speed=speed,magic=magic,luck=luck),sprite=dict(rect=dict(x=0,y=0,w=width,h=height),anchor_x=ax,anchor_y=ay),attack=[],target_policy='front_first',action_policy='roc' if enemy['id']=='roc' else 'attack' if supported else 'rabbit' if enemy['id']=='killer_rabbit' else 'commander',commander=commander_timings(data) if enemy['id']=='beast_commander' else None,commander_order=commander_order_timings(data)[0] if enemy['id']=='beast_commander' else None,ordered_attack=commander_order_timings(data)[1] if enemy['id']=='flying_squirrel' else None,projectile=rabbit_timings(data)['projectile'] if enemy['id']=='killer_rabbit' else None,ordinary_timing=roc_timings(data) if enemy['id']=='roc' else rabbit_timings(data)['ordinary'] if enemy['id']=='killer_rabbit' else None,affinities=affinities,fire_affinity=affinities['fire'],dodges_attacks=bool(flags&4),unavoidable_attack=bool(flags&8),drops=drops))
    records=battle_placement.area_encounters(data)['encounters']
    runs=[]
    for entry,roster in zip(records,travel['encounters']):
        off=entry['descriptor_offset'];flags=struct.unpack_from('<I',data,off+12)[0]
        raw_money = sum(struct.unpack_from('<h', data, slot['stats_offset'] + 0x34)[0] for slot in entry['slots'])
        if raw_money < 0:
            raise ValueError('negative source bribe totals require explicit signed-money runtime support')
        runs.append(dict(**encounter_music(flags),id=roster['id'],title=f'Region {region.upper()} encounter '+str(entry['index']),enemies=[v for v in roster['enemies'] if v],experience_per_member=0,positions=[dict(zip('xyz',slot['world'])) for slot in entry['slots']],enemy_rows=['front' if slot['slot']<3 else 'back' for slot in entry['slots']],source_slots=[slot['slot'] for slot in entry['slots']],escape_allowed=not bool(flags&0x80000000),bribe_cost=3*raw_money))
    for profile in profiles:
        if profile['id'] not in ('flying_squirrel','roc','kobold_type_2'):continue
        record=next(slot['stats_offset'] for entry in records for slot in entry['slots'] if war_text.decode(data[slot['stats_offset']:],length=16)[0]==profile['name'])
        profile['dodge']=enemy_dodge(data,struct.unpack_from('<I',data,record+40)[0]-encounters.BASE)
    return dict(medicine_timings=medicine_timings(),round_start=round_start_timing(),party_attacks=[party_attack_sequence(identifier) for identifier in ('hero','gremio','pahn','yam_koo','tai_ho')],protection=protection_export()[0],schema='suikoden-world-battle/30' if region=='c' else 'suikoden-world-battle/25',enemies=profiles,encounters=runs,unsupported_enemies=[] if region=='c' else ['killer_rabbit','beast_commander'])


if __name__=='__main__':
    content,proof=export()
    (ROOT/'game/assets/world_b.json').write_text(json.dumps(content,indent=2)+'\n')
    (ROOT/'kit/data/reports/world_travel.json').write_text(json.dumps(proof,indent=2)+'\n')
    (ROOT/'game/assets/world_b_battle.json').write_text(json.dumps(battle_export(),indent=2)+'\n')
    region_c,proof_c=export('c')
    (ROOT/'game/assets/world_c_battle.json').write_text(json.dumps(battle_export('c'),indent=2)+'\n')
    (ROOT/'game/assets/world_c.json').write_text(json.dumps(region_c,indent=2)+'\n')
    (ROOT/'kit/data/reports/world_travel_c.json').write_text(json.dumps(proof_c,indent=2)+'\n')
    print(f"Exported {len(content['walkable'])} world cells, {len(content['points'])} point bounds and {len(content['encounters'])} encounter candidates; metadata only")
