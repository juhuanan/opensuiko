"""Fire scene groups lowered through the shared constructor and sprite grammars."""
import hashlib
import spell_scene_source as source
import spell_scene_objects as objects


def final_program(effect,pieces):
    initializer=int(effect['initializer'],16)
    if initializer!=0x80101EB0:return None
    image=source.Image()
    for a,b,digest in [(0x80101EB0,0x80102280,'5df28b336bc696dec5c3f937f23c0fb2708ceaa67d3907b56b0c6ac6e2c6cfa8'),
                       (0x80102280,0x80102C7C,'acf9438a33795af80d285d2d827f5ffcec82d519267d04be56d82c6d3d9afd91'),
                       (0x8012496C,0x80124C4C,'4cace412a47800643ea5aa6e2a3ce30589abec04e1fc3b7f79750b3033bd6850'),
                       (0x80124C58,0x80124F84,'80af4f4bf927fcdbaef074f9a749ce0dbd437f285c60f7052e4e3f61720ae729'),
                       (0x80124530,0x8012496C,'6f3ff9862131fdaf313daa6b7ad36438cc085bac36bff94b90f7b19b54c6b73e'),
                       (0x801250B8,0x801251D4,'5fd3b4d2f07aec3742efbe852d11374009b6e7d5e6eee1afb2c19b5c430dfa4b')]:
        if hashlib.sha256(image.data[a-image.base:b-image.base]).hexdigest()!=digest:raise ValueError('Final Flame source changed; requalify its equations')
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    groups={n:[r for r in decoded['objects'] if r['animation']==n] for n in (0,10,12,6,13)}
    if decoded['blocked'] or [len(groups[n]) for n in groups]!=[1,20,30,30,30] or [p['updates'] for p in source.timeline(facts,analysis)]!=[64,128,296,96,1]:raise ValueError('unresolved Final Flame lifecycle')
    import export_spell_scenes as export
    duration=586;field=[export.signed_word(0x8016B814),export.signed_word(0x8016B818),0];flight=[field[0]+150,field[1],-300]
    tints=export.source_tints(effect,duration)
    caster=[export.sample(pieces[0] if 0<u<98 else None,position=[0,0,-60*4096],tint=tints[u]) for u in range(duration)]
    meteor=[export.sample(export.clip_piece(effect,10,age,pieces,True)) for age in range(duration)]
    before=[export.sample(visible=u<193,node_angles=[0,0,2049]) for u in range(duration)]
    after=[export.sample(visible=u>=193,node_angles=[0,0,2049]) for u in range(duration)]
    head=[export.sample(export.clip_piece(effect,12,0,pieces,True),size=0,node_angles=[0,0,-1023]) for _ in range(duration)]
    burst=export.animation_track(effect,6,pieces,size=0)
    scales=[1+93206*min(max(u-212,0),181) if u>=193 else 1 if u<64 else 0x1000000 for u in range(duration)]
    scales=[min(v,0x1000000)>>12 for v in scales]
    model=[export.sample(scale=[v]*3,size=0) for v in scales]
    flame=export.animation_track(effect,13,pieces,size=0)
    tracks=[caster,meteor,before,after,head,burst,model,flame];bindings=[dict(anchor='caster',track=0)]
    for i in range(20):
        bindings.append(dict(anchor='caster',track=2,piece_track=1,particle_index=i))
        bindings.append(dict(anchor='world',origin=flight,track=3,piece_track=1,particle_index=i))
    for i in range(30):
        size=export.variation(i,4096,8192) if i<29 else export.variation(0,1,12288)
        bindings.append(dict(anchor='world',origin=flight,track=4,particle_index=20+i,random_size=size))
        bindings.append(dict(anchor='world',origin=flight,track=5,particle_index=20+i,particle_part='spark',random_size=export.variation(30+i,4096,4096)))
    for i in range(30):bindings.append(dict(anchor='world',origin=field,track=6,piece_track=7,particle_index=50+i,random_size=export.variation(61+2*i,2048,4096)))
    meshes=[];dome_track=len(tracks)
    tracks.append([export.sample(scale=[(1+174762*max(0,min(u-392,96)))>>12]*3) for u in range(duration)])
    previous_radius=0;previous_height=-200
    for i in range(5):
        angle=1024*(i+1)//5
        radius=-export.battle_drops.trunc(200*export.effect_sine(angle),4096)
        height=-export.battle_drops.trunc(200*export.effect_sine(angle+1024),4096)
        meshes.append(dict(kind='column',anchor='world',origin=field,track=dome_track,start=393,stop=489,radius=abs(previous_radius),top_radius=abs(radius),segments=24,angles=[0,0,2048],outer=[51*i,39*i,32*i],inner=[51*(i+1)-1,39*(i+1)-1,32*(i+1)-1],base_heights=[previous_height]*duration,heights=[height]*duration))
        previous_radius,previous_height=radius,height
    meshes.append(dict(kind='fan',anchor='world',origin=field,track=6,start=213,stop=488,radius=170,segments=24,inner=[32,128,128],outer=[0,0,0],blend='subtractive',depth=379))
    cameras=export.source_cameras(effect,unresolved=(129,393,393))
    # Both calls on393 read the same current camera; the second replaces the target.
    cameras=[c for i,c in enumerate(cameras) if i+1==len(cameras) or cameras[i+1]['at']!=c['at']]
    base=export.reaction_track();starts=list(range(229,489,36));offsets=[];flashes=[];active=[]
    for u in range(starts[0],starts[-1]+len(base['offsets'])):
        age=u-max(at for at in starts if at<=u);on=age<len(base['offsets'])
        offsets.append(base['offsets'][age] if on else [0,0]);flashes.append(base['flash_frames'][age] if on else None);active.append(on)
    return dict(group=True,center_after_reaction=False,impact=584,duration=duration,initial_draws=120,tracks=tracks,objects=bindings,meshes=meshes,cameras=cameras,
                wash=[[max(0,(rise*min(u,64)-fall*min(max(u-488,0),96))>>12) for rise,fall in ((2048,1365),(4096,2730),(4096,2730))] for u in range(duration)],wash_blend='subtractive',
                reaction=dict(start=229,release=starts[-1]+base['release']-229,offsets=offsets,flash_frames=flashes,active_samples=active),
                emitters=[dict(kind='ballistic_sprites',start=65,stop=585,count=20,spawn_at=[65+r['delay'] for r in groups[10]],radius=30,roots=export.square_roots(900),height_range=40,gravity=-341,min_z=-299,color=[127]*3),
                          dict(kind='ballistic_sprites',particle_start=20,start=193,stop=585,count=29,spawn_at=[193+r['delay'] for r in groups[12]][:29],radius=120,roots=export.square_roots(14400),velocity_x=-38400,velocity_z=76800,landing_z=300,spark_track=5,focus_kick=5,color=[127]*3),
                          dict(kind='cycling_sprites',particle_start=50,start=193,stop=585,spawn_stop=488,count=30,radius=120,roots=export.square_roots(14400),scale_track=6,delay_modulus=64,delay_stride=2,initial_delay_draw=60,delay_bias=20,life_max=len(flame),color=[127]*3),
                          dict(kind='ballistic_sprites',particle_start=49,start=373,stop=585,count=1,spawn_at=[373],radius=2,roots=export.square_roots(4),velocity_x=-38400,velocity_z=76800,landing_z=300,spark_track=5,focus_kick=5,color=[127]*3)])


def dancing_program(effect,pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    if [e[2][1] for _,e in init.events('call') if e[1]==objects.GRAPHIC]!=[0,10,12,6,8,3,13]:return None
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    groups={n:[r for r in decoded['objects'] if r['animation']==n] for n in (0,10,12,6,8,3,13)}
    if decoded['blocked'] or [len(groups[n]) for n in groups]!=[1,4,1,4,40,4,15]:raise ValueError('unresolved dancing fire object groups')
    for start,stop,digest in [(0x80100168,0x801004F8,'426b185e9d19998c71e8bfad9f6b2ad9d9dda19ac566f409d619db13545cacb1'),
                              (0x801004F8,0x80100FE4,'01901fc73b1252fea97094e78ebbc4d09bccf5c1cf226def54e977ff4014ea16')]:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('dancing fire source changed; requalify its equations')
    phases=source.timeline(facts,analysis)
    if [p['updates'] for p in phases]!=[64,32,64,77,192,64]:raise ValueError('unresolved dancing fire phases')
    import export_spell_scenes as export
    end=sum(p['updates'] for p in phases);duration=end+1;tracks=[];bindings=[]
    arrow_life=sum(f['ticks'] for f in effect['animations'][8]['frames'])
    particle_life=sum(f['ticks'] for f in effect['animations'][13]['frames'])
    burst_life=sum(f['ticks'] for f in effect['animations'][6]['frames'])
    burst_stop=193+((45+burst_life-1)//burst_life)*burst_life-1
    plan,_=source.scalar_profile(initializer);scales=source.sample_scalar_channels(plan,fields=[176])[176]
    tints=export.source_tints(effect,duration);origin=[export.signed_word(0x8016B814),export.signed_word(0x8016B818),0]
    def add(track,anchor='world',**fields):
        bindings.append(dict(anchor=anchor,track=len(tracks),**(dict(origin=origin) if anchor=='world' else {}),**fields));tracks.append(track)
    add([export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-70*4096],tint=tints[u]) for u in range(duration)],'caster')
    for row in groups[10]:
        add([export.sample(export.clip_piece(effect,10,u-96,pieces,True) if 97<=u<160 else None,position=[row['initial'][0],0,row['initial'][20]*max(0,u-96)],angles=[0,0,row['initial'][68]+128*max(0,u-96)],node_angles=[0,0,2049]) for u in range(duration)],'caster')
    add([export.sample(export.clip_piece(effect,12,u-160,pieces,True) if 161<=u<193 else None,position=[0,0,-300*4096+38400*max(0,u-160)],size=8192,node_angles=[0,0,-1250]) for u in range(duration)])
    for row in groups[6]:
        add([export.sample(export.clip_piece(effect,6,u-192,pieces,True) if 193<=u<burst_stop else None,position=[row['initial'][0],0,0],angles=[0,0,row['initial'][68]]) for u in range(duration)])
    radial_tracks=[]
    for row in groups[8][:10]:
        start=238+row['delay'];track=[]
        for u in range(duration):
            last=start+arrow_life*((min(u,429)-start)//arrow_life) if u>=start else start;age=u-last+1
            track.append(export.sample(export.clip_piece(effect,8,age,pieces,False) if u>=start and age<arrow_life else None,scale=[scales[u]>>12]*3,angles=[0,0,16*(last-237)]))
        radial_tracks.append(len(tracks));tracks.append(track)
    for row in groups[8]:
        group,index=row['indices']
        # A modulus-one variation is a constant angle; it consumes no extra draw.
        bindings.append(dict(anchor='world',origin=origin,track=radial_tracks[index],position=[row['initial'][0],0,0],random_angle=export.variation(0,1,group*1024)))
    for row in groups[3]:
        add([export.sample(export.clip_piece(effect,3,u-192,pieces,True) if 193<=u<end else None,position=[row['initial'][0],0,0],scale=[scales[u]>>12]*3,angles=[0,0,row['initial'][68]+16*min(max(u-237,0),192)],node_angles=[0,16*min(max(u-429,0),64),1],size=min(4096,1+128*min(max(u-193,0),44))) for u in range(duration)])
    transform=len(tracks);tracks.append([export.sample(scale=[v>>12]*3,size=0) for v in scales])
    animation=len(tracks);tracks.append(export.animation_track(effect,13,pieces))
    for i in range(15):bindings.append(dict(anchor='world',origin=origin,track=transform,piece_track=animation,particle_index=i,random_size=export.variation(2*i+1,2048,4096)))
    base=export.reaction_track();restarts=list(range(238,430,36));stop=restarts[-1]+len(base['offsets']);offsets=[];flashes=[];active=[]
    for u in range(restarts[0],stop):
        age=u-max(at for at in restarts if at<=u);on=age<len(base['offsets'])
        offsets.append(base['offsets'][age] if on else [0,0]);flashes.append(base['flash_frames'][age] if on else None);active.append(on)
    reaction=dict(start=238,release=restarts[-1]+base['release']-238,offsets=offsets,flash_frames=flashes,active_samples=active)
    wash=[[max(0,(step*(min(u,64)-min(max(u-429,0),64)))>>12) for step in (2048,4096,4096)] for u in range(duration)]
    focus=[None]*duration;focus[193]=[-163,0,5]
    return dict(group=True,center_after_reaction=False,impact=end,duration=duration,initial_draws=30,tracks=tracks,objects=bindings,
                cameras=export.source_cameras(effect,unresolved=(338,)),focus_samples=focus,meshes=[],wash=wash,wash_blend='subtractive',reaction=reaction,
                emitter=dict(kind='cycling_sprites',start=238,spawn_stop=429,stop=end,count=15,radius=150,roots=export.square_roots(22500),scale_track=transform,delay_modulus=16,delay_stride=2,life_max=particle_life,color=[127]*3))


def explosion_program(effect,pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    if initializer!=0x80101158:return None
    for start,stop,digest in [(0x80101158,0x8010149C,'9fdc89f401cc970a8031648da8ed32c35c7e2e8d80bc7132dd62f7f8542cdfec'),
                              (0x8010149C,0x80101D70,'eb22df0d42b7831d407f37ebf24ec43412fc1588a81579429dbbcdc14d143b3e'),
                              (0x8012496C,0x80124C4C,'4cace412a47800643ea5aa6e2a3ce30589abec04e1fc3b7f79750b3033bd6850'),
                              (0x80124530,0x8012496C,'6f3ff9862131fdaf313daa6b7ad36438cc085bac36bff94b90f7b19b54c6b73e'),
                              (0x801250B8,0x801251D4,'5fd3b4d2f07aec3742efbe852d11374009b6e7d5e6eee1afb2c19b5c430dfa4b')]:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('Explosion source changed; requalify its equations')
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    groups={n:[r for r in decoded['objects'] if r['animation']==n] for n in (0,7,13)}
    if decoded['blocked'] or [len(groups[n]) for n in groups]!=[1,20,15]:raise ValueError('unresolved Explosion object groups')
    phases=source.timeline(facts,analysis)
    if [p['updates'] for p in phases]!=[64,32,128,96,64,64]:raise ValueError('unresolved Explosion phases')
    import export_spell_scenes as export
    duration=449;origin=[export.signed_word(0x8016B814),export.signed_word(0x8016B818),0];tints=export.source_tints(effect,duration)
    caster=[export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-70*4096],tint=tints[u]) for u in range(duration)]
    # Source retains unspecified heap bits below Q12; normalize that residue to zero.
    scales=[min(0x1000000,4096+174762*min(max(u-96,0),128))//4096+32*min(max(u-320,0),64) for u in range(duration)]
    model=[export.sample(scale=[v]*3,noise_scale=True,size=0) for v in scales]
    tracks=[caster,model,export.animation_track(effect,13,pieces),export.animation_track(effect,7,pieces)];bindings=[dict(anchor='caster',track=0)]
    for i in range(15):bindings.append(dict(anchor='world',origin=origin,track=1,piece_track=2,particle_index=i,random_size=export.variation(40+2*i+1,2048,4096)))
    for i in range(20):bindings.append(dict(anchor='world',origin=origin,track=1,piece_track=3,particle_index=15+i,random_size=export.variation(2*i+1,4096,4096)))
    meshes=[]
    # Six latitudes become ordinary columns; a half turn preserves the source negative radii.
    previous_radius=0;previous_height=-150
    for index in range(6):
        angle=1024*(index+1)//6
        radius=-export.battle_drops.trunc(150*export.effect_sine(angle),4096)
        height=-export.battle_drops.trunc(150*export.effect_sine(angle+1024),4096)
        meshes.append(dict(kind='column',anchor='world',origin=origin,track=1,start=1,stop=384,radius=abs(previous_radius),top_radius=abs(radius),segments=36,angles=[0,0,2048],blend='subtractive',outer=[2*index,16*index,16*index],inner=[2*(index+1)-1,16*(index+1)-1,16*(index+1)-1],base_heights=[previous_height]*duration,heights=[height]*duration))
        previous_radius,previous_height=radius,height
    meshes.append(dict(kind='fan',anchor='world',origin=origin,track=1,start=1,stop=384,radius=150,segments=36,inner=[0]*3,outer=[255]*3,depth=379,blend='subtractive'))
    base=export.reaction_track();restarts=[257,293];offsets=[];flashes=[];active=[]
    for u in range(257,restarts[-1]+len(base['offsets'])):
        age=u-max(at for at in restarts if at<=u);enabled=age<len(base['offsets'])
        offsets.append(base['offsets'][age] if enabled else [0,0]);flashes.append(base['flash_frames'][age] if enabled else None);active.append(enabled)
    return dict(group=True,center_after_reaction=False,impact=448,duration=duration,initial_draws=70,
                scale_noise=dict(start=225,stop=321,modulus=80,bias=-40),tracks=tracks,objects=bindings,meshes=meshes,cameras=export.source_cameras(effect,unresolved=(129,)),
                wash=[[0]*3]*duration,wash_blend='additive',reaction=dict(start=257,release=restarts[-1]+base['release']-257,offsets=offsets,flash_frames=flashes,active_samples=active),
                emitters=[dict(kind='cycling_sprites',start=225,spawn_stop=320,stop=448,count=15,particle_start=0,radius=80,roots=export.square_roots(6400),scale_track=1,delay_modulus=96,delay_stride=2,initial_delay_draw=40,life_max=len(tracks[2]),repeat_size_range=4096,repeat_size_min=4096,color=[127]*3),
                          dict(kind='cycling_sprites',start=225,spawn_stop=320,stop=448,count=20,particle_start=15,radius=80,roots=export.square_roots(6400),scale_track=1,delay_modulus=72,delay_stride=2,height_range=60,life_max=len(tracks[3]),focus_kick=5,focus_on_first=True,color=[127]*3),
                          dict(kind='inward_lines',start=97,spawn_stop=223,stop=448,count=30,particle_start=35,radius=150,roots=export.square_roots(22500),model_track=1,anchor='world',origin=origin,color=[127,127,0])])
