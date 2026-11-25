#!/usr/bin/env python3
"""Export the unresolved VB6 room6 ordinary predicate operands as named data."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene
import maindec
from export_first_room import source
from export_scene_population import decode_predicate, identified


def build():
    raw, provenance = source('/VB6.BIN')
    population = json.loads((ROOT / 'game/assets/scenes/population/vb6_room6.json').read_text())
    entities = area_scene.entities(raw, area_scene.room_record(raw, 6))
    records, evidence = [], []
    for entity in entities[:5]:
        predicate, proof = decode_predicate(raw, entity['stream_offsets'][1], 'event')
        expected = population['entities'][entity['index']]['event_selection']
        if predicate != expected:
            raise ValueError('source predicate does not match accepted population')
        terms = []
        for term in proof['terms'][:-1]:
            opcode, operands = term['opcode'], term['operands']
            if opcode in (0x0b, 0x0c):
                lo, hi = operands
                if lo > hi:
                    raise ValueError('invalid coordinate range')
                terms.append(dict(kind='x_range' if opcode == 0x0b else 'y_range',
                                  source_kind=term['semantics'], min_pixel=lo * 8, max_pixel=hi * 8))
            elif opcode == 0x04 and operands == [0]:
                if struct.unpack_from('<I', maindec.body(), 0x80171708 - maindec.MBASE)[0] != 0x1000:
                    raise ValueError('source direction table changed')
                terms.append(dict(kind='up_input', source_kind=term['semantics']))
            else:
                raise ValueError(f'unsupported source predicate {opcode:#x}')
        records.append(dict(entity=entity['index'], terms=terms))
        evidence.append(dict(entity=entity['index'], predicate_offset=proof['offset'], terms=proof['terms']))
    document = identified(dict(schema='suikoden-field-predicates/1', id='vb6_room6_predicates',
                               population_sha256=population['content_sha256'], records=records))
    samples = [dict(x=216, y=200, up=None), dict(x=8, y=200, up=False),
               dict(x=200, y=336, up=True), dict(x=200, y=336, up=None),
               dict(x=304, y=152, up=False), dict(x=112, y=168, up=True)]
    def evaluate(record, sample):
        for term in record['terms']:
            result = sample['up'] if term['kind'] == 'up_input' else (
                term['min_pixel'] <= sample['x' if term['kind'] == 'x_range' else 'y'] <= term['max_pixel'])
            if result is None or not result:
                return result
        return True
    for sample in samples:
        sample['expected'] = [evaluate(record, sample) for record in records]
    fixture = dict(schema='suikoden-field-predicate-fixtures/1', cases=samples)
    report = dict(schema='suikoden-field-predicate-report/1', source=provenance, room=6,
                  population_sha256=population['content_sha256'], records=evidence,
                  consumers=['MAIN:0x8013DCE0', 'MAIN:0x8013DD0C', 'MAIN:0x8013DD38'],
                  input_mapping='selector 0 uses 0x1000, the source up-direction bit',
                  scope='VB6 room6 ordinary entities0–4 only; missing live input and caller gates remain explicit.')
    registry = [dict(id='FDP01', stage='X_FIELD_PREDICATES', **{'class': 'script'},
                     claim='VB6 room6 ordinary entities0–4 use the exported inclusive X/Y bounds and up-direction predicate in source order. At half-cell (27,25), each first X predicate rejects; entity0 Y remains independently true.',
                     addr='MAIN:0x8013DCE0;MAIN:0x8013DD0C;MAIN:0x8013DD38;VB6:0x35084',
                     evidence='proven', source='kit/tools/export_field_predicates.py;kit/tests/test_field_predicates.py',
                     superseded_by='', note='Static source bytes and independent consumer-instruction checks; no live gate or callback assumption.')]
    return document, fixture, report, registry


def outputs():
    document, fixture, report, registry = build()
    return {
        ROOT / 'game/assets/field_predicates.json': json.dumps(document, indent=2) + '\n',
        ROOT / 'game/tests/fixtures/field_predicates.json': json.dumps(fixture, indent=2) + '\n',
        ROOT / 'kit/data/reports/field_predicates.json': json.dumps(report, indent=2) + '\n',
        ROOT / 'kit/data/registry/extract_field_predicates.jsonl': ''.join(json.dumps(row) + '\n' for row in registry),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, text in outputs().items():
        if args.check:
            if path.read_text() != text:
                raise SystemExit(f'out of date: {path.relative_to(ROOT)}')
        else:
            path.write_text(text)
    print('PASS: VB6 field predicate sidecar' if args.check else 'Exported VB6 field predicate sidecar')


if __name__ == '__main__':
    main()
