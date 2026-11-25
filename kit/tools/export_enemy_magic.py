#!/usr/bin/env python3
"""Export Kobold type3's source magic contract, actors and shared spell-bank art."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import battle_bin
import battle_formulas
import character_table
import export_world_travel
import maindec
import preparation
from export_battle_trial import section_art, pack_pose
from export_first_room import ROOT, Atlas, source
from export_physical_runes import stream
from export_unite_programs import animation_resource, compile_operations
from spell_effect_entries import entry_image

BASE = 0x80080000
VERSION = 'enemy-magic-export/3'
SOURCE_BLOCKS = (
    (0x80080300, 0x80080490, '5fbf602aaecb8e9a6dd175ec9f9eb0be7afc986f1d9ae148c85f73d888ff5a52'),
    (0x80080490, 0x80080770, '4445907a99dff7b71bca6ece57cfb9ef66b25f7479c628e6d7a33aa41cadd44f'),
    (0x80080770, 0x80081050, '1e72c205e546d7df1307ffc1945faf47b6f298b78179dce39365ba242d09400c'),
)


def signed(value):
    return (value+(1 << 31)) % (1 << 32)-(1 << 31)


def binding(plan):
    return dict(id=plan['id'], owner_program=plan['programs']['programs'][0]['id'],
        recipient_program=plan['programs']['programs'][1]['id'], selection_delay=plan['selection_delay'],
        effect={key: value for key, value in plan['effect'].items()
                if key not in ('reaction_origin', 'impact_attachment', 'impact_attachment_y')},
        **{key: plan['damage'][key] for key in ('element', 'target_rune_elements', 'fallback_element')})


def combine(actors, plan):
    import copy
    from export_physical_runes import merge_libraries
    if actors['schema'] not in ('suikoden-unite-actors/14', 'suikoden-unite-actors/16', 'suikoden-unite-actors/18'):
        raise ValueError('enemy magic needs the shared ordinary actor library')
    result = copy.deepcopy(actors)
    merge_libraries(result, dict(programs=plan['programs'],
        animations=dict(schema='suikoden-actor-animations/1', resources=[plan['resource']])))
    result.update(schema='suikoden-unite-actors/19' if actors['counter'].get('cooperation') else 'suikoden-unite-actors/17' if actors['counter'].get('cover') else 'suikoden-unite-actors/15', enemy_magic=binding(plan))
    return result


def build():
    raw, origin = source('/C_DATA.BIN')
    word = lambda pc: struct.unpack_from('<I', raw, pc-BASE)[0]
    immediate = lambda pc: word(pc) & 65535
    blocks = []
    for first, last, digest in SOURCE_BLOCKS:
        if hashlib.sha256(raw[first-BASE:last-BASE]).hexdigest() != digest:
            raise ValueError('Kobold magic callback changed')
        blocks.append(dict(source=origin, source_offset=first-BASE, byte_length=last-first, sha256=digest))
    _, travel_proof = export_world_travel.export('c')
    record = next(row['stats_offset'] for row in travel_proof['enemy_records'] if row['id'] == 'kobold_type_3')
    section = struct.unpack_from('<I', raw, record+44)[0]-BASE
    table = struct.unpack_from('<I', raw, record+40)[0]-BASE
    if struct.unpack_from('<I', raw, table+24)[0] != 0x80080300:
        raise ValueError('Kobold magic local callback binding changed')

    programs = []; program_proofs = []
    for name, address in (('owner', 0x800A3E84), ('recipient', 0x800A10CC)):
        operations, spans = stream(raw, origin, address-BASE)
        lowered = [dict(row) for row in operations]
        local = [i for i, row in enumerate(operations) if row == dict(op=35, args=[1, 6])]
        if name == 'owner':
            if len(local) != 1:
                raise ValueError('Kobold magic owner callback changed')
            lowered[local[0]] = dict(op=35, args=[0, 6])
        instructions, blocked, effects = compile_operations(lowered)
        if blocked or set(effects) - {'palette_cycle', 'unbound_shared_actor_effect_6'}:
            raise ValueError('unbound Kobold magic actor command')
        for instruction in instructions:
            if instruction.get('command', {}).get('effect') == dict(id='unbound_shared_actor_effect_6', binding='shared'):
                instruction['command']['effect'] = dict(id='kobold_magic', binding='self')
        programs.append(dict(id='kobold_type_3/magic_'+name, instructions=instructions))
        program_proofs.append(dict(id=name, spans=spans, operations=operations))
    resource, resource_proof = animation_resource('kobold_type_3', raw, origin, {0, 1, 3, 13, 14, 15}, section, BASE)
    actor_poses, _, actor_proof = section_art(raw, section, BASE,
        animation_indices=(0, 1, 3, 13, 14, 15), selected_poses_only=True, axis_aligned_packet=True)

    sections, blobs, errors, bank = battle_bin.parse()
    if errors:
        raise ValueError(errors)
    effects = sections[1]
    decoded = {row['offset']: row['atlas'] for row in blobs}
    palette_offset = effects['atlas_offsets'][9]
    palette = decoded[palette_offset]
    pointer = lambda offset: struct.unpack_from('<I', bank, offset)[0]-battle_bin.LOAD_BASE
    clips = []; animations = []; used = set()
    for name, index in (('flare', 1), ('impact', 6), ('projectile', 11)):
        offset = pointer(effects['tables']['f']+4*index)
        if bank[offset+1] != 1:
            raise ValueError('Kobold magic animation flags changed')
        frames = [dict(pose=bank[offset+4+2*i], updates=bank[offset+5+2*i] or 256)
                  for i in range(bank[offset])]
        if not frames:
            raise ValueError('empty Kobold magic clip')
        clips.append(dict(id=name, advances=True, loop=False, frames=frames))
        animations.append(dict(id=name, animation=index, source_offset=offset, flags=bank[offset+1]))
        used.update(row['pose'] for row in frames)
    atlas = Atlas(); pieces = []; entries = []
    for pose in sorted(used):
        offset = pointer(effects['tables']['e']+4*pose)
        if bank[offset] != 1:
            raise ValueError('Kobold magic piece composition changed')
        entry = list(bank[offset+8:offset+16])
        blob = effects['atlas_offsets'][entry[2]]
        image = entry_image(decoded[blob], palette, entry)
        pieces.append(dict(id=pose, rect=atlas.add(image), dx=entry[0]-bank[offset+4], dy=entry[1]-bank[offset+5],
                           width=entry[4], height=entry[5]))
        entries.append(dict(pose=pose, source_offset=offset, source_entry=entry, blob_offset=blob,
            decoded_sha256=hashlib.sha256(decoded[blob]).hexdigest(), rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest()))
    body = [dict(id=i, sprite=pack_pose(atlas, pose)) for i, pose in enumerate(actor_poses) if pose is not None]

    # This call site clears s1 in the branch delay slot before the shared damage call.
    if word(0x80080CC4) != 0x00008821:
        raise ValueError('Kobold magic resistance fall-through changed')
    selectors = []
    for rune in range(1, 32):
        pc = maindec.mword(0x800C1414+4*(rune-1))
        if pc == 0x800F830C:
            selectors.append(0)
        elif pc == 0x800F8308:
            selectors.append(maindec.mword(pc) & 65535)
        elif maindec.mword(pc) == 0x0803E0C3 and maindec.mword(pc+4) >> 16 == 0x3411:
            selectors.append(maindec.mword(pc+4) & 65535)
        else:
            raise ValueError('unresolved generic magic resistance selector')
    for slot, address in ((0xA4, 0x801233B4), (0xB0, 0x801238E0), (0xB4, 0x80123720), (0xB8, 0x8012080C), (0x158, 0x800F8174)):
        if maindec.mword(0x8016B680+slot) != address:
            raise ValueError('Kobold magic shared consumer changed')
    count = immediate(0x800809BC)
    first = immediate(0x80080964)
    spacing = immediate(0x800809AC)
    flight = immediate(0x80080F64)
    damage_update = immediate(0x80080CBC)
    anchors = []; anchor_sources = []
    for character in character_table.records():
        actor, actor_origin = source('/'+character['sprite_file'])
        header = struct.unpack_from('<I', actor, 36)[0]
        table_offset = struct.unpack_from('<I', actor, header+16)[0]
        pose_offsets = [struct.unpack_from('<I', actor, table_offset+4*i)[0]
                        for i in range(struct.unpack_from('<H', actor, header)[0])]
        if any(offset+16 > len(actor) or actor[offset] == 0 for offset in pose_offsets):
            raise ValueError('missing recipient graphic centering header')
        identifier = preparation.stable_id(character['name'])
        anchors.append(dict(id=identifier, centers_x=[actor[offset+2]//2-actor[offset+4]+actor[offset+8] for offset in pose_offsets]))
        anchor_sources.append(dict(id=identifier, source=actor_origin, poses=pose_offsets))
    plan = dict(schema='suikoden-enemy-magic/1', id='kobold_type_3', selection_delay=immediate(0x8008075C),
        programs=dict(schema='suikoden-actor-programs/7', programs=programs), resource=resource, actor_art=body,
        clips=clips, pieces=pieces, impact_anchors=anchors, targeting=dict(front_reject_below=immediate(0x80080558),
            special_reject_below=immediate(0x80080638)),
        effect=dict(owner_wait_updates=immediate(0x800803C0),
            art_prepare_updates=bank[effects['header_offset']+4],
            origin_offset=[immediate(0x80080954), 0, (immediate(0x80080984)+32768) % 65536-32768],
            flight_offset_q12=[signed(immediate(0x80080B90) << 16 | immediate(0x80080B94)), 0, 0],
            projectile_size=immediate(0x80080960), projectile_growth=immediate(0x80080F54),
            flight_updates=flight, flare_updates=immediate(0x80080C64),
            flare_grow_until=(maindec.mword(0x80120814) & 65535)-1,
            flare_growth=maindec.mword(0x80120830) & 65535,
            flare_shrink=-(((maindec.mword(0x80120844) & 65535)+32768) % 65536-32768),
            projectiles=[dict(launch_update=first+1+spacing*i, contact_update=first+spacing*i+flight) for i in range(count)],
            flares=[dict(launch_update=1+spacing*i) for i in range(count)],
            damage_update=damage_update, cleanup_update=damage_update+1,
            reaction_update=first+flight, reaction_origin='first_projectile_contact',
            impact_attachment='recipient_current_pose_x', impact_attachment_y=0,
            shock_size=immediate(0x80080FC0), shock_updates=1,
            sounds=[dict(update=1, id=immediate(0x80080C04))]+[
                dict(update=first+1+spacing*i, id=immediate(0x80080C44)) for i in range(count)]),
        damage=dict(element=immediate(0x80080CDC), target_rune_elements=selectors, fallback_element=0,
            defend_halves=False, variance_draws=1, minimum=1))
    lba, size = battle_bin.battle_bin_lba()
    proof = dict(producer=VERSION, status='candidate', source=origin, callbacks=blocks,
        programs=program_proofs, actor_resource=resource_proof, actor_art=actor_proof, recipient_anchors=anchor_sources,
        bank=dict(file=battle_bin.DISC_PATH, lba=lba, size=size, sha256=hashlib.sha256(bank).hexdigest(),
            decoder=battle_bin.DECODER_ID, section=effects['header_offset'], animations=animations, entries=entries,
            palette_blob=palette_offset, palette_decoded_sha256=hashlib.sha256(palette).hexdigest()),
        damage=dict(routine='0x800F8174', call='0x80080CD8', selector_table='0x800C1414',
            caller_fallback='0x80080CC4 clears s1 before the call, including runes8..26 and out-of-range ids'),
        scope='Portable actor/graphic contract only; normal battle admission, native scene ownership and media acceptance remain unfinished.',
        native_launched=False, media_accepted=False, promoted=False)
    return plan, atlas, proof


def frame(plan, update, owner_q12, recipient_q12):
    """Inspect graphic state from captured positions; actor VM owns body/reaction clocks."""
    effect = plan['effect']; result = []
    if not 1 <= update < effect['cleanup_update']:
        return result
    root = [(value >> 12)+offset for value, offset in zip(owner_q12, effect['origin_offset'])]
    delta = [signed(b-a+offset) for a, b, offset in zip(owner_q12, recipient_q12, effect['flight_offset_q12'])]
    contact = [battle_formulas.mips_div(signed(value*effect['flight_updates']), effect['flight_updates']) for value in delta]
    for i, row in enumerate(effect['projectiles']):
        age = update-row['launch_update']+1
        if 1 <= age < effect['flight_updates']:
            position = [battle_formulas.mips_div(signed(value*age), effect['flight_updates']) for value in delta]
            result.append(dict(kind='projectile', index=i, clip='projectile', animation_updates=age,
                position_q12=position, root=root, size=effect['projectile_size']+age*effect['projectile_growth']))
        age = update-row['contact_update']
        duration = sum(f['updates'] for f in next(c for c in plan['clips'] if c['id'] == 'impact')['frames'])
        if 1 <= age < duration:
            result.append(dict(kind='impact', index=i, clip='impact', animation_updates=age,
                position_q12=contact.copy(), root=root, size=4096))
    for i, row in enumerate(effect['flares']):
        age = update-row['launch_update']+1
        if 1 <= age < effect['flare_updates']:
            growing = min(age, effect['flare_updates']-effect['flare_grow_until'])
            size = 1+growing*effect['flare_growth']-(age-growing)*effect['flare_shrink']
            result.append(dict(kind='flare', index=i, clip='flare', animation_updates=0,
                position_q12=[0, 0, 0], root=root, size=size))
    return result


def magic_damage(plan, caster_magic, recipient_magic, target_rune, draw):
    if not 0 <= target_rune <= 255:
        raise ValueError('target rune must be a byte')
    damage = plan['damage']
    selected = damage['target_rune_elements'][target_rune-1] if 1 <= target_rune <= 31 else damage['fallback_element']
    return battle_formulas.magic_damage(caster_magic, recipient_magic, draw, damage['element'], selected)


def export(output):
    output = Path(output).resolve(); accepted = (ROOT/'kit/work/accepted').resolve()
    if accepted in (output, *output.parents):
        raise ValueError('enemy magic is a candidate; accepted promotion is separate')
    plan, atlas, proof = build()
    output.mkdir(parents=True, exist_ok=True)
    atlas.save(output/'atlas.png')
    (output/'scene.json').write_text(json.dumps(plan, separators=(',', ':'))+'\n')
    (output/'provenance.json').write_text(json.dumps(proof, indent=2)+'\n')
    names = ('scene.json', 'atlas.png', 'provenance.json')
    (output/'manifest.json').write_text(json.dumps(dict(schema='suikoden-enemy-magic-manifest/1', status='candidate',
        files={name: hashlib.sha256((output/name).read_bytes()).hexdigest() for name in names}), indent=2)+'\n')
    return plan, proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'kit/work/build/enemy_magic/kobold_type_3')
    args = parser.parse_args()
    value, _ = export(args.out)
    print(f'{value["id"]}: 18 graphic objects, source actor programs and resistance selectors exported')
