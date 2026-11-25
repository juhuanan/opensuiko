"""Static source checks for the VB6 initializer and following ordinary selection."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene
import export_field_initializers as export
import maindec as M
from event_script_decode import decode_stream
from export_first_room import source
from test_canonical_start import assert_main_words

BASE = 0x80010000


def check_consumers():
    image = M.body()
    for start, end, expected in [
        (0x8013F2A4, 0x8013F37C, '120696f34db1dd4f3a30ac0a2bad05a43beebc8cd46afb71e33780c6a099f673'),
        (0x8013F1BC, 0x8013F2A4, '4db7aede2434499dc42779af0e3646a822c5b88a69da97f48bfdd93e5e8cb007'),
        (0x8013DB6C, 0x8013E028, 'b2667024a22ee484f4985471906c3e3cb6c3f356a2bf65ddd375f6bdf934a845'),
        (0x8013E028, 0x8013E17C, 'de21a37e1a6a09ebe58814d58dac4e65135ed9414df9dbef4146e5f361387477'),
        (0x8013E17C, 0x8013E210, 'e573cc4f67de4e18af4380c3eedac315e1340817c56738de8e6b2b29eb21dbc7'),
        (0x8013CBBC, 0x8013CC04, '29453528401894bd0ba9a2c2743485d68ed277966daa4a66768670c256552861'),
        (0x801398F8, 0x80139930, '6af2b286f265ebc7c4a545210f5573e3329cbc0edb2e2363b61da2472d5611b1'),
    ]:
        assert hashlib.sha256(image[start - M.MBASE:end - M.MBASE]).hexdigest() == expected, hex(start)
    assert {op: M.mword(0x80171718 + 4 * op) for op in (9, 0x30, 0x31, 0x42)} == {
        9: 0x8013CBBC, 0x30: 0x8013D228, 0x31: 0x8013D23C, 0x42: 0x801398F8,
    }
    assert M.mword(0x800C1AC0 + 4 * 17) == 0x80141AF8
    assert_main_words({
        # The field setup clears the active stream, then runs the initialization pass.
        0x801318C4: (0x3C018017, 0xA0201C28, 0x3C018018, 0xA020BFE4, 0x0C04FCA9, 0x00808021),
        # Use initialization mode 1. Each accepted entry gets one VM call.
        0x8013F308: (0x0C04F6DB, 0x34040001, 0x304200FF, 0x10400007, 0x26100001,
                     0x0C04F85F, 0, 0x0C04F80A, 0, 0x3C018018, 0xAC20DC4C),
        0x8013F340: (0x24420018, 0x3C018018, 0xAC22A120, 0x320200FF, 0x0051102B, 0x1440FFEC),
        # Entry flag 0x10 controls admission into the two modes. Ordinary selection
        # retains the first accepted record and installs that entry's stream.
        0x8013DBAC: (0x10800008, 0, 0x94620004, 0, 0x30420010, 0x14400008, 0,
                     0x0804F806, 0x00001021, 0x94620004, 0, 0x30420010, 0x1440010E, 0x00001021),
        0x8013F238: (0x0C04F6DB, 0x02602021, 0x304200FF, 0x10400005, 0x26100001, 0x0C04F85F),
        0x8013E1F8: (0x8C420014, 0, 0x3C018018, 0xAC22AF84),
        # 30 enables the same-tick loop. 31 stops it after publishing the
        # next cursor, leaving the final FD for a later pump.
        0x8013E158: (0x9042A180, 0, 0x1440FFB4, 0),
        0x8013D228: (0x34020001, 0x3C018018, 0xA022A180, 0x03E00008, 0),
        0x8013D23C: (0x3C018018, 0xA020A180, 0x03E00008, 0),
        # 42 advances by one operand and dispatches selector 17.
        0x80139908: (0x24620001, 0x3C018018, 0xAC22AF84, 0x90640000, 0x0C050605),
        0x80141818: (0x308300FF, 0x3402001C, 0x0043102B, 0x14400109, 0xAFBF0010, 0x00031080,
                     0x3C01800C, 0x24211AC0, 0x00220821, 0x8C220000, 0, 0x00400008, 0),
        0x80141AF8: (0x3C038018, 0x8C63DB24, 0, 0x906201B6, 0, 0x34420002, 0x08050713, 0xA06201B6),
        0x80141C4C: (0x8FBF0010, 0, 0x03E00008, 0x27BD0018),
        # Generic OR and set/clear read the same byte bank.
        0x8013CBEC: (0x00852021, 0x90820190, 0, 0x00431025, 0x03E00008, 0xA0820190),
        0x8013D70C: (0x90430190,),
        0x8013D724: (0x00621024, 0x10400008, 0x24840001),
        0x8013D740: (0x00621024, 0x1040FFFA, 0x24840001),
    })


def vectors():
    check_consumers()
    raw, _ = source('/VB6.BIN')
    room = area_scene.room_record(raw, 6)
    entities = area_scene.entities(raw, room)
    root = struct.unpack_from('<I', raw)[0] - BASE
    table = struct.unpack_from('<I', raw, root + 8)[0] - BASE
    entry_array, count = struct.unpack_from('<IB', raw, table + 6 * 16)
    assert (entry_array - BASE, count) == (room['entity_off'], len(entities)) == (0x3572C, 36)
    flags = [struct.unpack_from('<H', raw, entry_array - BASE + 24 * i + 4)[0] for i in range(count)]
    assert [i for i, flag in enumerate(flags) if flag & 0x10] == [6, 8, 28]

    # The retained scenario has bytes 15/16/17 = 8/0/0 and field X=0.
    # Check the candidate predicates directly. Entry 8 additionally needs
    # byte 15 bit 0x40, and entry 28 needs byte 17 bit 0x04.
    predicates = {
        5: '08 0f 20 07 0f 08 06', 6: '06',
        8: '08 10 01 07 0f 40 06', 28: '08 11 10 07 11 04 06',
    }
    scenario = {15: 8, 16: 0, 17: 0}
    accepted = {}
    for index, expected in predicates.items():
        entry = entry_array - BASE + 24 * index
        predicate = struct.unpack_from('<I', raw, entry + 16)[0] - BASE
        assert predicate == entities[index]['stream_offsets'][1]
        encoded = bytes.fromhex(expected)
        actual = raw[predicate:predicate + len(encoded)]
        assert actual == encoded
        terms = list(zip(actual[0:-1:3], actual[1:-1:3], actual[2:-1:3], strict=True))
        assert all(op in (7, 8) for op, _, _ in terms)
        accepted[index] = all(bool(scenario[byte] & mask) == (op == 7) for op, byte, mask in terms)
    for index, x_min in enumerate((1, 45, 25, 38, 14)):
        predicate = entities[index]['stream_offsets'][1]
        assert not flags[index] & 0x10
        assert raw[predicate:predicate + 3] == bytes((0x0B, x_min, x_min))
        accepted[index] = raw[predicate + 1] <= 0 <= raw[predicate + 2]
    initialization = [i for i in sorted(accepted) if flags[i] & 0x10 and accepted[i]]
    ordinary = next(i for i in sorted(accepted) if not flags[i] & 0x10 and accepted[i])
    assert (initialization, ordinary) == ([6], 5)

    # The initializer's decoded prefix ends before FD. Its only state write
    # is in a different scenario byte than these selection predicates read.
    initializer, = initialization
    stream = struct.unpack_from('<I', raw, entry_array - BASE + 24 * initializer + 20)[0] - BASE
    assert stream == entities[6]['stream_offsets'][2] == 0x34848
    assert raw[stream:stream + 5] == bytes.fromhex('30 42 11 31 fd')
    decoded = decode_stream(raw, stream, max_insns=4)
    assert [(op, args) for _, op, args, _ in decoded] == [(0x30, b''), (0x42, b'\x11'), (0x31, b''), (0xFD, b'')]
    mask = M.mword(0x80141B0C) & 0xFFFF
    offset = M.mword(0x80141B14) & 0xFFFF
    assert (offset - (M.mword(0x8013D70C) & 0xFFFF), mask) == (38, 2)
    return [
        dict(before=before, after=before | mask, initialization=initialization, pump_pc=len(decoded) - 1,
             source_cursor_delta=decoded[-1][0] - stream, ordinary_entity=ordinary, ordinary_pc=0)
        for before in range(256)
    ]


class FieldInitializers(unittest.TestCase):
    def test_source_writer_and_initialization_order(self):
        rows = vectors()
        self.assertEqual(rows, json.loads((ROOT / 'game/tests/fixtures/field_initialization.json').read_text()))

    def test_scoped_lowering_preserves_frozen_arrival(self):
        content, proof = export.export()
        base = json.loads((ROOT / 'game/assets/events/vb6_room6_arrival.json').read_text())
        self.assertEqual(content['programs'][0], base['programs'][0])
        for name in ('actors', 'texts', 'tracks'):
            self.assertEqual(content[name], base[name])
        self.assertEqual(content, json.loads((ROOT / 'game/assets/events/vb6_room6_field_host.json').read_text()))
        self.assertEqual(proof, json.loads((ROOT / 'kit/data/reports/field_initialization.json').read_text()))
        self.assertEqual(proof['lowering'], dict(selector=17, bank='scenario', byte_index=38, mask=2))


if __name__ == '__main__':
    if '--write-fixtures' in sys.argv:
        export.write()
        (ROOT / 'game/tests/fixtures/field_initialization.json').write_text(json.dumps(vectors(), indent=2) + '\n')
    else:
        unittest.main()
