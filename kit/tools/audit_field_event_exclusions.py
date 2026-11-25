#!/usr/bin/env python3
"""Audit every explicit exclusion against the configured default field exporter.

Ungated exportability is a compiler result, not original-behavior qualification.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import export_opening_field_package as exporter

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'kit/work/build/opening/canonical_field_art.json'
REPORT = ROOT / 'kit/data/reports/field_event_exclusions.json'


def build_audit(art_path=ART):
    forced = exporter.FORCE_SOURCE_ONLY
    guarded = {(room['room'], program['entity'])
               for room in exporter.build_package(art_path)['rooms'] for program in room['content']['programs']}
    try:
        exporter.FORCE_SOURCE_ONLY = set()
        packet = exporter.build_package(art_path)
    finally:
        exporter.FORCE_SOURCE_ONLY = forced
    rooms = {(file, number): room for file, number, room in exporter.OPENING_ROOMS}
    unguarded = {(room['room'], program['entity']): program
                 for room in packet['rooms'] for program in room['content']['programs']}
    entries = []
    sources = {}
    for file, room, entity in sorted(forced):
        row = {'file': file, 'room': room, 'entity': entity}
        if (file, room) not in rooms:
            row['status'] = 'outside_default_scope'
        else:
            program = unguarded.get((rooms[file, room], entity))
            row['status'] = ('already_admitted_by_shared_rules' if (rooms[file, room], entity) in guarded
                             else 'requires_semantic_admission' if program else 'covered_by_export_checks')
            if program:
                if file not in sources:
                    sources[file] = exporter.source(file)[0]
                data = sources[file]
                record = exporter.scene.entities(data, exporter.scene.room_record(data, room))[entity]
                row['source_event_predicate'] = exporter.decode_predicate(data, record['stream_offsets'][1], 'event', full=True)[0]
                row['command_kinds'] = dict(sorted(Counter(command['kind'] for command in program['commands']).items()))
        entries.append(row)
    assert len(entries) == len(forced)
    return {'schema': 'suikoden-field-event-exclusions/1',
            'scope': 'configured default field export; not native or original-behavior admission',
            'rooms': len(packet['rooms']),
            'producer_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (Path(__file__), Path(exporter.__file__), art_path)},
            'entries': entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    report = build_audit()
    payload = (json.dumps(report, indent=2) + '\n').encode()
    covered = [row for row in report['entries'] if row['status'] in ('covered_by_export_checks', 'already_admitted_by_shared_rules')]
    if args.verify:
        if covered:
            raise SystemExit(f'{len(covered)} explicit exclusions are already covered by export checks')
        if not REPORT.is_file() or REPORT.read_bytes() != payload:
            raise SystemExit('stale field-event exclusion audit; regenerate with this tool')
    else:
        REPORT.write_bytes(payload)
    print(f"Audited {len(report['entries'])} exclusions across {report['rooms']} rooms; {len(covered)} redundant")


if __name__ == '__main__':
    main()
