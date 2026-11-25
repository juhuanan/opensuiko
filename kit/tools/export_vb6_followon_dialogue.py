#!/usr/bin/env python3
"""Export candidate VB6 E7 dialogue and its qualified scene context."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import area_scene
import maindec
import opening_audience
from export_first_room import source
from export_opening_scene import portrait_payload
from export_field_scene_contexts import identified

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'game/assets'


def load(path):
    return json.loads((ASSETS / path).read_text())


def export():
    raw, origin = source('/VB6.BIN')
    room = area_scene.room_record(raw, 6)
    section = area_scene.section_off(raw, room['section'])
    assert raw[0x35175:0x3517a] == bytes.fromhex('0b 00 12 00 0e')
    # Layout zero indexes the ordinary descriptor array; source actor7 is its
    # first unconditional constructed actor, unlike an event actor selector.
    actor = load('field_ordinary_actors_vb6_followons.json')['actors'][0]
    assert (actor['entity'], actor['slot'], actor['conditions'], actor['resource']) == (7, 0, [], 'vb6_room6_character_014')
    for address, word in {0x8013b054: 0x00071040, 0x8013b05c: 0x8c63daa0,
                          0x8013b064: 0x000210c0, 0x8013b06c: 0x90e20000,
                          0x8013b098: 0x90e20001}.items():
        assert maindec.mword(address) == word
    resources = area_scene.character_bindings(raw, section)
    record = resources[14]['record']
    image_offset, palette_offset = (area_scene.ptr_at(raw, record + offset) for offset in (4, 8))
    plane, palette, compressed = portrait_payload(raw, image_offset, palette_offset)
    image = maindec.body()
    native_ids = image[0x80170095-maindec.MBASE:0x80170095-maindec.MBASE+109]
    ranks = [i + 1 for i, value in enumerate(native_ids) if value == 14]
    assert ranks == [48]
    name_address = maindec.mword(0x80170588 + 4 * ranks[0])
    start = name_address - maindec.MBASE
    name = image[start:image.index(0, start)]
    tokens, _ = opening_audience.text(name + b'\x03\0', 0)
    assert ''.join(token.get('text', '') for token in tokens) == 'Kuromimi'
    e7 = load('events/vb6_room6_e7.json')
    assert e7['programs'][0]['commands'][5]['layout'] == 0
    assert e7['programs'][0]['commands'][6]['code'] == 14
    dialogue = load('field_dialogue.json')
    dialogue.pop('content_sha256')
    dialogue['schema'] = 'suikoden-field-dialogue/6'
    dialogue['anchors'].append(dict(program='vb6_r06_entity07_followon', command=5, box=0, actor=actor['id']))
    name_index = len(dialogue['texts'])
    dialogue['texts'].append(dict(id='vb6_prefix_kuromimi', tokens=tokens))
    dialogue['texts'].append(e7['texts'][0])
    portrait_index = len(dialogue['images'])
    dialogue['images'].append(dict(id='kuromimi_portrait', character=14, domain='area_custom', resource=actor['resource'], width=64, height=64,
        plane_sha256=hashlib.sha256(plane).hexdigest(), palette_sha256=hashlib.sha256(struct.pack('<256H', *palette)).hexdigest()))
    dialogue['prefixes'].append(dict(program='vb6_r06_entity07_followon', command=6, box=0, text=name_index, image=portrait_index))
    dialogue = identified(dialogue)
    context = load('vb6_field_context_followons.json')
    context.pop('content_sha256')
    context['dialogue_sha256'] = dialogue['content_sha256']
    context['dialogue_counts'] = [len(dialogue[key]) for key in ('anchors', 'texts', 'prefixes', 'images', 'descriptor_changes')]
    context = identified(context)
    proof = dict(schema='suikoden-vb6-followon-dialogue-source/1', source=origin,
        instructions='0b 00 12 00 0e', actor=actor['id'], source_entity=7, ordinary_layout_index=0,
        consumers=['0x8013B490', '0x8013B0C8', '0x8013AFA0', '0x8013AE80'],
        name_lookup=dict(character=14, rank=ranks[0], pointer=name_address),
        portrait=dict(record=record, image_offset=image_offset, palette_offset=palette_offset,
                      compressed_bytes=compressed, decoder='export_opening_scene.portrait_payload / lzss.decode_strict'),
        dialogue_sha256=dialogue['content_sha256'], context_sha256=context['content_sha256'],
        scope='Candidate source data only; no media acceptance or package promotion.')
    return {ASSETS/'field_dialogue_vb6_e7.json': dialogue, ASSETS/'vb6_field_context_dialogue.json': context,
            ROOT/'kit/data/reports/vb6_followon_dialogue.json': proof}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, value in export().items():
        output = json.dumps(value, indent=2) + '\n'
        if args.check:
            if path.read_text() != output:
                raise SystemExit(f'out of date: {path.relative_to(ROOT)}')
        else:
            path.write_text(output)


if __name__ == '__main__':
    main()
