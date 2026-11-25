"""Static Dagon half-damage/poison special over shared actor and spin consumers."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera
from export_first_room import ROOT, source
from export_physical_runes import merge_libraries, stream
from export_unite_programs import animation_resource, compile_operations, program_schema

BASE = 0x80080000
BLOCKS = (
    (0x188,0x254,'f7f80cc0ceb9953403288b8e432fd026e41d5761d4ba85717cafbc018751eaa4'),
    (0x254,0x338,'a68f8d9a88ba843aa876e649d20dfe9595260172f8e5fc54cb908821324e0762'),
    (0x338,0x530,'55ac3c13c7e5c4cea2596aa22c8664293524dde9a09eda8f2239e77bcc52e22f'),
    (0x530,0x5ac,'80381c9f41058f267d91470e7f73b923bf58dbfe5df1521537c143de2322627a'),
)


def build():
    raw,origin=source('/G_DATA.BIN')
    pointer=lambda off:struct.unpack_from('<I',raw,off)[0]-BASE
    directory=pointer(pointer(pointer(0)+12));record=pointer(pointer(directory+12)+4)
    table,section=pointer(record+40),pointer(record+44)
    if (record,table,section,pointer(record+48),pointer(table+20),struct.unpack_from('<H',raw,record+38)[0])!=(0x1e420,0x1e460,0x1e91c,0x338,0x530,5):
        raise ValueError('Dagon record, decision or spin dispatch changed')
    callbacks=[]
    for first,last,digest in BLOCKS:
        if hashlib.sha256(raw[first:last]).hexdigest()!=digest:raise ValueError('Dagon source callback changed')
        callbacks.append(dict(source=origin,source_offset=first,byte_length=last-first,sha256=digest))
    values=struct.unpack_from('<12i',raw,0x1e60c)
    if hashlib.sha256(raw[0x1e60c:0x1e63c]).hexdigest()!='a2e48a0a8b338fe79db0de7cf884d86b61803f8699f851eb2df7471d7ba83c2c':
        raise ValueError('Dagon return camera changed')
    camera=dict(updates=struct.unpack_from('<I',raw,0x1f4)[0]&65535,
                target={key:list(values[i*3:i*3+3]) for i,key in enumerate(('position','angles','c','d'))})
    ordinary=dict(id='dagon');special=dict(id='dagon');dodge=dict(id='dagon')
    programs=[];proofs=[];roots=[];selected={0,1,3}
    for binding,role,offset in (
        (ordinary,'attack',pointer(table+4)),(ordinary,'hurt',pointer(table+8)),
        (ordinary,'return',pointer(table+16)),(dodge,'response',pointer(table+12)),
        (special,'owner',0x1e548),(special,'recipient',0x1e63c),
    ):
        operations,spans=stream(raw,origin,offset,table,BASE)
        instructions,blocked,effects=compile_operations(operations,'melee/dagon',{(2,5):'recipient_spin'},member_resource='dagon')
        if blocked or set(effects)-{'recipient_spin'}:raise ValueError('Unbound Dagon actor: '+role)
        family='ordinary' if binding is ordinary else 'special' if binding is special else 'dodge'
        identifier='melee/dagon/'+family+'/'+role;binding[role+'_program']=identifier
        programs.append(dict(id=identifier,instructions=instructions));proofs.append(dict(id=identifier,operations=operations,spans=spans))
        roots.append(dict(script=identifier,operations=operations))
        selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command',{}))
    main,main_origin=source('MAIN.EXE')
    main_base=struct.unpack_from('<I',main,24)[0]
    helper_offset=2048+0x800f6110-main_base
    helper=main[helper_offset:helper_offset+0x1c4]
    helper_digest='a9d5ebe82b6a1c6e670e83267fb1e727f632e0b4671592126e1c26c082d45966'
    if hashlib.sha256(helper).hexdigest()!=helper_digest or struct.unpack_from('<I',main,2048+0x8016b680+0x28-main_base)[0]!=0x800f6110:
        raise ValueError('Dagon return camera consumer changed')
    phase=[]
    for first,last,digest in (
        (0x800f72f0,0x800f74a8,'cb99aea76276d021a3712bd80f7e7b3c3870dcd6cc3d2e6b40bb87494314e7a6'),
        (0x800de0b0,0x800de1ec,'b4c0ab7297a6048319311760ccc9d126d414a95f6d37eff784e337a7afcbbb38'),
        (0x800e0034,0x800e0080,'46395dfb7e5f97010d13a938d1e00990273dbf9d33a9423576f9854940131f80'),
    ):
        off=2048+first-main_base
        if hashlib.sha256(main[off:off+last-first]).hexdigest()!=digest:raise ValueError('Dagon primary/camera phase changed')
        phase.append(dict(source=main_origin,source_offset=off,byte_length=last-first,sha256=digest))
    _,children=battle_unite_camera.auxiliary_scripts(raw,origin,roots,main_origin,table+BASE,BASE)
    for child in children:
        instructions,blocked,effects=compile_operations(child['operations'])
        if blocked or effects or child['resource']!='shared':raise ValueError('Unbound Dagon child')
        identifier='melee/dagon/auxiliary/'+child['id'].replace(':','_')
        programs.append(dict(id=identifier,instructions=instructions))
        proofs.append(dict(id=identifier,operations=child['operations'],spans=[{k:child[k] for k in ('source','source_offset','byte_length','sha256')}]))
    resource,resource_proof=animation_resource('dagon',raw,origin,selected,section,BASE)
    from journey_battle import script_events
    animations={c['id']:[(f['pose'],f['updates']) for f in c['frames']] for c in resource['clips']}
    flags={c['id']:int(c['advances'])|int(c['loop'])<<1 for c in resource['clips']}
    owner=next(p for p in proofs if p['id']==special['owner_program'])
    clock=script_events(animations,[(op['op'],tuple(op['args'])) for op in owner['operations']],flags)
    timing=dict(contact_flag_update=clock['events'][2],contact_update=clock['events'][2]+1,
                poison_update=clock['events'][2]+1,return_flag_update=clock['events'][4],return_update=clock['events'][4]+1)
    melee=dict(ordinary,special=dict(attack_program=special['owner_program'],hurt_program=special['recipient_program'],
        return_program=ordinary['return_program'],damage_numerator=1,damage_denominator=2,
        clear_contact_signal=False,return_camera=camera))
    return dict(schema='suikoden-enemy-dagon/1',ordinary=ordinary,special=special,melee=melee,dodge=dodge,
        capability=dict(id='dagon',counterable=True,attack_program=ordinary['attack_program'],return_program=ordinary['return_program']),
        decision=dict(target_policy='front_first',secondary_modulus=100,secondary_threshold=76),timing=timing,
        programs=dict(schema=program_schema(programs),programs=programs),
        animations=dict(schema='suikoden-actor-animations/1',resources=[resource]),
        provenance=dict(producer='export_enemy_dagon.py v1',source=origin,record_source_offset=record,
            callbacks=callbacks,programs=proofs,resource=resource_proof,
            root_phase=phase,
            return_camera=dict(source=origin,source_offset=0x1e60c,byte_length=48,sha256=hashlib.sha256(raw[0x1e60c:0x1e63c]).hexdigest(),
                setter=dict(source=main_origin,source_offset=helper_offset,byte_length=len(helper),sha256=helper_digest)),
            scope='Source component; shared MAIN impact resource required. Native source profile/art/formation and media admission remain separate.'))


def combine(actors,plan=None):
    if actors['schema'] not in ('suikoden-unite-actors/35','suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):
        raise ValueError('Dagon needs the complete shared actor library')
    plan=build() if plan is None else plan
    result=copy.deepcopy(actors);merge_libraries(result,plan)
    for rows,binding in ((result['counter']['enemies'],plan['capability']),
            (result['counter']['melee']['enemies'],plan['melee']),
            (result['counter']['ranged']['dodges'],plan['dodge']),
            (result['counter']['party_melee']['dodges'],plan['dodge'])):
        prior=next((row for row in rows if row['id']=='dagon'),None)
        if prior is None:rows.append(copy.deepcopy(binding))
        elif prior!=binding:raise ValueError('Conflicting Dagon binding')
    result['schema']='suikoden-unite-actors/'+str(max(36,int(actors['schema'].rsplit('/',1)[1])))
    return result


def append_content(battle,actors,atlas):
    """Admit source Dagon and whole qualified G formations into the catalogue."""
    import journey_battle
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks
    if any(row['id']=='dagon' for row in battle['enemies']):raise ValueError('Dagon profile already present')
    plan=build();combined=combine(actors,plan)
    roots=[('dagon',binding[key]) for binding in (plan['ordinary'],plan['special'],plan['dodge'])
           for key in binding if key.endswith('_program')]
    art,proof=graphics(combined,dict(resources=[plan['provenance']['resource']]),atlas,{'dagon'},roots,
                       existing_graphics=battle['unite_graphics'])
    battle['unite_graphics'].extend(art)
    catalogue=journey_battle.append_later_enemies(battle,atlas,(('g',1,'dagon'),))
    profile=battle['enemies'][-1]
    raw,_=source('/G_DATA.BIN');record=plan['provenance']['record_source_offset']
    profile.update(action_policy='source_dagon',knockout_ticks=squirrel_knockout_ticks(raw,struct.unpack_from('<I',raw,record+40)[0]-BASE),
                   effect_offset=list(struct.unpack_from('<2h',raw,record+60)))
    resource=next(r for r in combined['animations']['resources'] if r['id']=='dagon')
    idle=next(c for c in resource['clips'] if c['id']==0)['frames'][0]['pose']
    pose=next(p for p in art[0]['poses'] if p['id']==idle)['sprite']
    profile['sprite']=copy.deepcopy(pose)
    profile['attack']=[dict(pose=copy.deepcopy(pose),ticks=1,source_pose=idle)]
    battle['schema']='suikoden-battle-trial/'+str(max(39,int(battle['schema'].rsplit('/',1)[1])))
    actors.clear();actors.update(combined)
    return dict(component=plan['provenance'],graphics=proof,catalogue=catalogue,
                scope='Source Dagon and whole qualified G diagnostic formations; field placement, audio and media acceptance remain separate.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'kit/work/build/enemy_dagon_source_v1/actors.json')
    args=parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.output.resolve(),*args.output.resolve().parents):raise ValueError('Dagon exports are candidates; accepted promotion is separate')
    packet=build();args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(packet,indent=2)+'\n');print(args.output)
