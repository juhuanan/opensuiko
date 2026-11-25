"""Static shared column constructors; lifecycle readiness is a separate gate."""
from functools import lru_cache
import spell_scene_source as source
import spell_scene_objects as objects
from spell_scene_support import _slot

CONSTRUCTOR=0x801208a0
SETTER=0x80120888
VERSION='spell-column-compiler/1'
FIELDS={0:'enabled',60:'angle_x',62:'angle_y',64:'angle_z',72:'scale_x',76:'scale_y',80:'scale_z'}


def constructors(facts,image=None):
    image=image or source.Image();root=facts.get('state_root') or ('global',facts['state_global'])
    decoded=objects.constructors(facts,image,constructor=CONSTRUCTOR,setters=(SETTER,))
    if not decoded['objects']:return dict(columns=[],blocked=decoded['blocked'])
    for pc,word in {0x8012088C:0xAC850028,0x80120890:0xAC860030,0x80120894:0xAC87002C,0x8012089C:0xAC820034,
                    0x80120A84:0xAEE00000,0x80120AB4:0xA440003C,0x80120AB8:0xA440003E,0x80120ABC:0xA4400040,
                    0x80120AC0:0xAC430048,0x80120AC4:0xAC43004C,0x80120AC8:0xAC430050}.items():
        if image.word(pc)!=word:raise ValueError(f'column constructor source changed at {pc:#x}')
    init=source.Analysis(image,facts['initializer'],cut_backedges=True)
    owners=[root]+[e[2] for _,e in init.events('store') if e[1]==root]
    rows=[];blocked=list(decoded['blocked'])
    for row in decoded['objects']:
        slot=row['slot'];setters=[]
        for setter in row['setters']:
            try:target=slot if setter['arguments'][0]==('call',CONSTRUCTOR,row['site']) else _slot(init,root,setter['arguments'][0])
            except ValueError:continue
            if slot is not None and target==slot:setters.append(setter)
        if len(setters)==1:
            shape=setters[0]['arguments'];setter_site=setters[0]['site']
        elif not setters and all(isinstance(row['initial'].get(offset),int) for offset in (40,44,48,52)):
            shape=[None]+[row['initial'][offset] for offset in (40,48,44,52)];setter_site=None
        else:
            blocked.append(dict(site=row['site'],instance=row['instance'],reason='unresolved_column_endpoints'));continue
        args=row['arguments'];stack=row['stack']
        values={0:0,60:0,62:0,64:0,72:4096,76:4096,80:4096}
        values.update({offset:value for offset,value in row['initial'].items() if offset in FIELDS})
        # Explicit stores after allocation use the source state slot, including post-loop stores.
        for pc,e in init.events('store'):
            dest=e[1]
            if pc<=row['site'] or not isinstance(dest,tuple) or len(dest)!=3 or dest[0]!='member':continue
            if dest[2] in FIELDS and any(source.field(dest[1],owner)==slot for owner in owners):values[dest[2]]=e[2]
        colors=[[stack[n] for n in group] for group in ((28,32,36),(40,44,48))]
        parameters=[args[0],args[1],args[2]]+shape[1:]+list(values.values())+sum(colors,[])
        if slot is None or not all(isinstance(v,int) for v in parameters):
            blocked.append(dict(site=row['site'],instance=row['instance'],reason='dynamic_column_parameters'));continue
        rows.append(dict(site=row['site'],setter=setter_site,instance=row['instance'],slot=slot,segments=args[0],semitransparent=bool(args[1]),blend={1:'additive',2:'subtractive'}.get(args[2],'unsupported'),
                         lower=dict(radius=shape[1],height=shape[3],color=[v&255 for v in colors[0]]),upper=dict(radius=shape[2],height=shape[4],color=[v&255 for v in colors[1]]),
                         enabled=bool(values[0]),angles=[values[n] for n in (60,62,64)],scale=[values[n] for n in (72,76,80)],
                         translation_source=[args[3],stack[16],stack[20]]))
    return dict(columns=rows,blocked=blocked)


PARAMETERS={0:('enabled',32),40:('lower_radius',32),44:('lower_height',32),48:('upper_radius',32),52:('upper_height',32),
            60:('angle_x',16),62:('angle_y',16),64:('angle_z',16),72:('scale_x',32),76:('scale_y',32),80:('scale_z',32)}


def motion(facts,image=None):
    """Compile column parameters; actor translation and other scene paths are separate."""
    image=image or source.Image();facts,analysis=source.analyze(facts['initializer'],image)
    facts['phases']=source.timeline(facts,analysis);decoded=constructors(facts,image)
    root=('global',facts['state_global']);nested={};bindings=[]
    for index,column in enumerate(decoded['columns']):
        values={0:int(column['enabled']),40:column['lower']['radius'],44:column['lower']['height'],48:column['upper']['radius'],52:column['upper']['height']}
        values.update(dict(zip((60,62,64),column['angles'])));values.update(dict(zip((72,76,80),column['scale'])))
        owner=source.member(root,column['slot']);fields={}
        for offset,(name,bits) in PARAMETERS.items():
            key=65536+256*index+offset;fields[name]=key
            nested[source.member(owner,offset)]=dict(key=key,initial=values[offset],bits=bits)
        bindings.append(dict(column=column,fields=fields))
    plan=source.scalar_channels(facts,analysis,nested)
    # Unknown loop bases can hide a writer; do not turn an absent recognized store into a constant.
    for pc,event in analysis.events('store'):
        word=image.word(pc)
        if word>>26 not in (40,41,43):word=image.word(pc+4)
        if event[1] is None and source.sx16(word) in PARAMETERS:
            offset=source.sx16(word);bits={40:8,41:16,43:32}.get(word>>26)
            if bits!=PARAMETERS[offset][1]:continue
            for binding in bindings:
                key=binding['fields'][PARAMETERS[offset][0]]
                plan['blocked'].setdefault(key,[]).append(dict(site=pc,reason='unbound_column_writer'))
                plan['channels'].pop(key,None)
    for _,event in analysis.events('call'):
        for binding in bindings:
            owner=source.member(root,binding['column']['slot'])
            if not any(owner in source.leaves(arg) for arg in event[2]) or event[1]==0x80120b58:continue
            if event[1]==0x801207b4 and all(source.member(event[2][3],4*i) in nested for i in range(3)):continue
            for key in binding['fields'].values():
                plan['blocked'].setdefault(key,[]).append(dict(reason='unlowered_column_helper',target=event[1]));plan['channels'].pop(key,None)
    # A newly rejected writer also invalidates fields whose equations consume it.
    changed=True
    while changed:
        changed=False
        for key,channel in list(plan['channels'].items()):
            dependencies={term[1] for actions in channel['phases'] for action in actions for expr in [action['value']]+[g[i] for g in action['guards'] for i in (1,2)] for term in source.leaves(expr) if term[0]=='value'}
            bad=dependencies&set(plan['blocked'])
            if bad:plan['blocked'][key]=[dict(reason='unresolved_scalar_dependency',fields=sorted(bad))];del plan['channels'][key];changed=True
    return dict(plan=plan,columns=bindings,blocked=decoded['blocked'])


@lru_cache(None)
def catalogue():
    base=source.catalogue();spells=[dict(id=p['id'],name=p['name'],**constructors(p)) for p in base['spells']]
    return dict(schema='suikoden-spell-column-constructors/1',producer=VERSION,source=base['source'],
                method='Bounded constructor induction, source setter operands and explicit initializer stores. Columns alone do not qualify scene lifecycles.',
                units=dict(radius='scene units',height='scene units',scale='Q12',angles='4096 units per turn',color='unsigned byte RGB'),
                coverage=dict(spells=33,column_spells=sum(bool(p['columns']) for p in spells),columns=sum(len(p['columns']) for p in spells),blocked_sites=sum(len(p['blocked']) for p in spells)),spells=spells)


@lru_cache(None)
def motion_catalogue():
    import hashlib,json
    base=source.catalogue();spells=[];available=blocked=complete=count=0
    for facts in base['spells']:
        if not constructors(facts)['columns']:
            spells.append(dict(id=facts['id'],name=facts['name'],columns=[],plan=None));continue
        result=motion(facts);plan=result['plan'];samples=source.sample_scalar_channels(plan)
        total=sum(p['updates'] for p in plan['timeline']) if all(p['updates'] is not None for p in plan['timeline']) else None
        rows=[]
        for binding in result['columns']:
            fields=binding['fields'];valid={name:key for name,key in fields.items() if key in plan['channels']}
            available+=len(valid);blocked+=len(fields)-len(valid);count+=1
            done=total is not None and len(valid)==len(fields) and all(len(samples[key])-1==total for key in valid.values());complete+=done
            rows.append(dict(slot=binding['column']['slot'],fields=fields,complete_parameters=done,
                             sampled_updates={name:len(samples[key])-1 for name,key in valid.items()},
                             sample_sha256={name:hashlib.sha256(json.dumps(samples[key],separators=(',',':')).encode()).hexdigest() for name,key in valid.items()}))
        spells.append(dict(id=facts['id'],name=facts['name'],columns=rows,plan=plan))
    return dict(schema='suikoden-spell-column-motion/1',producer='spell-column-motion/1',source=base['source'],
                method='Nested scalar recurrence/guard lowering with rejected unresolved writers and helpers. Translation, sprite lifecycles and scene qualification remain separate.',
                coverage=dict(spells=33,column_spells=sum(bool(p['columns']) for p in spells),columns=count,parameter_channels=available,blocked_parameters=blocked,complete_parameter_columns=complete),spells=spells)


if __name__=='__main__':
    import argparse,json
    from pathlib import Path
    root=Path(__file__).resolve().parents[2];parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path);parser.add_argument('--check',action='store_true');parser.add_argument('--motion',action='store_true')
    args=parser.parse_args()
    args.out=args.out or root/('kit/data/reports/spell_column_motion.json' if args.motion else 'kit/data/reports/spell_column_constructors.json')
    result=motion_catalogue() if args.motion else catalogue();encoded=json.dumps(result,indent=2)+'\n'
    if args.check:
        if args.out.read_text()!=encoded:raise SystemExit('stale spell column constructor report')
    else:
        accepted=(root/'kit/work/accepted').resolve()
        if accepted in (args.out.resolve(),*args.out.resolve().parents):raise ValueError('column analysis cannot promote accepted content')
        args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(encoded)
    print(result['coverage'])
