"""Source helper grammars for banded support scenes."""
import spell_scene_source as source
import spell_scene_objects as objects


def screen_flashes(effect, camera_events=None):
    """Lower the shared screen-light ramps and their caller resets into samples."""
    image=source.Image();initializer=int(effect['initializer'],16);facts,analysis=source.analyze(initializer)
    helpers={0x8011d264:'in',0x8011d3d4:'out'}
    if not any(e[1] in helpers for _,e in analysis.events('call')):return []
    facts['phases']=source.timeline(facts,analysis)
    if any(p['updates'] is None for p in facts['phases']):raise ValueError('screen flash needs resolved phase timing')
    init=source.Analysis(image,initializer);root=('global',facts['state_global'])
    ctors=[(pc,e) for pc,e in init.events('call') if e[1]==0x8011d154]
    if not ctors:raise ValueError('unbound screen flash constructor')
    plan,_=source.scalar_profile(initializer);scalar_samples=source.sample_scalar_channels(plan)
    duration=sum(p['updates'] for p in facts['phases'])+1;results=[]
    for ctor,call in ctors:
        total=call[2][0]
        if not isinstance(total,int) or not 1<=total<=4096:raise ValueError('invalid screen flash length')
        slot=_slot(init,root,('call',0x8011d154,ctor));owner=source.member(root,slot)
        state={72:0,76:total,80:total,88:0};initial_owner=('call',0x8011d154,ctor)
        for _,e in init.events('store'):
            offset=source.field(e[1],initial_owner)
            if offset is None:
                for parent in [root]+[e[2] for _,e in init.events('store') if e[1]==root]:
                    offset=source.field(e[1],source.member(parent,slot))
                    if offset is not None:break
            if offset in state:
                if not isinstance(e[2],int):raise ValueError('dynamic initial screen flash field')
                state[offset]=e[2]
        samples=[None];depth=state[72]
        for phase in facts['phases']:
            entry=facts['cases'][phase['index']]
            scoped=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=set(facts['cases'].values())-{entry})
            from functools import lru_cache
            @lru_cache(None)
            def reach(start,avoid=None):
                seen=set();pending=[start]
                while pending:
                    pc=pending.pop()
                    if pc in seen or pc==avoid:continue
                    seen.add(pc);pending.extend(scoped.edges.get(pc,()))
                return seen
            def lower(value):
                if isinstance(value,int):return value
                helper_field=source.field(value,owner)
                if helper_field in state:return ('value',('flash',helper_field))
                offset=source.field(value,root)
                if offset is not None:
                    if offset not in scalar_samples and offset not in (facts['clock_offset'],facts['phase_offset']):raise ValueError('unresolved flash guard field')
                    return ('value',offset)
                if isinstance(value,tuple) and len(value)==3 and value[0] in ('add','sub','lt','ult','and','or','shl','sar','shr'):
                    return (value[0],lower(value[1]),lower(value[2]))
                raise ValueError('unresolved flash guard expression')
            actions=[]
            for pc,events in sorted(scoped.records.items()):
                for event in events:
                    action=None
                    if event[0]=='call' and event[1] in helpers and event[2][0]==owner:action=dict(kind=helpers[event[1]])
                    elif event[0]=='call' and camera_events is not None and pc in camera_events:action=dict(kind='camera',site=pc)
                    elif event[0]=='store' and source.field(event[1],owner) in state:
                        if not isinstance(event[2],int):raise ValueError('dynamic screen flash reset')
                        action=dict(kind='set',field=source.field(event[1],owner),value=event[2])
                    if action is None:continue
                    guards=[]
                    for at,branch in scoped.events('branch'):
                        if at==pc or pc in reach(entry,at):continue
                        yes,no=branch[-2:];on_yes=pc in reach(yes);on_no=pc in reach(no)
                        if on_yes==on_no:continue
                        right=branch[3]
                        if branch[1]==1:
                            right=image.word(at)>>16&31
                            if right not in (0,1):raise ValueError('unsupported screen flash guard')
                        guards.append((branch[1],lower(branch[2]),lower(right),on_yes))
                    actions.append(dict(**action,guards=guards))
            if not actions:
                samples.extend([None]*phase['updates'])
                continue
            clock=source.phase_clocks(facts,analysis)[phase['index']]
            deltas={value for _,value in clock['deltas']}
            if len(deltas)!=1:raise ValueError('unresolved screen flash clock')
            step=deltas.pop()
            for age in range(phase['updates']):
                update=phase['start']+age+1
                before={key:values[update-1] for key,values in scalar_samples.items()}
                before[facts['clock_offset']]=phase['clock_initial']+step*age;before[facts['phase_offset']]=phase['index']
                color=None
                for action in actions:
                    inputs=dict(before);inputs.update({('flash',field):value for field,value in state.items()})
                    if not all(source.scalar_guard(guard,inputs) for guard in action['guards']):continue
                    if action['kind']=='camera':
                        camera_events[action['site']].append(update);continue
                    if action['kind']=='set':state[action['field']]=action['value'];continue
                    if state[76]<=0:raise ValueError('zero screen flash divisor')
                    if (action['kind']=='in' and state[80]>0) or (action['kind']=='out' and state[80]<state[76]):
                        sign=1 if action['kind']=='in' else -1
                        state[88]=source.signed(state[88]+sign*(0xff000//state[76]))
                        state[80]-=sign;color=[(state[88]>>12)&255]*3
                samples.append(color)
        if any(value is not None for value in samples):results.append(dict(depth=depth,blend='additive',colors=samples))
    return results


def _slot(init,root,handle):
    owners=[root]+[e[2] for _,e in init.events('store') if e[1]==root]
    slots={source.field(e[1],owner) for _,e in init.events('store') for owner in owners if e[2]==handle and source.field(e[1],owner) is not None}
    slots.update(source.field(handle,owner) for owner in owners if source.field(handle,owner) is not None)
    if len(slots)!=1:raise ValueError('unresolved support helper binding')
    return slots.pop()


def _delta(scoped,destination):
    values={e[2][2] for _,e in scoped.events('store') if e[1]==destination and isinstance(e[2],tuple) and len(e[2])==3 and e[2][:2]==('add',destination) and isinstance(e[2][2],int)}
    if len(values)>1:raise ValueError('conditional support recurrence')
    return next(iter(values),0)


def staggered_bands(effect):
    image=source.Image();initializer=int(effect['initializer'],16);init=source.Analysis(image,initializer)
    calls=init.events('call');graphics=[(pc,e) for pc,e in calls if e[1]==objects.GRAPHIC]
    bands=[(pc,e) for pc,e in calls if e[1]==0x80121c1c];fans=[(pc,e) for pc,e in calls if e[1]==0x8011d548]
    if len(graphics)!=2 or graphics[0][1][2][1]!=0 or graphics[1][1][2][1] not in (3,6) or len(bands)!=1 or len(fans)!=1:return None
    facts,analysis=source.analyze(initializer);facts['phases']=source.timeline(facts,analysis)
    if len(facts['phases'])!=7 or any(p['updates'] is None for p in facts['phases']):raise ValueError('unresolved banded support timeline')
    root=('global',facts['state_global']);first=source.Analysis(image,initializer,cut_backedges=True)
    band_site,band_call=bands[0];fan_site,fan_call=fans[0]
    loops=[e for pc,e in init.events('branch') if e[4]<=band_site<=pc]
    if len(loops)!=1:raise ValueError('unresolved support band loop')
    count=objects.counted_loop(first,loops[0],6)['count']
    opening=[]
    for pc,state in analysis.before.items():
        word=image.word(pc)
        if word>>26==0 and word&63==26 and state[word>>16&31]==count:
            offset=source.field(state[word>>21&31],root)
            if offset is not None:opening.append(offset)
    if len(set(opening))!=1:raise ValueError('unresolved support opening channel')
    scales=[]
    draw_sites=[pc for pc,e in analysis.events('call') if e[1]==0x80121ed8]
    for pc,event in analysis.events('store'):
        word=image.word(pc)
        if word>>26!=43:word=image.word(pc+4)
        if word>>26!=43 or source.sx16(word) not in (60,64,68) or not any(0<=at+4-pc<=32 for at in draw_sites):continue
        value=event[2]
        if isinstance(value,tuple) and len(value)==3 and value[0]=='sar' and value[2]==12:
            offset=source.field(value[1],root)
            if offset is not None:scales.append(offset)
    if len(set(scales))!=1:raise ValueError('unresolved support band scale')
    wash_calls=[(pc,e) for pc,e in calls if e[1]==0x8011cf4c]
    if len(wash_calls)!=1:raise ValueError('unresolved support wash')
    wash_slot=_slot(init,root,('call',0x8011cf4c,wash_calls[0][0]))
    decoded=objects.constructors(facts,image)
    if decoded['blocked']:raise ValueError('unresolved staggered support constructors')
    caster=next(o for o in decoded['objects'] if o['animation']==0)
    secondary=graphics[1][1][2][1];particles=[o for o in decoded['objects'] if o['animation']==secondary]
    counts=[sum(o['animation']==secondary for o in objects.constructors(facts,image,party)['objects']) for party in (1,2)]
    per_party=counts[1]==2*counts[0]
    if not particles or any(o['enabled']!=0 or not isinstance(o['delay'],int) for o in particles):raise ValueError('unresolved support sprite parameters')
    if not per_party and any(o['slot'] is None or o['size']!=1 or not isinstance(o['initial'].get(8),int) for o in particles):raise ValueError('unresolved staggered support sprite parameters')
    node=source.member(source.member(root,caster['slot']),24)
    array_owners=[e[1][1] for _,e in first.events('store') if e[2]==('call',0x80121c1c,band_site) and isinstance(e[1],tuple) and e[1][0]=='member']
    if len(array_owners)!=1:raise ValueError('unresolved support band array')
    band_slot=_slot(init,root,array_owners[0]);band_enabled=source.member(source.member(source.member(root,band_slot),0),0)
    caster_enabled=source.member(source.member(root,caster['slot']),28)
    fan_enabled=source.member(source.member(root,_slot(init,root,('call',0x8011d548,fan_site))),64)
    aliases=[e[2] for _,e in first.events('store') if e[1]==root]
    def context(value):
        if value in aliases:return root
        return tuple(context(v) for v in value) if isinstance(value,tuple) else value
    destinations=[e[1] for _,e in first.events('store') if e[2]==('call',objects.GRAPHIC,graphics[1][0])]
    if len(destinations)!=1:raise ValueError('unresolved support sprite array')
    particle=context(destinations[0]);particle_node=source.member(particle,24)
    phases=[];growth=set();rise=set();limits=set();band_on=[];band_off=[];caster_off=[];impacts=[];periods=set();particle_on=[];particle_off=[];fan_off=[];impact_end=False
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']]
        scoped=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=set(facts['cases'].values())-{entry},cut_backedges=True)
        angle_steps=[_delta(scoped,source.member(node,offset)) for offset in (24,26,28)]
        size_step=_delta(scoped,source.member(node,20))
        if not size_step:
            linked=[e[2] for _,e in scoped.events('store') if e[1]==source.member(node,20) and source.member(node,28) in list(source.leaves(e[2]))]
            if linked:size_step=angle_steps[2]
        wash_fields=[source.member(source.member(root,wash_slot),offset) for offset in (72,76,80)];wash_steps=[]
        for i,field in enumerate(wash_fields):
            changes=[e[2] for _,e in scoped.events('store') if e[1]==field and isinstance(e[2],tuple) and len(e[2])==3 and e[2][0]=='add' and e[2][1] in wash_fields and isinstance(e[2][2],int)]
            if len(set(changes))>1:raise ValueError('conditional support wash')
            wash_steps.append(dict(channel=wash_fields.index(changes[0][1]),delta=changes[0][2]) if changes else dict(channel=i,delta=0))
        phases.append(dict(size=size_step,angles=angle_steps,wash=wash_steps))
        for _,event in scoped.events('store'):
            if event[1]==band_enabled and event[2]==1:band_on.append(phase['index'])
            if event[1]==band_enabled and event[2]==0:band_off.append(phase['index'])
            if event[1]==caster_enabled and event[2]==0:caster_off.append(phase['index'])
            if event[1]==fan_enabled and event[2]==0:fan_off.append(phase['index'])
            if event[1]==source.member(particle,28) and event[2]==1:particle_on.append(phase['index'])
            if event[1]==source.member(particle,28) and event[2]==0:particle_off.append(phase['index'])
        impact_calls=[pc for pc,e in scoped.events('call') if e[1] in (0x800e04dc,0x800e1654)]
        if impact_calls:
            impacts.append(phase['index'])
            completion=phase['completion_site']
            reachable=set();pending=[entry]
            while pending:
                pc=pending.pop()
                if pc in reachable or pc==completion:continue
                reachable.add(pc);pending.extend(scoped.edges.get(pc,()))
            positions={pc not in reachable for pc in impact_calls}
            if len(positions)!=1:raise ValueError('mixed support impact boundaries')
            impact_end=positions.pop()
        for pc,state in scoped.before.items():
            word=image.word(pc)
            if word>>26==0 and word&63==26 and state[word>>21&31]==source.member(root,facts['clock_offset']):
                divisor=state[word>>16&31]
                if isinstance(divisor,int) and divisor>1:periods.add(divisor)
        value=_delta(scoped,source.member(particle_node,20))
        if value:growth.add(value)
        value=_delta(scoped,source.member(particle,8))
        if value:rise.add(value)
        for _,event in scoped.events('branch'):
            predicate=event[2]
            if isinstance(predicate,tuple) and len(predicate)==3 and predicate[0]=='lt' and isinstance(predicate[2],int):
                if any(term==source.member(particle_node,20) for term in source.leaves(predicate)):limits.add(predicate[2]-1)
    if not per_party and (len(growth)!=1 or len(rise)!=1 or len(limits)!=1):raise ValueError('unresolved support sprite growth')
    if len(set(band_on))!=1 or len(set(band_off))!=1 or not caster_off or len(set(impacts))!=1 or not per_party and len(periods)!=1:raise ValueError('unresolved support lifecycle')
    if caster['size'] is None or band_call[2][1] not in (1,2):raise ValueError('unsupported support primitive mode')
    result=dict(facts=facts,phases=phases,caster=caster,particles=particles,per_party=per_party,per_party_count=counts[0],
                growth=growth.pop() if growth else None,rise=rise.pop() if rise else None,limit=limits.pop() if limits else None,
                scale_field=scales[0],opening_field=opening[0],count=count,segments=band_call[2][0],
                band_on=band_on[0],band_off=band_off[0],caster_off=min(caster_off),impact_phase=impacts[0],reaction_period=periods.pop() if periods else None,
                wash_blend={1:'additive',2:'subtractive'}[wash_calls[0][1][2][0]],radius=source.stack_constant(first,band_site,24),blend='additive' if band_call[2][1]==1 else 'subtractive',
                inner=[source.stack_constant(first,band_site,n) for n in (28,32,36)],outer=[source.stack_constant(first,band_site,n) for n in (40,44,48)],
                fan_off=max(fan_off) if fan_off else None,impact_end=impact_end,fan_radius=fan_call[2][2],fan_depth=fan_call[2][3],fan_segments=fan_call[2][0],
                fan_inner=[source.stack_constant(first,fan_site,n) for n in (32,36,40)],fan_outer=[source.stack_constant(first,fan_site,n) for n in (44,48,52)])
    if per_party:
        if len(set(particle_on))!=1 or len(set(particle_off))!=1:raise ValueError('unresolved orbit support lifecycle')
        random_fields,height=source.orbit_random_parameters(image,init,graphics[1][0])
        local_x=particles[0]['initial'].get(0)
        rotations=[]
        loop_analysis=source.Analysis(image,analysis.start,analysis.end,analysis.indirect,cut_backedges=True)
        for pc,event in loop_analysis.events('store'):
            word=image.word(pc)
            if word>>26!=41:word=image.word(pc+4)
            if word>>26!=41 or source.sx16(word)!=68:continue
            value=event[2]
            if isinstance(value,tuple) and len(value)==3 and value[0]=='add' and isinstance(value[2],int):rotations.append(value[2])
        if len(set(rotations))!=1 or not isinstance(local_x,int):raise ValueError('unresolved orbit support movement')
        result.update(random_fields=random_fields,height_range=height,local_x=local_x,rotation=rotations[0],particle_on=particle_on[0],particle_off=particle_off[0])
    return result
