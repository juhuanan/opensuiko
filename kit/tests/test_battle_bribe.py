"""Static Bribe handler and raw prices; native Zig tests own deal execution."""
from pathlib import Path
import hashlib
import unittest
import json
import struct
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[1] / 'tools')]
import maindec
from export_first_room import source
import battle_placement
from export_world_travel import battle_export

ROOT = Path(__file__).resolve().parents[2]


def cases():
    # Semantic vectors retained from the former bounded-execution gate.
    rows = []
    for raw in [0, 1, 70, 300, 131068]:
        cost = raw * 3
        for money in sorted({0, max(0, cost - 1), cost, min(999999, cost + 1), 999999}):
            for allowed in [False, True]:
                success = allowed and money >= cost
                rows.append(dict(raw_money=raw, cost=cost, money=money, allowed=allowed,
                                 success=success, remaining_money=money-cost if success else money))
    return rows


def check_prices():
    # The initializer sums raw signed halfwords, not result-screen decoded rewards.
    assert [maindec.mword(pc) for pc in [0x800DEF40, 0x800DEF44, 0x800DEF4C, 0x800DEF50]] == [0x86220034, 0x8CA31260, 0x00431021, 0xACA21260]
    for region in ['b', 'c']:
        data, _ = source(f'/{region.upper()}_DATA.BIN')
        records = battle_placement.area_encounters(data)['encounters']
        exported = battle_export(region)
        assert exported['schema'] == ('suikoden-world-battle/30' if region == 'c' else 'suikoden-world-battle/25')
        for record, named in zip(records, exported['encounters'], strict=True):
            raw = [struct.unpack_from('<h', data, slot['stats_offset'] + 0x34)[0] for slot in record['slots']]
            assert named['bribe_cost'] == 3 * sum(raw)
        assert json.loads((ROOT / f'game/assets/world_{region}_battle.json').read_text()) == exported
    print('PASS: 16 encounter Bribe prices and exported battle data agree with static source records')


class BribeSource(unittest.TestCase):
    def test_handler_span_defend_price_signed_branch_and_cleanup(self):
        raw, _ = source('MAIN.EXE')
        base, size = struct.unpack_from('<II', raw, 0x18)
        body = raw[2048:2048+size]
        block = body[0x800EE38C-base:0x800EE5B8-base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         'a12e3d06f1cfea0f851ca9f6638268203b49aa6d7bab333a3d65e8074b647417')
        expected = {
            0x800EE3D4: 0x34050001, 0x800EE3DC: 0xA0650047,
            0x800EE3F4: 0x0044102A, 0x800EE3F8: 0x1040FFF8,
            0x800EE3FC: 0x24630054,
            0x800EE480: 0x8C821260, 0x800EE484: 0x8CC5001C,
            0x800EE488: 0x00021840, 0x800EE48C: 0x00621821,
            0x800EE490: 0x00A3102A, 0x800EE494: 0x14400007,
            0x800EE4A4: 0x8C42000C, 0x800EE4AC: 0x0441000B,
            0x800EE4B0: 0x00A31023, 0x800EE4D0: 0xAC400014,
            0x800EE4DC: 0xACC2001C, 0x800EE4FC: 0xAC510014,
            0x800EE580: 0x2442B414, 0x800EE590: 0xAC220000,
        }
        for pc, word in expected.items():
            self.assertEqual(struct.unpack_from('<I', body, pc-base)[0], word, hex(pc))
        words = [w for (w,) in struct.iter_unpack('<I', block)]
        calls = {0x80000000 | ((w & 0x3ffffff) << 2) for w in words if w >> 26 == 3}
        self.assertEqual(calls, {0x801455B8, 0x80145644, 0x80146DFC, 0x80146BB4, 0x8014707C})
        self.assertFalse(any(w >> 26 == 0 and w & 63 == 9 for w in words))

    def test_retained_decision_fixture(self):
        rows = json.loads((ROOT / 'game/tests/fixtures/battle_bribe.json').read_text())
        self.assertEqual(len(rows), 46)
        self.assertEqual(rows, cases())

    def test_all_exported_prices_use_raw_signed_money(self):
        check_prices()


if __name__ == '__main__':
    if '--static-only' in sys.argv:
        check_prices()
    else:
        unittest.main()
