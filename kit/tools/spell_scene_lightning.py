"""Static grammar for shared caster clones and lightning bolt families."""
import spell_scene_source as source
import spell_scene_objects as objects


def thunder_program(effect,pieces):
    if int(effect['initializer'],16)!=0x8010F440:return None
    import hashlib
    import export_spell_scenes as export
    image=source.Image()
    for a,b,digest in [(0x8010F440,0x8010F8DC,'8b68c0ffb6e3dd7c5376c5bb97e31f3c96e1b5cd142f464163ae0a82eb11c68e'),
                       (0x8010F8DC,0x80110308,'26368a0891a5e244c6e8940fa3dfc1bc7097316c5523dd89547017d7a0689ecd')]:
        if hashlib.sha256(image.data[a-image.base:b-image.base]).hexdigest()!=digest:raise ValueError('Thunder God source changed; requalify its equations')
    for pc,word in {0x80120814:0x28420021,0x80120830:0x24420200,0x80120844:0x2442FF00,
                    0x80120864:0x2442FFFF,0x80122EE0:0xAE62001C,0x80122F4C:0xAE620000,
                    0x80122FB4:0x8E620038,0x80122FE8:0x8E62003C}.items():
        if image.word(pc)!=word:raise ValueError('Thunder God source changed in shared spawn/pulse helper')
    facts,analysis=source.analyze(0x8010F440);facts['phases']=source.timeline(facts,analysis)
    decoded=objects.constructors(facts,image)
    groups={n:[row for row in decoded['objects'] if row['animation']==n] for n in (0,9,6,11,3,2,8)}
    if decoded['blocked'] or [len(groups[n]) for n in groups]!=[6,8,12,12,8,8,18] or [p['updates'] for p in facts['phases']]!=[64,64,48,180,64,64]:raise ValueError('unresolved Thunder God lifecycle')
    duration=485;end=484;origin=[export.signed_word(0x8016B814),export.signed_word(0x8016B818),0]
    tracks,bindings=export.lightning_clones(dict(facts=facts,groups=groups,clone_limit=-70,clone_turn=16),pieces,duration,129,dict(anchor='world',origin=origin))
    bolt=len(tracks)
    tracks.append([export.sample(export.clip_piece(effect,9,age,pieces,True)) for age in range(duration)])
    spark=len(tracks);tracks.append([export.sample(export.clip_piece(effect,3,0,pieces,True)) for _ in range(duration)])
    pulse=len(tracks);tracks.append([export.sample(export.clip_piece(effect,2,0,pieces,True))])
    for i in range(8):
        for part,track in [('primary',bolt),('spark',spark),('pulse',pulse)]:
            # All three children share the radial model angle, not the node rotation.
            track_id=len(tracks)
            tracks.append([dict(row,angles=[0,0,i*512]) for row in tracks[track]])
            bindings.append(dict(anchor='world',origin=origin,track=track_id,particle_index=i,particle_part=part))
    scale_track=len(tracks);tracks.append([export.sample() for _ in range(duration)])
    for i in range(24):
        animation=6 if i<12 else 11
        track=len(tracks);tracks.append([dict(row,node_angles=[0,0,0]) for row in export.animation_track(effect,animation,pieces,size=0)])
        bindings.append(dict(anchor='world',origin=origin,track=track,particle_index=8+i,
                             random_size=export.variation(4*i+1,4096,2048),random_node_angles=[export.variation(4*i+2,2048),None,export.variation(4*i+3,2048)]))
    for i,row in enumerate(groups[8]):
        track=len(tracks)
        tracks.append([export.sample(export.clip_piece(effect,8,max(u-356,0),pieces,True) if 357<=u<end else None,
                                     position=[100*4096,0,0],angles=[0,0,row['initial'][68]],size=8192,
                                     node_angles=[0,min(1024,16*max(u-420,0)),1]) for u in range(duration)])
        bindings.append(dict(anchor='world',origin=origin,track=track))
    response=export.reaction_track(0x8016F150);offsets=[];flashes=[];active=[]
    starts=[357,393];stop=starts[-1]+response['release']
    for u in range(357,stop):
        age=u-max(at for at in starts if at<=u);on=age<len(response['offsets'])
        offsets.append(response['offsets'][age] if on else [0,0]);flashes.append(response['flash_frames'][age] if on else None);active.append(on)
    reaction=dict(start=357,release=stop-357,offsets=offsets,flash_frames=flashes,active_samples=active)
    return dict(group=True,center_after_reaction=False,impact=end,duration=duration,initial_draws=96,tracks=tracks,objects=bindings,cameras=export.source_cameras(effect),meshes=[],
                wash=[[max(0,min(u,64)-max(u-420,0))]*3 for u in range(duration)],wash_blend='subtractive',reaction=reaction,
                emitters=[dict(kind='lightning_bolts',start=177,stop=end,count=8,spawn_at=[177+row['delay'] for row in groups[9]],flight_stop=end,
                               radius=2,roots=export.square_roots(4),min_z=-300,velocity_z=25*4096,color=[127]*3,
                               spawn_override=[150*4096,0,-300*4096],spark_velocity_z=-18*4096,spark_min_z=-299,
                               spark_track=spark,pulse_track=pulse,spark_life_min=64,spark_life_range=0,pulse_life=48,pulse_fade_at=32,pulse_grow=512,pulse_shrink=256),
                          dict(kind='cycling_sprites',particle_start=8,start=357,stop=end,spawn_stop=404,count=24,radius=80,roots=export.square_roots(6400),color=[127]*3,
                               initial_delays=False,initial_delay_draw=0,delay_stride=4,delay_modulus=64,height_range=200,life_max=10,scale_track=scale_track)])


def profile(effect):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    graphics=[e for _,e in init.events('call') if e[1]==objects.GRAPHIC]
    if [e[2][1] for e in graphics]!=[0,9,10,2]:return None
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    if decoded['blocked']:raise ValueError('unresolved lightning constructor')
    groups={n:[o for o in decoded['objects'] if o['animation']==n] for n in (0,9,10,2)}
    count=len(groups[9]);repeating=count==12
    if count not in (2,12):return None
    if len(groups[0])!=6 or any(len(groups[n])!=count for n in (10,2)):raise ValueError('unresolved lightning object pairing')
    facts['phases']=source.timeline(facts,analysis)
    if len(facts['phases'])!=(6 if repeating else 5) or any(p['updates'] is None for p in facts['phases']):raise ValueError('unresolved lightning phases')
    driver=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,cut_backedges=True)
    calls=driver.events('call');spawns=[(pc,e) for pc,e in calls if e[1]==0x80122eb4]
    if len(spawns)!=(3 if repeating else 1) or not all(isinstance(v,int) for _,spawn in spawns for v in spawn[2][1:3]):raise ValueError('unresolved lightning circle spawn')
    root=('global',facts['state_global']);bolt=source.member(root,groups[9][0]['slot']);pulse=source.member(root,groups[2][0]['slot'])
    def stored(destination):
        values={e[2] for _,e in driver.events('store') if e[1]==destination and isinstance(e[2],int)}
        if len(values)!=1:raise ValueError('unresolved lightning initial field')
        return values.pop()
    expected={0x8010C484:0x14620002,0x8010C52C:0x24420010,0x8010C53C:0x28420401,
              0x8010C7B0:0x2842FFBA,0x8010C7CC:0x12200002,0x8010C858:0x10400039,
              0x8010C8D8:0x24420030,0x8010C8C4:0x00021143,0x8010C930:0x3402A000,
              0x8010C934:0xAC6212FC,0x8010C938:0xA4731324,
              0x8010C958:0x0C043035,0x8010C960:0xAE00002C,
              0x80120814:0x28420021,0x80120830:0x24420200,0x80120844:0x2442FF00,
              0x800E1324:0x8C821294,0x800E1328:0x8C8312F4,0x800E14C8:0x00021303,
              0x800DE0E0:0x0040F809,0x800DE1C8:0x0C03800D,0x800E003C:0x0C0383A8}
    if repeating:
        expected={0x8010CF48:0x14620002,0x8010CFF0:0x24420010,0x8010D000:0x28420401,
                  0x8010D4A4:0x2842FFBA,0x8010D4C0:0x12400002,0x8010D0B4:0x1462000A,
                  0x8010D108:0x14400016,0x8010D120:0x14400010,0x8010D130:0x1440000C,
                  0x8010D28C:0x14400019,0x8010D2CC:0xAE80002C,0x8010D544:0x10400032,
                  0x8010D58C:0xAC620024,0x8010D5D4:0xAC620024,0x8010D604:0xAC6212FC,
                  0x8010D608:0xA4741324,0x8010D338:0x28420038,
                  0x80120814:0x28420021,0x80120830:0x24420200,0x80120844:0x2442FF00}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'lightning source changed at {pc:#x}')
    spawn_site,spawn=spawns[0]
    phase_spawns=[];impact=[];target_phase=[];strike_phases=[]
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']]
        scoped=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=set(facts['cases'].values())-{entry})
        if spawn_site in scoped.before:phase_spawns.append(phase['index'])
        if any(e[1]==0x800e1654 for _,e in scoped.events('call')):impact.append(phase['index'])
        if any(e[1]==0x80120734 for _,e in scoped.events('call')):target_phase.append(phase['index'])
        if repeating and spawns[-1][0] in scoped.before:strike_phases.append(phase['index'])
    if repeating:target_phase=phase_spawns
    if len(phase_spawns)!=1 or len(impact)!=1 or (not repeating and impact!=phase_spawns) or len(target_phase)!=1 or (repeating and len(strike_phases)!=1):raise ValueError('unresolved lightning lifecycle')
    reactions=[e[2][2]&0xffffffff for _,e in calls if e[1]==0x800e3820 and isinstance(e[2][2],int)]
    if len(set(reactions))!=1:raise ValueError('unresolved lightning response')
    if repeating and groups[9][0]['delay']!=0:raise ValueError('unresolved lightning repeat eligibility')
    return dict(repeating=repeating,impact_phase=impact[0],strike_phase=strike_phases[0] if repeating else None,strike_radius=spawns[-1][1][2][1] if repeating else 0,
                facts=facts,groups=groups,radius=spawn[2][1],height=spawn[2][2],speed=stored(source.member(bolt,20)),
                pulse_life=stored(source.member(pulse,36)),pulse_fade_at=(image.word(0x80120814)&65535)-1,
                pulse_grow=source.sx16(image.word(0x80120830)),pulse_shrink=-source.sx16(image.word(0x80120844)),
                spark_life_min=stored(source.member(source.member(root,groups[10][0]['slot']),36)) if repeating else image.word(0x8010C8D8)&65535,spark_life_range=0 if repeating else 1<<((image.word(0x8010C8C4)>>6)&31),
                clone_limit=source.sx16(image.word(0x8010D4A4 if repeating else 0x8010C7B0)),clone_turn=source.sx16(image.word(0x8010CFF0 if repeating else 0x8010C52C)),
                target_phase=target_phase[0],flight_phase=phase_spawns[0],response=reactions[0],response_clock=0 if repeating else source.sx16(image.word(0x8010C62C)),focus_kick=image.word(0x8010D600 if repeating else 0x8010C930)&65535)


def arranged_profile(effect):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    if [e[2][1] for _,e in init.events('call') if e[1]==objects.GRAPHIC]!=[0,9,7,10,8,2,1]:return None
    facts,analysis=source.analyze(initializer);facts['phases']=source.timeline(facts,analysis);facts['camera_schedule']=source.camera_schedule(facts,analysis)
    decoded=objects.constructors(facts,image)
    groups={n:[o for o in decoded['objects'] if o['animation']==n] for n in (0,9,7,10,8,2,1)}
    if decoded['blocked'] or [len(groups[n]) for n in groups]!=[6,12,4,12,4,12,4] or len(facts['phases'])!=5:raise ValueError('unresolved arranged lightning constructors')
    expected={0x8010DD1C:0x14620002,0x8010DDD4:0x28420401,0x8010DE40:0x0C0481CD,
              0x8010DE70:0x14620008,0x8010DF50:0xAC44001C,0x8010DF84:0x14430006,
              0x8010DFAC:0x14400019,0x8010DFE8:0x28420401,0x8010E000:0xAC80001C,
              0x8010E118:0x2842FFBA,0x8010E134:0x12200002,0x8010E1B4:0x0082102A,
              0x8010E1C8:0xAE020008,0x8010E224:0xAC550024,0x8010E26C:0xAC550024,
              0x8010E284:0xAC540014,0x8010E28C:0xAC6212FC,0x8010E290:0xA4741324,
              0x8010E300:0x10400007,0x8010E310:0x2442FFFF,0x8010E314:0x1C400002,
              0x8010E378:0x0C048203,0x80120814:0x28420021,0x80120830:0x24420200,0x80120844:0x2442FF00}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'arranged lightning source changed at {pc:#x}')
    root=('global',facts['state_global'])
    wash_calls=[(pc,e) for pc,e in init.events('call') if e[1]==0x8011cf4c]
    if len(wash_calls)!=1:raise ValueError('unresolved arranged lightning wash')
    from spell_scene_support import _slot,_delta
    wash=_slot(init,root,('call',0x8011cf4c,wash_calls[0][0]));wash_steps=[]
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']]
        scoped=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=set(facts['cases'].values())-{entry},cut_backedges=True)
        wash_steps.append(_delta(scoped,source.member(source.member(root,wash),80)))
    return dict(facts=facts,groups=groups,wash_steps=wash_steps,clone_limit=source.sx16(image.word(0x8010E118)),clone_turn=source.sx16(image.word(0x8010DDC4)),
                response_clock=image.word(0x8010DF7C)&65535,response=0x8016F150,turn_delay=source.sx16(image.word(0x8010DFA8)),turn_step=source.sx16(image.word(0x8010DFD8)),turn_limit=(image.word(0x8010DFE8)&65535)-1,
                spark_life=image.word(0x8010E178)&65535,pulse_life=image.word(0x8010E178)&65535,pulse_fade_at=(image.word(0x80120814)&65535)-1,
                pulse_grow=source.sx16(image.word(0x80120830)),pulse_shrink=-source.sx16(image.word(0x80120844)),focus_kick=(image.word(0x8010E288)&65535)>>12)


def contracting_profile(effect):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    if [e[2][1] for _,e in init.events('call') if e[1]==objects.GRAPHIC]!=[0,9,9,8,3,2]:return None
    facts,analysis=source.analyze(initializer);facts['phases']=source.timeline(facts,analysis)
    decoded=objects.constructors(facts,image);groups={n:[o for o in decoded['objects'] if o['animation']==n] for n in (0,9,8,3,2)}
    if decoded['blocked'] or any(len(v)!=6 for v in groups.values()) or len(facts['phases'])!=5:raise ValueError('unresolved contracting lightning constructors')
    expected={0x8010EB7C:0x14620002,0x8010EBDC:0x14400010,0x8010EC2C:0x14400010,0x8010ECB0:0x14620082,
              0x8010ED00:0xAC44001C,0x8010ED4C:0x10400020,0x8010ED98:0x3C03FFFC,
              0x8010EDBC:0x2442FFC0,0x8010EDDC:0x14600002,0x8010EE08:0x14600005,
              0x8010EE18:0x0C038E08,0x8010EE28:0x14620011,0x8010EE40:0xAC40001C,
              0x8010EE70:0x14620012,0x8010EE90:0xAC40001C,0x8010EF50:0x0C038595,
              0x8010EFB4:0x2842FFBA,0x8010F04C:0x0082102A,0x8010F060:0xAE020008,
              0x8010F06C:0x10400013,0x8010F118:0xAE000014,0x8010F124:0x1040000B,
              0x8010F1E4:0x00021303,0x8010F1E8:0xAE020038,0x8010F1F0:0xAE020034,
              0x8010F244:0x0C048203,0x8010F2AC:0x00021303,0x8010F2B0:0xAC62004C,
              0x8010F2B4:0xAC620048,0x8010F2BC:0x0C0482D6,
              0x8012088C:0xAC850028,0x80120890:0xAC860030,0x80120894:0xAC87002C,
              0x8012089C:0xAC820034,0x80120C50:0x96C20028,0x80120C68:0x96C2002C,
              0x80120C94:0x96C20030,0x80120CA4:0x96C20034,0x80120D10:0x00621823}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'contracting lightning source changed at {pc:#x}')
    from spell_scene_columns import constructors as columns,motion
    column_plan=columns(facts,image)
    if column_plan['blocked'] or len(column_plan['columns'])!=2:raise ValueError('unresolved contracting column constructors')
    column_motion=motion(facts,image);height_keys=[row['fields']['lower_height'] for row in column_motion['columns']]
    height_samples=source.sample_scalar_channels(column_motion['plan'],fields=height_keys)
    return dict(facts=facts,groups=groups,clone_limit=source.sx16(image.word(0x8010EFB4)),clone_turn=source.sx16(image.word(0x8010EB20)),
                scale_field=image.word(0x8010F1DC)&65535,columns=column_plan['columns'],column_heights=[height_samples[key] for key in height_keys],
                column_starts=[image.word(at)&65535 for at in (0x8010EBD8,0x8010EC28)],
                primary_off=image.word(0x8010ECAC)&65535,spark_off=image.word(0x8010EE24)&65535,aura_off=image.word(0x8010EE6C)&65535,
                reaction_period=image.word(0x8010EDD4)&65535,response=0x8016F150,
                pulse_life=image.word(0x8010F0FC)&65535,pulse_fade_at=(image.word(0x80120814)&65535)-1,
                pulse_grow=source.sx16(image.word(0x80120830)),pulse_shrink=-source.sx16(image.word(0x80120844)),spark_life=image.word(0x8010F0B4)&65535)
