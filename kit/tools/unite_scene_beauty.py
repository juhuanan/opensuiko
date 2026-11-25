"""Beauty's shared heart/wave program, lowered from its verified source contract."""
import battle_unite_camera


def program(piece_ids, wave_rows):
    import export_spell_scenes as export
    row=battle_unite_camera.report()[9]
    contract=row['scene_controller']['contract']
    if len(wave_rows)!=64:raise ValueError('Beauty needs64 screen-wave rows')
    raw,_=battle_unite_camera.field.source('/BATTLE.BIN')
    import battle_bin
    sections,_,errors,_=battle_bin.parse(need_atlases=False)
    if errors:raise ValueError(errors)
    frames,flags,_=battle_unite_camera.animation_frames(raw,section=sections[7]['header_offset'],base=battle_bin.LOAD_BASE)
    if flags[13]!=1 or sum(t for _,t in frames[13])!=47:raise ValueError('Beauty heart animation changed')
    animation=[export.sample(piece_ids[pose]) for pose,ticks in frames[13] for _ in range(ticks)]
    transforms=[];wave=[]
    for update in range(226):
        rise=min(update,64);fade=min(max(update-192,0),32)
        transforms.append(export.sample(position=[-2*rise*4096,0,-40*4096],scale=[64*rise]*3,
            angles=[0,0,16*max(0,min(update,224)-64)],size=1365+64*rise-128*fade))
        if not 1<=update<224:wave.append(None);continue
        phase=update%200;vertices=[]
        for line in range(64):
            top=(export.effect_sine(((4*line+phase)<<12)//200)*50)>>12
            bottom=(export.effect_sine(((4*line+phase+3)<<12)//200)*50)>>12
            vertices.append([[top-100,line*4],[top+420,line*4],[bottom-100,line*4+4],[bottom+420,line*4+4]])
        wave.append(dict(vertices=vertices,tint=0,rgb=[(5120*rise-10240*fade)>>12]+[(3072*rise-6144*fade)>>12]*2))
    camera=contract['camera']
    target=dict(position=[v>>12 for v in camera['focus_q12']],angles=[v>>12 for v in camera['angles_q12']],
        c=[v>>12 for v in camera['translation_q12']],d=[v>>12 for v in camera['scale_q12']])
    result=dict(group=True,impact=224,duration=225,initial_draws=150,tracks=[transforms,animation],
        objects=[dict(anchor='world',track=0,piece_track=1,particle_index=i,start=1) for i in range(30)],
        cameras=[dict(at=2,updates=60,target=target)],meshes=[],wash=[[0,0,0]]*226,wash_blend='additive',
        screen_layers=[dict(entries=wave_rows,samples=wave,copies=2)],
        emitter=dict(kind='seeded_spheres',start=1,loop_stop=64,spawn_stop=192,stop=224,count=30,radius=150,
            roots=export.square_roots(22500),scale_track=0,life_max=47,initial_warmup=32,initial_phase=64,
            oscillation=[30*export.effect_sine(32*i) for i in range(128)],color=[127]*3))
    return result
