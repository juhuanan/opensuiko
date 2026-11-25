#!/usr/bin/env python3
"""Static source and full-consumption checks for world-map descriptors."""
import hashlib
import json
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))

import world_map_pages as P
import world_map_render as W
import lzss
import maindec

BASE = 0x80080000
THRESHOLDS = dict(A=215, B=207, C=217, D=192, E=199, F=197, G=212, H=197, J=133, K=231, Z=215)


def has_pending_literal(payload):
    """Walk input token widths without decoding any output or adjacent bytes."""
    cursor = 0
    while cursor < len(payload):
        flags = payload[cursor]
        cursor += 1
        previous_control = False
        for bit in range(8):
            control = bool(flags & (1 << bit))
            if cursor == len(payload):
                return previous_control and not control
            tag = payload[cursor]
            cursor += 1
            if control:
                if tag < 0x80:
                    cursor += 1
                elif tag >= 0xC0:
                    cursor += (tag & 0x3F) + 8
            assert cursor <= len(payload)
            previous_control = control
    # At a flag refill the original can fetch a byte but does not emit one.
    return False


def check():
    image = maindec.body()
    spans = (
        (0x80126FA4, 0x80127024, '8ee431e364984bf42bedb3084899e2f4ae05f9647181ce1131501512aab3f1ef'),
        (0x801270C4, 0x80127114, '1d7ec439a89e40345ec3efbc5bdfba19d26ea9397eb2c0f615c7725aa9980e35'),
        (0x80127114, 0x80127224, '506f5ff956ebfc408bcf697d1f25593553efd9f35c938dfa2fa092b4445b267e'),
        (0x800C3144, 0x800C3344, 'f79717d4d1a6506667938b2ad0bf0c3cefb290e56afd3f7d0d61bad2a821e59a'),
    )
    for start, end, digest in spans:
        assert hashlib.sha256(image[start - maindec.MBASE:end - maindec.MBASE]).hexdigest() == digest, hex(start)
    anchors = {
        # D publication, allocation, buffer publication, stream length, and decoder arguments.
        0x80126FC0: 0xAC62002C, 0x80126FD4: 0x00021040, 0x80126FE4: 0x0C030B4C,
        0x80126FF8: 0xAC620010, 0x80126FFC: 0x8E050014, 0x80127004: 0x8CA40000,
        0x80127008: 0x00403021, 0x8012700C: 0x0C030C51, 0x80127010: 0x24A50004,
        # A/Z sign extension, equality exceptions, signed comparison and below-bound return.
        0x801270C4: 0x00042400, 0x801270C8: 0x00042403, 0x801270CC: 0x3402004C,
        0x801270D4: 0x340200A1, 0x801270F4: 0x94420004, 0x801270FC: 0x0082102A,
        0x80127104: 0x00001021,
        # The direction input is unsigned. Only regions 0 and 11 call the signed helper.
        0x80127188: 0x94500000, 0x801271D8: 0x10600003, 0x801271DC: 0x3402000B,
        0x801271E8: 0x0C049C31, 0x80127200: 0x94420004, 0x80127208: 0x0202102A,
        # Literal writes precede the input bound check. Refill checks before decoding another token.
        0x800C31AC: 0xA0C30000, 0x800C31B0: 0x10400062, 0x800C3330: 0x00AC102B,
    }
    for address, word in anchors.items():
        assert maindec.mword(address) == word, hex(address)
    directions = struct.unpack_from('<8h', image, 0x8016F34C - maindec.MBASE)
    assert directions == (0, 1, 0, -1, -1, 0, 1, 0)

    areas = P.area_files()
    assert areas.keys() == THRESHOLDS.keys()
    pending = set()
    for letter, (_, data) in areas.items():
        d = struct.unpack_from('<I', data)[0] - BASE
        s = struct.unpack_from('<I', data, d)[0] - BASE
        threshold = struct.unpack_from('<H', data, d + 4)[0]
        assert threshold == THRESHOLDS[letter] and threshold != struct.unpack_from('<H', data, s + 4)[0]
        width, height = struct.unpack_from('<HH', data, s)
        assert (width, height) == (160, 120)
        stream = d + 32
        assert struct.unpack_from('<I', data, s + 20)[0] == BASE + stream
        length = struct.unpack_from('<I', data, stream)[0]
        container = data[stream:stream + 4 + length]
        raw, used = lzss.decode_container(container)
        assert used == len(container) == 4 + length and len(raw) == 2 * width * height
        codes = struct.unpack('<19200H', raw)
        assert codes == W.parse_worldmap(data)['codes']
        if has_pending_literal(container[4:]):
            pending.add(letter)
        if letter in 'BC':
            retained = json.loads((KIT.parent / 'game/assets' / f'world_{letter.lower()}.json').read_text())
            assert retained['walkable'] == ''.join('1' if code >= threshold else '0' for code in codes)
    assert pending == set('ACEFJKZ')
    print('PASS: 11 complete planes and thresholds, four direction offsets, seven pending literal cases, B/C walkability grids')


if __name__ == '__main__':
    check()
