#!/usr/bin/env python3
"""Disc -> portable spell scene library + review atlas. No original code execution.

All 33 spells are inventoried and their decoded descriptor art is exported.
Custom texture and choreography gaps remain explicit; a program is supplied
only after its complete scene contract has been qualified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

import numpy as np
from PIL import Image
import battle_bin
import battle_drops
import item_tables
import export_battle_trial as actor_art
import area_encounter_tables as encounters
from journey_battle import ENEMY_IDS
import maindec
import spell_effect_sweep
from spell_effect_entries import entry_image
from actor_script import OP_LEN_HW
import spell_scene_source
import spell_scene_objects
import spell_scene_support
import spell_scene_lightning
import spell_scene_columns
import spell_scene_sound
import spell_scene_wind
import spell_scene_earth
import spell_scene_erosion
import spell_scene_fire
import spell_scene_judgment
import spell_scene_warp
import spell_scene_scolding

ROOT=Path(__file__).resolve().parents[2]
VERSION='spell-scene-export/52'


def block(address):
    values=struct.unpack_from('<12i',maindec.body(),address-maindec.MBASE)
    return dict(zip(('position','angles','c','d'),[list(values[i:i+3]) for i in (0,3,6,9)]))


def interpreted_block(address):return {k:[v>>12 for v in values] for k,values in block(address).items()}


def sample(piece=None, **fields):return dict(piece=piece,**fields)


def compact_tracks(library):
    # Both players already supply these defaults; retain explicit nondefault transforms.
    defaults=dict(target_weight=[0]*3,visible=True,position=[0]*3,scale=[4096]*3,
                  angles=[0]*3,node_angles=[0,0,1],size=4096,tint=[127]*3)
    spells=[]
    for spell in [*library['spells'],*library.get('unite_scenes',[])]:
        program=spell['program']
        if program is not None:
            program=dict(program,tracks=[[{k:v for k,v in row.items() if k not in defaults or v!=defaults[k]}
                                          for row in track] for track in program['tracks']])
        spells.append(dict(spell,program=program))
    result=dict(library,spells=spells[:len(library['spells'])])
    if library.get('unite_scenes'):result['unite_scenes']=spells[len(library['spells']):]
    return result


def variation(draw,modulus,bias=0,multiplier=1):return dict(draw=draw,modulus=modulus,bias=bias,multiplier=multiplier)


def source_tints(effect,duration):
    plan,binding=spell_scene_source.scalar_profile(int(effect['initializer'],16))
    if binding is None:raise ValueError('unresolved caster tint consumer')
    values=spell_scene_source.sample_scalar_channels(plan,duration-1,fields=[binding['field']])[binding['field']]
    if len(values)<duration:
        if any(p['updates'] is None for p in plan['timeline']):raise ValueError('incomplete caster tint channel')
        values.extend([values[-1]]*(duration-len(values)))
    return [[(value>>12)&255]*3 for value in values]


def source_scales(effect,duration,fields=None):
    initializer=int(effect['initializer'],16);plan,_=spell_scene_source.scalar_profile(initializer)
    if fields is None:
        facts,analysis=spell_scene_source.analyze(initializer)
        binding=spell_scene_source.sprite_scale_binding(facts,analysis)
        if binding is None:raise ValueError('unresolved sprite scale consumer')
        fields=binding['fields']
    samples=spell_scene_source.sample_scalar_channels(plan,duration-1,fields=[key for key in fields if key is not None])
    if any(len(values)<duration for values in samples.values()):raise ValueError('incomplete sprite scale channels')
    return [[samples[key][u]>>12 if key is not None else 4096 for key in fields] for u in range(duration)]


def source_graphics(effect,animation):
    facts=spell_scene_source.source_facts(int(effect['initializer'],16))
    result=spell_scene_objects.constructors(facts)
    if result['blocked']:raise ValueError('incomplete graphic constructor lowering')
    return [row for row in result['objects'] if row['animation']==animation]


def banded_support_program(effect,pieces):
    profile=spell_scene_support.staggered_bands(effect)
    if profile is None:return None
    phases=profile['facts']['phases'];end=sum(p['updates'] for p in phases);duration=end+1
    plan,_=spell_scene_source.scalar_profile(int(effect['initializer'],16))
    values=spell_scene_source.sample_scalar_channels(plan,end,fields=[profile['scale_field'],profile['opening_field']])
    scales=values[profile['scale_field']];openings=values[profile['opening_field']]
    tints=source_tints(effect,duration);caster=[];shared=[];wash=[]
    size=profile['caster']['size'];angles=[0,0,1];screen=[0,0,0];last_widths=[];last_openings=[]
    for u in range(duration):
        if u:
            phase=next(p['index'] for p in phases if p['start']<u<=p['start']+p['updates'])
            delta=profile['phases'][phase];size+=delta['size'];angles=[v+d for v,d in zip(angles,delta['angles'])]
            screen=[screen[row['channel']]+row['delta'] for row in delta['wash']]
        scale=scales[u]>>12
        caster.append(sample(pieces[0] if 0<u<phases[profile['caster_off']]['start']+phases[profile['caster_off']]['updates'] else None,position=[0,0,-70*4096],size=size,node_angles=angles.copy(),tint=tints[u]))
        shared.append(sample(scale=[scale]*3))
        width=battle_drops.trunc(openings[u],profile['count'])>>12
        current=openings[u];row_open=[];row_width=[]
        for i in range(profile['count']-1):
            angle=(current>>12)-width;current=(current&4095)|(angle<<12)
            row_open.append(angle);row_width.append(width)
        row_open.append(0);row_width.append(row_open[-2])
        last_openings.append(row_open);last_widths.append(row_width)
        wash.append([max(0,v>>12) for v in screen] if u<end else [0]*3)
    anchor='world' if profile['per_party'] else 'target'
    origin=dict(origin=[signed_word(0x8016B80C),signed_word(0x8016B810),0]) if profile['per_party'] else {}
    fan_stop=phases[profile['fan_off']]['start']+phases[profile['fan_off']]['updates'] if profile['fan_off'] is not None else end
    meshes=[dict(kind='fan',anchor=anchor,**origin,track=1,start=1 if profile['per_party'] else phases[profile['band_on']]['start']+1,stop=fan_stop,radius=profile['fan_radius'],segments=profile['fan_segments'],inner=profile['fan_inner'],outer=profile['fan_outer'],depth=profile['fan_depth'])]
    for i in range(profile['count']):
        meshes.append(dict(kind='band',anchor=anchor,**origin,track=1,start=phases[profile['band_on']]['start']+1,stop=phases[profile['band_off']]['start']+phases[profile['band_off']]['updates'],radius=profile['radius'],segments=profile['segments'],inner=profile['inner'],outer=profile['outer'],blend=profile['blend'],opening=[row[i] for row in last_openings],spread=[row[i] for row in last_widths]))
    impact=phases[profile['impact_phase']]['start']+(phases[profile['impact_phase']]['updates'] if profile['impact_end'] else 1)
    tracks=[caster,shared];bindings=[dict(anchor='caster',track=0)]
    if profile['per_party']:
        visible=phases[profile['particle_on']]['start'];stop=phases[profile['particle_off']]['start']+phases[profile['particle_off']]['updates']
        animation=profile['particles'][0]['animation']
        tracks.append([sample(clip_piece(effect,animation,u-visible,pieces,True) if visible<u<stop else None,
                              scale=[scales[u]>>12]*3,angles=[0,0,profile['rotation']*u],size=0,tint=tints[u]) for u in range(duration)])
        for i in range(profile['per_party_count']*6):
            size_mod,size_bias=profile['random_fields']['size'];angle_mod,angle_bias=profile['random_fields']['angle']
            bindings.append(dict(anchor='party_member',member_index=i//profile['per_party_count'],track=2,position=[profile['local_x'],0,0],
                                 random_z=variation(3*i+1,profile['height_range'],multiplier=-4096),random_angle=variation(3*i+2,angle_mod,bias=angle_bias),random_size=variation(3*i,size_mod,bias=size_bias)))
        program=dict(group=True,initial_draws_per_party=profile['per_party_count']*3,reaction=support_reaction(visible+1,duration))
    else:
        for row in profile['particles']:
            track=[sample()];node_size=row['size'];position=[row['initial'].get(axis*4,0) for axis in range(3)]
            for age in range(1,duration):
                node_size+=profile['growth']
                if node_size>profile['limit']:
                    node_size=profile['limit'];position[2]+=profile['rise']
                    if position[2]>0:break
                track.append(sample(clip_piece(effect,row['animation'],age,pieces,bool(row['looping'])),size=node_size,position=position.copy()))
            tracks.append(track);bindings.append(dict(anchor='target',track=len(tracks)-1,start=impact+row['delay']))
        period=profile['reaction_period'];restarts=list(range(impact,phases[profile['impact_phase']]['start']+phases[profile['impact_phase']]['updates'],period))
        program=dict(reaction=support_restarts(impact,duration,restarts))
    return dict(**program,impact=impact,duration=duration,initial_draws=0,center_after_reaction=False,tracks=tracks,objects=bindings,cameras=source_cameras(effect),
                meshes=meshes,wash=wash,wash_blend=profile['wash_blend'])


def lightning_clones(profile,pieces,duration,switch,world):
    phases=profile['facts']['phases'];end=duration-1
    tracks=[];bindings=[]
    for i,row in enumerate(profile['groups'][0]):
        track=[];mirror=[]
        for u in range(duration):
            age=max(0,u-row['delay']);height=min(profile['clone_limit'],(row['initial'][8]>>12)+(row['initial'][20]>>12)*age)
            visible=age>0 and u<end and (i==0 or height<profile['clone_limit'])
            angles=[0,profile['clone_turn']*min(max(u-phases[1]['start'],0),phases[1]['updates']) if i==0 else 0,1]
            fields=dict(position=[0,0,height*4096],size=row['size'],node_angles=angles,tint=[row['initial'][70]]*3)
            track.append(sample(pieces[0] if visible and u<switch else None,**fields))
            mirror.append(sample(pieces[0] if visible and u>=switch else None,**fields))
        tracks.append(track);bindings.append(dict(anchor='caster',track=len(tracks)-1))
        if i==0:mirror_track=mirror
    tracks.append(mirror_track);bindings.append(dict(**world,track=len(tracks)-1))
    return tracks,bindings


def lightning_program(effect,pieces):
    profile=spell_scene_lightning.profile(effect)
    if profile is None:return None
    phases=profile['facts']['phases'];end=sum(p['updates'] for p in phases);duration=end+1
    switch=phases[profile['target_phase']]['start']+1;flight=phases[profile['flight_phase']]
    repeating=profile['repeating'];strike=phases[profile['strike_phase']]['start']+1 if repeating else 0
    damage_phase=phases[profile['impact_phase']];impact=damage_phase['start']+(1 if repeating else damage_phase['updates'])
    world=dict(anchor='world',origin=[signed_word(0x8016B814),signed_word(0x8016B818),0],origin_until=strike) if repeating else dict(anchor='target')
    tracks,bindings=lightning_clones(profile,pieces,duration,switch,world);wash=[]
    for animation in (9,10):tracks.append([sample(clip_piece(effect,animation,age,pieces,True)) for age in range(duration)])
    tracks.append([sample(pieces[int(effect['animations'][2]['frames'][0]['piece'].split('_')[1])])])
    head,spark,pulse=len(tracks)-3,len(tracks)-2,len(tracks)-1
    for part,track in (('primary',head),('spark',spark),('pulse',pulse)):
        for i in range(len(profile['groups'][9])):bindings.append(dict(**world,track=track,particle_index=i,particle_part=part,center_on_target=True,center_y=False))
    for u in range(duration):
        fade=phases[-1]
        color=min(u,phases[0]['updates'])-min(max(u-fade['start'],0),fade['updates'])
        wash.append([color]*3 if u<end else [0]*3)
    spawn=[flight['start']+1+row['delay'] for row in profile['groups'][9]]
    cameras=source_cameras(effect);focus=[None]*duration
    collision_age=profile['height']//(profile['speed']>>12)+1
    landings=[at+collision_age-1 for at in spawn]
    if repeating:
        for row,at in zip(profile['groups'][9],spawn):
            if row['delay']!=0:continue
            again=at+collision_age-1+profile['spark_life_min']
            while again<=flight['start']+flight['updates']:
                landings.append(again+collision_age-1);again+=collision_age-1+profile['spark_life_min']
        landings.append(strike)
    for landing in set(landings):
        camera=next(c for c in reversed(cameras) if c['at']<=landing)
        if landing<camera['at']+camera['updates']:raise ValueError('lightning focus impulse overlaps camera interpolation')
        point=camera['target']['position'].copy();point[2]+=profile['focus_kick']>>12;focus[landing]=point
    reaction=reaction_track(profile['response']);reaction['start']=strike if repeating else flight['start']+profile['response_clock']+1
    emitter=dict(kind='lightning_bolts',start=min(spawn),stop=end,count=len(spawn),spawn_at=spawn,flight_stop=end if repeating else impact,
                 radius=profile['radius'],roots=square_roots(profile['radius']**2),min_z=-profile['height'],velocity_z=profile['speed'],color=[127]*3,
                 spark_track=spark,pulse_track=pulse,**{k:profile[k] for k in ('spark_life_min','spark_life_range','pulse_life','pulse_fade_at','pulse_grow','pulse_shrink')})
    if repeating:emitter.update(repeat_until=flight['start']+flight['updates'],strike_at=strike,strike_radius=profile['strike_radius'])
    return dict(impact=impact,duration=duration,initial_draws=0,**(dict(group=True) if repeating else dict(reaction_center_switch=True)),tracks=tracks,objects=bindings,cameras=cameras,
                meshes=[],wash=wash,wash_blend='subtractive',reaction=reaction,emitter=emitter,focus_samples=focus)


def arranged_lightning_program(effect,pieces):
    p=spell_scene_lightning.arranged_profile(effect)
    if p is None:return None
    phases=p['facts']['phases'];end=sum(v['updates'] for v in phases);duration=end+1
    switch=phases[2]['start']+1;impact=phases[-1]['start']+1
    tracks,bindings=lightning_clones(p,pieces,duration,switch,dict(anchor='target'))
    wash=[[0]*3];level=0
    for phase in phases:
        for _ in range(phase['updates']):
            level+=p['wash_steps'][phase['index']];wash.append([max(0,level>>12)]*3)
    wash[-1]=[0]*3
    heads=p['groups'][9]+p['groups'][7];spawn=[]
    for index,row in enumerate(heads):
        big=index>=len(p['groups'][9]);spawn.append(phases[3 if big else 2]['start']+1+row['delay'])
        for part,animation in (('primary',row['animation']),('spark',8 if big else 10),('pulse',1 if big else 2)):
            track=len(tracks)
            tracks.append([sample(clip_piece(effect,animation,age,pieces,True),angles=[0,0,row['initial'][68]]) for age in range(duration)] if part!='pulse' else [sample(clip_piece(effect,animation,0,pieces,True),angles=[0,0,row['initial'][68]])])
            bindings.append(dict(anchor='target',track=track,particle_index=index,particle_part=part))
    unresolved={c['site']:[] for c in p['facts']['camera_schedule'] if c['at'] is None}
    spell_scene_support.screen_flashes(effect,unresolved)
    cameras=[]
    for c in p['facts']['camera_schedule']:
        for at in [c['at']] if c['at'] is not None else unresolved[c['site']]:cameras.append(dict(at=at,updates=c['updates'],target=interpreted_block(c['block'])))
    reaction=reaction_track(p['response']);reaction['start']=phases[3]['start']+p['response_clock']
    emitter=dict(kind='lightning_bolts',start=min(spawn),stop=end,count=len(heads),spawn_at=spawn,flight_stop=end,
                 fixed_positions=[[row['initial'].get(i*4,0) for i in range(3)] for row in heads],target_height=True,
                 persistent_from=len(p['groups'][9]),spark_turn_at=phases[3]['start']+p['turn_delay'],spark_turn_stop=phases[3]['start']+phases[3]['updates'],spark_turn_step=p['turn_step'],spark_turn_limit=p['turn_limit'],focus_kick=p['focus_kick'],
                 radius=2,roots=square_roots(4),min_z=heads[0]['initial'][8]>>12,velocity_z=heads[0]['initial'][20],color=[127]*3,
                 spark_track=bindings[-2]['track'],pulse_track=bindings[-1]['track'],spark_life_min=p['spark_life'],spark_life_range=0,
                 **{k:p[k] for k in ('pulse_life','pulse_fade_at','pulse_grow','pulse_shrink')})
    return dict(impact=impact,duration=duration,initial_draws=0,tracks=tracks,objects=bindings,cameras=cameras,meshes=[],wash=wash,wash_blend='subtractive',reaction=reaction,emitter=emitter)


def contracting_lightning_program(effect,pieces):
    p=spell_scene_lightning.contracting_profile(effect)
    if p is None:return None
    phases=p['facts']['phases'];end=sum(v['updates'] for v in phases);duration=end+1
    tracks,bindings=lightning_clones(p,pieces,duration,duration,dict(anchor='target'))
    plan,_=spell_scene_source.scalar_profile(int(effect['initializer'],16))
    scales=spell_scene_source.sample_scalar_channels(plan,fields=[p['scale_field']])[p['scale_field']]
    wash=[[max(0,min(u,phases[0]['updates'])-max(0,u-phases[-1]['start']))]*3 for u in range(duration)]
    heads=p['groups'][9];spawn=[phases[2]['start']+1+row['delay'] for row in heads]
    for index,row in enumerate(heads):
        for part,animation in (('primary',row['animation']),('spark',3),('pulse',2)):
            track=len(tracks);tracks.append([sample(clip_piece(effect,animation,age,pieces,True),angles=[0,0,row['initial'][68]]) for age in range(duration)] if part!='pulse' else [sample(clip_piece(effect,animation,0,pieces,True),angles=[0,0,row['initial'][68]])])
            obj=dict(anchor='target',track=track,particle_index=index,particle_part=part)
            if part=='spark':
                obj['piece_track']=track;obj['track']=len(tracks)
                tracks.append([sample(scale=[scales[u]>>12]*2+[4096],size=scales[u]>>12,angles=[0,0,row['initial'][68]]) for u in range(duration)])
            bindings.append(obj)
    aura=p['groups'][8]
    for row in aura:
        start=phases[3]['start'];stop=start+p['aura_off']+1
        tracks.append([sample(clip_piece(effect,row['animation'],max(0,u-start),pieces,True) if start<u<stop else None,position=[row['initial'].get(i*4,0) for i in range(3)],size=row['size'],angles=[0,0,row['initial'][68]]) for u in range(duration)])
        bindings.append(dict(anchor='target',track=len(tracks)-1))
    meshes=[]
    for index,(clock,column) in enumerate(zip(p['column_starts'],p['columns'])):
        start=phases[2]['start']+clock+1;stop=phases[3]['start']+p['spark_off']+1
        heights=p['column_heights'][index]
        if len(heights)!=duration:raise ValueError('incomplete column height timeline')
        tracks.append([sample(scale=[scales[u]>>12]*2+[4096]) for u in range(duration)])
        mesh=dict(kind='column',anchor='target',track=len(tracks)-1,angles=column['angles'],start=start,stop=stop,radius=column['lower']['radius'],segments=column['segments'],inner=column['upper']['color'],outer=column['lower']['color'],base_heights=heights,heights=[column['upper']['height']]*duration)
        if column['upper']['radius']!=column['lower']['radius']:mesh['top_radius']=column['upper']['radius']
        blend=column['blend'] if column['semitransparent'] else 'opaque'
        if blend not in ('additive','subtractive','opaque'):raise ValueError('unsupported contracting column blend')
        if blend!='additive':mesh['blend']=blend
        meshes.append(mesh)
    base=reaction_track(p['response']);restarts=list(range(phases[3]['start']+1,phases[3]['start']+phases[3]['updates']+1,p['reaction_period']))
    first=restarts[0];last=restarts[-1]+base['release'];offsets=[];flashes=[];active=[]
    for update in range(first,last):
        age=update-max(at for at in restarts if at<=update);on=age<len(base['offsets'])
        offsets.append(base['offsets'][age] if on else [0,0]);flashes.append(base['flash_frames'][age] if on else None);active.append(on)
    reaction=dict(start=first,release=last-first,offsets=offsets,flash_frames=flashes,active_samples=active)
    emitter=dict(kind='lightning_bolts',start=min(spawn),stop=end,count=len(heads),spawn_at=spawn,flight_stop=phases[2]['start']+p['primary_off']+1,
                 fixed_positions=[[row['initial'].get(i*4,0) for i in range(3)] for row in heads],target_height=True,contact_holds=True,spark_stop=phases[3]['start']+p['spark_off']+1,persistent_from=0,
                 radius=2,roots=square_roots(4),min_z=heads[0]['initial'][8]>>12,velocity_z=heads[0]['initial'][20],color=[127]*3,
                 spark_track=bindings[8]['track'],pulse_track=bindings[9]['track'],spark_life_min=p['spark_life'],spark_life_range=0,
                 **{k:p[k] for k in ('pulse_life','pulse_fade_at','pulse_grow','pulse_shrink')})
    return dict(impact=end,duration=duration,initial_draws=0,tracks=tracks,objects=bindings,cameras=source_cameras(effect),meshes=meshes,wash=wash,wash_blend='subtractive',reaction=reaction,emitter=emitter)


def source_cameras(effect, unresolved=()):
    facts=spell_scene_source.source_facts(int(effect['initializer'],16))
    pending=iter(unresolved);result=[]
    for camera in facts['camera_schedule']:
        at=camera['at']
        if at is None:
            try:at=next(pending)
            except StopIteration:raise ValueError(f"unresolved camera trigger for {effect['name']}") from None
        result.append(dict(at=at,updates=camera['updates'],target=interpreted_block(camera['block'])))
    if next(pending,None) is not None:raise ValueError('unused camera timing calibration')
    return result


def support_reaction(start,duration):
    image=maindec.body();cursor=0x8016F234-maindec.MBASE
    offsets=[];colors=[];flashes=[];white=False;color=[128]*3;animation=None
    for _ in range(32):
        op=struct.unpack_from('<h',image,cursor)[0]
        if op==0:
            release=len(offsets)-1
            offsets=offsets[1:];colors=colors[1:];flashes=flashes[1:]
            while len(offsets)<duration-start:
                offsets.append([0,0]);colors.append([128]*3);flashes.append(None)
            return dict(start=start,release=release,animation=animation,offsets=offsets,tints=colors,flash_frames=flashes)
        length=OP_LEN_HW[op];args=struct.unpack_from('<'+'h'*(length-1),image,cursor+2)
        if op==4:animation=args[0]
        elif op==3:
            for _ in range(args[0]):offsets.append([0,0]);colors.append(color);flashes.append(3 if white else None)
        elif op==38:white=True
        elif op==39:white=False
        elif op==41:color=list(args)
        else:raise ValueError('unsupported support response operation')
        cursor+=2*length
    raise ValueError('unterminated support response')


def healing_orbits_program(effect,pieces):
    profile=spell_scene_source.healing_orbit_profile(effect)
    if profile is None:return None
    phases=profile['facts']['phases'];total=sum(p['updates'] for p in phases);duration=total+1
    visible=phases[profile['visible_phase']]['start'];impact=phases[profile['impact_phase']]['start']+phases[profile['impact_phase']]['updates']
    caster=[];target=[];wash=[];heights=[];tints=source_tints(effect,duration);size=profile['caster_size']
    scales=source_scales(effect,duration,profile['scalar_scale_fields']);screen=[0]*3;height=profile['column_height']
    for u in range(duration):
        if u:
            phase=next(p['index'] for p in phases if p['start']<u<=p['start']+p['updates'])
            delta=profile['phases'][phase];size+=delta['caster_size'];height+=delta['height']
            screen=[n+d for n,d in zip(screen,delta['wash'])]
        tint=tints[u]
        caster.append(sample(pieces[0] if 0<u<phases[2]['start'] else None,position=[0,0,-70*4096],size=size,tint=tint))
        age=max(u-visible,0)
        target.append(sample(clip_piece(effect,3,age,pieces,True) if visible<u<total else None,scale=scales[u],angles=[0,0,profile['rotation']*(age if profile['rotate_when_visible'] else u)],size=0,tint=tint))
        wash.append([max(0,n>>12) for n in screen] if u<total else [0]*3);heights.append(height)
    objects=[dict(anchor='caster',track=0)]
    count=profile['count']*(6 if profile['per_party'] else 1)
    for i in range(count):
        size_mod,size_bias=profile['random_fields']['size'];angle_mod,angle_bias=profile['random_fields']['angle']
        obj=dict(anchor='party_member' if profile['per_party'] else 'target',track=1,position=[profile['local_x'],0,0],random_z=variation(3*i+1,profile['height_range'],multiplier=-4096),random_angle=variation(3*i+2,angle_mod,bias=angle_bias),random_size=variation(3*i,size_mod,bias=size_bias))
        if profile['per_party']:obj['member_index']=i//profile['count']
        objects.append(obj)
    anchor='world' if profile['per_party'] else 'target';origin=[signed_word(0x8016B80C),signed_word(0x8016B810),0] if profile['per_party'] else None
    common=dict(anchor=anchor,track=1,start=1,stop=total,radius=profile['radius'],segments=profile['segments'])
    if origin is not None:common['origin']=origin
    program=dict(impact=impact,duration=duration,initial_draws=0 if profile['per_party'] else count*3,tracks=[caster,target],objects=objects,cameras=source_cameras(effect),
                 meshes=[dict(kind='fan',**common,inner=profile['fan_inner'],outer=profile['fan_outer'],depth=profile['depth']),dict(kind='column',**common,inner=profile['column_inner'],outer=profile['column_outer'],heights=heights,**(dict(top_radius=profile['top_radius']) if profile['top_radius']!=profile['radius'] else {}))],wash=wash,wash_blend=profile['wash_blend'])
    if profile['per_party']:
        program.update(group=True,initial_draws_per_party=profile['count']*3,reaction=support_reaction(impact,duration))
    if profile['rainfall']:add_falling_particles(program,effect,pieces,profile)
    return program


def add_falling_particles(program,effect,pieces,profile):
    image=spell_scene_source.Image();facts=profile['facts'];phases=facts['phases']
    init=spell_scene_source.Analysis(image,int(effect['initializer'],16),cut_backedges=True)
    _,driver=spell_scene_source.analyze(int(effect['initializer'],16))
    # Qualify the spawn/ground-transfer/animation consumer before lowering this helper family.
    expected={0x80107C60:0x1840000D,0x80107C70:0xAC62001C,0x80107C94:0xAD000060,
              0x80107CD0:0x0C049093,0x80107D04:0x0C048E38,0x801238FC:0x10400018,
              0x80123910:0x14400004,0x80123940:0x10400006,0x8012395C:0xAE20001C}
    for pc,word in expected.items():
        if image.word(pc)!=word:raise ValueError(f'falling helper consumer changed at {pc:#x}')
    lines=[(pc,e) for pc,e in init.events('call') if e[1]==0x80123a5c]
    spawn=[e for _,e in driver.events('call') if e[1]==0x80123e2c]
    if len(lines)!=1 or len(spawn)!=1 or not isinstance(spawn[0][2][1],int):raise ValueError('unresolved falling emitter')
    site,ctor=lines[0]
    import spell_scene_objects
    loops=[e for pc,e in init.events('branch') if e[4]<=site<=pc]
    if len(loops)!=1:raise ValueError('unresolved falling particle count')
    count=spell_scene_objects.counted_loop(init,loops[0],6)['count']
    splashes=source_graphics(effect,8)
    if len(splashes)!=count or any(o['size']!=4096 or o['enabled']!=0 or o['looping']!=0 for o in splashes):raise ValueError('unresolved splash constructor')
    track=animation_track(effect,8,pieces)
    for row in track:row['node_angles']=[spell_scene_source.sx16(image.word(0x801073D0)),0,1+spell_scene_source.sx16(image.word(0x801073E8))]
    program['tracks'].append(track);track_id=len(program['tracks'])-1
    origin=[signed_word(0x8016B80C),signed_word(0x8016B810),0]
    for i in range(count):program['objects'].append(dict(anchor='world',origin=origin,track=track_id,particle_index=i))
    radius=spawn[0][2][1]
    program['emitter']=dict(kind='falling_lines',start=phases[2]['start']+1,spawn_stop=phases[4]['start']+phases[4]['updates']-1,
                            stop=program['duration']-1,count=count,radius=radius,roots=square_roots(radius*radius),color=list(ctor[2][:3]),origin=origin,
                            min_z=spell_scene_source.signed((image.word(0x80123EEC)&65535)<<16|(image.word(0x80123EF0)&65535))>>12,
                            trail_min=image.word(0x80123F90)&65535,trail_range=image.word(0x80123F34)&65535,
                            velocity_z=(image.word(0x80123FE0)&65535)<<12,speed_range=image.word(0x80123FA8)&65535,splash_track=track_id)
    for mesh in program['meshes']:mesh.update(start=phases[profile['visible_phase']]['start']+1,stop=phases[4]['start']+phases[4]['updates'])
    program['reaction']=support_reaction(phases[4]['start']+1,program['duration'])


def support_restarts(start,duration,restarts):
    reaction=support_reaction(start,duration);base=support_reaction(0,duration)
    for i in range(duration-start):
        age=start+i-max(at for at in restarts if at<=start+i)
        for key in ('offsets','tints','flash_frames'):reaction[key][i]=base[key][age]
    reaction['release']=restarts[-1]+base['release']-start
    return reaction


def scheduled_columns_program(effect,pieces):
    image=spell_scene_source.Image();init=spell_scene_source.Analysis(image,int(effect['initializer'],16))
    calls=init.events('call');graphics=[e for _,e in calls if e[1]==0x801233B4]
    if [e[2][1] for e in graphics]!=[0,4] or not any(e[1]==0x8011D548 for _,e in calls) or not any(e[1]==0x801208A0 for _,e in calls):return None
    expected={0x801120B0:0x34160030,0x8011219C:0x2A820028,0x80112194:0x34636A00,
              0x80112208:0x3407017B,0x80112268:0x00101900,0x8011227C:0x34050096,
              0x80112280:0x34060078,0x80112288:0x2407FED4,0x80112290:0x2A020005,
              0x801124AC:0x3C040004,0x8011252C:0x14620008,0x801125C4:0x3042001F,
              0x80112604:0x24C6F234,0x80112630:0x28420080,0x801126B0:0xA4830042,
              0x801126CC:0x34020020,0x801126D8:0xAE4000E0,0x801126F8:0x2442F000,
              0x801127D4:0x34050078,0x801127D8:0x0C048BAD,0x80112820:0x3405005A,
              0x80112828:0x0C048BAD,0x8011286C:0x2842FED4,0x80112888:0x0C0481DB,
              0x80112924:0x24630080,0x80112990:0x24420040,0x80112998:0x28421001}
    for address,word in expected.items():
        if image.word(address)!=word:raise ValueError(f'scheduled-column source changed at {address:#x}')
    facts=spell_scene_source.source_facts(int(effect['initializer'],16));phases=facts['phases']
    if len(phases)!=5 or any(p['updates'] is None for p in phases):raise ValueError('unresolved scheduled-column phases')
    end=sum(p['updates'] for p in phases);duration=end+1;start=phases[3]['start']+1;impact=phases[4]['start']+1
    caster=[];shared=[];fan=[];columns=[[] for _ in range(5)];wash=[];clocks=[];tints=source_tints(effect,duration);scale_track=source_scales(effect,duration)
    enabled=[False]*5;delays=[16*i for i in range(5)];scales=[[1]*3 for _ in range(5)]
    for u in range(duration):
        n=[min(max(u-p['start'],0),p['updates']) for p in phases]
        size=scale_track[u][0]
        if start<=u<=phases[4]['start']:
            clock=u-start
            for i in range(5):
                if delays[i]==clock:delays[i]=0;enabled[i]=True;scales[i]=[1]*3
            for i in range(5):
                if delays[i]==0 and not enabled[i]:enabled[i]=True;scales[i]=[1]*3
        for i in range(5):
            if enabled[i] and u<end:
                scales[i][0]=min(scales[i][0]+128,size);scales[i][1]=min(scales[i][1]+128,size)
                if scales[i][0]==size:
                    scales[i][2]+=64
                    if scales[i][2]>4096:enabled[i]=False
            columns[i].append(sample(scale=scales[i].copy(),visible=enabled[i] and u<end))
        caster.append(sample(pieces[0] if 0<u<phases[2]['start'] else None,position=[0,0,-70*4096],size=1+64*n[0],node_angles=[0,0,1+64*n[0]],tint=tints[u]))
        shared.append(sample(pieces[2],scale=scale_track[u]))
        fan.append(sample(scale=[size]*3));wash.append([n[0]-n[4]]*3 if u<end else [0]*3)
        clocks.append(u-phases[3]['start'] if start<=u<phases[4]['start'] else u-phases[4]['start'] if u>=phases[4]['start'] else 0)
    origin=[signed_word(0x8016B80C),signed_word(0x8016B810),0]
    meshes=[dict(kind='fan',anchor='world',origin=origin,track=2,start=phases[2]['start']+1,stop=end,radius=120,segments=32,inner=[0]*3,outer=[127]*3,depth=379)]
    for i in range(5):meshes.append(dict(kind='column',anchor='world',origin=origin,track=3+i,start=start,stop=end,radius=120,top_radius=150,segments=32,inner=[64,64,0],outer=[144,144,0],heights=[-300]*duration,base_heights=[-300]*duration))
    count=len(source_graphics(effect,4));radius=image.word(0x801127D4)&65535
    return dict(group=True,impact=impact,duration=duration,initial_draws=count,center_after_reaction=False,
                tracks=[caster,shared,fan]+columns,objects=[dict(anchor='caster',track=0)]+[dict(anchor='world',origin=origin,track=1,particle_index=i) for i in range(count)],
                cameras=source_cameras(effect),meshes=meshes,wash=wash,wash_blend='subtractive',
                reaction=support_restarts(start,duration,list(range(start,phases[4]['start'],32))),
                emitter=dict(kind='scheduled_sprites',start=start,spawn_stop=phases[4]['start']+32,stop=end,scale_track=1,count=count,radius=radius,repeat_radius=image.word(0x80112820)&65535,delay_modulus=image.word(0x801120B0)&65535,spawn_clock=clocks,velocity_z=spell_scene_source.signed((0xFFFF<<16)|(image.word(0x80112194)&65535)),life_max=1,min_z=spell_scene_source.sx16(image.word(0x8011286C)),roots=square_roots(radius*radius),color=[127]*3))


def rising_column_program(effect,pieces):
    image=spell_scene_source.Image();init=spell_scene_source.Analysis(image,int(effect['initializer'],16))
    graphics=[e for _,e in init.events('call') if e[1]==0x801233B4]
    if [e[2][1] for e in graphics]!=[0,3,6] or not any(e[1]==0x801208A0 for _,e in init.events('call')):return None
    # Constructor/helper grammar is qualified against its scalar and draw consumers.
    expected={0x8011057C:0x2A82000A,0x80110598:0x34050006,0x801105D0:0x34020050,
              0x80110614:0x3405001E,0x80110624:0x2407FFFB,0x8011063C:0x3C030100,
              0x8011075C:0x24422000,0x80110774:0x24420040,0x80110794:0x24420040,
              0x801107AC:0x24421000,0x80110800:0x2442C000,0x80110850:0x34423333,
              0x80110890:0x24C6F234,0x801108D0:0xA4620042,0x801108F0:0x2442FFFE,
              0x801108FC:0x34020022,0x80110944:0x24C6F234,0x8011098C:0x3C03FFFC,
              0x801109B4:0x2442F000,0x80110A78:0x2414CAAB,0x80110AA4:0x3405001E,
              0x80110AA8:0x0C048BAD,0x80110AB8:0x3403003C,0x80110B2C:0x2842FF38,
              0x80110B4C:0x0C0481ED,0x80110B64:0xAE020008,0x80110BB0:0xAC620014,
              0x80110BB8:0x0C048E38,0x80110BF4:0x0C0481ED,0x80110C00:0x0C0482D6}
    for address,word in expected.items():
        if image.word(address)!=word:raise ValueError(f'rising-column consumer changed at {address:#x}')
    facts=spell_scene_source.source_facts(int(effect['initializer'],16));phases=facts['phases']
    if len(phases)!=5 or any(p['updates'] is None for p in phases):raise ValueError('unresolved rising-column phases')
    end=sum(p['updates'] for p in phases);duration=end+1;impact=phases[3]['start']+1
    count=len(source_graphics(effect,3));radius=image.word(0x80110AA4)&65535
    caster=[];shared=[];glyph=[];wash=[];heights=[];tints=source_tints(effect,duration);scales=source_scales(effect,duration)
    for u in range(duration):
        n=[min(max(u-p['start'],0),p['updates']) for p in phases]
        scale=scales[u]
        tint=tints[u]
        caster.append(sample(pieces[0] if 0<u<phases[2]['start'] else None,position=[0,0,-70*4096],size=1+64*n[0],node_angles=[0,0,1+64*n[0]],tint=tint))
        shared.append(sample(pieces[8],scale=scale))
        glyph.append(sample(clip_piece(effect,6,u,pieces,True) if 0<u<end else None,position=[0,0,-60*4096],size=scale[0]))
        heights.append(-5-2*n[3]);wash.append([n[0]-n[4]]*3 if u<end else [0]*3)
    restarts=[impact]+[phases[3]['start']+i for i in range(34,phases[3]['updates'],34)]
    reaction=support_restarts(impact,duration,restarts)
    return dict(impact=impact,duration=duration,initial_draws=0,center_after_reaction=False,
                tracks=[caster,shared,glyph],objects=[dict(anchor='caster',track=0),dict(anchor='target',track=2)]+[dict(anchor='target',track=1,particle_index=i) for i in range(count)],
                cameras=source_cameras(effect),meshes=[dict(kind='column',anchor='target',track=1,start=1,stop=end,radius=radius,segments=32,inner=[0]*3,outer=[80]*3,heights=heights)],wash=wash,wash_blend='subtractive',reaction=reaction,
                emitter=dict(kind='rising_sprites',start=impact,spawn_stop=phases[4]['start'],stop=end,scale_track=1,count=count,radius=radius,velocity_z=spell_scene_source.sx16(image.word(0x80110A78)),life_max=image.word(0x80110AB8)&65535,min_z=spell_scene_source.sx16(image.word(0x80110B2C)),roots=square_roots()[:radius*radius+1],color=[127]*3))


def signed_word(address):return struct.unpack_from('<i',maindec.body(),address-maindec.MBASE)[0]

def animation_track(effect,index,pieces,size=4096):
    result=[sample()]
    age=0
    frames=effect['animations'][index]['frames']
    duration=sum(f['ticks'] for f in frames)
    for age in range(1,duration):
        remaining=age
        chosen=frames[-1]
        for f in frames:
            if remaining<f['ticks']:chosen=f;break
            remaining-=f['ticks']
        result.append(sample(pieces[int(chosen['piece'].split('_')[1])],size=size))
    return result


def square_roots(maximum=10000):
    """Integer lookup consumer 8014EFE4, decoded into ordinary radius samples."""
    image=maindec.body();base=maindec.MBASE
    table=struct.unpack_from('<192h',image,0x8017242C-base)
    result=[0]
    for value in range(1,maximum+1):
        leading=32-value.bit_length();even=leading&~1
        exponent=(31-even)//2
        mantissa=(value<<(even-24)) if even>=24 else value>>(24-even)
        result.append((table[mantissa-64]<<exponent)>>12)
    return result


def reaction_track(address=0x8016F0D0):
    """Resolve the shared target actor script into screen-offset samples."""
    image=maindec.body();cursor=address-maindec.MBASE
    offset=[0,0];result=[];flash_start=flash_end=period=release=None;palette_start=1;white=False
    for _ in range(64):
        op=struct.unpack_from('<h',image,cursor)[0]
        if op==0:
            if flash_start is None or flash_end is None or release is None or (not white and period!=4):raise ValueError('unresolved reaction palette timing')
            offsets=result[1:]  # The actor advances again in the dispatch frame.
            frames=([3 if flash_start<=age<flash_end else None for age in range(len(offsets))] if white else
                    [((age-flash_start)//period)%3+(4 if palette_start==4 else 0) if flash_start<age<flash_end else None for age in range(len(offsets))])
            return dict(offsets=offsets,flash_frames=frames,release=release)
        length=OP_LEN_HW[op]
        if op==42:length=2+struct.unpack_from('<h',image,cursor+2)[0]
        args=struct.unpack_from('<'+'h'*(length-1),image,cursor+2)
        if op==3:result.extend([offset]*args[0])
        elif op==30:
            if args==(99,) and not white:flash_end=len(result)-1
            result.append(offset)  # Yields once before advancing on the actor's next callback.
        elif op==25:
            if args[0]!=1:raise ValueError('unsupported reaction offset mode')
            offset=list(args[1:])
        elif op==4:
            if args!=(1,) and not (white and args==(0,)):raise ValueError('unresolved magic hurt animation')
        elif op==35:
            if args!=(0,13):raise ValueError('unresolved magic colour callback')
            flash_start=len(result)-1
        elif op==38:
            if flash_start is not None:raise ValueError('mixed reaction palette modes')
            white=True;flash_start=len(result)-1
        elif op==39:
            if not white:raise ValueError('white reaction reset without a start')
            flash_end=len(result)-1
        elif op==42:
            if len(args)!=4 or args[:2]!=(3,0) or args[2] not in (1,4) or args[3]!=4:raise ValueError('unresolved reaction palette parameters')
            palette_start=args[2];period=args[-1]
        elif op==16:
            if args!=(0,1):raise ValueError('unresolved reaction release flags')
            release=len(result)-1
        elif op!=15:raise ValueError(f'unresolved magic reaction opcode{op}')
        cursor+=length*2
    raise ValueError('unterminated magic reaction')


def reaction_palettes(rows=(1,2,3)):
    return [struct.unpack_from('<32H',maindec.body(),0x8016B8A8+64*row-maindec.MBASE) for row in rows]


def flaming_program(effect,pieces):
    for pc,expected in {0x800FEE90:0x28420040,0x800FEF80:0x28420060,
                        0x800FF0D8:0x2842004A,0x800FF158:0x2842003C,
                        0x800FEFF4:0x34050020,0x800FF174:0x0C0496CA}.items():
        if maindec.mword(pc)!=expected:raise ValueError(f'Flaming source changed at {pc:#x}')
    caster=[];wash=[];tints=source_tints(effect,295)
    for update in range(295):
        a=min(update,64);c=min(max(update-234,0),60)
        caster.append(sample(pieces[0] if 0<update<95 else None,position=[0,0,-70*4096],tint=tints[update]))
        wash.append([max(0,(2048*a-2184*c)>>12),max(0,(4096*a-4369*c)>>12),max(0,(4096*a-4369*c)>>12)] if update<294 else [0,0,0])
    objects=[dict(anchor='caster',track=0)]
    for graphic in source_graphics(effect,8):
        if not isinstance(graphic['delay'],int) or not isinstance(graphic['initial'].get(0),int):raise ValueError('unresolved arrow placement')
        objects.append(dict(anchor='target_lane',track=1,start=161+graphic['delay'],position=[graphic['initial'][0],0,0]))
    objects.append(dict(anchor='target',track=2,start=225,center_on_target=True))
    return dict(impact=294,duration=295,initial_draws=0,
                tracks=[caster,animation_track(effect,8,pieces),animation_track(effect,7,pieces,size=8192)],objects=objects,
                cameras=source_cameras(effect),
                meshes=[],wash=wash,wash_blend='subtractive',
                reaction=dict(start=225,**reaction_track()),
                emitter=dict(start=65,stop=160,count=20,radius=100,roots=square_roots(),color=[127,0,0]))


def clip_piece(effect,index,age,pieces,loop=False):
    frames=effect['animations'][index]['frames'];duration=sum(f['ticks'] for f in frames)
    if loop:age%=duration
    elif age>=duration:return None
    for frame in frames:
        if age<frame['ticks']:return pieces[int(frame['piece'].split('_')[1])]
        age-=frame['ticks']
    raise ValueError('invalid animation duration')


def firestorm_program(effect,pieces):
    for pc,word in {0x800FF860:0x28420040,0x800FF890:0x28630020,
                    0x800FF954:0x28630040,0x800FFA30:0x28420040,
                    0x800FFC60:0x28420070,0x800FFD40:0x28420040,
                    0x800FFC3C:0x0C038E08,0x800FFCBC:0x0C0496CA}.items():
        if maindec.mword(pc)!=word:raise ValueError(f'Firestorm source changed at {pc:#x}')
    tracks=[];objects=[];wash=[]
    def add(track,anchor='caster',**fields):
        index=len(tracks);tracks.append(track);objects.append(dict(anchor=anchor,track=index,**fields))
    tints=source_tints(effect,435)
    add([sample(pieces[0] if 0<u<433 else None,position=[0,0,-70*4096],tint=tints[u]) for u in range(435)])
    for index,position in enumerate(([0,30*4096,0],[0,-30*4096,0],[30*4096,0,0],[-30*4096,0,0])):
        track=[]
        for u in range(435):
            n=u-96;angle=[0,0,0];angle[2 if index<2 else 1]=64*n
            track.append(sample(pieces[30] if 97<=u<160 else None,position=position,angles=angle,scale=[4096-64*n]*3))
        add(track,origin=[0,0,-50])
    add([sample(pieces[1] if 161<=u<208 else None,size=(1+512*min(max(u-160,0),16)-256*max(u-176,0))) if 161<=u<208 else sample() for u in range(435)],origin=[0,0,-50])
    add([sample(clip_piece(effect,12,u-170,pieces,True),position=[0,0,-38400*(u-170)],size=min(4096,1+256*(u-160)),node_angles=[0,0,1243]) if 171<=u<225 else sample() for u in range(435)],origin=[0,0,-50])
    add([sample(clip_piece(effect,12,u-170,pieces,True),position=[0,0,-300*4096+38400*(u-224)],size=8192,node_angles=[0,0,-1243]) if 225<=u<258 else sample() for u in range(435)],'world',origin=[-128,0,0])
    add(animation_track(effect,6,pieces,size=8192),'world',origin=[-128,0,0],start=258)
    arrows=animation_track(effect,8,pieces)
    for lane in range(4):
        track=len(tracks);tracks.append([dict(s,angles=[0,0,lane*1024]) for s in arrows])
        for ring in range(8):objects.append(dict(anchor='world',origin=[-128,0,0],track=track,start=277+10*ring,position=[20*(ring+1)*4096,0,0]))
    add(animation_track(effect,7,pieces,size=6144),'each_target',start=337,center_on_target=True)
    for u in range(435):
        a=min(u,64);b=min(max(u-369,0),64)
        wash.append([max(0,(2048*a-2048*b)>>12),max(0,(4096*a-4096*b)>>12),max(0,(4096*a-4096*b)>>12)] if u<433 else [0,0,0])
    focus=[None]*435;focus[258]=[-163,0,5];focus[337]=[-160,0,5]
    return dict(group=True,center_after_reaction=False,impact=369,duration=434,initial_draws=0,tracks=tracks,objects=objects,
                cameras=source_cameras(effect,unresolved=(306,)),
                focus_samples=focus,meshes=[],wash=wash,wash_blend='subtractive',reaction=dict(start=337,**reaction_track()))


def fog_reaction():
    image=maindec.body();cursor=0x8016F1CC-maindec.MBASE
    offsets=[];offset=[0,0];frames=[];white=False;release=None
    for _ in range(64):
        op=struct.unpack_from('<h',image,cursor)[0]
        if op==0:
            if release is None:raise ValueError('missing Fog actor release')
            return dict(start=223,release=release,offsets=offsets[1:],flash_frames=frames[1:])
        count=OP_LEN_HW[op];args=struct.unpack_from('<'+'h'*(count-1),image,cursor+2)
        if op==3:
            offsets.extend([offset]*args[0]);frames.extend([3 if white else None]*args[0])
        elif op==25:offset=list(args[1:])
        elif op==38:white=True
        elif op==39:white=False
        elif op==16:release=len(offsets)-1
        elif op not in (4,15):raise ValueError('unsupported Fog hit opcode')
        cursor+=count*2
    raise ValueError('unterminated Fog reaction')


def effect_sine(angle):
    angle&=4095;sign=-1 if angle>2048 else 1
    if angle>2048:angle-=2048
    index=angle if angle<=1024 else 2048-angle
    return sign*struct.unpack_from('<h',maindec.body(),0x801765BC+index*2-maindec.MBASE)[0]


def fog_program(effect,pieces,rows):
    for pc,word in {0x801063D0:0x28630040,0x80106420:0x28630020,
                    0x8010649C:0x28420020,0x80106584:0x1C400088,
                    0x80106630:0x0C038E08,0x80106674:0xA6420036,
                    0x80122D38:0x34050001,0x80122E68:0x2A820040,
                    0x80122E78:0x2AE21404}.items():
        if maindec.mword(pc)!=word:raise ValueError(f'Fog source changed at {pc:#x}')
    caster=[];wash=[];tints=source_tints(effect,320)
    for u in range(320):
        a=min(u,64);b=min(max(u-64,0),32)
        caster.append(sample(pieces[0] if 0<u<96 else None,position=[0,0,-70*4096],size=1+64*a+128*b,tint=tints[u]))
        wash.append([min(max(u-96,0),32)-min(max(u-286,0),32)]*3 if u<318 else [0]*3)
    layers=[]
    for start,stop,period in ((161,254,200),(129,286,300)):
        samples=[]
        for u in range(320):
            if not start<=u<stop:samples.append(None);continue
            amplitude=min(u-160,32)-min(max(u-222,0),32) if period==200 else 100
            intensity=(7168*(min(u-start+1,32)-min(max(u-(222 if period==200 else 254),0),32)))>>12
            phase=(u-start+1)%period;vertices=[]
            for row in range(64):
                top=(effect_sine(((4*row+phase)<<12)//period)*amplitude)>>12
                bottom=(effect_sine(((4*row+phase+3)<<12)//period)*amplitude)>>12
                vertices.append([[top-2*amplitude,row*4],[top+320+2*amplitude,row*4],[bottom-2*amplitude,row*4+4],[bottom+320+2*amplitude,row*4+4]])
            samples.append(dict(vertices=vertices,tint=intensity))
        layers.append(dict(entries=rows,samples=samples,copies=2))
    return dict(group=True,impact=223,duration=319,initial_draws=0,tracks=[caster],objects=[dict(anchor='caster',track=0)],
                cameras=source_cameras(effect),
                meshes=[],wash=wash,wash_blend='subtractive',reaction=fog_reaction(),screen_layers=layers)


def build(extra_hurt_ids=(), include_couple=False, include_warriors=False, include_martial=False, include_beat=False):
    sweep=spell_effect_sweep.build();sections,atlases,errors,data=battle_bin.parse()
    if errors:raise ValueError(errors)
    blobs={a['offset']:a['atlas'] for a in atlases};palette=blobs[sweep['effects'][0]['palette_source']['blob_offset']]
    entries=[];pieces=[];spells=[];images=[];bitmap_ids={};entry_ids={}
    by_name={e['name']:e for e in sweep['effects']};bank_mappings={};bank_effects={}
    wave_rows=[]
    names=item_tables.spell_names()
    for native,name in enumerate(names,1):
        effect=by_name[name];mapping=[]
        for piece in effect['pieces']:
            members=[]
            for en in piece['entries']:
                page=blobs[sections[effect['section']]['atlas_offsets'][en[2]]]
                image=entry_image(page,palette,en)
                key=(image.size,hashlib.sha256(image.tobytes()).hexdigest())
                bitmap=bitmap_ids.get(key)
                if bitmap is None:
                    bitmap=len(images);bitmap_ids[key]=bitmap;images.append(image)
                dx,dy=en[0]-piece['header'][4],en[1]-piece['header'][5]
                geometry=(bitmap,dx,dy)
                entry=entry_ids.get(geometry)
                if entry is None:
                    entry=len(entries);entry_ids[geometry]=entry
                    entries.append(dict(bitmap=bitmap,dx=dx,dy=dy,w=image.width,h=image.height))
                members.append(entry)
            mapping.append(len(pieces));pieces.append(members)
        bank_mappings[effect['section']]=mapping;bank_effects[effect['section']]=effect
        rows=[]
        if native in (10,13):
            wave_effect=effect if native==10 else by_name['Fog of Deception']
            en=wave_effect['pieces'][2]['entries'][0]
            if en!=[0,0,8,0,95,63,73,128]:raise ValueError('Fog strip texture changed')
            image=entry_image(blobs[sections[wave_effect['section']]['atlas_offsets'][8]],palette,en)
            for y in range(64):
                rows.append(len(entries));strip=image.crop((0,y,96,y+1))
                entries.append(dict(bitmap=len(images),dx=0,dy=0,w=96,h=1));images.append(strip)
            wave_rows=rows
        program=spell_scene_fire.final_program(effect,mapping) or spell_scene_lightning.thunder_program(effect,mapping) or spell_scene_earth.earthquake_program(effect,mapping) or spell_scene_fire.explosion_program(effect,mapping) or spell_scene_fire.dancing_program(effect,mapping) or healing_orbits_program(effect,mapping) or rising_column_program(effect,mapping) or scheduled_columns_program(effect,mapping) or banded_support_program(effect,mapping) or lightning_program(effect,mapping) or arranged_lightning_program(effect,mapping) or contracting_lightning_program(effect,mapping) or spell_scene_wind.storm_program(effect,mapping) or spell_scene_wind.shredding_program(effect,mapping) or spell_scene_wind.healing_trail_program(effect,mapping)
        if native==8:program=spell_scene_erosion.charm_program(effect,mapping,pieces,entries,images,blobs[sections[effect['section']]['atlas_offsets'][8]])
        if native==5:program=spell_scene_scolding.program(effect,mapping)
        if native==22:program=spell_scene_warp.voice_program(effect,mapping)
        if native in (25,26,27):
            import spell_scene_soul
            if native==25:program=spell_scene_soul.deadly_program(effect,mapping)
            elif native==26:program=spell_scene_soul.shadow_program(effect,mapping,incoming_root_fraction=0,point_initial_scales=[4096]*40)
            else:program=spell_scene_soul.hell_program(effect,mapping,incoming_root_fraction=0,incoming_velocity_fraction=0,point_initial_scales=[4096]*40)
        if native==31:program=spell_scene_wind.shining_program(effect,mapping)
        if native==28:program=spell_scene_judgment.program(effect,mapping,bank_effects[6],bank_mappings[6])
        if program is None and native==13:program=spell_scene_wind.sleep_program(effect,mapping,rows)
        if program is None:
            program=fog_program(effect,mapping,rows) if native==10 else flaming_program(effect,mapping) if native==1 else firestorm_program(effect,mapping) if native==2 else None
        sound=spell_scene_sound.profile(effect)
        if sound is not None:
            animation=sound['animation'];piece=effect['animations'][animation]['frames'][0]['piece']
            piece=int(piece.removeprefix('piece_')) if isinstance(piece,str) else piece
            en=effect['pieces'][piece]['entries'][0]
            # GetTPage(0,2,832,256), V128..184 reaches shared page8 at y384.
            raw=blobs[sections[effect['section']]['atlas_offsets'][8]]
            glyph=entry_image(raw,palette,[0,0,8,8 if sound['group'] else 0,62,56,en[6],0])
            split=[pieces[mapping[piece]][0]]
            for left in (0,31):
                split.append(len(entries));image=glyph.crop((left,0,left+32,57))
                entries.append(dict(bitmap=len(images),dx=0,dy=0,w=32,h=57));images.append(image)
            program=spell_scene_sound.program(effect,mapping,split)
        if program is not None and native not in (26,27):
            flashes=spell_scene_support.screen_flashes(effect)
            if flashes:program['screen_washes']=program.get('screen_washes',[])+flashes
        spells.append(dict(id=f'spell_{native}',name=name,program=program,blocker=None if program else 'object_choreography_not_exported'))
    # The common magic reaction selects each target's animation1, not a spell bitmap.
    raw,actor_source=actor_art.source('/A_DATA.BIN')
    _,_,directory,_=encounters.chain(raw)
    table=struct.unpack_from('<I',raw,directory+12-encounters.BASE)[0]
    airborne_facts=[]
    hurt_poses=[];flash_palettes=reaction_palettes();idle_flash_sources=[]
    enemy_sources=[]
    for identifier,native in ENEMY_IDS.items():
        record=struct.unpack_from('<I',raw,table+4*native-encounters.BASE)[0]-encounters.BASE
        enemy_sources.append((identifier,raw,actor_source,record))
    if extra_hurt_ids:
        from export_enemy_regional import RECIPIENTS as regional_recipients
        from export_physical_runes import LATER_ENEMIES, recipient_resources
        found=set()
        extra_enemies=tuple(row for row in (('z',1,'ninja_master'),('g',1,'dagon'),('e',1,'whip_wolf'),('d',1,'holly_fairy'),('e',2,'sorcerer'),('g',3,'siren'),('h',3,'earth_golem'),*regional_recipients) if row[2] in extra_hurt_ids)
        for _,origin in recipient_resources(include_later=bool(set(extra_hurt_ids)&{name for _,_,name in LATER_ENEMIES}),extra_enemies=extra_enemies):
            if origin['id'] not in extra_hurt_ids:continue
            if origin['id'] in ENEMY_IDS:raise ValueError('duplicate extra hurt binding')
            data,location=actor_art.source('/'+origin['source']['file'].split('/')[-1])
            enemy_sources.append((origin['id'],data,location,origin['record_source_offset']))
            found.add(origin['id'])
        if found!=set(extra_hurt_ids):raise ValueError('unknown extra hurt binding')
    for identifier,raw,enemy_source,record in enemy_sources:
        airborne_facts.append(dict(id=identifier,airborne=bool(struct.unpack_from('<H',raw,record+38)[0]&32),source=enemy_source,offset=record+38))
        section=struct.unpack_from('<I',raw,record+44)[0]-encounters.BASE
        poses,animations,art_proof=actor_art.section_art(raw,section,encounters.BASE)
        if len(animations[1])!=1:raise ValueError('reaction needs an animated hurt-pose track')
        image,ax,ay=poses[animations[1][0][0]]
        off=art_proof['poses'][animations[1][0][0]]
        center=[raw[off+2+i]//2-(raw[off+4+i]-raw[off+8+i]) for i in range(2)]
        idle=art_proof['poses'][animations[0][0][0]]
        idle_center=[raw[idle+2+i]//2-(raw[idle+4+i]-raw[idle+8+i]) for i in range(2)]
        hurt_poses.append(dict(id=identifier,entry=len(entries),center=center,idle_center=idle_center,sprite_height=raw[idle+3],
            impact_offset=[((raw[off+6+i]-raw[off+4+i]+128)%256)-128 for i in range(2)]))
        if include_beat:hurt_poses[-1]["source_attachment"]=[raw[off+6+i]-raw[off+4+i] for i in range(2)]
        entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=image.width,h=image.height))
        images.append(image)
        flashes=[];idle_variants=[]
        for palette in flash_palettes:
            variants,_,_=actor_art.section_art(raw,section,encounters.BASE,palette_override=palette)
            idle_variants.append(variants)
            variant,vx,vy=variants[animations[1][0][0]]
            if variant.size!=image.size or (vx,vy)!=(ax,ay):raise ValueError('flash changed actor geometry')
            flashes.append(len(entries))
            entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=variant.width,h=variant.height))
            images.append(variant)
        white=struct.unpack_from('<32H',maindec.body(),0x8016B8A8-maindec.MBASE)
        variants,_,_=actor_art.section_art(raw,section,encounters.BASE,palette_override=white)
        variant,vx,vy=variants[animations[1][0][0]]
        hurt_poses[-1]['white_entry']=len(entries)
        entries.append(dict(bitmap=len(images),dx=-vx,dy=-vy,w=variant.width,h=variant.height));images.append(variant)
        hurt_poses[-1]['flash_entries']=flashes
        flags=raw[art_proof['animations'][0]+1]
        idle_flash_sources.append((hurt_poses[-1], animations[0], flags, idle_variants, poses))
        shock=[]
        for palette in reaction_palettes((4,5,6)):
            variants,_,_=actor_art.section_art(raw,section,encounters.BASE,palette_override=palette)
            variant,vx,vy=variants[animations[1][0][0]]
            if variant.size!=image.size or (vx,vy)!=(ax,ay):raise ValueError('shock palette changed actor geometry')
            shock.append(len(entries));entries.append(dict(bitmap=len(images),dx=-vx,dy=-vy,w=variant.width,h=variant.height));images.append(variant)
        hurt_poses[-1]['shock_entries']=shock
        from export_world_travel import squirrel_knockout_ticks
        scripts=struct.unpack_from('<I',raw,record+40)[0]-encounters.BASE
        duration=squirrel_knockout_ticks(raw,scripts)
        if len(animations[3])!=1:raise ValueError('knockout needs an animated pose track')
        dead,dx,dy=poses[animations[3][0][0]]
        hurt_poses[-1]['knockout']=dict(entry=len(entries),duration=duration)
        entries.append(dict(bitmap=len(images),dx=-dx,dy=-dy,w=dead.width,h=dead.height));images.append(dead)

    import character_table
    records=character_table.by_id();party_sources=[]
    for native,identifier in ((8,'hero'),(2,'gremio'),(6,'pahn'),(35,'viktor'),(38,'yam_koo'),(32,'tai_ho'),(70,'maas')):
        actor,source=actor_art.source('/'+records[native]['sprite_file'])
        section=struct.unpack_from('<I',actor,36)[0]
        poses,animations,art_proof=actor_art.section_art(actor,section)
        if len(animations[0])!=1:raise ValueError('support idle needs a timed pose track')
        idle=animations[0][0][0];image,ax,ay=poses[idle]
        white_poses,_,_=actor_art.section_art(actor,section,palette_override=white)
        whitened,wx,wy=white_poses[idle]
        if whitened.size!=image.size or (wx,wy)!=(ax,ay):raise ValueError('support palette changed geometry')
        entry=len(entries)
        for variant in (image,whitened):
            entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=variant.width,h=variant.height));images.append(variant)
        hurt_poses.append(dict(id=identifier,entry=entry,white_entry=entry+1))
        if len(animations[1]) != 1:raise ValueError('Unite hurt needs a timed pose track')
        hurt=animations[1][0][0];hurt_image,hx,hy=poses[hurt];hurt_white,_,_=white_poses[hurt]
        hurt_poses[-1]['unite_entry']=len(entries)
        hurt_poses[-1]['unite_white_entry']=len(entries)+1
        off=art_proof['poses'][hurt]
        hurt_poses[-1]['impact_offset']=[((actor[off+6+i]-actor[off+4+i]+128)%256)-128 for i in range(2)]
        if include_beat:hurt_poses[-1]["source_attachment"]=[actor[off+6+i]-actor[off+4+i] for i in range(2)]
        for variant in (hurt_image,hurt_white):
            entries.append(dict(bitmap=len(images),dx=-hx,dy=-hy,w=variant.width,h=variant.height));images.append(variant)
        party_sources.append(dict(id=identifier,source=source,section=section,idle_pose=art_proof['poses'][idle]))

    lba,size=battle_bin.battle_bin_lba()
    proof=dict(airborne_facts=airborne_facts,producer='spell-scene-export/53' if include_beat else VERSION,texture_bindings=dict(schema=sweep['schema'],effects=[{k:e[k] for k in ('name','initializer','section','graphics_bindings','screen_wave_bindings','auxiliary_sections')} for e in sweep['effects']]),file=battle_bin.DISC_PATH,lba=lba,size=size,decoder=battle_bin.DECODER_ID,
               sha256=hashlib.sha256(data).hexdigest(),main_source=dict(file='MAIN.EXE',lba=maindec.EXE_LBA,size=maindec.EXE_SIZE,image_sha256=hashlib.sha256(maindec.body()).hexdigest(),decoder='PS-X EXE header strip + static semantic conversion'),
               actor_source=actor_source,party_actor_sources=party_sources,reaction_palette=dict(file='MAIN.EXE',image_address='0x8016B8A8',rows=list(range(7)),white_updater='0x800E57E4',uploader='0x800DEA74',updater='0x800F3AA0'),visual_limits=dict(explosion_fractional_scale='Explosion normalizes unspecified initial model-scale residue below Q12 to zero; pre-cap scale can differ by 1/4096 from other residue values.',sound_fractional_scale='Yell/Scream normalize unspecified allocator residue below Q12 to zero; size differs by at most 1/4096 scale from other residue values.'),positive_visual_review=['spell_1','spell_9'],candidate_visuals=['spell_29','spell_32','spell_24','spell_4','spell_31','spell_28','spell_3','spell_13','spell_15','spell_14','spell_16','spell_6','spell_7','spell_2','spell_10','spell_12','spell_11','spell_17','spell_18','spell_19','spell_20','spell_21','spell_23','spell_30','spell_33'],native_pixel_comparison=False)
    schema='suikoden-spell-scenes/30' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='rising_lines' for s in spells) else 'suikoden-spell-scenes/27' if any(s['program'] and s['program'].get('actor_motion') for s in spells) else 'suikoden-spell-scenes/26' if any(s['program'] and s['program'].get('background_warps') for s in spells) else 'suikoden-spell-scenes/25' if any(s['program'] and s['program'].get('erosion') for s in spells) else 'suikoden-spell-scenes/24' if any(s['program'] and any(e['kind']=='ballistic_sprites' for e in s['program'].get('emitters',[])) for s in spells) else 'suikoden-spell-scenes/23' if any(s['program'] and any(e.get('initial_delays') is False for e in s['program'].get('emitters',[])) for s in spells) else 'suikoden-spell-scenes/22' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='bouncing_sprites' for s in spells) else 'suikoden-spell-scenes/21' if any(s['program'] and s['program'].get('scale_noise') for s in spells) else 'suikoden-spell-scenes/20' if any(s['program'] and s['program'].get('party_reaction') for s in spells) else 'suikoden-spell-scenes/19' if any(s['program'] and s['program'].get('emitters') for s in spells) else 'suikoden-spell-scenes/18' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='cycling_sprites' for s in spells) else 'suikoden-spell-scenes/17' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='spherical_sprites' for s in spells) else 'suikoden-spell-scenes/16' if any(s['program'] and any(m['kind']=='strip' for m in s['program']['meshes']) for s in spells) else 'suikoden-spell-scenes/15' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='scheduled_pulses' for s in spells) else 'suikoden-spell-scenes/14' if any(s['program'] and s['program'].get('emitter',{}).get('contact_holds') for s in spells) else 'suikoden-spell-scenes/13' if any(s['program'] and s['program'].get('emitter',{}).get('fixed_positions') for s in spells) else 'suikoden-spell-scenes/12' if any(s['program'] and s['program'].get('emitter',{}).get('strike_at',0) for s in spells) else 'suikoden-spell-scenes/11' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='lightning_bolts' for s in spells) else 'suikoden-spell-scenes/10' if any(s['program'] and s['program'].get('emitter',{}).get('kind')=='falling_lines' for s in spells) else 'suikoden-spell-scenes/9' if any(s['program'] and any(m['kind']=='band' for m in s['program']['meshes']) for s in spells) else 'suikoden-spell-scenes/8'
    proof['approved_adaptations']=[dict(spells=['spell_26','spell_27'],approval='2026-11-12: user accepts the current preview startup choice',root_fraction=0,velocity_fraction=0,point_scale=4096,particle_positions=[0]*3,particle_lifetimes=0,impact='Deterministic particle appearance and random draw consumption; original allocation residue remains unrecovered.')]
    proof['positive_visual_review']+=['spell_26','spell_27','spell_5']
    proof['approved_adaptations'].append(dict(spells=['spell_5'],approval='2026-11-12: user accepts Scolding with the Charm Arrow bank workaround',texture=dict(section=2,animation=4,piece=1),scope='Reuse the shared Sound/Charm glow for each recovered Scolding quad. Full donor UVs/palette and additive glow blending replace the unresolved opaque texture strip; original movement, projection and timing are preserved.',visual_acceptance='user_accepted_2026-11-12',accepted_preview_sha256=spell_scene_scolding.ACCEPTED_PREVIEW_SHA256))
    import unite_reaction_assets
    impacts,impact_images=unite_reaction_assets.build()
    impact_entries={}
    new_impact = next(clip for clip in impacts['animations'] if clip['id'] == 3)
    old_impact_poses = {frame['entry'] for clip in impacts['animations'] if clip['id'] != 3 for frame in clip['frames']}
    late_impact_poses = {frame['entry'] for frame in new_impact['frames']} - old_impact_poses
    late_impact_images = []
    for entry,image in zip(impacts['entries'],impact_images,strict=True):
        if entry['id'] in late_impact_poses:
            late_impact_images.append((entry,image))
            continue
        impact_entries[entry['id']]=len(entries)
        entries.append(dict(bitmap=len(images),dx=entry['dx'],dy=entry['dy'],w=image.width,h=image.height));images.append(image)
    clips=[dict(id=clip['id'],frames=[dict(entry=impact_entries[f['entry']],ticks=f['ticks']) for f in clip['frames']]) for clip in impacts['animations'] if clip['id'] != 3]
    proof['unite_impacts']=dict(source=impacts['source'],entries=impacts['entries'],spawns=impacts['spawns'],ranged_critical_animations=impacts['ranged_critical_animations'],ranged_critical_sources=impacts['ranged_critical_sources'],scope=impacts['scope'])
    physical_sources=[];physical_white_poses=[]
    for region,native,identifier in (('B',4,'roc'),('C',2,'kobold_type_2')):
        actor,source=actor_art.source('/'+region+'_DATA.BIN')
        _,_,directory,_=encounters.chain(actor)
        table=struct.unpack_from('<I',actor,directory+12-encounters.BASE)[0]-encounters.BASE
        record=struct.unpack_from('<I',actor,table+4*native)[0]-encounters.BASE
        section=struct.unpack_from('<I',actor,record+44)[0]-encounters.BASE
        poses,animations,details=actor_art.section_art(actor,section,encounters.BASE,animation_indices=(1,),selected_poses_only=True)
        variants,_,_=actor_art.section_art(actor,section,encounters.BASE,animation_indices=(1,),selected_poses_only=True,palette_override=white)
        if len(animations[1])!=1:raise ValueError('ordinary white reaction needs a timed pose track')
        index=animations[1][0][0];image,ax,ay=poses[index];whitened,wx,wy=variants[index]
        if image.size!=whitened.size or (ax,ay)!=(wx,wy):raise ValueError('ordinary white changed actor geometry')
        entry=len(entries)
        entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=whitened.width,h=whitened.height));images.append(whitened)
        physical_white_poses.append(dict(id=identifier,entry=entry))
        physical_sources.append(dict(id=identifier,source=source,section=section,pose=details['poses'][index],source_pose=index,entry=entry))
    proof['physical_hurt_sources']=physical_sources
    import unite_scene_beauty
    unite_scenes=[dict(id='beauty',name='Beauty Attack',program=unite_scene_beauty.program(bank_mappings[7],wave_rows),blocker=None)]
    if include_warriors:
        import battle_unite_camera
        import unite_scene_warriors
        contract = battle_unite_camera.report()[15]['controller_research']
        for source_piece in contract['impact_art']['pieces']:
            piece = int(source_piece['id'].removeprefix('piece_'))
            decoded = bank_effects[1]['pieces'][piece]
            if any(decoded[key] != source_piece[key] for key in ('header', 'entries')):
                raise ValueError('Warriors source piece differs')
        unite_scenes.append(dict(id='warriors', name='Warriors Attack',
                                 program=unite_scene_warriors.program(bank_mappings[1]), blocker=None))
        proof['warriors_effect'] = contract
    import battle_status_art
    status, status_images, status_proof = battle_status_art.build()
    first = len(entries)
    for entry, image in zip(status_proof['entries'], status_images, strict=True):
        entries.append(dict(bitmap=len(images),dx=entry['dx'],dy=entry['dy'],w=image.width,h=image.height));images.append(image)
    for icon in status['icons']:
        for frame in icon['frames']:frame['entry'] += first
    for frame in status['needle_burst']:frame['entry'] += first
    proof['status_art'] = status_proof
    import export_enemy_magic
    magic,magic_atlas,magic_proof=export_enemy_magic.build()
    mapping={}
    for piece in magic['pieces']:
        rect=piece['rect'];image=magic_atlas.image.crop((rect['x'],rect['y'],rect['x']+rect['w'],rect['y']+rect['h']))
        mapping[piece['id']]=len(entries)
        entries.append(dict(bitmap=len(images),dx=piece['dx'],dy=piece['dy'],w=image.width,h=image.height));images.append(image)
    magic_clips=[dict(id=clip['id'],frames=[dict(entry=mapping[frame['pose']],updates=frame['updates']) for frame in clip['frames']]) for clip in magic['clips']]
    if 'earth_golem' in extra_hurt_ids:
        for clip_id,anim_id in (('golem_rock',1),('golem_impact',2)):
            anim=next(row for row in bank_effects[6]['animations'] if row['id']==f'animation_{anim_id}')
            frames=[]
            for frame in anim['frames']:
                piece=int(frame['piece'].removeprefix('piece_'))
                members=pieces[bank_mappings[6][piece]]
                if len(members)!=1:raise ValueError('Earth Golem magic clip needs a single-piece pose')
                frames.append(dict(entry=members[0],updates=frame['ticks']))
            magic_clips.append(dict(id=clip_id,frames=frames))
    magic_art=dict(anchors=magic['impact_anchors'],clips=magic_clips)
    proof['enemy_magic_art']=magic_proof
    for pose,frames,flags,variants,normal_poses in idle_flash_sources:
        by_pose={}
        for source_pose,_ in frames:
            if source_pose in by_pose:continue
            ids=[]
            for variant in variants:
                image,ax,ay=variant[source_pose]
                ids.append(len(entries))
                entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=image.width,h=image.height));images.append(image)
            image,ax,ay=normal_poses[source_pose]
            normal=len(entries)
            entries.append(dict(bitmap=len(images),dx=-ax,dy=-ay,w=image.width,h=image.height));images.append(image)
            by_pose[source_pose]=(ids,normal)
        pose['idle_flash']=dict(advances=bool(flags&1),loop=bool(flags&2),
                                frames=[dict(ticks=ticks,entries=by_pose[index][0],normal=by_pose[index][1]) for index,ticks in frames])
    for entry,image in late_impact_images:
        impact_entries[entry['id']]=len(entries)
        entries.append(dict(bitmap=len(images),dx=entry['dx'],dy=entry['dy'],w=image.width,h=image.height));images.append(image)
    clips.append(dict(id=3,frames=[dict(entry=impact_entries[f['entry']],ticks=f['ticks']) for f in new_impact['frames']]))
    schema='suikoden-spell-scenes/46'
    if include_couple:
        import unite_linked_controllers
        contract = next(row for row in unite_linked_controllers.build()['controllers'] if row['record'] == 16)
        art = contract['impact_art']
        animation = next(row for row in art['animations'] if row['id'] == contract['damage']['start_impact_animation'])
        if animation['flags'] != 1:
            raise ValueError('Couple impact animation flags changed')
        mapping = bank_mappings[art['section']]
        frames = []
        for frame in animation['frames']:
            piece = int(frame['piece'].removeprefix('piece_'))
            source_piece = next(row for row in art['pieces'] if row['id'] == frame['piece'])
            decoded_piece = bank_effects[art['section']]['pieces'][piece]
            if any(decoded_piece[key] != source_piece[key] for key in ('header', 'entries')):
                raise ValueError('Couple impact source piece differs')
            members = pieces[mapping[piece]]
            if len(members) != 1:
                raise ValueError('Couple impact needs a single-piece pose')
            frames.append(dict(entry=members[0], ticks=frame['ticks']))
        clips.append(dict(id=animation['id'], frames=frames))
        proof['couple_impact'] = art
        schema='suikoden-spell-scenes/48'
    if include_martial:
        import unite_martial_controller
        recipients = unite_martial_controller.recipient_programs()
        if any(row['record'] == 29 for row in impacts['reactions']):
            raise ValueError('Martial arts recipients already bound')
        impacts['reactions'].extend(recipients['programs'])
        proof['martial_recipients'] = recipients
        schema='suikoden-spell-scenes/49'
    if include_beat:
        import unite_beat_controller
        recipients=unite_beat_controller.recipient_programs()
        impacts['reactions']=[r for r in impacts['reactions'] if r['record']!=27]+recipients['programs']
        proof['beat_recipients']=recipients
        schema='suikoden-spell-scenes/50'
    return dict(schema=schema,needle_burst=status['needle_burst'],enemy_magic_art=magic_art,status_icons=status['icons'],status_anchors=status['anchors'],unite_scenes=unite_scenes,hurt_poses=hurt_poses,unite_impacts=clips,unite_reactions=impacts['reactions'],physical_white_poses=physical_white_poses,atlas='spell_effects.png',entries=entries,pieces=pieces,spells=spells),images,proof


def append_shared_impacts(package, animations):
    """Append required shared animations without relocating existing entries."""
    package=Path(package)
    accepted=(ROOT/'kit/work/accepted').resolve()
    if accepted in (package.resolve(),*package.resolve().parents):raise ValueError('candidate impacts cannot enter accepted staging')
    library=json.loads((package/'spells.json').read_text())
    if library['schema'] not in ('suikoden-spell-scenes/50','suikoden-spell-scenes/51','suikoden-spell-scenes/52'):raise ValueError('shared impacts require the current scene library')
    animations=tuple(animations)
    if any(type(index) is not int or index not in (0,1,2,3,6,13,14,17,18,19,20) for index in animations):raise ValueError('unqualified shared impact animation')
    selected=sorted(set(animations)-{clip['id'] for clip in library['unite_impacts']})
    if not selected:return []
    sections,_,errors,raw=battle_bin.parse()
    if errors:raise ValueError(errors)
    section=sections[0];table=section['tables']['f']
    if any(type(index) is not int or not 0<=index<section['b_f_count'] for index in selected):raise ValueError('shared impact index outside source')
    pose_end=min(struct.unpack_from('<I',raw,table+4*i)[0]-battle_bin.LOAD_BASE for i in range(section['b_f_count']))
    poses,clips,details=actor_art.section_art(raw,section['header_offset'],battle_bin.LOAD_BASE,animation_indices=selected,pose_table_end=pose_end)
    from export_first_room import Atlas
    atlas=Atlas()
    with Image.open(package/'spell_effects.png') as old:
        atlas.image=Image.new('RGBA',(old.width,4096));atlas.image.paste(old,(0,0));atlas.y=old.height
    mapping={};sources={}
    for pose in sorted({p for index in selected for p,_ in clips[index]}):
        image,ax,ay=poses[pose]
        mapping[pose]=len(library['entries']);rect=atlas.add(image)
        library['entries'].append(dict(x=rect['x'],y=rect['y'],dx=-ax,dy=-ay,w=image.width,h=image.height))
        sources[pose]=dict(pose=pose,entry=mapping[pose],source_offset=details['poses'][pose],rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest())
    lba,size=battle_bin.battle_bin_lba()
    origin=dict(file=battle_bin.DISC_PATH,lba=lba,size=size,sha256=hashlib.sha256(raw).hexdigest(),decoder=battle_bin.DECODER_ID,section=section['header_offset'])
    proof=[]
    for index in selected:
        frames=clips[index];offset=details['animations'][index]
        if raw[offset+1]!=1:raise ValueError('shared impact must be a one-shot animation')
        if index==13 and frames!=[(62,4),(63,4),(64,4),(65,4),(66,4)]:raise ValueError('ordinary dust source animation changed')
        library['unite_impacts'].append(dict(id=index,frames=[dict(entry=mapping[p],ticks=t) for p,t in frames]))
        proof.append(dict(source=origin,animation=index,animation_offset=offset,frames=frames,poses=[sources[p] for p in sorted({p for p,_ in frames})]))
    if any(index in (14,17,20) for index in selected):library['schema']='suikoden-spell-scenes/52'
    atlas.save(package/'spell_effects.png')
    (package/'spells.json').write_text(json.dumps(library,separators=(',',':'))+'\n')
    return proof


def add_ordinary_dust(package):
    """Append source shared animation13 after the existing scene/atlas entries."""
    package=Path(package)
    library=json.loads((package/'spells.json').read_text())
    if library['schema']!='suikoden-spell-scenes/50' or any(c['id']==13 for c in library['unite_impacts']):raise ValueError('ordinary dust requires the current scene library without animation13')
    proof=append_shared_impacts(package,(13,))[0]
    if proof['frames']!=[(62,4),(63,4),(64,4),(65,4),(66,4)]:raise ValueError('ordinary dust source animation changed')
    library=json.loads((package/'spells.json').read_text());library['schema']='suikoden-spell-scenes/51'
    (package/'spells.json').write_text(json.dumps(library,separators=(',',':'))+'\n')
    return proof


def export(package,output,extra_hurt_ids=(),extra_unite_scenes=(),include_couple=False,include_warriors=False,include_martial=False,include_beat=False):
    package,output=Path(package),Path(output)
    accepted=(ROOT/'kit/work/accepted').resolve()
    if accepted in (output.resolve(),*output.resolve().parents):raise ValueError('review exporter cannot promote accepted art')
    library,images,proof=build(extra_hurt_ids, include_couple=include_couple, include_warriors=include_warriors, include_martial=include_martial, include_beat=include_beat)
    if extra_unite_scenes:
        if any(scene['id'] in {row['id'] for row in library['unite_scenes']} for scene in extra_unite_scenes):
            raise ValueError('Duplicate Unite scene id')
        library['unite_scenes'].extend(extra_unite_scenes)
        if not include_couple and not include_martial and not include_beat:library['schema']='suikoden-spell-scenes/47'
        proof['extra_unite_scenes']=[dict(id=scene['id'],program_sha256=hashlib.sha256(json.dumps(scene['program'],sort_keys=True,separators=(',',':')).encode()).hexdigest()) for scene in extra_unite_scenes]
    width=1024;x=0;y=0;row=0;positions=[]
    for image in images:
        if image.width>width:raise ValueError('spell crop wider than atlas')
        if x+image.width>width:x=0;y+=row+1;row=0
        positions.append((x,y));x+=image.width+1;row=max(row,image.height)
    if y+row>4096:raise ValueError('spell atlas exceeds runtime dimensions')
    atlas=Image.new('RGBA',(width,y+row+1))
    for image,position in zip(images,positions,strict=True):atlas.paste(image,position)
    for entry in library['entries']:entry['x'],entry['y']=positions[entry.pop('bitmap')]
    output.mkdir(parents=True,exist_ok=True);atlas.save(output/'spell_effects.png')
    for name in ('actors.png','floor.png','ground.png','trial.json'):shutil.copyfile(package/name,output/name)
    trial=json.loads((output/'trial.json').read_text())
    facts={f['id']:f['airborne'] for f in proof['airborne_facts']}
    changed=False
    for enemy in trial.get('enemies',[]):
        if enemy['id'] in facts:
            if enemy.get('airborne',facts[enemy['id']])!=facts[enemy['id']]:raise ValueError('battle airborne fact disagrees with the disc')
            if 'airborne' not in enemy:enemy['airborne']=facts[enemy['id']];changed=True
    if changed:(output/'trial.json').write_text(json.dumps(trial,indent=2)+'\n')
    (output/'spells.json').write_text(json.dumps(compact_tracks(library),separators=(',',':'))+'\n')
    proof['callback_analysis']=spell_scene_source.catalogue()
    proof['scalar_compiler']=spell_scene_source.batch_scalar_catalogue()
    proof['object_compiler']=spell_scene_objects.catalogue()
    proof['column_compiler']=spell_scene_columns.catalogue()
    proof['column_motion']=spell_scene_columns.motion_catalogue()
    proof['custom_quad_contracts']={'spell_5':spell_scene_scolding.profile()}
    import spell_scene_soul
    proof['custom_warp_contracts']={'spell_22':spell_scene_warp.voice_profile()}
    proof['soul_lifecycles']=spell_scene_soul.catalogue()
    proof['scene_sources']=json.loads((package/'provenance.json').read_text())
    proof['coverage']=dict(inventoried=len(library['spells']),programs=sum(s['program'] is not None for s in library['spells']),bitmaps=len(images),entries=len(library['entries']))
    (output/'provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
    (output/'manifest.json').write_text(json.dumps(dict(schema='suikoden-spell-review/1',status='candidate',files={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ('actors.png','floor.png','ground.png','trial.json','spell_effects.png','spells.json','provenance.json')}),indent=2)+'\n')
    return library


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',type=Path,default=ROOT/'kit/work/build/canonical/battle')
    parser.add_argument('--out',type=Path,default=ROOT/'kit/work/build/battle_review/spell_library/native')
    args=parser.parse_args();library=export(args.package,args.out)
    print(f"Exported {len(library['spells'])} spells' art; {sum(s['program'] is not None for s in library['spells'])} choreography programs; remaining records have explicit blockers")
