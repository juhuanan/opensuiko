"""Shared Soul Eater geometry, source contracts and Deadly Fingertips playback.

Black Shadow and Hell use user-approved deterministic point startup.
"""
import hashlib
import json
from pathlib import Path

import battle_drops
import spell_scene_source as source
import spell_scene_columns as columns

SPANS=(
    (0x80113A90,0x801148D4,'e98dcf80cb2115e45c27eb5b6c43282c9177754af2ac2dd5c17e0fcbd46bc272'),
    (0x801148D4,0x8011567C,'0a2495b78902f8aea294486411e132c8a9ced5bc1660e1be1af3edca52076c81'),
    (0x8011567C,0x80116638,'1ccfe76b4c116e6efd198aa4f20cf860970a70a07b82b3489f6f0aee286c45df'),
    (0x8012496C,0x80124C58,'8b2fb4bbdabb885fe968e2c0161eb26cc76ba2004ff98d8ce635e447840f056f'),
    (0x80124C58,0x801250B8,'c48c4294ff26477e40335f5875191467ac7936cb0c79fc27ff469c113e1a96fe'),
    (0x801136F4,0x80113A68,'1e235fb36fa6f48b5f24c5841cc54571c35c5ddb2ffb5b42d41bb604299df0f5'),
    (0x80123A5C,0x80124530,'465646b6dcb5584737a3384a9101e99337a79ae30c1dea2044d86c7ec20951c2'),
    (0x80121448,0x80121C20,'819234286414d4812f05930549b712d56b667de66f316dd9007a2f585307ef0f'),
    (0x8016F1CC,0x8016F230,'8b264597e35cf43fd15da7ba132d31b68fdaefca540d405178f60c3947cafc86'),
    (0x80124530,0x8012496C,'6f3ff9862131fdaf313daa6b7ad36438cc085bac36bff94b90f7b19b54c6b73e'),
    (0x8014EC74,0x8014EE64,'11bfe01f8df3e958fae79fbd2e7da92c6bdac44cb07957d269d47247bf34e082'),
)


def deadly_states():
    """Callback state after phase work and the common draw tail."""
    root=1;pulse_on=False;pulse_size=4096;pulse_life=60;pulse_color=127*4096
    echoes=[4096]*3;echo_on=[False]*3;angle=0;result=[]
    for u in range(368):
        if 97<=u<=176 or 247<=u<=306:root+=64
        if 237<=u<=246:root-=32
        if u in (186,211,236):
            i=(186,211,236).index(u);echoes[i]=root;echo_on[i]=True
        if u==246:pulse_on=False
        common=0<u<366
        tint=0
        if common:
            if 97<=u<236:angle+=32
            if u>=97 and not pulse_on:
                pulse_on=True;pulse_size=root;pulse_life=60;pulse_color=127*4096
            if pulse_on:
                tint=(pulse_color>>12)&255;pulse_life-=1;pulse_color-=8669;pulse_size+=128
                if pulse_life<0:pulse_on=False
            for i in range(3):
                if echoes[i]<32:echo_on[i]=False
                else:echoes[i]-=128
        result.append(dict(update=u,scale=root,caster_visible=0<u<96,
                           main_visible=97<=u<306,sub_visible=97<=u<236,
                           sub_height=-300+5*min(max(u-176,0),60),sub_angle=angle,
                           pulse_visible=common and pulse_on,pulse_size=pulse_size,pulse_tint=tint,
                           echo_visible=[common and value for value in echo_on],echo_scales=echoes.copy()))
    return result


def deadly_program(effect,pieces):
    if int(effect['initializer'],16)!=0x80113A90:return None
    catalogue()
    import export_spell_scenes as export
    import spell_scene_warp as warp
    rows=deadly_states();duration=367
    caster=[export.sample(export.clip_piece(effect,0,u-1,pieces,True) if row['caster_visible'] else None,
                          position=[0,0,-80*4096+6400*min(max(u-64,0),32)],
                          node_angles=[1024-16*min(u,64),0,1],size=4096-128*min(max(u-64,0),32),
                          tint=[127-2*min(max(u-64,0),32)]*3) for u,row in enumerate(rows)]
    tracks=[caster,[export.sample(scale=[r['scale']]*3) for r in rows],
            [export.sample(scale=[r['scale'],r['scale'],4096]) for r in rows],
            [export.sample(scale=[r['scale']]*3,angles=[0,0,r['sub_angle']],visible=r['sub_visible']) for r in rows],
            [export.sample(scale=[r['pulse_size']]*3,visible=r['pulse_visible']) for r in rows]]
    mesh=[dict(kind='column',anchor='target',track=3,start=97,stop=236,radius=100,top_radius=100,segments=10,
               animated_angles=True,segment_gap=200,inner=[80,80,16],outer=[0]*3,blend='subtractive',
               heights=[0]*368,base_heights=[r['sub_height'] for r in rows]),
          dict(kind='column',anchor='target',track=4,start=97,stop=366,radius=100,segments=48,inner=[127]*3,outer=[0]*3,
               shape_samples=[dict(radius=100,top_radius=100,base_height=-5,height=0,inner=[r['pulse_tint']]*3,outer=[0]*3) for r in rows]),
          dict(kind='fan',anchor='target',track=1,start=97,stop=306,radius=100,segments=48,angles=[0,0,1024],inner=[0]*3,outer=[255]*3,blend='subtractive',depth=380)]
    for i in range(3):
        track=len(tracks);tracks.append([export.sample(scale=[r['echo_scales'][i]]*3,visible=r['echo_visible'][i]) for r in rows])
        mesh.append(dict(kind='fan',anchor='target',track=track,start=186,stop=306,radius=100,segments=48,
                         angles=[0,0,1024],inner=[16]*3,outer=[32]*3,depth=379))
    geometries=[]
    for row in rows:
        if not row['main_visible']:geometries.append(None);continue
        g=warp.ring_vertices(48,[100,130,160],row['scale'],[0,0,0])
        geometries.append(dict(source=[g['center']]+[v for ring in g['uv'] for v in ring],
                               destination=[g['center']]+[v for ring in g['destination'] for v in ring]))
    faces=[dict(indices=[0,1+i,1+(i+1)%48,0] if layer==0 else [1+(layer-1)*48+i,1+(layer-1)*48+(i+1)%48,1+layer*48+i,1+layer*48+(i+1)%48],count=3 if layer==0 else 4) for layer in range(3) for i in range(48)]
    return dict(center_after_reaction=False,impact=306,duration=duration,initial_draws=0,tracks=tracks,
                objects=[dict(anchor='caster',track=0)],meshes=mesh,cameras=export.source_cameras(effect,unresolved=(306,)),
                wash=[[0]*3 for _ in rows],wash_blend='additive',reaction=dict(export.reaction_track(0x8016F1CC),start=246),
                background_warps=[dict(samples=geometries,faces=faces,depth=380,anchor='target')],
                emitter=dict(kind='rising_lines',anchor='target',start=97,spawn_stop=305,stop=366,count=30,
                             radius=100,roots=export.square_roots(10000),scale_track=2,min_z=-300,
                             trail_min=10,trail_range=50,velocity_z=-20480,speed_range=5,life_max=70,color=[64,96,144]))


def shadow_states(incoming_root_fraction):
    """Explicit allocation residue; fractional growth makes it observable."""
    if type(incoming_root_fraction) is not int or not 0<=incoming_root_fraction<4096:
        raise ValueError('Black Shadow needs explicit incoming root fraction')
    root=4096+incoming_root_fraction;result=[]
    for u in range(312):
        if 97<=u<=176 or 187<=u<=250:root+=104857
        if 177<=u<=186:root-=104857
        result.append(dict(update=u,root_q12=root,scale=root>>12,
                           main_visible=97<=u<250,sub_visible=97<=u<128,
                           sub_angle=96*min(max(u-96,0),31),caster_visible=0<u<96))
    return result


def shadow_program(effect,pieces,*,incoming_root_fraction,point_initial_scales):
    """Complete choreography with explicitly supplied startup values.

    Particle lifetimes and positions start at zero, a diagnostic precondition;
    the original constructor does not establish those incoming heap fields.
    """
    if int(effect['initializer'],16)!=0x801148D4:return None
    if not isinstance(point_initial_scales,(list,tuple)) or len(point_initial_scales)!=40 or any(type(v) is not int or not -65536<=v<=65536 for v in point_initial_scales):
        raise ValueError('Black Shadow needs forty explicit incoming point scales')
    catalogue()
    import export_spell_scenes as export
    import spell_scene_warp as warp
    from spell_scene_support import screen_flashes
    warp.voice_profile()
    rows=shadow_states(incoming_root_fraction);duration=311;origin=[-128,0,0]
    caster=[export.sample(export.clip_piece(effect,0,u-1,pieces,True) if r['caster_visible'] else None,
                          position=[0,0,-80*4096+6400*min(max(u-64,0),32)],
                          node_angles=[1024-16*min(u,64),0,1],size=4096-128*min(max(u-64,0),32),
                          tint=[127-2*min(max(u-64,0),32)]*3) for u,r in enumerate(rows)]
    tracks=[caster,[export.sample(scale=[r['scale']]*3,visible=r['main_visible']) for r in rows],
            [export.sample(visible=r['sub_visible'],angles=[0,0,r['sub_angle']]) for r in rows]]
    meshes=[]
    bands=hemisphere(200,6)
    for i,band in enumerate(bands):
        meshes.append(dict(kind='column',anchor='world',origin=origin,track=1,start=97,stop=250,
                           radius=1,segments=36,angles=[0,0,2048],inner=[0]*3,outer=[0]*3,blend='subtractive',
                           shape_samples=[dict(radius=-band['lower'][0],top_radius=-band['upper'][0],
                                               base_height=band['lower'][1],height=band['upper'][1],
                                               inner=[128//6*(i+1)-1]*3,outer=[128//6*i]*3) for _ in rows]))
    meshes.extend([dict(kind='column',anchor='world',origin=origin,track=2,start=97,stop=128,radius=800,
                        segments=10,segment_gap=330,animated_angles=True,inner=[80]*3,outer=[32]*3,
                        shape_samples=[dict(radius=800,top_radius=0,base_height=0,height=0,inner=[80]*3,outer=[32]*3) for _ in rows],blend='subtractive',depth=1),
                   dict(kind='fan',anchor='world',origin=origin,track=1,start=97,stop=250,radius=205,segments=36,
                        angles=[0,0,1024],inner=[0]*3,outer=[127]*3,depth=380,blend='subtractive')])
    geometries=[]
    for row in rows:
        if not row['main_visible']:geometries.append(None);continue
        g=warp.ring_vertices(36,[200,230,260],row['scale'],origin)
        geometries.append(dict(source=[g['center']]+[v for ring in g['uv'] for v in ring],
                               destination=[g['center']]+[v for ring in g['destination'] for v in ring]))
    faces=[dict(indices=[0,1+i,1+(i+1)%36,0] if layer==0 else [1+(layer-1)*36+i,1+(layer-1)*36+(i+1)%36,1+layer*36+i,1+layer*36+(i+1)%36],count=3 if layer==0 else 4) for layer in range(3) for i in range(36)]
    base=export.reaction_track(0x8016F1CC)
    reaction=dict(start=187,release=32+base['release'],offsets=base['offsets']*2,flash_frames=base['flash_frames']*2)
    return dict(group=True,center_after_reaction=False,impact=310,duration=duration,initial_draws=0,
                tracks=tracks,objects=[dict(anchor='caster',track=0)],meshes=meshes,
                cameras=export.source_cameras(effect,unresolved=(250,)),wash=[[0]*3 for _ in rows],wash_blend='additive',
                screen_washes=screen_flashes(effect),reaction=reaction,
                background_warps=[dict(samples=geometries,faces=faces,depth=380)],
                emitter=dict(kind='inward_points',anchor='world',origin=origin,start=97,spawn_stop=176,stop=310,
                             count=40,radius=200,roots=export.square_roots(40000),scale_track=1,
                             point_initial_scales=list(point_initial_scales),color=[255]*3))


def _effect_mapping(name):
    import item_tables
    import spell_effect_sweep
    effects={e['name']:e for e in spell_effect_sweep.build()['effects']}
    offset=0
    for label in item_tables.spell_names():
        if label==name:break
        offset+=len(effects[label]['pieces'])
    effect=effects[name]
    return effect,list(range(offset,offset+len(effect['pieces'])))


def shadow_fixture(packet):
    """Initialized-state review vectors, deliberately outside the canonical library."""
    from PIL import Image
    from spell_scene_player import Player
    effect,mapping=_effect_mapping('Black Shadow')
    program=shadow_program(effect,mapping,
                           incoming_root_fraction=0,point_initial_scales=[4096]*40)
    review={**packet,
            'spells':[dict(id='spell_26',name='Black Shadow initialized-state diagnostic',program=program,blocker=None)]}
    cases=[];player=Player(review,'spell_26',Image.new('RGBA',(4096,4096)),seed=17)
    for update in (0,1,64,65,95,96,97,127,128,160,176,177,186,187,218,219,249,250,309,310,311):
        frame=player.frame(update,[120,50,0],[-128,0,0])
        cases.append(dict(update=update,draw_count=player.draw_count,commands=frame['commands']))
    return dict(status='diagnostic_not_qualified',startup=dict(root_fraction=0,point_scales=[4096]*40,
                particle_lifetimes=0,particle_positions=[0]*3),packet=review,cases=cases)


def hell_fixture(packet):
    """Full initialized-state geometry, kept separate from canonical gameplay."""
    from PIL import Image
    from spell_scene_player import Player
    effect,mapping=_effect_mapping('Hell')
    program=hell_program(effect,mapping,incoming_root_fraction=0,incoming_velocity_fraction=0,point_initial_scales=[4096]*40)
    review={**packet,
            'spells':[dict(id='spell_27',name='Hell initialized-state diagnostic',program=program,blocker=None)]}
    player=Player(review,'spell_27',Image.new('RGBA',(4096,4096)),seed=17);cases=[]
    for update in (0,1,64,65,95,96,97,141,142,145,146,187,188,223,224,225,228,237,251,270,
                   277,278,292,314,315,316,317,318,376,377,435,436,495,496,497):
        frame=player.frame(update,[120,50,0],[-128,0,0])
        cases.append(dict(update=update,draw_count=player.draw_count,commands=frame['commands']))
    return dict(status='diagnostic_not_qualified',startup=dict(root_fraction=0,velocity_fraction=0,
                point_scales=[4096]*40,particle_lifetimes=0,particle_positions=[0]*3),packet=review,cases=cases)


def hell_states(incoming_root_fraction,incoming_velocity_fraction):
    if any(type(v) is not int or not 0<=v<4096 for v in (incoming_root_fraction,incoming_velocity_fraction)):
        raise ValueError('Hell needs explicit root and velocity fractions')
    root=4096+incoming_root_fraction;velocity=131072+incoming_velocity_fraction
    radii=[180,210,240];twist=0;result=[]
    for u in range(498):
        if 97<=u<=224:
            root+=velocity
            if root>>12>4096:root=(root&4095)|(4096<<12)
        if 225<=u<=316:radii=[max(n-2,limit) for n,limit in zip(radii,(60,120,180))]
        if u==317:radii=[60,120,180]
        if 317<=u<=436:
            twist+=8
            if (436-u)%2==0 and radii[1]>0:
                radii[1]-=1;radii[0]=radii[1]//2
        result.append(dict(update=u,scale=root>>12,root_q12=root,caster_visible=0<u<96,
                           warp_visible=97<=u<436,warp_radii=radii.copy(),warp_twist=twist,
                           warp_depth=379 if u<317 else 6,fan_depth=378 if u<225 else 5,
                           sub_visible=97<=u<146,sub_angle=96*min(max(u-96,0),49)))
    return result


def hell_program(effect,pieces,*,incoming_root_fraction,incoming_velocity_fraction,point_initial_scales):
    """Complete initialized-state scene; caller supplies the approved startup policy."""
    if int(effect['initializer'],16)!=0x8011567C:return None
    if not isinstance(point_initial_scales,(list,tuple)) or len(point_initial_scales)!=40 or any(type(v) is not int or not -65536<=v<=65536 for v in point_initial_scales):
        raise ValueError('Hell needs forty explicit incoming point scales')
    catalogue()
    import export_spell_scenes as export
    import spell_scene_warp as warp
    warp.voice_profile()
    rows=hell_states(incoming_root_fraction,incoming_velocity_fraction);origin=[-178,0,0]
    collapse=collapse_shapes();bands=hemisphere(180,6)
    caster=[export.sample(export.clip_piece(effect,0,u-1,pieces,True) if r['caster_visible'] else None,
                          position=[0,0,-80*4096+6400*min(max(u-64,0),32)],
                          node_angles=[1024-16*min(u,64),0,1],size=4096-128*min(max(u-64,0),32),
                          tint=[127-2*min(max(u-64,0),32)]*3) for u,r in enumerate(rows)]
    tracks=[caster,[export.sample(scale=[r['scale']]*3) for r in rows],
            [export.sample(visible=r['sub_visible'],angles=[0,0,r['sub_angle']]) for r in rows]]
    meshes=[]
    for i,band in enumerate(bands):
        samples=[];shapes=[]
        for u,row in enumerate(rows):
            c=collapse[min(max(u-224,0),91)]
            samples.append(export.sample(scale=[row['scale']]*3,visible=0<u<315 and (u<=224 or c['enabled'] and i>=c['first_band'])))
            shapes.append(c['shapes'][i] if u>=225 else dict(radius=-band['lower'][0],top_radius=-band['upper'][0],
                          base_height=band['lower'][1],height=band['upper'][1],inner=[24*(i+1)-1]*3,outer=[24*i]*3))
        track=len(tracks);tracks.append(samples)
        meshes.append(dict(kind='column',anchor='world',origin=origin,track=track,start=1,stop=316,
                           radius=1,segments=36,angles=[0,0,2048],inner=[0]*3,outer=[0]*3,
                           blend='subtractive',shape_samples=shapes))
    pulse_samples=[dict(visible=False,scale=[4096]*3) for _ in rows]
    pulse_shapes=[dict(radius=5,top_radius=0,base_height=-180,height=-180,inner=[127]*3,outer=[0]*3) for _ in rows]
    for start in (97,188):
        pulse=hell_pulse_samples([rows[start+i]['scale'] for i in range(91)])
        for age,s in enumerate(pulse):
            pulse_samples[start+age]=export.sample(visible=s['visible'],scale=[s['scale']]*3)
            pulse_shapes[start+age]=s['shape']
    pulse_track=len(tracks);tracks.append(pulse_samples)
    meshes.extend([dict(kind='column',anchor='world',origin=origin,track=2,start=97,stop=146,radius=800,
                        segments=10,segment_gap=330,animated_angles=True,inner=[80]*3,outer=[32]*3,blend='subtractive',depth=1,
                        shape_samples=[dict(radius=800,top_radius=0,base_height=0,height=0,inner=[80]*3,outer=[32]*3) for _ in rows]),
                   dict(kind='column',anchor='world',origin=origin,track=pulse_track,start=97,stop=316,radius=1,segments=36,
                        inner=[127]*3,outer=[0]*3,shape_samples=pulse_shapes)])
    for start,stop,depth in ((97,225,378),(225,436,5)):
        meshes.append(dict(kind='fan',anchor='world',origin=origin,track=1,start=start,stop=stop,radius=180,segments=36,
                           angles=[0,0,1024],inner=[0]*3,outer=[160]*3,depth=depth,blend='subtractive'))
    geometries=[]
    for row in rows:
        if not row['warp_visible']:geometries.append(None);continue
        g=warp.ring_vertices(36,row['warp_radii'],row['scale'],origin,twist=row['warp_twist'])
        geometries.append(dict(source=[g['center']]+[v for ring in g['uv'] for v in ring],
                               destination=[g['center']]+[v for ring in g['destination'] for v in ring]))
    faces=[dict(indices=[0,1+i,1+(i+1)%36,0] if layer==0 else [1+(layer-1)*36+i,1+(layer-1)*36+(i+1)%36,1+layer*36+i,1+layer*36+(i+1)%36],count=3 if layer==0 else 4) for layer in range(3) for i in range(36)]
    warps=[dict(samples=[g if start<=u<stop else None for u,g in enumerate(geometries)],faces=faces,depth=depth)
           for start,stop,depth in ((97,317,379),(317,436,6))]
    flash=[None if u<377 else [((min(u-376,60)-min(max(u-436,0),60))*17408)>>12]*3 for u in range(498)]
    flash[497]=None
    return dict(group=True,center_after_reaction=False,impact=436,duration=497,initial_draws=0,
                tracks=tracks,objects=[dict(anchor='caster',track=0)],meshes=meshes,cameras=export.source_cameras(effect),
                wash=[[0]*3 for _ in rows],wash_blend='additive',screen_washes=[dict(depth=0,blend='additive',colors=flash)],
                background_warps=warps,
                emitter=dict(kind='inward_points',anchor='world',origin=origin,start=97,spawn_stop=224,stop=496,
                             count=40,radius=180,roots=export.square_roots(32400),scale_track=1,
                             point_initial_scales=list(point_initial_scales),color=[255]*3))


def hemisphere(radius,count):
    """Quarter-wave endpoints used by constructor2496C and setter24C58."""
    if not isinstance(radius,int) or not 1<=radius<=1024 or not isinstance(count,int) or not 1<=count<=16:
        raise ValueError('invalid hemisphere dimensions')
    from export_spell_scenes import effect_sine
    result=[];r=0;z=-radius
    for i in range(count):
        angle=(i+1)*1024//count
        next_r=-battle_drops.trunc(radius*effect_sine(angle),4096)
        next_z=-battle_drops.trunc(radius*effect_sine(angle+1024),4096)
        result.append(dict(lower=[r,z],upper=[next_r,next_z]))
        r,z=next_r,next_z
    return result


def sqrt_q12(value):
    """Shared normalized integer square root; input and output have12 fractional bits."""
    if type(value) is not int or not 0<=value<=0x7fffffff:
        raise ValueError('invalid fixed square root')
    if value==0:return 0
    shift=8-(32-value.bit_length())
    exponent=shift//2+(shift<0)
    normalized=value>>(2*exponent) if exponent>=0 else value<<(-2*exponent)
    x=normalized+0x5d50ad;y=normalized-0x5d50ad
    for step in (1,2,3,4,4,5,6):
        if y>=0:x,y=x-(y>>step),y-(x>>step)
        else:x,y=x+(y>>step),y+(x>>step)
    exponent-=6
    return x<<exponent if exponent>=0 else x>>(-exponent)


def hell_pulse_samples(root_scales):
    """One pulse after same-callback mutation; root scale inputs remain explicit."""
    if not isinstance(root_scales,(list,tuple)) or len(root_scales)!=91 or any(type(v) is not int or not 0<=v<=65536 for v in root_scales):
        raise ValueError('Hell pulse needs91 explicit root scales')
    height=-180;radius=0;scale=4096;result=[]
    for age,root in enumerate(root_scales):
        if height<0:
            height+=4;radius=battle_drops.trunc(sqrt_q12((180*180-height*height)<<12),4096)
            scale=root
        else:scale+=128
        tint=((127*4096-5779*age)>>12)&255
        result.append(dict(visible=age<90,scale=scale,
                           shape=dict(radius=radius+11,top_radius=radius+1,base_height=height,height=height,
                                      inner=[tint]*3,outer=[0]*3)))
    return result


def pulse_geometry_fixture():
    """Explicit changing scale inputs test the pulse's copy-then-expand handoff."""
    from PIL import Image
    from spell_scene_player import Player
    scales=[1+32*i for i in range(91)];pulse=hell_pulse_samples(scales)
    samples=[dict(visible=False,scale=[1]*3)]+[dict(visible=s['visible'],scale=[s['scale']]*3) for s in pulse]+[dict(visible=False)]
    shapes=[pulse[0]['shape']]+[s['shape'] for s in pulse]+[pulse[-1]['shape']]
    mesh=dict(kind='column',anchor='world',origin=[-170,0,0],track=0,start=1,stop=92,radius=1,segments=36,
              inner=[0]*3,outer=[0]*3,shape_samples=shapes)
    program=dict(impact=90,duration=92,initial_draws=0,tracks=[samples],objects=[],meshes=[mesh],
                 cameras=[],wash=[[0]*3 for _ in range(93)],wash_blend='additive')
    packet=dict(schema='suikoden-spell-scenes/28',atlas='spell_effects.png',hurt_poses=[],
                entries=[dict(x=0,y=0,w=1,h=1,dx=0,dy=0)],pieces=[[0]],
                spells=[dict(id='spell_27',name='Hell pulse geometry diagnostic',program=program,blocker=None)])
    player=Player(packet,'spell_27',Image.new('RGBA',(1,1)));cases=[]
    for update in range(93):
        frame=player.frame(update,[0]*3,[0]*3)
        cases.append(dict(update=update,commands=[{k:c[k] for k in ('vertices','colors','depth')} for c in frame['commands']]))
    return dict(packet=packet,scale_inputs=scales,cases=cases)


def collapse_updates(bands,speed):
    # The helper discards a band's vertical overshoot instead of carrying it forward.
    if not isinstance(speed,int) or not 1<=speed<=1024 or not bands:
        raise ValueError('invalid hemisphere collapse')
    lengths=[b['upper'][1]-b['lower'][1] for b in bands]
    if any(n<0 for n in lengths):raise ValueError('reversed hemisphere band')
    return sum(max(1,(n+speed-1)//speed) for n in lengths)


def collapse_shapes():
    """Model-space samples after each24F84 update, including same-update handoff."""
    import copy
    radius,count,speed,color=180,6,2,144
    bands=hemisphere(radius,count);updates=collapse_updates(bands,speed)
    current=copy.deepcopy(bands);index=0;remainder=0;step=0;result=[]
    for age in range(updates+1):
        if age:
            band=current[index];band['lower'][1]+=speed
            if band['lower'][1]>=band['upper'][1]:
                index+=1;remainder=0
            active=index<count
            # The helper already advances the new band's radial edge on handoff.
            if active:
                initial=bands[index]
                step=(abs(initial['upper'][0]-initial['lower'][0])<<12)//abs(initial['upper'][1]-initial['lower'][1])
                remainder+=step
                whole=remainder>>12
                if whole>0:current[index]['lower'][0]-=whole*speed;remainder&=4095
        else:active=True
        intensity=max(count,(color*4096-6144*age)>>12)
        shapes=[]
        for i,band in enumerate(current):
            shapes.append(dict(radius=abs(band['lower'][0]),top_radius=abs(band['upper'][0]),
                               base_height=band['lower'][1],height=band['upper'][1],
                               inner=[intensity//count*(i+1)-1]*3,
                               outer=[intensity//count*i]*3))
        result.append(dict(enabled=active,first_band=index,shapes=shapes))
    return result


def geometry_fixture():
    """Diagnostic shared-column packet; this is not a complete Hell scene."""
    from PIL import Image
    from spell_scene_player import Player
    catalogue()
    rows=collapse_shapes();tracks=[];meshes=[]
    for i in range(6):
        samples=[rows[min(max(u-224,0),91)] for u in range(318)]
        tracks.append([dict(visible=225<=u<316 and s['enabled'] and i>=s['first_band']) for u,s in enumerate(samples)])
        meshes.append(dict(kind='column',anchor='world',origin=[-170,0,0],track=i,start=225,stop=316,
                           radius=1,top_radius=1,segments=36,angles=[0,0,2048],inner=[0]*3,outer=[0]*3,
                           shape_samples=[s['shapes'][i] for s in samples]))
    program=dict(impact=316,duration=317,initial_draws=0,tracks=tracks,objects=[],meshes=meshes,
                 cameras=[],wash=[[0]*3 for _ in range(318)],wash_blend='additive')
    packet=dict(schema='suikoden-spell-scenes/28',atlas='spell_effects.png',hurt_poses=[],
                entries=[dict(x=0,y=0,w=1,h=1,dx=0,dy=0)],pieces=[[0]],
                spells=[dict(id='spell_27',name='Collapse geometry diagnostic',program=program,blocker=None)])
    player=Player(packet,'spell_27',Image.new('RGBA',(1,1)));cases=[]
    for update in range(224,318):
        frame=player.frame(update,[0]*3,[0]*3)
        cases.append(dict(update=update,commands=[dict(vertices=c['vertices'],colors=c['colors'],depth=c['depth']) for c in frame['commands']]))
    return dict(packet=packet,cases=cases)


def point_fixture():
    """Explicit incoming slot scales; no claim about a scene's first heap contents."""
    from PIL import Image
    from export_spell_scenes import square_roots
    from spell_scene_player import Player
    catalogue()
    emitter=dict(kind='inward_points',anchor='world',origin=[-170,0,0],start=1,spawn_stop=40,stop=80,
                 count=40,radius=200,roots=square_roots(40000),scale_track=0,
                 point_initial_scales=[-4096,0,1,4096,8192]*8,color=[255]*3)
    program=dict(impact=80,duration=81,initial_draws=0,tracks=[[dict(scale=[1+56*u]*3) for u in range(82)]],
                 objects=[],meshes=[],cameras=[],wash=[[0]*3 for _ in range(82)],wash_blend='additive',emitter=emitter)
    packet=dict(schema='suikoden-spell-scenes/29',atlas='spell_effects.png',entries=[dict(x=0,y=0,w=1,h=1,dx=0,dy=0)],pieces=[[0]],
                spells=[dict(id='spell_26',name='Point input diagnostic',program=program,blocker=None)])
    runs=[]
    for seed in (0,17):
        player=Player(packet,'spell_26',Image.new('RGBA',(1,1)),seed=seed);cases=[]
        for update in range(82):
            frame=player.frame(update,[0]*3,[0]*3)
            cases.append(dict(update=update,draw_count=player.draw_count,
                              particles=[dict(active=p['active'],life=p['life'],head=p['head'].copy(),velocity=p['velocity'].copy(),scale=p['spawn_scale'][0]) for p in player.particles_for(emitter)],
                              commands=[dict(vertices=c['vertices'],colors=c['colors'],depth=c['depth']) for c in frame['commands']]))
        runs.append(dict(seed=seed,cases=cases))
    return dict(packet=packet,runs=runs)


def catalogue(image=None):
    image=image or source.Image()
    for a,b,digest in SPANS:
        if hashlib.sha256(image.data[a-image.base:b-image.base]).hexdigest()!=digest:
            raise ValueError('Soul Eater source changed; requalify lifecycle')
    result=[]
    for native,initializer,expected in ((25,0x80113A90,[64,32,80,60,10,60,60]),
                                        (26,0x801148D4,[64,32,80,10,64,60]),
                                        (27,0x8011567C,[64,32,128,None,120,60])):
        facts,analysis=source.analyze(initializer,image)
        phases=source.timeline(facts,analysis)
        if [p['updates'] for p in phases]!=expected:raise ValueError('unresolved Soul Eater phase layout')
        wait=None
        if native==27:
            bands=hemisphere(180,6);updates=collapse_updates(bands,2)
            wait=dict(start=225,bands=bands,speed=2,helper_updates=updates,completion_observed=225+updates,
                      order='Phase guard reads enabled before the common-tail helper. The final helper update disables the wave; the next callback advances the phase.')
            phases[3]=dict(phases[3],updates=updates+1,blocker=None,
                           completion_site=0x80115E6C,resolution='shared_wave_collapse')
        start=0
        for phase in phases:phase['start']=start;start+=phase['updates']
        cameras=[]
        for c in facts['cameras']:
            phase=next((p for p in reversed(phases) if facts['cases'][p['index']]<=c['site']),None)
            if phase is None:raise ValueError('unbound Soul Eater camera phase')
            age=phase['updates'] if native in (25,26) and c==facts['cameras'][-1] else 1
            cameras.append(dict(at=phase['start']+age,**c))
        decoded=columns.constructors(facts,image)
        if decoded['blocked']:raise ValueError('unresolved Soul Eater column constructor')
        impact=306 if native==25 else 310 if native==26 else start-60
        result.append(dict(id=f'spell_{native}',runtime_ready=True,
                           blockers=[],
                           visual_acceptance='pending' if native==25 else 'user_memory_match_2026-11-12',
                           initializer=initializer,updater=facts['updater'],phases=phases,
                           impact=impact,cleanup=start+1,cameras=cameras,columns=decoded['columns'],
                           object_wait=wait,reactions=[246] if native==25 else [187,219] if native==26 else [],
                           allocation_startup=dict(root_fraction=None,velocity_fraction=None if native==27 else 'not_used',particle_lifetimes=None,particle_positions=None,
                                                   review_only=False,policy='user_approved_deterministic_startup_2026-11-12',
                                                   review_values=dict(root_fraction=0,velocity_fraction=0 if native==27 else 'not_used',particle_scale=4096,particle_lifetimes=0,particle_positions=[0]*3)) if native in (26,27) else None,
                           scene_capture=dict(early=dict(start=97,stop=317,draw_depth=379,minimum_depth=381),
                                              late=dict(start=317,stop=436,draw_depth=6,minimum_depth=8),
                                              software_status='verified',native_status='implemented_window_review_pending') if native==27 else None,
                           pulse=dict(visible_updates=90,geometry_samples=91,scale_copy_updates=45,scale_expand_step=128,
                                      height_start=-180,height_step=4,radius_offsets=[11,1],tint_initial=127*4096,tint_delta=-5779,
                                      square_root=0x8014EDC8,core=0x8014EC74,status='geometry_verified_for_explicit_scale_inputs') if native==27 else None,
                           points=dict(count=40,spawn=[97,176] if native==26 else [97,224],life_modulus=120,
                                       helper=0x801137DC,initial_scales=None,startup_status='first_values_unresolved',
                                       player_status='headless_verified_for_explicit_inputs') if native in (26,27) else None))
    return dict(schema='suikoden-soul-scene-contracts/6',producer='spell-soul-contract/6',
                source=dict(file='MAIN.EXE',lba=17976,size=757760,image_base=image.base,
                            spans=[dict(start=a,stop=b,sha256=h) for a,b,h in SPANS]),spells=result)


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--geometry-out',type=Path)
    parser.add_argument('--points-out',type=Path)
    parser.add_argument('--shadow-out',type=Path)
    parser.add_argument('--pulse-out',type=Path)
    parser.add_argument('--hell-out',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    (root/'kit/data/reports/spell_soul_scenes.json').write_text(json.dumps(catalogue(),indent=2)+'\n')
    if args.geometry_out:args.geometry_out.write_text(json.dumps(geometry_fixture(),separators=(',',':'))+'\n')
    if args.points_out:args.points_out.write_text(json.dumps(point_fixture(),separators=(',',':'))+'\n')
    if args.shadow_out:
        packet=json.loads((root/'game/tests/fixtures/spell_scene_library.json').read_text())
        args.shadow_out.write_text(json.dumps(shadow_fixture(packet),separators=(',',':'))+'\n')
    if args.pulse_out:args.pulse_out.write_text(json.dumps(pulse_geometry_fixture(),separators=(',',':'))+'\n')
    if args.hell_out:
        packet=json.loads((root/'game/tests/fixtures/spell_scene_library.json').read_text())
        args.hell_out.write_text(json.dumps(hell_fixture(packet),separators=(',',':'))+'\n')
