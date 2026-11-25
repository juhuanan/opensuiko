#!/usr/bin/env python3
"""Independent pointer/byte re-derivation and instruction checks; disc required."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import battle_placement as bp
from mipsdec import dec


def check():
    main, _ = bp.read_file('MAIN.EXE')
    area, _ = bp.read_file('DATA/08_AREA.E/E_DATA.BIN')
    # Second extraction through the other disc container; no raw disc opens.
    disc_root = bp.KIT.parent / 'disc'
    compared = []
    for suffix in ('bin', 'iso'):
        alternate = disc_root / f'Suikoden (v1.1).{suffix}'
        if not alternate.exists():
            continue
        assert bp.read_file('MAIN.EXE', str(alternate))[0] == main
        assert bp.read_file('DATA/08_AREA.E/E_DATA.BIN', str(alternate))[0] == area
        compared.append(suffix)

    # Independent reader uses byte arithmetic and literal pointer relations,
    # without calling the producer's pointer or struct readers.
    u = lambda off: int.from_bytes(area[off:off + 4], 'little')
    p = lambda off: u(off) - 0x80080000
    directory = p(p(p(0) + 12))
    selectors = p(directory + 8)
    assert (directory, selectors, u(selectors)) == (0x161b8, 0x16188, 11)
    parsed = bp.area_encounters(area)
    for index, encounter in enumerate(parsed['encounters'], 1):
        desc = p(selectors + index * 4)
        positions = p(p(desc + 20))
        assert positions == (0x15fe4 if index in (1, 9, 10, 11) else 0x16008)
        assert encounter['positions_offset'] == positions
        for slot in encounter['slots']:
            start = positions + slot['slot'] * 6
            triple = tuple(int.from_bytes(area[start + n:start + n + 2],
                                          'little', signed=True) for n in (0, 2, 4))
            assert slot['triple'] == triple
            flag = int.from_bytes(area[slot['stats_offset'] + 38:
                                       slot['stats_offset'] + 40], 'little')
            assert slot['world_q12'] == [(triple[0] - 128) * 4096,
                                        triple[1] * 4096,
                                        (triple[2] - (10 if flag & 32 else 0)) * 4096]
    expected = [(120, 50, 0), (112, 0, 0), (120, -50, 0),
                (192, 75, 0), (178, 25, 0), (178, -25, 0)]
    assert [r['world'] for r in bp.party_positions(main)] == expected
    # Pointer-selected tables also work where a four-column shape scan failed.
    counts = 0
    tables = 0
    for directory_name, letter in [('01_AREA.A', 'A'), ('02_AREA.B', 'B'),
                                   ('06_AREA.C', 'C'), ('07_AREA.D', 'D'),
                                   ('08_AREA.E', 'E'), ('09_AREA.F', 'F'),
                                   ('10_AREA.G', 'G'), ('11_AREA.H', 'H')]:
        raw, _ = bp.read_file(f'DATA/{directory_name}/{letter}_DATA.BIN')
        records = bp.area_encounters(raw)['encounters']
        counts += len(records)
        tables += len({r['positions_offset'] for r in records})
    assert (counts, tables) == (77, 18)
    base = int.from_bytes(main[24:28], 'little')
    # Verify stores, spawn callers, skipped table entry, and mode dispatcher.
    words = {0x800decfc: 0xae020068, 0x800ded20: 0xae02006c,
             0x800ded38: 0xae020070, 0x800df000: 0xae020068,
             0x800df028: 0xae02006c, 0x800df080: 0xae020070,
             0x800de7fc: 0x0c037afa, 0x800de804: 0x0c037b91,
             0x800dec50: 0x24d70006, 0x800deeb4: 0x8c840000,
             0x800c9a74: 0x28620004, 0x800c9a80: 0x080326af,
             0x800c9ac0: 0x2442df98}
    for address, expected_word in words.items():
        off = 2048 + address - base
        word = int.from_bytes(main[off:off + 4], 'little')
        assert word == expected_word, (hex(address), dec(address, word)[0])
    print('PASS: party, 11 independently re-derived E encounters, 13 instruction anchors; '
          f'77 encounters / 18 tables across A-H; containers compared: {compared}')


if __name__ == '__main__':
    check()
