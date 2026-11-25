"""Static constructor-loop lowering for spell scene objects; no CPU execution."""
from functools import lru_cache

import spell_scene_source as source

GRAPHIC=0x801233b4


def destination(word):
    op=word>>26
    if op in (8,9,10,11,12,13,14,15,32,33,35,36,37):return word>>16&31
    if op==0 and word&63 not in (8,9,12,13,17,19,24,25,26,27,48):return word>>11&31
    return None


def difference(after,before):
    if after==before:return 0
    if isinstance(after,int) and isinstance(before,int):return after-before
    if isinstance(after,tuple) and len(after)==3 and after[:2]==('add',before) and isinstance(after[2],int):return after[2]
    return None


def bound_value(value,party_count):
    if isinstance(value,int):return value
    if value==('member',('global',0x8017be3c),28):return party_count
    if isinstance(value,tuple) and value[0] in ('add','sub','shl'):
        a=bound_value(value[1],party_count);b=bound_value(value[2],party_count)
        if a is not None and b is not None:return source.operation(value[0],a,b)
    return None


def counted_loop(first,branch,party_count):
    head=branch[4];tail=branch[5]-8
    if branch[1] not in (5,6) or not head<=tail:raise ValueError('unsupported_constructor_loop_guard')
    word=first.image.word(tail);left=word>>21&31;right=word>>16&31
    if branch[1]==6:
        observed=first.before[tail][left]
        step=difference(observed,first.before[head][left])
        if right!=0 or not isinstance(observed,int) or not 0<observed<1<<31 or step is None:
            raise ValueError('unsupported_constructor_loop_guard')
        return dict(head=head,tail=tail,count=1,counter=left,step=step)
    compare=None
    if right==0:
        for pc in range(tail-4,head-1,-4):
            candidate=first.image.word(pc)
            if destination(candidate)!=left:continue
            op=candidate>>26
            if op in (10,11):counter=candidate>>21&31;limit=source.sx16(candidate);compare=pc
            elif op==0 and candidate&63 in (42,43):
                counter=candidate>>21&31;limit=bound_value(first.before[pc][candidate>>16&31],party_count);compare=pc
            break
    else:
        possible=[]
        for counter,other in ((left,right),(right,left)):
            step=difference(first.after[tail][counter],first.before[head][counter])
            if isinstance(step,int) and step>0:possible.append((counter,first.before[tail][other]))
        if len(possible)==1:counter,limit=possible[0];compare=tail
    if compare is None:raise ValueError('unresolved_constructor_loop_counter')
    initial=first.before[head][counter];observed=first.before[compare][counter]
    step=difference(first.after[tail][counter],initial)
    if not all(isinstance(v,int) for v in (initial,observed,step,limit)) or step<=0:raise ValueError('unresolved_constructor_loop_bound')
    if compare==tail and (limit-observed)%step:raise ValueError('nonterminating_constructor_counter')
    count=(limit-observed+step-1)//step+1
    if not 1<=count<=128:raise ValueError('unsafe_constructor_loop_count')
    return dict(head=head,tail=tail,count=count,counter=counter,step=step)


def written_registers(image,head,tail):
    return {register for pc in range(head,tail+8,4) if (register:=destination(image.word(pc))) is not None}


def field_path(value,root):
    if value==root:return []
    if isinstance(value,tuple) and len(value)==3 and value[0]=='member':
        parent=field_path(value[1],root)
        if parent is not None and isinstance(value[2],int):return parent+[value[2]]
    return None


def specializations(first,enclosing,entry,party_count):
    """Specialize bounded induction variables, retaining unknown non-affine values."""
    branches=sorted(enclosing,key=lambda item:item[1][4])
    if len(branches)>4:raise ValueError('unsafe_constructor_loop_depth')
    for (_,outer),(_,inner) in zip(branches,branches[1:]):
        if not outer[4]<inner[4] or inner[5]>outer[5]:raise ValueError('overlapping_constructor_loops')
    states=[(first,[],[],[first])]
    for depth,(_,branch) in enumerate(branches):
        expanded=[]
        for parent,loops,indices,contexts in states:
            loop=counted_loop(parent,branch,party_count)
            nested_writes=set().union(*(written_registers(first.image,e[4],e[5]-8) for _,e in branches[depth+1:]))
            if loop['counter'] in nested_writes:raise ValueError('constructor_counter_modified_by_nested_loop')
            written=written_registers(first.image,loop['head'],loop['tail'])
            for index in range(loop['count']):
                registers=list(parent.before[loop['head']])
                for register in written:
                    step=difference(parent.after[loop['tail']][register],registers[register])
                    # A single inner pass cannot summarize an outer-carried value.
                    if index and register in nested_writes:registers[register]=None
                    elif step is not None and step!=0:registers[register]=source.operation('add',registers[register],step*index)
                    elif index and step is None:registers[register]=None
                registers[0]=0
                scoped=source.Analysis(first.image,entry,end=loop['tail']+8,entry=loop['head'],initial=tuple(registers),cut_backedges=True)
                expanded.append((scoped,loops+[loop],indices+[index],contexts+[scoped]))
                if len(expanded)>128:raise ValueError('unsafe_constructor_instance_count')
        states=expanded
    return states


def constructors(facts,image=None,party_count=6, constructor=GRAPHIC, setters=()):
    if not 1<=party_count<=6:raise ValueError('invalid spell party size')
    image=image or source.Image();root=facts.get('state_root') or ('global',facts['state_global']);rows=[];blocked=[]
    for entry in [facts['initializer']]+facts['preparation']:
        full=source.Analysis(image,entry);first=source.Analysis(image,entry,cut_backedges=True)
        owners=[root]+[event[2] for _,event in first.events('store') if event[1]==root]
        backedges=[(pc,event) for pc,event in full.events('branch') if event[4]<=pc]
        for site,event in first.events('call'):
            if event[1]!=constructor:continue
            enclosing=[(pc,e) for pc,e in backedges if e[4]<=site<=pc]
            try:instances=specializations(first,enclosing,entry,party_count)
            except ValueError as error:
                blocked.append(dict(site=site,reason=str(error)));continue
            for index,(scoped,loops,indices,contexts) in enumerate(instances):
                loop=loops[-1] if loops else None
                call=next((e for pc,e in scoped.events('call') if pc==site),None)
                if call is None:
                    blocked.append(dict(site=site,reason='unreachable_specialized_constructor'));break
                handle=('call',constructor,site)
                slots={source.field(e[1],owner) for _,e in scoped.events('store') for owner in owners if e[2]==handle and source.field(e[1],owner) is not None}
                def stack(offset):
                    for context in reversed(contexts):
                        try:return source.stack_constant(context,site,offset)
                        except ValueError:
                            target=source.member(context.before[site][29],offset)
                            if any(e[1]==target for _,e in context.events('store')):return None
                    return None
                initial={}
                for pc,e in scoped.events('store'):
                    offset=source.field(e[1],handle)
                    if offset is not None:initial[offset]=e[2]
                row=dict(site=site,instance=index,animation=call[2][1],delay=call[2][2],looping=call[2][3],
                                 enabled=stack(16),size=stack(20),slot=next(iter(slots)) if len(slots)==1 else None,
                                 initial=initial,loop=loop)
                if len(loops)>1 or ('state_root' in facts and row['slot'] is None):
                    paths={tuple(path) for _,e in scoped.events('store') if e[2]==handle for owner in owners if (path:=field_path(e[1],owner)) is not None}
                    row['slot_path']=list(next(iter(paths))) if len(paths)==1 else None
                if len(loops)>1:
                    node=source.member(handle,24)
                    row.update(loops=loops,indices=indices,
                               node_initial={source.field(e[1],node):e[2] for _,e in scoped.events('store') if source.field(e[1],node) is not None})
                if constructor!=GRAPHIC:
                    row.update(arguments=list(call[2]),stack={n:stack(n) for n in range(16,52,4)})
                    row['setters']=[]
                    for at,event in scoped.events('call'):
                        if at<=site or event[1] not in setters:continue
                        try:arguments=list(event[2])+[source.stack_constant(scoped,at,16)]
                        except ValueError:arguments=list(event[2])+[None]
                        row['setters'].append(dict(site=at,arguments=arguments))
                rows.append(row)
        missing={pc for pc,e in full.events('call') if e[1]==constructor}-{pc for pc,e in first.events('call') if e[1]==constructor}
        blocked.extend(dict(site=pc,reason='constructor_not_reached_in_acyclic_analysis') for pc in sorted(missing))
    return dict(objects=rows,blocked=blocked)


@lru_cache(None)
def catalogue():
    spells=[];base=source.catalogue()
    for spell in base['spells']:
        result=constructors(spell)
        spells.append(dict(id=spell['id'],name=spell['name'],**result))
    return dict(schema='suikoden-spell-object-constructors/2',source=base['source'],party_count=6,
                method='Static bounded-loop induction specialization and constructor operands; no original instruction execution.',
                coverage=dict(spells=len(spells),objects=sum(len(s['objects']) for s in spells),blocked_sites=sum(len(s['blocked']) for s in spells),
                              unbound_slots=sum(o['slot'] is None and not o.get('slot_path') for s in spells for o in s['objects']),
                              dynamic_parameters=sum(any(o[k] is None for k in ('animation','delay','looping','enabled','size')) for s in spells for o in s['objects'])),spells=spells)


if __name__=='__main__':
    import argparse,json
    from pathlib import Path
    root=Path(__file__).resolve().parents[2]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=root/'kit/data/reports/spell_object_constructors.json')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args();result=catalogue();encoded=json.dumps(result,indent=2)+'\n'
    if args.check:
        if args.out.read_text()!=encoded:raise SystemExit('stale spell object constructor report')
    else:
        accepted=(root/'kit/work/accepted').resolve()
        if accepted in (args.out.resolve(),*args.out.resolve().parents):raise ValueError('constructor analysis cannot promote accepted content')
        args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(encoded)
    print(result['coverage'])
