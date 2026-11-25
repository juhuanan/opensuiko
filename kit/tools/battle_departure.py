#!/usr/bin/env python3
"""Extract the three-balloon departure motion from static MAIN.EXE data."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import journey_battle
import maindec

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/battle_departure.json'
RUNTIME = ROOT / 'game/src/battle_departure_data.zig'
BLOCKS = (
    (0x8016C170, 0x8016C194, '2b6104e1071a3d9c2c4e8e33f8abc02c5e620753ffa69966b5a6e808d5bcd3f2'),
    (0x800F3C5C, 0x800F3E98, '1229a6d7b67a141776093d14eaa3d1fa8322a6900f95f7b50931be3245f40e28'),
    (0x800E358C, 0x800E3820, 'a921697e4334bef240f626e216461882a060c85c6b18ecaf728dc10d83ac3e13'),
    (0x800E4974, 0x800E4C4C, '9bdfa5127f6e1a3e7825ad17b35d41ed6105c57b5319627f1bd7bedbdadc712c'),
    (0x800E56A8, 0x800E56EC, '7546ffd3d0aa8438cb117869869dad42bff840b9be735370d81d05db69f62af2'),
    (0x80150810, 0x8015099C, 'a5b336611796e248eddc735d0a600902a12d12ee8039c77f63ba70b6135414ee'),
    (0x801765BC, 0x80176DBE, 'bab3b71ba7f79dfb2b5cebb71f8382a79606a958d72031bc11b88066c36033bd'),
)


def build(image=None):
    image = maindec.body() if image is None else image
    base = maindec.MBASE
    blocks = []
    for start, end, expected in BLOCKS:
        block = image[start - base:end - base]
        if len(block) != end - start or hashlib.sha256(block).hexdigest() != expected:
            raise ValueError(f'departure source changed at {start:#x}')
        blocks.append(dict(address=f'{start:#010x}', size=len(block), sha256=expected))
    ops = journey_battle.script_at(image, 0x8016C170 - base)
    if ops != [(14, (2,)), (33, (1, 1, 0, 0, -200)), (37, (0,)),
               (30, (0,)), (35, (0, 14)), (31, (99,)), (0, ())]:
        raise ValueError('departure actor descriptor changed')
    quarter = struct.unpack_from('<1025h', image, 0x801765BC - base)

    def sine(angle):
        angle &= 4095
        if angle <= 1024:
            return quarter[angle]
        if angle <= 2048:
            return quarter[2048 - angle]
        if angle <= 3072:
            return -quarter[angle - 2048]
        return -quarter[4096 - angle]

    # The descriptor cancels the one-update movement timer before integration.
    # The callback instead advances the retained target over 96 updates.
    x = y = z = 0
    samples = [[0, 0, 0]]
    for remaining in range(95, -1, -1):
        angle = (remaining % 30) * 4096 // 30
        x += 4 * sine(angle)
        y += 4 * sine(angle + 1024)
        z += -((200 * 4096) // 96)
        samples.append([x, y, z])
    return dict(schema='suikoden-battle-departure/1', status='static_source_candidate',
                producer='battle_departure.py v1', units='relative world Q12',
                source=dict(file='MAIN.EXE', lba=maindec.EXE_LBA, size=maindec.EXE_SIZE,
                            image_base=f'{base:#010x}', blocks=blocks),
                descriptor=[dict(op=op, args=list(args)) for op, args in ops],
                helper_updates=96, phase_period=30, target_offset=[0, 0, -200],
                samples_q12=samples,
                limits='Source motion data; round/menu timing, revival placement, all-departed defeat and human media acceptance remain open.')


def runtime_source(report):
    rows = ''.join('    .{ %d, %d, %d },\n' % tuple(sample) for sample in report['samples_q12'])
    return ('//! Generated source-relative departure motion, in Q12 world units.\n'
            'pub const offsets = [97][3]i32{\n' + rows + '};\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    report = build()
    payload = json.dumps(report, indent=2) + '\n'
    runtime = runtime_source(report)
    if args.check:
        if REPORT.read_text() != payload:
            raise SystemExit('battle departure report is stale')
        if RUNTIME.read_text() != runtime:
            raise SystemExit('battle departure runtime data is stale')
    else:
        REPORT.write_text(payload)
        RUNTIME.write_text(runtime)
    print(f'{"Checked" if args.check else "Wrote"} departure report and runtime data')


if __name__ == '__main__':
    main()
