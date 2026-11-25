"""Recovered Earth-rune motion expressed with shared scene primitives."""
import hashlib
import spell_scene_source as source
import spell_scene_objects as objects


def earthquake_program(effect,pieces):
    initializer=int(effect['initializer'],16)
    if initializer!=0x801116F8:return None
    image=source.Image()
    for start,stop,digest in [(0x801116F8,0x80111994,'15267d04d9d826baca0955e7a39c93a168735a2e3850cc521f4d517a44aa8ac0'),
                              (0x80111994,0x80111FAC,'99865993b67a77c03685a59f3a580c8cad7c6f4f186383c9a2f40a99b5939ba9')]:
        if hashlib.sha256(image.data[start-image.base:stop-image.base]).hexdigest()!=digest:raise ValueError('Earthquake source changed; requalify its equations')
    facts,analysis=source.analyze(initializer);decoded=objects.constructors(facts,image)
    groups={n:[r for r in decoded['objects'] if r['animation']==n] for n in range(3)}
    if decoded['blocked'] or [len(groups[n]) for n in range(3)]!=[1,20,20]:raise ValueError('unresolved Earthquake object groups')
    if [p['updates'] for p in source.timeline(facts,analysis)]!=[64,64,128,64]:raise ValueError('unresolved Earthquake phases')
    import export_spell_scenes as export
    duration=321;origin=[export.signed_word(0x8016B80C),export.signed_word(0x8016B810),0];tints=export.source_tints(effect,duration)
    caster=[export.sample(pieces[0] if 0<u<97 else None,position=[0,0,-70*4096],size=1+64*min(u,64),node_angles=[0,0,1+64*min(u,64)],tint=tints[u]) for u in range(duration)]
    rock=[export.sample(export.clip_piece(effect,1,0,pieces,True),size=0,node_angles=[0]*3) for _ in range(duration)]
    burst=export.animation_track(effect,2,pieces,size=0)
    bindings=[dict(anchor='caster',track=0)]
    for i in range(20):
        bindings.append(dict(anchor='world',origin=origin,track=1,particle_index=i,blend='opaque',random_size=export.variation(4*i,4096,2048),random_node_angles=[export.variation(4*i+1,341),export.variation(4*i+2,341),export.variation(4*i+3,4096)]))
        bindings.append(dict(anchor='world',origin=origin,track=2,particle_index=i,particle_part='spark',random_size=export.variation(80+i,4096,2048)))
    return dict(group=True,center_after_reaction=False,impact=257,duration=duration,initial_draws=100,
                tracks=[caster,rock,burst],objects=bindings,meshes=[],cameras=export.source_cameras(effect),
                wash=[[min(u,64)-min(max(u-256,0),64)]*3 for u in range(duration)],wash_blend='subtractive',reaction=dict(export.fog_reaction(),start=159),
                emitter=dict(kind='bouncing_sprites',start=129,stop=320,count=20,radius=100,roots=export.square_roots(10000),spawn_at=[129+r['delay'] for r in groups[1]],min_z=-400,velocity_x=groups[1][0]['initial'][12],gravity=4096,bounce_divisor=2,min_x=-500,spin_modulus=256,focus_stride=2,focus_kick=5,spark_track=2,color=[127]*3))
