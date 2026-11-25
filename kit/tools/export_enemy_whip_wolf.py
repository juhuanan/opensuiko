"""Static Whip Wolf front attacks and relocated Commander group callbacks."""
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

BASE=0x80080000
BLOCKS=(
    (0x194,0x338,'2f1c6a784f052e4dfade3e73c446d40461ce38d8cd4bc50452a81abe1a60430d'),
    (0x338,0x4fc,'33cd12cf530b14634e0996ca0031f4f68e043e63ae7a9674a36a4b10b29af086'),
    (0x4fc,0x5e4,'2860fe2168b6c790ba24ed9501417a409f6fb03a9af2aea437bec4f176df4509'),
    (0x5e4,0x67c,'56418ca2dd6f5db0470738cdaab9502e563a335e2087467dc4997d206e68f993'),
)


def build():
    raw,origin=source('/E_DATA.BIN');pointer=lambda off:struct.unpack_from('<I',raw,off)[0]-BASE
    directory=pointer(pointer(pointer(0)+12));record=pointer(pointer(directory+12)+4)
    table,section=pointer(record+40),pointer(record+44)
    if (record,table,section,pointer(record+48),struct.unpack_from('<H',raw,record+38)[0])!=(0x1ec7c,0x1ecbc,0x1f044,0x194,4):
        raise ValueError('Whip Wolf record or selector changed')
    callbacks=[]
    for first,last,digest in BLOCKS:
        if hashlib.sha256(raw[first:last]).hexdigest()!=digest:raise ValueError('Whip Wolf callback changed')
        callbacks.append(dict(source=origin,source_offset=first,byte_length=last-first,sha256=digest))
    if struct.unpack_from('<2I',raw,0x1fc)!=(0x3c06800a,0x24c6ed74):raise ValueError('Whip Wolf order descriptor changed')
    programs=[];proofs=[];roots=[];selected={0,1,3};ordinary=dict(id='whip_wolf');dodge=dict(id='whip_wolf')
    for role,offset in (('attack',pointer(table+4)),('hurt',pointer(table+8)),('return',pointer(table+16)),
                        ('dodge',pointer(table+12)),('order',0x1ed74)):
        operations,spans=stream(raw,origin,offset,table,BASE)
        instructions,blocked,effects=compile_operations(operations,'melee/whip_wolf',member_resource='whip_wolf')
        if blocked or effects:raise ValueError('Unbound Whip Wolf actor: '+role)
        identifier='melee/whip_wolf/'+role
        programs.append(dict(id=identifier,instructions=instructions));proofs.append(dict(id=identifier,operations=operations,spans=spans))
        roots.append(dict(script=identifier,operations=operations))
        if role in ('attack','hurt','return'):ordinary[role+'_program']=identifier
        if role=='dodge':dodge['response_program']=identifier
        selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command',{}))
    _,main_origin=source('MAIN.EXE')
    _,children=battle_unite_camera.auxiliary_scripts(raw,origin,roots,main_origin,table+BASE,BASE)
    for child in children:
        instructions,blocked,effects=compile_operations(child['operations'])
        if blocked or effects or child['resource']!='shared':raise ValueError('Unbound Whip Wolf child')
        identifier='melee/whip_wolf/auxiliary/'+child['id'].replace(':','_')
        programs.append(dict(id=identifier,instructions=instructions))
        proofs.append(dict(id=identifier,operations=child['operations'],spans=[{k:child[k] for k in ('source','source_offset','byte_length','sha256')}]))
    resource,resource_proof=animation_resource('whip_wolf',raw,origin,selected,section,BASE)
    from journey_battle import script_events
    animations={c['id']:[(f['pose'],f['updates']) for f in c['frames']] for c in resource['clips']}
    flags={c['id']:int(c['advances'])|int(c['loop'])<<1 for c in resource['clips']}
    order=next(p for p in proofs if p['id'].endswith('/order'))
    clock=script_events(animations,[(o['op'],tuple(o['args'])) for o in order['operations']],flags)
    return dict(schema='suikoden-enemy-whip-wolf/1',ordinary=ordinary,dodge=dodge,
        capability=dict(id='whip_wolf',counterable=False,attack_program=None,return_program=None),
        order=dict(id='whip_wolf',order_program='melee/whip_wolf/order',solo_program=None,recipient_program=None,selection_delay=60),
        decision=dict(rear_row='group_orders',front_target_policy='any_row',front_draw_kind='scale_100_32767',front_threshold=51),
        timing=dict(order_flag_update=clock['events'][2],launch_update=clock['events'][2]+1,owner_duration=clock['duration']),
        programs=dict(schema=program_schema(programs),programs=programs),
        animations=dict(schema='suikoden-actor-animations/1',resources=[resource]),
        provenance=dict(producer='export_enemy_whip_wolf.py v1',source=origin,record_source_offset=record,
            callbacks=callbacks,programs=proofs,resource=resource_proof,
            scope='Source component; front ordinary attack or rear group order. Normal profile/art/formation and media admission remain separate.'))


def combine(actors,plan=None):
    if actors['schema'] not in ('suikoden-unite-actors/36','suikoden-unite-actors/37','suikoden-unite-actors/38','suikoden-unite-actors/39','suikoden-unite-actors/40'):
        raise ValueError('Whip Wolf needs the complete shared actor library')
    plan=build() if plan is None else plan;result=copy.deepcopy(actors);merge_libraries(result,plan)
    for rows,binding in ((result['counter']['enemies'],plan['capability']),
            (result['counter']['melee']['enemies'],plan['ordinary']),
            (result['counter']['ranged']['dodges'],plan['dodge']),
            (result['counter']['party_melee']['dodges'],plan['dodge']),
            (result.setdefault('group_orders',[]),plan['order'])):
        prior=next((r for r in rows if r['id']==binding['id']),None)
        if prior is None:rows.append(copy.deepcopy(binding))
        elif prior!=binding:raise ValueError('Conflicting Whip Wolf binding')
    result['schema']='suikoden-unite-actors/'+str(max(37,int(actors['schema'].rsplit('/',1)[1])))
    return result


def append_content(battle,actors,atlas):
    """Admit source Whip Wolf and complete qualified E formations."""
    import journey_battle
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks
    if any(row['id']=='whip_wolf' for row in battle['enemies']):raise ValueError('Whip Wolf profile already present')
    plan=build();combined=combine(actors,plan)
    roots=[('whip_wolf',binding[key]) for binding in (plan['ordinary'],plan['dodge'],plan['order'])
           for key in binding if key.endswith('_program') and binding[key] is not None]
    art,proof=graphics(combined,dict(resources=[plan['provenance']['resource']]),atlas,{'whip_wolf'},roots,
                       existing_graphics=battle['unite_graphics'])
    battle['unite_graphics'].extend(art)
    catalogue=journey_battle.append_later_enemies(battle,atlas,(('e',1,'whip_wolf'),))
    profile=battle['enemies'][-1];raw,_=source('/E_DATA.BIN');record=plan['provenance']['record_source_offset']
    profile.update(action_policy='source_whip_wolf',target_policy='any_row',
        knockout_ticks=squirrel_knockout_ticks(raw,struct.unpack_from('<I',raw,record+40)[0]-BASE),
        effect_offset=list(struct.unpack_from('<2h',raw,record+60)))
    resource=next(r for r in combined['animations']['resources'] if r['id']=='whip_wolf')
    idle=next(c for c in resource['clips'] if c['id']==0)['frames'][0]['pose']
    pose=next(p for p in art[0]['poses'] if p['id']==idle)['sprite']
    profile['sprite']=copy.deepcopy(pose);profile['attack']=[dict(pose=copy.deepcopy(pose),ticks=1,source_pose=idle)]
    battle['schema']='suikoden-battle-trial/'+str(max(40,int(battle['schema'].rsplit('/',1)[1])))
    actors.clear();actors.update(combined)
    return dict(component=plan['provenance'],graphics=proof,catalogue=catalogue,
        scope='Source Whip Wolf and whole qualified E diagnostic formations; original field placement, audio and media acceptance remain separate.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'kit/work/build/enemy_whip_wolf_source_v1/actors.json');args=parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.output.resolve(),*args.output.resolve().parents):raise ValueError('Whip Wolf exports are candidates')
    packet=build();args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(packet,indent=2)+'\n');print(args.output)
