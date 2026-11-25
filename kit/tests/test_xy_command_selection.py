#!/usr/bin/env python3
"""Static point-index, command and resource-request verification."""
import hashlib
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import maindec as M
import world_map_render as W
from test_worldmap_points import main_words


def check_consumers():
    image = M.body()
    for start, end, digest in [
            (0x8013112C, 0x801313CC, '647eed40dd91028b2dc7839a982ec5c018083ee42f5d0526fa4082866c85e34a'),
            (0x80142440, 0x801424C8, '10efcc789d4e0221701839303ef7f3b7360890ea89ff9bd537db850d373efa7b'),
            (0x800C4FE0, 0x800C50E8, 'faed2b57b2f619bda85bca9a978fc18ba4425ccb1a0d822900eb40bf9a87b277'),
            (0x800C7948, 0x800C79F4, '7b35b55bd584521c160d5eea2140805ea06091350217177cd4f4b6e511b6fe7f'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)
    assert M.mword(0x800C0800 + 4 * 4) == 0x800C5058
    main_words({
        # World initialization and the point-activation publication.
        0x80127BA4: (0x90620002, 0x3C038017, 0x9063F2A7, 0x00021080, 0x3C018017,
                     0x24210064, 0x00220821, 0x8C220000, 0x3C018018, 0xAC20A0B0, 0xAC820030),
        0x80128220: (0x144000A6,),
        0x801284BC: (0x92020001, 0xA2720000, 0xA2620001),
        0x80128574: (0x34030002, 0xAC831BBC),
        # State 3 reconstructs the same point from retained region and index.
        0x8013117C: (0x10620045, 0x34040014),
        0x801312A0: (0x90450000, 0x90430002, 0x000510C0, 0x00031880, 0x3C018017, 0x24210064,
                     0x00230821, 0x8C230000, 0x00451023, 0x00021040, 0x0C050717, 0x00438021,
                     0x10400009),
        # The three exceptional keys read the packed area/room/region bytes.
        0x80131304: (0x8C430000, 0x3C0200FF, 0x3442FFFF, 0x00621824, 0x34020200,
                     0x14620005, 0x3C020004, 0x0C030C41, 0x00002021, 0x0804C4DE, 0x00111880,
                     0x34420301, 0x14620005, 0x3C020003, 0x0C030C41, 0x3404040E,
                     0x0804C4DE, 0x00111880, 0x34420103, 0x14620005, 0, 0x0C030C41,
                     0x3404040D, 0x0804C4DE, 0x00111880),
        0x80131368: (0x86040008, 0x0C050910, 0, 0x00111880, 0x3C028013, 0x244213CC,
                     0x3C018018, 0x2421DA90, 0x00230821, 0xAC220000),
        # Compare the sign-extended command with the cache before dispatch.
        0x80142454: (0x84631E22, 0x00101400, 0x00022403, 0x10830015, 0x02002821),
        0x80142468: (0x2602FDFF, 0x3042FFFF, 0x2C420245, 0x10400003, 0, 0x3C018017,
                     0xA4251E22, 0x0C030C41),
        0x800C310C: (0x0C0313F8,),
        # The command high byte selects the jump table and family 4 forwards its command.
        0x800C4FE4: (0x00041202, 0x304300FF, 0x34020020, 0x0043102B, 0x14400037,
                     0xAFBF0010, 0x00031080, 0x3C01800C, 0x24210800, 0x00220821,
                     0x8C220000, 0, 0x00400008),
        0x800C5058: (0x00042400, 0x0C031E52, 0x00042403),
        # Publish the destination low byte. Flag an active-resource transition.
        0x800C7954: (0x00808021, 0x3C028018, 0x24429BF4, 0xA0500000),
        0x800C798C: (0x90639BF3, 0x3C018018, 0xA4229C0E, 0x1060000A),
        0x800C79BC: (0x0C0321F9,),
        0x800C87E8: (0x90429BF3, 0x27BDFFE8, 0x10400006, 0xAFBF0010, 0x34020001,
                     0x3C018018, 0xA0229C05),
    })


def check():
    check_consumers()
    image = M.body()
    parsed = W.region_tables(image)
    commands = {}
    # The shared code masks the low three bytes of the state word.
    exceptions = {0x000200: 0, 0x040301: 0x040E, 0x030103: 0x040D}
    observed_exceptions = set()
    for region in range(12):
        pointer = struct.unpack_from('<I', image, 0x80170064 - M.MBASE + 4 * region)[0]
        assert pointer == parsed[region]['offset']
        records = []
        for index in range(64):
            off = pointer - M.MBASE + 14 * index
            raw = image[off:off + 14]
            assert len(raw) == 14
            if raw[0] == 8:
                break
            records.append(raw.hex())
            room = raw[1]
            command = struct.unpack_from('<H', raw, 8)[0]
            key = int.from_bytes(bytes([index, room, region]), 'little')
            if key in exceptions:
                observed_exceptions.add(key)
            commands[region, index] = (room, exceptions.get(key, command))
        else:
            raise AssertionError('missing point terminator')
        assert records == [row['raw'] for row in parsed[region]['records']]

    assert len(commands) == 165
    resources = {(region, index): command & 255
                 for (region, index), (_, command) in commands.items() if command >> 8 == 4}
    assert len(resources) == 94
    # Validate the source keys with nondefault rooms too. The mask excludes byte 3.
    for (region, room, index), command in [((0, 2, 0), 0), ((4, 3, 1), 0x040E), ((3, 1, 3), 0x040D)]:
        key = int.from_bytes(bytes([index, room, region, 0xFF]), 'little') & 0xFFFFFF
        assert exceptions[key] == command
        if key in observed_exceptions:
            assert commands[region, index] == (room, command)

    # VCD's accepted point row supplies resource 17 and can suppress a cached repeat.
    point = bytes.fromhex(parsed[2]['records'][8]['raw'])
    assert struct.unpack_from('<HH', point, 2) == (41, 17)
    assert commands[2, 8] == (0, 0x0411)
    assert resources[2, 8] == 17
    command = commands[2, 8][1]
    assert [cached == command for cached in (0xFFFF, 0x0411)] == [False, True]
    print('PASS: 12 static point tables, 165 commands, 94 resource requests, three overrides and cache')


if __name__ == '__main__':
    check()
