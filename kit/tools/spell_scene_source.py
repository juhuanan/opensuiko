"""Static callback analysis for bulk spell compilation; never executes original code.

The worklist joins register constants and symbolic field expressions over the
control-flow graph. Loops widen conflicting values to unknown. It does not
interpret instructions against a CPU, heap, emulated game or random stream.
"""
from collections import Counter, deque
from functools import lru_cache
import struct

import maindec
from mipsdec import sx16

CALLER_SAVED=(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,24,25,31)


def signed(value):
    value &= 0xffffffff
    return value-0x100000000 if value&0x80000000 else value


def operation(kind,a,b):
    if a is None or b is None:return None
    if isinstance(a,int) and isinstance(b,int):
        if kind=='add':return signed(a+b)
        if kind=='sub':return signed(a-b)
        if kind=='or':return signed(a|b)
        if kind=='and':return signed(a&b)
        if kind=='xor':return signed(a^b)
        if kind=='shl':return signed(a<<b)
        if kind=='sar':return signed(a)>>b
        if kind=='shr':return (a&0xffffffff)>>b
        if kind=='lt':return int(signed(a)<signed(b))
        if kind=='ult':return int((a&0xffffffff)<(b&0xffffffff))
    if kind in ('add','or') and b==0:return a
    if kind in ('add','or') and a==0:return b
    if kind in ('sub','shl','shr','sar') and b==0:return a
    if len(repr((a,b)))>240:return None
    return (kind,a,b)


def member(base,offset):
    if isinstance(base,int):return ('global',(base+offset)&0xffffffff)
    if base is None:return None
    if isinstance(base,tuple) and len(base)==3 and base[0]=='add':
        if isinstance(base[2],int):return member(base[1],offset+base[2])
        if isinstance(base[1],int):return member(base[2],offset+base[1])
    return ('member',base,offset)


def field(value,root):
    return value[2] if isinstance(value,tuple) and len(value)==3 and value[:2]==('member',root) else None


def leaves(value):
    if isinstance(value,tuple):
        yield value
        for child in value[1:]:yield from leaves(child)


class Image:
    def __init__(self,data=None,base=None):
        self.data=maindec.body() if data is None else data
        self.base=maindec.MBASE if base is None else base
    def word(self,address):
        offset=address-self.base
        if offset<0 or offset+4>len(self.data) or offset%4:raise ValueError(f'instruction outside image: {address:#x}')
        return struct.unpack_from('<I',self.data,offset)[0]
    def end(self,start):
        # These callback functions have a shared return epilogue.
        for pc in range(start,min(start+0x6000,self.base+len(self.data)-4),4):
            if self.word(pc)==0x03e00008:return pc+8
        raise ValueError(f'no bounded callback epilogue: {start:#x}')


class Analysis:
    def __init__(self,image,start,end=None,indirect=None,entry=None,initial=None,barriers=(),scalar_root=None,scalar_offsets=(),cut_backedges=False,scalar_fields=()):
        self.image=image;self.start=start;self.entry=start if entry is None else entry;self.end=image.end(start) if end is None else end
        self.scalar_root=scalar_root;self.scalar_offsets=scalar_offsets;self.scalar_fields=scalar_fields
        self.indirect=indirect or {};self.before={};self.records={};self.edges={};self.after={}
        if initial is None and hasattr(image,'entry_registers'):
            initial=image.entry_registers(start)
        regs=initial or ((0,)+(None,)*28+(('stack',),)+(None,)*2)
        if cut_backedges and len(regs)==32:regs=regs+(None,None)
        work=deque([(start if entry is None else entry,regs)])
        while work:
            pc,incoming=work.popleft()
            if not start<=pc<self.end or pc in barriers:continue
            previous=self.before.get(pc)
            state=incoming if previous is None else tuple(a if a==b else None for a,b in zip(previous,incoming))
            if state==previous:continue
            self.before[pc]=state
            regs=list(state);w=image.word(pc);op=w>>26;fn=w&63;rs=w>>21&31;rt=w>>16&31
            branch=('branch',op,regs[rs],regs[rt]) if op in (1,4,5,6,7) else None
            target=regs[rs] if op==0 and fn in (8,9) else None
            events=[];self.transfer(pc,regs,events)
            if op in (1,2,3,4,5,6,7) or op==0 and fn in (8,9):
                self.transfer(pc+4,regs,events)
                if branch:
                    branch+= (pc+4+(sx16(w)<<2),pc+8)
                    events.append(branch);edges=branch[-2:]
                    # Fold forward constant guards; keep loop exits after cutting backedges.
                    if cut_backedges and edges[0]>pc:
                        a,b=branch[2:4];taken=None
                        if op in (4,5) and isinstance(a,int) and isinstance(b,int):taken=(a==b) if op==4 else (a!=b)
                        elif isinstance(a,int):
                            if op==1 and rt in (0,1):taken=(a<0) if rt==0 else (a>=0)
                            elif op==6:taken=a<=0
                            elif op==7:taken=a>0
                        if taken is not None:edges=(edges[0 if taken else 1],)
                elif op==2:edges=(((pc+4)&0xf0000000)|((w&0x3ffffff)<<2),)
                elif op==3 or op==0 and fn==9:
                    address=((pc+4)&0xf0000000)|((w&0x3ffffff)<<2) if op==3 else target
                    events.append(('call',address,tuple(regs[4:8])))
                    if address in (0x801207ec,0x801207fc):
                        expected=(0xAC850008,0xAC850004,0x03E00008,0xAC850000)
                        if any(image.word(address+4*i)!=word for i,word in enumerate(expected)):raise ValueError('vector fill helper source changed')
                        for axis in range(3):events.append(('store',member(regs[4],4*axis),regs[5],32))
                    if self.scalar_fields and address==0x801207b4:
                        expected={0x801207B4:0xAFA40000,0x801207B8:0xAFA50004,0x801207BC:0xAFA60008,0x801207C0:0x00042303,0x801207C4:0xACE40000,0x801207C8:0x8FA20004,0x801207CC:0,0x801207D0:0x00021303,0x801207D4:0xACE20004,0x801207D8:0x8FA20008,0x801207DC:0,0x801207E0:0x00021303,0x801207E4:0x03E00008,0x801207E8:0xACE20008}
                        if any(image.word(at)!=word for at,word in expected.items()):raise ValueError('column vector helper source changed')
                        for axis in range(3):
                            destination=member(regs[7],4*axis)
                            if destination in self.scalar_fields:events.append(('store',destination,operation('sar',regs[4+axis],12),32))
                    for r in CALLER_SAVED:regs[r]=None
                    if len(regs)>32:regs[32:]=[None,None]
                    regs[2]=('call',address,pc)
                    edges=(pc+8,)
                else:
                    events.append(('indirect',target))
                    edges=self.indirect.get(pc,())
            elif op==0 and (fn in (12,13) or fn==48 and rs==0 and rt==0):edges=()
            else:edges=(pc+4,)
            regs[0]=0;self.records[pc]=events;self.after[pc]=tuple(regs)
            self.edges[pc]=tuple(a for a in edges if start<=a<self.end and (not cut_backedges or a>pc))
            for following in self.edges[pc]:work.append((following,tuple(regs)))
    def transfer(self,pc,regs,events):
        w=self.image.word(pc);op=w>>26;rs=w>>21&31;rt=w>>16&31;rd=w>>11&31;fn=w&63;sh=w>>6&31;im=sx16(w)
        a,b=regs[rs],regs[rt];dest=None;value=None
        if op==15:dest=rt;value=signed((w&65535)<<16)
        elif op in (8,9,10,11,12,13,14):
            dest=rt;kind={8:'add',9:'add',10:'lt',11:'ult',12:'and',13:'or',14:'xor'}[op]
            value=operation(kind,a,(w&65535) if op in (12,13,14) else im)
        elif op in (32,33,35,36,37):
            dest=rt;value=member(a,im)
            if hasattr(self.image,'resolve_load'):value=self.image.resolve_load(value)
            if field(value,self.scalar_root) in self.scalar_offsets or value in self.scalar_fields:value=('read',pc,value,op)
        elif op in (40,41,43):events.append(('store',member(a,im),b))
        elif op==0:
            if fn in (32,33,34,35,36,37,38,42,43):
                dest=rd;value=operation({32:'add',33:'add',34:'sub',35:'sub',36:'and',37:'or',38:'xor',42:'lt',43:'ult'}[fn],a,b)
            elif fn in (0,2,3):dest=rd;value=operation({0:'shl',2:'shr',3:'sar'}[fn],b,sh)
            elif fn in (4,6,7):dest=rd;value=operation({4:'shl',6:'shr',7:'sar'}[fn],b,a)
            elif fn in (16,18):
                dest=rd
                if len(regs)>32:value=regs[32 if fn==16 else 33]
            elif fn in (24,25,26,27) and len(regs)>32:
                regs[32:]=[None,None]
                if isinstance(a,int) and isinstance(b,int):
                    if fn in (25,27):a&=0xffffffff;b&=0xffffffff
                    if fn in (24,25):regs[32:]=[signed((a*b)>>32),signed(a*b)]
                    elif b:
                        quotient=abs(a)//abs(b)*(-1 if (a<0)!=(b<0) else 1)
                        regs[32:]=[signed(a-quotient*b),signed(quotient)]
            elif fn not in (8,9,17,19,24,25,26,27,12,13,48,49,50,51,52,54):raise ValueError(f'unsupported SPECIAL {pc:#x}: {w:#x}')
        elif op in (16,18):
            if rs in (0,2):dest=rt
        elif op not in (1,2,3,4,5,6,7,42,46,50,58):
            raise ValueError(f'unsupported instruction {pc:#x}: {w:#x}')
        if dest:regs[dest]=value
    def events(self,kind):
        return [(pc,event) for pc,events in sorted(self.records.items()) for event in events if event[0]==kind]


def installed_callback(analysis):
    choices=[]
    for pc,event in analysis.events('store'):
        destination,value=event[1:3]
        if destination==('member',('global',0x8017be3c),20) and isinstance(value,int):
            pointer=value&0xffffffff
            if analysis.end<=pointer<analysis.end+0x2000:choices.append(pointer)
    if len(set(choices))!=1:raise ValueError('unresolved callback installation')
    return choices[0]


def dispatch(image,updater):
    analysis=Analysis(image,updater)
    phase=None;root=None
    for pc,event in analysis.events('branch'):
        candidates=[v for x in event[2:4] for v in leaves(x) if len(v)==3 and v[0]=='member' and isinstance(v[1],tuple) and v[1][0]=='global' and 0x80179f00<=v[1][1]<0x8017a100]
        if candidates:phase=candidates[0];root=phase[1];break
    if phase is None:raise ValueError('callback has no recognized phase selector')
    cases={};table=None
    for pc,event in analysis.events('indirect'):
        terms=list(leaves(event[1]))
        address=next((v for v in terms if v[0]=='add' and isinstance(v[1],int) and ('shl',phase,2)==v[2]),None)
        table_value=address[1] if address is not None else next((v[2] for v in terms if len(v)==3 and v[0]=='member' and v[1]==('shl',phase,2) and isinstance(v[2],int)),None)
        if table_value is None:continue
        table=table_value&0xffffffff
        bounds=[]
        for at,branch in analysis.events('branch'):
            if at>=pc:break
            for value in leaves(branch[2]):
                if len(value)==3 and value[0] in ('lt','ult'):
                    if value[2]==phase and isinstance(value[1],int):bounds.append(value[1]+1)
                    if value[1]==phase and isinstance(value[2],int):bounds.append(value[2])
        if not bounds or not 1<=min(bounds)<=16:raise ValueError('unresolved phase table bound')
        cases={i:image.word(table+4*i) for i in range(min(bounds))}
        analysis=Analysis(image,updater,indirect={pc:tuple(cases.values())});break
    if not cases:
        for pc,event in analysis.events('branch'):
            if event[1]!=4:continue
            a,b=event[2:4]
            if a==phase and isinstance(b,int) and 0<=b<16:cases[b]=event[4]
            elif b==phase and isinstance(a,int) and 0<=a<16:cases[a]=event[4]
        if set(cases)!=set(range(len(cases))) or len(cases)<2:raise ValueError('unresolved binary phase dispatch')
    increments=Counter()
    for pc,event in analysis.events('store'):
        destination,value=event[1:3]
        offset=field(destination,root)
        if offset is not None and destination!=phase and isinstance(value,tuple) and value[0]=='add' and value[1]==destination and value[2] in (-1,1):increments[offset]+=1
    if not increments:raise ValueError('phase clock recurrence unresolved')
    clock=increments.most_common(1)[0][0]
    return analysis,root,phase[2],clock,cases,table


def analyze(initializer,image=None):
    image=image or Image();init=Analysis(image,initializer);updater=installed_callback(init)
    preparation=[]
    for _ in range(3):
        try:analysis,root,phase,clock,cases,table=dispatch(image,updater);break
        except ValueError:
            setup=Analysis(image,updater);following=installed_callback(setup)
            preparation.append(updater);updater=following
    else:raise ValueError('too many preparation callbacks')
    cameras=[];sounds=[]
    for pc,event in analysis.events('call'):
        target,args=event[1:]
        if target==0x800f6110:
            if not isinstance(args[0],int) or not isinstance(args[1],int):raise ValueError(f'unresolved camera operands at {pc:#x}')
            cameras.append(dict(site=pc,block=args[0]&0xffffffff,updates=args[1]))
        if target==0x800c3104 and isinstance(args[0],int):sounds.append(dict(site=pc,command=args[0]))
    return dict(initializer=initializer,preparation=preparation,updater=updater,state_global=root[1],phase_offset=phase,clock_offset=clock,table=table,cases=cases,cameras=cameras,sounds=sounds),analysis


def phase_clocks(facts,analysis):
    """Recognize phase-completion guards on the source's scalar clock."""
    root=('global',facts['state_global']);clock=('member',root,facts['clock_offset']);phase=('member',root,facts['phase_offset'])
    entries=set(facts['cases'].values());result=[]
    for index,entry in sorted(facts['cases'].items()):
        barriers=entries-{entry}
        scoped=Analysis(analysis.image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=barriers)
        @lru_cache(None)
        def reachable(start):
            seen=set();queue=[start]
            while queue:
                pc=queue.pop()
                if pc in seen or pc in barriers:continue
                seen.add(pc);queue.extend(scoped.edges.get(pc,()))
            return frozenset(seen)
        region=reachable(entry)
        anchors=set()
        for pc,event in scoped.events('store'):
            if pc not in region:continue
            if event[1]==phase and event[2] not in (None,phase):anchors.add(pc)
            if event[1]==('member',('global',0x8017be3c),20) and isinstance(event[2],int):anchors.add(pc)
        gates=[]
        for pc,event in scoped.events('branch'):
            if pc not in region:continue
            yes,no=event[-2:]
            # One arm advances/tears down this phase; the other returns to draw.
            yes_advances=bool(reachable(yes)&anchors);no_advances=bool(reachable(no)&anchors)
            if yes_advances==no_advances:continue
            predicate=event[2];other=event[3]
            if predicate==clock or isinstance(predicate,tuple) and clock in list(leaves(predicate)):
                gates.append(dict(site=pc,op=event[1],predicate=predicate,other=other,advance_on_branch=yes_advances))
        constants=[];deltas=[]
        for pc,event in scoped.events('store'):
            if pc not in region or event[1]!=clock:continue
            value=event[2]
            if isinstance(value,int) and reachable(pc)&anchors:constants.append((pc,value))
            if isinstance(value,tuple) and value[:2]==('add',clock) and isinstance(value[2],int):deltas.append((pc,value[2]))
        result.append(dict(index=index,entry=entry,gates=gates,resets=constants,deltas=deltas,anchors=sorted(anchors)))
    return result


def timeline(facts,analysis):
    """Compile only unconditional scalar-clock phases; keep data-dependent waits explicit."""
    initializers=[Analysis(analysis.image,pc) for pc in [facts['initializer']]+facts['preparation']]
    root=('global',facts['state_global']);clock=('member',root,facts['clock_offset'])
    owners=[root]+[event[2] for init in initializers for _,event in init.events('store') if event[1]==root]
    values=[event[2] for init in initializers for _,event in init.events('store') if any(event[1]==('member',owner,facts['clock_offset']) for owner in owners) and isinstance(event[2],int)]
    initial=values[-1] if values else None
    phases=phase_clocks(facts,analysis);elapsed=0;result=[]
    for phase in phases:
        entry=phase['entry'];barriers=set(facts['cases'].values())-{entry}
        scoped=Analysis(analysis.image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=barriers)
        def reaches(start,target,avoid=None):
            pending=[start];seen=set()
            while pending:
                pc=pending.pop()
                if pc in seen or pc==avoid:continue
                if pc==target:return True
                seen.add(pc);pending.extend(scoped.edges.get(pc,()))
            return False
        candidates=[]
        for gate in phase['gates']:
            p=gate['predicate'];limit=None
            if isinstance(p,tuple) and p[0] in ('lt','ult') and isinstance(p[2],int) and 1<=p[2]<=4096 and gate['other']==0:
                if (gate['op']==4)==gate['advance_on_branch']:limit=p[2]
            elif gate['op']==7 and not gate['advance_on_branch']:limit=0
            if limit is None or any(reaches(entry,anchor,avoid=gate['site']) for anchor in phase['anchors'] if anchor!=gate['site']):continue
            before=[(pc,delta) for pc,delta in phase['deltas'] if reaches(entry,pc) and reaches(pc,gate['site'])]
            if len(before)!=1 or reaches(entry,gate['site'],avoid=before[0][0]) and before[0][0]!=gate['site']:continue
            delta=before[0][1]
            if delta not in (-1,1) or limit==0 and delta!=-1 or limit>0 and delta!=1:continue
            if initial is not None:
                updates=limit-initial if delta==1 else initial
                if not 1<=updates<=4096:continue
                candidates.append((updates,limit,gate['site']))
        unique=set((n,end) for n,end,_ in candidates)
        updates=None;finish=None;reason=None
        if len(unique)==1:
            updates,finish=next(iter(unique))
        else:
            exits=[pc for pc in scoped.before if analysis.image.word(pc)==0x03e00008]
            anchors=phase['anchors']+[pc for pc,event in scoped.events('call') if event[1]==0x800c2dc0 and event[2][0]==root]
            unconditional=next((pc for pc in anchors if exits and all(not reaches(entry,end,avoid=pc) for end in exits)),None)
            if not phase['deltas'] and unconditional is not None:
                updates=1;finish=initial
            else:reason='phase_clock_depends_on_object_or_unresolved_control'
        result.append(dict(index=phase['index'],start=elapsed,updates=updates,clock_initial=initial,completion_site=candidates[0][2] if len(unique)==1 else None,blocker=reason))
        elapsed=elapsed+updates if elapsed is not None and updates is not None else None
        resets=set(value for _,value in phase['resets'])
        initial=next(iter(resets)) if len(resets)==1 else finish if not resets else None
    return result


@lru_cache(None)
def source_facts(initializer):
    facts,analysis=analyze(initializer)
    facts['phases']=timeline(facts,analysis)
    facts['camera_schedule']=camera_schedule(facts,analysis)
    return facts


def initial_values(facts,image):
    root=('global',facts['state_global']);values={};owners=[root]
    for entry in [facts['initializer']]+facts['preparation']:
        init=Analysis(image,entry)
        owners.extend(e[2] for _,e in init.events('store') if e[1]==root)
        for _,event in init.events('store'):
            for owner in owners:
                offset=field(event[1],owner)
                if offset is not None:values[offset]=event[2] if isinstance(event[2],int) else None
    return values


def exit_values(scoped,root,phase_offset):
    anchors={pc for pc,e in scoped.events('store') if e[1]==('member',root,phase_offset)}
    stores=[(pc,field(e[1],root),e[2]) for pc,e in scoped.events('store') if field(e[1],root) is not None]
    def walk(start,avoid=None,stop=False):
        pending=[start];seen=set()
        while pending:
            pc=pending.pop()
            if pc in seen or pc==avoid:continue
            seen.add(pc)
            if not stop or pc not in anchors:pending.extend(scoped.edges.get(pc,()))
        return seen
    entry=scoped.entry;result={}
    for pc,offset,value in stores:
        if not isinstance(value,int) or not anchors or any(anchor in walk(entry,avoid=pc) for anchor in anchors if anchor!=pc):continue
        after=walk(pc,stop=True)
        if any(other!=pc and key==offset and val!=value and other in after and walk(other)&anchors for other,key,val in stores):continue
        result[offset]=value
    return result


def camera_schedule(facts,analysis):
    root=('global',facts['state_global']);clock=('member',root,facts['clock_offset'])
    entries=set(facts['cases'].values());result=[];values=initial_values(facts,analysis.image)
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']]
        scoped=Analysis(analysis.image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=entries-{entry})
        @lru_cache(None)
        def reach(start):
            pending=[start];seen=set()
            while pending:
                pc=pending.pop()
                if pc in seen:continue
                seen.add(pc);pending.extend(scoped.edges.get(pc,()))
            return frozenset(seen)
        for camera in facts['cameras']:
            site=camera['site']
            if site not in scoped.records:continue
            conditions=[]
            for pc,event in scoped.events('branch'):
                yes,no=event[-2:];on_yes=site in reach(yes);on_no=site in reach(no)
                if on_yes==on_no or site not in reach(pc):continue
                if event[1] not in (4,5):continue
                a,b=event[2:4]
                if isinstance(a,int):a,b=b,a
                offset=field(a,root)
                if offset is None or not isinstance(b,int):continue
                equal=(event[1]==4)==on_yes
                conditions.append(dict(field=offset,value=b,equal=equal))
            at=None;clock_value=None
            equalities=[c['value'] for c in conditions if c['field']==facts['clock_offset'] and c['equal']]
            first_flags=[]
            for condition in conditions:
                if condition['field']==facts['clock_offset'] or ((1==condition['value'])!=condition['equal']) or ((0==condition['value'])==condition['equal']):continue
                flag=('member',root,condition['field'])
                if values.get(condition['field'])==1 and any(e[1]==flag and e[2]==0 and pc in reach(site) for pc,e in scoped.events('store')):first_flags.append(condition['field'])
            if phase['start'] is not None:
                if len(set(equalities))==1 and phase['clock_initial'] is not None:
                    clock_value=equalities[0]
                    # Only admit an entry-clock predicate before its first update.
                    if clock_value==phase['clock_initial']:at=phase['start']+1
                elif first_flags:at=phase['start']+1
            result.append(dict(**camera,phase=phase['index'],clock=clock_value,at=at,conditions=conditions,blocker=None if at is not None else 'camera_trigger_needs_scalar_or_object_progress'))
        values.update(exit_values(scoped,root,facts['phase_offset']))
    return result


def scalar_channels(facts,analysis,nested=None):
    """Lower source recurrences and dominating guards, not original instructions."""
    root=('global',facts['state_global']);initial=initial_values(facts,analysis.image)
    nested=nested or {}
    for spec in nested.values():initial[spec['key']]=spec['initial']
    def key(value):
        direct=field(value,root)
        return direct if direct is not None else nested[value]['key'] if value in nested else None
    offsets={k for k,v in initial.items() if isinstance(v,int)}
    offsets.update((facts['clock_offset'],facts['phase_offset']))
    channels={k:dict(initial=initial[k],phases=[]) for k in offsets if k in initial and isinstance(initial[k],int) and k not in (facts['clock_offset'],facts['phase_offset'])}
    blocked={};dependencies={k:set() for k in channels}
    widths={spec['key']:{spec['bits']} for spec in nested.values()}
    def store_bits(image,pc,event):
        if len(event)>3:return event[3]
        word=image.word(pc)
        if word>>26 not in (40,41,43):word=image.word(pc+4)
        if word>>26 not in (40,41,43):raise ValueError('unresolved_store_width')
        return {40:8,41:16,43:32}[word>>26]
    owners=[root]
    for entry in [facts['initializer']]+facts['preparation']:
        init=Analysis(analysis.image,entry)
        owners.extend(e[2] for _,e in init.events('store') if e[1]==root)
        for pc,event in init.events('store'):
            for owner in owners:
                offset=field(event[1],owner)
                if offset is not None:widths.setdefault(offset,set()).add(store_bits(analysis.image,pc,event))
    entries=set(facts['cases'].values())
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']]
        scoped=Analysis(analysis.image,analysis.start,analysis.end,analysis.indirect,entry=entry,
                        initial=analysis.before[entry],barriers=entries-{entry},scalar_root=root,scalar_offsets=offsets,scalar_fields=nested)
        @lru_cache(None)
        def reach(start,avoid=None):
            seen=set();pending=[start]
            while pending:
                pc=pending.pop()
                if pc==avoid or pc in seen:continue
                seen.add(pc);pending.extend(scoped.edges.get(pc,()))
            return frozenset(seen)
        stores=[(pc,e) for pc,e in scoped.events('store') if key(e[1]) is not None]
        for pc,event in stores:widths.setdefault(key(event[1]),set()).add(store_bits(scoped.image,pc,event))
        def lower(value,visiting=frozenset()):
            if isinstance(value,int):return value
            if not isinstance(value,tuple):raise ValueError('unknown_source_value')
            offset=key(value)
            if offset is not None:
                if offset not in offsets:raise ValueError('uninitialized_or_pointer_field')
                return ('value',offset)
            if value[0]=='read':
                _,site,destination,op=value;offset=key(destination)
                if offset not in offsets:raise ValueError('uninitialized_or_pointer_field')
                writers=[(pc,e) for pc,e in stores if e[1]==destination and site in reach(pc) and pc!=site]
                if any(pc in visiting for pc,_ in writers):raise ValueError('cyclic_scalar_definition')
                dominating=[(pc,e) for pc,e in writers if site not in reach(entry,pc)]
                latest=[(pc,e) for pc,e in dominating if all(other==pc or pc in reach(other) for other,_ in writers)]
                if writers and len(latest)!=1:raise ValueError('conditional_memory_join')
                result=lower(latest[0][1][2],visiting|{latest[0][0]}) if latest else ('value',offset)
                return result if op==35 else ({32:'s8',33:'s16',36:'u8',37:'u16'}[op],result)
            if value[0] in ('add','sub','or','and','xor','shl','shr','sar','lt','ult'):
                return (value[0],lower(value[1],visiting),lower(value[2],visiting))
            raise ValueError('unsupported_source_expression')
        for offset,channel in channels.items():
            operations=[]
            for pc,event in stores:
                if key(event[1])!=offset:continue
                try:
                    if any(pc in reach(next_pc) for next_pc in scoped.edges.get(pc,())):raise ValueError('loop_carried_scalar')
                    guards=[]
                    for at,branch in scoped.events('branch'):
                        if at==pc or pc in reach(entry,at):continue
                        yes,no=branch[-2:];on_yes=pc in reach(yes);on_no=pc in reach(no)
                        if on_yes==on_no:continue
                        right=branch[3]
                        if branch[1]==1:
                            right=scoped.image.word(at)>>16&31
                            if right not in (0,1):raise ValueError('unsupported_regimm_guard')
                        guards.append((branch[1],lower(branch[2]),lower(right),on_yes))
                    value=lower(event[2]);width=store_bits(scoped.image,pc,event)
                    operations.append(dict(site=pc,value=value,guards=guards,bits=width))
                    for expression in [value]+[g[i] for g in guards for i in (1,2)]:
                        for term in leaves(expression):
                            if term and term[0]=='value':dependencies[offset].add(term[1])
                except ValueError as error:blocked.setdefault(offset,[]).append(dict(phase=phase['index'],site=pc,reason=str(error)))
            channel['phases'].append(operations)
    for offset in channels:
        sizes=widths.get(offset,{32})
        overlap=[other for other,bits in widths.items() if other!=offset and offset<other+max(bits)//8 and other<offset+max(sizes)//8]
        if len(sizes)>1 or overlap:blocked.setdefault(offset,[]).append(dict(reason='overlapping_scalar_storage',fields=sorted(set(overlap)|{offset})))
    changed=True
    while changed:
        changed=False
        for offset,requires in dependencies.items():
            missing=requires-set(channels)-{facts['clock_offset'],facts['phase_offset']}
            invalid=requires&set(blocked)
            if (missing or invalid) and offset not in blocked:
                blocked[offset]=[dict(reason='unresolved_scalar_dependency',fields=sorted(missing|invalid))];changed=True
    clocks=phase_clocks(facts,analysis);phases=[]
    for phase,clock in zip(facts['phases'],clocks):
        deltas={value for _,value in clock['deltas']}
        phases.append(dict(**phase,clock_delta=next(iter(deltas)) if len(deltas)==1 else 0 if not deltas else None))
    return dict(initial=initial,clock=facts['clock_offset'],phase=facts['phase_offset'],
                timeline=phases,channels={k:v for k,v in channels.items() if k not in blocked},blocked=blocked)


def scalar_value(expression,values):
    if isinstance(expression,int):return expression
    kind=expression[0]
    if kind=='value':return values[expression[1]]
    if kind in ('s8','s16','u8','u16'):
        bits=int(kind[1:]);value=scalar_value(expression[1],values)&((1<<bits)-1)
        return value-(1<<bits) if kind[0]=='s' and value&(1<<(bits-1)) else value
    return operation(kind,scalar_value(expression[1],values),scalar_value(expression[2],values))


def scalar_guard(guard,values):
    op,left,right,wanted=guard;a=scalar_value(left,values);b=scalar_value(right,values)
    # REGIMM's rt selects signed less-than-zero / greater-or-equal-to-zero.
    if op==1:result=a>=0 if b else a<0
    elif op==4:result=a==b
    elif op==5:result=a!=b
    elif op==6:result=a<=0
    elif op==7:result=a>0
    else:raise ValueError('unsupported_scalar_guard')
    return result==wanted


def sample_scalar_channels(plan,duration=None,fields=None):
    """Evaluate exported scalar equations, without registers, memory or instruction PCs."""
    channels=plan['channels']
    if fields is not None:
        required=set(fields);pending=list(required)
        while pending:
            key=pending.pop()
            if key not in channels:raise ValueError(f'unresolved scalar channel {key}')
            for actions in channels[key]['phases']:
                for action in actions:
                    for expression in [action['value']]+[g[i] for g in action['guards'] for i in (1,2)]:
                        for term in leaves(expression):
                            if term[0]=='value' and term[1] not in required and term[1] not in (plan['clock'],plan['phase']):
                                required.add(term[1]);pending.append(term[1])
        channels={k:channels[k] for k in required}
    values={k:v['initial'] for k,v in channels.items()}
    samples={k:[v] for k,v in values.items()}
    elapsed=0
    for phase in plan['timeline']:
        count=phase['updates']
        if count is None:
            if duration is None:break
            remaining=range(phase['index'],len(plan['timeline']))
            if any(any(channel['phases'][i] for i in remaining) for channel in channels.values()):break
            count=duration-elapsed
        if phase['clock_initial'] is None or phase['clock_delta'] is None:break
        deltas=phase['clock_delta']
        if duration is not None:count=min(count,duration-elapsed)
        for age in range(count):
            before=dict(values);before[plan['clock']]=phase['clock_initial']+deltas*age;before[plan['phase']]=phase['index']
            for offset,channel in channels.items():
                for action in channel['phases'][phase['index']]:
                    if all(scalar_guard(g,before) for g in action['guards']):
                        value=scalar_value(action['value'],before)
                        values[offset]=signed(value) if action['bits']==32 else value&((1<<action['bits'])-1)
            for offset,value in values.items():samples[offset].append(value)
            elapsed+=1
        if duration is not None and elapsed>=duration:break
    return samples


def caster_tint_binding(facts,analysis):
    root=('global',facts['state_global']);candidates={}
    for pc,event in analysis.events('store'):
        destination,value=event[1:3]
        if not isinstance(destination,tuple) or len(destination)!=3 or destination[0]!='member' or destination[2] not in (70,71,72):continue
        slot=field(destination[1],root)
        if slot is None or not isinstance(value,tuple) or len(value)!=3 or value[0] not in ('shr','sar') or value[2]!=12:continue
        offset=field(value[1],root)
        if offset is None:continue
        candidates.setdefault((slot,offset),{})[destination[2]]=pc
    owners=[root];constructors=[]
    for entry in [facts['initializer']]+facts['preparation']:
        init=Analysis(analysis.image,entry)
        owners.extend(e[2] for _,e in init.events('store') if e[1]==root)
        for pc,event in init.events('call'):
            if event[1]!=0x801233b4 or event[2][1]!=0:continue
            handle=('call',event[1],pc)
            for _,store in init.events('store'):
                if store[2]!=handle:continue
                for owner in owners:
                    slot=field(store[1],owner)
                    if slot is not None:constructors.append((slot,pc))
    bindings=[dict(slot=slot,field=offset,constructor=pc,stores=sites) for (slot,offset),sites in candidates.items() if set(sites)=={70,71,72} for key,pc in constructors if key==slot]
    if len(bindings)!=1:return None
    return bindings[0]


def sprite_scale_binding(facts,analysis):
    root=('global',facts['state_global']);bindings={}
    vectors=[]
    for pc,event in analysis.events('call'):
        if event[1]==0x801207b4:
            fields=[field(v,root) for v in event[2][:3]]
            if all(v is not None for v in fields):vectors.append(dict(fields=fields,stores=[pc]))
    for pc,event in analysis.events('store'):
        destination,value=event[1:3]
        word=analysis.image.word(pc);site=pc
        if word>>26 not in (40,41,43):word=analysis.image.word(pc+4);site=pc+4
        if word>>26!=43 or sx16(word) not in (52,56,60):continue
        if destination is None:
            consumers=[at for at,e in analysis.events('call') if e[1]==0x801238e0 and 0<=at+4-site<=32]
            if not consumers:continue
            base=('matrix_input',consumers[0],word>>21&31)
        else:base=destination[1]
        if not isinstance(value,tuple) or len(value)!=3 or value[0] not in ('shr','sar') or value[2]!=12:continue
        offset=field(value[1],root)
        if offset is None:continue
        bindings.setdefault(base,{})[sx16(word)]=(offset,pc)
    choices=[dict(fields=[rows[axis][0] if axis in rows else None for axis in (52,56,60)],stores=[rows[axis][1] for axis in (52,56,60) if axis in rows]) for rows in bindings.values() if 52 in rows and 56 in rows]
    choices+=vectors
    choices=list({tuple(c['fields']):c for c in choices}.values())
    return choices[0] if len(choices)==1 else None


@lru_cache(None)
def scalar_profile(initializer):
    facts,analysis=analyze(initializer);facts['phases']=timeline(facts,analysis)
    return scalar_channels(facts,analysis),caster_tint_binding(facts,analysis)


def batch_scalar_catalogue():
    base=catalogue();spells=[]
    for spell in base['spells']:
        plan,binding=scalar_profile(spell['initializer'])
        facts,analysis=analyze(spell['initializer'])
        samples=sample_scalar_channels(plan)
        spells.append(dict(id=spell['id'],name=spell['name'],channels=plan['channels'],blocked=plan['blocked'],
                           caster_tint=binding,sprite_scale=sprite_scale_binding(facts,analysis),sampled_updates=max((len(v)-1 for v in samples.values()),default=0),
                           phases=plan['timeline']))
    return dict(schema='suikoden-spell-scalar-compiler/1',source=base['source'],
                method='Static recurrence/guard lowering and source-order reaching definitions; scalar equation sampling only.',
                coverage=dict(spells=len(spells),channels=sum(len(s['channels']) for s in spells),
                              blocked_channels=sum(len(s['blocked']) for s in spells),
                              caster_tints=sum(s['caster_tint'] is not None and s['caster_tint']['field'] in s['channels'] for s in spells)),spells=spells)


def catalogue():
    import spell_effect_sweep
    import spell_rules
    _,rules=spell_rules.build();by_name={row['name']:row for row in rules['spells']}
    spells=[]
    for name,initializer in spell_effect_sweep.initializers():
        rule=by_name[name]
        if int(rule['initializer'],16)!=initializer:raise ValueError(f'{name} initializer disagrees with descriptor producer')
        facts,analysis=analyze(initializer);facts['phases']=timeline(facts,analysis)
        facts['camera_schedule']=camera_schedule(facts,analysis)
        spells.append(dict(id=rule['id'],name=name,**facts))
    spells.sort(key=lambda spell:int(spell['id'].split('_')[1]))
    if len(spells)!=33:raise ValueError('incomplete named spell catalogue')
    return dict(schema='suikoden-spell-callback-analysis/1',method='Static control-flow joins, phase-clock recurrence and constant call operands; no original instruction execution.',
                source=dict(file='MAIN.EXE',lba=maindec.EXE_LBA,size=maindec.EXE_SIZE,image_base=maindec.MBASE,image_sha256=__import__('hashlib').sha256(maindec.body()).hexdigest()),
                coverage=dict(spells=33,scalar_timelines=sum(all(p['updates'] is not None for p in s['phases']) for s in spells),camera_operands=sum(len(s['cameras']) for s in spells),scheduled_cameras=sum(e['at'] is not None for s in spells for e in s['camera_schedule'])),
                spells=spells)

def dominated_constant(analysis,destination,before):
    def walk(start,avoid=None):
        queue=[start];seen=set()
        while queue:
            pc=queue.pop()
            if pc in seen or pc==avoid:continue
            seen.add(pc);queue.extend(analysis.edges.get(pc,()))
        return seen
    stores=[(pc,e[2]) for pc,e in analysis.events('store') if e[1]==destination and before in walk(pc)]
    candidates=[(pc,v) for pc,v in stores if isinstance(v,int) and before not in walk(analysis.entry,avoid=pc)]
    for pc,value in reversed(candidates):
        if not any(other!=pc and other in walk(pc) and before in walk(other) and v!=value for other,v in stores):return value
    raise ValueError('unresolved constructor constant')


def stack_constant(analysis,site,offset):
    return dominated_constant(analysis,member(analysis.before[site][29],offset),site)


def orbit_random_parameters(image,init,ctor):
    random_fields={}
    for pc in sorted(init.before):
        shift=image.word(pc);left=image.word(pc+4);subtract=image.word(pc+8)
        if shift>>26 or shift&63!=3 or left>>26 or left&63!=0 or subtract>>26 or subtract&63!=35:continue
        register=shift>>11&31;bits=shift>>6&31
        if (left>>11&31,left>>16&31,left>>6&31,subtract>>11&31,subtract>>16&31)!=(register,register,bits,register,register):continue
        value=image.word(pc+12);bias=0;store_pc=pc+12
        if value>>26==9 and value>>21&31==register and value>>16&31==register:
            bias=sx16(value);store_pc+=4
        store=image.word(store_pc)
        if store>>16&31!=register:continue
        destination=member(init.before[store_pc][store>>21&31],sx16(store))
        if store>>26==43 and destination==member(init.before[store_pc][29],20):random_fields['size']=(1<<bits,bias)
        if store>>26==41 and destination==('member',('call',0x801233b4,ctor),68):random_fields['angle']=(1<<bits,bias)
    if set(random_fields)!={'size','angle'}:raise ValueError('unresolved orbit random fields')
    divisors=set()
    for pc,state in init.before.items():
        w=image.word(pc)
        if w>>26==0 and w&63==26:
            divisor=state[w>>16&31]
            if isinstance(divisor,int) and 1<divisor<512:divisors.add(divisor)
    if len(divisors)!=1:raise ValueError('unresolved orbit height range')
    return random_fields,next(iter(divisors))


def healing_orbit_profile(effect):
    """Shared fan/column/looping-orbit grammar, selected by source helper calls."""
    image=Image();initializer=int(effect['initializer'],16);init=Analysis(image,initializer)
    calls=init.events('call');graphics=[(pc,e) for pc,e in calls if e[1]==0x801233b4]
    fan=[(pc,e) for pc,e in calls if e[1]==0x8011d548];column=[(pc,e) for pc,e in calls if e[1]==0x801208a0]
    animations=[e[2][1] for _,e in graphics]
    if len(fan)!=1 or len(column)!=1 or animations not in ([0,3],[0,8,3]):return None
    rainfall=animations==[0,8,3]
    facts,analysis=analyze(initializer);facts['phases']=timeline(facts,analysis)
    if len(facts['phases'])!=(6 if rainfall else 5) or any(p['updates'] is None for p in facts['phases']):raise ValueError('unresolved orbit phase timeline')
    root=('global',facts['state_global']);ctor=graphics[-1][0];count=None;per_party=False
    from spell_scene_objects import constructors
    def count_for(party):
        result=constructors(facts,image,party)
        if result['blocked']:raise ValueError('unresolved orbit constructor loop')
        return sum(row['site']==ctor for row in result['objects'])
    count=count_for(1);second=count_for(2)
    per_party=second==2*count
    if count<=0 or not (second==count or per_party):raise ValueError('unresolved orbit multiplicity')
    random_fields,height_range=orbit_random_parameters(image,init,ctor)
    transforms=[e[2][:3] for _,e in analysis.events('call') if e[1]==0x801207b4 and all(field(v,root) is not None for v in e[2][:3])]
    if len(set(transforms))!=1:raise ValueError('unresolved orbit transform')
    scale=transforms[0]
    owners=[e[2] for _,e in init.events('store') if e[1]==root]
    wash_calls=[pc for pc,e in calls if e[1]==0x8011cf4c and e[2][0] in (1,2)]
    if len(wash_calls)!=1:raise ValueError('unresolved healing wash')
    wash_offset=[field(e[1],owner) for _,e in init.events('store') for owner in owners if e[2]==('call',0x8011cf4c,wash_calls[0]) and field(e[1],owner) is not None]
    if len(wash_offset)!=1:raise ValueError('unresolved wash owner')
    wash=('member',root,wash_offset[0]);channels=[('member',wash,offset) for offset in (72,76,80)]
    entries=set(facts['cases'].values());deltas=[];heals=[]
    caster=('member',('member',('member',root,0),24),20)
    # The column owner is the initializer's stored helper result.
    column_owner=next(field(e[1],owner) for _,e in init.events('store') for owner in owners if e[2]==('call',0x801208a0,column[0][0]) and field(e[1],owner) is not None)
    height=('member',('member',root,column_owner),44)
    def delta(scoped,destination,aliases=()):
        sources=aliases if destination in aliases else (destination,)
        values={e[2][2] for _,e in scoped.events('store') if e[1]==destination and isinstance(e[2],tuple) and len(e[2])==3 and e[2][0]=='add' and e[2][1] in sources and isinstance(e[2][2],int)}
        if len(values)>1:raise ValueError('conditional orbit recurrence')
        return next(iter(values),0)
    for phase in facts['phases']:
        entry=facts['cases'][phase['index']];scoped=Analysis(image,analysis.start,analysis.end,analysis.indirect,entry=entry,initial=analysis.before[entry],barriers=entries-{entry})
        deltas.append(dict(scale=[delta(scoped,v,scale[:2]) for v in scale],caster_size=delta(scoped,caster),wash=[delta(scoped,v,channels) for v in channels],height=delta(scoped,height)))
        if any(e[1]==0x800e1654 for _,e in scoped.events('call')):heals.append(phase['index'])
    if len(heals)!=1:raise ValueError('unresolved healing impact phase')
    angle=[]
    for pc in range(analysis.start,analysis.end,4):
        w=image.word(pc)
        if w>>26!=41 or w&65535!=68:continue
        rt=w>>16&31;base=w>>21&31
        for prior_pc in range(pc-4,max(pc-28,analysis.start)-1,-4):
            prior=image.word(prior_pc)
            if prior>>26==9 and prior>>16&31==rt and prior>>21&31==rt:
                visible=False
                for at in range(max(analysis.start,pc-128),pc-8,4):
                    load=image.word(at);branch=image.word(at+8)
                    if load>>26==35 and load>>21&31==base and load&65535==28 and branch>>26==4 and branch>>21&31==load>>16&31 and branch>>16&31==0 and at+12+(sx16(branch)<<2)>pc:visible=True
                angle.append((sx16(prior),visible));break
    if len(angle)!=1:raise ValueError('unresolved orbit rotation recurrence')
    fan_pc,fan_call=fan[0];shape=[(pc,e) for pc,e in calls if e[1]==0x80120888]
    if len(shape)!=1 or not isinstance(shape[0][1][2][1],int) or shape[0][1][2][2]!=fan_call[2][2]:raise ValueError('unresolved column dimensions')
    initial=initial_values(facts,image)
    if initial[field(scale[0],root)]!=initial[field(scale[1],root)] or any(p['scale'][0]!=p['scale'][1] for p in deltas):raise ValueError('orbit axes are not an equal-scale recurrence')
    local_x=next(e[2] for _,e in init.events('store') if e[1]==('member',('call',0x801233b4,ctor),0) and isinstance(e[2],int))
    wash_mode=next(e[2][0] for pc,e in calls if pc==wash_calls[0])
    return dict(rainfall=rainfall,top_radius=shape[0][1][2][1],visible_phase=3 if rainfall else 2,wash_blend={1:'additive',2:'subtractive'}[wash_mode],local_x=local_x,facts=facts,count=count,per_party=per_party,random_fields=random_fields,height_range=height_range,rotation=angle[0][0],rotate_when_visible=angle[0][1],
                phases=deltas,scalar_scale_fields=[field(v,root) for v in scale],
                caster_size=stack_constant(init,graphics[0][0],20),radius=fan_call[2][2],segments=fan_call[2][0],depth=fan_call[2][3],
                fan_inner=[stack_constant(init,fan_pc,i) for i in (32,36,40)],fan_outer=[stack_constant(init,fan_pc,i) for i in (44,48,52)],
                column_inner=[stack_constant(init,column[0][0],i) for i in (28,32,36)],column_outer=[stack_constant(init,column[0][0],i) for i in (40,44,48)],column_height=shape[0][1][2][3],impact_phase=heals[0])


if __name__=='__main__':
    import argparse,json
    from pathlib import Path
    root=Path(__file__).resolve().parents[2]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=root/'kit/data/reports/spell_choreography.json')
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--scalars',action='store_true',help='compile guarded scalar channels for the entire spell catalogue')
    args=parser.parse_args()
    if args.scalars and args.out==root/'kit/data/reports/spell_choreography.json':args.out=root/'kit/data/reports/spell_scalar_programs.json'
    value=batch_scalar_catalogue() if args.scalars else catalogue();encoded=json.dumps(value,indent=2)+'\n'
    if args.check:
        if args.out.read_text()!=encoded:raise SystemExit('stale spell callback analysis')
    else:
        accepted=(root/'kit/work/accepted').resolve()
        if accepted in (args.out.resolve(),*args.out.resolve().parents):raise ValueError('analysis cannot promote accepted content')
        args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(encoded)
    print(value['coverage'])
