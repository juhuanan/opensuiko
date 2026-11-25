"""Static Martial arts target queue and recipient-stage contract."""
import hashlib
import json
from pathlib import Path
import struct

import battle_unite_camera as source
import journey_battle

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/unite_martial_controller.json'
RECIPIENT_REPORT = ROOT / 'kit/data/reports/unite_martial_recipients.json'
ACTOR_REPORT = ROOT / 'kit/data/reports/unite_martial_actors.json'
SPANS = ((0x800FDE20, 0x800FE000, '27835ae25cba041016e4f09dfd30957e197425ec5d0315743f63471a795a760c'),
         (0x800FE000, 0x800FE3A8, '28a0991a36851babc974a81ec11df338aeffe15dfb8e13dad1e48d0c08c778e2'))


def build(image=None):
    image = image or source.Image()
    row = source.report()[29]
    if [member['id'] for member in row['member_scripts']] != [66, 6, 52]:
        raise ValueError('Martial arts participants changed')
    blocks = []
    for start, end, expected in SPANS:
        digest = hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()
        if image.end(start) != end or digest != expected:
            raise ValueError('Martial arts controller changed')
        blocks.append(dict(address=start, size=end-start, sha256=digest))
    raw, origin = source.field.source('/EIK.BIN')
    table = struct.unpack_from('<I', raw, 32)[0]
    recipients = []
    for script, digest in ((11, '9a16a85844f02d8f7a4302c507930a5db4f3a617f5f26a1fcb5ed313603f2852'),
                           (12, 'eb2d06c7b2dfcfd31484f9343a0d0a5fa8c552f3de35981ac6fd96a1d1a33f60')):
        operations = journey_battle.script(raw, script)
        offset = struct.unpack_from('<I', raw, table+4*script)[0]
        length = sum(2+2*len(args) for _, args in operations)
        if hashlib.sha256(raw[offset:offset+length]).hexdigest() != digest:
            raise ValueError('Martial arts recipient changed')
        recipients.append(dict(script=script, source=origin, source_offset=offset, byte_length=length,
                               sha256=digest, operations=[dict(op=op,args=list(args)) for op,args in operations],
                               local_timing=journey_battle.script_events([], operations, initial_movement_wait=True)))
    return dict(schema='suikoden-unite-martial-controller/1', record=29, source_blocks=blocks,
                members=[dict(id=m['id'], source=m['source'], scripts=m['scripts']) for m in row['member_scripts']],
                queue=dict(claim_signal=16, consume_claim=True, order='ascending enemy slots',
                           attacker_order='source member order', strike_script=10, script_owner_member=0,
                           recipient_script=11, impact_signal=2, consume_impact=True,
                           empty_queue='dispatch common return and mark member finished'),
                finish=dict(clock='increments only after all three members are marked finished',
                            initial_counter=0, recipient_return_counter=80, recipient_return_script=12,
                            damage_counter=140, damage_count=3, damage_multiplier=5, damage_divisor=10,
                            cleanup_counter=200, targets='active enemies in ascending slots'),
                recipients=recipients, admission='native_vm_scene_bound_visual_acceptance_pending',
                unresolved=['campaign acquisition', 'broader KO and overlap',
                            'human visual and audio acceptance'])


def recipient_programs():
    """Compile the paired recipient stages without admitting the battle controller."""
    import unite_reaction_assets
    contract = build()
    rows = [dict(index=29, variant=index+1, target_reaction=row)
            for index, row in enumerate(contract['recipients'])]
    programs = unite_reaction_assets.reactions(rows, lock_handoffs=((29, 1, 2),))
    # Script12 inherits the hurt pose and white palette retained by script11.
    programs[1]['poses'].insert(0, dict(at=0, animation=1))
    programs[1]['white'].insert(0, dict(at=0, enabled=True))
    for program, source_row in zip(programs, contract['recipients'], strict=True):
        program['sounds'] = [dict(at=max(0, tick-1), id=op['args'][0])
                             for op, tick in zip(source_row['operations'], source_row['local_timing']['operation_ticks'], strict=True)
                             if op['op'] == 34]
    return dict(schema='suikoden-unite-martial-recipients/1', record=29,
                source=contract['recipients'], programs=programs,
                admission='candidate_recipient_stages_bound_to_battle',
                unresolved=['concurrent cue ordering', 'human media acceptance'])


def actor_programs():
    """Lower the borrowed strike against each member's own animation resource."""
    import export_unite_programs as compiler
    import character_table
    import preparation
    import maindec
    contract = build()
    seeds = {row['id']: row for row in character_table.records()}
    strike = next(row for row in contract['members'][0]['scripts'] if row['script'] == 10)
    returning = [dict(op=op,args=list(args)) for op,args in journey_battle.script_at(maindec.body(),0x8016D214-maindec.MBASE)]
    _, main_source = source.field.source('MAIN.EXE')
    return_offset = 0x8016D214-maindec.MBASE
    return_length = sum(2+2*len(op['args']) for op in returning)
    programs, resources, bindings, provenance = [], [], [], []
    for member in contract['members']:
        identifier = preparation.stable_id(seeds[member['id']]['name'])
        setup = member['scripts'][0]
        selected = {0}
        names = {}
        for stage, operations in (('setup',setup['operations']),('strike',strike['operations']),('return',returning)):
            name = f'{identifier}/martial_{stage}'
            instructions, blocked, _ = compiler.compile_operations(operations,identifier)
            if blocked or instructions is None:
                raise ValueError('Martial arts member program is unsupported')
            selected.update(op['args'][0] for op in operations if op['op']==4)
            programs.append(dict(id=name,instructions=instructions))
            names[stage] = name
        raw, origin = source.field.source('/'+member['source']['file'].split('/')[-1])
        resource, proof = compiler.animation_resource(identifier,raw,origin,selected)
        resources.append(resource)
        provenance.append(proof)
        bindings.append(dict(id=identifier,**names))
    return dict(schema='suikoden-unite-martial-actors/1',
                programs=dict(schema='suikoden-actor-programs/7',programs=programs),
                animations=dict(schema='suikoden-actor-animations/1',resources=resources),
                bindings=bindings,provenance=provenance,borrowed_strike=strike,
                return_source=dict(source=main_source,source_offset=2048+return_offset,
                    byte_length=return_length,sha256=hashlib.sha256(maindec.body()[return_offset:return_offset+return_length]).hexdigest()),
                admission='portable_actor_candidate_bound_to_battle')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--recipients', action='store_true')
    parser.add_argument('--actors', action='store_true')
    args = parser.parse_args()
    if args.actors and args.recipients:
        parser.error('choose actors or recipients')
    payload = json.dumps(actor_programs() if args.actors else recipient_programs() if args.recipients else build(), indent=2) + '\n'
    destination = ACTOR_REPORT if args.actors else RECIPIENT_REPORT if args.recipients else REPORT
    if args.check:
        if destination.read_text() != payload:
            raise SystemExit('Martial arts report is stale')
    else:
        destination.write_text(payload)
    print('Checked Martial arts contract' if args.check else 'Wrote Martial arts contract')
