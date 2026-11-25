#!/usr/bin/env python3
"""Export the source-evidenced VB6 room6 follow-on boundary for review."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene
import event_script_decode
import export_field_actor_bindings as binder
import opening_audience
import export_opening_scene
import war_text
import maindec
from export_first_room import source
from export_scene_population import decode_predicate


def outputs():
    data, origin = source('/VB6.BIN')
    entities = area_scene.entities(data, area_scene.room_record(data, 6))
    entity = entities[7]
    if entity['stream_offsets'][2] != 0x35164:
        raise ValueError('VB6 room6 entity7 source stream changed')
    guard, guard_source = decode_predicate(data, entity['stream_offsets'][1], 'event')
    expected_guard = [('story_mask_clear', 'scenario_0015', 64), ('story_mask_set', 'scenario_0015', 32)]
    if [(term['kind'], term['flag']['id'], term['flag']['mask']) for term in guard['terms']] != expected_guard:
        raise ValueError('VB6 room6 entity7 guard changed')
    bindings = json.loads((ROOT / 'game/assets/scenes/bindings/field_actor_bindings.json').read_text())
    fixtures = json.loads((ROOT / 'game/tests/fixtures/field_actor_bindings.json').read_text())
    results = []
    for name in ('vb6_count3_entity7', 'vb6_count6_entity7'):
        case = next(row for row in fixtures['cases'] if row['id'] == name)
        result = binder.resolve(bindings, case['scene_id'], case['program_id'], case['selector'], case['state'])
        if result['status'] != 'resolved' or result['actor_id'] != 'vb6_r06_e07_char_014':
            raise ValueError('entity7 selector binding changed')
        results.append({'fixture': name, 'actor': result['actor_id'], 'source_entity': result['source_entity_id']})
    instructions = []
    for offset, opcode, operands, note in event_script_decode.decode_stream(data, entity['stream_offsets'][2], max_insns=32):
        if 'UNKNOWN' in note or 'TRUNCATED' in note:
            raise ValueError(f'undecodable entity7 instruction at {offset:#x}')
        instructions.append({'offset': offset, 'opcode': opcode, 'operands_hex': operands.hex()})
        if opcode == 3:
            if operands != bytes.fromhex('06 1b 19'):
                raise ValueError('entity7 transition changed')
            break
    else:
        raise ValueError('entity7 inline exit not found')
    if [(row['opcode'], row['operands_hex']) for row in instructions[:3]] != [
        (7, '000102'), (7, '000219'), (50, '00011605')
    ]:
        raise ValueError('entity7 actor setup changed')
    track = opening_audience.track(bytes.fromhex(instructions[2]['operands_hex'])[1:])
    text_tables = area_scene.ptr_at(data, area_scene.root(data) + 20)
    text_table = area_scene.ptr_at(data, text_tables)
    text_offset = area_scene.ptr_at(data, text_table + 6 * 4)
    tokens, text_end = opening_audience.text(data, text_offset)
    decoded, used = war_text.decode(data, text_offset)
    if ''.join(token.get('text', '\n') for token in tokens) != decoded or text_offset + used != text_end:
        raise ValueError('independent entity7 dialogue decoders disagree')
    expected = [(7, '000102'), (7, '000219'), (50, '00011605'), (51, ''), (17, '8003'),
                (11, '00'), (18, '000e'), (28, '000006'), (2, ''), (12, ''),
                (70, ''), (9, '0f40'), (3, '061b19')]
    if [(row['opcode'], row['operands_hex']) for row in instructions] != expected:
        raise ValueError('entity7 source instruction sequence changed')
    if maindec.mword(0x80171b98 + 4 * 3) != 2:
        raise ValueError('entity7 Hero transition mapping changed')
    initializers = []
    for index in (6, 8, 28):
        entry = entities[index]
        conditions, proof = decode_predicate(data, entry['stream_offsets'][1], 'event')
        initializers.append({'entity': index, 'conditions': conditions, 'source': proof})
    init8_rows = []
    for offset, opcode, operands, _ in event_script_decode.decode_stream(data, entities[8]['stream_offsets'][2], max_insns=16):
        init8_rows.append((opcode, operands.hex()))
        if opcode == 0xfd:
            break
    if init8_rows != [(48, ''), (7, '000118'), (7, '000219'), (17, '0001'),
                      (17, '8003'), (49, ''), (253, '')] or maindec.mword(0x80171b98 + 4) != 3:
        raise ValueError('VB6 initializer8 source program changed')
    actor = results[0]['actor']
    content = {
        'schema': 'suikoden-event-ir/1', 'id': 'vb6_room6_e7',
        'story_values': [{'id': 'scenario_0015', 'storage': 'scenario', 'byte_index': 15, 'initial': 0},
                         {'id': 'scenario_0016', 'storage': 'scenario', 'byte_index': 16, 'initial': 0}],
        'actors': [{'id': actor, 'character': 14, 'x': 2032, 'y': 2032, 'conditions': []}],
        'texts': [{'id': 'vb6_e7_text_0_6', 'tokens': tokens}],
        'tracks': [{'id': 'vb6_e7_actor_track', 'actor': actor, 'commands': track}],
        'programs': [{'id': 'vb6_r06_entity07_followon', 'entry': 'ordinary', 'entity': 7, 'trigger': 'none',
                      'conditions': guard['terms'], 'commands': [
                          {'kind': 'actor_x', 'actor': actor, 'value': 2},
                          {'kind': 'actor_y', 'actor': actor, 'value': 25},
                          {'kind': 'queue_track', 'track': 'vb6_e7_actor_track'},
                          {'kind': 'wait_tracks'},
                          {'kind': 'actor_transition', 'actor': 'hero', 'transition': 2},
                          {'kind': 'open_box', 'box': 0, 'layout': 0, 'requires': {'kind': 'box_closed', 'id': 'box_0'}},
                          {'kind': 'start_or_wait_dialogue', 'box': 0, 'code': 14, 'wait': {'kind': 'speaker_prefix', 'id': 'box_0'}},
                          {'kind': 'text', 'box': 0, 'speaker_slot': 0, 'table': 0, 'index': 6, 'text': 'vb6_e7_text_0_6', 'wait': {'kind': 'text', 'id': 'vb6_e7_text_0_6'}},
                          {'kind': 'wait_for_accept'}, {'kind': 'close_box', 'box': 0},
                          {'kind': 'wait_event_flags_low2'},
                          {'kind': 'story_or', 'flag': {'id': 'scenario_0015', 'mask': 64}},
                          {'kind': 'room_transition', 'destination': 'vb6_kobold_village', 'x': 216, 'y': 200},
                      ]},
                     {'id': 'vb6_r06_init_08', 'entry': 'initialization', 'entity': 8, 'trigger': 'none',
                      'conditions': initializers[1]['conditions']['terms'], 'commands': [
                          {'kind': 'continue_tick'},
                          {'kind': 'actor_x', 'actor': actor, 'value': 24},
                          {'kind': 'actor_y', 'actor': actor, 'value': 25},
                          {'kind': 'actor_transition', 'actor': actor, 'transition': 3},
                          {'kind': 'actor_transition', 'actor': 'hero', 'transition': 2},
                          {'kind': 'yield_tick'},
                          {'kind': 'end_stream', 'requires': {'kind': 'event_flags_low2', 'id': 'dialogue_flags'}},
                      ]}],
        'content_sha256': '',
    }
    content['content_sha256'] = hashlib.sha256((json.dumps(content, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
    arrival_content = json.loads((ROOT / 'game/assets/events/vb6_room6_field_host.json').read_text())
    composite = copy.deepcopy(arrival_content)
    by_story = {entry['id']: entry for entry in composite['story_values']}
    for entry in content['story_values']:
        if entry['id'] in by_story:
            if by_story[entry['id']] != entry:
                raise ValueError('follow-on story definition conflicts with arrival')
        else:
            composite['story_values'].append(entry)
    for actor in content['actors']:
        prior = next((entry for entry in composite['actors'] if entry['id'] == actor['id']), None)
        if prior is None or any(prior.get(key) != value for key, value in actor.items()):
            raise ValueError('follow-on actor differs from arrival construction')
    composite['texts'].extend(content['texts'])
    composite.setdefault('tracks', []).extend(content['tracks'])
    composite['programs'].extend(content['programs'])
    composite['content_sha256'] = ''
    composite['content_sha256'] = hashlib.sha256((json.dumps(composite, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
    bundle = json.loads((ROOT / 'game/assets/scenes/events/vb6_room6.json').read_text())
    if bundle['entries'][7]['status'] != 'blocked_unsupported' or bundle['entries'][7]['gap']['unsupported']['kind'] != 'room_coordinate_transition':
        raise ValueError('accepted E7 source frontier changed')
    e7_ref = {'namespace': 'suikoden-event-ir/1', 'content_id': content['id'],
              'content_sha256': content['content_sha256'], 'program_id': content['programs'][0]['id']}
    entry = bundle['entries'][7]
    entry['status'], entry['program'] = 'executable_embedded', e7_ref
    entry.pop('gap')
    bundle['contents'].append({'reference': e7_ref, 'relation': 'embedded_candidate',
                               'command_count': len(content['programs'][0]['commands']), 'content': content})
    bundle['coverage']['executable_entries'] += 1
    bundle['coverage']['blocked_entries'] -= 1
    bundle['content_sha256'] = ''
    bundle['content_sha256'] = hashlib.sha256((json.dumps(bundle, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
    policy = json.loads((ROOT / 'game/assets/scenes/dispatch/vaa_vb6.json').read_text())
    vb6_policy = next(scene for scene in policy['scenes'] if scene['id'] == 'vb6_room6')
    e7_entry = next(entry for entry in vb6_policy['entries'] if entry['source_order'] == 7)
    if e7_entry['status'] != 'blocked_unsupported' or e7_entry['blocker']['reason'] != 'room_coordinate_transition':
        raise ValueError('accepted E7 dispatch frontier changed')
    e7_entry.update(status='executable', program={**e7_ref, 'entry': 'ordinary'}, blocker=None)
    vb6_policy['bundle']['content_sha256'] = bundle['content_sha256']
    policy['content_sha256'] = ''
    policy['content_sha256'] = hashlib.sha256((json.dumps(policy, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
    source_scene = next(row for row in bindings['scenes'] if row['id'] == 'vb6_room6')
    source_actors, source_actor_proofs = opening_audience.actor_bindings(data, 6, bytearray(240))
    section = area_scene.section_off(data, area_scene.room_record(data, 6)['section'])
    resources = area_scene.character_bindings(data, section)
    animations = []
    for character, resource in sorted(resources.items()):
        context = resource['context']
        table = area_scene.ptr_at(data, context + 20)
        clips = []
        for variant in range(4):
            descriptor = area_scene.ptr_at(data, table + 4 * variant)
            count = data[descriptor]
            clips.append({'flags': data[descriptor + 1], 'ticks': [data[descriptor + 5 + 2*i] or 256 for i in range(count)],
                          'bounds': [{'width': data[sheet + 2], 'height': data[sheet + 3]}
                                     for i in range(count)
                                     for sheet in (area_scene.descriptor_sheet(data, context, variant, i)['sheet'],)]})
        animations.append({'graphic': f'vb6_character_{character:03d}', 'clips': clips})
    hero = next(row for row in opening_audience.animation_timings(data, source_actors) if row['graphic'] == 'hero')
    animations.append(hero)
    actor_rows = []
    for identity, candidate, proof in zip(source_scene['scene_actors'], source_actors, source_actor_proofs, strict=True):
        character = identity['source_character_id']
        if identity['source_order'] != proof['entity'] or character != proof['native_character']:
            raise ValueError('VB6 actor construction differs from accepted binder')
        if character == 8:
            if identity['resource_domain'] != 'active_party_character':
                raise ValueError('VB6 Hero descriptor requires active-party resource')
            graphic = 'hero'
        else:
            if character not in resources or identity['resource_domain'] != 'area_character_context':
                raise ValueError('VB6 actor resource unavailable in room section')
            graphic = f'vb6_character_{character:03d}'
        actor_rows.append({'id': identity['stable_actor_id'], 'entity': identity['source_order'],
                           'slot': identity['baseline_compact_index'], 'resource': identity['resource_id'],
                           'graphic': graphic, 'x': candidate['x'], 'y': candidate['y'],
                           'speed': candidate['motion'], 'variant': candidate['variant'],
                           'auto_animate': candidate['auto_animate'], 'conditions': identity['classification']['terms']})
    actor_packet = {'schema': 'suikoden-field-ordinary-actors/1', 'scene': 'vb6_room6',
                    'binding_sha256': bindings['content_sha256'], 'population_sha256': source_scene['population_content_id'],
                    'event_sha256': content['content_sha256'], 'actors': actor_rows}
    actor_packet['content_sha256'] = hashlib.sha256(json.dumps(actor_packet, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    arrival_context = json.loads((ROOT / 'game/assets/vb6_field_context.json').read_text())
    arrival_actors = dict(actor_packet)
    arrival_actors.pop('content_sha256')
    arrival_actors['event_sha256'] = arrival_context['event_sha256']
    arrival_actors['content_sha256'] = hashlib.sha256(json.dumps(arrival_actors, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    arrival_context.pop('content_sha256')
    arrival_context['ordinary_sha256'] = arrival_actors['content_sha256']
    arrival_context['content_sha256'] = hashlib.sha256(json.dumps(arrival_context, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    followon_actors = dict(actor_packet)
    followon_actors.pop('content_sha256')
    followon_actors['event_sha256'] = composite['content_sha256']
    followon_actors['content_sha256'] = hashlib.sha256(json.dumps(followon_actors, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    followon_context = dict(arrival_context)
    followon_context.pop('content_sha256')
    followon_context['event_sha256'] = composite['content_sha256']
    followon_context['ordinary_sha256'] = followon_actors['content_sha256']
    followon_context['content_sha256'] = hashlib.sha256(json.dumps(followon_context, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    animation_packet = {'schema': 'suikoden-field-ordinary-animations/1', 'scene': 'vb6_room6',
                        'animations': animations}
    surfaces = {'schema': 'suikoden-field-surfaces/1', 'scene': 'vb6_room6', 'source': origin,
                'population_sha256': source_scene['population_content_id'],
                'cells': export_opening_scene.surface_cells(data, 6)}
    surfaces['content_sha256'] = hashlib.sha256(json.dumps(surfaces, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    actor_fixture = {'schema': 'suikoden-field-ordinary-actors-fixture/1', 'actor_count': len(actor_rows),
                     'first_actor': actor_rows[0], 'animation': next(a for a in animations if a['graphic'] == actor_rows[0]['graphic']),
                     'active_party_graphic': 'hero', 'scope': 'source metadata only; active-party resource and image approval remain external'}
    report = {
        'schema': 'suikoden-field-followons-report/1',
        'status': 'candidate semantic program; actor, queue, dialogue and reconstruction are not yet live',
        'candidate_content_sha256': content['content_sha256'],
        'actor_metadata_sha256': actor_packet['content_sha256'],
        'source': origin,
        'room': 6,
        'entity': 7,
        'guard': guard,
        'guard_source': guard_source,
        'bindings': results,
        'actor_setup': {'actor': results[0]['actor'], 'x_pixel': 16, 'y_pixel': 200,
                        'track': track, 'scope': 'source-decoded, not yet a live actor or queue'},
        'dialogue': {'table': 0, 'index': 6, 'source_offset': text_offset, 'source_end': text_end,
                     'tokens': tokens, 'scope': 'decoded text; layout, portrait and live dialogue remain unbound'},
        'actor_resources': {'count': len(actor_rows), 'area_resource_ids': sorted(resources),
                            'active_party_ids': [8], 'hero_resource': 'requires a supplied loaded party context',
                            'first_actor_context_offset': resources[14]['context'],
                            'scope': 'constructor and animation metadata; no runtime admission or media acceptance'},
        'reconstruction_initializers': initializers,
        'verification': 'Static follow-on tests plus 14 event and 114 world component tests; no native window or media acceptance.',
        'instructions': instructions,
        'transition': {'room': 6, 'x_pixel': 216, 'y_pixel': 200, 'kind': 'same_room_reconstruction',
                       'source': ['MAIN:0x8013E0A8', 'MAIN:0x8013E0D0', 'MAIN:0x8013C12C', 'MAIN:0x8013E118'],
                       'wait': 'event_flags_low2_clear', 'terminal': 'inline_exit'},
        'limitations': ['The candidate is not admitted by the live field host.',
                        'Live source gates, actor/resource lifetime, queue/dialogue behavior and reconstruction remain unbound.',
                        'Entity9 and initialization8/28 require separate source selection.'],
    }
    fixture = {'schema': 'suikoden-field-followons-source-fixture/1', 'guard': guard,
               'actor': 'vb6_r06_e07_char_014', 'room': 6, 'x_pixel': 216, 'y_pixel': 200,
               'opcodes': [row['opcode'] for row in instructions]}
    return {
        ROOT / 'kit/data/reports/field_followons.json': json.dumps(report, indent=2) + '\n',
        ROOT / 'game/tests/fixtures/field_followons.json': json.dumps(fixture, indent=2) + '\n',
        ROOT / 'game/assets/events/vb6_room6_e7.json': json.dumps(content, indent=2) + '\n',
        ROOT / 'game/assets/events/vb6_room6_followons.json': json.dumps(composite, indent=2) + '\n',
        ROOT / 'game/assets/scenes/events/vb6_room6_followons.json': json.dumps(bundle, indent=2) + '\n',
        ROOT / 'game/assets/scenes/dispatch/vb6_room6_followons.json': json.dumps(policy, indent=2) + '\n',
        ROOT / 'game/assets/field_ordinary_actors_vb6.json': json.dumps(actor_packet, indent=2) + '\n',
        ROOT / 'game/assets/field_ordinary_actors_vb6_arrival.json': json.dumps(arrival_actors, indent=2) + '\n',
        ROOT / 'game/assets/vb6_field_context_actors.json': json.dumps(arrival_context, indent=2) + '\n',
        ROOT / 'game/assets/field_ordinary_actors_vb6_followons.json': json.dumps(followon_actors, indent=2) + '\n',
        ROOT / 'game/assets/vb6_field_context_followons.json': json.dumps(followon_context, indent=2) + '\n',
        ROOT / 'game/assets/field_ordinary_animations_vb6.json': json.dumps(animation_packet, indent=2) + '\n',
        ROOT / 'game/assets/field_surfaces_vb6.json': json.dumps(surfaces, indent=2) + '\n',
        ROOT / 'game/tests/fixtures/field_ordinary_actors_vb6.json': json.dumps(actor_fixture, indent=2) + '\n',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, content in outputs().items():
        if args.check:
            if path.read_text() != content:
                raise SystemExit(f'out of date: {path.relative_to(ROOT)}')
        else:
            path.write_text(content)
    print('PASS: VB6 follow-on source evidence')


if __name__ == '__main__':
    main()
