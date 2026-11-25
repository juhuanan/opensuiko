"""Decode the verified source camera/Hero push records without original execution."""
import argparse
import struct
import sys
from pathlib import Path

import maindec
from export_common import atomic_write, serialize
from export_first_room import source

TABLE = 0x801718D4
RECORD_SIZE = 5
VERIFIED_RECORDS = 8


def records():
    data, origin = source('MAIN.EXE')
    base = struct.unpack_from('<I', data, 24)[0]
    offset = 2048 + TABLE - base
    raw = data[offset:offset + RECORD_SIZE * VERIFIED_RECORDS]
    independent = maindec.body()[TABLE - maindec.MBASE:TABLE - maindec.MBASE + len(raw)]
    if len(raw) != 40 or raw != independent:
        raise ValueError('independent camera push table reads disagree')
    words = {0x8013ff6c: 0x00022080, 0x8013ff70: 0x00822021,
             0x80140028: 0x34020002, 0x80140030: 0xa022bd79,
             0x801400a4: 0x2442ffff, 0x80140114: 0x2442ffff,
             0x80140140: 0x38421000, 0x80140154: 0x0c04ffd7,
             0x8013f0f8: 0x3042fffc, 0x8013f12c: 0x0c04f80a,
             0x8013f150: 0x0c050782, 0x80141e10: 0x0c05001a}
    for address, expected in words.items():
        if struct.unpack_from('<I', data, 2048 + address - base)[0] != maindec.mword(address) or maindec.mword(address) != expected:
            raise ValueError('camera push consumer changed')
    result = []
    for index in range(VERIFIED_RECORDS):
        x, y, ox, oy, updates = struct.unpack_from('<4bB', raw, index * RECORD_SIZE)
        dx, dy = x * 8, y * 8
        if abs(dx) not in (8, 16) or abs(dy) != 8 or updates != 8 or (ox * updates, oy * updates) != (-dx, -dy):
            raise ValueError('unsupported camera push record')
        result.append(dict(dx=dx, dy=dy, updates=updates))
    return result, dict(source=origin, table_address=TABLE, table_offset=offset,
                        record_size=RECORD_SIZE, record_bytes=raw.hex(),
                        decoder='field_camera_push.py/v1: signed cell deltas *8; signed interpolation products; byte update count',
                        source_words={hex(address): hex(word) for address, word in words.items()})


def request(index, repeats):
    if type(index) is not int or not 0 <= index < VERIFIED_RECORDS or type(repeats) is not int or not 0 <= repeats <= 255:
        raise ValueError('unsupported camera push selector or repeat byte')
    profiles, _ = records()
    return dict(profiles[index], repeats=repeats or 256)


def reference(index, repeats, x=320, y=320):
    """Literal byte counters and offset stores, followed by the field settlement."""
    decoded = request(index, repeats)
    if type(x) is not int or type(y) is not int or not 0 <= x <= 2040 or not 0 <= y <= 2040 or x % 8 or y % 8:
        raise ValueError('invalid camera push start point')
    _, proof = records()
    raw = bytes.fromhex(proof['record_bytes'])[index * 5:index * 5 + 5]
    cx, cy = x // 8, y // 8
    repeat_byte = repeats
    frames = []

    def apply_record():
        nonlocal cx, cy
        cx, cy = (cx + raw[0]) & 255, (cy + raw[1]) & 255
        signed = lambda value: (value + 128) % 256 - 128
        return raw[4], signed(raw[2] * raw[4]), signed(raw[3] * raw[4])

    left, ox, oy = apply_record()
    for _ in range((repeats or 256) * raw[4]):
        left = (left - 1) & 255
        camera = (cx * 8 + ox, cy * 8 + oy)
        if not left:
            repeat_byte = (repeat_byte - 1) & 255
            if repeat_byte:
                left, ox, oy = apply_record()
        ox = max(0, ox - 2) if ox > 0 else min(0, ox + 2)
        oy = max(0, oy - 2) if oy > 0 else min(0, oy + 2)
        frames.append([*camera, cx * 8, cy * 8, ox, oy, left, repeat_byte, 2])
    return dict(request=decoded, start=dict(x=x, y=y), frames=frames)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=int, help='verified source record index, 0..7')
    parser.add_argument('--repeats', type=int, default=1, help='source repeat byte; 0 means 256 cycles')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    _, proof = records()
    payload = serialize(dict(schema='suikoden-camera-push/1', **proof, request=request(args.record, args.repeats)))
    if args.out and args.out != Path('-'):
        atomic_write(args.out, payload)
    else:
        sys.stdout.buffer.write(payload)


if __name__ == '__main__':
    main()
