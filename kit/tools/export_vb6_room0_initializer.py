"""Retained one-shot IR1 fixture; shared field export handles reusable3A staging."""
import json
from pathlib import Path

import area_scene
import character_table
import event_script_decode
import export_events
import maindec
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]


def export():
    raw, origin = source('/VB6.BIN')
    population = json.loads((ROOT / 'game/assets/scenes/population/vb6_room0.json').read_text())
    entries = area_scene.entities(raw, area_scene.room_record(raw, 0))
    entry = entries[6]
    assert entry['flags'] & 0x10 and entry['stream_offsets'][2] == 0x34944
    instructions = []
    for offset, opcode, operands, _ in event_script_decode.decode_stream(raw, 0x34944, max_insns=4):
        instructions.append([offset, opcode, operands.hex()])
        if opcode == 0xfd:
            break
    assert [(op, args) for _, op, args in instructions] == [(0x30, ''), (0x3a, '01'), (0x31, ''), (0xfd, '')]
    assert maindec.mword(0x80171718 + 4 * 0x3a) == 0x8013c82c
    assert maindec.mword(0x8013c8d8) == 0xa0620001
    candidates = [e for e in population['entities'] if e['population_candidate'] and e['classification']['pointer_state'] == 'present']
    assert [e['source_order'] for e in candidates] == [7, 8, 9]
    target = candidates[1]
    assert target['source_order'] == 8 and not target['classification']['terms']
    initializer = population['entities'][6]
    conditions = initializer['event_selection']['terms']
    assert conditions == [
        {'kind': 'story_mask_set', 'flag': export_events.flag(15, 8)},
        {'kind': 'story_mask_clear', 'flag': export_events.flag(15, 16)},
    ]
    actors = [dict(id=e['id'], character=e['source_character_id'],
                   x=e['position']['x'], y=e['position']['y'], attached=False,
                   conditions=e['classification']['terms']) for e in candidates]
    content = export_events.identified(dict(
        schema='suikoden-event-ir/1', id='vb6_room0_initializer',
        story_values=[export_events.story_value(index, character_table.image()[0x32fe0 + 0x190 + index]) for index in (15, 20)],
        actors=actors, texts=[], tracks=[], programs=[dict(
            id='vb6_r00_init_06', entry='initialization', entity=6, trigger='none',
            conditions=conditions, commands=[dict(kind='continue_tick'),
                dict(kind='release_actor', actor=target['id']),
                dict(kind='yield_tick'), dict(kind='end_stream')])]))
    proof = dict(schema='suikoden-vb6-room0-initializer-proof/1', source=origin,
                 population_sha256=population['content_sha256'], content_sha256=content['content_sha256'],
                 entity=6, selector=1, target=target['id'], instructions=instructions,
                 consumers=['MAIN:0x8013C82C', 'MAIN:0x8013C8D8', 'MAIN:0x8013CCF0'],
                 scope='Source initializer and selector mapping only; field construction, rendering and event admission remain unbound.')
    return content, proof


def write():
    content, proof = export()
    for path, value in ((ROOT / 'game/assets/events/vb6_room0_initializer.json', content),
                        (ROOT / 'kit/data/reports/vb6_room0_initializer.json', proof)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__':
    write()
