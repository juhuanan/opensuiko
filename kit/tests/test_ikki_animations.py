#!/usr/bin/env python3
"""Independent descriptor reads, bytecode boundaries, and timer/order witnesses."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import disc
import ikki_animations as anim


def main():
    report = anim.extract()
    counts = {'PAN': 42, 'TEO': 42, 'SHU': 50, 'KWA': 42}
    total_f, total_e = 0, 0
    for ov in report['overlays']:
        b = disc.extract(ov['lba'], ov['size'])
        u32 = lambda o: int.from_bytes(b[o:o + 4], 'little')
        rel = lambda o: u32(o) - 0x80080000
        for family in ov['families']:
            ctx = family['context_offset']
            ne = int.from_bytes(b[ctx:ctx + 2], 'little')
            nf = int.from_bytes(b[ctx + 2:ctx + 4], 'little')
            assert ne == counts[family['family']] and nf == 49
            total_e += ne
            total_f += nf
            for i, pose in enumerate(family['poses']):
                off = rel(rel(ctx + 16) + 4 * i)
                assert pose['offset'] == off
                assert pose['anchor'] == list(b[off + 4:off + 6])
                assert len(pose['pieces']) == b[off]
                for k, piece in enumerate(pose['pieces']):
                    assert piece['raw'] == list(b[off + 8 + k * 8:off + 16 + k * 8])
            for i, f in enumerate(family['animations']):
                off = rel(rel(ctx + 20) + 4 * i)
                raw = b[off:off + 4 + 2 * b[off]]
                assert f['offset'] == off
                assert f['flags'] == raw[1]
                assert f['steps'] == [[raw[j], raw[j + 1]] for j in range(4, len(raw), 2)]
                assert f['total_ticks'] == sum(raw[5::2])
            assert [f['id'] for f in family['animations'] if not f['count']] == [29, 31, 33, 35]
            assert not set((29, 31, 33, 35)) & {j for row in ov['directions'] for j in row}
            death = family['animations'][48]
            expected = {'PAN': [[0, 1], [16, 11], [40, 24], [41, 1]],
                        'TEO': [[4, 1], [18, 11], [40, 1]],
                        'SHU': [[0, 1], [20, 11], [40, 24], [41, 1]],
                        'KWA': [[4, 1], [18, 11], [40, 16], [41, 1]]}
            if family['family'] == 'TEO' and ov['overlay'].endswith('SHU_TEO.BIN'):
                expected['TEO'] = [[4, 1], [18, 11], [40, 24], [41, 1]]
            assert death['steps'] == expected[family['family']] and not death['loop']
        # Independent word-stream parsing, using handler-proven command lengths.
        sizes = [1, 1, 9, 2, 2, 1, 2, 1, 1, 2, 4, 1, 4, 2, 2]
        for pair in ov['rounds']:
            for actor, commands in enumerate(pair['scripts']):
                offset = rel(ov['script_tables'][actor] + pair['outcome_id'] * 4)
                for command in commands:
                    words = struct.unpack_from('<' + 'h' * sizes[command['op']], b, offset)
                    assert command['offset'] == offset and words[0] == command['op']
                    assert list(words[1:]) == command['args']
                    offset += sizes[words[0]] * 2
                assert words[0] == 0
        for off, instruction in {
            0x58E4: 0x90440001,  # duration byte
            0x58F0: 0xA2640003,  # remaining timer
            0x6318: 0x2442FFFF,  # decrement once per update
            0x6334: 0x24420001,  # next frame
            0x6358: 0xA0800002,  # loop reset
            0x6360: 0xA0800009,  # one-shot stops
        }.items():
            assert u32(off) == instruction, hex(off)
        assert u32(0x69E4) == 0x24630002
        assert u32(0x697C + 0x34) == 0x8E030078  # actor direction map
        assert u32(0x1FD0) == 0x0C021939  # script updates before sprite updates
        assert u32(0x20A0) == 0x0C020EAE
        assert u32(0x3B60) == 0x0C0218BE  # fighter timer update once in actor loop
        assert ov['choice_names'] == ['Attack', 'Defend', 'Desperate attack']
        assert u32(0x70E4) == 0xAC6207D0  # random opponent choice
        assert u32(0x75B0) == 0xAC4407D4  # menu player choice
    assert (total_e, total_f) == (268, 294)

    for name in ('SHU', 'TEO'):
        fs = [f for ov in report['overlays'] for f in ov['families'] if f['family'] == name]
        normalize = lambda f: [{k: v for k, v in e.items() if k != 'offset'} for e in f['poses']]
        assert normalize(fs[0]) == normalize(fs[1])
        mismatches = [i for i in range(49) if fs[0]['animations'][i]['steps'] != fs[1]['animations'][i]['steps']]
        assert mismatches == ([] if name == 'SHU' else [48])

    # Timer reference: pre-decrement callbacks consume the first duration before drawing.
    death = report['overlays'][0]['families'][0]['animations'][48]
    state = {}
    anim.select(state, death)
    assert state['pose'] == 0
    samples = []
    for _ in range(40):
        anim.tick_animation(state)
        samples.append(state['pose'])
    assert samples == [16] * 11 + [40] * 24 + [41] * 5
    assert state['active'] is False
    loop = report['overlays'][1]['families'][0]['animations'][32]
    anim.select(state, loop)
    samples = []
    for _ in range(8):
        anim.tick_animation(state)
        samples.append(state['pose'])
    assert samples == [32, 33, 33, 32, 32, 33, 33, 32] and state['active']

    # Hand-derived paired attack/block timing from the instruction order and wait values.
    ov = report['overlays'][0]
    schedule = anim.schedule(ov, 2)
    events = [(e['tick'], e['actor'], e['op'], e['args']) for e in schedule['events'] if e['op'] in (3, 6)]
    assert events == [(-1, 0, 3, [3]), (9, 0, 3, [1]), (29, 0, 3, [0]),
                      (34, 0, 3, [2]), (44, 0, 3, [4]), (56, 0, 3, [5]),
                      (57, 0, 6, [0]), (57, 1, 3, [8]), (89, 1, 3, [0]),
                      (91, 1, 6, [1]), (103, 0, 6, [2]), (103, 0, 3, [3]),
                      (104, 1, 6, [6]), (113, 0, 3, [6]), (143, 0, 3, [3]),
                      (153, 0, 3, [0]), (155, 0, 6, [5])]
    assert schedule['updates_to_quiescence'] == 156
    for ov in report['overlays']:
        for outcome in range(1, 10):
            for direction in range(8):
                schedule = anim.schedule(ov, outcome, direction)
                assert sum(r['ticks'] for r in schedule['render_runs']) == schedule['updates_to_quiescence']
    print('IC animations PASS: 294 F descriptors, 268 E poses, 54 scripts, 216 paired schedules')


if __name__ == '__main__':
    main()
