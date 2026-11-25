#!/usr/bin/env python3
"""Static auto-route expansion and movement evidence."""
import hashlib
import itertools
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
from disc import extract
import maindec as M
from event_script_reachability import build
from test_worldmap_points import main_words

# Independently stated direction/count pairs; directions N/E/S/W are 0/1/2/3.
PAIRS = [
    [(3, 18), (2, 5), (3, 5), (2, 12), (3, 5), (2, 2), (3, 25)],
    [(1, 23), (0, 5), (1, 5), (0, 5), (1, 15), (0, 11), (1, 10)],
    [(1, 23), (0, 5), (1, 5), (0, 5), (1, 15), (0, 11), (1, 10)],
    [(1, 23), (0, 5), (1, 5), (0, 5), (1, 15), (0, 11), (1, 10)],
    [(3, 19), (0, 1)],
]
DIRECTIONS = [(0, -1), (1, 0), (0, 1), (-1, 0)]


def check_consumers():
    image = M.body()
    for start, end, digest in [
            (0x80138A94, 0x80138AC4, '2e230eab7ec7c14e94ddbdd4790d2706dbfbb782fd26e9c99d08353f0c64f32b'),
            (0x801278B4, 0x801279E8, 'ca095b71b4c0e21d393c4aca05f5aebbc9e09ac45f80d8ca121ada5b41c983e1'),
            (0x80127784, 0x801277F0, '7a8811b0b3df78abbb6f31a5e227c1e4f8b4cd45ee76497d574c6c20fbe5b297'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)
    assert M.mword(0x80171718 + 4 * 0x4E) == 0x80138A94
    main_words({
        # Publish the operand and advance the script cursor by one.
        0x80138AA0: (0x24430001, 0x3C018018, 0xAC23AF84, 0x90420000, 0, 0x3C018017,
                     0xA022F2A7),
        # Clear the route index and fetch the compressed pointer.
        0x801278C0: (0x9042F2A7, 0x27BDFFE0, 0xAFBF0018, 0xA4600040, 0x00021080, 0x3C018017,
                     0x2421F2F0, 0x00220821, 0x8C250000),
        # First pass sums unsigned run lengths and allocates one terminator byte.
        0x801278E8: (0x90A30000, 0x00002021, 0x340200FF, 0x10620008, 0x24A50001,
                     0x340600FF, 0x90A30000, 0x24A50001, 0x90A20000, 0x24A50001, 0x1446FFFB,
                     0x00832021, 0x0C030B4C, 0x24840001),
        # Second pass uses the same selector. Zero-count runs skip the output loop.
        0x8012792C: (0x9063F2A7, 0x00404021, 0xAC88003C, 0x00031880, 0x3C018017, 0x2421F2F0,
                     0x00230821, 0x8C250000),
        0x80127958: (0x340200FF, 0x30C300FF, 0x14620003, 0x24A50001, 0x08049E76, 0xA1060000,
                     0x90A40000, 0x24A50001, 0x1080000B, 0x00001821),
        0x80127990: (0x24630001, 0x00471021, 0xA0460000, 0x0064102A, 0x1440FFF7, 0x24E70001,
                     0x90A60000, 0x340200FF, 0x30C300FF, 0x1462FFEE, 0x24A50001),
        0x801279C8: (0x8C42003C, 0, 0x00471021, 0xA0460000),
        # Consume an expanded byte only while ready. FF clears the route selector.
        0x80127794: (0x90A20022, 0, 0x10400010, 0, 0x94A20040, 0x8CA4003C, 0x24430001,
                     0xA4A30040, 0x00441021, 0x90440000, 0x340200FF, 0x10820005, 0x340200FF,
                     0x0C049D3A),
        0x801277D8: (0x3C018017, 0xA022F2A7),
        # This route caller goes straight to the stepper. An active selector returns
        # the requested heading with bit 0x80 before the normal terrain call.
        0x801274F4: (0x0C049C89, 0x308400FF, 0x00408021),
        0x80127240: (0x3C038017, 0x9063F2A7, 0x340200FF, 0x14620005, 0x00809821, 0x0C049C45),
        0x80127264: (0x08049CBF, 0x26620080),
        0x80127588: (0x1040002D, 0x34020010, 0x3C048018, 0x8C84A0B8, 0, 0x94830042,
                     0, 0x0043001A),
        0x801275CC: (0x00001012, 0xA0800022, 0x3C058018, 0x8CA5A0B8, 0xA4820020),
        0x8012760C: (0xA423F298,),
        0x8012763C: (0xA423F29A,),
        0x80127474: (0x94820020, 0, 0x2442FFFF, 0xA4820020, 0x94820020, 0, 0x14400012,
                     0x34030001, 0xA0830022),
        # FE supplies X/Y without changing region. FB adds the region byte before X/Y.
        0x8013BFBC: (0x340200FE,),
        0x8013BFC8: (0x1462000D, 0x340200FD, 0x24820002, 0x3C018018, 0xAC22AF84, 0x90830001,
                     0x24820003, 0x3C018018, 0xAC22AF84, 0x3C018017, 0xA423F298, 0x90850002,
                     0x0804F042),
        0x8013C08C: (0x340200FB,),
        0x8013C0D0: (0xA0620002,),
        0x8013C100: (0xA424F298, 0x90650001),
        0x8013C120: (0xA425F29A, 0x0804F08C, 0x34020001),
    })
    x_offsets = struct.unpack_from('<8h', image, 0x8016F31C - M.MBASE)
    y_offsets = struct.unpack_from('<8h', image, 0x8016F32C - M.MBASE)
    assert list(zip(x_offsets[::2], y_offsets[::2])) == DIRECTIONS


def route_positions(start, directions):
    x, y = start
    positions = [start]
    for direction in directions:
        dx, dy = DIRECTIONS[direction]
        x, y = (x + dx) & 65535, (y + dy) & 65535
        positions.append((x, y))
    return positions


def check():
    check_consumers()
    cases = 0
    routes = []
    step_counts = [72, 74, 74, 74, 20]
    displacement = [(-53, 19), (53, -21), (53, -21), (53, -21), (-19, -1)]
    for selector, pairs in enumerate(PAIRS):
        pointer = M.mword(0x8016F2F0 + 4*selector)
        raw = M.body()[pointer - M.MBASE:pointer - M.MBASE + 2*len(pairs) + 1]
        assert raw == bytes(itertools.chain.from_iterable(pairs)) + b'\xff'
        # Independently expand the bytes from the source table and verify the
        # allocation and terminator separately from the direction sequence.
        directions = b''.join(bytes([raw[i]]) * raw[i + 1] for i in range(0, len(raw) - 1, 2))
        stored = directions + raw[-1:]
        assert len(stored) == 1 + sum(raw[1:-1:2]) == 1 + step_counts[selector]
        assert stored.index(b'\xff') == len(directions)
        routes.append(directions)
        # Ordinary east and south requests are blocked at the second start.
        for start in [(67, 43), (140, 105)]:
            positions = route_positions(start, directions)
            x, y = start
            prefix = 0
            for direction, count in pairs:
                dx, dy = DIRECTIONS[direction]
                assert positions[prefix + 1:prefix + count + 1] == [
                    ((x + dx * i) & 65535, (y + dy * i) & 65535) for i in range(1, count + 1)]
                prefix += count
                x, y = (x + dx * count) & 65535, (y + dy * count) & 65535
            assert prefix + 1 == len(stored)
            assert positions[-1] == tuple(value + delta for value, delta in zip(start, displacement[selector]))
            cases += 1
    # One update decrements the clock, and a zero clock reopens readiness.
    countdown = M.mword(0x8012758C) & 0xFFFF  # speed = 1
    assert [frame for frame in range(1, countdown + 1) if countdown - frame == 0] == [16]

    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    # These are entry-rooted possible-path occurrences, not campaign witnesses.
    occurrences = [
        ('VB2.BIN', 0x2BFC4, 4, bytes.fromhex('03 fb 09 77 4b'), (119, 75), (100, 74), 75),
        ('VF2.BIN', 0x3DFC3, 1, bytes.fromhex('03 fe 0e 3c'), (14, 60), (67, 39), 60),
        ('VF3.BIN', 0x47EB7, 0, bytes.fromhex('03 fe 43 2b'), (67, 43), (14, 62), 62),
        ('VF3.BIN', 0x47F5F, 0, bytes.fromhex('03 fe 43 2b'), (67, 43), (14, 62), 62),
    ]
    graphs = {g['file'].rsplit('/', 1)[-1]: g for g in build(['VB2.BIN', 'VF2.BIN', 'VF3.BIN'])['overlays']}
    for name, site, selector, warp, start, end, max_row in occurrences:
        source = next(r for r in files if r['path'].endswith('/' + name))
        data = extract(source['lba'], source['size'])
        assert data[site:site + 2 + len(warp)] == bytes([0x4E, selector]) + warp
        assert any(n['offset'] == site and n.get('opcode') == 0x4E for n in graphs[name]['nodes'])
        assert tuple(warp[-2:]) == start
        positions = route_positions(start, routes[selector])
        assert positions[-1] == end and max(y for _, y in positions) == max_row < 107
        cases += 1
    print(f'PASS: {cases} static scripted-route cases, five expansions and four entry-rooted starts')


if __name__ == '__main__':
    check()
