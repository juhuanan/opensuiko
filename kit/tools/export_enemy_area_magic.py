"""Export Sorcerer, Siren and Earth Golem actor programs, workers and formations."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import battle_bin
import battle_formulas
import battle_unite_camera
from export_first_room import ROOT, source
from export_physical_runes import merge_libraries, stream
from export_unite_programs import animation_resource, compile_operations, program_schema
from journey_battle import script_events
import maindec

BASE = 0x80080000
SOURCES = (
    ('sorcerer', 'E', 0x2240c, 0x2268c, 0x22aa0, 0x226f8, 6, 51, (('recipient', 0x1e934),), (
        (0x12b4, 0x14a0, '773140a63f6b99fe621a40d6f998a152d7aa536f4815ec1aa50fb315b16791b3'),
        (0x14a0, 0x1574, '69deb338413c12a0e9544ef0e0eec2a7182a7734e424022de6017cc3e211dfc7'),
        (0x1574, 0x15e0, '83141cec2b212f2c16dd3defebe5dd1559d73395a55c391691daefe373e50fcb'),
        (0x67c, 0x79c, '26b0da676e8b06a6670b93e0e7a48dc3508424f5684bf0503d3cc929b245e110'),
        (0x79c, 0x12b4, 'e6fbc9e85f210355ad395da8c83480bc18d4026d291cc1a71dd25b401c19e4f3'))),
    ('siren', 'G', 0x20e40, 0x210c0, 0x216c8, 0x212e8, 10, 51, (('recipient_1', 0x212d0), ('recipient_2', 0x21344)), (
        (0x7b0, 0x99c, 'c322c3807c1a0722358e4cd9210c780132ef7c6a83d4338b8fe9759953e5d05e'),
        (0x99c, 0xa4c, 'ffa9f58900ffe11f8cf6fd7adf038edba26f8bbdb1e47ff4e810c0b852e03140'),
        (0xa4c, 0xa90, 'a17eec692c0816d46382393ddc48cc5203664aa85cdadb1d20efba49fed3dcb7'),
        (0x630, 0x7b0, '60ed52260cfa1a6a0aa8d0474965b0d823ec35d27c5c75a1b7d7a059215bf28c'),
        (0x5ac, 0x630, '7f80c3b5ce0a32de20db33a669b3009cb0a8d1f0d52bfbe3dc58aaf8452d22ff'),
        (0xa90, 0x1250, 'be3cd20f5bbb34a0fa492c843cc788b0219ef459c6962ace59ed7a48b368ba91'))),
    ('earth_golem', 'H', 0x236f4, 0x23974, 0x23d4c, 0x23b4c, 8, 71, (('recipient', 0x1f4f0),), (
        (0x2c18, 0x2e04, '8636fe8632ba410db6b772c39467653224cd099104c3cb47643cfbfb13785263'),
        (0x3a2c, 0x3adc, '80f797f621fb6ef46e198fa300b77f0bccff5d28fbc53ea5843794a4d77e0809'),
        (0x3adc, 0x3b20, 'a17eec692c0816d46382393ddc48cc5203664aa85cdadb1d20efba49fed3dcb7'),
        (0x2e04, 0x2f24, 'dcbf8f23454f476202982416f09d69a9dd18336b865136af2cea2ec8d01cd5e3'),
        (0x2a18, 0x2c18, 'ba4367cdb52716ab26a80f20b0ddd2a6b26a8d4f9595ea439de151b50ce79889'),
        (0x2f24, 0x3a2c, '432d7cbb8f11214e1e721ddc70b5aaac396d4fcb8e01941ffabb856136d84d70'))),
)


def span(raw, origin, start, end, digest):
    if hashlib.sha256(raw[start:end]).hexdigest() != digest:
        raise ValueError('Area magic source changed at ' + hex(start))
    return dict(source=origin, source_offset=start, byte_length=end - start, sha256=digest)


def normalize_jumps(raw, start, end):
    words = list(struct.unpack('<' + 'I' * ((end - start) // 4), raw[start:end]))
    for i, word in enumerate(words):
        if word >> 26 in (2, 3):
            target = ((BASE + start + 4 * i + 4) & 0xf0000000) | ((word & 0x3ffffff) << 2)
            words[i] = (word & 0xfc000000) | (((target - (BASE + start) + BASE) >> 2) & 0x3ffffff)
    return words


def resistance_selectors():
    selectors = []
    for rune in range(1, 32):
        pc = maindec.mword(0x800c1414 + 4 * (rune - 1))
        if pc == 0x800f830c:
            selectors.append(0)
        elif pc == 0x800f8308:
            selectors.append(maindec.mword(pc) & 65535)
        elif maindec.mword(pc) == 0x0803e0c3 and maindec.mword(pc + 4) >> 16 == 0x3411:
            selectors.append(maindec.mword(pc + 4) & 65535)
        else:
            raise ValueError('unresolved generic magic resistance selector')
    return selectors


def simm(raw, offset):
    value = struct.unpack_from('<I', raw, offset)[0] & 65535
    return (value + 32768) % 65536 - 32768


def uimm(raw, offset):
    return struct.unpack_from('<I', raw, offset)[0] & 65535


def worker_contract(identifier, raw, bank_sections, bank_raw, selectors):
    if identifier == 'sorcerer':
        phase_0 = uimm(raw, 0xd54)
        flight = uimm(raw, 0xdac)
        phase_1 = uimm(raw, 0xdb4)
        phase_2 = uimm(raw, 0xe20)
        if phase_0 + flight != phase_1 or uimm(raw, 0xde4) != phase_1:
            raise ValueError('Sorcerer worker phase boundaries changed')
        damage_update = phase_0 + phase_2
        return (
            dict(
                origin_offset=[simm(raw, 0x954), simm(raw, 0x968), simm(raw, 0x980)],
                target_z_offset=simm(raw, 0xc04),
                art_prepare_updates=bank_raw[bank_sections[1]['header_offset'] + 4],
                damage_update=damage_update,
                cleanup_update=damage_update + 1,
                sounds=[dict(update=1, id=uimm(raw, 0xce0)), dict(update=phase_0 + 1, id=uimm(raw, 0xda0))],
                line_pool=dict(
                    count=uimm(raw, 0xd38), spawn_until=uimm(raw, 0xcf0), radius=uimm(raw, 0xd30),
                    speed_base=uimm(raw, 0x9c8), speed_mod=64, life_mod=uimm(raw, 0xd30),
                    tail_frames=5, stop_abs_x=uimm(raw, 0x1234), angle_y=-1024, color=[255, 64, 0],
                ),
                beam=dict(
                    count=uimm(raw, 0x9c0), clip='projectile', clip_period=48,
                    grow_until=64, max_size=uimm(raw, 0x1068), size_step=uimm(raw, 0x1058),
                    flight_start=phase_0 + 1, flight_updates=flight, reaction_update=phase_1 + 1,
                    impact_clip='impact', impact_period=30, impact_loop_clear_update=phase_0 + phase_1 + 1,
                    impact_end_update=239, impact_size=uimm(raw, 0x998),
                ),
            ),
            dict(
                element=uimm(raw, 0xe40), target_rune_elements=selectors,
                fallback_element=1, fallback_by_slot=False, defend_halves=False, variance_draws=1, minimum=1,
            ),
        )
    if identifier == 'siren':
        active_until = uimm(raw, 0xed0)
        phase_1 = uimm(raw, 0xef8)
        damage_update = active_until + phase_1
        return (
            dict(
                origin_offset=[0, 0, simm(raw, 0xb14)],
                target_z_offset=0,
                art_prepare_updates=0,
                damage_update=damage_update,
                cleanup_update=damage_update + 1,
                sounds=[],
                waves=dict(
                    active_until=active_until, cycle_updates=65, scale_step=uimm(raw, 0x1024),
                    column_count=uimm(raw, 0xdc8), column_delay_step=16, reaction_scale=uimm(raw, 0x1198),
                    reaction_updates=[47, 63, 79, 95, 112, 128, 144, 160],
                    lower=dict(radius=180, height=-300, color=[100, 144, 0]),
                    upper=dict(radius=120, height=-200, color=[0, 0, 0]),
                    segments=24, angle_y=-1024,
                    note_count=uimm(raw, 0xe64), note_delay_step=4, note_turn_step=uimm(raw, 0x10ac),
                    note_local=[180, 0, -300], note_poses=[14, 15, 16, 17], note_size=4096,
                ),
            ),
            dict(
                element=uimm(raw, 0xf50), target_rune_elements=selectors,
                fallback_element=0, fallback_by_slot=False, defend_halves=False, variance_draws=1, minimum=1,
            ),
        )
    phase_0 = uimm(raw, 0x32d4)
    phase_1 = uimm(raw, 0x3768)
    flight = uimm(raw, 0x3400)
    damage_update = phase_0 + phase_1
    return (
        dict(
            origin_offset=[0, 0, simm(raw, 0x3108)],
            target_z_offset=simm(raw, 0x33bc),
            art_prepare_updates=bank_raw[bank_sections[6]['header_offset'] + 4],
            damage_update=damage_update,
            cleanup_update=damage_update + 2,
            sounds=[dict(update=1, id=uimm(raw, 0x32b8)), dict(update=phase_0 + uimm(raw, 0x36d8) + 1, id=uimm(raw, 0x36e0))],
            rocks=dict(
                camera_pulse_until=damage_update - 1, camera_pulse_z_q12=uimm(raw, 0x31a4),
                launch_update=phase_0 + 1, flight_updates=flight, active_until=damage_update,
                draw_until=damage_update + 1, sine_divisor=uimm(raw, 0x3404),
                flight_arc=20, bounce_arc=60, spin_step=uimm(raw, 0x3910),
                impact_enable_update=phase_0 + uimm(raw, 0x367c) + 1,
                reaction_update=phase_0 + uimm(raw, 0x36d8) + 1,
                impact_end_update=147, rock_clip='golem_rock', impact_clip='golem_impact',
                impact_duration=36, size=uimm(raw, 0x30e8),
            ),
        ),
        dict(
            element=uimm(raw, 0x37ac), target_rune_elements=selectors,
            fallback_element=0, fallback_by_slot=True, defend_halves=False, variance_draws=1, minimum=1,
        ),
    )


def build():
    main, main_origin = source('MAIN.EXE')
    main_base = struct.unpack_from('<I', main, 24)[0]
    main_offset = lambda address: 2048 + address - main_base
    main_proofs = [span(main, main_origin, main_offset(start), main_offset(end), digest)
        for start, end, digest in (
            (0x800e557c, 0x800e5644, 'f62112e3056cbb60ea551d4d302ea4fea5f41e84eb0009f4bf3607c4b6026a18'),
            (0x800e358c, 0x800e3820, 'a921697e4334bef240f626e216461882a060c85c6b18ecaf728dc10d83ac3e13'),
            (0x800f8174, 0x800f8464, '49d88419738e2f1c95b8dfb4df0ed0b9f753824b0b6a9e3652597394617b9b6f'),
            (0x80122800, 0x80122bac, '3bde45b614f27f68f9fd67151d9212237d83cdac15416e0e49cb1611770b8890'),
            (0x801233b4, 0x80123974, 'b0f6e6bff2db4c7d59ee1e615817fc11f2dd098c51986b7e33a654ea6bd74e4c'),
            (0x8014f000, 0x8014f0fc, '07cb8f67e351799801ec2a9a6bf535fa1213f58aa4202b3cb6bebfb47eb355db'),
            (0x8014fd68, 0x801500bc, '76ad4c51f85b202179ec2ae102493a5b081f294f853a126ee92d01a66df814c7'),
            (0x80150810, 0x801508ec, '02134e11c82b060827d85b553fb8cb99328661181ef5deeb5b7073fe968fd2cf'))]
    reference, reference_origin = source('/C_DATA.BIN')
    fixed_reference = span(reference, reference_origin, 0x1050, 0x1250,
        'da3a358f3050ad26abaad0c245730682f80fee8c7f9ff0944a3720dabc323eb7')
    bank_sections, _, bank_errors, bank_raw = battle_bin.parse(need_atlases=False)
    if bank_errors:
        raise ValueError(bank_errors)
    selectors = resistance_selectors()
    programs = []; resources = []; actors = []; proofs = []; resource_proofs = []
    dispatchers = []
    for identifier, region, record, table, section, special, slot, threshold, recipients, blocks in SOURCES:
        raw, origin = source('/' + region + '_DATA.BIN')
        pointer = lambda off: struct.unpack_from('<I', raw, off)[0] - BASE
        if (pointer(record + 40), pointer(record + 44), pointer(record + 48)) != (table, section, blocks[0][0]):
            raise ValueError('Area magic actor identity changed: ' + identifier)
        callbacks = [span(raw, origin, *block) for block in blocks]
        if pointer(table + slot * 4) != blocks[3][0]:
            raise ValueError('Area magic callback slot changed: ' + identifier)
        local = {slot: 'enemy_group_magic'}
        if identifier == 'siren':
            local[8] = 'camera_facing'
        if identifier == 'earth_golem':
            local[5] = 'fixed_projectile'
            if normalize_jumps(raw, 0x2a18, 0x2c18) != normalize_jumps(reference, 0x1050, 0x1250):
                raise ValueError('Earth Golem projectile differs from shared fixed projectile')
        prefix = 'melee/' + identifier
        binding = dict(id=identifier)
        roots = []; selected = {0, 1, 3} | ({13, 14, 15, 16} if identifier == 'siren' else set())
        member_programs = []
        for role, offset in [('idle', pointer(table)), ('attack', pointer(table + 4)),
                             ('hurt', pointer(table + 8)), ('dodge', pointer(table + 12)),
                             ('return', pointer(table + 16)), ('special', special)]:
            operations, spans = stream(raw, origin, offset, table, BASE)
            instructions, blocked, effects = compile_operations(operations, prefix, local, identifier)
            if blocked or set(effects) - {'enemy_group_magic'}:
                raise ValueError('Unbound area magic root: ' + identifier + '/' + role)
            name = prefix + '/' + role
            binding[role + '_program'] = name
            programs.append(dict(id=name, instructions=instructions)); member_programs.append(programs[-1])
            proofs.append(dict(id=name, operations=operations, spans=spans))
            roots.append(dict(script=name, operations=operations))
        for role, offset in recipients:
            operations, spans = stream(raw, origin, offset, table, BASE)
            instructions, blocked, effects = compile_operations(operations, prefix)
            if blocked or set(effects) - {'palette_cycle'}:
                raise ValueError('Unbound area magic recipient: ' + identifier + '/' + role)
            name = prefix + '/' + role
            binding[role + '_program'] = name
            programs.append(dict(id=name, instructions=instructions))
            proofs.append(dict(id=name, operations=operations, spans=spans))
        _, children = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table + BASE, BASE)
        for child in children:
            member = child['resource'] == 'member'
            instructions, blocked, effects = compile_operations(child['operations'], prefix if member else None,
                local if member else None, identifier if member else None)
            if blocked or set(effects) - {'fixed_projectile', 'camera_facing'}:
                raise ValueError('Unbound area magic child: ' + identifier + '/' + child['id'])
            name = prefix + '/auxiliary/' + child['id'].replace(':', '_')
            programs.append(dict(id=name, instructions=instructions))
            if member:
                member_programs.append(programs[-1])
            proofs.append(dict(id=name, operations=child['operations'], spans=[
                {k: child[k] for k in ('source', 'source_offset', 'byte_length', 'sha256')}]))
        for program in member_programs:
            for instruction in program['instructions']:
                command = instruction.get('command', {})
                if 'animation' in command:
                    selected.add(command['animation'])
                if command.get('child', {}).get('resource') == identifier:
                    selected.add(command['child']['animation'])
        resource, resource_proof = animation_resource(identifier, raw, origin, selected, section, BASE)
        resources.append(resource); resource_proofs.append(resource_proof)
        owner = roots[-1]['operations']
        install = next(i for i, op in enumerate(owner) if op['op'] == 35)
        clips = {c['id']: [(f['pose'], f['updates']) for f in c['frames']] for c in resource['clips']}
        flags = {c['id']: int(c['advances']) | int(c['loop']) << 1 for c in resource['clips']}
        first_callback = script_events(clips, [(op['op'], tuple(op['args'])) for op in owner[:install + 1]], flags)['duration']
        worker, damage = worker_contract(identifier, raw, bank_sections, bank_raw, selectors)
        actor = dict(
            binding,
            decision=dict(
                group=identifier != 'sorcerer',
                front_threshold=51, secondary_threshold=threshold,
                front_random='modulo_100', secondary_random='floor_draw_times_100_over_32767',
            ),
            special=dict(
                effect='enemy_group_magic', first_callback_update=first_callback,
                admission_guard='all_active_party_unlocked', completion_guard='owner_highlight_clear',
                completion_sets_delay=identifier != 'sorcerer',
                selection_delay=30 if identifier != 'sorcerer' else None,
                warmup_updates=20 if identifier == 'siren' else 0,
                ready_mailboxes=[99, 100] if identifier == 'siren' else [99],
                worker_completion_observed='next_actor_callback',
            ),
            worker=worker,
            damage=damage,
            provenance=dict(
                source=origin, record_source_offset=record, script_table_source_offset=table,
                special_source_offset=special, callbacks=callbacks, resource=resource_proof,
                local_worker_source_offset=blocks[-1][0],
            ),
        )
        actors.append(actor)
        if identifier != 'siren':
            start, end, _ = blocks[3]; words = normalize_jumps(raw, start, end)
            words[0xa4 // 4] = 0  # Relocated worker initializer pointer; all other operands agree.
            dispatchers.append(words)
    if dispatchers[0] != dispatchers[1]:
        raise ValueError('Sorcerer/Golem dispatcher contract changed')
    return dict(
        schema='suikoden-enemy-area-magic/2', admission='qualified',
        unbound_effects=[], actors=actors,
        programs=dict(schema=program_schema(programs), programs=programs),
        animations=dict(schema='suikoden-actor-animations/1', resources=resources),
        provenance=dict(
            producer='export_enemy_area_magic.py v2', programs=proofs, resources=resource_proofs,
            main_consumers=main_proofs, fixed_projectile_reference=fixed_reference,
            scope='Complete static actor, worker, damage/status and art contracts for Sorcerer, Siren and Earth Golem; human visual/audio acceptance and promotion remain separate.',
        ),
    )


def magic_damage(actor, caster_magic, recipient_magic, target_rune, draw, party_slot=0):
    if not 0 <= target_rune <= 255 or not 0 <= party_slot < 6:
        raise ValueError('target rune and party slot must be in range')
    damage = actor['damage']
    fallback = party_slot + 1 if damage.get('fallback_by_slot') else damage['fallback_element']
    selected = damage['target_rune_elements'][target_rune - 1] if 1 <= target_rune <= 31 else 0
    if selected == 0:
        selected = fallback
    return battle_formulas.magic_damage(caster_magic, recipient_magic, draw, damage['element'], selected)


def binding_for_runtime(actor):
    identifier = actor['id']
    return dict(
        id=identifier,
        owner_program=actor['special_program'],
        recipient_program=actor['recipient_1_program'] if identifier == 'siren' else actor['recipient_program'],
        wave_recipient_program=actor.get('recipient_2_program'),
        group=actor['decision']['group'],
        front_reject_below=actor['decision']['front_threshold'],
        special_reject_below=actor['decision']['secondary_threshold'],
        selection_delay=actor['special']['selection_delay'] or 0,
        first_callback_update=actor['special']['first_callback_update'],
        warmup_updates=actor['special']['warmup_updates'],
        ready_mailboxes=actor['special']['ready_mailboxes'],
        worker=copy.deepcopy(actor['worker']),
        **{k: copy.deepcopy(actor['damage'][k]) for k in ('element', 'target_rune_elements', 'fallback_element', 'fallback_by_slot')},
    )


def combine(actors, plan=None):
    """Merge Sorcerer, Siren and Earth Golem ordinary and area-magic bindings."""
    if actors['schema'] not in ('suikoden-unite-actors/37', 'suikoden-unite-actors/38', 'suikoden-unite-actors/39', 'suikoden-unite-actors/40'):
        raise ValueError('Area magic needs the complete shared actor library')
    plan = build() if plan is None else plan
    result = copy.deepcopy(actors)
    merge_libraries(result, plan)
    area_bindings = []
    for actor in plan['actors']:
        identifier = actor['id']
        capability = dict(id=identifier, counterable=False, attack_program=None, return_program=None)
        melee = {k: actor[k] for k in ('id', 'attack_program', 'hurt_program', 'return_program')}
        dodge = dict(id=identifier, response_program=actor['dodge_program'])
        for rows, value in (
            (result['counter']['enemies'], capability),
            (result['counter']['melee']['enemies'], melee),
            (result['counter']['ranged']['dodges'], dodge),
            (result['counter']['party_melee']['dodges'], dodge),
        ):
            previous = next((r for r in rows if r['id'] == identifier), None)
            if previous is None:
                rows.append(copy.deepcopy(value))
            elif previous != value:
                raise ValueError('Conflicting area magic actor binding: ' + identifier)
        area_bindings.append(binding_for_runtime(actor))
    if result.get('enemy_area_magic') not in (None, area_bindings):
        raise ValueError('Conflicting enemy area magic bindings')
    result['enemy_area_magic'] = area_bindings
    result['schema'] = 'suikoden-unite-actors/' + str(max(39, int(actors['schema'].rsplit('/', 1)[1])))
    return result


def append_content(battle, actors, atlas):
    """Admit Sorcerer, Siren and Earth Golem profiles, art and E/G/H formations."""
    import journey_battle
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks
    plan = build()
    ids = [a['id'] for a in plan['actors']]
    if any(row['id'] in ids for row in battle['enemies']):
        raise ValueError('Area magic enemy profile already present')
    combined = combine(actors, plan)
    roots = [(a['id'], value) for a in plan['actors'] for key, value in a.items()
             if key.endswith('_program') and not key.startswith('recipient')]
    art, proof = graphics(
        combined, dict(resources=plan['provenance']['resources']), atlas,
        set(ids), roots, existing_graphics=battle['unite_graphics'],
    )
    battle['unite_graphics'].extend(art)
    art_by_id = {g['id']: g for g in art}
    species = (('e', 2, 'sorcerer'), ('g', 3, 'siren'), ('h', 3, 'earth_golem'))
    catalogue = journey_battle.append_later_enemies(battle, atlas, species)
    policies = {'sorcerer': 'source_sorcerer', 'siren': 'source_siren', 'earth_golem': 'source_earth_golem'}
    for actor in plan['actors']:
        identifier = actor['id']
        raw, _ = source('/' + actor['provenance']['source']['file'].split('/')[-1])
        record = actor['provenance']['record_source_offset']
        profile = next(e for e in battle['enemies'] if e['id'] == identifier)
        profile.update(
            action_policy=policies[identifier],
            target_policy='front_first',
            knockout_ticks=squirrel_knockout_ticks(raw, struct.unpack_from('<I', raw, record + 40)[0] - BASE),
            effect_offset=list(struct.unpack_from('<2h', raw, record + 60)),
        )
        resource = next(r for r in combined['animations']['resources'] if r['id'] == identifier)
        idle = next(c for c in resource['clips'] if c['id'] == 0)['frames'][0]['pose']
        pose = next(p for p in art_by_id[identifier]['poses'] if p['id'] == idle)['sprite']
        profile['sprite'] = copy.deepcopy(pose)
        profile['attack'] = [dict(pose=copy.deepcopy(pose), ticks=1, source_pose=idle)]
    battle['schema'] = 'suikoden-battle-trial/' + str(max(42, int(battle['schema'].rsplit('/', 1)[1])))
    actors.clear()
    actors.update(combined)
    return dict(
        component=plan['provenance'], graphics=proof, catalogue=catalogue,
        scope='Source Sorcerer, Siren and Earth Golem profiles, workers and whole qualified E/G/H formations; field placement, audio and media acceptance remain separate.',
    )


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'kit/work/build/enemy_area_magic/actors.json')
    output = parser.parse_args().output
    if (ROOT / 'kit/work/accepted').resolve() in (output.resolve(), *output.resolve().parents):
        raise ValueError('Area magic components are candidates; promotion is separate')
    packet = build()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(packet, indent=2) + '\n')
    print(output)
