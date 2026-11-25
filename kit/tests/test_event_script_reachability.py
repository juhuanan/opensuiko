#!/usr/bin/env python3
"""Branch arithmetic, strict graph frontiers, and independent stream lifecycle anchors."""
import hashlib
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import disc
import event_script_reachability as R
import build_script_corpus as C


def check():
    assert R.first_room_stream_candidate(b'') is None
    sample = bytearray(256)
    for off, value in [(0, 4), (12, 64), (24, 32), (64, 128), (140, 96)]:
        struct.pack_into('<I', sample, off, 0x80010000 + value)
    sample[68] = 1
    assert R.first_room_stream_candidate(sample)['room_slots'] == 2
    for target in [0, 0x80010000 + 95, 0x80010000 + 256]:
        struct.pack_into('<I', sample, 140, target)
        assert R.first_room_stream_candidate(sample) is None
    sample[68] = 255
    assert R.first_room_stream_candidate(sample) is None
    assert R.successors(bytes.fromhex('14 03'), 0, 0x14, b'\x03') == [4]
    assert R.successors(bytes.fromhex('f8 f8 23 02'), 2, 0x23, b'\x02') == [1]
    assert R.successors(bytes.fromhex('15 03 05 07'), 0, 0x15, b'\x03\x05\x07') == [4, 8, 10]
    assert R.successors(bytes.fromhex('15 01'), 0, 0x15, b'\x01') == [2]
    assert R.successors(bytes.fromhex('fc f8 2d fc'), 2, 0x2D, b'\xfc') == [1]
    assert R.successors(bytes.fromhex('2e fc f8 fc'), 0, 0x2E, b'\xfc') == [4]
    assert R.successors(bytes.fromhex('2d 2d'), 0, 0x2D, b'\x2d') == [1]
    assert R.successors(bytes.fromhex('2f 82 fc fe fc fd'), 0, 0x2F, b'\x82\xfc') == [3, 4]
    g = R.walk(bytes.fromhex('23 01'), [0, 0])
    assert len(g['nodes']) == 1 and g['nodes'][0]['next'] == [0]
    # A frame yield is not a stream terminator; the subsequent FD is a boundary.
    g = R.walk(bytes.fromhex('31 fd 52'), [0])
    assert [n['offset'] for n in g['nodes']] == [0, 1] and g['inline_exits'] == 1
    assert R.walk(bytes.fromhex('03 ff 52'), [0])['inline_exits'] == 1
    assert len(R.walk(bytes.fromhex('52 fd'), [0])['nodes']) == 1
    assert R.walk(bytes.fromhex('14 ff'), [0])['frontier'][0]['reason'] == 'outside source file'
    assert 'label not found' in R.walk(bytes.fromhex('2d fc'), [0])['frontier'][0]['reason']
    assert 'zero switch' in R.walk(bytes.fromhex('15 00'), [0])['frontier'][0]['reason']
    assert R.walk(b'\xfd', [0], [(0, 1, 'known data')])['frontier'][0]['reason'] == 'known data'

    assert R.walk(bytes.fromhex('3d 01 fd'), [0])['frontier'] == [
        {'offset': 0, 'reason': 'overlay callback continuation unresolved'}]
    assert 'truncated' in R.walk(b'\x3d', [0])['frontier'][0]['reason']

    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    def read(name):
        rec = next(r for r in files if r['path'].rsplit('/', 1)[-1] == name)
        return disc.extract(rec['lba'], rec['size'])
    main = read('MAIN.EXE')[2048:]
    base = 0x800C0800
    # Guard the full selector and prefix scanner, including their delay slots.
    for start, end, digest in [
            (0x8013F1BC, 0x8013F2A4, '4db7aede2434499dc42779af0e3646a822c5b88a69da97f48bfdd93e5e8cb007'),
            (0x801372CC, 0x80137304, '97995f7f99b9fe4eab4bb0e428203df14fb79579ea1ab99ad7acb03c1cf325c8')]:
        assert hashlib.sha256(main[start - base:end - base]).hexdigest() == digest, hex(start)
    anchors = {
        0x8013F11C: 0x0C04FC30, 0x8013F12C: 0x0C04F80A,
        0x8013F124: 0x14400004, 0x8013E1C0: 0xA020A180,
        0x8013F24C: 0x0C04F85F, 0x8013F31C: 0x0C04F85F,
        0x8013D230: 0xA022A180, 0x8013D240: 0xA020A180,
        0x8013E158: 0x9042A180, 0x8013E160: 0x1440FFB4,
        0x8013E0D0: 0x0C04EFE5, 0x8013E0D8: 0x00408021,
        0x8013E0DC: 0x3C028018, 0x8013E108: 0xAC22AF84,
        0x8013E118: 0xA0201C28, 0x8013E130: 0x0804F85B,
        0x80132B80: 0x90421C28, 0x80132B90: 0x10400007,
        0x80142C78: 0x3C028018, 0x80142C7C: 0x2442AF84,
        0x80142C84: 0xAC22DA44, 0x801440C8: 0x8C420010,
        0x801440D8: 0x8E020000, 0x801440EC: 0x0040F809,
        0x8013B918: 0x8CC60014,
        # Room table, room byte, shift by four, and entity pointer/count.
        0x8013F1DC: 0x8C430008, 0x8013F1F0: 0x90420001, 0x8013F1F8: 0x00021100,
        0x8013F200: 0x8C430000, 0x8013F214: 0xAC23A120, 0x8013F218: 0x90420004,
        0x8013F2D0: 0x90420001, 0x8013F2D8: 0x00021100,
        0x8013DBBC: 0x30420010, 0x8013DBC0: 0x14400008,
        0x8013DBD8: 0x30420010, 0x8013DBDC: 0x1440010E,
        0x8013E004: 0x92030000, 0x8013E008: 0x34020006,
        0x8013E00C: 0x1462FEFB, 0x8013E014: 0x34020001,
        # Zero count exits. Rejection steps by 24 until count, acceptance exits.
        0x8013F22C: 0x10400015, 0x8013F238: 0x0C04F6DB, 0x8013F23C: 0x02602021,
        0x8013F244: 0x10400005, 0x8013F248: 0x26100001, 0x8013F254: 0x0804FCA2,
        0x8013F268: 0x24420018, 0x8013F278: 0x0052102B, 0x8013F27C: 0x1440FFEE,
        0x8013E1F0: 0x8C42A120, 0x8013E1F8: 0x8C420014, 0x8013E204: 0xAC22AF84,
        0x8013F334: 0x3C028018, 0x8013F340: 0x24420018,
        0x8013F354: 0x1440FFEC,
        # Byte 6 may occur immediately. The loop undoes its final delay-slot increment.
        0x801372D0: 0x34020006, 0x801372D4: 0x10620008, 0x801372E0: 0x24840003,
        0x801372EC: 0x1443FFFD, 0x801372F0: 0x24840003, 0x801372F4: 0x2484FFFD,
        0x801372F8: 0x90820001, 0x80137584: 0x8E240000, 0x80137588: 0x0C04DCB3,
        0x8013A3F0: 0x34020001, 0x8013A3F4: 0xA3A20000,
        0x8013A458: 0x2463FFFF, 0x8013A468: 0x9042FFFF,
        0x8013A598: 0x2443FFFF, 0x8013A5A4: 0x9043FFFF,
        0x8013A610: 0x24430001, 0x8013A61C: 0x90430001,
    }
    for va, value in anchors.items():
        assert struct.unpack_from('<I', main, va - base)[0] == value, hex(va)
    # Independent raw direct-call census, rather than the semantic scanner.
    target = 0x8013E17C
    sites = []
    for off in range(0, len(main) - 3, 4):
        word = struct.unpack_from('<I', main, off)[0]
        va = base + off
        if word >> 26 == 3 and ((va & 0xF0000000) | ((word & 0x3FFFFFF) << 2)) == target:
            sites.append(va)
    assert sites == [0x8013F24C, 0x8013F31C]
    # Specifically the ordinary pump's call instructions: no reset call there.
    calls = [struct.unpack_from('<I', main, va - base)[0]
             for va in range(0x8013F110, 0x8013F1BC, 4)]
    assert not any(w >> 26 == 3 and (w & 0x3FFFFFF) << 2 == (target & 0x0FFFFFFF)
                   for w in calls)

    table = C.load_dialogue()
    reports = KIT / 'data/reports'
    summaries = json.loads((reports / 'script_reachability_summary.json').read_text())['overlays']
    for name, count, nodes, exits, room_count in [
            ('VAAD.BIN', 60, 394, 13, 2), ('VB7D.BIN', 35, 596, 12, 2),
            ('VA7.BIN', 68, 634, 60, 14), ('VAC.BIN', 82, 421, 53, 18),
            ('VB1.BIN', 68, 1241, 63, 6), ('VAD.BIN', 102, 1038, 75, 11)]:
        data = read(name)
        # The text root marks the neighboring object: these source room
        # intervals end at that object; no 64-record heuristic is needed here.
        ptr = lambda off: struct.unpack_from('<I', data, off)[0] - 0x80010000
        root = ptr(0); rooms = ptr(root + 8); text = ptr(root + 20)
        assert text - rooms == 16 * room_count
        assert R.room_source_bound(data)['upper_bound'] == text
        expected = []
        for room in range(room_count):
            off = rooms + 16 * room; entries = ptr(off)
            for index in range(data[off + 4]):
                expected.append(ptr(entries + index * 24 + 20))
        entries = R.entry_roots(data)
        assert len(entries) == count and [e['offset'] for e in entries] == expected
        for entry in entries:
            record = entry['record']
            flags = struct.unpack_from('<H', data, record + 4)[0]
            assert entry['selection_mode'] == ('initialization' if flags & 16 else 'ordinary')
            classifier = ptr(record + 16)
            assert entry['unconditional_classifier'] == (data[classifier] == 6)
        contexts = C.data_ranges(data, name, table)
        if name == 'VAC.BIN':
            assert not any(lo <= 0x4164E < hi and 'entity records' in label for lo, hi, label in contexts)
        graph = R.walk(data, expected, contexts)
        assert graph['frontier'] == [] and len(graph['nodes']) == nodes
        assert graph['inline_exits'] == exits
        summary = next(r for r in summaries if r['file'].endswith('/' + name))
        assert (summary['entries'], summary['nodes'], summary['inline_exits']) == (count, nodes, exits)
        assert summary['unique_streams'] == len(set(expected))
        assert summary['frontier'] == graph['frontier']
        assert summary['dialogue_sites'] == [n['offset'] for n in graph['nodes'] if n.get('opcode') == 0x1C]
        for node in graph['nodes']:
            if node.get('opcode') == 0x1C:
                pc = node['offset']
                assert (name, data[pc + 2], data[pc + 3]) in table
        if name == 'VAAD.BIN':
            phase = R.walk(data, [0x7FB0])
            assert [n['offset'] for n in phase['nodes']] == [0x7FB0, 0x7FB1, 0x7FB5, 0x7FB9, 0x7FBC, 0x7FBD]
        elif name == 'VB1.BIN':
            assert data[0x20C06:0x20C09] == bytes.fromhex('20 1e fd')
            by_pc = {n['offset']: n for n in graph['nodes']}
            assert by_pc[0x20C06]['next'] == [0x20C08]
            assert by_pc[0x20C08]['stop'] == 'inline wait/stream exit'
        elif name == 'VAD.BIN':
            by_pc = {n['offset']: n for n in graph['nodes']}
            assert by_pc[0x4CC24]['next'] == [0x4CC24, 0x4CC2A]
            assert by_pc[0x4CC24]['callback'] == {'target': 0x8001426C, 'operands': 4}
            assert by_pc[0x4CC2A]['next'] == [0x4CC2A, 0x4CC2F]
            assert by_pc[0x4CC2A]['callback'] == {'target': 0x80017BB4, 'operands': 3}
            assert by_pc[0x4CD0F]['next'] == [0x4CD0F, 0x4CD13]
            assert by_pc[0x4CD0F]['callback'] == {'target': 0x80016434, 'operands': 2}
            assert by_pc[0x4CD13]['next'] == [0x4CD1B]
            assert by_pc[0x4CD13]['callback'] == {'target': 0x800157A0, 'operands': 6, 'retry': False}
            for site in [0x4CD39, 0x4CD61, 0x4CD89, 0x4CDB1]:
                assert by_pc[site]['next'] == [site, site + 5]
                assert by_pc[site]['callback'] == {'target': 0x8001AC90, 'operands': 3}
            assert by_pc[0x4CDE3]['next'] == [0x4CDE3, 0x4CDED]
            assert by_pc[0x4CDE3]['callback'] == {'target': 0x8001CF34, 'operands': 8}
            assert by_pc[0x4CDED]['next'] == [0x4CDF0]
            assert by_pc[0x4CDED]['callback'] == {'target': 0x80015934, 'operands': 1, 'retry': False}
            assert by_pc[0x4CE0E]['next'] == [0x4CE0E, 0x4CE12]
            for first in range(256):
                payload = bytes([255, 19, 33]) if first == 255 else bytes([first, 33])
                optional = R.walk(data + bytes([0x3D, 15]) + payload + b'\xfd', [len(data)])
                assert optional['frontier'] == []
                assert [n['offset'] for n in optional['nodes']] == [len(data), len(data) + 2 + len(payload)]
            for selector, body in [(28, 0xAC90), (2, 0xCF34), (19, 0x5934), (15, 0x9290)]:
                script = data + bytes([0x3D, selector]) + bytes(8)
                altered = bytearray(script); altered[body] ^= 1
                assert R.callback_cursor(altered, len(data)) is None
            assert R.walk(data + bytes([0x3D, 15, 255]), [len(data)])['frontier'][0]['reason'] == 'truncated overlay callback operands'
            for size in range(256):
                script = data + bytes([0x3D, 18, 4, size]) + bytes(range(size)) + b'\xfd'
                counted = R.walk(script, [len(data)])
                assert counted['frontier'] == []
                assert [n['offset'] for n in counted['nodes']] == [len(data), len(data) + 4 + size]
                assert counted['nodes'][0]['next'] == [len(data) + 4 + size]
            assert R.walk(data + bytes([0x3D, 18, 4]), [len(data)])['frontier'][0]['reason'] == 'truncated overlay callback operands'
            for size in (1, 255):
                short = data + bytes([0x3D, 18, 4, size]) + bytes(size - 1)
                assert R.walk(short, [len(data)])['frontier'][0]['reason'] == 'truncated overlay callback operands'
            for site, body in [(0x4CD0F, 0x1759C - 0x10000), (0x4CD13, 0x57A0)]:
                altered = bytearray(data); altered[body] ^= 1
                assert R.callback_cursor(altered, site) is None
            for site in [0x4CCE9, 0x4CCF0, 0x4CCF7, 0x4CCFE]:
                assert by_pc[site]['next'] == [site, site + 7]
                assert by_pc[site]['callback'] == {'target': 0x8001C818, 'operands': 5}
            for site, body in [(0x4CC2A, 0x7BB4), (0x4CCE9, 0xC818)]:
                altered = bytearray(data); altered[body] ^= 1
                assert R.callback_cursor(altered, site) is None
            # A changed callback body or import slot cannot inherit the contract.
            altered = bytearray(data); altered[0x426C] ^= 1
            assert R.callback_cursor(altered, 0x4CC24) is None
            altered = bytearray(data); struct.pack_into('<I', altered, ptr(root + 16) + 4*17, 0x800134C8)
            assert R.callback_cursor(altered, 0x4CC24) is None
            assert 'truncated overlay callback operands' == R.walk(data + b'\x3d\x07', [len(data)])['frontier'][0]['reason']
            functions = ptr(root + 16)
            assert ptr(functions + 4 * 11) == 0xC818
            callback_words = {
                0xC850: 0xAC2490BC, 0xC8F4: 0x8C620004,
                0xC928: 0x8C420000, 0xC930: 0x90420000,
                0xC940: 0x8C620000, 0xC948: 0x24420001,
                0xC94C: 0xAC620000, 0xC964: 0x8C420000,
                0xC96C: 0x90420000, 0xC984: 0x24420001,
                0xC988: 0xAC620000,
            }
            for offset, word in callback_words.items():
                assert struct.unpack_from('<I', data, offset)[0] == word
        elif name == 'VB7D.BIN':
            by_pc = {n['offset']: n for n in graph['nodes']}
            assert by_pc[0xC70C]['next'] == [0xC70C, 0xC711]
            assert by_pc[0xC70C]['callback'] == {'target': 0x800134C8, 'operands': 3}
            assert by_pc[0xC711]['opcode'] == 0x2A
            assert by_pc[0xC0F4]['next'] == [0xC081]
            assert by_pc[0xC5E7]['next'] == [0xC5EA, 0xC601]
    data = read('VD4.BIN')
    # The command reads a mode, then advances once for each of two actor lookups.
    for offset, word in {0x19C4: 0x90530000, 0x19D0: 0x24420001,
                         0x19F4: 0x90440000, 0x19F8: 0x24420001,
                         0x1A30: 0x2C420002, 0x1A34: 0x1440FFE8}.items():
        assert struct.unpack_from('<I', data, offset)[0] == word
    graph = R.walk(data, [0x411A0], C.data_ranges(data, 'VD4.BIN', table))
    assert graph['frontier'] == []
    by_pc = {node['offset']: node for node in graph['nodes']}
    for site in (0x412CC, 0x4137A):
        assert by_pc[site]['callback'] == {'target': 0x80011994, 'operands': 3, 'retry': False}
        assert by_pc[site]['next'] == [site + 5]
    assert by_pc[0x413DB]['stop'] == 'inline wait/stream exit'
    assert all(node.get('opcode') not in (0x43, 0x47) for node in graph['nodes'])
    altered = bytearray(data)
    altered[0x19F8] ^= 1
    assert R.callback_cursor(altered, 0x412CC) is None
    # Independently walk every physical room record in all18 following-text bounds.
    # The selector visits the full byte count when its predicate rejects;
    # classifier feasibility and whether the supplied room occurs in play remain open.
    bounded = physical_rooms = raw_entries = candidate_prefixes = 0
    prefix_results = bytearray()
    for name in R.CLUSTERS:
        data = read(name)
        ptr = lambda off: struct.unpack_from('<I', data, off)[0] - 0x80010000
        root = ptr(0); rooms = ptr(root + 8); text = ptr(root + 20)
        if not 0 <= rooms < text < len(data):
            # Prefix structure supports a neighboring stream, not an exhaustive room bound.
            entries = ptr(rooms); count = data[rooms + 4]
            targets = [(ptr(entries + 24*i + 12), i) for i in range(count)]
            target, index = min((off, i) for off, i in targets if rooms < off < len(data))
            assert (target - rooms) % 16 == 0
            proposed = R.first_room_stream_candidate(data)
            assert proposed == {
                'offset': target,
                'entry_index': index,
                'pointer_field_offset': entries + 24 * index + 12,
                'room_slots': (target - rooms) // 16,
                'status': 'inferred, not a canonical bound',
            }, name
            assert R.room_source_bound(data)['upper_bound'] is None
            step = data[target:-1:3].find(b'\x06')
            assert step >= 0, name
            terminator = target + 3 * step
            prefix_results.extend(struct.pack('<IIB', target, terminator, data[terminator + 1]))
            candidate_prefixes += 1
            continue
        assert (text - rooms) % 16 == 0
        expected_roots = []
        for room, off in enumerate(range(rooms, text, 16)):
            entry_start = ptr(off)
            count = data[off + 4]
            assert not count or 0 <= entry_start <= len(data) - 24 * count, (name, room)
            for index in range(count):
                record = entry_start + 24 * index
                expected_roots.append((room, index, record, ptr(record + 20)))
            physical_rooms += 1
        actual_roots = [(e['room'], e['entry'], e['record'], e['offset']) for e in R.entry_roots(data)]
        assert actual_roots == expected_roots, name
        raw_entries += len(expected_roots)
        bounded += 1
    assert (bounded, physical_rooms, raw_entries) == (18, 216, 1663)
    assert candidate_prefixes == 21
    # Each retained observation includes the candidate, terminator and returned byte.
    assert hashlib.sha256(prefix_results).hexdigest() == '9cecfe1389b9bc0fa502322c0c0bf831fc98eb7e26512fb7e8908bc0afce5f34'
    assert R.source_summary() == json.loads((reports / 'script_source_census.json').read_text())
    print(f'PASS: callback contracts/seven graphs; {bounded} physical intervals, '
          f'{physical_rooms} rooms, {raw_entries} entry pointers; '
          f'{candidate_prefixes} inferred neighboring prefixes checked statically')


if __name__ == '__main__':
    check()
