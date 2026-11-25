"""Lower only VB6 room6 initializer6, composing the frozen arrival IR unchanged."""
from pathlib import Path
import json

import area_scene
import character_table
import event_script_decode
import export_events
import maindec
from export_first_room import source

ROOT = Path(__file__).resolve().parents[2]


def export():
    raw, origin = source('/VB6.BIN')
    entities = area_scene.entities(raw, area_scene.room_record(raw, 6))
    assert [e['index'] for e in entities if e['flags'] & 16] == [6, 8, 28]
    entry = entities[6]
    predicate, stream = entry['stream_offsets'][1:]
    assert raw[predicate] == 6
    instructions = []
    for offset, opcode, operands, _ in event_script_decode.decode_stream(raw, stream, max_insns=8):
        instructions.append(dict(offset=offset, opcode=opcode, operands=operands.hex()))
        if opcode == 253:
            break
    assert [(r['opcode'], r['operands']) for r in instructions] == [(48, ''), (66, '11'), (49, ''), (253, '')]
    assert maindec.mword(0x80171718 + 4 * 0x42) == 0x801398F8
    assert maindec.mword(0x800C1AC0 + 4 * 17) == 0x80141AF8
    writer = [row[1] for row in maindec.dis(0x80141AF8, 8)]
    assert writer == [0x3C038018, 0x8C63DB24, 0, 0x906201B6, 0, 0x34420002, 0x08050713, 0xA06201B6]
    # The independently checked generic scenario consumer uses gs+0x190+index.
    assert maindec.mword(0x8013D70C) == 0x90430190
    index = (writer[3] & 65535) - (maindec.mword(0x8013D70C) & 65535)
    flag = export_events.flag(index, writer[5] & 65535)
    base = json.loads((ROOT / 'game/assets/events/vb6_room6_arrival.json').read_text())
    assert base == export_events.identified(base)
    assert base['id'] == 'vb6_room6_arrival' and len(base['programs']) == 1
    assert len(base['programs'][0]['commands']) == 28
    result = dict(base)
    result['story_values'] = base['story_values'] + [export_events.story_value(index, character_table.image()[0x32FE0 + 0x190 + index])]
    result['programs'] = base['programs'] + [dict(id='vb6_room6_init_06', entry='initialization', entity=6,
        trigger='none', conditions=[], commands=[dict(kind='continue_tick'), dict(kind='story_or', flag=flag),
                                                dict(kind='yield_tick'), dict(kind='end_stream')])]
    result = export_events.identified(result)
    proof = dict(schema='suikoden-field-initialization-proof/1', source=origin,
        base_content_sha256=base['content_sha256'], content_sha256=result['content_sha256'],
        producer='kit/tools/export_field_initializers.py', entity=6, predicate_offset=predicate,
        stream_offset=stream, instructions=instructions,
        source_consumers=['MAIN:0x801398F8','MAIN:0x80141814','MAIN:0x80141AF8','MAIN:0x8013CBBC',
                          'MAIN:0x8013D6CC','MAIN:0x8013F2A4','MAIN:0x801318C4','MAIN:0x8013F1BC'],
        lowering=dict(selector=17, bank='scenario', byte_index=index, mask=flag['mask']),
        policy='Source initialization driver selects every eligible initializer in source order and pumps each once. Do not resume the final FD in the ordinary event driver.',
        unsupported_initializers=[8, 28], media_accepted=False, promoted=False)
    return result, proof


def write():
    content, proof = export()
    for path, value in ((ROOT/'game/assets/events/vb6_room6_field_host.json', content),
                        (ROOT/'kit/data/reports/field_initialization.json', proof)):
        path.write_text(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__':
    write()
