"""Static source contracts for the loaded Warriors and Couple Unite controllers."""
import hashlib
import json
from pathlib import Path
import struct

import battle_bin
import spell_effect_sweep
import spell_scene_objects

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/unite_linked_controllers.json'

SPANS = {
    15: ((0x800FA9CC, 0x800FA9F4, 'b0c6255c7c1b61668601eda6456ce2fec38e430dcd0abb2d6afe20419c8176e0'),
         (0x800FA9F4, 0x800FABE4, '37c90f8441452137499ea7b73e2fd04de86b0c26dbf0435df636efe3d69a9404'),
         (0x800FABE4, 0x800FB048, 'a2767e1ba0abe3ce3cc1f1abb7210051864ec57fb1c4cd1aab55dbb17461b38f')),
    16: ((0x800FB048, 0x800FB070, '34d10ef4f531e287f5c9279066bcb426e6a890017932d91fd37b3cdeb6fee469'),
         (0x800FB070, 0x800FB210, 'b93e5ff272c2b77bdd535d7b43aa05ef920877d8f78c4dada4cb00a7e7317224'),
         (0x800FB210, 0x800FB428, '4c8598ca09e970dd7fa9d716478f838c328c9e568f45f45141205b61ef5ea592')),
}


def research(record, members, image):
    index = record['index']
    if index not in SPANS:
        raise ValueError('Unsupported linked Unite controller')
    spans = SPANS[index]
    if (record['handler'], record['update'], record['callback_chain']) != (spans[0][0], spans[2][0], [spans[1][0], spans[2][0]]):
        raise ValueError('Linked Unite callback chain changed')
    blocks = []
    for start, end, expected in spans:
        actual = hashlib.sha256(image.data[start-image.base:end-image.base]).hexdigest()
        if image.end(start) != end or actual != expected:
            raise ValueError('Linked Unite source changed')
        blocks.append(dict(address=start, size=end-start, sha256=actual))
    expected_members = {15: [(33, [10]), (63, [9])], 16: [(0, [11]), (30, [9, 10])]}[index]
    if [(member['id'], [script['script'] for script in member['scripts']]) for member in members] != expected_members:
        raise ValueError('Linked Unite member scripts changed')
    constructed = spell_scene_objects.constructors(dict(initializer=spans[1][0], preparation=[], state_global=0x8017A010), image)
    objects = constructed['objects']
    signature = [(obj['animation'], obj['delay'], obj['looping'], obj['enabled'], obj['size'], obj['slot']) for obj in objects]
    impact = (6, 48, 0, 0, 4096, 32 if index == 15 else 0)
    expected_objects = ([(9, 48, 1, 1, 4096, 4*i) for i in range(8)] if index == 15 else []) + [impact]
    if constructed['blocked'] or signature != expected_objects:
        raise ValueError('Linked Unite effect constructors changed')
    if index == 15 and [obj['initial'][68] for obj in objects[:8]] != [512*i for i in range(8)]:
        raise ValueError('Warriors initial angles changed')
    sections, _, errors, raw = battle_bin.parse(need_atlases=False)
    if errors:
        raise ValueError(errors)
    section = dict(sections[1], _data=raw)
    pieces, animations = spell_effect_sweep.entries(section)
    animations_out = []
    for animation in ((6, 9) if index == 15 else (6,)):
        row = animations[animation]
        offset = row['source_offset']
        flags = raw[offset+1]
        if flags != 1:
            raise ValueError('Linked Unite animation flags changed')
        animations_out.append(dict(id=animation, source_offset=offset, flags=flags, frames=row['frames']))
    if animations_out[0]['frames'] != [dict(piece=f'piece_{pose}', ticks=ticks) for pose, ticks in ((8, 6), (9, 6), (10, 8), (11, 10))]:
        raise ValueError('Linked Unite impact animation changed')
    selected = sorted({int(frame['piece'].split('_')[1]) for animation in animations_out for frame in animation['frames']})
    lba, size = battle_bin.battle_bin_lba()
    art = dict(file=battle_bin.DISC_PATH, lba=lba, size=size, sha256=hashlib.sha256(raw).hexdigest(),
               decoder=battle_bin.DECODER_ID, section=1, section_offset=section['header_offset'],
               animations=animations_out, pieces=[pieces[pose] for pose in selected])
    common = dict(source_blocks=blocks, members=[dict(id=identifier, scripts=scripts) for identifier, scripts in expected_members],
                  constructors=[list(values) for values in signature],
                  loading='handler requests the shared battle effect pages and waits for readiness before the initializer',
                  impact_art=art, target_position='snapshotted by initializer',
                  admission='source_research_only', unresolved=['native playback', 'KO and overlap', 'audio and human media acceptance'])
    if index == 16:
        common.update(trigger=dict(member=0, signal=16, clears=True, starts_member=1, script=10),
                      damage=dict(member=1, signal=2, clears=True, count=2, multiplier=20, divisor=10,
                                  start_impact_animation=6, shared_reaction_script=16),
                      returns=dict(signal=4, helper=0x800F9390, program=0x8016D214, completion=0x800F9718))
    else:
        import battle_unite_camera
        import journey_battle
        raw, source = battle_unite_camera.field.source('/' + members[0]['source']['file'].split('/')[-1])
        operations = journey_battle.script(raw, 15)
        offset = struct.unpack_from('<I', raw, struct.unpack_from('<I', raw, 32)[0] + 60)[0]
        length = sum(2 + 2 * len(args) for _, args in operations)
        digest = hashlib.sha256(raw[offset:offset + length]).hexdigest()
        if digest != 'fada2ada67501fff4a35b805372da58c898dc27b73284f3020eb181b6f818e59':
            raise ValueError('Warriors recipient script changed')
        timing = journey_battle.script_events([], operations, initial_movement_wait=True)
        common.update(trigger=dict(member=0, signal=16, clears=False),
                      phases=[dict(updates=64, object_scale_x_delta=64, start_sound=0x81f),
                              dict(updates=32, start_sound=0x524, start_impact_at_age=16, impact_sound=0x521),
                              dict(updates=32, damage_on_exit=True)],
                      ring=dict(count=8, animation=9, initial_angles=[512*i for i in range(8)],
                                angle_delta=64, initial_scale_x=1, local_x_q12=30*4096,
                                disabled_on_phase1_exit=True),
                      motion=dict(anchor_member=1, base_z_q12=-60*4096, divisor=16,
                                  sine_step=64, sine_amplitude=40),
                      damage=dict(count=2, multiplier=20, divisor=10, start_returns=True),
                      recipient=dict(member=0, script=15, phase=1, age=16, source=source,
                                     source_offset=offset, byte_length=length, sha256=digest,
                                     operations=[dict(op=op, args=list(args)) for op, args in operations],
                                     local_timing=dict(status='actor_local_wait_clocks',
                                                       duration=timing['duration'], operation_ticks=timing['operation_ticks'])),
                      returns=dict(program=0x8016D214))
    return common


def build():
    import battle_unite_camera
    rows = battle_unite_camera.report()
    return dict(schema='suikoden-unite-linked-controllers/1', status='static_source_candidate',
                producer='unite_linked_controllers.py v1',
                controllers=[dict(record=index, name=rows[index]['name'], **rows[index]['controller_research']) for index in (15, 16)])


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    payload = json.dumps(build(), indent=2) + '\n'
    if args.check:
        if REPORT.read_text() != payload:
            raise SystemExit('linked Unite controller report is stale')
    else:
        REPORT.write_text(payload)
    print(f'{"Checked" if args.check else "Wrote"} linked Unite controller report')
