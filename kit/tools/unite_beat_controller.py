"""Static Beat'em up callback, actor dispatches and recipient-stage contract."""
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera as source
import journey_battle

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT/'kit/data/reports/unite_beat_controller.json'
ACTORS = ROOT/'kit/data/reports/unite_beat_actors.json'
RECIPIENTS = ROOT/'kit/data/reports/unite_beat_recipients.json'
SPANS = ((0x800FD2FC,0x800FD42C,'902bce8802ed6446f6c5553fbc182eb5c4f3f78527e9d5a6983cee04f5ee46ee'),
         (0x800FD42C,0x800FD7A4,'f8f51d1fb2300769ffc683c2351e588ca21e2bf43972f57f0d37a790478326e1'))
SCRIPTS = {
    ('/PAN.BIN',10): 'd342a145273d12011439efb11536e20c520506663b19ee9350f73fb246cab70b',
    ('/PAN.BIN',15): 'd428dfe0ebc208f15cd10c555a7f8bd975f388abc0f1537897e125135125f29f',
    ('/BEL.BIN',9): '25cf3ceb4a3e9c4bc306abb44e3ed942c5de93af59b76e215859cbc44423d18f',
    ('/BEL.BIN',10): '0561e30696fac5f6c734326243aed4bc8039bb60184b8e03b203d671ed4a1f05',
    ('/BEL.BIN',11): '4f781bfc11e6c50e262ad71a3735a82dd8b1db9561374ab4909932c5b305ae23',
    ('/BEL.BIN',12): '2d650b440dd77c656c443a1296392a51ba29a09831f278e90ca582302f3d5963',
}


def descriptor(path, index):
    raw, origin = source.field.source(path)
    table = struct.unpack_from('<I',raw,32)[0]
    offset = struct.unpack_from('<I',raw,table+4*index)[0]
    operations = journey_battle.script(raw,index)
    length = sum(2+2*len(args) for _,args in operations)
    digest = hashlib.sha256(raw[offset:offset+length]).hexdigest()
    if digest != SCRIPTS[(path,index)]:
        raise ValueError('Beat em up descriptor changed')
    return dict(script=index,source=origin,source_offset=offset,byte_length=length,sha256=digest,
                operations=[dict(op=op,args=list(args)) for op,args in operations])


def build(image=None):
    image = image or source.Image()
    row = source.report()[27]
    if [m['id'] for m in row['member_scripts']] != [6,13]:
        raise ValueError('Beat em up participants changed')
    blocks=[]
    for start,end,digest in SPANS:
        actual=hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()
        if image.end(start)!=end or actual!=digest:
            raise ValueError('Beat em up controller changed')
        blocks.append(dict(address=start,size=end-start,sha256=actual))
    return dict(schema='suikoden-unite-beat-controller/1',record=27,source_blocks=blocks,
                members=[dict(id=6,entry=descriptor('/PAN.BIN',10),recovery=True),
                         dict(id=13,entry=descriptor('/BEL.BIN',9),followup=descriptor('/BEL.BIN',10),recovery=False)],
                child=dict(trigger_member=1,mailbox=1,consume=99,animation=18,
                           script=descriptor('/BEL.BIN',11),resource_member=1,owner_member=1,
                           offset_q12=[-10*4096,0,-20*4096],home='parent_owner_current_position',
                           draw_record=False,attachment='target current graphic unsigned-byte differences (e6-e4,e7-e5)',
                           allocation='descending shared actor pool; constructor before actor sweep'),
                transition=dict(trigger_member=0,signal=16,consume=True,member=1,script=10,owner='selected_target'),
                first_reaction=dict(trigger_member=0,signal=2,consume=True,script=descriptor('/PAN.BIN',15),
                                    inherited_lock='Pahn entry op15(owner,8)',terminal='wait for target signal2 to clear or descriptor replacement'),
                damage=dict(member=1,signal=2,count=2,multiplier=30,divisor=10,recipient=descriptor('/BEL.BIN',12)),
                completion=dict(signal=4,members=2,cleanup='after both ready flags; embedded returns and child continue independently'),
                callback_order=['mailbox child','Pahn ready16 transition','Pahn hit2 recipient','Bell hit2 combined damage','member ready4 cleanup'],
                admission='normal_journey_candidate_media_pending',
                unresolved=['campaign acquisition','broader KO and overlap','human visual/audio acceptance'])


def actor_programs():
    import export_unite_programs as compiler
    import character_table
    import preparation
    contract=build()
    seeds={r['id']:r for r in character_table.records()}
    programs=[];resources=[];origins=[];members=[];clocks={}
    for member in contract['members']:
        identifier=preparation.stable_id(seeds[member['id']]['name'])
        raw,origin=source.field.source('/'+member['entry']['source']['file'].split('/')[-1])
        animations,flags,_=source.animation_frames(raw)
        selected={0}; binding=dict(id=identifier)
        stages=[('entry',member['entry'])]
        if 'followup' in member:stages.append(('followup',member['followup']))
        if member['id']==13:stages.append(('child',contract['child']['script']));selected.add(contract['child']['animation'])
        for stage,stream in stages:
            name=f'{identifier}/beat_{stage}'
            instructions,blocked,_=compiler.compile_operations(stream['operations'],identifier)
            if blocked or instructions is None:raise ValueError('Unsupported Beat em up actor stage')
            programs.append(dict(id=name,instructions=instructions));binding[stage]=name
            clocks[name]=journey_battle.script_events(animations,[(o['op'],tuple(o['args'])) for o in stream['operations']],flags,initial_movement_wait=stage=='child')
            selected.update(op['args'][0] for op in stream['operations'] if op['op']==4)
        raw,origin=source.field.source('/'+member['entry']['source']['file'].split('/')[-1])
        resource,proof=compiler.animation_resource(identifier,raw,origin,selected)
        resources.append(resource);origins.append(proof);members.append(binding)
    child=dict(program=members[1].pop('child'),resource=members[1]['id'],animation=18,
               owner='self',home='parent_owner',draw_record=False,offset=[-10,0,-20])
    pahn=clocks[members[0]['entry']];bell=clocks[members[1]['followup']]
    followup=contract['members'][1]['followup']['operations']
    child_at=pahn['events'][16]+next(t for o,t in zip(followup,bell['operation_ticks'],strict=True) if o==dict(op=30,args=[1]))
    expected=dict(first_reaction=pahn['events'][2],transition=pahn['events'][16],child=child_at,
                  damage=pahn['events'][16]+bell['events'][2],cleanup=max(pahn['events'][4],pahn['events'][16]+bell['events'][4]),
                  child_hidden=child_at+clocks[child['program']]['duration']-1,
                  child_retired=child_at+clocks[child['program']]['duration'],pahn_complete=pahn['duration'])
    return dict(schema='suikoden-unite-beat-actors/1',programs=dict(schema='suikoden-actor-programs/7',programs=programs),
                animations=dict(schema='suikoden-actor-animations/1',resources=resources),members=members,
                child=child,source=contract,resources=origins,clocks=clocks,expected=expected)


def recipient_programs():
    import unite_reaction_assets
    contract=build()
    first=contract['first_reaction']['script']
    ops=first['operations']
    waits=[i for i,o in enumerate(ops) if o['op']==29]
    if len(waits)!=1 or ops[waits[0]]!=dict(op=29,args=[0,2]) or ops[waits[0]-1]!=dict(op=26,args=[0,2]):
        raise ValueError('Beat em up recipient handshake changed')
    prefix=ops[:waits[0]]
    first_source=dict(first,operations=prefix,local_timing=journey_battle.script_events([],[(o['op'],tuple(o['args'])) for o in prefix],initial_movement_wait=True))
    final=contract['damage']['recipient']
    final_source=dict(final,local_timing=journey_battle.script_events([],[(o['op'],tuple(o['args'])) for o in final['operations']],initial_movement_wait=True))
    rows=[dict(index=27,variant=1,target_reaction=first_source),dict(index=27,variant=0,target_reaction=final_source)]
    programs=unite_reaction_assets.reactions(rows,lock_handoffs=((27,1,0),),inherited_locks=((27,1),),include_sounds=True)
    if any(p['blocker'] for p in programs):raise ValueError('Beat em up recipient is blocked')
    return dict(schema='suikoden-unite-beat-recipients/1',programs=programs,
                source=[first,final],first_terminal=dict(operation=waits[0],wait='signal2 clear',semantics='hold prefix until callback replaces descriptor'),
                inherited_lock=contract['first_reaction']['inherited_lock'])


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group();group.add_argument('--actors',action='store_true');group.add_argument('--recipients',action='store_true')
    parser.add_argument('--check',action='store_true');args=parser.parse_args()
    data=actor_programs() if args.actors else recipient_programs() if args.recipients else build()
    path=ACTORS if args.actors else RECIPIENTS if args.recipients else REPORT
    payload=json.dumps(data,indent=2)+'\n'
    if args.check:
        if path.read_text()!=payload:raise SystemExit('Beat em up report is stale')
    else:path.write_text(payload)
    print('Checked Beat em up contract' if args.check else 'Wrote Beat em up contract')
