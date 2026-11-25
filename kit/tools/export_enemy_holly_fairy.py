"""Static Holly Fairy actor streams and delegated enemy-wave contract."""
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
    (0x1ac, 0x358, '01e0eca5396720abc8ba1f10ef45d40cabc5e9114dea48ec94fb63272921f4ae'),
    (0x358, 0x580, '14a09e1dbfde498676ebdcbd7dd05df7eefb7fcd33e4229431501eb49c98738a'),
)
MAIN_BLOCKS = (
    (0x800f3fec, 0x800f40b8, 'b314586304662a74a6184e87cceb449f44aea27987e110135a35c6e5340ca1f3'),
    (0x800f40fc, 0x800f43e8, '79150254e22ddc17a1d9dc4dae0d450b779db488e70b8261fbbf76f4f05b6ff9'),
    (0x800f45c8, 0x800f4628, 'eb017d3057fcb2e9079f06523c92a35d3e411d38dec407982b3b2aed028213f8'),
    (0x800f4e64, 0x800f5050, '9030d8745360442557ae784c5ec592649144a17e1eeca71772d8288e5badbdcb'),
)
IDLE_BLOCKS = (
    (0x800de61c, 0x800de9e0, 'b065008b00fac99b94fe0e9f0c0c27225004379cc51787128559c5fbec42a4e8'),
    (0x800dee44, 0x800df144, '7d631e8df5dafb59a6aa5c354d981e3a6b41dad3c6ce079fa2958787e8a9637b'),
    (0x800e09bc, 0x800e0ea0, 'ff1ad0dc5ee8dd8e3a49cfa550410ff8f415c1b8475b6a5c4a69da293697c276'),
    (0x800e358c, 0x800e3820, 'a921697e4334bef240f626e216461882a060c85c6b18ecaf728dc10d83ac3e13'),
    (0x800e3820, 0x800e38f0, '1b14a0c8563418079e0ba1c7e056661bc8c13a2e1bf73b77ef1347d0027a4939'),
    (0x800e38f0, 0x800e38f8, '207819bf4ebe30789debac4affc1a07c833e14f530eef04dc87a6cf369209b43'),
    (0x800e45c0, 0x800e460c, 'ff30424d1f5096b3a2171cc2b8229de5e0b692bc2f51b28723cb0ce40a1c4b5f'),
    (0x800e4974, 0x800e4c4c, '9bdfa5127f6e1a3e7825ad17b35d41ed6105c57b5319627f1bd7bedbdadc712c'),
)


def checked_span(raw, origin, first, last, digest):
    if hashlib.sha256(raw[first:last]).hexdigest() != digest:
        raise ValueError('Holly Fairy source controller changed')
    return dict(source=origin, source_offset=first, byte_length=last-first, sha256=digest)


def build():
    raw, origin = source('/D_DATA.BIN')
    pointer = lambda off: struct.unpack_from('<I', raw, off)[0] - BASE
    directory = pointer(pointer(pointer(0)+12))
    record = pointer(pointer(directory+12)+4)
    table, section = pointer(record+40), pointer(record+44)
    if (record, table, section, pointer(record+48), struct.unpack_from('<H', raw, record+38)[0]) != (0x207e0, 0x20820, 0x20b28, 0x1ac, 0x23):
        raise ValueError('Holly Fairy record or selector changed')
    callbacks = [checked_span(raw, origin, *block) for block in BLOCKS]
    main, main_origin = source('MAIN.EXE')
    main_base = struct.unpack_from('<I', main, 24)[0]
    main_offset = lambda address: 2048 + address - main_base
    consumers = [checked_span(main, main_origin, main_offset(first), main_offset(last), digest)
                 for first, last, digest in MAIN_BLOCKS]
    idle_consumers = [checked_span(main, main_origin, main_offset(first), main_offset(last), digest)
                      for first, last, digest in IDLE_BLOCKS]
    if struct.unpack_from('<I', main, main_offset(0x8016b680+0x44))[0] != 0x800f4e64:
        raise ValueError('Holly Fairy ordinary resolver import changed')
    programs, proofs, roots = [], [], []
    selected = {0, 1, 3}
    bindings = dict(id='holly_fairy')
    for role, offset in (
        ('idle', pointer(table)), ('attack', pointer(table+4)),
        ('hurt', pointer(table+8)), ('parry_response', pointer(table+12)),
        ('return', pointer(table+16)), ('parry_strike', pointer(table+20)),
        ('wave_owner', 0x20938),
    ):
        operations, spans = stream(raw, origin, offset, table, BASE)
        instructions, blocked, effects = compile_operations(operations, 'melee/holly_fairy', member_resource='holly_fairy')
        if blocked or effects:
            raise ValueError('Unbound Holly Fairy actor: '+role)
        identifier = 'melee/holly_fairy/'+role
        bindings[role+'_program'] = identifier
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=operations, spans=spans))
        roots.append(dict(script=identifier, operations=operations))
        selected.update(i['command']['animation'] for i in instructions if 'animation' in i.get('command', {}))
    _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table+BASE, BASE)
    for child in children:
        instructions, blocked, effects = compile_operations(child['operations'])
        if blocked or effects or child['resource'] != 'shared':
            raise ValueError('Unbound Holly Fairy child')
        identifier = 'melee/holly_fairy/auxiliary/'+child['id'].replace(':', '_')
        programs.append(dict(id=identifier, instructions=instructions))
        proofs.append(dict(id=identifier, operations=child['operations'], spans=[
            {k: child[k] for k in ('source', 'source_offset', 'byte_length', 'sha256')}]))
    resource, resource_proof = animation_resource('holly_fairy', raw, origin, selected, section, BASE)
    idle_root = next(row for row in proofs if row['id'] == bindings['idle_program'])
    expected_idle = [dict(op=op,args=args) for op,args in (
        (4,[0]), (33,[1,30,0,0,-10]), (21,[]), (33,[1,30,0,0,10]), (21,[]), (0,[]))]
    if idle_root['operations'] != expected_idle:
        raise ValueError('Holly Fairy idle motion changed')
    from journey_battle import script_events
    clips = {c['id']: [(f['pose'], f['updates']) for f in c['frames']] for c in resource['clips']}
    flags = {c['id']: int(c['advances']) | int(c['loop']) << 1 for c in resource['clips']}
    owner = next(row for row in proofs if row['id'] == bindings['wave_owner_program'])
    clock = script_events(clips, [(o['op'], tuple(o['args'])) for o in owner['operations']], flags)
    mailbox_writes = {o['args'][0]: tick for o, tick in zip(owner['operations'], clock['operation_ticks'], strict=True) if o['op'] == 30}
    return dict(
        schema='suikoden-enemy-holly-fairy/1', bindings=bindings,
        decision=dict(front_target_policy='front_only', front_draw_kind='modulo_100', front_threshold=51,
                      failed_front_scan='consume_turn', rear_row='delegated_enemy_wave'),
        wave=dict(owner_program=bindings['wave_owner_program'], active_mailbox=1, complete_mailbox=99,
                  active_delay=120, selection_delay=30, scan_order='ascending_enemy_index',
                  skip=['acted', 'locked', 'inactive'], maximum_started_per_update=1,
                  ordinary_dispatch='selected_enemy_physical_resolver',
                  ordinary_resolver_result='ignored', restore_owner=True,
                  zero_result='restore_wave_callback_and_continue',
                  started_results=[-1, 1], started_result='mark_acted_and_clear_signals',
                  special_result='retain_delegated_primary_callback',
                  other_result='restore_owner_and_stop_scan'),
        timing=dict(initial_motion_updates=0, active_mailbox_write=mailbox_writes[1], first_delegate_update=mailbox_writes[1]+1,
                    complete_mailbox_write=mailbox_writes[99], completion_update=mailbox_writes[99]+1,
                    owner_program_duration=clock['duration']),
        idle=dict(program=bindings['idle_program'], dispatch_phase='after_enemy_vm_and_ko_check',
                  restart_when='alive_active_script_halted', preserves_pending_motion=True,
                  motion_override='explicit_motion_command',
                  first_dispatch_update=1, first_motion_update=2, downward_snap_update=31,
                  return_motion_update=32, return_snap_update=61, restart_update=62,
                  period=61, motion_updates=30, displacement_q12=[0,0,-40960],
                  wave_delay_per_pending_motion_update=1,
                  attack_prepare_updates=sum(f['updates'] for c in resource['clips'] if c['id']==4 for f in c['frames'])),
        programs=dict(schema=program_schema(programs), programs=programs),
        animations=dict(schema='suikoden-actor-animations/1', resources=[resource]),
        provenance=dict(producer='export_enemy_holly_fairy.py v1', source=origin,
                        record_source_offset=record, callbacks=callbacks, consumers=consumers,
                        idle_consumers=idle_consumers,
                        programs=proofs, resource=resource_proof,
                        scope='Static source component only. Live delegated-wave scheduling, normal art/profile/formation admission and media review remain unfinished.'))


def combine(actors, plan=None):
    """Bind the source component without admitting guessed profiles or artwork."""
    if actors['schema'] not in ('suikoden-unite-actors/37', 'suikoden-unite-actors/38', 'suikoden-unite-actors/39', 'suikoden-unite-actors/40'):
        raise ValueError('Holly Fairy needs the complete shared actor library')
    plan = build() if plan is None else plan
    result = copy.deepcopy(actors)
    merge_libraries(result, plan)
    binding = plan['bindings']
    enemy = dict(id=binding['id'], counterable=True,
                 attack_program=binding['attack_program'], return_program=binding['return_program'])
    melee = {k: binding[k] for k in ('id', 'attack_program', 'hurt_program', 'return_program')}
    parry = dict(id=binding['id'], response_program=binding['parry_response_program'],
                 strike_program=binding['parry_strike_program'], hurt_program=binding['hurt_program'])
    for rows, value in ((result['counter']['enemies'], enemy),
                        (result['counter']['melee']['enemies'], melee),
                        (result['counter']['parries']['defenders'], parry)):
        previous = next((r for r in rows if r['id'] == value['id']), None)
        if previous is None:
            rows.append(copy.deepcopy(value))
        elif previous != value:
            raise ValueError('Conflicting Holly Fairy binding')
    wave = dict(id=binding['id'], owner_program=binding['wave_owner_program'])
    if result.get('enemy_wave') not in (None, wave):
        raise ValueError('Conflicting Holly Fairy wave binding')
    result['enemy_wave'] = wave
    result['schema'] = 'suikoden-unite-actors/' + str(max(38, int(actors['schema'].rsplit('/', 1)[1])))
    return result


def append_content(battle, actors, atlas):
    """Admit source Holly Fairy art/profile and complete qualified D formations."""
    import journey_battle
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks
    if any(row['id'] == 'holly_fairy' for row in battle['enemies']):
        raise ValueError('Holly Fairy profile already present')
    plan = build()
    combined = combine(actors, plan)
    roots = [('holly_fairy', value) for key, value in plan['bindings'].items() if key.endswith('_program')]
    art, proof = graphics(combined, dict(resources=[plan['provenance']['resource']]), atlas,
                          {'holly_fairy'}, roots, existing_graphics=battle['unite_graphics'])
    battle['unite_graphics'].extend(art)
    catalogue = journey_battle.append_later_enemies(battle, atlas, (('d', 1, 'holly_fairy'),))
    raw, _ = source('/D_DATA.BIN')
    record = plan['provenance']['record_source_offset']
    profile = battle['enemies'][-1]
    profile.update(action_policy='source_holly_fairy', target_policy='front_first',
                   knockout_ticks=squirrel_knockout_ticks(raw, struct.unpack_from('<I', raw, record+40)[0]-BASE),
                   effect_offset=list(struct.unpack_from('<2h', raw, record+60)))
    resource = next(r for r in combined['animations']['resources'] if r['id'] == 'holly_fairy')
    idle = next(c for c in resource['clips'] if c['id'] == 0)['frames'][0]['pose']
    pose = next(p for p in art[0]['poses'] if p['id'] == idle)['sprite']
    profile['sprite'] = copy.deepcopy(pose)
    profile['attack'] = [dict(pose=copy.deepcopy(pose), ticks=1, source_pose=idle)]
    battle['schema'] = 'suikoden-battle-trial/'+str(max(41, int(battle['schema'].rsplit('/', 1)[1])))
    actors.clear()
    actors.update(combined)
    return dict(component=plan['provenance'], graphics=proof, catalogue=catalogue,
                scope='Source Holly Fairy and whole qualified D diagnostic formations; field placement, mixed delegated specials and media acceptance remain separate.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'kit/work/build/enemy_holly_fairy_source_v1/actors.json')
    args = parser.parse_args()
    if (ROOT/'kit/work/accepted').resolve() in (args.output.resolve(), *args.output.resolve().parents):
        raise ValueError('Holly Fairy exports are candidates')
    packet = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(packet, indent=2)+'\n')
    print(args.output)
