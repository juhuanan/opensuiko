"""Judgment's independent source sprite pools, transform tracks and columns."""
import hashlib
import spell_scene_source as source
import spell_scene_objects as objects
import spell_scene_columns as columns


def program(effect,pieces,auxiliary,auxiliary_pieces):
    image=source.Image();initializer=int(effect['initializer'],16)
    facts,analysis=source.analyze(initializer)
    if initializer!=0x80116660:return None
    for start,stop,digest in [(0x80116660,0x80116B7C,'aef516f43435a512a4324152ac6a5b78d784b0b31e12bddfe37bd940eb45dc25'),
                              (0x80116B7C,0x80117870,'4c767eab0b5c58944d6239c5d447928af1fd2ce8d7a72364fe3ba12675f3b779')]:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('Judgment source changed; requalify its equations')
    decoded=objects.constructors(facts,image);nested=[r for r in decoded['objects'] if r.get('loops')]
    if decoded['blocked'] or len(decoded['objects'])!=64 or len(nested)!=40:raise ValueError('unresolved Judgment constructors')
    phases=source.timeline(facts,analysis)
    if [p['updates'] for p in phases]!=[64,32,64,64,64,96,60,60]:raise ValueError('unresolved Judgment phases')
    banks={r['section'] for r in effect['graphics_bindings'] if r['site']==0x80116890}
    if banks!={auxiliary['section']} or auxiliary['section']!=6:raise ValueError('unbound Judgment auxiliary bolt art')
    import export_spell_scenes as export
    end=504;duration=505;tracks=[];bindings=[]
    scales=[1+64*(min(max(u-96,0),64)+min(max(u-384,0),60)) for u in range(duration)]
    def static(animation):return export.clip_piece(effect,animation,0,pieces,True)
    def add(track,anchor='target',**fields):
        bindings.append(dict(anchor=anchor,track=len(tracks),**fields));tracks.append(track)
    add([export.sample(static(0) if 0<u<96 else None,position=[0,0,-80*4096+6400*min(max(u-64,0),32)],node_angles=[1024-16*min(u,64),0,1],size=4096-128*min(max(u-64,0),32),tint=[127-2*min(max(u-64,0),32)]*3) if 0<u<96 else export.sample() for u in range(duration)],'caster')
    for i,animation in enumerate((9,11,12,10)):
        track=[]
        for u in range(duration):
            if not 161<=u<444:track.append(export.sample());continue
            z=(-160*4096+6400*min(max(u-160,0),64)) if u<225 else -60*4096+50*export.effect_sine(32*(u-224))
            color=(8128*min(max(u-160,0),64)>>12)&255
            track.append(export.sample(static(animation) if 161<=u<444 else None,position=[120*4096,0,z],scale=[scales[u]]*2+[4096],angles=[0,0,1024*i+16*min(max(u-160,0),64)],tint=[color]*3))
        add(track)
    bolt=export.clip_piece(auxiliary,9,0,auxiliary_pieces,True)
    trail_track=len(tracks);tracks.append([export.sample(bolt,size=8192,node_angles=[0,512,1]) for _ in range(16)])
    for row in nested:bindings.append(dict(anchor='target',track=trail_track,particle_index=row['indices'][0],trail_index=row['indices'][1]))
    for i in range(4):
        add([export.sample(static(1) if 225<=u<444 else None,position=[110*4096,0,-80*4096+50*export.effect_sine(32*max(0,u-224))],scale=[scales[u]]*2+[4096],angles=[0,0,1024*(i+1)],size=min(4096,1+256*max(0,u-224))) if 225<=u<444 else export.sample() for u in range(duration)])
    flare=len(tracks);tracks.append(export.animation_track(effect,2,pieces,size=0))
    for i in range(4):bindings.append(dict(anchor='target',track=flare,particle_index=i,particle_part='spark',random_size=export.variation(2*i+1,4096,2048)))
    transform=len(tracks);tracks.append([export.sample(size=0) for _ in range(duration)])
    for i in range(4,15):bindings.append(dict(anchor='target',track=transform,piece_track=flare,particle_index=i,random_size=export.variation(2*i+1,4096,2048)))
    column_plan=columns.constructors(facts,image)
    if column_plan['blocked'] or len(column_plan['columns'])!=2:raise ValueError('unresolved Judgment columns')
    mesh_track=len(tracks);tracks.append([export.sample(scale=[scales[u]]*3,angles=[0,0,-16*(min(max(u-96,0),128)+min(max(u-384,0),60))]) for u in range(duration)])
    meshes=[]
    for column in column_plan['columns']:
        meshes.append(dict(kind='column',anchor='target',track=mesh_track,start=97,stop=444,radius=column['lower']['radius'],segments=column['segments'],angles=column['angles'],animated_angles=True,blend=column['blend'],inner=column['upper']['color'],outer=column['lower']['color'],heights=[0]*duration,base_heights=[-5-4*min(max(u-160,0),64) for u in range(duration)]))
    fan_track=len(tracks);tracks.append([export.sample(scale=[v]*3) for v in scales])
    meshes.append(dict(kind='fan',anchor='target',track=fan_track,start=1,stop=444,radius=100,segments=32,inner=[0]*3,outer=[144]*3,depth=380))
    base=export.fog_reaction();restarts=list(range(303,394,15));stop=restarts[-1]+len(base['offsets']);offsets=[];flashes=[]
    for u in range(restarts[0],stop):
        age=u-max(at for at in restarts if at<=u);offsets.append(base['offsets'][age]);flashes.append(base['flash_frames'][age])
    reaction=dict(start=303,release=restarts[-1]+base['release']-303,offsets=offsets,flash_frames=flashes)
    return dict(impact=end,duration=duration,initial_draws=30,center_after_reaction=False,tracks=tracks,objects=bindings,cameras=export.source_cameras(effect,unresolved=(444,)),meshes=meshes,
                wash=[[4369*min(max(u-96,0),64)>>12]*3 if u<end else [0]*3 for u in range(duration)],wash_blend='subtractive',reaction=reaction,
                emitters=[dict(kind='falling_trails',start=289,spawn_stop=384,stop=end,particle_start=0,count=4,radius=50,roots=export.square_roots(2500),spawn_at=[289+6*i for i in range(4)],min_z=-300,velocity_z=20*4096,trail_count=10,spark_track=flare,focus_kick=5,color=[127]*3),
                          dict(kind='cycling_sprites',start=289,spawn_stop=384,stop=end,particle_start=4,count=11,radius=70,roots=export.square_roots(4900),height_range=100,focus_kick=5,scale_track=transform,delay_modulus=48,delay_stride=2,initial_delay_draw=8,life_max=len(tracks[flare]),color=[127]*3)])
