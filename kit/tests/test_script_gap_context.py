#!/usr/bin/env python3
"""Independent source/consumer checks for apparent dialogue gaps in typed data."""
import json
from pathlib import Path
import re
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import build_script_corpus as C
import disc
import lzss
import memcard_text_tail as T


def check():
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())

    def read(name):
        rec = next(r for r in files if r['path'].rsplit('/', 1)[-1] == name)
        return disc.extract(rec['lba'], rec['size'])

    def word(data, off):
        return struct.unpack_from('<I', data, off)[0]

    def ptr(data, off):
        target = word(data, off) - 0x80010000
        assert 0 <= target < len(data)
        return target

    # Derive room arrays without the corpus/area helper, using the loader's
    # actual pointer and byte-count chain, then check exact field positions.
    table = C.load_dialogue()
    witnesses = {
        'VAAD.BIN': [(0x8162, 0, 7, 2), (0x8192, 0, 9, 2), (0x87F4, 1, 18, 0)],
        'VB7D.BIN': [(0xC3AE, 0, 8, 2), (0xC3C4, 0, 9, 0)],
        'VAA.BIN': [(0x509A4, 1, 23, 16)],
    }
    for name, cases in witnesses.items():
        data = read(name)
        root = ptr(data, 0)
        rooms = ptr(data, root + 8)
        for pc, room, entry, field in cases:
            room_off = rooms + 16 * room
            start = ptr(data, room_off)
            count = data[room_off + 4]
            assert entry < count
            assert pc == start + 24 * entry + field
            assert data[pc] == 0x1C
            streams = [ptr(data, start + 24 * entry + f) for f in (16, 20)]
            assert pc not in streams
            assert any(lo <= pc < hi and 'entity records' in label
                       for lo, hi, label in C.data_ranges(data, name, table))

    # The last current gap is 'l' + line break + 't' + 'h' inside Hanzo's
    # already recovered string, selected by the game's double-indirect table.
    data = read('VAAD.BIN')
    root = ptr(data, 0)
    subtable = ptr(data, ptr(data, root + 20))
    text = ptr(data, subtable + 18 * 4)
    assert text == 0x8ED4
    end = data.index(0, text)
    assert text <= 0x8F26 < end and data[0x8F26:0x8F2A] == bytes.fromhex('1c012418')
    decoded = T.decode(data[text:end])
    assert decoded == table['VAAD.BIN', 0, 18][1]
    assert 'fields until\nthis moment arrived.' in decoded

    # Historical VD2 gap: independently walk section -> context -> page bank.
    data = read('VD2.BIN')
    root = ptr(data, 0)
    section = ptr(data, ptr(data, root + 4))
    context = ptr(data, ptr(data, section + 32))
    assert context == 0x20614 and data[context + 4] == 15
    bank = ptr(data, context + 8)
    page = ptr(data, bank + 14 * 4)
    length = word(data, page)
    assert page == 0x43960 and length == 8195
    assert page + 4 <= 0x4561B < page + 4 + length
    plane, used = lzss.decode_container(data[page:page + 4 + length])
    assert used == length + 4 and len(plane) == 16384
    # The other reported VD2 [26,0] has no offset and no matching raw bytes.
    # This is a check on the old corpus attribution, not gameplay absence.
    for raw in (bytes.fromhex('1c001a00'), bytes.fromhex('1c011a00')):
        assert data.find(raw) == -1
        assert not any(data[p:p + 4] == raw for p in range(len(data) - 3))

    # Loader, coordinate readers, classifier and fresh-cursor installer.
    # These are exact raw instructions, independently extracted from MAIN.
    main = read('MAIN.EXE')[2048:]
    anchors = {
        0x801310A0: 0xAC22C108, 0x80131440: 0xAC22C108,
        0x80132068: 0x8C830008, 0x80132080: 0x00021100,
        0x80132088: 0x8C430000, 0x80132098: 0xAC23BF98,
        0x8012EDB8: 0x8E94BF98, 0x8012EEC8: 0x26100018,
        0x80137608: 0x92630000, 0x80137630: 0x9223FFF6,
        0x8013F200: 0x8C430000, 0x8013F218: 0x90420004,
        0x8013F238: 0x0C04F6DB, 0x8013F24C: 0x0C04F85F,
        0x8013F268: 0x24420018, 0x8013DBF0: 0x8C500010,
        0x8013E1F8: 0x8C420014, 0x8013E204: 0xAC22AF84,
        0x8013B8F8: 0x90850000, 0x8013B918: 0x8CC60014, 0x8013B928: 0x8C630000,
        0x8013B934: 0x8C440000,
        0x8012E9A8: 0x8C420020, 0x8012E9B0: 0x8C440000,
    }
    for va, expected in anchors.items():
        assert word(main, va - 0x800C0800) == expected, hex(va)

    # Unknown context stays unresolved; typed text context gets an annotation.
    raw = bytes.fromhex('1c000300')
    _, stats = C.decode_window(raw, 0, len(raw), 'X.BIN', {})
    assert stats['gaps_real'] == 1 and stats['gaps_data'] == 0
    lines, stats = C.decode_window(raw, 0, len(raw), 'X.BIN',
                                  {('X.BIN', 0, 0): ('0x0', 'fixture')})
    assert stats['gaps_data'] == 1 and stats['gaps'] == 0
    assert 'DATA CONTEXT' in '\n'.join(lines)
    for addr in ('0xff', '0x4'):
        try:
            C.data_ranges(b'\x01\x02\x03\x04', 'X.BIN',
                          {('X.BIN', 0, 0): (addr, 'fixture')})
        except ValueError:
            pass
        else:
            raise AssertionError('out-of-source text metadata accepted')
    try:
        C.data_ranges(b'\x01\x02\x03\x04', 'X.BIN',
                      {('X.BIN', 0, 0): ('0x0', 'fixture')})
    except ValueError:
        pass
    else:
        raise AssertionError('unterminated text silently classified')
    # Re-derive all current plausible sites; count alone cannot settle them.
    found = set()
    for name in ('VAAD.BIN', 'VB7D.BIN'):
        data = read(name)
        lines, stats = C.decode_window(data, C.CLUSTERS[name], C.WINDOW, name, table)
        assert stats['gaps_real'] == 0
        pc = None
        for line in lines:
            match = re.match(r'\s*(0x[0-9a-f]+): op', line)
            if match:
                pc = int(match[1], 16)
            if 'DATA CONTEXT' in line and 'speaker=' in line:
                speaker = int(line.split('speaker=')[1].split()[0])
                if speaker in (0, 1):
                    found.add((name, pc))
    assert found == {('VAAD.BIN', p) for p in (0x8162, 0x8192, 0x87F4, 0x8F26)} | {
        ('VB7D.BIN', 0xC3AE), ('VB7D.BIN', 0xC3C4)}
    print('PASS: 6 current gap contexts, 2 historical sites, 24 raw producer/consumer anchors; no untyped gap silently closed')


if __name__ == '__main__':
    check()
