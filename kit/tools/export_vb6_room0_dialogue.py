"""Export the two ordinary village conversations for the shared field host."""
import json
from pathlib import Path

import area_scene
import event_script_decode
import export_events
import opening_audience
from export_first_room import source
from export_field_scene_contexts import identified
from export_vb6_room0_actors import identity

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'game/assets'


def export():
    raw, provenance = source('/VB6.BIN')
    room = area_scene.room_record(raw, 0)
    entities = area_scene.entities(raw, room)
    table = area_scene.ptr_at(raw, room['record_off'] + 12)
    base = json.loads((ASSETS / 'events/vb6_room0_initializer.json').read_text())
    population = json.loads((ASSETS / 'scenes/population/vb6_room0.json').read_text())
    actors = json.loads((ASSETS / 'field_ordinary_actors_vb6_room0.json').read_text())
    programs, texts, anchors, evidence = [], [], [], []
    for entity, layout, index in ((8, 1, 0), (9, 2, 1)):
        entry = entities[entity]
        classification, predicate, stream = entry['stream_offsets']
        if raw[classification:classification + 1] != b'\x06' or raw[predicate:predicate + 2] != b'\x05\x06':
            raise ValueError('village conversation predicates changed')
        instructions = list(event_script_decode.decode_stream(raw, stream, max_insns=5))
        if [(op, args) for _, op, args, _ in instructions] != [(11, bytes([layout])), (4, bytes([0, index])), (2, b''), (12, b''), (253, b'')]:
            raise ValueError('village conversation stream changed')
        address = area_scene.ptr_at(raw, table + 4 * index)
        tokens, end = opening_audience.text(raw, address)
        if any(token['kind'] not in ('glyph', 'newline') for token in tokens):
            raise ValueError('unsupported village conversation token')
        program, text_id = f'vb6_r00_talk_{entity:02}', f'vb6_r00_text_{index}'
        texts.append(dict(id=text_id, tokens=tokens))
        anchors.append(dict(program=program, command=0, box=0, actor=f'vb6_room0_entity_{entity:02}'))
        programs.append(dict(id=program, entry='ordinary', entity=entity, trigger='interaction', conditions=[], commands=[
            dict(kind='open_box', box=0, layout=layout, requires=export_events.wait('box_closed', 'box_0')),
            dict(kind='text', box=0, text=text_id, wait=export_events.wait('text', text_id)),
            dict(kind='wait_for_accept'), dict(kind='close_box', box=0),
            dict(kind='end_stream', requires=export_events.wait('event_flags_low2', 'dialogue_flags'))]))
        evidence.append(dict(entity=entity, stream=stream, text_offset=address, text_end=end, layout=layout))
    content = export_events.identified(dict(schema='suikoden-event-ir/1', id='vb6_room0_dialogue',
        story_values=base['story_values'], actors=base['actors'], texts=texts, tracks=[], programs=programs))
    exit_stream = entities[1]['stream_offsets'][2]
    if raw[exit_stream:exit_stream + 9] != bytes.fromhex('09 27 10 03 fb 01 56 55 fd'):
        raise ValueError('village world exit stream changed')
    exit_program = export_events.identified(dict(schema='suikoden-event-ir/1', id='vb6_room0_world_exit',
        story_values=[export_events.story_value(39, 0)], actors=[], texts=[], tracks=[], programs=[
            dict(id='vb6_room0_world_exit', entry='ordinary', entity=1, trigger='none', conditions=[], commands=[
                dict(kind='story_or', flag=export_events.flag(39, 16)),
                dict(kind='world_transition', destination='region_b', x=86, y=85)])]))
    actors['event_sha256'] = content['content_sha256']
    actors.pop('content_sha256')
    actors['content_sha256'] = identity(actors)
    original_dialogue = json.loads((ASSETS / 'field_dialogue.json').read_text())
    dialogue = identified(dict(schema='suikoden-field-dialogue/6', anchors=anchors, texts=texts,
        prefixes=[], images=[], descriptor_changes=[], configuration=original_dialogue['configuration'],
        default_speed=original_dialogue['default_speed']))
    exit_dialogue = identified(dict(schema='suikoden-field-dialogue/6', anchors=[], texts=[],
        prefixes=[], images=[], descriptor_changes=[], configuration=original_dialogue['configuration'],
        default_speed=original_dialogue['default_speed']))
    exit_context = identified(dict(schema='suikoden-field-scene-context/1', room='vb6_village',
        event_id=exit_program['id'], event_sha256=exit_program['content_sha256'], population_id=population['id'],
        population_sha256=population['content_sha256'], dialogue_sha256=exit_dialogue['content_sha256'],
        dialogue_counts=[0, 0, 0, 0, 0], party_queue=False, ordinary_sha256=None))
    context = identified(dict(schema='suikoden-field-scene-context/1', room='vb6_village',
        event_id=content['id'], event_sha256=content['content_sha256'], population_id=population['id'],
        population_sha256=population['content_sha256'], dialogue_sha256=dialogue['content_sha256'],
        dialogue_counts=[len(dialogue[key]) for key in ('anchors', 'texts', 'prefixes', 'images', 'descriptor_changes')],
        party_queue=False, ordinary_sha256=actors['content_sha256']))
    proof = dict(schema='suikoden-vb6-room0-dialogue-proof/1', source=provenance, conversations=evidence,
        scope='Two ordinary source scripts and text; interaction admission, presentation and live scene ownership remain separate.')
    return {ASSETS / 'events/vb6_room0_dialogue.json': content,
            ASSETS / 'events/vb6_room0_world_exit.json': exit_program,
            ASSETS / 'field_dialogue_vb6_room0_world_exit.json': exit_dialogue,
            ASSETS / 'vb6_room0_world_exit_context.json': exit_context,
            ASSETS / 'field_dialogue_vb6_room0.json': dialogue,
            ASSETS / 'field_ordinary_actors_vb6_room0_dialogue.json': actors,
            ASSETS / 'vb6_room0_dialogue_context.json': context,
            ROOT / 'kit/data/reports/vb6_room0_dialogue.json': proof}


if __name__ == '__main__':
    for path, value in export().items():
        path.write_text(json.dumps(value, indent=2) + '\n')
