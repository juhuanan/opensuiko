#!/usr/bin/env python3
"""Actual world-map point loader/activation and camera movement boundaries."""
import hashlib
from pathlib import Path
import json
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import maindec as M
import world_map_render as W
from disc import extract
from area_entity_probe import room_records
from event_script_reachability import entry_roots, walk

GS,ST,OBJ,D,PL,SUB=range(0x80200000,0x80260000,0x10000)


# Legacy callers still import these helpers. The point gate below uses raw source reads.
def run(c,pc):
    c.r[31]=0xFFFFFFFC;c.r[4]=0
    return c.run(pc)


def fixture(region,x,y):
    from test_vb2_dice_states import OverlayInstructions

    c=OverlayInstructions(b'');m=c.mem
    m.sw(0x8017DB24,GS);m.sw(0x8017A0B8,ST);m.sw(0x8017C20C,SUB)
    m.sb(GS+2,region);m.sw(ST+0x30,M.mword(0x80170064+4*region))
    m.sw(ST+0x38,0xFFFFFFFF);m.sh(SUB+0x1C,200)
    m.sb(0x8016F2A7,255);m.sh(0x8016F298,x);m.sh(0x8016F29A,y)
    # Encounter/attribute updates and I/O are explicit boundaries; point dispatch is real.
    c.hooks[0x80126BCC]=0;c.hooks[0x800C2EF8]=0;c.hooks[0x801260B8]=0
    return c



def kobold_connection_cases():
    """Read the VB6 point, activation branches and source return operands."""
    from export_first_room import source
    data,origin=source('/VB6.BIN')
    descriptor=M.mword(M.mword(0x8016F67C+8)+6*4)
    assert (M.mword(descriptor),M.mword(descriptor+4))==(origin['size'],origin['lba'])
    kind, field_room, world_x, world_y, field_x, field_y = struct.unpack_from(
        '<BBHHBB', point_record(2, 6))
    assert (kind, field_room, world_x, world_y, field_x, field_y) == (0, 6, 59, 36, 44, 27)
    main_words({
        # Each axis accepts the point coordinate or that coordinate plus one.
        0x801281C8: (0x3C038017, 0x9463F298, 0, 0x10430003, 0x24420001, 0x14430012),
        0x801281E4: (0x3C038017, 0x9463F29A, 0x30A2FFFF, 0x10430003, 0x24420001, 0x1443000B),
        0x80128200: (0x92020000, 0, 0x00021080, 0x00551021, 0x8C420000, 0, 0x0040F809,
                     0, 0x144000A6),
        0x80128730: (0x03E00008, 0x34020001),
        # Publish the point index, room and field coordinates, then install the mode request.
        0x801284BC: (0x92020001, 0xA2720000, 0xA2620001, 0x92020006, 0, 0xA6620004,
                     0x92030007, 0, 0xA6630006, 0x3C038013, 0x24638528, 0x3C018018,
                     0x2421DA90, 0x00240821, 0xAC230000),
        0x80128574: (0x34030002, 0xAC831BBC),
        # Inline 03 FB writes region, X and Y, invalidates the saved camera match and exits.
        0x8013E070: (0x34020003,),
        0x8013E0D0: (0x0C04EFE5,),
        0x8013C08C: (0x340200FB,),
        0x8013C0B0: (0x1462001E, 0x24820002, 0x3C018018, 0xAC22AF84, 0x3C038018, 0x8C63C164,
                     0x90820001, 0, 0xA0620002),
        0x8013C0EC: (0x90640000, 0x24620002, 0x3C018018, 0xAC22AF84, 0x3C018017,
                     0xA424F298, 0x90650001, 0x3C048018, 0x8C84BE20, 0x3403FFFF,
                     0xA4830090, 0xA4830092, 0x3C018017, 0xA425F29A, 0x0804F08C, 0x34020001),
    })
    assert M.mword(0x8016F37C + 4 * kind) == 0x80128730
    cases = [dict(camera_cells=dict(x=x, y=y),
                  activated=x in (world_x, world_x + 1) and y in (world_y, world_y + 1))
             for x, y in ((59, 36), (60, 37), (58, 36), (59, 38))]
    assert [case['activated'] for case in cases] == [True, True, False, False]
    # Walk the room/entity pointers independently of the report producer.
    pointer=lambda off:struct.unpack_from('<I',data,off)[0]-0x80010000
    root=pointer(0);room=pointer(root+8)+16*6;entry=pointer(room)+24
    stream=pointer(entry+20);assert data[stream:stream+6]==bytes.fromhex('03fb023b26fd')
    return cases


def main_words(slices):
    for address, words in slices.items():
        assert tuple(M.mword(address + 4*i) for i in range(len(words))) == words, hex(address)


def point_record(region, index):
    table = M.mword(0x80170064 + 4 * region)
    return M.body()[table - M.MBASE + 14 * index:table - M.MBASE + 14 * (index + 1)]


def check_vcd(files):
    vcd = next(r for r in files if r['path'] == 'DATA/06_AREA.C/VCD.BIN')
    assert (vcd['lba'], vcd['size']) == (99400, 86288)
    region, index = 2, 8
    raw = point_record(region, index)
    assert raw == bytes.fromhex('00 00 29 00 11 00 18 26 11 04 36 00 00 00')
    kind, room, world_x, world_y, field_x, field_y = struct.unpack_from('<BBHHBB', raw)
    assert (kind, room, field_x, field_y) == (0, 0, 24, 38)
    descriptor = M.mword(M.mword(0x8016F67C + 4 * region) + 4 * index)
    assert (M.mword(descriptor), M.mword(descriptor + 4)) == (vcd['size'], vcd['lba'])
    main_words({
        # Exact activation is scanned before the proximity path. Both use 14-byte rows.
        0x80128220: (0x144000A6, 0x00142080),
        0x80128238: (0x2631000E,),
        0x8012825C: (0x8CE20038, 0, 0x04410060),
        # Nearby means camera-5 < point < camera+6, on both axes.
        0x801282B8: (0x2482FFFB, 0x0043102A, 0x1040003D, 0x24820006, 0x0062102A, 0x1040003A),
        0x801282E0: (0x2482FFFB, 0x0043102A, 0x10400033, 0x24820006, 0x0062102A, 0x10400030),
        0x801282FC: (0x90C20000, 0, 0x1440002C, 0x34030064),
        # Suppress a cached point-index match. Publish the region/point key in the loader delay slot.
        0x80128318: (0x84C2001C, 0, 0x0043001A),
        0x80128348: (0x00001810, 0, 0x10720019),
        0x80128364: (0x90A20002, 0, 0x00021080, 0x3C018017, 0x2421F67C, 0x00220821,
                     0x8C230000, 0x00121080, 0x00431021, 0x8C440000, 0xACF20038,
                     0x90A30002, 0x3C058001, 0x00031040, 0x00431021, 0x000210C0,
                     0x00431021, 0x00021080, 0x00521021, 0x0C030BBE, 0xA4C2001C),
        # The later uncached mode-2 request uses the same region/area descriptor and destination.
        0x80130F34: (0x10830012, 0, 0x3C028018, 0x8C42DB24, 0xA4A4001C, 0x90430002,
                     0x90420000, 0x00031880, 0x3C018017, 0x2421F67C, 0x00230821, 0x8C230000,
                     0x00021080, 0x00431021, 0x8C440000, 0x0C030BBE, 0x3C058001),
    })
    rows = [struct.unpack_from('<BBHH', point_record(region, i)) for i in range(index + 2)]
    assert rows[-1][0] == 8
    exact_count = preload_count = 0
    for x in range(34, 49):
        for y in range(10, 25):
            exact = (world_x <= x <= world_x + 1) and (world_y <= y <= world_y + 1)
            near = x - 5 < world_x < x + 6 and y - 5 < world_y < y + 6
            # In this window no earlier point can activate or take the preload.
            assert not any(x - 5 < px < x + 6 and y - 5 < py < y + 6 for _, _, px, py in rows[:index])
            assert exact == (41 <= x <= 42 and 17 <= y <= 18)
            assert near == (36 <= x <= 45 and 12 <= y <= 21)
            exact_count += exact
            preload_count += near and not exact
    assert (exact_count, preload_count) == (4, 96)
    cache_key = 100 * region + index
    assert cache_key == 208
    for cached, suppress in [(200, False), (207, False), (208, True)]:
        assert (cached % 100 == index) == suppress


def collision_offsets():
    offsets = struct.unpack_from('<8h', M.body(), 0x8016F34C - M.MBASE)
    x, y = offsets[:4], offsets[4:]
    directions = tuple(zip(x, y))
    assert directions == ((0, -1), (1, 0), (0, 1), (-1, 0))
    main_words({
        # Halfword offsets select the sampled neighbor of the (10,8)-biased camera.
        0x80127130: (0x2421F354, 0x00240821, 0x84220000),
        0x80127144: (0x24630008, 0x00621821, 0x00031080, 0x00431021),
        0x80127158: (0x2421F34C, 0x00240821, 0x84230000, 0x24A5000A),
        0x80127170: (0x00021140, 0x00A32821, 0x8C830010, 0x00451021, 0x00021040,
                     0x00431021, 0x94500000),
        0x801271F8: (0x8C82002C, 0, 0x94420004, 0, 0x0202102A, 0x1040FFEB),
    })
    return directions


def check_movement(files, directions):
    main_words({
        # Requested-axis guards, before consultation with the direction resolver.
        0x80127660: (0x90420022, 0, 0x10400042),
        0x801276A0: (0x30621000, 0x1040000A, 0x30624000, 0x3C028017, 0x9442F29A, 0,
                     0x10400028, 0, 0x0C049D3A, 0x00002021),
        0x801276D8: (0x3C028017, 0x9442F29A, 0, 0x2442000E, 0x28420077, 0x1040001B,
                     0, 0x0C049D3A, 0x34040002),
        0x80127704: (0x1040000A, 0x30622000, 0x3C028017, 0x9442F298, 0, 0x10400010,
                     0, 0x0C049D3A, 0x34040003),
        0x80127738: (0x3C028017, 0x9442F298, 0, 0x24420013, 0x2842009F, 0x10400003,
                     0, 0x0C049D3A, 0x34040001),
        # If the requested direction fails, the resolver checks the previous heading next.
        0x80127240: (0x3C038017, 0x9063F2A7, 0x340200FF, 0x14620005, 0x00809821),
        0x80127254: (0x0C049C45, 0x02602021, 0x10400003, 0, 0x08049CBF, 0x26620080),
        0x80127278: (0x90440023, 0x0C049C45, 0x00042042, 0x1040000B),
        0x80127298: (0x90420023, 0, 0x00021042, 0x08049CBF, 0x34420080),
        # An accepted result starts floor(16/speed) countdown, clears readiness and updates X/Y.
        0x801274F4: (0x0C049C89, 0x308400FF, 0x00408021, 0x3202000F),
        0x80127588: (0x1040002D, 0x34020010, 0x3C048018, 0x8C84A0B8, 0, 0x94830042,
                     0, 0x0043001A),
        0x801275CC: (0x00001012, 0xA0800022, 0x3C058018, 0x8CA5A0B8, 0xA4820020),
        0x801275F4: (0x2421F31C, 0x00220821, 0x94220000),
        0x80127604: (0x00621821, 0x3C018017, 0xA423F298),
        0x80127624: (0x2421F32C, 0x00220821, 0x94220000),
        0x80127634: (0x00621821, 0x3C018017, 0xA423F29A),
        # Each update applies its heading to both scroll objects. Only zero reopens readiness.
        0x80127360: (0x00620018, 0x8CA40014),
        0x8012737C: (0x00431021, 0xA482001C),
        0x801273A8: (0x00620018, 0x8CA40014),
        0x801273C4: (0x00431021, 0xA482001E),
        0x801273F0: (0x00620018, 0x8CA40018),
        0x8012740C: (0x00431021, 0xA482001C),
        0x80127438: (0x00620018, 0x8CA40018),
        0x80127454: (0x00431021, 0xA482001E),
        0x80127474: (0x94820020, 0, 0x2442FFFF, 0xA4820020, 0x94820020, 0,
                     0x14400012, 0x34030001, 0xA0830022),
    })
    # Source tables index the cardinal entries at direction * 2.
    dxs = struct.unpack_from('<8h', M.body(), 0x8016F31C - M.MBASE)
    dys = struct.unpack_from('<8h', M.body(), 0x8016F32C - M.MBASE)
    assert tuple(zip(dxs[::2], dys[::2])) == directions
    for direction, allowed_count in enumerate((255, 140, 105, 255)):
        dx, dy = directions[direction]
        step = dx + dy
        margin, limit = {1: (19, 159), 2: (14, 119)}.get(direction, (0, 0))
        moves = [value + step for value in range(256)
                 if (value + margin < limit if step > 0 else value > 0)]
        assert len(moves) == allowed_count
        assert (moves[0], moves[-1]) == ((1, allowed_count) if step > 0 else (0, 254))

    rec = next(r for r in files if r['path'] == 'DATA/02_AREA.B/B_DATA.BIN')
    blob = extract(rec['lba'], rec['size'])
    plane = W.parse_worldmap(blob)
    limit = struct.unpack_from('<H', blob, plane['d_off'] + 4)[0]
    assert limit == 207

    def passable(x, y, direction):
        dx, dy = directions[direction]
        return plane['codes'][(y + 8 + dy) * 160 + x + 10 + dx] >= limit

    for x, requests, expected in [(63, (2,), [105]), (8, (2, 1, 1), [105, 106, 107])]:
        y = 104
        heading = 2
        positions = []
        for request in requests:
            if passable(x, y, request):
                heading = request
            assert heading == 2 and passable(x, y, heading)
            y += directions[heading][1]
            positions.append(y)
        assert positions == expected
    # At speed one, the source divide and decrement give 16 updates of one pixel each.
    speed = 1
    countdown = (M.mword(0x8012758C) & 0xFFFF) // speed
    settled = [(remaining, remaining == 0) for remaining in range(countdown - 1, -1, -1)]
    assert len(settled) == 16 and settled == [(value, not value) for value in range(15, -1, -1)]
    assert (dys[2 * 2] * speed) * countdown == 16


def check_vb8(files, directions):
    main_words({
        # Both saved coordinates must match before either camera word is overwritten.
        0x80131D64: (0x9442F298, 0x94830090, 0, 0x14620024, 0, 0x94830092,
                     0x3C028017, 0x9442F29A, 0, 0x1462001E),
        0x80131D9C: (0x90850000, 0x90830002, 0x000510C0, 0x00031880, 0x3C018017, 0x24210064,
                     0x00230821, 0x8C260000, 0x00451023, 0x00021040, 0x00461021, 0x94420002),
        0x80131DD4: (0xA422F298,),
        0x80131DF0: (0x94420004, 0, 0x24420002, 0x3C018017, 0xA422F29A),
    })
    rec = next(r for r in files if r['path'] == 'DATA/02_AREA.B/VB8.BIN')
    assert (rec['lba'], rec['size']) == (63115, 144024)
    data = extract(rec['lba'], rec['size'])
    base = 0x80010000
    root = struct.unpack_from('<I', data)[0] - base
    roomtable = struct.unpack_from('<I', data, root + 8)[0] - base
    assert (root, roomtable) == (0x294, 0x10E74)
    rooms = room_records(data)
    assert rooms[0]['ent_off'] == 0x10F00
    for region in (1, 9):
        raw = point_record(region, 42)
        assert raw == bytes.fromhex('00 00 3f 00 69 00 14 14 39 04 00 00 00 00')
        saved = struct.unpack_from('<HH', raw, 2)
        rise = M.mword(0x80131DF8) & 0xFFFF
        for request, expected in [((63, 105), (63, 107)), ((62, 105), (62, 105)),
                                  ((63, 104), (63, 104)), ((36, 59), (36, 59))]:
            cache = (0xFFFF, 0xFFFF) if request == (36, 59) else saved
            assert ((saved[0], saved[1] + rise) if request == cache else request) == expected
        desc = M.mword(M.mword(0x8016F67C + 4 * region) + 42 * 4)
        assert (M.mword(desc), M.mword(desc + 4)) == (rec['size'], rec['lba'])

    entry = entry_roots(data)[0]
    assert (entry['record'], entry['classifier'] - base, entry['offset']) == (0x10F00, 0x10EA8, 0x10EC4)
    op_x, x0, x1, op_y, y0, y1, op_input, button, end = data[0x10EA8:0x10EB1]
    assert (op_x, op_y, op_input, end) == (0xB, 0xC, 4, 6)
    assert (x0, x1, y0, y1) == (18, 22, 30, 30)
    for op, target in [(op_x, 0x8013DCE0), (op_y, 0x8013DD0C), (op_input, 0x8013DD38)]:
        assert M.mword(0x800C1A00 + 4 * op) == target
    key = M.mword(0x80171708 + 4 * button)
    assert key == 0x4000
    main_words({
        # Compare the inclusive bounds and require the selected input mask.
        0x8013DCEC: (0x9063BD74, 0, 0x0062102B, 0x1440FFB3, 0x26100001, 0x92020000,
                     0x0804F7C1, 0x0043102B),
        0x8013DD18: (0x9063BD75, 0, 0x0062102B, 0x1440FFA8, 0x26100001, 0x92020000,
                     0x0804F7C1, 0x0043102B),
        0x8013DF04: (0x1040003F, 0x26100001, 0x0804F806, 0x00001021),
        0x8013DD44: (0x8C63BDCC, 0x00021080, 0x3C018017, 0x24211708, 0x00220821, 0x8C220000,
                     0, 0x00621824, 0x146000A7, 0x26100001),
        0x8013E004: (0x92030000, 0x34020006, 0x1462FEFB, 0x34020019, 0x34020001),
        0x8013F238: (0x0C04F6DB, 0x02602021, 0x304200FF, 0x10400005, 0x26100001, 0x0C04F85F),
        0x8013E1F0: (0x8C42A120, 0, 0x8C420014, 0, 0x3C018018, 0xAC22AF84),
        # Opcode 42 reads its UI selector and the mode arm writes its byte offset from 11.
        0x80139908: (0x24620001, 0x3C018018, 0xAC22AF84, 0x90640000, 0x0C050605),
        0x80141A9C: (0x248200F5, 0x3C018017, 0xA022F2A6),
        # Ordinary inline 03 writes only the field room/spawn and returns 2.
        0x8013C130: (0x10620014, 0, 0x3C028018, 0x8C42C164, 0, 0xA0450001,
                     0x3C038018, 0x8C63AF84, 0x3C058018, 0x8CA5C164, 0x24620001,
                     0x3C018018, 0xAC22AF84, 0x90640000, 0x24620002, 0x3C018018, 0xAC22AF84, 0xA4A40004,
                     0x90630001, 0x0804F08B, 0x34020002),
        0x8013C22C: (0xA4A30006, 0x03E00008, 0),
    })
    assert M.mword(0x80171718 + 4 * 0x42) == 0x801398F8
    assert [M.mword(0x800C1AC0 + 4 * selector) for selector in (11, 12, 13)] == [0x80141A9C] * 3
    assert [(selector + (M.mword(0x80141A9C) & 0xFFFF)) & 0xFF for selector in (11, 12, 13)] == [0, 1, 2]
    for axis, expected in [(0, [18, 19, 20, 21, 22]), (1, [30])]:
        accepted = []
        for value in range(256):
            x, y = (value, 30) if axis == 0 else (20, value)
            for pressed in (0, key):
                if x0 <= x <= x1 and y0 <= y <= y1 and pressed & key:
                    accepted.append(value)
        assert accepted == expected

    graph = walk(data, [entry['offset']])
    assert any(n['offset'] == 0x10EE0 and n.get('opcode') == 3 for n in graph['nodes'])
    assert data[0x10EDE:0x10EE5] == bytes.fromhex('42 0c 03 fb 09 24 3b')
    entries = entry_roots(data)
    all_graph = walk(data, [e['offset'] for e in entries])
    assert len(entries) == 14 and len(all_graph['nodes']) == 170 and not all_graph['frontier']
    assert {n['offset']: data[n['offset'] + 1:n['offset'] + 4]
            for n in all_graph['nodes'] if n.get('opcode') == 3} == {
        0x10EE0: bytes([0xFB, 9, 36]), 0x10EE8: bytes([1, 23, 29]), 0x10FA0: bytes([0, 17, 9]),
    }
    region, x, y = data[0x10EE2:0x10EE5]
    assert (region, x, y) == (9, 36, 59)
    rec = next(r for r in files if r['path'] == 'DATA/02_AREA.B/J_DATA.BIN')
    assert (rec['lba'], rec['size']) == (57829, 97654)
    desc = M.mword(0x8016F3B4 + region * 4)
    assert (M.mword(desc), M.mword(desc + 4)) == (rec['size'], rec['lba'])
    blob = extract(rec['lba'], rec['size'])
    plane = W.parse_worldmap(blob)
    limit = struct.unpack_from('<H', blob, plane['d_off'] + 4)[0]
    codes = [plane['codes'][(y + 8 + dy) * 160 + x + 10 + dx] for dx, dy in directions]
    assert (limit, codes) == (133, [9, 4, 8, 7])
    main_words({
        0x80127190: (0x9063F2A6, 0x34020001, 0x1462000A, 0, 0x0C049C09, 0x02002021,
                     0x1440001A, 0x34020001, 0x2A020015, 0x10400017, 0x00001021,
                     0x08049C85, 0x34020001),
        0x80127034: (0x90A30002, 0x34020009, 0x1462000E, 0x3402000A, 0x2482FED1,
                     0x3042FFFF, 0x2C420008, 0x10400018, 0x00001021),
    })
    assert all(code < limit for code in codes)
    assert all(code < (M.mword(0x801271B0) & 0xFFFF) for code in codes)


def check_foot_encounters():
    from export_first_room import source
    from export_world_travel import export

    fixtures = Path(__file__).resolve().parents[2] / 'game/tests/fixtures'
    image = M.body()
    for start, end, digest in (
        (0x801260B8, 0x801261B0, 'a6af49873a6acb68795035718c06c6296e6621b94a0533cb93f795ac1958f9cf'),
        (0x801261B0, 0x80126228, 'b806307d38b49189d8c68e34e19c0d520d182b2dfb228c522c4796603ca9a204'),
        (0x80126228, 0x80126408, '924062647ef00bf83c46945a70bb49b20295c6a11add2495511fc7c94ad879f9'),
    ):
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == digest, hex(start)
    main_words({
        0x80126150: (0x0C051F8E, 0xA0800024),
        0x80126264: (0x34037FFF, 0x0065001A),
        0x80126384: (0x00051100, 0x00451023, 0x3403000A, 0x0043001A),
        0x801263BC: (0x0C04986C, 0x34040018, 0x10400005, 0x0230102A),
        0x80128424: (0x0C04982E,),
        0x80128440: (0x30420200, 0x14400007),
        0x80128470: (0x30420080, 0x10400022, 0x340200FF),
    })
    area, _ = source('/B_DATA.BIN')
    pointer = lambda at: struct.unpack_from('<I', area, at)[0] - 0x80080000
    directory = pointer(pointer(pointer(0) + 12))
    roster_table, enemy_table = (pointer(directory + offset) for offset in (8, 12))
    count, = struct.unpack_from('<I', area, roster_table)
    levels = []
    for index in range(1, count + 1):
        start = pointer(roster_table + 4 * index)
        levels.append(sum(area[pointer(enemy_table + 4 * member) + 16] for member in area[start + 4:start + 10] if member))
    travel, _ = export()
    assert levels == [record['enemy_level_sum'] for record in travel['encounters']]
    plane = W.parse_worldmap(area)
    threshold, = struct.unpack_from('<H', area, pointer(0) + 4)
    assert travel['walkable'] == ''.join('1' if code >= threshold else '0' for code in plane['codes'])

    offsets = struct.unpack_from('<hh', image, 0x8016F35E - M.MBASE)
    resolvers = json.loads((fixtures / 'world_resolvers.json').read_text())
    assert len(resolvers) == 256
    for case in resolvers:
        mask, heading, requested = (case[key] for key in ('mask', 'heading', 'requested'))
        alternatives = ((requested + offsets[0]) % 4, requested + offsets[1])
        selected = next((step for step in (requested, heading, *alternatives) if mask & (1 << min(3, step))), None)
        assert (case['accepted'], case['facing']) == (selected is not None, (alternatives[1] if selected is None else selected) % 4)

    encounters = json.loads((fixtures / 'world_encounters.json').read_text())
    assert len(encounters) == 106
    for case in encounters:
        eligible = (case['enabled'] and not case['scripted'] and not case['boat'] and case['ready'] and
                    case['pending'] and case['table'] and case['counter'] >= (M.mword(0x80126134) & 0xFFFF))
        wants_battle = eligible and case['chance'] % 256 < (M.mword(0x80126174) & 0xFFFF)
        selection = None
        if wants_battle:
            index = min(count, case['pick'] // (32767 // count) + 1)
            if not case['rune'] or case['party'] <= levels[index - 1] * 15 // 10:
                selection = index
        assert case['accepted'] == (selection is not None) and case['selected'] == selection
        assert case['draws'] == int(eligible) + int(wants_battle)
        assert case['next_pending'] == (case['pending'] and not eligible)

    menus = json.loads((fixtures / 'world_menus.json').read_text())
    assert len(menus) == 16
    for case in menus:
        assert case['menu'] == (case['pressed'] and not case['entrance'] and not case['scripted'])


def check():
    for start, end, digest in [
            (0x801280C4, 0x80128528, '9ccbe4e218b37cf402088f4eefe7aee7742829124e26d69ea0e8480fafa3d9ec'),
            (0x80127650, 0x80127784, '764bce69bfa1a91e6f2b47b2b29acf02887826516193dc3f9ad4fb5fbb48d8be'),
            (0x8012731C, 0x801274E8, '0557abcf7380b83a823d6dbea7c8fc4009e5c229335e82e62d759375bd8bf287'),
            (0x801274E8, 0x80127650, '4b632a51d34ad5ca25c893d90630a987b7c04793a6628c924b3b7c26fab89fa3'),
            (0x80127224, 0x8012731C, 'df2800c2ef78731f476a45f3a3c68e8a17a0987ad93515e662097911d4a2c27b'),
            (0x80131D48, 0x80131E0C, 'f24430cfa26f4bafdcb47124f12de4e44d289afee17d1a7ac065abe089c9edf9'),
    ]:
        assert hashlib.sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert len(kobold_connection_cases()) == 4
    files = json.loads((Path(__file__).resolve().parents[1] / 'extracted/iso_files.json').read_text())
    directions = collision_offsets()
    check_vcd(files)
    check_movement(files, directions)
    check_vb8(files, directions)
    check_foot_encounters()
    print('PASS: static point and boat paths, 256 resolver, 106 encounter and 16 menu cases')


if __name__ == '__main__':
    check()
