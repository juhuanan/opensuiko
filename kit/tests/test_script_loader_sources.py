#!/usr/bin/env python3
"""Independent physical table walk and original mode-2 descriptor-load instructions."""
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract
import event_script_reachability as R


def check():
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    source = next(r for r in files if r['path'] == 'MAIN.EXE')
    executable = extract(source['lba'], source['size'])
    assert executable[:8] == b'PS-X EXE'
    base, size = struct.unpack_from('<II', executable, 0x18)
    assert base == 0x800C0800
    main = executable[2048:2048 + size]

    def word(address):
        return struct.unpack_from('<I', main, address - base)[0]

    # Cache-hit branch, cache-key write, two indexed pointer reads, and loader call.
    assert struct.unpack_from('<17I', main, 0x80130F34 - base) == (
        0x10830012, 0x00000000,
        0x3C028018, 0x8C42DB24, 0xA4A4001C, 0x90430002, 0x90420000,
        0x00031880, 0x3C018017, 0x2421F67C, 0x00230821, 0x8C230000,
        0x00021080, 0x00431021, 0x8C440000, 0x0C030BBE, 0x3C058001,
    )
    # Independent observed physical lengths; no stop-at-null or stop-at-first-data rule.
    lengths = [12, 50, 9, 9, 6, 5, 4, 3, 2, 50, 3, 13]
    expected, referenced = [], set()
    for region, count in enumerate(lengths):
        start = word(0x8016F67C + 4*region)
        for index in range(count):
            address = start + 4*index
            descriptor = word(address)
            slot = {'region': region, 'index': index, 'address': address, 'descriptor': descriptor}
            if descriptor:
                record = descriptor - 0x80163D64
                assert record % 8 == 0 and 0 <= record < 344 * 8
                size, lba = word(descriptor), word(descriptor + 4)
                file = next(r for r in files if (r['size'], r['lba']) == (size, lba))
                slot['file'] = file['path']
                referenced.add(file['path'])
            expected.append(slot)
    report = R.loader_source_census()
    assert len(expected) == 166 and report['slots'] == expected
    assert sum(bool(slot['descriptor']) for slot in expected) == 138
    assert len(referenced) == 89 and {r['file'] for r in report['overlays']} == referenced
    assert sum(r['in_window_catalogue'] for r in report['overlays']) == 39
    assert {r['file'].rsplit('/', 1)[-1] for r in report['other_v_files']} == {
        'VB5A21.BIN', 'VB5B31.BIN', 'VIC.BIN', 'VRE.BIN', 'VC61.BIN'}
    group = word(0x8016B358 + 15*4)
    companions = set()
    for index in range(3):
        descriptor = word(group + 4*index)
        companions.add(next(r['path'] for r in files if (r['size'], r['lba']) == (
            word(descriptor), word(descriptor + 4))))
    slus_source = next(r for r in files if r['path'] == 'SLUS_002.92')
    slus = extract(slus_source['lba'], slus_source['size'])[2048:]
    sw = lambda address: struct.unpack_from('<I', slus, address - 0x80010000)[0]
    characters = set()
    for index in range(78):
        descriptor = sw(0x80044D94 + 8*index + 4)
        characters.add(next(r['path'] for r in files if (r['size'], r['lba']) == (
            sw(descriptor), sw(descriptor + 4))))
    for other in report['other_v_files']:
        assert other['resource_role'] == ('group15 data companion' if other['file'] in companions
                                          else '04_PLAY character container')
        assert other['file'] in companions | characters
    assert {r['file'].rsplit('/', 1)[-1] for r in report['overlays'] if not r['candidate_entries']} == {
        'VA4B.BIN', 'VZ7.BIN', 'VZ8.BIN', 'VZV.BIN'}
    assert all(r['source_frontier'] for r in report['overlays'] if not r['candidate_entries'])
    retained = json.loads((KIT / 'data/reports/campaign_coverage.json').read_text())
    assert report == retained['source_inventory']
    print('PASS: 166 physical slots, 138 descriptor references, 89 overlays; '
          '50 sources outside the window catalogue, four explicit header/loader frontiers')


if __name__ == '__main__':
    check()
