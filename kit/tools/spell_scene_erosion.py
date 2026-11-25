"""Disc texture erosion expressed as semantic coverage layers and a portable sprite."""
import hashlib
import numpy as np
import spell_scene_source as source


def charm_program(effect,pieces,piece_entries,entries,images,raw_page):
    if int(effect['initializer'],16)!=0x801050B4:return None
    import export_spell_scenes as export
    image=source.Image()
    for a,b,digest in SPANS:
        if hashlib.sha256(image.data[a-image.base:b-image.base]).hexdigest()!=digest:raise ValueError('Charm Arrow source changed; requalify erosion and drawing')
    facts,analysis=source.analyze(0x801050B4)
    if [p['updates'] for p in source.timeline(facts,analysis)]!=[64,32,64,64]:raise ValueError('unresolved Charm Arrow phases')
    en=effect['pieces'][4]['entries']
    if en!=[[0,0,8,128,63,63,136,0]]:raise ValueError('unresolved Charm Arrow texture view')
    # The exported piece points to one ordinary decoded64x64 bitmap.
    entry_id=piece_entries[pieces[4]][0];record=entries[entry_id]
    rgba=np.asarray(images[record['bitmap']]).reshape(-1,4).tolist()
    duration=225;tints=export.source_tints(effect,duration)
    caster=[export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-60*4096],tint=tints[u]) for u in range(duration)]
    glyph=[export.sample(pieces[4] if 97<=u<224 else None,size=1+64*min(max(u-96,0),64),node_angles=[0,0,1+64*min(max(u-96,0),64)]) for u in range(duration)]
    return dict(group=True,center_after_reaction=False,impact=224,duration=duration,initial_draws=0,tracks=[caster,glyph],
                objects=[dict(anchor='caster',track=0),dict(anchor='screen',track=1,screen_depth=6,blend='opaque')],cameras=export.source_cameras(effect),meshes=[],
                wash=[[min(u,64)//2 if u<=160 else max(0,(255*4096-16320*(u-160))>>12)]*3 for u in range(duration)],wash_blend='additive',
                reaction=dict(export.fog_reaction(),start=176),
                erosion=dict(entry=entry_id,start=161,stop=225,budget=160,minimum_weight=160,
                             levels=[2 if value>=16 else int(value!=0) for value in raw_page],lower_present=[bool(value&15) for value in raw_page],
                             view_cells=[(64+y)*128+x//2 for y in range(64) for x in range(64)],view_upper=[bool(x%2) for y in range(64) for x in range(64)],colors=rgba))


SPANS=((0x801050B4,0x801052F8,'5d6e82abe355a3f6dbb179e64f48237f56eafae2f8c2bb603887b68381071d49'),
       (0x801052F8,0x80105858,'0d746aa5de8a6c2c337b18e60fbc3654f4149377a1ca2d3953cedf3a2e91aac0'))
