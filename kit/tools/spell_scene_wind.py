"""Shared wind geometry and bounded source scene profiles."""
import spell_scene_source as source
import spell_scene_objects as objects


def strip_edges(amplitude,width,height,segments):
    if not 3<=segments<=64 or any(not 0<=v<=1024 for v in (amplitude,width,height)):raise ValueError('invalid wind curve dimensions')
    from battle_drops import trunc
    result=[]
    for index in range(segments+1):
        t=4096-index*(8192//segments);parabola=trunc(t*t,4096)-4096
        outer=amplitude+trunc(amplitude*parabola,4096)
        inner=outer if index==0 else amplitude+trunc(width*parabola,4096)
        y=trunc(height*t,4096)
        result.append([[outer,y,0],[inner,y,0]])
    return result


def constructors(effect,image=None):
    image=image or source.Image();facts,_=source.analyze(int(effect['initializer'],16),image)
    decoded=objects.constructors(facts,image,constructor=0x80125958)
    if not decoded['objects']:return None
    for pc,word in {0x80125994:0xAFD3006C,0x80125AC4:0xAC400030,0x80125AC8:0xAC40002C,0x801259BC:0x00082080,0x80125A18:0x0C052B7A,
                    0x80125A1C:0x34050001,0x80125A2C:0xA2000014,0x80125A44:0xA2120004,
                    0x801251D4:0x00840018,0x801251F0:0x00021303,0x801251F8:0x2442F000,
                    0x801254B8:0x0043001A,0x801254B4:0x34022000,0x801254E8:0x02228823,
                    0x80125728:0x02258823,0x801257FC:0x8E420044}.items():
        if image.word(pc)!=word:raise ValueError(f'wind strip source changed at {pc:#x}')
    rows=[]
    for row in decoded['objects']:
        initial=row['initial'];segments=row['arguments'][0]
        if not all(isinstance(v,int) for v in [segments]+[initial.get(n) for n in (68,72,76)]):raise ValueError('unresolved wind curve parameters')
        rows.append(dict(instance=row['instance'],segments=segments,amplitude=initial[68]>>12,width=initial[72]>>12,height=initial[76]>>12))
    return rows


def reaction(start,duration):
    import struct,maindec
    from actor_script import OP_LEN_HW
    cursor=0x8016f088;offset=[0,0];color=[128]*3;white=False;offsets=[];tints=[];flashes=[]
    for _ in range(32):
        op=struct.unpack_from('<h',maindec.body(),cursor-maindec.MBASE)[0];length=OP_LEN_HW[op]
        args=struct.unpack_from('<'+'h'*(length-1),maindec.body(),cursor+2-maindec.MBASE)
        if op==0:
            release=len(offsets)-1;offsets=offsets[1:];tints=tints[1:];flashes=flashes[1:]
            return dict(start=start,release=release,animation=1,offsets=offsets,tints=tints,flash_frames=flashes)
        if op==3:offsets.extend([offset]*args[0]);tints.extend([color]*args[0]);flashes.extend([3 if white else None]*args[0])
        elif op==25:
            if args[0]!=1:raise ValueError('unresolved wind reaction offset mode')
            offset=list(args[1:])
        elif op==41:color=list(args)
        elif op==38:white=True
        elif op==39:white=False
        elif op==4:
            if args!=(1,):raise ValueError('unresolved wind hurt animation')
        elif op!=34:raise ValueError('unsupported wind reaction operation')
        cursor+=2*length
    raise ValueError('unterminated wind reaction')


def storm_program(effect,pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    calls=[e[1] for _,e in init.events('call')]
    if 0x80125958 not in calls or sum(c==objects.GRAPHIC for c in calls)!=1:return None
    rows=constructors(effect,image)
    if len(rows)!=6:return None
    facts,analysis=source.analyze(initializer);phases=source.timeline(facts,analysis)
    if [p['updates'] for p in phases]!=[64,32,64,64,56]:raise ValueError('unresolved wind trail phases')
    expected={0x8010AA54:0x34020001,0x8010AA58:0xACC20070,0x8010AA5C:0xACC40044,
              0x8010AA60:0xACC30048,0x8010AAAC:0x00021300,0x8010AB1C:0x2442E000,
              0x8010ABD4:0xAE220038,0x8010ADEC:0x28420024,0x8010AE10:0xAC400070,
              0x8010AE3C:0x00000000,0x8010AEC0:0x000210C3,0x8010AE50:0xAC650024,
              0x8010AC08:0x3402000A,0x8010ACE4:0x0C0496CA,0x8010AD34:0x2442EDB7}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'wind trail source changed at {pc:#x}')
    import export_spell_scenes as export
    from battle_drops import trunc
    duration=sum(p['updates'] for p in phases)+1;end=duration-1
    caster=[];wash=[];tracks=[];meshes=[];history=[None]*6;running=False;clock=0
    samples=[[] for _ in rows];edges=[[] for _ in rows]
    origin=[export.signed_word(0x8016B80C),export.signed_word(0x8016B810),-60]
    delta=(export.signed_word(0x8016B814)-origin[0])*4096
    for u in range(duration):
        tint=2*min(u,64)-4*min(max(u-64,0),32)
        if u>96:tint=128-2*min(u-96,64)
        caster.append(export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-60*4096-400*min(max(u-64,0),32)*(min(max(u-64,0),32)+1)//2],tint=[tint&255]*3))
        wash.append([0]*3)
        if u==97:history[0]=[0,0,0]
        if u==161:running=True
        if running:
            clock+=1
            if clock>=36:history=[None]*6;running=False
            for i in range(5,0,-1):history[i]=history[i-1].copy() if history[i-1] is not None else None
            if history[0] is not None and running:history[0][0]=trunc((clock+1)*delta,8)
        for i,row in enumerate(rows):
            color=[128-2*min(max(u-96,0),64),128-min(max(u-96,0),64),128] if i==0 and u>=97 else [0,4*(16-i),8*(16-i)]
            samples[i].append(export.sample(visible=history[i] is not None and u<end,position=history[i].copy() if history[i] is not None else [0]*3,tint=color))
            amplitude=((image.word(0x8010AA3C)&65535)<<16|(image.word(0x8010AA44)&65535))>>12 if i==0 and u>=97 else row['amplitude']
            reset_width=((image.word(0x8010AA4C)&65535)<<16|(image.word(0x8010AA50)&65535))>>12
            width=reset_width-2*min(max(u-96,0),64) if i==0 and u>=97 else row['width']
            edges[i].append(strip_edges(amplitude,width,row['height'],row['segments']))
    tracks=[caster]+samples
    for i,row in enumerate(rows):meshes.append(dict(kind='strip',anchor='world',origin=origin,track=i+1,start=97,stop=end,radius=row['amplitude'],segments=row['segments'],inner=[0]*3,outer=[0]*3,strip_edges=edges[i] if i==0 else edges[i][:1]))
    # The subtractive full-screen colour plane grows to64 and fades during phase4.
    colors=[[max(0,(4096*min(u,64)-4681*min(max(u-224,0),56))>>12)]*3 if 0<u<end else None for u in range(duration)]
    return dict(group=True,impact=224,duration=duration,initial_draws=0,center_after_reaction=False,tracks=tracks,objects=[dict(anchor='caster',track=0)],cameras=export.source_cameras(effect),meshes=meshes,wash=wash,wash_blend='additive',screen_washes=[dict(depth=7,blend='subtractive',colors=colors)],reaction=reaction(171,duration))


def shredding_program(effect,pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True);calls=[e[1] for _,e in init.events('call')]
    if 0x80125958 not in calls or sum(c==objects.GRAPHIC for c in calls)!=1:return None
    rows=constructors(effect,image)
    if len(rows)!=16:return None
    facts,analysis=source.analyze(initializer);phases=source.timeline(facts,analysis)
    if [p['updates'] for p in phases]!=[64,32,48,64,56]:raise ValueError('unresolved paired wind phases')
    expected={0x80109854:0xAC460070,0x801098A0:0x2442F000,0x80109920:0x34020012,
              0x8010998C:0x0C0496CA,0x80109A70:0x28420030,0x80109ABC:0x8C42FFF8,
              0x80109B54:0x00021103,0x80109BB8:0x00031903,0x80109C04:0x00031903,
              0x80109B64:0x00042180,0x80109B84:0x000421C0,0x80109B74:0x16000014,
              0x80109BC4:0x00621823,0x80109C0C:0x00621821,0x80109B78:0xAE430028}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'paired wind source changed at {pc:#x}')
    import export_spell_scenes as export
    duration=sum(p['updates'] for p in phases)+1;end=duration-1
    caster=[];tints=export.source_tints(effect,duration);samples=[[] for _ in rows];edges=[[] for _ in rows]
    history=[None]*16;clock=0;running=False
    for u in range(duration):
        falling=min(max(u-64,0),32)
        caster.append(export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-60*4096-400*falling*(falling+1)//2],tint=tints[u]))
        if u==97:history[0]=history[1]=dict(position=[0]*3,target_weight=[0]*3)
        if u==145:running=True
        if running:
            clock+=1
            if clock>=48:history=[None]*16;running=False
            for i in range(15,1,-1):history[i]=history[i-2]
            for i in range(2):
                if history[i] is not None and running:
                    history[i]=dict(position=[0,(-1 if i==0 else 1)*60*export.effect_sine(clock*128),30*export.effect_sine(clock*64)],target_weight=[256*(clock+1),256*(clock+1),0])
        for i,row in enumerate(rows):
            state=history[i] or dict(position=[0]*3,target_weight=[0]*3)
            samples[i].append(export.sample(visible=history[i] is not None and u<end,tint=[0,64,127],**state))
            amplitude=80 if i<2 and u>=97 else row['amplitude']
            width=78-min(max(u-96,0),48) if i<2 and u>=97 else row['width']
            edges[i].append(strip_edges(amplitude,width,row['height'],row['segments']))
    meshes=[dict(kind='strip',anchor='caster',origin=[0,0,-60],track=i+1,start=97,stop=end,radius=row['amplitude'],segments=row['segments'],inner=[0]*3,outer=[0]*3,strip_edges=edges[i] if i<2 else edges[i][:1]) for i,row in enumerate(rows)]
    colors=[[max(0,(4096*min(u,64)-4681*min(max(u-208,0),56))>>12)]*3 if 0<u<end else None for u in range(duration)]
    return dict(impact=208,duration=duration,initial_draws=0,center_after_reaction=False,tracks=[caster]+samples,objects=[dict(anchor='caster',track=0)],cameras=export.source_cameras(effect),meshes=meshes,wash=[[0]*3]*duration,wash_blend='additive',screen_washes=[dict(depth=7,blend='subtractive',colors=colors)],reaction=reaction(163,duration))


def healing_trail_program(effect,pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    if [e[2][1] for _,e in init.events('call') if e[1]==objects.GRAPHIC]!=[0,1]:return None
    facts,analysis=source.analyze(initializer);facts['phases']=source.timeline(facts,analysis)
    decoded=objects.constructors(facts,image);particles=[o for o in decoded['objects'] if o['animation']==1]
    if len(particles)!=30 or len(facts['phases'])!=4:return None
    if decoded['blocked'] or [p['updates'] for p in facts['phases']]!=[64,64,96,64]:raise ValueError('unresolved healing trail constructors')
    expected={0x8010A094:0x34130001,0x8010A288:0xAC530000,0x8010A420:0xAC600000,0x80109E1C:0x34130E63,0x80109EDC:0x3403001D,0x80109F2C:0x2673FF81,
              0x8010A194:0xAC450000,0x8010A1A0:0xAC440008,0x8010A200:0x24420090,
              0x8010A210:0x2442E040,0x8010A220:0x2442FF38,0x8010A2A8:0x2463FFFC,
              0x8010A2BC:0x14400007,0x8010A2FC:0x14620005,0x8010A338:0x2442F000,
              0x8010A3B8:0x2442FFC0,0x8010A3D0:0x2442FFC0,0x8010A400:0x0C038595,
              0x8010A47C:0x3411001D,0x8010A498:0x26080074,0x8010A528:0x1E20FFDC,0x8010A5A4:0x2A22001E,0x8010A4A8:0x8C620000,0x8010A4B4:0xAC820000,0x8010A4E0:0xAC82003C,
              0x8010A4EC:0xAC82001C,0x8010A510:0xA4820044,0x8010A52C:0xAC620014,
              0x8010A560:0x24420080,0x8010A568:0x28420801}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'healing trail source changed at {pc:#x}')
    import export_spell_scenes as export
    import spell_scene_columns as columns
    column_plan=columns.motion(facts,image)
    if column_plan['blocked'] or len(column_plan['columns'])!=1:raise ValueError('unresolved healing trail column')
    binding=column_plan['columns'][0];column=binding['column'];fields=binding['fields']
    motion=source.sample_scalar_channels(column_plan['plan'],fields=[fields[n] for n in ('lower_height','scale_x','scale_y','scale_z')])
    plan=source.scalar_channels(facts,analysis);scalars=source.sample_scalar_channels(plan,fields=[168,172,176])
    duration=sum(p['updates'] for p in facts['phases'])+1;end=duration-1
    tints=export.source_tints(effect,duration);caster=[];tracks=[[] for _ in particles]
    head=dict(position=[0]*3,scale=[4096]*3,angles=[0]*3);history=[dict(head) for _ in particles]
    frame=effect['animations'][1]['frames'][0]['piece'];frame=int(frame.removeprefix('piece_')) if isinstance(frame,str) else frame
    for u in range(duration):
        age=min(max(u-64,0),64)
        caster.append(export.sample(pieces[0] if 0<u<128 else None,position=[0,0,-60*4096-200*age*(age+1)//2],tint=tints[u]))
        if u==65:history=[dict(position=[100*4096,0,-300*4096],scale=[4096]*3,angles=[0]*3) for _ in particles]
        head=dict(history[0],scale=[scalars[n][u]>>12 for n in (168,172,176)])
        if 65<=u<=224:head['angles']=[0,0,144*(u-64)]
        for i in range(29,0,-1):history[i]=dict(head if i==1 else history[i-1])
        history[0]=head
        for i,state in enumerate(history):tracks[i].append(export.sample(pieces[frame] if 65<=u<224 else None,size=min(2048,1+128*max(u-64,0)),tint=[(29-i)*127//29]*3,**state))
    column_track=[export.sample(scale=[motion[fields[n]][u] for n in ('scale_x','scale_y','scale_z')]) for u in range(duration)]
    mesh=dict(kind='column',anchor='target',track=31,start=129,stop=end,radius=column['lower']['radius'],segments=column['segments'],inner=column['upper']['color'],outer=column['lower']['color'],base_heights=motion[fields['lower_height']],heights=[column['upper']['height']]*duration)
    colors=[[max(0,(4096*min(u,64)-4096*min(max(u-160,0),64))>>12)]*3 if 0<u<end else None for u in range(duration)]
    return dict(impact=end,duration=duration,initial_draws=0,center_after_reaction=False,tracks=[caster]+tracks+[column_track],objects=[dict(anchor='caster',track=0)]+[dict(anchor='target',track=i+1) for i in range(30)],cameras=export.source_cameras(effect),meshes=[mesh],wash=[[0]*3]*duration,wash_blend='additive',screen_washes=[dict(depth=7,blend='subtractive',colors=colors)],reaction=export.support_reaction(193,duration))


def sleep_program(effect,pieces,rows):
    """Sphere sprites + the shared row-wave helper, lowered to ordinary scene data."""
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    if not any(e[1]==0x80122AAC for _,e in init.events('call')):return None
    facts,analysis=source.analyze(initializer)
    if not any(e[1]==0x80123054 for _,e in analysis.events('call')):return None
    import hashlib
    contracts=[(0x80108B80,0x80109358,'6e0e0f11429b116737e1d492594460dcc2a40aa5b025427a0be8b5f33879a361'),
               (0x80123054,0x8012325C,'58a13fa99dbcfd38a2ec6432213121a6a1ec23e8e420f75f9607f50d952b7cbe'),
               (0x80122AAC,0x80122EB0,'ccb3723d1fba461b4572f27feaa4c6d0f5c661fe0d69483c414b84d1c9e35094'),
               (0x8016DE9C,0x8016DEDE,'f57c3a552904d01b5ada08265583b5dcbe546828068dce3fc5fa2d810c3e2adb')]
    for start,stop,digest in contracts:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('sleep scene source changed; requalify its equations')
    if len(rows)!=64 or [p['updates'] for p in source.timeline(facts,analysis)]!=[64,64,64,64,96,64]:raise ValueError('unresolved sleep scene timing or wave rows')
    import export_spell_scenes as export
    duration=417;caster=[];sprites=[];animation=[];wave=[]
    tints=export.source_tints(effect,duration);xy=1;z=1;velocity=0
    for u in range(duration):
        age=min(max(u-64,0),64)
        caster.append(export.sample(pieces[0] if 0<u<128 else None,position=[0,0,-60*4096-400*age*(age+1)//2],tint=tints[u]))
        if u==129:velocity=524288
        if 129<=u<=192:xy+=131072;velocity-=8192;z+=velocity
        elif 193<=u<=256:xy+=131072;velocity+=8192;z-=velocity
        elif 257<=u<=352:velocity+=8192;z+=velocity
        if u==256:z=1;velocity=0
        sprites.append(export.sample(scale=[xy>>12,xy>>12,z>>12],angles=[0,0,32*min(max(u-256,0),96)],size=0,node_angles=[0]*3,tint=[127]*3))
        animation.append(export.sample(export.clip_piece(effect,4,u,pieces,True)))
        if not 129<=u<352:wave.append(None);continue
        phase=(u-128)%200;vertices=[]
        for row in range(64):
            a=(export.effect_sine(((4*row+phase)<<12)//200)*50)>>12
            b=(export.effect_sine(((4*row+phase+3)<<12)//200)*50)>>12
            vertices.append([[a-100,4*row],[a+420,4*row],[b-100,4*row+4],[b+420,4*row+4]])
        rise=min(u-128,64);fall=min(max(u-256,0),96)
        wave.append(dict(vertices=vertices,tint=0,rgb=[max(0,(6144*rise-4096*fall)>>12)]+[max(0,(4096*rise-2730*fall)>>12)]*2))
    # Dispatch advances the actor once more: waits3/164/1 then a one-update home move.
    reaction=dict(start=193,release=168,animation=1,offsets=[[0,0]]*168,
                  tints=[[128]*3]*2+[[128,64,64]]*164+[[128]*3]*2,
                  flash_frames=[None]*2+[3]*164+[None]*2,active_samples=[True]*167+[False])
    bindings=[dict(anchor='caster',track=0)]
    origin=[export.signed_word(0x8016B814),export.signed_word(0x8016B818),0]
    for i in range(50):bindings.append(dict(anchor='world',origin=origin,track=1,piece_track=2,particle_index=i,random_size=export.variation(2*i,4096,1365),random_node_angle=export.variation(2*i+1,4096)))
    return dict(group=True,impact=361,duration=duration,initial_draws=100,center_after_reaction=False,
                tracks=[caster,sprites,animation],objects=bindings,cameras=export.source_cameras(effect),meshes=[],wash=[[0]*3]*duration,wash_blend='additive',reaction=reaction,
                screen_layers=[dict(entries=rows,samples=wave,copies=2)],
                emitter=dict(kind='spherical_sprites',start=129,stop=352,count=50,radius=200,roots=export.square_roots(40000),scale_track=1,life_max=180,color=[127]*3))


def shining_program(effect,pieces):
    import hashlib
    import spell_scene_columns as columns
    import spell_scene_sound as sound
    image=source.Image();initializer=int(effect['initializer'],16)
    if initializer!=0x8010B06C:return None
    for start,stop,digest in [(0x8010B06C,0x8010B404,'83943da5e9271fb4d0facbe043a5eab09363d54dcc1178f98cc1b1134dd8d640'),
                              (0x8010B404,0x8010BFD8,'a6e87e91c750716bf1e20f803897e48c97249e5db73c64cb05547c8b4a7fc9a3')]:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('Shining Wind source changed; requalify its equations')
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    groups={n:[r for r in decoded['objects'] if r['animation']==n] for n in range(5)}
    if decoded['blocked'] or [len(groups[n]) for n in range(5)]!=[1,20,20,20,30]:raise ValueError('unresolved Shining Wind objects')
    if [p['updates'] for p in source.timeline(facts,analysis)]!=[64,32,64,160,64]:raise ValueError('unresolved Shining Wind phases')
    column_plan=columns.constructors(facts,image)
    if column_plan['blocked'] or len(column_plan['columns'])!=2:raise ValueError('unresolved Shining Wind columns')
    import export_spell_scenes as export
    duration=385;tracks=[];bindings=[];party=[128,0,0];enemy=[-128,0,0]
    tints=export.source_tints(effect,duration)
    def add(track,anchor='world',**fields):
        bindings.append(dict(anchor=anchor,track=len(tracks),**fields));tracks.append(track)
    add([export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-60*4096-400*min(max(u-64,0),32)*(min(max(u-64,0),32)+1)//2],tint=tints[u]) for u in range(duration)],'caster')
    # The orbiting group never calls the animation updater; its first image is held.
    orbit=len(tracks);tracks.append([export.sample(export.clip_piece(effect,3,0,pieces,True),size=2048,angles=[0,0,96*age],node_angles=[0,0,1+64*age]) for age in range(121)])
    for i in range(20):bindings.append(dict(anchor='world',origin=enemy,track=orbit,particle_index=i))
    pulse=len(tracks);tracks.append([export.sample(export.clip_piece(effect,1,0,pieces,True))])
    for i in range(20):bindings.append(dict(anchor='world',origin=party,track=pulse,particle_index=20+i,particle_part='pulse'))
    drift=len(tracks);tracks.append([export.sample(export.clip_piece(effect,4,age,pieces,True),size=0,node_angles=[0,0,0]) for age in range(duration)])
    streak=len(tracks);tracks.append([export.sample(export.clip_piece(effect,2,age,pieces,True),size=0,node_angles=[0,0,32*age]) for age in range(duration)])
    for i in range(50):bindings.append(dict(anchor='world',origin=enemy,track=drift if i<30 else streak,particle_index=40+i,random_size=export.variation(20+2*i,4096 if i<30 else 2048,1365),random_node_angle=export.variation(21+2*i,4096)))
    model=len(tracks);tracks.append([export.sample(scale=[(1+262144*(min(max(u-96,0),64)-min(max(u-320,0),64)))>>12]*2+[4096]) for u in range(duration)])
    meshes=[]
    for column,origin in zip(column_plan['columns'],(party,enemy)):
        meshes.append(dict(kind='column',anchor='world',origin=origin,track=model,start=97,stop=384,radius=column['lower']['radius'],top_radius=column['upper']['radius'],segments=column['segments'],blend=column['blend'],inner=column['upper']['color'],outer=column['lower']['color'],heights=[0]*duration,base_heights=[-200]*duration))
    restarts=list(range(161,321,36));base=export.fog_reaction();last=restarts[-1]
    response=dict(start=161,release=last+base['release']-161,offsets=[],flash_frames=[])
    for u in range(161,last+len(base['offsets'])):
        age=u-max(at for at in restarts if at<=u);active=age<len(base['offsets'])
        response['offsets'].append(base['offsets'][age] if active else [0,0]);response['flash_frames'].append(base['flash_frames'][age] if active else None)
    response['active_samples']=[(u-max(at for at in restarts if at<=u))<len(base['offsets']) for u in range(161,last+len(base['offsets']))]
    ally_base=export.support_reaction(0,1);ally=export.support_restarts(161,duration,restarts)
    for key in ('offsets','tints','flash_frames'):ally[key]=ally[key][:last+len(ally_base['offsets'])-161]
    # Caller comparisons and the idle pass both use the helper's decrementing counter.
    pulses=sound.pulse_events([r['delay'] for r in groups[1]],160,160,repeat_idle=True)
    return dict(group=True,center_after_reaction=False,impact=384,duration=duration,initial_draws=120,
                tracks=tracks,objects=bindings,meshes=meshes,cameras=export.source_cameras(effect,unresolved=(64,)),
                wash=[[max(0,(2048*(min(u,64)-min(max(u-256,0),64)))>>12)]*3 for u in range(duration)],wash_blend='additive',reaction=response,party_reaction=ally,
                emitters=[dict(kind='orbiting_sprites',start=161,spawn_stop=199,stop=320,count=20,particle_start=0,radius=50,roots=export.square_roots(2500),height_range=200,life_max=120,spawn_at=[161+r['delay'] for r in groups[3]],color=[127]*3),
                          dict(kind='scheduled_pulses',start=161,stop=384,count=20,particle_start=20,radius=50,roots=export.square_roots(2500),height_range=200,pulse_spawns=pulses,pulse_life=48,pulse_fade_at=32,pulse_grow=512,pulse_shrink=256,color=[127]*3),
                          dict(kind='drifting_sprites',start=97,spawn_stop=319,stop=384,count=50,particle_start=40,radius=300,roots=export.square_roots(90000),height_range=80,spawn_height_min=160,velocity_min=7680,velocity_range=1024,life_max=180,color=[127]*3)])
