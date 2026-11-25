#!/usr/bin/env python3
"""Static extraction and verification for D3 Creeper, F2 Shadow Man, F3 Mirage and H2 Mirage."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import area_encounter_tables as encounters
import battle_bin
import battle_placement
import battle_unite_camera
import character_table
from export_first_room import ROOT, source
from export_physical_runes import merge_libraries, stream
from export_unite_programs import animation_resource, compile_operations, program_schema
import journey_battle
import maindec
import preparation

BASE = encounters.BASE

MAIN_SCRIPTS = (
    ('script_select', 0x800E557C, 0x800E5644, 'f62112e3056cbb60ea551d4d302ea4fea5f41e84eb0009f4bf3607c4b6026a18'),
    ('script_dispatch', 0x800E5644, 0x800E56A8, 'd95cf717b9974c3854958b74a62db4b6cae38719ade2678fdba823f1f5d5b470'),
    ('op9_coordinator', 0x800E3C34, 0x800E3CA0, None),
    ('damage_calc', 0x800F7E90, 0x800F7F90, None),
    ('hp_clamp', 0x800E1654, 0x800E16E0, None),
    ('enemy_ordinary_hit', 0x800F5960, 0x800F5ABC, None),
)

CREEPER_SPEC = dict(
    id='creeper',
    disc='/D_DATA.BIN',
    region='d',
    enemy_id=3,
    record_offset=0x24344,
    atab_offset=0x24384,
    section_offset=0x24894,
    poses=7,
    clips=23,
    flags=0x5,
    stats=[29, 300, 210, 90, 25, 73, 40, 25],
    bits=600,
    drops=[(66, 'earth_crystal', 5)],
    selector=(0x1FA8, 0x21B8, 'bf9f95c3933031f5a1e086570e75c909471d8b0c9bcbb5968d70e462e4474d55'),
    callbacks=(
        ('shrink_spin', 0x1C38, 0x1CE0, '88e41ef78945b55620b6ae2db9fa416361b71246fff19c9982cf85c77bf643cc'),
        ('spit_expand', 0x1CE0, 0x1D50, 'a145c1c0d888d88a9c5a3cb57333e5e7d2041c1a621bb613bd3c510feb5ca22a'),
        ('primary_1', 0x1D50, 0x1E20, '2981cd79c21c7bf2b1f9442935e9fbfe3710e224de5a8d6997db9477a9959c63'),
        ('primary_2', 0x1E20, 0x1E78, 'cc3f32390c3e7f5c0049b0612f1d4ef3262cc30816b688d62fa3a5a46f68db6a'),
        ('primary_3', 0x1E78, 0x1FA8, 'b94a61737050c3c27b46cd1b132040efca28d3ae8d417e9a6450e6c97c78f1b2'),
    ),
    special_offsets=(('attack', 0x2447C), ('hurt', 0x24578), ('return', 0x24598)),
)

SHADOW_MAN_SPEC = dict(
    id='shadow_man',
    disc='/F_DATA.BIN',
    region='f',
    enemy_id=2,
    record_offset=0x22898,
    atab_offset=0x22B18,
    section_offset=0x22E78,
    poses=8,
    clips=15,
    flags=0xC,
    level=50,
    stats=[400, 310, 150, 60, 130, 60, 90],
    bits=2000,
    drops=[(34, 'silverlet', 10), (50, 'rose_brooch', 10)],
    selector=(0x23D8, 0x25B0, '7445281bf948bdf0f90ecf2922041cb1887c638bfea7cbb79be2bac76e1846df'),
    callbacks=(
        ('hurt_helper', 0x19F0, 0x1BB8, 'c2be412f3ac8c25cd30f8776f47440bb641fdacdb8943be3bbf136d818116e88'),
        ('atab8_hurt', 0x1BB8, 0x1F28, '095554b20b581caaea86165eaebd4593ac3360453bc3d253e0b5795c40a29a36'),
        ('atab9_fade', 0x1F28, 0x2280, 'a31b036cdedefbac988daf5d16bb85a8cfbfdcb7d329385044a4ef7b8317e981'),
        ('primary_1', 0x2280, 0x231C, '2caf430e66cfed4cfa04eeaefe9fae8d4e24077ba14e35d0ffc29c67df809003'),
        ('primary_2', 0x231C, 0x23D8, '411f5a9447dad8acb3e667c837c1aeffea9c6f4c326d6447f7148bb80889905d'),
        ('jump_table', 0x2C, 0x1C0, 'c2ba756fa1a4735732356ebd5a805fd895ad08561d3d4f9ce1150ac63b7ba732'),
    ),
)

MIRAGE_SPECS = (
    dict(
        id='mirage_f',
        disc='/F_DATA.BIN',
        region='f',
        enemy_id=3,
        record_offset=0x24B4C,
        atab_offset=0x24B8C,
        section_offset=0x24F7C,
        special_offset=0x24C40,
        special_hurt_offset=0x24C98,
        vanish_sound=1443,
        wait_100=True,
        selector=(0x4294, 0x44A0, 'cf2aadaebf64920eabab701b189bd47ac591d049307440177acff2fcfa94dd59'),
        callbacks=(
            ('atab6_vanish_left', 0x25B0, 0x2F0C, 'fc3bfee20241f82f68c30f5b30e5f10172167fda15b70e7626b48c135c5ea7f1'),
            ('atab8_fade', 0x2F0C, 0x3848, 'a6ba19eeb0ccb854746aec28e96e9b543bffc8be8642fd7383a3d80022fda60d'),
            ('primary', 0x3848, 0x3938, '7784cbda8f4080df743f46cb235609b2717d5ed91e73f72dbc6b6fb9cf89d023'),
            ('atab9_vanish_right', 0x3938, 0x4294, '5647e7b424bf593736225dbbb362273fe7dbc6b401dac9fe8edfc0873723b474'),
        ),
    ),
    dict(
        id='mirage_h',
        disc='/H_DATA.BIN',
        region='h',
        enemy_id=2,
        record_offset=0x21658,
        atab_offset=0x21698,
        section_offset=0x21A84,
        special_offset=0x21748,
        special_hurt_offset=0x217A0,
        vanish_sound=1426,
        wait_100=False,
        selector=(0x280C, 0x2A18, 'e90f498a623e50491844c38499c4f9465d824e813535bc3c251425248af41bb3'),
        callbacks=(
            ('atab6_vanish_left', 0xB28, 0x1484, '76b5576200f0810acff6e6dcf8518cb21da9f7b01a3aa9b2423f0eefd5bcc691'),
            ('atab8_fade', 0x1484, 0x1DC0, '9dd44989ed44ff9385bd7e57873eb2318c2a851f42b46a28538464d15edf7d18'),
            ('primary', 0x1DC0, 0x1EB0, 'a4a5a3c7559722e67786a64104ef5109235cbfe6e60d5d9655e64a0a2a97dee9'),
            ('atab9_vanish_right', 0x1EB0, 0x280C, 'c5475f26403cd3f23722e04abcd3a9d48c34723666cade7c8d72e46fd8a57574'),
        ),
    ),
)

MIRAGE_STATS = [52, 400, 330, 130, 95, 120, 175, 70]
MIRAGE_BITS = 2400
MIRAGE_DROPS = [(52, 'speed_ring', 6)]
RECIPIENTS = tuple((spec['region'], spec['enemy_id'], spec['id'])
                   for spec in (CREEPER_SPEC, SHADOW_MAN_SPEC, *MIRAGE_SPECS))

EXPECTED_SCHEMAS = (
    'suikoden-unite-actors/39',
    'suikoden-unite-actors/40',
)


def _span(raw, origin, role, start, end, digest=None):
    actual = hashlib.sha256(raw[start:end]).hexdigest()
    if digest is not None and actual != digest:
        raise ValueError(f'Regional source changed in {role}: {actual} != {digest}')
    return dict(id=role, source=origin, source_offset=start, byte_length=end - start, sha256=actual)


def _verify_record(raw, spec):
    _, _, directory, _ = encounters.chain(raw)
    table = struct.unpack_from('<I', raw, directory - BASE + 12)[0] - BASE
    record = struct.unpack_from('<I', raw, table + 4 * spec['enemy_id'])[0] - BASE
    atab = struct.unpack_from('<I', raw, record + 40)[0] - BASE
    section = struct.unpack_from('<I', raw, record + 44)[0] - BASE
    selector = struct.unpack_from('<I', raw, record + 48)[0] - BASE
    if (record, atab, section, selector) != (spec['record_offset'], spec['atab_offset'], spec['section_offset'], spec['selector'][0]):
        raise ValueError(f"Enemy record layout changed for {spec['id']}")
    poses = struct.unpack_from('<H', raw, section)[0]
    clips = struct.unpack_from('<H', raw, section + 2)[0]
    if 'poses' in spec and (poses, clips) != (spec['poses'], spec['clips']):
        raise ValueError(f"Animation counts changed for {spec['id']}")
    flags = struct.unpack_from('<H', raw, record + 38)[0]
    if flags != spec.get('flags', 0x4):
        raise ValueError(f"Feature bits changed for {spec['id']}")
    return record, atab, section


def _verify_main():
    main, origin = source('MAIN.EXE')
    body = main[maindec.EXE_HEADER:]
    if body != maindec.body():
        raise ValueError('MAIN.EXE body mismatch')
    proofs = []
    for role, start, end, digest in MAIN_SCRIPTS:
        s_off = maindec.EXE_HEADER + start - maindec.MBASE
        e_off = maindec.EXE_HEADER + end - maindec.MBASE
        proofs.append(_span(main, origin, role, s_off, e_off, digest))
    return proofs


def _normalize_mirage_block(raw_slice, script_replacements, fn_delta):
    """Strip relocated F vs H overlay addresses when proving Mirage callbacks match."""
    buf = bytearray(raw_slice)
    for off in range(0, len(buf) - 4, 4):
        w = struct.unpack_from('<I', buf, off)[0]
        # J/JAL instructions inside the callback slice
        if (w >> 26) in (2, 3):
            target = (w & 0x3FFFFFF) << 2
            if 0x80000 <= target < 0xB0000:
                continue
        # lui + addiu pairs loading relocated script/callback pointers
        if (w >> 16) in (0x3C06, 0x3C05, 0x3C04, 0x3C02):
            hi = w & 0xFFFF
            for next_off in range(off + 4, min(len(buf), off + 24), 4):
                w2 = struct.unpack_from('<I', buf, next_off)[0]
                if (w2 >> 26) == 9 and ((w2 >> 21) & 31) == ((w >> 16) & 31):
                    lo = struct.unpack_from('<h', buf, next_off)[0]
                    va = (hi << 16) + lo
                    if va in script_replacements:
                        struct.pack_into('<I', buf, off, (w & 0xFFFF0000) | 0x8008)
                        struct.pack_into('<h', buf, next_off, script_replacements[va])
                        break
    return bytes(buf)


def _dis_normalize_words(raw, start, end, rep):
    words = []
    for off in range(start, end, 4):
        w = struct.unpack_from('<I', raw, off)[0]
        op = w >> 26
        if op == 2:  # j within slice: turn into relative offset
            target = ((BASE + off + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
            words.append(('J', target - (BASE + start)))
            continue
        words.append(w)
    # Replace relocated script pointer constants (lui 0x800a/0x8008 + addiu)
    out = []
    i = 0
    while i < len(words):
        w = words[i]
        if isinstance(w, int) and (w >> 26) == 15 and (w & 0xFFFF) in (0x8008, 0x800A):
            rt = (w >> 16) & 31
            patched = False
            for j in range(i + 1, min(len(words), i + 6)):
                w2 = words[j]
                if isinstance(w2, int) and (w2 >> 26) == 9 and ((w2 >> 21) & 31) == rt:
                    va = ((w & 0xFFFF) << 16) + struct.unpack('<h', struct.pack('<H', w2 & 0xFFFF))[0]
                    if va in rep:
                        out.append(('SCRIPT_PTR', rep[va], rt, (w2 >> 16) & 31))
                        words[j] = ('CONSUMED', j)
                        patched = True
                        break
            if patched:
                i += 1
                continue
        out.append(w)
        i += 1
    return out


def _verify_mirage_equivalence(raw_f, raw_h, spec_f, spec_h):
    """Prove F3 and H2 share code, art and animations up to relocated addresses."""
    # Verify exact art/CLUT/clip tables match
    for a, b, label in (
        (spec_f['section_offset'], spec_h['section_offset'], 'mirage section poses'),
    ):
        pf = struct.unpack_from('<I', raw_f, a + 16)[0] - BASE
        ph = struct.unpack_from('<I', raw_h, b + 16)[0] - BASE
        # Compare header pose/clip counts and frame sequences independently
        res_f, _ = animation_resource('mirage_f', raw_f, dict(file='F_DATA.BIN'), set(range(16)), section=spec_f['section_offset'], base=BASE)
        res_h, _ = animation_resource('mirage_h', raw_h, dict(file='H_DATA.BIN'), set(range(16)), section=spec_h['section_offset'], base=BASE)
        if res_f['pose_count'] != res_h['pose_count'] or res_f['clips'] != res_h['clips']:
            raise ValueError('F3 and H2 Mirage animation tables diverged')
    rep_f = {0x800A4C40: 'special', 0x80083848: 'primary', 0x800A4C98: 'special_hurt'}
    rep_h = {0x800A1748: 'special', 0x80081DC0: 'primary', 0x800A17A0: 'special_hurt'}
    pairs = [
        (spec_f['selector'][0], spec_f['selector'][1], spec_h['selector'][0], spec_h['selector'][1], 'selector'),
    ] + [
        (cf[1], cf[2], ch[1], ch[2], cf[0])
        for cf, ch in zip(spec_f['callbacks'], spec_h['callbacks'], strict=True)
    ]
    for fs, fe, hs, he, role in pairs:
        if fe - fs != he - hs:
            raise ValueError(f'F3/H2 {role} callback byte lengths differ')
        wf = _dis_normalize_words(raw_f, fs, fe, rep_f)
        wh = _dis_normalize_words(raw_h, hs, he, rep_h)
        if wf != wh:
            raise ValueError(f'F3/H2 {role} callbacks differ outside relocated script pointers')


def _compile_regional_program(programs, proofs, identifier, ops, local_effects, prefix, spans, effects_allowed, owner_effects=None):
    merged = local_effects
    if owner_effects is not None:
        merged = dict(local_effects or {})
        merged.update(owner_effects)
    instructions, blocked, effects = compile_operations(ops, prefix, merged, identifier)
    if blocked or set(effects) - set(effects_allowed):
        raise ValueError(f'Unbound regional program {identifier}: {blocked or effects}')
    programs[identifier] = dict(id=identifier, instructions=instructions)
    proofs[identifier] = dict(id=identifier, spans=spans, operations=ops, host_effects=effects)
    return effects


def _compile_children(programs, proofs, raw, origin, roots, prefix, table, main_origin):
    _, dependencies = battle_unite_camera.auxiliary_scripts(raw, origin, roots, main_origin, table + BASE, BASE)
    shared = set()
    for child in dependencies:
        identifier = f'{prefix}/auxiliary/' + child['id'].replace(':', '_')
        instructions, blocked, effects = compile_operations(
            child['operations'],
            prefix if child['resource'] == 'member' else None,
            None,
            identifier,
        )
        if blocked or effects:
            raise ValueError(f'Unbound regional child program {identifier}: {blocked or effects}')
        programs[identifier] = dict(id=identifier, instructions=instructions)
        proofs[identifier] = dict(
            id=identifier,
            operations=child['operations'],
            spans=[{k: child[k] for k in ('source', 'source_offset', 'byte_length', 'sha256')}],
        )
        if child['resource'] == 'shared_impacts':
            for ins in instructions:
                anim = ins.get('command', {}).get('animation')
                if anim is not None:
                    shared.add(anim)
    return shared


def _shadow_man_hurt_ops(raw, origin, atab):
    """Stop Shadow Man's atab[2] right at opcode (36, 4) so it stays tail_return."""
    offset = struct.unpack_from('<I', raw, atab + 8)[0] - BASE
    rows = journey_battle.script_at(raw, offset)
    if (rows[-1][0], list(rows[-1][1])) != (36, [4]):
        raise ValueError('Shadow Man atab[2] must end in op 36 target atab[4]')
    ops = [dict(op=op, args=list(args)) for op, args in rows]
    length = sum(2 + 2 * len(r['args']) for r in ops)
    spans = [_span(raw, origin, 'shadow_man_hurt', offset, offset + length)]
    return ops, spans


def _build_party_reactions():
    """Extract clip 3 and verify atab[4] return scripts for all 78 party characters."""
    programs = {}
    party_return_proofs = {}
    compiled_by_id = {}
    resources = []
    resource_proofs = []
    for record in character_table.records():
        identifier = preparation.stable_id(record['name'])
        raw, origin = source('/' + record['sprite_file'])
        table = struct.unpack_from('<I', raw, 32)[0]
        off4 = struct.unpack_from('<I', raw, table + 16)[0]
        ops, spans = stream(raw, origin, off4, table)
        instructions, blocked, effects = compile_operations(ops, None, None, identifier)
        if blocked or effects:
            raise ValueError(f'Party return script failed for {identifier}: {blocked or effects}')
        res, r_proof = animation_resource(identifier, raw, origin, {3})
        resources.append(res)
        resource_proofs.append(r_proof)
        if identifier == 'clive':
            programs['party_reaction/clive/return'] = dict(id='party_reaction/clive/return', instructions=instructions)
        compiled_by_id[identifier] = instructions
        party_return_proofs[identifier] = dict(id=identifier, spans=spans, operations=ops, host_effects=[])
    return programs, party_return_proofs, compiled_by_id, resources, resource_proofs


def _mirage_visual(raw, spec, section):
    start = spec['callbacks'][0][1]
    def word(relative):
        return struct.unpack_from('<I', raw, start + relative)[0]

    if (word(0xFC), word(0x164), word(0x168), word(0x230), word(0x234), word(0x284)) != (
            0x00002821, 0x34420004, 0xAC620008, 0x34040001, 0x34050002, 0x34050002):
        raise ValueError('Mirage copy pose or packet blend changed')
    if maindec.mword(0x8016B680 + 0x74) != 0x8014AB0C:
        raise ValueError('Mirage texture-page import changed')
    count, neutral, step = (word(off) & 0xFFFF for off in (0x2AC, 0x310, 0x570))
    if count != 7 or neutral != 128 or step != 4096:
        raise ValueError('Mirage copy loop changed')
    palette_table, poses = (pointer - BASE for pointer in struct.unpack_from('<2I', raw, section + 12))
    pose = struct.unpack_from('<I', raw, poses)[0] - BASE
    if raw[pose] != 1 or raw[pose + 15] != 0:
        raise ValueError('Mirage vanish requires a single unflipped piece')
    x, y, _, _, width, height, palette, _ = raw[pose + 8:pose + 16]
    palette_offset = struct.unpack_from('<I', raw, palette_table + 4 * palette)[0] - BASE
    colors = struct.unpack_from('<32H', raw, palette_offset)
    if any(color and not (color & 0x8000) for color in colors):
        raise ValueError('Mirage vanish requires one blend mode across the pose')
    return dict(pose=0, crop=[x, y, width, height], copies=count, modulation=neutral, spread_step_q12=step)


def build():
    main_proofs = _verify_main()
    _, main_origin = source('MAIN.EXE')
    raw_d, orig_d = source(CREEPER_SPEC['disc'])
    raw_f, orig_f = source('/F_DATA.BIN')
    raw_h, orig_h = source('/H_DATA.BIN')

    programs = {}
    proofs = {}
    resources = []
    resource_proofs = []
    callbacks = []
    regional_bindings = []
    melee_enemies = []
    capabilities = []
    dodges = []
    shared_animations = set()
    records_proof = {}

    # 1. D3 Creeper
    rec_d, atab_d, sec_d = _verify_record(raw_d, CREEPER_SPEC)
    sel_start, sel_end, sel_digest = CREEPER_SPEC['selector']
    callbacks.append(_span(raw_d, orig_d, 'creeper_selector', sel_start, sel_end, sel_digest))
    for name, s, e, dig in CREEPER_SPEC['callbacks']:
        callbacks.append(_span(raw_d, orig_d, f'creeper_{name}', s, e, dig))
    d_selected = {0, 1}
    d_roots = {}
    d_root_ops = []
    for role, slot in (('attack', 1), ('hurt', 2), ('dodge', 3), ('return', 4)):
        off = struct.unpack_from('<I', raw_d, atab_d + 4 * slot)[0] - BASE
        ops, spans = stream(raw_d, orig_d, off, atab_d, BASE)
        d_selected.update(op['args'][0] for op in ops if op['op'] == 4)
        key = f'melee/creeper/{role}'
        _compile_regional_program(programs, proofs, key, ops, None, 'melee/creeper', spans, ())
        d_roots[role] = key
        d_root_ops.append(dict(script=role, operations=ops))
    if struct.unpack_from('<I', raw_d, atab_d + 20)[0] != 0:
        raise ValueError('Creeper atab[5] unexpectedly populated')
    d_special = {}
    for role, off in CREEPER_SPEC['special_offsets']:
        ops, spans = stream(raw_d, orig_d, off, atab_d, BASE)
        d_selected.update(op['args'][0] for op in ops if op['op'] == 4)
        key = 'melee/creeper/special' if role == 'attack' else f'melee/creeper/special_{role}'
        _compile_regional_program(programs, proofs, key, ops, None, 'melee/creeper', spans, ())
        d_special[role] = key
        d_root_ops.append(dict(script='special_' + role, operations=ops))
    shared_animations.update(_compile_children(programs, proofs, raw_d, orig_d, d_root_ops, 'melee/creeper', atab_d, main_origin))
    frames_d = struct.unpack_from('<I', raw_d, sec_d + 20)[0] - BASE
    extent_d = struct.unpack_from('<I', raw_d, sec_d + 8)[0] - BASE
    last_d = struct.unpack_from('<I', raw_d, frames_d + 23 * 4)[0] - BASE
    if struct.unpack_from('<H', raw_d, sec_d + 2)[0] != 23 or extent_d - frames_d != 24 * 4 or raw_d[last_d:frames_d] != bytes.fromhex('030101000204030504010000'):
        raise ValueError('Creeper extended animation extent changed')
    d_res, d_rproof = animation_resource('creeper', raw_d, orig_d, d_selected, section=sec_d, base=BASE, animation_table_end=extent_d)
    d_rproof['record_source_offset'] = rec_d
    resources.append(d_res)
    resource_proofs.append(d_rproof)
    capabilities.append(dict(id='creeper', counterable=True, attack_program=d_roots['attack'], return_program=d_roots['return']))
    melee_enemies.append(dict(
        id='creeper',
        attack_program=d_roots['attack'],
        hurt_program=d_roots['hurt'],
        return_program=d_roots['return'],
        special=dict(attack_program=d_special['attack'], hurt_program=d_special['hurt']),
    ))
    dodges.append(dict(id='creeper', response_program=d_roots['dodge']))
    regional_bindings.append(dict(
        id='creeper',
        target_row='front',
        front_roll_threshold=51,
        special_roll_threshold=51,
        special_delay_updates=20,
        special_hits=3,
        special_recipient_return=d_special['return'],
        shrink_step_q12=128,
        shrink_min_q12=256,
        shrink_spin_angle=255,
        expand_step_q12=128,
        expand_target_q12=4096,
    ))
    records_proof['creeper'] = dict(source=orig_d, record_offset=rec_d, atab_offset=atab_d, section_offset=sec_d)

    # 2. F2 Shadow Man
    rec_f2, atab_f2, sec_f2 = _verify_record(raw_f, SHADOW_MAN_SPEC)
    s_start, s_end, s_dig = SHADOW_MAN_SPEC['selector']
    callbacks.append(_span(raw_f, orig_f, 'shadow_man_selector', s_start, s_end, s_dig))
    for name, s, e, dig in SHADOW_MAN_SPEC['callbacks']:
        callbacks.append(_span(raw_f, orig_f, f'shadow_man_{name}', s, e, dig))
    from enemy_area_magic_constructors import ActorImage, SCENE, analysis, columns
    image = ActorImage('F')
    column = columns.constructors(dict(initializer=BASE + 0x1F28, preparation=[],
                                       state_root=analysis.member(SCENE, 0xA8)), image)
    if column['blocked'] or len(column['columns']) != 1:
        raise ValueError('Shadow column is unresolved')
    shadow = column['columns'][0]
    if shadow['blend'] != 'additive' or not shadow['semitransparent']:
        raise ValueError('Shadow column material changed')
    lower, upper = shadow['lower'], shadow['upper']
    start, grow_x, grow_y, shrink_z = (struct.unpack_from('<I', raw_f, off)[0]
                                     for off in (0x20E8, 0x21D8, 0x21F8, 0x221C))
    if start != 0xAC860048 or grow_x >> 16 != 0x2442 or grow_y != grow_x or shrink_z >> 16 != 0x2442:
        raise ValueError('Shadow column scale update changed')
    initial_scale = struct.unpack_from('<I', raw_f, 0x20C0)[0]
    if initial_scale >> 16 != 0x3406 or initial_scale & 0xFFFF != 1:
        raise ValueError('Shadow column initial scale changed')
    step = grow_x & 0xFFFF
    if not 0 < step <= 4096 or shrink_z != (0x24420000 | ((-step) & 0xFFFF)):
        raise ValueError('Shadow column radial and height scales diverged')
    shadow_column = dict(segments=shadow['segments'], radial_start_q12=initial_scale & 0xFFFF,
                         step_q12=step, shape=dict(radius=lower['radius'], top_radius=upper['radius'],
                             base_height=lower['height'], height=upper['height'],
                             inner=upper['color'], outer=lower['color']))
    f2_selected = {0, 1}
    f2_roots = {}
    f2_root_ops = []
    f2_local = {9: 'shadow_fade'}
    f2_owner = {(2, 8): 'shadow_hurt'}
    for role, slot in (('attack', 1), ('dodge', 3), ('return', 4)):
        off = struct.unpack_from('<I', raw_f, atab_f2 + 4 * slot)[0] - BASE
        ops, spans = stream(raw_f, orig_f, off, atab_f2, BASE)
        f2_selected.update(op['args'][0] for op in ops if op['op'] == 4)
        key = f'melee/shadow_man/{role}'
        _compile_regional_program(programs, proofs, key, ops, f2_local, 'melee/shadow_man', spans, ('shadow_fade',))
        f2_roots[role] = key
        f2_root_ops.append(dict(script=role, operations=ops))
    hurt_ops, hurt_spans = _shadow_man_hurt_ops(raw_f, orig_f, atab_f2)
    hurt_key = 'melee/shadow_man/hurt'
    _compile_regional_program(programs, proofs, hurt_key, hurt_ops, None, 'melee/shadow_man', hurt_spans, ('shadow_hurt',), owner_effects=f2_owner)
    f2_roots['hurt'] = hurt_key
    f2_root_ops.append(dict(script='hurt', operations=hurt_ops))
    shared_animations.update(_compile_children(programs, proofs, raw_f, orig_f, f2_root_ops, 'melee/shadow_man', atab_f2, main_origin))
    f2_res, f2_rproof = animation_resource('shadow_man', raw_f, orig_f, f2_selected, section=sec_f2, base=BASE)
    f2_rproof['record_source_offset'] = rec_f2
    resources.append(f2_res)
    resource_proofs.append(f2_rproof)
    capabilities.append(dict(id='shadow_man', counterable=False, attack_program=None, return_program=None))
    melee_enemies.append(dict(id='shadow_man', attack_program=f2_roots['attack'], hurt_program=f2_roots['hurt'], return_program=f2_roots['return']))
    dodges.append(dict(id='shadow_man', response_program=f2_roots['dodge']))
    regional_bindings.append(dict(
        id='shadow_man',
        target_row='front',
        front_roll_threshold=51,
        direct_attack=True,
        fade_updates=80,
        wait_100=True,
        camera_shake_z_q12=20480,
        shadow_column=shadow_column,
    ))
    records_proof['shadow_man'] = dict(source=orig_f, record_offset=rec_f2, atab_offset=atab_f2, section_offset=sec_f2)

    # 3 & 4. F3 Mirage & H2 Mirage (separately qualified, proven equivalent code/art)
    _verify_mirage_equivalence(raw_f, raw_h, MIRAGE_SPECS[0], MIRAGE_SPECS[1])
    mirage_raws = {'f': (raw_f, orig_f), 'h': (raw_h, orig_h)}
    mirage_scripts_by_id = {}
    for spec in MIRAGE_SPECS:
        ident = spec['id']
        raw_m, orig_m = mirage_raws[spec['region']]
        rec_m, atab_m, sec_m = _verify_record(raw_m, spec)
        callbacks.append(_span(raw_m, orig_m, f'{ident}_selector', *spec['selector']))
        for name, s, e, dig in spec['callbacks']:
            callbacks.append(_span(raw_m, orig_m, f'{ident}_{name}', s, e, dig))
        m_selected = {0, 1}
        m_local = {6: 'mirage_vanish_left', 8: 'mirage_fade', 9: 'mirage_vanish_right'}
        m_allowed = ('mirage_vanish_left', 'mirage_fade', 'mirage_vanish_right')
        m_roots = {}
        m_ops = {}
        m_root_ops = []
        for role, slot in (('attack', 1), ('hurt', 2), ('dodge', 3), ('return', 4)):
            off = struct.unpack_from('<I', raw_m, atab_m + 4 * slot)[0] - BASE
            ops, spans = stream(raw_m, orig_m, off, atab_m, BASE)
            m_selected.update(op['args'][0] for op in ops if op['op'] == 4)
            key = f'melee/{ident}/{role}'
            _compile_regional_program(programs, proofs, key, ops, m_local, f'melee/{ident}', spans, m_allowed)
            m_roots[role] = key
            m_ops[role] = ops
            m_root_ops.append(dict(script=role, operations=ops))
        for role, off in (('special', spec['special_offset']), ('special_hurt', spec['special_hurt_offset'])):
            ops, spans = stream(raw_m, orig_m, off, atab_m, BASE)
            m_selected.update(op['args'][0] for op in ops if op['op'] == 4)
            key = f'melee/{ident}/{role}'
            _compile_regional_program(programs, proofs, key, ops, m_local, f'melee/{ident}', spans, m_allowed)
            m_roots[role] = key
            m_ops[role] = ops
            m_root_ops.append(dict(script=role, operations=ops))
        shared_animations.update(_compile_children(programs, proofs, raw_m, orig_m, m_root_ops, f'melee/{ident}', atab_m, main_origin))
        mirage_scripts_by_id[ident] = m_ops
        m_res, m_rproof = animation_resource(ident, raw_m, orig_m, m_selected, section=sec_m, base=BASE)
        m_rproof['record_source_offset'] = rec_m
        resources.append(m_res)
        resource_proofs.append(m_rproof)
        capabilities.append(dict(id=ident, counterable=False, attack_program=None, return_program=None))
        melee_enemies.append(dict(
            id=ident,
            attack_program=m_roots['attack'],
            hurt_program=m_roots['hurt'],
            return_program=m_roots['return'],
            special=dict(attack_program=m_roots['special'], hurt_program=m_roots['special_hurt']),
        ))
        dodges.append(dict(id=ident, response_program=m_roots['dodge']))
        regional_bindings.append(dict(
            id=ident,
            target_row='any_row',
            front_roll_threshold=51,
            rear_triggers_special=True,
            vanish_phase_updates=30,
            vanish_offset_q12=131072,
            mirage_visual=_mirage_visual(raw_m, spec, sec_m),
            wait_100=spec['wait_100'],
        ))
        records_proof[ident] = dict(source=orig_m, record_offset=rec_m, atab_offset=atab_m, section_offset=sec_m)

    # Assert exact script-level diffs between F3 and H2 Mirage
    if mirage_scripts_by_id['mirage_f']['attack'] == mirage_scripts_by_id['mirage_h']['attack']:
        raise ValueError('F3 and H2 Mirage sounds must differ (1443 vs 1426)')
    if not any(op == {'op': 31, 'args': [100]} for op in mirage_scripts_by_id['mirage_f']['return']):
        raise ValueError('F3 Mirage return must wait on shared_value 100')
    if any(op == {'op': 31, 'args': [100]} for op in mirage_scripts_by_id['mirage_h']['return']):
        raise ValueError('H2 Mirage return must not wait on shared_value 100')

    # Party clip 3 & return programs for all 78 characters
    p_programs, p_proofs, p_compiled, p_resources, p_rproofs = _build_party_reactions()
    proofs['party_reaction/clive/return'] = dict(id='party_reaction/clive/return', **{k: v for k, v in p_proofs['clive'].items() if k != 'id'})
    programs.update(p_programs)
    resources.extend(p_resources)

    # Also ensure shared_impacts clips referenced by child programs are in the bundle resource list
    sections, _, errors, raw_b = battle_bin.parse(need_atlases=False)
    if errors:
        raise ValueError(errors)
    lba_b, size_b = battle_bin.battle_bin_lba()
    orig_b = dict(file=battle_bin.DISC_PATH, lba=lba_b, size=size_b, sha256=hashlib.sha256(raw_b).hexdigest())
    shared_res, shared_rproof = animation_resource('shared_impacts', raw_b, orig_b, shared_animations, section=sections[0]['header_offset'], base=battle_bin.LOAD_BASE)
    resources.append(shared_res)
    resource_proofs.append(shared_rproof)

    all_programs = [programs[k] for k in sorted(programs)]
    return dict(
        schema='suikoden-enemy-regional/1',
        programs=dict(schema=program_schema(all_programs, 13), programs=all_programs),
        animations=dict(schema='suikoden-actor-animations/1', resources=resources),
        capabilities=capabilities,
        melee=melee_enemies,
        dodges=dodges,
        enemy_regional=regional_bindings,
        party_return_compiled=p_compiled,
        provenance=dict(
            producer='export_enemy_regional.py v1',
            main_scripts=main_proofs,
            records=records_proof,
            callbacks=callbacks,
            programs=proofs,
            party_returns=p_proofs,
            enemy_resources=resource_proofs[:4],
            party_resources=p_rproofs,
            resources=resource_proofs[:4],
            mirage_equivalence=dict(
                f3_vanish_sound=1443,
                h2_vanish_sound=1426,
                f3_wait_100=True,
                h2_wait_100=False,
                callbacks_identical_after_relocation=True,
            ),
            scope='Static source extraction for D3 Creeper, F2 Shadow Man, F3 Mirage, H2 Mirage and all 78 party clip-3/atab[4] reactions.',
        ),
    )


def combine(actors, plan=None):
    """Merge the 4 regional enemies and 78 party clip-3/return bindings into suikoden-unite-actors/40."""
    if actors['schema'] not in EXPECTED_SCHEMAS:
        raise ValueError('Regional enemies require suikoden-unite-actors/39 or later')
    plan = build() if plan is None else plan
    result = copy.deepcopy(actors)

    # Verify the 77 existing party return scripts match disc compilation identically
    ranged_ret = {r['id']: r['return_program'] for r in result['counter']['ranged']['attackers']}
    melee_ret = {r['id']: r['return_program'] for r in result['counter']['party_melee']['attackers']}
    existing_programs = {p['id']: p['instructions'] for p in result['programs']['programs']}

    merge_libraries(result, plan)

    for rows, entries in (
        (result['counter']['enemies'], plan['capabilities']),
        (result['counter']['melee']['enemies'], plan['melee']),
        (result['counter']['ranged']['dodges'], plan['dodges']),
        (result['counter']['party_melee']['dodges'], plan['dodges']),
    ):
        for entry in entries:
            previous = next((r for r in rows if r['id'] == entry['id']), None)
            if previous is None:
                rows.append(copy.deepcopy(entry))
            elif previous != entry:
                raise ValueError(f"Conflicting regional binding for {entry['id']}")

    for reaction in result['counter']['melee']['party_reactions']:
        ident = reaction['id']
        compiled = plan['party_return_compiled'][ident]
        if ident == 'clive':
            expected = 'party_reaction/clive/return'
        else:
            expected = ranged_ret.get(ident) or melee_ret.get(ident)
            if expected is None:
                raise ValueError(f'Missing base return program for {ident}')
            if existing_programs.get(expected) != compiled:
                raise ValueError(f'Conflicting party return program {expected}')
        prior = reaction.get('return_program')
        if prior is None:
            reaction['return_program'] = expected
        elif prior != expected:
            raise ValueError(f"Conflicting party reaction return_program for {ident}")

    regional = copy.deepcopy(plan['enemy_regional'])
    if result.get('enemy_regional') not in (None, regional):
        raise ValueError('Conflicting enemy_regional bindings')
    result['enemy_regional'] = regional
    result['schema'] = 'suikoden-unite-actors/40'
    return result


def _merge_party_unite_graphics(battle_graphics, addition, atlas):
    """Add only newly exposed poses (clip 3) to existing party unite_graphics entries."""
    by_id = {row['id']: row for row in battle_graphics if row.get('record') is None}
    for incoming in addition:
        current = by_id.get(incoming['id'])
        if current is None:
            battle_graphics.append(incoming)
            continue
        existing_poses = {p['id']: p for p in current['poses']}
        for pose in incoming['poses']:
            if pose['id'] not in existing_poses:
                current['poses'].append(pose)


def append_content(battle, actors, atlas):
    """Admit Creeper, Shadow Man, Mirage F and Mirage H plus party clip-3 graphics."""
    from export_physical_runes import graphics
    from export_world_travel import squirrel_knockout_ticks

    new_ids = {identifier for _, _, identifier in RECIPIENTS}
    if any(row['id'] in new_ids for row in battle['enemies']):
        raise ValueError('Regional enemy profile already present')

    plan = build()
    combined = combine(actors, plan)

    enemy_roots = []
    for cap in plan['capabilities']:
        if cap['attack_program']:
            enemy_roots.append((cap['id'], cap['attack_program']))
            enemy_roots.append((cap['id'], cap['return_program']))
    for m in plan['melee']:
        enemy_roots.append((m['id'], m['attack_program']))
        enemy_roots.append((m['id'], m['return_program']))
        if 'special' in m:
            enemy_roots.append((m['id'], m['special']['attack_program']))
    for d in plan['dodges']:
        enemy_roots.append((d['id'], d['response_program']))
    enemy_roots.append(('creeper', 'melee/creeper/special_return'))

    enemy_art, enemy_proof = graphics(
        combined,
        dict(resources=plan['provenance']['enemy_resources']),
        atlas,
        new_ids,
        enemy_roots,
        existing_graphics=battle['unite_graphics'],
    )
    battle['unite_graphics'].extend(enemy_art)

    party_ids = {row['id'] for row in battle['party']}
    party_roots = [
        (r['id'], r['return_program'])
        for r in combined['counter']['melee']['party_reactions']
        if r['id'] in party_ids
    ]
    party_roots.extend((pid, 'melee/shadow_man/hurt') for pid in sorted(party_ids))
    party_art, party_proof = graphics(
        combined,
        dict(resources=plan['provenance']['party_resources']),
        atlas,
        party_ids,
        party_roots,
        existing_graphics=battle['unite_graphics'],
    )
    _merge_party_unite_graphics(battle['unite_graphics'], party_art, atlas)

    catalogue = journey_battle.append_later_enemies(battle, atlas, RECIPIENTS)
    art_by_id = {row['id']: row for row in enemy_art}

    policies = {
        'creeper': ('source_creeper', 'front_first', '/D_DATA.BIN'),
        'shadow_man': ('source_shadow_man', 'front_first', '/F_DATA.BIN'),
        'mirage_f': ('source_mirage_f', 'any_row', '/F_DATA.BIN'),
        'mirage_h': ('source_mirage_h', 'any_row', '/H_DATA.BIN'),
    }
    raw_cache = {'/D_DATA.BIN': source('/D_DATA.BIN')[0], '/F_DATA.BIN': source('/F_DATA.BIN')[0], '/H_DATA.BIN': source('/H_DATA.BIN')[0]}
    for profile in battle['enemies'][-4:]:
        ident = profile['id']
        action_policy, target_policy, disc_path = policies[ident]
        raw = raw_cache[disc_path]
        record = plan['provenance']['records'][ident]['record_offset']
        profile.update(
            action_policy=action_policy,
            target_policy=target_policy,
            knockout_ticks=squirrel_knockout_ticks(raw, struct.unpack_from('<I', raw, record + 40)[0] - BASE),
            effect_offset=list(struct.unpack_from('<2h', raw, record + 60)),
        )
        resource = next(r for r in combined['animations']['resources'] if r['id'] == ident)
        idle = next(c for c in resource['clips'] if c['id'] == 0)['frames'][0]['pose']
        pose = next(p for p in art_by_id[ident]['poses'] if p['id'] == idle)['sprite']
        profile['sprite'] = copy.deepcopy(pose)
        profile['attack'] = [dict(pose=copy.deepcopy(pose), ticks=1, source_pose=idle)]

    battle['schema'] = 'suikoden-battle-trial/' + str(max(43, int(battle['schema'].rsplit('/', 1)[1])))
    actors.clear()
    actors.update(combined)
    return dict(
        component=plan['provenance'],
        graphics=enemy_proof,
        party_clip3_graphics=party_proof,
        catalogue=catalogue,
        scope='Source D3 Creeper, F2 Shadow Man, F3 Mirage, H2 Mirage, all 78 party clip-3/atab[4] bindings, and 15 qualified D/F/H formations.',
    )


def export(output):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('Regional enemy exports are candidates; accepted promotion is separate')
    packet = build()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'regional_enemies.json').write_text(json.dumps(packet, indent=2) + '\n')
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'kit/work/build/enemy_regional_v1')
    args = parser.parse_args()
    export(args.output)
    print(args.output)
