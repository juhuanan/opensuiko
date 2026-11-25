"""Shared sound-rune choreography, including the caller/helper counter alias."""
import spell_scene_source as source
import spell_scene_objects as objects
import spell_scene_columns as columns


def pulse_events(delays,start,updates,life=48,repeat_idle=False):
    counters=list(delays);enabled=[False]*len(delays);events=[]
    # The callback increments its clock before comparing it with the same field
    # that the common pulse helper decrements later in that update.
    for elapsed in range(1,updates):
        for index,counter in enumerate(counters):
            if counter==elapsed:
                events.append(dict(at=start+elapsed,index=index));counters[index]=life;enabled[index]=True
        if repeat_idle:
            for index,active in enumerate(enabled):
                if not active and counters[index]==0:
                    events.append(dict(at=start+elapsed,index=index));counters[index]=life;enabled[index]=True
        for index,active in enumerate(enabled):
            if active:
                counters[index]-=1
                if counters[index]==0:enabled[index]=False
    return events


def profile(effect):
    image=source.Image();initializer=int(effect['initializer'],16)
    init=source.Analysis(image,initializer,cut_backedges=True)
    graphics=[e[2][1] for _,e in init.events('call') if e[1]==objects.GRAPHIC]
    if graphics not in ([0,4,1],[0,4,2]):return None
    group=graphics[-1]==2
    facts,analysis=source.analyze(initializer);facts['phases']=source.timeline(facts,analysis)
    decoded=objects.constructors(facts,image);col=columns.motion(facts,image)
    if decoded['blocked'] or col['blocked'] or len(col['columns'])!=1 or len(facts['phases'])!=6:raise ValueError('unresolved sound constructors')
    pulses=[o for o in decoded['objects'] if o['animation']==4]
    if len(pulses)!=(20 if group else 5):raise ValueError('unresolved sound pulse count')
    # Qualify the aliased counter, compare, reset, common helper and RNG order.
    witnesses=({0x80104EA8:0x8E63011C,0x80104EAC:0x8E420024,0x80104EB4:0x1462001A,
                0x80104EBC:0x0C051F8E,0x80104F04:0x0C048BAD,0x80104F14:0xAE420024,0x80104F50:0x0C048203}
               if group else {0x801042D8:0x8E2300E0,0x801042DC:0x8E020024,0x801042E4:0x14620019,
                0x801042EC:0x0C051F8E,0x80104328:0x0C048BAD,0x80104340:0xAE020024,0x8010437C:0x0C048203})
    witnesses.update({0x80120814:0x28420021,0x80120830:0x24420200,0x80120844:0x2442FF00,0x80120864:0x2442FFFF,0x80120874:0xAC80001C})
    for pc,word in witnesses.items():
        if image.word(pc)!=word:raise ValueError(f'sound pulse source changed at {pc:#x}')
    uv_witnesses=({0x801046C0:0x341E0080,0x801046C4:0x34120040,0x801046F4:0x34060340,0x801046FC:0x34070100,0x80104728:0x0C052B7A,0x8010472C:0x00002821,0x80104754:0x26E3005F,0x80104764:0x340200B8,0x80104790:0x2A42007E}
                  if group else {0x80103AC0:0x34170080,0x80103AF0:0x34060340,0x80103AF8:0x34070100,0x80103B24:0x0C052B7A,0x80103B28:0x00002821,0x80103B50:0x2643001F,0x80103B60:0x340200B8,0x80103B88:0x2AA2003E,0x80104010:0x2463FFFA})
    for pc,word in uv_witnesses.items():
        if image.word(pc)!=word:raise ValueError(f'sound split texture source changed at {pc:#x}')
    root=('global',facts['state_global']);node=source.member(source.member(root,4),24)
    scale_field=280 if group else 220
    # shortcut: normalize unspecified allocator residue below Q12; revisit if subpixel parity is required.
    nested={source.member(root,scale_field):dict(key=scale_field,initial=4096,bits=32)}
    nested.update({source.member(node,o):dict(key=131072+o,initial=v,bits=b) for o,v,b in ((20,1,32),(28,1,16))})
    plan=source.scalar_channels(facts,analysis,nested)
    glyph=source.sample_scalar_channels(plan,fields=[131092,131100])
    motion=source.sample_scalar_channels(col['plan'],fields=list(col['columns'][0]['fields'].values()))
    phase=facts['phases'][3];life=image.word(0x80104F10 if group else 0x8010433C)&65535
    return dict(group=group,facts=facts,pulses=pulses,column=col['columns'][0],motion=motion,glyph=glyph,
                events=pulse_events([o['delay'] for o in pulses],phase['start'],phase['updates'],life),
                life=life,height=image.word(0x80104EC4 if group else 0x801042F4)&65535,
                radius=image.word(0x80104F00 if group else 0x8010432C)&65535,
                animation=graphics[-1])


def program(effect,pieces,split_entries):
    p=profile(effect)
    if p is None:return None
    import export_spell_scenes as export
    import battle_drops as math
    from spell_scene_player import Player
    phases=p['facts']['phases'];end=sum(row['updates'] for row in phases);duration=end+1
    split=phases[4]['start']+1;stop=phases[5]['start'];tints=export.source_tints(effect,duration)
    cameras=export.source_cameras(effect);camera=Player.__new__(Player);camera.program=dict(cameras=cameras);camera.last_landing=0
    glyph_piece=effect['animations'][p['animation']]['frames'][0]['piece'];glyph_index=int(glyph_piece.removeprefix('piece_')) if isinstance(glyph_piece,str) else glyph_piece
    if len(effect['pieces'][glyph_index]['entries'])!=1:raise ValueError('sound glyph needs one entry')
    entry=effect['pieces'][glyph_index]['entries'][0];header=effect['pieces'][glyph_index]['header']
    glyph=[];last=None;split_samples=[]
    for u in range(duration):
        quad=None
        if 96<u<split:
            b=camera.camera(u);scale=math.trunc(math.trunc(b[9]<<10,b[8])*p['glyph'][131092][u],4096)
            r=math.math_source.scale_matrix(math.math_source.rot_matrix([0,0,p['glyph'][131100][u]]),[scale]*3)
            x,y=entry[0]-header[4],entry[1]-header[5];w,h=entry[4]+1,entry[5]+1
            quad=[[160+((r[0]*px+r[1]*py)>>12),120+((r[3]*px+r[4]*py)>>12)] for px,py in ((x,y),(x+w,y),(x,y+h),(x+w,y+h))];last=quad
        glyph.append(dict(vertices=[quad],tint=127) if quad else None)
        halves=None
        if split<=u<=stop:
            halves=[]
            for half in range(2):
                q=[v.copy() for v in last]
                for left,right in ((0,1),(2,3)):
                    width=math.trunc(last[right][0]-last[left][0],2)
                    q[left][0]=last[left][0]+half*width;q[right][0]=q[left][0]+width
                shift=(-6 if half==0 else 6)*(u-split+1)
                halves.append([[x+shift,y] for x,y in q])
        split_samples.append(dict(vertices=halves,tint=127) if halves else None)
    caster=[export.sample(pieces[0] if 0<u<96 else None,position=[0,0,-60*4096],size=4096,tint=tints[u]) for u in range(duration)]
    fields=p['column']['fields'];values=p['motion'];column=p['column']['column']
    column_track=[export.sample(visible=bool(values[fields['enabled']][u]),scale=[values[fields[n]][u] for n in ('scale_x','scale_y','scale_z')]) for u in range(duration)]
    world=dict(anchor='world',origin=[export.signed_word(0x8016B80C),export.signed_word(0x8016B810),0]) if p['group'] else dict(anchor='target')
    mesh=dict(kind='column',**world,track=1,start=1,stop=end,radius=column['lower']['radius'],segments=column['segments'],inner=column['upper']['color'],outer=column['lower']['color'],base_heights=values[fields['lower_height']],heights=values[fields['upper_height']])
    pulse_piece=effect['animations'][4]['frames'][0]['piece'];pulse_index=int(pulse_piece.removeprefix('piece_')) if isinstance(pulse_piece,str) else pulse_piece
    tracks=[caster,column_track,[export.sample(pieces[pulse_index])]]
    bindings=[dict(anchor='caster',track=0)]+[dict(**world,track=2,particle_index=i,particle_part='pulse') for i in range(len(p['pulses']))]
    wash=[dict(depth=6,blend='additive',colors=[([min(u,64)//2]*3 if 0<u<end else None) for u in range(duration)])]
    reaction=export.support_reaction(177,duration) if p['group'] else dict(start=177,animation=0,offsets=[[0,0]]*(duration-177))
    return dict(group=p['group'],impact=end,duration=duration,initial_draws=0,center_after_reaction=False,tracks=tracks,objects=bindings,cameras=cameras,meshes=[mesh],wash=[[0]*3]*duration,wash_blend='additive',screen_washes=wash,reaction=reaction,
                emitter=dict(kind='scheduled_pulses',start=177,stop=end,count=len(p['pulses']),radius=p['radius'],roots=export.square_roots(p['radius']**2),color=[127]*3,height_range=p['height'],pulse_spawns=p['events'],pulse_life=p['life'],pulse_fade_at=32,pulse_grow=512,pulse_shrink=256),
                screen_layers=[dict(entries=split_entries[:1],samples=glyph,blend='opaque'),dict(entries=split_entries[1:],samples=split_samples,blend='opaque')])
